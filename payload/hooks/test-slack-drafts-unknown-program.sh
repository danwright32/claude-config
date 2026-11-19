#!/usr/bin/env bash
# Tests for the words written after a program the Slack drafts gate does not know
# (claude-config#3277). The rule is in lib/unknown-program.py. Kept apart from
# test-slack-drafts-only-gate.sh as test-slack-drafts-no-network-route.sh is, so that suite does not
# grow past its wall clock; the helpers below are copied from that one as they are, so a case here
# is driven the same way: a hook payload piped into slack-drafts-only-gate.sh, exit 0 allowed and 2
# refused, the reason on stderr. Nothing a case names is ever run.
#
# The gate refused `node --test test/notify.test.js`, a test file whose imports reach code able to
# post, and allowed the same words after `op run --`, `dotenv --` and `sandbox-exec -f <profile>`
# (measured 2026-11-18 on the installed gate): a program it has no rule for was a command that runs
# nothing. What is held:
#   * each measured form is refused, and so is the same command behind any other program the gate
#     does not know to be unable to run its words, a function, a program named by a variable or a
#     script that runs what it is handed, with a runner the shared reader reads past in front (env,
#     time, nice, nohup, timeout) or between the program and the command, typed, in a string a
#     shell runs and in a script on disk;
#   * a redirection glued to the last word (`... notify.test.js>out.txt`) does not hide the file
#     there, behind a script that runs its words and behind a program the gate does not know;
#   * the refusal names the program, and names the no network wrapper where a file's imports are
#     what reach the code that posts, in the words the gate already uses for it;
#   * what the gate allowed and must go on allowing: a program it does not know followed by words
#     that are no refused command, a program it knows to be unable to run its words (grep, echo, a
#     git subcommand that only reads, find with no -exec, a script that only prints what it is
#     handed) followed by the refused command's words, and the installed no network wrapper as the
#     whole call;
#   * what the gate refused before is refused still, behind each runner the reader reads past.
# Most cases are asked of the gate's own code in one start (L298); the ones that hold the wrapper's
# fast path and the wording of a refusal go through the hook, as a session's call does.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/slack-drafts-only-gate.sh"
unset SLACK_GATE_UNWORKED_PATHS

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

if [ ! -f "$HOOK" ]; then
  echo "FAIL: there is no slack-drafts-only-gate.sh beside this suite at $DIR, so no Slack send is refused."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

T="$(mktemp -d "${TMPDIR:-/tmp}/slack-gate.XXXXXXXX")" || exit 1
case "${T%/}" in ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$T'" >&2; exit 2 ;; esac
trap 'rm -rf "$T"' EXIT
# Every case runs with a judgement cache of its own, never this Mac's (claude-config#2918).
export SLACK_GATE_CACHE_DIR="$T/gate-cache"
unset SLACK_GATE_CACHE_TRACE

# payload <tool name> <tool_input JSON> [cwd]: one PreToolUse payload in the measured shape.
payload() {
  python3 -c '
import json, sys
tool, inp, cwd = sys.argv[1], json.loads(sys.argv[2]), sys.argv[3]
print(json.dumps({"session_id": "f6017250-8f33-47ac-bbb2-b82a7c319d0d",
                  "transcript_path": "/tmp/transcript.jsonl", "cwd": cwd,
                  "permission_mode": "auto", "hook_event_name": "PreToolUse", "tool_name": tool,
                  "tool_input": inp, "tool_use_id": "toolu_01X4Qw7JnfYswF7UVX94Z4Sy"}))
' "$1" "$2" "${3:-$T}"
}
bash_input() { python3 -c 'import json, sys; print(json.dumps({"command": sys.argv[1], "description": "d"}))' "$1"; }

RC=0; OUT=""; ERR=""
run_raw() { # run_raw <stdin text>
  local errf; errf="$(mktemp "${TMPDIR:-/tmp}/slack-gate-err.XXXXXXXX")"
  OUT="$(printf '%s' "$1" | bash "$HOOK" 2>"$errf")"; RC=$?
  ERR="$(cat "$errf")"; rm -f "$errf"
}

