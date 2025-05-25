#!/bin/bash

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

echo "🌐 Checking for existing firewalls..."
FIREWALLS_JSON=$(doctl compute firewall list -o json)
FIREWALL_NAMES=($(echo "$FIREWALLS_JSON" | jq -r '.[].name'))

if [[ ${#FIREWALL_NAMES[@]} -gt 0 ]]; then
  echo ""
  echo "🧱 Existing firewalls found:"
  for i in "${!FIREWALL_NAMES[@]}"; do
    echo "  [$i] ${FIREWALL_NAMES[$i]}"
  done

  echo ""
  read -p "📌 Enter the number of the firewall to attach (ex: 0,1,2) or press Enter to create a new one: " FW_INDEX
  if [[ -n "$FW_INDEX" ]]; then
    if [[ -z "${FIREWALL_NAMES[$FW_INDEX]}" ]]; then
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
read -p "🌐 Allow SSH from your current IPv6 (${HOME_IPV6:-unavailable})? Recommend no, if you have a v4. (y/n): " ALLOW_V6

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
  IFS=',' read -ra ADDR <<< "$EXTRA_IPS"
  for ip in "${ADDR[@]}"; do
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


# Build inbound rules array
INBOUND_RULES_ARGS=()
for ip in "${ALLOWED_IPS[@]}"; do
  INBOUND_RULES_ARGS+=("--inbound-rules=protocol:tcp,ports:22,address:${ip}")
done

# Outbound rules array - CORRECTED ICMP RULES
OUTBOUND_RULES_ARGS=(
  "--outbound-rules=protocol:tcp,ports:all,address:0.0.0.0/0"
  "--outbound-rules=protocol:tcp,ports:all,address:::0"
  "--outbound-rules=protocol:udp,ports:all,address:0.0.0.0/0"
  "--outbound-rules=protocol:udp,ports:all,address:::0"
  "--outbound-rules=protocol:icmp,address:0.0.0.0/0"
  "--outbound-rules=protocol:icmp,address:::0"
)

echo ""
echo "🌐 Fetching Cloudflare IP ranges..."
CF_IPS=$(curl -s https://www.cloudflare.com/ips-v4; curl -s https://www.cloudflare.com/ips-v6)
CF_INBOUND_RULES=()
for ip in $CF_IPS; do
  CF_INBOUND_RULES+=("--inbound-rules=protocol:tcp,ports:all,address:$ip")
  CF_INBOUND_RULES+=("--inbound-rules=protocol:udp,ports:all,address:$ip")
done

# Build command into an array
DOCTL_CMD=(doctl compute firewall create
  --name "$FIREWALL_NAME"
  "${INBOUND_RULES_ARGS[@]}"     # SSH from your IPs
  "${CF_INBOUND_RULES[@]}"       # Full access from Cloudflare
  "${OUTBOUND_RULES_ARGS[@]}"
  --droplet-ids "$DROPLET_IDS"
)

# Show the command before running
echo ""
echo "🔍 The following command will be run:"
# Using printf %q ensures arguments are quoted in a way that's unambiguous for shell interpretation
# and helps in debugging if there are spaces or special characters in firewall name or IPs (though less likely here).
# Each argument will be on a new line for readability, ending with a backslash.
COMMAND_TO_DISPLAY=""
for arg in "${DOCTL_CMD[@]}"; do
    COMMAND_TO_DISPLAY+=$(printf "%q " "$arg")
done
echo "  ${COMMAND_TO_DISPLAY% }" # Remove trailing space
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
  FIREWALL_ID=$(doctl compute firewall list -o json | jq -r --arg name "$FIREWALL_NAME" '.[] | select(.name == $name) | .id')
  if [[ -n "$FIREWALL_ID" ]]; then
    echo "🆔 Firewall ID: $FIREWALL_ID"
  else
    echo "⚠️  Warning: Firewall created, but ID could not be retrieved."
  fi
else
  echo ""
  echo "❌ Firewall creation failed. Please check the error message above."
  exit 1
fi

echo "🧪 Hint: To test your firewall from your local machine:"
echo "   nmap -Pn <your-droplet-ip>                  # scans top 1000 ports"
echo "   nmap -Pn -p- <your-droplet-ip>              # scan all 65535 ports"
echo "   nmap -Pn -p 22 <your-droplet-ip>            # SSH only"
echo "Port 22 should only show open if your IP is allowed. All others should be filtered or closed."
