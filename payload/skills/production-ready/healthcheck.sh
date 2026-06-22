#!/usr/bin/env bash
# Validates the production-ready skill is well-formed. Run from anywhere.
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
node --check "$WF" || fail "workflow script does not parse"
grep -q 'phases:' "$WF" || fail "workflow meta missing phases"

# 3. SKILL.md body documents the key sections
for marker in "## 1." "Workflow" "production-audit.workflow.js" "AskUserQuestion" "gh issue create"; do
  grep -qF "$marker" "$SKILL" || fail "SKILL.md missing section/marker: $marker"
done

echo "HEALTHCHECK OK"
