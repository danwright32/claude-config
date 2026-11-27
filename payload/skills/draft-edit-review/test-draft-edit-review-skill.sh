#!/usr/bin/env bash
# Tests for the draft-edit-review skill (claude-config#3554): decisions.py, which keeps on this Mac
# what Dan decided about each kind of edit, and the words of SKILL.md that the feature rests on.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$HERE/../../hooks"
. "$HOOKS/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): hooks/lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

TOOL="$HERE/decisions.py"
SKILL="$HERE/SKILL.md"
DIFF="$HOOKS/lib/draft-edit-diff.py"
WORK="$(mktemp -d)"
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
pass=0; fail=0
check(){ if [[ "$3" == *"$2"* ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; echo "  expected to contain: $2"; echo "  actual: ${3:0:700}"; fi; }
check_not(){ if [[ "$3" != *"$2"* ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; echo "  expected NOT to contain: $2"; echo "  actual: ${3:0:700}"; fi; }
check_eq(){ if [[ "$3" == "$2" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 (expected '$2', got '${3:0:400}')"; fi; }

T0=1793631600   # 10:00 AM ET on 2026-11-02
export TZ=America/New_York
export HOOK_TESTS_RUNNING=1
export CLAUDE_HOME="$WORK/config"   # so a seam that stopped being read lands here, never in the real state
fresh(){ export DRAFT_EDIT_REVIEW_STATE_DIR="$WORK/$1/state/draft-edit-review"; }
dec(){ DRAFT_EDIT_REVIEW_NOW="${NOW:-$T0}" python3 -B "$TOOL" "$@" 2>&1; }

# --- nothing decided yet ----------------------------------------------------------------------------
fresh new
out="$(dec status)"; rc=$?
check_eq "status with no state: succeeds" "0" "$rc"
check "status with no state: the author is not set" "author: not set" "$out"
check "status with no state: nothing decided" "decisions: none" "$out"
check "status with no state: nothing to skip" "skip arguments: none" "$out"
check_eq "status makes no folder: looking writes nothing" "" "$(ls "$WORK/new" 2>/dev/null)"

# --- the author --------------------------------------------------------------------------------------
dec author U0FIXTUREA >/dev/null
check "the author is kept" "author: U0FIXTUREA" "$(dec status)"
out="$(dec author "two words; rm")"; rc=$?
check_eq "an author that is no member id is refused" "2" "$rc"

# --- decisions ---------------------------------------------------------------------------------------
out="$(dec record "figures cut" accepted --where no-ai-tells)"; rc=$?
check_eq "an accepted rule is recorded" "0" "$rc"
dec record "length cut" never >/dev/null
dec record "the ask reworded" not-now >/dev/null
out="$(dec status)"
check "status shows the accepted one, with where it went and the day" "figures cut: accepted on 2026-11-02, written to the no-ai-tells skill" "$out"
check "status shows the one never to offer" "length cut: never offer again, decided 2026-11-02" "$out"
check "status shows the one put off" "the ask reworded: not now, decided 2026-11-02" "$out"
check "accepted and never are skipped at the next run, and not now is offered again" 'skip arguments: --skip "figures cut" --skip "length cut"' "$out"
check_not "not now is not skipped" '--skip "the ask reworded"' "$out"

out="$(dec record "figures cut" accepted)"; rc=$?
check_eq "accepted with no place named is refused" "2" "$rc"
check "and says a rule is accepted only once it is written somewhere" "--where" "$out"
out="$(dec record "no such kind" never)"; rc=$?
check_eq "a kind that does not exist is refused" "2" "$rc"
out="$(dec record "length cut" maybe)"; rc=$?
check_eq "a decision that does not exist is refused" "2" "$rc"
check "nothing above changed what was recorded" "length cut: never offer again" "$(dec status)"

# Where a rule went is one of three labels, and a project's folder name: never text somebody typed (S9).
out="$(dec record "the opening changed" accepted --where "the no-ai-tells skill, after a chat about the harbour")"; rc=$?
check_eq "where: free text is refused" "2" "$rc"
check "where: and the labels are named" "no-ai-tells, global-claude-md or project" "$out"
check_not "where: nothing was recorded for it" "the opening changed:" "$(dec status)"
dec record "the opening changed" accepted --where global-claude-md >/dev/null
check "where: the global file is said in words" "the opening changed: accepted on 2026-11-02, written to the Slack section of the global CLAUDE.md" "$(dec status)"
dec record "the opening changed" accepted --where project --project tide-tables >/dev/null
check "where: a project is said with its folder name" "the opening changed: accepted on 2026-11-02, written to the project's own file (tide-tables)" "$(dec status)"
out="$(dec record "the opening changed" accepted --where project --project "two words")"; rc=$?
check_eq "where: a project name with a space is refused" "2" "$rc"
out="$(dec record "the opening changed" accepted --where project --project "a/b")"; rc=$?
check_eq "where: a project name with a slash is refused" "2" "$rc"
out="$(dec record "the opening changed" accepted --where project --project "$(printf 'x%.0s' $(seq 1 61))")"; rc=$?
check_eq "where: a project name over 60 characters is refused" "2" "$rc"
out="$(dec record "the opening changed" accepted --where no-ai-tells --project tide-tables)"; rc=$?
check_eq "where: a project name beside another place is refused" "2" "$rc"
check "where: none of those changed what was recorded" "written to the project's own file (tide-tables)" "$(dec status)"
dec forget "the opening changed" >/dev/null

# A wrong answer is not permanent: it can be taken back, and the kind is offered again.
dec forget "length cut" >/dev/null
out="$(dec status)"
check_not "a forgotten decision is gone" "length cut:" "$out"
check 'and its kind is offered again' 'skip arguments: --skip "figures cut"' "$out"
check_not "(only the kind still decided is skipped)" '--skip "length cut"' "$out"

# --- a finished review is what the weekly notice reads ------------------------------------------------
NOW=$((T0 + 500)) dec reviewed >/dev/null
check_eq "reviewed records the time where the notice reads it" "$((T0 + 500))" "$(cat "$DRAFT_EDIT_REVIEW_STATE_DIR/last-review" 2>/dev/null)"
check "and status says when" "last review: 2026-11-02" "$(dec status)"

# --- state it cannot read: refused, never read as nothing decided --------------------------------------
fresh broken
mkdir -p "$DRAFT_EDIT_REVIEW_STATE_DIR"
printf '{"decisions": {"figures cut": ' > "$DRAFT_EDIT_REVIEW_STATE_DIR/decisions.json"
out="$(dec status)"; rc=$?
check_eq "decisions that are not JSON: status fails" "3" "$rc"
check "and says it could not be read" "could not be read" "$out"
check_not "and never says nothing is decided" "decisions: none" "$out"
out="$(dec record "length cut" never)"; rc=$?
check_eq "and a record is refused, so what was there is not written over" "3" "$rc"
check_eq "the file is as it was" '{"decisions": {"figures cut": ' "$(cat "$DRAFT_EDIT_REVIEW_STATE_DIR/decisions.json")"
printf '\xff\xfe not text' > "$DRAFT_EDIT_REVIEW_STATE_DIR/decisions.json"
out="$(dec status)"; rc=$?
check_eq "decisions holding bytes that are not UTF-8: status fails, and does not crash" "3" "$rc"
check_not "with no traceback" "Traceback" "$out"
# A time no calendar holds is state that cannot be read, never a crash.
fresh farfuture
mkdir -p "$DRAFT_EDIT_REVIEW_STATE_DIR"
echo 999999999999999 > "$DRAFT_EDIT_REVIEW_STATE_DIR/last-review"
out="$(dec status)"; rc=$?
check_eq "a last review at a time no calendar holds: status fails" "3" "$rc"
check_not "with no traceback" "Traceback" "$out"
rm -f "$DRAFT_EDIT_REVIEW_STATE_DIR/last-review"
printf '{"version": 1, "decisions": {"length cut": {"decision": "never", "at": 99999999999999999999}}}\n' > "$DRAFT_EDIT_REVIEW_STATE_DIR/decisions.json"
out="$(dec status)"; rc=$?
check_eq "a decision dated at a time no calendar holds: status fails" "3" "$rc"
check_not "with no traceback either" "Traceback" "$out"
printf '{"version": 1, "decisions": {"length cut": {"decision": "accepted", "at": 1793631600, "where": "somewhere somebody typed"}}}\n' > "$DRAFT_EDIT_REVIEW_STATE_DIR/decisions.json"
out="$(dec status)"; rc=$?
check_eq "a stored place that is none of the labels: status fails" "3" "$rc"
check_not "and the stored text is not printed back" "somebody typed" "$out"
if [ "$(id -u)" != 0 ]; then
  fresh shut
  dec record "length cut" never >/dev/null
  chmod 555 "$DRAFT_EDIT_REVIEW_STATE_DIR"
  out="$(dec record "figures cut" never)"; rc=$?
  check_eq "a decision that cannot be saved fails" "3" "$rc"
  check "and says it was not recorded" "was not recorded" "$out"
  chmod 755 "$DRAFT_EDIT_REVIEW_STATE_DIR"
fi

# --- one list of kinds, in two files -----------------------------------------------------------------
same="$(python3 -B - "$TOOL" "$DIFF" <<'PY'
import ast, sys
sys.stdout.reconfigure(errors="replace")
def named(path, name):
    try:
        with open(path, "rb") as f:
            tree = ast.parse(f.read().decode("utf-8", "replace"))
    except (OSError, SyntaxError) as e:
        return "unreadable %s: %s" % (path, e)
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == name for t in node.targets):
            return tuple(ast.literal_eval(node.value))
    return "no %s in %s" % (name, path)
a, b = named(sys.argv[1], "KINDS"), named(sys.argv[2], "OFFERED")
print("same" if a == b and isinstance(a, tuple) and a else "decisions.py: %r; draft-edit-diff.py: %r" % (a, b))
c, d = named(sys.argv[1], "SKIPPED"), named(sys.argv[2], "DECIDED_FOR_GOOD")
print("same" if c == d and isinstance(c, tuple) and c else "decisions.py: %r; draft-edit-diff.py: %r" % (c, d))
PY
)"
check_eq "the kinds decisions.py takes are the kinds draft-edit-diff.py offers" "same" "$(printf '%s\n' "$same" | sed -n 1p)"
check_eq "and the answers that stop an offer are the same in both" "same" "$(printf '%s\n' "$same" | sed -n 2p)"

# --- "never" is a fact of the code: the reader reads what decisions.py wrote, with nothing passed (S2) ----
E2E="$WORK/e2e"
mkdir -p "$E2E/records/project"
python3 -B "$HOOKS/draft-edit-fixtures/build.py" "$E2E/records/project" recurring
real(){ env -u CLAUDE_HOME -u DRAFT_EDIT_REVIEW_STATE_DIR HOME="$E2E" "$@" 2>&1; }
read_back(){ real python3 -B "$DIFF" --records "$E2E/records" --author U0FIXTUREA; }
check "round trip: with nothing decided the kind is offered" "figures cut: 12 of 12 pairs, in 3 threads: recurring" "$(read_back)"
real python3 -B "$TOOL" record "figures cut" never >/dev/null
out="$(read_back)"
check "round trip: a kind recorded as never is not offered by the reader" "figures cut: 12 of 12 pairs, in 3 threads: decided before, not offered" "$out"
check "round trip: a kind not decided still is" "length cut: 12 of 12 pairs, in 3 threads: recurring" "$out"
real python3 -B "$TOOL" record "length cut" accepted --where global-claude-md >/dev/null
check "round trip: an accepted kind is not offered again either" "length cut: 12 of 12 pairs, in 3 threads: decided before, not offered" "$(read_back)"
real python3 -B "$TOOL" forget "figures cut" >/dev/null
check "round trip: a forgotten decision is offered again" "figures cut: 12 of 12 pairs, in 3 threads: recurring" "$(read_back)"

# --- decisions.py reads no session record ----------------------------------------------------------------
check_eq "decisions.py names no session records folder: it can write, so it must never read them" "0" "$(grep -c -E 'projects|jsonl' "$TOOL")"

# --- what SKILL.md has to say ------------------------------------------------------------------------------
body="$(tr '\n' ' ' < "$SKILL" 2>/dev/null | tr -s ' ')"
check "the skill is named" "name: draft-edit-review" "$body"
check "it runs the reader by its installed path" "hooks/lib/draft-edit-diff.py" "$body"
check "it asks one question for each recurring kind" "one AskUserQuestion for each recurring kind" "$body"
for option in "Accept" "Not now" "Never offer this again"; do check "the picker offers: $option" "$option" "$body"; done
check "a second question asks where an accepted rule goes" "a second AskUserQuestion asks where the rule goes" "$body"
for place in "The no-ai-tells skill" "The Slack section of the global CLAUDE.md" "This project's own file"; do check "the places offered: $place" "$place" "$body"; done
check "the session makes the edit itself" "make the edit yourself, with the Edit tool" "$body"
# The review's M3. The sentence is checked with /no-ai-tells BEFORE the question that shows it, so
# what Dan accepts is what is written; and each place says what really checks the save there.
follows(){ # follows <first> <second>: 1 when both are in the skill and the first comes before the second
  local rest="${body#*"$1"}"
  if [[ "$rest" != "$body" && "$rest" == *"$2"* && "${body%%"$1"*}" != *"$2"* ]]; then echo 1; else echo 0; fi
}
check_eq "the sentence is checked with /no-ai-tells before the question that shows it" "1" "$(follows 'Run `/no-ai-tells` on that whole sentence now' 'Ask one AskUserQuestion for each recurring kind')"
check_eq "the day and what it rests on are added before the check, so he sees them too" "1" "$(follows 'Add the day and what it rests on in brackets' 'Run `/no-ai-tells` on that whole sentence now')"
check_not "nothing rewords the sentence after he has accepted it" 'Run `/no-ai-tells` on the sentence first' "$body"
check "what is written is the sentence he accepted" "exactly the sentence he accepted, word for word" "$body"
check "and the check is not run again at the edit" 'Do not run `/no-ai-tells` again' "$body"
check "a rule he rewords is checked and asked again" 'run `/no-ai-tells` on his wording, and ask this question again' "$body"
check "it says which files the ask before saving mod asks about" 'The ask before saving mod asks Dan before a save to a `CLAUDE.md`, an `AGENTS.md` or a memory file' "$body"
check "and that it does not ask about a skill file" "The ask before saving mod does not ask about a skill file" "$body"
check_not "the claim that it asks before any rule file changes is gone" "asks Dan again before a rule file changes" "$body"
check "for the skill file one more question shows the final sentence and the file" "ask one more AskUserQuestion that shows the final sentence in full and the file's name and path" "$body"
check_eq "and that question comes before the edit" "1" "$(follows 'ask one more AskUserQuestion that shows the final sentence in full' 'Then make the edit yourself, with the Edit tool')"
# The reader's output never goes into an issue (S1), and the reader reads the decisions itself (S2).
check "the note filed on exit 4 holds no line of the reader's output" "Never put a line of either run's output in that note" "$body"
check_not "the skill no longer hands the reader skip arguments" "<skip arguments>" "$body"
check "it says the reader reads the decisions itself" "It reads the decisions from step 1 itself" "$body"
check_not "a line about one unreadable result is not called nothing measured" "or a line saying read results were in a layout it cannot read" "$body"
for label in "--where no-ai-tells" "--where global-claude-md" "--where project --project"; do check "the record command for each place: $label" "$label" "$body"; done
check "a rule is written by no other route" "Never write a rule by any other route" "$body"
check "a kind under the floor is reported and not offered" "too thin" "$body"
check "the example pair goes nowhere but the question" "Never copy an example" "$body"
check "a refusal by the Slack drafts gate is final" "is final" "$body"
check "each decision is recorded" "decisions.py record" "$body"
check "the review is marked finished" "decisions.py reviewed" "$body"
check "a decision can be taken back" "decisions.py forget" "$body"
# The two long dashes are written as their bytes, so this file holds neither character.
EM="$(printf '\342\200\224')"; EN="$(printf '\342\200\223')"
check_eq "no dash is used as punctuation in the skill" "0" "$(grep -c -e ' - ' -e "$EM" -e "$EN" "$SKILL" 2>/dev/null || true)"
check_eq "and that check sees a long dash when one is there" "1" "$(printf 'a rule %s with a dash\n' "$EM" | grep -c -e ' - ' -e "$EM" -e "$EN" || true)"

# Outside the suites the folder and the clock cannot be moved by the environment.
out="$(HOOK_TESTS_RUNNING=0 DRAFT_EDIT_REVIEW_STATE_DIR="$WORK/elsewhere" python3 -B "$TOOL" status 2>&1)"
check "outside a suite the state folder is not taken from the environment" "state folder: $WORK/config/state/draft-edit-review" "$out"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
