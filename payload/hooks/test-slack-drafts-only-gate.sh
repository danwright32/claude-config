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
#
# Probing the gate by hand (claude-config#2794): drive it the way this suite does, by piping a
# hook payload into the wrapper, never by importing slack_drafts_only_gate from a Python script.
# The rule's own source names Slack's posting endpoints, so the gate refuses any script that
# imports it as one that posts, and setting PYTHONPATH only changes which refusal comes back
# (measured 2026-11-11). For example:
#   jq -n --arg c 'node tools/x.mjs a.ts' '{hook_event_name:"PreToolUse",tool_name:"Bash",
#     tool_input:{command:$c},cwd:"."}' | bash payload/hooks/slack-drafts-only-gate.sh; echo $?
# Exit 0 is allowed and 2 is refused, with the reason on stderr.
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
#
# This suite now holds the gate as a whole: /nudge, a payload it cannot read, a call it cannot judge
# in time, a crash inside its walk, its wiring, the merge helper's line, and its cost (the claude-sync
# line and the command that starts this suite). The cost checks judge the command that starts this
# suite, so it keeps this name and the sections whose text makes that command the costliest to judge.
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
# The same bytes with no extension, handed to a script that sources what it is handed: a file the
# gate cannot tell from a script, which the script runs, so it reads it as one. (Handed to a script
# that only counts its lines, it is that script's argument and is not read as code, #2797.)
# (Sourced by its path written out: one sourced through "$1" is refused unread since #2538, before any
# of it is read.)
cp "$T/big/session.jsonl" "$T/big/session"
printf '%s\n' '#!/usr/bin/env bash' ". \"$T/big/session\"" > "$T/big/count.sh"

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

# ---- #2683: a file run or sourced by a path the gate cannot work out, refused only when switched on ----
# #2678's probe found every way of running a file allowed once the gate could not work out its path:
# after an eval, after a wait on a condition it cannot read, through a variable nothing sets. Refusing
# that is built behind a switch that ships off (Dan, 2026-11-10: measure first, as #2538 does for
# sourcing), so with it off every verdict is what it was, and the measurement turns it on through
# SLACK_GATE_UNWORKED_PATHS=refuse. Each shape is in a tree whose files all post, so a pass with the
# switch off is the file left unread, exactly as before.
run_ur() { # run_ur <switch value> <command>: run_bash with SLACK_GATE_UNWORKED_PATHS set to that value
  local errf; errf="$(mktemp "${TMPDIR:-/tmp}/slack-gate-err.XXXXXXXX")"
  OUT="$(payload Bash "$(bash_input "$2")" | SLACK_GATE_UNWORKED_PATHS="$1" bash "$HOOK" 2>"$errf")"; RC=$?
  ERR="$(cat "$errf")"; rm -f "$errf"
}
UR="$T/ur"
for tree in posts quiet; do
  mkdir -p "$UR/$tree/tests" "$UR/$tree/tools/lib"
done
printf '%s\n' 'import json, urllib.request' \
  'urllib.request.urlopen("https://slack.com/api/chat.postMessage", data=json.dumps({"text": "hi"}).encode())' \
  > "$UR/posts/tools/lib/act.py"
printf '%s\n' '#!/bin/bash' 'curl -s -X POST https://slack.com/api/chat.postMessage -d channel=C1 -d text=hi' \
  > "$UR/posts/tools/lib/act.sh"
printf '%s\n' 'fetch("https://slack.com/api/chat.postMessage", { method: "POST", body: "{}" });' > "$UR/posts/tools/lib/act.js"
printf '%s\n' 'print("hi")' > "$UR/quiet/tools/lib/act.py"
printf '%s\n' '#!/bin/bash' 'echo hi' > "$UR/quiet/tools/lib/act.sh"
printf '%s\n' 'console.log("hi");' > "$UR/quiet/tools/lib/act.js"
chmod +x "$UR/posts/tools/lib/act.sh" "$UR/quiet/tools/lib/act.sh"
UR_TOP='DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
UP=..'
# The ways the walk loses ROOT (#2678's probe): an eval, a wait whose condition it cannot read
# (lib/hang-wait.sh evaluates it in the caller's shell), and a variable nothing in the script sets.
ur_lose() { case "$1" in
  evald) printf '%s\n' 'eval "$1"' ;;
  hang) printf '%s\n' ". \"$DIR/lib/hang-wait.sh\" || exit 1" 'hang_wait "$cond" 1 || exit 1' ;;
  unset) : ;;
esac; }
# The ways of running a file: <name>:<line, with @V@ for the folder holding the tools, and @U@ for
# the way up to it from the script's own, spelt from BASH_SOURCE>.
UR_FORMS=('python3:python3 "@V@/tools/lib/act.py"' 'python3B:python3 -B "@V@/tools/lib/act.py"'
  'bash:bash "@V@/tools/lib/act.sh"' 'sh:sh "@V@/tools/lib/act.sh"' 'node:node "@V@/tools/lib/act.js"'
  'source:source "@V@/tools/lib/act.sh"' 'dot:. "@V@/tools/lib/act.sh"' 'direct:"@V@/tools/lib/act.sh"'
  'subst:out="$(python3 "@V@/tools/lib/act.py" 2>&1)"' 'bsource:python3 "${BASH_SOURCE[0]%/*}/@U@/tools/lib/act.py"')
for tree in posts quiet; do
  for lose in evald hang unset; do
    v='$ROOT' u='$UP'; [ "$lose" = unset ] && v='$NOT_SET_2683' u='$NOT_SET_2683'
    for form in "${UR_FORMS[@]}"; do
      line="${form#*:}"; line="${line//@V@/$v}"; line="${line//@U@/$u}"
      { printf '%s\n' '#!/bin/bash' "$UR_TOP"; ur_lose "$lose"; printf '%s\n' "$line"; } > "$UR/$tree/tests/$lose-${form%%:*}.sh"
    done
  done
done
for lose in evald hang unset; do
  for form in "${UR_FORMS[@]}"; do
    f="$UR/posts/tests/$lose-${form%%:*}.sh"
    run_bash "bash $f"
    case "${form%%:*}" in
      source|dot)  # sourced, it is refused with the switch off too (#2538)
        refused "switched off by default, a file sourced by a path the gate cannot work out is still refused ($lose, ${form%%:*})"
        says "and it names the path ($lose, ${form%%:*})" "a path the gate cannot work out" ;;
      *) allowed "switched off by default: a file run by a path the gate cannot work out is let through unread ($lose, ${form%%:*})" ;;
    esac
    run_ur refuse "bash $f"
    refused "switched on: a file run by a path the gate cannot work out is refused ($lose, ${form%%:*})"
    says "it says it could not check, not that it found a post ($lose, ${form%%:*})" "REFUSED: the gate could not check whether this command posts to Slack"
    says "it names the path it could not work out ($lose, ${form%%:*})" "a path the gate cannot work out"
  done
done
# Not only a file that posts: the gate cannot read it, so it cannot tell one that does not.
run_ur refuse "bash $UR/quiet/tests/unset-python3.sh"
refused "switched on: a file that does not post, run by a path the gate cannot work out, is refused too"
# The reason names the script, its line, and the variable.
run_ur refuse "bash $UR/posts/tests/unset-bash.sh"
says "it names the script and line it stopped at" "the script $UR/posts/tests/unset-bash.sh, line 5, runs"
says "it names the variable that is not certain" "\$NOT_SET_2683 is not certain there"
says "it says what to do" "Write the path so it can be worked out"
run_ur refuse "bash $UR/posts/tests/evald-node.sh"
says "past an eval it names the line where the walk stopped" "since the gate stops following the script's variables at line 5: eval \"\$1\""
run_ur refuse "bash $UR/posts/tests/evald-source.sh"
says "a sourced file is named as sourced" "line 6, sources \"\$ROOT/tools/lib/act.sh\", a path the gate cannot work out"
# As a command typed: a variable the command never sets.
run_bash "python3 \"\$NOT_SET_2683/act.py\""
allowed "switched off: a command running a file through a variable it never sets is let through"
run_ur refuse "python3 \"\$NOT_SET_2683/act.py\""
refused "switched on: a command running a file through a variable it never sets is refused"
says "and says so of this command" "this command runs \"\$NOT_SET_2683/act.py\", a path the gate cannot work out"
# A program named by a variable alone is how a function runs the command it is handed, and a suite its
# stand in; refusing it newly refused 261 more of this repository's scripts (2026-11-12), so it is
# left as it was, as is the string an eval runs. A path holding a slash is a file run, and is refused.
printf '%s\n' '#!/bin/bash' 'run() { local cmd="$1"; $cmd 2>/dev/null; }' 'run "$NOT_SET_2683"' \
  '"$NOT_SET_2683" --version' 'A=1 "$NOT_SET_2683"' 'eval "$NOT_SET_2683"' > "$UR/posts/tests/bare.sh"
run_ur refuse "bash $UR/posts/tests/bare.sh"
allowed "switched on: a program named by a variable alone, or the string an eval runs, is left as before"
printf '%s\n' '#!/bin/bash' 'eval "$NOT_SET_2683/tools/lib/act.sh"' > "$UR/posts/tests/eval-path.sh"
run_ur refuse "bash $UR/posts/tests/eval-path.sh"
refused "switched on: an eval running a file by a path it cannot work out is refused"
# An assignment is not a program, however the shared reader splits it; a program past env's is found.
printf '%s\n' '#!/bin/bash' 'A+="$NOT_SET_2683/x.sh"' 'a[1]="$NOT_SET_2683/x.sh"' 'a+=("$NOT_SET_2683/x.sh")' \
  'b=("$NOT_SET_2683/x.sh" y)' 'case "$1" in /*) a+=("${1#/}") ;; esac' > "$UR/posts/tests/assigns.sh"
run_ur refuse "bash $UR/posts/tests/assigns.sh"
allowed "switched on: appends and array assignments built from a variable are not read as runs"
printf '%s\n' '#!/bin/bash' 'env "PATH=$NOT_SET_2683/bin:$PATH" "$NOT_SET_2683/tools/lib/act.sh"' > "$UR/posts/tests/env-path.sh"
run_bash "bash $UR/posts/tests/env-path.sh"
allowed "switched off: a file run past env's assignment by a path it cannot work out is let through"
run_ur refuse "bash $UR/posts/tests/env-path.sh"
says "switched on: the file run past env's quoted assignment is the one named" "runs \"\$NOT_SET_2683/tools/lib/act.sh\", a path the gate cannot work out"
# Any other value, or none, is off.
for value in "" 0 off yes 1; do
  run_ur "$value" "bash $UR/posts/tests/unset-python3.sh"
  allowed "only the value refuse switches it on (SLACK_GATE_UNWORKED_PATHS='$value')"
done
# What the switch leaves alone, with it on: a path it can work out, a file it can read, and code that
# names no file to run.
run_ur refuse "ROOT=$UR/quiet; python3 \"\$ROOT/tools/lib/act.py\""
allowed "switched on: a path built from a variable the command sets is worked out, not refused"
run_ur refuse "bash $UR/quiet/tests/hang-python3.sh"
refused "switched on: a wait on a condition it cannot read loses the path, so it is refused"
run_ur refuse "python3 $UR/posts/tools/lib/act.py"
says "switched on: a literal path to a file that posts is refused as the post it is" "REFUSED: this command posts to Slack"
run_ur refuse "python3 $UR/quiet/tools/lib/act.py"
allowed "switched on: a literal path to a file that does not post is allowed"
for cmd in "python3 -m json.tool \"\$NOT_SET_2683/x.json\"" "bash -c 'echo hi' _ \"\$NOT_SET_2683\"" \
           "python3 $UR/quiet/tools/lib/act.py \"\$NOT_SET_2683/data.json\"" "echo \"\$NOT_SET_2683/x.sh\"" \
           "bash < \"$UR/quiet/tools/lib/act.sh\"" "cat \"\$NOT_SET_2683/x.sh\" | wc -l"; do
  run_ur refuse "$cmd"
  allowed "switched on: a variable in a word that is not the file run is left alone: $cmd"
done

# ---- #2683: what the switch refused that a script sets plainly ----
# Switched on across every tracked script on 2026-11-12 it refused 185, 64 of them where the script
# sets the path plainly from its own folder. These are the shapes of those, each in the posting tree
# (where reading the file refuses it as the post it is) and the quiet one (where reading it lets it
# through), and each beside the one change that really makes the value uncertain, which stays refused.
# Taken from the scripts, not copied: every suite ends `printf 'SUITE-RESULT passed=...'`, read as
# printf binding SUITE (test-sleep-claim-notes-clock.sh, test-project-list-nudge-wiring.sh);
# lib/ai-review-common.sh prints a quoted `make-settled.py` beside its `local py`; and a comment
# saying what a test reads.
ur_plain() { # ur_plain <name> <line>...: a script in both trees, its first lines UR_TOP
  local name="$1" tree; shift
  for tree in posts quiet; do
    printf '%s\n' '#!/bin/bash' "$UR_TOP" "$@" > "$UR/$tree/tests/$name.sh"
  done
}
ur_plain suite 'SUITE="$DIR/../tools/lib/act.sh"' 'run() {' '  bash "$SUITE"' '}' 'run' \
  "printf 'SUITE-RESULT passed=%d failed=%d\\n' 0 0"
ur_plain sealed 'sealed() {' '  local py="$ROOT/tools/lib/act.py" out' '  [ -f "$py" ] || return 1' \
  '  out="$(echo x | python3 -I "$py" 2>/dev/null)" || return 1' '}' 'sealed' "printf '%s\\n' 'sealed by make-settled.py'"
