#!/bin/bash
# ============================================================
#  Google Cloud Lab: Configure an Application Load Balancer
#  with Autoscaling — FIXED & IDEMPOTENT VERSION
#  Paste and run the whole script in Cloud Shell.
# ============================================================

set -u
export DEBIAN_FRONTEND=noninteractive

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; B='\033[1;34m'; N='\033[0m'

step() { echo -e "\n${B}================ $1 ================${N}"; }
ok()   { echo -e "${G}[OK] $1${N}"; }
info() { echo -e "${Y}[INFO] $1${N}"; }
fail() { echo -e "${R}[FAIL] $1${N}"; }

# Retry only transient failures; validation errors fail immediately.
retry() {
  local desc="$1"; shift
  local log
  log=$(mktemp)
  local attempt=1

  while true; do
    if "$@" >"$log" 2>&1; then
      ok "$desc"
      rm -f "$log"
      return 0
    fi

    if grep -Eqi \
      'argument|invalid|unrecognized|ignored explicit|must be|choice|Usage:|flag.*does not exist|not a valid' \
      "$log"; then
      cat "$log"
      fail "$desc: permanent command/validation error. Not retrying."
      rm -f "$log"
      return 1
    fi

    if [ "$attempt" -ge 20 ]; then
      cat "$log"
      fail "$desc failed after 20 attempts."
      rm -f "$log"
      return 1
    fi

    info "$desc failed (attempt $attempt/20). Retrying in 10s..."
    sleep 10
    attempt=$((attempt+1))
  done
}

exists() {
  gcloud compute "$@" --format="value(name)" >/dev/null 2>&1
}

# ============================================================
# AUTO-DETECT PROJECT / REGIONS / ZONES
# ============================================================
step "AUTO-DETECTING PROJECT, REGION AND ZONE"

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
[ -z "$PROJECT_ID" ] && PROJECT_ID=$(gcloud projects list --format='value(projectId)' --limit=1)
gcloud config set project "$PROJECT_ID" >/dev/null

REGION1=$(gcloud compute project-info describe \
  --format="value(commonInstanceMetadata.items[google-compute-default-region])")
[ -z "$REGION1" ] && REGION1=$(gcloud compute regions list --format="value(name)" --limit=1)

ZONE1=$(gcloud compute project-info describe \
  --format="value(commonInstanceMetadata.items[google-compute-default-zone])")
[ -z "$ZONE1" ] && ZONE1=$(gcloud compute zones list --filter="region:$REGION1" --format="value(name)" --limit=1)

REGION2=$(gcloud compute regions list --format="value(name)" \
  | grep -v "^${REGION1}$" | head -n1)
ZONE2=$(gcloud compute zones list --filter="region:$REGION2" --format="value(name)" --limit=1)

echo -e "${G}PROJECT : $PROJECT_ID${N}"
echo -e "${G}REGION1 : $REGION1 | ZONE1: $ZONE1${N}"
echo -e "${G}REGION2 : $REGION2 | ZONE2: $ZONE2${N}"

# ============================================================
# TASK 1 — FIREWALL RULE
# ============================================================
step "TASK 1: HEALTH CHECK FIREWALL RULE"

if gcloud compute firewall-rules describe fw-allow-health-checks >/dev/null 2>&1; then
  ok "Firewall rule already exists"
else
  retry "Creating firewall rule" gcloud compute firewall-rules create fw-allow-health-checks \
    --network=default \
    --action=allow \
    --direction=INGRESS \
    --source-ranges=130.211.0.0/22,35.191.0.0/16 \
    --target-tags=allow-health-checks \
    --rules=tcp:80
fi

# ============================================================
# TASK 2 — CLOUD ROUTER + NAT
# ============================================================
step "TASK 2: CLOUD ROUTER + CLOUD NAT"

if gcloud compute routers describe nat-router-us1 --region="$REGION1" >/dev/null 2>&1; then
  ok "Cloud Router already exists"
else
  retry "Creating Cloud Router" gcloud compute routers create nat-router-us1 \
    --network=default \
    --region="$REGION1"
fi

if gcloud compute routers nats describe nat-config \
  --router=nat-router-us1 --region="$REGION1" >/dev/null 2>&1; then
  ok "Cloud NAT already exists"
else
  retry "Creating Cloud NAT" gcloud compute routers nats create nat-config \
    --router=nat-router-us1 \
    --region="$REGION1" \
    --auto-allocate-nat-external-ips \
    --nat-all-subnet-ip-ranges
