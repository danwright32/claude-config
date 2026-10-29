#!/usr/bin/env bash
#
# time-push-gates.sh: time every gate a `git push` waits on (claude-config#523).
#
# Four hooks gate a push here, declaring timeouts of 30, 120, 180 and 300 seconds, and only one of
# them had ever been measured. A declared timeout is evidence of what somebody FEARED a gate might
# cost, never of what it costs, so the real price of pushing was a sum of guesses, and a gate's own
# guards are an untimed pipeline until somebody times them (L300).
#
# It drives each PreToolUse hook registered for Bash with the payload Claude Code sends for a
# `git push`, all of them at once, as Claude Code runs them (claude-config#1122), and reports each
# one's time and exit code in the order the settings list them, then the wall clock until the last
# one finished, which is what a push waits through.
#
# Usage: time-push-gates.sh [--repo DIR] [--command "git push"] [--list]
#   --list             name the gates, one per line as "<declared timeout>\t<hook>", and run none of
#                      them: the reading the README's count of push gates is tested against
#                      (claude-config#1066), so the count and the timing come from one list.
#   GATE_TIMING_HOME   where settings.json and hooks/ live (default: ~/.claude), so a test can
#                      drive a fixture rather than the installed config.
#
# Each gate is bounded by the timeout the settings declare for it, killed at that bound and
# REPORTED as killed rather than as a duration: a run that hit its ceiling is not a measurement of
# what it costs (L11). A gate with no declared timeout is shown as "-" and bounded by the
# platform's own default, 60 seconds, which is written down here as the assumption it is.
#
# It runs the REAL gates against a REAL repository, so it costs what a push costs, model call and
# containers included, and anything a gate writes (a record, a state file) is written, except the
# push gate ledger, pointed at a throwaway below.
set -uo pipefail

DEFAULT_TIMEOUT=60
repo="$PWD"
command_line="git push"
list_only=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) repo="${2:-}"; shift 2 ;;
    --command) command_line="${2:-}"; shift 2 ;;
    --list) list_only=1; shift ;;
    *) printf 'time-push-gates: "%s" is not an argument this takes (--repo DIR, --command CMD, --list).\n' "$1" >&2; exit 2 ;;
  esac
done

home="${GATE_TIMING_HOME:-$HOME/.claude}"
settings="$home/settings.json"
if [ ! -f "$settings" ]; then
  printf 'time-push-gates: could not read %s, so there is no list of gates to time. Refusing rather than reporting an empty table, which would read as a push that waits on nothing.\n' "$settings" >&2
  exit 1
fi

# The gates, in order, as <timeout><tab><command>. Read with python because the settings are JSON
# and a hook may carry an `if` clause that decides whether it runs for this command at all.
gates="$(SETTINGS="$settings" HOME_DIR="$home" CMD="$command_line" python3 - <<'PY'
import json, os, re, sys
try:
    d = json.load(open(os.environ["SETTINGS"]))
except Exception as e:
    print("ERROR\t%s: %s" % (type(e).__name__, e)); sys.exit(0)
cmd = os.environ["CMD"]
for group in (d.get("hooks", {}) or {}).get("PreToolUse", []) or []:
    matcher = group.get("matcher", "")
    if not matcher or not re.search(r"(^|\|)Bash($|\|)", matcher):
        continue
    for h in group.get("hooks", []) or []:
        path = (h.get("command") or "").replace("__CLAUDE_HOME__", os.environ["HOME_DIR"])
        if not path:
            continue
        cond = h.get("if") or ""
        if cond:
            # Bash(git *) style clauses, any of which may match.
            pats = [c.strip() for c in cond.split("|")]
            globs = [re.escape(p[5:-1]).replace(r"\*", ".*") for p in pats if p.startswith("Bash(") and p.endswith(")")]
            if globs and not any(re.match(g + r"$", cmd) for g in globs):
                continue
        # "-" rather than an empty field for a hook with no declared timeout: a tab is IFS
        # whitespace, so read in the shell below collapses a leading empty field and the gate
        # would vanish from the table entirely (claude-config#523, measured on rtk-rewrite.sh).
        print("%s\t%s" % (h.get("timeout", "") or "-", path))
PY
)"
case "$gates" in
  ERROR*) printf 'time-push-gates: could not read %s (%s).\n' "$settings" "${gates#ERROR	}" >&2; exit 1 ;;
esac
if [ -z "$gates" ]; then
  printf 'time-push-gates: %s lists no PreToolUse hook for Bash, so nothing was timed. Refusing rather than reporting a push that waits on nothing.\n' "$settings" >&2
  exit 1
fi
if [ -n "$list_only" ]; then
  while IFS="$(printf '\t')" read -r declared hook; do
    [ -n "$hook" ] && printf '%s\t%s\n' "$declared" "${hook##*/}"
  done <<EOF
$gates
EOF
  exit 0
fi

payload="$(REPO="$repo" CMD="$command_line" python3 -c '
import json, os, sys
sys.stdout.write(json.dumps({"tool_name": "Bash", "tool_input": {"command": os.environ["CMD"]}, "cwd": os.environ["REPO"]}))')"

work="$(mktemp -d "${TMPDIR:-/tmp}/time-push-gates.XXXXXXXX")" || exit 1
trap 'rm -rf "$work"' EXIT
# Except the push gate ledger (claude-config#1075): a timing run is not a push, and counting it
# there would put pushes nobody made into the record the gates' accuracy is judged from.
export PUSH_GATE_LEDGER_DIR="${PUSH_GATE_LEDGER_DIR:-$work/push-gates}"

