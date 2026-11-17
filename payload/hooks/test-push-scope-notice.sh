#!/usr/bin/env bash
# Tests for push-scope-notice.sh, which REFUSES a push every push gate would stand down on because
# it names a directory that could not be resolved (claude-config#552, refusing since #589).
#
# Since #532 the shared resolver refuses rather than judging the session repository in its place,
# and the thirteen gates that use it exit 0 on that refusal, which left the push unjudged. #552 had
# this hook only say so, as context the model received, and let the push through; since #589 it
# blocks with exit 2 and states the reason and the remedy on stderr, once, instead of thirteen
# copies from thirteen gates (L42, L320).
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/push-scope-notice.sh"
# The hooks block is settings.hooks.json in the repository and settings.json once installed, and this
# suite runs in both places, so it reads whichever sits beside the hooks. Hard coding the repo's name
# failed every pull, where the suite runs from the installed copy.
. "$DIR/lib/settings-file.sh"
SETTINGS="$(hook_settings_file "$DIR/..")"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }
says() { case "$2" in *"$3"*) check "$1" ok ;; *) check "$1" "did not say '$3': ${2:0:300}" ;; esac; }
silent() { if [ -z "$2" ]; then check "$1" ok; else check "$1" "it said: ${2:0:300}"; fi; }

[ -f "$HOOK" ] || { echo "FAIL: no hook at $HOOK"; echo "passed: 0, failed: 1"; printf 'SUITE-RESULT passed=0 failed=1\n'; exit 1; }

W="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.pushnotice.XXXXXXXX")" || W=""
case "${W%/}" in ''|/|"${HOME%/}") echo "refusing: throwaway came back as '$W'" >&2; exit 2 ;; esac
trap 'rm -rf "$W"' EXIT
git init -q "$W/session" 2>/dev/null
git init -q "$W/target" 2>/dev/null

run() { # run <command> [cwd] -> the hook's stdout; stderr kept apart in $W/err
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","hook_event_name":"PreToolUse","tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' \
    "$1" "${2:-$W/session}" | bash "$HOOK" 2>"$W/err"
}

echo "push scope notice: a push no gate can judge is refused (claude-config#589)"

# It used to only TELL the session, as additionalContext, and let the push through: a gate that
# cannot find its target and then lets the command through fails open (L42, L320). On 2026-09-29 an
# Ovation subagent pushed with a quoted -C path and no global gate checked it. Now it refuses, with
# the reason, so the push is spelled in a form the gates can read before it goes anywhere.
out="$(run "cd $W/no-such-dir && git push")"; rc=$?
err="$(cat "$W/err")"
[ "$rc" -eq 2 ] && check "a push naming a missing directory is refused" ok || check "a push naming a missing directory is refused" "exit $rc"
says "and names the directory it could not resolve" "$err" "$W/no-such-dir"
says "and says the push gates could not judge this push" "$err" "no push gate could judge this push"
says "and that it did not fall back to the session repository" "$err" "$W/session"
says "and how to push so it can be judged" "$err" "spell it absolutely"
out="$(run "git -C $W/no-such-dir push")"; rc=$?
[ "$rc" -eq 2 ] && check "a git -C naming a missing directory is refused too" ok || check "a git -C naming a missing directory is refused too" "exit $rc"
out="$(run "git -C \"\$WT\" push")"; rc=$?
[ "$rc" -eq 2 ] && check "a git -C naming a variable is refused" ok || check "a git -C naming a variable is refused" "exit $rc"
# The case from the report: a quoted worktree path holding a space RESOLVES, so it is not refused.
git init -q "$W/with space" 2>/dev/null
out="$(run "git -C \"$W/with space\" push")"; rc=$?
[ "$rc" -eq 0 ] && check "a quoted -C path with a space is resolved, not refused" ok || check "a quoted -C path with a space is resolved, not refused" "exit $rc: $(cat "$W/err")"
silent "and says nothing" "$out"

echo "push scope notice: pushes into more than one repository in one command (claude-config#1062)"

# Every push gate judges one repository per command, and used to judge the FIRST push's, so the
# second push in `cd A && git push; cd B && git push` went out with no gate having looked at it. The
# library now refuses such a command, and this hook turns that into a refusal of the push, with a
# remedy that fits: run each push on its own. "Spell the path so it resolves" would send somebody
# to fix a path that was never the problem (L11, L111).
git init -q "$W/other" 2>/dev/null
out="$(run "cd $W/target && git push; cd $W/other && git push")"; rc=$?
err="$(cat "$W/err")"
[ "$rc" -eq 2 ] && check "two pushes into two repositories in one command are refused" ok \
  || check "two pushes into two repositories in one command are refused" "exit $rc, said [$err]"
says "and names the first repository" "$err" "$W/target"
says "and names the second" "$err" "$W/other"
says "and says why: the gates judge one repository per command" "$err" "more than one repository"
says "and how to push so every push is judged" "$err" "a command of its own"
case "$err" in *"spell it absolutely"*) check "and does not tell somebody to fix a path that resolved" "it did" ;;
  *) check "and does not tell somebody to fix a path that resolved" ok ;; esac
out="$(run "git push; cd $W/other && git push")"; rc=$?
[ "$rc" -eq 2 ] && check "a push from the session repository and one from another are refused" ok \
  || check "a push from the session repository and one from another are refused" "exit $rc"

echo "push scope notice: every push a judged gate stands down on is refused here (claude-config#1122)"

