#!/bin/bash
# =====================================================================
#  Configure an Application Load Balancer with Autoscaling (OCBL105)
#  Full lab automation for Google Cloud Shell
#  - Project / Region / Zone auto-detect
#  - Every step auto-retries (default 15 times) and is safe to re-run
#  Usage:   bash alb_autoscaling_lab.sh
#  Optional overrides:  REGION1=us-east1 REGION2=europe-west1 bash alb_autoscaling_lab.sh
# =====================================================================

export CLOUDSDK_CORE_DISABLE_PROMPTS=1

MAX_RETRY="${MAX_RETRY:-15}"
RETRY_DELAY="${RETRY_DELAY:-10}"

# ---------- Colors & pretty output ----------
R=$'\e[0m'; B=$'\e[1m'; D=$'\e[2m'
RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; BLU=$'\e[34m'; CYN=$'\e[36m'; MAG=$'\e[35m'

section() { echo; echo "${B}${BLU}━━━━ $* ━━━━${R}"; }
info()    { echo "  ${CYN}ℹ${R}  $*"; }
ok()      { echo "  ${GRN}✔${R}  $*"; }
warn()    { echo "  ${YEL}⚠${R}  $*"; }
bad()     { echo "  ${RED}✘${R}  $*"; }

# ---------- Retry engine ----------
# run "description" command args...
run() {
  local desc="$1"; shift
  local n=1 out=""
  echo "  ${D}▶ ${desc} ...${R}"
  while (( n <= MAX_RETRY )); do
    if out=$("$@" 2>&1); then
      ok "${desc}"
      return 0
    fi
    if grep -qiE "already exists|alreadyExists|duplicate nat name|duplicate|already in use|is already being used" <<<"$out"; then
      ok "${desc} ${D}(already exists - skipped)${R}"
      return 0
    fi
    local errline
    errline=$(grep -iE "ERROR|error:|unrecognized|invalid" <<<"$out" | head -n 1 | cut -c1-200)
    [[ -z "$errline" ]] && errline=$(tail -n 1 <<<"$out" | cut -c1-200)
    if grep -qiE "unrecognized arguments|Invalid choice|unknown flag|Invalid value for \\[--|required: |expected one argument" <<<"$out"; then
      bad "${desc} - command syntax error (retry se fix nahi hoga)"
      echo "      ${errline}"
      exit 1
    fi
    warn "Attempt ${n}/${MAX_RETRY} failed - retrying in ${RETRY_DELAY}s"
    echo "${D}      ${errline}${R}"
    sleep "$RETRY_DELAY"
    ((n++))
  done
  bad "${desc} FAILED after ${MAX_RETRY} attempts"
  echo "$out" | tail -n 6 | sed 's/^/      /'
  echo
  bad "Script rok diya. Dobara chalane par jahan ruka tha wahin se continue karega."
  exit 1
}

exists() { "$@" >/dev/null 2>&1; }

# =====================================================================
clear
echo "${B}${MAG}"
echo "  ╔══════════════════════════════════════════════════════════╗"
echo "  ║   Application Load Balancer + Autoscaling - Auto Lab     ║"
echo "  ╚══════════════════════════════════════════════════════════╝${R}"

# ---------- 0. Auto-detect environment ----------
section "Step 0 : Environment auto-detect"

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
[[ -z "$PROJECT_ID" || "$PROJECT_ID" == "(unset)" ]] && PROJECT_ID="$DEVSHELL_PROJECT_ID"
[[ -z "$PROJECT_ID" ]] && PROJECT_ID=$(gcloud projects list --filter="projectId~qwiklabs" --format="value(projectId)" --limit=1 2>/dev/null)
[[ -z "$PROJECT_ID" ]] && PROJECT_ID=$(gcloud projects list --format="value(projectId)" --limit=1 2>/dev/null)
if [[ -z "$PROJECT_ID" ]]; then bad "Project ID detect nahi hua. Lab credentials se login hai?"; exit 1; fi
gcloud config set project "$PROJECT_ID" >/dev/null 2>&1

run "Enabling Compute Engine API" gcloud services enable compute.googleapis.com --project "$PROJECT_ID"

