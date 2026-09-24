#!/usr/bin/env bash
# Tests for lib/pr-review-report.sh, the measurement claude-config#562 gates the lessons core on.
#
# The ledgers are written by the real ar_pr_ledger and ar_pr_opened from lib/ai-review-common.sh over
# fixture review files, so the report is tested against what the writers produce rather than against
# lines typed to suit it (L58). A fake gh answers which pull request a commit belongs to, and the
# repository is a throwaway, so nothing reaches the network or Dan's review state (L2).
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT="$DIR/lib/pr-review-report.sh"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $1"; }
check(){ if [[ "$3" == *"$2"* ]]; then ok; else bad "$1"; echo "  expected to contain: $2"; echo "  actual: ${3:0:2000}"; fi; }
check_not(){ if [[ "$3" != *"$2"* ]]; then ok; else bad "$1"; echo "  must not contain: $2"; fi; }

export AI_REVIEW_STATE_DIR="$WORKDIR/state"
export AI_REVIEW_HOST="test-mac"
mkdir -p "$AI_REVIEW_STATE_DIR"

# --- a repository where one flagged file was changed after its review and one was not ---
REPO="$WORKDIR/repo"; mkdir -p "$REPO/App"; git init -q "$REPO"
G(){ git -C "$REPO" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
printf 'a\n' > "$REPO/App/A.swift"; printf 'b\n' > "$REPO/App/B.swift"; printf 'r\n' > "$REPO/README.md"
G add -A; G commit -q -m seed
printf 'a2\n' > "$REPO/App/A.swift"; G commit -q -am "reviewed one"; S1="$(G rev-parse HEAD)"
printf 'a3\n' > "$REPO/App/A.swift"; G commit -q -am "fix after review"; S2="$(G rev-parse HEAD)"
printf 'b2\n' > "$REPO/App/B.swift"; G commit -q -am "reviewed two"; S3="$(G rev-parse HEAD)"
printf 'r2\n' > "$REPO/README.md"; G commit -q -am "unrelated"; S4="$(G rev-parse HEAD)"
S5="$(G rev-parse HEAD~4)"

FAKEBIN="$WORKDIR/bin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/gh" <<EOS
#!/usr/bin/env bash
case "\$*" in
  *"commits/$S1/pulls"*) printf '%s\n' "$S2" ;;
  *"commits/$S3/pulls"*) printf '%s\n' "$S4" ;;
  *) exit 0 ;;
esac
EOS
chmod +x "$FAKEBIN/gh"
export PATH="$FAKEBIN:$PATH"

now="$(date +%s)"
review(){ # review <sha> <status> <findings> <body>: a finished review file, recorded by the real writer
  local f="$WORKDIR/r-$1-$2.txt"
  printf 'repo=repo\nbranch=b\nsha=%s\nstarted=%s\nfinished=%s\nstatus=%s\nkind=pr\nbase=x\nfindings=%s\n\n%s\n' \
    "$1" "$((now - 200))" "$now" "$2" "$3" "$4" > "$f"
  bash -c '. "$1/lib/ai-review-common.sh"; ar_pr_ledger "$2" "$3"' _ "$DIR" "$f" "$REPO"
}
opened(){ bash -c '. "$1/lib/ai-review-common.sh"; ar_pr_opened repo "$2" "$3"' _ "$DIR" "$REPO" "$1"; }

run(){ bash "$REPORT" "$@" 2>&1; }

# 1. Too few pull requests is UNMEASURED, never a verdict (L716).
opened "$S1"
review "$S1" ok 1 "App/A.swift:1: a finding (L11). Should be: fixed. [severity: minor]"
out="$(run)"
check "the report names this Mac" "test-mac" "$out"
check "a thin window is unmeasured, not a pass" "UNMEASURED" "$out"
check_not "and never says the gate is met" "GATE MET" "$out"

# 2. A full window: five openings, outcomes of several kinds, acted on and not.
opened "$S3"; opened "$S5"; opened "aaaa"; opened "bbbb"
review "$S3" ok 1 "App/B.swift:1: another finding (L215). Should be: fixed. [severity: major]"
review "$S5" ok 0 "No issues found."
review "aaaa" timeout "" "did not finish"
review "bbbb" could-not-run "" "python3 missing"
out="$(run)"
check "counts the pull requests opened" "pull requests opened: 5" "$out"
check "counts finished reviews" "finished: 3" "$out"
check "names each outcome that did not finish" "timeout 1" "$out"
check "including could not run" "could-not-run 1" "$out"
check "gives the share of openings with a finished review" "3 of 5" "$out"
check "counts findings per finished review" "total 2" "$out"
check "a flagged file changed later counts as acted on" "acted on 1" "$out"
check "one never changed again counts as not acted on" "not acted on 1" "$out"
check "a share under nearly every is not met" "GATE NOT MET" "$out"

# 3. The window: an opening older than it is not counted.
printf '%s\t%s\t%s\t%s\t%s\n' "$((now - 40 * 86400))" test-mac repo "$REPO" old > "$AI_REVIEW_STATE_DIR/pr-opened.tsv.old"
cat "$AI_REVIEW_STATE_DIR/pr-opened.tsv.old" >> "$AI_REVIEW_STATE_DIR/pr-opened.tsv"
out="$(run --days 21)"
check "an opening outside the window is not counted" "pull requests opened: 5" "$out"

# 4. A pull request gh cannot name is unmeasured, never not acted on.
opened "cccc"
review "cccc" ok 1 "App/A.swift:9: third (L1). Should be: x. [severity: minor]"
out="$(run)"
check "a review whose pull request cannot be found is unmeasured" "unmeasured 1" "$out"

# 5. No ledgers at all is said as such, not as zeros (L98).
out="$(AI_REVIEW_STATE_DIR="$WORKDIR/empty" run)"
check "no ledger is a statement that nothing was recorded" "no pull request has been recorded" "$out"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
