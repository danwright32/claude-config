#!/usr/bin/env bash
#
# no-verify-gate.sh
# Claude Code PreToolUse(Bash) hook: refuse an AGENT's git command that skips the repository's own
# git hooks (claude-config#1587). Nothing lets one through (claude-config#1666). Also refuses an
# agent's git command reading a file from /dev/stdin, which hangs on a prompt (claude-config#1765).
#
# On 2026-10-23 a Bidspoke builder agent made two commits with `git commit --no-verify` because the
# pre-commit typecheck and lint were slow under load, then handed back "no `--no-verify`, no
# overrides". CI ran every check and they passed, so nothing broken shipped; but nothing refused the
# skip, and the gates this config adds run on a push or a merge, never on a commit, so the
# repository's own hooks are the only check that runs before the commit exists.
#
# WHAT A SKIP IS is lib/agent-overrides.py's one reading (`skips`): --no-verify on any git
# subcommand, commit's -n, a core.hooksPath set with -c, and HUSKY=0 and the other hook managers'
# switches, behind rtk, env, an if or a `bash -c` string alike, and inside a rebase's --exec. Words
# that only mention one (a commit message, an echo, a grep) are not one. Since claude-config#2135 it
# is also a git config that CHANGES core.hooksPath, in any scope and either spelling (set, unset,
# --add, --replace-all, the core section removed or renamed, or --edit): -c moves the hooks for one
# command, a config write moves them for every later one. Reading the key is not a change. An agent
# never writes the setting itself, even to a folder of tracked hooks; it runs the repository's own
# hook install script, which this gate does not read into, so the install keeps working.
#
# Since claude-config#2140 the other routes to the same setting count too: config given to git through
# the environment (GIT_CONFIG_COUNT with its numbered keys, GIT_CONFIG_PARAMETERS, and GIT_CONFIG_GLOBAL,
# GIT_CONFIG_SYSTEM or GIT_CONFIG naming a whole file), git's --config-env, a config include added or
# changed with -c or git config, and a key the shell spells so the gate cannot read it. And because no
# Bash gate sees the file tools, this gate is also registered for Edit, Write and MultiEdit, and
# refuses an agent's edit of a git config file (the repository's or a worktree's, the global one, or
# any file an include names) that changes the hooks location or an include, as git reads them.
#
# WHO IS ASKED is read from agent_id, which only a subagent's payload carries (measured on Claude
# Code 2.1.274, see playwright-subagent-gate.sh). The main session is not judged: Dan sees what it
# runs.
#
# NO APPROVAL. #1587 shipped one, the main session approving one agent for two hours by a file in a
# folder of approvals. Dan removed it on 2026-10-24 ("Remove it", claude-config#1666): an agent could
# write that file itself with the Write tool, which no Bash gate sees. So an agent's skip is always
# refused. The main session, which this gate does not judge, runs where Dan sees it.
#
# An agent's payload this cannot judge (no python3, or the reader missing or failing) is refused when
# it names a skip's words, or standard input's device path (the second rule below), at all: an agent
# can rerun without them, while one let through unread is the defect this exists for (L42, L490).
#
# A SECOND RULE, THE SAME AGENTS' GIT COMMANDS: STANDARD INPUT BY ITS DEVICE PATH (claude-config#1765).
# A worktree subagent's `git commit -F /dev/stdin <<EOF` hung 2 of 2 times (10,469 s on 2026-10-05
# and 1,241 s on 2026-10-26): Claude Code's own worktree check turned the device path into a
# permission prompt, which a background agent can never show, so the call waited until the agent was
# stopped. The same heredoc through `-F -` ran 418 times and never hung, and no hook here asks. So an
# agent's git command reading a file from /dev/stdin or /dev/fd/0 (-F, --file, --file=, a glued -F
# value, or the path as an argument) is refused at once, naming `-F <file>` or `-F -` instead. The
# reading is lib/agent-overrides.py's `stdin-device`, over the same lib/shell-words.py reading, so a
# message or a heredoc body naming the path is not one. A python3 that cannot run refuses a command
# naming the path, as it does a skip's words. Live, Claude Code raises that prompt BEFORE this hook
# runs (checked 2026-10-26), so the hang itself is answered by the job-watcher mod at the permission
# prompt, in the same words (lib/agent-overrides.py stdin-device-refusal); this rule stays for the
# day the hooks run first.
#
# No override.

