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
# A route that consulted the predicate cannot vanish unnoticed either: the ones that consult are
# also kept on a recorded list, CONSULTING below, held both ways against the derivation (#3411).
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
# This suite is ABOUT where the sleep record is found, through HOME, so it sets aside the record
# the test runner, and arming the deadline, hand every other suite through CLAUDE_SLEEP_RECORD
# (lib/sleep.sh). After arming, which would otherwise hand it one again (claude-config#1729).
unset CLAUDE_SLEEP_RECORD

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
settings:PermissionDenied:payload-write-gate.sh	Only removes the write gate's own note for the call auto mode refused, and prints nothing: no notification, sound or question, and not one byte to stdout or stderr, asleep or awake, which section 2b below runs it to prove. Dan signed this entry off on 2026-11-19, asked "This hook only deletes its own note and prints nothing. Sign off an exempt entry for it?" and answering "Sign off the entry" (claude-config#3253). It covers that and nothing wider: a hook on this event that comes to say or decide anything needs the predicate.
mod:scope-modes/hooks/register.ts:notify:notifier	The sleep mode notification itself: by endIfOver once the record no longer holds (past noon ET or another boot), the one page L523 calls for when a mute ends by itself; by /sleep when it refuses to start (#1545), before any record is written; and, the one page while asleep, by powerMinute once when the Mac goes onto battery and once when it comes back, which Dan asked for in #1545 so a pulled charger does not silently lose the night.
mod:scope-modes/hooks/register.ts:classic.Stop	Blocks only to keep Claude finishing winding down; a question that leads to is refused while asleep by this mod's AskUserQuestion refusal.
mod:manual-steps/hooks/register.tsx:classic.Stop	Sends Claude back to pin a steps card, and a card pinned while asleep is held by scope modes' hold, which reads the sleep record.
mod:is-it-live/hooks/register.ts:classic.Stop	Sends Claude back to make the is it live card for a merge (#1244), which is kept, toasted and drawn as a result row, never a notification, sound or question; it refuses once per merge in a chain of turn ends, so it never holds a sleeping worker, and the card is there for /live in the morning.
mod:manual-steps/hooks/register.tsx:tellDan:noun	Reaches Dan only through the goal tracker's notify, which consults the predicate (its own route below); a card pinned while asleep is held by scope modes' hold before this is reached, which scope modes' own suite holds against the real sleep record.
mod:goal-tracker/hooks/register.tsx:classic.PermissionRequest	Reaches Dan only through notify, which consults the predicate (its own route below).
mod:goal-tracker/hooks/register.tsx:classic.Notification	Reaches Dan only through notify, which consults the predicate (its own route below).
mod:scope-modes/hooks/register.ts:askOne:ask	The before bed questions, about a repository on neither merge and deploy list (#843) and the open questions on the queue's issues (#836): asked only inside /sleep, while Dan is at the prompt that typed it and before the sleep record exists, so the Mac is not asleep yet.
mod:job-watcher/hooks/register.ts:classic.SubagentStop	Refuses a dispatched agent's stop with an instruction to that agent alone (#1326); what it says past the bound goes to this conversation's next tool result, read by Claude, never a notification, sound or question to Dan.
mod:job-watcher/hooks/register.ts:classic.PermissionRequest	Answers a subagent's permission prompt for a git command reading /dev/stdin with a denial to that agent alone (#1765), and passes every other prompt on unchanged; it writes only to the debug log, never a notification, sound or question to Dan, and never allows anything, so a prompt it passes on reaches scope modes' overnight answer beneath as before.
mod:keystroke-guard/hooks/register.ts:headsUp:ask	Asked only after holdWhileAway, which holds the action through scope modes' hold while asleep, so the question is never reached then.
EOF

# ---- the recorded list: every route that consults the predicate (#3411) ----
# Held both ways against the enumeration below: a route found consulting that is not listed fails,
# and so does a listed route no longer found, or found but no longer consulting. So a refactor that
# renames, removes or folds a checked route into a helper fails by name until this list changes in
# the same pull request, where a reviewer sees where the check went. This is not the exempt list.
# To rewrite it from the tree after such a change, paste in what this prints:
#   bash tests/test-sleep-silence.sh --list-consulting
CONSULTING="$WORK/consulting.txt"
cat > "$CONSULTING" <<'EOF'
settings:Stop:turn-end-sound.sh
settings:Stop:check-later-nudge.sh
settings:Stop:feature-issue-review.sh
settings:Stop:session-reflection.sh
settings:Stop:pr-merge-quiz.sh
settings:SubagentStop:limit-messages.py
settings:StopFailure:limit-messages.py
mod:goal-tracker/hooks/register.tsx:notify:notifier
mod:scope-modes/hooks/register.ts:leavePrOpen:ask
mod:scope-modes/hooks/register.ts:leaveBranch:ask
mod:scope-modes/hooks/register.ts:openCleanupBranch:ask
mod:scope-modes/hooks/register.ts:tool.call:ask
mod:scope-modes/hooks/register.ts:classic.PermissionRequest
mod:scope-modes/hooks/register.ts:classic.PermissionDenied
mod:scope-modes/hooks/register.ts:classic.StopFailure
sync:notify
EOF

# ---- 1. the routes, derived ----
ROUTES="$WORK/routes.tsv"   # route <TAB> consults (yes/no) <TAB> where <TAB> arguments (settings routes)
enumerate_routes() {   # enumerate_routes <settings json> <hooks dir> <mods dir> <claude-sync> -> one route per line
python3 - "$@" <<'PY'
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
            # The arguments it is registered with, so section 2 runs it as Claude Code does: one
            # script can be two routes (pr-merge-quiz.sh is a PostToolUse hook, and with
            # --release-held a Stop one, #1768).
            print("settings:%s:%s\t%s\t%s\t%s" % (ev, m.group(1), "yes" if "sleep_active" in text else "no", path, c[m.end():].strip()))

# Mods: each block (a top level declaration, or a hook registered with on() inside register) that
# sends a notification, plays a sound, asks Dan, or is a classic hook on a turn end or a wait on Dan.
SENDS = [
    ("notifier", re.compile(r"""['"](?:terminal-notifier)['"]""")),
    ("sound", re.compile(r"""['"](?:afplay|say)['"]""")),
    ("ask", re.compile(r"\bui\.ask\(")),
    # Another mod's noun that pages Dan for it (#1245): the goal tracker's notifier, asked by name.
    ("noun", re.compile(r"\bgoalTracker\.waitingOnYou\(")),
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
}
enumerate_routes "$SETTINGS" "$HOOKS" "$MODS" "$SYNC" > "$ROUTES"
rc=$?
# `bash tests/test-sleep-silence.sh --list-consulting` prints the routes this tree finds consulting
# the predicate, in the order CONSULTING keeps them, and runs no check.
if [ "${1:-}" = --list-consulting ]; then
  awk -F'\t' '$2 == "yes" { print $1 }' "$ROUTES"
  exit "$rc"
fi
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
grep -q $'^mod:manual-steps/hooks/register.tsx:tellDan:noun\t' "$ROUTES" \
  && check "manual steps asking the goal tracker to notify is found as a route (#1245)" ok \
  || check "manual steps asking the goal tracker to notify is found as a route (#1245)" "not found; routes: $(cut -f1 "$ROUTES" | tr '\n' ' ')"

judge_routes() {   # judge_routes <routes> <exempt> <consulting> -> per check, "ok<TAB>check" or "FAIL<TAB>check<TAB>why"
  local routes="$1" exempt="$2" consulting="$3" route consults where reason found
  while IFS=$'\t' read -r route consults where _; do
    [ -n "$route" ] || continue
    reason="$(awk -F'\t' -v r="$route" '$1 == r { print $2 }' "$exempt")"
    if [ "$consults" = yes ]; then
      printf 'ok\t%s consults the sleep predicate\n' "$route"
      if grep -qxF "$route" "$consulting"; then printf 'ok\t%s is on the recorded list of routes that consult\n' "$route"
      else printf 'FAIL\t%s is on the recorded list of routes that consult\tit consults the predicate but is not listed: add it to CONSULTING in the same change\n' "$route"; fi
    elif [ -n "$reason" ]; then
      printf 'ok\t%s is exempt with a reason\n' "$route"
    else
      printf 'FAIL\t%s consults the sleep predicate or is exempt with a reason\tit does neither (%s)\n' "$route" "$where"
    fi
  done < "$routes"

  # Every recorded route is still found, and still consults: one that vanished, was renamed, was
  # folded into a helper or stopped consulting fails by name until the list says where it went.
  while IFS= read -r route; do
    [ -n "$route" ] || continue
    found="$(awk -F'\t' -v r="$route" '$1 == r { print $2; exit }' "$routes")"
    case "$found" in
      yes) printf 'ok\trecorded %s is still found consulting the predicate\n' "$route" ;;
      no) printf 'FAIL\trecorded %s is still found consulting the predicate\tit is found but no longer consults the sleep predicate\n' "$route" ;;
      *) printf 'FAIL\trecorded %s is still found consulting the predicate\tno such route now: a route that consulted the sleep predicate is gone, so find where its check went and update CONSULTING in the same change\n' "$route" ;;
    esac
  done < "$consulting"

  # Every exempt entry names a route that exists, and gives a reason with words in it.
  while IFS=$'\t' read -r route reason; do
    [ -n "$route" ] || continue
    if awk -F'\t' -v r="$route" '$1 == r { f = 1 } END { exit !f }' "$routes"; then printf 'ok\texempt %s is still a route\n' "$route"
    else printf 'FAIL\texempt %s is still a route\tno such route now: remove it from the list\n' "$route"; fi
    case "$reason" in
      *[A-Za-z]*[A-Za-z]*) printf 'ok\texempt %s gives a reason\n' "$route" ;;
      *) printf 'FAIL\texempt %s gives a reason\tnone\n' "$route" ;;
    esac
  done < "$exempt"
}
judge_routes "$ROUTES" "$EXEMPT" "$CONSULTING" > "$WORK/judged"
while IFS=$'\t' read -r verdict name why; do
  if [ "$verdict" = ok ]; then check "$name" ok; else check "$name" "${why:-no reason given}"; fi
