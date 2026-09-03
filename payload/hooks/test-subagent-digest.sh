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

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
