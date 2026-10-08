#!/usr/bin/env bash
# Personal Project Tracker helper.
#   tracker.sh headers                              # print the sheet's column names
#   tracker.sh append '{"Project":"X","Status":"Y"}'  # append a row (keys = header names)
#
# Exit 0 only when the sheet answered {"ok":true,...}. The Apps Script answers HTTP 200 for its
# refusals too ({"ok":false,"error":"bad token"}), so curl --fail cannot see them: the answer is
# read here, and a refusal exits 1 naming the sheet's own error (claude-config#677).
#
#   TRACKER_CONFIG   the config file to read (default: config.local.json beside this script)
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${TRACKER_CONFIG:-$DIR/config.local.json}"

if [ ! -f "$CONFIG" ]; then
  echo "Not configured: $CONFIG is missing. Run setup (see SKILL.md)." >&2
  exit 1
fi

URL=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['url'])" "$CONFIG")
TOKEN=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['token'])" "$CONFIG")

if [ -z "$URL" ] || [[ "$URL" == *REPLACE_ME* ]]; then
  echo "config.local.json has no deployment URL yet. Finish setup (see SKILL.md)." >&2
  exit 1
fi

# Prints the sheet's answer, or exits 1 naming why it is not an {"ok":true} object.
answered(){   # $1 = what was asked, $2 = the body
  python3 -c '
import json, sys
asked, body = sys.argv[1], sys.argv[2]
try:
    reply = json.loads(body)
except ValueError:
    print(f"tracker.sh: the {asked} answer was not the JSON the sheet sends, so nothing is known to "
          f"have happened. It began: {body[:200]!r}", file=sys.stderr)
    sys.exit(1)
if not isinstance(reply, dict) or reply.get("ok") is not True:
    why = reply.get("error") if isinstance(reply, dict) else None
    print(f"tracker.sh: the sheet refused the {asked}: {why or body[:200]}", file=sys.stderr)
    sys.exit(1)
print(body)
' "$1" "$2"
}

request(){   # $1 = what is being asked, the rest = curl's arguments
  local asked="$1" body
  shift
  if ! body="$(curl -fsSL "$@")"; then
    echo "tracker.sh: could not reach the sheet for the $asked (curl failed). Nothing was recorded." >&2
    exit 1
  fi
  answered "$asked" "$body"
}

case "${1:-}" in
  headers)
    request "headers read" "$URL?token=$TOKEN"
    ;;
  append)
    DATA="${2:?usage: tracker.sh append '<json object of header:value>'}"
    # wrap the caller's data object with the auth token via python (safe JSON assembly)
    PAYLOAD=$(python3 -c "import json,sys;print(json.dumps({'token':sys.argv[1],'data':json.loads(sys.argv[2])}))" "$TOKEN" "$DATA")
    # NOTE: no -X POST. --data makes the first request a POST; Apps Script 302-redirects
    # to a googleusercontent URL that only serves GET, so curl must switch to GET on the
    # redirect. -X POST would force a re-POST there and return 405.
    request "append" "$URL" -H 'Content-Type: application/json' --data "$PAYLOAD"
    ;;
  *)
    echo "usage: tracker.sh {headers | append '<json>'}" >&2
    exit 1
    ;;
esac
