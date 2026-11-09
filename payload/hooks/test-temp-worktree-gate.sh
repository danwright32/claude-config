#!/usr/bin/env bash
# A whole tree scan: a send touching these paths runs this suite (claude-config#809).
# send-gate: scans settings.hooks.json
# Tests for temp-worktree-gate.sh, which refuses a git worktree placed under a temp folder a restart
# empties (/tmp, /private/tmp, /var/folders, $TMPDIR), and EnterWorktree pointed at one, naming the
# repository's .claude/worktrees/<name> instead (claude-config#2528).
#
# On 2026-11-09 a restart emptied /private/tmp and took an agent's worktree with an uncommitted fix.
# #2490 told agents in prose to put worktrees in .claude/worktrees/, and a rule only in a prompt is a
# hope (L27), so this gate makes it hold.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$DIR/temp-worktree-gate.sh"
LIB="$DIR/lib/temp-worktree.py"
. "$DIR/lib/settings-file.sh"
SETTINGS="$(hook_settings_file "$DIR/..")"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

missing=""
for f in "$GATE" "$LIB"; do
  [ -f "$f" ] || missing="$missing $(basename "$f")"
done
if [ -n "$missing" ]; then
  echo "FAIL: test-temp-worktree-gate: missing beside this suite:$missing"
  printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" 1
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/temp-worktree.XXXXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# The session's folder: a repository path that is not under any temp folder. Nothing is made there;
# the gate only reads the path.
REPO="/Users/nobody/Apps/proj"

# A stand in for git, so the repository the gate finds is the one each case names. With STUB_COMMON
# set, `git rev-parse ... --git-common-dir` prints it; unset, it fails as git does outside a
# repository, and the gate falls back to the folder the command runs in.
mkdir -p "$WORK/bin"
REALGIT="$(command -v git)"
cat > "$WORK/bin/git" <<EOF
#!/bin/bash
case "\$*" in
  *rev-parse*git-common-dir*)
    if [ -n "\${STUB_COMMON:-}" ]; then printf '%s\n' "\$STUB_COMMON"; exit 0; fi
    echo "fatal: not a git repository" >&2; exit 128 ;;
esac
exec "$REALGIT" "\$@"
EOF
chmod +x "$WORK/bin/git"

payload() { # payload <tool> <input json> [agent_id] [cwd]
  python3 -c '
import json, sys
d = {"session_id": "s-2528", "transcript_path": "/tmp/s-2528.jsonl", "cwd": sys.argv[4],
     "hook_event_name": "PreToolUse", "tool_name": sys.argv[1], "tool_input": json.loads(sys.argv[2]),
     "tool_use_id": "toolu_01"}
if sys.argv[3]:
    d["agent_id"] = sys.argv[3]
    d["agent_type"] = "general-purpose"
print(json.dumps(d))
' "$1" "$2" "${3:-}" "${4:-$REPO}"
}
bash_payload() { # bash_payload <command> [agent_id] [cwd]
  payload Bash "$(python3 -c 'import json, sys; print(json.dumps({"command": sys.argv[1]}))' "$1")" "${2:-}" "${3:-}"
}
RC=0; OUT=""; ERR=""
run_hook() { # run_hook <payload>
  local errf; errf="$(mktemp "$WORK/err.XXXXXXXX")"
  OUT="$(printf '%s' "$1" | PATH="$WORK/bin:$PATH" bash "$GATE" 2>"$errf")"; RC=$?
  ERR="$(cat "$errf")"; rm -f "$errf"
}
refused() { # refused <label> <command> <suggested path> [cwd]
  run_hook "$(bash_payload "$2" "" "${4:-}")"
  case "$RC:$ERR" in
    "2:REFUSED (temp-worktree-gate.sh):"*"$3"*) check "$1" ok ;;
    *) check "$1" "exit $RC, stderr: ${ERR:0:400}" ;;
  esac
}
unread_refused() { # unread_refused <label> <command>
  run_hook "$(bash_payload "$2")"
  case "$RC:$ERR" in
    "2:REFUSED (temp-worktree-gate.sh):"*) check "$1" ok ;;
    *) check "$1" "exit $RC, stderr: ${ERR:0:400}" ;;
  esac
}
allowed() { # allowed <label> <command> [cwd]
  run_hook "$(bash_payload "$2" "" "${3:-}")"
  if [ "$RC" -eq 0 ] && [ -z "$ERR" ]; then check "$1" ok; else check "$1" "exit $RC, stderr: ${ERR:0:400}"; fi
}
says() { case "$ERR$OUT" in *"$2"*) check "$1" ok ;; *) check "$1" "did not say '$2': ${ERR:0:400}" ;; esac; }

