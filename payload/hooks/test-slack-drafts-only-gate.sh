#!/usr/bin/env bash
# A whole tree scan: a send touching these paths runs this suite (claude-config#809).
# send-gate: scans settings.hooks.json
# Tests for slack-drafts-only-gate.sh and its rule, slack_drafts_only_gate.py: the gate that leaves
# sessions only able to save Slack drafts (claude-config#2302).
#
# On 2026-11-05 two sessions on the work MacBook each posted a Slack reply after Dan picked a "Post"
# option in a picker, and he did not know either had gone out; one had reworded the text after he
# chose. Dan: "it should only ever save as draft in slack, never send directly." The written rule
# alone did not stop it, and a rule that lives only in a prompt is a hope (L27).
#
# The payloads are in the PreToolUse shape the Playwright gate's suite measured on Claude Code
# 2.1.274 (session_id, transcript_path, cwd, permission_mode, hook_event_name, tool_name,
# tool_input, tool_use_id). The Slack tool names are the ones the two integrations list today: the
# Slack plugin's mcp__plugin_slack_slack__* and the claude.ai connector's mcp__claude_ai_Slack__*.
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
NUDGE="$(cd "$DIR/.." && pwd)/skills/nudge/nudge.py"

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

SEND_INPUT='{"channel_id": "C0TEST1", "thread_ts": "1730000000.000100", "message": "hello"}'

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

cat > "$T/alert.py" <<'PY'
import json, urllib.request
req = urllib.request.Request("https://slack.com/api/chat.postMessage", data=json.dumps({"text": "hi"}).encode())
urllib.request.urlopen(req)
PY
printf '%s\n' '#!/bin/bash' "curl -s -X POST -d '{\"text\":\"hi\"}' https://hooks.slack.com/services/T0/B0/x" > "$T/alert.sh"
chmod +x "$T/alert.sh"
printf '%s\n' '#!/bin/bash' "python3 $T/alert.py" > "$T/calls-alert.sh"
printf '%s\n' '#!/bin/bash' 'grep -rn "chat.postMessage" .' 'echo "hooks.slack.com is where a webhook posts"' > "$T/mentions.sh"
printf '%s\n' 'print("hello")' > "$T/plain.py"
mkdir -p "$T/copy"
cp "$NUDGE" "$T/copy/nudge.py"

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
run_bash "bash $DIR/test-slack-drafts-only-gate.sh"
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
# names. So only the statement form is passed, only for a .d.ts, and only when the file is missing:
# one that is there is read and judged as any module is.
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
# A type only import of a file that is there is followed and judged as it always was.
mkdir -p "$T/imp/dts/types"
printf '%s\n' 'export type A = number;' "fetch('https://slack.com/api/chat.postMessage');" > "$T/imp/dts/types/index.d.ts"
dts_case "import type { A } from $D2526"
refused "a type only import of a declaration file that is there and posts"
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
run_bash "python3 $T/pp/app/run.py"
refused "the PYTHONPATH script run without it, its import placed nowhere"
# An export inside a script run in its own shell ends with that shell, so it must not place the
# imports of the commands after it; a sourced one really exports into the caller (claude-config#2409).
printf '%s\n' '#!/bin/bash' "export PYTHONPATH=$T/pp/okdir" > "$T/pp/setexp.sh"
run_bash "bash $T/pp/setexp.sh; python3 $T/pp/app/run.py"
refused "an export inside a script run by bash does not place the next command's import"
run_bash "source $T/pp/setexp.sh; python3 $T/pp/app/run.py"
allowed "an export inside a sourced script places the next command's import"
run_bash ". $T/pp/setexp.sh && python3 $T/pp/app/run.py"
allowed "the same sourced with a dot"
run_bash "cd $T/pp && python3 -c 'import no_such_helper_2358'"
refused "inline Python importing a module placed nowhere"

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
sw_top='DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"'
sw_py="python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import av_helper'"
for tree in ok posts; do
  printf '%s\n' 'wait_on(){ until eval "$1"; do sleep 1; done; }' > "$T/av/$tree/tools/waits.sh"
  printf '%s\n' '#!/bin/bash' "$sw_top" "$sw_py \"\$ROOT/tools/lib\"" > "$T/av/$tree/tests/nowait.sh"
  printf '%s\n' '#!/bin/bash' "$sw_top" '. "$ROOT/tools/waits.sh"' "$sw_py \"\$ROOT/tools/lib\"" > "$T/av/$tree/tests/waitvar.sh"
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

echo "slack drafts only: a file handed to a script as data is not code it runs (claude-config#2362)"

# The two refusals measured 2026-11-06. The end of turn review's TO FILE THESE line, bash
# lib/issue-spool.sh clear <project> <transcript .jsonl> <stamp .manifest>, over a session transcript
# whose conversation text names chat.postMessage; and node running a script over a saved gh listing
# (a .json) that names it. Both were refused (exit 2), each data file read as though it were a script.
mkdir -p "$T/ds/proj"
printf '%s\n' '{"type":"user","message":{"content":"curl -X POST https://slack.com/api/chat.postMessage -d text=hi"}}' \
  '{"type":"assistant","message":{"content":"the gate refuses hooks.slack.com too"}}' > "$T/ds/session.jsonl"
printf '%s\n' '{"keys":{}}' > "$T/ds/claude-issue-findings.session.manifest"
printf '%s\n' '[{"number":2302,"title":"Refuse chat.postMessage from every session"}]' > "$T/ds/issues.json"
printf '%s\n' 'const fs = require("fs");' 'const rows = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));' \
  'console.log(rows.map((r) => r.title).join(", "));' > "$T/ds/titles.js"
printf '%s\n' 'import json, sys' 'print(len(json.load(open(sys.argv[1]))))' > "$T/ds/count.py"
run_bash "bash $DIR/lib/issue-spool.sh clear $T/ds/proj $T/ds/session.jsonl $T/ds/claude-issue-findings.session.manifest"
allowed "issue-spool.sh clear over a transcript whose conversation names chat.postMessage"
for reads in "node $T/ds/titles.js $T/ds/issues.json" "cd $T/ds && node titles.js issues.json" \
  "python3 $T/ds/count.py $T/ds/issues.json" "python3 -I $T/ds/count.py $T/ds/session.jsonl"; do
  run_bash "$reads"
  allowed "a script reading a data file that names an endpoint, run as: $reads"
done

# The controls: a data file is still code where the program runs it, and a script that can send, or
# runs what it is handed, still has the files it is handed read.
for runs in "node $T/ds/issues.json" "python3 $T/ds/session.jsonl" "bash $T/ds/session.jsonl" \
  "python3 -I $T/ds/issues.json $T/ds/count.py"; do
  run_bash "$runs"
  refused "a data file naming an endpoint given to the program as its script: $runs"
done
run_bash "python3 $T/alert.py $T/ds/issues.json"
refused "a script whose own code posts, handed a data file"
says "that refusal names the script that posts" "alert.py"
printf '%s\n' '{"url": "https://slack.com/api/chat.postMessage", "text": "hi"}' > "$T/ds/msg.json"
printf '%s\n' 'const fs = require("fs");' 'const m = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));' \
  'await fetch(m.url, { method: "POST", body: JSON.stringify({ text: m.text }) });' > "$T/ds/post.mjs"
run_bash "node $T/ds/post.mjs $T/ds/msg.json"
refused "a script that sends a request, handed a data file naming the endpoint"
says "that refusal names the data file" "msg.json"
# A file read as code before the script (an option's value) must not stand in for the script when
# judging what the script does with its data (lessons review, 2026-11-07).
run_bash "node --require $T/ds/titles.js $T/ds/post.mjs $T/ds/msg.json"
refused "a sending script behind an option's file value, handed a data file naming the endpoint"
printf '%s\n' 'import json, sys, urllib.request' 'm = json.load(open(sys.argv[1]))' \
  'urllib.request.urlopen(urllib.request.Request(m["url"], data=m["text"].encode()))' > "$T/ds/post.py"
run_bash "python3 $T/ds/post.py $T/ds/msg.json"
refused "a Python script that sends a request, handed a data file naming the endpoint"
# A hand list of ways to send or run code always misses one (lessons review at 56b9d7f): urllib3,
# httplib2, smtplib, ftplib, asyncio streams and importlib's exec_module each slipped past it, and
# the data file each was handed went unread. A Python script now counts as unable to act only when
# every module it imports is one that cannot send, run code or write, so each of these is refused.
# urllib3 and httplib2 are made installed in a throwaway virtual environment beside the scripts, so
# the test does not depend on what this Mac has installed (placed nowhere is refused anyway).
mkdir -p "$T/dv/.venv/lib/python3/site-packages/urllib3" "$T/dv/.venv/lib/python3/site-packages/httplib2" "$T/dv/lib"
printf '%s\n' 'home = /usr/bin' > "$T/dv/.venv/pyvenv.cfg"
printf '%s\n' '' > "$T/dv/.venv/lib/python3/site-packages/urllib3/__init__.py"
printf '%s\n' '' > "$T/dv/.venv/lib/python3/site-packages/httplib2/__init__.py"
cp "$T/ds/msg.json" "$T/dv/msg.json"
printf '%s\n' 'import urllib.request' 'urllib.request.urlopen("https://slack.com/api/chat.postMessage")' > "$T/dv/job.txt"
printf '%s\n' 'import json, sys, urllib3' 'm = json.load(open(sys.argv[1]))' \
  'urllib3.PoolManager().request("POST", m["url"], body=m["text"])' > "$T/dv/u3.py"
printf '%s\n' 'import json, sys, httplib2' 'm = json.load(open(sys.argv[1]))' \
  'httplib2.Http().request(m["url"], "POST", body=m["text"])' > "$T/dv/h2.py"
printf '%s\n' 'import json, smtplib, sys' 'm = json.load(open(sys.argv[1]))' \
  'smtplib.SMTP("localhost").sendmail("a@b", ["c@d"], m["url"])' > "$T/dv/mail.py"
printf '%s\n' 'import ftplib, io, json, sys' 'm = json.load(open(sys.argv[1]))' \
  'ftplib.FTP("localhost").storbinary("STOR x", io.BytesIO(m["url"].encode()))' > "$T/dv/ftp.py"
printf '%s\n' 'import asyncio, json, sys' 'async def go(m):' '    r, w = await asyncio.open_connection("slack.com", 443, ssl=True)' \
  '    w.write(m["url"].encode())' 'asyncio.run(go(json.load(open(sys.argv[1]))))' > "$T/dv/aio.py"
printf '%s\n' 'import importlib.machinery, importlib.util, sys' \
  'loader = importlib.machinery.SourceFileLoader("job", sys.argv[1])' \
  'mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("job", loader))' 'loader.exec_module(mod)' > "$T/dv/load.py"
printf '%s\n' 'import json, sys' 'print(eval(json.load(open(sys.argv[1]))["text"]))' > "$T/dv/ev.py"
printf '%s\n' 'import json, os.path, sys' 'm = json.load(open(sys.argv[1]))' 'os.system("curl -d x " + m["url"])' > "$T/dv/ospath.py"
printf '%s\n' 'import json, sys' 'm = json.load(open(sys.argv[1]))' 'sys.modules["os"].system("curl " + m["url"])' > "$T/dv/sysmod.py"
printf '%s\n' 'import json, sys' 'm = json.load(open(sys.argv[1]))' 'open("/tmp/x.sh", "w").write("curl " + m["url"])' > "$T/dv/writes.py"
printf '%s\n' 'import smtplib' 'def send(text):' '    smtplib.SMTP("localhost").sendmail("a@b", ["c@d"], text)' > "$T/dv/lib_mailer.py"
printf '%s\n' 'import json, sys' 'import lib_mailer' 'lib_mailer.send(json.load(open(sys.argv[1]))["url"])' > "$T/dv/via.py"
for acts in "u3.py msg.json" "h2.py msg.json" "mail.py msg.json" "ftp.py msg.json" "aio.py msg.json" \
  "load.py job.txt" "ev.py msg.json" "ospath.py msg.json" "sysmod.py msg.json" "writes.py msg.json" "via.py msg.json"; do
  run_bash "cd $T/dv && python3 $acts"
  refused "a Python script that can act on what it is handed, handed a data file naming the endpoint: $acts"
