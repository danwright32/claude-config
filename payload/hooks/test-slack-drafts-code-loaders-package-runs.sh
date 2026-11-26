#!/usr/bin/env bash
# Tests for lib/program-runs.py's package_run as the Slack drafts gate reads it: a launcher's package
# run beside a folder or a file of the package's name (claude-config#3069), a launcher handed a local
# package folder by path (#3083), and a package script judged with the words after its name (#3143).
#
# test-slack-drafts-code-loaders.sh held every case of these readers, 2,287 checks, until on
# 2026-11-25 its slowest run on GitHub's runners (485 s) was 81 percent of the line the suite cost
# guard draws at half of run-all-tests.sh's 1,200 second wall limit (L315). Its sections are now
# five suites, dealt by their measured cost and kept together where one section makes the fixtures
# another reads (claude-config#3624): test-slack-drafts-code-loaders.sh itself, -data-names,
# -package-runs, -python and -shell-input. Every check is as it was, and a comment saying "above"
# or "below" means in whichever of the five holds it. Every other judgement of the gate is in
# test-slack-drafts-only-gate.sh and the five suites split from it (#3575).
#
# The world they all run in (the gate under test, the throwaway folder and its judgement cache,
# POST) is lib/slack-drafts-gate-harness.sh, the one place each of them takes it from. The helper
# functions are the one thing each holds a copy of, below, because the gate reads functions only
# where they are called; test-slack-drafts-gate-helper-copies.sh holds the copies equal. A case is
# driven the same way in all of them: a hook payload piped into slack-drafts-only-gate.sh, exit 0
# allowed and 2 refused, the reason on stderr.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib/slack-drafts-gate-harness.sh" || {
  echo "FAIL: $(basename "$0"): lib/slack-drafts-gate-harness.sh is missing, so there is no gate to run and no world to run it in. Refusing to run."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}

# The helpers every case is driven through, copied as they are into each of the five suites: the
# gate knows a shell function only where the text calling it defines it (lib/unknown-program.py,
# #3304), so with these in a sourced file it would read `run_bash "<a command that posts>"` as an
# unknown program running that command, and refuse a plain run of this suite.
pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

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
run_tool() { run_raw "$(payload "$1" "$2")"; }
run_bash() { run_raw "$(payload Bash "$(bash_input "$1")")"; }

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

echo "slack drafts only: a launcher's package run is read as one beside a folder or a file of the same name (claude-config#3069)"

# Found by the #3050 builder on 2026-11-16: package_run (lib/program-runs.py) answered "not a package"
# for a spec naming anything on disk, so beside a folder named vitest `npx vitest run posts.test.ts`
# was read as a path. A path holding no / is read as nothing at all (a bare name is no file the shell
# or a launcher runs from the directory), so the test file the package was handed was never opened,
# and an endpoint in its arguments was not seen either. No launcher reads such a word as a file: npm
# takes a word for a path only where it starts with . / or ~, or holds a / outside a scope. So a
# package spec is always read as the package, and as the file of that name as well where there is
# one, the call refused where either reading refuses. A word that can only be a path (./x) was read as
# the file alone, and since #3083 (the section below) only where it names a script. Measured through this wrapper on main at 2963c2b: every command in the first list
# below passed but `npx @acme/tool --method chat.postMessage`, which was refused as a path run with an
# endpoint in its arguments, and every command in the list with no folder was refused.
PB="$T/p3069/beside"; PN="$T/p3069/alone"
mkdir -p "$PB/vitest" "$PB/tool" "$PB/@acme/tool" "$PN"
for side in "$PB" "$PN"; do
  printf '%s\n' 'import { it } from "vitest";' 'it("adds", () => {});' > "$side/quiet.test.ts"
  printf '%s\n' 'import { it } from "vitest";' 'it("posts", () => fetch("https://slack.com/api/chat.postMessage"));' > "$side/posts.test.ts"
  printf '%s\n' 'import { it } from "vitest";' 'import { post } from "./poster";' 'it("posts", () => post("hi"));' > "$side/imports-poster.test.ts"
  printf '%s\n' 'export const post = (t: string) => fetch("https://slack.com/api/chat.postMessage", { body: t });' > "$side/poster.ts"
  printf '%s\n' '{"text": "hi", "url": "https://slack.com/api/chat.postMessage"}' > "$side/msg.json"
  printf '%s\n' '{"text": "hi"}' > "$side/quiet.json"
