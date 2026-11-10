#!/bin/bash
# =====================================================================
#  PERKVERSE | GSP539 - Build Global and Regional Load Balancing
#  Solutions: Challenge Lab  (one-paste script, safe to re-run)
#  - Auto-detects Project ID, Region A, Region B, zones, subnet
#  - Auto-retries failed commands and skips "already exists" errors
# =====================================================================

export CLOUDSDK_CORE_DISABLE_PROMPTS=1
set -o pipefail

# ---------- pretty output ----------
G='\033[1;32m'; R='\033[1;31m'; Y='\033[1;33m'; C='\033[1;36m'; W='\033[1;37m'; N='\033[0m'
banner() {
  echo -e "${C}"
  echo "  ╔══════════════════════════════════════════════════════════╗"
  echo "  ║                     P E R K V E R S E                    ║"
  echo "  ║        GSP539 - Global & Regional Load Balancing         ║"
  echo "  ╚══════════════════════════════════════════════════════════╝"
  echo -e "${N}"
}
step() { echo -e "\n${C}━━ $* ${N}"; }
ok()   { echo -e "  ${G}✔ $*${N}"; }
warn() { echo -e "  ${Y}⚠ $*${N}"; }
bad()  { echo -e "  ${R}✘ $*${N}"; }
info() { echo -e "  ${W}• $*${N}"; }

# ---------- smart runner: retry + skip "already exists" ----------
run() {
  local desc="$1"; shift
  local out try
  for try in 1 2 3 4 5; do
    if out=$("$@" 2>&1); then ok "$desc"; return 0; fi
    if grep -qiE "already exists|alreadyExists" <<<"$out"; then
      ok "$desc (already exists - skipped)"; return 0
    fi
    warn "$desc - attempt $try/5 failed, retrying..."
    echo "$out" | grep -iE "error|ERROR" | tail -2 | sed 's/^/      /'
    sleep $((try * 5))
  done
  bad "$desc - could not complete (see error above)"
  return 1
}

# =====================================================================
banner
step "Detecting project, regions and zones"
# =====================================================================
PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
[ -z "$PROJECT_ID" ] && PROJECT_ID=$(gcloud projects list --format="value(projectId)" --limit=1)
gcloud config set project "$PROJECT_ID" >/dev/null 2>&1

if gcloud services list --enabled --format="value(config.name)" 2>/dev/null | grep -q "^compute.googleapis.com$"; then
  ok "Compute Engine API already enabled"
else
  gcloud services enable compute.googleapis.com >/dev/null 2>&1 && ok "Compute Engine API enabled" || warn "Skipping API enable (not permitted in this lab)"
fi

NETWORK="lb-network"

# Region B + subnet come from template-proxy-internal
TPL_P="template-proxy-internal"
TPL_A="template-alb-api"
REGION_B="${REGION_B:-$(gcloud compute instance-templates list --filter="name=$TPL_P" --format='value(region.basename())' 2>/dev/null | head -1)}"
SUBNET_URL=$(gcloud compute instance-templates list --filter="name=$TPL_P" --format='value(properties.networkInterfaces[0].subnetwork)' 2>/dev/null | head -1)
[ -z "$REGION_B" ] && REGION_B=$(sed -n 's#.*/regions/\([^/]*\)/.*#\1#p' <<<"$SUBNET_URL")
SUBNET_B="${SUBNET_URL##*/}"

# Region A = the other region that has a subnet in lb-network
if [ -z "$REGION_A" ]; then
  REGION_A=$(gcloud compute networks subnets list --network="$NETWORK" --filter="purpose=PRIVATE" \
    --format='value(region.basename())' 2>/dev/null | sort -u | grep -v "^${REGION_B}$" | head -1)
fi
[ -z "$REGION_A" ] && REGION_A=$(gcloud config get-value compute/region 2>/dev/null)
[ -z "$REGION_B" ] && REGION_B=$(gcloud compute networks subnets list --network="$NETWORK" --filter="purpose=PRIVATE" \
    --format='value(region.basename())' 2>/dev/null | sort -u | tail -1)

