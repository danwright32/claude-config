#!/bin/bash
# kept-output.sh: keep a failure's WHOLE output in a folder where it can be read after the run, and
# prune old copies (claude-config#1788, L297). Sourced, never run.
#
# Why: a line reporting a failure carries a few lines of what failed, and the rest lived in a work
# folder removed at the end of the run. A failure seen once, a mod test or a suite that passed when
# run again, then left nothing to diagnose it from, and the only remedy was to reproduce it by hand,
# which is exactly what a flake refuses to do.
#
# Used by tools/check-mods.sh (each refused or failed mod) and run-all-tests.sh (each suite marked
# FLAKY). Each caller chooses its own folder, under ${XDG_CACHE_HOME:-~/.cache}/claude-config/ as the
# runner's suite timings are, and NEVER under the config directory, which mirrors itself to the
# other Mac: a failure on this machine is not configuration.
#
# Each copy is <UTC time>-<label>.<random>.log, so the folder sorts oldest first by name, whatever
# the files' modification times say. After each write the folder is pruned to the newest
# KEPT_OUTPUT_KEEP copies (default 20), judged by that time, and only files named that way are
# ever removed: anything else in the folder is left alone. The copy just written is never pruned.

KEPT_OUTPUT_KEEP="${KEPT_OUTPUT_KEEP:-20}"

# kept_output_save <folder> <label>, with the output on stdin. Sets KEPT_OUTPUT_PATH to the file it
# wrote and returns 0, or sets KEPT_OUTPUT_WHY to why nothing was kept and returns 1. Run in the
# current shell, never in $(...), or the two variables are lost with the subshell.
kept_output_save(){
  KEPT_OUTPUT_PATH=""; KEPT_OUTPUT_WHY=""
  local dir="$1" label keep stamp tmp
  keep="$KEPT_OUTPUT_KEEP"
  case "$keep" in
    ''|*[!0-9]*|0)
      KEPT_OUTPUT_WHY="KEPT_OUTPUT_KEEP must be a whole number above 0, not '$keep'"
      cat > /dev/null; return 1 ;;
  esac
  if [ -z "$dir" ]; then
    KEPT_OUTPUT_WHY="no folder was named to keep it in"
    cat > /dev/null; return 1
  fi
  # Only letters, digits, dot, underscore and hyphen in the name, so a label can never reach outside
  # the folder or break the pattern pruning matches on.
  label="$(printf '%s' "$2" | tr -c 'A-Za-z0-9._-' '_')"
  [ -n "$label" ] || label="output"
  if ! mkdir -p "$dir" 2>/dev/null; then
    KEPT_OUTPUT_WHY="could not create $dir"
    cat > /dev/null; return 1
  fi
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  if ! tmp="$(mktemp "$dir/$stamp-$label.XXXXXX" 2>/dev/null)"; then
    KEPT_OUTPUT_WHY="could not create a file in $dir"
    cat > /dev/null; return 1
  fi
  if ! cat > "$tmp" || ! mv "$tmp" "$tmp.log"; then
    rm -f "$tmp" "$tmp.log" 2>/dev/null
    KEPT_OUTPUT_WHY="could not write the file in $dir"
    return 1
  fi
  KEPT_OUTPUT_PATH="$tmp.log"
  kept_output_prune "$dir" "$keep" "$KEPT_OUTPUT_PATH"
  return 0
}

# kept_output_prune <folder> <keep> <spare>: remove every copy older than the newest <keep>, never
# <spare>. A copy another run removed first is no failure: the goal is that it is gone.
kept_output_prune(){
  local f
  { ls -1 "$1" 2>/dev/null || true; } | { grep -E '^[0-9]{8}T[0-9]{6}Z-.+\.log$' || true; } \
    | LC_ALL=C sort -r | tail -n +"$(( $2 + 1 ))" | while IFS= read -r f; do
      [ "$1/$f" = "$3" ] && continue
      rm -f "$1/$f" 2>/dev/null || true
    done
}
