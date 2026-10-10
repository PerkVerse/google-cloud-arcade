echo "${CYAN_TEXT}${BOLD_TEXT}==================================================================${RESET_FORMAT}"
echo "${CYAN_TEXT}${BOLD_TEXT}        SUBSCRIBE PERKVERSE - INITIATING EXECUTION...            ${RESET_FORMAT}"
echo "${CYAN_TEXT}${BOLD_TEXT}==================================================================${RESET_FORMAT}"

gcloud pubsub subscriptions create pubsub-subscription-message --topic=gcloud-pubsub-topic
gcloud pubsub topics publish gcloud-pubsub-topic --message="Hello World"

gcloud pubsub subscriptions pull pubsub-subscription-message --limit 5 --auto-ack

gcloud pubsub snapshots create pubsub-snapshot --subscription=gcloud-pubsub-subscription

echo
echo "${CYAN_TEXT}${BOLD_TEXT}=======================================================${RESET_FORMAT}"
echo "${CYAN_TEXT}${BOLD_TEXT}              LAB COMPLETED SUCCESSFULLY!              ${RESET_FORMAT}"
echo "${CYAN_TEXT}${BOLD_TEXT}=======================================================${RESET_FORMAT}"
echo
echo "${RED_TEXT}${BOLD_TEXT}${UNDERLINE_TEXT}https://www.youtube.com/@PerkVers${RESET_FORMAT}"
echo "${GREEN_TEXT}${BOLD_TEXT}👍 LIKE | 🔄 SHARE | 🔔 SUBSCRIBE${RESET_FORMAT}"
echo "${YELLOW_TEXT}${BOLD_TEXT}PERKVERSE - Google Cloud Arcade Labs & Tech Opportunities${RESET_FORMAT}"
echo "${CYAN_TEXT}${BOLD_TEXT}Follow @PerkVers for more updates${RESET_FORMAT}"
