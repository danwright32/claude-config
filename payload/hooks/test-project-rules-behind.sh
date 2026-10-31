#!/usr/bin/env bash
# Tests for the session start notice that a project's primary checkout is behind origin on its
# rule files (claude-config#1939), said by rule-files-changed.sh through lib/project-rules-behind.sh.
#
# On 2026-10-29 Bidspoke cut its CLAUDE.md from 36,964 to 20,423 characters, and a day later no
# session had loaded the cut: every session loads the project rules from the primary checkout, which
# sat on main 22 commits behind origin/main, and nothing said so. So the loud case is proved here,
# and every quiet one beside it in the same kind of fixture, because a notice that fires on a
# current checkout, or on a checkout behind only on code, would be ignored within a day (L36).
#
# Every fixture is a real git repository with a real origin, in this run's own folder, and HOME
# points there too, so no real checkout and no real git config is read (L2).
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/rule-files-changed.sh"
. "$DIR/lib/hook-notice.sh"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

if ! command -v git >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  printf 'SUITE-NOT-RUN %s\n' "needs git and python3 to build the fixture checkouts and read the notice"
  printf 'SUITE-RESULT passed=0 failed=0\n'
  exit 2
fi

TMPROOT="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/project-rules-behind.XXXXXXXX")" && pwd -P)"
trap 'rm -rf "$TMPROOT"' EXIT
export HOME="$TMPROOT/home"
mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$TMPROOT/gitconfig"
printf '[user]\n\tname = t\n\temail = t@e\n[init]\n\tdefaultBranch = main\n[advice]\n\tdetachedHead = false\n' > "$GIT_CONFIG_GLOBAL"
export CLAUDE_RULES_STATE_DIR="$TMPROOT/state"
# The global rule files the hook also watches: present, so the hook runs at all, and never changed.
export CLAUDE_RULES_DIR="$TMPROOT/dot-claude"
mkdir -p "$CLAUDE_RULES_DIR"
printf 'global rules\n' > "$CLAUDE_RULES_DIR/CLAUDE.md"

# A string of n characters, the last m of them two byte ones, so a count of bytes and a count of
# characters disagree and the test can tell which the notice gave.
chars() { python3 -c 'import sys; n, m = int(sys.argv[1]), int(sys.argv[2]); sys.stdout.write("x" * (n - m) + "é" * m)' "$1" "$2"; }

# world <name>: an origin, a seed clone that pushes to it, and the primary checkout, all current.
# The primary's CLAUDE.md is 1,200 characters (1,300 bytes) and imports docs/rules.md.
W=""
world() {
  W="$TMPROOT/$1"
  mkdir -p "$W"
  git init -q --bare "$W/origin.git"
  git clone -q "$W/origin.git" "$W/seed" 2>/dev/null
  { chars 1184 100; printf '\n@docs/rules.md\n'; } > "$W/seed/CLAUDE.md"
  mkdir -p "$W/seed/docs" "$W/seed/src"
  printf 'imported rules\n' > "$W/seed/docs/rules.md"
  printf 'agents\n' > "$W/seed/AGENTS.md"
  printf 'code\n' > "$W/seed/src/app.ts"
  printf 'node_modules/\n' > "$W/seed/.gitignore"
  git -C "$W/seed" add -A
  git -C "$W/seed" commit -q -m first
  git -C "$W/seed" push -q origin main 2>/dev/null
  git clone -q "$W/origin.git" "$W/primary" 2>/dev/null
}
# upstream <path> <content...>: a commit on origin that the primary has fetched but not merged.
upstream() {
  local path="$1"; shift
  mkdir -p "$(dirname "$W/seed/$path")"
  printf '%s' "$*" > "$W/seed/$path"
  git -C "$W/seed" add -A
  git -C "$W/seed" commit -q -m "change $path"
  git -C "$W/seed" push -q origin main 2>/dev/null
  git -C "$W/primary" fetch -q origin 2>/dev/null
}
start() { # start <session> <cwd> [source] -> the hook's stdout at SessionStart
  python3 - "$1" "$2" "${3:-startup}" <<'PY' | bash "$HOOK" 2>/dev/null
import json, sys
print(json.dumps({"session_id": sys.argv[1], "cwd": sys.argv[2], "hook_event_name": "SessionStart", "source": sys.argv[3]}))
PY
}
prompt() { # prompt <session> <cwd> -> the hook's stdout at UserPromptSubmit
  python3 - "$1" "$2" <<'PY' | bash "$HOOK" 2>/dev/null
import json, sys
print(json.dumps({"session_id": sys.argv[1], "cwd": sys.argv[2], "hook_event_name": "UserPromptSubmit", "prompt": "go on"}))
PY
}
msg() { # the systemMessage of one hook output, or nothing
  printf '%s' "$1" | python3 -c 'import json, sys
try:
    print(json.loads(sys.stdin.read()).get("systemMessage", ""))
except Exception:
    pass' 2>/dev/null
}
ctx() {
  printf '%s' "$1" | python3 -c 'import json, sys
try:
    print(json.loads(sys.stdin.read())["hookSpecificOutput"]["additionalContext"])
except Exception:
    pass' 2>/dev/null
}
silent() { # silent <description> <output>
  [ -z "$2" ] && check "$1" ok || check "$1" "said: $2"
}

