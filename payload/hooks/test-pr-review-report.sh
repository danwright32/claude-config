#!/usr/bin/env bash
# Tests for lib/pr-review-report.sh, the measurement claude-config#562 gates the lessons core on.
#
# The ledgers are written by the real ar_pr_ledger and ar_pr_opened from lib/ai-review-common.sh over
# fixture review files, so the report is tested against what the writers produce rather than against
# lines typed to suit it (L58). A fake gh answers which pull request a commit belongs to and what the
# rate limit is, and logs every call so a test can count them and prove the fake was reached (L143).
# The "GitHub" remote is a local bare repository reached through a url.insteadOf rewrite, and git may
# use the file protocol only, so nothing can reach the network or Dan's review state (L2).
#
# claude-config#1006: openings are counted by pull request, GitHub lookups are batched and held to a
# budget, and the report never fetches into a person's checkout.
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
check_eq(){ if [ "$3" = "$2" ]; then ok; else bad "$1"; echo "  expected: $2"; echo "  actual: $3"; fi; }

export AI_REVIEW_STATE_DIR="$WORKDIR/state"
export AI_REVIEW_HOST="test-mac"
mkdir -p "$AI_REVIEW_STATE_DIR"

# --- git isolated from this machine's config, and from the network ---
export GIT_CONFIG_GLOBAL="$WORKDIR/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
export GIT_ALLOW_PROTOCOL=file
ORIGIN="$WORKDIR/origin.git"
SLUG_URL="https://github.com/test-owner/repo.git"
git config --file "$GIT_CONFIG_GLOBAL" user.name t
git config --file "$GIT_CONFIG_GLOBAL" user.email t@t
git config --file "$GIT_CONFIG_GLOBAL" commit.gpgsign false
git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
git config --file "$GIT_CONFIG_GLOBAL" "url.$ORIGIN.insteadOf" "$SLUG_URL"
git init -q --bare "$ORIGIN"

# --- the person's primary checkout, and pull requests on the "GitHub" side ---
REPO="$WORKDIR/primary"; mkdir -p "$REPO/App"; git init -q "$REPO"
G(){ git -C "$REPO" "$@"; }
G remote add origin "$SLUG_URL"
printf 'a\n' > "$REPO/App/A.swift"; printf 'b\n' > "$REPO/App/B.swift"; printf 'c\n' > "$REPO/App/C.swift"
printf 'r\n' > "$REPO/README.md"
G add -A; G commit -q -m seed; SEED="$(G rev-parse HEAD)"
G push -q origin HEAD:refs/heads/main
branch(){ G checkout -q -B "$1" "$SEED"; }
edit(){ printf '%s\n' "$2" > "$REPO/$1"; G commit -q -am "$3"; G rev-parse HEAD; }
branch p1; S1="$(edit App/A.swift a2 'reviewed one')"; S2="$(edit App/A.swift a3 'fix after review')"
branch p2; S3="$(edit App/B.swift b2 'reviewed two')"; S4="$(edit README.md r2 'unrelated')"
branch p3; S5="$(edit README.md r3 'clean')"
branch p4; S6="$(edit README.md r4 'timed out')"
branch p6; S7="$(edit README.md r6 'could not run')"
branch p5; S8="$(edit App/C.swift c2 'reviewed five')"
branch p10; S10="$(edit README.md r10 'never pushed')"
G checkout -q main 2>/dev/null || G checkout -q -B main "$SEED"
G push -q origin "$S2:refs/pull/1/head" "$S4:refs/pull/2/head" "$S5:refs/pull/3/head" \
  "$S6:refs/pull/4/head" "$S7:refs/pull/6/head" "$S8:refs/pull/5/head"
# Pull request 5's final head exists only on "GitHub": made in another clone, never in the primary.
OTHER="$WORKDIR/other"; git clone -q "$SLUG_URL" "$OTHER"
git -C "$OTHER" fetch -q origin "refs/pull/5/head:p5"; git -C "$OTHER" checkout -q p5
printf 'c3\n' > "$OTHER/App/C.swift"; git -C "$OTHER" commit -q -am 'fix five'
S9="$(git -C "$OTHER" rev-parse HEAD)"
git -C "$OTHER" push -q origin "+$S9:refs/pull/5/head"
if G cat-file -e "$S9^{commit}" 2>/dev/null; then bad "fixture: pull request 5's final head must not be in the primary"; fi

