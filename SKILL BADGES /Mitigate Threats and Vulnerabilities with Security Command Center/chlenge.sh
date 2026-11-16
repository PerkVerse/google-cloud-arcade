clear; echo "=== GSP382 | Security Command Center Challenge Lab ==="; PROJECT_ID=$(gcloud config get-value project 2>/dev/null); [ -z "$PROJECT_ID" ] && PROJECT_ID=$DEVSHELL_PROJECT_ID; read -p "Enter region (example: us-central1): " REGION; ZONE=$(gcloud compute instances list --filter="name=cls-vm" --format="value(zone.basename())" 2>/dev/null | head -n1); VM_REGION=${ZONE%-*}; echo "Project: $PROJECT_ID | Region: $REGION | VM Zone: $ZONE"; \
echo "[1/5] Creating mute rules..."; \
gcloud scc muteconfigs create muting-flow-log-findings --project=$PROJECT_ID --location=global --type=STATIC --description="Rule for muting VPC Flow Logs" --filter='category="FLOW_LOGS_DISABLED"' --quiet 2>/dev/null || echo " - muting-flow-log-findings already exists or was skipped"; \
gcloud scc muteconfigs create muting-audit-logging-findings --project=$PROJECT_ID --location=global --type=STATIC --description="Rule for muting audit logs" --filter='category="AUDIT_LOGGING_DISABLED"' --quiet 2>/dev/null || echo " - muting-audit-logging-findings already exists or was skipped"; \
gcloud scc muteconfigs create muting-admin-sa-findings --project=$PROJECT_ID --location=global --type=STATIC --description="Rule for muting admin service account findings" --filter='category="ADMIN_SERVICE_ACCOUNT"' --quiet 2>/dev/null || echo " - muting-admin-sa-findings already exists or was skipped"; \
echo "[2/5] Restricting open SSH and RDP firewall rules..."; \
gcloud compute firewall-rules update default-allow-ssh --source-ranges=35.235.240.0/20 --quiet; \
gcloud compute firewall-rules update default-allow-rdp --source-ranges=35.235.240.0/20 --quiet; \
echo "[3/5] Reserving static IP for cls-vm..."; \
VM_IP=$(gcloud compute instances describe cls-vm --zone=$ZONE --format="get(networkInterfaces[0].accessConfigs[0].natIP)"); \
gcloud compute addresses create static-ip --addresses=$VM_IP --region=$VM_REGION --quiet 2>/dev/null || echo " - static-ip already exists"; \
echo " - VM IP: $VM_IP (app: http://$VM_IP:8080)"; \
echo "[4/5] Creating and starting Web Security Scan..."; \
gcloud alpha web-security-scanner scan-configs create --display-name=cls-scan --starting-urls=http://$VM_IP:8080 --target-platforms=COMPUTE --quiet 2>/dev/null || echo " - cls-scan already exists or was skipped"; \
SCAN_NAME=$(gcloud alpha web-security-scanner scan-configs list --filter="displayName=cls-scan" --format="value(name)" 2>/dev/null | head -n1); \
curl -s -X POST -H "Authorization: Bearer $(gcloud auth print-access-token)" -H "Content-Type: application/json" -d '{}' "https://websecurityscanner.googleapis.com/v1/$SCAN_NAME:start" >/dev/null && echo " - Scan started: $SCAN_NAME"; \
echo "[5/5] Exporting findings to Cloud Storage..."; \
gcloud storage buckets create gs://scc-export-bucket-$PROJECT_ID --location=$REGION --quiet 2>/dev/null || echo " - bucket already exists"; \
gcloud scc findings list "projects/$PROJECT_ID" --format=json 2>/dev/null | jq -c '.[]' > findings.jsonl; \
gcloud storage cp findings.jsonl gs://scc-export-bucket-$PROJECT_ID/findings.jsonl --quiet; \
echo "=== All tasks finished. Ab har task ke liye 'Check my progress' dabao. ==="
