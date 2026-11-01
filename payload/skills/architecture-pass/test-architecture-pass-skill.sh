#!/usr/bin/env bash
# Tests for the architecture pass skill's instructions (claude-config#1504).
#
# measure.py's counting rules are tested in test_measure.py. This suite holds SKILL.md to what the
# issue settled and what the manual passes of 2026-10-22 taught: it runs only when Dan starts it,
# it never counts fixes with git log --grep, it looks for the four shapes directly with at most four
# agents at once, it spot checks every agent claim, it looks across repos, and it files only what
# Dan picks, one question per picker, with a milestone, a priority and a category. Every
# measure.py command in a block is RUN as written against a fixture repository (L442), with a state
# directory of the suite's own, so this Mac's record of past passes is never touched.
# ARCH_PASS_SKILL points the suite at another copy, which is how a broken copy is shown to fail.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="${ARCH_PASS_SKILL:-$DIR/SKILL.md}"

pass=0
fail=0
check() { # check <description> <result>   ("ok" passes, anything else is the failure text)
  if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/architecture-pass-skill.XXXXXXXX")" || TMP=""
case "${TMP%/}" in
  ''|/|"${HOME%/}") echo "test-architecture-pass-skill: refusing to run: throwaway directory came back as '$TMP'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMP"' EXIT

check "the skill is there to read" "$([ -f "$SKILL" ] && echo ok || echo "no $SKILL")"
front="$(awk 'NR==1 && $0=="---" {on=1; next} on && $0=="---" {exit} on {print}' "$SKILL" 2>/dev/null)"
CODE="$(awk '/^```/ { inside = !inside; next } inside' "$SKILL" 2>/dev/null)"

# ---- 1. started by hand only, so it never costs anything Dan did not ask for ----
check "its name is architecture-pass" "$(grep -qx 'name: architecture-pass' <<< "$front" && echo ok || echo "frontmatter: $front")"
check "it runs only when Dan types it" \
  "$(grep -qx 'disable-model-invocation: true' <<< "$front" && echo ok || echo "no disable-model-invocation: true")"
check "its trigger is /architecture-pass" "$(grep -qx 'trigger: /architecture-pass' <<< "$front" && echo ok || echo "no trigger line")"
check "its description says when to use it" "$(grep -q '^description: Use when' <<< "$front" && echo ok || echo "description does not start Use when")"
check "the skill says it never runs unattended" \
  "$(grep -qi 'never runs unattended' "$SKILL" && echo ok || echo "no sentence saying it never runs unattended")"

# ---- 2. fixes are counted by title, through measure.py, never git log --grep ----
check "no command counts with git log --grep, which matches commit bodies" \
  "$(grep -qE 'git log.*--grep' <<< "$CODE" && echo "a block runs git log --grep" || echo ok)"
check "and the skill says why, so nobody adds it back" \
  "$(grep -q 'git log --grep' "$SKILL" && grep -qi 'bodies' "$SKILL" && echo ok || echo "no sentence naming git log --grep and bodies")"
for sub in last-pass hotspots kinds record-pass; do
  check "a block runs measure.py $sub" \
    "$(grep -qE "^python3 ~/\.claude/skills/architecture-pass/measure\.py $sub <repo>" <<< "$CODE" && echo ok || echo "no block line runs measure.py $sub <repo>")"
done

# Run every measure.py line as written, pointed at this checkout's copy and a fixture repository.
REPO="$TMP/widgets"; mkdir -p "$REPO"
fixture_git() {
  GIT_AUTHOR_NAME=F GIT_AUTHOR_EMAIL=f@example.com GIT_COMMITTER_NAME=F GIT_COMMITTER_EMAIL=f@example.com \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null git -C "$REPO" "$@" >/dev/null 2>&1
}
fixture_git init -q -b main
printf 'a\n' > "$REPO/app.ts"; fixture_git add app.ts; fixture_git commit -q -m "Add app"
printf 'b\n' > "$REPO/app.ts"; fixture_git commit -q -a -m "Fix the race in app"
fixture_git remote add origin git@github.com:acme/widgets.git
fixture_git update-ref refs/remotes/origin/main HEAD
STATE="$TMP/state"
ran=0
# Read into a variable first, never through process substitution, whose child bash 3.2 never waits
# for and whose exit can cut short what this suite prints next (L1035, claude-config#1989).
measure_lines="$(grep -E '^python3 ~/\.claude/skills/architecture-pass/measure\.py ' <<< "$CODE")"
while IFS= read -r line; do
  [ -n "$line" ] || continue
  runnable="${line//\~\/.claude\/skills\/architecture-pass\//$DIR/}"
  runnable="${runnable//<repo>/$REPO}"
  runnable="${runnable//<scratch>/$TMP}"
  out="$(ARCH_PASS_STATE_DIR="$STATE" ARCH_PASS_TODAY=2026-10-27 bash -c "$runnable" 2>&1)"; rc=$?
  ran=$((ran + 1))
  check "the command runs as written: $line" "$([ "$rc" -eq 0 ] && echo ok || echo "exit $rc: $out")"
