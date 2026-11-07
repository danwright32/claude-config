#!/usr/bin/env bash
# Tests for lib/tree-proof.sh (claude-config#2310): a head whose tree is byte for byte the tree of a
# parent whose checks all passed, beside a base that parent already held, carries that green, so the
# merge does not wait for a rerun of the same tree. Anything the proof cannot read, or any doubt,
# carries nothing, and the merge waits as it did before.
#
# A fake gh answers from files (the commit graph, each commit's workflow runs, each compare), so no
# case reaches the network (L2), and the record's clock is injected (L524).
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/lib/tree-proof.sh"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $1"; }
check(){ if [[ "$3" == *"$2"* ]]; then ok; else bad "$1"; echo "  expected to contain: $2"; echo "  actual: ${3:0:2000}"; fi; }
check_eq(){ if [[ "$3" == "$2" ]]; then ok; else bad "$1 (expected '$2', got '$3')"; fi; }

HEAD="2222222222222222222222222222222222222222"
P1="1111111111111111111111111111111111111111"
MAIN="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
BASE="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
TREE="7777777777777777777777777777777777777777"
OTHER_TREE="8888888888888888888888888888888888888888"

# --- the fake gh ---------------------------------------------------------------------------------
BIN="$WORKDIR/bin"; mkdir -p "$BIN"
export ST="$WORKDIR/state"
cat > "$BIN/gh" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ST/gh-calls"
case "$*" in
  "auth token"*) echo stand-in ;;
  # The commit graph: graph holds GitHub's answer; graph-fails makes the read fail.
  "api graphql"*)
    [ -s "$ST/graph-fails" ] && { cat "$ST/graph-fails" >&2; exit 1; }
    cat "$ST/graph" ;;
  # A commit's workflow runs: runs-<sha>, or runs-fails to make the read fail.
  "api repos/acme/widget/actions/runs?head_sha="*)
    [ -s "$ST/runs-fails" ] && { cat "$ST/runs-fails" >&2; exit 1; }
    sha="$(printf '%s\n' "$*" | sed -nE 's/.*head_sha=([0-9a-f]+).*/\1/p')"
    if [ -s "$ST/runs-$sha" ]; then cat "$ST/runs-$sha"; else printf '%s\n' '{"total_count":0,"workflow_runs":[]}'; fi ;;
  # Whether a commit contains a base: behind holds behind_by; compare-fails makes it fail.
  "api repos/acme/widget/compare/"*)
    [ -s "$ST/compare-fails" ] && { cat "$ST/compare-fails" >&2; exit 1; }
    printf '{"status":"ahead","ahead_by":3,"behind_by":%s}\n' "$(cat "$ST/behind" 2>/dev/null || echo 0)" ;;
  *) echo "fake gh: unexpected call: $*" >&2; exit 3 ;;
esac
EOS
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"
printf '#!/usr/bin/env bash\ncat "$ST/clock"\n' > "$BIN/fake-now"; chmod +x "$BIN/fake-now"
export TP_NOW="$BIN/fake-now"
export TP_LEDGER_DIR="$WORKDIR/ledger"

# A check run as the commit graph lists it, from workflow run $3 of event $4.
crun(){ jq -nc --arg n "$1" --arg c "$2" --argjson id "$3" --arg e "${4:-pull_request}" --arg st "${5:-COMPLETED}" \
  '{__typename:"CheckRun",name:$n,status:$st,conclusion:$c,startedAt:"2026-11-06T10:00:00Z",checkSuite:{workflowRun:{databaseId:$id,event:$e,workflow:{name:"ci"}}}}'; }
