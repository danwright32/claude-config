#!/usr/bin/env bash
#
# stage-workflow.sh: copy a skill's Workflow script into the session scratchpad and print the path
# to hand the Workflow tool (claude-config#587).
#
#   bash ~/.claude/hooks/lib/stage-workflow.sh <workflow script> <scratchpad directory>
#
# The Workflow tool accepts a scriptPath only when it is a path the tool itself returned, or a file
# the session can already read: the working directory, a directory added to the session, or the
# session scratchpad. A skill's own script under ~/.claude is none of those, so passing it is
# refused every time however correct the path is, even after the file has been read in the session
# (seen 2026-09-28 in a /production-ready run). Copying the script unchanged into the scratchpad and
# passing the copy is what works, and this is that copy done the same way by every skill that
# launches a workflow.
#
# On success it prints ONE line, the absolute path of the copy, and nothing else, so a caller can
# pass it verbatim. Every refusal prints a reason on stderr, prints nothing on stdout, and exits
# non zero, so a refusal can never be mistaken for a path.
set -uo pipefail

usage() {
  echo "Usage: stage-workflow.sh <workflow script> <scratchpad directory>" >&2
  echo "  Copies the script into the scratchpad and prints the copy's absolute path." >&2
}

[ "$#" -eq 2 ] || { usage; exit 2; }
src="$1"
dest="$2"

[ -f "$src" ] || { echo "stage-workflow: the workflow script is not a file: $src" >&2; exit 3; }

case "$dest" in
  /*) ;;
  *) echo "stage-workflow: the scratchpad must be an absolute path (the Workflow tool expands nothing), got: $dest" >&2; exit 2 ;;
esac
[ -d "$dest" ] || { echo "stage-workflow: the scratchpad is not a directory: $dest" >&2; exit 3; }

# Resolved through symlinks on both sides, so the config home reached by another name is still the
# config home.
real_dest="$(cd "$dest" && pwd -P)" || { echo "stage-workflow: cannot enter the scratchpad: $dest" >&2; exit 3; }
config_home="${CLAUDE_HOME:-$HOME/.claude}"
real_config=""
[ -d "$config_home" ] && real_config="$(cd "$config_home" && pwd -P)"
if [ -n "$real_config" ]; then
  case "$real_dest/" in
    "$real_config"/*)
      echo "stage-workflow: refusing to stage into the config home ($real_config): that is the folder the Workflow tool refuses. Pass the session scratchpad." >&2
      exit 4 ;;
  esac
fi

# Named under the scratchpad exactly as given, the spelling the session already reads it by.
out="${dest%/}/$(basename "$src")"
# Copied to a temporary name and moved into place, so a reader never sees half a script, and a
# second run in the same session replaces the first copy with the script as installed now.
tmp="$out.tmp.$$"
if ! cp "$src" "$tmp"; then
  rm -f "$tmp"
  echo "stage-workflow: could not copy $src into $dest" >&2
  exit 5
fi
if ! mv -f "$tmp" "$out"; then
  rm -f "$tmp"
  echo "stage-workflow: could not move the copy into place at $out" >&2
  exit 5
fi
# Proved, not assumed: the file the tool will run is byte for byte the skill's script.
cmp -s "$src" "$out" || { echo "stage-workflow: the copy at $out does not match $src" >&2; exit 5; }

printf '%s\n' "$out"