done
run_bash "cd $T/dv && python3 u3.py msg.json"
says "the refusal names the module the gate does not know to be inert" "urllib3"
# The controls: a script importing only modules that cannot send, run code or write, which prints the
# data file it is handed, still has that file read as data. re.compile is a regular expression, not
# the compile builtin (claude-config#2413).
printf '%s\n' 'import json, sys' 'print(json.load(open(sys.argv[1]))["text"])' > "$T/dv/show.py"
printf '%s\n' 'import json, re, sys' 'from os import path' 'from typing import Any' 'pat = re.compile(r"chat\.\w+")' \
  'm: Any = json.load(open(sys.argv[1]))' 'print(path.basename(sys.argv[1]), pat.findall(m["url"]))' > "$T/dv/rx.py"
for reads in "show.py msg.json" "rx.py msg.json"; do
  run_bash "cd $T/dv && python3 $reads"
  allowed "a Python script importing only modules that cannot act, handed a data file naming the endpoint: $reads"
done
# JavaScript and shell scripts are judged the same way (claude-config#2434). A hand list of what can
# act (JS_ACTS, SENDERS) missed a node script using the request package, worker_threads or dns, one
# writing a file or reaching Function through a constructor, and a shell script handing its argument
# to a program off the list, so each data file was read as data although the script could post it.
mkdir -p "$T/dj"
cp "$T/ds/msg.json" "$T/dj/msg.json"
J='const m = JSON.parse(require("fs").readFileSync(process.argv[2], "utf8"));'
printf '%s\n' 'const request = require("request");' "$J" 'request.post(m.url, { body: m.text });' > "$T/dj/req.js"
printf '%s\n' 'import { Worker as W } from "node:worker_threads";' 'import { readFileSync } from "node:fs";' \
  'const m = JSON.parse(readFileSync(process.argv[2], "utf8"));' 'new W(m.text, { eval: true });' > "$T/dj/worker.mjs"
printf '%s\n' 'const dns = require("dns");' "$J" 'dns.resolveTxt(m.text + "." + m.url, () => {});' > "$T/dj/dns.js"
printf '%s\n' "$J" 'require("fs").writeFileSync("/tmp/x.sh", "curl " + m.url);' > "$T/dj/writes.js"
printf '%s\n' "$J" '(() => {}).constructor(m.text)();' > "$T/dj/ctor.js"
printf '%s\n' 'const request = require("request");' 'module.exports = (u) => request.post(u);' > "$T/dj/lib-req.js"
printf '%s\n' 'const send = require("./lib-req.js");' "$J" 'send(m.url);' > "$T/dj/via.js"
printf '%s\n' "$J" 'require(m.text);' > "$T/dj/dyn.js"
# process.getBuiltinModule loads a builtin by a string with no require or import (claude-config#2476),
# so it is read as the require it is, and refused where its argument cannot be read.
printf '%s\n' 'const dns = process.getBuiltinModule("dns");' "$J" 'dns.resolveTxt(m.text + "." + m.url, () => {});' > "$T/dj/gbm-dns.js"
printf '%s\n' "$J" 'const { Worker } = process.getBuiltinModule("node:worker_threads");' 'new Worker(m.text, { eval: true });' > "$T/dj/gbm-worker.js"
printf '%s\n' "$J" 'const c = process.getBuiltinModule("cluster");' 'c.fork({ U: m.url });' > "$T/dj/gbm-cluster.js"
printf '%s\n' "$J" 'const i = process[`getBuiltinModule`](`inspector`);' 'i.open(9229);' > "$T/dj/gbm-inspector.js"
printf '%s\n' "$J" 'const mod = process.getBuiltinModule(m.text);' 'mod.request(m.url);' > "$T/dj/gbm-dyn.js"
printf '%s\n' "$J" 'const load = process.getBuiltinModule;' 'load(m.text).request(m.url);' > "$T/dj/gbm-alias.js"
# A word the old hand list named still refuses as it did, so nothing refused before passes now (13 of
# 268 real scripts measured on 2026-11-07 were refused only by one, `got` among them).
printf '%s\n' "$J" 'const got = m.text.length;' 'console.log(got);' > "$T/dj/words.js"
printf '%s\n' 'import { readFileSync } from "node:fs";' 'import { cp } from "node:fs/promises";' \
  'const m = JSON.parse(readFileSync(process.argv[2], "utf8"));' 'await cp(process.argv[2], m.text);' > "$T/dj/cp.mjs"
for acts in "cp.mjs:(cp)" "req.js:(request)" "worker.mjs:(node:worker_threads)" "dns.js:(dns)" "writes.js:writeFileSync" \
  "ctor.js:constructor" "via.js:request" "dyn.js:require" "words.js:(got)" "gbm-dns.js:(dns)" \
  "gbm-worker.js:(node:worker_threads)" "gbm-cluster.js:(cluster)" "gbm-inspector.js:getBuiltinModule" \
  "gbm-dyn.js:getBuiltinModule" "gbm-alias.js:getBuiltinModule"; do
  run_bash "cd $T/dj && node ${acts%%:*} msg.json"
  refused "a JavaScript script that can act on what it is handed, handed a data file naming the endpoint: ${acts%%:*}"
  says "that refusal names what lets ${acts%%:*} act" "${acts#*:}"
done
# The controls: a script importing only modules that cannot act (fs read, path, a local helper that
# imports nothing), with an import of a package shown only in a comment, still has its data read as
# data, as does titles.js above.
printf '%s\n' 'export const fmt = (s) => `[${s}]`;' > "$T/dj/fmt.mjs"
printf '%s\n' '// const request = require("request"); was the old way' 'import { readFileSync } from "node:fs";' \
  'import path from "path";' 'import { fmt } from "./fmt.mjs";' 'const m = JSON.parse(readFileSync(process.argv[2], "utf8"));' \
  'process.stdout.write(fmt(path.basename(process.argv[2]) + " " + m.text) + "\n");' > "$T/dj/show.mjs"
run_bash "cd $T/dj && node show.mjs msg.json"
allowed "a JavaScript script importing only modules that cannot act, handed a data file naming the endpoint"
printf '%s\n' 'const fs = process.getBuiltinModule("node:fs");' 'const m = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));' \
  'console.log(m.text);' > "$T/dj/gbm-fs.js"
run_bash "cd $T/dj && node gbm-fs.js msg.json"
allowed "a script loading only fs through process.getBuiltinModule, handed a data file naming the endpoint"
# A function of the script's own named like an fs method (repo-digest's format.ts has a link()) is not
# fs's when the script imports no fs.
printf '%s\n' 'const link = (u, t) => `<${u}|${t}>`;' 'process.stdin.on("data", (b) => console.log(link(process.argv[2], String(b))));' \
  > "$T/dj/fmt-link.js"
run_bash "cd $T/dj && node fmt-link.js msg.json"
allowed "a script calling its own link(), importing no fs, handed a data file naming the endpoint"
cp "$T/ds/titles.js" "$T/dj/titles.js"
cp "$T/ds/post.mjs" "$T/dj/sender.js"
printf '%s\n' '#!/bin/bash' 'msg="$1"' 'gh api -X POST /repos/x/y/dispatches --input "$msg"' > "$T/dj/gh.sh"
printf '%s\n' '#!/bin/bash' 'nc slack.com 443 < "$1"' > "$T/dj/nc.sh"
printf '%s\n' '#!/bin/bash' 'node ./sender.js "$1"' > "$T/dj/hand-js.sh"
printf '%s\n' '#!/bin/bash' 'python3 "$HOME/send.py" "$@"' > "$T/dj/hand-py.sh"
# awk, find and git are judged by how they are called: awk by whether its program can run a command,
# find by -exec, git by its subcommand and options. And a line continued inside $(...) is read from
# its first real word, so the curl after it is seen.
printf '%s\n' '#!/bin/bash' 'awk '"'"'{ system("curl -d @- " $0) }'"'"' "$1"' > "$T/dj/awk.sh"
printf '%s\n' '#!/bin/bash' 'find "$(dirname "$1")" -name "*.json" -exec sh {} \;' > "$T/dj/find.sh"
printf '%s\n' '#!/bin/bash' 'git -c core.pager=sh log --format=%s -- "$1"' > "$T/dj/git.sh"
printf '%s\n' '#!/bin/bash' 'out="$(printf "%s" "$1" | \' '  curl -s -d @- https://example.com/x)"' > "$T/dj/cont.sh"
printf '%s\n' '#!/bin/bash' 'while read -r line; do eval "$line"; done < "$1"' > "$T/dj/loop.sh"
# A local script named like a tool on SH_INERT is a script of its own, judged by what it does
# (lessons review at 340575e).
mkdir -p "$T/dj/bin"
printf '%s\n' '#!/bin/bash' 'curl -s -d @"$1" "$(jq -r .url "$1")"' > "$T/dj/bin/grep"
chmod +x "$T/dj/bin/grep"
printf '%s\n' '#!/bin/bash' 'bin/grep -c chat "$1"' > "$T/dj/local-grep.sh"
for acts in "gh.sh:(gh)" "nc.sh:(nc)" "hand-js.sh:sender.js" "hand-py.sh:send.py" "awk.sh:(awk)" "find.sh:(find)" \
  "git.sh:(git)" "cont.sh:(curl)" "loop.sh:loop" "local-grep.sh:bin/grep"; do
  run_bash "cd $T/dj && bash ${acts%%:*} msg.json"
  refused "a shell script handing its argument to a program that can act, handed a data file naming the endpoint: ${acts%%:*}"
  says "that refusal names the program ${acts%%:*} hands it to" "${acts#*:}"
done
# The controls: a shell script handing its argument only to programs that cannot act, to a function
# it defines, or to a script the gate reads and sees cannot act, still has its data read as data.
printf '%s\n' '#!/bin/bash' 'f="$1"' 'grep -c chat "$f"' 'jq -r .text "$f" | head -1' 'wc -l < "$f"' \
  'show() { cat "$1"; }' 'show "$f"' '[ -s "$f" ] && echo "$(basename "$f")"' \
  'awk -F, '"'"'NR > 1 || $1 == "x" { print $1 }'"'"' "$f"' 'find "$(dirname "$f")" -name "*.json" -newer "$f"' \
  'git -C "$(dirname "$f")" rev-parse --show-toplevel' '/usr/bin/grep -c chat "$f"' > "$T/dj/reads.sh"
printf '%s\n' '#!/bin/bash' 'node ./titles.js "$1"' > "$T/dj/hand-reader.sh"
for reads in "reads.sh" "hand-reader.sh"; do
  run_bash "cd $T/dj && bash $reads msg.json"
  allowed "a shell script handing its argument only to what cannot act, handed a data file naming the endpoint: $reads"
