#!/usr/bin/env bash
# Tests for lib/data-names.py (claude-config#2913), the Slack drafts gate's reading of an address
# only compared or listed, told from one sent to, and of a test file read the same way by npx vitest
# and the node_modules path. And lib/js-mocks.py (#2359): a test file's import of a module the same
# file replaces with vi.mock or jest.mock and a factory is not followed. And a module loaded through
# the test runner's own loaders, followed as an import (#3020). And lib/data-names.py again (#3050):
# the webhook's variable name where a JavaScript or TypeScript file only declares it, told from where
# it is read. And import text a test's matcher only compares, beside code that runs strings (#3146).
# They share the fixtures of the first section (a project with vitest in node_modules) and of the
# mocks section, so they are one suite.
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

echo "slack drafts only: an address held only as data, compared or listed, is told from one sent to (claude-config#2913)"

# Dan's decision of 2026-11-14 on #2913: teach the gate to tell a Slack posting address that is only
# compared against or listed (a refusal list of hosts in a guard's own code) from one that is sent to,
# with no exemption list, and to keep refusing any it cannot classify. A name counts as data only where
# it sits in a string that is an element of a list literal, an operand of a comparison, the argument of
# a test such as includes or startswith, or a regex pattern, or in a comment; and only where nothing in
# the program that holds it (the script, every module it reaches, and any other code run in the same
# process) can send a request or run code, since a list or a comparison can still feed a send.
D9="$T/d2913"
mkdir -p "$D9/src" "$D9/scripts" "$D9/py" "$D9/node_modules/.bin" "$D9/node_modules/vitest/dist"
printf '%s\n' '// Scripts may not post to Slack: hooks.slack.com and chat.postMessage are refused.' \
  'export const REFUSED_HOSTS = ["hooks.slack.com", "example.invalid"];' \
  'export const REFUSED_METHODS = new Set(["chat.postMessage", "chat.scheduleMessage"]);' \
  'export function refuses(url: string): boolean {' \
  '  const host = new URL(url).host;' \
  '  if (host === "hooks.slack.com" || url.includes("chat.postMessage")) return true;' \
  '  if (/hooks\.slack\.com/.test(url)) return true;' \
  '  return REFUSED_HOSTS.some((h) => host === h);' \
  '}' > "$D9/src/refuse.ts"
printf '%s\n' 'import { refuses } from "../src/refuse.ts";' 'import { readFileSync } from "node:fs";' \
  'const lines = readFileSync(process.argv[2], "utf8").split("\n");' 'console.log(lines.filter((l) => refuses(l)).length);' \
  > "$D9/scripts/count.ts"
printf '%s\n' 'import assert from "node:assert";' 'import { readFileSync } from "node:fs";' 'import { refuses } from "../src/refuse.ts";' \
  'const urls = JSON.parse(readFileSync("scripts/fixture.json", "utf8"));' 'for (const u of urls) assert.equal(refuses(u), true);' \
  > "$D9/scripts/refuse.test.ts"
printf '%s\n' '["https://example.invalid/a"]' > "$D9/scripts/fixture.json"
printf 'a\nb\n' > "$D9/data.txt"
# The same list, sent to: by the script that imports it, and by one that only compares and then sends.
printf '%s\n' 'import { REFUSED_HOSTS } from "../src/refuse.ts";' \
  'await fetch("https://" + REFUSED_HOSTS[0] + "/services/T0/B0/x", { method: "POST", body: "hi" });' > "$D9/scripts/send-listed.ts"
printf '%s\n' 'import { refuses } from "../src/refuse.ts";' 'const u = process.env.HOOK ?? "";' \
  'if (refuses(u)) await fetch(u, { method: "POST", body: "hi" });' > "$D9/scripts/send-compared.ts"
printf '%s\n' 'import { refuses } from "../src/refuse.ts";' 'import { execFileSync } from "node:child_process";' \
  'if (refuses(process.argv[2])) execFileSync("curl", ["-d", "hi", process.argv[2]]);' > "$D9/scripts/run-compared.ts"
# A loader run in the same process, able to run code, beside a script that holds the name only as data.
printf '%s\n' 'import { register } from "node:module";' 'register("./hooks.mjs", import.meta.url);' > "$D9/scripts/loader.mjs"
printf '%s\n' 'export async function load(u, c, next) { return next(u, c); }' > "$D9/scripts/hooks.mjs"
# Shapes that are not data: a string handed to a call, held in an object, indexed, or built into a URL.
printf '%s\n' 'console.log("https://hooks.slack.com/services/T0/B0/x");' > "$D9/scripts/arg.ts"
printf '%s\n' 'export const target = { url: "https://hooks.slack.com/services/T0/B0/x" };' > "$D9/src/object.ts"
printf '%s\n' 'import { target } from "../src/object.ts";' 'console.log(target);' > "$D9/scripts/object.ts"
printf '%s\n' 'const t: Record<string, number> = {};' 'console.log(t["chat.postMessage"]);' > "$D9/scripts/index.ts"
printf '%s\n' 'const id = process.argv[2];' 'console.log(`https://hooks.slack.com/services/${id}`);' > "$D9/scripts/template.ts"
printf '%s\n' 'const pick = (a: string, b: string) => b;' 'console.log(pick("a", "hooks.slack.com"));' > "$D9/scripts/call-args.ts"
run_d9() { run_raw "$(payload Bash "$(bash_input "$1")" "$D9")"; }
run_d9 "node --experimental-strip-types scripts/count.ts data.txt"
allowed "#2913 a script whose import names the host only in a refusal list, a comparison, a regex and a comment passes"
run_d9 "node --experimental-strip-types scripts/refuse.test.ts"
allowed "#2913 a single node test whose chain names the host only as data, reading a fixture, passes"
run_d9 "node --experimental-strip-types scripts/send-listed.ts"
read_refused "#2913 a script sending to an address taken from the refusal list is still refused"
says "#2913 the refusal names the module and what the script can do" "refuse.ts), which posts to Slack (it names hooks.slack.com"
run_d9 "node --experimental-strip-types scripts/send-compared.ts"
read_refused "#2913 a script that only compares an address against the host and then sends to it is still refused"
run_d9 "node --experimental-strip-types scripts/run-compared.ts https://hooks.slack.com/services/T0/B0/x"
read_refused "#2913 a script that compares then hands the address to a program is still refused"
run_d9 "node --experimental-strip-types --import ./scripts/loader.mjs scripts/count.ts data.txt"
read_refused "#2913 a loader able to run code in the same process as data only names is refused"
says "#2913 the refusal names the loader" "loader.mjs"
for s in arg object index template call-args; do
  run_d9 "node --experimental-strip-types scripts/$s.ts"
  read_refused "#2913 a name not compared or listed is refused even where nothing can send: $s"
