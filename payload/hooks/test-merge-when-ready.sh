#!/usr/bin/env bash
# Tests for lib/merge-when-ready.sh (claude-config#851): a pull request sent back for being behind its
# base is updated, waited on and merged in one step, and only ever through the same gates a typed
# merge meets.
#
# A fake gh holds the pull request's state in files (head, checks, distance behind, merged), and
# moves it the way GitHub does: `pr update-branch` gives the pull request a NEW head with its checks
# pending. The sleep is injected, and each fake sleep runs a step the test chose (checks go green,
# main moves again), so nothing here waits on a clock (L524, L290). The three gates and the review
# checker are stubs that log what they were asked and answer from files, except in section 6, where
# the REAL block-red-merge.sh judges, so the helper's reading of a real refusal is proved (L52).
# Nothing reaches the network or a real pull request (L2).
#
# This suite once held every check of the helper, 1,600 of them, and on 2026-11-24 it ran past
# run-all-tests.sh's 1,200 second wall limit on GitHub's runners (exit 124), which stopped the config
# sync between the two Macs (claude-config#3572, L315). It now holds the documentation and placement
# checks, which run once, and sections 1 to 10. The rest are suites of their own, each dealt to a part
# by its own measured cost, with every check as it was and every section keeping its number:
# test-merge-when-ready-heads.sh (11 to 21), -turn (22 to 26b), -line (27 to 30), -untested (31 to
# 33) and -bypass (the bypass merge and sleep mode, once section 34). "Section N" in a comment names
# the section of that number in whichever of them holds it. The world all six run the helper in, the
# counters and the result line are lib/merge-when-ready-harness.sh.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib/merge-when-ready-harness.sh" || {
  echo "FAIL: $(basename "$0"): lib/merge-when-ready-harness.sh is missing, so there is no world to run the helper in. Refusing to run."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}

# Every place that documents running it in the background names --log=, never a pipe into tee (#2304).
# The README is the repository's, so it is found through the checkout this copy sits in, by the one
# shared test of that (lib/checkout-root.sh, #1567). The installed copy, which the hook suite runs
# after every pull, is in none and has no README, so there it is reported unmeasured rather than
# failing for a file it can never hold (claude-config#2620, L411).
DOCS=("$DIR/../skills/orchestrate/SKILL.md" "$HELPER")
CHECKOUT="$(bash "$DIR/lib/checkout-root.sh" "$DIR/.." 2>/dev/null || true)"
if [ -n "$CHECKOUT" ]; then
  DOCS=("$CHECKOUT/README.md" "${DOCS[@]}")
else
  echo "SUITE-PART-UNMEASURED README.md naming --log= for a background run: $DIR/.. is not the payload of a claude-config checkout, so there is no README.md to read"
fi
for f in "${DOCS[@]}"; do
  check "#2304 $(basename "$f") documents --log= for a background run" "--log=" "$(cat "$f")"
  check_not "#2304 $(basename "$f") never pipes the helper into tee" "merge-when-ready.sh <pr> 2>&1 | tee" "$(cat "$f")"
done

# MERGE_WHEN_READY_DOCS_ONLY=1 is this suite's own run of a copy of itself, placed as installed and
# as a fixture checkout (below): only the documentation checks above, then the result.
if [ -n "${MERGE_WHEN_READY_DOCS_ONLY:-}" ]; then
  mwr_harness_result
  exit
fi

# The documentation checks, judged from both places this suite runs (claude-config#2620). Installed,
# as the hook suite after every pull runs it, there is no README, so its check is reported unmeasured
# and the run passes (L411). In a checkout whose README has lost --log=, it still fails (L1).
. "$DIR/lib/placement-copy.sh"
PLACED=(hooks/test-merge-when-ready.sh hooks/lib skills/orchestrate/SKILL.md)
placed_run() { MERGE_WHEN_READY_DOCS_ONLY=1 bash "$1/hooks/test-merge-when-ready.sh" 2>&1; }
if copy="$(placement_copy installed "$WORKDIR/placed-installed" "$DIR/.." "${PLACED[@]}")"; then
  out="$(placed_run "$copy")"; rc=$?
  check_eq "#2620 installed, with no README, the documentation run passes" "0" "$rc"
  check "#2620 and says the README was not measured" "SUITE-PART-UNMEASURED" "$out"
  check_not "#2620 and fails nothing" "FAIL:" "$out"
else
  bad "#2620 an installed copy of this suite could not be placed"
fi
if copy="$(placement_copy checkout "$WORKDIR/placed-checkout" "$DIR/.." "${PLACED[@]}")"; then
  printf '%s\n' 'Run it in the background with: bash merge-when-ready.sh <pr> 2>&1 | tee merge.log' \
    > "$WORKDIR/placed-checkout/README.md"
  out="$(placed_run "$copy")"; rc=$?
  check_eq "#2620 in a checkout whose README lost --log=, the documentation run fails" "1" "$rc"
  check "#2620 naming the README" "FAIL: #2304 README.md documents --log= for a background run" "$out"
else
  bad "#2620 a checkout copy of this suite could not be placed"
fi

mwr_harness_build

# =================================================================================================
# 1. Refuses what it was not built to carry, before it touches anything (no weakening, L448).
# =================================================================================================
fresh "$OLD" 0 "$GREEN"
for bad_args in "7 --admin" "7 --auto --squash" "7 --squash --match-head-commit $OLD" "7 --body ALLOW_RED_MERGE=1" "7 --squash --repo acme/widget;rm"; do
  # shellcheck disable=SC2086
  out="$(run $bad_args)"; rc=$?
  check_eq "#851 refuses arguments it does not carry: $bad_args" "64" "$rc"
  check_eq "#851 and makes no call to GitHub for them: $bad_args" "" "$(cat "$ST/gh-calls" 2>/dev/null)"
done
out="$(run --squash)"; rc=$?
check_eq "#851 refuses with no pull request number" "64" "$rc"
out="$(cd "$WORKDIR" && bash "$HELPER" 7 --squash 2>&1)"; rc=$?
check_eq "#851 refuses outside a checkout, where no review can be run" "64" "$rc"

# =================================================================================================
# 2. Already up to date, green and reviewed: merged at once, pinned, through both gates.
# =================================================================================================
fresh "$OLD" 0 "$GREEN"
out="$(run 7 --repo acme/widget --squash --delete-branch)"; rc=$?
check_eq "#851 an up to date green pull request merges" "0" "$rc"
check "#851 and says it merged that head" "Merged #7 in acme/widget at ${OLD:0:7}" "$out"
# The clean path (claude-config#2687): gh pr merge exits 0, as it does when the merge lands with
# nothing to complain about. Until #2687 the fake gh exited 1 after every merge, so every merge in
# this suite took the "gh exited after merging" path and this one was never run.
check "#2687 a clean merge reports the merge and the branch deleted, with nothing in between" "Merged #7 in acme/widget at ${OLD:0:7}. Deleted its branch feat/x." "$out"
check_not "#2687 and names no gh failure, since there was none" "gh exited" "$out"
check_eq "#2687 the branch is deleted, once" "feat/x" "$(cat "$ST/deleted" 2>/dev/null)"
check_eq "#851 the branch is not updated when it is not behind" "0" "$(count gh-calls 'pr update-branch')"
check_eq "#851 exactly one merge" "1" "$(count gh-calls 'pr merge')"
check "#851 the merge pins the head it judged" "pr merge 7 --repo acme/widget --squash --match-head-commit $OLD" "$(cat "$ST/gh-calls")"
check "#851 the checks gate is asked about that exact merge command" "gh pr merge 7 --repo acme/widget --squash --match-head-commit $OLD" "$(cat "$ST/red-gate-payloads")"
check "#851 and so is the lessons review gate" "gh pr merge 7 --repo acme/widget --squash --match-head-commit $OLD" "$(cat "$ST/review-gate-payloads")"
check "#851 the review is asked about the pull request's head, base and branch" "check --dir $REPO --sha $OLD --base-ref origin/main --branch feat/x" "$(cat "$ST/review-calls")"
check "#1161 and is started naming the pull request, whose comments it reads" "start --dir $REPO --sha $OLD --base-ref origin/main --branch feat/x --pr 7" "$(cat "$ST/review-calls")"
# A review that allows says what it found, once: since #1338 an allow can carry findings that repeat
# ones already answered, shown as answered, and the helper is where the session reads them.
check "#1338 the review's verdict is shown when it allows" "The lessons review finished with 0 findings." "$out"
check_eq "#1338 once, however often it is asked" "1" "$(grep -c 'The lessons review finished with 0 findings.' <<<"$out")"

# =================================================================================================
# 3. Behind: updated, then the NEW head's checks and review are waited for, and that head merged.
# =================================================================================================
fresh "$OLD" 4 "$GREEN"
printf '%s\n' "$NEW" > "$ST/next-heads"
# The first sleep follows the update, when the new head's checks have only just started.
printf '%s\n%s\n' ":" "printf '%s' '$GREEN' > \"\$ST/rollup\"" > "$ST/on-sleep"
printf '3\n0\n' > "$ST/review-answers"
out="$(run 7 --squash)"; rc=$?
check_eq "#851 a pull request behind main is updated and merged" "0" "$rc"
check_eq "#851 the branch was updated once" "1" "$(count gh-calls 'pr update-branch 7')"
check "#851 it says why it updated, with the distance" "4 commits behind main" "$out"
check "#851 the merge is pinned to the UPDATED head, never the one sent back" "--match-head-commit $NEW" "$(grep 'pr merge' "$ST/gh-calls")"
check_not "#851 the old head is never merged" "--match-head-commit $OLD" "$(grep 'pr merge' "$ST/gh-calls" || true)"
check "#851 the new head's review was started at once, in parallel with its checks" "start --dir $REPO --sha $NEW" "$(cat "$ST/review-calls")"
check "#851 it waited while the new head's checks ran" "checks still running" "$out"
check "#851 and while its lessons review ran" "lessons review still running" "$out"
check "#851 every wait line carries the elapsed time" "merge-when-ready: [" "$out"
[ "$(count sleeps 30)" -ge 2 ] && ok || bad "#851 it slept through the injected sleep while waiting ($(count sleeps 30))"

# =================================================================================================
# 4. Main moves again while the new head is being checked: updated again. There is no count of
#    updates since #1271; the deadline bounds the run, and section 11
#    (test-merge-when-ready-heads.sh) proves both.
# =================================================================================================
fresh "$OLD" 2 "$GREEN"
printf '%s\n%s\n' "$NEW" "$NEWER" > "$ST/next-heads"
printf '%s\n%s\n' "printf '%s' '$GREEN' > \"\$ST/rollup\"; printf 3 > \"\$ST/behind\"" "printf '%s' '$GREEN' > \"\$ST/rollup\"" > "$ST/on-sleep"
out="$(run 7 --squash)"; rc=$?
check_eq "#851 main moving again means a second update, then the merge" "0" "$rc"
check_eq "#851 two updates" "2" "$(count gh-calls 'pr update-branch 7')"
check "#851 merging the newest head" "--match-head-commit $NEWER" "$(grep 'pr merge' "$ST/gh-calls")"


# =================================================================================================
# 5. Every way it stops without merging, each in its own words.
# =================================================================================================
fresh "$OLD" 0 "$GREEN"
printf 'PR #7 is not green: tests=FAILURE.' > "$ST/red-gate-deny"
out="$(run 7 --squash)"; rc=$?
check_eq "#851 a refusal from the checks gate stops it" "1" "$rc"
check "#851 carrying the gate's own reason" "tests=FAILURE" "$out"
check_eq "#851 and nothing is merged past it" "0" "$(count gh-calls 'pr merge')"

fresh "$OLD" 0 "$GREEN"
printf 'Refusing to merge: the lessons review could not run.' > "$ST/review-gate-refuse"
out="$(run 7 --squash)"; rc=$?
check_eq "#851 a refusal from the lessons review gate stops it" "1" "$rc"
check "#851 carrying that gate's reason" "could not run" "$out"
check_eq "#851 and nothing is merged past it either" "0" "$(count gh-calls 'pr merge')"

fresh "$OLD" 0 "$GREEN"
printf '1\n' > "$ST/review-answers"
out="$(run 7 --squash)"; rc=$?
check_eq "#851 findings to read stop it: only the session can read them" "1" "$rc"
check "#851 showing the findings" "swallows the error" "$out"
check "#851 and how to come back with their key" "PR_REVIEW_READ=<key> bash ~/.claude/hooks/lib/merge-when-ready.sh 7" "$out"
check_eq "#851 nothing merged with findings unread" "0" "$(count gh-calls 'pr merge')"

fresh "$OLD" 0 "$GREEN"
present "PR_REVIEW_READ=abc123 bash ~/.claude/hooks/lib/merge-when-ready.sh 7 --squash" >/dev/null
out="$(PR_REVIEW_READ=abc123 run 7 --squash)"; rc=$?
check_eq "#851 with the read key typed in front of it, it merges" "0" "$rc"
check "#851 the key reaches the review checker" "PR_REVIEW_READ=abc123" "$(grep '^check' "$ST/review-calls")"
check "#851 and stands in front of the merge the review gate judges" "PR_REVIEW_READ=abc123 gh pr merge 7" "$(cat "$ST/review-gate-payloads")"
fresh "$OLD" 0 "$GREEN"
out="$(PR_REVIEW_READ='abc; rm -rf x' run 7 --squash)"; rc=$?
check_eq "#851 a key that is not a key is refused" "64" "$rc"

