#!/bin/bash
set -Eeuo pipefail

# ==========================================================
# PERKVERSE | GSP330
# Implement DevOps Workflows in Google Cloud
# ==========================================================

BLACK=$(tput setaf 0 2>/dev/null || true)
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

command -v gcloud >/dev/null || fail "gcloud CLI not found."
command -v kubectl >/dev/null || fail "kubectl not found."
command -v git >/dev/null || fail "git not found."

export PROJECT_ID
PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"
[[ -n "$PROJECT_ID" && "$PROJECT_ID" != "(unset)" ]] ||
  fail "No active project. Open the lab's Cloud Shell first."

export PROJECT_NUMBER
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" \
  --format='value(projectNumber)')"

export REGION="us-east1"
export ZONE="us-east1-c"
export CLUSTER="hello-cluster"
export REPO="my-repository"

gcloud config set compute/region "$REGION"
gcloud config set compute/zone "$ZONE"
gcloud config set builds/region "$REGION"

step "PERKVERSE | Task 1: Enable required services"

gcloud services enable \
  cloudbuild.googleapis.com \
  container.googleapis.com \
  artifactregistry.googleapis.com

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com" \
  --role="roles/container.developer" \
  --quiet

step "Create Artifact Registry repository"

if ! gcloud artifacts repositories describe "$REPO" \
  --location="$REGION" >/dev/null 2>&1; then
  gcloud artifacts repositories create "$REPO" \
    --repository-format=docker \
    --location="$REGION" \
    --description="GSP330 application repository"
fi

step "Create GKE cluster"

if ! gcloud container clusters describe "$CLUSTER" \
  --zone="$ZONE" >/dev/null 2>&1; then
  gcloud container clusters create "$CLUSTER" \
    --zone="$ZONE" \
    --release-channel=regular \
    --num-nodes=3 \
    --enable-autoscaling \
    --min-nodes=2 \
    --max-nodes=6
fi

gcloud container clusters get-credentials "$CLUSTER" \
  --zone="$ZONE" \
  --project="$PROJECT_ID"

kubectl get namespace prod >/dev/null 2>&1 ||
  kubectl create namespace prod

kubectl get namespace dev >/dev/null 2>&1 ||
  kubectl create namespace dev

step "Task 2: Download the official lab sample application"

cd "$HOME"
mkdir -p "$HOME/sample-app"

gcloud storage cp -r \
  gs://spls/gsp330/sample-app/* \
  "$HOME/sample-app/"

cd "$HOME/sample-app"

export GIT_SERVER_IP
GIT_SERVER_IP="$(gcloud compute instances describe git-server \
  --zone="$ZONE" \
  --format='value(networkInterfaces[0].accessConfigs[0].natIP)')"

[[ -n "$GIT_SERVER_IP" ]] ||
  fail "Could not find the git-server IP in zone $ZONE."

GIT_URL="http://${GIT_SERVER_IP}:3000/giteaadmin/sample-app.git"
AUTH_GIT_URL="http://giteaadmin:GiteaPassword123@${GIT_SERVER_IP}:3000/giteaadmin/sample-app.git"

git config user.name "Student"
git config user.email "student@qwiklabs.net"

for file in cloudbuild.yaml cloudbuild-dev.yaml; do
  [[ -f "$file" ]] || fail "Missing $file in sample-app."

  sed -i \
    -e "s|<your-region>|${REGION}|g" \
    -e "s|<your-zone>|${ZONE}|g" \
    -e 's|<version>|v1.0|g' \
    "$file"
done

if [[ ! -d .git ]]; then
  git init
fi

git branch -M master

if git remote get-url origin >/dev/null 2>&1; then
  git remote set-url origin "$GIT_URL"
else
  git remote add origin "$GIT_URL"
fi

git add .
if ! git diff --cached --quiet; then
  git commit -m "Initial application configuration"
fi

git push "$AUTH_GIT_URL" master

if git show-ref --verify --quiet refs/heads/dev; then
  git checkout dev
else
  git checkout -b dev
fi

git push "$AUTH_GIT_URL" dev
git checkout master

step "Task 3: Create correctly configured manual triggers"