ur_plain comment 'HOOK="$ROOT/tools/lib/act.sh"' '# Each case read HOOK for its verdict.' 'check() {' '  bash "$HOOK"' '}' 'check'
# `declare -F f >/dev/null`, asking whether a sourced file defined a function, binds nothing
# (pr-review-push-gate.sh, test-push-scope.sh, test-bad-byte-locale.sh).
ur_plain declf 'HOOK="$ROOT/tools/lib/act.sh"' 'for f in check run; do' '  declare -F "$f" >/dev/null || echo "$f"' 'done' \
  'bash "$HOOK"'
# A builtin's name in a sentence (test-project-list-nudge-wiring.sh: "and does not declare itself
# unrunnable" beside "SUITE-NOT-RUN"), and a case pattern named like one (this suite's own ur_lose).
ur_plain prose 'SUITE="$DIR/../tools/lib/act.sh"' 'run() {' '  bash "$SUITE"' '}' 'run' \
  'echo "and does not declare itself unrunnable" "it printed SUITE-NOT-RUN"'
ur_plain casepat 'SUITE="$DIR/../tools/lib/act.sh"' 'lose() { case "$1" in' "  evald) printf '%s\\n' x ;;" '  unset) : ;;' 'esac; }' 'run() {' '  bash "$SUITE"' '}' 'run'
# A local kept past a sourced file that binds nothing (plan-council's post-discussion.sh).
for tree in posts quiet; do
  printf '%s\n' 'CATCH_ALL=Ungrouped' > "$UR/$tree/tools/lib/names.sh"
  printf '%s\n' 'ensure=/nowhere/else.sh' > "$UR/$tree/tools/lib/rebinds.sh"
done
ur_plain localsrc 'fields() {' '  local ensure="$ROOT/tools/lib/act.sh"' '  . "$ROOT/tools/lib/names.sh"' '  bash "$ensure"' '}' 'fields'
# The same shapes where the name really is bound again, so its value is not certain.
ur_plain suite-read 'SUITE="$DIR/../tools/lib/act.sh"' 'read -r SUITE < /dev/null' 'run() {' '  bash "$SUITE"' '}' 'run'
ur_plain suite-printfv 'SUITE="$DIR/../tools/lib/act.sh"' 'printf -v SUITE %s "$1"' 'run() {' '  bash "$SUITE"' '}' 'run'
ur_plain sealed-read 'sealed() {' '  local py="$ROOT/tools/lib/act.py"' '  read -r py < /dev/null' '  python3 "$py"' '}' 'sealed'
ur_plain localsrc-rebinds 'fields() {' '  local ensure="$ROOT/tools/lib/act.sh"' '  . "$ROOT/tools/lib/rebinds.sh"' '  bash "$ensure"' '}' 'fields'
ur_plain declf-assign 'HOOK="$ROOT/tools/lib/act.sh"' 'declare HOOK="$1"' 'bash "$HOOK"'
# export -n takes the export off and keeps the value, where declare -n makes a nameref (#2538:
# test-claude-sync.sh's `export -n SUITE_FILTERED ...` ended its walk at line 1198).
ur_plain exportn 'HOOK="$ROOT/tools/lib/act.sh"' 'export -n HOOK SUITE_FILTERED 2>/dev/null || true' 'bash "$HOOK"'
ur_plain declaren 'HOOK="$ROOT/tools/lib/act.sh"' 'declare -n HOOK=OTHER' 'bash "$HOOK"'
ur_plain read-ifs 'SUITE="$DIR/../tools/lib/act.sh"' 'IFS= read -r SUITE < /dev/null' 'run() {' '  bash "$SUITE"' '}' 'run'
ur_plain read-chained 'SUITE="$DIR/../tools/lib/act.sh"' 'run() {' '  bash "$SUITE"' '}' '[ -n "$1" ] && read -r SUITE < /dev/null' 'run'
ur_plain read-case 'SUITE="$DIR/../tools/lib/act.sh"' 'case "$1" in' '  x) read -r SUITE < /dev/null ;;' 'esac' 'run() {' '  bash "$SUITE"' '}' 'run'
for shape in suite sealed comment declf localsrc prose casepat exportn; do
  run_ur refuse "bash $UR/posts/tests/$shape.sh"
  says "switched on: a path the script sets plainly is read, and a file that posts refused as the post ($shape)" \
    "REFUSED: this command posts to Slack"
  run_ur refuse "bash $UR/quiet/tests/$shape.sh"
  allowed "switched on: the same path to a file that does not post is read and let through ($shape)"
  run_bash "bash $UR/posts/tests/$shape.sh"
  says "switched off: the file is read too, so one that posts is refused ($shape)" "REFUSED: this command posts to Slack"
done
# #2832: the first command of a function body on the opener's own line was never judged, so
# `run() { bash post.sh; }` then `run` went through where the same body on its own lines was refused.
for tree in posts quiet; do
  printf '%s\n' '#!/bin/bash' "run() { bash $UR/$tree/tools/lib/act.sh; }" 'run' > "$UR/$tree/tests/oneline.sh"
  printf '%s\n' '#!/bin/bash' "function run { python3 $UR/$tree/tools/lib/act.py; }" 'run' > "$UR/$tree/tests/oneline-kw.sh"
  printf '%s\n' '#!/bin/bash' "$UR_TOP" 'run() { bash "$ROOT/tools/lib/act.sh"; }' 'run' > "$UR/$tree/tests/oneline-var.sh"
  printf '%s\n' '#!/bin/bash' "run() { echo hi; bash $UR/$tree/tools/lib/act.sh; }" 'run' > "$UR/$tree/tests/oneline-second.sh"
done
for shape in oneline oneline-kw oneline-var oneline-second; do
  run_bash "bash $UR/posts/tests/$shape.sh"
  says "the first command of a one line function body is judged: one that runs a posting file is refused ($shape, #2832)" \
    "REFUSED: this command posts to Slack"
  run_bash "bash $UR/quiet/tests/$shape.sh"
  allowed "and one that runs a file that does not post is allowed ($shape, #2832)"
done
# A copy writes its target, never what it copies from. With the target a word the gate cannot work
# out, every word was taken for a possible target, so a suite copying the hook it tests into a temp
# folder (`cp "$CHECK" "$NOLIB/check-home-paths.sh"`) and then running "$CHECK" was refused as posting
# once #2678 read files run through a variable: 25 scripts, switch off (measured 2026-11-12, #2683). A word stays a possible
# target where it is last, where every word after it can expand to nothing, or where the word before it
# may be an option that takes it as a value (-t, or a word the gate cannot work out).
ur_plain cpsrc 'T="$(mktemp -d)"' 'cp "$ROOT/tools/lib/act.sh" "$T/act.sh"' 'bash "$ROOT/tools/lib/act.sh"'
ur_plain cpsrc-mv 'T="$(mktemp -d)"' 'mv -f "$ROOT/tools/lib/act.sh" "$T/x/"' 'bash "$ROOT/tools/lib/act.sh"'
run_bash "bash $UR/quiet/tests/cpsrc.sh"
allowed "a file copied from into a folder the gate cannot work out is still read as it is (cp, #2683)"
run_bash "bash $UR/quiet/tests/cpsrc-mv.sh"
allowed "a file moved from into a folder the gate cannot work out is still read as it is (mv, #2683)"
run_bash "bash $UR/posts/tests/cpsrc.sh"
says "and the same file that posts is refused as the post (#2683)" "REFUSED: this command posts to Slack"
ur_plain cpdst 'T="$(mktemp -d)"' 'cp "$T/x" "$ROOT/tools/lib/act.sh"' 'bash "$ROOT/tools/lib/act.sh"'
ur_plain cpdst-opt 'T="$(mktemp -d)"' 'cp $OPTS "$ROOT/tools/lib/act.sh" "$T/x"' 'bash "$ROOT/tools/lib/act.sh"'
ur_plain cpdst-gone 'T="$(mktemp -d)"' 'cp "$T/x" "$ROOT/tools/lib/act.sh" $MORE' 'bash "$ROOT/tools/lib/act.sh"'
ur_plain cpdst-t 'T="$(mktemp -d)"' 'cp -t "$ROOT/tools/lib/act.sh" "$T/x"' 'bash "$ROOT/tools/lib/act.sh"'
for shape in cpdst cpdst-opt cpdst-gone cpdst-t; do
  run_bash "bash $UR/quiet/tests/$shape.sh"
  says "a file that may be the target of a copy from a word the gate cannot work out is refused unread ($shape, #2683)" \
    "what wrote it could not be told"
done
# The second reading (#2678) of code fed in a heredoc, its argument written through a variable, finds
# the heredoc by the command as the script writes it, so the file after - is judged as the same
# command with a literal path is, and not against the whole script taken as the code's input.
# The heredoc's code runs the file it is handed, so the file is read as code (#2691: code that only
# reads its argument passes, below).
ur_plain heredoc-arg 'python3 - "$ROOT/tools/lib/act.py" <<'"'EOF'" 'import sys' 'exec(open(sys.argv[1]).read())' 'EOF'
run_bash "bash $UR/posts/tests/heredoc-arg.sh"
says "a heredoc's argument written through a variable is judged as the literal path is (#2683)" "act.py posts to Slack"
ur_plain heredoc-read 'python3 - "$ROOT/tools/lib/act.py" <<'"'EOF'" 'import sys' 'print(len(open(sys.argv[1]).read()))' 'EOF'
run_bash "bash $UR/posts/tests/heredoc-read.sh"
allowed "and code that only reads that argument passes, as with a literal path (#2691)"
for shape in suite-read suite-printfv sealed-read localsrc-rebinds declf-assign read-ifs read-chained read-case declaren; do
  run_ur refuse "bash $UR/quiet/tests/$shape.sh"
  says "switched on: a name the script binds again is not certain, so its file is refused unread ($shape)" \
    "a path the gate cannot work out"
done
# Measured again on 2026-11-12 with the switch on (#2683, second pass): more shapes where the path is
# set plainly and the gate lost it. A comment holding an apostrophe inside an array assignment
# (tools/check-mod-shared-parts.sh's PARTS) was read as opening a quote, so no compound after it
# paired and the walk stopped at the first one. A plain NAME=value inside an if branch or a function
# body (bug-bash/target-guard.sh's egress) was never given a value there at all, as the walk steps
# over a compound and only a `local` had one.
ur_plain arraynote 'PARTS=(' '  "a|b"' "  # the note's apostrophe" '  "c|d"' ')' 'for p in "${PARTS[@]}"; do' '  echo "$p"' 'done' \
  "echo \"and the mod's last word\"" 'SUITE="$ROOT/tools/lib/act.sh"' 'bash "$SUITE"'
ur_plain branch 'if [ -n "$1" ]; then' '  egress="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../tools/lib/act.sh"' \
  '  grep -q x /dev/null || echo none' '  bash "$egress"' 'fi'
ur_plain funcplain 'run() {' '  helper="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../tools/lib/act.sh"' \
  '  grep -q x /dev/null || echo none' '  bash "$helper"' '}' 'run'
# The same shapes where the value really is not certain, which stay refused unread: a use in another
# branch than the one that set it (else, elif), a name bound again, a file sourced that binds it, a
# use past the function that set it, and an eval of what the script was handed.
ur_plain branch-else 'if [ -n "$1" ]; then' '  egress="$ROOT/tools/lib/act.sh"' 'else' '  bash "$egress"' 'fi'
ur_plain elsebranch 'if [ -n "$1" ]; then' '  egress="$ROOT/tools/lib/act.sh"' '  echo set' 'elif [ -n "$2" ]; then' \
  '  bash "$egress"' 'fi'
ur_plain branch-read 'if [ -n "$1" ]; then' '  egress="$ROOT/tools/lib/act.sh"' '  read -r egress < /dev/null' \
  '  bash "$egress"' 'fi'
ur_plain funcplain-src 'run() {' '  ensure="$ROOT/tools/lib/act.sh"' '  . "$ROOT/tools/lib/rebinds.sh"' '  bash "$ensure"' '}' 'run'
ur_plain funcplain-after 'run() {' '  helper="$ROOT/tools/lib/act.sh"' '}' 'run' 'bash "$helper"'
ur_plain arraynote-eval 'PARTS=(' '  "a|b"' "  # the note's apostrophe" ')' 'for p in "${PARTS[@]}"; do' '  echo "$p"' 'done' \
  "echo \"and the mod's last word\"" 'SUITE="$ROOT/tools/lib/act.sh"' 'eval "$1"' 'bash "$SUITE"'
for shape in arraynote branch funcplain; do
  run_ur refuse "bash $UR/posts/tests/$shape.sh"
  says "switched on: a path set plainly is read, and a file that posts refused as the post ($shape, #2683)" \
    "REFUSED: this command posts to Slack"
  run_ur refuse "bash $UR/quiet/tests/$shape.sh"
  allowed "switched on: the same path to a file that does not post is let through ($shape, #2683)"
done
for shape in branch-else elsebranch branch-read funcplain-src funcplain-after arraynote-eval; do
  run_ur refuse "bash $UR/quiet/tests/$shape.sh"
  says "switched on: a value that is not certain stays refused unread ($shape, #2683)" "a path the gate cannot work out"
