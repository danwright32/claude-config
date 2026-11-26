#!/bin/bash
# mods-real-tree.sh: case 8, the real tree, checked in parts (claude-config#3622).
#
# Case 8 was one run of tools/check-mods.sh over every mod in payload/mods with the real claude. On
# GitHub's runners that one check read 490 and 667 s (2026-11-25), near the 600 s each suite is held
# under, and nearly all of it is the engine running each mod's own tests, one mod after another:
# scope-modes alone is about a third. So the real tree is MODS_REAL_TREE_PARTS suites, each handing
# check-mods.sh the names of the mods dealt to it (mods_real_deal, tests/mods-harness.sh), so the
# runner's deal can put them in different parts of CI. Each named mod is checked exactly as in a
# whole run: the same type check, `claude plugin validate` and `claude plugin test`.
#
# Every part of one run joins one round (CHECK_MODS_ROUND, from the run id run-all-tests.sh gives
# each suite it starts), and check-mods.sh writes the record of the build the mods last passed on
# only when the round's parts, together, passed every mod in the folder on one build. A part run by
# hand joins no round and records nothing.
#
# Sourced, never run, by each real tree part (tests/test-mods.sh is part 1), after
# tests/mods-harness.sh. It is the one place the real claude is found (L2); section 14 of
# tests/test-mods-fixtures.sh holds every other piece to that, and holds the parts to 1 to
# MODS_REAL_TREE_PARTS, each in one suite.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "mods-real-tree.sh is sourced by the real tree parts (tests/test-mods.sh and its siblings), never run on its own." >&2
  exit 2
fi
MODS_REAL_TREE_PARTS=3
# The claude the real tree is checked with: MODS_CLAUDE where the caller installed one for the mods
# alone, as the pull request checks do without putting it on every suite's PATH (#3297), else the one
# on PATH, else ~/.local/bin/claude.
REAL_BIN="${MODS_CLAUDE:-$(command -v claude 2>/dev/null || true)}"
[ -n "$REAL_BIN" ] || { [ -x "$HOME/.local/bin/claude" ] && REAL_BIN="$HOME/.local/bin/claude"; }

# 8. The real tree, with the real binary where this machine has one (REAL_BIN, above), in parts.
#    Nothing before this case starts the real claude, so the record of the build the mods last
#    passed on is read and written here alone.
#    Its failures are kept, and its pass recorded as the build the mods last passed on, where the
#    caller said or in the default places, never in this run's scratch. Given MODS_CLAUDE, the caller
#    promised a claude, so a run that could not check the mods with it fails (#3297).
mods_real_tree_part(){   # $1 = this part  $2 = how many parts
  local part="$1" parts="$2" names=() n dealt out code real_note round=""
  local real_env=(env)
  if [ "$REAL_KEPT_SET" = set ]; then real_env+=(CHECK_MODS_FAILURE_OUTPUT="$REAL_KEPT"); else real_env+=(-u CHECK_MODS_FAILURE_OUTPUT); fi
  if [ "$REAL_LAST_SET" = set ]; then real_env+=(CHECK_MODS_LAST_PASSED="$REAL_LAST"); else real_env+=(-u CHECK_MODS_LAST_PASSED); fi
  [ -z "${MODS_CLAUDE:-}" ] || real_env+=(CHECK_MODS_REQUIRE_CLAUDE=1)
  if [ ! -d "$ROOT/payload/mods" ]; then
    # The folder is created by the sync the first time a Mac sends a mod, and never by hand: payload/
    # in a development checkout is overwritten by the live daemon (payload-write-gate.sh).
    # Not a pass over mods, so not counted as one (claude-config#1452, L98): said by the agreed line.
    echo "SUITE-PART-UNMEASURED the real mods, because payload/mods does not exist yet (no Mac has sent a mod), so there is nothing to check"
    return 0
  fi
  # The mods dealt to this part; none is said by the agreed line, and nothing is run.
  dealt="$(mods_real_part_names "$part" "$parts")"
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    names+=("$n")
  done <<EOF
$dealt
EOF
  if [ "${#names[@]}" -eq 0 ] || [ "${names[0]#SUITE-PART-UNMEASURED }" != "${names[0]}" ]; then
    if [ "${#names[@]}" -gt 0 ]; then echo "${names[0]}"; else check "the real mods of part $part of $parts were dealt" "the deal could not be made (the reason is above)"; fi
    return 0
  fi
  # One run of run-all-tests.sh is one round: its id names it, with how many parts make it whole, so
  # every part of the run puts its pass beside the others'.
  if [ -n "${CLAUDE_SUITE_RUN_ID:-}" ]; then
    round="mods-real-tree.$(printf '%s' "$CLAUDE_SUITE_RUN_ID" | tr -c 'A-Za-z0-9._-' '_').of$parts"
    round="${round#.}"
    real_env+=(CHECK_MODS_ROUND="$round")
  fi
  out="$("${real_env[@]}" CLAUDE_BIN="${REAL_BIN:-$TMPROOT/no-such-claude}" bash "$CHECK" "$ROOT/payload/mods" "${names[@]}" 2>&1)"; code=$?
  # check-mods says first when Claude Code changed since the mods last passed on this Mac (#3297).
  # Marked, by part 1 alone so a run says it once, so the runner prints it under this suite's line
  # whether the suite passed or failed; and put in front of a failure in any part below, so a red
  # reads as that change before anyone hunts for a commit.
  real_note="$(printf '%s\n' "$out" | sed -n 's/^check-mods: \(Claude Code changed since the mods last passed .*\)$/\1/p' | head -n 1)"
  [ -z "$real_note" ] || [ "$part" != 1 ] || echo "SUITE-NOTE $real_note"
  if [ "$code" -eq 3 ]; then
    # Said once, by the agreed line, and counted as nothing (claude-config#1452, L98).
    echo "SUITE-PART-UNMEASURED the real mods of part $part of $parts against Claude Code's own checks, because there is no claude command on this machine"
    # Their types were checked all the same, wherever the pinned compiler is installed (#953).
    if [ -x "$ROOT/tools/typescript/node_modules/.bin/tsc" ]; then
      printf '%s\n' "$out" | grep -q "^check-mods: ${#names[@]} of ${#names[@]} mods type checked against" \
        && check "but every real mod's types were checked, with no claude" ok \
        || check "but every real mod's types were checked, with no claude" "$out"
    fi
  elif [ "$code" -eq 4 ]; then
    # Claude Code's cached rollout switch, which this suite cannot set (#740, L411).
    # Its reasons ride on the one agreed line, which the runner prints; an indented copy below it was
    # dropped like any other chatter (#1444).
    echo "SUITE-PART-UNMEASURED the real mods of part $part of $parts against Claude Code's own checks, because Claude Code has hooks modules switched off on this machine. check-mods said: $(printf '%s\n' "$out" | grep UNMEASURED | sed 's/^check-mods: //' | tr '\n' ' ')"
  else
    [ "$code" -eq 0 ] && check "every mod of part $part of $parts in payload/mods passes Claude Code's own checks" ok \
      || check "every mod of part $part of $parts in payload/mods passes Claude Code's own checks" "${real_note:+$real_note }exit=$code out=$out"
  fi
}
