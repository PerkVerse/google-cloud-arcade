echo "${CYAN_TEXT}${BOLD_TEXT}==================================================================${RESET_FORMAT}"
echo "${CYAN_TEXT}${BOLD_TEXT}        SUBSCRIBE PERKVERSE - INITIATING EXECUTION...            ${RESET_FORMAT}"
echo "${CYAN_TEXT}${BOLD_TEXT}==================================================================${RESET_FORMAT}"

gcloud pubsub topics create myTopic

gcloud  pubsub subscriptions create --topic myTopic mySubscription

echo
echo "${CYAN_TEXT}${BOLD_TEXT}=======================================================${RESET_FORMAT}"
echo "${CYAN_TEXT}${BOLD_TEXT}              LAB COMPLETED SUCCESSFULLY!              ${RESET_FORMAT}"
echo "${CYAN_TEXT}${BOLD_TEXT}=======================================================${RESET_FORMAT}"
echo
echo "${RED_TEXT}${BOLD_TEXT}${UNDERLINE_TEXT}https://www.youtube.com/@PerkVers${RESET_FORMAT}"
echo "${GREEN_TEXT}${BOLD_TEXT}👍 LIKE | 🔄 SHARE | 🔔 SUBSCRIBE${RESET_FORMAT}"
echo "${YELLOW_TEXT}${BOLD_TEXT}PERKVERSE - Google Cloud Arcade Labs & Tech Opportunities${RESET_FORMAT}"
echo "${CYAN_TEXT}${BOLD_TEXT}Follow @PerkVers for more updates${RESET_FORMAT}"
