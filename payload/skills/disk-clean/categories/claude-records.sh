#!/usr/bin/env bash
#
# claude-records.sh: disk-clean's Claude Code records category (claude-config#3235). See scan-lib.sh
# for the module calls.
#
# Shows, sized, what Claude Code and this config keep about their own work, so the review page says
# where that space is. It offers one thing, the folders of images and documents below; every other
# row says why it is never offered, and its judge refuses every other path. Read from the code that
# writes each one, 2026-11-18:
#   ~/.claude/state/<entry>      state hooks and sessions read as they run, disk-clean's own scan
#                                record among it; disk-remove.sh refuses all of it besides. One row
#                                is session-notes, whose bulky leftovers Dan's daily keep rule looks
#                                after (#3235), so this shows it and does not offer it
#   session-notes/<project>/<session>/<task>/<folder>  a folder the daily keep rules keep because it
#                                is mostly images or documents, in a session that has ended (Dan,
#                                2026-11-18, recorded on #3235: "2.4 Keep, and show in disk
#                                cleanup"). OFFERED, to the Trash (Dan, 2026-11-19: "Allow it").
#                                Which folders those are is the keep rules' own answer, never a
#                                second copy of either rule: their daily run writes it to
#                                ~/.claude/state/keep-rules/readable-folders.tsv and this reads that
#                                file, since a disk-clean script may not run python (Dan,
#                                2026-11-19: "Daily file, no list change"). So a row can be up to a
#                                day old, and these are unmeasured when the list is missing, not
#                                whole, or over two days old. One is offered only when it is still
#                                a real folder of that shape by its own path (dc_notes_folder, the
#                                predicate disk-remove.sh holds it to), its session is not open
#                                now, and nothing in it was changed or opened in 30 days
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
#   any other ~/.claude-* or ~/.claude.* entry: the sync's own folders and logs, other hooks' records
#                                (~/.claude-verification, ~/.claude-review-cases and the like),
#                                Claude Code's ~/.claude.json and its backups. Never offered, and
#                                counted with their size in the kind's note rather than as rows, so the
#                                kind accounts for every home entry named for Claude (#3235: the work
#                                MacBook held twelve such folders on 2026-11-19, 48 MB, and only some
#                                were rows)
set -uo pipefail
HERE="${BASH_SOURCE[0]%/*}"; [ "$HERE" != "${BASH_SOURCE[0]}" ] || HERE=.
. "$HERE/../scan-lib.sh" || { echo "unmeasured: scan-lib.sh is missing beside the categories folder"; exit 0; }

NOTES="$HOME/.claude/state/session-notes"
NOTES_LIST="$HOME/.claude/state/keep-rules/readable-folders.tsv"
NOTES_MAX_DAYS=2 # the keep rules run once a day, so a list older than this means that stopped
NOTES_WHAT="folders of images and documents in ended sessions' notes"

# Reads the list the daily keep rules run wrote (hooks/lib/keep_rules.py, write_readable_list), once
# per process. Writes the folders it names to rec.nd.paths, one a line, and sets NOTES_WHY to empty;
# or sets NOTES_WHY to why they are unmeasured: no list, one that is not whole, one too old to
# stand for today, or one in which the keep rules said they could not decide. A list is never read
# as a shorter list, so a missing or cut one cannot pass for "none" (L10).
notes_read() {
  [ -z "${NOTES_READ:-}" ] || return 0
  NOTES_READ=1 NOTES_WHY=""
  local f="$NOTES_LIST" m now age verdict
  : > "$DCS_WORK/rec.nd.paths"
  if [ ! -f "$f" ] || [ -L "$f" ]; then
    if [ -e "${f%/*}/off" ]; then NOTES_WHY="the daily keep rules job is switched off on this Mac, so nothing lists them"
    else NOTES_WHY="the daily keep rules run has not written its list of them (it runs once a day)"; fi
    return 0
  fi
  m="$(dcs_mtime "$f")"; now="$(date '+%s')"
  case "$m:$now" in *[!0-9:]*|:*|*:) NOTES_WHY="the age of the daily keep rules run's list could not be read"; return 0 ;; esac
  age=$((now - m))
  if [ "$age" -lt -300 ]; then NOTES_WHY="the daily keep rules run's list is dated in the future, so its age cannot be trusted"; return 0; fi
  if [ "$age" -gt $((NOTES_MAX_DAYS * 86400)) ]; then
    NOTES_WHY="the daily keep rules run last listed them $((age / 86400)) days ago, on $(dcs_date "$m"), and a list over $NOTES_MAX_DAYS days old is not used"; return 0
  fi
  verdict="$(awk -F '\t' '
    NR == 1 { if ($0 != "readable-folders\t1") bad = 1; next }
    bad || ended { bad = 1; next }
    $1 == "folder" && NF == 3 && $2 ~ /^[0-9]+$/ && $3 ~ /^\// { n++; next }
    $1 == "unmeasured" && NF == 2 && $2 != "" { why = $2; next }
    $1 == "end" && NF == 2 && $2 ~ /^[0-9]+$/ { ended = 1; count = $2 + 0; next }
    { bad = 1 }
    END {
      if (NR == 0 || bad || !ended || count != n + 0) print "bad"
      else if (why != "") print "unmeasured\t" why
      else print "ok"
    }' "$f" 2>/dev/null)" || verdict=bad
  case "$verdict" in
    ok) awk -F '\t' '$1 == "folder" { print $3 }' "$f" > "$DCS_WORK/rec.nd.paths" ;;
    unmeasured$'\t'?*) NOTES_WHY="${verdict#unmeasured$'\t'}" ;;
    *) NOTES_WHY="the daily keep rules run's list is not whole, or is not one this reads ($f)" ;;
  esac
  return 0
}

