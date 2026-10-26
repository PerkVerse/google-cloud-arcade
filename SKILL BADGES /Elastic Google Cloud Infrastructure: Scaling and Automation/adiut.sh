cat > ~/tf_lab.sh <<'LAB_SCRIPT'
#!/bin/bash
# ============================================================
#  Automating the Deployment of Infrastructure Using Terraform
#  Self-healing lab runner (max 20 retries per step)
# ============================================================
set +e
MAX_ATTEMPTS=20
LOG=/tmp/tf_run.log
WORKDIR="$HOME/tfinfra"
TF_VERSION="1.9.8"

C_B="\033[1;34m"; C_G="\033[1;32m"; C_Y="\033[1;33m"; C_R="\033[1;31m"; C_N="\033[0m"
step() { echo -e "\n${C_B}==> $*${C_N}"; sleep 2; }
ok()   { echo -e "${C_G}  [OK]  $*${C_N}"; }
warn() { echo -e "${C_Y}  [FIX] $*${C_N}"; }
fail() { echo -e "${C_R}  [ERR] $*${C_N}"; }

clear
echo -e "${C_B}Terraform Lab Runner${C_N}"

# ---------- 1. Project, region, zones ----------
step "Detecting project, region and zones"
PROJECT=$(gcloud config get-value project 2>/dev/null)
[ -z "$PROJECT" ] && PROJECT=$(gcloud projects list --format="value(projectId)" --limit=1 2>/dev/null)
gcloud config set project "$PROJECT" >/dev/null 2>&1

meta() {
  gcloud compute project-info describe --project "$PROJECT" \
    --format="value(commonInstanceMetadata.items[$1])" 2>/dev/null
}
gcloud services enable compute.googleapis.com --project "$PROJECT" >/dev/null 2>&1

DEF_ZONE=$(meta google-compute-default-zone)
[ -z "$DEF_ZONE" ] && DEF_ZONE=$(gcloud config get-value compute/zone 2>/dev/null)
REGION=$(meta google-compute-default-region)
[ -z "$REGION" ] && REGION=$(gcloud config get-value compute/region 2>/dev/null)
[ -z "$REGION" ] && [ -n "$DEF_ZONE" ] && REGION="${DEF_ZONE%-*}"
[ -z "$REGION" ] && REGION="us-central1"

zone_list() {
  gcloud compute zones list --filter="region:${REGION} AND status=UP" \
    --format="value(name)" 2>/dev/null | sort
}
mapfile -t ZONES < <(zone_list)
[ ${#ZONES[@]} -eq 0 ] && ZONES=("${REGION}-a" "${REGION}-b" "${REGION}-c")
[ -z "$ZONE1" ] && ZONE1="${DEF_ZONE:-${ZONES[0]}}"
if [ -z "$ZONE2" ]; then
  for z in "${ZONES[@]}"; do [ "$z" != "$ZONE1" ] && ZONE2="$z" && break; done
  [ -z "$ZONE2" ] && ZONE2="$ZONE1"
fi
export GOOGLE_PROJECT="$PROJECT" GOOGLE_CLOUD_PROJECT="$PROJECT" GOOGLE_REGION="$REGION"

if gcloud compute images describe-from-family debian-12 --project debian-cloud >/dev/null 2>&1; then
  IMAGE="debian-cloud/debian-12"
else
  IMAGE="debian-cloud/debian-11"
fi
ok "Project : $PROJECT"
ok "Region  : $REGION"
ok "Zone 1  : $ZONE1"
ok "Zone 2  : $ZONE2"
ok "Image   : $IMAGE"

# ---------- 2. Install real Terraform ----------
step "Installing Terraform"
export PATH="$HOME/bin:$PATH"; hash -r
real_tf() { terraform version 2>/dev/null | head -n1 | grep -q '^Terraform v'; }

install_tf() {
  real_tf && return 0
  local arch
  case "$(uname -m)" in aarch64|arm64) arch=arm64 ;; *) arch=amd64 ;; esac
  mkdir -p "$HOME/bin"
  rm -f /tmp/tf.zip
  curl -fsSL "https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_linux_${arch}.zip" -o /tmp/tf.zip || return 1
  if command -v unzip >/dev/null 2>&1; then
    unzip -o -q /tmp/tf.zip -d "$HOME/bin"
  else
    python3 -c "import zipfile,os; zipfile.ZipFile('/tmp/tf.zip').extractall(os.path.expanduser('~/bin'))"
  fi
  chmod +x "$HOME/bin/terraform"; hash -r
  real_tf
}

install_tf_apt() {
  cat <<'EOF' > ~/.customize_environment
wget -O - https://apt.releases.hashicorp.com/gpg | sudo gpg --yes --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(grep -oP '(?<=UBUNTU_CODENAME=).*' /etc/os-release || lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install -y terraform
EOF
  bash ~/.customize_environment >/tmp/tf_install.log 2>&1
  hash -r; real_tf
}

INSTALLED=0
for i in 1 2 3; do
  install_tf && INSTALLED=1 && break
  warn "Binary install retry $i/3"; sleep 4
