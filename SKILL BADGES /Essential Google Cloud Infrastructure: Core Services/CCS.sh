#!/usr/bin/env bash
# ============================================================================
#  Configure Cloud SQL  |  Lab CBL037  |  Full Automation Script (Cloud Shell)
#
#  Features
#    - Project ID is detected automatically
#    - Region / Zone prompt (auto-detected default, just press Enter)
#    - Every step retries up to 20 times with built-in self-healing fixes
# ============================================================================
set -uo pipefail

# ------------------------------- Styling -----------------------------------
RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; BLU=$'\e[34m'; CYN=$'\e[36m'
BLD=$'\e[1m';  DIM=$'\e[2m';  RST=$'\e[0m'

rule()   { printf "${DIM}%s${RST}\n" "──────────────────────────────────────────────────────────────"; }
header() { echo; rule; printf "  ${BLD}${BLU}%s${RST}\n" "$*"; rule; }
info()   { printf "  ${CYN}ℹ${RST}  %s\n" "$*"; }
ok()     { printf "  ${GRN}✔${RST}  %s\n" "$*"; }
warn()   { printf "  ${YEL}⚠${RST}  %s\n" "$*"; }
err()    { printf "  ${RED}✘${RST}  %s\n" "$*"; }
kv()     { printf "  ${BLD}%-22s${RST} %s\n" "$1" "$2"; }

MAX_TRY=20
CUR_TRY=1

# retry "<description>" <command...>  ->  runs the command up to MAX_TRY times
retry() {
  local desc="$1"; shift
  local i=1 wait
  while (( i <= MAX_TRY )); do
    CUR_TRY=$i
    info "${desc}  ${DIM}(attempt ${i}/${MAX_TRY})${RST}"
    if "$@"; then ok "${desc}"; return 0; fi
    wait=$(( i * 5 )); (( wait > 30 )) && wait=30
    warn "Attempt ${i} failed. Retrying in ${wait}s..."
    sleep "$wait"
    ((i++))
  done
  err "${desc} failed after ${MAX_TRY} attempts"
  return 1
}

# ------------------------------- Banner ------------------------------------
clear
printf "${BLD}${CYN}"
cat <<'BANNER'

   ╔══════════════════════════════════════════════════════════╗
   ║                                                          ║
   ║            CONFIGURE CLOUD SQL  -  LAB CBL037            ║
   ║               Full Automation  |  Cloud Shell            ║
   ║                                                          ║
   ╚══════════════════════════════════════════════════════════╝

BANNER
printf "${RST}"

# ------------------------- Step 1: Project ID ------------------------------
header "STEP 1 of 7  ·  Detecting Project ID"
PROJECT_ID="$(gcloud config get-value project 2>/dev/null | tr -d '[:space:]')"
[[ -z "$PROJECT_ID" || "$PROJECT_ID" == "(unset)" ]] && PROJECT_ID="${GOOGLE_CLOUD_PROJECT:-${DEVSHELL_PROJECT_ID:-}}"
[[ -z "$PROJECT_ID" ]] && PROJECT_ID="$(gcloud projects list --format='value(projectId)' 2>/dev/null | head -n1)"
if [[ -z "$PROJECT_ID" ]]; then
  err "Could not detect the Project ID. Run: gcloud config set project <PROJECT_ID>"
  exit 1
fi
gcloud config set project "$PROJECT_ID" >/dev/null 2>&1
ok "Project ID detected: ${BLD}${PROJECT_ID}${RST}"

# ------------------------ Step 2: Region & Zone ----------------------------
header "STEP 2 of 7  ·  Region, Zone & Password"
DEF_ZONE="$(gcloud compute instances list --filter='name=wordpress-proxy' --format='value(zone.basename())' 2>/dev/null | head -n1)"
DEF_ZONE="${DEF_ZONE:-us-central1-a}"
DEF_REGION="${DEF_ZONE%-*}"
info "Detected from the lab VMs: region ${BLD}${DEF_REGION}${RST}, zone ${BLD}${DEF_ZONE}${RST}"
info "Enter the Lab Region / Lab Zone from the lab panel, or press Enter to accept the default."
echo
read -rp "  ▸ Region [${DEF_REGION}]: " REGION
REGION="${REGION:-$DEF_REGION}"
read -rp "  ▸ Zone   [${DEF_ZONE}]: " ZONE
ZONE="${ZONE:-$DEF_ZONE}"
if [[ "$ZONE" != "$REGION"-* ]]; then
  warn "Zone '${ZONE}' does not belong to region '${REGION}'. Adjusting region to match the zone."
  REGION="${ZONE%-*}"
