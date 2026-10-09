#!/usr/bin/env bash
#
# pr-review-push-gate.sh
# Claude Code PreToolUse(Bash) hook.
#
# Refuse a push of a branch until the lessons review of the head being pushed has finished and its
# findings have been read, so they are fixed BEFORE GitHub sees the branch (claude-config#599). Dan,
# 2026-10-02: "there have been several times today where you submitted a PR and had to go back and
# do something because a check caught it." Every one of those catches in that Slate session came
# from the lessons review, which then ran only after a push, so each finding cost a fix, another
# push and another full CI run (about 5 minutes on Slate), up to four rounds on one pull request.
# Run on the local head before pushing, the same review took 12 to 17 s a round.
#
# THE REVIEW IS THE MERGE GATE'S OWN (lib/pr-review.sh check, --gate push): the whole branch, merge
# base with origin's default branch to the local HEAD, every file type, on both Macs. Reviews are
# keyed by repository (a hash of the origin URL, never the checkout's folder name, which only
# labels messages) and commit, so the merge gate later finds THIS review for the same head and does
# not start a second one. The merge gate is exactly as strict as before: a key presented to a push
# is recorded where only pushes read it, so a merge still has to present the findings' key itself
# (the key this push was shown reads the same review), and a review whose range does not cover the
# pull request's base is run again rather than reused (lib/pr-review.sh, do_check).
#
# THE WAIT. A review usually starts at COMMIT time (ai-review-on-pr.sh), so it is often done by the
# push. When it is still running, or this gate had to start it, the push waits for it, polling,
# for at most PR_REVIEW_PUSH_WAIT_SECONDS (100 by default, inside the hook's 150 s timeout so the
# hook is never killed into allowing; L110, L743). Past that the push is refused with how long it
# waited and how long the review has run against its own deadline, and the review goes on in the
# background for the next attempt. Never an unbounded wait.
#
# THE OUTCOMES, each in its own words (L11, L260), all from pr-review.sh check:
#   0 findings, an empty diff, findings already read      allowed
#   findings not yet read                                 refused with the findings and their read
#                                                         key, until a push presents it as
#                                                         PR_REVIEW_READ=<key> <the push command>
#   still running when the wait ends                      refused, with the time waited
#   could not run, failed, timed out, too large, ...      refused (L42), naming the restart command
#                                                         and the one command override
# And three this gate decides itself:
#   a push of the default branch, or one that only deletes   not gated: no branch to review
#   a commit and a push in ONE command                       refused: the head it pushes does not
#                                                            exist yet, so nothing has read it
#   a missing library, reader or checker                     refused, saying which (L42, L488)
# Which pushes are held at all is ONE function, mt_push_gate_scope in lib/merge-target.sh, because
# ai-review-on-push.sh reads the same answer to stand down wherever this review reads the branch
# (claude-config#1007, L261): a second model review of a subset of the same diff is the same work
# done twice per push (L301).
#
# Override, one command, visible: SKIP_PR_REVIEW=1 on the push, the merge gate's own. Explain to
# Dan first. The head judged is the local HEAD, as every push gate here judges it.
#
# Seams for the suite (L524): PR_REVIEW_PUSH_SLEEP (a command, default sleep),
# PR_REVIEW_PUSH_CLOCK (a command printing epoch seconds, default date +%s),
# PR_REVIEW_PUSH_POLL_SECONDS (3), PR_REVIEW_PUSH_WAIT_SECONDS (100).

set -uo pipefail
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
payload="$(cat)"

# It runs before EVERY Bash command, so the commonest case leaves before anything is loaded.
case "$payload" in *push*) ;; *) exit 0 ;; esac

refuse() { printf '%s\n' "$1" >&2; exit 2; }
OVERRIDE_HOW="Override for one push, explained to Dan first: SKIP_PR_REVIEW=1 <the push command>."