# require-tests-before-push.sh and simplify-before-push.sh exit 0 when ps_repo_dir refuses with exit
# 2. The library's sentence still reaches their stderr, but Claude Code shows a hook's stderr only on
# a nonzero exit, so on exit 0 the session is told nothing, and that is right ONLY because this hook
# refuses the same push, once, for every gate. Asked of the real gates, so a gate that starts asking its own question, or this
# hook that stops refusing one of these shapes, fails here rather than letting a push out unjudged
# by both (L450). The gates' records go to a throwaway, and none of them reaches a judge.
gate() { # gate <hook> <command> [cwd, the session repository unless given] -> exit code; stderr in $W/gate.err
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","hook_event_name":"PreToolUse","tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' \
    "$2" "${3:-$W/session}" | PUSH_GATE_LEDGER_DIR="$W/ledger" bash "$DIR/$1" >/dev/null 2>"$W/gate.err"
}
for shape in "cd $W/target && git push; cd $W/other && git push" \
             "cd $W/no-such-dir && git push" \
             "git -C \"\$WT\" push"; do
  run "$shape" >/dev/null; nrc=$?
  for g in require-tests-before-push.sh simplify-before-push.sh; do
    gate "$g" "$shape"; grc=$?
    if [ "$grc" -eq 0 ]; then
      [ "$nrc" -eq 2 ] && check "#1122 $g stands down silently on [$shape], and this hook refuses it" ok \
        || check "#1122 $g stands down silently on [$shape], and this hook refuses it" "the gate said nothing and this hook exited $nrc, so the push goes out judged by neither"
    else
      check "#1122 $g stands down silently on [$shape], and this hook refuses it" "the gate exited $grc and said [$(head -c 300 "$W/gate.err")]: if it now judges or speaks here, revisit this coupling"
    fi
  done
done

echo "push scope notice: one command concluding a merge of main and pushing (claude-config#3062)"

# PreToolUse runs before the command, so in `git commit --no-edit && git push` with a merge of main
# in progress the merge commit does not exist yet. Every push gate folds the commit the command is
# about to make in as a change against HEAD, the branch's last commit, so every line main brought in
# reads as the branch's own, and ps_merged_apart, which sets a COMMITTED merge of main apart, has
# nothing to set apart. Reproduced first with the real style gate, then refused here, once.
. "$DIR/lib/merged-main-fixture.sh"
MAIN_LINE="# Old script $(printf '\342\200\224') a note main already carries"
PW="$(mmf_repo "$W/pending" pending guide/old.md "$MAIN_LINE"$'\n' src/shared.ts "the branch's own resolution line")"
mmf_pending "$PW" guide/old.md && check "#3062 the fixture leaves a merge of main in progress, main's file staged" ok \
  || check "#3062 the fixture leaves a merge of main in progress, main's file staged" "it does not, so every case below would pass for the wrong reason"
combined="git commit --no-edit && git push"
gate check-style-guide.sh "$combined" "$PW"; grc=$?
gerr="$(cat "$W/gate.err")"
case "$grc:$gerr" in
  2:*guide/old.md*) check "#3062 the fault: the style gate reads main's line as this commit's own in the combined form" ok ;;
  *) check "#3062 the fault: the style gate reads main's line as this commit's own in the combined form" "exit $grc [${gerr:0:200}]: if a gate now sets the pending merge apart, this refusal may no longer be needed" ;;
esac
out="$(run "$combined" "$PW")"; rc=$?
err="$(cat "$W/err")"
[ "$rc" -eq 2 ] && check "#3062 committing a merge of main and pushing in one command is refused" ok \
  || check "#3062 committing a merge of main and pushing in one command is refused" "exit $rc [${err:0:200}]"
says "#3062 and names the branch whose merge is in progress" "$err" "origin/main"
says "#3062 and says another gate's finding may already be on it" "$err" "do not edit"
says "#3062 and says how to push so the gates can tell the lines apart" "$err" "as a command of its own, then push"
out="$(run "git add src/shared.ts && git commit --no-edit && git push" "$PW")"; rc=$?
[ "$rc" -eq 2 ] && check "#3062 an add before the commit changes nothing" ok || check "#3062 an add before the commit changes nothing" "exit $rc"
out="$(run "cd $PW && git commit -m merged && git push origin HEAD" "$W/session")"; rc=$?
[ "$rc" -eq 2 ] && check "#3062 nor does a cd into the repository" ok || check "#3062 nor does a cd into the repository" "exit $rc"
# git merge --continue concludes the same merge and makes the same commit, so it is the same command
# (claude-config#3081). It used to be read as no commit at all: this hook let it through and no gate
# folded the pending merge commit in, so the whole commit, a conflict resolution included, went out
# with no gate having read it.
for c in "git merge --continue && git push" "GIT_EDITOR=true git merge --continue && git push" \
         "git -c core.editor=true merge --continue; git push"; do
  out="$(run "$c" "$PW")"; rc=$?
  err="$(cat "$W/err")"
  [ "$rc" -eq 2 ] && check "#3081 concluding a merge of main and pushing in one command is refused: $c" ok \
    || check "#3081 concluding a merge of main and pushing in one command is refused: $c" "exit $rc [${err:0:200}]"
done
says "#3081 and names the branch whose merge is in progress" "$err" "origin/main"
says "#3081 and names git merge --continue among what to run on its own first" "$err" "git merge --continue"
says "#3081 and still says how to push so the gates can tell the lines apart" "$err" "as a command of its own, then push"
out="$(run "cd $PW && git merge --continue && git push origin HEAD" "$W/session")"; rc=$?
[ "$rc" -eq 2 ] && check "#3081 and so it is behind a cd into the repository" ok || check "#3081 and so it is behind a cd into the repository" "exit $rc"
# The same commit written straight after a subshell or substitution opener is the same command
# (claude-config#3091). The library read it as no commit, so this hook let it through.
for c in "(git commit --no-edit) && git push" "(git merge --continue) && git push" \
         "x=\$(git commit --no-edit) && git push"; do
  out="$(run "$c" "$PW")"; rc=$?
  err="$(cat "$W/err")"
  [ "$rc" -eq 2 ] && check "#3091 concluding a merge of main inside brackets and pushing is refused: $c" ok \
    || check "#3091 concluding a merge of main inside brackets and pushing is refused: $c" "exit $rc [${err:0:200}]"
  says "#3091 and it is the merge in progress it is refused for: $c" "$err" "concludes a merge of origin/main"