done
# Python, read the same way: a set, a tuple, a comparison, startswith and a match case are data; a
# program that can send, or a name handed to a call, is not.
printf '%s\n' '"""Refuses any address on Slack."""' 'HOSTS = {"hooks.slack.com", "example.invalid"}' 'METHODS = ("chat.postMessage",)' \
  'def refuses(url):' '    if url == "https://hooks.slack.com/" or url.startswith("https://hooks.slack.com/"):' '        return True' \
  '    match url:' '        case "chat.postMessage":' '            return True' '    return any(h in url for h in HOSTS)' > "$D9/py/guard.py"
printf '%s\n' 'import sys' 'from guard import refuses' 'print(sum(refuses(l) for l in open(sys.argv[1])))' > "$D9/py/count.py"
printf '%s\n' 'import sys, urllib.request' 'from guard import HOSTS' \
  'urllib.request.urlopen("https://" + sorted(HOSTS)[0] + "/services/T0/B0/x", data=b"hi")' > "$D9/py/send.py"
printf '%s\n' 'print("https://hooks.slack.com/services/T0/B0/x")' > "$D9/py/arg.py"
run_d9 "python3 py/count.py data.txt"
allowed "#2913 a Python script importing a guard that names the host only as data passes"
run_d9 "python3 py/send.py"
read_refused "#2913 a Python script sending to a host taken from the guard's set is still refused"
run_d9 "python3 py/arg.py"
read_refused "#2913 a Python script handing the name to a call is still refused"
# Real sends in the same shapes are refused as before: the name sent to directly beside a list.
printf '%s\n' 'const HOSTS = ["hooks.slack.com"];' 'await fetch("https://hooks.slack.com/services/T0/B0/x", { method: "POST" });' > "$D9/scripts/both.ts"
run_d9 "node --experimental-strip-types scripts/both.ts"
read_refused "#2913 a script listing the host and also sending to it is refused"
says "#2913 the refusal names what it sends to" "posts to Slack (it names hooks.slack.com)"
# What a program prints or writes can carry a listed address to a sender in the same command, and a
# computed name reaches fetch unnamed, so each of these, sending for real, is refused (found probing
# the first build of this change, 2026-11-14).
printf '%s\n' 'console.log(["https://hooks.slack.com/services/T0/B0/x"][0]);' > "$D9/scripts/prints.ts"
printf '%s\n' 'import { writeFileSync } from "node:fs";' 'writeFileSync("u.txt", ["https://hooks.slack.com/services/T0/B0/x"][0]);' > "$D9/scripts/writes.ts"
printf '%s\n' 'const H = ["hooks.slack.com"];' 'globalThis["fe" + "tch"]("https://" + H[0] + "/services/T0/B0/x", { method: "POST" });' > "$D9/scripts/computed.ts"
printf '%s\n' 'const H = ["hooks.slack.com"];' 'const load = process["getBuiltin" + "Module"];' > "$D9/scripts/process-index.ts"
printf '%s\n' 'print(["https://hooks.slack.com/services/T0/B0/x"][0])' > "$D9/py/prints.py"
printf '%s\n' 'import { promises as p } from "node:fs";' 'const H = ["hooks.slack.com"];' \
  'await p["write" + "File"]("u.cfg", "url = https://" + H[0] + "/services/T0/B0/x");' > "$D9/scripts/computed-write.ts"
printf '%s\n' 'const H = ["hooks.slack.com", "example.invalid"];' 'for (let i = 0; i < H.length; i++) console.log(H[i].length);' > "$D9/scripts/var-index.ts"
for runs in "node scripts/computed-write.ts && curl -d hi -K u.cfg" "node scripts/var-index.ts"; do
  run_d9 "$runs"
  read_refused "#2913 a computed name other than a number or a string can reach a write, so it is refused: $runs"
done
run_d9 "node scripts/var-index.ts"
says "#2913 the refusal names the computed name" "by a computed name"
for runs in "node scripts/prints.ts | xargs curl -d hi" "curl -d hi \$(node scripts/prints.ts)" \
  "node scripts/prints.ts > u.txt; curl -d hi \$(cat u.txt)" "U=\`node scripts/prints.ts\`; curl -d hi \"\$U\"" \
  "node scripts/prints.ts | tail -1 | xargs curl -d hi" "python3 py/prints.py | xargs curl -d hi" \
  "node scripts/writes.ts" "node scripts/computed.ts" "node scripts/process-index.ts"; do
  run_d9 "$runs"
  read_refused "#2913 a listed address that can still reach a sender is refused: $runs"
done
# A module NODE_OPTIONS preloads shares the process with whatever node then runs, which can read what
# it leaves on the global object (lessons review at 73967ea), so a name it holds only as data is
# refused as before.
printf '%s\n' 'globalThis.H = ["hooks.slack.com"];' > "$D9/scripts/preload.mjs"
printf '%s\n' 'await fetch("https://" + globalThis.H[0] + "/services/T0/B0/x", { method: "POST" });' > "$D9/scripts/uses-preload.mjs"
run_d9 "NODE_OPTIONS='--import ./scripts/preload.mjs' node scripts/uses-preload.mjs"
read_refused "#2913 a module NODE_OPTIONS preloads, holding the host only as data, beside a script that sends, is refused"
says "#2913 the refusal names the preloaded module" "preload.mjs"
printf '%s\n' '#!/usr/bin/env bash' 'out=$(node scripts/prints.ts)' 'curl -d hi "$out"' > "$D9/scripts/captures.sh"
run_d9 "bash scripts/captures.sh"
read_refused "#2913 a script capturing what a program holding a listed address prints is refused"
printf '%s\n' '#!/usr/bin/env bash' 'node --experimental-strip-types scripts/count.ts data.txt' > "$D9/scripts/runs-count.sh"
run_d9 "bash scripts/runs-count.sh | xargs curl -d hi"
read_refused "#2913 a script's output piped on carries what the program inside it prints"
for runs in "node --experimental-strip-types scripts/count.ts data.txt 2>&1 | tail -20" \
  "node --experimental-strip-types scripts/count.ts data.txt > /dev/null && echo done" "bash scripts/runs-count.sh"; do
  run_d9 "$runs"
  allowed "#2913 output that only reaches the terminal, a filter or nowhere passes: $runs"
done

