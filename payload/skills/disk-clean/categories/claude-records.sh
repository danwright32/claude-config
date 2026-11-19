#!/usr/bin/env bash
#
# claude-records.sh: disk-clean's Claude Code records category (claude-config#3235). See scan-lib.sh
# for the module calls.
# offers: nothing
#
# Shows, sized, what Claude Code and this config keep about their own work, so the review page says
# where that space is. It never offers anything: each row says why, and its judge refuses every
# path. Read from the code that writes each one, 2026-11-18:
#   ~/.claude/state/<entry>      state hooks and sessions read as they run, disk-clean's own scan
#                                record among it; disk-remove.sh refuses all of it besides. One row
#                                is session-notes, whose bulky leftovers Dan's daily keep rule looks
#                                after (#3235), so this shows it and offers nothing
#   ~/.claude/file-history       Claude Code's copy of each file before an edit, which /rewind
#                                restores: one can be the only copy of an earlier version, so whether
#                                any goes is Dan's call (#3235)
#   ~/.claude-issue-spool        findings not yet reviewed
#   ~/.claude-issue-spool.backup-<date>  a copy of the spool nothing in this config writes now; it may
#                                hold findings found nowhere else, so Dan's call too
#   ~/.claude-payload-write-gate the payload write gate's note of each Bash call, read back when the
#                                call ends (hooks/payload-write-gate.sh)
#   ~/.claude-area-check         the area check's log, read for its weekly line
#   ~/.claude-quiz-verdicts      the merge quiz's counts, held and snoozed quizzes (hooks/pr-merge-quiz.sh)
#   ~/.claude-allow-rule-backups copies of allow rules taken before a sweep changed them, the only
#                                copy of the earlier rules (hooks/lib/local-allow-rules.py)
#   ~/.claude-handback-check     the hand back claims gate's refusal counts (hooks/handback-claims-gate.sh)
#   ~/.claude-engine-checks      written by a check nothing in this config names now, so kept
set -uo pipefail
HERE="${BASH_SOURCE[0]%/*}"; [ "$HERE" != "${BASH_SOURCE[0]}" ] || HERE=.
. "$HERE/../scan-lib.sh" || { echo "unmeasured: scan-lib.sh is missing beside the categories folder"; exit 0; }

# Sets V, always to "not offerable: <why>", for <target>.
rec_rules() { # <target>
  local t="${1%/}" n
  n="${t##*/}"
  case "$t" in
    "$HOME/.claude/state/session-notes")
      V="not offerable: sessions' notes and working files, which the daily keep rule for session notes looks after" ;;
    "$HOME/.claude/state/"*)
      case "${t#"$HOME/.claude/state/"}" in
        */*) V="not offerable: it is not one of the records this kind shows" ;;
        *) V="not offerable: state that Claude Code and this config's hooks read as they run, so it is never removed here" ;;
      esac ;;
    "$HOME/.claude/file-history")
      V="not offerable: Claude Code's copy of each file before an edit, which /rewind restores; one can be the only copy of an earlier version, so whether any goes is your call" ;;
    "$HOME/.claude-issue-spool")
      V="not offerable: findings not yet reviewed, which the end of turn issue review reads" ;;
    "$HOME/.claude-issue-spool.backup-"*)
      V="not offerable: a copy of the finding spool made $(printf '%s' "${n#.claude-issue-spool.backup-}" | sed 's|^\([0-9][0-9][0-9][0-9]\)\([0-9][0-9]\)\([0-9][0-9]\).*|\1-\2-\3|'); it may hold findings found nowhere else, so whether it goes is your call" ;;
    "$HOME/.claude-payload-write-gate")
      V="not offerable: the payload write gate's note of each Bash call, read back when the call ends" ;;
    "$HOME/.claude-area-check")
      V="not offerable: the area check's log, read for its weekly line" ;;
    "$HOME/.claude-quiz-verdicts")
      V="not offerable: the merge quiz's counts and its held and snoozed quizzes, read at each merge" ;;
    "$HOME/.claude-allow-rule-backups")
      V="not offerable: copies of allow rules taken before a sweep changed them, the only copy of the earlier rules" ;;
    "$HOME/.claude-handback-check")
      V="not offerable: the hand back claims gate's refusal counts, read as agents hand back" ;;
    "$HOME/.claude-engine-checks")
      V="not offerable: written by a check nothing in this config names now, so what reads it is not known" ;;
    *) V="not offerable: it is not one of the records this kind shows" ;;
  esac
}

# The rest of ~/.claude/state (about forty entries on the personal MacBook, all with the one reason) is
# said once, in the kind's note, with its count and size, rather than as forty greyed rows carrying
# the same sentence (L605); session notes keep a row of their own. Rows come largest first (L609).
do_scan() {
  local e
  : > "$DCS_WORK/rec.paths"; : > "$DCS_WORK/rec.rest"
  if [ -d "$HOME/.claude/state" ]; then
    if ls -A "$HOME/.claude/state" > "$DCS_WORK/rec.state" 2> "$DCS_WORK/rec.err"; then
      while IFS= read -r e; do
        [ -n "$e" ] || continue
        if [ "$e" = session-notes ]; then printf '%s\n' "$HOME/.claude/state/$e" >> "$DCS_WORK/rec.paths"
        else printf '%s\n' "$HOME/.claude/state/$e" >> "$DCS_WORK/rec.rest"; fi
      done < "$DCS_WORK/rec.state"
    else
      dcs_status "unmeasured: ~/.claude/state could not be listed ($(awk 'NR == 1' "$DCS_WORK/rec.err"))"
    fi
  fi
  for e in "$HOME/.claude/file-history" "$HOME/.claude-issue-spool" "$HOME"/.claude-issue-spool.backup-* \
    "$HOME/.claude-payload-write-gate" "$HOME/.claude-area-check" "$HOME/.claude-quiz-verdicts" \
    "$HOME/.claude-allow-rule-backups" "$HOME/.claude-handback-check" "$HOME/.claude-engine-checks"; do
    [ -e "$e" ] && printf '%s\n' "$e" >> "$DCS_WORK/rec.paths"
  done
  dcs_measure "$DCS_WORK/rec.paths" | sort -t "$S" -k2,2nr > "$DCS_WORK/rec.sized"
  local p kib size ident
  while IFS="$S" read -r p kib size ident; do
    rec_rules "$p"
    dcs_item "$p" delete "$kib" "$size" "$V" "" "" "$ident"
  done < "$DCS_WORK/rec.sized"
  [ -s "$DCS_WORK/rec.rest" ] || return 0
  local n=0 total=0 short=""
  dcs_measure "$DCS_WORK/rec.rest" > "$DCS_WORK/rec.rest.sized"
  while IFS="$S" read -r p kib size ident; do
    n=$((n + 1))
    case "$kib" in ''|*[!0-9]*) short=1 ;; *) total=$((total + kib)) ;; esac
    [ "$size" = measured ] || short=1
  done < "$DCS_WORK/rec.rest.sized"
  dcs_note "$n other entries in ~/.claude/state hold $([ -n "$short" ] && printf 'at least ')$(dcu_human "$total"): state that Claude Code and this config's hooks read as they run, never removed here."
}

case "${1:-}" in
  scan) do_scan ;;
  judge) rec_rules "${2:-}"; echo "$V" ;;
  *) echo "usage: claude-records.sh scan | claude-records.sh judge <target>" >&2; exit 2 ;;
esac
