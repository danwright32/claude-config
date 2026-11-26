#!/usr/bin/env bash
# send-gate: scans settings.hooks.json
# Tests for the hook that asks Dan before a skill shipped by an MCP server loads (claude-config#3615).
#
# An MCP server can ship skills beside its tools. In auto mode such a skill loads with no prompt, and
# its text is the server's, which can change it at any time. Dan accepted on 2026-11-25, in the
# article review picker, "Ask before a server's skill loads".
#
# WHAT IS HELD HERE.
#
#   1. What the hook decides, on payloads built by hand in the shape Claude Code sends a PreToolUse
#      hook for the Skill tool (tool_name "Skill", tool_input.skill). No skill is ever loaded and no
#      server is reached: the hook reads a name and prints a decision. The names are the forms
#      Claude Code's documentation gives (read 2026-11-26): <server>:<skill>, claude_ai_<name>:<skill>
#      for a connector, plugin_<plugin>_<server>:<skill> for a plugin's server, and the rule form
#      mcp__<server>__<skill>. NO SERVER SKILL HAS EVER LOADED on either Mac, so none of these was
#      measured from a real call.
#   2. That a skill kept on this Mac passes in silence: Dan's own, a bundled one, one synced from
#      claude.ai (anthropic-skills:), an installed plugin's that is on disk, and a directory's own.
#      The plugin and the directory are a made up home and project under the scratch folder.
#   3. Awake it asks; while Dan is asleep it refuses, and it refuses when it cannot tell which.
#   4. What it cannot read it asks about, and a call that is not a Skill call is never its business.
#   5. That it is wired: registered under PreToolUse for the Skill tool, to block when it fails.
#
# WHAT IT DOES NOT HOLD. That Claude Code hands a server skill's name to this hook in one of the
# forms above: the first real one is the measurement.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# SERVER_SKILL_ASK_HOOK names another hook to run the same cases against, so a stand in that decides
# differently can be seen to fail them.
HOOK="${SERVER_SKILL_ASK_HOOK:-$DIR/server-skill-ask.sh}"
. "$DIR/lib/settings-file.sh" 2>/dev/null || { echo "FAIL: lib/settings-file.sh is missing beside this suite"; printf 'SUITE-RESULT passed=0 failed=1\n'; exit 1; }
SETTINGS="$(hook_settings_file "$DIR/..")" || SETTINGS=""

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

if [ ! -f "$HOOK" ]; then
  echo "FAIL: there is no server-skill-ask.sh beside this suite at $DIR, so nothing asks before a skill shipped by an MCP server loads"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi
[ -x "$HOOK" ] && check "the hook is executable, as the settings run it by its path" ok || check "the hook is executable, as the settings run it by its path" "mode lacks x"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# A home holding one installed plugin, and a project holding one directory's own skill.
FAKE_HOME="$WORK/home"
PLUGIN="$WORK/plugins-cache/kit/1.0.0"
PROJECT="$WORK/project"
mkdir -p "$FAKE_HOME/.claude/plugins" "$PLUGIN/skills/brainstorming" "$PLUGIN/skills/a-folder" "$PLUGIN/commands/deep" \
  "$PROJECT/apps/web/.claude/skills/deploy"
printf -- '---\nname: brainstorming\n---\nbody\n' > "$PLUGIN/skills/brainstorming/SKILL.md"
printf -- '---\nname: fancy\ndescription: named apart from its folder\n---\nbody\n' > "$PLUGIN/skills/a-folder/SKILL.md"
printf 'a command\n' > "$PLUGIN/commands/build.md"
printf 'a nested command\n' > "$PLUGIN/commands/deep/dive.md"
printf -- '---\nname: deploy\n---\nbody\n' > "$PROJECT/apps/web/.claude/skills/deploy/SKILL.md"
python3 -c 'import json, sys; json.dump({"version": 2, "plugins": {"kit@a-marketplace": [{"scope": "user", "installPath": sys.argv[1], "version": "1.0.0"}]}}, open(sys.argv[2], "w"))' \
  "$PLUGIN" "$FAKE_HOME/.claude/plugins/installed_plugins.json"

