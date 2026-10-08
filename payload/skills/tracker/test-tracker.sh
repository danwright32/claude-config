#!/usr/bin/env bash
# Suite for tracker.sh: a refusal from the sheet is a failure, never a printed success (claude-config#677).
#
# The Apps Script answers HTTP 200 for everything, its refusals included ({"ok":false,"error":"bad
# token"}), so curl --fail passes them and tracker.sh used to print the refusal and exit 0. The
# skill then had to notice `ok` in the text. Now the script reads `ok` itself.
#
# No case reaches the network or the real sheet (L2): curl is a stand in on PATH that answers what
# each case needs and records that it was called, and the config is a fixture named through
# TRACKER_CONFIG, so the real config.local.json beside the script is never read.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRACKER="$DIR/tracker.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/tracker-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/    /'; return 0; }
has() { grep -qF -- "$2" <<< "$1"; }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'SH'
#!/bin/bash
echo "$*" >> "$FAKE_CURL_LOG"
printf '%s' "$FAKE_CURL_BODY"
exit "${FAKE_CURL_RC:-0}"
SH
chmod +x "$TMP/bin/curl"
printf '{"url":"https://script.example.invalid/exec","token":"t0k"}\n' > "$TMP/config.json"
export FAKE_CURL_LOG="$TMP/curl.log" TRACKER_CONFIG="$TMP/config.json"

go() { # go <body> <curl rc> <args...>
  local body="$1" crc="$2"; shift 2
  : > "$FAKE_CURL_LOG"
  out="$(FAKE_CURL_BODY="$body" FAKE_CURL_RC="$crc" PATH="$TMP/bin:$PATH" bash "$TRACKER" "$@" 2>"$TMP/err")"; rc=$?
  err="$(cat "$TMP/err")"
}

go '{"ok":true,"headers":["Project","Status"]}' 0 headers
[ "$rc" -eq 0 ] && has "$out" '"headers"' && ok || bad "a successful headers read exits 0 and prints the answer (rc=$rc)" "$out $err"
has "$(cat "$FAKE_CURL_LOG")" "script.example.invalid" && ok || bad "the stand in curl was the one called, with the fixture config's URL" "$(cat "$FAKE_CURL_LOG")"

go '{"ok":false,"error":"bad token"}' 0 headers
[ "$rc" -eq 1 ] && has "$err" "bad token" && ok || bad "a refused headers read exits 1 and names the refusal (rc=$rc)" "$out $err"

go '{"ok":true,"rowNumber":7,"row":["X","Y"]}' 0 append '{"Project":"X"}'
[ "$rc" -eq 0 ] && has "$out" '"rowNumber":7' && ok || bad "a successful append exits 0 and prints the row (rc=$rc)" "$out $err"

go '{"ok":false,"error":"bad json"}' 0 append '{"Project":"X"}'
[ "$rc" -eq 1 ] && has "$err" "bad json" && ok || bad "a refused append exits 1 and names the refusal (rc=$rc)" "$out $err"

go '<html><body>Sign in to continue</body></html>' 0 append '{"Project":"X"}'
[ "$rc" -eq 1 ] && has "$err" "not the JSON" && ok || bad "an answer that is not JSON (a sign in page) is a failure (rc=$rc)" "$out $err"

go '' 22 headers
[ "$rc" -ne 0 ] && has "$err" "could not reach" && ok || bad "a request curl could not complete is a failure that says so (rc=$rc)" "$out $err"

TRACKER_CONFIG="$TMP/none.json" go '{"ok":true}' 0 headers
[ "$rc" -eq 1 ] && has "$err" "none.json" && ok || bad "a missing config is refused by its path (rc=$rc)" "$out $err"
[ -s "$FAKE_CURL_LOG" ] && bad "and nothing is requested" || ok

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
