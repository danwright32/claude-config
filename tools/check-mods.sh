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
# TSC_BIN names a TypeScript compiler for the strict type check; left unset it is the compiler pinned
# in tools/typescript (installed with `npm ci --prefix tools/typescript`, #803), else tsc on PATH.
# CHECK_MODS_TS_DIR moves where the pin and its record of known type errors are read from, and
# CHECK_MODS_TYPES_HOME where a mod's laid types are borrowed from (default ~/.claude), for tests.
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

# The TypeScript compiler for the strict type check (#758): TSC_BIN, else the pinned one in
# tools/typescript (#803), else tsc on PATH. None is not a failure, since nothing was measured: each
# mod's line says its types were not checked, and the run ends with one UNMEASURED line counting
# them and naming the install command (L411).
TS_DIR="${CHECK_MODS_TS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/typescript}"
tsc="${TSC_BIN:-}"
[ -n "$tsc" ] || { [ -x "$TS_DIR/node_modules/.bin/tsc" ] && tsc="$TS_DIR/node_modules/.bin/tsc"; }
[ -n "$tsc" ] || tsc="$(command -v tsc 2>/dev/null || true)"
[ -n "$tsc" ] && [ -x "$tsc" ] || tsc=""
# Claude Code lays a mod's types only in the copy it loads, ~/.claude/mods/<mod>, and the mirror
# never carries them (README "Mods"), so a mod checked where none are laid borrows that copy's.
TYPES_HOME="${CHECK_MODS_TYPES_HOME:-$HOME/.claude}"
# Type errors already found and recorded, one mod a line: name, count, the issue fixing them (#803).
# A mod at or under its count passes and says so; over it, it fails. A mod not listed must have none.
KNOWN="$TS_DIR/known-type-errors.tsv"
known_of(){ [ -f "$KNOWN" ] && awk -F'\t' -v m="$1" '$1 == m { print $2 "\t" $3; exit }' "$KNOWN"; }
scratch="$(mktemp -d "${TMPDIR:-/tmp}/check-mods.XXXXXX")" || scratch=""
trap '[ -n "$scratch" ] && rm -rf "$scratch"' EXIT
untyped=0; untyped_why=""

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
  # Strict types (#758). Claude Code lays its declarations, and the tsconfig.json every mod's own
  # extends, under .claude-plugin/types once it has loaded the mod; with those and a TypeScript
  # compiler the mod is type checked as its tsconfig.json says (strict, noUncheckedIndexedAccess).
  # Without either it is said on the mod's line, never claimed (L411, L440).
  types="types not checked: no TypeScript compiler (looked for ${TSC_BIN:-$TS_DIR/node_modules/.bin/tsc, then tsc on PATH})"
  checked="$d"
  if [ ! -f "$d/.claude-plugin/types/tsconfig.json" ] && [ -f "$TYPES_HOME/mods/$name/.claude-plugin/types/tsconfig.json" ] && [ -n "$tsc" ] && [ -n "$scratch" ]; then
    # This mod's source beside the types laid for the installed copy of it, in scratch, so nothing
    # is written into either.
    checked="$scratch/$name"
    rm -rf "$checked"; cp -R "$d" "$checked" && rm -rf "$checked/.claude-plugin/types" \
      && cp -R "$TYPES_HOME/mods/$name/.claude-plugin/types" "$checked/.claude-plugin/types" || checked=""
  fi
  if [ -z "$checked" ] || [ ! -f "$checked/.claude-plugin/types/tsconfig.json" ]; then
    types="types not checked: Claude Code has not laid its types here or in $TYPES_HOME/mods/$name"
    untyped=$((untyped + 1)); untyped_why="no types laid for $name"
  elif [ -z "$tsc" ]; then
    untyped=$((untyped + 1)); untyped_why="no TypeScript compiler"
  else
    # Every mod imports its own files as ./x.ts, as the engine loads them, and the tsconfig Claude
    # Code lays does not allow that, so it is allowed here for every mod rather than in each one's
    # own tsconfig.json (lessons review of #797).
    out="$("$tsc" -p "$checked" --noEmit --allowImportingTsExtensions 2>&1)"; trc=$?
    if [ "$trc" -ne 0 ]; then
      # Each error named from the mod's own folder, never the scratch copy it was checked in.
      errs="$(printf '%s\n' "$out" | grep 'error TS' | sed "s#^[^(]*/$name/#$name/#" || true)"
      if [ -z "$errs" ]; then
        # No error TS line: the compiler itself failed (a crash, a config it could not read), so no
        # type check was measured and none is claimed (L11).
        echo "check-mods: $name could not be type checked: the compiler exited $trc without reporting a type error: $(printf '%s\n' "$out" | sed '/^ *$/d' | tail -n 3 | sed 's/^ *//' | paste -sd';' -)"
        failed=1
        continue
      fi
      count="$(printf '%s\n' "$errs" | grep -c 'error TS' || true)"
      rec="$(known_of "$name")"
      if [ -n "$rec" ]; then
        limit="${rec%%$'\t'*}"; issue="${rec#*$'\t'}"
        if [ "$count" -gt "$limit" ] 2>/dev/null; then
          echo "check-mods: $name has more type errors ($count) than the $limit recorded in $KNOWN ($issue): $(printf '%s\n' "$errs" | sed -n '1,3p' | sed 's/^ *//' | paste -sd';' -)"
          failed=1
          continue
        fi
        types="types checked, $count known type errors ($issue)"
        [ "$count" -lt "$limit" ] 2>/dev/null && types="$types, fewer than the $limit recorded: lower the record"
        echo "check-mods: $name ok ($types)"
        continue
      fi
      echo "check-mods: $name fails a strict type check ($count errors): $(printf '%s\n' "$errs" | sed -n '1,3p' | sed 's/^ *//' | paste -sd';' -)"
      failed=1
      continue
    fi
    types="types checked"
    rec="$(known_of "$name")"
    [ -n "$rec" ] && types="types checked, none of the ${rec%%$'\t'*} recorded errors left: remove its line from $KNOWN"
  fi
  echo "check-mods: $name ok ($types)"
done
echo "check-mods: $n mods checked in $dir"
# Never a silent skip (#803): how many mods' types went unchecked, why, and the one command that
# installs the pinned compiler. Said on stderr, and not a failure, since nothing was measured.
if [ "$untyped" -gt 0 ]; then
  echo "check-mods: UNMEASURED: $untyped of $n mods' types were not checked ($untyped_why$([ "$untyped" -gt 1 ] && echo ', among others')). Install the pinned compiler with: npm ci --prefix tools/typescript" >&2
fi
[ "$failed" -eq 1 ] && exit 1
if [ "$unmeasured" -eq 1 ]; then
  echo "check-mods: UNMEASURED: Claude Code has hooks modules switched off in this process, so its mods could not be checked. That is not a pass. It said: $off_reason" >&2
  exit 4
fi
exit 0
