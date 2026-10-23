#!/bin/bash
# ==============================================================================
#  PERKVERSE  |  Cloud Automation Toolkit
#  Lab      : GSP321 - Develop your Google Cloud Network: Challenge Lab
#  Usage    : bash perkverse-gsp321.sh   (run inside Google Cloud Shell)
#  Behavior : Every step retries up to 20 times (10 s apart). The script is
#             idempotent, so it is safe to re-run if it is interrupted.
# ==============================================================================

MAX=20
SLEEP=10
REGION="asia-south1"
ZONE="asia-south1-c"
PROJECT=$(gcloud config get-value project 2>/dev/null)
[ -z "$PROJECT" ] && PROJECT=$GOOGLE_CLOUD_PROJECT
export GOOGLE_CLOUD_PROJECT=$PROJECT

DB_ROOT_PW="RootPass#12345"
WP_USER="wp_user"
WP_PASS="stormwind_rules"

FAILED_STEPS=()
START_TS=$(date +%s)

# ---------- Perkverse branding ----------
C_RESET="\033[0m"; C_BOLD="\033[1m"
C_BRAND="\033[1;38;5;99m"    # Perkverse purple
C_ACCENT="\033[1;38;5;45m"   # accent cyan
C_OK="\033[1;32m"; C_WARN="\033[1;33m"; C_ERR="\033[1;31m"

banner() {
  echo -e "${C_BRAND}"
  cat <<'EOF'
  ____  _____ ____  _  __ __     _______ ____  ____  _____
 |  _ \| ____|  _ \| |/ / \ \   / / ____|  _ \/ ___|| ____|
 | |_) |  _| | |_) | ' /   \ \ / /|  _| | |_) \___ \|  _|
 |  __/| |___|  _ <| . \    \ V / | |___|  _ < ___) | |___
 |_|   |_____|_| \_\_|\_\    \_/  |_____|_| \_\____/|_____|
EOF
  echo -e "${C_RESET}${C_ACCENT}  Cloud Automation Toolkit  |  GSP321 Challenge Lab${C_RESET}"
  echo -e "  Project: ${C_BOLD}${PROJECT}${C_RESET}   Region: ${REGION}   Zone: ${ZONE}"
  echo -e "${C_BRAND}  ------------------------------------------------------------${C_RESET}"
}

log()  { echo -e "\n${C_BRAND}[Perkverse]${C_RESET} ${C_BOLD}$*${C_RESET}"; }
ok()   { echo -e "${C_OK}  [OK]${C_RESET} $*"; }
warn() { echo -e "${C_WARN}  [WARN]${C_RESET} $*"; }
err()  { echo -e "${C_ERR}  [ERROR]${C_RESET} $*"; }

# retry <cmd...> : run until it succeeds, up to MAX attempts
retry() {
  local i
  for ((i=1; i<=MAX; i++)); do
    "$@" && return 0
    warn "Attempt $i/$MAX failed. Retrying in ${SLEEP}s: $*"
    sleep $SLEEP
  done
  err "Gave up after $MAX attempts: $*"
  FAILED_STEPS+=("$*")
  return 1
}

# ensure "<check cmd>" <create cmd...> : skip if it already exists, otherwise create with retries
ensure() {
  local check="$1"; shift
  local i
  for ((i=1; i<=MAX; i++)); do
    if eval "$check" >/dev/null 2>&1; then
      ok "Already in place: ${check#gcloud }"
      return 0
    fi
    echo -e "  [try $i/$MAX] $*"
    "$@" && return 0
    warn "Failed. Retrying in ${SLEEP}s..."
    sleep $SLEEP
  done
  err "Gave up after $MAX attempts: $*"
  FAILED_STEPS+=("$*")
  return 1
}

banner
read -p "Enter the email of the 2nd lab user (Username 2) for Task 9, or press Enter to skip: " USER2

log "Configuring defaults and enabling APIs"
gcloud config set compute/region $REGION
gcloud config set compute/zone $ZONE
retry gcloud services enable compute.googleapis.com container.googleapis.com \
  sqladmin.googleapis.com monitoring.googleapis.com iam.googleapis.com \
  cloudresourcemanager.googleapis.com

############################ TASK 1: DEV VPC #################################
log "Task 1 - Development VPC (griffin-dev-vpc)"
ensure "gcloud compute networks describe griffin-dev-vpc" \
  gcloud compute networks create griffin-dev-vpc --subnet-mode=custom
ensure "gcloud compute networks subnets describe griffin-dev-wp --region=$REGION" \
  gcloud compute networks subnets create griffin-dev-wp --network=griffin-dev-vpc --region=$REGION --range=192.168.16.0/20