done
: > "$PB/filetool"  # a file of the package's name, as the folders vitest, tool and @acme/tool are
printf '%s\n' '#!/bin/sh' 'echo quiet' > "$PB/@acme/quietdisk"
printf '%s\n' '#!/bin/sh' 'curl https://hooks.slack.com/services/T0/B0/x' > "$PB/@acme/ondisk"
printf '%s\n' '#!/bin/sh' 'echo quiet' > "$PB/runner"
printf '%s\n' '#!/bin/sh' 'curl https://hooks.slack.com/services/T0/B0/x' > "$PB/poster"
run_pb() { run_raw "$(payload Bash "$(bash_input "$1")" "$PB")"; }
run_pn() { run_raw "$(payload Bash "$(bash_input "$1")" "$PN")"; }
# Beside a folder, or a file, of the package's name: the package is handed a test file naming an
# endpoint, one importing a module that posts, a data file naming one, or an endpoint itself.
for runs in "npx vitest run posts.test.ts" "npx vitest run imports-poster.test.ts" "npx -y vitest run posts.test.ts" \
  "npm exec -- vitest run posts.test.ts" "npm x vitest run posts.test.ts" "pnpm dlx vitest run posts.test.ts" \
  "yarn dlx vitest run posts.test.ts" "bunx vitest run posts.test.ts" "pnpx vitest run posts.test.ts" \
  "npx tool msg.json" "npx tool --url https://hooks.slack.com/services/T0/B0/x" "npx @acme/tool msg.json" \
  "npx @acme/tool --method chat.postMessage" "npx filetool msg.json" "npx @acme/quietdisk msg.json" \
  "printf '%s\\n' 'quiet' > made && npx made msg.json"; do
  run_pb "$runs"
  read_refused "#3069 a package run beside a folder or a file of its name is still read as the package: $runs"
done
run_pb "npx vitest run posts.test.ts"
says "#3069 beside a folder of its name the refusal names the package" "the package vitest, run by npx,"
says "#3069 beside a folder of its name the refusal names the test file it was handed" "posts.test.ts"
BESIDE_SAYS="${ERR//"$PB"/}"
run_pb "npx vitest run imports-poster.test.ts"
says "#3069 beside a folder of its name a test file's imports are followed to the module that posts" "poster"
# The folder decides nothing: with none there the same commands are refused, in the same words.
for runs in "npx vitest run posts.test.ts" "npx vitest run imports-poster.test.ts" "npm exec -- vitest run posts.test.ts" \
  "npx tool msg.json" "npx tool --url https://hooks.slack.com/services/T0/B0/x" "npx @acme/tool msg.json"; do
  run_pn "$runs"
  read_refused "#3069 the same package run with no folder of its name is refused (the control): $runs"
done
run_pn "npx vitest run posts.test.ts"
if [ "${ERR//"$PN"/}" = "$BESIDE_SAYS" ]; then check "#3069 the refusal reads the same with a folder of the package's name and with none" ok
else check "#3069 the refusal reads the same with a folder of the package's name and with none" "beside: ${BESIDE_SAYS:0:200}, alone: ${ERR:0:200}"; fi
# And it refuses nothing more than the package reading does: handed nothing naming an endpoint, the
# run passes on both sides.
for runs in "npx vitest run quiet.test.ts" "npx vitest --version" "npm exec -- vitest run quiet.test.ts" \
  "pnpm dlx vitest run quiet.test.ts" "npx tool quiet.json" "npx @acme/tool quiet.json"; do
  run_pb "$runs"
  allowed "#3069 a package run beside a folder of its name, handed nothing naming an endpoint, passes: $runs"
  run_pn "$runs"
  allowed "#3069 the same package run with no folder of its name passes (the control): $runs"
