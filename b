# Dagster MVP on EKS — Review, Fixes & Concepts

**Repo:** `helm-charts/charts/infra/aiops-dagster-platform`
**Goal:** hello-world Dagster running remotely on EKS with a login page, deployed via ArgoCD ApplicationSet, **no ECR push**.
**Verdict:** topology is sound; the `values` file is written against a **chart schema that doesn't exist**, so as-built it renders but does *not* produce auth, code loading, or exposure. Fix the schema, not the shape.

---

## TL;DR — what's actually wrong

1. The whole `dagster:` subtree uses **invented keys** the official subchart never reads → silent no-ops / schema failures. *(root cause)*
2. Because of #1: **no auth** (nginx never runs), **nothing mounted**, **nothing exposed**, **no code location** → empty UI, can't materialize.
3. Wrong system image: `dagster/dagster` → must be `dagster/dagster-k8s`; and `1.7.0` contradicts the `1.13.5` pin.
4. ConfigMap-mounted `hello_world.py` **does not load code** — webserver loads from gRPC code servers, not `/opt/code`.
5. External Postgres is half-wired (`postgresqlHost: ""`, secret-key mismatch).
6. ALB can't do basic auth; nginx as a subchart *sidecar* is not a real chart feature.
7. Unverified prerequisites: Docker Hub pullability, ArgoCD repo-server egress.

---

## Target architecture (MVP)

```
                 (basic auth here)
Browser ──HTTPS──► ALB ──► nginx (ClusterIP, htpasswd) ──► dagster-webserver:80
                                                              │ (workspace.yaml → gRPC)
                                                              ▼
                                                   dagster-user-deployments
                                                   (code location, gRPC :3030)
                                                              │ K8sRunLauncher
                                                              ▼
                                                   run-worker Job (same code image)

daemon ──► queued run coordinator ──► launches runs
postgres (bundled for MVP) ──► run/event storage
```

