#!/usr/bin/env bash
#
# claude-records.sh: disk-clean's Claude Code records category (claude-config#3235). See scan-lib.sh
# for the module calls.
#
# Shows, sized, what Claude Code and this config keep about their own work, so the review page says
# where that space is. It offers only folders in a session's task folder that the daily keep rules
# list, each by a decision of Dan's below; every other row says why it is never offered, and its
# judge refuses every other path. Read from the code that writes each one, 2026-11-18:
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
#   the same shape, in a session still OPEN: a bulky leftover, by the keep rules' own definition of
#                                bulky (a folder of 1 MB or more that is neither a git checkout nor
#                                mostly images or documents), which they list in open-leftovers.tsv
#                                and never remove while the session is open. OFFERED, to the Trash,
#                                once nothing in its task folder was changed or opened for 7 days
#                                (Dan, 2026-11-19, recorded on #3235: "Offer after 7 idle days");
#                                leftover_rules says which times that reads and why
#   ~/.claude/file-history      Claude Code's copy of each file before an edit, which /rewind
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
NOTES_LISTS="$HOME/.claude/state/keep-rules"
NOTES_MAX_DAYS=2 # the keep rules run once a day, so a list older than this means that stopped
# The lists the daily keep rules run writes there (hooks/lib/keep_rules.py, the_lists), each the
# file <name>.tsv, and what each one's folders are, as the kind says it when one cannot be read.
NOTES_WHAT="folders of images and documents in ended sessions' notes"
OPEN_WHAT="bulky leftovers in the notes of sessions still open"
CHECKOUT_WHAT="git checkouts ended sessions keep in their notes"
# A bulky leftover in an open session is offered once nothing in its task folder was changed or
# opened for this many days (Dan, 2026-11-19, recorded on #3235: "Offer after 7 idle days").
OPEN_IDLE_DAYS=7

