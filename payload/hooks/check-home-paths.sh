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
# Exit 0 = clean. Exit 1 = at least one of the three rules below found something,
# and a run reports EVERY cause it found rather than the first, so a tree holding
# several does not take one run per cause to discover (claude-config#108). Exit 2
# = nothing was scanned, which is a failure rather than a pass: an empty answer
# from a scan that read no files is indistinguishable from a clean tree (L98).
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

# Inside skills/, only what the sync CARRIES (claude-config#415). The plugin managed skills and the
# Claude app's own downloads (skills/synced/<bucket>/, fetched per account) never leave a Mac, so a
# home path inside one is not this guard's to report, and reporting it failed every hook suite run
# on a Mac the moment a login downloaded a skill with example paths in it (L36).
#
# The entries come from lib/unmanaged-skills.sh, the same file claude-sync reads, never a copy of
# its names here (L41). It is read from beside THIS script, which is ~/.claude/hooks/lib on a Mac,
# where no repo sits beside the hooks, and payload/hooks/lib in the repo. The matching is read off
# its skill_excludes lines, so it is the sync's own: `--exclude=NAME` leaves NAME out at any depth
# under skills/, as rsync does, and `--exclude=/NAME` leaves out only the entry at the top of
# skills/, so a folder that merely happens to be called synced inside a real skill is still read.
#
# If the list cannot be read, NOTHING is left out, and the run says so whatever it concludes. That
# is the direction that cannot hide a real defect: at worst it reports a file the sync would not
# have carried, which is the loud failure this change exists to stop, rather than passing over a
# file it would have (L42). And a scan quietly widened reads exactly like a normal one, so the
# notice is printed on a pass as well as a failure (L98).
UNMANAGED_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/unmanaged-skills.sh"
UNMANAGED_SKILLS_LIB_LOADED=""
if [ -r "$UNMANAGED_LIB" ]; then
  # shellcheck source=payload/hooks/lib/unmanaged-skills.sh
  . "$UNMANAGED_LIB" 2>/dev/null || UNMANAGED_SKILLS_LIB_LOADED=""
fi
list_note=""
skill_anchored=()     # names left out only at the top of skills/
skill_anywhere=()     # names left out at any depth under skills/
if [ -n "$UNMANAGED_SKILLS_LIB_LOADED" ] && declare -F skill_excludes >/dev/null; then
  while IFS= read -r _ex; do
    _name="${_ex#--exclude=}"
    case "$_name" in
      '') ;;
      /*) skill_anchored+=("${_name#/}") ;;
      *)  skill_anywhere+=("$_name") ;;
    esac
  done < <(skill_excludes)
fi
if [ "$((${#skill_anchored[@]} + ${#skill_anywhere[@]}))" -eq 0 ]; then
  list_note="check-home-paths: could not read the list of skills the sync never carries ($UNMANAGED_LIB), so every skill was scanned, including any the sync would leave behind."
fi

targets=()        # everything outside skills/, scanned whole
skill_targets=()  # the top level entries of skills/ the sync carries
for d in "${SYNCED_DIRS[@]}"; do
  [ -d "$ROOT/$d" ] || continue
  if [ "$d" != skills ]; then targets+=("$ROOT/$d"); continue; fi
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    _base="${e##*/}"
    _skip=0
    for _n in ${skill_anchored[@]+"${skill_anchored[@]}"} ${skill_anywhere[@]+"${skill_anywhere[@]}"}; do
      [ "$_base" = "$_n" ] && { _skip=1; break; }
    done
    [ "$_skip" -eq 1 ] || skill_targets+=("$e")
  done < <(find "$ROOT/skills" -mindepth 1 -maxdepth 1 2>/dev/null | sort)
done
while IFS= read -r f; do
  [ -n "$f" ] && targets+=("$f")
done < <(find "$ROOT" -maxdepth 1 -type f -name '*.md' 2>/dev/null | sort)

