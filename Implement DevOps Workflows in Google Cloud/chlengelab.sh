#!/bin/bash
set -Eeuo pipefail

# ==========================================================
# PERKVERSE | GSP330 - Implement DevOps Workflows in Google Cloud
# FINAL integrated script: Tasks 1 - 6
#   * Region/zone auto-detected from the lab's git-server VM
#   * Git server IP auto-detected (nothing hardcoded)
#   * Safe to re-run
# Run in Cloud Shell:  bash ~/perkverse-gsp330-final.sh
# ==========================================================

RED=$(tput setaf 1 2>/dev/null || true)
GREEN=$(tput setaf 2 2>/dev/null || true)
YELLOW=$(tput setaf 3 2>/dev/null || true)
BLUE=$(tput setaf 4 2>/dev/null || true)
RESET=$(tput sgr0 2>/dev/null || true)

step() {
  echo
  echo "${BLUE}==================================================${RESET}"
  echo "${YELLOW}$1${RESET}"
  echo "${BLUE}==================================================${RESET}"
}

fail() {
  echo "${RED}ERROR: $*${RESET}" >&2
  exit 1
}

trap 'echo "${RED}Script failed at line $LINENO. Upar wala error copy karke bhejo.${RESET}" >&2' ERR

command -v gcloud  >/dev/null || fail "gcloud CLI not found."
command -v kubectl >/dev/null || fail "kubectl not found."
command -v git     >/dev/null || fail "git not found."
command -v python3 >/dev/null || fail "python3 not found."
command -v curl    >/dev/null || fail "curl not found."

# ----------------------------------------------------------
# Project + auto-detected location
# ----------------------------------------------------------
export PROJECT_ID
PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"
[[ -n "$PROJECT_ID" && "$PROJECT_ID" != "(unset)" ]] ||
  fail "No active project. Open the lab's Cloud Shell first."

export PROJECT_NUMBER
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"

step "Detecting lab zone / region from git-server VM"

gcloud services enable compute.googleapis.com --project="$PROJECT_ID" >/dev/null

GIT_SERVER_ZONE="$(gcloud compute instances list \
  --project="$PROJECT_ID" \
  --filter='name=git-server' \
  --format='value(zone.basename())' | head -n 1)"

[[ -n "$GIT_SERVER_ZONE" ]] ||
  fail "git-server VM not found. Run: gcloud compute instances list"

export ZONE="$GIT_SERVER_ZONE"
export REGION="${ZONE%-*}"
export CLUSTER="hello-cluster"
export REPO="my-repository"

echo "Project : $PROJECT_ID ($PROJECT_NUMBER)"
echo "Zone    : $ZONE"
echo "Region  : $REGION"

gcloud config set compute/region "$REGION" >/dev/null 2>&1
gcloud config set compute/zone "$ZONE" >/dev/null 2>&1
gcloud config set builds/region "$REGION" >/dev/null 2>&1

export GIT_SERVER_IP
GIT_SERVER_IP="$(gcloud compute instances describe git-server \
  --zone="$ZONE" --project="$PROJECT_ID" \
  --format='value(networkInterfaces[0].accessConfigs[0].natIP)')"
[[ -n "$GIT_SERVER_IP" ]] || fail "Could not read git-server external IP."

GIT_URL="http://${GIT_SERVER_IP}:3000/giteaadmin/sample-app.git"
AUTH_GIT_URL="http://giteaadmin:GiteaPassword123@${GIT_SERVER_IP}:3000/giteaadmin/sample-app.git"
echo "Git IP  : $GIT_SERVER_IP"

# ----------------------------------------------------------
# Helper: python editor for cloudbuild + deployment manifests
# ----------------------------------------------------------
cat > /tmp/perk_edit.py <<'PY'
import re, sys
config, image, version, manifest, project, region, zone = sys.argv[1:8]

s = open(config).read()
s = s.replace('<version>', version).replace('<your-region>', region).replace('<your-zone>', zone)
s = re.sub(r'[a-z0-9-]+-docker\.pkg\.dev/[^/\s\'"]+/my-repository/[^:\s\'"]+:[^\s\'"]+',
           f'{region}-docker.pkg.dev/$PROJECT_ID/my-repository/{image}:{version}', s)
