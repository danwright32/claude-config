#!/usr/bin/env bash
# WHOLE-HOOK tests for check-closing-keyword.sh: feeds it real PreToolUse payloads and asserts
# the exit code, rather than testing the detector in isolation.
#
# This layer exists because of a real miss. The detector had 26 green assertions and the hook
# still had a defect the detector could never see: the MATCHER scanned the entire command
# string, so it fired on any command whose PAYLOAD merely quoted a PR-creation command. It
# blocked its own issue-closing comment, whose body quoted the broken phrasing as an example.
#
# A command and a command's payload are different things. The detector cannot tell them apart,
# because it never sees the shell. Only this layer can.
#
# Run with SKIP_CLOSING_CHECK=1, since every payload here necessarily contains the exact
# phrasing the hook exists to block.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/check-closing-keyword.sh"

pass=0
fail=0

# Every closing keyword and number pair is looked up (claude-config#2464), never against GitHub here:
# the stub reads "owner/name#N kind state" lines (kind issue, pr or fail), an unlisted number being an
# open issue. The commands run in a checkout whose origin is acme/widget, so a bare #N is acme/widget's.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/closing-keyword-hook.XXXXXXXX")"
trap 'rm -rf "$WORK"' EXIT
LOOKUP_TABLE="$WORK/table"
printf '%s\n' "acme/widget#2451 pr open" "acme/widget#2438 pr open" "acme/other#5 pr open" \
  "acme/widget#404 fail" > "$LOOKUP_TABLE"
cat > "$WORK/lookup.sh" <<'STUB'
#!/usr/bin/env bash
kind=issue; state=open
line="$(grep -m 1 -i -- "^$1#$2 " "$LOOKUP_TABLE")"
[ -n "$line" ] && read -r _ kind state <<< "$line"
case "$kind" in
  fail) echo "HTTP 404: Not Found (https://api.github.com/repos/$1/issues/$2)" >&2; exit 1 ;;
  pr) printf '{"number":%s,"state":"%s","pull_request":{"url":"x"}}' "$2" "$state" ;;
  *) printf '{"number":%s,"state":"%s"}' "$2" "$state" ;;
esac
STUB
chmod +x "$WORK/lookup.sh"
export LOOKUP_TABLE CLOSING_KEYWORD_LOOKUP="$WORK/lookup.sh"
REPO="$WORK/widget"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" remote add origin https://github.com/acme/widget.git
RUN_CWD="$REPO"
HOOK_MSG=""

# run <description> <expected-exit> <command-string> [<a needle the message must carry>]
run() {
  local desc="$1" want="$2" command="$3" needle="${4:-}"
  local payload got
  payload="$(python3 -c '
import json, sys
print(json.dumps({"tool_input": {"command": sys.argv[1]}, "cwd": sys.argv[2]}))
' "$command" "$RUN_CWD")"
  HOOK_MSG="$(printf '%s' "$payload" | "$HOOK" 2>&1 >/dev/null)"
  got=$?
  if [ "$got" -eq "$want" ]; then
    pass=$((pass+1))
  else
    fail=$((fail+1))
    echo "FAIL: $desc (wanted exit $want, got $got): ${HOOK_MSG:0:400}"
  fi
  if [ -n "$needle" ]; then
    case "$HOOK_MSG" in
      *"$needle"*) pass=$((pass+1)) ;;
      *) fail=$((fail+1)); echo "FAIL: $desc: the message did not carry [$needle], said: ${HOOK_MSG:0:400}" ;;
    esac
  fi
}

BLOCK=2
ALLOW=0

# --- claude-config#2464: a closing word in passing before a pull request (the #2456 description) ---
run "#2464 the #2456 sentence, before an open pull request, is refused" $BLOCK \
  'gh pr create --title x --body "6 were cancelled, including the p0 fix #2451 and batch #2438, which"' \
  "names pull request #2451"
run "#2464 the refusal quotes the phrase to reword" $BLOCK \
  'gh pr create --title x --body "6 were cancelled, including the p0 fix #2451 and batch #2438, which"' \
  "including the p0 fix #2451"