if ! gcloud builds triggers describe sample-app-prod-deploy \
  --region="$REGION" >/dev/null 2>&1; then
  gcloud builds triggers create manual \
    --name="sample-app-prod-deploy" \
    --inline-config="cloudbuild.yaml" \
    --service-account="projects/${PROJECT_ID}/serviceAccounts/${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
    --region="$REGION"
fi

if ! gcloud builds triggers describe sample-app-dev-deploy \
  --region="$REGION" >/dev/null 2>&1; then
  gcloud builds triggers create manual \
    --name="sample-app-dev-deploy" \
    --inline-config="cloudbuild-dev.yaml" \
    --service-account="projects/${PROJECT_ID}/serviceAccounts/${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
    --region="$REGION"
fi

gcloud builds triggers list --region="$REGION"

step "Trigger configuration completed"

echo "${GREEN}Check Task 1, Task 2 and Task 3 in Skills Boost now.${RESET}"
echo "This script intentionally stops here instead of guessing the"
echo "deployment manifests, application source edits and rollback."
echo "Those steps must match the exact supplied sample-app files."


#!/bin/bash
set -Eeuo pipefail

# PERKVERSE - GSP330 Tasks 4, 5 and 6
# Run after Tasks 1-3 have successfully completed.

RED=$(tput setaf 1 2>/dev/null || true)
GREEN=$(tput setaf 2 2>/dev/null || true)
YELLOW=$(tput setaf 3 2>/dev/null || true)
RESET=$(tput sgr0 2>/dev/null || true)

step() {
  echo
  echo "${YELLOW}========== $* ==========${RESET}"
}

fail() {
  echo "${RED}ERROR: $*${RESET}" >&2
  exit 1
}

cd "$HOME/sample-app" || fail "~/sample-app not found"

export PROJECT_ID
PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"
export PROJECT_NUMBER
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" \
  --format='value(projectNumber)')"
export REGION="us-east1"
export ZONE="us-east1-c"

if [[ -z "${GIT_SERVER_IP:-}" ]]; then
  export GIT_SERVER_IP
  GIT_SERVER_IP="$(gcloud compute instances describe git-server \
    --zone="$ZONE" \
    --format='value(networkInterfaces[0].accessConfigs[0].natIP)')"
fi

AUTH_GIT_URL="http://giteaadmin:GiteaPassword123@${GIT_SERVER_IP}:3000/giteaadmin/sample-app.git"

git config user.name "Student"
git config user.email "student@qwiklabs.net"

# Replace PROJECT_ID and the lab placeholders.
for f in cloudbuild.yaml cloudbuild-dev.yaml \
         dev/deployment.yaml prod/deployment.yaml; do
  [[ -f "$f" ]] || fail "Missing required file: $f"
  sed -i "s/PROJECT_ID/${PROJECT_ID}/g" "$f"
  sed -i "s/<your-region>/${REGION}/g" "$f"
  sed -i "s/<your-zone>/${ZONE}/g" "$f"
done

# Discover the image repository names from the build configuration.
get_image() {
  local file="$1"
  grep -Eo 'us-east1-docker\.pkg\.dev/[^[:space:]"]+' "$file" |
    head -n 1 | sed 's/[",]$//'
}

