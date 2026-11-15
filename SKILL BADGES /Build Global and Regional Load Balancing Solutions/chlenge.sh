#!/bin/bash
# =====================================================================
#  PERKVERSE | GSP539 - Build Global and Regional Load Balancing
#  Solutions: Challenge Lab  (FINAL - safe to re-run)
#  - Asks you for Region A / Region B / Network (auto-detected defaults,
#    just press ENTER to accept)
#  - Auto-retries errors, skips "already exists" and permission noise
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

# ---------- smart runner ----------
run() {
  local desc="$1"; shift
  local out try
  for try in 1 2 3 4 5; do
    if out=$("$@" 2>&1); then ok "$desc"; return 0; fi
    if grep -qiE "already exists|alreadyExists" <<<"$out"; then
      ok "$desc (already exists - skipped)"; return 0
    fi
    if grep -qiE "PERMISSION_DENIED|does not have permission" <<<"$out"; then
      warn "$desc - skipped (permission not needed in this lab)"; return 0
    fi
    warn "$desc - attempt $try/5 failed, retrying..."
    echo "$out" | grep -v '^\s*$' | tail -5 | sed 's/^/      /'
    sleep $((try * 5))
  done
  bad "$desc - could not complete (see error above)"
  return 1
}

# ---------- ask with default ----------
ask() { # var "question" default
  local v=""
  if [ -n "${!1}" ]; then return 0; fi
  read -r -p "  $2 [$3]: " v </dev/tty 2>/dev/null
  printf -v "$1" '%s' "${v:-$3}"
}

banner
# =====================================================================
step "Detecting project and defaults"
# =====================================================================
PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
[ -z "$PROJECT_ID" ] && PROJECT_ID=$(gcloud projects list --format="value(projectId)" --limit=1)
gcloud config set project "$PROJECT_ID" >/dev/null 2>&1

if gcloud services list --enabled --format="value(config.name)" 2>/dev/null | grep -q "^compute.googleapis.com$"; then
  ok "Compute Engine API already enabled"
else
  gcloud services enable compute.googleapis.com >/dev/null 2>&1 && ok "Compute Engine API enabled" \
    || warn "Skipping API enable (not permitted in this lab)"
fi

# ---- settings that can change from lab to lab (edit here if needed) ----
TPL_P="template-proxy-internal"
TPL_A="template-alb-api"
PROXY_CIDR="10.129.0.0/23"

NETWORK_DEF="${NETWORK:-lb-network}"
D_B=$(gcloud compute instance-templates list --filter="name=$TPL_P" --format='value(region.basename())' 2>/dev/null | head -1)
SUBNET_URL=$(gcloud compute instance-templates list --filter="name=$TPL_P" --format='value(properties.networkInterfaces[0].subnetwork)' 2>/dev/null | head -1)
[ -z "$D_B" ] && D_B=$(sed -n 's#.*/regions/\([^/]*\)/.*#\1#p' <<<"$SUBNET_URL")
[ -z "$D_B" ] && D_B=$(gcloud compute networks subnets list --network="$NETWORK_DEF" --filter="purpose=PRIVATE" --format='value(region.basename())' 2>/dev/null | sort -u | tail -1)
D_A=$(gcloud compute networks subnets list --network="$NETWORK_DEF" --filter="purpose=PRIVATE" --format='value(region.basename())' 2>/dev/null | sort -u | grep -v "^${D_B}$" | head -1)
[ -z "$D_A" ] && D_A=$(gcloud config get-value compute/region 2>/dev/null)

echo
echo -e "  ${Y}Open your lab panel and type the values below (both regions are required)${N}"
[ -n "$D_A" ] && info "Hint - Region A looks like: $D_A"
[ -n "$D_B" ] && info "Hint - Region B looks like: $D_B"
[ -n "$D_B" ] && info "Both Region A and B in Lab Setup"
echo

while true; do
  read -r -p "  Enter Region A (example us-east4): " REGION_A </dev/tty
  REGION_A=$(echo "$REGION_A" | tr -d ' ')
  [ -n "$REGION_A" ] && gcloud compute regions describe "$REGION_A" >/dev/null 2>&1 && break
  bad "Invalid region. Type it exactly as shown in the lab (example: us-east4)."
done
while true; do
  read -r -p "  Enter Region B (example us-central1): " REGION_B </dev/tty
  REGION_B=$(echo "$REGION_B" | tr -d ' ')
  [ -n "$REGION_B" ] && gcloud compute regions describe "$REGION_B" >/dev/null 2>&1 && break
  bad "Invalid region. Type it exactly as shown in the lab (example: us-central1)."
done

