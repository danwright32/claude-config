#!/usr/bin/env bash
printf '%s PR_REVIEW_READ=%s\n' "$*" "${PR_REVIEW_READ:-}" >> "$ST/review-calls"
case "$1" in
  start) echo "The lessons review started."; exit 0 ;;
  check)
    # on-review: a step run once, while the review is asked, the last thing before the merge's gates.
    if [ -s "$ST/on-review" ]; then s="$(cat "$ST/on-review")"; : > "$ST/on-review"; eval "$s"; fi
    # review-key: findings whose read key is this, so only a check presenting it is allowed, as the
    # real checker judges (claude-config#1673).
    if [ -s "$ST/review-key" ]; then
      if [ "${PR_REVIEW_READ:-}" = "$(cat "$ST/review-key")" ]; then echo "The lessons review finished with 1 finding(s), read: this merge presented their key."; exit 0; fi
      printf 'Refusing to merge until these are read: 1 finding.\n    PR_REVIEW_READ=%s <the merge command>\nApp/x.swift:3: swallows the error (L215).\n' "$(cat "$ST/review-key")"
      exit 1
    fi
    if [ -s "$ST/review-answers" ]; then
      rc="$(head -1 "$ST/review-answers")"; tail -n +2 "$ST/review-answers" > "$ST/review-answers.tmp"; mv "$ST/review-answers.tmp" "$ST/review-answers"
    else rc=0; fi
    case "$rc" in
      0) echo "The lessons review finished with 0 findings." ;;
      3) echo "Refusing to merge yet: the lessons review is still running (1m of 10m)." ;;
      1) printf 'Refusing to merge until these are read: 1 finding.\n    PR_REVIEW_READ=abc123 <the merge command>\nApp/x.swift:3: swallows the error (L215).\n' ;;
    esac
    exit "$rc" ;;
esac
