#!/usr/bin/env bash
# test-db-write-ask-approved-lines.sh: db-write-ask.sh trusts a line of a checkout's Supabase test
# project list only when a commit Dan answered yes to put it there (claude-config#3023).
#
# Before this, the hook asked about `git commit` and nothing else, so a line still reached HEAD with
# no question through a git alias for commit, git commit-tree, a merge, a cherry pick, a rebase or a
# pull, and a file run on that project then passed unasked. Enumerating git commands could never
# end that, so the list is now judged where it is used: when a database write runs, a line counts
# only if it is in HEAD and on this Mac's record of the lines a commit that passed the ask added.
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

# bash_payload <event> <command> <cwd> [session]: a Bash call as Claude Code sends it.
bash_payload() {
  python3 -c 'import json, sys
d = {"session_id": sys.argv[4], "transcript_path": sys.argv[5], "hook_event_name": sys.argv[1], "cwd": sys.argv[3],
     "tool_name": "Bash", "tool_input": {"command": sys.argv[2], "description": "d"}}
if sys.argv[1] == "PostToolUse":
    d["tool_response"] = {"stdout": "", "stderr": "", "interrupted": False}
print(json.dumps(d))' "$1" "$2" "$3" "${4:-s1}" "$NONE_T"
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
# after <command> <cwd> [session]: the hook as the settings run it once that Bash call has run.
after() {
  local body rc
  body="$(cd "$WORK" && bash_payload PostToolUse "$1" "$2" "${3:-s1}" | env -u CLAUDE_HOME HOME="${HOME_USED:-$HOME_A}" bash "$HOOK" --ran 2>/dev/null)"; rc=$?
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
# yes_commit <dir> <message word>: the staged list committed as Dan answering yes: the hook asks, the
# commit runs, and the hook is told it ran. Prints the hook's answer before the commit.
yes_commit() {
  local cmd="git commit -q -m $2" r
  r="$(before "$cmd" "$1" "${3:-s1}")"
  G "$1" commit -q -m "$2"
  after "$cmd" "$1" "${3:-s1}" >/dev/null
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

# --- the control: a line a commit Dan answered yes to added is trusted ---------------------------
OK_R="$WORK/approved"; new_repo "$OK_R" approvedref00000001
stage_line "$OK_R" approvedref00000001
r="$(yes_commit "$OK_R" list)"
case "$r" in
  "ask rc=0|"*approvedref00000001*supabase-test-projects*) check "a commit adding a line to the list is asked about, naming the line" ok ;;
  *) check "a commit adding a line to the list is asked about, naming the line" "${r:0:400}" ;;
esac
r="$(write "$OK_R")"
case "$r" in
  "allow rc=0||") check "a write on a project whose line a commit that passed the ask added passes, with nothing said" ok ;;
  *) check "a write on a project whose line a commit that passed the ask added passes, with nothing said" "${r:0:400}" ;;
esac
[ -s "$RECORD/approved" ] && check "the approved line is on this Mac's record, under its own home" ok || check "the approved line is on this Mac's record, under its own home" "no $RECORD/approved"
if grep -q approvedref00000001 "$RECORD/approved" 2>/dev/null; then
  check "the record holds a hash of the line, never the project ref itself" "the ref is written out in $RECORD/approved"
else
  check "the record holds a hash of the line, never the project ref itself" ok
fi

# The list staged and committed in one command is asked about once, by the question that names the
# line, so its yes approves it. Asked as a staging only, that yes would have approved nothing.
R="$WORK/onecommand"; new_repo "$R" onecmdref000000001
printf 'onecmdref000000001\n' >> "$R/.claude/supabase-test-projects"
ONE='git add -f .claude/supabase-test-projects && git commit -q -m list'
r="$(before "$ONE" "$R")"
case "$r" in "ask rc=0|"*"would commit the line onecmdref000000001"*) check "the list staged and committed in one command is asked about as the commit, naming the line" ok ;; *) check "the list staged and committed in one command is asked about as the commit, naming the line" "${r:0:400}" ;; esac
G "$R" add -f .claude/supabase-test-projects; G "$R" commit -q -m list
after "$ONE" "$R" >/dev/null
r="$(write "$R")"
case "$r" in "allow rc=0||") check "and a yes to it approves the line" ok ;; *) check "and a yes to it approves the line" "${r:0:400}" ;; esac
# Staged with no commit that adds a line after it, it is asked about as a staging, as before.
r="$(before 'git add -f .claude/supabase-test-projects && npm test' "$R")"
case "$r" in "ask rc=0|"*"is not one that only reads it"*) check "the list staged before a command that is no commit is still asked about" ok ;; *) check "the list staged before a command that is no commit is still asked about" "${r:0:400}" ;; esac
: > "$R/.claude/supabase-test-projects"
r="$(before "$ONE" "$R")"
case "$r" in "ask rc=0|"*"is not one that only reads it"*) check "the list staged before a commit that adds no line is still asked about" ok ;; *) check "the list staged before a commit that adds no line is still asked about" "${r:0:400}" ;; esac
r="$(before 'echo onecmdref000000001 >> .claude/supabase-test-projects && git commit -q -am list' "$R")"
case "$r" in "ask rc=0|"*"is not one that only reads it"*) check "a write of the list before a commit is asked about as the write, never put off" ok ;; *) check "a write of the list before a commit is asked about as the write, never put off" "${r:0:400}" ;; esac
G "$R" checkout -q -- .claude/supabase-test-projects

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

