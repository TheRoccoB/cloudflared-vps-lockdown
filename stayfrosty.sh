#!/bin/bash

if ! [ -t 0 ]; then
  echo "❌ This script must be run from an interactive terminal."
  echo "👉 SSH into the machine and run it manually."
  exit 1
fi

clear

echo ""
echo "❄️  StayFrosty: Cloudflare SSH tunnel setup and system lockdown"
echo "This script assumes you're running it on a fresh Ubuntu or Debian server and a Cloudflare free account."
echo ""
echo "You'll be prompted before this script starts messing with UFW firewall... but..."
echo ""
echo "⚠️⚠️⚠️ If this is an existing prod machine, take a snapshot in your VPS (digitalocean, etc) dashboard before running this script ⚠️⚠️⚠️"
echo ""
read -p '⚠️  Continue? (y/n): ' CONFIRM
[[ $CONFIRM != "y" ]] && echo "🧊💩🧊💩🧊 Ice cold 🧊💩🧊💩🧊 Exiting." && exit 1
echo ""

clear

echo "📦 First lets update our packages. This step will run:"
echo ""
echo "   sudo apt update"
echo "   sudo apt full-upgrade -y"
echo ""
echo "⚠️  During the upgrade, you may be prompted with a configuration screen for 'sshd'."
echo "   If asked whether to keep the existing version, it's usually safest to choose:"
echo "     → Keep the local version currently installed"
echo ""
echo "Note: This is totally optional, and the script will run fine without it."
read -p "🔄 Proceed with update and upgrade? (y/n): " DO_UPGRADE

if [[ "$DO_UPGRADE" =~ ^[Yy]$ ]]; then
    echo ""
    echo "📥 Running apt update..."
    sudo apt update

    echo ""
    echo "🚀 Running apt full-upgrade -y..."
    sudo apt full-upgrade -y

    echo ""
    echo "🧼 If any packages mentioned needing a reboot (like the kernel or systemd)..."
    echo "   Note: Reboot can usually be deferred until your next login."
    echo ""
    read -p "🔁 Reboot now (y/n) [default is n]: " DO_REBOOT
    if [[ "$DO_REBOOT" =~ ^[Yy]$ ]]; then
        echo "🔄 Rebooting..."
        sudo reboot
        exit 0
    fi
else
    echo "⏭️ Skipping upgrade step..."
fi

echo ""

echo "🔍 Detecting your box IPs"

