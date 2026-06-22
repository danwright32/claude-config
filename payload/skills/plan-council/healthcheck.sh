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

echo
if [ "$fail" -eq 0 ]; then echo "ALL GOOD ✓"; else echo "PROBLEMS FOUND — see FAIL lines above"; fi
exit "$fail"