echo "slack drafts only: npx vitest and the node_modules path read a test file the same way (claude-config#2913)"

# Before this, `npx vitest run x.test.ts` judged the test file by its own text only (#2865), while
# `./node_modules/.bin/vitest run x.test.ts` followed its imports, so a test importing a module that
# posts passed one spelling and was refused by the other. A package a launcher runs counts as able to
# run what it is handed, so a file it is handed that says it is JavaScript, TypeScript or Python is now
# read as a script, its imports followed, by every launcher; one another program only may have
# rewritten is read as it is on disk, as before.
printf '%s\n' '#!/usr/bin/env node' "import './dist/cli.js'" > "$D9/node_modules/vitest/vitest.mjs"
printf '%s\n' "import { fork } from 'node:child_process'" 'for (const f of process.argv.slice(3)) fork(f)' > "$D9/node_modules/vitest/dist/cli.js"
ln -s ../vitest/vitest.mjs "$D9/node_modules/.bin/vitest"
printf '%s\n' 'export const post = (t: string) => fetch("https://hooks.slack.com/services/T0/B0/x", { method: "POST", body: t });' > "$D9/src/poster.ts"
printf '%s\n' 'import { it } from "vitest";' 'import { post } from "./poster";' 'it("posts", () => post("hi"));' > "$D9/src/poster.test.ts"
printf '%s\n' 'import { it } from "vitest";' 'it("adds", () => {});' > "$D9/src/quiet.test.ts"
for runs in "npx vitest run src/poster.test.ts" "./node_modules/.bin/vitest run src/poster.test.ts" "bunx vitest run src/poster.test.ts" \
  "pnpm dlx vitest run src/poster.test.ts" "npm exec -- vitest run src/poster.test.ts" "yarn dlx vitest run src/poster.test.ts"; do
  run_d9 "$runs"
  read_refused "#2913 a test importing a module that posts is refused by every spelling: $runs"
  says "#2913 and the refusal follows the import: $runs" "poster"
done
for runs in "npx vitest run src/quiet.test.ts" "./node_modules/.bin/vitest run src/quiet.test.ts" "pnpm dlx vitest run src/quiet.test.ts"; do
  run_d9 "$runs"
  allowed "#2913 the control: a quiet test passes by every spelling: $runs"
done
run_d9 "npx prettier --write src/quiet.test.ts >/dev/null && npx vitest run src/quiet.test.ts"
allowed "#2913 a test a formatter only may rewrite is still read as it is on disk when a package is handed it"
# A shell script handed to a package is still judged by its own text, as before: only a file that says
# it is JavaScript, TypeScript or Python is followed.
printf '%s\n' 'sh scripts/poster.sh' > "$D9/scripts/lint-me.sh"
printf '%s\n' 'curl -d hi https://hooks.slack.com/services/T0/B0/x' > "$D9/scripts/poster.sh"
run_d9 "npx shellcheck scripts/lint-me.sh"
allowed "#2913 a shell script handed to a package is not read as commands"

echo "slack drafts only: a test file's import of a module the same file mocks out is not followed (claude-config#2359)"

# A test runner never loads a module a test file replaces with vi.mock or jest.mock and a factory:
# the import gets the factory's object. In the probe of 2026-11-06, 7 test files in two personal
# repositories that imported a posting helper only to mock it were refused when run directly. Dan
# decided on 2026-11-15 to let that import through, and only that: a real unmocked import, a mock
# without a factory (automock loads the module), a factory handed the original, the original fetched
# by importActual or requireActual, a mock taken back, a mock of another path, a mock the gate cannot
# read, a mock inside a block (babel-jest lifts a jest.mock only to the top of its own block, so the
# file's imports run first), a file that is not a test file, and a test file node runs itself (where
# vi.mock and jest.mock replace nothing) each stay refused.
MK="$T/g2359"
mkdir -p "$MK/__tests__" "$MK/node_modules/.bin" "$MK/node_modules/vitest/dist" "$MK/node_modules/jest/bin"
printf '%s\n' "export function send() { fetch('https://slack.com/api/chat.postMessage'); }" > "$MK/posts.ts"
printf '%s\n' "export function send() { fetch('https://slack.com/api/chat.postMessage'); }" > "$MK/posts2.ts"
printf '%s\n' 'export const other = 1;' > "$MK/other.ts"
# The runners as D9's: a node script that starts each file it is handed.
printf '%s\n' '#!/usr/bin/env node' "import './dist/cli.js'" > "$MK/node_modules/vitest/vitest.mjs"
printf '%s\n' "import { fork } from 'node:child_process'" 'for (const f of process.argv.slice(3)) fork(f)' > "$MK/node_modules/vitest/dist/cli.js"
ln -s ../vitest/vitest.mjs "$MK/node_modules/.bin/vitest"
printf '%s\n' '#!/usr/bin/env node' "const { fork } = require('node:child_process')" 'for (const f of process.argv.slice(2)) fork(f)' > "$MK/node_modules/jest/bin/jest.js"
ln -s ../jest/bin/jest.js "$MK/node_modules/.bin/jest"
run_mk() { run_raw "$(payload Bash "$(bash_input "$1")" "$MK")"; }
MK_RUN="./node_modules/.bin/vitest run"
mk_case() { # mk_case <file name> <lines...>: judge $MK_RUN handed a file in $MK holding them
  local name="$1"
  shift
  printf '%s\n' "$@" 'console.log(1);' > "$MK/$name"
  run_mk "$MK_RUN $name"
}
mk_case a.test.ts 'import { send } from "./posts.ts";'
read_refused "#2359 the control: a test file's unmocked import of a module that posts is refused"
mk_case a.test.ts 'import { vi } from "vitest";' 'import { send } from "./posts.ts";' 'vi.mock("./posts.ts", () => ({ send: vi.fn() }));'
allowed "#2359 a vi.mock with a factory, written after the import it replaces"
MK_RUN="./node_modules/.bin/jest"
mk_case a.spec.ts 'jest.mock("./posts", function () { return { send: jest.fn() }; });' 'import { send } from "./posts.ts";'
allowed "#2359 a jest.mock with a function factory, written before, naming the same file another way, run by jest"
mk_case a.test.js 'jest.mock("./posts.ts", () => ({ send: jest.fn() }));' 'const { send } = require("./posts.ts");'
allowed "#2359 a require of a module jest.mock replaces, run by jest"
mk_case a.test.js 'const { send } = require("./posts.ts");' 'describe("x", () => {' '  jest.mock("./posts.ts", () => ({ send: jest.fn() }));' '});'
read_refused "#2359 a jest.mock inside a block, which babel-jest lifts only to the top of that block, is refused"
MK_RUN="npx vitest run"
mk_case a.test.ts 'import { vi } from "vitest";' 'import { send } from "./posts.ts";' 'vi.mock("./posts.ts", async () => ({ send: vi.fn() }));'
allowed "#2359 an async factory, handed to the runner by npx"
MK_RUN="./node_modules/.bin/vitest run"
mk_case a.test.ts 'import { send } from "./posts.ts";' 'describe("x", () => {' '  vi.mock("./posts.ts", () => ({ send: vi.fn() }));' '});'
read_refused "#2359 a vi.mock inside a block is refused too"
mk_case a.test.ts 'import { vi, beforeAll } from "vitest"' 'import { send } from "./posts.ts"' 'beforeAll(() => {})' 'vi.mock("./posts.ts", () => ({ send: vi.fn() }))'
allowed "#2359 a mock as its own statement in a file written without semicolons"
mk_case a.test.ts 'import { send } from "./posts.ts";' 'vi.mock<typeof import("./posts.ts")>("./posts.ts", () => ({ send: vi.fn() }));'
allowed "#2359 a mock with a type argument"
mk_case __tests__/a.ts 'import { send } from "../posts.ts";' 'vi.mock("../posts.ts", () => ({ send: vi.fn() }));'
allowed "#2359 a file in a __tests__ folder"
mk_case a.ts 'import { send } from "./posts.ts";' 'vi.mock("./posts.ts", () => ({ send: vi.fn() }));'
read_refused "#2359 a file that is not a test file is unchanged: its mocked import is still followed"
for runs in "node a.test.ts" "npx tsx a.test.ts" "bash -c 'node a.test.ts'"; do
  mk_case a.test.ts 'import { vi } from "vitest";' 'import { send } from "./posts.ts";' 'vi.mock("./posts.ts", () => ({ send: vi.fn() }));'
  run_mk "$runs"
  read_refused "#2359 a test file run by node itself, where the mock replaces nothing, is refused: $runs"
