#!/bin/bash
# =====================================================================
#  Internal Network Load Balancer Lab  -  FAST + SELF-HEALING runner
#  Run inside Google Cloud Shell (logged in as the lab student account)
#
#    bash ilb-lab.sh
#
#  - Asks for your lab's Region and Network name
#  - Independent steps run IN PARALLEL (much faster)
#  - Errors are auto-diagnosed, auto-fixed and retried with short waits
#  - Whole run is idempotent: re-run it any time, finished steps are skipped
#  - Full technical log: /tmp/ilb-lab.log
# =====================================================================

# ---------- advanced settings (change only if your lab differs) ----------
MAX_TRIES=30            # attempts per step before giving up on that pass
START_DELAY=3           # first wait between retries (seconds)
MAX_DELAY=12            # wait grows 1.5x each retry, capped here
SUBNET_A="subnet-a"
SUBNET_B="subnet-b"
UTIL_IP="10.10.20.50"
ILB_IP="10.10.30.5"
LOG="/tmp/ilb-lab.log"
: > "$LOG"

# ---------- colours ----------
B=$'\033[1m'; D=$'\033[2m'; R=$'\033[0m'
RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; BLU=$'\033[34m'; CYN=$'\033[36m'

# ---------- ui helpers ----------
banner() {
  clear 2>/dev/null
  echo "${CYN}${B}"
  echo "  ╔══════════════════════════════════════════════════════════╗"
  echo "  ║                                                          ║"
  echo "  ║      INTERNAL NETWORK LOAD BALANCER  -  LAB SETUP        ║"
  echo "  ║        Google Cloud  •  Parallel  •  Self-Healing        ║"
  echo "  ║                                                          ║"
  echo "  ╚══════════════════════════════════════════════════════════╝"
  echo "${R}"
}
px()    { [ -n "$TAG" ] && printf "${D}[%-7s]${R} " "$TAG"; }
step()  { echo; echo "${BLU}${B}  ━━ [$1/3] $2 ━━${R}"; }
ok()    { echo "  $(px)${GRN}✔${R} $1${D}${2:+  ($2)}${R}"; }
bad()   { echo "  $(px)${RED}✘${R} $1"; }
info()  { echo "  $(px)${CYN}•${R} $1"; }
note()  { echo "  $(px)${YLW}⚙${R} ${D}$1${R}"; }
retry_msg() { echo "  $(px)${YLW}↻${R} $1 ${D}- retry $2: $3${R}"; }

spin() {
  local pid=$1 msg=$2 f='-\|/' i=0
  tput civis 2>/dev/null
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r  ${CYN}%s${R} %s" "${f:i++%4:1}" "$msg"
    sleep 0.15
  done
  printf "\r\033[K"
  tput cnorm 2>/dev/null
}

# ---------------------------------------------------------------------
#  AUTO-FIX: look at the error text and repair the root cause
# ---------------------------------------------------------------------
autofix() {
  local f=$1
  if grep -qiE "SERVICE_DISABLED|has not been used in project|accessNotConfigured" "$f"; then
    note "auto-fix: enabling required APIs"
    gcloud services enable compute.googleapis.com iap.googleapis.com >/dev/null 2>&1
  elif grep -qiE "RATE_LIMIT|rate.?limit|RESOURCE_OPERATION_RATE_EXCEEDED" "$f"; then
    note "auto-fix: rate limited, cooling down 15s"; sleep 15
  elif grep -qiE "Load key|invalid format|bad permissions|UNPROTECTED PRIVATE KEY" "$f"; then
    note "auto-fix: regenerating SSH key"
    rm -f ~/.ssh/google_compute_engine ~/.ssh/google_compute_engine.pub
    ssh-keygen -t rsa -f ~/.ssh/google_compute_engine -N "" -q
  elif grep -qiE "4003|4033|failed to connect to backend|Connection (timed out|refused|closed)|port 22" "$f"; then
    if ! gcloud compute firewall-rules describe fw-allow-iap-ssh >/dev/null 2>&1; then
      note "auto-fix: creating IAP SSH firewall rule"
      gcloud compute firewall-rules create fw-allow-iap-ssh --network="$NETWORK" \
        --direction=INGRESS --action=allow --rules=tcp:22 \
        --source-ranges=35.235.240.0/20 >/dev/null 2>&1
    fi
  fi
}

