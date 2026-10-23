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
# It runs on SessionStart too, where it says nothing and only records "what this
# session first saw" (claude-config#1544). That is the moment the session loads its
# rule files and names its mods; taken at the first prompt instead, the baseline
# already held whatever changed in between, so that change was never reported.
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
# MODS TOO, BUT ONLY THE SET OF THEM (claude-config#1535). A session names its mods once, at its
# start, from CLAUDE_CODE_PLUGIN_DIRS, so a mod that arrives on disk later is not loaded in it until
# a new session, and a mod removed from disk is still whatever the session made of it. That is the
# same shape as a rule file, so it is the same check over a second snapshot: the names of the mod
# folders that hold a manifest (a folder without one is not named by the sync either). A CHANGE to
# a mod the session already loaded is deliberately not reported: Claude Code reloads it in the
# running session and says so itself ("hooks.json changed, reloaded"), and says when a reload
# failed and the earlier version is still running. Reporting it here would repeat that line on every
# pull touching a mod and claim a staleness the reload has already cured (L11, L36). The names come
# from one glob, so this half starts no process at all however many mods there are.
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
[ -f "$RULES_DIR/CLAUDE.md" ] || [ -d "$RULES_DIR/mods" ] || exit 0

# Keyed on the session, so two sessions open at once each get their own baseline.
# With neither field there is no way to tell a first prompt from a later one, and
# guessing would either report every prompt as stale or never report at all, so
# the check says on stderr that it could not run rather than reporting silence as
# a clean answer (L98). stderr on a UserPromptSubmit hook is not shown to the
# person, which is why this is the one path that stays quiet to them.
#
# The same one python3 reads which event this is, so the start path costs no extra process. The
# fields are joined with the unit separator, never a tab: `read` folds a run of tabs into one, so an
# empty field in the middle would hand its neighbour's value to the wrong name.
fields="$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    d = {}
def one(v):
    return str(v or "").replace("\x1f", " ").replace("\n", " ")
print("\x1f".join(one(x) for x in (d.get("session_id") or d.get("transcript_path"),
                                   d.get("hook_event_name"))))
' 2>/dev/null || true)"
session="" event=""
IFS=$'\x1f' read -r session event <<< "$fields" || true
if [ -z "$session" ]; then
  echo "rule-files-changed: the hook payload carried neither a session id nor a transcript path, so a first prompt cannot be told from a later one and no comparison was made." >&2
  exit 0
fi

key="$(printf '%s' "$session" | shasum | cut -c1-12)"
STATE_DIR="${CLAUDE_RULES_STATE_DIR:-${TMPDIR:-/tmp}}"
mkdir -p "$STATE_DIR" 2>/dev/null || true
STATE="$STATE_DIR/claude-rule-files-${key}.state"
MODS_STATE="$STATE_DIR/claude-mods-${key}.state"

# ONE baseline rule for both snapshots, so the rule files and the mods cannot come to disagree about
# what a first prompt, an unreadable record or a repeated notice means (L370).
#
# since_baseline <state file> <snapshot function>: prints each line on one side only, as
# "gone<TAB><line>" or "new<TAB><line>", and nothing when the two agree. The snapshot is taken
# here, by name, so a start that keeps its record never pays for one.
#
# At SessionStart it only records, and only when there is no record yet (claude-config#1544). A
# session loads its rule files and names its mods when it starts, so that is the state to compare
# against; taken at the first prompt instead, a change in between was never reported. A start that
# finds a record keeps it: Claude Code runs SessionStart again on a resume or a compaction of the
# SAME session, and moving the baseline to what is on disk then would silence a change made before
# it. It never compares or speaks there either, so the change is said at the next prompt.
#
# No baseline yet at a prompt (a session started before this hook was wired, or whose start could
# not write), or one that cannot be read, re-seeds and stays quiet: reporting everything as changed
# because the record of what it used to be is missing would be a false alarm about the one subject
# this hook has to stay credible on (L36).
#
# The new state is recorded BEFORE anything is said, so a notice cannot repeat itself if anything
# after fails: the safe direction here is saying it once too few, not once per prompt for the rest
# of the session. ONE notice per divergence.
since_baseline() {
  local state="$1" current previous
  [ "$event" = "SessionStart" ] && [ -s "$state" ] && return 0
  current="$("$2")"
  [ -n "$current" ] || return 0
  [ "$event" = "SessionStart" ] && { printf '%s\n' "$current" > "$state" 2>/dev/null || true; return 0; }
  if [ ! -s "$state" ]; then
    printf '%s\n' "$current" > "$state" 2>/dev/null || true
    return 0
  fi
  previous="$(cat "$state" 2>/dev/null || true)"
  [ -n "$previous" ] || { printf '%s\n' "$current" > "$state" 2>/dev/null || true; return 0; }
  [ "$current" = "$previous" ] && return 0
  printf '%s\n' "$current" > "$state" 2>/dev/null || true
  comm -3 <(printf '%s\n' "$previous" | sort) <(printf '%s\n' "$current" | sort) 2>/dev/null \
    | awk -F '\t' '{ if ($1 != "") print "gone\t" $1; else print "new\t" $2 }'
}

