#!/usr/bin/env bash
#
# test-lessons-merge-gate.sh: the merge gate that holds a pull request changing lesson entries in
# payload/LESSONS.md until Dan has answered the lesson picker's merge form for exactly that change
# (claude-config#3343, route 3).
#
# Every case runs the REAL hook, through the real lib/lesson-merge.py, the real transcript reader
# (lib/db-apply-approval.py) and the real picker check (lib/picker-check.mjs), with a fake `gh`
# first on PATH that answers from files this suite writes. Nothing here reaches GitHub, merges
# anything, reads the real lessons file or writes under ~/.claude: the record of answers is a
# folder of the run's own.
#
# The picker a case answers is built from the refusal the gate itself printed, as a session would
# build it, so the suite holds the refusal's words to what the gate then accepts.
#
# The merge command is assembled from $MERGE rather than written out, because writing it literally
# makes this file trip the merge gates on the way in.

set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HOOK_DIR/lessons-merge-gate.sh"
# LESSONS_GATE_UNDER_TEST names another copy of the gate beside the real one, for proving a case by
# removal: a copy with one check taken out must fail the case that holds that check (L1).
[ -z "${LESSONS_GATE_UNDER_TEST:-}" ] || HOOK="$HOOK_DIR/${LESSONS_GATE_UNDER_TEST##*/}"
MERGE="gh pr me""rge"
HELPER_NAME="me""rge-when-ready.sh"
passed=0
failed=0
fail() { echo "  FAIL: $1"; failed=$((failed + 1)); }
pass() { passed=$((passed + 1)); }

# Named with no "merge" in it: the gate's first filter is that word anywhere in the payload.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lessons-gate-test.XXXXXXXX")" || WORK=""
case "${WORK%/}" in
  ''|/|"${HOME%/}") echo "$(basename "$0"): refusing to run: throwaway directory came back as '$WORK'." >&2; exit 2 ;;
esac
trap 'rm -rf "$WORK"' EXIT
export HOOK_TESTS_RUNNING=1

mkdir -p "$WORK/repo" "$WORK/bin" "$WORK/gh"
( cd "$WORK/repo" && git init -q && git remote add origin "https://github.com/acme/widget.git" )
BASE_SHA="b000000000000000000000000000000000000000"
HEAD_SHA="a111111111111111111111111111111111111111"
MB_SHA="c222222222222222222222222222222222222222"

# The fake gh. A file's content at a commit is $FAKE_DIR/blob-<sha>; with no such file the answer is
# gh's own 404, and $FAKE_DIR/err-<sha> holds an error to fail with instead.
cat > "$WORK/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
case "$*" in
  *"auth status"*) printf 'Logged in to github.com account danwright32 (keyring)\n' ;;
  *"auth token -u "*) printf 'tok\n' ;;
  *"pr view"*)
    if [ -n "${FAKE_PR_ERR:-}" ]; then printf '%s\n' "$FAKE_PR_ERR" >&2; exit 1; fi
    cat "$FAKE_DIR/pr.json" ;;
  api*"/compare/"*)
    if [ -f "$FAKE_DIR/err-compare" ]; then cat "$FAKE_DIR/err-compare" >&2; exit 1; fi
    cat "$FAKE_DIR/mergebase" ;;
  api*"/contents/payload/LESSONS.md?ref="*)
    ref="$*"; ref="${ref##*ref=}"
    if [ -f "$FAKE_DIR/err-$ref" ]; then cat "$FAKE_DIR/err-$ref" >&2; exit 1; fi
    if [ -f "$FAKE_DIR/blob-$ref" ]; then cat "$FAKE_DIR/blob-$ref"; else printf 'gh: Not Found (HTTP 404)\n' >&2; exit 1; fi ;;
  *) printf 'fake gh: unexpected call: %s\n' "$*" >&2; exit 1 ;;
esac
SH
chmod +x "$WORK/bin/gh"