refused() { if [ "$RC" -eq 2 ]; then check "$1" ok; else check "$1" "exit $RC, stdout: ${OUT:0:200}, stderr: ${ERR:0:300}"; fi; }
allowed() { if [ "$RC" -eq 0 ] && [ -z "$(printf '%s%s' "$OUT" "$ERR" | tr -d '[:space:]')" ]; then check "$1" ok
            else check "$1" "exit $RC, stdout: ${OUT:0:200}, stderr: ${ERR:0:300}"; fi; }
says() { case "$ERR" in *"$2"*) check "$1" ok ;; *) check "$1" "stderr did not say '$2': ${ERR:0:400}" ;; esac; }
says_not() { case "$ERR" in *"$2"*) check "$1" "stderr said '$2': ${ERR:0:400}" ;; *) check "$1" ok ;; esac; }
read_refused() {
  refused "$1"
  case "$ERR" in
    *"could not judge"*|*Traceback*) check "$1 (judged, not a crash)" "the gate crashed: ${ERR:0:300}" ;;
    *) check "$1 (judged, not a crash)" ok ;;
  esac
}
read_allowed() {
  allowed "$1"
  case "$ERR" in
    *"could not judge"*|*Traceback*) check "$1 (judged, not a crash)" "the gate crashed: ${ERR:0:300}" ;;
    *) check "$1 (judged, not a crash)" ok ;;
  esac
}
POST="curl -s -X POST -d text=hi https://slack.com/api/chat.postMessage"

W="$DIR/no-network-run.sh"
if [ ! -f "$W" ]; then
  echo "FAIL: there is no no-network-run.sh beside this suite at $DIR, so the gate has no installed wrapper to name."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

# A project whose one test file imports a module that reads the webhook, which is what the gate
# refuses (#3173), beside a test that imports nothing, a script that posts, a script that runs the
# words it is handed, one that only prints how many it was handed, a script on disk holding the
# measured command, and a package script that runs the file handed after its name.
P="$T/proj"
mkdir -p "$P/test" "$P/lib"
printf '%s\n' 'const url = process.env.SLACK_WEBHOOK;' \
  'module.exports.notify = (text) => fetch(url, { method: "POST", body: text });' > "$P/lib/notify.js"
printf '%s\n' 'const test = require("node:test");' 'const { notify } = require("../lib/notify.js");' \
  'test("is driven through a fake", () => notify);' > "$P/test/notify.test.js"
printf '%s\n' 'const test = require("node:test");' 'test("adds", () => 1 + 1);' > "$P/test/plain.test.js"
printf '%s\n' "$POST" > "$P/post.sh"
printf '%s\n' '#!/bin/bash' 'exec "$@"' > "$T/runner.sh"
printf '%s\n' '#!/bin/bash' 'echo "$#"' > "$T/quiet.sh"
chmod +x "$T/runner.sh" "$T/quiet.sh"
printf '%s\n' '(version 1)' '(allow default)' '(deny network*)' > "$P/strict.sb"
printf '%s\n' 'op run -- node --test test/notify.test.js' > "$P/behind.sh"
printf '%s\n' 'op run -- node --test test/plain.test.js' > "$P/behind-plain.sh"
printf '%s\n' '{ "scripts": { "test:one": "node --test" } }' > "$P/package.json"
# A function handed a program's name as a plain word, in a script whose other lines name the
# endpoint, as this repository's own gate suite has (`run_slow python`), and code that posts for a
# pipe to feed.
printf '%s\n' '# the cases below name https://slack.com/api/chat.postMessage' 'pick() { MODE="$1"; }' \
  'pick python' 'pick bash' 'echo "curl https://slack.com/api/chat.postMessage is refused"' > "$P/named.sh"
printf '%s\n' 'import urllib.request' 'urllib.request.urlopen("https://slack.com/api/chat.postMessage")' > "$P/post.py"
RUN_IN="$P"
run_here() { run_raw "$(payload Bash "$(bash_input "$1")" "$RUN_IN")"; }

# verdict.py <the gate's .py> <folder>: for each line on its input, read as a call made in that
# folder and walked as the gate walks one (Judge.line), "refused" or "allowed", a tab, the line as
# it was handed over, a tab, and the reason where there is one. One start of the gate's code answers
# a whole list (L298); none of the commands is run.
cat > "$T/verdict.py" <<'PY'
import importlib.util
import os
import sys

