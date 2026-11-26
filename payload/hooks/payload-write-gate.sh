#!/usr/bin/env bash
#
# payload-write-gate.sh
# Claude Code PreToolUse(Bash|Edit|Write|MultiEdit|NotebookEdit) hook: refuse a payload/ write
# Claude Code PostToolUse(Bash|Monitor) hook: name what a Bash call changed there, by destination
# Claude Code PostToolUseFailure(Bash|Monitor) hook: the same for a call that failed partway
# Claude Code PermissionDenied(Bash|Monitor) hook: drop the note of a call refused before it ran
#
# The first refuses a write under a development checkout's payload/ while the watch daemon could
# revert it, rather than warning about it on the next prompt (claude-config#367). Before a Bash call
# it also notes what an at risk payload/ holds, and after the call the second and third name anything
# written, added or removed there, so a write the command's words could not show (a script file, a
# path built at run time) is still caught, by its destination (claude-config#647). Each end of a
# call this gate hears of removes its note: succeeding, failing, and being refused by auto mode. On
# that last one it only removes the note, saying and deciding nothing (claude-config#3253).
#
# payload-revert-warning.sh already says the right thing: edits to payload/ in a development
# checkout are mirrored over by the watch daemon running from another clone. But it is a
# UserPromptSubmit hook, so it speaks only when Dan sends a message. On 2026-09-10 a session made
# roughly forty tool calls editing payload/LESSONS.md, adding 476 short form lines, before the
# warning was ever printed, and only then took a hold. Had the daemon fired in that window the work
# would have been reverted silently, which is what happened on 2026-09-03 to 84 files.
#
# So the refusal happens at the WRITE, which is the first step that can answer it (L667), and the
# prompt time warning stays for the case this cannot see: a hold that lapses mid session.
#
# It refuses ONLY in the state that loses work: a live watcher, running from a DIFFERENT clone, and
# no hold in force that covers the writing session, in a checkout the daemon can overwrite. A
# session editing the clone the watcher itself runs from is editing the source of the mirror and is
# not at risk, and neither is one holding the watcher off.
#
# A watcher it could NOT READ counts as one that may be live (claude-config#3547): the pid file
# names a process that is running, or that the shell may not even test, and ps could not say what
# it is. That is refused in its own words, which
# name the command that failed, and the clone the watcher runs from cannot be told apart then, so
# only a hold, an own worktree and a plain copy are let through. No watcher is a settled answer: no
# pid file, or one naming a process that is not running or is something else.
#
# The hold has to be the WRITING session's own, or one taken from a terminal, which records no
# session and covers anyone (claude-config#1886). Any session's hold used to do: session B wrote on
# session A's hold, and B's half written files were sent the moment A released. The refusal then
# names whose hold it is and that this session needs its own.
#
# Nor is an agent's linked worktree on a branch other than the default (claude-config#800): the
# daemon never writes into it, and its work reaches main only by a reviewed merge. Both halves
# below, the refusal before a call and the report after it, let it through.
#
# Nor is a plain copy of the tree with no repository around it (claude-config#2705), such as one
# kept in a session notes folder to measure a change in: what the daemon overwrites it reaches
# through the repository, and a copy with none has no route there. Both halves let it through, and
# only on git's own word that there is no repository plus no .git found by looking, so a copy that
# is its own checkout, one inside another work tree, and one git cannot answer for are refused as
# before (lib/sync-clone.sh, sc_is_plain_copy). A call this gate cannot READ is refused there too:
# where it writes is unknown, so the copy it was made from decides nothing.
#
# A destination is judged by its text AND by where it really is (claude-config#3537): the kernel is
# asked for the real path of each one, which sees through a path by disk and file number, a link
# that lives outside payload/ and another letter case of the folder name. A real path that cannot
# be read, and a file with more than one name, are refused in their own words, never let through.
# Making a link is a write, by ln, by the link command or by an inline script.
#
# Three routes more are read, each only ever adding a refusal (claude-config#3689): the command
# string an inline script hands to a shell, read the way that command typed directly is; a
# destination written as a pattern, judged as each file it matches; and the links a script FILE
# the command runs makes. What cannot be told (a string whose program is a value, a string longer
# than is read, a script file that cannot be read, a pattern with more files than are read) is
# refused in words that say so and that say to run the command directly, where this gate can
# read it.
#
# The questions come from lib/sync-clone.sh, shared with the warning hook, so the two cannot come
# to two different answers about whether a hold is in force (L370).
#
# Env:
#   SYNC_WATCH_PID_FILE  the watcher's pid file (default ~/.claude-sync-watch.pid)
#   SYNC_HOLD_FILE       the hold marker (default ~/.claude-sync-hold)
#   PAYLOAD_WRITE_INSTALLED_DIR  the installed config a changed file is compared with (default ~/.claude)
# Override, per this repo's convention, explained to the person first and never silently:
#   SKIP_PAYLOAD_WRITE_CHECK=1 as an inline prefix on a Bash command, for that one command.

set -uo pipefail

