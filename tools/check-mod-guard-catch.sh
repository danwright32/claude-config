#!/bin/bash
# check-mod-guard-catch.sh <mods dir>: every hook a mod registers at tool.call or tool.check ends in
# a catch built by mod-kit's hooks/hold.ts (#3655).
#
# Why: Claude Code cuts a hook at 10 s of its own time, and skips one that throws. A tool.call or
# tool.check hook with no catch that refuses is then skipped, and the call it was judging RUNS,
# with nothing said to anyone. Measured live on 2026-11-25 (Claude Code 2.1.332, a throwaway mod in
# headless sessions, #3627): a hook with no catch cut at 10 s let the call run in 6 of 6 runs, and a
# catch that refuses held it in 9 of 9. On that day 25 of the 34 such hooks in payload/mods had no
# catch. A rule each mod must remember to follow is one a mod leaves out (L621), so the catch is
# built in one place and this tool fails any tool hook that does not end in it.
#
# What a registration must end in, as hooks/hold.ts spells it:
#   on('tool.call', ...).catch(($, e, next) => cutCall(MOD, e, next))     it can refuse or ask
#   on('tool.check', ...).catch(($, e, next) => cutCheck(MOD, next))      the same at the check
#   on('tool.call', { tool: OWN }, ...).catch(($, e, next) => cutOwn(MOD, next))   its own tool
#   on('tool.call', ...).catch(watchesOnly)                               it only watches the call
#
# What fails, each named with its mod, file and line, by the state reached and not one spelling
# (L247):
#   - a tool.call or tool.check hook with no catch at all;
#   - one with a catch of the mod's own, whatever it answers;
#   - one answering through the catch of the other event (cutCheck at tool.call);
#   - one whose catch names a kit function its file does not import, under that name, from
#     ./mod-kit/hold.ts (a function of the mod's own called cutCall, an import renamed to it, an
#     import that is commented out), or whose hooks/mod-kit/hold.ts is missing or is not mod-kit's
#     hooks/hold.ts byte for byte;
#   - one declared watchesOnly whose own lines answer a refusal (a deny, a decision) or answer the
#     call themselves (a result): such a hook is a guard or an own tool hook, and says so;
#   - a tool.run or tool.judge hook, which also decides whether a call runs and has no shared catch
#     written for it yet;
#   - a registration whose event is not a plain string, or that cannot be read to its end: what
#     cannot be read is never passed over.
#
# What it cannot see, said here so the check's name is not read as wider than it is (L400): a hook
# declared watchesOnly that refuses through a function it calls rather than in its own lines; a
# hook registered through something other than an `on(` call; and whether the words a mod hands a
# shared catch as its own are true. tests/test-mod-guard-catch.sh covers the second where Claude
# Code is installed, by holding this tool's count of each mod's tool hooks to the one
# `claude plugin validate` gives.
#
# The reading is tools/lib/ts_source.py's guard-catches, shared with every other scan of a mod's
# hooks, so no two of them disagree about what a hook is.
#
# Exit codes, each distinct (L11): 0 every tool hook ends in a shared catch (the counts are
# printed, L98), 1 one does not, or a mod could not be read, 2 the mods folder does not exist, 3 no
# python3 to read the source with.
dir="${1:-}"
if [ -z "$dir" ] || [ ! -d "$dir" ]; then
  echo "check-mod-guard-catch: '${dir:-<none given>}' is not a folder, so nothing was checked." >&2
  exit 2
fi
dir="${dir%/}"
if ! command -v python3 >/dev/null 2>&1; then
  echo "check-mod-guard-catch: python3 is not installed, so no mod's source was read." >&2
  exit 3
fi
# Run isolated (python3 -I), as every caller of ts_source.py does (#3082).
TS_SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ts_source.py"
KIT="$dir/mod-kit/hooks/hold.ts"

n=0
failed=0
hooks=0
bare=0
tally=""
for d in "$dir"/*/; do
  [ -f "$d.claude-plugin/plugin.json" ] || continue
  n=$((n + 1))
  name="$(basename "$d")"
  if [ -f "$KIT" ]; then
    out="$(python3 -I "$TS_SOURCE" guard-catches "${d%/}" "$KIT" 2>&1)"
  else
    out="$(python3 -I "$TS_SOURCE" guard-catches "${d%/}" 2>&1)"
  fi
  # The reader's last line is always its count. Without one it did not finish, whatever it exited
  # with, so the mod was not read, and that is a failure rather than nothing found.
  last="$(printf '%s\n' "$out" | tail -n 1)"
  case "$last" in
    read$'\t'*) ;;
    *)
      failed=1
      echo "check-mod-guard-catch: $name's hooks could not be read, so whether each tool hook ends in a shared catch is not known: $(printf '%s' "$out" | tail -n 1)"
      continue
      ;;
  esac
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in read$'\t'*) continue ;; esac
    failed=1
    echo "check-mod-guard-catch: $name's hook at /${line%%$'\t'*}: ${line#*$'\t'}. The four catches are in the header of mod-kit's hooks/hold.ts, kept in each mod at hooks/mod-kit/hold.ts."
  done <<< "$out"
  counts="${last#read$'\t'}"
  mine=0
  for pair in $counts; do
    v="${pair#*=}"
    mine=$((mine + v))
    case "$pair" in none-of-them=*) bare=$((bare + v)) ;; esac
  done
  hooks=$((hooks + mine))
  [ "$mine" -eq 0 ] || tally="$tally $name=$mine"
done
if [ "$n" -eq 0 ]; then
  echo "check-mod-guard-catch: no mod (a folder with .claude-plugin/plugin.json) in $dir, so nothing was checked." >&2
  exit 2
fi
[ -f "$KIT" ] || echo "check-mod-guard-catch: no mod-kit in $dir, so each mod's copy of hold.ts was only seen to exist, not held to mod-kit's."
echo "check-mod-guard-catch: $n mods checked in $dir, $hooks tool.call and tool.check hooks read, $bare not ending in a shared catch. Hooks per mod:${tally:- none}"
exit "$failed"
