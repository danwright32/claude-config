#!/usr/bin/env bash
# A whole tree scan: a send touching these paths runs this suite (claude-config#809).
# send-gate: scans settings.hooks.json
# Tests for fresh-worktree-base-gate.sh, which refuses the first file edit in a fresh worktree (one
# with no commits of its own) while its base is behind the remote's main branch, naming the one
# command that brings it up to date (claude-config#2517). Reading is never refused.
#
# Worktrees share refs, so once another worktree has fetched, `git fetch` prints nothing however far
# main has moved; on 2026-09-14 that let a pull request merge without the rebase its brief required.
# The rule to check lived only in CLAUDE.md, and a rule only in a prompt is a hope (L27).
#
# Every origin here is a local bare repository, so no case reaches the network. The cases are the
# issue's "Done when" (a worktree cut from an old commit is refused on its first edit and allowed
# after updating; a worktree with its own commits is never refused), the agent worktree this config
# cuts from a freshly fetched origin/main, which must never be refused, and the failure paths: a
# fetch that fails, a fetch that hangs past its bound, and a payload that cannot be read.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$DIR/fresh-worktree-base-gate.sh"
. "$DIR/lib/settings-file.sh"
SETTINGS="$(hook_settings_file "$DIR/..")"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

if [ ! -f "$GATE" ]; then
  echo "FAIL: test-fresh-worktree-base-gate: fresh-worktree-base-gate.sh is missing beside this suite"
  printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" 1
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fresh-wt.XXXXXXXX")" || exit 1
WORK="$(cd "$WORK" && pwd -P)"
case "$WORK" in ''|/) echo "refusing to run: throwaway directory came back as '$WORK'" >&2; exit 2 ;; esac
trap 'rm -rf "$WORK"' EXIT

# The fixture's git sees none of the Mac's own configuration, hooks or signing.
export HOME="$WORK/home" GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME"
printf '[user]\n\tname = Fixture\n\temail = fixture@example.invalid\n[init]\n\tdefaultBranch = main\n[commit]\n\tgpgsign = false\n' > "$GIT_CONFIG_GLOBAL"
export FRESH_WORKTREE_STATE_DIR="$WORK/state"
mkdir -p "$FRESH_WORKTREE_STATE_DIR"

g() { git "$@" >/dev/null 2>&1; }
commit_in() { # commit_in <checkout> <name>
  printf '%s\n' "$2" > "$1/$2.txt"
  g -C "$1" add "$2.txt"
  g -C "$1" commit -q -m "$2"
}

# run_gate <tool> <file path> [session] [extra json] -> RC, OUT (stdout), ERR (stderr)
run_gate() {
  local tool="$1" path="$2" session="${3:-s1}" extra="${4:-}" payload
  payload="$(python3 -c '
import json, sys
tool, path, session, extra = sys.argv[1:5]
key = "notebook_path" if tool == "NotebookEdit" else "file_path"
ti = {key: path}
if tool == "Edit":
    ti.update({"old_string": "a", "new_string": "b"})
elif tool == "Write":
    ti["content"] = "x"
d = {"hook_event_name": "PreToolUse", "session_id": session, "cwd": "/", "tool_name": tool, "tool_input": ti}
if extra:
    d.update(json.loads(extra))
print(json.dumps(d))' "$tool" "$path" "$session" "$extra")"
  OUT="$(printf '%s' "$payload" | bash "$GATE" 2>"$WORK/err")"; RC=$?
  ERR="$(cat "$WORK/err")"
}

# --- the fixture -----------------------------------------------------------------------------------
# origin at c1; the checkout clones it; then origin moves on to c3 behind the checkout's back, so the
# checkout's origin/main still says c1. A worktree cut now is two commits behind, and a check that
# trusted the unrefreshed ref would call it current (L345).
git init -q --bare "$WORK/origin.git"
git clone -q "$WORK/origin.git" "$WORK/seed" 2>/dev/null
commit_in "$WORK/seed" c1
g -C "$WORK/seed" push -q origin main
git clone -q "$WORK/origin.git" "$WORK/repo" 2>/dev/null
commit_in "$WORK/seed" c2
commit_in "$WORK/seed" c3
g -C "$WORK/seed" push -q origin main
C1="$(git -C "$WORK/repo" rev-parse origin/main)"
C3="$(git -C "$WORK/seed" rev-parse HEAD)"
g -C "$WORK/repo" worktree add -q "$WORK/repo/.claude/worktrees/stale" -b stale origin/main
STALE="$WORK/repo/.claude/worktrees/stale"

echo "a fresh worktree cut from an old commit is refused on its first edit"
run_gate Edit "$STALE/c1.txt"
[ "$RC" -eq 2 ] && check "first edit refused" ok || check "first edit in a stale fresh worktree should exit 2" "exit $RC: $ERR"
case "$ERR" in *"git -C \"$STALE\" merge --ff-only origin/main"*) check "names the one command" ok ;;
  *) check "the refusal should name git -C \"$STALE\" merge --ff-only origin/main" "$ERR" ;; esac
