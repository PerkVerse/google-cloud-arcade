#!/bin/bash
# =====================================================================
#  Google Cloud HA VPN Lab (CBL389) - Full Auto Script
#  Run in Cloud Shell:  bash ha-vpn-lab.sh
# =====================================================================

export CLOUDSDK_CORE_DISABLE_PROMPTS=1
MAX_TRY=15      # kitni baar retry karna hai
DELAY=8         # retry ke beech wait (seconds)

# ---------- Colors ----------
RST=$'\e[0m'; BOLD=$'\e[1m'; RED=$'\e[1;31m'; GRN=$'\e[1;32m'
YLW=$'\e[1;33m'; BLU=$'\e[1;34m'; MAG=$'\e[1;35m'; CYN=$'\e[1;36m'; DIM=$'\e[2m'

START_ALL=$SECONDS
OK_PAT="already exist|alreadyExists|already has|duplicate"

hdr()  { echo; echo "${BLU}══════════════════════════════════════════════════════════════${RST}"
         echo "${BOLD}${MAG}  $1${RST}"
         echo "${BLU}══════════════════════════════════════════════════════════════${RST}"; }
info() { echo "  ${CYN}ℹ${RST} $1"; }
good() { echo "  ${GRN}✔${RST} $1"; }
warn() { echo "  ${YLW}⚠${RST} $1"; }
bad()  { echo "  ${RED}✘${RST} $1"; }

# ---------- Auto-fix hooks ----------
auto_fix() {
  local out="$1"
  if grep -qiE "SERVICE_DISABLED|has not been used|API .* not enabled|accessNotConfigured" <<<"$out"; then
    warn "Compute API enable kar raha hu (auto-fix)..."
    gcloud services enable compute.googleapis.com --quiet >/dev/null 2>&1
    sleep 10
  elif grep -qiE "resourceNotReady|not ready|being used by|RESOURCE_IN_USE|operation .* in progress|is not ready" <<<"$out"; then
    warn "Resource busy/not ready - thoda wait karke retry..."
    sleep 10
  elif grep -qiE "was not found|Could not fetch resource|notFound" <<<"$out"; then
    warn "Dependent resource abhi ban raha hai - wait kar raha hu..."
    sleep 8
  elif grep -qiE "ZONE_RESOURCE_POOL_EXHAUSTED|does not have enough resources" <<<"$out"; then
    warn "Zone me capacity nahi hai - retry (zone change karna pade to script dobara chalao)."
  elif grep -qiE "quota" <<<"$out"; then
    warn "Quota issue - auto-fix possible nahi, retry kar raha hu."
  fi
}

# ---------- Retry runner ----------
run() {
  local desc="$1"; shift
  local try=1 out rc t0=$SECONDS err
  echo "  ${CYN}▶${RST} ${BOLD}${desc}${RST}"
  while (( try <= MAX_TRY )); do
    out=$("$@" 2>&1); rc=$?
    if (( rc == 0 )); then
      good "Done ${DIM}($((SECONDS-t0))s)${RST}"; return 0
    fi
    if grep -qiE "$OK_PAT" <<<"$out"; then
      good "Already exists / done - skipping ${DIM}($((SECONDS-t0))s)${RST}"; return 0
    fi
    err=$(grep -iE "error" <<<"$out" | head -1); [[ -z "$err" ]] && err=$(tail -1 <<<"$out")
    warn "Attempt ${try}/${MAX_TRY} fail: ${err:0:150}"
    auto_fix "$out"
    try=$((try+1)); sleep $DELAY
  done
  bad "${MAX_TRY} attempts ke baad bhi fail: ${desc}"
  echo "${DIM}--- last error ---${RST}"; tail -8 <<<"$out"
  echo "${YLW}Script dobara chalane se wahi se continue hoga (safe).${RST}"
  exit 1
}

# run + output dikhao (verification ke liye)
show() {
  local desc="$1"; shift
  local try=1 out rc
  echo "  ${CYN}▶${RST} ${BOLD}${desc}${RST}"
  while (( try <= MAX_TRY )); do
    out=$("$@" 2>&1); rc=$?
    if (( rc == 0 )); then sed 's/^/      /' <<<"$out"; good "Verified"; return 0; fi
    warn "Attempt ${try}/${MAX_TRY} fail"; auto_fix "$out"
    try=$((try+1)); sleep $DELAY
  done
  bad "Fail: $desc"; tail -5 <<<"$out"; return 1
}

