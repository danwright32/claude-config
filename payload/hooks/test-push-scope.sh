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

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

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

# A heredoc BODY line that begins with the words is NOT a push (claude-config#532). It used to be
# accepted as one, on the reasoning that the splitter could not tell a body from a command and a
# gate running needlessly is the safer error. It was not safe: an issue whose body quoted a push was
# refused by a push gate, which then judged the wrong repository. The body is now read as the text
# it is, and the push that FOLLOWS a heredoc is still seen (the #97 case above, and the apostrophe
# case below, which is the one a plain quote tracker gets wrong).
want_notpush "$(printf 'git commit -F - <<%sMSG%s\ngit push is what this message talks about\nMSG' "'" "'")" \
  "#532 a heredoc body line that reads like a push is not a push"
want_push "$(printf 'git commit -F - <<%sMSG%s\nit isn%st balanced\nMSG\ngit push' "'" "'" "'")" \
  "#532 a push after a heredoc whose body has an apostrophe is still seen"
want_push "$(printf 'git commit -F - <<-MSG\n\tindented body\n\tMSG\ngit push' )" \
  "#532 a push after a tab stripped heredoc is still seen"
# A heredoc that never closes is not skipped: skipping to the end would hide a push that follows,
# and hiding a push is the direction that ships unjudged work.
want_push "$(printf 'cat <<MSG\nno closing line here\ngit push')" \
  "#532 an unclosed heredoc hides nothing after it"

# A push written INSIDE a quoted argument is not a push: filing this very issue was refused because
# its body quoted the reproduction (claude-config#532, L673).
want_notpush 'gh issue create --title x --body "repro: cd ~/a && git push origin main"' \
  "#532 a push quoted inside a double quoted argument is not a push"
want_notpush "gh issue create --body 'first; git push; last'" \
  "#532 a push quoted inside a single quoted argument is not a push"
want_notpush 'echo "say \"hi\" && git push"' \
  "#532 an escaped quote does not end the quoted argument early"
want_push "git commit -m 'msg with && inside' && git push" \
  "#532 a quoted separator does not hide the real push after it"
want_push 'git commit -m "it'"'"'s done" && git push' \
  "#532 an apostrophe inside double quotes does not open a quote"
# A quote that never closes is not trusted to hide anything: the crude split runs instead, and the
# gate fires on a push it cannot read cleanly, which is the direction #97 settled.
want_push 'git add "app/copy.ts && git commit -qm copy && git push' \
  "#532 an unclosed quote falls back to the split that sees the push"

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

# ---------------------------------------------------------------------------
# A lone surrogate escape (claude-config#1944). jq 1.7.1 rejects a WHOLE payload holding one, such
# as \ud800 with no low half after it, so every gate reading the payload with jq read nothing and
# six merge gates let gh pr merge through. The reader swaps each lone one for \ufffd before anything
# parses the text, the rule #1900 applied to a byte that is not UTF-8. The payloads are written as
# literal JSON text here, since that is the only place the escape exists.
# ---------------------------------------------------------------------------
lone='{"tool_name":"Bash","tool_input":{"command":"gh pr merge 5 --squash","description":"cut \ud800 here"},"cwd":"/tmp/x"}'
# Measured first, so a red below is about the reader and not about this machine's jq (L411).
if printf '%s' "$lone" | jq -e . >/dev/null 2>&1; then
  echo "SUITE-PART-UNMEASURED #1944 this machine's jq reads a lone surrogate escape, so the fault the reader exists for is not shown here"
else
  check "this machine's jq rejects a lone surrogate escape (the fault #1944 is about)" ok
fi
declare -F ps_clean_payload >/dev/null && declare -F ps_read_payload >/dev/null \
  && check "#1944 the library defines ps_clean_payload and ps_read_payload" ok \
  || check "#1944 the library defines ps_clean_payload and ps_read_payload" "missing"
lone_parsed="$(ps_parse_payload "$lone" raw 2>/dev/null)"; lone_rc=$?
[ "$lone_rc" -eq 0 ] && [ "${lone_parsed%%$'\x1f'*}" = "gh pr merge 5 --squash" ] \
  && check "#1944 ps_parse_payload reads a payload holding a lone surrogate escape" ok \
  || check "#1944 ps_parse_payload reads a payload holding a lone surrogate escape" "rc=$lone_rc out=[$lone_parsed]"
read_back="$(printf '%s' "$lone" | ps_read_payload 2>/dev/null)"
printf '%s' "$read_back" | jq -e . >/dev/null 2>&1 \
  && check "#1944 ps_read_payload hands back a payload jq parses" ok \
  || check "#1944 ps_read_payload hands back a payload jq parses" "got [$read_back]"
[ "$(printf '%s' "$read_back" | jq -r '.tool_input.description' 2>/dev/null)" = "cut $(printf '\xef\xbf\xbd') here" ] \
  && check "#1944 the lone escape becomes U+FFFD and nothing else moves" ok \
  || check "#1944 the lone escape becomes U+FFFD and nothing else moves" "got [$read_back]"

# clean_case <description> <input> <expected output>: ps_clean_payload with whichever readers PATH
# holds, so each case is run under both halves of the reader below.
clean_case() {
  local got; got="$(ps_clean_payload "$2" 2>/dev/null)"
  [ "$got" = "$3" ] && check "$1" ok || check "$1" "got [$got] want [$3]"
}
clean_cases() { # clean_cases <which reader>
  clean_case "#1944 ($1) a lone high half becomes \\ufffd" 'a\ud800b' 'a\ufffdb'
  clean_case "#1944 ($1) a lone low half becomes \\ufffd" 'a\udc00b' 'a\ufffdb'
  clean_case "#1944 ($1) a high half followed by a non low escape becomes \\ufffd, and the escape after it stays" 'a\uD83D\u0041' 'a\ufffd\u0041'
  clean_case "#1944 ($1) a whole pair stays a pair" 'a\ud83d\ude00b' 'a\ud83d\ude00b'
  clean_case "#1944 ($1) a pair in capitals stays a pair" 'a\uD83D\uDE00b' 'a\uD83D\uDE00b'
  clean_case "#1944 ($1) an escaped backslash before ud800 is text, not an escape" 'a\\ud800b' 'a\\ud800b'
  clean_case "#1944 ($1) three backslashes are an escaped one and then an escape" 'a\\\ud800b' 'a\\\ufffdb'
  clean_case "#1944 ($1) a low half after an escaped high half's text is still lone" 'a\\ud800\udc00' 'a\\ud800\ufffd'
  clean_case "#1944 ($1) two lone halves in a row are two replacements" '\udc00\ud800' '\ufffd\ufffd'
  clean_case "#1944 ($1) text with no escape at all is handed back untouched" '{"a":"b \\ c"}' '{"a":"b \\ c"}'
  # A byte that is not UTF-8 beside the escape: python3 leaves it as it was, for the next reader to
  # replace as #1900 settled, and jq reading the text raw replaces it with U+FFFD itself, which is
  # what jq parsing it would have done. Either way it is never dropped and never refused.
  local bytes want="$2"; bytes="$(printf 'x\xff\\ud800')"
  [ "$(ps_clean_payload "$bytes" | od -An -tx1 | tr -d ' \n')" = "$want" ] \
    && check "#1944 ($1) a byte that is not UTF-8 beside the escape is kept or made U+FFFD" ok \
    || check "#1944 ($1) a byte that is not UTF-8 beside the escape is kept or made U+FFFD" "got $(ps_clean_payload "$bytes" | od -An -tx1 | tr -d ' \n') want $want"
}
clean_cases "default PATH" 78ff5c7566666664
# Each reader on its own: a machine holding only jq, and one holding only python3, both still read
# the payload, so neither half may depend on the other (ps_reader_missing jq python3).
SCOPE_TOOLS="$(mktemp -d "${TMPDIR:-/tmp}/psclean.XXXXXXXX")"
mkdir -p "$SCOPE_TOOLS/jq-only" "$SCOPE_TOOLS/py-only"
for t in cat od tr; do
  ln -s "$(command -v "$t")" "$SCOPE_TOOLS/jq-only/$t"
  ln -s "$(command -v "$t")" "$SCOPE_TOOLS/py-only/$t"
done
ln -s "$(command -v jq)" "$SCOPE_TOOLS/jq-only/jq"
ln -s "$(command -v python3)" "$SCOPE_TOOLS/py-only/python3"
PATH="$SCOPE_TOOLS/jq-only" clean_cases "jq alone" 78efbfbd5c7566666664
PATH="$SCOPE_TOOLS/py-only" clean_cases "python3 alone" 78ff5c7566666664
only_jq="$(PATH="$SCOPE_TOOLS/jq-only" ps_parse_payload "$lone" raw 2>/dev/null)"
[ "${only_jq%%$'\x1f'*}" = "gh pr merge 5 --squash" ] \
  && check "#1944 with jq alone the payload holding the escape is read" ok \
  || check "#1944 with jq alone the payload holding the escape is read" "got [$only_jq]"
# A payload nothing can parse for any other reason (claude-config#1922): the gate refuses it when the
# raw text names what it judges, and lets anything else through, which is #1900's rule for a library
# that would not load. The override, read from the raw text the same way, still passes it.
unparsed(){ # unparsed <payload> -> RC and OUT, from a subshell, since the helper exits
  OUT="$( ps_unparsed_refuse "$1" demo-gate.sh SKIP_DEMO_CHECK "a push" '*push*' 2>&1 )"; RC=$?
}
unparsed '{"tool_name":"Bash","tool_input":{"command":"git push origin x"'
[ "$RC" -eq 2 ] && check "#1922 an unparseable payload naming a push is refused" ok || check "#1922 an unparseable payload naming a push is refused" "rc=$RC out=[$OUT]"
case "$OUT" in *demo-gate.sh*payload*SKIP_DEMO_CHECK=1*) check "#1922 the refusal names the gate, the payload and the override" ok ;; *) check "#1922 the refusal names the gate, the payload and the override" "out=[$OUT]" ;; esac
unparsed '{"tool_name":"Bash","tool_input":{"command":"ls -la"'
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && check "#1922 an unparseable payload naming nothing judged passes" ok || check "#1922 an unparseable payload naming nothing judged passes" "rc=$RC out=[$OUT]"
unparsed '{"tool_name":"Bash","tool_input":{"command":"SKIP_DEMO_CHECK=1 git push origin x"'
[ "$RC" -eq 0 ] && check "#1922 the override still passes an unparseable payload" ok || check "#1922 the override still passes an unparseable payload" "rc=$RC out=[$OUT]"
OUT="$( ps_unparsed_refuse '{"x"' demo-gate.sh - "a merge" '*merge*' '*Merge*' 2>&1 )"; RC=$?
[ "$RC" -eq 0 ] && check "#1922 with no override and no judged word it passes" ok || check "#1922 with no override and no judged word it passes" "rc=$RC"
OUT="$( ps_unparsed_refuse '{"gh pr Merge"' demo-gate.sh - "a merge" '*merge*' '*Merge*' 2>&1 )"; RC=$?
[ "$RC" -eq 2 ] && case "$OUT" in *OVERRIDE*|*=1*) false ;; *) true ;; esac \
  && check "#1922 any one of the words is enough, and a gate with no override offers none" ok \
  || check "#1922 any one of the words is enough, and a gate with no override offers none" "rc=$RC out=[$OUT]"

# JSON that parses but is not shaped like a call (claude-config#2057). ps_payload_unread gives one
# answer whichever reader it has: unreadable for a payload that is not an object, an input that is
# not an object, or the judged field there and not text; readable for text, an absent field, or no
# input at all. ps_payload_text joins a list of words into the command they make, and decodes an
# input sent as one JSON string, so the refusal finds a push in either.
for u in '[{"tool_input":{"command":"ls"}}]|0' '{"tool_input":"{\"command\": \"ls\"}"}|0' \
         '{"tool_input":{"command":["ls","-la"]}}|0' '{"tool_input":{"command":{"a":1}}}|0' \
         '{"tool_input":{"command":"ls"}}|1' '{"tool_input":{}}|1' '{"tool_name":"Bash"}|1' \
         '{"tool_input":{"message":["a"]}}|1' 'not json|0'; do
  for up in "$SCOPE_TOOLS/jq-only" "$SCOPE_TOOLS/py-only"; do
    PATH="$up" ps_payload_unread "${u%|*}" command; urc=$?
    [ "$urc" = "${u##*|}" ] && check "#2057 ps_payload_unread on ${u%|*} with ${up##*/}" ok \
      || check "#2057 ps_payload_unread on ${u%|*} with ${up##*/}" "got $urc, want ${u##*|}"
  done
done
PATH="$SCOPE_TOOLS/py-only" ps_payload_unread '{"tool_input":{"message":["a"]}}' message
[ "$?" -eq 0 ] && check "#2057 ps_payload_unread judges the field it is given" ok || check "#2057 ps_payload_unread judges the field it is given" "message as a list read as text"
for tp in "$SCOPE_TOOLS/jq-only" "$SCOPE_TOOLS/py-only"; do
  unparsed_text="$(PATH="$tp" ps_payload_text '{"tool_input":{"command":["git","push","origin","x"]}}')"
  case "$unparsed_text" in *"git push origin x"*) check "#2057 a list of words reads as the command they make with ${tp##*/}" ok ;; *) check "#2057 a list of words reads as the command they make with ${tp##*/}" "got [$unparsed_text]" ;; esac
  unparsed_text="$(PATH="$tp" ps_payload_text '{"tool_input":"{\"command\": \"git push origin x\"}"}')"
  case "$unparsed_text" in *$'\n'"git push origin x"*) check "#2057 an input sent as one JSON string is decoded with ${tp##*/}" ok ;; *) check "#2057 an input sent as one JSON string is decoded with ${tp##*/}" "got [$unparsed_text]" ;; esac
done
OUT="$( ps_unparsed_refuse '{"tool_input":{"command":["git","push","origin","x"]}}' demo-gate.sh - "a push" '*git push*' 2>&1 )"; RC=$?
[ "$RC" -eq 2 ] && check "#2057 a push sent as a list of words is refused by the shared refusal" ok || check "#2057 a push sent as a list of words is refused by the shared refusal" "rc=$RC out=[$OUT]"
OUT="$( ps_unparsed_refuse '' demo-gate.sh - "a push" '*git push*' 2>&1 )"; RC=$?
[ "$RC" -eq 0 ] && check "#2057 an empty payload names nothing and passes (#1922)" ok || check "#2057 an empty payload names nothing and passes (#1922)" "rc=$RC out=[$OUT]"

# A big payload carrying many escaped backslashes and many lone escapes is read quickly by either
# half: the cleaning runs only when the text could hold one, and then once over the whole text.
big="$(python3 -c 'import json; print(json.dumps({"tool_input": {"command": "echo x", "content": "a\\\\b \ud800 " * 20000}}))')"
for big_path in "$PATH" "$SCOPE_TOOLS/jq-only" "$SCOPE_TOOLS/py-only"; do
  t0=$SECONDS
  big_out="$(PATH="$big_path" ps_parse_payload "$big" raw 2>/dev/null)"
  [ "${big_out%%$'\x1f'*}" = "echo x" ] && [ $((SECONDS - t0)) -le 5 ] \
    && check "#1944 ($big_path) a payload of 20,000 escaped backslashes and 20,000 lone escapes is read within 5 seconds" ok \
    || check "#1944 ($big_path) a payload of 20,000 escaped backslashes and 20,000 lone escapes is read within 5 seconds" "took $((SECONDS - t0))s, got [${big_out:0:80}]"
done
rm -rf "$SCOPE_TOOLS"

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
# The gate records every push it reaches (claude-config#1075); these are not real pushes.
export PUSH_GATE_LEDGER_DIR="$E2E/ledger"
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
# The shell runs the substitutions in the body of a heredoc whose end marker is unquoted, so a push
# there is judged (claude-config#2053); a quoted marker keeps the body text, which pushes nothing.
e2e_hd="$(e2e_verdict $'git add -A && git commit -q -m x\ncat <<EOF\n$('"$_p"$' origin HEAD)\nEOF')"
[ "$e2e_hd" = "2" ] \
  && check "#2053 the gate refuses the same change pushed in an unquoted heredoc body's substitution" ok \
  || check "#2053 the gate refuses the same change pushed in an unquoted heredoc body's substitution" "exit=$e2e_hd"
e2e_hdq="$(e2e_verdict $'cat <<\'EOF\'\n$('"$_p"$' origin HEAD)\nEOF')"
[ "$e2e_hdq" = "0" ] \
  && check "#2053 control: the same in a quoted heredoc body is text, and passes" ok \
  || check "#2053 control: the same in a quoted heredoc body is text, and passes" "exit=$e2e_hdq"

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

# A LONG COMMAND, read under pipefail (claude-config#403). The four questions below piped the
# command into a quiet grep, which leaves on its first match. With the match near the start of a
# command longer than a pipe buffer, the writer was killed holding the rest, and under the pipefail
# every hook sourcing this library sets, the pipeline reported that death: the override or the
# commit it had just found read as absent (L183). A heredoc commit message is exactly this shape.
# This suite runs under pipefail itself, so it asks in the same conditions the hooks do.
#
# The CONTROL is the same command short: every answer must be yes there too, so a failure below is
# the size and not a pattern that never matched (L159).
#
# INSIDE A BOUND (claude-config#3111). ps_add_scope came to walk the one reading of the command for
# the paths a commit names, and ps__read took a trailing newline off three fields of every record
# by pattern removal. Only the last field holds one. On the other two nothing matched, so bash 3.2
# tried every position and measured the rest of the string at each, and the cost grew with the
# square of the command: 2 seconds at 79 KB, 5 at 159 KB, 19 at 319 KB, and the 1.6 MB command here
# held this suite until it was stopped. The words of a commit had the same fault where a message is
# glued to its option (--message=...), in the trim that takes a closing bracket off a word. A
# reading that never returns is a hook that times out, and what the gate would have said is never
# said (L98).
#
# So what walks the reading is asked in a shell of its own, under the same pipefail and under a
# bound, and a return of the fault fails here rather than holding the suite to its wall clock. The
# bounds are settings, sized from what each question was measured to take on the personal MacBook
# on 2026-11-16, with room for a loaded machine (L290). What a push sends and what a command writes
# took 9 seconds on the 1.6 MB command and get 60, where the fault kept both past 60. What a commit
# takes took 37 to 54 seconds, 28 of them the reading of the adds (ps__read_adds), which this
# change does not touch, and gets 240, where the fault kept it past 240.
# shellcheck source=lib/bounded-run.sh
. "$DIR/lib/bounded-run.sh" || { echo "FAIL: cannot source $DIR/lib/bounded-run.sh"; exit 1; }
LONG_BOUND=60
LONG_BOUND_ADDS=240
# shellcheck disable=SC2016  # the child shell expands these, not this one
LONG_ASK='set -uo pipefail; . "$1" || exit 9; cmd="$(cat "$2")"; "$3" "$cmd" "$4" | tr "\n" "|"'
long_within() { # long_within <seconds> <function> <command> <expected answer, lines joined by |> <description>
  printf '%s' "$3" > "$BR/long-cmd.txt"
  bounded_run "$1" bash -c "$LONG_ASK" long "$LIB" "$BR/long-cmd.txt" "$2" "$BR/r"
  if [ "$BOUNDED_RC" = 0 ] && [ "${BOUNDED_OUT%|}" = "$4" ]; then check "$5" ok
  else check "$5" "exit $BOUNDED_RC inside ${1}s over ${#3} bytes, answer [${BOUNDED_OUT:0:60}]"; fi
}
LONG_TAIL="$(awk 'BEGIN{for(i=0;i<40000;i++) print "filler line of a long heredoc body " i}')"
for size in short long; do
  body=""; [ "$size" = long ] && body="$LONG_TAIL"
  long_cmd="SKIP_TEST_CHECK=1 git add a.txt && git commit -a -m \"\$(cat <<'EOF'
subject
$body
EOF
)\" && git push"
  ps_has_override "$long_cmd" SKIP_TEST_CHECK \
    && check "a $size command still carries its override" ok \
    || check "a $size command still carries its override" "read as absent over ${#long_cmd} bytes"
  ps_commit_in_chain "$long_cmd" \
    && check "a $size command still has its commit seen" ok \
    || check "a $size command still has its commit seen" "read as absent over ${#long_cmd} bytes"
  # The whole answer, asked in a shell of its own under the same pipefail and inside a bound: see
  # long_within, above.
  long_within "$LONG_BOUND_ADDS" ps_add_scope "$long_cmd" "TRACKED|a.txt" \
    "a $size command still has its add and its -a seen, inside the bound (#403, #3111)"
  # What a push gate asks of a commit and a push in one command (claude-config#3111, #3112, #3113),
  # each with something to say, so a question that came back early with nothing does not pass.
  long_msg="\$(cat <<'EOF'
