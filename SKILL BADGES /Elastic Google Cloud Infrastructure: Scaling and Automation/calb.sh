#!/bin/bash
# ==============================================================================
#  LAB    : Configure an Application Load Balancer with Autoscaling (OCBL105)
#  SERIES : Elastic Google Cloud Infrastructure: Scaling and Automation
#  USAGE  : Paste into Cloud Shell, enter Region 1 / Zone 1 / Region 2 when asked
# ==============================================================================

# ----------------------------- BRANDING (edit me) -----------------------------
BRAND="PERKVERSE"
TAGLINE="Subscribe for more Google Cloud lab solutions"
# ------------------------------------------------------------------------------

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

# Retries temporary errors (up to 20 times), treats "already exists" as success,
# and stops immediately on permanent errors (bad arguments, quota, location policy).
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
    if grep -Eqi 'unrecognized arguments|invalid choice|invalid value|Usage:|flag.*does not exist|not a valid|quota|constraint|permission' "$log"; then
      head -n 6 "$log" | cut -c1-200 | sed 's/^/           /'
      fail "$desc: permanent error, not retrying."; rm -f "$log"; return 1
    fi
    if [ "$attempt" -ge 20 ]; then
      head -n 6 "$log" | cut -c1-200 | sed 's/^/           /'
      fail "$desc failed after 20 attempts."; rm -f "$log"; return 1
    fi
    info "$desc: attempt $attempt/20 failed, retrying in 10s"
    grep -m1 -iE 'ERROR' "$log" | cut -c1-160 | sed 's/^/           /'
    sleep 10
    attempt=$((attempt+1))
  done
}

ask() {  # ask "Question" "default"  -> answer in $ANSWER
  local v
  if [ -n "$2" ]; then read -r -p "  $1 [$2]: " v; ANSWER="${v:-$2}"
  else read -r -p "  $1: " v; ANSWER="$v"; fi
}

