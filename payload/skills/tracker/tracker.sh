#!/usr/bin/env bash
# Personal Project Tracker helper.
#   tracker.sh headers                              # print the sheet's column names
#   tracker.sh append '{"Project":"X","Status":"Y"}'  # append a row (keys = header names)
#   tracker.sh update '<link>' '<project name>' '{"Status":"Z"}'
#                                                   # change named cells of the row with that Link
#   tracker.sh new-token                            # write a fresh token into config.local.json
#   tracker.sh sheet-id                             # the id of the sheet SKILL.md names
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
LIB="$DIR/tracker_lib.py"

# The commands that never reach the web app run in tracker_lib.py, which needs no web app link or
# token: new-token writes the token into config.local.json without ever showing it, and sheet-id
# prints the id of the sheet SKILL.md names.
case "${1:-}" in
  new-token|sheet-id) exec python3 "$LIB" "$@" ;;
esac

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
# The sheet the web app must answer for: the one SKILL.md links to, its single declared home
# (claude-config#1080). Read before anything is sent, so a SKILL.md naming no sheet or two sends
# nothing.
SHEET_ID="$(python3 "$LIB" sheet-id)" || exit 1

# Every request is a POST with the key in its JSON body, never the address (claude-config#675):
# Google logs addresses, and a token in one is recorded there. The field is "key", which the
# matching apps-script.gs reads; the first version of the script read "token", so this caller
# and that deployment refuse each other ("bad token") rather than half understanding.
# The body is built by python with the token from its environment, and reaches curl on stdin.
# Every body also names the sheet SKILL.md links to, as "sheetId": a script attached to any other
# sheet refuses it before reading or writing anything (claude-config#1080).
post(){   # $1 = the request body without its key, as a JSON object; $2 = "sheet" for the sheet check, "update" or "preview" for those
  local payload
  payload=$(TRACKER_TOKEN="$TOKEN" TRACKER_SHEET_ID="$SHEET_ID" python3 -c "import json,os,sys;b=json.loads(sys.argv[1]);b['key']=os.environ['TRACKER_TOKEN'];b['sheetId']=os.environ['TRACKER_SHEET_ID'];print(json.dumps(b))" "$1")
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
body, expect, want = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    reply = json.loads(body)
except ValueError:
    sys.stderr.write("tracker.sh: the answer was not the JSON the web app sends, so nothing is known to have happened. It began: %r\n" % body[:200])
    sys.exit(1)
def other_sheet(got):
    sys.stderr.write("tracker.sh: the web app link in config.local.json belongs to an Apps Script attached to a different sheet (id %s), not the sheet SKILL.md names (id %s). Nothing was written. Open the sheet by the link in SKILL.md, then Extensions, Apps Script, Deploy, Manage deployments, and copy that deployment'"'"'s Web app URL into config.local.json (SKILL.md, Turning on the sheet check).\n" % (got, want))
    sys.exit(1)
got = reply.get("spreadsheetId") if isinstance(reply, dict) else None
if got is not None and got != want:
    if reply.get("ok") is not True:
        sys.stderr.write("tracker.sh: the web app refused: %s\n" % reply.get("error"))
    other_sheet(got)
if not isinstance(reply, dict) or reply.get("ok") is not True:
    why = reply.get("error") if isinstance(reply, dict) else None
    sys.stderr.write("tracker.sh: the web app refused: %s\n" % (why or body[:200]))
    if expect in ("update", "preview") and "nothing to append" in str(why):
        # The deployed script has no update, and refused the body because it carries no data.
        sys.stderr.write("tracker.sh: the deployed web app predates update, so nothing was changed. Deploy the current apps-script.gs as a new version (SKILL.md, Turning on update).\n")
    sys.exit(1)
if expect == "sheet" and got is None:
    # A script older than the sheet check answers without the id, and an old script is what the
    # wrong sheet held on 2026-10-12, so silence is refused, never taken as the right sheet.
    sys.stderr.write("tracker.sh: the web app did not say which sheet it is attached to, so it is a script older than the sheet check, and may be attached to another sheet. Nothing was written. Deploy the current apps-script.gs in the sheet SKILL.md links to as a new version, and check config.local.json holds that deployment'"'"'s Web app URL (SKILL.md, Turning on the sheet check).\n")
    sys.exit(1)
if expect in ("update", "preview") and reply.get("action") != "update":
    sys.stderr.write("tracker.sh: the answer was ok but not an update'"'"'s, so what changed in the sheet is unknown; check the sheet. It began: %r\n" % body[:200])
    sys.exit(1)
if expect == "preview" and reply.get("preview") is not True:
    sys.stderr.write("tracker.sh: asked for a preview but the answer is not a preview, so the sheet may have been written; check row %s. It began: %r\n" % (reply.get("rowNumber"), body[:200]))
    sys.exit(1)
if expect == "update" and reply.get("preview") is True:
    sys.stderr.write("tracker.sh: asked to update but the answer is only a preview, so nothing was written.\n")
    sys.exit(1)
print(body)
' "$answer" "${2:-}" "$SHEET_ID"
}

# The sheet check every command starts with: a headers request whose answer must name the sheet
# SKILL.md links to. A write goes only after it passes, so a script that cannot say which sheet it
# writes is refused before it could append a row there.
sheet_check(){ post '{"action":"headers"}' sheet > /dev/null; }

case "${1:-}" in
  headers)
    # The headers request IS the sheet check.
    post '{"action":"headers"}' sheet
    ;;
  append)
    DATA="${2:?usage: tracker.sh append '<json object of header:value>'}"
    BODY=$(python3 -c "import json,sys;print(json.dumps({'data':json.loads(sys.argv[1])}))" "$DATA")
    sheet_check
    post "$BODY"
    ;;
  update)
    # Changes only the named cells of the one row whose Link is <link>, once the web app has
    # confirmed that row's Project Name is <project name>. Every other cell is left as it is.
    # The cells go as "cells", never "data": a deployed script older than update would read a
    # "data" object as a row to append, and refuses a body without one instead.
    # --preview finds and checks the row the same way, writes nothing, and prints what each named
    # cell holds now, so the old and new values can be shown for approval before the real update.
    # An optional fourth argument is what the preview read (its "before"): the update then writes
    # only while every one of those cells still holds it.
    # --restore is the undo: it writes the cells raw (a formula live, a date as a date), so it takes
    # the answer's "restore" values as the cells and requires the fourth argument, what the cells
    # hold now. Without it every text value is written as literal text.
    USAGE="usage: tracker.sh update [--preview | --restore] '<link>' '<project name>' '<json object of header:value>' ['<json of what the cells hold now>']"
    shift
    MODE=update
    RESTORE=no
    if [ "${1-}" = "--preview" ]; then MODE=preview; shift
    elif [ "${1-}" = "--restore" ]; then RESTORE=yes; shift; fi
    BODY="$(python3 - "$USAGE" "${1-}" "${2-}" "${3-}" "$#" "$MODE" "${4-}" "$RESTORE" <<'PY'
import json, sys
usage, link, name, cells, argc = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])
preview, expect, restore = sys.argv[6] == "preview", sys.argv[7], sys.argv[8] == "yes"
def refuse(why):
    sys.stderr.write("tracker.sh: %s. %s\n" % (why, usage))
    sys.exit(1)
if argc not in (3, 4):
    refuse("update takes three arguments, or four with what the preview read")
if restore and argc != 4:
    refuse("restore needs a fourth argument, what the cells hold now, so it can only undo those values")
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
body = {"action": "update", "link": link, "projectName": name, "cells": parsed}
if argc == 4:
    try:
        expected = json.loads(expect)
    except ValueError:
        refuse("what the preview read is not JSON")
    if not isinstance(expected, dict):
        refuse("what the preview read must be a JSON object, the preview's before")
    body["expect"] = expected
if preview:
    body["preview"] = True
if restore:
    body["restore"] = True
print(json.dumps(body))
PY
)" || exit 1
    sheet_check
    post "$BODY" "$MODE"
    ;;
  *)
    echo "usage: tracker.sh {headers | append '<json>' | update '<link>' '<project name>' '<json>' | new-token | sheet-id}" >&2
    exit 1
    ;;
esac
