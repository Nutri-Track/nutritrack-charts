# NutriTrack — Cloud-Native Microservices Platform on Kubernetes

> A production-grade, security-first nutrition tracking application deployed on a self-managed dual-cluster Kubernetes setup using GitOps, reusable CI pipelines, and a comprehensive observability stack.

---

## Table of Contents

- [Overview](#overview)
- [Application Architecture](#application-architecture)
- [Infrastructure Overview](#infrastructure-overview)
- [Repository Structure](#repository-structure)
- [Kubernetes Architecture](#kubernetes-architecture)
- [Security Architecture](#security-architecture)
- [CI Pipeline — GitHub Actions](#ci-pipeline--github-actions)
- [CD Pipeline — ArgoCD GitOps](#cd-pipeline--argocd-gitops)
- [Observability Stack](#observability-stack)
- [Networking & Routing](#networking--routing)
- [Deployed Applications Reference](#deployed-applications-reference)
- [Sync Waves & Deployment Order](#sync-waves--deployment-order)
- [Configuration Reference](#configuration-reference)
- [Docs](#docs)

---

## Overview

NutriTrack is a microservices-based nutrition tracking platform. Users can log meals, track macronutrients, receive compliance alerts when nutritional targets are missed, and view analytics dashboards through a React frontend.

The project is fully deployed on self-managed Kubernetes clusters using kubeadm, with all delivery automated through a GitOps workflow. Security is implemented at every layer — from supply chain scanning in CI to runtime protection in the cluster.

**Domain:** `dev.nutritrack360.in`

---

## Application Architecture

### Microservices

| Service | Language | Port | Responsibility |
|---|---|---|---|
| `auth-service` | Python (FastAPI) | 8000 | User registration, login, JWT issuance |
| `food-service` | Python (FastAPI) | 8001 | Food logging and lookup |
| `macro-service` | Python (FastAPI) | 8002 | Macronutrient goal tracking |
| `compliance-service` | Python (FastAPI) | 8003 | Nutritional compliance alerts |
| `frontend` | React | 3000 | SPA — consumes all services via API gateway |

### Database

- **PostgreSQL 16 (Alpine)** deployed as a Kubernetes `StatefulSet`
- Persistent storage via NFS (`mongo-nfs-storage` StorageClass), 10Gi PVC
- Each service has its own isolated database (`auth_db`, `food_db`, `macro_db`, `compliance_db`) and dedicated database user
- All credentials managed via Sealed Secrets

### API Routing

All external traffic enters through **Envoy Gateway** using the Kubernetes Gateway API (`HTTPRoute`):

| Path Prefix | Backend Service | Port |
|---|---|---|
| `/api/auth` | `auth-service` | 8000 |
| `/api/food` | `food-service` | 8001 |
| `/api/macro` | `macro-service` | 8002 |
| `/api/compliance` | `compliance-service` | 8003 |
| `/` | `frontend` | 3000 |

---

## Infrastructure Overview

| Component | Technology | Purpose |
|---|---|---|
| Container orchestration | Kubernetes (kubeadm) | Self-managed clusters |
| Load balancer | HAProxy | SSL termination + HA control plane traffic |
| API gateway / Ingress | Envoy Gateway (Gateway API) | Path-based routing to services |
| GitOps engine | ArgoCD | Continuous delivery, self-healing |
| CI | GitHub Actions (reusable workflows) | Build, scan, publish |
| Secrets | Bitnami Sealed Secrets | Encrypted secrets safe for Git |
| Metrics | Prometheus + kube-prometheus-stack v72.6.2 | Cluster and service metrics |
| Logs | Loki v6.30.1 + Promtail v6.16.6 | Log aggregation and querying |
| Dashboards | Grafana (bundled with kube-prometheus-stack) | Metrics and log visualisation |
| K8s UI | Headlamp | Cluster management dashboard |
| Identity provider | Keycloak | OIDC SSO for Headlamp, Grafana, ArgoCD |
| Runtime scanning | Trivy Operator v0.32.1 | Continuous image vulnerability scanning |
| CIS benchmarking | kube-bench (CronJob, hourly) | CIS Kubernetes benchmark compliance |
| SAST | SonarQube | Static code analysis on every PR |
| SCA | Snyk | Dependency vulnerability scanning on every PR |
| Image scanning (CI) | Trivy (GitHub Actions) | Pre-push image vulnerability scanning |
| Email alerting | Brevo API | Snyk/Trivy critical vulnerability notifications |

---

## Repository Structure

This repository (`nutritrack-charts`) is the **single GitOps source of truth** for ArgoCD. All Helm charts, ArgoCD Application manifests, and infrastructure resources live here.

The GitHub organisation `Nutri-Track` contains the following repositories:

```
Nutri-Track/
├── nutritrack-auth-service/        ← app code + CI workflow
├── nutritrack-food-service/        ← app code + CI workflow
├── nutritrack-macro-service/       ← app code + CI workflow
├── nutritrack-compliance-service/  ← app code + CI workflow
├── nutritrack-frontend/            ← app code + CI workflow
├── nutritrack-shared/              ← reusable CI workflow library
│   └── .github/workflows/
│       ├── _sast.yml               ← SonarQube SAST (v2)
│       ├── _sca.yml                ← Snyk SCA (v1)
│       ├── _docker-build.yml       ← Temp build + Trivy scan (v1)
│       ├── _docker-publish.yml     ← Build & push to DockerHub (v1)
│       ├── _cd-template.yml        ← Update Helm values.yaml (v1)
│       └── _notify.yml             ← Brevo email alerts (v1)
│
└── nutritrack-charts/              ← THIS REPO — ArgoCD source of truth
    ├── app-of-apps.yaml            ← Root ArgoCD Application (App of Apps)
    ├── values.yaml                 ← Global Helm values (image tags updated by CI)
    ├── argocd-apps/
    │   ├── apps/                   ← ArgoCD Applications for microservices
    │   │   ├── auth-service.yaml
    │   │   ├── food-service.yaml
    │   │   ├── macro-service.yaml
    │   │   ├── compliance-service.yaml
    │   │   ├── frontend.yaml
    │   │   ├── kube-bench.yaml
    │   │   └── trivy-operator.yaml
    │   ├── infra/                  ← ArgoCD Applications for infrastructure
    │   │   ├── gateway.yaml
    │   │   ├── postgresql.yaml
    │   │   ├── headlamp.yaml
    │   │   ├── keycloak.yaml
    │   │   ├── kube-prometheus-stack.yaml
    │   │   ├── loki.yaml
    │   │   └── promtail.yaml
    │   └── projects/               ← ArgoCD Project definitions
    ├── microservices/              ← Helm charts for all microservices
    │   ├── auth-service/
    │   ├── food-service/
    │   ├── macro-service/
    │   ├── compliance-service/
    │   └── frontend/
    ├── infrastructure/             ← Custom Helm charts for infra components
    │   ├── bootstrap/              ← Namespace bootstrap manifest
    │   ├── envoy-gateway/          ← Gateway + HTTPRoute templates
    │   ├── headlamp/               ← Headlamp deployment (custom chart)
    │   ├── keycloak/               ← Keycloak CR + realm config
    │   ├── kube-bench/             ← CronJob manifest
    │   └── postgresql/             ← StatefulSet + SealedSecret + NetworkPolicy
    └── docs/
        └── https-setup-guide.md   ← HAProxy + Let's Encrypt TLS setup
```

---

## Kubernetes Architecture

### Dual-Cluster Setup

The project uses **two separate kubeadm-bootstrapped clusters**, each serving a distinct role:

**Production Cluster** — runs all NutriTrack workloads:
- All microservices (`nutritrack-dev` namespace)
- PostgreSQL StatefulSet
- Envoy Gateway (API routing)
- Trivy Operator (runtime scanning)
- Network Policies enforced per pod

**Management Cluster** — runs all tooling and observability:
- ArgoCD (GitOps delivery)
- Keycloak (OIDC identity provider)
- Grafana + Prometheus + Loki (observability)
- Headlamp (Kubernetes UI)
- SonarQube (SAST dashboard)

This separation ensures that infrastructure tooling does not compete with workload resources, provides independent upgrade paths, and reduces blast radius.

### Control Plane Traffic

**HAProxy** sits in front of the kube-apiserver on both clusters and:
- Terminates TLS (SSL) using Let's Encrypt wildcard certificates (`*.dev.nutritrack360.in`)
- Forwards traffic to Envoy Gateway NodePort (`30416`) with `X-Forwarded-Proto: https`
- Redirects all HTTP port 80 traffic to HTTPS port 443
- Performs round-robin load balancing across node IPs

### Kubernetes Namespaces

| Namespace | Contents |
|---|---|
| `nutritrack-dev` | All microservices, PostgreSQL, Keycloak, Envoy Gateway resources |
| `monitoring` | Prometheus, Grafana, Loki, Promtail, Alertmanager |
| `headlamp` | Headlamp Kubernetes UI |
| `trivy-system` | Trivy Operator |
| `kube-system` | kube-bench CronJob, CNI, CoreDNS |
| `argocd` | ArgoCD components |
| `sealed-secrets` | Sealed Secrets controller |

### Microservice Deployment Details

Every microservice Helm chart generates:
- `Deployment` with readiness and liveness HTTP probes
- `initContainer` (`postgres:16-alpine`) — waits for the database to be ready before the app starts
- `Service` (ClusterIP)
- `ConfigMap` for environment configuration
- `SealedSecret` for database credentials and JWT secrets
- `NetworkPolicy` — restricts ingress and egress to only required peers

The `frontend` additionally has:
- `HorizontalPodAutoscaler` (min: 2, max: 5 replicas, 70% CPU threshold)

---

## Security Architecture

Security is implemented as a **layered defence-in-depth model**:

```
┌──────────────────────────────────────────────────────┐
│  SUPPLY CHAIN SECURITY                               │
│  SonarQube (SAST) | Snyk (SCA) | Trivy (image scan) │
├──────────────────────────────────────────────────────┤
│  HARDENED CONTAINER IMAGES                           │
│  Multi-stage builds | Non-root UID | Read-only fs    │
├──────────────────────────────────────────────────────┤
│  SECRET MANAGEMENT                                   │
│  Bitnami Sealed Secrets — RSA-OAEP encrypted in Git  │
├──────────────────────────────────────────────────────┤
│  IDENTITY & ACCESS                                   │
│  JWT Auth (stateless) | OIDC via Keycloak | RBAC     │
├──────────────────────────────────────────────────────┤
│  NETWORK SECURITY                                    │
│  Kubernetes Network Policies — deny-all default      │
├──────────────────────────────────────────────────────┤
│  CLUSTER HARDENING                                   │
│  kube-bench CIS Benchmark — runs hourly (CronJob)    │
└──────────────────────────────────────────────────────┘
```

### Hardened Multi-Stage Docker Images

Every service uses a two-stage build to minimise the runtime attack surface:

- **Stage 1 (builder)**: installs all Python dependencies into a prefix directory
- **Stage 2 (runtime)**: copies only the installed packages — no build tools, no pip, no setuptools in the final image

Additional hardening in the runtime stage (from `auth-service` Dockerfile):
```dockerfile
RUN apt-get update && apt-get upgrade -y --no-install-recommends && \
    rm -rf /var/lib/apt/lists/* && \
    pip uninstall -y pip setuptools && \
    groupadd -g 1001 appuser && \
    useradd -r -u 1001 -g appuser -s /usr/sbin/nologin appuser
RUN chown -R appuser:appuser /app && chmod -R a-w /app
USER appuser
```

- No package manager in production image
- Dedicated non-root system user (UID 1001)
- No interactive shell login (`/usr/sbin/nologin`)
- Read-only application directory (`chmod a-w`)

### JWT Authentication

- `auth-service` issues signed JWT tokens on successful login
- All downstream services independently validate the JWT on every request — no shared session state
- Stateless authentication — no server-side session storage
- Frontend stores tokens in memory, not `localStorage`, to prevent XSS exposure

### Sealed Secrets

Plain Kubernetes Secrets are base64-encoded and unsafe to commit to Git. Bitnami Sealed Secrets solves this with RSA-OAEP asymmetric encryption:

```
Developer → kubeseal CLI → encrypts with cluster public key
         → SealedSecret YAML committed to Git ✅
         → Sealed Secrets Controller decrypts in-cluster
         → Native Kubernetes Secret created
```

- Namespaced scope — a SealedSecret sealed for `nutritrack-dev` cannot be unsealed in any other namespace
- Secrets managed: PostgreSQL credentials, JWT signing keys, API integration keys

### Network Policies

Default posture is **deny-all**. Explicit allow rules are defined per service:

| Source | Destination | Allowed |
|---|---|---|
| `frontend` | `auth-service` | ✅ |
| `frontend` | `food-service` | ✅ |
| `frontend` | `macro-service` | ✅ |
| `frontend` | `compliance-service` | ✅ |
| `auth-service` | `postgresql` | ✅ |
| `food-service` | `postgresql` | ✅ |
| `macro-service` | `postgresql` | ✅ |
| `compliance-service` | `postgresql` | ✅ |
| `keycloak` | `postgresql` | ✅ |
| `frontend` | `postgresql` | ❌ Direct DB access blocked |
| Cross-service lateral | any → any | ❌ Blocked |

### OIDC via Keycloak

Keycloak serves as the centralised identity provider for all cluster tooling:

- **Headlamp**: Browser → Keycloak login → OIDC token → K8s RBAC role mapping
- **Grafana**: OIDC login via Keycloak
- **ArgoCD**: OIDC login via Keycloak

Keycloak realm and OIDC client configuration are managed declaratively in Git (`infrastructure/keycloak/`). All OIDC URLs use HTTPS via HAProxy TLS termination.

### kube-bench

kube-bench runs as a **Kubernetes CronJob** on an hourly schedule (`0 * * * *`) in the `kube-system` namespace. It executes the CIS Kubernetes Benchmark against both node and master targets, mounting host paths read-only:

```yaml
command: ["kube-bench", "run", "--targets", "node,master"]
```

Results are available in pod logs and used to continuously verify the cluster hardening posture.

### Trivy Operator (Runtime)

Trivy Operator (`v0.32.1`) is deployed in `trivy-system` in Standalone mode. It continuously scans all running pod images and produces `VulnerabilityReport` CRDs:

```bash
kubectl get vulnerabilityreports -n nutritrack-dev
```

Reports are visible in Headlamp under the CRD browser.

---

## CI Pipeline — GitHub Actions

### Reusable Workflow Architecture

All CI logic lives in `nutritrack-shared` as reusable workflows, versioned by Git tags. Each microservice repo calls these workflows — a change to any shared workflow is instantly inherited by all services on the next run.

```
nutritrack-shared/.github/workflows/
├── _sast.yml           @v2  — SonarQube scan + Quality Gate
├── _sca.yml            @v1  — Snyk dependency scan (HTML report + artifact)
├── _docker-build.yml   @v1  — Temp build + Trivy image scan (PR only, not pushed)
├── _docker-publish.yml @v1  — Build + push to DockerHub (tag immutability enforced)
├── _cd-template.yml    @v1  — Update values.yaml in nutritrack-charts via yq
└── _notify.yml         @v1  — Email alert via Brevo API (with HTML report attachment)
```

A `concurrency` group per workflow+branch prevents duplicate runs. All sensitive tokens are stored in GitHub Actions Environments (`development` / `production`) and are scoped per environment.

### Trigger Strategy

Each service workflow (`ci-<service>.yaml`) is triggered by three events:

```yaml
on:
  push:
    branches: [develop, main]
  pull_request:
    branches: [develop, main]
  release:
    types: [created]
```

### Pull Request Flow

Runs on every PR targeting `develop` or `main`. Jobs run sequentially — each `needs` the previous:

```
PR opened / updated
│
├─ ① sast  (_sast.yml@v2)
│     SonarQube scan → Quality Gate check
│     Blocks merge if Quality Gate fails
│
├─ ② sca  (_sca.yml@v1)  [needs: sast]
│     Snyk scans requirements.txt / package-lock.json
│     --severity-threshold=high
│     HTML report uploaded as artifact (14-day retention)
│     │
│     └─ notify-snyk (_notify.yml@v1)  [if critical-found == 'true']
│           Brevo API email with HTML report attached
│
├─ ③ build  (_docker-build.yml@v1)  [needs: sast, sca]
│     Docker image built locally (NEVER pushed to registry)
│     Trivy scans image: CRITICAL,HIGH — OS + library CVEs
│     Report uploaded as artifact (14-day retention)
│     │
│     └─ notify-trivy (_notify.yml@v1)  [if trivy-critical == 'true']
│           Brevo API email with Trivy report attached
│
└─ ④ pr-check  (PR Quality Gate)  [needs: sast, sca, build]
      Required GitHub status check — blocks merge if any step failed
```

### Develop Branch Flow (After PR Merge)

Triggered by `push` to `develop`. Security scans are not repeated (they already passed on the PR).

```
Merge to develop
│
├─ ① dev-publish  (_docker-publish.yml@v1)
│     Checks tag dev-<sha> does not already exist in DockerHub
│       (DockerHub API call — exits with error if tag exists)
│     Builds Docker image
│     Pushes: nutritrack360/nutritrack-<service>:dev-<git-sha>
│
└─ ② dev-cd  (_cd-template.yml@v1)  [needs: dev-publish]
      Checks out nutritrack-charts (develop branch) via HELM_REPO_PAT
      Uses yq to update values.yaml:
        .<ServiceKey>.image.tag = "dev-<git-sha>"
      Validates YAML
      Commits and pushes:
        "cd: update authService image tag to dev-abc1234 [develop]"
```

`dev-<sha>` images are ephemeral — used only in the development environment and never promoted to production.

### Production Release Flow (GitHub Release on `main`)

Triggered only when a GitHub Release is created targeting `main` with `prerelease == false`:

```yaml
if: github.event_name == 'release'
    && github.event.release.target_commitish == 'main'
    && github.event.release.prerelease == false
```

```
GitHub Release created (e.g. v1.2.0) → targeting main
│
├─ ① publish  (_docker-publish.yml@v1)
│     Checks tag v1.2.0 does not already exist in DockerHub
│       (prevents overwriting immutable release tags)
│     Builds Docker image
│     Pushes: nutritrack360/nutritrack-<service>:v1.2.0
│     Environment: production
│
└─ ② cd  (_cd-template.yml@v1)  [needs: publish]
      Checks out nutritrack-charts (main branch)
      Uses yq to update values.yaml:
        .<ServiceKey>.image.tag = "v1.2.0"
      Commits and pushes:
        "cd: update authService image tag to v1.2.0 [main]"
```

---

## CD Pipeline — ArgoCD GitOps

### App of Apps Pattern

A single root ArgoCD Application (`app-of-apps.yaml`) manages all child Applications by watching `argocd-apps/` recursively:

```yaml
# app-of-apps.yaml
source:
  repoURL: https://github.com/Nutri-Track/nutritrack-charts.git
  targetRevision: develop
  path: argocd-apps
  directory:
    recurse: true
syncPolicy:
  automated:
    prune: true
    selfHeal: true
```

Applying this single manifest to the cluster bootstraps the entire platform.

### ArgoCD Application Pattern

Each microservice ArgoCD Application references the shared `values.yaml` for image tags:

```yaml
source:
  repoURL: https://github.com/Nutri-Track/nutritrack-charts.git
  targetRevision: develop
  path: microservices/auth-service
  helm:
    valueFiles:
      - ../../values.yaml   # global image tags
destination:
  namespace: nutritrack-dev
syncPolicy:
  automated:
    prune: true       # removes resources deleted from Git
    selfHeal: true    # reverts any manual cluster change
```

### GitOps Delivery Flow

```
CI commits updated image tag to values.yaml in nutritrack-charts
        │
        ▼
ArgoCD detects Git diff (~30–60 second polling interval)
        │
        ▼
ArgoCD renders Helm chart with new values
        │
        ▼
Applies only the diff to the cluster (rolling update)
        │
        ▼
New pods become ready → old pods terminate (zero-downtime)
```

**Self-healing**: if a resource is manually changed in the cluster, ArgoCD detects the drift and reverts it to match the Git state automatically.

---

## Observability Stack

### Metrics — kube-prometheus-stack (`v72.6.2`)

Deployed via upstream Helm chart. Components:

| Component | Purpose |
|---|---|
| Prometheus | Metrics scraping and storage (3-day retention, 4GB limit) |
| Grafana | Dashboards (provisioned via ConfigMap sidecar) |
| Alertmanager | Alert routing (72-hour retention) |
| Node Exporter | Host-level metrics (CPU, memory, disk) |
| kube-state-metrics | Kubernetes object state metrics |

Grafana persistence: 1Gi NFS PVC. Prometheus persistence: 5Gi NFS PVC.

Grafana datasources and dashboards are provisioned via sidecar (`grafana_datasource: "1"` label on ConfigMaps).

### Logs — Loki (`v6.30.1`) + Promtail (`v6.16.6`)

- **Loki**: `SingleBinary` deployment mode, `tsdb` schema v13, filesystem storage, 5Gi NFS PVC, 3-day log retention
- **Promtail**: DaemonSet on every node. Configured to push to `http://nutritrack-loki.monitoring.svc.cluster.local:3100/loki/api/v1/push`. `NoSchedule` toleration ensures coverage of control plane nodes
- Logs queryable in Grafana Explore via LogQL

### Kubernetes UI — Headlamp

- Deployed as a custom Helm chart (`infrastructure/headlamp/`)
- Secured via OIDC (Keycloak) — no static kubeconfig exposed
- Provides: pod/deployment/service inspection, real-time pod logs, Trivy `VulnerabilityReport` CRD browsing, RBAC and Network Policy visibility

---

## Networking & Routing

### TLS Termination

```
Browser (HTTPS :443)
    ↓
HAProxy (Let's Encrypt wildcard cert: *.dev.nutritrack360.in)
    ↓  X-Forwarded-Proto: https
Envoy Gateway NodePort (:30416)
    ↓
HTTPRoute → Backend Service
```

HAProxy redirects all HTTP port 80 traffic to HTTPS port 443. Auto-renewal of Let's Encrypt certificates is handled by a certbot post-renewal hook that rebuilds the combined PEM and reloads HAProxy.

### Envoy Gateway

- Implements the **Kubernetes Gateway API** (not the legacy Ingress API)
- `GatewayClass`: `kgateway`
- `Gateway` named `nutritrack-gateway` listens on port 80 in namespace `nutritrack-dev`
- Two `HTTPRoute` resources:
  - `nutritrack-apis` — routes `/api/auth`, `/api/food`, `/api/macro`, `/api/compliance`
  - `nutritrack-frontend` — routes `/` to frontend port 3000

---

## Deployed Applications Reference

### Microservice Applications (`argocd-apps/apps/`)

| ArgoCD Application | Chart Path | Namespace | Sync Wave |
|---|---|---|---|
| `nutritrack-auth-service` | `microservices/auth-service` | `nutritrack-dev` | 1 |
| `nutritrack-food-service` | `microservices/food-service` | `nutritrack-dev` | 1 |
| `nutritrack-macro-service` | `microservices/macro-service` | `nutritrack-dev` | 1 |
| `nutritrack-compliance-service` | `microservices/compliance-service` | `nutritrack-dev` | 1 |
| `nutritrack-frontend` | `microservices/frontend` | `nutritrack-dev` | 1 |
| `kube-bench` | `infrastructure/kube-bench` | `kube-system` | 5 |
| `trivy-operator` | Helm chart `aquasecurity/trivy-operator@0.32.1` | `trivy-system` | 5 |

### Infrastructure Applications (`argocd-apps/infra/`)

| ArgoCD Application | Source | Namespace | Sync Wave |
|---|---|---|---|
| `nutritrack-postgresql` | `infrastructure/postgresql` | `nutritrack-dev` | 0 |
| `nutritrack-gateway` | `infrastructure/envoy-gateway` | `nutritrack-dev` | 0 |
| `nutritrack-monitoring` | Helm `prometheus-community/kube-prometheus-stack@72.6.2` | `monitoring` | 0 |
| `nutritrack-loki` | Helm `grafana/loki@6.30.1` | `monitoring` | 0 |
| `nutritrack-promtail` | Helm `grafana/promtail@6.16.6` | `monitoring` | 0 |
| `nutritrack-keycloak` | `infrastructure/keycloak` | `nutritrack-dev` | 1 |
| `nutritrack-headlamp` | `infrastructure/headlamp` | `headlamp` | 2 |

---

## Sync Waves & Deployment Order

ArgoCD sync waves control the deployment order within a sync operation:

| Wave | What deploys |
|---|---|
| **0** | PostgreSQL, Envoy Gateway, Prometheus stack, Loki, Promtail |
| **1** | Keycloak, all microservices (after DB is ready) |
| **2** | Headlamp (after Keycloak OIDC is available) |
| **5** | kube-bench, Trivy Operator |

`initContainer` in each microservice deployment additionally gates startup on PostgreSQL readiness using `pg_isready`, providing an extra safety layer independent of sync wave ordering.

---

## Configuration Reference

All service image tags and shared configuration live in [`values.yaml`](./values.yaml). The CI pipeline uses `yq` to update image tags in this file automatically after a successful build.

Key configuration keys:

```yaml
global:
  appName: nutritrack
  namespace: nutritrack-dev
  domain: dev.nutritrack360.in

authService:
  image:
    repository: nutritrack360/nutritrack-auth-service
    tag: dev-<sha>          # updated automatically by CI

frontend:
  hpa:
    enabled: true
    minReplicas: 2
    maxReplicas: 5
    targetCPUUtilization: 70

complianceService:
  thresholds:
    proteinDeficiencyPct: "80"
    calorieSurplusPct: "120"
    calorieDeficitPct: "70"
    patternDays: "3"
```

---

## Docs

| Document | Description |
|---|---|
| [`docs/https-setup-guide.md`](./docs/https-setup-guide.md) | Step-by-step guide for configuring HAProxy TLS with Let's Encrypt wildcard certificates, including certbot setup, GoDaddy DNS TXT record configuration, HAProxy config, Keycloak HTTPS update, and auto-renewal |