# ---------------------------------------------------------------------
#  retry "description" command args...
#  (TRIES / START / CAP env vars can override the defaults per call)
# ---------------------------------------------------------------------
retry() {
  local desc="$1"; shift
  local tries=${TRIES:-$MAX_TRIES} delay=${START:-$START_DELAY} cap=${CAP:-$MAX_DELAY}
  local n=1 tmp rc pid reason
  tmp=$(mktemp)
  while (( n <= tries )); do
    "$@" </dev/null >"$tmp" 2>&1 &
    pid=$!
    [ -z "$TAG" ] && spin "$pid" "$desc"
    wait "$pid"; rc=$?
    { echo "### [${TAG:-main}] $desc (attempt $n, rc=$rc)"; cat "$tmp"; } >> "$LOG"
    if (( rc == 0 )); then
      ok "$desc" "$( (( n > 1 )) && echo "attempt $n" )"
      rm -f "$tmp"; return 0
    fi
    if grep -qiE "already exists|alreadyExists" "$tmp"; then
      ok "$desc" "already exists"
      rm -f "$tmp"; return 0
    fi
    reason=$(grep -v '^\s*$' "$tmp" | tail -n 1 | cut -c1-80)
    retry_msg "$desc" "$n/$tries" "$reason"
    autofix "$tmp"
    sleep "$delay"
    delay=$(( delay * 3 / 2 )); (( delay > cap )) && delay=$cap
    n=$((n+1))
  done
  bad "$desc  ${D}(gave up this pass - see $LOG)${R}"
  rm -f "$tmp"; return 1
}

ask() {  # ask "Prompt" "default"
  local v
  read -rp "  ${B}$1${R} ${D}[$2]${R}: " v
  echo "${v:-$2}"
}

# =====================================================================
#  START
# =====================================================================
banner

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
if [ -z "$PROJECT_ID" ] || [ "$PROJECT_ID" = "(unset)" ]; then
  PROJECT_ID=$(gcloud projects list --format="value(projectId)" --filter="projectId~qwiklabs" 2>/dev/null | head -n1)
  [ -z "$PROJECT_ID" ] && PROJECT_ID=$(gcloud projects list --format="value(projectId)" 2>/dev/null | head -n1)
  [ -n "$PROJECT_ID" ] && gcloud config set project "$PROJECT_ID" >/dev/null 2>&1
fi
info "Project : ${B}${PROJECT_ID:-not detected}${R}"
echo
retry "Enabling Compute Engine + IAP APIs" gcloud services enable compute.googleapis.com iap.googleapis.com

# ---------- user inputs ----------
echo
echo "  ${B}─── Enter your lab details (press Enter to accept the default) ───${R}"
echo

DEF_REGION=$(gcloud config get-value compute/region 2>/dev/null)
{ [ -z "$DEF_REGION" ] || [ "$DEF_REGION" = "(unset)" ]; } && DEF_REGION="us-west1"
DEF_NET=$(gcloud compute networks list --filter="name!=default" --format="value(name)" 2>/dev/null | head -n1)
[ -z "$DEF_NET" ] && DEF_NET="my-internal-app"

REGION=$(ask "Region        " "$DEF_REGION")
tries=0
until gcloud compute regions describe "$REGION" >/dev/null 2>&1 || (( tries >= 4 )); do
  bad "Region '$REGION' not found. Example: us-west1, us-central1, europe-west1"
  REGION=$(ask "Region        " "$DEF_REGION"); tries=$((tries+1))
done

NETWORK=$(ask "Network name  " "$DEF_NET")
tries=0
until gcloud compute networks describe "$NETWORK" >/dev/null 2>&1 || (( tries >= 4 )); do
  bad "Network '$NETWORK' not found. Available networks:"
  gcloud compute networks list --format="value(name)" 2>/dev/null | sed 's/^/        - /'
  NETWORK=$(ask "Network name  " "$DEF_NET"); tries=$((tries+1))
