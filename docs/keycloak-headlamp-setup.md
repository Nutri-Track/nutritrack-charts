# Keycloak & Headlamp — Manual Deployment Guide

> **Project:** NutriTrack · **Environment:** Dev  
> **Domain:** `dev.nutritrack360.in`  
> **Date:** April 2026

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Prerequisites](#2-prerequisites)
3. [DNS Configuration](#3-dns-configuration)
4. [Part A — Keycloak Deployment](#4-part-a--keycloak-deployment)
5. [Part B — Headlamp Deployment](#5-part-b--headlamp-deployment)
6. [Part C — Keycloak Realm & Client Setup](#6-part-c--keycloak-realm--client-setup)
7. [Part D — Integrating Headlamp with Keycloak OIDC](#7-part-d--integrating-headlamp-with-keycloak-oidc)
8. [Part E — Integrating Grafana with Keycloak OIDC](#8-part-e--integrating-grafana-with-keycloak-oidc)
9. [Part F — Integrating ArgoCD with Keycloak OIDC](#9-part-f--integrating-argocd-with-keycloak-oidc)
10. [Verification & Troubleshooting](#10-verification--troubleshooting)
11. [File Reference](#11-file-reference)

---

## 1. Architecture Overview

```
                         ┌─────────────────────────┐
                         │    Envoy Gateway         │
                         │  (nutritrack-gateway)    │
                         │    namespace:            │
                         │    nutritrack-dev         │
                         └─────┬──────┬──────┬──────┘
                               │      │      │
              ┌────────────────┤      │      ├────────────────┐
              │                │      │      │                │
              ▼                ▼      ▼      ▼                ▼
  keycloak.dev.           dev.   grafana.dev.  argocd.dev.  headlamp.dev.
  nutritrack360.in   nutritrack360.in  ...        ...    nutritrack360.in
              │                │      │      │                │
              ▼                ▼      ▼      ▼                ▼
     ┌────────────┐   ┌──────────┐  ...    ...     ┌────────────┐
     │  Keycloak  │   │ Frontend │                  │  Headlamp  │
     │  ns:       │   │ ns:      │                  │  ns:       │
     │  keycloak  │   │ nutritrack│                  │  headlamp  │
     │  :8080     │   │ -dev     │                  │  :4466     │
     └────────────┘   └──────────┘                  └────────────┘
```

**Routing Pattern:**  
Each tool gets its own subdomain and namespace. The `nutritrack-gateway` in `nutritrack-dev` namespace has `allowedRoutes.namespaces.from: All`, so HTTPRoutes in any namespace can attach to it.

| Subdomain | Namespace | Service | Port |
|---|---|---|---|
| `keycloak.dev.nutritrack360.in` | `keycloak` | `keycloak` | 8080 |
| `headlamp.dev.nutritrack360.in` | `headlamp` | `headlamp` | 4466 |
| `grafana.dev.nutritrack360.in` | `monitoring` | `nutritrack-monitoring-grafana` | 80 |
| `argocd.dev.nutritrack360.in` | `argocd` | `argocd-server` | 80 |
| `dev.nutritrack360.in` | `nutritrack-dev` | `frontend` | 3000 |

---

## 2. Prerequisites

- [x] Kubernetes cluster access with `kubectl` configured
- [x] Envoy Gateway / kgateway controller installed
- [x] `nutritrack-gateway` running in `nutritrack-dev` namespace
- [x] DNS subdomain `keycloak.dev.nutritrack360.in` pointing to gateway IP
- [x] DNS subdomain `headlamp.dev.nutritrack360.in` pointing to gateway IP

---

## 3. DNS Configuration

Both subdomains must resolve to the **same external IP** as your Envoy Gateway.

```bash
# Find your gateway external IP
kubectl get svc -n nutritrack-dev | grep nutritrack-gateway
```

Add **A records** (or CNAME if using cloud LB) in your DNS provider:

| Record Type | Hostname | Value |
|---|---|---|
| A | `keycloak.dev.nutritrack360.in` | `<GATEWAY_EXTERNAL_IP>` |
| A | `headlamp.dev.nutritrack360.in` | `<GATEWAY_EXTERNAL_IP>` |

> **Note:** If you use Cloudflare, set proxy status to **DNS only** (grey cloud) to avoid WebSocket/header issues with Keycloak.

---

## 4. Part A — Keycloak Deployment

### 4.1 Manifests Location

```
infrastructure/keycloak/
├── Chart.yaml
└── templates/
    ├── namespace.yaml      # Namespace: keycloak
    ├── secret.yaml         # Admin credentials
    ├── deployment.yaml     # Keycloak 25.0 (start-dev mode)
    ├── service.yaml        # ClusterIP :8080
    └── httproute.yaml      # HTTPRoute → keycloak.dev.nutritrack360.in
```

### 4.2 Update the Admin Password

> ⚠️ **IMPORTANT:** Before deploying, edit `infrastructure/keycloak/templates/secret.yaml` and change the default password.

```yaml
stringData:
  KEYCLOAK_ADMIN: "admin"
  KEYCLOAK_ADMIN_PASSWORD: "YOUR_SECURE_PASSWORD_HERE"   # ← CHANGE THIS
```

### 4.3 Deploy Keycloak (step-by-step)

```bash
# Step 1 — Create the namespace
kubectl apply -f infrastructure/keycloak/templates/namespace.yaml

# Step 2 — Create the admin secret
kubectl apply -f infrastructure/keycloak/templates/secret.yaml

# Step 3 — Deploy Keycloak
kubectl apply -f infrastructure/keycloak/templates/deployment.yaml

# Step 4 — Create the Service
kubectl apply -f infrastructure/keycloak/templates/service.yaml

# Step 5 — Create the HTTPRoute
kubectl apply -f infrastructure/keycloak/templates/httproute.yaml
```

Or apply everything at once:

```bash
kubectl apply -f infrastructure/keycloak/templates/
```

### 4.4 Verify Keycloak is Running

```bash
# Check pod status (wait for READY 1/1)
kubectl get pods -n keycloak -w

# Check logs
kubectl logs -n keycloak -l app=keycloak -f

# Check the service
kubectl get svc -n keycloak

# Check the HTTPRoute is attached to the gateway
kubectl get httproute -n keycloak
```

### 4.5 Access Keycloak

Once the pod is `Running` and the HTTPRoute is accepted:

```
http://keycloak.dev.nutritrack360.in
```

Admin console:

```
http://keycloak.dev.nutritrack360.in/admin
```

Login with the credentials from your secret.

### 4.6 Key Configuration Explained

| Env Variable | Value | Purpose |
|---|---|---|
| `KC_HOSTNAME` | `keycloak.dev.nutritrack360.in` | Sets the public hostname for cookies & token issuer URLs |
| `KC_HOSTNAME_STRICT` | `false` | Allows requests from any hostname (dev flexibility) |
| `KC_HOSTNAME_STRICT_HTTPS` | `false` | Allows HTTP access (dev mode) |
| `KC_PROXY_HEADERS` | `xforwarded` | Trusts X-Forwarded-\* headers from Envoy Gateway |
| `KC_HTTP_ENABLED` | `true` | Enables HTTP listener |
| `KC_HEALTH_ENABLED` | `true` | Enables /health/ready and /health/live endpoints |

> **Why no cookie issues?**  
> By setting `KC_HOSTNAME=keycloak.dev.nutritrack360.in`, Keycloak sets cookies for the correct domain. Since both the app (`dev.nutritrack360.in`) and Keycloak (`keycloak.dev.nutritrack360.in`) share the parent domain `dev.nutritrack360.in`, OIDC flows work seamlessly without cookie rejection.

---

## 5. Part B — Headlamp Deployment

### 5.1 Manifests Location

```
infrastructure/headlamp/
├── Chart.yaml
└── templates/
    ├── namespace.yaml      # Namespace: headlamp
    ├── rbac.yaml           # ServiceAccount + ClusterRoleBinding
    ├── deployment.yaml     # Headlamp v0.25.0 (in-cluster mode)
    ├── service.yaml        # ClusterIP :4466
    └── httproute.yaml      # HTTPRoute → headlamp.dev.nutritrack360.in
```

### 5.2 Deploy Headlamp (step-by-step)

```bash
# Step 1 — Create the namespace
kubectl apply -f infrastructure/headlamp/templates/namespace.yaml

# Step 2 — Create RBAC (ServiceAccount + ClusterRoleBinding)
kubectl apply -f infrastructure/headlamp/templates/rbac.yaml

# Step 3 — Deploy Headlamp
kubectl apply -f infrastructure/headlamp/templates/deployment.yaml

# Step 4 — Create the Service
kubectl apply -f infrastructure/headlamp/templates/service.yaml

# Step 5 — Create the HTTPRoute
kubectl apply -f infrastructure/headlamp/templates/httproute.yaml
```

Or apply everything at once:

```bash
kubectl apply -f infrastructure/headlamp/templates/
```

### 5.3 Verify Headlamp is Running

```bash
# Check pod status
kubectl get pods -n headlamp -w

# Check logs
kubectl logs -n headlamp -l app=headlamp -f

# Check the service
kubectl get svc -n headlamp

# Check the HTTPRoute
kubectl get httproute -n headlamp
```

### 5.4 Access Headlamp

```
http://headlamp.dev.nutritrack360.in
```

**Initial Login (Token-based):**

Headlamp by default requires a ServiceAccount token. Generate one:

```bash
# Create a token for the headlamp ServiceAccount
kubectl create token headlamp -n headlamp --duration=24h
```

Copy the token and paste it into the Headlamp login screen.

> **Note:** This token-based login is temporary. Section 7 covers setting up OIDC login via Keycloak so users can log in with username/password.

---

## 6. Part C — Keycloak Realm & Client Setup

After Keycloak is running, configure it for NutriTrack.

### 6.1 Create the NutriTrack Realm

1. Go to `http://keycloak.dev.nutritrack360.in/admin`
2. Login with admin credentials
3. Click the dropdown in the top-left (shows "master")
4. Click **Create Realm**
5. Set:
   - **Realm name:** `nutritrack`
   - **Enabled:** ON
6. Click **Create**

### 6.2 Create a Headlamp OIDC Client

1. In the `nutritrack` realm, go to **Clients** → **Create client**
2. **General Settings:**
   - **Client type:** OpenID Connect
   - **Client ID:** `headlamp`
   - Click **Next**
3. **Capability Config:**
   - **Client authentication:** ON (confidential client)
   - **Authorization:** OFF
   - **Authentication flow:** ✅ Standard flow, ✅ Direct access grants
   - Click **Next**
4. **Login Settings:**
   - **Root URL:** `http://headlamp.dev.nutritrack360.in`
   - **Home URL:** `http://headlamp.dev.nutritrack360.in`
   - **Valid redirect URIs:** `http://headlamp.dev.nutritrack360.in/*`
   - **Valid post logout redirect URIs:** `http://headlamp.dev.nutritrack360.in/*`
   - **Web origins:** `http://headlamp.dev.nutritrack360.in`
   - Click **Save**
5. Go to the **Credentials** tab → copy the **Client Secret** (you'll need it later)

### 6.3 Create a Grafana OIDC Client

1. Go to **Clients** → **Create client**
2. **General Settings:**
   - **Client ID:** `grafana`
   - Click **Next**
3. **Capability Config:**
   - **Client authentication:** ON
   - Click **Next**
4. **Login Settings:**
   - **Root URL:** `http://grafana.dev.nutritrack360.in`
   - **Valid redirect URIs:** `http://grafana.dev.nutritrack360.in/*`
   - **Web origins:** `http://grafana.dev.nutritrack360.in`
   - Click **Save**
5. Copy the **Client Secret** from the Credentials tab.

### 6.4 Create an ArgoCD OIDC Client

1. Go to **Clients** → **Create client**
2. **General Settings:**
   - **Client ID:** `argocd`
   - Click **Next**
3. **Capability Config:**
   - **Client authentication:** ON
   - Click **Next**
4. **Login Settings:**
   - **Root URL:** `http://argocd.dev.nutritrack360.in`
   - **Valid redirect URIs:** `http://argocd.dev.nutritrack360.in/*`
   - **Web origins:** `http://argocd.dev.nutritrack360.in`
   - Click **Save**
5. Copy the **Client Secret** from the Credentials tab.

### 6.5 Create Users

1. In the `nutritrack` realm, go to **Users** → **Add user**
2. Set:
   - **Username:** `nutritrack-admin`
   - **Email:** `admin@nutritrack360.in`
   - **First Name / Last Name:** as desired
   - **Email verified:** ON
3. Click **Create**
4. Go to the **Credentials** tab → **Set password**
   - Enter a password
   - **Temporary:** OFF
   - Click **Save**

### 6.6 Create Realm Roles

1. Go to **Realm roles** → **Create role**
2. Create these roles:
   - `admin` — Full access
   - `developer` — Development access
   - `viewer` — Read-only access
3. Assign roles to users via **Users** → select user → **Role mapping** → **Assign role**

---

## 7. Part D — Integrating Headlamp with Keycloak OIDC

After creating the Keycloak client for Headlamp, update the Headlamp deployment to use OIDC.

### 7.1 Create the OIDC Secret

```bash
kubectl create secret generic headlamp-oidc-secret \
  -n headlamp \
  --from-literal=clientID=headlamp \
  --from-literal=clientSecret=YOUR_CLIENT_SECRET_FROM_KEYCLOAK
```

> Replace `YOUR_CLIENT_SECRET_FROM_KEYCLOAK` with the actual secret copied from Keycloak (Section 6.2 Step 5).

### 7.2 Update Headlamp Deployment

Edit `infrastructure/headlamp/templates/deployment.yaml` and update the `args` section:

```yaml
args:
  - "-in-cluster"
  - "-plugins-dir=/headlamp/plugins"
  - "-oidc-client-id=headlamp"
  - "-oidc-client-secret=$(OIDC_CLIENT_SECRET)"
  - "-oidc-idp-issuer-url=http://keycloak.dev.nutritrack360.in/realms/nutritrack"
  - "-oidc-scopes=openid,profile,email"
```

Add environment variable to the container:

```yaml
env:
  - name: OIDC_CLIENT_SECRET
    valueFrom:
      secretKeyRef:
        name: headlamp-oidc-secret
        key: clientSecret
```

### 7.3 Re-apply the Deployment

```bash
kubectl apply -f infrastructure/headlamp/templates/deployment.yaml
```

### 7.4 Verify OIDC Login

1. Open `http://headlamp.dev.nutritrack360.in`
2. You should see a **"Sign in with OIDC"** button
3. Click it → redirected to Keycloak login → login → redirected back to Headlamp

---

## 8. Part E — Integrating Grafana with Keycloak OIDC

### 8.1 Update Grafana Helm Values

Add the following to your `kube-prometheus-stack` values (in `argocd-apps/infra/kube-prometheus-stack.yaml` or wherever Grafana is configured):

```yaml
grafana:
  grafana.ini:
    server:
      root_url: http://grafana.dev.nutritrack360.in
    auth.generic_oauth:
      enabled: true
      name: Keycloak
      allow_sign_up: true
      client_id: grafana
      client_secret: YOUR_GRAFANA_CLIENT_SECRET
      scopes: openid profile email
      auth_url: http://keycloak.dev.nutritrack360.in/realms/nutritrack/protocol/openid-connect/auth
      token_url: http://keycloak.dev.nutritrack360.in/realms/nutritrack/protocol/openid-connect/token
      api_url: http://keycloak.dev.nutritrack360.in/realms/nutritrack/protocol/openid-connect/userinfo
      role_attribute_path: "contains(realm_access.roles[*], 'admin') && 'Admin' || 'Viewer'"
```

### 8.2 Sync Grafana

```bash
# If using ArgoCD, trigger a sync:
argocd app sync nutritrack-monitoring
# Or manually restart Grafana:
kubectl rollout restart deployment -n monitoring nutritrack-monitoring-grafana
```

---

## 9. Part F — Integrating ArgoCD with Keycloak OIDC

### 9.1 Update ArgoCD ConfigMap

```bash
kubectl edit configmap argocd-cm -n argocd
```

Add:

```yaml
data:
  url: http://argocd.dev.nutritrack360.in
  oidc.config: |
    name: Keycloak
    issuer: http://keycloak.dev.nutritrack360.in/realms/nutritrack
    clientID: argocd
    clientSecret: YOUR_ARGOCD_CLIENT_SECRET
    requestedScopes:
      - openid
      - profile
      - email
```

### 9.2 Update ArgoCD RBAC

```bash
kubectl edit configmap argocd-rbac-cm -n argocd
```

Add:

```yaml
data:
  policy.csv: |
    g, /admin, role:admin
    g, /developer, role:readonly
  scopes: '[roles]'
```

### 9.3 Restart ArgoCD

```bash
kubectl rollout restart deployment argocd-server -n argocd
```

---

## 10. Verification & Troubleshooting

### 10.1 Quick Health Check

```bash
echo "=== Keycloak ==="
kubectl get pods,svc,httproute -n keycloak

echo ""
echo "=== Headlamp ==="
kubectl get pods,svc,httproute -n headlamp

echo ""
echo "=== HTTPRoutes Status ==="
kubectl get httproute -A
```

### 10.2 Test Endpoints

```bash
# Keycloak health
curl -s http://keycloak.dev.nutritrack360.in/health/ready

# Keycloak realm info (after realm creation)
curl -s http://keycloak.dev.nutritrack360.in/realms/nutritrack/.well-known/openid-configuration | head -5

# Headlamp
curl -s -o /dev/null -w "%{http_code}" http://headlamp.dev.nutritrack360.in/
```

### 10.3 Common Issues

#### Keycloak pod stuck in CrashLoopBackOff
```bash
kubectl logs -n keycloak -l app=keycloak --tail=50
# Common cause: OOM → increase memory limits
# Common cause: Port conflict → check if 8080 is free
```

#### HTTPRoute not routing traffic
```bash
# Verify the route is accepted by the gateway
kubectl describe httproute keycloak-route -n keycloak
# Check parentRef status — should show "Accepted: True"

# Verify gateway allows cross-namespace routes
kubectl describe gateway nutritrack-gateway -n nutritrack-dev
# Look for: allowedRoutes.namespaces.from: All
```

#### Keycloak cookie/CORS issues
```
If you see "invalid_redirect_uri" or cookie errors:
1. Ensure KC_HOSTNAME is exactly: keycloak.dev.nutritrack360.in
2. Ensure KC_PROXY_HEADERS is set to: xforwarded
3. Check that the client's Valid Redirect URIs include your app URL
4. Verify KC_HOSTNAME_STRICT_HTTPS is false (for HTTP dev)
```

#### Headlamp OIDC redirect loop
```
1. Ensure the Keycloak client redirect URIs match exactly
2. Check that the issuer URL is reachable FROM the headlamp pod:
   kubectl exec -n headlamp deploy/headlamp -- \
     wget -qO- http://keycloak.keycloak.svc.cluster.local:8080/realms/nutritrack
3. If issuer URL uses external hostname, ensure DNS resolves inside the cluster
```

### 10.4 Useful Debug Commands

```bash
# Port-forward to Keycloak directly (bypass gateway)
kubectl port-forward -n keycloak svc/keycloak 8080:8080

# Port-forward to Headlamp directly
kubectl port-forward -n headlamp svc/headlamp 4466:4466

# Check gateway listeners
kubectl get gateway nutritrack-gateway -n nutritrack-dev -o yaml

# List ALL httproutes across all namespaces
kubectl get httproute -A -o wide
```

---

## 11. File Reference

### Keycloak Manifests

| File | Purpose |
|---|---|
| `infrastructure/keycloak/Chart.yaml` | Helm chart metadata |
| `infrastructure/keycloak/templates/namespace.yaml` | Creates `keycloak` namespace |
| `infrastructure/keycloak/templates/secret.yaml` | Admin credentials (change before deploy!) |
| `infrastructure/keycloak/templates/deployment.yaml` | Keycloak 25.0 Deployment |
| `infrastructure/keycloak/templates/service.yaml` | ClusterIP Service on port 8080 |
| `infrastructure/keycloak/templates/httproute.yaml` | HTTPRoute for `keycloak.dev.nutritrack360.in` |

### Headlamp Manifests

| File | Purpose |
|---|---|
| `infrastructure/headlamp/Chart.yaml` | Helm chart metadata |
| `infrastructure/headlamp/templates/namespace.yaml` | Creates `headlamp` namespace |
| `infrastructure/headlamp/templates/rbac.yaml` | ServiceAccount + ClusterRoleBinding |
| `infrastructure/headlamp/templates/deployment.yaml` | Headlamp v0.25.0 Deployment |
| `infrastructure/headlamp/templates/service.yaml` | ClusterIP Service on port 4466 |
| `infrastructure/headlamp/templates/httproute.yaml` | HTTPRoute for `headlamp.dev.nutritrack360.in` |

---

## Quick Deploy Cheatsheet

```bash
# ── Deploy Keycloak ──────────────────────────────────────────────
kubectl apply -f infrastructure/keycloak/templates/

# ── Deploy Headlamp ──────────────────────────────────────────────
kubectl apply -f infrastructure/headlamp/templates/

# ── Verify everything ───────────────────────────────────────────
kubectl get pods -n keycloak
kubectl get pods -n headlamp
kubectl get httproute -A

# ── Generate Headlamp login token ────────────────────────────────
kubectl create token headlamp -n headlamp --duration=24h

# ── Access ───────────────────────────────────────────────────────
# Keycloak:  http://keycloak.dev.nutritrack360.in/admin
# Headlamp:  http://headlamp.dev.nutritrack360.in
```

---

> **Next Steps:**  
> 1. Deploy Keycloak and Headlamp using the commands above  
> 2. Create the `nutritrack` realm in Keycloak (Section 6)  
> 3. Configure OIDC clients for Headlamp, Grafana, and ArgoCD  
> 4. Update Headlamp deployment with OIDC args (Section 7)  
> 5. Optionally migrate Keycloak to PostgreSQL backend for production  