done
run_pb "npx filetool quiet.json"
allowed "#3069 a package run beside a file of its name, handed nothing naming an endpoint, passes"
# The file of that name is still read as well, as before #3069: a script on disk that posts, or one
# this command wrote, is refused as that script even where the package is handed nothing.
for runs in "npx @acme/ondisk quiet.json" \
  "printf '%s\\n' '#!/bin/sh' 'curl https://hooks.slack.com/services/T0/B0/x' > @acme/made && npx @acme/made quiet.json"; do
  run_pb "$runs"
  read_refused "#3069 a package shaped word naming a script that posts is still read as that script too: $runs"
done
run_pb "npx @acme/ondisk quiet.json"
says "#3069 and the refusal is the script's, in the words it had before" "the script @acme/ondisk runs a command that posts"
# A path naming a script is read as the file alone, where the path reading is the right one:
# the gate reads the script, so a quiet one handed a data file naming an endpoint passes, which a
# package (code the gate cannot read) handed the same file does not, and one that posts is refused as
# the script it is.
run_pb "npx ./runner msg.json"
allowed "#3069 a path run through a launcher is read as the script there, not as a package: a quiet script handed a data file"
run_pb "npx runner msg.json"
read_refused "#3069 the same word with no ./ is a package, whatever file has its name"
run_pb "npx ./poster"
read_refused "#3069 a path naming a script that posts, run through a launcher, is refused as that script"
case "$ERR" in *"the package"*) check "#3069 a path's refusal does not call the script a package" "stderr: ${ERR:0:300}" ;;
  *) check "#3069 a path's refusal does not call the script a package" ok ;; esac

echo
echo "slack drafts only: a launcher handed a local package folder runs that package (claude-config#3083)"

# Left by #3069, measured on main at 2963c2b: `npx ./vitest run posts.test.ts` beside a local package
# folder ./vitest was read as that path alone. A folder is no script, so nothing was read and the test
# file the package was handed was never opened. npm runs the package the folder holds (a word starting
# with . / or ~ that names no archive is a folder to it), so the run is read as a package run too:
# every file it is handed is judged against a program the gate cannot read. The same for every word a
# launcher is handed that is no package name and no script on disk: the folder it runs in (.), a
# folder an earlier command makes, a path naming nothing yet, an archive, and a GitHub shorthand
# (owner/repo). A script on disk is still read as the script it is, as #3069 left it.
printf '%s\n' '{"name": "vitest", "version": "1.0.0", "bin": "./cli.js"}' > "$PB/vitest/package.json"
printf '%s\n' '#!/usr/bin/env node' 'console.log("quiet")' > "$PB/vitest/cli.js"
printf '%s\n' '{"name": "tool", "version": "1.0.0", "bin": "./cli.js"}' > "$PB/tool/package.json"
printf '%s\n' '{"name": "here", "version": "1.0.0", "bin": "./cli.js"}' > "$PB/package.json"
ln -s vitest "$PB/linked"
: > "$PB/pkg.tgz"
for runs in "npx ./vitest run posts.test.ts" "npx ./vitest run imports-poster.test.ts" "npx -y ./vitest run posts.test.ts" \
  "npx ./vitest/ run posts.test.ts" "npx $PB/vitest run posts.test.ts" "npm exec -- ./vitest run posts.test.ts" \
  "npm x ./vitest run posts.test.ts" "pnpm dlx ./vitest run posts.test.ts" "yarn dlx ./vitest run posts.test.ts" \
  "bunx ./vitest run posts.test.ts" "pnpx ./vitest run posts.test.ts" "npx ./tool msg.json" \
  "npx ./tool --url https://hooks.slack.com/services/T0/B0/x" "npx . run posts.test.ts" "npx ./linked run posts.test.ts" \
  "npx ./pkg.tgz run posts.test.ts" "npx ./nothing-there run posts.test.ts" "npx acme/tool-repo run posts.test.ts" \
  "mkdir -p fresh && npx ./fresh run posts.test.ts"; do
  run_pb "$runs"
  read_refused "#3083 a launcher's run of a local package folder is read as a package run: $runs"