# network: use lb-network automatically, ask only if it does not exist
NETWORK="$NETWORK_DEF"
until gcloud compute networks describe "$NETWORK" >/dev/null 2>&1; do
  warn "Network '$NETWORK' not found. Available networks:"
  gcloud compute networks list --format="value(name)" | sed 's/^/      /'
  read -r -p "  Enter VPC network name: " NETWORK </dev/tty
done

SUBNET_B=$(gcloud compute networks subnets list --network="$NETWORK" --regions="$REGION_B" \
  --filter="purpose=PRIVATE" --format='value(name)' 2>/dev/null | head -1)
[ -z "$SUBNET_B" ] && SUBNET_B="${SUBNET_URL##*/}"
ZONE_A=$(gcloud compute zones list --filter="region:$REGION_A AND status=UP" --format='value(name)' | head -1)
ZONE_B=$(gcloud compute zones list --filter="region:$REGION_B AND status=UP" --format='value(name)' | head -1)

echo
info "Project ID : $PROJECT_ID"
info "Network    : $NETWORK"
info "Region A   : $REGION_A  (zone $ZONE_A)"
info "Region B   : $REGION_B  (zone $ZONE_B)"
info "Subnet (B) : $SUBNET_B"
if [ -z "$SUBNET_B" ] || [ -z "$ZONE_A" ] || [ -z "$ZONE_B" ]; then
  bad "Could not detect subnet/zones. Check the region names and run again."
  return 1 2>/dev/null || exit 1
fi
sleep 3

tpl_uri() { # template region
  if gcloud compute instance-templates describe "$1" --global --format='value(name)' >/dev/null 2>&1; then
    echo "$1"
  else
    echo "projects/$PROJECT_ID/regions/$2/instanceTemplates/$1"
  fi
}

# list "vm zone" pairs of a regional MIG (works without the billing-gated API)
mig_vms() { # mig region
  gcloud compute instance-groups managed list-instances "$1" --region="$2" --format='value(instance)' 2>/dev/null | \
  while read -r URL; do
    [ -z "$URL" ] && continue
    echo "${URL##*/} $(sed -n 's#.*/zones/\([^/]*\)/.*#\1#p' <<<"$URL")"
  done
}

# =====================================================================
step "TASK 1 | Regional Internal Proxy NLB (Region B)"
# =====================================================================
PROXY_SUBNET=$(gcloud compute networks subnets list --network="$NETWORK" --regions="$REGION_B" \
  --filter="purpose=REGIONAL_MANAGED_PROXY" --format='value(name)' 2>/dev/null | head -1)
if [ -z "$PROXY_SUBNET" ]; then
  run "Create proxy-only subnet $PROXY_CIDR" gcloud compute networks subnets create proxy-only-subnet-b \
    --network="$NETWORK" --region="$REGION_B" --range="$PROXY_CIDR" \
    --purpose=REGIONAL_MANAGED_PROXY --role=ACTIVE
else
  ok "Proxy-only subnet already present ($PROXY_SUBNET)"
fi

TPL_P_URI=$(tpl_uri "$TPL_P" "$REGION_B")
run "Create regional MIG mig-proxy-internal" gcloud compute instance-groups managed create mig-proxy-internal \
  --region="$REGION_B" --template="$TPL_P_URI" --size=2
run "Set named port tcp80:80" gcloud compute instance-groups managed set-named-ports mig-proxy-internal \
  --region="$REGION_B" --named-ports=tcp80:80

run "Firewall: health checks (TCP 80)" gcloud compute firewall-rules create fw-allow-health-check-proxy-internal \
  --network="$NETWORK" --direction=INGRESS --action=ALLOW --rules=tcp:80 \
  --source-ranges=130.211.0.0/22,35.191.0.0/16 --target-tags=tag-proxy-internal
run "Firewall: proxy-only subnet $PROXY_CIDR (TCP 80)" gcloud compute firewall-rules create fw-allow-proxy-only-internal \
  --network="$NETWORK" --direction=INGRESS --action=ALLOW --rules=tcp:80 \
  --source-ranges="$PROXY_CIDR" --target-tags=tag-proxy-internal

run "Regional health check" gcloud compute health-checks create tcp hc-proxy-internal \
  --region="$REGION_B" --port=80
run "Backend service" gcloud compute backend-services create service-proxy-internal \
  --load-balancing-scheme=INTERNAL_MANAGED --protocol=TCP --port-name=tcp80 \
  --region="$REGION_B" --health-checks=hc-proxy-internal --health-checks-region="$REGION_B"

