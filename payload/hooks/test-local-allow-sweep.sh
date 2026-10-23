#!/usr/bin/env bash
# Tests for local-allow-sweep.sh (SessionStart) and lib/local-allow-rules.py remove (claude-config#1582).
#
# Answering a permission prompt with "Yes, don't ask again" saves that exact command as an allow rule
# in the project's .claude/settings.local.json, which is out of git and read by nothing we own. One off
# rules pile up and warn at every session start, and in Bidspoke one held a live token in plain text.
# The sweep flags them and says so once; the remove command takes out only what Dan picked.
#
# Every settings file here is invented. Each fake key or token is written whole, in a shape the push
# scan accepts by its own rules (see the FAKE_ values below), and the test asserts none of them ever
# reaches any output, record or log.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/local-allow-sweep.sh"
LIB="$DIR/lib/local-allow-rules.py"
. "$DIR/lib/settings-file.sh"
SETTINGS="$(hook_settings_file "$DIR/..")"

pass=0; fail=0
check(){ if [ "$2" = ok ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/local-allow-sweep-test.XXXXXXXX")" && pwd -P)"
case "${T%/}" in ''|/|"${HOME%/}") echo "refusing: scratch came back as '$T'" >&2; exit 2 ;; esac
trap 'chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"' EXIT

# Invented secrets, each written whole in a shape the push's secret scan accepts by its own rules,
# never assembled from pieces to get past it (claude-config#1125): a bearer value (the scan has no
# bearer rule), an assigned value under the 24 characters the scan reads as a credential, a value
# after a --token flag with a space, and a bare 40 character token of Cloudflare's shape (#1585).
FAKE_BEARER="Zq7Kp9wKp9wKp9wKp9wKp9wKp9wKp9wKp9wXv"
FAKE_ASSIGN="RGsbDJuyuFSMCiK4gnZm"
FAKE_FLAG="TARKU4xHlfoL8Ld3pIAvjkaeiElo8X5Y6hvV"
FAKE_CF="Mu2Q7bFErl22VHXrRzdRySqGZ7eUhA6SpanQFtu0"
TOKEN_NAME="CLOUDFLARE_API_TOKEN"

fp(){ printf '%s' "$1" | shasum -a 256 | cut -c1-12; }
# Permission bits as octal digits, read the same way on macOS and Linux (stat's flags differ).
mode_of(){ python3 -c 'import os, sys; print(format(os.stat(sys.argv[1]).st_mode & 0o777, "o"))' "$1"; }

# world <name>: a fresh HOME, CLAUDE_HOME, project and backup folder.
world(){
  W="$T/$1"
  mkdir -p "$W/home/.claude" "$W/proj/.claude"
  P="$W/proj"; F="$P/.claude/settings.local.json"
}
# fixture <rules...>: a settings file holding these allow rules, written as JSON by python so the
# escaping is right, with other keys around them.
fixture(){
  python3 -c '
import json, sys
json.dump({"permissions": {"allow": sys.argv[2:], "deny": []}, "enableAllProjectMcpServers": True},
          open(sys.argv[1], "w"), indent=2)
' "$F" "$@"
}
sweep(){ # sweep [env...] -> stdout and stderr of one session start, in OUT
  OUT="$(cd "$P" && env HOME="$W/home" CLAUDE_HOME="$W/home/.claude" CLAUDE_PROJECT_DIR="$P" \
    LOCAL_ALLOW_BACKUP_DIR="$W/backups" "$@" bash "$HOOK" </dev/null 2>&1)"
  RC=$?
}
remove(){ # remove <rules arg> [env...] -> OUT, RC
  local r="$1"; shift
  OUT="$(env HOME="$W/home" CLAUDE_HOME="$W/home/.claude" LOCAL_ALLOW_BACKUP_DIR="$W/backups" "$@" \
    python3 "$LIB" remove --project "$P" --rules "$r" 2>&1)"
  RC=$?
}
has(){ case "$OUT" in *"$1"*) echo ok ;; *) echo "output lacks '$1': ${OUT:0:600}" ;; esac; }
lacks(){ case "$OUT" in *"$1"*) echo "output carries '$2'" ;; *) echo ok ;; esac; }
same_file(){ cmp -s "$1" "$2" && echo ok || echo "the file changed"; }
no_secret_under(){ # no_secret_under <dir>: no fake secret is in any file there
  if grep -r -l -F -e "$FAKE_BEARER" -e "$FAKE_ASSIGN" -e "$FAKE_FLAG" -e "$FAKE_CF" "$1" >/dev/null 2>&1; then echo "a secret was written under $1"; else echo ok; fi
}

