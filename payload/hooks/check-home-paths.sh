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
#   check-home-paths.sh --files0-from <list> [config-root]
#
# The second form reads only the files named in <list>, NUL separated paths relative to the root
# (claude-config#3465). claude-sync asks it about the files a send is about to publish, before it
# publishes them: on 2026-11-22 a send pushed 126 scratch files to main, 100 of them naming one
# Mac's home, and this check ran only afterwards, on GitHub. The list narrows WHICH
# files are read and nothing else: a listed file is read exactly when the walk of the whole tree
# would read it (the same folders, the same skills left out, the same names skipped), and by the
# same three rules, so the send and main's own run cannot disagree about a file. A listed file
# outside that set is not judged, and the run says how many of the listed files it read. An empty
# list, a list that cannot be read and a listed file that is not there are exit 2, like any scan
# that read something other than what it was asked about.
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
# Exit 2 as well when the lines the search matched could not be put to the rules.
#
# A reported line is the file, the line number and the line itself. A line longer
# than 300 bytes is reported as at most 300 bytes of it around what was found, cut
# at whole characters, with a note of which bytes those are and how long the line
# is (claude-config#3479).
#
# A line holding a byte that is not valid UTF-8 is searched and judged like any
# other (claude-config#3538: under a UTF-8 locale the search used to lose most of
# them, silently). In the report each such byte is shown as a backslash and its
# octal value, with a note of how many there are, so the report is always valid
# text and the path beside the byte can still be read. A file holding a NUL is
# still skipped as a binary. One thing about such a line is left as it was found:
# whether the allow marker on it is honoured depends on the locale and on where
# the byte sits (see the note above the search, below).
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

# Its own folder cut from its path in bash, never by dirname (claude-config#2081, #2130).
case "${BASH_SOURCE[0]}" in */*) _HD="${BASH_SOURCE[0]%/*}" ;; *) _HD=. ;; esac
_HD="$(cd "${_HD:-/}" && pwd)"
FILES_FROM=""
if [ "${1:-}" = "--files0-from" ]; then
  if [ "$#" -lt 2 ] || [ -z "$2" ]; then
    echo "check-home-paths: --files0-from needs the file holding the list of paths to read." >&2
    exit 2
  fi
  FILES_FROM="$2"
  shift 2
  if [ ! -f "$FILES_FROM" ] || [ ! -r "$FILES_FROM" ]; then
    echo "check-home-paths: the list of files to read, $FILES_FROM, is not there or cannot be read, so nothing was checked." >&2
    exit 2
  fi
fi
ROOT="${1:-$(cd "$_HD/.." && pwd)}"
[ -d "$ROOT" ] || { echo "check-home-paths: no such directory: $ROOT" >&2; exit 2; }

# The synced set, as claude-sync carries it: every tree it mirrors, plus the top
# level rule files. The trees are SYNCED_TREES from lib/synced-trees.sh, which
# test-synced-trees.sh holds to claude-sync's MIRROR_DIRS plus skills, never a
# list of this file's own (claude-config#2754). This file used to keep one, hooks
# agents commands skills, and the sync had since grown audits and mods, so a home
# path written in a mod reached the other Mac and this public repository unread.
#
# If that list cannot be read, every folder at the top of the root is scanned
# instead, and the run says so whatever it concludes: the same direction the
# skills list below takes, reporting too much rather than passing over a tree the
# sync carries (L42, L98). With no list, nothing counts as mirrored either, so the
# live config allowance further down excuses no line.
#
# settings.json is deliberately NOT scanned. Its hook commands are absolute by
# necessity, and claude-sync already rewrites that one file's home path per Mac
# on send and on apply, which is the mechanism this guard exists to cover the
# gap in rather than to duplicate.
TREES_LIB="$_HD/lib/synced-trees.sh"
SYNCED_TREES=()
# shellcheck source=payload/hooks/lib/synced-trees.sh
[ -r "$TREES_LIB" ] && . "$TREES_LIB" 2>/dev/null
MIRRORED_DIRS=(${SYNCED_TREES[@]+"${SYNCED_TREES[@]}"})   # what the live config allowance covers
SCAN_DIRS=(${SYNCED_TREES[@]+"${SYNCED_TREES[@]}"})       # what is read
trees_note=""
if [ "${#SCAN_DIRS[@]}" -eq 0 ]; then
  trees_note="check-home-paths: could not read the list of trees the sync mirrors ($TREES_LIB), so every folder under the root was scanned, including any the sync would leave behind."
  _loop="$(find "$ROOT" -mindepth 1 -maxdepth 1 -type d ! -name .git 2>/dev/null | sort)" || true
  while IFS= read -r _d; do
    [ -n "$_d" ] && SCAN_DIRS+=("${_d##*/}")
  done <<LOOP_INPUT
