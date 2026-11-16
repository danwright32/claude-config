#!/usr/bin/env bash
# test-db-write-ask-approved-lines.sh: db-write-ask.sh trusts a line of a checkout's Supabase test
# project list only when Dan himself approved it in a picker (claude-config#3023).
#
# Before this, the hook asked about `git commit` and nothing else, so a line still reached HEAD with
# no question through a git alias for commit, git commit-tree, a merge, a cherry pick, a rebase or a
# pull, and a file run on that project then passed unasked. Enumerating git commands could never
# end that, so the list is now judged where it is used: when a database write runs, a line counts
# only if it is in HEAD and Dan approved it, in a picker of this session or on this Mac's record of
# the lines he approved in one. A commit having run after the hook's question approves nothing,
# since sleep mode can answer a permission prompt with Dan asleep and never a picker.
# Each route above is driven here with real git in a throwaway checkout, and the write that follows
# must be asked about. Every ref is invented, and no database is ever reached: the hook only reads
# the command it is handed.
#
# Kept apart from test-db-write-ask.sh, which already takes about a minute, so these cases can be
# run on their own while the code under them changes.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/db-write-ask.sh"
. "$DIR/lib/settings-file.sh" 2>/dev/null || { echo "FAIL: lib/settings-file.sh is missing beside this suite"; printf 'SUITE-RESULT passed=0 failed=1\n'; exit 1; }
SETTINGS="$(hook_settings_file "$DIR/..")" || SETTINGS=""

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

if [ ! -f "$HOOK" ]; then
  echo "FAIL: there is no db-write-ask.sh beside this suite at $DIR"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

WORK="$(cd "$(mktemp -d)" && pwd -P)"
# Some cases below turn on the hook's screen finding neither of two words in a payload, and every
# payload holds this folder's path, so a random name that spells one of them is drawn again.
while case "$WORK" in *git*|*commit*) true ;; *) false ;; esac; do rmdir "$WORK"; WORK="$(cd "$(mktemp -d)" && pwd -P)"; done
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
# A HOME of its own: the record of approved lines is kept under it, never under the Mac's real one.
HOME_A="$WORK/home"
mkdir -p "$HOME_A"
RECORD="$HOME_A/.claude/state/supabase-test-projects"
NONE_T="$WORK/no-apply.jsonl"
printf '{"type": "user", "sessionId": "s1", "message": {"role": "user", "content": "hi"}}\n' > "$NONE_T"

# The suite's transcript: every picker a case has Dan answer is appended to it, and every payload
# names it unless TRANSCRIPT names another (NONE_T, a later session's, holds no picker).
TALK="$WORK/talk.jsonl"
cp "$NONE_T" "$TALK"
# bash_payload <event> <command> <cwd> [session]: a Bash call as Claude Code sends it. AGENT=1 makes
# it a subagent's call: its payload carries agent_id and agent_type and names the MAIN session's
# transcript (both captured on Claude Code 2.1.325, 2026-11-15); a main session's carries neither.
bash_payload() {
  python3 -c 'import json, os, sys
d = {"session_id": sys.argv[4], "transcript_path": sys.argv[5], "hook_event_name": sys.argv[1], "cwd": sys.argv[3],
     "tool_use_id": "toolu_suite1", "permission_mode": "auto",
     "tool_name": "Bash", "tool_input": {"command": sys.argv[2], "description": "d"}}
if os.environ.get("AGENT") == "1":
    d["agent_id"] = "a9bba4c0ffee"
    d["agent_type"] = "general-purpose"
print(json.dumps(d))' "$1" "$2" "$3" "${4:-s1}" "${TRANSCRIPT:-$TALK}"
}
# said <hook output> <exit code>: "<decision> rc=<exit>|<reason>|<notice>".
said() {
  printf '%s' "$1" | python3 -c '
import json, sys
t = sys.stdin.read().strip()
try:
    d = json.loads(t) if t else {}
except Exception:
    print("badjson rc=" + sys.argv[1] + "|" + t[:300] + "|", end=""); sys.exit()
h = d.get("hookSpecificOutput") or {}
print(h.get("permissionDecision", "none") + " rc=" + sys.argv[1] + "|" + h.get("permissionDecisionReason", "") + "|" + d.get("systemMessage", ""), end="")' "$2"
}
# before <command> <cwd> [session]: the hook's answer before that Bash call runs.
before() {
  local body rc
  body="$(cd "$WORK" && bash_payload PreToolUse "$1" "$2" "${3:-s1}" | env -u CLAUDE_HOME HOME="${HOME_USED:-$HOME_A}" bash "$HOOK" 2>/dev/null)"; rc=$?
  said "$body" "$rc"
}
CARRY='supabase db query --linked --yes -f carry.sql'
# write <checkout>: the hook's answer to a write from a file on the project that checkout is linked to.
write() { before "$CARRY" "$1"; }

G() { git -C "$1" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null -c pull.rebase=false "${@:2}" >/dev/null 2>&1; }
# new_repo <dir> <ref>: a checkout of its own linked to project <ref>, one commit, no list yet.
new_repo() {
  mkdir -p "$1/supabase/.temp" "$1/.claude"
  printf '%s' "$2" > "$1/supabase/.temp/project-ref"
  printf 'update a set note = 1 where id = 7;\n' > "$1/carry.sql"
  printf 'notes\n' > "$1/notes.txt"
  G "$1" init -q -b main && G "$1" add notes.txt carry.sql && G "$1" commit -q -m base
}
# stage_line <dir> <ref>: that ref added to the checkout's list and staged, not committed.
stage_line() {
  printf '%s\n' "$2" >> "$1/.claude/supabase-test-projects"
  G "$1" add -f .claude/supabase-test-projects
}
in_head() {
  local held
  held="$(git -C "$1" show HEAD:.claude/supabase-test-projects 2>/dev/null)"
  case $'\n'"$held"$'\n' in *$'\n'"$2"$'\n'*) return 0 ;; esac
  return 1
}
# trust <dir> <ref> [answer] [session] [shape]: Dan answering the picker that names <dir>'s list and
# <ref>, appended to the transcript as Claude Code writes one: the picker's input on the assistant
# entry holding its tool_use, his choice in toolUseResult.answers on the user entry carrying its
# tool_result (the shape lib/db-apply-approval.py reads an Apply from). The shapes are the ways a
# picker is NOT his answer: timeout, prefilled, two (questions), error, othersource.
trust() {
  python3 - "${TRANSCRIPT:-$TALK}" "$1/.claude/supabase-test-projects" "$2" "${3:-Trust}" "${4:-s1}" "${5:-}" <<'PY'
import json, sys, time
path, listed, ref, answer, sid, shape = sys.argv[1:7]
q = "Trust " + ref + " as a test project?"
ask = {"questions": [{"question": q, "header": "Test project", "multiSelect": False,
                      "options": [{"label": "Trust", "description": "d"}, {"label": "Cancel", "description": "d"}]}],
       "metadata": {"source": "db-test-project", "list": listed, "project_ref": ref}}
result = {"questions": ask["questions"], "answers": {q: answer}, "annotations": {}}
if shape == "timeout":
    result["afkTimeoutMs"] = 60000
if shape == "prefilled":
    ask["answers"] = {q: answer}
if shape == "two":
    ask["questions"] = ask["questions"] * 2
if shape == "othersource":
    ask["metadata"]["source"] = "db-apply"
uid = "toolu_trust%d" % time.time_ns()
with open(path, "a") as f:
    f.write(json.dumps({"type": "assistant", "sessionId": sid, "message": {"role": "assistant", "content": [
        {"type": "tool_use", "id": uid, "name": "AskUserQuestion", "input": ask}]}}) + "\n")
    f.write(json.dumps({"type": "user", "sessionId": sid, "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": uid, "content": "answered", "is_error": shape == "error"}]},
        "toolUseResult": result}) + "\n")