done

UTIL_ZONES=$(gcloud compute zones list --filter="region:$REGION" --format="value(name)" 2>/dev/null | sort | tr '\n' ' ')
[ -z "$UTIL_ZONES" ] && UTIL_ZONES="${REGION}-a ${REGION}-b ${REGION}-c"
UTIL_ZONE=${UTIL_ZONES%% *}
ROUTER="nat-router-${REGION}"

echo
echo "  ${B}┌──────────────────── Summary ────────────────────┐${R}"
printf "  │ %-14s %-34s │\n" "Project"      "$PROJECT_ID"
printf "  │ %-14s %-34s │\n" "Region"       "$REGION"
printf "  │ %-14s %-34s │\n" "Network"      "$NETWORK"
printf "  │ %-14s %-34s │\n" "Subnets"      "$SUBNET_A / $SUBNET_B"
printf "  │ %-14s %-34s │\n" "Utility VM"   "$UTIL_ZONE  ($UTIL_IP)"
printf "  │ %-14s %-34s │\n" "ILB frontend" "$ILB_IP : 80"
echo "  ${B}└─────────────────────────────────────────────────┘${R}"
echo
read -rp "  ${B}Start the setup? (Y/n)${R}: " go
[[ "$go" =~ ^[Nn] ]] && { echo "  Cancelled."; exit 0; }

gcloud config set compute/region "$REGION" >/dev/null 2>&1
START_TS=$(date +%s)

# =====================================================================
#  [1/3] PREPARE
# =====================================================================
step 1 "Preparing"

# Create the SSH key once, up front, so parallel SSH calls don't race on it
if [ ! -f ~/.ssh/google_compute_engine ]; then
  mkdir -p ~/.ssh && ssh-keygen -t rsa -f ~/.ssh/google_compute_engine -N "" -q 2>/dev/null
fi
if [ -f ~/.ssh/google_compute_engine ]; then ok "SSH key ready"; else note "SSH key will be created by gcloud on first connect"; fi

get_name() { gcloud compute instances list --filter="name~'^$1'" --format="value(name)" 2>/dev/null | head -n1; }
get_zone() { gcloud compute instances list --filter="name=$1" --format="value(zone.basename())" 2>/dev/null | head -n1; }
get_ip()   { gcloud compute instances describe "$1" --zone "$2" --format="value(networkInterfaces[0].networkIP)" 2>/dev/null; }

# NOTE: retry runs commands in a subshell, so we only use it to WAIT here and
# read the values again in the main shell afterwards.
backends_exist() { [ -n "$(get_name instance-group-1)" ] && [ -n "$(get_name instance-group-2)" ]; }
retry "Locating instance-group-1 / instance-group-2 VMs" backends_exist
IG1=$(get_name instance-group-1); IG2=$(get_name instance-group-2)
IG1_ZONE=$(get_zone "$IG1");      IG2_ZONE=$(get_zone "$IG2")
IG1_IP=$(get_ip "$IG1" "$IG1_ZONE"); IG2_IP=$(get_ip "$IG2" "$IG2_ZONE")
info "$IG1  ${D}$IG1_ZONE  $IG1_IP${R}"
info "$IG2  ${D}$IG2_ZONE  $IG2_IP${R}"

# =====================================================================
#  JOBS (each one is a chain of retried steps)
# =====================================================================
fw() { retry "$1" gcloud compute firewall-rules create "$2" --network="$NETWORK" \
        --direction=INGRESS --action=allow --rules="$3" --source-ranges="$4" ${5:+--target-tags="$5"}; }
job_fw_lb()  { fw "fw-allow-lb-access"            fw-allow-lb-access       all     10.10.0.0/16 backend-service; }
job_fw_hc()  { fw "fw-allow-health-checks"        fw-allow-health-checks   tcp:80  130.211.0.0/22,35.191.0.0/16 backend-service; }
job_fw_iap() { fw "fw-allow-iap-ssh (helper)"     fw-allow-iap-ssh         tcp:22  35.235.240.0/20; }

