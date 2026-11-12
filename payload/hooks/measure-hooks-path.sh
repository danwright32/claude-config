#!/usr/bin/env bash
#
# measure-hooks-path.sh: on THIS Mac, which working trees would the hooks folder push check refuse?
#
# push-scope-notice.sh refuses a push whose core.hooksPath names a missing folder (claude-config#2070)
# and, for an agent, one naming a location holding no hook git would run (#2135). Both were measured
# on the personal MacBook only. The work MacBook installs its hooks with a different command, and
# whether /dev/null there is hooks switched off on purpose or a broken setup was never seen (#2098),
# so the measurement has to be something that Mac can run itself (L177).
#
# For every working tree under the folders given (each repository's linked worktrees included,
# wherever they live) it prints one tab separated line:
#   <working tree> <scope> <value> <kind> main=<verdict> agent=<verdict>
# scope and value are where core.hooksPath is set and to what (unset when it is not); kind is
# unset, folder, missing or "not a folder" (such as /dev/null) for the location git resolves, or
# unreadable when the setting cannot be read, and a worktree list entry gone from disk reads
# "not on disk" with no verdicts; each
# verdict is pass, refused, or "error <exit code>", from the SHIPPING push-scope-notice.sh given a
# plain push from that tree, once as the main session and once carrying an agent's id. It asks the
# gate rather than copying its rules, so the numbers are the gate's own (L107).
#
# Run:  bash ~/.claude/hooks/measure-hooks-path.sh <folder> [<folder>...]
#
# Reads only: git config and the worktree lists, and the gate, which refuses or passes and writes
# nothing. Finding no repository is a refusal, never a clean count (L98), and so is any verdict the
# gate gave as an error.
set -uo pipefail

# Its own folder cut from its path in bash, never by dirname (claude-config#2081, #2130).
case "${BASH_SOURCE[0]}" in */*) _HD="${BASH_SOURCE[0]%/*}" ;; *) _HD=. ;; esac
_HD="$(cd "${_HD:-/}" && pwd)"
GATE="${MEASURE_HOOKS_PATH_GATE:-$_HD/push-scope-notice.sh}"
[ -f "$GATE" ] || { echo "measure-hooks-path: cannot find the gate it asks, $GATE" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "measure-hooks-path: python3 is not on PATH, so no push could be put to the gate" >&2; exit 1; }

[ "$#" -gt 0 ] || { echo "usage: $(basename "$0") <folder> [<folder>...]   (the folders your repositories live in)" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/measure-hooks-path.XXXXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT
: > "$WORK/trees"

for root in "$@"; do
  [ -d "$root" ] || { echo "measure-hooks-path: $root is not a folder" >&2; exit 1; }
  # A .git folder is a repository's main checkout, whose worktree list names every linked worktree
  # wherever it lives; a .git file is a linked worktree. Dependency and build folders hold
  # repositories nobody pushes from.
  # Into a file first, so find has exited before the loop reads (claude-config#2040).
  find "$root" \( -name node_modules -o -name .build -o -name Pods -o -name DerivedData \) -prune -o -name .git -print > "$WORK/found" 2>/dev/null
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    top="$(cd "${g%/.git}" 2>/dev/null && pwd -P)" || continue
    if [ -d "$g" ]; then
      git -C "$top" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' >> "$WORK/trees"
    fi
    printf '%s\n' "$top" >> "$WORK/trees"
  done < "$WORK/found"
done
sort -u "$WORK/trees" > "$WORK/unique"

payload() { # payload <cwd> [agent]: a plain push from that folder, as the hook event carries it
  python3 -c 'import json,sys
p={"tool_name":"Bash","hook_event_name":"PreToolUse","tool_input":{"command":"git push"},"cwd":sys.argv[1]}
if len(sys.argv)>2: p["agent_id"]="measure-hooks-path"
print(json.dumps(p))' "$@"
}
verdict() { # verdict <cwd> [agent]
  local rc
  payload "$@" | bash "$GATE" >/dev/null 2>&1; rc=$?
  case "$rc" in 0) echo pass ;; 2) echo refused ;; *) echo "error $rc" ;; esac
}

for scope in global system; do
  v="$(git config "--$scope" --get core.hooksPath 2>/dev/null)" || v="unset"
  printf '%s core.hooksPath: %s\n' "$scope" "$v"
done
printf 'working tree\tscope\tvalue\tkind\tmain\tagent\n'

n=0; set_n=0; main_ref=0; agent_ref=0; errors=0; gone=0
: > "$WORK/notfolder"
while IFS= read -r wt; do
  [ -n "$wt" ] || continue
  if [ ! -d "$wt" ]; then gone=$((gone + 1)); printf '%s\t-\t-\tnot on disk\t-\t-\n' "$wt"; continue; fi
  n=$((n + 1))
  sv="$(git -C "$wt" config --show-scope --get core.hooksPath 2>/dev/null)"; grc=$?
  if [ "$grc" -eq 1 ]; then scope=unset; value=-; kind=unset
  elif [ "$grc" -ne 0 ]; then scope="unreadable ($grc)"; value=-; kind=unreadable
  else
    set_n=$((set_n + 1))
    scope="${sv%%$'\t'*}"; value="${sv#*$'\t'}"
    where="$(git -C "$wt" rev-parse --git-path hooks 2>/dev/null)"
    case "$where" in /*) ;; *) where="$wt/$where" ;; esac
    if [ ! -e "$where" ]; then kind=missing
    elif [ -d "$where" ]; then kind=folder
    else kind="not a folder"; printf '%s (%s)\n' "$value" "$scope" >> "$WORK/notfolder"
    fi
  fi
  m="$(verdict "$wt")"; a="$(verdict "$wt" agent)"
  [ "$m" = refused ] && main_ref=$((main_ref + 1))
  [ "$a" = refused ] && agent_ref=$((agent_ref + 1))
  case "$m$a" in *error*) errors=$((errors + 1)) ;; esac
  printf '%s\t%s\t%s\t%s\tmain=%s\tagent=%s\n' "$wt" "$scope" "$value" "$kind" "$m" "$a"
done < "$WORK/unique"

echo
printf 'working trees: %s, setting core.hooksPath: %s\n' "$n" "$set_n"
printf 'main session pushes refused: %s, agent pushes refused: %s\n' "$main_ref" "$agent_ref"
sort "$WORK/notfolder" | uniq -c | while read -r count what; do
  printf 'not a folder: %s in %s\n' "$what" "$count"
done
[ "$gone" -eq 0 ] || printf 'listed by a worktree list but not on disk: %s\n' "$gone"

if [ "$n" -eq 0 ]; then
  echo "measure-hooks-path: found no git repository under $*, so there is nothing measured (not zero refusals)." >&2
  exit 1
fi
if [ "$errors" -gt 0 ]; then
  echo "measure-hooks-path: the gate gave an error for $errors working tree(s), so those verdicts are unknown, not passes." >&2
  exit 1
fi
exit 0