GATE = sys.argv[1]
CWD = sys.argv[2]
os.environ["GATE_DIR"] = os.path.dirname(GATE)
spec = importlib.util.spec_from_file_location("drafts_gate", GATE)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

for line in sys.stdin:
    shown = line.rstrip("\n")
    if not shown:
        continue
    judge = gate.Judge(gate.load_reader())
    try:
        judge.watch()
        try:
            reason = judge.line(shown, CWD, 0, shown)
        finally:
            judge.unwatch()
        if judge.overran:
            raise judge.overran
    except gate.OutOfTime as e:
        reason = "out of time: " + judge.out_of_time(e.doing)
    print(("refused" if reason else "allowed") + "\t" + shown + "\t" + (reason or "").replace("\n", " "))
PY

gate_says() { # gate_says <refused|allowed> <label> [text the reason must hold], the commands on descriptor 3
  # An answer that is missing or out of place fails the command it belongs to.
  local want="$1" label="$2" holds="${3:-}" runs got why i=0
  printf '' > "$T/verdict.in"
  while IFS= read -r runs <&3; do
    [ -n "$runs" ] || continue
    printf '%s\n' "$runs" >> "$T/verdict.in"
  done
  python3 "$T/verdict.py" "$DIR/slack_drafts_only_gate.py" "$P" < "$T/verdict.in" > "$T/verdict.out" 2>&1
  exec 4< "$T/verdict.out"
  while IFS= read -r runs; do
    i=$((i + 1))
    got=""
    IFS= read -r got <&4 || true
    why="${got#"$want"$'\t'"$runs"$'\t'}"
    if [ "$got" = "$why" ]; then
      check "$label: $runs" "the gate said: ${got:0:300}"
    else
      check "$label: $runs" ok
      if [ -n "$holds" ]; then
        case "$why" in *"$holds"*) check "$label, and the reason says so: $runs" ok ;;
          *) check "$label, and the reason says so: $runs" "the reason did not say '$holds': ${why:0:300}" ;; esac
      fi
    fi
  done < "$T/verdict.in"
  exec 4<&-
  if [ "$i" -eq 0 ]; then check "$label" "no command was handed over"; fi
}

KNOWS="knows to be unable to run the words after it"

not_by_this_rule() { # not_by_this_rule <label>, the commands on descriptor 3: allowed, or refused by another rule
  local label="$1" runs got i=0
  printf '' > "$T/verdict.in"
  while IFS= read -r runs <&3; do
    [ -n "$runs" ] || continue
    printf '%s\n' "$runs" >> "$T/verdict.in"
  done
  python3 "$T/verdict.py" "$DIR/slack_drafts_only_gate.py" "$P" < "$T/verdict.in" > "$T/verdict.out" 2>&1
  exec 4< "$T/verdict.out"
  while IFS= read -r runs; do
    i=$((i + 1))
    got=""
    IFS= read -r got <&4 || true
    case "$got" in
      "allowed"$'\t'"$runs"$'\t'*) check "$label: $runs" ok ;;
      "refused"$'\t'"$runs"$'\t'*"$KNOWS"*|"refused"$'\t'"$runs"$'\t'*"could each start a command"*)
        check "$label: $runs" "this rule refused it: ${got: -700}" ;;
      "refused"$'\t'"$runs"$'\t'*) check "$label: $runs" ok ;;
      *) check "$label: $runs" "the gate said: ${got:0:300}" ;;
    esac
  done < "$T/verdict.in"
  exec 4<&-
  if [ "$i" -eq 0 ]; then check "$label" "no command was handed over"; fi
}

echo "slack drafts only: the fixture is judged as it was before the rule (claude-config#3277)"

gate_says refused "#3277 the test file whose imports reach code that posts, run by node" 3<<EOF
node --test test/notify.test.js
EOF
gate_says allowed "#3277 a test file that imports nothing, run by node" 3<<EOF
node --test test/plain.test.js
EOF

echo "slack drafts only: each measured form behind a program the gate does not know is refused (claude-config#3277)"

gate_says refused "#3277 the measured forms" "$KNOWS" 3<<EOF
op run -- node --test test/notify.test.js
dotenv -- node --test test/notify.test.js
sandbox-exec -f strict.sb node --test test/notify.test.js
/usr/bin/sandbox-exec -f strict.sb node --test test/notify.test.js
sandbox-exec -f $P/strict.sb node --test test/notify.test.js
EOF