done

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
# the ceiling raised on a new measurement. Measured again on 2026-11-10: 7,975 steps, 12 files read
# 35 times, the 76 more all from the helper (one more sourced file), none from the gate; and 8,132
# later that day, once the helper had grown again.
MWR="bash $DIR/lib/merge-when-ready.sh 123 --repo danwright32/claude-config --delete-branch"
MWR_STEPS=12000
run_budget "$MWR_STEPS" "$MWR"
allowed "the real merge helper, with everything it sources, is judged within $MWR_STEPS steps"
# The control: the budget is live for this line, and a walk that passes it is refused with the
# gate's own reason.
run_budget 2000 "$MWR"
refused "the merge helper's line under a budget its walk passes is refused"
says "that refusal says the gate ran out of time" "ran out of time"
says "and says how to merge without the helper" "gh pr merge"
says "and to leave the branch for the helper" "--delete-branch"
run_budget "$TICKS" "bash $T/big/count.sh $T/big/session"
refused "a call that is no merge still runs out of its budget"
lacks "a call that is no merge gets no merge advice" "gh pr merge"
# The advice belongs to running out of time only: a line the gate did judge, and refused for
# posting, says nothing of merging however it names the helper.
run_bash "curl -X POST https://slack.com/api/chat.postMessage -d channel=C1 -d text=hi; echo merge-when-ready.sh"
refused "a line that posts and names the merge helper is refused for the post"
says "and that refusal is for the post" "posts to Slack:"
lacks "and carries no merge advice" "gh pr merge"

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
# h evaluates its own argument, so since #2912 it is read at each call to it: g hands it text the gate
# cannot read, which ends the walk; handed nothing (g0), it evaluates nothing, and the walk goes on.
stop = "KEEP=/keep\ng() {\n  h \"$2\"\n}\ng0() {\n  h\n}\nh() {\n  eval \"$1\"\n}\n%s\n: after\n"
ends = [judge.sh_cwd_at(judge.sh_known(stop % call, "/", None), (stop % call).index(": after"))
        for call in ("g", ": g", "g0")]
if ends != [False, True, True]:
    print("the walk past a call reaching eval of what it cannot read, past none, and past one evaluating "
          "nothing read %r, not [False, True, True]" % ends); sys.exit()
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
# Counted beneath what the gate puts over the reader (remember_readings, claude-config#2784), so each
# count is a real reading, whoever asked for it.
import os
spec = importlib.util.spec_from_file_location("shell_words", os.path.join(os.path.dirname(sys.argv[1]), "lib", "shell-words.py"))
sw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sw)
parses, real = {}, sw.commands
def counting(s, cwd="", heredocs=None, parts=None, spans=None, comments=None, unsure=None):
    if heredocs is None and spans is None:
        parses[(s, cwd)] = parses.get((s, cwd), 0) + 1
    return real(s, cwd, heredocs=heredocs, parts=parts, spans=spans, comments=comments, unsure=unsure)
sw.commands = counting
gate.remember_readings(sw)
judge = gate.Judge(sw)
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
once="$(python3 -B "$T/once.py" "$DIR/slack_drafts_only_gate.py" "$T/once" 2>&1)"
check "a text is read into commands once, and a sourced file asked about a name once (#2576)" "$once"

echo "slack drafts only: a claude-sync line is judged in about the time it took at #2640 (claude-config#2784)"

# The #2642 replay (2026-11-11) found `claude-sync lesson L174`, which CLAUDE.md tells every session
# to run, judged in 7.9 seconds on average against 1.8 at #2640, and 48 lines running claude-sync two
# or three times out of time and refused. Measured here the same day: 8.1 seconds of processor time
# on main, 1.8 at #2640, 1.8 with the fix. Three causes: sh_binds' NAME= pattern opened on a
# lookbehind, so re tried it at every character of claude-sync's 973,000 (16 ms a pass, once per local
# the walk follows, 4 seconds); claude-sync was read into commands twice, by the line being judged and
# by every_command (a second each under a profiler); and each of its 14,000 commands cut a copy of all
# the text before it, split it into lines, and read its own words three times over.
# Held two ways. The work itself, counted, which no load can move (L290): one reading of claude-sync
# into commands and one of each command's words in a run, and the same answers from sh_binds as the
# patterns it had. And the time, as processor time against a yardstick taken in the same run (L656):
# on 2026-11-11 the reader's one reading of claude-sync (0.3 seconds), so one lesson line came to
# about 6 readings with the fix and 27 on main, and three lesson lines to 11 with the fix, while main
# ran out of its 11 seconds; since 2026-11-15 a fixed workload sharing nothing with the gate (cost.py,
# #2918), the least of at least seven samples. The ceilings, 12 and 22 readings, became 36 and 66
# units: the same seconds on the personal MacBook, where one unit took 0.095 s and the two lines 19.6
# and 27.7 units on 2026-11-15. Each run's measurements are printed at the end of this part.
check "a copy of the gate that holds no reading is made for the checks of #3255 to be seen to fail on" \
  "$(if grep -q '^ONCE = False$' "$unheld_made/slack_drafts_only_gate.py" 2>/dev/null && ! grep -q '^ONCE = True$' "$unheld_made/slack_drafts_only_gate.py"; then echo ok; else echo "slack_drafts_only_gate.py has no line 'ONCE = True' to turn, so the copy at $unheld_made is not a gate that holds nothing"; fi)"
several=""
# Every SUITE-NOTE this part prints goes through here and is counted, because run-all-tests shows a
# passing suite's first SUITE_NOTE_MAX of them and drops the rest (#505): the note holding the
# readings must come before the cap, and this count is how the suite knows it did (#3170).
notes_n=0
phase_notes=""
suite_note() { notes_n=$((notes_n + 1)); printf 'SUITE-NOTE %s\n' "$1"; }
# The limit each cost case is held to, in units of the yardstick, for a platform (uname -s; this
# machine's when none is given). The one place the limits that differ by platform live (#3170).
# Two limits are the same on every platform and are set where they are judged, not here: three
# lessons (66) and the slow reader (1.25 times the run's own one lesson reading). The fallback
# case, where the gate's seconds run out (short-budget), takes the one lesson limit through here
# by design.
#
# ONE LESSON: 36 ON macOS AND 46 OFF IT (#3170, Dan's choice of 2026-11-25: "1.1 Limit 46 on Linux
# (Recommended)", the option reading "Your 11-23 rule, top reading plus 15%: 40.3 times 1.15. macOS
# stays 36."). The rule is the one suite-cold's limit took on 2026-11-23 (#3406): the highest
# reading that platform gave, times 1.15, to the nearest unit. Linux: 77 attempts of the tests
# workflow on 2026-11-25 printed readings; one lesson read a median of 33.0, 90 percent at or under
# 35.6, and at most 40.3 (run 45733139735 attempt 1, a Xeon 6975P-C), so 46. The fallback case read
# at most 39.3 that day, under the same 46. 5 of those 77 attempts failed the old limit of 36, every
# one on these two cases only and every one passing on the runner's own second try. The reading
# moves with the runner's processor model: the one lesson median that day ran from 35.5 on the
# fastest (EPYC 9V45) down to 29.7 on the slowest (EPYC 7763) for the same gate code. macOS keeps
# 36, set from the personal MacBook on 2026-11-15 (see the ceilings of 36 and 66 above).
# What 46 no longer catches, from the 2026-11-25 medians: a gate up to about 29 percent dearer
# passes on the fastest runner model and up to about 55 percent on the slowest; 36 already let 21
# percent through on the slowest and caught about 1 percent on the fastest. The counted work and the
# slow reader check below (1.25 times the run's own one lesson reading) are unaffected.
cost_limit() {
  local platform="${2:-$(uname -s)}"
  case "$1" in
    one-lesson) case "$platform" in Darwin) echo 36 ;; *) echo 46 ;; esac ;;
    short-budget) cost_limit one-lesson "$platform" ;;
    suite-cold) case "$platform" in Darwin) echo 67 ;; *) echo 91 ;; esac ;;
    own-suite) case "$platform" in Darwin) echo 17 ;; *) echo 18 ;; esac ;;
    *) echo "no cost limit is set for $1" >&2; return 1 ;;
  esac
}
# Each platform's limits, asked for by platform name, so a Mac run holds the Linux numbers too
# (#3170): only this machine's branch is ever judged against a reading.
limit_pair() { printf '%s/%s' "$(cost_limit "$1" Darwin 2>&1)" "$(cost_limit "$1" Linux 2>&1)"; }
limit_is() { if [ "$(limit_pair "$1")" = "$2" ]; then echo ok; else echo "$1 has $(limit_pair "$1") on Darwin/Linux, not $2"; fi; }
# Two limits that must be the same number on each platform. Both sides failing alike is no pass
# (L98): the first has to be a pair of numbers before it is compared. Functions, since macOS's bash
# 3.2 cannot read a case statement inside a command substitution (seen 2026-11-25).
limit_tied() {
  local a b
  a="$(limit_pair "$1")"; b="$(limit_pair "$2")"
  case "$a" in
    [0-9]*/[0-9]*) if [ "$a" = "$b" ]; then echo ok; else echo "$1 has $a on Darwin/Linux, $2 $b"; fi ;;
    *) echo "$1 has no limit to compare: '$a'" ;;
  esac
}
limit_default() {
  local here mine
  here="$(cost_limit "$1" 2>&1)"; mine="$(cost_limit "$1" "$(uname -s)" 2>&1)"
  case "$here" in
    ''|*[!0-9]*) echo "with no platform it gave '$here', which is no number" ;;
    *) if [ "$here" = "$mine" ]; then echo ok; else echo "with no platform it gave $here, for $(uname -s) $mine"; fi ;;
  esac
}
check "one claude-sync lesson is held to 36 units on macOS and 46 on Linux (#3170)" "$(limit_is one-lesson 36/46)"
check "where the gate's seconds run out it is held to the one lesson limit on each platform (#3170)" \
  "$(limit_tied short-budget one-lesson)"
check "bash tests/test-claude-sync.sh is held to 67 units on macOS and 91 on Linux (#3406)" "$(limit_is suite-cold 67/91)"
check "the command that starts this suite is held to 17 units on macOS and 18 on Linux (#3255)" "$(limit_is own-suite 17/18)"
check "a cost case's limit, asked for with no platform, is this machine's (#3170)" \
  "$(limit_default one-lesson)"
check "a cost case with no limit of its own is refused rather than given one (#3170)" \
  "$(if got="$(cost_limit no-such-case Linux 2>/dev/null)"; then echo "it was given '$got'"; else echo ok; fi)"
if [ -z "$CS" ]; then
  # L411: with no claude-sync on this Mac there is nothing to measure, and a red would read as the gate.
  echo "SUITE-PART-UNMEASURED #2784: no claude-sync in this checkout or at ~/claude-config-sync, so the time to judge a claude-sync line was not measured"
else
  cat > "$T/work.py" <<'PY'
import importlib.util, os, re, sys
gate_path, cs = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("gate", gate_path)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
spec = importlib.util.spec_from_file_location("shell_words", os.path.join(os.path.dirname(gate_path), "lib", "shell-words.py"))
sw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sw)
# Counted beneath whatever the gate puts over the reader, so each count is a real reading.
reads, rests = {}, {}
plain, plain_rest = sw.commands, sw.command_rest
def commands(s, cwd="", heredocs=None, parts=None, spans=None, comments=None, unsure=None):
    if heredocs is None and spans is None:
        reads[(s, cwd)] = reads.get((s, cwd), 0) + 1
    return plain(s, cwd, heredocs=heredocs, parts=parts, spans=spans, comments=comments, unsure=unsure)
def command_rest(text, passed=None):
    if passed is None:
        rests[text] = rests.get(text, 0) + 1
    return plain_rest(text, passed)
sw.commands, sw.command_rest = commands, command_rest
remember = getattr(gate, "remember_readings", None)
if remember is None:
    print("the gate has no remember_readings, so the reader reads each text afresh for every caller"); sys.exit()
remember(sw)
judge = gate.Judge(sw)
line = cs + " lesson L174; " + cs + " lesson L290"
if judge.line(line, "/", 0, line) is not None:
    print("two claude-sync lessons were refused"); sys.exit()
text = open(cs).read()
wrong = []
whole = sum(n for (s, _), n in reads.items() if s == text)
if whole != 1:
    wrong.append("claude-sync was read into commands %d times" % whole)
again = sorted(n for n in rests.values() if n > 1)
if again:
    wrong.append("one command's words were read %d times" % again[-1])
# sh_binds answers as the patterns it had did, over every name claude-sync binds or reads, on a
# piece of it and on texts placed to catch a line's edges. Each pattern here runs over the whole text;
# sh_binds reads only the lines holding the name. Since #2683 the rules are: printf binds only through
# -v, a line that is only a comment binds nothing, and a builtin binds only in command position;
# since #2538 a name inside a quoted string on its line binds nothing (sh_quoted_word_at), unless the
# string is a word handed to export, local, declare, typeset or readonly, or a trap's.
SH_BINDERS = (r"\b(?:read|for|select|local|declare|typeset|export|readonly|unset|getopts|mapfile|readarray|let)\b"
              r"[^\n;&|]*?(?<![\w$]){0}\b|\bprintf\b[^\n;&|]*?\s-v\s*['\"]?{0}\b|\$\{{{0}:?=")
def comment(t, at):
    s = t.rfind("\n", 0, at) + 1
    return t[s:at + 1].lstrip(" \t").startswith("#")
