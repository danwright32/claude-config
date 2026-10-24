#!/usr/bin/env bash
# Tests for lib/checkout-root.sh (claude-config#1567): the one test of whether a folder is the payload
# of a claude-config checkout, which every whole tree scan suite asks before it lists the files the
# repository ships. A git repository above the copy is not enough: a copy sitting inside some other
# repository (a home folder kept in git) would otherwise scan that repository instead.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$DIR/lib/checkout-root.sh"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/checkout-root.XXXXXXXX")" || TMPROOT=""
[ -n "$TMPROOT" ] && [ -d "$TMPROOT" ] || { echo "FAIL: could not make a scratch folder"; printf 'SUITE-RESULT passed=0 failed=1\n'; exit 1; }
trap 'rm -rf "$TMPROOT"' EXIT

pass=0
fail=0
check_eq() { if [[ "$3" == "$2" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 (expected '$2', got '$3')"; fi; }
real() { (cd "$1" 2>/dev/null && pwd -P); }
not_run() { case "$1" in "SUITE-NOT-RUN "*|*$'\n'"SUITE-NOT-RUN "*) echo yes ;; *) echo no ;; esac; }

# ---- the helper itself ----
# This suite's own payload, when it sits in a checkout, is one; the top level is printed.
SELF_TOP="$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$SELF_TOP" ] && [ -f "$SELF_TOP/claude-sync" ] && [ "$(real "$SELF_TOP/payload")" = "$(real "$DIR/..")" ]; then
  out="$(bash "$HELPER" "$DIR/.." 2>/dev/null)"; rc=$?
  check_eq "this checkout's payload is a checkout, and its top level is printed" "0 $(real "$SELF_TOP")" "$rc $(real "$out")"
else
  echo "SUITE-PART-UNMEASURED this copy is not in a claude-config checkout, so the real checkout case was not measured here"
fi

# A fixture checkout: claude-sync and payload/ at the top of a repository.
mkdir -p "$TMPROOT/checkout/payload/hooks" "$TMPROOT/checkout/other/payload"
: > "$TMPROOT/checkout/claude-sync"
git init -q "$TMPROOT/checkout" 2>/dev/null
out="$(bash "$HELPER" "$TMPROOT/checkout/payload" 2>/dev/null)"; rc=$?
check_eq "a checkout's payload is one" "0 $(real "$TMPROOT/checkout")" "$rc $(real "$out")"
out="$(bash "$HELPER" "$TMPROOT/checkout/other/payload" 2>&1)"; rc=$?
check_eq "a folder named payload elsewhere in that checkout is not its payload" "1" "$rc"
out="$(bash "$HELPER" "$TMPROOT/checkout/payload/hooks" 2>&1)"; rc=$?
check_eq "nor is a folder inside the payload" "1" "$rc"

# A copy inside an unrelated repository: a repository, but not this one.
mkdir -p "$TMPROOT/dotfiles/.claude/hooks"
git init -q "$TMPROOT/dotfiles" 2>/dev/null
out="$(bash "$HELPER" "$TMPROOT/dotfiles/.claude" 2>&1)"; rc=$?
check_eq "a copy inside an unrelated repository is no checkout" "1" "$rc"
case "$out" in *"$TMPROOT/dotfiles/.claude"*) said=yes ;; *) said=no ;; esac
check_eq "and the refusal names the folder" "yes" "$said"

# An unrelated repository that happens to hold a claude-sync and a payload/, the copy elsewhere in it.
mkdir -p "$TMPROOT/lookalike/payload" "$TMPROOT/lookalike/.claude"
: > "$TMPROOT/lookalike/claude-sync"
git init -q "$TMPROOT/lookalike" 2>/dev/null
out="$(bash "$HELPER" "$TMPROOT/lookalike/.claude" 2>&1)"; rc=$?
check_eq "a copy beside a lookalike checkout's payload is not that payload" "1" "$rc"

# No repository at all, and a folder that does not exist.
mkdir -p "$TMPROOT/installed/.claude"
out="$(bash "$HELPER" "$TMPROOT/installed/.claude" 2>&1)"; rc=$?
check_eq "an installed copy with no repository is no checkout" "1" "$rc"
out="$(bash "$HELPER" "$TMPROOT/no-such-folder" 2>&1)"; rc=$?
check_eq "a folder that does not exist is no checkout" "1" "$rc"
out="$(bash "$HELPER" 2>&1)"; rc=$?
check_eq "no folder given is a usage error" "2" "$rc"

# ---- the whole tree scan suites, each copied into an unrelated repository ----
# Before #1567 three of them took any git repository above them for this one and scanned it. Each
# copy here sits in a home folder kept in git, holding the hooks and nothing of this repository's,
# so each must say it cannot run rather than judge somebody else's files. Nothing in the copies is
# committed, so each is a file the unrelated repository would list.
HOME_REPO="$TMPROOT/home"
mkdir -p "$HOME_REPO/.claude"
cp -R "$DIR" "$HOME_REPO/.claude/hooks"
git init -q "$HOME_REPO" 2>/dev/null
for suite in test-two-file-awk.sh test-pipefail-shortcircuit.sh test-lib-self-locate.sh test-branch-issue-reader.sh; do
  [ -f "$HOME_REPO/.claude/hooks/$suite" ] || { check_eq "$suite is there to copy" yes no; continue; }
  out="$(env -u TWO_FILE_AWK_ROOT -u SHORTCIRCUIT_ROOT -u LIB_SELF_LOCATE_ROOT -u SHORTCIRCUIT_NESTED \
    BRANCH_READER_SCAN_ONLY=1 bash "$HOME_REPO/.claude/hooks/$suite" 2>&1)"; rc=$?
  check_eq "$suite, copied into an unrelated repository, says it cannot run there" "2 yes" "$rc $(not_run "$out")"
done

# ---- one test, in one place ----
# Every one of the four finds its checkout through the helper, and none keeps a hand written
# `rev-parse --show-toplevel` of its own to find the root it scans (L613).
for suite in test-two-file-awk.sh test-pipefail-shortcircuit.sh test-lib-self-locate.sh test-branch-issue-reader.sh; do
  body="$(cat "$DIR/$suite" 2>/dev/null)"
  case "$body" in *'lib/checkout-root.sh'*) uses=yes ;; *) uses=no ;; esac
  case "$body" in *'rev-parse --show-toplevel'*) own=yes ;; *) own=no ;; esac
  check_eq "$suite finds its checkout through lib/checkout-root.sh, with no test of its own" "yes no" "$uses $own"
done

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
