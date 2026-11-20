#!/usr/bin/env bash
# One-time Firebase setup for the Thanksgiving Dog Show Ballot.
# Run in Google Cloud Shell, signed in as the owner of the Firebase project:
#   bash setup_firebase.sh
# Safe to run more than once.
set -euo pipefail

PROJECT="dogshowapp-e9b1b"
SITE_DOMAIN="kyle-b-frazier.github.io"
FIRESTORE_LOCATION="nam5"   # US multi-region; only used if the database doesn't exist yet

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
json() { python3 -c "import sys,json; d=json.load(sys.stdin); print($1)"; }

gcloud config set project "$PROJECT" >/dev/null 2>&1
TOKEN="$(gcloud auth print-access-token)"
api() {  # api METHOD URL [JSON_BODY]
  local method="$1" url="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -sS -X "$method" -H "Authorization: Bearer $TOKEN" -H "x-goog-user-project: $PROJECT" \
         -H "Content-Type: application/json" "$url" -d "$body"
  else
    curl -sS -X "$method" -H "Authorization: Bearer $TOKEN" -H "x-goog-user-project: $PROJECT" "$url"
  fi
}

say "1/6  Turning on the Google APIs Firebase needs"
gcloud services enable firebase.googleapis.com identitytoolkit.googleapis.com \
  firestore.googleapis.com firebaserules.googleapis.com --project "$PROJECT"
ok "APIs enabled"

say "2/6  Reading your web app's config (registering one if needed)"
APPS_RESP="$(api GET "https://firebase.googleapis.com/v1beta1/projects/$PROJECT/webApps")"
if echo "$APPS_RESP" | grep -q '"error"'; then
  warn "Firebase returned an error while listing web apps:"
  echo "$APPS_RESP"
  exit 1
fi
APP_ID="$(echo "$APPS_RESP" | json '(d.get("apps") or [{}])[0].get("appId","")')"
if [ -z "$APP_ID" ]; then
  OP_RESP="$(api POST "https://firebase.googleapis.com/v1beta1/projects/$PROJECT/webApps" '{"displayName":"ballot-site"}')"
  if echo "$OP_RESP" | grep -q '"error"'; then
    warn "Couldn't register a web app:"; echo "$OP_RESP"; exit 1
  fi
  OP="$(echo "$OP_RESP" | json 'd["name"]')"
  for i in $(seq 1 30); do
    sleep 2
    OP_STATE="$(api GET "https://firebase.googleapis.com/v1beta1/$OP")"
    if [ "$(echo "$OP_STATE" | json 'd.get("done", False)')" = "True" ]; then
      if echo "$OP_STATE" | grep -q '"error"'; then warn "Registering the web app failed:"; echo "$OP_STATE"; exit 1; fi
      APP_ID="$(echo "$OP_STATE" | json 'd["response"]["appId"]')"
      break
    fi
  done
  [ -n "$APP_ID" ] || { warn "Timed out waiting for the web app to register; re-run the script."; exit 1; }
  ok "Registered a new web app ($APP_ID)"
fi
CONFIG_JSON="$(api GET "https://firebase.googleapis.com/v1beta1/projects/$PROJECT/webApps/$APP_ID/config")"
if echo "$CONFIG_JSON" | grep -q '"error"'; then warn "Couldn't read the web app config:"; echo "$CONFIG_JSON"; exit 1; fi
ok "Using web app $APP_ID"

say "3/6  Allowing $SITE_DOMAIN to use sign-in"
AUTH_CFG="$(api GET "https://identitytoolkit.googleapis.com/admin/v2/projects/$PROJECT/config")"
if echo "$AUTH_CFG" | grep -q '"error"'; then
  warn "Authentication isn't set up yet. Open https://console.firebase.google.com/project/$PROJECT/authentication"
  warn "click 'Get started', then re-run this script."
  exit 1
fi
NEW_DOMAINS="$(echo "$AUTH_CFG" | python3 -c '
import sys, json
d = json.load(sys.stdin).get("authorizedDomains", [])
site = sys.argv[1]
if site not in d:
    d.append(site)
print(json.dumps({"authorizedDomains": d}))' "$SITE_DOMAIN")"
api PATCH "https://identitytoolkit.googleapis.com/admin/v2/projects/$PROJECT/config?updateMask=authorizedDomains" "$NEW_DOMAINS" >/dev/null
ok "Authorized domains: $(echo "$NEW_DOMAINS" | json '", ".join(d["authorizedDomains"])')"

say "4/6  Checking Google sign-in"
GOOGLE="$(api GET "https://identitytoolkit.googleapis.com/admin/v2/projects/$PROJECT/defaultSupportedIdpConfigs/google.com")"
if [ "$(echo "$GOOGLE" | json 'd.get("enabled", False)')" = "True" ]; then
  ok "Google sign-in is on"
  GOOGLE_ON=1
else
  warn "Google sign-in is OFF. This one step has to be done by hand (about 20 seconds):"
  warn "  https://console.firebase.google.com/project/$PROJECT/authentication/providers"
  warn "  -> Add new provider -> Google -> Enable -> pick your support email -> Save"
  GOOGLE_ON=0
fi

say "5/6  Creating the Firestore database (if needed)"
if gcloud firestore databases describe --database='(default)' --project "$PROJECT" >/dev/null 2>&1; then
  ok "Database already exists"
else
  gcloud firestore databases create --database='(default)' --location="$FIRESTORE_LOCATION" \
    --type=firestore-native --project "$PROJECT"
  ok "Database created in $FIRESTORE_LOCATION"
fi

say "6/6  Publishing security rules (each person can only read/write their own ballot)"
RULES='rules_version = '"'"'2'"'"';
service cloud.firestore {
  match /databases/{database}/documents {
    match /ballots/{uid} {
      allow read, write: if request.auth != null && request.auth.uid == uid;
    }
  }
}'
RULESET_BODY="$(python3 -c 'import sys,json; print(json.dumps({"source":{"files":[{"name":"firestore.rules","content":sys.stdin.read()}]}}))' <<<"$RULES")"
RULESET="$(api POST "https://firebaserules.googleapis.com/v1/projects/$PROJECT/rulesets" "$RULESET_BODY" | json 'd["name"]')"
RELEASE="projects/$PROJECT/releases/cloud.firestore"
if api GET "https://firebaserules.googleapis.com/v1/$RELEASE" | grep -q '"rulesetName"'; then
  api PATCH "https://firebaserules.googleapis.com/v1/$RELEASE" \
    "{\"release\":{\"name\":\"$RELEASE\",\"rulesetName\":\"$RULESET\"}}" >/dev/null
else
  api POST "https://firebaserules.googleapis.com/v1/projects/$PROJECT/releases" \
    "{\"name\":\"$RELEASE\",\"rulesetName\":\"$RULESET\"}" >/dev/null
fi
ok "Rules published"

say "Done. Copy everything between the lines below and paste it back to Claude:"
echo "------------------------------------------------------------"
echo "$CONFIG_JSON" | python3 -c '
import sys, json
c = json.load(sys.stdin)
keys = ["apiKey", "authDomain", "projectId", "storageBucket", "messagingSenderId", "appId"]
print("const firebaseConfig = {")
print(",\n".join(f"  {k}: \"{c[k]}\"" for k in keys if k in c))
print("};")'
echo "------------------------------------------------------------"
[ "$GOOGLE_ON" = "1" ] || warn "Reminder: turn on Google sign-in (step 4 link above) or sign-in won't work."
