# lib/mods-replaced.sh: which mods claude-sync replaced on this Mac, and when (claude-config#2514).
#
# The ONE home of this record's shape, for its one writer (claude-sync, after a pull's mirror) and
# its one reader (rule-files-changed.sh, on every prompt), so the two cannot come to read it
# differently (L83, L370). Functions only; it sets no variable of its own.
#
# WHY IT EXISTS. A running session keeps the mod code it loaded until Claude Code reloads that mod,
# and Claude Code does not always: a headless session (claude -p, an SDK host) watches no mod folder
# unless CLAUDE_CODE_PLUGIN_DIR_WATCH is set (measured on Claude Code 2.1.322 on 2026-11-10), and
# its binary shows an interactive one holding, pausing or refusing a reload (read, not measured;
# README "Mods"). On 2026-11-09 a session
# went on running a guard from before the pull that replaced it, and nothing said so. A pull is
# what replaces a mod on this Mac, so a pull records it here, and a session's own hook compares it
# against what that session started with.
#
# THE RECORD: $home/state/mods-replaced.tsv, one line per mod, "<mod folder name> TAB <stamp>". The
# stamp is opaque: it only has to differ between two pulls, and a reader asks only whether it moved.
# state/ is this Mac's own and is never synced, so the record cannot reach the other Mac, whose
# pulls are its own.

# mods_replaced_path_into <variable> <config dir>: sets the variable to the record's path without a
# subshell, which the per prompt reader cannot afford; mods_replaced_file prints it for everyone else.
mods_replaced_path_into(){ printf -v "$1" '%s/state/mods-replaced.tsv' "$2"; }
mods_replaced_file(){ local p; mods_replaced_path_into p "$1"; printf '%s' "$p"; }

# mods_replaced_note <config dir> <applied list> <stamp>
# The applied list is claude-sync's own, "<added|updated|removed> TAB <path under the config dir>".
# Every mod one of whose files the pull wrote or removed gets the stamp; every other line is kept,
# except one naming a mod no longer on disk, which nothing could load. A pull that wrote no mod file
# leaves the record untouched, and so does a missing list. Written beside the record and renamed
# over it, so a reader never meets half a file. Returns 1 when the record could not be written.
mods_replaced_note(){
  local home="$1" applied="$2" stamp="$3" rec names tmp
  [ -s "$applied" ] || return 0
  names="$(awk -F '\t' '$2 ~ /^mods\/[^\/]+\/./ { split($2, p, "/"); if (!(p[2] in seen)) { seen[p[2]] = 1; print p[2] } }' "$applied")"
  [ -n "$names" ] || return 0
  mods_replaced_path_into rec "$home"
  mkdir -p "${rec%/*}" 2>/dev/null || return 1
  tmp="$rec.tmp.$$"
  {
    if [ -f "$rec" ]; then
      awk -F '\t' -v names="$names" -v home="$home" '
        BEGIN { n = split(names, a, "\n"); for (i = 1; i <= n; i++) skip[a[i]] = 1 }
        NF >= 2 && $1 != "" && !($1 in skip) {
          m = home "/mods/" $1 "/.claude-plugin/plugin.json"
          if ((getline line < m) > 0) { close(m); print } else close(m)
        }' "$rec"
    fi
    printf '%s\n' "$names" | while IFS= read -r n; do
      [ -f "$home/mods/$n/.claude-plugin/plugin.json" ] && printf '%s\t%s\n' "$n" "$stamp"
    done
    true
  } > "$tmp" 2>/dev/null && mv -f "$tmp" "$rec" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
}

# mods_replaced_lines <config dir>
# One "@replaced TAB <mod> TAB <stamp>" line per recorded mod that is on disk now (its folder holds
# a manifest, the test the sync and the hook both use for what a mod is). Bash builtins only: this
# runs on every prompt, and a process per prompt is a cost every session pays (#603). A line that
# names a path or a dot name, or carries no stamp, is skipped: it is not one this file's writer wrote.
mods_replaced_lines(){
  local rec n s
  mods_replaced_path_into rec "$1"
  [ -f "$rec" ] || return 0
  while IFS=$'\t' read -r n s; do
    case "$n" in ''|.*|*/*) continue ;; esac
    [ -n "$s" ] || continue
    [ -f "$1/mods/$n/.claude-plugin/plugin.json" ] || continue
    printf '@replaced\t%s\t%s\n' "$n" "$s"
  done < "$rec"
  return 0
}