# The commit graph: the head's tree, then each parent as "<oid> <tree> <contexts json>".
graph(){ # graph <head tree> <p1 oid> <p1 tree> <p1 contexts> [<p2 oid> <p2 tree> <p2 contexts>]
  local nodes
  nodes="$(jq -nc --arg o "$2" --arg t "$3" --argjson c "$4" '[{oid:$o,tree:{oid:$t},statusCheckRollup:{contexts:{pageInfo:{hasNextPage:false},nodes:$c}}}]')"
  [ "$#" -ge 7 ] && nodes="$(jq -c --arg o "$5" --arg t "$6" --argjson c "$7" '. + [{oid:$o,tree:{oid:$t},statusCheckRollup:{contexts:{pageInfo:{hasNextPage:false},nodes:$c}}}]' <<<"$nodes")"
  jq -nc --arg h "$HEAD" --arg t "$1" --argjson n "$nodes" '{data:{repository:{object:{oid:$h,tree:{oid:$t},parents:{totalCount:($n|length),nodes:$n}}}}}' > "$ST/graph"
}
# A commit's workflow runs: "<id>:<status>:<conclusion>:<event>:<base sha or empty>".
runs(){ # runs <sha> <spec>...
  local sha="$1"; shift
  printf '%s\n' "$@" | jq -R -s '{total_count:0, workflow_runs:[split("\n")[] | select(. != "") | split(":") |
    {id:(.[0]|tonumber), name:"ci", status:.[1], conclusion:.[2], event:.[3],
     pull_requests:(if .[4] == "" then [] else [{number:7, base:{ref:"main", sha:.[4]}, head:{sha:"x"}}] end)}]}' > "$ST/runs-$sha"
}
fresh(){ rm -rf "$ST" "$TP_LEDGER_DIR"; mkdir -p "$ST"; printf '1000000' > "$ST/clock"; printf '0' > "$ST/behind"; }
HEAD_PENDING='[{"__typename":"CheckRun","name":"tests","workflowName":"ci","status":"IN_PROGRESS","conclusion":"","startedAt":"2026-11-06T11:00:00Z"}]'
HEAD_RED='[{"__typename":"CheckRun","name":"tests","workflowName":"ci","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-11-06T11:00:00Z"}]'
HEAD_OTHER='[{"__typename":"CheckRun","name":"lint","workflowName":"ci","status":"IN_PROGRESS","conclusion":"","startedAt":"2026-11-06T11:00:00Z"}]'
GREEN_P1="[$(crun tests SUCCESS 41)]"
# The proven case: the head's tree is the first parent's, every check of that parent passed in a pull
# request run, and that run's base is held by the parent (compare says 0 behind).
proven(){ fresh; graph "$TREE" "$P1" "$TREE" "$GREEN_P1" "$MAIN" "$OTHER_TREE" "[]"; runs "$P1" "41:completed:success:pull_request:$BASE"; }
prove(){ ( . "$LIB" && tp_carried_green acme/widget "$HEAD" "" "$1"; rc=$?; printf 'rc=%s\nfrom=%s\nwhy=%s\n' "$rc" "$TP_FROM" "$TP_WHY" ); }

# =================================================================================================
# 1. The proof holds: the head carries its parent's green.
# =================================================================================================
proven
out="$(prove "$HEAD_PENDING")"
check "#2310 an identical tree beside a held base carries the parent's green" "rc=0" "$out"
check "#2310 and names the parent it carried from" "from=$P1" "$out"
check "#2310 and says why, byte for byte" "byte for byte the tree of ${P1:0:7}" "$out"
check "#2310 the base the run tested beside was asked about" "compare/$BASE...$P1" "$(cat "$ST/gh-calls")"
# A run whose base IS the parent needs no compare: the parent holds itself.
proven; runs "$P1" "41:completed:success:pull_request:$P1"
out="$(prove "$HEAD_PENDING")"
check "#2310 a run beside the parent itself carries too" "rc=0" "$out"
check_eq "#2310 with no compare asked" "0" "$(grep -c compare "$ST/gh-calls")"