# ---------------------------------------------------------------------------
# 1. A current checkout says nothing.
# ---------------------------------------------------------------------------
world current
silent "a checkout current with origin says nothing at session start" "$(start s-current "$W/primary")"

# ---------------------------------------------------------------------------
# 2. Behind, with CLAUDE.md changed upstream: said once, with the counts, and the fast forward.
# ---------------------------------------------------------------------------
world behind
upstream CLAUDE.md "$(chars 400 0)"
upstream src/app.ts "more code"
head_before="$(git -C "$W/primary" rev-parse HEAD)"
out="$(start s-behind "$W/primary")"
m="$(msg "$out")"
v="$(hook_notice_verdict "$out" 'CLAUDE\.md')"
[ -z "$v" ] && check "a checkout behind origin on CLAUDE.md is said at session start, as one JSON notice" ok \
  || check "a checkout behind origin on CLAUDE.md is said at session start, as one JSON notice" "$v"
case "$m" in *"1,200"*"400"*) check "the notice gives the characters loaded and the characters on origin" ok ;;
  *) check "the notice gives the characters loaded and the characters on origin" "said: $m" ;; esac
case "$m" in *"1,300"*) check "the counts are characters, not bytes" "gave the byte count: $m" ;;
  *) check "the counts are characters, not bytes" ok ;; esac
case "$m" in *"2 commits behind origin/main"*) check "the notice says how far behind the checkout is" ok ;;
  *) check "the notice says how far behind the checkout is" "said: $m" ;; esac
case "$m" in *"$W/primary"*) check "the notice names the checkout" ok ;;
  *) check "the notice names the checkout" "said: $m" ;; esac
case "$m" in *"git -C '$W/primary' pull --ff-only"*) check "a clean checkout is offered the one fast forward command" ok ;;
  *) check "a clean checkout is offered the one fast forward command" "said: $m" ;; esac
case "$m" in *" ago"*) check "the notice says how old the origin ref it compared against is" ok ;;
  *) check "the notice says how old the origin ref it compared against is" "said: $m" ;; esac
case "$m" in *"docs/rules.md"*|*"AGENTS.md"*) check "a rule file identical to origin is not named" "named one: $m" ;;
  *) check "a rule file identical to origin is not named" ok ;; esac
case "$(ctx "$out")" in *"show origin/main:CLAUDE.md"*) check "the session is told how to read the current copy" ok ;;
  *) check "the session is told how to read the current copy" "context: $(ctx "$out")" ;; esac