done < "$WORK/judged"

# ---- 1b. a route that consulted the predicate cannot vanish unnoticed (#3411) ----
# The judge above is held to fixture trees of one mod, so each case is its own small tree and the
# real one is never edited. A route that consulted the predicate and is no longer found must fail by
# name, whether it was deleted, renamed or folded into a helper (#3407 folded five into one), unless
# the same change updates the recorded list, where a reviewer sees it.
fixture_routes() {   # fixture_routes <name> -> enumerates the tree at $WORK/fixture-<name>, whose mod source is on stdin
  local t="$WORK/fixture-$1"
  mkdir -p "$t/hooks" "$t/mods/fixmod/hooks"
  printf '{"hooks":{}}\n' > "$t/settings.json"
  cat > "$t/mods/fixmod/hooks/register.ts"
  enumerate_routes "$t/settings.json" "$t/hooks" "$t/mods" "$t/no-claude-sync" > "$t/routes.tsv"
}
judge_fixture() {   # judge_fixture <name> <exempt lines> <consulting lines> -> the judge's FAIL lines for that tree
  local t="$WORK/fixture-$1"
  printf '%s\n' "$2" > "$t/exempt.tsv"
  printf '%s\n' "$3" > "$t/consulting.txt"
  judge_routes "$t/routes.tsv" "$t/exempt.tsv" "$t/consulting.txt" | grep '^FAIL' || true
}
FX="mod:fixmod/hooks/register.ts"
FX_LIST="$FX:pageDan:notifier
$FX:askDan:ask
"

