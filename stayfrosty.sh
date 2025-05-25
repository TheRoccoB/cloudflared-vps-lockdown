#!/bin/bash

if ! [ -t 0 ]; then
  echo "❌ This script must be run from an interactive terminal."
  echo "👉 SSH into the machine and run it manually."
  exit 1
fi

echo ""
echo "❄️  StayFrosty: Cloudflare SSH tunnel setup and system lockdown"
echo "This script assumes you're running it on a fresh Ubuntu or Debian server and a Cloudflare free account."
echo ""
echo "If it's an existing machine, it's safer to quit after Cloudflared configured. Don't worry you'll be prompted before this script starts messing with UFW firewall."
echo ""
read -p '⚠️  Continue? (y/n): ' CONFIRM
[[ $CONFIRM != "y" ]] && echo "🧊💩🧊💩🧊 Ice cold 🧊💩🧊💩🧊 Exiting." && exit 1
echo ""

echo "➡️  Checking cloudflared..."

if ! command -v cloudflared &> /dev/null; then
  echo "📦 Installing cloudflared..."
  curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o cloudflared.deb
  dpkg -i cloudflared.deb || apt install -f -y
else
  echo "✅ cloudflared is already installed."
fi

echo "➡️  Checking origin certificate..."

CERT_PATH="${HOME}/.cloudflared/cert.pem"
if [ ! -f "$CERT_PATH" ]; then
  echo "🔐  Logging into Cloudflare..."
  cloudflared login
  echo "✅ Login successful. Cert saved to: $CERT_PATH"
else
  echo "✅ Origin certificate already exists at $CERT_PATH"
fi

# Prompt loop to select tunnel
while true; do
  echo "📡 Available Cloudflare tunnels:"
  cloudflared tunnel list || { echo "❌ Failed to list tunnels"; exit 1; }

  echo ""
  echo "🌐 Visit your Cloudflare Zero Trust dashboard to manage tunnels:"
  echo "🔗 https://one.dash.cloudflare.com/"
  echo "Then go to ➜ Networks ➜ Tunnels ➜ Create Tunnel"
  echo ""
  read -p "Enter the name of the tunnel you'd like to use (or type 'r' to refresh the list): " TUNNEL_NAME

  if [[ "$TUNNEL_NAME" == "r" ]]; then
    continue
  fi

  TUNNEL_ID=$(cloudflared tunnel list | awk -v name="$TUNNEL_NAME" '$2 == name { print $1 }')


  if [[ -z "$TUNNEL_ID" ]]; then
    echo "❌ Tunnel '$TUNNEL_NAME' not found. Try again."
  else
    echo "✅ Found tunnel ID: $TUNNEL_ID"
    break
  fi
done

# Check if a cloudflared systemd service is already installed
if systemctl list-unit-files | grep -q '^cloudflared.service'; then
  echo "✅ cloudflared systemd service is already installed. Skipping service setup."
else
  echo ""
  echo "📎 After creating the tunnel you'll see a command 'sudo cloudflared service install <token>' paste the full command, not just the token."
  read -p "Paste the FULL command (not just the token) from Cloudflare (or leave blank to skip): " SERVICE_CMD

  if [[ -z "$SERVICE_CMD" ]]; then
    echo "⚠️  Skipping service install. You’ll need to run it manually later if you want it to start on boot."
  else
    echo "📦 Installing tunnel as a systemd service..."
    eval "$SERVICE_CMD"
    echo "✅ Tunnel installed and set to start on boot via systemd."
  fi
fi

echo ""
echo "🌐 Add a public hostname for SSH access (ex: myssh.domain.com pointing to ssh://localhost:22). Then this script will tell you how to setup Cloudflare."

