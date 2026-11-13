main() {
# ============================================================
#  GSP318 - Deploy Kubernetes Applications on Google Cloud
#  Challenge Lab - Fully Automated Solution (v4 - live output)
# ============================================================

G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
step() { echo -e "\n${C}${B}==> $1${N}"; }
ok()   { echo -e "${G}  [OK] $1${N}"; }
warn() { echo -e "${Y}  [..] $1${N}"; }
fail() { echo -e "${R}  [!!] $1${N}"; }

# Retry helper with LIVE output (nothing is hidden)
run() {
  local desc="$1"; shift
  for i in 1 2 3; do
    if eval "$@"; then ok "$desc"; return 0; fi
    warn "$desc failed (attempt $i/3). Retrying in 5s..."
    gcloud auth configure-docker us-central1-docker.pkg.dev --quiet >/dev/null 2>&1
    sleep 5
  done
  fail "$desc could not be completed."; return 1
}

ask() {
  local label="$1" default="$2" regex="$3" hint="$4" val
  while true; do
    read -r -p "$(echo -e "  ${B}${label}${N} [default: ${default}]: ")" val
    val="${val:-$default}"
    if [[ "$val" =~ $regex ]]; then ANSWER="$val"; return 0; fi
    fail "Invalid value. $hint"
  done
}

clear
echo -e "${B}${C}  ====== GSP318 : Kubernetes Challenge Lab - Auto Solver ======${N}"

# ---------- User input section ----------
while true; do
  step "Enter your configuration (press Enter to use the default)"
  ask "Repository name" "valkyrie-repo" '^[a-z][a-z0-9-]*$' "Lowercase letters, numbers, hyphens only."
  REPO="$ANSWER"
  ask "Docker image name" "valkyrie-app" '^[a-z0-9][a-z0-9._-]*$' "Lowercase letters, numbers, . - _ only."
  IMAGE="$ANSWER"
  ask "Image tag" "v0.0.1" '^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$' "Letters, numbers, . - _ only."
  TAG="$ANSWER"
  echo
  echo -e "  Repository : ${B}$REPO${N}"
  echo -e "  Image      : ${B}$IMAGE${N}"
  echo -e "  Tag        : ${B}$TAG${N}"
  read -r -p "$(echo -e "  ${B}Continue with these values? [Y/n]: ${N}")" CONFIRM
  case "${CONFIRM:-Y}" in [Yy]*) break ;; *) warn "Enter the values again." ;; esac
done

# ---------- Auto-detect environment ----------
step "Detecting project, zone and region"
export PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
export ZONE=$(timeout 60 gcloud container clusters list --filter="name=valkyrie-dev" --format="value(location)" 2>/dev/null | head -n1)
[ -z "$ZONE" ] && export ZONE="us-central1-c"
export REGION="${ZONE%-*}"
export REPO_REGION="us-central1"
export FULL_IMAGE="${REPO_REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO}/${IMAGE}:${TAG}"
gcloud config set compute/zone "$ZONE" --quiet >/dev/null 2>&1
gcloud config set compute/region "$REGION" --quiet >/dev/null 2>&1
echo -e "  Project ID : ${B}$PROJECT_ID${N}"
echo -e "  Zone       : ${B}$ZONE${N}"
echo -e "  Region     : ${B}$REGION${N}"
echo -e "  Image      : ${B}$FULL_IMAGE${N}"

# ---------- Task 1 ----------
step "TASK 1: Create Docker image and store Dockerfile"
cd ~ || return 1

warn "Checking Docker daemon..."
for i in $(seq 1 12); do docker info >/dev/null 2>&1 && break; echo "  waiting for Docker... ($i/12)"; sleep 5; done
docker info >/dev/null 2>&1 && ok "Docker is ready" || { fail "Docker is not responding. Restart Cloud Shell and run again."; return 1; }

rm -rf ~/valkyrie-app ~/valkyrie-app.tgz
run "Source code downloaded" "timeout 120 gcloud storage cp gs://spls/gsp318/valkyrie-app.tgz ."
tar -xzf valkyrie-app.tgz && ok "Source extracted"
cd ~/valkyrie-app || return 1

cat > Dockerfile <<'EOF'
FROM golang:1.10
WORKDIR /go/src/app
COPY source .
RUN go install -v
ENTRYPOINT ["app","-single=true","-port=8080"]
EOF
ok "Dockerfile created"

warn "Building image (first build downloads golang:1.10, wait 1-3 min, progress is shown below)"
run "Docker image built ($IMAGE:$TAG)" "docker build -t $IMAGE:$TAG ."
docker images | grep -E "REPOSITORY|$IMAGE"

# ---------- Task 2 ----------
step "TASK 2: Test the Docker image"
docker rm -f valkyrie-test >/dev/null 2>&1
OLD=$(docker ps -q --filter "publish=8080"); [ -n "$OLD" ] && docker rm -f $OLD >/dev/null 2>&1
run "Container running on port 8080" "docker run -d --name valkyrie-test -p 8080:8080 $IMAGE:$TAG"
sleep 5
CODE=$(curl -s -m 10 -o /dev/null -w "%{http_code}" http://localhost:8080)
[ "$CODE" = "200" ] && ok "App responded with HTTP 200" || warn "HTTP $CODE (container is still running)"

# ---------- Task 3 ----------
step "TASK 3: Push image to Artifact Registry"
if gcloud artifacts repositories describe $REPO --location=$REPO_REGION >/dev/null 2>&1; then
  ok "Repository $REPO already exists"
else
  run "Repository $REPO created" "gcloud artifacts repositories create $REPO --repository-format=docker --location=$REPO_REGION --description='Docker repo' --quiet"
fi
gcloud auth configure-docker ${REPO_REGION}-docker.pkg.dev --quiet >/dev/null 2>&1
ok "Docker authentication configured"
run "Image tagged" "docker tag $IMAGE:$TAG $FULL_IMAGE"
run "Image pushed to Artifact Registry" "docker push $FULL_IMAGE"

# ---------- Task 4 ----------
step "TASK 4: Create and expose deployment in Kubernetes"
run "Cluster credentials fetched" "gcloud container clusters get-credentials valkyrie-dev --zone $ZONE"

cd ~/valkyrie-app/k8s || return 1
sed -i "s|image:.*|image: ${FULL_IMAGE}|g" deployment.yaml
ok "Placeholder replaced in deployment.yaml"
grep "image:" deployment.yaml

run "deployment.yaml applied" "kubectl apply -f deployment.yaml"
run "service.yaml applied"    "kubectl apply -f service.yaml"

step "Waiting for pods and load balancer IP"
kubectl rollout status deployment --timeout=180s
for i in $(seq 1 30); do
  EXT_IP=$(kubectl get svc valkyrie-dev -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  [ -n "$EXT_IP" ] && break
  echo -e "  waiting for external IP... ($i/30)"; sleep 10
done

echo; kubectl get pods; kubectl get svc valkyrie-dev
echo -e "\n${G}${B}================ ALL TASKS COMPLETED ================${N}"
[ -n "$EXT_IP" ] && echo -e "  App URL : ${B}http://$EXT_IP${N}"
echo -e "  Now click ${B}'Check my progress'${N} for each task."
}
main