fixture_routes both <<'TS'
export function pageDan() {
  if (isAsleep()) return
  run('terminal-notifier', [])
}
export function askDan(ui) {
  if (isAsleep()) return
  ui.ask('Merge it?')
}
TS
[ "$(grep -c $'\tyes\t' "$WORK/fixture-both/routes.tsv")" = 2 ] \
  && check "the fixture tree's two routes are found consulting the predicate (the control)" ok \
  || check "the fixture tree's two routes are found consulting the predicate (the control)" "found: $(cat "$WORK/fixture-both/routes.tsv")"
out="$(judge_fixture both "" "$FX_LIST")"
[ -z "$out" ] && check "a tree matching its recorded list passes (the control)" ok \
  || check "a tree matching its recorded list passes (the control)" "$out"

fixture_routes gone <<'TS'
export function pageDan() {
  if (isAsleep()) return
  run('terminal-notifier', [])
}
TS
out="$(judge_fixture gone "" "$FX_LIST")"
case "$out" in
  *"$FX:askDan:ask"*) check "a route that consulted the predicate and is gone fails by name" ok ;;
  *) check "a route that consulted the predicate and is gone fails by name" "the judge said: ${out:-nothing}" ;;
esac

fixture_routes renamed <<'TS'
export function pageDan() {
  if (isAsleep()) return
  run('terminal-notifier', [])
}
export function askDanNow(ui) {
  if (isAsleep()) return
  ui.ask('Merge it?')
}
TS
out="$(judge_fixture renamed "" "$FX:pageDan:notifier
$FX:askDanNow:ask
")"
[ -z "$out" ] && check "a renamed route passes when the same change updates the recorded list" ok \
  || check "a renamed route passes when the same change updates the recorded list" "$out"
