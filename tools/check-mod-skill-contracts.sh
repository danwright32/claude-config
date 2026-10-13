#!/bin/bash
# check-mod-skill-contracts.sh <payload dir>: a mod and the skill it enforces carry one contract
# version, and it is the same on both sides (claude-config#1057). A skill is read fresh at every use,
# while a session keeps the mod code it loaded at its start, so a session can follow new steps against
# an old guard: on 2026-10-09 the design round guard from before #1027 ignored the `call` the new
# design rounds skill asked for, recorded Settled for the wrong subject, and refused the edit again,
# so every answer looped (#1046). Now the skill states `<!-- <mod> contract: N -->`, the mod holds
# `export const CONTRACT = N`, and the mod refuses, naming the remedy, an answer newer than it knows.
# That only works while the two numbers are raised together, which is what this holds:
#   - every skill's stamp names a mod in <payload dir>/mods holding CONTRACT, at the same number;
#   - every `"contract": X` the skill's examples carry is that number (an example left at the old
#     one teaches the old form with the skill's authority, L562);
#   - every mod holding CONTRACT is stamped by some skill (a version nothing states guards nothing).
#
# Exit codes, each distinct (L11): 0 every pair agrees (the count is printed, so none is visibly
# none, L98), 1 at least one disagreement, each named, 2 the payload folder is not there.
set -u
dir="${1:-}"
if [ -z "$dir" ] || [ ! -d "$dir/skills" ] || [ ! -d "$dir/mods" ]; then
  echo "check-mod-skill-contracts: '${dir:-<none given>}' holds no skills and mods folders, so nothing was checked." >&2
  exit 2
fi
dir="${dir%/}"
failed=0
pairs=0
stamped_mods=""

# The number a mod's hooks declare, or nothing; more than one declaration is its own failure.
mod_contract(){   # $1 = mod folder
  grep -h -o -E '^export const CONTRACT = [0-9]+' "$1"/hooks/*.ts 2>/dev/null | sed 's/.* = //'
}

for skill in "$dir"/skills/*/SKILL.md; do
  [ -f "$skill" ] || continue
  rel="${skill#"$dir"/}"
  while IFS= read -r stamp; do
    [ -n "$stamp" ] || continue
    mod="$(printf '%s' "$stamp" | sed -E 's/^<!-- *([A-Za-z0-9_-]+) contract: *([0-9]+) *-->$/\1/')"
    n="$(printf '%s' "$stamp" | sed -E 's/^<!-- *([A-Za-z0-9_-]+) contract: *([0-9]+) *-->$/\2/')"
    stamped_mods="$stamped_mods $mod "
    pairs=$((pairs + 1))
    if [ ! -d "$dir/mods/$mod" ]; then
      echo "check-mod-skill-contracts: $rel states contract $n with $mod, and there is no mod called $mod in $dir/mods"
      failed=1
      continue
    fi
    have="$(mod_contract "$dir/mods/$mod")"
    if [ -z "$have" ]; then
      echo "check-mod-skill-contracts: $rel states contract $n with $mod, and $mod declares no CONTRACT in its hooks"
      failed=1
    elif [ "$(printf '%s\n' "$have" | wc -l | tr -d ' ')" -ne 1 ]; then
      echo "check-mod-skill-contracts: $mod declares CONTRACT more than once in its hooks ($(printf '%s' "$have" | tr '\n' ' ')), so which one it knows cannot be told"
      failed=1
    elif [ "$have" != "$n" ]; then
      echo "check-mod-skill-contracts: $rel states contract $n with $mod, and $mod's CONTRACT is $have: raise both together"
      failed=1
    fi
    # Every example of the metadata in the skill carries the same number.
    while IFS= read -r ex; do
      [ -n "$ex" ] || continue
      if [ "$ex" != "$n" ]; then
        echo "check-mod-skill-contracts: $rel shows \"contract\": $ex in an example, and states contract $n with $mod"
        failed=1
      fi
    done < <(grep -o -E '"contract": *[0-9]+' "$skill" | sed -E 's/.*: *//')
  done < <(grep -o -E '<!-- *[A-Za-z0-9_-]+ contract: *[0-9]+ *-->' "$skill")
done

for m in "$dir"/mods/*/; do
  m="${m%/}"
  name="$(basename "$m")"
  [ -n "$(mod_contract "$m")" ] || continue
  case "$stamped_mods" in
    *" $name "*) ;;
    *)
      echo "check-mod-skill-contracts: $name declares a CONTRACT, and no skill in $dir/skills states one with it, so nothing tells a session its steps are newer"
      failed=1
      ;;
  esac
done

[ "$failed" -eq 0 ] && echo "check-mod-skill-contracts: $pairs mod and skill contract pairs checked, all agree"
exit "$failed"