# Add the /red route and handler to main.go safely.
add_red_handler() {
python3 - <<'PY'
from pathlib import Path
import re

p = Path("main.go")
s = p.read_text()

main_pattern = r'func main\(\)\s*\{.*?\n\}'
m = re.search(main_pattern, s, re.S)
if not m:
    raise SystemExit("ERROR: Could not find func main() in main.go")

main = m.group(0)
if 'http.HandleFunc("/red", redHandler)' not in main:
    if 'http.HandleFunc("/blue", blueHandler)' not in main:
        raise SystemExit("ERROR: Existing /blue handler registration not found")
    main = main.replace(
        'http.HandleFunc("/blue", blueHandler)',
        'http.HandleFunc("/blue", blueHandler)\n\thttp.HandleFunc("/red", redHandler)',
        1
    )
    s = s[:m.start()] + main + s[m.end():]

if not re.search(r'func\s+redHandler\s*\(', s):
    handler = r'''
func redHandler(w http.ResponseWriter, r *http.Request) {
    img := image.NewRGBA(image.Rect(0, 0, 100, 100))
    draw.Draw(img, img.Bounds(), &image.Uniform{color.RGBA{255, 0, 0, 255}}, image.ZP, draw.Src)
    w.Header().Set("Content-Type", "image/png")
    png.Encode(w, img)
}
'''
    s += "\n" + handler

# Ensure required imports exist.
imports = []
for name in ['"image"', '"image/color"', '"image/draw"', '"image/png"']:
    if name not in s:
        imports.append(name)

if imports:
    im = re.search(r'import\s*\((.*?)\)', s, re.S)
    if im:
        new_block = im.group(0)
        for name in imports:
            new_block = new_block[:-1] + '\t' + name + '\n)'
        s = s[:im.start()] + new_block + s[im.end():]
    else:
        im = re.search(r'import\s+"[^"]+"', s)
        if not im:
            raise SystemExit("ERROR: Could not safely update imports in main.go")
        existing = re.findall(r'"[^"]+"', im.group(0))
        all_imports = existing + imports
        block = 'import (\n' + ''.join('\t' + x + '\n' for x in all_imports) + ')'
        s = s[:im.start()] + block + s[im.end():]

p.write_text(s)
PY
  gofmt -w main.go
}

# Ensure the deployment manifest references the right version.
set_manifest_image() {
  local manifest="$1"
  local image="$2"
  python3 - "$manifest" "$image" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
image = sys.argv[2]
s = p.read_text()
s = re.sub(r'(?m)^(\s*image:\s*).+$', lambda m: m.group(1) + image, s, count=1)
if not re.search(r'(?m)^\s*image:\s*', s):
    raise SystemExit(f"ERROR: No image field found in {p}")
p.write_text(s)
PY
}

apply_deployment() {
  local ns="$1"
  local manifest="$2"
  local deployment="$3"
  local service="$4"

  kubectl apply -n "$ns" -f "$manifest"

  kubectl rollout status "deployment/$deployment" \
    -n "$ns" --timeout=300s

  if ! kubectl get service "$service" -n "$ns" >/dev/null 2>&1; then
    local target_port
    target_port="$(awk '/EXPOSE/{print $2; exit}' Dockerfile)"
    [[ -n "$target_port" ]] || target_port="8080"

    kubectl expose deployment "$deployment" \
      --name="$service" \
      --type=LoadBalancer \
      --port=8080 \
      --target-port="$target_port" \
      -n "$ns"
  fi
}

# ==================== TASK 4: v1.0 ====================

step "TASK 4 - Build first development deployment v1.0"

git checkout dev
sed -i 's/:v2\.0/:v1.0/g' cloudbuild-dev.yaml
DEV_IMAGE="$(get_image cloudbuild-dev.yaml)"
[[ -n "$DEV_IMAGE" ]] || fail "Cannot detect dev image from cloudbuild-dev.yaml"
set_manifest_image dev/deployment.yaml "$DEV_IMAGE"

git add .
if ! git diff --cached --quiet; then
  git commit -m "Deploy v1.0 on dev"
fi
git push "$AUTH_GIT_URL" dev
gcloud builds submit --config=cloudbuild-dev.yaml .

apply_deployment dev dev/deployment.yaml development-deployment dev-deployment-service

step "Verify dev /blue endpoint"
kubectl get service dev-deployment-service -n dev
DEV_LB_IP=""
for i in {1..30}; do
  DEV_LB_IP="$(kubectl get service dev-deployment-service -n dev \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [[ -n "$DEV_LB_IP" ]] && break
  sleep 10
done
if [[ -n "$DEV_LB_IP" ]]; then
  curl -sSI --max-time 20 "http://${DEV_LB_IP}:8080/blue" || true
else
  echo "Dev LoadBalancer IP is still pending."
fi

step "TASK 4 - Build first production deployment v1.0"

git checkout master
sed -i 's/:v2\.0/:v1.0/g' cloudbuild.yaml
PROD_IMAGE="$(get_image cloudbuild.yaml)"
[[ -n "$PROD_IMAGE" ]] || fail "Cannot detect prod image from cloudbuild.yaml"
set_manifest_image prod/deployment.yaml "$PROD_IMAGE"

