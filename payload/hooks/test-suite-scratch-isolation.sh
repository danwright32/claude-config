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

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${SCRATCH_ISOLATION_ROOT:-$(bash "$DIR/lib/checkout-root.sh" "$DIR/.." 2>/dev/null || true)}"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

# No repository here is not a failure of this suite's subject, it is a place it cannot be asked. Its
# own wording, so it stays distinguishable from the siblings that refuse for their own reasons (L11).
if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
  echo "test-suite-scratch-isolation: $DIR is not in a claude-config checkout, so there were no suites to read." >&2
  printf 'SUITE-NOT-RUN %s\n' "needs the repository to read every suite in it, and $DIR is not in a claude-config checkout"
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

# ---- and the same path reached through a NAME (claude-config#190) ----
#
# The two patterns above judge the text of the target, so a suite that stores the shared path in a
# variable first and writes through that name was invisible to them, one edit away from the shape
# they exist to catch. So the names a file assigns are classified before the tree is read.
#
# Per run wins over fixed, and is worked out FIRST, to a fixpoint: a name assigned from mktemp is
# per run, so is one built from the shell's own per process values, and so is any name whose value
# mentions a name already known to be per run. That last step is what matters in practice, because
# the usual shape is a throwaway root followed by two or three names derived from it, and stopping
# after one hop would accuse every one of them.
#
# What it deliberately does NOT resolve: a value that reaches the temp root through ANOTHER
# defaulted expansion, as in NAME="${NAME:-${TMPDIR:-/tmp}/thing}". Those are read as neither, so
# they are not accused and not cleared. This suite's own shared lock is one, and it is shared on
# purpose; widening to reach it would mean an exemption list, and an exemption is only worth having
# when somebody has written down why (L233).
_alternation(){   # " A B C " -> "A|B|C", empty for an empty set
  printf '%s' "$1" | sed 's/^ *//; s/ *$//; s/  */|/g'
}
PER_RUN_NAMES=" "
FIXED_TMP_NAMES=" "
classify_names(){   # classify_names <file>
  local assigns lists
  PER_RUN_NAMES=" "; FIXED_TMP_NAMES=" "
  # Nothing to classify unless the file assigns a name a fixed temp path in the first place, and
  # almost none do. Exactly equivalent to running the whole thing, because FIXED_TMP_NAMES can only
  # ever be filled from an assignment of this shape, and it is one grep instead of a pass per hop
  # over every assignment in the file: without it this guard went from under a second to fifty,
  # since the sync suite alone holds thousands of assignments.
  grep -qE "=[[:space:]]*${FIXED_TMP}" "$1" 2>/dev/null || return 0
  assigns="$(grep -hE '^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=' "$1" 2>/dev/null || true)"
  [ -n "$assigns" ] || return 0
  # Four hops is measured against the real files rather than chosen: the longest chain in this repo
  # is three (a mktemp root, a temp directory under it, a file under that). A chain longer than this
  # stops being resolved, which leaves it unaccused rather than wrongly accused.
  #
  # Worked out in ONE perl pass over the assignments, never a shell step per assignment per hop
  # (claude-config#3662, L297): on 2026-11-25 that loop spent 42 seconds of processor time on the
  # sync suite's 3,831 assignments, nearly all of this suite's cost. The rules are the loop's, step
  # for step: the leading blanks and one `export ` taken off; the name before the first `=`, skipped
  # unless it is letters, digits and underscores; a name already per run skipped; per run when its
  # value names mktemp, `$$` or `$RANDOM`, at once, or when it mentions `$NAME` or `${NAME` followed
  # by anything but a name character, where NAME was already per run when the hop began; then fixed
  # when a name not per run has a value that opens, after blanks, with FIXED_TMP, read from the
  # environment so the pattern stays the one written above. A name assigned twice is listed twice,
  # as before. Each list comes back on a line of its own, in the order the loop built it.
  #
  # The assignments go in on standard input, never in the environment: Linux refuses any one
  # environment string over 128 KB (MAX_ARG_STRLEN) before perl starts, and the sync suite's are
  # 260 KB (measured 2026-11-25), so on CI it would have been reported as unclassified.
  lists="$(SI_FIXED_TMP="$FIXED_TMP" perl -e '
    my $fixed = $ENV{SI_FIXED_TMP};
    my $in = do { local $/; <STDIN> };
    my @e;
    for my $entry (split /\n/, defined $in ? $in : "") {
      next if $entry eq "";
      $entry =~ s/^[[:space:]]+//;
      $entry =~ s/^export //;
      my $i = index($entry, "=");
      my ($name, $value) = $i < 0 ? ($entry, $entry) : (substr($entry, 0, $i), substr($entry, $i + 1));
      next if $name eq "" || $name =~ /[^A-Za-z0-9_]/;
      push @e, [$name, $value];
    }
    my (%per, @per);
    for my $hop (1 .. 4) {
      my $alt = join "|", @per;
      my $re = length($alt) ? qr/\$[{]?(?:$alt)(?:[^A-Za-z0-9_]|\z)/ : undef;
      for (@e) {
        my ($name, $value) = @$_;
        next if $per{$name};
        if ($value =~ /mktemp|\$\$|\$RANDOM/) { $per{$name} = 1; push @per, $name; next; }
        next unless $re;
        if ($value =~ $re) { $per{$name} = 1; push @per, $name; }
      }
    }
    my $start = qr/^[[:space:]]*(?:$fixed)/;
    my @fixed = map { $_->[0] } grep { !$per{$_->[0]} && $_->[1] =~ $start } @e;
    print join(" ", "", @per, ""), "\n", join(" ", "", @fixed, ""), "\n";
  ' <<< "$assigns")" || lists=""
  PER_RUN_NAMES="${lists%%$'\n'*}"
  FIXED_TMP_NAMES="${lists#*$'\n'}"
  # Two lists or nothing: a perl that did not answer is not a file with no names in it (L10), so
  # the caller is told, and shares_a_path reports the file rather than passing it.
  case "$lists" in
    " "*$'\n'" "*) ;;
    *) PER_RUN_NAMES=" "; FIXED_TMP_NAMES=" "; return 1 ;;
  esac
  return 0
}