run "#2464 a bare #N is looked up in the repository --repo names" $BLOCK \
  'gh pr create -R acme/other --title x --body "Closes #5"' "pull request"
run "#2464 control: the same #5 in the checkout's own repository is an open issue, and passes" $ALLOW \
  'gh pr create --title x --body "Closes #5"'
run "#2464 a lookup that fails refuses, saying why" $BLOCK \
  'gh pr create --title x --body "Closes #404."' "HTTP 404"
run "#2464 a closing word mid sentence before an open issue is refused" $BLOCK \
  'git commit -m "Tidies the follow up fix #12 asked for"' "not at the start of a line or sentence"
run "#2464 a commit message whose Closes line is in a heredoc passes" $ALLOW \
  $'git commit -F - <<\'EOF\'\nTidy the reader\n\nCloses #12\nEOF'
RUN_CWD="/tmp"
run "#2464 with no repository to look a bare #N up in, it refuses rather than passes" $BLOCK \
  'git commit -m "Closes #12"' "which repository"
RUN_CWD="$REPO"

BLOCK=2
ALLOW=0

# --- The bug this hook exists for ---
run "a PR body that negates a close"  $BLOCK 'gh pr create --title x --body "It does not close #897, which stays open."'
run "a commit message that negates"   $BLOCK 'git commit -m "this does not fix #12"'
run "a PR edit that negates"          $BLOCK 'gh pr edit 12 --body "does not resolve #5"'
# The shell runs the substitutions in the body of a heredoc whose end marker is unquoted, so a commit
# there is judged (claude-config#2053); a quoted marker keeps the body text, which commits nothing.
run "#2053 a commit in an unquoted heredoc body's substitution" $BLOCK $'cat <<EOF\n$(git commit -m "this does not fix #12")\nEOF'
run "#2053 control: the same in a quoted heredoc body is text" $ALLOW $'cat <<\'EOF\'\n$(git commit -m "this does not fix #12")\nEOF'

# --- gh takes the subcommand's flags in front of it (#1188): the same creation and edit ---
run "#1188 -R in front of pr create"           $BLOCK 'gh -R o/x pr create --title x --body "It does not close #897."'
run "#1188 -R between pr and create"           $BLOCK 'gh pr -R o/x create --title x --body "It does not close #897."'
run "#1188 --repo=x in front of pr edit"       $BLOCK 'gh --repo=o/x pr edit 12 --body "does not resolve #5"'
run "#1188 --repo between pr and edit"         $BLOCK 'gh pr --repo o/x edit 12 --body "does not resolve #5"'
run "#1188 behind rtk"                         $BLOCK 'rtk gh -R o/x pr create --title x --body "It does not close #897."'
run "#1188 behind env with a setting"          $BLOCK 'env GH_TOKEN=x gh -R o/x pr create --title x --body "It does not close #897."'
run "#1188 behind sudo"                        $BLOCK 'sudo gh pr -R o/x edit 12 --body "does not resolve #5"'
run "#1188 a commit with git -C in front"      $BLOCK 'git -C /tmp commit -m "this does not fix #12"'
run "#1188 a commit behind env"                $BLOCK 'env A=1 git commit -m "this does not fix #12"'
# --- run by another program it is the same creation, edit or commit (#1478) ---
run "#1478 a pr create in bash -c"             $BLOCK "bash -c 'gh pr create --title x --body \"It does not close #897.\"'"
run "#1478 a pr edit in sh -c after a cd"      $BLOCK "sh -c 'cd /tmp && gh pr edit 12 --body \"does not resolve #5\"'"
run "#1478 a pr create through eval"           $BLOCK "eval 'gh pr create --title x --body \"It does not close #897.\"'"
run "#1478 a pr create through nohup"          $BLOCK 'nohup gh pr create --title x --body "It does not close #897."'
run "#1478 a pr create through rtk proxy"      $BLOCK 'rtk proxy gh pr create --title x --body "It does not close #897."'
run "#1478 a commit in bash -c"                $BLOCK "bash -c 'git commit -m \"this does not fix #12\"'"
run "#1478 a commit through timeout"           $BLOCK 'timeout 30 git commit -m "this does not fix #12"'
run "#1188 control: a flag in front of pr view" $ALLOW 'gh -R o/x pr view 12 --json body --jq ".body" | grep "does not close #5"'