main() {
  banner

  # ============================================================================
  # SETUP - PROJECT AND LAB VALUES
  # ============================================================================
  step "Setup: project and lab values"

  PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
  [ -z "$PROJECT_ID" ] && PROJECT_ID=$(gcloud projects list --format='value(projectId)' --limit=1)
  gcloud config set project "$PROJECT_ID" >/dev/null 2>&1
  echo -e "${G}  Project: $PROJECT_ID${N}"

  ALL_REGIONS=$(gcloud compute regions list --format="value(name)" 2>/dev/null)
  ALL_ZONES=$(gcloud compute zones list --format="value(name)" 2>/dev/null)

  DEF_R1=$(gcloud compute project-info describe \
    --format="value(commonInstanceMetadata.items[google-compute-default-region])" 2>/dev/null)
  DEF_Z1=$(gcloud compute project-info describe \
    --format="value(commonInstanceMetadata.items[google-compute-default-zone])" 2>/dev/null)

  echo
  echo "  Enter the values shown in the LAB PANEL on the left side of the lab page."
  echo

  while true; do
    ask "Region 1" "$DEF_R1"; REGION1="$ANSWER"
    echo "$ALL_REGIONS" | grep -qx "$REGION1" && break
    fail "'$REGION1' is not a valid region. Try again."
  done

  [ -z "$DEF_Z1" ] && DEF_Z1=$(echo "$ALL_ZONES" | grep -m1 "^${REGION1}-")
  while true; do
    ask "Zone 1 (inside $REGION1)" "$DEF_Z1"; ZONE1="$ANSWER"
    echo "$ALL_ZONES" | grep -qx "$ZONE1" && [ "${ZONE1%-*}" = "$REGION1" ] && break
    fail "'$ZONE1' is not a zone of $REGION1. Try again."
  done

  while true; do
    ask "Region 2 (press Enter to auto-detect)" ""; REGION2="$ANSWER"
    [ -z "$REGION2" ] && break
    echo "$ALL_REGIONS" | grep -qx "$REGION2" && break
    fail "'$REGION2' is not a valid region. Try again."
  done

  CONT1=${REGION1%%-*}
  echo
  echo -e "${G}  Region 1 / Zone 1 : $REGION1 / $ZONE1${N}"
  echo -e "${G}  Region 2          : ${REGION2:-auto-detect}${N}"

  # ============================================================================
  # TASK 1 - HEALTH CHECK FIREWALL RULE
  # ============================================================================
  step "Task 1: Health check firewall rule"

  retry "Firewall rule fw-allow-health-checks" gcloud compute firewall-rules create fw-allow-health-checks \
    --network=default --direction=INGRESS --action=allow --rules=tcp:80 \
    --source-ranges=130.211.0.0/22,35.191.0.0/16 \
    --target-tags=allow-health-checks || return 1

  # ============================================================================
  # TASK 2 - CLOUD ROUTER + CLOUD NAT
  # ============================================================================
  step "Task 2: Cloud Router and Cloud NAT"

  retry "Cloud Router nat-router-us1" gcloud compute routers create nat-router-us1 \
    --network=default --region="$REGION1" || return 1

  retry "Cloud NAT gateway nat-config" gcloud compute routers nats create nat-config \
    --router=nat-router-us1 --region="$REGION1" \
    --auto-allocate-nat-external-ips --nat-all-subnet-ip-ranges || return 1

  info "Waiting for the NAT gateway to become active..."
  for i in $(seq 1 12); do
    NAT_IPS=$(gcloud compute routers get-status nat-router-us1 --region="$REGION1" \
      --format="value(result.natStatus[0].autoAllocatedNatIps)" 2>/dev/null)
    [ -n "$NAT_IPS" ] && break
    sleep 5
  done
  sleep 10
  ok "Cloud NAT is running"

  # ============================================================================
  # TASK 3 - CUSTOM WEB SERVER IMAGE
  # ============================================================================
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
      ok "VM webserver already exists"
    else
      retry "Creating VM webserver" gcloud compute instances create webserver \
        --zone="$ZONE1" --machine-type=e2-micro \
        --network-interface=subnet=default,no-address \
        --tags=allow-health-checks \
        --no-boot-disk-auto-delete \
        --metadata=startup-script="$STARTUP" || return 1
    fi

    info "Installing Apache on webserver (takes 1-3 minutes)..."
    READY=0
    for i in $(seq 1 40); do
      if gcloud compute instances get-serial-port-output webserver --zone="$ZONE1" 2>/dev/null \
         | grep -q "LAB_WEBSERVER_READY"; then READY=1; break; fi
      sleep 10
    done
    [ "$READY" = "1" ] && ok "Apache installed, enabled and running" || info "Apache marker not seen, continuing anyway"

    retry "Stopping webserver" gcloud compute instances stop webserver --zone="$ZONE1" || return 1
    retry "Creating image mywebserver" gcloud compute images create mywebserver \
      --source-disk=webserver --source-disk-zone="$ZONE1" || return 1
    retry "Deleting VM webserver (disk is kept)" gcloud compute instances delete webserver \
      --zone="$ZONE1" --quiet || return 1
  fi

  # ============================================================================
  # TASK 4 - TEMPLATE, HEALTH CHECK, MANAGED INSTANCE GROUPS
  # ============================================================================
  step "Task 4: Instance template, health check and instance groups"

  retry "Instance template mywebserver-template" gcloud compute instance-templates create mywebserver-template \
    --machine-type=e2-micro --image=mywebserver \
    --network-interface=network=default,no-address \
    --tags=allow-health-checks || return 1

  retry "HTTP health check http-health-check" gcloud compute health-checks create http http-health-check \
    --port=80 || return 1

  create_mig() {
    local MIG="$1" REGION="$2"
    retry "Instance group $MIG ($REGION)" gcloud compute instance-groups managed create "$MIG" \
      --template=mywebserver-template --region="$REGION" --size=1 \
      --health-check=http-health-check --initial-delay=60 || return 1
    retry "Named port http:80 on $MIG" gcloud compute instance-groups managed set-named-ports "$MIG" \
      --region="$REGION" --named-ports=http:80 || return 1
    retry "Autoscaling on $MIG (1-2 instances, 80% LB utilization)" \
      gcloud compute instance-groups managed set-autoscaling "$MIG" \
      --region="$REGION" --min-num-replicas=1 --max-num-replicas=2 \
      --target-load-balancing-utilization=0.8 --cool-down-period=60 || return 1
  }

  create_mig "us-1-mig" "$REGION1" || return 1

  # Region 2 was left blank: try regions until the project policy allows one
  if [ -z "$REGION2" ]; then
    info "Region 2 not entered. Searching for an allowed region..."
    for r in $( { echo "$ALL_REGIONS" | grep -v "^${CONT1}-"; echo "$ALL_REGIONS" | grep "^${CONT1}-" | grep -vx "$REGION1"; } ); do
      if gcloud compute instance-groups managed describe notus-1-mig --region="$r" >/dev/null 2>&1; then REGION2="$r"; break; fi
      OUT=$(gcloud compute instance-groups managed create notus-1-mig \
            --template=mywebserver-template --region="$r" --size=1 \
            --health-check=http-health-check --initial-delay=60 2>&1) && { REGION2="$r"; break; }
      echo "$OUT" | grep -qi 'resourceLocations' || echo "$OUT" | head -n 2 | cut -c1-180 | sed 's/^/           /'
    done
    [ -z "$REGION2" ] && { fail "No allowed Region 2 found. Re-run and enter it from the lab panel."; return 1; }
    ok "Region 2 selected: $REGION2"
  fi

  create_mig "notus-1-mig" "$REGION2" || return 1

  info "Waiting for the instance groups to become stable..."
  gcloud compute instance-groups managed wait-until us-1-mig    --stable --region="$REGION1" --timeout=300 >/dev/null 2>&1
  gcloud compute instance-groups managed wait-until notus-1-mig --stable --region="$REGION2" --timeout=300 >/dev/null 2>&1
  ok "Instances are running in both regions"

  # ============================================================================
  # TASK 5 - GLOBAL EXTERNAL APPLICATION LOAD BALANCER
  # ============================================================================
  step "Task 5: Application Load Balancer (HTTP)"

  retry "Backend service http-backend" gcloud compute backend-services create http-backend \
    --global --protocol=HTTP --port-name=http \
    --health-checks=http-health-check \
    --load-balancing-scheme=EXTERNAL_MANAGED \
    --enable-logging --logging-sample-rate=1.0 || return 1

  attached() {
    gcloud compute backend-services describe http-backend --global \
      --format="value(backends[].group)" 2>/dev/null | tr ';' '\n' | grep -q "/$1\$"
  }

  if attached us-1-mig; then ok "Backend us-1-mig already attached"; else
    retry "Backend us-1-mig (Rate, 50 RPS per instance)" gcloud compute backend-services add-backend http-backend \
      --global --instance-group=us-1-mig --instance-group-region="$REGION1" \
      --balancing-mode=RATE --max-rate-per-instance=50 --capacity-scaler=1.0 || return 1
  fi

  if attached notus-1-mig; then ok "Backend notus-1-mig already attached"; else
    retry "Backend notus-1-mig (Utilization, 80%)" gcloud compute backend-services add-backend http-backend \
      --global --instance-group=notus-1-mig --instance-group-region="$REGION2" \
      --balancing-mode=UTILIZATION --max-utilization=0.8 --capacity-scaler=1.0 || return 1
  fi

  retry "URL map http-lb" gcloud compute url-maps create http-lb --default-service=http-backend || return 1
  retry "Target proxy http-lb-target-proxy" gcloud compute target-http-proxies create http-lb-target-proxy \
    --url-map=http-lb || return 1

  retry "Frontend IPv4 (port 80)" gcloud compute forwarding-rules create http-lb-forwarding-rule \
    --global --target-http-proxy=http-lb-target-proxy --ports=80 \
    --load-balancing-scheme=EXTERNAL_MANAGED --ip-version=IPV4 || return 1
  retry "Frontend IPv6 (port 80)" gcloud compute forwarding-rules create http-lb-forwarding-rule-2 \
    --global --target-http-proxy=http-lb-target-proxy --ports=80 \
    --load-balancing-scheme=EXTERNAL_MANAGED --ip-version=IPV6 || return 1

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
                   || fail "Not responding yet. Wait 2-3 minutes, then open http://$LB_IP"

  # ============================================================================
  # TASK 6 - STRESS TEST
  # ============================================================================
  step "Task 6: Stress test"

  # Candidate zones: other nearby regions first, then Region 1, then Region 2
  CANDS=""
  for r in $(echo "$ALL_REGIONS" | grep "^${CONT1}-" | grep -vx "$REGION1" | grep -vx "$REGION2"); do
    CANDS="$CANDS $(echo "$ALL_ZONES" | grep -m1 "^${r}-")"
  done
  CANDS="$CANDS $(echo "$ALL_ZONES" | grep "^${REGION1}-") $(echo "$ALL_ZONES" | grep "^${REGION2}-")"

  STRESS_ZONE=""; IAP=0

  # Attempt A: VM with an external IP
  for Z in $CANDS; do
    info "Trying zone $Z (external IP)"
    if OUT=$(gcloud compute instances create stress-test --zone="$Z" --machine-type=e2-micro --image=mywebserver 2>&1); then
      STRESS_ZONE="$Z"; break
    fi
    if gcloud compute instances describe stress-test --zone="$Z" >/dev/null 2>&1; then STRESS_ZONE="$Z"; break; fi
    if echo "$OUT" | grep -qiE 'vmExternalIpAccess'; then info "External IPs are blocked by policy."; break; fi
    echo "$OUT" | grep -qi 'resourceLocations' || echo "$OUT" | head -n 3 | cut -c1-200 | sed 's/^/           /'
  done

  # Attempt B: VM without an external IP in Region 1 (Cloud NAT is there), SSH through IAP
  if [ -z "$STRESS_ZONE" ]; then
    info "Falling back to a VM without an external IP in $REGION1"
    for Z in $(echo "$ALL_ZONES" | grep "^${REGION1}-"); do
      info "Trying zone $Z (no external IP)"
      if OUT=$(gcloud compute instances create stress-test --zone="$Z" --machine-type=e2-micro \
           --image=mywebserver --network-interface=subnet=default,no-address 2>&1); then
        STRESS_ZONE="$Z"; IAP=1; break
      fi
      echo "$OUT" | head -n 3 | cut -c1-200 | sed 's/^/           /'
    done
  fi

  [ -z "$STRESS_ZONE" ] && { fail "Could not create stress-test in any zone. Check the errors above."; return 1; }
  ok "stress-test VM is ready in $STRESS_ZONE"

  SSH=(--zone="$STRESS_ZONE" --quiet --strict-host-key-checking=no)
  [ "$IAP" = "1" ] && SSH+=(--tunnel-through-iap)

  info "Waiting for SSH..."
  sleep 30
  for i in 1 2 3 4 5 6; do
    gcloud compute ssh stress-test "${SSH[@]}" --command="echo ssh-ok" 2>/dev/null | grep -q ssh-ok && break
    info "SSH not ready yet ($i/6)"; sleep 15
  done

  info "Generating load for 4 minutes (traffic goes to the closest region, then spills over)..."
  gcloud compute ssh stress-test "${SSH[@]}" \
    --command="command -v ab >/dev/null || (sudo apt-get update -y && sudo apt-get install -y apache2-utils); ab -r -t 240 -n 500000 -c 1000 http://$LB_IP/ 2>&1 | tail -n 25"
  ok "Stress test finished"

  # ============================================================================
  # DONE
  # ============================================================================
  echo -e "\n${C}  ============================================================${N}"
  echo -e "${G}   LAB COMPLETE${N}"
  echo -e "${C}  ============================================================${N}"
  echo -e "${G}   Region 1 / Region 2 : $REGION1 / $REGION2${N}"
  echo -e "${G}   Load balancer IPv4  : $LB_IP${N}"
  echo -e "${G}   Load balancer IPv6  : ${LB_IPV6:-n/a}${N}"
  echo -e "${Y}   Open in browser     : http://$LB_IP${N}"
  echo -e "${Y}   Monitoring          : Network Services > Load balancing > http-lb > Monitoring${N}"
  echo -e "${C}   Now click 'Check my progress' on every task.${N}"
  echo -e "${C}   Thanks for watching - $BRAND${N}\n"
}

main
