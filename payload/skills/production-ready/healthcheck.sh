#!/usr/bin/env bash
# Validates the installed production-ready skill is well-formed. Run from anywhere.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail() { echo "HEALTHCHECK FAIL: $1" >&2; exit 1; }

# 1. SKILL.md exists with required frontmatter
SKILL="$DIR/SKILL.md"
[ -f "$SKILL" ] || fail "SKILL.md missing"
head -20 "$SKILL" | grep -q '^name: production-ready$' || fail "frontmatter missing 'name: production-ready'"
head -20 "$SKILL" | grep -q '^disable-model-invocation: true$' || fail "frontmatter missing disable-model-invocation"
head -20 "$SKILL" | grep -q '^allowed-tools:.*Workflow' || fail "frontmatter missing allowed-tools with Workflow"

# 2. Workflow script parses and declares meta.phases
WF="$DIR/production-audit.workflow.js"
[ -f "$WF" ] || fail "workflow script missing"
if command -v node >/dev/null 2>&1; then
  node --check "$WF" || fail "workflow script does not parse"
fi
grep -q 'phases:' "$WF" || fail "workflow meta missing phases"

# 3. SKILL.md body documents the key sections.
#    'gh issue create' is deliberately NOT required: an install with issue
#    filing turned off is a valid install.
for marker in "## 1." "Workflow" "production-audit.workflow.js" "AskUserQuestion"; do
  grep -qF "$marker" "$SKILL" || fail "SKILL.md missing section/marker: $marker"
done

# 4. No unsubstituted install placeholders survived.
if grep -q '@@' "$SKILL"; then fail "SKILL.md still contains an unsubstituted placeholder"; fi

# 5. The scriptPath the skill hands to the Workflow tool must actually resolve.
#    A stale absolute path here is silent: the skill reads fine and only fails
#    at run time, which is exactly how the original shipped broken.
WFPATH="$(grep -o 'scriptPath: "[^"]*"' "$SKILL" | head -1 | sed 's/scriptPath: "//; s/"$//')"
[ -n "$WFPATH" ] || fail "SKILL.md declares no scriptPath for the Workflow tool"
[ -f "$WFPATH" ] || fail "SKILL.md scriptPath does not exist on this machine: $WFPATH"

echo "HEALTHCHECK OK"