# Every gate is started at once and waited on together, because that is how Claude Code runs them:
# "All matching hooks run in parallel" (the hooks reference). This ran them one after another and
# summed the times, so the table described a push nobody makes: what a push waits through is the
# SLOWEST gate, and each gate is slower than it is alone because the others share the machine with
# it (claude-config#1122).
#
# Each gate is started, timed and waited on by a small python runner of its own (claude-config#1870).
# This took every start and end with a python3 start of its own and noticed a gate had finished by
# polling every 0.2 seconds, so it printed tenths of a second while measuring to about 0.2: a gate
# that costs 7 ms read 0.1 and one that costs 125 ms read 0.4 (measured 2026-10-28). The runner reads its clock in the
# process that starts the gate, so its own start costs nothing that is measured, and it waits on the
# gate with a blocking wait, so the end is read the moment the gate exits. A timer, not a poll, kills
# a gate at its declared bound. Bash's EPOCHREALTIME would be a cheaper clock, but the bash on this
# Mac is 3.2, which has none, so it is not used.
KILL_TREE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../payload/hooks/lib" 2>/dev/null && pwd)/kill-tree.sh"
RUN_GATE='
import os, subprocess, sys, threading, time
hook, bound, outdir, kill_tree = sys.argv[1], float(sys.argv[2]), sys.argv[3], sys.argv[4]
data = sys.stdin.buffer.read()
killed = []
def kill(p):
    killed.append(1)
    try:
        subprocess.run(["bash", kill_tree, str(p.pid)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
    except Exception:
        pass
    try:
        p.kill()
    except Exception:
        pass
with open(os.path.join(outdir, "out"), "wb") as out:
    began_at = time.time(); began = time.monotonic()
    p = subprocess.Popen(["bash", hook], stdin=subprocess.PIPE, stdout=out, stderr=subprocess.STDOUT)
    timer = threading.Timer(bound, kill, (p,)); timer.daemon = True; timer.start()
    try:
        p.communicate(data)
    except Exception:
        p.wait()
    took = time.monotonic() - began
    timer.cancel()
with open(os.path.join(outdir, "result"), "w") as f:
    f.write("%d %.6f %.6f %.6f %s\n" % (p.returncode, took, began_at, began_at + took, "killed" if killed else "-"))
'
names=(); decls=(); bounds=(); pids=()
n=0
while IFS="$(printf '\t')" read -r declared hook; do
  [ -n "$hook" ] || continue
  bound="$declared"
  case "$bound" in ''|*[!0-9]*) bound="$DEFAULT_TIMEOUT" ;; esac
  names[n]="${hook##*/}"; decls[n]="$declared"; bounds[n]="$bound"
  mkdir -p "$work/$n"
  ( cd "$repo" 2>/dev/null || exit 0; printf '%s' "$payload" | python3 -c "$RUN_GATE" "$hook" "$bound" "$work/$n" "$KILL_TREE" ) &
  pids[n]=$!
  n=$((n + 1))
done <<EOF
$gates
EOF
j=0
while [ "$j" -lt "$n" ]; do wait "${pids[j]}" 2>/dev/null; j=$((j + 1)); done

# Milliseconds, because that is what the runner measures to; a gate costing a few of them is common.
printf 'seconds  exit  declared  gate\n'
first=""; last=""; sum=0; unread=0
j=0
while [ "$j" -lt "$n" ]; do
  result="$(cat "$work/$j/result" 2>/dev/null)"
  if [ -z "$result" ]; then
    # A runner that left no result is said to have done so, never shown as a duration (L11, L98).
    printf '%7s  %4s  %8s  %s (NOT MEASURED: its runner left no result, so there is no reading)\n' "-" "-" "${decls[j]}" "${names[j]}"
    unread=$((unread + 1)); j=$((j + 1)); continue
  fi
  read -r rc took began ended how <<EOF
$result
EOF
  secs="$(awk -v t="$took" 'BEGIN { printf "%.3f", t }')"
  sum="$(awk -v s="$sum" -v t="$took" 'BEGIN { printf "%.6f", s + t }')"
  first="$(awk -v a="$first" -v b="$began" 'BEGIN { printf "%.6f", (a == "" || b + 0 < a + 0) ? b : a }')"
  last="$(awk -v a="$last" -v b="$ended" 'BEGIN { printf "%.6f", (a == "" || b + 0 > a + 0) ? b : a }')"
  if [ "$how" = "killed" ]; then
    printf '%7s  %4s  %8s  %s (KILLED: timed out at its declared bound, so this is not a measurement of what it costs)\n' "$secs" "-" "${bounds[j]}" "${names[j]}"
  else
    printf '%7s  %4s  %8s  %s\n' "$secs" "$rc" "${decls[j]}" "${names[j]}"
  fi
  j=$((j + 1))
done

printf '%7s  %4s  %8s  WALL CLOCK, which is what a push waits through before git runs: the gates run together, so it is the slowest of them\n' \
  "$(awk -v a="${first:-0}" -v b="${last:-0}" 'BEGIN { printf "%.3f", b - a }')" "" ""
printf '%7s  %4s  %8s  the gates'"'"' own times added up, which no push waits through; it is here to show how much they overlap\n' \
  "$(awk -v s="$sum" 'BEGIN { printf "%.3f", s }')" "" ""
[ "$unread" -eq 0 ] || exit 1
exit 0
