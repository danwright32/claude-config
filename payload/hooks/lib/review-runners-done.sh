#!/usr/bin/env bash
# Sourced by the suites that drive the lessons review runner (test-pr-review.sh and
# test-pr-review-push.sh), so each waits the same way before wiping its state folder between cases.
#
# A reviewer runner still going from the case before writes its answer into the NEXT case's fresh
# state when it finishes: claude-config#1097, where section 3g2's runner, asleep 5 s, finished just
# as 3h's check had made the state folder, so 3h read 3g2's review with one finding instead of its
# own "could not run" (once in three runs under load, 2026-10-12, and on demand since by holding
# that runner until 3h's check had made the folder). A suite's wait for the review FILE returns once
# it lands, and a runner goes on after that to write the ledger and remove its input, so the state
# is wiped only once no runner holds an input (its .diff, removed last however it ends), waited on
# and bounded rather than slept (L290). test-pr-review-push.sh wiped without it until
# claude-config#1122, which moved this here so the two suites cannot drift apart.
#
# runners_done: 0 once no runner input is left in $AI_REVIEW_STATE_DIR, 1 if one is still there
# after RUNNERS_DONE_BOUND seconds (40 by default).
runners_done() {
  local t0=$SECONDS bound="${RUNNERS_DONE_BOUND:-40}"
  while [ $((SECONDS - t0)) -lt "$bound" ]; do
    compgen -G "$AI_REVIEW_STATE_DIR/*.diff" >/dev/null || compgen -G "$AI_REVIEW_STATE_DIR/parts/*/*.diff" >/dev/null || return 0
    sleep 0.1
  done
  return 1
}