# The deeper exclusions, as grep options and as find pruning, so the lines scanned and the files
# counted describe the same set.
skill_grep_skip=()
skill_find_prune=()
for _n in ${skill_anywhere[@]+"${skill_anywhere[@]}"}; do
  skill_grep_skip+=("--exclude-dir=$_n" "--exclude=$_n")
  skill_find_prune+=(-o -name "$_n")
done

[ -n "$list_note" ] && echo "$list_note" >&2

if [ "$((${#targets[@]} + ${#skill_targets[@]}))" -eq 0 ]; then
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
# The hand substituted placeholder, the third rule (claude-config#106). It used to be listed as an
# accepted portable form, because two Workflow scriptPath values could not be written as a tilde and
# had to be filled in per Mac. Since claude-config#87 the sync rewrites this Mac's home directory in
# every mirrored file on the way out and expands it per Mac on the way in, so both of those values
# are concrete again and nothing writes this spelling any more.
#
# It is REFUSED rather than merely unmentioned. Unmentioned changes nothing: it is not a machine
# path, so the first rule never matched it, and a line carrying it would go on passing while the
# path it names resolves to nothing wherever it is read. That is the same silent half working this
# whole guard exists to catch, and a placeholder standing in for a value nobody fills in is a
# DETECTION that the value is missing rather than a label on it (L67).
#
# Assembled from pieces, never written whole, exactly like the sync's own token: this file lives
# inside the tree it scans, so a comment naming the spelling in full would fail its own check.
ANGLE_TOKEN="<""HOME>"

# ---- one walk of the tree, three rules read off it (claude-config#108) ----
# The three rules arrived one at a time (#86, #99, #106) and each brought its own recursive scan
# and its own copy of the marker exemption, so the tree was walked three times and a change to how
# exemptions work had to be made in three places or it was made in two. One traversal now collects
# every candidate line and each line is put to all three rules.
#
# The rules stay THREE, with three messages, because they are three different causes and a single
# sentence covering all of them would name none of them precisely (L11). What changed is that one
# run reports every cause it found, instead of exiting at the first and sending somebody back for
# another run to discover the next one.
#
# The marker is dropped line by line, here, once: one excused line never excuses the rest of its
# file, and no rule can forget to honour it. -I so a binary that happens to hold the bytes is
# skipped rather than reported as a line nobody can read.
ALL_PAT="${MACHINE_PATH}|${CS_TOKEN}|${ANGLE_TOKEN}"
# Two walks rather than one only because the deeper skill exclusions must not reach hooks, agents
# or commands, where a folder sharing a plugin skill's name is ordinary config.
raw_all="$(
  { [ "${#targets[@]}" -eq 0 ] || grep -rInE "${SKIP[@]}" "$ALL_PAT" "${targets[@]}" 2>/dev/null
    [ "${#skill_targets[@]}" -eq 0 ] || grep -rInE "${SKIP[@]}" ${skill_grep_skip[@]+"${skill_grep_skip[@]}"} \
      "$ALL_PAT" "${skill_targets[@]}" 2>/dev/null
  } | grep -v 'claude-sync-allow-home-path' || true)"

# Is the tree being scanned this machine's own config directory? Compared as resolved physical
# paths, because /tmp and /private/tmp are the same directory here and a string comparison would
# answer no on a path that is the same place.
SELF_HOME="${CLAUDE_HOME:-$HOME/.claude}"
self_root=""
[ -d "$SELF_HOME" ] && self_root="$(cd "$SELF_HOME" 2>/dev/null && pwd -P || true)"
scan_root="$(cd "$ROOT" 2>/dev/null && pwd -P || printf '%s' "$ROOT")"
allow_self=0
[ -n "$self_root" ] && [ "$scan_root" = "$self_root" ] && allow_self=1

hits=""      # rule 1: one machine's home directory
tokbad=""    # rule 2: the sync's placeholder written where it is not fronting a path
angbad=""    # rule 3: the hand substituted placeholder