s = re.sub(r'CLOUDSDK_COMPUTE_(?:REGION|ZONE)=[A-Za-z0-9<>-]+', f'CLOUDSDK_COMPUTE_ZONE={zone}', s)
open(config, 'w').write(s)

p = open(manifest).read()
new_image = f'{region}-docker.pkg.dev/{project}/my-repository/{image}:{version}'
p = re.sub(r'^(\s*-?\s*image:\s*).*$', lambda m: m.group(1) + new_image, p, count=1, flags=re.M)
open(manifest, 'w').write(p)
PY

cat > /tmp/perk_red.py <<'PY'
import re
s = open('main.go').read()
if 'redHandler' in s:
    print('redHandler already present')
else:
    m = re.search(r'func blueHandler\(.*?\n}\n', s, re.S)
    if m:
        func = m.group(0).replace('blueHandler', 'redHandler').replace('blue', 'red').replace('Blue', 'Red')
    else:
        func = ('func redHandler(w http.ResponseWriter, r *http.Request) {\n'
                '\tw.Header().Set("Content-Type", "image/svg+xml")\n'
                '\tfmt.Fprint(w, `<svg width="100" height="100"><circle cx="50" cy="50" r="40" fill="red" /></svg>`)\n'
                '}\n')
    reg = re.search(r'^(\s*)http\.HandleFunc\("/blue",.*$', s, re.M) or \
          re.search(r'^(\s*)http\.HandleFunc\("/",.*$', s, re.M)
    if not reg:
        raise SystemExit('Could not find http.HandleFunc in main.go - add /red handler manually.')
    line = reg.group(0)
    indent = reg.group(1)
    s = s.replace(line, line + '\n' + indent + 'http.HandleFunc("/red", redHandler)', 1)
    s = s.rstrip('\n') + '\n\n' + func
    open('main.go', 'w').write(s)
    print('Added /red handler')
PY

edit_cfg() { # config image version manifest
  python3 /tmp/perk_edit.py "$1" "$2" "$3" "$4" "$PROJECT_ID" "$REGION" "$ZONE"
}

# ==========================================================
# TASK 1 - services, IAM, Artifact Registry, GKE, namespaces
# ==========================================================
step "Task 1: Enable services + IAM"

gcloud services enable \
  cloudbuild.googleapis.com \
  container.googleapis.com \
  artifactregistry.googleapis.com \
  --project="$PROJECT_ID"

for SA in "${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com" \
          "${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"; do
  for ROLE in roles/container.developer roles/artifactregistry.writer \
              roles/logging.logWriter roles/storage.objectViewer; do
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
      --member="serviceAccount:${SA}" --role="$ROLE" --quiet >/dev/null 2>&1 || true
  done
done

step "Task 1: Artifact Registry repository ($REPO in $REGION)"

if gcloud artifacts repositories describe "$REPO" \
     --location="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1; then
  echo "Repository already exists."
else
  gcloud artifacts repositories create "$REPO" \
    --repository-format=docker \
    --location="$REGION" \
    --description="Docker repository" \
    --project="$PROJECT_ID"
fi

step "Task 1: GKE cluster ($CLUSTER in $ZONE)"

if ! gcloud container clusters describe "$CLUSTER" \
     --zone="$ZONE" --project="$PROJECT_ID" >/dev/null 2>&1; then
  gcloud container clusters create "$CLUSTER" \
    --zone="$ZONE" \
    --project="$PROJECT_ID" \
    --release-channel=regular \
    --num-nodes=3 \
    --enable-autoscaling --min-nodes=2 --max-nodes=6
fi

gcloud container clusters get-credentials "$CLUSTER" \
  --zone="$ZONE" --project="$PROJECT_ID"

kubectl get namespace prod >/dev/null 2>&1 || kubectl create namespace prod
kubectl get namespace dev  >/dev/null 2>&1 || kubectl create namespace dev

# ==========================================================
# TASK 2 - sample app + Git repo (master + dev)
# ==========================================================
step "Task 2: Sample app + push master/dev branches"

mkdir -p "$HOME/sample-app"
if [[ ! -f "$HOME/sample-app/cloudbuild.yaml" ]]; then
  gcloud storage cp -r "gs://spls/gsp330/sample-app/*" "$HOME/sample-app/"
