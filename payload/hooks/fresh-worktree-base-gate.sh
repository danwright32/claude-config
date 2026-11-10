#!/usr/bin/env bash
#
# fresh-worktree-base-gate.sh
# Claude Code PreToolUse(Edit|Write|MultiEdit|NotebookEdit) hook: refuse the first file edit in a
# FRESH git worktree, one with no commits of its own yet, while its base is behind the remote's main
# branch, and name the one command that brings it up to date (claude-config#2517). Reading is never
# refused: the matcher names only the tools that write a file.
#
# WHY. Worktrees share refs, so once another worktree has fetched, `git fetch` prints no update line
# however far main has moved. On 2026-09-14 that let an Ovation pull request merge without the
# rebase its brief required. The only defence was a CLAUDE.md sentence telling sessions to run
# `git rev-list --count HEAD..origin/main`, a rule that lived only in a prompt (L27). #766 refuses a
# merge whose branch lacks the base tip, at the end; this catches the same thing at the start,
# before any work is built on the old base.
#
# THE SHAPE (settled on the issue):
#   * It fetches the remote's main branch itself before judging, because a ref nobody refreshed
#     answers "not behind" on stale data (L345). The fetch is bounded (FRESH_WORKTREE_FETCH_SECONDS,
#     10 by default), far inside the registration's 30 second timeout, so the gate always settles
#     itself: a gate Claude Code kills is a refused call under onFailure block. Measured on
#     2026-11-10 on the personal MacBook (12 cores, load average 16 to 19 over one minute and about
#     40 over five), eight `git fetch --quiet origin main` runs with nothing new took 0.18 to 0.33
#     seconds.
#   * Judged once per worktree per session, then cached, so a session pays one fetch per worktree
#     and not one per edit. Only a pass is cached. A refusal is judged again on the next edit (one
#     more fetch), so the edit after the named command goes ahead.
#   * A worktree with commits of its own stands down: main moving after that is a rebase question
#     for the merge step (#766). Read against the local ref first, which needs no fetch, since a
#     fetch only adds to main and cannot give the worktree commits it lacks.
#   * Primary checkouts are out of scope: only a worktree (git dir differs from the common dir).
#   * A fetch that fails (offline, auth, a hang cut off at the bound) says it could not check and
#     lets the edit through, never passing in silence and never blocking for good. It is said once
#     and tried again after FRESH_WORKTREE_RETRY_MINUTES (15 by default). One exception: when even
#     the unrefreshed local ref already shows the worktree behind, the gate refuses, because a stale
#     ref only ever understates how far behind it is and the named command needs no network.
#   * A fetch that was never RUN is refused, every time, naming the file (claude-config#2634). That
#     is lib/bounded-run.sh missing, or the lib/whole-number.sh it reads its bound with: the hooks
#     are missing a part, which is not a network fault, does not clear after the retry window, and
#     is put right by `claude-sync pull`. It took the failed fetch path until then, so with the
#     library gone a worktree behind the real main was let through with a notice said once, and
#     test-gates-fail-closed.sh, which left a library loaded with a stand in function out, never
#     ran the gate without it.
#
# DECISIONS TAKEN WITHOUT DAN (recorded in the pull request too):
#   * Refuse until updated, not warn once: a warning already read and passed is how the 2026-09-14
#     merge happened, and the remedy is one local command.
#   * The remedy is `git -C <worktree> merge --ff-only <base>`: with no commits of its own the
#     worktree's HEAD is an ancestor of the base, so a fast forward is always possible, moves the
#     branch (or a detached HEAD) without rewriting anything, and keeps uncommitted changes that do
#     not collide.
#   * The base is the remote's own HEAD (refs/remotes/origin/HEAD) where it is set, origin/main
#     otherwise. A worktree whose repository has no origin remote has nothing to be behind and is
#     passed in silence.
#   * A payload it cannot read is let through, saying so, rather than refused: this gate only
#     tightens, and refusing an edit whose payload the session cannot change would stop work with
#     no remedy (the same call as scratchpad-subagent-gate.sh). A missing python3 does the same,
#     through the notice, and a missing lib/hook-notice.sh changes only how that notice is built.
#     A missing lib/bounded-run.sh is the one library that is refused: see the fetch never run,
#     above.
#
# Settings, for the suite: FRESH_WORKTREE_STATE_DIR (where the per session record is kept, default
# TMPDIR), FRESH_WORKTREE_FETCH_SECONDS, FRESH_WORKTREE_RETRY_MINUTES.

set -uo pipefail