done
run_pb "npx ./vitest run posts.test.ts"
says "#3083 the refusal names the folder as the package the launcher runs" "the package ./vitest, run by npx,"
says "#3083 the refusal names the test file the package was handed" "posts.test.ts"
run_pb "npx ./vitest run imports-poster.test.ts"
says "#3083 a test file's imports are followed to the module that posts" "poster"
# It refuses nothing more than a package run does: handed nothing naming an endpoint, the run passes.
for runs in "npx ./vitest run quiet.test.ts" "npx ./vitest --version" "npm exec -- ./vitest run quiet.test.ts" \
  "pnpm dlx ./vitest run quiet.test.ts" "npx ./tool quiet.json" "npx . run quiet.test.ts" \
  "npx ./nothing-there run quiet.test.ts" "mkdir -p fresh && npx ./fresh run quiet.test.ts"; do
  run_pb "$runs"
  allowed "#3083 a launcher's run of a local package folder, handed nothing naming an endpoint, passes: $runs"
done
# The controls. A script on disk is read as the script it is, so a quiet one handed a data file naming
# an endpoint still passes (#3069's own case, run again here beside the folders), as does one an
# earlier command of the call writes; and a word the gate cannot work out is left as it was (#2683).
run_pb "npx ./runner msg.json"
allowed "#3083 a script on disk run through a launcher is still read as that script alone"
run_pb "printf '%s\\n' '#!/bin/sh' 'echo quiet' > made.sh && npx ./made.sh msg.json"
allowed "#3083 a script an earlier command writes, run through a launcher, is still read as that script alone"
run_pb 'npx "$SOMEWHERE/tool" msg.json'
allowed "#3083 a word the gate cannot work out is left as it was"

echo
echo "slack drafts only: a package script is judged with the words after its name (claude-config#3143)"

# Measured 2026-11-17 in a work repository: `npx playwright test --config c tests/x.spec.js` was refused,
# the spec's imports reaching a module that names the webhook, while `npm run test:node -- tests/x.spec.js`,
# whose script is that same `playwright test --config c`, passed. The words after a script's name were
# never read, so a file handed to a package script ran unjudged. npm, pnpm and yarn add those words to
# the end of the script's command, so the command is judged with them there as well as without, and a
# program the script names bare, which the package manager finds in node_modules/.bin, is read for the
# command they land in as npx reads it. Dan's decision, 2026-11-18: "Refuse both, then decide #3173".
P43="$T/p3143"
mkdir -p "$P43/tests" "$P43/scripts" "$P43/lib" "$T/q3143/tests"
for d in "$P43" "$T/q3143"; do
  printf '%s\n' '{"name": "fx", "version": "1.0.0", "scripts": {' \
    '"test:node": "playwright test --config playwright.node.config.js",' \
    '"test": "playwright test --config playwright.node.config.js",' \
    '"test:own": "node scripts/run-tests.js",' \
    '"check": "tsc --noEmit && playwright test",' \
    '"ci": "npm run test:node --",' \
    '"sub": "playwright test --config $(node scripts/noop.js)",' \
    '"env": "cross-env NODE_ENV=test playwright test",' \
    '"assign": "NODE_ENV=test playwright test",' \
    '"own:spec": "playwright test tests/job.spec.js",' \
    '"pretest:pre": "node scripts/run-tests.js", "test:pre": "node scripts/noop.js"}}' > "$d/package.json"
  printf '%s\n' 'module.exports = { testDir: "tests" };' > "$d/playwright.node.config.js"
  printf '%s\n' 'const { test } = require("@playwright/test");' 'test("adds", () => 1 + 1);' > "$d/tests/quiet.spec.js"
done
printf '%s\n' 'const url = process.env.SLACK_WEBHOOK;' \
  'async function alert(t) { await fetch(url, { method: "POST", body: JSON.stringify({ text: t }) }); }' \
  'module.exports = { alert };' > "$P43/lib/alert.js"