meta() { gcloud compute project-info describe --project "$PROJECT_ID" \
          --format="value(commonInstanceMetadata.items[$1])" 2>/dev/null; }

# Region 1 / Zone 1 (lab default metadata)
REGION1="${REGION1:-$(meta google-compute-default-region)}"
ZONE1="${ZONE1:-$(meta google-compute-default-zone)}"
[[ -z "$REGION1" ]] && REGION1=$(gcloud config get-value compute/region 2>/dev/null)
[[ -z "$ZONE1"   ]] && ZONE1=$(gcloud config get-value compute/zone 2>/dev/null)
[[ "$REGION1" == "(unset)" ]] && REGION1=""
[[ "$ZONE1"   == "(unset)" ]] && ZONE1=""
[[ -z "$REGION1" && -n "$ZONE1" ]] && REGION1="${ZONE1%-*}"
[[ -z "$REGION1" ]] && REGION1="us-central1"
if [[ -z "$ZONE1" ]]; then
  ZONE1=$(gcloud compute zones list --filter="name~^${REGION1}- AND status=UP" --format="value(name)" 2>/dev/null | sort | head -n 1)
fi

# Region 2 (non-US region for notus-1-mig)
if [[ -z "$REGION2" ]]; then
  case "$REGION1" in
    europe-*) REGION2="asia-east1" ;;
    *)        REGION2="europe-west1" ;;
  esac
fi

# Stress-test VM: different region, same continent as Region 1
GEO="${REGION1%%-*}"
STRESS_REGION="${STRESS_REGION:-$(gcloud compute regions list --format='value(name)' 2>/dev/null \
   | grep "^${GEO}-" | grep -vx "$REGION1" | grep -vx "$REGION2" | sort | head -n 1)}"
[[ -z "$STRESS_REGION" ]] && STRESS_REGION="us-central1"
STRESS_ZONE="${STRESS_ZONE:-$(gcloud compute zones list --filter="name~^${STRESS_REGION}- AND status=UP" --format='value(name)' 2>/dev/null | sort | head -n 1)}"

echo
echo "  ${B}Project ID    :${R} ${GRN}${PROJECT_ID}${R}"
echo "  ${B}Region 1      :${R} ${GRN}${REGION1}${R}   ${B}Zone 1 :${R} ${GRN}${ZONE1}${R}"
echo "  ${B}Region 2      :${R} ${GRN}${REGION2}${R}"
echo "  ${B}Stress region :${R} ${GRN}${STRESS_REGION}${R}   ${B}Zone :${R} ${GRN}${STRESS_ZONE}${R}"
echo
warn "Agar lab panel me Region 2 alag likha hai to Ctrl+C karke chalao:  REGION2=<region> bash alb_autoscaling_lab.sh"
sleep 5

gcloud config set compute/region "$REGION1" >/dev/null 2>&1
gcloud config set compute/zone "$ZONE1" >/dev/null 2>&1

# ---------- Task 1 : Firewall ----------
section "Task 1 : Health check firewall rule"
run "Creating fw-allow-health-checks" \
  gcloud compute firewall-rules create fw-allow-health-checks \
    --network=default --direction=INGRESS --action=allow --rules=tcp:80 \
    --source-ranges=130.211.0.0/22,35.191.0.0/16 --target-tags=allow-health-checks

# ---------- Task 2 : Cloud Router + NAT ----------
section "Task 2 : Cloud Router & Cloud NAT"
run "Creating Cloud Router nat-router-us1" \
  gcloud compute routers create nat-router-us1 --network=default --region="$REGION1"
run "Creating NAT gateway nat-config" \
  gcloud compute routers nats create nat-config --router=nat-router-us1 --region="$REGION1" \
    --auto-allocate-nat-external-ips --nat-all-subnet-ip-ranges
info "NAT ko Running hone ke liye 40s wait..."
sleep 40

# ---------- Task 3 : Custom image ----------
section "Task 3 : Custom web server image"
if exists gcloud compute images describe mywebserver; then
  ok "Image mywebserver pehle se hai - Task 3 skipped"
else
  STARTUP=$(mktemp)
  cat > "$STARTUP" <<'EOS'