# The two regex rules are matched with bash's own ERE engine rather than by piping each line into
# `grep -qE` (claude-config#162). `grep -q` leaves on its first match, its producer is killed by
# SIGPIPE, and under `pipefail` the pipeline's status becomes that death, so a line that DID match
# can be reported as clean. That is fail-open in a guard whose whole job is refusing, and it is a
# size threshold nobody watches rather than a bug that shows up once (L183). Bash's `=~` is POSIX
# ERE, the same dialect `grep -E` reads, so the patterns are unchanged; there is no second process
# to kill, and four sites become none.
#
# Held in variables because that is the only reliable way to feed a pattern to `=~`: written inline,
# an unquoted `$)` and a `${` are read by the shell before the regex engine ever sees them.
_RE_TOK_SUBST='[$][{][^}]*'"$CS_TOKEN"
_RE_TOK_LOOSE="$CS_TOKEN"'([^/]|$)'
while IFS= read -r line; do
  [ -n "$line" ] || continue
  # The file's own CONTENT, never the whole grep line. That line begins with the path of the file
  # it came from, which is itself under somebody's home directory, so testing the whole line
  # answers about the scanned tree's LOCATION rather than about what the file says (L135: a check
  # matched over the wrong span is answered by the wrong thing, and this one passed a deliberately
  # broken build because of it).
  content="${line#*:}"; content="${content#*:}"

  # Each rule is asked independently, never as an else-if: a line can commit two of these at once
  # and reporting only the first found would hide the second behind the fix for it.

  # Rule 2. The apply expands the placeholder in every mirrored file, so a file that NAMES it has
  # its own text rewritten: a comment about the placeholder becomes a comment about somebody's home
  # directory, and a shell substitution over it becomes a substitution over a path. Both were
  # measured on the installed copy, and the second left a healthcheck reporting a path made of two
  # home directories glued together (claude-config#99).
  # The line between the two uses is what the placeholder is FOR: standing at the front of a path.
  # So it is allowed immediately followed by a slash, and refused everywhere else, which covers
  # naming it in prose and refuses it again inside a ${...} substitution, where a following slash
  # is the substitution's own separator rather than a path.
  if [[ $content =~ $_RE_TOK_SUBST ]] || [[ $content =~ $_RE_TOK_LOOSE ]]; then
    tokbad="$tokbad$line
"
  fi

  # Rule 3. A literal comparison, not a regex: the spelling has no variable part.
  case "$content" in
    *"$ANGLE_TOKEN"*) angbad="$angbad$line
