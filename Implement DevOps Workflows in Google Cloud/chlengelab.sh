#!/bin/bash
set -Eeuo pipefail
# ==========================================================
# GSP330 - Implement DevOps Workflows in Google Cloud (Challenge Lab)
# ONE script: Tasks 1-6.  Run in Cloud Shell:  bash gsp330-complete.sh
# ==========================================================
G=$(tput setaf 2 2>/dev/null || true); R=$(tput setaf 1 2>/dev/null || true)
Y=$(tput setaf 3 2>/dev/null || true); N=$(tput sgr0 2>/dev/null || true)
step(){ echo; echo "${Y}=== $* ===${N}"; }
fail(){ echo "${R}ERROR: $*${N}" >&2; exit 1; }
trap 'echo "${R}Failed at line $LINENO - upar ka error bhejo.${N}" >&2' ERR

export PROJECT_ID; PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"
[[ -n "$PROJECT_ID" ]] || fail "No project set."
export PROJECT_NUMBER; PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"

# Lab values (auto-detect from git-server, default to lab's us-west1-b)
export ZONE; ZONE="$(gcloud compute instances list --filter='name=git-server' --format='value(zone.basename())' 2>/dev/null | head -n1 || true)"
ZONE="${ZONE:-us-west1-b}"
export REGION="${ZONE%-*}"
export CLUSTER=hello-cluster REPO=my-repository
gcloud config set compute/region "$REGION" >/dev/null 2>&1
gcloud config set compute/zone "$ZONE" >/dev/null 2>&1
export GIT_SERVER_IP; GIT_SERVER_IP="$(gcloud compute instances describe git-server --zone="$ZONE" --format='get(networkInterfaces[0].accessConfigs[0].natIP)')"
[[ -n "$GIT_SERVER_IP" ]] || fail "git-server IP not found."
AUTH="http://giteaadmin:GiteaPassword123@${GIT_SERVER_IP}:3000/giteaadmin/sample-app.git"
echo "Project=$PROJECT_ID Region=$REGION Zone=$ZONE GitIP=$GIT_SERVER_IP"

# ---------------- TASK 1 ----------------
step "Task 1: APIs, IAM, git config, Artifact Registry, GKE, namespaces"
gcloud services enable container.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com" \
  --role="roles/container.developer" --quiet >/dev/null
git config --global user.name "Student"
git config --global user.email "student@qwiklabs.net"

gcloud artifacts repositories describe "$REPO" --location="$REGION" >/dev/null 2>&1 || \
  gcloud artifacts repositories create "$REPO" --repository-format=docker --location="$REGION" --description="Docker repository"

gcloud container clusters describe "$CLUSTER" --zone="$ZONE" >/dev/null 2>&1 || \
  gcloud container clusters create "$CLUSTER" --zone="$ZONE" --release-channel=regular \
    --num-nodes=3 --enable-autoscaling --min-nodes=2 --max-nodes=6
gcloud container clusters get-credentials "$CLUSTER" --zone="$ZONE"
kubectl get ns prod >/dev/null 2>&1 || kubectl create namespace prod
kubectl get ns dev  >/dev/null 2>&1 || kubectl create namespace dev

# ---------------- TASK 2 ----------------
step "Task 2: sample-app + Git (master, dev)"
cd ~
rm -rf ~/sample-app; mkdir -p ~/sample-app
gcloud storage cp -r "gs://spls/gsp330/sample-app/*" ~/sample-app/
for f in ~/sample-app/cloudbuild-dev.yaml ~/sample-app/cloudbuild.yaml; do
  sed -i "s/<your-region>/${REGION}/g; s/<your-zone>/${ZONE}/g; s/<version>/v1.0/g" "$f"
  # zonal cluster: make sure the zone variable is not stored under the REGION name
  sed -i "s/CLOUDSDK_COMPUTE_REGION=${ZONE}/CLOUDSDK_COMPUTE_ZONE=${ZONE}/g" "$f"
done
cd ~/sample-app
git init -q
git remote remove origin 2>/dev/null || true
git remote add origin "http://${GIT_SERVER_IP}:3000/giteaadmin/sample-app.git"
git branch -m master
git add . && git commit -qm "initial commit"
git push -f -u "$AUTH" master
git checkout -b dev
git push -f -u "$AUTH" dev

# ---------------- TASK 3 ----------------
step "Task 3: Cloud Build triggers"
SA="projects/${PROJECT_ID}/serviceAccounts/${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
gcloud builds triggers describe sample-app-prod-deploy --region="$REGION" >/dev/null 2>&1 || \
  gcloud builds triggers create manual --name="sample-app-prod-deploy" --inline-config="cloudbuild.yaml" \
    --service-account="$SA" --region="$REGION"
gcloud builds triggers describe sample-app-dev-deploy --region="$REGION" >/dev/null 2>&1 || \
  gcloud builds triggers create manual --name="sample-app-dev-deploy" --inline-config="cloudbuild-dev.yaml" \
    --service-account="$SA" --region="$REGION"

# ---------------- helpers ----------------
PORT="$(grep -iE '^\s*EXPOSE' Dockerfile 2>/dev/null | head -n1 | awk '{print $2}' | tr -d '/tcp')"; PORT="${PORT:-8080}"