done
if [ $INSTALLED -eq 0 ]; then
  warn "Trying apt install as a fallback"
  install_tf_apt && INSTALLED=1
fi
if [ $INSTALLED -eq 0 ]; then
  fail "Terraform could not be installed. Check internet access in Cloud Shell and run again."
  exit 1
fi
grep -q 'HOME/bin' ~/.bashrc 2>/dev/null || echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bashrc
ok "$(terraform version | head -n1)"

# ---------- 3. Write configuration files ----------
write_files() {
  mkdir -p "$WORKDIR/instance"

  cat > "$WORKDIR/provider.tf" <<'EOF'
provider "google" {}
EOF

  cat > "$WORKDIR/instance/variables.tf" <<'EOF'
variable "instance_name" {}
variable "instance_zone" {}
variable "instance_type" {
  default = "e2-micro"
}
variable "instance_network" {}
EOF

  cat > "$WORKDIR/instance/main.tf" <<EOF
resource "google_compute_instance" "vm_instance" {
  name         = var.instance_name
  zone         = var.instance_zone
  machine_type = var.instance_type
  boot_disk {
    initialize_params {
      image = "${IMAGE}"
    }
  }
  network_interface {
    network = var.instance_network
    access_config {
      # Allocate a one-to-one NAT IP to the instance
    }
  }
}
EOF

  cat > "$WORKDIR/mynetwork.tf" <<EOF
# Create the mynetwork network
resource "google_compute_network" "mynetwork" {
  name                    = "mynetwork"
  auto_create_subnetworks = true
}

# Add a firewall rule to allow HTTP, SSH, RDP and ICMP traffic on mynetwork
resource "google_compute_firewall" "mynetwork-allow-http-ssh-rdp-icmp" {
  name    = "mynetwork-allow-http-ssh-rdp-icmp"
  network = google_compute_network.mynetwork.self_link
  allow {
    protocol = "tcp"
    ports    = ["22", "80", "3389"]
  }
  allow {
    protocol = "icmp"
  }
  source_ranges = ["0.0.0.0/0"]
}

# Create the mynet-vm-1 instance
module "mynet-vm-1" {
  source           = "./instance"
  instance_name    = "mynet-vm-1"
  instance_zone    = "${ZONE1}"
  instance_network = google_compute_network.mynetwork.self_link
}

# Create the mynet-vm-2 instance
module "mynet-vm-2" {
  source           = "./instance"
  instance_name    = "mynet-vm-2"
  instance_zone    = "${ZONE2}"
  instance_network = google_compute_network.mynetwork.self_link
}
EOF
}

step "Creating Terraform configuration files"
write_files
cd "$WORKDIR" || exit 1
rm -rf .terraform .terraform.lock.hcl
ok "Files ready in $WORKDIR"

# ---------- 4. Self-healing helpers ----------
import_existing() {
  warn "Resources already exist, importing them into state"
  terraform state list 2>/dev/null | grep -q '^google_compute_network.mynetwork$' || \
    terraform import -no-color google_compute_network.mynetwork "projects/$PROJECT/global/networks/mynetwork" >/dev/null 2>&1
  terraform state list 2>/dev/null | grep -q 'mynetwork-allow-http-ssh-rdp-icmp' || \
    terraform import -no-color google_compute_firewall.mynetwork-allow-http-ssh-rdp-icmp "projects/$PROJECT/global/firewalls/mynetwork-allow-http-ssh-rdp-icmp" >/dev/null 2>&1
  for n in 1 2; do
    zv="ZONE$n"; z="${!zv}"
    terraform state list 2>/dev/null | grep -q "module.mynet-vm-$n.google_compute_instance.vm_instance" || \
      terraform import -no-color "module.mynet-vm-$n.google_compute_instance.vm_instance" "projects/$PROJECT/zones/$z/instances/mynet-vm-$n" >/dev/null 2>&1
  done
}

