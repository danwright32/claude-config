#!/usr/bin/env bash
#
# prove-it-fails.sh: take a check, break the thing it checks, and report whether it noticed.
#
# A guard is only real once it has been seen to fail (L1). This repo checks that by hand: remove
# the fix, run the section, put the fix back. On 2026-09-02 that was done four times in one session
# and TWICE the section still passed with the fix removed, so the test proved nothing and would
# have shipped believing otherwise. Both times the cause was the fixture never reaching the state
# under test: once the fixture's CLAUDE.md imported nothing so the comparison never ran, and once
# an assertion matched a filename anywhere in the output rather than on the line that names it.
#
# The manual version edits a tracked file and depends on remembering to put it back, so an
# interrupted round leaves the tree modified, and it costs enough that it is skipped exactly when
# the suite is slow, which is when new tests are being written (claude-config#276).
#
# Everything here happens on a COPY. The tree you are working in is never touched.
#
# Usage:
#   tools/prove-it-fails.sh --run '<command>' [--sed <file> <expr>]... [--revert <file>]...
#                           [--repo <dir>] [--no-baseline] [--keep]
#
#   --run <command>     the command that runs the check, as it would be typed at the top of the
#                       repo, for instance:
#                         SECTION_ONLY='only one suite run at a time' bash tests/test-claude-sync.sh
#                         bash payload/hooks/test-run-all-tests.sh
#   --sed <file> <expr> apply one sed expression to one file in the copy. Repeatable.
#   --revert <file>     restore one file in the copy to its committed state, which is how you
#                       remove a fix that is not committed yet. Repeatable.
#   --repo <dir>        the tree to copy (default: the repository this script is in).
#   --no-baseline       skip the run that proves the check passes BEFORE the change.
#   --keep              leave the copy behind and say where it is.
#
# Exit codes, because a caller that reads only the output cannot tell these apart:
#   0  PROVED      the check passed before the change and failed after it.
#   1  NOT PROVED  the check still passed with the change applied, so it does not discriminate.
#   2  REFUSED     nothing was proved and nothing was measured: a patch that matched nothing, a
#                  baseline that was already failing, a usage error.
set -uo pipefail

usage(){ sed -n '3,40p' "$0" >&2; exit 2; }

RUN=""
REPO=""
KEEP=""
BASELINE=1
SED_FILES=(); SED_EXPRS=(); REVERTS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --run)     RUN="${2:-}"; shift 2 || usage ;;
    --repo)    REPO="${2:-}"; shift 2 || usage ;;
    --sed)     [ "$#" -ge 3 ] || usage; SED_FILES+=("$2"); SED_EXPRS+=("$3"); shift 3 ;;
    --revert)  [ "$#" -ge 2 ] || usage; REVERTS+=("$2"); shift 2 ;;
    --no-baseline) BASELINE=0; shift ;;
    --keep)    KEEP=1; shift ;;
    -h|--help) usage ;;
    *) echo "prove-it-fails: unknown argument '$1'." >&2; usage ;;
  esac
done

[ -n "$RUN" ] || { echo "prove-it-fails: --run is required: it is the command that runs the check." >&2; exit 2; }
if [ "${#SED_FILES[@]}" -eq 0 ] && [ "${#REVERTS[@]}" -eq 0 ]; then
  echo "prove-it-fails: nothing to break. Give at least one --sed or --revert, or this would run the check twice and tell you it passes." >&2
  exit 2
fi

if [ -z "$REPO" ]; then
  REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && git rev-parse --show-toplevel 2>/dev/null || true)"
fi
[ -n "$REPO" ] && [ -d "$REPO" ] || { echo "prove-it-fails: no repository to copy. Pass --repo." >&2; exit 2; }
REPO="${REPO%/}"

COPY="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.prove-it-fails.XXXXXXXX")" || COPY=""
case "${COPY%/}" in
  ''|/|"${HOME%/}") echo "prove-it-fails: refusing to run: the throwaway directory came back as '$COPY'." >&2; exit 2 ;;