gate_says refused "#3277 a redirection glued to the last word does not hide the file" "$KNOWS" 3<<EOF
$T/runner.sh node --test test/notify.test.js>out.txt
$T/runner.sh node --test test/notify.test.js>>out.txt
op run -- node --test test/notify.test.js>out.txt
op run -- node --test test/notify.test.js>out.txt 2>&1
EOF

# A function the text itself defines is that text's own code, whose body the gate reads where it
# stands, so the words it is handed are left as they were: this repository's gate suite hands its
# own functions a program's name as a plain label (`run_slow python`, `f2854 curl "<a write>"`),
# and read as commands those refused the suite. A body that runs its arguments ("\$@") is the
# program named by a variable that claude-config#2683 left as it was, and stays open here.
gate_says allowed "#3277 a function the text defines, handed the refused command's words, is left as it was" 3<<EOF
run() { "\$@"; }; run node --test test/notify.test.js
label() { echo "\$1"; }; label curl "$POST"
EOF

gate_says refused "#3277 any other program the gate does not know, and a program named by a variable" "$KNOWS" 3<<EOF
doppler run -- node --test test/notify.test.js
aws-vault exec dev -- node --test test/notify.test.js
arch -arm64 node --test test/notify.test.js
docker exec app node --test test/notify.test.js
flock /tmp/a.lock node --test test/notify.test.js
git bisect run node --test test/notify.test.js
coproc node --test test/notify.test.js
TOOL=op; \$TOOL run -- node --test test/notify.test.js
"\$TOOL" run -- node --test test/notify.test.js
EOF

gate_says refused "#3277 the command's name in quotes, or by a path" "$KNOWS" 3<<EOF
op run -- "node" --test test/notify.test.js
op run -- 'node' --test test/notify.test.js
op run -- /usr/local/bin/node --test test/notify.test.js
op run -- n'o'de --test test/notify.test.js
EOF

gate_says refused "#3277 every command the gate reads by its name, behind such a program" "$KNOWS" 3<<EOF
op run -- bash post.sh
op run -- sh ./post.sh
op run -- bash -c 'node --test test/notify.test.js'
op run -- bash -c '$POST'
op run -- npx playwright test test/notify.test.js
op run -- npm run test:one -- test/notify.test.js
op run -- $POST
op run -- python3 -c 'import urllib.request; urllib.request.urlopen("https://slack.com/api/chat.postMessage")'
EOF

gate_says refused "#3277 a runner the reader reads past, in front of the program or of the command" "$KNOWS" 3<<EOF
env OP_ACCOUNT=x op run -- node --test test/notify.test.js
time op run -- node --test test/notify.test.js
nice -n 5 op run -- node --test test/notify.test.js
nohup dotenv -- node --test test/notify.test.js
timeout 60 op run -- node --test test/notify.test.js
OP_ACCOUNT=x op run -- node --test test/notify.test.js
op run -- env NODE_ENV=test node --test test/notify.test.js
op run -- timeout 60 node --test test/notify.test.js
op run -- nice -n 5 node --test test/notify.test.js
op run -- exec node --test test/notify.test.js
docker exec app env A=1 node --test test/notify.test.js
EOF

gate_says refused "#3277 in a string a shell runs, in a script on disk, after another command, and in a pipe" "$KNOWS" 3<<EOF
bash -c 'op run -- node --test test/notify.test.js'
bash behind.sh
cd $P && op run -- node --test test/notify.test.js
true; dotenv -- node --test test/notify.test.js | tail -5
if true; then op run -- node --test test/notify.test.js; fi
EOF

echo "slack drafts only: what the gate refused before the rule is refused still (claude-config#3277)"

gate_says refused "#3277 the command behind a runner the reader reads past" 3<<EOF
env -i node --test test/notify.test.js
env NODE_ENV=test node --test test/notify.test.js
time node --test test/notify.test.js
nice -n 5 node --test test/notify.test.js
nohup node --test test/notify.test.js
timeout 60 node --test test/notify.test.js
caffeinate -i node --test test/notify.test.js
exec node --test test/notify.test.js
command node --test test/notify.test.js
echo test/notify.test.js | xargs node --test
$T/runner.sh node --test test/notify.test.js
$T/runner.sh node --test test/notify.test.js > out.txt
$T/runner.sh node --test test/notify.test.js 2>out.txt
EOF

