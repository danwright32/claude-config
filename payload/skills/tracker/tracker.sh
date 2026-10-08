#!/usr/bin/env bash
# Personal Project Tracker helper.
#   tracker.sh headers                              # print the sheet's column names
#   tracker.sh append '{"Project":"X","Status":"Y"}'  # append a row (keys = header names)
#   tracker.sh new-token                            # write a fresh token into config.local.json
#
# The write token lives ONLY in config.local.json beside this script. That file is ignored by
# git and left out of claude-sync's mirror, so it never leaves the Mac that holds it
# (claude-config#675: the token was once committed to this public repository). Nothing here
# prints the token or puts it on a command line, where any process listing would show it.
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
alphabet = string.ascii_letters + string.digits
data["token"] = "".join(secrets.choice(alphabet) for _ in range(40))
tmp = config + ".writing"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.chmod(tmp, 0o600)
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
    m = re.search(r"^const TOKEN = '([^']*)';", open(script_gs).read(), re.M)
    if not m:
        raise ValueError
    placeholders["token"].add(m.group(1))
except Exception:
    fail("%s is missing or has no TOKEN line, so the token placeholder cannot be checked. Refusing to send." % script_gs)
problems = []
for key in ("url", "token"):
    v = cfg.get(key)
    if v is None:
        problems.append("%s is missing" % key)
    elif not isinstance(v, str) or not v.strip():
        problems.append("%s is empty" % key)
    elif v in placeholders[key]:
        problems.append("%s is still the placeholder" % key)
if problems:
    fail("config.local.json is not set up: %s. %s" % ("; ".join(problems),
         "Run 'tracker.sh new-token' for a token and paste the web app's /exec URL into %s (see SKILL.md)." % config))
print(cfg["url"])
print(cfg["token"])
PY
)"
URL="${CHECKED%%$'\n'*}"
TOKEN="${CHECKED#*$'\n'}"

case "${1:-}" in
  headers)
    # The token travels in curl's config on stdin, not its arguments. It is still in the
    # address, because the web app's GET reads it from the query string.
    printf 'url = "%s?token=%s"\n' "$URL" "$TOKEN" | curl -fsSL -K -
    echo
    ;;
  append)
    DATA="${2:?usage: tracker.sh append '<json object of header:value>'}"
    # wrap the caller's data object with the auth token via python (safe JSON assembly); the
    # token reaches python through its environment and curl through stdin.
    PAYLOAD=$(TRACKER_TOKEN="$TOKEN" python3 -c "import json,os,sys;print(json.dumps({'token':os.environ['TRACKER_TOKEN'],'data':json.loads(sys.argv[1])}))" "$DATA")
    # NOTE: no -X POST. --data makes the first request a POST; Apps Script 302-redirects
    # to a googleusercontent URL that only serves GET, so curl must switch to GET on the
    # redirect. -X POST would force a re-POST there and return 405.
    printf '%s' "$PAYLOAD" | curl -fsSL "$URL" -H 'Content-Type: application/json' --data @-
    echo
    ;;
  *)
    echo "usage: tracker.sh {headers | append '<json>' | new-token}" >&2
    exit 1
    ;;
esac