done
pending_allowed() { # pending_allowed <description> <command> <cwd>
  local out rc
  out="$(run "$2" "$3")"; rc=$?
  if [ "$rc" -eq 0 ] && [ -z "$out" ] && [ ! -s "$W/err" ]; then check "$1" ok
  else check "$1" "exit $rc, stdout [${out:0:200}], stderr [$(head -c 200 "$W/err")]"; fi
}
# A push alone does not carry the pending merge, only what is already committed.
pending_allowed "#3062 a push alone while the merge is in progress is let through" "git push" "$PW"
pending_allowed "#3062 a commit with no push is not this hook's" "git commit --no-edit" "$PW"
pending_allowed "#3081 nor is concluding the merge with no push" "git merge --continue" "$PW"
pending_allowed "#3081 abandoning the merge and pushing is let through" "git merge --abort && git push" "$PW"
# Once the merge is committed, the push is the one ps_merged_apart sets apart, so it goes.
git -C "$PW" -c user.name=t -c user.email=t@t.t -c commit.gpgsign=false commit -q --no-edit >/dev/null 2>&1
pending_allowed "#3062 once the merge is committed, a push is let through" "git push" "$PW"
pending_allowed "#3062 and so is a later commit and push in one command" "git commit -am more && git push" "$PW"
# A merge of a branch that brings nothing new from main: every line it carries is the push's own and
# was never judged, and the combined form already reads it so.
git -C "$PW" checkout -qb side >/dev/null 2>&1
printf 'side work\n' > "$PW/notes/side.txt"
git -C "$PW" add notes/side.txt >/dev/null 2>&1
git -C "$PW" -c user.name=t -c user.email=t@t.t -c commit.gpgsign=false commit -qm side >/dev/null 2>&1
git -C "$PW" checkout -q feat >/dev/null 2>&1
git -C "$PW" -c user.name=t -c user.email=t@t.t merge -q --no-commit --no-ff side >/dev/null 2>&1
git -C "$PW" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 \
  && pending_allowed "#3062 a pending merge of another branch, committed and pushed in one command, is let through" "$combined" "$PW" \
  || check "#3062 a pending merge of another branch, committed and pushed in one command, is let through" "the side merge was not left in progress"
# The same merge concluded by git merge --continue is let through here too, and the gates must read
# the commit it is about to make (claude-config#3081). A line staged by hand for the merge commit, as
# a conflict resolution is, is the push's own. Asked of the real style gate: first with the commit
# form, the control showing the line is one it refuses, then with git merge --continue, where it used
# to say nothing because it saw no commit in the command.
continued="git merge --continue && git push"
pending_allowed "#3081 a pending merge of another branch, concluded by git merge --continue and pushed, is let through" "$continued" "$PW"
printf '%s\n' "$MAIN_LINE" > "$PW/notes/resolution.md"
git -C "$PW" add notes/resolution.md >/dev/null 2>&1
gate check-style-guide.sh "$combined" "$PW"; grc=$?
gerr="$(cat "$W/gate.err")"
case "$grc:$gerr" in
  2:*notes/resolution.md*) check "#3081 control: the style gate refuses a line staged for the merge commit, in the commit form" ok ;;
  *) check "#3081 control: the style gate refuses a line staged for the merge commit, in the commit form" "exit $grc [${gerr:0:200}], so the case below proves nothing" ;;
esac
gate check-style-guide.sh "$continued" "$PW"; grc=$?
gerr="$(cat "$W/gate.err")"
case "$grc:$gerr" in
  2:*notes/resolution.md*) check "#3081 the style gate reads the commit git merge --continue is about to make" ok ;;
  *) check "#3081 the style gate reads the commit git merge --continue is about to make" "exit $grc [${gerr:0:200}]: the line staged for the merge commit went out unread" ;;
esac
# And so it does when either is written inside brackets (claude-config#3091), where it saw no commit.
for c in "(git commit --no-edit) && git push" "(git merge --continue) && git push" \
         "x=\$(git commit --no-edit) && git push"; do
  pending_allowed "#3091 a pending merge of another branch, concluded inside brackets and pushed, is let through: $c" "$c" "$PW"
  gate check-style-guide.sh "$c" "$PW"; grc=$?
  gerr="$(cat "$W/gate.err")"
  case "$grc:$gerr" in
    2:*notes/resolution.md*) check "#3091 the style gate reads the commit made inside brackets: $c" ok ;;
    *) check "#3091 the style gate reads the commit made inside brackets: $c" "exit $grc [${gerr:0:200}]: the line staged for the commit went out unread" ;;
  esac
done
git -C "$PW" merge --abort >/dev/null 2>&1
rm -f "$PW/notes/resolution.md"
# Read into a variable and cut there, never piped into head, which can end the producer early and
# fail the pipeline under pipefail (L183).
left="$(git -C "$PW" status --porcelain 2>/dev/null)"
[ -z "$left" ] && check "#3081 the side merge is put away clean before the next case" ok \
  || check "#3081 the side merge is put away clean before the next case" "left [${left:0:200}]"
# A merge of main left in progress with no conflict at all is the same case: the commit is what is
# missing, not a conflict.
git -C "$PW" checkout -q main >/dev/null 2>&1
printf 'more from main\n' > "$PW/main-more.txt"
git -C "$PW" add main-more.txt >/dev/null 2>&1
git -C "$PW" -c user.name=t -c user.email=t@t.t -c commit.gpgsign=false commit -qm "main again" >/dev/null 2>&1
git -C "$PW" push -q origin main >/dev/null 2>&1
git -C "$PW" checkout -q feat >/dev/null 2>&1
git -C "$PW" -c user.name=t -c user.email=t@t.t merge -q --no-commit --no-ff origin/main >/dev/null 2>&1
out="$(run "$combined" "$PW")"; rc=$?
[ "$rc" -eq 2 ] && check "#3062 a clean merge of main left uncommitted, committed and pushed in one command, is refused" ok \
  || check "#3062 a clean merge of main left uncommitted, committed and pushed in one command, is refused" "exit $rc"

