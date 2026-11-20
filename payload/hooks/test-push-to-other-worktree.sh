#!/usr/bin/env bash
# Tests for push-scope-notice.sh's refusal of a push that sends one worktree's commits to the branch
# name another worktree has checked out (claude-config#3338).
#
# On 2026-11-20 at 3:13 PM ET a builder ran `git push origin HEAD:fix/3279-git-moves-hidden-names`
# with no -C while its shell stood in the #3277 worktree, so GitHub's branch of that name was made
# at the #3277 commit; the worktree fix-3279-b had that name checked out with its own commits. The
# push printed success and nothing refused it. Every case here runs in a throwaway repository with a
# bare repository in a temporary folder as origin, never the real one.
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
. "$DIR/lib/settings-file.sh"
SETTINGS="$(hook_settings_file "$DIR/..")"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }
says() { case "$2" in *"$3"*) check "$1" ok ;; *) check "$1" "did not say '$3': ${2:0:400}" ;; esac; }

[ -f "$HOOK" ] || { echo "FAIL: no hook at $HOOK"; printf 'SUITE-RESULT passed=0 failed=1\n'; exit 1; }

W="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.heldname.XXXXXXXX")" || W=""
case "${W%/}" in ''|/|"${HOME%/}") echo "refusing: throwaway came back as '$W'" >&2; exit 2 ;; esac
trap 'rm -rf "$W"' EXIT

REAL_GIT="$(command -v git)"
g() { "$REAL_GIT" -c user.name=t -c user.email=t@t.t -c commit.gpgsign=false -c init.defaultBranch=main "$@"; }
commit_in() { # commit_in <dir> <file> -> one commit adding <file>
  printf '%s\n' "$2" > "$1/$2" && g -C "$1" add "$2" >/dev/null 2>&1 && g -C "$1" commit -qm "$2" >/dev/null 2>&1
}

run() { # run <command> <cwd> [PATH] -> the hook's exit code; stderr in $W/err
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","hook_event_name":"PreToolUse","tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' \
    "$1" "$2" | PATH="${3:-$PATH}" bash "$HOOK" >"$W/out" 2>"$W/err"
}
allowed() { # allowed <description> <command> <cwd>
  local rc
  run "$2" "$3"; rc=$?
  if [ "$rc" -eq 0 ] && [ ! -s "$W/out" ] && [ ! -s "$W/err" ]; then check "$1" ok
  else check "$1" "exit $rc, stdout [$(head -c 200 "$W/out")], stderr [$(head -c 300 "$W/err")]"; fi
}

# The repository: main pushed to a bare origin, then a worktree per branch, each beside the
# repository the way .claude/worktrees/ holds them.
g init -q --bare "$W/origin.git" >/dev/null 2>&1
g init -q "$W/repo" >/dev/null 2>&1
commit_in "$W/repo" base.txt
g -C "$W/repo" remote add origin "$W/origin.git"
g -C "$W/repo" push -q origin main >/dev/null 2>&1
g -C "$W/repo" remote set-head origin main >/dev/null 2>&1
g -C "$W/repo" worktree add -q -b fix/a "$W/wt-a" origin/main >/dev/null 2>&1
commit_in "$W/wt-a" a.txt
g -C "$W/repo" worktree add -q -b fix/b "$W/wt-b" origin/main >/dev/null 2>&1
commit_in "$W/wt-b" b.txt
# A branch with no commits of its own yet, and a worktree at main's tip with nothing of its own.
g -C "$W/repo" worktree add -q -b fix/empty "$W/wt-empty" origin/main >/dev/null 2>&1
g -C "$W/repo" worktree add -q -b fix/plain "$W/wt-plain" origin/main >/dev/null 2>&1
# A fix up made on top of fix/b, the way a resolve or finish agent builds on another agent's branch.
g -C "$W/repo" worktree add -q -b resolve-b "$W/wt-resolve" fix/b >/dev/null 2>&1
commit_in "$W/wt-resolve" resolved.txt
# A detached head with a commit of its own.
g -C "$W/repo" worktree add -q --detach "$W/wt-detached" origin/main >/dev/null 2>&1
commit_in "$W/wt-detached" detached.txt

[ "$(g -C "$W/wt-a" branch --show-current)" = fix/a ] && [ "$(g -C "$W/wt-b" branch --show-current)" = fix/b ] \
  && [ "$(g -C "$W/wt-a" rev-list --count fix/b --not HEAD)" = 1 ] \
  && [ "$(g -C "$W/wt-resolve" rev-list --count fix/b --not HEAD)" = 0 ] \
  && [ -z "$(g -C "$W/wt-detached" branch --show-current)" ] \
  && check "the fixture: fix/a and fix/b each with a commit of its own, resolve-b built on fix/b, a detached head" ok \
  || check "the fixture: fix/a and fix/b each with a commit of its own, resolve-b built on fix/b, a detached head" "it is not, so every case below would pass or fail for the wrong reason"

echo "push to another worktree's branch name: the incident's shape is refused (claude-config#3338)"

run "git push origin HEAD:fix/b" "$W/wt-a"; rc=$?
err="$(cat "$W/err")"
[ "$rc" -eq 2 ] && check "HEAD pushed from fix/a's worktree to fix/b, which another worktree has checked out, is refused" ok \
  || check "HEAD pushed from fix/a's worktree to fix/b, which another worktree has checked out, is refused" "exit $rc [${err:0:300}]"
# By the folders' own names: git prints a path as it resolves it, which on macOS is not the spelling
# mktemp handed back (/private in front).
says "and names the worktree it was sent from" "$err" "${W##*/}/wt-a"
says "and the branch checked out there" "$err" "fix/a"
says "and the worktree that has the name checked out" "$err" "${W##*/}/wt-b"
says "and the name pushed to" "$err" "fix/b"
says "and the push to run instead, from the worktree that owns the name" "$err" "/wt-b push origin HEAD:fix/b"
says "and the issue" "$err" "claude-config#3338"