# A SHELL LOOP READING THE KEY OUT OF THE HELPER'S OWN REFUSAL (claude-config#1673). The key is the
# proof that whoever merges was SHOWN the findings, so it has to come from a reader: typed, by the
# session that read them, in front of the command. The helper takes it from its environment, and
# no gate counts the helper as a merge, so a Bash call that runs it, greps the key from what it
# printed and runs it again merged with nobody having read anything. The real review gate is shown
# the loop first, exactly as Claude Code would show it, and the loop then runs as typed.
# The helper's own path is written into the loop, as a session types it, so the gate reads a command
# naming merge-when-ready.sh, gets past its first filter and judges the key in front of the rerun
# (lessons review at a58c6bb: through "$HELPER" the gate never read the loop at all).
LOOP="out=\"\$(bash '$HELPER' 7 --squash 2>&1)\"; key=\"\$(printf '%s\\n' \"\$out\" | sed -n 's/.*PR_REVIEW_READ=\\([a-f0-9][a-f0-9]*\\).*/\\1/p')\"; PR_REVIEW_READ=\"\$key\" bash '$HELPER' 7 --squash"
check "#1673 the loop names the helper, so the gate reads it" "merge-when-ready.sh' 7 --squash" "$LOOP"
fresh "$OLD" 0 "$GREEN"
printf '5eed5eed5eed5eed' > "$ST/review-key"
gate_out="$(present "$LOOP")"; grc=$?
check_eq "#1673 and records no key for it, since none was typed" "" "$(ls "$AI_REVIEW_STATE_DIR/helper-keys" 2>/dev/null)"
out="$(cd "$REPO" && bash -c "$LOOP" 2>&1)"; rc=$?
check_eq "#1673 the review gate does not refuse the loop itself (the helper judges its key)" "0" "$grc"
check_eq "#1673 a key grepped from the helper's own refusal merges nothing" "0" "$(count gh-calls 'pr merge')"
check_eq "#1673 the rerun carrying it is refused before anything" "64" "$rc"
check "#1673 saying the key has to be typed in front of the command" "was not typed in front of this command" "$out"
check_eq "#1673 and the review checker never received the grepped key" "0" "$(count review-calls 'PR_REVIEW_READ=5eed5eed5eed5eed')"
# The same key, typed by the session that read the findings, merges: a person reading them and passing
# the key on a typed command is exactly what the key is for.
fresh "$OLD" 0 "$GREEN"
printf '5eed5eed5eed5eed' > "$ST/review-key"
gate_out="$(present "PR_REVIEW_READ=5eed5eed5eed5eed bash ~/.claude/hooks/lib/merge-when-ready.sh 7 --squash")"; grc=$?
check_eq "#1673 the gate allows the typed key" "0" "$grc"
out="$(PR_REVIEW_READ=5eed5eed5eed5eed run 7 --squash)"; rc=$?
check_eq "#1673 the same key typed in front of the helper merges" "0" "$rc"
check_eq "#1673 once" "1" "$(count gh-calls 'pr merge')"
# Exported, or carried in a variable, it was not typed in front of the helper, so it is refused too.
fresh "$OLD" 0 "$GREEN"
printf '5eed5eed5eed5eed' > "$ST/review-key"
present 'export PR_REVIEW_READ=5eed5eed5eed5eed; bash ~/.claude/hooks/lib/merge-when-ready.sh 7 --squash' >/dev/null
out="$(PR_REVIEW_READ=5eed5eed5eed5eed run 7 --squash)"; rc=$?
check_eq "#1673 an exported key is refused" "64" "$rc"
check_eq "#1673 and merges nothing" "0" "$(count gh-calls 'pr merge')"
# A key typed for one command does not vouch for a different one in the environment.
fresh "$OLD" 0 "$GREEN"
present "PR_REVIEW_READ=abc123 bash ~/.claude/hooks/lib/merge-when-ready.sh 7 --squash" >/dev/null
out="$(PR_REVIEW_READ=def456 run 7 --squash)"; rc=$?
check_eq "#1673 a key other than the one typed is refused" "64" "$rc"
# Where the typed key cannot be recorded, the gate says so and refuses the command, rather than
# letting the helper refuse it later for a reason nobody can see (L11, L667).
fresh "$OLD" 0 "$GREEN"
mkdir -p "$WORKDIR"; : > "$WORKDIR/ai-review"
gate_out="$(present "PR_REVIEW_READ=abc123 bash ~/.claude/hooks/lib/merge-when-ready.sh 7 --squash")"; grc=$?
rm -f "$WORKDIR/ai-review"
check_eq "#1673 a typed key that cannot be recorded refuses the command" "2" "$grc"
check "#1673 naming why" "could not be recorded" "$gate_out"
# With no key at all the gate stays out of the way: the helper waits for the review itself.
fresh "$OLD" 0 "$GREEN"
gate_out="$(present "bash ~/.claude/hooks/lib/merge-when-ready.sh 7 --squash")"; grc=$?
check_eq "#1673 no key: the gate allows the helper" "0" "$grc"
check_eq "#1673 and records nothing" "" "$(ls "$AI_REVIEW_STATE_DIR/helper-keys" 2>/dev/null)"

# A RECORD MADE BY HAND (claude-config#1700). The record of a typed key was an empty file named by the
# key's sha256, which anything able to write the folder could make, a session's own shell included.
# It is now named by an HMAC of the key under a secret only the gate creates, so a file made by hand,
# under the old name or any other a session can compute without that secret, vouches for nothing.
KEYS_DIR="$AI_REVIEW_STATE_DIR/helper-keys"
fresh "$OLD" 0 "$GREEN"
printf '5eed5eed5eed5eed' > "$ST/review-key"
mkdir -p "$KEYS_DIR"; : > "$KEYS_DIR/$(printf '%s' 5eed5eed5eed5eed | shasum -a 256 | awk '{ print $1 }')"
out="$(PR_REVIEW_READ=5eed5eed5eed5eed run 7 --squash)"; rc=$?
check_eq "#1700 a record made by hand, with no gate ever having run, is refused" "64" "$rc"
check_eq "#1700 and merges nothing" "0" "$(count gh-calls 'pr merge')"
# The same, once the gate has made its secret by recording another key: the hand made name is still
# not the one the gate would write.
fresh "$OLD" 0 "$GREEN"
printf '5eed5eed5eed5eed' > "$ST/review-key"
present "PR_REVIEW_READ=abc123 bash ~/.claude/hooks/lib/merge-when-ready.sh 7 --squash" >/dev/null
mkdir -p "$KEYS_DIR"; : > "$KEYS_DIR/$(printf '%s' 5eed5eed5eed5eed | shasum -a 256 | awk '{ print $1 }')"
out="$(PR_REVIEW_READ=5eed5eed5eed5eed run 7 --squash)"; rc=$?
check_eq "#1700 a hand made record beside the gate's own is refused" "64" "$rc"
check_eq "#1700 and merges nothing beside it" "0" "$(count gh-calls 'pr merge')"
# Read through python rather than stat, whose flags mean different things on macOS and Linux (on
# Linux `stat -f` reports the filesystem, and printed that in CI).
secret_mode="$(python3 -c 'import os, sys; print("%o" % (os.stat(sys.argv[1]).st_mode & 0o777))' "$AI_REVIEW_STATE_DIR/helper-keys.secret" 2>&1)"
check_eq "#1700 the gate's secret is readable by its owner alone" "600" "$secret_mode"
# A secret that is not one (cut short, emptied) is replaced, never used, and the typed path still works.
fresh "$OLD" 0 "$GREEN"
printf '5eed5eed5eed5eed' > "$ST/review-key"
mkdir -p "$AI_REVIEW_STATE_DIR"; printf 'short' > "$AI_REVIEW_STATE_DIR/helper-keys.secret"
gate_out="$(present "PR_REVIEW_READ=5eed5eed5eed5eed bash ~/.claude/hooks/lib/merge-when-ready.sh 7 --squash")"; grc=$?
check_eq "#1700 a damaged secret is replaced and the typed key recorded" "0" "$grc"
out="$(PR_REVIEW_READ=5eed5eed5eed5eed run 7 --squash)"; rc=$?
check_eq "#1700 and the typed key then merges" "0" "$rc"
# TWO GATES REPLACING ONE DAMAGED SECRET AT ONCE (lessons review of #1700). Both see it damaged; if
# each then put its own secret over it, the second would silently replace the first and the key the
# first recorded would stop counting. Gate B is held, through the pause the library offers for this,
# right after it has seen the secret damaged; gate A replaces it and records its key in full; then B
# goes on. Both keys must count, under one secret. The fifos make the order exact, so nothing here
# waits on a clock (L290).
fresh "$OLD" 0 "$GREEN"
mkdir -p "$AI_REVIEW_STATE_DIR"; printf 'short' > "$AI_REVIEW_STATE_DIR/helper-keys.secret"
RACE="$WORKDIR/race"; rm -f "$RACE.reached" "$RACE.go"; mkfifo "$RACE.reached" "$RACE.go"
# B says "done" on the same fifo when it ends, so a B that never pauses cannot leave this waiting.
( AR_HELPER_SECRET_PAUSE="$RACE" present "PR_REVIEW_READ=bbbb2222 bash ~/.claude/hooks/lib/merge-when-ready.sh 7 --squash" > "$WORKDIR/race-b.out"; echo $? > "$WORKDIR/race-b.rc"; printf 'done\n' > "$RACE.reached" ) &
race_b=$!
read -r race_said < "$RACE.reached"
check_eq "#1700 race: the second gate is held after seeing the secret damaged" "reached" "$race_said"
gate_out="$(present "PR_REVIEW_READ=aaaa1111 bash ~/.claude/hooks/lib/merge-when-ready.sh 7 --squash")"; grc=$?
if [ "$race_said" = reached ]; then printf 'go\n' > "$RACE.go"; read -r _ < "$RACE.reached"; fi
wait "$race_b"
check_eq "#1700 race: the first gate to replace the damaged secret records its key" "0" "$grc"
check_eq "#1700 race: and so does the second" "0" "$(cat "$WORKDIR/race-b.rc" 2>/dev/null)"
check_eq "#1700 race: the first gate's key still counts once the second has run" "yes" "$( (. "$DIR/lib/ai-review-common.sh" && ar_helper_key_typed aaaa1111) && echo yes || echo no)"
check_eq "#1700 race: and the second gate's key counts too, under the same secret" "yes" "$( (. "$DIR/lib/ai-review-common.sh" && ar_helper_key_typed bbbb2222) && echo yes || echo no)"
check_eq "#1700 race: and neither left a spare secret or its lock behind" "helper-keys helper-keys.secret" "$(ls "$AI_REVIEW_STATE_DIR" | tr '\n' ' ' | sed 's/ $//')"
rm -f "$RACE.reached" "$RACE.go"
# A gate that finds another one still replacing waits for it, briefly, and never replaces it itself.
# With the lock held by nobody who will finish it, the wait runs out and the key is not recorded
# rather than being recorded under a secret the holder is about to replace (the sleep is injected).
fresh "$OLD" 0 "$GREEN"
mkdir -p "$AI_REVIEW_STATE_DIR/helper-keys.secret.lock"; printf 'short' > "$AI_REVIEW_STATE_DIR/helper-keys.secret"
gate_out="$(AR_HELPER_SECRET_SLEEP=true present "PR_REVIEW_READ=abc123 bash ~/.claude/hooks/lib/merge-when-ready.sh 7 --squash")"; grc=$?
check_eq "#1700 a replacement another gate holds and never finishes refuses the command" "2" "$grc"
check "#1700 saying the key could not be recorded" "could not be recorded" "$gate_out"
check_eq "#1700 and leaves the secret to the holder" "short" "$(cat "$AI_REVIEW_STATE_DIR/helper-keys.secret")"
# And when the holder does finish while it waits, it records under the holder's secret. The injected
# sleep plays the holder: on its first call it puts a secret in place and lets the lock go.
fresh "$OLD" 0 "$GREEN"
mkdir -p "$AI_REVIEW_STATE_DIR/helper-keys.secret.lock"; printf 'short' > "$AI_REVIEW_STATE_DIR/helper-keys.secret"
HOLDER_SECRET="$(printf 'c%.0s' $(seq 64))"
cat > "$WORKDIR/holder-finishes" <<EOS
#!/usr/bin/env bash
printf '%s' '$HOLDER_SECRET' > '$AI_REVIEW_STATE_DIR/helper-keys.secret'
rmdir '$AI_REVIEW_STATE_DIR/helper-keys.secret.lock' 2>/dev/null
exit 0
EOS
chmod +x "$WORKDIR/holder-finishes"
gate_out="$(AR_HELPER_SECRET_SLEEP="$WORKDIR/holder-finishes" present "PR_REVIEW_READ=abc123 bash ~/.claude/hooks/lib/merge-when-ready.sh 7 --squash")"; grc=$?
check_eq "#1700 a gate that waited out another's replacement records its key" "0" "$grc"
check_eq "#1700 under the secret the other put in place" "$HOLDER_SECRET" "$(cat "$AI_REVIEW_STATE_DIR/helper-keys.secret")"
check_eq "#1700 and the key counts" "yes" "$( (. "$DIR/lib/ai-review-common.sh" && ar_helper_key_typed abc123) && echo yes || echo no)"
mkdir -p "$AI_REVIEW_STATE_DIR/helper-keys.secret.lock"; printf 'short' > "$AI_REVIEW_STATE_DIR/helper-keys.secret"
# A lock left by a gate that died mid replacement is cleared once it is over a minute old, so one
# killed gate cannot stop every later key being recorded.
touch -t 202601010000 "$AI_REVIEW_STATE_DIR/helper-keys.secret.lock"
gate_out="$(AR_HELPER_SECRET_SLEEP=true present "PR_REVIEW_READ=abc123 bash ~/.claude/hooks/lib/merge-when-ready.sh 7 --squash")"; grc=$?
check_eq "#1700 a stale lock is cleared and the key recorded" "0" "$grc"
check_eq "#1700 and the lock is gone" "no" "$([ -e "$AI_REVIEW_STATE_DIR/helper-keys.secret.lock" ] && echo yes || echo no)"
# A COMMAND THAT NAMES THE RECORD (claude-config#1700). However the name is spelled or cased, a Bash
# command that writes into the folder, reads the secret, or calls the function that records a key is
# refused before it runs, since only the gate may make a record.
fresh "$OLD" 0 "$GREEN"
for forged in \
  ": > ~/.claude/state/ai-review/helper-keys/0123abcd" \
  "touch \"\$HOME/.claude/state/ai-review/HELPER-KEYS/0123abcd\"" \
  "cat ~/.claude/state/ai-review/helper-keys.secret" \
  ". ~/.claude/hooks/lib/ai-review-common.sh; ar_helper_key_record 5eed5eed5eed5eed" \
  ". ~/.claude/hooks/lib/ai-review-common.sh; touch \"\$(ar__helper_keys_dir)/x\""; do
  gate_out="$(present "$forged")"; grc=$?
  check_eq "#1700 a command naming the typed key record is refused: $forged" "2" "$grc"
  check "#1700 saying only the gate writes it: $forged" "only the lessons review's own gates write" "$gate_out"
