#!/usr/bin/env bash
#
# check-home-paths.sh: refuse a machine specific home directory inside the
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
#   the sync's own placeholder, which claude-sync rewrites per Mac (it is not
#   spelled out anywhere in this file, and must not be: see the note below)
#
# One more form is allowed, and only in one place. claude-sync rewrites this Mac's
# config directory to its token in every MIRRORED file on the way out, and expands
# it again per Mac on the way in (claude-config#87), so inside a LIVE config tree
# an absolute path under that same directory is portable: it is what the sync just
# wrote, and it travels correctly. That allowance applies only when the tree being
# scanned IS this machine's config directory, and only under the mirrored
# directories. In the repo, where nothing has been through a send, every machine
# path is still refused, and a path in a top level rule file is refused everywhere,
# because rule files are merged entry by entry and are deliberately not rewritten.
#
# Deliberate exception, for a line that genuinely has to carry one (an example in
# prose, a test fixture): put the marker `claude-sync-allow-home-path` on the
# SAME line. It is visible in the file it excuses, unlike a list kept here.
#
# Usage:
#   check-home-paths.sh [config-root]
#
# CLAUDE_HOME_PATH_ROOTS overrides where home directories live (default "/Users
# /home", which covers a Mac and the Linux runner). It exists so the allowance
# above can be exercised against a throwaway tree on any platform: with the roots
# fixed at /Users, every test of it would be inert on the runner and green for a
# reason that has nothing to do with the rule (L504).
# The default root is the directory holding this hooks folder, which is ~/.claude
# on a live Mac and payload/ in the repo, so the same command means the same thing
# in both places.
#
# Exit 0 = clean. Exit 1 = at least one machine path. Exit 2 = nothing was
# scanned, which is a failure rather than a pass: an empty answer from a scan
# that read no files is indistinguishable from a clean tree (LESSONS.md L98).
# One thing this file must never do: write the sync's placeholder out in full. The
# apply expands that placeholder in EVERY mirrored file, and it cannot tell a line
# that means the placeholder from a line that means a path, so a file discussing it
# has its own text rewritten into somebody's home directory. That is not theoretical:
# the first version of this guard said "or the <placeholder> token" in its failure
# message and the installed copy said "or the /Users/<name>/.claude token"
# (claude-config#99). Assembled from pieces below, and the same rule applies to any
# synced file that has to NAME it.
set -uo pipefail

CS_TOKEN="__CLAUDE""_HOME__"

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
SYNCED_DIRS=(hooks agents commands skills)
targets=()
for d in "${SYNCED_DIRS[@]}"; do
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
# A path under a home directory root, whose account name starts with a letter or digit, which is
# what a real account looks like. Both roots by default: a /home path is as wrong in a synced file
# as a /Users one, and the suite runs on both kinds of machine.
HOME_ROOTS="${CLAUDE_HOME_PATH_ROOTS:-/Users /home}"
_alt=""
for _r in $HOME_ROOTS; do _alt="${_alt:+$_alt|}${_r}"; done
MACHINE_PATH="(${_alt})/[A-Za-z0-9][A-Za-z0-9._-]*"
raw="$(grep -rInE "${SKIP[@]}" "$MACHINE_PATH" "${targets[@]}" 2>/dev/null \
       | grep -v 'claude-sync-allow-home-path' || true)"

# Is the tree being scanned this machine's own config directory? Compared as resolved physical
# paths, because /tmp and /private/tmp are the same directory here and a string comparison would
# answer no on a path that is the same place.
SELF_HOME="${CLAUDE_HOME:-$HOME/.claude}"
self_root=""
[ -d "$SELF_HOME" ] && self_root="$(cd "$SELF_HOME" 2>/dev/null && pwd -P || true)"
scan_root="$(cd "$ROOT" 2>/dev/null && pwd -P || printf '%s' "$ROOT")"
allow_self=0
[ -n "$self_root" ] && [ "$scan_root" = "$self_root" ] && allow_self=1