echo "push scope notice: commits made by another route and pushed in one command (claude-config#3092)"

# A git rebase, cherry-pick, revert, am, merge of a named branch or pull puts commits on the branch
# that do not exist when PreToolUse runs, and no gate knows the command makes any: each reads the
# range as it stands and says nothing of what the command is about to add to it. Reproduced first
# with the real style gate on a line a cherry-pick is about to bring in, then refused here, once,
# for every gate, with the same remedy as the pending merge: the same work as two commands.
PR="$(mmf_repo "$W/routes" clean guide/new.md $'from main\n')"
mmf_built "$PR" guide/new.md && check "#3092 the fixture is a branch with main merged in and committed" ok \
  || check "#3092 the fixture is a branch with main merged in and committed" "it is not, so every case below would pass for the wrong reason"
git -C "$PR" checkout -qb side >/dev/null 2>&1
printf '%s\n' "$MAIN_LINE" > "$PR/notes/side.md"
git -C "$PR" add notes/side.md >/dev/null 2>&1
git -C "$PR" -c user.name=t -c user.email=t@t.t -c commit.gpgsign=false commit -qm side >/dev/null 2>&1
git -C "$PR" checkout -q feat >/dev/null 2>&1
picked="git cherry-pick side && git push"
gate check-style-guide.sh "$picked" "$PR"; grc=$?
gerr="$(cat "$W/gate.err")"
case "$grc:$gerr" in
  0:*) check "#3092 the fault: the style gate says nothing of the line a cherry-pick is about to commit and push" ok ;;
  *) check "#3092 the fault: the style gate says nothing of the line a cherry-pick is about to commit and push" "exit $grc [${gerr:0:200}]: if a gate now reads what a cherry-pick will make, this refusal may no longer be needed" ;;
esac
out="$(run "$picked" "$PR")"; rc=$?
err="$(cat "$W/err")"
[ "$rc" -eq 2 ] && check "#3092 a cherry-pick and a push in one command is refused" ok \
  || check "#3092 a cherry-pick and a push in one command is refused" "exit $rc [${err:0:200}]"
says "#3092 and names what the command runs before the push" "$err" "git cherry-pick"
says "#3092 and says no gate can read what it makes" "$err" "does not exist yet when the push gates run"
says "#3092 and says how to push so the gates can read it" "$err" "as a command of its own, then push"
says "#3092 and names the issue" "$err" "claude-config#3092"
case "$err" in *"concludes a merge"*) check "#3092 and does not call it a merge in progress" "it did: ${err:0:200}" ;;
  *) check "#3092 and does not call it a merge in progress" ok ;; esac
# Each route the issue names, and its neighbours measured to make commits the same way. The refusal
# names the route as written, so somebody knows which command to run first.
while IFS='|' read -r c want; do
  [ -n "$c" ] || continue
  out="$(run "$c" "$PR")"; rc=$?
  err="$(cat "$W/err")"
  case "$rc:$err" in
    2:*"this command runs $want before it pushes"*) check "#3092 refused, naming $want: $c" ok ;;
    *) check "#3092 refused, naming $want: $c" "exit $rc [${err:0:200}]" ;;
  esac
done <<'ROUTES'
git rebase --continue && git push --force-with-lease|git rebase --continue
git cherry-pick --continue && git push|git cherry-pick --continue
git revert --continue && git push|git revert --continue
git am --continue && git push|git am --continue
git merge --no-edit side && git push|git merge
git cherry-pick side && git push origin HEAD|git cherry-pick
git pull --no-edit && git push|git pull
git pull --rebase && git push|git pull
git rebase origin/main && git push -f|git rebase
git revert --no-edit HEAD && git push|git revert
git am fix.patch && git push|git am
git rebase --skip; git push -f|git rebase --skip
git merge --squash side && git commit -m squashed && git push|git merge
GIT_EDITOR=true git rebase --continue && git push|git rebase --continue
(git pull) && git push|git pull
ROUTES
out="$(run "cd $PR && git pull && git push origin HEAD" "$W/session")"; rc=$?
[ "$rc" -eq 2 ] && check "#3092 and so it is behind a cd into the repository" ok || check "#3092 and so it is behind a cd into the repository" "exit $rc"
# What makes nothing, what nothing pushes afterwards, and words that only name a route, are let
# through with nothing said.
pending_allowed "#3092 leaving a cherry-pick where it stands and pushing is let through" "git cherry-pick --quit; git push" "$PR"
# An abandoned rebase was let through here until #3098: it makes no commit, which was all #3092
# asked. But it puts HEAD back on the branch, off whatever the rebase had it on when the gates ran
# (measured: the push then sends a commit that was not on HEAD), so it is refused as a move.
out="$(run "git rebase --abort && git push" "$PR")"; rc=$?
err="$(cat "$W/err")"
case "$rc:$err" in
  2:*"this command runs git rebase --abort before it pushes"*"claude-config#3098"*) check "#3098 abandoning a rebase and pushing is refused, as a move of the branch" ok ;;
  *) check "#3098 abandoning a rebase and pushing is refused, as a move of the branch" "exit $rc [${err:0:200}]" ;;
esac
pending_allowed "#3092 a pull after the push is not carried by it" "git push && git pull" "$PR"
pending_allowed "#3092 a route with no push is not this hook's" "git rebase --continue" "$PR"
pending_allowed "#3092 a commit message that names a route runs none" "git commit -m 'run git pull, then git rebase --continue' && git push" "$PR"
pending_allowed "#3092 a fetch before the push is no route" "git fetch origin && git push" "$PR"
# The remedy works (L111): the cherry-pick run as a command of its own, the push is let through here
# and the style gate now reads the line it brought in.
git -C "$PR" -c user.name=t -c user.email=t@t.t -c commit.gpgsign=false cherry-pick side >/dev/null 2>&1
pending_allowed "#3092 the cherry-pick run on its own first, the push alone is let through" "git push" "$PR"
gate check-style-guide.sh "git push" "$PR"; grc=$?
gerr="$(cat "$W/gate.err")"
case "$grc:$gerr" in
  2:*notes/side.md*) check "#3092 and the style gate then reads the line the cherry-pick brought in" ok ;;
  *) check "#3092 and the style gate then reads the line the cherry-pick brought in" "exit $grc [${gerr:0:200}], so the two command form would not be judged either" ;;