done
check_eq "#1700 and nothing was recorded by any of them" "" "$(ls "$KEYS_DIR" 2>/dev/null)"
gate_out="$(present "ls ~/.claude/state/ai-review")"; grc=$?
check_eq "#1700 a command naming none of it is not refused" "0" "$grc"
# With no reader for the command's text (neither jq nor python3), a payload naming the record is
# refused, saying which reader is missing, rather than passed unread. The payload is built here and
# the gate run on a PATH holding only the basic tools it needs.
NOREAD="$WORKDIR/no-reader-bin"; mkdir -p "$NOREAD"
for t in bash cat dirname tr sed awk grep basename; do
  p="$(command -v "$t")" && ln -sf "$p" "$NOREAD/$t"
done
noread_payload="$(jq -nc --arg c ": > ~/.claude/state/ai-review/helper-keys/0123abcd" --arg d "$REPO" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}')"
gate_out="$(printf '%s' "$noread_payload" | PATH="$NOREAD" "$NOREAD/bash" "$DIR/pr-review-gate.sh" 2>&1)"; grc=$?
check_eq "#1700 with no reader, a command naming the record is refused" "2" "$grc"
check "#1700 naming the missing reader" "neither jq nor python3 is on PATH" "$gate_out"

fresh "$OLD" 3 "$GREEN"
: > "$ST/update-fails"
out="$(run 7 --squash)"; rc=$?
check_eq "#851 an update GitHub refuses stops it" "1" "$rc"
check "#851 with GitHub's reason" "merge conflict" "$out"

fresh "$OLD" 0 "$PENDING"
out="$(MWR_DEADLINE_SECONDS=0 run 7 --squash)"; rc=$?
check_eq "#851 out of time while still waiting is its own exit" "3" "$rc"
check "#851 saying what it was still waiting for" "checks still running" "$out"
check_eq "#851 and nothing merged" "0" "$(count gh-calls 'pr merge')"

fresh "$OLD" 0 "$PENDING"
out="$(MWR_MAX_POLLS=2 run 7 --squash)"; rc=$?
check_eq "#851 the wait is bounded by a count too, not only the clock (L704)" "3" "$rc"

fresh "$OLD" 0 "$GREEN"
: > "$ST/merged"
out="$(run 7 --squash)"; rc=$?
check_eq "#851 a pull request already merged is reported, not merged again" "0" "$rc"
check "#851 saying it was already merged" "already merged" "$out"
check_eq "#851 with no second merge" "0" "$(count gh-calls 'pr merge')"

# The merge itself refused because the head moved in the last second: it goes round again.
fresh "$OLD" 0 "$GREEN"
cat > "$STUBS/review-gate.sh" <<'EOS'
#!/usr/bin/env bash
cat >> "$ST/review-gate-payloads"; printf '\n' >> "$ST/review-gate-payloads"
# A push lands between the gates and the merge, once.
[ -e "$ST/pushed" ] || { : > "$ST/pushed"; printf '%s' "$NEWHEAD" > "$ST/head"; }
exit 0
EOS
out="$(NEWHEAD="$NEW" run 7 --squash)"; rc=$?
check_eq "#851 a head that moves under the merge is judged again, then merged" "0" "$rc"
check "#851 the first attempt was refused by GitHub's pin" "--match-head-commit $OLD" "$(grep 'pr merge' "$ST/gh-calls" | sed -n 1p)"
check "#851 and the merge that landed is the new head's" "--match-head-commit $NEW" "$(grep 'pr merge' "$ST/gh-calls" | tail -1)"
cat > "$STUBS/review-gate.sh" <<'EOS'
#!/usr/bin/env bash
cat >> "$ST/review-gate-payloads"; printf '\n' >> "$ST/review-gate-payloads"
exit 0
EOS

# =================================================================================================
# 6. The REAL checks gate decides: a red pull request is not merged, in the gate's own words (L52).
# =================================================================================================
fresh "$OLD" 0 "$RED"
out="$(MWR_RED_GATE="$DIR/block-red-merge.sh" run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#851 the real block-red-merge.sh refuses a red pull request through the helper" "1" "$rc"
check "#851 its reason is shown" "not green" "$out"
check_eq "#851 and nothing is merged" "0" "$(count gh-calls 'pr merge')"
fresh "$OLD" 0 "$GREEN"
out="$(MWR_RED_GATE="$DIR/block-red-merge.sh" run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#851 the real gate lets a green, up to date, pinned merge through the helper" "0" "$rc"

# The gate's behind refusal naming this helper is asserted on the real refusal, in
# test-block-red-merge.sh, rather than by reading its source here (L135).

# =================================================================================================
# 7. Its default pace (claude-config#1014). Every look reads the pull request through GitHub's
#    GraphQL allowance, which every session on the Mac shares, so with no MWR_POLL_SECONDS of its own
#    it looks once a minute, never every 30 seconds (both are paces the helper sets, not a measurement).
# =================================================================================================
fresh "$OLD" 0 "$PENDING"
printf '%s\n' "printf '%s' '$GREEN' > \"\$ST/rollup\"" > "$ST/on-sleep"
out="$(env -u MWR_POLL_SECONDS bash -c "cd '$REPO' && bash '$HELPER' 7 --squash" 2>&1)"; rc=$?
check_eq "#1014 with no poll setting it still waits and merges" "0" "$rc"
check_eq "#1014 the wait between looks defaults to 60 seconds" "60" "$(cat "$ST/sleeps" 2>/dev/null)"
check_eq "#1014 one pull request read per look, plus the read back after the merge" "3" "$(count gh-calls 'pr view 7')"

# =================================================================================================
# 8. A read GitHub fails to answer is tried again before the wait is thrown away (claude-config#1061).
#    On 2026-10-09 two queued merges each waited 7 to 16 minutes for CI and then stopped on ONE
#    "TLS handshake timeout" or "connection reset by peer" reading the compare. Stopping when it
#    cannot confirm the head contains main's tip stays: only a transport fault or a GitHub server
#    error is tried again, a few times over about a minute, and a real answer (a 404, a pull request
#    that is not there) is believed the first time. The retry waits go through the injected sleep,
#    at MWR_READ_RETRY_SECONDS (7 here, so they are told apart from the 30 second looks).
# =================================================================================================
fresh "$OLD" 0 "$GREEN"
printf '%s\n' 'Get "https://api.github.com/repos/acme/widget/compare/main...x": read tcp 10.0.0.2:51234->140.82.112.6:443: read: connection reset by peer' > "$ST/compare-fails"
out="$(run 7 --squash)"; rc=$?
check_eq "#1061 a compare that fails once and then answers still merges" "0" "$rc"
check "#1061 and the merge landed" "Merged #7 in acme/widget at ${OLD:0:7}" "$out"
check_eq "#1061 the compare was asked twice" "2" "$(count gh-calls 'compare/')"
check_eq "#1061 after one retry wait" "1" "$(count sleeps '^7$')"
check "#1061 the retry is said, with GitHub's own error" "connection reset by peer" "$out"

fresh "$OLD" 0 "$GREEN"
printf '%s\n' 'Get "https://api.github.com/repos/acme/widget/compare/main...x": net/http: TLS handshake timeout' > "$ST/compare-down"
# With no wait on the network (claude-config#2303, measured in its own section below), as in every
# run here whose network never comes back: these measure the four tries and how the stop says them.
out="$(MWR_NET_WAIT_SECONDS=0 run 7 --squash)"; rc=$?
check_eq "#1061 a compare that keeps failing still stops" "1" "$rc"
check "#1061 naming the last error" "TLS handshake timeout" "$out"
check "#1061 and saying it could not confirm the head contains main's tip" "could not connect to GitHub 4 times reading whether #7 contains the tip of main" "$out"
check_eq "#1061 nothing was merged on an unconfirmed read" "0" "$(count gh-calls 'pr merge')"
check_eq "#1061 the compare was tried four times" "4" "$(count gh-calls 'compare/')"
check_eq "#1061 with three retry waits between" "3" "$(count sleeps '^7$')"

fresh "$OLD" 0 "$GREEN"
printf '%s\n' 'gh: Not Found (HTTP 404)' > "$ST/compare-down"
out="$(run 7 --squash)"; rc=$?
check_eq "#1061 a compare GitHub refuses (404) stops at once" "1" "$rc"
check_eq "#1061 asked once, a real answer is not asked again" "1" "$(count gh-calls 'compare/')"
check_eq "#1061 with no retry wait" "0" "$(count sleeps '^7$')"
check_eq "#1061 and nothing merged" "0" "$(count gh-calls 'pr merge')"

fresh "$OLD" 0 "$GREEN"
printf '%s\n' 'HTTP 502: Bad Gateway (https://api.github.com/graphql)' > "$ST/view-fails"
out="$(run 7 --squash)"; rc=$?
check_eq "#1061 a pull request read that fails once with a server error still merges" "0" "$rc"
check_eq "#1061 after one retry wait for it" "1" "$(count sleeps '^7$')"

fresh "$OLD" 0 "$GREEN"
printf '%s\n' 'Post "https://api.github.com/graphql": net/http: TLS handshake timeout' > "$ST/view-down"
out="$(MWR_NET_WAIT_SECONDS=0 run 7 --squash)"; rc=$?
check_eq "#1061 a pull request read that keeps failing stops" "1" "$rc"
check "#1061 naming GitHub's last error" "TLS handshake timeout" "$out"
check_eq "#1061 nothing merged" "0" "$(count gh-calls 'pr merge')"
check_eq "#1061 three retry waits" "3" "$(count sleeps '^7$')"

fresh "$OLD" 0 "$GREEN"
printf '%s\n' 'GraphQL: Could not resolve to a PullRequest with the number of 7. (repository.pullRequest)' > "$ST/view-down"
out="$(run 7 --squash)"; rc=$?
check_eq "#1061 a pull request GitHub says is not there stops at once" "1" "$rc"
check_eq "#1061 with no retry wait" "0" "$(count sleeps '^7$')"
check_eq "#1061 asked once" "1" "$(count gh-calls 'pr view 7')"

# The read back after the merge: a transient failure there is tried again, so the merge is reported
# as merged rather than as a head that moved.
fresh "$OLD" 0 "$GREEN"
printf '%s\n' 'read tcp 10.0.0.2:51234->140.82.112.6:443: i/o timeout' > "$ST/readback-fails"
out="$(run 7 --squash)"; rc=$?
check_eq "#1061 a read back that fails once still reports the merge" "0" "$rc"
check "#1061 as merged" "Merged #7 in acme/widget at ${OLD:0:7}" "$out"
check_not "#1061 never as a head that moved" "head moved" "$out"
check_eq "#1061 exactly one merge" "1" "$(count gh-calls 'pr merge')"

# A sign in GitHub refused is asked again too, as its own outcome (claude-config#1615). On 2026-10-23,
# at load averages up to 342, merge-when-ready.sh 1606 stopped three times on "HTTP 401: Requires
# authentication" while waiting its turn, and a read seconds later answered: the request had gone out
# with no token. It is asked again by the same rule, a token read is made after each refusal, and a
# refusal that outlasts the tries says so in its own words, never as a pull request GitHub could not
# show (L11). Nothing merges on it.
# SIGNIN, GitHub's words for it, is set by lib/merge-when-ready-harness.sh.
fresh "$OLD" 0 "$GREEN"
printf '%s\n' "$SIGNIN" > "$ST/view-fails"
out="$(run 7 --squash)"; rc=$?
check_eq "#1615 a pull request read whose sign in is refused once still merges" "0" "$rc"
check "#1615 and the merge landed" "Merged #7 in acme/widget at ${OLD:0:7}" "$out"
check_eq "#1615 after one retry wait" "1" "$(count sleeps '^7$')"
check "#1615 the retry is said as the sign in refused" "GitHub refused the sign in reading pull request #7 (try 1 of 4" "$out"
check "#1615 with what the token read straight after came to" "a token read straight after came back present" "$out"
check_eq "#1615 one token read, after the one refusal" "1" "$(count gh-calls '^auth token')"
check_not "#1615 the token is never printed" "stand-in" "$out"

fresh "$OLD" 0 "$GREEN"
printf '%s\n' "$SIGNIN" > "$ST/view-down"; : > "$ST/token-empty"
out="$(run 7 --squash)"; rc=$?
check_eq "#1615 a sign in refused on every try still stops" "1" "$rc"
check "#1615 said as GitHub refusing the sign in, four times" "GitHub refused the sign in 4 times" "$out"
check "#1615 naming the pull request it was reading" "reading pull request #7 in acme/widget" "$out"
check "#1615 with what each token read came to" "came back empty, empty, empty, empty" "$out"
check_not "#1615 never as a pull request that could not be read" "could not read pull request" "$out"
check_eq "#1615 nothing merged on a refused sign in" "0" "$(count gh-calls 'pr merge')"
check_eq "#1615 three retry waits, through the injected sleep" "3" "$(count sleeps '^7$')"

fresh "$OLD" 0 "$GREEN"
printf '%s\n' 'gh: Requires authentication (HTTP 401)' > "$ST/compare-fails"
out="$(run 7 --squash)"; rc=$?
check_eq "#1615 a compare whose sign in is refused once still merges" "0" "$rc"
check_eq "#1615 the compare was asked twice" "2" "$(count gh-calls 'compare/')"