# Sets V for a folder in a session's task folder: offerable only when it is one, by dc_notes_folder,
# the list names it, its session is not open now, and the 30 day floor holds.
notes_rules() { # <target>
  local t="${1%/}" rest sid
  REC_METHOD=trash
  if ! dc_notes_folder "$t" "$HOME" "$DCS_HOME"; then V="not offerable: $DC_NOTES_WHY"; return; fi
  notes_read
  if [ -n "$NOTES_WHY" ]; then V="unmeasured: $NOTES_WHY"; return; fi
  if ! grep -qxF -- "$t" "$DCS_WORK/rec.nd.paths"; then
    V="not offerable: the daily keep rules run does not list it as an ended session's folder of mostly images or documents"; return
  fi
  # The list can be a day old, and a session can be resumed in that day.
  rest="${t#*/.claude/state/session-notes/}"; rest="${rest#*/}"; sid="${rest%%/*}"
  if ! dcs_sessions "$DCS_WORK/rec.nd.ids" "$DCS_WORK/rec.nd.cwds"; then
    V="unmeasured: whether its session is open now could not be read ($DCS_WHY)"; return
  fi
  if grep -qxF -- "$sid" "$DCS_WORK/rec.nd.ids"; then V="not offerable: its session is open now"; return; fi
  V=offerable
  dcs_floor "$t"
}