set -uo pipefail
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
payload="$(cat 2>/dev/null || true)"

# Only a subagent's payload is judged, and most commands name no git at all, so both leave before
# anything starts.
case "$payload" in *'"agent_id"'*) ;; *) exit 0 ;; esac
# A file edit is read whatever it names: a file a config include names need not mention git
# (claude-config#2140).
case "$payload" in *git*|*'"file_path"'*) ;; *) exit 0 ;; esac

refuse() { printf '%s\n' "$1" >&2; exit 2; }

# core.hooksPath as git reads it, in any case (claude-config#2135): a glob, used unquoted in a case
# pattern so its brackets match.
HOOKS_KEY_ANY_CASE='[hH][oO][oO][kK][sS][pP][aA][tT][hH]'
# A config include (include.path, includeIf), in any case, the same way (claude-config#2140).
INCLUDE_ANY_CASE='[iI][nN][cC][lL][uU][dD][eE]'

# EVERY path that cannot read the command judges the same words the reading path acts on: a skip's
# words and standard input's device path (#1765). Three lessons review rounds on #1587 each found a degraded path judging fewer things than the
# normal one, so they share this one list (L370).
refuse_unread() {   # $1 = the text to look in, $2 = why it could not be read
  # git reads the key in any case, so it is matched in any case (claude-config#2135), as are the
  # other ways a git config can change it unread: a section's removal or rename, and an edit.
  # Since claude-config#2140 also config given through the environment or --config-env, a config
  # include in any case, and a git config file's own path, for the file edit route.
  case "$1" in
    *no-verify*|*$HOOKS_KEY_ANY_CASE*|*HUSKY*|*LEFTHOOK*|*SIMPLE_GIT_HOOKS*|*-section*|*config*edit*|*config*-e*|\
    *GIT_CONFIG*|*config-env*|*$INCLUDE_ANY_CASE*|*.git/config*|*config.worktree*|*.gitconfig*)
      refuse "REFUSED (no-verify-gate.sh): this agent's command names a way to skip the repository's git hooks, and $2, so the gate cannot tell what it does. Run the command without it." ;;
    */dev/stdin*|*/dev/fd/0*)
      refuse "REFUSED (no-verify-gate.sh): this agent's command names standard input's device path, and $2, so the gate cannot tell whether git reads it. Write the message to a file and pass -F <file>, or use -F - (claude-config#1765)." ;;
  esac
  exit 0
}

# The payload and the skip are both read with python3. Without it nothing here can tell a skip from
# a mention, so an agent's command naming those words is refused, saying what is missing (L490).
if ! . "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null || ps_reader_missing python3; then
  refuse_unread "$payload" "python3 (or lib/push-scope.sh) is missing; install python3"
fi
# Cleaned before it is parsed: a lone surrogate escape survives python3's parse and raises when the
# command is written back out (claude-config#1944).
payload="$(ps_clean_payload "$payload")"

parsed="$(printf '%s' "$payload" | python3 -c '
import json, sys
sys.stdout.reconfigure(errors="replace")
try:
    d = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace"))
except Exception:
    sys.exit(3)
if not isinstance(d, dict) or "agent_id" not in d:
    sys.exit(4)
ti = d.get("tool_input") or {}
cmd = ti.get("command") if isinstance(ti, dict) else ""
tool = d.get("tool_name")
sys.stdout.write(str(d.get("agent_id") or "") + "\x1f" + (tool if isinstance(tool, str) else "") + "\x1f"
                 + (cmd if isinstance(cmd, str) else ""))
' 2>/dev/null)"; prc=$?
# JSON that parses but is not shaped like a call (the command as a list of its words, the input as
# one string, the payload inside a list) read above as an empty command or a call from nobody, and
# passed in silence. It is judged by every word it holds instead, by the shared rule (#2057).
case "$prc" in 0|4) ps_payload_unread "$payload" command && prc=3 ;; esac
[ "$prc" -eq 4 ] && exit 0
[ "$prc" -eq 0 ] || refuse_unread "$(ps_payload_text "$payload")" "the gate could not read the hook payload as a call"
agent="${parsed%%$'\x1f'*}"
rest="${parsed#*$'\x1f'}"
tool="${rest%%$'\x1f'*}"
cmd="${rest#*$'\x1f'}"
[ -n "$agent" ] || agent="(no id given)"

