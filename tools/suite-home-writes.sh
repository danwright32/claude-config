#!/usr/bin/env bash
#
# suite-home-writes.sh: does a suite, run on its own, write under ~/.claude? (claude-config#2156)
#
#   bash tools/suite-home-writes.sh <suite> [<suite> ...]
#
# Each suite is run the way a builder runs one before a full run, on its own with no runner around
# it, but under a throwaway HOME, so whatever it would have written into this Mac's real config
# state lands in that HOME instead and can be named. Every file it left under the throwaway HOME's
# .claude, or beside it in a .claude-* store (the issue spool, the sync hold and clone registry),
# fails the suite, named by its path inside that HOME. Nothing is read from any file the suite
# wrote, only its path: those records hold command text (#2126).
#
# The real ~/.claude is never touched. The suite's HOME is the throwaway one, CLAUDE_HOME is cleared
# so nothing is pointed back at the real one, and the seams lib/suite-isolation.sh lists are cleared
# too, along with HOOK_TESTS_RUNNING, so a check run from inside a full run still measures a suite
# started on its own rather than one the runner has already isolated. git still finds this Mac's
# own identity, through GIT_CONFIG_GLOBAL, so a suite that commits in a fixture repository is not
# stopped before it reaches whatever it writes.
#
# Exit 0 when no suite named wrote there, 1 when one did, 2 when it could not run a check at all (a
# suite that is not a file, no throwaway folder). Each suite's own exit status is printed beside
# its verdict, because a suite that stopped at its first line wrote nothing and reads as clean.
set -uo pipefail

_shw_dir="${BASH_SOURCE[0]%/*}"; [ "$_shw_dir" != "${BASH_SOURCE[0]}" ] || _shw_dir=.
_shw_dir="$(cd "${_shw_dir:-/}" && pwd)"
. "$_shw_dir/../payload/hooks/lib/suite-isolation.sh" || {
  echo "suite-home-writes: lib/suite-isolation.sh is missing, so the seams to clear are unknown." >&2
  exit 2
}

[ "$#" -gt 0 ] || { echo "usage: bash tools/suite-home-writes.sh <suite> [<suite> ...]" >&2; exit 2; }

real_home="${HOME%/}"
git_global=""
for _g in "$real_home/.gitconfig" "${XDG_CONFIG_HOME:-$real_home/.config}/git/config"; do
  [ -f "$_g" ] && { git_global="$_g"; break; }
done

unsets=(-u CLAUDE_HOME -u HOOK_TESTS_RUNNING)
for _v in $(suite_isolation_vars); do unsets+=(-u "$_v"); done

worst=0
for suite in "$@"; do
  if [ ! -f "$suite" ]; then
    echo "suite-home-writes: $suite is not a file, so nothing was checked." >&2
    worst=2; continue
  fi
  home="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-suite-work.home.XXXXXXXX" 2>/dev/null)" || home=""
  case "${home%/}" in
    ''|/|"$real_home") echo "suite-home-writes: the throwaway HOME came back as '$home', so $suite was not run." >&2; worst=2; continue ;;
  esac
  out="$home.out"
  if [ -n "$git_global" ]; then
    env "${unsets[@]}" HOME="$home" GIT_CONFIG_GLOBAL="$git_global" bash "$suite" > "$out" 2>&1 </dev/null
  else
    env "${unsets[@]}" HOME="$home" bash "$suite" > "$out" 2>&1 </dev/null
  fi
  rc=$?
  wrote="$(cd "$home" && find .claude .claude-* \( -type f -o -type l \) 2>/dev/null | LC_ALL=C sort)"
  if [ -n "$wrote" ]; then
    n="$(printf '%s\n' "$wrote" | wc -l | tr -d ' ')"
    echo "WRITES-HOME $suite: run on its own it left $n file(s) under ~/.claude (the suite exited $rc):"
    printf '%s\n' "$wrote" | sed 's/^/  ~\//'
    [ "$worst" -eq 2 ] || worst=1
  else
    echo "clean $suite: run on its own it left nothing under ~/.claude (the suite exited $rc)."
  fi
  rm -rf "$home" "$out"
done
exit "$worst"
