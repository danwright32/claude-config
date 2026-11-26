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
# A folder below is made unlistable on purpose; its permission is put back before removal.
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
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

# ---- What is sent, what is inferred, and which hook a number names (claude-config#3646), in a
# root of its own so the counts above stay as worked out. Every number here is set by this fixture.
#
# Interactive main (-fx-sent), requests r1 200, r2 600, r3 700 tokens: 1,500 measured. Items:
#   before r1: the typed request (17 characters), a deferred tools record with no `rendered` (never
#     sent, not counted), a skill listing whose `rendered` text is 278 characters (its JSON is far larger).
#   r1 is written on two lines: a thinking block stored empty (a signature only, output_tokens 5 on
#     that line) and a text block of 139 characters (output_tokens 150). Its thinking is inferred as
#     150 x 2.78 - 139 = 278 characters, carried by r2 and r3: 556 characters, 200 tokens.
#   before r2: r1's 139, a PostToolUse:Bash "command hook 2" of 556 rendered characters, a hook with
#     no `rendered` (not sent), and a PreToolUse:Bash refusal "command hook 3" of 278 characters.
#   r2: 16 characters of text and output_tokens 10, with no thinking block, so nothing is inferred.
#   before r3: a UserPromptSubmit hook naming its script, 139 characters.
# Carried: r1 17 + 278 = 295; r2 295 + 139 + 556 + 278 = 1,268; r3 1,268 + 16 + 139 = 1,423.
#   2,986 characters = 1,074.1 tokens, 0.72 of measured. With the inferred thinking, 1,274.1: 0.85.
# Hooks carried: command hook 2, 556 x 2 = 1,112 characters, 400 tokens (26.7%); command hook 3,
#   278 x 2 = 556, 200 tokens (13.3%); fx-named.sh 139 x 1, 50 tokens (3.3%).
# Settings: PostToolUse holds fx-post-one.sh (matcher Bash|Monitor) then fx-post-two.sh, so hook 2
#   is fx-post-two.sh. PreToolUse holds fx-pre-one.sh, then fx-pre-one.sh again (the same command,
#   counted once), fx-pre-two.sh and fx-pre-three.sh, so hook 3 is fx-pre-three.sh; counting the
#   repeat would make it fx-pre-two.sh.
S="$WORK/projects-sent"
mkdir -p "$S/-fx-sent"
python3 - "$S" "$WORK/settings.json" <<'PY'
import json, os, sys
S, SETTINGS = sys.argv[1], sys.argv[2]


def asst(mid, at, tokens, out, content):
    return json.dumps({"type": "assistant", "entrypoint": "cli", "timestamp": at,
                       "message": {"id": mid, "model": "m", "content": content,
                                   "usage": {"input_tokens": tokens, "cache_read_input_tokens": 0,
                                             "cache_creation_input_tokens": 0, "output_tokens": out}}})


def att(at, attachment, rendered=None):
    o = {"type": "attachment", "timestamp": at, "attachment": attachment}
    if rendered is not None:
        o["rendered"] = [{"content": rendered}]
    return json.dumps(o)


lines = [
    json.dumps({"type": "user", "entrypoint": "cli", "timestamp": "2026-03-03T10:00:00Z",
                "message": {"role": "user", "content": "Invented request."}}),
    att("2026-03-03T10:00:01Z", {"type": "deferred_tools_record", "tools": ["Invented " * 600]}),
    att("2026-03-03T10:00:02Z", {"type": "skill_listing", "content": "Invented " * 300}, "k" * 278),
    asst("r1", "2026-03-03T10:00:05Z", 200, 5, [{"type": "thinking", "thinking": "", "signature": "fx"}]),
    asst("r1", "2026-03-03T10:00:06Z", 200, 150, [{"type": "text", "text": "t" * 139}]),
    att("2026-03-03T10:00:07Z", {"type": "hook_success", "hookName": "PostToolUse:Bash", "hookEvent": "PostToolUse",
                                 "command": "command hook 2", "content": "h" * 556}, "h" * 556),
    att("2026-03-03T10:00:08Z", {"type": "hook_success", "hookName": "PreToolUse:Bash", "hookEvent": "PreToolUse",
                                 "command": "bash ~/.claude/hooks/fx-quiet.sh", "content": "Invented " * 50}),
    att("2026-03-03T10:00:09Z", {"type": "hook_blocking_error", "hookName": "PreToolUse:Bash", "hookEvent": "PreToolUse",
                                 "blockingError": {"command": "command hook 3", "blockingError": "Invented"}}, "b" * 278),
    asst("r2", "2026-03-03T10:01:00Z", 600, 10, [{"type": "text", "text": "Invented answer."}]),
    att("2026-03-03T10:01:01Z", {"type": "hook_success", "hookName": "UserPromptSubmit", "hookEvent": "UserPromptSubmit",
                                 "command": "bash ~/.claude/hooks/fx-named.sh --fx", "content": "n" * 139}, "n" * 139),
    asst("r3", "2026-03-03T10:02:00Z", 700, 1, [{"type": "text", "text": "More."}]),
]
with open(os.path.join(S, "-fx-sent", "main.jsonl"), "w") as fh:
    fh.write("\n".join(lines) + "\n")


