#!/usr/bin/env bash
# A ratchet on pipelines whose reader can leave before the writer has finished (claude-config#132).
#
# `producer | grep -q needle` under `set -o pipefail` can report a failure that never happened:
# grep -q leaves on its FIRST match, the producer is killed by SIGPIPE, and the pipeline's status
# becomes that death (L183). `head` short circuits the same way.
#
# It bites only when the reader leaves while the writer still has data, so whether it fires depends
# on how big the text is and where in it the match falls. That makes it a SIZE THRESHOLD nobody is
# watching, and two of these were correct for months before their input grew.
#
# Measured here on 2026-08-22 rather than left as a claim about somebody else's runner: the probe
# further down runs one deliberately and it fired on this Mac, exit 141 over 3.7MB with `cat` as the
# producer and the match on the first line. An earlier attempt at 5MB did not fire, which is the
# point: what decides it is where the match falls and how much the writer still has queued, not the
# size alone, so a site that is correct today is not correct at any particular size tomorrow. Two of
# these were correct for months before their input grew:
#
#   the sync suite's #41 citation check started failing on the Linux runner the week the file it
#   reads gained one line per suite, and reported a citation it HAD found as missing;
#
#   the lessons advisory went silent on any push adding more than a pipe buffer of lines, which is
#   precisely when it has the most to say. That one is measured, not theorised: its suite has a
#   fixture that makes it happen.
#
# No site in SHIPPED code is left. That sentence was here while three files disproved it: widening
# the pattern in #153 made 180 sites visible that had always been present, and three of them were
# not tests (claude-config#162). What is left is overwhelmingly `printf '%s' "$var" | grep -q`
# inside tests, where the text is a fixture the test itself built. The count is written down so it
# can only go down.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASELINE="${SHORTCIRCUIT_BASELINE:-$DIR/shortcircuit-pipes.txt}"
# The rule a count based ratchet applies, shared with the two scans rather than written again here
# (claude-config#377). Its twin in lib/ratchet.py serves the python ones, and one committed fixture
# is driven through both so they cannot drift (L26).
RATCHET_LIB="$DIR/lib/ratchet.sh"
if [ ! -f "$RATCHET_LIB" ]; then
  echo "test-pipefail-shortcircuit: no $RATCHET_LIB, so the baseline could not be compared against anything. Refusing rather than passing a check that measured nothing." >&2
  exit 2
fi
# shellcheck source=lib/ratchet.sh
. "$RATCHET_LIB"
ROOT="${SHORTCIRCUIT_ROOT:-$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null || true)}"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

[ -f "$BASELINE" ] || { echo "test-pipefail-shortcircuit: no baseline at $BASELINE, so there is nothing to compare against and nothing was verified." >&2; exit 2; }
# No repository here is not a failure of this suite's subject, it is a place this suite cannot be
# asked (claude-config#155). Said in the one agreed shape the runner reads exactly, so it is
# reported as NOT RUN rather than as broken code, and never as a pass: the runner refuses the same
# claim wherever a repository IS present, so this cannot become a way to opt out of being run.
if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
  echo "test-pipefail-shortcircuit: no repo above $DIR, so there were no files to read." >&2
  printf 'SUITE-NOT-RUN %s\n' "needs the repository to read its tracked files, and there is none above $DIR"
  exit 2
fi