hits=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  if [ "$allow_self" -eq 1 ]; then
    rel="${line%%:*}"; rel="${rel#"$ROOT"/}"
    mirrored=0
    for d in "${SYNCED_DIRS[@]}"; do
      case "$rel" in "$d"/*) mirrored=1; break ;; esac
    done
    if [ "$mirrored" -eq 1 ]; then
      # The file's own CONTENT, never the whole grep line. That line begins with the path of the
      # file it came from, which is itself under somebody's home directory, so re-testing the
      # whole line answers about the scanned tree's location rather than about what the file says
      # (L135: a check matched over the wrong span is answered by the wrong thing, and this one
      # passed a deliberately broken build because of it).
      content="${line#*:}"; content="${content#*:}"
      # This machine's own config path removed, then the content asked again: what is left is any
      # OTHER machine's home, which is the defect. Done per line, so one portable path never
      # excuses a stale one sitting beside it.
      if ! printf '%s' "${content//$SELF_HOME/}" | grep -qE "$MACHINE_PATH"; then continue; fi
    fi
  fi
  hits="$hits$line
"
done <<HITS
$raw
HITS
hits="${hits%$'\n'}"

scanned="$(find "${targets[@]}" -type f \
             ! -path '*/.git/*' ! -path '*__pycache__*' ! -name '*.pyc' 2>/dev/null | wc -l | tr -d ' ')"
case "$scanned" in ''|*[!0-9]*) scanned=0 ;; esac
if [ "$scanned" -eq 0 ]; then
  echo "check-home-paths: the synced directories under $ROOT are all empty, so nothing was read. Refusing to report a clean scan of nothing." >&2
  exit 2
fi

# The placeholder itself, which is a second way a machine path arrives. The apply expands it in
# every mirrored file, so a file that NAMES it has its own text rewritten: a comment about the
# placeholder becomes a comment about somebody's home directory, and a shell substitution over it
# becomes a substitution over a path. Both were measured on the installed copy, and the second one
# left a healthcheck reporting a path made of two home directories glued together
# (claude-config#99).
#
# The line between the two uses is what the placeholder is FOR: standing at the front of a path.
# So it is allowed immediately followed by a slash, and refused everywhere else, which covers
# naming it in prose and refused again inside a ${...} substitution, where a following slash is
# the substitution's own separator rather than a path.
#
# This bites in the repo, where the placeholder still exists. In a live tree there is none left to
# find, which is the point: by then the rewriting has already happened.
tokbad=""
while IFS= read -r tline; do
  [ -n "$tline" ] || continue
  case "$tline" in *claude-sync-allow-home-path*) continue ;; esac
  tcontent="${tline#*:}"; tcontent="${tcontent#*:}"
  if printf '%s' "$tcontent" | grep -qE '[$][{][^}]*'"$CS_TOKEN"; then
    tokbad="$tokbad$tline
"
    continue
  fi
  if printf '%s' "$tcontent" | grep -qE "$CS_TOKEN"'([^/]|$)'; then
    tokbad="$tokbad$tline
"
  fi
done <<TOKHITS
$(grep -rIn "${SKIP[@]}" -F -- "$CS_TOKEN" "${targets[@]}" 2>/dev/null || true)
TOKHITS
if [ -n "${tokbad//[[:space:]]/}" ]; then
  echo "check-home-paths: these lines write the sync's placeholder somewhere it is not standing in front of a path, and the apply will rewrite them into one machine's home directory:" >&2
  printf '%s' "$tokbad" | sed 's/^/  /' >&2
  echo "Assemble it from pieces so the apply has nothing to match, or put claude-sync-allow-home-path on the line if it genuinely has to be written whole." >&2
  exit 1
fi

# The OTHER placeholder: the angle bracket home spelling a person substitutes by hand. It used to
# be listed above as an accepted portable form, because two Workflow scriptPath values could not be
# written as a tilde and had to be filled in per Mac. Since claude-config#87 the sync rewrites this
# Mac's home directory in every mirrored file on the way out and expands it per Mac on the way in,
# so both of those values are concrete again and nothing writes this spelling any more
# (claude-config#106).
#
# It is REFUSED rather than merely unmentioned. Unmentioned changes nothing: it is not a machine
# path, so the rule above never matched it, and a line carrying it would go on passing while the
# path it names resolves to nothing wherever it is read. That is the same silent half working this
# whole guard exists to catch, and a placeholder standing in for a value nobody fills in is a
# DETECTION that the value is missing rather than a label on it (L67).
#
# Assembled from pieces, never written whole, exactly like the sync's own token above: this file
# lives inside the tree it scans, so a comment naming the spelling in full would fail its own check.
ANGLE_TOKEN="<""HOME>"
angbad="$(grep -rIn "${SKIP[@]}" -F -- "$ANGLE_TOKEN" "${targets[@]}" 2>/dev/null \
          | grep -v 'claude-sync-allow-home-path' || true)"
if [ -n "${angbad//[[:space:]]/}" ]; then
  echo "check-home-paths: these lines carry the hand substituted home placeholder, which nothing fills in any more, so the path they name resolves to nothing on every Mac:" >&2
  printf '%s\n' "$angbad" | sed 's/^/  /' >&2
  echo "Write the path relative to the home directory instead (a tilde, \$HOME, or expanduser), or put claude-sync-allow-home-path on the line if it genuinely has to name the placeholder." >&2
  exit 1
fi

if [ -n "$hits" ]; then
  echo "check-home-paths: these lines name one machine's home directory, so they are wrong on every other Mac and fail silently there:" >&2
  printf '%s\n' "$hits" | sed 's/^/  /' >&2
  echo "Write the path relative to the home directory instead (a tilde, \$HOME, expanduser, or the sync's own ${CS_TOKEN} placeholder), or put claude-sync-allow-home-path on the line if it genuinely has to name one." >&2
  exit 1
fi

echo "check-home-paths: $scanned file(s) under $ROOT, no machine specific home paths."
exit 0