done
printf '%s\n' "const { fork } = require('node:child_process')" 'for (const f of process.argv.slice(2)) fork(f)' > "$MK/my-vitest-runner.js"
run_mk "node my-vitest-runner.js a.test.ts"
read_refused "#2359 a script handed the file that only has the runner's name inside its own is not the runner"
# A script of the repository's own that takes the runner's name is not the runner as installed.
mkdir -p "$MK/vitest"
cp "$MK/my-vitest-runner.js" "$MK/jest.js"
cp "$MK/my-vitest-runner.js" "$MK/vitest/run.js"
for runs in "node jest.js a.test.ts" "node vitest/run.js a.test.ts"; do
  run_mk "$runs"
  read_refused "#2359 a script outside node_modules named after the runner is not the runner: $runs"
done
for line in 'vi.mock("./posts.ts");' \
  'jest.mock("./posts.ts");' \
  'vi.mock("./posts.ts", { spy: true });' \
  'vi.mock("./posts.ts", async (importOriginal) => ({ ...(await importOriginal()) }));' \
  'vi.mock("./posts.ts", factory);' \
  'vi.doMock("./posts.ts", () => ({}));' \
  'jest.doMock("./posts.ts", () => ({}));' \
  'vi.mock("./other.ts", () => ({}));' \
  'vi.mock(`./${name}.ts`, () => ({}));' \
  'vi.mock(path, () => ({}));' \
  'vi.mock(import("./posts.ts"), () => ({}));' \
  '// vi.mock("./posts.ts", () => ({}));' \
  'const s = '"'"'vi.mock("./posts.ts", () => ({}))'"'"';' \
  'vi.mock("./posts.ts", () => ({}));  vi.mock("./posts.ts");' \
  'vi.mock("./posts.ts", () => ({}));  const real = await vi.importActual("./posts.ts");' \
  'jest.mock("./posts.ts", () => ({}));  const real = jest.requireActual("./posts");' \
  'vi.mock("./posts.ts", () => ({}));  const real = await vi.importActual(p);' \
  'vi.mock("./posts.ts", () => ({}));  vi.unmock("./posts.ts");' \
  'jest.mock("./posts.ts", () => ({}));  jest.unmock("./posts.ts");' \
  'jest.mock("./posts.ts", () => ({}));  jest.dontMock("./posts.ts");' \
  'vi.mock("./posts.ts", () => ({}));  vi.doUnmock("./posts.ts");' \
  'vi.mock("./posts.ts", () => ({}));  const m = await vi.importMock("./posts.ts");' \
  'jest.mock("./posts.ts", () => ({}));  const m = jest.createMockFromModule("./posts.ts");' \
  'vi.mock("./posts.ts", () => ({}));  const real = await vi.importActual<typeof import("./posts.ts")>("./posts.ts");' \
  'jest.mock("./posts.ts", () => ({}));  const real = jest.requireActual<typeof import("./posts")>("./posts");' \
  'vi.mock("./posts.ts", () => ({}));  const load = vi.importActual;' \
  'const setup = () => vi.mock("./posts.ts", () => ({}));' \
  'if (process.env.MOCK) vi.mock("./posts.ts", () => ({}));' \
  'process.env.MOCK && vi.mock("./posts.ts", () => ({}));' \
  'void vi.mock("./posts.ts", () => ({}));' \
  'vi.mock("./posts.ts", () => ({}));  const real = await vi["importActual"]("./posts.ts");' \
  'vi.mock("./posts.ts", () => ({}));  const { importActual } = vi;' \
  'vi.mock("./posts.ts", () => ({}));  const k = "import" + "Actual";  const real = await vi[k]("./posts.ts");' \
  'vi.mock("./posts.ts", () => ({}));  const v = vi;' \
  'vi.mock("./posts.ts", () => ({}));  const fns = Object.values(vi);' \
  'vi.mock("./posts.ts", () => ({}));  const g = globalThis["vi"];' \
  'import { vi as v } from "vitest";  vi.mock("./posts.ts", () => ({}));' \
  'vi.mock("./posts.ts", () => ({}));  const m = vi.mock;'; do
  mk_case a.test.ts 'import { send } from "./posts.ts";' "$line"
  read_refused "#2359 a test file importing a module that posts stays refused beside: $line"