done
# Code a shell script writes inline and hands its arguments, and what it pipes from the file it is
# handed, are followed (claude-config#2446). Each of these passed: the code given to bash -c, python3
# -c or a heredoc was read only for what it names, and a pipe was not followed at all.
mkdir -p "$T/ip"
cp "$T/ds/msg.json" "$T/ip/msg.json"
printf '%s\n' '#!/bin/bash' "bash -c '. \"\$0\"' \"\$1\"" > "$T/ip/zero.sh"
printf '%s\n' '#!/bin/bash' "python3 -c 'import sys, subprocess; subprocess.run([\"bash\", sys.argv[1]])' \"\$1\"" > "$T/ip/py-c.sh"
printf '%s\n' '#!/bin/bash' "node -e 'require(\"child_process\").execSync(\"bash \" + process.argv[1])' \"\$1\"" > "$T/ip/node-e.sh"
printf '%s\n' '#!/bin/bash' "ruby -e 'load ARGV[0]' \"\$1\"" > "$T/ip/ruby-e.sh"
cat > "$T/ip/py-doc.sh" <<'SH'
#!/bin/bash
python3 - "$1" <<'PY'
import sys, urllib.request
urllib.request.urlopen(open(sys.argv[1]).read().strip())
PY
SH
cat > "$T/ip/os-run.sh" <<'SH'
#!/bin/bash
python3 - "$1" <<'PY'
import os, sys
os.system("bash " + sys.argv[1])
PY
SH
cat > "$T/ip/os-loose.sh" <<'SH'
#!/bin/bash
python3 - "$1" <<'PY'
import os, sys
tool = os
tool.system("bash " + sys.argv[1])
PY
SH
cat > "$T/ip/sh-doc.sh" <<'SH'
#!/bin/bash
bash - "$1" <<'EOF'
. "$1"
EOF
SH
cat > "$T/ip/doc-expands.sh" <<'SH'
#!/bin/bash
bash <<EOF
$(cat "$1")
EOF
SH
cat > "$T/ip/no-code.sh" <<'SH'
#!/bin/bash
python3 - "$1"
SH
printf '%s\n' '#!/bin/bash' 'cat "$1" | bash' > "$T/ip/pipe.sh"
printf '%s\n' '#!/bin/bash' 'grep -v "^#" "$1" | tr a b | sh' > "$T/ip/pipe-far.sh"
printf '%s\n' '#!/bin/bash' 'cat "$1" | while read -r line; do eval "$line"; done' > "$T/ip/pipe-loop.sh"
printf '%s\n' '#!/bin/bash' 'cat "$1" | { read -r first; eval "$first"; }' > "$T/ip/pipe-block.sh"
printf '%s\n' '#!/bin/bash' 'run() { bash; }' 'cat "$1" | run' > "$T/ip/pipe-func.sh"
printf '%s\n' '#!/bin/bash' 'cat "$1" | ./helper.sh' > "$T/ip/pipe-script.sh"
printf '%s\n' '#!/bin/bash' 'bash' > "$T/ip/helper.sh"
chmod +x "$T/ip/helper.sh"
printf '%s\n' '#!/bin/bash' "cat \"\$1\" | python3 -c 'import sys; exec(sys.stdin.read())'" > "$T/ip/pipe-py.sh"
printf '%s\n' '#!/bin/bash' 'bash <<< "$(cat "$1")"' > "$T/ip/here-string.sh"
# Python a script runs from its environment (issue-spool.sh's shape) is read only where the script
# sets that variable once, to a quoted literal: here it comes from the file handed, is bound a second
# time by read, or is a literal that itself runs the file.
cat > "$T/ip/env-handed.sh" <<'SH'
#!/bin/bash
CODE="$(cat "$1")" python3 - "$1" <<'PY'
import os
exec(os.environ["CODE"])
PY
SH
cat > "$T/ip/env-rebound.sh" <<'SH'
#!/bin/bash
SHARED='
import json
'
read -r SHARED < /tmp/shared.py
CODE="$SHARED" python3 - "$1" <<'PY'
import os
exec(os.environ["CODE"])
PY
SH
cat > "$T/ip/env-runs.sh" <<'SH'
#!/bin/bash
SHARED='
import subprocess, sys
subprocess.run(["bash", sys.argv[1]])
'
CODE="$SHARED" python3 - "$1" <<'PY'
import os
exec(os.environ["CODE"])
PY
SH
# A script the reader can only cut crudely gives no place to its commands, so where it pipes what it
# is handed cannot be followed.
printf '%s\n' '#!/bin/bash' 'cat "$1" | wc -l' "echo 'never closed" > "$T/ip/crude.sh"
for acts in "zero.sh:(.)" "py-c.sh:subprocess" "node-e.sh:child_process" "ruby-e.sh:does not read" "py-doc.sh:urllib" \
  "os-run.sh:uses os for more" "os-loose.sh:uses os for more" "sh-doc.sh:(.)" "doc-expands.sh:a heredoc that expands it" \
  "no-code.sh:code from its input" "pipe.sh:through a pipe (bash)" "pipe-far.sh:through a pipe (sh)" \
  "pipe-loop.sh:loop or block" "pipe-block.sh:loop or block" "pipe-func.sh:a function" "pipe-script.sh:helper.sh" \
  "pipe-py.sh:(exec)" "here-string.sh:a here string" "env-handed.sh:(exec)" "env-rebound.sh:(exec)" \
  "env-runs.sh:subprocess" "crude.sh:where it pipes"; do
  run_bash "cd $T/ip && bash ${acts%%:*} msg.json"
  refused "a shell script whose inline or piped code can act on what it is handed: ${acts%%:*}"
  says "that refusal says how ${acts%%:*} acts" "${acts#*:}"
done
# A heredoc the shell expands what the script was handed into is code it was handed, where a shell or
# an interpreter reads it (doc-expands.sh above). In a script the reader can only cut crudely no
# command has a place, so nothing says which heredoc feeds which command, and the heredoc's own
# lines come back as commands of the script: `echo "$1"` reads as an echo, and an assignment as
# nothing. Measured through this wrapper on 2026-11-10 (claude-config#2641): each script below was
# refused as written and allowed with a quote left open after it. A place the reader cannot follow
# is refused, so now both are.
crude_doc() { # crude_doc <name> <lines...>: the script as written, and one only the crude cut reads
  local n="$1"; shift
  printf '%s\n' '#!/bin/bash' "$@" > "$T/ip/$n.sh"
  printf '%s\n' '#!/bin/bash' "$@" "echo 'never closed" > "$T/ip/$n-crude.sh"
}
crude_doc cd-echo 'bash <<EOF' 'echo "$1"' 'EOF'
crude_doc cd-sub 'bash <<EOF' 'echo $(cat "$1")' 'EOF'
crude_doc cd-printf 'sh <<EOF' 'printf "%s" "$1"' 'EOF'
crude_doc cd-colon 'bash <<EOF' ': $1' 'EOF'
crude_doc cd-var 'f="$1"' 'bash <<EOF' 'echo $f' 'EOF'
crude_doc cd-py 'python3 <<EOF' 'echo = 1' 'cat = open("$1").read()' 'EOF'
crude_doc cd-dash 'bash -s <<-EOF' 'echo "$1"' 'EOF'
crude_doc cd-assign 'python3 <<EOF' 'p="$1"' 'exec(open(p).read())' 'EOF'
crude_doc cd-digit 'bash <<1' 'echo "$1"' '1'
for s in cd-echo cd-sub cd-printf cd-colon cd-var cd-py cd-dash cd-assign cd-digit; do
  run_bash "cd $T/ip && bash $s.sh msg.json"
  refused "a heredoc that expands what the script is handed into code, as written: $s.sh"
  says "that refusal says $s.sh runs code it is handed" "a heredoc that expands it"
done
for s in cd-echo cd-sub cd-printf cd-colon cd-var cd-py cd-dash cd-assign cd-digit; do
  run_bash "cd $T/ip && bash $s-crude.sh msg.json"
  refused "the same heredoc in a script the reader can only cut crudely: $s-crude.sh"
  says "that refusal says $s-crude.sh could not be followed" "could not be read as commands to see what a heredoc expands its arguments into"
done
# What a heredoc's text goes on to, through a pipe, cannot be followed either.
crude_doc cd-pipe 'cat <<EOF | ./helper.sh' 'p="$1"' 'EOF'
run_bash "cd $T/ip && bash cd-pipe.sh msg.json"
refused "a heredoc that expands what the script is handed, piped into a script that runs it, as written"
run_bash "cd $T/ip && bash cd-pipe-crude.sh msg.json"
refused "the same heredoc and pipe in a script the reader can only cut crudely"
# The controls, each a script only the crude cut reads, handed the same file: one that opens no
# heredoc, three whose heredoc marker is quoted (whole, by a backslash, or in part: any of them and
# the shell expands nothing into it, as lib/shell-words.py's heredoc_opener measured), one whose
# heredoc is expanded but which never uses its arguments, and a here string, which is a word and no
# heredoc. So the refusal above is the heredoc that may expand the arguments, not every crudely cut
# script.
printf '%s\n' '#!/bin/bash' 'cat <<E"O"F' 'give one file' 'EOF' 'grep -c chat "$1"' "echo 'never closed" > "$T/ip/cc-part.sh"
printf '%s\n' '#!/bin/bash' 'grep -c chat "$1"' "echo 'never closed" > "$T/ip/cc-reads.sh"
printf '%s\n' '#!/bin/bash' "cat <<'EOF'" 'give one file' 'EOF' 'grep -c chat "$1"' "echo 'never closed" > "$T/ip/cc-quoted.sh"
printf '%s\n' '#!/bin/bash' 'cat <<\EOF' 'give one file' 'EOF' 'grep -c chat "$1"' "echo 'never closed" > "$T/ip/cc-escaped.sh"
printf '%s\n' '#!/bin/bash' 'cat <<EOF' 'made in $HOME' 'EOF' 'grep -c chat msg.json' "echo 'never closed" > "$T/ip/cc-no-args.sh"
printf '%s\n' '#!/bin/bash' 'grep -c chat <<< "$1"' "echo 'never closed" > "$T/ip/cc-here-string.sh"
for s in cc-reads cc-quoted cc-escaped cc-part cc-no-args cc-here-string; do
  run_bash "cd $T/ip && bash $s.sh msg.json"
  allowed "a crudely cut script with no heredoc that can expand its arguments is still read as before: $s.sh"
done
# The controls: inline code that only reads or writes files, Python run from the environment that
# the script wrote as a literal, and a pipe into programs that cannot act, are data read as data. A
# shell script's writes are not counted (SH_INERT), so neither are those of the code it writes inline.
printf '%s\n' '#!/bin/bash' "python3 -c 'import json, sys; print(len(json.load(open(sys.argv[1]))))' \"\$1\"" \
  "node -e 'console.log(require(\"fs\").readFileSync(process.argv[1], \"utf8\").length)' \"\$1\"" \
  "node -e 'require(\"fs\").writeFileSync(process.argv[1] + \".bak\", \"1\")' \"\$1\"" \
  "bash -c 'echo \"\$0\"' \"\$1\"" > "$T/ip/reads-inline.sh"
cat > "$T/ip/writes-doc.sh" <<'SH'
#!/bin/bash
python3 - "$1" "$1.kept" <<'PY'
import os, stat, sys, tempfile
src, dst = sys.argv[1], sys.argv[2]
if stat.S_ISREG(os.lstat(src).st_mode):
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(dst))
    with os.fdopen(fd, "w", encoding="utf-8") as out:
        out.write(open(src, encoding="utf-8").read())
    os.replace(tmp, dst)
    os.makedirs(os.path.join(os.path.dirname(dst), "kept"), exist_ok=True)
PY
SH
cat > "$T/ip/env-literal.sh" <<'SH'
#!/bin/bash
SHARED='
import datetime as _dt, os as _os
LIMIT = int(_os.environ.get("LIMIT") or 10)
def old(path):
    return _os.stat(path).st_mtime < LIMIT
'
CODE="$SHARED" python3 - "$1" <<'PY'
import os, sys
exec(os.environ["CODE"])
print(old(sys.argv[1]))
PY
SH
printf '%s\n' '#!/bin/bash' 'cat "$1" | grep -c chat' 'cat "$1" | tr a b | wc -l' 'jq -r .text "$1" | head -1 | cut -c1-20' \
  > "$T/ip/pipe-reads.sh"
for reads in reads-inline.sh writes-doc.sh env-literal.sh pipe-reads.sh; do
  run_bash "cd $T/ip && bash $reads msg.json"
  allowed "a shell script whose inline or piped code cannot act on what it is handed: $reads"
done
printf '%s\n' 'curl -s -X POST https://hooks.slack.com/services/T0/B0/x -d text=hi' > "$T/ds/hook.conf"
printf '%s\n' '#!/bin/bash' 'cfg="$1"' 'source "$cfg"' > "$T/ds/load.sh"
printf '%s\n' '#!/bin/bash' 'exec bash "$@"' > "$T/ds/run-it.sh"
run_bash "source $T/ds/hook.conf"
refused "a sourced file that posts"
run_bash "bash $T/ds/load.sh $T/ds/hook.conf"
refused "a shell script that sources the file it is handed, which posts"
run_bash "bash $T/ds/run-it.sh $T/ds/hook.conf"
refused "a shell script that runs the file it is handed, which posts"
# A file sourced through a variable path is read once the path is worked out (claude-config#2465):
# `. "$ROOT/lib/x.sh"` was never read, so a sourced helper that posts passed the gate.
mkdir -p "$T/sv/posts/lib" "$T/sv/quiet/lib"
cp "$T/ds/hook.conf" "$T/sv/posts/lib/x.sh"
printf '%s\n' 'echo "hi"' > "$T/sv/quiet/lib/x.sh"
for tree in posts quiet; do
  printf '%s\n' '#!/bin/bash' 'ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"' '. "$ROOT/lib/x.sh"' > "$T/sv/$tree/run.sh"
  printf '%s\n' '#!/bin/bash' 'ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"' 'source "${ROOT}/lib/x.sh"' > "$T/sv/$tree/braces.sh"