# A commit the hook never asked about: one made before this shipped, on the other Mac, or by a
# person at a terminal. Nothing told the hook it ran, so nothing is on the record.
R="$WORK/neverasked"; new_repo "$R" oldref000000000001
stage_line "$R" oldref000000000001; G "$R" commit -q -m "before the record existed"
unasked "a line committed with no question on record is not trusted" "$R" oldref000000000001
r="$(write "$R")"
case "$r" in
  *"take the line out"*"git commit"*) check "the question says how to get the line approved: take it out, and put it back with a git commit" ok ;;
  *) check "the question says how to get the line approved: take it out, and put it back with a git commit" "${r:0:500}" ;;
esac
# And that way out works: the line taken out in one commit, put back in another that is asked about.
: > "$R/.claude/supabase-test-projects"; G "$R" add -f .claude/supabase-test-projects
r="$(yes_commit "$R" out)"
case "$r" in "none rc=0||") check "the commit taking the line out is not asked about" ok ;; *) check "the commit taking the line out is not asked about" "${r:0:300}" ;; esac
stage_line "$R" oldref000000000001
yes_commit "$R" back >/dev/null
r="$(write "$R")"
case "$r" in "allow rc=0||") check "after the line is put back by a commit that passed the ask, the write passes" ok ;; *) check "after the line is put back by a commit that passed the ask, the write passes" "${r:0:400}" ;; esac

# Dan answered no: the hook asked, the commit never ran, and the line then arrived another way.
R="$WORK/refused"; new_repo "$R" refusedref00000001
stage_line "$R" refusedref00000001
r="$(before 'git commit -q -m list' "$R")"
case "$r" in "ask rc=0|"*) check "the commit Dan will refuse is asked about" ok ;; *) check "the commit Dan will refuse is asked about" "${r:0:300}" ;; esac
G "$R" -c alias.ci=commit ci -q -m "by an alias, after the no"
unasked "a line Dan refused, then committed through an alias, is not trusted" "$R" refusedref00000001
# The same command sent again now has nothing to add, so it is not asked about, and its running
# must not turn the earlier, refused question into an approval.
r="$(before 'git commit -q -m list' "$R")"
case "$r" in "none rc=0||") check "the same commit command with nothing left to add is not asked about" ok ;; *) check "the same commit command with nothing left to add is not asked about" "${r:0:300}" ;; esac
after 'git commit -q -m list' "$R" >/dev/null
unasked "a refused question is not turned into an approval by the same command running later" "$R" refusedref00000001