esac

echo "push scope notice: a branch moved, or a commit staged by another route, then pushed (claude-config#3098)"

# Two more ways one command changes what its push sends after the gates have read it, neither of
# which makes a commit by a route #3092 names. A git checkout, switch or reset MOVES the branch onto
# commits that already exist, so the push sends a range no gate read. And a command can change the
# INDEX by a route other than git add (a path taken from another commit, a stash put back, a patch
# applied with --index, a git rm) and then commit: the gates fold the pending commit in from the
# index as it was before the command ran. Each is reproduced first with the real style gate, then
# refused here, once, for every gate, with the same remedy: the same work as two commands.
PM="$(mmf_repo "$W/moves" clean guide/new.md $'from main\n')"
mmf_built "$PM" guide/new.md && check "#3098 the fixture is a branch with main merged in and committed" ok \
  || check "#3098 the fixture is a branch with main merged in and committed" "it is not, so every case below would pass for the wrong reason"
git -C "$PM" checkout -qb other >/dev/null 2>&1
printf '%s\n' "$MAIN_LINE" > "$PM/notes/other.md"
git -C "$PM" add notes/other.md >/dev/null 2>&1
git -C "$PM" -c user.name=t -c user.email=t@t.t -c commit.gpgsign=false commit -qm other >/dev/null 2>&1
git -C "$PM" checkout -q feat >/dev/null 2>&1
[ "$(git -C "$PM" branch --show-current 2>/dev/null)" = feat ] && [ ! -e "$PM/notes/other.md" ] \
  && git -C "$PM" cat-file -e other:notes/other.md 2>/dev/null \
  && check "#3098 the fixture is on feat, and only the branch other holds the line the style gate refuses" ok \
  || check "#3098 the fixture is on feat, and only the branch other holds the line the style gate refuses" "it is not, so the faults below would be shown on the wrong state"
moved="git checkout other && git push -u origin other"
gate check-style-guide.sh "$moved" "$PM"; grc=$?
gerr="$(cat "$W/gate.err")"
case "$grc:$gerr" in
  0:*) check "#3098 the fault: the style gate says nothing of a line on the branch the command switches to and pushes" ok ;;
  *) check "#3098 the fault: the style gate says nothing of a line on the branch the command switches to and pushes" "exit $grc [${gerr:0:200}]: if a gate now reads the branch a checkout will land on, this refusal may no longer be needed" ;;
esac
out="$(run "$moved" "$PM")"; rc=$?
err="$(cat "$W/err")"
[ "$rc" -eq 2 ] && check "#3098 a checkout of another branch and a push in one command is refused" ok \
  || check "#3098 a checkout of another branch and a push in one command is refused" "exit $rc [${err:0:200}]"
says "#3098 and names what the command runs before the push" "$err" "this command runs git checkout before it pushes"
says "#3098 and says the branch may not be the one the gates read" "$err" "is not what the push gates read"
says "#3098 and says how to push so the gates can read it" "$err" "as a command of its own, then push"
says "#3098 and names the issue" "$err" "claude-config#3098"
taken="git checkout other -- notes/other.md && git commit -m take && git push"
gate check-style-guide.sh "$taken" "$PM"; grc=$?
gerr="$(cat "$W/gate.err")"
case "$grc:$gerr" in
  0:*) check "#3098 the fault: the style gate says nothing of a line the command takes from another commit, commits and pushes" ok ;;
  *) check "#3098 the fault: the style gate says nothing of a line the command takes from another commit, commits and pushes" "exit $grc [${gerr:0:200}]: if a gate now reads what such a checkout will stage, this refusal may no longer be needed" ;;
esac
out="$(run "$taken" "$PM")"; rc=$?
err="$(cat "$W/err")"
[ "$rc" -eq 2 ] && check "#3098 a path taken from another commit, committed and pushed in one command is refused" ok \
  || check "#3098 a path taken from another commit, committed and pushed in one command is refused" "exit $rc [${err:0:200}]"
says "#3098 and names what the command runs before the commit" "$err" "this command runs git checkout, then commits and pushes"
says "#3098 and says the index is not the one the gates read" "$err" "is not in the index when the push gates run"
says "#3098 and says how to commit so the gates can read it" "$err" "as a command of its own, then commit and push"
says "#3098 and names the issue there too" "$err" "claude-config#3098"
# Each spelling measured to move the branch or change the index. The refusal names the route as
# written, so somebody knows which command to run first.
while IFS='|' read -r c kind want; do
  [ -n "$c" ] || continue
  out="$(run "$c" "$PM")"; rc=$?
  err="$(cat "$W/err")"
  case "$kind" in
    move) phrase="this command runs $want before it pushes" ;;
    *) phrase="this command runs $want, then commits and pushes" ;;
  esac
  case "$rc:$err" in
    2:*"$phrase"*"claude-config#3098"*) check "#3098 refused, naming $want: $c" ok ;;
    *) check "#3098 refused, naming $want: $c" "exit $rc [${err:0:200}]" ;;
  esac
