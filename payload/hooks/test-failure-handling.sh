#!/usr/bin/env bash
# Tests for lib/failure-handling.sh: the one predicate that decides whether added code HANDLES
# FAILURE (a catch, an except, a rescue, an error branch, a status check, a retry or a backoff).
#
# claude-config#1477. On 2026-10-21 a Bidspoke test file was flagged as "new retry or
# failure-handling logic" needing a failure path test. It held no such code: the lessons advisory
# matched the WORD retries in a mocked response's field name (`retries_assumed: 2`), and the file's
# only other candidate was a select option labelled 'Fail the run'. The predicate judges code
# constructs, with string literals and comments removed, and every gate that asks the question
# reads it (L261, L370), so these cases pin the predicate once rather than once per caller.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/lib/failure-handling.sh"
REPO="$(cd "$DIR/../.." && pwd)"

pass=0
fail=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ -f "$LIB" ] && . "$LIB"; then
  pass=$((pass+1))
else
  fail=$((fail+1)); echo "FAIL: lib/failure-handling.sh is missing or does not source cleanly"
  echo "passed: $pass, failed: $fail"
  printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
  exit 1
fi

# Defined exactly once each: bash keeps the last definition without a word (claude-config#440).
for fn in fh_code_only fh_catch fh_retry fh_handles_failure fh_files; do
  n="$(grep -cE "^$fn\(\) \{" "$LIB")"
  if [ "$n" = "1" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $fn defined $n times in the lib, expected 1"; fi
done

# $1 predicate, $2 path, $3 the added lines, $4 what the case is.
fires() {
  printf '%s\n' "$3" > "$WORK/lines"
  if "$1" "$2" "$WORK/lines"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 should fire: $4"; fi
}
silent() {
  printf '%s\n' "$3" > "$WORK/lines"
  if "$1" "$2" "$WORK/lines"; then fail=$((fail+1)); echo "FAIL: $1 should stay silent: $4"; else pass=$((pass+1)); fi
}

# --- the case the issue reported: the test file's own wording ---------------------------------
# The two lines of apps/web/src/components/canvas/__tests__/LeadValidationConfig.carries-fields.test.tsx
# (Bidspoke PR #2630) that the flag was raised over: a mocked response's field, and a select option.
ISSUE_TEST='executions: {
  stepDurationStats: vi.fn().mockResolvedValue({
    p50: null, p95: null, p99: null, max_ms: null, sample_size: 0,
    window_days: 7, source: '"'"'history'"'"', subtype: null, retries_assumed: 2,
  }),
},
chooseOption(within(editor()).getByRole('"'"'combobox'"'"', { name: '"'"'If the lead has no value'"'"' }), '"'"'Fail the run'"'"')
expect(holders(onUpdate)).toEqual(['"'"'Renamed'"'"'])'
ISSUE_PATH='apps/web/src/components/canvas/__tests__/LeadValidationConfig.carries-fields.test.tsx'
silent fh_retry "$ISSUE_PATH" "$ISSUE_TEST" "the issue's test file: a fixture field named retries_assumed is data, not a retry"
silent fh_catch "$ISSUE_PATH" "$ISSUE_TEST" "the issue's test file has no catch"
silent fh_handles_failure "$ISSUE_PATH" "$ISSUE_TEST" "the issue's test file, wording and fixture data only"

# --- words in strings and comments are not code ----------------------------------------------
silent fh_handles_failure src/panel.tsx "const options = ['Fail the run', 'Skip the check', 'Retry later']" "option labels in a string"
silent fh_handles_failure src/panel.tsx "// on failure we retry with backoff, and catch (e) the rest" "a comment naming every construct"
silent fh_handles_failure src/panel.tsx "label = \"Retry, then catch (it) and back off\"; /* except: retry */" "a string and a block comment"
silent fh_handles_failure scripts/run.py "msg = 'except: retry with backoff'  # retry later" "a Python string and comment"
silent fh_handles_failure payload/hooks/x.sh 'echo "retry with exponential backoff later"   # catch (it)' "a shell message and comment"
silent fh_handles_failure README.md "Retry with backoff, catch (e) the error, except: nothing." "prose is not code"
silent fh_retry src/panel.tsx "const failures = rows.filter(r => r.failed).length" "the word fail in an identifier is not a retry"

# --- real constructs still fire, in source ------------------------------------------------------
fires fh_catch src/send.ts "try { await send() } catch (e) { return [] }" "a JS catch"
fires fh_catch src/send.ts "send().catch(err => log(err))" "a promise .catch("
fires fh_catch app/Sync.swift "} catch let error as URLError {" "a Swift catch let"
fires fh_catch app/Sync.swift "} catch {" "a bare Swift catch"
fires fh_catch tools/run.py "    except ValueError as e:" "a Python except"
fires fh_catch tools/run.py "except:" "a bare Python except"
fires fh_catch lib/worker.rb "rescue Timeout::Error => e" "a Ruby rescue"
fires fh_retry src/lib/fetch.ts "const backoff = attempt * 1000; await new Promise(r => setTimeout(r, backoff)); // retry" "a backoff in code"
fires fh_retry src/lib/fetch.ts "const res = await withRetry(() => fetch(url), { maxAttempts: 3 })" "a call to a retry helper"
fires fh_retry src/lib/fetch.ts "for (let i = 0; i < MAX_RETRIES; i++) {" "a retry loop bound"
fires fh_retry payload/hooks/fetch.sh 'out="$(mt_retry_read 3 2 sleep 30 "" reader)"' "a shell retry call inside a double quoted substitution"
fires fh_retry payload/hooks/fetch.sh 'while [ "$attempt" -lt 3 ]; do
  fetch_the_thing && break
  attempt=$(( attempt + 1 ))
  sleep $(( 2 ** attempt ))   # exponential backoff
done' "a shell retry loop whose retry words are only in its comment"
fires fh_retry src/config.ts "  retries_assumed: 2," "the same field in SOURCE is still counted: only test fixture data is exempt"
fires fh_handles_failure src/api.ts "if (!res.ok) throw new Error(res.statusText)" "a status check and a throw"
fires fh_handles_failure cmd/main.go "if err != nil {" "a Go error branch"
fires fh_handles_failure payload/hooks/x.sh 'git fetch -q origin || { echo "fetch failed" >&2; exit 1; }' "a shell error branch"
fires fh_handles_failure payload/hooks/x.sh 'if ! gh api "repos/$r" >/dev/null 2>&1; then' "a shell negated status check"

# A template literal nested inside another's ${...} closes where it closes, so the code after it is
# still read (measured: claude-config 9ed36c578 lost five real catches to the misread before this).
fires fh_catch payload/mods/a/hooks/register.ts 'if (r.exitCode !== 0) throw new Error(`could not be written: ${firstLine(r.stderr) || `exit ${r.exitCode}`}`)
}
try { await run() } catch (err) {' "a catch after a nested template literal"

# Added lines can begin INSIDE a docstring or a block comment opened above the hunk. Its closing
# quote or */ must not be read as an opening that swallows the code after it (measured:
# claude-config ef1291176 lost a real except that way), and its prose lines are not code.
fires fh_catch payload/hooks/lib/x.py '    passed over is appended to it as (its name, the text after it), for rtk_field."""
    if passed is not None:
        try:
            n = int(w)
        except ValueError:
            return ""' "a Python except after the tail of a docstring opened above"
fires fh_catch payload/hooks/lib/x.py '      it runs none of them, exit 0 either way.
    """
    try:
        go()
    except OSError:
        pass' "a Python except after a lone closing quote of a docstring opened above"
fires fh_catch src/x.ts ' * and it would retry the call with backoff here.
 */
export const go = () => run().catch(report)' "a catch after the tail of a block comment opened above"
silent fh_retry src/x.ts ' * and then we retry the call with backoff, which is the
 * whole point of this comment, opened above the hunk.' "the prose lines of a block comment opened above"
silent fh_retry payload/hooks/lib/x.py '    The caller retries with backoff, as the docstring above says."""
    return value' "the tail of a docstring that names a retry"

# --- real constructs still fire, in a TEST file ------------------------------------------------
fires fh_catch "$ISSUE_PATH" "try { render(<Panel />) } catch (e) { return null }" "a real catch in a test file"
fires fh_retry "$ISSUE_PATH" "await retry(() => expect(screen.getByText('Saved')).toBeVisible())" "a real retry call in a test file"
fires fh_retry payload/hooks/test-thing.sh 'while [ "$tries" -lt 5 ]; do retry_once && break; done' "a retry loop in a shell suite"

# The shell backoff case above must fire on the CODE, not its comment: with the comment removed it
# still fires, and with only the comment it does not.
fires fh_retry payload/hooks/fetch.sh 'sleep $(( 2 ** attempt )); backoff=$((backoff * 2))' "shell backoff arithmetic"
silent fh_retry payload/hooks/fetch.sh 'sleep 1   # exponential backoff, retry' "the same words only in a comment"

# --- what the code only text keeps -----------------------------------------------------------------
# A non empty string keeps one placeholder, so `return "x"` never reads as the empty `return ""` the
# advisory's error path trigger looks for, while a really empty string stays empty.
code_is() {   # $1 path  $2 line  $3 expected  $4 what
  local got; got="$(printf '%s\n' "$2" | fh_code_only "$1")"
  if [ "$got" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $4: got [$got], expected [$3]"; fi
}
code_is src/a.ts "  } catch { return 'pass' }  // was 'fail'" "  } catch { return 'S' }  " "a non empty string keeps a placeholder, the comment goes"
code_is src/a.ts "  } catch { return '' }" "  } catch { return '' }" "an empty string stays empty"
code_is tools/x.py 'except OSError:  # "retry"' 'except OSError:  ' "a Python comment goes"
code_is payload/hooks/x.sh 'echo "retry $n in ${dir} via $(retry_cmd "a b")" # later' 'echo "$n${dir}$(retry_cmd "a b")S" ' "shell keeps every expansion inside double quotes"
code_is payload/hooks/x.sh "awk '{ print \$1 }' f" "awk '{ print \$1 }' f" "shell keeps single quoted programs as code"
code_is README.md "catch (e) { retry() }" "" "prose carries no code"

# --- the diff reader every gate calls --------------------------------------------------------------
cat > "$WORK/diff" <<'DIFF'
diff --git a/src/send.ts b/src/send.ts
--- a/src/send.ts
+++ b/src/send.ts
@@ -1,0 +2,3 @@
+try {
+  await send()
+} catch (e) { report(e) }
diff --git a/apps/web/src/components/canvas/__tests__/LeadValidationConfig.carries-fields.test.tsx b/apps/web/src/components/canvas/__tests__/LeadValidationConfig.carries-fields.test.tsx
--- /dev/null
+++ b/apps/web/src/components/canvas/__tests__/LeadValidationConfig.carries-fields.test.tsx
@@ -0,0 +1,2 @@
+    window_days: 7, source: 'history', subtype: null, retries_assumed: 2,
+chooseOption(within(editor()).getByRole('combobox', { name: 'If the lead has no value' }), 'Fail the run')
diff --git a/src/old.ts b/src/old.ts
--- a/src/old.ts
+++ b/src/old.ts
@@ -3,1 +3,1 @@
-} catch (e) { return [] }
+} finally { done() }
diff --git a/payload/hooks/poll.sh b/payload/hooks/poll.sh
--- a/payload/hooks/poll.sh
+++ b/payload/hooks/poll.sh
@@ -9,0 +10,1 @@
+  delay=$(( delay * 2 ))  # backoff
+  mt_retry_read 3 2 sleep
DIFF
got="$(fh_files < "$WORK/diff" | tr '\n' ' ')"
want="src/send.ts payload/hooks/poll.sh "
if [ "$got" = "$want" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: fh_files listed [$got], expected [$want]"; fi
# Runnable as a command too, for callers that are not shell (the review runner).
got="$(bash "$LIB" files < "$WORK/diff" | tr '\n' ' ')"
if [ "$got" = "$want" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: 'failure-handling.sh files' listed [$got], expected [$want]"; fi
# The lessons review's input carries whole files after the diff, each headed `===== FULL FILE`
# (lib/ai-review-common.sh). Their lines are not added lines, even one that happens to begin with +.
cat > "$WORK/fulldiff" <<'FULL'
diff --git a/src/clean.ts b/src/clean.ts
--- a/src/clean.ts
+++ b/src/clean.ts
@@ -1,0 +2,1 @@
+export const b = 2


===== FULL FILE at abc1234: src/clean.ts =====
export const a = 1
+  } catch (e) { return [] }
FULL
got="$(bash "$LIB" files < "$WORK/fulldiff" | tr '\n' ' ')"
if [ -z "$got" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: a FULL FILE section after the diff was read as added lines: listed [$got]"; fi
got="$(printf '' | bash "$LIB" files; echo "rc=$?")"
if [ "$got" = "rc=0" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: an empty diff lists nothing and exits 0, got [$got]"; fi

# --- one predicate: nothing else in payload carries its own copy (L613) -------------------------
# The class this issue came from is a failure question answered by a hand written word list. A new
# alternation of the failure words in a regex anywhere outside the lib is a second copy, and a second
# copy drifts (L370). Suites, rule text and docs are exempt: they quote the words, they do not decide.
copies="$(grep -r -n -E -i 'retr(y|ies)[|]|[|]backoff|catch\[\[:space:\]\]|except\[\[:space:\]' "$REPO/payload" \
  --include='*.sh' --include='*.py' --include='*.ts' --include='*.js' --include='*.mjs' 2>/dev/null \
  | grep -v -E '/(test-[^/]*|[^/]*\.test\.[a-z]+|[^/]*_tests?\.py)[:]' \
  | grep -v -E '/tests/' \
  | grep -v -F "$LIB:")"
if [ -z "$copies" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: a failure handling word list outside lib/failure-handling.sh (call the lib instead):"; printf '%s\n' "$copies"; fi
# And the guard is real: it finds the shape it is looking for when one is planted (L1).
mkdir -p "$WORK/payload/hooks"
printf '%s\n' "RE='(retry|retries|backoff)'" > "$WORK/payload/hooks/new-gate.sh"
planted="$(grep -r -n -E -i 'retr(y|ies)[|]|[|]backoff|catch\[\[:space:\]\]|except\[\[:space:\]' "$WORK/payload" --include='*.sh')"
if [ -n "$planted" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: the copy guard did not find a planted word list"; fi

# Every gate that asks the question reads the lib (L261): the advisory, the push gate, the review.
for caller in lessons-advisory.sh require-tests-before-push.sh lib/ai-review-run.py; do
  if grep -q 'failure-handling.sh' "$DIR/$caller"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $caller does not read lib/failure-handling.sh"; fi
done

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
