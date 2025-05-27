# Stay Frosty: Coolify + Cloudflared domain troubleshooting

If you ran the stayfrosty_coolify script and your custom domain is still not attaching, here are some things to check:

If you're getting an infinite redirect loop:
* Be certain that your coolify URL in the <host_ip>/settings dash is set to http://mycoolify.mydomain.com, Not HTTPS!

If you're getting SSL errors
* In cloudflare dash, SSL => set to full (not full strict)

If certain assets are not loading (typically CSS)
* In cloudflare dash SSL => Edge certificates
   * Always use HTTPS
   * Automatic HTTPS rewrites on.

If you're getting stale assets
* Make sure the coolify resources are not set to cache everything in cloudflare dash.