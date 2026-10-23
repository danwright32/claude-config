#!/usr/bin/env bash
# Tests for lib/push-changes.sh: what a push carries, the one judge call, and the record of what
# each model judged push gate did (claude-config#1075, #1076). The gates' own suites drive it end to
# end through the real hooks; this one pins each function's contract, the failure paths of the judge
# call above all, since both gates run on every push in every project and fail open on each.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/lib/push-changes.sh"

pass=0
fail=0
ok() { pass=$((pass+1)); }
no() { fail=$((fail+1)); echo "FAIL: $1"; }

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
export PUSH_GATE_LEDGER_DIR="$TMPROOT/ledger"
PATH_BASE="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"

# shellcheck source=lib/push-scope.sh
. "$DIR/lib/push-scope.sh"
# shellcheck source=lib/push-changes.sh
. "$LIB"

mk_repo() {
  local root
  root="$(mktemp -d "$TMPROOT/repo.XXXXXX")"
  git init -q --bare "$root/origin.git"
  git init -q "$root/work"
  (
    cd "$root/work" || exit 1
    git config user.email t@example.com
    git config user.name tester
    git config commit.gpgsign false
    echo init > README.md
    git add README.md
    git commit -qm init
    git remote add origin "$root/origin.git"
    git push -qu origin HEAD
  ) >/dev/null 2>&1
  printf '%s' "$root/work"
}

# ---- pc_resolve / pc_diff -------------------------------------------------------------------------
W="$(mk_repo)"
( cd "$W" && mkdir -p lib tests docs \
    && printf 'def committed_marker():\n    return 1\n' > lib/a.py \
    && printf '{"lockfileVersion": 3}\n' > package-lock.json \
    && printf '<svg/>\n' > lib/logo.svg \
    && git add lib/a.py package-lock.json lib/logo.svg && git commit -qm "add a" \
    && printf 'def pending_marker():\n    return 2\n' > lib/b.py \
    && printf 'def test_b():\n    assert True\n' > tests/test_b.py \
    && printf 'stray_marker = 1\n' > lib/stray.py ) >/dev/null 2>&1

# From a subdirectory, with a commit pending: the answer is the same as from the root. The add names
# its paths as a person in that directory would, relative to it.
( cd "$W/docs" && pc_resolve "git add ../lib/b.py ../tests/test_b.py && git commit -m b && git push"
  rc=$?
  [ "$rc" -eq 0 ] || { echo "rc $rc"; exit 1; }
  [ "$PWD" = "$(cd "$W" && pwd -P)" ] || [ "$PWD" = "$W" ] || { echo "left the shell in $PWD, not the root"; exit 1; }
  printf '%s\n' "$PC_FILES" > "$TMPROOT/files"
  pc_diff . > "$TMPROOT/diff-all"
  pc_diff tests/test_b.py > "$TMPROOT/diff-test"
  pc_diff . ':(exclude)tests/test_b.py' > "$TMPROOT/diff-code"
  pc_messages > "$TMPROOT/msgs"
  printf '%s %s\n' "$PC_COMMIT_IN_CHAIN" "$PC_WIDENED" > "$TMPROOT/flags"
) > "$TMPROOT/resolve-out" 2>&1 || no "pc_resolve from a subdirectory: $(cat "$TMPROOT/resolve-out")"
for f in lib/a.py lib/b.py tests/test_b.py; do
  if grep -qx "$f" "$TMPROOT/files"; then ok; else no "PC_FILES is missing $f: [$(tr '\n' ' ' < "$TMPROOT/files")]"; fi
done
if grep -qx lib/stray.py "$TMPROOT/files"; then no "PC_FILES holds an untracked file the add did not name"; else ok; fi
if grep -q committed_marker "$TMPROOT/diff-all" && grep -q pending_marker "$TMPROOT/diff-all" && grep -q test_b "$TMPROOT/diff-all"; then ok; else no "the whole diff lacks the committed, the pending or the new test file"; fi
if grep -q stray_marker "$TMPROOT/diff-all"; then no "the diff shows an untracked file the commit does not take"; else ok; fi
if grep -q lockfileVersion "$TMPROOT/diff-all" || grep -q '<svg' "$TMPROOT/diff-all"; then no "the shared excludes did not keep a lock file or an image out"; else ok; fi
if grep -q '^+def test_b' "$TMPROOT/diff-test" && ! grep -q pending_marker "$TMPROOT/diff-test"; then ok; else no "a pathspec of one new file did not give exactly its diff, as added lines"; fi
if grep -q test_b "$TMPROOT/diff-code"; then no "an exclude pathspec did not keep the test out of the rest of the diff"; else ok; fi
if grep -qx -- '- add a' "$TMPROOT/msgs"; then ok; else no "pc_messages did not list the commit the push carries: [$(cat "$TMPROOT/msgs")]"; fi
if [ "$(cat "$TMPROOT/flags")" = "1 0" ]; then ok; else no "commit in chain and widened flags: [$(cat "$TMPROOT/flags")]"; fi

