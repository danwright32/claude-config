#!/bin/bash
# PreToolUse gate: refuse a gh watcher that would poll GitHub faster than once a minute
# (claude-config#1014).
#
# WHY. `gh pr checks --watch` asks GitHub again every 10 seconds unless told otherwise, and each ask
# costs a point of the GraphQL allowance: 5,000 points an hour per GitHub account, shared by every
# session, agent, hook and mod on the Mac, and when it runs out every `gh pr` command in every
# session stalls (it was down to 436 of 5,000 on 2026-10-09). One watcher at the default is 360
# points an hour. Measured that day with `rateLimit { cost }`: one refresh of a pull request's checks
# costs 1 point, so the cost is set entirely by how often it asks. A check run takes minutes, so a
# watcher that asks once a minute reports a finished run at most a minute late for a sixth of the
# cost. `gh run watch` is the same shape against the REST allowance, at a 3 second default.
#
# WHAT IT DOES. Refuses (exit 2) a `gh pr checks` carrying --watch, or a `gh run watch`, whose
# --interval (or -i) is missing or under MIN_INTERVAL, and says the command to run instead. The
# command is read in COMMAND POSITION by push-scope.sh's reader, so a watcher quoted in an argument
# or written in a heredoc body is not one (L673). An interval it cannot read as a number (a shell
# variable) is left to run: this guards a shared budget, not a person, and a value it cannot see is
# not evidence of a fast one.
#
# Nothing to override: an interval of a minute or more always passes.
#
# When it cannot judge (no python3, lib/push-scope.sh or lib/shell-words.py missing, a payload
# nothing can read) it lets the command run, since a watcher costs points and harms nothing, and says
# so in one line with exit 1 (claude-config#1065): a non-blocking error, the one code for which Claude
# Code shows stderr, so the guard being off is never silent (L98). Exit 0 would throw the line away.
MIN_INTERVAL=60

# Allow the command, saying in one line why it was not judged.
not_judged() {   # $1 = what went wrong, as a clause
  echo "GH WATCH INTERVAL CHECK DID NOT RUN: $1, so whether this runs a gh watcher at gh's own short default was not judged." >&2
  exit 1
}

payload="$(cat)"
# Every Bash call passes through here, and nearly none mention a watch: answer those at once,
# before the shared reader is even loaded.
case "$payload" in *watch*) ;; *) exit 0 ;; esac
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/push-scope.sh
. "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null \
  || not_judged "$HOOK_DIR/lib/push-scope.sh, the reader of the command, could not be loaded (reinstall the hooks with claude-sync pull)"
command -v python3 >/dev/null 2>&1 \
  || not_judged "python3 is not on PATH, and the command's words are read with it"

parsed="$(ps_parse_payload "$payload" segmented)" \
  || not_judged "it could not read the hook payload (neither jq nor python3 could parse it as JSON)"
cmd="${parsed%%$'\x1f'*}"
[ -n "$cmd" ] || exit 0

# The gh watcher in one segment, judged: prints the refusal and returns 0 when it is too fast.
# The subcommand is found as gh itself finds it, past flags written in front of it (`gh -R o/x pr
# checks 12 --watch`, `gh run -R o/x watch 7`), by lib/push-scope.sh's ps_runs_gh, the one reading of
# gh every gate asks (claude-config#1188); w is then the subcommand's own words, flags in front first.
too_fast() {   # $1 = one segment
  local kind default
  if ps_runs_gh "$1" pr checks; then kind="pr checks"; default=10
  elif ps_runs_gh "$1" run watch; then kind="run watch"; default=3
  else return 1
  fi
  local -a w=(${PS_RUN_ARGS[@]+"${PS_RUN_ARGS[@]}"})
  local i n=${#w[@]} t watching=0 interval=""
  [ "$kind" = "run watch" ] && watching=1
  for ((i = 0; i < n; i++)); do
    t="${w[$i]}"
    case "$t" in
      --watch) watching=1 ;;
      --interval=*) interval="${t#--interval=}" ;;
      --interval|-i) interval="${w[$((i+1))]:-}"; i=$((i+1)) ;;
      -i*) interval="${t#-i}" ;;
    esac
  done
  [ "$watching" = 1 ] || return 1
  if [ -n "$interval" ]; then
    case "$interval" in *[!0-9]*) return 1 ;; esac
    [ "$interval" -ge "$MIN_INTERVAL" ] && return 1
  fi
  # The command as it should be: the same words, any interval of its own replaced.
  local -a fixed=("gh" "$kind")
  for ((i = 0; i < n; i++)); do
    t="${w[$i]}"
    case "$t" in
      --interval=*|-i?*) continue ;;
      --interval|-i) i=$((i+1)); continue ;;
      # A redirection is the shell's, not gh's: left out of the suggestion, with its target.
      '>'|'>>'|'<'|[0-9]'>'|[0-9]'>>') i=$((i+1)); continue ;;
      [0-9]'>'*|'>'*|'<'*|'&>'*) continue ;;
    esac
    fixed+=("$t")
  done
  local said="every ${interval:-$default} seconds"
  [ -z "$interval" ] && said="every $default seconds, its default"
  echo "BLOCKED: this gh $kind asks GitHub $said. Each ask spends from the GitHub API allowance (for a pull request's checks, the GraphQL allowance), 5,000 points an hour that every session, agent and hook on this Mac shares, and when it runs out every gh pr command stalls (claude-config#1014). A check run takes minutes, so ask once a minute. Run instead:" >&2
  echo "  ${fixed[*]} --interval $MIN_INTERVAL" >&2
  return 0
}

# Read once, here, so each command's words come from this reading rather than a python start apiece
# (claude-config#1040). Exit 3 is a reading from the crude cut, which still holds every command.
ps__read "$cmd"
case $? in
  0|3) ;;
  *)
    if [ -f "$PS_SHELL_WORDS" ]; then not_judged "$PS_SHELL_WORDS could not read the command"; fi
    not_judged "$PS_SHELL_WORDS, the reader of the command, is missing (reinstall the hooks with claude-sync pull)" ;;
esac
segs="$(ps__shell_segments "$cmd")"
while IFS= read -r -d $'\x1e' seg; do
  case "$seg" in *watch*) ;; *) continue ;; esac
  too_fast "$seg" && exit 2
done < <(printf '%s' "$segs")
exit 0
