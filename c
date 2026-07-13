You can see both charts:

- GROUND TRUTH (do NOT modify): ~/Repos/heln/dagster
  This is my Dagster chart that is PROVEN RUNNING on my own AWS account.
  Its keys, structure, versions, and code-location approach are verified correct.

- TARGET (to be modified): ~/Repos/helm-charts/charts/infra/aiops-dagster-platform
  This is the chart destined for our prod. Its values are currently written
  against a SCHEMA THAT DOES NOT EXIST (dagit.sidecarContainers,
  dagit.ingress, runLauncher.k8s.jobPodTemplate, etc. are not real keys in
  the official chart).

TASK: rewrite TARGET to be structurally identical to GROUND TRUTH, then layer
on the prod-specific differences listed below.

RULES:
1. Wherever GROUND TRUTH and TARGET conflict, GROUND TRUTH wins. Do not
   "improve" it. Do not redesign it.
2. Do NOT invent values keys. Every key under the official dagster subchart
   must be findable in the output of:
     helm show values dagster/dagster --version 1.13.13
   Run that command BEFORE editing and treat it as the only source of truth.
3. Versions must be consistent everywhere: Chart.yaml version/appVersion,
   dependency version, and every image tag = 1.13.13. The system image is
   docker.io/dagster/dagster-k8s (NOT dagster/dagster).
4. Do NOT use dagster/user-code-example as the code location — it is broken at
   1.13.13. Keep GROUND TRUTH's approach: mount definitions.py from a ConfigMap
   into the stock dagster-k8s image + includeConfigInLaunchedRuns.enabled: true.

REAL prod-vs-personal differences — these must be HANDLED, not copied verbatim:
a) ESO auth: personal relies on the node role. Prod needs IRSA — the ESO
   controller's role must be able to read the parameterPrefix path.
b) S3ComputeLogManager needs IRSA: the ServiceAccounts for the webserver, the
   daemon, AND the run pods must all be able to write to the bucket.
c) SecretStore ownership: first check whether prod already has a shared
   platform-level SecretStore. If it does, only set storeName — do not create
   another aws-parameter-store.
d) ESO apiVersion: use whatever the prod cluster's installed ESO actually
   supports, NOT personal's v1 by default.
e) Parameterize: secretStoreRef.name, compute-logs bucket, and parameterPrefix
   must come from values, not be hardcoded.
f) Things personal does NOT have at all and must be ADDED: ingress,
   authentication (nginx basic auth or ALB OIDC), Karpenter
   nodeSelector/tolerations, runLauncher jobNamespace, resources.

HOW TO WORK:
- First, output a key-by-key diff table of personal vs prod, labeling each row
  as "copy as-is / must change (with reason) / new". Wait for my confirmation
  before touching any file.
- After editing, you MUST run:
    helm dependency build <target chart>
    helm template x <target chart> -f <env-values> | grep -E \
      'kind: (Deployment|Service|Ingress)|image:|command:|dagsterApiGrpcArgs'
  and paste the rendered output back to me. If the render fails or a key is
  rejected by the schema, do NOT work around it — say so.
- If you are unsure about anything, ask me. Do not guess.
