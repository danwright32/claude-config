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
  api*"/git/trees/"*)
    # Every file at a commit, from $FAKE_DIR/tree-<sha> (with none, a tree holding no file), put
    # through the --jq filter the caller sent, as gh does.
    ref="$*"; ref="${ref##*/git/trees/}"; ref="${ref%%\?*}"
    if [ -f "$FAKE_DIR/err-tree-$ref" ]; then cat "$FAKE_DIR/err-tree-$ref" >&2; exit 1; fi
    filter="."; prev=""
    for a in "$@"; do [ "$prev" = "--jq" ] && filter="$a"; prev="$a"; done
    if [ -f "$FAKE_DIR/tree-$ref" ]; then jq -r "$filter" "$FAKE_DIR/tree-$ref"; else printf '{"tree":[],"truncated":false}\n' | jq -r "$filter"; fi ;;
  api*graphql*)
    if [ -f "$FAKE_DIR/node.json" ]; then cat "$FAKE_DIR/node.json"; else printf 'gh: Could not resolve to a node (HTTP 200)\n' >&2; exit 1; fi ;;
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
    elif kind == "short":
        s, i = find(int(arg)); s[1][i][3] = "  SHORT: Rule %d in one line, reworded for the index." % int(arg)
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

# A merge pinned to a whole commit is judged at that commit, which is what GitHub would merge,
# whatever head GitHub's view shows (it can show the last one late, and the helper pins the head it
# read itself). Its file list is the head's, so it cannot say the pinned commit leaves the file alone.
PIN_SHA="dddddddddddddddddddddddddddddddddddddddd"
lessons "$WORK/gh/blob-$PIN_SHA" add:900 add:901
run_hook "$MERGE 7 --squash --match-head-commit $PIN_SHA"
expect_deny "a merge pinned to another commit than the head is judged at the pinned commit" "2 entries added (L900, L901)."
pr_json 7 2 "README.md:MODIFIED" "docs/x.md:MODIFIED"
run_hook "$MERGE 7 --squash --match-head-commit $PIN_SHA"
expect_deny "the head's file list leaving the file alone does not clear a pinned commit that changes it" "2 entries added (L900, L901)."
lessons "$WORK/gh/blob-$PIN_SHA" add:900
run_hook "$MERGE 7 --squash --match-head-commit $PIN_SHA"
expect_allow "a pinned commit whose change he answered for merges"
pull add:900
run_hook "$MERGE 7 --squash --match-head-commit ddddddd"
expect_deny "a shortened pin that is not the start of the head is refused" "pinned to ddddddd"
run_hook "$MERGE 7 --squash --match-head-commit a111111"
expect_allow "a shortened pin that starts the head is judged at the head"

# The file list names the lessons file, yet GitHub has it at neither commit: refused, never untouched.
rm -f "$WORK/gh/blob-$MB_SHA" "$WORK/gh/blob-$HEAD_SHA"
run_hook "$MERGE 7 --squash"
expect_deny "a lessons file the list names but GitHub has at neither commit is refused" "names payload/LESSONS.md as changed"

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

# Reading the transcript loads the approval reader by path. With bytecode on that leaves a
# __pycache__ in the lib folder, which the sync carries (#2600). Run a copy of the two files with
# bytecode left on and look for one.
LIBCOPY="$WORK/libcopy"; mkdir -p "$LIBCOPY" "$WORK/bytecode-record"
python3 "$HOOK_DIR/lib/install-hook-libs.py" "$HOOK_DIR/lib" "$LIBCOPY" lesson-merge.py db-apply-approval.py >/dev/null \
  || fail "lib/install-hook-libs.py could not install the lessons rule and the approval reader"
rm -rf "$LIBCOPY/__pycache__"   # whatever the install left, so the run below is what is judged
printf '{}\n' > "$WORK/bytecode-transcript.jsonl"
env -u PYTHONDONTWRITEBYTECODE python3 "$LIBCOPY/lesson-merge.py" harvest --record-dir "$WORK/bytecode-record" \
  --transcript "$WORK/bytecode-transcript.jsonl" --session s >/dev/null 2>&1
if [ -e "$LIBCOPY/__pycache__" ]; then fail "reading a transcript leaves a __pycache__ beside the lib files (#2600)"; else pass; fi

