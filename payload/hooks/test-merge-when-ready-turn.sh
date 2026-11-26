#!/usr/bin/env bash
# Tests for lib/merge-when-ready.sh, sections 22 to 26b of what was one suite, test-merge-when-ready.sh:
# the per repository turn, a deliberate load window named beside a failure, never a turn it
# cannot finish, a run keeping its place while the line moves, the phase it publishes, and a
# gate that ran out of its own time.
#
# test-merge-when-ready.sh ran past run-all-tests.sh's 1,200 second wall limit on GitHub's runners
# on 2026-11-24 (exit 124), which stopped the config sync between the two Macs: one piece held
# against a fixed deadline had grown to most of it (L315). Its sections are now six suites, each
# dealt to a part by its own measured cost (claude-config#3572): test-merge-when-ready.sh (its
# documentation checks and sections 1 to 10), -heads (11 to 21), -turn (22 to 26b), -line (27 to
# 30), -untested (31 to 33) and -bypass (the bypass merge and sleep mode). Every check is as it was,
# and each section keeps its number, so "section N" in a comment names the section of that number
# in whichever of the six holds it.
#
# The world they run in (the fake gh, the injected clock and sleep, the stub gates and review
# checker, the checkout, the counters and the result line) is lib/merge-when-ready-harness.sh, the
# one place every one of them takes it from. Nothing reaches the network or a real pull request (L2).
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
mwr_harness_build
# Section 24 holds is-it-live's WAIT_MS to the helper's default deadline as well as its line budget,
# so both are read here, the way section 11 reads them in test-merge-when-ready-heads.sh.
mwr_default_deadline
mwr_wait_ms

# =================================================================================================
# 22. A per repository turn (claude-config#1515). On 2026-10-22 PET #1885 sat here about 112 minutes:
#     four other pull requests merged under it while its 23 minute checks ran, each one restarting
#     them. Now a run takes the repository's turn before it updates, waits or merges, and holds it
#     until it has merged or stopped; another run waits for it, saying so as its own state with the
#     holder and how long it has held it. A holder whose run has gone is passed over at once, and
#     one that has held it past MWR_TURN_HOLD_SECONDS is passed over by a run waiting for it. The
#     queue itself is proved in test-merge-turn.sh; here, what the helper does with it.
# =================================================================================================
# TURN_LIB, LIVE_START and take-turn are lib/merge-when-ready-harness.sh's, since sections 29 and
# 30 (test-merge-when-ready-line.sh) read them too.
tickets(){ ls "$MWR_TURN_DIR/${1:-acme/widget}" 2>/dev/null | grep -E '^[0-9]+$' | tr '\n' ' ' | sed 's/ $//'; }
ticket_prs(){ local t out=""; for t in $(tickets "$@"); do out="$out $(sed -n 's/^pr //p' "$MWR_TURN_DIR/${1:-acme/widget}/$t")"; done; printf '%s' "${out# }"; }

# A live run holds the turn: this one waits, updating and merging nothing, and says it is waiting for
# its turn, naming the holder and how long it has held it, never as a wait on checks.
fresh "$OLD" 2 "$GREEN"; printf '%s\n' "$NEW" > "$ST/next-heads"
"$BIN/take-turn" acme/widget 9
out="$(MWR_MAX_POLLS=3 run 7 --squash)"; rc=$?
check_eq "#1515 behind a live holder it is still waiting when its looks run out" "3" "$rc"
check "#1515 saying it waits for its turn, and who holds it" "waiting for its turn to merge in acme/widget, which #9 holds (1 ahead of it in line)." "$out"
check "#1515 and how long #9 has held it" "#9 has held it for 0s, of the 60m any one pull request may hold it." "$out"
check_not "#1515 a wait for the turn is never said as a wait on checks" "checks still running" "$out"
check "#1515 out of time, it names the turn it was waiting for" "is waiting for its turn to merge in acme/widget, which #9 holds" "$out"
check_eq "#1515 nothing was updated while another held the turn" "0" "$(count gh-calls 'pr update-branch')"
check_eq "#1515 nothing was merged" "0" "$(count gh-calls 'pr merge')"
check_eq "#1515 no lessons review was started for a head it may not merge yet" "0" "$(count review-calls 'start')"
check_eq "#1515 on stopping it gave up its place, and #9's is kept" "9" "$(ticket_prs)"

# The heartbeat says the holder's time again as it grows, though the wait's own line is unchanged.
fresh "$OLD" 0 "$GREEN"
"$BIN/take-turn" acme/widget 9
out="$(MWR_MAX_POLLS=6 MWR_HEARTBEAT_SECONDS=60 run 7 --squash)"; rc=$?
check "#1515 a heartbeat names how long the holder has held it by then" "#9 has held it for 1m 00s, of the 60m any one pull request may hold it. Still waiting, for 1m 00s so far." "$out"
check_eq "#1515 and the wait's line is said once, then only on the heartbeat" "1" "$(grep -c 'which #9 holds' <<<"$(grep -v 'Still waiting' <<<"$out" | grep -v 'Out of time')")"

# The holder finishes: the turn passes, and this one merges.
fresh "$OLD" 0 "$GREEN"
"$BIN/take-turn" acme/widget 9
printf '%s\n' "rm -f \"\$MWR_TURN_DIR/acme/widget/1\" \"\$MWR_TURN_DIR/acme/widget/1.head\"" > "$ST/on-sleep"
out="$(run 7 --squash)"; rc=$?
check_eq "#1515 once the holder leaves, the next in line merges" "0" "$rc"
check "#1515 saying it is its turn now, after how long" "It is #7's turn to merge in acme/widget now, after waiting 30s for it" "$out"
check "#1515 and merging that head" "Merged #7 in acme/widget at ${OLD:0:7}" "$out"
check_eq "#1515 its place is given up once merged" "" "$(tickets)"

# A holder whose run has gone (L409): passed over at once, with no wait at all.
fresh "$OLD" 0 "$GREEN"
"$BIN/take-turn" acme/widget 9 99999999 "Thu Jan  1 00:00:00 1970"
out="$(run 7 --squash)"; rc=$?
check_eq "#1515 a dead holder does not hold up a merge" "0" "$rc"
check "#1515 saying whose place was passed over, and why" "#9's place in line was passed over: its run (pid 99999999) is no longer running." "$out"
check_eq "#1515 without a single wait" "0" "$(count sleeps .)"
check_eq "#1515 and leaves no ticket behind" "" "$(tickets)"

# A live holder past the bound (L523): the waiting run takes the turn over, on the injected clock.
fresh "$OLD" 0 "$GREEN"
"$BIN/take-turn" acme/widget 9
out="$(MWR_TURN_HOLD_SECONDS=90 run 7 --squash)"; rc=$?
check_eq "#1515 a holder past its bound does not hold up a merge for ever" "0" "$rc"
check "#1515 saying whose turn ran out, after how long" "#9's turn ran out after 1m 30s, past the 1m 30s any one pull request may hold it" "$out"
check_eq "#1515 after waiting the bound, in fake time" "3" "$(count sleeps 30)"
check "#1515 and merging" "Merged #7 in acme/widget at ${OLD:0:7}" "$out"

