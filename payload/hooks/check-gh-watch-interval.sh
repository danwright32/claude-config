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
# With no python3 the command cannot be read; it says so on stderr and lets the command run (a
# watcher costs points, it does not harm anything).
MIN_INTERVAL=60

payload="$(cat)"
# Every Bash call passes through here, and nearly none mention a watch: answer those at once,
# before the shared reader is even loaded.
case "$payload" in *watch*) ;; *) exit 0 ;; esac
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/push-scope.sh
. "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null || exit 0
command -v python3 >/dev/null 2>&1 || {
  echo "GH WATCH INTERVAL CHECK DID NOT RUN: python3 is not on PATH, and the command's words are read with it, so whether this runs a gh watcher at gh's own short default was not judged." >&2
  exit 0
}

parsed="$(ps_parse_payload "$payload" segmented)" || exit 0
cmd="${parsed%%$'\x1f'*}"
[ -n "$cmd" ] || exit 0

# The gh watcher in one segment, judged: prints the refusal and returns 0 when it is too fast.
too_fast() {   # $1 = one segment
  local -a w
  IFS=$'\x1f' read -r -a w <<< "$(ps__segment_command_words "$1")"
  [ "${#w[@]}" -ge 3 ] || return 1
  [ "${w[0]##*/}" = "gh" ] || return 1
  local kind default
  case "${w[1]} ${w[2]}" in
    "pr checks") kind="pr checks"; default=10 ;;
    "run watch") kind="run watch"; default=3 ;;
    *) return 1 ;;
  esac
  local i n=${#w[@]} t watching=0 interval=""
  [ "$kind" = "run watch" ] && watching=1
  for ((i = 3; i < n; i++)); do
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
  for ((i = 3; i < n; i++)); do
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
  echo "BLOCKED: this gh $kind asks GitHub $said. Each ask spends from the GitHub API allowance (the GraphQL allowance for gh pr checks), 5,000 points an hour that every session, agent and hook on this Mac shares, and when it runs out every gh pr command stalls (claude-config#1014). A check run takes minutes, so ask once a minute. Run instead:" >&2
  echo "  ${fixed[*]} --interval $MIN_INTERVAL" >&2
  return 0
}

segs="$(ps__shell_segments "$cmd")" || exit 0
while IFS= read -r -d $'\x1e' seg; do
  case "$seg" in *watch*) ;; *) continue ;; esac
  too_fast "$seg" && exit 2
done < <(printf '%s' "$segs")
exit 0
