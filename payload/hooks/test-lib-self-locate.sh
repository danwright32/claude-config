#!/usr/bin/env bash
# A whole tree scan: a send touching these paths runs this suite (claude-config#809).
# send-gate: scans hooks/ skills/ mods/
# No library finds its own folder with dirname (claude-config#1104, after #1098).
#
# `X="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` reads as "the folder this file is in". It is
# that only while `dirname` can be started. dirname is an external command, and under a PATH
# without it the substitution comes back empty, `cd ""` succeeds by staying where it is, and X
# becomes the CALLER's folder. Nothing errors, so the library goes on to source, run or report
# whatever sits beside the caller under that name. #1098 found it in lib/sleep.sh, which then ran
# the caller's sleep-report.py; eight more libraries had the same line.
#
# A library is SOURCED, so it runs in whatever shell, folder and PATH its caller has, which is
# exactly the case where its own folder must not be borrowed from anyone. So every library finds it
# by parameter expansion on BASH_SOURCE, with only builtins after it, and this scan fails on the
# next one written the old way, in any `lib/` folder in the tree. A one way door, not a count: every
# site was converted. Comment lines are skipped, or the prose explaining the rule would break it.
#
# The same holds for a hook (claude-config#2130, after #2120): a hook runs under whatever PATH the
# platform gives it, so every hook found its own folder the old way until 79 sites in 67 hooks were
# converted. The scan therefore covers every non test shell file in a `hooks/` folder as well, and a
# runtime section runs each hook that names BASH_SOURCE from a decoy folder, with no dirname on
# PATH, and fails on one that loads the decoy's library or runs dirname.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The checkout this copy is the payload of, found by the one shared test (lib/checkout-root.sh,
# claude-config#1567): a repository above that is not this one (a home folder kept in git) is no
# checkout, so its files are never scanned as this repository's.
ROOT="${LIB_SELF_LOCATE_ROOT:-$(bash "$DIR/lib/checkout-root.sh" "$DIR/.." 2>/dev/null || true)}"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
  echo "test-lib-self-locate: $DIR/.. is not the payload of a claude-config checkout, so there were no files of this repository to read." >&2
  printf 'SUITE-NOT-RUN %s\n' "needs the repository to read its files, and $DIR/.. is not the payload of a claude-config checkout"
  exit 2
fi

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/lib-self-locate.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-lib-self-locate: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

# The command's name, ASSEMBLED so this file holds no occurrence of the thing it forbids.
_D="dir""name"