$_loop
LOOP_INPUT
fi

# Inside skills/, only what the sync CARRIES (claude-config#415). The plugin managed skills and the
# Claude app's own downloads (skills/synced/<bucket>/, fetched per account) never leave a Mac, so a
# home path inside one is not this guard's to report, and reporting it failed every hook suite run
# on a Mac the moment a login downloaded a skill with example paths in it (L36).
#
# The entries come from lib/unmanaged-skills.sh, the same file claude-sync reads, never a copy of
# its names here (L41). It is read from beside THIS script, which is ~/.claude/hooks/lib on a Mac,
# where no repo sits beside the hooks, and payload/hooks/lib in the repo. The matching is read off
# its skill_excludes lines by its skill_exclude_names, the one reading the skill scans share too
# (claude-config#2001), so it is the sync's own: `--exclude=NAME` leaves NAME out at any depth
# under skills/, as rsync does, and `--exclude=/NAME` leaves out only the entry at the top of
# skills/, so a folder that merely happens to be called synced inside a real skill is still read.
#
# If the list cannot be read, NOTHING is left out, and the run says so whatever it concludes. That
# is the direction that cannot hide a real defect: at worst it reports a file the sync would not
# have carried, which is the loud failure this change exists to stop, rather than passing over a
# file it would have (L42). And a scan quietly widened reads exactly like a normal one, so the
# notice is printed on a pass as well as a failure (L98).
UNMANAGED_LIB="$_HD/lib/unmanaged-skills.sh"
UNMANAGED_SKILLS_LIB_LOADED=""
if [ -r "$UNMANAGED_LIB" ]; then
  # shellcheck source=payload/hooks/lib/unmanaged-skills.sh
  . "$UNMANAGED_LIB" 2>/dev/null || UNMANAGED_SKILLS_LIB_LOADED=""
fi
list_note=""
skill_anchored=()     # names left out only at the top of skills/
skill_anywhere=()     # names left out at any depth under skills/
if [ -n "$UNMANAGED_SKILLS_LIB_LOADED" ] && declare -F skill_exclude_names >/dev/null; then
  skill_exclude_names
  skill_anchored=(${SKILL_EXCLUDE_TOP[@]+"${SKILL_EXCLUDE_TOP[@]}"})
  skill_anywhere=(${SKILL_EXCLUDE_ANY[@]+"${SKILL_EXCLUDE_ANY[@]}"})
fi
if [ "$((${#skill_anchored[@]} + ${#skill_anywhere[@]}))" -eq 0 ]; then
  list_note="check-home-paths: could not read the list of skills the sync never carries ($UNMANAGED_LIB), so every skill was scanned, including any the sync would leave behind."
fi