# PC_DIFF_CONTEXT widens every diff to that many lines around each change, in both the committed
# range and the pending commit, and leaving it unset keeps git's three (claude-config#1238).
W="$(mk_repo)"
( cd "$W" && mkdir -p lib && printf 'far_marker\n2\n3\n4\n5\n6\n7\n8\nlast\n' > lib/c.js \
    && git add lib/c.js && git commit -qm base && git push -q \
    && printf 'far_marker\n2\n3\n4\n5\n6\n7\n8\ncommitted\n' > lib/c.js && git commit -qam one \
    && printf 'far_marker\n2\n3\n4\n5\n6\n7\n8\npending\n' > lib/c.js ) >/dev/null 2>&1
( cd "$W" && pc_resolve "git add lib/c.js && git commit -m two && git push" >/dev/null 2>&1
  PC_DIFF_CONTEXT=100 pc_diff lib/c.js > "$TMPROOT/diff-wide"
  pc_diff lib/c.js > "$TMPROOT/diff-narrow" )
[ "$(grep -c '^ far_marker' "$TMPROOT/diff-wide")" = 2 ] && ok \
  || no "PC_DIFF_CONTEXT did not show the far line around both changes: [$(cat "$TMPROOT/diff-wide")]"
grep -q '^ far_marker' "$TMPROOT/diff-narrow" && no "without PC_DIFF_CONTEXT the diff showed more than git's default context" || ok

# A push level with its upstream carries nothing: 1, quiet.
W="$(mk_repo)"
( cd "$W" && pc_resolve "git push"; echo "$?" ) > "$TMPROOT/rc" 2>/dev/null
if [ "$(tail -1 "$TMPROOT/rc")" = 1 ]; then ok; else no "a push carrying nothing with an upstream should return 1, got $(tail -1 "$TMPROOT/rc")"; fi

# No upstream and a local base that is the current commit: blind, 2 (#736).
B="$(mktemp -d "$TMPROOT/noup.XXXXXX")"
( cd "$B" && git init -q -b main && git config user.email t@e && git config user.name t \
    && git config commit.gpgsign false && echo x > a.txt && git add a.txt && git commit -qm x ) >/dev/null 2>&1
( cd "$B" && pc_resolve "git push"; echo "$?" ) > "$TMPROOT/rc" 2>/dev/null
if [ "$(tail -1 "$TMPROOT/rc")" = 2 ]; then ok; else no "a push with no upstream and the base at HEAD should return 2 (blind), got $(tail -1 "$TMPROOT/rc")"; fi

# ---- pc_judge: every way the call can fail is named, and none reads as a verdict ------------------
STUB="$TMPROOT/stub"; mkdir -p "$STUB"
cat > "$STUB/claude" <<'S'
#!/usr/bin/env bash
cat >/dev/null
[ -n "${STUB_OUT:-}" ] && printf '%s' "$STUB_OUT"
exit "${STUB_EXIT:-0}"
S
chmod +x "$STUB/claude"
TO="$TMPROOT/to"; mkdir -p "$TO"
printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 124\n' > "$TO/timeout"; chmod +x "$TO/timeout"