done
for shape in run braces; do
  run_bash "bash $T/sv/posts/$shape.sh"
  refused "a script sourcing, through a variable path, a file that posts: $shape.sh"
  says "that refusal names the sourced file" "lib/x.sh"
  run_bash "bash $T/sv/quiet/$shape.sh"
  allowed "the same script sourcing a file that does not post: $shape.sh"
done
run_bash "ROOT=$T/sv/posts; . \"\$ROOT/lib/x.sh\""
refused "a command sourcing, through a variable it set, a file that posts"
run_bash "ROOT=$T/sv/quiet; . \"\$ROOT/lib/x.sh\""
allowed "a command sourcing, through a variable it set, a file that does not post"
# The session's HOME is the one the command runs with, so a file sourced from it is read, not refused.
mkdir -p "$T/svhome"
cp "$T/sv/quiet/lib/x.sh" "$T/svhome/env.sh"
HOME="$T/svhome" run_bash ". \"\$HOME/env.sh\""
allowed "a command sourcing a file under HOME that does not post"
cp "$T/sv/posts/lib/x.sh" "$T/svhome/env.sh"
HOME="$T/svhome" run_bash ". \"\$HOME/env.sh\""
refused "a command sourcing a file under HOME that posts"
# The resolver reads the forms this repository's scripts use to build a sourced path (claude-config#2465):
# a `local` set in a function, ${X%/*}, ${X:-default}, and a name set twice where the last set always runs.
SV_ROOT='ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"'
for tree in posts quiet; do
  # The HOOK_DIR idiom: a case on BASH_SOURCE, then cd ... && pwd, sets DIR twice.
  printf '%s\n' '#!/bin/bash' 'case "${BASH_SOURCE[0]}" in */*) DIR="${BASH_SOURCE[0]%/*}" ;; *) DIR=. ;; esac' \
    'DIR="$(cd "${DIR:-/}" && pwd)"' '. "$DIR/lib/x.sh"' > "$T/sv/$tree/hookdir.sh"
  # lib/suite-deadline.sh's idiom: a test that only sometimes resets the name, then a last set that always runs.
  printf '%s\n' '#!/bin/bash' 'D="${BASH_SOURCE[0]%/*}"; [ "$D" != "${BASH_SOURCE[0]}" ] || D=.' \
    'D="$(cd "$D" && pwd)"' '. "$D/lib/x.sh"' > "$T/sv/$tree/twice.sh"
  # A local set inside a function, before the use, from a global set at the top.
  printf '%s\n' '#!/bin/bash' "$SV_ROOT" 'load() {' '  local a="" p="$ROOT/lib/x.sh"' \
    '  if [ -f "$p" ] && . "$p" 2>/dev/null; then echo ok; fi' '}' 'load' > "$T/sv/$tree/local.sh"
  # A global read inside a function body, and ${X:-default} on a name the script set empty.
  printf '%s\n' '#!/bin/bash' "$SV_ROOT" 'SUB=""' 'go() {' '  . "$ROOT/${SUB:-lib}/x.sh"' '}' 'go' > "$T/sv/$tree/default.sh"
done
for shape in hookdir twice local default; do
  run_bash "bash $T/sv/posts/$shape.sh"
  refused "a script sourcing, through a path the resolver works out, a file that posts: $shape.sh"
  says "that refusal names the sourced file" "lib/x.sh"
  run_bash "bash $T/sv/quiet/$shape.sh"
  allowed "the same script sourcing a file that does not post: $shape.sh"
done
# BASH_SOURCE with no slash in it (the script run from its own folder) takes the other case branch.
run_bash "cd $T/sv/posts && bash hookdir.sh"
refused "the HOOK_DIR idiom run from the script's own folder, sourcing a file that posts"
run_bash "cd $T/sv/quiet && bash hookdir.sh"
allowed "the HOOK_DIR idiom run from the script's own folder, sourcing a file that does not post"
run_bash "cd $T/sv/quiet && bash twice.sh"
allowed "the set twice idiom run from the script's own folder, sourcing a file that does not post"
# A path the gate cannot work out is not read, and NOT refused: that refusal is the half of #2465 kept off
# until the 80 scripts it would newly refuse are explained (Dan, 2026-11-09). Every shape is in the tree
# whose lib/x.sh posts, so a pass is the path left unread, exactly as on main; turning the refusal on
# turns each of these red.
printf '%s\n' '#!/bin/bash' '. "$NOT_SET_2465/lib/x.sh"' > "$T/sv/quiet/unknown.sh"
printf '%s\n' '#!/bin/bash' 'source "$(some_tool --where)/x.sh"' > "$T/sv/quiet/subst.sh"
printf '%s\n' '#!/bin/bash' "$SV_ROOT" '. "${LIB_2465:-$ROOT/lib}/x.sh"' > "$T/sv/quiet/envdefault.sh"
printf '%s\n' '#!/bin/bash' "if [ -d /tmp ]; then $SV_ROOT; fi" '. "$ROOT/lib/x.sh"' > "$T/sv/quiet/onlyif.sh"
printf '%s\n' '#!/bin/bash' "setup() { $SV_ROOT; }" '. "$ROOT/lib/x.sh"' > "$T/sv/quiet/nevercalled.sh"
printf '%s\n' '#!/bin/bash' 'cd /nonexistent-2465' 'ROOT="$(pwd)"' '. "$ROOT/lib/x.sh"' > "$T/sv/quiet/cdfails.sh"
printf '%s\n' '#!/bin/bash' 'ROOT="$(cd /nonexistent-2465 && pwd)"' '. "$ROOT/lib/x.sh"' > "$T/sv/quiet/cdsubst.sh"
printf '%s\n' '#!/bin/bash' "$SV_ROOT" 'load() {' '  local p="$ROOT/lib/x.sh"' '  helper' '  . "$p"' '}' > "$T/sv/quiet/aftercall.sh"
printf '%s\n' '#!/bin/bash' "$SV_ROOT" 'load() {' '  if [ -d /tmp ]; then local p="$ROOT/lib/x.sh"; fi' '  . "$p"' '}' \
  > "$T/sv/quiet/localif.sh"
printf '%s\n' '#!/bin/bash' "$SV_ROOT" 'moved() { ROOT=/elsewhere; }' 'go() {' '  . "$ROOT/lib/x.sh"' '}' 'moved' 'go' \
  > "$T/sv/quiet/rebound.sh"
printf '%s\n' '#!/bin/bash' 'go() { local p="lib/x.sh"; . "$p"; }' 'go' > "$T/sv/quiet/relative.sh"
for shape in unknown subst envdefault onlyif nevercalled cdfails cdsubst aftercall localif rebound relative; do
  cp "$T/sv/quiet/$shape.sh" "$T/sv/posts/$shape.sh"
  run_bash "cd $T/sv/posts && bash $T/sv/posts/$shape.sh"
  allowed "the refusal is off: a script sourcing a file whose path the gate cannot work out is let through unread: $shape.sh"
done
run_bash ". \"\$NOT_SET_2465/lib/x.sh\""
allowed "the refusal is off: a command sourcing through a variable it did not set is let through unread"
# The variables a script set are still followed past a helper it sources (claude-config#2465), so long
# as the helper binds no name through a variable. whole-number.sh and disk-clean-units.sh returned
# their result with printf -v "$2", which binds a name only running can tell, so every variable was
# lost after them and the next sourced path refused; they print now, and the caller captures.
mkdir -p "$T/sv/posts/help" "$T/sv/quiet/help"
for tree in posts quiet; do
  printf '%s\n' 'num() { case "${1-}" in ""|*[!0-9]*) return 1 ;; esac; printf "%s" "$1"; }' \
    'arr() { local -a q=("" "@x"); local pr=( -name .none ); printf "%s" "${#q[@]}${pr[0]}"; }' \
    'home() { local h; h="$(eval "printf %s ~root")"; printf "%s" "$h"; }' > "$T/sv/$tree/help/prints.sh"
  printf '%s\n' 'num() { printf -v "$2" "%s" "$1"; }' > "$T/sv/$tree/help/outparam.sh"
  printf '%s\n' 'grab() { eval "$1=1"; }' > "$T/sv/$tree/help/evals.sh"
  for kind in prints outparam evals; do
    printf '%s\n' '#!/bin/bash' "$SV_ROOT" ". \"\$ROOT/help/$kind.sh\"" 'n="$(num 007)" || n=5' '. "$ROOT/lib/x.sh"' \
      > "$T/sv/$tree/past-$kind.sh"
  done
done
run_bash "bash $T/sv/quiet/past-prints.sh"
allowed "a script's variables are followed past a sourced helper that prints its result, arrays and a \$(eval) in it"
run_bash "bash $T/sv/posts/past-prints.sh"
refused "and the file sourced after it is read: one that posts is refused"
says "that refusal names the file sourced after the helper" "lib/x.sh"
# The controls: a helper binding a name through a variable loses the script's variables after it, so
# the file sourced next, which posts, is left unread (and, with the refusal off, let through).
for kind in outparam evals; do
  run_bash "bash $T/sv/posts/past-$kind.sh"
  allowed "a script sourcing a helper that binds a name through a variable ($kind) loses its variables after it"
done
# The real helpers: a script sourcing each, then a file through a variable path, is followed.
# hang-wait.sh is not here: its waits evaluate a condition in the caller's shell on purpose, since
# callers read what the condition sets, so the gate still loses a script's variables past it (#2538).
for helper in whole-number.sh disk-clean-units.sh suite-isolation.sh push-scope.sh full-run-slot.sh \
              disk-clean-predicates.sh; do
  printf '%s\n' '#!/bin/bash' "$SV_ROOT" ". \"$DIR/lib/$helper\"" '. "$ROOT/lib/x.sh"' > "$T/sv/quiet/real-$helper"
  run_bash "bash $T/sv/quiet/real-$helper"
  allowed "a script's variables are followed past the real lib/$helper"
done
printf '%s\n' 'import runpy, sys' 'runpy.run_path(sys.argv[1])' > "$T/ds/runner.py"
printf '%s\n' 'import urllib.request' 'urllib.request.urlopen("https://slack.com/api/chat.postMessage")' > "$T/ds/job.txt"
run_bash "python3 $T/ds/runner.py $T/ds/job.txt"
refused "a Python script that runs the file it is handed, which posts"
run_bash "python3 $T/ds/count.py $T/alert.py"
refused "a script file handed to another script is still read, since a wrapper may run it"
# A script run by its own path has the files it is handed read as one run through its interpreter
# does, the interpreter taken from its #! line (claude-config#2400): `./post.mjs msg.json` was let
# through while `node post.mjs msg.json` was refused.
{ printf '%s\n' '#!/usr/bin/env node'; cat "$T/ds/post.mjs"; } > "$T/ds/post-direct.mjs"
{ printf '%s\n' '#!/usr/bin/env node'; cat "$T/ds/post.mjs"; } > "$T/ds/post-node"
{ printf '%s\n' '#!/usr/bin/env python3'; cat "$T/ds/post.py"; } > "$T/ds/post-python"
{ printf '%s\n' '#!/usr/bin/env node'; cat "$T/ds/titles.js"; } > "$T/ds/titles-direct"
{ printf '%s\n' '#!/usr/bin/env python3'; cat "$T/ds/count.py"; } > "$T/ds/count-direct"
chmod +x "$T/ds/post-direct.mjs" "$T/ds/post-node" "$T/ds/post-python" "$T/ds/titles-direct" "$T/ds/count-direct"
for runs in "$T/ds/post-direct.mjs $T/ds/msg.json" "cd $T/ds && ./post-direct.mjs msg.json" \
  "$T/ds/post-node $T/ds/msg.json" "cd $T/ds && ./post-python msg.json"; do
  run_bash "$runs"
  refused "a sending script run by its own path, handed a data file naming the endpoint: $runs"
  says "that refusal names the data file, run as: $runs" "msg.json"
