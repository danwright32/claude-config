#!/usr/bin/env bash
# rtk-hook-version: 2
# RTK Claude Code hook: rewrites commands to use rtk for token savings.
# Requires: rtk >= 0.23.0, jq
#
# This is a thin delegating hook: all rewrite logic lives in `rtk rewrite`,
# which is the single source of truth (src/discover/registry.rs).
# To add or change rewrite rules, edit the Rust registry, not this file.

if ! command -v jq &>/dev/null; then
  echo "[rtk] WARNING: jq is not installed. Hook cannot rewrite commands. Install jq: https://jqlang.github.io/jq/download/" >&2
  exit 0
fi

if ! command -v rtk &>/dev/null; then
  echo "[rtk] WARNING: rtk is not installed or not in PATH. Hook cannot rewrite commands. Install: https://github.com/rtk-ai/rtk#installation" >&2
  exit 0
fi

# Version guard: rtk rewrite was added in 0.23.0.
# Older binaries: warn once and exit cleanly (no silent failure).
RTK_VERSION=$(rtk --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | awk 'NR <= 1')
if [ -n "$RTK_VERSION" ]; then
  MAJOR=$(echo "$RTK_VERSION" | cut -d. -f1)
  MINOR=$(echo "$RTK_VERSION" | cut -d. -f2)
  # Require >= 0.23.0
  if [ "$MAJOR" -eq 0 ] && [ "$MINOR" -lt 23 ]; then
    echo "[rtk] WARNING: rtk $RTK_VERSION is too old (need >= 0.23.0). Upgrade: cargo install rtk" >&2
    exit 0
  fi
fi

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

if [ -z "$CMD" ]; then
  exit 0
fi

# Delegate all rewrite logic to the Rust binary.
# rtk rewrite exits 1 when there's no rewrite: hook passes through silently.
REWRITTEN=$(rtk rewrite "$CMD" 2>/dev/null) || exit 0

# NEVER rewrite a command into `rtk read` (downbeat#254).
#
# `rtk read` STRIPS COMMENT LINES and renumbers what remains from 1. Measured
# 2026-08-17 on rtk 0.31.0: a 51 line Swift file came back as 28 lines. So every
# line number taken from it is wrong AND plausible, which is worse than mangled
# output, because a wrong line number looks exactly like a line number. Three
# consecutive planning passes cited wrong file:line pairs for this reason and
# each one corrected the previous pass's numbers rather than suspecting the
# instrument.
#
# This refuses by the DESTINATION rather than by the source command. rtk's own
# `[hooks] exclude_commands` setting honours `cat` but is ignored for `head` and
# `tail` (measured on 0.31.0 with all three listed), so a source based list both
# misses those two and would miss the next command that starts mapping here.
# Whatever produced it, `rtk read` is the thing that corrupts the output.
#
# Everything else still goes through rtk, which is the point: git, gh and the
# rest keep saving tokens. Only file reads pass through untouched.
case "$REWRITTEN" in
  "rtk read "*) exit 0 ;;
esac

# NEVER rewrite a TEST RUN into an rtk summariser (claude-config#259).
#
# Twice on 2026-09-01 a full Playwright run came back as exactly 18 bytes, `PASS (0) FAIL (3)`, and
# nothing else. Both commands EXITED 0 and the true results were 4356 and 4359 passed with nothing
# failed, confirmed by re-running with a different reporter. Two properties compound: it invented
# three failures that did not exist, and it discarded the entire underlying output, so there was
# nothing left to cross-check against. The same parser failing the other way round reports PASS on
# a red suite by the same mechanism, and there would be no output left to contradict it either.
#
# It is size dependent, so the condensing engages exactly on the runs too long to eyeball, and
# intermittent, so a correct summary yesterday says nothing about today.
#
# A summary that can disagree with the exit code, while being the only thing printed, is not a
# summary a reader can rely on. A test verdict is the one output where being wrong is
# indistinguishable from being right, so these pass through unfiltered. Everything else still goes
# through rtk, which is the point: git, gh and the rest keep saving tokens.
#
# Refused by DESTINATION, like `rtk read` above, and for the same reason: whatever produced it,
# the summariser is the thing that corrupts the output.
rtk_dest_sub="${REWRITTEN#rtk }"; rtk_dest_verb="${rtk_dest_sub#* }"
rtk_dest_sub="${rtk_dest_sub%% *}"; rtk_dest_verb="${rtk_dest_verb%% *}"

