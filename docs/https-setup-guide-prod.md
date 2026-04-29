# Production HTTPS Setup Guide with HAProxy & Let's Encrypt

> **Goal:** Enable HTTPS for the **Production** NutriTrack platform using Let's Encrypt certificates terminated at HAProxy.

## How It Works

```
Browser (HTTPS :443)
    ↓
HAProxy (SSL Termination)
    ↓ adds X-Forwarded-Proto: https
Envoy Gateway (HTTP :32565)
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

You need a **wildcard certificate** so it covers all your subdomains for production (`keycloak.nutritrack360.in`, `api.nutritrack360.in`, etc.).

```bash
sudo certbot certonly --manual --preferred-challenges dns \
  -d "*.nutritrack360.in" \
  -d "nutritrack360.in"
```

**Certbot will show you a TXT record value.** Now add it to GoDaddy:

### Adding the TXT Record in GoDaddy

1. Log into [GoDaddy DNS Management](https://dcc.godaddy.com/manage/) for `nutritrack360.in`
2. Click **DNS** → **DNS Records**
3. Click **Add New Record**
4. Fill in:

| Field | Value |
|-------|-------|
| **Type** | TXT |
| **Name** | `_acme-challenge` |
| **Value** | *(paste the string certbot gave you)* |
| **TTL** | 600 (or lowest available) |

> **Important:** The Name is just `_acme-challenge` — GoDaddy automatically appends `.nutritrack360.in`

5. Click **Save**
6. **Wait 2-3 minutes** for DNS propagation

> **Note:** Certbot may ask for TWO TXT records (one for `*.nutritrack360.in` and one for `nutritrack360.in`). If so, add BOTH with the **same Name** (`_acme-challenge`) but **different Values**. GoDaddy allows multiple TXT records with the same name.

### Verify Before Pressing Enter

From your EC2 terminal, check if the TXT record has propagated:

```bash
dig TXT _acme-challenge.nutritrack360.in +short
```

If you see your value in the output, go back to certbot and **press Enter**.

If `dig` shows nothing, wait another minute and try again. GoDaddy's TTL can be slow.

---

## Step 4: Create the Combined PEM for HAProxy

HAProxy needs the certificate and private key in a **single file**:

```bash
sudo mkdir -p /etc/haproxy/certs

sudo cat \
  /etc/letsencrypt/live/nutritrack360.in/fullchain.pem \
  /etc/letsencrypt/live/nutritrack360.in/privkey.pem \
  | sudo tee /etc/haproxy/certs/nutritrack360.in.pem > /dev/null

sudo chmod 600 /etc/haproxy/certs/nutritrack360.in.pem
```

---

## Step 5: Update HAProxy Configuration

Replace your `/etc/haproxy/haproxy.cfg` with the following configuration (updated for your production nodes and port `32565`):

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

        # See: https://ssl-config.mozilla.org/#server=haproxy&server-version=2.0.3&config=intermediate
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
    bind *:443 ssl crt /etc/haproxy/certs/nutritrack360.in.pem

    # Tell backend services the original protocol was HTTPS
    http-request set-header X-Forwarded-Proto https

    # Tell backend services the original port was 443
    http-request set-header X-Forwarded-Port 443

    default_backend nutritrack_gateway_backend

# ── Backend (Envoy Gateway NodePort) ────────────────────────────
backend nutritrack_gateway_backend
    balance roundrobin
    server node1 172.31.9.44:32565 check
   # server node2 172.31.7.75:32565 check
```

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

## Step 7: Update Keycloak to Use HTTPS (Production)

Now that HAProxy terminates TLS, update the Keycloak CR hostname in your prod namespace to use `https://`:

Update your production keycloak config (e.g., `infrastructure/keycloak/templates/keycloak-cr.yaml` or via values):
```yaml
hostname:
  hostname: https://keycloak.nutritrack360.in
```

Push to Git. Keycloak will restart and generate all URLs with `https://`.

---

## Step 8: Update Headlamp OIDC URLs (Production)

Update Headlamp's configuration for production — change the OIDC issuer URL to HTTPS:
```yaml
- "-oidc-idp-issuer-url=https://keycloak.nutritrack360.in/realms/nutritrack"
```

---

## Step 9: Test Everything

1. Open an **Incognito window**
2. Go to `https://keycloak.nutritrack360.in/admin` (or your relevant base URL)
3. You should see the **Keycloak login page** safely served over HTTPS.

---

## Step 10: Auto-Renew Certificate

Let's Encrypt certs expire every 90 days. Set up auto-renewal:

```bash
# Create a renewal script
sudo tee /etc/letsencrypt/renewal-hooks/post/haproxy.sh << 'EOF'
#!/bin/bash
cat /etc/letsencrypt/live/nutritrack360.in/fullchain.pem \
    /etc/letsencrypt/live/nutritrack360.in/privkey.pem \
    > /etc/haproxy/certs/nutritrack360.in.pem
systemctl reload haproxy
EOF

sudo chmod +x /etc/letsencrypt/renewal-hooks/post/haproxy.sh

# Test the renewal (dry run)
sudo certbot renew --dry-run
```

Certbot's systemd timer will automatically renew and reload HAProxy. Zero maintenance!