fi

info "Waiting for Cloud NAT to become ACTIVE..."
for i in $(seq 1 20); do
  STATUS=$(gcloud compute routers nats describe nat-config \
    --router=nat-router-us1 --region="$REGION1" \
    --format="value(status)" 2>/dev/null)
  [ "$STATUS" = "ACTIVE" ] && break
  sleep 10
done
ok "Cloud NAT status: ${STATUS:-UNKNOWN}"

# ============================================================
# TASK 3 — CUSTOM WEB SERVER IMAGE
# ============================================================
step "TASK 3: CUSTOM WEB SERVER IMAGE"

if gcloud compute images describe mywebserver >/dev/null 2>&1; then
  ok "Custom image mywebserver already exists"
else
  if gcloud compute instances describe webserver --zone="$ZONE1" >/dev/null 2>&1; then
    ok "webserver VM already exists"
  else
    retry "Creating webserver VM" gcloud compute instances create webserver \
      --zone="$ZONE1" \
      --machine-type=e2-micro \
      --network-interface=subnet=default,no-address \
      --tags=allow-health-checks \
      --no-boot-disk-auto-delete \
      --metadata=startup-script='#! /bin/bash
apt-get update
apt-get install -y apache2
systemctl enable apache2
systemctl start apache2'
  fi

  info "Waiting 90 seconds for Apache installation..."
  sleep 90

  retry "Stopping webserver VM" gcloud compute instances stop webserver --zone="$ZONE1"

  retry "Creating image mywebserver" gcloud compute images create mywebserver \
    --source-disk=webserver \
    --source-disk-zone="$ZONE1"

  retry "Deleting webserver VM" gcloud compute instances delete webserver \
    --zone="$ZONE1" --quiet
fi

# ============================================================
# TASK 4 — TEMPLATE, HEALTH CHECK, MIGs
# ============================================================
step "TASK 4: INSTANCE TEMPLATE, HEALTH CHECK, MIGs"

if gcloud compute instance-templates describe mywebserver-template >/dev/null 2>&1; then
  ok "Instance template already exists"
else
  retry "Creating instance template" gcloud compute instance-templates create mywebserver-template \
    --machine-type=e2-micro \
    --image=mywebserver \
    --network-interface=subnet=default,no-address \
    --tags=allow-health-checks
fi

if gcloud compute health-checks describe http-health-check >/dev/null 2>&1; then
  ok "Health check already exists"
else
  retry "Creating health check" gcloud compute health-checks create tcp http-health-check \
    --port=80 \
    --check-interval=5s \
    --timeout=5s \
    --unhealthy-threshold=2 \
    --healthy-threshold=2
fi

create_mig() {
  local MIG="$1" REGION="$2"

  if gcloud compute instance-groups managed describe "$MIG" --region="$REGION" >/dev/null 2>&1; then
    ok "$MIG already exists"
  else
    retry "Creating MIG $MIG" gcloud compute instance-groups managed create "$MIG" \
      --template=mywebserver-template \
      --region="$REGION" \
      --size=1 \
      --health-check=http-health-check \
      --initial-delay=60
  fi

  retry "Setting autoscaling for $MIG" gcloud compute instance-groups managed set-autoscaling "$MIG" \
    --region="$REGION" \
    --min-num-replicas=1 \
    --max-num-replicas=2 \
    --target-load-balancing-utilization=0.8 \
    --cool-down-period=60
}

create_mig "us-1-mig" "$REGION1"
create_mig "notus-1-mig" "$REGION2"

# ============================================================
# TASK 5 — GLOBAL EXTERNAL APPLICATION LOAD BALANCER
# ============================================================
step "TASK 5: CREATING GLOBAL HTTP LOAD BALANCER"

if gcloud compute backend-services describe http-backend --global >/dev/null 2>&1; then
  ok "Backend service already exists"
else
  retry "Creating backend service" gcloud compute backend-services create http-backend \
    --global \
    --protocol=HTTP \
    --health-checks=http-health-check \
    --enable-logging \
    --logging-sample-rate=1.0 \
    --load-balancing-scheme=EXTERNAL_MANAGED
fi

if gcloud compute backend-services describe http-backend --global \
  --format="value(backends[].group)" 2>/dev/null | grep -q "us-1-mig"; then
  ok "us-1-mig backend already attached"
