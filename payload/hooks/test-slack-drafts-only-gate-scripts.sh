#!/usr/bin/env bash
# Tests for slack-drafts-only-gate.sh and its rule, slack_drafts_only_gate.py, the gate that leaves
# sessions only able to save Slack drafts (claude-config#2302): the draft tool and reading Slack
# still work, every send and schedule tool is refused, a command or a script that posts is refused
# and one that only names an endpoint passes, and a Python script is followed into the modules it
# imports, wherever its first line, PYTHONPATH, sys.path or a shell variable places them.
#
# test-slack-drafts-only-gate.sh held every check of the gate, 2,633 of them, until on 2026-11-24 it
# ran past run-all-tests.sh's 1,200 second wall limit on GitHub's runners in three runs of four,
# each time stopping the config sync between the two Macs: one piece held against a fixed deadline
# had grown to most of it (L315). Its sections are now six suites, each a run of them in their
# order, dealt by their own measured cost (claude-config#3575): -scripts, -written-files,
# -file-arguments, test-slack-drafts-only-gate.sh itself (the gate as a whole: /nudge, a payload it
# cannot read, its time budget, a crash, its wiring and its cost), -runners and -tools-cache. Every
# check is as it was, and a comment saying "above" or "below" means in whichever of the six holds it.
#
# The world they all run in (the gate under test, the throwaway folder and its judgement cache, the
# result line, and the fixtures one section makes and a section in another suite reads) is
# lib/slack-drafts-gate-harness.sh, the one place each of them takes it from. The helper functions
# are the one thing each holds a copy of, below, because the gate reads functions only where they
# are called.
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

# The helpers every case is driven through, copied as they are into each of the six suites: the
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

echo "slack drafts only: the draft tool and reading Slack still work"

# The control FIRST: the draft, with the same input the sends below carry, goes through, so a
# refusal below is the tool name doing it and not a gate that refuses every Slack call (L159).
run_tool mcp__plugin_slack_slack__slack_send_message_draft "$SEND_INPUT"
allowed "the Slack plugin's draft tool"
run_tool mcp__claude_ai_Slack__slack_send_message_draft "$SEND_INPUT"
allowed "the claude.ai connector's draft tool"
run_tool mcp__claude_ai_Slack__slack_read_channel '{"channel_id": "C0TEST1"}'
allowed "reading a channel"
run_tool mcp__plugin_slack_slack__slack_search_public '{"query": "chat.postMessage"}'
allowed "a search whose text names the endpoint"

echo "slack drafts only: every send and schedule tool is refused"

for tool in mcp__plugin_slack_slack__slack_send_message mcp__plugin_slack_slack__slack_schedule_message \
            mcp__claude_ai_Slack__slack_send_message mcp__claude_ai_Slack__slack_schedule_message \
            mcp__some_future_connector__slack_send_message mcp__Another_Slack__slack_schedule_message; do
  run_tool "$tool" "$SEND_INPUT"
  refused "$tool is refused"
  says "the refusal for $tool names the tool" "$tool"
done

run_tool mcp__claude_ai_Slack__slack_send_message "$SEND_INPUT"
says "the refusal names the draft tool" "slack_send_message_draft"
says "and the same channel" "C0TEST1"
says "and the same thread" "1730000000.000100"
says "and to tell Dan where the draft is" "tell Dan where the draft is"
run_tool mcp__plugin_slack_slack__slack_schedule_message '{"channel_id": "C0TEST2", "message": "x", "post_at": 1730000000}'
says "a schedule without a thread names its channel" "C0TEST2"

echo "slack drafts only: a command that posts is refused"

posts=(
  "curl -X POST https://slack.com/api/chat.postMessage -H 'Authorization: Bearer x' -d channel=C1 -d text=hi"
  "curl -s https://slack.com/api/chat.scheduleMessage -d post_at=1730000000"
  "wget --post-data='{\"text\":\"hi\"}' https://hooks.slack.com/services/T0/B0/x"
  "sudo -u bob curl -d '{}' https://hooks.slack.com/services/T0/B0/x"
  "echo '{\"text\":\"hi\"}' | curl -d @- https://hooks.slack.com/services/T0/B0/x"
  "U=https://hooks.slack.com/services/T0/B0/x; curl -d '{}' \"\$U\""
  "curl -X POST -d '{\"text\":\"hi\"}' \"\$SLACK_WEBHOOK_URL\""
  "python3 -c 'import urllib.request; urllib.request.urlopen(\"https://slack.com/api/chat.postMessage\", data=b\"x\")'"
  "node -e 'fetch(\"https://hooks.slack.com/services/x\", {method: \"POST\", body: \"{}\"})'"
  "bash -c 'curl https://slack.com/api/chat.postMessage -d text=hi'"
  "python3 - <<'EOF'
import urllib.request
urllib.request.urlopen('https://hooks.slack.com/services/T0/B0/x', data=b'{}')
EOF"
)
for c in "${posts[@]}"; do
  run_bash "$c"
  refused "refused: ${c:0:90}"
done
run_bash "curl -X POST https://slack.com/api/chat.postMessage -d channel=C1 -d text=hi"
says "a refused command names the draft tool" "slack_send_message_draft"
says "and the same channel and thread" "same channel and thread"
says "and to tell Dan where the draft is" "tell Dan where the draft is"

echo "slack drafts only: a command that only mentions an endpoint passes"

mentions=(
  "grep -rn chat.postMessage ."
  "grep -rn 'hooks.slack.com' src | head -5"
  "rg -n 'chat.scheduleMessage|SLACK_WEBHOOK' payload"
  "[ \"\$method\" = chat.postMessage ] && echo yes"
  "echo 'curl https://slack.com/api/chat.postMessage is refused'"
  "bash -c 'grep -n chat.postMessage nudge.py'"
  "git log --grep chat.postMessage --oneline"
  "curl -s https://example.com/status"
  "git status"
)
for c in "${mentions[@]}"; do
  run_bash "$c"
  allowed "passes: ${c:0:90}"
done

echo "slack drafts only: a script that posts is refused, one that only mentions the endpoint passes"

printf '%s\n' '#!/bin/bash' "curl -s -X POST -d '{\"text\":\"hi\"}' https://hooks.slack.com/services/T0/B0/x" > "$T/alert.sh"
chmod +x "$T/alert.sh"
printf '%s\n' '#!/bin/bash' "python3 $T/alert.py" > "$T/calls-alert.sh"
printf '%s\n' '#!/bin/bash' 'grep -rn "chat.postMessage" .' 'echo "hooks.slack.com is where a webhook posts"' > "$T/mentions.sh"
printf '%s\n' 'print("hello")' > "$T/plain.py"

run_bash "python3 $T/alert.py"
refused "a python script that posts"
says "the refusal names the script" "alert.py"
run_bash "cd $T && python3 alert.py"
refused "the same script named relative to the directory the command moved to"
run_bash "bash $T/alert.sh"
refused "a shell script that posts, run by bash"
# A script with no extension gets past the quick exit only by its runner or its path (lessons review).
cp "$T/alert.sh" "$T/notify"; chmod +x "$T/notify"
run_bash "cd $T && bash notify"
refused "an extensionless script that posts, run by bash by its bare name"
run_bash "$T/notify"
refused "an extensionless script that posts, run by its absolute path"
# The same script by a relative path with a directory, and behind every wrapper the shared reader
# reads through: the quick exit must send each to the full rule (lessons review, 2026-11-05).
mkdir -p "$T/bin"; cp "$T/alert.sh" "$T/bin/notify-slack"; chmod +x "$T/bin/notify-slack"
run_bash "cd $T && bin/notify-slack"
refused "an extensionless script run by a relative path with a directory"
run_bash "cd $T && X=1 bin/notify-slack"
refused "the same, after an assignment"
for wrapped in "sudo $T/notify" "sudo -u root $T/notify" "env X=1 $T/notify" "rtk $T/notify" \
  "nohup $T/notify" "time $T/notify" "command $T/notify" "exec $T/notify" "nice -n 5 $T/notify" \
  "timeout 30 $T/notify" "echo x | xargs $T/notify" "cd $T && sudo bin/notify-slack" \
  "if true; then bin/notify-slack; fi" "find $T -name notify -exec $T/notify {} \\;" \
  ">/dev/null bin/notify-slack" "cd $T && . notify" "cd $T && source notify"; do
  run_raw "$(payload Bash "$(bash_input "$wrapped")")"
  refused "a script that posts, run as: $wrapped"
done
# An option the reader takes for one that carries a value must not hide the script after it: every
# word naming a file is read, not only the one an option table points at (lessons review, round 3).
for flagged in "python3 -I $T/alert.py" "python3 -i $T/alert.py" "python3 -u -W ignore $T/alert.py" \
  "bash -i $T/notify" "bash -o pipefail $T/notify" "ruby -I lib $T/alert.py"; do
  run_bash "$flagged"
  refused "a script that posts behind interpreter options: $flagged"
done
run_bash "python3 -I $T/plain.py"
allowed "a script that names no endpoint, behind the same options"
run_bash "git push origin HEAD:fix/2302-slack-drafts-only"
allowed "a plain push naming a branch with a slash"

# A package script is followed the way a shell script is: repo-digest's CLAUDE.md documents
# `npm run digest` as a local command that posts to Slack.
mkdir -p "$T/pkg/scripts" "$T/pkg/sub"
cp "$T/alert.py" "$T/pkg/scripts/digest.py"
cp "$T/alert.sh" "$T/pkg/scripts/post.sh"
cat > "$T/pkg/package.json" <<'JSON'
{"name": "p", "scripts": {
  "digest": "python3 scripts/digest.py",
  "lint": "echo lint ok",
  "test": "bash scripts/post.sh",
  "predeploy": "curl -d '{}' https://hooks.slack.com/services/T0/B0/x",
  "deploy": "echo deployed",
  "announce": "curl -d '{}' https://slack.com/api/chat.postMessage"
}}
JSON
for posts in "cd $T/pkg && npm run digest" "cd $T/pkg && npm run-script digest" "cd $T/pkg && npm run digest -- --dry-run" \
  "cd $T/pkg/sub && pnpm run digest" "cd $T/pkg && pnpm digest" "cd $T/pkg && yarn digest" "cd $T/pkg && yarn run digest" \
  "npm --prefix $T/pkg run digest" "pnpm -C $T/pkg run digest" "cd $T/pkg && npm test" "cd $T/pkg && npm t" \
  "cd $T/pkg && npm run deploy" "cd $T/pkg && npm run announce" "cd $T/pkg && sudo npm run digest"; do
  run_bash "$posts"
  refused "a package script that posts, run as: $posts"