# Its own folder cut from its path in bash, never by dirname (claude-config#2081, #2130).
case "${BASH_SOURCE[0]}" in */*) HOOK_DIR="${BASH_SOURCE[0]%/*}" ;; *) HOOK_DIR=. ;; esac
HOOK_DIR="$(cd "${HOOK_DIR:-/}" && pwd)"
payload="$(cat 2>/dev/null || true)"

# A LIBRARY THIS GATE CANNOT LOAD IS NOT NOTHING TO CHECK (claude-config#1900, L10, L1033).
#
# Both libraries below answer every question this gate asks: whether a watcher could revert the
# write, whether it runs from here, whether a hold covers it, and what the command writes. They were
# sourced with || exit 0 after it, so a hook dir missing either let every payload write through with
# nothing said, which looks exactly like a write nothing could revert. Now the call is refused when
# its raw payload names payload/ at all, since nothing here can read more than that, and the
# refusal names the file. A library that sources but lacks the function asked for (an empty or cut
# short file) is the same failure. After a call there is nothing left to refuse.
# Is this payload one sent after a call has ended, or once it was refused, read from its raw text
# because the readers below may be what failed? Every such event, never only PostToolUse: a failed
# call (PostToolUseFailure) has already run and a refused one (PermissionDenied) never will, so
# neither has anything left to refuse (claude-config#3253).
after_call(){
  case "$payload" in
    *'"hook_event_name":"PostToolUse'*|*'"hook_event_name": "PostToolUse'*) return 0 ;;
    *'"hook_event_name":"PermissionDenied"'*|*'"hook_event_name": "PermissionDenied"'*) return 0 ;;
  esac
  return 1
}
unloaded(){   # $1 = the library file that could not be loaded
  case "$payload" in *SKIP_PAYLOAD_WRITE_CHECK=1*) exit 0 ;; esac
  after_call && exit 0
  case "$payload" in *payload/*) ;; *) exit 0 ;; esac
  cat >&2 <<MSG
claude-sync: REFUSED a write that may be under a development checkout's payload/.

payload-write-gate.sh could not load lib/$1 from $HOOK_DIR/lib, and that library is how it tells whether a watch daemon could revert this write and whether a hold covers it. A library this gate cannot load is not a sign there is nothing to check, so a call naming payload/ is refused until it is back. Reinstall the hooks with: claude-sync pull

For one Bash command, and only after reading this: SKIP_PAYLOAD_WRITE_CHECK=1 <the same command>
MSG
  exit 2
}
# shellcheck source=lib/sync-clone.sh
{ . "$HOOK_DIR/lib/sync-clone.sh" 2>/dev/null && declare -F sc_hold_covers >/dev/null && declare -F sc_watcher_possible >/dev/null; } || unloaded sync-clone.sh
# shellcheck source=lib/push-scope.sh
{ . "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null && declare -F ps_parse_payload >/dev/null; } || unloaded push-scope.sh
# Taken raw above, for the refusal a missing library gives, and cleaned now, before anything parses
# it: a lone surrogate escape reads as nothing to jq and raises in python3's print (claude-config#1944).
payload="$(ps_clean_payload "$payload")"
# Missing, a file differing only by the home placeholder is reported rather than left out, which is
# the safe side of that question.
# shellcheck source=lib/home-token.sh
. "$HOOK_DIR/lib/home-token.sh" 2>/dev/null || true

# WHICH SESSION is writing, because only its own hold protects its writes (claude-config#1886).
# Another session's hold lets this one write today and is released whenever that session is done,
# which sends this session's half written files with it. Read from the payload without python3, so
# the branch below that has none still knows; lib/sync-clone.sh adds CLAUDE_CODE_SESSION_ID.
sid="$(sc_payload_session "$payload")"
# The paragraph that names who does hold the watcher, when it is somebody else, and where this
# message gives the command that takes this session's own hold, in OTHERS_NOTE with the blank line
# that follows it. Empty otherwise, so a message reads exactly as before when nobody else holds.
OTHERS_NOTE=""
others_note(){   # $1 = where the command is in this message
  local s
  OTHERS_NOTE=""
  s="$(sc_hold_others_sentence "$sid")"
  [ -n "$s" ] || return 0
  # Pointed at the command only when another session holds; the same call also says when no hold
  # can count at all because the hold reader is missing, and then no hold would help.
  [ -z "$(sc_hold_others "$sid")" ] || s="$s Take it with $1."
  OTHERS_NOTE="$s

"
}

# A WATCHER THIS GATE COULD NOT READ IS NOT ONE THAT IS ABSENT (claude-config#3547, L10).
#
# Whether a watch daemon is live, and which clone it runs from, is read from the process itself with
# ps, in lib/sync-clone.sh. That reading's failure was discarded, so a ps that could not run (refused
# by a wrapper, missing from PATH) gave an empty answer, every question below read it as no watcher,
# and the write was allowed with nothing said. Found on 2026-11-24, when five cases of
# test-gates-fail-closed.sh about this gate passed a call through under a wrapper that forbade ps.
#
# So every place below asks sc_watcher_possible, which says no only when it is SETTLED that none is
# running. For a watcher that could not be read, the pass for the clone it runs from is not given,
# since that is read from the same command line (sc_is_this_clone is handed an empty one, which
# matches no clone). The passes that do not depend on the watcher stand: a linked worktree on its
# own branch, a plain copy, and a hold of this session's, which is read from its own record and is
# the way on that the refusal names (L111).
#
# The refusal is its own message, never the live watcher's with a word changed, because a message
# may claim only what its check measured (L11) and nothing here saw a watcher. It reads the state
# sc_watcher_possible left, so it is called straight after the reading that refused, with no other
# reading between them.
watcher_seen(){ [ "${SC_WATCHER_STATE:-}" = live ]; }
# The words a refusal of a call it could not read carries about the watcher, in place of @WATCHER@.
WATCHER_SEEN_CLAUSE="a watch daemon is live on this Mac running from another clone"
WATCHER_UNREAD_CLAUSE="whether a watch daemon is live on this Mac could not be read either"
refuse_watcher_unread(){   # $1 = what is refused, as the first line names it; $2 = a paragraph about the call itself, or nothing
  local about=""
  [ -z "${2:-}" ] || about="$2

"
  others_note "the second way below"
  cat >&2 <<MSG
claude-sync: REFUSED $1: this gate could not read whether a watch daemon is live on this Mac.

${about}$(sc_watcher_unread_sentence) A watcher this gate cannot read is not one it can rule out, so the write is refused rather than allowed (claude-config#3547). A live one mirrors ~/.claude up over payload/ and pushes, so an edit made to payload/ in a development checkout is not merged with the config, it is overwritten by it, silently and with no conflict to notice. On 2026-09-03 that reverted 84 files of a day's work in one commit. Which clone a watcher runs from is read the same way, so the clone it runs from is refused with every other until this can be read.

${OTHERS_NOTE}Three ways on, and the first needs nothing:

  1. Edit ~/.claude directly. That is the copy the daemon mirrors FROM, so nothing can revert it.
  2. Take a hold first, then edit here. A hold is read from its own record, so it counts while the watcher cannot be read:

     claude-sync hold 120 "why you are editing the checkout"

  3. See why it could not be read. Run this in a terminal and fix what it reports:

     $SC_WATCHER_PROBE

A hold expires. When it does, make ~/.claude match what is in the checkout, or a live watcher's next send reverts it.
MSG
  exit 2
}

# THE READER THIS GATE SEES THE TOOL CALL THROUGH, asked before its answer is believed
# (claude-config#480, L490).
#
# Which tool is being called and which files it would write are both read with python3 below. With
# none installed the tool name came back as a dash, the case over it matched nothing, and every
# write under payload/ was allowed with nothing said: an absent reader is the one failure that
# looks exactly like a clean run (L42, L98), and what it was allowing is the loss of a day's work.
#
# What is refused is narrowed to what could be a payload write at all, by the raw payload text,
# because nothing here can read the path out of it: a gate that refused every Edit and every Bash
# call on such a machine is one nobody keeps (L36, L54). The questions that decide whether
# anything is at risk (is there a watcher, does it run from HERE, is it an own worktree, is a hold in
# force) are pure
# shell in lib/sync-clone.sh, so they are asked here exactly as they are below, and a machine where
# nothing could revert the write is not refused.
#
# The same refusal serves a payload python3 is present for and still cannot read (claude-config
# #1900): before it read its stdin in text mode, a byte that is not UTF-8 anywhere in the payload
# raised, the tool name came back as a dash, and the write was allowed. The readers now decode as jq
# does, so that byte is read, and whatever is left that they cannot read is refused here, never
# allowed (L1033). $1 is the paragraph saying why the call could not be read, with @WATCHER@ where
# it speaks of the watcher: which words go there is known only once the watcher has been read, a
# live one seen or one that could not be read either (claude-config#3547).
refuse_unread(){
  case "$payload" in *SKIP_PAYLOAD_WRITE_CHECK=1*) exit 0 ;; esac
  # After a call there is nothing left to refuse, and the check made then needs the note this
  # branch never took.
  after_call && exit 0
  case "$payload" in *payload/*) ;; *) exit 0 ;; esac
  unreadable_root="$(sc_clone_root_of "$PWD" 2>/dev/null || true)"
  sc_watcher_possible || exit 0
  if [ -n "$unreadable_root" ]; then
    sc_is_this_clone "$unreadable_root" "$SC_WATCHER_CMD" && exit 0
    sc_is_own_worktree "$unreadable_root" && exit 0
  fi
  sc_hold_covers "$sid" && exit 0
  watcher_seen || refuse_watcher_unread "a write that may be under a development checkout's payload/" "${1//@WATCHER@/$WATCHER_UNREAD_CLAUSE}"
  others_note "the second way below"
  cat >&2 <<MSG
claude-sync: REFUSED a write that may be under a development checkout's payload/.

${1//@WATCHER@/$WATCHER_SEEN_CLAUSE}

${OTHERS_NOTE}A watch daemon mirrors ~/.claude up over payload/ and pushes, so an edit made to payload/ in a development checkout is not merged with the config, it is overwritten by it, silently and with no conflict to notice. On 2026-09-03 it reverted 84 files of a day's work in one commit.

Two ways on, and the first needs nothing:

  1. Edit ~/.claude directly. That is the copy the daemon mirrors FROM, so nothing can revert it.
  2. Take a hold first, then edit here:

     claude-sync hold 120 "why you are editing the checkout"
MSG
  exit 2
}
if ps_reader_missing python3; then
  refuse_unread "$(ps_reader_absent_why "python3 is not on PATH" "payload-write-gate.sh reads which tool is being called and which files it would write with it, so with python3 absent it cannot tell a write under payload/ from any other write, and @WATCHER@." "python3")"
fi
UNREAD="payload-write-gate.sh could not read this tool call: the hook payload could not be read as JSON, so which tool is being called and which files it would write are unknown, and @WATCHER@. A payload this gate cannot read is not one with nothing in it, so the call is refused rather than allowed (claude-config#1900)."

# Read as jq reads it: a byte that is not UTF-8 becomes U+FFFD rather than raising, on the way in
# and on the way out (claude-config#1900).
fields="$(printf '%s' "$payload" | python3 -c '
import json, re, sys
sys.stdout.reconfigure(errors="replace")
d = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace"))
if not isinstance(d, dict):
    sys.exit(3)
def f(k):
    v = d.get(k) or "-"
    return re.sub(r"[\t\n]", " ", str(v))
print("\t".join([f("tool_name"), f("cwd"), f("hook_event_name"), f("tool_use_id")]))
' 2>/dev/null)" || refuse_unread "$UNREAD"
IFS=$'\t' read -r tool cwd event use_id <<EOF
$fields
EOF
[ "$cwd" = "-" ] && cwd="$PWD"

# WHERE this gate keeps the note of what payload/ held before a Bash call, read back after it
# (claude-config#647). One set of files per call, removed by the read, so what it keeps cannot grow
# with the number of calls (claude-config#603).
STATE_DIR="${PAYLOAD_WRITE_STATE_DIR:-$HOME/.claude-payload-write-gate}"
state_key="$(printf '%s' "$use_id" | tr -c 'A-Za-z0-9_.-' '_')"

# A call can end three ways besides succeeding, and each left its note behind until the day old sweep
# below took it (claude-config#3253): on 2026-11-18 the folder held 261 calls' notes, about 145 KB
# each, every one a call whose end never reached the read. A Bash call that exits non zero is reported
# as PostToolUseFailure, never PostToolUse, so it is read back the same way, since it can write before
# it fails (L480). A Monitor call runs the Bash hooks, so its note is taken, but returns as Monitor
# while its command runs on, so a read when it returns would judge a command that has barely started:
# its note is dropped. A call auto mode refuses before it runs is reported as PermissionDenied and
# has nothing to read back, so its note is dropped too. A refusal by another gate and an interrupt
# nothing reports reach no event, and Claude Code promises none for a refusal by a mod, so the day
# old sweep below is what removes those.
#
# THE PermissionDenied ARM SAYS NOTHING AND DECIDES NOTHING, and that is what lets it be here at all.
# tests/test-sleep-silence.sh holds every hook on that event to the sleep predicate or to an exempt
# entry, and this hook has the entry, which Dan signed off on 2026-11-19 for exactly this: it removes
# this gate's own note for the refused call and prints nothing. So the arm writes to neither stream
# (rm's own complaint included, since a note it cannot remove is the sweep's to take), never prints
# the JSON that would let the call be tried again, and touches only the note of a tool this gate
# takes one for. Anything more it came to say would need the predicate, and both suites run it to
# hold it to this.
case "$event" in
  PostToolUse|PostToolUseFailure)
    [ "$tool" = "Bash" ] || { [ "$use_id" = "-" ] || rm -f "$STATE_DIR/$state_key".*; exit 0; } ;;
  PermissionDenied)
    case "$tool" in
      Bash|Monitor) [ "$use_id" = "-" ] || rm -f "$STATE_DIR/$state_key".* 2>/dev/null ;;
    esac
    exit 0 ;;
esac

# AFTER a Bash call: what changed under a payload/ that was at risk while it ran (claude-config#647).
#
# The command text cannot show every write. A script FILE, a path a program builds at run time, a
# tool nobody listed: each writes where its words do not say, and on 2026-10-04 an agent's python
# edits to payload/mods went past this gate while its one shell redirect was refused. So whatever
# the words could not show is judged by the destination itself, after the fact. It cannot undo the
# write, so it says so plainly and names the one step that protects it now, rather than staying
# quiet about a write the daemon may revert (L11, L98).
if [ "$event" = "PostToolUse" ] || [ "$event" = "PostToolUseFailure" ]; then
  [ "$tool" = "Bash" ] || exit 0
  [ "$use_id" != "-" ] || exit 0
  roots_f="$STATE_DIR/$state_key.roots"
  list_f="$STATE_DIR/$state_key.list"
  [ -f "$roots_f" ] || exit 0
  changed=""
  while IFS= read -r root; do
    [ -n "$root" ] && [ -d "$root/payload" ] || continue
    # Written or replaced since the note: mtime for an edit, ctime for a move, which keeps the moved
    # file's old modification time and would read as untouched by mtime alone.
    changed="$changed$(find "$root/payload" -type f \( -newer "$roots_f" -o -cnewer "$roots_f" \) 2>/dev/null)
"
  done < "$roots_f"
  # Added or removed: the listing now against the listing then.
  now_list="$(while IFS= read -r root; do
    [ -n "$root" ] && [ -d "$root/payload" ] && find "$root/payload" -type f 2>/dev/null
  done < "$roots_f" | LC_ALL=C sort)"
  if [ -f "$list_f" ]; then
    changed="$changed$(printf '%s\n' "$now_list" | LC_ALL=C comm -3 - "$list_f" | sed 's/^[[:space:]]*//')"
  fi
  roots_list="$(cat "$roots_f")"
  # A linked worktree noted before the call whose folder is gone now was removed whole
  # (claude-config#3165, note_worktrees_before). Its files are not edits the daemon could revert,
  # since nothing is left there to revert, so they leave the report below; the ones that had
  # uncommitted changes when the call started are a loss, said apart in say_lost, with no hold
  # advised, since a hold cannot bring back a file that no longer exists. Everything else, the
  # primary checkout and a worktree still there included, is judged exactly as before.
  wt_f="$STATE_DIR/$state_key.wt"; dirty_f="$STATE_DIR/$state_key.dirty"
  gone=""
  if [ -f "$wt_f" ]; then
    while IFS= read -r wroot; do
      [ -n "$wroot" ] || continue
      [ -e "$wroot" ] || [ -L "$wroot" ] || gone="$gone$wroot
"
    done < "$wt_f"
  fi
  dirty_list="$(LC_ALL=C sort -u "$dirty_f" 2>/dev/null)"
  rm -f "$roots_f" "$list_f" "$wt_f" "$dirty_f"
  changed="$(printf '%s\n' "$changed" | sed '/^$/d' | LC_ALL=C sort -u)"
  lost=""
  if [ -n "$gone" ] && [ -n "$changed" ]; then
    # One pass over the list, never a process per file: a removed worktree is the whole payload/.
    in_gone="$(printf '%s\n' "$changed" | GONE="$gone" awk '
      BEGIN { n = split(ENVIRON["GONE"], g, "\n"); for (i = 1; i <= n; i++) if (g[i] != "") p[++m] = g[i] "/payload/" }
      { for (i = 1; i <= m; i++) if (index($0, p[i]) == 1) { print; next } }')"
    if [ -n "$in_gone" ]; then
      lost="$(LC_ALL=C comm -12 <(printf '%s\n' "$in_gone") <(printf '%s\n' "$dirty_list") | sed '/^$/d')"
      changed="$(LC_ALL=C comm -23 <(printf '%s\n' "$changed") <(printf '%s\n' "$in_gone") | sed '/^$/d')"
    fi
  fi
  say_lost(){   # $1 = the exit code when there is no loss to report
    if [ -z "$lost" ]; then exit "$1"; fi
    local ln shown_lost where
    ln="$(printf '%s\n' "$lost" | grep -c .)"
    shown_lost="$(printf '%s\n' "$lost" | awk 'NR <= 20 { print "  " $0 }')"
    [ "$ln" -gt 20 ] && shown_lost="$shown_lost
  ... and $((ln - 20)) more"
    # Only the worktrees a lost file was in: a clean one removed by the same command lost nothing.
    where="$(printf '%s\n' "$lost" | GONE="$gone" awk '
      BEGIN { n = split(ENVIRON["GONE"], g, "\n") }
      { for (i = 1; i <= n; i++) if (g[i] != "" && index($0, g[i] "/payload/") == 1 && !(g[i] in seen)) { seen[g[i]] = 1; o = o (o == "" ? "" : ", ") g[i] } }
      END { print o }')"
    [ "$1" -eq 0 ] || printf '\n' >&2
    cat >&2 <<MSG
claude-sync: $ln file(s) under payload/ had uncommitted changes when this command started, in a worktree whose folder is no longer there ($where):

$shown_lost

If the worktree was removed, those changes went with it, and a sync hold cannot bring them back. A change that was staged stays in the repository's objects until git next prunes them, and git fsck --lost-found lists it; one never staged is not in git at all.
MSG
    exit 2
  }
  [ -n "$changed" ] || say_lost 0
  # Protected since it ran: a hold of this session's own taken meanwhile, or the watcher gone, is
  # what makes it safe now. Another session's hold is not (claude-config#1886), and nor is a
  # watcher that could not be read just now, which is not one that has gone (claude-config#3547).
  # What the report says of the watcher is settled here, straight after the reading, so it claims a
  # live one only when one was seen (L11).
  sc_watcher_possible || say_lost 0
  sc_hold_covers "$sid" && say_lost 0
  if watcher_seen; then
    post_state="with a watch daemon live from another clone and no hold of this session's in force"
    post_daemon="The daemon mirrors ~/.claude up over payload/ and pushes, so these edits can be reverted silently, as 84 files were on 2026-09-03."
    post_probe=""
  else
    post_state="with no hold of this session's in force, and this gate could not read whether a watch daemon is live on this Mac"
    post_daemon="$(sc_watcher_unread_sentence) A live one mirrors ~/.claude up over payload/ and pushes, so these edits can be reverted silently, as 84 files were on 2026-09-03."
    post_probe="