echo "slack drafts only: what the gate allowed and must still allow (claude-config#3277)"

gate_says allowed "#3277 a program the gate does not know, followed by words that are no refused command" 3<<EOF
op run -- node --test test/plain.test.js
op run -- node --test test/plain.test.js>out.txt
dotenv -- node --test test/plain.test.js
sandbox-exec -f strict.sb node --test test/plain.test.js
/usr/bin/sandbox-exec -f strict.sb true
op read op://vault/item/field
op run -- echo hello
dotenv -- true
docker exec app ls test/notify.test.js
which node
brew install node
op run -- node --version
op run -- env
bash behind-plain.sh
EOF

gate_says allowed "#3277 a program the gate knows to be unable to run its words, followed by the refused command's words" 3<<EOF
echo node --test test/notify.test.js
printf '%s\n' node --test test/notify.test.js
grep -n node test/notify.test.js
rg node test/notify.test.js
cat node test/notify.test.js
wc -l node test/notify.test.js
ls -l node test/notify.test.js
git log --grep node -- test/notify.test.js
git diff node -- test/notify.test.js
find node test/notify.test.js -type f
awk '{ print }' node test/notify.test.js
$T/quiet.sh node --test test/notify.test.js
EOF

# The shapes found in the sessions' own commands on the personal MacBook, 30 days to 2026-11-19 (a
# count of the text alone, 403 of 43,432 distinct commands): a word that could start a command
# after ps, top, which, claude, gh and taskpolicy, none of them a refused command.
gate_says allowed "#3277 the shapes sessions typed, where the words spell no refused command" 3<<EOF
ps -o pid,etime,command -p 4242
ps -axo pid,command
ps -o command -p 4242
ps -o time,pcpu,command -r
top -l 1 -o mem -stats pid,command,mem,time
top -l 1 -n 5 -o time
which node
which bun node tsx deno
which python3 pytest
which gtimeout timeout
claude mcp add lightroom -- npx -y @example/lightroom-mcp@0.26.0
gh search issues --repo rtk-ai/rtk npx npm --limit 5 --json number,title
gh issue view 7 --repo rtk-ai/rtk --json comments -q '.comments[-1].body'
taskpolicy -c utility bash behind-plain.sh
taskpolicy -c utility node --test test/plain.test.js
EOF

gate_says refused "#3277 and taskpolicy in front of the refused test file, which runs it" "$KNOWS" 3<<EOF
taskpolicy -c utility node --test test/notify.test.js
EOF

# A program run by the unknown one reads the input that one was given: a lone name is fed what
# feeds the command it is written in, never every line of the script that holds the same word.
gate_says allowed "#3277 a function handed a program's name, in a script whose other lines name the endpoint" 3<<EOF
bash named.sh
pick() { MODE="\$1"; }; pick python
op run -- python3 < test/plain.test.js
EOF
gate_says refused "#3277 a program's name alone behind an unknown program, fed code that posts" "$KNOWS" 3<<EOF
cat post.py | op run -- python3
op run -- python3 < post.py
op run -- python3 - < post.py
cat post.sh | op run -- bash
EOF

