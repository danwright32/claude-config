#!/usr/bin/env bash
# Sleep mode phase 2 (claude-config#841): nothing pages Dan while the Mac is asleep, found by a test.
#
# The routes that can reach Dan are DERIVED here, never listed by hand (L96): every settings hook on
# an event that fires when a turn or agent ends or Claude Code wants Dan, every place a mod sends a
# notification, plays a sound or asks him a question, every classic Stop, Notification or
# PermissionRequest hook a mod registers, and claude-sync's `notify`. Each must consult the one sleep
# predicate (lib/sleep.sh's sleep_active for the shell, readSleep through scope modes' sleepNow, isAsleep or
# hold for a mod) or sit on the exempt list below with its reason (L129). A route found by neither
# fails, and so does an exempt entry with no reason or one naming a route that no longer exists.
#
# What "consults" means is a text match, which proves the predicate is named where it should be,
# never that it is obeyed (L135, L400). So every shell route is also RUN here against an asleep
# record and an awake one in the same fixture (L159), and the mods' own suites run theirs: goal
# tracker, ask before saving and scope modes each hold a test of what they do while asleep. For a
# mod the match is judged within the block that holds the route (the function or the `on(` hook),
# not anywhere in its file, so a mention elsewhere cannot answer for it.
#
# A route asking Dan through Claude (a Stop hook whose instruction leads to a picker) is backstopped
# by scope modes refusing AskUserQuestion while asleep, which the mod's own suite proves.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
. "$ROOT/payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

PAYLOAD="$ROOT/payload"
HOOKS="$PAYLOAD/hooks"
SETTINGS="$PAYLOAD/settings.hooks.json"
MODS="$PAYLOAD/mods"
SYNC="$ROOT/claude-sync"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-sleep-silence.XXXXXX")"
case "${WORK%/}" in
  ''|/|"${HOME%/}")
    echo "FAIL: $(basename "$0"): refusing to run: the throwaway directory came back as '$WORK'."
    printf 'SUITE-RESULT passed=0 failed=1\n'
    exit 1 ;;
esac
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