To see why the watcher could not be read, run this in a terminal and fix what it reports:

     $SC_WATCHER_PROBE"
  fi
  # Left out: a file that already matches the installed config, which the daemon mirrors FROM, so
  # it has nothing to revert there (claude-config#1211). On 2026-10-15 a fast forward pull of the
  # checkout right after the same commit was installed listed 27 files, every one identical to its
  # installed copy, and a report wrong whenever a checkout catches up teaches skimming (L36). A
  # file matches when its bytes do, or when the only difference is the home placeholder the install
  # expands, and a removed one when the installed config lacks it too. Anything else is reported,
  # an installed copy merged with local settings included, since a match cannot be shown there.
  installed="${PAYLOAD_WRITE_INSTALLED_DIR:-$HOME/.claude}"
  differ=""; matched=0
  while IFS= read -r f; do
    rel=""
    while IFS= read -r root; do
      case "$f" in "$root/payload/"*) rel="${f#"$root/payload/"}"; break ;; esac
    done <<LOOP_INPUT
$roots_list
LOOP_INPUT
    inst="$installed/$rel"
    if [ -n "$rel" ] && {
      { [ ! -e "$f" ] && [ ! -e "$inst" ]; } ||
      { [ -f "$f" ] && [ -f "$inst" ] && { cmp -s "$f" "$inst" ||
        { [ -n "${HOME_TOKEN:-}" ] && grep -Iq -F -- "$HOME_TOKEN" "$f" 2>/dev/null &&
          home_detok "$installed" < "$f" | cmp -s - "$inst"; }; }; }
    }; then matched=$((matched + 1)); else differ="$differ$f
"; fi
  done <<LOOP_INPUT
$changed
LOOP_INPUT
  changed="$(printf '%s' "$differ" | sed '/^$/d')"
  [ -n "$changed" ] || say_lost 0
  n="$(printf '%s\n' "$changed" | grep -c .)"
  shown="$(printf '%s\n' "$changed" | awk 'NR <= 20 { print "  " $0 }')"
  [ "$n" -gt 20 ] && shown="$shown
  ... and $((n - 20)) more"
  [ "$matched" -gt 0 ] && shown="$shown

  $matched more already matched the installed config at $installed, so the daemon has nothing to revert there, and are left out."
  others_note "the command below"
  cat >&2 <<MSG
claude-sync: $n file(s) changed under a development checkout's payload/ while that command ran, $post_state. What was measured is what changed while it ran, so another session or a parallel command writing there at the same moment would show here too:

$shown

${OTHERS_NOTE}Nothing in the command's words showed those writes, so they could not be refused before it ran. $post_daemon Protect them now, before anything else:

     claude-sync hold 120 "why you are editing the checkout"

Then make ~/.claude match the checkout before the hold expires, or the next send reverts them.$post_probe
MSG
  say_lost 2
fi

# WHICH FILES this call would write. Two shapes, because two kinds of tool call write a file and
# only covering the first would leave the gate silent on the way most of this session's own edits
# were actually made (L247).
targets=""
case "$tool" in
  Edit|Write|MultiEdit|NotebookEdit)
    # A reader that fails here is refused rather than taken for a call that writes nothing
    # (claude-config#1900, L1033).
    targets="$(printf '%s' "$payload" | python3 -c '
import json, sys
sys.stdout.reconfigure(errors="replace")
d = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace"))
ti = d.get("tool_input") or {}
seen = []
for key in ("file_path", "notebook_path"):
    v = ti.get(key)
    if v:
        seen.append(v)
for e in (ti.get("edits") or []):
    v = (e or {}).get("file_path")
    if v:
        seen.append(v)
for v in seen:
    print(v)
' 2>/dev/null)" || refuse_unread "$UNREAD"
    ;;
  Bash)
    cmd="$(ps_parse_payload "$payload" raw 2>/dev/null)" || refuse_unread "$UNREAD"
    cmd="${cmd%%$'\x1f'*}"
    [ -n "$cmd" ] || exit 0
    # The documented override, honoured before anything else, so the person who has read the
    # message can get past it for one command.
    case "$cmd" in *SKIP_PAYLOAD_WRITE_CHECK=1*) exit 0 ;; esac
    # Nothing can revert anything with no watcher, so none of the reading below is paid for then.
    # Only when that is settled: a watcher that could not be read is read on (claude-config#3547).
    sc_watcher_possible || exit 0
    # Only the paths in a WRITE POSITION, never every payload path in a command that happens to
    # contain a redirect somewhere. The command cat payload/x 2>/dev/null holds both and writes nothing, and
    # reading is the overwhelming majority of what a session does in a checkout: a gate that refused
    # those would be turned off within the hour (L36, L104).
    #
    # Judged by the DESTINATION (claude-config#647): a relative path is resolved against where the
    # command actually runs, the session's directory or a cd earlier in the same command, so a
    # write made from inside payload/ counts whether or not its words say payload.
    targets="$(printf '%s' "$cmd" | GATE_CWD="$cwd" PS_SHELL_WORDS="$PS_SHELL_WORDS" python3 -B -c '
import importlib.util, os, re, sys

sys.stdout.reconfigure(errors="replace")
cmd = sys.stdin.buffer.read().decode("utf-8", "replace")
GIT_WRITERS = ("checkout", "restore", "rm", "mv")
# Which git subcommand a command runs is read by lib/shell-words.py (git_command), the one reading
# of git every gate asks (claude-config#1188): past assignments, rtk, env and sudo, and the options
# git takes itself. With that file missing, any command naming git and a subcommand that writes is
# taken for it, the reading that sees more writes, never fewer (L42).
try:
    _spec = importlib.util.spec_from_file_location("shell_words", os.environ["PS_SHELL_WORDS"])
    _sw = importlib.util.module_from_spec(_spec)
    _spec.loader.exec_module(_sw)
    git_command, GIT_VALUED = _sw.git_command, _sw.GIT_VALUED
except Exception:
    GIT_VALUED = {"-C"}
    def git_command(words):
        names = [w.lstrip("({").split("/")[-1] for w in words]
        for k, w in enumerate(words):
            if "git" in names and w in GIT_WRITERS:  # gh-reader: the crude reading, when there is no other
                return (w, [], words[k + 1:])
        return None
cwd = os.environ.get("GATE_CWD") or os.getcwd()
targets = []

# A directory only the shell can work out (a cd to a variable, or to an OLDPWD this cannot know) is
# kept as its words behind this mark, never taken for the directory it was moved from: that let a
# write after cd $P be judged where the session was and let through (claude-config#2128).
UNKNOWN = "\x00"
SHELL_VALUE = re.compile(r"\$[A-Za-z_{(0-9@*#?$!-]|`")
HOME = os.environ.get("HOME", "")

def place(tok, base):
    """Where tok names, read from base as the shell reads it: (path, True), or (its words, False)
    when only the shell can work it out. HOME is the same for this hook and the command, and PWD is
    the directory the command runs in, so both are expanded; any other value is not guessed at."""
    tok = tok.strip().strip("\"\x27")
    if not tok:
        return None, True
    if tok.startswith("~"):
        tok = os.path.expanduser(tok)
    if HOME:
        tok = re.sub(r"\$(?:HOME|\{HOME\})(?![A-Za-z0-9_])", lambda m: HOME, tok)
    known = not base.startswith(UNKNOWN)
    if known:
        tok = re.sub(r"\$(?:PWD|\{PWD\})(?![A-Za-z0-9_])", lambda m: base, tok)
    elif not tok.startswith("/"):
        return base[len(UNKNOWN):].rstrip("/") + "/" + tok, False
    if SHELL_VALUE.search(tok):
        return tok, False
    if not tok.startswith("/"):
        tok = os.path.join(base, tok)
    return os.path.normpath(tok), True

def resolve(tok, base):
    p, known = place(tok, base)
    if not p:
        return None
    if known:
        return p
    # A value only the shell knows. Counted only when its words name payload, as before, and then
    # judged as the payload write it may be, marked with a leading ? (claude-config#2128).
    # In any letter case: on a volume that does not tell case apart, PAYLOAD is the same folder
    # (claude-config#3537).
    return "?" + p if re.search(r"(^|/)payload(/|$)", p, re.I) else None

def move(dest, base):
    """Where a cd to dest leaves the commands after it: a path, or the words behind UNKNOWN."""
    if dest == "-":
        return UNKNOWN + "-"
    p, known = place(dest, base)
    if not p:
        return base
    return p if known else UNKNOWN + p.lstrip(UNKNOWN)

def unfolded(tok, base):
    """tok from base with its .. steps kept, when it has any and its place is known, or None. The
    reading above folds a/b/.. into a by its words; where b is a link to a folder elsewhere the
    system climbs out of THAT folder, so the path is also judged as written (claude-config#3537)."""
    if ".." not in re.split(r"/+", tok.strip().strip("\"\x27")):
        return None
    p, known = place(tok, base)
    if not p or not known:
        return None
    raw = tok.strip().strip("\"\x27")
    if raw.startswith("~"):
        raw = os.path.expanduser(raw)
    if HOME:
        raw = re.sub(r"\$(?:HOME|\{HOME\})(?![A-Za-z0-9_])", lambda m: HOME, raw)
    raw = re.sub(r"\$(?:PWD|\{PWD\})(?![A-Za-z0-9_])", lambda m: base, raw)
    return raw if raw.startswith("/") else os.path.join(base, raw)

def add(tok, base):
    p = resolve(tok, base)
    if p:
        targets.append(p)
        raw = unfolded(tok, base)
        if raw and raw != p:
            targets.append(raw)

# A quoted word in a script that writes, which may be a path and does not name payload: judged
# only by where it REALLY is, never by its words, so a link into payload or a file named by disk
# and file number is still seen (claude-config#3537). Behind this mark the step after this reading
# asks where it really is and drops it unless that is under a payload folder, cannot be read, or is
# a file with more than one name: the script may be writing there, as a quoted payload path is
# taken for a write. Text that only looks like a path ("text/plain", a web address) names nothing,
# which is an answer, so it refuses nothing.
MAYBE = "\x03"
def add_maybe(tok, base):
    p, known = place(tok, base)
    if p and known:
        raw = unfolded(tok, base)
        targets.append(MAYBE + (raw or p))

# Every line is read as shell, a heredoc body line included (Dan, 2026-11-02, "Also read heredoc
# text", claude-config#2080). A body is data the shell never runs, so the text a > b in one can be refused
# as a redirect; that was chosen over a reading of where a body ends that could ever hide a command
# after it, as the pattern this gate kept did with <<'E'OF, <<END-OF and a << inside a quoted string.
# Where a body really ends is read by lib/shell-words.py, below, for the commands the shell runs.
#
# Two narrowings. The single quoted arguments of a plain printf or echo (claude-config#3152,
# printed_as_text, below). And (Dan, 2026-11-11, the middle path, claude-config#2722): a body only cat or tee copies
# into files named on the command line is text, so the paths it names are not write targets. Where
# that command writes is still judged, from its own words, and the substitutions the shell runs in
# an unquoted body are still read as commands below. Every other consumer (a shell, sh -s, python,
# xargs, eval, a function, any command not known here) has its body read as before: a consumer that
# cannot be told is read. On 2026-11-10 a cat append to a session notes file was refused for the
# payload paths its text named in backticks.
# A command that could make cat or tee something else, or send what it writes on to a shell, is
# never narrowed: a function or alias of either, a change to PATH or the command hash, or a
# process substitution anywhere in it. Anywhere but the bodies being copied, when their end marker
# is quoted: the shell expands nothing in one, so its words define nothing. On 2026-11-11 a cat
# append to a session notes file was refused because its text said "function" (claude-config#2789).
# An unquoted body is expanded, so its words are still read.
NOT_A_PLAIN_COPY = re.compile(r"[<>]\(|\bfunction\b|\balias\b|\bhash\b|\b(?:PATH|path)\+?=|(?:^|[\s;&|(){}])(?:cat|tee)\s*\(\s*\)")

def copy_targets(text):
    """The files a cat or tee command copies its input into, from its own words, or [] when text is
    not such a command: cat with its output sent to a file, or tee naming one, and nothing else."""
    try:
        toks = _sw.shell_tokens(text)
    except Exception:
        return []
    if not toks or toks[0] not in ("cat", "tee"):
        return []
    head, files, to_file, i = toks[0], [], False, 1
    while i < len(toks):
        t = toks[i]
        if re.fullmatch(r"[0-9]*<<-?", t):          # the heredoc itself, and its end marker
            i += 2
            continue
        if t in (">", ">>", "1>", "1>>"):
            if i + 1 >= len(toks):
                return []
            files.append(toks[i + 1])
            to_file = True
            i += 2
            continue
        if re.fullmatch(r"(?:2>>?|[0-9]*<)", t):    # stderr, or an input, read as a redirect as ever
            i += 2
            continue
        if any(c in t for c in "<>&|;()`$"):
            return []                                # any other operator or value: cannot be told
        if head == "tee" and not t.startswith("-"):
            files.append(t)
        i += 1
    if head == "cat" and not to_file:
        return []
    return files