# The pattern, in ONE place, so the baseline records an answer this produced rather than a second
# definition of the question drifting beside it (L107). Comment lines are skipped, or the prose
# explaining the rule counts as breaking it.
#
# A `|` PRECEDED BY ANOTHER `|` is not a pipe (claude-config#282). `[ ... ] || grep -q PAT <<< "$var"`
# is a logical OR: grep is a separate command with its own stdin, nothing is producing into it, and
# no producer can be killed. It was counted anyway, so a correct line was reported as a defect and
# whoever wrote it had to work around a rule it never broke. A guard that fires on lines it was not
# written about is one people learn to route around (L104, L36). The `^` alternative keeps a pipe
# that starts a line, which would otherwise be the case this newly missed.
#
# The quiet flag is matched in ANY cluster spelling (claude-config#153). It read `-[a-zA-Z]*q`,
# which requires the cluster to end in q, so `-q` and `-Eq` counted while `-qi`, `-qE` and `-qF`
# did not: the same hazard with the letters the other way round, permanently exempt from the check
# written to catch it (L217). The cluster must still CONTAIN a q, so a piped `grep -i`, `-c` or
# `-o` reads its producer to the end and is not counted, which the probes below assert both ways.
count_in() { # count_in <file>  -> how many short circuiting pipelines it has
  grep -cE '(^|[^|])\| *(grep +(--quiet|-[a-zA-Z]*q[a-zA-Z]*)|head)( |$)' "$1" 2>/dev/null | tr -d ' ' || echo 0
}
count_uncommented() { # count_uncommented <file>
  local n
  n="$(grep -vE '^[[:space:]]*#' "$1" 2>/dev/null | grep -cE '(^|[^|])\| *(grep +(--quiet|-[a-zA-Z]*q[a-zA-Z]*)|head)( |$)' || true)"
  printf '%s' "${n:-0}"
}

# ---------------------------------------------------------------------------
# The counter has to be able to see one, and to ignore a comment about one, before the real tree is
# asked. A counter that matched nothing would report every file as clean (L1, L98).
# ---------------------------------------------------------------------------
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.shortcircuit.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-pipefail-shortcircuit: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT
# The fixture lines are ASSEMBLED, never written whole. Spelled out, this file would itself contain
# three of the thing it counts, and the ratchet would report its own probe as a defect. It cannot
# tell the line demonstrating the pattern from the line committing it, which is the ratchet working
# correctly (measured: it caught this file the first time it ran). The answer is to leave no
# literal for it to find, the same trick check-style-guide.sh needs for the characters it bans.
_PIPE='|'
{
  printf '#!/usr/bin/env bash\nset -uo pipefail\n'
  printf 'cat file %s grep -q needle\n' "$_PIPE"
  printf 'ls dir %s head -1\n' "$_PIPE"
  printf '# cat other %s grep -q thing   <- a comment about one, not one\n' "$_PIPE"
  printf 'grep -q needle file\n'
} > "$TMPROOT/probe.sh"
[ "$(count_uncommented "$TMPROOT/probe.sh")" = "2" ] \
  && check "the counter sees a piped grep -q and a piped head, and nothing else" ok \
  || check "the counter sees a piped grep -q and a piped head, and nothing else" "it counted $(count_uncommented "$TMPROOT/probe.sh")"

# Every SPELLING of the quiet flag, not only the ones ending in `q` (claude-config#153). The
# pattern read `-[a-zA-Z]*q`, which requires the cluster to END in q, so `-q` and `-Eq` counted and
# `-qi`, `-qE` and `-qF` did not. Those are the identical hazard with the letters the other way
# round, and being exempt from the check written to catch them is L217 exactly. Measured on
# 2026-08-22: widening this found 182 sites the ratchet had never seen, including four in
# check-home-paths.sh and two in claude-sync itself, in a file whose own header said every site
# whose producer is a whole program had been converted.
{
  printf '#!/usr/bin/env bash\nset -uo pipefail\n'
  printf 'cat file %s grep -qi needle\n' "$_PIPE"
  printf 'cat file %s grep -qE needle\n' "$_PIPE"
  printf 'cat file %s grep -qF needle\n' "$_PIPE"
  printf 'cat file %s grep -iq needle\n' "$_PIPE"
  printf '# cat other %s grep -qi thing   <- a comment about one, not one\n' "$_PIPE"
} > "$TMPROOT/probe-flags.sh"
[ "$(count_uncommented "$TMPROOT/probe-flags.sh")" = "4" ] \
  && check "the counter sees the quiet flag however its cluster is spelt" ok \
  || check "the counter sees the quiet flag however its cluster is spelt" "it counted $(count_uncommented "$TMPROOT/probe-flags.sh") of 4"