out="$(judge_fixture renamed "" "$FX_LIST")"
case "$out" in
  *"$FX:askDan:ask"*"$FX:askDanNow:ask"*|*"$FX:askDanNow:ask"*"$FX:askDan:ask"*)
    check "a renamed route with the list left alone fails, naming the old route and the new" ok ;;
  *) check "a renamed route with the list left alone fails, naming the old route and the new" "the judge said: ${out:-nothing}" ;;
esac

# The near miss #3407 showed: a recorded route still found but no longer consulting, and moved
# under an exemption, which the exempt list alone would accept.
fixture_routes unchecked <<'TS'
export function pageDan() {
  if (isAsleep()) return
  run('terminal-notifier', [])
}
export function askDan(ui) {
  ui.ask('Merge it?')
}
TS
out="$(judge_fixture unchecked "$FX:askDan:ask"$'\t'"Asked only before bed." "$FX_LIST")"
case "$out" in
  *"$FX:askDan:ask"*) check "a recorded route that stops consulting fails by name, even when exempt" ok ;;
  *) check "a recorded route that stops consulting fails by name, even when exempt" "the judge said: ${out:-nothing}" ;;
esac

# The exempt list keeps its own check through the move into judge_routes: an entry naming a route
# that is not found fails by name.
out="$(judge_fixture both "$FX:askDanLater:ask"$'\t'"Asked only before bed." "$FX_LIST")"
case "$out" in
  *"exempt $FX:askDanLater:ask is still a route"*) check "an exempt entry naming a route that is not found fails by name" ok ;;
  *) check "an exempt entry naming a route that is not found fails by name" "the judge said: ${out:-nothing}" ;;
esac

