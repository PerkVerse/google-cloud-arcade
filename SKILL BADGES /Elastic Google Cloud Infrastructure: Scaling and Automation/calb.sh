#!/bin/bash
# ==============================================================================
#  LAB   : Configure an Application Load Balancer with Autoscaling (OCBL105)
#  SERIES: Elastic Google Cloud Infrastructure: Scaling and Automation
#  MODE  : One command, auto-detect, auto-retry, safe to re-run
# ==============================================================================

# ----------------------------- BRANDING (edit me) -----------------------------
BRAND="PERKVERSE"
TAGLINE="Subscribe for more Google Cloud lab solutions"
REGION2_OVERRIDE=""     # Optional: set this to the Region 2 shown in your lab panel
# ------------------------------------------------------------------------------

set -u
export DEBIAN_FRONTEND=noninteractive

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; B='\033[1;34m'; C='\033[0;36m'; N='\033[0m'

banner() {
  clear 2>/dev/null
  echo -e "${C}"
  echo "  ============================================================"
  printf "   %-56s\n" "$BRAND"
  printf "   %-56s\n" "$TAGLINE"
  echo "  ============================================================"
  echo "   Lab : Configure an Application Load Balancer with Autoscaling"
  echo "  ============================================================"
  echo -e "${N}"
}

step() { echo -e "\n${B}>>> $1${N}"; }
ok()   { echo -e "${G}  [ OK ]  $1${N}"; }
info() { echo -e "${Y}  [ .. ]  $1${N}"; }
fail() { echo -e "${R}  [FAIL]  $1${N}"; }

# Retries transient errors, treats "already exists" as success, stops on bad arguments.
retry() {
  local desc="$1"; shift
  local log attempt=1
  log=$(mktemp)
  while true; do
    if "$@" >"$log" 2>&1; then
      ok "$desc"; rm -f "$log"; return 0
    fi
    if grep -qi 'already exists' "$log"; then
      ok "$desc (already exists)"; rm -f "$log"; return 0
    fi
    if grep -Eqi 'unrecognized arguments|invalid choice|invalid value|Usage:|flag.*does not exist|not a valid' "$log"; then
      cat "$log"; fail "$desc: command error, not retrying."; rm -f "$log"; return 1
    fi
    if [ "$attempt" -ge 20 ]; then
      cat "$log"; fail "$desc failed after 20 attempts."; rm -f "$log"; return 1
    fi
    info "$desc: not ready yet (try $attempt/20), retrying in 10s..."
    sleep 10
    attempt=$((attempt+1))
  done
}

banner

# ==============================================================================
# DETECT PROJECT, REGIONS AND ZONES
# ==============================================================================
step "Detecting project, regions and zones"

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
[ -z "$PROJECT_ID" ] && PROJECT_ID=$(gcloud projects list --format='value(projectId)' --limit=1)
gcloud config set project "$PROJECT_ID" >/dev/null 2>&1

REGION1=$(gcloud compute project-info describe \
  --format="value(commonInstanceMetadata.items[google-compute-default-region])" 2>/dev/null)
ZONE1=$(gcloud compute project-info describe \
  --format="value(commonInstanceMetadata.items[google-compute-default-zone])" 2>/dev/null)

ALL_REGIONS=$(gcloud compute regions list --format="value(name)" 2>/dev/null)
[ -z "$REGION1" ] && REGION1=$(echo "$ALL_REGIONS" | grep -E '^us-' | head -n1)
[ -z "$ZONE1" ] && ZONE1=$(gcloud compute zones list --filter="name~^${REGION1}-" --format="value(name)" --limit=1)

CONT1=${REGION1%%-*}

# Region 2: a different continent from Region 1 (the "notus" backend)
REGION2="$REGION2_OVERRIDE"
if [ -z "$REGION2" ]; then
  for r in europe-west1 europe-west4 asia-east1 asia-southeast1 us-east1 us-central1 us-west1; do
    if [ "${r%%-*}" != "$CONT1" ] && echo "$ALL_REGIONS" | grep -qx "$r"; then REGION2="$r"; break; fi
  done
fi
[ -z "$REGION2" ] && REGION2=$(echo "$ALL_REGIONS" | grep -v "^${CONT1}-" | head -n1)

# Stress-test region: same continent as Region 1, but a different region
STRESS_REGION=""
for r in us-central1 us-east1 us-east4 us-west1 europe-west1 europe-west4 asia-east1 asia-south1; do
  if [ "${r%%-*}" = "$CONT1" ] && [ "$r" != "$REGION1" ] && echo "$ALL_REGIONS" | grep -qx "$r"; then STRESS_REGION="$r"; break; fi
done
[ -z "$STRESS_REGION" ] && STRESS_REGION="$REGION1"
STRESS_ZONE=$(gcloud compute zones list --filter="name~^${STRESS_REGION}-" --format="value(name)" --limit=1)

