echo "${CYAN_TEXT}${BOLD_TEXT}==================================================================${RESET_FORMAT}"
echo "${CYAN_TEXT}${BOLD_TEXT}        SUBSCRIBE PERKVERSE - INITIATING EXECUTION...            ${RESET_FORMAT}"
echo "${CYAN_TEXT}${BOLD_TEXT}==================================================================${RESET_FORMAT}"

#!/bin/bash

set -e

echo "Task 1: Create an API key"
echo "Create the API key in Google Cloud Console first."
read -s -p "Paste your API key: " API_KEY
echo
export API_KEY

echo "Finding lab-vm..."
ZONE=$(gcloud compute instances list \
  --filter="name=lab-vm" \
  --format="value(zone)" | head -n 1)

if [ -z "$ZONE" ]; then
  echo "ERROR: lab-vm not found. Start the lab and try again."
  exit 1
fi

echo "Connecting to lab-vm in zone $ZONE..."

API_KEY_B64=$(printf '%s' "$API_KEY" | base64 -w 0)
unset API_KEY

gcloud compute ssh lab-vm \
  --zone="$ZONE" \
  --command="API_KEY_B64=$API_KEY_B64 bash -s" <<'REMOTE'

set -e
export API_KEY="$(printf '%s' "$API_KEY_B64" | base64 -d)"
unset API_KEY_B64

echo "Task 2: Natural Language API entity analysis"

cat > nl_request.json <<'EOF'
{
  "document": {
    "type": "PLAIN_TEXT",
    "content": "With approximately 8.2 million people residing in Boston, the capital city of Massachusetts is one of the largest in the United States."
  },
  "encodingType": "UTF8"
}
EOF

curl -fsS -X POST \
  -H "Content-Type: application/json" \
  --data-binary @nl_request.json \
  "https://language.googleapis.com/v1/documents:analyzeEntities?key=${API_KEY}" \
  -o nl_response.json

echo "Task 2 request completed. Response saved."

echo "Task 3: Speech-to-Text API"

cat > speech_request.json <<'EOF'
{
  "config": {
    "encoding": "FLAC",
    "languageCode": "en-US"
  },
  "audio": {
    "uri": "gs://cloud-samples-tests/speech/brooklyn.flac"
  }
}
EOF

curl -fsS -X POST \
  -H "Content-Type: application/json" \
  --data-binary @speech_request.json \
  "https://speech.googleapis.com/v1/speech:recognize?key=${API_KEY}" \
  -o speech_response.json

echo "Task 3 request completed. Response saved."

echo "Task 4: Sentiment analysis"

cat > sentiment_analysis.py <<'PY'
import argparse
from google.cloud import language_v1

def analyze(movie_review_filename):
    client = language_v1.LanguageServiceClient()

    with open(movie_review_filename, "r") as review_file:
        content = review_file.read()

    document = language_v1.Document(
        content=content,
        type_=language_v1.Document.Type.PLAIN_TEXT
    )

    response = client.analyze_sentiment(request={"document": document})

    for index, sentence in enumerate(response.sentences):
        print(
            f"Sentence {index} sentiment score: "
            f"{sentence.sentiment.score:.2f}"
        )

    print(
        f"Overall Sentiment: Score "
        f"{response.document_sentiment.score:.2f}, Magnitude "
        f"{response.document_sentiment.magnitude:.2f}"
    )

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("movie_review_filename")
    args = parser.parse_args()
    analyze(args.movie_review_filename)
PY

echo "Downloading sentiment samples..."
gsutil cp \
  gs://cloud-samples-tests/natural-language/sentiment-samples.tgz \
  sentiment-samples.tgz

tar -xzf sentiment-samples.tgz

echo "Review files available:"
ls reviews/

echo "Running sentiment analysis..."
python3 sentiment_analysis.py reviews/bladerunner-pos.txt

echo "All four task steps have been executed."
REMOTE

echo "Script execution finished."
echo "Check each task using Check my progress in Google Skills."

echo
echo "${CYAN_TEXT}${BOLD_TEXT}=======================================================${RESET_FORMAT}"
echo "${CYAN_TEXT}${BOLD_TEXT}              LAB COMPLETED SUCCESSFULLY!              ${RESET_FORMAT}"
echo "${CYAN_TEXT}${BOLD_TEXT}=======================================================${RESET_FORMAT}"
echo
echo "${RED_TEXT}${BOLD_TEXT}${UNDERLINE_TEXT}https://www.youtube.com/@PerkVers${RESET_FORMAT}"
echo "${GREEN_TEXT}${BOLD_TEXT}👍 LIKE | 🔄 SHARE | 🔔 SUBSCRIBE${RESET_FORMAT}"
echo "${YELLOW_TEXT}${BOLD_TEXT}PERKVERSE - Google Cloud Arcade Labs & Tech Opportunities${RESET_FORMAT}"
echo "${CYAN_TEXT}${BOLD_TEXT}Follow @PerkVers for more updates${RESET_FORMAT}"