done
# The controls: the same scripts through their interpreter are refused as before, and a script run by
# its own path that only reads what it is handed still passes.
run_bash "node $T/ds/post-node $T/ds/msg.json"
refused "the extensionless node script through node, handed a data file naming the endpoint"
for reads in "$T/ds/titles-direct $T/ds/issues.json" "cd $T/ds && ./count-direct session.jsonl"; do
  run_bash "$reads"
  allowed "a script run by its own path reading a data file that names an endpoint: $reads"
done
# A compiled program run by its path has no #! to name an interpreter and is not a script the gate
# reads, so the files it is handed stay unread as before (lessons review at b3c887d): reading them
# would refuse a pager or a JSON tool over any file naming an endpoint.
cp /bin/cat "$T/ds/cat-bin"
run_bash "cd $T/ds && ./cat-bin session.jsonl"
allowed "a compiled program run by its own path over a data file that names an endpoint"

echo "slack drafts only: which word is the code is read from each program's own options (claude-config#2439)"

# The refusal measured 2026-11-07: python3 -I -c "<read only analysis>" <transcript .jsonl>. One table
# of options for every interpreter said -I takes a value (ruby's -I does), so it swallowed -c, the
# code went unseen, and the transcript the code reads was taken for the script and refused.
run_bash "python3 -I -c 'import json, sys; print(sum(1 for _ in open(sys.argv[1])))' $T/ds/session.jsonl"
allowed "python3 -I -c over a transcript that names an endpoint, read only"
run_bash "node -e 'const fs = require(\"fs\"); console.log(fs.readFileSync(process.argv[1], \"utf8\").length)' $T/ds/issues.json"
allowed "node -e over a data file that names an endpoint, read only"
# The same table said -E holds code (perl's does) for every program, and that -c does, so a script run
# after python's -E, bash's -e (errexit), ruby's -E (an encoding) or php's -c (an ini file) went unread,
# and node -r loaded a module before -e unread. Each is a script that posts, so each is refused.
printf '%s\n' "curl -d text=hi https://slack.com/api/chat.postMessage" > "$T/ds/post.sh"
cp "$T/alert.py" "$T/ds/post.rb"
cp "$T/alert.py" "$T/ds/post.php"
printf '%s\n' "memory_limit = 256M" > "$T/ds/php.ini"
printf '%s\n' 'fetch("https://slack.com/api/chat.postMessage", { method: "POST" });' > "$T/ds/post-req.js"
for runs in "python3 -E $T/alert.py" "python3 -IE $T/alert.py" "python3 -I $T/alert.py" "python3 -I -W ignore $T/alert.py" \
  "bash -e $T/ds/post.sh" "bash -xe $T/ds/post.sh" "sh -e $T/ds/post.sh" "ruby -E UTF-8 $T/ds/post.rb" \
  "php -c $T/ds/php.ini $T/ds/post.php" "node -r $T/ds/post-req.js -e 1" "node --require $T/ds/post-req.js -p 1"; do
  run_bash "$runs"
  refused "a script that posts, run behind an option that is not code for that program: $runs"
done
# Code given inline is judged as a script file is for the data files it is handed: when it can act on
# them, they are read. Before, python3 -c never read them at all (only -I's wrong table read them, as
# code), so code handing its argument to bash, or posting it, passed.
for acts in "python3 -c 'import sys, subprocess; subprocess.run([\"bash\", sys.argv[1]])' $T/ds/msg.json" \
  "python3 -I -c 'import json, sys, urllib.request; urllib.request.urlopen(json.load(open(sys.argv[1]))[\"url\"])' $T/ds/msg.json" \
  "node -e 'fetch(require(process.argv[1]).url, { method: \"POST\" })' $T/ds/msg.json" \
  "perl -ne 'print' $T/ds/session.jsonl"; do
  run_bash "$acts"
  refused "inline code that can act on a data file naming the endpoint, or that the gate cannot judge: ${acts%% *}"
done
run_bash "python3 -c 'import sys, subprocess; subprocess.run([\"bash\", sys.argv[1]])' $T/ds/msg.json"
says "that refusal names the data file" "msg.json"
# A file with no extension handed to inline code may be a script, as for a script file, so it is read
# as code; and a data file still read as the program's script is refused as before.
printf '%s\n' "curl -d text=hi https://slack.com/api/chat.postMessage" > "$T/ds/noext"
for runs in "python3 -c 'print(1)' $T/ds/noext" "python3 -I $T/ds/issues.json -c 1"; do
  run_bash "$runs"
  refused "a file whose role cannot be told is still read as code: $runs"
done

echo "slack drafts only: /nudge is the one script let through"

if [ -f "$NUDGE" ]; then check "nudge.py is where the gate expects it, beside the hooks" ok
else check "nudge.py is where the gate expects it, beside the hooks" "missing $NUDGE"; fi
run_bash "python3 $NUDGE 'https://example.slack.com/archives/C0TEST1/p1730000000000100'"
allowed "the nudge script passes"
run_bash "python3 $T/copy/nudge.py 'https://example.slack.com/archives/C0TEST1/p1730000000000100'"
refused "a copy of the nudge script anywhere else is refused"

echo "slack drafts only: a payload it cannot read"

# Fails CLOSED on a call whose raw text names a send route: Claude Code writes the payload, so an
# unreadable one means the platform changed, and letting a send through unjudged is the harm this
# gate exists to stop. One that names no route passes, as every refusing gate does (#1922).
run_raw '{"tool_name": "mcp__claude_ai_Slack__slack_send_message", "tool_input": {"channel_id": "C1"'
refused "a send tool payload cut short"
says "and names the payload as the reason" "payload"
run_raw '{"tool_name": "Bash", "tool_input": {"command": "curl https://slack.com/api/chat.postMessage -d x"'
refused "a posting command cut short"
run_raw '{"tool_name": "Bash", "tool_input": {"command": ["curl", "https://hooks.slack.com/services/x"]}}'
refused "a posting command whose command came as a list of words"
run_raw '{"tool_name": "Bash", "tool_input": {"command": "ls -la"'
allowed "an unrelated call cut short"
# The reader not running at all: python3 off the PATH on a call it judges.
NOPY="$(mktemp -d "${TMPDIR:-/tmp}/slack-gate-nopy.XXXXXXXX")"
ln -s "$(command -v cat)" "$NOPY/cat"
errf="$(mktemp "${TMPDIR:-/tmp}/slack-gate-err.XXXXXXXX")"
OUT="$(payload Bash "$(bash_input "python3 $T/alert.py")" | PATH="$NOPY" "$BASH" "$HOOK" 2>"$errf")"; RC=$?
ERR="$(cat "$errf")"
refused "a reader that cannot start refuses a call that runs a script"
says "and says the gate could not judge it" "could not"
# The quick exit, proved by what it does not start rather than by a timing: a plain push in the
# measured payload shape (its own {", a cwd and a transcript path full of slashes) passes with no
# python3 anywhere. A { matched without its space sent every call to python3 (0.05 s each).
for plain in "git push -u origin HEAD:fix/2302-slack-drafts-only" "git status" "ls -la $T" "rtk git status"; do
  OUT="$(payload Bash "$(bash_input "$plain")" | PATH="$NOPY" "$BASH" "$HOOK" 2>"$errf")"; RC=$?
  ERR="$(cat "$errf")"
  case "$plain" in
    rtk*) refused "a wrapped command still goes to the full rule (here unable to start, so refused): $plain" ;;
    *) allowed "the quick exit passes without starting python3: $plain" ;;
  esac
done
rm -rf "$errf" "$NOPY"

echo "slack drafts only: a call it cannot judge in time is refused with its own reason (claude-config#2432)"

# On 2026-11-07 the TO FILE THESE line, bash lib/issue-spool.sh clear <project> <transcript .jsonl>
# <stamp .manifest>, was refused on every try on the work MacBook with "[command hook 42]: timed out;
# blocking because onFailure is block": Claude Code killed this gate at its 15 second timeout. The
# gate of that day read the session transcript as a shell script, the first 2 MB of it (MAX_FILE),
# about 12,000 commands: 5.6 seconds here at a load average of 90, and past 15 on that Mac. A gate
# killed at its timeout says nothing of why, so a call it ran out of time on read the same as one
# that sends. Now the gate stops itself inside its timeout and says it ran out of time.
#
# Timed by an injected clock, never the real one (L524, L290): under a test run,
# SLACK_GATE_TICK_BUDGET makes the clock count the gate's steps (each command judged, each file
# read) and the budget that many steps, so a case is decided by how much the gate reads, whatever
# the Mac's load. The clear line below took 895 steps on the real issue-spool.sh (2026-11-09); with
# the transcript read as code, as on 2026-11-07, it took 12,819.
TICKS=6000
mkdir -p "$T/big/proj"
python3 - "$T/big/session.jsonl" <<'PY'
# A transcript sized past the most the gate reads of any file (2 MB, MAX_FILE), as the real ones are
# (248 MB for one session on 2026-11-08), of JSON lines that read as shell commands, the first naming
# the endpoint the way a conversation about the gate does. The endpoint is put together here, so
# this suite run by hand is not itself refused for feeding python3 a script that names it.
import json, sys
endpoint = "chat." + "post" + "Message"
with open(sys.argv[1], "w") as f:
    f.write(json.dumps({"type": "user", "message": {"content": "curl -X POST https://slack.com/api/" + endpoint + " -d text=hi"}}) + "\n")
    i = 0
    while f.tell() < 3 * 1024 * 1024:
        f.write(json.dumps({"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "Bash",
                "input": {"command": "cd /tmp/x%d && git status && echo 'a;b|c' && ls -la | head -%d" % (i, i % 50)}}]}}) + "\n")
        i += 1
PY
printf '%s\n' '{"keys":{}}' > "$T/big/claude-issue-findings.session.manifest"
# The same bytes with no extension: a file the gate cannot tell from a script, so it reads it as one.
cp "$T/big/session.jsonl" "$T/big/session"
printf '%s\n' '#!/usr/bin/env bash' 'wc -l "$1"' > "$T/big/count.sh"

run_budget() { # run_budget <tick budget> <command>: run_bash under a test run with the step clock
  local errf; errf="$(mktemp "${TMPDIR:-/tmp}/slack-gate-err.XXXXXXXX")"
  OUT="$(payload Bash "$(bash_input "$2")" | HOOK_TESTS_RUNNING=1 SLACK_GATE_TICK_BUDGET="$1" bash "$HOOK" 2>"$errf")"; RC=$?
  ERR="$(cat "$errf")"; rm -f "$errf"
}
lacks() { case "$ERR" in *"$2"*) check "$1" "stderr said '$2': ${ERR:0:400}" ;; *) check "$1" ok ;; esac; }

CLEAR="bash $DIR/lib/issue-spool.sh clear $T/big/proj $T/big/session.jsonl $T/big/claude-issue-findings.session.manifest"
run_budget "$TICKS" "$CLEAR"
allowed "the TO FILE THESE clear line over a 3 MB transcript naming chat.postMessage is judged within $TICKS steps"

# The control: a file it must read as code, sized the same, runs out of the same budget, and the
# refusal says it ran out of time rather than claiming a send.
run_budget "$TICKS" "bash $T/big/count.sh $T/big/session"
refused "a 3 MB file read as code that runs past the budget is refused, not left to the timeout"
says "that refusal says the gate ran out of time" "ran out of time"
says "and names the file whose commands it was judging" "judging the commands in $T/big/session ("
lacks "and does not claim the command posts" "posts to Slack:"
# Run out before a file is read, and the refusal names that file rather than the last one read.
run_budget 1 "$CLEAR"
refused "a budget that passes before the script is read refuses"
says "and names the file it was about to read" "about to read $DIR/lib/issue-spool.sh ("

# The step clock is a test seam only: outside a test run the setting is ignored, so a one step
# budget there still lets a small clear through.
errf="$(mktemp "${TMPDIR:-/tmp}/slack-gate-err.XXXXXXXX")"
OUT="$(payload Bash "$(bash_input "bash $DIR/lib/issue-spool.sh clear $T/ds/proj $T/ds/session.jsonl $T/ds/claude-issue-findings.session.manifest")" \
  | env -u HOOK_TESTS_RUNNING SLACK_GATE_TICK_BUDGET=1 bash "$HOOK" 2>"$errf")"; RC=$?
