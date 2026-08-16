#!/usr/bin/env bash
#
# issue-spool.sh — the durable holding place for issue candidates found by
# subagents, and the ONE definition of the spool's shape.
#
# Why a spool at all. The end of turn issue review is a Stop hook: it fires when
# the MAIN session stops, on a 30 minute per project cooldown, reading the main
# transcript. None of that reaches a subagent. A batch of agents working in
# parallel therefore produced observations that were never offered to anyone,
# and a review suppressed by the cooldown lost whatever that turn found.
#
# So findings are written down the moment an agent finishes, and they stay
# written down until they are FILED. Reading them does not consume them: a
# review that is read and then interrupted has to leave the finding behind for
# the next one. Losing a finding twice over is the failure this exists to stop.
#
# Every consumer goes through this file (the harvest that writes, the review
# that reads, the clear that files) so the format cannot drift between them.
#
# Usage:
#   issue-spool.sh key          <dir>          the project key <dir> belongs to
#   issue-spool.sh path         <dir>          the pending spool file for <dir>
#   issue-spool.sh archive-path <dir>          the archive file for <dir>
#   issue-spool.sh append       <dir> <json>   append one record; non-zero if refused
#   issue-spool.sh raw          <dir>          the pending records, verbatim
#   issue-spool.sh pending      <dir>          what a person should read; exit 1 if nothing
#   issue-spool.sh has-findings <dir>          exit 0 only if a real finding is pending
#   issue-spool.sh archive      <dir>          everything already filed
#   issue-spool.sh clear        <dir>          move pending into the archive
#
# `raw` and `archive` exit 0 on an empty spool. They used to exit non-zero,
# which kills any caller running under errexit on the ordinary empty case, and
# that behaviour was documented for `pending` only.
#
# The spool lives OUTSIDE ~/.claude on purpose. Anything under ~/.claude is
# auto committed and pushed to Dan's other Macs within seconds, and transcript
# derived notes are not config.
set -uo pipefail

SPOOL_ROOT="${CLAUDE_ISSUE_SPOOL_DIR:-$HOME/.claude-issue-spool}"

# How many records the archive keeps. It is only history, and nothing reads it
# automatically, but left uncapped it grows for as long as the machine lives.
ARCHIVE_MAX_RECORDS="${CLAUDE_ISSUE_SPOOL_ARCHIVE_MAX:-5000}"

# The key must survive a worktree. An agent usually runs in .claude/worktrees/<x>,
# whose path hashes differently from the checkout the session reading the spool
# sits in, so keying on the raw directory would file every agent's findings under
# a project nobody ever opens. Normalise through git: a worktree and its main
# checkout share one common git dir. The result is then resolved to its physical
# path, because /tmp and /private/tmp are the same directory on macOS and the
# writer and the reader do not always arrive by the same route.
issue_spool_key() {
  local dir="${1:-$PWD}" common root
  common="$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  if [ -n "$common" ] && [ -d "$common" ]; then
    root="$(dirname "$common")"
  else
    root="$dir"
  fi
  root="$(cd "$root" 2>/dev/null && pwd -P || printf '%s' "$root")"
  printf '%s' "$root" | shasum | cut -c1-12
}

issue_spool_path()         { printf '%s/%s.jsonl' "$SPOOL_ROOT" "$(issue_spool_key "${1:-$PWD}")"; }
issue_spool_archive_path() { printf '%s/%s.filed.jsonl' "$SPOOL_ROOT" "$(issue_spool_key "${1:-$PWD}")"; }

# A record is one line of JSON. Anything else breaks the one-record-per-line
# invariant every reader depends on, and a broken line is then dropped by the
# reader, so a bad caller would corrupt the spool and see no complaint. Refusing
# here means the caller can fall back to somewhere the record still survives.
issue_spool_append() { # append <dir> <json-record>
  local file record; file="$(issue_spool_path "$1")"; record="${2:-}"
  [ -n "$record" ] || return 2
  case "$record" in *$'\n'*) return 2 ;; esac
  printf '%s' "$record" | python3 -c 'import json,sys; json.loads(sys.stdin.read())' 2>/dev/null || return 2
  mkdir -p "$SPOOL_ROOT" 2>/dev/null || return 1
  printf '%s\n' "$record" >> "$file" 2>/dev/null || return 1
}