# ---- 2. the shell routes, run asleep and awake ----
# This boot by sleep.sh's sleep_boot_of, the one shell rule, held to the mod's BOOT_FIXTURES and to
# the mod's own reading of the live sysctl by test-sleep-state.sh.
BOOT="$(bash -c '. "$1" && sleep_boot_of "$(sysctl -n kern.boottime 2>/dev/null)"' _ "$HOOKS/lib/sleep.sh")"
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
    "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"${RUN_LAST_TEXT:-done}\"}]}}" > "$1"
}
run_route() {   # run_route <script> <event> [arguments...] -> stdout of the hook, run in the current world
  local t="$WORK/t.$RANDOM.jsonl"; transcript "$t"
  local proj; proj="$(mktemp -d "$WORK/proj.XXXXXX")"
  local script="$1" ev="$2"; shift 2
  # Run as the hook's command line runs it: python3 for a .py route (limit-messages.py), bash otherwise.
  local interp=bash; case "$script" in *.py) interp=python3 ;; esac
  # A route that speaks to Dan only on stderr (seed_route sets RUN_STDERR) is judged on stderr too.
  local errs=/dev/null; [ -n "${RUN_STDERR:-}" ] && errs="$WORK/stderr.$RANDOM"
  printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","hook_event_name":"%s","stop_hook_active":false%s}' "${RUN_SESSION:-s1}" "$t" "$proj" "$ev" "${RUN_EXTRA:-}" \
    | env HOME="$H" CLAUDE_HOME="$H/.claude" TMPDIR="$WORK/tmp" CLAUDE_PROJECT_DIR="$proj" PATH="$H/bin:$STUBS:$PATH" \
        STOP_HOOK_NOTICE_DIR="$WORK/notices" "$interp" "$HOOKS/$script" "$@" 2>"$errs"
  [ "$errs" = /dev/null ] || cat "$errs"
}
# A route that speaks only about state it holds is given that state in each world, so its awake
# control has something to say. Anything a route needs on PATH goes in "$H/bin", the world's own.
seed_route() {   # seed_route <script> <arguments>
  RUN_SESSION=""
  RUN_LAST_TEXT=""
  RUN_EXTRA=""
  RUN_STDERR=""
  case "$1 $2" in
    "limit-messages.py record")
      # It speaks only when it fails (#3308), on stderr, so each world is given a record it cannot
      # write (a file where its folder goes) and a usage limit to record, which StopFailure needs.
      mkdir -p "$H/.claude/state"; printf 'a file where the folder goes\n' > "$H/.claude/state/limit-messages"
      RUN_EXTRA=',"error":"rate_limit","last_assistant_message":"You have hit your 5-hour limit"'
      RUN_STDERR=1
      ;;
    "check-later-nudge.sh ")
      # A turn that promises to look again on a later day (#2079), the thing it speaks about.
      RUN_LAST_TEXT="I'll check again tomorrow."
      ;;
    "pr-merge-quiz.sh --release-held")
      # A merge held while it ran in the background (#1768), which GitHub now says merged.
      RUN_SESSION="sleep-silence-held-1"
      mkdir -p "$H/bin" "$H/.claude-quiz-verdicts/held"
      printf '#!/bin/sh\ncase "$*" in *"pr view"*) printf %s ;; esac\n' \
        "'{\"number\":12,\"url\":\"https://github.com/acme/widget/pull/12\",\"state\":\"MERGED\",\"mergedAt\":\"2026-10-26T19:43:00Z\",\"labels\":[]}'" > "$H/bin/gh"
      chmod +x "$H/bin/gh"
      jq -nc --arg dir "$H" --arg sid "$RUN_SESSION" --argjson at "$(date +%s)" \
        '{heldAt: $at, merges: [{dir: $dir, repo: "", slug: "", pr: "12"}],
          payload: {session_id: $sid, cwd: $dir, tool_name: "Bash", tool_input: {command: "gh pr merge 12 --squash"}}}' \
        > "$H/.claude-quiz-verdicts/held/$RUN_SESSION"
      ;;
  esac
}

mkdir -p "$WORK/tmp"
while IFS=$'\t' read -r route consults where args; do
  case "$route" in settings:*) ;; *) continue ;; esac
  [ "$consults" = yes ] || continue
  ev="${route#settings:}"; ev="${ev%%:*}"
  script="${route#settings:*:}"
  # shellcheck disable=SC2086 # the registered arguments, split as the hook's command line splits them
  world "$script" awake; seed_route "$script" "$args"; out="$(run_route "$script" "$ev" $args)"
  if [ -n "$out" ] || [ -s "$STUB_LOG" ]; then check "$script on $ev reaches Dan while awake (the control)" ok
  else check "$script on $ev reaches Dan while awake (the control)" "it did nothing awake either, so the silence below proves nothing"; fi
  # shellcheck disable=SC2086
  world "$script" asleep; seed_route "$script" "$args"; out="$(run_route "$script" "$ev" $args)"
  [ -z "$out" ] && [ ! -s "$STUB_LOG" ] && check "$script on $ev is silent while asleep" ok \
    || check "$script on $ev is silent while asleep" "printed '${out:0:200}', ran: $(cat "$STUB_LOG")"
