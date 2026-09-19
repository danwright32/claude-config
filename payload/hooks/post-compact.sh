#!/usr/bin/env bash
# Re-inject the project's CLAUDE.md after context compaction, as SessionStart additional context.
#
# When this works, a compacted session keeps its project rules. When it does not, the session
# carries on with NO rules and nothing anywhere says so, which is the whole reason it has to be
# hard to break.
#
# It was registered under PostCompact until 2026-09-19 and had never once delivered anything
# (claude-config#478). Two reasons, both silent:
#
#   * it named no event, and Claude Code refuses a whole hook payload whose hookSpecificOutput
#     carries no hookEventName, which is what "Hook JSON output validation failed" was saying;
#   * PostCompact has no channel for context in any case. Read out of the installed binary
#     (strings on version 2.1.278, 2026-09-19): the accepted output union has no PostCompact
#     member at all, and the runner that fires those hooks keeps only a line to show the person,
#     "PostCompact [command] completed successfully: ...", which nothing hands to the model.
#
# What the same binary does after a compaction is run the SessionStart hooks with source
# "compact" and append what they return to the rebuilt transcript, so SessionStart is the event
# this hook belongs to and the name it prints. The tree wide version of the question lives in
# lib/hook-output.py, so the next hook printing a shape the platform refuses fails the suite
# instead of going quiet (L30, L613).
#
# Only a compaction, never any other SessionStart: Claude Code loads the project rules itself when
# a session starts, and this hook's sentence says a compaction is why it is speaking, which would
# be untrue on a startup or a resume (L680).
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

# A source this hook has nothing to say about. A missing source is still answered, because a
# payload that does not carry one has not said the session started any other way, and going quiet
# on it would be a silence nobody could tell from a failure (L11).
source = data.get("source")
if source is not None and source != "compact":
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

print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": context}}))
PY
