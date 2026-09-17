#!/usr/bin/env bash
#
# sync-stuck-notice.sh: say, in the session, when the automatic config sync has been stuck for a
# long time, and say again when it clears (claude-config#391).
#
# On 2026-09-17 Dans-MacBook-Pro skipped 57 sends in a row over 11 hours and refused 52 receives,
# because the newest shared commit was red in CI and the clone was behind. Edits to CLAUDE.md, hooks
# and lessons made in that window existed on one Mac only, and nothing said so: it was found only
# because `claude-sync status` happened to be run while investigating something else. The detection
# existed. The delivery did not, and a number nobody is shown is not a detector (L357).
#
# So this runs on UserPromptSubmit, which is where a person working is, and asks the clone that runs
# the automatic sync whether it is stuck.
#
# IT COPIES NO PREDICATE. It runs `claude-sync stuck`, which is the function `claude-sync status`
# prints its "sending is stuck" and "receiving is stuck" lines from, so the notice and status cannot
# disagree about what stuck means (L41, L370). A new kind of stuck added there reaches this hook with
# nothing here to change.
#
# CHEAP, because it runs on every prompt in every project. No network and no CI query: `stuck` reads
# the two small records the sync already keeps (.behind-skips and .ci-red-since) and takes no lock,
# so it never waits on a watcher that is busy (L110). Measured 2026-09-17 on this Mac over 20 prompts
# each: 70ms per prompt with one clone to ask (75ms while a stuck stretch is on record), and 16ms on
# a Mac with no automatic sync installed, which never starts claude-sync at all. Most of the 70 is
# bash reading claude-sync itself. A fast path that skipped the tool when neither record file exists
# would save that on the healthy day, and was deliberately not taken: it would put the names of the
# records in this file, so a third kind of stuck added to the tool would be skipped here in silence
# on exactly the day it mattered (L289).
#
# WHICH clone: the ones the launch agents run, read from the plists the installer writes, because
# those name the script each automatic job runs (the same derivation status uses, L41). A clone
# nobody runs automatically is not "the sync": a development checkout keeps whatever record its last
# hand run left, and treating that as a stalled sync would speak in every session about something a
# person already watched happen. No automatic job installed means nothing runs unattended, so there
# is nothing that can be stuck without somebody watching the run that stuck, and it says nothing.
#
# ONCE PER STRETCH, PER SESSION. A stretch is keyed on its clone, its direction and the moment it
# started, which the sync records and keeps for as long as the condition lasts. A count going up is
# the same stretch and is not said again; a record that went away and came back is a new one. Per
# session rather than once per Mac, because a session that was never told has not been told, and the
# edits at risk are the ones made in whichever session is open. A notice on every prompt would be the
# noise this exists to prevent (L36).
#
# ITS END IS SAID TOO, once, in each session that heard it begin, so the stretch visibly ends rather
# than being assumed to (L160). Only when the clone was actually asked and answered: a clone that
# could not be asked has told us nothing about recovery (L11).
#
# FAILS LOUD, NOT NOISY. A record that is there and cannot be read, a stretch whose start cannot be
# read, and a clone that cannot be asked are each said once, in their own words, because each is a
# sync nobody can vouch for and none of them is a healthy one (L98). A payload with no session is
# the one case said only on stderr, which the person does not see: without a session a first prompt
# cannot be told from a later one, and guessing would mean speaking on every prompt.
#
# Env:
#   SYNC_STUCK_NOTICE_AFTER      seconds a stretch must have lasted before it is said (default 3600)
#   SYNC_LAUNCHAGENTS            where the launch agents are (default ~/Library/LaunchAgents)
#   CLAUDE_SYNC_STUCK_STATE_DIR  where each session's record of what it was told is kept (default
#                                TMPDIR). Losing it costs one repeated notice and nothing else.
#   CLAUDE_SYNC_STUCK_NOW        the clock, as an epoch, so a test can cross the threshold without
#                                waiting for it (L290)
set -uo pipefail

