#!/usr/bin/env bash
# Does an rtk substitute still report the same PASS or FAIL as the tool it replaced?
# (claude-config#319)
#
# The rtk rewrite hook swaps a real command for an rtk one before it runs, and twice a substitute
# has reported a verdict the real tool would not have: claude-config#259 (a Playwright run
# summarised as `PASS (0) FAIL (3)` for a run with 4356 passes, exiting 0) and claude-config#318
# (`rtk diff` printing a difference and exiting 0 where real diff exits 1). Both were found by a
# person noticing afterwards. Nothing measured it, so the protection was three refusals somebody
# remembered to write, and anything nobody thought of was exempt (L96).
#
# This runs a case that genuinely FAILS, and one that genuinely SUCCEEDS, through both the real
# tool and whatever the hook actually substitutes, and compares the exit codes. Both directions,
# because a substitute that always returns 0 is caught only by the failing case and one that always
# returns 1 only by the succeeding one (L142).
#
# Containment is asked of the HOOK, by running it, never by re-reading its refusal list here: two
# copies of that list would drift and this would then report about a hook that is not the one
# installed (L70). A destination that lies and that the hook refuses is CONTAINED, and reported.
# A destination that lies and that the hook allows is a failure, and it names it.
#
# Exit codes, because the whole subject of this script is a tool whose exit code lied (L184):
#   0  every comparison agreed, or its mismatch is contained by the hook
#   1  a destination the hook ALLOWS disagreed with the real tool, named in the output
#   2  it could not measure: no rtk, no hook, no probe could run, or its own control failed
# There is deliberately no exit 0 for a run that compared nothing, because that is the state that
# reads exactly like a clean bill of health (L98).
#
# Two seams, and they are the only two: RTK_FIDELITY_RTK and RTK_FIDELITY_HOOK. The point of this
# script is to measure the REAL binary, so both default to the real thing and only its own tests
# set them.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RTK_BIN="${RTK_FIDELITY_RTK:-$(command -v rtk 2>/dev/null)}"
HOOK="${RTK_FIDELITY_HOOK:-$HERE/rtk-rewrite.sh}"

# Named separately, because "rtk is not installed" and "the hook is not there" need different
# messages or the first will be diagnosed as the second (L11).
if [ -z "$RTK_BIN" ] || [ ! -x "$RTK_BIN" ]; then
  echo "check-rtk-exit-fidelity: rtk is not installed or not executable at [${RTK_BIN:-not found}], so nothing was measured." >&2
  exit 2
fi
if [ ! -f "$HOOK" ]; then
  echo "check-rtk-exit-fidelity: the rewrite hook is not at [$HOOK], so what actually gets substituted could not be asked. Nothing was measured." >&2
  exit 2
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.fidelity-probe.XXXXXXXX")" || WORK=""
case "${WORK%/}" in
  ''|/|"${HOME%/}") echo "check-rtk-exit-fidelity: refusing to run: throwaway directory came back as '$WORK'." >&2; exit 2 ;;
esac
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# The control. Before any verdict is believed, the comparison is watched telling two DIFFERENT
# exit codes apart, or every agreement it reports afterwards is satisfied by a comparison that
# cannot see anything (L1). It is built on `true` and `false`, which cannot be fixed or changed
# out from under it, rather than on the known rtk mismatch, whose disappearance would otherwise
# leave this passing for the wrong reason (L182).
# ---------------------------------------------------------------------------
exits_differ() { [ "$1" != "$2" ]; }
control_ok=no
( exit 0 ); c_true=$?
( exit 1 ); c_false=$?
if exits_differ "$c_true" "$c_false" && ! exits_differ "$c_true" "$c_true"; then control_ok=yes; fi
if [ "$control_ok" != yes ]; then
  echo "check-rtk-exit-fidelity: the control failed: this run could not tell exit $c_true from exit $c_false, so no comparison below would mean anything. Nothing was measured." >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Fixtures. Everything is inside the throwaway directory: no network, no live data, nothing
# outside it read or written (L2).
# ---------------------------------------------------------------------------
mkdir -p "$WORK/plain" "$WORK/repo"
printf 'alpha\n' > "$WORK/plain/a.txt"
printf 'beta\n'  > "$WORK/plain/b.txt"
printf 'alpha\n' > "$WORK/plain/same.txt"
repo_ready=no
if command -v git >/dev/null 2>&1; then
  if git -C "$WORK/repo" init -q >/dev/null 2>&1 \
     && printf 'one\n' > "$WORK/repo/f.txt" \
     && git -C "$WORK/repo" add f.txt >/dev/null 2>&1 \
     && git -C "$WORK/repo" -c user.email=probe@localhost -c user.name=probe commit -qm init >/dev/null 2>&1 \
     && printf 'two\n' > "$WORK/repo/f.txt"; then
    repo_ready=yes
  fi