def before(name, t, allowed=0):
    if name not in t:
        return False
    n = re.escape(name)
    if sum(1 for m in re.finditer(r"(?<![\w$])" + n + r"(?:\[[^\]\n]*\])?\+?=", t)
           if not comment(t, m.start()) and not gate.sh_quoted_word_at(t, m.start())) > allowed:
        return True
    if any(not comment(t, m.start()) for m in re.finditer(r"\(\([^()]*(?<![\w$])" + n + r"\b", t)):
        return True
    pat, pos = re.compile(SH_BINDERS.format(n)), 0
    while True:
        m = pat.search(t, pos)
        if not m:
            return False
        w = m.group(0)
        if not comment(t, m.start()) and not re.match(r"(?:export|readonly)\b", w) and (
                w.startswith("$") or (gate.sh_command_at(t, t.rfind("\n", 0, m.start()) + 1, m.start())
                                      and not gate.sh_quoted_word_at(t, m.end() - len(name)))):
            return True
        pos = m.start() + 1
piece = text[200000:260000]
names = sorted(set(re.findall(r"\b[A-Za-z_]\w*\b", piece)))
edges = ["x=1", "\nx=1", "$x=1", "ax=1", "x[1]=a\n", "local\nx", "read -r a x", "export x", "export x=1",
         "(( y +\n x ))", "((a)) x", "echo ${x:=d}", "for x in a", "a; read x", "x", "local y x\nexport x",
         "printf -v x %s", "y=x=1", "x+=1", "x\n=1", "readonly x;x=2", "# read x", "  # x=1", "printf 'x %s'",
         'echo "now read x"', "IFS= read -r x", "if read x", "a # read x\nread x", "f() { local x; }",
         "local top='x=1'", "printf '%s' 'x=1'", "export 'x=1'", "trap 'x=1' EXIT", "echo \"x=1\"; x=2"]
# What the quoted string rule decides, said outright rather than only matched against itself.
told = {t: gate.Judge.sh_binds("x", t) for t in ("local top='x=1'", "printf '%s' 'x=1'", "export 'x=1'",
                                                 "trap 'x=1' EXIT", "local a 'x=1'", "echo 'it''s' x=1")}
if told != {"local top='x=1'": False, "printf '%s' 'x=1'": False, "export 'x=1'": True,
            "trap 'x=1' EXIT": True, "local a 'x=1'": True, "echo 'it''s' x=1": True}:
    wrong.append("a quoted NAME=value was read as %r" % told)
bad = []
for t in [piece] + edges:
    for name in (names if t is piece else ["x"]):
        for allowed in (0, 1):
            if gate.Judge.sh_binds(name, t, allowed) != before(name, t, allowed):
                bad.append((name, t if t is not piece else "claude-sync", allowed))
if bad:
    wrong.append("sh_binds answered differently from the patterns it had for %d cases, first %r" % (len(bad), bad[0]))
if len(names) < 500:
    wrong.append("only %d names were compared" % len(names))
print("; ".join(wrong) or "ok")
PY
  work="$(python3 -B "$T/work.py" "$DIR/slack_drafts_only_gate.py" "$CS" 2>&1)"
  check "claude-sync is read once in a run, and sh_binds answers as it did (#2784)" "$work"

  cat > "$T/cost.py" <<'PY'
import json, os, re, resource, statistics, subprocess, sys, tempfile, time
hook, cs, ceiling = sys.argv[1], sys.argv[2], float(sys.argv[3])
# --line <command line> judges that line instead of claude-sync lessons (#2918).
line = sys.argv[5] if sys.argv[4] == "--line" else " ; ".join("%s lesson %s" % (cs, l) for l in sys.argv[4:])
# The yardstick is a fixed workload sharing no code and no input with the gate (#2918, Dan's decision
# of 2026-11-15): it cuts a made up shell-like text into tokens with a pattern, counts them in a dict
# through a small function, and walks each line's quotes with str.find, the kinds of work the gate
# does, so a slower machine or Python slows both alike. It was the gate's own reader reading
# claude-sync, which a cut to that reader shrank along with the gate (a 6% cut read as 5% dearer),
# and which grew whenever claude-sync did. One unit took 0.095 s of processor time on the personal
# MacBook on 2026-11-15.
WORDS = ("alpha", "beta", "gamma", "delta", "eps", "zeta", "theta", "iota", "kappa", "lambda", "mu")
LINES = []
for i in range(2400):
    a, b, c, d = (WORDS[(i * k) % len(WORDS)] for k in (1, 3, 5, 7))
    LINES.append("%s_%d \"%s ${%s}\" | %s=%d; %s '%s' # %s %d" % (a, i % 97, b, c, d, i, a, c, b, i * 7))
TOKEN = re.compile(r"\"[^\"]*\"|'[^']*'|\$\{?\w+\}?|[A-Za-z_]\w*=|\w+|[|;&#]")
def keep(tok, seen):
    k = tok[:3]
    seen[k] = seen.get(k, 0) + 1
    return len(tok)
def yard():
    t = time.process_time()
    seen, total = {}, 0
    for _ in range(10):
        for text in LINES:
            for m in TOKEN.finditer(text):
                total += keep(m.group(0), seen)
            q = text.find('"')
            while q >= 0:
                q = text.find('"', q + 1)
            total += len(text.split()) + (text.rfind("#") > 0)
    return time.process_time() - t
# SLACK_GATE_COST_REPLAY names a doctored record to judge in place of the gate (#3170): a JSON list
# of judgements, each with its "units", what the cache "said" of it and, for a refusal, its "exit"
# and "stderr". With it set no gate is run and no yardstick is timed (the code sets the unit to one
# second, which is not a measurement, so a judgement's seconds are its units); everything after
# that, which samples are taken, what each must show and the verdict, is the code every measurement
# runs. It is how the suite sees the cached cases' verdicts on records this machine cannot make, a
# judgement that ran out of the gate's seconds among them. No measurement sets it.
replay = None
if os.environ.get("SLACK_GATE_COST_REPLAY"):
    with open(os.environ["SLACK_GATE_COST_REPLAY"]) as f:
        replay = json.load(f)
    yard = lambda: 1.0
# Several samples, and the least is the unit (L656): load only ever adds to a sample.
samples = [yard() for _ in range(5)]
payload = json.dumps({"session_id": "s", "transcript_path": "/tmp/t.jsonl", "cwd": "/", "permission_mode": "auto",
                      "hook_event_name": "PreToolUse", "tool_name": "Bash",
                      "tool_input": {"command": line, "description": "d"}, "tool_use_id": "t"})
# One judgement is one sample, and one sample cannot be told from noise (L656, L395): on a CI runner
# one reading of 12.5 crossed a ceiling of 12 that the personal MacBook measures at 10.8 (#2915). So
# a judgement past the ceiling is measured again, up to three in all, and the least is judged, each
# against yardstick samples taken around it. A cold measurement (an empty cache to start) is
# repeated from an empty cache each time, so no sample is answered from the one before.
# SLACK_GATE_COST_SAMPLES asks for that many judgements whether or not the first is inside the
# ceiling (#3170), for a case whose limit is to be placed from its readings on a runner (L172): the
# verdict is the same, the least of them against the ceiling, and the log then holds the spread.
cache = os.environ.get("SLACK_GATE_CACHE_DIR", "")
cold = bool(cache) and os.path.isdir(cache) and not os.listdir(cache)
# What the judgement cache did for each judgement, in its own words (SLACK_GATE_CACHE_TRACE): "hit"
# where it answered, "miss: ..." or "off: ..." where the gate judged afresh. A cold measurement holds
# the gate's whole work only while the cache answers none of its samples (L102), and the least
# sample is the one judged, so a single answered sample, at about 2 units, would pass any ceiling.
# So every sample of a cold measurement must be one the cache says it did not answer, and the
# measurement fails otherwise, whatever the units (#3255). The warm cases are held the other way:
# handed a cache that already holds something, every sample must be one the cache says it answered.
# One trace file for every run of this script: its name is part of the cache's key (KEY_ENV), and
# a judgement asked a second time has to be asked under the key the first was kept under.
trace = os.path.join(os.path.dirname(cache.rstrip("/")), "cost-cache-trace.log") if cache else ""
def judge(env):
    """One judgement: the finished process, its processor seconds, and what the cache traced for it."""
    if replay is not None:
        r = replay.pop(0)
        return subprocess.CompletedProcess(["replay"], r.get("exit", 0), "", r.get("stderr", "")), float(r["units"]), list(r["said"])
    if trace:
        env["SLACK_GATE_CACHE_TRACE"] = trace
    at = os.path.getsize(trace) if trace and os.path.exists(trace) else 0
    was = resource.getrusage(resource.RUSAGE_CHILDREN)
    p = subprocess.run(["bash", hook], input=payload, capture_output=True, text=True, env=env)
    now = resource.getrusage(resource.RUSAGE_CHILDREN)
    said = []
    if trace and os.path.exists(trace):
        with open(trace, errors="replace") as f:
            f.seek(at)
            said = [s for s in f.read().splitlines() if not s.startswith("parse ")]
    return p, (now.ru_utime - was.ru_utime) + (now.ru_stime - was.ru_stime), said
# A cached case is handed the folder an earlier cold measurement made its first judgement in, and
# needs that judgement kept there. The gate keeps only a judgement it finished, so where that one
# ran out of the gate's seconds the folder holds no judgement, and nothing the cached case does can
# put the earlier one there. On 2026-11-21 that failed a pull request that did not touch the gate
# (run 44965167694, a runner at 0.151 s a unit): the cold judgement ran out after 10.4 s, and the
# cached case failed on its own first sample, 52.0 units, where the cache traced "miss: no entry |
# stored", though the next was answered from the cache at 1.7. It is a state this case cannot set
# and can see, so it says unmeasured and never fails or passes on it (L411; Dan's decision of
# 2026-11-21, "Build it", with no limit changed).
# What it sees, both required: the cold measurement wrote down here that the one judgement it made
# in the folder it was handed was refused for running out (its exit code and its refusal, never the
# cache's word, L345; later cold samples get folders of their own and write nothing), and the
# cache's own trace for this case's first sample says nothing was kept: "miss: no entry", or "miss:
# no signing key" where the judgement ran out before anything at all was kept and left the folder
# empty. Every other miss is the defect these cases exist to catch and still fails: no such record
# (the entry should have been there), an entry that was there and not used, a stale one, and any
# later sample the cache did not answer, the first having stored it. The later samples' least is
# still held to the ceiling.
unfilled_log = os.path.join(os.path.dirname(cache.rstrip("/")), "cost-cache-unfilled.log") if cache else ""
ran_out_before = None
if unfilled_log and os.path.exists(unfilled_log):
    with open(unfilled_log) as f:
        for l in f:
            parts = l.rstrip("\n").split("\t")
            if len(parts) == 3 and parts[0] == os.path.basename(cache.rstrip("/")):
                ran_out_before = (parts[1], parts[2])
# Such a folder can be empty and is a cached case's all the same, never a cold measurement's.
cold = cold and not ran_out_before
warm = bool(cache) and os.path.isdir(cache) and not cold
NOTHING_KEPT = ("miss: no entry", "miss: no signing key")
UNFILLED = "unmeasured: the cache this case was handed was never filled: the judgement that fills it (%s) ran out of the gate's seconds on this machine, after %s, and a judgement that runs out is not kept. "
filled_here = ""
ratios, ran_out, unfit = [], [], []
# How many yardstick samples had been taken when each reading's unit was read, printed beside the
# readings (#3170) and used for nothing else.
taken = []
need =int(os.environ.get("SLACK_GATE_COST_SAMPLES", "1"))
for attempt in range(max(need, int(os.environ.get("SLACK_GATE_COST_ATTEMPTS", "3")))):
    env = dict(os.environ)
    if cold and attempt:
        env["SLACK_GATE_CACHE_DIR"] = tempfile.mkdtemp(dir=os.path.dirname(cache.rstrip("/")))
    p, spent, said = judge(env)
    samples += [yard(), yard()]
    unit = min(samples)
    if p.returncode != 0 and cold and env.get("HOOK_TESTS_RUNNING") != "1" and "ran out of time judging this call" in p.stderr:
        # The gate's budget is seconds, and how many of them this machine needs for one unit of work
        # is not the gate's doing: on CI's slowest runners (a unit of 0.16 to 0.22 s against 0.095 s on
        # the personal MacBook) a gate inside its ceiling still ran out of its 11 seconds, and the
        # check failed on the runner's speed (claude-config#3170, four runs to 2026-11-20). This
        # check holds the gate's work, in units, so where the seconds ran out the same line is
        # judged again from an empty cache on the step clock, which no speed can end, and those
        # units are held to the same ceiling: a gate that does more work still fails here, on any
        # machine (L411). That the seconds ran out is recorded beside the reading.
        ran_out.append("%.1f s at %.3f s a unit" % (spent, unit))
        if not attempt:
            # The one judgement made in the folder this measurement was handed, so the folder holds
            # no judgement: written down for the cached case that is handed the folder next.
            with open(unfilled_log, "a") as f:
                f.write("%s\t%s\t%s\n" % (os.path.basename(cache.rstrip("/")), os.environ.get("SLACK_GATE_COST_LABEL", "?"), ran_out[-1]))
        env.update(HOOK_TESTS_RUNNING="1", SLACK_GATE_TICK_BUDGET="1000000000",
                   SLACK_GATE_CACHE_DIR=tempfile.mkdtemp(dir=os.path.dirname(cache.rstrip("/"))))
        p, spent, said = judge(env)
        samples += [yard(), yard()]
        unit = min(samples)
    # The first sample of a cached case whose cache was never filled, by both things it must see.
    empty = bool(warm and ran_out_before and not ratios and "hit" not in said and any(s in NOTHING_KEPT for s in said))
    if p.returncode != 0:
        if empty and "ran out of time judging this call" in p.stderr:
            print((UNFILLED + "This case's first judgement found nothing kept and ran out as well, after %.1f s of processor time at %.3f s a unit, where the cache traced %s, so nothing could be kept on this machine and no answer from the cache was there to measure")
                  % (ran_out_before + (spent, unit, " | ".join(s[:80] for s in said)))); sys.exit()
        print("the line was refused (exit %d) after %.1f s of processor time: %s" % (p.returncode, spent, p.stderr[:200])); sys.exit()
    ratios.append((spent / unit, spent, unit))
    taken.append(len(samples))
    # A trace that says neither is no evidence the sample was cold, so it fails too (L98). A
    # measurement handed a cache that already holds something is one of the cache answering (the
    # warm cases), and there every sample must be a "hit": the same reading of the trace, required
    # to say the opposite, so each run of the suite shows it telling the two apart.
    afresh = "hit" not in said and any(s.startswith(("miss: ", "off: ")) for s in said)
    if empty:
        # It did the whole work and, where its trace says "stored", filled the cache itself. It is
        # not a sample of the cache answering and not a defect; every sample after it is held as ever.
        filled_here = "%.1f units, where the cache traced %s" % (spent / unit, " | ".join(s[:80] for s in said))
    elif (cold and not afresh) or (warm and "hit" not in said):
        unfit.append("sample %d, %.1f units, where the cache traced %s"
                     % (len(ratios), spent / unit, " | ".join(s[:80] for s in said) or "nothing"))
    if len(ratios) >= need and min(ratios)[0] <= ceiling:
        break