if [ -z "$SUBNET_B" ]; then
  SUBNET_B=$(gcloud compute networks subnets list --network="$NETWORK" --regions="$REGION_B" \
    --filter="purpose=PRIVATE" --format='value(name)' 2>/dev/null | head -1)
fi

ZONE_A=$(gcloud compute zones list --filter="region:$REGION_A AND status=UP" --format='value(name)' | head -1)
ZONE_B=$(gcloud compute zones list --filter="region:$REGION_B AND status=UP" --format='value(name)' | head -1)

echo
info "Project ID : $PROJECT_ID"
info "Region A   : $REGION_A  (zone $ZONE_A)"
info "Region B   : $REGION_B  (zone $ZONE_B)"
info "Subnet (B) : $SUBNET_B"
if [ -z "$REGION_A" ] || [ -z "$REGION_B" ] || [ -z "$SUBNET_B" ]; then
  bad "Could not detect everything. Set them manually and run again, e.g.:"
  echo "     export REGION_A=us-east1 REGION_B=us-west1"
  return 1 2>/dev/null || exit 1
fi
warn "Check Region A / B above match your lab panel. Starting in 5 seconds..."
sleep 5

# template helper: global template -> name, regional template -> full URI
tpl_uri() {
  if gcloud compute instance-templates describe "$1" --global --format='value(name)' >/dev/null 2>&1; then
    echo "$1"
  else
    echo "projects/$PROJECT_ID/regions/$2/instanceTemplates/$1"
  fi
}

# =====================================================================
step "TASK 1 | Regional Internal Proxy NLB (Region B)"
# =====================================================================

# --- proxy-only subnet (required for internal proxy NLB) ---
PROXY_SUBNET=$(gcloud compute networks subnets list --network="$NETWORK" --regions="$REGION_B" \
  --filter="purpose=REGIONAL_MANAGED_PROXY" --format='value(name)' 2>/dev/null | head -1)
if [ -z "$PROXY_SUBNET" ]; then
  run "Create proxy-only subnet 10.129.0.0/23" gcloud compute networks subnets create proxy-only-subnet-b \
    --network="$NETWORK" --region="$REGION_B" --range=10.129.0.0/23 \
    --purpose=REGIONAL_MANAGED_PROXY --role=ACTIVE
else
  ok "Proxy-only subnet already present ($PROXY_SUBNET)"
fi

# --- MIG ---
TPL_P_URI=$(tpl_uri "$TPL_P" "$REGION_B")
run "Create regional MIG mig-proxy-internal" gcloud compute instance-groups managed create mig-proxy-internal \
  --region="$REGION_B" --template="$TPL_P_URI" --size=2
run "Set named port tcp80:80" gcloud compute instance-groups managed set-named-ports mig-proxy-internal \
  --region="$REGION_B" --named-ports=tcp80:80

# --- firewall rules ---
run "Firewall: health checks (TCP 80)" gcloud compute firewall-rules create fw-allow-health-check-proxy-internal \
  --network="$NETWORK" --direction=INGRESS --action=ALLOW --rules=tcp:80 \
  --source-ranges=130.211.0.0/22,35.191.0.0/16 --target-tags=tag-proxy-internal
run "Firewall: proxy-only subnet 10.129.0.0/23 (TCP 80)" gcloud compute firewall-rules create fw-allow-proxy-only-internal \
  --network="$NETWORK" --direction=INGRESS --action=ALLOW --rules=tcp:80 \
  --source-ranges=10.129.0.0/23 --target-tags=tag-proxy-internal

# --- internal proxy load balancer ---
run "Regional health check" gcloud compute health-checks create tcp hc-proxy-internal \
  --region="$REGION_B" --port=80
run "Backend service" gcloud compute backend-services create service-proxy-internal \
  --load-balancing-scheme=INTERNAL_MANAGED --protocol=TCP --port-name=tcp80 \
  --region="$REGION_B" --health-checks=hc-proxy-internal --health-checks-region="$REGION_B"
