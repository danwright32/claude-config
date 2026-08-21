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
printf '%s\n' "$_fm" | grep -q '^name: production-ready$' || fail "frontmatter missing 'name: production-ready'"
printf '%s\n' "$_fm" | grep -q '^disable-model-invocation: true$' || fail "frontmatter missing disable-model-invocation"
printf '%s\n' "$_fm" | grep -q '^allowed-tools:.*Workflow' || fail "frontmatter missing allowed-tools with Workflow"

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
# The installed SKILL.md carries a real absolute path, because the config sync rewrites the home
# directory in every synced file on the way in. A copy that has not been through an apply (the
# repo's own, or one edited by hand) still holds the token, so expand it here rather than
# reporting a file that does not exist.
# The token is ASSEMBLED, never written whole. The sync expands it in every mirrored
# file on the way in, and it cannot tell a line that means the token from a line that
# means a path: written out, this very line came back as
# ${WFPATH//Users/<name>/.claude/...} and the healthcheck reported a path made of two
# homes glued together (claude-config#99).
_CS_TOKEN="__CLAUDE""_HOME__"
WFPATH="${WFPATH/$_CS_TOKEN/${CLAUDE_HOME:-$HOME/.claude}}"
[ -n "$WFPATH" ] || fail "SKILL.md declares no scriptPath for the Workflow tool"
[ -f "$WFPATH" ] || fail "SKILL.md scriptPath does not exist on this machine: $WFPATH"

echo "HEALTHCHECK OK"