PY
}
# yes_commit <dir> <message word>: the staged list committed with Dan's approval: he answers Trust
# in a picker for each ref the commit adds, the hook reads the commit before it runs, and git
# commits. Prints the hook's answer before the commit.
yes_commit() {
  local cmd="git commit -q -m $2" r line added
  # Read into a variable first, so no child is left that this shell never waits for (#2040). A
  # commit adding nothing leaves one empty line here, which the pattern below does not match.
  added="$(git -C "$1" diff --cached -U0 -- .claude/supabase-test-projects 2>/dev/null | grep -v '^+++')"
  while IFS= read -r line; do
    case "$line" in +[A-Za-z0-9_-]*) trust "$1" "${line#+}" ;; esac
  done <<ADDED
$added
ADDED
  r="$(before "$cmd" "$1" "${3:-s1}")"
  G "$1" commit -q -m "$2"
  printf '%s' "$r"
}
# unasked <label> <dir> <ref>: the line is in HEAD, and the write is asked about, naming the project
# and the issue.
unasked() {
  local r
  if ! in_head "$2" "$3"; then
    check "$1" "the fixture is wrong: the route did not put $3 in HEAD, so nothing here measures it"
    return
  fi
  r="$(write "$2")"
  case "$r" in
    "ask rc=0|"*"$3"*3023*) check "$1" ok ;;
    *) check "$1" "wanted the write asked about, naming $3 and #3023; got ${r:0:400}" ;;
  esac
}

# --- the control: a line Dan approved in a picker is trusted --------------------------------------
OK_R="$WORK/approved"; new_repo "$OK_R" approvedref00000001
stage_line "$OK_R" approvedref00000001
r="$(before 'git commit -q -m list' "$OK_R")"
case "$r" in
  "ask rc=0|"*approvedref00000001*supabase-test-projects*"approves nothing"*AskUserQuestion*db-test-project*) check "a commit adding a line Dan has not approved is asked about, naming the line and how he approves it" ok ;;
  *) check "a commit adding a line Dan has not approved is asked about, naming the line and how he approves it" "${r:0:700}" ;;
esac
trust "$OK_R" approvedref00000001
r="$(before 'git commit -q -m list' "$OK_R")"
case "$r" in "none rc=0||") check "a commit whose every added line Dan approved in a picker is not asked about" ok ;; *) check "a commit whose every added line Dan approved in a picker is not asked about" "${r:0:400}" ;; esac
G "$OK_R" commit -q -m list
r="$(write "$OK_R")"
case "$r" in
  "allow rc=0||") check "a write on a project whose line Dan approved passes, with nothing said" ok ;;
  *) check "a write on a project whose line Dan approved passes, with nothing said" "${r:0:400}" ;;
esac
[ -s "$RECORD/approved" ] && check "the approved line is on this Mac's record, under its own home" ok || check "the approved line is on this Mac's record, under its own home" "no $RECORD/approved"
if grep -q approvedref00000001 "$RECORD/approved" 2>/dev/null; then
  check "the record holds a hash of the line, never the project ref itself" "the ref is written out in $RECORD/approved"
else
  check "the record holds a hash of the line, never the project ref itself" ok
fi
r="$(TRANSCRIPT="$NONE_T" write "$OK_R")"
case "$r" in "allow rc=0||") check "and it stays trusted in a later session, whose transcript holds no picker, by the record" ok ;; *) check "and it stays trusted in a later session, whose transcript holds no picker, by the record" "${r:0:400}" ;; esac

# A COMMIT HAVING RUN APPROVES NOTHING. The first build took a commit running after the hook's
# question as Dan's yes. Sleep mode approves Claude Code's permission prompts for an overnight
# worker (payload/mods/scope-modes, #834), so a prompt can be answered with Dan asleep; a picker
# cannot (sleep mode never answers a question, and a subagent has none to ask).
R="$WORK/yesonly"; new_repo "$R" yesonlyref00000001
stage_line "$R" yesonlyref00000001
r="$(before 'git commit -q -m list' "$R")"
case "$r" in "ask rc=0|"*yesonlyref00000001*) check "the commit of a line with no picker is asked about" ok ;; *) check "the commit of a line with no picker is asked about" "${r:0:300}" ;; esac
G "$R" commit -q -m list
unasked "a commit that ran after its question is no approval: the line is not trusted" "$R" yesonlyref00000001

# Only Dan's own choice of Trust, for this list and this ref, in this session, counts.
# not_by <label> <checkout name> <ref> <answer> <session> <shape>
not_by() {
  local R="$WORK/$2"
  new_repo "$R" "$3"; stage_line "$R" "$3"; G "$R" commit -q -m list
  trust "$R" "$3" "$4" "$5" "$6"
  unasked "$1" "$R" "$3"
}
not_by "a picker Dan answered Cancel approves nothing" cancelled cancelref000000001 Cancel s1 ""
not_by "a picker that timed out with Dan away approves nothing" timedout timeoutref00000001 Trust s1 timeout
not_by "a picker sent with its answer already filled in approves nothing" prefilled prefilledref000001 Trust s1 prefilled
not_by "a picker of two questions approves nothing" twoquestions twoqref00000000001 Trust s1 two
not_by "a picker that failed approves nothing" errored erroredref00000001 Trust s1 error
not_by "a picker answered in another session approves nothing" othersession sessionref00000001 Trust s2 ""
not_by "a picker carrying another source, the Apply's, approves nothing" othersource sourceref000000001 Trust s1 othersource
R="$WORK/otherref"; new_repo "$R" wantedref000000001
stage_line "$R" wantedref000000001; G "$R" commit -q -m list
trust "$R" unrelatedref000001
unasked "a picker naming another project approves nothing for this one" "$R" wantedref000000001
R="$WORK/otherlist"; new_repo "$R" otherlistref000001
stage_line "$R" otherlistref000001; G "$R" commit -q -m list
trust "$OK_R" otherlistref000001
unasked "a picker naming another checkout's list approves nothing for this one" "$R" otherlistref000001
R="$WORK/notranscript"; new_repo "$R" notalkref000000001
stage_line "$R" notalkref000000001; G "$R" commit -q -m list
trust "$R" notalkref000000001
TRANSCRIPT="$WORK/absent.jsonl" unasked "a transcript that cannot be read approves nothing" "$R" notalkref000000001