subject
$body
EOF
)"
  # TRACKED, not PATHS: an option holding an a is read as commit -a, which reads more (see
  # ps__commit_stages_all).
  long_within "$LONG_BOUND_ADDS" ps_add_scope "git commit --message=\"$long_msg\" a.txt && git push" "TRACKED|a.txt" \
    "#3111 a $size message glued to its option is no path, and the path after it is read inside the bound"
  long_within "$LONG_BOUND" ps_unread_write "cp b.txt a.txt && git add a.txt && git commit -m \"$long_msg\" && git push" "cp" \
    "#3113 a $size command is asked what it writes before it stages inside the bound"
  long_within "$LONG_BOUND" ps_unread_push_source "git commit -m \"$long_msg\" && git push origin nosuch" "unresolved nosuch" \
    "#3112 a $size command is asked what its push sends inside the bound"
done

# The trim itself: what closes a subshell or ends the command comes off the end of a word, the same
# answer as the pattern removal it stands in for, at any length.
for w in 'a.txt' 'a.txt)' 'a.txt;' 'a.txt}' ')' 'a}b)c' '' 'a b)c' '(a)'; do
  PS__WORD="not set"
  if declare -F ps__word_end >/dev/null; then ps__word_end "$w"; fi
  [ "$PS__WORD" = "${w%%[)\};]*}" ] \
    && check "#3111 the trim of [$w] is the pattern removal's answer" ok \
    || check "#3111 the trim of [$w] is the pattern removal's answer" "got [$PS__WORD]"
done
# shellcheck disable=SC2016  # the child shell expands these, not this one
LONG_TRIM='. "$1" || exit 9; w="$(cat "$2")"
ps__word_end "$w)"; printf "%s|" "${#PS__WORD}"
ps__word_end "$w;tail)"; printf "%s|" "${#PS__WORD}"
ps__word_end ");$w"; printf "%s|" "${#PS__WORD}"
ps__word_end "$w"; printf "%s" "${#PS__WORD}"'
printf '%s' "$LONG_TAIL" > "$BR/long-word.txt"
bounded_run "$LONG_BOUND" bash -c "$LONG_TRIM" long "$LIB" "$BR/long-word.txt"
[ "$BOUNDED_RC" = 0 ] && [ "$BOUNDED_OUT" = "${#LONG_TAIL}|${#LONG_TAIL}|0|${#LONG_TAIL}" ] \
  && check "#3111 a word of ${#LONG_TAIL} bytes is trimmed at its first closing mark inside the bound" ok \
  || check "#3111 a word of ${#LONG_TAIL} bytes is trimmed at its first closing mark inside the bound" "exit $BOUNDED_RC, lengths [${BOUNDED_OUT:0:60}]"

# ---------------------------------------------------------------------------
# Every ps_ function is defined exactly once (claude-config#440). ps_base_ref was written twice and
# bash kept the second, so the first and its comment read as live while nothing ran them, and the
# next edit to one would not have reached the other (L29, L30). Derived from the file, so a
# function added later is covered without anybody listing it (L96).
# ---------------------------------------------------------------------------
dup_defs="$(grep -Eo '^ps_[A-Za-z0-9_]+\(\)' "$LIB" | sort | uniq -d | tr '\n' ' ')"
def_count="$(grep -Ec '^ps_[A-Za-z0-9_]+\(\)' "$LIB")"
[ "${def_count:-0}" -ge 8 ] \
  && check "the define once check can see the library's functions" ok \
  || check "the define once check can see the library's functions" "found only $def_count definitions"
case "$dup_defs" in
  *[![:space:]]*) check "#440 every ps_ function is defined exactly once" "defined more than once: $dup_defs" ;;
  *) check "#440 every ps_ function is defined exactly once" ok ;;
esac

# ---------------------------------------------------------------------------
# ps_repo_dir reads a cd written inside a subshell or a group (claude-config#439). Its pattern
# wanted whitespace or a separator before the cd, so `(cd repo && git push)` fell through to the
# SESSION's directory and the gate judged, and refused, a repository the command never touched
# (L11). Each case sets the session directory to a DIFFERENT real repository, so a fall through is
# visible as the wrong answer rather than as no answer.
# ---------------------------------------------------------------------------
RD="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-repodir.XXXXXXXX")"
case "${RD%/}" in ''|/|"${HOME%/}") echo "refusing: throwaway came back as '$RD'" >&2; exit 2 ;; esac
git init -q "$RD/target" 2>/dev/null
git init -q "$RD/session" 2>/dev/null
mkdir -p "$RD/with space"
git init -q "$RD/with space/repo" 2>/dev/null
T="$RD/target"; S="$RD/session"

want_repo() { # want_repo <command> <expected dir> <description>
  local got
  got="$(ps_repo_dir "$1" "$S" || true)"
  [ "$got" = "$2" ] && check "$3" ok || check "$3" "resolved to [$got]"
}
want_repo "cd $T && git push" "$T" \
  "#439 control: a plain cd before the push is still read"
want_repo "(cd $T && git push)" "$T" \
  "#439 a cd inside a subshell names the repo"
want_repo "( cd $T && git push )" "$T" \
  "#439 a subshell with spaces inside its parentheses names the repo"
want_repo "{ cd $T; git push; }" "$T" \
  "#439 a cd inside a brace group names the repo"
want_repo "out=\$(cd $T && git push 2>&1); echo \"\$out\"" "$T" \
  "#439 a cd inside a command substitution names the repo"
want_repo "echo \"(cd $T && git push)\" && git push" "$S" \
  "#439 a subshell cd written inside a quoted string is not a cd"
want_repo "git commit -m 'then cd $T' && git push" "$S" \
  "#439 a cd written inside a single quoted message is not a cd"
want_repo "cd \"$RD/with space/repo\" && git push" "$RD/with space/repo" \
  "#439 a quoted path with a space in it is read whole"
# The commonest shape of all: a heredoc commit message whose body has an apostrophe in it, which
# leaves an unbalanced quote for any tokenizer that reads to the end (segmented, as a hook sees it).
want_repo "cd $T && git commit -q -F - <<'MSG'; it isn't balanced; MSG; git push" "$T" \
  "#439 a cd before a heredoc body with an apostrophe is still read"
want_repo "git push" "$S" \
  "#439 with no cd at all the session directory is used"

# A cd that IS named but cannot be read must refuse, never become the session directory
# (claude-config#532). The tokenizer does not expand a tilde, so `cd ~/repo` came back as the
# literal `~/repo`, failed the directory test, and the gate judged the SESSION's repository with
# full confidence: it quoted another project's docs back at a push that carried none of them.
# HOME is swapped and restored in THIS shell, not a subshell, which would discard the count.
REAL_HOME="$HOME"; HOME="$RD"
want_repo "cd ~/target && git push" "$T" \
  "#532 a tilde path is expanded against HOME"
HOME="$REAL_HOME"
got="$(ps_cd_target "cd ~/target && git push")"
[ "$got" = "$HOME/target" ] && check "#532 ps_cd_target expands a leading tilde" ok \
  || check "#532 ps_cd_target expands a leading tilde" "got [$got]"
me="$(id -un)"; my_home="$(python3 -c 'import pwd,os; print(pwd.getpwuid(os.getuid()).pw_dir)')"
got="$(ps_cd_target "cd ~$me/nowhere && git push")"
[ "$got" = "$my_home/nowhere" ] && check "#532 ps_cd_target expands a ~user tilde" ok \
  || check "#532 ps_cd_target expands a ~user tilde" "got [$got]"
got="$(ps_cd_target "cd a~b && git push")"
[ "$got" = "a~b" ] && check "#532 a tilde that does not lead the path is left alone" ok \
  || check "#532 a tilde that does not lead the path is left alone" "got [$got]"

refuses() { # refuses <command> <description>
  local got rc
  got="$(ps_repo_dir "$1" "$S" 2>"$RD/refuse.err")"; rc=$?
  if [ "$rc" -ne 0 ] && [ -z "$got" ] && grep -q 'could not' "$RD/refuse.err"; then check "$2" ok
  else check "$2" "rc=$rc resolved to [$got], said [$(cat "$RD/refuse.err")]"; fi
}
refuses "cd $RD/no-such-dir && git push" \
  "#532 a cd to a missing directory refuses rather than judging the session repo"
refuses "cd \$SOMEWHERE && git push" \
  "#532 a cd to an unexpanded variable refuses rather than judging the session repo"
mkdir -p "$RD/plain-dir"
refuses "cd $RD/plain-dir && git push" \
  "#532 a cd to a directory that is not a repository refuses"
refuses "git -C $RD/no-such-dir push" \
  "#532 a git -C naming a missing directory refuses"
# A RELATIVE cd is relative to the session directory, not to wherever the hook runs, so refusing
# unreadable targets must not start refusing the ordinary relative form.
got="$(ps_repo_dir "cd target && git push" "$RD" 2>/dev/null)"
[ "$got" = "$RD/target" ] && check "#532 a relative cd resolves against the session directory" ok \
  || check "#532 a relative cd resolves against the session directory" "got [$got]"
got="$(ps_repo_dir "git -C target push" "$RD" 2>/dev/null)"
[ "$got" = "$RD/target" ] && check "#532 a relative git -C resolves against the session directory" ok \
  || check "#532 a relative git -C resolves against the session directory" "got [$got]"

# A QUOTED -C path, and one holding spaces, is read the way the shell reads it (claude-config#589).
# On 2026-09-29 an Ovation subagent pushed with `git -C "<worktree path>" push`; the pattern took the
# opening quote as part of the path, nothing resolved, and every global push gate stood down.
SP="$RD/with space/wt"
mkdir -p "$RD/with space"
git init -q "$SP" 2>/dev/null
for c in "git -C \"$SP\" push" \
         "git -C '$SP' push origin HEAD" \
         "rtk git -C \"$SP\" push" \
         "git -c core.quotepath=false -C \"$SP\" push" \
         "GIT_TRACE=0 git -C \"$SP\" push -u origin feat"; do
  got="$(ps_repo_dir "$c" "$S" 2>"$RD/quoted.err")"; rc=$?
  [ "$rc" -eq 0 ] && [ "$got" = "$SP" ] && check "#589 a quoted -C path with a space resolves: $c" ok \
    || check "#589 a quoted -C path with a space resolves: $c" "rc=$rc got [$got] said [$(cat "$RD/quoted.err")]"
done
# ...and before any of that, the push has to be SEEN as a push. The segment reader split on
# whitespace, so the skip after -C landed on the second half of the quoted path, read it as the
# subcommand, and every gate stood down at its first question (found by the lessons review of #778).
want_push "git -C \"$SP\" push" "#589 a push with a quoted -C path holding a space is seen"
want_push "git -C '$SP' push origin HEAD" "#589 a push with a single quoted -C path holding a space is seen"
want_push "git -c core.quotepath=false -C \"$SP\" push" "#589 a push with an option before a quoted -C path is seen"
want_push "rtk git -C \"$SP\" push" "#589 an rtk push with a quoted -C path is seen"
# The same word reader answers the pull request question, so a quoted assignment holding a space
# in front of `gh pr create` is still a creation (found by the lessons review of #778).
if ps_is_gh_pr_create 'GH_TOKEN="a b" gh pr create --fill'; then check "#589 a pr create after a quoted assignment with a space is seen" ok
else check "#589 a pr create after a quoted assignment with a space is seen" "not seen"; fi
if ps_is_gh_pr_create 'echo "gh pr create --fill"'; then check "#589 a pr create inside a quoted argument is still not a creation" "seen"
else check "#589 a pr create inside a quoted argument is still not a creation" ok; fi
# gh takes the subcommand's flags in front of it, and env or sudo can stand in front of gh or git
# (claude-config#1188): each is the same creation, push or commit.
for c in 'gh -R o/x pr create --fill' 'gh pr -R o/x create --fill' 'gh --repo=o/x pr create' \
         'rtk gh -R o/x pr create' 'env GH_TOKEN=x gh pr --repo o/x create' 'sudo -u dan gh -Ro/x pr create'; do
  if ps_is_gh_pr_create "$c"; then check "#1188 a pr create is seen: $c" ok; else check "#1188 a pr create is seen: $c" "not seen"; fi
done
# gh pr new is gh's other name for gh pr create (claude-config#2411): read by the one reading of gh's
# words (lib/shell-words.py gh_path), never by looking for the text create first.
for c in 'gh pr new --fill' 'gh -R o/x pr new --fill' 'rtk gh pr new --title t --body b' "sh -c 'gh pr new --fill'"; do
  if ps_is_gh_pr_create "$c"; then check "#2411 a pr new is seen as the creation it is: $c" ok; else check "#2411 a pr new is seen as the creation it is: $c" "not seen"; fi
done
if ps_is_gh_pr_create 'echo "gh pr new --fill"'; then check "#2411 a pr new inside a quoted argument is not a creation" "seen"
else check "#2411 a pr new inside a quoted argument is not a creation" ok; fi
if ps_is_gh_pr_create 'gh --fill pr create'; then check "#1188 a flag in front that takes pr, as gh reads it, is no pr create" "seen"
else check "#1188 a flag in front that takes pr, as gh reads it, is no pr create" ok; fi
for c in "env A=1 git push" "sudo git push origin main" "env -u X sudo -E git -C \"$SP\" push"; do
  if ps_is_git_push "$c"; then check "#1188 a push behind env or sudo is seen: $c" ok; else check "#1188 a push behind env or sudo is seen: $c" "not seen"; fi
done
if ps_is_git_commit "env A=1 git commit -m x"; then check "#1188 a commit behind env is seen" ok; else check "#1188 a commit behind env is seen" "not seen"; fi
got="$(ps_git_c_target "env A=1 git -C \"$SP\" push")"
[ "$got" = "$SP" ] && check "#1188 the -C directory of a push behind env is read" ok || check "#1188 the -C directory of a push behind env is read" "got [$got]"
got="$(ps_repo_dir "git -C \"$RD/target\" push" "$S" 2>/dev/null)"
[ "$got" = "$RD/target" ] && check "#589 a quoted -C path without a space resolves" ok \
  || check "#589 a quoted -C path without a space resolves" "got [$got]"
# A -C that is only MENTIONED (in an echo, or after the subcommand) is not where the push runs.
got="$(ps_repo_dir "echo \"git -C $RD/no-such-dir push\" && git push" "$RD/target" 2>/dev/null)"
[ "$got" = "$RD/target" ] && check "#589 a -C inside a quoted argument is not read as the push's directory" ok \
  || check "#589 a -C inside a quoted argument is not read as the push's directory" "got [$got]"
refuses "git -C \"$RD/no such dir\" push" \
  "#589 a quoted -C naming a missing directory refuses"
refuses "git -C \"\$WT\" push" \
  "#589 a quoted -C naming a variable refuses rather than judging the session repo"

# Finding the repo is only half of it: the same subshell has to be seen as a push at all, or every
# gate exits before it asks which repo. Its segment ends `git push)`, whose subcommand read as
# `push)`, so the push was invisible, which is indistinguishable from a push judged clean (L98).
want_push "(cd /tmp/x && git push)" \
  "#439 a push inside a subshell is seen"
want_push "( cd /tmp/x && git push )" \
  "#439 a push inside a spaced subshell is seen"
want_push "{ cd /tmp/x; git push; }" \
  "#439 a push inside a brace group is seen"
want_push "(git push origin main)" \
  "#439 a subshell that is only a push is seen"
want_push "(SKIP_X=1 git push)" \
  "#439 a subshell push with an inline variable is seen"
want_notpush "git commit -m \"(git push later)\"" \
  "#439 a parenthesised push inside a message is still not a push"
want_notpush "(cd /tmp/x && git status)" \
  "#439 a subshell with no push in it is not a push"

# ---------------------------------------------------------------------------
# The cd that governs a push is the LAST one the shell runs before it, in the same shell, on ANY
# line (claude-config#1017). ps_cd_target read only the first cd it met and stopped at the first
# thing its tokenizer could not read, so a cd after a heredoc whose body held an apostrophe was
# never seen, a cd written inside a heredoc body was taken for one, a first cd beat a later one, and
# a cd inside a subshell that had already closed still counted. Each answer fell back to, or
# landed in, a repository the push never touched, and on 2026-10-09 the push gate refused a push
# from one worktree twice with another repository's findings. Every case is asked twice, as the
# command was typed (real newlines, how the merge hooks read it) and as the push hooks read it
# (each newline flattened to "; "), and the session directory is a DIFFERENT repository, so a fall
# through shows as the wrong answer rather than no answer.
# ---------------------------------------------------------------------------
O="$RD/other"; git init -q "$O" 2>/dev/null
want_repo_both() { # want_repo_both <command as typed> <expected dir> <description>
  want_repo "$1" "$2" "$3 (as typed)"
  want_repo "${1//$'\n'/; }" "$2" "$3 (as a push hook reads it)"
}
want_repo_both $'echo hi\ncd '"$T"' && git push' "$T" \
  "#1017 the issue's reproduction: a cd on the line after another command is read"
want_repo_both $'cat > /dev/null <<\'EOF\'\nit\'s a note\nEOF\ncd '"$T"' && git push' "$T" \
  "#1017 a cd after a heredoc whose body has an apostrophe is read"
want_repo_both $'cat > /dev/null <<\'EOF\'\ncd '"$O"$'\nEOF\ngit push' "$S" \
  "#1017 a cd written inside a heredoc body is not a cd"
want_repo_both $'echo a\necho b\ncd '"$T"$'\ngit push' "$T" \
  "#1017 a cd on line 3 is read"
want_repo_both $'cd '"$O"$' && git status\ncd '"$T"' && git push' "$T" \
  "#1017 of two cds before the push, the last one wins"
want_repo_both "cd $T && git push && cd $O" "$T" \
  "#1017 a cd after the push does not govern it"
want_repo_both $'(cd '"$O"$' && git status)\ngit push' "$S" \
  "#1017 a cd inside a subshell that closed before the push does not govern it"
want_repo_both "(cd $O && git status) && (cd $T && git push)" "$T" \
  "#1017 a cd inside the push's own subshell governs it, a closed sibling's does not"
want_repo_both "top=\$(cd $O && pwd); git push" "$S" \
  "#1017 a cd inside a command substitution does not govern the push after it"
want_repo_both "cd $RD && cd target && git push" "$T" \
  "#1017 a relative cd is taken from the cd before it"
want_repo_both "cd $T && cd $O && cd - && git push" "$T" \
  "#1017 cd - returns to the directory the cd before it left"
want_repo_both $'# don\'t cd '"$O"$' here\ncd '"$T"$'\ngit push' "$T" \
  "#1017 a cd named inside a comment is not a cd"
want_repo_both $'git commit -m "$(cat <<\'EOF\'\nfix: cd '"$O"$' && git push "now"\nEOF\n)"\ncd '"$T"' && git push' "$T" \
  "#1017 a cd inside a heredoc body inside a command substitution is not a cd"
want_repo_both "echo 'cd $O' && git push" "$S" \
  "#1017 control: a cd inside a quoted string is still not a cd"

# The cd is the one in force for the action the CALLER asks about, so a hook judging a commit or a
# merge passes its own question and gets the directory that one runs in.
got="$(ps_cd_target "cd $T && git commit -m x; cd $O && git push" ps_is_git_commit)"
[ "$got" = "$T" ] && check "#1017 the cd for a commit is the one before the commit" ok \
  || check "#1017 the cd for a commit is the one before the commit" "got [$got]"
got="$(ps_cd_target "cd $T && git commit -m x; cd $O && git push")"
[ "$got" = "$O" ] && check "#1017 asked about nothing in particular, the cd is the push's" ok \
  || check "#1017 asked about nothing in particular, the cd is the push's" "got [$got]"
got="$(ps_cd_target "cd $T && git status")"
[ -z "$got" ] && check "#1017 a command with no push names no directory for one" ok \
  || check "#1017 a command with no push names no directory for one" "got [$got]"
got="$(ps_repo_dir "cd $T && git add -A; cd $O && git push" "$S" ps_is_git_add)"
[ "$got" = "$T" ] && check "#1017 ps_repo_dir asked about an add reads the add's cd" ok \
  || check "#1017 ps_repo_dir asked about an add reads the add's cd" "got [$got]"
