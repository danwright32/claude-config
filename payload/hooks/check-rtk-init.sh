#!/bin/bash
# PreToolUse gate: refuse a Bash command that runs `rtk init` (claude-config#1468).
#
# WHY. Measured in claude-config#1446, in a throwaway HOME holding a copy of this config's hook:
# `rtk init -g --auto-patch` deleted hooks/rtk-rewrite.sh and its hash baseline outright, put rtk's
# own built in hook in the settings in its place, and added @RTK.md to CLAUDE.md and wrote its own
# RTK.md. rtk's hook has none of the refusals rtk-rewrite.sh carries: it rewrote `curl -s ...` and
# `npx wrangler --version` and approved them. The same command exists on 0.31.0. Dan decided on
# 2026-10-21 that both Macs stay on rtk 0.31.0 and nobody runs rtk init. That rule lived only in a
# memory note, and a rule that lives only in a prompt is a hope (L27), so it is refused here.
#
# WHAT IT DOES. Refuses (exit 2) any command whose rtk runs its own `init` subcommand, read in
# COMMAND POSITION by lib/push-scope.sh over lib/shell-words.py, the one reading every gate asks: so
# after a cd, in a chain, a subshell or a substitution, by a path to the binary, and behind command,
# env, sudo or exec are all refused, while `echo "rtk init"`, a grep pattern, a commit message or a
# heredoc body only mention it and pass. `rtk git init` is git's init and passes.
#
# Allowed: `rtk init --show`, which in rtk 0.31.0 returns before anything else is read and only
# reads the configuration (src/main.rs, init::show_config), and `rtk init --help` or `-h`, which
# print help and exit. Only when every other word is one of a few that write nothing (-g, --global,
# --codex, -v, --verbose): `--show` beside a flag that writes is refused, erring toward the hook.
#
# When it cannot read the command (no python3, lib/push-scope.sh or lib/shell-words.py missing, a
# payload nothing can read) and the text names both rtk and init, it refuses, saying it could not
# judge: what is at stake is the hook itself, and a reader that is missing must not read as a
# command that is safe (L42, L98). A command naming neither passes before anything is loaded.
#
# Override, explained to Dan first and never silently: SKIP_RTK_INIT_CHECK=1 as an inline prefix on
# the command, good for that one command.

OVERRIDE=SKIP_RTK_INIT_CHECK
DECISION="Dan decided on 2026-10-21 that both Macs stay on rtk 0.31.0 and nobody runs rtk init (claude-config#1468)."
HARM="Measured in claude-config#1446, rtk init -g deletes ~/.claude/hooks/rtk-rewrite.sh and its hash baseline, installs rtk's own hook with none of this config's refusals (it rewrote curl and npx wrangler and approved them), and adds @RTK.md to CLAUDE.md. The other forms write rtk's own setup too and were not measured, so they are refused with it."
ASK="If running it really is intended, ask Dan first, then add $OVERRIDE=1 to that one command."

payload="$(cat)"
# Every Bash call passes through here, and nearly none name rtk and init: answer those at once,
# before the shared reader is even loaded.
case "$payload" in *rtk*) ;; *) exit 0 ;; esac
case "$payload" in *init*) ;; *) exit 0 ;; esac

# Refuse, saying the command could not be read rather than that it runs rtk init.
not_judged() {   # $1 = what went wrong, as a clause
  case "$payload" in *"$OVERRIDE=1"*) exit 0 ;; esac
  echo "BLOCKED: this command names rtk and init, and whether it runs rtk init could not be read: $1. $HARM So it is refused rather than guessed at. $DECISION $ASK" >&2
  exit 2
}

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
ps_has_override "$cmd" "$OVERRIDE" && exit 0

# Read once, here. Exit 3 is a reading from the crude cut at every separator, which still holds
# every command.
ps__read "$cmd"
case $? in
  0|3) ;;
  *)
    if [ -f "$PS_SHELL_WORDS" ]; then not_judged "$PS_SHELL_WORDS could not read the command"; fi
    not_judged "$PS_SHELL_WORDS, the reader of the command, is missing (reinstall the hooks with claude-sync pull)" ;;
esac

# True when the words after init only read: --show or a help flag, beside nothing that writes.
only_reads() {
  local w reads=0
  for w in ${PS_RUN_ARGS[@]+"${PS_RUN_ARGS[@]}"}; do
    case "$w" in
      --show|-h|--help) reads=1 ;;
      -g|--global|--codex|-v|-vv|-vvv|--verbose) ;;
      *) return 1 ;;
    esac
  done
  [ "$reads" = 1 ]
}

i="${PS__M_FIRST[$PS__HIT]}"; end=$((i + PS__M_COUNT[PS__HIT]))
while [ "$i" -lt "$end" ]; do
  if ps_runs_at rtk "$i" init && ! only_reads; then
    echo "BLOCKED: this command runs rtk init, which replaces this config's rtk hook. $HARM $DECISION rtk init --show only reads the configuration and is allowed. $ASK" >&2
    exit 2
  fi
  i=$((i + 1))
done
exit 0
