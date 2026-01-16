# M2 MOSIG Cloud — Online Boutique on GKE (Standard) + Load Testing + Canary (Istio) + Flagger

This repository contains the code and configuration used to deploy and manage the Online Boutique microservices demo on Google Kubernetes Engine (GKE) in Standard mode, run Locust load testing outside the cluster (locally or on a GCE VM), perform canary releases for adservice using Istio (manual split) and Flagger (automated canary + rollback), and reproduce autoscaling experiments (HPA + GKE Cluster Autoscaler).

## Project structure (where to find the code)

**Note:** The application code and base Kubernetes manifests come from the upstream repository GoogleCloudPlatform/microservices-demo. This repo adds overlays, IaC, and scripts/configs needed for the lab.

```text
.
├── cloudbuild.yaml                             # Cloud Build pipeline (build & push images)
├── kustomize/
│   ├── base/                                   # Base manifests (upstream)
│   └── overlays/
│       ├── m2-gke-standard-small/               # Lab overlay (GKE deployment)
│       ├── canary-adservice/                   # Manual canary with Istio (v1/v2)
│       ├── flagger-adservice/                  # Automated canary with Flagger (v3)
│       └── autoscaling-frontend/               # Frontend HPA configuration
├── src/
│   └── loadgenerator/                          # Local load generator (Docker)
│       └── Dockerfile
├── infra/
│   └── loadgen-vm/                             # Automated load generator on GCE (Terraform)
│       └── Terraform configuration files
└── monitoring/                                 # Custom Prometheus alerts and Redis monitoring
    ├── frontend-alert.yaml                     # Saturation alert rules
    ├── redis-monitor.yaml                      # Redis ServiceMonitor
    └── patched-redis-cart.yaml                 # Redis sidecar deployment

```
## Reproducibility instructions


### SECTION 1 — Deploy Online Boutique on GKE + Locust load testing

#### 0) Prerequisites

- Enable required APIs:

```bash
gcloud services enable compute.googleapis.com container.googleapis.com
```

- Configure region/zone:

```bash
gcloud config set compute/region europe-west6
gcloud config set compute/zone europe-west6-a
```

#### 1) Create the GKE cluster (Standard mode)

```bash
CLUSTER_NAME=boutique-cluster
gcloud container clusters create "$CLUSTER_NAME"
gcloud container clusters get-credentials "$CLUSTER_NAME"
```

**Verify:**

```bash
kubectl get nodes
```

#### 2) Get the source code

```bash
git clone https://github.com/GoogleCloudPlatform/microservices-demo.git
cd microservices-demo
```

#### 3) Deploy Online Boutique with the lab Kustomize overlay

**Overlay used:**
- `kustomize/overlays/m2-gke-standard-small`

**Optional render check:**

```bash
kubectl kustomize kustomize/overlays/m2-gke-standard-small | head
```

**Apply:**

```bash
kubectl apply -k kustomize/overlays/m2-gke-standard-small
```

**Wait and verify:**

```bash
kubectl get pods -w
```

**Get Frontend external IP:**

```bash
kubectl get svc frontend-external
FRONTEND_IP=$(kubectl get svc frontend-external -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "$FRONTEND_IP"
curl -I "http://$FRONTEND_IP"
```

#### 4) Local load generator (manual, Docker)

**Build:**

```bash
docker build -t boutique-loadgen:local ./src/loadgenerator
```

**Run Locust (headless) against the frontend:**

```bash
docker run --rm \
  -e FRONTEND_ADDR="$FRONTEND_IP" \
  -e USERS=20 \
  -e RATE=5 \
  boutique-loadgen:local
```

**Stop:** `Ctrl+C`

#### 5) Automated load generator on a GCE VM (Terraform)

**Go to Terraform folder:**

```bash
cd infra/loadgen-vm
terraform init
```

**Create/update terraform.tfvars:**

```hcl
project_id       = "m2-cloud-computing-478123"
region           = "europe-west6"
zone             = "europe-west6-a"
frontend_addr    = "34.65.171.116"   # IMPORTANT: replace with the actual FRONTEND_IP
users            = 20
rate             = 5
duration         = "2m"
export_csv       = true
enable_locust_ui = false
use_spot         = true
```

**Apply:**

```bash
terraform apply -auto-approve
```

**SSH + verify:**

```bash
gcloud compute ssh loadgen-vm --zone europe-west6-a
docker ps
docker logs -f loadgen
```

**If CSV export enabled:**

```bash
ls -lh /var/locust
```

**Copy results back to Cloud Shell:**

```bash
exit
gcloud compute scp --recurse loadgen-vm:/var/locust ./locust-results-vm --zone europe-west6-a
```

#### 6) Locust UI mode (optional)

**In terraform.tfvars:**

```hcl
enable_locust_ui = true
```

**Apply:**

```bash
terraform apply -auto-approve
```

**Get VM public IP:**

```bash
terraform output loadgen_external_ip
```

**Open:**

```
http://<VM_EXTERNAL_IP>:8089
```