# What a person should read. Records that looked and found nothing are kept in
# the file (they are the evidence a harvest ran) but are not printed, because
# there is nothing to act on. Everything else is printed and says which it is: a
# harvest that could not run is not a project with no findings, and neither is a
# reply nobody could parse.
issue_spool_pending() { # pending <dir>  -> exit 1 when there is nothing to show
  local file; file="$(issue_spool_path "$1")"
  [ -s "$file" ] || return 1
  python3 - "$file" <<'PY'
import json, sys

MAX_FINDINGS = 200

shown = 0
seen = set()
errors = {}
unparsed = []
corrupt = 0
findings = []

for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line:
        continue
    try:
        rec = json.loads(line)
    except Exception:
        corrupt += 1          # counted, never silently skipped
        continue
    if not isinstance(rec, dict):
        corrupt += 1
        continue
    where = rec.get("agent") or "subagent"
    status = rec.get("status")
    if status == "found":
        for f in rec.get("findings") or []:
            if f in seen:
                continue
            seen.add(f)
            findings.append((where, rec.get("ts", "?"), f))
    elif status == "error":
        # Deduped by REASON, and counted. A recurring fault (a subagent kind that
        # leaves no transcript fires every few minutes, measured 2026-08-16)
        # otherwise appends a fresh record every time, the spool is never empty,
        # and the review would carry N copies of one line.
        reason = rec.get("error") or "no reason recorded"
        e = errors.setdefault(reason, {"count": 0, "agents": set(), "last": "?"})
        e["count"] += 1
        e["agents"].add(where)
        e["last"] = rec.get("ts", "?")
    elif status == "unparsed":
        unparsed.append((where, rec.get("ts", "?"), (rec.get("raw") or "")[:400]))

for where, ts, f in findings[:MAX_FINDINGS]:
    shown += 1
    print("FINDING (%s, %s): %s" % (where, ts, f))
if len(findings) > MAX_FINDINGS:
    shown += 1
    print("...and %d more findings not shown here. They stay in the spool until filed."
          % (len(findings) - MAX_FINDINGS))

for reason, info in errors.items():
    shown += 1
    times = "" if info["count"] == 1 else ", %d times" % info["count"]
    print("HARVEST FAILED (%s, last %s%s): %s. Nothing was read from those agents, so this "
          "is not the same as them finding nothing."
          % (", ".join(sorted(info["agents"])), info["last"], times, reason))

for where, ts, raw in unparsed:
    shown += 1
    print("REPLY COULD NOT BE READ (%s, %s): the harvest model answered in a shape this code "
          "could not parse, so anything it found was not captured. Its words were: %s"
          % (where, ts, raw))

if corrupt:
    shown += 1
    print("UNREADABLE SPOOL RECORDS: %d line(s) in the spool are not valid records and were "
          "skipped. Something wrote to it that should not have." % corrupt)

sys.exit(0 if shown else 1)
PY
}

# Does the spool hold an actual FINDING, as opposed to only records of harvests
# that failed or looked and found nothing? The review bypasses its cooldown on
# this answer alone: a recurring failure keeps the spool permanently non-empty,
# and interrupting every turn over it would train the review to be ignored.
issue_spool_has_findings() { # has-findings <dir> -> exit 0 when a finding is pending
  local file; file="$(issue_spool_path "$1")"
  [ -s "$file" ] || return 1
  python3 - "$file" <<'PY_HF'
import json, sys
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line:
        continue
    try:
        rec = json.loads(line)
    except Exception:
        continue
    if isinstance(rec, dict) and rec.get("status") == "found" and (rec.get("findings") or []):
        sys.exit(0)
sys.exit(1)
PY_HF
}

# Filing RENAMES the pending file out of the way first, then drains the renamed
# copy into the archive. Copying and then truncating is two steps with no lock,
# and anything a finishing agent appends between them is destroyed: not
# archived, not shown, gone. Filing runs exactly when background agents are most
# likely to be finishing (right after the picker is answered), so that window is
# the normal case rather than a corner. After the rename an appender writes to a
# fresh file and cannot be caught by the drain at all.
issue_spool_clear() { # clear <dir>  -> file the pending records into the archive
  local file archive staged count
  file="$(issue_spool_path "$1")"
  archive="$(issue_spool_archive_path "$1")"
  [ -s "$file" ] || return 0
  mkdir -p "$SPOOL_ROOT" 2>/dev/null || return 1
  staged="${file}.filing.$$"
  mv "$file" "$staged" 2>/dev/null || return 1

  # Test seam: the one instant that decides whether a concurrently arriving
  # record survives. Racing real processes proved nothing here, because the
  # window happened not to open (measured 2026-08-16, the broken version passed).
  [ -n "${CLAUDE_ISSUE_SPOOL_MIDCLEAR:-}" ] && eval "${CLAUDE_ISSUE_SPOOL_MIDCLEAR}"

  cat "$staged" >> "$archive" 2>/dev/null && rm -f "$staged"

  # Cap the archive. It is history that nothing reads automatically, so the only
  # thing unbounded growth buys is a file that eventually matters.
  if [ -f "$archive" ]; then
    count="$(wc -l < "$archive" 2>/dev/null | tr -d ' ')"
    if [ -n "$count" ] && [ "$count" -gt "$ARCHIVE_MAX_RECORDS" ]; then
      tail -n "$ARCHIVE_MAX_RECORDS" "$archive" > "${archive}.trimmed" 2>/dev/null \
        && mv "${archive}.trimmed" "$archive"
    fi
  fi
}

# Direct invocation dispatch. Sourcing the file defines the functions and runs
# nothing, so the hooks can source it or shell out to it.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  cmd="${1:-}"
  shift || true
  case "$cmd" in
    key)          issue_spool_key "${1:-$PWD}" ;;
    path)         issue_spool_path "${1:-$PWD}" ;;
    archive-path) issue_spool_archive_path "${1:-$PWD}" ;;
    append)       issue_spool_append "${1:-$PWD}" "${2:-}" ;;
    raw)          f="$(issue_spool_path "${1:-$PWD}")"; [ -s "$f" ] && cat "$f" ;;
    pending)      issue_spool_pending "${1:-$PWD}" ;;
    has-findings) issue_spool_has_findings "${1:-$PWD}" ;;
    archive)      f="$(issue_spool_archive_path "${1:-$PWD}")"; [ -s "$f" ] && cat "$f"; exit 0 ;;
    clear)        issue_spool_clear "${1:-$PWD}" ;;
    *)            echo "issue-spool.sh: unknown command '${cmd}'" >&2; exit 2 ;;
  esac
fi