ratio, spent, unit = min(ratios)
# Every measurement is recorded where the suite prints it, passing or not, so the ceiling's premise
# can be measured again from any run's log, a CI runner's included (L316).
# PRINTED ONLY, never judged (#3170, Dan's decision of 2026-11-21, "Measure more first"): after the
# readings, each one's processor seconds ("seconds per reading"), the unit it was divided by and how
# many yardstick samples that unit was the least of ("yardstick per reading", 5 before the first
# judgement and 2 after each, 2 more where the seconds ran out), every yardstick sample in the order
# taken ("yardstick N samples"), and their least, median and greatest. Some CI runners read a case
# over its limit with the gate unchanged, and the logs held the seconds and the unit for one case
# only and the least sample alone, so whether a busy spell moved the gate and not the yardstick
# could not be read. These are the figures the case already took; no extra sample is timed for
# them, and the verdict below reads none of them. The suite holds that with
# tools/gate-cost-rows.py check, which fails unless each reading is its seconds over the least
# sample taken by then and the judged reading is the least of them.
log = os.environ.get("SLACK_GATE_COST_LOG")
if log:
    with open(log, "a") as f:
        f.write("%s %s: %.1f (%.2f s of processor time, unit %.3f s, ceiling %s, samples %s%s%s; %s)\n"
                % (os.environ.get("SLACK_GATE_COST_LABEL", "?"), line[-40:], ratio, spent, unit, ceiling,
                   ", ".join("%.1f" % r[0] for r in ratios),
                   "; the gate's 11 s ran out on this machine, after %s, so those were read on the step clock"
                   % " and ".join(ran_out) if ran_out else "",
                   # Read by tools/gate-cost-rows.py for its last column, so the words are held there
                   # too; no bar and no bracket, which separate the entries of the note this goes in.
                   "; the cache was never filled, the judgement that fills it having run out of the gate's seconds after %s, so the first reading here filled it"
                   % ran_out_before[1] if filled_here else "",
                   "seconds per reading %s; yardstick per reading %s; yardstick %d samples %s; yardstick least %.4f, median %.4f, greatest %.4f"
                   % (", ".join("%.3f" % r[1] for r in ratios),
                      ", ".join("%.4f from %d" % (r[2], n) for r, n in zip(ratios, taken)),
                      len(samples), ", ".join("%.4f" % y for y in samples),
                      min(samples), statistics.median(samples), max(samples))))
if unfit:
    print("%d of the %d samples of this measurement from %s, so the least of them (%s) is not the cost this limit is for: %s"
          % (len(unfit), len(ratios),
             "an empty cache were not shown to be judged afresh" if cold else "a filled cache were not answered from it",
             ", ".join("%.1f" % r[0] for r in ratios), "; ".join(unfit)))
    sys.exit()
if filled_here and ratio <= ceiling:
    later = ratios[1:]
    print((UNFILLED + "So the first sample here did the whole work, %s, and %s; an answer from a judgement kept by an earlier measurement was not measured")
          % (ran_out_before + (filled_here,
             "the %d after it %s answered from the cache, at %s units" % (len(later), "was" if len(later) == 1 else "were", ", ".join("%.1f" % r[0] for r in later))
             if later else "no sample was taken after it")))
    sys.exit()
# A case asked for it (SLACK_GATE_COST_RAN_OUT_UNMEASURED=1, the cold suite case alone) is not
# failed on step clock readings only (#3406, Dan's decision of 2026-11-26, "3.60.1 Read it as
# unmeasured"). Over the 2026-11-26 pull request runs every red on that case began with a first
# judgement that ran out of the gate's seconds; a first judgement that finished inside them read
# 66.8 to 88.5, with the gate's work the same count on each. In 2 of the 8 reds whose logs were read
# every sample ran out; in the other 6 samples 2 and 3 finished inside the seconds and read past the
# limit as well (92.0 to 98.1), so those stay red under this rule. The rule: a reading
# past the ceiling is unmeasured only where EVERY sample taken ran out and was read on the step
# clock. One sample that finished inside the seconds and is past the ceiling fails the case as ever,
# since it is the reading this limit is for; any sample at or under the ceiling passes as ever. The
# limit does not move, and tools/ci-cold-cost-streak.sh turns main red when this has been the
# answer on main several trees in a row, so a real slowdown cannot hide here.
if (ratio > ceiling and ran_out and len(ran_out) == len(ratios)
        and os.environ.get("SLACK_GATE_COST_RAN_OUT_UNMEASURED") == "1"):
    print("unmeasured: every judgement of this case ran out of the gate's seconds on this machine, after %s, so each was read on the step clock instead, at %s units against the limit of %s, and a reading taken only on the step clock is not held to the limit, while a sample that finishes inside the seconds is held to it as ever (#3406)"
          % (" and ".join(ran_out), ", ".join("%.1f" % r[0] for r in ratios), ceiling))
    sys.exit()
print("ok" if ratio <= ceiling else "judging it took at least %.1f s of processor time, %.1f units of the fixed yardstick (%.3f s each), past %s, in each of %d samples (%s)"
      % (spent, ratio, unit, ceiling, len(ratios), ", ".join("%.1f" % r[0] for r in ratios)))
PY
  export SLACK_GATE_COST_LOG="$T/cost.log"
  several="one-lesson"
  lesson_ceiling="$(cost_limit one-lesson)"
  cost="$(SLACK_GATE_COST_LABEL=one-lesson SLACK_GATE_COST_SAMPLES=3 SLACK_GATE_CACHE_DIR="$(mktemp -d "$T/cold.XXXXXX")" env -u SLACK_GATE_TICK_BUDGET -u HOOK_TESTS_RUNNING python3 -B "$T/cost.py" "$HOOK" "$CS" "$lesson_ceiling" L174 2>&1)"
  check "one claude-sync lesson is judged within $lesson_ceiling units of the yardstick on $(uname -s) (#2784, #3170)" "$cost"
  cost="$(SLACK_GATE_COST_LABEL=three-lessons SLACK_GATE_CACHE_DIR="$(mktemp -d "$T/cold.XXXXXX")" env -u SLACK_GATE_TICK_BUDGET -u HOOK_TESTS_RUNNING python3 -B "$T/cost.py" "$HOOK" "$CS" 66 L174 L290 L656 2>&1)"
  check "three claude-sync lessons in one line are judged within 66 units of the yardstick (#2784)" "$cost"
  # The yardstick must not move with the gate (#2918, Dan's decision of 2026-11-15). Measured by the
  # gate's own reader, a cut to that reader shrank the yardstick with it and read as no change, and a
  # reader made slower slowed both alike and read as no change either. So a copy of the gate whose
  # reader burns ten times its own processor time again must read as at least a quarter dearer than
  # the gate itself judging the same line, measured just above. Ten, not three: with three the slowed
  # copy read 23.9 against a limit of 23.5 once the real reader got faster, a margin load could erase;
  # with ten it read 36.2 to 41.8 against 21.9 to 24.1 (the gate 17.1 to 19.3), and its 3.4 to 4.2 s of
  # processor time stays well inside the gate's 11 s budget, which sixteen times again (5.4 s) once
  # ran past at a load of 35 (#3037, 2026-11-15).
  slow="$T/slow-gate"
  mkdir -p "$slow" && cp "$HOOK" "$DIR/slack_drafts_only_gate.py" "$slow/" && cp -R "$DIR/lib" "$slow/lib"
  cat >> "$slow/lib/shell-words.py" <<'PY'
_plain_commands = commands
def commands(*a, **k):
    import time
    t = time.process_time()
    got = _plain_commands(*a, **k)
    end = time.process_time() + 10 * (time.process_time() - t)
    while time.process_time() < end:
        pass
    return got
PY
  base="$(sed -n 's/^one-lesson .*: \([0-9.]*\) (.*/\1/p' "$T/cost.log")"
  base="${base%%$'\n'*}"
  if [ -n "$base" ]; then
    over="$(awk -v b="$base" 'BEGIN { printf "%.1f", b * 1.25 }')"
    # On the step clock, as the slowed copy is measured for the suite line below: on CI's slowest
    # runners its 3.4 to 4.2 s became 10.3 s, the gate's own 11 seconds refused it first, and this
    # check failed for the runner's speed (run 44801153504, 2026-11-20, claude-config#3170).
    cost="$(SLACK_GATE_COST_LABEL=slow-reader SLACK_GATE_COST_ATTEMPTS=1 SLACK_GATE_CACHE_DIR="$(mktemp -d "$T/cold.XXXXXX")" HOOK_TESTS_RUNNING=1 SLACK_GATE_TICK_BUDGET=1000000000 python3 -B "$T/cost.py" "$slow/slack-drafts-only-gate.sh" "$CS" "$over" L174 2>&1)"
    case "$cost" in
      "judging it took"*) cost=ok ;;
      ok) cost="the slowed gate read as no dearer, so the yardstick moved with the gate: $(grep '^slow-reader' "$T/cost.log")" ;;
    esac
    check "a gate whose reader is eleven times as slow is measured as dearer, past $over against $base (#2918)" "$cost"
  else
    check "the one lesson cost check recorded its measurement in the cost log (#2918)" "$(cat "$T/cost.log" 2>&1)"
  fi
fi