echo -e "${G}  Project       : $PROJECT_ID${N}"
echo -e "${G}  Region 1/Zone : $REGION1 / $ZONE1${N}"
echo -e "${G}  Region 2      : $REGION2${N}"
echo -e "${G}  Stress test in: $STRESS_ZONE${N}"

# ==============================================================================
# TASK 1 - HEALTH CHECK FIREWALL RULE
# ==============================================================================
step "Task 1: Health check firewall rule"

retry "Firewall rule fw-allow-health-checks" gcloud compute firewall-rules create fw-allow-health-checks \
  --network=default --direction=INGRESS --action=allow --rules=tcp:80 \
  --source-ranges=130.211.0.0/22,35.191.0.0/16 \
  --target-tags=allow-health-checks

# ==============================================================================
# TASK 2 - CLOUD ROUTER + CLOUD NAT
# ==============================================================================
step "Task 2: Cloud Router and Cloud NAT"

retry "Cloud Router nat-router-us1" gcloud compute routers create nat-router-us1 \
  --network=default --region="$REGION1"

retry "Cloud NAT gateway nat-config" gcloud compute routers nats create nat-config \
  --router=nat-router-us1 --region="$REGION1" \
  --auto-allocate-nat-external-ips --nat-all-subnet-ip-ranges

info "Letting the NAT gateway become active..."
for i in $(seq 1 12); do
  NAT_IPS=$(gcloud compute routers get-status nat-router-us1 --region="$REGION1" \
    --format="value(result.natStatus[0].autoAllocatedNatIps)" 2>/dev/null)
  [ -n "$NAT_IPS" ] && break
  sleep 5
done
sleep 10
ok "Cloud NAT is running"

# ==============================================================================
# TASK 3 - CUSTOM WEB SERVER IMAGE
# ==============================================================================
step "Task 3: Custom web server image"

if gcloud compute images describe mywebserver >/dev/null 2>&1; then
  ok "Image mywebserver already exists"
else
  STARTUP='#! /bin/bash
apt-get update
apt-get install -y apache2
systemctl enable apache2
systemctl start apache2
sleep 3
curl -s localhost | grep -q Apache && echo "LAB_WEBSERVER_READY"'

  if gcloud compute instances describe webserver --zone="$ZONE1" >/dev/null 2>&1; then
    ok "webserver VM already exists"
  else
    retry "Creating VM webserver" gcloud compute instances create webserver \
      --zone="$ZONE1" --machine-type=e2-micro \
      --network-interface=subnet=default,no-address \
      --tags=allow-health-checks \
      --no-boot-disk-auto-delete \
      --metadata=startup-script="$STARTUP"
  fi

  info "Installing Apache on webserver (this takes 1-3 minutes)..."
  READY=0
  for i in $(seq 1 40); do
    if gcloud compute instances get-serial-port-output webserver --zone="$ZONE1" 2>/dev/null \
       | grep -q "LAB_WEBSERVER_READY"; then READY=1; break; fi
    sleep 10
  done
  [ "$READY" = "1" ] && ok "Apache installed, enabled and running" || info "Marker not seen, continuing anyway"

  retry "Stopping webserver"      gcloud compute instances stop webserver --zone="$ZONE1"
  retry "Creating image mywebserver" gcloud compute images create mywebserver \
    --source-disk=webserver --source-disk-zone="$ZONE1"
  retry "Deleting VM webserver (disk is kept)" gcloud compute instances delete webserver \
    --zone="$ZONE1" --quiet
fi

# ==============================================================================
# TASK 4 - TEMPLATE, HEALTH CHECK, MANAGED INSTANCE GROUPS
# ==============================================================================
step "Task 4: Instance template, health check and instance groups"

retry "Instance template mywebserver-template" gcloud compute instance-templates create mywebserver-template \
  --machine-type=e2-micro --image=mywebserver \
  --network-interface=network=default,no-address \
  --tags=allow-health-checks

retry "HTTP health check http-health-check" gcloud compute health-checks create http http-health-check \
  --port=80

create_mig() {
  local MIG="$1" REGION="$2"
  retry "Instance group $MIG ($REGION)" gcloud compute instance-groups managed create "$MIG" \
    --template=mywebserver-template --region="$REGION" --size=1 \
    --health-check=http-health-check --initial-delay=60
  retry "Named port http:80 on $MIG" gcloud compute instance-groups managed set-named-ports "$MIG" \
    --region="$REGION" --named-ports=http:80
  retry "Autoscaling on $MIG (1-2 instances, 80% LB utilization)" \
    gcloud compute instance-groups managed set-autoscaling "$MIG" \
    --region="$REGION" --min-num-replicas=1 --max-num-replicas=2 \
    --target-load-balancing-utilization=0.8 --cool-down-period=60
}

create_mig "us-1-mig"    "$REGION1"
create_mig "notus-1-mig" "$REGION2"

