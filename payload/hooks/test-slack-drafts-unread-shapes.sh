#!/usr/bin/env bash
# Tests for the shapes the Slack drafts gate judged without opening the files involved
# (claude-config#3251): a file pattern handed to a test runner, a package script run through a
# workspace selector, a package script whose own command hands a bare runner a file, and a shell
# whose code or script is built by xargs, named as /dev/stdin, started through $SHELL, read as a
# line and then run, or written as \$( ) inside a double quoted string. The package reading is in
# lib/program-runs.py and the shell shapes in lib/sh-walk-shapes.py. Kept apart from
# test-slack-drafts-code-loaders.sh so that suite does not grow past its wall clock; the helpers
# below are copied from it as they are, so a case here is driven the same way: a hook payload piped
# into slack-drafts-only-gate.sh, exit 0 allowed and 2 refused, the reason on stderr. Nothing a case
# names is ever run, and every refused case has a harmless twin that passes.
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
read_refused() {
  refused "$1"
  case "$ERR" in
    *"could not judge"*|*Traceback*) check "$1 (judged, not a crash)" "the gate crashed: ${ERR:0:300}" ;;
    *) check "$1 (judged, not a crash)" ok ;;
  esac
}
POST="curl -s -X POST -d text=hi https://slack.com/api/chat.postMessage"

# each <helper> <label> [says text]: one command per line of the heredoc on descriptor 3, judged in
# the folder run_in names. The commands are data here, read a line at a time and handed to the gate
# as a payload; none is run.
RUN_IN="$T"
run_here() { run_raw "$(payload Bash "$(bash_input "$1")" "$RUN_IN")"; }
each() {
  local how="$1" label="$2" want="${3:-}" runs
  while IFS= read -r runs <&3; do
    [ -n "$runs" ] || continue
    run_here "$runs"
    "$how" "$label: $runs"
    if [ -n "$want" ]; then says "$label, and the refusal says so: $runs" "$want"; fi
  done
}

echo "slack drafts only: a file pattern handed to a runner is expanded and its files read (claude-config#3251)"

# Measured 2026-11-18 through the loaders suite's harness: `npx playwright test tests/job.spec.js`
# is refused where the spec's imports reach code that posts, and `npx playwright test
# 'tests/*.spec.js'` passed, in the npx form and the package script form alike: a word that names no
# file was read as nothing. The same held for a pattern the shell itself expands before the program
# starts (`node scripts/run-tests.js tests/*.spec.js`, `bash scripts/p*.sh`). A word holding a
# pattern character is now expanded against the tree as the shell expands it, and each file it
# matches is read as if it were written there.
P="$T/p3251"
mkdir -p "$P/tests" "$P/scripts" "$P/lib" "$P/web/tests" "$P/packages/api/tests" "$P/packages/quiet/tests" "$P/many"
printf '%s\n' '{"name": "fx", "version": "1.0.0", "workspaces": ["web", "packages/*"], "scripts": {' \
  '"test:node": "playwright test --config playwright.node.config.js",' \
  '"test:one": "playwright test tests/job.spec.js",' \
  '"test:quiet": "playwright test tests/quiet.spec.js",' \
  '"test:glob": "playwright test tests/*.spec.js",' \
  '"test:qglob": "playwright test tests/q*.spec.js",' \
  '"two": "tsc --noEmit && playwright test tests/job.spec.js",' \
  '"viaenv": "cross-env NODE_ENV=test playwright test tests/job.spec.js",' \
  '"viash": "bash scripts/run-one.sh",' \
  '"viashq": "bash scripts/run-quiet.sh",' \
  '"copy": "cp tests/job.spec.js out.spec.js",' \
  '"show": "cat tests/job.spec.js",' \
  '"lint:quiet": "eslint tests/quiet.spec.js",' \
  '"test:own": "node scripts/run-tests.js"}}' > "$P/package.json"
printf '%s\n' 'packages:' '  - web' '  - "packages/*"' > "$P/pnpm-workspace.yaml"
printf '%s\n' 'module.exports = { testDir: "tests" };' > "$P/playwright.node.config.js"
printf '%s\n' 'const { test } = require("@playwright/test");' 'test("adds", () => 1 + 1);' > "$P/tests/quiet.spec.js"
cp "$P/tests/quiet.spec.js" "$P/tests/quick.spec.js"
printf '%s\n' 'const url = process.env.SLACK_WEBHOOK;' \
  'async function alert(t) { await fetch(url, { method: "POST", body: JSON.stringify({ text: t }) }); }' \
  'module.exports = { alert };' > "$P/lib/alert.js"
printf '%s\n' 'const { test } = require("@playwright/test");' 'const { alert } = require("../lib/alert");' \
  'test("runs", () => alert("x"));' > "$P/tests/job.spec.js"