# Different repositories never block each other.
fresh "$OLD" 0 "$GREEN"
"$BIN/take-turn" acme/other 9
out="$(run 7 --squash)"; rc=$?
check_eq "#1515 a holder in another repository does not hold up this one" "0" "$rc"
check_not "#1515 and this one never waits for it" "waiting for its turn" "$out"
check_eq "#1515 the other repository's holder is untouched" "9" "$(ticket_prs acme/other)"

# Its own turn taken over while it waits on its checks: it joins the line again and never merges
# under the run that took it over, though its checks have gone green.
fresh "$OLD" 0 "$PENDING"
printf '%s\n' "rm -f \"\$MWR_TURN_DIR/acme/widget/1\" \"\$MWR_TURN_DIR/acme/widget/1.head\"; \"\$BIN_DIR/take-turn\" acme/widget 9; printf '%s' '$GREEN' > \"\$ST/rollup\"" > "$ST/on-sleep"
out="$(BIN_DIR="$BIN" MWR_MAX_POLLS=4 run 7 --squash)"; rc=$?
check_eq "#1515 a run whose turn was taken over does not merge" "3" "$rc"
check "#1515 it took the turn first" "Took the turn to merge in acme/widget" "$out"
check "#1515 then says its place is gone and joins the line again" "#7's place in the line to merge in acme/widget is gone" "$out"
check "#1515 and waits behind the run that took it" "which #9 holds (1 ahead of it in line)" "$out"
check_eq "#1515 nothing merged under #9" "0" "$(count gh-calls 'pr merge')"

# The same, at the last moment: taken over while its review is asked, just before the gates.
fresh "$OLD" 0 "$GREEN"
printf '%s\n' "rm -f \"\$MWR_TURN_DIR/acme/widget/1\" \"\$MWR_TURN_DIR/acme/widget/1.head\"; \"\$BIN_DIR/take-turn\" acme/widget 9" > "$ST/on-review"
out="$(BIN_DIR="$BIN" MWR_MAX_POLLS=2 run 7 --squash)"; rc=$?
check_eq "#1515 the turn is asked again right before the merge" "3" "$rc"
check_eq "#1515 so nothing merged under the run that took it" "0" "$(count gh-calls 'pr merge')"
check_eq "#1515 and no gate was asked about a merge it may not make" "" "$(cat "$ST/red-gate-payloads" 2>/dev/null)"

# A run stopped by a signal while it holds the turn gives it up, so the next in line is not left to
# wait for the bound. The step signals the helper itself, the one sleeping (helper_pid).
fresh "$OLD" 0 "$PENDING"
printf '%s\n' "kill -TERM \$helper_pid" > "$ST/on-sleep"
out="$(run 7 --squash)"; rc=$?
check_eq "#1515 a holder sent TERM stops" "143" "$rc"
check "#1515 having held the turn" "Took the turn to merge in acme/widget" "$out"
check_eq "#1515 and gives its place up as it goes" "" "$(tickets)"

# A turn that cannot be taken is said, and the merge goes on as it did before: the turn decides only
# the order helpers merge in, and every gate still judges the merge.
fresh "$OLD" 0 "$GREEN"
: > "$WORKDIR/turns-not-a-folder"
out="$(MWR_TURN_DIR="$WORKDIR/turns-not-a-folder" run 7 --squash)"; rc=$?
check_eq "#1515 a turn folder that cannot be made does not stop a merge" "0" "$rc"
check "#1515 but says it goes on without a turn, and where" "Could not take a turn to merge in acme/widget (could not make $WORKDIR/turns-not-a-folder/acme/widget)" "$out"
check "#1515 and merges through the gates as before" "Merged #7 in acme/widget at ${OLD:0:7}" "$out"

# The front of the line (claude-config#2474). On 2026-11-08 #2471 made the sync suite cheaper, which
# the five pull requests ahead of it needed to pass CI, and it was moved forward by hand by stopping
# all five helpers. --first puts a run ahead of every run still waiting, never ahead of the run
# holding the turn, and says so; every gate still judges its merge.
# look-turn <slug>: a look from outside the line, as each waiter's look does, marking the holder.
cat > "$BIN/look-turn" <<EOS
#!/usr/bin/env bash
. "$TURN_LIB"
TURN_TICKET=""; turn_open "\$1" && turn_look "\$(cat "\$ST/clock")" 3600
EOS
chmod +x "$BIN/look-turn"
front_line(){ "$BIN/take-turn" acme/widget 9; "$BIN/look-turn" acme/widget; "$BIN/take-turn" acme/widget 8; }

fresh "$OLD" 0 "$GREEN"
front_line
printf '%s\n' "rm -f \"\$MWR_TURN_DIR/acme/widget/1\" \"\$MWR_TURN_DIR/acme/widget/1.head\"" > "$ST/on-sleep"
out="$(run 7 --squash --first)"; rc=$?
check_eq "#2474 a run started with --first merges" "0" "$rc"
check "#2474 saying it went to the front, ahead of the run waiting" "Joined the line to merge in acme/widget at the front (--first), ahead of 1 pull request waiting" "$out"
check "#2474 and that it still waits for the run holding the turn" "which #9 holds (1 ahead of it in line)" "$out"
check "#2474 then takes the turn when #9 leaves, before #8" "It is #7's turn to merge in acme/widget now" "$out"
check "#2474 and merges through the gates" "Merged #7 in acme/widget at ${OLD:0:7}" "$out"
check_eq "#2474 the run it passed keeps its place" "8" "$(ticket_prs)"
check_eq "#2474 nothing merged while #9 held the turn" "1" "$(count gh-calls 'pr merge')"

# Every gate still judges a run at the front: a refused merge is refused here as anywhere.
fresh "$OLD" 0 "$GREEN"
printf 'refused for the test' > "$ST/red-gate-deny"
out="$(run 7 --squash --first)"; rc=$?
check_eq "#2474 a run at the front is still stopped by a gate" "1" "$rc"
check "#2474 by block-red-merge.sh, as before" "block-red-merge.sh refused the merge of #7" "$out"
check_eq "#2474 and nothing merged" "0" "$(count gh-calls 'pr merge')"

# Nobody waiting: --first changes nothing, and says so.
fresh "$OLD" 0 "$GREEN"
out="$(run 7 --squash --first)"; rc=$?
check_eq "#2474 --first with nobody in line merges" "0" "$rc"
check "#2474 saying --first changed nothing" "--first changed nothing: nobody was waiting in line to merge in acme/widget" "$out"

