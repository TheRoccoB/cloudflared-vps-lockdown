# Locking down Admin pages + SSH with Cloudflare access

Cloudflare Access provides an additional layer of security by requiring authentication before users can access your SSH server or admin pages. Here's how to set it up:

## Prerequisites

- A Cloudflare account with your domain
- Cloudflare tunnel or proxied dns entry already configured (from the main setup)
- Cloudflare Zero Trust account (free tier available)

## Benefits
- Extra layer of protection for SSH or admin apps.
- Your origin is never even hit until authenticated with cloudflare access.

## Setting up Cloudflare Access

1. Log in to the [Cloudflare Zero Trust Dashboard](https://one.dash.cloudflare.com/)

2. Create an Access Application:
    - Go to **Access** → **Applications** → **Add an application**
    - Select **Self-hosted**
    - Enter a name (e.g., "SSH Access")
    - For the domain, enter your SSH subdomain (e.g., `ssh.yourdomain.com`)

3. Configure Access Policies:
    - Under the **Policies** tab, click **Add a policy**
    - Name your policy  
      - "SSH Authentication (or something more general if you want to use this for a dashboard app like Coolify too)
    - Under **Configure rules**, choose authentication methods:
        - One-time PIN
        - Social login (Google, GitHub, etc.)
        - Corporate identity providers (Okta, Azure AD, etc.)
    - Set additional rules if needed (IP restrictions, device posture, etc.)
    - Click **Save**

## Gotcha
I highly recommend setting up a social login like Github because the email one-time-passwords can be very slow (5-10 min)