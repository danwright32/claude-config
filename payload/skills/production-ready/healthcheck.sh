#!/usr/bin/env bash
# Validates the installed production-ready skill is well-formed. Run from anywhere.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail() { echo "HEALTHCHECK FAIL: $1" >&2; exit 1; }

# 1. SKILL.md exists with required frontmatter
SKILL="$DIR/SKILL.md"
[ -f "$SKILL" ] || fail "SKILL.md missing"
# The frontmatter is read ONCE and matched against a variable. `head -20 file | grep -q ...` is a
# pipeline whose consumer short circuits: grep -q exits on its first match, head is killed by
# SIGPIPE, and under `pipefail` the pipeline's status becomes that death, so the check can report
# missing frontmatter that is plainly there (L183).
_fm="$(head -20 "$SKILL" 2>/dev/null || true)"
grep -q '^name: production-ready$' <<< "$_fm" || fail "frontmatter missing 'name: production-ready'"
grep -q '^disable-model-invocation: true$' <<< "$_fm" || fail "frontmatter missing disable-model-invocation"
grep -q '^allowed-tools:.*Workflow' <<< "$_fm" || fail "frontmatter missing allowed-tools with Workflow"

# 2. Workflow script parses and declares meta.phases
WF="$DIR/production-audit.workflow.js"
[ -f "$WF" ] || fail "workflow script missing"
# Parsed as the Workflow engine runs it, an async function body, never as a file: `node --check`
# reads its `export const meta` as an ES module, where the script's top level return is a syntax
# error, and so failed a healthy script on CI's node (#587, PR #798).
if command -v node >/dev/null 2>&1; then
  node "$DIR/../../hooks/lib/workflow-syntax.js" "$WF" || fail "workflow script does not parse"
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

# 5. The launch the skill describes must actually work (claude-config#587).
#    The Workflow tool refuses a scriptPath under the config home, so the skill copies its script
#    into the session scratchpad with hooks/lib/stage-workflow.sh and passes the copy. A SKILL.md
#    that hands the tool its installed path reads fine and fails every run, which is how this
#    skill first shipped, so both halves are checked: the instruction, and the helper doing it.
grep -q "stage-workflow\.sh.*skills/production-ready/production-audit\.workflow\.js" "$SKILL" \
  || fail "SKILL.md does not stage production-audit.workflow.js through hooks/lib/stage-workflow.sh"
if grep -Eq 'scriptPath: *"(__CLAUDE|~|\$HOME|/Users/)' "$SKILL"; then
  fail "SKILL.md hands the Workflow tool a scriptPath inside the config home, which the tool refuses"
fi
STAGE="$DIR/../../hooks/lib/stage-workflow.sh"
[ -f "$STAGE" ] || fail "hooks/lib/stage-workflow.sh is missing, so the skill cannot stage its workflow"
_hc_tmp="$(mktemp -d)"
_staged="$(bash "$STAGE" "$WF" "$_hc_tmp" 2>&1)" || { rm -rf "$_hc_tmp"; fail "stage-workflow.sh refused a fresh scratchpad: $_staged"; }
cmp -s "$WF" "$_staged" || { rm -rf "$_hc_tmp"; fail "stage-workflow.sh printed a path that is not an exact copy: $_staged"; }
rm -rf "$_hc_tmp"

echo "HEALTHCHECK OK"