# A SUBAGENT'S CALL WRITES NOTHING ON THE RECORD. Dan's picker in the session's transcript lets its
# write pass, and the record is written only by a call of the main session.
R="$WORK/byagent"; new_repo "$R" agentref0000000001
stage_line "$R" agentref0000000001; G "$R" commit -q -m list
trust "$R" agentref0000000001
r="$(AGENT=1 write "$R")"
case "$r" in "allow rc=0||") check "a subagent's write on a line Dan approved in this session's picker passes" ok ;; *) check "a subagent's write on a line Dan approved in this session's picker passes" "${r:0:400}" ;; esac
TRANSCRIPT="$NONE_T" unasked "and it put nothing on the record: a later session's write is asked about" "$R" agentref0000000001
write "$R" >/dev/null
r="$(TRANSCRIPT="$NONE_T" write "$R")"
case "$r" in "allow rc=0||") check "the main session's write puts Dan's approval on the record, which a later session keeps" ok ;; *) check "the main session's write puts Dan's approval on the record, which a later session keeps" "${r:0:400}" ;; esac
R="$WORK/agentcommit"; new_repo "$R" agentcommitref0001
stage_line "$R" agentcommitref0001
trust "$R" agentcommitref0001
r="$(AGENT=1 before 'git commit -q -m list' "$R")"
case "$r" in "none rc=0||") check "a subagent's commit of a line Dan approved is not asked about" ok ;; *) check "a subagent's commit of a line Dan approved is not asked about" "${r:0:400}" ;; esac
G "$R" commit -q -m list
TRANSCRIPT="$NONE_T" unasked "and it put nothing on the record either" "$R" agentcommitref0001

# The list staged and committed in one command is asked about as the commit, by the question that
# names the line and says how Dan approves it.
R="$WORK/onecommand"; new_repo "$R" onecmdref000000001
printf 'onecmdref000000001\n' >> "$R/.claude/supabase-test-projects"
ONE='git add -f .claude/supabase-test-projects && git commit -q -m list'
r="$(before "$ONE" "$R")"
case "$r" in "ask rc=0|"*"would commit the line onecmdref000000001"*) check "the list staged and committed in one command is asked about as the commit, naming the line" ok ;; *) check "the list staged and committed in one command is asked about as the commit, naming the line" "${r:0:400}" ;; esac
G "$R" add -f .claude/supabase-test-projects; G "$R" commit -q -m list
# Staged with no commit that adds a line after it, it is asked about as a staging, as before.
r="$(before 'git add -f .claude/supabase-test-projects && npm test' "$R")"
case "$r" in "ask rc=0|"*"is not one that only reads it"*) check "the list staged before a command that is no commit is still asked about" ok ;; *) check "the list staged before a command that is no commit is still asked about" "${r:0:400}" ;; esac
r="$(before "$ONE" "$R")"
case "$r" in "ask rc=0|"*"is not one that only reads it"*) check "the list staged before a commit that adds no line is still asked about" ok ;; *) check "the list staged before a commit that adds no line is still asked about" "${r:0:400}" ;; esac
r="$(before 'echo onecmdref000000001 >> .claude/supabase-test-projects && git commit -q -am list' "$R")"
case "$r" in "ask rc=0|"*"is not one that only reads it"*) check "a write of the list before a commit is asked about as the write, never put off" ok ;; *) check "a write of the list before a commit is asked about as the write, never put off" "${r:0:400}" ;; esac

# --- each route that put a line in HEAD with no question: the write is asked about ---------------
R="$WORK/alias"; new_repo "$R" aliasref0000000001
stage_line "$R" aliasref0000000001
G "$R" -c alias.ci=commit ci -q -m "by an alias"
unasked "a line committed through a git alias for commit is not trusted" "$R" aliasref0000000001

R="$WORK/committree"; new_repo "$R" treeref00000000001
stage_line "$R" treeref00000000001
made="$(git -C "$R" -c user.name=t -c user.email=t@example.invalid commit-tree "$(git -C "$R" write-tree)" -p HEAD -m "by commit-tree" 2>/dev/null)"
G "$R" update-ref HEAD "$made"
unasked "a line committed through git commit-tree is not trusted" "$R" treeref00000000001

R="$WORK/merge"; new_repo "$R" mergeref0000000001
G "$R" checkout -q -b side
stage_line "$R" mergeref0000000001; G "$R" commit -q -m "on the side branch"
G "$R" checkout -q main
printf 'more\n' >> "$R/notes.txt"; G "$R" commit -q -am "main moves on"
G "$R" merge -q --no-edit side
unasked "a line a merge brought into HEAD is not trusted" "$R" mergeref0000000001

R="$WORK/cherry"; new_repo "$R" cherryref000000001
G "$R" checkout -q -b side
stage_line "$R" cherryref000000001; G "$R" commit -q -m "on the side branch"
G "$R" checkout -q main
G "$R" cherry-pick side
unasked "a line a cherry pick brought into HEAD is not trusted" "$R" cherryref000000001

R="$WORK/rebase"; new_repo "$R" rebaseref000000001
G "$R" checkout -q -b work
printf 'work\n' >> "$R/notes.txt"; G "$R" commit -q -am "work of its own"
G "$R" checkout -q main
stage_line "$R" rebaseref000000001; G "$R" commit -q -m "main gains the line"
G "$R" checkout -q work
G "$R" rebase -q main
unasked "a line a rebase brought into HEAD is not trusted" "$R" rebaseref000000001

R="$WORK/pull"; new_repo "$R" pullref00000000001
UP="$WORK/pull-upstream"; git clone -q "$R" "$UP" 2>/dev/null
mkdir -p "$UP/.claude"; stage_line "$UP" pullref00000000001; G "$UP" commit -q -m "another clone adds the line"
G "$R" pull -q "$UP" main
unasked "a line a pull brought into HEAD is not trusted" "$R" pullref00000000001

# A line nobody asked Dan about: committed before this shipped, on the other Mac, or by a person at
# a terminal. The question says how he approves it, and his picker is all it takes: no commit.
R="$WORK/neverasked"; new_repo "$R" oldref000000000001
stage_line "$R" oldref000000000001; G "$R" commit -q -m "before the record existed"
unasked "a line Dan approved in no picker is not trusted" "$R" oldref000000000001
r="$(write "$R")"
case "$r" in
  *AskUserQuestion*Trust*db-test-project*project_ref*) check "the question says how Dan approves the line: a picker carrying the hook's metadata" ok ;;
  *) check "the question says how Dan approves the line: a picker carrying the hook's metadata" "${r:0:700}" ;;
esac
trust "$R" oldref000000000001
r="$(write "$R")"
case "$r" in "allow rc=0||") check "after Dan answers that picker the write passes, with no commit needed" ok ;; *) check "after Dan answers that picker the write passes, with no commit needed" "${r:0:400}" ;; esac

