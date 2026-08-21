#!/usr/bin/env bash
# Re-inject the project's CLAUDE.md after context compaction, via hookSpecificOutput.
#
# When this works, a compacted session keeps its project rules. When it does not, the session
# carries on with NO rules and nothing anywhere says so, which is the whole reason it has to be
# hard to break.
#
# Values reach python through the ENVIRONMENT, never by being pasted into its source. The first
# version built the program text with the project name inside a single quoted python string, so a
# directory whose name contains a quote (Dan's Projects, and every folder like it) produced a
# syntax error, printed nothing at all, and the session silently lost its rules: the exact failure
# this hook exists to prevent, arriving as silence (claude-config#124).
set -uo pipefail

input=$(cat)

CC_POST_COMPACT_INPUT="$input" python3 <<'PY'
import json, os, sys

try:
    data = json.loads(os.environ.get("CC_POST_COMPACT_INPUT", "") or "{}")
except Exception:
    sys.exit(0)

cwd = data.get("cwd") or ""
if not cwd:
    sys.exit(0)

project = os.path.basename(cwd.rstrip("/")) or cwd
path = os.path.join(cwd, "CLAUDE.md")

try:
    with open(path, "r", encoding="utf-8") as fh:
        content = fh.read()
except Exception:
    content = None

if content is None:
    # Its own sentence, not a quieter version of the one above. "There were no rules to re-inject"
    # and "the rules are below" are different facts, and a session that cannot tell them apart
    # cannot tell a project with no CLAUDE.md from a hook that failed (L11).
    context = ("Context was compacted. Project: %s. No CLAUDE.md was found in that directory, "
               "so there are no project rules to restore. Proceed with care." % project)
else:
    context = ("Context was compacted. Project: %s. CLAUDE.md contents:\n%s" % (project, content))

print(json.dumps({"hookSpecificOutput": {"additionalContext": context}}))
PY
