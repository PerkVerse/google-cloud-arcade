#!/bin/bash
# =====================================================================
#  Configure an Application Load Balancer with Autoscaling
#  Full lab automation for Google Cloud Shell  (fast / parallel version)
#  Usage:  bash lab.sh
# =====================================================================

# ---------- Look & feel ----------
BOLD=$'\e[1m'; DIM=$'\e[2m'; RESET=$'\e[0m'
GREEN=$'\e[32m'; RED=$'\e[31m'; YELLOW=$'\e[33m'; CYAN=$'\e[36m'; BLUE=$'\e[34m'
LINE="${DIM}────────────────────────────────────────────────────────────${RESET}"

banner() {
  echo
  echo "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
  printf "${CYAN}${BOLD}║${RESET}  %-56s${CYAN}${BOLD}║${RESET}\n" "$1"
  [ -n "$2" ] && printf "${CYAN}${BOLD}║${RESET}  ${DIM}%-56s${RESET}${CYAN}${BOLD}║${RESET}\n" "$2"
  echo "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
}
step()  { echo; echo "${BLUE}${BOLD}▶ $1${RESET}"; echo "$LINE"; }
ok()    { echo "  ${GREEN}✔${RESET} $1"; }
info()  { echo "  ${CYAN}ℹ${RESET} $1"; }
warn()  { echo "  ${YELLOW}⚠${RESET} $1"; }
fail()  { echo "  ${RED}✘${RESET} $1"; }

# ---------- Settings ----------
PROJECT=$(gcloud config get-value project 2>/dev/null)
MAX_TRIES=15
SLEEP=5
LOGDIR=/tmp/labrun; rm -rf $LOGDIR; mkdir -p $LOGDIR

# ---------- Inputs ----------
banner "Application Load Balancer + Autoscaling Lab" "Fast automated setup for Cloud Shell"
echo
echo "${BOLD}Enter the values shown in your lab instructions:${RESET}"
read -r -p "  ${CYAN}Region${RESET} (e.g. us-west1)  : " R1 </dev/tty
R1=$(echo "$R1" | tr -d '[:space:]')
read -r -p "  ${CYAN}Zone${RESET}   (e.g. ${R1:-us-west1}-b) : " Z1 </dev/tty
Z1=$(echo "$Z1" | tr -d '[:space:]')
if [ -z "$R1" ] || [ -z "$Z1" ]; then fail "Region and Zone are required."; exit 1; fi

# Fixed by this lab's instructions
R2=europe-west4
MIG1=us-1-mig
MIG2=notus-1-mig

Z2=$(gcloud compute zones list --filter="region:($R1) AND status=UP AND name!=$Z1" --format="value(name)" 2>/dev/null | sort | head -1)
STRESS_ZONE=${Z2:-$Z1}

echo
echo "$LINE"
printf "  %-18s %s\n" "Project"          "${BOLD}$PROJECT${RESET}"
printf "  %-18s %s\n" "Region / Zone"    "${BOLD}$R1 / $Z1${RESET}"
printf "  %-18s %s\n" "Second region"    "${BOLD}$R2${RESET}"
printf "  %-18s %s\n" "Instance groups"  "${BOLD}$MIG1, $MIG2${RESET}"
printf "  %-18s %s\n" "Stress-test zone" "${BOLD}$STRESS_ZONE${RESET}"
echo "$LINE"

gcloud config set compute/region "$R1" >/dev/null 2>&1
gcloud config set compute/zone "$Z1" >/dev/null 2>&1

# ---------- Retry helper: retry "description" command... ----------
retry() {
  local desc="$1"; shift
  local n=1 out rc err
  while true; do
    out=$("$@" 2>&1); rc=$?
    if [ $rc -eq 0 ]; then ok "$desc"; return 0; fi
    if echo "$out" | grep -qi "already exists"; then
      ok "$desc ${DIM}(already exists)${RESET}"; return 0
    fi
    err=$(echo "$out" | grep -iE "error|denied|invalid|not found|quota|unrecognized" | tail -1 | cut -c1-150)
    # Clearly permanent mistakes: stop early instead of wasting time
    if [ $n -ge 3 ] && echo "$out" | grep -qiE "unrecognized arguments|invalid choice|Invalid value for|PERMISSION_DENIED"; then
      fail "$desc ${DIM}— permanent error, not retrying${RESET}"
      echo "    ${DIM}${err:-$out}${RESET}"; return 1
    fi
    if [ $n -ge $MAX_TRIES ]; then
      fail "$desc ${DIM}— gave up after $MAX_TRIES attempts${RESET}"
      echo "    ${DIM}${err:-$out}${RESET}"; return 1
    fi
    warn "$desc ${DIM}— attempt $n/$MAX_TRIES failed, retrying in ${SLEEP}s${RESET}"
    [ -n "$err" ] && echo "    ${DIM}$err${RESET}"
    n=$((n+1)); sleep $SLEEP
  done
}

