#!/usr/bin/env bash
#
# measure-lessons-advisory.sh — how noisy is the lessons advisory, really?
#
# Replays the REAL lessons-advisory.sh hook over the recent history of a repo and
# reports how often it would have spoken up, and which triggers did it. The point
# is to keep "is this hook crying wolf?" a measured number rather than an opinion:
# an advisory that fires on most pushes becomes wallpaper within a week, and takes
# the credibility of the blocking gates beside it down too.
#
# It runs the SHIPPING hook, not a copy of its patterns. A re-typed copy would
# drift from the hook and then report on something nobody actually runs.
#
# Run:  bash ~/.claude/hooks/measure-lessons-advisory.sh <repo> [<repo>...] [-n 20]
#
# Reads nothing but git history, and works in a throwaway clone, so the repos you
# point it at are never touched.

set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lessons-advisory.sh"
[ -x "$HOOK" ] || { echo "measure: cannot find lessons-advisory.sh next to this script" >&2; exit 1; }

N=20
repos=()
while [ $# -gt 0 ]; do
  case "$1" in
    -n) N="${2:-20}"; shift 2 ;;
    *) repos+=("$1"); shift ;;
  esac
done
[ "${#repos[@]}" -gt 0 ] || { echo "usage: $(basename "$0") <repo> [<repo>...] [-n <commits>]" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

grand_fired=0
grand_total=0

for src in "${repos[@]}"; do
  name="$(basename "$src")"
  if [ ! -e "$src/.git" ]; then
    echo "### $name: SKIPPED (not a git repo at $src)"
    continue
  fi
  clone="$WORK/clone-$name"
  if ! git clone -q --no-hardlinks "$src" "$clone" 2>/dev/null; then
    echo "### $name: SKIPPED (could not clone)"
    continue
  fi

  fired=0
  total=0
  spotted="$WORK/spotted-$name.txt"
  : > "$spotted"

  for sha in $(git -C "$clone" log -"$N" --format=%H 2>/dev/null); do
    total=$((total+1))
    git -C "$clone" checkout -q "$sha" 2>/dev/null || continue
    # A fresh TMPDIR per commit so the hook's cooldown cannot suppress a reading.
    tmp="$WORK/t$total"; mkdir -p "$tmp"
    out="$(HK_CWD="$clone" python3 -c 'import json,os,sys
sys.stdout.write(json.dumps({"tool_input":{"command":"git push"},"cwd":os.environ["HK_CWD"]}))' \
      | env TMPDIR="$tmp" "$HOOK" 2>/dev/null)"
    rm -rf "$tmp"
    [ -z "$out" ] && continue
    fired=$((fired+1))
    printf '%s' "$out" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit
for line in d["hookSpecificOutput"]["additionalContext"].splitlines():
    if line.startswith("- ") and "->" in line:
        print(line.split("->")[0][2:].strip())
' >> "$spotted" 2>/dev/null
  done

  grand_fired=$((grand_fired + fired))
  grand_total=$((grand_total + total))

  if [ "$total" -eq 0 ]; then
    echo "### $name: NO COMMITS READ — nothing was measured, which is not the same as quiet."
  else
    pct=$(( fired * 100 / total ))
    echo "### $name: advised on $fired of $total commits (${pct}%)"
    sort "$spotted" | uniq -c | sort -rn | sed 's/^/      /'
  fi
  rm -rf "$clone"
done

echo
if [ "$grand_total" -eq 0 ]; then
  echo "NOTHING MEASURED: no commits were read, so this run says nothing about the hook."
  exit 1
fi
echo "OVERALL: advised on $grand_fired of $grand_total commits ($(( grand_fired * 100 / grand_total ))%)"
echo "A rate above roughly one push in three is the point where advice starts being tuned out."