# Every uncommented line applying it to the file's own path, as "<path>:<line>", for the shell files
# under a lib/ folder named on stdin relative to $1. The path is BASH_SOURCE in any index or brace
# spelling, $0, or a variable this same file assigned from either, and options (`--`) before it are
# read past: each spelling left out would be exempt (L217). One awk over all of them (L297).
# The program, read once, outside the function that runs it. Read by `read` rather than through a
# command substitution, which bash 3.2 parses for quotes even inside a heredoc, and this program
# holds lone double quotes. `read -d ""` stops at the end of input with status 1, by design.
_SELF_SCAN=""
IFS= read -r -d "" _SELF_SCAN <<'AWK' || true
  # The name of the parameter a "$..." word at the start of s expands, or "" when it is not one.
  function param(s,    t) {
    sub(/^"/, "", s)
    if (substr(s, 1, 1) != "$") return ""
    s = substr(s, 2); sub(/^\{/, "", s)
    if (s ~ /^0([^0-9]|$)/) return "0"
    if (match(s, /^[A-Za-z_][A-Za-z_0-9]*/)) return substr(s, 1, RLENGTH)
    return ""
  }
  FNR == 1 { split("", own) }
  /^[[:space:]]*#/ { next }
  {
    # A variable given the file s own path keeps meaning it for the rest of this file.
    rest = $0
    while (match(rest, /[A-Za-z_][A-Za-z_0-9]*="?\$\{?(BASH_SOURCE|0([^0-9]|$))/)) {
      a = substr(rest, RSTART, RLENGTH); sub(/=.*/, "", a); own[a] = 1
      rest = substr(rest, RSTART + RLENGTH)
    }
    rest = $0
    while (match(rest, D "[[:space:]]+")) {
      rest = substr(rest, RSTART + RLENGTH)
      arg = rest
      while (match(arg, /^-[^[:space:]]*[[:space:]]+/)) arg = substr(arg, RLENGTH + 1)
      p = param(arg)
      if (p == "BASH_SOURCE" || p == "0" || (p != "" && (p in own))) { print FILENAME ":" FNR; break }
    }
  }
AWK
[ -n "$_SELF_SCAN" ] || { echo "test-lib-self-locate: the scan program came back empty, so nothing could be judged." >&2; exit 2; }
sites_in(){   # $1 = root; stdin = repo relative paths
  local root="$1" rel
  local files=()
  while IFS= read -r rel; do
    # A library, then a hook: any other shell file under a hooks/ folder except a test suite, which
    # runs from the suite with a whole PATH and is not installed as a hook (claude-config#2130).
    case "$rel" in
      lib/*.sh|*/lib/*.sh) [ -f "$root/$rel" ] && files+=("$rel") ;;
      test-*.sh|*/test-*.sh) ;;
      hooks/*.sh|*/hooks/*.sh) [ -f "$root/$rel" ] && files+=("$rel") ;;
    esac
  done
  [ "${#files[@]}" -gt 0 ] || return 0
  (cd "$root" && awk -v D="$_D" "$_SELF_SCAN" "${files[@]}" 2>/dev/null)
  return 0
}

# ---------------------------------------------------------------------------
# The scan has to see every spelling, and not the fix or a dirname of anything else, first (L1).
# ---------------------------------------------------------------------------
mkdir -p "$TMPROOT/plant/hooks/lib" "$TMPROOT/plant/tools"
{
  printf '#!/usr/bin/env bash\n'
  printf 'A="$(cd "$(%s "${BASH_SOURCE[0]}")" && pwd)"\n' "$_D"
  printf 'B="$(cd "$(%s "$BASH_SOURCE")" && pwd)"\n' "$_D"
  printf '. "$(%s "$0")/x.sh"\n' "$_D"
  printf 'C=$(%s ${BASH_SOURCE[0]})\n' "$_D"
  printf 'D="$(%s "${0}")"\n' "$_D"
  printf '# E="$(%s "${BASH_SOURCE[0]}")"  <- a comment about one, not one\n' "$_D"
  printf 'F="$(%s "$transcript")"\n' "$_D"
  printf 'G="${BASH_SOURCE[0]%%/*}"\n'
  printf 'H="$(%s -- "${BASH_SOURCE[0]}")"\n' "$_D"
  printf 'self="${BASH_SOURCE[0]}"\n'
  printf 'I="$(cd "$(%s "$self")" && pwd)"\n' "$_D"
  printf 'other="$1"; J="$(%s "$other")"\n' "$_D"
} > "$TMPROOT/plant/hooks/lib/planted.sh"
printf 'A="$(%s "${BASH_SOURCE[0]}")"\n' "$_D" > "$TMPROOT/plant/tools/not-a-hook.sh"
# A variable holding its own path is followed within its own file only: the next file's `self` is
# somebody else's.
printf 'K="$(%s "$self")"\n' "$_D" > "$TMPROOT/plant/hooks/lib/second.sh"
# A hook is judged as a library is, and a test suite beside it is not (claude-config#2130).
printf 'HERE="$(cd "$(%s "${BASH_SOURCE[0]}")" && pwd)"\n' "$_D" > "$TMPROOT/plant/hooks/planted-hook.sh"
printf 'HERE="$(cd "$(%s "${BASH_SOURCE[0]}")" && pwd)"\n' "$_D" > "$TMPROOT/plant/hooks/test-planted-hook.sh"
planted="$(printf '%s\n' hooks/lib/planted.sh tools/not-a-hook.sh hooks/lib/second.sh hooks/planted-hook.sh hooks/test-planted-hook.sh | sites_in "$TMPROOT/plant" | tr '\n' ' ')"
[ "$planted" = "hooks/lib/planted.sh:2 hooks/lib/planted.sh:3 hooks/lib/planted.sh:4 hooks/lib/planted.sh:5 hooks/lib/planted.sh:6 hooks/lib/planted.sh:10 hooks/lib/planted.sh:12 hooks/planted-hook.sh:1 " ] \
  && check "the scan names every spelling in a library or a hook, and not a comment, another path, the fix, a test suite or a file outside hooks/" ok \
  || check "the scan names every spelling in a library or a hook, and not a comment, another path, the fix, a test suite or a file outside hooks/" "it named: ${planted:-nothing}"

# ---------------------------------------------------------------------------
# The real tree.
# ---------------------------------------------------------------------------
# Committed or not, through the one lister every scanner here uses (claude-config#522).
FILES="$(bash "$DIR/lib/repo-files.sh" "$ROOT" 2>/dev/null || true)"
libs="$(printf '%s\n' "$FILES" | awk '/(^|\/)lib\/[^\/]*\.sh$/' | awk 'END { print NR }')"
# A listing with no library in it read nothing, and the check below would pass over it (L98).
[ "${libs:-0}" -ge 10 ] \
  && check "the libraries to judge were listed ($libs)" ok \
  || check "the libraries to judge were listed (${libs:-0})" "lib/repo-files.sh gave too few for $ROOT, so nothing below was read"
hooks="$(printf '%s\n' "$FILES" | awk '/(^|\/)hooks\/[^\/]*\.sh$/ && !/(^|\/)test-[^\/]*$/' | awk 'END { print NR }')"
[ "${hooks:-0}" -ge 40 ] \
  && check "the hooks to judge were listed ($hooks)" ok \
  || check "the hooks to judge were listed (${hooks:-0})" "lib/repo-files.sh gave too few for $ROOT, so nothing below was read"
found="$(printf '%s\n' "$FILES" | sites_in "$ROOT")"
[ -z "$found" ] \
  && check "no library or hook finds its own folder with dirname" ok \
  || check "no library or hook finds its own folder with dirname" "these do:
$found
  In a library, use the parameter expansion lib/sleep.sh and lib/pr-review.sh use: X=\"\${BASH_SOURCE[0]%/*}\"; [ \"\$X\" != \"\${BASH_SOURCE[0]}\" ] || X=.; X=\"\$(cd \"\${X:-/}\" && pwd)\"
  In a hook, the two lines require-issue-fields.sh uses (claude-config#2081): case \"\${BASH_SOURCE[0]}\" in */*) X=\"\${BASH_SOURCE[0]%/*}\" ;; *) X=. ;; esac; X=\"\$(cd \"\${X:-/}\" && pwd)\""

# ---------------------------------------------------------------------------
# And each converted library, RUN, finds its own folder with no dirname to start (L3).
# ---------------------------------------------------------------------------
# Under a PATH holding nothing at all, from a folder that is not the library's, with bash named by
# its own path so nothing is looked up. The old line gave the caller's folder here. Each is traced
# and the last value the named variable took is read off the trace, so an executable library is
# stopped by a bad argument before it does anything, and a sourced one is only sourced: with no
# PATH, nothing it would start can be started.
CALLER="$TMPROOT/caller"
mkdir -p "$CALLER"
LIBDIR="$DIR/lib"
traced(){   # traced <var> <folder> <bash args...> -> the last value <var> was given
  local var="$1" at="$2"
  shift 2
  (cd "$at" && PS4='+ ' PATH=/nonexistent "$BASH" -x "$@" 2>&1 >/dev/null </dev/null) \
    | awk -v v="$var" '
        { t = $0; sub(/^\++ /, "", t) }
        index(t, v "=") == 1 { val = substr(t, length(v) + 2); gsub(/^'"'"'|'"'"'$/, "", val); got = val }
        END { printf "%s", got }'
}
expect_dir(){   # expect_dir <label> <expected> <var> <folder> <bash args...>
  local label="$1" want="$2" got
  shift 2
  got="$(traced "$@")"
  [ "$got" = "$want" ] && check "$label" ok || check "$label" "expected '$want', got '${got:-nothing}'"
}
expect_dir "#1104 pr-review.sh, run from another folder, knows its own" "$LIBDIR" PRR_LIB "$CALLER" "$LIBDIR/pr-review.sh" start --dir
expect_dir "#1104 pr-review-report.sh, run from another folder, knows its own" "$LIBDIR" LIB "$CALLER" "$LIBDIR/pr-review-report.sh" --days
expect_dir "#1104 merge-when-ready.sh, run from another folder, knows its own" "$LIBDIR" MWR_LIB "$CALLER" "$LIBDIR/merge-when-ready.sh" --not-an-option
expect_dir "#1104 push-scope.sh, sourced from another folder, finds shell-words.py beside it" "$LIBDIR/shell-words.py" PS_SHELL_WORDS "$CALLER" -c '. "$1"' _ "$LIBDIR/push-scope.sh"
expect_dir "#1104 merge-target.sh, sourced from another folder, finds shell-words.py beside it" "$LIBDIR/shell-words.py" MT_SHELL_WORDS "$CALLER" -c '. "$1"' _ "$LIBDIR/merge-target.sh"
expect_dir "#1104 and sources the push-scope.sh beside it, not the caller's" "$LIBDIR/shell-words.py" PS_SHELL_WORDS "$CALLER" -c '. "$1"' _ "$LIBDIR/merge-target.sh"
expect_dir "#1104 sleep-queue.sh, sourced from another folder, knows its own" "$LIBDIR" _SQ_LIB "$CALLER" -c '. "$1"' _ "$LIBDIR/sleep-queue.sh"
expect_dir "#1104 suite-deadline.sh, sourced from another folder, knows its own" "$LIBDIR" _suite_deadline_dir "$CALLER" -c '. "$1"' _ "$LIBDIR/suite-deadline.sh"
expect_dir "#1104 ai-review-common.sh finds the redaction rules beside it when asked to redact" "$LIBDIR/review-redact.sed" rules "$CALLER" -c '. "$1"; ar_redact' _ "$LIBDIR/ai-review-common.sh"
# A relative path, and a bare name found in the current folder, are the two spellings with no
# leading slash, so the expansion's two other branches are driven too.
expect_dir "#1104 sourced by a relative path, a library still knows its own folder" "$LIBDIR" _suite_deadline_dir "$DIR" -c '. lib/suite-deadline.sh'
expect_dir "#1104 sourced by a bare name from its own folder, it knows it too" "$LIBDIR" _suite_deadline_dir "$LIBDIR" -c '. suite-deadline.sh'

# ---------------------------------------------------------------------------
# And every hook, RUN from a folder that is not its own, loads its own lib/ (claude-config#2130).
# ---------------------------------------------------------------------------
# The folder it is run from holds a decoy of every library and every hook by name, each of which
# says so when sourced, so a hook that took the working directory for its own folder loads one and
# is caught. Nothing on PATH, so no dirname, and an emptied environment with HOME and TMPDIR in the
# throwaway folder, so whatever a hook writes lands there. Each hook is traced, and passes only once
# the trace shows it changing into its own folder: a hook that stopped before locating itself has
# shown nothing, and is not counted as having passed (L98). It is tried with nothing on stdin, then
# with a command naming the words the hooks that answer at once look for first.
# shellcheck source=lib/bounded-run.sh
. "$LIBDIR/bounded-run.sh" || { check "lib/bounded-run.sh loads" "it is missing, so no hook could be run"; }
DECOY="$TMPROOT/decoy"
mkdir -p "$DECOY/lib" "$TMPROOT/home" "$TMPROOT/tmp"
for f in "$DIR"/*.sh "$LIBDIR"/*.sh; do
  case "$f" in "$LIBDIR"/*) at="$DECOY/lib" ;; *) at="$DECOY" ;; esac
  printf 'printf "DECOY LOADED %%s\\n" "${BASH_SOURCE[0]}" >&2\n' > "$at/${f##*/}"
done
INPUTS="$TMPROOT/inputs"
mkdir -p "$INPUTS"
: > "$INPUTS/1-empty"
printf '{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"%s","tool_input":{"command":"gh issue create --title t --body b && gh run watch 1 -i 5 && rtk init -g && git branch -D x && gh pr comment 1 --body b && log show"}}' "$DECOY" > "$INPUTS/2-command"
# cat alone on PATH, so a hook can read its payload at all, and nothing else (dirname least of all).
CAT_ONLY="$TMPROOT/cat-only"
mkdir -p "$CAT_ONLY"
ln -s "$(command -v cat)" "$CAT_ONLY/cat"
# Its own folder, shown in the trace as a folder changed into, a value given, or a file sourced from it.
own_re="^\\++ (cd '?${DIR}'?\$|[A-Za-z_][A-Za-z_0-9]*='?${DIR}'?\$|(\\.|source) '?${DIR}/)"
ran=0
for hook in "$DIR"/*.sh; do
  name="${hook##*/}"
  case "$name" in test-*) continue ;; esac
  grep -q 'BASH_SOURCE' "$hook" || continue
  ran=$((ran + 1))
  # Every input is run, since a hook that finds its folder rightly at one line can go on, on a
  # longer path, to a line that finds it wrongly: any wrong one fails it, and one right one is needed.
  verdict="no input reached the line where it finds its own folder"
  for input in "$INPUTS"/*; do
    # HOOK_TESTS_LIST_ONLY makes the test runner list its directories and stop, instead of running
    # every suite in the repo from the decoy folder; no other hook reads it.
    bounded_run 20 env -i HOME="$TMPROOT/home" TMPDIR="$TMPROOT/tmp" HOOK_TESTS_LIST_ONLY=1 PS4='+ ' "$BASH" -c \
      'cd "$1" && PATH="$4" exec "$BASH" -x "$2" < "$3"' _ "$DECOY" "$hook" "$input" "$CAT_ONLY"
    if [[ "$BOUNDED_OUT" == *"DECOY LOADED"* ]]; then
      decoy_line="${BOUNDED_OUT#*DECOY LOADED}"
      verdict="it loaded a decoy from the folder it was run from: DECOY LOADED${decoy_line%%$'\n'*}"; break
    fi
    if [[ "$BOUNDED_OUT" == *"${_D}: command not found"* ]]; then
      verdict="it ran ${_D} to find its own folder, and with none on PATH took another"; break
    fi
    grep -E -q "$own_re" <<< "$BOUNDED_OUT" && verdict=ok
  done
  check "#2130 $name, run from another folder with nothing on PATH, finds its own lib/" "$verdict"
done
# A loop that ran no hook judged nothing (L98).
[ "$ran" -ge 40 ] && check "the hooks to run were found ($ran)" ok \
  || check "the hooks to run were found ($ran)" "too few hooks under $DIR name BASH_SOURCE, so the loop above judged almost nothing"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