# --- the fake gh: which pull request holds a commit, and the rate limit ---
now="$(date +%s)"
PRMAP="$WORKDIR/prmap"
printf '%s\t%s\t%s\t%s\n' \
  "$S1" 1 "$S2" "$now" "$S2" 1 "$S2" "$now" "$S3" 2 "$S4" "$now" "$S4" 2 "$S4" "$now" \
  "$S5" 3 "$S5" "$now" "$S6" 4 "$S6" "$now" "$S7" 6 "$S7" "$now" "$S8" 5 "$S9" "$now" > "$PRMAP"
export PRMAP
export GH_LOG="$WORKDIR/gh.log"
FAKEBIN="$WORKDIR/bin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/gh" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 ${2:-}" in
  "api rate_limit")
    # The REST view always looks healthy here. Measured 2026-10-09, it reported 4,876 GraphQL points
    # left while GraphQL's own rateLimit reported 502, so a check reading it must fail these tests.
    printf '5000 5000 1760000000\n' ;;
  "api graphql")
    case "$*" in *rateLimit*)
      [ -n "${RL_FAIL:-}" ] && { echo "HTTP 503: Service Unavailable" >&2; exit 1; }
      # What the report's --jq makes of GraphQL's own rateLimit: remaining, limit, reset (epoch).
      printf '%s %s %s\n' "${RL_REMAINING:-5000}" 5000 "${RL_RESET:-1760000000}"; exit 0 ;;
    esac
    [ -n "${GH_GRAPHQL_FAIL:-}" ] && { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
    # What the report's --jq turns the answer into: one line per pull request holding each commit.
    for sha in $(printf '%s' "$*" | grep -oE 'c[0-9a-f]{40}:' | sed 's/^c//; s/:$//'); do
      awk -F '\t' -v s="$sha" '$1 == s' "$PRMAP"
    done ;;
  "api repos/"*)
    # The REST form the report used before #1006, so the old code can be run against these tests.
    sha="$(printf '%s' "$2" | sed -n 's#.*/commits/\([0-9a-f]*\)/pulls.*#\1#p')"
    awk -F '\t' -v s="$sha" '$1 == s { print $3; exit }' "$PRMAP" ;;
  *) exit 1 ;;
esac
EOS
chmod +x "$FAKEBIN/gh"
export PATH="$FAKEBIN:$PATH"

review(){ # review <sha> <status> <findings> <body>: a finished review file, recorded by the real writer
  local f="$WORKDIR/r-$1-$2.txt"
  printf 'repo=repo\nbranch=b\nsha=%s\nstarted=%s\nfinished=%s\nstatus=%s\nkind=pr\nbase=x\nfindings=%s\n\n%s\n' \
    "$1" "$((now - 200))" "$now" "$2" "$3" "$4" > "$f"
  bash -c '. "$1/lib/ai-review-common.sh"; ar_pr_ledger "$2" "$3"' _ "$DIR" "$f" "$REPO"
}
opened(){ bash -c '. "$1/lib/ai-review-common.sh"; ar_pr_opened repo "$2" "$3"' _ "$DIR" "${2:-$REPO}" "$1"; }

run(){ : > "$GH_LOG"; bash "$REPORT" "$@" 2>&1; }
calls(){ awk -v p="$1" 'index($0, p) == 1 { n++ } END { print n + 0 }' "$GH_LOG"; }
lookups(){ awk '/^api graphql/ && !/rateLimit/ { n++ } END { print n + 0 }' "$GH_LOG"; }
ratereads(){ awk '/^api graphql/ && /rateLimit/ { n++ } END { print n + 0 }' "$GH_LOG"; }