# ---- the exempt list: a route that does not consult the predicate, and why it need not ----
# One per line: the route as the enumeration below names it, a tab, the reason.
EXEMPT="$WORK/exempt.tsv"
cat > "$EXEMPT" <<'EOF'
settings:SubagentStop:subagent-issue-harvest.sh	Runs async and only writes a finishing agent's findings to the issue spool; it never prints to Dan, and the spool waits for the morning.
settings:TeammateIdle:teammate-challenge-gate.sh	Talks to an agent team's teammate before it goes idle, never to Dan.
mod:scope-modes/hooks/register.ts:notify:notifier	The sleep mode notification itself: endIfOver sends it only once the record no longer holds (past noon ET or another boot), the one page L523 calls for when a mute ends by itself.
mod:scope-modes/hooks/register.ts:classic.Stop	Blocks only to keep Claude finishing winding down; a question that leads to is refused while asleep by this mod's AskUserQuestion refusal.
mod:manual-steps/hooks/register.tsx:classic.Stop	Sends Claude back to pin a steps card, and a card pinned while asleep is held by scope modes' hold, which reads the sleep record.
mod:goal-tracker/hooks/register.tsx:classic.PermissionRequest	Reaches Dan only through notify, which consults the predicate (its own route below).
mod:goal-tracker/hooks/register.tsx:classic.Notification	Reaches Dan only through notify, which consults the predicate (its own route below).
mod:scope-modes/hooks/register.ts:askOne:ask	The before bed questions, about a repository on neither merge and deploy list (#843) and the open questions on the queue's issues (#836): asked only inside /sleep, while Dan is at the prompt that typed it and before the sleep record exists, so the Mac is not asleep yet.
mod:keystroke-guard/hooks/register.ts:headsUp:ask	Asked only after holdWhileAway, which holds the action through scope modes' hold while asleep, so the question is never reached then.
EOF

# ---- 1. the routes, derived ----
ROUTES="$WORK/routes.tsv"   # route <TAB> consults (yes/no) <TAB> where
python3 - "$SETTINGS" "$HOOKS" "$MODS" "$SYNC" > "$ROUTES" <<'PY'
import json, os, re, sys

settings, hooks, mods, sync = sys.argv[1:5]

# Settings: every hook on an event that fires at a turn's or agent's end, or when Claude Code wants Dan.
EVENTS = ("Stop", "SubagentStop", "StopFailure", "Notification", "PermissionRequest", "PermissionDenied", "TeammateIdle")
d = json.load(open(settings))["hooks"]
for ev in EVENTS:
    for group in d.get(ev) or []:
        for h in group.get("hooks") or []:
            c = h.get("command", "")
            m = re.search(r"/hooks/([^\s\"]+)", c)
            if not m:
                # A bare command runs nothing of ours, so it cannot read the record.
                print("settings:%s:external:%s\tno\t%s" % (ev, c.split()[0] if c.split() else "", c))
                continue
            path = os.path.join(hooks, m.group(1))
            text = open(path).read() if os.path.isfile(path) else ""
            print("settings:%s:%s\t%s\t%s" % (ev, m.group(1), "yes" if "sleep_active" in text else "no", path))

# Mods: each block (a top level declaration, or a hook registered with on() inside register) that
# sends a notification, plays a sound, asks Dan, or is a classic hook on a turn end or a wait on Dan.
SENDS = [
    ("notifier", re.compile(r"""['"](?:terminal-notifier)['"]""")),
    ("sound", re.compile(r"""['"](?:afplay|say)['"]""")),
    ("ask", re.compile(r"\bui\.ask\(")),
]
CLASSIC = re.compile(r"""\bon\(\s*['"](classic\.(?:Stop|SubagentStop|StopFailure|Notification|PermissionRequest|PermissionDenied|TeammateIdle))['"]""")
CONSULTS = re.compile(r"\bisAsleep\b|\bsleepNow\(|\.scopeModes\.hold\(")
START = re.compile(r"^(?:export\s+)?(?:const|let|function|async\s+function)\s+(\w+)|^  on\(\s*['\"]([^'\"]+)['\"]")
for name in sorted(os.listdir(mods)):
    hdir = os.path.join(mods, name, "hooks")
    if not os.path.isdir(hdir):
        continue
    for root, dirs, files in os.walk(hdir):
        for f in sorted(files):
            if not re.search(r"\.tsx?$", f):
                continue
            path = os.path.join(root, f)
            rel = os.path.relpath(path, mods)
            lines = open(path).read().split("\n")
            starts = [(i, (m.group(1) or m.group(2))) for i, l in enumerate(lines) for m in [START.match(l)] if m]
            for k, (i, label) in enumerate(starts):
                end = starts[k + 1][0] if k + 1 < len(starts) else len(lines)
                body = "\n".join(lines[i:end])
                # Comments are not code: a route named in a comment is not a route.
                code = "\n".join(re.sub(r"^\s*(//|\*|/\*).*$", "", l) for l in lines[i:end])
                consults = "yes" if CONSULTS.search(code) else "no"
                c = CLASSIC.search(code)
                if c:
                    print("mod:%s:%s\t%s\t%s:%d" % (rel, c.group(1), consults, path, i + 1))
                for kind, rx in SENDS:
                    if rx.search(code):
                        print("mod:%s:%s:%s\t%s\t%s:%d" % (rel, label, kind, consults, path, i + 1))

# claude-sync's notify, the desktop alert the sync daemon raises.
if os.path.isfile(sync):
    text = open(sync).read()
    m = re.search(r"^notify\(\)\s*\{\n(.*?)^\}", text, re.S | re.M)
    body = m.group(1) if m else ""
    print("sync:notify\t%s\t%s" % ("yes" if "sleep_active" in body else "no", sync if m else "notify() not found"))
PY
rc=$?
[ "$rc" -eq 0 ] && check "the routes were enumerated" ok || check "the routes were enumerated" "the enumeration failed, exit $rc"

count() { grep -c "^$1" "$ROUTES" 2>/dev/null || true; }
# Each kind found at least once: a derivation that silently found nothing would pass everything (L98).
for kind in settings:Stop: mod: sync:notify; do
  n="$(count "$kind")"
  [ "${n:-0}" -gt 0 ] && check "the enumeration finds $kind routes ($n)" ok || check "the enumeration finds $kind routes" "found none, so nothing below judged them"
done
grep -q $'^mod:goal-tracker/hooks/register.tsx:notify:notifier\t' "$ROUTES" \
  && check "the goal tracker's notify is found as a route" ok \
  || check "the goal tracker's notify is found as a route" "not found; routes: $(cut -f1 "$ROUTES" | tr '\n' ' ')"

while IFS=$'\t' read -r route consults where; do
  [ -n "$route" ] || continue
  reason="$(awk -F'\t' -v r="$route" '$1 == r { print $2 }' "$EXEMPT")"
  if [ "$consults" = yes ]; then
    check "$route consults the sleep predicate" ok
  elif [ -n "$reason" ]; then
    check "$route is exempt with a reason" ok
  else
    check "$route consults the sleep predicate or is exempt with a reason" "it does neither ($where)"
  fi
done < "$ROUTES"

# Every exempt entry names a route that exists, and gives a reason with words in it.
cut -f1 "$ROUTES" > "$WORK/route-names"
while IFS=$'\t' read -r route reason; do
  [ -n "$route" ] || continue
  grep -qxF "$route" "$WORK/route-names" && check "exempt $route is still a route" ok \
    || check "exempt $route is still a route" "no such route now: remove it from the list"
  case "$reason" in *[A-Za-z]*[A-Za-z]*) check "exempt $route gives a reason" ok ;; *) check "exempt $route gives a reason" "none" ;; esac
