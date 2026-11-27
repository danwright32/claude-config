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
export CLAUDE_HOME="$WORK/home"   # so a seam that stopped being read lands here, never in the real state
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
out="$(dec record "figures cut" accepted --where "the no-ai-tells skill")"; rc=$?
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
PY
)"
check_eq "the kinds decisions.py takes are the kinds draft-edit-diff.py offers" "same" "$same"

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
check "and says the ask before saving mod asks Dan again" "the ask before saving mod asks Dan again" "$body"
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
check "outside a suite the state folder is not taken from the environment" "state folder: $WORK/home/state/draft-edit-review" "$out"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