# 1. Too few pull requests is UNMEASURED, never a verdict (L716).
opened "$S1"
review "$S1" ok 1 "App/A.swift:1: a finding (L11). Should be: fixed. [severity: minor]"
out="$(run)"
check "the report names this Mac" "test-mac" "$out"
check "a thin window is unmeasured, not a pass" "UNMEASURED" "$out"
check_not "and never says the gate is met" "GATE MET" "$out"

# 2. A full window, counted by pull request. Pull request 1 is opened three times: twice at S1 (a
# second gh pr create on a branch that already has one) and once at its later head S2.
opened "$S1"; opened "$S2"; opened "$S3"; opened "$S5"; opened "$S6"; opened "$S7"
review "$S3" ok 1 "App/B.swift:1: another finding (L215). Should be: fixed. [severity: major]"
review "$S5" ok 0 "No issues found."
review "$S6" timeout "" "did not finish"
review "$S7" could-not-run "" "python3 missing"
out="$(run)"
check "counts pull requests, not openings" "pull requests opened: 5" "$out"
check "keeps the opening count beside it, labelled as openings" "from 7 gh pr create openings" "$out"
check "counts finished reviews" "finished: 3" "$out"
check "names each outcome that did not finish" "timeout 1" "$out"
check "including could not run" "could-not-run 1" "$out"
check "a pull request is reviewed when any of its openings had a finished review of that head" \
  "pull requests with a finished review of a head they were opened at: 3 of 5 (60%)" "$out"
check "the per opening share stays visible, labelled as openings" "openings with a finished review of that head: 4 of 7" "$out"
check "counts findings per finished review" "total 2" "$out"
check "a flagged file changed later counts as acted on" "acted on 1" "$out"
check "one never changed again counts as not acted on" "not acted on 1" "$out"
check "a share under nearly every is not met" "GATE NOT MET" "$out"
check "the verdict is about pull requests" "60% of pull requests opened" "$out"
check_eq "seven openings over five pull requests take ONE batched GitHub lookup" 1 "$(lookups)"
check_eq "and no call per pull request's commits, let alone per review" 0 "$(awk '/pulls\/[0-9]+\/commits|commits\/[0-9a-f]+\/pulls/ { n++ } END { print n + 0 }' "$GH_LOG")"
check_eq "the allowance is read once, from GraphQL itself, before any lookup" 1 "$(ratereads)"
check_eq "never from the REST rate_limit view, which reports a different bucket" 0 "$(calls 'api rate_limit')"

# 3. The window: an opening older than it is not counted.
printf '%s\t%s\t%s\t%s\t%s\n' "$((now - 40 * 86400))" test-mac repo "$REPO" "$S4" >> "$AI_REVIEW_STATE_DIR/pr-opened.tsv"
out="$(run --days 21)"
check "an opening outside the window is not counted" "pull requests opened: 5 (from 7 gh pr create openings" "$out"

# 4. A pull request GitHub cannot name is unmeasured, never not acted on, and says why.
review "$S10" ok 1 "App/A.swift:9: third (L1). Should be: x. [severity: minor]"
out="$(run)"
check "a review whose pull request cannot be found is unmeasured" "unmeasured 1 (GitHub found no pull request 1)" "$out"

# 5. No ledgers at all is said as such, not as zeros (L98).
out="$(AI_REVIEW_STATE_DIR="$WORKDIR/empty" run)"
check "no ledger is a statement that nothing was recorded" "no pull request has been recorded" "$out"

# 6. A final head the checkout does not hold is fetched into a scratch repository, never into the
# person's checkout, and is still measured (L159: the positive and the negative in one fixture).
review "$S8" ok 1 "App/C.swift:1: fifth (L5). Should be: y. [severity: minor]"
snap(){ { G for-each-ref; find "$REPO/.git" -type f -exec ls -ln {} + | awk '{ print $5, $NF }' | sort; } 2>/dev/null; }
before="$(snap)"
out="$(run)"
check "a final head only GitHub holds is still measured" "acted on 2" "$out"
check "through one scratch fetch" "1 scratch fetch" "$out"
check_eq "nothing in the primary checkout was written" "$before" "$(snap)"
if G cat-file -e "$S9^{commit}" 2>/dev/null; then bad "the final head was fetched into the primary checkout"; else ok; fi