done < "$ROUTES"
RUN_EXTRA=""; RUN_STDERR=""   # what one route was seeded with is never carried into the runs below

# A record that cannot be read counts as awake: the sound still plays.
world unreadable awake; printf 'not json' > "$H/.claude/state/sleep/current.json"
run_route turn-end-sound.sh Stop >/dev/null
grep -q '^afplay ' "$STUB_LOG" && check "an unreadable sleep record reads as awake, so the turn end sound plays" ok \
  || check "an unreadable sleep record reads as awake, so the turn end sound plays" "afplay was not run"

# ---- 2b. the exempt route whose reason is that it prints nothing is run, asleep and awake ----
# settings:PermissionDenied:payload-write-gate.sh sits on the exempt list because it only removes the
# write gate's own note for a refused call and prints nothing (claude-config#3253; Dan, 2026-11-19).
# A reason is a claim about what a hook does, and the list alone would go on believing it after the
# hook changed (L129, L400). So the route is run here against an asleep record and an awake one and
# held to the claim in both: exit 0, not one byte on stdout or stderr, nothing run that reaches Dan,
# the note named for the refused call gone and another call's note still there. The notes here are
# empty files under the names the gate gives its own; hooks/test-payload-write-gate.sh holds the same
# with notes the gate took itself.
DENIED_ROUTE="settings:PermissionDenied:payload-write-gate.sh"
grep -q "^$DENIED_ROUTE"$'\t' "$ROUTES" && check "the write gate on PermissionDenied is found as a route" ok \
  || check "the write gate on PermissionDenied is found as a route" "not found, so the runs below judge a hook nothing registers"
asleep_now() { env HOME="$H" bash -c ". \"$HOOKS/lib/sleep.sh\" && sleep_active" >/dev/null 2>&1; }
for state in awake asleep; do
  world denied "$state"
  if asleep_now; then seen=asleep; else seen=awake; fi
  [ "$seen" = "$state" ] && check "the $state world reads as $state to the sleep predicate (the control)" ok \
    || check "the $state world reads as $state to the sleep predicate (the control)" "it reads as $seen, so the run below is not a run while $state"
  NOTES="$H/gate-notes"; mkdir -p "$NOTES"
  : > "$NOTES/toolu_refused.roots"; : > "$NOTES/toolu_refused.list"; : > "$NOTES/toolu_other.roots"
  printf '{"session_id":"s1","cwd":"%s","permission_mode":"auto","hook_event_name":"PermissionDenied","tool_name":"Bash","tool_input":{"command":"true"},"tool_use_id":"toolu_refused","reason":"refused by auto mode"}' "$WORK" \
    | env HOME="$H" CLAUDE_HOME="$H/.claude" TMPDIR="$WORK/tmp" PATH="$STUBS:$PATH" PAYLOAD_WRITE_STATE_DIR="$NOTES" \
        bash "$HOOKS/payload-write-gate.sh" > "$H/denied.out" 2> "$H/denied.err"
  denied_rc=$?
  [ "$denied_rc" -eq 0 ] && check "the write gate on PermissionDenied exits 0 while $state" ok \
    || check "the write gate on PermissionDenied exits 0 while $state" "exit $denied_rc"
  [ ! -s "$H/denied.out" ] && check "and writes nothing to stdout while $state" ok \
    || check "and writes nothing to stdout while $state" "it wrote '$(head -c 200 "$H/denied.out")'"
  [ ! -s "$H/denied.err" ] && check "and nothing to stderr while $state" ok \
    || check "and nothing to stderr while $state" "it wrote '$(head -c 200 "$H/denied.err")'"
  [ ! -s "$STUB_LOG" ] && check "and runs no notifier or sound while $state" ok \
    || check "and runs no notifier or sound while $state" "ran: $(cat "$STUB_LOG")"
  left="$(find "$NOTES" -type f | sed 's|.*/||' | LC_ALL=C sort | tr '\n' ' ')"
  [ "$left" = "toolu_other.roots " ] && check "and removes the refused call's note and no other while $state" ok \
    || check "and removes the refused call's note and no other while $state" "its notes folder holds: ${left:-nothing}"
done

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