# =================================================================================================
# 2. Every doubt carries nothing.
# =================================================================================================
proven; graph "$OTHER_TREE" "$P1" "$TREE" "$GREEN_P1"
out="$(prove "$HEAD_PENDING")"
check "#2310 a different tree carries nothing" "rc=1" "$out"
check "#2310 saying the tree differs" "differs from" "$out"

proven; printf 'gh: Something went wrong (HTTP 502)\n' > "$ST/graph-fails"
out="$(prove "$HEAD_PENDING")"
# A read that failed is not a judgement: it returns 2, so the helper can ask again at its next look.
check "#2310 a commit graph that cannot be read carries nothing, as unread (2)" "rc=2" "$out"
check "#2310 saying it could not be read, with GitHub's words" "HTTP 502" "$out"

proven; printf 'not json' > "$ST/graph"
out="$(prove "$HEAD_PENDING")"
check "#2310 a commit graph that is not the answer carries nothing, as unread" "rc=2" "$out"

proven
out="$(prove "$HEAD_RED")"
check "#2310 a check on the head that already failed carries nothing" "rc=1" "$out"
check "#2310 saying the head itself failed" "already failed" "$out"

proven
out="$(prove "$HEAD_OTHER")"
check "#2310 a check on the head the parent never passed carries nothing" "rc=1" "$out"
check "#2310 naming it" "ci/lint" "$out"

proven; graph "$TREE" "$P1" "$TREE" "[$(crun tests FAILURE 41)]"
out="$(prove "$HEAD_PENDING")"
check "#2310 a parent whose checks were not all green carries nothing" "rc=1" "$out"

proven; graph "$TREE" "$P1" "$TREE" "[$(crun tests '' 41 pull_request IN_PROGRESS)]"
out="$(prove "$HEAD_PENDING")"
check "#2310 a parent whose checks have not finished carries nothing" "rc=1" "$out"

proven; graph "$TREE" "$P1" "$TREE" "[]"
out="$(prove "$HEAD_PENDING")"
check "#2310 a parent with no checks at all carries nothing" "rc=1" "$out"

proven; graph "$TREE" "$P1" "$TREE" '[{"__typename":"StatusContext","context":"vercel","state":"SUCCESS","createdAt":"2026-11-06T10:00:00Z"}]'
out="$(prove "$HEAD_PENDING")"
check "#2310 a status from outside Actions carries nothing: what it tested is unknown" "rc=1" "$out"
check "#2310 naming it" "vercel" "$out"

proven; printf 'gh: Server Error (HTTP 500)\n' > "$ST/runs-fails"
out="$(prove "$HEAD_PENDING")"
check "#2310 workflow runs that cannot be read carry nothing, as unread" "rc=2" "$out"
check "#2310 saying so" "HTTP 500" "$out"

proven; runs "$P1" "41:in_progress::pull_request:$BASE"
out="$(prove "$HEAD_PENDING")"
check "#2310 a run of the parent that has not finished carries nothing" "rc=1" "$out"

proven; runs "$P1" "41:completed:failure:pull_request:$BASE"
out="$(prove "$HEAD_PENDING")"
check "#2310 a run of the parent that did not pass carries nothing" "rc=1" "$out"

proven; runs "$P1" "41:completed:success:pull_request:"
out="$(prove "$HEAD_PENDING")"
check "#2310 a run naming no pull request base carries nothing" "rc=1" "$out"
check "#2310 saying what it tested beside is unknown" "unknown" "$out"

proven; runs "$P1" "41:completed:success:push:"
out="$(prove "$HEAD_PENDING")"
check "#2310 a run from another event carries nothing" "rc=1" "$out"

proven; runs "$P1" "99:completed:success:pull_request:$BASE"
out="$(prove "$HEAD_PENDING")"
check "#2310 a check whose run is not among the parent's runs carries nothing" "rc=1" "$out"

