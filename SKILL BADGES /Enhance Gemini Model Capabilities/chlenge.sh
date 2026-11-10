# ===== GSP525 - ALL TASKS IN ONE CELL =====
import os, json, time, subprocess
from google import genai
from google.genai.types import GenerateContentConfig, Tool, ToolCodeExecution, GoogleSearch

def sh(c): return subprocess.run(c, shell=True, capture_output=True, text=True).stdout.strip()

# --- Task 1: auto-detect project / region, create client ---
PROJECT_ID = globals().get("PROJECT_ID") or sh("gcloud config get-value project 2>/dev/null") \
    or sh("curl -s -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/project/project-id")
ZONE = sh("curl -s -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/zone | awk -F/ '{print $NF}'")
LOCATION = globals().get("LOCATION") or sh("gcloud config get-value compute/region 2>/dev/null") \
    or (ZONE.rsplit("-", 1)[0] if ZONE else "") or "us-central1"
print(f"✔ Project: {PROJECT_ID} | Region: {LOCATION} | Zone: {ZONE or 'n/a'}")

# Model: keep the notebook's MODEL_ID if it already has one, else find one that works
candidates = [globals().get("MODEL_ID"), "gemini-3.6-flash", "gemini-3-flash", "gemini-2.5-flash", "gemini-2.0-flash-001"]
candidates = [m for m in dict.fromkeys(candidates) if m]

def make_client(loc): return genai.Client(vertexai=True, project=PROJECT_ID, location=loc)

client = None
for loc in dict.fromkeys([LOCATION, "global", "us-central1"]):
    c = make_client(loc)
    for m in candidates:
        try:
            c.models.generate_content(model=m, contents="Say OK")
            client, LOCATION, MODEL_ID = c, loc, m
            break
        except Exception as e:
            print(f"! {m}@{loc} failed: {str(e)[:90]}")
    if client: break
assert client, "No model worked - re-run once after 30 seconds"
print(f"✔ Using model {MODEL_ID} @ {LOCATION}")

def retry(fn, tries=3):
    for i in range(tries):
        try: return fn()
        except Exception as e:
            print(f"! retry {i+1}: {str(e)[:100]}"); time.sleep(4)
    raise RuntimeError("failed after retries")

# --- Task 2: code execution ---
code_execution_tool = Tool(code_execution=ToolCodeExecution())
prompt = "Generate and run Python code to calculate the sum of the first 50 prime numbers."
response = retry(lambda: client.models.generate_content(
    model=MODEL_ID, contents=prompt,
    config=GenerateContentConfig(tools=[code_execution_tool], temperature=0)))
for p in response.candidates[0].content.parts:
    if p.executable_code: print("CODE:\n", p.executable_code.code)
    if p.code_execution_result: print("OUTPUT:\n", p.code_execution_result.output)
print("✔ Task 2 done")

# --- Task 3: grounding with Google Search ---
google_search_tool = Tool(google_search=GoogleSearch())
product = "Nike Air Jordan XXXVI"
prompt = f"What are the price, features and customer reviews of the {product}?"
response = retry(lambda: client.models.generate_content(
    model=MODEL_ID, contents=prompt,
    config=GenerateContentConfig(tools=[google_search_tool], temperature=0)))
print(response.text[:600])
print("✔ Task 3 done")

# --- Task 4: competitor pricing + JSON schema ---
if "response_schema" not in globals():   # use the notebook's own schema when it exists
    response_schema = {
        "type": "OBJECT",
        "properties": {
            "product": {"type": "STRING"},
            "competitor": {"type": "STRING"},
            "price": {"type": "NUMBER"},
            "currency": {"type": "STRING"},
        },
        "required": ["product", "competitor", "price"],
    }

prompt = (f"Find the price of the {product} basketball sneaker sold by a competitor retailer "
          f"(for example Foot Locker or Dick's). Give product name, competitor name and price in USD.")
search_resp = retry(lambda: client.models.generate_content(
    model=MODEL_ID, contents=prompt,
    config=GenerateContentConfig(tools=[google_search_tool], temperature=0)))

response = retry(lambda: client.models.generate_content(
    model=MODEL_ID,
    contents=f"Extract the data from this text:\n{search_resp.text}",
    config=GenerateContentConfig(response_mime_type="application/json",
                                 response_schema=response_schema, temperature=0)))
print(json.dumps(json.loads(response.text), indent=2))
print("\n🎉 All tasks executed - now click 'Check my progress' on each task")
