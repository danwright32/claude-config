#!/usr/bin/env bash
#
# local-allow-sweep.sh: SessionStart hook. Reads the project's .claude/settings.local.json allow
# rules, and says once when any is a one off rule or holds a key or token, with a picker to remove
# them on Dan's answer (claude-config#1582). It removes nothing itself.
#
# Every allow rule saved by "Yes, don't ask again" lands in that file, out of git and read by nothing
# we own, so one off grep, rg, ls and curl rules piled up into a warning at every session start, and
# Bidspoke's held a live token in plain text. Dan chose "Sweep and report" on 2026-10-23.
#
# All the judging, the once per set record and the removal live in lib/local-allow-rules.py, whose
# header says what is flagged and why nothing of a rule's text is ever printed. This file only decides
# whether there is anything to read.
#
# COST. A project with no local settings file costs one test of a path and no process at all. With a
# file: python3 reads it once, and runs the one redactor (bash and sed) once over all its rules
# together, however many there are; the said record is read only when something is flagged. Measured
# in test-per-prompt-hook-cost.sh.
#
# A detached headless run (CLAUDE_DETACHED_RUN) has nobody to tell, and saying it there would record
# it as said. Never blocks: every path exits 0. stdout on exit 0 is added to the session's context.
[ -n "${CLAUDE_DETACHED_RUN:-}" ] && exit 0

DIR="${BASH_SOURCE[0]%/*}"; [ "$DIR" != "${BASH_SOURCE[0]}" ] || DIR=.
PROJECT="${CLAUDE_PROJECT_DIR:-$PWD}"
FILE="$PROJECT/.claude/settings.local.json"
{ [ -e "$FILE" ] || [ -L "$FILE" ]; } || exit 0

if ! command -v python3 >/dev/null 2>&1; then
  echo "local-allow-sweep: python3 is not on PATH, so the allow rules in $FILE were not checked for one off rules or keys (claude-config#1582). Tell Dan."
  exit 0
fi
python3 "$DIR/lib/local-allow-rules.py" sweep --file "$FILE" --project "$PROJECT" || \
  echo "local-allow-sweep: the check of the allow rules in $FILE failed (exit $?), so they were not checked (claude-config#1582). Nothing was changed. Tell Dan."
exit 0
