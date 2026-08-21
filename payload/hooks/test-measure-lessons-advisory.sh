#!/usr/bin/env bash
# Tests for measure-lessons-advisory.sh, which replays the real lessons advisory over a repo's
# recent history and reports how often it would have spoken (claude-config#124).
#
# It exists to keep "is this hook crying wolf?" a measured number rather than an opinion, and a
# measuring tool that is not itself tested is the shape this repo has been caught by before. The
# reading that matters most is the one it must REFUSE: a run that read no commits reports nothing,
# and nothing reads identically to a hook that never fires (L98). That refusal is checked first
# here, before any number it produces is believed.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
M="$DIR/measure-lessons-advisory.sh"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

command -v git >/dev/null 2>&1 || { echo "test-measure-lessons-advisory: git is not on PATH, so nothing was verified." >&2; exit 2; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.measureadv.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-measure-lessons-advisory: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

mkrepo() { # mkrepo <name> <file> <content>  -> prints the repo path
  local r="$TMPROOT/$1"
  mkdir -p "$r"
  git -C "$r" init -q
  git -C "$r" config user.email t@t
  git -C "$r" config user.name t
  printf '%s\n' "$3" > "$r/$2"
  git -C "$r" add -A >/dev/null 2>&1
  git -C "$r" commit -q -m "a commit"
  printf '%s' "$r"
}

# ---------------------------------------------------------------------------
# Refusals first, because every number below is only worth reading once these hold.
# ---------------------------------------------------------------------------
out_none="$(bash "$M" 2>&1)"; code_none=$?
[ "$code_none" -ne 0 ] \
  && check "pointed at no repo at all it refuses" ok \
  || check "pointed at no repo at all it refuses" "exit=$code_none out=$out_none"
printf '%s' "$out_none" | grep -qi 'usage' \
  && check "and says how to call it" ok \
  || check "and says how to call it" "out=$out_none"

NOTAREPO="$TMPROOT/plain"; mkdir -p "$NOTAREPO"
out_notrepo="$(bash "$M" "$NOTAREPO" 2>&1)"; code_notrepo=$?
printf '%s' "$out_notrepo" | grep -qi 'not a git repo' \
  && check "a path that is not a repo is named as skipped, not counted" ok \
  || check "a path that is not a repo is named as skipped, not counted" "out=$out_notrepo"
[ "$code_notrepo" -ne 0 ] \
  && check "and a run that measured nothing exits non-zero rather than reporting quiet" ok \
  || check "and a run that measured nothing exits non-zero rather than reporting quiet" "exit=$code_notrepo"
printf '%s' "$out_notrepo" | grep -qi 'NOTHING MEASURED' \
  && check "and says plainly that nothing was measured" ok \
  || check "and says plainly that nothing was measured" "out=$out_notrepo"

# ---------------------------------------------------------------------------
# A real repo, so it can be seen producing a reading at all. Without this, every refusal above is
# satisfied by a tool that can only ever refuse (L159).
# ---------------------------------------------------------------------------
CLEAN="$(mkrepo clean notes.md "just some prose, nothing a lesson pattern would match")"
out_clean="$(bash "$M" "$CLEAN" -n 1 2>&1)"; code_clean=$?
[ "$code_clean" -eq 0 ] \
  && check "a real repo measures cleanly" ok \
  || check "a real repo measures cleanly" "exit=$code_clean out=$out_clean"
printf '%s' "$out_clean" | grep -qE 'advised on [0-9]+ of [0-9]+ commits' \
  && check "and reports how many commits it read, not just how many fired" ok \
  || check "and reports how many commits it read, not just how many fired" "out=$out_clean"
printf '%s' "$out_clean" | grep -q 'OVERALL' \
  && check "and closes with an overall rate" ok \
  || check "and closes with an overall rate" "out=$out_clean"
printf '%s' "$out_clean" | grep -qi 'tuned out' \
  && check "and says what the number would have to reach to matter" ok \
  || check "and says what the number would have to reach to matter" "out=$out_clean"

# ---------------------------------------------------------------------------
# It has to be able to report a FIRING, or the rate it prints is a constant zero and the whole
# measurement is decoration (L90: a counter whose only input is a value nothing ever writes reports
# zero, and zero is indistinguishable from a real reading).
# ---------------------------------------------------------------------------
# TWO commits, and the risky line arrives in the second. The advisory reads the lines a push would
# ADD, so a repo whose only commit is its first has nothing for it to look at, and a fixture like
# that measures zero for a reason that has nothing to do with the hook (L165: damage the middle,
# not the end).
RISKY="$(mkrepo risky README.md 'a first commit with nothing in it')"
printf 'rm -rf "$target_directory"\n' > "$RISKY/cleanup.sh"
git -C "$RISKY" add -A >/dev/null 2>&1
git -C "$RISKY" commit -q -m "add the cleanup script"
out_risky="$(bash "$M" "$RISKY" -n 2 2>&1)"
printf '%s' "$out_risky" | grep -qE 'advised on [1-9][0-9]* of' \
  && check "a commit the advisory really does flag is counted as a firing" ok \
  || check "a commit the advisory really does flag is counted as a firing" "out=$out_risky"
printf '%s' "$out_risky" | grep -qE '^ +[0-9]+ ' \
  && check "and the trigger that did it is named, so the number can be acted on" ok \
  || check "and the trigger that did it is named, so the number can be acted on" "out=$out_risky"

# ---------------------------------------------------------------------------
# It measures a THROWAWAY clone, so the repo it is pointed at is never touched. That is the whole
# reason it is safe to run against real work (L2).
# ---------------------------------------------------------------------------
before="$(git -C "$RISKY" rev-parse HEAD)"
branch_before="$(git -C "$RISKY" rev-parse --abbrev-ref HEAD)"
bash "$M" "$RISKY" -n 1 >/dev/null 2>&1
[ "$(git -C "$RISKY" rev-parse HEAD)" = "$before" ] \
  && check "the repo it measured is left on the same commit" ok \
  || check "the repo it measured is left on the same commit" "HEAD moved"
[ "$(git -C "$RISKY" rev-parse --abbrev-ref HEAD)" = "$branch_before" ] \
  && check "and on the same branch, not a detached checkout" ok \
  || check "and on the same branch, not a detached checkout" "it is now on $(git -C "$RISKY" rev-parse --abbrev-ref HEAD)"
[ -z "$(git -C "$RISKY" status --porcelain)" ] \
  && check "and with nothing left in its working tree" ok \
  || check "and with nothing left in its working tree" "it left: $(git -C "$RISKY" status --porcelain)"

# ---------------------------------------------------------------------------
# It runs the SHIPPING hook rather than a copy of its patterns, which is what stops the measurement
# drifting from the thing being measured (L107). Asserted from the file, because the alternative is
# noticing years later that the two disagree.
# ---------------------------------------------------------------------------
grep -q 'lessons-advisory.sh' "$M" \
  && check "it invokes the real advisory hook" ok \
  || check "it invokes the real advisory hook" "no reference to it"
[ -x "$DIR/lessons-advisory.sh" ] \
  && check "and that hook is really there and runnable" ok \
  || check "and that hook is really there and runnable" "missing or not executable"

echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