# A question in one session is not answered by a command running in another.
R="$WORK/othersession"; new_repo "$R" sessionref00000001
stage_line "$R" sessionref00000001
before 'git commit -q -m list' "$R" s1 >/dev/null
G "$R" commit -q -m list
after 'git commit -q -m list' "$R" s2 >/dev/null
unasked "a commit told as run by another session than the one asked is not an approval" "$R" sessionref00000001
# Dan said yes and the command then committed nothing (a commit hook of the repository refused it,
# say), while the line was already in HEAD by a route nobody asked about: HEAD did not move, so the
# yes approves nothing.
R="$WORK/nothingran"; new_repo "$R" stuckref0000000001
stage_line "$R" stuckref0000000001; G "$R" -c alias.ci=commit ci -q -m "by an alias"
stage_line "$R" stuckref0000000001
r="$(before 'git commit -q -m again' "$R")"
case "$r" in "ask rc=0|"*stuckref0000000001*) check "a commit adding a line a second time is asked about" ok ;; *) check "a commit adding a line a second time is asked about" "${r:0:300}" ;; esac
after 'git commit -q -m again' "$R" >/dev/null
G "$R" reset -q --hard
unasked "a yes to a commit that then committed nothing approves nothing" "$R" stuckref0000000001
# A question nobody answered is cleared once it is old, when the next one is recorded; a recent one stays.
OLD_Q="$RECORD/pending/1-1.json"; NEW_Q="$RECORD/pending/2-2.json"
printf '{"session": "long gone"}\n' > "$OLD_Q"; printf '{"session": "still open"}\n' > "$NEW_Q"
python3 -c 'import os, sys, time; t = time.time() - 8 * 24 * 3600; os.utime(sys.argv[1], (t, t))' "$OLD_Q"
R="$WORK/sweep"; new_repo "$R" sweepref0000000001
stage_line "$R" sweepref0000000001
before 'git commit -q -m list' "$R" >/dev/null
[ ! -e "$OLD_Q" ] && [ -e "$NEW_Q" ] && check "a question unanswered for over a week is cleared when another is recorded, and a recent one is kept" ok || check "a question unanswered for over a week is cleared when another is recorded, and a recent one is kept" "old one $([ -e "$OLD_Q" ] && echo kept || echo cleared), recent one $([ -e "$NEW_Q" ] && echo kept || echo cleared)"
rm -f "$NEW_Q"

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
# Only the lines the question showed are approved: a commit adding more than it names leaves the rest.
R="$WORK/many"; new_repo "$R" manyref0000000001
for i in 01 02 03 04 05 06 07 08 09 10 11 12; do printf 'manyref00000000%s\n' "$i" >> "$R/.claude/supabase-test-projects"; done
G "$R" add -f .claude/supabase-test-projects
r="$(yes_commit "$R" many)"
shown=0; for i in 01 02 03 04 05 06 07 08 09 10 11 12; do case "$r" in *"manyref00000000$i"*) shown=$((shown + 1)) ;; esac; done
case "$r" in *"and more"*) [ "$shown" -lt 12 ] && [ "$shown" -ge 1 ] && check "a commit adding more lines than the question holds says there are more" ok || check "a commit adding more lines than the question holds says there are more" "it named $shown of 12" ;; *) check "a commit adding more lines than the question holds says there are more" "${r:0:500}" ;; esac
r="$(write "$R")"
case "$r" in "allow rc=0||") check "a line the question named is approved" ok ;; *) check "a line the question named is approved" "${r:0:400}" ;; esac
printf 'manyref0000000012' > "$R/supabase/.temp/project-ref"
unasked "a line the question did not name is not approved by its answer" "$R" manyref0000000012

# --- the record itself is held like the list -----------------------------------------------------
edit_payload() { python3 -c 'import json, sys; print(json.dumps({"session_id": "s1", "hook_event_name": "PreToolUse", "tool_name": sys.argv[1], "tool_input": {"file_path": sys.argv[2], "old_string": "a", "new_string": "b", "content": "c"}}))' "$1" "$2"; }
for t in Edit Write MultiEdit; do
  body="$(cd "$WORK" && edit_payload "$t" "$RECORD/approved" | env -u CLAUDE_HOME HOME="$HOME_A" bash "$HOOK" 2>/dev/null)"; r="$(said "$body" $?)"
  case "$r" in "ask rc=0|"*approved*3023*) check "a $t of the record of approved lines is asked about" ok ;; *) check "a $t of the record of approved lines is asked about" "${r:0:300}" ;; esac