# ---------- Tunnel wait ----------
wait_tunnel() {
  local name="$1" st i
  echo "  ${CYN}▶${RST} ${BOLD}Waiting for ${name} -> ESTABLISHED${RST}"
  for i in $(seq 1 40); do
    st=$(gcloud compute vpn-tunnels describe "$name" --region "$REGION1" --format="value(status)" 2>/dev/null)
    if [[ "$st" == "ESTABLISHED" ]]; then good "${name} is ESTABLISHED"; return 0; fi
    echo "      ${DIM}[$i/40] status: ${st:-pending}${RST}"; sleep 10
  done
  warn "${name} abhi tak ESTABLISHED nahi hua - aage badh raha hu."
  return 1
}

# ---------- Ping via SSH ----------
ssh_ping() {
  local target="$1" try=1 out rc
  echo "  ${CYN}▶${RST} ${BOLD}on-prem-instance1 se ping ${target}${RST}"
  while (( try <= MAX_TRY )); do
    out=$(gcloud compute ssh on-prem-instance1 --zone "$ZONE_ONPREM" --quiet \
          --strict-host-key-checking=no --command "ping -c 4 ${target}" 2>&1); rc=$?
    if (( rc == 0 )) && grep -qE "bytes from" <<<"$out"; then
      grep -E "bytes from|packet loss|rtt" <<<"$out" | sed 's/^/      /'
      good "Ping successful: ${target}"; return 0
    fi
    warn "Attempt ${try}/${MAX_TRY}: ping/ssh abhi ready nahi (BGP/route converge ho raha hai)..."
    try=$((try+1)); sleep 12
  done
  bad "Ping fail: ${target}"; tail -6 <<<"$out"; return 1
}

# ---------- Input helpers ----------
ask() { # ask VAR "prompt" "default"
  local var="$1" prompt="$2" def="$3" val
  while true; do
    if [[ -n "$def" ]]; then
      read -r -p "  ${YLW}?${RST} ${prompt} ${DIM}[${def}]${RST}: " val; val="${val:-$def}"
    else
      read -r -p "  ${YLW}?${RST} ${prompt}: " val
    fi
    val=$(echo "$val" | tr -d ' "'"'"); [[ -n "$val" ]] && break
  done
  printf -v "$var" '%s' "$val"
}
valid_region() { gcloud compute regions describe "$1" --format="value(name)" >/dev/null 2>&1; }
valid_zone()   { [[ "$2" == "$1"-* ]] && gcloud compute zones describe "$2" --format="value(name)" >/dev/null 2>&1; }

# =====================================================================
clear
echo "${CYN}${BOLD}"
cat << 'BANNER'
  ╔══════════════════════════════════════════════════════════╗
  ║        GOOGLE CLOUD  HA VPN  LAB  -  AUTO SETUP          ║
  ║   VPC + Subnets + HA VPN + Cloud Router + BGP + Tests    ║
  ╚══════════════════════════════════════════════════════════╝
BANNER
echo "${RST}"

# ---------- Project ID ----------
hdr "STEP 0: Project & Inputs"
PROJECT_ID="${DEVSHELL_PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "(unset)" ]]; then
  PROJECT_ID=$(gcloud projects list --format="value(projectId)" --limit=1 2>/dev/null)
fi
if [[ -z "$PROJECT_ID" ]]; then bad "Project ID detect nahi hua. Lab ke credentials se login ho?"; exit 1; fi
gcloud config set project "$PROJECT_ID" --quiet >/dev/null 2>&1
good "Project ID detected: ${BOLD}${PROJECT_ID}${RST}"

run "Enabling Compute Engine API" gcloud services enable compute.googleapis.com --quiet

DEF_REGION=$(gcloud compute project-info describe --format="value(commonInstanceMetadata.items[google-compute-default-region])" 2>/dev/null)
DEF_ZONE=$(gcloud compute project-info describe --format="value(commonInstanceMetadata.items[google-compute-default-zone])" 2>/dev/null)

