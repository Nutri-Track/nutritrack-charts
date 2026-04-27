# Keycloak & Headlamp — End-to-End Setup Guide

> **NutriTrack Platform · Identity & Access Management + Kubernetes Dashboard**

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Prerequisites](#2-prerequisites)
3. [DNS Configuration](#3-dns-configuration)
4. [Keycloak Deployment](#4-keycloak-deployment)
   - 4.1 [PostgreSQL Database Provisioning](#41-postgresql-database-provisioning)
   - 4.2 [Create & Seal the Keycloak Secret](#42-create--seal-the-keycloak-secret)
   - 4.3 [Update the PostgreSQL SealedSecret](#43-update-the-postgresql-sealedsecret)
   - 4.4 [Helm Chart Structure](#44-helm-chart-structure)
   - 4.5 [ArgoCD Application](#45-argocd-application)
5. [Keycloak Post-Deployment Configuration](#5-keycloak-post-deployment-configuration)
   - 5.1 [Verify the Deployment](#51-verify-the-deployment)
   - 5.2 [Realm & Client Configuration](#52-realm--client-configuration)
   - 5.3 [Update Client Secrets](#53-update-client-secrets)
6. [Headlamp Deployment](#6-headlamp-deployment)
   - 6.1 [Helm Chart Structure](#61-helm-chart-structure)
   - 6.2 [ArgoCD Application](#62-argocd-application)
7. [OIDC Integration Matrix](#7-oidc-integration-matrix)
   - 7.1 [Headlamp ↔ Keycloak](#71-headlamp--keycloak)
   - 7.2 [Grafana ↔ Keycloak](#72-grafana--keycloak)
   - 7.3 [ArgoCD ↔ Keycloak](#73-argocd--keycloak)
   - 7.4 [NutriTrack Frontend ↔ Keycloak](#74-nutritrack-frontend--keycloak)
8. [Network & Routing Architecture](#8-network--routing-architecture)
9. [Troubleshooting](#9-troubleshooting)
10. [Security Considerations](#10-security-considerations)

---

## 1. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        Envoy Gateway (port 80)                         │
│   ┌──────────────┐ ┌──────────────┐ ┌──────────────┐ ┌──────────────┐ │
│   │ keycloak.    │ │ headlamp.    │ │ grafana.     │ │ argocd.      │ │
│   │ dev.nutri    │ │ dev.nutri    │ │ dev.nutri    │ │ dev.nutri    │ │
│   │ track360.in  │ │ track360.in  │ │ track360.in  │ │ track360.in  │ │
│   └──────┬───────┘ └──────┬───────┘ └──────┬───────┘ └──────┬───────┘ │
└──────────┼────────────────┼────────────────┼────────────────┼──────────┘
           │                │                │                │
   ┌───────▼────────┐ ┌────▼─────────┐ ┌────▼──────┐ ┌──────▼───────┐
   │   Keycloak     │ │   Headlamp   │ │  Grafana  │ │  ArgoCD      │
   │  (ns: keycloak)│ │ (ns:headlamp)│ │(monitoring)│ │ (ns: argocd) │
   └───────┬────────┘ └──────────────┘ └───────────┘ └──────────────┘
           │ OIDC ▲         │ OIDC           │ OIDC        │ OIDC
           │      └─────────┴────────────────┴─────────────┘
           │
   ┌───────▼────────┐
   │  PostgreSQL    │
   │(nutritrack-dev)│
   │  keycloak_db   │
   └────────────────┘
```

**Key design decisions:**
- **Dedicated subdomain** (`keycloak.dev.nutritrack360.in`) eliminates cookie collisions between Keycloak and the main application.
- **Keycloak in its own namespace** (`keycloak`) isolates IAM workloads.
- **Headlamp in its own namespace** (`headlamp`) with a dedicated ServiceAccount.
- **Shared PostgreSQL** — Keycloak gets its own database (`keycloak_db`) on the existing PostgreSQL StatefulSet, avoiding the need for a second database deployment.
- **GitOps-first** — Realm configuration is declared in a ConfigMap and auto-imported on first boot.

---

## 2. Prerequisites

| Requirement | Version / Details |
|---|---|
| Kubernetes Cluster | 1.28+ with Gateway API CRDs |
| Envoy Gateway | Already deployed with `kgateway` GatewayClass |
| ArgoCD | Running in `argocd` namespace |
| Sealed Secrets Controller | Running in `kube-system` namespace |
| `kubeseal` CLI | Installed on your workstation |
| `kubectl` | Configured with cluster access |
| PostgreSQL | StatefulSet running in `nutritrack-dev` |
| DNS access | Ability to create A/CNAME records for `*.dev.nutritrack360.in` |

---

## 3. DNS Configuration

Create the following DNS records pointing to your **Envoy Gateway LoadBalancer IP**:

```bash
# Get the external IP of the Gateway
kubectl get svc -n envoy-gateway-system

# Or check your Gateway resource
kubectl get gateway nutritrack-gateway -n nutritrack-dev -o jsonpath='{.status.addresses[0].value}'
```

| Subdomain | Type | Value |
|---|---|---|
| `keycloak.dev.nutritrack360.in` | A / CNAME | `<Gateway External IP>` |
| `headlamp.dev.nutritrack360.in` | A / CNAME | `<Gateway External IP>` |

> **Note:** If you already have a wildcard record (`*.dev.nutritrack360.in`) pointing to the Gateway, these subdomains will resolve automatically.

---

## 4. Keycloak Deployment

### 4.1 PostgreSQL Database Provisioning

The existing PostgreSQL init job (`infrastructure/postgresql/templates/job-db-init.yaml`) has been updated to create the Keycloak database automatically:

```sql
-- Created automatically by the db-init Job:
CREATE DATABASE keycloak_db;
CREATE ROLE keycloak_user WITH LOGIN PASSWORD '<from-secret>';
GRANT ALL PRIVILEGES ON DATABASE keycloak_db TO keycloak_user;
```

The init script (`infrastructure/postgresql/templates/configmap.yaml`) now includes:

```bash
create_db_and_user "keycloak_db" "keycloak_user" "$KEYCLOAK_USER_PASSWORD"
```

The NetworkPolicy has also been updated to allow cross-namespace access from the `keycloak` namespace to PostgreSQL.

### 4.2 Create & Seal the Keycloak Secret

The Keycloak deployment requires admin credentials stored in a SealedSecret.

**Step 1: Create the plain Secret YAML:**

```bash
cat <<EOF > /tmp/keycloak-secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: keycloak-secret
  namespace: keycloak
type: Opaque
stringData:
  KEYCLOAK_ADMIN_USERNAME: admin
  KEYCLOAK_ADMIN_PASSWORD: "<YOUR-STRONG-PASSWORD>"
EOF
```

**Step 2: Seal it with kubeseal:**

```bash
kubeseal --format yaml \
  --controller-name sealed-secrets-controller \
  --controller-namespace kube-system \
  < /tmp/keycloak-secret.yaml \
  > infrastructure/keycloak/templates/keycloak-sealed-secret.yaml
```

**Step 3: Clean up the plain secret:**

```bash
rm /tmp/keycloak-secret.yaml
```

> ⚠️ **IMPORTANT:** Never commit the plain secret file. Only the SealedSecret YAML should be pushed to Git.

### 4.3 Update the PostgreSQL SealedSecret

The PostgreSQL SealedSecret needs a new key: `KEYCLOAK_USER_PASSWORD`.

**Step 1: Create a new plain secret with ALL keys (including the new one):**

```bash
cat <<EOF > /tmp/postgresql-secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: postgresql-secret
  namespace: nutritrack-dev
type: Opaque
stringData:
  POSTGRES_USER: postgres
  POSTGRES_PASSWORD: "<your-existing-postgres-password>"
  AUTH_USER_PASSWORD: "<your-existing-auth-password>"
  FOOD_USER_PASSWORD: "<your-existing-food-password>"
  MACRO_USER_PASSWORD: "<your-existing-macro-password>"
  COMPLIANCE_USER_PASSWORD: "<your-existing-compliance-password>"
  KEYCLOAK_USER_PASSWORD: "<NEW-keycloak-db-password>"
EOF
```

**Step 2: Re-seal the entire secret:**

```bash
kubeseal --format yaml \
  --controller-name sealed-secrets-controller \
  --controller-namespace kube-system \
  < /tmp/postgresql-secret.yaml \
  > infrastructure/postgresql/templates/postgresql-sealed-secret.yaml
```

**Step 3: Clean up:**

```bash
rm /tmp/postgresql-secret.yaml
```

### 4.4 Helm Chart Structure

```
infrastructure/keycloak/
├── Chart.yaml
└── templates/
    ├── namespace.yaml                 # Dedicated 'keycloak' namespace
    ├── deployment.yaml                # Keycloak 26.0 (Quarkus) Deployment
    ├── service.yaml                   # ClusterIP Service (port 8080)
    ├── keycloak-httproute.yaml        # HTTPRoute → keycloak.dev.nutritrack360.in
    ├── keycloak-sealed-secret.yaml    # SealedSecret (admin credentials)
    └── realm-configmap.yaml           # Auto-imported realm definition
```

**Key configuration in `values.yaml`:**

```yaml
keycloak:
  name: keycloak
  namespace: keycloak
  hostname: keycloak.dev.nutritrack360.in
  secretName: keycloak-secret
  image:
    repository: quay.io/keycloak/keycloak
    tag: "26.0"
    pullPolicy: IfNotPresent
  replicas: 1
  port: 8080
  database:
    name: keycloak_db
    username: keycloak_user
  resources:
    requests:
      cpu: "250m"
      memory: "512Mi"
    limits:
      cpu: "1000m"
      memory: "1Gi"
```

**Deployment highlights:**
- Uses `KC_PROXY_HEADERS=xforwarded` for proper operation behind Envoy Gateway proxy
- Uses `KC_HOSTNAME=keycloak.dev.nutritrack360.in` so Keycloak generates correct redirect URIs
- `KC_HTTP_ENABLED=true` (TLS termination happens at the Gateway level)
- `--import-realm` flag auto-imports the realm from the mounted ConfigMap
- Health probes use Keycloak's built-in `/health/ready`, `/health/live`, `/health/started` endpoints
- Startup probe with `failureThreshold: 30` gives Keycloak up to ~2.5 minutes to start (it's a heavy Java app)

### 4.5 ArgoCD Application

File: `argocd-apps/infra/keycloak.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: nutritrack-keycloak
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  project: nutritrack
  source:
    repoURL: https://github.com/Nutri-Track/nutritrack-charts.git
    targetRevision: develop
    path: infrastructure/keycloak
    helm:
      valueFiles:
        - ../../values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: keycloak
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

---

## 5. Keycloak Post-Deployment Configuration

### 5.1 Verify the Deployment

```bash
# Check pod status
kubectl get pods -n keycloak

# Watch logs for startup progress
kubectl logs -n keycloak -l app=keycloak -f

# Check the HTTPRoute
kubectl get httproute -n keycloak

# Test connectivity
curl -s http://keycloak.dev.nutritrack360.in/health/ready
# Expected: {"status": "UP", ...}
```

**Expected pod startup timeline:**
1. `wait-for-db` init container runs (~5-10s)
2. Keycloak container starts (~60-120s for first boot with realm import)
3. `startupProbe` passes → pod becomes `Running`
4. `readinessProbe` passes → pod receives traffic

### 5.2 Realm & Client Configuration

On first boot, Keycloak auto-imports the `nutritrack` realm from the ConfigMap, which includes:

| Client ID | Type | Purpose |
|---|---|---|
| `nutritrack-app` | Public | Frontend SPA (PKCE flow) |
| `grafana` | Confidential | Grafana OIDC SSO |
| `argocd` | Confidential | ArgoCD OIDC SSO |
| `headlamp` | Confidential | Headlamp OIDC SSO |

**Roles defined:**
| Role | Description |
|---|---|
| `admin` | Full platform administration |
| `user` | Standard user (default for new registrations) |

### 5.3 Update Client Secrets

After first boot, you **must** regenerate the client secrets for confidential clients via the Keycloak Admin Console:

1. Navigate to `http://keycloak.dev.nutritrack360.in`
2. Login with the admin credentials from the SealedSecret
3. Go to **Realm: nutritrack → Clients**
4. For each confidential client (`grafana`, `argocd`, `headlamp`):
   - Click the client → **Credentials** tab
   - Click **Regenerate** to get a new secret
   - Copy the secret and update the corresponding integration configuration

> ⚠️ The placeholder secrets (`CHANGE_ME_*`) in the realm ConfigMap are only used for initial import. Keycloak will generate proper secrets when you regenerate them.

---

## 6. Headlamp Deployment

### 6.1 Helm Chart Structure

```
infrastructure/headlamp/
├── Chart.yaml
└── templates/
    ├── namespace.yaml              # Dedicated 'headlamp' namespace
    ├── rbac.yaml                   # ServiceAccount + ClusterRoleBinding
    ├── deployment.yaml             # Headlamp Deployment with OIDC args
    ├── service.yaml                # ClusterIP Service (port 4466)
    └── headlamp-httproute.yaml     # HTTPRoute → headlamp.dev.nutritrack360.in
```

**Key configuration in `values.yaml`:**

```yaml
headlamp:
  name: headlamp
  namespace: headlamp
  hostname: headlamp.dev.nutritrack360.in
  image:
    repository: ghcr.io/headlamp-k8s/headlamp
    tag: "latest"
    pullPolicy: Always
  replicas: 1
  port: 4466
  oidc:
    enabled: true
    clientId: headlamp
    clientSecret: CHANGE_ME_HEADLAMP_CLIENT_SECRET  # Update after Keycloak setup
  resources:
    requests:
      cpu: "100m"
      memory: "128Mi"
    limits:
      cpu: "300m"
      memory: "256Mi"
```

**Deployment details:**
- Runs with `-in-cluster` flag using a ServiceAccount with `cluster-admin` binding
- When `oidc.enabled: true`, passes OIDC flags:
  - `-oidc-client-id=headlamp`
  - `-oidc-client-secret=<from-values>`
  - `-oidc-idp-issuer-url=http://keycloak.dev.nutritrack360.in/realms/nutritrack`
  - `-oidc-scopes=openid,profile,email`
  - `-base-url=http://headlamp.dev.nutritrack360.in`

### 6.2 ArgoCD Application

File: `argocd-apps/infra/headlamp.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: nutritrack-headlamp
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "1"  # Deploys AFTER Keycloak
spec:
  project: nutritrack
  source:
    repoURL: https://github.com/Nutri-Track/nutritrack-charts.git
    targetRevision: develop
    path: infrastructure/headlamp
    helm:
      valueFiles:
        - ../../values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: headlamp
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

---

## 7. OIDC Integration Matrix

### 7.1 Headlamp ↔ Keycloak

**Configuration:** Handled via deployment args (already configured in `values.yaml`).

After Keycloak is running:
1. Go to Keycloak Admin → `nutritrack` realm → Clients → `headlamp`
2. Go to **Credentials** → **Regenerate** the client secret
3. Update `values.yaml`:

```yaml
headlamp:
  oidc:
    clientSecret: "<regenerated-secret-from-keycloak>"
```

4. Push to Git → ArgoCD will auto-sync

### 7.2 Grafana ↔ Keycloak

Update the kube-prometheus-stack ArgoCD Application values (`argocd-apps/infra/kube-prometheus-stack.yaml`):

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
      client_secret: "<regenerated-secret-from-keycloak>"
      scopes: openid profile email
      auth_url: http://keycloak.dev.nutritrack360.in/realms/nutritrack/protocol/openid-connect/auth
      token_url: http://keycloak.dev.nutritrack360.in/realms/nutritrack/protocol/openid-connect/token
      api_url: http://keycloak.dev.nutritrack360.in/realms/nutritrack/protocol/openid-connect/userinfo
      role_attribute_path: contains(realm_access.roles[*], 'admin') && 'Admin' || 'Viewer'
```

### 7.3 ArgoCD ↔ Keycloak

Apply this configuration to your ArgoCD ConfigMap (`argocd-cm`):

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cm
  namespace: argocd
data:
  url: http://argocd.dev.nutritrack360.in
  oidc.config: |
    name: Keycloak
    issuer: http://keycloak.dev.nutritrack360.in/realms/nutritrack
    clientID: argocd
    clientSecret: "<regenerated-secret-from-keycloak>"
    requestedScopes: ["openid", "profile", "email"]
```

And the RBAC policy in `argocd-rbac-cm`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-rbac-cm
  namespace: argocd
data:
  policy.csv: |
    g, admin, role:admin
    g, user, role:readonly
  policy.default: role:readonly
```

### 7.4 NutriTrack Frontend ↔ Keycloak

The `nutritrack-app` client is configured as a **public client** (no client secret needed). Use the PKCE flow in your frontend:

```javascript
// Example configuration for keycloak-js or oidc-client-ts
const oidcConfig = {
  authority: 'http://keycloak.dev.nutritrack360.in/realms/nutritrack',
  client_id: 'nutritrack-app',
  redirect_uri: 'http://dev.nutritrack360.in/callback',
  post_logout_redirect_uri: 'http://dev.nutritrack360.in/',
  scope: 'openid profile email',
  response_type: 'code',  // Authorization Code + PKCE
};
```

---

## 8. Network & Routing Architecture

### HTTPRoutes Summary

| Route Name | Namespace | Hostname | Backend Service | Port |
|---|---|---|---|---|
| `keycloak-route` | `keycloak` | `keycloak.dev.nutritrack360.in` | `keycloak` | 8080 |
| `headlamp-route` | `headlamp` | `headlamp.dev.nutritrack360.in` | `headlamp` | 4466 |
| `grafana-route` | `monitoring` | `grafana.dev.nutritrack360.in` | `nutritrack-monitoring-grafana` | 80 |
| `argocd-route` | `argocd` | `argocd.dev.nutritrack360.in` | `argocd-server` | 80 |
| `nutritrack-apis` | `nutritrack-dev` | `dev.nutritrack360.in` | Various APIs | Various |
| `nutritrack-frontend` | `nutritrack-dev` | `dev.nutritrack360.in` | `frontend` | 3000 |

### Cookie Isolation Strategy

By using **dedicated subdomains** for each service:
- `keycloak.dev.nutritrack360.in` — Keycloak session cookies stay here
- `headlamp.dev.nutritrack360.in` — Headlamp session cookies stay here
- `dev.nutritrack360.in` — Application cookies stay here

This prevents **cookie collisions** where services might overwrite each other's cookies due to sharing the same domain. Each service gets an isolated cookie jar.

### NetworkPolicy Changes

The PostgreSQL NetworkPolicy now includes a **cross-namespace rule** allowing the `keycloak` namespace to access the database:

```yaml
# New rule added to postgresql NetworkPolicy
- from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: keycloak
      podSelector:
        matchLabels:
          app: keycloak
  ports:
    - port: 5432
      protocol: TCP
```

---

## 9. Troubleshooting

### Keycloak Pod Not Starting

```bash
# Check events
kubectl describe pod -n keycloak -l app=keycloak

# Common issues:
# 1. DB connection failed → Check NetworkPolicy, PostgreSQL SealedSecret
# 2. Out of memory → Increase memory limits (Keycloak needs ~512Mi minimum)
# 3. Startup probe timeout → Increase failureThreshold
```

### Keycloak Returns 502/503

```bash
# Pod is running but not ready yet (still starting up)
kubectl get pods -n keycloak -w

# Check readiness probe
kubectl logs -n keycloak -l app=keycloak | grep -i "started"
```

### OIDC Callback Errors

```
Error: "redirect_uri_mismatch"
```

**Fix:** Ensure the redirect URI in the Keycloak client configuration exactly matches what the application sends. Check for protocol (http vs https) and trailing slashes.

### Headlamp OIDC Login Fails

```bash
# Verify Keycloak is reachable from within the cluster
kubectl exec -n headlamp deploy/headlamp -- wget -qO- http://keycloak.keycloak.svc.cluster.local:8080/realms/nutritrack/.well-known/openid-configuration

# Check Headlamp logs
kubectl logs -n headlamp -l app=headlamp
```

**Common issue:** If Headlamp is using the external hostname to reach Keycloak, ensure it resolves from inside the cluster. You may need a DNS record or use the internal service URL.

### Database Init Job Fails

```bash
# Check job logs
kubectl logs -n nutritrack-dev job/postgresql-db-init

# Re-run the job (ArgoCD PostSync hook)
kubectl delete job postgresql-db-init -n nutritrack-dev
# ArgoCD will re-create it on next sync
```

### Cookie Issues / Session Conflicts

If you see unexpected logouts or session errors:
1. Clear browser cookies for `*.dev.nutritrack360.in`
2. Verify each service has a **unique subdomain**
3. Check that `KC_HOSTNAME` matches the actual URL being accessed

---

## 10. Security Considerations

### Production Hardening Checklist

- [ ] **Enable TLS** — Add HTTPS listeners to the Gateway with cert-manager
- [ ] **Rotate client secrets** — Replace all `CHANGE_ME_*` placeholders
- [ ] **Restrict Headlamp RBAC** — Replace `cluster-admin` with a custom ClusterRole
- [ ] **Enable brute force protection** — Already enabled in realm config
- [ ] **Set password policies** — Configure in Keycloak Admin Console
- [ ] **Pin Headlamp image tag** — Replace `latest` with a specific version
- [ ] **Enable Keycloak audit logging** — For compliance tracking
- [ ] **Review CORS origins** — Restrict `webOrigins` in Keycloak clients to actual domains only
- [ ] **NetworkPolicy for Headlamp** — Add a NetworkPolicy restricting Headlamp's egress

### Secrets Management

| Secret | Location | Keys |
|---|---|---|
| `postgresql-secret` | `nutritrack-dev` namespace | `KEYCLOAK_USER_PASSWORD` (new) |
| `keycloak-secret` | `keycloak` namespace | `KEYCLOAK_ADMIN_USERNAME`, `KEYCLOAK_ADMIN_PASSWORD` |
| Client secrets | `values.yaml` → `headlamp.oidc.clientSecret` | Update after Keycloak setup |

---

## Deployment Sequence (Quick Reference)

```
1. Create DNS records (keycloak.dev.nutritrack360.in, headlamp.dev.nutritrack360.in)
       ↓
2. Re-seal PostgreSQL secret (add KEYCLOAK_USER_PASSWORD key)
       ↓
3. Create & seal Keycloak admin secret (keycloak-secret)
       ↓
4. Push all changes to 'develop' branch
       ↓
5. ArgoCD auto-syncs:
   a. PostgreSQL db-init Job creates keycloak_db + keycloak_user
   b. Keycloak deploys → imports 'nutritrack' realm
   c. Headlamp deploys → connects to Keycloak OIDC
       ↓
6. Access Keycloak Admin (keycloak.dev.nutritrack360.in)
       ↓
7. Regenerate client secrets for: grafana, argocd, headlamp
       ↓
8. Update values.yaml with real headlamp OIDC client secret
       ↓
9. (Optional) Configure Grafana & ArgoCD OIDC integration
       ↓
10. Verify all services accessible and OIDC login works
```

---

## Files Modified / Created

### New Files

| File | Purpose |
|---|---|
| `infrastructure/keycloak/Chart.yaml` | Keycloak Helm chart metadata |
| `infrastructure/keycloak/templates/namespace.yaml` | `keycloak` namespace |
| `infrastructure/keycloak/templates/deployment.yaml` | Keycloak 26.0 Deployment |
| `infrastructure/keycloak/templates/service.yaml` | ClusterIP Service |
| `infrastructure/keycloak/templates/keycloak-httproute.yaml` | HTTPRoute for subdomain |
| `infrastructure/keycloak/templates/keycloak-sealed-secret.yaml` | Admin credentials (placeholder) |
| `infrastructure/keycloak/templates/realm-configmap.yaml` | Realm import definition |
| `infrastructure/headlamp/Chart.yaml` | Headlamp Helm chart metadata |
| `infrastructure/headlamp/templates/namespace.yaml` | `headlamp` namespace |
| `infrastructure/headlamp/templates/deployment.yaml` | Headlamp Deployment with OIDC |
| `infrastructure/headlamp/templates/service.yaml` | ClusterIP Service |
| `infrastructure/headlamp/templates/rbac.yaml` | ServiceAccount + ClusterRoleBinding |
| `infrastructure/headlamp/templates/headlamp-httproute.yaml` | HTTPRoute for subdomain |
| `argocd-apps/infra/keycloak.yaml` | ArgoCD Application for Keycloak |
| `argocd-apps/infra/headlamp.yaml` | ArgoCD Application for Headlamp |
| `docs/keycloak-headlamp-setup.md` | This documentation |

### Modified Files

| File | Change |
|---|---|
| `values.yaml` | Added `keycloak` and `headlamp` config blocks; added `keycloak` to PostgreSQL network policy allowlist |
| `infrastructure/postgresql/templates/configmap.yaml` | Added `keycloak_db` creation to init script |
| `infrastructure/postgresql/templates/job-db-init.yaml` | Added `KEYCLOAK_USER_PASSWORD` env var |
| `infrastructure/postgresql/templates/networkpolicy.yaml` | Added cross-namespace rule for keycloak namespace |
