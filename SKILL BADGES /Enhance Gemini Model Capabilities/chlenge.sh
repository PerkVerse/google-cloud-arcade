cat > gsp525.sh <<'EOF'
#!/bin/bash
# ============ GSP525 - Enhance Gemini Model Capabilities ============
G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[1;36m'; N='\033[0m'
step(){ echo -e "\n${C}==> $1${N}"; }
ok(){ echo -e "${G}✔ $1${N}"; }
warn(){ echo -e "${Y}! $1${N}"; }

step "Detecting project, region and zone"
PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
[ -z "$PROJECT_ID" ] && PROJECT_ID=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/project/project-id)
[ -z "$PROJECT_ID" ] && PROJECT_ID=$(gcloud projects list --format="value(projectId)" --limit=1 2>/dev/null)

ZONE=$(gcloud config get-value compute/zone 2>/dev/null)
[ -z "$ZONE" ] && ZONE=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/zone 2>/dev/null | awk -F/ '{print $NF}')
REGION=$(gcloud config get-value compute/region 2>/dev/null)
[ -z "$REGION" ] && [ -n "$ZONE" ] && REGION="${ZONE%-*}"
[ -z "$REGION" ] && REGION="us-central1"

export PROJECT_ID REGION ZONE
ok "Project: $PROJECT_ID | Region: $REGION | Zone: ${ZONE:-n/a}"

step "Enabling required APIs"
gcloud services enable aiplatform.googleapis.com --project "$PROJECT_ID" 2>/dev/null && ok "Vertex AI API enabled" || warn "API enable skipped (may already be on)"

step "Installing Gen AI SDK"
for i in 1 2 3; do
  pip install -q --upgrade google-genai --break-system-packages 2>/dev/null || pip install -q --upgrade google-genai && break
  warn "Retry $i..."; sleep 3
done
ok "google-genai installed"

cat > /tmp/gsp525.py <<'PY'
import os, sys, json, time
from google import genai
from google.genai.types import (GenerateContentConfig, Tool, ToolCodeExecution,
                                GoogleSearch, Schema, Type)

PROJECT = os.environ["PROJECT_ID"]
REGIONS = list(dict.fromkeys([os.environ["REGION"], "us-central1", "us-east4"]))
MODELS  = ["gemini-2.5-flash", "gemini-2.0-flash-001", "gemini-2.5-flash-lite"]

def say(m): print(f"\033[1;36m==> {m}\033[0m")
def good(m): print(f"\033[1;32m✔ {m}\033[0m")
def bad(m): print(f"\033[1;33m! {m}\033[0m")

def run(label, fn):
    """Try every region/model combo until one works."""
    for region in REGIONS:
        client = genai.Client(vertexai=True, project=PROJECT, location=region)
        for model in MODELS:
            for attempt in (1, 2):
                try:
                    out = fn(client, model)
                    good(f"{label} done (model={model}, region={region})")
                    return out
                except Exception as e:
                    bad(f"{label}: {model}@{region} try {attempt} failed -> {str(e)[:120]}")
                    time.sleep(2)
    print(f"\033[1;31m✘ {label} failed everywhere\033[0m"); sys.exit(1)

# ---------- Task 2: Code execution ----------
say("Task 2: Code execution")
def t2(client, model):
    cfg = GenerateContentConfig(tools=[Tool(code_execution=ToolCodeExecution())], temperature=0)
    r = client.models.generate_content(
        model=model,
        contents="Generate and run Python code to calculate the sum of the first 50 prime numbers.",
        config=cfg)
    for p in r.candidates[0].content.parts:
        if p.executable_code: print("CODE:\n", p.executable_code.code)
        if p.code_execution_result: print("OUTPUT:\n", p.code_execution_result.output)
    return r
run("Code execution", t2)

# ---------- Task 3: Grounding ----------
say("Task 3: Grounding with Google Search")
PRODUCT = "Nike Air Jordan XXXVI"
def t3(client, model):
    cfg = GenerateContentConfig(tools=[Tool(google_search=GoogleSearch())], temperature=0)
    r = client.models.generate_content(
        model=model,
        contents=f"What are the current price, features and customer reviews of the {PRODUCT} basketball shoe?",
        config=cfg)
    print(r.text[:800])
    return r
run("Grounding", t3)

# ---------- Task 4: Competitor pricing + JSON schema ----------
say("Task 4: Competitor pricing with JSON schema")
def t4(client, model):
    # Step 1: grounded search (search tool and schema can't be combined in one call)
    g = client.models.generate_content(
        model=model,
        contents=f"Find the price of the {PRODUCT} sold by a competitor retailer (e.g. Foot Locker, Nike, Dick's). Give product name, competitor name and price in USD.",
        config=GenerateContentConfig(tools=[Tool(google_search=GoogleSearch())]))
    # Step 2: structure with JSON schema
    schema = Schema(type=Type.OBJECT, properties={
        "product": Schema(type=Type.STRING),
        "competitor": Schema(type=Type.STRING),
        "price": Schema(type=Type.NUMBER),
        "currency": Schema(type=Type.STRING),
    }, required=["product", "competitor", "price"])
    r = client.models.generate_content(
        model=model,
        contents=f"Extract the data from this text:\n{g.text}",
        config=GenerateContentConfig(response_mime_type="application/json",
                                     response_schema=schema, temperature=0))
    print(json.dumps(json.loads(r.text), indent=2))
    return r
run("Structured extraction", t4)

print("\n\033[1;32m🎉 All tasks executed. Now click 'Check my progress' for each task.\033[0m")
PY

step "Running tasks"
python3 /tmp/gsp525.py
EOF
bash gsp525.sh