done
mk_case a.test.ts 'import { send } from "./posts.ts";' 'import { send as s2 } from "./posts2.ts";' 'vi.mock("./posts.ts", () => ({}));'
read_refused "#2359 a second module that posts, not mocked, is still followed"
says "#2359 the refusal names the unmocked module" "posts2.ts"
# Through the test runner's launcher, as the refusals of 2026-11-06 were met.
printf '%s\n' 'import { it, vi } from "vitest";' 'import { post } from "./poster";' 'vi.mock("./poster", () => ({ post: vi.fn() }));' \
  'it("posts", () => post("hi"));' > "$D9/src/mocks-poster.test.ts"
for runs in "npx vitest run src/mocks-poster.test.ts" "./node_modules/.bin/vitest run src/mocks-poster.test.ts"; do
  run_d9 "$runs"
  allowed "#2359 a test file mocking the poster it imports passes: $runs"
done
run_d9 "npx vitest run src/poster.test.ts"
read_refused "#2359 the same test without the mock is still refused (the control)"

echo
echo "slack drafts only: a module loaded through the test runner's own loaders is followed as an import (claude-config#3020)"

# vi.importActual, jest.requireActual and the runners' other loaders (importMock, requireMock,
# createMockFromModule, genMockFromModule) each load the module they name: the original, or the
# original read to build a mock of its shape. A test file reaching a module that posts only through
# one of them, with no import, require or import() of it, passed: the gate followed none of those
# calls. Each is now followed as an import is, and one whose path is not written out is read as a
# require of a computed name is.
MK_RUN="./node_modules/.bin/vitest run"
mk_case b.test.ts 'import { vi } from "vitest";' 'const real = await vi.importActual("./other.ts");'
allowed "#3020 the control: a module that posts nothing, loaded by vi.importActual, passes"
mk_case b.test.ts 'import { vi } from "vitest";' 'const real = await vi.importActual("./posts.ts");'
read_refused "#3020 a module that posts, loaded only by vi.importActual, is followed and refused"
says "#3020 and the refusal names the module" "posts.ts"
mk_case b.test.ts 'const real = await vi.importActual<typeof Posts>("./posts.ts");'
read_refused "#3020 and with a type argument naming no import"
mk_case b.test.ts 'const real = await vi.importActual(`./posts.ts`);'
read_refused "#3020 and with the path in a template"
# A type argument written as an object type, or over several lines, holds { } = ; and line breaks,
# which the pattern left out, so the call matched nothing and the module was not followed (lessons
# review at d06d7aa).
mk_case b.test.ts 'const real = await vi.importActual<{ send: () => void }>("./posts.ts");'
read_refused "#3020 and with an object type as the type argument"
mk_case b.test.ts 'const real = await vi.importActual<{' '  send: (text: string) => Promise<void>;' '}>("./posts.ts");'
read_refused "#3020 and with one written over several lines"
mk_case b.test.ts 'const real = await vi.importActual<{ send: () => void }>("./other.ts");'
allowed "#3020 the control: the same type argument on a module that posts nothing passes"
mk_case b.test.ts 'const m = await vi.importMock("./posts.ts");'
read_refused "#3020 and by vi.importMock, which loads the module to mock its shape"
MK_RUN="./node_modules/.bin/jest"
for call in 'jest.requireActual("./posts")' 'jest.requireMock("./posts.ts")' 'jest.createMockFromModule("./posts.ts")' \
  'jest.genMockFromModule("./posts.ts")' 'jest . requireActual ( "./posts.ts" )'; do
  mk_case b.test.js "const m = $call;"
  read_refused "#3020 and by jest's loader: $call"
done
mk_case b.test.js 'const m = jest.requireActual("./other.ts");'
allowed "#3020 the control: jest.requireActual of a module that posts nothing passes"
mk_case b.test.js '// const m = jest.requireActual("./posts.ts");'
allowed "#3020 a loader call in a comment loads nothing"
mk_case b.test.js "const s = 'jest.requireActual(\"./posts.ts\")';"
allowed "#3020 nor one inside an ordinary string"
mk_case b.test.ts 'import { vi } from "vitest";' 'const real = await vi.importActual("./posts.ts");'
run_mk "node b.test.ts"
read_refused "#3020 the call is followed whatever runs the file"

echo
echo "slack drafts only: a file that only declares the webhook's name is not one that posts (claude-config#3050)"

# On 2026-11-15, in a work repository whose worker has a Slack module, three runs of test files by
# name were refused: one file's fixtures held the word slack_webhook, one imported a module that
# names it, and one imported a route reaching the module that sends. The first two name the variable
# without reading it. slack_webhook is the name projects keep a webhook in, never an address, so a
# file posts through it only by reading what is kept under it. Two uses read nothing and are now
# left out: the name as an object literal's key set to null, undefined or a string that is no
# address anyone receives at, and the name as a member of an interface or a type alias, which is
# erased. Every other use (a member read, a destructuring, a string, a key set to anything else)
# refuses as before, and so does the third run, which reaches a module that reads the name and
# sends. These files are written from the issue's words: the work repository is not on this Mac.
printf '%s\n' 'export async function notify(env: { SLACK_WEBHOOK_URL?: string }, text: string) {' \
  '  if (env.SLACK_WEBHOOK_URL) await fetch(env.SLACK_WEBHOOK_URL, { method: "POST", body: text });' '}' > "$MK/hook.ts"
printf '%s\n' 'import { notify } from "./hook.ts";' 'export const run = (env: object, text: string) => notify(env, text);' > "$MK/engine.ts"
printf '%s\n' 'import { run } from "./engine.ts";' 'export const handle = (env: object) => run(env, "hi");' > "$MK/route.ts"
printf '%s\n' 'export interface Env {' '  DB: unknown;' '  SLACK_WEBHOOK_URL?: string;' '}' \
  'export type Team = { id: string; slack_webhook: string | null };' 'export const DEFAULTS = { retries: 3 };' > "$MK/env.ts"
printf '%s\n' 'export const rank = (rows: { id: string }[]) => rows.map((r) => r.id);' > "$MK/rank.ts"
MK_RUN="./node_modules/.bin/vitest run"
mk_case c.test.ts 'import { expect, it } from "vitest";' 'import { rank } from "./rank.ts";' 'it("ranks", () => expect(rank([{ id: "t1" }])).toEqual(["t1"]));'
allowed "#3050 the control: a test file naming nothing passes"
mk_case c.test.ts 'import { expect, it } from "vitest";' 'import { rank } from "./rank.ts";' \
  'const team = { id: "t1", slack_webhook: null };' 'it("ranks", () => expect(rank([team])).toEqual(["t1"]));'
