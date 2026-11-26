#!/bin/bash
# PreToolUse gate: refuse a Bash command that runs the web guidance tool at any version but the pinned
# one (claude-config#3565).
#
# WHY. The tool is the npm package of Google Chrome's Modern Web Guidance, run with npx before any web
# design work. npx downloads and runs whatever version the command names, and @latest, or no version
# at all, means whichever release is newest that minute, on Dan's Mac, under his login, with no
# prompt. Its version is pinned in hooks/lib/<package>-version, and the rule file names that version.
# But the plugin's own skill text, which updates itself, tells sessions to run @latest, and a session
# can ignore a line in a rule file. It cannot get past a gate.
#
# WHAT IT DOES. Refuses (exit 2) any command that RUNS the package (npx, bunx, npm exec, npm x, npm
# install, pnpm dlx or yarn dlx naming it) with any version but the pin, or with none, and names the
# pinned command to run instead. The judgement is lib/web-guidance-pin.py's `judge`, over
# lib/shell-words.py, the one reading every gate uses: so behind env, rtk, a cd, in a chain or inside
# a `bash -c` string all count, while a grep, an echo, a commit message or `npm view` only mention it
# and pass.
#
# When it cannot read the command (no python3, a library missing, a payload nothing can read) and the
# text names the package, it refuses, saying it could not judge: what is at stake is running an
# unread release, and a reader that is missing must not read as a command that is safe (L42, L98). A
# command not naming the package passes before anything is loaded.
#
# No override. Moving to a newer version is a pull request that changes the pin file, after reading
# npm diff between the two versions.

payload="$(cat)"
# Every Bash call passes through here, and nearly none name the package: answer those at once.
case "$payload" in *modern-web-guid*) ;; *) exit 0 ;; esac

# Refuse, saying the command could not be read rather than that it runs an unpinned version.
not_judged() {   # $1 = what went wrong, as a clause
  echo "BLOCKED (web-guidance-pin-gate.sh): this command names the web guidance tool, and whether it runs a version other than the pinned one could not be read: $1. Only the pinned version, written in ~/.claude/hooks/lib/, is run (claude-config#3565), so it is refused rather than guessed at." >&2
  exit 2
}

# Its own folder cut from its path in bash, never by dirname (claude-config#2081, #2130).
case "${BASH_SOURCE[0]}" in */*) HOOK_DIR="${BASH_SOURCE[0]%/*}" ;; *) HOOK_DIR=. ;; esac
HOOK_DIR="$(cd "${HOOK_DIR:-/}" && pwd)"
# shellcheck source=lib/push-scope.sh
. "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null \
  || not_judged "$HOOK_DIR/lib/push-scope.sh, the reader of the payload, could not be loaded (reinstall the hooks with claude-sync pull)"

command -v python3 >/dev/null 2>&1 \
  || not_judged "python3 is not on PATH, and the command's words are read with it"

# Taken raw above so the commonest call leaves before anything loads, and cleaned before anything
# parses it: a lone surrogate escape made jq read nothing (claude-config#1944).
payload="$(ps_clean_payload "$payload")"
parsed="$(ps_parse_payload "$payload" segmented)" \
  || not_judged "it could not read the hook payload (neither jq nor python3 could parse it as JSON)"
cmd="${parsed%%$'\x1f'*}"
[ -n "$cmd" ] || exit 0

JUDGE="$HOOK_DIR/lib/web-guidance-pin.py"
[ -f "$JUDGE" ] || not_judged "$JUDGE, which holds the pin and judges the command, is missing (reinstall the hooks with claude-sync pull)"
said="$(printf '%s' "$cmd" | python3 "$JUDGE" judge 2>&1)"; rc=$?
case "$rc" in
  10) exit 0 ;;
  0) echo "BLOCKED (web-guidance-pin-gate.sh): $said" >&2; exit 2 ;;
  *) not_judged "lib/web-guidance-pin.py could not judge it (exit $rc: ${said##*$'\n'})" ;;
esac