# ---------- Parallel helpers ----------
NAMES=()
prun() {  # prun name command...   (runs in background, output saved to a log)
  local name="$1"; shift
  NAMES+=("$name")
  ( "$@" ) > "$LOGDIR/$name.log" 2>&1 &
}
pwait() {  # waits for all background jobs, shows a live timer, then prints their logs in order
  local start=$SECONDS
  while [ -n "$(jobs -rp)" ]; do
    printf "\r  ${DIM}⏳ running in parallel... %ss${RESET}" $((SECONDS-start))
    sleep 1
  done
  wait
  printf "\r%60s\r" ""
  for n in "${NAMES[@]}"; do cat "$LOGDIR/$n.log"; done
  NAMES=()
}

step "Preparing project"
retry "Enable Compute Engine API" gcloud services enable compute.googleapis.com

# =====================================================================
#  PHASE 1 — Tasks 1, 2, 3 (all run together)
# =====================================================================
cat > /tmp/web-startup.sh <<'EOF'
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive
for i in $(seq 1 40); do
  apt-get update && apt-get install -y apache2 && break
  sleep 5
done
systemctl enable apache2
systemctl start apache2
if dpkg -s apache2 >/dev/null 2>&1 && systemctl is-active --quiet apache2; then
  echo "WEBSERVER-SETUP-DONE"
fi
EOF

task1_firewall() {
  echo "${BOLD}Task 1 · Health check firewall rule${RESET}"
  retry "Create firewall rule fw-allow-health-checks" \
    gcloud compute firewall-rules create fw-allow-health-checks \
    --network=default --direction=INGRESS --action=allow --rules=tcp:80 \
    --source-ranges=130.211.0.0/22,35.191.0.0/16 \
    --target-tags=allow-health-checks
  retry "Create health check 'http-health-check'" \
    gcloud compute health-checks create http http-health-check --port=80
}

task2_nat() {
  echo "${BOLD}Task 2 · Cloud Router and Cloud NAT${RESET}"
  retry "Create Cloud Router nat-router-us1" \
    gcloud compute routers create nat-router-us1 --network=default --region=$R1
  retry "Create NAT gateway nat-config" \
    gcloud compute routers nats create nat-config \
    --router=nat-router-us1 --region=$R1 \
    --auto-allocate-nat-external-ips --nat-all-subnet-ip-ranges
}

setup_webserver() {
  gcloud compute instances delete webserver --zone=$Z1 --quiet >/dev/null 2>&1
  gcloud compute disks delete webserver --zone=$Z1 --quiet >/dev/null 2>&1
  retry "Create VM 'webserver' (no external IP, keep boot disk)" \
    gcloud compute instances create webserver \
    --zone=$Z1 --machine-type=e2-medium \
    --image-family=debian-12 --image-project=debian-cloud \
    --tags=allow-health-checks --no-address --network=default \
    --no-boot-disk-auto-delete \
    --metadata-from-file=startup-script=/tmp/web-startup.sh || return 1
  for i in $(seq 1 120); do      # up to ~10 minutes, checks every 5s
    if gcloud compute instances get-serial-port-output webserver --zone=$Z1 2>/dev/null | grep -q "WEBSERVER-SETUP-DONE"; then
      ok "Apache installed and set to start on boot"
      return 0
    fi
    sleep 5
  done
  return 1
}

task3_image() {
  echo "${BOLD}Task 3 · Custom web server image${RESET}"
  for attempt in 1 2 3; do
    [ $attempt -gt 1 ] && warn "Web server setup failed, starting attempt $attempt/3"
    if setup_webserver; then break; fi
  done
  retry "Delete VM 'webserver' (disk is kept)" \
    gcloud compute instances delete webserver --zone=$Z1 --quiet
  retry "Create custom image 'mywebserver'" \
    gcloud compute images create mywebserver \
    --source-disk=webserver --source-disk-zone=$Z1
}

step "Tasks 1–3 · Firewall, NAT and custom image (running together)"
prun t1 task1_firewall
prun t2 task2_nat
prun t3 task3_image
pwait

# =====================================================================
#  PHASE 2 — Task 4
# =====================================================================
step "Task 4 · Instance template and managed instance groups"
retry "Create instance template 'mywebserver-template'" \
  gcloud compute instance-templates create mywebserver-template \
  --machine-type=e2-micro --image=mywebserver --image-project=$PROJECT \
  --tags=allow-health-checks --no-address --network=default

build_mig() {  # build_mig NAME REGION
  local name=$1 region=$2
  echo "${BOLD}Instance group '$name' ($region)${RESET}"
  retry "Create instance group '$name'" \
    gcloud compute instance-groups managed create $name \
    --template=mywebserver-template --size=1 --region=$region \
    --health-check=http-health-check --initial-delay=60
  retry "Set autoscaling (1–2 instances, 80% target)" \
    gcloud compute instance-groups managed set-autoscaling $name \
    --region=$region --min-num-replicas=1 --max-num-replicas=2 \
    --target-load-balancing-utilization=0.8 --cool-down-period=60
  retry "Set named port http:80" \
    gcloud compute instance-groups managed set-named-ports $name \
    --named-ports=http:80 --region=$region
}
prun m1 build_mig $MIG1 $R1
prun m2 build_mig $MIG2 $R2
pwait