# A `git -C` counts only on the action's own command, and is taken from the cd in force for it
# (lessons review of #1017). ps_repo_dir used to take the push's -C or else the FIRST git -C anywhere
# in the command, and ask it before any cd, so an unrelated `git -C <other> status` decided which
# repository a later push was judged in.
want_repo_both "git -C $O status; cd $T && git push" "$T" \
  "#1017 a git -C on another command does not decide the push's repository"
want_repo_both "cd $RD && git -C target push" "$T" \
  "#1017 a relative git -C on the push is taken from the cd in force for it"
want_repo_both "cd $O && git -C $T push" "$T" \
  "#1017 an absolute git -C on the push wins over the cd before it"
got="$(ps_repo_dir "git -C $O commit -m x && git push" "$S" ps_is_git_commit)"
[ "$got" = "$O" ] && check "#1017 asked about a commit, the commit's own -C decides" ok \
  || check "#1017 asked about a commit, the commit's own -C decides" "got [$got]"
want_repo "git -C $O commit -m x && git push" "$S" \
  "#1017 asked about the push, a commit's -C beside it decides nothing"
want_repo_both $'cat > /dev/null <<\'EOF\'\nit\'s a note\nEOF\ngit -C '"$T"' push' "$T" \
  "#1017 a git -C push after a heredoc whose body has an apostrophe is read"

# A push written after a reserved word is a push (#1017, folded in with Dan's approval): the walker
# took `then` or `do` for the command, so `if x; then git push; fi` and a push in a loop were seen
# by no push gate at all. The words looked past are lib/shell-words.py's own RESERVED list.
want_push 'if true; then git push; fi' \
  "#1017 a push after then is seen"
want_push $'while false; do\n  git push origin feat\ndone' \
  "#1017 a push after do, on its own line in a loop, is seen"
want_push 'if [ -n x ]; then :; else git push; fi' \
  "#1017 a push after else is seen"
want_push 'if git push; then echo ok; fi' \
  "#1017 a push that is an if's condition is seen"
want_push 'if false; then :; elif git push --dry-run; then :; fi' \
  "#1017 a push that is an elif's condition is seen"
want_push '! git push' \
  "#1017 a negated push is seen"
want_notpush 'if true; then echo "git push"; fi' \
  "#1017 a push quoted after then is still not a push"
if ps_is_gh_pr_create 'if true; then gh pr create --fill; fi'; then check "#1017 a pr create after then is seen" ok
else check "#1017 a pr create after then is seen" "not seen"; fi
if ps_is_git_commit $'for f in a b; do\n  git commit -m "$f"\ndone'; then check "#1017 a commit inside a loop is seen" ok
else check "#1017 a commit inside a loop is seen" "not seen"; fi
# A command after a heredoc opener on the same line, in text that holds real newlines (how the merge
# hooks read it): the "; " there is a separator, never the line break that starts the body (lessons
# review of #1017). The flattened text the push hooks read cannot tell the two apart.
if ps_is_git_push $'cat > /dev/null <<EOF; git push\nbody line\nEOF'; then
  check "#1017 a push after a heredoc opener and ; on the same line is seen" ok
else check "#1017 a push after a heredoc opener and ; on the same line is seen" "not seen"; fi
want_repo $'cat > /dev/null <<EOF; cd '"$T"$' && git push\nbody line\nEOF' "$T" \
  "#1017 the cd after a heredoc opener and ; on the same line governs the push"
if ps_is_git_push $'cat > /dev/null <<EOF; echo hi\ngit push is only body text\nEOF'; then
  check "#1017 and the body after it is still not a push" "seen as a push"
else check "#1017 and the body after it is still not a push" ok; fi
want_repo "for r in a; do git -C $T push; done" "$T" \
  "#1017 a git -C push right after do names its -C repository"
want_repo "git -C $RD -C target push" "$T" \
  "#1017 several -C compose the way git composes them"
want_repo_both $'cd '"$T"$'\nif true; then\n  git push\nfi' "$T" \
  "#1017 the cd before an if governs the push inside it"

# ---------------------------------------------------------------------------
# EVERY action in a command is judged, not only the first (claude-config#1062). ps__action_record
# returned the first command performing the action, so in `cd A && git push; cd B && git push` the
# second push, in another repository, was judged by no gate at all. Every gate judges one repository
# per command, so ps_repo_dir now refuses a command whose actions run in more than one, by name and
# with exit 2, the answer every gate already treats as "nothing judged here", and ps_repo_dirs lists
# each distinct one for a caller that can act on several.
# ---------------------------------------------------------------------------
spans() { # spans <command> <description> [predicate]
  local got rc
  got="$(ps_repo_dir "$1" "$S" ${3:+"$3"} 2>"$RD/span.err")"; rc=$?
  if [ "$rc" -eq 2 ] && [ -z "$got" ] && grep -q 'more than one repository' "$RD/span.err" \
    && grep -qF "$T" "$RD/span.err"; then check "$2" ok
  else check "$2" "rc=$rc resolved to [$got], said [$(cat "$RD/span.err")]"; fi
}
# The exact sentence, so the list of repositories is seen whole: it was joined with a trailing
# separator, "(A, B, )" (merge time lessons review of #1072).
ps_repo_dir "cd $T && git push; cd $O && git push" "$S" >/dev/null 2>"$RD/span.err"
want_sentence="push-scope: this command runs a git push in more than one repository ($T, $O), and every gate judges one repository per command, so judging only the first would let the rest through unjudged. Nothing was judged rather than judging one of them (claude-config#1062). Run each repository's git push as a command of its own."
[ "$(cat "$RD/span.err")" = "$want_sentence" ] && check "#1062 the refusal is exactly this sentence, its list with no trailing separator" ok \
  || check "#1062 the refusal is exactly this sentence, its list with no trailing separator" "said [$(cat "$RD/span.err")]"
spans "cd $T && git push; cd $O && git push" \
  "#1062 two pushes into two repositories in one command are refused, not judged by the first"
spans "cd $T && git push && (cd $O && git push origin main)" \
  "#1062 a second push in a subshell in another repository is refused too"
spans "out=\$(cd $T && git push 2>&1); cd $O && git push" \
  "#1062 a push inside a substitution and a push in another repository are refused"
want_repo "out=\$(cd $T && git push 2>&1); echo \"\$out\"; x=\$(git -C $T push)" "$T" \
  "#1062 control: an assignment holding a push is not a second push in the session repository"
# A push whose ARGUMENT is a substitution is still a push, wherever its text turns up again: only a
# command that is no longer the action once its substitutions are taken out is a container (lessons
# review of #1062, which found the first rule dropping this push because its text held "git push").
spans "cd $T && git push origin \"\$(git branch --show-current)\"; cd $O && git push" \
  "#1062 a push with a substitution argument is still judged beside a push elsewhere"
spans "cd $O && git push origin \`git branch --show-current\`; cd $T && git push" \
  "#1062 and so is one with a backquoted argument"
spans $'cd '"$T"$' && git commit -m "$(cat <<\'EOF\'\nit\'s a message\nEOF\n)"\ncd '"$O"' && git commit -m y' \
  "#1062 a commit whose message is a heredoc substitution is still judged beside a commit elsewhere" ps_is_git_commit
want_repo "cd $T && git push origin \"\$(git branch --show-current)\"" "$T" \
  "#1062 control: one push with a substitution argument resolves to its repository"
want_repo "cd $T && git push \"\$(echo origin)\" \"\$(cd $O && git rev-parse --abbrev-ref HEAD)\"" "$T" \
  "#1062 control: a cd inside the argument's substitution does not move the push"
spans "git -C $T push; git -C $O push" \
  "#1062 two pushes naming two repositories with git -C are refused"
spans "git -C $T push; git push" \
  "#1062 a push in a named repository and one in the session repository are refused"
spans "cd $T && git commit -m x; cd $O && git commit -m y" \
  "#1062 two commits in two repositories are refused when the commit is asked about" ps_is_git_commit
spans "cd $T && git add -A; cd $O && git add -A" \
  "#1062 two adds in two repositories are refused when the add is asked about" ps_is_git_add
spans "cd $T && gh pr create --fill; cd $O && gh pr create --fill" \
  "#1062 two pull request creations in two repositories are refused" ps_is_gh_pr_create
# A second push whose directory cannot be resolved is refused too: before, the first answered.
got="$(ps_repo_dir "cd $T && git push; cd $RD/no-such-dir && git push" "$S" 2>"$RD/span.err")"; rc=$?
if [ "$rc" -eq 2 ] && [ -z "$got" ] && grep -qF "$RD/no-such-dir" "$RD/span.err"; then
  check "#1062 a second push naming a directory that cannot be resolved is refused, not passed over" ok
else check "#1062 a second push naming a directory that cannot be resolved is refused, not passed over" "rc=$rc got [$got] said [$(cat "$RD/span.err")]"; fi
# Several actions in ONE repository are still that repository: the refusal is about repositories,
# not about how many times the action appears.
want_repo "cd $T && git push; cd $T && git push origin HEAD:other" "$T" \
  "#1062 control: two pushes in the same repository resolve to it"
mkdir -p "$T/sub"
want_repo "cd $T && git push; cd $T/sub && git push" "$T" \
  "#1062 control: a second push from a subdirectory of the same repository resolves to the first"
want_repo "git push -d origin old; git push origin feat" "$S" \
  "#1062 control: two pushes in the session repository resolve to it"
got="$(ps_repo_dir "cd $T && git add a; cd $O && git push" "$S" ps_is_git_add 2>/dev/null)"
[ "$got" = "$T" ] && check "#1062 control: one add and a push elsewhere still answer for the add" ok \
  || check "#1062 control: one add and a push elsewhere still answer for the add" "got [$got]"
# The list, for a caller that can act on every repository: each distinct one, in command order.
got="$(ps_repo_dirs "cd $T && git push; cd $O && git push; cd $T && git push" "$S")"; rc=$?
[ "$rc" -eq 0 ] && [ "$got" = "$T"$'\n'"$O" ] && check "#1062 ps_repo_dirs lists each distinct repository once, in order" ok \
  || check "#1062 ps_repo_dirs lists each distinct repository once, in order" "rc=$rc got [$got]"
got="$(ps_repo_dirs "cd $T && git push" "$S")"; rc=$?
[ "$rc" -eq 0 ] && [ "$got" = "$T" ] && check "#1062 ps_repo_dirs of one push is that repository" ok \
  || check "#1062 ps_repo_dirs of one push is that repository" "rc=$rc got [$got]"
got="$(ps_repo_dirs "cd $T && git push; cd $RD/no-such-dir && git push" "$S" 2>/dev/null)"; rc=$?
[ "$rc" -eq 2 ] && [ -z "$got" ] && check "#1062 ps_repo_dirs refuses when any one directory cannot be resolved" ok \
  || check "#1062 ps_repo_dirs refuses when any one directory cannot be resolved" "rc=$rc got [$got]"

# With lib/shell-words.py missing, a command that names a directory is REFUSED by name, never judged
# in the session directory (lessons review of #1017, L490): a reader that cannot run reads no cd,
# and no cd is exactly what sends a push to the wrong repository. A command naming no directory is
# still the session's.
LONE="$RD/lone-lib"
python3 "$DIR/lib/install-hook-libs.py" "$DIR/lib" "$LONE" push-scope.sh >/dev/null \
  || check "#2204 push-scope.sh could be installed with what it sources" "the install refused"
# A copy made at run time is driven by a script written beside it and run as its own process, never
# sourced by its path: a path made at run time and sourced is one the Slack drafts gate cannot work
# out, and refuses (claude-config#2538).
printf '%s\n' '. "${BASH_SOURCE[0]%/*}/push-scope.sh" || exit 1' '"$@"' > "$LONE/drive.sh"
lone() { bash "$LONE/drive.sh" "$@"; }
got="$(lone ps_repo_dir "cd $T && git push" "$S" 2>"$RD/lone.err")"; rc=$?
if [ "$rc" -eq 2 ] && [ -z "$got" ] && grep -q "shell-words.py" "$RD/lone.err"; then
  check "#1017 with no reader beside it, a cd is refused by name rather than judged in the session" ok
else check "#1017 with no reader beside it, a cd is refused by name rather than judged in the session" "rc=$rc got [$got] said [$(cat "$RD/lone.err")]"; fi
got="$(lone ps_repo_dir "git -C $T push" "$S" 2>/dev/null)"; rc=$?
[ "$rc" -eq 2 ] && check "#1017 and so is a git -C" ok || check "#1017 and so is a git -C" "rc=$rc got [$got]"
got="$(lone ps_repo_dir "git push" "$S" 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] && [ "$got" = "$S" ] && check "#1017 a push naming no directory is still the session's" ok \
  || check "#1017 a push naming no directory is still the session's" "rc=$rc got [$got]"

# A caller asking about an action no command in the line performs, while the line names a directory,
# is refused by name rather than handed the session directory (lessons review of #1017): a hook that
# forgets to name its action would otherwise judge `cd <repo> && git commit` in the session.
got="$(ps_repo_dir "cd $T && git commit -m x" "$S" 2>"$RD/noaction.err")"; rc=$?
if [ "$rc" -eq 2 ] && [ -z "$got" ] && grep -q "none of its commands" "$RD/noaction.err"; then
  check "#1017 a cd before a command that is not the action asked about is refused, not the session's" ok
else check "#1017 a cd before a command that is not the action asked about is refused, not the session's" "rc=$rc got [$got] said [$(cat "$RD/noaction.err")]"; fi
got="$(ps_repo_dir "git status" "$S" 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] && [ "$got" = "$S" ] && check "#1017 a line naming no directory is still the session's" ok \
  || check "#1017 a line naming no directory is still the session's" "rc=$rc got [$got]"
# The add reader loads shell-words.py's list without leaving a bytecode cache beside it (#1017).
# Measured in a copy of the two files whose __pycache__ does not exist yet, never in the hooks' own
# lib/ (#2103, L411): any other importer of shell-words.py can leave a .pyc there, which this test
# cannot clear, and it decides the reading either way. A current one is read by python in place of
# writing, so a reader that lost its -B wrote nothing and passed; any one at all failed a reader
# that wrote nothing. In the copy, every file after the call is one the reader wrote.
# PYTHONDONTWRITEBYTECODE and PYTHONPYCACHEPREFIX are cleared for the call, so what is measured is
# the reader's own -B and not this shell's environment (L322). The answer is checked too: a reader
# that never loaded shell-words.py writes no bytecode either, and would pass unmeasured (L98).
PYC_LIB="$RD/pyc-lib"; mkdir -p "$PYC_LIB"
python3 "$DIR/lib/install-hook-libs.py" "$DIR/lib" "$PYC_LIB" push-scope.sh shell-words.py \
  || check "#2147 the hook helpers install into $PYC_LIB" "the install refused"
# Driven by a script beside the copy, as the lone copy above is (claude-config#2538).
printf '%s\n' '. "${BASH_SOURCE[0]%/*}/push-scope.sh" || exit 1' '"$@"' > "$PYC_LIB/drive.sh"
pyc_got="$(env -u PYTHONDONTWRITEBYTECODE -u PYTHONPYCACHEPREFIX bash "$PYC_LIB/drive.sh" ps_add_scope "bash -c 'git add a.txt b.txt && git commit -m x' && git push" | tr '\n' ' ')"
pyc_left="$(ls -A "$PYC_LIB/__pycache__" 2>/dev/null | tr '\n' ' ')"
if [ "$pyc_got" != "PATHS a.txt b.txt " ]; then
  check "#1017 reading an add leaves no shell-words bytecode beside it" "the copy's reader answered [$pyc_got], not the paths shell-words.py reads, so whether it writes bytecode was not measured"
elif [ -n "$pyc_left" ]; then
  check "#1017 reading an add leaves no shell-words bytecode beside it" "it wrote [$pyc_left]"
else check "#1017 reading an add leaves no shell-words bytecode beside it" ok; fi

# The review runner is loaded by path from three places, and each used to leave
# lib/__pycache__/ai-review-run.cpython-*.pyc in the installed, synced lib (#2353, the #1017 class):
# ai-review-placement.py's runner(), and the loader snippets in the two ai-review suites. Only the
# loaders run, never the suites (those take minutes), in a private copy of lib, never the shared one
# other suites write into (#2103, L411), with the environment's bytecode switches cleared so only the
# loader's own setting is measured (L322). The copy holds no bytecode before a run, so anything
# there afterwards was written by it.
PYC2353="$RD/pyc2353"; mkdir -p "$PYC2353/snippets"
cp -R "$DIR/lib" "$PYC2353/lib" && find "$PYC2353/lib" -name __pycache__ -type d -prune -exec rm -rf {} +
pyc2353_run() { env -u PYTHONDONTWRITEBYTECODE -u PYTHONPYCACHEPREFIX "$@"; }
# Only the runner's own bytecode counts: the probe below loads ai-review-placement.py itself.
pyc2353_left() { find "$PYC2353/lib" -name 'ai-review-run*.pyc' -print | tr '\n' ' '; }
# The probe loads the placement with bytecode off, then turns it back on, so what is measured is
# runner()'s own setting alone (#2600 requires every lib loader to start with it off).
pyc2353_ans="$(pyc2353_run python3 -c 'import importlib.util,sys
sys.dont_write_bytecode=True
s=importlib.util.spec_from_file_location("p",sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m)
sys.dont_write_bytecode=False
print(hasattr(m.runner(),"framework_line"))' "$PYC2353/lib/ai-review-placement.py" 2>&1)"
pyc2353_got="$(pyc2353_left)"
if [ "$pyc2353_ans" != "True" ]; then
  check "#2353 ai-review-placement.py's runner() leaves no bytecode in lib" "runner() did not load the review runner ([$pyc2353_ans]), so whether it writes bytecode was not measured"
elif [ -n "$pyc2353_got" ]; then
  check "#2353 ai-review-placement.py's runner() leaves no bytecode in lib" "it wrote [$pyc2353_got]"
