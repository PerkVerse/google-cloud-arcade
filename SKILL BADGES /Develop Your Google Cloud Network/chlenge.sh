#!/bin/bash
# ==============================================================================
#  PERKVERSE  |  Cloud Automation Toolkit
#  Lab   : GSP321 - Develop your Google Cloud Network: Challenge Lab
#
#  STEP 1 (once per Cloud Shell session):   export ZONE=asia-south1-c
#  STEP 2                                  :   bash perkverse-gsp321-branded.sh
#
#  - Region is derived automatically from ZONE (asia-south1-c -> asia-south1)
#  - Every step auto-retries on error and is safe to re-run any number of times
#  - Raw gcloud noise is hidden; you only see clean status lines
# ==============================================================================

# ---------- brand settings (edit these freely) ----------
BRAND_NAME="PERKVERSE"
BRAND_TAGLINE="Automate smarter. Ship faster."
BRAND_FOOTER="Crafted with care by Perkverse"

# ---------- config ----------
if [ -z "$ZONE" ]; then
  echo -e "\n\033[1;31m [ERROR] \033[0m ZONE is not set. Run this first, then start the script again:\n"
  echo -e "      \033[1mexport ZONE=asia-south1-c\033[0m\n"
  exit 1
fi
REGION="${ZONE%-*}"
PROJECT=$(gcloud config get-value project 2>/dev/null)
[ -z "$PROJECT" ] && PROJECT=$GOOGLE_CLOUD_PROJECT
export GOOGLE_CLOUD_PROJECT=$PROJECT
export CLOUDSDK_CORE_DISABLE_PROMPTS=1

MAX=15          # attempts per step
SLEEP=8         # seconds between attempts
LOG=/tmp/perkverse.log
DB_ROOT_PW="RootPass#12345"
WP_USER="wp_user"
WP_PASS="stormwind_rules"

FAILED=()
LAST_ERR=""
SOFT=0
SPIN_LABEL=""
CUR_TASK=0
SEC_N=0
SEC_TOTAL=10
TASK_FAIL=()
TASK_SKIP=()
TASK_NOTE=()
START_TS=$SECONDS
W=64   # inner width of boxes

# ---------- palette ----------
C_RESET="\033[0m"; C_BOLD="\033[1m"; C_DIM="\033[2m"
C_BRAND="\033[1;38;5;99m"      # Perkverse violet
C_ACCENT="\033[1;38;5;45m"     # electric cyan
C_OK="\033[1;38;5;84m"         # mint green
C_WARN="\033[1;38;5;214m"      # amber
C_ERR="\033[1;38;5;203m"       # coral red
C_GREY="\033[38;5;245m"

# ---------- drawing helpers ----------
rep() { local s="" k; for ((k=0; k<$2; k++)); do s+="$1"; done; printf "%s" "$s"; }
box_top() { echo -e "${C_BRAND}╭$(rep ─ $W)╮${C_RESET}"; }
box_sep() { echo -e "${C_BRAND}├$(rep ─ $W)┤${C_RESET}"; }
box_bot() { echo -e "${C_BRAND}╰$(rep ─ $W)╯${C_RESET}"; }
# box_row "plain ascii text"
box_row() { printf "${C_BRAND}│${C_RESET} %-*s ${C_BRAND}│${C_RESET}\n" $((W-2)) "${1:0:$((W-2))}"; }
# box_sym "<color>" "<symbol>" "plain ascii text"
box_sym() { printf "${C_BRAND}│${C_RESET} %b%s${C_RESET} %-*s ${C_BRAND}│${C_RESET}\n" "$1" "$2" $((W-4)) "${3:0:$((W-4))}"; }

banner() {
  local LOGO=(
'  ____  _____ ____  _  __ __     _______ ____  ____  _____'
' |  _ \| ____|  _ \| |/ / \ \   / / ____|  _ \/ ___|| ____|'
' | |_) |  _| | |_) | '"'"' /   \ \ / /|  _| | |_) \___ \|  _|'
' |  __/| |___|  _ <| . \    \ V / | |___|  _ < ___) | |___'
' |_|   |_____|_| \_\_|\_\    \_/  |_____|_| \_\____/|_____|'
  )
  local COLORS=(129 99 63 39 45)
  echo
  local i
  for i in "${!LOGO[@]}"; do
    printf "\033[1;38;5;%sm%s\033[0m\n" "${COLORS[$i]}" "${LOGO[$i]}"
  done
  echo
  box_top
  box_row "  $BRAND_NAME  |  Cloud Automation Toolkit"
  box_row "  $BRAND_TAGLINE"
  box_sep
  box_row "  Lab      GSP321 - Develop your Google Cloud Network"
  box_row "  Project  $PROJECT"
  box_row "  Region   $REGION      Zone  $ZONE"
  box_row "  Started  $(date '+%d %b %Y, %H:%M')"
  box_bot
}

