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
#   issue-spool.sh key      <dir>            the project key <dir> belongs to
#   issue-spool.sh path     <dir>            the pending spool file for <dir>
#   issue-spool.sh append   <dir> <json>     append one record (used by the harvest)
#   issue-spool.sh raw      <dir>            the pending records, verbatim
#   issue-spool.sh pending  <dir>            pending FINDING lines; exit 1 if none
#   issue-spool.sh archive  <dir>            everything already filed
#   issue-spool.sh clear    <dir>            move pending into the archive
#
# The spool lives OUTSIDE ~/.claude on purpose. Anything under ~/.claude is
# auto committed and pushed to Dan's other Macs within seconds, and transcript
# derived notes are not config.
set -uo pipefail

SPOOL_ROOT="${CLAUDE_ISSUE_SPOOL_DIR:-$HOME/.claude-issue-spool}"

# The key must survive a worktree. An agent usually runs in .claude/worktrees/<x>,
# whose path hashes differently from the checkout the session reading the spool
# sits in, so keying on the raw directory would file every agent's findings under
# a project nobody ever opens. Normalise through git: a worktree and its main
# checkout share one common git dir.
issue_spool_key() {
  local dir="${1:-$PWD}" common root
  common="$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  if [ -n "$common" ] && [ -d "$common" ]; then
    root="$(dirname "$common")"
  else
    root="$dir"
  fi
  printf '%s' "$root" | shasum | cut -c1-12
}

issue_spool_path()    { printf '%s/%s.jsonl' "$SPOOL_ROOT" "$(issue_spool_key "${1:-$PWD}")"; }
issue_spool_archive() { printf '%s/%s.filed.jsonl' "$SPOOL_ROOT" "$(issue_spool_key "${1:-$PWD}")"; }

issue_spool_append() { # append <dir> <json-record>
  local file; file="$(issue_spool_path "$1")"
  mkdir -p "$SPOOL_ROOT" || return 1
  printf '%s\n' "$2" >> "$file"
}

# Pending findings, rendered for a person. Records that looked and found nothing
# are kept in the file (they are the evidence a harvest ran) but are not printed
# here, because there is nothing to act on. Records that FAILED are printed, and
# say so: a harvest that could not run is not a project with no findings.
issue_spool_pending() { # pending <dir>  -> exit 1 when there is nothing to show
  local file; file="$(issue_spool_path "$1")"
  [ -s "$file" ] || return 1
  python3 - "$file" <<'PY'
import json, sys

shown = 0
seen = set()
errors = {}
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    try:
        rec = json.loads(line)
    except Exception:
        continue
    where = rec.get("agent") or "subagent"
    if rec.get("status") == "found":
        for f in rec.get("findings") or []:
            if f in seen:
                continue
            seen.add(f)
            shown += 1
            print("FINDING (%s, %s): %s" % (where, rec.get("ts", "?"), f))
    elif rec.get("status") == "error":
        # Deduped by REASON, and counted. A recurring fault (a subagent kind that
        # leaves no transcript fires about once a minute, measured 2026-08-16)
        # otherwise appends a fresh record every time, the spool is never empty,
        # and a non-empty spool deliberately bypasses the review's cooldown: the
        # review would then fire every single turn carrying N copies of one line.
        reason = rec.get("error") or "no reason recorded"
        errors.setdefault(reason, {"count": 0, "agents": set(), "last": rec.get("ts", "?")})
        errors[reason]["count"] += 1
        errors[reason]["agents"].add(where)
        errors[reason]["last"] = rec.get("ts", "?")

for reason, info in errors.items():
    shown += 1
    times = "" if info["count"] == 1 else ", %d times" % info["count"]
    print("HARVEST FAILED (%s, last %s%s): %s. Nothing was read from those agents, so this "
          "is not the same as them finding nothing."
          % (", ".join(sorted(info["agents"])), info["last"], times, reason))

sys.exit(0 if shown else 1)
PY
}

# Filing RENAMES the pending file out of the way first, then drains the renamed
# copy into the archive. Copying and then truncating is two steps with no lock,
# and anything a finishing agent appends between them is destroyed: not
# archived, not shown, gone. Filing runs exactly when background agents are most
# likely to be finishing (right after the picker is answered), so that window is
# the normal case rather than a corner. After the rename an appender writes to a
# fresh file and cannot be caught by the drain at all.
issue_spool_clear() { # clear <dir>  -> file the pending records into the archive
  local file archive staged
  file="$(issue_spool_path "$1")"
  archive="$(issue_spool_archive "$1")"
  [ -s "$file" ] || return 0
  mkdir -p "$SPOOL_ROOT" || return 1
  staged="${file}.filing.$$"
  mv "$file" "$staged" 2>/dev/null || return 1

  # Test seam: the one instant that decides whether a concurrently arriving
  # record survives. Racing real processes proved nothing here, because the
  # window happened not to open (measured 2026-08-16, the broken version passed).
  [ -n "${CLAUDE_ISSUE_SPOOL_MIDCLEAR:-}" ] && eval "${CLAUDE_ISSUE_SPOOL_MIDCLEAR}"

  cat "$staged" >> "$archive" && rm -f "$staged"
}

# Direct invocation dispatch. Sourcing the file defines the functions and runs
# nothing, so the hooks can source it or shell out to it.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  cmd="${1:-}"
  shift || true
  case "$cmd" in
    key)     issue_spool_key "${1:-$PWD}" ;;
    path)    issue_spool_path "${1:-$PWD}" ;;
    append)  issue_spool_append "${1:-$PWD}" "${2:-}" ;;
    raw)     f="$(issue_spool_path "${1:-$PWD}")"; [ -s "$f" ] && cat "$f" ;;
    pending) issue_spool_pending "${1:-$PWD}" ;;
    archive) f="$(issue_spool_archive "${1:-$PWD}")"; [ -s "$f" ] && cat "$f" ;;
    clear)   issue_spool_clear "${1:-$PWD}" ;;
    *)       echo "issue-spool.sh: unknown command '${cmd}'" >&2; exit 2 ;;
  esac
fi