echo; info "Lab ke ${BOLD}Lab setup panel${RST} se Region/Zone dekh ke daalo:"; echo
while true; do ask REGION1 "REGION 1 (e.g. us-central1)" "$DEF_REGION"; valid_region "$REGION1" && break || bad "Invalid region: $REGION1"; done
while true; do ask ZONE1 "ZONE 1 (zone in $REGION1)" "${DEF_ZONE:-${REGION1}-a}"; valid_zone "$REGION1" "$ZONE1" && break || bad "Zone $ZONE1, $REGION1 ka nahi hai ya invalid"; done
while true; do ask REGION2 "REGION 2 (e.g. us-west1)" ""; valid_region "$REGION2" && break || bad "Invalid region: $REGION2"; done
DEF_Z2=$(gcloud compute zones list --filter="name~^${REGION2}-" --format="value(name)" 2>/dev/null | head -1)
while true; do ask ZONE2 "ZONE 2 (zone in $REGION2)" "$DEF_Z2"; valid_zone "$REGION2" "$ZONE2" && break || bad "Zone $ZONE2, $REGION2 ka nahi hai ya invalid"; done
DEF_ZO=$(gcloud compute zones list --filter="name~^${REGION1}-" --format="value(name)" 2>/dev/null | grep -v "^${ZONE1}$" | head -1)
while true; do ask ZONE_ONPREM "ON-PREM zone (REGION 1 me, ZONE 1 se alag)" "$DEF_ZO"
  if [[ "$ZONE_ONPREM" == "$ZONE1" ]]; then bad "ZONE 1 se alag zone chahiye"; continue; fi
  valid_zone "$REGION1" "$ZONE_ONPREM" && break || bad "Invalid zone"; done

SECRET=$(openssl rand -hex 16 2>/dev/null || echo "LabSecret${RANDOM}${RANDOM}")

echo
echo "  ${BOLD}┌──────────────── CONFIGURATION ────────────────┐${RST}"
printf "  │ %-14s : %-29s │\n" "Project"      "$PROJECT_ID"
printf "  │ %-14s : %-29s │\n" "Region 1"     "$REGION1"
printf "  │ %-14s : %-29s │\n" "Zone 1"       "$ZONE1"
printf "  │ %-14s : %-29s │\n" "Region 2"     "$REGION2"
printf "  │ %-14s : %-29s │\n" "Zone 2"       "$ZONE2"
printf "  │ %-14s : %-29s │\n" "On-prem zone" "$ZONE_ONPREM"
printf "  │ %-14s : %-29s │\n" "Shared secret" "(auto-generated)"
echo "  ${BOLD}└───────────────────────────────────────────────┘${RST}"
read -r -p "  ${YLW}Enter dabao start karne ke liye (Ctrl+C = cancel)...${RST}" _

# =====================================================================
hdr "TASK 1: Global VPC environment (vpc-demo)"
run "Create VPC vpc-demo" gcloud compute networks create vpc-demo --subnet-mode custom
run "Create subnet vpc-demo-subnet1 ($REGION1)" gcloud compute networks subnets create vpc-demo-subnet1 --network vpc-demo --range 10.1.1.0/24 --region "$REGION1"
run "Create subnet vpc-demo-subnet2 ($REGION2)" gcloud compute networks subnets create vpc-demo-subnet2 --network vpc-demo --range 10.2.1.0/24 --region "$REGION2"
run "Firewall: vpc-demo-allow-custom" gcloud compute firewall-rules create vpc-demo-allow-custom --network vpc-demo --allow tcp:0-65535,udp:0-65535,icmp --source-ranges 10.0.0.0/8
run "Firewall: vpc-demo-allow-ssh-icmp" gcloud compute firewall-rules create vpc-demo-allow-ssh-icmp --network vpc-demo --allow tcp:22,icmp
run "Create VM vpc-demo-instance1 ($ZONE1)" gcloud compute instances create vpc-demo-instance1 --machine-type=e2-medium --zone "$ZONE1" --subnet vpc-demo-subnet1
run "Create VM vpc-demo-instance2 ($ZONE2)" gcloud compute instances create vpc-demo-instance2 --machine-type=e2-medium --zone "$ZONE2" --subnet vpc-demo-subnet2

