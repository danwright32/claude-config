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
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${LIB_SELF_LOCATE_ROOT:-$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null || true)}"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
  echo "test-lib-self-locate: no repo above $DIR, so there were no files to read." >&2
  printf 'SUITE-NOT-RUN %s\n' "needs the repository to read its files, and there is none above $DIR"
  exit 2
fi

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/lib-self-locate.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-lib-self-locate: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

# The pattern, ASSEMBLED so this file holds no occurrence of the thing it forbids: dirname applied
# to the file's own path, BASH_SOURCE in any index or brace spelling, or $0.
_D="dir""name"
PATTERN="${_D}[[:space:]]+\"?\\\$(\\{?BASH_SOURCE|\\{?0([^0-9]|$))"

# Every uncommented line holding one, as "<path>:<line>", for the shell files under a lib/ folder
# named on stdin relative to $1. One grep over all of them, never one per file (L297).
sites_in(){   # $1 = root; stdin = repo relative paths
  local root="$1" rel
  local files=()
  while IFS= read -r rel; do
    case "$rel" in lib/*.sh|*/lib/*.sh) [ -f "$root/$rel" ] && files+=("$rel") ;; esac
  done
  [ "${#files[@]}" -gt 0 ] || return 0
  # -H always, or a single file is printed without its name and the comment filter misreads it.
  (cd "$root" && grep -HnE "$PATTERN" -- "${files[@]}" 2>/dev/null) \
    | awk '{ t = $0; sub(/^[^:]*:[0-9]+:/, "", t); if (t !~ /^[[:space:]]*#/) { split($0, p, ":"); print p[1] ":" p[2] } }'
  return 0
}

# ---------------------------------------------------------------------------
# The scan has to see every spelling, and not the fix or a dirname of anything else, first (L1).
# ---------------------------------------------------------------------------
mkdir -p "$TMPROOT/plant/hooks/lib" "$TMPROOT/plant/hooks/other"
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
} > "$TMPROOT/plant/hooks/lib/planted.sh"
printf 'A="$(%s "${BASH_SOURCE[0]}")"\n' "$_D" > "$TMPROOT/plant/hooks/other/not-a-lib.sh"
planted="$(printf '%s\n' hooks/lib/planted.sh hooks/other/not-a-lib.sh | sites_in "$TMPROOT/plant" | tr '\n' ' ')"
[ "$planted" = "hooks/lib/planted.sh:2 hooks/lib/planted.sh:3 hooks/lib/planted.sh:4 hooks/lib/planted.sh:5 hooks/lib/planted.sh:6 " ] \
  && check "the scan names every spelling in a library, and not a comment, another path, the fix or a file outside lib/" ok \
  || check "the scan names every spelling in a library, and not a comment, another path, the fix or a file outside lib/" "it named: ${planted:-nothing}"

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
found="$(printf '%s\n' "$FILES" | sites_in "$ROOT")"
[ -z "$found" ] \
  && check "no library finds its own folder with dirname" ok \
  || check "no library finds its own folder with dirname" "these do:
$found
  Use the parameter expansion lib/sleep.sh and lib/pr-review.sh use: X=\"\${BASH_SOURCE[0]%/*}\"; [ \"\$X\" != \"\${BASH_SOURCE[0]}\" ] || X=.; X=\"\$(cd \"\${X:-/}\" && pwd)\""

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

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