done
run_bash "cd $T && npm exec -- bin/notify-slack"
refused "npm exec running a script that posts"
mkdir -p "$T/badpkg"; printf '%s\n' '{"scripts": {"go": "curl https://hooks.slack.com/services/T0/B0/x",}' > "$T/badpkg/package.json"
run_bash "cd $T/badpkg && npm run go"
refused "a package.json that is not valid JSON but names an endpoint"
run_bash "cd $T/pkg && npm run lint"
allowed "a package script that does not post"
run_bash "cd $T/pkg && npm run missing"
allowed "a package script that does not exist runs nothing"
run_bash "cd $T && npm run digest"
allowed "npm run with no package.json above it runs nothing"
run_bash "$T/alert.sh"
refused "the same script run by its path"
run_bash "bash $T/calls-alert.sh"
refused "a shell script that runs a script that posts"
run_bash "bash $T/mentions.sh"
allowed "a shell script that only mentions the endpoints"
run_bash "python3 $T/plain.py"
allowed "a script that names no endpoint"
run_bash "python3 $T/missing.py"
allowed "a script that does not exist runs nothing"

# What a heredoc feeds is its own body, not every line of the script around it. Measured before this
# was cut that way: running this very suite was refused, because one of its python3 heredocs sat in
# a file whose other lines name chat.postMessage as test data.
printf '%s\n' '#!/bin/bash' 'echo "chat.postMessage is only test data here"' "python3 - <<'PY'" 'print(1)' 'PY' > "$T/heredoc-clean.sh"
run_bash "bash $T/heredoc-clean.sh"
allowed "a script whose heredoc names no endpoint, beside a line that does"
# This suite since the split (#3575); test-slack-drafts-only-gate.sh, which held this case until
# then, is judged by its own cost checks, which need it allowed.
run_bash "bash $DIR/test-slack-drafts-only-gate-scripts.sh"
allowed "running this suite itself"
# Every suite sources lib/suite-deadline.sh, which sources its readers from inside its functions,
# where a global's value cannot be proved (a function runs with whatever its caller set), so it names
# them by its own BASH_SOURCE, which the gate reads (claude-config#2465).
run_bash "bash $DIR/test-suite-deadline.sh"
allowed "a suite whose deadline helper sources its readers from inside its functions"
run_bash "bash <<'EOF'
curl -d '{}' https://hooks.slack.com/services/T0/B0/x
EOF"
refused "a shell fed a posting command by a heredoc"
run_bash "bash <<'EOF'
grep -rn chat.postMessage .
EOF"
allowed "a shell fed a heredoc that only greps for the endpoint"

echo "slack drafts only: a script posting through a module it imports is refused (claude-config#2318)"

# The shape measured in repo-digest on 2026-11-05: package.json runs `FORCE_RUN=1 node src/digest.ts`,
# src/digest.ts names no endpoint and imports ./slack.ts (with its .ts extension written, beside a
# node builtin and an `import type`), and src/slack.ts names chat.postMessage. The #2302 gate let it
# through (exit 0).
mkdir -p "$T/rd/src"
printf '%s\n' '{"name": "repo-digest", "type": "module", "scripts": {' \
  '  "digest": "FORCE_RUN=1 node src/digest.ts", "fmt": "node src/fmt-only.ts"}}' > "$T/rd/package.json"
cat > "$T/rd/src/digest.ts" <<'TS'
import { readFileSync } from "node:fs";
import { buildDigest } from "./format.ts";
import { postDigest } from "./slack.ts";
await postDigest(buildDigest(JSON.parse(readFileSync("repos.json", "utf8"))));
TS
cat > "$T/rd/src/format.ts" <<'TS'
export type SlackBlock = { type: string };
export function buildDigest(x: unknown): SlackBlock[] { return [{ type: String(x) }]; }
TS
cat > "$T/rd/src/slack.ts" <<'TS'
import type { SlackBlock } from "./format.ts";
export async function postDigest(blocks: SlackBlock[]) {
  await fetch("https://slack.com/api/chat.postMessage", { method: "POST", body: JSON.stringify(blocks) });
}
TS
printf '%s\n' 'import { buildDigest } from "./format.ts";' 'console.log(buildDigest(1));' > "$T/rd/src/fmt-only.ts"
for posts in "cd $T/rd && npm run digest" "cd $T/rd && node src/digest.ts" "node $T/rd/src/digest.ts" \
  "cd $T/rd && npx tsx src/digest.ts" "cd $T/rd/src && FORCE_RUN=1 node digest.ts"; do
  run_bash "$posts"
  refused "a script importing a helper that posts, run as: $posts"
done
run_bash "cd $T/rd && npm run digest"
says "the refusal names the helper the script imports" "slack.ts"
says "the refusal names the endpoint the helper holds" "chat.postMessage"
run_bash "cd $T/rd && npm run fmt"
allowed "a package script whose script imports only a helper that names no endpoint"

# The resolutions node and TypeScript make: no extension, a directory's index, require(), a dynamic
# import(), an `export ... from`, and the .js a TypeScript ESM file writes for its own .ts sibling.
mkdir -p "$T/imp/lib/notify" "$T/imp/deep" "$T/imp/cyc" "$T/imp/ok"
printf '%s\n' 'module.exports = () => fetch("https://hooks.slack.com/services/T0/B0/x");' > "$T/imp/lib/notify/index.js"
printf '%s\n' 'const notify = require("./lib/notify");' 'notify();' > "$T/imp/req.js"
printf '%s\n' 'const m = await import("./lib/notify/index.js");' > "$T/imp/dyn.mjs"
printf '%s\n' 'export { post } from "./ts-helper.js";' > "$T/imp/reexport.ts"
printf '%s\n' 'export const post = () => fetch("https://slack.com/api/chat.scheduleMessage");' > "$T/imp/ts-helper.ts"
printf '%s\n' '#!/usr/bin/env node' 'require("../lib/notify")();' > "$T/imp/deep/notify-cli"
chmod +x "$T/imp/deep/notify-cli"
for posts in "node $T/imp/req.js" "node $T/imp/dyn.mjs" "npx tsx $T/imp/reexport.ts" "$T/imp/deep/notify-cli"; do
  run_bash "$posts"
  refused "a script reaching a posting helper through an import node resolves, run as: $posts"
done
run_bash "node $T/imp/req.js"
says "a helper found as a directory's index is named" "index.js"

# Two imports deep: the script names nothing, the helper it imports names nothing, and the helper
# that one imports posts.
printf '%s\n' 'import { a } from "./mid";' 'a();' > "$T/imp/deep/top.ts"
printf '%s\n' 'import { b } from "./bottom";' 'export const a = () => b();' > "$T/imp/deep/mid.ts"
printf '%s\n' 'export const b = () => fetch("https://slack.com/api/chat.postMessage");' > "$T/imp/deep/bottom.ts"
run_bash "node $T/imp/deep/top.ts"
refused "a script whose helper imports a helper that posts"
says "the refusal names the helper two imports deep" "bottom.ts"

# A cycle ends: two helpers importing each other are each read once, and a poster reached only past
# the cycle is still found.
printf '%s\n' 'import { y } from "./y";' 'export const x = () => y();' > "$T/imp/cyc/x.ts"
printf '%s\n' 'import { x } from "./x";' 'export const y = () => x;' > "$T/imp/cyc/y.ts"
printf '%s\n' 'import { x } from "./x";' 'x();' > "$T/imp/cyc/main.ts"
run_bash "node $T/imp/cyc/main.ts"
allowed "an import cycle that names no endpoint ends and passes"
printf '%s\n' 'import { x } from "./x";' 'import { z } from "./z";' 'export const w = () => x() + z();' > "$T/imp/cyc/w.ts"
printf '%s\n' 'import { w } from "./w";' 'export const z = () => fetch("https://slack.com/api/chat.postEphemeral");' > "$T/imp/cyc/z.ts"
printf '%s\n' 'import { w } from "./w";' 'w();' > "$T/imp/cyc/main2.ts"
run_bash "node $T/imp/cyc/main2.ts"
refused "a poster reached through an import cycle"
says "the refusal names the helper past the cycle" "z.ts"

# An import the gate cannot find or read is a module it cannot see, and node may still find it
# (package.json exports, a path alias, a loader), so it is refused rather than passed.
printf '%s\n' 'import { gone } from "./not-here";' 'gone();' > "$T/imp/missing.ts"
run_bash "node $T/imp/missing.ts"
refused "a script importing a relative module the gate cannot find"
says "the refusal names the import it could not find" "./not-here"
printf '%s\n' 'export const s = 1;' > "$T/imp/sealed.ts"
printf '%s\n' 'import { s } from "./sealed.ts";' 'console.log(s);' > "$T/imp/reads-sealed.ts"
chmod 000 "$T/imp/sealed.ts"
if [ -r "$T/imp/sealed.ts" ]; then
  echo "SUITE-PART-UNMEASURED #2318 a script importing a module the gate cannot read: this user can read a mode 000 file (running as root), so no unreadable module could be made"
else
  run_bash "node $T/imp/reads-sealed.ts"
  refused "a script importing a module the gate cannot read"
  says "the refusal names the module it could not read" "sealed.ts"
fi
chmod 644 "$T/imp/sealed.ts"
# An import written in a comment is an example, not code node runs (claude-config#2397). Measured
# 2026-11-07: a test harness whose header comment shows how to import it, from the suites' folder,
# was read as importing ./lib/harness.ts from its own folder, which is not there, so every suite
# importing the harness was refused. The fixture is that shape: a suite in scripts/, the harness in
# scripts/lib/, and no scripts/lib/lib/.
mkdir -p "$T/imp/cmt/scripts/lib"
printf '%s\n' '// A tiny test harness. Use it from a suite like this:' \
  '//   import { assert, finish } from "./lib/harness.ts";' \
  '/* or, the older way:' \
  '   const { assert } = require("./lib/old-harness.js");' \
  '*/' \
  '/**' \
  ' * import { finish } from "./lib/finish.ts";' \
  ' */' \
  'export const assert = (ok: boolean) => { if (!ok) throw new Error("failed"); };' \
  'export const finish = () => console.log("done"); // import "./lib/trailing.ts"' > "$T/imp/cmt/scripts/lib/harness.ts"
