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
gate() { # gate <hook> <command> -> exit code; stderr in $W/gate.err
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","hook_event_name":"PreToolUse","tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' \
    "$2" "$W/session" | PUSH_GATE_LEDGER_DIR="$W/ledger" bash "$DIR/$1" >/dev/null 2>"$W/gate.err"
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