# section_header "LABEL"  -> rule + progress bar
section_header() {
  SEC_N=$((SEC_N+1))
  local txt=" $1 "
  local fill=$((W+2-${#txt}-3)); [ $fill -lt 3 ] && fill=3
  local pct=$((SEC_N*100/SEC_TOTAL)); [ $pct -gt 100 ] && pct=100
  local on=$((SEC_N*28/SEC_TOTAL));   [ $on -gt 28 ] && on=28
  echo
  echo -e "${C_BRAND}━━━${C_RESET}${C_BOLD}${txt}${C_RESET}${C_BRAND}$(rep ━ $fill)${C_RESET}"
  printf "  ${C_ACCENT}%s${C_GREY}%s${C_RESET}  ${C_BOLD}%s%%${C_RESET}\n" "$(rep ▰ $on)" "$(rep ▱ $((28-on)))" "$pct"
}
begin_task()  { CUR_TASK=$1; section_header "TASK $1  |  $2"; }
resume_task() { CUR_TASK=$1; section_header "TASK $1  |  $2 (continued)"; }
skip_task()   { TASK_SKIP[$1]=1; TASK_NOTE[$1]="$2"; }

info() { echo -e "  ${C_ACCENT}●${C_RESET} $*"; }
ok()   { echo -e "  ${C_OK}✔${C_RESET} $1 ${C_DIM}$2${C_RESET}"; }
warn() { echo -e "  ${C_WARN}▲${C_RESET} $*"; }
err()  { echo -e "  ${C_ERR}✘${C_RESET} $*"; }

# ---------- engine ----------
# quiet <cmd...> : run with a live spinner, keep raw output in the log
quiet() {
  local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏") f=0 t0=$SECONDS pid rc
  "$@" >"$LOG" 2>&1 &
  pid=$!
  if [ -t 1 ]; then
    while kill -0 $pid 2>/dev/null; do
      printf "\r  ${C_ACCENT}%s${C_RESET} %s ${C_DIM}(%ss)${C_RESET}\033[K" "${frames[f]}" "$SPIN_LABEL" $((SECONDS-t0))
      f=$(( (f+1) % 10 )); sleep 0.15
    done
    printf "\r\033[K"
  fi
  wait $pid; rc=$?
  LAST_ERR=$(grep -iE 'error|denied|invalid|failed|not found|quota|unable' "$LOG" | tail -1 | cut -c1-110)
  [ -z "$LAST_ERR" ] && LAST_ERR=$(tail -1 "$LOG" | cut -c1-110)
  return $rc
}

# step "<label>" "<check cmd or ->" <cmd...>
#   skips if already done, treats "already exists" as success, retries up to MAX times
step() {
  local label="$1" check="$2"; shift 2
  local i t0=$SECONDS
  SPIN_LABEL="$label"
  for ((i=1; i<=MAX; i++)); do
    if [ "$check" != "-" ] && eval "$check" >/dev/null 2>&1; then
      ok "$label" "(already done)"; return 0
    fi
    [ ! -t 1 ] && [ $i -eq 1 ] && info "$label"
    if quiet "$@"; then ok "$label" "($((SECONDS-t0))s)"; return 0; fi
    if grep -qi 'already exists' "$LOG"; then ok "$label" "(already done)"; return 0; fi
    warn "$label - attempt $i/$MAX failed: ${LAST_ERR}"
    sleep $SLEEP
  done
  err "$label - gave up after $MAX attempts"
  if [ "$SOFT" -eq 0 ]; then FAILED+=("$label"); TASK_FAIL[$CUR_TASK]=1; fi
  return 1
}

# wait_until "<label>" <iterations> <sleep> <predicate...>
wait_until() {
  local label="$1" n="$2" s="$3"; shift 3
  local i t0=$SECONDS
  for ((i=1; i<=n; i++)); do
    if "$@"; then [ -t 1 ] && printf "\r\033[K"; return 0; fi
    [ -t 1 ] && printf "\r  ${C_ACCENT}◔${C_RESET} %s ${C_DIM}(%ss)${C_RESET}\033[K" "$label" $((SECONDS-t0))
    sleep "$s"
  done
  [ -t 1 ] && printf "\r\033[K"
  return 1
}

banner

# optional env: USER2 can also be exported beforehand
if [ -z "$USER2" ]; then
  echo
  read -r -p "$(echo -e "  ${C_ACCENT}?${C_RESET} Email of the 2nd lab user (Username 2) for Task 9 ${C_DIM}[Enter to skip]${C_RESET}: ")" USER2
fi

############################ SETUP ###########################################
section_header "SETUP  |  Defaults and APIs"
step "Set default region and zone" - bash -c "gcloud config set compute/region $REGION && gcloud config set compute/zone $ZONE"
step "Enable required APIs" - gcloud services enable compute.googleapis.com container.googleapis.com \
  sqladmin.googleapis.com monitoring.googleapis.com iam.googleapis.com cloudresourcemanager.googleapis.com

############################ TASK 1 ##########################################
begin_task 1 "Development VPC"
step "VPC griffin-dev-vpc" "gcloud compute networks describe griffin-dev-vpc" \
  gcloud compute networks create griffin-dev-vpc --subnet-mode=custom
step "Subnet griffin-dev-wp  (192.168.16.0/20)" "gcloud compute networks subnets describe griffin-dev-wp --region=$REGION" \
  gcloud compute networks subnets create griffin-dev-wp --network=griffin-dev-vpc --region=$REGION --range=192.168.16.0/20
step "Subnet griffin-dev-mgmt  (192.168.32.0/20)" "gcloud compute networks subnets describe griffin-dev-mgmt --region=$REGION" \
  gcloud compute networks subnets create griffin-dev-mgmt --network=griffin-dev-vpc --region=$REGION --range=192.168.32.0/20

############################ TASK 2 ##########################################
begin_task 2 "Production VPC"
step "VPC griffin-prod-vpc" "gcloud compute networks describe griffin-prod-vpc" \
  gcloud compute networks create griffin-prod-vpc --subnet-mode=custom
step "Subnet griffin-prod-wp  (192.168.48.0/20)" "gcloud compute networks subnets describe griffin-prod-wp --region=$REGION" \
  gcloud compute networks subnets create griffin-prod-wp --network=griffin-prod-vpc --region=$REGION --range=192.168.48.0/20
step "Subnet griffin-prod-mgmt  (192.168.64.0/20)" "gcloud compute networks subnets describe griffin-prod-mgmt --region=$REGION" \
  gcloud compute networks subnets create griffin-prod-mgmt --network=griffin-prod-vpc --region=$REGION --range=192.168.64.0/20

############################ TASK 3 ##########################################
begin_task 3 "Bastion host"
step "Firewall griffin-dev-allow-ssh" "gcloud compute firewall-rules describe griffin-dev-allow-ssh" \
  gcloud compute firewall-rules create griffin-dev-allow-ssh --network=griffin-dev-vpc --allow=tcp:22,icmp --source-ranges=0.0.0.0/0
step "Firewall griffin-prod-allow-ssh" "gcloud compute firewall-rules describe griffin-prod-allow-ssh" \
  gcloud compute firewall-rules create griffin-prod-allow-ssh --network=griffin-prod-vpc --allow=tcp:22,icmp --source-ranges=0.0.0.0/0
step "Bastion griffin-dev-bastion  (2 network interfaces)" "gcloud compute instances describe griffin-dev-bastion --zone=$ZONE" \
  gcloud compute instances create griffin-dev-bastion --zone=$ZONE --machine-type=e2-medium \
    --network-interface=network=griffin-dev-vpc,subnet=griffin-dev-mgmt \
    --network-interface=network=griffin-prod-vpc,subnet=griffin-prod-mgmt

############################ TASK 4 (start early) ############################
begin_task 4 "Cloud SQL  (started early, builds in background)"
MYIP=$(curl -s -4 ifconfig.me || curl -s -4 icanhazip.com)

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
step "Cloud SQL instance griffin-dev-db" "gcloud sql instances describe griffin-dev-db" sql_create

############################ TASK 5 ##########################################
begin_task 5 "GKE cluster  (about 5-8 min)"
CLUSTER_OK=0
if step "Cluster griffin-dev  (2 x e2-standard-4)" "gcloud container clusters describe griffin-dev --zone=$ZONE" \
  gcloud container clusters create griffin-dev --zone=$ZONE --num-nodes=2 \
    --machine-type=e2-standard-4 --network=griffin-dev-vpc --subnetwork=griffin-dev-wp; then
  step "Cluster credentials" - gcloud container clusters get-credentials griffin-dev --zone=$ZONE && CLUSTER_OK=1
fi

############################ TASK 4 (finish) #################################
resume_task 4 "WordPress database"
sql_runnable() { [ "$(gcloud sql instances describe griffin-dev-db --format='value(state)' 2>/dev/null)" = "RUNNABLE" ]; }
CONN=""
if wait_until "Waiting for Cloud SQL to become RUNNABLE" 90 10 sql_runnable; then
  ok "Cloud SQL is RUNNABLE"
  SQL_IP=$(gcloud sql instances describe griffin-dev-db --format='value(ipAddresses[0].ipAddress)')
  CONN=$(gcloud sql instances describe griffin-dev-db --format='value(connectionName)')

  allow_my_ip() {
    local cur
    cur=$(gcloud sql instances describe griffin-dev-db --format='value(settings.ipConfiguration.authorizedNetworks[].value)' 2>/dev/null)
    echo "$cur" | grep -q "$MYIP" && return 0
    gcloud sql instances patch griffin-dev-db --authorized-networks="${MYIP}/32" --quiet
  }
  step "Allow Cloud Shell IP on Cloud SQL" - allow_my_ip

  cat > wp.sql <<EOF
CREATE DATABASE IF NOT EXISTS wordpress;
CREATE USER IF NOT EXISTS "wp_user"@"%" IDENTIFIED BY "stormwind_rules";
GRANT ALL PRIVILEGES ON wordpress.* TO "wp_user"@"%";
FLUSH PRIVILEGES;
EOF
  run_sql() { MYSQL_PWD="$DB_ROOT_PW" mysql --host="$SQL_IP" --user=root < wp.sql; }

  if ! SOFT=1 step "Run WordPress SQL  (database + wp_user)" - run_sql; then
    warn "mysql client route failed, using the gcloud API instead"
    step "Database wordpress" "gcloud sql databases describe wordpress --instance=griffin-dev-db" \
      gcloud sql databases create wordpress --instance=griffin-dev-db
    step "User wp_user" "gcloud sql users list --instance=griffin-dev-db --format='value(name)' | grep -qx $WP_USER" \
      gcloud sql users create $WP_USER --host=% --instance=griffin-dev-db --password=$WP_PASS
  fi
else
  err "Cloud SQL never became RUNNABLE"
  FAILED+=("Cloud SQL instance"); TASK_FAIL[4]=1
fi

############################ TASK 6 + 7 ######################################
LB_IP=""
if [ $CLUSTER_OK -eq 1 ] && [ -n "$CONN" ]; then
  begin_task 6 "Cluster secrets and volume"
  [ -f wp-k8s/wp-env.yaml ] || step "Download wp-k8s files" - gsutil cp -r gs://spls/gsp321/wp-k8s .
  cd wp-k8s || exit 1

  sed -i "s/username_goes_here/$WP_USER/g; s/password_goes_here/$WP_PASS/g" wp-env.yaml
  step "Apply secrets and volume  (wp-env.yaml)" - kubectl apply -f wp-env.yaml

  SA="cloud-sql-proxy@${PROJECT}.iam.gserviceaccount.com"
  step "Service account key  (key.json)" "[ -s key.json ]" \
    gcloud iam service-accounts keys create key.json --iam-account=$SA
  step "Secret cloudsql-instance-credentials" "kubectl get secret cloudsql-instance-credentials" \
    kubectl create secret generic cloudsql-instance-credentials --from-file key.json

  begin_task 7 "WordPress deployment"
  sed -i "s/YOUR_SQL_INSTANCE/$CONN/g" wp-deployment.yaml
  step "Apply deployment  (wp-deployment.yaml)" - kubectl apply -f wp-deployment.yaml
  step "Apply service  (wp-service.yaml)" - kubectl apply -f wp-service.yaml

  lb_ready() { LB_IP=$(kubectl get svc -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].status.loadBalancer.ingress[0].ip}' 2>/dev/null); [ -n "$LB_IP" ]; }
  if wait_until "Waiting for LoadBalancer external IP" 60 10 lb_ready; then
    ok "LoadBalancer IP: $LB_IP"
  else
    err "No LoadBalancer IP yet"; FAILED+=("LoadBalancer IP"); TASK_FAIL[7]=1
  fi
else
  CUR_TASK=6; section_header "TASK 6-7  |  Secrets and deployment"
  err "Skipped - cluster or Cloud SQL is not ready (re-run the script after fixing the issues above)"
  skip_task 6 "cluster not ready"; skip_task 7 "cluster not ready"
fi

############################ TASK 8 ##########################################
begin_task 8 "Uptime check"
if [ -n "$LB_IP" ]; then
  uptime_exists() {
    curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
      "https://monitoring.googleapis.com/v3/projects/$PROJECT/uptimeCheckConfigs" | grep -q "griffin-dev-wp-uptime"
  }
  uptime_gcloud() {
    gcloud monitoring uptime create griffin-dev-wp-uptime --resource-type=uptime-url \
      --resource-labels=host=$LB_IP,project_id=$PROJECT --protocol=http --port=80 --path=/ --period=1 --timeout=10
  }
  uptime_rest() {
    curl -s -X POST -H "Authorization: Bearer $(gcloud auth print-access-token)" -H "Content-Type: application/json" \
      "https://monitoring.googleapis.com/v3/projects/$PROJECT/uptimeCheckConfigs" \
      -d "{\"displayName\":\"griffin-dev-wp-uptime\",
           \"monitoredResource\":{\"type\":\"uptime_url\",\"labels\":{\"project_id\":\"$PROJECT\",\"host\":\"$LB_IP\"}},
           \"httpCheck\":{\"path\":\"/\",\"port\":80,\"requestMethod\":\"GET\"},
           \"period\":\"60s\",\"timeout\":\"10s\"}" | tee "$LOG" | grep -q '"name"'
  }
  uptime_create() { uptime_gcloud || uptime_rest; }
  step "Uptime check griffin-dev-wp-uptime" uptime_exists uptime_create
else
  err "Skipped - WordPress IP not available"
  skip_task 8 "no WordPress IP"
fi

############################ TASK 9 ##########################################
begin_task 9 "Additional engineer access"
if [ -n "$USER2" ]; then
  step "Editor role for $USER2" - gcloud projects add-iam-policy-binding $PROJECT --member="user:$USER2" --role="roles/editor"
else
  warn "No email given - skipped"
  echo -e "    ${C_DIM}Later run: gcloud projects add-iam-policy-binding $PROJECT --member=user:EMAIL --role=roles/editor${C_RESET}"
  skip_task 9 "no email"
fi

############################ SITE CHECK ######################################
if [ -n "$LB_IP" ]; then
  site_live() {
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" "http://$LB_IP")
    case "$code" in 200|301|302) return 0;; esac
    return 1
  }
  echo
  if wait_until "Waiting for the WordPress site to respond" 15 10 site_live; then
    ok "WordPress site is live" "(http://$LB_IP)"
  else
    warn "Site is not responding yet - it may need another minute"
  fi
fi

############################ SUMMARY #########################################
ELAPSED=$((SECONDS-START_TS))
TASK_NAMES=("" "Development VPC" "Production VPC" "Bastion host" "Cloud SQL + WordPress DB" \
            "GKE cluster" "Secrets and volume" "WordPress deployment" "Uptime check" "Engineer access")

echo; echo
box_top
box_row "  $BRAND_NAME  |  RUN SUMMARY"
box_sep
for n in 1 2 3 4 5 6 7 8 9; do
  if [ "${TASK_FAIL[$n]}" = "1" ]; then
    box_sym "$C_ERR" "✘" "Task $n  ${TASK_NAMES[$n]}  -  needs attention"
  elif [ "${TASK_SKIP[$n]}" = "1" ]; then
    box_sym "$C_WARN" "▲" "Task $n  ${TASK_NAMES[$n]}  -  skipped (${TASK_NOTE[$n]})"
  else
    box_sym "$C_OK" "✔" "Task $n  ${TASK_NAMES[$n]}"
  fi
done
box_sep
box_row "  Time taken     $((ELAPSED/60))m $((ELAPSED%60))s"
box_row "  WordPress URL  http://${LB_IP:-pending}"
if [ ${#FAILED[@]} -eq 0 ]; then
  box_sym "$C_OK" "✔" "All steps completed"
else
  box_sym "$C_ERR" "✘" "${#FAILED[@]} step(s) need attention - just run the script again"
fi
box_bot
echo -e "\n  ${C_ACCENT}Next:${C_RESET} open the Score panel and click ${C_BOLD}Check my progress${C_RESET} on every task."
echo -e "\n  ${C_BRAND}✦ ${BRAND_FOOTER}${C_RESET}  ${C_GREY}|  ${BRAND_TAGLINE}${C_RESET}\n"
[ ${#FAILED[@]} -eq 0 ]