SUGGEST="$REPO/.claude/worktrees/wt-2528"

# ---------------------------------------------------------------------------------------------
echo "a git worktree added under a temp folder is refused, naming .claude/worktrees/<name>"
refused "under /tmp" 'git worktree add /tmp/wt-2528 -b fix/2528 origin/main' "$SUGGEST"
says "the refusal names the restart" "restart"
says "the refusal names the issue" "#2528"
says "the refusal names its one command override" "ALLOW_TEMP_WORKTREE=1"
refused "under /private/tmp, a scratchpad" 'git worktree add /private/tmp/claude-501/proj/sess/scratchpad/wt-2528 -b fix/2528' "$SUGGEST"
refused "under /var/folders" 'git worktree add /var/folders/ab/cd1234/T/wt-2528' "$SUGGEST"
refused "under /private/var/folders" 'git worktree add /private/var/folders/ab/cd1234/T/wt-2528' "$SUGGEST"
refused "under \$TMPDIR" 'git worktree add "$TMPDIR/wt-2528" -b fix/2528' "$SUGGEST"
refused "under \${TMPDIR}" 'git worktree add ${TMPDIR}/wt-2528' "$SUGGEST"
refused "under \${TMPDIR:-/tmp}" 'git worktree add "${TMPDIR:-/tmp}/wt-2528"' "$SUGGEST"
refused "under \$TMP" 'git worktree add $TMP/wt-2528' "$SUGGEST"
refused "with git -C and an absolute temp path" "git -C $REPO worktree add /tmp/wt-2528 -b fix/2528" "$SUGGEST"
refused "relative to git -C, climbing into /tmp" "git -C $REPO worktree add ../../../../tmp/wt-2528" "$SUGGEST"
refused "relative after a cd, climbing into /private/tmp" "cd $REPO && git worktree add ../../../../private/tmp/wt-2528" "$SUGGEST"
refused "relative to the session folder, climbing into /tmp" 'git worktree add ../../../../tmp/wt-2528' "$SUGGEST"
refused "behind rtk" 'rtk git worktree add /tmp/wt-2528' "$SUGGEST"
refused "behind env" 'env GIT_TRACE=0 git worktree add /tmp/wt-2528' "$SUGGEST"
refused "inside bash -c" "bash -c 'git worktree add /tmp/wt-2528 -b fix/2528'" "$SUGGEST"
refused "after a chain" 'git fetch origin && git worktree add /tmp/wt-2528 -b fix/2528 origin/main' "$SUGGEST"
refused "-b before the path" 'git worktree add -b fix/2528 /tmp/wt-2528 origin/main' "$SUGGEST"
refused "-fb clustered before the path" 'git worktree add -fb fix/2528 /tmp/wt-2528' "$SUGGEST"
refused "--lock --reason with a value before the path" 'git worktree add --lock --reason keep /tmp/wt-2528 main' "$SUGGEST"
refused "--reason=value before the path" 'git worktree add --reason=keep --lock /tmp/wt-2528' "$SUGGEST"
refused "after --" 'git worktree add -- /tmp/wt-2528' "$SUGGEST"
refused "a move into /tmp" 'git worktree move .claude/worktrees/wt-2528 /tmp/wt-2528' "$SUGGEST"
# The repository is found by git where it can be: from a worktree, the main checkout's folder.
STUB_COMMON="/Users/nobody/Apps/main/.git" refused "the suggestion is the main checkout's .claude/worktrees" \
  'git worktree add /tmp/wt-2528' "/Users/nobody/Apps/main/.claude/worktrees/wt-2528"
# The main session is judged the same as an agent: a restart takes either one's worktree.
run_hook "$(bash_payload 'git worktree add /tmp/wt-2528' a1b2c3d4)"
if [ "$RC" -eq 2 ]; then check "an agent's temp worktree is refused" ok; else check "an agent's temp worktree is refused" "exit $RC: ${ERR:0:300}"; fi

