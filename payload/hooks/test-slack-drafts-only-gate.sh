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
# Past the most modules it reads (IMPORT_MAX_FILES, 300; the largest real script reaches 11), what
# lies beyond is unseen, so it is refused; a short chain of the same shape passes.
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

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