done < "$EXEMPT"

# ---- 2. the shell routes, run asleep and awake ----
BOOT="$(sysctl -n kern.boottime 2>/dev/null | python3 -c 'import re, sys; m = re.search(r"\bsec\s*=\s*(\d+)", sys.stdin.read()); print(m.group(1) if m else "")')"
[ -n "$BOOT" ] || BOOT=1   # no sysctl (Linux CI): sleep.sh skips the boot check, so any boot will do
NOW_MS="$(( $(date +%s) * 1000 ))"
STUBS="$WORK/stubs"; mkdir -p "$STUBS"
for c in afplay terminal-notifier; do
  printf '#!/bin/sh\nprintf "%%s %%s\\n" %s "$*" >> "$STUB_LOG"\n' "$c" > "$STUBS/$c"
  chmod +x "$STUBS/$c"
done

world() {   # world <name> <asleep|awake> -> sets H (a home of its own) and STUB_LOG
  H="$WORK/$1-$2/home"
  mkdir -p "$H/.claude/state/sleep" "$WORK/$1-$2/tmp"
  export STUB_LOG="$WORK/$1-$2/stub.log"; : > "$STUB_LOG"
  if [ "$2" = asleep ]; then
    printf '{"v":1,"generation":"g-test","since":%s,"until":%s,"night":"2026-10-07","bootTime":%s,"report":"%s/r.md","startedBy":{"sessionId":"s0","cwd":"/"},"workers":[],"placeBefore":"home"}\n' \
      "$((NOW_MS - 60000))" "$((NOW_MS + 3600000))" "$BOOT" "$H" > "$H/.claude/state/sleep/current.json"
  fi
}
transcript() {   # a turn that did real work, so the end of turn hooks take their full path
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"do the thing"}}' \
    '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","id":"t1","input":{}}]}}' \
    '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}' \
    '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}' > "$1"
}
run_route() {   # run_route <script> <event> -> stdout of the hook, run in the current world
  local t="$WORK/t.$RANDOM.jsonl"; transcript "$t"
  local proj; proj="$(mktemp -d "$WORK/proj.XXXXXX")"
  printf '{"session_id":"s1","transcript_path":"%s","cwd":"%s","hook_event_name":"%s","stop_hook_active":false}' "$t" "$proj" "$2" \
    | env HOME="$H" CLAUDE_HOME="$H/.claude" TMPDIR="$WORK/tmp" CLAUDE_PROJECT_DIR="$proj" PATH="$STUBS:$PATH" \
        STOP_HOOK_NOTICE_DIR="$WORK/notices" bash "$HOOKS/$1" 2>/dev/null
}

mkdir -p "$WORK/tmp"
while IFS=$'\t' read -r route consults where; do
  case "$route" in settings:*) ;; *) continue ;; esac
  [ "$consults" = yes ] || continue
  ev="${route#settings:}"; ev="${ev%%:*}"
  script="${route#settings:*:}"
  world "$script" awake; out="$(run_route "$script" "$ev")"
  if [ -n "$out" ] || [ -s "$STUB_LOG" ]; then check "$script on $ev reaches Dan while awake (the control)" ok
  else check "$script on $ev reaches Dan while awake (the control)" "it did nothing awake either, so the silence below proves nothing"; fi
  world "$script" asleep; out="$(run_route "$script" "$ev")"
  [ -z "$out" ] && [ ! -s "$STUB_LOG" ] && check "$script on $ev is silent while asleep" ok \
    || check "$script on $ev is silent while asleep" "printed '${out:0:200}', ran: $(cat "$STUB_LOG")"