# ---------------------------------------------------------------------------------------------
echo "a path the gate cannot know is refused, never guessed at"
unread_refused "a variable for the path" 'git worktree add "$WT" -b fix/2528'
says "saying to write the path literally" "literal"
unread_refused "a substitution for the path" 'git worktree add "$(mktemp -d)"'
unread_refused "a quote that never closes" 'git worktree add "/tmp/wt-2528'
unread_refused "a relative path after cd -" 'cd - && git worktree add wt-2528'
unread_refused "an eval naming worktree" 'eval "$CMD worktree add /tmp/x"'

# ---------------------------------------------------------------------------------------------
echo "a worktree anywhere else, and every other worktree command, goes through"
allowed "under the repository's .claude/worktrees" 'git worktree add .claude/worktrees/fix-2528 -b fix/2528 origin/main'
allowed "the same, absolute" "git worktree add $REPO/.claude/worktrees/fix-2528 -b fix/2528"
allowed "with git -C" "git -C $REPO worktree add $REPO/.claude/worktrees/fix-2528 -b fix/2528"
allowed "under home by tilde" 'git worktree add ~/wt-2528'
allowed "under \$HOME" 'git worktree add "$HOME/wt-2528"'
allowed "under /var/tmp, which a restart keeps" 'git worktree add /var/tmp/wt-2528'
allowed "a folder whose name only starts like tmp" 'git worktree add /tmpfoo/wt-2528'
allowed "git worktree list" 'git worktree list'
allowed "git worktree remove of a temp worktree" 'git worktree remove /tmp/wt-2528'
allowed "git worktree prune" 'git worktree prune'
allowed "a move within the repository" 'git worktree move .claude/worktrees/a .claude/worktrees/b'
allowed "an echo naming one" 'echo "git worktree add /tmp/wt-2528"'
allowed "a commit message naming one" 'git commit -m "refuse git worktree add /tmp/wt-2528"'
allowed "a command that is not git" 'ls -la /tmp'
allowed "the override, for one command" 'ALLOW_TEMP_WORKTREE=1 git worktree add /tmp/wt-2528'
# A repository that is itself in a temp folder loses nothing more by its worktree being there.
STUB_COMMON="/private/tmp/fixture/.git" allowed "a repository itself under a temp folder" 'git worktree add /tmp/wt-2528'
allowed "a repository git cannot find, run in a temp folder" 'git worktree add ../wt-2528' /private/tmp/fixture/repo

# ---------------------------------------------------------------------------------------------
echo "EnterWorktree pointed at a temp folder is refused"
run_hook "$(payload EnterWorktree '{"path": "/private/tmp/claude-501/scratchpad/wt-2528"}')"
case "$RC:$ERR" in "2:REFUSED (temp-worktree-gate.sh):"*"$SUGGEST"*) check "EnterWorktree path under /private/tmp" ok ;; *) check "EnterWorktree path under /private/tmp" "exit $RC: ${ERR:0:300}" ;; esac
run_hook "$(payload EnterWorktree '{"path": "/tmp/wt-2528"}' a1b2c3d4)"
if [ "$RC" -eq 2 ]; then check "an agent's EnterWorktree path under /tmp" ok; else check "an agent's EnterWorktree path under /tmp" "exit $RC: ${ERR:0:300}"; fi
run_hook "$(payload EnterWorktree '{"name": "fix-2528"}')"
if [ "$RC" -eq 0 ] && [ -z "$ERR" ]; then check "EnterWorktree by name" ok; else check "EnterWorktree by name" "exit $RC: ${ERR:0:300}"; fi
run_hook "$(payload EnterWorktree "{\"path\": \"$REPO/.claude/worktrees/fix-2528\"}")"
if [ "$RC" -eq 0 ] && [ -z "$ERR" ]; then check "EnterWorktree path under .claude/worktrees" ok; else check "EnterWorktree path under .claude/worktrees" "exit $RC: ${ERR:0:300}"; fi
run_hook "$(payload EnterWorktree '{}')"
if [ "$RC" -eq 0 ] && [ -z "$ERR" ]; then check "EnterWorktree with neither" ok; else check "EnterWorktree with neither" "exit $RC: ${ERR:0:300}"; fi

