#!/usr/bin/env bash
# No suite may write its working files into its OWN directory (claude-config#180).
#
# test-check-style-guide.sh and test-check-closing-keyword.sh each extracted the detector out of
# the hook they test and wrote it to a FIXED name beside themselves, in payload/hooks. That is one
# path shared by every run of that suite on the machine, so two runs at once truncate and then
# delete each other's copy, and the second one reads a half written file and reports that the
# detector found nothing. Measured 2026-08-22: three concurrent runs of run-all-tests.sh produced
# `FAIL: expected a finding: em dash in a brand-new untracked file` and two more like it, all green
# again on the next run. Nothing said the cause was a shared file rather than a slow machine, and a
# check that goes red for reasons unrelated to its subject is one people learn to skim (L36, L205).
#
# It is also the wrong directory to write in at all: a run killed between the write and the delete
# leaves a stray file inside the tree the sync mirrors, so it travels to the other Mac.
#
# So this is a ratchet on the CLASS rather than a fix to the two (L30). Every suite gets its
# throwaway directory from mktemp, which is unique per run by construction.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${SCRATCH_ISOLATION_ROOT:-$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null || true)}"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

# No repository here is not a failure of this suite's subject, it is a place it cannot be asked. Its
# own wording, so it stays distinguishable from the siblings that refuse for their own reasons (L11).
if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
  echo "test-suite-scratch-isolation: no repo above $DIR, so there were no suites to read." >&2
  printf 'SUITE-NOT-RUN %s\n' "needs the repository to read every suite in it, and there is none above $DIR"
  exit 2
fi

# Assembled from pieces so this file holds no literal occurrence of what it looks for, and cannot
# answer its own question (the trick test-suite-result-line.sh needs for the same reason).
GT='>'
PATTERN="${GT}{1,2}[[:space:]]*\"?[\$][{]?(DIR|SELF_DIR)[}]?/"

writes_into_own_dir(){   # writes_into_own_dir <file>  -> the offending lines, if any
  grep -nE "$PATTERN" "$1" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Both answers on a fixture first, or a pattern that matched nothing would report a perfectly clean
# tree and a pattern that matched everything would look identical to a working check (L1, L104).
# ---------------------------------------------------------------------------
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.scratchiso.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-suite-scratch-isolation: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

BADFIX="$TMPROOT/bad.sh"
GOODFIX="$TMPROOT/good.sh"
printf 'awk "{print}" x %s "$DIR/.detector.tmp.py"\n' "$GT" > "$BADFIX"
printf 'printf x %s "$DIR/.other.tmp"\n' "$GT$GT" >> "$BADFIX"
{
  printf 'W="$(mktemp -d)"\n'
  printf 'awk "{print}" x %s "$W/.detector.tmp.py"\n' "$GT"
  printf 'echo "$DIR/something" \n'
} > "$GOODFIX"

[ -n "$(writes_into_own_dir "$BADFIX")" ] \
  && check "it catches a write into the suite's own directory" ok \
  || check "it catches a write into the suite's own directory" "it found nothing in the bad fixture"
[ "$(writes_into_own_dir "$BADFIX" | grep -c .)" = 2 ] \
  && check "and catches an appending one as well as a truncating one" ok \
  || check "and catches an appending one as well as a truncating one" "it found $(writes_into_own_dir "$BADFIX" | grep -c .) of the 2 planted"
is_blank_out="$(writes_into_own_dir "$GOODFIX")"
[ -z "$is_blank_out" ] \
  && check "and leaves a write into a throwaway directory alone" ok \
  || check "and leaves a write into a throwaway directory alone" "it flagged: $is_blank_out"

# ---------------------------------------------------------------------------
# The real tree. Read from git, so an untracked scratch copy of a suite is not counted.
# ---------------------------------------------------------------------------
offenders=""
seen=0
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  case "${rel##*/}" in test-*.sh) ;; *) continue ;; esac
  f="$ROOT/$rel"
  [ -f "$f" ] || continue
  seen=$((seen + 1))
  hits="$(writes_into_own_dir "$f")"
  [ -n "$hits" ] && offenders="$offenders  $rel
$(printf '%s\n' "$hits" | sed 's/^/    /')
"
done <<EOF
$(git -C "$ROOT" ls-files 2>/dev/null || true)
EOF

# A count that could only ever be zero is not a measurement, so the reading is asserted (L98).
[ "$seen" -ge 10 ] \
  && check "it found the repo's suites to read ($seen of them)" ok \
  || check "it found the repo's suites to read ($seen of them)" "only $seen, so this proves almost nothing"

case "$offenders" in
  *[![:space:]]*)
    check "no suite writes its working files beside itself" "these do:
$offenders  Take a directory from mktemp and write there, so two runs at once cannot share one path." ;;
  *) check "no suite writes its working files beside itself" ok ;;
esac

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