# --- what an approval covers ---------------------------------------------------------------------
# The line and the list it is on, in that clone: a branch of it, and a worktree of it, are covered.
R="$WORK/branch"; new_repo "$R" branchref000000001
G "$R" checkout -q -b feature
stage_line "$R" branchref000000001; yes_commit "$R" list >/dev/null
G "$R" checkout -q main
printf 'more\n' >> "$R/notes.txt"; G "$R" commit -q -am "main moves on"
G "$R" merge -q --no-edit feature
r="$(write "$R")"
case "$r" in "allow rc=0||") check "a line approved on a branch stays trusted once merged in the same clone" ok ;; *) check "a line approved on a branch stays trusted once merged in the same clone" "${r:0:400}" ;; esac
TREE="$WORK/branch-worktree"
G "$R" worktree add -q "$TREE" -b tree main
mkdir -p "$TREE/supabase/.temp"; printf 'branchref000000001' > "$TREE/supabase/.temp/project-ref"
r="$(write "$TREE")"
case "$r" in "allow rc=0||") check "a line approved in a clone is trusted in a worktree of that clone" ok ;; *) check "a line approved in a clone is trusted in a worktree of that clone" "${r:0:400}" ;; esac
# Another clone holding the same line was never asked about.
CLONE="$WORK/branch-clone"; git clone -q "$R" "$CLONE" 2>/dev/null
mkdir -p "$CLONE/supabase/.temp"; printf 'branchref000000001' > "$CLONE/supabase/.temp/project-ref"
unasked "the same line in another clone is not trusted" "$CLONE" branchref000000001
# Another project put on the same list by a route nobody asked about: the approved one still passes.
R="$WORK/second"; new_repo "$R" firstref0000000001
stage_line "$R" firstref0000000001; yes_commit "$R" list >/dev/null
stage_line "$R" secondref000000002; G "$R" -c alias.ci=commit ci -q -m "by an alias"
r="$(write "$R")"
case "$r" in "allow rc=0||") check "an approved line stays trusted when another line arrives unasked" ok ;; *) check "an approved line stays trusted when another line arrives unasked" "${r:0:400}" ;; esac
printf 'secondref000000002' > "$R/supabase/.temp/project-ref"
unasked "the line that arrived unasked beside an approved one is not trusted" "$R" secondref000000002
# Each line is approved on its own: a commit adding twelve, one of them approved, is asked about the
# other eleven, names up to eight of them, and leaves them untrusted whatever is answered.
R="$WORK/many"; new_repo "$R" manyref0000000001
for i in 01 02 03 04 05 06 07 08 09 10 11 12; do printf 'manyref00000000%s\n' "$i" >> "$R/.claude/supabase-test-projects"; done
G "$R" add -f .claude/supabase-test-projects
trust "$R" manyref0000000001
r="$(before 'git commit -q -m many' "$R")"
shown=0; for i in 02 03 04 05 06 07 08 09 10 11 12; do case "$r" in *"manyref00000000$i"*) shown=$((shown + 1)) ;; esac; done
case "$r" in
  *manyref0000000001*) check "a commit adding more unapproved lines than the question holds names some and says there are more" "it named the line Dan approved: ${r:0:300}" ;;
  "ask rc=0|"*"and more"*) [ "$shown" -lt 11 ] && [ "$shown" -ge 1 ] && check "a commit adding more unapproved lines than the question holds names some and says there are more" ok || check "a commit adding more unapproved lines than the question holds names some and says there are more" "it named $shown of 11" ;;
  *) check "a commit adding more unapproved lines than the question holds names some and says there are more" "${r:0:500}" ;;
esac
G "$R" commit -q -m many
r="$(write "$R")"
case "$r" in "allow rc=0||") check "the line Dan approved is trusted, though its commit added others" ok ;; *) check "the line Dan approved is trusted, though its commit added others" "${r:0:400}" ;; esac
printf 'manyref0000000012' > "$R/supabase/.temp/project-ref"
unasked "a line of the same commit Dan approved no picker for is not trusted" "$R" manyref0000000012

# --- the record itself is held like the list -----------------------------------------------------
edit_payload() { python3 -c 'import json, sys; print(json.dumps({"session_id": "s1", "hook_event_name": "PreToolUse", "tool_name": sys.argv[1], "tool_input": {"file_path": sys.argv[2], "old_string": "a", "new_string": "b", "content": "c"}}))' "$1" "$2"; }
for t in Edit Write MultiEdit; do
  body="$(cd "$WORK" && edit_payload "$t" "$RECORD/approved" | env -u CLAUDE_HOME HOME="$HOME_A" bash "$HOOK" 2>/dev/null)"; r="$(said "$body" $?)"
  case "$r" in "ask rc=0|"*approved*3023*) check "a $t of the record of approved lines is asked about" ok ;; *) check "a $t of the record of approved lines is asked about" "${r:0:300}" ;; esac
  # What adds to the record is Dan's picker, never a commit he was asked about: the question must
  # not teach the rule the picker replaced.
  case "$r" in
    *"commit he answered yes"*) check "and the $t question names the picker he answered Trust, not a commit, as what adds to it" "it still says a commit he answered yes to adds to the record: ${r:0:400}" ;;
    *"picker he answered Trust"*) check "and the $t question names the picker he answered Trust, not a commit, as what adds to it" ok ;;
    *) check "and the $t question names the picker he answered Trust, not a commit, as what adds to it" "${r:0:400}" ;;
  esac
done
r="$(before "echo 0000 >> $RECORD/approved" "$WORK")"
case "$r" in "ask rc=0|"*"record of the test project lines Dan approved"*) check "a shell write to the record is asked about, naming it as the record" ok ;; *) check "a shell write to the record is asked about, naming it as the record" "${r:0:300}" ;; esac
r="$(before "cat $RECORD/approved" "$WORK")"
case "$r" in "none rc=0||") check "a read of the record passes" ok ;; *) check "a read of the record passes" "${r:0:300}" ;; esac

# --- failures: each leaves the line untrusted, and says what went wrong --------------------------
# The record cannot be read: nothing on it counts, and the question names the file.
R="$WORK/unreadable"; new_repo "$R" lockedref000000001
stage_line "$R" lockedref000000001; yes_commit "$R" list >/dev/null
chmod 000 "$RECORD/approved"
if cat "$RECORD/approved" >/dev/null 2>&1; then
  check "a record that cannot be read trusts nothing, and the question says so" "UNMEASURED: this user can read a file with no permissions (root?), so the unreadable case cannot be made"