else check "#2353 ai-review-placement.py's runner() leaves no bytecode in lib" ok; fi
rm -rf "$PYC2353/lib/__pycache__"
# Each suite's python heredoc that loads ai-review-run.py, cut off after its exec_module line, so only
# the loader runs. The count is checked against the loader lines in the suite, so a heredoc this
# extraction misses is reported rather than skipped (L98).
for pyc2353_suite in test-ai-review-start-order.sh test-ai-review-on-push.sh; do
  rm -f "$PYC2353"/snippets/*
  awk -v out="$PYC2353/snippets" '
    /<<.EOF.( \|\| true)?$/ { inb = 1; body = ""; done = 0; next }
    inb && /^EOF$/ { if (body ~ /spec_from_file_location\("ai_review_run"/) { n++; f = out "/" n ".py"; printf "%s", body > f; close(f) } inb = 0; next }
    inb && !done { body = body $0 "\n"; if ($0 ~ /exec_module\(m\)/) done = 1 }
  ' "$DIR/$pyc2353_suite"
  pyc2353_want="$(grep -c 'spec_from_file_location("ai_review_run"' "$DIR/$pyc2353_suite")"
  pyc2353_have="$(ls "$PYC2353/snippets" | wc -l | tr -d ' ')"
  if [ "$pyc2353_have" != "$pyc2353_want" ] || [ "$pyc2353_have" = 0 ]; then
    check "#2353 $pyc2353_suite's runner loaders leave no bytecode in lib" "extracted $pyc2353_have loader snippet(s) against $pyc2353_want loader line(s), so it was not measured"
    continue
  fi
  pyc2353_bad=""
  for pyc2353_snip in "$PYC2353"/snippets/*.py; do
    pyc2353_err="$(pyc2353_run python3 - "$PYC2353/lib/ai-review-run.py" < "$pyc2353_snip" 2>&1)" \
      || pyc2353_bad="$pyc2353_bad [$(basename "$pyc2353_snip") did not run: $pyc2353_err]"
  done
  pyc2353_got="$(pyc2353_left)"
  if [ -n "$pyc2353_bad" ]; then check "#2353 $pyc2353_suite's runner loaders leave no bytecode in lib" "not measured:$pyc2353_bad"
  elif [ -n "$pyc2353_got" ]; then check "#2353 $pyc2353_suite's runner loaders leave no bytecode in lib" "it wrote [$pyc2353_got]"
  else check "#2353 $pyc2353_suite's runner loaders leave no bytecode in lib" ok; fi
  rm -rf "$PYC2353/lib/__pycache__"
done

# The reader's edges, each one a way a plausible scanner gets the directory wrong.
want_repo "cd $T &>/dev/null && git push" "$T" \
  "#1017 &> is a redirect, not a cd sent to the background"
want_repo "cd $T 2>&1 && git push 2>&1 | tee /dev/null" "$T" \
  "#1017 2>&1 is a redirect, and a push piped onward keeps its cd"
want_repo "cd $O | cat; git push" "$S" \
  "#1017 a cd in a pipeline runs in a shell of its own and governs nothing after it"
want_repo "f() { echo hi; }; (( n = 1 + 2 )); cd $T && git push" "$T" \
  "#1017 a function's and an arithmetic command's parentheses are not subshells"
want_notpush 'words=(git push origin); echo "${words[@]}"' \
  "#1017 an array's parentheses hold words, not a subshell running them"
refuses "cd - && git push" \
  "#1017 cd - with no earlier cd names a directory nobody can know, so it refuses"
recs="$(ps__shell_commands $'cd '"$T"$' && git add "x\ngit push')"; rc=$?
[ "$rc" -eq 3 ] && check "#1017 a quote never closed says the reading could not be trusted" ok \
  || check "#1017 a quote never closed says the reading could not be trusted" "exit $rc"
got="$(ps_cd_target $'cd '"$T"$' && git add "x\ngit push')"
[ "$got" = "$T" ] && check "#1017 and the crude reading still finds the cd before the push" ok \
  || check "#1017 and the crude reading still finds the cd before the push" "got [$got]"
if ps_is_git_add 'git add -A' && ps_is_git_add '(cd x && rtk git add a.ts)' \
  && ! ps_is_git_add 'echo "git add -A"' && ! ps_is_git_add 'git commit -m "git add"'; then
  check "#1017 ps_is_git_add sees an add in command position and only there" ok
else check "#1017 ps_is_git_add sees an add in command position and only there" "misread"; fi

# And the second half of #1017: a push verb that sits only inside text is not a push. The quote
# reader opened a quote at an apostrophe in a comment and at the escaped quote of a $'...' string,
# never closed it, and fell back to the crude split, which reads quoted text as commands; and it
# did not know that quotes open afresh inside "$( )", so a double quote in a commit message's
# heredoc body ended the message and what followed read as a command (L673).
want_notpush $'# don\'t run this: cd /x && git push origin main\nbash t.sh' \
  "#1017 a push named in a comment with an apostrophe is not a push"
want_notpush $'printf $\'it\\\'s\\n\'; echo \'x && git push origin\'' \
  "#1017 a push inside quotes after a \$'...' string with an escaped quote is not a push"
want_notpush $'git commit -m "$(cat <<\'EOF\'\nfix: the gate read "cd /x; git push origin " as a push\nEOF\n)"' \
  "#1017 a push in double quotes inside a heredoc message inside \"\$( )\" is not a push"
want_notpush $'bash test.sh \'cd ~/a && git push origin main\' "git push -u origin feat"' \
  "#1017 push verbs inside quoted test strings are not a push"
# The pushes the shell really runs are still seen, including the forms the old reader missed.
want_push 'out=$(git push 2>&1); echo "$out"' \
  "#1017 a push inside a command substitution is seen"
want_push $'# a comment\ngit push' \
  "#1017 a push on the line after a comment is seen"
want_push 'make & git push' \
  "#1017 a push after a backgrounded command is seen"

# ---------------------------------------------------------------------------
# Where a push's range starts, in the three situations a push hook meets (claude-config#441).
# ps_merge_base alone dropped to HEAD~1 whenever the merge base was HEAD, which is right for a plain
# push with no upstream and wrong for the other two, and two hooks had each worked around it
# privately. Each situation is built for real below and asked of the helper written for it.
# ---------------------------------------------------------------------------
MB="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-mergebase.XXXXXXXX")"
case "${MB%/}" in ''|/|"${HOME%/}") echo "refusing: throwaway came back as '$MB'" >&2; exit 2 ;; esac
gc() { git -c user.email=p@l -c user.name=p "$@"; }
mb_commit() { # mb_commit <repo> <message>
  ( cd "$1" && printf '%s\n' "$2" >> f && git add f && gc commit -qm "$2" ) >/dev/null 2>&1
}
sha_of() { git -C "$1" rev-parse --verify --quiet "$2" 2>/dev/null; }

# 1. A PLAIN push with no upstream: the base falls to the local branch, which IS HEAD, so the
#    committed range is the most recent change (the case the HEAD~1 fallback was written for).
git init -q -b main "$MB/plain" 2>/dev/null
mb_commit "$MB/plain" one; mb_commit "$MB/plain" two
got="$( cd "$MB/plain" && ps_merge_base "$(ps_base_ref)" )"
[ "$got" = "$(sha_of "$MB/plain" HEAD~1)" ] \
  && check "#441 a plain push with no upstream is measured from HEAD~1" ok \
  || check "#441 a plain push with no upstream is measured from HEAD~1" "got=$got"

# 2. A command that COMMITS before it pushes, on a branch whose upstream is already HEAD. The
#    pending commit is the change, so the base is HEAD; HEAD~1 would blame this push for the last
#    commit already on the remote.
git init -q --bare "$MB/remote.git" 2>/dev/null
git init -q -b main "$MB/pend" 2>/dev/null
mb_commit "$MB/pend" one; mb_commit "$MB/pend" two
( cd "$MB/pend" && git remote add origin "$MB/remote.git" && git push -q -u origin main ) >/dev/null 2>&1
got="$( cd "$MB/pend" && ps_pending_base "$(ps_base_ref)" )"
[ -n "$got" ] && [ "$got" = "$(sha_of "$MB/pend" HEAD)" ] \
  && check "#441 a commit then push on a pushed branch is measured from HEAD" ok \
  || check "#441 a commit then push on a pushed branch is measured from HEAD" "got=$got"
# The same helper on unpushed commits still returns the fork point, not HEAD.
mb_commit "$MB/pend" three
got="$( cd "$MB/pend" && ps_pending_base "$(ps_base_ref)" )"
[ -n "$got" ] && [ "$got" = "$(sha_of "$MB/pend" HEAD~1)" ] \
  && check "#441 a commit then push with unpushed work is measured from the upstream" ok \
  || check "#441 a commit then push with unpushed work is measured from the upstream" "got=$got"

# A ONE commit repository, pushed: HEAD~1 does not exist, so the old fallback returned nothing and
# the gate skipped the very commit this command was about to make.
git init -q --bare "$MB/one.git" 2>/dev/null
git init -q -b main "$MB/one" 2>/dev/null
mb_commit "$MB/one" only
( cd "$MB/one" && git remote add origin "$MB/one.git" && git push -q -u origin main ) >/dev/null 2>&1
got="$( cd "$MB/one" && ps_pending_base "$(ps_base_ref)" )"
[ -n "$got" ] && [ "$got" = "$(sha_of "$MB/one" HEAD)" ] \
  && check "#441 a commit then push in a one commit repo is measured from HEAD" ok \
  || check "#441 a commit then push in a one commit repo is measured from HEAD" "got=[$got]"

# But when the base is only a LOCAL branch name, a merge base at HEAD says nothing about what the
# remote holds, so the pending helper keeps the plain push answer and reads the last commit too.
# Reading one commit more is the safe side for a gate; reading one fewer ships it unjudged (L93).
got="$( cd "$MB/plain" && ps_pending_base "$(ps_base_ref)" )"
[ "$got" = "$(sha_of "$MB/plain" HEAD~1)" ] \
  && check "#441 a commit then push against a local base keeps the plain push answer" ok \
  || check "#441 a commit then push against a local base keeps the plain push answer" "got=$got"

# 3. AFTER the push (a PostToolUse hook). The upstream is now HEAD, so the merge base is HEAD and
#    the old fallback reviewed one commit however many the push carried.
git init -q --bare "$MB/post.git" 2>/dev/null
git init -q -b main "$MB/post" 2>/dev/null
mb_commit "$MB/post" one
( cd "$MB/post" && git remote add origin "$MB/post.git" && git push -q -u origin main ) >/dev/null 2>&1
before="$(sha_of "$MB/post" HEAD)"
mb_commit "$MB/post" two; mb_commit "$MB/post" three; mb_commit "$MB/post" four
( cd "$MB/post" && git push -q ) >/dev/null 2>&1
got="$( cd "$MB/post" && ps_pushed_base )"
[ -n "$got" ] && [ "$got" = "$before" ] \
  && check "#441 after a three commit push the range starts at the upstream's previous tip" ok \
  || check "#441 after a three commit push the range starts at the upstream's previous tip" "got=$got want=$before"
# The control: this is exactly the situation where the plain push answer is one commit short.
got_plain="$( cd "$MB/post" && ps_merge_base "$(ps_base_ref)" )"
[ "$got_plain" != "$before" ] \
  && check "#441 control: the plain push answer really is short after a push" ok \
  || check "#441 control: the plain push answer really is short after a push" "it already matched"

# A FIRST push of a feature branch has no previous upstream tip, so the whole branch is measured
# against the remote's default branch.
( cd "$MB/post" && git checkout -q -b feat && printf 'x\n' > g && git add g && gc commit -qm g1 \
    && printf 'y\n' >> g && git add g && gc commit -qm g2 && git push -q -u origin feat ) >/dev/null 2>&1
got="$( cd "$MB/post" && ps_pushed_base )"
[ -n "$got" ] && [ "$got" = "$(sha_of "$MB/post" main)" ] \
  && check "#441 after a first push of a branch the range starts where it left main" ok \
  || check "#441 after a first push of a branch the range starts where it left main" "got=$got"

# And no hook keeps its own copy of the post push rule. ai-review-on-push.sh wrote the three steps
# out itself because the library had no entry point for them; a second copy of "what did this push
# add" drifts invisibly (L613). The reflog selector is what every copy has to read, so it is the
# needle, assembled here so this line does not match itself (L245).
reflog_sel='@{u}'; reflog_sel="${reflog_sel}@{1}"
own_pushed="$(grep -lF "$reflog_sel" "$DIR"/*.sh 2>/dev/null | grep -v '/test-' | tr '\n' ' ')"
case "$own_pushed" in
  *[![:space:]]*) check "#441 no hook keeps its own post push range" "still in: $own_pushed" ;;
  *) check "#441 no hook keeps its own post push range" ok ;;
esac

# ---------------------------------------------------------------------------
# A branch REBASED onto a newer main and force pushed (claude-config#456). Its upstream still names
# the pre rebase tip, which is no longer an ancestor of HEAD, so the merge base with it is the OLD
# fork point and every commit main gained since was judged as part of this push: the deferral gate
# refused a force push over lines another pull request had already merged (L11). When the upstream
# tip is not an ancestor of HEAD, the range starts where the branch now leaves the default branch.
# ---------------------------------------------------------------------------
git init -q --bare "$MB/rb.git" 2>/dev/null
git init -q -b main "$MB/rb" 2>/dev/null
mb_commit "$MB/rb" base
( cd "$MB/rb" && git remote add origin "$MB/rb.git" && git push -q -u origin main \
    && git checkout -q -b feat && printf 'f\n' > g && git add g && gc commit -qm feat1 \
    && git push -q -u origin feat \
    && git checkout -q main ) >/dev/null 2>&1
mb_commit "$MB/rb" main2; mb_commit "$MB/rb" main3
# The rebase commits, so it needs an identity: a runner with none stops it halfway, HEAD detached
# at main, and the cases below would measure that instead.
( cd "$MB/rb" && git push -q origin main && git checkout -q feat && gc rebase -q main ) >/dev/null 2>&1
new_main="$(sha_of "$MB/rb" main)"
old_fork="$(sha_of "$MB/rb" main~2)"
[ "$(sha_of "$MB/rb" HEAD~1)" = "$new_main" ] && [ "$(git -C "$MB/rb" symbolic-ref --quiet --short HEAD 2>/dev/null)" = "feat" ] \
  && check "#456 fixture: the branch really was rebased onto the new main" ok \
  || check "#456 fixture: the branch really was rebased onto the new main" "HEAD~1=$(sha_of "$MB/rb" HEAD~1) new main=$new_main"
# The fixture is what it claims: the upstream is behind a rewrite, not simply behind (L159).
if git -C "$MB/rb" merge-base --is-ancestor origin/feat HEAD 2>/dev/null; then
  check "#456 fixture: the upstream tip is no longer an ancestor of HEAD" "it still is"
else
  check "#456 fixture: the upstream tip is no longer an ancestor of HEAD" ok
fi
got="$( cd "$MB/rb" && ps_merge_base "$(ps_base_ref)" )"
[ -n "$got" ] && [ "$got" = "$new_main" ] \
  && check "#456 a rebased branch's plain push is measured from the new main, not the old fork" ok \
  || check "#456 a rebased branch's plain push is measured from the new main, not the old fork" "got=$got want=$new_main (old fork $old_fork)"
got="$( cd "$MB/rb" && ps_pending_base "$(ps_base_ref)" )"
[ -n "$got" ] && [ "$got" = "$new_main" ] \
  && check "#456 a rebased branch's commit then push is measured from the new main" ok \
  || check "#456 a rebased branch's commit then push is measured from the new main" "got=$got want=$new_main"
# After the force push itself, the post push helper reads the whole branch against the new main.
( cd "$MB/rb" && git push -q --force origin feat ) >/dev/null 2>&1
got="$( cd "$MB/rb" && ps_pushed_base )"
[ -n "$got" ] && [ "$got" = "$new_main" ] \
  && check "#456 after the force push the range starts at the new main" ok \
  || check "#456 after the force push the range starts at the new main" "got=$got want=$new_main"

# The control that keeps the fix narrow: a branch that DIVERGED from its upstream without being
# rebased (someone else pushed to it) is not a rewrite onto main. The newer of the two merge bases
# wins, so the range stays on the branch rather than widening back to where it left main.
git init -q --bare "$MB/dv.git" 2>/dev/null
git init -q -b main "$MB/dv" 2>/dev/null
mb_commit "$MB/dv" base
( cd "$MB/dv" && git remote add origin "$MB/dv.git" && git push -q -u origin main \
    && git checkout -q -b feat && printf 'a\n' > g && git add g && gc commit -qm f1 \
    && git push -q -u origin feat \
    && git clone -q "$MB/dv.git" "$MB/dv2" && cd "$MB/dv2" && git checkout -q feat \
    && printf 'other\n' > h && git add h && gc commit -qm theirs && git push -q origin feat \
    && cd "$MB/dv" && git fetch -q origin \
    && printf 'b\n' >> g && git add g && gc commit -qm mine ) >/dev/null 2>&1
shared="$(sha_of "$MB/dv" HEAD~1)"
got="$( cd "$MB/dv" && ps_merge_base "$(ps_base_ref)" )"
[ -n "$got" ] && [ "$got" = "$shared" ] \
  && check "#456 control: a diverged but unrebased branch keeps the upstream merge base" ok \
  || check "#456 control: a diverged but unrebased branch keeps the upstream merge base" "got=$got want=$shared"

# A repository with no commits has no range at all: every entry point answers nothing and says so
# with its status, rather than printing something a caller would diff against.
git init -q "$MB/none" 2>/dev/null
for fn in ps_merge_base ps_pending_base ps_pushed_base; do
  out="$( cd "$MB/none" && "$fn" "" 2>/dev/null )"; rc=$?
  [ -z "$out" ] && [ "$rc" -ne 0 ] \
    && check "#441 $fn refuses in a repository with no commits" ok \
    || check "#441 $fn refuses in a repository with no commits" "rc=$rc out=[$out]"
done

# ---------------------------------------------------------------------------
# ps_add_scope: what the commit in a chained command will take beyond the index
# (claude-config#442). It lived as inline python in two hooks; the cases are the ones
# test-check-style-guide.sh drives end to end, asked here of the one parser directly.
# ---------------------------------------------------------------------------
want_scope() { # want_scope <command> <expected output, lines joined by |> <description>
  local got
  got="$(ps_add_scope "$1" | tr '\n' '|' | sed 's/|$//')"
  [ "$got" = "$2" ] && check "$3" ok || check "$3" "got [$got]"
}
want_scope "git add app/copy.ts && git commit -qm copy && git push" "PATHS|app/copy.ts" \
  "#442 an add naming one file takes that path"
want_scope "git add a.ts b/c.ts && git commit -qm x && git push" "PATHS|a.ts|b/c.ts" \
  "#442 an add naming several files takes each"
want_scope "git add -A && git commit -qm copy && git push" "ALL" \
  "#442 git add -A takes everything"
want_scope "git add . && git commit -qm copy && git push" "ALL" \
  "#442 git add . takes everything"
want_scope "git add -u && git commit -qm copy && git push" "TRACKED" \
  "#442 git add -u takes tracked changes"
want_scope "git commit -qam copy && git push" "TRACKED" \
  "#442 commit -a with no add takes tracked changes"
want_scope "git commit -qm copy && git push" "INDEX" \
  "#442 a bare commit takes only the index"
want_scope "git add does-not-exist.txt && git commit -qm copy && git push" "PATHS|does-not-exist.txt" \
  "#442 a named path is reported as named, for the caller to resolve"
want_scope "git add \"app/copy.ts && git commit -qm copy && git push" "UNKNOWN" \
  "#442 a command that cannot be tokenised is UNKNOWN, never narrowed to nothing"
want_scope "git add --verbose && git commit -qm x && git push" "UNKNOWN" \
  "#442 an add that names nothing is UNKNOWN"
want_scope "rtk git -C /tmp/x add app/copy.ts && git commit -qm x && git push" "PATHS|app/copy.ts" \
  "#442 an rtk rewritten add with -C is still read"
# An add naming paths AND a commit that stages for itself with -a (claude-config#457 item 4). The
# commit takes every tracked change as well as the named paths, and reporting only the paths left
# a tracked edit nobody named unread by every gate. TRACKED, with the named paths after it, because
# a named path may be untracked and -a alone never takes one.
want_scope "git add new.ts && git commit -qam x && git push" "TRACKED|new.ts" \
  "#457 an add naming a path beside commit -a takes tracked changes AND the path"
want_scope "git add a.ts b.ts && git commit -a -m x && git push" "TRACKED|a.ts|b.ts" \
  "#457 the same with a separate -a flag and several paths"
want_scope "git add -u sub && git commit -qm x && git push" "TRACKED" \
  "#457 control: an add -u with a path and no commit -a names no untracked path"
want_scope "git add -A && git commit -qam x && git push" "ALL" \
  "#457 control: an add taking everything stays ALL beside commit -a"

# The commonest commit there is: a heredoc message whose body has an apostrophe. The whole command
# was tokenised at once, the unbalanced quote failed it, and the add's scope came back UNKNOWN, so
# every gate widened to the whole working tree on exactly this shape (claude-config#457). Each
# segment is tokenised on its own now, and a body line that is not a git add is not read as one.
want_scope "git add a.ts && git commit -q -F - <<'MSG'; it isn't balanced; MSG; git push" "PATHS|a.ts" \
  "#457 an add before a heredoc body with an apostrophe still names its path"
want_scope "git add \"a b.ts\" && git commit -qm x && git push" "PATHS|a b.ts" \
  "#457 a quoted path with a space is still one path"
want_scope "echo git add -A && git commit -qm x && git push" "INDEX" \
  "#457 an add named only as an argument is not an add"
want_scope "git commit -qm \"fix git add handling\" && git push" "INDEX" \
  "#457 an add named inside a commit message is not an add"

# ---------------------------------------------------------------------------
# ps_add_takes_all: does a git add in this command take more than the paths it names (claude-config
# #457 item 6)? check-add-scope.sh answered it with its own detector beside the shared parser; it is
# a different question from ps_add_scope's (a commit -a is not an add), so it is its own entry point
# over the same parser rather than a second parser (L342).
# ---------------------------------------------------------------------------
want_takes() { # want_takes <command> <yes|no> <description>
  local got=no
  ps_add_takes_all "$1" && got=yes
  [ "$got" = "$2" ] && check "$3" ok || check "$3" "answered $got"
}
want_takes "git add -A" yes "#457 git add -A takes everything"
want_takes "git add ." yes "#457 git add . takes everything"
want_takes "git add --all" yes "#457 git add --all takes everything"
want_takes "git add -u" yes "#457 git add -u takes every tracked change"
want_takes "git add :/" yes "#457 git add :/ takes everything"
want_takes "FOO=1 git add ." yes "#457 an inline variable before the add is skipped"
want_takes "(cd /tmp/x && git add -A)" yes "#457 an add inside a subshell is read"
want_takes "rtk git -C /tmp/x add -A" yes "#457 an rtk rewritten add with -C is read"
want_takes "git add -A && git commit -q -F - <<'MSG'; it isn't balanced; MSG" yes \
  "#457 an add taking everything before a heredoc with an apostrophe is still seen"
want_takes "git add mine.txt" no "#457 an add naming a file is scoped"
want_takes "git add -- mine.txt other.txt" no "#457 an add naming files after -- is scoped"
want_takes "git add --help" no "#457 an add naming nothing stages nothing"
want_takes "echo 'remember to git add -A next time'" no "#457 an add inside an echo is not an add"
want_takes "git commit -m 'git add -A was wrong here'" no "#457 an add inside a message is not an add"
want_takes "git commit -qam x" no "#457 a commit -a is not an add"
want_takes "git status" no "#457 an unrelated command is not an add"

# ---------------------------------------------------------------------------
# ps_pending_files: the working tree files a commit in this command takes BEYOND the index, as one
# list the hooks read rather than each turning ps_add_scope into files its own way (claude-config
# #457 items 1, 3, 5). First line EXACT, or WIDENED when the add could not be accounted for and the
# whole working tree was listed instead, which the caller must say (L98).
# ---------------------------------------------------------------------------
PF="$MB/pf"
git init -q -b main "$PF" 2>/dev/null
( cd "$PF" && printf 'a\n' > tracked.txt && mkdir -p sub && printf 's\n' > sub/t.txt \
    && git add tracked.txt sub/t.txt && gc commit -qm seed \
    && printf 'changed\n' >> tracked.txt && printf 'new\n' > named.txt && printf 'stranger\n' > stranger.txt \
    && printf 'n\n' > sub/new.txt ) >/dev/null 2>&1
want_pending() { # want_pending <command> <expected, sorted, | joined> <description>
  local got
  got="$( cd "$PF" && ps_pending_files "$1" | { IFS= read -r v; printf '%s\n' "$v"; sort; } | tr '\n' '|' | sed 's/|$//' )"
  [ "$got" = "$2" ] && check "$3" ok || check "$3" "got [$got]"
}
want_pending "git commit -qm x && git push" "EXACT" \
  "#457 a bare commit takes nothing beyond the index"
want_pending "git add named.txt && git commit -qm x && git push" "EXACT|named.txt" \
  "#457 an add naming an untracked file takes that file only"
want_pending "git add tracked.txt && git commit -qm x && git push" "EXACT|tracked.txt" \
  "#457 an add naming a tracked file takes that file only"
want_pending "git add sub && git commit -qm x && git push" "EXACT|sub/new.txt" \
  "#457 an add naming a directory takes what changed under it"
want_pending "git commit -qam x && git push" "EXACT|tracked.txt" \
  "#457 a commit -a takes tracked changes and no untracked file"
want_pending "git add named.txt && git commit -qam x && git push" "EXACT|named.txt|tracked.txt" \
  "#457 an add beside commit -a takes the named file and the tracked changes"
want_pending "git add -A && git commit -qm x && git push" "EXACT|named.txt|stranger.txt|sub/new.txt|tracked.txt" \
  "#457 git add -A takes every change"
want_pending "git add \"named.txt && git commit -qm x && git push" "WIDENED|named.txt|stranger.txt|sub/new.txt|tracked.txt" \
  "#457 an add nobody can read widens to the whole tree and says so"
want_pending "git add gone.txt && git commit -qm x && git push" "WIDENED|named.txt|stranger.txt|sub/new.txt|tracked.txt" \
  "#457 an add naming a path that is not there widens and says so"
# Paths come back relative to the repository root wherever the command runs, so a hook that went
# into a subdirectory reads the same list.
got="$( cd "$PF/sub" && ps_pending_files "git add new.txt && git commit -qm x" | tr '\n' '|' | sed 's/|$//' )"
[ "$got" = "EXACT|sub/new.txt" ] \
  && check "#457 a pending file named from a subdirectory comes back relative to the root" ok \
  || check "#457 a pending file named from a subdirectory comes back relative to the root" "got [$got]"

# And no hook keeps its own copy of the parser. Derived from the hooks on disk, not from a list of
# the two that had one, so a third copy is caught the day it is written (L96, L613).
# The pattern is written with its brackets escaped, so the line holding it does not match itself
# (L245): the text on disk here is not the text the pattern finds.
own_add_parsers="$(grep -l 'toks\[j\] != "add"' "$DIR"/*.sh 2>/dev/null | tr '\n' ' ')"
case "$own_add_parsers" in
  *[![:space:]]*) check "#442 no hook keeps its own git add scope parser" "still in: $own_add_parsers" ;;
  *) check "#442 no hook keeps its own git add scope parser" ok ;;
esac
# The other shape a private add reader takes is a regular expression for the add itself (the test
# gate's sed parser, check-add-scope.sh's detector). The needle is assembled so this line does not
# match itself (L245); the library is the one file allowed to hold it.
add_re=':space:]]'; add_re="${add_re}+add"
own_add_res="$(grep -lF "$add_re" "$DIR"/*.sh 2>/dev/null | grep -v '/test-' | tr '\n' ' ')"
case "$own_add_res" in
  *[![:space:]]*) check "#457 no hook keeps its own git add pattern" "still in: $own_add_res" ;;
  *) check "#457 no hook keeps its own git add pattern" ok ;;
esac

# No hook works out a push's range itself (claude-config#457): a merge base computed outside the
# library misses every correction made inside it, the rebase one (#456) included (L613).
mb_cmd='git merge'; mb_cmd="${mb_cmd}-base"
own_mbs="$(grep -lE "^[^#]*${mb_cmd}" "$DIR"/*.sh 2>/dev/null | grep -v '/test-' | tr '\n' ' ')"
case "$own_mbs" in
  *[![:space:]]*) check "#457 no hook computes its own merge base" "still in: $own_mbs" ;;
  *) check "#457 no hook computes its own merge base" ok ;;
esac
# And none asks for a range with no base at all, which always lands on HEAD~1 (item 2).
no_base="$(grep -lE '^[^#]*ps_(merge|pending)_base[[:space:]]*\)' "$DIR"/*.sh 2>/dev/null | grep -v '/test-' | tr '\n' ' ')"
case "$no_base" in
  *[![:space:]]*) check "#457 no hook asks for a range without a base" "still in: $no_base" ;;
  *) check "#457 no hook asks for a range without a base" ok ;;
esac

echo "push-scope: one reading of a command, whatever is asked of it (claude-config#1040)"
# ps_is_git_push asked python for the words of EVERY command in the line, so the commonest push here,
# a heredoc commit then a push, started one python per line: 44 for a commit, forty short commands
# and a push, in each of the push hooks (measured 2026-10-12, 3.7 s in ps_is_git_push alone on
# 2026-10-09). The cost is counted in python3 starts, not seconds, so the machine's load cannot move
# it (L224): a python3 on PATH that notes each start, then runs the real one.
CNT="$(mktemp -d "${TMPDIR:-/tmp}/ps-count.XXXXXXXX")"
mkdir -p "$CNT/bin"
printf '#!/bin/bash\nprintf "start\\n" >> "%s/log"\nexec "%s" "$@"\n' "$CNT" "$(command -v python3)" > "$CNT/bin/python3"
chmod +x "$CNT/bin/python3"
starts() { if [ -f "$CNT/log" ]; then wc -l < "$CNT/log" | tr -d ' '; else printf '0'; fi; }
counted() {  # counted <function> <args...>: runs it in a fresh shell, its answers on stdout
  rm -f "$CNT/log"
  PATH="$CNT/bin:$PATH" bash -c '. "$1"; shift; "$@"' _ "$LIB" "$@"
}
asks_all() {  # the questions a push hook asks of one command, in one shell, as one line of answers
  local c="$1" a="" d
  ps_is_git_push "$c" && a+="push "
  ps_is_git_commit "$c" && a+="commit "
  ps_is_git_add "$c" && a+="add "
  d="$(ps_repo_dir "$c" "$2")" && a+="dir=$d"
  printf '%s' "$a"
}
export -f asks_all
msg=""; for i in $(seq 1 400); do msg+="line $i of the message, which says don't push yet"$'\n'; done
big="git add a.txt && git commit -F - <<'EOF'"$'\n'"$msg"'EOF'
for i in $(seq 1 40); do big+=$'\n'"echo step $i"; done
big+=$'\n'"git push origin HEAD"
flat="${big//$'\n'/; }"
for form in raw flat; do
  [ "$form" = raw ] && c="$big" || c="$flat"
  got="$(counted asks_all "$c" "$T")"
  [ "$got" = "push commit add dir=$T" ] && check "#1040 the $form heredoc commit then push is still read right" ok \
    || check "#1040 the $form heredoc commit then push is still read right" "answered [$got]"
  n="$(starts)"
  [ "$n" -le 1 ] && check "#1040 four questions of the $form command start python once" ok \
    || check "#1040 four questions of the $form command start python once" "$n starts"
done
# The control on the instrument: a question that has to read starts the counted python, so a count
# of zero above cannot come from a shim nothing ran (L1).
counted ps_is_git_push "git push" >/dev/null
n="$(starts)"
[ "$n" -ge 1 ] && check "#1040 the counter sees a reading" ok || check "#1040 the counter sees a reading" "$n starts"
# The reading is kept for the command it was made from and no other: a second command one word
# different is read again and answered for itself.
got="$(PATH="$CNT/bin:$PATH" bash -c '. "$1"; ps_is_git_push "git push" && printf y; ps_is_git_push "git pull" || printf n; ps_is_git_push "git push" && printf y' _ "$LIB")"
[ "$got" = "yny" ] && check "#1040 a kept reading answers only for its own command" ok \
  || check "#1040 a kept reading answers only for its own command" "answered [$got]"
# A reader swapped underneath the shell (a test seam, a reinstall) is not answered from the old one.
got="$(bash -c '. "$1"; ps_is_git_push "cd $2 && git push" >/dev/null; PS_SHELL_WORDS=/nonexistent/shell-words.py; ps_repo_dir "cd $2 && git push" "$3"' _ "$LIB" "$T" "$S" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && check "#1040 a reading is not reused once the reader it came from is gone" ok \
  || check "#1040 a reading is not reused once the reader it came from is gone" "rc=$rc said [$got]"
rm -rf "$CNT"

rm -rf "$RD" "$MB"

echo "push-scope: the reader a gate cannot work without (claude-config#480)"

# A gate handed a payload nothing on the machine can read is handed an EMPTY command, and every
# question it then asks of an empty command answers that there is nothing here to refuse. So it
# exits 0 on exactly the command it exists to stop, with nothing said, which is the one failure
# indistinguishable from a clean run (L490, L42, L98).
#
# The question and the sentence live here, once, so no gate writes a second wording of either
# (L613). lib/merge-target.sh's mt_reader_missing is this predicate with python3 filled in.

# ANY ONE of the named tools is enough, because ps_parse_payload reads the payload with jq OR with
# python3: a machine holding either can still read a payload, and a gate that refused on jq alone
# would refuse on every Mac in this house.
if ps_reader_missing claude-config-no-such-tool-4d1; then check "a tool that is not installed reads as missing" ok
else check "a tool that is not installed reads as missing" "ps_reader_missing said it was there"; fi
if ps_reader_missing bash; then check "a tool that IS installed does not read as missing" "ps_reader_missing said bash was absent"
else check "a tool that IS installed does not read as missing" ok; fi
if ps_reader_missing claude-config-no-such-tool-4d1 bash; then
  check "one reader present is enough for both" "ps_reader_missing refused a pair holding bash"
else check "one reader present is enough for both" ok; fi

# The sentence has to NAME the reader and name a remedy that changes the state somebody is stuck
# in (L111), or it is the silence this issue exists to replace.
why="$(ps_reader_absent_why "jq is not on PATH" "this gate reads the command out of the payload with it." "jq")"
case "$why" in *jq*) check "the shared sentence names the reader" ok ;;
  *) check "the shared sentence names the reader" "said: $why" ;; esac
case "$why" in *"Install jq"*) check "the shared sentence names the remedy" ok ;;
  *) check "the shared sentence names the remedy" "said: $why" ;; esac
case "$why" in *"nothing to refuse"*) check "the shared sentence says what the silence looks like" ok ;;
  *) check "the shared sentence says what the silence looks like" "said: $why" ;; esac

# The DETECTOR's sentence (claude-config#486): the payload was legible and what could not run is
# the gate's own rule. A separate sentence rather than a reworded copy, because the two describe
# different failures and a message may claim only what its check measured (L11).
dwhy="$(ps_detector_absent_why "python3 is not on PATH" "this gate scans the diff with it." "python3")"
case "$dwhy" in *python3*) check "the detector sentence names the reader" ok ;;
  *) check "the detector sentence names the reader" "said: $dwhy" ;; esac
case "$dwhy" in *"Install python3"*) check "the detector sentence names the remedy" ok ;;
  *) check "the detector sentence names the remedy" "said: $dwhy" ;; esac
case "$dwhy" in *"finding nothing"*) check "the detector sentence says what the silence looks like" ok ;;
  *) check "the detector sentence says what the silence looks like" "said: $dwhy" ;; esac
# And it does NOT say the payload was empty, which is the other sentence's claim and would send a
# reader to look at the wrong thing (L11, L440).
case "$dwhy" in *"empty payload"*) check "the detector sentence does not claim the payload was empty" "said: $dwhy" ;;
  *) check "the detector sentence does not claim the payload was empty" ok ;; esac

# ps__read_adds is python3 only, and ps_add_takes_all compares its answer against "yes", so a
# missing interpreter answered NO: check-add-scope.sh then allowed every unscoped add on the
# machine. The library has to be able to tell the gate that the reading did not happen, which is a
# different answer from "this add names its paths".
NOPY_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-nopy.XXXXXXXX")"
NOPY="$NOPY_ROOT/bin"; mkdir -p "$NOPY"
for t in bash sh git grep sed awk tr cat cut head sort dirname basename env uname mkdir mv rm shasum wc tail printf; do
  p="$(command -v "$t" 2>/dev/null)"; [ -n "$p" ] && ln -s "$p" "$NOPY/$t" 2>/dev/null
done
# The fixture's own premise, asserted rather than assumed: a bare directory that still reaches a
# python3 would make every case below pass for the wrong reason (L159).
if PATH="$NOPY" "$NOPY/bash" -c 'command -v python3 >/dev/null 2>&1'; then
  check "the bare directory really reaches no python3" "it found one, so nothing below measures its absence"
else check "the bare directory really reaches no python3" ok; fi

nopy_lib() {  # nopy_lib <function> <args...> ; the library function with no python3 on PATH
  PATH="$NOPY" "$NOPY/bash" -c '. "$1"; shift; "$@"' _ "$LIB" "$@" 2>&1
}

if nopy_lib ps_add_scope_unreadable "git add -A && git commit -m x && git push" >/dev/null 2>&1; then
  check "an add nothing can read is reported as unread" ok
else check "an add nothing can read is reported as unread" "the library said the add had been read"; fi
# The control on the same question with python3 present: the reading happens, so there is nothing
# to report and the gate goes on to judge the add itself (L159).
if ps_add_scope_unreadable "git add -A && git commit -m x && git push"; then
  check "with python3 present the add is read" "the library still said it could not read the add"
else check "with python3 present the add is read" ok; fi
# And a command with no add at all is not something an absent reader takes anything away from, so
# it is not reported however bare the PATH is (L54, L324).
if nopy_lib ps_add_scope_unreadable "git push" >/dev/null 2>&1; then
  check "a command with no add is not blamed on the missing reader" "it was reported anyway"
else check "a command with no add is not blamed on the missing reader" ok; fi

rm -rf "$NOPY_ROOT"

# ---------------------------------------------------------------------------
# A command another program runs is judged as the same command written bare (claude-config#1478).
# Every question here read only commands in command position, so `bash -c 'git push --force'`,
# `eval`, `xargs git push`, `nohup git push` and `rtk proxy git push` were no push, commit or add to
# any gate. Each wrapper is asked about each action, and the bare form is asked beside it, so a
# wrapper that is seen only because the bare form is not seen either cannot pass (L1).
# ---------------------------------------------------------------------------
WR="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-wrapped.XXXXXXXX")"
case "${WR%/}" in ''|/|"${HOME%/}") echo "refusing: throwaway came back as '$WR'" >&2; exit 2 ;; esac
git init -q "$WR/target" 2>/dev/null
git init -q "$WR/session" 2>/dev/null
WT="$WR/target"; WS="$WR/session"
# Each wrapper with a %s where the command goes. The string wrappers hand it over single quoted.
WRAPPERS=("bash -c '%s'" "sh -c '%s'" "zsh -c '%s'" "bash -lc '%s'" "bash -e -o pipefail -c '%s'"
          "/bin/bash -c '%s'" "eval '%s'" "eval %s" "env -S '%s'" "xargs %s" "xargs -n 1 -I{} %s"
          "nohup %s" "time %s" "time -p %s" "nice -n 5 %s" "timeout 30 %s" "caffeinate -i %s"
          "env A=1 %s" "command %s" "sudo %s" "rtk proxy %s" "sudo -u dan bash -c '%s'"
          "nohup bash -c \"%s\"" "find . -maxdepth 0 -exec %s \\;" "find . -maxdepth 0 -ok %s \;" "watch -n 5 '%s'"
          "watch -x %s" "script -q /dev/null %s" "script -q -c '%s' /dev/null" "parallel %s ::: x" "parallel ::: '%s'")
wrap() { printf "$1" "$2"; }   # wrap <wrapper> <command>
asked() { if "$1" "$2"; then echo yes; else echo no; fi; }   # asked <predicate> <command>
for pair in "ps_is_git_push|git push --force origin main" "ps_is_git_commit|git commit -m x" \
            "ps_is_git_add|git add -A" "ps_is_gh_pr_create|gh pr create --fill"; do
  pred="${pair%%|*}"; bare="${pair#*|}"
  [ "$(asked "$pred" "$bare")" = yes ] && check "#1478 control: $pred sees the bare $bare" ok \
    || check "#1478 control: $pred sees the bare $bare" "the bare form was not seen"
  for w in "${WRAPPERS[@]}"; do
    c="$(wrap "$w" "$bare")"
    [ "$(asked "$pred" "$c")" = yes ] && check "#1478 $pred sees: $c" ok || check "#1478 $pred sees: $c" "not seen"
  done
done
# Where it runs: the cd in force for the wrapper, and a cd inside the string.
for w in "${WRAPPERS[@]}"; do
  c="cd $WT && $(wrap "$w" "git push")"
  got="$(ps_repo_dir "$c" "$WS" 2>/dev/null)"
  [ "$got" = "$WT" ] && check "#1478 the cd before the wrapper names the repo: $c" ok \
    || check "#1478 the cd before the wrapper names the repo: $c" "resolved to [$got]"
done
for w in "bash -c '%s'" "sh -c '%s'" "eval '%s'" "env -S '%s'" "nohup bash -c \"%s\""; do
  c="$(wrap "$w" "cd $WT && git push")"
  got="$(ps_repo_dir "$c" "$WS" 2>/dev/null)"
  [ "$got" = "$WT" ] && check "#1478 a cd inside the string names the repo: $c" ok \
    || check "#1478 a cd inside the string names the repo: $c" "resolved to [$got]"
done
got="$(ps_repo_dir "bash -c 'cd $WT' && git push" "$WS" 2>/dev/null)"
[ "$got" = "$WS" ] && check "#1478 a cd inside bash -c does not move a push after it" ok \
  || check "#1478 a cd inside bash -c does not move a push after it" "resolved to [$got]"
# The commit chained before a push, and what its adds take.
for w in "${WRAPPERS[@]}"; do
  c="$(wrap "$w" "git commit -m x") && git push"
  ps_commit_in_chain "$c" && check "#1478 a commit in the chain is seen: $c" ok \
    || check "#1478 a commit in the chain is seen: $c" "not seen"
  c="$(wrap "$w" "git add -A") && git commit -m x && git push"
  got="$(ps_add_scope "$c" | awk 'NR == 1')"
  [ "$got" = ALL ] && check "#1478 an add of everything is read: $c" ok || check "#1478 an add of everything is read: $c" "scope [$got]"
  ps_add_takes_all "$(wrap "$w" "git add -A")" && check "#1478 ps_add_takes_all: $w" ok || check "#1478 ps_add_takes_all: $w" "not seen"
done
got="$(ps_add_scope "bash -c 'git add a.txt b.txt && git commit -m x' && git push" | tr '\n' ' ')"
[ "$got" = "PATHS a.txt b.txt " ] && check "#1478 the paths an add in a string names are read" ok \
  || check "#1478 the paths an add in a string names are read" "scope [$got]"
# A wrapper whose string cannot be read is never read as no add: the gates widen and say so (L98).
got="$(ps_add_scope "CMD='git add -A'; bash -c \"\$CMD\" && git commit -m x && git push" | awk 'NR == 1')"
[ "$got" = UNKNOWN ] && check "#1478 an add in a string that cannot be read is UNKNOWN" ok \
  || check "#1478 an add in a string that cannot be read is UNKNOWN" "scope [$got]"
ps_add_takes_all "CMD='git add -A'; eval \"\$CMD\"" && check "#1478 and an unread add is taken to take everything" ok \
  || check "#1478 and an unread add is taken to take everything" "read as scoped"
# What only mentions a wrapper is still text.
for c in "echo \"bash -c 'git push'\"" "git commit -m \"eval git push\"" "grep -n 'xargs git push' notes.md" \
         "$(printf "cat <<'EOF'\nbash -c 'git push'\nEOF")"; do
  [ "$(asked ps_is_git_push "$c")" = no ] && check "#1478 control: no push in: $c" ok || check "#1478 control: no push in: $c" "seen as a push"
done
got="$(ps_add_scope "echo \"bash -c 'git add -A'\" && git commit -m x && git push" | awk 'NR == 1')"
[ "$got" = INDEX ] && check "#1478 control: an add only echoed takes nothing" ok || check "#1478 control: an add only echoed takes nothing" "scope [$got]"
# A script run by its path or sourced is unreadable (claude-config#1623), but unlike a wrapper it
# holds no records of its own: it is the command itself. So a gate whose action is that script, a
# repo's merge tool run as `./scripts/merge-when-green.sh 7`, still finds it, as it did before the
# script was reported unreadable; a wrapper around it is still a container and not a second action.
is_merge_tool() { case "$1" in *merge-when-green.sh*) return 0 ;; esac; return 1; }
for c in "./scripts/merge-when-green.sh 7" "cd $WT && scripts/merge-when-green.sh 7" "~/bin/merge-when-green.sh 7"; do
  n="$(ps__action_records "$c" is_merge_tool | tr -cd '\036' | wc -c | tr -d ' ')"
  [ "$n" = 1 ] && check "#1623 a merge tool run by its path is still one action: $c" ok \
    || check "#1623 a merge tool run by its path is still one action: $c" "found $n"
done
n="$(ps__action_records "bash -c './scripts/merge-when-green.sh 7'" is_merge_tool | tr -cd '\036' | wc -c | tr -d ' ')"
[ "$n" = 1 ] && check "#1623 inside bash -c it is one action, the wrapper none" ok \
  || check "#1623 inside bash -c it is one action, the wrapper none" "found $n"
ps_unreadable "./build.sh && git push" && [ "$PS_UNREAD_WRAPPER" = direct ] \
  && check "#1623 a script run by its path is unreadable, as a direct run" ok \
  || check "#1623 a script run by its path is unreadable, as a direct run" "wrapper [$PS_UNREAD_WRAPPER]"
ps_unreadable ". ./env.sh && git push" && [ "$PS_UNREAD_WRAPPER" = source ] \
  && check "#1623 a sourced file is unreadable, as a source" ok \
  || check "#1623 a sourced file is unreadable, as a source" "wrapper [$PS_UNREAD_WRAPPER]"
ps_unreadable "/usr/bin/git push && /opt/homebrew/bin/gh pr list" \
  && check "#1623 control: git and gh by their paths are read, not scripts" "wrapper [$PS_UNREAD_WRAPPER]" \
  || check "#1623 control: git and gh by their paths are read, not scripts" ok
[ "$(asked ps_is_git_push "/opt/homebrew/bin/git push")" = yes ] && check "#1623 control: a push by git's path is a push" ok \
  || check "#1623 control: a push by git's path is a push" "not seen"
rm -rf "$WR"

# A field ending in a separator drops the empty last argument the here string's newline made, by a
# slice rather than unset "PS_RUN_ARGS[$_last]", whose subscript the Slack drafts gate cannot follow
# (#2465). Two arguments either way, the second without the newline, and no empty third.
for f in "$(printf 'git\035push\035\035a b\037c\037')" "$(printf 'git\035push\035\035a b\037c')"; do
  r="$(bash -c '. "$1"; ps__tool_field "$2" git push ""; printf "%s|%s|%s" "${#PS_RUN_ARGS[@]}" "${PS_RUN_ARGS[0]}" "${PS_RUN_ARGS[1]}"' _ "$LIB" "$f")"
  check "#2465 a field's arguments are read whole, with no empty last one (a field of ${#f} bytes)" \
    "$([ "$r" = "2|a b|c" ] && echo ok || echo "got [$r]")"
done

echo "push-scope: a merge of main still in progress, concluded by the command that pushes (claude-config#3062)"

# ps_pending_merge_of_default answers whether the commit a command makes before it pushes would
# conclude a merge that brings the default branch's commits in, which no gate can set apart before
# that commit exists. It asks ps_commit_in_chain, the question every gate asks before folding the
# pending commit in, so it is true exactly where the gates would misread.
. "$DIR/lib/merged-main-fixture.sh"
WP="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.pendmerge.XXXXXXXX")"
PW="$(mmf_repo "$WP" pending guide/old.md $'from main\n')"
mmf_pending "$PW" guide/old.md && check "#3062 the fixture leaves a merge of main in progress" ok \
  || check "#3062 the fixture leaves a merge of main in progress" "it does not, so the cases below prove nothing"
r="$(ps_pending_merge_of_default "git commit --no-edit && git push" "$PW")"; rc=$?
[ "$rc" -eq 0 ] && [ "$r" = origin/main ] && check "#3062 a commit and push in one command concludes the merge of main" ok \
  || check "#3062 a commit and push in one command concludes the merge of main" "exit $rc, printed [$r]"
r="$(cd "$PW" && ps_pending_merge_of_default "git commit --no-edit && git push")"; rc=$?
[ "$rc" -eq 0 ] && check "#3062 the directory defaults to where it is asked" ok || check "#3062 the directory defaults to where it is asked" "exit $rc"
ps_pending_merge_of_default "git push" "$PW" >/dev/null \
  && check "#3062 a push alone does not conclude it" "said it does" || check "#3062 a push alone does not conclude it" ok
# git merge --continue concludes the same merge and makes the same commit, so it is a commit in the
# chain, for every gate and for this question (claude-config#3081). It used to be read as no commit
# at all, so no gate folded the pending merge commit in and a conflict resolution went out unread.
# Measured on git 2.51.1 with a merge in progress: --continue is the only spelling of git merge that
# concludes it. A git merge with anything else, or with nothing, is refused there ("You have not
# concluded your merge"), and --continue beside any other argument is refused too.
for c in "git merge --continue && git push" "git merge --continue; git push" "git merge --continue;git push" \
         "GIT_EDITOR=true git merge --continue && git push" "git -c core.editor=true merge --continue && git push" \
         "rtk git merge --continue && git push" "cd $PW && git merge --continue && git push origin HEAD" \
         "bash -c 'git merge --continue' && git push" "eval \"git merge --continue\" && git push" \
         "/usr/bin/git merge --continue&&git push"; do
  ps_commit_in_chain "$c" && check "#3081 concluding a merge is a commit in the chain: $c" ok \
    || check "#3081 concluding a merge is a commit in the chain: $c" "not seen"
done
# What does not conclude a merge is not one. A git merge naming a branch starts a merge: nothing of
# it is in the index when the gates run, so there is no pending commit to fold in.
for c in "git push" "git merge --abort && git push" "git merge --quit; git push" \
         "git merge --no-edit origin/main && git push" "git merge-base --is-ancestor a b && git push" \
         "git merge --continued && git push"; do
  ps_commit_in_chain "$c" && check "#3081 control: no commit in the chain: $c" "seen as a commit" \
    || check "#3081 control: no commit in the chain: $c" ok
done
r="$(ps_pending_merge_of_default "git merge --continue && git push" "$PW")"; rc=$?
[ "$rc" -eq 0 ] && [ "$r" = origin/main ] && check "#3081 git merge --continue and a push in one command concludes the merge of main" ok \
  || check "#3081 git merge --continue and a push in one command concludes the merge of main" "exit $rc, printed [$r]"
ps_pending_merge_of_default "git merge --abort && git push" "$PW" >/dev/null \
  && check "#3081 abandoning the merge and pushing does not conclude it" "said it does" \
  || check "#3081 abandoning the merge and pushing does not conclude it" ok
git -C "$PW" -c user.name=t -c user.email=t@t.t -c commit.gpgsign=false commit -q --no-edit >/dev/null 2>&1
ps_pending_merge_of_default "git commit --no-edit && git push" "$PW" >/dev/null \
  && check "#3062 once the merge is committed nothing is pending" "said it is" || check "#3062 once the merge is committed nothing is pending" ok
# A clean merge of main left in progress again, first with origin/main known (the control: it is
# pending), then with no default branch known, where nothing can say what came from main and the
# gates judge the range whole as ps_merged_apart does, so it does not answer yes.
git -C "$PW" checkout -q main >/dev/null 2>&1
printf 'again\n' > "$PW/again.txt"; git -C "$PW" add again.txt >/dev/null 2>&1
git -C "$PW" -c user.name=t -c user.email=t@t.t -c commit.gpgsign=false commit -qm again >/dev/null 2>&1
git -C "$PW" push -q origin main >/dev/null 2>&1
git -C "$PW" checkout -q feat >/dev/null 2>&1
git -C "$PW" -c user.name=t -c user.email=t@t.t merge -q --no-commit --no-ff origin/main >/dev/null 2>&1
ps_pending_merge_of_default "git commit --no-edit && git push" "$PW" >/dev/null \
  && check "#3062 control: a clean merge of main left uncommitted is pending" ok \
  || check "#3062 control: a clean merge of main left uncommitted is pending" "said it is not"
git -C "$PW" update-ref -d refs/remotes/origin/main >/dev/null 2>&1
git -C "$PW" symbolic-ref -d refs/remotes/origin/HEAD >/dev/null 2>&1
ps_pending_merge_of_default "git commit --no-edit && git push" "$PW" >/dev/null \
  && check "#3062 with no default branch known it does not answer yes" "said yes" \
  || check "#3062 with no default branch known it does not answer yes" ok
rm -rf "$WP"

echo "push-scope: a commit written straight after a bracket or a backquote (claude-config#3091)"

# ps_commit_in_chain read where a git starts from a list of characters that left out the opener of a
# subshell and of a command substitution, so `(git commit -m x) && git push` was read as no commit:
# no gate folded the pending commit in, and it went out unread. ps__git_add_in_chain has accepted
# those openers since #2203; the commit question now reads them the same way, for both spellings it
# knows (git commit, and git merge --continue since #3081). The word that ends the spelling may be
# closed the same way, `(git commit)`, or be followed by a separator with no space between.
for c in "(git commit -m x) && git push" "(git merge --continue) && git push" \
         "x=\$(git commit -m x) && git push" "x=\$(git merge --continue) && git push" \
         "echo \"\$(git commit -m x)\" && git push" "x=\`git commit -m x\` && git push" \
         "x=\`git merge --continue\` && git push" "(git commit) && git push" \
         "(rtk git commit -m x) && git push" "(/usr/bin/git commit -m x) && git push" \
         "(git -c core.editor=true merge --continue); git push" \
         "git commit;git push" "git commit&&git push" "git commit|cat; git push"; do
  ps_commit_in_chain "$c" && check "#3091 a commit after an opener is a commit in the chain: $c" ok \
    || check "#3091 a commit after an opener is a commit in the chain: $c" "not seen"
done
# What an opener starts but is no commit stays none, and the shapes read before are read still.
for c in "(git commit-graph write) && git push" "(git committed) && git push" "(git log) && git push" \
         "(legit commit -m x) && git push" "(git merge --abort) && git push" \
         "x=\$(git merge-base a b) && git push" "(git merge --continued) && git push" \
         "x=\$(git rev-parse HEAD) && git push"; do
  ps_commit_in_chain "$c" && check "#3091 control: no commit in the chain: $c" "seen as a commit" \
    || check "#3091 control: no commit in the chain: $c" ok
done
for c in "git commit -m x && git push" "(cd sub && git commit -m x) && git push" "{ git commit -m x; } && git push"; do
  ps_commit_in_chain "$c" && check "#3091 control: read before, and still: $c" ok \
    || check "#3091 control: read before, and still: $c" "not seen"
done

echo "push-scope: commits a command makes by a route no gate can read (claude-config#3092)"

# ps_unread_commit_route answers whether a command runs, before a push, a git command that puts
# commits on the branch (or stages changes for a commit later in the command) by a route other than
# the two the gates read, git commit and git merge --continue. Measured in throwaway repositories on
# git 2.51.1: each of these makes at least one commit that did not exist when a gate would have run.
# It prints the route as the refusal names it.
# A command of several lines is named on one, its line ends written out, so a FAIL line never goes on
# at the margin (test-fail-margin.sh).
route_is() { # route_is <description> <command> <the route it must print>
  local r rc name="$1: ${2//$'\n'/\\n}"
  r="$(ps_unread_commit_route "$2")"; rc=$?
  if [ "$rc" -eq 0 ] && [ "$r" = "$3" ]; then check "$name" ok
  else check "$name" "exit $rc, printed [$r], wanted [$3]"; fi
}
no_route() { # no_route <description> <command>
  local r rc name="$1: ${2//$'\n'/\\n}"
  r="$(ps_unread_commit_route "$2")"; rc=$?
  if [ "$rc" -eq 1 ] && [ -z "$r" ]; then check "$name" ok
  else check "$name" "exit $rc, printed [$r]"; fi
}
# The seven the issue names.
route_is "#3092 a route no gate reads" "git rebase --continue && git push" "git rebase --continue"
route_is "#3092 a route no gate reads" "git cherry-pick --continue && git push" "git cherry-pick --continue"
route_is "#3092 a route no gate reads" "git revert --continue && git push" "git revert --continue"
route_is "#3092 a route no gate reads" "git am --continue && git push" "git am --continue"
route_is "#3092 a route no gate reads" "git merge --no-edit side && git push" "git merge"
route_is "#3092 a route no gate reads" "git cherry-pick abc123 && git push" "git cherry-pick"
route_is "#3092 a route no gate reads" "git pull --no-edit && git push" "git pull"
# The same six commands spelled another way make commits too (measured beside the seven): a rebase
# onto a branch, a revert or an am that starts, a --skip that replays the rest, a merge that only
# fast forwards (it makes no commit, and still puts commits on the branch that were not there), and
# the forms that stage for a commit later in the command.
route_is "#3092 the same command, started rather than continued" "git rebase origin/main && git push --force-with-lease" "git rebase"
route_is "#3092 the same command, started rather than continued" "git revert --no-edit HEAD && git push" "git revert"
route_is "#3092 the same command, started rather than continued" "git am fix.patch && git push" "git am"
route_is "#3092 a skip replays the commits after it" "git rebase --skip; git push -f" "git rebase --skip"
route_is "#3092 a skip replays the commits after it" "git cherry-pick --skip && git push" "git cherry-pick --skip"
route_is "#3092 a fast forward puts commits on the branch too" "git merge --ff-only side && git push" "git merge"
route_is "#3092 a pull that rebases replays this branch's commits" "git pull --rebase && git push" "git pull"
route_is "#3092 staged for a commit later in the command" "git merge --squash side && git commit -m x && git push" "git merge"
route_is "#3092 staged for a commit later in the command" "git cherry-pick -n abc123 && git commit -m x && git push" "git cherry-pick"
route_is "#3092 staged for a commit later in the command" "git merge --no-commit side && git commit -m x && git push" "git merge"
# However the git is written, as every other question here reads one.
route_is "#3092 however the git is written" "rtk git pull && rtk git push" "git pull"
route_is "#3092 however the git is written" "git -C /tmp/x pull && git -C /tmp/x push" "git pull"
route_is "#3092 however the git is written" "GIT_EDITOR=true git rebase --continue && git push" "git rebase --continue"
route_is "#3092 however the git is written" "git -c core.editor=true rebase --continue && git push" "git rebase --continue"
route_is "#3092 however the git is written" "/usr/bin/git pull&&git push" "git pull"
route_is "#3092 however the git is written" "git pull;git push" "git pull"
route_is "#3092 however the git is written" $'git pull\ngit push' "git pull"
route_is "#3092 however the git is written" "(git rebase --continue) && git push" "git rebase --continue"
route_is "#3092 however the git is written" "bash -c 'git pull && git push'" "git pull"
route_is "#3092 however the git is written" "git fetch origin && git merge origin/main && git push origin HEAD" "git merge"
route_is "#3092 the first route is the one named" "git pull && git rebase --continue && git push" "git pull"
route_is "#3092 a route after one that makes nothing is still found" "git merge --abort; git merge side && git push" "git merge"
# What makes no commit and stages nothing is no route: measured, --abort and --quit of each. A git
# merge --continue is the commit ps_commit_in_chain reads, so the gates read it and it is not one.
for c in "git push" "git commit -m x && git push" "git add -A && git commit -m x && git push" \
         "git merge --continue && git push" "git merge --abort && git push" "git merge --quit; git push" \
         "git rebase --abort && git push" "git rebase --quit && git push" \
         "git cherry-pick --abort && git push" "git cherry-pick --quit; git push" \
         "git revert --abort && git push" "git revert --quit && git push" \
         "git am --abort && git push" "git am --quit && git push" \
         "git merge-base --is-ancestor a b && git push" "git fetch origin && git push" \
         "git log --grep=rebase && git push" "git branch -d merge && git push" \
         "git status && git push origin pull"; do
  no_route "#3092 control: no route in the command" "$c"
done
# A route nothing pushes after is not this question's: with no push, or with the push before it,
# what it makes is not carried by a push in this command.
for c in "git rebase --continue" "git pull" "git merge side" "git push && git pull" \
         "git push origin feat; git checkout main && git pull" "git push -u origin feat && git merge --no-edit side"; do
  no_route "#3092 control: nothing pushes what it makes" "$c"
done
# Words that only name a route, in a message or a heredoc body, run nothing.
no_route "#3092 control: a route named in a commit message" "git commit -m 'run git pull and then git rebase --continue' && git push"
no_route "#3092 control: a route named in a heredoc body" \
  $'git commit -F - <<\'EOF\'\nRefuse git pull && git push in one command\n\ngit rebase --continue && git push is refused too.\nEOF\ngit push'
no_route "#3092 control: a route named in an echo" "echo git pull && git push"
# With nothing to read the command, the crude cut still finds the route, so a missing reader refuses
# rather than letting the command past unread (L42).
r="$(PS_SHELL_WORDS=/nonexistent/shell-words.py; ps_unread_commit_route "git pull && git push")"; rc=$?
[ "$rc" -eq 0 ] && [ "$r" = "git pull" ] && check "#3092 with no reader the route is still found" ok \
  || check "#3092 with no reader the route is still found" "exit $rc, printed [$r]"
r="$(PS_SHELL_WORDS=/nonexistent/shell-words.py; ps_unread_commit_route "GIT_EDITOR=true git rebase --continue; git push -f")"; rc=$?
[ "$rc" -eq 0 ] && [ "$r" = "git rebase --continue" ] && check "#3092 with no reader a continued rebase is still found" ok \
  || check "#3092 with no reader a continued rebase is still found" "exit $rc, printed [$r]"
r="$(PS_SHELL_WORDS=/nonexistent/shell-words.py; ps_unread_commit_route "git merge --abort && git push")"; rc=$?
[ "$rc" -eq 1 ] && [ -z "$r" ] && check "#3092 with no reader an abandoned merge is still no route" ok \
  || check "#3092 with no reader an abandoned merge is still no route" "exit $rc, printed [$r]"

echo "push-scope: a branch moved or a commit staged by a route no gate reads (claude-config#3098)"

# ps_unread_move_or_stage answers whether a command runs, before a push, a git command that changes
# what the push sends without making a commit: one that MOVES the branch onto commits that already
# exist (or off ones a gate read), or one that changes the INDEX by a route other than git add ahead
# of a commit and a push. It prints `move` or `stage`, a space, and the route as the refusal names
# it. Each spelling below was measured first in a throwaway repository on git 2.51.1 (HEAD, the tree
# the index holds and the files compared before and after), and the controls are the spellings
# measured to change neither HEAD nor the index.
moves_or_stages() { # moves_or_stages <description> <command> <what it must print>
  local r rc name="$1: ${2//$'\n'/\\n}"
  r="$(ps_unread_move_or_stage "$2")"; rc=$?
  if [ "$rc" -eq 0 ] && [ "$r" = "$3" ]; then check "$name" ok
  else check "$name" "exit $rc, printed [$r], wanted [$3]"; fi
}
neither() { # neither <description> <command>
  local r rc name="$1: ${2//$'\n'/\\n}"
  r="$(ps_unread_move_or_stage "$2")"; rc=$?
  if [ "$rc" -eq 1 ] && [ -z "$r" ]; then check "$name" ok
  else check "$name" "exit $rc, printed [$r]"; fi
}
# The branch moves: HEAD names another commit afterwards, so the push sends commits no gate read, or
# leaves out ones a gate read as part of it.
while IFS='|' read -r c want; do
  [ -n "$c" ] || continue
  moves_or_stages "#3098 the branch is moved before the push" "$c" "move $want"
done <<'MOVES'
git checkout main && git push|git checkout
git switch main && git push|git switch
git checkout -b new origin/main && git push -u origin new|git checkout
git switch -c new side && git push -u origin new|git switch
git checkout -B feat side && git push -f|git checkout
git checkout --detach side && git push origin HEAD:refs/heads/x|git checkout
git switch --detach side && git push origin HEAD:refs/heads/x|git switch
git checkout - && git push|git checkout
git checkout --orphan fresh && git commit -m x && git push -u origin fresh|git checkout
git checkout -b new --track origin/main && git push|git checkout
git checkout --track origin/other && git push|git checkout
git checkout -f -b new && git push|git checkout
git checkout side -- && git push|git checkout
git reset --hard origin/main && git push -f|git reset
git reset --hard side && git push|git reset
git reset --soft HEAD~1 && git commit -m x && git push -f|git reset
git reset HEAD~1; git push -f|git reset
git reset --keep side && git push|git reset
git reset --hard @{u} && git push|git reset
git update-ref refs/heads/feat side && git push|git update-ref
git update-ref HEAD side && git push|git update-ref
git symbolic-ref HEAD refs/heads/side && git push|git symbolic-ref
git bisect reset && git push|git bisect
git bisect start HEAD main && git push|git bisect
git filter-branch -f --msg-filter cat HEAD~1..HEAD && git push -f|git filter-branch
git stash branch fromstash && git push -u origin fromstash|git stash branch
git rebase --abort && git push|git rebase --abort
git cherry-pick --abort && git push|git cherry-pick --abort
git revert --abort && git push|git revert --abort
git am --abort && git push|git am --abort
MOVES
# The index changes by a route other than git add, and a commit later in the command takes it: the
# gates fold in the index as it was before the command ran.
while IFS='|' read -r c want; do
  [ -n "$c" ] || continue
  moves_or_stages "#3098 staged by another route for a commit the command then pushes" "$c" "stage $want"
done <<'STAGES'
git apply --index fix.patch && git commit -m x && git push|git apply
git apply --cached fix.patch && git commit -m x && git push|git apply
git apply --3way fix.patch && git commit -m x && git push|git apply
git apply -3 fix.patch && git commit -m x && git push|git apply
git stash pop && git commit -m x && git push|git stash pop
git stash pop --index && git commit -m x && git push|git stash pop
git stash apply && git add -A && git commit -m x && git push|git stash apply
git stash; git commit --allow-empty -m x; git push|git stash
git stash push -u -m aside; git commit --allow-empty -m x; git push|git stash
git stash -k; git commit -m x; git push|git stash
git rm old.txt && git commit -m x && git push|git rm
git rm --cached old.txt && git commit -m x && git push|git rm
git mv old.txt older.txt && git commit -m x && git push|git mv
git checkout side -- notes.txt && git commit -m x && git push|git checkout
git checkout origin/main -- a.txt b.txt && git commit -m x && git push|git checkout
git checkout HEAD -- a.txt && git commit -m x && git push|git checkout
git restore --staged a.txt && git commit -m x && git push|git restore
git restore -S a.txt && git commit -m x && git push|git restore
git restore -s side -SW a.txt && git commit -m x && git push|git restore
git restore --source=side --staged a.txt && git commit -m x && git push|git restore
git reset && git add a.txt && git commit -m x && git push|git reset
git reset -q && git commit -m x && git push|git reset
git reset HEAD && git commit -m x && git push|git reset
git reset -- a.txt && git commit -m x && git push|git reset
git reset HEAD -- a.txt && git commit -m x && git push|git reset
git reset --hard && git commit --allow-empty -m x && git push|git reset
git reset --hard HEAD && git commit --allow-empty -m x && git push|git reset
git read-tree side && git commit -m x && git push|git read-tree
git update-index --add hand.txt && git commit -m x && git push|git update-index
git update-index --force-remove old.txt && git commit -m x && git push|git update-index
git update-index --chmod=+x old.txt && git commit -m x && git push|git update-index
git merge --abort && git commit -m x && git push|git merge --abort
git checkout side -- notes.txt && git merge --continue && git push|git checkout
STAGES
# A move is named ahead of a staging route, wherever each stands: it is refused whatever follows it.
moves_or_stages "#3098 a move is named ahead of a staging route" "git rm old.txt && git checkout main && git push" "move git checkout"
moves_or_stages "#3098 a move is named ahead of a staging route" "git stash && git checkout main && git commit -m x && git push" "move git checkout"
moves_or_stages "#3098 the first staging route is the one named" "git rm old.txt && git mv a b && git commit -m x && git push" "stage git rm"
moves_or_stages "#3098 a route after one that changes nothing is still found" "git checkout -b new && git reset --hard side && git push" "move git reset"
# However the git is written, as every other question here reads one.
moves_or_stages "#3098 however the git is written" "rtk git checkout main && rtk git push" "move git checkout"
moves_or_stages "#3098 however the git is written" "git -C /tmp/x reset --hard origin/main && git -C /tmp/x push -f" "move git reset"
moves_or_stages "#3098 however the git is written" "GIT_TRACE=0 git switch main && git push" "move git switch"
moves_or_stages "#3098 however the git is written" "git -c advice.detachedHead=false checkout side && git push" "move git checkout"
moves_or_stages "#3098 however the git is written" "/usr/bin/git checkout main&&git push" "move git checkout"
moves_or_stages "#3098 however the git is written" "git checkout main;git push" "move git checkout"
moves_or_stages "#3098 however the git is written" $'git checkout main\ngit push' "move git checkout"
moves_or_stages "#3098 however the git is written" "(git checkout main) && git push" "move git checkout"
moves_or_stages "#3098 however the git is written" "bash -c 'git checkout main && git push'" "move git checkout"
moves_or_stages "#3098 however the git is written" "(git stash pop) && git commit -m x && git push" "stage git stash pop"
moves_or_stages "#3098 however the git is written" "git stash pop;git commit -m x;git push" "stage git stash pop"
moves_or_stages "#3098 however the git is written" "git fetch origin && git checkout origin/main -- a.txt && git commit -m x && git push origin HEAD" "stage git checkout"
# Measured to change neither HEAD nor the index: a branch made where HEAD already is, files written
# back from the index, the forms that only look, and a sequence left where it stands.
while IFS= read -r c; do
  [ -n "$c" ] || continue
  neither "#3098 control: neither HEAD nor the index changes" "$c"
done <<'HARMLESS'
git push
git commit -m x && git push
git add -A && git commit -m x && git push
git checkout -b new && git add a.txt && git commit -m x && git push -u origin new
git checkout -q -b new && git push -u origin new
git checkout -B new && git push -u origin new
git switch -c new && git commit -am x && git push -u origin new
git switch --create new && git push -u origin new
git switch -C new && git push -u origin new
git checkout -- README.md && git commit -am x && git push
git checkout . && git commit -am x && git push
git checkout && git push
git restore README.md && git commit -am x && git push
git restore --source=side a.txt && git commit -m x && git push
git reset --soft && git commit -m x && git push
git reset --soft HEAD && git commit -m x && git push
git apply --check fix.patch && git commit -m x && git push
git apply --stat fix.patch && git commit -m x && git push
git rm -n old.txt && git commit -m x && git push
git rm --dry-run old.txt && git commit -m x && git push
git mv -n old.txt older.txt && git commit -m x && git push
git stash list && git commit -m x && git push
git stash show && git commit -m x && git push
git stash drop && git commit -m x && git push
git update-index --refresh; git commit -m x && git push
git update-index -q --refresh && git commit -m x && git push
git symbolic-ref --short HEAD && git push
git symbolic-ref -q refs/remotes/origin/HEAD; git push
git branch -f other side && git push
git branch -m renamed && git push -u origin renamed
git rebase --quit && git push
git cherry-pick --quit; git push
git am --quit && git push
git merge --quit && git commit -m x && git push
git fetch origin && git push
git log --grep=checkout && git push
git branch -d reset && git push
git status && git push origin checkout
git checkout -b new 2>&1 && git push -u origin new
git checkout -b new >/dev/null 2>&1 && git push -u origin new
git checkout -b new > out.txt && git push -u origin new
git symbolic-ref --short HEAD 2>/dev/null; git push
git symbolic-ref HEAD > branch.txt; git push
git reset --soft 2>&1; git commit -m x; git push
git update-index --refresh >/dev/null; git commit -m x && git push
git stash list | wc -l; git commit -m x && git push
x=$(git symbolic-ref --short HEAD) && git push origin "$x"
HARMLESS
# A redirection is among the words the reader hands over and is none of git's own, so a branch made
# at HEAD with its output sent away is still that, and a move with its output sent away still a move.
moves_or_stages "#3098 a redirection is not one of git's words" "git checkout main 2>&1 | tail -1; git push" "move git checkout"
moves_or_stages "#3098 a redirection is not one of git's words" "git checkout -b new origin/main >/dev/null 2>&1 && git push -u origin new" "move git checkout"
moves_or_stages "#3098 a redirection is not one of git's words" "git reset 2>/dev/null; git commit -m x; git push" "stage git reset"
moves_or_stages "#3098 a redirection is not one of git's words" "git apply --index < fix.patch && git commit -m x && git push" "stage git apply"
# A move inside a loop, a condition or a list is one too.
moves_or_stages "#3098 wherever the command stands" "for b in a b; do git checkout \$b && git push; done" "move git checkout"
moves_or_stages "#3098 wherever the command stands" "if git checkout main; then git push; fi" "move git checkout"
moves_or_stages "#3098 wherever the command stands" "git checkout main || exit 1; git push" "move git checkout"
moves_or_stages "#3098 a target worked out by another command is still a target" 'git reset --hard "$(git merge-base HEAD origin/main)" && git push -f' "move git reset"
# A file written by git apply with no --index, --cached or --3way is a file written, as by any
# program: the index is as the gates read it (measured), so this question lets it through. What a
# later git add or commit -a takes of it is the wider gap this change does not close.
neither "#3098 control: a patch applied to the files only" "git apply fix.patch && git commit -m x && git push"
# A staging route with no commit after it changes nothing the push sends: the push carries commits,
# and none was made. Nor does one that comes after the commit.
for c in "git stash pop && git push" "git stash && git push" "git rm --cached a.txt && git push" \
         "git merge --abort && git push" "git apply --index fix.patch && git push" "git reset && git push" \
         "git restore --staged a.txt; git push" "git commit -m x && git stash pop && git push" \
         "git commit -m x && git rm old.txt && git push"; do
  neither "#3098 control: nothing commits what it staged before the push" "$c"
done
# Nothing pushes after it: with no push, or with the push before it.
for c in "git checkout main" "git reset --hard origin/main" "git push && git checkout main" \
         "git push origin feat; git checkout main && git pull" "git stash pop && git commit -m x" \
         "git push -u origin feat && git rm old.txt && git commit -m x"; do
  neither "#3098 control: nothing pushes afterwards" "$c"
done
# Words that only name a route, in a message or a heredoc body, run nothing.
neither "#3098 control: a route named in a commit message" "git commit -m 'git checkout main and git reset --hard, then git push' && git push"
neither "#3098 control: a route named in a heredoc body" \
  $'git commit -F - <<\'EOF\'\nRefuse git checkout main && git push in one command\n\ngit stash pop && git commit -m x && git push is refused too.\nEOF\ngit push'
neither "#3098 control: a route named in an echo" "echo git checkout main && git push"
# The question #3092 asks is left as it was: an abandoned sequence makes no commit, so it is not one
# of ITS routes, and is this question's.
no_route "#3098 an abandoned rebase is still no commit making route" "git rebase --abort && git push"
# With nothing to read the command, the crude cut still finds the route, so a missing reader refuses
# rather than letting the command past unread (L42).
r="$(PS_SHELL_WORDS=/nonexistent/shell-words.py; ps_unread_move_or_stage "git checkout main && git push")"; rc=$?
[ "$rc" -eq 0 ] && [ "$r" = "move git checkout" ] && check "#3098 with no reader a checkout is still found" ok \
  || check "#3098 with no reader a checkout is still found" "exit $rc, printed [$r]"
r="$(PS_SHELL_WORDS=/nonexistent/shell-words.py; ps_unread_move_or_stage "git stash pop && git commit -m x; git push -f")"; rc=$?
[ "$rc" -eq 0 ] && [ "$r" = "stage git stash pop" ] && check "#3098 with no reader a staging route is still found" ok \
  || check "#3098 with no reader a staging route is still found" "exit $rc, printed [$r]"
r="$(PS_SHELL_WORDS=/nonexistent/shell-words.py; ps_unread_move_or_stage "(git reset --hard origin/main) && git push -f")"; rc=$?
[ "$rc" -eq 0 ] && [ "$r" = "move git reset" ] && check "#3098 with no reader a reset inside brackets is still found" ok \
  || check "#3098 with no reader a reset inside brackets is still found" "exit $rc, printed [$r]"
r="$(PS_SHELL_WORDS=/nonexistent/shell-words.py; ps_unread_move_or_stage "git checkout -b new && git push -u origin new")"; rc=$?
[ "$rc" -eq 1 ] && [ -z "$r" ] && check "#3098 with no reader a branch made at HEAD is still neither" ok \
  || check "#3098 with no reader a branch made at HEAD is still neither" "exit $rc, printed [$r]"
r="$(PS_SHELL_WORDS=/nonexistent/shell-words.py; ps_unread_move_or_stage "git stash pop && git push")"; rc=$?
[ "$rc" -eq 1 ] && [ -z "$r" ] && check "#3098 with no reader a staging route nothing commits is still neither" ok \
  || check "#3098 with no reader a staging route nothing commits is still neither" "exit $rc, printed [$r]"

echo "push-scope: a commit that names the paths it takes (claude-config#3111)"

# `git commit <paths>` takes those files' edits straight from the working tree, with no git add
# (measured on git 2.51.1: the commit holds the path's edit, a directory's tracked edits, and with -i
# what was staged as well; an untracked path is refused by git). ps_add_scope read only a git add
# and a commit -a, so the gates folded in the index alone and the edit went out unread. The paths
# are in the command, so they are read as an add's paths are.
want_scope "git commit notes/a.txt -m x && git push" "PATHS|notes/a.txt" \
  "#3111 a commit naming a path takes that path"
want_scope "git commit -m x -- a.txt 'b c.txt' && git push" "PATHS|a.txt|b c.txt" \
  "#3111 paths after a double dash, one of them quoted with a space"
want_scope "git commit -m x a.txt && git push" "PATHS|a.txt" \
  "#3111 a path after the message"
want_scope "git commit -qm x notes && git push" "PATHS|notes" \
  "#3111 a directory, after a cluster of short options ending in m"
want_scope "git commit -o a.txt -m x && git push" "PATHS|a.txt" "#3111 with -o"
want_scope "git commit --only a.txt -m x && git push" "PATHS|a.txt" "#3111 with --only"
want_scope "git commit -i a.txt -m x && git push" "PATHS|a.txt" "#3111 with -i"
want_scope "git commit --include a.txt -m x && git push" "PATHS|a.txt" "#3111 with --include"
want_scope "git commit . -m x && git push" "PATHS|." "#3111 the dot is a path here, never every untracked file"
want_scope "(git commit a.txt -m x) && git push" "PATHS|a.txt" "#3111 inside brackets"
want_scope "git commit -F msg.txt a.txt && git push" "PATHS|a.txt" "#3111 the message file is no path, the word after it is"
want_scope "git commit -m x a.txt 2>&1 && git push" "PATHS|a.txt" "#3111 a redirection is not a path"
want_scope "git commit a.txt -m x > out.txt && git push" "PATHS|a.txt" "#3111 nor is the file a redirection writes"
want_scope "git -C sub commit a.txt -m x && git -C sub push" "PATHS|a.txt" "#3111 behind git -C"
want_scope "rtk git commit a.txt -m x && rtk git push" "PATHS|a.txt" "#3111 behind rtk"
want_scope "git commit a.txt -m x && git commit b.txt -m y && git push" "PATHS|a.txt|b.txt" "#3111 two commits, each naming one"
want_scope "git add b.txt && git commit a.txt -m x && git push" "PATHS|b.txt|a.txt" "#3111 beside an add naming another path"
want_scope "git add a.txt && git commit a.txt -m x && git push" "PATHS|a.txt" "#3111 a path both name is listed once"
want_scope "git add -u && git commit a.txt -m x && git push" "TRACKED|a.txt" "#3111 beside git add -u"
want_scope "git commit -am x a.txt && git push" "TRACKED|a.txt" "#3111 beside commit -a"
want_scope "git add -A && git commit a.txt -m x && git push" "ALL" "#3111 beside an add that takes everything"
want_scope "git commit -Skey a.txt -m x && git push" "PATHS|a.txt" "#3111 a signing key glued to -S takes no word after it"
want_scope "git commit -uno a.txt -m x && git push" "PATHS|a.txt" "#3111 nor does a mode glued to -u"
# A list of paths in a file cannot be read from the command, so it is an add nobody can account
# for. It used to be read as commit -a, by a pattern that takes any option holding an a for one.
want_scope "git commit --pathspec-from-file=list.txt -m x && git push" "UNKNOWN" \
  "#3111 paths named in a file are UNKNOWN, never narrowed to the index"
want_scope "git commit --pathspec-from-file list.txt -m x && git push" "UNKNOWN" \
  "#3111 and so with the file as a word of its own"
# Controls: the value of an option is no path, and a commit only named is no commit.
while IFS= read -r c; do
  [ -n "$c" ] || continue
  want_scope "$c" "INDEX" "#3111 control, no path is named: $c"
done <<'NOPATHS'
git commit -m a.txt && git push
git commit -F a.txt && git push
git commit -qm 'see a.txt' && git push
git commit -mfix.txt && git push
git commit -C HEAD~1 && git push
git commit --fixup HEAD~1 && git push
git commit --file b.txt && git push
git commit --file=b.txt && git push
git commit -m x -m y && git push
git commit -t b.txt && git push
git commit -m 'git commit b.txt' && git push
echo git commit b.txt && git commit -m x && git push
git commit -m x 2>&1 && git push origin feat
NOPATHS
# The pattern that reads commit -a takes any option holding an a for one (--message, --author,
# --squash, --cleanup, --trailer, --amend), so these are read as every tracked change, as they were
# before. What matters here is that the word after each is still no path.
while IFS= read -r c; do
  [ -n "$c" ] || continue
  want_scope "$c" "TRACKED" "#3111 control, the value of an option is no path: $c"
done <<'VALUES'
git commit --message b.txt && git push
git commit --message=b.txt && git push
git commit --squash HEAD~1 && git push
git commit --author 'A B <a@b.c>' --date now -m x && git push
git commit -m x --cleanup strip --trailer 'Refs: 1' && git push
git commit --reuse-message HEAD~1 && git push
git commit --amend --no-edit && git push
VALUES
want_scope $'git commit -q -F - <<\'EOF\' && git push\nfix b.txt\nEOF' "INDEX" \
  "#3111 control, a message read from the commit's own input names no path"
want_scope 'git commit -m "$(cat <<'"'"'EOF'"'"'
fix b.txt and c.txt
EOF
)" && git push' "INDEX" "#3111 control, a heredoc message that names files names no path"
# With nothing to read the command the crude cut answers, which can only see more (L42).
got="$(PS_SHELL_WORDS=/nonexistent/shell-words.py; ps_add_scope "git commit a.txt -m x && git push" | tr '\n' '|' | sed 's/|$//')"
[ "$got" = "PATHS|a.txt" ] && check "#3111 with no reader a path a commit names is still read" ok \
  || check "#3111 with no reader a path a commit names is still read" "got [$got]"
got="$(PS_SHELL_WORDS=/nonexistent/shell-words.py; ps_add_scope "git commit -m x && git push" | tr '\n' '|' | sed 's/|$//')"
[ "$got" = "INDEX" ] && check "#3111 with no reader a bare commit still takes only the index" ok \
  || check "#3111 with no reader a bare commit still takes only the index" "got [$got]"
# And as files, in the repository ps_pending_files is asked in (tracked.txt edited, the rest untracked).
PF="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.commitpaths.XXXXXXXX")"
git init -q -b main "$PF" 2>/dev/null
( cd "$PF" && printf 'a\n' > tracked.txt && mkdir -p sub && printf 's\n' > sub/t.txt \
    && git add tracked.txt sub/t.txt && gc commit -qm seed \
    && printf 'changed\n' >> tracked.txt && printf 'changed\n' >> sub/t.txt \
    && printf 'new\n' > named.txt ) >/dev/null 2>&1
want_pending "git commit -qm x && git push" "EXACT" "#3111 control: a bare commit takes nothing beyond the index"
want_pending "git commit tracked.txt -qm x && git push" "EXACT|tracked.txt" \
  "#3111 a commit naming an edited file takes that file"
want_pending "git commit -qm x -- sub && git push" "EXACT|sub/t.txt" \
  "#3111 a commit naming a directory takes what changed under it"
want_pending "git commit -qm tracked.txt && git push" "EXACT" \
  "#3111 control: a message that is a file's name takes nothing"
want_pending "git commit gone.txt -qm x && git push" "WIDENED|named.txt|sub/t.txt|tracked.txt" \
  "#3111 a commit naming a path that is not there widens and says so"
want_pending "git commit --pathspec-from-file=list.txt -qm x && git push" "WIDENED|named.txt|sub/t.txt|tracked.txt" \
  "#3111 paths named in a file widen to the whole tree and say so"
rm -rf "$PF"

echo "push-scope: files a command writes before it stages, commits and pushes (claude-config#3113)"

# ps_unread_write answers whether a command runs something that may write a file, then stages (a
# git add, or a commit that takes files itself with -a or by naming paths), commits and pushes. The
# gates read the files as they stand before the command runs, so what such a command writes goes
# out unread. It prints what may write, as the refusal names it. Anything is taken to write unless
# it is one of the commands measured to change no file (the probe in the pull request).
writes() { # writes <description> <command> <what it must print>
  local r rc name="$1: ${2//$'\n'/\\n}"
  r="$(ps_unread_write "$2")"; rc=$?
  if [ "$rc" -eq 0 ] && [ "$r" = "$3" ]; then check "$name" ok
  else check "$name" "exit $rc, printed [$r], wanted [$3]"; fi
}
no_write() { # no_write <description> <command>
  local r rc name="$1: ${2//$'\n'/\\n}"
  r="$(ps_unread_write "$2")"; rc=$?
  if [ "$rc" -eq 1 ] && [ -z "$r" ]; then check "$name" ok
  else check "$name" "exit $rc, printed [$r]"; fi
}
# The answer is after the LAST bar of a line, since a command can hold a pipe of its own.
while IFS= read -r line; do
  [ -n "$line" ] || continue
  c="${line%|*}"; want="${line##*|}"
  writes "#3113 a file may be written, then staged, committed and pushed" "$c" "$want"
done <<'WRITES'
cp ../held.txt notes/copied.md && git add -A && git commit -m x && git push|cp
sed -i '' s/a/b/ a.txt && git add -u && git commit -m x && git push|sed
npx prettier --write . && git add . && git commit -m x && git push|npx
git apply fix.patch && git add -A && git commit -m x && git push|git apply
git checkout -- a.txt && git add a.txt && git commit -m x && git push|git checkout
git restore a.txt && git add a.txt && git commit -m x && git push|git restore
git stash pop && git add -A && git commit -m x && git push|git stash
cp a b && git commit -am x && git push|cp
cp a b && git commit -qam x && git push|cp
cp a b && git commit --all -m x && git push|cp
cp a b && git commit -p -m x && git push|cp
cp a b && git commit --patch -m x && git push|cp
cp a b && git commit --interactive -m x && git push|cp
cp a b && git commit b -m x && git push|cp
cp a b && git commit -m x -- b && git push|cp
bash build.sh && git add . && git commit -m x && git push|bash
bash -c 'cp a b' && git add b && git commit -m x && git push|cp
python3 gen.py; git add out.txt; git commit -m x; git push|python3
make fmt && git add -u && git commit -m x && git push|make
(cd sub && npm run build) && git add -A && git commit -m x && git push|npm
X=1 ./gen.sh && git add . && git commit -m x && git push|./gen.sh
mv a b && git add -A && git commit -m x && git push|mv
rm a && git add -A && git commit -m x && git push|rm
touch a && git add a && git commit -m x && git push|touch
gh pr checkout 5 && git add -A && git commit -m x && git push|gh
git add a && cp x b && git add b && git commit -m x && git push|cp
cp a b && git status && git add b && git commit -m x && git push origin HEAD|cp
cp a b && git add b && git commit -m x && rtk git push|cp
cp a b && git add b && git merge --continue && git push|cp
echo hi > notes/new.txt && git add notes && git commit -m x && git push|echo into a file
printf '%s\n' hi >> notes/new.txt; git add notes; git commit -m x; git push|printf into a file
git diff > fix.patch && git add fix.patch && git commit -m x && git push|git diff into a file
git show HEAD~1:a.txt >a.txt && git add a.txt && git commit -m x && git push|git show into a file
git log --output=log.txt -1 && git add log.txt && git commit -m x && git push|git log
echo x | tee f.txt && git add f.txt && git commit -m x && git push|tee
if cp a b; then git add b && git commit -m x && git push; fi|cp
WRITES
writes "#3113 a heredoc written into a file, then staged, committed and pushed" \
  $'cat > notes/h.txt <<\'EOF\'\nbody\nEOF\ngit add notes/h.txt && git commit -m x && git push' "cat into a file"
# Controls: nothing before the staging step may write, or nothing stages, commits or pushes what
# was written.
while IFS= read -r c; do
  [ -n "$c" ] || continue
  no_write "#3113 control" "$c"
done <<'NOWRITES'
git add -A && git commit -m x && git push
cd repo && git add a.txt && git commit -m x && git push
git status && git add -u && git commit -qm x && git push 2>&1 | tail -3
git fetch origin && git add a && git commit -m x && git push
git checkout -b new && git add a && git commit -m x && git push -u origin new
git switch -c new 2>&1 && git add a && git commit -m x && git push -u origin new
test -f a && git add a && git commit -m x && git push
[ -f a ] && git add a && git commit -m x && git push
echo staging && git add a && git commit -m x && git push
echo staging >/dev/null 2>&1 && git add a && git commit -m x && git push
git diff --stat 2>/dev/null && git add a && git commit -m x && git push
git log -1 >&2; git add a; git commit -m x; git push
X=1 Y=2 git add a && git commit -m x && git push
git add a && cp x b && git commit -m x && git push
cp a b && git commit -m x && git push
cp a b && git commit --allow-empty -m x && git push
cp a b && git commit --amend --no-edit && git push
cp a b && git commit -m a && git push
cp a b && git commit -ma && git push
git stash list && git commit --allow-empty -m none && git push
cp a b && git add b && git push
cp a b && git add b && git commit -m x
git add a && git commit -m x && git push && cp a b
git add a && git commit -m x && git push > out.txt
git add a && git commit -m 'cp a b' && git push
echo cp a b && git add a && git commit -m x && git push
cat notes.txt && git add a && git commit -m x && git push
git branch keep && git tag v1 && git add a && git commit -m x && git push
NOWRITES
no_write "#3113 control: a heredoc commit message writes no file" \
  $'git add a.txt && git commit -m "$(cat <<\'EOF\'\ncp a b, then > c\nEOF\n)" && git push'
no_write "#3113 control: nor does one read from the commit's own input" \
  $'git add a.txt && git commit -q -F - <<\'EOF\' && git push\ncp a b > c\nEOF'
# With nothing to read the command the crude cut answers, which can only see more (L42).
r="$(PS_SHELL_WORDS=/nonexistent/shell-words.py; ps_unread_write "cp a b && git add -A && git commit -m x && git push")"; rc=$?
[ "$rc" -eq 0 ] && [ "$r" = "cp" ] && check "#3113 with no reader a write before the add is still found" ok \
  || check "#3113 with no reader a write before the add is still found" "exit $rc, printed [$r]"
r="$(PS_SHELL_WORDS=/nonexistent/shell-words.py; ps_unread_write "(git apply fix.patch) && git commit -am x; git push")"; rc=$?
[ "$rc" -eq 0 ] && [ "$r" = "git apply" ] && check "#3113 with no reader a patch applied before a commit -a is still found" ok \
  || check "#3113 with no reader a patch applied before a commit -a is still found" "exit $rc, printed [$r]"
r="$(PS_SHELL_WORDS=/nonexistent/shell-words.py; ps_unread_write "cd repo && git add -A && git commit -m x && git push")"; rc=$?
[ "$rc" -eq 1 ] && [ -z "$r" ] && check "#3113 with no reader an add, commit and push alone is still let through" ok \
  || check "#3113 with no reader an add, commit and push alone is still let through" "exit $rc, printed [$r]"
# Which subcommand a git runs is the reader's to say (lib/word-position-scan.py). With no reader
# this keeps no second reading of it, so any git but an add, a commit or a push may write: more
# refused on a machine that has lost its reader, never less (L42).
r="$(PS_SHELL_WORDS=/nonexistent/shell-words.py; ps_unread_write "cd repo && git status && git add -A && git commit -m x && git push")"; rc=$?
[ "$rc" -eq 0 ] && [ "$r" = "git status" ] && check "#3113 with no reader a git that only looks is not told from one that writes" ok \
  || check "#3113 with no reader a git that only looks is not told from one that writes" "exit $rc, printed [$r]"
r="$(PS_SHELL_WORDS=/nonexistent/shell-words.py; ps_unread_write "rtk git stash pop; git add -A; git commit -m x; git push")"; rc=$?
[ "$rc" -eq 0 ] && [ "$r" = "git stash" ] && check "#3113 with no reader a git behind rtk is named with its next word" ok \
  || check "#3113 with no reader a git behind rtk is named with its next word" "exit $rc, printed [$r]"
r="$(PS_SHELL_WORDS=/nonexistent/shell-words.py; ps_unread_write "cp status git && git add -A && git commit -m x && git push")"; rc=$?
[ "$rc" -eq 0 ] && [ "$r" = "cp" ] && check "#3113 with no reader a copy whose words name git and status is still a copy" ok \
  || check "#3113 with no reader a copy whose words name git and status is still a copy" "exit $rc, printed [$r]"

echo "push-scope: a push that names what it sends (claude-config#3112)"

# ps_unread_push_source answers whether a push names, as the source of a refspec, something other
# than the branch checked out that the gates did not read: `other`, when it holds commits that are
# neither in the history of the branch checked out nor on the remote already; `unresolved`, when it
# cannot be resolved to a commit before the command runs; `moved`, when the command makes or moves
# it, or commits, before pushing it. The fixture is on feat, one merge commit ahead of origin/feat;
# the branch other holds one commit nothing else does; the branch pushed holds one that origin has;
# the tag onother is on other and the tag onhead on HEAD.
RS="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.pushsource.XXXXXXXX")"
PSRC="$(mmf_repo "$RS" clean guide/new.md $'from main\n')"
( cd "$PSRC" && git checkout -qb other && printf 'only here\n' > notes/other.md && git add notes/other.md && gc commit -qm other \
    && git checkout -q feat && git checkout -qb pushed && printf 'on origin\n' > notes/pushed.md && git add notes/pushed.md \
    && gc commit -qm pushed && git push -qu origin pushed && git checkout -q feat \
    && git tag onother other && git tag onhead ) >/dev/null 2>&1
[ "$(git -C "$PSRC" branch --show-current 2>/dev/null)" = feat ] \
  && [ "$(git -C "$PSRC" rev-list --count other --not HEAD --remotes=origin 2>/dev/null)" = 1 ] \
  && [ "$(git -C "$PSRC" rev-list --count pushed --not HEAD --remotes=origin 2>/dev/null)" = 0 ] \
  && [ "$(git -C "$PSRC" rev-list --count onhead --not HEAD 2>/dev/null)" = 0 ] \
  && check "#3112 the fixture is on feat, and only other and its tag hold a commit neither feat nor origin has" ok \
  || check "#3112 the fixture is on feat, and only other and its tag hold a commit neither feat nor origin has" "it is not, so the cases below prove nothing"
OTHER_SHA="$(git -C "$PSRC" rev-parse other 2>/dev/null)"
source_is() { # source_is <description> <command> <what it must print>
  local r rc name="$1: ${2//$'\n'/\\n}"
  r="$(ps_unread_push_source "$2" "$PSRC")"; rc=$?
  if [ "$rc" -eq 0 ] && [ "$r" = "$3" ]; then check "$name" ok
  else check "$name" "exit $rc, printed [$r], wanted [$3]"; fi
}
source_read() { # source_read <description> <command>
  local r rc name="$1: ${2//$'\n'/\\n}"
  r="$(ps_unread_push_source "$2" "$PSRC")"; rc=$?
  if [ "$rc" -eq 1 ] && [ -z "$r" ]; then check "$name" ok
  else check "$name" "exit $rc, printed [$r]"; fi
}
# The answer is after the LAST bar of a line, since a command can hold a pipe of its own.
while IFS= read -r line; do
  [ -n "$line" ] || continue
  c="${line%|*}"; want="${line##*|}"
  source_is "#3112 the push sends commits no gate read" "$c" "$want"
done <<'SOURCES'
git push origin other|other other
git push origin other:other|other other
git push origin +other:refs/heads/x|other other
git push origin refs/heads/other|other refs/heads/other
git push -u origin other|other other
git push -f origin other|other other
git push --force-with-lease origin other|other other
git push -q origin other 2>&1 | tail -1|other other
git push -o ci.skip origin other|other other
git push origin feat other|other other
git push origin HEAD other:x|other other
git push origin onother|other onother
git push origin tag onother|other onother
git push --all origin|other --all
git push --all|other --all
git push origin --branches|other --branches
git push --mirror origin|other --mirror
git push --tags origin|other --tags
git push origin feat --tags|other --tags
rtk git push origin other|other other
(git push origin other)|other other
git status && git push origin other|other other
git push && git push origin other|other other
bash -c 'git push origin other'|other other
git push origin "$BRANCH"|unresolved $BRANCH
git push origin $BRANCH:feat|unresolved $BRANCH
git push origin "$(cat branch.txt)"|unresolved $(cat branch.txt)
git push origin $(cat branch.txt)|unresolved $(cat branch.txt)
git push origin $(cat branch.txt):feat|unresolved $(cat branch.txt)
git push origin $(echo other|unresolved $(echo other
git push origin nosuch|unresolved nosuch
git push origin tag nosuch|unresolved nosuch
git push origin 'refs/heads/*:refs/heads/*'|unresolved refs/heads/*
git branch -f pushed other && git push origin pushed|moved pushed
git branch -M pushed && git push origin pushed|moved pushed
git branch new other && git push origin new|moved new
git tag v9 other && git push origin v9|moved v9
git tag -f onhead other && git push origin onhead|moved onhead
git tag -a v9 -m 'rel nine' other && git push origin v9|moved v9
git fetch origin main:pushed && git push origin pushed|moved pushed
git worktree add -b new ../wt other && git push origin new|moved new
git commit -m x && git push origin pushed|moved pushed
git commit -m x && git push origin HEAD~1:feat|moved HEAD~1
git merge --continue && git push origin pushed|moved pushed
SOURCES
source_is "#3112 a commit named by its hash is still another branch's" "git push origin $OTHER_SHA:refs/heads/x" "other $OTHER_SHA"
source_is "#3112 asked through git -C" "git -C $PSRC push origin other" "other other"
# Read, and let through: what the push sends is in the range the gates read, is on the remote
# already, or is nothing at all.
while IFS= read -r c; do
  [ -n "$c" ] || continue
  source_read "#3112 control, the gates read what this sends" "$c"
done <<'READ'
git push
git push origin
git push -u origin feat
git push origin feat:feat
git push origin +feat
git push origin refs/heads/feat
git push origin feat:refs/heads/elsewhere
git push origin HEAD
git push origin HEAD:other
git push origin HEAD:refs/heads/x
git push origin @
git push origin HEAD~1:feat
git push origin pushed
git push origin main
git push origin onhead
git push origin tag onhead
git push --follow-tags origin feat
git push origin "$(git branch --show-current)"
git push -u origin $(git rev-parse --abbrev-ref HEAD)
git push origin $(git branch --show-current)
git push -n origin $(cat branch.txt)
git push origin "$(git symbolic-ref --short HEAD)"
git push origin --delete other
git push -d origin other
git push origin :other
git push -n origin other
git push --dry-run origin other
git checkout -b new && git push -u origin new
git switch -c new && git push -u origin new
git switch -c new && git add a && git commit -m x && git push -u origin new
git branch new && git push origin new
git tag v9 && git push origin v9
git tag -a v9 -m 'rel nine' && git push origin v9
git commit -m x && git push -u origin feat
git commit -m x && git push origin HEAD
git commit -m 'git push origin other' && git push
echo git push origin other && git push
git push origin feat && git branch -f pushed other
git fetch origin main && git push origin main
READ
# A name this command makes where HEAD is, when it is there already, is whatever it already was.
source_is "#3112 a branch the command would make at HEAD, already there with commits of its own" \
  "git branch other; git push origin other" "other other"
# A repository with no commit has nothing to compare against, and git itself refuses its push.
git init -q "$RS/empty" 2>/dev/null
r="$(ps_unread_push_source "git push origin other" "$RS/empty")"; rc=$?
[ "$rc" -eq 1 ] && [ -z "$r" ] && check "#3112 a repository with no commit is not asked" ok \
  || check "#3112 a repository with no commit is not asked" "exit $rc, printed [$r]"
r="$(cd "$PSRC" && ps_unread_push_source "git push origin other")"; rc=$?
[ "$rc" -eq 0 ] && [ "$r" = "other other" ] && check "#3112 the directory defaults to where it is asked" ok \
  || check "#3112 the directory defaults to where it is asked" "exit $rc, printed [$r]"
# Once every tag is in the range the gates read, a push of the tags sends nothing unread.
git -C "$PSRC" tag -d onother >/dev/null 2>&1
source_read "#3112 control, every tag is on the branch checked out" "git push --tags origin"
# With nothing to read the command the crude cut answers, which can only see more (L42).
r="$(PS_SHELL_WORDS=/nonexistent/shell-words.py; ps_unread_push_source "git status; git push origin other" "$PSRC")"; rc=$?
[ "$rc" -eq 0 ] && [ "$r" = "other other" ] && check "#3112 with no reader a push of another branch is still found" ok \
  || check "#3112 with no reader a push of another branch is still found" "exit $rc, printed [$r]"
r="$(PS_SHELL_WORDS=/nonexistent/shell-words.py; ps_unread_push_source "git branch -f pushed other && git push origin pushed" "$PSRC")"; rc=$?
[ "$rc" -eq 0 ] && [ "$r" = "moved pushed" ] && check "#3112 with no reader a branch moved before its push is still found" ok \
  || check "#3112 with no reader a branch moved before its push is still found" "exit $rc, printed [$r]"
r="$(PS_SHELL_WORDS=/nonexistent/shell-words.py; ps_unread_push_source "git checkout -b new && git push -u origin new" "$PSRC")"; rc=$?
[ "$rc" -eq 1 ] && [ -z "$r" ] && check "#3112 with no reader a branch made at HEAD and pushed is still let through" ok \
  || check "#3112 with no reader a branch made at HEAD and pushed is still let through" "exit $rc, printed [$r]"
r="$(PS_SHELL_WORDS=/nonexistent/shell-words.py; ps_unread_push_source "git push -u origin feat" "$PSRC")"; rc=$?
[ "$rc" -eq 1 ] && [ -z "$r" ] && check "#3112 with no reader a push of the branch checked out is still let through" ok \
  || check "#3112 with no reader a push of the branch checked out is still let through" "exit $rc, printed [$r]"
rm -rf "$RS"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