# ---------------------------------------------------------------------------------------------
echo "a payload the gate cannot read"
run_hook '{"tool_name": "Bash", "tool_input": {"command": "git worktree add /tmp/wt"'
if [ "$RC" -eq 2 ]; then check "a broken payload naming a worktree add is refused" ok; else check "a broken payload naming a worktree add is refused" "exit $RC: ${ERR:0:300}"; fi
run_hook '{"tool_name": "Bash", "tool_input": {"command": "git status"'
if [ "$RC" -eq 0 ]; then check "a broken payload naming none goes through" ok; else check "a broken payload naming none goes through" "exit $RC: ${ERR:0:300}"; fi
run_hook '{"tool_name": "Bash", "tool_input": {"command": ["git", "worktree", "add", "/tmp/wt"]}}'
if [ "$RC" -eq 2 ]; then check "a command sent as a list of words is refused" ok; else check "a command sent as a list of words is refused" "exit $RC: ${ERR:0:300}"; fi

NOPY="$WORK/nopy"; mkdir -p "$NOPY"
for t in bash cat dirname sed head tail tr date mkdir rm mv grep cut wc printf env; do
  p="$(command -v "$t" 2>/dev/null)"; case "$p" in /*) ln -sf "$p" "$NOPY/$t" ;; esac
done
run_nopy() { # run_nopy <payload>
  local errf; errf="$(mktemp "$WORK/err.XXXXXXXX")"
  OUT="$(printf '%s' "$1" | PATH="$NOPY" "$NOPY/bash" "$GATE" 2>"$errf")"; RC=$?
  ERR="$(cat "$errf")"; rm -f "$errf"
}
run_nopy "$(bash_payload 'git worktree add /tmp/wt-2528')"
if [ "$RC" -eq 2 ]; then check "with no python3 a worktree add is refused" ok; else check "with no python3 a worktree add is refused" "exit $RC: ${ERR:0:300}"; fi
says "naming python3" "python3"
run_nopy "$(bash_payload 'git worktree list')"
if [ "$RC" -eq 0 ]; then check "with no python3 a worktree list goes through" ok; else check "with no python3 a worktree list goes through" "exit $RC: ${ERR:0:300}"; fi

# A reader that crashes exits 1, as Python does on an uncaught exception, and that must never read
# as "nothing to refuse".
CRASHPY="$WORK/crashpy"; mkdir -p "$CRASHPY"
REALPY="$(command -v python3)"
printf '#!/bin/bash\ncase "$*" in *temp-worktree.py*) echo "Traceback: boom" >&2; exit 1 ;; esac\nexec "%s" "$@"\n' "$REALPY" > "$CRASHPY/python3"
chmod +x "$CRASHPY/python3"
errf="$(mktemp "$WORK/err.XXXXXXXX")"
OUT="$(bash_payload 'git worktree add /tmp/wt-2528' | PATH="$CRASHPY:$WORK/bin:$PATH" bash "$GATE" 2>"$errf")"; RC=$?
ERR="$(cat "$errf")"; rm -f "$errf"
if [ "$RC" -eq 2 ]; then check "a reader that crashes still refuses a worktree add" ok; else check "a reader that crashes still refuses a worktree add" "exit $RC: ${ERR:0:300}"; fi

# A library the gate cannot load is not a command with nothing to check (claude-config#1900).
T="$WORK/nolib"; mkdir -p "$T/lib"
cp "$GATE" "$T/temp-worktree-gate.sh"
errf="$(mktemp "$WORK/err.XXXXXXXX")"
OUT="$(bash_payload 'git worktree add /tmp/wt-2528' | bash "$T/temp-worktree-gate.sh" 2>"$errf")"; RC=$?
ERR="$(cat "$errf")"; rm -f "$errf"
if [ "$RC" -eq 2 ]; then check "with its libraries missing a worktree add is refused" ok; else check "with its libraries missing a worktree add is refused" "exit $RC: ${ERR:0:300}"; fi

# ---------------------------------------------------------------------------------------------
echo "settings.hooks.json: the gate runs before every Bash and EnterWorktree call"
if jq -e '[.hooks.PreToolUse[] | select((.matcher | split("|") | index("Bash")) and (.matcher | split("|") | index("EnterWorktree"))) | .hooks[] | select(.command | endswith("/hooks/temp-worktree-gate.sh")) | select(.onFailure == "block")] | length == 1' "$SETTINGS" >/dev/null 2>&1; then
  check "temp-worktree-gate.sh is registered once under Bash and EnterWorktree, blocking" ok
else
  check "temp-worktree-gate.sh is registered once under Bash and EnterWorktree, blocking" "not registered in $SETTINGS"
fi

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