if gcloud compute backend-services describe service-proxy-internal --region="$REGION_B" \
     --format="value(backends[].group)" 2>/dev/null | grep -q "mig-proxy-internal"; then
  ok "MIG already attached to internal backend service"
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

run "Create client VM vm-client-internal" gcloud compute instances create vm-client-internal \
  --zone="$ZONE_B" --network="$NETWORK" --subnet="$SUBNET_B" --tags=allow-ssh --machine-type=e2-micro

INTERNAL_IP=$(gcloud compute addresses describe ip-internal-proxy --region="$REGION_B" --format='value(address)')
info "Internal LB IP: $INTERNAL_IP"
info "Waiting for backends and client VM (1-3 minutes)..."
gcloud compute instance-groups managed wait-until mig-proxy-internal --stable --region="$REGION_B" --timeout=300 >/dev/null 2>&1

for try in 1 2 3 4 5 6 7 8; do
  CODE=$(gcloud compute ssh vm-client-internal --zone="$ZONE_B" --quiet --strict-host-key-checking=no \
    --command="curl -s -m 10 -o /dev/null -w '%{http_code}' http://$INTERNAL_IP:110" 2>/dev/null | tail -1)
  [ "$CODE" = "200" ] || CODE=$(gcloud compute ssh vm-client-internal --zone="$ZONE_B" --quiet --tunnel-through-iap \
    --strict-host-key-checking=no --command="curl -s -m 10 -o /dev/null -w '%{http_code}' http://$INTERNAL_IP:110" 2>/dev/null | tail -1)
  if [ "$CODE" = "200" ]; then ok "Internal LB reachable on $INTERNAL_IP:110 (HTTP 200)"; break; fi
  warn "Not ready yet (attempt $try/8) - waiting 20s..."
  sleep 20
done

# =====================================================================
step "TASK 2 | Global External Application Load Balancer"
# =====================================================================
run "Create MIG mig-alb-api-a (Region A)" gcloud compute instance-groups managed create mig-alb-api-a \
  --region="$REGION_A" --template="$(tpl_uri "$TPL_A" "$REGION_A")" --size=2
run "Set named port http80:80 (A)" gcloud compute instance-groups managed set-named-ports mig-alb-api-a \
  --region="$REGION_A" --named-ports=http80:80
run "Create MIG mig-alb-api-b (Region B)" gcloud compute instance-groups managed create mig-alb-api-b \
  --region="$REGION_B" --template="$(tpl_uri "$TPL_A" "$REGION_B")" --size=2
run "Set named port http80:80 (B)" gcloud compute instance-groups managed set-named-ports mig-alb-api-b \
  --region="$REGION_B" --named-ports=http80:80

run "Global HTTP health check http-check-alb" gcloud compute health-checks create http http-check-alb \
  --global --port=80
run "Global backend service service-alb-global" gcloud compute backend-services create service-alb-global \
  --global --load-balancing-scheme=EXTERNAL_MANAGED --protocol=HTTP --port-name=http80 \
  --health-checks=http-check-alb --global-health-checks

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
    OUT=$(gcloud compute backend-services add-backend service-alb-global --global \
      --instance-group="${X%%:*}" --instance-group-region="${X##*:}" \
      --balancing-mode=RATE --max-rate=1 2>&1) || { warn "add-backend ${X%%:*}:"; echo "$OUT" | tail -4 | sed 's/^/      /'; }
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
  both_attached && ok "Both MIGs attached (Rate, max 1 RPS)" || bad "MIG attach failed - copy the error above"
fi

CERT_DIR=$(mktemp -d); cd "$CERT_DIR" || exit 1
openssl genrsa -out key.pem 2048 >/dev/null 2>&1
openssl req -new -x509 -key key.pem -out cert.pem -days 1 -subj "/CN=example.com" >/dev/null 2>&1
run "SSL certificate cert-self-signed" gcloud compute ssl-certificates create cert-self-signed \
  --certificate=cert.pem --private-key=key.pem --global
cd ~ || true

run "Reserve global IP ip-alb-global" gcloud compute addresses create ip-alb-global --global --ip-version=IPV4
run "URL map" gcloud compute url-maps create urlmap-alb-global --default-service=service-alb-global
run "Target HTTPS proxy" gcloud compute target-https-proxies create proxy-alb-https \
  --url-map=urlmap-alb-global --ssl-certificates=cert-self-signed
run "HTTPS forwarding rule (port 443)" gcloud compute forwarding-rules create rule-alb-https \
  --global --load-balancing-scheme=EXTERNAL_MANAGED --network-tier=PREMIUM \
  --address=ip-alb-global --target-https-proxy=proxy-alb-https --ports=443