# ======================================================================================================================
# The ways round (claude-config#3583). Everything above is #3343's and is left as it was.
# ======================================================================================================================
json() { printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'; }
# run_tool <tool> <its input, as JSON> [VAR=value ...]: a call of a tool that writes a file.
run_tool() {
  local tool="$1" input="$2"; shift 2
  : > "$WORK/gh.log"
  hook_out="$(printf '{"hook_event_name":"PreToolUse","tool_name":"%s","tool_input":%s,"cwd":%s,%s}' \
      "$tool" "$input" "$(json "$WORK/repo")" "$PAYLOAD_EXTRA" \
    | ( cd "$WORK/repo" && env PATH="$WORK/bin:$PATH" FAKE_DIR="$WORK/gh" FAKE_GH_LOG="$WORK/gh.log" \
          LM_MERGE_RECORD_DIR="$RECORD" LM_MERGE_SLEEP=true CLAUDE_SLEEP_RECORD="$WORK/no-sleep-record" "$@" bash "$HOOK" 2>&1 ))"
  hook_rc=$?
  reason="$(printf '%s' "$hook_out" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)"
}
write_to() { run_tool Write "{\"file_path\":$(json "$1"),\"content\":\"{}\"}" "${@:2}"; }
# The helper's ask: no transcript, the pull request pinned to its head.
helper_ask() { PAYLOAD_EXTRA='"session_id":"me''rge-when-ready"' run_hook "$MERGE 7 --repo acme/widget --squash --match-head-commit $HEAD_SHA"; }
# hand_line <a refusal's reason> [transcript] [session] [pull request]: the line a hand would put on
# the record for the change the refusal names: its repository, number and sha256, and a question
# holding every line the gate asks for.
hand_line() {
  python3 - "$1" "${2:-}" "${3:-}" "${4:-}" <<'PY'
import json, re, sys, time
reason, transcript, session, pr = sys.argv[1:5]
meta = json.loads(re.search(r'metadata (\{.*?\})\.', reason).group(1))
block = reason.split("on a line of its own:\n\n", 1)[1].split("\n\n", 1)[0]
line = {"repo": meta["repo"], "pr": int(pr) if pr else meta["pr"], "sha256": meta["sha256"],
        "question": block + "\nMay it merge?", "at": int(time.time())}
if transcript:
    line["transcript"] = transcript
if session:
    line["session"] = session
print(json.dumps(line))
PY
}
RECORD_NAME_WORDS="lesson-me""rges"

# --- item 1: the record is the gate's to write, whatever tool names it ---------------------------------------------
fresh; pull add:900
mkdir -p "$RECORD"
write_to "$RECORD/answers.jsonl"
expect_deny "#3583 a Write to the record of his answers is refused" "the record of Dan's answers about lesson entries"
expect_deny "#3583 and the refusal says why" "an approval he never gave"
said write-to-the-record
run_tool Edit "{\"file_path\":$(json "$RECORD/answers.jsonl"),\"old_string\":\"a\",\"new_string\":\"b\"}"
expect_deny "#3583 an Edit of the record is refused" "the record of Dan's answers about lesson entries"
run_tool MultiEdit "{\"file_path\":$(json "$RECORD/answers.jsonl"),\"edits\":[{\"old_string\":\"a\",\"new_string\":\"b\"}]}"
expect_deny "#3583 a MultiEdit of the record is refused" "the record of Dan's answers about lesson entries"
run_tool NotebookEdit "{\"notebook_path\":$(json "$RECORD/answers.jsonl"),\"new_source\":\"x\"}"
expect_deny "#3583 a NotebookEdit naming the record is refused" "the record of Dan's answers about lesson entries"
write_to "$RECORD/another-file"
expect_deny "#3583 any file in the record's folder is the record" "the record of Dan's answers about lesson entries"
write_to "$(printf '%s' "$RECORD" | tr 'a-z' 'A-Z')/ANSWERS.JSONL"
expect_deny "#3583 the record spelled in another case is the same file on a Mac" "the record of Dan's answers about lesson entries"
write_to "$WORK/repo/..//record/./answers.jsonl"
expect_deny "#3583 the record reached through .., a doubled slash and a dot is the record" "the record of Dan's answers about lesson entries"
write_to "../record/answers.jsonl"
expect_deny "#3583 the record named from the session's own folder is the record" "the record of Dan's answers about lesson entries"
ln -s "$RECORD" "$WORK/a-door"
write_to "$WORK/a-door/answers.jsonl"
expect_deny "#3583 the record reached through a linked folder is the record" "the record of Dan's answers about lesson entries"
: > "$RECORD/answers.jsonl"; ln -s "$RECORD/answers.jsonl" "$WORK/an-alias-for-the-me""rge.jsonl"
write_to "$WORK/an-alias-for-the-me""rge.jsonl"
expect_deny "#3583 the record reached through a linked file is the record" "the record of Dan's answers about lesson entries"
PAYLOAD_EXTRA="$PAYLOAD_EXTRA"',"agent_id":"a1b2c3d4"' write_to "$RECORD/answers.jsonl"
expect_deny "#3583 a subagent's Write to the record is refused alike" "the record of Dan's answers about lesson entries"
# Outside a test run the record is the one under the home folder, here a folder of the run's own.
write_to "$WORK/home/.claude/state/$RECORD_NAME_WORDS/answers.jsonl" HOOK_TESTS_RUNNING= CLAUDE_HOME= HOME="$WORK/home"
expect_deny "#3583 outside a test run the record under the home folder is the one guarded" "the record of Dan's answers about lesson entries"
# What is not the record is not refused.
mkdir -p "$WORK/notes-on-the-me""rge"
write_to "$WORK/notes-on-the-me""rge/answers.jsonl"
expect_allow "#3583 a Write to a file of the same name elsewhere is let through"
run_tool Write "{\"file_path\":$(json "$WORK/repo/notes.md"),\"content\":$(json "the record is $RECORD/answers.jsonl, read at the me""rge")}"
expect_allow "#3583 a Write whose text names the record, to another file, is let through"
run_tool Edit "{\"file_path\":$(json "$WORK/repo/README.md"),\"old_string\":\"a\",\"new_string\":\"about a me""rge\"}"
expect_allow "#3583 an Edit that only holds the word is let through"
expect_calls "#3583 and a tool that writes a file reads nothing from GitHub" 0

# The shell: the folder named in another case, or with a dot or a doubled slash, is the same folder.
run_hook "echo '{}' >> ~/.claude/STATE/LESSON-ME""RGES/answers.jsonl"
expect_deny "#3583 a shell command naming the record in capitals is refused" "is written only by lessons-me""rge-gate.sh"
run_hook "echo '{}' >> ~/.claude/State/Lesson-Me""rges/answers.jsonl"
expect_deny "#3583 a shell command naming the record in mixed case is refused" "is written only by lessons-me""rge-gate.sh"
run_hook "echo '{}' >> ~/.claude/state//$RECORD_NAME_WORDS/answers.jsonl"
expect_deny "#3583 a shell command naming the record with a doubled slash is refused" "is written only by lessons-me""rge-gate.sh"
run_hook "echo '{}' >> ~/.claude/state/./$RECORD_NAME_WORDS/answers.jsonl"
expect_deny "#3583 a shell command naming the record with a dot is refused" "is written only by lessons-me""rge-gate.sh"

# --- item 1, by the state reached: the record holds a line Dan did not answer -------------------------------------
# Whatever put the line there, it covers nothing: a line is believed only when the transcript it
# names holds the picker he answered. Each route below really writes the line, then the helper asks.
fresh; pull add:900
run_hook "$MERGE 7 --squash"; unanswered="$reason"
mkdir -p "$RECORD"
hand_line "$unanswered" > "$RECORD/answers.jsonl"
helper_ask
expect_deny "#3583 a line written on the record by hand, naming no transcript, covers nothing" "Dan has not answered the lesson picker"
expect_deny "#3583 and the refusal says the line is not his answer" "holds a line for this change that is not his answer"
said hand-written-line
run_hook "$MERGE 7 --squash"
expect_deny "#3583 nor does it cover a typed merge from a session he never answered in" "Dan has not answered the lesson picker"

# A script run by its path, which builds the folder's name as it runs: the line names this
# session's transcript, where nothing was answered.
fresh; mkdir -p "$RECORD"
hand_line "$unanswered" "$TRANSCRIPT" sess-1 > "$WORK/line.json"
printf '#!/usr/bin/env bash\nd="%s"; cat "%s" >> "${d}ord/answers.jsonl"\n' "$WORK/rec" "$WORK/line.json" > "$WORK/a-script.sh"
bash "$WORK/a-script.sh"
helper_ask
expect_deny "#3583 a line a script wrote, naming a transcript with no answer in it, covers nothing" "the transcript it names holds no such answer"

# An interpreter: the line names a transcript that is not there.
fresh; mkdir -p "$RECORD"
hand_line "$unanswered" "$WORK/no-such-transcript.jsonl" sess-1 > "$WORK/line.json"
python3 -c 'import sys; open(sys.argv[2], "a").write(open(sys.argv[1]).read())' "$WORK/line.json" "$RECORD/answers.jsonl"
helper_ask
expect_deny "#3583 a line an interpreter wrote, naming a transcript that is not there, covers nothing" "the transcript it names could not be read"

# A prepared file moved onto the record: the line names the transcript where he answered Do not merge.
fresh; answer "$unanswered" "" "Do not merge"
hand_line "$unanswered" "$TRANSCRIPT" sess-1 > "$WORK/prepared.jsonl"
mkdir -p "$RECORD"; mv "$WORK/prepared.jsonl" "$RECORD/answers.jsonl"
helper_ask
expect_deny "#3583 a prepared file moved onto the record, where he answered Do not merge, covers nothing" "the transcript it names holds no such answer"

# The record's folder swapped for a link to a prepared one: he answered for one change, and the
# line claims that answer for another.
fresh; answer "$unanswered"
pull add:900 change:5
run_hook "$MERGE 7 --squash" LM_MERGE_RECORD_DIR="$WORK/unused-record"; other="$reason"
mkdir -p "$WORK/prepared-folder"; hand_line "$other" "$TRANSCRIPT" sess-1 > "$WORK/prepared-folder/answers.jsonl"
rm -rf "$RECORD"; ln -s "$WORK/prepared-folder" "$RECORD"
helper_ask
expect_deny "#3583 a prepared folder linked in as the record, claiming his answer for another change, covers nothing" "the transcript it names holds no such answer"
rm -f "$RECORD"

# His answer for pull request 7, copied onto a line for pull request 8 carrying the same entries.
fresh; pull add:900; answer "$unanswered"
pr_json 8 2 "payload/LESSONS.md:MODIFIED" "README.md:MODIFIED"
PAYLOAD_EXTRA='"session_id":"me''rge-when-ready"' run_hook "$MERGE 8 --repo acme/widget --squash --match-head-commit $HEAD_SHA"; eight="$reason"
mkdir -p "$RECORD"; hand_line "$eight" "$TRANSCRIPT" sess-1 8 > "$RECORD/answers.jsonl"
PAYLOAD_EXTRA='"session_id":"me''rge-when-ready"' run_hook "$MERGE 8 --repo acme/widget --squash --match-head-commit $HEAD_SHA"
expect_deny "#3583 his answer for one pull request, copied onto a line for another, covers nothing" "Refusing to merge PR #8"

# The line the gate itself writes names the transcript and the session it read his answer in, and
# is believed for as long as that transcript holds the answer.
fresh; pull add:900
run_hook "$MERGE 7 --squash"; answer "$reason"; run_hook "$MERGE 7 --squash"
if python3 -c 'import json,os,sys; e=json.loads(open(sys.argv[1]).readline()); sys.exit(0 if e.get("transcript")==os.path.abspath(sys.argv[2]) and e.get("session")=="sess-1" else 1)' "$RECORD/answers.jsonl" "$TRANSCRIPT" 2>/dev/null; then pass; else fail "#3583 the gate's own line names the transcript and the session of his answer: $(cat "$RECORD/answers.jsonl" 2>&1)"; fi
helper_ask
expect_allow "#3583 the gate's own line, whose transcript holds his answer, covers the helper's ask"
mv "$TRANSCRIPT" "$WORK/transcript-set-aside.jsonl"
helper_ask
expect_deny "#3583 once that transcript is gone the line covers nothing, and he is asked again" "the transcript it names could not be read"
mv "$WORK/transcript-set-aside.jsonl" "$TRANSCRIPT"

# --- item 2: another spelling of the lessons file in the file list ---------------------------------------------------
for spelling in "payload/lessons.md:ADDED" "payload/Lessons.md:MODIFIED" "Payload/LESSONS.md:MODIFIED" "PAYLOAD/LESSONS.MD:ADDED" \
                "./payload/LESSONS.md:MODIFIED" "payload//LESSONS.md:MODIFIED" "payload/./LESSONS.md:MODIFIED" \
                "payload/hooks/../LESSONS.md:MODIFIED" "/payload/LESSONS.md:MODIFIED"; do
  fresh; pull
  pr_json 7 2 "$spelling" "README.md:MODIFIED"
  run_hook "$MERGE 7 --squash"
  expect_deny "#3583 ${spelling%:*} in the file list is the lessons file under another spelling" "another spelling of payload/LESSONS.md"
done
said another-spelling
fresh; pull add:900
pr_json 7 3 "payload/LESSONS.md:MODIFIED" "payload/lessons.md:ADDED" "README.md:MODIFIED"
run_hook "$MERGE 7 --squash"
expect_deny "#3583 another spelling beside the lessons file itself is refused, and no picker covers it" "another spelling of payload/LESSONS.md"
if says "AskUserQuestion"; then fail "#3583 no picker is named for another spelling: $reason"; else pass; fi
# A path through a link: the folder the lessons file is in, listed as a file itself.
fresh; pull
pr_json 7 2 "payload:ADDED" "README.md:MODIFIED"
run_hook "$MERGE 7 --squash"
expect_deny "#3583 the lessons file's own folder listed as a file (a link put in its place) is refused" "the folder payload/LESSONS.md is in"
pr_json 7 2 "Payload:ADDED" "README.md:MODIFIED"
run_hook "$MERGE 7 --squash"
expect_deny "#3583 and so is that folder under another spelling" "the folder payload/LESSONS.md is in"
# What only looks like it is another file, and costs the one read.
for other in "payload/LESSONS.md.bak:ADDED" "docs/payload/lessons.md:ADDED" "payload/hooks/lessons.md:ADDED" \
             "payload/LESSONS-INDEX-proof-over-green.md:MODIFIED" "payload/lessons.markdown:ADDED" "payloads:ADDED"; do
  fresh; pull
  pr_json 7 2 "$other" "README.md:MODIFIED"
  run_hook "$MERGE 7 --squash"
  expect_allow "#3583 ${other%:*} is not the lessons file"
  expect_calls "#3583 and costs the one read" 1
done

# --- item 2, where the file list cannot say: every file GitHub holds is read for another spelling ---------------------
# tree <commit> [<path>:<one hex digit> ...] [truncated]: the files GitHub holds at a commit, as its
# git trees endpoint answers; the digit, repeated, is the file's own sha.
tree() {
  python3 - "$WORK/gh/tree-$1" "${@:2}" <<'PY'
import json, sys
out, rows = sys.argv[1], sys.argv[2:]
held = [{"path": "README.md", "type": "blob", "sha": "1" * 40}, {"path": "payload", "type": "tree", "sha": "2" * 40},
        {"path": "payload/LESSONS.md", "type": "blob", "sha": "3" * 40}, {"path": "payload/hooks/lessons.md", "type": "blob", "sha": "9" * 40}]
cut = False
for row in rows:
    if row == "truncated":
        cut = True
        continue
    path, _, digit = row.rpartition(":")
    held.append({"path": path, "type": "blob", "sha": digit * 40})
json.dump({"sha": "0" * 40, "tree": held, "truncated": cut}, open(out, "w"))
PY
}
fresh; pull; pr_json 7 150 "README.md:MODIFIED"
tree "$MB_SHA"; tree "$HEAD_SHA" "payload/lessons.md:4"
run_hook "$MERGE 7 --squash"
expect_deny "#3583 a file list cut short does not hide another spelling added at the head" "payload/lessons.md, another spelling of payload/LESSONS.md"
said another-spelling-in-the-tree
tree "$MB_SHA" "payload/Lessons.md:4"; tree "$HEAD_SHA" "payload/Lessons.md:5"
run_hook "$MERGE 7 --squash"
expect_deny "#3583 nor another spelling whose text changes" "payload/Lessons.md, another spelling of payload/LESSONS.md"
tree "$MB_SHA" "Payload/LESSONS.md:4"; tree "$HEAD_SHA"
run_hook "$MERGE 7 --squash"
expect_deny "#3583 nor another spelling removed at the head" "Payload/LESSONS.md, another spelling of payload/LESSONS.md"
tree "$MB_SHA" "payload/lessons.md:4"; tree "$HEAD_SHA" "payload/lessons.md:4"
run_hook "$MERGE 7 --squash"
expect_allow "#3583 another spelling the pull request leaves as it was is not its change"
expect_calls "#3583 which costs the view, the merge base, the files at both commits and the lessons file twice" 6
tree "$MB_SHA"; tree "$HEAD_SHA" truncated
run_hook "$MERGE 7 --squash"
expect_deny "#3583 a tree GitHub cuts short cannot say, and is refused" "more files than GitHub lists in one answer"
tree "$MB_SHA"; rm -f "$WORK/gh/tree-$HEAD_SHA"; printf 'gh: Bad Gateway (HTTP 502)\n' > "$WORK/gh/err-tree-$HEAD_SHA"
run_hook "$MERGE 7 --squash"
expect_deny "#3583 the files unreadable at the head: refused with what GitHub said" "HTTP 502"
rm -f "$WORK/gh/err-tree-$HEAD_SHA"
pr_json 7 2 "payload/OLD.md:RENAMED" "README.md:MODIFIED"
tree "$MB_SHA"; tree "$HEAD_SHA" "payload:4"
run_hook "$MERGE 7 --squash"
expect_deny "#3583 a list holding a rename has the tree read, and the folder turned into a file is refused" "the folder payload/LESSONS.md is in"
# A pinned commit that is not the head: the head's file list says nothing of it, so its tree is read.
pr_json 7 2 "README.md:MODIFIED" "docs/x.md:MODIFIED"
lessons "$WORK/gh/blob-$PIN_SHA"
tree "$MB_SHA"; tree "$PIN_SHA" "payload/lessons.md:4"
run_hook "$MERGE 7 --squash --match-head-commit $PIN_SHA"
expect_deny "#3583 a pinned commit holding another spelling is refused" "payload/lessons.md, another spelling of payload/LESSONS.md"
rm -f "$WORK/gh"/tree-*

# --- item 3: a change that fits the picker shows its rules and SHORT lines -------------------------------------------
# Five changed entries: seventeen rows of rules and SHORT lines, which #3343 asked about as a count.
fresh; pull change:1 change:2 change:3 change:4 change:5
run_hook "$MERGE 7 --squash"
expect_deny "#3583 five changed entries are refused, naming the count" "5 entries changed (L1, L2, L3, L4, L5)."
expect_deny "#3583 and each rule is shown, the first" "L1: Rule 1 says a guard has to be seen to fail before anybody trusts what it reports."
expect_deny "#3583 the last" "L5: Rule 5 says a guard has to be seen to fail before anybody trusts what it reports."
expect_deny "#3583 with its SHORT line" "SHORT: Rule 5 in one line for the index."
if says 'a line starting "The change: "'; then fail "#3583 a change that fits is not asked about as a sweep: $reason"; else pass; fi
expect_deny "#3583 the refusal says how much of the picker the lines take" "rows of the 20 a question may take"
five="$reason"; said five-entries-shown
# An answer to the count alone, as the sweep form asked, no longer covers it.
python3 - "$TRANSCRIPT" "$five" <<'PY'
import json, re, sys, time
path, reason = sys.argv[1:3]
meta = json.loads(re.search(r'metadata (\{.*?\})\.', reason).group(1))
facts = reason.split("on a line of its own:\n\n", 1)[1].split("\n", 1)[0]
question = facts + "\nThe change: rewords must be seen as has to be seen in five entries.\nMay it merge?"
ask = {"questions": [{"question": question, "header": "Lessons", "multiSelect": False,
                      "options": [{"label": "Merge these lessons", "description": "The pull request may merge."},
                                  {"label": "Do not merge", "description": "The pull request stays open."}]}],
       "metadata": meta}
uid = "toolu_%d" % time.time_ns()
with open(path, "a") as f:
    f.write(json.dumps({"type": "assistant", "sessionId": "sess-1", "message": {"role": "assistant", "content": [
        {"type": "tool_use", "id": uid, "name": "AskUserQuestion", "input": ask}]}}) + "\n")
    f.write(json.dumps({"type": "user", "sessionId": "sess-1", "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": uid, "content": "answered"}]},
        "toolUseResult": {"questions": ask["questions"], "answers": {question: "Merge these lessons"}}}) + "\n")