fi
read -rp "  ▸ Cloud SQL root password (letters/numbers only) [LabPass12345]: " ROOT_PASSWORD
ROOT_PASSWORD="${ROOT_PASSWORD:-LabPass12345}"
if [[ ! "$ROOT_PASSWORD" =~ ^[A-Za-z0-9]+$ ]]; then
  warn "Password contains special characters. Falling back to the default: LabPass12345"
  ROOT_PASSWORD="LabPass12345"
fi
WP_ADMIN_PASS="Admin${ROOT_PASSWORD}"

gcloud config set compute/region "$REGION" >/dev/null 2>&1
gcloud config set compute/zone   "$ZONE"   >/dev/null 2>&1

DB_INSTANCE="wordpress-db"
PROXY_VM="wordpress-proxy"
PRIVATE_VM="wordpress-private-ip"
PSA_RANGE="google-managed-services-default"

echo
rule
kv "Project"  "$PROJECT_ID"
kv "Region"   "$REGION"
kv "Zone"     "$ZONE"
kv "SQL name" "$DB_INSTANCE"
rule

# --------------------- Step 3: Task 1 - Enable APIs ------------------------
header "STEP 3 of 7  ·  Task 1 · Enable the required APIs"
enable_apis() {
  gcloud services enable servicenetworking.googleapis.com sqladmin.googleapis.com \
    compute.googleapis.com cloudresourcemanager.googleapis.com --quiet
}
retry "Enable Service Networking, SQL Admin and Compute APIs" enable_apis || exit 1

# --------------------- Step 4: Task 2 - Cloud SQL --------------------------
header "STEP 4 of 7  ·  Task 2 · Create the Cloud SQL instance"

setup_psa() {
  # Private Services Access: allocated IP range + VPC peering (idempotent)
  if ! gcloud compute addresses describe "$PSA_RANGE" --global >/dev/null 2>&1; then
    gcloud compute addresses create "$PSA_RANGE" --global --purpose=VPC_PEERING \
      --prefix-length=16 --network=default --description="Private services access" --quiet || return 1
  fi
  if ! gcloud services vpc-peerings list --network=default --service=servicenetworking.googleapis.com \
       --format='value(network)' 2>/dev/null | grep -q .; then
    gcloud services vpc-peerings connect --service=servicenetworking.googleapis.com \
      --ranges="$PSA_RANGE" --network=default --quiet || return 1
  fi
  return 0
}

sql_state() { gcloud sql instances describe "$DB_INSTANCE" --format='value(state)' 2>/dev/null; }

create_sql() {
  local state; state="$(sql_state)"
  case "$state" in
    RUNNABLE)
      ok "Instance already exists and is RUNNABLE"; return 0 ;;
    PENDING_CREATE|MAINTENANCE|PENDING_UPDATE)
      info "Instance is still being created (${state}). Waiting..."
      for _ in $(seq 1 60); do sleep 15; state="$(sql_state)"; [[ "$state" == "RUNNABLE" ]] && return 0; done
      return 1 ;;
    FAILED)
      warn "Instance is in FAILED state. Deleting it and recreating..."
      gcloud sql instances delete "$DB_INSTANCE" --quiet || true ;;
  esac

  # Self-heal: verify Private Services Access on every attempt
  setup_psa || { warn "Private Services Access not ready yet"; return 1; }

  gcloud sql instances create "$DB_INSTANCE" \
    --database-version=MYSQL_8_0 \
    --edition=ENTERPRISE \
    --tier=db-n1-standard-1 \
    --region="$REGION" \
    --gce-zone="$ZONE" \
    --availability-type=zonal \
    --storage-type=SSD \
    --storage-size=10GB \
    --storage-auto-increase \
    --network=default \
    --root-password="$ROOT_PASSWORD" \
    --quiet
  local rc=$?
  state="$(sql_state)"
  [[ "$state" == "RUNNABLE" ]] && return 0
  return $rc
}
retry "Create Cloud SQL instance '${DB_INSTANCE}' (this takes a few minutes)" create_sql || exit 1

patch_ssl() {
  gcloud sql instances patch "$DB_INSTANCE" --ssl-mode=ALLOW_UNENCRYPTED_AND_ENCRYPTED --quiet
}
retry "Allow unencrypted traffic (the lab does not use SSL)" patch_ssl \
  || warn "SSL patch skipped (unencrypted traffic is allowed by default)"