allowed "#3050 a test file whose fixture row holds the name as a key set to null passes"
mk_case c.test.ts 'import { expect, it } from "vitest";' 'import { rank } from "./rank.ts";' \
  'const env = { DB: null, SLACK_WEBHOOK_URL: "https://hooks.example.test/T0/B0/x" };' 'it("ranks", () => expect(rank([])).toEqual([]));'
allowed "#3050 and as a key of a worker's env set to an address reserved for tests"
for value in 'undefined' '""' "'fake-hook'" '"http://localhost:8787/hook"' '"https://example.com/hook"' '"https://hooks.slack.invalid/x"'; do
  mk_case c.test.ts "const team = { id: 't1', slack_webhook: $value, name: 'a' };"
  allowed "#3050 a key set to a value that is no address anyone receives at passes: $value"
done
mk_case c.test.ts 'const rows = [' '  {' '    id: "t1",' '    "slack_webhook": null,' '  },' '  { id: "t2", slack_webhook_url: undefined },' '];'
allowed "#3050 a quoted key, and keys over several lines, pass"
mk_case c.test.ts 'import { expect, it } from "vitest";' 'import { DEFAULTS } from "./env.ts";' 'it("retries", () => expect(DEFAULTS.retries).toBe(3));'
allowed "#3050 a test file importing a module that names it only in an interface and a type alias passes"
printf '%s\n' 'import { DEFAULTS } from "./env.ts";' 'console.log(DEFAULTS);' > "$MK/d.test.ts"
run_mk "./node_modules/.bin/vitest run c.test.ts d.test.ts"
allowed "#3050 and with several test files named in one run"
# Handed to the runner by a launcher, as the three runs of the issue were, in $D9. Since #3069 the
# gate reads `npx vitest` as the package run even beside a folder named vitest.
cp "$MK/env.ts" "$MK/hook.ts" "$D9/src/"
printf '%s\n' 'import { expect, it } from "vitest";' 'import { DEFAULTS } from "./env";' \
  'const team = { id: "t1", slack_webhook: null };' 'it("retries", () => expect(DEFAULTS.retries).toBe(3));' > "$D9/src/declares.test.ts"
printf '%s\n' 'import { it } from "vitest";' 'const env = { DB: null, SLACK_WEBHOOK_URL: "https://hooks.example.test/T0/B0/x" };' \
  'it("adds", () => {});' > "$D9/src/env-fixture.test.ts"
printf '%s\n' 'import { it } from "vitest";' 'import { notify } from "./hook";' \
  'const env = { SLACK_WEBHOOK_URL: "https://hooks.example.test/T0/B0/x" };' 'it("notifies", () => notify(env, "hi"));' > "$D9/src/notifies.test.ts"
for runs in "npx vitest run src/declares.test.ts" "pnpm dlx vitest run src/declares.test.ts" "bunx vitest run src/env-fixture.test.ts" \
  "./node_modules/.bin/vitest run src/declares.test.ts" "npx vitest run src/declares.test.ts src/env-fixture.test.ts src/quiet.test.ts"; do
  run_d9 "$runs"
  allowed "#3050 test files that only declare the name pass, handed to the runner by a launcher: $runs"
done
for runs in "npx vitest run src/notifies.test.ts" "pnpm dlx vitest run src/notifies.test.ts" "./node_modules/.bin/vitest run src/notifies.test.ts" \
  "npx vitest run src/declares.test.ts src/notifies.test.ts" "npx vitest run src/notifies.test.ts src/declares.test.ts"; do
  run_d9 "$runs"
  read_refused "#3050 a test file importing the module that reads the name and sends is still refused: $runs"
  says "#3050 and the refusal names that module: $runs" "hook"
done
MK_RUN="./node_modules/.bin/jest"
mk_case c.spec.ts 'import { DEFAULTS } from "./env.ts";' 'const team = { id: "t1", slack_webhook: null };'
allowed "#3050 and run by jest"
run_mk "node c.spec.ts"
allowed "#3050 the reading is of the file's text, so it is the same whatever runs the file"
# The third run of the issue reaches a module that reads the name and sends, so it is refused still,
# through every loader the gate follows, with a declared name beside the loader hiding nothing.
MK_RUN="./node_modules/.bin/vitest run"
mk_case c.test.ts 'import { expect, it } from "vitest";' 'import { handle } from "./route.ts";' 'it("handles", () => expect(handle({})).toBeDefined());'
read_refused "#3050 a test file whose route reaches the module that reads the name and sends is still refused"
says "#3050 and the refusal names that module" "hook.ts"
says "#3050 and the name it reads" "it names SLACK_WEBHOOK"
for target in ./hook.ts ./posts.ts; do
  for line in "import { x } from \"$target\";" "import \"$target\";" "export * from \"$target\";" "const m = await import(\"$target\");" \
    "const m = require(\"$target\");" "const m = await vi.importActual(\"$target\");" "const m = await vi.importMock(\"$target\");" \
    "const m = await vi.importActual<{ send: () => void }>(\"$target\");" "const m = jest.requireActual(\"$target\");" \
    "const m = jest.requireMock(\"$target\");" "const m = jest.createMockFromModule(\"$target\");" "const m = jest.genMockFromModule(\"$target\");"; do
    mk_case c.test.ts 'const env = { SLACK_WEBHOOK_URL: "https://hooks.example.test/x", slack_webhook: null };' "$line"
    read_refused "#3050 a module that can post is still refused beside a declared name, reached by: $line"
  done
