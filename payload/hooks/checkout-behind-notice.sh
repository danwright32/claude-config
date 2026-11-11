#!/usr/bin/env bash
#
# checkout-behind-notice.sh: tell a session, and every subagent it starts, when the checkout it is
# reading is behind the remote's default branch (claude-config#2712). Registered on SessionStart
# (startup, resume, /clear, compaction) and SubagentStart.
#
# WHY. On 2026-11-10, on the work MacBook, a project's primary checkout sat on a detached HEAD from
# 2026-10-20, 279 commits behind its main branch. The session read it as current, told Dan twice
# that a shipped feature did not exist, saved a draft naming the wrong link, and filed an issue for
# work that had gone live nine days earlier. `git branch --show-current` printed an empty line and
# nobody read it as a signal. A written rule to read the live repository was already in that
# project's memory, and a rule that lives only in a prompt is a hope (L27).
#
# WHAT IT SAYS. The checkout is the one the hook's cwd is in, a primary or a worktree, judged on its
# own HEAD against origin's default branch (origin/HEAD, else origin/main, else origin/master). The
# notice names the checkout, its branch or that HEAD is detached, how many commits it lacks and how
# old the oldest of them is, and tells the session to read the current code from the remote branch
# (git show <base>:<path>, git grep <pattern> <base>), because a shared checkout must not be
# switched. IT NEVER CHANGES THE CHECKOUT: no pull, merge, checkout or reset, only a fetch, which
# writes the remote tracking ref and nothing a session standing on the checkout can see move.
#
# WHEN IT SPEAKS (measured, see the pull request for the table). Behind at all, and one of:
#   * HEAD is detached: the shape of the 2026-11-10 checkout, and no session on its own work stands
#     there, so any distance is reported. A detached HEAD AT origin's tip is the current code and is
#     not reported: there is nothing to do about it.
#   * the oldest missing commit is CHECKOUT_BEHIND_HOURS old (default 8). Measured on the personal
#     MacBook on 2026-11-10 across every listed checkout and its 57 worktrees: every worktree in
#     active use lacked at most 5 hours of work, and every stale one at least 16 (the primaries
#     ranged from 1 commit missing for 43 days to 7 missing for 45). A commit count alone could not
#     separate them: a slow repository one commit behind for six weeks was quieter than a busy one
#     twenty behind after an afternoon.
#   * it lacks CHECKOUT_BEHIND_COMMITS commits (default 50), however recent: the active worktrees
#     topped out at 20, so 50 is a backstop for a repository moving faster than the hours rule sees.
#
# THE FETCH. A ref nobody refreshed answers "not behind" on stale data (L345), so it fetches the one
# branch first, bounded at CHECKOUT_BEHIND_FETCH_SECONDS (default 5; the same measurement took 0.22
# to 0.87 seconds a repository). A fetch that succeeded is cached for the repository (worktrees share
# refs) for CHECKOUT_BEHIND_FETCH_TTL_MINUTES (default 10), so a burst of sessions and subagents pays
# one fetch. A fetch that fails or runs out of time says the checkout COULD NOT BE CHECKED, with
# git's reason, never "0 behind" (L98, L11), and still says how far behind the last fetched copy
# already shows it. A failure is not cached.
#
# ONCE PER ANSWER. The person is told once per session for each answer (the checkout, its HEAD and
# origin's commit), as a systemMessage. The session's context gets it again where its context is
# rebuilt (a /clear or a compaction) and every subagent gets it as its own SubagentStart context,
# without telling the person again. Measured on Claude Code 2.1.322 on 2026-11-10 with a probe hook:
# SubagentStart additionalContext reaches the subagent, and its payload's cwd is the subagent's own
# worktree when it runs in one, the session's folder otherwise, so a subagent briefed into the same
# old checkout is told and one in a fresh worktree is not.
#
# Env, for the suite: CHECKOUT_BEHIND_NOW (the clock, epoch seconds), CHECKOUT_BEHIND_FETCH (a
# command run as <command> <checkout> <branch> in place of the git fetch), CHECKOUT_BEHIND_STATE_DIR
# (default TMPDIR), and the four settings above.
set -uo pipefail