# ---- the listed form: which of the listed files the walk below would read (claude-config#3465) ----
# One question, asked of a path instead of answered by walking: is this file in a tree the walk
# reads, outside every skill the sync leaves alone, and not one of the names the walk's grep skips?
# test-check-home-paths.sh holds the two forms to the same lines over one tree holding every kind of
# place, so a place added to the walk and missed here fails there.
listed_in_scope(){   # $1 = a path relative to the root -> 0 when the walk reads it
  local rel="$1" base top rest entry seg _n _in=0
  case "$rel" in /*|..|../*|*/../*|*/..) return 1 ;; esac
  base="${rel##*/}"
  case "$base" in *.pyc|*.conflict-*) return 1 ;; esac
  case "$rel" in
    */*) ;;
    *.md) return 0 ;;   # a rule file at the top of the root
    *) return 1 ;;
  esac
  case "/${rel%/*}/" in */.git/*|*/__pycache__/*|*/node_modules/*) return 1 ;; esac
  top="${rel%%/*}"; rest="${rel#*/}"
  for seg in ${SCAN_DIRS[@]+"${SCAN_DIRS[@]}"}; do
    [ "$seg" = "$top" ] && { _in=1; break; }
  done
  [ "$_in" -eq 1 ] || return 1
  [ "$top" = skills ] || return 0
  # The entry at the top of skills/, left out under either kind of name.
  entry="${rest%%/*}"
  for _n in ${skill_anchored[@]+"${skill_anchored[@]}"} ${skill_anywhere[@]+"${skill_anywhere[@]}"}; do
    [ "$entry" = "$_n" ] && return 1
  done
  # Below it, only the names left out at any depth, as a folder or as a file.
  case "$rest" in */*) rest="${rest#*/}" ;; *) return 0 ;; esac
  while :; do
    seg="${rest%%/*}"
    for _n in ${skill_anywhere[@]+"${skill_anywhere[@]}"}; do
      [ "$seg" = "$_n" ] && return 1
    done
    case "$rest" in */*) rest="${rest#*/}" ;; *) break ;; esac
  done
  return 0
}
list_files=()     # the listed files this run reads, as full paths
list_missing=""   # listed, and not there
listed_n=0
if [ -n "$FILES_FROM" ]; then
  # `|| [ -n ... ]` so a last path with no NUL after it is still read.
  while IFS= read -r -d '' _rel || [ -n "$_rel" ]; do
    [ -n "$_rel" ] || continue
    listed_n=$((listed_n + 1))
    if [ ! -e "$ROOT/$_rel" ] && [ ! -L "$ROOT/$_rel" ]; then
      list_missing="$list_missing  $_rel
"
      continue
    fi
    # A link, a folder or a device is not something the walk's grep reads either.
    if [ -f "$ROOT/$_rel" ] && [ ! -L "$ROOT/$_rel" ] && listed_in_scope "$_rel"; then
      list_files+=("$ROOT/$_rel")
    fi
  done < "$FILES_FROM"
fi

targets=()        # everything outside skills/, scanned whole
skill_targets=()  # the top level entries of skills/ the sync carries
for d in ${SCAN_DIRS[@]+"${SCAN_DIRS[@]}"}; do
  [ -n "$FILES_FROM" ] && break   # the listed form reads its list, never the trees
  [ -d "$ROOT/$d" ] || continue
  if [ "$d" != skills ]; then targets+=("$ROOT/$d"); continue; fi
  loop_input="$(find "$ROOT/skills" -mindepth 1 -maxdepth 1 2>/dev/null | sort)" || true
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    _base="${e##*/}"
    _skip=0
    for _n in ${skill_anchored[@]+"${skill_anchored[@]}"} ${skill_anywhere[@]+"${skill_anywhere[@]}"}; do
      [ "$_base" = "$_n" ] && { _skip=1; break; }
    done
    [ "$_skip" -eq 1 ] || skill_targets+=("$e")
  done <<LOOP_INPUT
$loop_input
LOOP_INPUT
done
loop_input=""
[ -n "$FILES_FROM" ] || loop_input="$(find "$ROOT" -maxdepth 1 -type f -name '*.md' 2>/dev/null | sort)" || true
while IFS= read -r f; do
  [ -n "$f" ] && targets+=("$f")
done <<LOOP_INPUT
$loop_input
LOOP_INPUT