# A lessons file shaped like the real one: text above the first heading, two sections, forty
# entries, each with a rule in bold, a line of evidence, its provenance and a SHORT line. The
# operations after the file name change it as a pull request would.
lessons() {  # lessons <out file> [op ...]
  python3 - "$@" <<'PY'
import sys
out, ops = sys.argv[1], sys.argv[2:]
def entry(n, rule=None, short=None):
    rule = rule or "Rule %d says a guard must be seen to fail before anybody trusts what it reports." % n
    return ["- **L%d. %s**" % (n, rule), "  It was found on a day somebody trusted a green run.",
            "  (acme#%d, 2026-01-02)" % n, "  SHORT: %s" % (short or "Rule %d in one line for the index." % n)]
pre = ["# Lessons", "", "Text above the first section, which reaches no index.", ""]
sections = [["## Proof over green", [entry(n) for n in range(1, 21)]], ["## Honest failure", [entry(n) for n in range(21, 41)]]]
blank = 1
def find(n):
    for s in sections:
        for i, e in enumerate(s[1]):
            if e[0].startswith("- **L%d." % n):
                return s, i
    raise SystemExit("no L%d" % n)
for op in ops:
    kind, _, arg = op.partition(":")
    if kind == "add":
        sections[1][1].append(entry(int(arg)))
    elif kind == "addlink":
        sections[1][1].append(entry(int(arg), rule="Rule with a [link](x) in it that a picker would draw as less than its text."))
    elif kind == "change":
        s, i = find(int(arg)); s[1][i][0] = s[1][i][0].replace("must be seen", "has to be seen")
    elif kind == "changeall":
        for n in range(1, int(arg) + 1):
            s, i = find(n); s[1][i][1] = "  It was found on a day somebody trusted a green run, twice."
    elif kind == "remove":
        s, i = find(int(arg)); del s[1][i]
    elif kind == "move":
        s, i = find(int(arg)); e = s[1].pop(i); sections[1][1].append(e)
    elif kind == "rewrap":
        s, i = find(int(arg)); first = s[1][i][0]; cut = first.index(" before ")
        s[1][i][0:1] = [first[:cut], " " + first[cut:]]
    elif kind == "preamble":
        pre[2] = "Text above the first section, reworded."
    elif kind == "blank":
        blank = 2
    elif kind == "reorder":
        s = sections[0][1]; s[0], s[1] = s[1], s[0]
    elif kind == "swapsections":
        sections.reverse()
    else:
        raise SystemExit("unknown op " + op)
lines = list(pre)
for title, es in sections:
    lines += [title, ""]
    for e in es:
        lines += e + [""] * blank
open(out, "w").write("\n".join(lines) + "\n")
PY
}

# pr_json <number> <changedFiles> <path:changeType ...>
pr_json() {
  python3 - "$BASE_SHA" "$HEAD_SHA" "$@" > "$WORK/gh/pr.json" <<'PY'
import json, sys
base, head, number, changed = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
files = [{"path": p.rpartition(":")[0], "changeType": p.rpartition(":")[2], "additions": 1, "deletions": 0} for p in sys.argv[5:]]
print(json.dumps({"number": number, "url": "https://github.com/acme/widget/pull/%d" % number,
                  "baseRefOid": base, "headRefOid": head, "changedFiles": changed, "files": files}))
PY
}

# pull <op ...>: pull request seven, whose head holds the base's lessons file with the operations.
pull() {
  rm -f "$WORK/gh"/blob-* "$WORK/gh"/err-*
  printf '%s\n' "$MB_SHA" > "$WORK/gh/mergebase"
  lessons "$WORK/gh/blob-$MB_SHA"
  lessons "$WORK/gh/blob-$HEAD_SHA" "$@"
  pr_json 7 2 "payload/LESSONS.md:MODIFIED" "README.md:MODIFIED"
}