# And still does NOT count a piped grep that has no quiet flag at all, which reads its producer to
# the end and is the thing this rule permits. Without this, widening the cluster to any letters
# would be satisfied by a pattern that counts every piped grep there is (L104, L178).
{
  printf '#!/usr/bin/env bash\nset -uo pipefail\n'
  printf 'cat file %s grep -i needle\n' "$_PIPE"
  printf 'cat file %s grep -cE needle\n' "$_PIPE"
  printf 'cat file %s grep -oE needle\n' "$_PIPE"
} > "$TMPROOT/probe-loud.sh"
[ "$(count_uncommented "$TMPROOT/probe-loud.sh")" = "0" ] \
  && check "and does not count a piped grep that reads its producer to the end" ok \
  || check "and does not count a piped grep that reads its producer to the end" "it counted $(count_uncommented "$TMPROOT/probe-loud.sh")"

# And does not count a logical OR, which is not a pipe at all (claude-config#282). Both spacings,
# because the counter reads text and a defect that only shows without a space would be exempt from
# the probe written to catch it. The last two lines are REAL pipes sitting beside them, so a
# pattern that fixed the false positive by refusing to count anything would fail here (L159).
{
  printf '#!/usr/bin/env bash\nset -uo pipefail\n'
  printf '[ -n "$x" ] %s%s grep -q needle <<< "$var"\n' "$_PIPE" "$_PIPE"
  printf 'test -f f %s%sgrep -q needle <<< "$var"\n' "$_PIPE" "$_PIPE"
  printf 'cat file %s grep -q needle\n' "$_PIPE"
  printf 'ls dir %s head -1\n' "$_PIPE"
} > "$TMPROOT/probe-or.sh"
[ "$(count_uncommented "$TMPROOT/probe-or.sh")" = "2" ] \
  && check "and does not count a logical OR, only the real pipes beside it" ok \
  || check "and does not count a logical OR, only the real pipes beside it" "it counted $(count_uncommented "$TMPROOT/probe-or.sh") of the 2 real pipes"

# ---------------------------------------------------------------------------
# The hazard itself, on THIS machine, rather than taken from a note (claude-config#162).
# ---------------------------------------------------------------------------
# Everything above is a ratchet on a pattern. What justifies the ratchet is a claim about how the
# platform behaves, and that claim has only ever been recorded in prose here: it was seen biting on
# the Linux runner and could not be reproduced on a Mac. A premise nobody re-takes is a premise
# nobody notices going stale, so it is measured on whatever machine this runs on and the answer is
# printed either way.
#
# It is deliberately NOT a failure. The two outcomes are both facts about the platform rather than
# about this tree, and a red suite on the runner would say nothing anybody could act on (L112). The
# check beside it is the CONTROL: the needle really is in the file and a direct read really does
# find it, so "the pipeline succeeded" means the hazard did not fire here and never means the probe
# read nothing (L98, L159).
#
# The pipeline is assembled rather than written, for the same reason the fixtures above are: spelt
# out, this file would hold one of the things it counts and the ratchet would report its own probe.
_SC_BIG="$TMPROOT/short-circuit-probe.txt"
{ printf 'needle\n'; awk 'BEGIN{for(i=0;i<200000;i++) print "filler line " i}'; } > "$_SC_BIG"
_sc_bytes="$(wc -c < "$_SC_BIG" 2>/dev/null | tr -d ' ')"
case "$_sc_bytes" in ''|*[!0-9]*) _sc_bytes=0 ;; esac
{
  printf '#!/usr/bin/env bash\nset -o pipefail\n'
  printf 'cat "$1" %s grep -q "^needle$"\n' "$_PIPE"
} > "$TMPROOT/probe-hazard.sh"
grep -q '^needle$' "$_SC_BIG"; _sc_direct=$?
bash "$TMPROOT/probe-hazard.sh" "$_SC_BIG" >/dev/null 2>&1; _sc_piped=$?
[ "$_sc_direct" = "0" ] && [ "$_sc_bytes" -gt 65536 ] \
  && check "the hazard probe really has a match to find, past a pipe buffer ($_sc_bytes bytes)" ok \
  || check "the hazard probe really has a match to find, past a pipe buffer ($_sc_bytes bytes)" \
       "direct read said $_sc_direct over $_sc_bytes bytes, so nothing was measured"
if [ "$_sc_piped" = "0" ]; then
  echo "test-pipefail-shortcircuit: on this machine the short circuiting pipeline reported success over ${_sc_bytes} bytes, so the hazard did NOT fire here. The ratchet rests on it firing elsewhere, which is what makes it a platform dependent threshold rather than a bug you can see."
