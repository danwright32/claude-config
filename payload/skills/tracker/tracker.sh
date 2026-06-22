#!/usr/bin/env bash
# Personal Project Tracker helper.
#   tracker.sh headers                              # print the sheet's column names
#   tracker.sh append '{"Project":"X","Status":"Y"}'  # append a row (keys = header names)
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$DIR/config.local.json"

if [ ! -f "$CONFIG" ]; then
  echo "Not configured: $CONFIG is missing. Run setup (see SKILL.md)." >&2
  exit 1
fi

URL=$(python3 -c "import json;print(json.load(open('$CONFIG'))['url'])")
TOKEN=$(python3 -c "import json;print(json.load(open('$CONFIG'))['token'])")

if [ -z "$URL" ] || [[ "$URL" == *REPLACE_ME* ]]; then
  echo "config.local.json has no deployment URL yet. Finish setup (see SKILL.md)." >&2
  exit 1
fi

case "${1:-}" in
  headers)
    curl -fsSL "$URL?token=$TOKEN"
    echo
    ;;
  append)
    DATA="${2:?usage: tracker.sh append '<json object of header:value>'}"
    # wrap the caller's data object with the auth token via python (safe JSON assembly)
    PAYLOAD=$(python3 -c "import json,sys;print(json.dumps({'token':sys.argv[1],'data':json.loads(sys.argv[2])}))" "$TOKEN" "$DATA")
    # NOTE: no -X POST. --data makes the first request a POST; Apps Script 302-redirects
    # to a googleusercontent URL that only serves GET, so curl must switch to GET on the
    # redirect. -X POST would force a re-POST there and return 405.
    curl -fsSL "$URL" -H 'Content-Type: application/json' --data "$PAYLOAD"
    echo
    ;;
  *)
    echo "usage: tracker.sh {headers | append '<json>'}" >&2
    exit 1
    ;;
esac
