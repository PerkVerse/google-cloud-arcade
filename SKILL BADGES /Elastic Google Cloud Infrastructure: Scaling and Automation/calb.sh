#!/bin/bash
# ============================================================
#  Google Cloud Lab: Configure an Application Load Balancer
#  with Autoscaling  (Lab ID: OCBL105)
#  Run this FULL script in Cloud Shell.
# ============================================================

set -u
export DEBIAN_FRONTEND=noninteractive

# ---------- COLORS ----------
G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; B='\033[1;34m'; N='\033[0m'

step()    { echo -e "\n${B}================ $1 ================${N}"; }
ok()      { echo -e "${G}[OK] $1${N}"; }
info()    { echo -e "${Y}[INFO] $1${N}"; }
fail()    { echo -e "${R}[FAIL] $1${N}"; }

# ---------- RETRY FUNCTION (20 attempts) ----------
retry() {
  local desc="$1"; shift
  local attempt=1
  until "$@"; do
    if [ $attempt -ge 20 ]; then
      fail "$desc failed after 20 attempts."
      return 1
    fi
    info "$desc failed (attempt $attempt/20). Retrying in 10s..."
    sleep 10
    attempt=$((attempt+1))
  done
  ok "$desc"
}

# ---------- AUTO DETECTION ----------
step "AUTO-DETECTING PROJECT / REGION / ZONE"

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
[ -z "$PROJECT_ID" ] && PROJECT_ID=$(gcloud projects list --format='value(projectId)' --limit=1)
gcloud config set project "$PROJECT_ID" >/dev/null

REGION1=$(gcloud compute project-info describe \
  --format="value(commonInstanceMetadata.items[google-compute-default-region])")

if [ -z "$REGION1" ]; then
  REGION1=$(gcloud compute regions list --format="value(name)" --limit=1)
fi

ZONE1=$(gcloud compute project-info describe \
  --format="value(commonInstanceMetadata.items[google-compute-default-zone])")

if [ -z "$ZONE1" ]; then
  ZONE1=$(gcloud compute zones list --filter="region:$REGION1" \
    --format="value(name)" --limit=1)
fi

# Pick a second region automatically (different from REGION1)
REGION2=$(gcloud compute regions list --format="value(name)" \
  | grep -v "^$REGION1$" | head -n1)

ZONE2=$(gcloud compute zones list --filter="region:$REGION2" \
  --format="value(name)" --limit=1)

echo -e "${G}PROJECT_ID : $PROJECT_ID${N}"
echo -e "${G}REGION 1   : $REGION1   |  ZONE 1: $ZONE1${N}"
echo -e "${G}REGION 2   : $REGION2   |  ZONE 2: $ZONE2${N}"

# ============================================================
# TASK 1 — HEALTH CHECK FIREWALL RULE
# ============================================================
step "TASK 1: HEALTH CHECK FIREWALL RULE"

retry "Creating firewall rule fw-allow-health-checks" gcloud compute firewall-rules create fw-allow-health-checks \
  --network=default \
  --action=allow \
  --direction=INGRESS \
  --source-ranges=130.211.0.0/22,35.191.0.0/16 \
  --target-tags=allow-health-checks \
  --rules=tcp:80

# ============================================================
# TASK 2 — CLOUD ROUTER + CLOUD NAT
# ============================================================
step "TASK 2: CLOUD ROUTER + CLOUD NAT"

retry "Creating Cloud Router nat-router-us1" gcloud compute routers create nat-router-us1 \
  --network=default \
  --region="$REGION1"

retry "Creating Cloud NAT nat-config" gcloud compute routers nats create nat-config \
  --router=nat-router-us1 \
  --region="$REGION1" \
  --auto-allocate-nat-external-ips \
  --nat-all-subnet-ip-ranges

info "Waiting for Cloud NAT to become ACTIVE..."
for i in $(seq 1 20); do
  STATUS=$(gcloud compute routers nats describe nat-config \
    --router=nat-router-us1 --region="$REGION1" \
    --format="value(status)" 2>/dev/null)
  [ "$STATUS" = "ACTIVE" ] && break
  sleep 10
done
ok "Cloud NAT status: $STATUS"

# ============================================================
# TASK 3 — CUSTOM WEB SERVER IMAGE
# ============================================================
step "TASK 3: CREATING CUSTOM WEB SERVER IMAGE"

retry "Creating webserver VM" gcloud compute instances create webserver \
  --zone="$ZONE1" \
  --machine-type=e2-micro \
  --network-interface=subnet=default,no-address \
  --tags=allow-health-checks \
  --boot-disk-auto-delete=no \
  --metadata=startup-script='#! /bin/bash
apt-get update
apt-get install -y apache2
systemctl enable apache2
systemctl start apache2'

info "Waiting for webserver VM to finish setup..."
sleep 60

retry "Stopping webserver VM" gcloud compute instances stop webserver --zone="$ZONE1"

retry "Creating custom image mywebserver" gcloud compute images create mywebserver \
  --source-disk=webserver \
  --source-disk-zone="$ZONE1"

retry "Deleting webserver VM" gcloud compute instances delete webserver \
  --zone="$ZONE1" --quiet

# ============================================================
# TASK 4 — INSTANCE TEMPLATE + HEALTH CHECK + MIGs
# ============================================================
step "TASK 4: INSTANCE TEMPLATE, HEALTH CHECK, MIGs"

retry "Creating instance template" gcloud compute instance-templates create mywebserver-template \
  --machine-type=e2-micro \
  --image=mywebserver \
  --network-interface=subnet=default,no-address \
  --tags=allow-health-checks \
  --region="$REGION1"

retry "Creating TCP health check" gcloud compute health-checks create tcp http-health-check \
  --port=80 \
  --check-interval=5s \
  --timeout=5s \
  --unhealthy-threshold=2 \
  --healthy-threshold=2