done < "$ROUTES"

# A record that cannot be read counts as awake: the sound still plays.
world unreadable awake; printf 'not json' > "$H/.claude/state/sleep/current.json"
run_route turn-end-sound.sh Stop >/dev/null
grep -q '^afplay ' "$STUB_LOG" && check "an unreadable sleep record reads as awake, so the turn end sound plays" ok \
  || check "an unreadable sleep record reads as awake, so the turn end sound plays" "afplay was not run"

# ---- 3. the hooks that ask Dan for something right after a tool call stand down while asleep ----
# The lesson fan out: a lesson not fanned out yet is asked for, awake; asleep it waits, unstamped.
fanout() {
  mkdir -p "$H/.claude/state"
  printf -- '- **L1. one\n- **L2. two\n' > "$H/.claude/LESSONS.md"
  printf 'L1 baseline\n' > "$H/.claude/state/lesson-fanout.done"
  printf '{}' | env HOME="$H" CLAUDE_HOME="$H/.claude" LESSON_FANOUT_NOW=1000000 bash "$HOOKS/lesson-fanout-notice.sh" 2>/dev/null
}
world fanout awake; out="$(fanout)"
case "$out" in *'"decision"'*L2*) check "the lesson fan out asks for a new lesson while awake (the control)" ok ;;
  *) check "the lesson fan out asks for a new lesson while awake (the control)" "got '${out:0:200}'" ;; esac
world fanout asleep; out="$(fanout)"
[ -z "$out" ] && check "the lesson fan out stands down while asleep" ok || check "the lesson fan out stands down while asleep" "got '${out:0:200}'"
[ ! -e "$H/.claude/state/lesson-fanout-notice.stamp" ] && check "and spends no cooldown, so the morning still asks" ok \
  || check "and spends no cooldown, so the morning still asks" "the cooldown stamp was written"

# The PR quiz: a merge is quizzed while awake, and not while asleep.
quiz() {
  printf '{"session_id":"s1","cwd":"%s","tool_name":"Bash","tool_input":{"command":"gh pr merge 12 --squash"},"tool_response":{"stdout":"merged"}}' "$WORK" \
    | env HOME="$H" CLAUDE_HOME="$H/.claude" CLAUDE_QUIZ_VERDICT_DIR="$H/verdicts" PATH="$STUBS:$PATH" bash "$HOOKS/pr-merge-quiz.sh" 2>/dev/null
}
# gh is stubbed to know nothing, so the quiz cannot read a label that would silence it.
printf '#!/bin/sh\nexit 1\n' > "$STUBS/gh"; chmod +x "$STUBS/gh"
world quiz awake; out="$(quiz)"
[ -n "$out" ] && check "a merge is quizzed while awake (the control)" ok || check "a merge is quizzed while awake (the control)" "no quiz"
world quiz asleep; out="$(quiz)"
[ -z "$out" ] && check "the merge quiz stands down while asleep" ok || check "the merge quiz stands down while asleep" "got '${out:0:200}'"
rm -f "$STUBS/gh"

# ---- 4. claude-sync's notify: logged instead of shown while asleep ----
sync_notify() {   # an unknown command dies, and a death off a terminal notifies
  env HOME="$H" CLAUDE_HOME="$H/.claude" SYNC_NOTIFIER="$STUBS/terminal-notifier" SYNC_NO_LAUNCHCTL=1 \
    SYNC_LOG_FILE="$H/sync.log" bash "$SYNC" no-such-command-841 >/dev/null 2>&1
}
world sync awake; sync_notify
grep -q 'no-such-command-841' "$STUB_LOG" && check "claude-sync notifies while awake (the control)" ok \
  || check "claude-sync notifies while awake (the control)" "nothing was sent: $(cat "$STUB_LOG")"
world sync asleep; sync_notify
[ ! -s "$STUB_LOG" ] && check "claude-sync sends no notification while asleep" ok \
  || check "claude-sync sends no notification while asleep" "sent: $(cat "$STUB_LOG")"
grep -q 'not shown, Dan is asleep: .*no-such-command-841' "$H/sync.log" 2>/dev/null \
  && check "and writes what it would have said to its log instead" ok \
  || check "and writes what it would have said to its log instead" "log: $(cat "$H/sync.log" 2>/dev/null)"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
