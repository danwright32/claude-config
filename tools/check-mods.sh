#!/bin/bash
# check-mods.sh <mods dir>: hold every mod in a folder to what Claude Code itself accepts
# (claude-config#606). A mod is a folder holding .claude-plugin/plugin.json. Each one is run through
# `claude plugin validate`, and through `claude plugin test` when it carries any *.test.ts of its
# own. Both commands' exit codes were measured on 2.1.288 before this relied on them (2026-10-03):
# validate exits 1 on a bad event name and on a missing module, test exits 1 on a failing test.
#
# Exit codes, each distinct so a caller can never read one as another (L11, L53):
#   0  every mod passed (the count is printed, so zero mods is visibly zero, L98)
#   1  at least one mod failed, each named with the engine's reason
#   2  the mods folder does not exist
#   3  UNMEASURED: mods are present but there is no claude command to ask (L411, L490)
#
# CLAUDE_BIN names the claude command; left unset it is found on PATH, then at ~/.local/bin/claude.
dir="${1:-}"
if [ -z "$dir" ] || [ ! -d "$dir" ]; then
  echo "check-mods: '${dir:-<none given>}' is not a folder, so nothing was checked." >&2
  exit 2
fi
dir="${dir%/}"

mods=()
for d in "$dir"/*/; do
  [ -f "$d.claude-plugin/plugin.json" ] && mods+=("${d%/}")
done
n=${#mods[@]}
if [ "$n" -eq 0 ]; then
  echo "check-mods: 0 mods checked in $dir"
  exit 0
fi

bin="${CLAUDE_BIN:-}"
if [ -z "$bin" ]; then
  bin="$(command -v claude 2>/dev/null || true)"
  [ -n "$bin" ] || { [ -x "$HOME/.local/bin/claude" ] && bin="$HOME/.local/bin/claude"; }
fi
if [ -z "$bin" ] || [ ! -x "$bin" ]; then
  echo "check-mods: UNMEASURED: $n mod(s) in $dir, and no claude command to check them with (looked for ${bin:-claude on PATH}). That is not a pass." >&2
  exit 3
fi

# The engine's verdict lines: the item marks and the failure summary, a few at most.
reason(){ printf '%s\n' "$1" | grep -E '[Ff]ail|[Ee]rror|refused|bad' | sed -n '1,3p' | sed 's/^ *//' | paste -sd';' -; }

failed=0
for d in "${mods[@]}"; do
  name="$(basename "$d")"
  # Every mod ships its own tsconfig.json (Dan, 2026-10-04, after #638). Without one, Claude Code
  # generates it in the installed copy, and the sync sends that up to main as a local edit.
  if [ ! -f "$d/tsconfig.json" ]; then
    echo "check-mods: $name has no tsconfig.json; every mod ships its own, or the copy Claude Code generates is sent up as a local edit"
    failed=1
    continue
  fi
  if ! out="$("$bin" plugin validate "$d" 2>&1)"; then
    echo "check-mods: $name refused by claude plugin validate: $(reason "$out")"
    failed=1
    continue
  fi
  # Its own tests only: what the engine generates under .claude-plugin/types/ is not the mod's.
  if [ -n "$(find "$d" -name '*.test.ts' -not -path "$d/.claude-plugin/types/*" 2>/dev/null)" ]; then
    if ! out="$("$bin" plugin test "$d" 2>&1)"; then
      echo "check-mods: $name failed claude plugin test: $(reason "$out")"
      failed=1
      continue
    fi
  fi
  echo "check-mods: $name ok"
done
echo "check-mods: $n mods checked in $dir"
exit "$failed"