fi

# id | tool it needs | directory | expected direction of the REAL exit | command
PROBES=(
  "diff-differs|diff|plain|fail|diff a.txt b.txt"
  "diff-same|diff|plain|pass|diff a.txt same.txt"
  "find-missing-path|find|plain|fail|find ./no-such-dir"
  "find-present-path|find|plain|pass|find . -name a.txt"
  "ls-missing-path|ls|plain|fail|ls ./no-such-dir"
  "ls-present-path|ls|plain|pass|ls a.txt"
  "git-outside-a-repo|git|plain|fail|git status"
  "git-dirty-tree|git|repo|fail|git diff --quiet"
  "git-clean-status|git|repo|pass|git status"
)

# What the hook ACTUALLY substitutes for a command: its own answer, not a guess at its rules.
# Silence means it passed the command through, which is the hook refusing that destination.
substitution_for() {
  local cmd="$1" payload out
  payload="$(python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1],"description":"exit fidelity probe"}}))' "$cmd" 2>/dev/null)" || return 1
  out="$(printf '%s' "$payload" | PATH="$(dirname "$RTK_BIN"):$PATH" bash "$HOOK" 2>/dev/null)"
  [ -n "$out" ] || return 1
  printf '%s' "$out" | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
c = ((d.get("hookSpecificOutput") or {}).get("updatedInput") or {}).get("command", "")
print(c)
sys.exit(0 if c else 1)' 2>/dev/null
}

compared=0
skipped=0
broken=0
contained=()
mismatched=()

for entry in "${PROBES[@]}"; do
  IFS='|' read -r id tool dir want cmd <<< "$entry"
  if ! command -v "$tool" >/dev/null 2>&1; then
    skipped=$((skipped + 1))
    echo "skipped $id: $tool is not on PATH here, so the real tool it would be compared against does not exist."
    continue
  fi
  if [ "$dir" = repo ] && [ "$repo_ready" != yes ]; then
    skipped=$((skipped + 1))
    echo "skipped $id: the throwaway git repository could not be built."
    continue
  fi

  ( cd "$WORK/$dir" && eval "$cmd" ) >/dev/null 2>&1; real=$?
  # A probe meant to fail that succeeded is a broken fixture, not a finding: comparing against it
  # would report about a case nobody chose (L165). Said out loud rather than quietly dropped.
  if { [ "$want" = fail ] && [ "$real" -eq 0 ]; } || { [ "$want" = pass ] && [ "$real" -ne 0 ]; }; then
    broken=$((broken + 1))
    echo "broken probe $id: the real \`$cmd\` was expected to $want and exited $real, so its fixture no longer stands for the case it was written for."
    continue
  fi

  if ! sub="$(substitution_for "$cmd")"; then
    contained+=("$id (\`$cmd\`): the hook passes it through, so the real tool runs and there is nothing to compare")
    continue
  fi
  # Run the substitution through the SAME rtk this script was pointed at, never whichever one is
  # first on PATH, or the reading would be about a different binary than the one named.
  case "$sub" in
    "rtk "*) sub_cmd="\"$RTK_BIN\" ${sub#rtk }" ;;
    *)       sub_cmd="$sub" ;;
  esac
  ( cd "$WORK/$dir" && eval "$sub_cmd" ) >/dev/null 2>&1; got=$?
  compared=$((compared + 1))
  if exits_differ "$real" "$got"; then
    mismatched+=("$id: \`$cmd\` exits $real but the hook substitutes \`$sub\` which exits $got")
  fi
done

echo
echo "control: the comparison was proved able to tell exit $c_true from exit $c_false before any verdict below."
echo "compared $compared substitution(s) against the real tool, skipped $skipped, broken fixtures $broken, contained by the hook ${#contained[@]}."
for c in "${contained[@]:-}"; do [ -n "$c" ] && echo "  contained: $c"; done

if [ "$compared" -eq 0 ]; then
  echo "check-rtk-exit-fidelity: nothing was actually compared, so this run says nothing about whether a substitute lies. Treating that as a failure to measure rather than a clean run." >&2
  exit 2
fi

if [ "${#mismatched[@]}" -gt 0 ]; then
  echo
  echo "check-rtk-exit-fidelity: ${#mismatched[@]} substitution(s) the hook ALLOWS report a different verdict than the tool they replace:" >&2
  for m in "${mismatched[@]}"; do echo "  $m" >&2; done
  echo "Anything judging these by their exit code reads the wrong answer (L184). Either refuse the destination in rtk-rewrite.sh, the way \`rtk read\`, the test summarisers and \`rtk diff\` already are, or record why this one is safe." >&2
  exit 1
fi

echo "check-rtk-exit-fidelity: every substitution the hook allows reported the same verdict as the tool it replaced."
exit 0