done <<'ROUTES'
git switch other && git push|move|git switch
git reset --hard other && git push -f|move|git reset
git checkout -b new origin/main && git push -u origin new|move|git checkout
git rebase --abort && git push|move|git rebase --abort
git cherry-pick --abort; git push|move|git cherry-pick --abort
git update-ref refs/heads/feat other && git push|move|git update-ref
git stash branch fromstash && git push -u origin fromstash|move|git stash branch
(git checkout other) && git push|move|git checkout
git stash pop && git commit -am take && git push|stage|git stash pop
git apply --index fix.patch && git commit -m take && git push|stage|git apply
git rm notes/feat.txt && git commit -m gone && git push|stage|git rm
git mv notes/feat.txt notes/kept.txt && git commit -m moved && git push|stage|git mv
git restore --staged notes/feat.txt && git commit -m less && git push|stage|git restore
git reset && git commit --allow-empty -m none && git push|stage|git reset
git merge --abort && git commit --allow-empty -m none && git push|stage|git merge --abort
ROUTES
out="$(run "cd $PM && git checkout other && git push origin HEAD" "$W/session")"; rc=$?
[ "$rc" -eq 2 ] && check "#3098 and so it is behind a cd into the repository" ok || check "#3098 and so it is behind a cd into the repository" "exit $rc"
# What was measured to change neither HEAD nor the index, a staging route nothing commits, what
# nothing pushes afterwards, and words that only name a route, are let through with nothing said.
pending_allowed "#3098 a branch made where HEAD already is, then pushed, is let through" "git checkout -b new && git push -u origin new" "$PM"
pending_allowed "#3098 so is one made with git switch, committed to and pushed" "git switch -c new && git add notes && git commit -m more && git push -u origin new" "$PM"
pending_allowed "#3098 files written back from the index are no route" "git checkout -- notes/feat.txt && git push" "$PM"
pending_allowed "#3098 a stash put back with no commit after it changes nothing the push sends" "git stash pop && git push" "$PM"
pending_allowed "#3098 a stash only listed is no route" "git stash list && git commit --allow-empty -m none && git push" "$PM"
pending_allowed "#3098 a checkout after the push is not carried by it" "git push && git checkout main" "$PM"
pending_allowed "#3098 a commit message that names a route runs none" "git commit --allow-empty -m 'git checkout main, then git reset --hard' && git push" "$PM"
# The remedy works (L111). The checkout run as a command of its own, the push is let through here
# and the style gate reads the line on the branch it landed on.
git -C "$PM" checkout -q other >/dev/null 2>&1
pending_allowed "#3098 the checkout run on its own first, the push alone is let through" "git push -u origin other" "$PM"
gate check-style-guide.sh "git push -u origin other" "$PM"; grc=$?
gerr="$(cat "$W/gate.err")"
case "$grc:$gerr" in
  2:*notes/other.md*) check "#3098 and the style gate then reads the line on the branch the checkout landed on" ok ;;
  *) check "#3098 and the style gate then reads the line on the branch the checkout landed on" "exit $grc [${gerr:0:200}], so the two command form would not be judged either" ;;
esac
# And the path taken from another commit as a command of its own, the commit and push in one command
# are let through here and the style gate reads the line now in the index.
git -C "$PM" checkout -q feat >/dev/null 2>&1
git -C "$PM" checkout -q other -- notes/other.md >/dev/null 2>&1
pending_allowed "#3098 the path taken on its own first, the commit and push are let through" "git commit -m take && git push" "$PM"
gate check-style-guide.sh "git commit -m take && git push" "$PM"; grc=$?
gerr="$(cat "$W/gate.err")"
case "$grc:$gerr" in
  2:*notes/other.md*) check "#3098 and the style gate then reads the line the checkout staged" ok ;;
  *) check "#3098 and the style gate then reads the line the checkout staged" "exit $grc [${gerr:0:200}], so the two command form would not be judged either" ;;
esac
# A route question that cannot be asked is not one answered no (L1033, claude-config#1900). The hook
# read every exit but 0 as nothing to refuse, so beside a library that lacks one of the two
# questions (an older library under a newer hook) it let the command through with nothing said.
# Asked of a copy of the hook whose library has the question renamed away; the copy with the
# library whole is the control, so the refusal is the missing question's and not the copy's.
copy_hook() { # copy_hook <folder> [<the library function to take away>] -> the hook and lib/ copied there
  mkdir -p "$1" && cp "$HOOK" "$1/push-scope-notice.sh" && cp -R "$DIR/lib" "$1/lib" || return 1
  [ -n "${2:-}" ] || return 0
  sed "s/^$2() {/${2}_taken_away() {/" "$DIR/lib/push-scope.sh" > "$1/lib/push-scope.sh"
}
run_copy() { # run_copy <folder> <command> <cwd> -> the copied hook's exit code; stderr in $W/err
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","hook_event_name":"PreToolUse","tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' \
    "$2" "$3" | bash "$1/push-scope-notice.sh" >/dev/null 2>"$W/err"
}
git -C "$PM" reset -q --hard >/dev/null 2>&1
copy_hook "$W/whole" && run_copy "$W/whole" "git push" "$PM"; rc=$?
[ "$rc" -eq 0 ] && [ ! -s "$W/err" ] && check "#3098 control: a copy of the hook with its library whole lets a push through" ok \
  || check "#3098 control: a copy of the hook with its library whole lets a push through" "exit $rc [$(head -c 200 "$W/err")], so the cases below would be refused for the copy's sake"
for q in ps_unread_move_or_stage ps_unread_commit_route; do
  copy_hook "$W/without-$q" "$q"
  if grep -q "^$q() {" "$W/without-$q/lib/push-scope.sh" 2>/dev/null || [ ! -s "$W/without-$q/lib/push-scope.sh" ]; then
    check "#3098 the copied library has $q taken away" "it does not, so the case below proves nothing"
  else check "#3098 the copied library has $q taken away" ok; fi
  # The command each question would have answered for, so nothing else refuses it first.
  case "$q" in ps_unread_commit_route) c="git pull && git push" ;; *) c="git checkout other && git push" ;; esac
  run_copy "$W/without-$q" "$c" "$PM"; rc=$?
  err="$(cat "$W/err")"
  case "$rc:$err" in
    2:*"could not ask"*"$q"*) check "#3098 beside a library that lacks $q the push is refused, naming the question" ok ;;
    *) check "#3098 beside a library that lacks $q the push is refused, naming the question" "exit $rc [${err:0:200}]" ;;
  esac
  run_copy "$W/without-$q" "git status" "$PM"; rc=$?
  [ "$rc" -eq 0 ] && [ ! -s "$W/err" ] && check "#3098 and a command that does not push is still let through there ($q)" ok \
    || check "#3098 and a command that does not push is still let through there ($q)" "exit $rc [$(head -c 200 "$W/err")]"