printf '%s\n' 'const path = require("path");' 'for (const f of process.argv.slice(2)) require(path.resolve(f));' > "$P/scripts/run-tests.js"
printf '%s\n' "$POST" > "$P/scripts/post.sh"
printf '%s\n' 'echo ok' > "$P/scripts/ok.sh"
printf '%s\n' 'playwright test tests/job.spec.js' > "$P/scripts/run-one.sh"
printf '%s\n' 'playwright test tests/quiet.spec.js' > "$P/scripts/run-quiet.sh"
printf '%s\n' "npx playwright test 'many/*.spec.js'" > "$P/scripts/run-many.sh"
# More files than one pattern is expanded to: the pattern is then unread, and refused where typed.
python3 -c '
import os, sys
for n in range(260):
    open(os.path.join(sys.argv[1], "s%03d.spec.js" % n), "w").close()
' "$P/many"
RUN_IN="$P"

# The yardsticks, refused before and still: the spec handed by name.
each read_refused "#3251 the yardstick: a spec whose imports reach code that posts is refused handed by name" "alert.js" 3<<'EOF'
npx playwright test tests/job.spec.js
node scripts/run-tests.js tests/job.spec.js
EOF
each read_refused "#3251 a pattern matching a spec that reaches code that posts is refused handed to a launcher's package" "alert.js" 3<<'EOF'
npx playwright test 'tests/*.spec.js'
npx playwright test tests/*.spec.js
npx playwright test "tests/**/*.spec.js"
npx playwright test tests/j??.spec.js
npx playwright test tests/{job,quiet}.spec.js
npx playwright test 'tests/[j]ob.spec.js'
npx playwright test --headed 'tests/*.spec.js'
npx vitest run 'tests/*.spec.js'
npx mocha '**/job.spec.js'
pnpm exec playwright test 'tests/*.spec.js'
EOF
each read_refused "#3251 and handed to a package script" "alert.js" 3<<'EOF'
npm run test:node -- 'tests/*.spec.js'
npm run test:node -- tests/*.spec.js
pnpm test:node 'tests/*.spec.js'
yarn test:node tests/*.spec.js
npm run test:own -- tests/*.spec.js
npm run test:own -- 'tests/j*.spec.js'
EOF
each read_refused "#3251 and handed to a program by a pattern the shell expands" "" 3<<'EOF'
node scripts/run-tests.js tests/*.spec.js
node tests/j*.spec.js
bash scripts/p*.sh
sh scripts/pos?.sh
EOF
each allowed "#3251 a pattern matching only files that reach nothing that posts still passes" 3<<'EOF'
npx playwright test tests/quiet.spec.js
npx playwright test 'tests/q*.spec.js'
npx playwright test tests/q*.spec.js
npx playwright test 'tests/**/q*.spec.js'
npx playwright test tests/{quiet,quick}.spec.js
npx playwright test 'nothing/*.spec.js'
npx playwright test --grep 'a*b'
npx vitest run 'tests/qui*.spec.js'
npm run test:node -- 'tests/q*.spec.js'
pnpm test:node tests/q*.spec.js
yarn test:node 'tests/qui??.spec.js'
node scripts/run-tests.js tests/q*.spec.js
bash scripts/o*.sh
EOF
RUN_IN="$P"; run_here "npx playwright test 'many/*.spec.js'"
read_refused "#3251 a pattern matching more files than are read is refused typed, as unread"
says "#3251 and the refusal says the pattern was not expanded" "matches more than"
run_here "bash scripts/run-many.sh"
allowed "#3251 and the same pattern in a script on disk is left alone, as an unread feed is"

echo
echo "slack drafts only: a package script's own runner is handed the files its command names (claude-config#3251)"

# Measured 2026-11-18: `"test:one": "playwright test tests/job.spec.js"` run as `npm run test:one`
# passed. #3143 read a bare program of a package script as a package only for the words after the
# script's name, so the files the script's own command names were never opened. A bare program in a
# package script is one the package manager finds in node_modules/.bin, so it is now read as the
# package a launcher runs with every word it is given. A shell builtin or a program of the system's
# own folders (cp, cat) is no package and is read as before.
each read_refused "#3251 a package script whose command hands a bare runner a spec that reaches code that posts is refused" "alert.js" 3<<'EOF'
npm run test:one
npm run-script test:one
pnpm test:one
pnpm run test:one
yarn test:one
yarn run test:one
npm run test:one -- --headed
npm run two
npm run viaenv
npm run viash
npm run test:glob
EOF
run_here "npm run test:one"
says "#3251 and the refusal names the package script" "the package script test:one"
each allowed "#3251 a package script whose command names only files that reach nothing that posts still passes" 3<<'EOF'
npm run test:quiet
pnpm test:quiet
yarn test:quiet
npm run test:quiet -- --headed
npm run test:qglob
npm run lint:quiet
npm run viashq
npm run test:node
npm run test:own
EOF
each allowed "#3251 a system program in a package script is no package, and the files it is handed stay unread" 3<<'EOF'
npm run copy
npm run show
EOF

