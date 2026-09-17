echo "${CYAN_TEXT}${BOLD_TEXT}==================================================================${RESET_FORMAT}"
echo "${CYAN_TEXT}${BOLD_TEXT}        SUBSCRIBE PERKVERSE - INITIATING EXECUTION...            ${RESET_FORMAT}"
echo "${CYAN_TEXT}${BOLD_TEXT}==================================================================${RESET_FORMAT}"

gcloud config set compute/region $REGION


gsutil mb gs://$DEVSHELL_PROJECT_ID

curl https://upload.wikimedia.org/wikipedia/commons/thumb/a/a4/Ada_Lovelace_portrait.jpg/800px-Ada_Lovelace_portrait.jpg --output ada.jpg

gsutil cp ada.jpg gs://$DEVSHELL_PROJECT_ID

gsutil cp -r gs://$DEVSHELL_PROJECT_ID/ada.jpg .

gsutil cp gs://$DEVSHELL_PROJECT_ID/ada.jpg gs://$DEVSHELL_PROJECT_ID/image-folder/

gsutil acl ch -u AllUsers:R gs://$DEVSHELL_PROJECT_ID/ada.jpg

echo
echo "${CYAN_TEXT}${BOLD_TEXT}=======================================================${RESET_FORMAT}"
echo "${CYAN_TEXT}${BOLD_TEXT}              LAB COMPLETED SUCCESSFULLY!              ${RESET_FORMAT}"
echo "${CYAN_TEXT}${BOLD_TEXT}=======================================================${RESET_FORMAT}"
echo
echo "${RED_TEXT}${BOLD_TEXT}${UNDERLINE_TEXT}https://www.youtube.com/@PerkVers${RESET_FORMAT}"
echo "${GREEN_TEXT}${BOLD_TEXT}👍 LIKE | 🔄 SHARE | 🔔 SUBSCRIBE${RESET_FORMAT}"
echo "${YELLOW_TEXT}${BOLD_TEXT}PERKVERSE - Google Cloud Arcade Labs & Tech Opportunities${RESET_FORMAT}"
echo "${CYAN_TEXT}${BOLD_TEXT}Follow @PerkVers for more updates${RESET_FORMAT}"