# ----- REGION 1 MIG -----
retry "Creating regional MIG us-1-mig" gcloud compute instance-groups managed create us-1-mig \
  --template=mywebserver-template \
  --region="$REGION1" \
  --size=1 \
  --health-check=http-health-check \
  --initial-delay=60

retry "Setting autoscaling for us-1-mig" gcloud compute instance-groups managed set-autoscaling us-1-mig \
  --region="$REGION1" \
  --max-num-replicas=2 \
  --min-num-replicas=1 \
  --target-load-balancing-utilization=0.8 \
  --cool-down-period=60

# ----- REGION 2 MIG -----
retry "Creating regional MIG notus-1-mig" gcloud compute instance-groups managed create notus-1-mig \
  --template=mywebserver-template \
  --region="$REGION2" \
  --size=1 \
  --health-check=http-health-check \
  --initial-delay=60

retry "Setting autoscaling for notus-1-mig" gcloud compute instance-groups managed set-autoscaling notus-1-mig \
  --region="$REGION2" \
  --max-num-replicas=2 \
  --min-num-replicas=1 \
  --target-load-balancing-utilization=0.8 \
  --cool-down-period=60

# ============================================================
# TASK 5 — GLOBAL EXTERNAL APPLICATION LOAD BALANCER
# ============================================================
step "TASK 5: CREATING GLOBAL HTTP LOAD BALANCER"

retry "Creating backend service http-backend" gcloud compute backend-services create http-backend \
  --global \
  --protocol=HTTP \
  --health-checks=http-health-check \
  --enable-logging \
  --logging-sample-rate=1.0 \
  --load-balancing-scheme=EXTERNAL_MANAGED

retry "Adding us-1-mig backend (RATE mode)" gcloud compute backend-services add-backend http-backend \
  --global \
  --instance-group=us-1-mig \
  --instance-group-region="$REGION1" \
  --balancing-mode=RATE \
  --max-rate=50 \
  --capacity-scaler=1.0

retry "Adding notus-1-mig backend (UTILIZATION mode)" gcloud compute backend-services add-backend http-backend \
  --global \
  --instance-group=notus-1-mig \
  --instance-group-region="$REGION2" \
  --balancing-mode=UTILIZATION \
  --max-utilization=0.8 \
  --capacity-scaler=1.0

retry "Creating URL map" gcloud compute url-maps create http-lb \
  --default-service=http-backend

retry "Creating HTTP target proxy" gcloud compute target-http-proxies create http-lb-target-proxy \
  --url-map=http-lb

retry "Creating IPv4 forwarding rule" gcloud compute forwarding-rules create http-lb-ipv4 \
  --global \
  --target-http-proxy=http-lb-target-proxy \
  --ports=80 \
  --load-balancing-scheme=EXTERNAL_MANAGED \
  --ip-version=IPV4

retry "Creating IPv6 forwarding rule" gcloud compute forwarding-rules create http-lb-ipv6 \
  --global \
  --target-http-proxy=http-lb-target-proxy \
  --ports=80 \
  --load-balancing-scheme=EXTERNAL_MANAGED \
  --ip-version=IPV6

# ============================================================
# WAIT FOR LOAD BALANCER TO BECOME HEALTHY
# ============================================================
step "WAITING FOR LOAD BALANCER TO BECOME ACTIVE"

LB_IP=$(gcloud compute forwarding-rules describe http-lb-ipv4 \
  --global --format="value(IPAddress)")

echo -e "${G}LOAD BALANCER IPv4: $LB_IP${N}"

for i in $(seq 1 20); do
  RESULT=$(curl -m 3 -s "http://$LB_IP" | grep -i apache)
  [ -n "$RESULT" ] && break
  info "Load balancer not ready yet... waiting ($i/20)"
  sleep 15
done

[ -n "$RESULT" ] && ok "Load balancer is serving Apache traffic." \
  || fail "Load balancer still not responding. Re-run the waiting loop."

# ============================================================
# TASK 6 — STRESS TEST
# ============================================================
step "TASK 6: STRESS TESTING LOAD BALANCER"

retry "Creating stress-test VM" gcloud compute instances create stress-test \
  --zone="$ZONE1" \
  --machine-type=e2-micro \
  --image=mywebserver \
  --boot-disk-auto-delete=yes

info "Waiting for stress-test VM..."
sleep 45

retry "Installing Apache Benchmark (apache2-utils)" gcloud compute ssh stress-test \
  --zone="$ZONE1" \
  --command="sudo apt-get update -y && sudo apt-get install -y apache2-utils"

info "Starting stress test: 500000 requests, concurrency 1000"
retry "Running Apache Benchmark stress test" gcloud compute ssh stress-test \
  --zone="$ZONE1" \
  --command="ab -n 500000 -c 1000 http://$LB_IP/"

# ============================================================
# FINAL OUTPUT
# ============================================================
step "LAB SETUP COMPLETE"

echo -e "${G}Project ID        : $PROJECT_ID${N}"
echo -e "${G}Region 1 / Zone   : $REGION1 / $ZONE1${N}"
echo -e "${G}Region 2          : $REGION2${N}"
echo -e "${G}Load Balancer IPv4: $LB_IP${N}"

LB_IPv6=$(gcloud compute forwarding-rules describe http-lb-ipv6 \
  --global --format="value(IPAddress)" 2>/dev/null)

echo -e "${G}Load Balancer IPv6: $LB_IPv6${N}"

echo -e "${Y}Open in browser:${N} http://$LB_IP"
echo -e "${Y}Check progress in lab page after each major task.${N}"
echo -e "${Y}Monitoring:${N} Network Services → Load Balancing → http-lb → Monitoring"