" ;;
  esac

  # Rule 1, and its one allowance. claude-sync rewrites this Mac's config directory to its token in
  # every mirrored file on the way out and expands it again per Mac on the way in, so inside a LIVE
  # config tree an absolute path under that same directory is portable: it is what the sync just
  # wrote, and it travels correctly. That applies only when the tree being scanned IS this
  # machine's config directory, and only under the mirrored directories. In the repo, where nothing
  # has been through a send, every machine path is still refused, and a path in a top level rule
  # file is refused everywhere, because rule files are merged entry by entry and are deliberately
  # not rewritten.
  if [[ $content =~ $MACHINE_PATH ]]; then
    _keep=1
    if [ "$allow_self" -eq 1 ]; then
      rel="${line%%:*}"; rel="${rel#"$ROOT"/}"
      mirrored=0
      for d in "${SYNCED_DIRS[@]}"; do
        case "$rel" in "$d"/*) mirrored=1; break ;; esac
      done
      if [ "$mirrored" -eq 1 ]; then
        # This machine's own config path removed, then the content asked again: what is left is any
        # OTHER machine's home, which is the defect. Done per line, so one portable path never
        # excuses a stale one sitting beside it.
        _stripped="${content//$SELF_HOME/}"
        [[ $_stripped =~ $MACHINE_PATH ]] || _keep=0
      fi
    fi
    [ "$_keep" -eq 1 ] && hits="$hits$line
"
  fi
done <<HITS
$raw_all
HITS
hits="${hits%$'\n'}"

# Counted from a directory walk rather than from the grep above, and deliberately: grep can only
# count files it FOUND something in, and the whole point of this number is to notice a scan that
# read nothing at all. A clean tree matches nothing, which is indistinguishable from a scanner
# pointed at the wrong directory unless something counts the files independently (L98).
scanned="$(
  { [ "${#targets[@]}" -eq 0 ] || find "${targets[@]}" -type f \
      ! -path '*/.git/*' ! -path '*__pycache__*' ! -name '*.pyc' 2>/dev/null
    # The pruned names are matched below the top only (-mindepth 1), mirroring the grep, whose
    # exclusions were already applied to the top level entries when the targets were chosen.
    [ "${#skill_targets[@]}" -eq 0 ] || find "${skill_targets[@]}" -mindepth 1 \
      \( -name .git ${skill_find_prune[@]+"${skill_find_prune[@]}"} \) -prune -o -type f \
      ! -path '*__pycache__*' ! -name '*.pyc' -print 2>/dev/null
    # A bare file directly under skills/ is itself a target, and -mindepth 1 would skip it.
    for _t in ${skill_targets[@]+"${skill_targets[@]}"}; do [ -f "$_t" ] && printf '%s\n' "$_t"; done
  } | wc -l | tr -d ' ')"
case "$scanned" in ''|*[!0-9]*) scanned=0 ;; esac
if [ "$scanned" -eq 0 ]; then
  echo "check-home-paths: the synced directories under $ROOT are all empty, so nothing was read. Refusing to report a clean scan of nothing." >&2
  exit 2
fi

# Every cause found is reported, in the order the rules were introduced, and the exit is decided
# once at the end. Exiting inside the first rule that fired is what made a tree holding several of
# these take one run per cause to discover (claude-config#108).
rc=0
# `case` rather than `${x//[[:space:]]/}`. That substitution builds a whole new string, and under
# the bash macOS ships its cost is superlinear in the NUMBER OF MATCHES: measured on 2026-08-21,
# at 1,536 matches it took 11.5 seconds and at 3,072 it took 82, while this answers either in
# milliseconds. The list
# below is built from grep hits, so it is longest exactly when the guard has something to report
# (claude-config#117).
case "$hits" in *[![:space:]]*)
  echo "check-home-paths: these lines name one machine's home directory, so they are wrong on every other Mac and fail silently there:" >&2
  printf '%s\n' "$hits" | sed 's/^/  /' >&2
  echo "Write the path relative to the home directory instead (a tilde, \$HOME, expanduser, or the sync's own ${CS_TOKEN} placeholder), or put claude-sync-allow-home-path on the line if it genuinely has to name one." >&2
  rc=1 ;;
esac
case "$tokbad" in *[![:space:]]*)
  echo "check-home-paths: these lines write the sync's placeholder somewhere it is not standing in front of a path, and the apply will rewrite them into one machine's home directory:" >&2
  printf '%s' "$tokbad" | sed 's/^/  /' >&2
  echo "Assemble it from pieces so the apply has nothing to match, or put claude-sync-allow-home-path on the line if it genuinely has to be written whole." >&2
  rc=1 ;;
esac
case "$angbad" in *[![:space:]]*)
  echo "check-home-paths: these lines carry the hand substituted home placeholder, which nothing fills in any more, so the path they name resolves to nothing on every Mac:" >&2
  printf '%s' "$angbad" | sed 's/^/  /' >&2
  echo "Write the path relative to the home directory instead (a tilde, \$HOME, or expanduser), or put claude-sync-allow-home-path on the line if it genuinely has to name the placeholder." >&2
  rc=1 ;;
esac
[ "$rc" -eq 0 ] || exit 1

echo "check-home-paths: $scanned file(s) under $ROOT, no machine specific home paths."
exit 0