fresh "$OLD" 0 "$GREEN"
printf '%s\n' 'gh: Requires authentication (HTTP 401)' > "$ST/compare-down"
out="$(run 7 --squash)"; rc=$?
check_eq "#1615 a compare refused on every try stops" "1" "$rc"
check "#1615 and says the sign in was refused" "GitHub refused the sign in 4 times" "$out"
check_eq "#1615 and nothing merged" "0" "$(count gh-calls 'pr merge')"

# A connection gh could not make is asked again too, as its own outcome (claude-config#1675). On
# 2026-10-24 #1640 stopped at 41m 36s on "could not read pull request #1640 ... (error connecting to
# api.github.com)" with no retry line: gh prints that, and no HTTP status, when it could not reach
# GitHub at all, so GitHub never saw the read. It is asked again by the same rule, through the
# injected sleep, and one that outlasts the tries says so in its own words (L11). Nothing merges on it.
# CONNECT, gh's words for it, is set by lib/merge-when-ready-harness.sh.
fresh "$OLD" 0 "$GREEN"
printf '%s\n' "$CONNECT" > "$ST/view-fails"
out="$(run 7 --squash)"; rc=$?
check_eq "#1675 a pull request read gh could not connect for once still merges" "0" "$rc"
check "#1675 and the merge landed" "Merged #7 in acme/widget at ${OLD:0:7}" "$out"
check_eq "#1675 after one retry wait, through the injected sleep" "1" "$(count sleeps '^7$')"
check "#1675 the retry is said as the connection, not GitHub not answering" "Could not connect to GitHub reading pull request #7 (try 1 of 4" "$out"
check_not "#1675 never said as a refused sign in" "refused the sign in" "$out"

fresh "$OLD" 0 "$GREEN"
printf '%s\n' "$CONNECT" > "$ST/view-down"
out="$(MWR_NET_WAIT_SECONDS=0 run 7 --squash)"; rc=$?
check_eq "#1675 a connection never made on any try still stops" "1" "$rc"
check "#1675 said as the connection, four times, naming what it was reading" "could not connect to GitHub 4 times reading pull request #7 in acme/widget from GitHub (error connecting to api.github.com)" "$out"
check "#1675 and that GitHub never answered" "GitHub never answered" "$out"
check_not "#1675 never as a pull request that could not be read" "could not read pull request" "$out"
check_eq "#1675 the read was tried four times" "4" "$(count gh-calls 'pr view 7')"
check_eq "#1675 three retry waits" "3" "$(count sleeps '^7$')"
check_eq "#1675 nothing merged" "0" "$(count gh-calls 'pr merge')"

fresh "$OLD" 0 "$GREEN"
printf '%s\n' "$CONNECT" > "$ST/compare-down"
out="$(MWR_NET_WAIT_SECONDS=0 run 7 --squash)"; rc=$?
check_eq "#1675 a compare gh could never connect for stops" "1" "$rc"
check "#1675 and says so" "could not connect to GitHub 4 times reading whether #7 contains the tip of main" "$out"
check_eq "#1675 and nothing merged" "0" "$(count gh-calls 'pr merge')"

# Every network failure gh prints is that outcome, not only "error connecting to" (claude-config#1735).
# On 2026-10-25, with #1675 installed, #1732 stopped at 35m 35s with no retry line on this, word for
# word: no local port was left to connect from, so the request never left this Mac.
DIAL='Post "https://api.github.com/graphql": dial tcp 140.82.113.6:443: connect: can'"'"'t assign requested address'
fresh "$OLD" 0 "$GREEN"
printf '%s\n' "$DIAL" > "$ST/view-fails"
out="$(run 7 --squash)"; rc=$?
check_eq "#1735 a pull request read whose dial failed once still merges" "0" "$rc"
check "#1735 and the merge landed" "Merged #7 in acme/widget at ${OLD:0:7}" "$out"
check_eq "#1735 after one retry wait" "1" "$(count sleeps '^7$')"
check "#1735 the retry is said as the connection" "Could not connect to GitHub reading pull request #7 (try 1 of 4: $DIAL)" "$out"

fresh "$OLD" 0 "$GREEN"
printf '%s\n' "$DIAL" > "$ST/view-down"
out="$(MWR_NET_WAIT_SECONDS=0 run 7 --squash)"; rc=$?
check_eq "#1735 a dial that fails on every try still stops" "1" "$rc"
check "#1735 said as the connection, four times, with the error" "could not connect to GitHub 4 times reading pull request #7 in acme/widget from GitHub ($DIAL)" "$out"
check_not "#1735 never as a pull request that could not be read" "could not read pull request" "$out"
check_eq "#1735 the read was tried four times" "4" "$(count gh-calls 'pr view 7')"
check_eq "#1735 nothing merged" "0" "$(count gh-calls 'pr merge')"

# A connection that was made and then reset is said as lost, never as one gh could not make (L11).
RESET='Get "https://api.github.com/repos/acme/widget/compare/main...x": read tcp 10.0.0.2:57411->140.82.112.6:443: read: connection reset by peer'
fresh "$OLD" 0 "$GREEN"
printf '%s\n' "$RESET" > "$ST/compare-down"
out="$(MWR_NET_WAIT_SECONDS=0 run 7 --squash)"; rc=$?
check_eq "#1735 a compare whose connection is reset on every try stops" "1" "$rc"
check "#1735 each retry says the connection was lost" "Lost the connection to GitHub reading whether #7 contains the tip of main (try 1 of 4" "$out"
check "#1735 and the stop says it was lost four times" "lost the connection to GitHub 4 times reading whether #7 contains the tip of main" "$out"
check_not "#1735 never that gh could not reach GitHub" "could not reach it" "$out"
check_eq "#1735 and nothing merged" "0" "$(count gh-calls 'pr merge')"

# A network outage is waited through, not stopped on after four tries (claude-config#2303). On
# 2026-11-05 an outage of about 40 minutes stopped all ten helpers a session had queued, each after
# four tries a minute apart, and every one had to be started again by hand with the queue order
# rebuilt. A read the network never carried to GitHub is safe to ask again, so while every try fails
# that way the helper keeps waiting, saying it is waiting on the network with how long, up to
# MWR_NET_WAIT_SECONDS (3600 by default), and carries on when GitHub answers. The sections above run
# with that wait at 0, since they measure the four tries and their wording. Every wait here is the
# injected sleep (L524): an outage of 40 minutes is crossed in no real time.
# The long waits below ask again every NET_RETRY seconds rather than the 7 above (claude-config#2674):
# at 7 the 40 minute outage and the 60 minute limit took about 860 tries of the helper's whole read
# path, nearly half this suite's time, where 40 takes about 150. It stays under the 120 second
# heartbeat, so a line is still said only every few tries, and apart from the 30 second looks.
NET_RETRY=40
net_back_at(){ local i; for i in $(seq 1 600); do printf '[ "$(cat "$ST/clock")" -lt %s ] || rm -f "$ST/view-down"\n' "$1" >> "$ST/on-sleep"; done; }
fresh "$OLD" 0 "$GREEN"
printf '%s\n' "$CONNECT" > "$ST/view-down"; net_back_at 1002400
out="$(MWR_READ_RETRY_SECONDS=$NET_RETRY run 7 --squash)"; rc=$?
check_eq "#2303 a pull request read through a 40 minute outage merges" "0" "$rc"
check "#2303 and the merge landed" "Merged #7 in acme/widget at ${OLD:0:7}" "$out"
check_eq "#2303 it waited past the 40 minutes" "yes" "$( [ "$(( $(cat "$ST/clock") - 1000000 ))" -ge 2400 ] && echo yes || echo no)"
check "#2303 saying it is waiting on the network, with how long" "Waiting on the network: GitHub has not been reachable for 2m 00s reading pull request #7" "$out"
check "#2303 and how long it will wait" "stops once it has waited 60m (MWR_NET_WAIT_SECONDS)" "$out"
# Worked out from the settings this suite sets, not measured: said at the end of the first round, its
# three waits of 40s at 2m, then on the first try at least the 120s heartbeat after the last line.
# Every try falls on a multiple of 40s, and 120 is one, so the lines fall every 2m and the last line
# before 40m is 38m 00s.
check "#2303 a later line says the wait has grown" "Waiting on the network: GitHub has not been reachable for 38m 00s" "$out"
check "#2303 saying when GitHub answers again" "GitHub answered again reading pull request #7 after 40m" "$out"
check_eq "#2303 the four tries before the wait are said as today, three retry lines" "3" "$(printf '%s\n' "$out" | grep -c 'Could not connect to GitHub reading pull request #7 (try')"
net_lines="$(printf '%s\n' "$out" | grep -c 'Waiting on the network')"
check_eq "#2303 the wait is said about every 2 minutes, not on every try ($net_lines lines)" "yes" "$( [ "$net_lines" -ge 15 ] && [ "$net_lines" -le 25 ] && echo yes || echo no)"
check_not "#2303 never out of time" "Out of time" "$out"

# The outer limit: a network that never comes back still ends in a stop, at MWR_NET_WAIT_SECONDS.
fresh "$OLD" 0 "$GREEN"
printf '%s\n' "$CONNECT" > "$ST/view-down"
out="$(MWR_READ_RETRY_SECONDS=$NET_RETRY run 7 --squash)"; rc=$?
check_eq "#2303 a network that never comes back still stops" "1" "$rc"
waited=$(( $(cat "$ST/clock") - 1000000 ))
check_eq "#2303 at the 60 minute limit, within one round of tries ($waited s)" "yes" "$( [ "$waited" -ge 3600 ] && [ "$waited" -le 3660 ] && echo yes || echo no)"
check "#2303 the stop says how long it waited on the network" "Stopped: waited 60m " "$out"
check "#2303 naming the setting" "on the network (MWR_NET_WAIT_SECONDS), and could not connect to GitHub" "$out"
check "#2303 and what it was reading, as the connection" "times reading pull request #7 in acme/widget from GitHub (error connecting to api.github.com)" "$out"
check_eq "#2303 nothing merged" "0" "$(count gh-calls 'pr merge')"

fresh "$OLD" 0 "$GREEN"
printf '%s\n' "$CONNECT" > "$ST/view-down"
out="$(MWR_NET_WAIT_SECONDS=600 MWR_READ_RETRY_SECONDS=$NET_RETRY run 7 --squash)"; rc=$?
waited=$(( $(cat "$ST/clock") - 1000000 ))
check_eq "#2303 MWR_NET_WAIT_SECONDS sets the limit" "1" "$rc"
check_eq "#2303 a 10 minute limit stops near 10 minutes ($waited s)" "yes" "$( [ "$waited" -ge 600 ] && [ "$waited" -le 660 ] && echo yes || echo no)"

# Controls (L497): an answer GitHub gave is handled as today, before and during the wait.
fresh "$OLD" 0 "$GREEN"
printf '%s\n' 'HTTP 502: Bad Gateway (https://api.github.com/graphql)' > "$ST/view-down"
out="$(run 7 --squash)"; rc=$?
check_eq "#2303 control: GitHub's server failing on every try stops after four as today" "1" "$rc"
check_eq "#2303 control: three retry waits" "3" "$(count sleeps '^7$')"
check_not "#2303 control: never said as waiting on the network" "Waiting on the network" "$out"

fresh "$OLD" 0 "$GREEN"
printf '%s\n' "$SIGNIN" > "$ST/view-fails"; printf '%s\n' "$CONNECT" > "$ST/view-down"
out="$(run 7 --squash)"; rc=$?
check_eq "#2303 control: a round with a refused sign in in it is not waited through" "1" "$rc"
check_eq "#2303 control: four tries" "4" "$(count gh-calls 'pr view 7')"
check_not "#2303 control: and not said as waiting on the network" "Waiting on the network" "$out"

fresh "$OLD" 0 "$GREEN"
printf '%s\n' "$CONNECT" > "$ST/view-down"
for _ in $(seq 1 600); do printf '%s\n' '[ "$(cat "$ST/clock")" -lt 1000600 ] || printf "%s\n" "HTTP 502: Bad Gateway (https://api.github.com/graphql)" > "$ST/view-down"' >> "$ST/on-sleep"; done
out="$(MWR_READ_RETRY_SECONDS=$NET_RETRY run 7 --squash)"; rc=$?
waited=$(( $(cat "$ST/clock") - 1000000 ))
check_eq "#2303 control: GitHub answering with a server error during the wait stops as today" "1" "$rc"
check_eq "#2303 control: soon after it answered, not at the limit ($waited s)" "yes" "$( [ "$waited" -lt 700 ] && echo yes || echo no)"
check "#2303 control: said as GitHub's error" "Bad Gateway" "$out"
check_eq "#2303 control: nothing merged" "0" "$(count gh-calls 'pr merge')"

# GitHub answering the merge itself with "Something went wrong" (claude-config#2289). On 2026-11-05
# a merge in a work repository stopped three times in three minutes on "GraphQL: Something went wrong
# while executing your query", with every gate allowing it, and a fourth run five minutes later
# merged. The pull request is read back first: merged is reported as merged; still open at the same
# head, every gate is asked again and the merge, pinned to that head, is tried again
# MWR_MERGE_RETRY_SECONDS (120) later, MWR_MERGE_TRIES (3) times in all, then it stops naming the
# error. The waits are the injected sleep (L524).
# WRONG, GitHub's words for it, is set by lib/merge-when-ready-harness.sh.
fresh "$OLD" 0 "$GREEN"
printf '%s\n%s\n' "$WRONG" "$WRONG" > "$ST/merge-fails"
out="$(run 7 --squash)"; rc=$?
check_eq "#2289 a merge GitHub answers Something went wrong twice merges on the third try" "0" "$rc"
check "#2289 and the merge landed" "Merged #7 in acme/widget at ${OLD:0:7}" "$out"
check_eq "#2289 three merge commands" "3" "$(count gh-calls 'pr merge')"
check_eq "#2289 every one pinned to the head the gates allowed" "3" "$(count gh-calls "pr merge 7 .*--match-head-commit $OLD")"
check_eq "#2289 every gate asked again before each try" "3" "$(grep -c 'match-head-commit' "$ST/red-gate-payloads")"
check_eq "#2289 two waits of 2 minutes between the tries" "2" "$(count sleeps '^120$')"
check "#2289 the retry is said, with GitHub's error and that nothing merged" "GitHub answered the merge of #7 at ${OLD:0:7} with Something went wrong (try 1 of 3: $WRONG), and reading it back shows it still open at that head, so nothing merged" "$out"
check_eq "#2289 the pull request was read back after each merge" "yes" "$( [ "$(count gh-calls 'pr view 7')" -ge 6 ] && echo yes || echo no)"

