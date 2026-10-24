#!/bin/bash
# =====================================================================
#   Google Cloud Lab: Exploring IAM (CBL003): Automated Solution
#   Run this in the Cloud Shell of Username 1
# =====================================================================

MAX_TRIES=20
DELAY=10

# ---------- Colors ----------
BOLD=$'\e[1m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; RED=$'\e[31m'
CYAN=$'\e[36m'; RESET=$'\e[0m'

banner() { echo -e "\n${CYAN}${BOLD}══════════ $1 ══════════${RESET}"; }

# ---------- Run a command quietly, retry up to MAX_TRIES ----------
run() {
  local desc="$1"; shift
  local n=1 out
  printf "  • %-55s" "$desc"
  until out=$("$@" 2>&1); do
    if (( n >= MAX_TRIES )); then
      echo -e "${RED}FAILED${RESET}"
      echo "$out" | tail -n 5 | sed 's/^/      /'
      return 1
    fi
    ((n++)); sleep $DELAY
  done
  echo -e "${GREEN}done${RESET}"
}

# ---------- Run a command with visible output, retry on failure ----------
run_show() {
  local desc="$1"; shift
  local n=1
  echo -e "  ${YELLOW}▶ $desc${RESET}"
  until "$@"; do
    if (( n >= MAX_TRIES )); then
      echo -e "  ${RED}✖ Failed after $MAX_TRIES attempts${RESET}"
      return 1
    fi
    echo -e "  ${YELLOW}↻ Attempt $n failed, retrying in ${DELAY}s...${RESET}"
    ((n++)); sleep $DELAY
  done
}

# =====================================================================
#   SETUP: detect and ask
# =====================================================================
clear
echo -e "${BOLD}${CYAN}"
echo "  ┌──────────────────────────────────────────────┐"
echo "  │      Exploring IAM: Automated Lab Script     │"
echo "  └──────────────────────────────────────────────┘"
echo -e "${RESET}"

# --- Auto-detect Project ID ---
PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
[[ -z "$PROJECT_ID" ]] && PROJECT_ID="$GOOGLE_CLOUD_PROJECT"
[[ -z "$PROJECT_ID" ]] && PROJECT_ID=$(gcloud projects list --format="value(projectId)" --limit=1 2>/dev/null)

if [[ -z "$PROJECT_ID" ]]; then
  echo -e "${RED}Could not detect Project ID. Make sure you are in the lab's Cloud Shell.${RESET}"
  exit 1
fi

# --- Auto-detect Username 1 (current account) ---
USER1=$(gcloud config get-value account 2>/dev/null)

# --- Ask for Region & Zone ---
read -rp "  Enter Region [us-central1]: " REGION
REGION=${REGION:-us-central1}

read -rp "  Enter Zone   [${REGION}-a]: " ZONE
ZONE=${ZONE:-${REGION}-a}

if [[ "$ZONE" != "$REGION"-* ]]; then
  echo -e "${RED}Zone '$ZONE' does not belong to region '$REGION'. Please re-run.${RESET}"
  exit 1
fi

# --- Ask for Username 2 ---
read -rp "  Enter Username 2 (from lab panel): " USER2
if [[ -z "$USER2" ]]; then
  echo -e "${RED}Username 2 is required.${RESET}"
  exit 1
fi

# --- Derived variables ---
BUCKET="${PROJECT_ID}-iam-bucket"
SA_NAME="read-bucket-objects"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
VM_NAME="demoiam"

gcloud config set project "$PROJECT_ID" >/dev/null 2>&1
gcloud config set compute/region "$REGION" >/dev/null 2>&1
gcloud config set compute/zone "$ZONE" >/dev/null 2>&1

echo -e "\n${BOLD}  Configuration${RESET}"
echo "  ─────────────────────────────────────────────"
echo "  Project ID : $PROJECT_ID"
echo "  Region     : $REGION"
echo "  Zone       : $ZONE"
echo "  Username 1 : $USER1"
echo "  Username 2 : $USER2"
echo "  Bucket     : $BUCKET"
echo "  ─────────────────────────────────────────────"
read -rp "  Press Enter to start (Ctrl+C to cancel)... "

# =====================================================================
#   TASK 3: Bucket + sample.txt
# =====================================================================
banner "TASK 3: Create bucket & upload sample.txt"

run "Enabling required APIs" \
  gcloud services enable compute.googleapis.com storage.googleapis.com iam.googleapis.com

if ! gcloud storage buckets describe "gs://$BUCKET" >/dev/null 2>&1; then
  run "Creating bucket gs://$BUCKET (multi-region US)" \
    gcloud storage buckets create "gs://$BUCKET" --location=US --project="$PROJECT_ID"
else
  echo -e "  • Bucket already exists                                ${GREEN}skipped${RESET}"
fi

echo "This is a sample file" > sample.txt
run "Uploading sample.txt" \
  gcloud storage cp sample.txt "gs://$BUCKET/sample.txt"

# =====================================================================
#   TASK 4: Remove Username 2's project access
# =====================================================================
banner "TASK 4: Remove project access for Username 2"

ROLES=$(gcloud projects get-iam-policy "$PROJECT_ID" \
  --flatten="bindings[].members" \
  --filter="bindings.members:user:$USER2" \
  --format="value(bindings.role)" 2>/dev/null)

if [[ -z "$ROLES" ]]; then
  echo -e "  • No project roles found for Username 2               ${GREEN}skipped${RESET}"
else
  for ROLE in $ROLES; do
    run "Removing $ROLE" \
      gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
        --member="user:$USER2" --role="$ROLE" --quiet
  done
fi

# =====================================================================
#   TASK 5: Give Username 2 Storage Object Viewer
# =====================================================================
banner "TASK 5: Grant Storage Object Viewer to Username 2"

run "Adding roles/storage.objectViewer" \
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="user:$USER2" --role="roles/storage.objectViewer" --quiet

# =====================================================================
#   TASK 6: Service account, IAM roles, VM
# =====================================================================
banner "TASK 6: Service Account User setup"

if ! gcloud iam service-accounts describe "$SA_EMAIL" >/dev/null 2>&1; then
  run "Creating service account $SA_NAME" \
    gcloud iam service-accounts create "$SA_NAME" --display-name="$SA_NAME"
else
  echo -e "  • Service account already exists                      ${GREEN}skipped${RESET}"
fi

run "Granting Storage Object Viewer to service account" \
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:$SA_EMAIL" --role="roles/storage.objectViewer" --quiet

run "Granting Service Account User to altostrat.com" \
  gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
    --member="domain:altostrat.com" --role="roles/iam.serviceAccountUser" --quiet

run "Granting Compute Instance Admin (v1) to altostrat.com" \
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="domain:altostrat.com" --role="roles/compute.instanceAdmin.v1" --quiet

if ! gcloud compute instances describe "$VM_NAME" --zone="$ZONE" >/dev/null 2>&1; then
  run "Creating VM $VM_NAME (e2-micro, Debian 12)" \
    gcloud compute instances create "$VM_NAME" \
      --zone="$ZONE" \
      --machine-type=e2-micro \
      --image-family=debian-12 \
      --image-project=debian-cloud \
      --service-account="$SA_EMAIL" \
      --scopes=https://www.googleapis.com/auth/devstorage.read_write
else
  echo -e "  • VM $VM_NAME already exists                          ${GREEN}skipped${RESET}"
fi

# =====================================================================
#   TASK 7: Explore Service Account User role (via SSH)
# =====================================================================
banner "TASK 7: Test access from the VM"

echo -e "  Waiting 40s for the VM to boot..."
sleep 40

SSH="gcloud compute ssh $VM_NAME --zone=$ZONE --quiet --strict-host-key-checking=no"

echo -e "\n${BOLD}  (a) List instances: 'insufficient scopes' warning is EXPECTED${RESET}"
$SSH --command="gcloud compute instances list" || true

echo -e "\n${BOLD}  (b) Download sample.txt from the bucket: should SUCCEED${RESET}"
run_show "Copy and rename file on VM" \
  $SSH --command="gcloud storage cp gs://$BUCKET/sample.txt . && mv sample.txt sample2.txt"

echo -e "\n${BOLD}  (c) Upload sample2.txt: '403 AccessDenied' is EXPECTED${RESET}"
$SSH --command="gcloud storage cp sample2.txt gs://$BUCKET" || true

echo -e "\n${BOLD}  (d) Change service account role: Viewer → Object Creator${RESET}"
run "Removing roles/storage.objectViewer from service account" \
  gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:$SA_EMAIL" --role="roles/storage.objectViewer" --quiet
run "Adding roles/storage.objectCreator to service account" \
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:$SA_EMAIL" --role="roles/storage.objectCreator" --quiet

echo -e "\n${BOLD}  (e) Upload again: should SUCCEED (retries while IAM propagates)${RESET}"
run_show "Upload sample2.txt from VM" \
  $SSH --command="gcloud storage cp sample2.txt gs://$BUCKET"

# =====================================================================
#   DONE
# =====================================================================
echo -e "\n${GREEN}${BOLD}══════════════ ✔ ALL TASKS COMPLETED ══════════════${RESET}"
echo -e "  Now click ${BOLD}Check my progress${RESET} on the lab page for each task."
echo
