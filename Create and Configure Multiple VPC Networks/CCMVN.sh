#!/bin/bash
# =====================================================================
#  GSP211 - Create and Configure Multiple VPC Networks  (FULL LAB)
#  Script version 2.0
#
#  Run in Google Cloud Shell:
#     bash gsp211_final.sh
#
#  What it does
#   1. Auto-detects project, regions and zone from the lab itself
#   2. Waits for the lab's pre-created mynetwork / mynet-vm-1 / mynet-vm-2
#      (creates them only if they really are missing)
#   3. Builds everything the lab asks for (Tasks 1, 2, 4)
#   4. AUDITS every checkpoint exactly like "Check my progress"
#      and automatically re-builds (up to 3 passes) if anything is wrong
# =====================================================================

# ---------- Colors ----------
R=$'\e[1;31m'; G=$'\e[1;32m'; Y=$'\e[1;33m'; B=$'\e[1;34m'
M=$'\e[1;35m'; C=$'\e[1;36m'; D=$'\e[2m'; W=$'\e[1;37m'; N=$'\e[0m'

VERSION="2.0"
MAX_RETRIES=12
RETRY_DELAY=5
FAILED=()
BREAK_ON=""
START_TS=$(date +%s)

# ---------- Pretty helpers ----------
line()   { printf "${B}%s${N}\n" "=============================================================="; }
banner() { echo; line; printf "${W}  %s${N}\n" "$1"; line; }
step()   { echo; printf "${M}▶ %s${N}\n" "$1"; }
info()   { printf "  ${C}ℹ${N} %s\n" "$1"; }
ok()     { printf "  ${G}✔ %s${N}\n" "$1"; }
warn()   { printf "  ${Y}⚠ %s${N}\n" "$1"; }
err()    { printf "  ${R}✘ %s${N}\n" "$1"; }

# ---------- Retry runner ----------
# usage: run "Description" command arg1 arg2 ...
# return: 0 ok | 1 failed | 2 zone out of capacity (only when BREAK_ON matches)
run() {
  local desc="$1"; shift
  local attempt=1 out
  printf "  ${C}➜${N} %s\n" "$desc"
  printf "    ${D}\$ %s${N}\n" "$*"
  while (( attempt <= MAX_RETRIES )); do
    if out=$("$@" 2>&1); then ok "Done"; return 0; fi
    if grep -qi "already exists" <<<"$out"; then warn "Already exists - skipping (OK)"; return 0; fi
    if [[ -n "$BREAK_ON" ]] && grep -qiE "$BREAK_ON" <<<"$out"; then
      warn "No capacity in this zone"; return 2
    fi
    if grep -qiE "QUOTA_EXCEEDED|quota .* exceeded" <<<"$out"; then
      err "Quota exceeded (retrying will not help)"
      printf "    ${R}%s${N}\n" "$(tail -n 3 <<<"$out" | cut -c1-300)"
      FAILED+=("$desc"); return 1
    fi
    warn "Attempt ${attempt}/${MAX_RETRIES} failed. Retrying in ${RETRY_DELAY}s..."
    printf "    ${D}%s${N}\n" "$(tail -n 3 <<<"$out" | cut -c1-300)"
    sleep "$RETRY_DELAY"
    ((attempt++))
  done
  err "FAILED after ${MAX_RETRIES} attempts: $desc"
  printf "    ${R}%s${N}\n" "$(tail -n 5 <<<"$out")"
  FAILED+=("$desc")
  return 1
}

# ---------- Wait until something is visible ----------
wait_for() {  # wait_for "Description" command args...
  local desc="$1"; shift
  local i
  printf "  ${C}⏳${N} Waiting for %s\n" "$desc"
  for ((i=1; i<=MAX_RETRIES; i++)); do
    if "$@" >/dev/null 2>&1; then ok "Ready"; return 0; fi
    warn "Not ready yet (${i}/${MAX_RETRIES})..."
    sleep "$RETRY_DELAY"
  done
  err "Timed out waiting for $desc"
  FAILED+=("wait: $desc")
  return 1
}

show() { eval "$1" 2>/dev/null || eval "$2"; }
net_exists() { gcloud compute networks describe "$1" >/dev/null 2>&1; }
vm_exists()  { [[ -n "$(gcloud compute instances list --filter="name=$1" --format='value(name)' 2>/dev/null)" ]]; }