else
  r="$(write "$R")"
  case "$r" in "ask rc=0|"*approved*"could not be read"*) check "a record that cannot be read trusts nothing, and the question says so" ok ;; *) check "a record that cannot be read trusts nothing, and the question says so" "${r:0:400}" ;; esac
  # A commit adding a line then says the record could not be read, never that Dan approved the
  # line in no picker, which nothing could look up (L11).
  stage_line "$R" lockedref000000002
  r="$(before 'git commit -q -m more' "$R")"
  case "$r" in
    "ask rc=0|"*"in no picker"*) check "and a commit adding a line says the record could not be read" "it claims he approved the line in no picker, with a record nothing could read: ${r:0:500}" ;;
    "ask rc=0|"*lockedref000000002*"could not be checked against the lines Dan approved"*"could not be read"*"approves nothing"*) check "and a commit adding a line says the record could not be read" ok ;;
    *) check "and a commit adding a line says the record could not be read" "${r:0:500}" ;;
  esac
fi
chmod 600 "$RECORD/approved"
# The record cannot be written (claude-config#3058). Before, the failure was swallowed: his picker
# let the call through, nothing was kept, and the next session asked him to approve the same line
# again with no reason given. Dan chose on 2026-11-16 to keep that trust: a line he approved in a
# picker is trusted for that call even when the record cannot take it. So a commit and a write on
# the picker's line still go through, and the hook says the save failed, naming the line, the
# record and the error, as a notice on the call it lets through and never as a question. Nothing
# is kept, so a later session is asked. The control: the same fixture, the record made writable,
# passes on the picker already given with nothing said, and a later session keeps it.
REC_B="$WORK/home-nowrite/.claude/state/supabase-test-projects"
HOME_B="$WORK/home-nowrite"; mkdir -p "$REC_B"; chmod 500 "$REC_B"
R="$WORK/nowrite"; new_repo "$R" nowriteref00000001
stage_line "$R" nowriteref00000001
trust "$R" nowriteref00000001
if : 2>/dev/null > "$REC_B/probe"; then
  check "with a record that cannot be written, a commit and a write on Dan's picker go through, saying the save failed" "UNMEASURED: this user can write into a folder with no write permission (root?), so the case cannot be made"
else
  r="$(HOME_USED="$HOME_B" before 'git commit -q -m list' "$R")"
  case "$r" in
    "ask rc=0|"*) check "a commit of a line Dan approved, whose record cannot be written, passes, saying the save failed" "it is asked about, though his picker covers the line: ${r:0:900}" ;;
    "none rc=0||") check "a commit of a line Dan approved, whose record cannot be written, passes, saying the save failed" "it passes and says nothing of the save that failed" ;;
    "none rc=0||"*nowriteref00000001*"$REC_B/approved"*"could not be written"*PermissionError*"ask him to approve"*3058*) check "a commit of a line Dan approved, whose record cannot be written, passes, saying the save failed" ok ;;
    *) check "a commit of a line Dan approved, whose record cannot be written, passes, saying the save failed" "${r:0:900}" ;;
  esac
  # The same commit in a command the screen reads as a database call too (its message holds the
  # word supabase) leaves by another way out of the hook, and still says it.
  r="$(HOME_USED="$HOME_B" before 'git commit -q -m supabase' "$R")"
  case "$r" in
    "none rc=0||"*nowriteref00000001*"$REC_B/approved"*"could not be written"*PermissionError*3058*) check "and so does one whose message holds a database word, which leaves the hook by another way" ok ;;
    *) check "and so does one whose message holds a database word, which leaves the hook by another way" "${r:0:900}" ;;
  esac
  G "$R" commit -q -m list
  r="$(HOME_USED="$HOME_B" write "$R")"
  case "$r" in
    "ask rc=0|"*) check "a write on a line Dan approved, whose record cannot be written, is let through, saying the save failed" "it is asked about, though his picker covers the line: ${r:0:900}" ;;
    "allow rc=0||") check "a write on a line Dan approved, whose record cannot be written, is let through, saying the save failed" "it is let through and says nothing of the save that failed" ;;
    "allow rc=0||"*nowriteref00000001*"$REC_B/approved"*"could not be written"*PermissionError*"ask him to approve"*3058*) check "a write on a line Dan approved, whose record cannot be written, is let through, saying the save failed" ok ;;
    *) check "a write on a line Dan approved, whose record cannot be written, is let through, saying the save failed" "${r:0:900}" ;;
  esac
  # Without lib/hook-notice.sh beside the hook the write is still let through, and the failed save
  # still said, in the hook's own plain JSON.
  NONOTE="$WORK/nonote"; mkdir -p "$NONOTE/hooks"
  cp "$HOOK" "$NONOTE/hooks/"; cp -R "$DIR/lib" "$NONOTE/hooks/lib"; rm -f "$NONOTE/hooks/lib/hook-notice.sh"
  body="$(cd "$WORK" && bash_payload PreToolUse "$CARRY" "$R" | env -u CLAUDE_HOME HOME="$HOME_B" bash "$NONOTE/hooks/db-write-ask.sh" 2>/dev/null)"; r="$(said "$body" $?)"
  case "$r" in
    "allow rc=0||"*nowriteref00000001*"could not be written"*PermissionError*"lib/hook-notice.sh is missing"*) check "with lib/hook-notice.sh missing, that write is still let through and the failed save still said" ok ;;
    *) check "with lib/hook-notice.sh missing, that write is still let through and the failed save still said" "${r:0:900}" ;;
  esac
  # A subagent's call writes nothing on the record, so it has no failed save to say.
  r="$(AGENT=1 HOME_USED="$HOME_B" write "$R")"
  case "$r" in "allow rc=0||") check "a subagent's write on that picker passes with nothing said, since it saves nothing" ok ;; *) check "a subagent's write on that picker passes with nothing said, since it saves nothing" "${r:0:400}" ;; esac
  [ -e "$REC_B/approved" ] && check "and nothing was put on the record" "$REC_B/approved exists" || check "and nothing was put on the record" ok
  HOME_USED="$HOME_B" TRANSCRIPT="$NONE_T" unasked "and a later session's write is asked about" "$R" nowriteref00000001
  # A commit adding one line with a picker and one without is asked about for the one without
  # only, and the notice beside the question says the save of the other failed.
  R2="$WORK/nowritemix"; new_repo "$R2" nowritemixref00001
  stage_line "$R2" nowritemixref00001; stage_line "$R2" nowritemixref00002
  trust "$R2" nowritemixref00001
  r="$(HOME_USED="$HOME_B" before 'git commit -q -m list' "$R2")"
  mix_reason="${r#*|}"; mix_notice="${mix_reason#*|}"; mix_reason="${mix_reason%%|*}"
  case "$r" in
    "ask rc=0|"*) case "$mix_reason" in
        *nowritemixref00001*) check "a commit adding a line with a picker and one without, whose record cannot be written, is asked about for the one without only" "the question names the line his picker covers: ${mix_reason:0:700}" ;;
        *nowritemixref00002*"in no picker"*AskUserQuestion*) check "a commit adding a line with a picker and one without, whose record cannot be written, is asked about for the one without only" ok ;;
        *) check "a commit adding a line with a picker and one without, whose record cannot be written, is asked about for the one without only" "${mix_reason:0:700}" ;;
      esac
      case "$mix_notice" in
        *nowritemixref00002*) check "and the notice beside that question says the save of the line his picker covers failed" "the notice names the line with no picker: ${mix_notice:0:700}" ;;
        *nowritemixref00001*"$REC_B/approved"*"could not be written"*PermissionError*3058*) check "and the notice beside that question says the save of the line his picker covers failed" ok ;;
        *) check "and the notice beside that question says the save of the line his picker covers failed" "${mix_notice:0:700}" ;;
      esac ;;
    *) check "a commit adding a line with a picker and one without, whose record cannot be written, is asked about for the one without only" "${r:0:900}" ;;
  esac
  chmod 700 "$REC_B"
  r="$(HOME_USED="$HOME_B" write "$R")"
  case "$r" in "allow rc=0||") check "once the record can be written, the same picker covers the write with nothing said" ok ;; *) check "once the record can be written, the same picker covers the write with nothing said" "${r:0:400}" ;; esac
  r="$(HOME_USED="$HOME_B" TRANSCRIPT="$NONE_T" write "$R")"
  case "$r" in "allow rc=0||") check "and a later session keeps it by the record" ok ;; *) check "and a later session keeps it by the record" "${r:0:400}" ;; esac