esac
cleanup(){
  if [ -n "$KEEP" ]; then
    echo "prove-it-fails: the copy is at $COPY"
  else
    rm -rf "$COPY" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# The whole tree, .git included, because several suites here REFUSE to run without a repository
# above them and would report SUITE-NOT-RUN rather than a verdict, which reads exactly like a check
# that noticed nothing (L98). `cp -Rc` clones on APFS, so this is 0.4s for the 47MB this repo is.
cp -Rc "$REPO/." "$COPY/" 2>/dev/null || cp -R "$REPO/." "$COPY/" || {
  echo "prove-it-fails: could not copy $REPO." >&2; exit 2; }

# Its own lock and its own spool. A proof run is something you do WHILE working, so it must not
# take the lock a real run is using, and it must not write into the real findings spool (L2).
export SUITE_LOCK="$COPY/.prove-it-fails.lock"
export CLAUDE_ISSUE_SPOOL_DIR="$COPY/.prove-it-fails.spool"
mkdir -p "$CLAUDE_ISSUE_SPOOL_DIR"

# One in place edit that works on both seds this repo runs on. Decided by asking the tool rather
# than by trying one form and falling back, because the BSD form on GNU sed rewrites the file with
# an empty script before it fails, which is a write nobody asked for on the way to the fallback.
sed_inplace(){ # <expr> <file>
  if sed --version >/dev/null 2>&1; then sed -i -e "$1" "$2"; else sed -i '' -e "$1" "$2"; fi
}

run_check(){ # run_check <label> -> prints the output, returns the command's own code
  ( cd "$COPY" && eval "$RUN" ) 2>&1
}

# The BASELINE first. A section that was already failing proves nothing about the change, and its
# red is indistinguishable from the red this tool exists to produce (L159, L11). This is the half
# the manual ritual skipped, because the person had just watched it pass.
if [ "$BASELINE" -eq 1 ]; then
  echo "prove-it-fails: running the check BEFORE the change, to see it pass."
  base_out="$(run_check baseline)"; base_rc=$?
  if [ "$base_rc" -ne 0 ]; then
    echo "REFUSED: the check ALREADY FAILS without any change, so nothing here can be proved by it failing again." >&2
    printf '%s\n' "$base_out" | grep -iE '^ *(FAIL|not ok)' | sed 's/^/  /' | awk 'NR <= 10'
    echo "  Fix the check first, or pass --no-baseline if you know why it is red." >&2
    exit 2
  fi
fi

# Now break it. Each change is confirmed to have CHANGED SOMETHING, because a patch that matched
# nothing produces a passing check that looks exactly like a check which does not discriminate
# (L100, L98). That is the failure this tool exists to remove, so it refuses rather than answers.
applied=0
_i=0
while [ "$_i" -lt "${#SED_FILES[@]}" ]; do
  f="${SED_FILES[$_i]}"; e="${SED_EXPRS[$_i]}"; _i=$((_i + 1))
  t="$COPY/$f"
  [ -f "$t" ] || { echo "REFUSED: --sed names $f, which is not a file in the copy." >&2; exit 2; }
  before="$(cksum < "$t")"
  sed_inplace "$e" "$t" || { echo "REFUSED: sed could not apply '$e' to $f." >&2; exit 2; }
  after="$(cksum < "$t")"
  if [ "$before" = "$after" ]; then
    echo "REFUSED: '$e' changed nothing in $f. A patch that matched nothing leaves the check passing for the same reason it always did, which is the answer this tool exists NOT to give." >&2
    exit 2
  fi
  echo "prove-it-fails: applied '$e' to $f"
  applied=$((applied + 1))
done

for f in "${REVERTS[@]:-}"; do
  [ -n "$f" ] || continue
  t="$COPY/$f"
  [ -f "$t" ] || { echo "REFUSED: --revert names $f, which is not a file in the copy." >&2; exit 2; }
  committed="$(git -C "$COPY" show "HEAD:$f" 2>/dev/null)" || {
    echo "REFUSED: $f is not in HEAD, so there is no committed state to go back to." >&2; exit 2; }
  before="$(cksum < "$t")"
  printf '%s\n' "$committed" > "$t"
  after="$(cksum < "$t")"
  if [ "$before" = "$after" ]; then
    echo "REFUSED: $f is already exactly what HEAD holds, so reverting it removed nothing. Name the file the fix is in, or commit the test first and revert that instead." >&2
    exit 2
  fi
  echo "prove-it-fails: reverted $f to its committed state"
  applied=$((applied + 1))
done

echo "prove-it-fails: running the check WITH the change applied."
out="$(run_check broken)"; rc=$?
fails="$(printf '%s\n' "$out" | grep -icE '^ *(FAIL|not ok)' || true)"
case "$fails" in ''|*[!0-9]*) fails=0 ;; esac

if [ "$rc" -ne 0 ]; then
  echo "PROVED: the check noticed. It passed before the change and failed after it."
  if [ "$fails" -gt 0 ]; then
    echo "  $fails line(s) reported a failure, the first of them:"
    printf '%s\n' "$out" | grep -iE '^ *(FAIL|not ok)' | awk 'NR <= 5' | sed 's/^/    /'
  else
    echo "  It exited $rc without printing a line this could recognise as a failure, so read its output:"
    printf '%s\n' "$out" | awk 'NR <= 10' | sed 's/^/    /'
  fi
  exit 0
fi

echo "NOT PROVED: the check still passed with the change applied, so it does not discriminate."
echo "  The two causes that have actually happened here are a fixture that never reaches the state"
echo "  under test, and an assertion that matches its target anywhere in the output rather than on"
echo "  the line that carries it. Both leave a test that can only ever pass."
printf '%s\n' "$out" | awk 'NR <= 10' | sed 's/^/    /'
exit 1