# 🔍 Try to detect both IPv4 and IPv6 with timeouts
IPV4=$(curl -s -4 --connect-timeout 3 --max-time 5 https://ifconfig.co 2>/dev/null || echo "")
if [[ -n "$IPV4" ]]; then
  echo "🌍 Detected IPv4: $IPV4"
else
  echo "⚠️  No IPv4 detected."
fi

IPV6=$(curl -s -6 --connect-timeout 3 --max-time 5 https://ifconfig.co 2>/dev/null || echo "")

if [[ -n "$IPV6" ]]; then
  echo "🌍 Detected IPv6: $IPV6"
else
  echo "⚠️  No IPv6 detected."
fi

# Set BOX_IP to IPv4 if available, otherwise use IPv6, or empty if neither works
BOX_IP=${IPV4:-$IPV6}

echo "➡️  Checking cloudflared..."

if ! command -v cloudflared &> /dev/null; then
  echo "📦 Installing cloudflared..."
  curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o cloudflared.deb
  dpkg -i cloudflared.deb || apt install -f -y
else
  echo "✅ cloudflared is already installed."
fi

# Check if a cloudflared systemd service is already installed
if systemctl list-unit-files | grep -q '^cloudflared.service'; then
  echo "✅ cloudflared systemd service is already installed. Skipping service setup."
else
  echo ""
  echo "➡️ Go to https://one.dash.cloudflare.com/"
  echo "➡️ Then: Networks → Tunnels → Create a Tunnel → Cloudflared"
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
echo "➡️ Go to https://one.dash.cloudflare.com/"
echo "Then: Networks → Tunnels → [Your Tunnel] → Add Public Hostname"
echo ""
echo "Example:"
echo "  Subdomain:      myssh"
echo "  Domain:         mydomain.com"
echo "  Type:           SSH"
echo "  URL:            http://localhost:22"
echo ""

# Ask for subdomain and domain separately
read -p "🔤 Enter the subdomain (e.g. myssh): " SUBDOMAIN
read -p "🔤 Enter the domain (e.g. mydomain.com): " DOMAIN

# Strip whitespace just in case
SUBDOMAIN=$(echo "$SUBDOMAIN" | xargs)
DOMAIN=$(echo "$DOMAIN" | xargs)
FULL_HOSTNAME="${SUBDOMAIN}.${DOMAIN}"

echo ""
echo "🧪 Test it!:"
echo ""
echo "Install cloudflared on your local machine (https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/): "
echo ""
echo "Then run this to make sure you can login:"
echo ""
echo "  ssh -o ProxyCommand='cloudflared access ssh --hostname $FULL_HOSTNAME' root@$BOX_IP"
echo ""
echo "📌 To make this permanent, add the following to your ~/.ssh/config:"
echo ""
echo "Host $SUBDOMAIN"
echo "  HostName $BOX_IP"
echo "  User root"
echo "  ProxyCommand cloudflared access ssh --hostname $FULL_HOSTNAME"
echo ""
echo "Then you can just:"
echo "  ssh $SUBDOMAIN"
echo ""
echo "⚠️⚠️⚠️ Test the above before continuing with lockdown! Make sure it logs you into your box! ⚠️⚠️⚠️"
read -p " (Enter to continue)"

echo ""
echo "⚠️ Cloudflare tunnel setup complete. Steps below this modify UFW and SSH configs, and are only recommended if this is a new server."
echo ""
read -p "🔒 Continue with system lockdown? (y/n): " CONTINUE_LOCKDOWN
[[ $CONTINUE_LOCKDOWN != "y" ]] && echo "🧊 Exiting without system lockdown." && exit 0

echo "🔐 Starting system lockdown..."

# 🔓 Collect allowed SSH IPs
echo ""
echo "We'll now lock out down access to the machine with UFW."
echo ""
echo "⚠️ As a backup you might want to still be able to SSH (without cloudflared) from your home or work IP."
echo "➡️  Add IPs allowed direct SSH access into this machine (e.g. home, office, VPN)."
echo "Press Enter without input to finish."
echo ""
echo "Use this command to get IP of your local machine. You can use -6 if it has not IPV4 IP."
echo ""
echo "  curl -s -4 https://ifconfig.co"
echo ""

ALLOWED_IPS=("$@")  # Load optional IPs from script args

if [[ ${#ALLOWED_IPS[@]} -gt 0 ]]; then
  echo "✅ Currently allowed IPs from args: ${ALLOWED_IPS[*]} (already added, do not add below)"
fi

echo ""

# Prompt for more
first_prompt=true
while true; do
  if [ "$first_prompt" = true ]; then
    read -p "Allow direct SSH from IP (home/work)? (add a single IP or leave blank to finish): " ip
    first_prompt=false
  else
    read -p "Another IP to allow? (leave blank to finish): " ip
  fi
  [[ -z "$ip" ]] && break
  ALLOWED_IPS+=("$ip")
done

# Check if UFW is installed
if ! command -v ufw &> /dev/null; then
  echo "📦 Installing UFW..."
  apt update && apt install -y ufw
fi


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

# 🛠 Extra: Allow SSH from loopback and server’s own public IP
# this is needed for installing coolify.
echo "➡️  Allowing SSH from 127.0.0.1 and ::1..."
ufw allow from 127.0.0.1 to any port 22 proto tcp
ufw allow from ::1 to any port 22 proto tcp

if [[ -n "$IPV4" ]]; then
  echo "➡️  Allowing SSH from $IPV4 (public IPv4)..."
  ufw allow from "$IPV4" to any port 22 proto tcp
fi

if [[ -n "$IPV6" ]]; then
  echo "➡️  Allowing SSH from $IPV6 (public IPv6)..."
  ufw allow from "$IPV6" to any port 22 proto tcp
fi


echo ""
echo "📋 Current UFW status (Hint: ask an LLM to explain it to you):"
ufw status verbose || echo "⚠️  UFW not active or failed to report status."

echo ""
read -p " Next we'll install unattended-upgrades (Enter to continue)"
echo ""

# ✨ Harden system
if ! dpkg -s unattended-upgrades apt-listchanges >/dev/null 2>&1; then
  echo "📦 Installing unattended-upgrades and apt-listchanges..."
  apt update && apt install -y unattended-upgrades apt-listchanges
else
  echo "✅ unattended-upgrades and apt-listchanges already installed."
fi

echo "➡️  Enabling automatic security updates..."
dpkg-reconfigure -f noninteractive unattended-upgrades

echo ""
read -p " Next we'll install fail2ban. This prevents multiple brute force SSH login attempts (Enter to continue)"
echo ""

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

# Backup SSH config
echo "📑 Backing up SSH config..."
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)

echo "➡️  Hardening SSH config..."
sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config


echo
read -p "🔁 Restart SSH service now? You'll likely be logged out (y/n): " RESTART
if [[ "$RESTART" == "y" ]]; then

  # Verify SSH config before restarting
  if ! sshd -t; then
    echo "❌❌❌ SSH config is invalid. Reverting changes..."
    cp /etc/ssh/sshd_config.bak.* /etc/ssh/sshd_config
    exit 1
  fi

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
  echo ""
  echo "🔐 Check fail2ban status with: sudo fail2ban-client status. You should see an sshd jail."
  echo ""
  echo "⚠️  Reminder: Docker can expose ports directly, bypassing UFW. Check nmap often."
  echo ""
  echo "⚠️  Reminder: Security is your responsibility! Run the Security check tests above!"
  echo "Don't rely solely on some guy from the internet who made this script. Do your own research!"

  echo ""
  echo ""
  echo "Restarting SSH in 3 seconds..."
  echo "✅ Lockdown complete"
  echo ""
  echo "reminder: log back in with "
  echo ""
  echo "  cloudflared access ssh --hostname $FULL_HOSTNAME' root@$BOX_IP"
  echo ""
  echo "or if you set up your local SSH config (preferred)"
  echo ""
  echo "  ssh $SUBDOMAIN"
  echo ""
  echo "Coolify is an amazing way to manage resources like Docker on your server."
  echo "To install it with this Cloudflared configuration, run this on your remote:"
  echo ""
  echo "wget -O stayfrosty_coolify.sh https://raw.githubusercontent.com/TheRoccoB/cloudflared-vps-lockdown/master/stayfrosty_coolify.sh && chmod +x stayfrosty_coolify.sh && ./stayfrosty_coolify.sh"
  echo ""
  echo "❄️ Stay frosty."

  sleep 3
  systemctl restart ssh
else
  echo "⚠️  SSH config changes will take effect after manual restart (systemctl restart ssh)."
fi