def copied_as_text(cmd):
    """cmd with the body of each heredoc only cat or tee copies into a named file blanked, its line
    breaks kept, or cmd unchanged wherever that cannot be read (claude-config#2722)."""
    if "<<" not in cmd or "\n" not in cmd:
        return cmd
    try:
        parts, spans, heredocs = [], [], []
        _sw.commands(cmd, heredocs=heredocs, parts=parts, spans=spans)
    except Exception:
        return cmd
    if len(heredocs) != len(spans):
        return cmd
    out, rest_of_it = list(cmd), list(cmd)
    for (opener, start, end), (quoted, _, _) in zip(spans, heredocs):
        part = next((p for p in parts if any(o[0] == opener for o in p["openers"])), None)
        # Only a command the session shell runs itself, its output not piped on to another.
        if part is None or part["scope"] != (0,) or part["how"] == "|":
            continue
        files = copy_targets(cmd[part["start"]:part["end"]])
        if not files:
            continue
        # A file it writes that the command names again anywhere else may be run (a script written
        # and then run), so that body is read.
        rest = cmd[:part["start"]] + cmd[part["end"]:start] + cmd[end:]
        if any(os.path.basename(f.rstrip("/")) in rest for f in files):
            continue
        for k in range(start, end):
            if out[k] != "\n":
                out[k] = " "
                if quoted:
                    rest_of_it[k] = " "
    if NOT_A_PLAIN_COPY.search("".join(rest_of_it)):
        return cmd
    return "".join(out)

# The single quoted arguments of printf and echo are text the command prints, as the body of a
# heredoc cat or tee copies is (claude-config#3152). The lines below read every line of a command as
# shell, so a quoted argument holding a line that began "> payload/..." was taken for a redirect: on
# 2026-11-17 a printf appending to a notes file was refused for one. Such text is blanked, its line
# breaks kept, only where nothing can run it: a printf or echo the session shell runs itself, at the
# top of the command, with nothing in the command piping, saving (printf -v, eval), redefining
# (a function, alias, hash or PATH change) or wrapping (a compound command, exec, coproc, a process
# substitution) anything, and every file it writes named plainly (no value or pattern only the shell
# can work out) and not named again in the command. Where it writes, and a
# redirect target written in quotes, are read as ever. Anything else keeps every line read. A
# backquote inside the single quotes is text too, so only one outside them keeps the lines read
# (claude-config#3184): Markdown text nearly always holds one.
PRINTER = re.compile(r"\s*(?:printf|echo)(?=\s|$)")
COMPOUND = re.compile(r"\s*(?:[{}]|then|do|done|fi|else|elif|if|while|until|for|case|esac|select|[A-Za-z_][A-Za-z0-9_-]*\s*\(\s*\))(?=\s|$|;|\()")
RUNS_TEXT = re.compile(r"\b(?:eval|exec|coproc)\b|(?:^|[\s;&|(){}])(?:printf|echo)\s*\(\s*\)")
UNREAD_FORMS = ("$(", "`", "${", "$\x27", "<(", ">(")

def single_quoted(text):
    """(start, end) of the inside of each single quoted string in text as bash reads it, leaving out
    the word after a redirection, or None when a quote never closes."""
    spans, i, n = [], 0, len(text)
    in_dq, target, seen = False, False, False
    while i < n:
        c = text[i]
        if in_dq:
            if c == "\\":
                i += 2
                continue
            if c == "\"":
                in_dq = False
            i += 1
            continue
        if c == "\\":
            seen = True
            i += 2
            continue
        if c in "<>":
            target, seen = True, False
            i += 1
            continue
        if c in " \t\n":
            if target and seen:
                target = False
            i += 1
            continue
        seen = True
        if c == "\"":
            in_dq = True
        elif c == "\x27":
            j = text.find("\x27", i + 1)
            if j < 0:
                return None
            if not target:
                spans.append((i + 1, j))
            i = j
        i += 1
    return spans

def written_files(text):
    """The files text redirects its output into, from its own words, or None when it cannot be read."""
    try:
        toks = _sw.shell_tokens(text)
    except Exception:
        return None
    return [toks[k + 1] for k in range(len(toks) - 1) if re.fullmatch(r"[0-9&]*>[>|&]?", toks[k])]

def printed_as_text(cmd):
    """cmd with the single quoted arguments of each plain printf or echo blanked, line breaks kept,
    or cmd unchanged wherever that cannot be read (claude-config#3152)."""
    if "\x27" not in cmd:
        return cmd
    try:
        parts = []
        _sw.commands(cmd, parts=parts)
    except Exception:
        return cmd
    if any(p["how"] == "|" or COMPOUND.match(cmd[p["start"]:p["end"]]) for p in parts):
        return cmd
    out = list(cmd)
    for p in parts:
        text = cmd[p["start"]:p["end"]]
        if p["scope"] != (0,) or p["inner"] or p["openers"] or not PRINTER.match(text):
            continue
        spans, files = single_quoted(text), written_files(text)
        if not spans or files is None:
            continue
        # A backquote inside single quotes is a character printed, not a substitution, so only one
        # outside them stops the text being read as text (claude-config#3184). The other forms are
        # looked for across the whole command, quotes included, as before.
        unquoted = list(text)
        for a, b in spans:
            unquoted[a:b] = " " * (b - a)
        if "`" in "".join(unquoted) or any(f in text for f in UNREAD_FORMS if f != "`") \
                or re.match(r"\s*printf(?:\s.*)?\s-v", text, re.S):
            continue
        # A file named by a value or a pattern only the shell can work out may be the one run after.
        if any(re.search(r"[$`*?\[]", f) for f in files):
            continue
        rest = cmd[:p["start"]] + cmd[p["end"]:]
        if any(os.path.basename(f.rstrip("/")) in rest for f in files):
            continue
        for a, b in spans:
            for k in range(p["start"] + a, p["start"] + b):
                if out[k] != "\n":
                    out[k] = " "
    narrowed = "".join(out)
    if NOT_A_PLAIN_COPY.search(narrowed) or RUNS_TEXT.search(narrowed):
        return cmd
    return narrowed

try:
    cmd = printed_as_text(cmd)
except Exception:
    pass

try:
    shell_text = copied_as_text(cmd)
except Exception:
    shell_text = cmd

# Commands whose arguments ARE what they write. Scanned per segment, in order, so a read in one
# segment is not blamed on a write in the next, and a cd moves where the rest resolve.
WRITERS = ("tee", "cp", "mv", "rm", "touch", "mkdir", "patch", "install", "rsync", "truncate",
           "ln", "link", "ditto", "unlink", "rmdir")
base = cwd
CD_TO = object()  # marks a segment that is a directory the commands after it run in
segments = re.split(r"&&|\|\||;|\||\n", shell_text)
# The commands a shell runs from its -c string, eval from its words and env -S from its string
# (claude-config#1478), read by lib/shell-words.py as commands of their own, each after a cd to the
# directory it runs in, so a cd inside one moves only what follows it there. Only added to the
# segments of the whole command above, which still read every line of it, heredoc bodies included,
# except a body only cat or tee copies into a named file, which is blank there (claude-config#2722),
# and the single quoted arguments of a plain printf or echo, blank the same way (claude-config#3152).
# So are the commands inside a substitution, which those segments never read as commands of their
# own, those in the body of a heredoc whose end marker is unquoted among them, since the shell runs
# them too (claude-config#2053). And with a heredoc, every command it runs, each in the directory it
# runs in: the segments above read a cd in a body as moving the commands after it, which the shell
# never does (claude-config#2080).
try:
    for d, text, _, _, depth in _sw.every_command(cmd):
        if depth > 0 or "$(" in cmd or "`" in cmd or "<<" in cmd:
            # The directory itself, never a cd segment: those are cut into words at each space,
            # so a checkout whose path holds one resolved against its first word (#2080). One the
            # reading could not work out is kept as its words, never as where the session is (#2128).
            segments += [(CD_TO, move(d, cwd) if d else cwd)] + re.split(r"&&|\|\||;|\||\n", text)
except Exception:
    # With no reading of the wrapped commands, a command naming a wrapper has every payload path it
    # holds taken for a write: the reading that sees more writes, never fewer (L42). So does one
    # with a heredoc, whose body lines the cut above reads as shell: a cd in a body moves the writes
    # after it there, and only this reading put them back where the shell runs them (#2080).
    # Each path is judged where the session is AND wherever any cd in the command could have left
    # it, since which of those it runs in cannot be read here (claude-config#2128).
    if "<<" in cmd or re.search(r"(^|[^A-Za-z0-9_.-])(bash|sh|zsh|dash|ksh|eval|env|find|watch|script|parallel)([^A-Za-z0-9_.-]|$)", cmd):
        bases, last = [cwd], cwd
        for m in re.finditer(r"(?:^|[\s;&|(])(?:cd|pushd)\s+([^\s;&|<>()]+)", cmd):
            last = move(m.group(1), last)
            bases += [move(m.group(1), cwd), last]
        for m in re.finditer(r"[^\s\"\x27;&|<>()]*(?i:payload)/[^\s\"\x27;&|<>()]*", cmd):
            for b in bases:
                add(m.group(0), b)
# An inline script that can write, and names a payload path. Most of this repo own payload edits
# are made this way, and the path is routinely held in a variable before it is opened, so the test
# is the script holding a payload path AND any writing call at all, not the two on one line.
WRITE_CALLS = (r"open\([^)]*,\s*[\"\x27][^\"\x27]*[wax+]", r"\.write_(text|bytes)\(",
               r"shutil\.(copy|copy2|copyfile|copytree|move|rmtree)\(",
               r"os\.(replace|rename|remove|unlink|makedirs|mkdir|rmdir)\(", r"\.unlink\(",
               r"\.rename\(", r"\.touch\(", r"writeFileSync|appendFileSync|File\.write")
# MAKING A LINK IS A WRITE (claude-config#3537). A hard link or a symbolic link is a second name
# for a payload file, and a write through that name names no payload folder. So the call that makes
# one is refused where its script names a payload path, as ln is among the commands below: os.link,
# os.symlink, a path object linking to or from another, the Sync forms node has, File and FileUtils
# in ruby, link and symlink called bare as perl and php call them, with or without brackets, and a
# script that runs ln itself. Never readlink or unlink, which hold the same letters: the first
# reads, and the second is in the list above.
LINK_CALLS = (r"\.(?:sym|hard)?link(?:Sync|_to)?\(",
              r"(?<![A-Za-z0-9_.])(?:sym)?link(?:Sync)?\(",
              r"File\.(?:sym)?link\b|FileUtils\.(?:ln|link|symlink)",
              r"(?:^|[\s;&|(])(?:perl|ruby|php)\b[^\n]*?(?<![A-Za-z0-9_.])(?:sym)?link\s+[\"\x27$@]",
              r"[\[(,]\s*[\"\x27]ln[\"\x27]\s*[,\])]")
WRITE_CALLS += LINK_CALLS
# A script that runs a copy, move or remove command from a list of words, as subprocess is given
# one (claude-config#3689): the first word of the list is the command, so a script holding one and
# naming a payload path is one that may write there, as a script running ln from a list is above.
WRITE_CALLS += (r"[\[(]\s*[\"\x27](?:[^\"\x27\s]*/)?(?:cp|mv|rm|tee|touch|mkdir|install|rsync|truncate|ditto|unlink|rmdir|link)[\"\x27]\s*,",)
# A script that runs ln as one string (os.system, subprocess, perl and ruby system, with or
# without brackets): the words of that string are what ln is given, so each is judged as a
# destination below, as the arguments of ln itself are. Only after a call that runs a command,
# never any quoted text starting with ln: a search of a payload file for those letters reads.
LN_STRING = r"(?:system|popen|Popen|exec[a-z]*|spawn[A-Za-z]*|run|call|check_call|check_output|getoutput)\s*\(?\s*[\"\x27](ln\s[^\"\x27]*)[\"\x27]"
WRITE_SCRIPT = any(re.search(p, shell_text) for p in WRITE_CALLS)
# payload in any letter case: a volume that does not tell case apart opens the same folder.
SCRIPT_PATH = r"[\"\x27]([^\"\x27\s]*(?i:payload)/[^\"\x27\s]*)[\"\x27]"
# Any other quoted word holding a slash, or starting at the home folder: it may be a path.
MAYBE_PATH = r"[\"\x27]((?:~|[^\"\x27\s]*/)[^\"\x27\s]*)[\"\x27]"
# The original single line form, kept: a literal opened for writing in place.
OPENED_PATH = r"open\(\s*([\"\x27][^\"\x27]+[\"\x27])\s*,\s*[\"\x27][wa]"