# --- The sentences lib/closing-keyword.py learned with #1550 reach this hook too ---
run "#1550 a conditional close"               $BLOCK 'gh pr create --title x --body "The parser change would also have closed #2584."'
run "#1550 a close of an issue called part of" $BLOCK 'gh pr edit 12 --body "Part of #953. The next PR closes #953."'

# --- A detector that crashes prints no finding, which must not read as a clean text (L98) ---
BROKEN_LIB="$(mktemp "${TMPDIR:-/tmp}/closing-keyword-broken.XXXXXXXX")"
printf 'raise SystemExit(5)\n' > "$BROKEN_LIB"
CLOSING_KEYWORD_LIB="$BROKEN_LIB" run "#1550 a crashing detector refuses rather than passes" $BLOCK \
  'gh pr create --title x --body "Part of #897, which stays open."'
rm -f "$BROKEN_LIB"

# --- A genuine close must sail through, or the hook is useless ---
run "a real close"                    $ALLOW 'gh pr create --title x --body "Closes #897."'
run "the safe phrasing"               $ALLOW 'gh pr create --title x --body "Part of #897, which stays open."'
run "an ordinary commit"              $ALLOW 'git commit -m "#897: fix the ratchet only"'

# --- A command is not its payload ---
#
# The miss that created this file. Each of these CONTAINS the forbidden phrasing, and even
# contains the text of a PR-creation command, but none of them can close anything.
run "an issue comment quoting a pr create" $ALLOW \
  'gh issue close 912 --comment "example: gh pr create --body \"does not close #897\" is blocked"'
run "an issue comment discussing it"       $ALLOW \
  'gh issue comment 912 --body "this does not close #897 and that is the bug"'
run "a plain echo of the phrasing"         $ALLOW \
  'echo "gh pr create --body \"does not close #897\""'
run "a grep for the phrasing"              $ALLOW \
  'grep -r "does not close #897" .'

# --- Commands that cannot link an issue at all ---
run "a push"     $ALLOW 'git push -u origin branch'
run "a pr view"  $ALLOW 'gh pr view 914 --json state'

# --- The override, and failing open ---
run "the documented override" $ALLOW \
  'SKIP_CLOSING_CHECK=1 gh pr create --title x --body "It does not close #897."'
run "an env-prefixed real command still blocked" $BLOCK \
  'GH_TOKEN=abc gh pr create --title x --body "It does not close #897."'

# --- the detector's own reader (claude-config#486) -----------------------------
#
# The detector (lib/closing-keyword.py since #1550) is python3 and nothing asked whether python3 was
# installed. Without it the
# findings came back empty, the emptiness test passed, and this gate exited 0 on exactly the
# phrasing it exists to stop, with nothing said (L490, L42, L98).
. "$DIR/lib/no-python-path.sh"
NOPY_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/check-closing-nopy.XXXXXXXX")"
NOPY="$NOPY_ROOT/bin"
# jq linked in, so the payload is still legible and only the detector's interpreter is gone.
npp_build_bin "$NOPY" jq
if npp_reaches_python3 "$NOPY"; then
  fail=$((fail+1)); echo "FAIL: the bare directory really reaches no python3 (it found one, so nothing below measures its absence)"
else pass=$((pass+1)); fi

# run_nopy <description> <expected-exit> <command-string> [needle the message must carry]
run_nopy() {
  local desc="$1" want="$2" command="$3" needle="${4:-}"
  local payload msg got
  payload="$(python3 -c '
import json, sys
print(json.dumps({"tool_input": {"command": sys.argv[1]}, "cwd": "/tmp"}))
' "$command")"
  msg="$(printf '%s' "$payload" | env PATH="$NOPY" "$NOPY/bash" "$HOOK" 2>&1 >/dev/null)"; got=$?
  if [ "$got" -eq "$want" ]; then pass=$((pass+1));
  else fail=$((fail+1)); echo "FAIL: $desc (wanted exit $want, got $got)"; fi
  if [ -n "$needle" ]; then
    case "$msg" in
      *"$needle"*) pass=$((pass+1)) ;;
      *) fail=$((fail+1)); echo "FAIL: $desc: the message did not name [$needle], said: $msg" ;;
    esac
  fi
}

