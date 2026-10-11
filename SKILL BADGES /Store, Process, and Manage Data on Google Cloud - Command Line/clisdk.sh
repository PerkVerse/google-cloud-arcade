```bash
#!/bin/bash

# ==========================================
# PERKVERSE | GSP074
# Cloud Storage: Qwik Start - CLI/SDK
# YouTube: @PerkVers
# ==========================================

set -Eeuo pipefail

# Colors
RED=$'\033[0;91m'
GREEN=$'\033[0;92m'
YELLOW=$'\033[0;93m'
CYAN=$'\033[0;96m'
WHITE=$'\033[0;97m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

# Error handler
trap 'rc=$?; echo; echo "${RED}${BOLD}ERROR: Script failed at line ${LINENO} (exit code: ${rc}).${RESET}"; exit "$rc"' ERR

clear || true

echo "${CYAN}${BOLD}"
echo "=========================================="
echo "       PERKVERSE | GSP074 🚀"
echo "   Cloud Storage: Qwik Start - CLI/SDK"
echo "=========================================="
echo "${RESET}"

# Check tools
if ! command -v gcloud >/dev/null 2>&1; then
    echo "${RED}ERROR: gcloud CLI is not available.${RESET}"
    exit 1
fi

# Check project
PROJECT_ID="$(gcloud config get-value project 2>/dev/null || true)"

if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "(unset)" ]]; then
    echo "${RED}ERROR: Google Cloud project is not set.${RESET}"
    echo "Set your lab project, then run this script again."
    exit 1
fi

echo "${GREEN}Project: ${PROJECT_ID}${RESET}"
gcloud auth list
gcloud config list project

# Lab region
gcloud config set compute/region us-east1

# Bucket name
BUCKET_NAME="${PROJECT_ID}-techcode"

echo
echo "${YELLOW}${BOLD}TASK 1: Create a Cloud Storage bucket${RESET}"

if gcloud storage buckets describe "gs://${BUCKET_NAME}" >/dev/null 2>&1; then
    echo "${YELLOW}Bucket already exists; reusing it.${RESET}"
else
    gcloud storage buckets create "gs://${BUCKET_NAME}" \
        --location=us-east1
fi

echo "${GREEN}Task 1 command completed.${RESET}"

echo
echo "${YELLOW}${BOLD}TASK 2: Upload an object${RESET}"

if ! curl -fLsS \
    "https://upload.wikimedia.org/wikipedia/commons/thumb/a/a4/Ada_Lovelace_portrait.jpg/800px-Ada_Lovelace_portrait.jpg" \
    -o ada.jpg; then
    echo "${RED}ERROR: Could not download the image.${RESET}"
    exit 1
fi

gcloud storage cp ada.jpg "gs://${BUCKET_NAME}/ada.jpg"

echo "${GREEN}Task 2 command completed.${RESET}"

echo
echo "${YELLOW}${BOLD}TASK 3: Download an object${RESET}"

gcloud storage cp "gs://${BUCKET_NAME}/ada.jpg" ./ada-downloaded.jpg

echo "${GREEN}Task 3 command completed.${RESET}"

echo
echo "${YELLOW}${BOLD}TASK 4: Copy an object to a folder${RESET}"

gcloud storage cp \
    "gs://${BUCKET_NAME}/ada.jpg" \
    "gs://${BUCKET_NAME}/image-folder/ada.jpg"

echo "${GREEN}Task 4 command completed.${RESET}"

echo
echo "${YELLOW}${BOLD}TASK 5: List bucket contents${RESET}"

gcloud storage ls "gs://${BUCKET_NAME}/"

echo "${GREEN}Task 5 command completed.${RESET}"

echo
echo "${YELLOW}${BOLD}TASK 6: List object details${RESET}"

gcloud storage ls -l "gs://${BUCKET_NAME}/ada.jpg"

echo "${GREEN}Task 6 command completed.${RESET}"

echo
echo "${YELLOW}${BOLD}TASK 7: Make object publicly accessible${RESET}"

echo "Checking bucket access configuration..."

if gcloud storage buckets describe "gs://${BUCKET_NAME}" \
    --format="value(iamConfiguration.uniformBucketLevelAccess.enabled)" \
    2>/dev/null | grep -qi '^true$'; then

    echo "${YELLOW}Uniform bucket-level access is enabled.${RESET}"
    echo "Object ACL changes may be blocked by this configuration."
    echo "Follow the official lab instructions for the required access setting."
else
    gcloud storage objects update \
        "gs://${BUCKET_NAME}/ada.jpg" \
        --add-acl-grant=entity=allUsers,role=READER
fi

echo
echo "${CYAN}${BOLD}PAUSE: CHECK YOUR LAB PROGRESS${RESET}"
echo "Open the Google Skills lab page."
echo "Click Check my progress for the public-access task."
echo
read -r -p "After checking progress, press ENTER to continue..."

echo
echo "${YELLOW}${BOLD}TASK 8: Remove public access${RESET}"

if gcloud storage buckets describe "gs://${BUCKET_NAME}" \
    --format="value(iamConfiguration.uniformBucketLevelAccess.enabled)" \
    2>/dev/null | grep -qi '^true$'; then

    echo "${YELLOW}Bucket uses uniform bucket-level access."
    echo "No object ACL removal was attempted.${RESET}"
else
    gcloud storage objects update \
        "gs://${BUCKET_NAME}/ada.jpg" \
        --remove-acl-grant=allUsers
fi

echo
echo "${GREEN}${BOLD}SCRIPT TASKS FINISHED${RESET}"
echo
echo "${WHITE}Bucket: gs://${BUCKET_NAME}${RESET}"
echo "${WHITE}Uploaded object: gs://${BUCKET_NAME}/ada.jpg${RESET}"
echo
echo "${YELLOW}${BOLD}PERKVERSE | @PerkVers${RESET}"
echo "${GREEN}Like • Share • Subscribe for more Arcade Labs!${RESET}"
echo
echo "Check your Google Skills lab progress before ending the lab."
```