printf '%s\n' 'import { assert, finish } from "./lib/harness.ts";' 'assert(true);' 'finish();' > "$T/imp/cmt/scripts/test-lane.ts"
run_bash "node $T/imp/cmt/scripts/test-lane.ts"
allowed "a suite whose harness shows an example import in its comments"
run_bash "cd $T/imp/cmt && node --experimental-strip-types scripts/test-lane.ts"
allowed "the same suite run from the repository root"
# The controls: a real import of a missing module beside those comments is still refused, and so is
# one after a string, a template or a regex holding // (a URL is not a comment opening), or after a
# block comment closed earlier on its line.
printf '%s\n' '// import { a } from "./lib/example.ts";' 'import { gone } from "./not-here";' 'gone();' > "$T/imp/cmt/real.ts"
run_bash "node $T/imp/cmt/real.ts"
refused "a real import of a missing module below a commented example"
says "that refusal names the real import" "./not-here"
for line in 'const u = "https://example.com/a"; import { gone } from "./not-here";' \
  "const u = 'https://example.com/a'; import { gone } from \"./not-here\";" \
  'const u = `https://example.com/${1}`; import { gone } from "./not-here";' \
  'const r = /https?:\/\//; import { gone } from "./not-here";' \
  'const s = "/*"; import { gone } from "./not-here"; const e = "*/";' \
  '/* a note */ import { gone } from "./not-here";' \
  'const x = 1 / 2; import { gone } from "./not-here"; const y = 3 / 4;'; do
  printf '%s\n' "$line" > "$T/imp/cmt/url.ts"
  run_bash "node $T/imp/cmt/url.ts"
  refused "a real import of a missing module on a line holding: ${line:0:40}"
done
# A block comment that never closes is not trusted as a comment: node refuses to parse the file, and
# a misread one must not hide the imports after it.
printf '%s\n' '/* never closed' 'import { gone } from "./not-here";' > "$T/imp/cmt/open.ts"
run_bash "node $T/imp/cmt/open.ts"
refused "an import after a block comment that never closes"

# A type only import statement of a declaration file that is not there loads nothing, so it is not
# a module the gate could not see (claude-config#2526). Measured 2026-11-09: `bun test` on a mod's
# test in an agent worktree was refused, because the test imports the generated
# ../.claude-plugin/types/mod-kit/index.d.ts for its types and a worktree does not have that file.
# Measured 2026-11-10 with bun 1.3.11, node 22.22.2 and deno: `import type ... from` never loads its
# module, there or not, while `import { type A } from` is loaded by node, which only blanks the
# names. So only the statement form is passed, and, where the file is missing, only for a .d.ts. One
# that is there is not read for it either (#2890, cases at the end of
# test-slack-drafts-only-gate-tools-cache.sh).
mkdir -p "$T/imp/dts/tests"
D2526="'../types/index.d.ts'"
dts_case() { # dts_case <lines of the test file...>: judge a bun test run of a test holding them
  printf '%s\n' "$@" 'console.log(1);' > "$T/imp/dts/tests/a.test.ts"
  run_bash "bun test $T/imp/dts/tests/a.test.ts"
}
dts_case "import type { ModKitBandRow } from $D2526"
allowed "a test importing only types from a declaration file that is not there"
dts_case 'import type {' '  A,' '  B as C,' "} from $D2526"
allowed "the same import written over several lines, with a renamed type"
dts_case "import type A from $D2526"
allowed "a type only default import of a missing declaration file"
dts_case "import type * as Kit from $D2526"
allowed "a type only namespace import of a missing declaration file"
dts_case "import type { A } /* the kit */ from $D2526"
allowed "a type only import with a comment before its from"
printf '%s\n' "import type { A } from $D2526" 'export const n = 1;' > "$T/imp/dts/tests/helper.ts"
dts_case 'import { n } from "./helper.ts";' 'console.log(n);'
allowed "a test whose helper imports only types from a missing declaration file"
# Every other way of naming the same missing file is refused as it was: each one loads the module in
# some runtime, or is not seen to be unable to.
for line in "import { A } from $D2526" \
  "import { type A, b } from $D2526" \
  "import { type A } from $D2526" \
  "import { type A, type B } from $D2526" \
  "import type from $D2526" \
  "import type, { A } from $D2526" \
  "import $D2526" \
  "const kit = await import($D2526)" \
  "const kit = require($D2526)" \
  "import type Kit = require($D2526)" \
  "export type { A } from $D2526" \
  "export * from $D2526" \
  "const s = \"import type { A } \"; export * from $D2526" \
  "import type { A } from '../types/index.ts'" \
  "import type { A } from '../types/index.d.ts.js'" \
  "import type { A } from '../types/index'"; do
  dts_case "$line"
  refused "a missing module imported as: ${line:0:60}"
  says "that refusal is the module it could not find: ${line:0:40}" "a module the gate cannot find"
done
dts_case 'import type { A }' "export * from $D2526"
refused "a re-export of a missing module on the line after a type only import"
dts_case "import type { A } from $D2526" "import { b } from $D2526"
refused "a value import of a missing declaration file beside a type only import of it"
dts_case "import type { A } from $D2526" "fetch('https://slack.com/api/chat.postMessage');"
refused "a test that posts by itself and imports types from a missing declaration file"
says "that refusal is the endpoint the test names" "chat.postMessage"
# A type only import of a file that is there loads nothing either, so it is not followed (#2890
# reversed reading it, which refused a test whose only route to a module that posts was a type import).
mkdir -p "$T/imp/dts/types"
printf '%s\n' 'export type A = number;' "fetch('https://slack.com/api/chat.postMessage');" > "$T/imp/dts/types/index.d.ts"
dts_case "import type { A } from $D2526"
allowed "a type only import of a declaration file that is there and posts (#2890)"
dts_case "import { type A } from $D2526"
refused "a value import of the same declaration file is still followed, and posts"
says "that refusal names the declaration file" "index.d.ts"
says "and says it posts" "which posts to Slack"
printf '%s\n' 'export type A = number;' > "$T/imp/dts/types/index.d.ts"
dts_case "import type { A } from $D2526"
allowed "a type only import of a declaration file that is there and posts nothing"
rm -rf "$T/imp/dts/types"
# What a script can do with a file it is handed (claude-config#2362) is read the same way: the type
# import no longer makes an inert script one that acts, and nothing else stops being one.
printf '%s\n' 'curl -X POST https://slack.com/api/chat.postMessage -d text=hi' > "$T/imp/dts/msg.txt"
printf '%s\n' "import type { A } from $D2526" 'import { readFileSync } from "node:fs";' \
  'console.log(readFileSync(process.argv[2], "utf8").length);' > "$T/imp/dts/tests/count.ts"
run_bash "cd $T/imp/dts && node tests/count.ts msg.txt"
allowed "an inert script importing types from a missing declaration file, handed a file naming the endpoint"
printf '%s\n' "import { A } from $D2526" 'import { readFileSync } from "node:fs";' \
  'console.log(readFileSync(process.argv[2], "utf8").length);' > "$T/imp/dts/tests/count.ts"
run_bash "cd $T/imp/dts && node tests/count.ts msg.txt"
refused "the same script with a value import of the missing declaration file"
printf '%s\n' "import type { A } from $D2526" 'import { execSync } from "node:child_process";' \
  'import { readFileSync } from "node:fs";' 'execSync(readFileSync(process.argv[2], "utf8"));' > "$T/imp/dts/tests/count.ts"
run_bash "cd $T/imp/dts && node tests/count.ts msg.txt"
refused "a script that runs what it is handed, importing types from a missing declaration file"
# A type only import of a package is erased the same way, so it does not make an inert script one that
# may act (#2890's fold): only a value import of a package the gate does not know is read as acting.
printf '%s\n' 'import type { Options } from "some-pkg";' 'import { readFileSync } from "node:fs";' \
  'console.log(readFileSync(process.argv[2], "utf8").length);' > "$T/imp/dts/tests/count.ts"
run_bash "cd $T/imp/dts && node tests/count.ts msg.txt"
allowed "an inert script importing only types from a package, handed a file naming the endpoint"
for line in 'import { Options } from "some-pkg";' 'import { type Options } from "some-pkg";' 'import "some-pkg";'; do
  printf '%s\n' "$line" 'import { readFileSync } from "node:fs";' \
    'console.log(readFileSync(process.argv[2], "utf8").length);' > "$T/imp/dts/tests/count.ts"
  run_bash "cd $T/imp/dts && node tests/count.ts msg.txt"
  refused "the same script importing the package as: $line"
done

# Import text inside an ordinary string literal is data, not an import node runs (claude-config#2484,
# narrowing signed off by Dan on 2026-11-09). Measured on the work MacBook: a test script holding an
# esbuild stdin entry and a Miniflare module source as strings was refused for modules nothing loads,
# and the builder got past it by assembling the strings by concatenation. A string is still followed
# wherever the code the script reaches can run a string as code (eval, new Function, vm, a Worker,
# Miniflare's script or modules source, a child process, a data: URL), because a string reaches that
# sink through a variable, a function or another module the gate cannot trace.
mkdir -p "$T/imp/str"
printf '%s\n' 'export const post = () => fetch("https://slack.com/api/chat.postMessage");' > "$T/imp/str/poster.js"
cat > "$T/imp/str/data.ts" <<'TS'
import { join } from "node:path";
const entry = "import { handler } from './missing-entry.js'";
const opts = { stdin: { contents: "export * from './src/missing-stdin.ts'", resolveDir: join(".", "src") } };
const tpl = `export { x } from "./missing-template.js"; ${entry}`;
const req = 'const m = require("./missing-required.js"); await import("./missing-dynamic.js");';
const doc = "import { post } from './poster.js'";
console.log(entry, opts, tpl, req, doc);
TS
run_bash "node $T/imp/str/data.ts"
allowed "import text inside ordinary string literals (missing modules and a posting one) is not followed"
# The controls: a real import beside those strings is still followed, missing or posting.
{ cat "$T/imp/str/data.ts"; printf '%s\n' 'import { gone } from "./not-here";'; } > "$T/imp/str/data-real.ts"
run_bash "node $T/imp/str/data-real.ts"
refused "a real import of a missing module beside import text in strings"
says "that refusal names the real import, not a string" "./not-here"
{ cat "$T/imp/str/data.ts"; printf '%s\n' 'const { post } = await import("./poster.js");' 'post();'; } > "$T/imp/str/data-posts.ts"
run_bash "node $T/imp/str/data-posts.ts"
refused "a real dynamic import of a posting helper beside import text in strings"
says "that refusal names the posting helper" "poster.js"
# A script whose own code posts is refused however its imports read.
printf '%s\n' 'const doc = "import { a } from \"./missing.js\"";' \
  'await fetch("https://slack.com/api/chat.postMessage", { method: "POST", body: doc });' > "$T/imp/str/sends.ts"
