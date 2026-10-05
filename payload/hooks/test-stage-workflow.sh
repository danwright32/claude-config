#!/usr/bin/env bash
# Tests for lib/stage-workflow.sh and the two skills that launch a Workflow script through it
# (claude-config#587).
#
# The Workflow tool accepts a scriptPath only when it is a path the tool itself returned or a file
# the session can already read: the working directory, a directory added to the session, or the
# session scratchpad. A script under ~/.claude sits outside all of those, so a skill that hands the
# tool its own installed path is refused every time, however correct the path is. The skills now
# copy the script into the session scratchpad first and pass the copy's path, and this suite tests
# the path that copy step computes.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$DIR/lib/stage-workflow.sh"
SKILLS="$(cd "$DIR/../skills" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; [ -n "${2:-}" ] && echo "  output: $2"; return 0; }

# A fake config home holding a fake skill, and a fake scratchpad. CLAUDE_HOME points the helper's
# refusal at the fake home, so nothing here reads or writes the real ~/.claude.
FAKEHOME="$TMP/home/.claude"
mkdir -p "$FAKEHOME/skills/demo" "$TMP/scratch"
printf 'export const meta = { name: "demo", description: "d" }\n// body\n' > "$FAKEHOME/skills/demo/demo.workflow.js"
SRC="$FAKEHOME/skills/demo/demo.workflow.js"

stage() { CLAUDE_HOME="$FAKEHOME" bash "$HELPER" "$@" 2>&1; }

# --- 1. the happy path: one line out, the path to pass, an exact copy, inside the scratchpad ---
out="$(stage "$SRC" "$TMP/scratch")"; rc=$?
[ "$rc" -eq 0 ] && ok || bad "staging into a real scratchpad succeeds (rc $rc)" "$out"
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = "1" ] && ok || bad "it prints exactly one line, the path to pass" "$out"
case "$out" in
  "$TMP/scratch/"*) ok ;;
  *) bad "the printed path is inside the scratchpad it was given" "$out" ;;
