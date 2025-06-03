# Stay Frosty: Coolify + Cloudflared domain troubleshooting

If you ran the stayfrosty_coolify script and your custom domain is still not attaching, here are some things to check:

If you're getting an infinite redirect loop:
* Be certain that your coolify URL in the <host_ip>/settings dash is set to http://mycoolify.mydomain.com, Not HTTPS!

But the above might not work in all cases. For instance, when installing Ghost, the main page will load up fine, but it
may point to http:// url's internally (mixed content error). If this happens, a workaround is to edit your server's 
proxy and add the following lines under the `command` section:

```
- '--entrypoints.http.address=:80' #existing
- '--entrypoints.http.forwardedHeaders.insecure=true' # ADD THIS 
- '--entrypoints.https.address=:443' # existing
- '--entrypoints.https.forwardedHeaders.insecure=true' # ADD THIS
```

Save and restart proxy. Possibly restart the app (ie: ghost) too.

*"forwardedHeaders.insecure=true" is fine if Traefik is firewall-locked so that only Cloudflare Tunnel (or other trusted proxy) can connect.*

*Otherwise, a malicious client can set X-Forwarded-Proto: https (or fake their IP) and fool Traefik and your backend services into trusting a non-TLS or unauthorized request.*

If you're getting SSL errors
* In cloudflare dash, SSL => set to full (not full strict)

If certain assets are not loading (typically CSS)
* In cloudflare dash SSL => Edge certificates
   * Always use HTTPS
   * Automatic HTTPS rewrites on.

If you're getting stale assets
* Make sure the coolify resources are not set to cache everything in cloudflare dash.