done
body="$(cd "$WORK" && edit_payload Write "$RECORD/pending/x.json" | env -u CLAUDE_HOME HOME="$HOME_A" bash "$HOOK" 2>/dev/null)"; r="$(said "$body" $?)"
case "$r" in "ask rc=0|"*) check "a Write of a question waiting on the record is asked about" ok ;; *) check "a Write of a question waiting on the record is asked about" "${r:0:300}" ;; esac
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
fi
chmod 600 "$RECORD/approved"
# The record cannot be written: the question about the commit says a yes will not be remembered.
HOME_B="$WORK/home-nowrite"; mkdir -p "$HOME_B/.claude/state"; printf 'in the way\n' > "$HOME_B/.claude/state/supabase-test-projects"
R="$WORK/nowrite"; new_repo "$R" nowriteref00000001
stage_line "$R" nowriteref00000001
r="$(HOME_USED="$HOME_B" before 'git commit -q -m list' "$R")"
case "$r" in "ask rc=0|"*nowriteref00000001*"could not record"*) check "a question that cannot be recorded says a yes will not be remembered" ok ;; *) check "a question that cannot be recorded says a yes will not be remembered" "${r:0:500}" ;; esac
G "$R" commit -q -m list; HOME_USED="$HOME_B" after 'git commit -q -m list' "$R" >/dev/null
r="$(HOME_USED="$HOME_B" write "$R")"
case "$r" in "ask rc=0|"*nowriteref00000001*) check "and the write that follows is asked about" ok ;; *) check "and the write that follows is asked about" "${r:0:400}" ;; esac
# git failing once the commit has run: no approval, and a notice says the answer was not recorded.
R="$WORK/gitgone"; new_repo "$R" gitgoneref00000001
stage_line "$R" gitgoneref00000001
before 'git commit -q -m list' "$R" >/dev/null
G "$R" commit -q -m list
GITSTUB="$WORK/gitstub"; mkdir -p "$GITSTUB"
printf '#!/bin/sh\necho "fatal: index file corrupt" >&2\nexit 3\n' > "$GITSTUB/git"; chmod +x "$GITSTUB/git"
body="$(cd "$WORK" && bash_payload PostToolUse 'git commit -q -m list' "$R" | PATH="$GITSTUB:$PATH" env -u CLAUDE_HOME HOME="$HOME_A" bash "$HOOK" --ran 2>/dev/null)"; r="$(said "$body" $?)"
case "$r" in "none rc=0||"*"could not record"*3023*) check "git failing after the commit ran is said in a notice, with no decision" ok ;; *) check "git failing after the commit ran is said in a notice, with no decision" "${r:0:400}" ;; esac
unasked "and that line is not trusted" "$R" gitgoneref00000001
# A waiting question that is not a record at all is passed over.
printf 'not json\n' > "$RECORD/pending/garbage.json"
r="$(after 'git commit -q -m list' "$R")"
case "$r" in "none rc=0||") check "a waiting question that cannot be read is passed over in silence" ok ;; *) check "a waiting question that cannot be read is passed over in silence" "${r:0:300}" ;; esac
rm -f "$RECORD/pending/garbage.json"
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
  # A question left waiting, so the hook has something to look for once the command has run.
  R="$WORK/nopy-repo"; new_repo "$R" nopyref00000000001
  stage_line "$R" nopyref00000000001
  before 'git commit -q -m list' "$R" >/dev/null
  G "$R" commit -q -m list
  r="$(nopy "$(bash_payload PostToolUse 'git commit -q -m list' "$R")" --ran)"
  case "$r" in "none rc=0||") check "with no python3, the hook after a commit records nothing and says nothing" ok ;; *) check "with no python3, the hook after a commit records nothing and says nothing" "${r:0:300}" ;; esac
  unasked "and that line is not trusted" "$R" nopyref00000000001
  rm -f "$RECORD"/pending/*.json
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
# python3 failing after a commit ran, with a question waiting: a notice says the yes was not recorded.
R="$WORK/pyfail-repo"; new_repo "$R" pyfailref000000001
stage_line "$R" pyfailref000000001
before 'git commit -q -m list' "$R" >/dev/null
G "$R" commit -q -m list
body="$(cd "$WORK" && bash_payload PostToolUse 'git commit -q -m list' "$R" | PATH="$PYFAIL:$PATH" env -u CLAUDE_HOME HOME="$HOME_A" bash "$HOOK" --ran 2>/dev/null)"; r="$(said "$body" $?)"
case "$r" in "none rc=0||"*"could not check"*python3*3023*) check "with python3 failing after a commit ran, a notice says its approval could not be checked" ok ;; *) check "with python3 failing after a commit ran, a notice says its approval could not be checked" "${r:0:400}" ;; esac
unasked "and that line is not trusted" "$R" pyfailref000000001
r="$(failing "$(bash_payload PreToolUse 'gh pr view 12 --json commits' "$OK_R")")"
case "$r" in "none rc=0||") check "with python3 failing, a command holding the word commit and no git is not asked about" ok ;; *) check "with python3 failing, a command holding the word commit and no git is not asked about" "${r:0:300}" ;; esac

# --- what a commit costs: the cuts, each held by what it does, never by a stopwatch ---------------
# python3 and git stand ins that note how they were started, then run the real one.
REAL_PY="$(command -v python3)"; REAL_GIT="$(command -v git)"
SPY="$WORK/spy"; mkdir -p "$SPY"
printf '#!/bin/sh\nprintf "%%s %%s %%s\\n" "$1" "$2" "$3" >> "%s"\nexec "%s" "$@"\n' "$SPY/python.log" "$REAL_PY" > "$SPY/python3"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\nexec "%s" "$@"\n' "$SPY/git.log" "$REAL_GIT" > "$SPY/git"
chmod +x "$SPY/python3" "$SPY/git"
spied() {  # spied <payload> [--ran]: the hook run with both stand ins first on the PATH
  rm -f "$SPY/python.log" "$SPY/git.log"
  (cd "$WORK" && printf '%s' "$1" | PATH="$SPY:$PATH" env -u CLAUDE_HOME HOME="$HOME_A" bash "$HOOK" ${2:+"$2"} >/dev/null 2>&1)
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
# After a Bash call. With a question waiting (the untracked case above left one), a call naming a
# commit starts python3 to look for its question, and a call naming none does not.
if ls "$RECORD"/pending/*.json >/dev/null 2>&1; then
  spied "$(bash_payload PostToolUse 'git commit -m unrelated' "$OK_R")" --ran
  [ -e "$SPY/python.log" ] && check "with a question waiting, the hook after a call naming a commit starts python3" ok || check "with a question waiting, the hook after a call naming a commit starts python3" "python3 was never started, so the cases below measure nothing"
  spied "$(bash_payload PostToolUse 'ls -la' "$OK_R")" --ran
  [ -e "$SPY/python.log" ] && check "with a question waiting, the hook after a call naming no commit never starts python3" "python3 was started" || check "with a question waiting, the hook after a call naming no commit never starts python3" ok
else
  check "with a question waiting, the hook after a call naming a commit starts python3" "the cases above left no question waiting, so nothing here measures it"
fi
# With none waiting, as after nearly every call, it leaves before anything else starts.
rm -f "$RECORD"/pending/*.json
spied "$(bash_payload PostToolUse 'git commit -m x' "$OK_R")" --ran
[ -e "$SPY/python.log" ] && check "after a Bash call with no question waiting, python3 never starts" "python3 was started" || check "after a Bash call with no question waiting, python3 never starts" ok
r="$(after 'git commit -m x' "$OK_R")"
case "$r" in "none rc=0||") check "after a Bash call with no question waiting, the hook says nothing" ok ;; *) check "after a Bash call with no question waiting, the hook says nothing" "${r:0:300}" ;; esac
# A payload larger than a pipe holds is still read to its end, so its writer is never cut off.
big="$(python3 -c 'import json; print(json.dumps({"session_id": "s1", "hook_event_name": "PostToolUse", "tool_name": "Bash", "tool_input": {"command": "ls"}, "tool_response": {"stdout": "x" * 400000}}))')"
printf '%s' "$big" | env -u CLAUDE_HOME HOME="$HOME_A" bash "$HOOK" --ran >/dev/null 2>&1; codes=("${PIPESTATUS[@]}")
[ "${codes[0]}" = 0 ] && [ "${codes[1]}" = 0 ] && check "with no question waiting, a large payload is read to its end before the hook leaves" ok || check "with no question waiting, a large payload is read to its end before the hook leaves" "its writer ended ${codes[0]}, the hook ${codes[1]}"
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
rm -f "$RECORD"/pending/*.json
# And that shortcut is true of the library: text holding neither < nor > comes back from it unchanged.
same="$(python3 -I -B -S - "$DIR/lib" <<'PY'
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
)"
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

# --- the settings run the hook after a Bash call, to learn that an asked commit ran --------------
wiring="$(python3 - "$SETTINGS" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1]))
hits = [(e.get("matcher", ""), h) for e in d.get("hooks", {}).get("PostToolUse", [])
        for h in e.get("hooks", []) if h.get("command", "").endswith("/hooks/db-write-ask.sh --ran")]
if len(hits) != 1:
    print("registered %d times after a tool call" % len(hits)); sys.exit()
m, h = hits[0]
bad = [] if re.fullmatch(m, "Bash") else ["matcher %s does not match Bash" % m]
bad += ["also runs after " + t for t in ("Edit", "Read", "mcp__claude_ai_Supabase__execute_sql") if re.fullmatch(m, t)]
if not isinstance(h.get("timeout"), int):
    bad.append("no timeout")
print("ok" if not bad else ", ".join(bad))
PY
)"
check "the settings run the hook after every Bash call, and after nothing else" "$wiring"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