RECORD="$WORK/record"
TRANSCRIPT="$WORK/transcript.jsonl"
# run_hook <command> [VAR=value ...] ; a main session's call. Sets hook_out, hook_rc and reason.
PAYLOAD_EXTRA='"session_id":"sess-1","transcript_path":"'"$TRANSCRIPT"'"'
run_hook() {
  local cmd="$1"; shift
  : > "$WORK/gh.log"
  hook_out="$(printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":%s},"cwd":%s,%s}' \
      "$(printf '%s' "$cmd" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
      "$(printf '%s' "$WORK/repo" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
      "$PAYLOAD_EXTRA" \
    | ( cd "$WORK/repo" && env PATH="$WORK/bin:$PATH" FAKE_DIR="$WORK/gh" FAKE_GH_LOG="$WORK/gh.log" \
          LM_MERGE_RECORD_DIR="$RECORD" LM_MERGE_SLEEP=true CLAUDE_SLEEP_RECORD="$WORK/no-sleep-record" "$@" bash "$HOOK" 2>&1 ))"
  hook_rc=$?
  reason="$(printf '%s' "$hook_out" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)"
}
denied() { local re='"permissionDecision": *"deny"'; [[ "$hook_out" =~ $re ]]; }
says() { [[ "$hook_out" == *"$1"* || "$reason" == *"$1"* ]]; }
expect_deny() {  # $1 = description, $2 = a needle the refusal must carry
  if denied && says "$2"; then pass; else fail "$1: wanted a refusal carrying [$2], got (exit $hook_rc): ${hook_out:0:900}"; fi
}
expect_allow() {  # $1 = description
  if [ "$hook_rc" -eq 0 ] && ! denied && [ -z "$hook_out" ]; then pass; else fail "$1: wanted a silent allow, got (exit $hook_rc): ${hook_out:0:900}"; fi
}
calls() { grep -c -E '^(pr view|api) ' "$WORK/gh.log" 2>/dev/null || true; }
expect_calls() {  # $1 = description, $2 = how many reads of GitHub
  if [ "$(calls)" = "$2" ]; then pass; else fail "$1: wanted $2 reads of GitHub, got $(calls): $(tr '\n' '|' < "$WORK/gh.log")"; fi
}

# answer <the refusal's reason> [extra question line] [answer] [filled] [a third option]: appends to
# the transcript the picker the refusal names, built from its own words, answered as given
# (default: the merge answer), as Claude Code records it. `filled` sends the answer already filled
# in; a third option is one the merge form does not have.
answer() {
  python3 - "$TRANSCRIPT" "$1" "${2:-}" "${3:-Merge these lessons}" "${4:-}" "${5:-}" <<'PY'
import json, re, sys, time
path, reason, extra, chosen, filled, third = sys.argv[1:7]
meta = json.loads(re.search(r'metadata (\{.*?\})\.', reason).group(1))
block = reason.split("on a line of its own:\n\n", 1)[1].split("\n\n", 1)[0]
question = block + ("\n" + extra if extra else "") + "\nMay it merge?"
ask = {"questions": [{"question": question, "header": "Lessons", "multiSelect": False,
                      "options": [{"label": "Merge these lessons", "description": "The pull request may merge."},
                                  {"label": "Do not merge", "description": "The pull request stays open."}]}],
       "metadata": meta}
if filled:
    ask["answers"] = {question: chosen}
if third:
    ask["questions"][0]["options"].append({"label": third, "description": "Another answer."})
uid = "toolu_%d" % time.time_ns()
with open(path, "a") as f:
    f.write(json.dumps({"type": "assistant", "sessionId": "sess-1", "message": {"role": "assistant", "content": [
        {"type": "tool_use", "id": uid, "name": "AskUserQuestion", "input": ask}]}}) + "\n")
    f.write(json.dumps({"type": "user", "sessionId": "sess-1", "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": uid, "content": "answered"}]},
        "toolUseResult": {"questions": ask["questions"], "answers": {question: chosen}}}) + "\n")
PY
}
fresh() { rm -rf "$RECORD"; : > "$TRANSCRIPT"; }
# said <name>: with LESSONS_GATE_TEST_KEEP naming a folder, the refusal just given is written there
# under that name, so its words can be read cold, as a session gets them (L21).
said() { [ -z "${LESSONS_GATE_TEST_KEEP:-}" ] || printf '%s\n' "$reason" > "$LESSONS_GATE_TEST_KEEP/$1.txt"; }

echo "lessons merge gate: a pull request that changes lesson entries waits for Dan's answer"

[ -f "$HOOK" ] || fail "$HOOK is missing"

# --- one entry added -----------------------------------------------------------------------------
fresh; pull add:900
run_hook "$MERGE 7 --squash"
expect_deny "one entry added and no answer: the merge is refused" "Dan has not answered the lesson picker"
expect_deny "the refusal states the count and the number" "Pull request #7 in acme/widget changes payload/LESSONS.md: 1 entry added (L900)."
expect_deny "the refusal gives the rule to show him, after its number" "L900: Rule 900 says a guard must be seen to fail before anybody trusts what it reports."
expect_deny "the refusal gives the SHORT line to show him" "SHORT: Rule 900 in one line for the index."
expect_deny "the refusal names the picker's source and the change's sha256" '"source": "lesson-merge", "repo": "acme/widget", "pr": 7, "sha256": "'
expect_calls "a pull request that touches the file costs the view, the merge base and the file twice" 4
one_added="$reason"; said one-entry-added