judge_case() {   # <label> <PATH> <expect rc> <pattern on PC_JUDGE_ERR, or on PC_JUDGE_OBJ for 0>
  local rc got
  PATH="$2" pc_judge sonnet 7 "rubric" "input"; rc=$?
  if [ "$3" = 0 ]; then got="$PC_JUDGE_OBJ"; else got="$PC_JUDGE_ERR"; fi
  if [ "$rc" = "$3" ] && grep -Eq -- "$4" <<< "$got"; then ok; else no "$1: rc $rc (want $3), got [$got]"; fi
}
STUB_OUT='{"result":"{\"verdict\":\"pass\"}","duration_ms":1500,"total_cost_usd":0.02}' judge_case "a clean answer" "$STUB:$PATH_BASE" 0 '^\{"verdict":"pass"\}$'
if [ "$PC_JUDGE_MS" = 1500 ] && [ "$PC_JUDGE_COST" = 0.02 ] && [ "$PC_JUDGE_MODEL" = sonnet ] && [ "$PC_JUDGE_BYTES" = 5 ]; then ok; else no "time, cost, model or size not read: [$PC_JUDGE_MS] [$PC_JUDGE_COST] [$PC_JUDGE_MODEL] [$PC_JUDGE_BYTES]"; fi
# The envelope's figures are recorded as the envelope wrote them: %g kept 6 significant digits and
# wrote a different number for a long call or a precise cost (merge review of #1109).
STUB_OUT='{"result":"{\"verdict\":\"pass\"}","duration_ms":1234567.5,"total_cost_usd":0.123456789}' judge_case "large and precise figures" "$STUB:$PATH_BASE" 0 'verdict'
if [ "$PC_JUDGE_MS" = 1234567.5 ] && [ "$PC_JUDGE_COST" = 0.123456789 ]; then ok; else no "figures rewritten on the way to the ledger: [$PC_JUDGE_MS] [$PC_JUDGE_COST]"; fi
STUB_OUT='{"result":"```json\n{\"verdict\":\"block\",\"findings\":[]}\n```"}' judge_case "a fenced answer" "$STUB:$PATH_BASE" 0 '"verdict":"block"'
STUB_OUT='{"is_error":true,"result":"overloaded"}' judge_case "an error envelope" "$STUB:$PATH_BASE" 1 'error envelope'
STUB_OUT='{"result":"looks fine to me"}' judge_case "a prose answer" "$STUB:$PATH_BASE" 1 'not readable JSON'
STUB_OUT='{"result":"[1,2,3]"}' judge_case "an answer that is not an object" "$STUB:$PATH_BASE" 1 'not readable JSON'
STUB_OUT='<html>502 Bad Gateway</html>' judge_case "a garbage envelope" "$STUB:$PATH_BASE" 1 'not readable JSON'
STUB_OUT='' STUB_EXIT=3 judge_case "nothing returned" "$STUB:$PATH_BASE" 1 'returned nothing \(exit 3\)'
STUB_OUT='' judge_case "a timeout" "$TO:$STUB:$PATH_BASE" 1 'timed out after 7s'
# The judge runs on the FIVE MINUTE prompt cache (claude-config#1600). On a subscription a headless
# run otherwise writes to the one hour cache at twice the input price; 392 of 670 judge runs in the
# week to 2026-10-23 started within five minutes of the one before, so five minutes was estimated at
# 16.8M input units a week against 20.7M. Read from the environment the judge's claude actually
# received, on both launches: through a timeout command, and with none on PATH.
CACHE_STUB="$TMPROOT/cachestub"; mkdir -p "$CACHE_STUB"
printf '#!/usr/bin/env bash\ncat >/dev/null\nprintf "%%s\\n" "${CLAUDE_CODE_PROMPT_CACHE_TTL:-unset}" > "%s/ttl"\nprintf "%%s" "{\\"result\\":\\"{}\\"}"\n' "$TMPROOT" > "$CACHE_STUB/claude"
chmod +x "$CACHE_STUB/claude"
PASS_TO="$TMPROOT/passto"; mkdir -p "$PASS_TO"
printf '#!/usr/bin/env bash\nshift\nexec "$@"\n' > "$PASS_TO/timeout"; chmod +x "$PASS_TO/timeout"
# A PATH with no timeout command whatever the machine has (Linux has /usr/bin/timeout, a Mac with
# coreutils has gtimeout): only the tools pc_judge and the stand in use, linked from PATH_BASE.
NOTO="$TMPROOT/notimeout"; mkdir -p "$NOTO"
for t in bash cat mktemp date rm python3; do
  p="$(PATH="$PATH_BASE" command -v "$t" 2>/dev/null)" && ln -s "$p" "$NOTO/$t"