# Failure paths. A pull request whose own checks are failing is not the fix the others need, and
# would only hold them up: --first is refused, loudly, and it joins at the back.
fresh "$OLD" 0 "$RED"
front_line
out="$(MWR_MAX_POLLS=2 run 7 --squash --first)"; rc=$?
check "#2474 --first is refused for a pull request whose own checks fail" "--first was refused for #7: its own checks are failing (tests)" "$out"
check "#2474 so it waits behind both, at the back" "which #9 holds (2 ahead of it in line)" "$out"
check_not "#2474 and never says it joined at the front" "at the front (--first)" "$out"
# Checks that cannot be read: not honoured, said, at the back.
fresh "$OLD" 0 '"not a list"'
front_line
out="$(MWR_MAX_POLLS=2 run 7 --squash --first)"; rc=$?
check "#2474 --first is not honoured when its checks cannot be read" "--first was not honoured for #7: GitHub's answer did not list its checks" "$out"
check "#2474 so it waits at the back" "which #9 holds (2 ahead of it in line)" "$out"
# Pending checks are not failing ones: a fix just pushed goes to the front while its checks run.
fresh "$OLD" 0 "$PENDING"
front_line
out="$(MWR_MAX_POLLS=2 run 7 --squash --first)"; rc=$?
check "#2474 a pull request whose checks are still running goes to the front" "at the front (--first), ahead of 1 pull request waiting" "$out"
check "#2474 behind only the holder" "which #9 holds (1 ahead of it in line)" "$out"
# Passed over while holding the turn, a run at the front joins again at the back, so a pull request
# stuck at the front cannot take the turn again and again ahead of the rest.
fresh "$OLD" 0 "$PENDING"
printf '%s\n' "rm -f \"\$MWR_TURN_DIR/acme/widget/1\" \"\$MWR_TURN_DIR/acme/widget/1.head\"; \"\$BIN_DIR/take-turn\" acme/widget 9; \"\$BIN_DIR/look-turn\" acme/widget; \"\$BIN_DIR/take-turn\" acme/widget 8" > "$ST/on-sleep"
out="$(BIN_DIR="$BIN" MWR_MAX_POLLS=3 run 7 --squash --first)"; rc=$?
check "#2474 a run at the front that is passed over is told its place there is not kept" "Its place at the front (--first) is not kept" "$out"
check "#2474 and waits behind both, at the back" "which #9 holds (2 ahead of it in line)" "$out"
# A stop that hands back the command to run again keeps --first in it, or copying it sends the run
# to the back of the line with nothing said.
fresh "$OLD" 0 "$GREEN"
out="$(run 7 --first)"; rc=$?
check "#2474 the command to run instead still carries --first" "merge-when-ready.sh 7 --repo acme/widget --squash --first" "$out"
# --first takes no value: anything attached to it is refused before any call, like any other word.
fresh "$OLD" 0 "$GREEN"
out="$(run 7 --squash --first=yes)"; rc=$?
check_eq "#2474 --first=yes is refused" "64" "$rc"
check_eq "#2474 before any call to GitHub" "" "$(cat "$ST/gh-calls" 2>/dev/null)"

# =================================================================================================
# 23. A deliberate load window is named beside a failure (claude-config#1618). On 2026-10-23 this
#     helper stopped five times on GitHub reads at a load average of 342 while a builder's load
#     reproduction ran, and nothing it said named that load. tools/load-window.sh records each
#     window; a stop that is not a merge, and every read asked again, says the running or just ended
#     one, in ET. A merge that lands says nothing about it.
# =================================================================================================
rm -rf "$LOAD_WINDOW_DIR"
fresh "$OLD" 0 "$GREEN"
printf 'Refusing to merge PR #7 at 1111111 until every area it touches has a passing verification run there.' > "$ST/verify-gate-deny"
out="$(run 7 --squash)"; rc=$?
check_eq "#1618 with no window recorded, a refusal still stops" "1" "$rc"
check_not "#1618 and says nothing about a load window" "load window" "$out"

( . "$DIR/lib/load-window.sh" && load_window_begin "w1" 999900 1000080 4242 24 6 "repro of #1620" )
fresh "$OLD" 0 "$GREEN"
printf 'Refusing to merge PR #7 at 1111111 until every area it touches has a passing verification run there.' > "$ST/verify-gate-deny"
out="$(run 7 --squash)"; rc=$?
check_eq "#1618 a refusal during a load window still stops" "1" "$rc"
check "#1618 and names the window running, with its workers and label" "A deliberate load window is running on this Mac (tools/load-window.sh, pid 4242, 24 busy and 6 process launching workers, \"repro of #1620\")" "$out"
check "#1618 in ET, on the helper's own clock" "until 08:48:00 ET at the latest" "$out"

fresh "$OLD" 0 "$GREEN"
printf '%s\n' "$SIGNIN" > "$ST/view-fails"
out="$(run 7 --squash)"; rc=$?
check_eq "#1618 a read asked again during a window still merges" "0" "$rc"
check "#1618 and the retry names the window" "GitHub refused the sign in reading pull request #7 (try 1 of 4" "$out"
check "#1618 right beside it" "A deliberate load window is running on this Mac" "$out"

fresh "$OLD" 0 "$GREEN"
out="$(run 7 --squash)"; rc=$?
check_eq "#1618 a green merge during a window" "0" "$rc"
check_not "#1618 says nothing about it once merged" "load window" "$out"

( . "$DIR/lib/load-window.sh" && load_window_finish "w1" 999990 "the command finished (exit 0)" )
fresh "$OLD" 0 "$GREEN"
printf 'Refusing to merge PR #7 at 1111111 until every area it touches has a passing verification run there.' > "$ST/verify-gate-deny"
out="$(run 7 --squash)"; rc=$?
check "#1618 a window that ended minutes before is named as ended" "A deliberate load window ran on this Mac from 08:45:00 ET to 08:46:30 ET" "$out"

# =================================================================================================
# 24. Never a turn it cannot finish (claude-config#1604). On 2026-10-23 about 20 helpers queued in
#     one repository, each spent most of its three hour deadline in line, took the turn, updated its
#     pull request (restarting checks of 10 to 20 minutes) and ran out with them still running: three
#     turns in a row were lost and nothing merged for about three hours. Now the deadline counts from
#     when the turn is taken, the wait in line has its own budget (MWR_LINE_SECONDS), and a run whose
#     time left is shorter than the repository's recent check runs does not take the turn at all.
# =================================================================================================
# runs_of <sha:start:took[:conclusion[:attempt]]>...: GitHub's answer for the repository's recent
# runs, each created <start> seconds after a fixed moment and finished <took> seconds later.
runs_of(){ printf '%s\n' "$@" | jq -R -s '{total_count: 0, workflow_runs: [split("\n")[] | select(. != "") | split(":") | {head_sha: .[0], event: "pull_request", status: "completed", conclusion: (.[3] // "success"), run_attempt: ((.[4] // "1") | tonumber), created_at: ((1761200000 + (.[1] | tonumber)) | todate), updated_at: ((1761200000 + (.[1] | tonumber) + (.[2] | tonumber)) | todate)}]}'; }
# The step that ends #9's hold, whichever ticket it has.
LEAVE9='for f in "$MWR_TURN_DIR"/acme/widget/[0-9]*; do grep -qx "pr 9" "$f" && rm -f "$f" "$f.head"; done'