shares_a_path(){   # shares_a_path <file>  -> the offending lines, if any
  local alt varref pattern
  grep -nE "$OWN_PATTERN" "$1" 2>/dev/null || true
  grep -nE "$SHARED_PATTERN" "$1" 2>/dev/null || true
  classify_names "$1" || {
    echo "the names this file assigns could not be classified (perl gave no answer), so a shared temp path reached through one of them was not looked for"
    return 0
  }
  alt="$(_alternation "$FIXED_TMP_NAMES")"
  # No names to look for is not the same question as no matches, so the pattern is never built from
  # an empty set: an alternation with nothing in it matches an empty string and would report every
  # write in the file (L215 the other way up).
  [ -n "$alt" ] || return 0
  varref="\\\$[{]?($alt)[}]?"
  pattern="(${GT}{1,2}[[:space:]]*\"?${varref}|(^|[[:space:]])rm([[:space:]]+-[A-Za-z]+)*[[:space:]]+\"?${varref})"
  grep -nE "$pattern" "$1" 2>/dev/null || true
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
# ---- the same path reached through a NAME (claude-config#190) ----
# The variable half needs its own pair, and the good fixture is deliberately THREE hops (a mktemp
# root, a temp directory under it, a file under that), because a resolver that stopped after one
# would clear the bad fixture's shape and accuse this one, and a single-hop fixture could not tell
# the two apart.
BADVAR="$TMPROOT/badvar.sh"
GOODVAR="$TMPROOT/goodvar.sh"
{
  printf 'L="%s/shared-name.txt"\n' "$TD"
  printf 'printf x %s "$L"\n' "$GT$GT"
  printf 'rm -f "$L"\n'
} > "$BADVAR"
{
  printf 'W="$(mktemp -d)"\n'
  printf 'export TD2="$W/tmp"\n'
  printf 'L2="$TD2/shared-name.txt"\n'
  printf 'printf x %s "$L2"\n' "$GT$GT"
  printf 'rm -f "$L2"\n'
} > "$GOODVAR"

[ "$(shares_a_path "$BADVAR" | grep -c .)" = 2 ] \
  && check "it catches a shared path reached through a name" ok \
  || check "it catches a shared path reached through a name" "it found $(shares_a_path "$BADVAR" | grep -c .) of the 2 planted"
var_blank="$(shares_a_path "$GOODVAR")"
[ -z "$var_blank" ] \
  && check "and follows a name back to the throwaway directory it came from" ok \
  || check "and follows a name back to the throwaway directory it came from" "it flagged: $var_blank"

# The two halves must both still be live in the combined question, or one of them could be broken
# while the pair reads as working (L178).
[ "$(shares_a_path "$BADFIX" | grep -c .)" = 2 ] \
  && check "and the own-directory half is still asked by the combined check" ok \
  || check "and the own-directory half is still asked by the combined check" "it found $(shares_a_path "$BADFIX" | grep -c .) of the 2 planted"

# THE NAMES ARE CLASSIFIED IN ONE PASS PER FILE, NOT ONE SHELL STEP PER ASSIGNMENT PER HOP
# (claude-config#3662, L297). On 2026-11-25 the sync suite's 3,831 assignments, 1,957 of them per
# run, cost the shell loop 42 seconds of processor time (one sample, load average 131), because each
# assignment not yet per run was matched against an alternation of every per run name, compiled
# afresh, on each of four hops: most of the 53 seconds of processor time this suite took alone (60
# of wall clock, one sample at a load average of 18), and it took 75 inside the push gate, the gate's
# largest scanner on a push that changes no suite. A file of that shape is
# classified here, a throwaway root, 1,500 names under it and 500 plain ones, and the processor time
# it takes (user and system, the shell's and its children's, never the wall clock, which measures the
# Mac's load: L290) must stay under 3 seconds. The shell loop took 12.8 on it (one sample, load
# average 49 to 98), the perl pass 0.13. Each value is padded so the assignments come to about 250
# KB, as the sync suite's do, past the 128 KB Linux allows one environment string, so a hand off
# through the environment fails here on CI rather than only on the real tree.
{
  printf 'ROOT_T="$(mktemp -d)"\n'
  printf 'SHARED="%s/one-fixed-name.txt"\n' "$TD"
  awk 'BEGIN { pad = sprintf("%0100d", 0); for (i = 0; i < 1500; i++) printf "P%d=\"$ROOT_T/p%d/%s\"\n", i, i, pad; for (i = 0; i < 500; i++) printf "V%d=\"plain value %d %s\"\n", i, i, pad }'
  printf 'D1="$ROOT_T/a"\nD2="$D1/b"\nD3="$D2/c"\n'
  printf 'printf x %s "$SHARED"\n' "$GT$GT"
} > "$TMPROOT/many-assigns.sh"
_ci_t="$( { TIMEFORMAT='%U %S'; time classify_names "$TMPROOT/many-assigns.sh"; } 2>&1 >/dev/null )"
_ci_cpu="$(printf '%s\n' "$_ci_t" | awk 'NF == 2 { printf "%.2f", $1 + $2 }')"
classify_names "$TMPROOT/many-assigns.sh"
[ "$FIXED_TMP_NAMES" = " SHARED " ] \
  && check "a file of 2,000 assignments has its one fixed temp name found" ok \
  || check "a file of 2,000 assignments has its one fixed temp name found" "the fixed names came back as '$FIXED_TMP_NAMES'"
_ci_missing=""
for _ci_n in ROOT_T P0 P1499 D1 D2 D3; do
  case "$PER_RUN_NAMES" in *" $_ci_n "*) ;; *) _ci_missing="$_ci_missing $_ci_n" ;; esac
