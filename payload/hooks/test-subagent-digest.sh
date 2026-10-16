#!/usr/bin/env bash
# Tests for subagent-digest.py, which compresses a subagent transcript for the harvest
# (claude-config#124).
#
# Its docstring enumerates three outcomes and says exactly why they have to stay apart: it prints
# NOTHING when the transcript could not be read and NOTHING when the agent simply said nothing, so
# a caller reading only stdout files a corrupt transcript as an agent with no findings, which is
# the reassuring half of the pair and therefore the one that gets believed. That contract had no
# test at all. Every outcome a contract enumerates needs a check that PRODUCES it, not one that
# merely passes (L151).
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
D="$DIR/subagent-digest.py"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

command -v python3 >/dev/null 2>&1 || { echo "test-subagent-digest: python3 is not on PATH, so nothing was verified." >&2; exit 2; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.digest.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-subagent-digest: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

# A transcript is JSON lines. Built here rather than copied from a real one, so what each check
# depends on is visible in the check itself.
say() { # say <text>  -> one assistant line
  python3 -c 'import json,sys; print(json.dumps({"type":"assistant","message":{"content":[{"type":"text","text":sys.argv[1]}]}}))' "$1"
}
used() { # used <tool> <path>  -> one assistant tool_use line
  python3 -c 'import json,sys; print(json.dumps({"type":"assistant","message":{"content":[{"type":"tool_use","name":sys.argv[1],"input":{"file_path":sys.argv[2]}}]}}))' "$1" "$2"
}
asked() { # asked <text>  -> the user line the digest reads as the task
  python3 -c 'import json,sys; print(json.dumps({"type":"user","message":{"content":sys.argv[1]}}))' "$1"
}

# ---------------------------------------------------------------------------
# Outcome 0: a digest.
# ---------------------------------------------------------------------------
FULL="$TMPROOT/full.jsonl"
{ asked "Audit the retry path"; say "I found a swallowed error in the retry helper."; used Edit "/repo/retry.ts"; say "Nothing else stood out."; } > "$FULL"
out_full="$(python3 "$D" "$FULL" 2>&1)"; code_full=$?
[ "$code_full" -eq 0 ] \
  && check "a transcript with something in it exits 0" ok \
  || check "a transcript with something in it exits 0" "exit=$code_full out=$out_full"
grep -q 'swallowed error' <<< "$out_full" \
  && check "and prints what the agent said" ok \
  || check "and prints what the agent said" "out=$out_full"
grep -q '/repo/retry.ts' <<< "$out_full" \
  && check "and the files it touched" ok \
  || check "and the files it touched" "out=$out_full"
grep -q 'Audit the retry path' <<< "$out_full" \
  && check "and the task it was given" ok \
  || check "and the task it was given" "out=$out_full"

# ---------------------------------------------------------------------------
# Outcome 1: read fine, the agent said nothing. It must print nothing AND exit 1, because the exit
# code is the only thing separating this from the case below.
# ---------------------------------------------------------------------------
SILENT="$TMPROOT/silent.jsonl"
{ asked "Go and look"; used Read "/repo/thing.ts"; } > "$SILENT"
out_silent="$(python3 "$D" "$SILENT" 2>/dev/null)"; code_silent=$?
[ "$code_silent" -eq 1 ] \
  && check "an agent that said nothing exits 1" ok \
  || check "an agent that said nothing exits 1" "exit=$code_silent"
[ -z "$out_silent" ] \
  && check "and prints nothing" ok \
  || check "and prints nothing" "printed: $out_silent"

# ---------------------------------------------------------------------------
# Outcome 2: the transcript could not be read. Same empty stdout as outcome 1, different exit, and
# that difference is the entire contract.
# ---------------------------------------------------------------------------
out_gone="$(python3 "$D" "$TMPROOT/never-written.jsonl" 2>/dev/null)"; code_gone=$?
[ "$code_gone" -eq 2 ] \
  && check "a transcript that is not there exits 2" ok \
  || check "a transcript that is not there exits 2" "exit=$code_gone"
[ -z "$out_gone" ] \
  && check "and prints nothing, which is why the exit code has to differ" ok \
  || check "and prints nothing, which is why the exit code has to differ" "printed: $out_gone"
[ "$code_gone" -ne "$code_silent" ] \
  && check "unreadable and silent are told apart" ok \
  || check "unreadable and silent are told apart" "both exited $code_gone"

out_noargs="$(python3 "$D" 2>/dev/null)"; code_noargs=$?
[ "$code_noargs" -eq 2 ] \
  && check "called with no transcript at all it exits 2, not 1" ok \
  || check "called with no transcript at all it exits 2, not 1" "exit=$code_noargs"

# A file that exists but holds no JSON is READ successfully and yields nothing, so it is outcome 1.
# Worth pinning: it is the case most likely to be lumped in with unreadable by a later change.
GIBBERISH="$TMPROOT/gibberish.jsonl"; printf 'not json at all\nnor this\n' > "$GIBBERISH"
python3 "$D" "$GIBBERISH" >/dev/null 2>&1
[ "$?" -eq 1 ] \
  && check "a readable file holding no usable lines is silent, not unreadable" ok \
  || check "a readable file holding no usable lines is silent, not unreadable" "exit=$?"

# ---------------------------------------------------------------------------
# Tool RESULTS are left out on purpose: they are most of the bytes and none of the judgment. A
# change that started including them would still pass every check above.
# ---------------------------------------------------------------------------
WITHRESULT="$TMPROOT/withresult.jsonl"
{
  asked "Check the thing"
  say "The registry is empty."
  python3 -c 'import json; print(json.dumps({"type":"user","message":{"content":[{"type":"tool_result","content":"ENORMOUS-TOOL-OUTPUT-MARKER"}]}}))'
} > "$WITHRESULT"
out_wr="$(python3 "$D" "$WITHRESULT" 2>/dev/null)"
grep -q 'ENORMOUS-TOOL-OUTPUT-MARKER' <<< "$out_wr" \
  && check "tool results are left out of the digest" "the marker came through" \
  || check "tool results are left out of the digest" ok
grep -q 'The registry is empty' <<< "$out_wr" \
  && check "while what the agent said still comes through" ok \
  || check "while what the agent said still comes through" "out=$out_wr"

# ---------------------------------------------------------------------------
# The END of what the agent said is what survives trimming, because the observations it is still
# carrying when it wraps up are the ones worth filing.
# ---------------------------------------------------------------------------
LONG="$TMPROOT/long.jsonl"
{ asked "Look at everything"; say "OPENING-MARKER"; say "$(python3 -c 'print("filler. " * 400)')"; say "CLOSING-MARKER"; } > "$LONG"
out_long="$(python3 "$D" "$LONG" 500 2>/dev/null)"
grep -q 'CLOSING-MARKER' <<< "$out_long" \
  && check "trimming keeps the end of what the agent said" ok \
  || check "trimming keeps the end of what the agent said" "out=${out_long:0:200}"
grep -q 'OPENING-MARKER' <<< "$out_long" \
  && check "and drops the beginning" "the opening survived, so nothing was trimmed" \
  || check "and drops the beginning" ok
grep -qi 'trimmed' <<< "$out_long" \
  && check "and says it trimmed rather than silently shortening" ok \
  || check "and says it trimmed rather than silently shortening" "out=${out_long:0:200}"

# ---------------------------------------------------------------------------
# The TASK is capped too, and a cap that says nothing turns a complete brief into what reads as one
# cut off mid sentence. The harvest model then files exactly that as a finding (claude-config#860:
# three times in one day for one agent whose brief was whole). So a trimmed task carries a marker
# saying the digest cut it, at what length and out of how many characters, and a normal brief is
# not trimmed at all.
# ---------------------------------------------------------------------------
LONGTASK="$TMPROOT/longtask.jsonl"
long_task="$(python3 -c 'print("Brief opening. " + "brief body words. " * 1200 + "BRIEF-TAIL-MARKER")')"
{ asked "$long_task"; say "Done."; } > "$LONGTASK"
out_lt="$(python3 "$D" "$LONGTASK" 2>/dev/null)"
grep -q 'Brief opening' <<< "$out_lt" \
  && check "a long task keeps its opening" ok \
  || check "a long task keeps its opening" "out=${out_lt:0:200}"
grep -q 'BRIEF-TAIL-MARKER' <<< "$out_lt" \
  && check "a task past the cap is actually trimmed" "the tail survived, so the case tests nothing" \
  || check "a task past the cap is actually trimmed" ok
lt_marker="$(grep '^\[task trimmed by the digest' <<< "$out_lt")"
[ -n "$lt_marker" ] \
  && check "a trimmed task carries a marker saying the digest cut it" ok \
  || check "a trimmed task carries a marker saying the digest cut it" "out=${out_lt:0:300}"
contains_len="${#long_task}"
grep -q "of $contains_len characters" <<< "$lt_marker" \
  && check "and the marker names the brief's real length" ok \
  || check "and the marker names the brief's real length" "marker=$lt_marker want=$contains_len"

# A brief of an ordinary size reaches the harvest whole. Measured 2026-10-06 over 508 real subagent
# transcripts on this Mac: the median brief was 1,564 characters, so the old cap of 1500 trimmed more
# than half of them; the 75th percentile was 3,325 and the 90th 5,801.
NORMALTASK="$TMPROOT/normaltask.jsonl"
normal_task="$(python3 -c 'print("Normal brief. " + "x" * 5000 + " NORMAL-TAIL-MARKER")')"
{ asked "$normal_task"; say "Done."; } > "$NORMALTASK"
out_nt="$(python3 "$D" "$NORMALTASK" 2>/dev/null)"
grep -q 'NORMAL-TAIL-MARKER' <<< "$out_nt" \
  && check "a brief of about five thousand characters reaches the harvest whole" ok \
  || check "a brief of about five thousand characters reaches the harvest whole" "the tail was cut"
grep -q '^\[task trimmed' <<< "$out_nt" \
  && check "and carries no trim marker" "marker present on a whole brief" \
  || check "and carries no trim marker" ok

# ODD SHAPES ARE SKIPPED, NEVER FATAL (claude-config#898). An uncaught exception exits 1, which is
# the code for "the agent said nothing", so one oddly shaped line used to turn a transcript full of
# findings into a clean empty harvest. Each shape is valid JSON a reader could meet: a line that is
# not an object, a message that is not an object, content that is neither text nor a list, a tool
# input that is not an object, and text or a file path that is not a string.
ODD="$TMPROOT/odd.jsonl"
{ asked "Audit the queue"
  printf '%s\n' '[1, 2]' '{"type":"user","message":"a string message"}' \
    '{"type":"assistant","message":"a string message"}' '{"type":"assistant","message":{"content":7}}' \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":"not an object"}]}}' \
    '{"type":"assistant","message":{"content":[{"type":"text","text":7}]}}' \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":7}}]}}'
  say "ODD-SHAPES-SURVIVED: the queue has no retry cap."; } > "$ODD"