fi
chmod 700 "$REC_B"
# This session's transcript cannot be read: nobody looked for Dan's picker, so the question says
# the transcript could not be read and never that he approved the line in no picker (L11). The
# control is the same write with a transcript that reads and holds no picker.
R="$WORK/notalk"; new_repo "$R" notalkref000000001
stage_line "$R" notalkref000000001; G "$R" commit -q -m list
r="$(TRANSCRIPT="$NONE_T" write "$R")"
case "$r" in "ask rc=0|"*notalkref000000001*"in no picker"*) check "control: with a transcript that reads and holds no picker, the question says he approved it in no picker" ok ;; *) check "control: with a transcript that reads and holds no picker, the question says he approved it in no picker" "${r:0:500}" ;; esac
r="$(TRANSCRIPT="$WORK/gone.jsonl" write "$R")"
case "$r" in
  "ask rc=0|"*"in no picker"*) check "a write with a transcript that is not there is asked about, saying the transcript could not be read" "it claims he approved the line in no picker, which nothing read: ${r:0:500}" ;;
  "ask rc=0|"*notalkref000000001*"transcript"*"could not be read"*FileNotFoundError*3023*) check "a write with a transcript that is not there is asked about, saying the transcript could not be read" ok ;;
  *) check "a write with a transcript that is not there is asked about, saying the transcript could not be read" "${r:0:500}" ;;
esac
stage_line "$R" notalkref000000002
r="$(TRANSCRIPT="$WORK/gone.jsonl" before 'git commit -q -m more' "$R")"
case "$r" in
  "ask rc=0|"*"in no picker"*) check "and so is a commit adding a line, which says the same" "it claims he approved the line in no picker, which nothing read: ${r:0:500}" ;;
  "ask rc=0|"*notalkref000000002*"transcript"*"could not be read"*FileNotFoundError*"approves nothing"*) check "and so is a commit adding a line, which says the same" ok ;;
  *) check "and so is a commit adding a line, which says the same" "${r:0:500}" ;;
esac
# One budget bounds all the git a test project check runs, set short rather than waited out (L524).
SLOWGIT="$WORK/slowgit"; mkdir -p "$SLOWGIT"
printf '#!/bin/sh\nexec sleep 5\n' > "$SLOWGIT/git"; chmod +x "$SLOWGIT/git"
limits="$(HOME="$HOME_A" PATH="$SLOWGIT:$PATH" python3 -I -B - "$DIR/lib" "$OK_R" <<'PY'
import importlib.util, sys, time
spec = importlib.util.spec_from_file_location("ap", sys.argv[1] + "/db-apply-approval.py")
ap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ap)
ap.GIT_SECONDS = 0.3
t = time.monotonic()
print(ap.on_test_project(sys.argv[2], []))
print("took %.1f" % (time.monotonic() - t))
ap.GIT_SECONDS, ap.COMMIT_SECONDS = 4, 0
print(ap.on_test_project(sys.argv[2], []))
PY
)"
case "$limits" in *"(False, "*TimeoutExpired*"took 0."*) check "a git outlasting its limit while a test project is checked is asked about, within one limit" ok ;; *) check "a git outlasting its limit while a test project is checked is asked about, within one limit" "got: $limits" ;; esac
case "$limits" in *"git took longer than 0 seconds"*) check "a test project check past its whole budget is asked about, saying so" ok ;; *) check "a test project check past its whole budget is asked about, saying so" "got: $limits" ;; esac

# --- python3 missing or failing ------------------------------------------------------------------
. "$DIR/lib/no-python-path.sh"
NOPY="$WORK/nopy/bin"
npp_build_bin "$NOPY"
if npp_reaches_python3 "$NOPY"; then
  check "the bare directory reaches no python3" "it found one, so nothing below measures its absence"
else
  nopy() { local body rc; body="$(cd "$WORK" && printf '%s' "$1" | env -u CLAUDE_HOME HOME="$HOME_A" PATH="$NOPY" "$NOPY/bash" "$HOOK" ${2:+"$2"} 2>/dev/null)"; rc=$?; said "$body" "$rc"; }
  r="$(nopy "$(bash_payload PreToolUse 'git commit -m x' "$OK_R")")"
  case "$r" in "ask rc=0|"*"before this commit"*"python3 is not on PATH"*3023*) check "with no python3, a commit is asked about, naming python3" ok ;; *) check "with no python3, a commit is asked about, naming python3" "${r:0:400}" ;; esac
  r="$(nopy "$(bash_payload PreToolUse 'ls -la' "$OK_R")")"
  case "$r" in "none rc=0||") check "with no python3, a command that is no commit and no database call passes" ok ;; *) check "with no python3, a command that is no commit and no database call passes" "${r:0:300}" ;; esac
fi
# python3 failing: only a Bash call that could be a git commit is asked about as one.
PYFAIL="$WORK/pyfail"; mkdir -p "$PYFAIL"
printf '#!/bin/sh\nexit 1\n' > "$PYFAIL/python3"; chmod +x "$PYFAIL/python3"
failing() { local body rc; body="$(cd "$WORK" && printf '%s' "$1" | PATH="$PYFAIL:$PATH" env -u CLAUDE_HOME HOME="$HOME_A" bash "$HOOK" 2>/dev/null)"; rc=$?; said "$body" "$rc"; }
r="$(failing "$(bash_payload PreToolUse 'git commit -m x' "$OK_R")")"
case "$r" in "ask rc=0|"*"before this commit"*) check "with python3 failing, a commit is asked about as a commit" ok ;; *) check "with python3 failing, a commit is asked about as a commit" "${r:0:300}" ;; esac
# An Edit whose text holds the word Bash as a whole value, and the word commit, is no Bash call.
EDIT_BASH='{"session_id":"s1","hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"/tmp/notes.txt","old_string":"git commit the notes","new_string":"Bash"}}'
r="$(failing "$EDIT_BASH")"
case "$r" in "none rc=0||") check "with python3 failing, an Edit holding the words Bash and commit is not asked about as a commit" ok ;; *) check "with python3 failing, an Edit holding the words Bash and commit is not asked about as a commit" "${r:0:300}" ;; esac
r="$(failing "$(bash_payload PreToolUse 'gh pr view 12 --json commits' "$OK_R")")"
case "$r" in "none rc=0||") check "with python3 failing, a command holding the word commit and no git is not asked about" ok ;; *) check "with python3 failing, a command holding the word commit and no git is not asked about" "${r:0:300}" ;; esac