ensure "gcloud compute networks subnets describe griffin-dev-mgmt --region=$REGION" \
  gcloud compute networks subnets create griffin-dev-mgmt --network=griffin-dev-vpc --region=$REGION --range=192.168.32.0/20

############################ TASK 2: PROD VPC ################################
log "Task 2 - Production VPC (griffin-prod-vpc)"
ensure "gcloud compute networks describe griffin-prod-vpc" \
  gcloud compute networks create griffin-prod-vpc --subnet-mode=custom
ensure "gcloud compute networks subnets describe griffin-prod-wp --region=$REGION" \
  gcloud compute networks subnets create griffin-prod-wp --network=griffin-prod-vpc --region=$REGION --range=192.168.48.0/20
ensure "gcloud compute networks subnets describe griffin-prod-mgmt --region=$REGION" \
  gcloud compute networks subnets create griffin-prod-mgmt --network=griffin-prod-vpc --region=$REGION --range=192.168.64.0/20

############################ Firewall (SSH to bastion) #######################
log "Firewall rules for SSH access"
ensure "gcloud compute firewall-rules describe griffin-dev-allow-ssh" \
  gcloud compute firewall-rules create griffin-dev-allow-ssh --network=griffin-dev-vpc --allow=tcp:22,icmp --source-ranges=0.0.0.0/0
ensure "gcloud compute firewall-rules describe griffin-prod-allow-ssh" \
  gcloud compute firewall-rules create griffin-prod-allow-ssh --network=griffin-prod-vpc --allow=tcp:22,icmp --source-ranges=0.0.0.0/0

############################ TASK 4 (early start): Cloud SQL #################
# Cloud SQL takes several minutes, so it is started asynchronously first.
log "Task 4 - Starting Cloud SQL instance (async)"
MYIP=$(curl -s -4 ifconfig.me || curl -s -4 icanhazip.com)
echo "  Cloud Shell IP: $MYIP"

sql_create() {
  gcloud sql instances create griffin-dev-db \
    --database-version=MYSQL_8_0 --edition=ENTERPRISE --tier=db-n1-standard-1 \
    --region=$REGION --root-password="$DB_ROOT_PW" \
    --authorized-networks="${MYIP}/32" --async \
  || gcloud sql instances create griffin-dev-db \
    --database-version=MYSQL_8_0 --tier=db-n1-standard-1 \
    --region=$REGION --root-password="$DB_ROOT_PW" \
    --authorized-networks="${MYIP}/32" --async
}
ensure "gcloud sql instances describe griffin-dev-db" sql_create

############################ TASK 3: BASTION #################################
log "Task 3 - Bastion host with two network interfaces"
ensure "gcloud compute instances describe griffin-dev-bastion --zone=$ZONE" \
  gcloud compute instances create griffin-dev-bastion --zone=$ZONE --machine-type=e2-medium \
    --network-interface=network=griffin-dev-vpc,subnet=griffin-dev-mgmt \
    --network-interface=network=griffin-prod-vpc,subnet=griffin-prod-mgmt

############################ TASK 5: GKE CLUSTER #############################
log "Task 5 - GKE cluster griffin-dev (takes roughly 5-8 minutes)"
ensure "gcloud container clusters describe griffin-dev --zone=$ZONE" \
  gcloud container clusters create griffin-dev --zone=$ZONE --num-nodes=2 \
    --machine-type=e2-standard-4 --network=griffin-dev-vpc --subnetwork=griffin-dev-wp
retry gcloud container clusters get-credentials griffin-dev --zone=$ZONE

############################ TASK 4 (finish): SQL setup ######################
log "Task 4 - Waiting for Cloud SQL to become RUNNABLE"
for ((i=1; i<=60; i++)); do
  STATE=$(gcloud sql instances describe griffin-dev-db --format='value(state)' 2>/dev/null)
  echo "  SQL state: ${STATE:-unknown} ($i/60)"
  [ "$STATE" = "RUNNABLE" ] && break
  sleep 15
done

SQL_IP=$(gcloud sql instances describe griffin-dev-db --format='value(ipAddresses[0].ipAddress)')
CONN=$(gcloud sql instances describe griffin-dev-db --format='value(connectionName)')
echo "  SQL IP: $SQL_IP | Instance connection name: $CONN"

cat > wp.sql <<EOF
CREATE DATABASE IF NOT EXISTS wordpress;
CREATE USER IF NOT EXISTS "wp_user"@"%" IDENTIFIED BY "stormwind_rules";
GRANT ALL PRIVILEGES ON wordpress.* TO "wp_user"@"%";
FLUSH PRIVILEGES;
EOF