hdr "TASK 2: Simulated on-premises environment (on-prem)"
run "Create VPC on-prem" gcloud compute networks create on-prem --subnet-mode custom
run "Create subnet on-prem-subnet1" gcloud compute networks subnets create on-prem-subnet1 --network on-prem --range 192.168.1.0/24 --region "$REGION1"
run "Firewall: on-prem-allow-custom" gcloud compute firewall-rules create on-prem-allow-custom --network on-prem --allow tcp:0-65535,udp:0-65535,icmp --source-ranges 192.168.0.0/16
run "Firewall: on-prem-allow-ssh-icmp" gcloud compute firewall-rules create on-prem-allow-ssh-icmp --network on-prem --allow tcp:22,icmp
run "Create VM on-prem-instance1 ($ZONE_ONPREM)" gcloud compute instances create on-prem-instance1 --machine-type=e2-medium --zone "$ZONE_ONPREM" --subnet on-prem-subnet1

hdr "TASK 3: HA VPN gateways & Cloud Routers"
run "Create HA VPN gateway vpc-demo-vpn-gw1" gcloud compute vpn-gateways create vpc-demo-vpn-gw1 --network vpc-demo --region "$REGION1"
run "Create HA VPN gateway on-prem-vpn-gw1" gcloud compute vpn-gateways create on-prem-vpn-gw1 --network on-prem --region "$REGION1"
show "Describe vpc-demo-vpn-gw1" gcloud compute vpn-gateways describe vpc-demo-vpn-gw1 --region "$REGION1" --format="yaml(name,vpnInterfaces)"
show "Describe on-prem-vpn-gw1" gcloud compute vpn-gateways describe on-prem-vpn-gw1 --region "$REGION1" --format="yaml(name,vpnInterfaces)"
run "Create Cloud Router vpc-demo-router1 (ASN 65001)" gcloud compute routers create vpc-demo-router1 --region "$REGION1" --network vpc-demo --asn 65001
run "Create Cloud Router on-prem-router1 (ASN 65002)" gcloud compute routers create on-prem-router1 --region "$REGION1" --network on-prem --asn 65002

hdr "TASK 4: VPN tunnels"
run "Tunnel vpc-demo-tunnel0 (interface 0)" gcloud compute vpn-tunnels create vpc-demo-tunnel0 --peer-gcp-gateway on-prem-vpn-gw1 --region "$REGION1" --ike-version 2 --shared-secret "$SECRET" --router vpc-demo-router1 --vpn-gateway vpc-demo-vpn-gw1 --interface 0
run "Tunnel vpc-demo-tunnel1 (interface 1)" gcloud compute vpn-tunnels create vpc-demo-tunnel1 --peer-gcp-gateway on-prem-vpn-gw1 --region "$REGION1" --ike-version 2 --shared-secret "$SECRET" --router vpc-demo-router1 --vpn-gateway vpc-demo-vpn-gw1 --interface 1
run "Tunnel on-prem-tunnel0 (interface 0)" gcloud compute vpn-tunnels create on-prem-tunnel0 --peer-gcp-gateway vpc-demo-vpn-gw1 --region "$REGION1" --ike-version 2 --shared-secret "$SECRET" --router on-prem-router1 --vpn-gateway on-prem-vpn-gw1 --interface 0
run "Tunnel on-prem-tunnel1 (interface 1)" gcloud compute vpn-tunnels create on-prem-tunnel1 --peer-gcp-gateway vpc-demo-vpn-gw1 --region "$REGION1" --ike-version 2 --shared-secret "$SECRET" --router on-prem-router1 --vpn-gateway on-prem-vpn-gw1 --interface 1