while IFS='|' read -r c d; do
  [ -n "$c" ] || continue
  c="${c//@W@/$W}"; d="${d//@W@/$W}"
  run "$c" "$d"; rc=$?
  err="$(cat "$W/err")"
  case "$rc:$err" in
    2:*"claude-config#3338"*) check "refused: $c (from ${d##*/})" ok ;;
    *) check "refused: $c (from ${d##*/})" "exit $rc [${err:0:300}]" ;;
  esac
done <<'REFUSED'
git push origin HEAD:refs/heads/fix/b|@W@/wt-a
git push -u origin HEAD:fix/b|@W@/wt-a
git push origin @:fix/b|@W@/wt-a
git push origin fix/a:fix/b|@W@/wt-a
git -C @W@/wt-a push origin HEAD:fix/b|@W@/repo
cd @W@/wt-a && git push origin HEAD:fix/b|@W@/repo
git commit --allow-empty -m more && git push origin HEAD:fix/b|@W@/wt-a
git push origin HEAD:fix/a|@W@/wt-b
git push origin HEAD:fix/b|@W@/wt-detached
git push origin HEAD:fix/empty|@W@/wt-a
REFUSED

echo "push to another worktree's branch name: what must go through still goes (claude-config#3338)"

while IFS='|' read -r c d why; do
  [ -n "$c" ] || continue
  c="${c//@W@/$W}"; d="${d//@W@/$W}"
  allowed "let through, $why: $c (from ${d##*/})" "$c" "$d"
done <<'ALLOWED'
git push origin HEAD:fix/a|@W@/wt-a|the branch to its own name
git push -u origin fix/a|@W@/wt-a|the branch by its own name
git push origin HEAD:refs/heads/fix/a|@W@/wt-a|the branch to its own name spelled in full
git push origin HEAD:fix/a-2|@W@/wt-a|a name no worktree holds
git push origin HEAD:fix/b|@W@/wt-b|the worktree that holds the name
git -C @W@/wt-b push origin HEAD:fix/b|@W@/wt-a|the worktree that holds the name, named with -C
cd @W@/wt-b && git push origin HEAD:fix/b|@W@/wt-a|the worktree that holds the name, behind a cd
git push origin HEAD:new-name|@W@/wt-detached|a detached head to a new name
git push origin HEAD:fix/b|@W@/wt-resolve|a fix up built on the branch it pushes to
git push origin HEAD:fix/empty|@W@/wt-plain|the very commit the name already points at
git push origin HEAD:refs/tags/fix/b|@W@/wt-a|a tag, not a branch
git push origin --delete fix/b|@W@/wt-a|a deletion
git push -n origin HEAD:fix/b|@W@/wt-a|a dry run
ALLOWED

echo "push to another worktree's branch name: a worktree list that cannot be read (claude-config#3338)"

# A git that answers everything but `worktree list`, as a repository whose worktree records git
# cannot read would. A check that could not be made is not one that passed, so the push is refused
# and says it could not check; a push is recoverable by running it again once the list reads.
mkdir -p "$W/bin"
cat > "$W/bin/git" <<SHIM
#!/usr/bin/env bash
case " \$* " in *" worktree list "*) echo "fatal: worktree records unreadable (test shim)" >&2; exit 128 ;; esac
exec "$REAL_GIT" "\$@"
SHIM
chmod +x "$W/bin/git"
"$W/bin/git" -C "$W/wt-a" worktree list --porcelain >/dev/null 2>&1; src=$?
"$W/bin/git" -C "$W/wt-a" rev-parse HEAD >/dev/null 2>&1; orc=$?
[ "$src" -ne 0 ] && [ "$orc" -eq 0 ] && check "the shim fails worktree list and answers the rest" ok \
  || check "the shim fails worktree list and answers the rest" "worktree list exit $src, rev-parse exit $orc"
run "git push origin HEAD:fix/b" "$W/wt-a" "$W/bin:$PATH"; rc=$?
err="$(cat "$W/err")"
[ "$rc" -eq 2 ] && check "with the worktree list unreadable, a push to another name is refused" ok \
  || check "with the worktree list unreadable, a push to another name is refused" "exit $rc [${err:0:300}]"
says "and says it could not check" "$err" "could not be checked"
says "and names the name" "$err" "fix/b"
says "and the issue" "$err" "claude-config#3338"
run "git push origin HEAD:fix/a" "$W/wt-a" "$W/bin:$PATH"; rc=$?
[ "$rc" -eq 0 ] && [ ! -s "$W/err" ] && check "and a push of the branch to its own name needs no list, so it goes" ok \
  || check "and a push of the branch to its own name needs no list, so it goes" "exit $rc [$(head -c 300 "$W/err")]"

echo "push to another worktree's branch name: wired for every Bash call (claude-config#3338)"

# The refusal lives in push-scope-notice.sh, so it runs only if that hook is in the hooks block for
# Bash before a call, and blocks only if a failure of it blocks.
wired="$(python3 - "$SETTINGS" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for m in d.get("hooks", {}).get("PreToolUse", []):
    if m.get("matcher") not in ("Bash", "*", ""):
        continue
    for h in m.get("hooks", []):
        if h.get("command", "").endswith("/hooks/push-scope-notice.sh") and "if" not in h:
            print(h.get("onFailure", ""))
PY
)"
[ "$wired" = block ] && check "push-scope-notice.sh is wired before every Bash call and blocks on failure" ok \
  || check "push-scope-notice.sh is wired before every Bash call and blocks on failure" "found [$wired] in $SETTINGS"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