done

echo "push scope notice: silent where there is nothing to announce"

# Since #589 the hook refuses with exit 2 and speaks on STDERR, so "silent" means all three: exit 0,
# nothing on stdout, nothing on stderr. Checking stdout alone could not see a wrong refusal.
allowed() { # allowed <description> <command>
  local out rc
  out="$(run "$2")"; rc=$?
  if [ "$rc" -eq 0 ] && [ -z "$out" ] && [ ! -s "$W/err" ]; then check "$1" ok
  else check "$1" "exit $rc, stdout [${out:0:200}], stderr [$(head -c 200 "$W/err")]"; fi
}
allowed "a push the gates can resolve is let through, saying nothing" "cd $W/target && git push"
allowed "a plain push from the session repository is let through, saying nothing" "git push"
allowed "two pushes into the same repository are let through, saying nothing" "cd $W/target && git push; cd $W/target && git push origin HEAD:x"
allowed "a command that is not a push is let through, saying nothing" "cd $W/no-such-dir && git status"
allowed "a push quoted inside an argument is let through, saying nothing" "gh issue create --body \"cd $W/no-such-dir && git push\""

echo "push scope notice: a push whose repository's hooks folder is missing is refused (claude-config#2070)"

# A core.hooksPath naming a folder that does not exist makes git skip every local hook and say
# nothing: the push below exits 0 with no pre-push run. Bidspoke sets it to .husky/_, which only
# `pnpm install` creates, so a worktree that never ran the install pushed a live migration on
# 2026-11-02 with no SQL suite, test gate or style gate (Bidspoke PR #3199).
agent_run() { # agent_run <command> [cwd]: the same payload as run, carrying a subagent's id
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","hook_event_name":"PreToolUse","tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2],"agent_id":"a1b2c3d4"}))' \
    "$1" "${2:-$W/session}" | bash "$HOOK" 2>"$W/err"
}
refused_for_hooks() { # refused_for_hooks <description> <command> [cwd]
  local out rc
  out="$(run "$2" "${3:-$W/session}")"; rc=$?
  if [ "$rc" -eq 2 ]; then check "$1" ok; else check "$1" "exit $rc, stderr [$(head -c 300 "$W/err")]"; fi
}
# git names the top level by its real path, symlinks resolved (/var is /private/var on a Mac).
WR="$(cd "$W" && pwd -P)"
git init -q "$W/hooked" 2>/dev/null
git -C "$W/hooked" commit -q --allow-empty -m one 2>/dev/null
git -C "$W/hooked" config core.hooksPath .husky/_
: > "$W/hooked/pnpm-lock.yaml"
refused_for_hooks "a push whose relative hooksPath names a missing folder is refused" "cd $W/hooked && git push"
err="$(cat "$W/err")"
says "and says the repository's own hooks would not run" "$err" "hooks folder"
says "and names the folder git would look in" "$err" "$WR/hooked/.husky/_"
says "and names the install that creates it, read from the lockfile" "$err" "pnpm install"
says "and names the checkout to run it in" "$err" "in $WR/hooked,"
says "and gives the one command override" "$err" "SKIP_HOOKS_PATH_CHECK=1"
case "$err" in *"spell it absolutely"*|*"more than one repository"*) check "and gives only this cause's remedy" "it gave another's: ${err:0:200}" ;;
  *) check "and gives only this cause's remedy" ok ;; esac
refused_for_hooks "a git -C push into that repository is refused too" "git -C $W/hooked push"
refused_for_hooks "a plain push with the session in that repository is refused too" "git push" "$W/hooked"
mkdir -p "$W/hooked/sub"
refused_for_hooks "and from below its top level" "git push" "$W/hooked/sub"

# The Bidspoke shape: the folder is untracked, made by an install in the main checkout, so the main
# checkout pushes with its hooks and a linked worktree made from it has none.
mkdir -p "$W/hooked/.husky/_"
allowed "the same push once the folder exists is let through, saying nothing" "cd $W/hooked && git push"
git -C "$W/hooked" worktree add -q "$W/hooked-wt" 2>/dev/null
refused_for_hooks "a linked worktree that never ran the install is refused" "cd $W/hooked-wt && git push"
says "and names the worktree's own folder, not the main checkout's" "$(cat "$W/err")" "$WR/hooked-wt/.husky/_"
allowed "while the main checkout's push is let through" "cd $W/hooked && git push"

git init -q "$W/abs" 2>/dev/null
git -C "$W/abs" config core.hooksPath "$W/abs-hooks-gone"
refused_for_hooks "an absolute hooksPath naming a missing folder is refused" "cd $W/abs && git push"
says "and with no lockfile names the step generally, not a made up command" "$(cat "$W/err")" "the repository's install"
ln -s "$W/nowhere" "$W/abs-hooks-gone"
refused_for_hooks "a hooksPath that is a dangling symlink is refused" "cd $W/abs && git push"
rm -f "$W/abs-hooks-gone"
git -C "$W/abs" config core.hooksPath /dev/null
allowed "a hooksPath naming something that exists but is no folder (hooks switched off on purpose) is let through" "cd $W/abs && git push"

git -C "$W/abs" config core.hooksPath "$W/abs-hooks-gone"
allowed "the main session's SKIP_HOOKS_PATH_CHECK=1 lets that one push through, saying nothing" "cd $W/abs && SKIP_HOOKS_PATH_CHECK=1 git push"
out="$(agent_run "cd $W/abs && SKIP_HOOKS_PATH_CHECK=1 git push")"; rc=$?
[ "$rc" -eq 2 ] && check "an agent's SKIP_HOOKS_PATH_CHECK=1 is refused, as every agent skip of the hooks is (#1666)" ok \
  || check "an agent's SKIP_HOOKS_PATH_CHECK=1 is refused, as every agent skip of the hooks is (#1666)" "exit $rc"
