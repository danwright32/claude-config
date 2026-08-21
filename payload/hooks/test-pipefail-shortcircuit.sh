#!/usr/bin/env bash
# A ratchet on pipelines whose reader can leave before the writer has finished (claude-config#132).
#
# `producer | grep -q needle` under `set -o pipefail` can report a failure that never happened:
# grep -q leaves on its FIRST match, the producer is killed by SIGPIPE, and the pipeline's status
# becomes that death (L183). `head` short circuits the same way.
#
# It bites only when the reader leaves while the writer still has data, so whether it fires depends
# on how big the text is and where in it the match falls. That makes it a SIZE THRESHOLD nobody is
# watching, and two of these were correct for months before their input grew:
#
#   the sync suite's #41 citation check started failing on the Linux runner the week the file it
#   reads gained one line per suite, and reported a citation it HAD found as missing;
#
#   the lessons advisory went silent on any push adding more than a pipe buffer of lines, which is
#   precisely when it has the most to say. That one is measured, not theorised: its suite has a
#   fixture that makes it happen.
#
# Every site whose producer is a whole PROGRAM has been converted. What is left is overwhelmingly
# `printf '%s' "$var" | grep -q` inside tests, where the text is a fixture the test itself built.
# The count is written down so it can only go down.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASELINE="${SHORTCIRCUIT_BASELINE:-$DIR/shortcircuit-pipes.txt}"
ROOT="${SHORTCIRCUIT_ROOT:-$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null || true)}"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

[ -f "$BASELINE" ] || { echo "test-pipefail-shortcircuit: no baseline at $BASELINE, so there is nothing to compare against and nothing was verified." >&2; exit 2; }
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "test-pipefail-shortcircuit: no repo above $DIR, so there were no files to read." >&2; exit 2; }

# The pattern, in ONE place, so the baseline records an answer this produced rather than a second
# definition of the question drifting beside it (L107). Comment lines are skipped, or the prose
# explaining the rule counts as breaking it.
count_in() { # count_in <file>  -> how many short circuiting pipelines it has
  grep -cE '\| *(grep +-[a-zA-Z]*q|head)( |$)' "$1" 2>/dev/null | tr -d ' ' || echo 0
}
count_uncommented() { # count_uncommented <file>
  local n
  n="$(grep -vE '^[[:space:]]*#' "$1" 2>/dev/null | grep -cE '\| *(grep +-[a-zA-Z]*q|head)( |$)' || true)"
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
{
  printf '#!/usr/bin/env bash\nset -uo pipefail\n'
  printf 'cat file | grep -q needle\n'
  printf 'ls dir | head -1\n'
  printf '# cat other | grep -q thing   <- a comment about one, not one\n'
  printf 'grep -q needle file\n'
} > "$TMPROOT/probe.sh"
[ "$(count_uncommented "$TMPROOT/probe.sh")" = "2" ] \
  && check "the counter sees a piped grep -q and a piped head, and nothing else" ok \
  || check "the counter sees a piped grep -q and a piped head, and nothing else" "it counted $(count_uncommented "$TMPROOT/probe.sh")"

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