# Since #2911 the gate reads every file the claude-sync suite sources, and judging
# `bash tests/test-claude-sync.sh` took 7.5 s of the 11 s budget at a load of 14, and ran out of it on
# a slow CI runner (PR #2917, 2026-11-13). Profiled, the time was work repeated per name, per local
# and per command over the same text, now done once (#2918). Held in units of the fixed yardstick, as
# above, so no load moves it: at 0.095 s a unit on the personal MacBook the 11 s budget is about 116
# units, and the limit of 67 is about 58 percent of it, which leaves a machine 1.7 times as slow per
# unit inside the budget. Measured on 2026-11-13 in readings of claude-sync: about 22 before #2918
# (21.5 to 24 under load), about 15 after; on 2026-11-15 in units: 44.8 to 45.7 at a load of 11.
#
# THE LIMIT IS 67 ON macOS AND 91 OFF IT (#3406, Dan's choice of 2026-11-23: "Top reading plus 15%
# (Recommended)"). Each is the highest reading that platform gave with the gate as it has been
# since #3486, times 1.15, to the nearest unit. macOS: 58.3, on the work MacBook (57.3 and 58.3 at
# a load of 2 to 4, 2026-11-23; the personal MacBook read 54.5 to 56.7 that day), so 67. Linux:
# 78.9, the highest of CI's three readings that day: 74.2 (run 45288689074), then 78.9 and, for
# the same commit run again, 73.3 (run 45295975472, both attempts), so 91. One machine moves about
# 7 percent between runs of the same code (those two), so each limit sits about two such moves
# above its highest reading. Read once more before the limits went in, on main at f8ae7710f9 and
# the pull requests of that evening: the personal MacBook 55.1 and 55.3 (two whole runs of this
# suite at a load of 34 to 181); Linux 74.8 for main's own tree (run 45308408783) and 63.8, 64.0,
# 65.2, 67.4 and 67.9 on five pull request runs (45302832678, 45311844748, 45303036287,
# 45305899804, 45311774478). So Linux read from about 64 to 79 on the same gate code: the
# yardstick does not cancel the runner's speed there, and across those nine runs the slower the
# runner, the lower the reading, from 78.9 at 0.078 s a unit to 63.8 at 0.162 s. The highest
# readings come from the fastest runners.
# What fails it: the least of three cold judgements past the limit, which is a gate about 15
# percent slower than the highest reading above, and about a fifth slower than the middle ones (56
# on the personal MacBook, 74 on Linux); the slowed gate check below shows one failing it (114 on
# the personal MacBook and 128 to 144 on Linux that evening). On a runner whose unit is past about
# 0.12 s, 91 units is more than the gate's own 11 s budget, so there a gate inside the limit can
# run out of its seconds first; cost.py then reads the line again on the step clock and holds
# those units to the same limit (#3170). Five of the six runners read that evening were that slow,
# and the judgement took 9.5 to 10.4 s of the 11 on each.
#
# BEFORE THAT: 57 and 77 (#3167, Dan's choice of 2026-11-17), each 1.41 times that day's reading,
# 40.3 on macOS (the mean of 15) and 54.3 on Linux (the middle of five passing runs). Work added to
# the gate since took the readings to within 2 percent of both (#3406: 55 to 56 on the personal
# MacBook, 77.7 to 81.4 on Linux), #3486 took 3 to 6 units back out, and what was left still crossed
# them from run to run on unchanged code: 57.3 and 58.3 on the work MacBook, 78.9 on Linux.
#
# WHERE EVERY SAMPLE RAN OUT OF THE GATE'S SECONDS, THE CASE IS UNMEASURED (#3406, Dan's decision of
# 2026-11-26, "3.60.1 Read it as unmeasured"). Over about 50 pull request runs on 2026-11-26 every red
# here began with a judgement that ran out of the gate's 11 seconds on the runner and was then read
# on the step clock; first judgements that finished inside them read 66.8 to 88.5 and none failed,
# with the gate's work the same count on every run. So cost.py, asked with SLACK_GATE_COST_RAN_OUT_UNMEASURED=1,
# answers unmeasured where all its samples were read on the step clock and the least is past the
# limit, and this suite prints that as a SUITE-PART-UNMEASURED line, as the cached twin below does.
# A sample that finished inside the seconds still fails it past the limit, and
# tools/ci-cold-cost-streak.sh turns main red when its last trees were all unmeasured here.
cold_ceiling="$(cost_limit suite-cold)"
# A cost case's answer from cost.py, counted: ok or a failure as every check is, and where cost.py
# answered unmeasured, a part this machine could not measure, in the one shape run-all-tests reads
# for that (L411, #3170, #3406, Dan's decisions of 2026-11-21, "Build it", and 2026-11-26). The line
# is printed on every run it happens in, under the suite's own line and in the run's summary, so a
# runner where this is unmeasured every time is seen as that, never as a pass (L557).
cost_case() {  # <the check's name> <cost.py's answer> [<the issue the line is filed under>]
  case "$2" in
    "unmeasured: "*) echo "SUITE-PART-UNMEASURED ${3:-#3170}: $1: ${2#unmeasured: }" ;;
    *) check "$1" "$2" ;;
  esac
}
if [ -n "$CS" ] && [ -n "$REPO" ] && [ -f "$REPO/tests/test-claude-sync.sh" ]; then
  warm="$(mktemp -d "$T/warm.XXXXXX")"
  cost="$(SLACK_GATE_COST_LABEL=suite-cold SLACK_GATE_COST_RAN_OUT_UNMEASURED=1 SLACK_GATE_PHASE_LOG="$T/phases.log" SLACK_GATE_CACHE_DIR="$warm" env -u SLACK_GATE_TICK_BUDGET -u HOOK_TESTS_RUNNING python3 -B "$T/cost.py" "$HOOK" "$CS" "$cold_ceiling" --line "bash $REPO/tests/test-claude-sync.sh" 2>&1)"
  # tools/ci-cold-cost-streak.sh finds this case's unmeasured line by its start, "#3406: bash
  # tests/test-claude-sync.sh is judged within", and its suite holds the two equal.
  cost_case "bash tests/test-claude-sync.sh is judged within $cold_ceiling units of the yardstick on $(uname -s) (#2918, #3167)" "$cost" "#3406"
  # The reading, on a passing run too (#3167). run-all-tests prints a suite's output only when it
  # fails, so until 2026-11-17 CI's log held this measurement only for runs past the ceiling, and the
  # runner's own distribution, the premise of the ceiling (L316), could not be read from any log. A
  # SUITE-NOTE is the one line the runner prints under a passing suite (#505). Composed from the cost
  # log by matching, so a change to that log's shape that matches nothing is a failure here rather
  # than a note that silently stops (L100).
  case "$cost" in
    "the line was refused"*) cold_note="refused it: ${cost:0:160}" ;;
    *) cold_note="$(sed -n 's/^suite-cold .*: \([0-9][0-9.]* (.*)\)$/at \1/p' "$T/cost.log" | sed -n 1p)" ;;
  esac
  if [ -n "$cold_note" ]; then
    cold_note_text="$(printf 'drafts gate on %s, bash tests/test-claude-sync.sh from an empty cache: %s (#3167)' "$(uname -s)" "$cold_note")"
    suite_note "$cold_note_text"
    cold_note=ok
  else
    cold_note="no suite-cold line in the cost log to print: $(cat "$T/cost.log" 2>&1)"
  fi
  check "the cold reading of bash tests/test-claude-sync.sh is printed for a passing run too (#3167)" "$cold_note"
  # Where that judgement's time went, phase by phase (#3170): the gate writes one line per judgement
  # to SLACK_GATE_PHASE_LOG, collected here for each cold judgement cost.py made and printed at the
  # end of this part, so a slow runner's log says which part of the gate grew. The warm judgement below names the same file, since the
  # variable is part of the cache's key, and is answered from the cache.
  cold_phases="$(grep -c '^phases: ' "$T/phases.log" 2>/dev/null || true)"
  if [ "${cold_phases:-0}" -ge 1 ] 2>/dev/null; then
    # Printed after the note with every cost reading, below: these are one line per cold judgement,
    # so more than one when the first was past its limit, and the note cap must drop them rather
    # than the readings (#3170).
    phase_notes="$(sed -n "s/^phases: /drafts gate phases on $(uname -s), bash tests\/test-claude-sync.sh cold (#3170): /p" "$T/phases.log")"
    cold_phases=ok
  else
    cold_phases="the gate wrote no phases line to SLACK_GATE_PHASE_LOG: $(cat "$T/phases.log" 2>&1)"
  fi
  check "the cold judgement of bash tests/test-claude-sync.sh says where its time went (#3170)" "$cold_phases"
  # The limit this platform got still fails on a real slowdown (#3167, L1): the copy of the gate whose
  # reader burns ten times its own time again, made above, judging the same line, once. It counts its
  # steps rather than seconds (SLACK_GATE_TICK_BUDGET under a test run), so the gate's own 11 s budget
  # cannot refuse it first and the units decide. Measured 2026-11-17: 95.6 units on the personal
  # MacBook against 41.0 for the gate itself.
  if [ -f "$T/slow-gate/slack-drafts-only-gate.sh" ]; then
    cost="$(SLACK_GATE_COST_LABEL=suite-slowed SLACK_GATE_COST_ATTEMPTS=1 SLACK_GATE_CACHE_DIR="$(mktemp -d "$T/cold.XXXXXX")" HOOK_TESTS_RUNNING=1 SLACK_GATE_TICK_BUDGET=1000000000 python3 -B "$T/cost.py" "$T/slow-gate/slack-drafts-only-gate.sh" "$CS" "$cold_ceiling" --line "bash $REPO/tests/test-claude-sync.sh" 2>&1)"
    case "$cost" in
      "judging it took"*) cost=ok ;;
      ok) cost="the slowed gate read within $cold_ceiling, so this limit passes a gate that slow: $(grep '^suite-slowed' "$T/cost.log")" ;;
    esac
    check "a gate whose reader is eleven times as slow is past the $cold_ceiling unit limit for bash tests/test-claude-sync.sh on $(uname -s) (#3167)" "$cost"
  else
    # With a claude-sync to judge the copy is always made above, so its absence is a fault, not a skip.
    check "a gate whose reader is eleven times as slow is past the $cold_ceiling unit limit for bash tests/test-claude-sync.sh on $(uname -s) (#3167)" "the slowed copy of the gate was not made at $T/slow-gate, so this limit was not seen to fail"
  fi
  # A cached case's answer goes through cost_case above: where the cache it was handed was never
  # filled, it is unmeasured.
  # Judged again with nothing changed, it is answered from the judgement cache: every file it read
  # and every disk test it answered is checked again, and nothing is walked.
  cost="$(SLACK_GATE_COST_LABEL=suite-warm SLACK_GATE_PHASE_LOG="$T/phases.log" SLACK_GATE_CACHE_DIR="$warm" env -u SLACK_GATE_TICK_BUDGET -u HOOK_TESTS_RUNNING python3 -B "$T/cost.py" "$HOOK" "$CS" 6 --line "bash $REPO/tests/test-claude-sync.sh" 2>&1)"
  cost_case "judged a second time, bash tests/test-claude-sync.sh takes at most 6 units of the yardstick, from the cache (#2918)" "$cost"
  # What a cached case answers, on doctored records in place of the gate (#3170, L1): cost.py's own
  # loop and verdict, replayed (SLACK_GATE_COST_REPLAY), so no gate runs and each takes a fraction of
  # a second. The first is run 44965167694's own record (2026-11-21, a Linux runner at 0.151 s a
  # unit): the cold judgement ran out after 10.4 s, and the cached case's samples read 52.0 units,
  # where the cache traced "miss: no entry | stored", and then 1.7 from the cache. It failed there,
  # and it is the state the case cannot set (L411), so it is unmeasured, with those figures. Every
  # other miss still fails, because a miss is what these cases exist to catch: the same samples with
  # no record that the filling judgement ran out (the entry should have been there), an entry that
  # was there and not used, a stale entry, and an entry stored by the first sample that the next did
  # not read back. The folder each is handed holds one kept parse and no judgement, which is what a
  # judgement that runs out late leaves (measured on the personal MacBook, 2026-11-21, with a copy
  # of the gate whose budget is 1 s); one that runs out early leaves the folder empty and the next
  # asking traces "miss: no signing key" (the same copy at 0.2 s), which is replayed too.
  replay_cached() {  # <ran-out|kept> <parse|empty> <the judgements, a JSON list>: cost.py's answer
    local d
    d="$(mktemp -d "$T/replay.XXXXXX")" && mkdir "$d/cache" || { echo "no folder to replay in"; return; }
    [ "$2" = empty ] || : > "$d/cache/parse-kept"
    [ "$1" = kept ] || printf 'cache\tsuite-cold\t10.4 s at 0.151 s a unit\n' > "$d/cost-cache-unfilled.log"
    printf '%s\n' "$3" > "$d/judgements.json"
    SLACK_GATE_COST_LABEL=replay SLACK_GATE_COST_LOG="$d/cost.log" SLACK_GATE_COST_REPLAY="$d/judgements.json" SLACK_GATE_CACHE_DIR="$d/cache" \
      env -u SLACK_GATE_TICK_BUDGET -u HOOK_TESTS_RUNNING python3 -B "$T/cost.py" "$HOOK" "$CS" 6 --line "bash tests/test-claude-sync.sh" 2>&1
    sed 's/^/logged: /' "$d/cost.log" 2>/dev/null
  }
  replayed() {  # <the check's name> <a pattern its answer must match> <the answer>
    # shellcheck disable=SC2254
    case "$3" in
      $2) check "$1" ok ;;
      *) check "$1" "cost.py answered: ${3:0:700}" ;;
    esac
  }
  rp_miss() { printf '{"units": 52.0, "said": ["qos: not raised: not macOS", "miss: %s", "stored"]}' "$1"; }
  rp_hit() { printf '{"units": %s, "said": ["qos: not raised: not macOS", "hit"]}' "$1"; }
  rp_fill="$(rp_miss "no entry")"
  rp_out='{"exit": 2, "stderr": "BLOCKED: slack-drafts-only-gate.sh ran out of time judging this call: it stopped after 11 seconds", "units": 70.2, "said": ["qos: not raised: not macOS", "miss: no entry"]}'
  replayed "replayed, a cached case answered from the cache at once is ok, so the replay can pass (#3170)" \
    "ok*" "$(replay_cached kept parse "[$(rp_hit 1.7)]")"
  replayed "a cached case whose cache was never filled, the judgement that fills it having run out of the gate's seconds, is unmeasured and says why with the figures (#3170)" \
    "unmeasured: the cache this case was handed was never filled*suite-cold*ran out of the gate's seconds*10.4 s at 0.151 s a unit*52.0 units*miss: no entry | stored*1.7 units*logged: replay *the cache was never filled*" \
    "$(replay_cached ran-out parse "[$rp_fill, $(rp_hit 1.7)]")"
  replayed "the same where the judgement that fills it ran out early and left the folder empty (#3170)" \
    "unmeasured: the cache this case was handed was never filled*miss: no signing key | stored*1.7 units*" \
    "$(replay_cached ran-out empty "[$(rp_miss "no signing key"), $(rp_hit 1.7)]")"
  replayed "and where this case's first judgement runs out of the gate's seconds as well, so nothing could be kept (#3170)" \
    "unmeasured: the cache this case was handed was never filled*10.4 s at 0.151 s a unit*This case's first judgement found nothing kept and ran out as well, after 70.2 s*miss: no entry*" \
    "$(replay_cached ran-out parse "[$rp_out]")"
  replayed "with no record that the filling judgement ran out, the same miss still fails: the entry should have been there (#3170)" \
    "1 of the 2 samples of this measurement from a filled cache were not answered from it*sample 1, 52.0 units*miss: no entry | stored*" \
    "$(replay_cached kept parse "[$rp_fill, $(rp_hit 1.7)]")"
  replayed "with no such record, a cached case refused for running out of time still fails (#3170)" \
    "the line was refused (exit 2)*" "$(replay_cached kept parse "[$rp_out]")"
  replayed "an entry that was there and not used still fails where the filling judgement ran out (#3170)" \
    "1 of the 2 samples of this measurement from a filled cache were not answered from it*the entry is not a whole allow for this key*" \
    "$(replay_cached ran-out parse "[$(rp_miss "the entry is not a whole allow for this key"), $(rp_hit 1.7)]")"
  replayed "a stale entry still fails where the filling judgement ran out (#3170)" \
    "1 of the 2 samples of this measurement from a filled cache were not answered from it*answers differently now*" \
    "$(replay_cached ran-out parse "[$(rp_miss "stat ['claude-sync'] answers differently now"), $(rp_hit 1.7)]")"
  replayed "an entry the first sample stored and the next did not read back still fails where the filling judgement ran out (#3170)" \
    "2 of the 3 samples of this measurement from a filled cache were not answered from it*sample 2, 52.0 units*sample 3, 52.0 units*" \
    "$(replay_cached ran-out parse "[$rp_fill, $rp_fill, $rp_fill]")"
  replayed "a cache the first sample filled that then answers past 6 units still fails where the filling judgement ran out (#3170)" \
    "judging it took*past 6*52.0, 8.1, 8.3*" \
    "$(replay_cached ran-out parse "[$rp_fill, $(rp_hit 8.1), $(rp_hit 8.3)]")"
  # The cold case's own verdict where the gate's seconds run out (#3406, L1), replayed the same way
  # at the Linux limit of 91, with SLACK_GATE_COST_RAN_OUT_UNMEASURED as the cold case sets it. A
  # record that ran out carries the processor seconds it had run; the step clock judgement after it
  # carries its units. The first is run 45838830923's own record (2026-11-26, pull request 3531):
  # every sample ran out (after 7.3, 11.5 and 11.6 s) and read 106.2, 93.4 and 91.4 on the step
  # clock. The second is run 45850402488's (the same day): only its first sample ran out, after 7.6
  # s, and samples 2 and 3 FINISHED inside the seconds at 92.4 and 92.0, so it still fails: a sample
  # that finished in time past the limit is the reading the limit is for. Then each other mix of a
  # sample that ran out and one that did not, and the same records without the setting, as every
  # other cost case is run, failing as before.
  replay_cold() {  # <1 or 0, the setting> <the judgements, a JSON list>: cost.py's answer and its log line
    local d
    d="$(mktemp -d "$T/replay.XXXXXX")" && mkdir "$d/cache" || { echo "no folder to replay in"; return; }
    printf '%s\n' "$2" > "$d/judgements.json"
    env -u SLACK_GATE_TICK_BUDGET -u HOOK_TESTS_RUNNING -u SLACK_GATE_COST_SAMPLES -u SLACK_GATE_COST_ATTEMPTS \
      SLACK_GATE_COST_RAN_OUT_UNMEASURED="$1" SLACK_GATE_COST_LABEL=replay-cold SLACK_GATE_COST_LOG="$d/cost.log" \
      SLACK_GATE_COST_REPLAY="$d/judgements.json" SLACK_GATE_CACHE_DIR="$d/cache" \
      python3 -B "$T/cost.py" "$HOOK" "$CS" 91 --line "bash tests/test-claude-sync.sh" 2>&1
    sed 's/^/logged: /' "$d/cost.log" 2>/dev/null
  }
  rc_out() { printf '{"exit": 2, "stderr": "BLOCKED: slack-drafts-only-gate.sh ran out of time judging this call: it stopped after 11 seconds", "units": %s, "said": ["qos: not raised: not macOS", "miss: no signing key"]}' "$1"; }
  rc_in() { printf '{"units": %s, "said": ["qos: not raised: not macOS", "miss: no signing key", "stored"]}' "$1"; }
  replayed "run 45838830923's cold record, every sample run out of the gate's seconds and past 91 on the step clock, is unmeasured and says why with the figures (#3406)" \
    "unmeasured: every judgement of this case ran out of the gate's seconds on this machine, after 7.3 s at 1.000 s a unit and 11.5 s at 1.000 s a unit and 11.6 s at 1.000 s a unit, so each was read on the step clock instead, at 106.2, 93.4, 91.4 units against the limit of 91.0*(#3406)*logged: replay-cold *: 91.4 (*the gate's 11 s ran out on this machine*" \
    "$(replay_cold 1 "[$(rc_out 7.3), $(rc_in 106.2), $(rc_out 11.5), $(rc_in 93.4), $(rc_out 11.6), $(rc_in 91.4)]")"
  replayed "run 45850402488's cold record, its first sample run out and samples 2 and 3 finished inside the seconds past 91, still fails (#3406)" \
    "judging it took at least*past 91.0, in each of 3 samples (93.1, 92.4, 92.0)*" \
    "$(replay_cold 1 "[$(rc_out 7.6), $(rc_in 93.1), $(rc_in 92.4), $(rc_in 92.0)]")"
  replayed "a cold case whose first sample finished inside the seconds past 91 and whose others ran out still fails (#3406)" \
    "judging it took at least*past 91.0, in each of 3 samples (93.0, 92.4, 92.0)*" \
    "$(replay_cold 1 "[$(rc_in 93.0), $(rc_out 7.0), $(rc_in 92.4), $(rc_out 7.0), $(rc_in 92.0)]")"
  replayed "a cold case whose middle sample finished inside the seconds past 91 still fails (#3406)" \
    "judging it took at least*past 91.0, in each of 3 samples (93.0, 95.0, 92.0)*" \
    "$(replay_cold 1 "[$(rc_out 7.0), $(rc_in 93.0), $(rc_in 95.0), $(rc_out 7.0), $(rc_in 92.0)]")"
  replayed "a cold case none of whose samples ran out still fails past 91 (#3406)" \
    "judging it took at least*past 91.0, in each of 3 samples (93.0, 94.0, 95.0)*" \
    "$(replay_cold 1 "[$(rc_in 93.0), $(rc_in 94.0), $(rc_in 95.0)]")"
  replayed "a cold case whose samples ran out passes where one reads at or under 91 on the step clock, as before (#3406)" \
    "ok*logged: replay-cold *: 88.0 (*samples 95.0, 88.0;*ran out on this machine*" \
    "$(replay_cold 1 "[$(rc_out 7.0), $(rc_in 95.0), $(rc_out 7.0), $(rc_in 88.0)]")"
  replayed "without the setting, as every other cost case runs, every sample run out and past 91 still fails (#3406)" \
    "judging it took at least*past 91.0, in each of 3 samples (106.2, 93.4, 91.4)*" \
    "$(replay_cold 0 "[$(rc_out 7.3), $(rc_in 106.2), $(rc_out 11.5), $(rc_in 93.4), $(rc_out 11.6), $(rc_in 91.4)]")"
  # cost_case turns that answer into the suite's unmeasured line, under #3406 and with the start
  # tools/ci-cold-cost-streak.sh finds it by, and never into a pass or a failure.
  cold_line="$(pass=0; fail=0; cost_case "bash tests/test-claude-sync.sh is judged within 91 units of the yardstick on Linux (#2918, #3167)" "unmeasured: every judgement of this case ran out" "#3406"; echo "counted $pass $fail")"
  case "$cold_line" in
    "SUITE-PART-UNMEASURED #3406: bash tests/test-claude-sync.sh is judged within 91 units of the yardstick on Linux (#2918, #3167): every judgement of this case ran out"$'\n'"counted 0 0") cold_line=ok ;;
    *) cold_line="cost_case printed: $cold_line" ;;
  esac
  check "an unmeasured cold answer is printed as one SUITE-PART-UNMEASURED #3406 line and counted as neither a pass nor a failure (#3406)" "$cold_line"
  # A machine too slow for the gate's budget, stood in for by a copy of the gate whose budget is a
  # fifth of a second, judging the one lesson line (#3170, L411): the seconds run out, cost.py reads
  # the same line on the step clock and holds those units to the ceiling it was given. So such a
  # machine neither fails a gate inside its ceiling nor passes one past it: with the one lesson
  # ceiling (cost_limit, 36 on macOS and 46 off it) it is inside, and with a ceiling of 1 unit,
  # which no gate meets, it must fail.
  short="$T/short-gate"
  mkdir -p "$short" && cp "$HOOK" "$short/" && cp -R "$DIR/lib" "$short/lib" \
    && sed 's/^BUDGET_SECONDS = 11$/BUDGET_SECONDS = 0.2/' "$DIR/slack_drafts_only_gate.py" > "$short/slack_drafts_only_gate.py"
  if grep -q '^BUDGET_SECONDS = 0\.2$' "$short/slack_drafts_only_gate.py" 2>/dev/null; then
    short_cold="$(mktemp -d "$T/cold.XXXXXX")"
    cost="$(SLACK_GATE_COST_LABEL=short-budget SLACK_GATE_COST_SAMPLES=3 SLACK_GATE_CACHE_DIR="$short_cold" env -u SLACK_GATE_TICK_BUDGET -u HOOK_TESTS_RUNNING python3 -B "$T/cost.py" "$short/slack-drafts-only-gate.sh" "$CS" "$(cost_limit short-budget)" L174 2>&1)"
    if [ "$cost" = ok ] && ! grep -q '^short-budget .*ran out on this machine' "$T/cost.log"; then
      cost="the copy with a budget of 0.2 s did not run out of it, so the step clock reading was never taken: $(grep '^short-budget' "$T/cost.log")"
    fi
    check "where the gate's seconds run out, its work is read on the step clock and held to the same $(cost_limit short-budget) units on $(uname -s) (#3170)" "$cost"
    # Judged from several readings, never one (L656, L395): on 2026-11-20 this check turned a pull
    # request's run red from a single reading, 42.6 units against 36 (run 44850974680, part 2), and
    # one reading of a duration cannot be told from noise. Every one of them is a reading where the
    # seconds ran out, taken on the step clock, or the samples are of some other work.
    sb_line="$(grep '^short-budget ' "$T/cost.log" | sed -n 1p)"
    sb_n="$(printf '%s\n' "$sb_line" | sed -n 's/.*, samples \([0-9][0-9., ]*\)[;)].*/\1/p' | tr ',' '\n' | grep -c . || true)"
    sb_out="$(printf '%s\n' "$sb_line" | grep -o ' s a unit' | grep -c . || true)"
    if [ "${sb_n:-0}" -ge 3 ] 2>/dev/null && [ "$sb_out" = "$sb_n" ]; then
      sb_n=ok
    else
      sb_n="judged from ${sb_n:-0} reading(s), ${sb_out:-0} of them where the seconds ran out: ${sb_line:-no short-budget line in the cost log}"
    fi
    check "where the gate's seconds run out, it is judged from at least 3 readings, each on the step clock (#3170)" "$sb_n"
    cost="$(SLACK_GATE_COST_LABEL=short-budget-over SLACK_GATE_COST_ATTEMPTS=1 SLACK_GATE_CACHE_DIR="$(mktemp -d "$T/cold.XXXXXX")" env -u SLACK_GATE_TICK_BUDGET -u HOOK_TESTS_RUNNING python3 -B "$T/cost.py" "$short/slack-drafts-only-gate.sh" "$CS" 1 L174 2>&1)"
    case "$cost" in
      "judging it took"*) cost=ok ;;
      ok) cost="a ceiling of 1 unit passed, so a gate whose seconds run out is held to nothing: $(grep '^short-budget-over' "$T/cost.log")" ;;
    esac
    check "where the gate's seconds run out, a gate past its ceiling still fails (#3170)" "$cost"
    # The never filled cache, made by this machine and not doctored (L48, L3): the first judgement
    # of the short-budget measurement above was made in $short_cold and ran out, so nothing is kept
    # there. Asked for the one lesson line in that folder as a cached case is, the gate itself must
    # be reported unmeasured: cost.py wrote down that the judgement ran out, read that back here, and
    # the cache's own trace for the first sample says it found nothing. Its record is kept out of the
    # cost log, in a log of its own, so the notes and the counts above hold the measurements only.
    cost="$(SLACK_GATE_COST_LABEL=unfilled-warm SLACK_GATE_COST_LOG="$T/cost-unfilled.log" SLACK_GATE_CACHE_DIR="$short_cold" env -u SLACK_GATE_TICK_BUDGET -u HOOK_TESTS_RUNNING python3 -B "$T/cost.py" "$HOOK" "$CS" 6 L174 2>&1)"
    case "$cost" in
      "unmeasured: the cache this case was handed was never filled"*"short-budget"*"ran out of the gate's seconds"*) cost=ok ;;
      *) cost="cost.py answered: ${cost:0:700}; the record of judgements that ran out: $(head -c 300 "$T/cost-cache-unfilled.log" 2>&1)" ;;
    esac
    check "a cached case in the folder where a real judgement ran out of the gate's seconds is unmeasured, from the record that judgement left (#3170)" "$cost"
  else
    check "a copy of the gate with a budget of 0.2 s is made, for a machine too slow for the budget (#3170)" "slack_drafts_only_gate.py has no line 'BUDGET_SECONDS = 11' to change, so $short holds the gate's own budget"
  fi
  # The command that starts this suite (#3255). On 2026-11-20 the installed gate ran out of its 11
  # seconds on it on the personal MacBook, so this suite could not be started from a session: the
  # suite runs the gate's own source as a program some sixty times, and each run read it afresh.
  # Measured that day, the two gates back to back with a unit at 0.095 s: 63.6 to 66.1 units before
  # and 18.7 to 19.0 after (5 samples each; earlier that afternoon, with a unit at 0.15 to 0.17 s, the
  # gate before read 58.9 to 68.6, which is 10.2 to 10.7 of its 11 seconds). The limit is 1.41 times
  # the middle reading after, 18.9, rounded up, as the limit for the claude-sync suite is set (this
  # suite with the checks of #3255 in it read 19.2 to 19.6, 3 samples), and the copy of
  # the gate that holds no reading (made in the harness, the gate as it was) must be past it, on the step
  # clock so its seconds cannot run out first. Off macOS the limit is wider by the 77 to 57 the
  # claude-sync suite's limits were then (#3167; they are 91 and 67 since #3406, and 27 times 91
  # over 67 is 36.7, the same 37): no Linux reading of this line existed when it was set, so each
  # run prints its reading below, and the limit is set again from those. This suite's own text is
  # what is judged, so the reading grows as the suite does (L323): a limit crossed by growth alone
  # is raised with the readings that show it, never by guessing.
  # Set again on 2026-11-24, when #3575 cut this suite to a quarter of its 6,561 lines and so moved
  # both readings the 27 was set between (L220): measured on the work MacBook, one run after another
  # at 1 minute load averages of 1.9 to 22, the command that starts this suite read 8.1, 8.1, 8.2,
  # 8.5, 8.7, 8.8 and 9.4 units (each the least of 3 samples; the highest sample 9.6), and the gate
  # that holds no reading 28.7, 29.3, 29.5, 30.9, 31.0, 32.0 and 33.4. The macOS limit is now near
  # the geometric midpoint of the highest of the first and the lowest of the second, the square root
  # of 9.6 times 28.7, 16.6, rounded to 17, which leaves 1.77 times of room above the one and 1.69
  # below the other. Off macOS the limit is set from Linux readings too, no longer from the macOS
  # one by the 91 over 67 above, which would give 24 and leave the gate that holds no reading too
  # close: the first CI run of this suite as it now is (run 45543054872, 2026-11-24) read 7.9 for the
  # first (samples 8.0, 8.1, 7.9) and 30.4 for the second, close to macOS, and that run's check
  # failed at the old 37, as it should. Before the cut two Linux runs read 24.3 and 35.0 for the
  # first and 80.5 and 95.5 for the second (runs 45447561839 and 45468757442), a wider spread than
  # macOS shows; cut by what the split cut macOS (8.2 over 24.1), that spread is about 8 to 12 and
  # 27 to 33. The Linux limit is 18, the geometric midpoint of 12 and 27: 2.2 times of room above
  # the 8.1 read and 1.69 below the 30.4, and 1.5 each way against that estimated spread. One
  # Linux run is thin, so each run still prints its readings, and the limit is set again from them.
  own_ceiling="$(cost_limit own-suite)"
  several="$several own-suite"
  # Only the first of the three cold judgements is made in this folder, empty until then, and it is
  # the one the warm check below asks for again. cost.py gives each later sample an empty folder of
  # its own, and fails the measurement when the cache says it answered any sample, so none of the
  # three readings held to the limit is a reading of the cache. Measured 2026-11-21 on the personal
  # MacBook: 20.0, 20.4 and 20.0 units, and then 1.9 for the warm check.
  own_warm="$(mktemp -d "$T/warm.XXXXXX")"
  cost="$(SLACK_GATE_COST_LABEL=own-suite SLACK_GATE_COST_SAMPLES=3 SLACK_GATE_CACHE_DIR="$own_warm" env -u SLACK_GATE_TICK_BUDGET -u HOOK_TESTS_RUNNING python3 -B "$T/cost.py" "$HOOK" "$CS" "$own_ceiling" --line "bash $DIR/test-slack-drafts-only-gate.sh" 2>&1)"
  check "the command that starts this suite is judged within $own_ceiling units of the yardstick on $(uname -s) (#3255)" "$cost"
  # Judged a second time with nothing changed, it is answered from the judgement cache, as the
  # claude-sync suite's command is above and inside the same 6 units (#3255). Until 2026-11-21 it
  # never was: the first of the three cold judgements above, the one made in this cache, was not
  # kept (the judgement cache part, in test-slack-drafts-only-gate-tools-cache.sh, says why), so
  # every asking cost the whole judgement.
  # Measured that day on the personal MacBook with a unit at 0.097 s, one cache for every reading:
  # 19.4 to 20.1 units each time before (5 readings), and 20.2 then 1.8, 1.8, 1.8, 1.8 after.
  cost="$(SLACK_GATE_COST_LABEL=own-suite-warm SLACK_GATE_CACHE_DIR="$own_warm" env -u SLACK_GATE_TICK_BUDGET -u HOOK_TESTS_RUNNING python3 -B "$T/cost.py" "$HOOK" "$CS" 6 --line "bash $DIR/test-slack-drafts-only-gate.sh" 2>&1)"
  cost_case "judged a second time, the command that starts this suite takes at most 6 units of the yardstick, from the cache (#3255)" "$cost"
  # Its readings are printed with every other cost case's, in the one note at the end of this part
  # (#3170), which took the place of a note of its own when the note cap was full.
  if [ -f "$unheld_made/slack-drafts-only-gate.sh" ]; then
    cost="$(SLACK_GATE_COST_LABEL=own-suite-unheld SLACK_GATE_COST_ATTEMPTS=1 SLACK_GATE_CACHE_DIR="$(mktemp -d "$T/cold.XXXXXX")" HOOK_TESTS_RUNNING=1 SLACK_GATE_TICK_BUDGET=1000000000 python3 -B "$T/cost.py" "$unheld_made/slack-drafts-only-gate.sh" "$CS" "$own_ceiling" --line "bash $DIR/test-slack-drafts-only-gate.sh" 2>&1)"
    case "$cost" in
      "judging it took"*) cost=ok ;;
      ok) cost="the gate that holds no reading read within $own_ceiling, so this limit passes the gate as it was before #3255: $(grep '^own-suite-unheld' "$T/cost.log")" ;;
    esac
    check "a gate that holds no reading is past the $own_ceiling unit limit for the command that starts this suite on $(uname -s) (#3255)" "$cost"
  else
    check "a gate that holds no reading is past the $own_ceiling unit limit for the command that starts this suite on $(uname -s) (#3255)" "the copy that holds no reading was not made at $unheld_made, so this limit was not seen to fail"
  fi