# The deeper exclusions, as grep options and as find pruning, so the lines scanned and the files
# counted describe the same set.
skill_grep_skip=()
skill_find_prune=()
for _n in ${skill_anywhere[@]+"${skill_anywhere[@]}"}; do
  skill_grep_skip+=("--exclude-dir=$_n" "--exclude=$_n")
  skill_find_prune+=(-o -name "$_n")
done

[ -n "$trees_note" ] && echo "$trees_note" >&2
[ -n "$list_note" ] && echo "$list_note" >&2

if [ -n "$FILES_FROM" ]; then
  if [ "$listed_n" -eq 0 ]; then
    echo "check-home-paths: the list of files to read, $FILES_FROM, names no files, so nothing was checked. Refusing to report a clean scan of nothing." >&2
    exit 2
  fi
  case "$list_missing" in *[![:space:]]*)
    echo "check-home-paths: these listed files are not under $ROOT, so they were not read and the list was not checked:" >&2
    printf '%s' "$list_missing" >&2
    exit 2 ;;
  esac
  if [ "${#list_files[@]}" -eq 0 ]; then
    # A pass, and said as what it is: the list was the caller's, and nothing on it is a file this
    # check reads, so no file was found clean and none was found at fault (L11).
    echo "check-home-paths: none of the $listed_n listed file(s) under $ROOT is one this check reads (the synced folders and the top level rule files), so there was nothing of theirs to judge."
    exit 0
  fi
elif [ "$((${#targets[@]} + ${#skill_targets[@]}))" -eq 0 ]; then
  echo "check-home-paths: found nothing to check under $ROOT (none of ${SCAN_DIRS[*]:-the synced trees}, and no rule files). Refusing to report a clean scan of nothing." >&2
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
# skipped rather than reported as a line nobody can read. The search runs under LC_ALL=C, where
# the only thing that makes a file a binary is a NUL (claude-config#3538). The grep macOS ships
# looks for one near the start of the file only: measured on 2026-11-24, a file whose NUL sat
# 310,000 bytes in was read like any text file, in either locale.
ALL_PAT="${MACHINE_PATH}|${CS_TOKEN}|${ANGLE_TOKEN}"

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

