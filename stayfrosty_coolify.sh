#!/bin/bash
set -e

command -v jq &> /dev/null || {
    echo "❌ jq is not installed. Install with: sudo apt install jq"
    exit 1
}

# 🧠 Check if cloudflared tunnel is running
echo "🔍 Checking if cloudflared tunnel is running..."
if pgrep -f "cloudflared.*tunnel" > /dev/null; then
  echo "✅ Cloudflared tunnel appears to be running."
else
  echo "❌ Cloudflared tunnel does not seem to be running. Please run stayfrosty.sh first."
  exit 1
fi

# 🧰 Install Coolify
echo ""
read -p "📦 Ready to run the Coolify installer? Press Enter to continue..."
echo "📦 Installing Coolify..."
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | sudo bash
echo "✅ Coolify installation complete."

SOURCE_NETWORK_NAMES=("coolify" "bridge")
TARGET_PORT="22"
TARGET_PROTO="tcp"

echo "🔧 Finding host (bridge) network gateway IP..."
TARGET_HOST_IP=$(docker network inspect bridge | jq -r '.[0].IPAM.Config[]? | select(.Gateway) | .Gateway' | head -n1)

if [[ -z "$TARGET_HOST_IP" ]]; then
    echo "❌ Could not determine bridge gateway IP. Check Docker network config."
    exit 1
fi

echo "✅ Host IP (for host.docker.internal): $TARGET_HOST_IP"
echo ""

RULES=()

for NET in "${SOURCE_NETWORK_NAMES[@]}"; do
    echo "🌐 Processing network: $NET"
    SUBNET=$(docker network inspect "$NET" | jq -r '.[0].IPAM.Config[]? | select(.Subnet) | .Subnet' | head -n1)

    if [[ -z "$SUBNET" ]]; then
        echo "  ⚠️  No subnet found for $NET — skipping."
    else
        RULE="sudo ufw allow from $SUBNET to $TARGET_HOST_IP port $TARGET_PORT proto $TARGET_PROTO"
        RULES+=("$RULE")
        echo "  ✅ $RULE"
    fi
done

echo ""
echo "🔒 ${#RULES[@]} rule(s) generated. Apply with:"
printf '   %s\n' "${RULES[@]}"
echo ""

# 🔐 Ask user if they want to apply the rules now
echo "These are local routing rules that allow Coolify to function without exposing external ports."
read -p "🛡️  Do you want to apply these rules now? (y/n): " APPLY_NOW
if [[ "$APPLY_NOW" =~ ^[Yy]$ ]]; then
    for rule in "${RULES[@]}"; do
        echo "Applying: $rule"
        eval "$rule"
    done

    echo ""
    # ✅ Check if UFW is enabled
    if sudo ufw status | grep -q inactive; then
        echo "⚠️  UFW is currently disabled."
        read -p "👉 Do you want to enable UFW now? (y/n): " ENABLE_UFW
        if [[ "$ENABLE_UFW" =~ ^[Yy]$ ]]; then
            sudo ufw enable
        else
            echo "🚫 UFW remains disabled."
        fi
    else
        echo "✅ UFW is already active. Reloading..."
        sudo ufw reload
    fi
else
    echo "🚫 Rules not applied. Remember to apply them later if needed."
fi

get_public_ip() {
  # Try IPv4 first with a 5-second timeout
  local ipv4=$(curl -s -4 --connect-timeout 2 --max-time 5 ifconfig.me 2>/dev/null)

  # If IPv4 fails, try IPv6
  if [[ -z "$ipv4" ]]; then
    echo "ℹ️ IPv4 detection failed, trying IPv6..."
    local ipv6=$(curl -s -6 --connect-timeout 2 --max-time 5 ifconfig.me 2>/dev/null)

    if [[ -z "$ipv6" ]]; then
      echo "⚠️ Could not detect public IP address. Using 'localhost' instead."
      echo "localhost"
    else
      echo "$ipv6"
    fi
  else
    echo "$ipv4"
  fi
}

echo ""
echo "🖥️  Getting public IP..."
# Get the public IP with fallback and timeout protection
PUBLIC_IP=$(get_public_ip)
echo ""

echo ""
echo "🖥️  Once Coolify finishes installing, visit the dashboard at:"
echo "   👉 http://$PUBLIC_IP:8000"
echo ""
read -p "⏳ Press Enter once you've visited the dashboard and created your user/pass and connected localhost (onboarding)..."