# The libraries it reads through (merge-target.sh sources push-scope.sh). Missing, it cannot tell a
# push from anything else, so it refuses only what could be one, by the cheap filter above.
if ! . "$HOOK_DIR/lib/merge-target.sh" 2>/dev/null || ! declare -F ps_is_git_push >/dev/null \
  || ! declare -F mt_push_gate_scope >/dev/null; then
  case "$payload" in *SKIP_PR_REVIEW=1*) exit 0 ;; esac
  refuse "Refusing to push: lib/merge-target.sh or lib/push-scope.sh is missing, so pr-review-push-gate.sh cannot tell whether this command pushes, and the lessons review of the branch cannot be asked. $OVERRIDE_HOW"
fi
if ps_reader_missing jq python3; then
  case "$payload" in *SKIP_PR_REVIEW=1*) exit 0 ;; esac
  refuse "Refusing to push: $(ps_reader_absent_why "neither jq nor python3 is on PATH" "pr-review-push-gate.sh reads the command with one of them, so it cannot tell a push from anything else." "jq or python3") $OVERRIDE_HOW"
fi

parsed="$(ps_parse_payload "$payload" segmented)" || parsed=""
command="${parsed%%$'\x1f'*}"
cwd="${parsed#*$'\x1f'}"
ps_is_git_push "$command" || exit 0

raw="$(ps_parse_payload "$payload" raw)" || raw=""
raw="${raw%%$'\x1f'*}"

# Whether this push is held, read from the one predicate ai-review-on-push.sh also reads to stand
# down where this gate reviews (lib/merge-target.sh, mt_push_gate_scope; claude-config#1007, L261).
mt_push_gate_scope "$command" "$raw" "$cwd"
case $? in
  0) ;;
  3)
    echo "pr-review-push-gate: SKIP_PR_REVIEW=1 was set, so this push was NOT held for the lessons review. Tell Dan why it was skipped; never skip it silently."
    exit 0 ;;
  4)
    refuse "Refusing to push: this command commits and pushes in one go, so the head it would push does not exist yet and the lessons review cannot read it. Run the commit first, on its own, then the push." ;;
  5) exit 2 ;;
  *) exit 0 ;;
esac
top="$MT_PUSH_GATE_TOP"
head="$MT_PUSH_GATE_HEAD"
branch="$MT_PUSH_GATE_BRANCH"

[ -f "$HOOK_DIR/lib/pr-review.sh" ] \
  || refuse "Refusing to push: the lessons review could not run, because $HOOK_DIR/lib/pr-review.sh is missing. $OVERRIDE_HOW"

# The read key, only as an assignment in front of the PUSH itself (the merge gate's own reader).
read_key="$(mt_presented_read_key "$raw" ps_is_git_push)"

WAIT="${PR_REVIEW_PUSH_WAIT_SECONDS:-100}"
case "$WAIT" in ''|*[!0-9]*) WAIT=100 ;; esac
POLL="${PR_REVIEW_PUSH_POLL_SECONDS:-3}"
case "$POLL" in ''|*[!0-9]*|0) POLL=3 ;; esac
SLEEP="${PR_REVIEW_PUSH_SLEEP:-sleep}"
now_s() { if [ -n "${PR_REVIEW_PUSH_CLOCK:-}" ]; then "$PR_REVIEW_PUSH_CLOCK"; else date +%s; fi; }

args=(check --gate push --dir "$top" --sha "$head")
[ -n "$branch" ] && args+=(--branch "$branch")
t0="$(now_s)"
while :; do
  out="$(PR_REVIEW_READ="$read_key" bash "$HOOK_DIR/lib/pr-review.sh" "${args[@]}" 2>&1)"; rc=$?
  case "$rc" in
    0) printf 'pr-review-push-gate: %s\n' "$out"; exit 0 ;;
    3)
      now="$(now_s)"
      waited=$((now - t0))
      if [ $((waited + POLL)) -gt "$WAIT" ]; then
        refuse "$out This push waited ${waited}s for it, the longest a push waits (PR_REVIEW_PUSH_WAIT_SECONDS=$WAIT); the review goes on in the background, so push again in a while."
      fi
      "$SLEEP" "$POLL"
      ;;
    *) refuse "$out" ;;
  esac
done