# A body with NO negation in it at all, on purpose: nothing here can tell the two apart, so the
# refusal comes from the detector being absent rather than from anything it found (L11).
run_nopy "with no python3 a pr create is refused rather than passed unread" $BLOCK \
  'gh pr create --title x --body "Part of #897, which stays open."' 'python3'
run_nopy "and a commit is refused the same way" $BLOCK \
  'git commit -m "Part of #897, which stays open."'
# A command the missing detector takes nothing from is not refused (L54, L324).
run_nopy "a push cannot link an issue, so it is not refused over a detector it never needed" $ALLOW \
  'git push -u origin branch'
# The documented override still clears it (L109).
run_nopy "the visible override still clears the missing detector refusal" $ALLOW \
  'SKIP_CLOSING_CHECK=1 gh pr create --title x --body "Part of #897, which stays open."'
# The control, the same command with python3 present: allowed, so the refusals above are the
# detector's absence and not a fixture that refuses everything (L159).
run "the control still allows the same pr create with python3 present" $ALLOW \
  'gh pr create --title x --body "Part of #897, which stays open."'

# Every fallback with no reader acts on gh's pr group, never on the word create alone, since `gh pr
# new` is gh's other name for gh pr create and no fallback holds a list of gh's aliases
# (claude-config#2424): with no python3, with push-scope.sh missing, and with a payload no reader parses.
run_nopy "#2424 with no python3 gh pr new is refused as gh pr create is" $BLOCK \
  'gh pr new --title x --body "Part of #897, which stays open."' 'python3'
run_nopy "#2424 and with gh's flags in front of the group" $BLOCK \
  'gh -R o/x pr new --title x --body "Part of #897, which stays open."' 'python3'
NOLIB="$NOPY_ROOT/nolib"; mkdir -p "$NOLIB"
cp "$HOOK" "$NOLIB/check-closing-keyword.sh"
nolib_run() {   # $1 = description, $2 = expected exit, $3 = command; the hook with no lib/ beside it
  local payload got
  payload="$(python3 -c '
import json, sys
print(json.dumps({"tool_input": {"command": sys.argv[1]}, "cwd": "/tmp"}))
' "$3")"
  printf '%s' "$payload" | bash "$NOLIB/check-closing-keyword.sh" >/dev/null 2>&1; got=$?
  if [ "$got" -eq "$2" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 (wanted exit $2, got $got)"; fi
}
nolib_run "#2424 control: with push-scope.sh missing gh pr create is refused" $BLOCK \
  'gh pr create --title x --body "Part of #897, which stays open."'
nolib_run "#2424 with push-scope.sh missing gh pr new is refused too" $BLOCK \
  'gh pr new --title x --body "Part of #897, which stays open."'
nolib_run "#2424 control: with push-scope.sh missing a command naming no pull request passes" $ALLOW \
  'ls -la'
unparsed_run() {   # $1 = description, $2 = expected exit, $3 = a payload no reader parses
  local got
  printf '%s' "$3" | "$HOOK" >/dev/null 2>&1; got=$?
  if [ "$got" -eq "$2" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 (wanted exit $2, got $got)"; fi
}
unparsed_run "#2424 control: a payload no reader parses naming gh pr create is refused" $BLOCK \
  '{"tool_input":{"command":"gh pr create --title x --body \"Part of #897\"'
unparsed_run "#2424 a payload no reader parses naming gh pr new is refused too" $BLOCK \
  '{"tool_input":{"command":"gh pr new --title x --body \"Part of #897\"'
unparsed_run "#2424 control: a payload no reader parses naming no pull request passes" $ALLOW \
  '{"tool_input":{"command":"ls -la'

rm -rf "$NOPY_ROOT"

echo
echo "passed: $pass   failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
