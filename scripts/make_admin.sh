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

say "1/2  Publishing database rules (ballots, leaderboard, leagues, admin-only results)"
RULES="$(cat <<'EOF_RULES'
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {

    function signedIn() { return request.auth != null; }

    // Admins are listed in /admins/{uid}; only the project owner can add them (via scripts/make_admin.sh).
    function isAdmin() {
      return signedIn() && exists(/databases/$(database)/documents/admins/$(request.auth.uid));
    }

    // Ballots lock when the admin locks them, or automatically at results/current.autoLockAt
    // (milliseconds; default Thanksgiving 2026, noon Eastern; null turns the automatic lock off).
    function locked() {
      return exists(/databases/$(database)/documents/results/current)
        ? lockedBy(get(/databases/$(database)/documents/results/current).data)
        : request.time.toMillis() >= 1795712400000;
    }
    function lockedBy(r) {
      return r.get('locked', false) == true
        || (r.get('autoLockAt', 1795712400000) != null && request.time.toMillis() >= r.get('autoLockAt', 1795712400000));
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

    // ---------------- Leagues ----------------
    // A league is a named group of ballots with its own leaderboard view. Picks/results are shared.
    function leagueData(id) { return get(/databases/$(database)/documents/leagues/$(id)).data; }
    function isLeagueOwner(id) { return signedIn() && leagueData(id).ownerUid == request.auth.uid; }
    function isMember(id) { return signedIn() && exists(/databases/$(database)/documents/leagues/$(id)/members/$(request.auth.uid)); }

    match /leagues/{leagueId} {
      allow read: if signedIn();
      allow create: if signedIn()
        && request.resource.data.ownerUid == request.auth.uid
        && request.resource.data.name is string && request.resource.data.name.size() > 0 && request.resource.data.name.size() <= 40
        && request.resource.data.isPrivate is bool;
      allow update: if (isLeagueOwner(leagueId) || isAdmin())
        && request.resource.data.ownerUid == resource.data.ownerUid
        && request.resource.data.name is string && request.resource.data.name.size() > 0 && request.resource.data.name.size() <= 40;
      allow delete: if isLeagueOwner(leagueId) || isAdmin();

      // The password lives here; only the league owner (and admin) can read or change it.
      match /private/{docId} {
        allow read, write: if isLeagueOwner(leagueId) || isAdmin();
      }

      // Joining: a password league requires the right password, checked here by the database.
      match /members/{uid} {
        allow read: if signedIn() && (uid == request.auth.uid || isLeagueOwner(leagueId) || isAdmin());
        allow create: if signedIn() && uid == request.auth.uid
          && (leagueData(leagueId).isPrivate == false
              || request.resource.data.password == get(/databases/$(database)/documents/leagues/$(leagueId)/private/secret).data.password);
        allow delete: if signedIn() && (uid == request.auth.uid || isLeagueOwner(leagueId) || isAdmin());
      }

      // Which ballots are entered in the league. Members enter their own ballots (until ballots lock).
      match /entries/{ballotId} {
        allow read: if signedIn() && (leagueData(leagueId).isPrivate == false || isMember(leagueId) || isLeagueOwner(leagueId) || isAdmin());
        allow create: if isMember(leagueId) && !locked()
          && request.resource.data.ownerUid == request.auth.uid
          && get(/databases/$(database)/documents/ballots/$(ballotId)).data.ownerUid == request.auth.uid;
        allow delete: if signedIn() && (resource.data.ownerUid == request.auth.uid || isLeagueOwner(leagueId) || isAdmin());
      }
    }

    // Each person's list of leagues they've joined (only they can see or change it).
    match /users/{uid} {
      allow read, write: if signedIn() && uid == request.auth.uid;
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
REL_RESP="$(api PATCH "https://firebaserules.googleapis.com/v1/$RELEASE" "{\"release\":{\"name\":\"$RELEASE\",\"rulesetName\":\"$RULESET\"}}")"
if ! echo "$REL_RESP" | grep -q "\"rulesetName\": *\"$RULESET\""; then
  bad "Google didn't accept the new rules. Copy everything below and send it to Claude:"; echo "$REL_RESP"; exit 1
fi
LIVE="$(api GET "https://firebaserules.googleapis.com/v1/$RELEASE" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("rulesetName",""))')"
LIVE_SRC="$(api GET "https://firebaserules.googleapis.com/v1/$LIVE")"
if echo "$LIVE_SRC" | grep -q "match /leagues/" && echo "$LIVE_SRC" | grep -q "autoLockAt"; then
  ok "Rules published (leagues and automatic lock are on)"
else
  bad "The live rules aren't the newest ones. Copy everything above and send it to Claude."; exit 1
fi

say "2/2  Making $EMAIL an admin"
LOOKUP="$(api POST "https://identitytoolkit.googleapis.com/v1/projects/$PROJECT/accounts:lookup" "{\"email\":[\"$EMAIL\"]}")"
UID_="$(echo "$LOOKUP" | python3 -c 'import sys,json; u=json.load(sys.stdin).get("users",[]); print(u[0]["localId"] if u else "")')"
if [ -z "$UID_" ]; then
  bad "No account found for $EMAIL. Open the website, click 'Sign in with Google' with that account, then run this again."
  exit 1
fi
api PATCH "https://firestore.googleapis.com/v1/projects/$PROJECT/databases/(default)/documents/admins/$UID_" '{"fields":{"role":{"stringValue":"admin"}}}' >/dev/null
ok "Admin access granted. Reload the website; an 'Admin' button appears in the header."