input="$(cat 2>/dev/null || true)"
case "${BASH_SOURCE[0]}" in */*) HOOK_DIR="${BASH_SOURCE[0]%/*}" ;; *) HOOK_DIR=. ;; esac
# A lone surrogate escape cleaned, where the library is; without it the payload is read as it came.
. "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null && input="$(ps_clean_payload "$input")"
. "$HOOK_DIR/lib/hook-notice.sh" 2>/dev/null || hook_allow_notice() {  # the library is missing
  printf '%s\n' "$1" >&2
  printf '{"systemMessage": "%s (lib/hook-notice.sh is missing beside this hook)"}\n' "${1//[^A-Za-z0-9 .,:;()\/_=+#-]/}"; exit 0; }
# Without the library a context the person already saw is said to them again: louder, never lost.
declare -F hook_context_json >/dev/null || hook_context_json() { hook_allow_notice "$2"; }
# The stand in answers 125, the library's own code for having run nothing, which is said as a fetch
# that could not be run, never as a checkout found current.
. "$HOOK_DIR/lib/bounded-run.sh" 2>/dev/null || bounded_run() {  # the library is missing: run nothing unbounded
  BOUNDED_RC=125; BOUNDED_OUT="lib/bounded-run.sh is missing beside this hook"; }

NAME="checkout-behind-notice"
command -v python3 >/dev/null 2>&1 \
  || hook_allow_notice "$NAME: python3 is missing, so the hook payload could not be read and whether this checkout is behind origin was not checked."

fields="$(printf '%s' "$input" | python3 -c '
import json, sys
sys.stdout.reconfigure(errors="replace")
try:
    d = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace"))
except Exception:
    print("unreadable"); sys.exit()
if not isinstance(d, dict):
    print("unreadable"); sys.exit()
def one(v):
    return str(v or "").replace("\x1f", " ").replace("\n", " ")
print("\x1f".join(one(x) for x in (d.get("hook_event_name"), d.get("session_id") or d.get("transcript_path"),
                                   d.get("source"), d.get("cwd"))))
' 2>/dev/null)"
[ "$fields" = unreadable ] \
  && hook_allow_notice "$NAME: the hook payload could not be read, so whether this checkout is behind origin was not checked."
event="" session="" source="" cwd=""
IFS=$'\x1f' read -r event session source cwd <<< "$fields" || true
case "$event" in SessionStart|SubagentStart) ;; *) exit 0 ;; esac
cwd="${cwd:-${CLAUDE_PROJECT_DIR:-$PWD}}"

# --- the checkout ---------------------------------------------------------------------------------
# Anything git cannot place (no repository, a bare one) or a repository with no origin has nothing to
# be behind, and says nothing.
loc="$(git -C "$cwd" rev-parse --path-format=absolute --show-toplevel --git-common-dir 2>/dev/null)" || exit 0
{ IFS= read -r top; IFS= read -r common; } <<< "$loc"
[ -n "$top" ] && [ -n "$common" ] || exit 0
git -C "$top" remote get-url origin >/dev/null 2>&1 || exit 0
head="$(git -C "$top" rev-parse -q --verify HEAD 2>/dev/null)" || exit 0
here_branch="$(git -C "$top" symbolic-ref -q --short HEAD 2>/dev/null)" || here_branch=""
base="$(git -C "$top" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)" || base=""
case "$base" in
  origin/?*) ;;
  *) base=origin/main
     git -C "$top" rev-parse -q --verify refs/remotes/origin/main >/dev/null 2>&1 \
       || { git -C "$top" rev-parse -q --verify refs/remotes/origin/master >/dev/null 2>&1 && base=origin/master; } ;;
esac
dbranch="${base#origin/}"

whole() { case "$1" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$((10#$1))" ;; esac; }
now="$(whole "${CHECKOUT_BEHIND_NOW:-}" "$(date +%s)")"
secs="$(whole "${CHECKOUT_BEHIND_FETCH_SECONDS:-}" 5)"; [ "$secs" -gt 0 ] || secs=5
ttl="$(whole "${CHECKOUT_BEHIND_FETCH_TTL_MINUTES:-}" 10)"
hours="$(whole "${CHECKOUT_BEHIND_HOURS:-}" 8)"
commits="$(whole "${CHECKOUT_BEHIND_COMMITS:-}" 50)"; [ "$commits" -gt 0 ] || commits=50

STATE_DIR="${CHECKOUT_BEHIND_STATE_DIR:-${TMPDIR:-/tmp}}"
mkdir -p "$STATE_DIR" 2>/dev/null || true
STAMP="$STATE_DIR/claude-checkout-fetch-$(printf '%s\n%s' "$common" "$dbranch" | shasum | cut -c1-16).stamp"

# ago <seconds>: "10 hours ago", "3 days ago".
ago() {
  local s="$1" unit size n
  [ "$s" -ge 0 ] 2>/dev/null || s=0
  for unit in day:86400 hour:3600 minute:60; do
    size="${unit#*:}"; unit="${unit%:*}"
    if [ "$s" -ge "$size" ]; then
      n=$((s / size)); [ "$n" = 1 ] && printf '1 %s ago' "$unit" || printf '%s %ss ago' "$n" "$unit"
      return 0
    fi
  done
  printf 'under a minute ago'
}
fresh_stamp() { # prints the stamp's time when a successful fetch is within the window
  local at
  at="$(whole "$(cat "$STAMP" 2>/dev/null)" "")"
  [ -n "$at" ] && [ "$now" -ge "$at" ] && [ $((now - at)) -lt $((ttl * 60)) ] && printf '%s' "$at"
}

# --- the fetch, cached --------------------------------------------------------------------------------
fetched_at="$(fresh_stamp)" why=""
if [ -z "$fetched_at" ]; then
  if [ -n "${CHECKOUT_BEHIND_FETCH:-}" ]; then
    bounded_run "$secs" "$CHECKOUT_BEHIND_FETCH" "$top" "$dbranch"
  else
    bounded_run "$secs" env GIT_TERMINAL_PROMPT=0 git -c gc.auto=0 -c maintenance.auto=false \
      -C "$top" fetch --quiet --no-tags origin "$dbranch"
  fi
  if [ "$BOUNDED_RC" -eq 0 ]; then
    fetched_at="$now"
    printf '%s\n' "$now" > "$STAMP.$$" 2>/dev/null && mv -f "$STAMP.$$" "$STAMP" 2>/dev/null
    rm -f "$STAMP.$$" 2>/dev/null
  else
    # Another session's fetch may have landed meanwhile (two at once can lock each other out).
    fetched_at="$(fresh_stamp)"
    if [ -z "$fetched_at" ]; then
      case "$BOUNDED_RC" in
        124) why="took longer than $secs seconds" ;;
        125) why="could not be run (${BOUNDED_OUT:-nothing was run})" ;;
        *) why="failed: $(printf '%s' "$BOUNDED_OUT" | tr '\n' ' ' | cut -c1-200)" ;;
      esac
    fi
  fi
fi

# --- how far behind ----------------------------------------------------------------------------------
origin_sha="$(git -C "$top" rev-parse -q --verify "refs/remotes/$base" 2>/dev/null)" || origin_sha=""
behind=0 oldest=""
if [ -n "$origin_sha" ]; then
  read -r behind oldest <<< "$(git -C "$top" log --format=%ct "HEAD..$origin_sha" 2>/dev/null \
    | awk 'NF { n++; if (min == "" || $1 < min) min = $1 } END { print n + 0, min }')"
fi
behind="$(whole "$behind" 0)"
commits_word() { [ "$1" = 1 ] && printf '1 commit' || printf '%s commits' "$1"; }

if [ -n "$here_branch" ]; then
  where="$top is on $here_branch"
else
  where="$top is on a detached HEAD (no branch) at ${head:0:10}"
fi
remedy="A shared checkout must not be switched, pulled or reset, since other sessions may be standing on it, so read the current code from the remote branch instead: git -C '$top' show $base:<path> for a file, git -C '$top' grep -n <pattern> $base to search, and git -C '$top' log --oneline HEAD..$base for what this checkout lacks."

if [ -n "$fetched_at" ]; then
  [ "$behind" -gt 0 ] || exit 0
  age=$((now - $(whole "$oldest" "$now")))
  if [ -n "$here_branch" ] && [ "$behind" -lt "$commits" ] && [ "$age" -lt $((hours * 3600)) ]; then
    exit 0
  fi
  if [ "$fetched_at" = "$now" ]; then when="fetched just now"; else when="fetched $(ago $((now - fetched_at)))"; fi
  lead="CHECKOUT BEHIND ORIGIN: $where, $(commits_word "$behind") behind $base, missing work from as long as $(ago "$age") ($base $when). Files read from this checkout are that older code, so something that shipped since will look missing."
  key="behind|$top|$head|$origin_sha"
else
  if [ -z "$origin_sha" ]; then
    local_sentence="There is no copy of $base on this Mac to compare with."
  else
    newest=0
    for f in "$STAMP" "$common/FETCH_HEAD" "$common/refs/remotes/$base" "$common/logs/refs/remotes/$base"; do
      m="$(perl -e 'my @s = stat shift; print $s[9] // ""' "$f" 2>/dev/null)"
      m="$(whole "$m" 0)"; [ "$m" -gt "$newest" ] && newest="$m"
    done
    [ -f "$STAMP" ] && { m="$(whole "$(cat "$STAMP" 2>/dev/null)" 0)"; [ "$m" -gt "$newest" ] && newest="$m"; }
    if [ "$newest" -gt 0 ]; then copy="The copy of $base on this Mac, fetched $(ago $((now - newest))),"; else copy="The copy of $base on this Mac,"; fi
    if [ "$behind" -gt 0 ]; then
      local_sentence="$copy already shows it $(commits_word "$behind") behind, and origin can only have moved further since."
    else
      local_sentence="$copy is all there is to compare with, so how far behind origin it is now is not known."
    fi
  fi
  lead="CHECKOUT NOT CHECKED: whether $where is behind $base could not be checked, because the fetch of origin $dbranch $why. $local_sentence Until it is checked, do not take these files as the current code."
  key="unchecked|$top|$head"
fi
# The session gets the commands; the person gets the fact and what the session was told to do.
text="$lead $remedy"
person="$lead The session was told to read the current code from $base (git show, git grep) and not to switch this checkout."

# --- once per answer -------------------------------------------------------------------------------
said_file=""
[ -n "$session" ] && said_file="$STATE_DIR/claude-checkout-behind-$(printf '%s' "$session" | shasum | cut -c1-16).said"
said=0
[ -n "$said_file" ] && grep -qxF "$key" "$said_file" 2>/dev/null && said=1
if [ "$said" = 1 ]; then
  # The person was told. The context is handed over again only where it is new or was rebuilt.
  if [ "$event" = SessionStart ]; then
    case "$source" in compact|clear) ;; *) exit 0 ;; esac
  fi
  hook_context_json "$event" "$text"
  exit 0
fi
[ -n "$said_file" ] && printf '%s\n' "$key" >> "$said_file" 2>/dev/null
hook_allow_notice "$person" "$event" "$text"