run "Firewall fw-allow-health-check-and-proxy" gcloud compute firewall-rules create fw-allow-health-check-and-proxy \
  --network="$NETWORK" --direction=INGRESS --action=ALLOW --rules=tcp:80 \
  --source-ranges=130.211.0.0/22,35.191.0.0/16

# extra SSH access so Task 3 can reach the ALB VMs (direct + IAP)
run "Firewall: SSH access for Task 3" gcloud compute firewall-rules create fw-perkverse-allow-ssh \
  --network="$NETWORK" --direction=INGRESS --action=ALLOW --rules=tcp:22 \
  --source-ranges=0.0.0.0/0,35.235.240.0/20

# =====================================================================
step "TASK 3 | Failover and global distribution test"
# =====================================================================
if ! both_attached; then
  bad "Task 2 backends are not attached, so Task 3 cannot work. Fix the error above first."
  return 1 2>/dev/null || exit 1
fi

LB_IP=$(gcloud compute addresses describe ip-alb-global --global --format='value(address)')
info "Global LB IP: $LB_IP"
hit()     { curl -k -s -m 5 "https://$LB_IP" | grep "Hello from"; }
health()  { gcloud compute backend-services get-health service-alb-global --global 2>/dev/null; }
n_healthy()   { health | grep -c "healthState: HEALTHY"; }
n_unhealthy() { health | grep -c "healthState: UNHEALTHY"; }

ssh_run() { # vm zone command
  gcloud compute ssh "$1" --zone="$2" --quiet --strict-host-key-checking=no --command="$3" >/dev/null 2>&1 || \
  gcloud compute ssh "$1" --zone="$2" --quiet --tunnel-through-iap --strict-host-key-checking=no --command="$3" >/dev/null 2>&1
}
nginx_ctl() { # stop|start
  local count=0
  while read -r VM VZ; do
    [ -z "$VM" ] && continue
    count=$((count+1))
    for try in 1 2 3 4; do
      if ssh_run "$VM" "$VZ" "sudo systemctl $1 nginx"; then ok "nginx $1 done on $VM"; break; fi
      warn "SSH to $VM failed (attempt $try/4), retrying in 15s..."; sleep 15
      [ "$try" = "4" ] && bad "Could not run 'systemctl $1 nginx' on $VM"
    done
  done < <(mig_vms mig-alb-api-a "$REGION_A")
  [ "$count" = "0" ] && bad "No VMs found in mig-alb-api-a"
}

info "Waiting for backends to become HEALTHY (can take 3-8 minutes)..."
for try in $(seq 1 50); do
  H=$(n_healthy)
  if [ "$H" -ge 2 ] && hit | grep -q "Hello from"; then ok "Backends healthy ($H) and LB is serving traffic"; break; fi
  echo -ne "  ...waiting ($try/50)  healthy backends: $H\r"; sleep 15
done
echo

echo; info "Traffic distribution (should alternate between Region A and Region B):"
for i in $(seq 1 16); do hit; sleep 0.5; done

echo; info "Simulating failure: stopping nginx in mig-alb-api-a"
nginx_ctl stop

info "Waiting for the health check to mark Region A UNHEALTHY..."
for try in $(seq 1 24); do
  U=$(n_unhealthy)
  if [ "$U" -ge 1 ]; then ok "Region A is UNHEALTHY ($U instance(s))"; break; fi
  echo -ne "  ...waiting ($try/24)\r"; sleep 10
done
echo
info "Traffic during failure (only Region B should respond):"
for i in $(seq 1 14); do hit; sleep 0.5; done

echo -e "\n${Y}  ► Now click 'Check my progress' for Task 3 in the lab page.${N}"
echo -e "${Y}    Press ENTER afterwards to restore nginx (auto-restores after 120s).${N}"
read -t 120 -r _ </dev/tty 2>/dev/null || sleep 3

echo; info "Restoring backend: starting nginx"
nginx_ctl start
info "Waiting for Region A to become HEALTHY again..."
for try in $(seq 1 24); do	
  [ "$(n_unhealthy)" = "0" ] && [ "$(n_healthy)" -ge 2 ] && { ok "All backends HEALTHY again"; break; }
  echo -ne "  ...waiting ($try/24)\r"; sleep 10
done
echo
for i in $(seq 1 10); do hit; sleep 0.5; done

echo -e "\n${G}  ╔══════════════════════════════════════════════════════════╗"
echo -e "  ║   ALL TASKS DONE - now click 'Check my progress' ✔       ║"
echo -e "  ║                  Subscribe to PERKVERSE                  ║"
echo -e "  ╚══════════════════════════════════════════════════════════╝${N}"