# The imports, as bare names only. An absolute path, a tilde path or anything with
# a slash points outside the set a config sync carries, so it is not this hook's
# business (again, claude-sync's own rule for the same list).
rule_files() {
  local line target
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
#
# ONE shasum over every file present, never one per file (claude-config#603): this runs on every
# prompt, and the import list grows with every section the lessons index is split into.
snapshot() {
  local f h names present=() hashes
  names="$(rule_files | sort -u)"
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$RULES_DIR/$f" ] && present+=("$f")
  done <<< "$names"
  hashes=""
  [ "${#present[@]}" -gt 0 ] && hashes="$(cd "$RULES_DIR" && shasum -- "${present[@]}" 2>/dev/null)"
  # One awk joins the hashes back onto the names, in the names' order. shasum prints
  # "<hash>  <name>", so the name is everything after the first two spaces.
  {
    printf '%s\n' "$hashes" | sed 's/^/H /'
    [ "${#present[@]}" -gt 0 ] && printf 'P %s\n' "${present[@]}"
    printf '%s\n' "$names" | sed 's/^/N /'
  } | awk '
    /^H / { l = substr($0, 3); i = index(l, "  "); if (i) h[substr(l, i + 2)] = substr(l, 1, i - 1); next }
    /^P / { p[substr($0, 3)] = 1; next }
    /^N / { n = substr($0, 3); if (n == "") next
            v = (n in p) ? ((n in h) ? h[n] : "unreadable") : "absent"
            printf "%s  %s\n", v, n }'
}

# The mod folders that hold a manifest, by name, under a header line that never changes, so a Mac
# with no mods at all still takes a baseline and a first mod arriving later is reported.
mod_snapshot() {
  local m n
  [ -d "$RULES_DIR/mods" ] || return 0
  printf '#mods\n'
  for m in "$RULES_DIR"/mods/*/.claude-plugin/plugin.json; do
    [ -f "$m" ] || continue
    n="${m%/.claude-plugin/plugin.json}"
    printf '%s\n' "${n##*/}"
  done
}

# Joined with spaces without stripping them out afterwards: `case` rather than a substitution,
# superlinear in the number of matches under the bash macOS ships (claude-config#117).
words() { tr '\n' ' ' | sed 's/ $//'; }

# At a start there is nothing to say, only the record to take, and SessionStart's stdout would go
# into the session's context, so it goes no further than that.
if [ "$event" = "SessionStart" ]; then
  [ -f "$RULES_DIR/CLAUDE.md" ] && since_baseline "$STATE" snapshot
  since_baseline "$MODS_STATE" mod_snapshot
  exit 0
fi

if [ -f "$RULES_DIR/CLAUDE.md" ]; then
  # Lines on either side that the other does not have, which covers an edited file, one that
  # appeared, and one that went away. The name is the last field of a "<hash>  <name>" line.
  changed="$(since_baseline "$STATE" snapshot | awk '{print $NF}' | sort -u | words)"
  case "$changed" in *[![:space:]]*)
    echo "claude-sync: these rule files changed on disk after this session loaded them, so what is in this session's context is the older copy: ${changed}. Start a new session to pick them up, or read the changed file directly before relying on anything it says." ;;
  esac
fi

mods_diff="$(since_baseline "$MODS_STATE" mod_snapshot)"
added="$(printf '%s\n' "$mods_diff" | awk -F '\t' '$1 == "new" && $2 != "#mods" { print $2 }' | words)"
removed="$(printf '%s\n' "$mods_diff" | awk -F '\t' '$1 == "gone" && $2 != "#mods" { print $2 }' | words)"
case "$added" in *[![:space:]]*)
  echo "claude-sync: these mods arrived on disk after this session started, and this session has not loaded them: ${added}. A session names its mods when it starts, so a new session loads them; until then their tools, commands and hooks are not here." ;;
esac
case "$removed" in *[![:space:]]*)
  echo "claude-sync: these mods were removed from disk after this session started: ${removed}. A new session runs without them; this one may still be running what it loaded." ;;
esac
exit 0