fi
cd "$HOME/sample-app"

git config user.name "Student"
git config user.email "student@qwiklabs.net"

[[ -f cloudbuild.yaml && -f cloudbuild-dev.yaml ]] || fail "cloudbuild yaml files missing in sample-app."
[[ -f prod/deployment.yaml && -f dev/deployment.yaml ]] || fail "deployment.yaml files missing in sample-app."

[[ -d .git ]] || git init
git checkout master 2>/dev/null || git checkout -b master 2>/dev/null || git branch -M master

if git remote get-url origin >/dev/null 2>&1; then
  git remote set-url origin "$GIT_URL"
else
  git remote add origin "$GIT_URL"
fi

# fill placeholders (v1.0) on master
edit_cfg cloudbuild.yaml     hello-cloudbuild     v1.0 prod/deployment.yaml
edit_cfg cloudbuild-dev.yaml hello-cloudbuild-dev v1.0 dev/deployment.yaml

git add .
git diff --cached --quiet || git commit -m "Initial application configuration"
git push "$AUTH_GIT_URL" master

if git show-ref --verify --quiet refs/heads/dev; then
  git checkout dev
else
  git checkout -b dev
fi
git push "$AUTH_GIT_URL" dev
git checkout master

# ==========================================================
# TASK 3 - Cloud Build triggers
# ==========================================================
step "Task 3: Cloud Build triggers"

COMPUTE_SA="projects/${PROJECT_ID}/serviceAccounts/${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

if ! gcloud builds triggers describe sample-app-prod-deploy --region="$REGION" >/dev/null 2>&1; then
  gcloud builds triggers create manual \
    --name="sample-app-prod-deploy" \
    --inline-config="cloudbuild.yaml" \
    --service-account="$COMPUTE_SA" \
    --region="$REGION"
fi

if ! gcloud builds triggers describe sample-app-dev-deploy --region="$REGION" >/dev/null 2>&1; then
  gcloud builds triggers create manual \
    --name="sample-app-dev-deploy" \
    --inline-config="cloudbuild-dev.yaml" \
    --service-account="$COMPUTE_SA" \
    --region="$REGION"
fi

gcloud builds triggers list --region="$REGION"

# ==========================================================
# Helpers for Tasks 4-6
# ==========================================================
commit_push() { # branch message files...
  local branch="$1" msg="$2"; shift 2
  git add "$@"
  git diff --cached --quiet || git commit -m "$msg"
  git push "$AUTH_GIT_URL" "$branch"
}

build_retry() { # config
  local config="$1" attempt id
  for attempt in 1 2; do
    echo "Building with $config (attempt $attempt/2)"
    if gcloud builds submit --project="$PROJECT_ID" --region="$REGION" --config="$config" .; then
      return 0
    fi
    id="$(gcloud builds list --project="$PROJECT_ID" --region="$REGION" \
          --limit=1 --sort-by='~createTime' --format='value(id)' 2>/dev/null || true)"
    if [[ -n "$id" ]]; then
      gcloud builds log "$id" --project="$PROJECT_ID" --region="$REGION" 2>&1 | tail -60 || true
    fi
    sleep 5
  done
  fail "Build failed twice using $config."
}

ensure_lb() { # namespace dir
  local ns="$1" dir="$2" dep
  [[ -f "$dir/service.yaml" ]] && kubectl apply -f "$dir/service.yaml" -n "$ns" 2>/dev/null || true
  if ! kubectl get svc -n "$ns" -o jsonpath='{.items[*].spec.type}' | grep -q LoadBalancer; then
    dep="$(kubectl get deploy -n "$ns" -o jsonpath='{.items[0].metadata.name}')"
    [[ -n "$dep" ]] || fail "No deployment found in namespace $ns."
    kubectl expose deployment "$dep" -n "$ns" --type=LoadBalancer \
      --port=8080 --target-port=8080 --name="${ns}-deployment-service"
  fi
}

lb_ip() { # namespace
  local ns="$1" ip="" i
  for i in $(seq 1 40); do
    ip="$(kubectl get svc -n "$ns" \
      -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.status.loadBalancer.ingress[0].ip}{end}' 2>/dev/null || true)"
    [[ -n "$ip" ]] && break
    sleep 8
  done
  echo "$ip"
}

