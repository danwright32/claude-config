#!/bin/bash
#
# disk-clean-guard.sh: the writing tools the disk-clean harness puts on PATH (claude-config#1804).
#
#   bash disk-clean-guard.sh <tool name> <real binary> [<the tool's own arguments>...]
#
# dc_setup writes one wrapper per tool on DC_GUARDED_TOOLS into the harness's core folder, each
# calling this with its own name and the real binary. Every path the tool would write is resolved
# physically, links included, and the tool runs only when all of them lie strictly inside the root
# DISK_CLEAN_TEST_ROOT names, which must itself be a root the harness accepts. Otherwise it writes
# nothing, says why on stderr, appends the same line to the root's refused.log when there is a valid
# root to append to, and exits 97. A missing or invalid root refuses everything (fail closed).
#
# Which arguments are paths it writes, per tool (options are skipped, with the value of the ones
# that take one; `--` ends them):
#   rm rmdir mkdir touch mv tee cp   every operand (cp's sources too: stricter than needed)
#   ln                               the last operand, the link it creates
#   chmod                            every operand after the mode
#   sed                              only with -i: every operand after the script
#   find                             only with -delete: the starting paths
# The predicates are the harness's own, sourced from beside this file (L261).

name="${1:-}"; real="${2:-}"
shift 2 2>/dev/null || { echo "disk-clean-guard: called without a tool name and its real binary" >&2; exit 97; }
. "${BASH_SOURCE[0]%/*}/disk-clean-harness.sh" || { echo "disk-clean-guard: cannot read the harness beside it, refusing $name" >&2; exit 97; }
root="${DISK_CLEAN_TEST_ROOT:-}"

refuse() {
  local msg="disk-clean harness: refused $name $*"
  msg="$msg: $REASON"
  echo "$msg" >&2
  if [ -n "$root" ] && dc_root_valid "$root"; then printf '%s\n' "$msg" >> "$root/refused.log"; fi
  exit 97
}

if ! dc_root_valid "$root"; then
  REASON="DISK_CLEAN_TEST_ROOT ('$root') is not a throwaway directory the harness made, so nothing may be written"
  refuse "$@"
fi

# The operands of the call, options and their values removed. $1 = the option letters that take a
# value as the next argument.
operands() {
  local takes="$1" a seen_dd=""; shift
  while [ $# -gt 0 ]; do
    a="$1"; shift
    if [ -n "$seen_dd" ]; then printf '%s\n' "$a"; continue; fi
    case "$a" in
      --) seen_dd=1 ;;
      -?*) case "$a" in --*) ;; *) [ "${#a}" -eq 2 ] && case "$takes" in *"${a#-}"*) shift ;; esac ;; esac ;;
      *) printf '%s\n' "$a" ;;
    esac
  done
}

paths=""
case "$name" in
  rm|rmdir|mv|tee|cp) paths="$(operands "" "$@")" ;;
  mkdir) paths="$(operands "m" "$@")" ;;
  touch) paths="$(operands "trdA" "$@")" ;;
  ln) paths="$(operands "" "$@" | tail -n 1)"
      [ "$(operands "" "$@" | wc -l)" -eq 1 ] && paths="${paths##*/}" ;;
  chmod)
    # The mode is the first argument that is not one of chmod's own flags, and may itself start with
    # a dash (-w), so flags are recognised by their letters rather than by the dash.
    rest=""; mode_seen=""
    for a in "$@"; do
      if [ -z "$mode_seen" ]; then
        case "$a" in
          --) continue ;;
          -*) case "${a#-}" in *[!RHLPfhvEINCiV]*) mode_seen=1 ;; *) continue ;; esac ;;
          *) mode_seen=1 ;;
        esac
        continue
      fi
      rest="$rest$a
"
    done
    paths="$rest" ;;
  sed)
    inplace=""
    for a in "$@"; do case "$a" in -i*|--in-place*) inplace=1 ;; esac; done
    if [ -n "$inplace" ]; then
      script_given=""
      for a in "$@"; do case "$a" in -e|-f|-e?*|-f?*|--expression*|--file*) script_given=1 ;; esac; done
      # BSD sed takes -i's backup suffix as the next argument when it is not attached.
      paths="$(operands "ef" "$@")"
      # The first operand is the script when no -e or -f gave one. Dropped in the shell: sed here
      # would be this guard again.
      if [ -z "$script_given" ]; then
        case "$paths" in *$'\n'*) paths="${paths#*$'\n'}" ;; *) paths="" ;; esac
      fi
    fi ;;
  find)
    deletes=""
    for a in "$@"; do [ "$a" = "-delete" ] && deletes=1; done
    if [ -n "$deletes" ]; then
      for a in "$@"; do
        case "$a" in -H|-L|-P|-E|-X|-d|-s|-x) continue ;; -*|'('|'!') break ;; esac
        paths="$paths$a
"
      done
    fi ;;
  *) REASON="$name is not a tool this guard knows which arguments of to check"; refuse "$@" ;;
esac

while IFS= read -r p; do
  [ -n "$p" ] || continue
  if ! dc_inside "$p" "$root"; then
    REASON="$p is outside the throwaway directory $root"
    refuse "$@"
  fi
done <<< "$paths"

exec "$real" "$@"