def cmd(name):
    return {"type": "command", "command": "bash ~/.claude/hooks/%s" % name, "timeout": 10}


with open(SETTINGS, "w") as fh:
    json.dump({"hooks": {
        "PreToolUse": [{"matcher": "Bash", "hooks": [cmd("fx-pre-one.sh")]},
                       {"matcher": "Edit", "hooks": [cmd("fx-pre-one.sh"), cmd("fx-pre-two.sh"), cmd("fx-pre-three.sh")]}],
        "PostToolUse": [{"matcher": "Bash|Monitor", "hooks": [cmd("fx-post-one.sh")]},
                        {"matcher": "Bash", "hooks": [cmd("fx-post-two.sh")]}]}}, fh)
PY

srun(){ python3 "$TOOL" --root "$S" --since 2026-03-02 --until 2026-03-09 --tz America/New_York "$@" 2>&1; }
out="$(srun --settings "$WORK/settings.json")"; rc=$?
exit_is "a run over attachments and hooks exits 0" "$rc" 0
check "an attachment is sized by its rendered text, and one with none is not counted" \
  $'KIND\tinteractive\tfiles=1\trequests=3\ttokens=1500\tshare_of_all=100.0%\testimated_over_measured=0.72' "$out"
check "the attachments never sent are counted by type, apart from the estimate" \
  $'NOT_SENT\tinteractive\tattachments=2\t' "$out"
check "and named by type, most first" $'types=deferred_tools_record:1,hook_success:1' "$out"
check "thinking stored empty is inferred from output_tokens, on its own line, marked as inferred" \
  $'INFERRED\tinteractive\tthinking_stored_empty_from_output_tokens\treplies=1\tcarried_tokens=200\tshare_of_measured=13.3%\testimated_over_measured_with_it=0.85' "$out"
check "a hook recorded by number is named from the settings, labelled as inferred from them as they are today" \
  $'HOOK\tinteractive\tPostToolUse:Bash\tcommand hook 2\tname_inferred_from_todays_settings=fx-post-two.sh\tcarried_tokens=400\tshare_of_measured=26.7%' "$out"
check "a repeated identical command is counted once in the numbering" \
  $'HOOK\tinteractive\tPreToolUse:Bash\tcommand hook 3\tname_inferred_from_todays_settings=fx-pre-three.sh\tcarried_tokens=200\tshare_of_measured=13.3%' "$out"
check "a hook whose command was recorded is named by its script" \
  $'HOOK\tinteractive\tUserPromptSubmit\tfx-named.sh\tcarried_tokens=50\tshare_of_measured=3.3%' "$out"
check "the settings the numbers were read against are named, with the warning that numbers shift" \
  $'HOOKNUMBERS\tsettings='"$WORK/settings.json"$'\tread=yes' "$out"
absent "a hook with nothing rendered is not listed as carried" "fx-quiet.sh" "$out"
absent "no transcript text is printed" "Invented" "$out"

cp "$S/-fx-sent/main.jsonl" "$S/-fx-sent/main2.jsonl"
out="$(srun --settings "$WORK/settings.json" --jobs 2)"
check "several worker processes add the inferred thinking of two files" \
  $'INFERRED\tinteractive\tthinking_stored_empty_from_output_tokens\treplies=2\tcarried_tokens=400\t' "$out"
check "and the attachments not sent" $'NOT_SENT\tinteractive\tattachments=4\t' "$out"
check "and the hooks" $'command hook 2\tname_inferred_from_todays_settings=fx-post-two.sh\tcarried_tokens=800\t' "$out"
rm "$S/-fx-sent/main2.jsonl"