else
  echo "test-pipefail-shortcircuit: on this machine the short circuiting pipeline exited $_sc_piped over ${_sc_bytes} bytes while a direct read of the same file found the match. The hazard is LIVE here: every remaining site in the list below can report a failure that never happened."
fi

# ---------------------------------------------------------------------------
# WHERE it starts, so "the fixture is small" stops being a word (claude-config#168).
# ---------------------------------------------------------------------------
# The tolerance above is that the remaining sites are printf of a small fixture piped into a quiet
# grep. That held on nothing but the word "small", and two of these were correct for months before
# their input grew, so the number nobody had is exactly the number that decides it.
#
# Bracketed rather than bisected to the byte: the answer is not a constant. What decides it is where
# the match falls and how much the writer still has queued when the reader leaves, so a precise
# figure would be a precise fact about this one fixture. A bracket ("clean at this size, fires at
# that one") is what the claim actually needs, and it is honest about being approximate.
#
# The match is on the FIRST line every time, which is the worst case and the one a real site meets
# when its needle is common. A site whose match falls late has more headroom than this reports.
_sc_probe_at(){   # $1 = approximate bytes -> exit 0 when the fault FIRED at that size
  local f="$TMPROOT/sc-at.txt" lines
  lines=$(( $1 / 18 + 1 ))
  { printf 'needle\n'; awk -v n="$lines" 'BEGIN{for(i=0;i<n;i++) print "filler line " i}'; } > "$f"
  bash "$TMPROOT/probe-hazard.sh" "$f" >/dev/null 2>&1 && return 1
  return 0
}
_sc_clean=""      # the largest size that did NOT fire
_sc_fires=""      # the smallest size that DID
for _sc_try in 4096 16384 65536 262144 1048576 4194304; do
  if _sc_probe_at "$_sc_try"; then
    [ -z "$_sc_fires" ] && _sc_fires="$_sc_try"
  else
    _sc_clean="$_sc_try"
  fi
done
# Both sides, or nothing was bracketed. A run that only ever saw one answer has measured that this
# machine is entirely one way, which is a different fact and is reported as one rather than as a
# threshold nobody found (L98, L11).
if [ -n "$_sc_clean" ] && [ -n "$_sc_fires" ]; then
  echo "test-pipefail-shortcircuit: it is clean at ${_sc_clean} bytes and fires at ${_sc_fires}, with the match on the first line. That is the headroom the remaining sites have: a fixture under ${_sc_clean} bytes is safe here today, and one approaching ${_sc_fires} is not."
  check "the hazard was bracketed on this machine (clean ${_sc_clean}, fires ${_sc_fires})" ok
elif [ -n "$_sc_fires" ]; then
  echo "test-pipefail-shortcircuit: it fired at every size tried, from ${_sc_fires} bytes up. There is no safe size here, so the tolerated sites are safe only because their fixtures are smaller than anything measured."
  check "the hazard was bracketed on this machine" "it fired at every size tried, so no clean side was found"
elif [ -n "$_sc_clean" ]; then
  echo "test-pipefail-shortcircuit: it was clean at every size tried, up to ${_sc_clean} bytes. The hazard is not reachable here at these sizes, which is why the ratchet exists on a platform dependent threshold rather than on a bug this machine can show."
  check "the hazard was bracketed on this machine" ok
else
  check "the hazard was bracketed on this machine" "neither side was found, so the sizes probed measured nothing"
fi

# ---------------------------------------------------------------------------
# The real tree, against the recorded counts.
# ---------------------------------------------------------------------------
grew=""
shrank=""
gone=""
measured=""
seen=0
while IFS=' ' read -r rel want; do
  case "$want" in ''|*[!0-9]*) continue ;; esac
  [ -n "$rel" ] || continue
  seen=$((seen + 1))
  f="$ROOT/$rel"
  if [ ! -f "$f" ]; then gone="$gone  $rel
"; continue; fi
  measured="$measured$rel: $(count_uncommented "$f")
"
done <<EOF
$(ratchet_read_baseline "$(cat "$BASELINE")")
EOF

