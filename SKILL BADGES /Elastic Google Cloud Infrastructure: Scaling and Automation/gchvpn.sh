#!/bin/bash
# =====================================================================
#  Google Cloud HA VPN Lab (CBL389) - Full Auto Script
#  Run in Cloud Shell:  bash ha-vpn-lab.sh
# =====================================================================

export CLOUDSDK_CORE_DISABLE_PROMPTS=1
MAX_TRY=15      # number of retries per command
DELAY=8         # wait between retries (seconds)

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
    warn "Enabling Compute API (auto-fix)..."
    gcloud services enable compute.googleapis.com --quiet >/dev/null 2>&1
    sleep 10
  elif grep -qiE "resourceNotReady|not ready|being used by|RESOURCE_IN_USE|operation .* in progress|is not ready" <<<"$out"; then
    warn "Resource busy/not ready - waiting, then retrying..."
    sleep 10
  elif grep -qiE "was not found|Could not fetch resource|notFound" <<<"$out"; then
    warn "Dependent resource is still being created - waiting..."
    sleep 8
  elif grep -qiE "ZONE_RESOURCE_POOL_EXHAUSTED|does not have enough resources" <<<"$out"; then
    warn "Zone has no capacity - retrying (if it keeps failing, re-run the script with a different zone)."
  elif grep -qiE "quota" <<<"$out"; then
    warn "Quota issue - cannot be auto-fixed, retrying."
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
      good "Already exists - skipping ${DIM}($((SECONDS-t0))s)${RST}"; return 0
    fi
    err=$(grep -iE "error" <<<"$out" | head -1); [[ -z "$err" ]] && err=$(tail -1 <<<"$out")
    warn "Attempt ${try}/${MAX_TRY} failed: ${err:0:150}"
    auto_fix "$out"
    try=$((try+1)); sleep $DELAY
  done
  bad "Failed after ${MAX_TRY} attempts: ${desc}"
  echo "${DIM}--- last error ---${RST}"; tail -8 <<<"$out"
  echo "${YLW}Re-running the script will continue from here (safe).${RST}"
  exit 1
}

# run + show output (for verification)
show() {
  local desc="$1"; shift
  local try=1 out rc
  echo "  ${CYN}▶${RST} ${BOLD}${desc}${RST}"
  while (( try <= MAX_TRY )); do
    out=$("$@" 2>&1); rc=$?
    if (( rc == 0 )); then sed 's/^/      /' <<<"$out"; good "Verified"; return 0; fi
    warn "Attempt ${try}/${MAX_TRY} failed"; auto_fix "$out"
    try=$((try+1)); sleep $DELAY
  done
  bad "Failed: $desc"; tail -5 <<<"$out"; return 1
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
  warn "${name} is not ESTABLISHED yet - continuing anyway."
  return 1
}