# Awake is a sleep record that is not there, asleep a real one judged by lib/sleep.sh, never a
# stand in flag. Named on every run, so the Mac really being asleep cannot decide a case.
AWAKE="$WORK/no-sleep-record.json"
NOW_MS="$(date +%s)000"
BOOT="$(bash -c '. "$1" && sleep_boot_of "$(sysctl -n kern.boottime 2>/dev/null)"' _ "$DIR/lib/sleep.sh")"
[ -n "$BOOT" ] || BOOT=1   # no sysctl (Linux CI): sleep.sh skips the boot check, so any boot will do
ASLEEP="$WORK/asleep-record.json"
printf '{"v":1,"generation":"g-test","since":%s,"until":%s,"night":"2026-11-25","bootTime":%s,"report":"%s/r.md","startedBy":{"sessionId":"s0","cwd":"/"},"workers":[],"placeBefore":"home"}\n' \
  "$((NOW_MS - 60000))" "$((NOW_MS + 3600000))" "$BOOT" "$WORK" > "$ASLEEP"

# run <hook> <payload> [<sleep record>]: the hook's stdout, its exit code on the last line.
run() {
  local out rc
  out="$(cd "$WORK" && printf '%s' "$2" | env -u CLAUDE_HOME HOME="$FAKE_HOME" CLAUDE_SLEEP_RECORD="${3:-$AWAKE}" bash "$1" 2>/dev/null)"; rc=$?
  printf '%s\nrc=%s\n' "$out" "$rc"
}
# decision <run output>: ask, deny, allow, none or badjson, then " rc=N".
decision() {
  local rc="${1##*rc=}" body="${1%$'\n'rc=*}"
  printf '%s' "$body" | python3 -c '
import json, sys
t = sys.stdin.read().strip()
if not t:
    print("none", end=""); sys.exit()
try:
    d = json.loads(t)
except Exception:
    print("badjson", end=""); sys.exit()
h = d.get("hookSpecificOutput") if isinstance(d, dict) else None
print((h or {}).get("permissionDecision", "none"), end="")'
  printf ' rc=%s' "$rc"
}
reason() {  # reason <run output>
  local body="${1%$'\n'rc=*}"
  printf '%s' "$body" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    sys.exit()
print((d.get("hookSpecificOutput") or {}).get("permissionDecisionReason", ""))'
}
payload() {  # payload <tool> <input as JSON> [<cwd>]
  python3 -c 'import json, sys; print(json.dumps({"session_id": "s1", "transcript_path": "/nonexistent/t.jsonl", "cwd": sys.argv[3], "permission_mode": "auto", "hook_event_name": "PreToolUse", "tool_name": sys.argv[1], "tool_input": json.loads(sys.argv[2])}))' "$1" "$2" "${3:-$PROJECT}"
}
skill() {  # skill <name> [<args>]: a Skill call's payload
  python3 -c 'import json, sys; print(json.dumps({"session_id": "s1", "transcript_path": "/nonexistent/t.jsonl", "cwd": sys.argv[3], "permission_mode": "auto", "hook_event_name": "PreToolUse", "tool_name": "Skill", "tool_input": ({"skill": sys.argv[1], "args": sys.argv[2]} if sys.argv[2] else {"skill": sys.argv[1]})}))' "$1" "${2:-}" "$PROJECT"
}
expect() {  # expect <label> <want decision> <payload> [<sleep record>] [<hook>]
  local got; got="$(decision "$(run "${5:-$HOOK}" "$3" "${4:-$AWAKE}")")"
  [ "$got" = "$2 rc=0" ] && check "$1" ok || check "$1" "wanted $2 rc=0, got $got"
}
says() {  # says <label> <run output> <ERE the reason must match>
  local r; r="$(reason "$2")"
  [[ $r =~ $3 ]] && check "$1" ok || check "$1" "the reason does not say /$3/: ${r:0:300}"
}