if gcloud compute backend-services describe service-proxy-internal --region="$REGION_B" \
     --format="value(backends[].group)" 2>/dev/null | grep -q "mig-proxy-internal"; then
  ok "MIG already attached to backend service"
else
  run "Add MIG to backend service" gcloud compute backend-services add-backend service-proxy-internal \
    --region="$REGION_B" --instance-group=mig-proxy-internal --instance-group-region="$REGION_B" \
    --balancing-mode=UTILIZATION --max-utilization=0.8 \
  || run "Add MIG to backend service (CONNECTION mode)" gcloud compute backend-services add-backend service-proxy-internal \
    --region="$REGION_B" --instance-group=mig-proxy-internal --instance-group-region="$REGION_B" \
    --balancing-mode=CONNECTION --max-connections-per-instance=100
fi
run "Target TCP proxy" gcloud compute target-tcp-proxies create target-proxy-internal \
  --backend-service=service-proxy-internal --region="$REGION_B"
run "Reserve static internal IP ip-internal-proxy" gcloud compute addresses create ip-internal-proxy \
  --region="$REGION_B" --subnet="$SUBNET_B" --purpose=SHARED_LOADBALANCER_VIP
run "Forwarding rule rule-internal-proxy (TCP 110)" gcloud compute forwarding-rules create rule-internal-proxy \
  --load-balancing-scheme=INTERNAL_MANAGED --network="$NETWORK" --subnet="$SUBNET_B" \
  --address=ip-internal-proxy --ports=110 --region="$REGION_B" \
  --target-tcp-proxy=target-proxy-internal --target-tcp-proxy-region="$REGION_B"

# --- client VM + validation ---
run "Create client VM vm-client-internal" gcloud compute instances create vm-client-internal \
  --zone="$ZONE_B" --network="$NETWORK" --subnet="$SUBNET_B" --tags=allow-ssh \
  --machine-type=e2-micro

INTERNAL_IP=$(gcloud compute addresses describe ip-internal-proxy --region="$REGION_B" --format='value(address)')
info "Internal LB IP: $INTERNAL_IP"
info "Waiting for backends and VM to get ready (this can take 1-3 minutes)..."
gcloud compute instance-groups managed wait-until mig-proxy-internal --stable --region="$REGION_B" --timeout=300 >/dev/null 2>&1

for try in 1 2 3 4 5 6 7 8; do
  CODE=$(gcloud compute ssh vm-client-internal --zone="$ZONE_B" --quiet \
    --strict-host-key-checking=no --command="curl -s -m 10 -o /dev/null -w '%{http_code}' http://$INTERNAL_IP:110" 2>/dev/null | tail -1)
  if [ "$CODE" = "200" ]; then ok "Internal LB reachable on $INTERNAL_IP:110 (HTTP 200)"; break; fi
  # fallback through IAP if direct SSH is blocked
  CODE=$(gcloud compute ssh vm-client-internal --zone="$ZONE_B" --quiet --tunnel-through-iap \
    --strict-host-key-checking=no --command="curl -s -m 10 -o /dev/null -w '%{http_code}' http://$INTERNAL_IP:110" 2>/dev/null | tail -1)
  if [ "$CODE" = "200" ]; then ok "Internal LB reachable on $INTERNAL_IP:110 (HTTP 200)"; break; fi
  warn "Not ready yet (attempt $try/8) - waiting 20s..."
  sleep 20
done

# =====================================================================
step "TASK 2 | Global External Application Load Balancer"
# =====================================================================
TPL_A_URI_A=$(tpl_uri "$TPL_A" "$REGION_A")
TPL_A_URI_B=$(tpl_uri "$TPL_A" "$REGION_B")

run "Create MIG mig-alb-api-a (Region A)" gcloud compute instance-groups managed create mig-alb-api-a \
  --region="$REGION_A" --template="$TPL_A_URI_A" --size=2
run "Set named port http80:80 (A)" gcloud compute instance-groups managed set-named-ports mig-alb-api-a \
  --region="$REGION_A" --named-ports=http80:80