fresh "$OLD" 0 "$GREEN"
printf '%s\n%s\n%s\n%s\n' "$WRONG" "$WRONG" "$WRONG" "$WRONG" > "$ST/merge-fails"
out="$(run 7 --squash)"; rc=$?
check_eq "#2289 a merge GitHub keeps answering Something went wrong stops" "1" "$rc"
check_eq "#2289 after three tries" "3" "$(count gh-calls 'pr merge')"
check "#2289 the stop names the error and the tries" "Stopped: GitHub answered the merge of #7 at ${OLD:0:7} with Something went wrong 3 times, 2m apart, and reading it back shows it still open at that head, so nothing merged: $WRONG" "$out"
check "#2289 and says what to do" "run the same command again" "$out"
check_eq "#2289 nothing merged" "no" "$( [ -e "$ST/merged" ] && echo yes || echo no)"

# Merged though gh printed the error: the read back reports it merged, with no second merge.
fresh "$OLD" 0 "$GREEN"
printf '%s\n' "$WRONG" > "$ST/merge-lands-fails"
out="$(run 7 --squash)"; rc=$?
check_eq "#2289 a merge that landed though GitHub answered Something went wrong is reported merged" "0" "$rc"
check "#2289 as merged, naming what gh said" "Merged #7 in acme/widget at ${OLD:0:7} (gh exited 1 after merging: GraphQL: Something went wrong" "$out"
check_eq "#2289 and merged once" "1" "$(count gh-calls 'pr merge')"

# The other shape of merged but exited non zero (claude-config#2687): gh run from a detached HEAD
# merges and then fails on the local branch, as the global CLAUDE.md records for --delete-branch.
# The read back still finds it merged, and the branch on GitHub is still deleted.
fresh "$OLD" 0 "$GREEN"
printf '%s\n' 'could not determine current branch: failed to run git: fatal: not a symbolic ref' > "$ST/merge-lands-fails"
out="$(run 7 --squash --delete-branch)"; rc=$?
check_eq "#2687 a merge gh failed after, from a detached HEAD, is reported merged" "0" "$rc"
check "#2687 naming what gh said" "Merged #7 in acme/widget at ${OLD:0:7} (gh exited 1 after merging: could not determine current branch" "$out"
check "#2687 and the branch is still deleted" "Deleted its branch feat/x." "$out"
check_eq "#2687 once" "feat/x" "$(cat "$ST/deleted" 2>/dev/null)"
check_eq "#2687 with one merge" "1" "$(count gh-calls 'pr merge')"

# The head moving during the wait is judged as a new head: the old head is never merged again.
fresh "$OLD" 0 "$GREEN"
printf '%s\n' "$WRONG" > "$ST/merge-fails"
for _ in $(seq 1 20); do printf '%s\n' "grep -q 'pr merge' \"\$ST/gh-calls\" && printf '%s' $NEW > \"\$ST/head\"" >> "$ST/on-sleep"; done
out="$(run 7 --squash)"; rc=$?
check_eq "#2289 a head that moved during the wait merges as the new head" "0" "$rc"
check "#2289 merged at the new head" "Merged #7 in acme/widget at ${NEW:0:7}" "$out"
check_eq "#2289 the old head was tried once, never again" "1" "$(count gh-calls "pr merge 7 .*--match-head-commit $OLD")"
check_eq "#2289 the gates judged the new head before it merged" "yes" "$(grep -q "match-head-commit $NEW" "$ST/red-gate-payloads" && echo yes || echo no)"

# Control (L497): any other merge error stops at once, as before.
fresh "$OLD" 0 "$GREEN"
printf '%s\n' 'GraphQL: Pull request is not mergeable (mergePullRequest)' > "$ST/merge-fails"
out="$(run 7 --squash)"; rc=$?
check_eq "#2289 control: another merge error stops at once" "1" "$rc"
check_eq "#2289 control: one merge command" "1" "$(count gh-calls 'pr merge')"
check "#2289 control: naming it" "Stopped: gh pr merge did not merge #7 at ${OLD:0:7}: GraphQL: Pull request is not mergeable" "$out"

# The helper writes its own log (claude-config#2304). Started as `... 2>&1 | tee <log>`, a background
# helper reports tee's exit, not its own: on 2026-11-05 ten helpers stopped on a network outage and
# every one was reported as "completed (exit code 0)", the same as a merge. With --log=<file> the
# helper appends everything it says to the file itself, so no pipe is needed and the exit the session
# is told is the helper's, and it ends the file with that exit and what it means, so the log alone
# cannot read a stop as a finish either.
LOGS="$WORKDIR/logs"; mkdir -p "$LOGS"
fresh "$OLD" 0 "$GREEN"; rm -f "$LOGS/a.log"
out="$(run 7 --squash --log="$LOGS/a.log")"; rc=$?
check_eq "#2304 a merge run with --log exits as the helper does" "0" "$rc"
check "#2304 still says it on its own output" "Merged #7 in acme/widget at ${OLD:0:7}" "$out"
check "#2304 the log holds what it said" "Merged #7 in acme/widget at ${OLD:0:7}" "$(cat "$LOGS/a.log" 2>/dev/null)"
check "#2304 the log's last line is the exit and what it means" "merge-when-ready: exit 0: merged" "$(tail -1 "$LOGS/a.log" 2>/dev/null)"
check_not "#2304 --log is never handed to gh" "--log" "$(grep 'pr merge' "$ST/gh-calls")"

fresh "$OLD" 0 "$GREEN"; rm -f "$LOGS/b.log"; printf '%s' 'CI is red.' > "$ST/red-gate-deny"
out="$(run 7 --squash --log "$LOGS/b.log")"; rc=$?
check_eq "#2304 a stopped run with --log exits 1, never 0" "1" "$rc"
check "#2304 the log holds the stop" "Stopped: block-red-merge.sh refused the merge of #7" "$(cat "$LOGS/b.log" 2>/dev/null)"
check "#2304 and ends saying it stopped, nothing merged" "merge-when-ready: exit 1: stopped, needing a person; nothing was merged by this stop" "$(tail -1 "$LOGS/b.log" 2>/dev/null)"
check_not "#2304 a stopped log never reads as merged" "exit 0" "$(tail -1 "$LOGS/b.log" 2>/dev/null)"

# A log is appended to, each run marked where it starts, so a log kept across runs reads run by run.
fresh "$OLD" 0 "$GREEN"
out="$(run 7 --squash --log="$LOGS/b.log")"; rc=$?
check_eq "#2304 a second run appended to the same log" "2" "$(grep -c '^merge-when-ready: started' "$LOGS/b.log")"
check "#2304 its own result last" "merge-when-ready: exit 0: merged" "$(tail -1 "$LOGS/b.log" 2>/dev/null)"

fresh "$OLD" 0 "$GREEN"
out="$(run 7 --squash --log="$LOGS/no-such-folder/c.log")"; rc=$?
check_eq "#2304 a log that cannot be written is refused before anything" "64" "$rc"
check "#2304 saying so" "--log $LOGS/no-such-folder/c.log cannot be written" "$out"
check_eq "#2304 and GitHub was never asked" "0" "$(count gh-calls 'pr view')"

# A relative --log names a file relative to where the caller ran the helper. The helper moves to the
# top of the checkout before it reads anything, so a path kept as given would send every line after
# that move into a second file the caller never named (lessons review of #2386). Started from a
# folder inside the checkout, every line, the exit line included, lands in the one file named.
mkdir -p "$REPO/sub"; rm -f "$REPO/sub/rel.log" "$REPO/rel.log"
fresh "$OLD" 0 "$GREEN"
out="$( (cd "$REPO/sub" && bash "$HELPER" 7 --squash --log=rel.log 2>&1) )"; rc=$?
check_eq "#2304 a relative --log run still merges" "0" "$rc"
check "#2304 a relative --log keeps the start line where the caller named it" "merge-when-ready: started for #7" "$(cat "$REPO/sub/rel.log" 2>/dev/null)"
check "#2304 a relative --log keeps the merge line there too, after the helper moves" "Merged #7 in acme/widget at ${OLD:0:7}" "$(cat "$REPO/sub/rel.log" 2>/dev/null)"
check_eq "#2304 a relative --log ends with the exit line in the named file" "merge-when-ready: exit 0: merged." "$(tail -1 "$REPO/sub/rel.log" 2>/dev/null)"
check_eq "#2304 a relative --log writes no second file at the checkout's top" "no" "$([ -e "$REPO/rel.log" ] && echo yes || echo no)"
rm -f "$REPO/sub/rel.log" "$REPO/rel.log"

# A relative --log whose folder does not exist is refused, naming that folder, before anything runs.
fresh "$OLD" 0 "$GREEN"
out="$( (cd "$REPO/sub" && bash "$HELPER" 7 --squash --log=missing/d.log 2>&1) )"; rc=$?
check_eq "#2304 a relative --log into a missing folder is refused" "64" "$rc"
check "#2304 naming the folder that does not exist" "does not exist" "$out"
check_eq "#2304 and GitHub was never asked for it" "0" "$(count gh-calls 'pr view')"
check_eq "#2304 and nothing was written at the checkout's top" "no" "$([ -e "$REPO/missing" ] && echo yes || echo no)"
rmdir "$REPO/sub" 2>/dev/null

# An empty --log= names no file, so it is refused rather than the run going on with no log at all.
fresh "$OLD" 0 "$GREEN"
out="$(run 7 --squash --log=)"; rc=$?
check_eq "#2304 an empty --log= is refused" "64" "$rc"
check "#2304 saying it needs a file" "--log needs a file." "$out"
check_eq "#2304 and GitHub was never asked for the empty one" "0" "$(count gh-calls 'pr view')"

# Refused sign ins are counted across runs too (claude-config#1626): each one this run sees is written
# to this Mac's ledger, and once the last day holds five, the run says so as a rate across runs, once,
# where it announces the retry. Four from earlier runs are seeded, inside the day on the fake clock.
SIGNIN_LEDGER="$MT_SIGNIN_LEDGER_DIR/refusals.tsv"
seed_signins(){
  rm -rf "$MT_SIGNIN_LEDGER_DIR"; mkdir -p "$MT_SIGNIN_LEDGER_DIR"
  for t in 990000 995000 999000 999500; do
    printf '%s\thost\tsess_x\trun-%s\tmerge-when-ready.sh\trefused\tempty\n' "$t" "$t" >> "$SIGNIN_LEDGER"
  done
}
seed_signins
fresh "$OLD" 0 "$GREEN"
printf '%s\n' "$SIGNIN" > "$ST/view-fails"
out="$(run 7 --squash)"; rc=$?
check_eq "#1626 a refusal that brings the day to five still merges once answered" "0" "$rc"
check "#1626 and the day's count is said as a rate across runs" "Across runs, this Mac has recorded 5 failed GitHub sign ins in the last 24 hours (5 refused by GitHub, 0 with no token gh could read), in 5 runs" "$out"
check_eq "#1626 one line written for the one refusal" "5" "$(wc -l < "$SIGNIN_LEDGER" | tr -d ' ')"
own_run="$(tail -1 "$SIGNIN_LEDGER" | cut -f4)"
check_eq "#1626 the gates it asks are handed its run, so a run and its gates count as one" "$own_run" "$(tail -1 "$ST/verify-gate-runs" 2>/dev/null)"
check_eq "#1626 recorded as the helper's" "merge-when-ready.sh" "$(tail -1 "$SIGNIN_LEDGER" | cut -f5)"

seed_signins
fresh "$OLD" 0 "$GREEN"
printf '%s\n' "$SIGNIN" > "$ST/view-down"
out="$(run 7 --squash)"; rc=$?
check_eq "#1626 a run refused on every try still stops" "1" "$rc"
check_eq "#1626 the count across runs is said once, not again at the stop" "1" "$(grep -c 'Across runs, this Mac has recorded' <<< "$out")"
check_eq "#1626 every refusal of the run is recorded" "8" "$(wc -l < "$SIGNIN_LEDGER" | tr -d ' ')"

# Under the threshold, nothing is said beyond what #1615 already says.
rm -rf "$MT_SIGNIN_LEDGER_DIR"
fresh "$OLD" 0 "$GREEN"
printf '%s\n' "$SIGNIN" > "$ST/view-fails"
out="$(run 7 --squash)"; rc=$?
check_not "#1626 one refusal in a day says nothing across runs" "Across runs" "$out"

# A ledger that cannot be written is said once, and the merge goes on (L95).
printf 'x' > "$WORKDIR/signin-file"
fresh "$OLD" 0 "$GREEN"
printf '%s\n' "$SIGNIN" > "$ST/view-fails"
out="$(MT_SIGNIN_LEDGER_DIR="$WORKDIR/signin-file/x" run 7 --squash)"; rc=$?
check_eq "#1626 an unwritable ledger still merges" "0" "$rc"
check "#1626 and says the refusal was not recorded" "This refusal could not be recorded in $WORKDIR/signin-file/x/refusals.tsv" "$out"
rm -rf "$MT_SIGNIN_LEDGER_DIR"

