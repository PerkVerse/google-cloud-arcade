#!/bin/bash
# ===== VPC Networks Lab: Auto Setup =====

G='\033[1;32m'; R='\033[1;31m'; Y='\033[1;33m'; B='\033[1;36m'; N='\033[0m'
step(){ echo -e "\n${B}━━━ $1 ━━━${N}"; }

# Runs a command, retries up to 3 times, treats "already exists" / "not found" as OK
run(){
  local desc="$1"; shift; local out
  for i in 1 2 3; do
    if out=$("$@" 2>&1); then echo -e "  ${G}✔${N} $desc"; return 0; fi
    if echo "$out" | grep -qiE "already exists|was not found|notFound"; then
      echo -e "  ${Y}↷${N} $desc (skipped: already done / not present)"; return 0; fi
    echo -e "  ${Y}…${N} $desc failed, retry $i/3"; sleep 6
  done
  echo -e "  ${R}✘${N} $desc\n    $(echo "$out" | tail -n 3)"; return 1
}

# ---------- Auto-detect project / region / zone ----------
step "Detecting environment"
PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
[ -z "$PROJECT_ID" ] && PROJECT_ID=$(gcloud projects list --format="value(projectId)" --limit=1)
gcloud config set project "$PROJECT_ID" >/dev/null 2>&1

meta(){ gcloud compute project-info describe --format="value(commonInstanceMetadata.items[$1])" 2>/dev/null; }

ZONE1=${ZONE1:-$(meta google-compute-default-zone)}
REGION1=${REGION1:-$(meta google-compute-default-region)}
[ -z "$ZONE1" ]   && ZONE1=$(gcloud config get-value compute/zone 2>/dev/null)
[ -z "$REGION1" ] && REGION1=$(gcloud config get-value compute/region 2>/dev/null)
[ -z "$REGION1" ] && [ -n "$ZONE1" ] && REGION1=${ZONE1%-*}
[ -z "$ZONE1" ]   && ZONE1=$(gcloud compute zones list --filter="region:$REGION1 AND status=UP" --format="value(name)" --limit=1)

# Region 2 / Zone 2 are shown in the lab panel. Override like: REGION2=europe-west4 ZONE2=europe-west4-a bash
if [ -z "$REGION2" ]; then
  case "$REGION1" in europe-*) REGION2="asia-east1";; *) REGION2="europe-west1";; esac
fi
[ -z "$ZONE2" ] && ZONE2=$(gcloud compute zones list --filter="region:$REGION2 AND status=UP" --format="value(name)" --limit=1)

echo -e "  Project : ${G}$PROJECT_ID${N}"
echo -e "  Region 1: ${G}$REGION1${N}   Zone 1: ${G}$ZONE1${N}"
echo -e "  Region 2: ${G}$REGION2${N}   Zone 2: ${G}$ZONE2${N}"
echo -e "  ${Y}(If Region 2 / Zone 2 differ from your lab panel, re-run with REGION2=... ZONE2=...)${N}"

IMG="--image-family=debian-12 --image-project=debian-cloud"

# ---------- Task 1: Delete default network ----------
step "Task 1: Removing default firewall rules and network"
run "Enable APIs" gcloud services enable compute.googleapis.com iap.googleapis.com networkmanagement.googleapis.com
for fw in $(gcloud compute firewall-rules list --filter="network:default" --format="value(name)" 2>/dev/null); do
  run "Delete firewall rule $fw" gcloud compute firewall-rules delete "$fw" --quiet
done
run "Delete default network" gcloud compute networks delete default --quiet