run_bash "node $T/imp/str/sends.ts"
refused "a script that posts to Slack itself, beside import text in a string"

# Miniflare's script or modules source is code Miniflare runs, so its import text is still followed:
# missing, it is refused as a module the gate cannot see; present and posting, as a post.
cat > "$T/imp/str/mf-missing.ts" <<'TS'
import { Miniflare } from "miniflare";
const worker = `export { handler as default } from "./outbound.js";`;
const mf = new Miniflare({ modules: true, script: worker });
await mf.dispatchFetch("http://localhost/");
TS
run_bash "node $T/imp/str/mf-missing.ts"
refused "a Miniflare script source importing a module the gate cannot find"
says "that refusal names the module in the source string" "./outbound.js"
cat > "$T/imp/str/mf-posts.ts" <<'TS'
import { Miniflare } from "miniflare";
const mf = new Miniflare({
  modules: [{ type: "ESModule", path: "worker.mjs", contents: "import { post } from './poster.js'; export default { fetch: () => post() };" }],
});
await mf.dispatchFetch("http://localhost/");
TS
run_bash "node $T/imp/str/mf-posts.ts"
refused "a Miniflare modules source importing a helper that posts to Slack"
says "that refusal names the posting helper reached through the source string" "poster.js"

# Each other sink that runs a string as code keeps its strings followed, held directly or through a
# variable, and so does a string another module hands to a sink in the script.
mkdir -p "$T/imp/str/sinks"
cp "$T/imp/str/poster.js" "$T/imp/str/sinks/poster.js"
cat > "$T/imp/str/sinks/eval.ts" <<'TS'
eval("import('./poster.js').then((m) => m.post())");
TS
cat > "$T/imp/str/sinks/function.ts" <<'TS'
const src = "return import('./poster.js')";
new Function(src)();
TS
cat > "$T/imp/str/sinks/vm.ts" <<'TS'
import vm from "node:vm";
vm.runInNewContext("import('./poster.js')");
TS
cat > "$T/imp/str/sinks/worker.ts" <<'TS'
import { Worker } from "node:worker_threads";
new Worker("import('./poster.js')", { eval: true });
TS
cat > "$T/imp/str/sinks/child.ts" <<'TS'
import { execSync } from "node:child_process";
execSync(`node --input-type=module -e "import './poster.js'"`);
TS
cat > "$T/imp/str/sinks/data-url.ts" <<'TS'
await import("data:text/javascript,import './poster.js'");
TS
cat > "$T/imp/str/sinks/constructor.ts" <<'TS'
const f = (async () => {}).constructor;
await f("await import('./poster.js')")();
TS
for sink in eval function vm worker child data-url constructor; do
  run_bash "node $T/imp/str/sinks/$sink.ts"
  refused "a string handed to code that runs it ($sink), importing a helper that posts"
  says "the $sink refusal names the posting helper" "poster.js"
done
cat > "$T/imp/str/src.ts" <<'TS'
export const src = "import { post } from './poster.js'; post();";
TS
printf '%s\n' 'import { src } from "./src.ts";' 'eval(src);' > "$T/imp/str/evals-imported.ts"
run_bash "node $T/imp/str/evals-imported.ts"
refused "a string from another module handed to eval in the script, importing a helper that posts"
says "that refusal names the posting helper" "poster.js"
# Past the most modules it reads in no repository (IMPORT_MAX_FILES, 300; the largest real script
# reaches 11), what lies beyond is unseen, so it is refused; a short chain of the same shape passes.
# Inside a repository it reads on (claude-config#2470, with the budget cases below).
mkdir -p "$T/imp/chain" "$T/imp/short"
for n in $(seq 0 305); do printf 'import "./m%s";\n' "$((n + 1))" > "$T/imp/chain/m$n.ts"; done
printf '%s\n' 'export {};' > "$T/imp/chain/m306.ts"
for n in 0 1 2; do printf 'import "./m%s";\n' "$((n + 1))" > "$T/imp/short/m$n.ts"; done
printf '%s\n' 'export {};' > "$T/imp/short/m3.ts"
run_bash "node $T/imp/chain/m0.ts"
refused "a script whose imports reach more modules than the gate reads"
says "the refusal says the imports go past what it reads" "more than 300 modules"
run_bash "node $T/imp/short/m0.ts"
allowed "a short import chain that names no endpoint"

# Passes: a helper that only saves a draft, packages and node builtins (not ours to read, and not
# relative), and an import whose path is assembled at run time.
cat > "$T/imp/ok/draft.ts" <<'TS'
import { writeFileSync } from "node:fs";
// Saves the message as a draft for Dan to send himself (slack_send_message_draft does the rest).
export const saveDraft = (text: string) => writeFileSync("drafts/digest.md", text);
TS
cat > "$T/imp/ok/main.ts" <<'TS'
import express from "express";
import { join } from "node:path";
import { saveDraft } from "./draft";
const lang = process.env.LANG_CODE;
const words = await import(`./locales/${lang}.js`);
saveDraft(join("a", String(express), String(words)));
TS
run_bash "node $T/imp/ok/main.ts"
allowed "a script importing a helper that only saves a draft, a package and a builtin"
run_bash "grep -rn chat.postMessage $T/rd/src/slack.ts"
allowed "a grep for the endpoint in the helper still passes"

# A Python script's imports are followed the same way: a sibling module, a package and its
# __init__.py, a relative import inside a package. A module not on disk beside it is the standard
# library or an installed package, so `import json` is not an import the gate cannot find; a relative
# one that names nothing is.
mkdir -p "$T/py/helpers/inner" "$T/py/ok" "$T/py/cyc" "$T/py/badpkg"
printf '%s\n' 'import json, os' 'import notify_helper' 'notify_helper.go()' > "$T/py/run_alert.py"
printf '%s\n' 'import urllib.request' 'def go():' '    urllib.request.urlopen("https://slack.com/api/chat.postMessage")' > "$T/py/notify_helper.py"
printf '%s\n' 'from helpers.inner import relay' 'relay.go()' > "$T/py/run_pkg.py"
: > "$T/py/helpers/__init__.py"; : > "$T/py/helpers/inner/__init__.py"
printf '%s\n' 'from . import sender' 'def go():' '    sender.send()' > "$T/py/helpers/inner/relay.py"
printf '%s\n' 'def send():' '    return "https://hooks.slack.com/services/T0/B0/x"' > "$T/py/helpers/inner/sender.py"
printf '%s\n' 'from .gone import thing' > "$T/py/badpkg/mod.py"; : > "$T/py/badpkg/__init__.py"
printf '%s\n' 'from badpkg import mod' > "$T/py/run_bad.py"
for posts in "python3 $T/py/run_alert.py" "cd $T/py && python3 run_alert.py" "uv run $T/py/run_alert.py" \
  "python3 $T/py/run_pkg.py"; do
  run_bash "$posts"
  refused "a Python script importing a helper that posts, run as: $posts"
done
run_bash "python3 $T/py/run_alert.py"
says "the refusal names the Python helper" "notify_helper.py"
run_bash "python3 $T/py/run_pkg.py"
says "the refusal names the Python helper three imports deep" "sender.py"
run_bash "python3 $T/py/run_bad.py"
refused "a Python relative import the gate cannot find"
says "the refusal names the relative import it could not find" ".gone"
printf '%s\n' 'import a_mod' 'a_mod.f()' > "$T/py/cyc/main.py"
printf '%s\n' 'import b_mod' 'def f():' '    return b_mod' > "$T/py/cyc/a_mod.py"
printf '%s\n' 'import a_mod' > "$T/py/cyc/b_mod.py"
run_bash "python3 $T/py/cyc/main.py"
allowed "a Python import cycle that names no endpoint ends and passes"
printf '%s\n' 'import json, sys, requests' 'from pathlib import Path' 'from draft_saver import save' 'save("hi")' > "$T/py/ok/main.py"
printf '%s\n' 'from pathlib import Path' 'def save(text):' '    Path("drafts/out.md").write_text(text)  # a draft for Dan' > "$T/py/ok/draft_saver.py"
# The package is installed in the project's own virtual environment, where the gate places it
# (claude-config#2358): an import placed nowhere is refused below.
mkdir -p "$T/py/ok/.venv/lib/python3.12/site-packages/requests"
printf '%s\n' 'home = /usr/bin' > "$T/py/ok/.venv/pyvenv.cfg"
: > "$T/py/ok/.venv/lib/python3.12/site-packages/requests/__init__.py"
run_bash "python3 $T/py/ok/main.py"
allowed "a Python script importing the standard library, a package and a helper that only saves a draft"

