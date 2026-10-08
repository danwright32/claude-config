#!/usr/bin/env bash
# Tests for the tracker skill (claude-config#675).
#
# The skill's Apps Script write token was committed in plain text, in SKILL.md and in
# config.example.json, in a public repository. The token now lives only in
# config.local.json, which never leaves the Mac that holds it, and tracker.sh refuses by
# name when that file is missing or still holds a placeholder.
#
# Every run happens on a COPY of the skill in a throwaway directory, with a fake curl on
# PATH that records what it was asked and reaches nothing (L2). Every token here is
# invented by this file; no real one is read, printed or passed anywhere.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
case "${TMP%/}" in
  ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$TMP'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; }
check() { # check <description> <expected-substring> <actual>
  if [[ "$3" == *"$2"* ]]; then ok; else
    bad "$1"; echo "  expected to contain: $2"; echo "  actual: $3"
  fi
}
check_not() { # check_not <description> <forbidden-substring> <actual>
  if [[ "$3" != *"$2"* ]]; then ok; else bad "$1 (output should not contain '$2')"; fi
}
check_eq() { # check_eq <description> <expected> <actual>
  if [[ "$3" == "$2" ]]; then ok; else bad "$1 (expected '$2', got '$3')"; fi
}

# --- the shipped files hold no token ----------------------------------------
# A token is a long run of letters AND digits. Bounded by anything that is not part of an
# identifier, so the sheet id in SKILL.md (which carries a hyphen) is not one, and the
# placeholders (which carry underscores) are not either. Every file the skill ships is
# read, never a list of the ones that held it last time (L96). config.local.json is the
# one file that is meant to hold it, and it never ships.
shipped_secret_lines(){ # $1 = a skill directory; prints file:line for each token shaped run
  python3 - "$1" <<'PY'
import os, re, sys
root = sys.argv[1]
shape = re.compile(r"(?<![A-Za-z0-9_-])[A-Za-z0-9]{32,}(?![A-Za-z0-9_-])")
for name in sorted(os.listdir(root)):
    p = os.path.join(root, name)
    if name == "config.local.json" or not os.path.isfile(p):
        continue
    for i, line in enumerate(open(p, errors="ignore").read().splitlines(), 1):
        for m in shape.finditer(line):
            v = m.group(0)
            if re.search(r"[0-9]", v) and re.search(r"[A-Za-z]", v):
                print("%s:%d" % (name, i))
PY
}
found="$(shipped_secret_lines "$DIR")"
check_eq "no shipped file in the tracker skill holds a token shaped value (file:line listed, value never printed)" "" "$found"
# The control (L1): the scan finds a token where one is planted, so its silence above means something.
mkdir -p "$TMP/planted"
# Assembled from two halves so this file never holds a token shaped run of its own.
printf '{ "url": "x", "token": "%s%s" }\n' "Ab3dEf6hIj9kLm2n" "Op5qRs8tUv1wXy4zAb7cDe0f" > "$TMP/planted/config.example.json"
printf 'kept local\n' > "$TMP/planted/config.local.json"
check_eq "and the same scan finds a planted one, while ignoring config.local.json" "config.example.json:1" "$(shipped_secret_lines "$TMP/planted")"

# The example must still be a template the skill can fill: both keys present, both placeholders.
example_keys="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(",".join(sorted(d)))' "$DIR/config.example.json" 2>&1)"
check_eq "config.example.json carries url and token" "token,url" "$example_keys"

# --- SKILL.md's worked examples obey SKILL.md's own rules ---------------------
# An example that breaks a rule teaches the inverse with the rule's authority (L562). The rule:
# Skills Used never lists Claude Code. Every `tracker.sh append '<json>'` example is parsed.
example_verdict="$(python3 - "$DIR/SKILL.md" <<'PY'
import json, re, sys
found = 0
for m in re.finditer(r"tracker\.sh append '(\{.*?\})'", open(sys.argv[1]).read()):
    try:
        row = json.loads(m.group(1))
    except Exception:
        print("unparseable example"); continue
    found += 1
    if "claude code" in str(row.get("Skills Used", "")).lower():
        print("an example lists Claude Code under Skills Used")