echo
echo "slack drafts only: a package script run through a workspace selector is followed (claude-config#3251)"

# Measured 2026-11-18: `pnpm --filter web test`, `npm -w web run test` and `yarn workspace web test`
# passed whatever the workspace's test script ran: the selector was read as the script's name or
# skipped as an option, so no package.json was opened. The workspaces are now found (every
# package.json at or under the nearest folder that declares workspaces), the selector is matched
# against each one's name and folder, and the script is judged in each folder it selects, with the
# words after its name. A selector that is a pattern, or a run of every workspace, judges them all.
printf '%s\n' '{"name": "web", "scripts": {"test": "node ../scripts/run-tests.js tests/job.spec.js",' \
  '"lint": "node ../scripts/run-tests.js tests/quiet.spec.js"}}' > "$P/web/package.json"
printf '%s\n' '{"name": "@fx/api", "scripts": {"test": "node ../../scripts/run-tests.js tests/job.spec.js"}}' > "$P/packages/api/package.json"
printf '%s\n' '{"name": "@fx/quiet", "scripts": {"test": "node ../../scripts/run-tests.js tests/quiet.spec.js",' \
  '"runner": "node ../../scripts/run-tests.js"}}' > "$P/packages/quiet/package.json"
for w in web packages/api packages/quiet; do cp "$P/tests/quiet.spec.js" "$P/$w/tests/quiet.spec.js"; done
printf '%s\n' 'const { test } = require("@playwright/test");' 'const { alert } = require("../../lib/alert");' \
  'test("runs", () => alert("x"));' > "$P/web/tests/job.spec.js"
printf '%s\n' 'const { test } = require("@playwright/test");' 'const { alert } = require("../../../lib/alert");' \
  'test("runs", () => alert("x"));' > "$P/packages/api/tests/job.spec.js"
RUN_IN="$P/web"
each read_refused "#3251 the yardstick: the workspace's script is refused run in its own folder" "alert.js" 3<<'EOF'
npm run test
pnpm test
yarn test
EOF
RUN_IN="$P"
each read_refused "#3251 the yardstick: and run there by a folder option" "alert.js" 3<<'EOF'
npm --prefix web run test
pnpm -C web test
EOF
each read_refused "#3251 a workspace's script that runs a spec reaching code that posts is refused through a selector" "alert.js" 3<<'EOF'
pnpm --filter web test
pnpm --filter=web test
pnpm -F web test
pnpm --filter web run test
pnpm --filter @fx/api test
pnpm --filter api test
pnpm --filter './packages/*' test
pnpm --filter ./web test
pnpm --filter '@fx/*' test
pnpm --filter web --filter @fx/quiet test
pnpm --filter '...web' test
pnpm -r test
pnpm --recursive run test
npm -w web run test
npm --workspace web run test
npm --workspace=web test
npm run test -w web
npm test --workspace=web
npm run test --workspaces
npm run test -ws
npm -w packages/api run test
npm -w packages run test
yarn workspace web test
yarn workspace web run test
yarn workspace @fx/api test
yarn workspaces foreach -A run test
yarn workspaces foreach --all --parallel run test
yarn workspaces run test
EOF
run_here "pnpm --filter web test"
says "#3251 and the refusal names the workspace" "in the workspace web"
each read_refused "#3251 and the words after the script's name are handed to it there" "alert.js" 3<<'EOF'
pnpm --filter @fx/quiet runner ../api/tests/job.spec.js
npm -w packages/quiet run runner -- ../api/tests/job.spec.js
yarn workspace @fx/quiet runner ../api/tests/job.spec.js
EOF
RUN_IN="$P/packages/quiet"
each read_refused "#3251 and from another workspace's folder" "alert.js" 3<<'EOF'
pnpm --filter web test
yarn workspace web test
npm -w web run test
EOF
RUN_IN="$P"
each allowed "#3251 a workspace's script that reaches nothing that posts still passes through a selector" 3<<'EOF'
pnpm --filter web lint
pnpm -F web run lint
pnpm --filter @fx/quiet test
pnpm --filter quiet test
pnpm --filter ./packages/quiet test
pnpm -r lint
pnpm --filter nosuch test
pnpm --filter web install
pnpm --filter @fx/quiet runner tests/quiet.spec.js
npm -w web run lint
npm run lint -w web
npm -w packages/quiet run test
npm --workspace=@fx/quiet test
npm run lint --workspaces
npm -w web install
yarn workspace web lint
yarn workspace @fx/quiet test
yarn workspace @fx/quiet runner tests/quiet.spec.js
yarn workspace web add left-pad
yarn workspaces foreach -A run lint
EOF
# More entries under the workspace root than the walk reads: the workspaces cannot be listed, so a
# selector cannot be matched, and the typed command is refused as unread.
B="$T/b3251"
mkdir -p "$B/web" "$B/big"
printf '%s\n' '{"name": "big", "workspaces": ["web"]}' > "$B/package.json"
printf '%s\n' '{"name": "web", "scripts": {"test": "node run.js"}}' > "$B/web/package.json"
printf '%s\n' 'console.log(1);' > "$B/web/run.js"
python3 -c '
import os, sys
for n in range(60):
    d = os.path.join(sys.argv[1], "d%02d" % n)
    os.makedirs(d)
    for m in range(110):
        open(os.path.join(d, "f%03d" % m), "w").close()
