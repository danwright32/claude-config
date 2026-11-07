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
run_bash "python3 $T/pp/app/run.py"
refused "the PYTHONPATH script run without it, its import placed nowhere"
run_bash "cd $T/pp && python3 -c 'import no_such_helper_2358'"
refused "inline Python importing a module placed nowhere"

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
printf '%s\n' 'import json, sys, urllib.request' 'm = json.load(open(sys.argv[1]))' \
  'urllib.request.urlopen(urllib.request.Request(m["url"], data=m["text"].encode()))' > "$T/ds/post.py"
run_bash "python3 $T/ds/post.py $T/ds/msg.json"
refused "a Python script that sends a request, handed a data file naming the endpoint"
printf '%s\n' 'curl -s -X POST https://hooks.slack.com/services/T0/B0/x -d text=hi' > "$T/ds/hook.conf"
printf '%s\n' '#!/bin/bash' 'cfg="$1"' 'source "$cfg"' > "$T/ds/load.sh"
printf '%s\n' '#!/bin/bash' 'exec bash "$@"' > "$T/ds/run-it.sh"
run_bash "source $T/ds/hook.conf"
refused "a sourced file that posts"
run_bash "bash $T/ds/load.sh $T/ds/hook.conf"
refused "a shell script that sources the file it is handed, which posts"
run_bash "bash $T/ds/run-it.sh $T/ds/hook.conf"
refused "a shell script that runs the file it is handed, which posts"
printf '%s\n' 'import runpy, sys' 'runpy.run_path(sys.argv[1])' > "$T/ds/runner.py"
printf '%s\n' 'import urllib.request' 'urllib.request.urlopen("https://slack.com/api/chat.postMessage")' > "$T/ds/job.txt"
run_bash "python3 $T/ds/runner.py $T/ds/job.txt"
refused "a Python script that runs the file it is handed, which posts"
run_bash "python3 $T/ds/count.py $T/alert.py"
refused "a script file handed to another script is still read, since a wrapper may run it"

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