out_odd="$(python3 "$D" "$ODD" 2>&1)"; code_odd=$?
[ "$code_odd" -eq 0 ] && grep -q 'ODD-SHAPES-SURVIVED' <<< "$out_odd" \
  && check "#898 oddly shaped lines are skipped and the rest of the transcript is still digested" ok \
  || check "#898 oddly shaped lines are skipped and the rest of the transcript is still digested" "exit=$code_odd out=${out_odd:0:300}"

# A REPORT HANDED BACK THROUGH THE SubagentHandback TOOL IS WHAT THE AGENT SAID (claude-config#1232).
# An agent that ends by calling that tool writes its report as the tool's INPUT, not as assistant
# text, so a digest reading only text blocks recorded such an agent as having said nothing: status
# none, no model call, and every side finding in its report lost. The shape below is measured, not
# imagined: 286 SubagentHandback blocks across 229 real subagent transcripts on 2026-10-16, every
# one a tool_use block with exactly the keys caller, id, input, name and type, caller {"type":
# "direct"}, and an input holding one key, message, always a string. 8 of those 229 transcripts
# held no assistant text at all, so the handback was the only thing the agent ever said. The text
# here is invented; only the shape is copied.
handback() { # handback <report>  -> one assistant line handing the report back, in the measured shape
  python3 -c 'import json,sys; print(json.dumps({"type":"assistant","message":{"role":"assistant","type":"message","content":[{"type":"tool_use","id":"toolu_01FixtureHandback0000000001","name":"SubagentHandback","caller":{"type":"direct"},"input":{"message":sys.argv[1]}}]}}))' "$1"
}
handback_ack() { # the tool_result the harness answers a delivered handback with, as measured
  python3 -c 'import json; print(json.dumps({"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_01FixtureHandback0000000001","content":"{\"success\":true,\"message\":\"Report delivered to your caller.\"}"}]}}))'
}