# --- 1. a skill from a server is asked about ------------------------------------------------------
echo "a skill shipped by an MCP server is asked about, in every form the documentation gives its name"
for n in claude_ai_Docs:pdf plugin_my-plugin_docs:pdf docs:pdf mcp__docs__pdf mcp__claude_ai_Docs__pdf MCP__docs__pdf /docs:pdf kit:not-on-disk nokit:brainstorming; do
  expect "$n is asked about" ask "$(skill "$n")"
done
expect "a server skill called with arguments is asked about" ask "$(skill docs:pdf 'report.pdf --fast')"
r="$(run "$HOOK" "$(skill claude_ai_Docs:pdf)")"
says "the question names the skill" "$r" 'the skill pdf'
says "the question names the connector" "$r" 'claude\.ai connector Docs'
says "the question says the text is the server's and can change at any time" "$r" 'can change it at any time'
says "the question says whose decision it is, and when" "$r" 'Dan decided on 2026-11-25'
says "the question names the issue" "$r" '#3615'
r="$(run "$HOOK" "$(skill plugin_my-plugin_docs:pdf)")"
says "a plugin's server is named as one" "$r" 'server shipped by a plugin \(my-plugin_docs\)'
r="$(run "$HOOK" "$(skill docs:pdf)")"
says "a server added by hand is named" "$r" 'MCP server docs'
r="$(run "$HOOK" "$(skill mcp__docs__pdf)")"
says "the rule form names its server and skill" "$r" 'the skill pdf.*MCP server docs'
r="$(run "$HOOK" "$(skill kit:not-on-disk)")"
says "a name under an installed plugin that holds no such skill says so" "$r" 'no installed plugin named kit holds a skill not-on-disk'

echo "a name written to look local is read as Claude Code compares names"
# A fullwidth colon, a space after the colon and a zero width space: the documentation says names
# are compared ignoring spacing and invisible characters, with fullwidth forms as their plain ones.
expect "docs and pdf joined by a fullwidth colon is asked about" ask "$(skill $'docs\xef\xbc\x9apdf')"
expect "docs: pdf, with a space after the colon, is asked about" ask "$(skill 'docs: pdf')"
expect "docs:pdf with a zero width space before the colon is asked about" ask "$(skill $'docs\xe2\x80\x8b:pdf')"
expect "a connector's name joined to pdf by a small colon is asked about" ask "$(skill $'claude_ai_Docs\xef\xb9\x95pdf')"
expect "a name holding punctuation this hook cannot place is asked about" ask "$(skill $'docs\xea\x9e\x89pdf')"

# --- 2. a skill kept on this Mac passes in silence ------------------------------------------------
echo "a skill kept on this Mac passes in silence"
for n in next-issue db-apply no-ai-tells code-review init plugin-authoring plannotator-annotate keybindings-help a.b_c-d; do
  expect "$n passes" none "$(skill "$n")"