' "$B/big"
RUN_IN="$B"; run_here "pnpm --filter web test"
read_refused "#3251 a workspace root too large to list is refused typed, as unread"
says "#3251 and the refusal says the workspaces could not be listed" "could not be listed"
RUN_IN="$B/web"; run_here "pnpm test"
allowed "#3251 and the script run in its own folder there passes as before"

echo
echo "slack drafts only: a shell whose code xargs builds from its input is read (claude-config#3251)"

# Measured 2026-11-18 (#3229's left open list): `cat posts.sh | xargs -0 bash -c` and `cat posts.sh |
# xargs -I{} bash -c {}` passed, and so did `echo posts.sh | xargs bash`, where the input names the
# script. xargs puts its input into the command it runs. Where what feeds it can be read, that
# command is now put together and judged. Where it cannot, the typed command is refused only when
# the input becomes the code or names what runs; a fixed script handed arguments nobody can read is
# judged as before.
S="$T/s3251"
mkdir -p "$S"
printf '%s\n' "$POST" > "$S/posts.sh"
printf '%s\n' "$POST" > "$S/posts"
printf '%s\n' 'echo ok' > "$S/ok.sh"
printf '%s\n' 'echo ok' > "$S/ok"
printf '%s\n' 'import urllib.request' 'urllib.request.urlopen("https://slack.com/api/chat.postMessage", data=b"text=hi")' > "$S/post.py"
printf '%s\n' 'print("ok")' > "$S/ok.py"
printf '%s\n' 'posts.sh' > "$S/list-posts.txt"
printf '%s\n' 'ok.sh' > "$S/list-ok.txt"
printf '%s\n' 'sort list-ok.txt | xargs bash' > "$S/xargs-unread.sh"
RUN_IN="$S"
each read_refused "#3251 a shell whose code or script comes from what xargs reads is refused where that posts" 3<<'EOF'
cat posts.sh | xargs -0 bash -c
cat posts.sh | xargs -I{} bash -c {}
cat posts.sh | xargs -I{} bash -c "{}"
cat posts.sh | xargs -I{} sh -c 'true; {}'
cat posts.sh | xargs -I % sh -c %
cat posts.sh | xargs -J % sh -c %
cat posts.sh | xargs -0 -I{} bash -c {}
xargs -0 bash -c < posts.sh
cat list-posts.txt | xargs bash
cat list-posts.txt | xargs -n1 bash
cat list-posts.txt | xargs -P4 -n 1 bash
xargs bash < list-posts.txt
echo posts.sh | xargs bash
printf '%s\n' posts.sh | xargs -n 1 sh
cat list-posts.txt | xargs -I{} bash {}
cat list-posts.txt | xargs -I{} bash ./{}
cat list-posts.txt | xargs env bash
echo post.py | xargs python3
echo post.py | xargs -I{} python3 {}
EOF
each read_refused "#3251 and where what xargs reads cannot be read, the typed command is refused as unread" "cannot be read" 3<<'EOF'
ls *.sh | xargs -n1 bash
find . -name "*.sh" | xargs bash
sort list-ok.txt | xargs -I{} sh -c "wc -l {}"
sort ok.sh | xargs -0 bash -c
sort list-ok.txt | xargs python3
EOF
each allowed "#3251 xargs putting together a command that posts nothing still passes" 3<<'EOF'
cat ok.sh | xargs -0 bash -c
cat ok.sh | xargs -I{} bash -c {}
cat ok.sh | xargs -I{} sh -c 'true; {}'
cat list-ok.txt | xargs bash
cat list-ok.txt | xargs -n1 bash
xargs bash < list-ok.txt
echo ok.sh | xargs bash
cat list-ok.txt | xargs -I{} bash {}
cat list-ok.txt | xargs -I{} sh -c "wc -l {}"
echo ok.py | xargs python3
cat list-posts.txt | xargs wc -l
cat list-posts.txt | xargs -I{} cat {}
cat posts.sh | xargs echo
ls | xargs -n1 bash ok.sh
ls | xargs sh -c 'echo "$@"' _
ls | xargs -I{} sh -c 'echo "$1"' _ {}
ls | xargs python3 ok.py
bash xargs-unread.sh
EOF

