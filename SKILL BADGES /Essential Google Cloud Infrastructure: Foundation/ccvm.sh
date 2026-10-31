#!/bin/bash
# ============================================================
#  Create and Configure Virtual Machines (Minecraft Server Lab)
# ============================================================

# ---------- Auto-detect project, region, zone ----------
PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
[ -z "$PROJECT_ID" ] && PROJECT_ID=$(gcloud projects list --format="value(projectId)" --limit=1)

ZONE=$(gcloud config get-value compute/zone 2>/dev/null)
# The lab requires us-west1-b, so use it unless the detected zone is already in us-west1
case "$ZONE" in us-west1-*) ;; *) ZONE="us-west1-b" ;; esac
REGION="${ZONE%-*}"

gcloud config set project "$PROJECT_ID" -q >/dev/null 2>&1
gcloud config set compute/zone "$ZONE" -q >/dev/null 2>&1
gcloud config set compute/region "$REGION" -q >/dev/null 2>&1

VM="mc-server"; DISK="minecraft-disk"; IP_NAME="mc-server-ip"
BUCKET="${PROJECT_ID}-minecraft-backup"

# ---------- Helpers ----------
G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; B='\033[1;36m'; N='\033[0m'
step(){ echo -e "\n${B}==> $*${N}"; }
ok(){   echo -e "${G}[ OK ]${N} $*"; }
warn(){ echo -e "${Y}[WARN]${N} $*"; }

# retry <attempts> <command...> : retries on failure, waits 10s between tries
retry(){
  local n=$1; shift
  for ((i=1;i<=n;i++)); do
    "$@" && return 0
    warn "Attempt $i/$n failed, retrying in 10s..."; sleep 10
  done
  echo -e "${R}[FAIL]${N} $*"; return 1
}

echo -e "${B}Project: $PROJECT_ID | Region: $REGION | Zone: $ZONE${N}"

# ---------- Task 1: Create the VM ----------
step "Task 1: Creating static IP and VM"
gcloud services enable compute.googleapis.com storage.googleapis.com -q 2>/dev/null

gcloud compute addresses describe $IP_NAME --region=$REGION >/dev/null 2>&1 || \
  retry 3 gcloud compute addresses create $IP_NAME --region=$REGION -q
ok "Static IP ready"

if gcloud compute instances describe $VM --zone=$ZONE >/dev/null 2>&1; then
  warn "VM already exists, skipping creation"
else
  retry 3 gcloud compute instances create $VM \
    --zone=$ZONE \
    --machine-type=e2-medium \
    --image-family=debian-12 --image-project=debian-cloud \
    --tags=minecraft-server \
    --address=$IP_NAME \
    --scopes=storage-rw \
    --create-disk=name=$DISK,size=50GB,type=pd-ssd,auto-delete=yes,mode=rw,device-name=$DISK \
    -q
fi
ok "VM created"

# ---------- Task 4 (firewall, done early so SSH/test work) ----------
step "Task 4: Creating firewall rule"
gcloud compute firewall-rules describe minecraft-rule >/dev/null 2>&1 || \
  retry 3 gcloud compute firewall-rules create minecraft-rule \
    --network=default --direction=INGRESS --action=ALLOW \
    --rules=tcp:25565 --source-ranges=0.0.0.0/0 \
    --target-tags=minecraft-server -q
ok "Firewall rule ready"

# ---------- Create bucket (Task 5 prep) ----------
step "Creating Cloud Storage bucket"
gcloud storage buckets describe gs://$BUCKET >/dev/null 2>&1 || \
  retry 3 gcloud storage buckets create gs://$BUCKET --location=$REGION
ok "Bucket: gs://$BUCKET"

# ---------- Remote script (runs on the VM) ----------
cat > /tmp/remote.sh <<'REMOTE'
#!/bin/bash
set +e
echo "--- Task 2: Prepare data disk ---"
mkdir -p /home/minecraft
if ! blkid /dev/disk/by-id/google-minecraft-disk >/dev/null 2>&1; then
  mkfs.ext4 -F -E lazy_itable_init=0,lazy_journal_init=0,discard /dev/disk/by-id/google-minecraft-disk
fi
mountpoint -q /home/minecraft || mount -o discard,defaults /dev/disk/by-id/google-minecraft-disk /home/minecraft

echo "--- Task 3: Install Java, Minecraft, screen ---"
for i in 1 2 3; do apt-get update && break; sleep 5; done
for i in 1 2 3; do apt-get install -y default-jre-headless wget screen && break; sleep 5; done
cd /home/minecraft
[ -f server.jar ] || for i in 1 2 3; do
  wget -q https://launcher.mojang.com/v1/objects/d0d0fe2b1dc6ab4c65554cb734270872b72dadd6/server.jar && break; sleep 5
done
java -Xmx1024M -Xms1024M -jar server.jar nogui
sed -i 's/eula=false/eula=true/' eula.txt
screen -list | grep -q mcs || screen -dmS mcs java -Xmx1024M -Xms1024M -jar server.jar nogui
echo "Waiting for world folder..."
for i in $(seq 1 40); do [ -d /home/minecraft/world ] && break; sleep 5; done

echo "--- Task 5: Backup script and cron ---"
echo '#!/bin/bash' > /home/minecraft/backup.sh
echo "export YOUR_BUCKET_NAME=${BUCKET%-minecraft-backup}" >> /home/minecraft/backup.sh
cat >> /home/minecraft/backup.sh <<'EOF'
screen -r mcs -X stuff '/save-all\n/save-off\n'
/usr/bin/gcloud storage cp -R ${BASH_SOURCE%/*}/world gs://${YOUR_BUCKET_NAME}-minecraft-backup/$(date "+%Y%m%d-%H%M%S")-world
screen -r mcs -X stuff '/save-on\n'
EOF
chmod 755 /home/minecraft/backup.sh
bash /home/minecraft/backup.sh
(crontab -l 2>/dev/null | grep -v backup.sh; echo "0 */4 * * * /home/minecraft/backup.sh") | crontab -
crontab -l

echo "--- Task 6: Stop Minecraft server ---"
screen -r -X stuff '/stop\n'
sleep 10
REMOTE

# ---------- Run remote script over SSH ----------
step "Tasks 2, 3, 5: Configuring the VM over SSH (takes a few minutes)"
echo "Waiting for the VM to accept SSH..."
retry 12 gcloud compute ssh $VM --zone=$ZONE --quiet --command="echo SSH ready" 2>/dev/null

retry 3 gcloud compute ssh $VM --zone=$ZONE --quiet \
  --command="sudo BUCKET=$BUCKET bash -s" < /tmp/remote.sh
ok "VM configured and backup tested"

# ---------- Task 6: Maintenance ----------
step "Task 6: Stopping VM and adding startup/shutdown scripts"
retry 3 gcloud compute instances stop $VM --zone=$ZONE -q
retry 3 gcloud compute instances add-metadata $VM --zone=$ZONE \
  --metadata=startup-script-url=https://storage.googleapis.com/cloud-training/archinfra/mcserver/startup.sh,shutdown-script-url=https://storage.googleapis.com/cloud-training/archinfra/mcserver/shutdown.sh
ok "Metadata scripts added"

echo -e "\n${G}All tasks done. Now click 'Check my progress' on each task.${N}"