done
expect "a local skill with arguments passes" none "$(skill next-issue 'see mcp__docs__pdf and docs:pdf')"
expect "a skill synced from claude.ai passes (anthropic-skills is reserved for them)" none "$(skill anthropic-skills:docx)"
expect "an installed plugin's skill, on disk in its skills folder, passes" none "$(skill kit:brainstorming)"
expect "an installed plugin's skill named apart from its folder passes" none "$(skill kit:fancy)"
expect "an installed plugin's command passes" none "$(skill kit:build)"
expect "an installed plugin's nested command passes" none "$(skill kit:deep:dive)"
expect "a directory's own skill, on disk under the working directory, passes" none "$(skill apps/web:deploy)"
expect "a directory form with no such skill on disk is asked about" ask "$(skill apps/api:deploy)"
# The same plugin skill under a home holding no record of installed plugins: nothing says it is on
# this Mac, so it is asked about.
EMPTY_HOME="$WORK/empty-home"
mkdir -p "$EMPTY_HOME"
r="$(cd "$WORK" && printf '%s' "$(skill kit:brainstorming)" | env -u CLAUDE_HOME HOME="$EMPTY_HOME" CLAUDE_SLEEP_RECORD="$AWAKE" bash "$HOOK" 2>/dev/null; printf '\nrc=%s\n' "$?")"
[ "$(decision "$r")" = "ask rc=0" ] && check "with no record of installed plugins, a plugin form is asked about" ok || check "with no record of installed plugins, a plugin form is asked about" "$(decision "$r")"
says "and the question says the record is not there, never that no plugin holds the skill" "$r" 'no record of installed plugins'
# A record that is there and cannot be read is said to be that, too (L11).
BAD_HOME="$WORK/bad-home"
mkdir -p "$BAD_HOME/.claude/plugins"
printf 'not json' > "$BAD_HOME/.claude/plugins/installed_plugins.json"
r="$(cd "$WORK" && printf '%s' "$(skill kit:brainstorming)" | env -u CLAUDE_HOME HOME="$BAD_HOME" CLAUDE_SLEEP_RECORD="$AWAKE" bash "$HOOK" 2>/dev/null; printf '\nrc=%s\n' "$?")"
[ "$(decision "$r")" = "ask rc=0" ] && check "with a record of installed plugins that cannot be read, a plugin form is asked about" ok || check "with a record of installed plugins that cannot be read, a plugin form is asked about" "$(decision "$r")"
says "and the question says the record could not be read" "$r" 'installed plugins .*could not be read'

# --- 3. asleep --------------------------------------------------------------------------------------
echo "while Dan is asleep a server's skill is refused, with the reason, and a local skill still passes"
CLAUDE_SLEEP_RECORD="$ASLEEP" bash -c '. "$1" && sleep_active' _ "$DIR/lib/sleep.sh" >/dev/null 2>&1 \
  && check "the asleep record reads as asleep to lib/sleep.sh (the control)" ok \
  || check "the asleep record reads as asleep to lib/sleep.sh (the control)" "sleep_active says awake, so the asleep cases below prove nothing"
for n in claude_ai_Docs:pdf plugin_my-plugin_docs:pdf docs:pdf mcp__docs__pdf; do
  expect "asleep, $n is refused" deny "$(skill "$n")" "$ASLEEP"
  expect "awake, the same call is asked about (the control)" ask "$(skill "$n")" "$AWAKE"
done
r="$(run "$HOOK" "$(skill claude_ai_Docs:pdf)" "$ASLEEP")"
says "the refusal says Dan is asleep" "$r" 'Dan is asleep'
says "the refusal names the skill and the server" "$r" 'the skill pdf.*claude\.ai connector Docs'
says "the refusal says not to reach the same end another way" "$r" 'another way'
expect "asleep, a local skill passes untouched" none "$(skill next-issue)" "$ASLEEP"
expect "asleep, an installed plugin's skill passes untouched" none "$(skill kit:brainstorming)" "$ASLEEP"

