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
        shown += 1
        print("HARVEST FAILED (%s, %s): %s. Nothing was read from that agent, so this is "
              "not the same as it finding nothing."
              % (where, rec.get("ts", "?"), rec.get("error") or "no reason recorded"))

sys.exit(0 if shown else 1)
PY
}

issue_spool_clear() { # clear <dir>  -> file the pending records into the archive
  local file archive
  file="$(issue_spool_path "$1")"
  archive="$(issue_spool_archive "$1")"
  [ -s "$file" ] || return 0
  mkdir -p "$SPOOL_ROOT" || return 1
  cat "$file" >> "$archive" && : > "$file"
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