read -p "Subdomain (ex: myssh): " SUBDOMAIN
read -p "Domain (ex: domain.com): " DOMAIN
read -p "Service URL [leave blank for default: ssh://localhost:22]: " SSH_URL
SSH_URL=${SSH_URL:-ssh://localhost:22}

echo ""
echo "➡️ Go to https://one.dash.cloudflare.com/"
echo "Then: Networks → Tunnels → [Your Tunnel] → Add Public Hostname"
echo ""
echo "Use:"
echo "  Subdomain:      $SUBDOMAIN"
echo "  Domain:         $DOMAIN"
echo "  Type:           SSH"
echo "  URL:            $SSH_URL"

read -p "⏎ Press Enter when done..."

# Try to get public IP (IPv4 preferred)
BOX_IP=$(curl -s -4 https://ifconfig.co || curl -s -6 https://ifconfig.co)

echo ""
echo "🧪 Test it:"
echo "ssh -o ProxyCommand='cloudflared access ssh --hostname $SUBDOMAIN.$DOMAIN' root@$BOX_IP"
echo ""
echo "📌 To make this permanent, add the following to your ~/.ssh/config:"
echo ""
echo "Host $SUBDOMAIN"
echo "  HostName $BOX_IP"
echo "  User root"
echo "  ProxyCommand cloudflared access ssh --hostname $SUBDOMAIN.$DOMAIN"
echo ""
echo "Then you can just:"
echo "  ssh $SUBDOMAIN"

read -p "⚠️ Test the above before continuing with lockdown! (Enter to continue) "

echo ""
echo "⚠️ Cloudflare tunnel setup complete. Steps below this modify UFW and SSH configs, and are only recommended if this is a new server."
echo ""
read -p "🔒 Continue with system lockdown? (y/n): " CONTINUE_LOCKDOWN
[[ $CONTINUE_LOCKDOWN != "y" ]] && echo "🧊 Exiting without system lockdown." && exit 0

echo "🔐 Starting system lockdown..."

# 🔓 Collect allowed SSH IPs
echo "⚠️ As a backup you might want to still be able to SSH (without cloudflared) from your home or work IP."
echo "➡️  Add IPs allowed direct SSH access into this machine (e.g. home, office, VPN)."
echo "Press Enter without input to finish."
echo ""
echo "Use this command to get IP of your local machine. You can use -6 if it has not IPV4 IP."
echo "  curl -s -4 https://ifconfig.co"
echo ""

ALLOWED_IPS=("$@")  # Load optional IPs from script args

if [[ ${#ALLOWED_IPS[@]} -gt 0 ]]; then
  echo "✅ Currently allowed IPs from args: ${ALLOWED_IPS[*]}"
fi

# Prompt for more
first_prompt=true
while true; do
  echo ""
  if [ "$first_prompt" = true ]; then
    read -p "Allow direct SSH from IP (home/work)? (add a single IP or leave blank to finish): " ip
    first_prompt=false
  else
    read -p "Another IP to allow? (leave blank to finish): " ip
  fi
  [[ -z "$ip" ]] && break
  ALLOWED_IPS+=("$ip")
done

# 🔥 Apply UFW rules
echo ""
echo "➡️  Setting up UFW firewall..."
ufw --force enable
ufw default deny incoming
ufw default allow outgoing

# Allow each entered IP (avoid duplicate rules)
for ip in "${ALLOWED_IPS[@]}"; do
  if ufw status | grep -q "$ip.*22"; then
    echo "✅  SSH rule for $ip already exists. Skipping."
  else
    echo "➡️  Allowing SSH from $ip..."
    ufw allow from "$ip" to any port 22 proto tcp
  fi
done

# Localhost allowances
echo "➡️  Allowing SSH on localhost..."
ufw allow in on lo to any port 22 proto tcp
echo "➡️  Allowing all loopback traffic..."
ufw allow in on lo
ufw allow out on lo

# ✨ Harden system
if ! dpkg -s unattended-upgrades apt-listchanges >/dev/null 2>&1; then
  echo "📦 Installing unattended-upgrades and apt-listchanges..."
  apt update && apt install -y unattended-upgrades apt-listchanges
else
  echo "✅ unattended-upgrades and apt-listchanges already installed."
fi

echo "➡️  Enabling automatic security updates..."
dpkg-reconfigure -f noninteractive unattended-upgrades

if ! dpkg -s fail2ban >/dev/null 2>&1; then
  echo "📦 Installing fail2ban..."
  apt install -y fail2ban
else
  echo "✅ fail2ban already installed."
fi

echo "➡️  Setting MOTD reboot notice..."
echo -e '#!/bin/sh\nif [ -f /var/run/reboot-required ]; then echo \"⚠️  Reboot is required!\"; fi' > /etc/update-motd.d/99-reboot-required
chmod +x /etc/update-motd.d/99-reboot-required

# 🔐 SSH hardening
echo "➡️  Hardening SSH config..."
sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config

echo "📋 Current UFW status:"
ufw status verbose || echo "⚠️  UFW not active or failed to report status."

# 🔍 Try to detect both IPv4 and IPv6
IPV4=$(curl -s -4 https://ifconfig.co)
IPV6=$(curl -s -6 https://ifconfig.co)

echo ""
echo "🧪 Security check: After SSH restart, scan this box from another machine to verify lockdown."

if [[ -n "$IPV4" ]]; then
  echo "🌍 Detected IPv4: $IPV4"
  echo "  🔹 Fast scan (top 1000 ports): nmap -Pn $IPV4"
  echo "       expectation: all ports should be closed except for 22 if you allowlisted your home IP"
  echo "  🔹 Full scan (all ports, slow):      nmap -Pn -p- $IPV4"
  echo "       expectation: all ports should be closed except for 22 if you allowlisted your home IP"
  echo "  🔹 Test SSH password login (this should fail)"
  echo "     ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no root@$IPV4"
  echo ""
fi

if [[ -n "$IPV6" ]]; then
  echo "🌍 Detected IPv6: $IPV6"
  echo "  🔹 Fast scan (top 1000 ports): nmap -6 -Pn $IPV6"
  echo "       expectation: all ports should be closed except for 22 if you allowlisted your home IP"
  echo "  🔹 Full scan (all ports):      nmap -6 -Pn -p- $IPV6"
  echo "       expectation: all ports should be closed except for 22 if you allowlisted your home IP"
  echo "  🔹 Test SSH password login (this should fail):"
  echo "     ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no root@[$IPV6]"
  echo ""
fi

read -p "🔁 Restart SSH service now? You'll likely be logged out (y/n): " RESTART
if [[ "$RESTART" == "y" ]]; then
  echo "Restarting SSH in 3 seconds..."
  echo ""
  echo "⚠️  Reminder: Docker can expose ports directly, bypassing UFW. Check nmap often."
  echo ""
  echo "⚠️  Reminder: Security is your responsibility! Run the Security check tests above!"
  echo "Don't rely solely on some guy from the internet who made this script. Do your own research!"

  echo ""
  echo "✅ Lockdown complete"
  echo "❄️ Stay frosty."

  sleep 3
  systemctl restart ssh
else
  echo "⚠️  SSH config changes will take effect after manual restart."
fi