# The deadline counts from the turn: a run that waited in line longer than its whole deadline still
# has all of it once the turn is its, updates, waits out the new head's checks and merges.
fresh "$OLD" 2 "$GREEN"; printf '%s\n' "$NEW" > "$ST/next-heads"
"$BIN/take-turn" acme/widget 9
for _ in $(seq 1 9); do printf ':\n' >> "$ST/on-sleep"; done
printf '%s\n' "$LEAVE9" ':' ':' ':' "printf '%s' '$GREEN' > \"\$ST/rollup\"" >> "$ST/on-sleep"
out="$(MWR_DEADLINE_SECONDS=200 run 7 --squash)"; rc=$?
check_eq "#1604 a run that waited in line past its deadline still merges once the turn is its" "0" "$rc"
check "#1604 having waited for the turn" "It is #7's turn to merge in acme/widget now, after waiting 5m 00s for it" "$out"
check "#1604 saying its deadline runs from the turn" "Its 3m 20s to merge counts from now" "$out"
check_eq "#1604 it updated once, after taking the turn" "1" "$(count gh-calls 'pr update-branch')"
check "#1604 and merged the updated head" "Merged #7 in acme/widget at ${NEW:0:7}" "$out"
check_eq "#1604 the whole run lasted longer than the deadline" "yes" "$( [ "$(el)" -gt 200 ] && echo yes || echo no)"

# Control: the deadline still bounds the run once the turn is taken, counted from that moment.
fresh "$OLD" 0 "$PENDING"
"$BIN/take-turn" acme/widget 9
for _ in $(seq 1 9); do printf ':\n' >> "$ST/on-sleep"; done
printf '%s\n' "$LEAVE9" >> "$ST/on-sleep"
out="$(MWR_DEADLINE_SECONDS=200 run 7 --squash)"; rc=$?
check_eq "#1604 a run whose checks never finish still runs out" "3" "$rc"
check "#1604 at the end of its deadline from the turn" "at the end of its 3m 20s deadline from taking the turn" "$out"
check_eq "#1604 two hundred seconds after the turn at five minutes, not before" "yes" "$( e="$(el)"; [ "$e" -ge 500 ] && [ "$e" -lt 560 ] && echo yes || echo no)"
check_eq "#1604 and nothing merged" "0" "$(count gh-calls 'pr merge')"

# The wait in line has its own budget: a run that never gets the turn stops at it, resumable.
fresh "$OLD" 2 "$GREEN"
"$BIN/take-turn" acme/widget 9
out="$(MWR_LINE_SECONDS=600 MWR_TURN_HOLD_SECONDS=100000 run 7 --squash)"; rc=$?
check_eq "#1604 a run never given the turn stops at its line budget" "3" "$rc"
check "#1604 naming what it waited for" "is waiting for its turn to merge in acme/widget, which #9 holds" "$out"
check "#1604 and that its time in line ran out, the line standing still (#1697)" "nothing ahead of it in line has moved for 10m (MWR_LINE_SECONDS)" "$out"
check_eq "#1604 after ten minutes" "yes" "$( e="$(el)"; [ "$e" -ge 600 ] && [ "$e" -lt 630 ] && echo yes || echo no)"
check_eq "#1604 updating nothing" "0" "$(count gh-calls 'pr update-branch')"
check_eq "#1604 and its place is given up" "9" "$(ticket_prs)"

# Its default line budget, measured by running it out (L107): three hours, and the most a run can
# last is that plus its deadline from the turn.
fresh "$OLD" 0 "$GREEN"
"$BIN/take-turn" acme/widget 9
out="$(MWR_POLL_SECONDS=600 MWR_TURN_HOLD_SECONDS=100000 run 7 --squash)"; rc=$?
default_line=$(el)
check_eq "#1604 with no line budget set, a run never given the turn stops after three hours" "3 10800" "$rc $default_line"
# THE RATIO (L227), as #1271 holds it, over the longest a run can now last: is-it-live asks about a
# merge made in the background for WAIT_MS, so it must stay at least twice the line plus the deadline.
if [[ "${wait_s:-}" =~ ^[0-9]+$ ]]; then
  [ "$wait_s" -ge $(( 2 * (default_line + default_deadline) )) ] && ok || bad "#1604 is-it-live's WAIT_MS (${wait_s}s) is not at least twice the longest a run can last, its line budget plus its deadline ($(( default_line + default_deadline ))s)"
else
  bad "#1604 WAIT_MS was not read from is-it-live's merges.ts"
fi

# Too little time left to finish a check run: a run whose turn was taken over late in its deadline,
# and that comes round to the turn again, does not take it. It leaves the line so the next one goes.
retake(){ # retake <deadline> <recent run took>: the turn taken, taken over 2500s in, then given back
  fresh "$OLD" 0 "$PENDING"
  runs_of "a:0:$2" > "$ST/recent-runs"
  printf '%s\n' "printf '%s' \"\$(( \$(cat \"\$ST/clock\") + 2500 ))\" > \"\$ST/clock\"; rm -f \"\$MWR_TURN_DIR/acme/widget/1\" \"\$MWR_TURN_DIR/acme/widget/1.head\"; \"\$BIN_DIR/take-turn\" acme/widget 9" > "$ST/on-sleep"
  printf '%s\n' "$LEAVE9; printf '%s' '$GREEN' > \"\$ST/rollup\"" >> "$ST/on-sleep"
  out="$(BIN_DIR="$BIN" MWR_DEADLINE_SECONDS="$1" run 7 --squash)"; rc=$?
}
# It held the turn 42m 10s (a look, then the jump) and waited a look in line before it came back,
# all fixture settings, not measured; since #1975 the wait in line is not taken off its deadline,
# so 17m 50s is left (17m 20s before).
retake 3600 1200
check_eq "#1604 a run with less time left than a check run does not take the turn back" "3" "$rc"
check "#1604 it took the turn at first, with time enough" "Took the turn to merge in acme/widget" "$out"
check "#1604 then says why it will not take it again" "Did not take the turn to merge in acme/widget back: 17m 50s is left of #7's 60m deadline, shorter than the 20m 00s its recent check runs took" "$out"
check_eq "#1604 its place is given up, so the next in line goes now" "" "$(tickets)"
check_eq "#1604 nothing was updated or merged" "0 0" "$(count gh-calls 'pr update-branch') $(count gh-calls 'pr merge')"
# Control, the other way (L497): with check runs shorter than the time left, it takes the turn back.
retake 3600 600
check_eq "#1604 control: with time enough left it takes the turn back and merges" "0" "$rc"
check "#1604 control: saying it is its turn again, with the time it has left" "It is #7's turn to merge in acme/widget now" "$out"
check "#1604 control: and how much of its deadline is left" "17m 50s of its 60m deadline is left" "$out"
check_not "#1604 control: never a refusal" "Did not take the turn" "$out"

# A whole deadline shorter than the check runs can never be finished: it stops at once, for a person.
fresh "$OLD" 2 "$GREEN"
runs_of "a:0:1200" > "$ST/recent-runs"
out="$(MWR_DEADLINE_SECONDS=600 run 7 --squash)"; rc=$?
check_eq "#1604 a deadline shorter than the check runs is refused before the turn" "1" "$rc"
check "#1604 saying so, and what to change" "Stopped: #7's whole deadline, 10m (MWR_DEADLINE_SECONDS), is shorter than the 20m 00s acme/widget's recent check runs took" "$out"
check_eq "#1604 with no wait" "0" "$(count sleeps .)"
check_eq "#1604 no update" "0" "$(count gh-calls 'pr update-branch')"
check_eq "#1604 and no place kept in line" "" "$(tickets)"
check "#1604 the runs read are the repository's recent successful pull request runs" "api repos/acme/widget/actions/runs?status=success&event=pull_request" "$(cat "$ST/gh-calls")"