ERR="$(cat "$errf")"; rm -f "$errf"
allowed "SLACK_GATE_TICK_BUDGET is ignored outside a test run"

# A lint run whose config imports more modules than IMPORT_MAX_FILES (claude-config#2470). In a work
# repository `pnpm run lint` was refused outright because the lint config's local imports pass 300,
# though nothing in it touches Slack, and builders went round the gate to lint at all. Dan,
# 2026-11-09: "Time budget past 300, repository files only". So past 300 the gate reads on, inside
# the budget above, while every module is inside the repository the script is in, each one still
# judged by the endpoint it names. A module outside that repository, a script in no repository and
# the budget running out are each refused as not checked, never allowed.
lint_tree() { # lint_tree <folder> <rule modules> [poster=N|outside=N|link=N|config-outside|no-repo|worktree]
  python3 - "$@" <<'PY'
# <folder> becomes a made up repository: package.json's lint script runs tools/lint.mjs, which imports
# eslint.config.mjs, which imports lint/groups/group-NN.mjs, each importing 16 of
# lint/rules/rule-NNNN.mjs. Read breadth first, rule N is module 2 + groups + N + 1.
#   poster=N        rule N also names a posting endpoint (put together here, so this suite names none)
#   outside=N       rule N also imports <folder>-shared/helper.mjs, outside the repository
#   link=N          rule N is a link to <folder>-shared/linked.mjs, outside the repository
#   config-outside  eslint.config.mjs itself imports <folder>-shared/helper.mjs, among the first 300
#   no-repo         the same tree in a plain folder
#   worktree        .git is the file git writes in a worktree, not a folder
import os, subprocess, sys
root, count, opts = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
num = {o.split("=")[0]: int(o.split("=")[1]) for o in opts if "=" in o}
shared, name = root + "-shared", os.path.basename(root)
for d in ("tools", "lint/groups", "lint/rules"):
    os.makedirs(os.path.join(root, d), exist_ok=True)
os.makedirs(shared, exist_ok=True)
if "worktree" in opts:
    with open(os.path.join(root, ".git"), "w") as f:
        f.write("gitdir: %s/.git/worktrees/%s\n" % (shared, name))
elif "no-repo" not in opts:
    subprocess.run(["git", "init", "-q", root], check=True)
with open(os.path.join(root, "package.json"), "w") as f:
    f.write('{"name": "%s", "private": true, "scripts": {"lint": "node ./tools/lint.mjs ."}}\n' % name)
with open(os.path.join(root, "tools", "lint.mjs"), "w") as f:
    f.write('import config from "../eslint.config.mjs";\nconsole.log(config.length);\n')
groups = (count + 15) // 16
with open(os.path.join(root, "eslint.config.mjs"), "w") as f:
    if "config-outside" in opts:
        f.write('import { helper } from "../%s-shared/helper.mjs";\n' % name)
    for g in range(groups):
        f.write('import group%02d from "./lint/groups/group-%02d.mjs";\n' % (g, g))
    f.write("export default [%s];\n" % ", ".join("group%02d" % g for g in range(groups)))
for g in range(groups):
    rules = range(g * 16, min(count, g * 16 + 16))
    with open(os.path.join(root, "lint", "groups", "group-%02d.mjs" % g), "w") as f:
        for r in rules:
            f.write('import rule%04d from "../rules/rule-%04d.mjs";\n' % (r, r))
        f.write("export default { rules: { %s } };\n" % ", ".join('"made-up/rule-%04d": rule%04d' % (r, r) for r in rules))
endpoint = "chat." + "post" + "Message"
for r in range(count):
    path = os.path.join(root, "lint", "rules", "rule-%04d.mjs" % r)
    if num.get("link") == r:
        os.symlink(os.path.join(shared, "linked.mjs"), path)
        continue
    with open(path, "w") as f:
        if num.get("outside") == r:
            f.write('import { helper } from "../../../%s-shared/helper.mjs";\n' % name)
        f.write('export default { meta: { type: "problem" }, create(context) { return { Identifier(node) {\n')
        f.write('  if (node.name === "forbidden%d") context.report({ node, message: "no forbidden%d" });\n' % (r, r))
        if num.get("poster") == r:
            f.write('  fetch("https://slack.com/api/%s", { method: "POST", body: node.name });\n' % endpoint)
        f.write("} }; } };\n")
for helper in ("helper.mjs", "linked.mjs"):
    with open(os.path.join(shared, helper), "w") as f:
        f.write("export const helper = (name) => name.toLowerCase();\nexport default {};\n")
PY
}
run_lint() { # run_lint <tick budget> <folder>: `pnpm run lint` as a session calls it in that folder
  local errf; errf="$(mktemp "${TMPDIR:-/tmp}/slack-gate-err.XXXXXXXX")"
  OUT="$(payload Bash "$(bash_input "pnpm run lint")" "$2" | HOOK_TESTS_RUNNING=1 SLACK_GATE_TICK_BUDGET="$1" bash "$HOOK" 2>"$errf")"; RC=$?
  ERR="$(cat "$errf")"; rm -f "$errf"
}
mkdir -p "$T/lint"
# 320 rules, so the lint script reaches 342 modules: itself, the config, 20 groups and the rules.
lint_tree "$T/lint/clean" 320
run_lint "$TICKS" "$T/lint/clean"
allowed "a lint script reaching 342 modules, all in its repository and none posting, is allowed"
lint_tree "$T/lint/wt" 320 worktree
run_lint "$TICKS" "$T/lint/wt"
allowed "and so is one in a worktree, whose .git is a file"
# The control: one module past the first 300 that posts is still read, and refused by name.
lint_tree "$T/lint/poster" 320 poster=310
run_lint "$TICKS" "$T/lint/poster"
refused "one posting module among 342, read after the first 300, is refused"
says "that refusal names the posting module" "rule-0310.mjs"
says "and the endpoint it names" "which posts to Slack (it names chat.postMessage)"
says "and says the command posts" "REFUSED: this command posts to Slack"
# A module outside the repository ends the reading: whether it comes after the first 300 ...
lint_tree "$T/lint/out" 320 outside=305
run_lint "$TICKS" "$T/lint/out"
refused "a module outside the repository, reached past 300, is refused"
says "that refusal names the module outside" "/lint/out-shared/helper.mjs) is outside the repository"
says "and the repository it is outside" "/lint/out: the script ./tools/lint.mjs, which imports"
says "and says the check could not be made" "REFUSED: the gate could not check whether this command posts to Slack"
lacks "and does not claim the command posts" "REFUSED: this command posts to Slack"
# ... among them (the walk passes 300 only when every module it has read is inside too) ...
lint_tree "$T/lint/early" 320 config-outside
run_lint "$TICKS" "$T/lint/early"
refused "a module outside the repository among the first 300 is refused once the walk passes 300"
says "that refusal names the module outside" "/lint/early-shared/helper.mjs) is outside the repository"
says "and the repository it is outside" "/lint/early: the script ./tools/lint.mjs, which imports"
# ... or is inside by its path and outside by where its link leads.
lint_tree "$T/lint/link" 320 link=306
run_lint "$TICKS" "$T/lint/link"
refused "a module that is a link to a file outside the repository is refused"
says "that refusal names the file the link leads to" "/lint/link-shared/linked.mjs) is outside the repository"
says "and the repository it is outside" "/lint/link: the script ./tools/lint.mjs, which imports"
# A script in no repository is read no further than it ever was. The throwaway folder has to be in
# none itself for that to be measured, so that is checked first and said (L411).
if (d="$(cd "$T" && pwd -P)"; while [ "$d" != "/" ] && [ ! -e "$d/.git" ]; do d="$(dirname "$d")"; done; [ -e "$d/.git" ]); then
  check "the throwaway folder is in no repository, as the no repository cases need" "it is inside one: $T"
else check "the throwaway folder is in no repository, as the no repository cases need" ok; fi
lint_tree "$T/lint/plain" 320 no-repo
run_lint "$TICKS" "$T/lint/plain"
refused "a lint script reaching 342 modules in no repository is refused"
says "that refusal says the imports go past what it reads" "more than 300 modules"
says "and that the script is in no repository" "is not inside a repository"
lacks "and does not claim the command posts" "REFUSED: this command posts to Slack"
# The budget running out past 300 is refused as not checked, saying how far the reading got.
run_lint 330 "$T/lint/clean"
refused "the budget running out while reading past 300 modules is refused, never allowed"
says "that refusal says the gate ran out of time" "ran out of time"
says "and that the command was not checked" "was not checked"
says "and how far past 300 the reading got" "of the modules the script ./tools/lint.mjs imports (past 300"
lacks "and does not claim the command posts" "posts to Slack:"

# The budget was looked at only between commands and before each file, so work inside one file's
# walk was never timed (claude-config#2571): on 2026-11-09 the walk of one script took 41 s of
# processor time (#2569), the budget passed unseen, Claude Code killed the hook at 15 seconds, and
# the session saw "[command hook 44]: timed out" with no gate named. On the real clock the budget
# now interrupts the walk wherever it is, and a reader that cannot be interrupted (held inside one
# long call into C) is ended a little later by a watchdog, so either way the gate's own refusal is
# what prints. Proved by which of the two stopped the walk and where, never by how long anything
# took (L290): the real reader runs behind the real wrapper with a budget of half a second and a
# hard stop at 2, and the walk of the script's variables is made slow before it starts, by 4
# seconds of Python or by one call into C that nothing can interrupt and that runs several times
# longer than the hard stop (a sum over two thousand million numbers: measured on 2026-11-10, the
# interruption reached a backtracking regular expression at once, and reached this sum only when
# it had finished). Slow work that was let run to its end leaves a mark, and work the gate stopped
# part way leaves none: before this the gate refused such a walk too, but only at the next file
# it came to after the slow work had finished, however long that took. The third slow case is an interruption that something swallowed (an exception raised from
# a timer can land in code that discards it), after which the walk went on to an answer: once the
# budget has interrupted a walk, no answer it gives afterwards is an allow.
mkdir -p "$T/slow/hooks" "$T/slow/lib"
cp "$HOOK" "$T/slow/hooks/slack-drafts-only-gate.sh"
ln -s "$DIR/lib" "$T/slow/hooks/lib"
cat > "$T/slow/hooks/slack_drafts_only_gate.py" <<'PY'
import importlib.util, os, sys, time
spec = importlib.util.spec_from_file_location("gate", os.environ["SLOW_REAL_READER"])
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
gate.BUDGET_SECONDS = 0.5
if hasattr(gate, "HARD_STOP_SECONDS"):
    gate.HARD_STOP_SECONDS = 2.0
how = os.environ["SLOW_HOW"]
def spin(seconds):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        pass
real_walk = gate.Judge.sh_walk
def slow_walk(self, s, *a, **k):
    if "SLOW-2571" in s:
        if how == "python":
            spin(4)
        elif how == "c":
            sum(range(2 * 10**9))
        open(os.environ["SLOW_MARK"], "a").write("finished\n")
    return real_walk(self, s, *a, **k)
gate.Judge.sh_walk = slow_walk
real_line = gate.Judge.line
def slow_line(self, s, cwd, depth, whole):
    out = real_line(self, s, cwd, depth, whole)
    if how == "swallowed" and depth == 0:
        try:
            spin(4)  # the walk has its answer, and the budget passes before it hands it back
        except BaseException:
            pass
    return out