echo
echo "slack drafts only: a shell or an interpreter handed its input by the path that names it is read (claude-config#3251)"

# Measured 2026-11-18 (#3229's left open list): `cat posts.sh | bash /dev/stdin` and `cat posts.sh |
# source /dev/stdin` passed where `cat posts.sh | bash` is refused. /dev/stdin, /dev/fd/0 and
# /proc/self/fd/0 name the program's own input, so the program is judged as one reading its input.
each read_refused "#3251 a program handed its input by a path is refused where that input posts" 3<<'EOF'
cat posts.sh | bash /dev/stdin
cat posts.sh | sh /dev/fd/0
cat posts.sh | zsh /dev/stdin
cat posts.sh | bash /proc/self/fd/0
bash /dev/stdin < posts.sh
cat posts.sh | source /dev/stdin
source /dev/stdin < posts.sh
. /dev/stdin < posts.sh
cat posts.sh | . /dev/fd/0
cat post.py | python3 /dev/stdin
python3 /dev/stdin < post.py
bash /dev/fd/3 3< posts.sh
bash /dev/fd/3 3<posts.sh
cat posts.sh | (true; bash /dev/stdin)
cat posts.sh | env bash /dev/stdin
EOF
each read_refused "#3251 and where that input cannot be read, the typed command is refused as unread" "cannot be read" 3<<'EOF'
sort posts.sh | bash /dev/stdin
sort ok.sh | source /dev/stdin
exec 7< posts.sh; bash /dev/fd/7
EOF
each allowed "#3251 a program handed a harmless input by that path, or a program that runs none of it, still passes" 3<<'EOF'
cat ok.sh | bash /dev/stdin
bash /dev/stdin < ok.sh
cat ok.sh | source /dev/stdin
source /dev/stdin < ok.sh
. /dev/stdin < ok.sh
cat ok.py | python3 /dev/stdin
bash /dev/fd/3 3< ok.sh
cat posts.sh | wc -l /dev/stdin
cat posts.sh | cat /dev/stdin
cat posts.sh | bash ok.sh /dev/stdin
echo hi > /dev/stdout
EOF

echo
echo "slack drafts only: a shell started through a variable or a broken up name is read as the shell it is (claude-config#3251)"

# Measured 2026-11-18 (#3229's left open list): `$SHELL posts` and `$SHELL < posts` passed, and so
# did `b\ash posts` and `b''ash < posts` with a file of no extension, which the wrapper never sent
# to the rule. $SHELL, $BASH, $ZSH_NAME, $0 in a typed command, and `$(which bash)` name a shell;
# the command is judged as that shell given the same words.
each read_refused "#3251 a shell named through a variable, a lookup or a broken up name is refused run on a file that posts" 3<<'EOF'
$SHELL posts
$SHELL posts.sh
"$SHELL" posts
${SHELL} posts
${SHELL:-/bin/sh} posts.sh
$SHELL < posts
$SHELL <posts
cat posts.sh | $SHELL
$SHELL -c "bash posts.sh"
$BASH posts
$ZSH_NAME posts
$0 posts
$(which bash) posts
$(command -v zsh) posts
`which sh` posts
"$(which bash)" posts
env $SHELL posts
exec $SHELL posts
true; $SHELL posts
b\ash posts
b''ash posts
b''ash < posts
'bash' posts
ba"sh" posts
EOF
each allowed "#3251 the same spellings run on a file that posts nothing, or naming no shell, still pass" 3<<'EOF'
$SHELL ok
$SHELL ok.sh
"$SHELL" ok
${SHELL} ok
$SHELL < ok
cat ok.sh | $SHELL
$SHELL -c "echo hi"
$SHELL --version
$BASH ok
$0 ok
$(which bash) ok
`which sh` ok
b\ash ok
b''ash ok
'bash' ok
echo $SHELL
echo "$SHELL posts"
$EDITOR posts
EOF

echo
echo "slack drafts only: a line read from a file and then run as a command is read (claude-config#3251)"