# ---- every matching line judged outside the shell, and cut there (claude-config#3479) ----
# The three rules used to be asked by this shell, of each matching line held whole in a variable.
# On 2026-11-22 a send published 126 scratch files whose matching lines ran to 1.6 MB each, and the
# shell copied every one of them on every use: 6 to 10 seconds and 11.5 MB of report, where the
# search alone took under a second. Under the bash macOS ships, removing this Mac's own config
# path from one such line (the allowance below) did not finish in three minutes.
#
# So one awk program reads the lines the search matched, straight off the pipe, puts each to the
# three rules, and hands the shell one short record per finding: the rule's number, a tab, and the
# line as it is reported. A line of HP_CUT bytes or fewer is reported whole, and when it is valid
# text, byte for byte as it always was. A longer one is reported as HP_CUT bytes of it, starting
# HP_LEAD bytes before what the rule found, so the part shown is the part to act on, followed by a
# note of which bytes are shown and how long the line is; an edge of that cut that falls inside a
# character moves inward to the nearest whole one, so a cut shows up to three bytes fewer at each
# end and never half a character (claude-config#3538). The cut is made AFTER the line is judged,
# on the whole line: a line cut first would pass everything that sat below the cut. Last, each
# byte of what is reported that belongs to no well formed UTF-8 character is written as a
# backslash and its octal value and counted in a note, so the report is valid text whatever the
# file held.
#
# What each rule refuses is what it refused in the shell. Each is asked the way the shell asked it,
# with plain string comparison wherever the rule has no variable part, so the answer does not turn
# on one regex engine agreeing with another. Three things are matched as patterns, each as simple
# as a pattern gets: the home path itself, the placeholder followed by one character that is not a
# slash, and this Mac's own config path where the allowance removes it. It runs with LC_ALL=C, so
# a byte is a byte whatever the line holds and a cut is counted in bytes. The search in front of
# it runs under C too, since claude-config#3538, and the marker filter between them keeps the
# locale it always ran in: the note above the search says what each did with a byte that is not
# valid text, and why.
#
# Measured on those 126 files on 2026-11-23, eight rounds at a load average near 175: 3.8 to 4.3
# seconds before, 0.4 to 0.8 after, with the bare search at 0.05 to 0.12 and the same run over
# 126 one line files at 0.09 to 0.17. What is left above the search is the marker filter (about
# 0.15) and awk reading 12 MB (about 0.25 in the awk macOS ships).
#
# There is still no `grep -q` at the end of a pipe (claude-config#162): awk reads every line it is
# sent, so nothing upstream is killed by a reader that left early. And a judge that fails, or ends
# well without reaching its last line, is exit 2 below, never a clean tree (L98).
HP_CUT=300    # the most bytes of a matching line a report carries
HP_LEAD=60    # how many of those come before what the rule found
IFS= read -r -d '' _HP_JUDGE <<'JUDGE' || true
# A string as a pattern that matches exactly that string.
function literal_re(s,    out, i, c) {
  out = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c == "\\") out = out "\\\\"
    else if (c == "^") out = out "\\^"
    else if (index(".[]()*+?{}|$", c) > 0) out = out "[" c "]"
    else out = out c
  }
  return out
}
# Where the placeholder is written somewhere it is not fronting a path, or 0. Two ways, as ever:
# followed by anything but a slash (the end of the line included), or inside a ${...} that has not
# closed before it. The first is one pass over the line and the second one split on the closing
# brace, because a line can hold the placeholder thousands of times (15,280 on a line of 1.6 MB,
# measured on the files of 2026-11-22) and anything done once per appearance, a split on the
# placeholder included, took a second a line in the awk macOS ships.
function token_misused(s,    n, i, off, p, found, segs) {
  found = 0
  if (match(s, TOKLOOSE)) found = RSTART
  else if (substr(s, length(s) - length(TOK) + 1) == TOK) found = length(s) - length(TOK) + 1
  n = split(s, segs, "}")
  off = 0
  for (i = 1; i <= n; i++) {
    p = index(segs[i], "${")
    if (p > 0 && index(substr(segs[i], p + 2), TOK) > 0) {
      if (found == 0 || off + p < found) found = off + p
      break
    }
    off += length(segs[i]) + 1
  }
  return found
}
# Where the first home path that is not this Mac's own config path starts. Only for choosing the
# part of a long line to show: the verdict is made before this is asked.
function foreign_pos(s,    n, i, off, parts) {
  n = split(s, parts, SELFRE)
  off = 0
  for (i = 1; i <= n; i++) {
    if (match(parts[i], MACH)) return off + RSTART
    off += length(parts[i]) + length(SELF)
  }
  return 1
}
# The value of one byte, or -1 for anything that is not a single byte of the table built in BEGIN
# (an awk that hands back whole characters gives a valid one here, which is shown as it is).
function byte_of(c) { return (c in ORD) ? ORD[c] : -1 }
# Bytes as they are shown when they are not valid text: a backslash and three octal digits each.
function escaped(q,    j, r) {
  r = ""
  for (j = 1; j <= length(q); j++) { r = r sprintf("\\%03o", byte_of(substr(q, j, 1))); NBAD++ }
  return r
}
# A reported line as valid text (claude-config#3538). Every well formed UTF-8 character and every
# ASCII byte is kept exactly as it is, so a line of valid text is still reported byte for byte.
# A byte that belongs to no well formed character is replaced by its octal value, and counted in
# NBAD, so the report can be read, searched and passed on whatever the file held. Only ever asked
# of the few hundred bytes a report carries, never of a whole line.
function as_text(s,    n, i, c, b, out, seq, need, lo, hi) {
  n = length(s); out = ""; seq = ""; need = 0; lo = 128; hi = 191
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    b = byte_of(c)
    if (need > 0) {
      if (b >= lo && b <= hi) {
        seq = seq c; need--; lo = 128; hi = 191
        if (need == 0) { out = out seq; seq = "" }
        continue
      }
      # The character broke off here, so what was held of it is not text. This byte starts afresh.
      out = out escaped(seq); seq = ""; need = 0
    }
    if (b < 128) { out = out c; continue }
    lo = 128; hi = 191
    if (b >= 194 && b <= 223) need = 1
    else if (b == 224) { need = 2; lo = 160 }
    else if ((b >= 225 && b <= 236) || b == 238 || b == 239) need = 2
    else if (b == 237) { need = 2; hi = 159 }
    else if (b == 240) { need = 3; lo = 144 }
    else if (b >= 241 && b <= 243) need = 3
    else if (b == 244) { need = 3; hi = 143 }
    else { out = out escaped(c); continue }
    seq = c
  }
  if (need > 0) out = out escaped(seq)
  return out
}
# The last byte to show of a cut that would otherwise end at `end`: moved back to the end of the
# character before, when the cut falls inside one whose remaining bytes lie past it.
function whole_end(start, end,    j, b, need) {
  for (j = end; j >= start && j > end - 4; j--) {
    b = byte_of(substr(content, j, 1))
    if (b >= 128 && b <= 191) continue
    need = 1
    if (b >= 194 && b <= 223) need = 2
    else if (b >= 224 && b <= 239) need = 3
    else if (b >= 240 && b <= 244) need = 4
    if (j + need - 1 > end) return j - 1
    return end
  }
  return end
}
function report(rule, pos,    start, end, k, b, text, note) {
  note = ""
  if (len <= CUT) text = line
  else {
    start = pos - LEAD
    if (start > len - CUT + 1) start = len - CUT + 1
    if (start < 1) start = 1
    end = start + CUT - 1
    # The cut is counted in bytes, and a character can be up to four of them. A cut that began or
    # ended inside one would put part of a character at the edge of the report, which is not valid
    # text even when the file is, so each edge moves inward to the nearest whole character. What
    # was found is never among the bytes given up: it starts on an ASCII character, LEAD bytes in.
    if (start > 1) {
      for (k = 0; k < 3 && start < end; k++) {
        b = byte_of(substr(content, start, 1))
        if (b < 128 || b > 191) break
        start++
      }
    }
    if (end < len) end = whole_end(start, end)
    text = prefix substr(content, start, end - start + 1)
    note = " [line cut: bytes " start " to " end " of " len " shown]"
  }
  NBAD = 0
  text = as_text(text)
  if (NBAD == 1) note = note " [1 byte that is not valid text, shown as a backslash and its octal value]"
  else if (NBAD > 1) note = note " [" NBAD " bytes that are not valid text, each shown as a backslash and its octal value]"
  print rule "\t" text note
}
BEGIN {
  TOK = ENVIRON["HP_TOKEN"]; ANG = ENVIRON["HP_ANGLE"]; MACH = ENVIRON["HP_MACHINE"]
  SELF = ENVIRON["HP_SELF_HOME"]; ROOT = ENVIRON["HP_ROOT"]
  ALLOW = ENVIRON["HP_ALLOW_SELF"] + 0; CUT = ENVIRON["HP_CUT"] + 0; LEAD = ENVIRON["HP_LEAD"] + 0
  if (TOK == "" || ANG == "" || MACH == "" || CUT < 1 || (ALLOW && SELF == "")) { unset = 1; exit 2 }
  nd = split(ENVIRON["HP_MIRRORED"], MIRR, "\n")
  # The placeholder followed by anything but a slash. It is letters and underscores, so it is its
  # own pattern; the end of the line, the other half of that rule, is compared as a string.
  TOKLOOSE = TOK "[^/]"
  if (ALLOW) SELFRE = literal_re(SELF)
  # Each byte's value, looked up by the byte itself, for showing a reported line as valid text.
  for (i = 1; i < 256; i++) ORD[sprintf("%c", i)] = i
}
$0 == "" { next }
{
  line = $0
  # The file's own CONTENT, never the whole grep line. That line begins with the path of the file
  # it came from, which is itself under somebody's home directory, so testing the whole line
  # answers about the scanned tree's LOCATION rather than about what the file says (L135: a check
  # matched over the wrong span is answered by the wrong thing, and this one passed a deliberately
  # broken build because of it).
  # Cut at the first colon, then at the next, exactly as the shell cut it (${line#*:} twice).
  content = line
  c = index(content, ":"); if (c > 0) content = substr(content, c + 1)
  c = index(content, ":"); if (c > 0) content = substr(content, c + 1)
  len = length(content)
  prefix = substr(line, 1, length(line) - len)

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
  if (index(content, TOK) > 0) {
    pos = token_misused(content)
    if (pos > 0) report("2", pos)
  }

  # Rule 3. A literal comparison, not a regex: the spelling has no variable part.
  pos = index(content, ANG)
  if (pos > 0) report("3", pos)

  # Rule 1, and its one allowance. claude-sync rewrites this Mac's config directory to its token in
  # every mirrored file on the way out and expands it again per Mac on the way in, so inside a LIVE
  # config tree an absolute path under that same directory is portable: it is what the sync just
  # wrote, and it travels correctly. That applies only when the tree being scanned IS this
  # machine's config directory, and only under the mirrored directories. In the repo, where nothing
  # has been through a send, every machine path is still refused, and a path in a top level rule
  # file is refused everywhere, because rule files are merged entry by entry and are deliberately
  # not rewritten.
  if (match(content, MACH)) {
    pos = RSTART
    keep = 1
    if (ALLOW) {
      # The file the line came from, relative to the root: what sits before the first colon.
      rel = line
      c = index(rel, ":"); if (c > 0) rel = substr(rel, 1, c - 1)
      if (index(rel, ROOT "/") == 1) rel = substr(rel, length(ROOT) + 2)
      mirrored = 0
      for (i = 1; i <= nd; i++) {
        if (MIRR[i] != "" && index(rel, MIRR[i] "/") == 1) { mirrored = 1; break }
      }
      if (mirrored) {
        # This machine's own config path removed, then the content asked again: what is left is any
        # OTHER machine's home, which is the defect. Done per line, so one portable path never
        # excuses a stale one sitting beside it.
        stripped = content
        gsub(SELFRE, "", stripped)
        if (match(stripped, MACH)) pos = foreign_pos(content)
        else keep = 0
      }
    }
    if (keep) report("1", pos)
  }
}
# The last line, and the proof the lines above were all read: the shell refuses a run without it.
END { if (unset) exit 2; print "E\t" NR }
JUDGE

