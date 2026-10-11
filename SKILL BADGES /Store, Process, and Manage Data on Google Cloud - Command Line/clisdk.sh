```bash
#!/bin/bash

# ==========================================
# PERKVERSE | GSP074
# Cloud Storage: Qwik Start - CLI/SDK
# ==========================================

set -euo pipefail

# Text colors
BLACK_TEXT=$'\033[0;90m'
RED_TEXT=$'\033[0;91m'
GREEN_TEXT=$'\033[0;92m'
YELLOW_TEXT=$'\033[0;93m'
BLUE_TEXT=$'\033[0;94m'
MAGENTA_TEXT=$'\033[0;95m'
CYAN_TEXT=$'\033[0;96m'
WHITE_TEXT=$'\033[0;97m'

NO_COLOR=$'\033[0m'
RESET_FORMAT=$'\033[0m'
BOLD_TEXT=$'\033[1m'
UNDERLINE_TEXT=$'\033[4m'

clear

echo "${CYAN_TEXT}${BOLD_TEXT}=======================================${RESET_FORMAT}"
echo "${CYAN_TEXT}${BOLD_TEXT}   PERKVERSE | EXECUTION STARTING 🚀   ${RESET_FORMAT}"
echo "${CYAN_TEXT}${BOLD_TEXT}=======================================${RESET_FORMAT}"
echo

# Check authentication and project
gcloud auth list
gcloud config list project

PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"

if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "(unset)" ]]; then
    echo "${RED_TEXT}ERROR: Google Cloud project is not set.${RESET_FORMAT}"
    exit 1
fi

# Lab region
gcloud config set compute/region us-east1

# Bucket name
BUCKET_NAME="${PROJECT_ID}-techcode"

echo
echo "${YELLOW_TEXT}${BOLD_TEXT}Task 1: Create a Cloud Storage bucket${RESET_FORMAT}"

if gcloud storage buckets describe "gs://${BUCKET_NAME}" >/dev/null 2>&1; then
    echo "${YELLOW_TEXT}Bucket already exists; reusing it.${RESET_FORMAT}"
else
    gcloud storage buckets create "gs://${BUCKET_NAME}"
fi

echo "${GREEN_TEXT}Task 1 command completed.${RESET_FORMAT}"

# Download Ada Lovelace image
echo
echo "${YELLOW_TEXT}${BOLD_TEXT}Task 2: Upload an object into your bucket${RESET_FORMAT}"

curl -fL \
  "https://upload.wikimedia.org/wikipedia/commons/thumb/a/a4/Ada_Lovelace_portrait.jpg/800px-Ada_Lovelace_portrait.jpg" \
  -o ada.jpg

gcloud storage cp ada.jpg "gs://${BUCKET_NAME}/"

echo "${GREEN_TEXT}Task 2 command completed.${RESET_FORMAT}"

# Download object from bucket
echo
echo "${YELLOW_TEXT}${BOLD_TEXT}Task 3: Download an object from your bucket${RESET_FORMAT}"

gcloud storage cp "gs://${BUCKET_NAME}/ada.jpg" .

echo "${GREEN_TEXT}Task 3 command completed.${RESET_FORMAT}"

# Copy object into a folder
echo
echo "${YELLOW_TEXT}${BOLD_TEXT}Task 4: Copy an object to a folder${RESET_FORMAT}"

gcloud storage cp \
  "gs://${BUCKET_NAME}/ada.jpg" \
  "gs://${BUCKET_NAME}/image-folder/"

echo "${GREEN_TEXT}Task 4 command completed.${RESET_FORMAT}"

# List bucket contents
echo
echo "${YELLOW_TEXT}${BOLD_TEXT}Task 5: List bucket contents${RESET_FORMAT}"

gcloud storage ls "gs://${BUCKET_NAME}"

echo "${GREEN_TEXT}Task 5 command completed.${RESET_FORMAT}"

# List object details
echo
echo "${YELLOW_TEXT}${BOLD_TEXT}Task 6: List details for ada.jpg${RESET_FORMAT}"

gcloud storage ls -l "gs://${BUCKET_NAME}/ada.jpg"

echo "${GREEN_TEXT}Task 6 command completed.${RESET_FORMAT}"

# Make object public
echo
echo "${YELLOW_TEXT}${BOLD_TEXT}Task 7: Make your object publicly accessible${RESET_FORMAT}"

gcloud storage objects update \
  "gs://${BUCKET_NAME}/ada.jpg" \
  --add-acl-grant=entity=allUsers,role=READER

echo
echo "${GREEN_TEXT}${BOLD_TEXT}Task 7 command completed.${RESET_FORMAT}"
echo
echo "${YELLOW_TEXT}${BOLD_TEXT}IMPORTANT:${RESET_FORMAT}"
echo "Go to the Google Skills lab page and click Check my progress for:"
echo "Make your object publicly accessible"
echo
read -r -p "After checking Task 7, press ENTER to continue to Task 8..."

# Remove public access
echo
echo "${YELLOW_TEXT}${BOLD_TEXT}Task 8: Remove public access${RESET_FORMAT}"

gcloud storage objects update \
  "gs://${BUCKET_NAME}/ada.jpg" \
  --remove-acl-grant=allUsers

echo "${GREEN_TEXT}Task 8 command completed.${RESET_FORMAT}"

# Delete root object, as described in the lab's cleanup section
echo
read -r -p "Task 7 progress checked? Press ENTER to delete the original ada.jpg object, or Ctrl+C to keep it..."

gcloud storage rm "gs://${BUCKET_NAME}/ada.jpg"

# Final message
echo
echo "${CYAN_TEXT}${BOLD_TEXT}=======================================================${RESET_FORMAT}"
echo "${CYAN_TEXT}${BOLD_TEXT}          🎉 SCRIPT EXECUTION FINISHED! 🎉           ${RESET_FORMAT}"
echo "${CYAN_TEXT}${BOLD_TEXT}=======================================================${RESET_FORMAT}"
echo
echo "${WHITE_TEXT}Bucket: gs://${BUCKET_NAME}${RESET_FORMAT}"
echo "${YELLOW_TEXT}${BOLD_TEXT}${UNDERLINE_TEXT}YouTube: https://www.youtube.com/@PerkVers${RESET_FORMAT}"
echo "${GREEN_TEXT}${BOLD_TEXT}🔥 Like • Share • Subscribe for more Arcade Labs${RESET_FORMAT}"
echo
echo "${YELLOW_TEXT}Now check the remaining lab progress on Google Skills.${RESET_FORMAT}"
```
