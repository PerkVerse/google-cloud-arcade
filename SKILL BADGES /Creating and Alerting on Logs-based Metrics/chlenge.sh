read -p "Enter ZONE (example: us-central1-a): " ZONE; export ZONE REGION="${ZONE%-*}" PROJECT_ID=$(gcloud config get-value project 2>/dev/null) EMAIL=$(gcloud config get-value account 2>/dev/null); gcloud config set compute/zone $ZONE; echo "Project: $PROJECT_ID | Zone: $ZONE | Region: $REGION"
# Task 1
gcloud container clusters create gmp-cluster --num-nodes=1 --zone $ZONE
# Task 2
CH=$(gcloud beta monitoring channels create --display-name="Lab Email" --type=email --channel-labels=email_address=$EMAIL --format="value(name)")
cat > stopped-vm.json <<EOF
{"displayName":"stopped vm","combiner":"OR","conditions":[{"displayName":"stopped vm","conditionMatchedLog":{"filter":"resource.type=\"gce_instance\" protoPayload.methodName=\"v1.compute.instances.stop\""}}],"alertStrategy":{"notificationRateLimit":{"period":"300s"},"autoClose":"3600s"},"notificationChannels":["$CH"]}
EOF
gcloud alpha monitoring policies create --policy-from-file=stopped-vm.json
gcloud compute instances stop instance1 --zone $ZONE -q
# Task 3
gcloud artifacts repositories create docker-repo --repository-format=docker --location=$REGION --description="Docker repository" --project=$PROJECT_ID
gcloud auth configure-docker $REGION-docker.pkg.dev -q
wget https://storage.googleapis.com/spls/gsp1024/flask_telemetry.zip && unzip -o flask_telemetry.zip && docker load -i flask_telemetry.tar
IMAGE=$REGION-docker.pkg.dev/$PROJECT_ID/docker-repo/flask-telemetry:v1
docker tag gcr.io/ops-demo-330920/flask_telemetry:61a2a7aabc7077ef474eb24f4b69faeab47deed9 $IMAGE && docker push $IMAGE
# Task 4
gcloud container clusters get-credentials gmp-cluster --zone $ZONE
kubectl create ns gmp-test
wget https://storage.googleapis.com/spls/gsp1024/gmp_prom_setup.zip && unzip -o gmp_prom_setup.zip && cd gmp_prom_setup
sed -i "s|<ARTIFACT REGISTRY IMAGE NAME>|$IMAGE|g" flask_deployment.yaml
kubectl -n gmp-test apply -f flask_deployment.yaml && kubectl -n gmp-test apply -f flask_service.yaml
sleep 60; kubectl get services -n gmp-test
IP=$(kubectl get services -n gmp-test -o jsonpath='{.items[*].status.loadBalancer.ingress[0].ip}'); curl $IP/metrics; cd ~
# Task 5
gcloud logging metrics create hello-app-error --description="404 errors" --log-filter='severity=ERROR
resource.labels.container_name="hello-app"
textPayload: "ERROR: 404 Error page not found"'
# Task 6
cat > metric-alert.json <<EOF
{"displayName":"log based metric alert","combiner":"OR","conditions":[{"displayName":"hello-app-error","conditionThreshold":{"filter":"metric.type=\"logging.googleapis.com/user/hello-app-error\" resource.type=\"k8s_container\"","aggregations":[{"alignmentPeriod":"120s","perSeriesAligner":"ALIGN_RATE"}],"comparison":"COMPARISON_GT","thresholdValue":0,"duration":"0s"}}],"notificationChannels":["$CH"]}
EOF
gcloud alpha monitoring policies create --policy-from-file=metric-alert.json
# Task 7
timeout 120 bash -c "while true; do curl -s $IP/error >/dev/null; sleep \$((RANDOM % 4)); done"
