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

echo "Checking Artifact Registry API..."
gcloud services enable artifactregistry.googleapis.com \
  --project="$PROJECT_ID" || {
    echo "ERROR: Artifact Registry API enable nahi hui."
    exit 1
  }

echo "Checking repository: $REPO"

if gcloud artifacts repositories describe "$REPO" \
  --location="$REGION" \
  --project="$PROJECT_ID" >/dev/null 2>&1; then

  echo "Repository already exists. Skipping creation."

else
  echo "Repository not found. Creating it..."

  gcloud artifacts repositories create "$REPO" \
    --repository-format=docker \
    --location="$REGION" \
    --description="GSP330 application repository" \
    --project="$PROJECT_ID" || {

      echo "Creation command failed. Checking whether repository now exists..."

      gcloud artifacts repositories describe "$REPO" \
        --location="$REGION" \
        --project="$PROJECT_ID" >/dev/null 2>&1 || {
          echo "ERROR: Repository create nahi hui."
          echo "Check the permission/API error shown above."
          exit 1
        }
    }
fi

echo "Verifying repository..."
gcloud artifacts repositories describe "$REPO" \
  --location="$REGION" \
  --project="$PROJECT_ID"

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

cat > /tmp/perkverse-gsp330.sh <<'SCRIPT'
#!/bin/bash
set -Eeuo pipefail

PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"
REGION="us-east1"
ZONE="us-east1-c"
CLUSTER="hello-cluster"
GIT_SERVER_IP="34.148.99.119"
REPO_URL="http://giteaadmin:GiteaPassword123@${GIT_SERVER_IP}:3000/giteaadmin/sample-app.git"

cd ~/sample-app || exit 1
git config user.name "PerkVerse"
git config user.email "perkverse@example.com"
git remote set-url origin "$REPO_URL"

fail() {
  echo
  echo "ERROR: $*"
  echo "Current branch: $(git branch --show-current)"
  echo "Git status:"
  git status --short || true
  exit 1
}

commit_push() {
  local branch="$1"
  local message="$2"
  shift 2
  git add "$@"
  if ! git diff --cached --quiet; then
    git commit -m "$message"
  fi
  git push origin "$branch" || fail "Git push failed on $branch"
}

build_retry() {
  local config="$1"
  local attempt
  for attempt in 1 2; do
    echo "Building with $config (attempt $attempt/2)"
    if gcloud builds submit --project="$PROJECT_ID" \
      --region="$REGION" --config="$config" .; then
      return 0
    fi
    echo "Build failed. Latest build log:"
    local id
    id="$(gcloud builds list --project="$PROJECT_ID" --region="$REGION" \
      --limit=1 --sort-by='~createTime' --format='value(id)' 2>/dev/null || true)"
    if [[ -n "$id" ]]; then
      gcloud builds log "$id" --project="$PROJECT_ID" --region="$REGION" 2>&1 | tail -70 || true
    fi
    [[ "$attempt" == 1 ]] && sleep 5
  done
  fail "Build failed twice using $config. Read the error above."
}

set_config() {
  local config="$1" image="$2" version="$3" manifest="$4"
  python3 - "$config" "$image" "$version" "$manifest" "$PROJECT_ID" "$REGION" "$ZONE" <<'PY'
import sys, re
config, image, version, manifest, project, region, zone = sys.argv[1:]
s = open(config).read()
s = re.sub(r'us-east1-docker\.pkg\.dev/[^/]+/my-repository/[^:]+:[^\'"]+',
           f'us-east1-docker.pkg.dev/$PROJECT_ID/my-repository/{image}:{version}', s)
s = s.replace('<version>', version).replace('<your-region>', region).replace('<your-zone>', zone)
s = s.replace('CLOUDSDK_COMPUTE_REGION=us-east1-c', 'CLOUDSDK_COMPUTE_ZONE=us-east1-c')
s = s.replace('CLOUDSDK_COMPUTE_REGION=us-east1', 'CLOUDSDK_COMPUTE_ZONE=us-east1-c')
open(config, 'w').write(s)

p = open(manifest).read()
p = re.sub(r'image:\s*.*', f'image: us-east1-docker.pkg.dev/{project}/my-repository/{image}:{version}', p, count=1)
open(manifest, 'w').write(p)
PY
}

echo "========== CHECK CLUSTER =========="
gcloud container clusters get-credentials "$CLUSTER" --zone="$ZONE" --project="$PROJECT_ID" \
  || fail "Cannot access cluster $CLUSTER in $ZONE"

echo "========== TASK 4: DEV v1.0 =========="
git checkout dev || fail "Cannot switch to dev branch"
set_config cloudbuild-dev.yaml hello-cloudbuild-dev v1.0 dev/deployment.yaml
commit_push dev "Fix dev v1.0 image configuration" cloudbuild-dev.yaml dev/deployment.yaml
build_retry cloudbuild-dev.yaml

echo "========== TASK 4: PRODUCTION v1.0 =========="
git checkout master || fail "Cannot switch to master branch"
set_config cloudbuild.yaml hello-cloudbuild v1.0 prod/deployment.yaml
commit_push master "Deploy production v1.0" cloudbuild.yaml prod/deployment.yaml
build_retry cloudbuild.yaml

