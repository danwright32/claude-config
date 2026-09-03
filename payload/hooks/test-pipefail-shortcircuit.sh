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
# The quiet flag is matched in ANY cluster spelling (claude-config#153). It read `-[a-zA-Z]*q`,
# which requires the cluster to end in q, so `-q` and `-Eq` counted while `-qi`, `-qE` and `-qF`
# did not: the same hazard with the letters the other way round, permanently exempt from the check
# written to catch it (L217). The cluster must still CONTAIN a q, so a piped `grep -i`, `-c` or
# `-o` reads its producer to the end and is not counted, which the probes below assert both ways.
count_in() { # count_in <file>  -> how many short circuiting pipelines it has
  grep -cE '\| *(grep +(--quiet|-[a-zA-Z]*q[a-zA-Z]*)|head)( |$)' "$1" 2>/dev/null | tr -d ' ' || echo 0
}
count_uncommented() { # count_uncommented <file>
  local n
  n="$(grep -vE '^[[:space:]]*#' "$1" 2>/dev/null | grep -cE '\| *(grep +(--quiet|-[a-zA-Z]*q[a-zA-Z]*)|head)( |$)' || true)"
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
seen=0
while IFS=' ' read -r want rel; do
  case "$want" in ''|*[!0-9]*) continue ;; esac
  [ -n "$rel" ] || continue
  seen=$((seen + 1))
  f="$ROOT/$rel"
  if [ ! -f "$f" ]; then gone="$gone  $rel
"; continue; fi
  have="$(count_uncommented "$f")"
  if [ "$have" -gt "$want" ]; then grew="$grew  $rel: $want recorded, $have now
"; fi
  if [ "$have" -lt "$want" ]; then shrank="$shrank  $rel: $want recorded, $have now
"; fi
done <<EOF
$(grep -vE '^[[:space:]]*(#|$)' "$BASELINE")
EOF

[ "$seen" -ge 10 ] \
  && check "the baseline names files to check ($seen of them)" ok \
  || check "the baseline names files to check ($seen of them)" "only $seen, so this proves almost nothing"

# A file the baseline does not mention at all, that has one. This is the case that matters: a new
# one arriving in a file nobody was watching (L96).
unlisted=""
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  case "$rel" in *.sh|claude-sync) ;; *) continue ;; esac
  f="$ROOT/$rel"
  [ -f "$f" ] || continue
  grep -q 'pipefail' "$f" 2>/dev/null || continue
  have="$(count_uncommented "$f")"
  [ "${have:-0}" -gt 0 ] || continue
  grep -qE "^[0-9]+ $rel\$" "$BASELINE" || unlisted="$unlisted  $rel: $have
"
done <<EOF
$(git -C "$ROOT" ls-files 2>/dev/null || true)
EOF

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

echo "test-pipefail-shortcircuit: $seen file(s) tracked."
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
