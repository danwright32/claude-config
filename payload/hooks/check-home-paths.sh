#!/usr/bin/env bash
#
# check-home-paths.sh — refuse a machine specific home directory inside the
# SYNCED config (claude-config#86).
#
# Eight file paths across the synced skills and hooks were written as absolute
# paths under one machine's home directory. On the other Mac they resolved to
# nothing, so the skill silently half worked: six named one account, two named
# another, and `/production-ready` failed its own healthcheck because of it.
#
# The failure is invisible on whichever machine AUTHORED the line, which is what
# makes it worth a guard rather than a habit. It also degrades silently instead
# of erroring, so a skill can go months looking healthy while reading a file that
# is not there. Those eight are fixed; this is what stops the ninth.
#
# What is allowed instead, none of which name a machine:
#   ~/...                       expanded by the shell
#   $HOME/...                   expanded by the shell
#   os.path.expanduser("~/...") expanded by Python
#   __CLAUDE_HOME__/...         claude-sync's own token, rewritten per Mac
#   <HOME>/...                  a placeholder the model substitutes at call time,
#                               for the two Workflow scriptPath values that
#                               expand neither a tilde nor a variable
#
# Deliberate exception, for a line that genuinely has to carry one (an example in
# prose, a test fixture): put the marker `claude-sync-allow-home-path` on the
# SAME line. It is visible in the file it excuses, unlike a list kept here.
#
# Usage:
#   check-home-paths.sh [config-root]
# The default root is the directory holding this hooks folder, which is ~/.claude
# on a live Mac and payload/ in the repo, so the same command means the same thing
# in both places.
#
# Exit 0 = clean. Exit 1 = at least one machine path. Exit 2 = nothing was
# scanned, which is a failure rather than a pass: an empty answer from a scan
# that read no files is indistinguishable from a clean tree (LESSONS.md L98).
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
[ -d "$ROOT" ] || { echo "check-home-paths: no such directory: $ROOT" >&2; exit 2; }

# The synced set, as claude-sync carries it: its MIRROR_DIRS, plus skills, plus
# the top level rule files. This is an INCLUDE list, so if that set ever grows a
# new directory the consequence is that the new one is not scanned, never a false
# alarm. Add it here in the same change (and see claude-sync's MIRROR_DIRS).
#
# settings.json is deliberately NOT scanned. Its hook commands are absolute by
# necessity, and claude-sync already rewrites that one file's home path per Mac
# on send and on apply, which is the mechanism this guard exists to cover the
# gap in rather than to duplicate.
targets=()
for d in hooks agents commands skills; do
  [ -d "$ROOT/$d" ] && targets+=("$ROOT/$d")
done
while IFS= read -r f; do
  [ -n "$f" ] && targets+=("$f")
done < <(find "$ROOT" -maxdepth 1 -type f -name '*.md' 2>/dev/null | sort)

if [ "${#targets[@]}" -eq 0 ]; then
  echo "check-home-paths: found nothing to check under $ROOT (no hooks, agents, commands or skills directory, and no rule files). Refusing to report a clean scan of nothing." >&2
  exit 2
fi

SKIP=(--exclude-dir=.git --exclude-dir=__pycache__ --exclude-dir=node_modules \
      --exclude=*.pyc --exclude=*.conflict-*)

# -I so a binary that happens to hold the bytes is skipped rather than reported
# as a line nobody can read. The allow marker is dropped line by line, so one
# excused line never excuses the rest of its file.
# The name must START with a letter or digit, which is what a real account is
# shaped like. An elided example (a Users path written with dots for the name) is
# how documentation refers to the idea rather than to a machine, and one of those
# already lives in a vendored skill here, so a class that accepted it would open
# with a false alarm nobody could act on (L104, L147).
hits="$(grep -rInE "${SKIP[@]}" '/Users/[A-Za-z0-9][A-Za-z0-9._-]*' "${targets[@]}" 2>/dev/null \
        | grep -v 'claude-sync-allow-home-path' || true)"

scanned="$(find "${targets[@]}" -type f \
             ! -path '*/.git/*' ! -path '*__pycache__*' ! -name '*.pyc' 2>/dev/null | wc -l | tr -d ' ')"
case "$scanned" in ''|*[!0-9]*) scanned=0 ;; esac
if [ "$scanned" -eq 0 ]; then
  echo "check-home-paths: the synced directories under $ROOT are all empty, so nothing was read. Refusing to report a clean scan of nothing." >&2
  exit 2
fi

if [ -n "$hits" ]; then
  echo "check-home-paths: these lines name one machine's home directory, so they are wrong on every other Mac and fail silently there:" >&2
  printf '%s\n' "$hits" | sed 's/^/  /' >&2
  echo "Write the path relative to the home directory instead (a tilde, \$HOME, expanduser, or the __CLAUDE_HOME__ token), or put claude-sync-allow-home-path on the line if it genuinely has to name one." >&2
  exit 1
fi

echo "check-home-paths: $scanned file(s) under $ROOT, no machine specific home paths."
exit 0