git add .
if ! git diff --cached --quiet; then
  git commit -m "Deploy v1.0 on master"
fi
git push "$AUTH_GIT_URL" master
gcloud builds submit --config=cloudbuild.yaml .

apply_deployment prod prod/deployment.yaml production-deployment prod-deployment-service

step "Verify production /blue endpoint"
kubectl get service prod-deployment-service -n prod
PROD_LB_IP=""
for i in {1..30}; do
  PROD_LB_IP="$(kubectl get service prod-deployment-service -n prod \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [[ -n "$PROD_LB_IP" ]] && break
  sleep 10
done
if [[ -n "$PROD_LB_IP" ]]; then
  curl -sSI --max-time 20 "http://${PROD_LB_IP}:8080/blue" || true
else
  echo "Production LoadBalancer IP is still pending."
fi

# ==================== TASK 5: v2.0 ====================

step "TASK 5 - Development v2.0 with /red endpoint"

git checkout dev
add_red_handler
sed -i 's/:v1\.0/:v2.0/g' cloudbuild-dev.yaml
DEV_IMAGE="$(get_image cloudbuild-dev.yaml)"
[[ -n "$DEV_IMAGE" ]] || fail "Cannot detect dev v2 image"
set_manifest_image dev/deployment.yaml "$DEV_IMAGE"

git add .
if ! git diff --cached --quiet; then
  git commit -m "Deploy v2.0 on dev"
fi
git push "$AUTH_GIT_URL" dev
gcloud builds submit --config=cloudbuild-dev.yaml .
kubectl apply -n dev -f dev/deployment.yaml
kubectl rollout status deployment/development-deployment \
  -n dev --timeout=300s

step "Verify dev /red endpoint"
if [[ -n "$DEV_LB_IP" ]]; then
  curl -sSI --max-time 20 "http://${DEV_LB_IP}:8080/red" || true
fi

step "TASK 5 - Production v2.0 with /red endpoint"

git checkout master
add_red_handler
sed -i 's/:v1\.0/:v2.0/g' cloudbuild.yaml
PROD_IMAGE="$(get_image cloudbuild.yaml)"
[[ -n "$PROD_IMAGE" ]] || fail "Cannot detect prod v2 image"
set_manifest_image prod/deployment.yaml "$PROD_IMAGE"

git add .
if ! git diff --cached --quiet; then
  git commit -m "Deploy v2.0 on master"
fi
git push "$AUTH_GIT_URL" master
gcloud builds submit --config=cloudbuild.yaml .
kubectl apply -n prod -f prod/deployment.yaml
kubectl rollout status deployment/production-deployment \
  -n prod --timeout=300s

step "Verify production /red endpoint"
if [[ -n "$PROD_LB_IP" ]]; then
  curl -sSI --max-time 20 "http://${PROD_LB_IP}:8080/red" || true
fi

# ==================== TASK 6: rollback ====================

step "TASK 6 - Roll production back to v1.0"

# Rebuild production using the v1.0 image config.
sed -i 's/:v2\.0/:v1.0/g' cloudbuild.yaml
PROD_IMAGE="$(get_image cloudbuild.yaml)"
[[ -n "$PROD_IMAGE" ]] || fail "Cannot detect prod v1 image for rollback"
set_manifest_image prod/deployment.yaml "$PROD_IMAGE"

git add cloudbuild.yaml prod/deployment.yaml
if ! git diff --cached --quiet; then
  git commit -m "Rollback production to v1.0"
fi
git push "$AUTH_GIT_URL" master
gcloud builds submit --config=cloudbuild.yaml .
kubectl apply -n prod -f prod/deployment.yaml
kubectl rollout status deployment/production-deployment \
  -n prod --timeout=300s

step "Verify rollback: /red should return 404"
if [[ -n "$PROD_LB_IP" ]]; then
  curl -sSI --max-time 20 "http://${PROD_LB_IP}:8080/red" || true
fi

echo
echo "${GREEN}Script finished. Verify Tasks 4, 5 and 6 with Check my progress.${RESET}"