# The gates it asks run under no harness timeout, so they are handed a longer read budget than a typed
# merge's gate keeps: on 2026-10-23, at a load average of 342, require-verification-run.sh spent its 15
# seconds before it could read areas.json, twice (claude-config#1615).
fresh "$OLD" 0 "$GREEN"
out="$(run 7 --squash)"; rc=$?
check_eq "#1615 a green merge" "0" "$rc"
check_eq "#1615 the verification gate is handed the helper's read budget" "90" "$(sort -u "$ST/verify-gate-budgets" | tr '\n' ' ' | sed 's/ $//')"
check_eq "#1615 and so is the CI gate" "90" "$(sort -u "$ST/red-gate-budgets" | tr '\n' ' ' | sed 's/ $//')"

# Its default retry pace: about a minute in all, through the injected sleep.
fresh "$OLD" 0 "$GREEN"
printf '%s\n' 'Get "https://api.github.com/repos/acme/widget/compare/main...x": net/http: TLS handshake timeout' > "$ST/compare-down"
out="$(env -u MWR_READ_RETRY_SECONDS MWR_NET_WAIT_SECONDS=0 bash -c "cd '$REPO' && bash '$HELPER' 7 --squash" 2>&1)"; rc=$?
check_eq "#1061 with no retry setting it still stops when GitHub stays unreachable" "1" "$rc"
check_eq "#1061 the default retry waits are 20 seconds each, a minute in all" "20 20 20" "$(tr '\n' ' ' < "$ST/sleeps" | sed 's/ $//')"

# =================================================================================================
# 9. A fast check reporting first is not the head's CI (claude-config#1087). On 2026-10-12 Slate
#    #3645 was merged at 22:25:56 with one check on its head, a green one from a separate fast
#    workflow, while its CI run had existed since 22:24:52 waiting on a concurrency group: its jobs
#    were created at 22:26:05. The helper read "every reported check is green" as "the head is green".
#    The run itself is the record that more is coming, so an unfinished workflow run for the head is
#    waited on like a pending check, whatever its checks will be called.
# =================================================================================================
FAST='[{"__typename":"CheckRun","name":"merge-gap","workflowName":"Merge-gap guard","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-10-12T22:24:49Z"}]'
FAST_CI_RUNNING='[{"__typename":"CheckRun","name":"merge-gap","workflowName":"Merge-gap guard","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-10-12T22:24:49Z"},{"__typename":"CheckRun","name":"build","workflowName":"CI","status":"IN_PROGRESS","conclusion":"","startedAt":"2026-10-12T22:26:07Z"}]'
FAST_CI_GREEN='[{"__typename":"CheckRun","name":"merge-gap","workflowName":"Merge-gap guard","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-10-12T22:24:49Z"},{"__typename":"CheckRun","name":"build","workflowName":"CI","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-10-12T22:26:07Z"}]'
RUNS_CI_PENDING='{"total_count":2,"workflow_runs":[{"name":"CI","status":"pending","conclusion":null},{"name":"Merge-gap guard","status":"completed","conclusion":"success"}]}'
RUNS_CI_RUNNING='{"total_count":2,"workflow_runs":[{"name":"CI","status":"in_progress","conclusion":null},{"name":"Merge-gap guard","status":"completed","conclusion":"success"}]}'
RUNS_DONE='{"total_count":2,"workflow_runs":[{"name":"CI","status":"completed","conclusion":"success"},{"name":"Merge-gap guard","status":"completed","conclusion":"success"}]}'

fresh "$OLD" 0 "$FAST"
printf '%s' "$RUNS_CI_PENDING" > "$ST/runs"
printf '%s\n%s\n' \
  "printf '%s' '$FAST_CI_RUNNING' > \"\$ST/rollup\"; printf '%s' '$RUNS_CI_RUNNING' > \"\$ST/runs\"" \
  "printf '%s' '$FAST_CI_GREEN' > \"\$ST/rollup\"; printf '%s' '$RUNS_DONE' > \"\$ST/runs\"" > "$ST/on-sleep"
out="$(run 7 --squash)"; rc=$?
check_eq "#1087 a head whose only reported check is a fast green one still merges once its CI is green" "0" "$rc"
check "#1087 it waited, naming the run whose checks had not registered" "CI (pending)" "$out"
check_eq "#1087 it looked three times: the fast check alone, CI running, CI green" "2" "$(count sleeps '^30$')"
check_eq "#1087 the gates were asked only once, after CI finished" "1" "$(grep -c 'gh pr merge' "$ST/red-gate-payloads" 2>/dev/null || echo 0)"
check_eq "#1087 exactly one merge" "1" "$(count gh-calls 'pr merge')"
check "#1087 the runs were read for the head being merged" "actions/runs?head_sha=$OLD" "$(cat "$ST/gh-calls")"

# No check has reported at all, past the grace for a fresh head, but a run exists: still waited on.
fresh "$OLD" 0 '[]'
printf '%s' '{"total_count":1,"workflow_runs":[{"name":"CI","status":"queued","conclusion":null}]}' > "$ST/runs"
printf '%s\n' "printf '%s' '$FAST_CI_GREEN' > \"\$ST/rollup\"; printf '%s' '$RUNS_DONE' > \"\$ST/runs\"" > "$ST/on-sleep"
out="$(run 7 --squash)"; rc=$?
check_eq "#1087 a head with no checks yet but a queued run merges only after it" "0" "$rc"
check "#1087 waiting on the queued run" "CI (queued)" "$out"
check_eq "#1087 after one wait" "1" "$(count sleeps '^30$')"

# Every run finished, checks green: merged at the first look, no wait added (the control).
fresh "$OLD" 0 "$FAST_CI_GREEN"
printf '%s' "$RUNS_DONE" > "$ST/runs"
out="$(run 7 --squash)"; rc=$?
check_eq "#1087 control: finished runs and green checks merge at once" "0" "$rc"
check_eq "#1087 control: with no wait" "0" "$(count sleeps '^30$')"

# The runs read is retried like the others, and a read that never succeeds stops: not knowing
# whether CI is still to come is not knowing it is not (L42).
fresh "$OLD" 0 "$FAST_CI_GREEN"
printf '%s\n' 'Get "https://api.github.com/repos/acme/widget/actions/runs": net/http: TLS handshake timeout' > "$ST/runs-fails"
out="$(run 7 --squash)"; rc=$?
check_eq "#1087 a runs read that fails once and then answers still merges" "0" "$rc"
check_eq "#1087 after one retry wait" "1" "$(count sleeps '^7$')"

fresh "$OLD" 0 "$FAST_CI_GREEN"
printf '%s\n' 'gh: Server Error (HTTP 502)' > "$ST/runs-down"
out="$(run 7 --squash)"; rc=$?
check_eq "#1087 a runs read that keeps failing stops" "1" "$rc"
check "#1087 saying what it could not read" "could not read which workflow runs" "$out"
check_eq "#1087 and nothing was merged" "0" "$(count gh-calls 'pr merge')"

fresh "$OLD" 0 "$FAST_CI_GREEN"
printf '%s\n' 'gh: Resource not accessible by integration (HTTP 403)' > "$ST/runs-down"
out="$(run 7 --squash)"; rc=$?
check_eq "#1087 a runs read GitHub refuses stops at once" "1" "$rc"
check_eq "#1087 with no retry wait" "0" "$(count sleeps '^7$')"

# =================================================================================================
# 9b. A CI start that never began is re-run once (claude-config#2537). On 2026-11-09 pull requests
#     #2495, #2496 and #2534 stopped with block-red-merge.sh's "PR has NO checks at all": each head's
#     tests run had completed as a failure with zero jobs ("This run likely failed because of a
#     workflow file issue") while main's workflow was fine, and `gh run rerun` started each properly.
#     Only that exact shape is re-run, once per head; a second such failure stops as before.
# =================================================================================================
NO_CHECKS='PR has NO checks at all.'
fs_runs(){ # fs_runs <id> <status> <conclusion> <attempt>: the head's one tests run
  jq -nc --argjson id "$1" --arg s "$2" --arg c "$3" --argjson a "$4" \
    '{total_count:1,workflow_runs:[{id:$id,name:"tests",status:$s,conclusion:(if $c == "" then null else $c end),run_attempt:$a}]}'
}

# Failed with no jobs, re-run, then green: it carries on and merges.
fresh "$OLD" 0 '[]'
fs_runs 4201 completed failure 1 > "$ST/runs"; printf '0' > "$ST/jobs-4201"
printf '%s' "$NO_CHECKS" > "$ST/red-gate-deny"
printf '%s\n' "printf '%s' '$(fs_runs 4201 queued '' 2)' > \"\$ST/runs\"" > "$ST/on-rerun"
printf '%s\n' "printf '%s' '$GREEN' > \"\$ST/rollup\"; printf '%s' '$(fs_runs 4201 completed success 2)' > \"\$ST/runs\"; printf '3' > \"\$ST/jobs-4201\"; : > \"\$ST/red-gate-deny\"" > "$ST/on-sleep"
out="$(run 7 --squash)"; rc=$?
check_eq "#2537 a run that failed with no jobs is re-run and the head then merges" "0" "$rc"
check_eq "#2537 re-run exactly once" "1" "$(count gh-calls '^run rerun 4201 --repo acme/widget')"
check "#2537 saying so, naming the run" "re-ran workflow run 4201 (tests)" "$out"
check "#2537 and why" "failed with no jobs" "$out"
check_eq "#2537 the gates were asked once, after the re-run went green" "1" "$(grep -c 'gh pr merge' "$ST/red-gate-payloads" 2>/dev/null || echo 0)"
check_eq "#2537 exactly one merge" "1" "$(count gh-calls 'pr merge')"

# Re-run, and the second start fails the same way: it stops as before, with no second re-run.
fresh "$OLD" 0 '[]'
fs_runs 4202 completed failure 1 > "$ST/runs"; printf '0' > "$ST/jobs-4202"
printf '%s' "$NO_CHECKS" > "$ST/red-gate-deny"
printf '%s\n' "printf '%s' '$(fs_runs 4202 queued '' 2)' > \"\$ST/runs\"" > "$ST/on-rerun"
printf '%s\n' "printf '%s' '$(fs_runs 4202 completed failure 2)' > \"\$ST/runs\"" > "$ST/on-sleep"
out="$(run 7 --squash)"; rc=$?
check_eq "#2537 a second start failing with no jobs stops" "1" "$rc"
check_eq "#2537 after only the one re-run" "1" "$(count gh-calls '^run rerun')"
check "#2537 saying it failed to start again and is not re-run twice" "failed to start again" "$out"
check "#2537 and stopping on block-red-merge.sh's own refusal" "PR has NO checks at all" "$out"
check_eq "#2537 nothing was merged" "0" "$(count gh-calls 'pr merge')"

# Already re-run before this helper started (attempt 2): never re-run again, whoever re-ran it.
fresh "$OLD" 0 '[]'
fs_runs 4205 completed failure 2 > "$ST/runs"; printf '0' > "$ST/jobs-4205"
printf '%s' "$NO_CHECKS" > "$ST/red-gate-deny"
out="$(run 7 --squash)"; rc=$?
check_eq "#2537 a run already on its second attempt is not re-run" "0" "$(count gh-calls '^run rerun')"
check_eq "#2537 and it stops as before" "1" "$rc"

# GitHub slow to show the re-run (still attempt 1 a look later): not re-run a second time, and the
# grace for a head with no checks starts again from the re-run, so it waits rather than stopping.
# The run sits queued for 210 seconds first, so the re-run comes after the head's own grace is spent
# (fixture settings, not measured).
fresh "$OLD" 0 '[]'
fs_runs 4206 queued '' 1 > "$ST/runs"; printf '0' > "$ST/jobs-4206"
printf '%s' "$NO_CHECKS" > "$ST/red-gate-deny"
printf '%s\n' : : : : : : \
  "printf '%s' '$(fs_runs 4206 completed failure 1)' > \"\$ST/runs\"" \
  : \
  "printf '%s' '$(fs_runs 4206 queued '' 2)' > \"\$ST/runs\"" \
  "printf '%s' '$GREEN' > \"\$ST/rollup\"; printf '%s' '$(fs_runs 4206 completed success 2)' > \"\$ST/runs\"; : > \"\$ST/red-gate-deny\"" > "$ST/on-sleep"
out="$(MWR_NO_CHECKS_GRACE_SECONDS=180 run 7 --squash)"; rc=$?
check_eq "#2537 a re-run GitHub has not shown yet is waited on, then merges" "0" "$rc"
check_eq "#2537 with no second re-run" "1" "$(count gh-calls '^run rerun')"

# A run whose jobs ran and failed is a real failure: never re-run.
fresh "$OLD" 0 "$RED"
fs_runs 4203 completed failure 1 > "$ST/runs"; printf '3' > "$ST/jobs-4203"
printf 'a check failed' > "$ST/red-gate-deny"
out="$(run 7 --squash)"; rc=$?
check_eq "#2537 a failed run with jobs stops as before" "1" "$rc"
check "#2537 its jobs were read, so the shape was judged" "actions/runs/4203/jobs" "$(cat "$ST/gh-calls")"
check_eq "#2537 and it was never re-run" "0" "$(count gh-calls '^run rerun')"

# A run that succeeded is never judged at all.
fresh "$OLD" 0 "$GREEN"
fs_runs 4207 completed success 1 > "$ST/runs"; printf '0' > "$ST/jobs-4207"
out="$(run 7 --squash)"; rc=$?
check_eq "#2537 control: a green run merges" "0" "$rc"
check_eq "#2537 control: with no jobs read" "0" "$(count gh-calls '/jobs')"

# The run list unreadable: it stops as before, and nothing is re-run.
fresh "$OLD" 0 '[]'
printf '%s\n' 'gh: Server Error (HTTP 502)' > "$ST/runs-down"
out="$(run 7 --squash)"; rc=$?
check_eq "#2537 an unreadable run list stops as before" "1" "$rc"
check "#2537 saying what it could not read" "could not read which workflow runs" "$out"
check_eq "#2537 and nothing is re-run" "0" "$(count gh-calls '^run rerun')"