# --- wiring ------------------------------------------------------------------------------------
if [ -n "$SETTINGS" ] && python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))["hooks"]
cmds = [h.get("command", "") for m in d.get("SessionStart", []) for h in m.get("hooks", [])]
sys.exit(0 if any(c.endswith("/hooks/local-allow-sweep.sh") for c in cmds) else 1)
' "$SETTINGS"; then check "SessionStart runs local-allow-sweep.sh" ok
else check "SessionStart runs local-allow-sweep.sh" "not wired in ${SETTINGS:-the hooks block}"; fi

# --- nothing to read, nothing to flag -----------------------------------------------------------
world none; rm -rf "$P/.claude"
sweep
check "no settings file: exit 0" "$([ "$RC" -eq 0 ] && echo ok || echo "rc $RC")"
check "no settings file: says nothing" "$([ -z "$OUT" ] && echo ok || echo "said: $OUT")"

world clean
fixture 'Bash(npm run test:*)' 'Bash(git status)' 'Bash(swift test)' 'Bash(ls *)' \
  'WebFetch(domain:example.test)' 'mcp__posthog__exec' 'Bash(./scripts/check.sh)' 'Read(//srv/project/**)'
cp "$F" "$W/orig"
sweep
check "a clean file: exit 0" "$([ "$RC" -eq 0 ] && echo ok || echo "rc $RC")"
check "a clean file: says nothing" "$([ -z "$OUT" ] && echo ok || echo "said: $OUT")"
check "a clean file: is not changed" "$(same_file "$F" "$W/orig")"
check "a clean file: no record written" "$([ ! -e "$W/home/.claude/state/local-allow-sweep" ] && echo ok || echo "a state folder was made")"

# --- each kind flagged ---------------------------------------------------------------------------
world kinds
fixture 'Bash(npm run test:*)' \
  'Bash(grep -rn foo * --include=x)' \
  'Bash(grep -n "handleSubmit" src/app/page.tsx)' \
  'Bash(node dist/cli.js:*)' \
  'Read(//private/tmp/claude-501/scratch/**)' \
  "Bash(curl -s -H \"Authorization: Bearer $FAKE_BEARER\" https://api.example.test/v1/zones)" \
  "Bash($TOKEN_NAME=$FAKE_ASSIGN wrangler deploy)" \
  'Bash(git status)'
