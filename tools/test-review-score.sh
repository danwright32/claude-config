#!/usr/bin/env bash
# Tests for tools/review-score.py, the scorer for the pre merge lessons review (claude-config#1355).
#
# The scorer runs the REAL runner (payload/hooks/lib/ai-review-run.py) over each case, so a fake
# claude on PATH stands in for the model: no test here ever calls a real model. The fake answers
# from files this suite writes, chosen by which invented file the review input names, in the
# stream the runner asks for (lib/fake-claude-stream.py wraps its text), whose result event carries
# the cost the scorer reads back from each review's metadata.
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
for a in "$@"; do
  if [ "$a" = stream-json ] && [ -z "${FAKE_STREAM_INNER:-}" ]; then
    FAKE_STREAM_INNER=1 "$0" "$@" | python3 "$FAKE_STREAM"; exit "${PIPESTATUS[0]}"
  fi
done
printf 'called\n' >> "$FAKE_DIR/calls"
printf '%s\x1e' "$@" > "$FAKE_DIR/args"
env > "$FAKE_DIR/env.$$"
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
printf '%s\n' "$text"
EOS
chmod +x "$FAKEBIN/claude"
# The runner asks for the stream and reads each review's cost from its result event (#1619): the
# one converter wraps the text above in those events, with this cost and these token counts.
export FAKE_STREAM="$DIR/../payload/hooks/lib/fake-claude-stream.py"
export FAKE_STREAM_RESULT='{"total_cost_usd": 0.05, "usage": {"input_tokens": 1000, "cache_creation_input_tokens": 200, "cache_read_input_tokens": 300, "output_tokens": 50}}'

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
check "catch rate counts the real defects found, with its 95% range (#3556)" "catch rate: 3 of 5 real defects caught (60%, 95% range 23% to 88%)" "$out"
check "#3556 the wrong rate is over the findings checked against a judged item" "wrong findings: 2 of 6 checked findings judged wrong (33%, 95% range 10% to 70%)" "$out"
check "#3556 the unchecked findings are counted on a line of their own" "unchecked: 1 of 7 findings matched no judged item" "$out"
check "#3556 the old figure over every finding stays, labelled as a floor" "if every unchecked finding were right, the wrong rate over all 7 would be 29% (2 of 7)" "$out"
check "trivial and unsure findings are counted apart" "also: trivial 1, unsure 0" "$out"
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
# #1619: the reviews of one run, started together, share one folder of turns (never the live one),
# so exactly one goes first and the others read the lessons back after it.
warm_dirs="$(cat "$FAKE_DIR"/env.* 2>/dev/null | grep '^AI_REVIEW_WARM_DIR=' | sort -u)"
[ "$(grep -c . <<< "$warm_dirs")" = 1 ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: every review of a run takes its turn in the same folder ($warm_dirs)"; }
check_not "and that folder is not the live review state" "$H/.claude" "$warm_dirs"
firsts="$(grep -o '"start_order": "first"' "$run1" 2>/dev/null | grep -c . || true)"
[ "$firsts" = 1 ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: of the reviews started together, exactly one went first ($firsts)"; }

# --- 4. matching: a line window, and quoted text beyond it --------------------------------------
cp -R "$SAMPLE" "$WORK/match"; rm -rf "$WORK/match/invented-retry"
rm -f "$FAKE_DIR/answers/"*
answer far "shop/paginate.py" 'shop/paginate.py:60: range stops at len(items) - 1, so a list of one item gives no pages (off by one). Should be: len(items). [severity: major]'
out="$(score run --all --cases "$WORK/match" --results-dir "$WORK/match-results")"
check "a finding far outside the line window does not match" "catch rate: 0 of 3 real defects caught (0%," "$out"
check "the unmatched finding is counted as unchecked" "unchecked: 1 of 1 finding matched no judged item" "$out"
answer far "shop/paginate.py" 'shop/paginate.py:60: `for start in range(0, len(items) - 1, size):` drops the last item (off by one). Should be: len(items). [severity: major]'
out="$(score run --all --cases "$WORK/match" --results-dir "$WORK/match-results")"
check "a finding quoting the defect's line matches wherever it points" "catch rate: 1 of 3 real defects caught (33%," "$out"
answer far "shop/paginate.py" 'shop/paginate.py:16: the docstring above is long. Should be: shorter. [severity: minor]'
out="$(score run --all --cases "$WORK/match" --results-dir "$WORK/match-results")"
check "a finding on the right line making another claim does not match" "catch rate: 0 of 3 real defects caught (0%," "$out"
# One shared keyword is not a claim (claude-config#1367): the smoke run of #1355 credited an off
# topic finding with a catch because it shared a single keyword with the defect. d2 lists several
# keywords, so a finding on its line that names only "range" and is about something else must not
# catch it, while the same finding naming a second of them, or quoting the line, still does.
answer far "shop/paginate.py" 'shop/paginate.py:16: the range of page sizes callers may pass is not documented. Should be: a docstring. [severity: minor]'
out="$(score run --all --cases "$WORK/match" --results-dir "$WORK/match-results")"
check "one shared keyword alone does not catch a defect that lists several" "catch rate: 0 of 3 real defects caught (0%," "$out"
check "and that finding is left unchecked for a person to judge" "unchecked: 1 of 1 finding matched no judged item" "$out"
answer far "shop/paginate.py" 'shop/paginate.py:16: the range is off by one. Should be: len(items). [severity: major]'
out="$(score run --all --cases "$WORK/match" --results-dir "$WORK/match-results")"
check "two of the defect's keywords still catch it" "catch rate: 1 of 3 real defects caught (33%," "$out"
answer far "shop/paginate.py" 'shop/paginate.py:16: the range in `for start in range(0, len(items) - 1, size):` is wrong. Should be: len(items). [severity: major]'
out="$(score run --all --cases "$WORK/match" --results-dir "$WORK/match-results")"
check "one keyword plus the defect's quoted line still catches it" "catch rate: 1 of 3 real defects caught (33%," "$out"
answer far "shop/paginate.py" 'shop/paginate.py:16: the range stops one short, so a list of one item gives nothing back. Should be: len(items). [severity: major]'
out="$(score run --all --cases "$WORK/match" --results-dir "$WORK/match-results")"
check "one keyword plus a restatement of the defect's claim still catches it" "catch rate: 1 of 3 real defects caught (33%," "$out"
# A restated claim is judged by review-answered.py's own measure and threshold, never a copy that
# can drift from it (lessons review of #1376): over pairs either side of the threshold, the scorer's
# decision must be exactly the one that measure gives.
IFS= read -r -d '' agree_prog <<'PY' || true
import importlib.util, sys
def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod); return mod
rs, ra = load("rs", sys.argv[1]), load("ra", sys.argv[2])
item = {"keywords": ["range", "drop"], "claim": "the range stops one short, so a list of one item gives no pages."}
texts = ["the range stops one short, so a list of one item gives nothing back. Should be: len(items).",
         "the range stops early on short lists. [severity: major]",
         "the range of page sizes callers may pass is not documented.",
         "the range stops one short [review harness: not placed, no quote, so line 16 is the reviewer's own number, unchecked]"]
bad = [t for t in texts
       if rs.claim_matches(t.lower(), item, False, t) != (ra.similarity(t, item["claim"]) >= ra.MIN_SIMILARITY)]
print("agree" if not bad else "differ: " + " | ".join(bad))
PY
agree="$(python3 -I -B -c "$agree_prog" "$TOOL" "$DIR/../payload/hooks/lib/review-answered.py" </dev/null)"
check "a restated claim is judged by review-answered.py's own measure" "agree" "$agree"
rm -f "$FAKE_DIR/answers/far.txt"
answer far2 "shop/paginate.py" 'shop/paginate.py:16: range stops at len(items) - 1 (off by one). Should be: len(items). [severity: major]
shop/paginate.py:17: range again drops the last item (off by one). Should be: len(items). [severity: major]'
out="$(score run --all --cases "$WORK/match" --results-dir "$WORK/match-results")"
check "two findings on one defect catch it once" "catch rate: 1 of 3 real defects caught (33%," "$out"
check "and both count as findings, neither as unchecked" "unchecked: 0 of 2 findings matched no judged item" "$out"

# --- 5. regression against a baseline -------------------------------------------------------------
rm -f "$FAKE_DIR/answers/"*
answer paginate "shop/paginate.py" "$PAGINATE_GOOD"
answer retry "report/send.sh" "$RETRY_GOOD"
out="$(score baseline "$run1" --results-dir "$RESULTS")"; rc=$?
check "a run can be saved as the baseline" "baseline" "$out"
check_rc "saving a baseline succeeds" 0 "$rc"
before="$(calls)"
out="$(score run --all --cases "$CASES" --results-dir "$RESULTS")"; rc=$?
check "#3556 an equal run says there is no difference" "NO DIFFERENCE" "$out"
check_not "#3556 and never calls the runs not worse" "NOT WORSE" "$out"
check_rc "a run no different from the baseline exits 0" 0 "$rc"
# The caught defect's finding is swapped for one about something else, so only one defect flips.
# One flip is inside the noise (#3556): the old tool called it a REGRESSION.
answer retry "report/send.sh" 'report/send.sh:1: the script has no usage comment. Should be: add one. [severity: minor]
report/send.sh:11: the loop runs 4 times, one more than the 3 tries it reports (off by one). Should be: -lt 3. [severity: minor]'
out="$(score run --all --cases "$CASES" --results-dir "$RESULTS")"; rc=$?
check "#3556 a catch only change leaves the known wrong findings where they were" "known wrong findings: 0 raised more often, 0 less often, 2 the same" "$out"
check "#3556 the defect that flipped is named" "newly missed: invented-retry d1" "$out"
check "#3556 one missed defect is too few to tell from noise" "CANNOT TELL" "$out"
check_not "#3556 and is never called a regression" "REGRESSION" "$out"
check_rc "#3556 a difference inside the noise exits 4" 4 "$rc"
base_before="$(cat "$RESULTS/baseline.json")"
out="$(score run --all --save-baseline --cases "$CASES" --results-dir "$RESULTS")"; rc=$?
check "#3556 a run that cannot be told apart is refused as the baseline" "not saved as the baseline" "$out"
[ "$(cat "$RESULTS/baseline.json")" = "$base_before" ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: --save-baseline must not overwrite the baseline with a run it cannot tell apart from it"; }
check_rc "a refused save still exits as the comparison it is" 4 "$rc"
answer retry "report/send.sh" "$RETRY_GOOD"
answer paginate "shop/paginate.py" "$PAGINATE_GOOD
shop/paginate.py:14: size of zero is not checked here either. Should be: check it. [severity: minor]"
out="$(score run --all --cases "$CASES" --results-dir "$RESULTS")"; rc=$?
check "#3556 a known wrong finding raised one more time is named" "raised more often: invented-paginate w1" "$out"
check "#3556 and one more is inside the noise" "CANNOT TELL" "$out"
check_rc "#3556 so it exits 4" 4 "$rc"
answer paginate "shop/paginate.py" "$PAGINATE_GOOD"

# --- 6. a subset is compared only with the same cases in the baseline -----------------------------
before="$(calls)"
out="$(score run --only invented-retry --cases "$CASES" --results-dir "$RESULTS")"; rc=$?
[ "$(calls)" = $((before + 1)) ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: --only reviews just the named case"; }
check "a subset is compared with the baseline's same cases" "catch rate: 1 of 2 real defects caught (50%," "$out"
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
check "the rates come from the cases that were measured" "catch rate: 2 of 3 real defects caught (67%," "$out"
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
                           "model": "sonnet", "deadline": 30, "finding_re": None, "warm_dir": sys.argv[2]})
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
check "a rescore applies the case set's current judgements" "also: trivial 2, unsure 0" "$out"
check "and the finding it now judges is no longer unchecked" "unchecked: 0 of 7 findings" "$out"
[ "$(calls)" = "$before" ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: a rescore must not call the reviewer"; }
cp -R "$CASES" "$WORK/shrunk"; rm -rf "$WORK/shrunk/invented-retry"
out="$(score rescore "$run1" --cases "$WORK/shrunk" --results-dir "$WORK/shrunk-results")"
check "a case the run holds but the set no longer does is named as unmeasured" "unmeasured: invented-retry (no longer in the case set)" "$out"

# --- 9. repeats pool their reviews ---------------------------------------------------------------
out="$(score run --all --repeat 2 --cases "$CASES" --results-dir "$WORK/repeat-results")"
check "two reviews per case double the denominators" "catch rate: 6 of 10 real defects caught (60%," "$out"
# #3556: two reviews of one case are not two independent samples, so the range is as wide as one
# review per case would give (6 of 10 over 5 defects: 3 of 5, 23% to 88%), never 31% to 83%.
check "#3556 the range of a repeated run counts each case's reviews once" "(60%, 95% range 23% to 88%" "$out"
check "#3556 and says so" "counts each case's reviews as one" "$out"
touch "$WORK/fail-once"
out="$(FAKE_FAIL_ONCE="$WORK/fail-once" score run --only invented-retry --repeat 2 --cases "$CASES" --results-dir "$WORK/repeat-results")"
check "a case with one of its repeats failed says so" "unmeasured: invented-retry (1 of 2 reviews failed: error)" "$out"
check "and is scored on the review that succeeded" "catch rate: 1 of 2 real defects caught (50%," "$out"

# --- 10. a review that read only what changed since the last reviewed head (claude-config#1358) ---
# After three rounds of findings a review's input lists every file of the branch, marks the ones it
# does not show as read by the earlier reviews, and says it is narrowed. A case taken from such an
# input is scored like any other, and the check names an item on a file it does not show, since no
# review of that input could find it there.
mkdir -p "$WORK/narrow/invented-narrowed"
{ printf '===== FILES THIS PUSH CHANGED: the complete list, 2 file(s), from 4444444..5555555 =====\n'
  printf 'A\treport/send.sh\t(changed, shown below)\n'
  printf 'A\treport/old.sh\t(changed by this branch before 3333333 and not since, so read by the earlier reviews: not shown below)\n'
  printf '===== END OF FILE LIST =====\n\n'
  printf '===== THIS REVIEW READS ONLY WHAT CHANGED SINCE 3333333: earlier reviews of this pull request read the whole branch up to 3333333 and returned findings in 3 rounds, so this review is given only the changes made since then, below. =====\n\n'
  awk 'past { print } /END OF FILE LIST/ { past = 1 }' "$SAMPLE/invented-retry/input.diff"
} > "$WORK/narrow/invented-narrowed/input.diff"
python3 -c 'import json, sys
c = json.load(open(sys.argv[1]))
c["items"] = [i for i in c["items"] if i["id"] == "d1"]
json.dump(c, open(sys.argv[2], "w"))' "$SAMPLE/invented-retry/case.json" "$WORK/narrow/invented-narrowed/case.json"
out="$(score check --cases "$WORK/narrow")"; rc=$?
check_rc "#1358 a case in the narrowed shape checks clean" 0 "$rc"
rm -f "$FAKE_DIR/answers/"*
answer narrowed "THIS REVIEW READS ONLY WHAT CHANGED SINCE" "$RETRY_GOOD"
out="$(score run --all --cases "$WORK/narrow" --results-dir "$WORK/narrow-results")"
check "#1358 and is scored like any other" "catch rate: 1 of 1 real defects caught (100%," "$out"
python3 -c 'import json, sys
c = json.load(open(sys.argv[1]))
c["items"].append({"id": "d9", "verdict": "real", "file": "report/old.sh", "line": 2})
json.dump(c, open(sys.argv[1], "w"))' "$WORK/narrow/invented-narrowed/case.json"
out="$(score check --cases "$WORK/narrow")"; rc=$?
check "#1358 an item on a file the narrowed input does not show is named" "report/old.sh" "$out"
check_rc "#1358 and fails the check" 1 "$rc"

# --- 11. every rate carries its count and its 95% range (claude-config#3556) ----------------------
# These runs are result files written by hand, from invented findings on the invented sample, and
# scored with rescore, which never calls a reviewer. A spec names, per case, each review's findings.
IFS= read -r -d '' mkrun_prog <<'PY' || true
import json, sys
F = {
    "p.d1": "shop/paginate.py:8: `return len(items) // size` floors the count, so a partial last page is lost. [severity: major]",
    "p.d2": "shop/paginate.py:16: range stops at len(items) - 1 (off by one). [severity: major]",
    "p.d3": "shop/paginate.py:23: start should use number - 1, so the first page skips its items (one based). [severity: major]",
    "p.w1": "shop/paginate.py:13: a size of zero is not checked. [severity: minor]",
    "p.x": "shop/paginate.py:2: the docstring could say more. [severity: minor]",
    "r.d1": "report/send.sh:6: the || true swallows the upload failure. [severity: critical]",
    "r.d2": "report/send.sh:17: sleep 5 is a fixed delay the tests wait on; inject it. [severity: minor]",
    "r.w1": "report/send.sh:11: the loop runs 4 times (off by one). [severity: minor]",
}
out, cases_dir, spec = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
run = {"version": 1, "name": out.rsplit("/", 1)[-1], "model": "sonnet", "selection": "invented",
       "repeat": max(len(r) for r in spec.values()), "cases_dir": cases_dir,
       "cases": {cid: {"reviews": [{"status": "ok", "findings": [F[k] for k in rv]} for rv in reviews]}
                 for cid, reviews in spec.items()}}
json.dump(run, open(out, "w"), indent=2)
PY
mkrun(){ python3 -I -B -c "$mkrun_prog" "$1" "$2" "$3" </dev/null; }
C11="$WORK/c11"; cp -R "$SAMPLE" "$C11"
R11="$WORK/r11"; mkdir -p "$R11" "$WORK/r11-none"
mkrun "$R11/a.json" "$C11" '{"invented-paginate": [["p.d1", "p.d2", "p.w1", "p.x"]], "invented-retry": [["r.d1", "r.w1"]]}'
out="$(score rescore "$R11/a.json" --cases "$C11" --results-dir "$WORK/r11-none")"
check "#3556 the catch rate carries its count and range" "catch rate: 3 of 5 real defects caught (60%, 95% range 23% to 88%)" "$out"
check "#3556 the wrong rate is over checked findings, with its range" "wrong findings: 2 of 5 checked findings judged wrong (40%, 95% range 12% to 77%)" "$out"
check "#3556 the unchecked count is on its own line" "unchecked: 1 of 6 findings matched no judged item" "$out"
check "#3556 the figure over every finding is kept and labelled" "the wrong rate over all 6 would be 33% (2 of 6)" "$out"
# The issue's own figures, from the saved baseline of 2026-11-19 (not on this Mac): 11 of 24 caught
# and 2 wrong of 20 checked. The range printed for them must be the one the issue measured.
IFS= read -r -d '' unit_prog <<'PY' || true
import importlib.util, sys
spec = importlib.util.spec_from_file_location("rs", sys.argv[1])
rs = importlib.util.module_from_spec(spec); spec.loader.exec_module(rs)
print("catch:", rs.rate_text(11, 24))
print("wrong:", rs.rate_text(2, 20))
print("zero:", rs.rate_text(0, 0))
print("p8:", round(rs.sign_test(0, 8), 4), "p1:", rs.sign_test(1, 0), "p44:", rs.sign_test(4, 4), "p00:", rs.sign_test(0, 0))
print("fewest:", rs.FEWEST_FLIPS)
PY
unit="$(python3 -I -B -c "$unit_prog" "$TOOL" </dev/null 2>&1)"
check "#3556 the issue's catch figure gives its measured range" "catch: 46%, 95% range 28% to 65%" "$unit"
check "#3556 the issue's wrong figure gives its measured range" "wrong: 10%, 95% range 3% to 30%" "$unit"
check "#3556 zero of zero has no rate, rather than 0% or a crash" "zero: None" "$unit"
check "#3556 eight flips all one way: the exact two sided sign test gives 2 in 256" "p8: 0.0078" "$unit"
check "#3556 one flip, or an even split, is no evidence at all" "p1: 1.0 p44: 1.0 p00: None" "$unit"
check "#3556 six flips all one way is the fewest that can clear the 95% level" "fewest: 6" "$unit"
# Zero checked findings: no rate, said in words.
mkrun "$R11/z.json" "$C11" '{"invented-paginate": [["p.x"]]}'
out="$(score rescore "$R11/z.json" --cases "$C11" --results-dir "$WORK/r11-none")"; rc=$?
check "#3556 no checked finding gives no wrong rate, in words" "wrong findings: no rate, none of the 1 finding matched a judged item" "$out"
check_not "#3556 and never a percentage over nothing" "0 of 0" "$out"
check_not "#3556 nor a crash" "Traceback" "$out"
check_rc "#3556 a rescore with no baseline still exits 3" 3 "$rc"
mkrun "$R11/all.json" "$C11" '{"invented-paginate": [["p.d1", "p.d2", "p.d3"]], "invented-retry": [["r.d1", "r.d2"]]}'
out="$(score rescore "$R11/all.json" --cases "$C11" --results-dir "$WORK/r11-none")"
check "#3556 every defect caught still carries a range below 100%" "catch rate: 5 of 5 real defects caught (100%, 95% range 57% to 100%)" "$out"
mkrun "$R11/one.json" "$C11" '{"invented-retry": [["r.d1"]]}'
out="$(score rescore "$R11/one.json" --cases "$C11" --results-dir "$WORK/r11-none")"
check "#3556 one case gives the wide range it should" "catch rate: 1 of 2 real defects caught (50%, 95% range 9% to 91%)" "$out"
# Repeats that disagree: the spread per case is printed, and a defect caught by only some reviews is
# named apart from one never caught.
mkrun "$R11/rep.json" "$C11" '{"invented-paginate": [["p.d1", "p.d2"], ["p.d1"]], "invented-retry": [["r.d1"], ["r.d1"]]}'
out="$(score rescore "$R11/rep.json" --cases "$C11" --results-dir "$WORK/r11-none")"
check "#3556 repeats pool, and the range counts each case once" "catch rate: 5 of 10 real defects caught (50%, 95% range 17% to 83%" "$out"
check "#3556 the repeats line says how often the reviews of a case disagreed" "repeats: 2 reviews per case; the reviews of 1 of 2 cases caught different defects" "$out"
check "#3556 the spread per case is printed" "caught in each review: invented-paginate 2, 1 of 3; invented-retry 1, 1 of 2" "$out"
check "#3556 a defect caught by only some reviews is named" "caught by only some reviews: invented-paginate d2 (1 of 2)" "$out"
check "#3556 missed means never caught in any review" "missed: invented-paginate d3, invented-retry d2" "$out"
out="$(score rescore "$R11/a.json" --cases "$C11" --results-dir "$WORK/r11-none")"
check_not "#3556 a run of one review per case prints no repeats line" "repeats:" "$out"

# --- 12. two runs compared case by case (claude-config#3556) --------------------------------------
R12="$WORK/r12"; mkdir -p "$R12"
cp "$R11/a.json" "$R12/baseline.json"
out="$(score rescore "$R12/baseline.json" --cases "$C11" --results-dir "$R12")"; rc=$?
check "#3556 the baseline compared with itself says no difference" "NO DIFFERENCE" "$out"
check "#3556 with no defect flipped either way" "catch: 0 newly caught, 0 newly missed, 5 the same" "$out"
check "#3556 both sides carry their ranges" "baseline: catch 3 of 5 (60%, 95% range 23% to 88%); wrong 2 of 5 checked findings (40%, 95% range 12% to 77%), 1 unchecked" "$out"
check "#3556 the test used is named" "exact two sided sign test" "$out"
check_rc "#3556 no difference exits 0" 0 "$rc"
mkrun "$R12/b.json" "$C11" '{"invented-paginate": [["p.d1", "p.w1", "p.x"]], "invented-retry": [["r.d1", "r.w1"]]}'
out="$(score rescore "$R12/b.json" --cases "$C11" --results-dir "$R12")"; rc=$?
check "#3556 the defect newly missed is named" "newly missed: invented-paginate d2" "$out"
check "#3556 one flip cannot be told from noise" "CANNOT TELL" "$out"
check "#3556 and it says why" "too few" "$out"
check_not "#3556 one flip is never a regression" "REGRESSION" "$out"
check_not "#3556 nor not worse" "NOT WORSE" "$out"
check_rc "#3556 cannot tell exits 4" 4 "$rc"
mkrun "$R12/c.json" "$C11" '{"invented-paginate": [["p.d1", "p.d2", "p.w1", "p.x"]]}'
out="$(score rescore "$R12/c.json" --cases "$C11" --results-dir "$R12")"
check "#3556 a case measured only in the baseline is named, never dropped silently" "measured only in the baseline: invented-retry" "$out"
check "#3556 and nothing is measured only in this run" "measured only in this run: none" "$out"
R12b="$WORK/r12b"; mkdir -p "$R12b"; cp "$R12/c.json" "$R12b/baseline.json"
out="$(score rescore "$R11/a.json" --cases "$C11" --results-dir "$R12b")"
check "#3556 a case measured only in this run is named too" "measured only in this run: invented-retry" "$out"
mkrun "$R12/rep.json" "$C11" '{"invented-paginate": [["p.d1", "p.d2", "p.w1", "p.x"], ["p.d1", "p.w1", "p.x"]], "invented-retry": [["r.d1", "r.w1"], ["r.d1", "r.w1"]]}'
out="$(score rescore "$R12/rep.json" --cases "$C11" --results-dir "$R12")"
check "#3556 a defect caught in fewer of its repeats counts as a flip down, with both sides' counts" "newly missed: invented-paginate d2 (1 in 1 then, 1 in 2 now)" "$out"
# A set big enough for the test to decide: eight invented cases, each a copy of the sample's one.
C12="$WORK/c12"; mkdir -p "$C12"
for n in 1 2 3 4 5 6 7 8; do cp -R "$SAMPLE/invented-paginate" "$C12/p$n"; done
all3='[["p.d1", "p.d2", "p.d3"]]'; two='[["p.d2", "p.d3"]]'; all3w='[["p.d1", "p.d2", "p.d3", "p.w1"]]'
spec(){ printf '{"p1": %s, "p2": %s, "p3": %s, "p4": %s, "p5": %s, "p6": %s, "p7": %s, "p8": %s}' "$@"; }
R12c="$WORK/r12c"; mkdir -p "$R12c"
mkrun "$R12c/baseline.json" "$C12" "$(spec "$all3" "$all3" "$all3" "$all3" "$all3" "$all3" "$all3" "$all3")"
mkrun "$R12c/worse.json" "$C12" "$(spec "$two" "$two" "$two" "$two" "$two" "$two" "$two" "$two")"
out="$(score rescore "$R12c/worse.json" --cases "$C12" --results-dir "$R12c")"; rc=$?
check "#3556 eight newly missed and none newly caught is a regression" "REGRESSION" "$out"
check "#3556 with the counts and the test's p" "catch 0 newly caught, 8 newly missed (p = 0.008)" "$out"
check_rc "#3556 a regression exits 1" 1 "$rc"
R12d="$WORK/r12d"; mkdir -p "$R12d"; cp "$R12c/worse.json" "$R12d/baseline.json"
out="$(score rescore "$R12c/baseline.json" --cases "$C12" --results-dir "$R12d")"; rc=$?
check "#3556 eight newly caught and none newly missed is an improvement" "IMPROVEMENT" "$out"
check_rc "#3556 an improvement exits 0" 0 "$rc"
mkrun "$R12c/mixed.json" "$C12" "$(spec "$two" "$two" "$two" "$two" "$all3" "$all3" "$all3" "$all3")"
R12e="$WORK/r12e"; mkdir -p "$R12e"
mkrun "$R12e/baseline.json" "$C12" "$(spec "$all3" "$all3" "$all3" "$all3" "$two" "$two" "$two" "$two")"
out="$(score rescore "$R12c/mixed.json" --cases "$C12" --results-dir "$R12e")"; rc=$?
check "#3556 four up and four down at the same rate is counted case by case" "catch: 4 newly caught, 4 newly missed" "$out"
check "#3556 and cannot be told apart" "CANNOT TELL" "$out"
check_not "#3556 an unchanged rate over different cases is never not worse" "NOT WORSE" "$out"
check_rc "#3556 so it exits 4" 4 "$rc"
mkrun "$R12c/wrong.json" "$C12" "$(spec "$all3w" "$all3w" "$all3w" "$all3w" "$all3w" "$all3w" "$all3w" "$all3w")"
out="$(score rescore "$R12c/wrong.json" --cases "$C12" --results-dir "$R12c")"; rc=$?
check "#3556 a known wrong finding raised in eight more cases is a regression" "REGRESSION: known wrong findings raised 8 more often, 0 less often (p = 0.008)" "$out"
check_rc "#3556 and exits 1" 1 "$rc"
# The reason given for CANNOT TELL is the unclear side's own: one defect flipped while eight known
# wrong findings went away must say the ONE change is too few, not count the other side's eight.
R12f="$WORK/r12f"; mkdir -p "$R12f"; cp "$R12c/wrong.json" "$R12f/baseline.json"
mkrun "$R12c/mixed2.json" "$C12" "$(spec "$two" "$all3" "$all3" "$all3" "$all3" "$all3" "$all3" "$all3")"
out="$(score rescore "$R12c/mixed2.json" --cases "$C12" --results-dir "$R12f")"; rc=$?
check "#3556 the unclear side gives its own change count" "catch 0 newly caught, 1 newly missed (p = 1.000), 1 change, too few for the 95% level" "$out"
check "#3556 and the side that did clear it is still said" "Also better: known wrong findings raised 0 more often, 8 less often" "$out"
check_rc "#3556 one side unclear is cannot tell overall" 4 "$rc"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