# The jobs unreadable: not re-run, saying why, and the checks gate decides as before.
fresh "$OLD" 0 '[]'
fs_runs 4204 completed failure 1 > "$ST/runs"
printf '%s\n' 'gh: Server Error (HTTP 502)' > "$ST/jobs-down"
printf '%s' "$NO_CHECKS" > "$ST/red-gate-deny"
out="$(run 7 --squash)"; rc=$?
check_eq "#2537 jobs that cannot be read leave the run alone and stop as before" "1" "$rc"
check "#2537 saying the jobs could not be read" "Could not read the jobs of workflow run 4204" "$out"
check_eq "#2537 and nothing is re-run" "0" "$(count gh-calls '^run rerun')"

# GitHub refusing the re-run: said, and the checks gate decides as before.
fresh "$OLD" 0 '[]'
fs_runs 4208 completed failure 1 > "$ST/runs"; printf '0' > "$ST/jobs-4208"
printf '%s\n' 'gh: Resource not accessible by integration (HTTP 403)' > "$ST/rerun-down"
printf '%s' "$NO_CHECKS" > "$ST/red-gate-deny"
out="$(run 7 --squash)"; rc=$?
check_eq "#2537 a re-run GitHub refuses stops as before" "1" "$rc"
check "#2537 naming GitHub's answer" "HTTP 403" "$out"
check_eq "#2537 nothing was merged" "0" "$(count gh-calls 'pr merge')"

# =================================================================================================
# 9c. A head whose run GitHub has not created yet, or whose checks it has not listed yet, is waited
#     on for a bounded time (claude-config#3254). On 2026-11-18 this helper updated #3242 at 14:36:13
#     ET and stopped at 14:40:28 on block-red-merge.sh's "PR has NO checks at all": GitHub created
#     the head's tests run (44382714174) at 14:40:29, 256 seconds after the update, one second after
#     the stop, and the run went green. Over the 455 updates of 2026-11-08 to 11-18 GitHub created the
#     run within 8 seconds for 95 in 100, and in up to 388 seconds for the rest (evidence in the
#     issue's working notes). These sections run on the helper's own default waits, never the suite's
#     zero, and every wait is crossed on the injected clock.
# =================================================================================================
# tick: run on every sleep, it moves GitHub along by the time since the update, as 2026-11-18 went:
# nothing for created-at seconds, then the run in progress, then green after finished-at.
lag_tick(){ # lag_tick <created-at> <finished-at>: writes the step every sleep runs
  cat > "$ST/tick" <<EOT
u="\$(head -1 "\$ST/update-times" 2>/dev/null)"; c=""; read -r c < "\$ST/clock"
if [ -n "\$u" ] && [ \$(( c - u )) -ge $2 ]; then
  printf '%s' '$GREEN' > "\$ST/rollup"; printf '%s' '$(fs_runs 44382714174 completed success 1)' > "\$ST/runs"; : > "\$ST/red-gate-deny"
elif [ -n "\$u" ] && [ \$(( c - u )) -ge $1 ]; then
  printf '%s' '$PENDING' > "\$ST/rollup"; printf '%s' '$(fs_runs 44382714174 in_progress '' 1)' > "\$ST/runs"
fi
EOT
  local i; for i in $(seq 1 120); do printf '%s\n' '. "$ST/tick"'; done > "$ST/on-sleep"
}
elapsed_since_update(){ local c u; read -r c < "$ST/clock"; u="$(head -1 "$ST/update-times")"; printf '%s' "$(( c - u ))"; }

# The 2026-11-18 stop, reproduced: the run is created 256 seconds after the update and finishes green.
fresh "$OLD" 1 "$GREEN"
printf '%s\n' "$NEW" > "$ST/next-heads"; printf '[]' > "$ST/rollup-after-update"
printf '%s' "$NO_CHECKS" > "$ST/red-gate-deny"
lag_tick 256 1156
out="$(MWR_NO_CHECKS_GRACE_SECONDS= run 7 --squash)"; rc=$?
check_eq "#3254 a run GitHub creates 256s after the update is waited for, and the head merges" "0" "$rc"
check_not "#3254 it never stops on an empty check list GitHub has not filled yet" "PR has NO checks at all" "$out"
check "#3254 the wait says no run has been created for the head yet" "no workflow run created for this head yet" "$out"
check_eq "#3254 the checks gate was asked once, after the checks were green" "1" "$(grep -c 'gh pr merge' "$ST/red-gate-payloads" 2>/dev/null || echo 0)"
check "#3254 pinned to the updated head" "--match-head-commit $NEW" "$(grep 'pr merge' "$ST/gh-calls")"

# A head whose run never starts (Actions disabled, a workflow that will not parse): it still stops on
# the checks gate's own refusal, once the bounded wait is spent and not long after.
fresh "$OLD" 1 "$GREEN"
printf '%s\n' "$NEW" > "$ST/next-heads"; printf '[]' > "$ST/rollup-after-update"
printf '%s' "$NO_CHECKS" > "$ST/red-gate-deny"
out="$(MWR_NO_CHECKS_GRACE_SECONDS= run 7 --squash)"; rc=$?
check_eq "#3254 a head whose run never starts stops" "1" "$rc"
check "#3254 on block-red-merge.sh's own refusal, naming why" "PR has NO checks at all" "$out"
check_eq "#3254 nothing was merged" "0" "$(count gh-calls 'pr merge')"
el="$(elapsed_since_update)"
[ "$el" -ge 600 ] && ok || bad "#3254 it waited out the 10 minute wait for a run first (stopped ${el}s after the update)"
[ "$el" -le 700 ] && ok || bad "#3254 and stopped soon after it (stopped ${el}s after the update)"

# Checks reported late: the head's run has finished green, and GitHub has not listed its checks on
# the pull request yet. Waited on, with no grace for a run to be created (the suite's zero).
fresh "$OLD" 0 '[]'
fs_runs 44382714174 completed success 1 > "$ST/runs"
printf '%s' "$NO_CHECKS" > "$ST/red-gate-deny"
printf '%s\n' : : : "printf '%s' '$GREEN' > \"\$ST/rollup\"; : > \"\$ST/red-gate-deny\"" > "$ST/on-sleep"
out="$(run 7 --squash)"; rc=$?
check_eq "#3254 a finished run whose checks GitHub lists late is waited for, then merges" "0" "$rc"
check "#3254 saying GitHub has not listed the finished run's checks yet" "GitHub has not listed its checks" "$out"
check_eq "#3254 the checks gate was asked once, after they were listed" "1" "$(grep -c 'gh pr merge' "$ST/red-gate-payloads" 2>/dev/null || echo 0)"

# Checks never listed for a run that finished green: after a bounded wait it says so, naming the run,
# and the checks gate decides on the empty list exactly as it did before this wait existed.
fresh "$OLD" 0 '[]'
fs_runs 44382714174 completed success 1 > "$ST/runs"
printf '%s' "$NO_CHECKS" > "$ST/red-gate-deny"
read -r t0 < "$ST/clock"
out="$(run 7 --squash)"; rc=$?
read -r t1 < "$ST/clock"
check_eq "#3254 a finished run whose checks are never listed stops" "1" "$rc"
check "#3254 naming the run and that GitHub listed no checks for it" "Head ${OLD:0:7}: workflow run tests finished, but GitHub has listed no checks on #7 after 5m" "$out"
check "#3254 on the checks gate's own refusal" "PR has NO checks at all" "$out"
check_eq "#3254 nothing was merged" "0" "$(count gh-calls 'pr merge')"
check_eq "#3254 the gates were asked once, after the wait" "1" "$(grep -c 'gh pr merge' "$ST/red-gate-payloads" 2>/dev/null || echo 0)"
[ $(( t1 - t0 )) -ge 300 ] && [ $(( t1 - t0 )) -le 400 ] && ok || bad "#3254 after the 5 minute wait for a listing and not long after ($(( t1 - t0 ))s)"

# And where the checks gate allows an empty list (a repository with no pull request workflows, whose
# head carries some other finished run), the wait changes nothing it decides: it still merges.
fresh "$OLD" 0 '[]'
fs_runs 44382714174 completed success 1 > "$ST/runs"
out="$(run 7 --squash)"; rc=$?
check_eq "#3254 control: an empty list the gate allows still merges after the wait" "0" "$rc"
check_eq "#3254 control: exactly one merge" "1" "$(count gh-calls 'pr merge')"

# Control: a run that FAILED, with an empty check list, is no listing delay: the gate decides at once.
fresh "$OLD" 0 '[]'
fs_runs 4209 completed failure 1 > "$ST/runs"; printf '3' > "$ST/jobs-4209"
printf '%s' "$NO_CHECKS" > "$ST/red-gate-deny"
out="$(run 7 --squash)"; rc=$?
check_eq "#3254 control: a failed run with no checks listed stops as before" "1" "$rc"
check_not "#3254 control: with no wait for a listing" "has not listed its checks" "$out"
check "#3254 control: on the gate's own refusal" "PR has NO checks at all" "$out"

# =================================================================================================
# 10. The changelog record gate is asked too (claude-config#1178). Nine Slate pull requests merged
#     through this helper between 2026-10-07 and 2026-10-12 with no changelog/* label: the helper
#     asked only the checks and review gates, and the typed command that started it is not a merge
#     the changelog gate recognises, so require-changelog-tag.sh saw none of them.
# =================================================================================================
fresh "$OLD" 0 "$GREEN"
printf 'PR #7 carries no usable changelog record. It has no changelog/* label.' > "$ST/changelog-gate-deny"
out="$(run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#1178 a refusal from the changelog record gate stops it" "1" "$rc"
check "#1178 carrying that gate's own reason" "no changelog/* label" "$out"
check "#1178 and naming the gate that refused" "require-changelog-tag.sh refused" "$out"
check_eq "#1178 and nothing is merged past it" "0" "$(count gh-calls 'pr merge')"

# Asked FIRST, before any wait: the record does not depend on the head or its checks, so a missing
# label is known at once, and finding it after a twelve minute CI run and a lessons review costs
# both (L667).
fresh "$OLD" 0 "$PENDING"
printf 'PR #7 carries no usable changelog record.' > "$ST/changelog-gate-deny"
out="$(MWR_MAX_POLLS=3 run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#1178 a missing record stops it before it waits on checks" "1" "$rc"
check_eq "#1178 with no wait at all" "0" "$(count sleeps '^30$')"
check_eq "#1178 and no lessons review started for a merge that cannot happen" "0" "$(count review-calls '^start')"

# A run resumed after the merge landed reports it merged, not refused: the record is asked only of an
# open pull request.
fresh "$OLD" 0 "$GREEN"
: > "$ST/merged"
printf 'PR #7 carries no usable changelog record.' > "$ST/changelog-gate-deny"
out="$(run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#1178 an already merged pull request is reported merged, whatever its record" "0" "$rc"
check "#1178 in those words" "already merged" "$out"

# And asked again at the merge, about the exact pinned command, because a label can be taken off
# while the helper waits.
fresh "$OLD" 0 "$GREEN"
out="$(run 7 --repo acme/widget --squash --delete-branch)"; rc=$?
check_eq "#1178 with a record the merge goes through" "0" "$rc"
check "#1178 the changelog gate judges the exact pinned merge command" "gh pr merge 7 --repo acme/widget --squash --match-head-commit $OLD" "$(cat "$ST/changelog-gate-payloads" 2>/dev/null)"
check "#1178 the merge line names every gate, not two" "every merge gate allows it" "$out"

fresh "$OLD" 0 "$PENDING"
printf '%s\n' "printf '%s' '$GREEN' > \"\$ST/rollup\"; printf 'label removed' > \"\$ST/changelog-gate-deny\"" > "$ST/on-sleep"
out="$(run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#1178 a record removed during the wait stops the merge" "1" "$rc"
check "#1178 in the gate's words" "label removed" "$out"
check_eq "#1178 and nothing is merged" "0" "$(count gh-calls 'pr merge')"

# A gate that cannot be run is a refusal, never a pass (L98).
fresh "$OLD" 0 "$GREEN"
out="$(MWR_CHANGELOG_GATE="$WORKDIR/no-such-gate.sh" run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#1178 a changelog gate that is not there stops it" "1" "$rc"
check_eq "#1178 and nothing is merged" "0" "$(count gh-calls 'pr merge')"

# The REAL gate decides, against a registry that gates acme/widget (L52).
REG="$WORKDIR/repos.json"
printf '%s\n' '{"repos":[{"name":"Widget","repo":"acme/widget","changelogFrom":"2026-01-01"}]}' > "$REG"
fresh "$OLD" 0 "$GREEN"
out="$(CHANGELOG_REGISTRY="$REG" MWR_CHANGELOG_GATE="$DIR/require-changelog-tag.sh" run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#1178 the real require-changelog-tag.sh refuses an unlabelled pull request through the helper" "1" "$rc"
check "#1178 its reason is shown" "carries no usable changelog record" "$out"
check_eq "#1178 and nothing is merged" "0" "$(count gh-calls 'pr merge')"
fresh "$OLD" 0 "$GREEN"
printf '%s' '[{"name":"changelog/technical"}]' > "$ST/labels"
out="$(CHANGELOG_REGISTRY="$REG" MWR_CHANGELOG_GATE="$DIR/require-changelog-tag.sh" run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#1178 control: the real gate lets a labelled pull request through the helper" "0" "$rc"

# The design score gate (#1364) is asked at the merge as well: a pull request whose closing keywords
# name a Match the settled design issue below 100% is not merged through the helper any more than
# when typed.
fresh "$OLD" 0 "$GREEN"
printf 'Match the settled design is below 100%% on the code being merged.' > "$ST/design-gate-deny"
out="$(run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#1364 a merge the design score gate refuses stops the helper" "1" "$rc"
check "#1364 in the gate's words" "below 100% on the code being merged" "$out"
check_eq "#1364 and nothing is merged" "0" "$(count gh-calls 'pr merge')"
fresh "$OLD" 0 "$GREEN"
out="$(run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#1364 with the design score gate allowing it, the merge goes through" "0" "$rc"
check "#1364 the design score gate judges the exact pinned merge command" "gh pr merge 7 --repo acme/widget --squash --match-head-commit $OLD" "$(cat "$ST/design-gate-payloads" 2>/dev/null)"