# A COMMAND STRING AN INLINE SCRIPT HANDS TO A SHELL IS A COMMAND (claude-config#3689).
#
# os.system, subprocess given one string, perl, ruby, php and awk system, node execSync: each runs
# the words of a quoted string as a shell command, and nothing above read them, because a quoted
# word with a space in it is no payload path to SCRIPT_PATH. LN_STRING read such a string for ln
# alone. On stand in files, a copy, a move, a remove and a redirect through a link were each let
# through from inside one.
#
# So the string is read the way a command typed directly is, by the same two readers and no third:
# it is cut into commands by lib/shell-words.py, the reader every gate shares, and each is judged by
# the loop below, the one that judges a typed command, in the directory the script runs in. The
# string is only ever ADDED to what is read: every segment read before is still read, so nothing
# refused before can be let through by this (L42).
#
# A string put together as the script runs is read as far as its words go, each value marked as
# one only the shell knows, so a path with one in it is judged as a typed path holding a variable
# is. Where the PROGRAM is a value (os.system(cmd), f"{tool} a b"), what will run cannot be told,
# and that is refused in its own words (UNTOLD) when the call names a payload/ path or runs inside
# one: the same narrowing an unreadable call gets above, so a script in another project that runs
# a value is not refused for a config it never touches.
#
# Held to a count: at most STRINGS_MAX strings are read from one command, a string inside a string
# included, and one more is refused as a command this gate could not finish reading.
UNTOLD = "\x04"
STRINGS_MAX = 256
SEP =r"&&|\|\||;|\||\n"
HOLE = "$_"
NAMES_PAYLOAD = r"(?i)(?:^|[^A-Za-z0-9_.-])payload/|/payload(?:$|[^A-Za-z0-9_.-])"
IN_PAYLOAD = r"(?i)(?:^|/)payload(?:/|$)"
QUOTE = r"(\\?(?:\"\"\"|\x27\x27\x27|[\"\x27]))"
RUN_NAME = (r"(?<![A-Za-z0-9_])(?:system|popen|Popen|exec[A-Za-z]*|spawn[A-Za-z]*|run|call|check_call"
            r"|check_output|getoutput|getstatusoutput|shell_exec|passthru|proc_open|do\s+shell\s+script)")
# A shell named as the first word of a list, with its -c: the word after is its command string.
SHELL_LIST = r"[\"\x27](?:[^\"\x27\s]*/)?(?:ba|z|da|k)?sh[\"\x27]\s*,\s*\[?\s*[\"\x27]-[a-z]*c[\"\x27]\s*,\s*"
# A string of up to STRING_CHARS characters, so that a quote that never closes costs each call that
# opens one a bounded search, never the rest of a long command. In the string, a backslash is only
# ever read together with the character after it, and anything else alone: were a backslash also
# readable alone, a run of them before a quote that never closes could be read in a number of ways
# that doubles every two characters, and the search would never end.
STRING_CHARS = 4000
RUN_STRING = re.compile(r"(?:" + RUN_NAME + r"\s*(\(?)\s*|" + SHELL_LIST + r")([rbuRBUfF]{0,2})" + QUOTE
                        + r"((?:\\.|(?!\3)[^\\]){0,%d}?)\3\s*(\.format\b|[+%%.])?" % STRING_CHARS, re.S)
# Where such a string OPENS. One that opens with more than STRING_CHARS characters after it and
# does not close within them is one the bound cut off: refused as untold, never let through unread
# (L42). Only then: in a shorter command a quote that never closes is no string a script runs, as
# the script would not parse, and is most often a quote of the shell read as one opening, the
# closing quote of grep -n "system" or "os.system(".
RUN_OPEN = re.compile(r"(?:" + RUN_NAME + r"\s*(\(?)\s*|" + SHELL_LIST + r")([rbuRBUfF]{0,2})" + QUOTE, re.S)
UNTOLD_LONG = ("payload-write-gate.sh could not tell what that string will run: it reads a command string an "
               "inline script hands to a shell only up to %d characters, and this one goes on past that "
               "without its quote closing." % STRING_CHARS)
# perl, ruby and php run a command written in backquotes, or after qx or %x. Read only in a command
# that runs one of them on an inline script, never wherever the word appears: a template string in
# node is written in backquotes too, and so is Markdown.
TICK_LANGUAGE = re.compile(r"(?:^|[^A-Za-z0-9_.-])(?:(?:perl|ruby)\s+(?:-\S+\s+)*-[A-Za-z0-9]*e"
                           r"|php\s+(?:-\S+\s+)*-r|(?:perl|ruby|php)\s+(?:-\S+\s+)*(?:-(?:\s|$)|<<))")
TICKED = re.compile(r"`([^`\n]+)`|(?:qx|%x)\s*[({\[<|/!]([^)}\]>|/!\n]+)[)}\]>|/!]")
# A call that hands a shell a value, where no string can be read at all. Never one whose value
# starts with a dot: os.system(...) is how prose writes the call.
RUN_VALUE = re.compile(
    r"(?<![A-Za-z0-9_])((?:os\.system|os\.popen|subprocess\.(?:run|call|check_call|check_output|Popen"
    r"|getoutput|getstatusoutput)|commands\.getoutput|child_process\.exec|execSync|execFileSync|spawnSync"
    r"|shell_exec|passthru|proc_open|system|popen)\s*\(\s*(?![rbuRBUfF]{0,2}\\?[\"\x27])(?!\[)"
    r"[^\s,).\"\x27][^,)\n]{0,60}\)?|system\s+[$@][A-Za-z_{][^\s;]{0,60})")
ALL_BASES = [cwd]
_last = cwd
for m in re.finditer(r"(?:^|[\s;&|(])(?:cd|pushd)\s+([^\s;&|<>()]+)", cmd):
    _last = move(m.group(1), _last)
    for b in (move(m.group(1), cwd), _last):
        if b not in ALL_BASES:
            ALL_BASES.append(b)

def untold(what, about, base):
    """Note a part of the command this gate could not tell the writes of, when the call names a
    payload path or runs inside a payload folder."""
    if re.search(NAMES_PAYLOAD, cmd) or re.search(IN_PAYLOAD, base.lstrip(UNKNOWN)):
        t = UNTOLD + re.sub(r"\s+", " ", what) + "\t" + re.sub(r"\s+", " ", about) + "\t"
        if t not in targets:
            targets.append(t)

UNTOLD_STRING = ("payload-write-gate.sh could not tell what that string will run: it is put together as the "
                 "script runs (a value, or a program word that is filled in), so a copy, move, redirect or "
                 "remove in it cannot be read from the command.")

def told(prefix, body, tail):
    """The readings of a string a script hands a shell: its words, with each value the script fills
    in marked as one only the shell knows, as written and with its escaped quotes undone."""
    outs = []
    b = re.sub(r"#\{[^{}\n]*\}", HOLE, body)
    if "f" in prefix.lower() or tail == ".format":
        b = re.sub(r"\{[^{}\n]*\}", HOLE, b)
    if tail == "%":
        b = re.sub(r"%(?:\([^)\n]*\))?[-0-9.]*[sdrif]", HOLE, b)
    for v in (b, re.sub(r"\\([\"\x27\\])", r"\1", b)):
        for w in ((v, v + HOLE) if tail in ("+", ".") else (v,)):
            if w not in outs:
                outs.append(w)
    return outs

def string_segments(text, b):
    """The segments of one command string, run in directory b: its own, cut as a typed command is,
    and those of each command a shell inside it runs, as the whole command has them above."""
    out = [(CD_TO, b)] + re.split(SEP, text)
    try:
        for d, inner, _, _, depth in _sw.every_command(text):
            if depth > 0 or "$(" in text or "`" in text or "<<" in text:
                out += [(CD_TO, move(d, b) if d else b)] + re.split(SEP, inner)
    except Exception:
        for m in re.finditer(r"[^\s\"\x27;&|<>()]*(?i:payload)/[^\s\"\x27;&|<>()]*", text):
            add(m.group(0), b)
    return out

def program_is_value(text):
    """Whether a command in text names its program by a value, so what runs cannot be told. A
    reading of it that fails is not one that found a program, so that cannot be told either (L11)."""
    try:
        for _, inner, _, why, _ in _sw.every_command(text):
            w = _sw.first_word(_sw.command_rest(inner)[0])[0]
            if (w and w[0] in "$`") or why == _sw.WHY_VARIABLE:
                return True
    except Exception:
        return True
    return False

strings_read = [0]
strings_ran = set()
def read_strings(text, bases, cut):
    """The segments to read for every command string in text that a script hands a shell. cut asks
    for the strings holding a command separator, which the cut into segments splits, and not cut
    for the rest, which a segment holds whole."""
    out = []
    # Whether a string whose program is a value is refused as untold: only one a call hands over in
    # brackets, a list naming a shell, or perl system and exec, which take none. A word such as run
    # or call straight before a quote is as often a shell function given a value, or prose, and a
    # string in backquotes as often a template: their words are read, and nothing more is claimed.
    found = [(m.group(2), m.group(4), m.group(5) or "", m.group(0),
              m.group(1) != "" or re.match(r"(?:system|exec)\b", m.group(0)) is not None)
             for m in RUN_STRING.finditer(text)]
    if TICK_LANGUAGE.search(cmd):
        found += [("", m.group(1) or m.group(2), "", m.group(0), False) for m in TICKED.finditer(text)]
    # A string the bound cut off (RUN_OPEN). Asked of the whole command only: a segment is cut at
    # every separator, those inside a string included, so in a segment a string that closes can look open.
    # And only of a string a call hands over, by the same test as a value above: a word such as run
    # before a quote is as often prose.
    if cut:
        for m in RUN_OPEN.finditer(text):
            if (len(text) - m.end() > STRING_CHARS and (m.group(1) != "" or re.match(r"(?:system|exec)\b", m.group(0)))
                    and RUN_STRING.match(text, m.start()) is None):
                for b in bases:
                    untold("a command string an inline script hands to a shell: " + m.group(0)[:80], UNTOLD_LONG, b)
    for prefix, body, tail, whole, called in found:
        if bool(re.search(SEP, body)) != cut:
            continue
        for s in told(prefix, body, tail):
            for b in bases:
                if (s, b) in strings_ran:
                    continue
                strings_ran.add((s, b))
                strings_read[0] += 1
                if strings_read[0] > STRINGS_MAX:
                    untold("a command holding more than %d command strings for a shell" % STRINGS_MAX,
                           "payload-write-gate.sh could not tell what all of them run: it reads at most "
                           "%d command strings an inline script hands to a shell from one command." % STRINGS_MAX, b)
                    return out
                out += string_segments(s, b)
                if called and program_is_value(s):
                    untold("a command string an inline script hands to a shell: " + whole[:80], UNTOLD_STRING, b)
    return out

try:
    for extra in read_strings(shell_text, ALL_BASES, True):
        segments.append(extra)
except Exception:
    untold("a command string an inline script hands to a shell", UNTOLD_STRING, cwd)

placed = set()
# The list grows as it is read: a command string found in a segment is added to its end, with the
# directory it runs in before it, and read in its turn (claude-config#3689, STRINGS_MAX).
for seg in segments:
    if isinstance(seg, tuple) and seg[0] is CD_TO:
        base = seg[1]
        continue
    # A redirect TARGET: the word after > or >> (or 2>, &>, a fd form), attached or separated.
    for m in re.finditer(r"(?:^|[^0-9<>&|])(?:[0-9]*|&)>>?\s*([^\s;&|<>]+)", seg):
        add(m.group(1), base)
    # A script opens a relative path from where it runs, which is where a cd earlier in the command
    # left it, not the session directory (claude-config#2128).
    for m in (re.finditer(SCRIPT_PATH, seg) if WRITE_SCRIPT else ()):
        add(m.group(1), base)
        placed.add(m.group(1))
    for m in (re.finditer(MAYBE_PATH, seg) if WRITE_SCRIPT else ()):
        if m.group(1) not in placed:
            add_maybe(m.group(1), base)
    for m in re.finditer(LN_STRING, seg):
        for w in m.group(1).split()[1:]:
            if not w.startswith("-"):
                add(w, base)
    try:
        segments += read_strings(seg, [base], False)
        for m in RUN_VALUE.finditer(seg):
            untold("a command an inline script hands to a shell as a value: " + m.group(1)[:80], UNTOLD_STRING, base)
    except Exception:
        untold("a command string an inline script hands to a shell", UNTOLD_STRING, base)
    for m in re.finditer(OPENED_PATH, seg):
        add(m.group(1), base)
        placed.add(m.group(1))
    words = seg.split()
    if not words:
        continue
    k = 0
    while k < len(words) and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", words[k]):
        k += 1
    if k >= len(words):
        continue
    # Past the launchers that run the command after them, sudo, env, nohup, timeout, xargs and the rest
    # (lib/shell-words.py RUNNERS, claude-config#1478), so sudo cp x payload/y is the copy it runs.
    try:
        past = _sw.command_rest(" ".join(words[k:]))[0].split() or words[k:]
    except Exception:
        past = words[k:]
    head = past[0].lstrip("(").rsplit("/", 1)[-1]
    args = past[1:]
    found = git_command(words[k:])
    if found:
        # Past the options git itself takes to the subcommand: -C names the directory the paths
        # resolve against, and the others that take a value are not the subcommand.
        gbase, (sub, front, rest) = base, found
        i = 0
        while i < len(front):
            if front[i] == "-C" and i + 1 < len(front):
                gbase = move(front[i + 1], gbase)
            i += 2 if front[i] in GIT_VALUED else 1
        if sub in GIT_WRITERS:
            # checkout and restore name a branch or commit before the -- separator, and only the paths
            # after it are rewritten; a bare git checkout main switches branches and names no path.
            if sub == "restore":
                # --staged alone rewrites the index, never the file; -s/--source names a commit.
                if ("--staged" in rest or "-S" in rest) and not ("--worktree" in rest or "-W" in rest):
                    rest = []
                kept, skip = [], False
                for w in rest:
                    if skip:
                        skip = False
                    elif w in ("-s", "--source"):
                        skip = True
                    elif w != "--":
                        kept.append(w)
                rest = kept
            elif sub == "checkout" and "--" in rest:
                rest = rest[rest.index("--") + 1:]
            elif sub == "checkout":
                rest = []
            for w in rest:
                if not w.startswith("-"):
                    add(w, gbase)
        continue
    if head in ("cd", "pushd"):
        dest = next((w for w in args if w == "-" or not w.startswith("-")), "~")
        base = move(dest, base)
        continue
    # A flag is never a path, so none is resolved against where the command runs.
    if head == "sed" and any(w == "-i" or w.startswith("-i") for w in args):
        for w in args:
            if not w.startswith("-"):
                add(w, base)
    elif head in ("perl", "ruby") and any(re.match(r"^-[A-Za-z]*i", w) for w in args):
        for w in args:
            if not w.startswith("-"):
                add(w, base)
    elif head == "dd":
        for w in args:
            if w.startswith("of="):
                add(w[3:], base)
    elif head in WRITERS:
        for w in args:
            if not w.startswith("-"):
                add(w, base)