print("examples=%d" % found)
PY
)"
check "SKILL.md carries a worked append example to judge" "examples=1" "$example_verdict"
check_not "and no worked example lists Claude Code under Skills Used, which the rule forbids" "Claude Code" "$example_verdict"
check_not "and every worked example is valid JSON" "unparseable" "$example_verdict"

# --- config.local.json never travels ------------------------------------------
# Git: the skill's own ignore file keeps it out of every commit.
gitignored(){ # gitignored <file name>; prints yes when a pattern in the skill's .gitignore matches it
  python3 -c 'import fnmatch,sys; ps=[l.strip() for l in open(sys.argv[1]) if l.strip() and not l.startswith("#")]; print("yes" if any(fnmatch.fnmatch(sys.argv[2], p) for p in ps) else "no")' "$DIR/.gitignore" "$1" 2>&1
}
check_eq "the skill's .gitignore leaves out config.local.json" "yes" "$(gitignored config.local.json)"
check_eq "and does not leave out the files the skill ships" "no no no" "$(gitignored tracker.sh) $(gitignored config.example.json) $(gitignored SKILL.md)"

# --- a sandbox copy of the skill, and a curl that reaches nothing -------------
SK="$TMP/skill"
mkdir -p "$SK" "$TMP/bin"
cp "$DIR/tracker.sh" "$DIR/config.example.json" "$DIR/apps-script.gs" "$SK/"
CURL_LOG="$TMP/curl.log"
cat > "$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
# Records its arguments and whatever arrived on stdin, then answers like the web app.
{ printf 'ARGS:'; printf ' %s' "$@"; printf '\n'; printf 'STDIN:'; cat; printf '\n'; } >> "$CURL_LOG"
printf '{"ok":true}'
STUB
chmod +x "$TMP/bin/curl"
export CURL_LOG

GOOD_URL="https://script.google.com/macros/s/FAKEDEPLOYMENT/exec"
GOOD_TOKEN="test_token_0123456789_abcdef_not_real"
write_local(){ # write_local <url> <token>
  python3 -c 'import json,sys; json.dump({"url":sys.argv[2],"token":sys.argv[3]}, open(sys.argv[1],"w"))' "$SK/config.local.json" "$1" "$2"
}
run(){ # run <args...>; sets OUT and RC
  : > "$CURL_LOG"
  OUT="$(PATH="$TMP/bin:$PATH" bash "$SK/tracker.sh" "$@" 2>&1)"
  RC=$?
}
curl_calls(){ grep -c '^ARGS:' "$CURL_LOG" 2>/dev/null || true; }
EX_URL="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["url"])' "$DIR/config.example.json")"
EX_TOKEN="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["token"])' "$DIR/config.example.json")"
GS_TOKEN="$(sed -n "s/^const TOKEN = '\\(.*\\)';.*/\\1/p" "$DIR/apps-script.gs")"
check "the Apps Script placeholder could be read from apps-script.gs" "REPLACE" "$GS_TOKEN"

# --- the positive control first (L159): a configured skill does reach curl ---
write_local "$GOOD_URL" "$GOOD_TOKEN"
run headers
check_eq "a configured skill's headers call succeeds" 0 "$RC"
check_eq "and reaches curl exactly once" 1 "$(curl_calls)"
check "and asks the configured web app" "FAKEDEPLOYMENT" "$(grep '^ARGS:' "$CURL_LOG")"
check "as a POST whose body asks for the headers" '"action": "headers"' "$(grep '^STDIN:' "$CURL_LOG")"
check "with the key in that body" "\"key\": \"$GOOD_TOKEN\"" "$(grep '^STDIN:' "$CURL_LOG")"
check "the body goes as POST data" "--data @-" "$(grep '^ARGS:' "$CURL_LOG")"
check_not "and never puts the token on curl's command line or in the address" "$GOOD_TOKEN" "$(grep '^ARGS:' "$CURL_LOG")"
check_not "and the address carries no query string at all" "?" "$(grep '^ARGS:' "$CURL_LOG")"
run append '{"Project Name":"x"}'
check_eq "a configured skill's append succeeds" 0 "$RC"
check_eq "and reaches curl exactly once" 1 "$(curl_calls)"
check "and sends the key in the request body" "\"key\": \"$GOOD_TOKEN\"" "$(grep '^STDIN:' "$CURL_LOG")"
check "and the row with it" '"data": {"Project Name": "x"}' "$(grep '^STDIN:' "$CURL_LOG")"
check_not "and never under the old field name the first script read" '"token"' "$(grep '^STDIN:' "$CURL_LOG")"
check_not "and never puts the token on curl's command line" "$GOOD_TOKEN" "$(grep '^ARGS:' "$CURL_LOG")"