# The verification run gate (#1529) is asked at the merge, about the exact pinned command: its
# records are about a head, so a verdict read before the wait would be about a head that may move.
fresh "$OLD" 0 "$GREEN"
printf 'Refusing to merge PR #7 at 1111111 until every area it touches has a passing verification run there.' > "$ST/verify-gate-deny"
out="$(run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#1529 a merge the verification run gate refuses stops the helper" "1" "$rc"
check "#1529 in the gate's words" "has a passing verification run there" "$out"
check "#1529 and the stop names the gate" "require-verification-run.sh refused" "$out"
check_eq "#1529 and nothing is merged" "0" "$(count gh-calls 'pr merge')"
fresh "$OLD" 0 "$GREEN"
printf 'Verification merge check, warn mode, so this merge is allowed. PR #7 would be refused in block mode.' > "$ST/verify-gate-context"
out="$(run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#1529 a warn mode allow lets the merge through" "0" "$rc"
check "#1529 the verification gate judges the exact pinned merge command" "gh pr merge 7 --repo acme/widget --squash --match-head-commit $OLD" "$(cat "$ST/verify-gate-payloads" 2>/dev/null)"
check "#1529 and the warn verdict it hands back is shown in the log, not dropped" "would be refused in block mode" "$out"

# The closing keyword gate (#1550) is asked once before the wait, since a body does not depend on the
# head or its checks (L667), and again at the merge, about the exact pinned command, because the body
# can be edited while this waits.
fresh "$OLD" 0 "$PENDING"
printf 'Refusing to merge PR #7: this body says otherwise about #4358.' > "$ST/closing-gate-deny"
out="$(run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#1550 a body the closing keyword gate refuses stops the helper" "1" "$rc"
check "#1550 in the gate's words, naming it" "check-closing-merge.sh refused the merge of #7 before any wait" "$out"
check_eq "#1550 before any wait" "0" "$(count sleeps '.')"
check_eq "#1550 and nothing is merged" "0" "$(count gh-calls 'pr merge')"
fresh "$OLD" 0 "$GREEN"
out="$(run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#1550 with the closing keyword gate allowing it, the merge goes through" "0" "$rc"
check "#1550 the closing keyword gate judges the exact pinned merge command" "gh pr merge 7 --repo acme/widget --squash --match-head-commit $OLD" "$(cat "$ST/closing-gate-payloads" 2>/dev/null)"
fresh "$OLD" 0 "$PENDING"
printf '%s\n' "printf '%s' '$GREEN' > \"\$ST/rollup\"; printf 'body now says #4358 stays open' > \"\$ST/closing-gate-deny\"" > "$ST/on-sleep"
out="$(run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#1550 a body edited during the wait stops the merge" "1" "$rc"
check "#1550 in the gate's words" "body now says #4358 stays open" "$out"
check_eq "#1550 and nothing is merged" "0" "$(count gh-calls 'pr merge')"

# The work names gate (#1995) is asked at the same two moments, for the same reasons: a title, a
# description and the commit messages do not depend on the head's checks, and can change while this
# waits.
fresh "$OLD" 0 "$PENDING"
printf 'Refusing to merge PR #7: it names a work organisation. title:1: a work organisation name' > "$ST/work-names-gate-deny"
out="$(run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#1995 a pull request the work names gate refuses stops the helper" "1" "$rc"
check "#1995 in the gate's words, naming it" "check-work-names-merge.sh refused the merge of #7 before any wait" "$out"
check_eq "#1995 before any wait" "0" "$(count sleeps '.')"
check_eq "#1995 and nothing is merged" "0" "$(count gh-calls 'pr merge')"
fresh "$OLD" 0 "$GREEN"
out="$(run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#1995 with the work names gate allowing it, the merge goes through" "0" "$rc"
check "#1995 the work names gate judges the exact pinned merge command" "gh pr merge 7 --repo acme/widget --squash --match-head-commit $OLD" "$(cat "$ST/work-names-gate-payloads" 2>/dev/null)"
fresh "$OLD" 0 "$PENDING"
printf '%s\n' "printf '%s' '$GREEN' > \"\$ST/rollup\"; printf 'title now names a work organisation' > \"\$ST/work-names-gate-deny\"" > "$ST/on-sleep"
out="$(run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#1995 a title edited during the wait stops the merge" "1" "$rc"
check "#1995 in the gate's words" "title now names a work organisation" "$out"
check_eq "#1995 and nothing is merged" "0" "$(count gh-calls 'pr merge')"
# Every script this helper runs is named from the environment only under the test marker
# (claude-config#2231 for the work names gate, #2317 for the rest): a script named there would stand
# in for a merge gate, the lessons review or the worktree check on every merge this helper makes.
# Outside a test run the installed one beside the helper is run instead. The real installed scripts
# would reach GitHub and start a real lessons review, so these cases run a copy of the helper from a
# folder of its own, whose installed scripts are stand ins that log their own name and then answer
# as this suite's stubs do. Every setting names a decoy that logs and refuses, and outside a test run
# no decoy may ever run.
# The installed copy, its stand ins, the decoys and fake_in are lib/merge-when-ready-harness.sh's,
# since section 20 (test-merge-when-ready-heads.sh) runs it too.
for marker in "" 0; do
  fresh "$OLD" 0 "$GREEN"
  out="$(fake_in "$REPO" HOOK_TESTS_RUNNING="$marker" bash "$FAKE_HELPER" 7 --repo acme/widget --squash)"; rc=$?
  check_eq "#2317 outside a test run (marker '$marker') no script named in the environment is run" "" "$(cat "$ST/decoys-asked" 2>/dev/null)"
  check_eq "#2317 and the merge goes through the installed gates (marker '$marker')" "0" "$rc"
  for g in block-red-merge.sh pr-review-gate.sh require-changelog-tag.sh design-score-gate.sh \
           require-verification-run.sh check-closing-merge.sh check-work-names-merge.sh lib/pr-review.sh; do
    check "#2317 outside a test run the installed $g is run (marker '$marker')" "$g" "$(cat "$ST/installed-asked" 2>/dev/null)"
  done
done
# Control: under the marker each setting is still the test's own, so the seam the suite uses works.
fresh "$OLD" 0 "$GREEN"
out="$(fake_in "$REPO" HOOK_TESTS_RUNNING=1 bash "$FAKE_HELPER" 7 --repo acme/widget --squash)"; rc=$?
check "#2317 control: under the test marker a script named in the environment is run" "ran" "$(cat "$ST/decoys-asked" 2>/dev/null)"
check_eq "#2317 control: and its refusal stops the merge" "0" "$(count gh-calls 'pr merge')"
# The wait and the clock (claude-config#2399): a head whose checks are pending makes the helper wait
# once, and the queued step turns them green during that wait, so the run both sleeps and reads the
# clock before it merges.
for marker in "" 0; do
  fresh "$OLD" 0 "$PENDING"
  printf '%s\n' "printf '%s' '$GREEN' > \"\$ST/rollup\"" > "$ST/on-sleep"
  out="$(fake_in "$REPO" HOOK_TESTS_RUNNING="$marker" bash "$FAKE_HELPER" 7 --repo acme/widget --squash)"; rc=$?
  check_eq "#2399 outside a test run (marker '$marker') the merge goes through after its wait" "0" "$rc"
  check_eq "#2399 outside a test run (marker '$marker') the sleep named in MWR_SLEEP is never run" "" "$(cat "$ST/decoy-sleeps" 2>/dev/null)"
  check_eq "#2399 outside a test run (marker '$marker') the clock named in MWR_NOW is never read" "" "$(cat "$ST/decoy-nows" 2>/dev/null)"
  check "#2399 outside a test run (marker '$marker') the sleep on the PATH does the wait" "30" "$(cat "$ST/path-sleeps" 2>/dev/null)"
  check "#2399 outside a test run (marker '$marker') the date on the PATH is the clock" "read" "$(cat "$ST/path-dates" 2>/dev/null)"
done
# Control: under the marker both settings are the test's own, so the seam every case above uses works.
fresh "$OLD" 0 "$PENDING"
printf '%s\n' "printf '%s' '$GREEN' > \"\$ST/rollup\"" > "$ST/on-sleep"
out="$(fake_in "$REPO" HOOK_TESTS_RUNNING=1 MWR_RED_GATE="$STUBS/red-gate.sh" MWR_REVIEW_GATE="$STUBS/review-gate.sh" \
  MWR_CHANGELOG_GATE="$STUBS/changelog-gate.sh" MWR_DESIGN_GATE="$STUBS/design-gate.sh" MWR_VERIFY_GATE="$STUBS/verify-gate.sh" \
  MWR_CLOSING_GATE="$STUBS/closing-gate.sh" MWR_WORK_NAMES_GATE="$STUBS/work-names-gate.sh" MWR_REVIEW_LIB="$STUBS/pr-review.sh" \
  MWR_WORKTREE_CHECK= bash "$FAKE_HELPER" 7 --repo acme/widget --squash)"; rc=$?
check_eq "#2399 control: under the test marker the merge goes through after its wait" "0" "$rc"
check "#2399 control: under the test marker the sleep named in MWR_SLEEP does the wait" "30" "$(cat "$ST/decoy-sleeps" 2>/dev/null)"
check "#2399 control: under the test marker the clock named in MWR_NOW is read" "read" "$(cat "$ST/decoy-nows" 2>/dev/null)"
check_eq "#2399 control: and the sleep on the PATH is not run" "" "$(cat "$ST/path-sleeps" 2>/dev/null)"

# A read of the injected clock that gives no time is asked again (claude-config#2327). The clock is a
# command the helper runs, so a read can come back empty when that command could not run (no process
# to spare under load, a clock file a full disk left empty), and the helper read the real clock in
# its place: one look at an epoch near 1.8 billion, against the suite's clock near a million, crossed
# every deadline and line budget at once. Injected (2327 evidence), one empty read was enough to stop
# the "three ahead" case below at its line budget with the line still moving. Here every fourth read
# answers nothing, and the run must come out exactly as a run on a whole clock does.
cat > "$BIN/gappy-now" <<'EOS'
#!/usr/bin/env bash
n=$(( $(cat "$ST/now-reads" 2>/dev/null || echo 0) + 1 )); printf '%s' "$n" > "$ST/now-reads"
[ $(( n % 4 )) -eq 0 ] && exit 0
cat "$ST/clock"
EOS
chmod +x "$BIN/gappy-now"
fresh "$OLD" 0 "$PENDING"
printf '%s\n' ':' ':' "printf '%s' '$GREEN' > \"\$ST/rollup\"" > "$ST/on-sleep"
out="$(MWR_NOW="$BIN/gappy-now" MWR_DEADLINE_SECONDS=900 run 7 --squash)"; rc=$?
check_eq "#2327 a clock read that answers nothing now and then does not stop the run" "0" "$rc"
check "#2327 and the merge landed" "Merged #7 in acme/widget at ${OLD:0:7}" "$out"
check_not "#2327 never out of time" "Out of time" "$out"
check_eq "#2327 every elapsed figure it said is on the injected clock (none past the 90s it ran)" "" "$(grep -oE '^merge-when-ready: \[[^]]*\]' <<<"$out" | grep -vE '\[(0s|[0-9]{1,2}s|1m [0-9]{2}s)\]')"
check_not "#2327 and it never said it read the real clock" "real clock" "$out"
check "#2327 control: the clock did answer nothing on some reads" "yes" "$( [ "$(cat "$ST/now-reads" 2>/dev/null || echo 0)" -ge 4 ] && echo yes || echo no)"
# A clock that never answers is said, naming the setting, rather than read past in silence (L11).
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/mute-now"; chmod +x "$BIN/mute-now"
fresh "$OLD" 0 "$GREEN"
out="$(MWR_NOW="$BIN/mute-now" run 7 --squash)"; rc=$?
check "#2327 a clock that never answers is said, naming MWR_NOW" "the clock named in MWR_NOW ($BIN/mute-now) gave no time in 3 reads, so the real clock is read instead" "$out"

# THE CLASS (L30, L96): the gates this helper asks must be every gate a typed merge meets. The list
# here is written by hand, so it is checked against the hooks block: every PreToolUse Bash hook that
# recognises a merge through the shared reader (mt_runs_merge or mt_is_pr_merge) must be asked, or
# a merge through this helper skips it, which is exactly how the changelog gate was skipped.
. "$DIR/lib/settings-file.sh"
SETTINGS="$(hook_settings_file "$DIR/..")"
if [ -z "$SETTINGS" ]; then
  bad "#1178 neither settings.hooks.json nor settings.json beside $DIR, so the merge gates cannot be listed"
else
  typed_gates="$(jq -r '.hooks.PreToolUse[]? | select((.matcher // "") | test("(^|[|])Bash($|[|])")) | .hooks[]?.command' "$SETTINGS" \
    | sed 's#.*/##' | sort -u | while IFS= read -r h; do
        [ -f "$DIR/$h" ] && grep -Eq 'mt_runs_merge|mt_is_pr_merge' "$DIR/$h" && printf '%s\n' "$h"
      done)"
  helper_gates="$(grep -oE '\$MWR_HOOKS/[A-Za-z0-9_.-]+\.sh' "$HELPER" | sed 's#.*/##' | sort -u)"
  # The control: the listing must find the gate this suite already proves the helper asks, or an
  # empty listing would agree with anything (L98).
  check "#1178 control: the hooks block lists block-red-merge.sh as a merge gate" "block-red-merge.sh" "$typed_gates"
  missing="$(comm -23 <(printf '%s\n' "$typed_gates") <(printf '%s\n' "$helper_gates"))"
  check_eq "#1178 every merge gate a typed merge meets is asked by merge-when-ready.sh" "" "$missing"
fi

echo
mwr_harness_result
