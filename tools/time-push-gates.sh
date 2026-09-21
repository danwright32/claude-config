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
# `git push`, in the order the settings list them, which is the order a push waits through, and
# reports each one's wall clock, its exit code, and the total.
#
# Usage: time-push-gates.sh [--repo DIR] [--command "git push"] [--json]
#   GATE_TIMING_HOME   where settings.json and hooks/ live (default: ~/.claude), so a test can
#                      drive a fixture rather than the installed config.
#
# Each gate is bounded by the timeout the settings declare for it, killed at that bound and
# REPORTED as killed rather than as a duration: a run that hit its ceiling is not a measurement of
# what it costs (L11). A gate with no declared timeout is shown as "-" and bounded by the
# platform's own default, 60 seconds, which is written down here as the assumption it is.
#
# It runs the REAL gates against a REAL repository, so it costs what a push costs, model call and
# containers included, and anything a gate writes (a record, a state file) is written.
set -uo pipefail

DEFAULT_TIMEOUT=60
repo="$PWD"
command_line="git push"
as_json=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) repo="${2:-}"; shift 2 ;;
    --command) command_line="${2:-}"; shift 2 ;;
    --json) as_json=1; shift ;;
    *) printf 'time-push-gates: "%s" is not an argument this takes (--repo DIR, --command CMD, --json).\n' "$1" >&2; exit 2 ;;
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

payload="$(REPO="$repo" CMD="$command_line" python3 -c '
import json, os, sys
sys.stdout.write(json.dumps({"tool_name": "Bash", "tool_input": {"command": os.environ["CMD"]}, "cwd": os.environ["REPO"]}))')"

work="$(mktemp -d "${TMPDIR:-/tmp}/time-push-gates.XXXXXXXX")" || exit 1
trap 'rm -rf "$work"' EXIT

printf 'seconds  exit  declared  gate\n'
rows=""
total=0
while IFS="$(printf '\t')" read -r declared hook; do
  [ -n "$hook" ] || continue
  name="${hook##*/}"
  bound="$declared"
  case "$bound" in ''|*[!0-9]*) bound="$DEFAULT_TIMEOUT" ;; esac
  start="$(python3 -c 'import time; print(time.time())')"
  # Run it in the background and wait on the CONDITION, so a gate that hangs is killed at its own
  # declared bound rather than taking this tool with it (L110, L473).
  ( cd "$repo" 2>/dev/null || exit 0; printf '%s' "$payload" | bash "$hook" >"$work/out" 2>&1; printf '%s' "$?" > "$work/rc" ) &
  runner=$!
  killed=""
  while kill -0 "$runner" 2>/dev/null; do
    now="$(python3 -c 'import time; print(time.time())')"
    over="$(awk -v a="$now" -v b="$start" -v c="$bound" 'BEGIN { print (a - b > c) ? 1 : 0 }')"
    if [ "$over" = "1" ]; then
      bash "$(dirname "${BASH_SOURCE[0]}")/../payload/hooks/lib/kill-tree.sh" "$runner" 2>/dev/null || kill -9 "$runner" 2>/dev/null
      killed=1
      break
    fi
    sleep 0.2
  done
  wait "$runner" 2>/dev/null
  end="$(python3 -c 'import time; print(time.time())')"
  secs="$(awk -v a="$end" -v b="$start" 'BEGIN { printf "%.1f", a - b }')"
  rc="$(cat "$work/rc" 2>/dev/null || printf '?')"
  total="$(awk -v t="$total" -v s="$secs" 'BEGIN { printf "%.1f", t + s }')"
  if [ -n "$killed" ]; then
    printf '%7s  %4s  %8s  %s (KILLED: timed out at its declared bound, so this is not a measurement of what it costs)\n' "$secs" "-" "$bound" "$name"
  else
    printf '%7s  %4s  %8s  %s\n' "$secs" "$rc" "$declared" "$name"
  fi
  rm -f "$work/rc" "$work/out"
done <<EOF
$gates
EOF

printf '%7s  %4s  %8s  TOTAL, which is what a push waits through before git runs\n' "$total" "" ""
exit 0