proven; printf '2' > "$ST/behind"
out="$(prove "$HEAD_PENDING")"
check "#2310 a run beside a base the parent did not hold carries nothing" "rc=1" "$out"
check "#2310 saying so, naming the base" "${BASE:0:7}" "$out"

proven; printf 'gh: Not Found (HTTP 404)\n' > "$ST/compare-fails"
out="$(prove "$HEAD_PENDING")"
check "#2310 a containment that cannot be read carries nothing, as unread" "rc=2" "$out"

# The second parent (main's tip) has the same tree but was tested by a push run: never carried.
fresh; graph "$TREE" "$P1" "$OTHER_TREE" "$GREEN_P1" "$MAIN" "$TREE" "[$(crun tests SUCCESS 52 push)]"
runs "$MAIN" "52:completed:success:push:"
out="$(prove "$HEAD_PENDING")"
check "#2310 main's tip with the same tree, tested by a push, carries nothing" "rc=1" "$out"

# =================================================================================================
# 3. The record: each decision a line, and a reader that counts them.
# =================================================================================================
fresh
out="$( . "$LIB" && tp_record merge-when-ready acme/widget 7 "$HEAD" taken "$P1" "its tree is the same" && printf '1000060' > "$ST/clock" && tp_record merge-when-ready acme/widget 8 "$HEAD" not-taken "" "its tree differs"; echo "rc=$?")"
check_eq "#2310 recording a decision succeeds" "rc=0" "$out"
check_eq "#2310 one line per decision" "2" "$(wc -l < "$TP_LEDGER_DIR/decisions.tsv" | tr -d ' ')"
check "#2310 each line carries time, who, repository, pull request, head, outcome and parent" "$(printf '1000000\tmerge-when-ready\tacme/widget\t7\t%s\ttaken\t%s\t' "$HEAD" "$P1")" "$(cat "$TP_LEDGER_DIR/decisions.tsv")"
out="$(bash "$LIB" rate)"
check "#2310 the reader counts how often it was taken of how often it was considered" "taken 1 of 2" "$out"
# A head weighed more than once (an unread proof asked again, a refusal after a carry) counts once,
# by its last decision.
( . "$LIB" && tp_record merge-when-ready acme/widget 9 "$P1" not-taken "" "could not read" && tp_record merge-when-ready acme/widget 9 "$P1" taken "$P1" "same tree" \
    && tp_record merge-when-ready acme/widget 10 "$MAIN" taken "$P1" "same tree" && tp_record merge-when-ready acme/widget 10 "$MAIN" not-taken "" "the checks gate refused it" )
out="$(bash "$LIB" rate)"
check "#2310 each head counts once, by its last decision" "taken 2 of 4" "$out"
rm -rf "$TP_LEDGER_DIR"
out="$(bash "$LIB" rate)"
check "#2310 with nothing recorded the reader says so rather than a zero rate" "nothing recorded" "$out"
# A record that cannot be written says so, and returns non zero.
fresh; mkdir -p "$TP_LEDGER_DIR"; : > "$TP_LEDGER_DIR/decisions.tsv"; chmod 0444 "$TP_LEDGER_DIR/decisions.tsv"
out="$( . "$LIB" && tp_record merge-when-ready acme/widget 7 "$HEAD" taken "$P1" x 2>&1; echo "rc=$?")"
check "#2310 a record that cannot be written returns non zero" "rc=1" "$out"
check "#2310 and says where" "$TP_LEDGER_DIR/decisions.tsv" "$out"
chmod 0644 "$TP_LEDGER_DIR/decisions.tsv"
# Tabs and newlines in a reason cannot break a line.
fresh
( . "$LIB" && tp_record merge-when-ready acme/widget 7 "$HEAD" not-taken "" "$(printf 'a\tb\nc')" )
check_eq "#2310 a reason with a tab and a newline stays one line" "1" "$(wc -l < "$TP_LEDGER_DIR/decisions.tsv" | tr -d ' ')"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
