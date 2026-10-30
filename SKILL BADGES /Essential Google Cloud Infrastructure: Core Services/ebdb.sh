#!/usr/bin/env bash
# ============================================================
#  Examine Billing Data with BigQuery  |  Auto Lab Runner
#  Auto-retry (up to 20x) + self-healing fixes
# ============================================================
set -uo pipefail

# ---------- Look & feel ----------
G="\033[1;32m"; R="\033[1;31m"; Y="\033[1;33m"; B="\033[1;36m"; N="\033[0m"
step() { echo -e "\n${B}==> $*${N}"; }
ok()   { echo -e "${G}[ OK ]${N} $*"; }
warn() { echo -e "${Y}[WARN]${N} $*"; }
fail() { echo -e "${R}[FAIL]${N} $*"; }

# ---------- Config ----------
DATASET="billing_dataset"
TABLE="sampleinfotable"
LOCATION="US"
SOURCE_URI="gs://cloud-training/archinfra/BillingExport-2020-09-18.avro"
MAX_TRIES=20
FQ="${DATASET}.${TABLE}"

# ---------- Retry engine ----------
# usage: retry "<label>" "<fix_function>" command args...
retry() {
  local label="$1" fixer="$2"; shift 2
  local n=1 delay=2
  while (( n <= MAX_TRIES )); do
    if "$@"; then ok "$label"; return 0; fi
    warn "$label failed (attempt $n/$MAX_TRIES) - applying auto-fix..."
    [[ -n "$fixer" ]] && "$fixer" >/dev/null 2>&1
    sleep "$delay"
    (( delay < 10 )) && (( delay += 1 ))
    (( n++ ))
  done
  fail "$label failed after $MAX_TRIES attempts"
  return 1
}

# ---------- Auto-fix helpers ----------
fix_project() {
  local p
  p="$(gcloud config get-value project 2>/dev/null)"
  [[ -z "$p" || "$p" == "(unset)" ]] && p="${DEVSHELL_PROJECT_ID:-}"
  [[ -z "$p" ]] && p="$(gcloud projects list --filter='projectId:qwiklabs-gcp*' \
                        --format='value(projectId)' --limit=1 2>/dev/null)"
  [[ -n "$p" ]] && gcloud config set project "$p" --quiet
  PROJECT_ID="$p"
}
fix_api() { gcloud services enable bigquery.googleapis.com bigquerystorage.googleapis.com --quiet; }
fix_dataset() {
  bq --location="$LOCATION" mk -d --default_table_expiration 86400 "${PROJECT_ID}:${DATASET}" 2>/dev/null || true
}
fix_generic() { fix_project; fix_api; }

# ---------- Query helpers ----------
run_sql()   { bq query --quiet --nouse_legacy_sql --format=pretty --max_rows=15 "$1"; }
scalar()    { bq query --quiet --nouse_legacy_sql --format=csv "$1" | tail -n1; }

# ============================================================
step "Preparing environment"
# ============================================================
PROJECT_ID=""
fix_project
if [[ -z "${PROJECT_ID}" ]]; then fail "No project found. Open Cloud Shell from the lab console."; exit 1; fi
ok "Project: ${PROJECT_ID}"
retry "BigQuery API ready" "fix_generic" gcloud services enable bigquery.googleapis.com --quiet || true

# ============================================================
step "TASK 1 | Create dataset '${DATASET}'"
# ============================================================
create_dataset() {
  if bq show --format=none "${PROJECT_ID}:${DATASET}" 2>/dev/null; then return 0; fi
  bq --location="$LOCATION" mk -d \
     --default_table_expiration 86400 \
     --description "Billing dataset" \
     "${PROJECT_ID}:${DATASET}"
}
retry "Dataset created" "fix_generic" create_dataset