# Measured 2026-11-18 (#3229's left open list): `cat posts.sh | { read -r l; $l; }` passed. A
# command named by a variable that read, mapfile or readarray fills runs what was read, and one
# named by `$(cat file)` runs the file's text, so what feeds it is read as commands.
each read_refused "#3251 a command that is a line read from a file that posts is refused" 3<<'EOF'
cat posts.sh | { read -r l; $l; }
read -r l < posts.sh; $l
while read -r l; do $l; done < posts.sh
cat posts.sh | while read l; do $l; done
while IFS= read -r l; do "$l"; done < posts.sh
read -r a b < posts.sh; $a $b
cat posts.sh | (read l; ${l})
mapfile -t L < posts.sh; "${L[@]}"
read -r l <<< "$(cat posts.sh)"; $l
$(cat posts.sh)
`cat posts.sh`
$(<posts.sh)
"$(cat posts.sh)"
true && $(cat posts.sh)
EOF
each read_refused "#3251 and where what is read cannot be read here, the typed command is refused as unread" "cannot be read" 3<<'EOF'
sort posts.sh | { read -r l; $l; }
sort ok.sh | while read -r l; do $l; done
$(sort ok.sh)
EOF
each allowed "#3251 a line read from a file that posts nothing, or read and not run, still passes" 3<<'EOF'
cat ok.sh | { read -r l; $l; }
read -r l < ok.sh; $l
while read -r l; do $l; done < ok.sh
cat ok.sh | while read l; do $l; done
$(cat ok.sh)
`cat ok.sh`
cat posts.sh | { read -r l; echo "$l"; }
cat posts.sh | while read l; do echo $l; done
while read -r f; do wc -l "$f"; done < list-posts.txt
sort ok.sh | while read -r f; do wc -l "$f"; done
read -r l; echo $l
EOF

echo
echo "slack drafts only: a substitution written with a backslash in a double quoted string is read (claude-config#3251)"

# Measured 2026-11-18 (#3229's left open list): in `bash -c "echo \$(bash posts.sh)"` the outer
# shell hands the inner one `echo $(bash posts.sh)`, which runs posts.sh. The shared reader keeps
# the backslash, so the substitution was text to every reading. The string is now also judged as
# the inner shell gets it.
each read_refused "#3251 a substitution escaped for the inner shell is refused where what it runs posts" 3<<'EOF'
bash -c "echo \$(bash posts.sh)"
bash -c "echo \`bash posts.sh\`"
sh -c "x=\$(cat posts.sh); eval \"\$x\""
eval "echo \$(bash posts.sh)"
bash -c "\$SHELL posts"
bash -c "cat posts.sh | \$SHELL"
bash -c "bash -c \"echo \\\$(bash posts.sh)\""
zsh -c "true && \$(cat posts.sh)"
env bash -c "echo \$(bash posts.sh)"
EOF
run_here 'bash -c "echo \$(sort ok.sh | bash)"'
read_refused "#3251 and one whose inner command reads what cannot be read is refused typed, as unread"
each allowed "#3251 the same spellings running nothing that posts still pass" 3<<'EOF'
bash -c "echo \$(bash ok.sh)"
bash -c "echo \`bash ok.sh\`"
bash -c "echo \$HOME"
bash -c "echo \$(date)"
eval "echo \$(bash ok.sh)"
bash -c "\$SHELL ok"
bash -c "echo \"\$(cat posts.sh)\""
EOF
# A string that also holds a variable the outer shell fills in: taking its quotes off alone would
# leave `$DIR` inside the single quotes the string writes, a path no reading can work out, where the
# inner shell is handed the folder. Seen on the first build of this reading, which refused this
# repository's own test-pr-review.sh for `bash -c ". '$DIR/lib/merge-turn.sh' && .
# '$DIR/lib/merge-phase.sh' && mp_reviews_busy \$(date +%s)"`. The variable is filled in with the
# value the gate works out for it; where it works none out, a script on disk is left as before.
printf '%s\n' 'f() { echo ok; }' > "$S/lib-ok.sh"
printf '%s\n' 'DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"' \
  'busy(){ bash -c ". '"'"'$DIR/lib-ok.sh'"'"' && . '"'"'$DIR/lib-ok.sh'"'"' && f \$(date +%s)"; }' \
  'busy' > "$S/mixed-ok.sh"
printf '%s\n' 'D=.' 'bash -c "cd $D && echo \$(bash posts.sh)"' > "$S/mixed-posts.sh"
each allowed "#3251 a string mixing a variable of the outer shell with an escaped substitution that posts nothing passes" 3<<'EOF'
bash mixed-ok.sh
D=.; bash -c ". '$D/lib-ok.sh' && f \$(date +%s)"
EOF
each read_refused "#3251 and one whose escaped substitution runs what posts is refused" 3<<'EOF'
bash mixed-posts.sh
D=.; bash -c "cd $D && echo \$(bash posts.sh)"
EOF

echo
echo "slack drafts only: a string a one line function hands a shell is read as that shell gets it (claude-config#3252)"

