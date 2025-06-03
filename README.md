# ❄️ Stay Frosty

**Cloudflare tunnel setup + SSH hardening + full VPS lockdown + Bonus Coolify Setup**

So you got a shiny new VPS and you don't want to get pwned? Want to install services and have them available to the internet? Don't want to expose your origin IP?

This script may be a good start.

One liner for your remote Ubuntu / Debian:
```bash
wget -O stayfrosty.sh https://raw.githubusercontent.com/TheRoccoB/cloudflared-vps-lockdown/master/stayfrosty.sh && chmod +x stayfrosty.sh && ./stayfrosty.sh
```

After completing this wizard, the script will ask you if you want to create a secure Coolify setup under Cloudflared.
* This is totally optional, and the first script assumes nothing about Coolify. Once you have your tunnel set up, you can run:
```bash
wget -O stayfrosty_coolify.sh https://raw.githubusercontent.com/TheRoccoB/cloudflared-vps-lockdown/master/stayfrosty_coolify.sh && chmod +x stayfrosty_coolify.sh && ./stayfrosty_coolify.sh
```
This will likely work even if you didn't do the first step, but I highly recommend hardening your fresh VPS first.

After completing the wizards I highly recommend adding Cloudflare Access in front (especially cloudflared SSH access and any admin dashboards like Coolify). 
* Here's a quick guide: [Cloudflare Access Guide](CloudflareAccess.md).

## Prerequisites

* Free (or paid) cloudflare account with a custom domain attached.
* A new VPS instance (DigitalOcean Droplet, Hetzner Cloud, etc).
* Cloudflared not installed yet on remote (ideally, uninstall, stop services first, if existing install).
* You can log in from your local box `ssh root@<server-ip>` with SSH keys (not password).
* Your local machine needs [cloudflared installed](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/).

## What it does
The main script, stayfrosty.sh:
* Helps you configure Cloudflare tunnels to access your server via a URL like ssh.mydomain.com.
* Enables exposure of additional access to services (docker, etc) to the internet while still hiding your origin IP.
* Works on Ubuntu and Debian
* Is tested on Digital Ocean and Hetzner Cloud. 
  * It should work elsewhere, but make sure to check your security afterwards. Script gives you good verification commands.

After Cloudflare SSH tunneling is set up, you're prompted to proceed with the following:
* UFW to block all direct ports to the server.
* Allowlists direct SSH access for IP's that you select, like your (home, office, etc)
* Installs fail2ban (prevents SSH brute force attacks)
* Enables automatic security updates on the OS.
* Gives a login warning (MOTD) that when a reboot is required.
* Tells you how to run nmap to scan your server for open ports.

*Feedback welcomed in case I missed something.*

## Existing Setups
The script should be safe to run on an existing setup without Cloudflared installed. It will prompt before closing down UFW ports and modifying SSH.

## Running from Local

Install from a local box, allowing your home IP direct SSH access as a fallback. Set `SERVER_IP`: 

```
SERVER_IP=<your_server_ip>
```

Then run:

```
HOME_IP=$(curl -s -4 https://ifconfig.co || curl -s -6 https://ifconfig.co)
ssh -t root@$SERVER_IP "bash -c 'wget -O /root/stayfrosty.sh https://raw.githubusercontent.com/TheRoccoB/cloudflared-vps-lockdown/master/stayfrosty.sh && chmod +x /root/stayfrosty.sh && /root/stayfrosty.sh $HOME_IP'"
```

You can leave home IP blank if you don't want fallback direct SSH access.

## Running from Remote
```
wget -O stayfrosty.sh https://raw.githubusercontent.com/TheRoccoB/cloudflared-vps-lockdown/master/stayfrosty.sh
chmod +x stayfrosty.sh
./stayfrosty.sh
```

## Gotcha's

### Coolify
* Connecting a domain to your tunnel for your coolify admin panel can be quite tricky (stayfrosty_coolify.sh). Here's a [troubleshooting guide](CoolifyTroubleshooting.md).

### Docker

Docker likes to sometimes bypass UFW firewall with ip_tables or something. Run the following commands to check your server anytime you fire up a new service:

```
# top 1000 ports
nmap -Pn -T4 <server-ip> 

# all ports (slow)
nmap -Pn -p- -T4 <server-ip>
```

## If you messed up

These scripts are designed to be pretty resilient if you need to run them more than once.

## Referral links
If you haven't gotten a VPS yet, here are some referral links that help me too.

* [Digital Ocean](https://m.do.co/c/294e41c860d1): $200 to use in 60d
* [Hostinger](https://www.hostinger.com/referral?REFERRALCODE=9NVROCCOBJNO) Extra % off typical deals + free months.
* Hetzner: Just sign up I don't have a code yet ;-).

Note: I haven't tried on Hostinger yet.

## 🧊 Stay frosty.
