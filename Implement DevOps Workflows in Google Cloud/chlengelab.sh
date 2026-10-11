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