cp "$F" "$W/orig"
sweep
check "flagged: exit 0" "$([ "$RC" -eq 0 ] && echo ok || echo "rc $RC")"
check "flagged: says how many are flagged" "$(has '8 allow rules; 6 are flagged')"
check "flagged: a * inside the command" "$(has 'rule 2 (Bash grep): one off: a * inside the command')"
check "flagged: literal arguments" "$(has 'rule 3 (Bash grep): one off: literal arguments')"
check "flagged: a path into dist" "$(has 'rule 4 (Bash node): one off: a path into dist or a temp folder')"
check "flagged: a path into a temp folder" "$(has 'rule 5 (Read): one off: a path into dist or a temp folder')"
check "flagged: a bearer header" "$(has 'rule 6 (Bash curl): holds a key or token')"
check "flagged: a token assignment, named by the command after it" "$(has 'rule 7 (Bash wrangler): holds a key or token')"
check "flagged: rule 1, a prefix rule, is not named" "$(lacks 'rule 1 ' 'rule 1')"
check "flagged: rule 8, an exact plain command, is not named" "$(lacks 'rule 8 ' 'rule 8')"
check "flagged: the bearer token is not printed" "$(lacks "$FAKE_BEARER" 'the bearer token')"
check "flagged: the assigned token is not printed" "$(lacks "$FAKE_ASSIGN" 'the assigned token')"
check "flagged: no rule text is printed" "$(lacks 'handleSubmit' 'the text of rule 3')"
check "flagged: asks with a picker" "$(has 'AskUserQuestion')"
check "flagged: more than three flagged offers removal by kind" "$(has "Remove the 2 holding a key or token")"
check "flagged: the removal command names rules by position and fingerprint" \
  "$(has "6:$(fp "Bash(curl -s -H \"Authorization: Bearer $FAKE_BEARER\" https://api.example.test/v1/zones)")")"
check "flagged: the file is not changed by the sweep" "$(same_file "$F" "$W/orig")"
check "flagged: the record holds no secret" "$(no_secret_under "$W/home")"

# --- once per set ---------------------------------------------------------------------------------
sweep
check "the same set again: says nothing" "$([ -z "$OUT" ] && echo ok || echo "said: ${OUT:0:300}")"
python3 -c '
import json, sys
d = json.load(open(sys.argv[1])); d["permissions"]["allow"] = d["permissions"]["allow"][:3]
json.dump(d, open(sys.argv[1], "w"), indent=2)' "$F"
sweep
check "a smaller set (some removed): says nothing" "$([ -z "$OUT" ] && echo ok || echo "said: ${OUT:0:300}")"
python3 -c '
import json, sys
d = json.load(open(sys.argv[1])); d["permissions"]["allow"].append("Bash(cat /tmp/x.log)")
json.dump(d, open(sys.argv[1], "w"), indent=2)' "$F"
sweep
check "a new flagged rule: says again" "$(has 'rule 4 (Bash cat): one off')"
check "a new flagged rule: three or fewer are offered one by one" "$(has 'Remove rule 4')"

# A process id is a literal argument: kill 48213 matches one process, once. A plain word is not.
world pid
fixture 'Bash(kill 48213)' 'Bash(git status)'
sweep
check "a process id: flagged as literal arguments" "$(has 'rule 1 (Bash kill): one off: literal arguments')"
check "a process id: the plain command beside it is not" "$(lacks 'rule 2 ' 'rule 2')"

# A detached headless run says nothing and records nothing, so the next real session still says it.
world detached
fixture 'Bash(grep -n "x" a/b.ts)'
sweep CLAUDE_DETACHED_RUN=1
check "detached: says nothing" "$([ -z "$OUT" ] && echo ok || echo "said: $OUT")"
sweep
check "detached: the next real session says it" "$(has 'rule 1 (Bash grep): one off: literal arguments')"

# --- a file that cannot be judged says so, distinctly, and once -------------------------------------
world malformed
printf '{ "permissions": { "allow": [ "Bash(ls)", ] }\n' > "$F"
cp "$F" "$W/orig"
sweep
check "malformed: exit 0" "$([ "$RC" -eq 0 ] && echo ok || echo "rc $RC")"
check "malformed: says it could not be read as JSON" "$(has 'could not be read as JSON')"
check "malformed: is not changed" "$(same_file "$F" "$W/orig")"
sweep
check "malformed: says it once" "$([ -z "$OUT" ] && echo ok || echo "said: $OUT")"