else
  # L411: installed in ~/.claude there is no checkout, so no suite to judge.
  echo "SUITE-PART-UNMEASURED #2918: no claude-config checkout with tests/test-claude-sync.sh beside this suite, so the time to judge it was not measured"
fi
if [ -f "$T/cost.log" ]; then
  sed 's/^/cost measured (#2918): /' "$T/cost.log"
  # The one lesson case (36 units on macOS, 46 off it) and the command that starts this suite (17
  # on macOS, 18 off it) take several readings whether or not the first passes (#3170), so one run's
  # log gives the spread a limit is placed from, not a lone reading (L172). The fallback case, held
  # to the one lesson limit, takes them
  # too and is checked above, where it also has to show each reading was taken on the step clock.
  for lbl in $several; do
    l="$(grep "^$lbl " "$T/cost.log" | sed -n 1p)"
    n="$(printf '%s\n' "$l" | sed -n 's/.*, samples \([0-9][0-9., ]*\)[;)].*/\1/p' | tr ',' '\n' | grep -c . || true)"
    if [ "${n:-0}" -ge 3 ] 2>/dev/null; then n=ok; else n="${n:-0} reading(s): ${l:-no $lbl line in the cost log}"; fi
    check "the $lbl cost case takes at least 3 readings, whether or not the first passes (#3170)" "$n"
  done
  # Every reading, on a passing run too (#3170). run-all-tests prints only a passing suite's
  # SUITE-NOTE lines, at most SUITE_NOTE_MAX of them (3, #505), and the claude-sync suite's reading
  # and its phases already take two. So the rest go in one line, each case's least reading and then
  # every sample, and the line's entries are counted against the log's, so a change to the log's
  # shape that matches nothing fails here rather than printing a shorter note (L100). The 42.6 that
  # failed on 2026-11-20 was the first Linux reading of this kind anybody saw.
  # Since 2026-11-21 each entry is the case, its least reading and the whole record in brackets, the
  # printed only figures with it (each reading's seconds, the unit it was divided by, every yardstick
  # sample and their spread, #3170), so a passing CI run's log holds them for every case, not only
  # suite-cold. Entries are separated by " | ", since the record itself holds "; ".
  cost_read="$(grep -v '^suite-cold ' "$T/cost.log" | sed -E -n 's/^([a-z-]+) .*: ([0-9][0-9.]*) \((.*; seconds per reading .*)\)$/\1 \2 (\3)/p')"
  cost_want="$(grep -v -c '^suite-cold ' "$T/cost.log" || true)"
  cost_got="$(printf '%s\n' "$cost_read" | grep -c . || true)"
  notes_before="$notes_n"
  if [ -n "$cost_read" ] && [ "$cost_got" = "$cost_want" ]; then
    cost_note="$(printf 'drafts gate costs on %s, every case but suite-cold, in units of the yardstick and how each was read: %s (#3170)' \
      "$(uname -s)" "$(printf '%s\n' "$cost_read" | paste -s -d '|' - | sed 's/|/ | /g')")"
    suite_note "$cost_note"
    cost_read=ok
  else
    cost_read="${cost_got:-0} of the cost log's ${cost_want:-0} lines matched, so they were not printed: $(cat "$T/cost.log")"
  fi
  check "every cost reading is printed in one note for a passing run too (#3170)" "$cost_read"
  # The reader the next pass uses must find every case in the notes a passing run shows, the
  # suite-cold note included, each with its seconds and its yardstick (#3170).
  if [ -n "$REPO" ] && [ -f "$REPO/tools/gate-cost-rows.py" ]; then
    printf '          note: %s\n' "${cold_note_text:-}" "${cost_note:-}" > "$T/notes.txt"
    rows="$(python3 -B "$REPO/tools/gate-cost-rows.py" rows "$T/notes.txt" 2>&1)"
    rows_want="$(grep -c . "$T/cost.log" || true)"
    rows_got="$(printf '%s\n' "$rows" | awk -F'\t' 'NR > 1 && NF == 14 && $6 != "-" && $8 != "-" && $9 != "-"' | grep -c . || true)"
    [ "$rows_got" = "$rows_want" ] && rows=ok || rows="the reader found ${rows_got:-0} cases with seconds and yardstick in the notes, of the cost log's ${rows_want:-0}: $rows"
    check "tools/gate-cost-rows.py reads every case's seconds and yardstick from the notes a passing run shows (#3170)" "$rows"
    # The verdict never reads a printed only figure (#3170): every reading must be its seconds over
    # the least yardstick sample taken by then, and the judged reading the least of them, so a
    # verdict taken from a median, a greatest or any other figure printed beside it fails here.
    held="$(python3 -B "$REPO/tools/gate-cost-rows.py" check "$T/cost.log" 2>&1)"
    check "every cost case is judged by its least reading, each its seconds over the least yardstick sample taken by then, never a figure printed beside it (#3170)" "$held"
    # And that check is seen to fail on this run's own one lesson record, its last reading divided
    # by the greatest yardstick sample instead (L1).
    python3 -B - "$T/cost.log" > "$T/cost-doctored.log" 2>&1 <<'PY'