# --- what a commit costs: the cuts, each held by what it does, never by a stopwatch ---------------
# python3 and git stand ins that note how they were started, then run the real one.
REAL_PY="$(command -v python3)"; REAL_GIT="$(command -v git)"
SPY="$WORK/spy"; mkdir -p "$SPY"
printf '#!/bin/sh\nprintf "%%s %%s %%s\\n" "$1" "$2" "$3" >> "%s"\nexec "%s" "$@"\n' "$SPY/python.log" "$REAL_PY" > "$SPY/python3"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\nexec "%s" "$@"\n' "$SPY/git.log" "$REAL_GIT" > "$SPY/git"
chmod +x "$SPY/python3" "$SPY/git"
spied() {  # spied <payload>: the hook run with both stand ins first on the PATH
  rm -f "$SPY/python.log" "$SPY/git.log"
  (cd "$WORK" && printf '%s' "$1" | PATH="$SPY:$PATH" env -u CLAUDE_HOME HOME="$HOME_A" bash "$HOOK" >/dev/null 2>&1)
}
spied "$(bash_payload PreToolUse 'git commit -m x' "$OK_R")"
if [ -s "$SPY/python.log" ] && [ -s "$SPY/git.log" ]; then
  check "the stand ins see the hook start python3 and git for a commit" ok
  IFS= read -r started < "$SPY/python.log"
  case " $started " in *" -S "*) check "python3 is started without the site module, which the hook never uses" ok ;; *) check "python3 is started without the site module, which the hook never uses" "started as: $started" ;; esac
  walked="$(grep -- '--exclude-standard' "$SPY/git.log")"
  [ -n "$walked" ] && check "a commit alone in its command does not have git walk the untracked files" "git was run as: ${walked:0:160}" || check "a commit alone in its command does not have git walk the untracked files" ok
else
  check "the stand ins see the hook start python3 and git for a commit" "python3 log: $(wc -l < "$SPY/python.log" 2>/dev/null || echo none), git log: $(wc -l < "$SPY/git.log" 2>/dev/null || echo none)"
fi
spied "$(bash_payload PreToolUse 'git add -A && git commit -m x' "$OK_R")"
grep -q -- '--exclude-standard' "$SPY/git.log" 2>/dev/null && check "a commit after an add still has git list the untracked files, which the add could stage" ok || check "a commit after an add still has git list the untracked files, which the add could stage" "git was run as: $(head -3 "$SPY/git.log" 2>/dev/null | cut -c1-200)"
# An untracked list is what that walk is for: after an add it is asked about, alone it cannot be committed.
R="$WORK/untracked"; new_repo "$R" untrackedref000001
printf 'untrackedref000001\n' > "$R/.claude/supabase-test-projects"
r="$(before 'git add -A && git commit -m x' "$R")"
case "$r" in "ask rc=0|"*untrackedref000001*) check "an untracked list is asked about when an add comes before the commit" ok ;; *) check "an untracked list is asked about when an add comes before the commit" "${r:0:300}" ;; esac
r="$(before 'git commit -m x' "$R")"
case "$r" in "none rc=0||") check "an untracked list is not asked about by a commit alone, which cannot commit it" ok ;; *) check "an untracked list is not asked about by a commit alone, which cannot commit it" "${r:0:300}" ;; esac
spied "$EDIT_BASH"
[ -e "$SPY/python.log" ] && check "an Edit holding the words Bash and commit never starts python3" "python3 was started" || check "an Edit holding the words Bash and commit never starts python3" ok
spied "$(bash_payload PreToolUse 'gh pr view 12 --json commits' "$OK_R")"
[ -e "$SPY/python.log" ] && check "a command holding the word commit and no git never starts python3" "python3 was started" || check "a command holding the word commit and no git never starts python3" ok
# What python3 loads for a commit that passes, read from python3's own account of its imports: not
# the site module, and none of the modules only a question or a write needs.
SPY2="$WORK/spy-imports"; mkdir -p "$SPY2"
printf '#!/bin/sh\nexec "%s" -X importtime "$@" 2>>"%s"\n' "$REAL_PY" "$SPY2/imports.log" > "$SPY2/python3"; chmod +x "$SPY2/python3"
r="$(cd "$WORK" && bash_payload PreToolUse 'git commit -m x' "$OK_R" | PATH="$SPY2:$PATH" env -u CLAUDE_HOME HOME="$HOME_A" bash "$HOOK" 2>/dev/null)"
# The account names json and subprocess, which a commit check does load, so it is a real account.
if grep -q '| *json$' "$SPY2/imports.log" 2>/dev/null && grep -q '| *subprocess$' "$SPY2/imports.log" && [ -z "$r" ]; then
  loaded="$(for m in site socket hashlib datetime; do grep -q "| *$m\$" "$SPY2/imports.log" && printf '%s ' "$m"; done)"
  [ -z "$loaded" ] && check "a commit that passes loads no site, socket, hashlib or datetime module" ok || check "a commit that passes loads no site, socket, hashlib or datetime module" "loaded: $loaded"
else
  check "a commit that passes loads no site, socket, hashlib or datetime module" "the stand in recorded no json and subprocess import, or the hook spoke: ${r:0:200}"
fi
# The database call library is needed by a commit only to take a redirection out of its command,
# which only a command holding < or > can have. Without the library beside the hook a plain commit
# is still read, and one with a redirection is asked about, naming the library.
PART="$WORK/part"; mkdir -p "$PART/hooks"
cp "$HOOK" "$PART/hooks/"; cp -R "$DIR/lib" "$PART/hooks/lib"; rm -f "$PART/hooks/lib/db-write-calls.py"
R="$WORK/nolib"; new_repo "$R" nolibref0000000001
stage_line "$R" nolibref0000000001
partial() { local body rc; body="$(cd "$WORK" && bash_payload PreToolUse "$1" "$R" | env -u CLAUDE_HOME HOME="$HOME_A" bash "$PART/hooks/db-write-ask.sh" 2>/dev/null)"; rc=$?; said "$body" "$rc"; }
r="$(partial 'git commit -q -m list')"
case "$r" in "ask rc=0|"*"would commit the line nolibref0000000001"*) check "without the database call library, a plain commit is still read, and asked about by its line" ok ;; *) check "without the database call library, a plain commit is still read, and asked about by its line" "${r:0:400}" ;; esac
r="$(partial 'git commit -q -m list > /dev/null 2>&1')"
case "$r" in "ask rc=0|"*db-write-calls.py*) check "without it, a commit with a redirection is asked about, naming the library" ok ;; *) check "without it, a commit with a redirection is asked about, naming the library" "${r:0:400}" ;; esac
r="$(before 'git commit -q -m list > /dev/null 2>&1' "$R")"
case "$r" in "ask rc=0|"*"would commit the line nolibref0000000001"*) check "with it, a commit with a redirection is read as the commit it is" ok ;; *) check "with it, a commit with a redirection is read as the commit it is" "${r:0:400}" ;; esac
# And that shortcut is true of the library: text holding neither < nor > comes back from it unchanged.
IFS= read -r -d '' same_prog <<'PY' || true
import importlib.util, itertools, sys
spec = importlib.util.spec_from_file_location("calls", sys.argv[1] + "/db-write-calls.py")
calls = importlib.util.module_from_spec(spec)
spec.loader.exec_module(calls)
parts = ["git commit", " -m ", "'a b'", '"c \\" d"', " && ", " | ", "\\ ", "2", "&", " ; ", "$(x)", "`y`", "(z)", " 2 ", "#", "\\\\", "'", '"']
bad = []
for n in (1, 2, 3):
    for combo in itertools.product(parts, repeat=n):
        s = "".join(combo)
        found = []
        if calls.strip_redirects(s, found) != s or found:
            bad.append(s)
