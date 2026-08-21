#!/usr/bin/env bash
#
# rule-files-changed.sh: say when this session's rule files have changed on disk
# since it started (claude-config#84).
#
# A pull that changes the rule files prints one line telling the person to start a
# new session, and that line is the only defence. A session already running keeps
# the copy it loaded at startup, and nothing after that moment repeats it. On
# 2026-08-18 this happened inside the very session that ran the pull: two new
# lessons were on disk and in the shared repo, and the session went on working
# against the older index for the rest of its turn. This is the shape of L175, a
# value read once at startup describing something that lives outside the program,
# with no action inside the program to hang a re-read on.
#
# So this runs on UserPromptSubmit, which IS an action inside the program, and
# compares a hash of each rule file against the hash this session first saw. It
# cannot reload anything (only a new session picks these up), but it can stop the
# staleness being silent.
#
# ONE notice per divergence, not one per prompt: after speaking it records the new
# state, so the next prompt is quiet until something changes again. A notice on
# every prompt would be the noise it exists to prevent.
#
# WHICH files: CLAUDE.md and the files it imports with a leading @name line,
# derived from the file itself rather than listed here, so a new import is covered
# with no edit (the same rule claude-sync's own top_files_in follows, L41). Only
# the global rule files under the config directory: a project's own CLAUDE.md is
# not what a config sync changes underneath a session.
#
# Env:
#   CLAUDE_RULES_DIR        the config directory to read (default ~/.claude)
#   CLAUDE_RULES_STATE_DIR  where the per session hashes are kept (default TMPDIR).
#                           A DIRECTORY rather than a file, so a caller giving it a
#                           throwaway location still gets one record per session:
#                           pointed at a single file, two sessions would overwrite
#                           each other's baseline and each would be told about the
#                           other's changes.
set -uo pipefail

input="$(cat 2>/dev/null || true)"

RULES_DIR="${CLAUDE_RULES_DIR:-$HOME/.claude}"
[ -d "$RULES_DIR" ] || exit 0
[ -f "$RULES_DIR/CLAUDE.md" ] || exit 0

# Keyed on the session, so two sessions open at once each get their own baseline.
# With neither field there is no way to tell a first prompt from a later one, and
# guessing would either report every prompt as stale or never report at all, so
# the check says on stderr that it could not run rather than reporting silence as
# a clean answer (L98). stderr on a UserPromptSubmit hook is not shown to the
# person, which is why this is the one path that stays quiet to them.
session="$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    d = {}
print(d.get("session_id") or d.get("transcript_path") or "")
' 2>/dev/null || true)"
if [ -z "$session" ]; then
  echo "rule-files-changed: the hook payload carried neither a session id nor a transcript path, so a first prompt cannot be told from a later one and no comparison was made." >&2
  exit 0
fi

key="$(printf '%s' "$session" | shasum | cut -c1-12)"
STATE_DIR="${CLAUDE_RULES_STATE_DIR:-${TMPDIR:-/tmp}}"
mkdir -p "$STATE_DIR" 2>/dev/null || true
STATE="$STATE_DIR/claude-rule-files-${key}.state"

# The imports, as bare names only. An absolute path, a tilde path or anything with
# a slash points outside the set a config sync carries, so it is not this hook's
# business (again, claude-sync's own rule for the same list).
rule_files() {
  printf 'CLAUDE.md\n'
  while IFS= read -r line; do
    case "$line" in '@'?*) ;; *) continue ;; esac
    target="${line#@}"
    target="${target%%[[:space:]]*}"
    case "$target" in ''|/*|'~'*|*/*) continue ;; esac
    printf '%s\n' "$target"
  done < "$RULES_DIR/CLAUDE.md"
}

# "<hash>  <name>" per file, sorted by name so two readings can be compared line
# by line. A file named as an import but missing is recorded as missing rather
# than skipped: it appearing or disappearing is exactly the kind of change worth
# reporting, and skipping it would make the two states read the same.
snapshot() {
  local f h
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ -f "$RULES_DIR/$f" ]; then
      h="$(shasum "$RULES_DIR/$f" 2>/dev/null | cut -d' ' -f1)"
    else
      h="absent"
    fi
    printf '%s  %s\n' "${h:-unreadable}" "$f"
  done < <(rule_files | sort -u)
}

current="$(snapshot)"
[ -n "$current" ] || exit 0

# No baseline yet (the first prompt of this session), or one that cannot be read.
# Both re-seed and stay quiet: reporting every file as changed because the record
# of what they used to be is missing would be a false alarm about the one subject
# this hook has to stay credible on (L36).
if [ ! -s "$STATE" ]; then
  printf '%s\n' "$current" > "$STATE" 2>/dev/null || true
  exit 0
fi

previous="$(cat "$STATE" 2>/dev/null || true)"
[ -n "$previous" ] || { printf '%s\n' "$current" > "$STATE" 2>/dev/null || true; exit 0; }
[ "$current" = "$previous" ] && exit 0

# Lines on either side that the other does not have, which covers an edited file,
# one that appeared, and one that went away.
changed="$(comm -3 <(printf '%s\n' "$previous") <(printf '%s\n' "$current") 2>/dev/null \
           | awk '{print $NF}' | sort -u | tr '\n' ' ')"
changed="${changed% }"

# Recorded BEFORE speaking, so a notice cannot repeat itself if anything below
# fails: the safe direction here is saying it once too few, not once per prompt
# for the rest of the session.
printf '%s\n' "$current" > "$STATE" 2>/dev/null || true

[ -n "${changed// }" ] || exit 0
echo "claude-sync: these rule files changed on disk after this session loaded them, so what is in this session's context is the older copy: ${changed}. Start a new session to pick them up, or read the changed file directly before relying on anything it says."
exit 0