printf '%s\n' 'const { alert } = require("./alert");' 'module.exports = { report: (t) => alert(t) };' > "$P43/lib/report.js"
printf '%s\n' 'const { report } = require("../lib/report");' 'module.exports = { run: () => report("done") };' > "$P43/scripts/job.js"
printf '%s\n' 'const { test } = require("@playwright/test");' 'const { run } = require("../scripts/job");' 'test("runs", () => run());' \
  > "$P43/tests/job.spec.js"
# The project's own test runner, started by node, which runs each file it is handed, and a script
# that runs nothing it is handed.
printf '%s\n' 'const path = require("path");' 'for (const f of process.argv.slice(2)) require(path.resolve(f));' > "$P43/scripts/run-tests.js"
printf '%s\n' 'console.log(process.argv.length);' > "$P43/scripts/noop.js"
run_p43() { run_raw "$(payload Bash "$(bash_input "$1")" "$P43")"; }
# The two forms that were refused before and still are: the yardsticks every packager spelling is held to.
for runs in "npx playwright test --config playwright.node.config.js tests/job.spec.js" "node scripts/run-tests.js tests/job.spec.js"; do
  run_p43 "$runs"
  read_refused "#3143 the yardstick: a spec whose imports reach code that posts is refused started this way: $runs"
  says "#3143 and the refusal follows the imports to the module that posts: $runs" "alert.js"
done
# A bare runner handed the spec, in every spelling package() reads.
for runs in "npm run test:node -- tests/job.spec.js" "npm run-script test:node -- tests/job.spec.js" "npm run test:node tests/job.spec.js" \
  "npm test -- tests/job.spec.js" "npm --silent run test:node -- tests/job.spec.js" "npm --prefix $P43 run test:node -- tests/job.spec.js" \
  "pnpm run test:node tests/job.spec.js" "pnpm test:node tests/job.spec.js" "pnpm run test:node -- tests/job.spec.js" \
  "yarn test:node tests/job.spec.js" "yarn run test:node tests/job.spec.js" "cd $P43/tests && npm run test:node -- tests/job.spec.js"; do
  run_p43 "$runs"
  read_refused "#3143 a spec reaching code that posts is refused handed to a package script: $runs"
  says "#3143 and the refusal follows the imports to the module that posts: $runs" "alert.js"
  says "#3143 and it names the package script and the words after its name: $runs" "with the words after its name runs a command that posts: the package playwright, run by the package script test"
done
# The project's own runner started by node, the words landing in the last of two commands, a script
# that hands them on to another, one with a substitution before them, a runner behind cross-env or an
# assignment, and an option or another file before the file.
for runs in "npm run test:own -- tests/job.spec.js" "pnpm test:own tests/job.spec.js" "yarn test:own tests/job.spec.js" \
  "npm run check -- tests/job.spec.js" "npm run ci -- tests/job.spec.js" "pnpm test:node --headed tests/job.spec.js" \
  "npm run sub -- tests/job.spec.js" "npm run env -- tests/job.spec.js" "yarn assign tests/job.spec.js" \
  "npm run test:node -- --workers 1 tests/job.spec.js" "npm run test:node -- tests/quiet.spec.js tests/job.spec.js"; do
  run_p43 "$runs"
  read_refused "#3143 a spec reaching code that posts is refused in the other shapes a script takes: $runs"
  says "#3143 and the refusal follows the imports to the module that posts: $runs" "alert.js"