#!/bin/bash
until apt-get update && apt-get install -y apache2; do sleep 10; done
systemctl enable apache2
systemctl start apache2
until curl -s localhost | grep -qi apache; do sleep 3; done
echo "APACHE_SETUP_COMPLETE"
EOS

  if ! exists gcloud compute disks describe webserver --zone="$ZONE1"; then
    run "Creating VM webserver (no external IP, keep boot disk)" \
      gcloud compute instances create webserver --zone="$ZONE1" \
        --tags=allow-health-checks --no-address --network=default \
        --no-boot-disk-auto-delete --metadata-from-file=startup-script="$STARTUP"
  fi

  if exists gcloud compute instances describe webserver --zone="$ZONE1"; then
    info "Apache install hone ka wait (max ~8 min)..."
    READY=0
    for i in $(seq 1 48); do
      SERIAL=$(gcloud compute instances get-serial-port-output webserver --zone="$ZONE1" 2>/dev/null)
      if [[ "$SERIAL" == *APACHE_SETUP_COMPLETE* ]]; then
        READY=1; break
      fi
      printf "  ${D}   waiting... %ds${R}\r" $((i*10)); sleep 10
    done
    echo
    if (( READY )); then ok "Apache installed & enabled on boot"; else warn "Ready marker nahi mila, phir bhi aage badh raha hoon"; fi

    run "Deleting VM webserver (boot disk kept)" \
      gcloud compute instances delete webserver --zone="$ZONE1" --keep-disks=boot --quiet
  fi
  rm -f "$STARTUP"

  run "Creating custom image mywebserver" \
    gcloud compute images create mywebserver --source-disk=webserver --source-disk-zone="$ZONE1"
fi

# ---------- Task 4 : Template, health check, MIGs ----------
section "Task 4 : Instance template & managed instance groups"
run "Creating instance template mywebserver-template" \
  gcloud compute instance-templates create mywebserver-template \
    --machine-type=e2-micro --image="mywebserver" --image-project="$PROJECT_ID" \
    --tags=allow-health-checks --network=default --no-address

run "Creating health check http-health-check" \
  gcloud compute health-checks create http http-health-check --port=80

create_mig() {  # name region
  local NAME="$1" REG="$2"
  run "Creating MIG ${NAME} (${REG})" \
    gcloud compute instance-groups managed create "$NAME" \
      --template=mywebserver-template --size=1 --region="$REG" \
      --health-check=http-health-check --initial-delay=60
  run "Autoscaling ${NAME}: min 1 / max 2 / LB utilization 80%" \
    gcloud compute instance-groups managed set-autoscaling "$NAME" --region="$REG" \
      --min-num-replicas=1 --max-num-replicas=2 \
      --target-load-balancing-utilization=0.8 --cool-down-period=60
  run "Setting named port http:80 on ${NAME}" \
    gcloud compute instance-groups set-named-ports "$NAME" --named-ports=http:80 --region="$REG"
}
create_mig us-1-mig    "$REGION1"
create_mig notus-1-mig "$REGION2"

run "Waiting for us-1-mig to become stable" \
  gcloud compute instance-groups managed wait-until us-1-mig --stable --region="$REGION1" --timeout=600
run "Waiting for notus-1-mig to become stable" \
  gcloud compute instance-groups managed wait-until notus-1-mig --stable --region="$REGION2" --timeout=600

# ---------- Task 5 : Load balancer ----------
section "Task 5 : Application Load Balancer (HTTP)"
run "Creating backend service http-backend" \
  gcloud compute backend-services create http-backend --global \
    --load-balancing-scheme=EXTERNAL_MANAGED --protocol=HTTP --port-name=http \
    --health-checks=http-health-check --enable-logging --logging-sample-rate=1.0

run "Adding backend us-1-mig (RATE, 50 RPS)" \
  gcloud compute backend-services add-backend http-backend --global \
    --instance-group=us-1-mig --instance-group-region="$REGION1" \
    --balancing-mode=RATE --max-rate-per-instance=50 --capacity-scaler=1.0