echo "slack drafts only: a script run by its path finds its imports where the python its first line names does (claude-config#3144)"
# A command line tool installed by Homebrew in its own virtual environment is a script whose first
# line names that environment's python by its absolute path, with its package installed there. Run by
# its path it was refused, its package placed nowhere, while the same package run as `<that python>
# -m <module>` passed. Each environment here is a folder holding pyvenv.cfg, bin/python (a link to
# python3) and, where one is named, a package in lib/python3.12/site-packages that only prints.
PY3="$(command -v python3)"
sv_env() { # sv_env <folder> [package]
  mkdir -p "$1/bin" "$1/lib/python3.12/site-packages"
  printf '%s\n' 'home = /usr/bin' > "$1/pyvenv.cfg"
  ln -sf "$PY3" "$1/bin/python"
  if [ -n "${2:-}" ]; then
    mkdir -p "$1/lib/python3.12/site-packages/$2/_app"
    : > "$1/lib/python3.12/site-packages/$2/__init__.py"
    : > "$1/lib/python3.12/site-packages/$2/_app/__init__.py"
    printf '%s\n' 'def main():' '    print("select 1")' > "$1/lib/python3.12/site-packages/$2/_app/__main__.py"
  fi
}
sv_tool() { # sv_tool <file> <first line> [module]: an entry point script, as pip writes one
  printf '%s\n' "$2" 'import sys' "from ${3:-fakecli._app.__main__} import main" 'sys.exit(main())' > "$1"
  chmod +x "$1"
}
SV="$T/sv"
sv_env "$SV/env" fakecli
sv_env "$SV/bare"
sv_tool "$SV/env/bin/fake" "#!$SV/env/bin/python"
mkdir -p "$SV/brew/bin" "$SV/other/bin"
ln -s "$SV/env/bin/fake" "$SV/brew/bin/fake"
run_bash "$SV/env/bin/python -m fakecli._app sql -q 'select 1'"
allowed "the control: the package run with -m by its environment's own python"
run_bash "$SV/env/bin/fake sql -q 'select 1'"
allowed "the package's entry point script, run by its path, whose first line names that python"
run_bash "$SV/brew/bin/fake sql -q 'select 1' --format json"
allowed "the same script reached through a link, as Homebrew puts one on the PATH"
run_bash "cd $SV/env && bin/fake sql"
allowed "the same script run by a relative path"
printf '%s\n' '#!/bin/bash' "$SV/env/bin/fake sql" > "$SV/run.sh"
run_bash "bash $SV/run.sh"
allowed "the same script run by its path from a shell script"
# What stays refused. The first line counts only where the script is run by its own path, so the
# kernel starts the python it names; a python typed in the command ignores it.
run_bash "python3 $SV/env/bin/fake sql"
refused "the same script handed to python3, which ignores its first line"
sv_tool "$SV/env/bin/fake-missing" "#!$SV/env/bin/python" "no_such_pkg_3144.cli"
run_bash "$SV/env/bin/fake-missing sql"
refused "a script importing a package its first line's environment does not hold"
says "that refusal names the package placed nowhere" "no_such_pkg_3144"
sv_tool "$SV/other/bin/fake" "#!$SV/bare/bin/python"
run_bash "$SV/other/bin/fake sql"
refused "a script whose first line names an environment without the package"
# Each script's first line places its own imports only: not the other script's in the same command,
# nor one run after it by a shell script.
run_bash "$SV/env/bin/fake sql; $SV/other/bin/fake sql"
refused "two scripts in one command, the second's first line naming an environment without the package"
printf '%s\n' '#!/bin/bash' "$SV/env/bin/fake sql" "$SV/other/bin/fake sql" > "$SV/run-both.sh"
run_bash "bash $SV/run-both.sh"
refused "the same two scripts run from a shell script"
sv_tool "$SV/env/bin/fake-relative" "#!env/bin/python"
run_bash "cd $SV && env/bin/fake-relative sql"
refused "a first line naming the python by a relative path"
ln -sf "$PY3" "$SV/env/bin/python-wrapper"
sv_tool "$SV/env/bin/fake-wrapper" "#!$SV/env/bin/python-wrapper"
run_bash "$SV/env/bin/fake-wrapper sql"
refused "a first line naming a program whose name is not a Python runtime's"
sv_tool "$SV/env/bin/fake-env" "#!/usr/bin/env python3"
run_bash "$SV/env/bin/fake-env sql"
refused "a first line having env find python3 on the PATH, as before"
sv_tool "$SV/env/bin/fake-env-path" "#!/usr/bin/env $SV/env/bin/python"
run_bash "$SV/env/bin/fake-env-path sql"
refused "a first line having env run the environment's python, as before"
printf '%s\n' 'import urllib.request' 'def go():' '    urllib.request.urlopen("https://slack.com/api/chat.postMessage")' \
  > "$SV/env/bin/notify_3144.py"
printf '%s\n' "#!$SV/env/bin/python" 'from fakecli._app.__main__ import main' 'import notify_3144' 'notify_3144.go()' \
  > "$SV/env/bin/fake-posts"
chmod +x "$SV/env/bin/fake-posts"
run_bash "$SV/env/bin/fake-posts sql"
refused "a script whose package is installed there and which imports a helper beside it that posts"
says "that refusal names the helper" "notify_3144"
# An installed package is not read, on either route: one naming the endpoint, installed in the
# environment, passes with -m today, and so through the script whose first line names that python.
# Recorded so the reach of an installed package is a decision, not a surprise.
sv_env "$SV/env" fakepost
printf '%s\n' 'import urllib.request' 'def main():' '    urllib.request.urlopen("https://slack.com/api/chat.postMessage")' \
  > "$SV/env/lib/python3.12/site-packages/fakepost/_app/__main__.py"
sv_tool "$SV/env/bin/fake-installed" "#!$SV/env/bin/python" "fakepost._app.__main__"
run_bash "$SV/env/bin/python -m fakepost._app"
allowed "an installed package is not read when run with -m (as before)"
run_bash "$SV/env/bin/fake-installed"
allowed "nor when its entry point script is run by its path"

echo "slack drafts only: a Python import is placed through PYTHONPATH and sys.path, or refused (claude-config#2358)"

# A helper that posts, found only through PYTHONPATH or a sys.path change: the #2357 gate looked for
# it beside the script alone, took it for an installed package, and let the script through (exit 0).
mkdir -p "$T/pp/lib" "$T/pp/app" "$T/pp/okdir"
printf '%s\n' 'import json, urllib.request' 'def go():' \
  '    urllib.request.urlopen("https://slack.com/api/chat.postMessage", data=json.dumps({"text": "hi"}).encode())' \
  > "$T/pp/lib/pp_notify.py"
printf '%s\n' 'from pathlib import Path' 'def save(text):' '    Path("drafts/out.md").write_text(text)' > "$T/pp/okdir/pp_notify.py"
printf '%s\n' 'import pp_notify' 'pp_notify.go()' > "$T/pp/app/run.py"
printf '%s\n' 'import sys' "sys.path.insert(0, \"$T/pp/lib\")" 'import pp_notify' 'pp_notify.go()' > "$T/pp/app/literal.py"
printf '%s\n' 'import os, sys' 'sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))' \
  'import pp_notify' > "$T/pp/app/beside.py"
printf '%s\n' 'import sys' 'from pathlib import Path' 'sys.path.append(str(Path(__file__).resolve().parent.parent / "lib"))' \
  'from pp_notify import go' > "$T/pp/app/pathlib_append.py"
# The forms measured in this payload's own scripts on 2026-11-07: a name set from __file__ first, a
# string joined with +, and Path(...).parents[n].
printf '%s\n' 'import os, sys' 'HERE = os.path.dirname(os.path.abspath(__file__))' 'sys.path.insert(0, HERE + "/../lib")' \
  'import pp_notify' > "$T/pp/app/named.py"
printf '%s\n' 'import sys' 'from pathlib import Path' 'ROOT = Path(__file__).resolve().parents[1]' \
  'sys.path.insert(0, str(ROOT / "lib"))' 'import pp_notify' > "$T/pp/app/parents.py"
printf '%s\n' 'import json' 'import no_such_helper_2358' 'no_such_helper_2358.go()' > "$T/pp/app/unplaced.py"
for posts in "PYTHONPATH=$T/pp/lib python3 $T/pp/app/run.py" "cd $T/pp && PYTHONPATH=lib python3 app/run.py" \
  "env PYTHONPATH=$T/pp/app/none:$T/pp/lib python3 $T/pp/app/run.py" "export PYTHONPATH=$T/pp/lib; python3 $T/pp/app/run.py" \
  "python3 $T/pp/app/literal.py" "python3 $T/pp/app/beside.py" "python3 $T/pp/app/pathlib_append.py" \
  "python3 $T/pp/app/named.py" "python3 $T/pp/app/parents.py"; do
  run_bash "$posts"
  refused "a Python helper that posts, placed through PYTHONPATH or sys.path, run as: $posts"
done
run_bash "PYTHONPATH=$T/pp/lib python3 $T/pp/app/run.py"
says "the refusal names the helper found on PYTHONPATH" "pp_notify.py"
run_bash "PYTHONPATH=$T/pp/okdir python3 $T/pp/app/run.py"
allowed "the same import placed on PYTHONPATH at a helper that only saves a draft"
# Python imports the first one it finds along PYTHONPATH, so the posting one behind it never runs.
run_bash "PYTHONPATH=$T/pp/okdir:$T/pp/lib python3 $T/pp/app/run.py"
allowed "the import found first on PYTHONPATH at the helper that only saves a draft"
run_bash "python3 $T/pp/app/unplaced.py"
refused "a Python import found nowhere: not beside the script, on PYTHONPATH, standard library or installed"
says "that refusal names the import it could not place" "no_such_helper_2358"
says "that refusal says the gate could not check whether it posts" "could not check whether this command posts to Slack"
case "$ERR" in *"REFUSED: this command posts to Slack"*) check "that refusal does not claim the command posts" "stderr claimed a post: ${ERR:0:300}" ;; *) check "that refusal does not claim the command posts" ok ;; esac
run_bash "PYTHONPATH=$T/pp/lib python3 $T/pp/app/run.py"
says "a script that really posts still gets the posts wording" "REFUSED: this command posts to Slack"
# The wording is chosen by the cause, an import the gate gave up on, never by matching the words that
# cause is put in (lessons review of #2389): a script that posts from a folder whose name holds those
# words still gets the posts wording.
mkdir -p "$T/so it cannot see what"
printf '%s\n' 'await fetch("https://hooks.slack.com/services/T0/B0/x", { method: "POST" });' > "$T/so it cannot see what/post.mjs"
run_bash "node '$T/so it cannot see what/post.mjs'"
says "a script that posts from a folder named like the could not check wording gets the posts wording" \
  "REFUSED: this command posts to Slack"
# run_late.py imports the same helper after a statement that runs, so its import placed nowhere is
# still refused (run.py's, its first statement, is not: claude-config#2631, below).
printf '%s\n' 'import json' 'import pp_notify' 'pp_notify.go()' > "$T/pp/app/run_late.py"
run_bash "python3 $T/pp/app/run_late.py"
refused "the PYTHONPATH script run without it, its import placed nowhere after a statement that runs"
# An export inside a script run in its own shell ends with that shell, so it must not place the
# imports of the commands after it; a sourced one really exports into the caller (claude-config#2409).
printf '%s\n' '#!/bin/bash' "export PYTHONPATH=$T/pp/okdir" > "$T/pp/setexp.sh"
run_bash "bash $T/pp/setexp.sh; python3 $T/pp/app/run_late.py"
refused "an export inside a script run by bash does not place the next command's import"
run_bash "source $T/pp/setexp.sh; python3 $T/pp/app/run_late.py"
allowed "an export inside a sourced script places the next command's import"
run_bash ". $T/pp/setexp.sh && python3 $T/pp/app/run_late.py"
allowed "the same sourced with a dot"
run_bash "cd $T/pp && python3 -c 'import json; import no_such_helper_2358'"
refused "inline Python importing a module placed nowhere after a statement that runs"