else
  retry "Attaching us-1-mig backend" gcloud compute backend-services add-backend http-backend \
    --global \
    --instance-group=us-1-mig \
    --instance-group-region="$REGION1" \
    --balancing-mode=RATE \
    --max-rate=50 \
    --capacity-scaler=1.0
fi

if gcloud compute backend-services describe http-backend --global \
  --format="value(backends[].group)" 2>/dev/null | grep -q "notus-1-mig"; then
  ok "notus-1-mig backend already attached"
else
  retry "Attaching notus-1-mig backend" gcloud compute backend-services add-backend http-backend \
    --global \
    --instance-group=notus-1-mig \
    --instance-group-region="$REGION2" \
    --balancing-mode=UTILIZATION \
    --max-utilization=0.8 \
    --capacity-scaler=1.0
fi

if gcloud compute url-maps describe http-lb >/dev/null 2>&1; then
  ok "URL map already exists"
else
  retry "Creating URL map" gcloud compute url-maps create http-lb \
    --default-service=http-backend
fi

if gcloud compute target-http-proxies describe http-lb-target-proxy >/dev/null 2>&1; then
  ok "Target proxy already exists"
else
  retry "Creating target proxy" gcloud compute target-http-proxies create http-lb-target-proxy \
    --url-map=http-lb
fi

if gcloud compute forwarding-rules describe http-lb-ipv4 --global >/dev/null 2>&1; then
  ok "IPv4 forwarding rule already exists"
else
  retry "Creating IPv4 forwarding rule" gcloud compute forwarding-rules create http-lb-ipv4 \
    --global \
    --target-http-proxy=http-lb-target-proxy \
    --ports=80 \
    --load-balancing-scheme=EXTERNAL_MANAGED \
    --ip-version=IPV4
fi

if gcloud compute forwarding-rules describe http-lb-ipv6 --global >/dev/null 2>&1; then
  ok "IPv6 forwarding rule already exists"
else
  retry "Creating IPv6 forwarding rule" gcloud compute forwarding-rules create http-lb-ipv6 \
    --global \
    --target-http-proxy=http-lb-target-proxy \
    --ports=80 \
    --load-balancing-scheme=EXTERNAL_MANAGED \
    --ip-version=IPV6
fi

# ============================================================
# WAIT UNTIL LOAD BALANCER SERVES TRAFFIC
# ============================================================
step "WAITING FOR LOAD BALANCER"

LB_IP=$(gcloud compute forwarding-rules describe http-lb-ipv4 \
  --global --format="value(IPAddress)")

echo -e "${G}Load Balancer IPv4: $LB_IP${N}"

RESULT=""
for i in $(seq 1 20); do
  RESULT=$(curl -m 3 -s "http://$LB_IP" | grep -i apache)
  [ -n "$RESULT" ] && break
  info "Load balancer not ready yet ($i/20)..."
  sleep 15
done

if [ -n "$RESULT" ]; then
  ok "Load balancer is serving Apache traffic"
else
  fail "Load balancer is not responding yet. Wait 2-3 minutes, then run the stress-test section again."
fi

# ============================================================
# TASK 6 — STRESS TEST
# ============================================================
step "TASK 6: STRESS TEST"

if gcloud compute instances describe stress-test --zone="$ZONE1" >/dev/null 2>&1; then
  ok "stress-test VM already exists"
else
  retry "Creating stress-test VM" gcloud compute instances create stress-test \
    --zone="$ZONE1" \
    --machine-type=e2-micro \
    --image=mywebserver \
    --boot-disk-auto-delete
fi

retry "Installing Apache Benchmark" gcloud compute ssh stress-test \
  --zone="$ZONE1" \
  --command="sudo apt-get update -y && sudo apt-get install -y apache2-utils"

retry "Running stress test" gcloud compute ssh stress-test \
  --zone="$ZONE1" \
  --command="ab -n 500000 -c 1000 http://$LB_IP/"

# ============================================================
# FINAL DETAILS
# ============================================================
step "LAB COMPLETE"

LB_IPv6=$(gcloud compute forwarding-rules describe http-lb-ipv6 \
  --global --format="value(IPAddress)" 2>/dev/null)

echo -e "${G}Project           : $PROJECT_ID${N}"
echo -e "${G}Region1 / Zone1   : $REGION1 / $ZONE1${N}"
echo -e "${G}Region2           : $REGION2${N}"
echo -e "${G}Load Balancer IPv4: $LB_IP${N}"
echo -e "${G}Load Balancer IPv6: $LB_IPv6${N}"
echo -e "${Y}Open: http://$LB_IP${N}"