import re, sys
line = next(l for l in open(sys.argv[1]) if l.startswith("one-lesson "))
greatest = re.search(r"greatest ([0-9.]+)\)", line).group(1)
per = re.search(r"yardstick per reading (.*?); yardstick [0-9]+ samples", line).group(1).split(", ")
if per[-1].split(" ")[0] == greatest:
    sys.exit("every yardstick sample was the same, so the greatest cannot stand in for the least")
per[-1] = re.sub(r"^[0-9.]+", greatest, per[-1])
print(re.sub(r"yardstick per reading .*?; yardstick ([0-9]+) samples", lambda m: "yardstick per reading %s; yardstick %s samples" % (", ".join(per), m.group(1)), line).rstrip("\n"))
PY
    doctored="$(python3 -B "$REPO/tools/gate-cost-rows.py" check "$T/cost-doctored.log" 2>&1)"
    if ! grep -q '^one-lesson ' "$T/cost-doctored.log"; then
      echo "SUITE-PART-UNMEASURED #3170: the one lesson record could not be doctored ($(head -c 200 "$T/cost-doctored.log")), so the check of printed only figures was not seen to fail"
    else
      case "$doctored" in
        *"was divided by"*"but the least of the first"*) doctored=ok ;;
        *) doctored="a reading divided by the greatest yardstick sample passed: $doctored" ;;
      esac
      check "a reading divided by a printed only figure, the greatest yardstick sample, fails that check (#3170)" "$doctored"
    fi
  else
    echo "SUITE-PART-UNMEASURED #3170: no tools/gate-cost-rows.py in a checkout beside this suite, so the printed only cost figures were not checked against the verdicts"
  fi
  note_max="$(sed -n 's/^SUITE_NOTE_MAX="\${SUITE_NOTE_MAX:-\([0-9][0-9]*\)}"$/\1/p' "$DIR/run-all-tests.sh" 2>/dev/null | sed -n 1p)"
  if [ -z "$note_max" ]; then
    notes_before="run-all-tests.sh beside this suite has no line SUITE_NOTE_MAX=\"\${SUITE_NOTE_MAX:-<n>}\" to read the cap from, so whether the readings are shown is unknown"
  elif [ "$notes_before" -lt "$note_max" ]; then
    notes_before=ok
  else
    notes_before="$notes_before note(s) came before it and run-all-tests shows $note_max, so a passing run's log drops the readings"
  fi
  check "the note with every cost reading is among the notes a passing run shows (#3170)" "$notes_before"
fi
if [ -n "$phase_notes" ]; then
  while IFS= read -r ph; do
    suite_note "$ph"
  done <<< "$phase_notes"
fi
unset SLACK_GATE_COST_LOG

echo
sdg_harness_result