answer "$one_added"
run_hook "$MERGE 7 --squash"
expect_allow "with Dan's answer for exactly this change the merge goes through"
if [ "$(wc -l < "$RECORD/answers.jsonl" 2>/dev/null | tr -d ' ')" = 1 ]; then pass; else fail "his answer is kept on the record, one line: $(cat "$RECORD/answers.jsonl" 2>&1)"; fi

# The helper asks with no transcript: the record alone answers it.
PAYLOAD_EXTRA='"session_id":"me''rge-when-ready"' run_hook "$MERGE 7 --repo acme/widget --squash --match-head-commit $HEAD_SHA"
expect_allow "the merge helper's ask, which carries no transcript, is answered from the record"
rm -rf "$RECORD"
PAYLOAD_EXTRA='"session_id":"me''rge-when-ready"' run_hook "$MERGE 7 --repo acme/widget --squash --match-head-commit $HEAD_SHA"
expect_deny "with no record and no transcript the helper's ask is refused" "Dan has not answered the lesson picker"

# Starting the helper keeps his answer on the record, and decides nothing.
run_hook "bash ~/.claude/hooks/lib/$HELPER_NAME 7 --repo acme/widget --squash"
expect_allow "starting the merge helper is not refused"
expect_calls "and reads nothing from GitHub" 0
if [ "$(wc -l < "$RECORD/answers.jsonl" 2>/dev/null | tr -d ' ')" = 1 ]; then pass; else fail "starting the helper keeps his answer on the record: $(ls "$RECORD" 2>&1)"; fi

# A pin that is not the head GitHub shows.
run_hook "$MERGE 7 --squash --match-head-commit dddddddddddddddddddddddddddddddddddddddd"
expect_deny "a merge pinned to another commit than the head judged is refused" "pinned to"

# --- an answer for another change does not count ---------------------------------------------------
fresh; pull add:900
run_hook "$MERGE 7 --squash"; answer "$reason"
pull add:900 change:5
run_hook "$MERGE 7 --squash"
expect_deny "an answer for one change does not cover the same pull request once it changes another entry" "Dan has not answered the lesson picker"
expect_deny "and the refusal counts both" "1 entry added (L900), 1 entry changed (L5)."
fresh; pull add:900
run_hook "$MERGE 7 --squash"; answer "$reason"
pr_json 8 2 "payload/LESSONS.md:MODIFIED" "README.md:MODIFIED"
run_hook "$MERGE 8 --squash"
expect_deny "an answer for pull request 7 does not cover pull request 8 carrying the same entries" "Refusing to merge PR #8"

# --- answers that are not his, or not for what he read ---------------------------------------------
fresh; pull add:900
run_hook "$MERGE 7 --squash"; answer "$reason" "" "Do not merge"
run_hook "$MERGE 7 --squash"
expect_deny "Do not merge is no approval" "Dan has not answered the lesson picker"
fresh; run_hook "$MERGE 7 --squash"; answer "$reason" "" "Merge these lessons" filled
run_hook "$MERGE 7 --squash"
expect_deny "a picker sent with its answer filled in is no approval" "Dan has not answered the lesson picker"
fresh; run_hook "$MERGE 7 --squash"; answer "$reason" "" "Merge these lessons" "" "Decide later"
run_hook "$MERGE 7 --squash"
expect_deny "a picker offering an answer the merge form does not have is no approval" "Dan has not answered the lesson picker"
fresh; run_hook "$MERGE 7 --squash"
answer "${reason/SHORT: Rule 900 in one line for the index./SHORT: Something else entirely.}"
run_hook "$MERGE 7 --squash"
expect_deny "an answer to a question that showed another SHORT line covers nothing" "the question he read did not hold"
expect_deny "and the refusal names the line it lacked" 'the line "SHORT: Rule 900 in one line for the index."'
fresh; run_hook "$MERGE 7 --squash"; answer "$reason"
PAYLOAD_EXTRA="$PAYLOAD_EXTRA"',"agent_id":"a1b2c3d4"' run_hook "$MERGE 7 --squash"
expect_allow "a subagent's merge passes on the answer Dan gave the main session"
if [ ! -e "$RECORD/answers.jsonl" ]; then pass; else fail "a subagent's call writes nothing on the record"; fi