echo "slack drafts only: a first statement importing a module found nowhere runs nothing (claude-config#2631)"

# python3 -c "import playwright; print('py ok')" (2026-11-10) and a python3 -I -c "import openpyxl"
# probe after an ffprobe and an ls (2026-11-12) were refused as imports the gate could not follow.
# When the import is the code's first statement and the module is in none of the places the
# interpreter named would look, Python stops with ImportError before anything runs, so nothing can
# reach Slack. The module names are invented, so no test depends on what this Mac has installed (L411).
mkdir -p "$T/probe/media"
: > "$T/probe/media/clip.m4a"
run_bash "python3 -c \"import no_such_probe_2631; print('py ok')\""
allowed "a probe whose first statement imports a module found nowhere"
run_bash "ffprobe -v error -show_entries format_tags -of default=nw=1 \"$T/probe/media/clip.m4a\"; ls \"$T/probe/media/clip.m4a\" 2>&1; python3 -I -c \"import no_such_probe_2631; print('no_such_probe_2631', no_such_probe_2631.__version__)\""
allowed "the same probe with -I as one segment of a longer command"
run_bash "cd $T/probe && python3 -c 'from no_such_probe_2631.sub import thing; thing()'"
allowed "a from import of a package found nowhere as the first statement"
run_bash "python3 $T/pp/app/run.py"
allowed "a script whose first statement imports a helper on no path it is run with"
# The gate's own interpreter named by its path is the same interpreter (the wrapper runs python3).
PYEXE="$(python3 -c 'import sys; print(sys.executable)')"
run_bash "'$PYEXE' -c 'import no_such_probe_2631'"
allowed "the same probe run by the path of the interpreter python3 names"
# What still refuses: a statement that runs before the import, a second import placed nowhere, a
# module Python may find but the gate cannot read, and an interpreter other than the gate's own.
run_bash "python3 -c \"print('x'); import no_such_probe_2631\""
refused "a statement that runs before the import placed nowhere"
run_bash "python3 -c 'import os, no_such_probe_2631'"
refused "an import placed nowhere named after a module that is found"
run_bash "python3 -c 'import no_such_probe_2631; import no_such_other_2631'"
refused "a later import placed nowhere, though the first is too"
says "that refusal names the later import" "no_such_other_2631"
run_bash "python3 -c 'try:
    import no_such_probe_2631
except ImportError:
    pass'"
refused "an import placed nowhere inside a try, whose failure the code carries on past"
mkdir -p "$T/probe/unread" "$T/probe/locked"
printf '%s\n' 'import urllib.request' 'urllib.request.urlopen("https://hooks.slack.com/services/T0/B0/x", data=b"{}")' \
  > "$T/probe/unread/unread_probe_2631.py"
chmod 000 "$T/probe/unread/unread_probe_2631.py" "$T/probe/locked"
run_bash "cd $T/probe/unread && python3 -c 'import unread_probe_2631'"
refused "a first statement importing a module beside it the gate cannot read"
# Run as root, mode 000 still lets the folder be listed, so the case cannot be set up here (L411).
if ls "$T/probe/locked" >/dev/null 2>&1; then
  echo "SUITE-PART-UNMEASURED #2631 a first statement import with a folder on PYTHONPATH the gate cannot list: this user can list a mode 000 folder (running as root), so no unlistable folder could be made"
else
  run_bash "PYTHONPATH=$T/probe/locked python3 -c 'import no_such_probe_2631'"
  refused "a first statement importing a module placed nowhere, with a folder on PYTHONPATH the gate cannot list"
fi
chmod 755 "$T/probe/locked"
chmod 644 "$T/probe/unread/unread_probe_2631.py"
mkdir -p "$T/probe/fakebin"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$T/probe/fakebin/python3"
chmod +x "$T/probe/fakebin/python3"
run_bash "$T/probe/fakebin/python3 -c 'import no_such_probe_2631'"
refused "a first statement importing a module placed nowhere, run by an interpreter other than the gate's own"
run_bash "PATH=$T/probe/fakebin:\$PATH python3 -c 'import no_such_probe_2631'"
refused "the same with PATH changed for the command, so python3 may be another interpreter"
run_bash "uv run python3 -c 'import no_such_probe_2631'"
refused "the same run through a wrapper that chooses its own environment"
run_bash "sudo python3 -c 'import no_such_probe_2631'"
refused "the same run by sudo, whose PATH and user are not the session's"
run_bash "bash -c \"python3 -c 'import no_such_probe_2631'\""
refused "the same run by a wrapper's string"
# The refusal that is left does not tell the session to save a draft when nothing in the command
# names a Slack posting endpoint: it says the gate could not follow the import.
run_bash "python3 -c \"print('x'); import no_such_probe_2631\""
says "a could not follow refusal says what it could not follow" "the gate could not follow"
case "$ERR" in *slack_send_message_draft*) check "that refusal does not tell the session to save a draft" "stderr: ${ERR:0:400}" ;;
  *) check "that refusal does not tell the session to save a draft" ok ;; esac
says "that refusal says nothing in the command names a posting endpoint" "names no Slack posting endpoint"
run_bash "echo https://hooks.slack.com/services/T0/B0/x >/dev/null; python3 -c \"print('x'); import no_such_probe_2631\""
says "a could not follow refusal for a command naming an endpoint still says to save a draft" "slack_send_message_draft"

echo "slack drafts only: a sys.path entry handed to python through a shell variable is placed (claude-config#2449)"

# tests/test-mods.sh runs `python3 - "$ROOT/tools/lib" <<'PY'` and imports ts_source after
# sys.path.insert(0, sys.argv[1]), ROOT set at the top of the script. The #2358 gate could not place
# that entry, so it refused the whole suite (exit 2, measured 2026-11-07). The same script, one tree
# whose helper only saves a draft and one whose helper posts: each shape is allowed in the first and
# refused in the second, so the placed module is judged, never assumed harmless.
av_tree() { # av_tree <dir> <helper body file>: the tree's helper, and every script shape beside it
  mkdir -p "$1/tests" "$1/tools/lib"
  cp "$2" "$1/tools/lib/av_helper.py"
  local top='DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"'
  printf '%s\n' '#!/bin/bash' "$top" 'fc="$(python3 - "$ROOT/tools/lib" <<'"'PY'" 'import sys' 'sys.path.insert(0, sys.argv[1])' \
    'from av_helper import save' 'save("hi")' 'PY' ')"' > "$1/tests/stdin.sh"
  printf '%s\n' '#!/bin/bash' "$top" \
    "out=\"\$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import av_helper' \"\$DIR/../tools/lib\")\"" > "$1/tests/inline.sh"
  printf '%s\n' '#!/bin/bash' 'python3 - "first" "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../tools/lib" <<'"'PY'" \
    'import sys' 'sys.path.insert(0, sys.argv[2])' 'import av_helper' 'PY' > "$1/tests/subst.sh"
  printf '%s\n' '#!/bin/bash' "$top" 'PYTHONPATH="$ROOT/tools/lib" python3 - <<'"'PY'" 'import av_helper' 'PY' > "$1/tests/pypath.sh"
  printf '%s\n' '#!/bin/bash' "$top" 'export LIBDIR="$ROOT/tools/lib"' \
    "python3 -c 'import os, sys; sys.path.insert(0, os.environ[\"LIBDIR\"]); import av_helper'" > "$1/tests/environ.sh"
  # The guards the payload's suites open with, which either do not exit or end the script, and a
  # NAME=value in front of one command, which sets it for that command alone.
  printf '%s\n' '#!/bin/bash' 'if [ -z "${BASH_VERSION:-}" ]; then' '  echo "not bash" >&2' '  exit 2' 'fi' \
    'true || { echo "no"; exit 1; }' 'true || exit $?' "$top" 'ROOT=/nowhere/2449 true' \
    'python3 - "$ROOT/tools/lib" <<'"'PY'" 'import sys' 'sys.path.insert(0, sys.argv[1])' 'import av_helper' 'PY' > "$1/tests/guard.sh"
}
printf '%s\n' 'from pathlib import Path' 'def save(text):' '    Path("drafts/out.md").write_text(text)' > "$T/av_ok.py"
printf '%s\n' 'import json, urllib.request' 'def save(text):' \
  '    urllib.request.urlopen("https://slack.com/api/chat.postMessage", data=json.dumps({"text": text}).encode())' > "$T/av_posts.py"
av_tree "$T/av/ok" "$T/av_ok.py"
av_tree "$T/av/posts" "$T/av_posts.py"
for shape in stdin inline subst pypath environ guard; do
  run_bash "bash $T/av/ok/tests/$shape.sh"
  allowed "a sys.path entry from a shell variable, at a helper that only saves a draft: tests/$shape.sh"
  run_bash "bash $T/av/posts/tests/$shape.sh"
  refused "the same entry at a helper that posts: tests/$shape.sh"
done
# Run as the session runs the suite: by a path relative to the command's directory.
run_bash "cd $T/av/ok && bash tests/stdin.sh"
allowed "the test-mods.sh shape run by its relative path"
run_bash "cd $T/av/posts && bash tests/stdin.sh"
says "the refusal names the placed helper that posts" "av_helper.py"

# The controls: wherever the gate cannot be sure what the argument holds when python starts, the
# entry is placed nowhere and the import is refused, as before.
C="$T/av/ok/tests"
printf '%s\n' '#!/bin/bash' 'python3 - "$NOT_SET_2449/tools/lib" <<'"'PY'" 'import sys' 'sys.path.insert(0, sys.argv[1])' 'import av_helper' 'PY' > "$C/unset.sh"
# Set first to the tree whose helper posts, then, only when X is set, to this one: read in order, the
# last assignment is this tree's, but python is handed the posting tree whenever X is unset.
printf '%s\n' '#!/bin/bash' 'DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"' "ROOT=\"$T/av/posts\"" \
  'if [ -n "${X:-}" ]; then' '  ROOT="$(cd "$DIR/.." && pwd)"' 'fi' \
  'python3 - "$ROOT/tools/lib" <<'"'PY'" 'import sys' 'sys.path.insert(0, sys.argv[1])' 'import av_helper' 'PY' > "$C/twice.sh"