# A file broken for a moment and then mended does not make its flagged rules new again.
world mended
fixture 'Bash(grep -n "x" a/b.ts)'
cp "$F" "$W/good"
sweep
check "mended: the flagged rule is said first" "$(has 'rule 1 (Bash grep)')"
printf '{ "permissions": ' > "$F"
sweep
check "mended: the broken file is said" "$(has 'could not be read as JSON')"
cp "$W/good" "$F"
sweep
check "mended: the same flagged rule is not said again" "$([ -z "$OUT" ] && echo ok || echo "said: ${OUT:0:300}")"

world notalist
printf '{ "permissions": { "allow": "Bash(ls)" } }\n' > "$F"
sweep
check "allow not a list: says so" "$(has 'is not a list')"

if [ "$(id -u)" != 0 ]; then
  world unreadable
  fixture 'Bash(grep -n "x" a/b.ts)'
  chmod 000 "$F"
  sweep
  chmod 644 "$F"
  check "unreadable: says it could not be read" "$(has 'could not be read (')"
  check "unreadable: does not call it malformed" "$(lacks 'as JSON' 'the malformed message')"
else
  echo "SUITE-PART-UNMEASURED the unreadable file case: running as root, which reads a file with mode 000"
fi

# A token after a flag and a space, and a bare token of Cloudflare's shape, are keys too (#1585):
# Bidspoke's saved rules held exactly such a Cloudflare token. A commit id and a long plain name
# beside them are not.
world flagtokens
fixture "Bash(npx wrangler whoami --api-key $FAKE_FLAG)" \
  "Bash(printf %s $FAKE_CF | npx wrangler secret put CF_KEY)" \
  'Bash(git show 4dbee97a1c2e3f4a5b6c7d8e9f00112233445566:*)' \
  'Bash(npm run run_every_hook_against_its_own_suite_now:*)'
sweep
check "a token after --api-key: flagged" "$(has 'rule 1 (Bash npx): holds a key or token')"
check "a bare Cloudflare shaped token: flagged" "$(has 'rule 2 (Bash printf): holds a key or token')"
check "a commit id: not flagged" "$(lacks 'rule 3 ' 'rule 3')"
check "a long plain name: not flagged" "$(lacks 'rule 4 ' 'rule 4')"
check "the flag token is not printed" "$(lacks "$FAKE_FLAG" 'the flag token')"
check "the Cloudflare shaped token is not printed" "$(lacks "$FAKE_CF" 'the Cloudflare token')"
check "flag tokens: the record holds no secret" "$(no_secret_under "$W/home")"
# The detector is the one redactor (lib/review-redact.sed, through ar_redact). Without it nothing can
# say whether a rule holds a key, and that is said rather than passed as clean.
world noredactor
mkdir -p "$W/lib"; cp "$DIR/lib/ai-review-common.sh" "$W/lib/"
fixture 'Bash(npm run test:*)'
sweep LOCAL_ALLOW_REVIEW_COMMON="$W/lib/ai-review-common.sh"
check "no redactor: says the keys could not be checked" "$(has 'could not check')"
sweep LOCAL_ALLOW_REVIEW_COMMON="$W/lib/ai-review-common.sh"
check "no redactor: says it again next session, since it is never recorded" "$(has 'could not check')"