[ "$(git -C "$W/primary" rev-parse HEAD)" = "$head_before" ] && [ -z "$(git -C "$W/primary" status --porcelain)" ] \
  && check "the hook never moves or touches the checkout" ok \
  || check "the hook never moves or touches the checkout" "HEAD or the tree changed"
silent "the same session starting again (a compaction or resume) is not told twice" "$(start s-behind "$W/primary" compact)"
silent "and its prompts never repeat it" "$(prompt s-behind "$W/primary")"
m2="$(msg "$(start s-behind-2 "$W/primary")")"
case "$m2" in *CLAUDE.md*) check "a new session, which loaded the stale copy too, is told" ok ;;
  *) check "a new session, which loaded the stale copy too, is told" "said: $m2" ;; esac

# The age, rendered from a set clock rather than this machine's (L713).
touch -t 202601010000 "$W/primary/.git/FETCH_HEAD" "$W/primary/.git/refs/remotes/origin/main" "$W/primary/.git/logs/refs/remotes/origin/main" 2>/dev/null
now="$(python3 -c 'import os, time; print(int(os.path.getmtime(os.sys.argv[1])) + 3 * 3600 + 60)' "$W/primary/.git/FETCH_HEAD")"
m3="$(msg "$(PROJECT_RULES_NOW="$now" start s-behind-3 "$W/primary")")"
case "$m3" in *"3 hours ago"*) check "the age of the origin ref is read from its files, against the clock given" ok ;;
  *) check "the age of the origin ref is read from its files, against the clock given" "said: $m3" ;; esac

# ---------------------------------------------------------------------------
# 3. Behind, but only on code: the rule files are what the session would load anyway. Nothing.
# ---------------------------------------------------------------------------
world code-only
upstream src/app.ts "new code"
silent "a checkout behind origin only on code says nothing" "$(start s-code "$W/primary")"

# ---------------------------------------------------------------------------
# 4. An imported rule file and AGENTS.md are rule files too.
# ---------------------------------------------------------------------------
world imports
upstream docs/rules.md "imported rules, revised"
upstream AGENTS.md "agents, revised"
m="$(msg "$(start s-imports "$W/primary")")"
case "$m" in *"docs/rules.md"*"AGENTS.md"*|*"AGENTS.md"*"docs/rules.md"*) check "an import of CLAUDE.md and AGENTS.md changed upstream are both named" ok ;;
  *) check "an import of CLAUDE.md and AGENTS.md changed upstream are both named" "said: $m" ;; esac
case "$m" in *"CLAUDE.md ("*) check "CLAUDE.md, identical to origin, is not named among them" "said: $m" ;;
  *) check "CLAUDE.md, identical to origin, is not named among them" ok ;; esac

# ---------------------------------------------------------------------------
# 5. Changes to tracked files withhold the fast forward; untracked and ignored files do not.
# ---------------------------------------------------------------------------
world dirty
upstream CLAUDE.md "short"
printf 'local edit\n' >> "$W/primary/src/app.ts"
m="$(msg "$(start s-dirty "$W/primary")")"
case "$m" in *CLAUDE.md*) check "a checkout with local changes behind on its rules is still told" ok ;;
  *) check "a checkout with local changes behind on its rules is still told" "said: $m" ;; esac
case "$m" in *"pull --ff-only"*) check "a checkout with changes to tracked files is not offered the fast forward" "offered: $m" ;;
  *) check "a checkout with changes to tracked files is not offered the fast forward" ok ;; esac
case "$m" in *"changes to tracked files"*) check "and it says why not" ok ;;
  *) check "and it says why not" "said: $m" ;; esac

world untracked
upstream CLAUDE.md "short"
mkdir -p "$W/primary/node_modules" "$W/primary/.cache"
printf 'x\n' > "$W/primary/node_modules/dep.js"
printf 'x\n' > "$W/primary/.cache/build"
m="$(msg "$(start s-untracked "$W/primary")")"
case "$m" in *"pull --ff-only"*) check "untracked and ignored files alone do not withhold the fast forward" ok ;;
  *) check "untracked and ignored files alone do not withhold the fast forward" "said: $m" ;; esac

