#!/bin/bash

# Exit on error and treat unset variables as an error
set -euo pipefail

# Ensure doctl and jq are available
if ! command -v doctl &> /dev/null; then
  echo "❌ 'doctl' is not installed. Install it and run 'doctl auth init' first."
  echo "  Recommended: When creating the token, only allow Droplet => Read, and Firewall (all 4 rules)"
  exit 1
fi

if ! command -v jq &> /dev/null; then
  echo "❌ 'jq' is required but not installed. Install it first."
  exit 1
fi

echo "📡 Fetching your Droplets..."
doctl compute droplet list --format ID,Name,PublicIPv4,PublicIPv6

echo ""
echo "🌐 Checking for existing firewalls..."
FIREWALLS_JSON=$(doctl compute firewall list -o json)

# Populate FIREWALL_NAMES array.
# Using word splitting from command substitution. This is generally safe as DO firewall names
# are unlikely to contain spaces. readarray (Bash 4+) would be more robust for arbitrary strings.
# shellcheck disable=SC2207 # Word splitting is intentional here for jq output.
FIREWALL_NAMES=($(echo "$FIREWALLS_JSON" | jq -r '.[].name'))

# Check if FIREWALL_NAMES array actually has content.
# It could be empty or contain a single empty string if no firewalls exist.
HAS_FIREWALLS=0
if [[ ${#FIREWALL_NAMES[@]} -gt 0 && -n "${FIREWALL_NAMES[0]}" ]]; then
  HAS_FIREWALLS=1
fi

if [[ $HAS_FIREWALLS -eq 1 ]]; then
  echo ""
  echo "🧱 Existing firewalls found:"
  for i in "${!FIREWALL_NAMES[@]}"; do
    echo "  [$i] ${FIREWALL_NAMES[$i]}"
  done

  echo ""
  read -p "📌 Enter the number of the firewall to attach (ex: 0,1,2) or press Enter to create a new one: " FW_INDEX
  if [[ -n "$FW_INDEX" ]]; then
    # Validate FW_INDEX is a number and within bounds
    if ! [[ "$FW_INDEX" =~ ^[0-9]+$ ]] || [[ "$FW_INDEX" -ge "${#FIREWALL_NAMES[@]}" ]]; then
      echo "❌ Invalid selection. Aborting."
      exit 1
    fi
    FIREWALL_NAME="${FIREWALL_NAMES[$FW_INDEX]}"
    FIREWALL_ID=$(echo "$FIREWALLS_JSON" | jq -r --arg name "$FIREWALL_NAME" '.[] | select(.name == $name) | .id')
    read -p "✳️  Enter Droplet IDs (ex: 43214321) to attach to '$FIREWALL_NAME' (comma-separated): " DROPLET_IDS
    if [[ -z "$DROPLET_IDS" ]]; then
      echo "❌ No Droplet IDs entered. Aborting."
      exit 1
    fi
    if doctl compute firewall add-droplets "$FIREWALL_ID" --droplet-ids "$DROPLET_IDS"; then
      echo "✅ Firewall '$FIREWALL_NAME' attached to Droplet(s): $DROPLET_IDS"
      exit 0
    else
      echo "❌ Failed to attach firewall. Check the error above."
      exit 1
    fi
  fi
fi

echo ""
read -p "✳️  Enter Droplet IDs to secure (comma-separated): " DROPLET_IDS
if [[ -z "$DROPLET_IDS" ]]; then
  echo "❌ No Droplet IDs entered. Aborting."
  exit 1
fi

# Safe IP fetching with timeout
HOME_IPV4=$(curl -s -4 --max-time 3 ifconfig.me || echo "")
HOME_IPV6=$(curl -s -6 --max-time 3 ifconfig.me || echo "")

read -p "🏠 Allow SSH from your current IPv4 (${HOME_IPV4:-unavailable})? (y/n): " ALLOW_V4
read -p "🌐 Allow SSH from your current IPv6 (${HOME_IPV6:-unavailable})? (Recommend no if you have a dynamic IPv6 or stable IPv4) (y/n): " ALLOW_V6

ALLOWED_IPS=()

if [[ "$ALLOW_V4" =~ ^[Yy]$ && -n "$HOME_IPV4" ]]; then
  ALLOWED_IPS+=("${HOME_IPV4}/32")
fi

if [[ "$ALLOW_V6" =~ ^[Yy]$ && -n "$HOME_IPV6" ]]; then
  ALLOWED_IPS+=("${HOME_IPV6}/128")
fi

echo ""
read -p "➕ Add any additional IPs to allow for SSH? (comma-separated IPv4 or IPv6, or leave blank): " EXTRA_IPS
if [[ -n "$EXTRA_IPS" ]]; then
  # Bash 3 compatible way to split string into array
  OLD_IFS="$IFS"
  IFS=','
  # shellcheck disable=SC2206 # Word splitting is desired here based on IFS
  ADDR_ARRAY=($EXTRA_IPS)
  IFS="$OLD_IFS"

  for ip in "${ADDR_ARRAY[@]}"; do
    ip_trimmed=$(echo "$ip" | xargs) # Trim whitespace
    if [[ -n "$ip_trimmed" ]]; then # Ensure not empty after trimming
      if [[ "$ip_trimmed" == *:* ]]; then
        ALLOWED_IPS+=("${ip_trimmed}/128")  # IPv6
      else
        ALLOWED_IPS+=("${ip_trimmed}/32")   # IPv4
      fi
    fi
  done
fi

if [[ ${#ALLOWED_IPS[@]} -eq 0 ]]; then
  echo "❌ No IPs to allow for SSH. You would be locked out. Aborting."
  exit 1
fi

echo ""
echo "📋 Allowed IPs for SSH:"
printf '  - %s\n' "${ALLOWED_IPS[@]}"
echo ""

FIREWALL_NAME="stay-frosty-lockdown-$(date +%Y%m%d-%H%M%S)"
read -p "🛡️  Enter a name for the firewall (default: ${FIREWALL_NAME}): " USER_FIREWALL_NAME
if [[ -n "$USER_FIREWALL_NAME" ]]; then
  FIREWALL_NAME="$USER_FIREWALL_NAME"
fi

# Build inbound rules array for SSH
INBOUND_RULES_ARGS=()
for ip in "${ALLOWED_IPS[@]}"; do
  INBOUND_RULES_ARGS+=("--inbound-rules=protocol:tcp,ports:22,address:${ip}")
done

# Outbound rules array
OUTBOUND_RULES_ARGS=(
  "--outbound-rules=protocol:tcp,ports:all,address:0.0.0.0/0,address:::/0"
  "--outbound-rules=protocol:udp,ports:all,address:0.0.0.0/0,address:::/0"
  "--outbound-rules=protocol:icmp,address:0.0.0.0/0,address:::/0"
)

echo ""
echo "🌐 Fetching Cloudflare IP ranges..."
# Use -f to fail silently on server errors, -L to follow redirects, -s for silent
# The '|| echo ""' ensures the variable is empty if curl fails, preventing set -e from exiting prematurely
CF_IPV4_RANGES=$(curl -sfL https://www.cloudflare.com/ips-v4 || echo "")
CF_IPV6_RANGES=$(curl -sfL https://www.cloudflare.com/ips-v6 || echo "")

if [[ -z "$CF_IPV4_RANGES" && -z "$CF_IPV6_RANGES" ]]; then
  echo "⚠️ Warning: Failed to fetch Cloudflare IP ranges. Firewall will not include Cloudflare rules."
  # If Cloudflare access is mandatory, you might want to exit:
  # echo "❌ Aborting as Cloudflare IP fetch failed."
  # exit 1
fi

CF_INBOUND_RULES=()
CLOUDFLARE_TCP_ADDRESS_ARGS=""
CLOUDFLARE_UDP_ADDRESS_ARGS=""

# Process IPv4 ranges
# Need to iterate line by line if CF_IPV4_RANGES contains multiple lines
# Use a while read loop for line-by-line processing to avoid word splitting issues with the range list itself
OLD_IFS="$IFS" # Save current IFS
IFS=$'\n' # Set IFS to newline for reading lines
for ip_range in $CF_IPV4_RANGES; do
  # Trim potential whitespace from the ip_range itself (though unlikely from Cloudflare's list)
  ip_range_trimmed=$(echo "$ip_range" | xargs)
  if [[ -n "$ip_range_trimmed" ]]; then # Basic check to skip empty lines
    CLOUDFLARE_TCP_ADDRESS_ARGS+=",address:${ip_range_trimmed}"
    CLOUDFLARE_UDP_ADDRESS_ARGS+=",address:${ip_range_trimmed}"
  fi
done

# Process IPv6 ranges
for ip_range in $CF_IPV6_RANGES; do
  ip_range_trimmed=$(echo "$ip_range" | xargs)
  if [[ -n "$ip_range_trimmed" ]]; then # Basic check to skip empty lines
    CLOUDFLARE_TCP_ADDRESS_ARGS+=",address:${ip_range_trimmed}"
    CLOUDFLARE_UDP_ADDRESS_ARGS+=",address:${ip_range_trimmed}"
  fi
done
IFS="$OLD_IFS" # Restore IFS

# Only add Cloudflare rules if there are addresses to add
if [[ -n "$CLOUDFLARE_TCP_ADDRESS_ARGS" ]]; then
  CF_INBOUND_RULES+=("--inbound-rules=protocol:tcp,ports:all${CLOUDFLARE_TCP_ADDRESS_ARGS}")
fi
if [[ -n "$CLOUDFLARE_UDP_ADDRESS_ARGS" ]];
then
  CF_INBOUND_RULES+=("--inbound-rules=protocol:udp,ports:all${CLOUDFLARE_UDP_ADDRESS_ARGS}")
fi


# Build command into an array
DOCTL_CMD=(doctl compute firewall create
  --name "$FIREWALL_NAME"
)
# Add SSH rules if any
if [[ ${#INBOUND_RULES_ARGS[@]} -gt 0 ]]; then
  DOCTL_CMD+=("${INBOUND_RULES_ARGS[@]}")
fi
# Add Cloudflare rules if any were generated
if [[ ${#CF_INBOUND_RULES[@]} -gt 0 ]]; then
  DOCTL_CMD+=("${CF_INBOUND_RULES[@]}")
fi
# Add Outbound rules
if [[ ${#OUTBOUND_RULES_ARGS[@]} -gt 0 ]]; then
  DOCTL_CMD+=("${OUTBOUND_RULES_ARGS[@]}")
fi

DOCTL_CMD+=(--droplet-ids "$DROPLET_IDS")


# Show the command before running
echo ""
echo "🔍 The following command will be run:"
echo "doctl compute firewall create \\"
echo "  --name \"$FIREWALL_NAME\" \\"

# Print SSH inbound rules
for rule in "${INBOUND_RULES_ARGS[@]}"; do
  echo "  $rule \\"
done

# Break up Cloudflare rules into TCP and UDP address lines
for rule in "${CF_INBOUND_RULES[@]}"; do
  proto=$(echo "$rule" | cut -d',' -f1 | cut -d= -f2)
  ports=$(echo "$rule" | cut -d',' -f2 | cut -d= -f2)
  addresses=$(echo "$rule" | sed -E 's/--inbound-rules=protocol:[^,]+,ports:[^,]+,//')
  IFS=',' read -ra ADDR_ARR <<< "$addresses"
  echo "  --inbound-rules=protocol:$proto,ports:$ports \\"
  for addr in "${ADDR_ARR[@]}"; do
    echo "    $addr \\"
  done
done

# Outbound rules
for rule in "${OUTBOUND_RULES_ARGS[@]}"; do
  echo "  $rule \\"
done

# Droplet IDs
echo "  --droplet-ids \"$DROPLET_IDS\""

echo ""
read -p "⚠️  Proceed with this firewall creation? (y/n): " FINAL_CONFIRM
if [[ ! "$FINAL_CONFIRM" =~ ^[Yy]$ ]]; then
  echo "❌ Cancelled before firewall creation."
  exit 1
fi

# Actually run it
if "${DOCTL_CMD[@]}"; then
  echo ""
  echo "✅ Firewall '$FIREWALL_NAME' created and applied to Droplet(s): $DROPLET_IDS"
  # Attempt to retrieve firewall ID. Might fail if name isn't unique or due to eventual consistency.
  FIREWALL_ID=$(doctl compute firewall list --format ID,Name -o json | jq -r --arg name "$FIREWALL_NAME" '.[] | select(.name == $name) | .id' || echo "")
  if [[ -n "$FIREWALL_ID" ]]; then
    echo "🆔 Firewall ID: $FIREWALL_ID"
  else
    echo "⚠️  Warning: Firewall created, but ID could not be retrieved automatically. You can find it in your DigitalOcean control panel."
  fi
else
  echo ""
  echo "❌ Firewall creation failed. Please check the error message above."
  exit 1
fi

echo ""
echo "🧪 Hint: To test your firewall from your local machine:"
echo "   nmap -Pn <your-droplet-ip>                  # scans top 1000 ports"
echo "   nmap -Pn -p- <your-droplet-ip>              # scan all 65535 ports"
echo "   nmap -Pn -p 22 <your-droplet-ip>            # SSH only"
echo "Port 22 should only show open if your IP is allowed. Others might show open if Cloudflare is proxying to them (e.g. 80, 443) from their IPs."
echo "All other ports should appear filtered or closed from non-Cloudflare, non-allowed IPs."