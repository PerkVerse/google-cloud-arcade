run_lab() {
export PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
export PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format='value(projectNumber)')
read -p "Enter region: " REGION
export REGION
gcloud config set compute/region $REGION

echo "=== Task 1 ==="
gcloud services enable cloudkms.googleapis.com run.googleapis.com cloudbuild.googleapis.com container.googleapis.com containerregistry.googleapis.com artifactregistry.googleapis.com containerscanning.googleapis.com ondemandscanning.googleapis.com binaryauthorization.googleapis.com
cd ~
rm -rf sample-app
mkdir sample-app && cd sample-app
gcloud storage cp gs://spls/gsp521/* .
gcloud artifacts repositories create artifact-scanning-repo --repository-format=docker --location=$REGION
gcloud artifacts repositories create artifact-prod-repo --repository-format=docker --location=$REGION

echo "=== Task 2 ==="
export SCAN_IMG="${REGION}-docker.pkg.dev/${PROJECT_ID}/artifact-scanning-repo/sample-image"
export PROD_IMG="${REGION}-docker.pkg.dev/${PROJECT_ID}/artifact-prod-repo/sample-image:latest"
export KEY_VERSION="projects/${PROJECT_ID}/locations/global/keyRings/binauthz-keys/cryptoKeys/lab-key/cryptoKeyVersions/1"

cat > cloudbuild.yaml << EOM
steps:
- id: "build"
  name: 'gcr.io/cloud-builders/docker'
  args: ['build', '-t', '${SCAN_IMG}', '.']
  waitFor: ['-']
- id: "push"
  name: 'gcr.io/cloud-builders/docker'
  args: ['push', '${SCAN_IMG}']
images:
  - ${SCAN_IMG}
EOM
gcloud builds submit --region=$REGION --config cloudbuild.yaml .

echo "=== Task 3 ==="
cat > vulnerability_note.json << EOM
{"attestation": {"hint": {"human_readable_name": "Container Vulnerabilities attestation authority"}}}
EOM
curl -s -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $(gcloud auth print-access-token)" -H "X-Goog-User-Project: ${PROJECT_ID}" --data-binary @vulnerability_note.json "https://containeranalysis.googleapis.com/v1/projects/${PROJECT_ID}/notes/?noteId=vulnerability_note"
curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" -H "X-Goog-User-Project: ${PROJECT_ID}" "https://containeranalysis.googleapis.com/v1/projects/${PROJECT_ID}/notes/vulnerability_note"

gcloud container binauthz attestors create vulnerability-attestor --attestation-authority-note=vulnerability_note --attestation-authority-note-project=${PROJECT_ID}
gcloud container binauthz attestors list

export BINAUTHZ_SA="service-${PROJECT_NUMBER}@gcp-sa-binaryauthorization.iam.gserviceaccount.com"
cat > iam_request.json << EOM
{"resource": "projects/${PROJECT_ID}/notes/vulnerability_note",
 "policy": {"bindings": [{"role": "roles/containeranalysis.notes.occurrences.viewer",
 "members": ["serviceAccount:${BINAUTHZ_SA}"]}]}}
EOM
curl -s -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $(gcloud auth print-access-token)" -H "X-Goog-User-Project: ${PROJECT_ID}" --data-binary @iam_request.json "https://containeranalysis.googleapis.com/v1/projects/${PROJECT_ID}/notes/vulnerability_note:setIamPolicy"

gcloud kms keyrings create binauthz-keys --location=global
gcloud kms keys create lab-key --keyring=binauthz-keys --location=global --purpose=asymmetric-signing --default-algorithm=ec-sign-p256-sha256
gcloud beta container binauthz attestors public-keys add --attestor=vulnerability-attestor --keyversion-project=${PROJECT_ID} --keyversion-location=global --keyversion-keyring=binauthz-keys --keyversion-key=lab-key --keyversion=1

