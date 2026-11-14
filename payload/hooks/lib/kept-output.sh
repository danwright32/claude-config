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
#
# A caller may instead keep copies by AGE PER LABEL (claude-config#2895, L202), by setting all three
# of KEPT_OUTPUT_MAX_DAYS, KEPT_OUTPUT_PER_LABEL and KEPT_OUTPUT_MAX_KB. The newest 20 overall was
# about ten days of flaky suites on the personal MacBook, so a suite that flakes daily pushed out the
# one log an issue had named before anyone opened it. Under this policy a copy stays while it is
# younger than KEPT_OUTPUT_MAX_DAYS by the time in its name, OR while it is among the newest
# KEPT_OUTPUT_PER_LABEL copies of its own label however old, so a rare failure keeps its evidence
# until the same thing fails again. KEPT_OUTPUT_MAX_KB then bounds the folder's total size whatever
# the ages, removing the oldest first, so keeping by age cannot fill the disk. A clock that cannot be
# turned into a date removes nothing by age (the harmless side) and still holds the size cap.
# KEPT_OUTPUT_NOW_EPOCH sets the clock, for tests (L524).

KEPT_OUTPUT_KEEP="${KEPT_OUTPUT_KEEP:-20}"
# The one test of a whole number above zero, 00 included as zero (claude-config#1948). Missing, every
# keep is refused as unreadable and nothing is kept, which the caller already says.
# Its own folder by parameter expansion, never dirname (claude-config#1104, test-lib-self-locate.sh).
_KO_LIB="${BASH_SOURCE[0]%/*}"; [ "$_KO_LIB" != "${BASH_SOURCE[0]}" ] || _KO_LIB=.
# shellcheck source=whole-number.sh
. "$_KO_LIB/whole-number.sh" 2>/dev/null

# kept_output_save <folder> <label>, with the output on stdin. Sets KEPT_OUTPUT_PATH to the file it
# wrote and returns 0, or sets KEPT_OUTPUT_WHY to why nothing was kept and returns 1. Run in the
# current shell, never in $(...), or the two variables are lost with the subshell.
kept_output_save(){
  KEPT_OUTPUT_PATH=""; KEPT_OUTPUT_WHY=""
  local dir="$1" label keep stamp tmp
  if ! keep="$(whole_above_zero "$KEPT_OUTPUT_KEEP")"; then
    KEPT_OUTPUT_WHY="KEPT_OUTPUT_KEEP must be a whole number above 0, not '$KEPT_OUTPUT_KEEP'"
    cat > /dev/null; return 1
  fi
  local by_age="" per="" days="" maxkb=""
  if [ -n "${KEPT_OUTPUT_MAX_DAYS:-}${KEPT_OUTPUT_PER_LABEL:-}${KEPT_OUTPUT_MAX_KB:-}" ]; then
    by_age=1
    if ! days="$(whole_above_zero "${KEPT_OUTPUT_MAX_DAYS:-}")"; then
      KEPT_OUTPUT_WHY="KEPT_OUTPUT_MAX_DAYS must be a whole number above 0, not '${KEPT_OUTPUT_MAX_DAYS:-}'"
      cat > /dev/null; return 1
    fi
    if ! per="$(whole_above_zero "${KEPT_OUTPUT_PER_LABEL:-}")"; then
      KEPT_OUTPUT_WHY="KEPT_OUTPUT_PER_LABEL must be a whole number above 0, not '${KEPT_OUTPUT_PER_LABEL:-}'"
      cat > /dev/null; return 1
    fi
    if ! maxkb="$(whole_above_zero "${KEPT_OUTPUT_MAX_KB:-}")"; then
      KEPT_OUTPUT_WHY="KEPT_OUTPUT_MAX_KB must be a whole number above 0, not '${KEPT_OUTPUT_MAX_KB:-}'"
      cat > /dev/null; return 1
    fi
  fi
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
  if [ -n "$by_age" ]; then
    kept_output_prune_by_age "$dir" "$per" "$days" "$maxkb" "$KEPT_OUTPUT_PATH"
  else
    kept_output_prune "$dir" "$keep" "$KEPT_OUTPUT_PATH"
  fi
  return 0
}

# _kept_output_stamp <epoch seconds>: that instant as the UTC stamp the names carry, by BSD date
# (macOS) or GNU date (CI). Prints nothing and fails when neither can read it.
_kept_output_stamp(){
  local s
  s="$(date -u -r "$1" +%Y%m%dT%H%M%SZ 2>/dev/null || date -u -d "@$1" +%Y%m%dT%H%M%SZ 2>/dev/null)" || return 1
  case "$s" in [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) printf '%s' "$s" ;; *) return 1 ;; esac
}

# kept_output_prune_by_age <folder> <per label> <days> <max KB> <spare>: the policy described at the
# top. One pass over the named copies, newest first by the time in the name; the label is the name
# between the stamp and the random suffix. <spare>, the copy just written, is never removed.
kept_output_prune_by_age(){
  local dir="$1" per="$2" days="$3" maxkb="$4" spare="${5##*/}" now cutoff f spare_size
  # The copy just written counts against the cap from the start, wherever its name sorts.
  spare_size="$(wc -c < "$5" 2>/dev/null | tr -d ' ')" || spare_size=0
  [ -n "$spare_size" ] || spare_size=0
  # A clock that is not a whole number cannot be aged from: everything counts as young.
  cutoff="00000000T000000Z"
  if now="$(whole_above_zero "${KEPT_OUTPUT_NOW_EPOCH:-$(date -u +%s)}")"; then
    cutoff="$(_kept_output_stamp "$(( now - days * 86400 ))")" || cutoff="00000000T000000Z"
  fi
  { ls -1 "$dir" 2>/dev/null || true; } | { grep -E '^[0-9]{8}T[0-9]{6}Z-.+\.log$' || true; } \
    | LC_ALL=C sort -r | while IFS= read -r f; do
      printf '%s\t%s\n' "$f" "$(wc -c < "$dir/$f" 2>/dev/null | tr -d ' ' || true)"
    done \
    | awk -F'\t' -v per="$per" -v cutoff="$cutoff" -v maxb="$(( maxkb * 1024 ))" -v spare="$spare" -v spare_size="$spare_size" '
        BEGIN { total = spare_size + 0 }
        {
          name = $1; size = $2 + 0; stamp = substr(name, 1, 16)
          label = substr(name, 18); sub(/\.[^.]+\.log$/, "", label)
          seen[label]++
          if (name == spare) next
          if (seen[label] > per && stamp < cutoff) { print name; next }
          # Oldest first: once one copy does not fit, every older one goes too, never kept in its place.
          if (full || total + size > maxb) { full = 1; print name; next }
          total += size
        }' \
    | while IFS= read -r f; do
      rm -f "$dir/$f" 2>/dev/null || true
    done
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
