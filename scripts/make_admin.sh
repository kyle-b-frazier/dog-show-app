#!/usr/bin/env bash
# Make yourself the admin of the Dog Show Ballot and publish the database rules.
# Run in Google Cloud Shell AFTER you've signed in to the website once with Google:
#   bash make_admin.sh you@gmail.com
# Your email is only used here to look up your account; it isn't stored anywhere else.
set -euo pipefail
PROJECT="dogshowapp-e9b1b"
EMAIL="${1:-}"
[ -n "$EMAIL" ] || { echo "Usage: bash make_admin.sh you@gmail.com"; exit 1; }

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; }
gcloud config set project "$PROJECT" >/dev/null 2>&1
TOKEN="$(gcloud auth print-access-token)"
api() { curl -sS -X "$1" -H "Authorization: Bearer $TOKEN" -H "x-goog-user-project: $PROJECT" -H "Content-Type: application/json" "$2" ${3:+-d "$3"}; }

say "1/2  Publishing database rules (multiple ballots, leaderboard, admin-only results)"
RULES="$(cat <<'EOF_RULES'
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {

    function signedIn() { return request.auth != null; }

    // Admins are listed in /admins/{uid}; only the project owner can add them (via scripts/make_admin.sh).
    function isAdmin() {
      return signedIn() && exists(/databases/$(database)/documents/admins/$(request.auth.uid));
    }

    // The admin locks ballots on show day; after that, nobody can change picks.
    function locked() {
      return exists(/databases/$(database)/documents/results/current)
        && get(/databases/$(database)/documents/results/current).data.get('locked', false) == true;
    }

    function validBallot() {
      let d = request.resource.data;
      return d.ownerUid == request.auth.uid && d.name is string && d.name.size() > 0 && d.name.size() <= 40;
    }

    // Ballots: anyone signed in can see them (leaderboard); only the owner can change their own, until locked.
    match /ballots/{ballotId} {
      allow read: if signedIn();
      allow create: if signedIn() && validBallot() && !locked();
      allow update: if signedIn() && resource.data.ownerUid == request.auth.uid && validBallot() && !locked();
      allow delete: if signedIn() && resource.data.ownerUid == request.auth.uid && !locked();
      allow update, delete: if isAdmin();
    }

    // Results: public to read, only admins can write.
    match /results/{docId} {
      allow read: if true;
      allow write: if isAdmin();
    }

    // Admin list: you can check whether you're an admin; nobody can write it from the website.
    match /admins/{uid} {
      allow read: if signedIn() && request.auth.uid == uid;
      allow write: if false;
    }
  }
}
EOF_RULES
)"
BODY="$(python3 -c 'import sys,json; print(json.dumps({"source":{"files":[{"name":"firestore.rules","content":sys.stdin.read()}]}}))' <<<"$RULES")"
RS_RESP="$(api POST "https://firebaserules.googleapis.com/v1/projects/$PROJECT/rulesets" "$BODY")"
RULESET="$(echo "$RS_RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("name",""))')"
[ -n "$RULESET" ] || { bad "Rules were rejected:"; echo "$RS_RESP"; exit 1; }
RELEASE="projects/$PROJECT/releases/cloud.firestore"
api PATCH "https://firebaserules.googleapis.com/v1/$RELEASE" "{\"release\":{\"name\":\"$RELEASE\",\"rulesetName\":\"$RULESET\"}}" >/dev/null
ok "Rules published"

say "2/2  Making $EMAIL an admin"
LOOKUP="$(api POST "https://identitytoolkit.googleapis.com/v1/projects/$PROJECT/accounts:lookup" "{\"email\":[\"$EMAIL\"]}")"
UID_="$(echo "$LOOKUP" | python3 -c 'import sys,json; u=json.load(sys.stdin).get("users",[]); print(u[0]["localId"] if u else "")')"
if [ -z "$UID_" ]; then
  bad "No account found for $EMAIL. Open the website, click 'Sign in with Google' with that account, then run this again."
  exit 1
fi
api PATCH "https://firestore.googleapis.com/v1/projects/$PROJECT/databases/(default)/documents/admins/$UID_" '{"fields":{"role":{"stringValue":"admin"}}}' >/dev/null
ok "Admin access granted. Reload the website; an 'Admin' button appears in the header."