job_nat() {
  retry "Cloud Router $ROUTER" gcloud compute routers create "$ROUTER" --network="$NETWORK" --region="$REGION" &&
  retry "Cloud NAT nat-config" gcloud compute routers nats create nat-config --router="$ROUTER" \
        --region="$REGION" --auto-allocate-nat-external-ips --nat-all-subnet-ip-ranges
}

create_vm() {  # tries every zone of the region (handles zone capacity errors)
  local z out
  for z in $UTIL_ZONES; do
    out=$(gcloud compute instances create utility-vm --zone="$z" --machine-type=e2-medium \
          --image-family=debian-12 --image-project=debian-cloud \
          --network-interface="network=$NETWORK,subnet=$SUBNET_A,private-network-ip=$UTIL_IP,no-address" 2>&1) && return 0
    echo "$out" | grep -qi "already exists" && return 0
    echo "$out" >&2
  done
  return 1
}
job_vm() { retry "utility-vm ($UTIL_IP)" create_vm; }

ssh_cmd() { gcloud compute ssh "$1" --zone "$2" --tunnel-through-iap --quiet \
              --strict-host-key-checking=no --command "$3"; }

job_backend() {  # name zone
  local name=$1 zone=$2
  local cmd="sudo google_metadata_script_runner startup; curl -sf -m 5 http://localhost >/dev/null"
  [ "$name" = "$IG2" ] && sleep 4        # stagger so the two SSH key pushes don't collide
  TRIES=8 retry "Startup script on $name" ssh_cmd "$name" "$zone" "$cmd" && return 0
  note "SSH route failing - resetting $name (startup script re-runs on boot)"
  retry "Reset $name" gcloud compute instances reset "$name" --zone "$zone" || return 1
  sleep 40
  TRIES=15 retry "Startup script on $name (after reset)" ssh_cmd "$name" "$zone" "$cmd"
}

job_ilb() {
  retry "Health check my-ilb-health-check" gcloud compute health-checks create tcp my-ilb-health-check \
        --region="$REGION" --port=80 --check-interval=10s --timeout=5s \
        --healthy-threshold=2 --unhealthy-threshold=3 &&
  retry "Backend service my-ilb" gcloud compute backend-services create my-ilb \
        --load-balancing-scheme=internal --protocol=tcp --region="$REGION" \
        --health-checks=my-ilb-health-check --health-checks-region="$REGION" &&
  retry "Add backend instance-group-1" gcloud compute backend-services add-backend my-ilb \
        --region="$REGION" --instance-group=instance-group-1 --instance-group-zone="$IG1_ZONE" &&
  retry "Add backend instance-group-2" gcloud compute backend-services add-backend my-ilb \
        --region="$REGION" --instance-group=instance-group-2 --instance-group-zone="$IG2_ZONE" &&
  retry "Static IP my-ilb-ip ($ILB_IP)" gcloud compute addresses create my-ilb-ip \
        --region="$REGION" --subnet="$SUBNET_B" --addresses="$ILB_IP" &&
  retry "Forwarding rule my-ilb (port 80)" gcloud compute forwarding-rules create my-ilb \
        --region="$REGION" --load-balancing-scheme=internal --network="$NETWORK" \
        --subnet="$SUBNET_B" --address=my-ilb-ip --ip-protocol=TCP --ports=80 \
        --backend-service=my-ilb --backend-service-region="$REGION"
}

# ---------- parallel runner ----------
PIDS=(); TAGS=(); FAILED=()
run_job() { local tag=$1; shift; ( TAG=$tag "$@" ) </dev/null & PIDS+=($!); TAGS+=("$tag"); }
wait_jobs() {
  FAILED=()
  local i
  for i in "${!PIDS[@]}"; do wait "${PIDS[$i]}" || FAILED+=("${TAGS[$i]}"); done
  PIDS=(); TAGS=()
}

