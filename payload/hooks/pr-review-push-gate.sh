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
# base with origin's default branch to the local HEAD (for a branch stacked on another open branch,
# from that branch's head: WHERE THE REVIEW READS FROM, below), every file type, on both Macs. Reviews are
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
#   only minor findings                                   allowed, handing them over as advisory
#                                                         (claude-config#1356, mt_review_allowed)
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
# Its own folder cut from its path in bash, never by dirname (claude-config#2081, #2130).
case "${BASH_SOURCE[0]}" in */*) HOOK_DIR="${BASH_SOURCE[0]%/*}" ;; *) HOOK_DIR=. ;; esac
HOOK_DIR="$(cd "${HOOK_DIR:-/}" && pwd)"
payload="$(cat)"

# It runs before EVERY Bash command, so the commonest case leaves before anything is loaded. A
# word written across a backslash and line break is in the payload in two pieces, so a payload
# that holds that pair, by any way JSON spells it, is not answered here (claude-config#3739).
named_whole() { case "$payload" in *push*) return 0 ;; esac; return 1; }
case "$payload" in
  *'\\\n'*|*'\\\u000'[aA]*|*'\u005'[cC]*) ;;
  *) named_whole || exit 0 ;;
esac

refuse() { printf '%s\n' "$1" >&2; exit 2; }
OVERRIDE_HOW="Override for one push, explained to Dan first: SKIP_PR_REVIEW=1 <the push command>."

# The libraries it reads through (merge-target.sh sources push-scope.sh and whole-number.sh).
# Missing, it cannot tell a push from anything else, so it refuses only what could be one, by the
# cheap filter above. A payload here only for the pair it holds names push nowhere whole, and with
# nothing to join its pieces it is let through.
if ! . "$HOOK_DIR/lib/merge-target.sh" 2>/dev/null || ! declare -F ps_is_git_push >/dev/null \
  || ! declare -F mt_push_gate_scope >/dev/null || ! declare -F whole_above_zero >/dev/null; then
  named_whole || exit 0
  case "$payload" in *SKIP_PR_REVIEW=1*) exit 0 ;; esac
  refuse "Refusing to push: lib/merge-target.sh, lib/push-scope.sh or lib/whole-number.sh is missing, so pr-review-push-gate.sh cannot tell whether this command pushes, and the lessons review of the branch cannot be asked. $OVERRIDE_HOW"
fi
if ps_reader_missing jq python3; then
  named_whole || exit 0
  case "$payload" in *SKIP_PR_REVIEW=1*) exit 0 ;; esac
  refuse "Refusing to push: $(ps_reader_absent_why "neither jq nor python3 is on PATH" "pr-review-push-gate.sh reads the command with one of them, so it cannot tell a push from anything else." "jq or python3") $OVERRIDE_HOW"
fi

# Taken raw above so the commonest call leaves before anything loads, and cleaned here, before
# anything parses it: a lone surrogate escape made jq read nothing (claude-config#1944). A payload
# still unreadable is judged by its words (#1922).
payload="$(ps_clean_payload "$payload")"
# What the segmented form hides is judged in a run of its own, in what is left of this hook's
# registered time limit, which is the number here (claude-config#3739).
ps_both_readings "$payload" 150
parsed="$(ps_parse_payload "$payload" segmented)" \
  || ps_unparsed_refuse "$payload" pr-review-push-gate.sh SKIP_PR_REVIEW "a push" '*push*'
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
    # To Dan as a systemMessage and to the session as context: a PreToolUse hook's plain stdout on
    # exit 0 goes to the debug log (hooks documentation), so the line printed plain reached neither
    # (#1906).
    # shellcheck source=lib/hook-notice.sh
    . "$HOOK_DIR/lib/hook-notice.sh" 2>/dev/null || hook_allow_notice() {  # the library is missing
      printf '%s\n' "$1" >&2
      printf '{"systemMessage": "%s (lib/hook-notice.sh is missing beside this hook)"}\n' "${1//[^A-Za-z0-9 .,:;()\/_=+#-]/}"; exit 0; }
    hook_allow_notice "pr-review-push-gate: SKIP_PR_REVIEW=1 was set, so this push was NOT held for the lessons review. Tell Dan why it was skipped; never skip it silently." PreToolUse ;;
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
# Zero however written is the default (lib/whole-number.sh, loaded by merge-target.sh, #1948).
POLL="$(whole_above_zero "$POLL")" || POLL=3
SLEEP="${PR_REVIEW_PUSH_SLEEP:-sleep}"
now_s() { if [ -n "${PR_REVIEW_PUSH_CLOCK:-}" ]; then "$PR_REVIEW_PUSH_CLOCK"; else date +%s; fi; }

# WHERE THE REVIEW READS FROM (claude-config#3444). A branch cut from another open branch was read
# all the way back to the default branch, so a stopping finding in a file its base branch owns
# refused the stacked push (twice on 2026-11-22). Whether the branch is stacked, and on what, is the
# one answer in lib/stacked-base.sh, which the test gate asks too: a branch on origin whose head is
# in this branch's history and is, on GitHub, the head of an open pull request. Then the review reads
# from that head, and the base's own changes are read on its own pull request, which the merge gate
# holds until its review is read. Anything short of that reads from the default branch as before.
#
# The base is always NAMED to the checker, the default branch included, because a finished review is
# reused only when it covers the base it is asked about (lib/pr-review.sh, do_check): a review that
# read from a base which has since stopped being an open pull request is then read again from the
# default branch, never reused for commits nobody read.
STACK_NOTE=""; review_base=""
# shellcheck source=lib/stacked-base.sh
if . "$HOOK_DIR/lib/stacked-base.sh" 2>/dev/null && declare -F sb_stacked_base >/dev/null; then
  stacked="$(sb_stacked_base "$top")"; stacked_rc=$?
  # 2: a branch does lie under this one and was not established as its base, so its changes are in
  # what the review read; a refusal says why (L11). 1 is an ordinary branch, with nothing to say.
  [ "$stacked_rc" -eq 2 ] && STACK_NOTE=" Another branch on origin lies under this one and the review still read from the default branch, that branch's changes included, because: ${stacked#none }."
  if review_base="$(sb_field "$stacked" ref)"; then
    stacked_tip="$(sb_field "$stacked" tip)"
    STACK_NOTE=" This branch is stacked on $review_base (pull request #$(sb_field "$stacked" pr), open), so the review read only what the branch adds to that branch's head ${stacked_tip:0:7}; that branch's own changes are read on its own pull request."
  fi
fi
[ -n "$review_base" ] || review_base="$(cd "$top" 2>/dev/null && ps__default_ref)" || review_base=""

args=(check --gate push --dir "$top" --sha "$head")
[ -n "$branch" ] && args+=(--branch "$branch")
[ -n "$review_base" ] && args+=(--base-ref "$review_base")
t0="$(now_s)"
while :; do
  out="$(PR_REVIEW_READ="$read_key" bash "$HOOK_DIR/lib/pr-review.sh" "${args[@]}" 2>&1)"; rc=$?
  case "$rc" in
    # An allow with minor findings hands them over as advisory (claude-config#1356).
    # The note rides an allow only when the base was used: a base not taken matters to a refusal.
    0) [ -n "$review_base" ] && [ "${stacked_rc:-1}" -eq 0 ] || STACK_NOTE=""
       mt_review_allowed pr-review-push-gate "$out$STACK_NOTE" ;;
    3)
      now="$(now_s)"
      waited=$((now - t0))
      if [ $((waited + POLL)) -gt "$WAIT" ]; then
        refuse "$out This push waited ${waited}s for it, the longest a push waits (PR_REVIEW_PUSH_WAIT_SECONDS=$WAIT); the review goes on in the background, so push again in a while."
      fi
      "$SLEEP" "$POLL"
      ;;
    *) refuse "$out$STACK_NOTE" ;;
  esac
done
