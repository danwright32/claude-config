#!/usr/bin/env bash
#
# sync-commands.sh: does the claude-sync on this Mac have the commands this config's hooks call?
# (claude-config#379)
#
# The payload and the tool travel separately. The payload reaches a Mac through an apply, while
# each clone of the tool updates when that clone next pulls, so a config change can ship a hook
# calling a command the deployed copy does not have. Measured 2026-09-11:
# payload/hooks/lesson-entry-check.sh calls `claude-sync lesson-faults`, and ~/claude-config-sync
# answered `unknown command 'lesson-faults'` because it had not pulled since the command was added.
# The hook read that refusal as a verdict about the lesson and blocked the edit saying the file
# could not publish, which is a claim it never measured (L11, L640).
#
# BOTH SIDES ARE DERIVED, neither is a list somebody maintains. What the tool offers comes from its
# own dispatch, and what the hooks need comes from the hooks. A registry written by hand checks
# only what it lists, so anything missing from it is exempt from the check meant to catch it
# (L41, L96).
#
# Sourced, never executed.

# The commands a claude-sync offers, read from its DISPATCH rather than from the usage text beside
# it: a command that exists and is undocumented would read as missing, and a documented one that
# was removed would read as present (L41, L400).
#
# A tool this cannot read answers NOTHING. Nothing must never read as "offers everything", which is
# what a caller treating an empty answer as satisfaction would do (L98, L215).
sc_commands_offered(){   # $1 = path to a claude-sync -> one command per line, sorted
  [ -f "${1:-}" ] || return 0
  awk '
    inblock && /^[[:space:]]*esac[[:space:]]*$/ { inblock = 0 }
    inblock {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      # `label)` or `label|other)`, before any command on the same line. A `*)` catch all is not a
      # command anybody can call.
      if (match(line, /^[a-z0-9|_-]+\)/)) {
        labels = substr(line, 1, RLENGTH - 1)
        n = split(labels, parts, "|")
        for (i = 1; i <= n; i++) if (parts[i] != "" && parts[i] != "*") print parts[i]
      }
    }
    /^case "\$cmd" in[[:space:]]*$/ { inblock = 1 }
  ' "$1" 2>/dev/null | sed 's/^-*//' | grep -vE '^(h|help)$' | sort -u
  return 0
}

# The claude-sync commands the hooks in a directory actually CALL. Read from the two shapes a hook
# uses, `"$sync" <command>` and `claude-sync <command>`, in COMMAND position, and then kept only if
# the tool has ever heard of it, which throws away the prose (L673).
#
# A comment or a message that NAMES a command is not a call. A file explaining what to run has to
# write the command down, and reading that as a dependency is the shape where a script matches
# itself because it has to name the thing it looks for (L245).
sc_commands_needed(){   # $1 = hooks directory, $2 = path to a claude-sync -> one per line, sorted
  local offered
  offered="$(sc_commands_offered "${2:-}")"
  [ -n "$offered" ] || return 0
  [ -d "${1:-}" ] || return 0
  # ONLY the form a hook actually invokes it by: the tool's path in a variable, then the command.
  # A bare `claude-sync <word>` is how a hook WRITES ABOUT the tool, in a comment or in a message
  # telling somebody what to run, and counting those made `status` a dependency of a hook that only
  # mentions it. Comment lines are dropped first for the same reason (L245, L673).
  grep -rhv '^[[:space:]]*#' "$1" 2>/dev/null \
    | grep -ohE '"[$][A-Za-z_][A-Za-z0-9_]*"[[:space:]]+[a-z0-9-]+' \
    | awk '{print $2}' | sort -u | while IFS= read -r c; do
    [ -n "$c" ] || continue
    case "
$offered" in *"
$c"*) printf '%s\n' "$c" ;; esac
  done
  return 0
}

# What to say about one clone. Silent when it has everything, because a line on every apply is the
# noise this exists to prevent (L36). A clone this cannot read is its own answer, never the same
# silence as one that has everything (L98, L11).
sc_report_missing(){   # $1 = hooks dir, $2 = the tool the payload was built against, $3 = the clone to judge
  local needed offered missing="" c
  needed="$(sc_commands_needed "${1:-}" "${2:-}")"
  [ -n "$needed" ] || return 0
  if [ ! -f "${3:-}" ]; then
    echo "claude-sync: the clone at $(dirname "${3:-an unnamed path}") could not be read, so whether it has the commands this config's hooks call cannot be answered from here."
    return 0
  fi
  offered="$(sc_commands_offered "$3")"
  if [ -z "$offered" ]; then
    echo "claude-sync: no command could be read out of ${3}, so whether it has the commands this config's hooks call cannot be answered from here."
    return 0
  fi
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    case "
$offered" in *"
$c"*) ;; *) missing="${missing:+$missing }$c" ;; esac
  done <<NEEDED
$needed
NEEDED
  [ -n "$missing" ] || return 0
  echo "claude-sync: the clone at $(dirname "$3") does not have the command(s) this config's hooks call: $missing. Those hooks will refuse work for a reason that has nothing to do with the work until it catches up. Update it with: git -C $(dirname "$3") pull"
  return 0
}
