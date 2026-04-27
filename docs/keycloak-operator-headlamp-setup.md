# NutriTrack IAM & Dashboard Setup (Keycloak Operator + Manual OIDC)

> **Goal:** Deploy Keycloak (via the Operator) connected to PostgreSQL, then manually configure OIDC for Headlamp through the Keycloak Admin UI.

## Architecture Overview

- **Keycloak** runs in `nutritrack-dev` (same namespace as PostgreSQL) so the NetworkPolicy allows database access automatically.
- **Headlamp** runs in its own `headlamp` namespace.
- The **Keycloak Operator** manages the Keycloak pod, database migrations, and lifecycle.
- OIDC clients and realms are configured **manually via the Keycloak Admin Console** for full control.

---

## Step 1: Install the Keycloak Operator (One-Time Prerequisite)

The cluster needs the Keycloak CRDs before ArgoCD can deploy `kind: Keycloak` resources.

```bash
# Install the CRDs
kubectl apply -f https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/25.0.0/kubernetes/keycloaks.k8s.keycloak.org-v1.yml
kubectl apply -f https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/25.0.0/kubernetes/keycloakrealmimports.k8s.keycloak.org-v1.yml

# Deploy the Operator
kubectl apply -f https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/25.0.0/kubernetes/kubernetes.yml
```

Verify the operator is running:
```bash
kubectl get pods -A -l app=keycloak-operator
```

---

## Step 2: Push Code & Let ArgoCD Deploy

Push to `develop`. ArgoCD will automatically:

1. **Run the DB Init Job** — Creates the `keycloak` Postgres user and `keycloak_db` database inside your existing PostgreSQL.
2. **Deploy Keycloak** — The Operator reads the `Keycloak` CR and spins up a fully configured Keycloak instance connected to Postgres.
3. **Deploy Headlamp** — Deploys the Kubernetes dashboard (OIDC integration is configured but won't work until you complete Step 3).

Monitor the deployment:
```bash
# Watch Keycloak pod
kubectl get pods -n nutritrack-dev -l app=keycloak -w

# Watch Headlamp pod
kubectl get pods -n headlamp -l app=headlamp -w
```

---

## Step 3: Configure OIDC in Keycloak Admin UI

Once Keycloak is running and accessible at `http://keycloak.dev.nutritrack360.in`, follow these steps:

### 3.1 — Log into the Admin Console

1. Go to `http://keycloak.dev.nutritrack360.in/admin`
2. Log in with the **Master Admin** credentials:
   - **Username:** `admin`
   - **Password:** *(the password you set in `keycloak-admin-secret`)*

### 3.2 — Create the `nutritrack` Realm

1. Click the dropdown in the top-left corner (it says **"master"**).
2. Click **"Create realm"**.
3. Set:
   - **Realm name:** `nutritrack`
   - **Enabled:** ON
4. Click **"Create"**.

### 3.3 — Create the Headlamp OIDC Client

1. In the `nutritrack` realm, go to **Clients** → **Create client**.
2. **General Settings:**
   - **Client type:** OpenID Connect
   - **Client ID:** `headlamp`
   - **Name:** Headlamp Kubernetes Dashboard
3. Click **Next**.
4. **Capability Config:**
   - **Client authentication:** ON (this makes it a "confidential" client)
   - **Standard flow:** ON
   - **Direct access grants:** ON
5. Click **Next**.
6. **Login Settings:**
   - **Root URL:** `http://headlamp.dev.nutritrack360.in`
   - **Valid redirect URIs:** `http://headlamp.dev.nutritrack360.in/*`
   - **Web origins:** `http://headlamp.dev.nutritrack360.in`
7. Click **Save**.

### 3.4 — Copy the Client Secret

1. Go to the **Credentials** tab of the `headlamp` client.
2. Copy the **Client secret** value.
3. You will need this for the Headlamp deployment (see Step 4).

### 3.5 — Create a User

1. Go to **Users** → **Add user**.
2. Set:
   - **Username:** `nutritrack-admin`
   - **Email:** `admin@nutritrack360.in`
   - **Email verified:** ON
   - **First name:** Admin
   - **Last name:** User
3. Click **Create**.
4. Go to the **Credentials** tab → **Set password**.
5. Enter a password, set **Temporary** to OFF, and click **Save**.

---

## Step 4: Update Headlamp with the OIDC Secret

After you copy the **Client secret** from Step 3.4, you need to update the Headlamp secret in your cluster.

### Option A: Update the SealedSecret (GitOps way)

1. Create a new plain secret file locally (do NOT commit this):
   ```yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: headlamp-oidc-secret
     namespace: headlamp
   type: Opaque
   stringData:
     clientID: "headlamp"
     clientSecret: "<PASTE_THE_SECRET_FROM_STEP_3.4>"
   ```
2. Seal it:
   ```bash
   kubeseal --format=yaml < secret.yaml > infrastructure/headlamp/templates/sealed-secret.yaml
   ```
3. Commit and push the updated `sealed-secret.yaml`.
4. Delete the plain `secret.yaml` file.

### Option B: Quick Manual Override (for testing)

```bash
kubectl delete secret headlamp-oidc-secret -n headlamp
kubectl create secret generic headlamp-oidc-secret \
  -n headlamp \
  --from-literal=clientID=headlamp \
  --from-literal=clientSecret="<PASTE_THE_SECRET_FROM_STEP_3.4>"

# Restart Headlamp to pick up the new secret
kubectl rollout restart deployment/headlamp -n headlamp
```

---

## Step 5: Access Your Apps

### 🔑 Keycloak Admin Console
- **URL:** `http://keycloak.dev.nutritrack360.in/admin`
- **Realm:** Switch to `nutritrack` after login

### 🛡️ Headlamp Dashboard
1. Go to `http://headlamp.dev.nutritrack360.in`
2. Click **"Sign in with OIDC"**
3. You will be redirected to Keycloak
4. Log in with the user you created in Step 3.5
5. You are now logged into Headlamp via SSO!

---

## File Structure

```
infrastructure/
├── keycloak/
│   ├── Chart.yaml
│   └── templates/
│       ├── sealed-secrets.yaml    # DB + Admin credentials (encrypted)
│       ├── keycloak-cr.yaml       # Keycloak Operator Custom Resource
│       ├── httproute.yaml         # Envoy Gateway routing
│       └── db-init-job.yaml       # Auto-creates keycloak_db in Postgres
├── headlamp/
│   ├── Chart.yaml
│   └── templates/
│       ├── namespace.yaml
│       ├── rbac.yaml              # ServiceAccount + ClusterRoleBinding
│       ├── sealed-secret.yaml     # OIDC client credentials (encrypted)
│       ├── deployment.yaml        # Headlamp with OIDC args
│       └── service-route.yaml     # Service + HTTPRoute
```

---

## Troubleshooting

**ArgoCD says Keycloak CR is "Out of Sync"**
The Operator adds status fields to the CR. This is normal. Ensure `ServerSideApply=true` is set in your ArgoCD Application (it is).

**Database Job fails**
Check the job logs:
```bash
kubectl logs -n nutritrack-dev job/keycloak-db-init
```
It expects the `postgresql-secret` to exist in `nutritrack-dev` with a `POSTGRES_PASSWORD` key.

**"Cookie not found" error**
The Keycloak CR is configured with `hostname.strict: false`, `hostname.strictHttps: false`, and `proxy.headers: xforwarded`. This ensures cookies work correctly behind the Envoy Gateway over HTTP.

**"No healthy upstream" error**
This means Keycloak hasn't passed its readiness probe yet. Wait 60-90 seconds for it to fully boot and initialize the database schema.
