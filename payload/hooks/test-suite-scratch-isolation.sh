#!/usr/bin/env bash
# No suite may write its working files to a path another run of it will write to as well
# (claude-config#180, widened by claude-config#186).
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
#
# ---- and the same class in the SHARED temp directory (claude-config#186) ----
#
# The first version looked only under $DIR or $SELF_DIR, which is the location the incident
# happened in. test-subagent-issue-harvest.sh wrote and removed a FIXED name under the shared temp
# directory instead, which two concurrent runs destroy for each other in exactly the same way, and
# this guard reported the tree clean the whole time. A guard that covers only where the fault was
# found leaves the class alive while reading as proof it is gone (L30, L96).
#
# So a fixed path anywhere in the shared temp directory counts too. "Fixed" is judged by TEXT: the
# whole path after the temp root is literal, with nothing in it that could differ between runs.
# That is what this can actually prove by reading a file, and it is the shape the real offenders
# have. What it deliberately does NOT claim is that a path CONTAINING a variable is safe: it may be
# per run, as the review stamps here are (they interpolate a directory that came from mktemp), or
# it may be a constant under another name, which this cannot see. Removals count as well as writes,
# because a removal of a shared name destroys another run's file just as completely, and the write
# is often done by the code under test rather than by the suite.
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
OWN_PATTERN="${GT}{1,2}[[:space:]]*\"?[\$][{]?(DIR|SELF_DIR)[}]?/"

# The shared temp directory, in every spelling a suite here actually uses. Longest first, so
# /private/tmp is not consumed by the /tmp alternative sitting to its left.
TMPROOT_PATTERN='(\$\{TMPDIR:-/tmp\}|\$\{TMPDIR\}|\$TMPDIR|/private/tmp|/var/tmp|/tmp)'
# A path with no interpolation anywhere in it. The terminator is required: without it the match
# could stop early and a genuinely per run path like ...review-$(...).stamp would be reported as a
# constant, which is a guard accusing the code that got it right.
LITERAL_TAIL='[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*'
FIXED_TMP="(\"${TMPROOT_PATTERN}/${LITERAL_TAIL}\"|${TMPROOT_PATTERN}/${LITERAL_TAIL}([[:space:]]|;|$))"
SHARED_PATTERN="(${GT}{1,2}[[:space:]]*${FIXED_TMP}|(^|[[:space:]])rm([[:space:]]+-[A-Za-z]+)*[[:space:]]+${FIXED_TMP})"

shares_a_path(){   # shares_a_path <file>  -> the offending lines, if any
  grep -nE "$OWN_PATTERN" "$1" 2>/dev/null || true
  grep -nE "$SHARED_PATTERN" "$1" 2>/dev/null || true
}
writes_into_own_dir(){   # kept as the narrower question, for the fixtures that ask only that
  grep -nE "$OWN_PATTERN" "$1" 2>/dev/null || true
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

# The widened half, both directions, on its own fixtures. Assembled from pieces for the same reason
# as the pattern above: written out whole, these lines would make this file its own offender.
TD='${TMPDIR:-/tmp}'
BADTMP="$TMPROOT/badtmp.sh"
GOODTMP="$TMPROOT/goodtmp.sh"
{
  printf 'printf x %s "%s/claude-issue-spool-lost.jsonl"\n' "$GT$GT" "$TD"
  printf 'rm -f "%s/claude-issue-spool-lost.jsonl"\n' "$TD"
  printf 'awk "{print}" y %s "/tmp/one-fixed-name.txt"\n' "$GT"
} > "$BADTMP"
{
  # A directory this run obtained for itself, which is the shape every suite should use.
  printf 'W="$(mktemp -d)"\n'
  printf 'rm -f "$W/claude-issue-spool-lost.jsonl"\n'
  # Per run because the name interpolates something, which is as much as reading the text can say.
  printf 'rm -f "%s/claude-feature-issue-review-$(printf %%s "$REPO" | shasum).stamp"\n' "$TD"
  # Merely NAMING the shared directory is not writing to it.
  printf 'echo "%s/not-written-to"\n' "$TD"
  printf 'case "$cwd" in "/tmp/somewhere") : ;; esac\n'
} > "$GOODTMP"

[ "$(shares_a_path "$BADTMP" | grep -c .)" = 3 ] \
  && check "it catches a fixed path in the shared temp directory" ok \
  || check "it catches a fixed path in the shared temp directory" "it found $(shares_a_path "$BADTMP" | grep -c .) of the 3 planted"
shared_blank="$(shares_a_path "$GOODTMP")"
[ -z "$shared_blank" ] \
  && check "and leaves a per-run path in that directory alone" ok \
  || check "and leaves a per-run path in that directory alone" "it flagged: $shared_blank"
# The two halves must both still be live in the combined question, or one of them could be broken
# while the pair reads as working (L178).
[ "$(shares_a_path "$BADFIX" | grep -c .)" = 2 ] \
  && check "and the own-directory half is still asked by the combined check" ok \
  || check "and the own-directory half is still asked by the combined check" "it found $(shares_a_path "$BADFIX" | grep -c .) of the 2 planted"

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
  hits="$(shares_a_path "$f")"
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
    check "no suite writes its working files to a path it shares with itself" "these do:
$offenders  Take a directory from mktemp and write there, so two runs at once cannot share one path." ;;
  *) check "no suite writes its working files to a path it shares with itself" ok ;;
esac

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