printf '%s\n' '#!/bin/bash' 'DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"' '[ -n "${X:-}" ] && ROOT="$(cd "$DIR/.." && pwd)"' \
  'python3 - "$ROOT/tools/lib" <<'"'PY'" 'import sys' 'sys.path.insert(0, sys.argv[1])' 'import av_helper' 'PY' > "$C/cond.sh"
printf '%s\n' '#!/bin/bash' 'DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"' 'ROOT="$(cd "$DIR/.." && pwd)"' \
  "python3 - '\$ROOT/tools/lib' <<'PY'" 'import sys' 'sys.path.insert(0, sys.argv[1])' 'import av_helper' 'PY' > "$C/quoted.sh"
printf '%s\n' 'ROOT=/nowhere/2449' > "$T/av/ok/tools/rebind.sh"
printf '%s\n' '#!/bin/bash' 'DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"' 'ROOT="$(cd "$DIR/.." && pwd)"' '. "$ROOT/tools/rebind.sh"' \
  'python3 - "$ROOT/tools/lib" <<'"'PY'" 'import sys' 'sys.path.insert(0, sys.argv[1])' 'import av_helper' 'PY' > "$C/rebind.sh"
printf '%s\n' '#!/bin/bash' 'DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"' 'ROOT="$(cd "$DIR/.." && pwd)"' '. "$NOT_SET_2449/lib.sh"' \
  'python3 - "$ROOT/tools/lib" <<'"'PY'" 'import sys' 'sys.path.insert(0, sys.argv[1])' 'import av_helper' 'PY' > "$C/unsourced.sh"
printf '%s\n' '#!/bin/bash' 'DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"' 'ROOT="$(cd "$DIR/.." && pwd)"' \
  'python3 - $NOT_SET_2449 "$ROOT/tools/lib" <<'"'PY'" 'import sys' 'sys.path.insert(0, sys.argv[2])' 'import av_helper' 'PY' > "$C/split.sh"
printf '%s\n' '#!/bin/bash' 'DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"' '( ROOT="$(cd "$DIR/.." && pwd)" )' \
  'python3 - "$ROOT/tools/lib" <<'"'PY'" 'import sys' 'sys.path.insert(0, sys.argv[1])' 'import av_helper' 'PY' > "$C/subshell.sh"
# Set only inside a guard that then exits, so whenever python runs, the guard did not and ROOT is empty.
printf '%s\n' '#!/bin/bash' 'DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"' 'if [ -z "${X:-}" ]; then' \
  '  ROOT="$(cd "$DIR/.." && pwd)"' '  exit 0' 'fi' \
  'python3 - "$ROOT/tools/lib" <<'"'PY'" 'import sys' 'sys.path.insert(0, sys.argv[1])' 'import av_helper' 'PY' > "$C/inguard.sh"
for why in "unset:a variable the script never sets" "twice:a variable set again inside an if" \
  "inguard:a variable set only inside a guard that exits" \
  "cond:a variable set only when an && runs" "quoted:the variable in single quotes, which python gets as written" \
  "rebind:a variable a sourced file sets again" "unsourced:a sourced file the gate cannot find" \
  "split:an unquoted unknown word before the argument, which can split into any number" \
  "subshell:a variable set only inside a subshell"; do
  run_bash "bash $C/${why%%:*}.sh"
  refused "an entry the gate cannot be sure of is placed nowhere and refused: ${why#*:}"
done

# A string the gate cannot read, run by eval in the script's own shell between where ROOT is set and
# where python starts, can set ROOT again, so the entry is no longer certain (claude-config#2654).
# tests/test-mods.sh ran a remedy its checker printed that way, 1,800 lines above its ts_source step,
# and from #2539 on the gate refused the whole suite for it (measured through this wrapper as it
# stood at each change, 2026-11-10: allowed up to #2522, refused from #2539). The gate was applying
# its rule, so the suite changed and the gate did not: the remedy now runs in a subshell, which can
# set nothing in the script. Both halves, each in both trees: the eval in the script's own shell is
# refused whatever the helper does, and the one in a subshell is placed and its helper judged.
ev_top='DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
remedy="$(grep "differs" "$DIR/found.txt" | cut -d: -f2)"'
for tree in ok posts; do
  for how in 'evald:eval "$remedy"' 'subeval:( eval "$remedy" )'; do
    printf '%s\n' '#!/bin/bash' "$ev_top" "[ -n \"\$remedy\" ] && ${how#*:}" \
      'python3 - "$ROOT/tools/lib" <<'"'PY'" 'import sys' 'sys.path.insert(0, sys.argv[1])' 'import av_helper' 'PY' > "$T/av/$tree/tests/${how%%:*}.sh"
  done
done
run_bash "bash $T/av/ok/tests/evald.sh"
refused "a string run by eval in the script's own shell leaves the entry uncertain, at a helper that only saves a draft"
says "that refusal is the import placed nowhere" "av_helper, a module the gate cannot find"
run_bash "bash $T/av/posts/tests/evald.sh"
refused "the same eval at a helper that posts"
run_bash "bash $T/av/ok/tests/subeval.sh"
allowed "the same string run by eval in a subshell sets nothing in the script, so the entry is placed"
run_bash "bash $T/av/posts/tests/subeval.sh"
refused "and the helper placed past a subshell's eval is judged: one that posts"
says "that refusal names the placed helper" "av_helper.py"
# The suite itself, as a session runs it. The fixtures above are shaped like it; this is it, so the
# next change to the walk that refuses it fails here rather than in a session (L48). The installed
# copy of these hooks has no tests/ folder beside it, and says so rather than passing (L411).
MODS_REPO="$(bash "$DIR/lib/checkout-root.sh" "$DIR/.." 2>/dev/null || true)"
if [ -n "$MODS_REPO" ] && [ -f "$MODS_REPO/tests/test-mods.sh" ] && [ -f "$MODS_REPO/tools/lib/ts_source.py" ]; then
  run_bash "cd $MODS_REPO && bash tests/test-mods.sh"
  allowed "the repository's own mods suite, bash tests/test-mods.sh, is not refused (claude-config#2654)"
else
  echo "SUITE-PART-UNMEASURED #2654 the gate allows bash tests/test-mods.sh: $DIR is not in a claude-config checkout holding tests/test-mods.sh (the installed copy of the hooks is not), so the repository's mods suite was not judged here"
fi

# A file the script sources whose function runs its argument by eval in the caller's shell can set
# any name each time it is called, so past that source line the gate is sure of no variable, and an
# import placed by one is placed nowhere (claude-config#2668). lib/hang-wait.sh is such a file: its
# two waits run their condition in the suite's own shell, and what the condition sets is kept
# (test-hang-wait.sh pins that; a subshell there was tried in #2465 and lost what suites read
# back). test-context-size-notice.sh, test-pr-review.sh and the design rounds' test-score-adapters.sh
# each sourced it and then handed python a folder held in a variable. Measured through this wrapper
# on 2026-11-10: each was allowed cut off before that source line and refused from it on, and the
# same import with no such file sourced was allowed. The gate was applying its rule, so the suites
# changed and the gate did not: each spells the folder from BASH_SOURCE where it hands it over,
# which no variable carries. Both halves, each in both trees, and the control with nothing sourced.
# Since #2538 the name is lost at the CALL, not the source: sourcing such a file binds nothing until
# its function is called, and a call whose condition is written out binds only what that condition
# binds. So waitvar.sh calls it with a condition held in a variable, and nocall.sh does not call it.
sw_top='DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"'
sw_py="python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import av_helper'"
for tree in ok posts; do
  printf '%s\n' 'wait_on(){ until eval "$1"; do sleep 1; done; }' > "$T/av/$tree/tools/waits.sh"
  printf '%s\n' '#!/bin/bash' "$sw_top" "$sw_py \"\$ROOT/tools/lib\"" > "$T/av/$tree/tests/nowait.sh"
  printf '%s\n' '#!/bin/bash' "$sw_top" '. "$ROOT/tools/waits.sh"' 'wait_on "$c"' "$sw_py \"\$ROOT/tools/lib\"" \
    > "$T/av/$tree/tests/waitvar.sh"
  printf '%s\n' '#!/bin/bash' "$sw_top" '. "$ROOT/tools/waits.sh"' "$sw_py \"\$ROOT/tools/lib\"" > "$T/av/$tree/tests/nocall.sh"
  printf '%s\n' '#!/bin/bash' "$sw_top" '. "$ROOT/tools/waits.sh"' \
    "$sw_py \"\$(cd \"\$(dirname \"\${BASH_SOURCE[0]}\")/..\" && pwd)/tools/lib\"" > "$T/av/$tree/tests/waitspelt.sh"
done
run_bash "bash $T/av/ok/tests/nowait.sh"
allowed "an entry held in a variable is placed where the script sources nothing"
run_bash "bash $T/av/ok/tests/waitvar.sh"
refused "past a sourced file whose function runs its argument by eval, an entry held in a variable is uncertain, at a helper that only saves a draft"
says "that refusal is the import placed nowhere" "av_helper, a module the gate cannot find"
run_bash "bash $T/av/posts/tests/waitvar.sh"
refused "the same entry at a helper that posts"
run_bash "bash $T/av/ok/tests/nocall.sh"
allowed "past the same sourced file with its function never called, an entry held in a variable is placed"
run_bash "bash $T/av/posts/tests/nocall.sh"
refused "and the helper placed that way is judged: one that posts"
says "that refusal names the helper placed past the uncalled function" "av_helper.py"
run_bash "bash $T/av/ok/tests/waitspelt.sh"
allowed "past the same sourced file, an entry spelt from BASH_SOURCE where it is handed over is placed"
run_bash "bash $T/av/posts/tests/waitspelt.sh"
refused "and the helper placed that way is judged: one that posts"
says "that refusal names the placed helper" "av_helper.py"
# A module the script copies somewhere and imports from there is not on disk when the gate reads the
# script, so it is placed nowhere. test-shell-code-lines.sh did that to show its reader refusing
# with no shell-words.py beside it: it copied the reader alone into a throwaway folder and imported
# the copy (allowed cut off before that step, refused from it on). The suite now imports the
# reader from lib/ and points the one load of shell-words.py at an empty folder, so everything that
# runs is on disk for the gate to read. Both halves, each in both trees.
for tree in ok posts; do
  printf '%s\n' '#!/bin/bash' "$sw_top" 'W="$(mktemp -d)"' 'cp "$ROOT/tools/lib/av_helper.py" "$W/"' "$sw_py \"\$W\"" > "$T/av/$tree/tests/copied.sh"
  printf '%s\n' '#!/bin/bash' "$sw_top" 'W="$(mktemp -d)"' "python3 -c '" 'import importlib.util, os, sys' \
    'found = importlib.util.spec_from_file_location' 'def elsewhere(name, location=None, *rest, **more):' \
    '    return found(name, os.path.join(sys.argv[2], os.path.basename(str(location))), *rest, **more)' \
    'importlib.util.spec_from_file_location = elsewhere' 'sys.path.insert(0, sys.argv[1])' 'import av_helper' \
    "' \"\$ROOT/tools/lib\" \"\$W\"" > "$T/av/$tree/tests/pointed.sh"