done
case "$PER_RUN_NAMES" in *" V0 "*|*" SHARED "*) _ci_missing="$_ci_missing (and a plain name was taken for per run)" ;; esac
[ -z "$_ci_missing" ] \
  && check "and the names under its throwaway root are followed to the end of their chain" ok \
  || check "and the names under its throwaway root are followed to the end of their chain" "missing:$_ci_missing"
[ "$(shares_a_path "$TMPROOT/many-assigns.sh" | grep -c .)" = 1 ] \
  && check "and the one write through the fixed name is reported" ok \
  || check "and the one write through the fixed name is reported" "it reported: $(shares_a_path "$TMPROOT/many-assigns.sh")"
# A perl that gives no answer is not a file with nothing to report: the file is reported, so the
# tree check fails naming it rather than passing a file nobody classified (L10).
_ci_nop="$(perl() { return 1; }; shares_a_path "$BADVAR")"
case "$_ci_nop" in
  *"could not be classified"*) check "a classification that gives no answer reports the file instead of passing it" ok ;;
  *) check "a classification that gives no answer reports the file instead of passing it" "it reported: ${_ci_nop:-nothing}" ;;
esac
awk -v c="${_ci_cpu:-x}" 'BEGIN { exit !(c ~ /^[0-9.]+$/ && c + 0 < 3) }' \
  && check "and classifying it takes under 3 seconds of processor time ($_ci_cpu)" ok \
  || check "and classifying it takes under 3 seconds of processor time" "it took '${_ci_cpu:-unread}' (the time keyword printed '$_ci_t'), so the names are being worked out a shell step at a time again"

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
$(bash "$DIR/lib/repo-files.sh" "$ROOT" 2>/dev/null || true)
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