done
# What still passes: the same spellings handed a spec that reaches nothing that posts, only an option,
# or nothing at all (77 of the 478 runs measured on 2026-11-18 were handed only an option).
for runs in "npx playwright test --config playwright.node.config.js tests/quiet.spec.js" \
  "npm run test:node -- tests/quiet.spec.js" "npm run-script test:node -- tests/quiet.spec.js" "npm run test:node tests/quiet.spec.js" \
  "npm test -- tests/quiet.spec.js" "npm --silent run test:node -- tests/quiet.spec.js" "npm --prefix $P43 run test:node -- tests/quiet.spec.js" \
  "pnpm run test:node tests/quiet.spec.js" "pnpm test:node tests/quiet.spec.js" "pnpm run test:node -- tests/quiet.spec.js" \
  "yarn test:node tests/quiet.spec.js" "yarn run test:node tests/quiet.spec.js" "cd $P43/tests && npm run test:node -- tests/quiet.spec.js" \
  "npm run test:own -- tests/quiet.spec.js" "npm run check -- tests/quiet.spec.js" "npm run ci -- tests/quiet.spec.js" \
  "npm run sub -- tests/quiet.spec.js" "npm run env -- tests/quiet.spec.js" "yarn assign tests/quiet.spec.js" \
  "npm run test:node -- tests/quiet.spec.js > out.log 2>&1"; do
  run_p43 "$runs"
  allowed "#3143 a spec reaching nothing that posts still passes: $runs"
done
for runs in "npm run test:node -- --grep adds" "npm run-script test:node -- --headed" "npm test -- --reporter=list" \
  "npm --silent run test:node -- --workers 1" "npm --prefix $P43 run test:node -- --headed" "npm run test:node --silent" \
  "pnpm run test:node --headed" "pnpm test:node --grep adds" "pnpm run test:node -- --headed" "yarn test:node --headed" \
  "yarn run test:node --workers 1" "cd $P43/tests && npm run test:node -- --headed" "npm run test:own -- --watch" \
  "npm run check -- --headed" "npm run ci -- --headed"; do
  run_p43 "$runs"
  allowed "#3143 a package script handed only an option still passes: $runs"
done
for runs in "npm run test:node" "npm run-script test:node" "npm test" "npm --silent run test:node" "npm --prefix $P43 run test:node" \
  "pnpm run test:node" "pnpm test:node" "yarn test:node" "yarn run test:node" "cd $P43/tests && npm run test:node" \
  "npm run test:own" "npm run check" "npm run ci" "npm run test:pre" "npm run sub" "npm run env" "yarn assign"; do
  run_p43 "$runs"
  allowed "#3143 a package script handed nothing still passes: $runs"
done
# Only the words after the name are read as handed to a bare program: what the script's own command
# writes after it is judged as it is with nothing after the name, so an option, or a spec reaching
# nothing that posts, never changes the answer (lessons review at f916b1b: reading the whole command
# refused `npm run own:spec -- --headed` over the spec own:spec itself names, which plain `npm run
# own:spec` passed). The two are compared, so this holds whichever way that plain run is judged.
run_p43 "npm run own:spec"
plain_rc=$RC
for runs in "npm run own:spec -- --headed" "pnpm own:spec --workers 1" "yarn own:spec --grep adds" \
  "npm run own:spec -- tests/quiet.spec.js"; do
  run_p43 "$runs"
  if [ "$RC" -eq "$plain_rc" ]; then check "#3143 an option or a quiet spec after the name leaves the script's own words judged as before: $runs" ok
  else check "#3143 an option or a quiet spec after the name leaves the script's own words judged as before: $runs" "exit $RC against $plain_rc for npm run own:spec alone, stderr: ${ERR:0:300}"; fi
done
run_p43 "npm run own:spec -- tests/job.spec.js"
read_refused "#3143 and the same script handed the spec that reaches code that posts is refused"
# The words go to the script itself, never to its pre script: pretest:pre is the runner that runs what
# it is handed, and test:pre a script that runs nothing it is handed.
run_p43 "npm run test:pre -- tests/job.spec.js"
allowed "#3143 the words after the name are not handed to the pre script"
# In a project whose specs reach nothing that posts, a whole suite run passes as before.
for runs in "npm run test" "npm test" "npm run test:node" "npx playwright test --config playwright.node.config.js" \
  "npm test -- tests/quiet.spec.js"; do
  run_raw "$(payload Bash "$(bash_input "$runs")" "$T/q3143")"
  allowed "#3143 a project whose specs reach nothing that posts passes as before: $runs"
done

echo

sdg_harness_result