# ---------------------------------------------------------------------------
# 6. Local commits on main as well: told, but a fast forward cannot be offered.
# ---------------------------------------------------------------------------
world diverged
upstream CLAUDE.md "short"
printf 'local\n' > "$W/primary/local.txt"
git -C "$W/primary" add local.txt
git -C "$W/primary" commit -q -m local
m="$(msg "$(start s-diverged "$W/primary")")"
case "$m" in *CLAUDE.md*"1 commit origin/main does not have"*) check "a checkout with its own commits is told, and why it is not offered a fast forward" ok ;;
  *) check "a checkout with its own commits is told, and why it is not offered a fast forward" "said: $m" ;; esac
case "$m" in *"pull --ff-only"*) check "a diverged checkout is never offered the fast forward" "offered: $m" ;;
  *) check "a diverged checkout is never offered the fast forward" ok ;; esac

# ---------------------------------------------------------------------------
# 7. A session in a worktree nested inside the primary loads the primary's CLAUDE.md as an ancestor,
#    so it is told about the primary. A primary on another branch says nothing.
# ---------------------------------------------------------------------------
world nested
upstream CLAUDE.md "short"
git -C "$W/primary" worktree add -q "$W/primary/.claude/worktrees/w1" -b w1 2>/dev/null
m="$(msg "$(start s-nested "$W/primary/.claude/worktrees/w1")")"
case "$m" in *"$W/primary"*CLAUDE.md*) check "a session in a worktree nested in the primary is told about the primary" ok ;;
  *) check "a session in a worktree nested in the primary is told about the primary" "said: $m" ;; esac
git -C "$W/primary" worktree add -q "$TMPROOT/outside-w2" -b w2 2>/dev/null
silent "a session in a worktree outside the primary, which does not load its CLAUDE.md, says nothing" "$(start s-outside "$TMPROOT/outside-w2")"
m="$(msg "$(start s-subdir "$W/primary/src")")"
case "$m" in *CLAUDE.md*) check "a session in a folder inside the primary is told" ok ;;
  *) check "a session in a folder inside the primary is told" "said: $m" ;; esac

world branch
upstream CLAUDE.md "short"
git -C "$W/primary" checkout -q -b feature
silent "a primary on a branch other than the default says nothing" "$(start s-branch "$W/primary")"

# ---------------------------------------------------------------------------
# 8. No origin/HEAD recorded: the branch named main is taken as the default.
# ---------------------------------------------------------------------------
world nohead
upstream CLAUDE.md "short"
git -C "$W/primary" remote set-head origin -d
m="$(msg "$(start s-nohead "$W/primary")")"
case "$m" in *CLAUDE.md*) check "a checkout with no origin/HEAD recorded is still judged against origin/main" ok ;;
  *) check "a checkout with no origin/HEAD recorded is still judged against origin/main" "said: $m" ;; esac

# ---------------------------------------------------------------------------
# 9. Not a git checkout at all, and no remote: nothing, and the hook still exits 0.
# ---------------------------------------------------------------------------
mkdir -p "$TMPROOT/plain"
silent "a session outside any git checkout says nothing" "$(start s-plain "$TMPROOT/plain")"
git init -q "$TMPROOT/noremote"
silent "a checkout with no remote says nothing" "$(start s-noremote "$TMPROOT/noremote")"
python3 -c 'import json; print(json.dumps({"session_id": "s-rc", "cwd": "/nonexistent/dir", "hook_event_name": "SessionStart", "source": "startup"}))' \
  | bash "$HOOK" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && check "a cwd that does not exist leaves the hook exiting 0" ok \
  || check "a cwd that does not exist leaves the hook exiting 0" "exit $rc"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
