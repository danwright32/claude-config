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
# A script on disk whose helper runs the words it is handed, and one whose helper only prints them
# (claude-config#3304).
printf '%s\n' 'run() { "$@"; }' 'run node --test test/notify.test.js' > "$P/helper-runs.sh"
printf '%s\n' 'label() { echo "case: $1"; }' 'label node --test test/notify.test.js' > "$P/helper-labels.sh"
# A script on disk that hands a benchmark runner a command as one quoted word (claude-config#3304).
printf '%s\n' "hyperfine 'node --test test/notify.test.js'" > "$P/quoted.sh"
printf '%s\n' "hyperfine 'node --test test/plain.test.js'" > "$P/quoted-plain.sh"
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
    # VERDICT_BEHIND stands the command inside that many of the rule's readings already, so the
    # nesting limit's own refusal is what comes back, with no reading around it to word it.
    judge.behind = int(os.environ.get("VERDICT_BEHIND", "0"))
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

# The words every refusal of this rule says of the program (NOT_KNOWN in lib/unknown-program.py).
# A refusal is this rule's where it holds them and another rule's where it does not, and nothing
# else is asked of its wording: until claude-config#3304 the limits' refusals were worded without
# them, and the nesting limit's matched neither wording the helper below looked for.
KNOWS="is not a program the gate knows to be unable to run the words after it"

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
      "refused"$'\t'"$runs"$'\t'*"$KNOWS"*)
        check "$label: $runs" "this rule refused it: ${got:0:700}" ;;
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
op run -- node --test test/notify.test.js>out.txt
op run -- node --test test/notify.test.js>out.txt 2>&1
EOF

# A function the text itself defines is asked what a script on disk is asked: whether its body
# runs what it is handed, or hands it to something not seen to be unable to (claude-config#3304).
# Until then every such function was left as it was, because this repository's gate suite hands
# its own functions a program's name as a plain label (`run_slow python`, `f2854 curl "<a
# write>"`), so `run() { "\$@"; }; run <the refused command>` was allowed (measured on main's
# gate through this suite, 2026-11-21). A helper that only takes a label is still left alone.
gate_says refused "#3304 a function whose body runs the words it is handed, in front of the refused command" "$KNOWS" 3<<EOF
run() { "\$@"; }; run node --test test/notify.test.js
run() { "\$@"; }; run $POST
run() { eval "\$1"; }; run node --test test/notify.test.js
run() { command "\$@"; }; run node --test test/notify.test.js
run() { exec "\$@"; }; run node --test test/notify.test.js
run() { echo "\$1"; "\$@"; }; run node --test test/notify.test.js
run() { local tool="\$1"; shift; "\$tool" "\$@"; }; run node --test test/notify.test.js
function run { "\$@"; }; run node --test test/notify.test.js
run() { op run -- "\$@"; }; run node --test test/notify.test.js
run() { inner "\$@"; }; inner() { "\$@"; }; run node --test test/notify.test.js
run() { $T/runner.sh "\$@"; }; run node --test test/notify.test.js
run() ( "\$@" ); run node --test test/notify.test.js
bash helper-runs.sh
EOF
gate_says refused "#3304 and the refusal says what the function's body does with the words" "run is a function that runs a command named by its arguments" 3<<EOF
run() { "\$@"; }; run node --test test/notify.test.js
EOF
gate_says allowed "#3304 a function that only takes a label, handed the refused command's words, is left as it was" 3<<EOF
label() { echo "\$1"; }; label curl "$POST"
label() { echo "\$1"; }; label node --test test/notify.test.js
pick() { MODE="\$1"; }; pick node --test test/notify.test.js
note() { printf '%s\n' "\$*" >> notes.txt; }; note node --test test/notify.test.js
save() { { echo "\$2"; } > "out-\$1.txt"; }; save node --test test/notify.test.js
count() { $T/quiet.sh "\$@"; }; count node --test test/notify.test.js
outer() { label "\$@"; }; label() { echo "\$1"; }; outer node --test test/notify.test.js
again() { again "\$@"; }; again node --test test/notify.test.js
bash helper-labels.sh
EOF
gate_says allowed "#3304 a function whose body runs its words, in front of a command that is not refused" 3<<EOF
run() { "\$@"; }; run node --test test/plain.test.js
run() { "\$@"; }; run echo hello
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