# How long the check runs took: the longest of the ten most recent heads, each head's time from its
# first run created to its last finished (two workflows on one head are one check run), a re-run and
# a failure left out. Both directions (L497): a deadline just over the longest head is enough and one
# just under it is not (fixture values, not measured).
RECENT="$(runs_of "h0:0:5000" "h1:10000:600" "h2:11000:600" "h3:12000:600" "h4:13000:600" "h5:14000:600" "h5:14000:20000:success:2" "h6:15000:600" "h6:15000:30000:failure" "h7:16000:600" "h8:17000:600" "h9:18000:600" "h10:19000:600" "h10:19000:1300")"
fresh "$OLD" 0 "$GREEN"; printf '%s' "$RECENT" > "$ST/recent-runs"
out="$(MWR_DEADLINE_SECONDS=1350 run 7 --squash)"; rc=$?
check_eq "#1604 an older head, a re-run and a failure are not the check run time" "0" "$rc"
check "#1604 the longest recent head is said with the turn" "the longest of acme/widget's recent check runs took 21m 40s" "$out"
fresh "$OLD" 0 "$GREEN"; printf '%s' "$RECENT" > "$ST/recent-runs"
out="$(MWR_DEADLINE_SECONDS=1250 run 7 --squash)"; rc=$?
check_eq "#1604 two workflows on one head are one check run, as long as the longer" "1" "$rc"

# Not measured: GitHub answers no runs, or cannot be read. Either is said, and the turn is taken as
# before, its deadline weighed against nothing (the fallback: a retake late in a deadline can run
# out, as every turn could before #1604).
fresh "$OLD" 0 "$GREEN"
out="$(run 7 --squash)"; rc=$?
check_eq "#1604 no recent check runs: the turn is taken and the merge made" "0" "$rc"
check "#1604 saying there was nothing to weigh the deadline against" "no recent successful pull request check runs in acme/widget to weigh its deadline against" "$out"
fresh "$OLD" 0 "$GREEN"
printf 'gh: Server Error (HTTP 502)\n' > "$ST/recent-runs-down"
out="$(run 7 --squash)"; rc=$?
check_eq "#1604 an unreadable run list does not stop a merge" "0" "$rc"
check "#1604 but says it could not read them, with GitHub's error" "could not read how long acme/widget's recent check runs took (gh: Server Error (HTTP 502)" "$out"

# =================================================================================================
# 25. A run keeps its place while the line moves (claude-config#1697). On 2026-10-24 Slate had about
#     15 pull requests in one line at about 20 minutes a merge, longer than the fixed three hours in
#     line, and #4148, #4164 and #4177 each ran out (exit 3, "at the end of its 180m in line for a
#     turn") with the line still moving, and were queued again by hand at the back. Now
#     MWR_LINE_SECONDS counts only time in which nothing ahead advanced. While it waits in line it
#     reads GitHub less often (the wait grows, as on checks), and reads its turn locally every base
#     look, so a turn passing is still taken at once. The ceiling #1697 also put on the whole wait,
#     nine hours from the run's start however much the line moved, is gone (claude-config#2351): on
#     2026-11-06 it ended 11 helpers 1 to 3 places from the front of a line still moving, and each
#     joined again behind about 20 others. A line that keeps moving now never ends a run, by clock or
#     by its count of looks; a line standing still still does.
# =================================================================================================
# leave <pr> is lib/merge-when-ready-harness.sh's, since section 30 (test-merge-when-ready-line.sh)
# reads it too.

# Three ahead, each leaving after 15 looks of 30s: the run waits 22m 30s in all, far past a 10m line
# budget, but the line never stands still for 10m, so it keeps its place and merges. Every figure
# here is a fixture setting, not measured.
fresh "$OLD" 0 "$GREEN"
for p in 9 10 11; do "$BIN/take-turn" acme/widget "$p"; done
for p in 9 10 11; do
  for _ in $(seq 1 14); do printf ':\n' >> "$ST/on-sleep"; done
  leave "$p" >> "$ST/on-sleep"; printf '\n' >> "$ST/on-sleep"
done
out="$(MWR_LINE_SECONDS=600 MWR_TURN_HOLD_SECONDS=100000 run 7 --squash)"; rc=$?
check_eq "#1697 a run whose line keeps moving waits past its line budget and merges" "0" "$rc"
check "#1697 and the merge landed" "Merged #7 in acme/widget at ${OLD:0:7}" "$out"
check_eq "#1697 having waited longer than the line budget" "yes" "$( [ "$(el)" -gt 600 ] && echo yes || echo no)"
check "#1697 saying once it passed the budget that it keeps its place because the line is moving" "has waited over 10m in line, but the line is still moving" "$out"
check_eq "#1697 said once, not at every look" "1" "$(grep -c 'but the line is still moving' <<<"$out")"
check_not "#1697 never said as out of time" "Out of time" "$out"

# Control, the line standing still (L497): the holder never leaves, so the same budget ends the wait,
# said as the line not moving, never as a line still moving.
fresh "$OLD" 0 "$GREEN"
"$BIN/take-turn" acme/widget 9
out="$(MWR_LINE_SECONDS=600 MWR_TURN_HOLD_SECONDS=100000 run 7 --squash)"; rc=$?
check_eq "#1697 control: a line that never moves stops at the line budget" "3" "$rc"
check "#1697 control: said as nothing ahead having moved for the budget" "nothing ahead of it in line has moved for 10m (MWR_LINE_SECONDS)" "$out"
check_not "#1697 control: never as the line still moving" "still moving" "$out"
check_eq "#1697 control: after ten minutes still" "yes" "$( e="$(el)"; [ "$e" -ge 600 ] && [ "$e" -lt 630 ] && echo yes || echo no)"

# Its count of looks follows the line too (claude-config#2351, L704): the looks it takes in line up
# to each move of the line are not held against MWR_MAX_POLLS, so a long line that keeps moving never
# runs it out of looks, while a line standing still still does. Six ahead, each leaving after ten
# looks, sixty looks in line in all, against a cap of twenty. Fixture settings, not measured.
fresh "$OLD" 0 "$GREEN"
for p in 9 10 11 12 13 14; do "$BIN/take-turn" acme/widget "$p"; done
for p in 9 10 11 12 13 14; do
  for _ in $(seq 1 9); do printf ':\n' >> "$ST/on-sleep"; done
  leave "$p" >> "$ST/on-sleep"; printf '\n' >> "$ST/on-sleep"
done
out="$(MWR_LINE_SECONDS=600 MWR_MAX_POLLS=20 MWR_TURN_HOLD_SECONDS=100000 run 7 --squash)"; rc=$?
check_eq "#2351 a long line that keeps moving does not run a run out of looks" "0" "$rc"
check "#2351 and the merge landed" "Merged #7 in acme/widget at ${OLD:0:7}" "$out"
check_not "#2351 never said as the most looks it makes" "MWR_MAX_POLLS" "$out"
check_not "#2351 never out of time" "Out of time" "$out"