# Its own folder cut from its path in bash, never by dirname (claude-config#2081, #2130).
case "${BASH_SOURCE[0]}" in */*) HOOK_DIR="${BASH_SOURCE[0]%/*}" ;; *) HOOK_DIR=. ;; esac
HOOK_DIR="$(cd "${HOOK_DIR:-/}" && pwd)"

payload="$(cat 2>/dev/null || true)"

# Most calls this sees are edits; anything naming no file path leaves before anything starts. The
# bare words, not the quoted keys, so a tool_input sent as one JSON string (its quotes escaped) is
# still read and named as unreadable (claude-config#2057).
case "$payload" in *file_path*|*notebook_path*) ;; *) exit 0 ;; esac

. "$HOOK_DIR/lib/hook-notice.sh" 2>/dev/null || hook_allow_notice() {  # the library is missing
  printf '%s\n' "$1" >&2
  printf '{"systemMessage": "%s (lib/hook-notice.sh is missing beside this hook)"}\n' "${1//[^A-Za-z0-9 .,:;()\/_=+#-]/}"; exit 0; }
# A lone surrogate escape cleaned, where the library is; without it the payload is read as it came.
. "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null && payload="$(ps_clean_payload "$payload")"
# The stand in answers 125, the library's own code for having run nothing, and the gate refuses on
# it where it needs the fetch, so a call that never reaches the fetch is not refused for the file.
. "$HOOK_DIR/lib/bounded-run.sh" 2>/dev/null || bounded_run() {  # the library is missing: run nothing unbounded
  BOUNDED_RC=125; BOUNDED_OUT="lib/bounded-run.sh is missing beside this hook, so the fetch was not run"; }

NAME="FRESH WORKTREE CHECK DID NOT RUN"
command -v python3 >/dev/null 2>&1 \
  || hook_allow_notice "$NAME: python3 is missing, so fresh-worktree-base-gate.sh could not read the hook payload and this edit went ahead without checking whether its worktree is behind origin main."

parsed="$(printf '%s' "$payload" | python3 -c '
import json, os, sys
sys.stdout.reconfigure(errors="replace")
try:
    d = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace"))
except Exception as e:
    print("unreadable\t" + type(e).__name__); sys.exit()
if not isinstance(d, dict):
    print("unreadable\tthe payload is not a JSON object"); sys.exit()
if d.get("tool_name") not in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
    print("allow\t"); sys.exit()
ti = d.get("tool_input")
if not isinstance(ti, dict):
    print("unreadable\tits tool_input is not an object"); sys.exit()
p = ti.get("notebook_path") if d.get("tool_name") == "NotebookEdit" else ti.get("file_path")
if not isinstance(p, str) or not p:
    print("unreadable\tit names no file path as text"); sys.exit()
cwd = d.get("cwd") if isinstance(d.get("cwd"), str) else ""
p = os.path.normpath(os.path.join(cwd or "/", p))
# The nearest folder that exists: a Write may make a file in folders not made yet.
while p != "/" and not os.path.isdir(p):
    p = os.path.dirname(p)
sid = d.get("session_id") or d.get("transcript_path") or ""
print("judge\t" + p + "\x1f" + (sid if isinstance(sid, str) else ""))
' 2>&1)"

case "$parsed" in
  allow$'\t'*) exit 0 ;;
  judge$'\t'*) ;;
  unreadable$'\t'*)
    hook_allow_notice "$NAME: fresh-worktree-base-gate.sh could not read the hook payload (${parsed#*$'\t'}), so this edit went ahead without checking whether its worktree is behind origin main." ;;
  *)
    hook_allow_notice "$NAME: fresh-worktree-base-gate.sh could not read the hook payload (${parsed//$'\n'/ }), so this edit went ahead without checking whether its worktree is behind origin main." ;;
esac
parsed="${parsed#*$'\t'}"
dir="${parsed%%$'\x1f'*}"
session="${parsed#*$'\x1f'}"

# A worktree, not a primary checkout: its own git dir differs from the shared one. Anything git
# cannot place (no repository, a bare one, inside a .git folder) is out of scope.
loc="$(git -C "$dir" rev-parse --path-format=absolute --show-toplevel --git-dir --git-common-dir 2>/dev/null)" || exit 0
{ IFS= read -r top; IFS= read -r gitdir; IFS= read -r common; } <<< "$loc"
[ -n "$top" ] && [ -n "$gitdir" ] && [ -n "$common" ] || exit 0
[ "$gitdir" != "$common" ] || exit 0
git -C "$top" remote get-url origin >/dev/null 2>&1 || exit 0

base="$(git -C "$top" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)" || base=""
case "$base" in origin/?*) ;; *) base="origin/main" ;; esac
branch="${base#origin/}"

# The record for this session and worktree: "ok", or "unchecked <epoch seconds>". With no session to
# key it on, nothing is kept and every edit is judged, which costs a fetch each but is never wrong.
state=""
if [ -n "$session" ]; then
  key="$(printf '%s\n%s' "$session" "$top" | shasum 2>/dev/null | cut -c1-16)"
  [ -n "$key" ] && state="${FRESH_WORKTREE_STATE_DIR:-${TMPDIR:-/tmp}}/claude-fresh-worktree-$key.state"
fi
record() { # record <text>: written whole, so a reader never sees half of it
  [ -n "$state" ] || return 0
  mkdir -p "${state%/*}" 2>/dev/null
  printf '%s\n' "$1" > "$state.$$" 2>/dev/null && mv -f "$state.$$" "$state" 2>/dev/null
  rm -f "$state.$$" 2>/dev/null
  return 0
}
now="$(date +%s)"
retry="${FRESH_WORKTREE_RETRY_MINUTES:-15}"
case "$retry" in ''|*[!0-9]*) retry=15 ;; *) retry=$((10#$retry)) ;; esac
if [ -n "$state" ] && [ -f "$state" ]; then
  was="$(cat "$state" 2>/dev/null)"
  case "$was" in
    ok) exit 0 ;;
    "unchecked "*)
      at="${was#unchecked }"
      case "$at" in ''|*[!0-9]*) ;; *) [ $((now - at)) -lt $((retry * 60)) ] && exit 0 ;; esac ;;
  esac
fi

count() { git -C "$top" rev-list --count "$1" 2>/dev/null; }
plural() { [ "$1" = 1 ] && printf '%s commit' "$1" || printf '%s commits' "$1"; }
refuse() { # refuse <behind> <extra sentence or empty>
  printf '%s\n' "REFUSED: the worktree $top has no commits of its own yet and is $(plural "$1") behind $base, so an edit here would build on old code (claude-config#2517).${2:+ $2} Reading files is not affected. Bring it up to date with this one command, then make the edit again:
  git -C \"$top\" merge --ff-only $base" >&2
  exit 2
}

# Commits of its own stand it down, read on the local ref with no fetch.
own="$(count "$base..HEAD")"
case "$own" in ''|0) ;; *) record ok; exit 0 ;; esac

# Zero written any way, or anything not a whole number, is the default (lib/whole-number.sh, which
# lib/bounded-run.sh loads). With either library missing the bound is the default as well, but no
# fetch is run with it: bounded_run answers 125 and the edit is refused below (claude-config#2634).
secs="$(whole_above_zero "${FRESH_WORKTREE_FETCH_SECONDS:-10}" 2>/dev/null)" || secs=10
bounded_run "$secs" env GIT_TERMINAL_PROMPT=0 git -C "$top" fetch --quiet origin "$branch"
if [ "$BOUNDED_RC" -ne 0 ]; then
  case "$BOUNDED_RC" in 124) why="it took longer than $secs seconds" ;; *) why="$(printf '%s' "$BOUNDED_OUT" | tr '\n' ' ' | cut -c1-200)" ;; esac
  behind="$(count "HEAD..$base")"
  own="$(count "$base..HEAD")"
  if [ -n "$behind" ] && [ "$behind" != 0 ] && [ "$own" = 0 ]; then
    refuse "$behind" "The fetch of origin $branch failed ($why), so it could not check how far main has moved since; this copy of $base already shows it behind."
  fi
  # 125 is bounded_run saying it ran NOTHING: lib/bounded-run.sh is missing (the stand in above), or
  # the lib/whole-number.sh it reads its bound with is. That is not a fetch that failed. Nothing on
  # the network is wrong, it will not come right after the retry window, and the remedy is one
  # command the session can run, so the edit is refused, every time, until the hooks are whole
  # (claude-config#2634). It used to take the failed fetch path below, which let through, with a
  # notice said once, an edit this gate refuses with the library in place.
  if [ "$BOUNDED_RC" -eq 125 ]; then
    case "$why" in *[![:space:]]*) ;; *) why="nothing was run" ;; esac
    printf '%s\n' "REFUSED: fresh-worktree-base-gate.sh could not run its fetch of origin $branch at all ($why), so whether the worktree $top, which has no commits of its own yet, is behind $base was not checked (claude-config#2634). A part of the hooks is missing, which is not a network fault and will not clear by waiting. Reinstall the hooks with claude-sync pull, then make the edit again. Reading files is not affected." >&2
    exit 2
  fi
  record "unchecked $now"
  hook_allow_notice "$NAME: fresh-worktree-base-gate.sh could not fetch origin $branch for the worktree $top ($why), so whether it is behind $base was not checked and this edit went ahead. It tries again after $retry minutes."
fi

behind="$(count "HEAD..$base")"
own="$(count "$base..HEAD")"
if [ -z "$behind" ] || [ -z "$own" ]; then
  record "unchecked $now"
  hook_allow_notice "$NAME: fresh-worktree-base-gate.sh fetched origin $branch for the worktree $top but could not compare it with $base, so whether it is behind was not checked and this edit went ahead."
fi
if [ "$own" != 0 ] || [ "$behind" = 0 ]; then
  record ok
  exit 0
fi
refuse "$behind" ""