# ---------- Task 2: Auto mode network ----------
step "Task 2: Creating auto mode network 'mynetwork'"
run "Create mynetwork (auto)" gcloud compute networks create mynetwork --subnet-mode=auto
run "Firewall: allow-custom" gcloud compute firewall-rules create mynetwork-allow-custom --network=mynetwork --direction=INGRESS --priority=65534 --action=ALLOW --rules=all --source-ranges=10.128.0.0/9
run "Firewall: allow-icmp"   gcloud compute firewall-rules create mynetwork-allow-icmp   --network=mynetwork --direction=INGRESS --priority=65534 --action=ALLOW --rules=icmp --source-ranges=0.0.0.0/0
run "Firewall: allow-rdp"    gcloud compute firewall-rules create mynetwork-allow-rdp    --network=mynetwork --direction=INGRESS --priority=65534 --action=ALLOW --rules=tcp:3389 --source-ranges=0.0.0.0/0
run "Firewall: allow-ssh"    gcloud compute firewall-rules create mynetwork-allow-ssh    --network=mynetwork --direction=INGRESS --priority=65534 --action=ALLOW --rules=tcp:22 --source-ranges=0.0.0.0/0
run "Firewall: allow-iap-ssh" gcloud compute firewall-rules create allow-iap-ssh --network=mynetwork --direction=INGRESS --priority=1000 --action=ALLOW --rules=tcp:22 --source-ranges=35.235.240.0/20 --target-tags=iap-gce

run "VM mynet-us-vm"    gcloud compute instances create mynet-us-vm    --zone="$ZONE1" --machine-type=e2-medium --network=mynetwork --subnet=mynetwork --tags=iap-gce $IMG
run "VM mynet-notus-vm" gcloud compute instances create mynet-notus-vm --zone="$ZONE2" --machine-type=e2-medium --network=mynetwork --subnet=mynetwork --tags=iap-gce $IMG

run "Convert mynetwork to custom mode" gcloud compute networks update mynetwork --switch-to-custom-subnet-mode --quiet

# ---------- Task 3: Custom mode networks ----------
step "Task 3: Creating managementnet and privatenet"
run "Create managementnet" gcloud compute networks create managementnet --subnet-mode=custom
run "Subnet managementsubnet-us" gcloud compute networks subnets create managementsubnet-us --network=managementnet --region="$REGION1" --range=10.240.0.0/20
run "Firewall managementnet" gcloud compute firewall-rules create managementnet-allow-icmp-ssh-rdp --network=managementnet --direction=INGRESS --priority=1000 --action=ALLOW --rules=tcp:22,tcp:3389,icmp --source-ranges=0.0.0.0/0

run "Create privatenet" gcloud compute networks create privatenet --subnet-mode=custom
run "Subnet privatesubnet-us"    gcloud compute networks subnets create privatesubnet-us    --network=privatenet --region="$REGION1" --range=172.16.0.0/24
run "Subnet privatesubnet-notus" gcloud compute networks subnets create privatesubnet-notus --network=privatenet --region="$REGION2" --range=172.20.0.0/20
run "Firewall privatenet" gcloud compute firewall-rules create privatenet-allow-icmp-ssh-rdp --network=privatenet --direction=INGRESS --priority=1000 --action=ALLOW --rules=icmp,tcp:22,tcp:3389 --source-ranges=0.0.0.0/0

run "VM managementnet-us-vm" gcloud compute instances create managementnet-us-vm --zone="$ZONE1" --machine-type=e2-micro --subnet=managementsubnet-us $IMG
run "VM privatenet-us-vm"    gcloud compute instances create privatenet-us-vm    --zone="$ZONE1" --machine-type=e2-micro --subnet=privatesubnet-us $IMG \
  --boot-disk-size=10GB --boot-disk-type=pd-standard --boot-disk-device-name=privatenet-us-vm

# ---------- Verify ----------
step "Summary"
gcloud compute networks list
echo; gcloud compute networks subnets list --filter="network~mynetwork OR network~managementnet OR network~privatenet" --sort-by=NETWORK --format="table(name,region.basename(),network.basename(),ipCidrRange)"
echo; gcloud compute firewall-rules list --sort-by=NETWORK --format="table(name,network.basename(),direction,priority,allowed[].map().firewall_rule().list():label=ALLOW)"
echo; gcloud compute instances list --sort-by=ZONE
echo -e "\n${G}✔ All done. Now click 'Check my progress' for each task in the lab page.${N}"