says "and says the override is not an agent's to use" "$(cat "$W/err")" "not available to an agent"
out="$(agent_run "cd $W/abs && git push")"; rc=$?
[ "$rc" -eq 2 ] && check "an agent's push is refused the same way" ok || check "an agent's push is refused the same way" "exit $rc"

# For an AGENT, a hooks location that exists but holds no hook git would run is not hooks switched
# off on purpose: an agent may have set it itself, by a config write or an edit of the config file
# (claude-config#2135). /dev/null, an empty folder and a folder of samples alike. The main session's
# push is unchanged, since a person's deliberate setting is theirs.
agent_refused_for_hooks() { # agent_refused_for_hooks <description> <command>
  local out rc
  out="$(agent_run "$2")"; rc=$?
  if [ "$rc" -eq 2 ]; then check "$1" ok; else check "$1" "exit $rc, stderr [$(head -c 300 "$W/err")]"; fi
}
agent_allowed() { # agent_allowed <description> <command>
  local out rc
  out="$(agent_run "$2")"; rc=$?
  if [ "$rc" -eq 0 ]; then check "$1" ok; else check "$1" "exit $rc, stderr [$(head -c 300 "$W/err")]"; fi
}
git -C "$W/abs" config core.hooksPath /dev/null
agent_refused_for_hooks "#2135 an agent's push with hooksPath /dev/null is refused" "cd $W/abs && git push"
err="$(cat "$W/err")"
says "#2135 and names the issue" "$err" "claude-config#2135"
says "#2135 and names the setting" "$err" "/dev/null"
says "#2135 and says to hand back" "$err" "hand back"
allowed "#2135 while the main session's push with hooksPath /dev/null is still let through" "cd $W/abs && git push"
mkdir -p "$W/abs-empty"
git -C "$W/abs" config core.hooksPath "$W/abs-empty"
agent_refused_for_hooks "#2135 an agent's push with hooksPath an empty folder is refused" "cd $W/abs && git push"
allowed "#2135 while the main session's push with an empty hooks folder is still let through" "cd $W/abs && git push"
printf '#!/bin/sh\nexit 0\n' > "$W/abs-empty/pre-push.sample"; chmod +x "$W/abs-empty/pre-push.sample"
printf 'notes\n' > "$W/abs-empty/README"
agent_refused_for_hooks "#2135 an agent's push with a folder of samples and notes only is refused" "cd $W/abs && git push"
printf '#!/bin/sh\nexit 0\n' > "$W/abs-empty/pre-push"
agent_refused_for_hooks "#2135 a hook git would not run, since it is not executable, is not a hook" "cd $W/abs && git push"
chmod +x "$W/abs-empty/pre-push"
agent_allowed "#2135 an agent's push with a folder holding an executable pre-push goes through" "cd $W/abs && git push"
rm -f "$W/abs-empty/pre-push"
printf '#!/bin/sh\nexit 0\n' > "$W/abs-empty/pre-commit"; chmod +x "$W/abs-empty/pre-commit"
agent_allowed "#2135 an agent's push with a folder holding only another hook goes through" "cd $W/abs && git push"
git -C "$W/abs" config --unset core.hooksPath
agent_allowed "#2135 an agent's push with hooksPath unset goes through" "cd $W/abs && git push"

# Failure path: a hooksPath this hook cannot read is not a hooksPath that is unset. A git that fails
# the read (exit 128, as a damaged config gives) must refuse, never let the push out unread (L42).
mkdir -p "$W/bin"
REAL_GIT="$(command -v git)"
cat > "$W/bin/git" <<STUB
#!/usr/bin/env bash
case " \$* " in *" config --get core.hooksPath "*) echo "fatal: bad config line 1" >&2; exit 128 ;; esac
exec "$REAL_GIT" "\$@"
STUB
chmod +x "$W/bin/git"
out="$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","hook_event_name":"PreToolUse","tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' \
  "cd $W/target && git push" "$W/session" | PATH="$W/bin:$PATH" bash "$HOOK" 2>"$W/err")"; rc=$?
[ "$rc" -eq 2 ] && check "a hooksPath read that fails refuses the push" ok || check "a hooksPath read that fails refuses the push" "exit $rc, stderr [$(head -c 300 "$W/err")]"
says "and says it could not read it, not that the folder is missing" "$(cat "$W/err")" "could not read"

echo "push scope notice: an orchestrated agent runs the install before its first commit (claude-config#2098)"

# The decision recorded on #2098 for #2070's open question: no hook runs an install when a worktree
# is created, and the agent rules say to run it right after the worktree is made, before any commit,
# since until the folder exists git runs none of the repository's hooks on a commit either, and the
# refusal above only arrives at the push.
RULES="$DIR/../skills/orchestrate/agent-rules.md"
rules="$(cat "$RULES" 2>/dev/null)"
says "the agent rules name the setting to read in the worktree" "$rules" "config --get core.hooksPath"
says "and say to run the install before the first commit" "$rules" "before your first commit"
says "and name the lockfile's install" "$rules" "pnpm install"
says "and name the decision" "$rules" "#2098"

echo "push scope notice: it is actually run"

python3 - "$SETTINGS" <<'PY' && check "settings register it on PreToolUse Bash" ok || check "settings register it on PreToolUse Bash" "not registered"
import json, sys
d = json.load(open(sys.argv[1]))
for group in d.get("hooks", {}).get("PreToolUse", []):
    if group.get("matcher") == "Bash":
        for h in group.get("hooks", []):
            if h.get("command", "").endswith("hooks/push-scope-notice.sh"):
                sys.exit(0)
sys.exit(1)
PY

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
