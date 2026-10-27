#!/bin/bash
# =====================================================================
#  GSP211 - Create and Configure Multiple VPC Networks (Full Lab)
#  Run in Google Cloud Shell:   bash gsp211_fixed.sh
#  - Auto-detects project, asks Region/Zone
#  - Auto-creates mynetwork + mynet-vm-1/2 if the lab did not provide them
#  - Retries every step up to 15 times
# =====================================================================

# ---------- Colors ----------
R=$'\e[1;31m'; G=$'\e[1;32m'; Y=$'\e[1;33m'; B=$'\e[1;34m'
M=$'\e[1;35m'; C=$'\e[1;36m'; D=$'\e[2m'; W=$'\e[1;37m'; N=$'\e[0m'

MAX_RETRIES=15
RETRY_DELAY=6
FAILED=()
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
run() {
  local desc="$1"; shift
  local attempt=1 out
  printf "  ${C}➜${N} %s\n" "$desc"
  printf "    ${D}\$ %s${N}\n" "$*"
  while (( attempt <= MAX_RETRIES )); do
    if out=$("$@" 2>&1); then
      ok "Done"
      return 0
    fi
    if grep -qiE "already exists" <<<"$out"; then
      warn "Already exists - skipping (OK)"
      return 0
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

# ---------- Wait until a resource is visible ----------
# usage: wait_for "Description" command arg1 arg2 ...
wait_for() {
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

# ---------- Table helper (pretty format, fallback to plain) ----------
show() {  # show "<pretty cmd>" "<fallback cmd>"
  eval "$1" 2>/dev/null || eval "$2"
}

# ---------- Banner ----------
clear
banner "GSP211 • Create and Configure Multiple VPC Networks"

# ---------- Auto-detect project ----------
step "Detecting project"
PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
[[ -z "$PROJECT_ID" || "$PROJECT_ID" == "(unset)" ]] && PROJECT_ID="$DEVSHELL_PROJECT_ID"
if [[ -z "$PROJECT_ID" ]]; then
  read -r -p "  Project ID not detected. Enter it: " PROJECT_ID
fi
gcloud config set project "$PROJECT_ID" >/dev/null 2>&1
ok "Project ID : ${PROJECT_ID}"

# ---------- Auto-detect defaults ----------
step "Detecting lab regions/zones"
Z1=$(gcloud compute instances list --filter="name=mynet-vm-1" --format="value(zone.basename())" 2>/dev/null | head -n1)
Z2=$(gcloud compute instances list --filter="name=mynet-vm-2" --format="value(zone.basename())" 2>/dev/null | head -n1)
DEF_ZONE="${Z1:-$(gcloud config get-value compute/zone 2>/dev/null)}"
DEF_R1="${Z1%-*}"
[[ -z "$DEF_R1" ]] && DEF_R1="$(gcloud config get-value compute/region 2>/dev/null)"
DEF_R2="${Z2%-*}"
[[ -n "$DEF_R1" ]] && info "Detected Region 1 : $DEF_R1"
[[ -n "$DEF_R2" ]] && info "Detected Region 2 : $DEF_R2"
[[ -n "$DEF_ZONE" ]] && info "Detected Zone     : $DEF_ZONE"
[[ -z "$Z1" ]] && warn "mynet-vm-1 not found (will be created automatically if needed)"

# ---------- User input ----------
banner "Enter Lab Values (see 'Lab setup and access' panel)"
echo "  Press ENTER to accept the [detected] default."
echo

ask() {  # ask "Prompt" "default" -> sets REPLY_VAL
  local p="$1" d="$2" v
  if [[ -n "$d" ]]; then read -r -p "  ${W}${p}${N} [${G}${d}${N}]: " v; v="${v:-$d}"
  else read -r -p "  ${W}${p}${N}: " v; fi
  v="${v//[[:space:]\\]/}"   # strip spaces and stray backslashes
  REPLY_VAL="$v"
}

while true; do ask "Region 1 (e.g. us-east1)" "$DEF_R1"; REGION_1="$REPLY_VAL"
  gcloud compute regions describe "$REGION_1" >/dev/null 2>&1 && break || err "Invalid region, try again."; done

while true; do ask "Region 2 (e.g. asia-east1)" "$DEF_R2"; REGION_2="$REPLY_VAL"
  gcloud compute regions describe "$REGION_2" >/dev/null 2>&1 && break || err "Invalid region, try again."; done

while true; do ask "Zone (inside Region 1, e.g. ${REGION_1}-c)" "$DEF_ZONE"; ZONE="$REPLY_VAL"
  if [[ "$ZONE" == "${REGION_1}-"* ]] && gcloud compute zones describe "$ZONE" >/dev/null 2>&1; then break
  else err "Zone must be valid and belong to ${REGION_1}."; fi; done

# Zone for mynet-vm-2 (only needed if it must be created)
ZONE2="${Z2:-$(gcloud compute zones list --filter="name~^${REGION_2}-" --format='value(name)' 2>/dev/null | sort | head -n1)}"

gcloud config set compute/region "$REGION_1" >/dev/null 2>&1
gcloud config set compute/zone "$ZONE" >/dev/null 2>&1

echo
line
printf "  ${W}Project  :${N} %s\n  ${W}Region 1 :${N} %s\n  ${W}Region 2 :${N} %s\n  ${W}Zone     :${N} %s\n" \
  "$PROJECT_ID" "$REGION_1" "$REGION_2" "$ZONE"
line
read -r -p "  Start the lab automation? [Y/n]: " GO
[[ "$GO" =~ ^[Nn]$ ]] && { err "Cancelled."; exit 1; }

# =====================================================================
# PRE-CHECK - mynetwork and its VMs (normally pre-created by the lab)
# =====================================================================
banner "PRE-CHECK • mynetwork resources"

if gcloud compute networks describe mynetwork >/dev/null 2>&1; then
  ok "mynetwork already exists"
else
  warn "mynetwork is missing - creating it (auto mode, same as the lab setup)"
  run "Create network mynetwork" \
    gcloud compute networks create mynetwork --subnet-mode=auto
  run "Create rule mynetwork-allow-icmp" \
    gcloud compute firewall-rules create mynetwork-allow-icmp \
      --network=mynetwork --direction=INGRESS --priority=65534 --action=ALLOW \
      --rules=icmp --source-ranges=0.0.0.0/0
  run "Create rule mynetwork-allow-ssh" \
    gcloud compute firewall-rules create mynetwork-allow-ssh \
      --network=mynetwork --direction=INGRESS --priority=65534 --action=ALLOW \
      --rules=tcp:22 --source-ranges=0.0.0.0/0
  run "Create rule mynetwork-allow-rdp" \
    gcloud compute firewall-rules create mynetwork-allow-rdp \
      --network=mynetwork --direction=INGRESS --priority=65534 --action=ALLOW \
      --rules=tcp:3389 --source-ranges=0.0.0.0/0
fi

wait_for "mynetwork subnet in $REGION_1" \
  gcloud compute networks subnets describe mynetwork --region="$REGION_1"
wait_for "mynetwork subnet in $REGION_2" \
  gcloud compute networks subnets describe mynetwork --region="$REGION_2"

if [[ -z "$(gcloud compute instances list --filter='name=mynet-vm-1' --format='value(name)' 2>/dev/null)" ]]; then
  run "Create mynet-vm-1 ($ZONE)" \
    gcloud compute instances create mynet-vm-1 \
      --zone="$ZONE" --machine-type=e2-micro \
      --network=mynetwork --subnet=mynetwork
else
  ok "mynet-vm-1 already exists"
fi

if [[ -z "$(gcloud compute instances list --filter='name=mynet-vm-2' --format='value(name)' 2>/dev/null)" ]]; then
  run "Create mynet-vm-2 ($ZONE2)" \
    gcloud compute instances create mynet-vm-2 \
      --zone="$ZONE2" --machine-type=e2-micro \
      --network=mynetwork --subnet=mynetwork
else
  ok "mynet-vm-2 already exists"
fi

# =====================================================================
# TASK 1 - Networks and firewall rules
# =====================================================================
banner "TASK 1 • Custom VPC networks + firewall rules"

step "managementnet"
run "Create network managementnet" \
  gcloud compute networks create managementnet --subnet-mode=custom
run "Create subnet managementsubnet-1 ($REGION_1)" \
  gcloud compute networks subnets create managementsubnet-1 \
    --network=managementnet --region="$REGION_1" --range=10.130.0.0/20

step "privatenet"
run "Create network privatenet" \
  gcloud compute networks create privatenet --subnet-mode=custom
run "Create subnet privatesubnet-1 ($REGION_1)" \
  gcloud compute networks subnets create privatesubnet-1 \
    --network=privatenet --region="$REGION_1" --range=172.16.0.0/24
run "Create subnet privatesubnet-2 ($REGION_2)" \
  gcloud compute networks subnets create privatesubnet-2 \
    --network=privatenet --region="$REGION_2" --range=172.20.0.0/20

step "Firewall rules"
run "Create rule managementnet-allow-icmp-ssh-rdp" \
  gcloud compute firewall-rules create managementnet-allow-icmp-ssh-rdp \
    --direction=INGRESS --priority=1000 --network=managementnet --action=ALLOW \
    --rules=icmp,tcp:22,tcp:3389 --source-ranges=0.0.0.0/0
run "Create rule privatenet-allow-icmp-ssh-rdp" \
  gcloud compute firewall-rules create privatenet-allow-icmp-ssh-rdp \
    --direction=INGRESS --priority=1000 --network=privatenet --action=ALLOW \
    --rules=icmp,tcp:22,tcp:3389 --source-ranges=0.0.0.0/0

step "Verification"
echo "  ${W}Networks${N}"
show 'gcloud compute networks list --format="table(name,x_gcloud_subnet_mode:label=MODE)"' \
     'gcloud compute networks list'
echo; echo "  ${W}Lab subnets${N}"
show 'gcloud compute networks subnets list --filter="name~managementsubnet|privatesubnet|^mynetwork$ AND (region~'"$REGION_1"'|region~'"$REGION_2"')" --sort-by=NETWORK --format="table(name,region.basename(),network.basename(),ipCidrRange)"' \
     'gcloud compute networks subnets list --sort-by=NETWORK'
echo; echo "  ${W}Lab firewall rules${N}"
show 'gcloud compute firewall-rules list --filter="network~managementnet|privatenet|mynetwork" --sort-by=NETWORK --format="table(name,network.basename(),priority,allowed[].map().firewall_rule().list():label=ALLOW)"' \
     'gcloud compute firewall-rules list --sort-by=NETWORK'

# =====================================================================
# TASK 2 - VM instances
# =====================================================================
banner "TASK 2 • VM instances"

run "Create managementnet-vm-1 ($ZONE)" \
  gcloud compute instances create managementnet-vm-1 \
    --zone="$ZONE" --machine-type=e2-micro \
    --network=managementnet --subnet=managementsubnet-1

run "Create privatenet-vm-1 ($ZONE)" \
  gcloud compute instances create privatenet-vm-1 \
    --zone="$ZONE" --machine-type=e2-micro \
    --network=privatenet --subnet=privatesubnet-1

step "Instances list"
show 'gcloud compute instances list --sort-by=ZONE --format="table(name,zone.basename(),machineType.basename(),networkInterfaces[0].networkIP:label=INTERNAL_IP,networkInterfaces[0].accessConfigs[0].natIP:label=EXTERNAL_IP,status)"' \
     'gcloud compute instances list --sort-by=ZONE'

# =====================================================================
# TASK 4 - Multi-NIC VM
# =====================================================================
banner "TASK 4 • VM with multiple network interfaces"

step "Checking all 3 subnets are ready"
wait_for "privatesubnet-1"    gcloud compute networks subnets describe privatesubnet-1    --region="$REGION_1"
wait_for "managementsubnet-1" gcloud compute networks subnets describe managementsubnet-1 --region="$REGION_1"
wait_for "mynetwork subnet"   gcloud compute networks subnets describe mynetwork          --region="$REGION_1"

run "Create vm-appliance (3 NICs, e2-standard-4)" \
  gcloud compute instances create vm-appliance \
    --zone="$ZONE" --machine-type=e2-standard-4 \
    --network-interface=network=privatenet,subnet=privatesubnet-1 \
    --network-interface=network=managementnet,subnet=managementsubnet-1 \
    --network-interface=network=mynetwork,subnet=mynetwork

step "vm-appliance interfaces"
gcloud compute instances describe vm-appliance --zone="$ZONE" \
  --format="table(networkInterfaces[].name:label=NIC, networkInterfaces[].network.basename():label=NETWORK, networkInterfaces[].networkIP:label=INTERNAL_IP)" 2>/dev/null

# =====================================================================
# Summary
# =====================================================================
ELAPSED=$(( $(date +%s) - START_TS ))
banner "SUMMARY"
if (( ${#FAILED[@]} == 0 )); then
  ok "All tasks completed successfully in ${ELAPSED}s 🎉"
  echo
  info "Now go to the lab page and click 'Check my progress' on each task."
else
  err "Some steps failed:"
  for f in "${FAILED[@]}"; do printf "    ${R}- %s${N}\n" "$f"; done
  echo
  warn "Re-run the script: finished resources are skipped automatically."
fi
echo
info "Task 3 (ping tests) is exploration only - SSH into mynet-vm-1 / vm-appliance from the console if you want to try it."
echo