out="$(srun --settings "$WORK/no-such-settings.json")"
check "settings that cannot be read leave the number unnamed, and say so" \
  $'HOOK\tinteractive\tPostToolUse:Bash\tcommand hook 2\tname_inferred_from_todays_settings=unknown\t' "$out"
check "and the header says the settings were not read" $'HOOKNUMBERS\tsettings='"$WORK/no-such-settings.json"$'\tread=no' "$out"

# ---- The prompt snapshot, the one attachment with no `rendered` that is counted: it records the
# system prompt and tool list every request is sent (claude-config#3646). Every number is set here.
# Interactive snap (-fx-snap): snapshot A (systemPrompt and tools 2,780 JSON characters, 1,000
# tokens), requests q1 1,000 and q2 2,000 tokens, snapshot B (5,560 characters, 2,000 tokens), then
# q3 3,000 tokens: 6,000 measured. Nothing else is in the file.
#   Right, the newest snapshot once per request: 1,000 + 1,000 + 2,000 = 4,000 tokens, 0.67.
#   Adding them up: 1,000 + 1,000 + 3,000 = 5,000 (0.83). Dropping them: 0 (0.00). Never
#   replacing the first: 3,000 (0.50). Each wrong reading gives a different line.
N="$WORK/projects-snap"
mkdir -p "$N/-fx-snap"
python3 - "$N" <<'PY'
import json, os, sys
N = sys.argv[1]


def asst(mid, at, tokens):
    return json.dumps({"type": "assistant", "entrypoint": "cli", "timestamp": at,
                       "message": {"id": mid, "model": "m", "content": [],
                                   "usage": {"input_tokens": tokens, "cache_read_input_tokens": 0,
                                             "cache_creation_input_tokens": 0, "output_tokens": 0}}})


def snap(at, n):
    a = {"type": "prompt_snapshot", "systemPrompt": "p" * n, "tools": []}
    assert len(json.dumps(a["systemPrompt"])) + len(json.dumps(a["tools"])) == n + 4
    return json.dumps({"type": "attachment", "timestamp": at, "attachment": a})


lines = [snap("2026-03-03T10:00:00Z", 2776), asst("q1", "2026-03-03T10:00:01Z", 1000),
         asst("q2", "2026-03-03T10:00:02Z", 2000), snap("2026-03-03T10:00:03Z", 5556),
         asst("q3", "2026-03-03T10:00:04Z", 3000)]
with open(os.path.join(N, "-fx-snap", "snap.jsonl"), "w") as fh:
    fh.write("\n".join(lines) + "\n")
PY
out="$(python3 "$TOOL" --root "$N" --since 2026-03-02 --until 2026-03-09 --tz America/New_York --settings "$WORK/settings.json" 2>&1)"
check "the newest snapshot is carried once per request, replaced by a later one, never added up" \
  $'KIND\tinteractive\tfiles=1\trequests=3\ttokens=6000\tshare_of_all=100.0%\testimated_over_measured=0.67' "$out"
check "and stated on its own line as the one exception, with why" \
  $'SNAPSHOT\tinteractive\tsnapshots=2\tcarried_tokens=4000\tshare_of_measured=66.7%\tnote=' "$out"
absent "a snapshot is not listed as never sent" "prompt_snapshot" "$out"

# ---- Faults inside a file and inside the folder tree, in a root of their own so the counts above
# stay as worked out. Every number here is set by this fixture, not measured.
Q="$WORK/projects-faults"
mkdir -p "$Q/-fx-ids" "$Q/-fx-io" "$Q/-fx-locked/s9/subagents"
python3 - "$Q" <<'PY'
import json, os, sys
Q = sys.argv[1]


def asst(mid, tokens, content=None):
    return json.dumps({"type": "assistant", "entrypoint": "cli", "timestamp": "2026-03-04T09:00:00Z",
                       "message": {"id": mid, "model": "m", "content": content or [],
                                   "usage": {"input_tokens": tokens, "cache_read_input_tokens": 0,
                                             "cache_creation_input_tokens": 0}}})


def write(path, lines):
    with open(path, "w") as fh:
        fh.write("\n".join(lines) + "\n")