done
run_bash "bash $T/av/ok/tests/copied.sh"
refused "a module the script copies into a throwaway folder and imports from there is placed nowhere, at a helper that only saves a draft"
says "that refusal is the import placed nowhere" "av_helper, a module the gate cannot find"
run_bash "bash $T/av/posts/tests/copied.sh"
refused "the same copy of a helper that posts"
run_bash "bash $T/av/ok/tests/pointed.sh"
allowed "the helper imported from where it is kept, by code that points a later load by path at an empty folder, is placed"
run_bash "bash $T/av/posts/tests/pointed.sh"
refused "and the helper imported that way is judged: one that posts"
says "that refusal names the placed helper" "av_helper.py"
# The four suites themselves, as a session runs them. The fixtures above are shaped like them; these
# are them, so the next change to the walk, or to a suite, that gets one refused fails here rather
# than in a session (L48). All four are in the installed copy too, one folder shallower, and a copy
# that lacks one says so rather than passing (L411).
if [ -n "$MODS_REPO" ] && [ "$MODS_REPO/payload/hooks" -ef "$DIR" ]; then
  sw_from="$MODS_REPO"; sw_pre="payload/"
else
  sw_from="$(cd "$DIR/.." && pwd)"; sw_pre=""
fi
for sw_suite in hooks/test-context-size-notice.sh hooks/test-pr-review.sh hooks/test-shell-code-lines.sh \
  skills/design-rounds/score/test-score-adapters.sh; do
  if [ -f "$sw_from/$sw_pre$sw_suite" ]; then
    run_bash "cd $sw_from && bash $sw_pre$sw_suite"
    allowed "a suite of this repository is not refused when a session runs it: bash $sw_pre$sw_suite (claude-config#2668)"
  else
    echo "SUITE-PART-UNMEASURED #2668 the gate allows bash $sw_pre$sw_suite: $sw_from/$sw_pre$sw_suite is not there, so that suite was not judged here"
  fi
done
# The scripts a sweep of every tracked shell script found refused once a file run through a variable
# was read (claude-config#2678, 530 scripts on 2026-11-10), each fixed in the script and never in the
# gate: the tally notice handed its inline python a folder that started from an environment variable,
# the replay suite's fixture maker spelt a module path inside two strings it writes, and the README
# table suite handed README.md, which names an endpoint, to a script that can act. As a session runs
# them, so a change to one of them, or to the walk, that gets it refused again fails here (L48). The
# first two are in the installed copy too; the last two live only in the repository (L411).
for sw_suite in hooks/verification-tally-notice.sh hooks/test-require-verification-run.sh; do
  if [ -f "$sw_from/$sw_pre$sw_suite" ]; then
    run_bash "cd $sw_from && bash $sw_pre$sw_suite"
    allowed "a script of this repository is not refused when a session runs it: bash $sw_pre$sw_suite (claude-config#2678)"
  else
    echo "SUITE-PART-UNMEASURED #2678 the gate allows bash $sw_pre$sw_suite: $sw_from/$sw_pre$sw_suite is not there, so that script was not judged here"
  fi
done
for sw_suite in tests/test-readme-mods-table.sh tools/test-area-check-replay.sh; do
  if [ -n "$MODS_REPO" ] && [ -f "$MODS_REPO/$sw_suite" ]; then
    run_bash "cd $MODS_REPO && bash $sw_suite"
    allowed "a suite of this repository is not refused when a session runs it: bash $sw_suite (claude-config#2678)"
  else
    echo "SUITE-PART-UNMEASURED #2678 the gate allows bash $sw_suite: $DIR is not in a claude-config checkout holding $sw_suite (the installed copy of the hooks is not), so that suite was not judged here"
  fi
done

# A file a script runs by a path the gate can work out is read as one run by a literal path is
# (claude-config#2678). Measured through this wrapper on 2026-11-10, in a script whose first lines
# set ROOT from BASH_SOURCE: `python3 /the/tree/tools/lib/act.py` was refused where act.py posts,
# and `python3 "$ROOT/tools/lib/act.py"` was allowed, as the same file was with python3 -B, bash,
# sh and node, run by its own path, through $DIR/.., by a path spelt from BASH_SOURCE, and in a
# command that sets the variable itself. A word holding a variable or a substitution was never
# worked out where the program runs a file, so there was no file to read. Each shape in both trees:
# allowed where the file only saves a draft, refused where it posts, naming the file.
rv_top='DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"'
rv_shapes=(
  'py:python3 "$ROOT/tools/lib/act.py"'
  'pyb:python3 -B "$ROOT/tools/lib/act.py" 2>&1'
  'bash:bash "$ROOT/tools/lib/act.sh"'
  'sh:sh "$ROOT/tools/lib/act.sh"'
  'node:node "$ROOT/tools/lib/act.js"'
  'own:"$ROOT/tools/lib/act.sh"'
  'dir:python3 "$DIR/../tools/lib/act.py"'
  'spelt:python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tools/lib/act.py"'
)
for tree in ok posts; do
  mkdir -p "$T/rv/$tree/tests" "$T/rv/$tree/tools/lib"
  printf '%s\n' 'wait_on(){ until eval "$1"; do sleep 1; done; }' > "$T/rv/$tree/tools/waits.sh"
  for shape in "${rv_shapes[@]}"; do
    printf '%s\n' '#!/bin/bash' "$rv_top" "${shape#*:}" > "$T/rv/$tree/tests/${shape%%:*}.sh"
  done
  # Its function called with a condition held in a variable, which since #2538 is where the name is
  # lost (sourcing the file alone binds nothing).
  printf '%s\n' '#!/bin/bash' "$rv_top" '. "$ROOT/tools/waits.sh"' 'wait_on "$c"' 'python3 "$ROOT/tools/lib/act.py"' \
    > "$T/rv/$tree/tests/waited.sh"
  printf '%s\n' '#!/bin/bash' 'python3 "$NOT_SET_2678/tools/lib/act.py"' > "$T/rv/$tree/tests/unset.sh"
done
printf '%s\n' 'from pathlib import Path' 'Path("drafts/out.md").write_text("hi")' > "$T/rv/ok/tools/lib/act.py"
printf '%s\n' "printf '%s\\n' hi > drafts/out.md" > "$T/rv/ok/tools/lib/act.sh"
printf '%s\n' 'console.log("hi");' > "$T/rv/ok/tools/lib/act.js"
printf '%s\n' 'import json, urllib.request' \
  'urllib.request.urlopen("https://slack.com/api/chat.postMessage", data=json.dumps({"text": "hi"}).encode())' > "$T/rv/posts/tools/lib/act.py"
printf '%s\n' 'curl -s -X POST https://slack.com/api/chat.postMessage -d channel=C1 -d text=hi' > "$T/rv/posts/tools/lib/act.sh"
printf '%s\n' 'fetch("https://slack.com/api/chat.postMessage", { method: "POST", body: JSON.stringify({ text: "hi" }) });' > "$T/rv/posts/tools/lib/act.js"
for shape in "${rv_shapes[@]}"; do
  run_bash "bash $T/rv/ok/tests/${shape%%:*}.sh"
  allowed "a file run by a path the gate works out, where it only saves a draft: ${shape#*:}"
  run_bash "bash $T/rv/posts/tests/${shape%%:*}.sh"
  refused "the same where the file posts: ${shape#*:}"
  says "that refusal names the file: ${shape#*:}" "/tools/lib/act."
done
run_bash "V=$T/rv/ok/tools/lib; python3 \"\$V/act.py\""
allowed "a command that sets a variable and runs a file through it, where the file only saves a draft"
run_bash "V=$T/rv/posts/tools/lib; python3 \"\$V/act.py\""
refused "the same command where the file posts"
says "that refusal names the file" "/tools/lib/act.py"
# A path the gate cannot work out is not read, and NOT refused with #2683's switch off: past a call
# to a sourced function that runs its argument by eval (the #2668 shape), and through a variable
# the script never sets. Pinned here so that turning it on is a change somebody makes on purpose.
run_bash "bash $T/rv/posts/tests/waited.sh"
allowed "a posting file run through a variable the gate is no longer sure of is not read, as before"
run_bash "bash $T/rv/posts/tests/unset.sh"
allowed "a posting file run through a variable the script never sets is not read, as before"

# Code given inline or fed on standard input imports from the directory it runs in.
run_bash "cd $T/py && python3 -c 'import notify_helper; notify_helper.go()'"
refused "python3 -c importing a helper that posts"
run_bash "cd $T/imp && node -e 'require(\"./lib/notify\")()'"
refused "node -e requiring a helper that posts"
says "the inline refusal names the helper" "index.js"
run_bash "cd $T/py && python3 - <<'PY'
import notify_helper
notify_helper.go()
PY"
refused "a Python script fed on standard input importing a helper that posts"
run_bash "cd $T/py && python3 -c 'import json; print(json.dumps(1))'"
allowed "python3 -c importing only the standard library"
run_bash "cd $T/imp && node -e 'console.log(require(\"node:fs\").existsSync(\"x\"))'"
allowed "node -e requiring only a builtin"
run_bash "cat $T/rd/src/digest.ts"
allowed "reading the importing script runs nothing"

echo
sdg_harness_result