ONLYHANDBACK="$TMPROOT/onlyhandback.jsonl"
{ asked "Fix the invoice rounding"; used Edit "/repo/invoice.ts"
  handback "HANDBACK-ONLY-MARKER: fixed the rounding; the tax helper still truncates negative totals and I left it alone."
  handback_ack; } > "$ONLYHANDBACK"
out_hb="$(python3 "$D" "$ONLYHANDBACK" 2>&1)"; code_hb=$?
[ "$code_hb" -eq 0 ] \
  && check "#1232 an agent whose only words are a handback report exits 0, not 1 (said nothing)" ok \
  || check "#1232 an agent whose only words are a handback report exits 0, not 1 (said nothing)" "exit=$code_hb out=${out_hb:0:300}"
grep -q 'HANDBACK-ONLY-MARKER' <<< "$out_hb" \
  && check "#1232 and the handed back report is printed as what the agent said" ok \
  || check "#1232 and the handed back report is printed as what the agent said" "out=${out_hb:0:300}"
grep -q 'Report delivered to your caller' <<< "$out_hb" \
  && check "#1232 while the harness acknowledgement, a tool result, stays out" "the acknowledgement came through" \
  || check "#1232 while the harness acknowledgement, a tool result, stays out" ok

# An agent that narrates AND hands back: the report is the end of what it said, which is the part
# trimming keeps, so it has to come through after the narration rather than not at all.
NARRATED="$TMPROOT/narrated.jsonl"
{ asked "Audit the export job"; say "NARRATION-MARKER: reading the export job now."
  handback "REPORT-MARKER: the export job retries forever on a 403."; handback_ack; } > "$NARRATED"