# A message id that is a list, a tool result whose tool_use_id is an object, and a line nested too
# deep to parse: three bad lines, each counted, and the 1,000 token request after them still read.
write(os.path.join(Q, "-fx-ids", "ids.jsonl"), [
    asst(["not", "an", "id"], 500),
    json.dumps({"type": "user", "timestamp": "2026-03-04T09:00:01Z", "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": {"x": 1}, "content": "invented"}]}}),
    "[" * 100000,
    asst("good1", 1000),
])
# Two requests of 300 and 400 tokens; the run below makes the read fail after the first line.
write(os.path.join(Q, "-fx-io", "flaky.jsonl"), [asst("io1", 300), asst("io2", 400)])
write(os.path.join(Q, "-fx-io", "fine.jsonl"), [asst("ok1", 2000)])
write(os.path.join(Q, "-fx-locked", "s9", "subagents", "agent-l1.jsonl"), [asst("hidden", 9000)])
PY

out="$(python3 "$TOOL" --root "$Q" --project fx-ids --since 2026-03-02 --until 2026-03-09 2>&1)"; rc=$?
exit_is "a line with a bad id or too deep to parse does not stop the run" "$rc" 0
check "each bad line is counted against its file" $'MALFORMED\t'"$Q/-fx-ids/ids.jsonl"$'\tlines=3' "$out"
check "the good request after them is still read" $'TOTAL\ttokens=1000' "$out"
absent "no traceback" "Traceback" "$out"

# A read that fails part way through a file. The failure is injected into the tool's own open() so
# it is a real OSError raised from inside the read loop, after the first line.
out="$(python3 - "$TOOL" "$Q" <<'PY' 2>&1
import errno, importlib.util, sys
spec = importlib.util.spec_from_file_location("transcript_shares", sys.argv[1])
tm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tm)


class Flaky:
    def __init__(self, fh):
        self.fh = fh

    def __enter__(self):
        return self

    def __exit__(self, *a):
        self.fh.close()

    def __iter__(self):
        yield next(iter(self.fh))
        raise OSError(errno.EIO, "Input/output error")


def fake_open(path, *a, **k):
    fh = open(path, *a, **k)
    return Flaky(fh) if path.endswith("flaky.jsonl") else fh


tm.open = fake_open
rc = tm.main(["--root", sys.argv[2], "--project", "fx-io", "--since", "2026-03-02", "--until", "2026-03-09"])
print("rc=%d" % rc)
PY
)"
check "a read failing part way names the file and says what was dropped" \
  $'UNREADABLE\t'"$Q/-fx-io/flaky.jsonl"$'\tread failed after line 1, nothing from this file counted: [Errno 5] Input/output error' "$out"
check "the other file is still measured, without the failed file's first request" $'TOTAL\ttokens=2000' "$out"
check "and the run says it is incomplete" $'END\tcomplete=no' "$out"
check "and still exits 0" "rc=0" "$out"
absent "no traceback" "Traceback" "$out"

# A folder that cannot be listed. Root can list it anyway, so that case is reported as unmeasured.
chmod 000 "$Q/-fx-locked/s9"
if ls "$Q/-fx-locked/s9" >/dev/null 2>&1; then
  # Running as a user chmod cannot lock out (root): the unlistable folder case cannot be built here.
  echo "SUITE-PART-UNMEASURED a folder with no permissions is still listable by this user, so the folder that cannot be listed was not tested"
else
  out="$(python3 "$TOOL" --root "$Q" --project fx-locked --project fx-io --since 2026-03-02 --until 2026-03-09 2>&1)"
  check "a folder that cannot be listed is named" $'UNREADABLE\t'"$Q/-fx-locked/s9"$'\t' "$out"
  check "and counted" $'unreadable=1' "$out"
  check "and the run says it is incomplete" $'END\tcomplete=no' "$out"
fi
chmod 755 "$Q/-fx-locked/s9"

# Without the zoneinfo module a valid zone must not be called bad.
out="$(python3 -c 'import runpy, sys; sys.modules["zoneinfo"] = None; sys.argv = sys.argv[1:]; runpy.run_path(sys.argv[0], run_name="__main__")' \
  "$TOOL" --root "$Q" --since 2026-03-02 --until 2026-03-09 --tz America/New_York 2>&1)"; rc=$?
check "a missing zoneinfo module is said as that" "NO ZONEINFO" "$out"
absent "not as a bad zone name" "BAD --tz" "$out"
exit_is "and exits 2" "$rc" 2

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