# The `test` VERB, wherever it appears as the first argument. rtk's help describes `cargo`, `go`,
# `dotnet` and `npm` as compact output for those tools generally, so the subcommand alone cannot
# tell `cargo test` from `cargo build`, and only the verb makes it a verdict.
if [ "$rtk_dest_verb" = "test" ]; then exit 0; fi

# The floor: summarisers whose whole job is a test verdict. Held in code AND checked by the
# derivation below, so neither is the only guard (L96).
case " test playwright pytest vitest " in
  *" $rtk_dest_sub "*) exit 0 ;;
esac

# And derived from rtk's OWN subcommand list, so a summariser this hook has never heard of is
# refused because rtk says it runs tests, rather than because somebody remembered to add it (L41).
# A help output that cannot be read finds nothing and refuses nothing extra, which is why the floor
# above is not folded into it: the derivation going quiet must not take the known cases with it.
#
# It errs toward refusing, and the cost of that is measured rather than assumed. Against rtk 0.31.0
# it also catches `dotnet` (its description lists build/test/restore/format) and `verify` (it runs
# TOML filter inline tests), neither of which is purely a test verdict. Both simply run unfiltered,
# which loses some token saving and cannot lose a result, and neither is used by any project here.
if rtk --help 2>/dev/null | awk -v want="$rtk_dest_sub" '
     $1 == want && tolower($0) ~ /test/ { found = 1 }
     END { exit found ? 0 : 1 }
   '; then
  exit 0
fi

# NEVER rewrite into a destination MEASURED to report a different verdict than the tool it
# replaces (claude-config#318, claude-config#319).
#
# Two measurements against rtk 0.31.0 on 2026-09-05. `rtk diff` on two one line files that differ
# prints the difference and EXITS 0, where the real diff exits 1, so anything judging by the exit
# code reads "different" as "same" (L184). And comparing a regenerated lessons index against the
# committed one, it printed "[ok] Files are identical" for two files that genuinely differ; cmp on
# the same pair reported "differ: char 44885, line 206", and a repeat of the same command a minute
# later reported the difference correctly. That half is intermittent, which is worse than always
# wrong: it was caught only because the line was read by hand afterwards.
#
# A comparison verdict has the same property as the test verdict above, that being wrong is
# indistinguishable from being right, and it is worse in one way: the two things a reader could
# cross-check against each other are the output and the exit code, and the exit code here carries
# no verdict at all.
#
# `rtk find` is the second, found by the check rather than by a person: `find ./no-such-dir` exits
# 1 and `rtk find ./no-such-dir` exits 0, so a search over a path that does not exist, a typo or
# something since moved, reads as a search that ran and found nothing (L100, L320).
#
# No derivation from rtk's help for these, unlike the summarisers above. The only thing a help line
# offers to match on is a word in a description, and the day `git`'s description mentions diffs
# that match refuses every git rewrite, which is the largest saving this hook exists for. What
# stops this list being the only guard is not a cleverer pattern, it is a MEASUREMENT:
# `check-rtk-exit-fidelity.sh` runs a genuinely failing case and a genuinely succeeding one through
# both the real tool and whatever this hook substitutes, and fails when a destination it ALLOWS
# disagrees. So the next liar is found by the check rather than by somebody remembering to add it
# here (L96), and a destination listed here is reported by that check as contained rather than as
# a finding.
#
# `rtk git diff` is a different destination and was measured to carry its exit code through (a
# dirty tree gave 1 through both the real git and rtk), so it is untouched here and
# `git diff --quiet` goes on answering. So do `rtk ls`, `rtk git status` and `rtk git log`, all
# measured to agree in both directions.
case " diff find " in
  *" $rtk_dest_sub "*) exit 0 ;;
esac

# No change: nothing to do.
if [ "$CMD" = "$REWRITTEN" ]; then
  exit 0
fi

ORIGINAL_INPUT=$(echo "$INPUT" | jq -c '.tool_input')
UPDATED_INPUT=$(echo "$ORIGINAL_INPUT" | jq --arg cmd "$REWRITTEN" '.command = $cmd')

jq -n \
  --argjson updated "$UPDATED_INPUT" \
  '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "allow",
      "permissionDecisionReason": "RTK auto-rewrite",
      "updatedInput": $updated
    }
  }'