esac
case "$out" in
  /*) ok ;;
  *) bad "the printed path is absolute, because the Workflow tool expands nothing" "$out" ;;
esac
case "$out" in
  *'~'*|*'$HOME'*|*'__CLAUDE'*) bad "the printed path carries nothing the tool would have to expand" "$out" ;;
  *) ok ;;
esac
[ -f "$out" ] && cmp -s "$SRC" "$out" && ok || bad "the file at the printed path is byte for byte the source" "$out"
case "$out" in
  "$FAKEHOME"/*) bad "the printed path is not under the config home the tool refuses" "$out" ;;
  *) ok ;;
esac

# Run twice in one session: the second run replaces the first copy rather than failing on it, so
# the script passed is always the one installed now.
printf '// changed\n' >> "$SRC"
out2="$(stage "$SRC" "$TMP/scratch")"; rc=$?
[ "$rc" -eq 0 ] && [ "$out2" = "$out" ] && cmp -s "$SRC" "$out2" && ok \
  || bad "a second staging refreshes the same copy from the current source" "$out2"

# --- 2. refusals, each with a reason, and nothing printed that could be passed as a path ---
refuses() { # refuses <description> <expected words> <args...>
  local desc="$1" words="$2"; shift 2
  local o r
  o="$(stage "$@")"; r=$?
  if [ "$r" -ne 0 ] && grep -qi -- "$words" <<< "$o" && ! grep -q '^/' <<< "$o"; then ok
  else bad "$desc (rc $r)" "$o"; fi
}
refuses "no arguments is refused with usage" "usage"
refuses "a relative scratchpad is refused" "absolute" "$SRC" "scratch"
refuses "a scratchpad that does not exist is refused" "not a directory" "$SRC" "$TMP/nowhere"
refuses "a missing source script is refused" "not a file" "$FAKEHOME/skills/demo/gone.workflow.js" "$TMP/scratch"
refuses "a destination inside the config home is refused, since the tool refuses that folder" \
  "config" "$SRC" "$FAKEHOME/skills/demo"
# The same folder reached through a symlink is the same folder.
ln -s "$FAKEHOME" "$TMP/linkhome"
refuses "the config home reached through a symlink is still refused" "config" "$SRC" "$TMP/linkhome/skills"

# --- 3. the skills hand the Workflow tool the staged copy, never their installed path ---
for pair in "production-ready:production-audit.workflow.js" "plan-council:panel.workflow.js"; do
  skill="${pair%%:*}"; wf="${pair#*:}"
  md="$SKILLS/$skill/SKILL.md"
  if grep -Eq 'scriptPath: *"(__CLAUDE_HOME__|~|\$HOME|/Users/)' "$md"; then
    bad "$skill/SKILL.md no longer hands Workflow a scriptPath inside the config home" "$(grep -n 'scriptPath' "$md")"
  else ok; fi
  if grep -q "stage-workflow.sh.*skills/$skill/$wf" "$md"; then ok
  else bad "$skill/SKILL.md stages its own $wf through stage-workflow.sh"; fi
  if grep -qi 'scratchpad' "$md"; then ok
  else bad "$skill/SKILL.md says the copy goes into the session scratchpad"; fi
  # The claim this issue exists to remove.
  if grep -q 'That path is absolute and correct on this machine' "$md"; then
    bad "$skill/SKILL.md still claims the installed path is correct to pass"
  else ok; fi
  [ -f "$SKILLS/$skill/$wf" ] && ok || bad "$skill ships the $wf it stages"
done

# The production-ready healthcheck validates the launch as the skill now describes it.
out="$(bash "$SKILLS/production-ready/healthcheck.sh" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'HEALTHCHECK OK' <<< "$out" && ok || bad "production-ready healthcheck passes on this tree" "$out"

# And it is a real check: a SKILL.md that goes back to passing its installed path fails it.
cp -R "$SKILLS/production-ready" "$TMP/pr-bad"
sed -i.bak 's#stage-workflow\.sh#stage-nothing.sh#g' "$TMP/pr-bad/SKILL.md"
out="$(bash "$TMP/pr-bad/healthcheck.sh" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -qi 'stage-workflow' <<< "$out" && ok \
  || bad "production-ready healthcheck fails a SKILL.md that does not stage its workflow" "$out"

# The plan-council healthcheck reads an installed tree under $HOME/.claude, so it is run against a
# fake home holding just what its workflow section reads, and only that section is judged.
PCH="$TMP/pchome"
mkdir -p "$PCH/.claude/skills" "$PCH/.claude/hooks/lib"
cp -R "$SKILLS/plan-council" "$PCH/.claude/skills/"
cp "$HELPER" "$PCH/.claude/hooks/lib/"
pc_section() { HOME="$PCH" bash "$PCH/.claude/skills/plan-council/healthcheck.sh" 2>&1 | sed -n '/skill -> workflow/,/^==/p'; }
out="$(pc_section)"
if [ "$(grep -c '^  ok' <<< "$out")" = "2" ] && ! grep -q 'FAIL' <<< "$out"; then ok
else bad "plan-council healthcheck passes its workflow section on this tree" "$out"; fi
sed -i.bak 's#stage-workflow\.sh#stage-nothing.sh#g' "$PCH/.claude/skills/plan-council/SKILL.md"
out="$(pc_section)"
grep -q 'FAIL.*stage-workflow' <<< "$out" && ok \
  || bad "plan-council healthcheck fails a SKILL.md that does not stage its workflow" "$out"
rm -f "$PCH/.claude/hooks/lib/stage-workflow.sh"
out="$(pc_section)"
grep -q 'FAIL.*exact copy' <<< "$out" && ok \
  || bad "plan-council healthcheck fails when the staging helper is missing" "$out"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