SQL_CONNECTION="$(gcloud sql instances describe "$DB_INSTANCE" --format='value(connectionName)')"
SQL_PRIVATE_IP="$(gcloud sql instances describe "$DB_INSTANCE" --format=json \
  | jq -r '.ipAddresses[]? | select(.type=="PRIVATE") | .ipAddress' | head -n1)"
ok "Connection name : ${SQL_CONNECTION}"
ok "Private IP      : ${SQL_PRIVATE_IP:-NOT FOUND}"
if [[ -z "$SQL_PRIVATE_IP" ]]; then
  err "No Private IP found. Check the network / Private Services Access settings."
  exit 1
fi

# ------------------- Step 5: Task 3 - Database + Proxy ---------------------
header "STEP 5 of 7  ·  Task 3 · Create database & start the proxy"

create_db() {
  if gcloud sql databases list --instance="$DB_INSTANCE" --format='value(name)' 2>/dev/null | grep -qx wordpress; then
    return 0
  fi
  gcloud sql databases create wordpress --instance="$DB_INSTANCE" --quiet
}
retry "Create database 'wordpress'" create_db || exit 1

# Self-heal: make sure SSH (direct + IAP) is allowed
gcloud compute firewall-rules create lab-allow-ssh --network=default --direction=INGRESS \
  --allow=tcp:22 --source-ranges=0.0.0.0/0,35.235.240.0/20 --quiet >/dev/null 2>&1 || true

# run_remote <vm> <script> [KEY=VALUE ...]  -> runs a script on a VM over SSH
run_remote() {
  local vm="$1" script="$2"; shift 2
  local envs="" pair k v
  for pair in "$@"; do k="${pair%%=*}"; v="${pair#*=}"; envs+="${k}=$(printf '%q' "$v") "; done
  local iap=()
  (( CUR_TRY % 2 == 0 )) && iap=(--tunnel-through-iap)   # alternate to IAP on even attempts
  printf '%s\n' "$script" | gcloud compute ssh "$vm" --zone="$ZONE" --quiet \
    --strict-host-key-checking=no "${iap[@]}" --command="${envs}bash -s"
}

REMOTE_PROXY=$(cat <<'EOS'
cd "$HOME"
if [ ! -x ./cloud_sql_proxy ]; then
  wget -q https://dl.google.com/cloudsql/cloud_sql_proxy.linux.amd64 -O cloud_sql_proxy || exit 1
  chmod +x cloud_sql_proxy
fi
pkill -f cloud_sql_proxy >/dev/null 2>&1 || true
sleep 1
setsid nohup ./cloud_sql_proxy -instances="$SQL_CONNECTION=tcp:3306" > proxy.log 2>&1 < /dev/null &
for i in $(seq 1 20); do
  grep -q "Ready for new connections" proxy.log 2>/dev/null && { echo "Proxy is READY:"; cat proxy.log; exit 0; }
  sleep 2
done
echo "Proxy did not become ready. Log:"; cat proxy.log; exit 1
EOS
)
start_proxy() { run_remote "$PROXY_VM" "$REMOTE_PROXY" "SQL_CONNECTION=$SQL_CONNECTION"; }
retry "Download & start Cloud SQL Proxy on ${PROXY_VM}" start_proxy || exit 1

# ---------------- Step 6: Task 4 - WordPress via the proxy -----------------
header "STEP 6 of 7  ·  Task 4 · Connect WordPress through the proxy"