# --- remove -------------------------------------------------------------------------------------------
# Hand formatted, with tabs, odd spacing, a key after the rules and a non ASCII escape, so any
# rewrite that re-serialises the file changes bytes this compares.
world remove
RULE2='Bash(grep -rn \"handleSubmit\" src/app/page.tsx)'
RULE4="Bash(curl -s -H \\\"Authorization: Bearer $FAKE_BEARER\\\" https://api.example.test/v1/zones)"
TAB="$(printf '\t')"
cat > "$F" <<EOF
{
${TAB}"permissions" : {
${TAB}${TAB}"allow":[
${TAB}${TAB}${TAB}"Bash(npm run test:*)",
${TAB}${TAB}${TAB}"$RULE2",
${TAB}${TAB}${TAB}"Bash(git status)",
${TAB}${TAB}${TAB}"$RULE4",
${TAB}${TAB}${TAB}"WebFetch(domain:example.test)"
${TAB}${TAB}],
${TAB}${TAB}"deny" : [ "Bash(rm -rf /)" ]
${TAB}},
${TAB}"enabledMcpjsonServers": ["café"],
${TAB}"note":   "kept   exactly"
}
EOF
cat > "$W/expected" <<EOF
{
${TAB}"permissions" : {
${TAB}${TAB}"allow":[
${TAB}${TAB}${TAB}"Bash(npm run test:*)",
${TAB}${TAB}${TAB}"Bash(git status)",
${TAB}${TAB}${TAB}"WebFetch(domain:example.test)"
${TAB}${TAB}],
${TAB}${TAB}"deny" : [ "Bash(rm -rf /)" ]
${TAB}},
${TAB}"enabledMcpjsonServers": ["café"],
${TAB}"note":   "kept   exactly"
}
EOF
cp "$F" "$W/orig"
chmod 640 "$F"
R2="2:$(fp 'Bash(grep -rn "handleSubmit" src/app/page.tsx)')"
R4="4:$(fp "Bash(curl -s -H \"Authorization: Bearer $FAKE_BEARER\" https://api.example.test/v1/zones)")"
remove "$R2,$R4"
check "remove: exit 0" "$([ "$RC" -eq 0 ] && echo ok || echo "rc $RC: $OUT")"
check "remove: only the picked rules go, every other byte stays" "$(same_file "$F" "$W/expected")"
check "remove: says which rules it removed" "$(has 'Removed rules 2, 4')"
check "remove: does not print the token" "$(lacks "$FAKE_BEARER" 'the bearer token')"
check "remove: keeps the file's mode" "$([ "$(mode_of "$F")" = 640 ] && echo ok || echo "mode is now $(mode_of "$F")")"
find "$W/backups" -type f > "$W/backups.list" 2>/dev/null
IFS= read -r bk < "$W/backups.list" || bk=""
check "remove: took a backup" "$([ -n "$bk" ] && echo ok || echo "no backup under $W/backups")"
[ -n "$bk" ] && check "remove: the backup is the original, byte for byte" "$(same_file "$bk" "$W/orig")"
[ -n "$bk" ] && check "remove: the backup is readable by its owner only" "$([ "$(mode_of "$bk")" = 600 ] && echo ok || echo "mode $(mode_of "$bk")")"
check "remove: names the backup and how to put it back" "$(has "$bk")"
check "remove: nothing was left beside the file" "$([ "$(ls -A "$P/.claude")" = settings.local.json ] && echo ok || echo "found: $(ls -A "$P/.claude" | tr '\n' ' ')")"

# Removing the last rules leaves an empty list, still with everything else exactly as it was.
remove "1:$(fp 'Bash(npm run test:*)'),2:$(fp 'Bash(git status)'),3:$(fp 'WebFetch(domain:example.test)')"
check "remove all: exit 0" "$([ "$RC" -eq 0 ] && echo ok || echo "rc $RC: $OUT")"
python3 - "$W/expected" "$W/expected-empty" <<'PY'
import sys
s = open(sys.argv[1]).read()
a = s.index('"allow":[') + len('"allow":[')
b = s.index("]", a)
open(sys.argv[2], "w").write(s[:a] + s[b:])
PY
check "remove all: an empty list and nothing else changed" "$(same_file "$F" "$W/expected-empty")"

# The default backup folder is outside ~/.claude (the sync only keeps out names ending in .local.json).
world defaultbackup
fixture 'Bash(npm run test:*)' 'Bash(grep -n "x" a/b.ts)'
OUT="$(env -u LOCAL_ALLOW_BACKUP_DIR HOME="$W/home" CLAUDE_HOME="$W/home/.claude" \
  python3 "$LIB" remove --project "$P" --rules "2:$(fp 'Bash(grep -n "x" a/b.ts)')" 2>&1)"; RC=$?
