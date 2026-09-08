#!/usr/bin/env bash
# Tests for how a hook payload's command is read, and therefore for whether a
# push is seen as a push at all (claude-config#97).
#
# A newline is a command separator in shell, exactly like a semicolon. Every
# parse_payload flattened it to a SPACE, and ps_is_git_push then split the
# command on && || ; and | and asked whether each segment STARTS with git push.
# A push written on its own line was glued onto the previous segment, so it
# started with whatever that segment started with, and the gate exited 0 without
# looking at anything. Not refused, not warned: unseen, which is indistinguishable
# from a push that was judged and allowed (L98, L184).
#
# That is the shape a heredoc commit message forces, because the heredoc has to
# close before the next command can start, so it is the commonest shape here
# rather than an exotic one.
#
# The functions under test are taken out of the real files rather than restated,
# so this cannot pass against a copy that has drifted.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/lib/push-scope.sh"
GATE="$DIR/require-tests-before-push.sh"

pass=0
fail=0
check() { # check <description> <result>   ("ok" passes, anything else is the failure text)
  if [[ "$2" == "ok" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $1 ($2)"
  fi
}

# shellcheck source=lib/push-scope.sh
. "$LIB" || { echo "FAIL: cannot source $LIB"; exit 1; }

# The whole chain a hook runs: a JSON payload in, a verdict on whether this is a
# push out. Asked this way rather than of ps_is_git_push alone, because the
# defect lived in the step BEFORE it and a test of the splitter on its own would
# have passed throughout (L3).
payload_for() { # payload_for <command text> [cwd]
  python3 -c '
import json, sys
print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}, "cwd": sys.argv[2]}))' \
    "$1" "${2:-}"
}

seen_as_push() { # seen_as_push <command text>
  local parsed cmd
  parsed="$(ps_parse_payload "$(payload_for "$1")" segmented)" || return 2
  cmd="${parsed%%$'\x1f'*}"
  ps_is_git_push "$cmd"
}

want_push()    { if seen_as_push "$1"; then check "$2" ok; else check "$2" "not seen as a push"; fi; }
want_notpush() { if seen_as_push "$1"; then check "$2" "seen as a push"; else check "$2" ok; fi; }

# The shape that was invisible: a heredoc commit message, then the push on the
# next line, because the heredoc cannot be followed by && on the same line.
want_push "$(printf 'git add -A && git commit -q -F - <<%sMSG%s\nsome message\nMSG\ngit push -u origin branch' "'" "'")" \
  "#97 a push on the line after a heredoc commit is seen"
want_push "$(printf 'git add -A && git commit -q -m "x"\ngit push')" \
  "#97 a push on its own line after a commit is seen"
want_push "$(printf 'echo one\necho two\ngit push --force-with-lease')" \
  "#97 a push on the last of several lines is seen"

# The shapes that already worked must keep working.
want_push 'git push' \
  "#97 a bare push is still seen"
want_push 'git add -A && git commit -m "x" && git push' \
  "#97 a push joined with && is still seen"
want_push 'cd /tmp/x; git push origin main' \
  "#97 a push after a semicolon is still seen"

# And it must not start seeing pushes that are not there, or every gate fires on
# every command and they all get switched off (L36).
want_notpush 'git status' \
  "#97 an unrelated command is not a push"
want_notpush "$(printf 'git add -A\ngit commit -m "mentions git push in the message"')" \
  "#97 a push named inside an argument is not a push"
want_notpush "$(printf 'echo one\necho two')" \
  "#97 several lines with no push in them are not a push"

# A heredoc BODY line that begins with the words is deliberately accepted as a
# push. It is the safe direction to be wrong in: the cost is a gate running when
# it need not, against a gate not running when it must, which is what shipped.
want_push "$(printf 'git commit -F - <<%sMSG%s\ngit push is what this message talks about\nMSG' "'" "'")" \
  "#97 a body line that reads like a push is judged, not ignored"

# ---------------------------------------------------------------------------
# One definition, two modes (claude-config#102). Six hooks each had their own copy
# of this, three flattening a newline and three not, which is how the defect above
# came to live in exactly the three that guard a push.
# ---------------------------------------------------------------------------
two_line="$(printf 'echo one\necho two')"
seg="$(ps_parse_payload "$(payload_for "$two_line" /tmp/somewhere)" segmented)"
raw="$(ps_parse_payload "$(payload_for "$two_line" /tmp/somewhere)" raw)"
seg_cmd="${seg%%$'\x1f'*}"; seg_cwd="${seg#*$'\x1f'}"
raw_cmd="${raw%%$'\x1f'*}"; raw_cwd="${raw#*$'\x1f'}"
[ "$seg_cmd" = "echo one; echo two" ] \
  && check "segmented mode turns a newline into a separator" ok \
  || check "segmented mode turns a newline into a separator" "got [$seg_cmd]"
[ "$raw_cmd" = "$two_line" ] \
  && check "raw mode leaves the command exactly as typed" ok \
  || check "raw mode leaves the command exactly as typed" "got [$raw_cmd]"
# Both modes carry the working directory, so every caller reads one shape. Losing it
# is not visible in the command half, and the gate uses it to find the repository at
# all: without it the whole hook exits silently.
[ "$seg_cwd" = "/tmp/somewhere" ] && [ "$raw_cwd" = "/tmp/somewhere" ] \
  && check "both modes carry the working directory" ok \
  || check "both modes carry the working directory" "segmented=[$seg_cwd] raw=[$raw_cwd]"