# --- every refusal names its cause, and reaches nothing -----------------------
refuses(){ # refuses <description> <expected words in the message> <args...>
  local d="$1" want="$2"; shift 2
  run "$@"
  if [ "$RC" -ne 0 ]; then ok; else bad "$d: exits non zero (got $RC)"; fi
  check "$d: says why" "$want" "$OUT"
  check_eq "$d: reaches nothing" 0 "$(curl_calls)"
  check_not "$d: never prints the configured token" "$GOOD_TOKEN" "$OUT"
}

rm -f "$SK/config.local.json"
refuses "no config.local.json" "config.local.json is missing" headers
refuses "no config.local.json, on append" "config.local.json is missing" append '{"a":1}'

cp "$DIR/config.example.json" "$SK/config.local.json"
refuses "config.local.json copied straight from the example" "placeholder" headers
check "and it names the url" "url" "$OUT"

write_local "$EX_URL" "$GOOD_TOKEN"
refuses "the example's url placeholder" "url" headers
check "and calls it a placeholder" "placeholder" "$OUT"

write_local "$GOOD_URL" "$EX_TOKEN"
refuses "the example's token placeholder" "token" headers
check "and calls it a placeholder" "placeholder" "$OUT"

write_local "$GOOD_URL" "$GS_TOKEN"
refuses "the Apps Script's own placeholder token" "token" append '{"a":1}'
check "and calls it a placeholder" "placeholder" "$OUT"

write_local "$GOOD_URL" ""
refuses "an empty token" "token" headers
check "and calls it empty" "empty" "$OUT"

write_local "$GOOD_URL" "short_token_0123456789"
refuses "a token shorter than the web app accepts" "shorter than 32" headers

python3 -c 'import json,sys; json.dump({"url":sys.argv[2]}, open(sys.argv[1],"w"))' "$SK/config.local.json" "$GOOD_URL"
refuses "a config with no token key" "token" headers

printf '{ not json' > "$SK/config.local.json"
refuses "a config that is not JSON" "config.local.json" headers
check "and says it could not be read" "could not be read" "$OUT"

# The placeholders are read from the shipped files, so a missing one cannot be judged.
write_local "$GOOD_URL" "$GOOD_TOKEN"
mv "$SK/apps-script.gs" "$TMP/apps-script.gs.aside"
refuses "with apps-script.gs missing, placeholders cannot be checked" "apps-script.gs" headers
mv "$TMP/apps-script.gs.aside" "$SK/apps-script.gs"

# --- new-token writes a fresh token without ever showing it -------------------
rm -f "$SK/config.local.json"
run new-token
check_eq "new-token with no config.local.json succeeds" 0 "$RC"
check_eq "and reaches nothing" 0 "$(curl_calls)"
check "and says where the token went" "config.local.json" "$OUT"
NEWTOK="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["token"])' "$SK/config.local.json" 2>/dev/null)"
NEWURL="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["url"])' "$SK/config.local.json" 2>/dev/null)"
if [ "${#NEWTOK}" -ge 32 ]; then ok; else bad "new-token writes a token of at least 32 characters (got ${#NEWTOK})"; fi
if [ -n "$NEWTOK" ] && [ "$NEWTOK" != "$EX_TOKEN" ] && [ "$NEWTOK" != "$GS_TOKEN" ]; then ok; else bad "new-token writes a token that is not a placeholder"; fi
if [ -n "$NEWTOK" ] && [[ "$OUT" != *"$NEWTOK"* ]]; then ok; else bad "new-token never prints the token it wrote"; fi
check_eq "and the file is readable by its owner only" "600" "$(python3 -c 'import os,sys; print(format(os.stat(sys.argv[1]).st_mode & 0o777, "o"))' "$SK/config.local.json" 2>&1)"
check_eq "and the url is still the example's, waiting to be filled" "$EX_URL" "$NEWURL"
refuses "a fresh token with the url still a placeholder" "url" headers