# AN EDIT, WRITE OR MULTIEDIT OF A GIT CONFIG FILE (claude-config#2140). No Bash gate reads the file
# tools, so an agent writing the hooks location or an include into a git config file with Write moved
# the hooks with nothing refusing it. lib/agent-overrides.py config-edit finds the files git reads
# config from (the repository's, a worktree's, the global ones and every file an include names) and
# compares the hooks location and the includes as git reads them, before the edit and after it.
case "$tool" in
  Edit|Write|MultiEdit)
    ps_payload_unread "$payload" file_path && refuse_unread "$(ps_payload_text "$payload")" "the gate could not read the hook payload as a file edit"
    edit="$(printf '%s' "$payload" | python3 "$HOOK_DIR/lib/agent-overrides.py" config-edit 2>&1)"; erc=$?
    # 10 is the reader's "moves nothing"; 1 is what Python exits on a crash, so it is unread (#1869).
    case "$erc" in
      10) exit 0 ;;
      0) refuse "REFUSED (no-verify-gate.sh): agent $agent: $edit
Hand back to the main session saying which hooks setting the work needs, rather than writing it." ;;
      *) refuse_unread "$(ps_payload_text "$payload")" "lib/agent-overrides.py could not read the edit (exit $erc: ${edit##*$'\n'})" ;;
    esac ;;
  NotebookEdit) exit 0 ;;
esac

# Standard input by its device path first: it hangs the agent rather than skipping a check, and the
# reading is the same one (claude-config#1765). The words come from the library's
# stdin-device-refusal, which the job watcher mod also says at Claude Code's permission prompt (it
# comes BEFORE this hook, so the live hang is answered there), so the two cannot drift (L263, L370).
case "$cmd" in
  */dev/stdin*|*/dev/fd/0*)
    dev="$(printf '%s' "$cmd" | python3 "$HOOK_DIR/lib/agent-overrides.py" stdin-device-refusal "$agent" 2>&1)"; drc=$?
    # 10 is the reader's "no read of the device path"; 1 is what Python exits on a crash, so it is
    # unread like every other code (claude-config#1869, L1033).
    case "$drc" in
      10) ;;
      0) refuse "REFUSED (no-verify-gate.sh): $dev" ;;
      *) refuse_unread "$cmd" "lib/agent-overrides.py could not read it (exit $drc: ${dev##*$'\n'})" ;;
    esac ;;
esac

# A git config is read whatever it names, since a section's removal or an edit changes the key
# without naming it (claude-config#2135). So is config through the environment, any -c (whose key the
# shell may spell so no word names it), and a config include (claude-config#2140).
case "$cmd" in
  *commit*|*no-verify*|*$HOOKS_KEY_ANY_CASE*|*HUSKY*|*LEFTHOOK*|*SIMPLE_GIT_HOOKS*|*config*|*CONFIG*|*-c*|*$INCLUDE_ANY_CASE*) ;;
  *) exit 0 ;;
esac

found="$(printf '%s' "$cmd" | python3 "$HOOK_DIR/lib/agent-overrides.py" skips 2>&1)"; rc=$?
# 10 is the reader's "no skip"; 1 is what Python exits on a crash, so it is unread (#1869, L1033).
case "$rc" in
  10) exit 0 ;;
  0) ;;
  *) refuse_unread "$cmd" "lib/agent-overrides.py could not read it (exit $rc: ${found##*$'\n'})" ;;
esac

# A persistent change of where git reads the hooks from has its own remedy: the repository's own
# install script sets the hooks up, and an agent never writes the setting itself (claude-config#2135).
# The advice is chosen by the reader from its reasons, never by searching the found text, which holds
# the command and so whatever its message says (claude-config#2140). Any answer but 0 is no advice:
# the refusal below stands either way.
install=""
advice="$(printf '%s' "$cmd" | python3 "$HOOK_DIR/lib/agent-overrides.py" hooks-location-advice 2>/dev/null)" \
  && install="
$advice"

refuse "REFUSED (no-verify-gate.sh): agent $agent ran a git command that skips the repository's own git hooks:
  ${found//$'\n'/$'\n'  }$install
Those hooks are the only check that runs before the commit exists, and an agent skipping them is what claude-config#1587 records. No agent may skip them (claude-config#1666). Run it without the skip and wait for the hooks in the foreground, however slow they are. If they cannot pass, stop and hand back to the main session saying why. Whatever happens, never report a skip as not having happened."
