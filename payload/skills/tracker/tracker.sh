#!/usr/bin/env bash
# Personal Project Tracker helper.
#   tracker.sh headers                              # print the sheet's column names
#   tracker.sh append '{"Project":"X","Status":"Y"}'  # append a row (keys = header names)
#   tracker.sh update '<link>' '<project name>' '{"Status":"Z"}'
#                                                   # change named cells of the row with that Link
#   tracker.sh new-token                            # write a fresh token into config.local.json
#
# The write token lives ONLY in config.local.json beside this script. That file is ignored by
# git and left out of claude-sync's mirror, so it never leaves the Mac that holds it
# (claude-config#675: the token was once committed to this public repository). Nothing here
# prints the token or puts it on a command line, where any process listing would show it, or
# in a request address, which Google's logs record.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$DIR/config.local.json"
EXAMPLE="$DIR/config.example.json"
SCRIPT_GS="$DIR/apps-script.gs"

# new-token: a fresh random token, written straight into config.local.json (created from the
# example when absent, keeping any url already there). Only the path is printed: the person
# copies the token from that file into the Apps Script, so it never passes through a terminal.
if [ "${1:-}" = "new-token" ]; then
  python3 - "$CONFIG" "$EXAMPLE" <<'PY'
import json, os, secrets, string, sys
config, example = sys.argv[1], sys.argv[2]
src = config if os.path.exists(config) else example
try:
    with open(src) as f:
        data = json.load(f)
    if not isinstance(data, dict):
        raise ValueError("not a JSON object")
except Exception as e:
    # Never overwrite a file that cannot be read: it may hold the only copy of the URL.
    sys.stderr.write("Refusing to write a token: %s could not be read (%s). Fix or remove it, then run new-token again.\n" % (src, type(e).__name__))
    sys.exit(1)
import tempfile
alphabet = string.ascii_letters + string.digits
data["token"] = "".join(secrets.choice(alphabet) for _ in range(40))
# The half written copy is named *.local.json, which the skill's .gitignore and claude-sync's
# mirror both leave out, so a run killed before the rename below can never leave the token in
# a file that syncs or commits. mkstemp creates it readable by its owner only.
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(config), prefix=".new-token.", suffix=".local.json")
with os.fdopen(fd, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.chmod(tmp, 0o600)
if os.environ.get("TRACKER_TEST_STOP_BEFORE_RENAME") == "1":
    os._exit(9)   # test seam: stands in for a run killed between the write and the rename
os.replace(tmp, config)
print("Wrote a new token to %s (not shown here). Copy it from that file into the TOKEN line of the Apps Script, then deploy a new version." % config)
PY
  exit $?
fi

if [ ! -f "$CONFIG" ]; then
  echo "Not configured: $CONFIG is missing. Run setup (see SKILL.md)." >&2
  exit 1
fi

# Read and judge the config in one place. A value still equal to a shipped placeholder is
# refused by name: the placeholders are READ from config.example.json and apps-script.gs, so a
# renamed placeholder cannot slip past a hand kept list. The token comes back on stdout of
# this one process, into a variable, never through argv.
CHECKED="$(python3 - "$CONFIG" "$EXAMPLE" "$SCRIPT_GS" <<'PY'
import json, re, sys
config, example, script_gs = sys.argv[1:4]
def fail(msg):
    sys.stderr.write(msg + "\n")
    sys.exit(1)
try:
    with open(config) as f:
        cfg = json.load(f)
    if not isinstance(cfg, dict):
        raise ValueError
except Exception:
    fail("%s could not be read as a JSON object. Fix it, or recreate it with setup (see SKILL.md)." % config)
placeholders = {"url": set(), "token": set()}
try:
    with open(example) as f:
        ex = json.load(f)
    placeholders["url"].add(ex["url"])
    placeholders["token"].add(ex["token"])
except Exception:
    fail("%s is missing or unreadable, so the placeholders in config.local.json cannot be checked. Refusing to send." % example)
try:
    gs = open(script_gs).read()
    m = re.search(r"^const TOKEN = '([^']*)';", gs, re.M)
    n = re.search(r"^const TOKEN_MIN_LENGTH = (\d+);", gs, re.M)
    if not m or not n:
        raise ValueError
    placeholders["token"].add(m.group(1))
    min_len = int(n.group(1))
except Exception:
    fail("%s is missing or has no TOKEN or TOKEN_MIN_LENGTH line, so the token cannot be checked. Refusing to send." % script_gs)
problems = []
for key in ("url", "token"):
    v = cfg.get(key)
    if v is None:
        problems.append("%s is missing" % key)
    elif not isinstance(v, str) or not v.strip():
        problems.append("%s is empty" % key)
    elif v in placeholders[key]:
        problems.append("%s is still the placeholder" % key)
    elif key == "token" and len(v) < min_len:
        # The web app refuses a token this short too (apps-script.gs TOKEN_MIN_LENGTH).
        problems.append("token is shorter than %d characters" % min_len)
if problems:
    fail("config.local.json is not set up: %s. %s" % ("; ".join(problems),
         "Run 'tracker.sh new-token' for a token and paste the web app's /exec URL into %s (see SKILL.md)." % config))
print(cfg["url"])
print(cfg["token"])
PY
)"
URL="${CHECKED%%$'\n'*}"
TOKEN="${CHECKED#*$'\n'}"

