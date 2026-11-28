#!/usr/bin/env bash
# rerun-resolve.sh <project folder> [session transcript]: the end of turn review's half of the hand
# rerun record (claude-config#3613). issue-spool.sh rerun writes each hand rerun; this reads each
# waiting rerun's run from GitHub and spools a finding for a repeat flake or a job that failed again,
# drops one unreadable for its keep days (printing one line per dropped run on stdout), and keeps the
# flake history to its window.
#
# A script of its own, not a subcommand of issue-spool.sh, because it runs gh from Python, and the
# Slack drafts gate reads the whole of issue-spool.sh whenever a session runs any of its subcommands
# (the clear line every review hands out): code there that can start a program is refused, so every
# clear would be. Only feature-issue-review.sh, a Stop hook, runs this.
set -uo pipefail

_RR_LIB="${BASH_SOURCE[0]%/*}"; [ "$_RR_LIB" != "${BASH_SOURCE[0]}" ] || _RR_LIB=.
. "$_RR_LIB/issue-spool.sh" || { echo "rerun-resolve: lib/issue-spool.sh could not be loaded, so no hand rerun was read." >&2; exit 1; }

# The review's half: read each waiting rerun's run from GitHub, one call a run (a rerun named only by
# its job takes one more, once, to learn its run), inside a time budget the Stop hook's own limit
# leaves room for. A run still going, one not yet showing the rerun's attempt, and one whose result
# cannot be read (no answer in time, a repository this Mac's gh cannot read, output that is not the
# jobs list) are put back to wait for the next review, never offered. Newest first, so one that can
# never be read does not hold up the rest. One this review tried and could not read, first recorded
# CLAUDE_RERUN_UNREAD_KEEP_DAYS (7) or more days ago, is dropped instead, and one line per dropped run
# goes to STDOUT, which the review always says (it makes the review speak); one never tried this turn
# for lack of time is not dropped, and one with no readable date is never aged, kept and said.
#
# Claimed by RENAME before it is read, as a clear does, so a rerun recorded meanwhile lands in a new
# file, and two reviews cannot both resolve one run. A claim whose process died is taken back first.
rerun_resolve() { # <dir> [session-transcript]
  local dir="${1:-$PWD}" transcript="${2:-}" key wait claim c pid out rc failed="" line
  local _rr_unread_days _rr_flake_days _rr_now
  if [ -n "${CLAUDE_SUITE_RUN_ID:-}" ] && [ "$(issue_spool_root)" = "${HOME%/}/.claude-issue-spool" ]; then
    echo "issue-spool: refusing to resolve reruns in the real spool at $(issue_spool_root): this is running under a test suite (CLAUDE_SUITE_RUN_ID=$CLAUDE_SUITE_RUN_ID)." >&2
    return 3
  fi
  issue_spool_rerun_limits
  key="$(issue_spool_key "$dir" "$transcript")" || return
  wait="$(issue_spool_reruns_dir)/$key.jsonl"
  for c in "$wait".resolving.*; do
    [ -f "$c" ] || continue
    pid="${c##*.}"
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    kill -0 "$pid" 2>/dev/null && continue
    cat "$c" >> "$wait" 2>/dev/null && rm -f "$c"
  done
  [ -s "$wait" ] || return 0
  claim="$wait.resolving.$$"
  if ! mv "$wait" "$claim" 2>/dev/null; then
    [ -e "$wait" ] || return 0   # another review took it in the instant between
    echo "issue-spool: could not move $wait aside to resolve it, so no hand rerun was read this turn; they wait for the next." >&2
    return 1
  fi
  out="$(mktemp -d "${TMPDIR:-/tmp}/claude-reruns.XXXXXX")" || { cat "$claim" >> "$wait" 2>/dev/null && rm -f "$claim"; return 1; }
  python3 "$_RR_LIB/rerun-resolve.py" resolve "$claim" "$(issue_spool_reruns_dir)/flakes.jsonl" "$out" "$_rr_now" "$_rr_unread_days" "$_rr_flake_days"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    cat "$claim" >> "$wait" 2>/dev/null && rm -f "$claim"
    rm -rf "$out"
    echo "issue-spool: reading the waiting hand reruns failed (python3 exit $rc); they wait for the next review." >&2
    return 1
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    issue_spool_append "$dir" "$line" "$transcript" || { failed=yes; break; }
  done < "$out/findings.jsonl"
  if [ -n "$failed" ]; then
    # Nothing is counted as seen and nothing is dropped: every rerun goes back to wait, so the next
    # review offers or drops it, and says so then.
    cat "$out/resolved.jsonl" "$out/keep.jsonl" "$out/dropped.jsonl" >> "$wait" 2>/dev/null && rm -f "$claim"
    rm -rf "$out"
    echo "issue-spool: a finding from a resolved hand rerun could not be written to the spool, so the reruns wait for the next review." >&2
    return 1
  fi
  # The new flakes are added and lines past the flake window removed in one step, under the
  # history's lock (see commit in lib/rerun-resolve.py).
  python3 "$_RR_LIB/rerun-resolve.py" commit "$(issue_spool_reruns_dir)/flakes.jsonl" "$out/history.jsonl" "$_rr_now" "$_rr_flake_days" || failed=yes
  if [ -s "$out/keep.jsonl" ] && ! cat "$out/keep.jsonl" >> "$wait" 2>/dev/null; then
    echo "issue-spool: the hand reruns still waiting could not be put back in $wait; they are left in $claim." >&2
    rm -rf "$out"
    return 1
  fi
  # Each dropped run, one line, on stdout: the review says these, and speaks because of them.
  cat "$out/dropped.txt" 2>/dev/null
  rm -f "$claim"
  rm -rf "$out"
  [ -z "$failed" ]
}

rerun_resolve "${1:-$PWD}" "${2:-}"