echo "========== CREATE LOAD BALANCER SERVICES =========="
kubectl get namespace dev >/dev/null 2>&1 || kubectl create namespace dev
kubectl get namespace prod >/dev/null 2>&1 || kubectl create namespace prod

cat > /tmp/dev-service.yaml <<'YAML'
apiVersion: v1
kind: Service
metadata:
  name: dev-deployment-service
  namespace: dev
spec:
  type: LoadBalancer
  selector:
    app: dev-app
  ports:
  - port: 8080
    targetPort: 8080
YAML

cat > /tmp/prod-service.yaml <<'YAML'
apiVersion: v1
kind: Service
metadata:
  name: prod-deployment-service
  namespace: prod
spec:
  type: LoadBalancer
  selector:
    app: production-app
  ports:
  - port: 8080
    targetPort: 8080
YAML

kubectl apply -f /tmp/dev-service.yaml || fail "Could not create dev service"
kubectl apply -f /tmp/prod-service.yaml || fail "Could not create production service"

echo "========== CHECK BLUE ENDPOINTS =========="
kubectl rollout status deployment/development-deployment -n dev --timeout=180s \
  || fail "Dev deployment did not become ready"
kubectl rollout status deployment/production-deployment -n prod --timeout=180s \
  || fail "Production deployment did not become ready"

echo "========== TASK 5: ADD RED HANDLER ON DEV =========="
git checkout dev || fail "Cannot switch to dev"
python3 - <<'PY'
p = "main.go"
s = open(p).read()
if 'http.HandleFunc("/red", redHandler)' not in s:
    needle = 'http.HandleFunc("/blue", blueHandler)'
    if needle not in s:
        raise SystemExit('Cannot find blue route in main.go; stopping safely.')
    s = s.replace(needle, needle + '\n\thttp.HandleFunc("/red", redHandler)', 1)
if 'func redHandler(' not in s:
    s += '''

func redHandler(w http.ResponseWriter, r *http.Request) {
    img := image.NewRGBA(image.Rect(0, 0, 100, 100))
    draw.Draw(img, img.Bounds(), &image.Uniform{color.RGBA{255, 0, 0, 255}}, image.ZP, draw.Src)
    w.Header().Set("Content-Type", "image/png")
    png.Encode(w, img)
}
'''
open(p, 'w').write(s)
PY
gofmt -w main.go
set_config cloudbuild-dev.yaml hello-cloudbuild-dev v2.0 dev/deployment.yaml
commit_push dev "Deploy dev v2.0 with red endpoint" main.go cloudbuild-dev.yaml dev/deployment.yaml
build_retry cloudbuild-dev.yaml

echo "========== TASK 5: ADD RED HANDLER ON PRODUCTION =========="
git checkout master || fail "Cannot switch to master"
python3 - <<'PY'
p = "main.go"
s = open(p).read()
if 'http.HandleFunc("/red", redHandler)' not in s:
    needle = 'http.HandleFunc("/blue", blueHandler)'
    if needle not in s:
        raise SystemExit('Cannot find blue route in main.go; stopping safely.')
    s = s.replace(needle, needle + '\n\thttp.HandleFunc("/red", redHandler)', 1)
if 'func redHandler(' not in s:
    s += '''

func redHandler(w http.ResponseWriter, r *http.Request) {
    img := image.NewRGBA(image.Rect(0, 0, 100, 100))
    draw.Draw(img, img.Bounds(), &image.Uniform{color.RGBA{255, 0, 0, 255}}, image.ZP, draw.Src)
    w.Header().Set("Content-Type", "image/png")
    png.Encode(w, img)
}
'''
open(p, 'w').write(s)
PY
gofmt -w main.go
set_config cloudbuild.yaml hello-cloudbuild v2.0 prod/deployment.yaml
commit_push master "Deploy production v2.0 with red endpoint" main.go cloudbuild.yaml prod/deployment.yaml
build_retry cloudbuild.yaml

echo "========== TASK 6: ROLLBACK PRODUCTION TO v1.0 =========="
git checkout master || fail "Cannot switch to master for rollback"
set_config cloudbuild.yaml hello-cloudbuild v2.0 prod/deployment.yaml
# Task 6 requires the already-built v1.0 image. Do not rebuild it from v2.0 source.
sed -i "s|image: .*|image: us-east1-docker.pkg.dev/${PROJECT_ID}/my-repository/hello-cloudbuild:v1.0|" prod/deployment.yaml
commit_push master "Rollback production deployment to v1.0" prod/deployment.yaml
kubectl apply -n prod -f prod/deployment.yaml || fail "Could not apply production rollback"
kubectl rollout status deployment/production-deployment -n prod --timeout=180s \
  || fail "Production rollback did not become ready"

echo "========== FINAL DEPLOYMENT STATUS =========="
kubectl get deployments,services -n dev
kubectl get deployments,services -n prod
echo
echo "Script finished. Check endpoint status after the load balancers receive external IPs:"
kubectl get services dev-deployment-service -n dev
kubectl get services prod-deployment-service -n prod
echo
echo "Production should now use the v1.0 image, so /red should return 404."
SCRIPT

bash /tmp/perkverse-gsp330.sh