# --- a sweep: thirty entries, one question -----------------------------------------------------------
fresh; pull changeall:30
run_hook "$MERGE 7 --squash"
expect_deny "thirty entries changed: refused, naming the count" "30 entries changed (between L1 and L30)."
expect_deny "a sweep is asked for the change in the session's words" 'a line starting "The change: "'
if [ "$(printf '%s' "$reason" | grep -c 'AskUserQuestion')" = 1 ] && [ "$(printf '%s' "$reason" | grep -c '^Pull request #7')" = 1 ]; then pass; else fail "a sweep names ONE picker with one facts line: $reason"; fi
nl=$'\n'
case "$nl$reason" in *"${nl}L1: "*) fail "a sweep does not list every rule: $reason" ;; *) pass ;; esac
sweep="$reason"; said sweep-of-thirty
answer "$sweep"
run_hook "$MERGE 7 --squash"
expect_deny "a sweep's answer without a line saying the change covers nothing" 'a line starting "The change: "'
said answered-without-the-change
answer "$sweep" "The change: adds the word twice to the evidence line of thirty entries."
run_hook "$MERGE 7 --squash"
expect_allow "a sweep answered once, with the count and the change, merges"

# --- removals and moves are entries too ----------------------------------------------------------------
fresh; pull remove:12 move:3
run_hook "$MERGE 7 --squash"
expect_deny "an entry removed and one moved are asked about, by number" "1 entry removed (L12), 1 entry moved to another section (L3)."
answer "$reason"; run_hook "$MERGE 7 --squash"
expect_allow "and his answer naming them covers the merge"

# --- what is no entry's change ---------------------------------------------------------------------------
fresh; pull preamble blank reorder swapsections
run_hook "$MERGE 7 --squash"
expect_allow "text above the first section, blank lines and the order of entries and sections change no entry"
expect_calls "which is known only by reading the file at both commits" 4
fresh; pull rewrap:4
run_hook "$MERGE 7 --squash"
expect_deny "a rule wrapped onto other lines is a changed entry" "1 entry changed (L4)."

# --- a pull request that does not touch the file ------------------------------------------------------------
fresh; pull add:900
pr_json 7 2 "README.md:MODIFIED" "payload/hooks/x.sh:ADDED"
run_hook "$MERGE 7 --squash"
expect_allow "a pull request that does not touch payload/LESSONS.md is never asked"
expect_calls "and costs one read of GitHub, the pull request itself" 1
run_hook "git status"
expect_allow "a command that merges nothing is let through"
expect_calls "and reads nothing" 0

# --- the sync's own send is a push, never a pull request ------------------------------------------------------
run_hook "git -C $WORK/repo commit -q -m 'sync from host' && git -C $WORK/repo push -q origin main"
expect_allow "the sync's send, a push to the branch, is not asked"
expect_calls "and reads nothing from GitHub" 0

# --- a file list that cannot say: the file itself is read -------------------------------------------------------
fresh; pull add:900
pr_json 7 150 "README.md:MODIFIED"
run_hook "$MERGE 7 --squash"
expect_deny "a file list cut short does not hide a changed lessons file" "1 entry added (L900)."
pr_json 7 2 "payload/OLD.md:RENAMED" "README.md:MODIFIED"
run_hook "$MERGE 7 --squash"
expect_deny "a renamed file in the list has the lessons file read" "1 entry added (L900)."
rm -f "$WORK/gh/blob-$HEAD_SHA"
run_hook "$MERGE 7 --squash"
expect_deny "a lessons file gone at the head is every entry removed" "40 entries removed (between L1 and L40)."
pull; pr_json 7 150 "README.md:MODIFIED"
run_hook "$MERGE 7 --squash"
expect_allow "a file list cut short over an unchanged lessons file is let through"

# --- an entry that cannot be shown to him ---------------------------------------------------------------------------
fresh; pull addlink:901
run_hook "$MERGE 7 --squash"
expect_deny "an entry whose rule a picker would not show as written names no picker" "would not reach Dan as written"
if says "AskUserQuestion"; then fail "and no picker is named for it: $reason"; else pass; fi
said cannot-be-shown

