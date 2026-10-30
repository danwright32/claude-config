# The locale a test runs its cases with a byte that is not UTF-8 under, and whether the fault those
# cases guard shows there at all (claude-config#1923). Sourced by test suites; no hook uses it. It is
# named test_ because it is test code: it reads stdin in python3's text mode ON PURPOSE, to see the
# fault, and the scans keeping hook code off that read leave test code alone. Not test-, which
# run-all-tests would run as a suite.
#
# python3's text mode, the Mac's awk, grep and sed, and bash's =~ each trip on such a byte only under
# a UTF-8 locale. The Mac has en_US.UTF-8. Linux often has only C.UTF-8, and a locale a machine does
# not have falls back to C, where none of them trips, so a case pinned to en_US.UTF-8 passed there
# whether or not its fix was in. So a suite asks for a UTF-8 locale this machine HAS, and before it
# trusts a pass, measures that the fault shows under it, saying UNMEASURED where it does not (L411).
#
#   bad_byte_locale                 prints the first of en_US.UTF-8, en_US.utf8, C.UTF-8, C.utf8 that
#                                   `locale -a` lists; prints C and returns 1 when it lists none.
#   bad_byte_measured <kind> <what> returns 0 when <kind> trips on such a byte under that locale here.
#                                   Otherwise prints `SUITE-PART-UNMEASURED <what>: <why>` and
#                                   returns 1. <kind> is python (text mode stdin raises), awk (a
#                                   pattern stops at it), grep (skips the line), sed (refuses it) or
#                                   regex (bash's =~ does not match past it).

bad_byte_locale(){
  local have l
  # Matched in the shell: a grep -q that leaves early would fail the pipe under a caller's pipefail.
  have=$'\n'"$(locale -a 2>/dev/null)"$'\n'
  for l in en_US.UTF-8 en_US.utf8 C.UTF-8 C.utf8; do
    if [[ "$have" == *$'\n'"$l"$'\n'* ]]; then
      printf '%s\n' "$l"
      return 0
    fi
  done
  printf 'C\n'
  return 1
}

bad_byte_measured(){
  local kind="$1" what="$2" loc tripped=1
  if ! loc="$(bad_byte_locale)"; then
    printf 'SUITE-PART-UNMEASURED %s: this machine lists none of en_US.UTF-8, en_US.utf8, C.UTF-8 or C.utf8 in locale -a, so a byte that is not UTF-8 trips nothing here and these cases pass with or without their fix\n' "$what"
    return 1
  fi
  case "$kind" in
    python) printf 'a\377b' | LC_ALL="$loc" python3 -c 'import sys; sys.stdin.read()' >/dev/null 2>&1 || tripped=0 ;;
    awk)    printf 'a\377b\n' | LC_ALL="$loc" awk '/b/ { n++ }' >/dev/null 2>&1 || tripped=0 ;;
    grep)   [ "$(printf 'a\377b x\n' | LC_ALL="$loc" grep -c x 2>/dev/null)" = 1 ] || tripped=0 ;;
    sed)    printf 'a\377b\n' | LC_ALL="$loc" sed 's/b/c/' >/dev/null 2>&1 || tripped=0 ;;
    regex)  LC_ALL="$loc" bash -c '[[ "$0" =~ x ]]' $'\377x' || tripped=0 ;;
    *)
      printf 'SUITE-PART-UNMEASURED %s: bad_byte_measured was asked about %s, which it does not know how to measure\n' "$what" "$kind"
      return 1
      ;;
  esac
  [ "$tripped" -eq 0 ] && return 0
  printf 'SUITE-PART-UNMEASURED %s: %s under %s here reads a byte that is not UTF-8 without tripping, so these cases pass with or without their fix\n' "$what" "$kind" "$loc"
  return 1
}