# Reads one list the daily keep rules run wrote (write_list in keep_rules.py), once per process.
# Sets LIST_PATHS to a file of the folders it names, one a line, and LIST_WHY to empty; or sets
# LIST_WHY to why they are unmeasured: no list, one that is not whole, one too old to stand for
# today, or one in which the keep rules said they could not decide. A list is never read as a
# shorter list, so a missing or cut one cannot pass for "none" (L10).
list_read() { # <list name: readable-folders or open-leftovers>
  LIST_PATHS="$DCS_WORK/rec.$1.paths" LIST_WHY=""
  if [ -f "$LIST_PATHS.why" ]; then LIST_WHY="$(cat "$LIST_PATHS.why")"; return 0; fi
  list_load "$1"
  printf '%s\n' "$LIST_WHY" > "$LIST_PATHS.why"
}
list_load() { # <list name>, for list_read alone
  local f="$NOTES_LISTS/$1.tsv" m now age verdict
  : > "$LIST_PATHS"
  if [ ! -f "$f" ] || [ -L "$f" ]; then
    if [ -e "${f%/*}/off" ]; then LIST_WHY="the daily keep rules job is switched off on this Mac, so nothing lists them"
    else LIST_WHY="the daily keep rules run has not written its list of them (it runs once a day)"; fi
    return 0
  fi
  m="$(dcs_mtime "$f")"; now="$(date '+%s')"
  case "$m:$now" in *[!0-9:]*|:*|*:) LIST_WHY="the age of the daily keep rules run's list could not be read"; return 0 ;; esac
  age=$((now - m))
  if [ "$age" -lt -300 ]; then LIST_WHY="the daily keep rules run's list is dated in the future, so its age cannot be trusted"; return 0; fi
  if [ "$age" -gt $((NOTES_MAX_DAYS * 86400)) ]; then
    LIST_WHY="the daily keep rules run last listed them $((age / 86400)) days ago, on $(dcs_date "$m"), and a list over $NOTES_MAX_DAYS days old is not used"; return 0
  fi
  verdict="$(awk -F '\t' -v head="$1" '
    NR == 1 { if ($0 != head "\t1") bad = 1; next }
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
    ok) awk -F '\t' '$1 == "folder" { print $3 }' "$f" > "$LIST_PATHS" ;;
    unmeasured$'\t'?*) LIST_WHY="${verdict#unmeasured$'\t'}" ;;
    *) LIST_WHY="the daily keep rules run's list is not whole, or is not one this reads ($f)" ;;
  esac
  return 0
}
# Succeeds when the list <name> could be read and names <target>.
list_names() { # <list name> <target>
  list_read "$1"
  [ -z "$LIST_WHY" ] && grep -qxF -- "$2" "$LIST_PATHS"
}
# The live session map, read once per process: fails, setting V, when it could not be read.
sessions_read() {
  if [ -z "${SESSIONS_READ:-}" ]; then
    SESSIONS_READ=ok
    dcs_sessions "$DCS_WORK/rec.nd.ids" "$DCS_WORK/rec.nd.cwds" || SESSIONS_READ="$DCS_WHY"
  fi
  [ "$SESSIONS_READ" = ok ] || { V="unmeasured: which sessions are open now, and where they are working, could not be read ($SESSIONS_READ)"; return 1; }
}
# Succeeds, setting V, when a live session's working folder is <folder> or inside it. Its process
# names that folder, so it is never idle while that runs, whatever its files' times say.
session_works_in() { # <folder> <what to call it>
  local f="${1%/}" p cwd
  p="$(dcs_phys "$f" 2>/dev/null)" || p="$f"
  while IFS= read -r cwd; do
    [ -n "$cwd" ] || continue
    case "$cwd" in "$f"|"$f"/*|"$p"|"$p"/*) V="not offerable: a session is working in $2 ($cwd)"; return 0 ;; esac
  done < "$DCS_WORK/rec.nd.cwds"
  return 1
}

# Sets V for a folder in a session's task folder, by which of the keep rules' lists names it: a
# folder of images or documents in an ended session (readable_rules), or a bulky leftover in an open
# one (leftover_rules). One no list names is not offerable, and unmeasured while a list that might
# have named it cannot be read.
notes_rules() { # <target>
  local t="${1%/}" why="" open_why=""
  REC_METHOD=trash
  if ! dc_notes_folder "$t" "$HOME" "$DCS_HOME"; then V="not offerable: $DC_NOTES_WHY"; return; fi
  if list_names readable-folders "$t"; then readable_rules "$t"; return; fi
  why="$LIST_WHY"
  if list_names open-leftovers "$t"; then leftover_rules "$t"; return; fi
  open_why="$LIST_WHY"
  # Only a folder holding a .git can be on the list of checkouts, so that list is asked of no other.
  if [ -e "$t/.git" ] || [ -L "$t/.git" ]; then checkout_listed "$t" && return; fi
  if [ -n "$why" ]; then V="unmeasured: $why"; return; fi
  if [ -n "$open_why" ]; then V="unmeasured: whether it is one of the $OPEN_WHAT is not known: $open_why"; return; fi
  V="not offerable: the daily keep rules run does not list it, as an ended session's folder of mostly images or documents or git checkout, or as a bulky leftover in a session still open"
}

# Sets V for a session's task folder: never offerable unless it is itself a git checkout holding
# its own repository (dc_notes_checkout, which disk-remove.sh holds it to) that the keep rules list.
task_rules() { # <target>
  local t="${1%/}"
  REC_METHOD=trash
  if ! dc_notes_checkout "$t" "$HOME" "$DCS_HOME"; then V="not offerable: $DC_NOTES_WHY"; return; fi
  checkout_listed "$t" && return
  V="not offerable: the daily keep rules run does not list it as a git checkout an ended session keeps"
}

# Succeeds, V set, when the list of kept checkouts names <target> (checkout_rules then judges it)
# or cannot be read (unmeasured). Fails, V untouched, when the list is whole and does not name it.
checkout_listed() { # <target>
  if list_names kept-checkouts "$1"; then checkout_rules "$1"; return 0; fi
  [ -n "$LIST_WHY" ] || return 1
  V="unmeasured: whether it is one of the $CHECKOUT_WHAT is not known: $LIST_WHY"
}

# A git checkout the keep rules keep in an ENDED session's notes, which their list names (Dan,
# 2026-11-19, recorded on #3235: "Offer when git says safe"). They keep it because it may hold work
# that exists nowhere else, so it is offered only when git says none does. In order:
#   its session is not open now (the list can be a day old), and no live session is working in it;
#   its .git is a real folder, so the repository git answers for is the one inside it. A .git file
#   names a repository somewhere else (a worktree, a submodule), and git here would answer for that;
#   the 30 day floor, before git runs, since git status reads files. Files inside .git are read by
#   git on every look, so only their change times count, as for a worktree's .git file;
#   dcs_git_merged, the worktrees kind's own test: nothing uncommitted or untracked, on a branch,
#   and a merged pull request whose head is exactly its HEAD;
#   no stash, which lives in this folder's own repository and would go with it;
#   no commit on any other branch or tag that no remote has (HEAD's own are the merged pull
#   request's): a worktree leaves its other branches behind in its repository, and this does not;
#   the floor again, so a file git had to read just now is never offered as unopened.
checkout_rules() { # <target>
  local t="$1" rest sid out n err="$DCS_WORK/rec.git.err.$$"
  rest="${t#*/.claude/state/session-notes/}"; rest="${rest#*/}"; sid="${rest%%/*}"
  sessions_read || return
  if grep -qxF -- "$sid" "$DCS_WORK/rec.nd.ids"; then V="not offerable: its session is open now"; return; fi
  session_works_in "$t" it && return
  if [ ! -d "$t/.git" ] || [ -L "$t/.git" ]; then
    V="not offerable: its .git is not a folder of its own, so it is a worktree or submodule of a repository elsewhere, and git here would answer for that one"; return
  fi
  V=offerable
  dcs_floor "$t" .gitignore .gitattributes "$t/.git/*"
  [ "$V" = offerable ] || return
  dcs_git_merged "$t"
  [ "$V" = offerable ] || return
  out="$(git -C "$t" stash list 2> "$err" </dev/null)" || { V="unmeasured: git stash list failed ($(awk 'NR == 1' "$err"))"; rm -f "$err"; return; }
  [ -z "$out" ] || { V="not offerable: it holds a stash"; rm -f "$err"; return; }
  n="$(git -C "$t" rev-list --count --branches --tags --not --remotes HEAD 2> "$err" </dev/null)" || { V="unmeasured: git rev-list failed ($(awk 'NR == 1' "$err"))"; rm -f "$err"; return; }
  rm -f "$err"
  case "$n" in
    0) ;;
    ''|*[!0-9]*) V="unmeasured: git rev-list did not give a count of the commits no remote has ($n)"; return ;;
    *) V="not offerable: it holds $n commit(s) on another branch or tag that no remote has"; return ;;
  esac
  dcs_floor "$t" .gitignore .gitattributes "$t/.git/*"
  case "$V" in
    offerable)
      REC_DETAIL="a git checkout an ended session kept: nothing uncommitted, no stash, $D"
      out="$(dcs_credential "$t")"
      [ -z "$out" ] || { REC_FLAGS=credential; REC_DETAIL="$REC_DETAIL; holds ${out#"$t"/}"; } ;;
    "not offerable: opened within "*)
      V="not offerable: asking git about it just now read files in it, which counts as opening them, so it waits $DCS_UNUSED_DAYS days from today" ;;
  esac
}