run "Create MIG mig-alb-api-b (Region B)" gcloud compute instance-groups managed create mig-alb-api-b \
  --region="$REGION_B" --template="$TPL_A_URI_B" --size=2
run "Set named port http80:80 (B)" gcloud compute instance-groups managed set-named-ports mig-alb-api-b \
  --region="$REGION_B" --named-ports=http80:80

# --- health check, backend service ---
run "Global HTTP health check http-check-alb" gcloud compute health-checks create http http-check-alb \
  --global --port=80
run "Global backend service service-alb-global" gcloud compute backend-services create service-alb-global \
  --global --load-balancing-scheme=EXTERNAL_MANAGED --protocol=HTTP --port-name=http80 \
  --health-checks=http-check-alb --global-health-checks
# --- attach both MIGs to the global backend service (gcloud first, REST API fallback) ---
GA="https://www.googleapis.com/compute/v1/projects/$PROJECT_ID/regions/$REGION_A/instanceGroups/mig-alb-api-a"
GB="https://www.googleapis.com/compute/v1/projects/$PROJECT_ID/regions/$REGION_B/instanceGroups/mig-alb-api-b"
both_attached() {
  local a; a=$(gcloud compute backend-services describe service-alb-global --global --format="value(backends[].group)" 2>/dev/null)
  grep -q "mig-alb-api-a" <<<"$a" && grep -q "mig-alb-api-b" <<<"$a"
}
if both_attached; then
  ok "Both MIGs already attached to service-alb-global"
else
  for X in "mig-alb-api-a:$REGION_A" "mig-alb-api-b:$REGION_B"; do
    gcloud compute backend-services add-backend service-alb-global --global \
      --instance-group="${X%%:*}" --instance-group-region="${X##*:}" \
      --balancing-mode=RATE --max-rate=1 >/dev/null 2>&1
  done
  if ! both_attached; then
    warn "gcloud add-backend failed - using REST API fallback..."
    curl -s -X PATCH -H "Authorization: Bearer $(gcloud auth print-access-token)" \
      -H "Content-Type: application/json" \
      "https://compute.googleapis.com/compute/v1/projects/$PROJECT_ID/global/backendServices/service-alb-global" \
      -d "{\"backends\":[{\"group\":\"$GA\",\"balancingMode\":\"RATE\",\"maxRate\":1},{\"group\":\"$GB\",\"balancingMode\":\"RATE\",\"maxRate\":1}]}" \
      | grep -iE '"message"|"status"'
    sleep 10
  fi
  both_attached && ok "Both MIGs attached (Rate, max 1 RPS)" || bad "MIG attach failed - paste the error here"
fi

# --- self-signed certificate ---
CERT_DIR=$(mktemp -d); cd "$CERT_DIR" || exit 1
openssl genrsa -out key.pem 2048 >/dev/null 2>&1
openssl req -new -x509 -key key.pem -out cert.pem -days 1 -subj "/CN=example.com" >/dev/null 2>&1
run "SSL certificate cert-self-signed" gcloud compute ssl-certificates create cert-self-signed \
  --certificate=cert.pem --private-key=key.pem --global
cd ~ || true

# --- frontend ---
run "Reserve global IP ip-alb-global" gcloud compute addresses create ip-alb-global --global --ip-version=IPV4
run "URL map" gcloud compute url-maps create urlmap-alb-global --default-service=service-alb-global
run "Target HTTPS proxy" gcloud compute target-https-proxies create proxy-alb-https \
  --url-map=urlmap-alb-global --ssl-certificates=cert-self-signed
run "HTTPS forwarding rule (port 443)" gcloud compute forwarding-rules create rule-alb-https \
  --global --load-balancing-scheme=EXTERNAL_MANAGED --network-tier=PREMIUM \
  --address=ip-alb-global --target-https-proxy=proxy-alb-https --ports=443