# Read over the whole command too, for a script path the cut into segments split (a quoted path
# holding a ; or |): one no segment placed is judged where the session is, as it always was,
# rather than not at all (L42).
for m in (re.finditer(SCRIPT_PATH, shell_text) if WRITE_SCRIPT else ()):
    if m.group(1) not in placed:
        add(m.group(1), cwd)
for m in re.finditer(OPENED_PATH, shell_text):
    if m.group(1) not in placed:
        add(m.group(1), cwd)

# A LINK MADE BY A SCRIPT FILE THE COMMAND RUNS (claude-config#3689).
#
# Making a link is a write (#3537), read above from a command and from an inline script. A script
# FILE was read by nothing, so bash mk.sh, ./mk.sh and python3 mk.py made the second name unseen.
# Each script file the command runs is now read as it is on disk at this moment. A shell script is
# read by lib/shell-words.py, which already reads the script files a command runs for the other
# gates (its scripts list, claude-config#2301), a script it runs included; one larger than that
# reader takes is searched for its link commands as text. A python, perl, ruby, node or php script
# is searched for the calls that make a link, the ones LINK_CALLS and LN_STRING name for an inline
# script.
#
# ONLY a link is read from a file, and only where it can be PLACED. Every other write a script file
# makes is still caught after the call, by its destination, as before. A link whose path holds a
# value only the script knows is not judged here: the suites of this repository make such links in
# temporary folders by the hundred, and judging each as the payload write it may be would refuse
# running them. That is a choice left to Dan in the pull request of #3689.
#
# A script file that CANNOT BE READ (no file there now, a name holding a value, larger than
# FILE_MAX, not openable) is refused in its own words when the command names a payload/ path besides
# the script itself, or runs inside a payload folder. Only for a script the command itself runs,
# never one a script file runs. A file the command writes from a heredoc of its own is read from
# that text, which is in the command. A compiled program is no script and is left as it was.
#
# Held to a count: at most FILES_MAX script files are read here from one command.
#
# WHAT COUNTS IS A FILE THIS GATE GOES ON TO OPEN (claude-config#3775). The count went up for every
# occurrence of a script being run, before anything was known about the file: a name holding a
# value, which is never opened, a file that is not there, and the same file again. So a plain run
# of a test suite was refused at its ninth `bash "$HOOK"`, with no file opened for any of them. On
# 2026-11-26 on the personal MacBook that was 84 of the 410 suites of this repository and the
# whole run: 1,937 occurrences counted in them, 1,935 a name holding a value, and no file this
# loop would have opened had it gone on. Now a file is found first (file_found), and only one that
# is there to open is counted, once for each directory it is run in: a relative path in it lands
# somewhere else when it is run from somewhere else, so it is read again there, and that reading
# counts. What is not counted is treated as it was inside the first FILES_MAX: nothing is read
# from it, and a script the command itself runs that cannot be read keeps its refusal below.
# Carrying the loop on past those occurrences also reads the link commands after them, which the
# stop left unread.
FILE_MAX = 4 * 1024 * 1024
FILES_MAX = 8
MAYBE_MAX = 256
INTERPRETER = re.compile(r"(?:python[0-9.]*|perl|ruby|node|nodejs|php|deno|bun)\Z")
# The options each interpreter takes before its script file, since they differ: -I takes a folder
# in perl and ruby and nothing in python, and -c is an inline script in python, a check in node and
# a settings file in php. For each: the letters that end the options with an inline script or with
# no script file at all, the letters whose value is the rest of the word or else the next word, the
# letters whose value is the rest of the word alone, the long options that take the next word, and
# the long options that mean no script file is run.
INTERPRETER_OPTIONS = {
    "python": ("cm", "WX", "", ("--check-hash-based-pycs",), ()),
    "perl": ("eE", "I", "MmiFCDxV", (), ()),
    "ruby": ("e", "IrCE", "FixKTW", ("--encoding", "--external-encoding", "--internal-encoding"), ()),
    "node": ("epic", "r", "", ("--require", "--import", "--loader", "--experimental-loader", "--env-file", "--conditions"),
             ("--eval", "--print", "--check", "--interactive", "--test")),
    "php": ("rRBEaS", "dcz", "", ("--define", "--php-ini"), ("--run", "--interactive", "--server")),
}
BARE_LINK = r"(?<![A-Za-z0-9_.])(?:sym)?link\s+[\"\x27$@]"

def add_placed(tok, base):
    p, known = place(tok, base)
    if p and known:
        targets.append(p)
        raw = unfolded(tok, base)
        if raw and raw != p:
            targets.append(raw)

def interpreter_file(text):
    """(the interpreter, the script file it is given) for one command, or None: an inline script,
    a module, a script read from its input, or no interpreter at all."""
    try:
        words = _sw.shell_split(_sw.command_rest(text)[0])
    except Exception:
        return None
    if not words:
        return None
    head = words[0].rsplit("/", 1)[-1]
    if not INTERPRETER.match(head):
        return None
    kind = "python" if head.startswith("python") else "node" if head == "nodejs" else head
    ends, valued, glued, longs_valued, longs_end = INTERPRETER_OPTIONS.get(kind, ("", "", "", (), ()))
    k = 1
    if kind in ("deno", "bun"):
        # Their script follows the word run; any other first word is a command of the tool itself.
        if len(words) > 1 and not words[1].startswith("-") and "/" not in words[1] and "." not in words[1]:
            if words[1] != "run":
                return None
            k = 2
    while k < len(words):
        w = words[k]
        if _sw.REDIRECT_WORD.match(w):
            return None
        if w == "-" or w in ("--version", "--help") or w in longs_end:
            return None
        if w.startswith("--"):
            k += 2 if w in longs_valued else 1
            continue
        if w.startswith("-"):
            # A word of one letter options, read a letter at a time as the interpreter reads it: a
            # letter that ends them with an inline script or no script at all, one whose value is the
            # rest of the word or the next word, one whose value is the rest of the word alone.
            step = 1
            for j, c in enumerate(w[1:], 1):
                if c == "f" and kind == "php":
                    rest = w[j + 1:]
                    return (head, rest) if rest else ((head, words[k + 1]) if k + 1 < len(words) else None)
                if c in ends:
                    return None
                if c in valued:
                    step = 1 if w[j + 1:] else 2
                    break
                if c in glued:
                    break
            k += step
            continue
        return head, w
    return None

def file_found(tok, base):
    """(its full path, "") for a script file that is there to open now, or (its path as far as it
    can be told, why it cannot be read). Nothing is opened here."""
    p, known = place(tok, base)
    if not p or not known:
        return tok, "its name holds a value only the shell can work out"
    try:
        if not os.path.isfile(p):
            return p, "no file is there now"
        if os.path.getsize(p) > FILE_MAX:
            return p, "it is larger than %d MB" % (FILE_MAX // (1024 * 1024))
    except OSError as e:
        return p, e.strerror or "it could not be opened"
    return p, ""

def file_text(p):
    """(its text, "") for the script file at a full path file_found gave, as it is on disk now, or
    (None, why it could not be read)."""
    try:
        with open(p, "rb") as f:
            return f.read(FILE_MAX).decode("utf-8", "replace"), ""
    except OSError as e:
        return None, e.strerror or "it could not be opened"

def script_links(text, base, bare):
    """The links a python, perl, ruby, node or php script makes, from its text: each quoted payload
    path it names, and each other quoted path by where it really is, when it calls anything that
    makes a link; and the words of an ln command it runs as a string."""
    if any(re.search(p, text) for p in LINK_CALLS + ((BARE_LINK,) if bare else ())):
        named, n = set(), 0
        for m in re.finditer(SCRIPT_PATH, text):
            add_placed(m.group(1), base)
            named.add(m.group(1))
        for m in re.finditer(MAYBE_PATH, text):
            if m.group(1) in named:
                continue
            n += 1
            if n > MAYBE_MAX:
                untold("a script file naming more than %d paths beside a call that makes a link" % MAYBE_MAX,
                       "payload-write-gate.sh could not tell where all of them really are: it asks for at most %d." % MAYBE_MAX, base)
                break
            add_maybe(m.group(1), base)
    for m in re.finditer(LN_STRING, text):
        for w in m.group(1).split()[1:]:
            if not w.startswith("-"):
                add_placed(w, base)

def shell_links(text, base):
    """The words of one command of a shell script file when it is a link command, each placed."""
    try:
        words = _sw.shell_split(_sw.command_rest(text)[0])
    except Exception:
        words = text.split()
    if words and words[0].rsplit("/", 1)[-1] in ("ln", "link"):
        for w in words[1:]:
            if not w.startswith("-"):
                add_placed(w, base)

def heredoc_written():
    """The files this command writes from a heredoc of its own, whose text is in the command."""
    out = set()
    try:
        parts = []
        _sw.commands(cmd, heredocs=[], parts=parts, spans=[])
        for p in parts:
            if p["openers"]:
                for f in copy_targets(cmd[p["start"]:p["end"]]):
                    q, known = place(f, cwd)
                    if q and known:
                        out.add(q)
    except Exception:
        pass
    return out

RUNS_A_FILE = re.compile(r"(?:^|[\s;&|(){}\"\x27`])(?:(?:ba|z|da|k)?sh|source|\.|python[0-9.]*|perl|ruby|node|nodejs|php|deno|bun)(?:\s|$)|[^\s\"\x27=]*/[^\s\"\x27]*")
try:
    own = every = []
    read_by_reader = []
    if RUNS_A_FILE.search(cmd):
        cwd_abs = cwd if os.path.isabs(cwd) else ""
        own = _sw.every_command(cmd, cwd_abs)
        every = own
        if any(w and _sw.script_file(why) for _, _, w, why, _ in own):
            every = _sw.every_command(cmd, cwd_abs, read_by_reader)
    left = {}
    for d, text, _, _, depth in own:
        left[(d, text, depth)] = left.get((d, text, depth), 0) + 1
    files_read, unread, own_scripts = 0, [], []
    readings = set()
    for d, text, wrapper, why, depth in every:
        b = move(d, cwd) if d else cwd
        is_own = left.get((d, text, depth), 0) > 0
        if is_own:
            left[(d, text, depth)] -= 1
        else:
            # A command of a script file: only a link it makes is read.
            shell_links(text, b)
            script_links(text, b, bool(TICK_LANGUAGE.search(text)))
        path = _sw.script_file(why) if wrapper else None
        head = ""
        if path is None:
            found = interpreter_file(text)
            if not found:
                continue
            head, path = found
        elif _sw.compiled_program(path, d, wrapper):
            continue
        elif _sw.script_text(path, d, wrapper) is not None:
            if is_own:
                own_scripts.append(path)
            continue
        if is_own:
            own_scripts.append(path)
        full, why_not = file_found(path, b)
        body = None
        if not why_not:
            # Read once for each directory it is run in, and counted only now that it is there to
            # open (claude-config#3775).
            if (full, b) in readings:
                continue
            files_read += 1
            if files_read > FILES_MAX:
                untold("a command that runs more than %d script files" % FILES_MAX,
                       "payload-write-gate.sh could not tell what all of them do: it reads at most %d script files "
                       "of a command for the links they make." % FILES_MAX, b)
                break
            readings.add((full, b))
            body, why_not = file_text(full)
        if body is None:
            if is_own:
                unread.append((path, full, why_not, b))
            continue
        first = body.split("\n", 1)[0]
        if head or (first.startswith("#!") and not re.search(r"(?:^|[/\s])(?:ba|z|da|k)?sh(?:\s|$)", first[2:])):
            script_links(body, b, bool(re.search(r"perl|ruby|php", head or first)))
        else:
            # A shell script larger than the shared reader takes: its link commands, as text.
            for m in re.finditer(r"(?:^|[\n;&|({])[ \t]*(?:ln|link)[ \t]+([^\n;&|]+)", body):
                for w in m.group(1).split():
                    if not w.startswith("-"):
                        add_placed(w, b)
            script_links(body, b, False)
    if unread:
        rest_of_it = cmd
        for p in own_scripts:
            rest_of_it = rest_of_it.replace(p, " ")
        written = heredoc_written()
        for path, full, why_not, b in unread:
            if full in written:
                continue
            if re.search(NAMES_PAYLOAD, rest_of_it) or re.search(IN_PAYLOAD, b.lstrip(UNKNOWN)):
                t = UNTOLD + re.sub(r"\s+", " ", "a command that runs the script file %s, which this gate could not read" % full) \
                    + "\t" + re.sub(r"\s+", " ", "payload-write-gate.sh could not read the script file %s (%s), so a link or "
                    "a write it makes cannot be read from it, and the command names a payload/ path besides it or "
                    "runs inside a payload folder." % (full, why_not)) + "\t"
                if t not in targets:
                    targets.append(t)
except Exception:
    untold("a command whose script files this gate could not read",
           "payload-write-gate.sh could not tell which script files this command runs: the reading of them failed partway.", cwd)

seen = []
for t in targets:
    if t not in seen:
        seen.append(t)
print("\n".join(seen))
' 2>/dev/null)" || refuse_unread "payload-write-gate.sh read this command and then could not work out which files it writes: the reading of where a shell command writes failed partway, and @WATCHER@. A reading that failed is not one that found nothing, so the call is refused rather than allowed (claude-config#1900)."
    ;;
  *) exit 0 ;;