hdr "TASK 5: BGP peering"
run "vpc-demo: interface tunnel0" gcloud compute routers add-interface vpc-demo-router1 --interface-name if-tunnel0-to-on-prem --ip-address 169.254.0.1 --mask-length 30 --vpn-tunnel vpc-demo-tunnel0 --region "$REGION1"
run "vpc-demo: BGP peer tunnel0" gcloud compute routers add-bgp-peer vpc-demo-router1 --peer-name bgp-on-prem-tunnel0 --interface if-tunnel0-to-on-prem --peer-ip-address 169.254.0.2 --peer-asn 65002 --region "$REGION1"
run "vpc-demo: interface tunnel1" gcloud compute routers add-interface vpc-demo-router1 --interface-name if-tunnel1-to-on-prem --ip-address 169.254.1.1 --mask-length 30 --vpn-tunnel vpc-demo-tunnel1 --region "$REGION1"
run "vpc-demo: BGP peer tunnel1" gcloud compute routers add-bgp-peer vpc-demo-router1 --peer-name bgp-on-prem-tunnel1 --interface if-tunnel1-to-on-prem --peer-ip-address 169.254.1.2 --peer-asn 65002 --region "$REGION1"
run "on-prem: interface tunnel0" gcloud compute routers add-interface on-prem-router1 --interface-name if-tunnel0-to-vpc-demo --ip-address 169.254.0.2 --mask-length 30 --vpn-tunnel on-prem-tunnel0 --region "$REGION1"
run "on-prem: BGP peer tunnel0" gcloud compute routers add-bgp-peer on-prem-router1 --peer-name bgp-vpc-demo-tunnel0 --interface if-tunnel0-to-vpc-demo --peer-ip-address 169.254.0.1 --peer-asn 65001 --region "$REGION1"
run "on-prem: interface tunnel1" gcloud compute routers add-interface on-prem-router1 --interface-name if-tunnel1-to-vpc-demo --ip-address 169.254.1.2 --mask-length 30 --vpn-tunnel on-prem-tunnel1 --region "$REGION1"
run "on-prem: BGP peer tunnel1" gcloud compute routers add-bgp-peer on-prem-router1 --peer-name bgp-vpc-demo-tunnel1 --interface if-tunnel1-to-vpc-demo --peer-ip-address 169.254.1.1 --peer-asn 65001 --region "$REGION1"

hdr "TASK 6: Verify routers, firewall, tunnels, connectivity"
show "Router vpc-demo-router1" gcloud compute routers describe vpc-demo-router1 --region "$REGION1" --format="yaml(name,bgp.asn,bgpPeers[].name,bgpPeers[].peerIpAddress,interfaces[].name)"
show "Router on-prem-router1" gcloud compute routers describe on-prem-router1 --region "$REGION1" --format="yaml(name,bgp.asn,bgpPeers[].name,bgpPeers[].peerIpAddress,interfaces[].name)"
run "Firewall: vpc-demo-allow-subnets-from-on-prem" gcloud compute firewall-rules create vpc-demo-allow-subnets-from-on-prem --network vpc-demo --allow tcp,udp,icmp --source-ranges 192.168.1.0/24
run "Firewall: on-prem-allow-subnets-from-vpc-demo" gcloud compute firewall-rules create on-prem-allow-subnets-from-vpc-demo --network on-prem --allow tcp,udp,icmp --source-ranges 10.1.1.0/24,10.2.1.0/24

for t in vpc-demo-tunnel0 vpc-demo-tunnel1 on-prem-tunnel0 on-prem-tunnel1; do wait_tunnel "$t"; done
show "VPN tunnels list" gcloud compute vpn-tunnels list
for t in vpc-demo-tunnel0 vpc-demo-tunnel1 on-prem-tunnel0 on-prem-tunnel1; do
  show "Status of $t" gcloud compute vpn-tunnels describe "$t" --region "$REGION1" --format="yaml(name,detailedStatus,status)"
done

ssh_ping 10.1.1.2

echo; info "${BOLD}Global routing mode ON kar raha hu (vpc-demo)${RST}"
run "Update vpc-demo BGP routing mode -> GLOBAL" gcloud compute networks update vpc-demo --bgp-routing-mode GLOBAL
show "Verify routing mode" gcloud compute networks describe vpc-demo --format="yaml(name,routingConfig)"
sleep 15
ssh_ping 10.2.1.2

hdr "TASK 7: Test HA failover (tunnel0 delete)"
run "Delete vpc-demo-tunnel0" gcloud compute vpn-tunnels delete vpc-demo-tunnel0 --region "$REGION1" --quiet
sleep 20
show "on-prem-tunnel0 status (should be broken)" gcloud compute vpn-tunnels describe on-prem-tunnel0 --region "$REGION1" --format="yaml(name,detailedStatus,status)"
ssh_ping 10.1.1.2
good "Pings still working via second tunnel -> HA VPN verified!"

# =====================================================================
hdr "ALL TASKS COMPLETE"
echo "  ${GRN}${BOLD}🎉 Lab ke saare tasks complete ho gaye!${RST}"
echo "  ${DIM}Total time: $((SECONDS-START_ALL))s${RST}"
echo
echo "  ${YLW}Ab Lab page par 'Check my progress' dabao.${RST}"
echo "  ${DIM}Cleanup (Task 8) optional hai - progress check ke BAAD hi karna.${RST}"
echo
read -r -p "  ${YLW}Cleanup abhi karna hai? (y/N): ${RST}" DO_CLEAN
[[ "$DO_CLEAN" =~ ^[Yy]$ ]] || { echo "  ${GRN}Done. Cleanup skip kiya.${RST}"; exit 0; }