# Control, the line standing still (L497): the same cap of twenty looks, a holder that never leaves
# and a line budget too long to end it first, so the count still ends the wait.
fresh "$OLD" 0 "$GREEN"
"$BIN/take-turn" acme/widget 9
out="$(MWR_LINE_SECONDS=100000 MWR_MAX_POLLS=20 MWR_TURN_HOLD_SECONDS=100000 run 7 --squash)"; rc=$?
check_eq "#2351 control: behind a line standing still the count of looks still ends the wait" "3" "$rc"
check "#2351 control: said as the most looks it makes" "the most it makes (MWR_MAX_POLLS)" "$out"
check_eq "#2351 control: nothing merged" "0" "$(count gh-calls 'pr merge')"

# The shared polling budget (L24): in line, GitHub is read only every MWR_LINE_LOOK_SECONDS
# (claude-config#2715), while the turn is read locally at every base look, so a turn passing mid
# wait is taken at once. #9 leaves
# after twelve minutes of one minute looks.
fresh "$OLD" 0 "$GREEN"
"$BIN/take-turn" acme/widget 9
for _ in $(seq 1 11); do printf ':\n' >> "$ST/on-sleep"; done
leave 9 >> "$ST/on-sleep"; printf '\n' >> "$ST/on-sleep"
out="$(MWR_POLL_SECONDS=60 MWR_POLL_MAX_SECONDS=180 run 7 --squash)"; rc=$?
check_eq "#1697 a run in line, reading GitHub every ten minutes, still merges" "0" "$rc"
check "#1697 taking the turn the look after it passed, not at its next ten minute look at GitHub" "after waiting 12m 00s for it" "$out"
check_eq "#1697 never sleeping longer than a base look in line" "60" "$(sort -n "$ST/sleeps" | tail -1)"
reads_in_line="$(awk '$1 < 1000720' "$ST/view-times" | wc -l | tr -d ' ')"
check_eq "#1697 reading GitHub fewer times than once a minute while in line (2 reads in its 12 minutes in line, at its first look and ten minutes later, claude-config#2715; 5 on the growing wait before it, 12 at one a minute)" "2" "$reads_in_line"

# A long line that keeps moving, at the default settings (claude-config#2351): each of twenty pull
# requests ahead holds the turn for a look of 30m and is passed over, ten hours in all, past the nine
# hours (540m) that used to end the wait from the run's start. A line moving at every look never ends
# the run, so it waits its whole way to the front and merges. One place among them belongs to a run
# that has died, and is still passed over at once, as before.
fresh "$OLD" 0 "$GREEN"
for p in $(seq 101 110); do "$BIN/take-turn" acme/widget "$p"; done
"$BIN/take-turn" acme/widget 130 99999999 "Thu Jan  1 00:00:00 1970"
for p in $(seq 111 120); do "$BIN/take-turn" acme/widget "$p"; done
out="$(MWR_POLL_SECONDS=1800 MWR_HEARTBEAT_SECONDS=1800 MWR_TURN_HOLD_SECONDS=1800 run 7 --squash)"; rc=$?
check_eq "#2351 a run in a long line that keeps moving waits past 540m and merges" "0" "$rc"
check "#2351 and the merge landed" "Merged #7 in acme/widget at ${OLD:0:7}" "$out"
check_eq "#2351 having waited past the 540m that used to end it" "yes" "$( [ "$(el)" -gt 32400 ] && echo yes || echo no)"
check_not "#2351 never out of time" "Out of time" "$out"
check "#2351 a dead run's place is still passed over" "#130's place in line was passed over: its run (pid 99999999) is no longer running." "$out"

# Control, a long line that then stands still (L497): the same twenty go, one a look, then #121 holds
# the turn and is never passed over, so three hours (MWR_LINE_SECONDS, the default) after the line last
# moved, the run stops, said as the line standing still, and gives up its place.
fresh "$OLD" 0 "$GREEN"
for p in $(seq 101 121); do "$BIN/take-turn" acme/widget "$p"; done
for p in $(seq 101 120); do leave "$p" >> "$ST/on-sleep"; printf '\n' >> "$ST/on-sleep"; done
out="$(MWR_POLL_SECONDS=1800 MWR_HEARTBEAT_SECONDS=1800 MWR_TURN_HOLD_SECONDS=100000 run 7 --squash)"; rc=$?
check_eq "#2351 control: a long line that stops moving still ends the wait" "3" "$rc"
stop_line="$(grep 'Out of time' <<<"$out")"
check "#2351 control: its stop said as nothing ahead having moved for three hours" "nothing ahead of it in line has moved for 180m (MWR_LINE_SECONDS)" "$stop_line"
check_not "#2351 control: its stop never as a line still moving" "still moving" "$stop_line"
check_eq "#2351 control: three hours after the last of the twenty went (ten hours in)" "yes" "$( e="$(el)"; [ "$e" -ge 46800 ] && [ "$e" -lt 48600 ] && echo yes || echo no)"
check_eq "#2351 control: nothing merged" "0" "$(count gh-calls 'pr merge')"
check_eq "#2351 control: and its place is given up" "121" "$(ticket_prs)"
# THE RATIO (L227): with no ceiling on a moving line, the longest a run lasts is no longer one fixed
# figure; the check of is-it-live's WAIT_MS against the line budget plus the deadline (#1604, above)
# is the one that still holds, for a line standing still.

# A run passed over and back in line (claude-config#1975). On 2026-10-30 #1962 took the turn, held
# it the hour any one pull request may, was passed over and joined the line again, and stopped at
# 181m saying in one second both that it keeps its place because the line still moved and that it
# was out of time at the end of its 180m deadline from taking the turn: the deadline went on
# counting through the wait in line, so the line rule never governed it. Now the deadline counts
# only time the run holds the turn (or goes on without one), and the line rule governs every wait
# in line, its time in line counting only time spent waiting. Scaled down by twelve, every figure a
# fixture setting: deadline 15m (180m), line 15m (180m), passed over at 5m (60m), each holder
# ahead leaving after 4m.
# drive: run after every fake sleep. At DRIVE_STEAL_AT seconds in, this run's ticket (1) is taken
# away and DRIVE_AHEAD join ahead of it, as a waiter passing it over would leave things; then every
# DRIVE_LEAVE_EVERY seconds the first of them leaves, and once none is left the checks go green.
cat > "$BIN/drive" <<EOS
#!/usr/bin/env bash
rel=\$(( \$(cat "\$ST/clock") - 1000000 ))
q="\$MWR_TURN_DIR/acme/widget"
if [ ! -e "\$ST/stolen" ] && [ "\$rel" -ge "\$DRIVE_STEAL_AT" ]; then
  rm -f "\$q/1" "\$q/1.head"
  for p in \$DRIVE_AHEAD; do "$BIN/take-turn" acme/widget "\$p"; done
  printf '%s' "\$rel" > "\$ST/stolen"; printf '%s' "\$rel" > "\$ST/last-leave"
  exit 0