PY
run_hook "$MERGE 7 --squash"
expect_deny "#3583 an answer to the count and one line about the change does not cover entries he was not shown" "the question he read did not hold"
answer "$five"
run_hook "$MERGE 7 --squash"
expect_allow "#3583 an answer to the question that showed all five covers the merge"
# Six of the same entries take one row more than the picker's limit: the sweep form is kept for it.
fresh; pull change:1 change:2 change:3 change:4 change:5 change:6
run_hook "$MERGE 7 --squash"
expect_deny "#3583 a change one row too tall for the picker keeps the sweep form" 'a line starting "The change: "'
case "$nl$reason" in *"${nl}L1: "*) fail "#3583 and the sweep form lists no rule: $reason" ;; *) pass ;; esac
# Whether it fits is the shared check's answer. Where that check cannot be run, no picker is named.
mkdir -p "$WORK/no-check"; printf '#!/usr/bin/env bash\necho "node: cannot run" >&2\nexit 1\n' > "$WORK/no-check/node"; chmod +x "$WORK/no-check/node"
fresh; pull change:1 change:2 change:3 change:4 change:5
run_hook "$MERGE 7 --squash" PATH="$WORK/no-check:$WORK/bin:$PATH"
expect_deny "#3583 with the shared picker check failing, a change that would fit names no picker" "could not be checked"
if says "AskUserQuestion"; then fail "#3583 no picker is named while the check cannot run: $reason"; else pass; fi
fresh; pull changeall:30
run_hook "$MERGE 7 --squash" PATH="$WORK/no-check:$WORK/bin:$PATH"
expect_deny "#3583 with the shared picker check failing, a sweep names no picker either" "could not be checked"
if says "AskUserQuestion"; then fail "#3583 no sweep picker is named while the check cannot run: $reason"; else pass; fi