gate.Judge.line = slow_line
gate.main()
PY
printf '%s\n' 'echo "hi"' > "$T/slow/lib/x.sh"
printf '%s\n' '#!/bin/bash' '# SLOW-2571' 'ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"' '. "$ROOT/lib/x.sh"' > "$T/slow/run.sh"
run_slow() { # run_slow <no|python|swallowed|c>: judge `bash run.sh` on the real clock, slowed that way
  local errf; errf="$(mktemp "${TMPDIR:-/tmp}/slack-gate-err.XXXXXXXX")"
  rm -f "$T/slow/mark"
  OUT="$(payload Bash "$(bash_input "bash $T/slow/run.sh")" | env -u SLACK_GATE_TICK_BUDGET SLOW_REAL_READER="$DIR/slack_drafts_only_gate.py" SLOW_HOW="$1" SLOW_MARK="$T/slow/mark" bash "$T/slow/hooks/slack-drafts-only-gate.sh" 2>"$errf")"; RC=$?
  ERR="$(cat "$errf")"; rm -f "$errf"
}
unfinished() { if [ -e "$T/slow/mark" ]; then check "$1" "the slow work ran to its end before the gate answered"; else check "$1" ok; fi; }
# The control: with nothing slow the copy allows the script and the walk of run.sh is reached, so
# the mark means what it says and the short budget alone refuses nothing.
run_slow no
allowed "with nothing slow, a script sourcing a quiet helper passes under the short budget"
if [ -e "$T/slow/mark" ]; then check "and the walk of the script was reached" ok; else check "and the walk of the script was reached" "no mark was left, so the walk of run.sh was never reached"; fi
run_slow python
refused "a walk of one file that runs past the budget is refused"
says "that refusal says the gate ran out of time" "ran out of time"
says "and names the file whose walk it was in" "judging the commands in $T/slow/run.sh ("
unfinished "and the walk was stopped inside the file, not after it"
run_slow swallowed
refused "a walk whose interruption was swallowed, and which went on to an answer, is refused all the same"
says "and that refusal says the gate ran out of time too" "ran out of time"
run_slow c
refused "a reader held inside one long call into C is refused too"
says "and says the gate could not judge the call" "could not judge this call"
says "and that the reader was stopped for taking too long" "Timeout"
unfinished "and it was stopped inside the call, not after it"

# The budget sits inside the timeout the settings give the gate, with room for python3 to start and
# for the one file it may be reading when the budget passes (MAX_FILE read as commands took 2.8
# seconds under a profiler at a load average of 222 on 2026-11-09).
. "$DIR/lib/settings-file.sh"
SETTINGS="$(hook_settings_file "$DIR/..")"
[ -n "$SETTINGS" ] || room="neither settings.hooks.json nor settings.json is in $DIR/.., so there is no timeout to compare"
[ -z "$SETTINGS" ] || room="$(python3 - "$SETTINGS" "$DIR/slack_drafts_only_gate.py" <<'PY'
import json, re, sys
timeout = None
for g in json.load(open(sys.argv[1])).get("hooks", {}).get("PreToolUse", []):
    for h in g.get("hooks", []):
        if h.get("command", "").endswith("hooks/slack-drafts-only-gate.sh"):
            timeout = h.get("timeout")
m = re.search(r"^BUDGET_SECONDS = (\d+)$", open(sys.argv[2]).read(), re.M)
if timeout is None or not m:
    print("no registered timeout or no BUDGET_SECONDS line to compare"); sys.exit()
print("ok" if int(m.group(1)) <= timeout - 4 else "BUDGET_SECONDS %s leaves under 4 of the %s second timeout" % (m.group(1), timeout))
PY
)"
check "the gate's own budget leaves at least 4 seconds of its registered timeout" "$room"
# And the hard stop, which ends a reader the budget could not interrupt, still leaves the wrapper 2
# seconds of that timeout to print its refusal (claude-config#2571): a hard stop at or past the
# timeout is Claude Code's kill again, with no gate named. The 2 is the floor this check sets, not
# measured; on 2026-11-10, with the Mac's load average over 50, a hook whose reader was ended by
# a hard stop set at 1 s had answered 1.19 s after it was started, so everything outside the
# reader's own time (the wrapper, python3 starting, the refusal) took 0.19 s.
[ -n "$SETTINGS" ] || stop_room="$room"
[ -z "$SETTINGS" ] || stop_room="$(python3 - "$SETTINGS" "$DIR/slack_drafts_only_gate.py" <<'PY'
import json, re, sys
timeout = None
for g in json.load(open(sys.argv[1])).get("hooks", {}).get("PreToolUse", []):
    for h in g.get("hooks", []):
        if h.get("command", "").endswith("hooks/slack-drafts-only-gate.sh"):
            timeout = h.get("timeout")
src = open(sys.argv[2]).read()
budget = re.search(r"^BUDGET_SECONDS = (\d+)$", src, re.M)
extra = re.search(r"^HARD_STOP_SECONDS = BUDGET_SECONDS \+ (\d+)$", src, re.M)
if timeout is None or not budget or not extra:
    print("no registered timeout, BUDGET_SECONDS line or HARD_STOP_SECONDS line to compare"); sys.exit()
stop = int(budget.group(1)) + int(extra.group(1))
print("ok" if stop <= timeout - 2 else "HARD_STOP_SECONDS %s leaves under 2 of the %s second timeout" % (stop, timeout))
PY
)"
check "and its hard stop leaves at least 2 seconds of that timeout" "$stop_room"

echo "slack drafts only: a crash inside the walk of a script is no verdict (claude-config#2573)"

# On 2026-11-09, while #2569 was being fixed, sh_binds briefly raised AttributeError, and with that
# fault in place the gate allowed `bash lib/merge-when-ready.sh` in 0.24 s: the handler around a
# script read as commands took the crash for a script that cannot be read, and such a script passes
# when it names no endpoint itself, whatever it goes on to source. So a fault in the gate's own
# walk read as a clean script. Here the real reader runs behind the real wrapper with that one
# fault put back (CRASH_IN names the function, which raises the first time it is asked), over a
# script that sets a variable in an if and then sources a helper: one that posts, and one that
# does not, since a walk that crashed has judged neither.
mkdir -p "$T/crash/hooks" "$T/crash/posts/lib" "$T/crash/quiet/lib"
cp "$HOOK" "$T/crash/hooks/slack-drafts-only-gate.sh"
ln -s "$DIR/lib" "$T/crash/hooks/lib"
cat > "$T/crash/hooks/slack_drafts_only_gate.py" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("gate", os.environ["CRASH_REAL_READER"])
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
name = os.environ.get("CRASH_IN", "")
if name:
    def crashing(*a, **k):
        raise AttributeError("'NoneType' object has no attribute 'search'")
    setattr(gate.Judge, name, staticmethod(crashing))
gate.main()
PY
for tree in posts quiet; do
  cp "$T/sv/$tree/lib/x.sh" "$T/crash/$tree/lib/x.sh"
  printf '%s\n' '#!/bin/bash' 'ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"' 'MODE=one' \
    'if [ -n "$1" ]; then' '  MODE=two' 'fi' '. "$ROOT/lib/x.sh"' > "$T/crash/$tree/run.sh"
  printf '%s\n' '{"scripts": {"go": "MODE=one; if [ -n \"$1\" ]; then MODE=two; fi; . ./lib/x.sh"}}' > "$T/crash/$tree/package.json"
done
run_crash() { # run_crash <function to crash, or ""> <command>: run_bash through the faulted reader
  local errf; errf="$(mktemp "${TMPDIR:-/tmp}/slack-gate-err.XXXXXXXX")"
  OUT="$(payload Bash "$(bash_input "$2")" | CRASH_REAL_READER="$DIR/slack_drafts_only_gate.py" CRASH_IN="$1" bash "$T/crash/hooks/slack-drafts-only-gate.sh" 2>"$errf")"; RC=$?
  ERR="$(cat "$errf")"; rm -f "$errf"
}
# The control: with no fault the copy judges as the gate does, so what follows is the fault's doing.
run_crash "" "bash $T/crash/posts/run.sh"
refused "with no fault, the script sourcing a helper that posts is refused"
says "and that refusal names the helper" "lib/x.sh"
run_crash "" "bash $T/crash/quiet/run.sh"
allowed "with no fault, the script sourcing a helper that does not post passes"
run_crash "" "npm --prefix $T/crash/posts run go"
refused "with no fault, the package script sourcing a helper that posts is refused"
run_crash "" "npm --prefix $T/crash/quiet run go"
allowed "with no fault, the package script sourcing a helper that does not post passes"
# Each way a script's commands are reached: the file a shell is handed, a shell fed them on its
# input, and a package script. sh_binds is asked inside the walk of the script's variables,
# sh_source_word when the source command itself is judged.
for fault in sh_binds sh_source_word; do
  for tree in posts quiet; do
    run_crash "$fault" "bash $T/crash/$tree/run.sh"
    refused "a crash in $fault while walking a script that sources a helper ($tree) is refused"
    says "and says the gate could not judge the call" "could not judge this call"
    lacks "and does not claim the command posts" "posts to Slack:"
    run_crash "$fault" "cd $T/crash/$tree && bash <<'EOF'
$(cat "$T/crash/$tree/run.sh")
EOF"
    refused "the same crash in commands a shell is fed on its input ($tree) is refused"
    says "and says the gate could not judge the call" "could not judge this call"
    run_crash "$fault" "npm --prefix $T/crash/$tree run go"
    refused "the same crash in a package script's commands ($tree) is refused"
    says "and says the gate could not judge the call" "could not judge this call"
  done
done
# A script the reader cannot read as commands at all is not a crash of the walk: it is judged as it
# was, by what it names. The reader is made to fail on the script's own text, and on no other.
cat > "$T/crash/hooks/slack_drafts_only_gate.py" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("gate", os.environ["CRASH_REAL_READER"])
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
real_load = gate.load_reader
def load():
    sw = real_load()
    real = sw.every_command
    def every_command(s, *a, **k):
        if "UNREADABLE-2573" in s and "\n" in s:
            raise sw.Unreadable()
        return real(s, *a, **k)
    sw.every_command = every_command
    return sw
gate.load_reader = load
gate.main()
PY
printf '%s\n' '#!/bin/bash' '# UNREADABLE-2573' 'echo hi' > "$T/crash/quiet/odd.sh"
printf '%s\n' '#!/bin/bash' '# UNREADABLE-2573' "$(cat "$T/sv/posts/lib/x.sh")" > "$T/crash/posts/odd.sh"
run_crash "" "bash $T/crash/quiet/odd.sh"
allowed "a script the reader cannot read as commands, naming no endpoint, still passes"
run_crash "" "bash $T/crash/posts/odd.sh"
refused "a script the reader cannot read as commands, naming an endpoint, is still refused"
says "and that refusal says it could not be read as commands" "could not be read as commands"
# A shell script handed a data file is read once more, for what it does with its arguments
# (shell_acts), and that reading kept the broad handler (claude-config#2593): a fault in the gate's
# own walk there was reported as a script that could not be read as commands, which claims a post
# and names the wrong cause. The reader is made to fail only where shell_acts asks it (ACTS_RAISES
# names what it raises), over a script that never touches the file it is handed, which names an
# endpoint.
cat > "$T/crash/hooks/slack_drafts_only_gate.py" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("gate", os.environ["CRASH_REAL_READER"])
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
real_load = gate.load_reader
def load():
    sw = real_load()
    real = sw.every_command
    def every_command(s, *a, **k):
        kind = os.environ.get("ACTS_RAISES", "")
        if kind and sys._getframe(1).f_code.co_name == "shell_acts":
            raise {"fault": AttributeError("a fault"), "unreadable": sw.Unreadable(),
                   "late": gate.OutOfTime("judging what a script does with its arguments")}[kind]
        return real(s, *a, **k)
    sw.every_command = every_command
    return sw