_mirrored_nl=""
for d in ${MIRRORED_DIRS[@]+"${MIRRORED_DIRS[@]}"}; do _mirrored_nl="$_mirrored_nl$d
"; done

# Two walks rather than one only because the deeper skill exclusions must not reach hooks, agents
# or commands, where a folder sharing a plugin skill's name is ordinary config.
#
# The listed form reads its files by name, a few hundred to a call so a long list never outgrows
# what one command line may carry, and with -H so a call left holding one file still names it.
#
# The searches end in `true` and the marker filter in `|| true`, as they always did (a search that
# matches nothing is not a failure), so under pipefail the status left is the judge's own.
#
# Every search runs with LC_ALL=C (claude-config#3538). In a UTF-8 locale the grep macOS ships
# gives up on a line at the first byte that is not valid UTF-8: measured on 2026-11-24 under
# en_US.UTF-8, it left out 17 of 23 matching lines that held such a byte (whenever the byte came
# before what the pattern matches, or touched the end of it), with exit 0, nothing on stderr and
# no "Binary file matches" in its output, so a home path on such a line passed. Under C a byte is
# a byte and it found all 23. GNU grep, by its manual, calls the whole FILE binary over one such
# byte in a UTF-8 locale, and -I then skips the file, while under C only a NUL makes a file
# binary. That is read, not measured: no GNU grep was to hand on 2026-11-24, so the suite's
# cases for it (a home path on another line of such a file) have only ever run on macOS. Nothing
# valid text matched before is lost by this: the pattern is ASCII, and the judge below was
# already asking it under C, so a line only a UTF-8 reading of the pattern could match was never
# reported anyway (14 kinds of valid line, accents in and around the path included, gave the
# same report byte for byte before and after, in both locales).
#
# The marker filter gets -a and keeps the locale it always ran in. -a because it reads the
# search's output from a pipe, and GNU grep, on meeting a byte it calls binary there, prints
# "Binary file (standard input) matches" in place of every line from that one on (L329, and again
# read from its manual rather than measured); the searches above can now send it such a line. In
# the grep macOS ships -a changed nothing that was measured. Its locale is left alone on purpose. Under a UTF-8
# locale the grep macOS ships cannot see the marker on a line whose odd byte comes before the
# marker or touches its end, so that line is reported though it is marked (measured the same day),
# while under C the marker is seen wherever the byte is. Running the filter under C would make
# that uniform by EXCUSING lines that are reported today, and a change that makes this guard pass
# more is not one to make in passing.
judged="$(
  { _i=0
    while [ "$_i" -lt "${#list_files[@]}" ]; do
      LC_ALL=C grep -InHE "$ALL_PAT" "${list_files[@]:_i:400}" 2>/dev/null
      _i=$((_i + 400))
    done
    [ "${#targets[@]}" -eq 0 ] || LC_ALL=C grep -rInE "${SKIP[@]}" "$ALL_PAT" "${targets[@]}" 2>/dev/null
    [ "${#skill_targets[@]}" -eq 0 ] || LC_ALL=C grep -rInE "${SKIP[@]}" ${skill_grep_skip[@]+"${skill_grep_skip[@]}"} \
      "$ALL_PAT" "${skill_targets[@]}" 2>/dev/null
    true
  } | { grep -a -v 'claude-sync-allow-home-path' || true; } \
    | LC_ALL=C HP_TOKEN="$CS_TOKEN" HP_ANGLE="$ANGLE_TOKEN" HP_MACHINE="$MACHINE_PATH" \
      HP_ALLOW_SELF="$allow_self" HP_ROOT="$ROOT" HP_SELF_HOME="$SELF_HOME" HP_MIRRORED="$_mirrored_nl" \
      HP_CUT="$HP_CUT" HP_LEAD="$HP_LEAD" awk "$_HP_JUDGE"
)"
judge_rc=$?