esac

# WHERE EACH DESTINATION REALLY IS (claude-config#3537).
#
# Everything below judged a destination by its text, and three kinds of text reach a payload file
# with no part of them under payload/: the volume folder with a disk number and a file number
# (/.vol/<disk>/<file>, which macOS resolves to the file itself), a symbolic link that lives
# elsewhere, and a hard link, a second name for the same file. So does the folder name in another
# letter case on a volume that does not tell case apart. Resolving the text the usual way leaves
# the first and the last exactly as written.
#
# So the system is asked: the destination is opened for nothing but its path (O_EVTONLY, which
# reads and writes nothing) and the kernel names the file it holds (fcntl F_GETPATH). That sees
# through the numbers, every link on the way, and the letter case. A destination not made yet is
# its nearest folder that exists, asked the same way, plus the rest; a link to a file not made yet
# is followed by hand. On a system without that call the links are followed by the usual resolving.
#
# Each destination is STILL judged by its text below, exactly as before, and its real path is
# judged as well, so this step can only add a refusal (L42). A real path is passed on only when it
# holds a folder named payload, the one thing the judging below can refuse, so a write anywhere
# else costs it nothing.
#
# Two answers are refused in their own words, while a watcher could revert the write and no hold
# covers this session: a real path that COULD NOT BE READ (links that never end, a folder this
# account may not look into, a numbered path it may not open), and a file with MORE THAN ONE NAME,
# since the kernel names only one of them and where the others are cannot be read. Neither is let
# through for want of an answer. A device, a pipe or a socket is none of these and is left to its
# text.
#
# Run only when there is something to resolve: never for a command that writes nothing, nor for
# one whose only destinations are the devices every command writes to, and never once it is
# settled that no watcher is live.
real_path_wanted(){
  local line
  while IFS= read -r line; do
    case "$line" in
      ""|"?"*|$'\x04'*|/dev/null|/dev/stdout|/dev/stderr|/dev/tty|/dev/fd/[0-9]*) ;;
      *) return 0 ;;
    esac
  done <<WANTED
$targets
WANTED
  return 1
}
refuse_real_step(){
  sc_hold_covers "$sid" && return 0
  local what="a write whose destination this gate could not read" about="payload-write-gate.sh could not read where this call's destinations really are: the step that asks the system for the real path of each one failed before it answered, so whether one of them is a file under a development checkout's payload/ by another name is unknown. A reading that failed is not one that found nothing, so the call is refused rather than allowed (claude-config#3537)."
  watcher_seen || refuse_watcher_unread "$what" "$about"
  others_note "the second way below"
  cat >&2 <<MSG
claude-sync: REFUSED $what.

$about A watch daemon is live on this Mac running from another clone. It mirrors ~/.claude up over payload/ and pushes, so an edit made to a development checkout's payload/ is overwritten by it, silently.

${OTHERS_NOTE}Two ways on:

  1. Edit ~/.claude directly. That is the copy the daemon mirrors FROM, so nothing can revert it.
  2. Take a hold first, then run this again:

     claude-sync hold 120 "why you are editing the checkout"
MSG
  exit 2
}
if real_path_wanted && sc_watcher_possible; then
  targets="$(printf '%s\n' "$targets" | GATE_CWD="$cwd" python3 -B -S -c '
import errno, fcntl, glob, os, re, stat, sys

sys.stdout.reconfigure(errors="replace")
cwd = os.environ.get("GATE_CWD") or os.getcwd()
ASK =sys.platform == "darwin"
F_GETPATH = getattr(fcntl, "F_GETPATH", 50)
O_EVTONLY = getattr(os, "O_EVTONLY", 0x8000)
UNREAD, NAMES, MAYBE, UNTOLD = "\x01", "\x02", "\x03", "\x04"
# A DESTINATION WRITTEN AS A PATTERN (claude-config#3689). rm pay*/hooks/x.sh names no payload
# folder and removes a payload file: the shell writes the pattern out as the files it matches, and
# the text judged here was the pattern. So a destination holding a pattern is written out the same
# way, as the files it matches at this moment and each word of a list in braces, and every one is
# judged as that file typed directly is. Held to a count: at most GLOB_MAX files are read from one
# pattern, and a pattern that expands to more, or holds ** and may reach any folder below, is one
# this gate could not tell, refused in its own words where its fixed part is in a checkout at risk.
GLOB_MAX = 512

def spelled(a):
    """a with each list in braces written out, or None past GLOB_MAX of them."""
    done, todo = [], [a]
    while todo:
        s = todo.pop()
        m = re.search(r"\{([^{}]*,[^{}]*)\}", s)
        if m is None:
            done.append(s)
        else:
            todo += [s[:m.start()] + alt + s[m.end():] for alt in m.group(1).split(",")]
        if len(done) + len(todo) > GLOB_MAX + 1:
            return None
    return done

def expanded(a):
    """(the files the pattern a matches at this moment, whether there are more than can be read)."""
    names = spelled(a)
    if names is None:
        return [], True
    found = []
    for n in names:
        if any(c in n for c in "*?["):
            try:
                for g in glob.iglob(n):
                    found.append(g)
                    if len(found) > GLOB_MAX:
                        return found, True
            except Exception:
                return found, True
        elif n != a:
            found.append(n)
            if len(found) > GLOB_MAX:
                return found, True
    return found, False

class Unread(Exception):
    pass

def asked(p):
    """The path the kernel gives for what p names, which exists."""
    if not ASK:
        return os.path.realpath(p)
    fd = os.open(p, O_EVTONLY | os.O_NONBLOCK)
    try:
        return os.fsdecode(fcntl.fcntl(fd, F_GETPATH, b"\0" * 1024).split(b"\0", 1)[0])
    finally:
        os.close(fd)

def real(p, depth=0):
    """(the real path of p, its stat or None when nothing is there yet), or (None, None) for a
    device, pipe or socket. Raises Unread with the reason when it cannot be read."""
    if depth > 40:
        raise Unread("its links never end")
    try:
        st = os.stat(p)
    except (FileNotFoundError, NotADirectoryError):
        st = None
    except OSError as e:
        # A name longer than any file can have names nothing, as text read for a redirect often
        # does: that is a settled answer, and its folder is asked instead.
        if e.errno != errno.ENAMETOOLONG:
            raise Unread(e.strerror or "it could not be looked at")
        st = None
    why = None
    if st is not None:
        if not (stat.S_ISREG(st.st_mode) or stat.S_ISDIR(st.st_mode)):
            return None, None
        try:
            return asked(p), st
        except OSError as e:
            why = e.strerror or "it could not be opened"
    # Nothing there yet, or something this account may not open: its folder, plus its name.
    p = p.rstrip("/") or "/"
    if p == "/":
        return "/", st
    head, leaf = os.path.split(p)
    try:
        lst = os.lstat(p)
    except (FileNotFoundError, NotADirectoryError):
        lst = None
    except OSError as e:
        if e.errno != errno.ENAMETOOLONG:
            raise Unread(e.strerror or "it could not be looked at")
        lst = None
    if lst is not None and stat.S_ISLNK(lst.st_mode):
        try:
            to = os.readlink(p)
        except OSError as e:
            raise Unread(e.strerror or "its link could not be read")
        parent, _ = real(head, depth + 1)
        if parent is None:
            return None, None
        return real(os.path.join(parent, to), depth + 1)
    parent, _ = real(head, depth + 1)
    if parent is None:
        return None, None
    out = os.path.normpath(os.path.join(parent, leaf))
    # A numbered path that exists and could not be opened has no folder to go by.
    if st is not None and (out == "/.vol" or out.startswith("/.vol/")):
        raise Unread(why or "it could not be opened")
    return out, st

out = []

def judge(a, line):
    """Add what the destination a really is to out: its real path when that is under a payload
    folder, or that it could not be read, or that it is a file with more than one name."""
    try:
        r, st = real(a)
    except Unread as e:
        # For a word that only may be a path too: a script that writes may be writing there, and
        # a word that names nothing never ends here, since nothing being there is an answer.
        out.append(UNREAD + a + "\t" + str(e))
        return
    except Exception as e:
        # Anything else that stops one destination being read is that destination unread, never
        # the whole step and never an answer.
        out.append(UNREAD + a + "\t" + (type(e).__name__ if not isinstance(e, RecursionError) else "its links never end"))
        return
    if r is None:
        return
    if "/payload/" in r + "/" and r != line:
        out.append(r)
    if st is not None and stat.S_ISREG(st.st_mode) and st.st_nlink > 1:
        out.append(NAMES + a + "\t" + str(st.st_nlink))

for line in sys.stdin.buffer.read().decode("utf-8", "replace").split("\n"):
    if not line:
        continue
    maybe = line.startswith(MAYBE)
    if not maybe:
        out.append(line)
    if line.startswith("?") or line.startswith("/dev/") or line.startswith(UNTOLD):
        continue
    t = line[1:] if maybe else line
    a = t if t.startswith("/") else os.path.join(cwd, t)
    judge(a, line)
    if maybe or not any(c in a for c in "*?[{"):
        continue
    # Written as a pattern: each file it matches at this moment is judged as that file typed directly is.
    found, more = expanded(a)
    if more or "**" in a:
        d = re.split(r"[*?\[{]", a, 1)[0].rsplit("/", 1)[0] or "/"
        while d != "/" and not os.path.isdir(d):
            d = os.path.dirname(d) or "/"
        why = "expands to more than %d files" % GLOB_MAX if more else "holds ** and may reach any folder below"
        out.append(UNTOLD + "a write to the pattern %s, which %s" % (a, why) + "\t"
                   + "payload-write-gate.sh could not tell where everything that pattern stands for really is: it reads "
                     "at most %d of the files a pattern expands to, and none below a **." % GLOB_MAX + "\t" + d)
    if not more:
        for g in found:
            judge(g, line)
seen = []
for t in out:
    if t not in seen:
        seen.append(t)
print("\n".join(seen))
' 2>/dev/null)" || refuse_real_step
fi