# --- 4. what it cannot read ---------------------------------------------------------------------------
echo "a Skill call it cannot read is asked about, and a call that is not a Skill call is not its business"
expect "a Skill call naming no skill is asked about" ask "$(payload Skill '{}')"
expect "a Skill call whose skill is a list is asked about" ask "$(payload Skill '{"skill": ["docs:pdf"]}')"
expect "a Skill call whose skill is empty is asked about" ask "$(payload Skill '{"skill": ""}')"
expect "a Skill call whose input is one string is asked about" ask "$(python3 -c 'import json; print(json.dumps({"hook_event_name": "PreToolUse", "tool_name": "Skill", "tool_input": json.dumps({"skill": "docs:pdf"})}))')"
whole="$(skill docs:pdf)"
expect "a Skill call cut short is asked about" ask "${whole%?}"
r="$(run "$HOOK" "${whole%?}")"
says "and the question names the payload" "$r" 'payload'
expect "a Skill call inside a list is asked about" ask "[$whole]"
expect "a Skill call cut short inside its name is asked about" ask "${whole%%:pdf*}"
expect "text that is no JSON and names no tool is asked about" ask 'not json at all'
expect "a local Skill call holding a second skill key is read by its own skill, not the first found" none "$(python3 -c 'import json; print(json.dumps({"hook_event_name": "PreToolUse", "tool_name": "Skill", "tool_input": {"skill": "next-issue", "args": "x"}, "note": {"skill": "also"}}))')"
expect "a Skill call whose own skill is a server's, behind another skill key, is asked about" ask "$(python3 -c 'import json; print(json.dumps({"note": {"skill": "next-issue"}, "hook_event_name": "PreToolUse", "tool_name": "Skill", "tool_input": {"skill": "docs:pdf"}}))')"
expect "a Skill call carrying a field this hook does not know that names a server is asked about" ask "$(payload Skill '{"skill": "pdf", "source": "mcp__docs__pdf"}')"
expect "a Skill call whose arguments alone name a server passes" none "$(payload Skill '{"skill": "next-issue", "args": "mcp__docs__pdf"}')"
expect "an empty payload passes, as any call naming nothing does (#1922)" none ""
expect "a Bash call naming a server skill in its text is not this hook's" none "$(payload Bash '{"command": "echo docs:pdf mcp__docs__pdf Skill"}')"
bash_whole="$(payload Bash '{"command": "ls -la"}')"
expect "a Bash call cut short is not this hook's" none "${bash_whole%?}"
expect "an MCP tool call is not this hook's" none "$(payload mcp__docs__search '{"skill": "docs:pdf"}')"
tricky="$(python3 -c 'import json; print(json.dumps({"skill": "docs:p\"d\\f\nline two\tand a tab"}))')"
r="$(run "$HOOK" "$(payload Skill "$tricky")")"
[ "$(decision "$r")" = "ask rc=0" ] && check "a name holding quotes, a backslash, a newline and a tab still gives one valid question" ok || check "a name holding quotes, a backslash, a newline and a tab still gives one valid question" "$(decision "$r")"
long="$(python3 -c 'print("docs:" + "x" * 5000)')"
r="$(run "$HOOK" "$(skill "$long")")"
says "a long name is cut short in the question, saying so" "$r" 'cut short'

echo "with a library or python3 gone it still stops a server's skill, saying what is missing"
# The hook and the files it loads, in a folder of their own with one taken away.
LIBS="hook-notice.sh push-scope.sh sleep.sh ask-awake.sh server-skills.py"
copy_without() {  # copy_without <name> <file under lib to leave out, or -> -> the copied hook's path
  local to="$WORK/$1" f
  mkdir -p "$to/lib"
  cp "$HOOK" "$to/server-skill-ask.sh"
  for f in $LIBS; do
    [ "$f" = "$2" ] || cp "$DIR/lib/$f" "$to/lib/$f" 2>/dev/null
  done
  printf '%s' "$to/server-skill-ask.sh"
}
WHOLE_COPY="$(copy_without whole -)"
expect "the copied hook, with every file in place, asks about a server's skill (the control)" ask "$(skill docs:pdf)" "$AWAKE" "$WHOLE_COPY"
expect "and passes a local one (the control)" none "$(skill next-issue)" "$AWAKE" "$WHOLE_COPY"
for lib in $LIBS; do
  H="$(copy_without "no-$lib" "$lib")"
  r="$(run "$H" "$(skill docs:pdf)")"
  # With lib/sleep.sh or lib/ask-awake.sh gone nothing says whether Dan is asleep, and a question
  # is the one answer sleep mode can say yes to at night: so those are refused, not asked.
  case "$lib" in sleep.sh|ask-awake.sh) want=deny ;; *) want=ask ;; esac
  [ "$(decision "$r")" = "$want rc=0" ] && check "with lib/$lib gone, a server's skill is still stopped ($want)" ok || check "with lib/$lib gone, a server's skill is still stopped ($want)" "$(decision "$r"): ${r:0:200}"
  case "$lib" in
    push-scope.sh) ;;   # the payload is read as it came, which takes nothing away from the question
    *) says "and the answer names lib/$lib" "$r" "lib/${lib//./\\.}" ;;
  esac
  expect "with lib/$lib gone, a local skill is still passed" none "$(skill next-issue)" "$AWAKE" "$H"