Two auth choices — pick one (see [Auth](#auth-two-options)):
- **A. nginx basic auth** as its **own Deployment + Service** in the wrapper chart.
- **B. ALB-native `authenticate-oidc`** → existing Keycloak (no nginx, real login page).

---

## Issues, ranked

### 1. `dagster:` values use keys the official subchart doesn't have  ⛔ blocker / root cause

The official chart ships a `values.schema.json`. Helm validates your `dagster:` block against it. Invented keys either **hard-fail** the render or **silently no-op**. Observed invented/renamed keys:

| In your values | Reality |
|---|---|
| `dagit:` | renamed to **`dagsterWebserver:`** (don't rely on the old `dagit` alias in modern charts) |
| `dagit.sidecarContainers:` | **does not exist** — the webserver Deployment has no sidecar-injection field |
| `dagit.ingress:` | ingress is **top-level** `ingress:`, not under the webserver |
| `dagit.persistence:` | webserver is **stateless** — no such key |
| `dagsterDaemon.image:` / `dagsterDaemon.runQueue:` | not daemon fields; run-queue lives under `dagsterDaemon.runCoordinator.config.queuedRunCoordinator` |
| `runLauncher.k8s.jobPodTemplate.containers:` | real shape is **`runLauncher.config.k8sRunLauncher.{…}`**, not a raw pod template |

**Fix:** configure the subchart **only** through its real keys. Reconcile every key against the authoritative source (see [Verification](#pre-merge-verification)) — do not trust hand-written or LLM-generated values that assume a schema.

---

### 2. Direct consequences of #1  ⛔ blocker

- **No authentication at all.** The nginx "sidecar" under `dagit.sidecarContainers` never renders → the webserver is wide open (or unexposed). Your `nginx-configmap.yaml` / htpasswd exist but **nothing consumes them**.
- **Nothing mounted.** `code-configmap.yaml` renders, but the subchart's webserver pod won't mount it — those `extraVolumes`/`extraVolumeMounts` were placed under invented keys.
- **Nothing exposed.** Ingress under the wrong path → no ALB provisioned as intended.
- **No code location.** Webserver has nothing to load → empty UI, no assets, can't materialize.

**Fix:** wire volumes/ingress/code through real keys and a real code-location subchart (below).

---

### 3. Wrong image + version drift  ⛔ crashloop

- `dagster/dagster` **lacks** `dagster_k8s` and `dagster_aws`. The daemon + webserver crashloop on the `K8sRunLauncher` import; your `from dagster_aws.s3 import …` also fails.
- **Use `docker.io/dagster/dagster-k8s`** for webserver, daemon, and the run launcher image.
- `1.7.0` contradicts the **`1.13.5`** core pin. Chart `--version`, `appVersion`, and every image tag must be the **same** version.

**Fix:** `dagster/dagster-k8s:1.13.5` everywhere; set Chart `version`/`appVersion` and ApplicationSet `targetRevision` to match.

---

### 4. ConfigMap-mounted code doesn't load  ⛔ can't materialize

Dagster loads definitions from a **workspace** that points at **gRPC code servers**, not from a file on the webserver's disk. Mounting `hello_world.py` at `/opt/code` does nothing on its own.

**Fix (MVP, zero build):** add a `dagster-user-deployments` code location using the **prebuilt** `dagster/user-code-example` image — code is baked in, guaranteed to load and materialize, no ECR, no S3.
Also **remove `S3PickleIOManager`** from the hello-world code for the smoke test — the default in-memory/filesystem I/O manager drops the S3 bucket + IRSA + `dagster_aws` import from the critical path. Prove the pipeline first; add S3 I/O later.

---

### 5. External Postgres is half-wired  ⚠️ likely startup failure

- `postgresqlHost: ""` won't be populated from the ExternalSecret — the chart takes **host as a plain value** and reads only the **password** from a secret, under a **specific key name** (not necessarily `password`).
- ExternalSecret + RDS + SecretStore is a lot of moving parts to debug on first bring-up.

**Fix (MVP):** `postgresql.enabled: true` (in-cluster, ephemeral) to cut RDS + ExternalSecret out of the critical path. Switch to RDS via ExternalSecret once the stack is green.

---

### 6. nginx + ALB details  ⚠️ won't route / won't auth

- **ALB has no native basic auth** (only `authenticate-oidc` / `authenticate-cognito`). Basic auth must live at **nginx**.
- nginx upstream `127.0.0.1:3000` is wrong — target the **webserver Service on :80** (`http://<release>-dagster-webserver:80`). `127.0.0.1` only works if nginx and webserver share a pod (the sidecar that isn't real).
- ALB annotations `listen-ports: [{"HTTPS":443}]` + `ssl-redirect: "443"` with `certificate-arn: ""` → **no listener provisioned** (no ACM cert).

**Fix (MVP):** nginx as its **own Deployment + Service**; ALB on **HTTP :80** for the smoke test (add ACM cert + HTTPS after). Path: `ALB → nginx Service (ClusterIP) → dagster-webserver:80`.

---

### 7. Unverified prerequisites  ⚠️ verify before sync

- **Docker Hub pullability.** "No ECR required" holds **only if nodes can pull Docker Hub**. If egress is ECR-only → `ImagePullBackOff`. Test: `kubectl run t --rm -it --image=nginx:alpine --restart=Never -- true`. If it fails, set up an **ECR pull-through cache** (rule + IAM, no push) and rewrite image repos to `<acct>.dkr.ecr.<region>.amazonaws.com/docker-hub/…`.
- **ArgoCD repo-server egress.** `helm dependency build` runs on the repo-server at sync; it must reach `dagster-io.github.io` to fetch `dagster-1.13.5.tgz`. Locked-down cluster → vendor the dependency instead.

---

## Auth: two options

**A — nginx basic auth (fastest gate, no IdP wiring)**
Own Deployment + Service in the wrapper chart. Mount `nginx.conf` (ConfigMap) + `.htpasswd` (Secret). Source htpasswd from your secret store via **ExternalSecret** (you already have the plumbing) rather than an out-of-band `kubectl create secret`, so it stays GitOps-pure. Health path `/health` with `auth_basic off` for probes.

**B — ALB `authenticate-oidc` → Keycloak (real login, no nginx)**
You already run Keycloak/NLB SSO. Add `alb.ingress.kubernetes.io/auth-*` annotations pointing at the Keycloak OIDC endpoints. No sidecar fight, no htpasswd, and it's the same path that later feeds `dagster-authkit`'s `proxy` backend. Heavier one-time setup (client, callback URLs).

> `dagster-authkit` stays **out of scope** until CI can push a custom image to ECR — it *requires* one. Basic auth or OIDC is the MVP gate.

---

## Corrected values skeleton (real keys)

> Illustrative — **reconcile every key** against `helm show values dagster/dagster --version 1.13.5` and the chart's `values.schema.json`. That reconciliation *is* the fix for Issue #1.

```yaml
# usw2sandbox-values.yaml (wrapper chart)

# ---- official chart, as a subchart (nested under its name) ----
dagster:
  dagsterWebserver:
    replicaCount: 1
    image:
      repository: docker.io/dagster/dagster-k8s
      tag: "1.13.5"
    service:
      type: ClusterIP
      port: 80

  dagsterDaemon:
    enabled: true
    image:
      repository: docker.io/dagster/dagster-k8s
      tag: "1.13.5"
    runCoordinator:
      enabled: true
      config:
        queuedRunCoordinator:
          maxConcurrentRuns: 10
          dequeueIntervalSeconds: 5

  runLauncher:
    type: K8sRunLauncher
    config:
      k8sRunLauncher:
        jobNamespace: aiops-data-pipeline
        loadInclusterConfig: true
        # image for run workers is inherited from the code location (DAGSTER_CURRENT_IMAGE)

  # MVP: in-cluster ephemeral PG. Flip to false + external once green.
  postgresql:
    enabled: true

  # Let the WRAPPER chart own ingress so it points at nginx, not the webserver.
  ingress:
    enabled: false

  # ---- code location (nested subchart) : baked-in example, no build/S3 ----
  dagster-user-deployments:
    enabled: true
    deployments:
      - name: hello-world
        image:
          repository: docker.io/dagster/user-code-example
          tag: "1.13.5"
        dagsterApiGrpcArgs:
          - "-f"
          - "/example_project/example_repo/repo.py"
        port: 3030

# ---- wrapper-chart-owned resources (your templates/) ----
# nginx: OWN Deployment + Service (not a subchart sidecar)
#   ALB Ingress -> nginx Service (ClusterIP, basic auth) -> dagster-webserver:80
# ingress: HTTP :80 for smoke test; add ACM cert + HTTPS later
```

If nodes can't pull Docker Hub, prefix every `repository:` with the ECR pull-through path.

---

## Pre-merge verification

Run locally before the PR — it fails immediately on bad keys for the pinned version, which is more authoritative than any memory:

```bash
# 1. resolve the subchart the way ArgoCD will
helm dependency build charts/infra/aiops-dagster-platform

# 2. see the ground truth for real keys
helm show values dagster/dagster --version 1.13.5 | less

# 3. render and eyeball the critical objects
helm template x charts/infra/aiops-dagster-platform \
  -f charts/infra/aiops-dagster-platform/usw2sandbox-values.yaml \
  | grep -E 'kind: (Deployment|Service|Ingress)|image:|nginx|command:|dagsterApiGrpcArgs'
```

**Pass criteria in the rendered output:**
- Every `image:` is `dagster-k8s` / `user-code-example` at **1.13.5** (or the ECR-prefixed equivalent).
- An **nginx container** appears (as its own Deployment).
- A **code-location Deployment** renders (`hello-world` / user-code-example).
- The **exposed Service** targets **nginx**, not the webserver directly.

If nginx or the code location is missing from the render, that's the whole bug in one glance.

---

## MVP ladder (don't skip rungs)

1. Stock Dagster reachable via `port-forward` (no auth, bundled PG, example code) → materialize an asset.
2. Add ingress (ALB → nginx :80) with **basic auth**.
3. Swap bundled PG → RDS via ExternalSecret.
4. Swap example code → your own code location (needs an image CI can push).
5. HTTPS (ACM) / OIDC → Keycloak.
6. `dagster-authkit` (needs custom image → needs ECR push → needs CI). Last.

---

## Key concepts to internalize

- **Dagster OSS has no auth.** It's always added *outside* the app — ingress/reverse proxy (basic auth or OIDC). The webserver never sees credentials.
- **Wrapper-chart contract.** The official chart is a **dependency**. You configure it *only* through its published keys under `dagster:`. Resources you template yourself (nginx, extra ConfigMaps) live in the wrapper and are **not** magically consumed by the subchart's pods — you must wire them via real keys or point your own Deployments at the subchart's Services.
- **`values.schema.json` is law.** Made-up keys don't "extend" the chart; they no-op or fail validation. When in doubt, `helm show values` + `helm template`.
- **Code locations are gRPC servers / images, not folder sync.** The webserver reads a workspace that points at code servers. The run worker reuses the code location's image via `DAGSTER_CURRENT_IMAGE`. This is why ConfigMap-mounted `.py` doesn't load, and why "your own code" eventually needs a pushable image.
- **System image = `dagster-k8s`.** Plain `dagster/dagster` lacks the k8s/aws integration libs.
- **Version coherence.** core pin == chart version == appVersion == image tags == ApplicationSet targetRevision. One number (1.13.5).
- **ALB ≠ nginx Ingress.** ALB does OIDC/Cognito, not basic auth. nginx annotations are interpreted by the nginx controller only.
- **"No ECR push" ≠ "no ECR pulls."** Locked-down egress may force **pull-through cache** even for public images. Verify pullability early.
- **ArgoCD resolves deps at sync**, on the repo-server — which needs egress to the chart repo. No local `charts/` vendoring required *if* that egress exists.

---

## Open questions to resolve

- [ ] Can nodes pull Docker Hub? (decides pull-through cache)
- [ ] Can the ArgoCD repo-server reach `dagster-io.github.io`? (decides vendoring)
- [ ] Auth path: nginx basic auth **or** ALB OIDC → Keycloak?
- [ ] Namespace: is `aiops-data-pipeline` the intended target for the run Jobs + secrets?
- [ ] ACM cert ARN for HTTPS (or stay HTTP for the smoke test)?