deploy_all() {
  run_job fw-lb   job_fw_lb
  run_job fw-hc   job_fw_hc
  run_job fw-iap  job_fw_iap
  run_job nat     job_nat
  run_job vm      job_vm
  run_job be-1    job_backend "$IG1" "$IG1_ZONE"
  run_job be-2    job_backend "$IG2" "$IG2_ZONE"
  run_job ilb     job_ilb
  wait_jobs
}

deploy_with_healing() {
  local pass
  for pass in 1 2 3; do
    (( pass > 1 )) && note "Pass $pass - re-running only what is missing (finished items are skipped)"
    deploy_all
    [ ${#FAILED[@]} -eq 0 ] && return 0
    bad "Not finished after pass $pass: ${FAILED[*]}"
  done
  return 1
}

# =====================================================================
#  [2/3] DEPLOY - tasks 1-4 run in parallel
# =====================================================================
step 2 "Deploying firewall • NAT • VMs • Load Balancer (parallel)"
echo "  ${D}live log lines are tagged by job: fw-*, nat, vm, be-1, be-2, ilb${R}"
echo
deploy_with_healing
UTIL_ZONE=$(get_zone utility-vm); [ -z "$UTIL_ZONE" ] && UTIL_ZONE=${UTIL_ZONES%% *}

# =====================================================================
#  [3/3] TEST - wait for health, then confirm both backends answer
# =====================================================================
step 3 "Testing the load balancer"

LB_OUT="/tmp/ilb-result.txt"; : > "$LB_OUT"
REMOTE_TEST="for i in \$(seq 1 20); do curl -s -m 3 $ILB_IP | grep -o \"instance-group-[0-9]\" | head -1; done | sort | uniq -c"

lb_healthy() { [ "$(gcloud compute backend-services get-health my-ilb --region="$REGION" 2>/dev/null | grep -c 'healthState: HEALTHY')" -ge 2 ]; }
check_lb() {
  local out
  out=$(gcloud compute ssh utility-vm --zone "$UTIL_ZONE" --tunnel-through-iap --quiet \
        --strict-host-key-checking=no --command "$REMOTE_TEST" 2>/dev/null)
  echo "$out" > "$LB_OUT"
  [ "$(echo "$out" | grep -c 'instance-group')" -ge 2 ]
}

LB_OK=0
for round in 1 2 3; do
  TRIES=30 START=4 CAP=6 retry "Waiting for both backends to turn HEALTHY" lb_healthy || note "continuing - testing directly"
  if TRIES=15 START=3 CAP=8 retry "Sending 20 requests to $ILB_IP from utility-vm" check_lb; then
    LB_OK=1; break
  fi
  note "Round $round failed - re-checking and repairing all resources"
  deploy_with_healing
  UTIL_ZONE=$(get_zone utility-vm); [ -z "$UTIL_ZONE" ] && UTIL_ZONE=${UTIL_ZONES%% *}
done

# =====================================================================
#  SUMMARY
# =====================================================================
ELAPSED=$(( $(date +%s) - START_TS ))
echo
if (( LB_OK == 1 )); then
  echo "${GRN}${B}  ╔══════════════════════════════════════════════════════════╗"
  echo "  ║                  ✔  LAB COMPLETED                        ║"
  echo "  ╚══════════════════════════════════════════════════════════╝${R}"
  echo
  echo "  ${B}Traffic distribution (20 requests to $ILB_IP):${R}"
  sed 's/^/     /' "$LB_OUT"
else
  echo "${RED}${B}  ╔══════════════════════════════════════════════════════════╗"
  echo "  ║        ✘  COULD NOT CONFIRM BOTH BACKENDS YET            ║"
  echo "  ╚══════════════════════════════════════════════════════════╝${R}"
  echo
  info "Health : gcloud compute backend-services get-health my-ilb --region=$REGION"
  info "Re-run this script - finished steps are skipped automatically."
fi
echo
info "Time taken : $((ELAPSED/60))m $((ELAPSED%60))s"
info "Full log   : $LOG"
echo
echo "  ${YLW}${B}Next:${R} lab page par har task ke ${B}'Check my progress'${R} button click karo."
echo
