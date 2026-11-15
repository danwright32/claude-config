#!/bin/bash
# PreToolUse gate: refuse `gh issue view --comments` and `gh pr view --comments` as text, which in a
# Bash call prints only part of the thread, or nothing at all (claude-config#2891).
#
# WHY. gh decides how to print a view by whether its output is a terminal, and a Bash call's never is.
# Measured on 2026-11-14 against gh 2.89.0: with the output not a terminal, `gh issue view N
# --comments` prints ONLY the comments, each as author, association, edited and status lines over its
# body, and never the title or the body of the issue. On an issue with no comments it prints nothing
# at all and exits 0. `gh pr view N --comments` is the same. On 2026-11-13 two builders read their
# brief's issue that way, saw nothing, and worked on without knowing anything was missing. The bytes
# were identical through the gh guard on PATH, through `rtk proxy` and through the real binary by its
# path, and the rtk rewrite leaves every gh but gh api unrewritten (#1428), so the fault is gh's own
# and neither rtk nor the rewrite hook drops anything. gh cannot be told to print both, so the command
# is refused, loudly, with the one that does: `--json title,body,comments`.
#
# WHAT IT DOES. Refuses (exit 2) a `gh issue view` or `gh pr view` carrying --comments, -c or
# --comments=true with neither --json nor --web (-w, alone or clustered as -cw), and says the command to run
# instead. The command is read in COMMAND POSITION by push-scope.sh's reader, which reads past rtk
# proxy, env, sudo and a shell's -c, so a view quoted in an argument or a heredoc body is not one.
#
# Nothing to override: the JSON form always passes.
#
# When it cannot judge (no python3, lib/push-scope.sh or lib/shell-words.py missing, a payload nothing
# can read) it lets the command run and says so in one line, a systemMessage on exit 0, so the guard
# being off is never silent (L98, lib/hook-notice.sh, #1912).

payload="$(cat)"
# Nearly every Bash call names no comments flag at all: answer those before anything loads.
case "$payload" in *--comments*|*-c*) ;; *) exit 0 ;; esac
case "$payload" in *view*) ;; *) exit 0 ;; esac
# Its own folder cut from its path in bash, never by dirname (claude-config#2081, #2130).
case "${BASH_SOURCE[0]}" in */*) HOOK_DIR="${BASH_SOURCE[0]%/*}" ;; *) HOOK_DIR=. ;; esac
HOOK_DIR="$(cd "${HOOK_DIR:-/}" && pwd)"
# shellcheck source=lib/hook-notice.sh
. "$HOOK_DIR/lib/hook-notice.sh" 2>/dev/null || hook_allow_notice() {  # the library is missing
  printf '%s\n' "$1" >&2
  printf '{"systemMessage": "%s (lib/hook-notice.sh is missing beside this hook)"}\n' "${1//[^A-Za-z0-9 .,:;()\/_=+#-]/}"; exit 0; }

not_judged() {   # $1 = what went wrong, as a clause
  hook_allow_notice "GH VIEW COMMENTS CHECK DID NOT RUN: $1, so whether this gh view prints only the comments, or nothing, was not judged."
}
# shellcheck source=lib/push-scope.sh
. "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null \
  || not_judged "$HOOK_DIR/lib/push-scope.sh, the reader of the command, could not be loaded (reinstall the hooks with claude-sync pull)"
command -v python3 >/dev/null 2>&1 \
  || not_judged "python3 is not on PATH, and the command's words are read with it"

payload="$(ps_clean_payload "$payload")"
parsed="$(ps_parse_payload "$payload" segmented)" \
  || not_judged "it could not read the hook payload (neither jq nor python3 could parse it as JSON)"
cmd="${parsed%%$'\x1f'*}"
[ -n "$cmd" ] || exit 0

# The view in one segment, judged: prints the refusal and returns 0 when it asks for comments as text.
# The subcommand is found as gh itself finds it, past flags in front of it, by ps_runs_gh (#1188);
# w is then the subcommand's own words, flags in front first.
comments_as_text() {   # $1 = one segment
  local kind extra=""
  if ps_runs_gh "$1" issue view; then kind="issue view"
  elif ps_runs_gh "$1" pr view; then kind="pr view"; extra=",reviews"
  else return 1
  fi
  local -a w=(${PS_RUN_ARGS[@]+"${PS_RUN_ARGS[@]}"})
  local i n=${#w[@]} t comments=0
  for ((i = 0; i < n; i++)); do
    t="${w[$i]}"
    case "$t" in
      --json|--json=*|--web|--web=true|-w) return 1 ;;
      --comments|--comments=true) comments=1 ;;
      # A value flag's value is never a flag of the view's own (`-R acme/c`).
      -R|--repo|-q|--jq|-t|--template) i=$((i+1)) ;;
      -[cw]*) case "$t" in *[!-cw]*) ;; *)
          case "$t" in *w*) return 1 ;; esac
          comments=1 ;; esac ;;
    esac
  done
  [ "$comments" = 1 ] || return 1
  # The command as it should be: the same words, the comments flag replaced by the JSON form.
  local -a fixed=("gh" "$kind")
  for ((i = 0; i < n; i++)); do
    t="${w[$i]}"
    case "$t" in
      --comments|--comments=true|-c) continue ;;
      # A redirection is the shell's, not gh's: left out of the suggestion, with its target.
      '>'|'>>'|'<'|[0-9]'>'|[0-9]'>>') i=$((i+1)); continue ;;
      [0-9]'>'*|'>'*|'<'*|'&>'*) continue ;;
    esac
    fixed+=("$t")
  done
  echo "BLOCKED: this gh $kind --comments would print only the comments, never the title or body, and nothing at all, exiting 0, when there are none. gh prints a view that way whenever its output is not a terminal, and a Bash call's never is, so the thread would read as empty or headless (claude-config#2891). Run instead:" >&2
  echo "  ${fixed[*]} --json title,body,comments$extra" >&2
  return 0
}

ps__read "$cmd"
case $? in
  0|3) ;;
  *)
    if [ -f "$PS_SHELL_WORDS" ]; then not_judged "$PS_SHELL_WORDS could not read the command"; fi
    not_judged "$PS_SHELL_WORDS, the reader of the command, is missing (reinstall the hooks with claude-sync pull)" ;;
esac
segs="$(ps__shell_segments "$cmd")"
while IFS= read -r -d $'\x1e' seg; do
  case "$seg" in *view*) ;; *) continue ;; esac
  comments_as_text "$seg" && exit 2
done <<LOOP_INPUT
$segs
LOOP_INPUT
exit 0
