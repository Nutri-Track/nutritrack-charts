# Flawless NutriTrack IAM & Dashboard Setup (Operator & GitOps)

> **Goal:** Deploy Keycloak connected to PostgreSQL with Automated OIDC Setup for Headlamp using the GitOps pattern.

This guide explains the perfect architecture we've built using the **Keycloak Operator**. Everything is fully automated:
- **Persistence:** Keycloak connects to your existing PostgreSQL (`postgresql-0`).
- **DB Init:** A Kubernetes Job automatically creates the `keycloak` Postgres user and database.
- **SSO Setup:** A `KeycloakRealmImport` automatically provisions the `nutritrack` Realm, the Admin user, and the OIDC Client for Headlamp.
- **Zero Configuration:** Headlamp boots up and instantly logs you in securely via Keycloak.

---

## Step 1: Install the Keycloak Operator (Manual Prerequisite)

Because you are using ArgoCD to manage Custom Resources (like `kind: Keycloak`), the Kubernetes cluster needs to "learn" what a Keycloak resource is *before* ArgoCD tries to deploy it. 

You must install the Keycloak Operator **cluster-wide** manually just once:

```bash
# 1. Install the Custom Resource Definitions (CRDs)
kubectl apply -f https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/25.0.0/kubernetes/keycloaks.k8s.keycloak.org-v1.yml
kubectl apply -f https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/25.0.0/kubernetes/keycloakrealmimports.k8s.keycloak.org-v1.yml

# 2. Deploy the Operator
kubectl apply -f https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/25.0.0/kubernetes/kubernetes.yml
```

Verify the operator is running:
```bash
kubectl get pods -n default -l app=keycloak-operator
```

---

## Step 2: Push Your Code to Git

We have created the ArgoCD Application definitions (`argocd-apps/infra/keycloak.yaml` and `headlamp.yaml`) and the infrastructure charts. 

1. Add everything to Git.
2. Commit: `git commit -m "feat: Perfect Operator-based Keycloak & Headlamp"`
3. Push to `develop`.

---

## Step 3: Watch ArgoCD Do the Magic

Because your `app-of-apps` monitors `argocd-apps/`, ArgoCD will automatically pick up the new Keycloak and Headlamp applications!

Here is exactly what ArgoCD will do in order:

### 1. Database Initialization
ArgoCD deploys the `keycloak-db-init` Job.
- It spins up a temporary Alpine container.
- It connects to `postgresql-0.postgresql.nutritrack-dev`.
- It safely runs `CREATE USER keycloak` and `CREATE DATABASE keycloak_db`.
- *Result:* Postgres is fully prepared.

### 2. The Keycloak Custom Resource
ArgoCD deploys the `Keycloak` YAML.
- The Keycloak Operator notices this.
- The Operator spins up Keycloak `25.0`, sets up the JDBC connection to Postgres, and configures the `edge` proxy and `keycloak.dev.nutritrack360.in` hostname safely.
- *Result:* Keycloak is live on Postgres!

### 3. The Realm Import Custom Resource
ArgoCD deploys the `KeycloakRealmImport` YAML.
- The Keycloak Operator instantly configures the `nutritrack` realm.
- It creates the `nutritrack-admin` user.
- It creates the `headlamp` OIDC Client with the secret `headlamp-oidc-secure-secret-2026`.
- *Result:* Zero manual UI clicking required!

### 4. Headlamp Deployment
ArgoCD deploys Headlamp into the `headlamp` namespace.
- It passes the OIDC Client Secret directly into the pod.
- *Result:* Headlamp is locked behind SSO.

---

## Step 4: Access Your Apps

Ensure your DNS is set to point to your Envoy Gateway IP:
- `keycloak.dev.nutritrack360.in`
- `headlamp.dev.nutritrack360.in`

### 🛡️ Headlamp Dashboard
1. Go to `http://headlamp.dev.nutritrack360.in`
2. Click **"Sign in with OIDC"**.
3. You will be redirected to Keycloak.
4. Log in with:
   - **Username:** `nutritrack-admin`
   - **Password:** `admin123`
5. You are instantly logged into Headlamp as an Admin!

### 🔑 Keycloak Admin Console
If you ever need to manually tweak Keycloak:
1. Go to `http://keycloak.dev.nutritrack360.in/admin`
2. Log in with the Master Admin:
   - **Username:** `admin`
   - **Password:** `admin_secure_password`
   *(This was defined in the `keycloak-admin-secret`)*

---

## Troubleshooting

**What if ArgoCD says the Keycloak CR is "Out of Sync"?**
Occasionally, Operators modify their own Custom Resources (adding status fields). If ArgoCD complains, you can click "Sync" or ensure `ServerSideApply=true` is set (which we did!).

**What if the Database Job fails?**
Check the job logs: `kubectl logs -n nutritrack-dev job/keycloak-db-init`. It expects the `postgresql-secret` to be present in `nutritrack-dev` with the `POSTGRES_PASSWORD` key.

**How is the "Cookie not found" fixed here?**
In the Operator CR, we set:
```yaml
hostname:
  strict: false
  strictHttps: false
proxy:
  headers: xforwarded
```
This forces Keycloak 25.0 to accept HTTP from Envoy Gateway perfectly.