done
r="$(run "$(copy_without no-sleep-told sleep.sh)" "$(skill docs:pdf)" "$AWAKE")"
says "with lib/sleep.sh gone, the refusal says that whether Dan is asleep could not be told" "$r" 'whether Dan is asleep could not be told'
says "and how to get past it" "$r" 'pull of the shared config'
expect "with lib/hook-notice.sh gone, a server's skill is still refused while Dan is asleep" deny "$(skill docs:pdf)" "$ASLEEP" "$(copy_without no-notice-asleep hook-notice.sh)"
. "$DIR/lib/no-python-path.sh"
NOPY="$WORK/nopy/bin"
npp_build_bin "$NOPY"
if npp_reaches_python3 "$NOPY"; then
  check "the bare directory reaches no python3" "it found one, so nothing below measures its absence"
else
  run_nopy() { local out rc; out="$(cd "$WORK" && printf '%s' "$1" | env -u CLAUDE_HOME HOME="$FAKE_HOME" CLAUDE_SLEEP_RECORD="$AWAKE" PATH="$NOPY" "$NOPY/bash" "$HOOK" 2>/dev/null)"; rc=$?; printf '%s\nrc=%s\n' "$out" "$rc"; }
  r="$(run_nopy "$(skill docs:pdf)")"
  # Refused, not asked: lib/sleep.sh reads the sleep record with python3, so nothing could tell
  # whether Dan is asleep either.
  case "$(decision "$r")|$(reason "$r")" in
    "deny rc=0|"*"python3 is not on PATH"*) check "with no python3, a server's skill is refused, naming python3" ok ;;
    *) check "with no python3, a server's skill is refused, naming python3" "$(decision "$r") $(reason "$r")" ;;
  esac
  r="$(run_nopy "$(skill next-issue)")"
  [ "$(decision "$r")" = "none rc=0" ] && check "with no python3, a local skill is passed in silence" ok || check "with no python3, a local skill is passed in silence" "$(decision "$r")"
  r="$(run_nopy "$(skill kit:brainstorming)")"
  case "$(decision "$r")|$(reason "$r")" in
    "deny rc=0|"*"python3 is not on PATH"*) check "with no python3, a plugin form cannot be looked up on disk and is refused, naming python3" ok ;;
    *) check "with no python3, a plugin form cannot be looked up on disk and is refused, naming python3" "$(decision "$r") $(reason "$r")" ;;
  esac
fi

# --- 5. it is wired -----------------------------------------------------------------------------
echo "the hook is registered for the Skill tool, to block when it fails"
if [ -z "$SETTINGS" ]; then
  check "a settings file registers the hooks" "no settings.hooks.json or settings.json beside $DIR"
else
  wired="$(python3 - "$SETTINGS" <<'PY'
import json, os, re, sys
d = json.load(open(sys.argv[1]))
rows = [(g.get("matcher", ""), h) for g in d.get("hooks", {}).get("PreToolUse", []) for h in g.get("hooks", [])
        if h.get("command", "").split()[:1] and os.path.basename(h["command"].split()[0]) == "server-skill-ask.sh"]
if not rows:
    print("no PreToolUse entry runs server-skill-ask.sh"); sys.exit()
for matcher, h in rows:
    if h.get("onFailure") != "block":
        print("its registration (matcher %s) has no onFailure block, so a crash or a timeout lets the skill load unasked" % matcher)
if not any(re.fullmatch(m, "Skill") for m, _ in rows):
    print("no registration of it matches the Skill tool")
PY
)"
  [ -z "$wired" ] && check "settings register server-skill-ask.sh for the Skill tool with onFailure block" ok || check "settings register server-skill-ask.sh for the Skill tool with onFailure block" "$wired"
fi

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