# A folder of images or documents the list names: offerable only when its session is not open now
# and the 30 day floor holds.
readable_rules() { # <target>
  local t="$1" rest sid
  # The list can be a day old, and a session can be resumed in that day.
  rest="${t#*/.claude/state/session-notes/}"; rest="${rest#*/}"; sid="${rest%%/*}"
  sessions_read || return
  if grep -qxF -- "$sid" "$DCS_WORK/rec.nd.ids"; then V="not offerable: its session is open now"; return; fi
  V=offerable
  dcs_floor "$t"
}

# A bulky leftover in a session still open, which the list names (Dan, 2026-11-19, recorded on
# #3235: "Offer after 7 idle days"). What is bulky is the keep rules' own answer, in the list. This
# asks what only today can say:
#   it holds no .git at its top now (a checkout may hold work that exists nowhere else, and the
#   keep rules never call one bulky; one made there since the list was written is kept too);
#   no live session's working folder is its task folder or inside it: the process names that folder
#   as where it works, so it is not idle while that runs, however old its files are;
#   nothing in its TASK folder was changed or opened in OPEN_IDLE_DAYS days, the notes beside it
#   included, since an agent still writing its handoff there is still using its fixtures.
# The times are the floor's (dcs_idle in scan-lib.sh): the modification time of everything in the
# task folder and the access time of its files. A folder's access time is never read, because
# listing a folder moves it, and listing is all the daily keep rules job and this scan do there
# (os.listdir and lstat; du, find and lsof): neither opens a file, so neither moves a time this
# reads. A program that does read the files, a backup say, moves a file's access time only on the
# first read after each change, so it can delay an offer once and can never bring one forward. The
# task folder's own modification time is left out (depth 1), because moving one ticked leftover to
# the Trash moves it, and the next one in the same folder is judged again just after.
leftover_rules() { # <target>
  local t="$1" task="${1%/*}"
  if [ -e "$t/.git" ] || [ -L "$t/.git" ]; then
    V="not offerable: it is a git checkout now, which may hold work that exists nowhere else"; return
  fi
  sessions_read || return
  session_works_in "$task" "its task folder" && return
  V=offerable
  dcs_idle "$OPEN_IDLE_DAYS" 1 "$task"
  case "$V" in
    "not offerable: changed within "*|"not offerable: opened within "*) V="not offerable: something in its task folder was ${V#not offerable: }" ;;
    offerable) REC_DETAIL="a bulky leftover in a session still open, with nothing in its task folder changed or run in $OPEN_IDLE_DAYS days" ;;
  esac
}