# --- item 4: the API routes, a SHORT line alone ------------------------------------------------------------------------
fresh; pull add:900
run_hook "gh api -X PUT repos/acme/widget/pulls/7/me""rge -f merge_method=squash"
expect_deny "#3583 a merge through the REST endpoint is refused like a typed one" "Refusing to merge PR #7"
expect_deny "#3583 naming the entry" "1 entry added (L900)."
run_hook "gh api --method PUT /repos/acme/widget/pulls/7/me""rge"
expect_deny "#3583 the REST endpoint spelled with --method and a leading slash is refused" "Refusing to merge PR #7"
rm -f "$WORK/gh/node.json"
run_hook "gh api graphql -f query='mutation { me""rgePullRequest(input: {pullRequestId: \"PR_kwDOAAAA\"}) { clientMutationId } }'"
expect_deny "#3583 a GraphQL merge whose pull request GitHub cannot name is refused" "Cannot judge whether this me""rge changes a lesson entry"
printf '{"data":{"node":{"__typename":"PullRequest","repository":{"nameWithOwner":"acme/widget"},"number":7}}}\n' > "$WORK/gh/node.json"
run_hook "gh api graphql -f query='mutation { me""rgePullRequest(input: {pullRequestId: \"PR_kwDOAAAA\"}) { clientMutationId } }'"
expect_deny "#3583 a GraphQL merge of a pull request GitHub names is refused for its entries" "Refusing to merge PR #7"
run_hook "gh api graphql -f query='mutation { enqueuePullRequest(input: {pullRequestId: \"PR_kwDOAAAA\"}) { clientMutationId } }'"
expect_deny "#3583 a GraphQL add to the merge queue is refused for its entries" "Refusing to merge PR #7"
run_hook "$MERGE 7 --squash"; answer "$reason"
run_hook "gh api -X PUT repos/acme/widget/pulls/7/me""rge -f merge_method=squash"
expect_allow "#3583 with his answer the REST merge goes through"
run_hook "gh api graphql -f query='mutation { me""rgePullRequest(input: {pullRequestId: \"PR_kwDOAAAA\"}) { clientMutationId } }'"
expect_allow "#3583 and so does the GraphQL one"
rm -f "$WORK/gh/node.json"

fresh; pull short:5
run_hook "$MERGE 7 --squash"
expect_deny "#3583 a change to a SHORT line alone is a changed entry" "1 entry changed (L5)."
expect_deny "#3583 and the refusal shows the new SHORT line" "SHORT: Rule 5 in one line, reworded for the index."
answer "${reason/SHORT: Rule 5 in one line, reworded for the index./SHORT: Rule 5 in one line for the index.}"
run_hook "$MERGE 7 --squash"
expect_deny "#3583 an answer that showed him the old SHORT line covers nothing" 'the line "SHORT: Rule 5 in one line, reworded for the index."'

echo
echo "passed: $passed   failed: $failed"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
