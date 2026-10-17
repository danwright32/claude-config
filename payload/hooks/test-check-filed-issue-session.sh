#!/usr/bin/env bash
# Tests for check-filed-issue-session.sh and filed_issue_session.py (claude-config#1272).
#
# The issue field gate judges a create before it runs, so a body written by a script, by cat of
# another file, or by a heredoc or printf that expands a variable passes it unread. After the create
# this hook reads the new issue's body back from GitHub and, where the line naming the session is
# missing, adds it and says so. Every case runs a stand-in gh on PATH, never GitHub: it answers
# `gh issue view` from a body file, records every call, and keeps what `gh issue edit` writes, so
# the read back after an edit sees it.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/check-filed-issue-session.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-check-filed-issue-session.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
LINE='Claude-Session: local 11111111-2222-3333-4444-555555555555'
SESSION=11111111-2222-3333-4444-555555555555
URL='https://github.com/danwright32/demo/issues/42'
FIELDS='--milestone Ungrouped --label bug --label priority-p2'

# The stand-in gh. GH_BODY is the issue's body on "GitHub"; GH_CREATED its creation time;
# GH_VIEW_FAILS and GH_EDIT_FAILS make that call fail as gh does, on stderr with exit 1.
cat >"$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
case "$1 $2" in
  "issue view")
    [ -n "${GH_VIEW_FAILS:-}" ] && { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
    python3 -c 'import json,sys; print(json.dumps({"body": open(sys.argv[1]).read(), "createdAt": sys.argv[2]}))' "$GH_BODY" "${GH_CREATED:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
    ;;
  "issue edit")
    [ -n "${GH_EDIT_FAILS:-}" ] && { echo "HTTP 403: Resource not accessible by integration" >&2; exit 1; }
    # GH_EDIT_IGNORED: gh says the edit went through, and the body on GitHub is unchanged.
    case " $* " in *" --body-file - "*) if [ -n "${GH_EDIT_IGNORED:-}" ]; then cat >/dev/null; else cat >"$GH_BODY"; fi ;; *) echo "unexpected edit: $*" >&2; exit 2 ;; esac
    echo "$3"
    ;;
  *) echo "unexpected gh call: $*" >&2; exit 2 ;;
esac
GH
chmod +x "$TMP/bin/gh"

pass=0
fail=0
check() { if [ "$2" = ok ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1: $2"; fi; }

# run <command> <stdout of the Bash call> [exit code]: the hook's output for a PostToolUse payload,
# in a session unless SESSION_ID is set empty. Leaves the gh calls in $TMP/gh.log.
run() {
  : >"$TMP/gh.log"
  python3 -c '
import json, sys
json.dump({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]},
           "tool_response": {"stdout": sys.argv[2], "stderr": "", "interrupted": False, "exit_code": int(sys.argv[3])}}, sys.stdout)
' "$1" "$2" "${3:-0}" | env -u CLAUDE_CODE_BRIDGE_SESSION_ID CLAUDE_CODE_SESSION_ID="${SESSION_ID-$SESSION}" \
    PATH="$TMP/bin:$PATH" GH_LOG="$TMP/gh.log" GH_BODY="$TMP/body.md" bash "$HOOK" 2>"$TMP/stderr"
}
body() { printf '%s' "$1" >"$TMP/body.md"; }
edits() { grep -c '^issue edit' "$TMP/gh.log"; }
calls() { grep -c . "$TMP/gh.log"; }

# The three shapes the gate cannot read before the command runs, each filed without the line: the
# hook reads the body from GitHub, adds the line once, reads it back, and says on GitHub it did.
shapes=(
  "python3 make_body.py > body.md && gh issue create --title t --body-file body.md $FIELDS"
  "cat notes.md > body.md && gh issue create --title t -F body.md $FIELDS"
  'printf "%s\n" "$BODY" > body.md; gh issue create --title t -F body.md '"$FIELDS"
  'gh issue create --title t --body "$(cat <<EOF
$SUMMARY
EOF
)" '"$FIELDS"
)
for cmd in "${shapes[@]}"; do
  name="#1272 ${cmd:0:30}"
  body $'What broke.\n\nWhat to do.\n'
  out="$(run "$cmd" "$URL")"
  [ "$(edits)" = 1 ] && check "$name: the missing line is added on GitHub" ok || check "$name: the missing line is added on GitHub" "$(cat "$TMP/gh.log")"
  [ "$(cat "$TMP/body.md")" = $'What broke.\n\nWhat to do.\n\n'"$LINE" ] && check "$name: the body keeps every word and ends with the line" ok || check "$name: the body keeps every word and ends with the line" "$(cat "$TMP/body.md")"
  case "$out" in *'added the line'*'on GitHub'*"$LINE"*) check "$name: the output says the issue was edited on GitHub" ok ;; *) check "$name: the output says the issue was edited on GitHub" "$out" ;; esac
  case "$out" in *'"systemMessage"'*'#42'*) check "$name: Dan is told too" ok ;; *) check "$name: Dan is told too" "$out" ;; esac
  case "$out" in *'"additionalContext"'*) check "$name: Claude is told" ok ;; *) check "$name: Claude is told" "$out" ;; esac
done