check "default backup: exit 0" "$([ "$RC" -eq 0 ] && echo ok || echo "rc $RC: $OUT")"
check "default backup: lands in ~/.claude-allow-rule-backups" "$([ -n "$(find "$W/home/.claude-allow-rule-backups" -type f 2>/dev/null)" ] && echo ok || echo "none there")"
check "default backup: nothing written under ~/.claude" "$([ -z "$(find "$W/home/.claude" -type f 2>/dev/null)" ] && echo ok || echo "found $(find "$W/home/.claude" -type f)")"

world backupinside
fixture 'Bash(grep -n "x" a/b.ts)'; cp "$F" "$W/orig"
remove "1:$(fp 'Bash(grep -n "x" a/b.ts)')" LOCAL_ALLOW_BACKUP_DIR="$W/home/.claude/backups"
check "a backup folder inside ~/.claude: refused" "$([ "$RC" -ne 0 ] && echo ok || echo "it removed")"
check "a backup folder inside ~/.claude: says why" "$(has 'inside')"
check "a backup folder inside ~/.claude: file unchanged" "$(same_file "$F" "$W/orig")"

# --- removals that cannot be done change nothing ------------------------------------------------------
world stale
fixture 'Bash(npm run test:*)' 'Bash(grep -n "x" a/b.ts)'; cp "$F" "$W/orig"
remove "2:$(fp 'Bash(grep -n "y" a/b.ts)')"
check "a fingerprint not in the file: refused" "$([ "$RC" -ne 0 ] && echo ok || echo "rc 0")"
check "a fingerprint not in the file: says the file changed since the sweep" "$(has 'changed since')"
check "a fingerprint not in the file: unchanged" "$(same_file "$F" "$W/orig")"
check "a fingerprint not in the file: no backup taken" "$([ ! -e "$W/backups" ] && echo ok || echo "a backup was taken")"

world removemalformed
printf '{ "permissions": { "allow": [ "Bash(ls)", ] }\n' > "$F"; cp "$F" "$W/orig"
remove "1:$(fp 'Bash(ls)')"
check "remove on a malformed file: refused" "$([ "$RC" -ne 0 ] && echo ok || echo "rc 0")"
check "remove on a malformed file: says it could not be read as JSON" "$(has 'could not be read as JSON')"
check "remove on a malformed file: unchanged" "$(same_file "$F" "$W/orig")"

if [ "$(id -u)" != 0 ]; then
  world writefails
  fixture 'Bash(npm run test:*)' 'Bash(grep -n "x" a/b.ts)'; cp "$F" "$W/orig"
  chmod 555 "$P/.claude"
  remove "2:$(fp 'Bash(grep -n "x" a/b.ts)')"
  chmod 755 "$P/.claude"
  check "a write that fails: refused" "$([ "$RC" -ne 0 ] && echo ok || echo "rc 0")"
  check "a write that fails: says the file was not changed" "$(has 'not changed')"
  check "a write that fails: the original is untouched" "$(same_file "$F" "$W/orig")"
  check "a write that fails: names the backup" "$(has "$W/backups")"

  world backupfails
  fixture 'Bash(npm run test:*)' 'Bash(grep -n "x" a/b.ts)'; cp "$F" "$W/orig"
  mkdir -p "$W/backups"; chmod 555 "$W/backups"
  remove "2:$(fp 'Bash(grep -n "x" a/b.ts)')"
  chmod 755 "$W/backups"
  check "a backup that fails: refused" "$([ "$RC" -ne 0 ] && echo ok || echo "rc 0")"
  check "a backup that fails: says no backup, nothing removed" "$(has 'no backup')"
  check "a backup that fails: the original is untouched" "$(same_file "$F" "$W/orig")"
else
  echo "SUITE-PART-UNMEASURED the failed write and failed backup cases: running as root, which writes into a mode 555 folder"
fi

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
