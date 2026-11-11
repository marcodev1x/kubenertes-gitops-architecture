Production Kubernetes on a Single VPS: GitOps, Service Mesh, and Autoscaling
Infrastructure for a public procurement monitoring SaaS.
The platform runs 17 workloads (15 Go services and 2 Next.js frontends), plus Kafka, Redis, and observability, on a single-node k3s cluster hosted on a 12 GB RAM / 4 vCPU VPS. Production and staging share the cluster.
All workloads are managed through GitOps. Argo CD watches this repository; deploying a new version means changing an image tag in Git.
About the **** values: this is a public mirror of a private infrastructure repository. Domains, email addresses, GitHub organization, storage endpoints, SMTP host, cluster IDs, and Secret values have been replaced. Charts, policies, CPU and memory settings reflect the actual setup.
Stack
Layer	Technology
Cluster	k3s, single node, Traefik disabled
GitOps	Argo CD: App of Apps + ApplicationSets with the Git directory generator
Packaging	Helm, one chart per service, environment-specific values files
Service mesh	Istio 1.28, native sidecars, STRICT mTLS
Ingress	Istio IngressGateway + cert-manager (Let's Encrypt, DNS-01)
Scaling	HPA (autoscaling/v2) based on CPU, PDBs, ResourceQuotas
Go runtime	GOMEMLIMIT set to approximately 80% of each container's memory limit
Registry	GHCR, image tags based on commit SHA, SBOM and provenance
CI	GitHub Actions with reusable workflows per repository type
Messaging / cache	Kafka 4.1 (KRaft, kafka-native), Redis 8
Database	MongoDB Atlas (external, for Atlas Search)
Observability	VictoriaMetrics, VictoriaLogs, Vector, Grafana
Backups	mongodump CronJob to Cloudflare R2 via rclone; 30-day retention

1. GitOps with Argo CD
flowchart LR
    dev[Push to service repository] --> gha[GitHub Actions<br/>build · test · image]
    gha -->|push :sha| ghcr[(GHCR)]
    gha -->|commit image.tag = sha| infra[Infrastructure repository<br/>apps/svc/values-env.yaml]
    infra -->|pull| argo[Argo CD]
    argo -->|sync| prod[Production namespace<br/>audita]
    argo -->|sync| stg[Staging namespace<br/>audita-staging]
    ghcr -.->|imagePullSecret ghcr| prod
    ghcr -.-> stg
The CI pipeline has no cluster credentials. It can only update this infrastructure repository. A deployment is the commit that changes an image tag; rollback is a git revert or an action from Argo CD history.
App of Apps
A single root-app, applied once, points to argocd/. Argo CD then manages:
Resource	Purpose
project.yaml	Restricts source repositories and destination namespaces (audita, audita-staging, argocd, istio-system)
applicationset.yaml	Creates one production Application for each directory under apps/*
applicationset-staging.yaml	Does the same for staging, excluding shared or production-only components: mesh, observability, and mongo-backup
base-app.yaml / base-staging-app.yaml	Creates each environment's namespace, ResourceQuota, LimitRange, and ConfigMap

Adding a service does not require an Argo CD change. Creating apps/<service>/ with a Chart.yaml and values.yaml is enough for the Git directory generator to create its Applications.
Sync policy
syncPolicy:
  automated: { prune: true, selfHeal: true }
  syncOptions: [ServerSideApply=true]
  retry: { limit: 5, backoff: { duration: 10s, factor: 2, maxDuration: 3m } }
ignoreDifferences:
  - group: apps
    kind: Deployment
    jsonPointers: [/spec/replicas]
Git is the source of truth: drift is reverted. /spec/replicas is excluded from comparison so Argo CD does not overwrite the HPA's replica count. The Helm template also omits replicas when autoscaling is enabled. This allows staging to be scaled to zero manually to free memory without Argo CD scaling it back up.
2. Production and staging
Both environments run in the same cluster, isolated by namespace. Environment differences are defined in values files, not separate infrastructure branches.
helm:
  valueFiles:
    - values.yaml              # base: image, env, secretEnv, sidecar, probes
    - values-production.yaml  # or values-staging.yaml
	Production	Staging
Namespace	audita	audita-staging
Service branch that triggers deployment	main	staging
CI updates	values-production.yaml	values-staging.yaml
Replicas	HPA, ranges from 1–2 to 2–6 depending on service	1, no HPA
ResourceQuota requests	3 CPU / 7 Gi, 45 pods	1.5 CPU / 3 Gi, 24 pods
LimitRange max per container	1536 Mi	768 Mi
Hosts	api.****, app.****, etc.	stg-api.****, stg-app.****, etc.
Kafka and Redis	Dedicated instances	Dedicated instances
Mesh and observability	Shared	Shared

Staging has its own Kafka and Redis because topic names are identical across environments and Redis keys have no environment prefix. Connecting staging to production could trigger real customer emails from a staging event.
The frontend also gets a separate image per environment. NEXT_PUBLIC_* variables are embedded at build time, so web-app uses separate build-args and staging-build-args. Otherwise, the staging frontend could point to the production API.
3. Istio service mesh: gRPC and HTTP load balancing
Why the mesh is needed
A Kubernetes ClusterIP Service balances connections at L4. Since gRPC uses HTTP/2, a client can keep one long-lived connection and multiplex all requests through it. Without a mesh, multiple replicas may still receive uneven traffic because the connection stays attached to one pod.
Envoy terminates HTTP/2 and distributes traffic at L7, per request. Each service defines its policy in a DestinationRule:
trafficPolicy:
  loadBalancer:
    simple: LEAST_REQUEST
  connectionPool:
    tcp:  { maxConnections: 64, connectTimeout: 3s }
    http: { http2MaxRequests: 256, maxRequestsPerConnection: 0, maxRetries: 2 }
  outlierDetection:
    consecutive5xxErrors: 5
    interval: 10s
    baseEjectionTime: 30s
    maxEjectionPercent: 50
LEAST_REQUEST is used instead of ROUND_ROBIN because request cost varies. A heavy MongoDB aggregation should not count the same as a simple key lookup.
The mesh handles 11 gRPC services (port 9090, appProtocol: grpc) and 6 HTTP services (gateways, webhooks, CDN, and frontends).
Ingress
flowchart LR
    net((Internet)) -->|80 → 301 · 443 TLS| gw[istio-ingressgateway<br/>Gateway + Certificate]
    gw -->|/api/| api[api-gateway]
    gw -->|/v1/webhooks/| wh[webhooks]
    gw -->|api-auth host| auth[api-auth-gateway]
    gw -->|app host| web[audita-web]
    api -->|gRPC · mTLS · LEAST_REQUEST| svcs[bids · client · billings · agents<br/>coupons · limits · certificates …]
    auth --> svcs
    svcs --> kafka[(Kafka)]
    svcs --> redis[(Redis)]
    svcs --> mongo[(MongoDB Atlas)]
    • One Gateway serves both environments. Port 80 redirects to HTTPS; TLS certificates are issued by cert-manager through Let's Encrypt DNS-01 challenges.
    • Each host has a VirtualService with its own timeout, retry, and CORS settings.
    • The API retries connect-failure, refused-stream, and unavailable. Payment webhooks use retries: 0; the provider already retries, and another retry at the gateway could duplicate processing.
    • Staging hosts route to *.audita-staging.svc.cluster.local.
Keeping the mesh within the VPS budget
Istio's default sidecar request is 100m CPU / 128 MiB. With 23 pods in the mesh, sidecars alone would use close to 3 GiB. These settings reduce that overhead:
Setting	Location	Effect
Sidecar request 25m / 48 MiB, limit 200m / 192 MiB	sidecar.istio.io/proxy* pod annotations	About 1 GiB for all sidecars instead of about 3 GiB
Sidecar resource limits egress to ./* and istio-system/*	apps/mesh/templates/policy.yaml	Envoy loads configuration only for its namespace
ENABLE_NATIVE_SIDECARS=true	istiod	CronJobs can terminate instead of remaining stuck behind the proxy
holdApplicationUntilProxyStarts	meshConfig	The application starts after the proxy, avoiding failed initial gRPC calls
Metrics port excluded from interception	traffic.sidecar.istio.io/excludeInboundPorts	Probes and scrapes reach the process directly
Kafka, Redis, observability, and backup excluded from injection	sidecar.istio.io/inject: "false"	No L7 benefit for their TCP traffic; saves roughly 100 MiB

PeerAuthentication enforces STRICT mTLS across the namespace. Pods do not accept plaintext traffic from other pods.
4. HPA and pod scaling
Every production service except pncp has an autoscaling/v2 HPA based on CPU utilization.
Service	Min → max	CPU target
api-gateway, client	2 → 6	70%
bids	2 → 5	70%
audita-web, billings, api-auth-gateway	2 → 4	70%
webhooks, limits	2 → 4	75%
agents	1 → 3	60%
cdn, mailer	1 → 3	70%
automations, coupons, certificates	1 → 3	75%
whitelabel, audita-landing	1 → 2	80%
pncp	1 fixed	—

behavior:
  scaleUp:   { stabilizationWindowSeconds: 30,  policies: [{ type: Pods, value: 1, periodSeconds: 60 }] }
  scaleDown: { stabilizationWindowSeconds: 300, policies: [{ type: Pods, value: 1, periodSeconds: 120 }] }
Scale-up adds at most one pod per minute. Scale-down waits for five stable minutes and removes at most one pod every two minutes.
Scaling decisions
    • CPU, not memory. Go's heap does not return memory predictably. With GOMEMLIMIT, the process is intentionally kept near its memory budget; a memory-based HPA could scale up and remain at its maximum.
    • pncp has no HPA. Its rate limiter for the public government API is in process memory. Multiple replicas would multiply the request rate. HPA can be enabled after moving the limiter to Redis.
    • ResourceQuota caps aggregate demand. HPAs do not coordinate with each other. A pod that exceeds the namespace quota remains Pending instead of pushing the node into OOM. The system degrades rather than taking down the node.
    • Rolling updates: maxSurge: 1, maxUnavailable: 0; PDBs with maxUnavailable: 1 protect critical services (gateways, webhooks, bids, client, billings, and web). topologySpreadConstraints use hostname and are ready for a second node.
5. GOMEMLIMIT
Without GOMEMLIMIT, Go's garbage collector follows GOGC=100 and does not account for the container's cgroup limit. A large allocation can exceed limits.memory before the next GC cycle, causing an OOMKill.
GOMEMLIMIT makes the runtime more aggressive as the heap approaches its budget. It is set to approximately 80% of the container memory limit, leaving the remaining 20% for goroutine stacks, runtime data structures, and buffers.
Workload	limits.memory	GOMEMLIMIT
agents	1 Gi	819 MiB
bids	768 Mi	614 MiB
api-gateway, client, billings	384 Mi	307 MiB
api-auth-gateway, webhooks	256 Mi	204 MiB
mailer, coupons, limits, etc.	192 Mi	153 MiB
bids (staging)	384 Mi	307 MiB
collect-bids CronJob	1 Gi	819 MiB

The value is injected into each Deployment through {{ .Values.goMemLimit }} and changes with the environment's memory limit. CronJobs define their own value because jobs such as data collection have a different memory profile from the service process sharing the image.
For the Next.js frontends, NODE_OPTIONS=--max-old-space-size sets the Node.js heap limit.
6. ConfigMaps, environment variables, and Secrets
Configuration reaches each pod through three layers:
# Service values.yaml
env:
  DB_NAME: "bids"
  CLIENT_HOST: "client:9090"
  MAILER_HOST: "mailer:9090"

secretEnv:
  MONGODB_URL: mongodb-url
  REDIS_PASSWORD: redis-password
# templates/deployment.yaml
env:
  - name: GOMEMLIMIT
    value: {{ .Values.goMemLimit | quote }}
  {{- range $k, $v := .Values.env }}
  - name: {{ $k }}
    value: {{ $v | quote }}
  {{- end }}
  {{- range $k, $v := .Values.secretEnv }}
  - name: {{ $k }}
    valueFrom:
      secretKeyRef: { name: audita, key: {{ $v }} }
  {{- end }}
envFrom:
  - configMapRef: { name: audita-config }
Layer	Contents	Stored in
ConfigMap audita-config	Kafka and Redis addresses, public frontend URLs, auth, and CDN	base/ and base-staging/, one per namespace
env	Database name and addresses of neighboring services	Each service's values.yaml
secretEnv → Secret audita	Database credentials, payment gateway, LLM, SMTP, and storage credentials	Outside Git

Each service receives only the Secret keys it declares. For example, api-gateway does not get the payment gateway token, and mailer does not get the database URL.
Secrets are never committed. base/secret.example.yaml documents the required keys and is excluded from Argo CD sync through directory.exclude. Real values are created in the cluster during bootstrap.
7. GHCR image registry
    • CI publishes images to ghcr.io/****/<service> using the repository's GITHUB_TOKEN with packages: write permission.
    • Image tags use the full commit SHA, never latest. If the tag does not change, the manifest does not change and Argo CD has nothing to sync.
    • Each image includes an SBOM and provenance (mode=max); builds use GitHub Actions cache.
    • Private Go modules are downloaded using a BuildKit secret (--mount=type=secret,id=gh_token), so the token is not stored in an image layer.
    • Each namespace has a docker-registry Secret named ghcr. scripts/create-ghcr-secret.sh creates it and supports token rotation. It is attached to each service's ServiceAccount:
apiVersion: v1
kind: ServiceAccount
automountServiceAccountToken: false
imagePullSecrets:
  - name: ghcr
Deployments and CronJobs inherit the registry credentials from the ServiceAccount. The Kubernetes API token is not mounted because application services do not communicate with the API server.
8. Scheduled jobs with CronJobs
Scheduled tasks use the service's existing image and run a CLI command, for example bids-cli collect-bids. Jobs are configured as a list in the service values; the Helm template creates a CronJob for each entry.
cronjobs:
  - name: collect-bids
    command: collect-bids
    schedule: "0 7,14,20 * * *"
    deadline: 3600
    goMemLimit: "819MiB"
    resources: { requests: { cpu: 100m, memory: 256Mi }, limits: { cpu: "1", memory: 1Gi } }
CronJob	Schedule (America/Sao_Paulo)	Purpose
bids-collect-bids	07:00, 14:00, 20:00	Fetches tenders from the public API
bids-send-recommendations	08:00, 15:00, 21:00	Matches new tenders to customer profiles and sends notifications
client-expire-tastings	03:00	Expires trial periods
client-alert-companies	12:00	Notifies companies in a trial period, once per day to avoid duplicate emails
certificates-expiring-alert	09:00	Notifies customers about certificates nearing expiration
mongo-backup	04:00	Runs mongodump and uploads to R2; 30-day retention

Common settings:
timeZone: America/Sao_Paulo
concurrencyPolicy: Forbid
startingDeadlineSeconds: 300
jobTemplate:
  spec:
    backoffLimit: 0
    activeDeadlineSeconds: …
Notification jobs use backoffLimit: 0 to avoid resending emails after an automatic retry. The idempotent MongoDB backup uses backoffLimit: 2.
The backup runs in a pod with two stages: an initContainer runs mongodump --gzip into an emptyDir; the main container uses rclone copy to upload the dump to an S3-compatible bucket, then deletes files older than 30 days with rclone delete --min-age 30d. Credentials come from a Secret, and both containers use read-only filesystems.
The namespace ResourceQuota also limits the number of CronJobs with count/cronjobs.batch: "6".
9. Resource governance
Resource limits are enforced at three levels:
Layer	Protects against
Per-container limits	A single service consuming the node through a leak or spike
GOMEMLIMIT (~80% of the memory limit)	GC running too late and triggering an OOMKill
Namespace ResourceQuota	Multiple HPAs scaling at the same time

Each namespace also has a LimitRange to set default requests and limits for containers that do not declare them.
CAPACIDADE.md contains the CPU and memory budget, including OS, k3s, istiod, and Argo CD overhead, available scaling headroom, page cache, and why staging needs 16 GB. The figures are measured with helm template across all charts.
10. Pod security
Application workloads use the following security context:
securityContext:
  runAsNonRoot: true
  runAsUser: 65532
  fsGroup: 65532
  seccompProfile: { type: RuntimeDefault }
containers:
  - securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities: { drop: ["ALL"] }
The image uses the distroless nonroot user. Writable paths are limited to an emptyDir mounted at /tmp, with a sizeLimit.
Health checks use a dedicated metrics port (19090): startupProbe and livenessProbe call /health; readinessProbe calls /ready.
11. Observability
Component	Role
VictoriaMetrics	Scrapes pods through kubernetes_sd; 3-month retention
VictoriaLogs	Log storage with 7-day retention and an Elasticsearch-compatible endpoint
Vector (DaemonSet)	Collects kubernetes_logs from each node and ships them to VictoriaLogs
Grafana	Datasources provisioned through ConfigMaps

The observability stack requests approximately 830 MiB and runs once per cluster, outside the service mesh. It is shared by production and staging.
12. CI
Workflow	Used by	Steps
go-service.yaml	15 Go services	Build · go test -race -shuffle=on with coverage · image · image tag update
web-app.yaml	2 frontends	bun install --frozen-lockfile · lint · tsc --noEmit · image · image tag update
ci.yaml	Infrastructure repository	helm lint + helm template \| kubeconform -strict across all charts

Service repositories do not maintain their own full pipelines. Each has a small ci.yaml that calls a reusable workflow from this repository through workflow_call. Updating the Go version or deployment steps only requires one change.
The deployment job uses concurrency per chart and retries pull --rebase up to five times before pushing. This prevents deployments from different services from conflicting on the same main branch.
Bootstrap
Bootstrap order matters because each step depends on the previous one:
./scripts/bootstrap-k3s.sh          # k3s without Traefik (Istio uses 80/443) + Argo CD
kubectl -n cert-manager create secret generic cloudflare-api-token ...
./scripts/bootstrap-istio.sh        # cert-manager, ClusterIssuer, istio-base, istiod, ingressgateway
kubectl -n audita create secret generic audita ...                    # Secret kept outside Git
GHCR_USER=... GHCR_TOKEN=... ./scripts/create-ghcr-secret.sh
kubectl apply -f argocd/root-app.yaml                                 # Argo CD manages the rest
Istio must be installed before applying root-app, because the charts create Gateway, VirtualService, and DestinationRule resources. Sync fails if their CRDs are not installed.
For local development, scripts/bootstrap-k3s-local.sh runs the same setup on k3d (k3s in Docker) with a self-signed certificate. STAGING=1 adds the staging environment; MINIMAL=1 starts only the cluster and Argo CD.
Known trade-offs
Current state	Reason	Next step
Single node	Cost	topologySpreadConstraints are already in the charts; a second node can spread replicas without chart changes
Secrets created manually during bootstrap	Initial simplicity	Sealed Secrets or External Secrets to bring Secrets under GitOps
pncp runs one replica	Rate limiter is in process memory	Move the limiter to Redis, then enable HPA
agents HPA uses CPU	The pod spends most of its time waiting for the LLM API, with low CPU usage	Scale by queue depth with KEDA or move analysis to Kafka
Kafka has one broker	Fits the VPS budget	Add brokers and configure min.insync.replicas when more nodes are available

Repository layout
.
├── argocd/              App of Apps, AppProject, ApplicationSets (production and staging)
├── base/                Production namespace, quota, LimitRange, ConfigMap
├── base-staging/        Staging equivalents
├── apps/
│   ├── <service>/       Chart + values.yaml + values-production.yaml + values-staging.yaml
│   ├── mesh/            Gateway, Certificate, VirtualServices, PeerAuthentication, Sidecar
│   ├── kafka/ redis/    In-cluster dependencies
│   ├── observability/   VictoriaMetrics, VictoriaLogs, Vector, Grafana
│   └── mongo-backup/    Backup CronJob
├── atlas/               Versioned Atlas Search index definition
├── scripts/             k3s, Istio, local (k3d), and GHCR bootstrap scripts
├── .github/workflows/   Reusable workflows and chart validation
└── CAPACIDADE.md        CPU and memory budget behind the resource settings