done
run_mk "./node_modules/.bin/vitest run d.test.ts c.test.ts"
read_refused "#3050 and named after a file that only declares the name"
# Every use that reads the name, or sets it to something the gate cannot see is no address, refuses
# as before, in the test file itself and in a module it imports.
for line in 'const hook = env.SLACK_WEBHOOK_URL;' \
  'const { SLACK_WEBHOOK_URL } = process.env;' \
  'const { slack_webhook: hook } = row;' \
  'const env = { SLACK_WEBHOOK_URL: process.env.HOOK };' \
  'const env = { SLACK_WEBHOOK_URL: hook };' \
  'const env = { SLACK_WEBHOOK_URL };' \
  'const env = { SLACK_WEBHOOK_URL: "https://hooks.slack.com/services/T0/B0/x" };' \
  'const env = { SLACK_WEBHOOK_URL: "https://hooks.slack-gov.com/services/T0/B0/x" };' \
  'const env = { SLACK_WEBHOOK_URL: "https://example.test@hooks.slack-gov.com/services/T0/B0/x" };' \
  'const env = { SLACK_WEBHOOK_URL: "hooks.slack-gov.com/services/T0/B0/x" };' \
  'const env = { SLACK_WEBHOOK_URL: "https://example.test/" + id };' \
  'const env = { SLACK_WEBHOOK_URL: `https://${host}/x` };' \
  'const env = { SLACK_WEBHOOK_URL: "https://example.test/\x2e" };' \
  'const env = { SLACK_WEBHOOK_URL: null as unknown as string };' \
  'const env = { SLACK_WEBHOOK_URL: null ?? hook };' \
  'const env = { SLACK_WEBHOOK_URL: null, ...process.env };' \
  'const env = { SLACK_WEBHOOK_URL: "https://example.test/x", DB: { rows: [] }, ...real };' \
  'const pick = { select: { slack_webhook: true } };' \
  'const pick = { slack_webhook: 1 };' \
  'const key = "SLACK_WEBHOOK_URL";' \
  'const hook = on ? slack_webhook : null;' \
  'const hook = [on ? a : b, slack_webhook][1];' \
  'function send(a, slack_webhook) { return fetch(slack_webhook); }' \
  'process.env.SLACK_WEBHOOK_URL = "https://example.test/x";' \
  'function f(env: { SLACK_WEBHOOK_URL: string }) { return env; }' \
  'class Env { SLACK_WEBHOOK_URL = process.env.HOOK; }' \
  'const type = { SLACK_WEBHOOK_URL: string };' \
  'const env = { SLACK_WEBHOOK_URL: null };  const hook = env.SLACK_WEBHOOK_URL;' \
  'interface Env { SLACK_WEBHOOK_URL?: string }  const hook = env.SLACK_WEBHOOK_URL;' \
  'interface Env { SLACK_WEBHOOK_URL: typeof hook }' \
  'interface Env { SLACK_WEBHOOK_URL: string }  const env = { SLACK_WEBHOOK_URL: string };'; do
  mk_case c.test.ts "$line"
  read_refused "#3050 a use that is no bare declaration stays refused: $line"
  says "#3050 as a file naming what posts: $line" "c.test.ts posts to Slack (it names "
  printf '%s\n' "$line" 'export const DEFAULTS = { retries: 3 };' > "$MK/uses.ts"
  mk_case c.test.ts 'import { DEFAULTS } from "./uses.ts";'
  read_refused "#3050 and in a module the test file imports: $line"
  says "#3050 named as that module: $line" "uses.ts), which posts to Slack (it names "
done
mk_case c.test.ts 'const base = { DB: null };' 'const env = { ...base, SLACK_WEBHOOK_URL: "https://example.test/x", nested: { ...base } };'
allowed "#3050 a spread before the key, or inside a value after it, leaves the key as written"
# A fixture file can hold the name once per row, so the reading is judged at that size too: 5,000
# rows, each read by stepping back to its own row's brace and never by a copy of the file.
{
  printf '%s\n' 'export const rows = ['
  for ((i = 0; i < 5000; i++)); do printf '  { id: "t%d", slack_webhook: null, name: "team %d" },\n' "$i" "$i"; done
  printf '%s\n' '];'
} > "$MK/rows.ts"
mk_case c.test.ts 'import { rows } from "./rows.ts";'
allowed "#3050 a fixture module holding the name in each of 5,000 rows is read in time and passes"
# And written on one line, as a generated fixture is, where anything read per name back to the start
# of its line is read 5,000 times over the whole file.
{
  printf '%s' 'export const rows = ['
  for ((i = 0; i < 5000; i++)); do printf '{ id: "t%d", slack_webhook: null, name: "team %d" },' "$i" "$i"; done
  printf '%s\n' '];'
} > "$MK/rows-line.ts"
mk_case c.test.ts 'import { rows } from "./rows-line.ts";'
allowed "#3050 and the same 5,000 rows on one line"
printf '%s\n' 'export const last = { id: "t5000", slack_webhook: process.env.HOOK };' >> "$MK/rows.ts"
mk_case c.test.ts 'import { rows } from "./rows.ts";'
read_refused "#3050 and one row among them set to something else is still found"
# A key built in brackets is no declared name. The name in a string inside brackets reads as a list's
# element, held only as data (#2913), which a runner able to send refuses as it always did.
mk_case c.test.ts 'const env = { ["SLACK_WEBHOOK_URL"]: process.env.HOOK };'
read_refused "#3050 a key computed from a string stays refused"
# A header and its { on two lines is not read as a type's: in JavaScript `type` and `interface` are
# names there, and the braces a block holding a label.
mk_case c.test.ts 'type' 'Env = { SLACK_WEBHOOK_URL: string };'
read_refused "#3050 a type alias whose header is split over lines is not read as one"
mk_case c.test.ts 'interface Env' '{ SLACK_WEBHOOK_URL: string }'
read_refused "#3050 nor an interface whose brace is on the next line"
# The other names are addresses, and a file holding one is judged as before whatever it is set to.
mk_case c.test.ts 'const methods = { "chat.postMessage": null, chat_postMessage: null };'
read_refused "#3050 a posting method as a key is not a declared name"
mk_case c.test.ts 'interface Hosts { "hooks.slack.com": string }'
read_refused "#3050 nor a webhook's host as a member of an interface"
# A shell script and a Python script are read as before: this reading is of JavaScript and TypeScript.
printf '%s\n' 'ENV = {"SLACK_WEBHOOK_URL": None}' > "$MK/names.py"
run_mk "python3 names.py"
read_refused "#3050 a Python script naming it is unchanged"
printf '%s\n' '#!/bin/bash' 'curl -d hi "$SLACK_WEBHOOK_URL"' > "$MK/send.sh"
run_mk "bash send.sh"
refused "#3050 a shell script sending to what the variable holds is refused"
run_mk "node -e 'const env = { SLACK_WEBHOOK_URL: null }; fetch(process.env.SLACK_WEBHOOK_URL)'"
refused "#3050 and code given inline"

echo
echo "slack drafts only: import text a test only compares is not followed beside code that runs strings (claude-config#3146)"