# ---------- VM creation with zone fallback ----------
# usage: vm_create NAME REGION PREFERRED_ZONE <gcloud create args...>
vm_create() {
  local name="$1" region="$2" pref="$3"; shift 3
  local z rc zones
  if vm_exists "$name"; then ok "$name already exists - skipping"; return 0; fi
  zones=("$pref" $(gcloud compute zones list --filter="name~^${region}- AND status=UP" \
          --format='value(name)' 2>/dev/null | sort | grep -vx "$pref"))
  for z in "${zones[@]}"; do
    BREAK_ON="ZONE_RESOURCE_POOL_EXHAUSTED|does not have enough resources|STOCKOUT"
    run "Create $name ($z)" gcloud compute instances create "$name" --zone="$z" "$@"
    rc=$?
    BREAK_ON=""
    [[ $rc -eq 0 ]] && return 0
    [[ $rc -eq 1 ]] && return 1
    warn "Trying another zone in $region..."
  done
  FAILED+=("Create $name"); return 1
}

# ---------- Terminal input (works even with curl | bash) ----------
HAS_TTY=0; [[ -r /dev/tty ]] && HAS_TTY=1
ask() {  # ask "Prompt" "default" -> REPLY_VAL
  local p="$1" d="$2" v=""
  if (( HAS_TTY )); then
    if [[ -n "$d" ]]; then read -r -p "  ${W}${p}${N} [${G}${d}${N}]: " v </dev/tty; v="${v:-$d}"
    else read -r -p "  ${W}${p}${N}: " v </dev/tty; fi
  else v="$d"; fi
  v="${v//[[:space:]\\]/}"
  REPLY_VAL="$v"
}

# =====================================================================
# START
# =====================================================================
clear
banner "GSP211 • Create and Configure Multiple VPC Networks  (v${VERSION})"
info "Do not close this window until the SUMMARY appears."

step "Checking Cloud Shell login"
ACCOUNT=$(gcloud config get-value account 2>/dev/null)
if [[ -z "$ACCOUNT" || "$ACCOUNT" == "(unset)" ]]; then
  err "Cloud Shell is not authorized. Click 'Authorize' in the popup (or run: gcloud auth login) and run the script again."
  exit 1
fi
ok "Account    : ${ACCOUNT}"

step "Detecting project"
PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
[[ -z "$PROJECT_ID" || "$PROJECT_ID" == "(unset)" ]] && PROJECT_ID="$DEVSHELL_PROJECT_ID"
[[ -z "$PROJECT_ID" ]] && PROJECT_ID=$(gcloud projects list --format='value(projectId)' --filter='projectId~^qwiklabs' 2>/dev/null | head -n1)
if [[ -z "$PROJECT_ID" ]]; then
  ask "Project ID not detected. Enter it" ""; PROJECT_ID="$REPLY_VAL"
fi
gcloud config set project "$PROJECT_ID" >/dev/null 2>&1
ok "Project ID : ${PROJECT_ID}"

if gcloud services enable compute.googleapis.com >/dev/null 2>&1; then ok "Compute Engine API enabled"
else warn "Could not confirm Compute API (continuing)"; fi

# ---------- Wait for the lab's own provisioning ----------
step "Detecting lab regions and zone"
if ! net_exists mynetwork; then
  info "mynetwork not visible yet - the lab may still be provisioning. Waiting up to 60s..."
  for i in 1 2 3 4 5 6; do
    sleep 10
    net_exists mynetwork && { ok "mynetwork appeared"; break; }
  done
fi

Z1=""; Z2=""
for i in 1 2 3; do
  Z1=$(gcloud compute instances list --filter="name=mynet-vm-1" --format="value(zone.basename())" 2>/dev/null | head -n1)
  Z2=$(gcloud compute instances list --filter="name=mynet-vm-2" --format="value(zone.basename())" 2>/dev/null | head -n1)
  [[ -n "$Z1" && -n "$Z2" ]] && break
  sleep 5
done

ZONE="$Z1"
REGION_1="${Z1%-*}"
REGION_2="${Z2%-*}"
if [[ -z "$ZONE" ]]; then
  ZONE=$(gcloud config get-value compute/zone 2>/dev/null)
  [[ "$ZONE" == "(unset)" ]] && ZONE=""
  REGION_1="${ZONE%-*}"