# =====================================================================
#  PHASE 3 — Task 5
# =====================================================================
step "Task 5 · Application Load Balancer (HTTP)"
retry "Create backend service 'http-backend' (logging 100%)" \
  gcloud compute backend-services create http-backend \
  --protocol=HTTP --port-name=http --health-checks=http-health-check \
  --global --enable-logging --logging-sample-rate=1

retry "Add backend '$MIG1' (Rate, 50 RPS)" \
  gcloud compute backend-services add-backend http-backend --global \
  --instance-group=$MIG1 --instance-group-region=$R1 \
  --balancing-mode=RATE --max-rate-per-instance=50 --capacity-scaler=1.0

retry "Add backend '$MIG2' (Utilization, 80%)" \
  gcloud compute backend-services add-backend http-backend --global \
  --instance-group=$MIG2 --instance-group-region=$R2 \
  --balancing-mode=UTILIZATION --max-utilization=0.8 --capacity-scaler=1.0

retry "Create URL map 'http-lb'" \
  gcloud compute url-maps create http-lb --default-service=http-backend
retry "Create target HTTP proxy" \
  gcloud compute target-http-proxies create http-lb-target-proxy --url-map=http-lb

prun f4 retry "Create IPv4 frontend (port 80)" \
  gcloud compute forwarding-rules create http-lb-forwarding-rule \
  --global --target-http-proxy=http-lb-target-proxy --ports=80 --ip-version=IPV4
prun f6 retry "Create IPv6 frontend (port 80)" \
  gcloud compute forwarding-rules create http-lb-forwarding-rule-2 \
  --global --target-http-proxy=http-lb-target-proxy --ports=80 --ip-version=IPV6
pwait

LB_IP=$(gcloud compute forwarding-rules describe http-lb-forwarding-rule --global --format="value(IPAddress)")
LB_IPV6=$(gcloud compute forwarding-rules describe http-lb-forwarding-rule-2 --global --format="value(IPAddress)")
ok "Load balancer IPv4: ${BOLD}$LB_IP${RESET}"
ok "Load balancer IPv6: ${BOLD}$LB_IPV6${RESET}"

# =====================================================================
#  PHASE 4 — Task 6 (stress VM waits for the LB by itself)
# =====================================================================
step "Task 6 · Stress test"
cat > /tmp/stress-startup.sh <<'EOF'
#!/bin/bash
ulimit -n 65535
for i in $(seq 1 180); do
  curl -m2 -s http://LB_IP_PLACEHOLDER/ | grep -q Apache && break
  sleep 5
done
nohup bash -c 'ab -n 500000 -c 1000 http://LB_IP_PLACEHOLDER/ ; ab -n 500000 -c 1000 http://LB_IP_PLACEHOLDER/' > /tmp/ab.log 2>&1 &
EOF
sed -i "s/LB_IP_PLACEHOLDER/$LB_IP/g" /tmp/stress-startup.sh

prun s1 retry "Create VM 'stress-test' ($STRESS_ZONE) — load starts when the LB is ready" \
  gcloud compute instances create stress-test \
  --zone=$STRESS_ZONE --machine-type=e2-micro \
  --image=mywebserver --image-project=$PROJECT \
  --metadata-from-file=startup-script=/tmp/stress-startup.sh

info "Checking that the load balancer is serving traffic"
READY=0
for i in $(seq 1 60); do
  if curl -m2 -s http://$LB_IP | grep -q Apache; then READY=1; break; fi
  printf "\r  ${DIM}⏳ waiting for load balancer... %ss${RESET}" $((i*5))
  sleep 5
done
printf "\r%60s\r" ""
if [ $READY -eq 1 ]; then ok "Load balancer is serving traffic"; else warn "Load balancer is still warming up — give it a few more minutes"; fi
pwait

# =====================================================================
MINS=$((SECONDS/60)); SECS=$((SECONDS%60))
FAILS=$(cat $LOGDIR/*.log 2>/dev/null | grep -c "✘")
if [ "$FAILS" -eq 0 ]; then
  banner "All done in ${MINS}m ${SECS}s" "Everything has been configured"
else
  banner "Finished in ${MINS}m ${SECS}s with $FAILS issue(s)" "Check the ✘ lines above, then re-run: bash lab.sh"
fi
echo
printf "  %-14s %s\n" "IPv4 URL"  "${BOLD}http://$LB_IP${RESET}"
printf "  %-14s %s\n" "IPv6"      "${BOLD}$LB_IPV6${RESET}"
echo
echo "${BOLD}Next steps${RESET}"
echo "  1. Console → Network services → Load balancing → http-lb → Monitoring"
echo "     and watch traffic spread across both backends."
echo "  2. Click ${BOLD}Check my progress${RESET} for every task in the lab."
echo "  3. Quiz answer: closest region gets the traffic → ${BOLD}True${RESET}"
echo