write_local "$GOOD_URL" "$GOOD_TOKEN"
run new-token
NEWTOK2="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["token"])' "$SK/config.local.json" 2>/dev/null)"
NEWURL2="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["url"])' "$SK/config.local.json" 2>/dev/null)"
check_eq "new-token over an existing config succeeds" 0 "$RC"
if [ -n "$NEWTOK2" ] && [ "$NEWTOK2" != "$GOOD_TOKEN" ]; then ok; else bad "new-token replaces the old token"; fi
check_eq "and keeps the configured url" "$GOOD_URL" "$NEWURL2"
check_not "and never prints the old token" "$GOOD_TOKEN" "$OUT"
run headers
check_eq "and the skill works with the new token" 0 "$RC"

printf '{ not json' > "$SK/config.local.json"
run new-token
if [ "$RC" -ne 0 ]; then ok; else bad "new-token over an unreadable config refuses rather than overwriting it"; fi
check_eq "and leaves that file as it was" "{ not json" "$(cat "$SK/config.local.json")"

# --- a run killed mid write leaves the token only where nothing syncs ---------
# new-token writes a temporary copy and renames it over config.local.json. A run killed between
# the two leaves that copy behind, holding the new token, so its name must be one the skill's
# .gitignore and claude-sync's mirror (every *.local.json) both leave out.
write_local "$GOOD_URL" "$GOOD_TOKEN"
export TRACKER_TEST_STOP_BEFORE_RENAME=1
run new-token
unset TRACKER_TEST_STOP_BEFORE_RENAME
if [ "$RC" -ne 0 ]; then ok; else bad "the stopped new-token run reports failure (got $RC)"; fi
check "a run stopped before the rename leaves config.local.json as it was" "$GOOD_TOKEN" "$(cat "$SK/config.local.json")"
leftovers="$(python3 - "$SK" "$DIR/.gitignore" <<'PY'
import fnmatch, os, stat, sys
sk, gitignore = sys.argv[1], sys.argv[2]
shipped = {"tracker.sh", "config.example.json", "apps-script.gs", "config.local.json"}
patterns = [l.strip() for l in open(gitignore) if l.strip() and not l.startswith("#")]
for name in sorted(os.listdir(sk)):
    if name in shipped:
        continue
    mode = format(os.stat(os.path.join(sk, name)).st_mode & 0o777, "o")
    ignored = any(fnmatch.fnmatch(name, p) for p in patterns)
    print("%s synced=%s ignored=%s mode=%s" % ("leftover", "no" if name.endswith(".local.json") else "YES", "yes" if ignored else "NO", mode))
PY
)"
check "the stopped run did leave its temporary copy behind (the case under test happened)" "leftover" "$leftovers"
check_not "and that copy's name is one claude-sync leaves out (*.local.json)" "synced=YES" "$leftovers"
check_not "and one the skill's .gitignore leaves out" "ignored=NO" "$leftovers"
check_not "and it is readable by its owner only" "mode=6" "$(grep -v 'mode=600' <<< "$leftovers")"

# --- the web app itself (apps-script.gs), run under node with fake Google services ---
# The script's own logic, not a reading of its text (L638): each case evaluates the shipped file,
# with its TOKEN line set the way Dan sets it, against stubs that record every append.
if ! command -v node >/dev/null 2>&1; then
  bad "node is not on PATH, so apps-script.gs could not be run. Install node; this is UNMEASURED, not passed."
else
  cat > "$TMP/gs-harness.js" <<'JS'