# Sets V for <target>: "not offerable: <why>" for everything but a folder in a session's task folder.
# Sets REC_METHOD to how its row would go: the Trash for such a folder, and for the rest delete,
# which nothing ever acts on, since none of them is offered. Sets REC_DETAIL to what a row says of
# itself beyond its path, where its rule is not the 30 days the page states for every row.
rec_rules() { # <target>
  local t="${1%/}" n
  n="${t##*/}"
  REC_METHOD=delete REC_DETAIL="" REC_FLAGS=""
  # Anything four levels under session-notes, by the shape disk-remove.sh reads, is notes_rules' to
  # answer; a path that only resembles one (a link, a file) is refused there with its own reason.
  if dc_notes_shape "$t" "$HOME" || dc_notes_shape "$t" "$DCS_HOME"; then notes_rules "$t"; return; fi
  if dc_notes_task_shape "$t" "$HOME" || dc_notes_task_shape "$t" "$DCS_HOME"; then task_rules "$t"; return; fi
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
  local list what
  if [ -d "$NOTES" ]; then
    for list in "readable-folders|$NOTES_WHAT" "open-leftovers|$OPEN_WHAT" "kept-checkouts|$CHECKOUT_WHAT"; do
      what="${list#*|}"; list_read "${list%%|*}"
      if [ -n "$LIST_WHY" ]; then
        unmeasured="${unmeasured:+$unmeasured; }$what: $LIST_WHY"
      else
        while IFS= read -r e; do
          dc_notes_item "$e" "$HOME" "$DCS_HOME" && ! grep -qxF -- "$e" "$DCS_WORK/rec.paths" && printf '%s\n' "$e" >> "$DCS_WORK/rec.paths"
        done < "$LIST_PATHS"
      fi
    done
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
    dcs_item "$p" "$REC_METHOD" "$kib" "$size" "$V" "$REC_FLAGS" "$REC_DETAIL" "$ident"
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