input="$(cat 2>/dev/null || true)"

# The session, matched in bash rather than by starting python, because this runs on every prompt.
session=""
re_sid='"session_id"[[:space:]]*:[[:space:]]*"([^"]+)"'
re_tp='"transcript_path"[[:space:]]*:[[:space:]]*"([^"]+)"'
if [[ $input =~ $re_sid ]]; then session="${BASH_REMATCH[1]}"
elif [[ $input =~ $re_tp ]]; then session="${BASH_REMATCH[1]}"
fi
if [ -z "$session" ]; then
  echo "sync-stuck-notice: the hook payload carried neither a session id nor a transcript path, so a first prompt cannot be told from a later one and the sync was not checked." >&2
  exit 0
fi
key="${session//[^A-Za-z0-9_-]/_}"
[ "${#key}" -le 120 ] || key="${key: -120}"

# ONE HOUR, and a chosen number rather than a measurement. It has to sit above an ordinary wait on
# CI, which is one run of five to eight minutes (gh run list, 2026-09-17) and routinely two when a
# push lands behind another, so a normal push never reaches it. It has to sit well below a working
# day, because what it protects is edits made while the stretch lasts: on 2026-09-17 that was eleven
# hours. An hour is also the window the sync already waits before escalating a red shared repo to a
# desktop notification (SYNC_CI_RED_ALERT_AFTER), so the session hears it when the desktop does.
# Being wrong costs an hour of edits on one Mac in one direction, and one notice about a stretch that
# was about to clear in the other.
after="${SYNC_STUCK_NOTICE_AFTER:-3600}"
case "$after" in
  ''|*[!0-9]*)
    echo "sync-stuck-notice: SYNC_STUCK_NOTICE_AFTER='$after' is not a whole number of seconds, so the default of 3600 is used instead." >&2
    after=3600 ;;
esac
now="${CLAUDE_SYNC_STUCK_NOW:-}"
case "$now" in ''|*[!0-9]*) now="$(date +%s)" ;; esac

# The clones the automatic jobs run, from the plists that name them.
agentdir="${SYNC_LAUNCHAGENTS:-$HOME/Library/LaunchAgents}"
re_script='<string>(/[^<]*)/claude-sync</string>'
clones=""
for plist in "$agentdir"/com.claudesync.*.plist; do
  [ -f "$plist" ] || continue
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ $line =~ $re_script ]]; then
      c="${BASH_REMATCH[1]}"
      case "
$clones
" in *"
$c
"*) ;; *) clones="${clones:+$clones
}$c" ;; esac
    fi
  done < "$plist"
done

STATE_DIR="${CLAUDE_SYNC_STUCK_STATE_DIR:-${TMPDIR:-/tmp}}"
mkdir -p "$STATE_DIR" 2>/dev/null || true
STATE="$STATE_DIR/claude-sync-stuck-${key}.state"
ERRF="$STATE.err"

# What this session has been told: one line per stretch, clone TAB kind TAB start.
told=""
[ -f "$STATE" ] && told="$(cat "$STATE" 2>/dev/null || true)"
[ -n "$clones" ] || [ -n "$told" ] || exit 0

T=$'\t'
keep=""
notices=""
in_list(){ # in_list <newline list> <line>
  case "
$1
" in *"
$2
"*) return 0 ;; esac
  return 1
}
remember(){ in_list "$keep" "$1" || keep="${keep:+$keep
}$1"; }
say(){ notices="${notices:+$notices

}$1"; }