ps_parse_payload "$(payload_for "echo hi")" sideways >/dev/null 2>&1
[ "$?" -eq 2 ] \
  && check "an unknown mode is refused rather than guessed at" ok \
  || check "an unknown mode is refused rather than guessed at" "it answered anyway"
bad_json="$(ps_parse_payload 'not json at all' segmented 2>/dev/null)"; bad_rc=$?
[ "$bad_rc" -ne 0 ] || [ -z "$bad_json" ] \
  && check "a payload that does not parse does not answer with a command" ok \
  || check "a payload that does not parse does not answer with a command" "rc=$bad_rc out=[$bad_json]"

# And nothing may keep a private copy. Derived from the files rather than from a list
# of the hooks somebody remembered, because a copy added later is exempt from exactly
# the check meant to catch it (L96).
own_copies="$(grep -l '^parse_payload() {' "$DIR"/*.sh 2>/dev/null | tr '\n' ' ')"
case "$own_copies" in *[![:space:]]*) own_copies_found=1 ;; *) own_copies_found=0 ;; esac
[ "$own_copies_found" -eq 0 ] \
  && check "no hook keeps its own copy of the payload reader" ok \
  || check "no hook keeps its own copy of the payload reader" "still defined in: $own_copies"
users="$(grep -l 'ps_parse_payload' "$DIR"/*.sh 2>/dev/null | grep -c . || true)"
[ "${users:-0}" -ge 6 ] \
  && check "and the hooks that read one go through the library" ok \
  || check "and the hooks that read one go through the library" "only $users use it"

# ---------------------------------------------------------------------------
# End to end, through the whole hook against a real repository, because
# classifying the command correctly is only half of it: the verdict is what
# ships (L3). Two payloads carrying the SAME work, one joined with && and one
# split across lines, must reach the same verdict. Measured on the old code the
# first exits 2 and the second exits 0, which is the defect.
# ---------------------------------------------------------------------------
E2E="$(mktemp -d)"
trap 'rm -rf "$E2E"' EXIT
(
  cd "$E2E" || exit 1
  git init -q .
  git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  mkdir -p src
  printf 'print("one")\n' > src/thing.py
  git add -A
  git -c user.email=t@t -c user.name=t commit -q -m seed
  git init -q --bare "$E2E/remote.git"
  git remote add origin "$E2E/remote.git"
  git push -q -u origin HEAD 2>/dev/null
  printf 'print("two")\n' >> src/thing.py
) >/dev/null 2>&1

e2e_verdict() { # e2e_verdict <command text> -> prints the hook's exit code
  local rc=0
  python3 -c '
import json, sys
print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}, "cwd": sys.argv[2]}))'     "$1" "$E2E" | bash "$GATE" >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}

_p="git push"
e2e_amp="$(e2e_verdict "git add -A && git commit -q -m x && $_p origin HEAD")"
e2e_nl="$(e2e_verdict "$(printf 'git add -A && git commit -q -m x\n%s origin HEAD' "$_p")")"
[ "$e2e_amp" = "2" ] \
  && check "#97 the gate refuses an untested change written on one line" ok \
  || check "#97 the gate refuses an untested change written on one line" "exit=$e2e_amp"
[ "$e2e_nl" = "2" ] \
  && check "#97 and refuses the same change with the push on its own line" ok \
  || check "#97 and refuses the same change with the push on its own line" "exit=$e2e_nl"

# --- ps_base_ref (claude-config#339): the ref a push is judged AGAINST. Three push gates need the
#     same answer and it used to be written out inside one of them, so a second gate would have
#     been a second copy, and two answers to "what is this push compared with" drift invisibly.
BR="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-baseref.XXXXXXXX")"
case "${BR%/}" in ''|/|"${HOME%/}") echo "refusing: throwaway came back as '$BR'" >&2; exit 2 ;; esac
trap 'rm -rf "$BR"' EXIT
git init -q "$BR/r" 2>/dev/null
( cd "$BR/r" && printf 'x\n' > f && git add f && git -c user.email=p@l -c user.name=p commit -qm seed ) >/dev/null 2>&1

# With no upstream and no remote at all, it falls through to the local names it knows.
got="$( cd "$BR/r" && ps_base_ref || true )"
[ "$got" = "main" ] || [ "$got" = "master" ] \
  && check "ps_base_ref falls back to the local default branch" ok \
  || check "ps_base_ref falls back to the local default branch" "got=$got"

# And it prefers what the remote itself says over guessing from a list of names.
( cd "$BR/r" && git branch -f origin/zeta HEAD && git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/zeta ) >/dev/null 2>&1
got2="$( cd "$BR/r" && ps_base_ref || true )"
[ "$got2" = "origin/zeta" ] \
  && check "ps_base_ref prefers the remote's own default branch" ok \
  || check "ps_base_ref prefers the remote's own default branch" "got=$got2"

# Nothing at all to compare with is a refusal, never a guess: "judge against HEAD~1" and "judge
# nothing" are different decisions and the gates do not make them the same way.
git init -q "$BR/empty" 2>/dev/null
( cd "$BR/empty" && ps_base_ref ) >/dev/null 2>&1 \
  && check "ps_base_ref refuses when there is nothing to compare with" "it returned 0" \
  || check "ps_base_ref refuses when there is nothing to compare with" ok

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