# The shared reader now passes a function's header over (#3252), so the first command of a body
# written on the header's own line is read, and with it the commands of a string it hands a shell.
# Read as written, the string of `busy(){ bash -c ". '$DIR/lib-ok.sh' && f"; }` sources a file named
# $DIR/lib-ok.sh from a folder nobody knows, so every script holding such a line was refused:
# mixed-ok.sh above, and six helpers of this repository's own suites. Before #3252 nobody read that
# string at all. In a script on disk it is now read as the shell it is handed to gets it, with the
# outer shell's variables filled in (sh_inner_text, the reading #3251 wrote), where the gate works
# every one of them out and can follow the text that gives. Anywhere else the reader's commands
# stand, as they did before this: a variable not worked out, a body's second command, a body over
# several lines, the same string at a script's top level or typed.
printf '%s\n' "f() { $POST; }" > "$S/lib-posts.sh"
cat > "$S/fn-plain-ok.sh" <<'EOF'
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
busy(){ bash -c ". '$DIR/lib-ok.sh' && f"; }
function idle { sh -c ". '$DIR/lib-ok.sh'; f"; }
busy; idle
EOF
cat > "$S/fn-plain-posts.sh" <<'EOF'
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
busy(){ bash -c ". '$DIR/lib-posts.sh' && f"; }
busy
EOF
cat > "$S/fn-mixed-posts.sh" <<'EOF'
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
busy(){ bash -c ". '$DIR/lib-posts.sh' && f \$(date +%s)"; }
busy
EOF
cat > "$S/fn-unknown.sh" <<'EOF'
busy(){ bash -c ". '$NOWHERE/lib-ok.sh' && f"; }
busy
EOF
cat > "$S/fn-handed.sh" <<'EOF'
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
busy(){ bash -c ". '$DIR/lib-ok.sh' && . \"\$0/lib-ok.sh\" && f" "$DIR"; }
busy
EOF
cat > "$S/fn-second.sh" <<'EOF'
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
busy(){ true; bash -c ". '$DIR/lib-ok.sh' && f \$(date +%s)"; }
busy
EOF
cat > "$S/fn-lines.sh" <<'EOF'
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
busy() {
  bash -c ". '$DIR/lib-ok.sh' && f \$(date +%s)"
}
busy
EOF
cat > "$S/fn-then-posts.sh" <<'EOF'
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
busy(){ bash -c ". '$DIR/lib-ok.sh' && f"; bash "$DIR/posts.sh"; }
busy
EOF
cat > "$S/fn-line-after-posts.sh" <<'EOF'
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
busy(){ bash -c ". '$DIR/lib-ok.sh' && f"; }
bash "$DIR/posts.sh"
EOF
cat > "$S/top-mixed-posts.sh" <<'EOF'
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash -c ". '$DIR/lib-posts.sh' && f \$(date +%s)"
EOF
run_here 'bash fn-plain-ok.sh'
allowed "#3252 a script whose one line functions source a file that posts nothing by the outer shell's variable passes"
run_here 'bash fn-plain-posts.sh'
read_refused "#3252 and one whose function sources a file that posts is refused"
says "#3252 and the refusal is a finding that it posts, from the file the variable names" "sends a request to chat.postMessage"
says "#3252 and it names the file" "lib-posts.sh"
each read_refused "#3252 control: what was refused before the reader fix is refused still" 3<<'EOF'
bash fn-mixed-posts.sh
bash fn-second.sh
bash fn-lines.sh
bash fn-then-posts.sh
bash fn-line-after-posts.sh
bash top-mixed-posts.sh
bash -c ". '$DIR/lib-ok.sh' && . '$DIR/lib-ok.sh' && f \$(date +%s)"
bash -c ". '$DIR/lib-posts.sh' && f \$(date +%s)"
D=.; busy(){ bash -c ". '$D/lib-posts.sh' && f \$(date +%s)"; }; busy
busy(){ bash -c ". '$DIR/lib-ok.sh' && f \$(date +%s)"; }; busy
EOF
each read_refused "#3252 where a variable is not worked out, or the text the shell gets cannot be followed, the reader's commands stand" "a path the gate cannot work out" 3<<'EOF'
bash fn-unknown.sh
bash fn-handed.sh
EOF

echo
echo "slack drafts only: in a script on disk these readings refuse only what posts (claude-config#3251)"

# Each reading here puts a command together and reads it as a line of its own, which knows none of
# the script's variables or of the words a -c string is handed. Seen on the first push of this
# branch, where the whole repository scan refused this repository's own test-merge-target.sh for
# `"$BASH" -c '. "$0/lib/merge-target.sh"; ...' "$HOOK_DIR"`: read as a line, the string's $0 is
# nobody's, so the file it sources could not be worked out. In a script on disk a reading that only
# fails to read something is dropped, and one that finds a post stands.
printf '%s\n' 'HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"' \
  'out="$("$BASH" -c '"'"'. "$0/lib-ok.sh"; f'"'"' "$HOOK_DIR" 2>/dev/null)"' \
  '$SHELL -c '"'"'. "$1/lib-ok.sh"; f'"'"' _ "$HOOK_DIR"' > "$S/named-ok.sh"
