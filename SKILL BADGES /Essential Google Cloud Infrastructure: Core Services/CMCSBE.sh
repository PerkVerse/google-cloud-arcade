#!/bin/bash
# ==========================================================================
#  Create and Manage Cloud Storage Buckets and Encryption  (CBL005)
#  Full auto-solver for Google Cloud Shell
#  - Auto-detects Project ID
#  - Asks for Region (Enter = default)
#  - Every step auto-retries (default 15 times) + fallback commands
# ==========================================================================

# ---------- Colors ----------
R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[34m'; C=$'\e[36m'; D=$'\e[2m'; W=$'\e[1m'; N=$'\e[0m'

MAX_TRIES=${MAX_TRIES:-15}     # max retries per step (10-20 recommended)
SLEEP_SEC=${SLEEP_SEC:-5}      # wait between retries
LOG="/tmp/gcs_lab_$(date +%s).log"
FAILED=()

# ---------- Pretty helpers ----------
line()    { printf "${D}%s${N}\n" "──────────────────────────────────────────────────────────"; }
section() { echo; line; echo "  ${B}${W}$1${N}"; line; }
ok()      { echo "  ${G}✔${N} $1"; }
info()    { echo "  ${C}ℹ${N} $1"; }
warn()    { echo "  ${Y}⚠${N} $1"; }
err()     { echo "  ${R}✘${N} $1"; }
show()    { eval "$1" 2>&1 | head -n "${2:-6}" | sed "s/^/      ${D}│${N} /"; }

# ---------- Auto-retry engine ----------
# usage: run "Description" "command 1" ["fallback command 2" ...]
run() {
  local desc="$1"; shift
  local n=1 c
  while (( n <= MAX_TRIES )); do
    for c in "$@"; do
      if eval "$c" >>"$LOG" 2>&1; then
        (( n > 1 )) && ok "$desc ${D}(attempt $n)${N}" || ok "$desc"
        return 0
      fi
    done
    warn "$desc ${D}— attempt $n/$MAX_TRIES failed, retry in ${SLEEP_SEC}s${N}"
    tail -n 1 "$LOG" | cut -c1-110 | sed "s/^/      ${D}/;s/$/${N}/"
    sleep "$SLEEP_SEC"; ((n++))
  done
  err "$desc ${D}— $MAX_TRIES attempts, still failing${N}"
  FAILED+=("$desc"); return 1
}

# ---------- gsutil wrapper with CSEK keys ----------
ENC=""; DEC1=""
GSK() {
  local o=()
  [ -n "$ENC" ]  && o+=(-o "GSUtil:encryption_key=$ENC")
  [ -n "$DEC1" ] && o+=(-o "GSUtil:decryption_key1=$DEC1")
  gsutil "${o[@]}" "$@"
}

gen_key() { python3 -c 'import base64,os; print(base64.encodebytes(os.urandom(32)).decode().strip())'; }

# set_boto <key_name> <value> <enabled:yes|no>
set_boto() {
  local k="$1" v="$2" p=""; [ "$3" = "no" ] && p="# "
  if grep -qE "^[# ]*$k[ ]*=" "$BOTO"; then
    sed -i -E "s|^[# ]*$k[ ]*=.*|${p}${k}=${v}|" "$BOTO"
  elif grep -q "^\[GSUtil\]" "$BOTO"; then
    sed -i "/^\[GSUtil\]/a ${p}${k}=${v}" "$BOTO"
  else
    printf "\n[GSUtil]\n%s%s=%s\n" "$p" "$k" "$v" >> "$BOTO"
  fi
}

clear
echo
echo "${C}${W}  ╔════════════════════════════════════════════════════════╗${N}"
echo "${C}${W}  ║   Cloud Storage Buckets & Encryption — Auto Solver     ║${N}"
echo "${C}${W}  ║   Lab: CBL005   •   Auto-Retry + Fallback enabled      ║${N}"
echo "${C}${W}  ╚════════════════════════════════════════════════════════╝${N}"

# ==========================================================================
section "STEP 0 │ Project & Region"
# ==========================================================================
PROJECT_ID="${DEVSHELL_PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
if [ -z "$PROJECT_ID" ] || [ "$PROJECT_ID" = "(unset)" ]; then
  PROJECT_ID=$(gcloud projects list --format="value(projectId)" --limit=1 2>/dev/null)
fi
if [ -z "$PROJECT_ID" ]; then
  err "Could not detect Project ID. Log in to the lab console and open Cloud Shell first."
  exit 1
fi
gcloud config set project "$PROJECT_ID" >/dev/null 2>&1
ok "Project ID detected : ${W}$PROJECT_ID${N}"

DEFAULT_REGION="us-east4"
echo
read -rp "  ${W}Region${N} enter ${D}[default: $DEFAULT_REGION]${N} : " REGION
REGION="${REGION:-$DEFAULT_REGION}"

gcloud config set compute/region "$REGION" >/dev/null 2>&1

BUCKET_NAME_1="${PROJECT_ID}-bucket"
export PROJECT_ID REGION BUCKET_NAME_1
echo
ok "Region      : ${W}$REGION${N}"
ok "Bucket name : ${W}$BUCKET_NAME_1${N}"
info "Log file    : $LOG"

WORKDIR="$HOME/gcs_lab"; mkdir -p "$WORKDIR"; cd "$WORKDIR" || exit 1

# ==========================================================================
section "TASK 1 │ Prepare the lab environment"
# ==========================================================================
run "Storage API enable" "gcloud services enable storage.googleapis.com --project=$PROJECT_ID"

run "Create bucket (Region, Fine-grained access)" \
  "gcloud storage buckets describe gs://$BUCKET_NAME_1" \
  "gcloud storage buckets create gs://$BUCKET_NAME_1 --project=$PROJECT_ID --location=$REGION --no-uniform-bucket-level-access" \
  "gcloud storage buckets create gs://$BUCKET_NAME_1 --project=$PROJECT_ID --location=$REGION" \
  "gsutil mb -p $PROJECT_ID -l $REGION gs://$BUCKET_NAME_1"

run "Public access prevention OFF" \
  "gcloud storage buckets update gs://$BUCKET_NAME_1 --no-public-access-prevention" \
  "gcloud storage buckets update gs://$BUCKET_NAME_1 --public-access-prevention=inherited" \
  "gsutil pap set inherited gs://$BUCKET_NAME_1"

run "Sample file download (setup.html)" \
  "curl -fsSL https://hadoop.apache.org/docs/current/hadoop-project-dist/hadoop-common/ClusterSetup.html -o setup.html && [ -s setup.html ]" \
  "wget -q https://hadoop.apache.org/docs/current/hadoop-project-dist/hadoop-common/ClusterSetup.html -O setup.html && [ -s setup.html ]"

run "Make setup2.html & setup3.html" "cp setup.html setup2.html && cp setup.html setup3.html"

# ==========================================================================
section "TASK 2 │ Access Control Lists (ACLs)"
# ==========================================================================
run "Copy setup.html to bucket" \
  "gcloud storage cp setup.html gs://$BUCKET_NAME_1/" "gsutil cp setup.html gs://$BUCKET_NAME_1/"

run "Get default ACL (acl.txt)" \
  "gcloud storage objects get-iam-policy gs://$BUCKET_NAME_1/setup.html > acl.txt" \
  "gsutil acl get gs://$BUCKET_NAME_1/setup.html > acl.txt"
show "cat acl.txt" 4

run "Set ACL → private" \
  "gcloud storage objects update gs://$BUCKET_NAME_1/setup.html --predefined-acl=private" \
  "gsutil acl set private gs://$BUCKET_NAME_1/setup.html"
run "Get private ACL (acl2.txt)" \
  "gcloud storage objects get-iam-policy gs://$BUCKET_NAME_1/setup.html > acl2.txt" \
  "gsutil acl get gs://$BUCKET_NAME_1/setup.html > acl2.txt"

run "Make file PUBLIC READABLE" \
  "gcloud storage objects add-iam-policy-binding gs://$BUCKET_NAME_1/setup.html --member=allUsers --role=roles/storage.legacyObjectReader" \
  "gsutil acl ch -u AllUsers:R gs://$BUCKET_NAME_1/setup.html" \
  "gcloud storage objects update gs://$BUCKET_NAME_1/setup.html --add-acl-grant=entity=AllUsers,role=READER"
run "Get public ACL (acl3.txt)" \
  "gcloud storage objects get-iam-policy gs://$BUCKET_NAME_1/setup.html > acl3.txt" \
  "gsutil acl get gs://$BUCKET_NAME_1/setup.html > acl3.txt"
show "cat acl3.txt" 6

run "Verify public link works" \
  "curl -sfI https://storage.googleapis.com/$BUCKET_NAME_1/setup.html | head -1 | grep -q 200"

run "Delete local setup.html" "rm -f setup.html && [ ! -f setup.html ]"
run "Copy setup.html back from bucket" \
  "gcloud storage cp gs://$BUCKET_NAME_1/setup.html setup.html && [ -s setup.html ]" \
  "gsutil cp gs://$BUCKET_NAME_1/setup.html setup.html"

# ==========================================================================
section "TASK 3 │ Customer-Supplied Encryption Keys (CSEK)"
# ==========================================================================
BOTO=$(gsutil version -l 2>/dev/null | grep -oE '/[^ ,]*\.boto' | head -1)
BOTO="${BOTO:-$HOME/.boto}"
[ -s "$BOTO" ] || gsutil config -n </dev/null >/dev/null 2>&1
[ -f "$BOTO" ] || touch "$BOTO"
info ".boto file : $BOTO"

KEY1=$(gen_key); ENC="$KEY1"
ok "CSEK key #1 generated : ${D}${KEY1:0:12}…${N}"

set_boto encryption_key "$KEY1" yes
ok "encryption_key set in .boto"

run "KMS default key remove" "gsutil kms encryption -d gs://$BUCKET_NAME_1" "true"
run "Upload setup2.html (encrypted)" "GSK cp setup2.html gs://$BUCKET_NAME_1/"
run "Upload setup3.html (encrypted)" "GSK cp setup3.html gs://$BUCKET_NAME_1/"
run "Verify setup2.html is customer-encrypted" \
  "gsutil ls -L gs://$BUCKET_NAME_1/setup2.html | grep -qi 'encryption'"

run "Delete local setup*" "rm -f setup*"
run "Download all setup files back" \
  "GSK cp gs://$BUCKET_NAME_1/setup.html gs://$BUCKET_NAME_1/setup2.html gs://$BUCKET_NAME_1/setup3.html ./"
for f in setup.html setup2.html setup3.html; do
  echo "      ${D}│ $f → $(head -c 60 $f | tr -d '\n')…${N}"
done

# ==========================================================================
section "TASK 4 │ Rotate CSEK keys"
# ==========================================================================
set_boto encryption_key  "$KEY1" no
set_boto decryption_key1 "$KEY1" yes
DEC1="$KEY1"
ok "Old key → decryption_key1"

KEY2=$(gen_key); ENC="$KEY2"
set_boto encryption_key "$KEY2" yes
ok "CSEK key #2 generated → encryption_key : ${D}${KEY2:0:12}…${N}"

run "Rewrite key for setup2.html (setup3 intentionally skipped)" \
  "GSK rewrite -k gs://$BUCKET_NAME_1/setup2.html"

set_boto decryption_key1 "$KEY1" no
DEC1=""
ok "decryption_key1 commented out"

run "Download setup2.html → recover2.html" \
  "GSK cp gs://$BUCKET_NAME_1/setup2.html recover2.html && [ -s recover2.html ]"

if GSK cp gs://$BUCKET_NAME_1/setup3.html recover3.html >>"$LOG" 2>&1; then
  warn "recover3.html downloaded (it was expected to fail)"
else
  ok "recover3.html FAILED — ${D}this is expected in the lab ✔${N}"
fi

# ==========================================================================
section "TASK 5 │ Lifecycle management"
# ==========================================================================
show "gcloud storage buckets describe gs://$BUCKET_NAME_1 --format='json(lifecycle)'" 4
cat > life.json <<'EOF'
{
  "rule":
  [
    {
      "action": {"type": "Delete"},
      "condition": {"age": 31}
    }
  ]
}
EOF
ok "life.json created"
run "Set lifecycle policy (delete after 31 days)" \
  "gcloud storage buckets update gs://$BUCKET_NAME_1 --lifecycle-file=life.json" \
  "gsutil lifecycle set life.json gs://$BUCKET_NAME_1"
run "Verify lifecycle" \
  "gcloud storage buckets describe gs://$BUCKET_NAME_1 --format='json(lifecycle_config)' | grep -q Delete" \
  "gsutil lifecycle get gs://$BUCKET_NAME_1 | grep -q Delete"
show "gcloud storage buckets describe gs://$BUCKET_NAME_1 --format='json(lifecycle_config)'" 12

# ==========================================================================
section "TASK 6 │ Versioning"
# ==========================================================================
run "Enable versioning" \
  "gcloud storage buckets update gs://$BUCKET_NAME_1 --versioning" \
  "gsutil versioning set on gs://$BUCKET_NAME_1"
run "Verify versioning" \
  "gcloud storage buckets describe gs://$BUCKET_NAME_1 --format='json(versioning_enabled)' | grep -q true" \
  "gsutil versioning get gs://$BUCKET_NAME_1 | grep -qi enabled"

info "Original size : $(stat -c%s setup.html) bytes"
sed -i '1,5d' setup.html
run "Upload version 2 (5 lines deleted)" \
  "gcloud storage cp -v setup.html gs://$BUCKET_NAME_1" \
  "gcloud storage cp setup.html gs://$BUCKET_NAME_1" \
  "gsutil cp setup.html gs://$BUCKET_NAME_1"
sed -i '1,5d' setup.html
run "Upload version 3 (5 more lines deleted)" \
  "gcloud storage cp -v setup.html gs://$BUCKET_NAME_1" \
  "gcloud storage cp setup.html gs://$BUCKET_NAME_1" \
  "gsutil cp setup.html gs://$BUCKET_NAME_1"

run "List all versions" "gcloud storage ls -a gs://$BUCKET_NAME_1/setup.html | grep -c '#' | grep -qE '^[2-9]'"
show "gcloud storage ls -a gs://$BUCKET_NAME_1/setup.html" 6

VERSION_NAME=$(gcloud storage ls -a gs://$BUCKET_NAME_1/setup.html 2>/dev/null | grep '#' | sort -t'#' -k2 -n | head -1)
export VERSION_NAME
ok "Oldest version : ${D}$VERSION_NAME${N}"

run "Download oldest (original) version" \
  "gcloud storage cp '$VERSION_NAME' recovered.txt && [ -s recovered.txt ]" \
  "gsutil cp '$VERSION_NAME' recovered.txt"
echo "      ${D}│ setup.html    : $(stat -c%s setup.html) bytes (current)${N}"
echo "      ${D}│ recovered.txt : $(stat -c%s recovered.txt) bytes (original, should be larger)${N}"

# ==========================================================================
section "TASK 7 │ Synchronize a directory to a bucket"
# ==========================================================================
run "Create nested directories & copy files" \
  "mkdir -p firstlevel/secondlevel && cp setup.html firstlevel && cp setup.html firstlevel/secondlevel"
run "rsync ./firstlevel → bucket" \
  "gcloud storage rsync ./firstlevel gs://$BUCKET_NAME_1/firstlevel --recursive" \
  "gsutil -m rsync -r ./firstlevel gs://$BUCKET_NAME_1/firstlevel"
show "gcloud storage ls -r gs://$BUCKET_NAME_1/firstlevel" 10

# ==========================================================================
section "FINAL │ Verification summary"
# ==========================================================================
chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else err "$1"; fi; }
chk "Bucket created ($REGION)"              "gcloud storage buckets describe gs://$BUCKET_NAME_1"
chk "setup.html publicly readable"          "curl -sfI https://storage.googleapis.com/$BUCKET_NAME_1/setup.html | head -1 | grep -q 200"
chk "setup2/setup3 customer-encrypted"      "gsutil ls -L gs://$BUCKET_NAME_1/setup3.html | grep -qi encryption"
chk "Lifecycle policy set (31 days)"        "gsutil lifecycle get gs://$BUCKET_NAME_1 | grep -q Delete"
chk "Versioning enabled"                    "gsutil versioning get gs://$BUCKET_NAME_1 | grep -qi enabled"
chk "firstlevel/secondlevel synced"         "gcloud storage ls -r gs://$BUCKET_NAME_1/firstlevel | grep -q secondlevel"

echo
if [ ${#FAILED[@]} -eq 0 ]; then
  echo "  ${G}${W}🎉 All steps completed successfully!${N}"
else
  echo "  ${Y}${W}These steps failed:${N}"
  for f in "${FAILED[@]}"; do echo "   ${R}•${N} $f"; done
  echo "  ${D}Re-run the script: bash gcs_lab_autosolver.sh  |  Log: $LOG${N}"
fi
echo
echo "  ${W}Now go to the lab page and click 'Check my progress' under each task.${N}"
echo