run "Adding backend notus-1-mig (UTILIZATION 80%)" \
  gcloud compute backend-services add-backend http-backend --global \
    --instance-group=notus-1-mig --instance-group-region="$REGION2" \
    --balancing-mode=UTILIZATION --max-utilization=0.8 --capacity-scaler=1.0

run "Creating URL map http-lb" \
  gcloud compute url-maps create http-lb --default-service=http-backend
run "Creating target HTTP proxy" \
  gcloud compute target-http-proxies create http-lb-target-proxy --url-map=http-lb

run "Creating IPv4 forwarding rule" \
  gcloud compute forwarding-rules create http-lb-forwarding-rule --global \
    --load-balancing-scheme=EXTERNAL_MANAGED --network-tier=PREMIUM \
    --target-http-proxy=http-lb-target-proxy --ports=80
run "Creating IPv6 forwarding rule" \
  gcloud compute forwarding-rules create http-lb-forwarding-rule-2 --global \
    --load-balancing-scheme=EXTERNAL_MANAGED --network-tier=PREMIUM --ip-version=IPV6 \
    --target-http-proxy=http-lb-target-proxy --ports=80

LB_IP=$(gcloud compute forwarding-rules describe http-lb-forwarding-rule --global --format="value(IPAddress)")
LB_IP_V6=$(gcloud compute forwarding-rules describe http-lb-forwarding-rule-2 --global --format="value(IPAddress)")
echo
echo "  ${B}LB IPv4 :${R} ${GRN}${LB_IP}${R}"
echo "  ${B}LB IPv6 :${R} ${GRN}${LB_IP_V6}${R}"

# ---------- Task 6 : Stress test ----------
section "Task 6 : Stress test"
info "Load balancer ready hone ka wait (max ~15 min)..."
LB_READY=0
for i in $(seq 1 90); do
  PAGE=$(curl -m 2 -s "http://${LB_IP}" 2>/dev/null)
  if [[ "${PAGE,,}" == *apache* ]]; then LB_READY=1; break; fi
  printf "  ${D}   Waiting for Load Balancer... %ds${R}\r" $((i*10)); sleep 10
done
echo
if (( LB_READY )); then ok "Load balancer is serving traffic  ->  http://${LB_IP}"; else warn "LB abhi tak ready nahi, stress test phir bhi start kar raha hoon"; fi

STRESS_STARTUP=$(mktemp)
cat > "$STRESS_STARTUP" <<EOS
#!/bin/bash
systemd-run --unit=lb-stress ab -n 500000 -c 1000 http://${LB_IP}/ || (setsid nohup ab -n 500000 -c 1000 http://${LB_IP}/ >/tmp/ab.log 2>&1 &)
EOS

run "Creating stress-test VM (${STRESS_ZONE}) - auto starts ab load" \
  gcloud compute instances create stress-test --zone="$STRESS_ZONE" \
    --machine-type=e2-micro --image="mywebserver" --image-project="$PROJECT_ID" \
    --metadata-from-file=startup-script="$STRESS_STARTUP"
rm -f "$STRESS_STARTUP"

# ---------- Monitor ----------
section "Live monitor (3 min)"
for i in $(seq 1 6); do
  US=$(gcloud compute instance-groups managed describe us-1-mig --region="$REGION1" --format="value(targetSize)" 2>/dev/null)
  NU=$(gcloud compute instance-groups managed describe notus-1-mig --region="$REGION2" --format="value(targetSize)" 2>/dev/null)
  echo "  ${CYN}$(date +%H:%M:%S)${R}  us-1-mig instances: ${B}${US:-?}${R}   notus-1-mig instances: ${B}${NU:-?}${R}"
  sleep 30
done

# ---------- Done ----------
echo
echo "${B}${GRN}"
echo "  ╔══════════════════════════════════════════════════════════╗"
echo "  ║                 ✔  LAB SETUP COMPLETE                    ║"
echo "  ╚══════════════════════════════════════════════════════════╝${R}"
echo "  Ab lab page par har task ke 'Check my progress' button click karo."
echo "  LB URL : http://${LB_IP}"
echo "  Monitoring : Network Services > Load balancing > http-lb > Monitoring"
echo