# ---------- Ping via SSH ----------
ssh_ping() {
  local target="$1" try=1 out rc
  echo "  ${CYN}▶${RST} ${BOLD}Ping ${target} from on-prem-instance1${RST}"
  while (( try <= MAX_TRY )); do
    out=$(gcloud compute ssh on-prem-instance1 --zone "$ZONE_ONPREM" --quiet \
          --strict-host-key-checking=no --command "ping -c 4 ${target}" 2>&1); rc=$?
    if (( rc == 0 )) && grep -qE "bytes from" <<<"$out"; then
      grep -E "bytes from|packet loss|rtt" <<<"$out" | sed 's/^/      /'
      good "Ping successful: ${target}"; return 0
    fi
    warn "Attempt ${try}/${MAX_TRY}: ssh/ping not ready yet (BGP/routes still converging)..."
    try=$((try+1)); sleep 12
  done
  bad "Ping failed: ${target}"; tail -6 <<<"$out"; return 1
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
if [[ -z "$PROJECT_ID" ]]; then bad "Could not detect Project ID. Are you logged in with the lab credentials?"; exit 1; fi
gcloud config set project "$PROJECT_ID" --quiet >/dev/null 2>&1
good "Project ID detected: ${BOLD}${PROJECT_ID}${RST}"

run "Enabling Compute Engine API" gcloud services enable compute.googleapis.com --quiet

# ---------- Auto-detect Region / Zones ----------
AUTO_MODE=0; [[ "$1" == "--auto" ]] && AUTO_MODE=1
meta() { gcloud compute project-info describe --format="value(commonInstanceMetadata.items[$1])" 2>/dev/null; }
clean_unset() { [[ "$1" == "(unset)" ]] && echo "" || echo "$1"; }

info "Auto-detecting Region/Zones..."
E2_ZONES=$(gcloud compute machine-types list --filter="name=e2-medium" --format="value(zone)" 2>/dev/null | sort -u)

DEF_REGION=$(meta google-compute-default-region)
DEF_ZONE=$(meta google-compute-default-zone)
[[ -z "$DEF_REGION" ]] && DEF_REGION=$(clean_unset "$(gcloud config get-value compute/region 2>/dev/null)")
[[ -z "$DEF_ZONE"   ]] && DEF_ZONE=$(clean_unset "$(gcloud config get-value compute/zone 2>/dev/null)")
[[ -z "$DEF_REGION" && -n "$DEF_ZONE" ]] && DEF_REGION="${DEF_ZONE%-*}"
if [[ -z "$DEF_REGION" ]]; then
  DEF_REGION=$(gcloud compute regions list --filter="status=UP" --format="value(name)" 2>/dev/null | grep -E '^us-' | head -1)
fi
[[ -n "$DEF_ZONE" && "$DEF_ZONE" != "$DEF_REGION"-* ]] && DEF_ZONE=""

# zone chooser: prefer zones with e2-medium, then any zone
pick_zone() { # region [exclude-zone]
  local z
  for z in $(grep "^$1-" <<<"$E2_ZONES"); do [[ "$z" != "$2" ]] && { echo "$z"; return; }; done
  for z in $(gcloud compute zones list --filter="name~^$1-" --format="value(name)" 2>/dev/null | sort); do
    [[ "$z" != "$2" ]] && { echo "$z"; return; }
  done
}
# second region chooser: same continent, different region
pick_region2() {
  local cont="${REGION1%%-*}" r
  for r in us-west1 us-east1 us-central1 europe-west1 europe-west4 asia-east1 asia-south1; do
    [[ "$r" != "$REGION1" && "$r" == "$cont"-* ]] && grep -q "^$r-" <<<"$E2_ZONES" && { echo "$r"; return; }
  done
  for r in $(gcloud compute regions list --filter="status=UP" --format="value(name)" 2>/dev/null | sort); do
    [[ "$r" != "$REGION1" && "$r" == "$cont"-* ]] && grep -q "^$r-" <<<"$E2_ZONES" && { echo "$r"; return; }
  done
  for r in $(gcloud compute regions list --filter="status=UP" --format="value(name)" 2>/dev/null | sort); do
    [[ "$r" != "$REGION1" ]] && grep -q "^$r-" <<<"$E2_ZONES" && { echo "$r"; return; }
  done
}

REGION1="$DEF_REGION"
ZONE1="${DEF_ZONE:-$( [[ -n "$REGION1" ]] && pick_zone "$REGION1" )}"
DEF_R2=""; DEF_Z2=""; DEF_ZO=""
if [[ -n "$REGION1" ]]; then
  DEF_R2=$(pick_region2)
  [[ -n "$DEF_R2" ]] && DEF_Z2=$(pick_zone "$DEF_R2")
  DEF_ZO=$(pick_zone "$REGION1" "$ZONE1")
fi
REGION2="$DEF_R2"; ZONE2="$DEF_Z2"; ZONE_ONPREM="$DEF_ZO"

DETECT_OK=0
if [[ -n "$REGION1" && -n "$ZONE1" && -n "$REGION2" && -n "$ZONE2" && -n "$ZONE_ONPREM" ]] \
   && valid_region "$REGION1" && valid_zone "$REGION1" "$ZONE1" \
   && valid_region "$REGION2" && valid_zone "$REGION2" "$ZONE2" \
   && valid_zone "$REGION1" "$ZONE_ONPREM"; then DETECT_OK=1; fi

USE_MANUAL=0
if (( DETECT_OK )); then
  echo
  good "Auto-detected:  Region1=${BOLD}$REGION1${RST}  Zone1=${BOLD}$ZONE1${RST}  Region2=${BOLD}$REGION2${RST}  Zone2=${BOLD}$ZONE2${RST}  On-prem zone=${BOLD}$ZONE_ONPREM${RST}"
  warn "Region 1/Zone 1 come from the project settings. Region 2 is only a suggestion - compare it with the Lab setup panel."
  if (( AUTO_MODE == 0 )); then
    read -r -p "  ${YLW}?${RST} Use these values? [Y/n]: " ans
    [[ "$ans" =~ ^[Nn]$ ]] && USE_MANUAL=1
  fi
else
  warn "Auto-detect incomplete - please enter values manually."
  USE_MANUAL=1
fi

if (( USE_MANUAL )); then
  echo; info "Enter Region/Zone from the ${BOLD}Lab setup panel${RST} (Enter = detected default):"; echo
  while true; do ask REGION1 "REGION 1" "$REGION1"; valid_region "$REGION1" && break || bad "Invalid region: $REGION1"; done
  [[ "$ZONE1" != "$REGION1"-* ]] && ZONE1=$(pick_zone "$REGION1")
  while true; do ask ZONE1 "ZONE 1 (in $REGION1)" "$ZONE1"; valid_zone "$REGION1" "$ZONE1" && break || bad "Zone $ZONE1 does not belong to $REGION1 or is invalid"; done
  [[ -z "$REGION2" || "$REGION2" == "$REGION1" ]] && REGION2=$(pick_region2)
  while true; do ask REGION2 "REGION 2" "$REGION2"; valid_region "$REGION2" && break || bad "Invalid region: $REGION2"; done
  [[ "$ZONE2" != "$REGION2"-* ]] && ZONE2=$(pick_zone "$REGION2")
  while true; do ask ZONE2 "ZONE 2 (in $REGION2)" "$ZONE2"; valid_zone "$REGION2" "$ZONE2" && break || bad "Zone $ZONE2 does not belong to $REGION2 or is invalid"; done
  ZONE_ONPREM=$(pick_zone "$REGION1" "$ZONE1")
  while true; do ask ZONE_ONPREM "ON-PREM zone (in $REGION1, different from ZONE 1)" "$ZONE_ONPREM"
    if [[ "$ZONE_ONPREM" == "$ZONE1" ]]; then bad "Must be different from ZONE 1"; continue; fi
    valid_zone "$REGION1" "$ZONE_ONPREM" && break || bad "Invalid zone"; done
fi

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
(( AUTO_MODE )) || read -r -p "  ${YLW}Press Enter to start (Ctrl+C to cancel)...${RST}" _

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

echo; info "${BOLD}Enabling global routing mode on vpc-demo${RST}"
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
echo "  ${GRN}${BOLD}🎉 All lab tasks are complete!${RST}"
echo "  ${DIM}Total time: $((SECONDS-START_ALL))s${RST}"
echo
echo "  ${YLW}Now click 'Check my progress' on the lab page.${RST}"
echo "  ${DIM}Cleanup (Task 8) is optional - only do it AFTER the progress check.${RST}"
echo
DO_CLEAN=n; (( AUTO_MODE )) || read -r -p "  ${YLW}Run cleanup now? (y/N): ${RST}" DO_CLEAN
[[ "$DO_CLEAN" =~ ^[Yy]$ ]] || { echo "  ${GRN}Done. Cleanup skipped.${RST}"; exit 0; }

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