fi
[ -e "\$ST/stolen" ] && [ "\${DRIVE_LEAVE_EVERY:-0}" -gt 0 ] || exit 0
[ \$(( rel - \$(cat "\$ST/last-leave") )) -ge "\$DRIVE_LEAVE_EVERY" ] || exit 0
for t in \$(ls "\$q" | grep -E '^[0-9]+\$' | sort -n); do
  grep -qx "pr 7" "\$q/\$t" && continue
  rm -f "\$q/\$t" "\$q/\$t.head"; break
done
printf '%s' "\$rel" > "\$ST/last-leave"
others=0
for t in \$(ls "\$q" | grep -E '^[0-9]+\$'); do grep -qx "pr 7" "\$q/\$t" || others=\$(( others + 1 )); done
[ "\$others" -gt 0 ] || [ -n "\${DRIVE_NO_GREEN:-}" ] || printf '%s' '$GREEN' > "\$ST/rollup"
EOS
chmod +x "$BIN/drive"
drive_queue(){ local i; for i in $(seq 1 400); do printf '"$BIN_DIR/drive"\n' >> "$ST/on-sleep"; done; }
# secs_of <line>: the elapsed figure a said line carries ([Xm YYs]), in seconds.
secs_of(){ local l="${1%%$'\n'*}"; [[ "$l" =~ ^merge-when-ready:\ \[([0-9]+)m\ ([0-9]+)s\] ]] && printf '%s' $(( 10#${BASH_REMATCH[1]} * 60 + 10#${BASH_REMATCH[2]} )); }
# Every run here: deadline 15m, line budget 15m, and no holder passed over by this run. It looks
# every 60s rather than the suite's 30 (claude-config#2674): measured on 2026-11-10, each look in a
# line of several cost about 90 processes, and these four runs were a fifth of the suite's time, and every figure they judge
# (passed over at 5m, a holder leaving every 4m, the 15m budgets) is a whole number of minutes, so a
# look lands on each of them at either pace.
line_run(){ MWR_POLL_SECONDS=60 MWR_DEADLINE_SECONDS=900 MWR_LINE_SECONDS=900 MWR_TURN_HOLD_SECONDS=100000 BIN_DIR="$BIN" run 7 --squash; }

# Passed over at 5m, then five ahead each leaving after 4m: it waits 20m in line, past its 15m line
# budget and past 15m from taking the turn, with the line never still for 15m, so it keeps waiting,
# says once (and only once its time in line is past the budget) that it keeps its place, takes the
# turn back with the deadline it had not used, and merges.
fresh "$OLD" 0 "$PENDING"; drive_queue
out="$(DRIVE_STEAL_AT=300 DRIVE_AHEAD="9 10 11 12 13" DRIVE_LEAVE_EVERY=240 line_run)"; rc=$?
check_eq "#1975 a run passed over and waiting in a moving line past its deadline from the turn merges" "0" "$rc"
check "#1975 it was passed over and joined the line again" "#7's place in the line to merge in acme/widget is gone" "$out"
check "#1975 and the merge landed" "Merged #7 in acme/widget at ${OLD:0:7}" "$out"
check_eq "#1975 the run lasted past its deadline from the turn" "yes" "$( [ "$(el)" -gt 900 ] && echo yes || echo no)"
check_not "#1975 never out of time" "Out of time" "$out"
check_not "#1975 never at the end of its deadline from taking the turn" "deadline from taking the turn" "$out"
note="$(grep 'but the line is still moving' <<<"$out")"
check_eq "#1975 it says once that it keeps its place" "1" "$(grep -c . <<<"$note")"
check_eq "#1975 and only once its time in line, not its whole run, is past the line budget (5m held + 15m in line)" "yes" "$( s="$(secs_of "$note")"; [ -n "$s" ] && [ "$s" -ge 1200 ] && echo yes || echo no)"
check "#1975 it takes the turn back with the deadline it held the turn for taken off, not its wait in line" "10m 00s of its 15m deadline is left" "$out"

# Control, the line standing still (L497): passed over the same way, nobody ahead ever leaves, so it
# stops at its line budget, said as the line standing still, 15m after it joined the line again.
fresh "$OLD" 0 "$PENDING"; drive_queue
out="$(DRIVE_STEAL_AT=300 DRIVE_AHEAD="9" line_run)"; rc=$?
check_eq "#1975 control: behind a line that stopped moving it still stops" "3" "$rc"
check "#1975 control: said as nothing ahead having moved for the budget" "nothing ahead of it in line has moved for 15m (MWR_LINE_SECONDS)" "$out"
check_not "#1975 control: never as its deadline from the turn" "deadline from taking the turn" "$out"
check_not "#1975 control: never as the line still moving" "still moving" "$out"
check_eq "#1975 control: 15m after joining the line again at 5m" "yes" "$( e="$(el)"; [ "$e" -ge 1200 ] && [ "$e" -lt 1260 ] && echo yes || echo no)"
check_eq "#1975 control: nothing merged" "0" "$(count gh-calls 'pr merge')"

# A long moving line after being passed over (claude-config#2351): twelve ahead, one leaving every
# 4m, 48m in line, past the 45m (540m scaled down by twelve) that used to end the wait. The line
# never stands still for 15m, so it waits its whole way back to the front and merges.
fresh "$OLD" 0 "$PENDING"; drive_queue
out="$(DRIVE_STEAL_AT=300 DRIVE_AHEAD="$(seq -s ' ' 9 20)" DRIVE_LEAVE_EVERY=240 line_run)"; rc=$?
check_eq "#2351 passed over, a run in a long moving line waits through it and merges" "0" "$rc"
check "#2351 passed over: and the merge landed" "Merged #7 in acme/widget at ${OLD:0:7}" "$out"
check_eq "#2351 passed over: past 45m in line after the 5m it held the turn" "yes" "$( [ "$(el)" -gt 3000 ] && echo yes || echo no)"
check_not "#2351 passed over: never out of time" "Out of time" "$out"

# The deadline still bounds the time it holds the turn, over both holds: passed over at 5m, back
# at 9m with 10m left, and its checks never finish, so it stops at 19m, 15m of holding in all.
fresh "$OLD" 0 "$PENDING"; drive_queue
out="$(DRIVE_STEAL_AT=300 DRIVE_AHEAD="9" DRIVE_LEAVE_EVERY=240 DRIVE_NO_GREEN=1 line_run)"; rc=$?
check_eq "#1975 deadline: a run holding the turn again still runs out" "3" "$rc"
check "#1975 deadline: at the end of its deadline, said as counted only while it held the turn" "at the end of its 15m deadline from taking the turn, counted only while it held the turn" "$out"
check_eq "#1975 deadline: 5m held, 4m in line, then the 10m it had left" "yes" "$( e="$(el)"; [ "$e" -ge 1140 ] && [ "$e" -lt 1200 ] && echo yes || echo no)"
check_eq "#1975 deadline: nothing merged" "0" "$(count gh-calls 'pr merge')"

# =================================================================================================
# 26. The phase it publishes for tools/load-window.sh (claude-config#1676): waiting while it sleeps
#     on GitHub, renewed before each wait and good only until that wait is over (plus a minute);
#     local while the gates are asked and while its lessons review runs; gone once it ends. A run
#     killed outright leaves its record, which then says nothing, because its pid no longer runs.
# =================================================================================================
MP_LIBS=". \"$DIR/lib/merge-turn.sh\" && . \"$DIR/lib/merge-phase.sh\""
SNAP='cat "$MWR_PHASE_DIR"/[0-9]* >> "$ST/phases-seen" 2>/dev/null; echo --- >> "$ST/phases-seen"'
fresh "$OLD" 0 "$PENDING"
printf '%s\n' "$SNAP" "$SNAP; printf '%s' '$GREEN' > \"\$ST/rollup\"" > "$ST/on-sleep"
out="$(run 7 --squash)"; rc=$?
check_eq "#1676 a merge that waited on its checks still merges" "0" "$rc"
seen1="$(awk '/^---$/{exit} {print}' "$ST/phases-seen" 2>/dev/null)"
check "#1676 while it sleeps on its checks it says it is waiting" "phase waiting" "$seen1"
check "#1676 on what" "checks still running" "$seen1"
check "#1676 good until the end of that wait and a minute more, on its own clock" "until 1000090" "$seen1"
check_eq "#1676 every gate is asked while it says it is doing local work" "local" "$(sort -u "$ST/phase-at-gate" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
check_eq "#1676 and once it has merged it leaves no record" "" "$(ls "$MWR_PHASE_DIR" 2>/dev/null | grep -E '^[0-9]+$')"

# Its lessons review running in the background is local work, so the wait beside it is too.
fresh "$OLD" 0 "$GREEN"
printf '3\n0\n' > "$ST/review-answers"
printf '%s\n' "$SNAP" > "$ST/on-sleep"
out="$(run 7 --squash)"; rc=$?
check_eq "#1676 a merge whose review ran a while still merges" "0" "$rc"
seen1="$(awk '/^---$/{exit} {print}' "$ST/phases-seen" 2>/dev/null)"
check "#1676 while its lessons review runs it says it is doing local work" "phase local" "$seen1"
check "#1676 naming the review" "lessons review" "$seen1"

# Killed outright mid wait (L409, L617): while it runs, a reader believes its record; once it is
# killed the record stays behind, and says nothing.
fresh "$OLD" 0 "$PENDING"
printf '%s\n' "( $MP_LIBS && mp_waiting \$helper_pid \$(cat \"\$ST/clock\") ) && echo believed > \"\$ST/verdict-alive\"; echo \$helper_pid > \"\$ST/helper-pid\"; kill -9 \$helper_pid" > "$ST/on-sleep"
# The shell running the helper reports the kill ("Killed: 9 bash $HELPER") on its own stderr, which is
# not the helper's output and nothing here reads. It is dropped: printed into the suite's own output, at
# the tail of every run, it was read as a helper killed at its deadline and blamed for a failure two
# sections earlier (claude-config#2327).
out="$(run 7 --squash 2>/dev/null)"; rc=$?
hp="$(cat "$ST/helper-pid" 2>/dev/null)"
check_eq "#1676 control: while the run is alive and waiting, its record is believed" "believed" "$(cat "$ST/verdict-alive" 2>/dev/null)"
check_eq "#1676 a run killed outright leaves its record behind" "yes" "$( [ -n "$hp" ] && [ -e "$MWR_PHASE_DIR/$hp" ] && echo yes || echo no)"
check_eq "#1676 which is not believed once its run has gone" "busy" "$( ( eval "$MP_LIBS" && mp_waiting "$hp" "$(cat "$ST/clock")" ) && echo waiting || echo busy)"

# =================================================================================================
# 26b. A gate that ran out of its own time decided nothing, so it is asked again (claude-config#2558).
#     On 2026-11-09, with the Mac out of memory, the helper stopped three times on
#     check-work-names-merge.sh saying its read budget of 15 seconds was spent, and each stopped pull
#     request lost its place in the line. The refusal each gate gives then is read from the gate's own
#     source here, so a gate rewording it fails this section rather than going back to stopping.
# =================================================================================================
export MWR_GATE_TIMEOUT_TRIES=3 MWR_GATE_TIMEOUT_RETRY_SECONDS=11
asks(){ grep -c 'tool_input' "$ST/work-names-gate-payloads" 2>/dev/null || true; }
for g in check-work-names-merge.sh check-closing-merge.sh require-verification-run.sh lessons-merge-gate.sh; do
  spent="$(sed -n 's/^BUDGET_SPENT="\(.*\)"$/\1/p' "$DIR/$g")"; spent="${spent//\$READ_DEADLINE/15}"
  check "#2558 $g says in its source when its read budget was spent" "seconds was spent" "$spent"
  fresh "$OLD" 0 "$GREEN"
  printf 'Refusing to merge PR #7: GitHub could not be read for payload/x: %s.\n' "$spent" "$spent" > "$ST/work-names-gate-queue"
  printf '\n' >> "$ST/work-names-gate-queue"
  out="$(run 7 --repo acme/widget --squash)"; rc=$?
  check_eq "#2558 a gate saying what $g says when it ran out of time is asked again, and the merge goes through" "0" "$rc"
  check_eq "#2558 ($g's wording) asked three times at the first look and once at the merge" "4" "$(asks)"
  check_eq "#2558 ($g's wording) the wait between asks is the injected one, twice" "2" "$(count sleeps '^11$')"
done
check "#2558 the retried timeout is said in the run's log, naming the gate" "work-names-gate.sh ran out of its own time and decided nothing (ask 1 of 3); asking it again in 11s" "$out"
check_eq "#2558 and the merge is made once" "1" "$(count gh-calls 'pr merge')"
# Out of time on every ask: it stops, as before, but only after the bounded asks, and says so.
fresh "$OLD" 0 "$GREEN"
printf 'Refusing to merge PR #7: %s.\n' "this hook's read budget of 15 seconds was spent before it could be read" > "$ST/work-names-gate-deny"
out="$(run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#2558 a gate out of time on every ask still stops the helper" "1" "$rc"
check_eq "#2558 after exactly the bounded number of asks" "3" "$(asks)"
check "#2558 saying it ran out of time on every ask" "ran out of its own time on each of 3 asks" "$out"
check_eq "#2558 and nothing is merged" "0" "$(count gh-calls 'pr merge')"
# A gate that decided to refuse stops the merge at once: asked once, no wait.
fresh "$OLD" 0 "$GREEN"
printf 'Refusing to merge PR #7: it names a work organisation. title:1: a work organisation name' > "$ST/work-names-gate-deny"
out="$(run 7 --repo acme/widget --squash)"; rc=$?
check_eq "#2558 a gate that decided to refuse still stops the helper" "1" "$rc"
check_eq "#2558 asked once, never again" "1" "$(asks)"
check_eq "#2558 with no wait for it" "0" "$(count sleeps '^11$')"
check_not "#2558 and never said to have run out of time" "ran out of its own time" "$out"
unset MWR_GATE_TIMEOUT_TRIES MWR_GATE_TIMEOUT_RETRY_SECONDS

echo
mwr_harness_result
