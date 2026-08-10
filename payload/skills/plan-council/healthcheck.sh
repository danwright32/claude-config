#!/usr/bin/env bash
#
# healthcheck.sh — validate the plan-council / plan-lite planning system.
#
# Catches silent breakage (e.g. a Claude Code update that changes the workflow
# or skill format) before a live run hits it. Checks: workflow JS syntax, skill
# and role-agent frontmatter, helper/hook script syntax, and that the skill's
# referenced workflow path resolves. Exit 0 = all good, 1 = problems found.
#
# Run:  bash ~/.claude/skills/plan-council/healthcheck.sh

set -uo pipefail
D="${HOME}/.claude"
fail=0
ok(){ printf '  ok    %s\n' "$1"; }
bad(){ printf '  FAIL  %s\n' "$1"; fail=1; }

echo "== workflow engine (JS syntax) =="
for f in "$D"/skills/plan-council/*.workflow.js; do
  [ -e "$f" ] || { bad "no *.workflow.js found"; break; }
  if node --check "$f" 2>/dev/null; then ok "$(basename "$f")"; else bad "$(basename "$f") — syntax error"; fi
done

echo "== skills (frontmatter) =="
for s in plan-council plan-lite; do
  smd="$D/skills/$s/SKILL.md"
  if [ -f "$smd" ] && grep -q '^name:' "$smd" && grep -q '^description:' "$smd"; then ok "$s"; else bad "$s — missing SKILL.md or name/description"; fi
done

echo "== role agents (frontmatter) =="
n=0
for f in "$D"/agents/plan-*.md; do
  [ -e "$f" ] || { bad "no plan-*.md role agents found"; break; }
  n=$((n+1))
  if grep -q '^name:' "$f" && grep -q '^description:' "$f"; then ok "$(basename "$f")"; else bad "$(basename "$f") — missing name/description"; fi
done
[ "$n" -gt 0 ] && echo "  ($n role agents)"

echo "== helper / hook scripts (syntax) =="
for f in "$D"/skills/plan-council/post-discussion.sh "$D"/hooks/teammate-challenge-gate.sh; do
  if [ -f "$f" ] && bash -n "$f" 2>/dev/null; then ok "$(basename "$f")"; else bad "$(basename "$f") — missing or syntax error"; fi
done

echo "== skill -> workflow path resolves =="
ref=$(grep -o '/Users/[^"]*panel\.workflow\.js' "$D/skills/plan-council/SKILL.md" 2>/dev/null | head -1)
if [ -n "$ref" ] && [ -f "$ref" ]; then ok "scriptPath -> $ref"; else bad "SKILL.md scriptPath missing or broken: '${ref:-none}'"; fi

echo "== grilling gate (both planners open with a grill) =="
# The `grilling` skill must exist AND both planners must invoke it, and both must be
# allowed the Skill tool — an allowed-tools list without it makes the step impossible.
if [ -f "$D/skills/grilling/SKILL.md" ]; then ok "grilling skill present"; else bad "grilling skill missing — the framing gate cannot run"; fi
for s in plan-council plan-lite; do
  smd="$D/skills/$s/SKILL.md"
  if grep -q '`grilling` skill' "$smd" 2>/dev/null; then ok "$s invokes grilling"; else bad "$s — no grilling step in SKILL.md"; fi
  if awk '/^---$/{n++; next} n==1' "$smd" 2>/dev/null | grep -q '^allowed-tools:.*Skill'; then
    ok "$s allowed-tools includes Skill"
  else
    bad "$s — allowed-tools lacks Skill, so it cannot invoke grilling"
  fi
done

echo "== lessons audit (wired, and pointed at a real file) =="
# An audit against a missing or empty lessons file would report "clean" forever.
lessons="$D/LESSONS.md"
if [ -s "$lessons" ]; then
  n_lessons=$(grep -c '^\s*-\s*\*\*L[0-9]' "$lessons" 2>/dev/null || echo 0)
  if [ "$n_lessons" -gt 0 ]; then ok "LESSONS.md present ($n_lessons lessons)"; else bad "LESSONS.md has no L-numbered lessons — an audit against it is vacuous"; fi
else
  bad "LESSONS.md missing or empty — the lessons audit would pass on everything"
fi
wf="$D/skills/plan-council/panel.workflow.js"
lref=$(grep -o "LESSONS_PATH = '[^']*'" "$wf" 2>/dev/null | sed "s/.*'\(.*\)'/\1/")
if [ -n "$lref" ] && [ -f "$lref" ]; then ok "workflow LESSONS_PATH -> $lref"; else bad "panel.workflow.js LESSONS_PATH missing or broken: '${lref:-none}'"; fi
rref=$(grep -o "RULES_PATH = '[^']*'" "$wf" 2>/dev/null | sed "s/.*'\(.*\)'/\1/")
if [ -n "$rref" ] && [ -f "$rref" ]; then ok "workflow RULES_PATH -> $rref"; else bad "panel.workflow.js RULES_PATH missing or broken: '${rref:-none}'"; fi
if grep -q "title: 'Lessons audit'" "$wf" 2>/dev/null; then ok "workflow declares the Lessons audit phase"; else bad "panel.workflow.js — no 'Lessons audit' phase declared"; fi
# The audit is only a gate if its violations drive the fix loop; a phase that merely
# reports would leave a known-bad plan intact and still look present in the phase list.
if grep -q 'stillViolating()' "$wf" 2>/dev/null; then ok "lesson violations feed the fix loop"; else bad "panel.workflow.js — lessons audit is not wired into the fix-and-reverify loop"; fi
# The script has TWO exits (main path and revise mode) and each must carry the audit.
# Matching 'a return containing lessonsAudit' is not enough: the revise return satisfies
# it on its own, so the main return could lose the audit and this would stay green.
if grep -qE '^\s*return \{.*plan: finalPlan.*lessonsAudit' "$wf" 2>/dev/null; then ok "main path returns lessonsAudit"; else bad "panel.workflow.js — main return does not carry lessonsAudit"; fi
if grep -qE "^\s*return \{ mode: 'revise'.*lessonsAudit" "$wf" 2>/dev/null; then ok "revise mode returns lessonsAudit"; else bad "panel.workflow.js — revise return does not carry lessonsAudit"; fi
if grep -q 'lessonsAudit' "$D/skills/plan-council/SKILL.md" 2>/dev/null; then ok "plan-council reports lessonsAudit to the user"; else bad "plan-council SKILL.md — never reads lessonsAudit, so violations would be invisible"; fi
if grep -q 'LESSONS.md' "$D/skills/plan-lite/SKILL.md" 2>/dev/null; then ok "plan-lite runs a lessons audit"; else bad "plan-lite SKILL.md — no lessons audit step"; fi

echo
if [ "$fail" -eq 0 ]; then echo "ALL GOOD ✓"; else echo "PROBLEMS FOUND — see FAIL lines above"; fi
exit "$fail"