fi
[[ -z "$REGION_1" ]] && REGION_1=$(gcloud config get-value compute/region 2>/dev/null) && [[ "$REGION_1" == "(unset)" ]] && REGION_1=""

[[ -n "$REGION_1" ]] && info "Region 1 : $REGION_1"
[[ -n "$REGION_2" ]] && info "Region 2 : $REGION_2"
[[ -n "$ZONE"     ]] && info "Zone     : $ZONE"

MANUAL=0
if [[ -n "$REGION_1" && -n "$REGION_2" && -n "$ZONE" ]]; then
  echo
  printf "  ${G}All values detected automatically.${N} Starting in 10s - press any key to change them.\n"
  if (( HAS_TTY )) && read -r -t 10 -n 1 -s _ </dev/tty 2>/dev/null; then MANUAL=1; fi
else
  MANUAL=1
  warn "Some values could not be detected. Copy them from the 'Lab setup and access' panel."
fi

if (( MANUAL )); then
  echo
  while true; do ask "Region 1 (e.g. us-east1)" "$REGION_1"; REGION_1="$REPLY_VAL"
    gcloud compute regions describe "$REGION_1" >/dev/null 2>&1 && break || err "Invalid region, try again."; done
  while true; do ask "Region 2 (e.g. europe-west1)" "$REGION_2"; REGION_2="$REPLY_VAL"
    gcloud compute regions describe "$REGION_2" >/dev/null 2>&1 && break || err "Invalid region, try again."; done
  while true; do ask "Zone (inside Region 1, e.g. ${REGION_1}-c)" "$ZONE"; ZONE="$REPLY_VAL"
    if [[ "$ZONE" == "${REGION_1}-"* ]] && gcloud compute zones describe "$ZONE" >/dev/null 2>&1; then break
    else err "Zone must be valid and belong to ${REGION_1}."; fi; done
fi

# safety net: zones must match regions
if [[ "$ZONE" != "${REGION_1}-"* ]]; then err "Zone ($ZONE) is not inside $REGION_1. Re-run the script."; exit 1; fi
ZONE2="${Z2:-$(gcloud compute zones list --filter="name~^${REGION_2}- AND status=UP" --format='value(name)' 2>/dev/null | sort | head -n1)}"

gcloud config set compute/region "$REGION_1" >/dev/null 2>&1
gcloud config set compute/zone "$ZONE" >/dev/null 2>&1

echo
line
printf "  ${W}Project  :${N} %s\n  ${W}Region 1 :${N} %s\n  ${W}Region 2 :${N} %s\n  ${W}Zone     :${N} %s\n" \
  "$PROJECT_ID" "$REGION_1" "$REGION_2" "$ZONE"
line