# Which clone each target is in, and whether that clone is at risk. Asked per target, because one
# command can name paths in two checkouts.
refuse_root=""
refuse_path=""
refuse_unplaced=""
refuse_real=""
refuse_untold=""
while IFS= read -r t; do
  [ -n "$t" ] || continue
  case "$t" in
    # A part of the command this gate could not tell the writes of (claude-config#3689): a command
    # string an inline script puts together as it runs, a script file it could not read, a pattern
    # with more files than it reads. Its three fields are what is refused, why it could not be
    # told, and for a pattern the folder its fixed part is in. Refused on the terms a path that
    # cannot be placed is, and for a pattern only where that folder is in a checkout at risk.
    $'\x04'*)
      sc_watcher_possible || continue
      sc_hold_covers "$sid" && continue
      untold_dir="${t##*$'\t'}"
      if [ -n "$untold_dir" ]; then
        root="$(sc_clone_root_of "$untold_dir")" || continue
        [ -n "$root" ] || continue
        sc_is_this_clone "$root" "$SC_WATCHER_CMD" && continue
        sc_is_own_worktree "$root" && continue
        sc_is_plain_copy "$root" && continue
      fi
      refuse_untold="${t#?}"; break ;;
    # A path only the shell can work out, whose words name payload/ (claude-config#2128). Which
    # checkout it lands in cannot be read, so it is judged as the payload write it may be: refused
    # while a watcher could revert it, unless this session holds the watcher off. Never let through
    # for want of a place to judge it, which is what every such path was before.
    "?"*)
      sc_watcher_possible || continue
      sc_hold_covers "$sid" && continue
      refuse_unplaced="${t#?}"; break ;;
    # A destination whose real path could not be read, or a file with more than one name
    # (claude-config#3537): where it lands is unknown, so it is refused on the same terms.
    $'\x01'*|$'\x02'*)
      sc_watcher_possible || continue
      sc_hold_covers "$sid" && continue
      refuse_real="$t"; break ;;
    # A word that only may be a path, left unresolved because the watcher went between two
    # readings of it: with no watcher nothing below would refuse it either.
    $'\x03'*) continue ;;
    /*) ;;
    *)  t="$cwd/$t" ;;
  esac
  # Judged from the nearest directory that exists: one a command is about to make (mkdir -p, a copy
  # into a new folder) cannot be entered, and was skipped unjudged when this read only the target's
  # own directory (claude-config#2128).
  d="$(dirname "$t")"
  while [ ! -d "$d" ] && [ "$d" != "/" ] && [ "$d" != "." ]; do d="$(dirname "$d")"; done
  root="$(sc_clone_root_of "$d")" || continue
  [ -n "$root" ] || continue
  # Only payload/ is mirrored. An edit to claude-sync itself, or to tests/, is this checkout's own
  # work and the daemon never touches it. The part of the path below that directory is kept, so a
  # target that IS payload/, or a folder in it not made yet, is still read as under payload/.
  case "$(cd "$d" 2>/dev/null && pwd -P)${t#"$d"}/" in "$root/payload/"*) ;; *) continue ;; esac
  # The reading that refuses is the LAST one made: the loop leaves on the first refusal, so what
  # the refusal below says of the watcher is this target's (claude-config#3547).
  sc_watcher_possible || continue                  # settled that no watcher is live: nothing can revert anything
  sc_is_this_clone "$root" "$SC_WATCHER_CMD" && continue   # a watcher seen running from HERE: this is its source
  sc_is_own_worktree "$root" && continue          # a linked worktree on its own branch (#800)
  sc_is_plain_copy "$root" && continue            # a copy with no repository around it (#2705)
  sc_hold_covers "$sid" && continue                # held off by THIS session, or a terminal (#1886)
  refuse_root="$root"; refuse_path="$t"; break
done <<TARGETS
$targets
TARGETS

# BEFORE a Bash call it let through: a note of what each at risk payload/ holds, for the check after
# it to compare against (claude-config#647). Taken only in the state that loses work, a live watcher
# from another clone, or one that could not be read and so has no clone passed as its source
# (claude-config#3547), and no hold covering this session (the same question the refusal asks, so a
# call let through on another session's hold still has its note, claude-config#1886), and only for
# the checkouts this command could reach: the one it runs in, and any its words name. Two finds
# over a few hundred files, never one process per file.
note_payload_before(){
  local roots="" dir root
  [ "$tool" = "Bash" ] && [ "$use_id" != "-" ] || return 0
  # Taken for a watcher that could not be read as for a live one, with no clone passed as its
  # source, so the check after the call still has its note (claude-config#3547).
  sc_watcher_possible || return 0
  sc_hold_covers "$sid" && return 0
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    root="$(sc_clone_root_of "$dir" 2>/dev/null)" || continue
    [ -n "$root" ] || continue
    sc_is_this_clone "$root" "$SC_WATCHER_CMD" && continue
    sc_is_own_worktree "$root" && continue    # nothing mirrors into it, so nothing to report (#800)
    sc_is_plain_copy "$root" && continue      # nor into a copy with no repository (#2705)
    case "
$roots
" in *"
$root
"*) continue ;; esac
    roots="${roots:+$roots
}$root"
  done <<DIRS
$cwd
$(printf '%s\n' "$targets" | sed -n 's#/[^/]*$##p')
$(printf '%s' "$cmd" | grep -oE "/[^[:space:]\"']*/payload/" | sed 's#/payload/$##' | LC_ALL=C sort -u)
DIRS
  [ -n "$roots" ] || return 0
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  # A call another gate refused never reaches the check after it, so its note is left behind. One
  # find clears every such note older than a day, so the directory cannot grow with refusals. Not
  # sooner: a note is needed until its own call ends, and the longest call in a week of this Mac's
  # transcripts (2026-11-19) returned 258 minutes after it was issued, waiting on a prompt
  # (claude-config#3253). A shorter window would drop that note and its check with it (L174).
  find "$STATE_DIR" -type f -mmin +1440 -delete 2>/dev/null
  # The roots file is written FIRST: its time is what "changed since" is measured from.
  printf '%s\n' "$roots" > "$STATE_DIR/$state_key.roots" || return 0
  printf '%s\n' "$roots" | while IFS= read -r root; do
    find "$root/payload" -type f 2>/dev/null
  done | LC_ALL=C sort > "$STATE_DIR/$state_key.list"
  note_worktrees_before
  return 0
}

# A LINKED worktree's uncommitted payload files, noted before the call, so that the check after it
# can tell a worktree the command removed whole from edits at risk (claude-config#3165). On
# 2026-11-17 a git worktree remove of a detached worktree of main was reported as 1398 files changed
# under payload/, with a 120 minute hold advised before anything else, when every one was a
# committed file ceasing to exist with its worktree. A folder that is gone holds nothing for the
# daemon to revert, but a file in it that was never committed is lost, and only a note taken BEFORE
# the call can say which those were. So for each linked worktree among the roots, one line in .wt
# naming it, and every file git status lists under its payload/ in .dirty: modified, staged or
# untracked. Ignored files are left out, by the repository's own rules of what is not its work
# (bytecode caches, .DS_Store, a Mac's own *.local.json the sync never carries). A worktree git
# cannot answer for gets no .wt line, so its files are judged after the call exactly as before (L42).
# The primary checkout is never noted here: only a linked worktree is ever read as removed whole.
note_worktrees_before(){
  local root top line skip=""
  : > "$STATE_DIR/$state_key.wt" || return 0
  : > "$STATE_DIR/$state_key.dirty" || return 0
  printf '%s\n' "$roots" | while IFS= read -r root; do
    [ -n "$root" ] || continue
    sc_is_linked_worktree "$root" || continue
    top="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)" || continue
    [ "$(cd "$top" 2>/dev/null && pwd -P)" = "$root" ] || continue
    # -z, so no path comes back quoted; a rename or copy carries its old path as one more field,
    # skipped. Into a file first, so a git that fails is seen by its exit code.
    git -C "$root" status --porcelain=v1 -z --untracked-files=all --ignored=no -- payload \
      > "$STATE_DIR/$state_key.st" 2>/dev/null || continue
    tr '\0' '\n' < "$STATE_DIR/$state_key.st" | while IFS= read -r line; do
      if [ -n "$skip" ]; then skip=""; continue; fi
      case "$line" in [RC]?\ *|?[RC]\ *) skip=1 ;; esac
      [ "${#line}" -gt 3 ] && printf '%s/%s\n' "$root" "${line:3}"
    done >> "$STATE_DIR/$state_key.dirty"
    printf '%s\n' "$root" >> "$STATE_DIR/$state_key.wt"
  done
  rm -f "$STATE_DIR/$state_key.st"
  return 0
}

if [ -n "$refuse_real" ]; then
  real_body="${refuse_real#?}"
  real_dest="${real_body%%$'\t'*}"
  real_detail="${real_body#*$'\t'}"
  case "$refuse_real" in
    $'\x01'*)
      real_what="a write to $real_dest: this gate could not read where it really is"
      real_about="The system was asked for the real path of that destination and gave none ($real_detail), so whether it is a file under a development checkout's payload/ by another name (a link, or a path by disk and file number) is unknown. A destination that cannot be read is judged as the payload write it may be, never let through (claude-config#3537)." ;;
    *)
      real_what="a write to $real_dest, a file with more than one name"
      real_about="That file has $real_detail names (hard links) and the system gives only the one written here, so whether another of them is under a development checkout's payload/ cannot be read. A write through one name changes the file under all of them, so it is judged as the payload write it may be, never let through (claude-config#3537)." ;;
  esac
  watcher_seen || refuse_watcher_unread "$real_what" "$real_about"
  others_note "the second way below"
  cat >&2 <<MSG
claude-sync: REFUSED $real_what.

$real_about A watch daemon is live on this Mac running from another clone. It mirrors ~/.claude up over payload/ and pushes, so an edit made to a development checkout's payload/ is overwritten by it, silently.

${OTHERS_NOTE}Two ways on:

  1. Edit ~/.claude directly. That is the copy the daemon mirrors FROM, so nothing can revert it.
  2. Take a hold first, then run this again:

     claude-sync hold 120 "why you are editing the checkout"
MSG
  exit 2
fi

if [ -n "$refuse_untold" ]; then
  untold_what="${refuse_untold%%$'\t'*}"
  untold_about="${refuse_untold#*$'\t'}"
  untold_about="${untold_about%%$'\t'*}"
  untold_way="Run the command directly, where this gate can read it: the copy, move, redirect, remove or link itself as a shell command, with its paths written out in full."
  watcher_seen || refuse_watcher_unread "$untold_what" "$untold_about What this gate cannot tell is judged as the payload write it may be, never let through (claude-config#3689). $untold_way"
  others_note "the third way below"
  cat >&2 <<MSG
claude-sync: REFUSED $untold_what.

$untold_about A watch daemon is live on this Mac running from another clone. It mirrors ~/.claude up over payload/ and pushes, so an edit made to a development checkout's payload/ is overwritten by it, silently. What this gate cannot tell is judged as the payload write it may be, never let through (claude-config#3689).

${OTHERS_NOTE}Three ways on:

  1. $untold_way
  2. Edit ~/.claude directly. That is the copy the daemon mirrors FROM, so nothing can revert it.
  3. Take a hold first, then run this again:

     claude-sync hold 120 "why you are editing the checkout"
MSG
  exit 2
fi

if [ -n "$refuse_unplaced" ]; then
  watcher_seen || refuse_watcher_unread "a write to $refuse_unplaced, a path only the shell can work out" "Its words name payload/, but they hold a value this gate cannot read (a variable, a command's output, or a cd to one of those), so which checkout it lands in is unknown. A path that cannot be placed is judged as the payload write it may be, never let through (claude-config#2128). Writing the path out in full lets it be judged where it really lands."
  others_note "the third way below"
  cat >&2 <<MSG
claude-sync: REFUSED a write to $refuse_unplaced, a path only the shell can work out.

Its words name payload/, but they hold a value this gate cannot read (a variable, a command's output, or a cd to one of those), so which checkout it lands in is unknown, and a watch daemon is live on this Mac running from another clone. That daemon mirrors ~/.claude up over payload/ and pushes, so an edit made to a development checkout's payload/ is overwritten by it, silently. A path that cannot be placed is judged as the payload write it may be, never let through (claude-config#2128).

${OTHERS_NOTE}Three ways on:

  1. Write the path out in full, so it can be judged where it really lands.
  2. Edit ~/.claude directly. That is the copy the daemon mirrors FROM, so nothing can revert it.
  3. Take a hold first, then edit here:

     claude-sync hold 120 "why you are editing the checkout"
MSG
  exit 2
fi

if [ -z "$refuse_root" ]; then
  note_payload_before
  exit 0
fi

watcher_seen || refuse_watcher_unread "a write to $refuse_path" "This is a development checkout at $refuse_root."
others_note "the second way below"
cat >&2 <<MSG
claude-sync: REFUSED a write to $refuse_path.

This is a development checkout at $refuse_root, and a watch daemon is live on this Mac running from another clone. That daemon mirrors ~/.claude up over payload/ and pushes, so an edit made to payload/ here is not merged with the config, it is overwritten by it, silently and with no conflict to notice. On 2026-09-03 it reverted 84 files of a day's work in one commit and deleted a file that existed only in the repo.

${OTHERS_NOTE}Two ways on, and the first needs nothing:

  1. Edit ~/.claude directly. That is the copy the daemon mirrors FROM, so nothing can revert it.
  2. Take a hold first, then edit here:

     claude-sync hold 120 "why you are editing the checkout"

A hold expires. When it does, make ~/.claude match what is in the checkout, or the next send reverts it again.
MSG
exit 2