# The comparison itself, from the shared rule, so a change to how a ratchet decides reaches all
# three guards rather than this one (claude-config#377).
while IFS= read -r line; do
  case "$line" in
    "GROWN "*) set -- $line; grew="$grew  $2: $3 recorded, $4 now
" ;;
    "STALE "*) set -- $line; shrank="$shrank  $2: $3 recorded, $4 now
" ;;
  esac
done <<EOF
$(ratchet_verdict "$(cat "$BASELINE")" "$measured")
EOF

[ "$seen" -ge 10 ] \
  && check "the baseline names files to check ($seen of them)" ok \
  || check "the baseline names files to check ($seen of them)" "only $seen, so this proves almost nothing"

# WHICH FILES RUN UNDER PIPEFAIL (claude-config#403). A file used to be judged only if it held the
# word itself, and a SOURCED file never does: it runs with whatever options its caller set. So
# lib/merge-target.sh kept a producer piped into `grep -Eq` for as long as it existed, while
# block-red-merge.sh and require-changelog-tag.sh sourced it under pipefail and misread a merge
# followed by another command on most runs (L183). Two rules, because neither alone is exact:
#
#   every file under a lib/ directory. Deriving these from source lines was tried first and is NOT
#   exact: callers name them through variables (`. "$LIB"`, `. "$SPOOL"`, `. "$RATCHET_LIB"`), and
#   a library runs under whatever its NEXT caller sets, which nothing in the library records. A
#   file lives in lib/ to be sourced, so the directory is the honest statement of that.
#
#   any file a pipefail script names on a `.` or `source` line, resolved against that script's own
#   directory. That is the shape skills/milestone/catch-all.sh has, sourced as "$HERE/catch-all.sh"
#   from outside any lib/, which the directory rule alone would leave exempt (L247).
#
# A variable leading the path is taken to be the script's own directory (`$HERE`, `$HOOK_DIR`,
# `$DIR`), which is the convention every source line here follows; a path that is ONLY a variable
# cannot be resolved from text and is covered by the lib/ rule or not at all.
sourced_under_pipefail() { # sourced_under_pipefail <newline separated repo relative paths>
  local rel f arg tail dir
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    case "$rel" in *.sh|claude-sync) ;; *) continue ;; esac
    f="$ROOT/$rel"
    [ -f "$f" ] || continue
    grep -q 'pipefail' "$f" 2>/dev/null || continue
    while IFS= read -r arg; do
      case "$arg" in
        '$'*/*) tail="${arg#*/}" ;;
        '$'*|/*|'') continue ;;
        *) tail="$arg" ;;
      esac
      dir="${rel%/*}"; [ "$dir" = "$rel" ] && dir=""
      printf '%s\n' "${dir:+$dir/}$tail"
    done < <(sed -nE 's/^[[:space:]]*(\.|source)[[:space:]]+"?([^"[:space:];&|]+)"?.*/\2/p' "$f" 2>/dev/null)
  done <<< "$1"
}
TRACKED="$(git -C "$ROOT" ls-files 2>/dev/null || true)"
SOURCED="$(sourced_under_pipefail "$TRACKED")"
runs_under_pipefail() { # runs_under_pipefail <repo relative path>  -> 0 when that file does
  case "$1" in lib/*|*/lib/*) return 0 ;; esac
  grep -q 'pipefail' "$ROOT/$1" 2>/dev/null && return 0
  case "
$SOURCED
" in *"
$1
"*) return 0 ;; esac
  return 1
}

# A file the baseline does not mention at all, that has one. This is the case that matters: a new
# one arriving in a file nobody was watching (L96).
unlisted=""
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  case "$rel" in *.sh|claude-sync) ;; *) continue ;; esac
  f="$ROOT/$rel"
  [ -f "$f" ] || continue
  runs_under_pipefail "$rel" || continue
  have="$(count_uncommented "$f")"
  [ "${have:-0}" -gt 0 ] || continue
  case "
$(ratchet_read_baseline "$(cat "$BASELINE")")" in *"
$rel "*) ;; *) unlisted="$unlisted  $rel: $have
" ;; esac
done <<EOF
$TRACKED
EOF

# ---------------------------------------------------------------------------
# THE FILE BEING WRITTEN RIGHT NOW (claude-config#376).
#
# Everything above enumerates from `git ls-files`, which lists TRACKED files, so a suite that has
# not been committed yet is invisible to it. Measured 2026-09-11, twice in one session: two new
# suites were written with real sites in them, this ratchet was run before committing and said
# nothing both times, and CI went red on the commit that added each of them. The guard was right
# about the violations and simply could not see them at the moment anybody would have acted on
# them (L376's own case, and the reason L456 exists).
#
# Reported as a NOTICE and deliberately NOT counted in the verdict. Counting them would make this
# suite's pass or fail depend on uncommitted local state, so a draft nobody intends to commit would
# fail it while CI, which sees only what was committed, passed: local and CI would then disagree in
# the other direction, which is the same defect facing the other way (L376). What the notice gives
# is the information at the moment it can be acted on, and it says outright that these WILL count
# once committed, so the silence that produced the incident is gone without the verdict moving.
pending=""
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  case "$rel" in *.sh|claude-sync) ;; *) continue ;; esac
  f="$ROOT/$rel"
  [ -f "$f" ] || continue
  runs_under_pipefail "$rel" || continue
  have="$(count_uncommented "$f")"
  [ "${have:-0}" -gt 0 ] || continue
  pending="$pending  $rel: $have
"
done <<EOF
$(git -C "$ROOT" ls-files --others --exclude-standard 2>/dev/null || true)
EOF
case "$pending" in
  *[![:space:]]*)
    echo "test-pipefail-shortcircuit: NOT YET COUNTED, because these are not committed, and this suite judges what git tracks so that its verdict matches CI's. They WILL be counted the moment they are, and the verdict below does not include them:"
    printf '%s' "$pending"
    echo "  Read the producer into a variable and match with \`case\`, or write it to a file and let grep read that." ;;
esac

case "$grew$unlisted" in
  *[![:space:]]*)
    check "no file has gained a short circuiting pipeline" "these have:
$grew$unlisted  Read the producer into a variable and match with \`case\`, or write it to a file and let grep read that." ;;
  *) check "no file has gained a short circuiting pipeline" ok ;;
esac

case "$shrank$gone" in
  *[![:space:]]*)
    check "the baseline has been lowered as sites were converted" "these are stale:
$shrank$gone  Lower the recorded number, so what is left keeps meaning something." ;;
  *) check "the baseline has been lowered as sites were converted" ok ;;
esac

# ---------------------------------------------------------------------------
# The notice above, driven end to end against a throwaway repository (claude-config#376).
# ---------------------------------------------------------------------------
# A guard seen only against passing input has not been shown to work (L1), and this one has three
# outcomes that have to stay apart: a site in an UNCOMMITTED file is reported and NOT counted, the
# same site once COMMITTED is counted and fails, and a clean untracked file says nothing at all.
# Run as a nested copy of this very file against its own fixture, so what is proved is the code
# that ships rather than a restatement of it (L52).
if [ -z "${SHORTCIRCUIT_NESTED:-}" ] && command -v git >/dev/null 2>&1; then
  sc_probe="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.shortcircuit.XXXXXXXX")" || sc_probe=""
  case "${sc_probe%/}" in
    ''|/|"${HOME%/}") echo "test-pipefail-shortcircuit: refusing to run its own fixture: throwaway directory came back as '$sc_probe'." >&2 ;;
    *)
      git init -q "$sc_probe" 2>/dev/null
      git -C "$sc_probe" config user.email t@e 2>/dev/null
      git -C "$sc_probe" config user.name t 2>/dev/null
      printf '# empty baseline\n' > "$sc_probe/base.txt"
      # Ten listed files, because the baseline's own floor refuses a fixture that proves almost
      # nothing, and that floor is this suite's, not something this fixture may opt out of.
      i=1
      while [ "$i" -le 10 ]; do
        printf 'set -uo pipefail\necho clean\n' > "$sc_probe/listed$i.sh"
        printf 'listed%s.sh: 0\n' "$i" >> "$sc_probe/base.txt"
        i=$((i + 1))
      done
      git -C "$sc_probe" add . >/dev/null 2>&1
      git -C "$sc_probe" -c commit.gpgsign=false commit -q -m seed >/dev/null 2>&1
      sc_run(){ SHORTCIRCUIT_NESTED=1 SHORTCIRCUIT_ROOT="$sc_probe" SHORTCIRCUIT_BASELINE="$sc_probe/base.txt" bash "${BASH_SOURCE[0]}" 2>&1; }

      # A clean untracked file says nothing: a notice on every run is the noise this exists to
      # prevent (L36).
      printf 'set -uo pipefail\necho clean\n' > "$sc_probe/fresh.sh"
      sc_out="$(sc_run)"; sc_rc=$?
      case "$sc_out" in
        *"NOT YET COUNTED"*) check "a clean uncommitted file is not announced" "it was announced" ;;
        *) check "a clean uncommitted file is not announced" ok ;;
      esac

      # A site in an uncommitted file IS announced, and does NOT move the verdict.
      # ASSEMBLED, never written out: spelled literally this line would itself hold the shape this
      # suite counts, and the file would report ITSELF for ever, which is the guard working
      # correctly and is why every other pattern here is assembled too (L245).
      sc_bad='printf %s "$x" | gr'"ep -q needle"
      printf 'set -uo pipefail\n%s\n' "$sc_bad" > "$sc_probe/fresh.sh"
      sc_out="$(sc_run)"; sc_rc=$?
      case "$sc_out" in
        *"NOT YET COUNTED"*fresh.sh*) check "a site in an uncommitted file is announced" ok ;;
        *) check "a site in an uncommitted file is announced" "it was not: $sc_out" ;;
      esac
      [ "$sc_rc" -eq 0 ] \
        && check "and it does not move the verdict, which judges what git tracks" ok \
        || check "and it does not move the verdict, which judges what git tracks" "the run failed ($sc_rc)"

      # THE POSITIVE CONTROL, in the same fixture: the identical file, once committed, IS counted
      # and DOES fail. Without it the two checks above would pass against a scan that found nothing
      # anywhere (L159).
      git -C "$sc_probe" add fresh.sh >/dev/null 2>&1
      git -C "$sc_probe" -c commit.gpgsign=false commit -q -m add >/dev/null 2>&1
      sc_out="$(sc_run)"; sc_rc=$?
      [ "$sc_rc" -ne 0 ] \
        && check "the same file, once committed, is counted and fails" ok \
        || check "the same file, once committed, is counted and fails" "it still passed"
      case "$sc_out" in
        *"NOT YET COUNTED"*) check "and is no longer announced as uncounted" "it is still announced" ;;
        *) check "and is no longer announced as uncounted" ok ;;
      esac

      # A SOURCED file inherits pipefail from its caller (claude-config#403). A file was judged only
      # if it held the word itself, so lib/merge-target.sh kept a producer piped into a quiet grep
      # while every script sourcing it ran under pipefail. Three shapes, each committed, because the
      # verdict judges what git tracks.
      git -C "$sc_probe" rm -q fresh.sh >/dev/null 2>&1
      git -C "$sc_probe" -c commit.gpgsign=false commit -q -m clean >/dev/null 2>&1

      # 1. A library under lib/, with no pipefail of its own and nothing naming it literally.
      mkdir -p "$sc_probe/hooks/lib"
      printf '%s\n' '# a library' "sc_has(){ $sc_bad; }" > "$sc_probe/hooks/lib/helper.sh"
      git -C "$sc_probe" add hooks/lib/helper.sh >/dev/null 2>&1
      git -C "$sc_probe" -c commit.gpgsign=false commit -q -m lib >/dev/null 2>&1
      sc_out="$(sc_run)"; sc_rc=$?
      case "$sc_rc:$sc_out" in
        0:*) check "#403 a site in a lib/ file with no pipefail of its own is counted" "it passed" ;;
        *hooks/lib/helper.sh*) check "#403 a site in a lib/ file with no pipefail of its own is counted" ok ;;
        *) check "#403 a site in a lib/ file with no pipefail of its own is counted" "it failed without naming the file: $sc_out" ;;
      esac
      git -C "$sc_probe" rm -q hooks/lib/helper.sh >/dev/null 2>&1
      git -C "$sc_probe" -c commit.gpgsign=false commit -q -m unlib >/dev/null 2>&1

      # 2. A file OUTSIDE lib/ that a pipefail script sources by name, the shape catch-all.sh has.
      #    The CONTROL comes first, in the same fixture: the identical file with nothing sourcing it
      #    is not counted, so the case after it proves the source line and not a rule that counts
      #    every file (L159).
      printf '%s\n' '# shared' "sc_has(){ $sc_bad; }" > "$sc_probe/util.sh"
      git -C "$sc_probe" add util.sh >/dev/null 2>&1
      git -C "$sc_probe" -c commit.gpgsign=false commit -q -m util >/dev/null 2>&1
      sc_out="$(sc_run)"; sc_rc=$?
      [ "$sc_rc" -eq 0 ] \
        && check "#403 a file nothing sources under pipefail is still not counted" ok \
        || check "#403 a file nothing sources under pipefail is still not counted" "it failed: $sc_out"
      # Assembled, so this file holds no source line of its own for the derivation to read.
      sc_src='sou''rce "$HERE/util.sh"'
      printf '%s\n' 'set -uo pipefail' 'HERE="$(dirname "$0")"' "$sc_src" > "$sc_probe/caller.sh"
      git -C "$sc_probe" add caller.sh >/dev/null 2>&1
      git -C "$sc_probe" -c commit.gpgsign=false commit -q -m caller >/dev/null 2>&1
      sc_out="$(sc_run)"; sc_rc=$?
      case "$sc_rc:$sc_out" in
        0:*) check "#403 the same file, once a pipefail script sources it, is counted" "it passed" ;;
        *util.sh*) check "#403 the same file, once a pipefail script sources it, is counted" ok ;;
        *) check "#403 the same file, once a pipefail script sources it, is counted" "it failed without naming the file: $sc_out" ;;
      esac
      rm -rf "$sc_probe" ;;
  esac
fi

# ---------------------------------------------------------------------------
# And NOTHING outside a test fixture may carry one at all (claude-config#197).
# ---------------------------------------------------------------------------
# The ratchet above only forbids a count from GROWING, so a site in shipped code could sit at one
# for ever and read as a tracked allowance rather than as the defect it is. The distinction that
# makes the remaining sites tolerable is that every one of them feeds a fixture the test itself
# built, which is small by construction. That argument does not cover shipped code, which reads
# real files that grow on their own: the two sites that actually fired both did, and one of them
# was a guard that failed OPEN when the pipeline reported its producer's death instead of a match.
#
# So this is a one way door rather than a number. 492 sites were converted down to 79 on 2026-09-02
# and every one that is left is in a `test-*.sh`. A new one anywhere else fails this suite on the
# day it lands, rather than being added to the list.
_ship_bad=""; _ship_seen=0
while read -r _sc_path _sc_n; do
  case "$_sc_n" in ''|*[!0-9]*) continue ;; esac
  [ -n "$_sc_path" ] || continue
  _ship_seen=$(( _ship_seen + 1 ))
  [ "$_sc_n" -gt 0 ] || continue
  case "${_sc_path##*/}" in test-*) continue ;; esac
  _ship_bad="$_ship_bad
  $_sc_path: $_sc_n"
done < <(ratchet_read_baseline "$(cat "$BASELINE")")
# Reading NOTHING is not a clean answer. The first version of this named the wrong variable, read
# an empty file, and passed while measuring nothing, which is the exact failure this whole suite is
# organised against (L98, and it was caught by reading the code rather than by the check).
if [ "$_ship_seen" -eq 0 ]; then
  check "no site outside a test fixture is left" "the tracked list at $BASELINE gave no rows to read, so nothing was measured."
elif [ -n "$_ship_bad" ]; then
  check "no site outside a test fixture is left" "shipped code still short circuits a pipeline, which reads a real file that grows on its own:$_ship_bad
  Convert it to a here-string (grep -q PAT <<< \"\$var\") or to awk (NR <= n), then lower the count."
else
  check "no site outside a test fixture is left" ok
fi

echo "test-pipefail-shortcircuit: $seen file(s) tracked."
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