# Since claude-config#3252 the shared reader takes a redirection glued to a word off it, so behind
# a script that runs its words the glued form is the same command as the spaced one above, and is
# refused by the rule that refuses that one (the script runs a command named by its arguments),
# not by the unknown program reading. The reason is held, so a return to the old allowance or to
# the other reading is seen.
gate_says refused "#3277 behind a script that runs its words, a glued redirection is the spaced command" "runs a command named by its arguments" 3<<EOF
$T/runner.sh node --test test/notify.test.js>out.txt
$T/runner.sh node --test test/notify.test.js>>out.txt
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
# The repository's tests and tools are in the checkout, found by the one shared test
# (lib/checkout-root.sh, #1663); the installed copy of this suite has none and walks what is beside it.
REPO="$(bash "$DIR/lib/checkout-root.sh" "$DIR/.." 2>/dev/null || true)"
: > "$T/named.in"
named_from=("$DIR"/*.sh "$DIR"/lib/*.sh)
[ -z "$REPO" ] || named_from+=("$REPO"/tests/*.sh "$REPO"/tools/*.sh)
for f in "${named_from[@]}"; do
  [ -f "$f" ] || continue
  if grep -qiE 'chat[._](postmessage|schedulemessage|postephemeral|memessage)|hooks\.slack\.com|slack_webhook' "$f"; then
    printf 'bash %s\n' "$f" >> "$T/named.in"
  fi
done
named_count="$(grep -c . "$T/named.in" || true)"
if [ "${named_count:-0}" -ge 5 ]; then check "#3277 the scripts that name a posting endpoint were found ($named_count)" ok
else check "#3277 the scripts that name a posting endpoint were found" "only ${named_count:-0} were found beside $DIR, and the gate's own five suites name one"; fi
not_by_this_rule "#3277 a script of this repository that names a posting endpoint, run by bash, is not refused by this rule" 3< "$T/named.in"

echo "slack drafts only: a command handed to such a program as one quoted word (claude-config#3304)"

# A program that takes its command as one word (a benchmark runner, a terminal multiplexer) was
# handed the refused command in quotes and allowed: the rule read a word as the start of a command
# only where the whole word named a program (measured on main's gate through this suite,
# 2026-11-21). A word holding white space is now read as a command line of its own where one of
# its commands starts with a program the gate reads by its name. git commit is not a program the
# gate knows to be unable to run its words, so a message that is exactly a refused command is
# refused with the rest; a message that only mentions one starts with another word and is not.
gate_says refused "#3304 the refused command as one quoted word, behind a program the gate does not know" "command line of its own" 3<<EOF
hyperfine 'node --test test/notify.test.js'
hyperfine "node --test test/notify.test.js"
hyperfine '$POST'
hyperfine 'cd . && node --test test/notify.test.js'
hyperfine --warmup 3 'NODE_ENV=test node --test test/notify.test.js'
hyperfine --prepare='node --test test/notify.test.js' 'sleep 1'
hyperfine 'node --test test/plain.test.js' 'node --test test/notify.test.js'
hyperfine 'bash post.sh'
bench() { hyperfine "\$@"; }; bench 'node --test test/notify.test.js'
bench() { local n="\$1"; shift; hyperfine --runs "\$n" "\$@"; }; bench 3 'node --test test/notify.test.js'
tmux send-keys 'node --test test/notify.test.js' Enter
time hyperfine 'node --test test/notify.test.js'
git commit -m 'node --test test/notify.test.js'
run() { "\$@"; }; run hyperfine 'node --test test/notify.test.js'
bash quoted.sh
EOF
gate_says refused "#3304 a function that evaluates the word it is handed, or runs it in a shell, is refused as it was" 3<<EOF
run() { eval "\$1"; }; run 'node --test test/notify.test.js'
run() { bash -c "\$1"; }; run 'node --test test/notify.test.js'
EOF
# A body that pipes one word it is handed into a command NAMED by another runs that other word: the
# pipe hands text to read, and the command's own name is still a word of a command. The first build
# passed such a command over with the ones a pipe only feeds, looking at the words after the name
# alone (the lessons review of this branch, 2026-11-21).
gate_says refused "#3304 a function that pipes one word into a command named by another word it is handed runs that word" "command line of its own" 3<<EOF
ask() { printf '%s' "\$2" | \$1; }; ask 'node --test test/notify.test.js' hello
EOF
gate_says refused "#3304 and the refusal is this rule's, by the words every refusal of it carries" "$KNOWS" 3<<EOF
hyperfine 'node --test test/notify.test.js'
EOF
gate_says allowed "#3304 a quoted word that is no refused command, or is handed to a program known to be unable to run it" 3<<EOF
hyperfine 'node --test test/plain.test.js'
hyperfine 'sleep 1'
hyperfine --warmup 3 'echo hello'
echo 'node --test test/notify.test.js'
printf '%s\n' 'node --test test/notify.test.js'
grep -n 'node --test' test/notify.test.js
git commit -m 'refuse node --test test/notify.test.js behind a helper'
git commit -m 'fix: curl to chat.postMessage is refused'
claude -p 'run node --test test/notify.test.js and say what it prints'
jq '.scripts | keys' package.json
sed -n '1,5p' test/notify.test.js
label() { echo "\$1"; }; label 'node --test test/notify.test.js'
bash quoted-plain.sh
EOF
# Two limits, held so a change to either is seen. A quoted word whose own command starts with a
# program the gate does not know is not read: read, every sentence that mentions a program after
# its first word (a commit message) would be a command line. And a function whose body only pipes
# what it is handed into a program's input is handed text, not a command: this repository's gate
# suites hand each command they ask the gate about to such a helper (run_bash "<a refused
# command>"), and read as a run of it every one of those suites would be refused.
gate_says allowed "#3304 left open: a quoted word whose command starts with a program the gate does not know" 3<<EOF
hyperfine 'op run -- node --test test/notify.test.js'
EOF
# Only a word written as one quoted string is read. A quoted string glued to more is what a line
# of JSON read as a command holds ("command": "<a command>"}}), and read as a command line it
# refused a transcript that a script sources as posting, for a command the transcript only quotes
# (the gate suite's own 3 MB transcript case, which must run out of time and say so).
gate_says allowed "#3304 a quoted string glued to more is not one quoted word, and is left as it was" 3<<EOF
{type: user, message: {content: "node --test test/notify.test.js"}}
jot "node --test test/notify.test.js",
EOF
gate_says allowed "#3304 a function that only pipes what it is handed into a program, handed the refused command as one word" 3<<EOF
ask() { printf '%s' "\$1" | $T/quiet.sh; }; ask 'node --test test/notify.test.js'
ask() { OUT="\$(printf '%s' "\$1" | bash "\$HOOK" 2>/dev/null)"; }; ask 'node --test test/notify.test.js'
EOF
gate_says refused "#3304 more quoted command lines than the rule reads are refused as unread" "could each start a command" 3<<EOF
hyperfine 'node a.js' 'node b.js' 'node c.js' 'node d.js' 'node e.js' 'node f.js' 'node --test test/notify.test.js'
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
gate_says refused "#3304 and that refusal carries the words every refusal of this rule does" "$KNOWS" 3<<EOF
op run -- node node node node node node node node node --test test/notify.test.js
EOF
gate_says allowed "#3277 and the same number of them behind a program known to be unable to run them is allowed" 3<<EOF
echo node node node node node node node node node --test test/notify.test.js
EOF

echo "slack drafts only: more of these readings inside one another than the rule reads (claude-config#3277)"

# Each string a shell runs holds the next program the gate does not know, so the last command is
# a word of no reading but the innermost. Past three readings inside one another the rule read
# nothing and said nothing, which allowed the fourth (the lessons review of this branch, 2026-11-19).
gate_says refused "#3277 a typed command four such programs deep, each in a string a shell runs, is refused as unread" "inside one another" 3<<EOF
op run -- bash -c 'op run -- bash -c "op run -- bash -c \"op run -- node --test test/notify.test.js\""'
EOF
gate_says refused "#3304 and that refusal carries the words every refusal of this rule does" "$KNOWS" 3<<EOF
op run -- bash -c 'op run -- bash -c "op run -- bash -c \"op run -- node --test test/notify.test.js\""'
EOF
gate_says refused "#3277 and three deep the test file is still read and refused for what it imports" "$KNOWS" 3<<EOF
op run -- bash -c 'op run -- bash -c "op run -- node --test test/notify.test.js"'
EOF
gate_says allowed "#3277 and three deep in front of a test file that imports nothing is allowed" 3<<EOF
op run -- bash -c 'op run -- bash -c "op run -- node --test test/plain.test.js"'
EOF
# With no string between them the programs are words of one command, read once however many
# there are: nothing there is unread, so nothing is refused as unread.
gate_says refused "#3277 four such programs as the words of one command are one reading, and the test file is read" "$KNOWS" 3<<EOF
op run -- env A=1 op run -- env A=1 op run -- env A=1 op run -- node --test test/notify.test.js
EOF
gate_says allowed "#3277 and the same in front of a test file that imports nothing is allowed, not refused as unread" 3<<EOF
op run -- env A=1 op run -- env A=1 op run -- env A=1 op run -- node --test test/plain.test.js
EOF

echo "slack drafts only: the helper that tells this rule's refusals from another rule's (claude-config#3304)"

# not_by_this_rule passes a command another rule refuses and fails one this rule refuses. It knew
# this rule's refusals by two wordings, and the nesting limit's was a third, so a script refused
# by that limit counted as refused by some other rule (the lessons review of pull request 3305).
# Each of the rule's refusals is handed to it here, and it must count each as a failure.
helper_counts() { # helper_counts <label> <the failures it must count>, the commands on descriptor 3
  local label="$1" want="$2" got
  got="$( (pass=0; fail=0; not_by_this_rule "probe" > /dev/null; printf '%s' "$fail") )"
  if [ "$got" = "$want" ]; then check "$label" ok; else check "$label" "it counted $got failures, not $want"; fi
}
helper_counts "#3304 the helper counts a refusal by the nesting limit as this rule's" 1 3<<EOF
op run -- bash -c 'op run -- bash -c "op run -- bash -c \"op run -- node --test test/notify.test.js\""'
EOF
# Typed four deep, the three readings around the limit's refusal each word theirs in front of it,
# so the refusal as a whole carried the rule's words whatever the limit's own said. Asked with the
# command already standing inside the readings, the limit's refusal comes back alone, and it is
# that text the helper must know: it is what a reading that words nothing around it would hand on.
VERDICT_BEHIND=99 gate_says refused "#3304 the nesting limit's own refusal, with no reading around it, carries the rule's words" "$KNOWS" 3<<EOF
op run -- node --test test/notify.test.js
EOF
VERDICT_BEHIND=99 gate_says refused "#3304 and it is the nesting limit's refusal" "inside one another" 3<<EOF
op run -- node --test test/notify.test.js
EOF
VERDICT_BEHIND=99 helper_counts "#3304 the helper counts the nesting limit's own refusal as this rule's" 1 3<<EOF
op run -- node --test test/notify.test.js
EOF
helper_counts "#3304 the helper counts a refusal by the limit on words as this rule's" 1 3<<EOF
op run -- node node node node node node node node node --test test/notify.test.js
EOF
helper_counts "#3304 the helper counts each of the rule's other refusals as this rule's" 3 3<<EOF
op run -- node --test test/notify.test.js
run() { "\$@"; }; run node --test test/notify.test.js
hyperfine 'node --test test/notify.test.js'
EOF
helper_counts "#3304 and counts no failure for a command another rule refuses, or one that is allowed" 0 3<<EOF
node --test test/notify.test.js
op run -- node --test test/plain.test.js
EOF

echo "slack drafts only: the refusal, as a session's call gets it through the hook (claude-config#3277)"

run_here "op run -- node --test test/notify.test.js"
read_refused "#3277 op run -- in front of the refused test file is refused through the hook"
says "#3277 and the refusal names the program" "op $KNOWS"
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
run_here "run() { \"\$@\"; }; run node --test test/notify.test.js"
read_refused "#3304 a function that runs its words, in front of the refused test file, is refused through the hook"
says "#3304 and the refusal says what the function does" "run is a function that runs a command named by its arguments"
says "#3304 and names the installed no network wrapper by its path" "$W"
run_here "hyperfine 'node --test test/notify.test.js'"
read_refused "#3304 the refused test file as one quoted word, behind a program the gate does not know, is refused through the hook"
says "#3304 and the refusal names the program" "hyperfine $KNOWS"
run_here "hyperfine 'node --test test/plain.test.js'"
read_allowed "#3304 a test file that imports nothing, as one quoted word, is allowed through the hook"
run_here "grep -n node test/notify.test.js"
read_allowed "#3277 grep for the word node in the refused test file is allowed through the hook"

echo

echo "passed: $pass, failed: $fail"

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"

[ "$fail" -eq 0 ]