gate.load_reader = load
gate.main()
PY
printf '%s\n' '#!/bin/bash' 'echo hi' > "$T/crash/quiet/ignores.sh"
run_crash "" "bash $T/crash/quiet/ignores.sh $T/ds/msg.json"
allowed "with no fault, a script that ignores the data file it is handed passes"
ACTS_RAISES=fault run_crash "" "bash $T/crash/quiet/ignores.sh $T/ds/msg.json"
refused "a crash while reading what a shell script does with its arguments is refused"
says "and says the gate could not judge the call" "could not judge this call"
lacks "and does not claim the command posts" "posts to Slack:"
lacks "and does not say the script could not be read" "could not be read as commands"
ACTS_RAISES=unreadable run_crash "" "bash $T/crash/quiet/ignores.sh $T/ds/msg.json"
refused "a script the reader cannot read for what it does with its arguments is still refused"
says "and that refusal says it could not be read as commands" "could not be read as commands to see what it does"
ACTS_RAISES=late run_crash "" "bash $T/crash/quiet/ignores.sh $T/ds/msg.json"
refused "the budget running out while reading what a script does with its arguments is refused"
says "and says the gate ran out of time" "ran out of time judging this call"
lacks "and does not say the script could not be read" "could not be read as commands"
# The same rule where the gate asks the reader for a text's commands (the line being judged, the
# walk of its variables, the names a sourced file binds): the reader saying it cannot read the text
# gives what it gave (nothing known, every name bound, no command's place), and any other error
# from it is a fault that is not swallowed into one of those answers.
cat > "$T/crash/parse.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("gate", sys.argv[1])
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
d = sys.argv[2]
text = open(d + "/run.sh").read()
def ask(make):
    # The error is made from this judge's own copy of the reader: each load is a module of its own,
    # so another copy's Unreadable is not the class this one catches.
    judge = gate.Judge(gate.load_reader())
    error = make(judge.sw)
    def commands(*a, **k):
        raise error
    judge.sw.commands = commands
    got = {}
    for label, call in (("the walk of its variables", lambda: judge.sh_walk(text, d, "run.sh", True, 0)),
                        ("the names a sourced file binds", lambda: judge.sh_bound_in(d + "/run.sh", {"MODE"}, d, True, "run.sh", 1, set())),
                        ("the line being judged", lambda: judge.line("echo hi", d, 0, "echo hi"))):
        try:
            got[label] = ("gave", call())
        except Exception as e:
            got[label] = ("raised", type(e).__name__)
    return got
wrong = []
for label, (how, what) in ask(lambda sw: AttributeError("a fault")).items():
    if (how, what) != ("raised", "AttributeError"):
        wrong.append("a fault in the reader, asked for %s, was taken as an answer: %r" % (label, what))
unreadable = ask(lambda sw: sw.Unreadable())
expect = {"the walk of its variables": ("gave", {"regions": {}, "top": 0, "lost": [], "bodies": []}),
          "the names a sourced file binds": ("gave", {"MODE"}), "the line being judged": ("gave", None)}
for label in expect:
    if unreadable[label] != expect[label]:
        wrong.append("a text the reader cannot read, asked for %s, %s %r" % ((label,) + unreadable[label]))
print("; ".join(wrong) or "ok")
PY
parse="$(python3 "$T/crash/parse.py" "$DIR/slack_drafts_only_gate.py" "$T/crash/quiet" 2>&1)"
check "a fault in the reader is not taken for a text it cannot read, in each place the gate asks it (#2573)" "$parse"

echo "slack drafts only: it is wired"

. "$DIR/lib/settings-file.sh"
SETTINGS="$(hook_settings_file "$DIR/..")"
if [ -z "$SETTINGS" ]; then
  check "a settings file registers the gate" "neither settings.hooks.json nor settings.json is in $DIR/.."
else
  wiring="$(python3 - "$SETTINGS" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1]))
matchers = []
for g in d.get("hooks", {}).get("PreToolUse", []):
    for h in g.get("hooks", []):
        if h.get("command", "").endswith("hooks/slack-drafts-only-gate.sh"):
            if h.get("onFailure") != "block":
                print("the gate is not registered with onFailure block"); sys.exit()
            matchers.append(g.get("matcher", ""))
if not matchers:
    print("no PreToolUse group runs slack-drafts-only-gate.sh"); sys.exit()
must = ["Bash", "mcp__plugin_slack_slack__slack_send_message", "mcp__plugin_slack_slack__slack_schedule_message",
        "mcp__claude_ai_Slack__slack_send_message", "mcp__claude_ai_Slack__slack_schedule_message",
        "mcp__some_future_connector__slack_send_message"]
mustnot = ["Read", "Write", "mcp__playwright__browser_navigate"]
for name in must:
    if not any(re.fullmatch(m, name) for m in matchers):
        print("no matcher routes " + name); sys.exit()
for name in mustnot:
    if any(m == "" or re.fullmatch(m, name) for m in matchers):
        print("a matcher also routes " + name); sys.exit()
print("ok")
PY
)"
  check "the gate is registered under PreToolUse for Bash and every Slack tool, to block" "$wiring"
fi

# ---- #2569: the patterns sh_binds builds are compiled once per name ----
# The merge helper's own script has a few thousand names, and sh_binds built three patterns per name
# on every call. re keeps only 512 compiled patterns, so a profile of the gate judging
# `bash lib/merge-when-ready.sh` showed 1,002,444 compilations and 41 s of processor time, past the
# 15 s the gate is given, and no session could start the helper (2026-11-09). Held by the count of
# compilations, never by the clock (L290).
cat > "$T/binds.py" <<'PY'
import importlib.util, re, sys
spec = importlib.util.spec_from_file_location("gate", sys.argv[1])
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
binds = gate.Judge.sh_binds
# What it answers is unchanged: (name, text, NAME= forms allowed, bound or not).
cases = [("x", "x=1", 0, True), ("x", "echo $x", 0, False), ("x", "read x", 0, True),
         ("x", "export x", 0, False), ("x", "export x=2", 0, True), ("x", "(( x++ ))", 0, True),
         ("x", "x=1 cmd", 1, False), ("x", "xy=1", 0, False), ("x", "local y x", 0, True),
         ("x", ': "${x:=d}"', 0, True), ("x", "y=1", 0, False), ("x", "x[2]=a", 0, True),
         ("x", "x+=a", 0, True), ("a.b", "aXb=1", 0, False)]
wrong = [c for c in cases if binds(c[0], c[1], c[2]) != c[3]]
if wrong:
    print("wrong answers: %r" % wrong); sys.exit()
comp = getattr(re, "_compiler", None) or __import__("sre_compile")
real, count = comp.compile, [0]
def counting(*a, **k):
    count[0] += 1
    return real(*a, **k)
names = ["name_%d" % i for i in range(700)]   # more than the 512 patterns re keeps
text = "\n".join("%s=1" % n for n in names)
if not all(binds(n, text) for n in names):
    print("a name set in the text was not read as bound"); sys.exit()
comp.compile = counting
try:
    again = all(binds(n, text) for n in names)
finally:
    comp.compile = real
print("ok" if again and count[0] == 0 else "a second pass over 700 names compiled %d patterns" % count[0])
PY
binds="$(python3 "$T/binds.py" "$DIR/slack_drafts_only_gate.py" 2>&1)"
check "sh_binds compiles each name's patterns once, however many names a script has (#2569)" "$binds"

echo "slack drafts only: the merge helper's own line is judged inside the gate's time (claude-config#2576)"

# On 2026-11-09 no merge through lib/merge-when-ready.sh could start on the work MacBook: the gate
# follows the helper into everything it sources, and that walk had grown past the gate's time. The
# cause of that day was #2569, but nothing held the walk of the real helper to a size, so the next
# file added to what it sources would be found at a merge. Held by the step clock, never the real
# one (L290). Measured on 2026-11-09: 7,899 steps, 11 files read 32 times, 3.9 seconds of processor
# time before the changes below and 2.4 after; before them, at a load average of 110, that was 7.5
# to 10.5 seconds on the wall against the 11 the gate has. So the ceiling sits at about one and a
# half times today's walk: a helper that grows past it fails here, to be made cheaper to judge or
# the ceiling raised on a new measurement.
MWR="bash $DIR/lib/merge-when-ready.sh 123 --repo danwright32/claude-config --delete-branch"
MWR_STEPS=12000
run_budget "$MWR_STEPS" "$MWR"
allowed "the real merge helper, with everything it sources, is judged within $MWR_STEPS steps"
# The control: the budget is live for this line, and a walk that passes it is refused with the
# gate's own reason.
run_budget 2000 "$MWR"
refused "the merge helper's line under a budget its walk passes is refused"
says "that refusal says the gate ran out of time" "ran out of time"

# A function of the script that calls others was followed once per path to it, so a chain of
# functions each calling the next twice cost two to the power of its length: 16,383 walks for 14
# functions. Each function's own effect is now worked out once and a call takes in everything it
# reaches. Held by a count of what is read, never the clock, and by the answers being the same.
cat > "$T/calls.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("gate", sys.argv[1])
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
chain = "".join("f%d() {\n  f%d\n  f%d\n}\n" % (i, i + 1, i + 1) for i in range(1, 14))
text = ("KEEP=/keep\nLOSE=/lose\nCYC=/cyc\n" + chain + "f14() {\n  LOSE=changed\n}\n"
        "a() {\n  b\n}\nb() {\n  a\n  CYC=changed\n}\nf1\na\n: after\n")
count = [0]
real = gate.Judge.sh_indirect
def counting(self, t):
    count[0] += 1
    return real(self, t)
gate.Judge.sh_indirect = counting
judge = gate.Judge(gate.load_reader())
known = judge.sh_known(text, "/", None)
at = text.index(": after")
got = [judge.sh_at(known, n, at) for n in ("KEEP", "LOSE", "CYC")]
if got != ["/keep", None, None]:
    print("after the calls KEEP, LOSE and CYC read %r, not ['/keep', None, None]" % got); sys.exit()
# A function reached through another that binds a name through a variable ends the walk at the call.
stop = "KEEP=/keep\ng() {\n  h\n}\nh() {\n  eval \"$1\"\n}\n%s\n: after\n"
ends = [judge.sh_cwd_at(judge.sh_known(stop % call, "/", None), (stop % call).index(": after")) for call in ("g", ": g")]
if ends != [False, True]:
    print("the walk past a call reaching eval, and past none, read %r, not [False, True]" % ends); sys.exit()
print("ok" if count[0] < 1000 else "following 14 chained functions read %d commands for a name bound through a variable" % count[0])
PY
calls="$(python3 "$T/calls.py" "$DIR/slack_drafts_only_gate.py" 2>&1)"
check "a function is followed once, however many paths of calls reach it (#2576)" "$calls"

# One script's text was read into commands again by each part of the gate that wanted them (the
# line being judged, the walk of its variables, the names a sourced file binds), 40 times for the
# 11 files of the merge helper (counted on 2026-11-09), and a sourced file was asked which names it binds once per script
# that sources it. Both answers depend on the text alone, so each is worked out once in a run.
mkdir -p "$T/once"
printf '%s\n' 'ROOT=/somewhere' '. ./lib.sh' 'echo "$ROOT"' > "$T/once/a.sh"
printf '%s\n' 'HELPER=1' 'helper() {' '  echo "$HELPER"' '}' > "$T/once/lib.sh"
cat > "$T/once.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("gate", sys.argv[1])
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
d = sys.argv[2]
judge = gate.Judge(gate.load_reader())
parses, real = {}, judge.sw.commands
def counting(s, *a, **k):
    # Only what the gate's own code asks for: the reader's own calls to itself are not the gate's.
    if sys._getframe(1).f_code.co_filename == gate.__file__:
        parses[s] = parses.get(s, 0) + 1
    return real(s, *a, **k)
judge.sw.commands = counting
asked, binds = [], gate.Judge.sh_binds
gate.Judge.sh_binds = staticmethod(lambda name, text, allowed=0: asked.append((name, text)) or binds(name, text, allowed))
if judge.line("bash a.sh", d, 0, "bash a.sh") is not None:
    print("a script that sources a helper posting nothing was refused"); sys.exit()
lib = open(d + "/lib.sh").read()
names = {"ROOT", "HELPER"}
first = judge.sh_bound_in(d + "/lib.sh", names, d, True, "./lib.sh", 1, set())
whole = [a for a in asked if a[1] == lib]
again = judge.sh_bound_in(d + "/lib.sh", names, d, True, "./lib.sh", 1, set())
if first != {"HELPER"} or again != first:
    print("lib.sh was read as binding %r, then %r, not {'HELPER'}" % (first, again)); sys.exit()
more = len([a for a in asked if a[1] == lib]) - len(whole)
twice = sorted(n for n in parses.values() if n > 1)
wrong = []
if twice:
    wrong.append("the gate read one text into commands %s times" % twice[-1])
if len(parses) < 2:
    wrong.append("the gate read %d texts into commands, and a.sh and lib.sh are two" % len(parses))
if more:
    wrong.append("asking lib.sh about the same names again scanned it %d more times" % more)
print("; ".join(wrong) or "ok")
PY
once="$(python3 "$T/once.py" "$DIR/slack_drafts_only_gate.py" "$T/once" 2>&1)"
check "a text is read into commands once, and a sourced file asked about a name once (#2576)" "$once"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