case "$ERR" in *"2 commits behind origin/main"*) check "says how far behind" ok ;;
  *) check "the refusal should say it is 2 commits behind origin/main" "$ERR" ;; esac
case "$ERR" in *"Reading"*"not"*) check "says reading is unaffected" ok ;;
  *) check "the refusal should say reading is not affected" "$ERR" ;; esac
# It fetched before judging: the shared ref now says c3, where nothing else refreshed it.
[ "$(git -C "$WORK/repo" rev-parse origin/main)" = "$C3" ] && check "fetched before judging" ok \
  || check "the gate should fetch origin main before judging, so the shared ref reaches c3" "$(git -C "$WORK/repo" rev-parse origin/main)"

echo "a Write of a new file in a folder not yet made is judged by the worktree it lands in"
run_gate Write "$STALE/new/deeper/file.txt"
[ "$RC" -eq 2 ] && check "new file refused" ok || check "a Write of a new file in a stale worktree should exit 2" "exit $RC: $ERR"
for t in MultiEdit NotebookEdit; do
  run_gate "$t" "$STALE/c1.txt"
  [ "$RC" -eq 2 ] && check "$t refused" ok || check "$t in a stale fresh worktree should exit 2" "exit $RC: $ERR"
done

echo "reading is never refused"
run_gate Read "$STALE/c1.txt"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && check "Read passes" ok || check "a Read in a stale worktree should pass in silence" "exit $RC: $OUT $ERR"
reg="$(python3 - "$SETTINGS" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for group in d.get("hooks", {}).get("PreToolUse", []):
    for h in group.get("hooks", []):
        if "fresh-worktree-base-gate.sh" in h.get("command", ""):
            print("%s\t%s\t%s" % (group.get("matcher", ""), h.get("onFailure", "-"), h.get("timeout", "-")))
PY
)"
IFS=$'\t' read -r matcher onfail tmo <<< "$reg"
[ "$matcher" = "Edit|Write|MultiEdit|NotebookEdit" ] && check "registered on the file edit tools" ok \
  || check "the gate should be registered once on Edit|Write|MultiEdit|NotebookEdit, and never on Read" "${reg:-not registered}"
[ "$onfail" = block ] && check "registered to block on failure" ok || check "the gate should carry onFailure block" "$onfail"
case "$tmo" in ''|-|*[!0-9]*) check "the registration should carry a timeout" "${tmo:-none}" ;;
  *) [ "$tmo" -ge 20 ] && check "timeout leaves room past the fetch bound" ok || check "the timeout should be at least 20 seconds, twice the 10 second fetch bound" "$tmo" ;; esac

echo "after updating with the named command, the edit goes ahead and stays cached"
g -C "$STALE" merge --ff-only origin/main
run_gate Edit "$STALE/c1.txt"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && check "allowed after updating" ok || check "after merge --ff-only the edit should pass in silence" "exit $RC: $OUT $ERR"
# Origin moves again; this session already judged the worktree, so it neither fetches nor refuses.
commit_in "$WORK/seed" c4
g -C "$WORK/seed" push -q origin main
run_gate Edit "$STALE/c1.txt"
[ "$RC" -eq 0 ] && check "cached for the session" ok || check "a worktree judged current this session should not be judged again" "exit $RC: $ERR"
[ "$(git -C "$WORK/repo" rev-parse origin/main)" = "$C3" ] && check "no second fetch" ok \
  || check "a cached worktree should cost no fetch" "origin/main moved to $(git -C "$WORK/repo" rev-parse origin/main)"
# Another session has not judged it, so it fetches and finds it one behind.
run_gate Edit "$STALE/c1.txt" s2
[ "$RC" -eq 2 ] && check "cache is per session" ok || check "a second session should judge the worktree afresh" "exit $RC: $ERR"
case "$ERR" in *"1 commit behind"*) check "singular count" ok ;; *) check "one commit behind should say 1 commit behind" "$ERR" ;; esac

echo "a worktree with commits of its own is never refused"
g -C "$WORK/repo" worktree add -q "$WORK/repo/.claude/worktrees/own" -b own "$C1"
OWN="$WORK/repo/.claude/worktrees/own"
commit_in "$OWN" mine
run_gate Edit "$OWN/mine.txt"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && check "own commits stand it down" ok || check "a worktree with its own commit, though behind, should pass" "exit $RC: $OUT $ERR"
run_gate Edit "$OWN/mine.txt" s3
[ "$RC" -eq 0 ] && check "own commits, fresh session" ok || check "a worktree with its own commit should pass in a new session too" "exit $RC: $ERR"

echo "an agent's worktree cut from a freshly fetched origin/main is never refused"
g -C "$WORK/repo" fetch -q origin
g -C "$WORK/repo" worktree add -q "$WORK/repo/.claude/worktrees/agent" -b fix/agent origin/main
run_gate Edit "$WORK/repo/.claude/worktrees/agent/c1.txt" s4 '{"agent_id": "a1b2c3d4"}'
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && check "agent worktree allowed" ok || check "an agent worktree cut from fetched origin/main should pass in silence" "exit $RC: $OUT $ERR"

