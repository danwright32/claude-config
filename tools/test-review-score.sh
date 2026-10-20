#!/usr/bin/env bash
# Tests for tools/review-score.py, the scorer for the pre merge lessons review (claude-config#1355).
#
# The scorer runs the REAL runner (payload/hooks/lib/ai-review-run.py) over each case, so a fake
# claude on PATH stands in for the model: no test here ever calls a real model. The fake answers
# from files this suite writes, chosen by which invented file the review input names, and it
# answers the way `claude -p --output-format json` does when asked to, since the scorer reads the
# cost of each review from that.
#
# The case set is the invented public sample in tools/review-score-sample (no real code: the real
# judged set quotes private code and stays on the Mac outside this repository), copied into a
# scratch directory so a test can add cases without touching the committed sample.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$DIR/review-score.py"
SAMPLE="$DIR/review-score-sample"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
check(){ if [[ "$3" == *"$2"* ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; echo "  expected to contain: $2"; echo "  actual: ${3:0:2500}"; fi; }
check_not(){ if [[ "$3" != *"$2"* ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 (must not contain '$2')"; echo "  actual: ${3:0:2500}"; fi; }
check_rc(){ if [[ "$3" -eq "$2" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 (exit $3, expected $2)"; fi; }

# --- the fake claude -------------------------------------------------------------------------
FAKEBIN="$WORK/bin"; mkdir -p "$FAKEBIN"
export FAKE_DIR="$WORK/fake"; mkdir -p "$FAKE_DIR/answers"
cat > "$FAKEBIN/claude" <<'EOS'
#!/usr/bin/env bash
printf 'called\n' >> "$FAKE_DIR/calls"
printf '%s\x1e' "$@" > "$FAKE_DIR/args"
cat > "$FAKE_DIR/stdin.$$"
answer=""
for f in "$FAKE_DIR"/answers/*.txt; do
  [ -f "$f" ] || continue
  token="$(head -1 "$f")"
  if grep -qF -- "$token" "$FAKE_DIR/stdin.$$"; then answer="$f"; break; fi
done
if [ -n "${FAKE_FAIL_TOKEN:-}" ] && grep -qF -- "$FAKE_FAIL_TOKEN" "$FAKE_DIR/stdin.$$"; then
  echo "fake claude: refusing on purpose" >&2
  exit 1
fi
# Fail exactly one call: whichever call removes the marker file first.
if [ -n "${FAKE_FAIL_ONCE:-}" ] && rm "$FAKE_FAIL_ONCE" 2>/dev/null; then
  echo "fake claude: failing this one call on purpose" >&2
  exit 1
fi
text="No issues found."
[ -n "$answer" ] && text="$(tail -n +2 "$answer")"
json=0
prev=""
for a in "$@"; do
  [ "$prev" = "--output-format" ] && [ "$a" = "json" ] && json=1
  prev="$a"
done
if [ "$json" = 1 ]; then
  FAKE_TEXT="$text" python3 -c 'import json, os; print(json.dumps({"type": "result", "is_error": False, "result": os.environ["FAKE_TEXT"], "total_cost_usd": 0.05, "usage": {"input_tokens": 1000, "cache_creation_input_tokens": 200, "cache_read_input_tokens": 300, "output_tokens": 50}}))'
else
  printf '%s\n' "$text"
fi
EOS
chmod +x "$FAKEBIN/claude"

# answer <name> <token the review input must contain> <review text>
answer(){ printf '%s\n%s\n' "$2" "$3" > "$FAKE_DIR/answers/$1.txt"; }
calls(){ [ -f "$FAKE_DIR/calls" ] && wc -l < "$FAKE_DIR/calls" | tr -d ' ' || echo 0; }

PAGINATE_GOOD='shop/paginate.py:12: page_count floors the division, so a partial last page is not counted. Should be: round up. [severity: major]
shop/paginate.py:16: range stops at len(items) - 1, so a list of one item gives no pages (off by one). Should be: range(0, len(items), size). [severity: major]
shop/paginate.py:13: size of zero is not checked before dividing. Should be: check it. [severity: minor]
shop/paginate.py:21: page does not validate size like its siblings. Should be: raise on size <= 0. [severity: minor]
shop/paginate.py:2: the module docstring is vague about which screen. Should be: name it. [severity: minor]'
RETRY_GOOD='report/send.sh:6: the upload ends in || true, which swallows the failure, so the retry never runs and sent prints on a failed upload. Should be: let the status through. [severity: critical]
report/send.sh:11: the loop runs 4 times, one more than the 3 tries it reports (off by one). Should be: -lt 3. [severity: minor]'

CASES="$WORK/cases"; cp -R "$SAMPLE" "$CASES"
RESULTS="$WORK/results"
H="$WORK/home"; mkdir -p "$H"
score(){ HOME="$H" PATH="$FAKEBIN:$PATH" python3 "$TOOL" "$@" 2>&1; }

# --- 1. no case set: UNMEASURED, never a zero score (L411, L90) ---------------------------------
out="$(score run --cases "$WORK/no-such-dir" --results-dir "$RESULTS")"; rc=$?
check "a missing case set is reported as unmeasured" "UNMEASURED" "$out"
check "the refusal names the path it looked at" "$WORK/no-such-dir" "$out"
check_not "a missing case set never prints a catch rate" "catch rate" "$out"
check_not "a missing case set never prints a percentage" "0%" "$out"
check_rc "a missing case set exits 2" 2 "$rc"
out="$(REVIEW_SCORE_CASES="$WORK/also-missing" score run --results-dir "$RESULTS")"; rc=$?
check "the environment variable names the case set when no flag does" "$WORK/also-missing" "$out"
check_rc "a missing case set from the environment exits 2" 2 "$rc"
out="$(score run --results-dir "$RESULTS")"; rc=$?
check "with neither, the default case set lives outside ~/.claude and the repository" "$H/.claude-review-cases" "$out"
check_rc "a missing default case set exits 2" 2 "$rc"
[ "$(calls)" = 0 ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: no reviewer may run without a case set (calls: $(calls))"; }

# --- 2. check: the shape of a case set, before anything is spent on it --------------------------
out="$(score check --cases "$CASES")"; rc=$?
check "check counts the cases" "2 cases" "$out"
check "check counts every item by verdict" "8 items: 5 real, 1 trivial, 2 wrong, 0 unsure" "$out"
check_rc "a well formed case set checks clean" 0 "$rc"
mkdir -p "$WORK/badset/broken"; cp "$SAMPLE/invented-retry/input.diff" "$WORK/badset/broken/"
printf '{"items":[{"id":"d1","verdict":"real","file":"not/in/the/diff.py","line":3},{"id":"d2","verdict":"maybe","file":"report/send.sh","line":4}]}\n' > "$WORK/badset/broken/case.json"
out="$(score check --cases "$WORK/badset")"; rc=$?
check "check names an item whose file the diff never changes" "not/in/the/diff.py" "$out"
check "check names a verdict outside the vocabulary" "maybe" "$out"
check_rc "a malformed case set fails the check" 1 "$rc"

# --- 3. the rates on the invented sample, with a finding cited four lines off -------------------
answer paginate "shop/paginate.py" "$PAGINATE_GOOD"
answer retry "report/send.sh" "$RETRY_GOOD"
out="$(score run --all --cases "$CASES" --results-dir "$RESULTS")"; rc=$?
check "catch rate counts the real defects found" "catch rate: 3 of 5 real defects caught (60%)" "$out"
check "wrong rate counts findings matching a known wrong one" "wrong findings: 2 of 7 findings judged wrong (29%)" "$out"
check "trivial and unjudged findings are counted apart" "trivial 1, unsure 0, unjudged 1" "$out"
check "a missed defect is named by its id" "invented-paginate d3" "$out"
check "the measured cost of the run is reported" '$0.10' "$out"
check "the measured tokens of the run are reported" "3,000 input tokens" "$out"
check "a first run says there is no baseline to compare with" "no baseline" "$out"
check_rc "a first run with nothing to compare exits 3" 3 "$rc"
check_not "a finding's own text is never printed to the terminal (it can quote private code)" "docstring is vague" "$out"
[ "$(calls)" = 2 ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: --all reviews each case once (calls: $(calls))"; }
args="$(tr '\036' '\n' < "$FAKE_DIR/args")"
check "the reviewer is given the repository's prompt" "OUTPUT FORMAT, follow it exactly." "$args"
check "the reviewer is given the pull request scope" "SCOPE OF THIS REVIEW" "$args"
check "the reviewer is given the lessons index" "===== LESSONS" "$args"
check "the model defaults to the one the lessons review uses" $'--model\nsonnet' "$args"
runs=("$RESULTS"/run-*.json); run1="${runs[0]}"
[ -f "$run1" ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: a run writes its results file"; }
check "the results file keeps the unjudged finding for a person to judge" "docstring is vague" "$(cat "$run1" 2>/dev/null)"
[ ! -e "$H/.claude/state" ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: a scoring run must not write the live review state"; }

# --- 4. matching: a line window, and quoted text beyond it --------------------------------------
cp -R "$SAMPLE" "$WORK/match"; rm -rf "$WORK/match/invented-retry"
rm -f "$FAKE_DIR/answers/"*
answer far "shop/paginate.py" 'shop/paginate.py:60: range stops at len(items) - 1, so a list of one item gives no pages (off by one). Should be: len(items). [severity: major]'
out="$(score run --all --cases "$WORK/match" --results-dir "$WORK/match-results")"
check "a finding far outside the line window does not match" "catch rate: 0 of 3 real defects caught (0%)" "$out"
check "the unmatched finding is counted as unjudged" "unjudged 1" "$out"
answer far "shop/paginate.py" 'shop/paginate.py:60: `for start in range(0, len(items) - 1, size):` drops the last item (off by one). Should be: len(items). [severity: major]'
out="$(score run --all --cases "$WORK/match" --results-dir "$WORK/match-results")"
check "a finding quoting the defect's line matches wherever it points" "catch rate: 1 of 3 real defects caught (33%)" "$out"
answer far "shop/paginate.py" 'shop/paginate.py:16: the docstring above is long. Should be: shorter. [severity: minor]'
out="$(score run --all --cases "$WORK/match" --results-dir "$WORK/match-results")"
check "a finding on the right line making another claim does not match" "catch rate: 0 of 3 real defects caught (0%)" "$out"
# One shared keyword is not a claim (claude-config#1367): the smoke run of #1355 credited an off
# topic finding with a catch because it shared a single keyword with the defect. d2 lists several
# keywords, so a finding on its line that names only "range" and is about something else must not
# catch it, while the same finding naming a second of them, or quoting the line, still does.
answer far "shop/paginate.py" 'shop/paginate.py:16: the range of page sizes callers may pass is not documented. Should be: a docstring. [severity: minor]'
out="$(score run --all --cases "$WORK/match" --results-dir "$WORK/match-results")"
check "one shared keyword alone does not catch a defect that lists several" "catch rate: 0 of 3 real defects caught (0%)" "$out"
check "and that finding is left unjudged for a person to judge" "unjudged 1" "$out"
answer far "shop/paginate.py" 'shop/paginate.py:16: the range is off by one. Should be: len(items). [severity: major]'
out="$(score run --all --cases "$WORK/match" --results-dir "$WORK/match-results")"
check "two of the defect's keywords still catch it" "catch rate: 1 of 3 real defects caught (33%)" "$out"
answer far "shop/paginate.py" 'shop/paginate.py:16: the range in `for start in range(0, len(items) - 1, size):` is wrong. Should be: len(items). [severity: major]'
out="$(score run --all --cases "$WORK/match" --results-dir "$WORK/match-results")"
check "one keyword plus the defect's quoted line still catches it" "catch rate: 1 of 3 real defects caught (33%)" "$out"
answer far "shop/paginate.py" 'shop/paginate.py:16: the range stops one short, so a list of one item gives nothing back. Should be: len(items). [severity: major]'
out="$(score run --all --cases "$WORK/match" --results-dir "$WORK/match-results")"
check "one keyword plus a restatement of the defect's claim still catches it" "catch rate: 1 of 3 real defects caught (33%)" "$out"
rm -f "$FAKE_DIR/answers/far.txt"
answer far2 "shop/paginate.py" 'shop/paginate.py:16: range stops at len(items) - 1 (off by one). Should be: len(items). [severity: major]
shop/paginate.py:17: range again drops the last item (off by one). Should be: len(items). [severity: major]'
out="$(score run --all --cases "$WORK/match" --results-dir "$WORK/match-results")"
check "two findings on one defect catch it once" "catch rate: 1 of 3 real defects caught (33%)" "$out"
check "and both count as findings, neither as unjudged" "unjudged 0" "$out"

# --- 5. regression against a baseline -------------------------------------------------------------
rm -f "$FAKE_DIR/answers/"*
answer paginate "shop/paginate.py" "$PAGINATE_GOOD"
answer retry "report/send.sh" "$RETRY_GOOD"
out="$(score baseline "$run1" --results-dir "$RESULTS")"; rc=$?
check "a run can be saved as the baseline" "baseline" "$out"
check_rc "saving a baseline succeeds" 0 "$rc"
before="$(calls)"
out="$(score run --all --cases "$CASES" --results-dir "$RESULTS")"; rc=$?
check "an equal run is not worse" "NOT WORSE" "$out"
check_rc "a run no worse than the baseline exits 0" 0 "$rc"
# The caught defect's finding is swapped for one about something else, so the findings and the
# wrong ones stay 7 and 2: only the catch rate moves.
answer retry "report/send.sh" 'report/send.sh:1: the script has no usage comment. Should be: add one. [severity: minor]
report/send.sh:11: the loop runs 4 times, one more than the 3 tries it reports (off by one). Should be: -lt 3. [severity: minor]'
out="$(score run --all --cases "$CASES" --results-dir "$RESULTS")"; rc=$?
check "a catch only regression leaves the wrong rate where it was" "wrong findings: 2 of 7" "$out"
check "a run that catches less is a regression" "REGRESSION" "$out"
check "the regression names the rate that fell" "catch rate fell from 60% to 40%" "$out"
check_rc "a regression exits 1" 1 "$rc"
base_before="$(cat "$RESULTS/baseline.json")"
out="$(score run --all --save-baseline --cases "$CASES" --results-dir "$RESULTS")"; rc=$?
check "a regressed run is refused as the baseline" "not saved as the baseline" "$out"
[ "$(cat "$RESULTS/baseline.json")" = "$base_before" ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: --save-baseline must not overwrite the baseline with a run that is worse"; }
check_rc "a refused save still exits as the regression it is" 1 "$rc"
answer retry "report/send.sh" "$RETRY_GOOD"
answer paginate "shop/paginate.py" "$PAGINATE_GOOD
shop/paginate.py:14: size of zero is not checked here either. Should be: check it. [severity: minor]"
out="$(score run --all --cases "$CASES" --results-dir "$RESULTS")"; rc=$?
check "a run with more wrong findings is a regression even when it catches as much" "wrong finding rate rose from 29% to 38%" "$out"
check_rc "a wrong rate regression exits 1" 1 "$rc"
answer paginate "shop/paginate.py" "$PAGINATE_GOOD"

# --- 6. a subset is compared only with the same cases in the baseline -----------------------------
before="$(calls)"
out="$(score run --only invented-retry --cases "$CASES" --results-dir "$RESULTS")"; rc=$?
[ "$(calls)" = $((before + 1)) ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: --only reviews just the named case"; }
check "a subset is compared with the baseline's same cases" "catch rate: 1 of 2 real defects caught (50%)" "$out"
check "the subset comparison says which cases it covered" "same 1 case" "$out"
check_rc "a subset no worse than the baseline on those cases exits 0" 0 "$rc"
base_before="$(cat "$RESULTS/baseline.json")"
out="$(score run --only invented-retry --save-baseline --cases "$CASES" --results-dir "$RESULTS")"
check "a subset run is refused as the baseline of the whole set" "covers only some of the baseline's cases" "$out"
[ "$(cat "$RESULTS/baseline.json")" = "$base_before" ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: a subset run must not replace a baseline holding more cases"; }
mkdir -p "$WORK/other-set"; cp -R "$CASES/invented-retry" "$WORK/other-set/invented-other"
out="$(score run --all --save-baseline --cases "$WORK/other-set" --results-dir "$RESULTS")"; rc=$?
check "a run sharing no case with the baseline says nothing was compared" "nothing is compared" "$out"
[ "$(cat "$RESULTS/baseline.json")" = "$base_before" ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: a run sharing no case with the baseline must not replace it"; }
check_rc "a run sharing no case with the baseline exits 3" 3 "$rc"
cp -R "$CASES/invented-paginate" "$CASES/invented-paginate-2"
cp -R "$CASES/invented-retry" "$CASES/invented-retry-2"
before="$(calls)"
out="$(score run --cases "$CASES" --results-dir "$RESULTS")"
[ "$(calls)" = $((before + 3)) ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: a run with no selection reviews a small sample, not the whole set (calls $(($(calls) - before)))"; }
check "the default run says it is a sample" "sample of 3 of 4 cases" "$out"
before="$(calls)"
out="$(score run --sample 1 --cases "$CASES" --results-dir "$RESULTS")"
[ "$(calls)" = $((before + 1)) ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: --sample 1 reviews one case"; }
rm -rf "$CASES/invented-paginate-2" "$CASES/invented-retry-2"

# --- 7. a case whose review fails is unmeasured, never a zero ---------------------------------------
out="$(FAKE_FAIL_TOKEN="report/send.sh" score run --all --cases "$CASES" --results-dir "$WORK/fail-results")"; rc=$?
check "a failed review is named as unmeasured" "unmeasured: invented-retry" "$out"
check "a failed review's progress line says why it failed" "invented-retry: error, 0 findings" "$out"
check "with the runner's own reason" "claude exited 1" "$out"
check "the rates come from the cases that were measured" "catch rate: 2 of 3 real defects caught (67%)" "$out"
failed_runs=("$WORK/fail-results"/run-*.json)
out="$(score rescore "${failed_runs[0]}" --cases "$CASES" --results-dir "$WORK/fail-results")"
check "a rescore names the cases whose stored reviews failed" "unmeasured: invented-retry (error)" "$out"
out="$(FAKE_FAIL_TOKEN="diff --git" score run --all --cases "$CASES" --results-dir "$WORK/fail-results")"; rc=$?
check "when every review fails the run is unmeasured" "UNMEASURED" "$out"
check_not "an all failed run never prints a catch rate" "catch rate:" "$out"
check_rc "an all failed run exits 2" 2 "$rc"
# A review whose own setup fails (the disk full, the case's diff gone) is a failed review with a
# reason, never an exception that would end the run before its results are written.
out="$(PATH="$FAKEBIN:$PATH" python3 - "$TOOL" "$CASES" <<'PY' 2>&1
import importlib.util, shutil, sys
spec = importlib.util.spec_from_file_location("review_score", sys.argv[1])
rs = importlib.util.module_from_spec(spec); spec.loader.exec_module(rs)
case, problems = rs.load_case(sys.argv[2], "invented-retry")
def refuse(*a, **k):
    raise OSError(28, "No space left on device")
shutil.copyfile = refuse
rv = rs.review_once(case, {"hooks_lib": rs.DEFAULT_HOOKS_LIB, "lessons_dir": rs.DEFAULT_LESSONS_DIR,
                           "model": "sonnet", "deadline": 30, "finding_re": None}, shutil.which("claude"))
print("status=%s note=%s" % (rv["status"], rv.get("note", "")))
PY
)"
check "a review that cannot be set up is a failed review, not a crash" "status=error" "$out"
check "the failed setup says why" "No space left on device" "$out"
check_not "a review that cannot be set up raises nothing" "Traceback" "$out"

# --- 8. rescoring a stored run costs no review --------------------------------------------------
before="$(calls)"
python3 - "$CASES/invented-paginate/case.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["items"].append({"id": "t2", "verdict": "trivial", "file": "shop/paginate.py", "line": 1,
                   "quote": "", "keywords": ["docstring"], "claim": "The module docstring is vague."})
json.dump(d, open(p, "w"), indent=2)
PY
out="$(score rescore "$run1" --cases "$CASES" --results-dir "$RESULTS")"
check "a rescore applies the case set's current judgements" "trivial 2, unsure 0, unjudged 0" "$out"
[ "$(calls)" = "$before" ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: a rescore must not call the reviewer"; }
cp -R "$CASES" "$WORK/shrunk"; rm -rf "$WORK/shrunk/invented-retry"
out="$(score rescore "$run1" --cases "$WORK/shrunk" --results-dir "$WORK/shrunk-results")"
check "a case the run holds but the set no longer does is named as unmeasured" "unmeasured: invented-retry (no longer in the case set)" "$out"

# --- 9. repeats pool their reviews ---------------------------------------------------------------
out="$(score run --all --repeat 2 --cases "$CASES" --results-dir "$WORK/repeat-results")"
check "two reviews per case double the denominators" "catch rate: 6 of 10 real defects caught (60%)" "$out"
touch "$WORK/fail-once"
out="$(FAKE_FAIL_ONCE="$WORK/fail-once" score run --only invented-retry --repeat 2 --cases "$CASES" --results-dir "$WORK/repeat-results")"
check "a case with one of its repeats failed says so" "unmeasured: invented-retry (1 of 2 reviews failed: error)" "$out"
check "and is scored on the review that succeeded" "catch rate: 1 of 2 real defects caught (50%)" "$out"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