#### 7) Cleanup

**Destroy load generator VM + firewall rules:**

```bash
cd infra/loadgen-vm
terraform destroy -auto-approve
```

**Delete Online Boutique:**

```bash
cd ~/microservices-demo
kubectl delete -k kustomize/overlays/m2-gke-standard-small
```

**Delete GKE cluster:**

```bash
gcloud container clusters delete boutique-cluster
```

#### Notes:

- Overlay `m2-gke-standard-small`:
  - deletes in-cluster loadgenerator (Deployment + ServiceAccount)
  - reduces CPU requests for adservice and recommendationservice
- Load generator VM runs Locust automatically from a startup script and can export CSV to `/var/locust`

### SECTION 2 — Reproducibility: Manual Canary release with Istio (adservice v1/v2)

#### Prerequisites

- Online Boutique running on GKE
- Istio installed
- Sidecar injection enabled in default:

```bash
kubectl label namespace default istio-injection=enabled --overwrite
```

#### 1) Build & push adservice:v2 with Google Cloud Build (`cloudbuild.yaml`):

```bash
export IMAGE_URI="europe-west6-docker.pkg.dev/m2-cloud-computing-478123/online-boutique/adservice:v2"
gcloud builds submit ./src/adservice --tag "$IMAGE_URI"
```

#### 2) Deploy canary resources (v1 + v2 + Istio routing)

```bash
kubectl apply -k kustomize/overlays/canary-adservice
kubectl get pods -l app=adservice
kubectl get virtualservice adservice -o yaml
kubectl get destinationrule adservice -o yaml
```

#### 3) Generate traffic (to observe split)

**Example (local Locust):**

```bash
FRONTEND_IP=$(kubectl get svc frontend-external -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
# docker run --rm -e FRONTEND_ADDR="$FRONTEND_IP" -e USERS=40 -e RATE=5 boutique-loadgen:local

cd infra/loadgen-vm
terraform init
terraform apply -auto-approve
```

#### 4) Verify the split (75/25)

**Pick one:**

- **Kiali:** Graph → namespace default → filter adservice → confirm ~75% v1 / ~25% v2.
<!-- - **Logs (quick check):**

```bash
kubectl logs -l app=adservice,version=v1 --since=5m | wc -l
kubectl logs -l app=adservice,version=v2 --since=5m | wc -l
``` -->

#### 5) Promote v2 to 100%

Update VirtualService weights (in overlay) to v1=0, v2=100 and apply:

```bash
kubectl apply -k kustomize/overlays/canary-adservice
```

**Optional:** scale down v1 once 100% is on v2:

```bash
kubectl scale deploy adservice --replicas=0
```

#### 6) Rollback to v1

Set weights back to v1=100, v2=0 and apply:

```bash
kubectl apply -k kustomize/overlays/canary-adservice
```

**If v1 was scaled down:**

```bash
kubectl scale deploy adservice --replicas=1
```

#### 7) Cleanup

```bash
kubectl delete -k kustomize/overlays/canary-adservice
```

### SECTION 3 — Reproducibility: Automated Canary + Rollback with Flagger (adservice v3)

#### 0) Prerequisites

- Online Boutique deployed and healthy
- Istio installed + sidecar injection enabled on default
- Prometheus running (Istio telemetry available)
- Flagger installed (CRDs + controller)

**Quick checks:**

```bash
kubectl get pods -n istio-system | egrep 'istiod|prometheus'
kubectl get crd | grep flagger
kubectl get pods -A | grep flagger
```

#### 1) Set stable baseline = v2 (primary)

```bash
PROJECT_ID="m2-cloud-computing-478123"
IMAGE_V2="europe-west6-docker.pkg.dev/${PROJECT_ID}/online-boutique/adservice:v2"

kubectl -n default set image deploy/adservice server="$IMAGE_V2"
kubectl -n default rollout status deploy/adservice
```

#### 2) Remove manual Istio canary objects (avoid conflicts)

**If we previously created our own VirtualService/DestinationRule:**

```bash
kubectl delete virtualservice adservice --ignore-not-found
kubectl delete destinationrule adservice --ignore-not-found
```

#### 3) Apply Flagger setup for adservice

**Apply your Flagger overlay:**

```bash
kubectl apply -k kustomize/overlays/flagger-adservice

# or apply the canary directly:
kubectl apply -f kustomize/overlays/flagger-adservice/adservice-canary.yaml
```

**Verify Flagger created services and routing:**

```bash
kubectl get canary adservice
kubectl get svc | grep adservice
kubectl get virtualservice,destinationrule | grep adservice
```

**Expected:**
- `adservice-primary` and `adservice-canary` exist
- Flagger-managed VirtualService exists for host `adservice`

#### 4) Start sustained traffic (required for metrics)

Run the load generator continuously (Locust VM or local).

**(Terraform VM approach):**

```bash
cd infra/loadgen-vm
terraform init
terraform apply -auto-approve"
```

**Check Locust:**

```bash
gcloud compute ssh loadgen-vm --zone europe-west6-a --command "docker ps"
```