img_from_cfg(){ # extract image reference from cloudbuild file, substitute project id
  grep -oE '[A-Za-z0-9.<>_-]*docker\.pkg\.dev/[^ "'"'"',]+' "$1" | head -n1 \
    | sed "s/\${PROJECT_ID}/${PROJECT_ID}/g; s/\$PROJECT_ID/${PROJECT_ID}/g"
}
set_manifest_image(){ # manifest image
  if grep -q '<todo>' "$1"; then sed -i "s|<todo>|$2|" "$1"
  else sed -i -E "0,/^(\s*-?\s*image:\s*).*/s||\1$2|" "$1"; fi
}
build(){ # config
  gcloud builds submit --config="$1" . && return 0
  echo "${Y}Build failed - granting build permissions and retrying with --region${N}"
  for r in roles/artifactregistry.writer roles/container.developer roles/logging.logWriter roles/storage.objectViewer; do
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
      --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" --role="$r" --quiet >/dev/null 2>&1 || true
  done
  sleep 15
  gcloud builds submit --config="$1" --region="$REGION" . || fail "Build failed: $1"
}
dep_name(){ kubectl get deploy -n "$1" -o jsonpath='{.items[0].metadata.name}'; }
expose_lb(){ # ns svcname
  kubectl get svc "$2" -n "$1" >/dev/null 2>&1 || \
    kubectl expose deployment "$(dep_name "$1")" -n "$1" --name="$2" --type=LoadBalancer --port=8080 --target-port="$PORT"
}
lb_ip(){ local ip=""; for _ in $(seq 1 45); do
    ip="$(kubectl get svc "$2" -n "$1" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    [[ -n "$ip" ]] && break; sleep 8; done; echo "$ip"; }
code(){ # ns svc path -> waits until expected code or timeout
  local ip; ip="$(lb_ip "$1" "$2")"; local c=""
  for _ in $(seq 1 24); do
    c="$(curl -s -o /dev/null -m 8 -w '%{http_code}' "http://${ip}:8080$3" || true)"
    [[ "$c" == "$4" ]] && break; sleep 10; done
  echo "$1 $3 -> HTTP $c (expected $4)"
}
python_edit_main(){ cat > /tmp/editmain.py <<'PY'
import re
s=open('main.go').read()
newmain='''func main() {
	http.HandleFunc("/blue", blueHandler)
	http.HandleFunc("/red", redHandler)
	http.ListenAndServe(":8080", nil)
}'''
s=re.sub(r'func main\(\)\s*\{.*?\n\}', newmain, s, count=1, flags=re.S)
if 'func redHandler' not in s:
    s=s.rstrip('\n')+'''

func redHandler(w http.ResponseWriter, r *http.Request) {
	img := image.NewRGBA(image.Rect(0, 0, 100, 100))
	draw.Draw(img, img.Bounds(), &image.Uniform{color.RGBA{255, 0, 0, 255}}, image.ZP, draw.Src)
	w.Header().Set("Content-Type", "image/png")
	png.Encode(w, img)
}
'''
open('main.go','w').write(s)
PY
python3 /tmp/editmain.py; }

# ---------------- TASK 4 ----------------
step "Task 4: v1.0 dev"
cd ~/sample-app
git checkout dev
DEV_IMG="$(img_from_cfg cloudbuild-dev.yaml)"; echo "dev image: $DEV_IMG"
set_manifest_image dev/deployment.yaml "$DEV_IMG"
git add . && git commit -qm "Deploy v1.0 on dev" || true
git push "$AUTH" dev
build cloudbuild-dev.yaml
expose_lb dev dev-deployment-service
code dev dev-deployment-service /blue 200

step "Task 4: v1.0 prod"
git checkout master
PROD_IMG="$(img_from_cfg cloudbuild.yaml)"; echo "prod image: $PROD_IMG"
set_manifest_image prod/deployment.yaml "$PROD_IMG"
git add . && git commit -qm "Deploy v1.0 on master" || true
git push "$AUTH" master
V1_COMMIT="$(git rev-parse HEAD)"
build cloudbuild.yaml
expose_lb prod prod-deployment-service
code prod prod-deployment-service /blue 200

# ---------------- TASK 5 ----------------
step "Task 5: v2.0 dev"
git checkout dev
python_edit_main
sed -i 's/v1\.0/v2.0/g' cloudbuild-dev.yaml dev/deployment.yaml
git add . && git commit -qm "Deploy v2.0 on dev" || true
git push "$AUTH" dev
build cloudbuild-dev.yaml
kubectl rollout status deployment -n dev --timeout=240s || true
code dev dev-deployment-service /red 200

step "Task 5: v2.0 prod"
git checkout master
python_edit_main
sed -i 's/v1\.0/v2.0/g' cloudbuild.yaml prod/deployment.yaml
git add . && git commit -qm "Deploy v2.0 on master" || true
git push "$AUTH" master
build cloudbuild.yaml
kubectl rollout status deployment -n prod --timeout=240s || true
code prod prod-deployment-service /red 200

# ---------------- TASK 6 ----------------
step "Task 6: Roll back prod to v1.0"
rm -rf /tmp/rollback; git worktree prune
git worktree add -f /tmp/rollback "$V1_COMMIT" >/dev/null 2>&1
( cd /tmp/rollback && build cloudbuild.yaml )
kubectl rollout status deployment -n prod --timeout=240s || true
CUR="$(kubectl get deploy "$(dep_name prod)" -n prod -o jsonpath='{.spec.template.spec.containers[0].image}')"
if [[ "$CUR" != *":v1.0" ]]; then
  echo "Forcing image to v1.0"
  kubectl set image "deployment/$(dep_name prod)" "*=${PROD_IMG}" -n prod
  kubectl rollout status deployment -n prod --timeout=240s || true
fi
echo "Prod image now: $(kubectl get deploy "$(dep_name prod)" -n prod -o jsonpath='{.spec.template.spec.containers[0].image}')"
code prod prod-deployment-service /red 404
code dev dev-deployment-service /red 200

echo; echo "${G}DONE - Skills Boost mein sab tasks par 'Check my progress' click karo.${N}"