echo "the primary checkout and files outside any repository are out of scope"
g -C "$WORK/repo" reset -q --hard "$C1"
run_gate Edit "$WORK/repo/c1.txt" s5
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && check "primary checkout passes" ok || check "the primary checkout, though behind, should pass" "exit $RC: $OUT $ERR"
mkdir -p "$WORK/plain"
run_gate Write "$WORK/plain/notes.md" s5
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && check "outside a repository passes" ok || check "a file outside any repository should pass" "exit $RC: $OUT $ERR"

# --- a fetch that fails ----------------------------------------------------------------------------
git clone -q "$WORK/origin.git" "$WORK/repo2" 2>/dev/null
g -C "$WORK/repo2" worktree add -q "$WORK/repo2/.claude/worktrees/current" -b current origin/main
g -C "$WORK/repo2" worktree add -q "$WORK/repo2/.claude/worktrees/behind" -b behind origin/main~1
g -C "$WORK/repo2" remote set-url origin "$WORK/no-such-origin.git"

echo "a fetch that fails says it could not check, lets the edit through, and does not repeat"
run_gate Edit "$WORK/repo2/.claude/worktrees/current/c1.txt" s6
[ "$RC" -eq 0 ] && check "failed fetch does not block" ok || check "a failed fetch should let the edit through" "exit $RC: $ERR"
case "$OUT" in *'"systemMessage"'*"could not"*) check "says it could not check" ok ;;
  *) check "a failed fetch should say in a systemMessage that it could not check" "$OUT" ;; esac
printf '%s' "$OUT" | python3 -c 'import json, sys; json.load(sys.stdin)' 2>/dev/null && check "notice is valid JSON" ok || check "the notice should be valid JSON" "$OUT"
run_gate Edit "$WORK/repo2/.claude/worktrees/current/c1.txt" s6
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && check "said once, not on every edit" ok || check "a second edit inside the retry window should pass in silence" "exit $RC: $OUT"
FRESH_WORKTREE_RETRY_MINUTES=0 run_gate Edit "$WORK/repo2/.claude/worktrees/current/c1.txt" s6
case "$OUT" in *"could not"*) check "tried again once the window passed" ok ;;
  *) check "past the retry window the gate should try the fetch again and say so again" "exit $RC: $OUT" ;; esac

echo "a fetch that fails while even the local copy shows the worktree behind still refuses, offline"
run_gate Edit "$WORK/repo2/.claude/worktrees/behind/c1.txt" s6
[ "$RC" -eq 2 ] && check "behind on the local copy refused" ok || check "behind on the local ref, with no fetch, should still refuse" "exit $RC: $ERR"
case "$ERR" in *"merge --ff-only origin/main"*"could not"*|*"could not"*"merge --ff-only origin/main"*) check "names the command and the failed fetch" ok ;;
  *) check "the offline refusal should name the command and say the fetch failed" "$ERR" ;; esac

echo "a fetch that hangs is cut off at its bound and the edit goes ahead"
mkdir -p "$WORK/bin"
REALGIT="$(command -v git)"
printf '#!/bin/bash\ncase " $* " in *" fetch "*) sleep 30 ;; esac\nexec "%s" "$@"\n' "$REALGIT" > "$WORK/bin/git"
chmod +x "$WORK/bin/git"
start=$SECONDS
# The agent worktree is current on the local ref, so the only thing that can decide is the fetch.
PATH="$WORK/bin:$PATH" FRESH_WORKTREE_FETCH_SECONDS=1 run_gate Edit "$WORK/repo/.claude/worktrees/agent/c1.txt" s7
took=$((SECONDS - start))
[ "$took" -le 10 ] && check "hang bounded" ok || check "a hanging fetch should be cut off near its 1 second bound" "took ${took}s"
[ "$RC" -eq 0 ] && check "hang does not block" ok || check "a fetch cut off at its bound should not block the edit" "exit $RC: $ERR"
case "$OUT" in *"could not"*) check "hang says it could not check" ok ;; *) check "a hanging fetch should be reported as could not check" "$OUT" ;; esac

echo "a payload that cannot be read is let through, saying so"
OUT="$(printf '%s' '{"tool_name": "Edit", "tool_input": {"file_path": "/x/y.txt"' | bash "$GATE" 2>/dev/null)"; RC=$?
[ "$RC" -eq 0 ] && check "cut payload passes" ok || check "a cut payload should not block" "exit $RC"
case "$OUT" in *'"systemMessage"'*"could not read"*) check "cut payload said" ok ;; *) check "a cut payload should be named in a systemMessage" "$OUT" ;; esac
OUT="$(printf '%s' '{"tool_name": "Bash", "tool_input": {"command": "ls"' | bash "$GATE" 2>/dev/null)"; RC=$?
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && check "unrelated cut payload silent" ok || check "a cut payload naming no file should pass in silence" "exit $RC: $OUT"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