lb_port() { # namespace
  kubectl get svc -n "$1" \
    -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.spec.ports[0].port}{end}' 2>/dev/null
}

http_code() { # ns path
  local ip port
  ip="$(lb_ip "$1")"; port="$(lb_port "$1")"
  [[ -n "$ip" ]] || { echo "no-ip"; return; }
  curl -s -o /dev/null -m 10 -w '%{http_code}' "http://${ip}:${port:-8080}$2" || echo "curl-failed"
}

# ==========================================================
# TASK 4 - v1.0 on dev and prod
# ==========================================================
step "Task 4: Dev v1.0"

git checkout dev
edit_cfg cloudbuild-dev.yaml hello-cloudbuild-dev v1.0 dev/deployment.yaml
commit_push dev "Dev v1.0 configuration" cloudbuild-dev.yaml dev/deployment.yaml
build_retry cloudbuild-dev.yaml
ensure_lb dev dev

step "Task 4: Production v1.0"

git checkout master
edit_cfg cloudbuild.yaml hello-cloudbuild v1.0 prod/deployment.yaml
commit_push master "Production v1.0 configuration" cloudbuild.yaml prod/deployment.yaml
build_retry cloudbuild.yaml
ensure_lb prod prod

echo "Dev  /      -> HTTP $(http_code dev /)"
echo "Prod /      -> HTTP $(http_code prod /)"

# ==========================================================
# TASK 5 - v2.0 with /red handler (dev, then prod)
# ==========================================================
step "Task 5: Dev v2.0 (/red handler)"

git checkout dev
python3 /tmp/perk_red.py
edit_cfg cloudbuild-dev.yaml hello-cloudbuild-dev v2.0 dev/deployment.yaml
commit_push dev "Add /red handler - dev v2.0" main.go cloudbuild-dev.yaml dev/deployment.yaml
git tag -f v2.0 >/dev/null 2>&1 && git push -f "$AUTH_GIT_URL" v2.0 >/dev/null 2>&1 || true
build_retry cloudbuild-dev.yaml
kubectl rollout status deployment -n dev --timeout=180s || true
echo "Dev /red    -> HTTP $(http_code dev /red)  (expected 200)"

step "Task 5: Production v2.0"

git checkout master
git checkout dev -- main.go
edit_cfg cloudbuild.yaml hello-cloudbuild v2.0 prod/deployment.yaml
commit_push master "Add /red handler - production v2.0" main.go cloudbuild.yaml prod/deployment.yaml
build_retry cloudbuild.yaml
kubectl rollout status deployment -n prod --timeout=180s || true
echo "Prod /red   -> HTTP $(http_code prod /red)  (expected 200)"

# ==========================================================
# TASK 6 - Roll back production to v1.0
# ==========================================================
step "Task 6: Roll back production to v1.0"

PROD_DEP="$(kubectl get deploy -n prod -o jsonpath='{.items[0].metadata.name}')"
PROD_IMG="${REGION}-docker.pkg.dev/${PROJECT_ID}/my-repository/hello-cloudbuild:v1.0"

# v1.0 image already exists from Task 4 -> reuse it (no rebuild, /red stays 404)
kubectl set image "deployment/${PROD_DEP}" "*=${PROD_IMG}" -n prod
kubectl rollout status "deployment/${PROD_DEP}" -n prod --timeout=240s

# keep git in sync with what is running
edit_cfg cloudbuild.yaml hello-cloudbuild v1.0 prod/deployment.yaml
commit_push master "Rollback production to v1.0" cloudbuild.yaml prod/deployment.yaml

echo
echo "Prod image  : $(kubectl get deploy "$PROD_DEP" -n prod -o jsonpath='{.spec.template.spec.containers[0].image}')"
echo "Prod /      -> HTTP $(http_code prod /)     (expected 200)"
echo "Prod /red   -> HTTP $(http_code prod /red)  (expected 404)"
echo "Dev  /red   -> HTTP $(http_code dev /red)   (expected 200)"

step "DONE"
echo "${GREEN}Ab Skills Boost mein Tasks 1-6 ke 'Check my progress' click karo.${RESET}"
kubectl get svc -A | grep -E 'NAMESPACE|LoadBalancer' || true