hdr "TASK 8: Cleanup"
GONE="not found|was not found|does not exist|notFound"
OK_PAT="$GONE"
run "Remove BGP peer bgp-on-prem-tunnel0" gcloud compute routers remove-bgp-peer vpc-demo-router1 --peer-name bgp-on-prem-tunnel0 --region "$REGION1"
run "Remove BGP peer bgp-on-prem-tunnel1" gcloud compute routers remove-bgp-peer vpc-demo-router1 --peer-name bgp-on-prem-tunnel1 --region "$REGION1"
run "Remove BGP peer bgp-vpc-demo-tunnel0" gcloud compute routers remove-bgp-peer on-prem-router1 --peer-name bgp-vpc-demo-tunnel0 --region "$REGION1"
run "Remove BGP peer bgp-vpc-demo-tunnel1" gcloud compute routers remove-bgp-peer on-prem-router1 --peer-name bgp-vpc-demo-tunnel1 --region "$REGION1"
run "Remove interface if-tunnel0-to-on-prem" gcloud compute routers remove-interface vpc-demo-router1 --interface-name if-tunnel0-to-on-prem --region "$REGION1"
run "Remove interface if-tunnel1-to-on-prem" gcloud compute routers remove-interface vpc-demo-router1 --interface-name if-tunnel1-to-on-prem --region "$REGION1"
run "Remove interface if-tunnel0-to-vpc-demo" gcloud compute routers remove-interface on-prem-router1 --interface-name if-tunnel0-to-vpc-demo --region "$REGION1"
run "Remove interface if-tunnel1-to-vpc-demo" gcloud compute routers remove-interface on-prem-router1 --interface-name if-tunnel1-to-vpc-demo --region "$REGION1"
for t in vpc-demo-tunnel0 on-prem-tunnel0 vpc-demo-tunnel1 on-prem-tunnel1; do run "Delete tunnel $t" gcloud compute vpn-tunnels delete "$t" --region "$REGION1" --quiet; done
run "Delete router on-prem-router1" gcloud compute routers delete on-prem-router1 --region "$REGION1" --quiet
run "Delete router vpc-demo-router1" gcloud compute routers delete vpc-demo-router1 --region "$REGION1" --quiet
run "Delete gateway vpc-demo-vpn-gw1" gcloud compute vpn-gateways delete vpc-demo-vpn-gw1 --region "$REGION1" --quiet
run "Delete gateway on-prem-vpn-gw1" gcloud compute vpn-gateways delete on-prem-vpn-gw1 --region "$REGION1" --quiet
run "Delete VM vpc-demo-instance1" gcloud compute instances delete vpc-demo-instance1 --zone "$ZONE1" --quiet
run "Delete VM vpc-demo-instance2" gcloud compute instances delete vpc-demo-instance2 --zone "$ZONE2" --quiet
run "Delete VM on-prem-instance1" gcloud compute instances delete on-prem-instance1 --zone "$ZONE_ONPREM" --quiet
for f in vpc-demo-allow-custom on-prem-allow-subnets-from-vpc-demo on-prem-allow-ssh-icmp on-prem-allow-custom vpc-demo-allow-subnets-from-on-prem vpc-demo-allow-ssh-icmp; do
  run "Delete firewall $f" gcloud compute firewall-rules delete "$f" --quiet
done
run "Delete subnet vpc-demo-subnet1" gcloud compute networks subnets delete vpc-demo-subnet1 --region "$REGION1" --quiet
run "Delete subnet vpc-demo-subnet2" gcloud compute networks subnets delete vpc-demo-subnet2 --region "$REGION2" --quiet
run "Delete subnet on-prem-subnet1" gcloud compute networks subnets delete on-prem-subnet1 --region "$REGION1" --quiet
run "Delete VPC vpc-demo" gcloud compute networks delete vpc-demo --quiet
run "Delete VPC on-prem" gcloud compute networks delete on-prem --quiet
echo; echo "  ${GRN}${BOLD}🧹 Cleanup complete!${RST}"