# 7. A worktree folder deleted since its opening is placed by the checkout around it; a folder in no
# checkout at all is unmeasured with its own reason.
opened "$S3" "$REPO/.claude/worktrees/gone"
mkdir -p "$WORKDIR/nowhere"; opened "$S5" "$WORKDIR/nowhere/x"
out="$(run)"
check "a deleted worktree's opening still counts toward its pull request" "pull requests opened: 5 (from 9 gh pr create openings" "$out"
check "an opening in no checkout is named, not dropped" "openings not tied to a pull request: 1 (folder or GitHub remote gone 1)" "$out"
check_eq "still one lookup call for five pull requests" 1 "$(lookups)"

# 8. The call budget: past it, the rest is UNMEASURED with its count, never zero (L90, L331).
shas_sorted="$(printf '%s\n' "$S1" "$S2" "$S3" "$S5" "$S6" "$S7" "$S8" "$S10" | sort)"
looked="$(printf '%s\n' "$shas_sorted" | head -2)"
skipped(){ local n=0 s; for s in "$@"; do case "$looked" in *"$s"*) ;; *) n=$((n + 1)) ;; esac; done; echo "$n"; }
# Every opening in the window whose folder resolves (the one in no checkout is never looked up).
exp_o="$(skipped "$S1" "$S1" "$S2" "$S3" "$S5" "$S6" "$S7" "$S3")"
exp_r="$(skipped "$S1" "$S3" "$S10" "$S8")"
out="$(PR_REVIEW_REPORT_CALL_BUDGET=1 PR_REVIEW_REPORT_BATCH=2 run)"
check_eq "the budget stops the lookups at one call" 1 "$(lookups)"
check "openings past the budget are counted as unmeasured" "call budget of 1 reached $exp_o" "$out"
if [ "$exp_r" -gt 0 ]; then
  check "reviews past the budget are counted as unmeasured" "call budget of 1 reached $exp_r)" "$out"
fi
check "the pull request count past the budget is a floor, and says so" "pull requests opened: at least" "$out"
check "and so is the share per pull request" "the rest UNMEASURED" "$out"
check "a budget cut window has no verdict" "UNMEASURED (#562)" "$out"
check_not "and never a gate reading" "GATE" "$out"

# 9. Too little rate limit headroom refuses to start, naming why; enough runs (the same fixture).
out="$(RL_REMAINING=599 run)"; rc=$?
check "low headroom refuses" "refusing to start" "$out"
check "naming what is left and what it would need" "599 of 5000" "$out"
check "and the budget plus margin" "budget of 100 plus a margin of 500" "$out"
check_eq "a refusal exits as a temporary failure" 75 "$rc"
check_eq "and makes no lookup" 0 "$(lookups)"
out="$(RL_REMAINING=600 run)"; rc=$?
check_eq "exactly the budget plus margin is enough" 0 "$rc"
check "and the report runs" "pull requests opened: 5" "$out"

# 10. A rate limit that cannot be read refuses too, rather than spending blind.
out="$(RL_FAIL=1 run)"; rc=$?
check "an unreadable rate limit refuses" "could not read GitHub's rate limit" "$out"
check "naming what gh said" "HTTP 503" "$out"
check_eq "as a temporary failure" 75 "$rc"
check_eq "with no lookup" 0 "$(lookups)"

# 11. A lookup that fails is its own reason, and the window has no verdict.
out="$(GH_GRAPHQL_FAIL=1 run)"
check "a failed lookup is named" "GitHub lookup failed" "$out"
check "and leaves the window unmeasured" "UNMEASURED (#562)" "$out"

# 12. --no-github asks GitHub nothing and still prints what the ledgers alone can say.
out="$(run --no-github)"
check_eq "no gh call at all" "" "$(cat "$GH_LOG")"
check "pull requests cannot be counted without GitHub" "pull requests opened: UNMEASURED" "$out"
check "the opening share is still printed" "openings with a finished review of that head:" "$out"
check "and there is no verdict" "UNMEASURED (#562)" "$out"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