done
for judge_path in "$PASS_TO:$CACHE_STUB:$NOTO" "$CACHE_STUB:$NOTO"; do
  rm -f "$TMPROOT/ttl"
  PATH="$judge_path" pc_judge sonnet 7 "rubric" "input" >/dev/null 2>&1
  case "$judge_path" in "$PASS_TO"*) how="through a timeout command" ;; *) how="with no timeout command" ;; esac
  if [ "$(cat "$TMPROOT/ttl" 2>/dev/null)" = 5m ]; then ok; else no "the judge launched $how ran with CLAUDE_CODE_PROMPT_CACHE_TTL=[$(cat "$TMPROOT/ttl" 2>/dev/null || echo 'not reached')], want 5m (#1600)"; fi
done
judge_case "no CLI" "$PATH_BASE" 1 'no claude CLI'
if [ -z "$PC_JUDGE_MODEL" ]; then ok; else no "a judge that never launched still names a model ($PC_JUDGE_MODEL), so it would be counted as a call"; fi
# The CLI on PATH below has to be absent for that case to mean anything.
if PATH="$PATH_BASE" command -v claude >/dev/null 2>&1; then no "the no CLI case found a claude on $PATH_BASE, so it proved nothing"; else ok; fi

# ---- pc_record ----------------------------------------------------------------------------------
LEDGER="$(pc_ledger_path)"
W="$(mk_repo)"
( cd "$W" && PC_GATE=simplify PC_CALL_ID=toolu_1 pc_record block "$(printf 'one\ttab\nnewline')" ) || no "pc_record failed on a writable ledger"
row="$(tail -1 "$LEDGER" 2>/dev/null)"
if [ "$(awk -F '\t' '{ print NF }' <<< "$row")" = 15 ]; then ok; else no "a row should have 15 columns, got [$row]"; fi
if [ "$(awk -F '\t' '{ print $3 "|" $4 "|" $7 "|" $14 }' <<< "$row")" = "simplify|block|toolu_1|one tab newline" ]; then ok; else no "row fields wrong, or a tab or newline in the detail broke it: [$row]"; fi
before="$(wc -l < "$LEDGER")"
( cd "$W" && PC_GATE=simplify pc_record blocked "x" ); rc=$?
if [ "$rc" = 2 ] && [ "$(wc -l < "$LEDGER")" = "$before" ]; then ok; else no "an outcome outside the list must be refused (2) and write nothing, got rc $rc"; fi
printf 'x\n' > "$TMPROOT/notadir"
( cd "$W" && PUSH_GATE_LEDGER_DIR="$TMPROOT/notadir" PC_GATE=tests pc_record pass ) 2> "$TMPROOT/err"; rc=$?
if [ "$rc" = 1 ] && [ ! -s "$TMPROOT/err" ]; then ok; else no "an unwritable ledger must return 1 and print nothing itself, got rc $rc [$(cat "$TMPROOT/err")]"; fi

# pc_call_id reads the id Claude Code gives every hook on one call, and nothing when there is none.
if [ "$(pc_call_id '{"tool_name":"Bash","tool_use_id": "toolu_01AbC","tool_input":{}}')" = toolu_01AbC ]; then ok; else no "pc_call_id did not read the id"; fi
if [ -z "$(pc_call_id '{"tool_input":{"command":"git push"}}')" ]; then ok; else no "pc_call_id invented an id"; fi

# ---- one copy: neither gate keeps its own (L613) ------------------------------------------------
# What each gate used to carry a copy of. A gate that grows one again fails here, named.
copies() {   # $1 = a gate's text on stdin's file
  grep -nE "(^|[^_A-Z])EXCLUDES=\(|claude -p|ps_pending_base|ps_pending_files|--diff-filter|ls-files --others|is_error" "$1"
}
for g in require-tests-before-push.sh simplify-before-push.sh; do
  found="$(copies "$DIR/$g")"
  if [ -z "$found" ]; then ok; else no "$g keeps its own copy of what lib/push-changes.sh holds: $found"; fi
  if grep -q 'lib/push-changes.sh' "$DIR/$g"; then ok; else no "$g does not source lib/push-changes.sh"; fi
done
# The scan is seen to fire: the text the gates carried before #1076 holds every one of those copies.
OLD="$TMPROOT/old-gate.sh"
printf '%s\n' 'EXCLUDES=(":(exclude)*.lock")' '  claude -p --model "$JUDGE_MODEL"' > "$OLD"
if [ -n "$(copies "$OLD")" ]; then ok; else no "the copy scan does not fire on a gate holding its own exclude list and launch"; fi

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