#### 5) Create defective v3 + build/push

**Code idea:** add artificial delay in `getAds(...)` and handle `InterruptedException`.

**Build/push with Cloud Build:**

```bash
cd ~/microservices-demo
PROJECT_ID="m2-cloud-computing-478123"
IMAGE_V3="europe-west6-docker.pkg.dev/${PROJECT_ID}/online-boutique/adservice:v3"

gcloud builds submit . \
  --config cloudbuild.yaml \
  --substitutions=_IMAGE_URI="$IMAGE_V3"
```

#### 6) Trigger Flagger analysis (deploy v3)

```bash
kubectl -n default set image deploy/adservice server="$IMAGE_V3"
```

**Watch progression:**

```bash
kubectl get canary adservice -w
kubectl describe canary adservice | tail -n 60
```

#### 7) Expected outcome: automatic rollback

With sustained traffic, Flagger should:
- shift traffic gradually to canary
- detect bad metrics ( request duration too high)
- rollback and route traffic back to `adservice-primary`

**Confirm rollback:**

```bash
kubectl describe canary adservice | egrep -i "failed|rollback|promotion|weight"
kubectl get pods | grep adservice
```

#### 8) Reset / Retest

Ensure traffic is still running.

**Re-apply v2 baseline:**

```bash
kubectl -n default set image deploy/adservice server="$IMAGE_V2"
kubectl rollout status deploy/adservice
```

**Re-deploy v3 to trigger canary again:**

```bash
kubectl -n default set image deploy/adservice server="$IMAGE_V3"
```

#### 9) Cleanup (optional)

**Stop load generator:**

```bash
cd infra/loadgen-vm
terraform destroy -auto-approve
```

**Remove Flagger objects (optional):**

```bash
kubectl delete canary adservice --ignore-not-found
kubectl delete svc adservice-primary adservice-canary --ignore-not-found
kubectl delete virtualservice adservice --ignore-not-found
kubectl delete destinationrule adservice-primary adservice-canary --ignore-not-found
```

### SECTION 4 — Reproducibility: Autoscaling experiment (HPA + Cluster Autoscaler)

This section assumes the autoscaling configuration (HPA overlay / manifests) already exists in the repo. The goal here is to re-run the experiment and capture evidence.

#### A) Validate prerequisites (metrics + frontend requests)

HPA requires working metrics. These must return values:

```bash
kubectl top pods
kubectl top nodes
```

**Check that frontend has CPU requests set (CPU HPA uses CPU usage as a % of requests):**

```bash
kubectl -n default get deploy frontend -o jsonpath='{.spec.template.spec.containers[0].resources}{"\n"}'
```

#### B) Apply autoscaling config (HPA on frontend)

**Apply the autoscaling overlay:**

```bash
kubectl apply -k kustomize/overlays/autoscaling-frontend
```

**Verify HPA is created and targeting frontend:**

```bash
kubectl get hpa
kubectl describe hpa frontend-hpa
```

**Watch scaling live:**

```bash
kubectl get hpa frontend-hpa -w
kubectl get pods -l app=frontend -w
```

#### C) Enable GKE Cluster Autoscaler (node pool)

**Identify the node pool name (don't assume):**

```bash
CLUSTER_NAME=boutique-cluster
ZONE=europe-west6-a

gcloud container node-pools list --cluster "$CLUSTER_NAME" --zone "$ZONE"
```

**Enable autoscaling (example min/max :3 / 6):**

```bash
POOL_NAME=default-pool

gcloud container node-pools update "$POOL_NAME" \
  --cluster "$CLUSTER_NAME" \
  --zone "$ZONE" \
  --enable-autoscaling \
  --min-nodes 3 \
  --max-nodes 6
```

**Validate scale-out under pressure (while load runs):**

```bash
kubectl get nodes -w
kubectl get events --sort-by=.lastTimestamp | tail -n 30
```

**Expected behavior:**
- HPA increases frontend replicas under load
- if pods become Pending, Cluster Autoscaler adds nodes
- pods schedule once capacity exists

#### D) Re-run load tests (prove autoscaling works)

Use the same load generator method as before (local Docker Locust or Terraform VM). For the VM approach, increase load:

- baseline (20 users)
- 100 users
- 300 users
- 400+ users

**Example high-load configuration (Terraform):**

```hcl
users = 400
rate = 20
duration = "5m"
export_csv = true
```

**Run:**

```bash
cd infra/loadgen-vm
terraform apply -auto-approve
```

**Copy CSV results:**

```bash
gcloud compute scp --recurse loadgen-vm:/var/locust ./locust-results-autoscaling --zone europe-west6-a
```

#### Cleanup

**Remove autoscaling overlay:**

```bash
kubectl delete -k kustomize/overlays/autoscaling-frontend
```

**Disable node pool autoscaling:**

```bash
gcloud container node-pools update "$POOL_NAME" \
  --cluster "$CLUSTER_NAME" \
  --zone "$ZONE" \
  --no-enable-autoscaling
```