echo ""
echo "🤨 Did you notice that Docker (Coolify) broke through UFW and exposed port 8000 anyway?"
echo ""
echo "Before we clean up exposed ports, let's get Coolify serving via the Cloudflare tunnel, then we'll clean up port 8000."
echo ""
echo "➡️  Go to your Cloudflare Tunnel dashboard:"
echo "   https://one.dash.cloudflare.com/"
echo "Then:"
echo "  - Navigate to Networks → Tunnels → [Your Tunnel]"
echo "  - Add a Public Hostname:"
echo "      Subdomain:      coolify (or something else)"
echo "      Domain:         yourdomain.com (your domain)"
echo "      Type:           HTTP"
echo "      URL:            http://localhost:80"
echo ""
echo "This will proxy your Coolify instance securely through Cloudflare."
read -p "⏳ Press Enter when done..."
echo ""
echo "Complete onboarding at http://$PUBLIC_IP:8000, and connect localhost. Don't worry about adding a resource yet."
echo ""
echo "Then go to:"
echo "   👉 http://$PUBLIC_IP:8000/settings"
echo ""
echo "Set your instance name to http://coolify.yourdomain.com (match cloudflare)."
echo ""
echo "⚠️ IMPORTANT ⚠️: Note that you need to use http and not https. Click save."
echo "Why? Cloudflare and Coolify attempt to apply https causing an infinite redirect loop."
echo "Also note, Cloudflare SSL settings should be 'full' (I *think* this is default)"
echo ""
echo "Confirm that you can load coolify from https://coolify.yourdomain.com."
echo "Also confirm that http://coolify.yourdomain.com redirects to https."
echo "If it doesn't work right away wait a minute or two and try again."
echo ""

read -r "Enter to continue."

echo ""
echo "If you want to block external traffic ports 80, 443, 8080 (recommended with cloudflare tunnel)"
echo "Go to Coolify => Server => Localhost => Proxy and change:"
echo ""
echo "    ports:"
echo "      - '80:80'"
echo "      - '443:443'"
echo "      - '443:443/udp'"
echo "      - '8080:8080'"
echo "      "
echo "      to "
echo "      "
echo "    ports:"
echo "      - '127.0.0.1:80:80'        # HTTP"
echo "      - '127.0.0.1:443:443'      # HTTPS"
echo "      - '127.0.0.1:8080:8080'    # Traefik dashboard"
echo "      - '127.0.0.1:443:443/udp'  # UDP"
echo ""
read -p "Save and restart proxy. Enter when done."

echo ""
echo "🛠️  Disabling direct port 8000 exposure from Coolify..."

CUSTOM_COMPOSE_FILE="/data/coolify/source/docker-compose.custom.yml"
CUSTOM_COMPOSE_CONTENT=$(cat <<EOF
services:
  coolify:
    ports: !reset []
  soketi:   # blocks external access to ports 6001 and 6002
    ports: !reset []
EOF
)

sudo tee "$CUSTOM_COMPOSE_FILE" > /dev/null <<< "$CUSTOM_COMPOSE_CONTENT"

echo "✅ Custom docker-compose custom created at $CUSTOM_COMPOSE_FILE "
echo "This blocks ports 8000, 6001, 6002 to the outside."
echo ""
echo "📄 File content:"
echo "-------------------------------------------"
echo "$CUSTOM_COMPOSE_CONTENT"
echo "-------------------------------------------"
echo ""


read -p "📦 Next, we'll re-run the Coolify installer to lock out exposed ports (8000, 6001, 6002). Press Enter to continue..."
echo ""
echo "📦 Re-running Coolify installer to apply port changes..."
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | sudo bash
echo "✅ Coolify installation complete."

echo ""
echo "✅ If all went well, Coolify should no longer be accessible at http://$PUBLIC_IP:8000"
echo "🕵️  You can verify all ports are closed (on a your home computer) with:"
echo "   nmap -Pn -T4 -n $PUBLIC_IP"
echo ""
echo "Note: If you allowed SSH access from your home PC, you'll see port 22 open."
echo "Remember, docker can sometimes bypass UFW. Check nmap after installing new services."
echo "Read up on 'Cloudflare Access' to fully block access to your coolify login page."
echo ""
echo "❄️  Stay frosty."
