#!/bin/bash
# check-mod-shared-parts.sh <mods dir>: what every mod shares lives once, in mod-kit, and no other
# mod keeps a copy (L613: the shared component plus the scan that fails on the next hand rolled
# copy). Before batch 2 of the mods milestone three guards each read shell commands their own way,
# and every review found a different hole in a different copy.
#
# The shared parts, each named by the code a copy cannot be written without:
#   reader    splitting a command on shell separators          use $.modkit.commands({ command })
#   quotes    tracking quote characters one by one              use $.modkit.commands({ command })
#   heredoc   reading a heredoc's opening                       use $.modkit.commands({ command })
#   card      drawing a tool result row (the blocked card)      use $.modkit.blocked({ ... })
#   git       listing git's global options to find a subcommand use $.modkit.git({ words })
#
# Only each mod's hooks/ is read: its tests may stand in for mod-kit, since a mod cannot import
# another mod's files.
#
# Exit codes, each distinct (L11): 0 none found (the count is printed, L98), 1 a copy found, each
# named with its file and line, 2 the mods folder does not exist.
dir="${1:-}"
if [ -z "$dir" ] || [ ! -d "$dir" ]; then
  echo "check-mod-shared-parts: '${dir:-<none given>}' is not a folder, so nothing was checked." >&2
  exit 2
fi
dir="${dir%/}"

# name|pattern|remedy. Patterns are extended regular expressions over each source line.
PARTS=(
  "reader|split\(/[^/]*&&|\$.modkit.commands({ command })"
  "quotes|=== '\"' \|\| [a-z]+ === \"'\"|\$.modkit.commands({ command })"
  "heredoc|<<\(\?!<\)|\$.modkit.commands({ command })"
  "card|component: *'ToolResult'|\$.modkit.blocked({ ... })"
  "git|'--work-tree'|\$.modkit.git({ words })"
)

n=0
failed=0
for d in "$dir"/*/; do
  [ -f "$d.claude-plugin/plugin.json" ] || continue
  n=$((n + 1))
  name="$(basename "$d")"
  [ "$name" = mod-kit ] && continue
  [ -d "$d/hooks" ] || continue
  for part in "${PARTS[@]}"; do
    label="${part%%|*}"; rest="${part#*|}"; pattern="${rest%|*}"; remedy="${rest##*|}"
    hits="$(grep -rnE --include='*.ts' --include='*.tsx' --include='*.js' --include='*.mjs' -- "$pattern" "$d/hooks" 2>/dev/null)"
    [ -n "$hits" ] || continue
    failed=1
    while IFS= read -r h; do
      echo "check-mod-shared-parts: $name keeps its own $label at ${h#"$d"}: use $remedy from mod-kit instead."
    done <<< "$hits"
  done
done
echo "check-mod-shared-parts: $n mods checked in $dir"
exit "$failed"