print("ok" if not bad else "changed %d of them, first: %r" % (len(bad), bad[0]))
PY
same="$(python3 -I -B -S -c "$same_prog" "$DIR/lib" </dev/null)"
check "text holding neither < nor > comes back from strip_redirects unchanged, so skipping it there loses nothing" "$same"
# The library loads without the modules only some of its paths need.
lazy="$(python3 -I -B -S - "$DIR/lib" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ap", sys.argv[1] + "/db-apply-approval.py")
ap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ap)
print(",".join(m for m in ("hashlib", "datetime") if m in sys.modules) or "none")
PY
)"
[ "$lazy" = none ] && check "the approval library loads without hashlib or datetime, which a commit check never needs" ok || check "the approval library loads without hashlib or datetime, which a commit check never needs" "loaded: $lazy"

# --- a byte that is not UTF-8 hides no Bash tool_name (claude-config#1885) ------------------------
# Under a UTF-8 locale bash's =~ stops at such a byte, so a commit whose payload held one before its
# tool_name was read as no commit at all and passed unasked. The byte rides in a field of its own
# ahead of tool_name, as a raw byte (json.dumps would escape it). Run only where this machine's
# UTF-8 locale shows the fault (L411).
if . "$DIR/lib/test_bad_byte_locale.sh" 2>/dev/null; then
  if bad_byte_measured regex "#1885 a commit payload holding a byte that is not UTF-8"; then
    R="$WORK/badbyte"; new_repo "$R" badbyteref00000001
    stage_line "$R" badbyteref00000001
    body="$(cd "$WORK" && bash_payload PreToolUse 'git commit -q -m list' "$R" s1 | LC_ALL=C sed "s/^{/{\"note\": \"x$(printf '\377')y\", /" | env -u CLAUDE_HOME LC_ALL="$(bad_byte_locale)" HOME="$HOME_A" bash "$HOOK" 2>/dev/null)"; rc=$?
    r="$(said "$body" "$rc")"
    case "$r" in "ask rc=0|"*badbyteref00000001*) check "a commit whose payload holds a byte that is not UTF-8 before its tool_name is still asked about" ok ;; *) check "a commit whose payload holds a byte that is not UTF-8 before its tool_name is still asked about" "${r:0:400}" ;; esac
  fi
else
  check "lib/test_bad_byte_locale.sh is beside this suite" "missing, so the #1885 case has no locale to run under"
fi

# --- a record key that is not ASCII is refused, never written and never raised on -----------------
# Every key is a hex digest; anything else is refused before the record is opened, and the refusal
# is returned as why, like any other failure to write it (claude-config#3058), never kept quiet.
keyed="$(env -u CLAUDE_HOME HOME="$WORK/keyhome" python3 -B - "$DIR/lib" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("ap", sys.argv[1] + "/db-apply-approval.py")
ap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ap)
try:
    why = ap._put_on_record(["abcé", "\ud800"])
except Exception as e:
    print("raised " + type(e).__name__)
    sys.exit()
rec = os.path.join(ap._record_dir(), "approved")
if os.path.exists(rec):
    print("wrote " + repr(open(rec, "rb").read()))
    sys.exit()
if not (isinstance(why, str) and "UnicodeEncodeError" in why and rec in why):
    print("the refusal was not said, naming the record and the error: " + repr(why))
    sys.exit()
why = ap._put_on_record(["0123abcd"])
if why is not None:
    print("a hex key written was said to fail: " + repr(why))
    sys.exit()
if ap._on_record() != ({"0123abcd"}, None):
    print("a hex key was not written: " + repr(open(rec, "rb").read()))
    sys.exit()
# A short write that a failure cut off leaves a fragment with no newline; the next key written
# must not fuse onto it, or it is lost while reported kept.
with open(rec, "ab") as f:
    f.write(b"4567")
why = ap._put_on_record(["89abcdef"])
held, _ = ap._on_record()
print("ok" if why is None and "89abcdef" in held else "a key written after a fragment was lost: " + repr(open(rec, "rb").read()))
PY
)"
check "a record key that is not ASCII is refused unwritten, said and not raised on, while a hex key is written" "$keyed"
# A failed save is said on the caller's list (claude-config#3058), so a call that writes the record
# and gives no list is refused before the write, never left to drop a failed save in silence.
nolist="$(env -u CLAUDE_HOME HOME="$WORK/nolisthome" python3 -B - "$DIR/lib" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("ap", sys.argv[1] + "/db-apply-approval.py")
ap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ap)
rec = os.path.join(ap._record_dir(), "approved")
try:
    ap._keep(["0123abcd"], ["someref000000000001"], None)
    print("it was not refused")
    sys.exit()
except TypeError:
    pass
if os.path.exists(rec):
    print("it wrote the record before it was refused: " + repr(open(rec, "rb").read()))
    sys.exit()
said = []
ap._keep(["0123abcd"], ["someref000000000001"], said)
print("ok" if not said and ap._on_record() == ({"0123abcd"}, None) else "with a list, a save that worked said " + repr(said))
PY
)"
check "a call that writes the record with no list for a failed save is refused before the write" "$nolist"

# --- the settings never run the hook after a tool call --------------------------------------------
wiring="$(python3 - "$SETTINGS" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
hits = [h for e in d.get("hooks", {}).get("PostToolUse", []) for h in e.get("hooks", [])
        if "db-write-ask.sh" in h.get("command", "")]
before = [h for e in d.get("hooks", {}).get("PreToolUse", []) for h in e.get("hooks", [])
          if "db-write-ask.sh" in h.get("command", "")]
print("ok" if not hits and before else "registered %d times after a tool call, %d before one" % (len(hits), len(before)))
PY
)"
check "the settings run the hook before a call and never after one: a commit having run approves nothing" "$wiring"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