cat > policy.yaml << EOM
defaultAdmissionRule:
  evaluationMode: REQUIRE_ATTESTATION
  enforcementMode: ENFORCED_BLOCK_AND_AUDIT_LOG
  requireAttestationsBy:
  - projects/${PROJECT_ID}/attestors/vulnerability-attestor
globalPolicyEvaluationMode: ENABLE
EOM
gcloud container binauthz policy import policy.yaml

echo "=== Task 4 ==="
git clone https://github.com/GoogleCloudPlatform/cloud-builders-community.git
cd cloud-builders-community/binauthz-attestation
gcloud builds submit . --region=$REGION --config cloudbuild.yaml
cd ../..
rm -rf cloud-builders-community

cat > cloudbuild.yaml << EOM
steps:
- id: "build"
  name: 'gcr.io/cloud-builders/docker'
  args: ['build', '-t', '${SCAN_IMG}', '.']
  waitFor: ['-']
- id: "push"
  name: 'gcr.io/cloud-builders/docker'
  args: ['push', '${SCAN_IMG}']
- id: scan
  name: 'gcr.io/cloud-builders/gcloud'
  entrypoint: 'bash'
  args:
  - '-c'
  - |
    (gcloud artifacts docker images scan \\
    ${SCAN_IMG} \\
    --location us \\
    --format="value(response.scan)") > /workspace/scan_id.txt
- id: severity check
  name: 'gcr.io/cloud-builders/gcloud'
  entrypoint: 'bash'
  args:
  - '-c'
  - |
      gcloud artifacts docker images list-vulnerabilities \$(cat /workspace/scan_id.txt) \\
      --format="value(vulnerability.effectiveSeverity)" | if grep -Fxq CRITICAL; \\
      then echo "Failed vulnerability check for CRITICAL level" && exit 1; else echo \\
      "No CRITICAL vulnerability found, congrats !" && exit 0; fi
- id: 'create-attestation'
  name: 'gcr.io/${PROJECT_ID}/binauthz-attestation:latest'
  args:
    - '--artifact-url'
    - '${SCAN_IMG}'
    - '--attestor'
    - 'projects/${PROJECT_ID}/attestors/vulnerability-attestor'
    - '--keyversion'
    - '${KEY_VERSION}'
- id: "push-to-prod"
  name: 'gcr.io/cloud-builders/docker'
  args:
    - 'tag'
    - '${SCAN_IMG}'
    - '${PROD_IMG}'
- id: "push-to-prod-final"
  name: 'gcr.io/cloud-builders/docker'
  args: ['push', '${PROD_IMG}']
- id: 'deploy-to-cloud-run'
  name: 'gcr.io/cloud-builders/gcloud'
  entrypoint: 'bash'
  args:
  - '-c'
  - |
    gcloud run deploy auth-service --image=${PROD_IMG} \\
    --binary-authorization=default --region=${REGION} --allow-unauthenticated
images:
  - ${SCAN_IMG}
EOM
echo "Task 4 build is EXPECTED to fail at the severity check."
gcloud builds submit --region=$REGION --config cloudbuild.yaml .

echo "=== Task 5 ==="
cat > Dockerfile << 'EOM'
FROM python:3.12-slim

WORKDIR /app
COPY . ./

RUN pip3 install Flask==3.0.3
RUN pip3 install gunicorn==23.0.0
RUN pip3 install Werkzeug==3.0.4

CMD exec gunicorn --bind :$PORT --workers 1 --threads 8 main:app
EOM
cat Dockerfile
gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" --role="roles/run.admin"
gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" --role="roles/iam.serviceAccountUser"
gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" --role="roles/ondemandscanning.admin"
gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" --role="roles/binaryauthorization.attestorsViewer"
gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" --role="roles/cloudkms.signerVerifier"
gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" --role="roles/containeranalysis.notes.attacher"
gcloud builds submit --region=$REGION --config cloudbuild.yaml .
gcloud beta run services add-iam-policy-binding --region=$REGION --member=allUsers --role=roles/run.invoker auth-service
echo "Service URL:"
gcloud run services describe auth-service --region=$REGION --format='value(status.url)'
}
run_lab
