#!/usr/bin/env bash
# Tests for tools/transcript-shares.py: what share of the tokens a window's requests read went to
# subagent code reading, to agent reports carried in the main session, and to very long sessions
# (claude-config#1940). Every fixture line, path and word is invented.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="${TRANSCRIPT_SHARES_TOOL:-$DIR/transcript-shares.py}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
check(){ if [[ "$3" == *"$2"* ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; echo "  expected to contain: $2"; echo "  actual: ${3:0:3000}"; fi; }
absent(){ if [[ "$3" != *"$2"* ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; echo "  expected NOT to contain: $2"; fi; }
exit_is(){ if [ "$2" -eq "$3" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1: exit $2, expected $3"; fi; }

P="$WORK/projects"
mkdir -p "$P/-fx-alpha/s1/subagents" "$P/-fx-beta"

# Every number here is set by this fixture, not measured. The window is 2 March 2026 00:00 to 9 March 2026 00:00 in America/New_York. Clocks there go
# forward on 8 March, so the start is 05:00Z (EST) and the end is 04:00Z (EDT). A request at
# 04:30Z on 9 March is half an hour OUTSIDE the window; a tool using one fixed offset of minus five
# hours would count it.
#
# Hand worked expectations, at 2.78 characters a token:
#
# Subagent a1 (-fx-alpha): requests m1 2,000, m2 3,000, m3 5,000 = 10,000 tokens (m3 is written on
#   two lines with one message id and counts once). A Read of 200 lines of 12 characters (2,599
#   characters) comes back after m1; a Bash `cd /fx && rg needle` of 3 lines of 120 characters
#   (362 characters) after m2; a Bash `ls` (not code reading) beside the Read. m2 carries the long
#   read and m3 carries both: 2,599 + 2,599 + 362 = 5,560 characters = 2,000 tokens, 20.0% of
#   10,000. Reads: 2, one over 150 lines (50.0%), carrying 2,599 of 2,961 read characters (87.8%),
#   median lines (200 + 3) / 2 = 101.5. First request 2,000. One line is broken JSON.
#
# Interactive main1 (-fx-alpha): r1 10,000, r2 20,000, r3 30,000, a compaction, r4 40,000, then r5
#   (99,999) just outside the window: 100,000 tokens, 4 requests, 1 compaction. After r1 come an
#   agent launch receipt of 278 characters (4 words), a task notification of 556 characters (21
#   words in its result) arriving twice (as a queued command and again as a user text block, read
#   once), and an agent message of 834 characters (311 words). r2 and r3 carry them; the compaction
#   clears them before r4. Launches 2 x 278 / 2.78 = 200 tokens (0.2%), notifications
#   2 x 556 / 2.78 = 400 (0.4%), messages 2 x 834 / 2.78 = 600 (0.6%), reports 1,200 (1.2%).
#
# Headless run1 (-fx-alpha): h0 77,777 one second before the window, then h1 10,000 in it. Its first
#   request is outside the window, so it has no first request median.
#
# All of -fx-alpha: 10,000 + 100,000 + 10,000 = 120,000 tokens; interactive 83.3%, the other two
#   8.3% each. old.jsonl was last written before the window and is not read. gone.jsonl is a link
#   to nothing: unreadable, and named. -fx-beta holds 55,555 tokens in the window, read only when
#   no project is named (175,555 in all).
python3 - "$P" <<'PY'
import json, os, sys
P = sys.argv[1]
alpha = os.path.join(P, "-fx-alpha")


def u(tokens):
    return {"input_tokens": 0, "cache_read_input_tokens": 0, "cache_creation_input_tokens": tokens,
            "output_tokens": 1}


def asst(mid, at, tokens, content, side=False, entry=None):
    o = {"type": "assistant", "isSidechain": side, "timestamp": at,
         "message": {"id": mid, "model": "m", "usage": u(tokens), "content": content}}
    if entry:
        o["entrypoint"] = entry
    return json.dumps(o)


def write(path, lines):
    with open(path, "w") as fh:
        fh.write("\n".join(lines) + "\n")


LONG = "\n".join(["l" * 12] * 200)
SHORT = "\n".join(["s" * 120] * 3)
assert (len(LONG), LONG.count("\n") + 1, len(SHORT)) == (2599, 200, 362)
write(os.path.join(alpha, "s1", "subagents", "agent-a1.jsonl"), [
    json.dumps({"type": "user", "isSidechain": True, "timestamp": "2026-03-04T12:00:00Z",
                "message": {"role": "user", "content": "Invented brief."}}),
    asst("m1", "2026-03-04T12:00:01Z", 2000, [
        {"type": "tool_use", "id": "t1", "name": "Read", "input": {"file_path": "/fx/long.txt"}},
        {"type": "tool_use", "id": "t3", "name": "Bash", "input": {"command": "ls /fx"}}], side=True),
    json.dumps({"type": "user", "isSidechain": True, "timestamp": "2026-03-04T12:00:02Z",
                "message": {"role": "user", "content": [
                    {"type": "tool_result", "tool_use_id": "t1", "content": LONG},
                    {"type": "tool_result", "tool_use_id": "t3", "content": "a\nb"}]}}),
    '{"type":"assistant", this line is cut off',
    asst("m2", "2026-03-04T12:00:03Z", 3000, [
        {"type": "tool_use", "id": "t2", "name": "Bash", "input": {"command": "cd /fx && rg needle"}}], side=True),
    json.dumps({"type": "user", "isSidechain": True, "timestamp": "2026-03-04T12:00:04Z",
                "message": {"role": "user", "content": [
                    {"type": "tool_result", "tool_use_id": "t2", "content": [{"type": "text", "text": SHORT}]}]}}),
    asst("m3", "2026-03-04T12:00:05Z", 5000, [{"type": "text", "text": "Invented reply."}], side=True),
    asst("m3", "2026-03-04T12:00:05Z", 5000, [{"type": "text", "text": "Second block."}], side=True),
])

FG = "Async agent launched " + "z" * 257
BG = "<task-notification><result>" + "done " * 20 + "q" * 400 + "</result></task-notification>"
AM = '<agent-message from="fx">' + "a " * 310 + "y" * 173 + "</agent-message>"
assert (len(FG), len(BG), len(AM)) == (278, 556, 834)
write(os.path.join(alpha, "main1.jsonl"), [
    json.dumps({"type": "user", "entrypoint": "cli", "isSidechain": False, "timestamp": "2026-03-03T10:00:00Z",
                "message": {"role": "user", "content": "Invented request."}}),
    asst("r1", "2026-03-03T10:00:05Z", 10000, [
        {"type": "tool_use", "id": "u1", "name": "Agent", "input": {"description": "fx", "prompt": "Invented."}}], entry="cli"),
    json.dumps({"type": "user", "timestamp": "2026-03-03T10:00:06Z",
                "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "u1", "content": FG}]}}),
    json.dumps({"type": "attachment", "timestamp": "2026-03-03T10:03:00Z",
                "attachment": {"type": "queued_command", "prompt": BG}}),
    json.dumps({"type": "user", "timestamp": "2026-03-03T10:03:01Z",
                "message": {"role": "user", "content": [{"type": "text", "text": BG}]}}),
    json.dumps({"type": "user", "timestamp": "2026-03-03T10:04:00Z", "message": {"role": "user", "content": AM}}),
    asst("r2", "2026-03-03T10:05:00Z", 20000, [{"type": "text", "text": "Invented answer."}], entry="cli"),
    asst("r3", "2026-03-03T10:06:00Z", 30000, [{"type": "text", "text": "More."}], entry="cli"),
    json.dumps({"type": "system", "subtype": "compact_boundary", "timestamp": "2026-03-03T10:07:00Z"}),
    json.dumps({"type": "user", "isCompactSummary": True, "timestamp": "2026-03-03T10:07:30Z",
                "message": {"role": "user", "content": "Invented summary."}}),
    asst("r4", "2026-03-03T10:08:00Z", 40000, [{"type": "text", "text": "After."}], entry="cli"),
    asst("r5", "2026-03-09T04:30:00Z", 99999, [{"type": "text", "text": "Too late."}], entry="cli"),
])

write(os.path.join(alpha, "run1.jsonl"), [
    asst("h0", "2026-03-02T04:59:59Z", 77777, [{"type": "text", "text": "Too early."}], entry="sdk-cli"),
    asst("h1", "2026-03-05T09:00:00Z", 10000, [{"type": "text", "text": "Headless."}], entry="sdk-cli"),
])
write(os.path.join(alpha, "old.jsonl"), [
    asst("o1", "2026-01-01T09:00:00Z", 66666, [{"type": "text", "text": "Old."}], entry="cli"),
])
write(os.path.join(P, "-fx-beta", "b1.jsonl"), [
    asst("b1", "2026-03-04T09:00:00Z", 55555, [{"type": "text", "text": "Other project."}], entry="cli"),
])
PY
touch -t 202601010000 "$P/-fx-alpha/old.jsonl"
ln -s "$WORK/nothing-here.jsonl" "$P/-fx-alpha/gone.jsonl"

run(){ python3 "$TOOL" --root "$P" --since 2026-03-02 --until 2026-03-09 --tz America/New_York "$@" 2>&1; }
out="$(run --project fx-alpha)"; rc=$?
exit_is "a run that measured something exits 0" "$rc" 0

check "the window is stated in the zone it was given in" \
  $'WINDOW\tsince=2026-03-02T00:00:00-05:00\tuntil=2026-03-09T00:00:00-04:00\ttz=America/New_York' "$out"
check "what was read is counted, so a zero can be told from an empty input" \
  $'INPUT\tprojects=1\tfiles_found=5\tfiles_older_than_window=1\tfiles_read=3\tfiles_with_requests_in_window=3\trequests_in_window=8\tunreadable=1\tmalformed_lines=1\tuntimed_requests=0' "$out"
check "an unreadable file is named" $'UNREADABLE\t'"$P/-fx-alpha/gone.jsonl" "$out"
check "a broken line is counted against the file it is in" \
  $'MALFORMED\t'"$P/-fx-alpha/s1/subagents/agent-a1.jsonl"$'\tlines=1' "$out"
check "the total excludes the requests outside the window, by their own times" $'TOTAL\ttokens=120000' "$out"
absent "a request half an hour past a daylight saving end is outside" "199999" "$out"
check "interactive sessions" \
  $'KIND\tinteractive\tfiles=1\trequests=4\ttokens=100000\tshare_of_all=83.3%' "$out"
check "the first request of an interactive session" $'first_request_median=10000' "$out"
check "a subagent, its split message counted once" \
  $'KIND\tsubagent\tfiles=1\trequests=3\ttokens=10000\tshare_of_all=8.3%' "$out"
check "a headless run whose first request is outside the window has no first request median" \
  $'KIND\theadless\tfiles=1\trequests=1\ttokens=10000\tshare_of_all=8.3%' "$out"
check "the headless first request median is not a zero" $'first_request_median=n/a' "$out"
check "subagent code reading, the Read and the rg, not the ls" \
  $'SHARE\tsubagent\tcode_reading=20.0%\tagent_reports=0.0%' "$out"
check "agent reports carried in the main session, until the compaction" \
  $'SHARE\tinteractive\tcode_reading=0.0%\tagent_reports=1.2%\ttask_notifications=0.4%\tagent_messages=0.6%\tagent_launches=0.2%' "$out"
check "long and short reads" \
  $'READS\tsubagent\tcode_reads=2\tover_150_lines=50.0%\ttheir_share_of_code_read_chars=87.8%\tmedian_lines=101.5' "$out"
check "agent message length, over the 300 word cap" \
  $'WORDS\tinteractive\tagent_messages\tcount=1\tmedian=311\tover_300=100.0%\tp90=311' "$out"
check "a notification arriving twice is read once" \
  $'WORDS\tinteractive\ttask_notifications\tcount=1\tmedian=21\tover_300=0.0%\tp90=21' "$out"
check "agent launch receipts" $'WORDS\tinteractive\tagent_launches\tcount=1\tmedian=4' "$out"
check "the longest session, its times in the zone given" \
  $'SESSION\tinteractive\ttokens=100000\tshare_of_all=83.3%\tcompactions=1\trequests=4\tfirst=2026-03-03 05:00 EST\tlast=2026-03-03 05:08 EST' "$out"
check "sessions past a number of compactions" $'COMPACTIONS\tat_least=3\tsessions=0\tshare_of_all=0.0%' "$out"
check "an input with a fault says it is incomplete" $'END\tcomplete=no' "$out"
absent "no transcript text is printed" "Invented" "$out"

out="$(run --project fx-alpha --compactions 1)"
check "the compaction thresholds are an argument" $'COMPACTIONS\tat_least=1\tsessions=1\tshare_of_all=83.3%' "$out"

# Every real project folder name starts with a dash, so a whole name is given with an equals sign.
out="$(run --project=-fx-beta)"; rc=$?
exit_is "a project name starting with a dash is read" "$rc" 0
check "and matches only that project" $'TOTAL\ttokens=55555' "$out"

out="$(run)"
check "with no project named, every project folder is read" $'TOTAL\ttokens=175555' "$out"
check "and counted" $'INPUT\tprojects=2\t' "$out"

out="$(python3 "$TOOL" --root "$P" --project fx-beta --since 2026-03-02 --until 2026-03-09 --tz America/New_York 2>&1)"; rc=$?
check "a clean input says it is complete" $'END\tcomplete=yes' "$out"

out="$(run --project fx-nothing)"; rc=$?
check "no project folder matching is refused, not reported as zero" "NO TRANSCRIPTS" "$out"
exit_is "and exits 1" "$rc" 1

out="$(python3 "$TOOL" --root "$P" --project fx-alpha --since 2025-06-01 --until 2025-06-08 --tz America/New_York 2>&1)"; rc=$?
check "a window holding no requests is refused, not reported as zero" "NO REQUESTS IN WINDOW" "$out"
check "and still says what it read" $'requests_in_window=0' "$out"
exit_is "and exits 1" "$rc" 1

out="$(python3 "$TOOL" --root "$WORK/none" --since 2026-03-02 --until 2026-03-09 2>&1)"; rc=$?
check "a missing transcripts root is refused" "NO TRANSCRIPTS ROOT" "$out"
exit_is "and exits 1" "$rc" 1

out="$(run --project fx-alpha --tz Not/AZone)"; rc=$?
check "an unknown time zone is refused" "BAD --tz" "$out"
exit_is "and exits 2" "$rc" 2

out="$(run --project fx-alpha --jobs 2)"
check "several worker processes give the same answer" \
  $'SHARE\tinteractive\tcode_reading=0.0%\tagent_reports=1.2%' "$out"
check "and the same input counts" $'files_read=3\tfiles_with_requests_in_window=3\trequests_in_window=8' "$out"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