rotate_zones() {
  mapfile -t ZONES < <(zone_list)
  [ ${#ZONES[@]} -lt 2 ] && mapfile -t ZONES < <(gcloud compute zones list --filter="status=UP" --format="value(name)" | sort | head -n 6)
  local n=${#ZONES[@]}
  local off=$(( ($1 * 2) % n ))
  ZONE1="${ZONES[$off]}"
  ZONE2="${ZONES[$(( (off + 1) % n ))]}"
  warn "Switching zones to $ZONE1 and $ZONE2"
  write_files
}

fix_error() {
  local attempt=$1
  if grep -qiE "SERVICE_DISABLED|has not been used|accessNotConfigured" "$LOG"; then
    warn "Enabling Compute Engine API"
    gcloud services enable compute.googleapis.com --project "$PROJECT" >/dev/null 2>&1
    sleep 20
  elif grep -qiE "state lock" "$LOG"; then
    warn "Releasing Terraform state lock"
    LOCK_ID=$(grep -oE 'ID: +[0-9a-f-]+' "$LOG" | head -n1 | awk '{print $2}')
    [ -n "$LOCK_ID" ] && terraform force-unlock -force "$LOCK_ID" >/dev/null 2>&1
    rm -f .terraform.tfstate.lock.info
  elif grep -qiE "RESOURCE_POOL_EXHAUSTED|does not have enough resources|zone.*(not found|does not exist)|Invalid value for field 'zone'|machine type.*(not found|not available)" "$LOG"; then
    rotate_zones "$attempt"
  elif grep -qiE "already exists|alreadyExists|Error 409" "$LOG"; then
    import_existing
  elif grep -qiE "image.*(not found|was not found)|Invalid value for field 'resource.disks" "$LOG"; then
    warn "Switching boot image to debian-cloud/debian-11"
    IMAGE="debian-cloud/debian-11"; write_files
  elif grep -qiE "could not find default credentials|No credentials|invalid_grant|Unauthenticated|oauth2" "$LOG"; then
    warn "Refreshing credentials"
    export GOOGLE_OAUTH_ACCESS_TOKEN="$(gcloud auth print-access-token 2>/dev/null)"
  elif grep -qiE "project: required|project.*not set" "$LOG"; then
    warn "Re-exporting project"
    export GOOGLE_PROJECT="$PROJECT" GOOGLE_CLOUD_PROJECT="$PROJECT" GOOGLE_REGION="$REGION"
  elif grep -qiE "Module not installed|dependency lock|Required plugins|Failed to query available provider|Failed to install provider" "$LOG"; then
    warn "Re-initializing Terraform"
    rm -rf .terraform .terraform.lock.hcl
    terraform init -upgrade -input=false -no-color >/dev/null 2>&1
  elif grep -qiE "Unsupported argument|Invalid|Unclosed|Missing|syntax|Argument or block" "$LOG"; then
    warn "Rewriting configuration files cleanly"
    write_files; terraform fmt >/dev/null 2>&1
  elif grep -qiE "quota|rateLimit|RATE_EXCEEDED" "$LOG"; then
    warn "Quota or rate limit hit, waiting 25s"
    sleep 25
  else
    warn "Unknown error, re-initializing and retrying"
    terraform init -input=false -no-color >/dev/null 2>&1
    sleep 8
  fi
}

retry_cmd() {   # usage: retry_cmd "label" command args...
  local label="$1"; shift
  local a=1 rc
  while [ $a -le $MAX_ATTEMPTS ]; do
    "$@" 2>&1 | tee "$LOG"
    rc=${PIPESTATUS[0]}
    [ $rc -eq 0 ] && { ok "$label succeeded"; return 0; }
    fail "$label failed (attempt $a/$MAX_ATTEMPTS)"
    fix_error "$a"
    sleep 3
    a=$((a + 1))
  done
  return 1
}

# ---------- 5. Terraform workflow ----------
step "terraform fmt"
terraform fmt

step "terraform init"
retry_cmd "init" terraform init -input=false -no-color || exit 1

step "terraform plan"
retry_cmd "plan" terraform plan -input=false -no-color || exit 1

step "terraform apply"
retry_cmd "apply" terraform apply -auto-approve -input=false -no-color

# ---------- 6. Verify (real check via gcloud) ----------
step "Verifying deployment"
sleep 5
NET=$(gcloud compute networks list --filter="name=mynetwork" --format="value(name)" 2>/dev/null | wc -l)
FW=$(gcloud compute firewall-rules list --filter="name=mynetwork-allow-http-ssh-rdp-icmp" --format="value(name)" 2>/dev/null | wc -l)
VMS=$(gcloud compute instances list --filter="name~'^mynet-vm-[12]$' AND status=RUNNING" --format="value(name)" 2>/dev/null | wc -l)

echo -e "\n${C_B}VPC network${C_N}"
gcloud compute networks list --filter="name=mynetwork" 2>/dev/null
echo -e "\n${C_B}Firewall rule${C_N}"
gcloud compute firewall-rules list --filter="name=mynetwork-allow-http-ssh-rdp-icmp" \
  --format="table(name,network.basename(),sourceRanges.list())" 2>/dev/null
echo -e "\n${C_B}VM instances${C_N}"
gcloud compute instances list --filter="name~'^mynet-vm'" \
  --format="table(name,zone.basename(),machineType.basename(),networkInterfaces[0].networkIP:label=INTERNAL_IP,networkInterfaces[0].accessConfigs[0].natIP:label=EXTERNAL_IP,status)" 2>/dev/null

echo
if [ "$NET" -ge 1 ] && [ "$FW" -ge 1 ] && [ "$VMS" -ge 2 ]; then
  echo -e "${C_G}=====================================================${C_N}"
  echo -e "${C_G}  LAB COMPLETE: network + firewall + 2 VMs verified${C_N}"
  echo -e "${C_G}  Now click 'Check my progress', then 'End Lab'${C_N}"
  echo -e "${C_G}=====================================================${C_N}"
else
  echo -e "${C_R}Not complete yet: network=$NET firewall=$FW running_vms=$VMS${C_N}"
  echo -e "${C_Y}Run again with:  bash ~/tf_lab.sh   (safe to re-run)${C_N}"
fi
LAB_SCRIPT
bash ~/tf_lab.sh