# Sets V for <target>: "not offerable: <why>" for everything but a folder in a session's task folder.
# Sets REC_METHOD to how its row would go: the Trash for such a folder, and for the rest delete,
# which nothing ever acts on, since none of them is offered.
rec_rules() { # <target>
  local t="${1%/}" n
  n="${t##*/}"
  REC_METHOD=delete
  # Anything four levels under session-notes, by the shape disk-remove.sh reads, is notes_rules' to
  # answer; a path that only resembles one (a link, a file) is refused there with its own reason.
  if dc_notes_shape "$t" "$HOME" || dc_notes_shape "$t" "$DCS_HOME"; then notes_rules "$t"; return; fi
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
    "$HOME/.claude-"?*|"$HOME/.claude."?*)
      case "${t#"$HOME/"}" in
        */*) V="not offerable: it is not one of the records this kind shows" ;;
        *) V="not offerable: a file or folder that Claude Code, the sync or this config's hooks read, counted in this kind's note" ;;
      esac ;;
    *) V="not offerable: it is not one of the records this kind shows" ;;
  esac
}

# The rest of ~/.claude/state (about forty entries on the personal MacBook, all with the one reason) is
# said once, in the kind's note, with its count and size, rather than as forty greyed rows carrying
# the same sentence (L605); session notes keep a row of their own. Rows come largest first (L609).
do_scan() {
  local e unmeasured=""
  : > "$DCS_WORK/rec.paths"; : > "$DCS_WORK/rec.rest"
  if [ -d "$HOME/.claude/state" ]; then
    if ls -A "$HOME/.claude/state" > "$DCS_WORK/rec.state" 2> "$DCS_WORK/rec.err"; then
      while IFS= read -r e; do
        [ -n "$e" ] || continue
        if [ "$e" = session-notes ]; then printf '%s\n' "$HOME/.claude/state/$e" >> "$DCS_WORK/rec.paths"
        else printf '%s\n' "$HOME/.claude/state/$e" >> "$DCS_WORK/rec.rest"; fi
      done < "$DCS_WORK/rec.state"
    else
      unmeasured="~/.claude/state could not be listed ($(awk 'NR == 1' "$DCS_WORK/rec.err"))"
    fi
  fi
  # The folders the daily keep rules list, each a row among the others. One that has gone since the
  # list was written (moved to the Trash from here yesterday, say) or is no longer a real folder of
  # the shape is no row: the list can be a day old, and what is not there has no size to show.
  if [ -d "$NOTES" ]; then
    notes_read
    if [ -n "$NOTES_WHY" ]; then
      unmeasured="${unmeasured:+$unmeasured; }$NOTES_WHAT: $NOTES_WHY"
    else
      while IFS= read -r e; do
        dc_notes_folder "$e" "$HOME" "$DCS_HOME" && printf '%s\n' "$e" >> "$DCS_WORK/rec.paths"
      done < "$DCS_WORK/rec.nd.paths"
    fi
  fi
  # One status line for the kind, since the scan keeps only the last one a module prints.
  [ -z "$unmeasured" ] || dcs_status "unmeasured: $unmeasured"
  for e in "$HOME/.claude/file-history" "$HOME/.claude-issue-spool" "$HOME"/.claude-issue-spool.backup-* \
    "$HOME/.claude-payload-write-gate" "$HOME/.claude-area-check" "$HOME/.claude-quiz-verdicts" \
    "$HOME/.claude-allow-rule-backups" "$HOME/.claude-handback-check" "$HOME/.claude-engine-checks"; do
    [ -e "$e" ] && printf '%s\n' "$e" >> "$DCS_WORK/rec.paths"
  done
  # Every other home entry named for Claude, which the note counts (the header says what they are).
  : > "$DCS_WORK/rec.home"
  for e in "$HOME"/.claude-* "$HOME"/.claude.*; do
    { [ -e "$e" ] || [ -L "$e" ]; } || continue
    grep -qxF -- "$e" "$DCS_WORK/rec.paths" || printf '%s\n' "$e" >> "$DCS_WORK/rec.home"
  done
  dcs_measure "$DCS_WORK/rec.paths" | sort -t "$S" -k2,2nr > "$DCS_WORK/rec.sized"
  local p kib size ident
  while IFS="$S" read -r p kib size ident; do
    rec_rules "$p"
    dcs_item "$p" "$REC_METHOD" "$kib" "$size" "$V" "" "" "$ident"
  done < "$DCS_WORK/rec.sized"
  local notes=""
  [ ! -s "$DCS_WORK/rec.rest" ] || notes="$(rec_count "$DCS_WORK/rec.rest" "other entries in ~/.claude/state") state that Claude Code and this config's hooks read as they run, never removed here."
  [ ! -s "$DCS_WORK/rec.home" ] || notes="${notes:+$notes }$(rec_count "$DCS_WORK/rec.home" "other files and folders in the home folder named for Claude Code or this config") the sync's folders and logs, other hooks' records and Claude Code's settings, never removed here."
  [ -z "$notes" ] || dcs_note "$notes"
}

# Prints "<count> <what> hold <size>:" for the paths listed in <file>, "at least" before the size when
# any of them could not be read in full (dcs_measure's size column).
rec_count() { # <file of paths> <what>
  local n=0 total=0 short="" p kib size ident
  dcs_measure "$1" > "$1.sized"
  while IFS="$S" read -r p kib size ident; do
    n=$((n + 1))
    case "$kib" in ''|*[!0-9]*) short=1 ;; *) total=$((total + kib)) ;; esac
    [ "$size" = measured ] || short=1
  done < "$1.sized"
  printf '%s %s hold %s%s:' "$n" "$2" "$([ -n "$short" ] && printf 'at least ')" "$(dcu_human "$total")"
}

case "${1:-}" in
  scan) do_scan ;;
  judge) rec_rules "${2:-}"; echo "$V" ;;
  *) echo "usage: claude-records.sh scan | claude-records.sh judge <target>" >&2; exit 2 ;;
esac