run_sql() { MYSQL_PWD="$DB_ROOT_PW" mysql --host="$SQL_IP" --user=root < wp.sql; }
if ! retry run_sql; then
  warn "mysql client failed - falling back to the gcloud API for the database and user"
  retry gcloud sql databases create wordpress --instance=griffin-dev-db
  retry gcloud sql users create $WP_USER --host=% --instance=griffin-dev-db --password=$WP_PASS
fi

############################ TASK 6: PREPARE K8S #############################
log "Task 6 - Secrets, volume and Cloud SQL proxy key"
rm -rf wp-k8s
retry gsutil cp -r gs://spls/gsp321/wp-k8s .
cd wp-k8s || exit 1

sed -i "s/username_goes_here/$WP_USER/g" wp-env.yaml
sed -i "s/password_goes_here/$WP_PASS/g" wp-env.yaml
retry kubectl apply -f wp-env.yaml

SA="cloud-sql-proxy@${PROJECT}.iam.gserviceaccount.com"
[ -f key.json ] || retry gcloud iam service-accounts keys create key.json --iam-account=$SA
ensure "kubectl get secret cloudsql-instance-credentials" \
  kubectl create secret generic cloudsql-instance-credentials --from-file key.json

############################ TASK 7: DEPLOYMENT ##############################
log "Task 7 - WordPress deployment and service"
sed -i "s/YOUR_SQL_INSTANCE/$CONN/g" wp-deployment.yaml
retry kubectl apply -f wp-deployment.yaml
retry kubectl apply -f wp-service.yaml

log "Waiting for the LoadBalancer external IP"
LB_IP=""
for ((i=1; i<=60; i++)); do
  LB_IP=$(kubectl get svc -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  [ -n "$LB_IP" ] && break
  echo "  Waiting for external IP... ($i/60)"
  sleep 10
done
echo "  WordPress IP: $LB_IP"
kubectl get pods

############################ TASK 8: UPTIME CHECK ############################
log "Task 8 - Uptime check for the WordPress site"
uptime_gcloud() {
  gcloud monitoring uptime create griffin-dev-wp-uptime \
    --resource-type=uptime-url \
    --resource-labels=host=$LB_IP,project_id=$PROJECT \
    --protocol=http --port=80 --path=/ --period=1 --timeout=10
}
uptime_rest() {
  curl -s -X POST \
    -H "Authorization: Bearer $(gcloud auth print-access-token)" \
    -H "Content-Type: application/json" \
    "https://monitoring.googleapis.com/v3/projects/$PROJECT/uptimeCheckConfigs" \
    -d "{\"displayName\":\"griffin-dev-wp-uptime\",
         \"monitoredResource\":{\"type\":\"uptime_url\",\"labels\":{\"project_id\":\"$PROJECT\",\"host\":\"$LB_IP\"}},
         \"httpCheck\":{\"path\":\"/\",\"port\":80,\"requestMethod\":\"GET\"},
         \"period\":\"60s\",\"timeout\":\"10s\"}" | grep -q '"name"'
}
if [ -n "$LB_IP" ]; then
  uptime_gcloud || retry uptime_rest
else
  warn "No LoadBalancer IP found. Create the uptime check manually in Monitoring > Uptime checks."
fi

############################ TASK 9: IAM #####################################
log "Task 9 - Grant the Editor role to the additional engineer"
if [ -n "$USER2" ]; then
  retry gcloud projects add-iam-policy-binding $PROJECT --member="user:$USER2" --role="roles/editor"
else
  warn "No email provided, skipping Task 9. Run later:"
  echo "  gcloud projects add-iam-policy-binding $PROJECT --member=user:EMAIL --role=roles/editor"
fi

############################ SUMMARY #########################################
ELAPSED=$(( $(date +%s) - START_TS ))
echo -e "\n${C_BRAND}============================================================${C_RESET}"
echo -e "${C_BRAND}  PERKVERSE${C_RESET} | Run summary"
echo -e "${C_BRAND}============================================================${C_RESET}"
echo "  Elapsed time : $((ELAPSED/60))m $((ELAPSED%60))s"
echo "  WordPress URL: http://${LB_IP:-<pending>}"
if [ ${#FAILED_STEPS[@]} -eq 0 ]; then
  echo -e "  Status       : ${C_OK}All steps completed${C_RESET}"
else
  echo -e "  Status       : ${C_ERR}${#FAILED_STEPS[@]} step(s) failed${C_RESET}"
  for s in "${FAILED_STEPS[@]}"; do echo "    - $s"; done
fi
echo "  Next         : open the Score panel and click 'Check my progress' on each task."
echo -e "${C_BRAND}  Powered by Perkverse${C_RESET}\n"
