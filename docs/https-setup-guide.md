# Setting Up HTTPS with HAProxy + Let's Encrypt

> **Goal:** Enable HTTPS on your NutriTrack platform using Let's Encrypt certificates terminated at HAProxy. This permanently fixes the Keycloak cookie issue and makes everything production-ready.

## How It Works

```
Browser (HTTPS :443)
    ↓
HAProxy (SSL Termination)
    ↓ adds X-Forwarded-Proto: https
Envoy Gateway (HTTP :30416)
    ↓
Keycloak / Headlamp / APIs
```

HAProxy handles all the SSL/TLS complexity. Your Kubernetes services stay on HTTP internally — nothing changes inside the cluster.

---

## Step 1: Stop HAProxy Temporarily

Certbot needs port 80 to verify your domain. Stop HAProxy briefly:

```bash
sudo systemctl stop haproxy
```

---

## Step 2: Install Certbot

```bash
sudo apt update
sudo apt install -y certbot
```

---

## Step 3: Get the SSL Certificate

You need a **wildcard certificate** so it covers all your subdomains (`keycloak.dev.`, `headlamp.dev.`, `api.dev.`, etc.).

### Option A: DNS Challenge (Recommended for Wildcard)

```bash
sudo certbot certonly --manual --preferred-challenges dns \
  -d "*.dev.nutritrack360.in" \
  -d "dev.nutritrack360.in"
```

**What happens:**
1. Certbot will show you a TXT record value.
2. Go to your DNS provider (Route53, Cloudflare, etc.).
3. Create a TXT record:
   - **Name:** `_acme-challenge.dev.nutritrack360.in`
   - **Value:** (the string certbot shows you)
4. Wait 30-60 seconds for DNS propagation.
5. Press Enter in the terminal.
6. Certbot verifies and downloads the certificate.

### Option B: Standalone (If you only need specific subdomains)

```bash
sudo certbot certonly --standalone \
  -d "keycloak.dev.nutritrack360.in" \
  -d "headlamp.dev.nutritrack360.in" \
  -d "api.dev.nutritrack360.in" \
  -d "dev.nutritrack360.in"
```

This uses HTTP challenge on port 80 (that's why we stopped HAProxy).

---

## Step 4: Create the Combined PEM for HAProxy

HAProxy needs the certificate and private key in a **single file**:

```bash
sudo mkdir -p /etc/haproxy/certs

sudo cat \
  /etc/letsencrypt/live/dev.nutritrack360.in/fullchain.pem \
  /etc/letsencrypt/live/dev.nutritrack360.in/privkey.pem \
  | sudo tee /etc/haproxy/certs/dev.nutritrack360.in.pem > /dev/null

sudo chmod 600 /etc/haproxy/certs/dev.nutritrack360.in.pem
```

---

## Step 5: Update HAProxy Configuration

Replace your `/etc/haproxy/haproxy.cfg` with:

```haproxy
global
        log /dev/log    local0
        log /dev/log    local1 notice
        chroot /var/lib/haproxy
        stats socket /run/haproxy/admin.sock mode 660 level admin
        stats timeout 30s
        user haproxy
        group haproxy
        daemon

        # Default SSL material locations
        ca-base /etc/ssl/certs
        crt-base /etc/ssl/private

        ssl-default-bind-ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384
        ssl-default-bind-ciphersuites TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256
        ssl-default-bind-options ssl-min-ver TLSv1.2 no-tls-tickets

defaults
        log     global
        mode    http
        option  httplog
        option  dontlognull
        timeout connect 5000
        timeout client  50000
        timeout server  50000
        errorfile 400 /etc/haproxy/errors/400.http
        errorfile 403 /etc/haproxy/errors/403.http
        errorfile 408 /etc/haproxy/errors/408.http
        errorfile 500 /etc/haproxy/errors/500.http
        errorfile 502 /etc/haproxy/errors/502.http
        errorfile 503 /etc/haproxy/errors/503.http
        errorfile 504 /etc/haproxy/errors/504.http

# ── HTTP Frontend (Redirect everything to HTTPS) ────────────────
frontend http_front
    bind *:80
    stats uri /haproxy?stats

    # Redirect all HTTP traffic to HTTPS
    http-request redirect scheme https unless { ssl_fc }

# ── HTTPS Frontend (SSL Termination) ────────────────────────────
frontend https_front
    bind *:443 ssl crt /etc/haproxy/certs/dev.nutritrack360.in.pem

    # Tell backend services the original protocol was HTTPS
    http-request set-header X-Forwarded-Proto https

    # Tell backend services the original port was 443
    http-request set-header X-Forwarded-Port 443

    default_backend nutritrack_gateway_backend

# ── Backend (Envoy Gateway NodePort) ────────────────────────────
backend nutritrack_gateway_backend
    balance roundrobin
    server node1 172.31.30.217:30416 check
    server node2 172.31.7.75:30416 check
```

### What Changed:
| Before | After |
|--------|-------|
| Only port 80 | Port 80 redirects to 443 |
| No SSL | SSL termination with Let's Encrypt cert |
| No forwarded headers | `X-Forwarded-Proto: https` sent to Envoy |

---

## Step 6: Validate and Restart HAProxy

```bash
# Check the config for syntax errors
sudo haproxy -c -f /etc/haproxy/haproxy.cfg

# If it says "Configuration file is valid", start it:
sudo systemctl start haproxy
sudo systemctl status haproxy
```

---

## Step 7: Update Keycloak to Use HTTPS

Now that HAProxy terminates TLS, update the Keycloak CR hostname to use `https://`:

Change `infrastructure/keycloak/templates/keycloak-cr.yaml`:
```yaml
hostname:
  hostname: https://keycloak.dev.nutritrack360.in
```

Push to Git. Keycloak will restart and generate all URLs with `https://`. The `Secure` cookies will now work because the browser IS on HTTPS!

---

## Step 8: Update Headlamp OIDC URLs

Update `infrastructure/headlamp/templates/deployment.yaml` — change the OIDC issuer URL to HTTPS:
```yaml
- "-oidc-idp-issuer-url=https://keycloak.dev.nutritrack360.in/realms/nutritrack"
```

---

## Step 9: Test Everything

1. Open **Incognito window**
2. Go to `https://keycloak.dev.nutritrack360.in/admin`
3. You should see the **Keycloak login page** (no cookie error!)
4. Log in with your admin credentials

---

## Step 10: Auto-Renew Certificate

Let's Encrypt certs expire every 90 days. Set up auto-renewal:

```bash
# Create a renewal script
sudo tee /etc/letsencrypt/renewal-hooks/post/haproxy.sh << 'EOF'
#!/bin/bash
cat /etc/letsencrypt/live/dev.nutritrack360.in/fullchain.pem \
    /etc/letsencrypt/live/dev.nutritrack360.in/privkey.pem \
    > /etc/haproxy/certs/dev.nutritrack360.in.pem
systemctl reload haproxy
EOF

sudo chmod +x /etc/letsencrypt/renewal-hooks/post/haproxy.sh

# Test the renewal (dry run)
sudo certbot renew --dry-run
```

Certbot's systemd timer will automatically renew and reload HAProxy. Zero maintenance!

---

## Troubleshooting

**"Cannot bind socket" on port 443**
Make sure your EC2 Security Group allows inbound port 443 (HTTPS).

**Certificate verification failed**
The DNS TXT record might not have propagated. Wait 2-3 minutes and try again.

**Keycloak still shows cookie error**
Make sure you updated the hostname to `https://` and the pod has restarted:
```bash
kubectl delete pod nutritrack-keycloak-0 -n nutritrack-dev
```