done <<MEASURE_LINES
$measure_lines
MEASURE_LINES
check "and the suite ran every one of them" "$([ "$ran" -ge 4 ] && echo ok || echo "only $ran measure.py lines ran")"
check "the hotspots and kinds output landed where the skill reads it" \
  "$(python3 -c 'import json,sys; [json.load(open(p)) for p in sys.argv[1:]]' "$TMP/hotspots.json" "$TMP/kinds.json" 2>&1 && echo ok)"
check "and record-pass wrote the date last-pass reads back" \
  "$(grep -qF '"acme/widgets": "2026-10-27"' "$STATE/last-pass.json" 2>/dev/null && echo ok || echo "state: $(cat "$STATE/last-pass.json" 2>&1)")"

# ---- 3. the judgement steps the measurements cannot make ----
for shape in 'hand wired chain' 'calling sequence' 'two homes' 'multi step write'; do
  check "the skill looks for the shape: $shape" "$(grep -qi "$shape" "$SKILL" && echo ok || echo "not named")"
done
check "agents are capped at four at once" "$(grep -qi 'at most four' "$SKILL" && echo ok || echo "no 'at most four'")"
# The needle sits on a line of its own: the spool's own suite flags any line where a documented
# note call is followed by a shell expansion, and the file name after it would read as one.
note_call='bash ~/.claude/hooks/lib/issue-spool.sh note . "<the finding>" "architecture-pass"'
check "agents record out of scope findings with issue-spool" \
  "$(grep -qF "$note_call" "$SKILL" && echo ok || echo "no issue-spool note command")"
check "every agent claim is spot checked against the code" \
  "$(grep -qi 'spot check' "$SKILL" && echo ok || echo "no spot check step")"
check "the pass looks across repos for a pattern that fixes another" \
  "$(grep -qi 'across repos' "$SKILL" && echo ok || echo "no cross repo step")"
check "growth and pure additions are read before a hot file is called a problem" \
  "$(grep -q 'pure_addition_share' "$SKILL" && grep -q 'net_growth_share' "$SKILL" && echo ok || echo "the growth fields are not named")"

# ---- 4. proposes, never files on its own ----
check "proposals go to Dan in AskUserQuestion, one question per call" \
  "$(grep -q 'AskUserQuestion' "$SKILL" && grep -qi 'one question per call' "$SKILL" && echo ok || echo "no picker, or not one question per call")"
check "it files only what Dan picks" "$(grep -qi 'only what Dan picks' "$SKILL" && echo ok || echo "missing")"
create_line="$(grep -m 1 -E '^gh issue create ' <<< "$CODE")"
check "the filing command carries a milestone, a priority and a category" \
  "$(grep -q -- '--milestone' <<< "$create_line" && grep -q 'priority-p' <<< "$create_line" && grep -q 'architecture' <<< "$create_line" && echo ok || echo "the line is: $create_line")"
check "and its body comes from a file, never inline" \
  "$(grep -q -- '--body-file' <<< "$create_line" && echo ok || echo "the line is: $create_line")"
check "the milestone comes from ensure-milestone.sh" \
  "$(grep -qF 'bash ~/.claude/skills/milestone/ensure-milestone.sh' <<< "$CODE" && echo ok || echo "no ensure-milestone.sh line")"

# ---- 5. the style rule: no em or en dash anywhere in the skill ----
dashes="$(grep -n $'\xe2\x80\x94\|\xe2\x80\x93' "$SKILL" 2>/dev/null)"
check "the skill holds no em or en dash" "$([ -z "$dashes" ] && echo ok || echo "$dashes")"

echo ""
echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