# A body that already carries the line is read and left alone, with nothing said.
body $'What broke.\n\n'"$LINE"$'\n'
out="$(run "${shapes[0]}" "$URL")"
[ "$(edits)" = 0 ] && [ "$(calls)" = 1 ] && check "#1272 a body with the line is read once and not edited" ok || check "#1272 a body with the line is read once and not edited" "$(cat "$TMP/gh.log")"
[ -z "$out" ] && check "#1272 a body with the line says nothing" ok || check "#1272 a body with the line says nothing" "$out"

# Several creates: each issue the output names is checked.
body 'no line'
out="$(run "gh issue create --title a --body-file a.md $FIELDS && gh issue create --title b --body-file b.md $FIELDS" "$URL
https://github.com/danwright32/demo/issues/43")"
[ "$(grep -c '^issue view' "$TMP/gh.log")" -ge 2 ] && check "#1272 every issue a command files is read" ok || check "#1272 every issue a command files is read" "$(cat "$TMP/gh.log")"

# An issue named in the output that was not filed just now (a view of an old one) is never edited.
body 'no line'
out="$(GH_CREATED=2020-01-01T00:00:00Z run "gh issue create --title t --body-file b.md $FIELDS && gh issue view 7" "$URL")"
[ "$(edits)" = 0 ] && check "#1272 an issue not filed just now is never edited" ok || check "#1272 an issue not filed just now is never edited" "$(cat "$TMP/gh.log")"

# A body GitHub cannot give back, and an edit GitHub refuses, are said with the reason, never as done.
body 'no line'
out="$(GH_VIEW_FAILS=1 run "${shapes[1]}" "$URL")"
case "$out" in *'could not read'*'502'*) check "#1272 a body that cannot be read is said, with why" ok ;; *) check "#1272 a body that cannot be read is said, with why" "$out" ;; esac
[ "$(edits)" = 0 ] && check "#1272 nothing is edited when the body cannot be read" ok || check "#1272 nothing is edited when the body cannot be read" "$(cat "$TMP/gh.log")"
body 'no line'
out="$(GH_EDIT_FAILS=1 run "${shapes[1]}" "$URL")"
case "$out" in *'could not add'*'403'*"$LINE"*) check "#1272 a refused edit is said, with the line to add" ok ;; *) check "#1272 a refused edit is said, with the line to add" "$out" ;; esac
case "$out" in *'added the line'*) check "#1272 a refused edit is never said as added" "$out" ;; *) check "#1272 a refused edit is never said as added" ok ;; esac

# An edit gh accepts that did not land is caught by reading the body back, never said as added.
body 'no line'
out="$(GH_EDIT_IGNORED=1 run "${shapes[1]}" "$URL")"
case "$out" in *'did not find it'*"$LINE"*) check "#1272 an edit that did not land is said, from reading the body back" ok ;; *) check "#1272 an edit that did not land is said, from reading the body back" "$out" ;; esac
case "$out" in *'added the line'*) check "#1272 an edit that did not land is never said as added" "$out" ;; *) check "#1272 an edit that did not land is never said as added" ok ;; esac

# Output that names no issue: a create that failed says nothing; one that succeeded with its output
# sent elsewhere is said as unchecked, never as checked.
out="$(run "${shapes[1]}" "could not create issue: HTTP 422" 1)"
[ -z "$out" ] && [ "$(calls)" = 0 ] && check "#1272 a failed create says nothing and asks GitHub nothing" ok || check "#1272 a failed create says nothing and asks GitHub nothing" "$out $(cat "$TMP/gh.log")"
out="$(run "gh issue create --title t --body-file b.md $FIELDS > out.txt" "")"
case "$out" in *'named no issue'*"$LINE"*) check "#1272 a create whose output names no issue is said as unchecked" ok ;; *) check "#1272 a create whose output names no issue is said as unchecked" "$out" ;; esac

# Nothing to do: a command filing no issue, and a create outside any Claude session.
out="$(run "gh issue view 42" "$URL")"
[ -z "$out" ] && [ "$(calls)" = 0 ] && check "#1272 a command filing no issue is left alone" ok || check "#1272 a command filing no issue is left alone" "$out"
out="$(run "echo gh issue create is how" "$URL")"
[ -z "$out" ] && [ "$(calls)" = 0 ] && check "#1272 a create only mentioned is left alone" ok || check "#1272 a create only mentioned is left alone" "$out"
body 'no line'
out="$(SESSION_ID='' run "${shapes[0]}" "$URL")"
[ -z "$out" ] && [ "$(calls)" = 0 ] && check "#1272 outside a session nothing is required or asked" ok || check "#1272 outside a session nothing is required or asked" "$out"

# Wired: a PostToolUse hook on Bash in the settings the payload installs.
. "$DIR/lib/settings-file.sh"
SETTINGS="$(hook_settings_file "$DIR/..")"
python3 - "$SETTINGS" <<'PY' && check "#1272 wired as a PostToolUse Bash hook" ok || check "#1272 wired as a PostToolUse Bash hook" "not in $SETTINGS"
import json, sys
d = json.load(open(sys.argv[1]))
ok = any(m.get("matcher") == "Bash" and any("check-filed-issue-session.sh" in h.get("command", "") for h in m.get("hooks", []))
         for m in d["hooks"].get("PostToolUse", []))
sys.exit(0 if ok else 1)
PY

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