const fs = require('fs'), vm = require('vm');
const [src, token, requestJson, method] = process.argv.slice(2);
let code = fs.readFileSync(src, 'utf8');
if (token !== '-') {
  const before = code;
  code = code.replace(/^const TOKEN = '[^']*';/m, "const TOKEN = '" + token + "';");
  if (code === before) { console.log(JSON.stringify({ harness: 'no TOKEN line to set' })); process.exit(0); }
}
const appended = [];
const sheet = {
  getLastColumn: () => 2,
  getRange: () => ({ getValues: () => [['Project Name', 'Date Started']] }),
  appendRow: (r) => appended.push(r),
  getLastRow: () => 1 + appended.length,
};
const ctx = {
  SpreadsheetApp: { getActiveSpreadsheet: () => ({ getSheets: () => [sheet], getSheetByName: () => sheet }) },
  ContentService: { MimeType: { JSON: 'json' }, createTextOutput: (s) => ({ setMimeType: () => s }) },
  Utilities: { formatDate: () => '2026-01-01' },
  Session: { getScriptTimeZone: () => 'UTC' },
  JSON,
};
vm.createContext(ctx);
vm.runInContext(code, ctx);
const out = method === 'GET'
  ? ctx.doGet({ parameter: JSON.parse(requestJson) })
  : ctx.doPost({ postData: { contents: requestJson } });
console.log(JSON.stringify({ response: JSON.parse(out), appended: appended.length }));
JS
  GS="$DIR/apps-script.gs"
  # Built from parts so this file never holds a token shaped run of its own.
  REAL="abcdefghijklmnop""0123456789ABCDEFGHIJKLMN"
  gs(){ node "$TMP/gs-harness.js" "$GS" "$1" "$2" "${3:-POST}" 2>&1; }

  r="$(gs "$REAL" "{\"key\":\"$REAL\",\"action\":\"headers\"}")"
  check "web app, real token: the right key asks for the headers" '"ok":true,"headers":["Project Name","Date Started"]' "$r"
  check "and appends nothing" '"appended":0' "$r"
  r="$(gs "$REAL" "{\"key\":\"$REAL\",\"data\":{\"Project Name\":\"x\"}}")"
  check "web app, real token: the right key appends a row" '"ok":true' "$r"
  check "exactly one" '"appended":1' "$r"
  for case in "wrong key|{\"key\":\"nope\",\"data\":{\"a\":1}}" \
              "no key|{\"data\":{\"a\":1}}" \
              "the right value under the first version's field name|{\"token\":\"$REAL\",\"data\":{\"a\":1}}" \
              "the placeholder as the key|{\"key\":\"$GS_TOKEN\",\"data\":{\"a\":1}}"; do
    r="$(gs "$REAL" "${case#*|}")"
    check "web app, real token, ${case%%|*}: refused as a bad token" '"error":"bad token"' "$r"
    check "web app, real token, ${case%%|*}: appends nothing" '"appended":0' "$r"
  done
  r="$(gs "$REAL" "{\"key\":\"$REAL\"}")"
  check "web app: the right key with neither action nor data is refused" '"ok":false' "$r"
  check "and appends nothing, never an empty dated row" '"appended":0' "$r"
  r="$(gs "$REAL" "{\"token\":\"$REAL\"}" GET)"
  check "web app: a GET is refused even with the right token in its address" '"ok":false' "$r"
  check_not "and reveals no headers" "Project Name" "$r"

  # Fails closed: the shipped placeholder, or a token too short to be real, refuses everything,
  # including a caller that sends that very placeholder as its key.
  for tok in "-|the shipped placeholder" "short0123|a short token"; do
    t="${tok%%|*}"; key="$t"; [ "$t" = "-" ] && key="$GS_TOKEN"
    r="$(gs "$t" "{\"key\":\"$key\",\"action\":\"headers\"}")"
    check "web app with ${tok#*|} as TOKEN: refuses even the matching key" '"error":"token not set' "$r"
    check_not "and reveals no headers" "Project Name" "$r"
    r="$(gs "$t" "{\"key\":\"$key\",\"data\":{\"a\":1}}")"
    check "web app with ${tok#*|} as TOKEN: refuses an append" '"ok":false' "$r"
    check "and appends nothing" '"appended":0' "$r"
  done
fi

echo
echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