# The gate reads a script a session runs with bash, every line of it. The words after a program
# it does not know can be refused there for what the script's other lines hold only where the
# script names a posting endpoint (a sender whose address is a variable, a program's name alone
# fed a line that names one), so every shell script beside this suite, in lib and in the
# repository's tests and tools that names one is walked, found afresh on each run. None is refused
# by this rule. On 2026-11-19 they were seven of the repository's 588 shell scripts, this suite and
# the gate's other four among them; before a function the text defines was left as it was, the
# gate's own suite was refused at `run_slow python` and then at `f2854 curl "<a write>"`.
: > "$T/named.in"
for f in "$DIR"/*.sh "$DIR"/lib/*.sh "$DIR"/../../tests/*.sh "$DIR"/../../tools/*.sh; do
  [ -f "$f" ] || continue
  if grep -qiE 'chat[._](postmessage|schedulemessage|postephemeral|memessage)|hooks\.slack\.com|slack_webhook' "$f"; then
    printf 'bash %s\n' "$f" >> "$T/named.in"
  fi
done
named_count="$(grep -c . "$T/named.in" || true)"
if [ "${named_count:-0}" -ge 5 ]; then check "#3277 the scripts that name a posting endpoint were found ($named_count)" ok
else check "#3277 the scripts that name a posting endpoint were found" "only ${named_count:-0} were found beside $DIR, and the gate's own five suites name one"; fi
not_by_this_rule "#3277 a script of this repository that names a posting endpoint, run by bash, is not refused by this rule" 3< "$T/named.in"

gate_says allowed "#3277 the refused command as one quoted word, which no rule reads as words" 3<<EOF
echo 'node --test test/notify.test.js'
git commit -m 'node --test test/notify.test.js'
EOF

gate_says allowed "#3277 a runner the reader reads past, in front of a command that is not refused" 3<<EOF
env NODE_ENV=test node --test test/plain.test.js
time node --test test/plain.test.js
nice -n 5 node --test test/plain.test.js
nohup node --test test/plain.test.js
timeout 60 node --test test/plain.test.js
echo test/plain.test.js | xargs node --test
env OP_ACCOUNT=x op run -- node --test test/plain.test.js
time op run -- timeout 60 node --test test/plain.test.js
EOF

gate_says allowed "#3277 the installed no network wrapper and its command, as the whole call" 3<<EOF
$W op run -- node --test test/notify.test.js
$W dotenv -- node --test test/notify.test.js
$W sandbox-exec -f strict.sb node --test test/notify.test.js
cd $P && $W op run -- node --test test/notify.test.js
EOF

gate_says refused "#3277 the wrapper behind a program the gate does not know is not the whole call" 3<<EOF
op run -- $W node --test test/notify.test.js
EOF

echo "slack drafts only: more words that could each start a command than the rule reads (claude-config#3277)"

gate_says refused "#3277 a typed command with more such words than the rule reads is refused as unread" "could each start a command" 3<<EOF
op run -- node node node node node node node node node --test test/notify.test.js
EOF
gate_says allowed "#3277 and the same number of them behind a program known to be unable to run them is allowed" 3<<EOF
echo node node node node node node node node node --test test/notify.test.js
EOF

echo "slack drafts only: the refusal, as a session's call gets it through the hook (claude-config#3277)"

run_here "op run -- node --test test/notify.test.js"
read_refused "#3277 op run -- in front of the refused test file is refused through the hook"
says "#3277 and the refusal names the program" "op is not a program the gate $KNOWS"
says "#3277 and says which import reaches the code that posts" "which imports ../lib/notify.js"
says "#3277 and names the installed no network wrapper by its path" "$W"
says "#3277 and says where the wrapper goes, in the gate's own words for it" "as the first word of the command"
says "#3277 and says what the wrapper takes away" "no network access"
run_here "dotenv -- node --test test/notify.test.js"
read_refused "#3277 dotenv -- in front of the refused test file is refused through the hook"
run_here "sandbox-exec -f strict.sb node --test test/notify.test.js"
read_refused "#3277 sandbox-exec by its bare name is refused through the hook"
run_here "/usr/bin/sandbox-exec -f strict.sb node --test test/notify.test.js"
read_refused "#3277 sandbox-exec by its path is refused through the hook"
run_here "$T/runner.sh node --test test/notify.test.js>out.txt"
read_refused "#3277 a script that runs its words, the redirection glued to the last word, is refused through the hook"
run_here "op run -- bash post.sh"
read_refused "#3277 a script that posts, behind op run --, is refused through the hook"
says_not "#3277 and a refusal that is not about an import names no route" "no network wrapper"
run_here "op run -- node --test test/plain.test.js"
read_allowed "#3277 op run -- in front of a test file that imports nothing is allowed through the hook"
run_here "$W op run -- node --test test/notify.test.js"
read_allowed "#3277 the installed wrapper in front of op run -- passes through the hook"
run_here "grep -n node test/notify.test.js"
read_allowed "#3277 grep for the word node in the refused test file is allowed through the hook"

echo

echo "passed: $pass, failed: $fail"

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"

[ "$fail" -eq 0 ]