# --- firewall ---
run "Firewall fw-allow-health-check-and-proxy" gcloud compute firewall-rules create fw-allow-health-check-and-proxy \
  --network="$NETWORK" --direction=INGRESS --action=ALLOW --rules=tcp:80 \
  --source-ranges=130.211.0.0/22,35.191.0.0/16

# =====================================================================
step "TASK 3 | Failover and global distribution test"
# =====================================================================
alb_a_vms() {
  gcloud compute instance-groups managed list-instances mig-alb-api-a --region="$REGION_A" --format='value(instance)' 2>/dev/null | \
  while read -r URL; do
    [ -z "$URL" ] && continue
    echo "${URL##*/} $(sed -n 's#.*/zones/\([^/]*\)/.*#\1#p' <<<"$URL")"
  done
}
LB_IP=$(gcloud compute addresses describe ip-alb-global --global --format='value(address)')
info "Global LB IP: $LB_IP"
info "Waiting for the load balancer to start serving (can take 3-7 minutes)..."
for try in $(seq 1 40); do
  if curl -k -s -m 5 "https://$LB_IP" | grep -q "Hello from"; then ok "Load balancer is serving traffic"; break; fi
  echo -ne "  ...waiting ($try/40)\r"; sleep 15
done

echo; info "Traffic distribution (should alternate between Region A and B):"
for i in $(seq 1 16); do curl -k -s -m 5 "https://$LB_IP" | grep "Hello from"; sleep 0.5; done

# --- simulate failure: stop nginx on every VM in mig-alb-api-a ---
echo
info "Simulating failure: stopping nginx in mig-alb-api-a"
alb_a_vms | \
while read -r VM VZ; do
  [ -z "$VM" ] && continue
  for try in 1 2 3; do
    if gcloud compute ssh "$VM" --zone="$VZ" --quiet --strict-host-key-checking=no \
         --command="sudo systemctl stop nginx" >/dev/null 2>&1 || \
       gcloud compute ssh "$VM" --zone="$VZ" --quiet --tunnel-through-iap --strict-host-key-checking=no \
         --command="sudo systemctl stop nginx" >/dev/null 2>&1; then
      ok "nginx stopped on $VM"; break
    fi
    warn "SSH to $VM failed (attempt $try/3), retrying..."; sleep 10
  done
done

info "Waiting for health checks to mark Region A UNHEALTHY (about 60s)..."
sleep 60
info "Traffic during failure (only Region B should respond):"
for i in $(seq 1 12); do curl -k -s -m 5 "https://$LB_IP" | grep "Hello from"; sleep 0.5; done

echo -e "\n${Y}  ► Now click 'Check my progress' for Task 3 in the lab page.${N}"
echo -e "${Y}    The script restores nginx when you press ENTER (or automatically after 90s).${N}"
read -t 90 -r _ </dev/tty 2>/dev/null || sleep 5

# --- restore ---
info "Restoring backend: starting nginx"
alb_a_vms | \
while read -r VM VZ; do
  [ -z "$VM" ] && continue
  for try in 1 2 3; do
    if gcloud compute ssh "$VM" --zone="$VZ" --quiet --strict-host-key-checking=no \
         --command="sudo systemctl start nginx" >/dev/null 2>&1 || \
       gcloud compute ssh "$VM" --zone="$VZ" --quiet --tunnel-through-iap --strict-host-key-checking=no \
         --command="sudo systemctl start nginx" >/dev/null 2>&1; then
      ok "nginx started on $VM"; break
    fi
    warn "SSH to $VM failed (attempt $try/3), retrying..."; sleep 10
  done
done

info "Waiting for Region A to become HEALTHY again..."
sleep 45
for i in $(seq 1 10); do curl -k -s -m 5 "https://$LB_IP" | grep "Hello from"; sleep 0.5; done

echo -e "\n${G}  ╔══════════════════════════════════════════════════════════╗"
echo -e "  ║   ALL TASKS DONE - now click 'Check my progress' ✔       ║"
echo -e "  ║                  Subscribe to PERKVERSE                  ║"
echo -e "  ╚══════════════════════════════════════════════════════════╝${N}"
