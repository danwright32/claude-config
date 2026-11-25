#!/usr/bin/env bash
#
# slack-drafts-gate-harness.sh: the one world the suites of slack-drafts-only-gate.sh, and of its
# rule slack_drafts_only_gate.py, run the gate in (claude-config#3575).
#
# test-slack-drafts-only-gate.sh held every check of the gate, 2,633 of them, until on 2026-11-24 it
# ran past run-all-tests.sh's 1,200 second wall limit on GitHub's runners in three runs of four,
# each time stopping the config sync between the two Macs (L315). Its sections are now six suites,
# each a run of them in their order: test-slack-drafts-only-gate-scripts.sh, -written-files,
# -file-arguments, test-slack-drafts-only-gate.sh itself, -runners and -tools-cache. Every one of
# them runs the gate in the same world, so that world is here, once, and no suite holds a copy of
# it (L613): two copies of the throwaway folder or of a fixture could drift until a case passed in
# one suite against a file the others no longer made.
#
# Sourced, never run, after the suite has armed its own deadline (lib/suite-deadline.sh) and set
# DIR to the hooks folder. It is the opening of test-slack-drafts-only-gate.sh moved here unchanged,
# all of it but the shell functions: HOOK, the gate under test, refusing to go on when it is not
# there; NUDGE; T, a throwaway folder removed when the suite exits, and the judgement cache in it;
# and SEND_INPUT. Then sdg_harness_result, the totals, and, last, what one section set or made and a
# section in another suite reads. The functions every case is driven through (check, payload,
# bash_input, run_raw, run_tool, run_bash, refused, allowed and says) are not here: the gate knows a
# shell function only where the text calling it defines it (lib/unknown-program.py, #3304), so each
# suite holds its own copy of them as they are, and a plain run of it is judged as before.
#
# USE, in a suite:
#
#   DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   . "$DIR/lib/slack-drafts-gate-harness.sh" || { ...refuse to run... }
#   <the helper functions, copied as they are>
#   run_tool mcp__claude_ai_Slack__slack_send_message "$SEND_INPUT"
#   refused "the connector's send tool"
#   echo; sdg_harness_result   # last: the totals and the SUITE-RESULT line, returning 1 on a failure

HOOK="$DIR/slack-drafts-only-gate.sh"
# The gate's switched off refusal of a file run by a path it cannot work out (#2683) is switched on
# only where run_ur asks for it, never by whatever the caller's environment holds. A file sourced by
# one is refused either way (#2538).
unset SLACK_GATE_UNWORKED_PATHS
NUDGE="$(cd "$DIR/.." && pwd)/skills/nudge/nudge.py"

if [ ! -f "$HOOK" ]; then
  echo "FAIL: there is no slack-drafts-only-gate.sh beside this suite at $DIR, so no Slack send is refused."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

T="$(mktemp -d "${TMPDIR:-/tmp}/slack-gate.XXXXXXXX")" || exit 1
case "${T%/}" in ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$T'" >&2; exit 2 ;; esac
trap 'rm -rf "$T"' EXIT
# The gate keeps the judgements it allowed in a cache (claude-config#2918). Every case in this suite
# runs with one of its own, so the cache is in front of every judgement below, and none of them reads
# or writes the cache in this Mac's ~/.claude/state. The cost checks each start from an empty one, so
# they measure a cold judgement.
export SLACK_GATE_CACHE_DIR="$T/gate-cache"
unset SLACK_GATE_CACHE_TRACE

SEND_INPUT='{"channel_id": "C0TEST1", "thread_ts": "1730000000.000100", "message": "hello"}'

# The totals and the agreed result line run-all-tests.sh reads, returning 1 when anything failed,
# so a suite whose last command this is exits as it should.
sdg_harness_result() {
  echo "passed: $pass, failed: $fail"
  printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]
}

# What follows was each set or made by one section and read by a section in another suite, and is
# as it was there: the scripts that post and the copy of /nudge from the section on a script that
# posts; the transcript, data and config files and the sourced helpers from the one on a file handed
# to a script as data (#2362); POST from the one on a file written and run in the same command
# (#2721); and the gate that holds no reading, and the checkout and claude-sync to judge, from the
# one on the claude-sync line (#2784).
cat > "$T/alert.py" <<'PY'
import json, urllib.request
req = urllib.request.Request("https://slack.com/api/chat.postMessage", data=json.dumps({"text": "hi"}).encode())
urllib.request.urlopen(req)
PY
mkdir -p "$T/copy"
cp "$NUDGE" "$T/copy/nudge.py"
mkdir -p "$T/ds/proj"
printf '%s\n' '{"type":"user","message":{"content":"curl -X POST https://slack.com/api/chat.postMessage -d text=hi"}}' \
  '{"type":"assistant","message":{"content":"the gate refuses hooks.slack.com too"}}' > "$T/ds/session.jsonl"
printf '%s\n' '{"keys":{}}' > "$T/ds/claude-issue-findings.session.manifest"
printf '%s\n' '{"url": "https://slack.com/api/chat.postMessage", "text": "hi"}' > "$T/ds/msg.json"
printf '%s\n' 'curl -s -X POST https://hooks.slack.com/services/T0/B0/x -d text=hi' > "$T/ds/hook.conf"
mkdir -p "$T/sv/posts/lib" "$T/sv/quiet/lib"
cp "$T/ds/hook.conf" "$T/sv/posts/lib/x.sh"
printf '%s\n' 'echo "hi"' > "$T/sv/quiet/lib/x.sh"
POST="curl -s -X POST -d text=hi https://slack.com/api/chat.postMessage"
# The gate as it was before #3255, for the checks of that change to be seen to fail on (L1): a copy
# that holds no reading (ONCE False in slack_drafts_only_gate.py), so it parses a Python text again
# for each reading of it. The switch found and turned, or the copy is the gate itself and every
# check that must fail on it would be a pass of nothing (L100).
unheld_made="$T/unheld-gate"
mkdir -p "$unheld_made" && cp "$HOOK" "$unheld_made/" && cp -R "$DIR/lib" "$unheld_made/lib" \
  && sed 's/^ONCE = True$/ONCE = False/' "$DIR/slack_drafts_only_gate.py" > "$unheld_made/slack_drafts_only_gate.py"
# The checkout's own claude-sync, found by the one shared test (lib/checkout-root.sh, #1663); installed
# in ~/.claude there is no checkout, and the clone the sync runs from is read instead.
CS=""
REPO="$(bash "$DIR/lib/checkout-root.sh" "$DIR/.." 2>/dev/null || true)"
for c in "${REPO:+$REPO/claude-sync}" "$HOME/claude-config-sync/claude-sync"; do
  if [ -n "$c" ] && [ -f "$c" ]; then CS="$c"; break; fi
done