step "TASK 1 | Import Avro file into '${TABLE}'"
load_table() {
  bq --location="$LOCATION" load \
     --source_format=AVRO \
     --replace \
     "${PROJECT_ID}:${FQ}" "${SOURCE_URI}"
}
retry "Table loaded from Cloud Storage" "fix_dataset" load_table

# ============================================================
step "TASK 2 | Examine the table"
# ============================================================
bq show --schema --format=prettyjson "${PROJECT_ID}:${FQ}" | head -n 25
ROWS=$(scalar "SELECT COUNT(*) FROM \`${FQ}\`")
ok "Total rows in table (Quiz answer) : ${ROWS}"

# ============================================================
step "TASK 3 | Simple query (cost > 0)"
# ============================================================
q3() { run_sql "SELECT * FROM \`${FQ}\` WHERE cost > 0"; }
retry "Query: cost > 0" "fix_generic" q3
C3=$(scalar "SELECT COUNT(*) FROM \`${FQ}\` WHERE cost > 0")
ok "Rows with cost > 0 (Quiz answer)  : ${C3}"

# ============================================================
step "TASK 4 | Analyze large billing dataset"
# ============================================================
q4a() { run_sql "SELECT billing_account_id, project.id, project.name, service.description,
  currency, currency_conversion_rate, cost, usage.amount, usage.pricing_unit FROM \`${FQ}\`"; }
retry "Query 1: all billing lines" "fix_generic" q4a
ok "Total lines verified: $(scalar "SELECT COUNT(*) FROM \`${FQ}\`")"

q4b() { run_sql "SELECT service.description, sku.description, location.country, cost, project.id,
  project.name, currency, currency_conversion_rate, usage.amount, usage.unit
  FROM \`${FQ}\` WHERE cost > 0 ORDER BY usage_end_time DESC LIMIT 100"; }
retry "Query 2: latest 100 charged records" "fix_generic" q4b

q4c() { run_sql "SELECT service.description, sku.description, location.country, cost, project.id,
  project.name, currency, currency_conversion_rate, usage.amount, usage.unit
  FROM \`${FQ}\` WHERE cost > 10"; }
retry "Query 3: charges over \$10" "fix_generic" q4c

q4d() { run_sql "SELECT service.description, COUNT(*) AS billing_records
  FROM \`${FQ}\` GROUP BY service.description ORDER BY billing_records DESC"; }
echo -e "${Y}Quiz: product with most billing records ->${N}"
retry "Query 4: most records per product" "fix_generic" q4d

q4e() { run_sql "SELECT service.description, COUNT(*) AS billing_records
  FROM \`${FQ}\` WHERE cost > 1 GROUP BY service.description ORDER BY billing_records DESC"; }
echo -e "${Y}Quiz: product with most records over \$1 ->${N}"
retry "Query 5: most frequent product > \$1" "fix_generic" q4e

q4f() { run_sql "SELECT usage.unit, COUNT(*) AS billing_records
  FROM \`${FQ}\` WHERE cost > 0 GROUP BY usage.unit ORDER BY billing_records DESC"; }
echo -e "${Y}Quiz: most commonly charged unit ->${N}"
retry "Query 6: most common unit of measure" "fix_generic" q4f

q4g() { run_sql "SELECT service.description, ROUND(SUM(cost),2) AS total_cost
  FROM \`${FQ}\` GROUP BY service.description ORDER BY total_cost DESC"; }
echo -e "${Y}Quiz: product with highest total cost ->${N}"
retry "Query 7: highest aggregate cost" "fix_generic" q4g

# ============================================================
step "FINAL CHECK"
# ============================================================
if bq show --format=none "${PROJECT_ID}:${FQ}" 2>/dev/null; then
  ok "Dataset + table exist. All tasks completed."
else
  fail "Table missing - re-run the script once more."
fi
echo -e "\n${G}DONE!${N} Ab lab page par jao, 'Check my progress' (Task 1, 3, 4) click karo,"
echo -e "quiz answers upar ke output se select karo, phir ${G}End Lab${N} dabao."