while IFS= read -r clone; do
  [ -n "$clone" ] || continue
  sync="$clone/claude-sync"
  # A plist naming a script that is not there is a broken job, which status reports. It is not a
  # stuck sync, and saying so here would put a second fault in the middle of this one.
  [ -f "$sync" ] || continue
  recs="$(SYNC_REPO="$clone" SYNC_NO_NOTIFY=1 "$sync" stuck 2>"$ERRF")"; rc=$?
  if [ "$rc" -ne 0 ]; then
    entry="$clone${T}unavailable$T"
    if ! in_list "$told" "$entry"; then
      err="$(cat "$ERRF" 2>/dev/null || true)"
      case "$err" in
        *"unknown command 'stuck'"*)
          say "claude-sync: whether the automatic config sync has stalled cannot be checked, because the clone it runs from, $clone, does not have the 'stuck' command yet. That clone updates itself on its own schedule and this config reached this Mac first, so it should clear by itself; run 'claude-sync pull' from that clone to hurry it." ;;
        *)
          err="${err%%$'\n'*}"
          say "claude-sync: whether the automatic config sync has stalled cannot be checked, because asking the clone it runs from, $clone, failed (exit $rc): ${err:0:300}" ;;
      esac
    fi
    remember "$entry"
    # Nothing was learned about any stretch this session was told about, so all of them stand.
    while IFS= read -r t; do
      case "$t" in "$clone$T"*) remember "$t" ;; esac
    done <<< "$told"
    continue
  fi

  while IFS="$T" read -r kind count first sentence; do
    [ -n "$kind" ] || continue
    case "$kind" in
      sending|receiving)
        case "$first" in ''|*[!0-9]*) entry="$clone$T$kind$T?"; due=1 ;;
          *) entry="$clone$T$kind$T$first"; due=0; [ $(( now - first )) -ge "$after" ] && due=1 ;;
        esac
        if in_list "$told" "$entry"; then remember "$entry"; continue; fi
        [ "$due" -eq 1 ] || continue
        if [ "$kind" = sending ]; then what="config edited on this Mac is not reaching the other Mac"
        else what="config changed on the other Mac is not arriving here"; fi
        unread=""
        case "$first" in
          ''|*[!0-9]*) unread=" When this started could not be read from its record, so it is said now rather than held back until it is old enough." ;;
        esac
        say "claude-sync: $what. From the automatic sync in $clone: ${sentence}${unread} This is said once in this session, and again here when it clears."
        remember "$entry" ;;
      *)
        # An unreadable record, or a kind added to the tool after this hook was written: said once
        # in the tool's own words rather than dropped, because a kind nobody handles would otherwise
        # take the silent default and read as nothing wrong (L113).
        entry="$clone$T$kind$T"
        if ! in_list "$told" "$entry"; then
          say "claude-sync: in the automatic sync at $clone, ${sentence:-a record of kind $kind came back with nothing to say about it.}"
        fi
        remember "$entry" ;;
    esac
  done <<< "$recs"

  # Every stretch this session was told about that the clone no longer reports has ENDED. Only the
  # two stuck directions have an end worth saying; an unreadable record that became readable is
  # followed by whatever it now says, which is its own notice if anything is wrong.
  while IFS= read -r t; do
    case "$t" in "$clone$T"*) ;; *) continue ;; esac
    in_list "$keep" "$t" && continue
    rest="${t#"$clone$T"}"; kind="${rest%%"$T"*}"
    case "$kind" in
      sending)   say "claude-sync: sending from this Mac is moving again. The stuck stretch reported earlier in this session, in the automatic sync at $clone, has ended." ;;
      receiving) say "claude-sync: receiving on this Mac is moving again. The stuck stretch reported earlier in this session, in the automatic sync at $clone, has ended." ;;
    esac
  done <<< "$told"
done <<< "$clones"
rm -f "$ERRF" 2>/dev/null || true

# Recorded BEFORE speaking, so a notice cannot repeat itself if anything below fails: the safe
# direction is saying it once too few, not once per prompt for the rest of the session. A clone no
# longer run automatically drops out of the record without a word, since nothing about it was
# measured this time.
if [ -n "$keep" ]; then
  printf '%s\n' "$keep" > "$STATE" 2>/dev/null || true
else
  rm -f "$STATE" 2>/dev/null || true
fi

[ -n "$notices" ] && printf '%s\n' "$notices"
exit 0