printf '%s\n' '"$BASH" -c '"'"'bash posts.sh'"'"' "$0"' > "$S/named-posts.sh"
run_here 'bash named-ok.sh'
allowed "#3251 a script whose shell, named by a variable, sources a file by the words its string is handed passes"
run_here 'bash named-posts.sh'
read_refused "#3251 and one whose string runs what posts is refused"
# A first word made of two substitutions is a path built from what they print, never text run as
# commands, so it is judged as it was before (lessons review of the first push).
run_here '$(pwd)/$(basename ok.sh)'
allowed "#3251 a program whose path is built from two substitutions is not read as a substitution run as a command"

echo
echo "slack drafts only: a quoted pattern handed to a program that is no runner is that program's own text (claude-config#3251)"

# Found by the sweep of this Mac's past commands, 2026-11-19: the first build expanded every pattern
# handed to any program, and seven harmless commands were newly refused. This repository's own
# tests/test-undated-measurements.sh runs `bash "$root/payload/hooks/lib/repo-files.sh" "$root"
# '*.md'`, a pathspec for git: its matches were read as files bash may run, and CLAUDE.md, which
# names an endpoint, made the whole suite a command that posts. A quoted pattern is expanded only
# for a package a launcher or a package script runs, which expands it itself; written bare, the
# shell expands it for any program, and the files are judged as if written out.
printf '%s\n' 'Call chat.postMessage to send.' 'Run `bash posts.sh` to send it.' > "$S/notes.md"
printf '%s\n' 'root="$1"' 'found="$(bash "$root/lib/list.sh" "$root" '"'"'*.md'"'"' 2>/dev/null)"' > "$S/scan-md.sh"
each allowed "#3251 a quoted pattern handed to a script is not expanded" 3<<'EOF'
bash scan-md.sh
bash "$NOWHERE/list.sh" . '*.md'
python3 "$NOWHERE/list.py" '*.md' 'x[0]'
bash "$NOWHERE/find.sh" . -maxdepth 1 -name 'post*'
EOF
run_here 'bash "$NOWHERE/list.sh" notes.md'
WRITTEN_OUT="$RC"
run_here 'bash "$NOWHERE/list.sh" *.md'
if [ "$RC" -eq "$WRITTEN_OUT" ]; then check "#3251 the same pattern written bare is judged as its matches written out are (exit $WRITTEN_OUT)" ok
else check "#3251 the same pattern written bare is judged as its matches written out are" "written out exit $WRITTEN_OUT, as a pattern exit $RC"; fi

# The two whole repository scans a push waits on, judged as a session runs them. The sweep's own
# command of 2026-11-19 running both was refused by the first build over the first, and judged
# again after that fix the gate crashed on the second. A crash shows the end of what it printed,
# where the error is.
# The scans live in the checkout, found by the one shared test (lib/checkout-root.sh, #1663); the
# installed copy of this suite has none beside it and judges nothing here.
REPO="$(bash "$DIR/lib/checkout-root.sh" "$DIR/.." 2>/dev/null || true)"
if [ -n "$REPO" ] && [ -f "$REPO/tests/test-undated-measurements.sh" ] && [ -f "$REPO/tests/test-hang-wait-suites-gate.sh" ]; then
  for scan in tests/test-undated-measurements.sh tests/test-hang-wait-suites-gate.sh; do
    RUN_IN="$REPO"; run_here "bash $REPO/$scan"; RUN_IN="$S"
    case "$ERR" in
      *"could not judge"*|*Traceback*) check "#3251 a session running $scan is judged, not a crash" "the gate crashed: ...${ERR: -900}" ;;
      *) allowed "#3251 a session running $scan is not refused" ;;
    esac
  done
  # And both in one command from another folder, with what a session adds around them, as the
  # sweep's command was.
  run_here "bash $REPO/tests/test-undated-measurements.sh > u.txt 2>&1; echo \"exit=\$?\"; tail -1 u.txt; bash $REPO/tests/test-hang-wait-suites-gate.sh > h.txt 2>&1; echo \"exit=\$?\"; grep \"^FAIL\" h.txt | cut -c1-500; tail -1 h.txt"
  case "$ERR" in
    *"could not judge"*|*Traceback*) check "#3251 a session running both scans in one command is judged, not a crash" "the gate crashed: ...${ERR: -900}" ;;
    *) allowed "#3251 a session running both scans in one command is not refused" ;;
  esac
fi

echo

echo "passed: $pass, failed: $fail"

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"

[ "$fail" -eq 0 ]
