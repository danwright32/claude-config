#!/usr/bin/env bash
# placement-copy.sh: a copy of some payload files, placed the way one of the two places a suite
# runs from places them (claude-config#2620).
#
# A suite runs from a checkout's payload/hooks, and from the installed copy in ~/.claude/hooks, where
# the hook suite runs after every claude-sync pull. A check reading a file only the checkout has (the
# repository's README) passes in the first and fails in the second for a reason that says nothing
# about the config just installed, so every pull reported the hook suite FAILED for nothing (L36). A
# suite proves each of its checkout only parts both ways by running a copy of itself in each
# placement: installed, where the part must say it was not measured (L411), and in a fixture checkout
# holding a wrong file, where the part must still fail (L1). Whether a copy is in a checkout is
# decided by lib/checkout-root.sh, the one test of that (#1567), never by this helper.
#
#   . "$DIR/lib/placement-copy.sh"
#   copy="$(placement_copy installed "$TMP/home" "$DIR/.." hooks/test-x.sh hooks/lib)" || ...
#   copy="$(placement_copy checkout "$TMP/repo" "$DIR/.." hooks/test-x.sh hooks/lib)" || ...
#
# installed  copies each path into <into>/.claude, with no repository around it.
# checkout   copies each path into <into>/payload, and makes <into> a git repository holding a
#            claude-sync, the shape lib/checkout-root.sh recognises. Files the caller adds at <into>
#            (a README.md) are then the checkout's.
#
# Prints the copy's payload folder, resolved, and returns 0. Returns 1 with the reason on stderr when
# a path cannot be copied or the repository cannot be made, and 2 for an unknown placement, so a
# caller never runs a copy that is not the one it asked for.

placement_copy() {
  local kind="${1:-}" into="${2:-}" src="${3:-}" root rel dest
  case "$kind" in
    installed) root="$into/.claude" ;;
    checkout) root="$into/payload" ;;
    *) echo "placement_copy: no placement named '$kind' (installed or checkout)" >&2; return 2 ;;
  esac
  shift 3
  mkdir -p "$root" || { echo "placement_copy: could not make $root" >&2; return 1; }
  for rel in "$@"; do
    dest="$root/$rel"
    mkdir -p "${dest%/*}" && cp -R "$src/$rel" "$dest" \
      || { echo "placement_copy: could not copy $src/$rel to $dest" >&2; return 1; }
  done
  if [ "$kind" = checkout ]; then
    : > "$into/claude-sync" && git init -q "$into" >/dev/null 2>&1 \
      || { echo "placement_copy: could not make $into a repository holding claude-sync" >&2; return 1; }
  fi
  (cd "$root" && pwd -P)
}