# =====================================================================
# BUILD  (idempotent - safe to run many times)
# =====================================================================
build() {
  FAILED=()

  banner "PRE-CHECK • mynetwork resources"
  if net_exists mynetwork; then
    ok "mynetwork already exists"
  else
    warn "mynetwork is missing - creating it (auto mode, same as the lab setup)"
    run "Create network mynetwork" gcloud compute networks create mynetwork --subnet-mode=auto
    run "Create rule mynetwork-allow-icmp" gcloud compute firewall-rules create mynetwork-allow-icmp \
      --network=mynetwork --direction=INGRESS --priority=65534 --action=ALLOW --rules=icmp --source-ranges=0.0.0.0/0
    run "Create rule mynetwork-allow-ssh" gcloud compute firewall-rules create mynetwork-allow-ssh \
      --network=mynetwork --direction=INGRESS --priority=65534 --action=ALLOW --rules=tcp:22 --source-ranges=0.0.0.0/0
    run "Create rule mynetwork-allow-rdp" gcloud compute firewall-rules create mynetwork-allow-rdp \
      --network=mynetwork --direction=INGRESS --priority=65534 --action=ALLOW --rules=tcp:3389 --source-ranges=0.0.0.0/0
  fi
  wait_for "mynetwork subnet in $REGION_1" gcloud compute networks subnets describe mynetwork --region="$REGION_1"
  vm_create mynet-vm-1 "$REGION_1" "$ZONE"  --machine-type=e2-micro --network=mynetwork --subnet=mynetwork
  if [[ -n "$REGION_2" ]]; then
    wait_for "mynetwork subnet in $REGION_2" gcloud compute networks subnets describe mynetwork --region="$REGION_2"
    vm_create mynet-vm-2 "$REGION_2" "$ZONE2" --machine-type=e2-micro --network=mynetwork --subnet=mynetwork
  fi

  banner "TASK 1 • Custom VPC networks + firewall rules"
  step "managementnet"
  run "Create network managementnet" gcloud compute networks create managementnet --subnet-mode=custom
  wait_for "managementnet" gcloud compute networks describe managementnet
  run "Create subnet managementsubnet-1 ($REGION_1)" gcloud compute networks subnets create managementsubnet-1 \
    --network=managementnet --region="$REGION_1" --range=10.130.0.0/20

  step "privatenet"
  run "Create network privatenet" gcloud compute networks create privatenet --subnet-mode=custom
  wait_for "privatenet" gcloud compute networks describe privatenet
  run "Create subnet privatesubnet-1 ($REGION_1)" gcloud compute networks subnets create privatesubnet-1 \
    --network=privatenet --region="$REGION_1" --range=172.16.0.0/24
  run "Create subnet privatesubnet-2 ($REGION_2)" gcloud compute networks subnets create privatesubnet-2 \
    --network=privatenet --region="$REGION_2" --range=172.20.0.0/20

  step "Firewall rules"
  run "Create rule managementnet-allow-icmp-ssh-rdp" gcloud compute firewall-rules create managementnet-allow-icmp-ssh-rdp \
    --direction=INGRESS --priority=1000 --network=managementnet --action=ALLOW \
    --rules=icmp,tcp:22,tcp:3389 --source-ranges=0.0.0.0/0
  run "Create rule privatenet-allow-icmp-ssh-rdp" gcloud compute firewall-rules create privatenet-allow-icmp-ssh-rdp \
    --direction=INGRESS --priority=1000 --network=privatenet --action=ALLOW \
    --rules=icmp,tcp:22,tcp:3389 --source-ranges=0.0.0.0/0

  banner "TASK 2 • VM instances"
  vm_create managementnet-vm-1 "$REGION_1" "$ZONE" --machine-type=e2-micro \
    --network=managementnet --subnet=managementsubnet-1
  vm_create privatenet-vm-1 "$REGION_1" "$ZONE" --machine-type=e2-micro \
    --network=privatenet --subnet=privatesubnet-1

  banner "TASK 4 • VM with multiple network interfaces"
  wait_for "privatesubnet-1"    gcloud compute networks subnets describe privatesubnet-1    --region="$REGION_1"
  wait_for "managementsubnet-1" gcloud compute networks subnets describe managementsubnet-1 --region="$REGION_1"
  wait_for "mynetwork subnet"   gcloud compute networks subnets describe mynetwork          --region="$REGION_1"
  vm_create vm-appliance "$REGION_1" "$ZONE" --machine-type=e2-standard-4 \
    --network-interface=network=privatenet,subnet=privatesubnet-1 \
    --network-interface=network=managementnet,subnet=managementsubnet-1 \
    --network-interface=network=mynetwork,subnet=mynetwork
}