REMOTE_WP=$(cat <<'EOS'
set -u
WP_DIR=""
for d in /var/www/html /var/www/html/wordpress /usr/share/wordpress; do
  [ -f "$d/wp-load.php" ] && { WP_DIR="$d"; break; }
done
[ -z "$WP_DIR" ] && { echo "WordPress directory not found"; exit 1; }
CFG="$WP_DIR/wp-config.php"

patch_cfg() {
  sudo sed -i -E \
   -e "s|define\( *'DB_NAME'.*|define( 'DB_NAME', 'wordpress' );|" \
   -e "s|define\( *'DB_USER'.*|define( 'DB_USER', 'root' );|" \
   -e "s|define\( *'DB_PASSWORD'.*|define( 'DB_PASSWORD', '$DB_PASS' );|" \
   -e "s|define\( *'DB_HOST'.*|define( 'DB_HOST', '$DB_HOST' );|" "$CFG"
}

if sudo test -f "$CFG"; then
  patch_cfg
else
  curl -s -o /dev/null -X POST "http://localhost/wp-admin/setup-config.php?step=2" \
    --data-urlencode "dbname=wordpress" --data-urlencode "uname=root" \
    --data-urlencode "pwd=$DB_PASS" --data-urlencode "dbhost=$DB_HOST" \
    --data-urlencode "prefix=wp_" --data-urlencode "language=" --data-urlencode "submit=Submit"
  if ! sudo test -f "$CFG"; then
    sudo cp "$WP_DIR/wp-config-sample.php" "$CFG" && patch_cfg
  fi
fi
sudo test -f "$CFG" || { echo "Could not create wp-config.php"; exit 1; }

OUT=$(curl -s -X POST "http://localhost/wp-admin/install.php?step=2" \
  --data-urlencode "weblog_title=Lab Blog" --data-urlencode "user_name=admin" \
  --data-urlencode "admin_password=$WP_PASS" --data-urlencode "admin_password2=$WP_PASS" \
  --data-urlencode "pw_weak=1" --data-urlencode "admin_email=admin@example.com" \
  --data-urlencode "blog_public=0" --data-urlencode "Submit=Install WordPress" \
  --data-urlencode "language=")

if echo "$OUT" | grep -qi "Already Installed"; then
  echo "RESULT: Already Installed! (the app is connected to Cloud SQL)"
elif echo "$OUT" | grep -qi "Success"; then
  echo "RESULT: Success! WordPress installed"
else
  echo "Install response:"; echo "$OUT" | sed 's/<[^>]*>//g' | grep -v '^\s*$' | head -15
  exit 1
fi

HOME_HTML=$(curl -sL "http://localhost/")
if echo "$HOME_HTML" | grep -qi "Error establishing a database connection"; then
  echo "Homepage reports a database connection error"; exit 1
fi
echo "Homepage OK (database connected)"
EOS
)
wp_proxy() { run_remote "$PROXY_VM" "$REMOTE_WP" "DB_HOST=127.0.0.1" "DB_PASS=$ROOT_PASSWORD" "WP_PASS=$WP_ADMIN_PASS"; }
retry "Install WordPress on ${PROXY_VM} (host 127.0.0.1 via proxy)" wp_proxy || exit 1

# -------------- Step 7: Task 5 - WordPress via the Private IP --------------
header "STEP 7 of 7  ·  Task 5 · Connect WordPress through the Private IP"
wp_private() { run_remote "$PRIVATE_VM" "$REMOTE_WP" "DB_HOST=$SQL_PRIVATE_IP" "DB_PASS=$ROOT_PASSWORD" "WP_PASS=$WP_ADMIN_PASS"; }
retry "Connect WordPress on ${PRIVATE_VM} (host ${SQL_PRIVATE_IP})" wp_private || exit 1

# ------------------------------ Final check --------------------------------
header "FINAL CHECK"
ext_ip() { gcloud compute instances describe "$1" --zone="$ZONE" --format='get(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null; }
PROXY_IP="$(ext_ip "$PROXY_VM")"
PRIV_IP="$(ext_ip "$PRIVATE_VM")"

check_url() {
  local code; code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "http://$1/")"
  if [[ "$code" =~ ^(200|301|302)$ ]]; then ok "http://$1  →  HTTP $code"; else warn "http://$1  →  HTTP $code"; fi
}
[[ -n "$PROXY_IP" ]] && check_url "$PROXY_IP"
[[ -n "$PRIV_IP"  ]] && check_url "$PRIV_IP"

echo
printf "${BLD}${GRN}"
cat <<'DONE'
   ╔══════════════════════════════════════════════════════════╗
   ║                     LAB COMPLETE  ✔                      ║
   ╚══════════════════════════════════════════════════════════╝
DONE
printf "${RST}\n"
kv "Project"                 "$PROJECT_ID"
kv "Region / Zone"           "$REGION / $ZONE"
kv "SQL instance"            "$DB_INSTANCE"
kv "Connection name"         "$SQL_CONNECTION"
kv "SQL private IP"          "$SQL_PRIVATE_IP"
kv "Root password"           "$ROOT_PASSWORD"
echo
kv "WordPress (proxy)"       "http://${PROXY_IP}"
kv "WordPress (private IP)"  "http://${PRIV_IP}"
echo
info "Now go back to the lab page and click every \"Check my progress\" button."
echo