# Every request is a POST with the key in its JSON body, never the address (claude-config#675):
# Google logs addresses, and a token in one is recorded there. The field is "key", which the
# matching apps-script.gs reads; the first version of the script read "token", so this caller
# and that deployment refuse each other ("bad token") rather than half understanding.
# The body is built by python with the token from its environment, and reaches curl on stdin.
post(){   # $1 = the request body without its key, as a JSON object; $2 = "update" for an update
  local payload
  payload=$(TRACKER_TOKEN="$TOKEN" python3 -c "import json,os,sys;b=json.loads(sys.argv[1]);b['key']=os.environ['TRACKER_TOKEN'];print(json.dumps(b))" "$1")
  # NOTE: no -X POST. --data makes the first request a POST; Apps Script 302-redirects
  # to a googleusercontent URL that only serves GET, so curl must switch to GET on the
  # redirect. -X POST would force a re-POST there and return 405.
  local answer
  if ! answer="$(printf '%s' "$payload" | curl -fsSL "$URL" -H 'Content-Type: application/json' --data @-)"; then
    echo "tracker.sh: could not reach the web app (curl failed). Nothing was recorded." >&2
    exit 1
  fi
  # The web app answers HTTP 200 for its refusals too ({"ok":false,"error":"bad token"}), so
  # curl --fail cannot see them: the answer is read here, and anything but {"ok":true,...} is a
  # failure naming the web app's own error (claude-config#677).
  python3 -c '
import json, sys
body, expect = sys.argv[1], sys.argv[2]
try:
    reply = json.loads(body)
except ValueError:
    sys.stderr.write("tracker.sh: the answer was not the JSON the web app sends, so nothing is known to have happened. It began: %r\n" % body[:200])
    sys.exit(1)
if not isinstance(reply, dict) or reply.get("ok") is not True:
    why = reply.get("error") if isinstance(reply, dict) else None
    sys.stderr.write("tracker.sh: the web app refused: %s\n" % (why or body[:200]))
    if expect == "update" and "nothing to append" in str(why):
        # The deployed script has no update, and refused the body because it carries no data.
        sys.stderr.write("tracker.sh: the deployed web app predates update, so nothing was changed. Deploy the current apps-script.gs as a new version (SKILL.md, Turning on update).\n")
    sys.exit(1)
if expect == "update" and reply.get("action") != "update":
    sys.stderr.write("tracker.sh: the answer was ok but not an update'"'"'s, so what changed in the sheet is unknown; check the sheet. It began: %r\n" % body[:200])
    sys.exit(1)
print(body)
' "$answer" "${2:-}"
}

case "${1:-}" in
  headers)
    post '{"action":"headers"}'
    ;;
  append)
    DATA="${2:?usage: tracker.sh append '<json object of header:value>'}"
    BODY=$(python3 -c "import json,sys;print(json.dumps({'data':json.loads(sys.argv[1])}))" "$DATA")
    post "$BODY"
    ;;
  update)
    # Changes only the named cells of the one row whose Link is <link>, once the web app has
    # confirmed that row's Project Name is <project name>. Every other cell is left as it is.
    # The cells go as "cells", never "data": a deployed script older than update would read a
    # "data" object as a row to append, and refuses a body without one instead.
    USAGE="usage: tracker.sh update '<link>' '<project name>' '<json object of header:value>'"
    BODY="$(python3 - "$USAGE" "${2-}" "${3-}" "${4-}" "$#" <<'PY'
import json, sys
usage, link, name, cells, argc = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])
def refuse(why):
    sys.stderr.write("tracker.sh: %s. %s\n" % (why, usage))
    sys.exit(1)
if argc != 4:
    refuse("update takes exactly three arguments")
if not link.strip():
    refuse("the link is empty")
if not name.strip():
    refuse("the project name is empty")
try:
    parsed = json.loads(cells)
except ValueError:
    refuse("the cells are not JSON")
if not isinstance(parsed, dict) or not parsed:
    refuse("the cells must be a JSON object naming at least one column")
print(json.dumps({"action": "update", "link": link, "projectName": name, "cells": parsed}))
PY
)" || exit 1
    post "$BODY" update
    ;;
  *)
    echo "usage: tracker.sh {headers | append '<json>' | update '<link>' '<project name>' '<json>' | new-token}" >&2
    exit 1
    ;;
esac