out_nar="$(python3 "$D" "$NARRATED" 2>&1)"
python3 -c 'import sys; t=sys.stdin.read(); a=t.find("NARRATION-MARKER"); b=t.find("REPORT-MARKER"); sys.exit(0 if 0 <= a < b else 1)' <<< "$out_nar" \
  && check "#1232 a report handed back after narration comes through, after it" ok \
  || check "#1232 a report handed back after narration comes through, after it" "out=${out_nar:0:300}"

# Only the hand back tool is read this way. Another tool's input carrying a message field (a commit,
# a message to a sibling) is an action, not the agent's report, and must stay out of the digest.
OTHERMSG="$TMPROOT/othermsg.jsonl"
{ asked "Commit the work"
  python3 -c 'import json; print(json.dumps({"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_01FixtureOther00000000000001","name":"SendMessage","input":{"to":"sibling","message":"OTHER-TOOL-MESSAGE-MARKER"}}]}}))'
  say "Committed."; } > "$OTHERMSG"
out_om="$(python3 "$D" "$OTHERMSG" 2>&1)"
grep -q 'OTHER-TOOL-MESSAGE-MARKER' <<< "$out_om" \
  && check "#1232 a message field on another tool's input is not read as the report" "it came through" \
  || check "#1232 a message field on another tool's input is not read as the report" ok

# A handback whose message is not a string, or is blank, is skipped like any odd shape (#898), so an
# agent whose only handback is malformed is still one that said nothing (exit 1), never a crash.
ODDHANDBACK="$TMPROOT/oddhandback.jsonl"
{ asked "Look around"
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"SubagentHandback","input":{"message":7}}]}}' \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"SubagentHandback","input":{"message":"   "}}]}}' \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"SubagentHandback","input":"not an object"}]}}'; } > "$ODDHANDBACK"
python3 "$D" "$ODDHANDBACK" >/dev/null 2>&1; code_ohb=$?
[ "$code_ohb" -eq 1 ] \
  && check "#1232 a malformed or blank handback is skipped, and the agent reads as having said nothing" ok \
  || check "#1232 a malformed or blank handback is skipped, and the agent reads as having said nothing" "exit=$code_ohb"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
