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
  echo "❌ Cloudflared tunnel does not seem to be running. Please start it and try again."
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

# 🌍 Get public IP
# todo handle v6 if there's no v4. Also set timeouts so that the script doesn't fail
PUBLIC_IP=$(curl -s -4 ifconfig.me)

echo ""
echo "🖥️  Once Coolify finishes installing, visit the dashboard at:"
echo "   👉 http://$PUBLIC_IP:8000"
echo ""
read -p "⏳ Press Enter once you've visited the dashboard and created your user/pass and connected localhost..."

echo "🤨 Did you notice that Docker (Coolify) broke through UFW and exposed port 8000 anyway?"
echo ""
echo "Before we clean up exposed ports, let's get Coolify serving via the Cloudflare tunnel, then we'll clean up port 8000."
echo ""
echo "➡️  Now, go to your Cloudflare Tunnel dashboard:"
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
echo "Complete onboarding at http://$PUBLIC_IP:8000, and connect localhost."
echo ""
echo "Then go to:"
echo "   👉 http://$PUBLIC_IP:8000/settings"
echo ""
echo "Set your instance name to http://coolify.yourdomain.com (match cloudflare)."
echo ""
echo "Cloudflare SSL settings should be 'full'"
echo ""
echo "⚠️IMPORTANT⚠️: Note that you need to use http and not https. Click save."
echo "Why? Cloudflare and Coolify attempt to apply https causing an infinite redirect loop."
echo ""
echo "Confirm that you can load coolify from https://coolify.yourdomain.com."
echo "Also confirm that http://coolify.yourdomain.com redirects to https."
echo "If it doesn't work right away wait a minute or two and try again."
echo ""

read -p "Press enter when complete."

echo ""
echo "🛠️  Disabling direct port 8000 exposure from Coolify..."

CUSTOM_COMPOSE_FILE="/data/coolify/source/docker-compose.custom.yml"

sudo tee "$CUSTOM_COMPOSE_FILE" > /dev/null <<EOF
services:
  coolify:
    ports: !reset []
EOF

echo "✅ Custom docker-compose custom created at $CUSTOM_COMPOSE_FILE "
echo "This blocks ports 8000, 600 to the outside."
echo ""

TRAEFIK_COMPOSE_FILE="/data/coolify/proxy/docker-compose.override.yml" > /dev/null <<EOF
services:
  traefik:
    ports: !override
      - "127.0.0.1:80:80"
      - "127.0.0.1:443:443"
      - "127.0.0.1:443:443/udp"
      - "127.0.0.1:8080:8080"
EOF

echo "✅ Custom docker-compose override created at $TRAEFIK_COMPOSE_FILE"
echo "This blocks ports 80, 443, 8080"
echo ""


read -p "📦 Next, we'll re-run the Coolify installer to lock out exposed ports. Press Enter to continue..."
echo ""
echo "📦 Re-running Coolify installer to apply port changes..."
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | sudo bash
echo "✅ Coolify installation complete."

echo ""
echo "✅ If all went well, Coolify should no longer be accessible at http://$PUBLIC_IP:8000"
echo "🕵️  You can verify this with:"
echo "   nmap -T4 -n $PUBLIC_IP"
echo ""
echo "❄️  Stay frosty."
