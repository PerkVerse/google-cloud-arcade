# ==========================================================
# Google Cloud Arcade Lab Script
# Lab: IAM & Cloud Storage Access Control
# Channel: CampusPerks (@CampusPerkss)
# ==========================================================

# Define color codes for output formatting
YELLOW_COLOR=$'\033[0;33m'
NO_COLOR=$'\033[0m'

BACKGROUND_RED=$(tput setab 1)
GREEN_TEXT=$(tput setab 2)
RED_TEXT=$(tput setaf 1)

BOLD_TEXT=$(tput bold)
UNDERLINE_TEXT=$(tput smul)
RESET_FORMAT=$(tput sgr0)

clear
echo "${BACKGROUND_RED}${BOLD_TEXT}🚀 CAMPUSPERKS | ARCADE LAB EXECUTION STARTED${RESET_FORMAT}"
echo

# Prompt user for their username
read -p "${YELLOW_COLOR}Enter USERNAME 2 (example: user@gmail.com): ${NO_COLOR}" USERNAME_2
echo

# =============================
# CLOUD STORAGE SETUP
# =============================
echo "${BOLD_TEXT}📦 Creating Cloud Storage bucket...${RESET_FORMAT}"
gsutil mb -l us -b on gs://$DEVSHELL_PROJECT_ID

# Create a sample file
echo "Subscribe to CampusPerks for Google Cloud Arcade Labs 🚀" > sample.txt

# Upload the file to the bucket
echo "${BOLD_TEXT}⬆️ Uploading file to bucket...${RESET_FORMAT}"
gsutil cp sample.txt gs://$DEVSHELL_PROJECT_ID

# =============================
# IAM CONFIGURATION
# =============================
echo "${BOLD_TEXT}🔐 Updating IAM roles...${RESET_FORMAT}"

# Remove Viewer role
gcloud projects remove-iam-policy-binding $DEVSHELL_PROJECT_ID \
  --member=user:$USERNAME_2 \
  --role=roles/viewer

# Add Storage Object Viewer role
gcloud projects add-iam-policy-binding $DEVSHELL_PROJECT_ID \
  --member=user:$USERNAME_2 \
  --role=roles/storage.objectViewer

# =============================
# COMPLETION
# =============================
echo
echo "${GREEN_TEXT}${BOLD_TEXT}✅ LAB COMPLETED SUCCESSFULLY!${RESET_FORMAT}"
echo
echo "${YELLOW_COLOR}${BOLD_TEXT}${UNDERLINE_TEXT}YouTube: https://www.youtube.com/@CampusPerkss${RESET_FORMAT}"
echo "${BOLD_TEXT}🔥 Like • Share • Subscribe for more Arcade Labs${RESET_FORMAT}"