# =====================================================================
# AUDIT  (mirrors the lab's "Check my progress" buttons)
# =====================================================================
PASS=0; FAILN=0
check() {  # check "label" test_function args...
  local label="$1"; shift
  if "$@"; then printf "  ${G}✔${N} %s\n" "$label"; ((PASS++))
  else printf "  ${R}✘${N} %s\n" "$label"; ((FAILN++)); fi
}
t_net_custom() { net_exists "$1" && [[ "$(gcloud compute networks describe "$1" --format='value(autoCreateSubnetworks)' 2>/dev/null)" != "True" ]]; }
t_subnet() { [[ "$(gcloud compute networks subnets describe "$1" --region="$2" --format='value(ipCidrRange)' 2>/dev/null)" == "$3" ]]; }
t_fw() {
  local j; j=$(gcloud compute firewall-rules describe "$1" --format=json 2>/dev/null | tr -d ' \n')
  [[ "$j" == *"/networks/$2\""* && "$j" == *'"IPProtocol":"icmp"'* && "$j" == *'"22"'* && "$j" == *'"3389"'* ]]
}
t_vm() {  # t_vm NAME MACHINETYPE SUBNET...
  local name="$1" mt="$2" j s; shift 2
  j=$(gcloud compute instances list --filter="name=$name" --format=json 2>/dev/null | tr -d ' \n')
  [[ -n "$j" && "$j" != "[]" && "$j" == *"machineTypes/$mt\""* ]] || return 1
  for s in "$@"; do [[ "$j" == *"/subnetworks/$s\""* ]] || return 1; done
  return 0
}
audit() {
  PASS=0; FAILN=0
  banner "AUDIT • Checking every lab checkpoint"
  check "Task 1 • Create the managementnet network (custom mode)"       t_net_custom managementnet
  check "Task 1 •   managementsubnet-1 = 10.130.0.0/20 ($REGION_1)"     t_subnet managementsubnet-1 "$REGION_1" 10.130.0.0/20
  check "Task 1 • Create the privatenet network (custom mode)"          t_net_custom privatenet
  check "Task 1 •   privatesubnet-1 = 172.16.0.0/24 ($REGION_1)"        t_subnet privatesubnet-1 "$REGION_1" 172.16.0.0/24
  check "Task 1 •   privatesubnet-2 = 172.20.0.0/20 ($REGION_2)"        t_subnet privatesubnet-2 "$REGION_2" 172.20.0.0/20
  check "Task 1 • Firewall rules for managementnet"                     t_fw managementnet-allow-icmp-ssh-rdp managementnet
  check "Task 1 • Firewall rules for privatenet"                        t_fw privatenet-allow-icmp-ssh-rdp privatenet
  check "Task 2 • managementnet-vm-1 (e2-micro, managementsubnet-1)"    t_vm managementnet-vm-1 e2-micro managementsubnet-1
  check "Task 2 • privatenet-vm-1 (e2-micro, privatesubnet-1)"          t_vm privatenet-vm-1 e2-micro privatesubnet-1
  check "Task 4 • vm-appliance (e2-standard-4, 3 NICs)"                 t_vm vm-appliance e2-standard-4 privatesubnet-1 managementsubnet-1 mynetwork
  echo
  info "Passed: ${PASS}   Failed: ${FAILN}"
}

# =====================================================================
# MAIN LOOP - build, audit, self-heal
# =====================================================================
ALL_OK=0
for pass in 1 2 3; do
  banner "BUILD • pass ${pass} of 3"
  build
  audit
  if (( FAILN == 0 )); then ALL_OK=1; break; fi
  if (( pass < 3 )); then
    warn "Some checks failed - self-healing: rebuilding in 10s..."
    sleep 10
  fi
done

# ---------- Final overview ----------
banner "OVERVIEW"
echo "  ${W}Lab networks${N}"
show 'gcloud compute networks list --format="table(name,x_gcloud_subnet_mode:label=MODE)"' 'gcloud compute networks list'
echo; echo "  ${W}Lab VMs${N}"
show 'gcloud compute instances list --sort-by=ZONE --format="table(name,zone.basename(),machineType.basename(),networkInterfaces[0].networkIP:label=INTERNAL_IP,networkInterfaces[0].accessConfigs[0].natIP:label=EXTERNAL_IP,status)"' 'gcloud compute instances list --sort-by=ZONE'
echo; echo "  ${W}vm-appliance interfaces${N}"
gcloud compute instances list --filter="name=vm-appliance" \
  --format="table(networkInterfaces[].name:label=NIC, networkInterfaces[].network.basename():label=NETWORK, networkInterfaces[].networkIP:label=INTERNAL_IP)" 2>/dev/null

# ---------- Summary ----------
ELAPSED=$(( $(date +%s) - START_TS ))
banner "SUMMARY"
if (( ALL_OK )); then
  ok "ALL ${PASS} CHECKPOINTS PASSED in ${ELAPSED}s 🎉"
  echo
  info "Now click 'Check my progress' on every task in the lab page."
  echo
  printf "  ${Y}Task 3 quiz (answer manually in the lab page):${N}\n"
  printf "  Which instance(s) can mynet-region-1-vm ping using internal IP?\n"
  printf "  ${G}➜ Answer: mynet-region-2-vm   (same VPC network: mynetwork)${N}\n"
else
  err "${FAILN} checkpoint(s) still failing after 3 passes."
  for f in "${FAILED[@]}"; do printf "    ${R}- %s${N}\n" "$f"; done
  echo
  warn "Run the script once more. If it still fails, take a screenshot of this output and share it."
fi
echo