# --- asleep ---------------------------------------------------------------------------------------------------------
fresh; pull add:900
boot="$(sysctl -n kern.boottime 2>/dev/null | sed -n -E 's/^\{ sec = ([0-9]+).*/\1/p')"
printf '{"v":1,"until":%s000,"bootTime":%s}\n' "$(( $(date +%s) + 3600 ))" "${boot:-0}" > "$WORK/asleep.json"
run_hook "$MERGE 7 --squash" CLAUDE_SLEEP_RECORD="$WORK/asleep.json"
expect_deny "asleep, the merge waits and the refusal says so" "Dan is asleep (sleep mode), so he is not asked tonight: this merge waits for him."
if says "AskUserQuestion"; then fail "asleep, no picker is named: $reason"; else pass; fi
said asleep
run_hook "$MERGE 7 --squash"; answer "$reason"
run_hook "$MERGE 7 --squash" CLAUDE_SLEEP_RECORD="$WORK/asleep.json"
expect_allow "an answer he gave before the night still covers the merge while he sleeps"

# --- it refuses whenever it cannot tell (fail closed) -----------------------------------------------------------------
fresh; pull add:900
run_hook "$MERGE 7 --squash" FAKE_PR_ERR="error connecting to api.github.com"
expect_deny "GitHub unreachable for the pull request: refused, never passed" "Cannot tell whether this merge changes a lesson entry"
printf 'gh: Bad Gateway (HTTP 502)\n' > "$WORK/gh/err-$HEAD_SHA"
run_hook "$MERGE 7 --squash"
expect_deny "the lessons file unreadable at the head: refused with what GitHub said" "HTTP 502"
rm -f "$WORK/gh/err-$HEAD_SHA"
printf 'gh: Server Error (HTTP 500)\n' > "$WORK/gh/err-compare"
run_hook "$MERGE 7 --squash"
expect_deny "the merge base unreadable: refused with what GitHub said" "HTTP 500"
rm -f "$WORK/gh/err-compare"
printf 'not-a-commit\n' > "$WORK/gh/mergebase"
run_hook "$MERGE 7 --squash"
expect_deny "a merge base that is no commit: refused" "named no merge base"
printf '%s\n' "$MB_SHA" > "$WORK/gh/mergebase"
run_hook "$MERGE 7 --squash" LM_MERGE_MAX_BYTES=1000
expect_deny "a lessons file larger than the gate reads: refused, saying its size" "more than the 1000 bytes this gate reads"
printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/broken-rule.py"
run_hook "$MERGE 7 --squash" LM_MERGE_RULE="$WORK/broken-rule.py"
expect_deny "the rule giving no verdict: refused, never passed" "gave no verdict"
printf '{"number":7,"url":"https://github.com/acme/widget/pull/7"}\n' > "$WORK/gh/pr.json"
run_hook "$MERGE 7 --squash"
expect_deny "an answer about the pull request naming no commits: refused" "named no number, base commit, head commit or repository"
pull add:900
# Outside a test run no setting names the rule, the record or the size: the gate's own are used.
: > "$WORK/gh.log"
run_hook "$MERGE 7 --squash" HOOK_TESTS_RUNNING= LM_MERGE_RULE="$WORK/broken-rule.py" LM_MERGE_MAX_BYTES=1000 HOME="$WORK/home"
expect_deny "outside a test run a rule named in the environment is not run" "Dan has not answered the lesson picker"

# The record is the gate's to write.
run_hook "echo '{}' >> ~/.claude/state/lesson-me""rges/answers.jsonl"
expect_deny "a shell command naming the record of his answers is refused" "is written only by lessons-me""rge-gate.sh"

# Neither reader installed: refused rather than passed.
NOREADER="$WORK/noreader"; mkdir -p "$NOREADER"
for t in bash cat sed grep awk git dirname basename mktemp rm tr cut head tail wc env printf date sysctl cmp; do
  p="$(command -v "$t" 2>/dev/null)" && [ -x "$p" ] && ln -sf "$p" "$NOREADER/$t"
done
run_hook "$MERGE 7 --squash" PATH="$NOREADER"
if [ "$hook_rc" -eq 2 ] && says "jq or python3"; then pass; else fail "with neither jq nor python3 a merge is refused naming them, got (exit $hook_rc): ${hook_out:0:400}"; fi

echo
echo "passed: $passed   failed: $failed"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