# One short record per finding, sorted into the three rules. Nothing read here is longer than a
# file's path and HP_CUT bytes of one of its lines.
_tab=$'\t'
judge_ended=0
while IFS= read -r _rec; do
  case "$_rec" in
    "1$_tab"*) hits="$hits${_rec#??}
" ;;
    "2$_tab"*) tokbad="$tokbad${_rec#??}
" ;;
    "3$_tab"*) angbad="$angbad${_rec#??}
" ;;
    "E$_tab"*) judge_ended=1 ;;
  esac
done <<JUDGED
$judged
JUDGED
if [ "$judge_rc" -ne 0 ] || [ "$judge_ended" -ne 1 ]; then
  echo "check-home-paths: the lines the search matched could not be judged: the step that puts each one to the three rules ended with exit $judge_rc and $([ "$judge_ended" -eq 1 ] && echo "said it had read them all" || echo "never said it had read them all"). Nothing is known about those lines, so this is not a clean scan." >&2
  exit 2
fi
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
# The listed form read the files it chose above, one by one, so that is its count, and it has
# already left if there were none.
[ -z "$FILES_FROM" ] || scanned="${#list_files[@]}"
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

if [ -n "$FILES_FROM" ]; then
  echo "check-home-paths: $scanned of $listed_n listed file(s) under $ROOT read, no machine specific home paths."
  exit 0
fi
echo "check-home-paths: $scanned file(s) under $ROOT, no machine specific home paths."
exit 0
