#!/bin/bash
# check-mods.sh <mods dir>: hold every mod in a folder to what Claude Code itself accepts
# (claude-config#606). A mod is a folder holding .claude-plugin/plugin.json. Each one is run through
# `claude plugin validate`, and through `claude plugin test` when it carries any *.test.ts or
# *.test.tsx of its own. Both commands' exit codes were measured on 2.1.288 before this relied on
# them (2026-10-03): validate exits 1 on a bad event name and on a missing module, test exits 1 on
# a failing test.
#
# Exit codes, each distinct so a caller can never read one as another (L11, L53):
#   0  every mod passed (the count is printed, so zero mods is visibly zero, L98)
#   1  at least one mod failed, each named with the engine's reason
#   2  the mods folder does not exist
#   3  UNMEASURED: mods are present but there is no claude command to ask (L411, L490)
#   4  UNMEASURED: claude answered that hooks modules are switched off in this process (its cached
#      rollout switch, cachedGrowthBookFeatures.tengu_plugin_hooks_modules in the user's
#      .claude.json, or a setting such as disableAllHooks), which no test can set; the engine's
#      words are printed (#740). A definite failure of another mod outranks it, as it outranks 3.
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

# Every mod ships its own tsconfig.json (Dan, 2026-10-04, after #638). Without one, Claude Code
# generates it in the installed copy, and the sync sends that up to main as a local edit. This needs
# only the filesystem, so it is checked before the claude lookup and holds on a machine with none.
failed=0
for d in "${mods[@]}"; do
  if [ ! -f "$d/tsconfig.json" ]; then
    echo "check-mods: $(basename "$d") has no tsconfig.json; every mod ships its own, or the copy Claude Code generates is sent up as a local edit"
    failed=1
  fi
done

bin="${CLAUDE_BIN:-}"
if [ -z "$bin" ]; then
  bin="$(command -v claude 2>/dev/null || true)"
  [ -n "$bin" ] || { [ -x "$HOME/.local/bin/claude" ] && bin="$HOME/.local/bin/claude"; }
fi
if [ -z "$bin" ] || [ ! -x "$bin" ]; then
  echo "check-mods: UNMEASURED: $n mod(s) in $dir, and no claude command to check them with (looked for ${bin:-claude on PATH}). That is not a pass." >&2
  # A missing tsconfig.json is a definite failure, which outranks the unmeasured rest.
  [ "$failed" -eq 1 ] && exit 1
  exit 3
fi

# The engine's verdict lines: the item marks and the failure summary, a few at most. When there is
# no such line, the exit code and the last lines of output instead, never an empty reason (#740).
reason(){   # $1 = output  $2 = exit code
  local r
  r="$(printf '%s\n' "$1" | grep -E '[Ff]ail|[Ee]rror|refused|bad' | sed -n '1,3p' | sed 's/^ *//' | paste -sd';' -)"
  [ -n "$r" ] || r="no verdict line; exit $2, last output: $(printf '%s\n' "$1" | grep -v '^[[:space:]]*$' | tail -n 3 | sed 's/^ *//' | paste -sd';' -)"
  printf '%s' "$r"
}
# Claude Code's refusal to run any plugin's code at all (2.1.289: "hooks modules are turned off in
# this process: ..." or "hooks modules are turned off here (disableAllHooks, ...)"). It says nothing
# about the mod, so the mod is unmeasured, never failed (L411).
switched_off(){ printf '%s\n' "$1" | grep -m1 'hooks modules are turned off' | sed 's/^ *//'; }
unmeasured=0; off_reason=""

for d in "${mods[@]}"; do
  name="$(basename "$d")"
  [ -f "$d/tsconfig.json" ] || continue
  out="$("$bin" plugin validate "$d" 2>&1)"; rc=$?
  off="$(switched_off "$out")"
  if [ -n "$off" ]; then
    echo "check-mods: $name UNMEASURED: claude plugin validate answered: $off"
    unmeasured=1; off_reason="$off"
    continue
  fi
  if [ "$rc" -ne 0 ]; then
    echo "check-mods: $name refused by claude plugin validate: $(reason "$out" "$rc")"
    failed=1
    continue
  fi
  # Its own tests only: what the engine generates under .claude-plugin/types/ is not the mod's.
  # Both .test.ts and .test.tsx (UI tests that mount a component, #655).
  if [ -n "$(find "$d" \( -name '*.test.ts' -o -name '*.test.tsx' \) -not -path "$d/.claude-plugin/types/*" 2>/dev/null)" ]; then
    out="$("$bin" plugin test "$d" 2>&1)"; rc=$?
    off="$(switched_off "$out")"
    if [ -n "$off" ]; then
      echo "check-mods: $name UNMEASURED: claude plugin test answered: $off"
      unmeasured=1; off_reason="$off"
      continue
    fi
    if [ "$rc" -ne 0 ]; then
      echo "check-mods: $name failed claude plugin test: $(reason "$out" "$rc")"
      failed=1
      continue
    fi
  fi
  echo "check-mods: $name ok"
done
echo "check-mods: $n mods checked in $dir"
[ "$failed" -eq 1 ] && exit 1
if [ "$unmeasured" -eq 1 ]; then
  echo "check-mods: UNMEASURED: Claude Code has hooks modules switched off in this process, so its mods could not be checked. That is not a pass. It said: $off_reason" >&2
  exit 4
fi
exit 0