# Seen 2026-11-17 in a work repository: one test file run through vitest was refused as importing
# ./src/index.ts, a module the gate cannot find, though it imports four node builtins, vitest and two
# sibling scripts; the text was only an argument to expect(...).toContain(). Import text inside a
# string has not been followed since #2484, except where any file the walk reaches names something
# that can run a string as code (JS_SINK, JS_DYNAMIC), when every string is followed, and a test of a
# build script names child_process. A string that is the whole argument of toBe, toContain or toMatch
# on expect(...) is now left out even there, since the matcher only compares it, unless the file
# binds expect any other way or a file in the walk names a way to change what a matcher does.
D46="$T/d3146"
mkdir -p "$D46/scripts" "$D46/node_modules/.bin" "$D46/node_modules/vitest/dist"
printf '%s\n' '#!/usr/bin/env node' "import './dist/cli.js'" > "$D46/node_modules/vitest/vitest.mjs"
printf '%s\n' "import { fork } from 'node:child_process'" 'for (const f of process.argv.slice(3)) fork(f)' > "$D46/node_modules/vitest/dist/cli.js"
ln -s ../vitest/vitest.mjs "$D46/node_modules/.bin/vitest"
printf '%s\n' 'export default {};' > "$D46/vitest.config.mjs"
printf '%s\n' 'export function makeEntry(p) {' "  return \`export * from '\${p}';\\n\`;" '}' > "$D46/scripts/entry.mjs"
printf '%s\n' 'import { readdirSync } from "node:fs";' 'export const listFiles = (d) => readdirSync(d);' > "$D46/scripts/list.mjs"
printf '%s\n' 'export const post = (t) => fetch("https://slack.com/api/chat.postMessage", { method: "POST", body: t });' > "$D46/scripts/poster.mjs"
cat > "$D46/scripts/base.txt" <<'JS'
import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { test, expect } from "vitest";
import { makeEntry } from "./entry.mjs";
import { listFiles } from "./list.mjs";

// export * from './src/commented.ts'
/* import { gone } from "./src/block-comment.ts"; */
const here = path.dirname(fileURLToPath(import.meta.url));
test("the entry re-exports the source", () => {
  execFileSync("node", [path.join(here, "entry.mjs")]);
  const source = makeEntry("./src/index.ts");
  expect(source).toContain("export * from './src/index.ts'");
  expect(source).not.toContain(`import { gone } from "./src/missing.ts"`);
  expect(source.trim()).toBe('export * from "./src/other.ts";');
  expect(readFileSync(path.join(here, "entry.mjs"), "utf8")).toMatch("import x from './src/x.ts'");
  expect(listFiles(here).length).toBeGreaterThan(0);
});
JS
run_46() { run_raw "$(payload Bash "$(bash_input "$1")" "$D46")"; }
vt46() { # vt46 <file name> <lines...>: the base test with these lines after it
  local name="$1"
  shift
  { cat "$D46/scripts/base.txt"; printf '%s\n' "$@"; } > "$D46/scripts/$name"
}
vt46 a.node.test.mjs
for runs in "./node_modules/.bin/vitest run -c vitest.config.mjs scripts/a.node.test.mjs" \
  "node scripts/entry.mjs && ./node_modules/.bin/vitest run -c vitest.config.mjs scripts/a.node.test.mjs > out.txt 2>&1" \
  "node scripts/a.node.test.mjs"; do
  run_46 "$runs"
  allowed "#3146 import text a matcher only compares, in strings, a template and comments, beside child_process: $runs"
done
# The controls. A real import of a module that posts or is not there, each way it can be written,
# on its own line or after such a string on the same line, is still followed.
VT46="./node_modules/.bin/vitest run -c vitest.config.mjs"
n46=0
for line in 'import { post } from "./poster.mjs";' 'export { post } from "./poster.mjs";' \
  'const { post } = require("./poster.mjs");' 'await import("./poster.mjs");' \
  'expect(makeEntry("x")).toContain("export * from '"'"'./src/index.ts'"'"'"); await import("./poster.mjs");' \
  'expect(makeEntry("x")).toBe("a"); export { post } from "./poster.mjs";'; do
  n46=$((n46 + 1))
  vt46 "real-$n46.node.test.mjs" "$line"
  run_46 "$VT46 scripts/real-$n46.node.test.mjs"
  read_refused "#3146 a real import of a module that posts is still followed: $line"
  says "#3146 and the refusal names it: $line" "poster.mjs"
done
vt46 missing.node.test.mjs 'import "./src/index.ts";'
run_46 "$VT46 scripts/missing.node.test.mjs"
read_refused "#3146 a real import of a module that is not there is still refused"
says "#3146 and the refusal names it" "./src/index.ts, a module the gate cannot find"
# A string anywhere else is still followed while something in the walk can run strings: held in a
# name and handed on, built with +, an array's element, compared by a matcher with custom testers,
# or beside a matcher or a string method the file changes.
n46=0
for line in 'const entry = "export * from '"'"'./src/index.ts'"'"'"; execFileSync("node", ["--input-type=module", "-e", entry]);' \
  'expect(makeEntry("x")).toContain("export * from '"'"'./src/index.ts'"'"'" + "");' \
  'const cases = ["export * from '"'"'./src/index.ts'"'"'"];' \
  'expect(makeEntry("x")).toEqual("export * from '"'"'./src/index.ts'"'"'");' \
  'expect.extend({ toContain: (r, c) => execFileSync("node", ["--input-type=module", "-e", c]) });' \
  'Object.defineProperty(String.prototype, "includes", { value: (c) => execFileSync("node", ["-e", c]) });'; do
  n46=$((n46 + 1))
  vt46 "held-$n46.node.test.mjs" "$line"
  run_46 "$VT46 scripts/held-$n46.node.test.mjs"
  read_refused "#3146 import text in a string not only compared by a matcher is still followed: $line"
  says "#3146 and the refusal names the module in the string: $line" "./src/index.ts"
done
# expect bound by the file itself, which may hand the string to anything.
sed -e 's/^import { test, expect } from "vitest";$/import { test } from "vitest";/' "$D46/scripts/base.txt" > "$D46/scripts/own-expect.node.test.mjs"
printf '%s\n' 'function expect(s) { return { toContain: (c) => execFileSync("node", ["-e", c]), not: {}, toBe() {}, toMatch() {}, toBeGreaterThan() {} }; }' >> "$D46/scripts/own-expect.node.test.mjs"
run_46 "$VT46 scripts/own-expect.node.test.mjs"
read_refused "#3146 a file that binds expect itself still has its strings followed"
# A matcher changed in another module the test imports.
printf '%s\n' 'import { expect } from "vitest";' 'import { execFileSync } from "node:child_process";' \
  'expect.extend({ toContain: (r, c) => ({ pass: !!execFileSync("node", ["-e", c]), message: () => "" }) });' > "$D46/scripts/matchers.mjs"
vt46 extended.node.test.mjs 'import "./matchers.mjs";'
run_46 "$VT46 scripts/extended.node.test.mjs"
read_refused "#3146 a matcher changed in a module the test imports leaves every string followed"
says "#3146 and the refusal names the module in the string" "./src/index.ts"

echo

sdg_harness_result