info "Waiting for the instance groups to become stable..."
gcloud compute instance-groups managed wait-until us-1-mig    --stable --region="$REGION1" --timeout=300 >/dev/null 2>&1
gcloud compute instance-groups managed wait-until notus-1-mig --stable --region="$REGION2" --timeout=300 >/dev/null 2>&1
ok "Instances are running in both regions"

# ==============================================================================
# TASK 5 - GLOBAL EXTERNAL APPLICATION LOAD BALANCER
# ==============================================================================
step "Task 5: Application Load Balancer (HTTP)"

retry "Backend service http-backend" gcloud compute backend-services create http-backend \
  --global --protocol=HTTP --port-name=http \
  --health-checks=http-health-check \
  --load-balancing-scheme=EXTERNAL_MANAGED \
  --enable-logging --logging-sample-rate=1.0

attached() {
  gcloud compute backend-services describe http-backend --global \
    --format="value(backends[].group)" 2>/dev/null | tr ';' '\n' | grep -q "/$1\$"
}

if attached us-1-mig; then ok "Backend us-1-mig already attached"; else
  retry "Backend us-1-mig (Rate, 50 RPS)" gcloud compute backend-services add-backend http-backend \
    --global --instance-group=us-1-mig --instance-group-region="$REGION1" \
    --balancing-mode=RATE --max-rate-per-instance=50 --capacity-scaler=1.0
fi

if attached notus-1-mig; then ok "Backend notus-1-mig already attached"; else
  retry "Backend notus-1-mig (Utilization, 80%)" gcloud compute backend-services add-backend http-backend \
    --global --instance-group=notus-1-mig --instance-group-region="$REGION2" \
    --balancing-mode=UTILIZATION --max-utilization=0.8 --capacity-scaler=1.0
fi

retry "URL map http-lb" gcloud compute url-maps create http-lb --default-service=http-backend
retry "Target proxy http-lb-target-proxy" gcloud compute target-http-proxies create http-lb-target-proxy \
  --url-map=http-lb

retry "Frontend IPv4 (port 80)" gcloud compute forwarding-rules create http-lb-forwarding-rule \
  --global --target-http-proxy=http-lb-target-proxy --ports=80 \
  --load-balancing-scheme=EXTERNAL_MANAGED --ip-version=IPV4
retry "Frontend IPv6 (port 80)" gcloud compute forwarding-rules create http-lb-forwarding-rule-2 \
  --global --target-http-proxy=http-lb-target-proxy --ports=80 \
  --load-balancing-scheme=EXTERNAL_MANAGED --ip-version=IPV6

LB_IP=$(gcloud compute forwarding-rules describe http-lb-forwarding-rule --global --format="value(IPAddress)")
LB_IPV6=$(gcloud compute forwarding-rules describe http-lb-forwarding-rule-2 --global --format="value(IPAddress)" 2>/dev/null)
echo -e "${G}  Load balancer IPv4: $LB_IP${N}"

info "Waiting for the load balancer to serve traffic (up to 12 minutes)..."
RESULT=""
for i in $(seq 1 48); do
  RESULT=$(curl -m 3 -s "http://$LB_IP" | grep -i apache)
  [ -n "$RESULT" ] && break
  info "Load balancer warming up ($i/48)..."
  sleep 15
done
[ -n "$RESULT" ] && ok "Load balancer is serving Apache traffic" \
                 || fail "Not responding yet. Wait 2-3 minutes and open http://$LB_IP"

# ==============================================================================
# TASK 6 - STRESS TEST
# ==============================================================================
step "Task 6: Stress test"

retry "Stress-test VM in $STRESS_ZONE" gcloud compute instances create stress-test \
  --zone="$STRESS_ZONE" --machine-type=e2-micro --image=mywebserver

SSH_OPTS=(--zone="$STRESS_ZONE" --quiet --strict-host-key-checking=no)

retry "Apache Bench is ready" gcloud compute ssh stress-test "${SSH_OPTS[@]}" \
  --command="command -v ab >/dev/null || (sudo apt-get update -y && sudo apt-get install -y apache2-utils)"

info "Generating load for 4 minutes (traffic starts in the closest region, then spills over)..."
gcloud compute ssh stress-test "${SSH_OPTS[@]}" \
  --command="ab -r -t 240 -n 500000 -c 1000 http://$LB_IP/ 2>&1 | tail -n 25"
ok "Stress test finished"

# ==============================================================================
# DONE
# ==============================================================================
echo -e "\n${C}  ============================================================${N}"
echo -e "${G}   LAB COMPLETE${N}"
echo -e "${C}  ============================================================${N}"
echo -e "${G}   Load balancer IPv4 : $LB_IP${N}"
echo -e "${G}   Load balancer IPv6 : ${LB_IPV6:-n/a}${N}"
echo -e "${Y}   Open in browser    : http://$LB_IP${N}"
echo -e "${Y}   Monitoring         : Network Services > Load balancing > http-lb > Monitoring${N}"
echo -e "${C}   Now click 'Check my progress' on every task.${N}"
echo -e "${C}   Thanks for watching - $BRAND${N}\n"
