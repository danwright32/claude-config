#!/usr/bin/env bash
# A whole tree scan: a send touching these paths runs this suite (claude-config#809).
# send-gate: scans hooks/ skills/ mods/
# A ratchet on pipelines whose reader can leave before the writer has finished (claude-config#132).
#
# `producer | grep -q needle` under `set -o pipefail` can report a failure that never happened:
# grep -q leaves on its FIRST match, the producer is killed by SIGPIPE, and the pipeline's status
# becomes that death (L183). `head` short circuits the same way, and so do an awk program that
# calls `exit` outside its END blocks and a sed script holding a `q` (claude-config#1042): two of
# those shipped in claude-sync in #1022 and were caught only by a review, because this counted
# neither.
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

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

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
#
# An awk or a sed cannot be judged from its line alone (claude-config#1042). Whether it leaves
# early is decided by its PROGRAM, which routinely runs over many lines, and by where in that
# program the `exit` sits: one inside an END block runs after the input was read to the end and
# kills nothing, while one in a rule or in BEGIN leaves the writer with data still queued. So the
# counter reads each `| awk` and `| sed` the way the shell would, a word at a time with its quotes,
# extending onto the next line while a quote is still open, and judges the program it gets:
#
#   awk counts when the program, with every END block taken out, still calls `exit`;
#   sed counts when its script holds a `q` or `Q` command, after substitutions and /addresses/,
#   which can hold the letter as text, are taken out.
#
# Every reader is found past what the shell runs it THROUGH (claude-config#1104): assignments
# (`| LC_ALL=C awk`), `command`, and `env` with its options and assignments, and a reader named by
# its path is the same reader. It was recognised only straight after the pipe, so the same program
# behind a locale setting went uncounted. The reader's name must end at a space or the line's end,
# so a case pattern such as `grep|head)` is not taken for a pipe into head.
#
# A program read from a file (`-f`, `--file`) cannot be judged from here. It is not counted, and it
# is not passed either: the counter names its line as UNJUDGED, and the tree check further down
# fails on one, because a site nobody has judged is not a site that is known not to short circuit
# (L98). Still one count per LINE, as grep -c gave, so every recorded number keeps its meaning.
_SC_COUNTER="$(cat <<'AWK'
function tok(s,    n, c, pos, len, t, intok, j, closed) {
  split("", T); split("", TEND)
  UNTERM = 0
  n = 0; pos = 1; len = length(s); t = ""; intok = 0
  while (pos <= len && n < 40) {
    c = substr(s, pos, 1)
    if (c == "\\" && pos == len) { UNTERM = 1; break }
    if (c == "\\" && substr(s, pos + 1, 1) == "\n") { if (intok) { T[++n] = t; TEND[n] = pos; t = ""; intok = 0 } pos += 2; continue }
    if (c == " " || c == "\t") { if (intok) { T[++n] = t; TEND[n] = pos; t = ""; intok = 0 } pos++; continue }
    if (c == "\n" || c == ";" || c == "|" || c == "&" || c == ")" || c == "<" || c == ">") break
    intok = 1
    if (c == SQ) {
      j = index(substr(s, pos + 1), SQ)
      if (j == 0) { UNTERM = 1; break }
      t = t substr(s, pos + 1, j - 1); pos += j + 1; continue
    }
    if (c == DQ) {
      pos++; closed = 0
      while (pos <= len) {
        c = substr(s, pos, 1)
        if (c == "\\") { t = t substr(s, pos + 1, 1); pos += 2; continue }
        if (c == DQ) { pos++; closed = 1; break }
        t = t c; pos++
      }
      if (!closed) { UNTERM = 1; break }
      continue
    }
    if (c == "\\") { t = t substr(s, pos + 1, 1); pos += 2; continue }
    t = t c; pos++
  }
  if (intok) { T[++n] = t; TEND[n] = pos }
  return n
}
# The word that names the reader, past assignments and the command and env wrappers, or 0 when
# there is none. A command -v or -V only describes a command, so it names no reader.
function reader_at(n,    i) {
  i = 1
  while (i <= n) {
    if (T[i] ~ /^[A-Za-z_][A-Za-z_0-9]*=/) { i++; continue }
    if (T[i] == "command") {
      i++
      while (i <= n && T[i] ~ /^-[a-zA-Z]+$/) { if (T[i] ~ /[vV]/) return 0; i++ }
      continue
    }
    if (T[i] == "env") {
      i++
      while (i <= n) {
        if (T[i] == "-u" || T[i] == "--unset") { i += 2; continue }
        if (T[i] == "--") { i++; break }
        if (T[i] ~ /^-/ || T[i] ~ /^[A-Za-z_][A-Za-z_0-9]*=/) { i++; continue }
        break
      }
      continue
    }
    return i
  }
  return 0
}
function strip_end(p,    s, k, depth, ch, rest) {
  while (match(p, /(^|[^A-Za-z_0-9])END[[:space:]]*\{/)) {
    s = RSTART + RLENGTH - 1
    depth = 0
    for (k = s; k <= length(p); k++) {
      ch = substr(p, k, 1)
      if (ch == "{") depth++
      else if (ch == "}") { depth--; if (depth == 0) break }
    }
    rest = (k < length(p)) ? substr(p, k + 1) : ""
    p = substr(p, 1, RSTART) rest
  }
  return p
}
# Each judge starts at the word after the name of the reader, r; a program read from a file sets UNJ.
function awk_leaves(r, n,    i, prog) {
  i = r + 1
  while (i <= n && substr(T[i], 1, 1) == "-") {
    if (T[i] == "--") { i++; break }
    if (T[i] == "-f" || T[i] ~ /^--file/) { UNJ = 1; return 0 }
    if (T[i] == "-v" || T[i] == "-F") i += 2; else i++
  }
  if (i > n) return 0
  prog = strip_end(T[i])
  return prog ~ /(^|[^A-Za-z_0-9])exit([^A-Za-z_0-9]|$)/
}
function sed_leaves(r, n,    i, sc) {
  i = r + 1; sc = ""
  while (i <= n && substr(T[i], 1, 1) == "-") {
    if (T[i] == "-f" || T[i] ~ /^--file/) { UNJ = 1; return 0 }
    if (T[i] ~ /^-[a-zA-Z]*e$/ || T[i] == "--expression") { sc = sc ";" T[i + 1]; i += 2; continue }
    i++
  }
  if (sc == "" && i <= n) sc = T[i]
  gsub(/s\/([^\/\\]|\\.)*\/([^\/\\]|\\.)*\/[a-zA-Z0-9]*/, "", sc)
  gsub(/s#([^#\\]|\\.)*#([^#\\]|\\.)*#[a-zA-Z0-9]*/, "", sc)
  gsub(/s\|([^|\\]|\\.)*\|([^|\\]|\\.)*\|[a-zA-Z0-9]*/, "", sc)
  gsub(/s,([^,\\]|\\.)*,([^,\\]|\\.)*,[a-zA-Z0-9]*/, "", sc)
  gsub(/\/([^\/\\]|\\.)*\//, "//", sc)
  return sc ~ /(^|[;{}[:space:]0-9$\/!])[qQ]([;}[:space:]0-9]|$)/
}
{ L[NR] = $0 }
END {
  total = 0; unjudged = ""
  for (i = 1; i <= NR; i++) {
    line = L[i]
    if (line ~ /^[[:space:]]*#/) continue
    rest = line; hit = 0; UNJ = 0
    while (!hit && match(rest, /(^|[^|])\|/)) {
      # Kept before anything else can call match(), which resets RSTART for the whole program.
      after = RSTART + RLENGTH
      s = substr(rest, after)
      rest = s
      # A second bar makes a logical OR (claude-config#282), and a bar then an ampersand pipes both streams.
      if (substr(s, 1, 1) == "|") { rest = substr(s, 2); continue }
      if (substr(s, 1, 1) == "&") s = substr(s, 2)
      text = s; k = i
      n = tok(text)
      r = reader_at(n)
      if (!r) continue
      c = substr(text, TEND[r], 1)
      if (c != "" && c != " " && c != "\t" && c != "\n" && c != "\\") continue
      name = T[r]; sub(/.*\//, "", name)
      if (name == "head") { hit = 1; continue }
      if (name == "grep") { if (T[r + 1] ~ /^(--quiet|-[a-zA-Z]*q[a-zA-Z]*)$/) hit = 1; continue }
      if (name != "awk" && name != "sed") continue
      while (UNTERM && k < NR && k < i + 300) { text = text "\n" L[++k]; n = tok(text) }
      if (name == "awk" && awk_leaves(r, n)) hit = 1
      else if (name == "sed" && sed_leaves(r, n)) hit = 1
    }
    if (hit) total++
    if (UNJ) unjudged = unjudged " " i
  }
  print total
  if (unjudged != "") print "unjudged" unjudged
}
AWK
)"
# One pass over a file answers both questions: the count on the first line, then, when there are
# any, `unjudged` and the line numbers of the piped programs read from a file.
sc_scan() { # sc_scan <file>
  awk -v SQ="'" -v DQ='"' "$_SC_COUNTER" "$1" 2>/dev/null
}
_SC_NL='
'
count_uncommented() { # count_uncommented <file>  -> how many lines hold a short circuiting pipeline
  local out n
  out="$(sc_scan "$1")"
  n="${out%%"$_SC_NL"*}"
  printf '%s' "${n:-0}"
}
unjudged_lines() { # unjudged_lines <file>  -> the line numbers that pipe into a file program, or nothing
  local out rest
  out="$(sc_scan "$1")"
  rest="${out#*"$_SC_NL"unjudged }"
  [ "$rest" = "$out" ] || printf '%s' "$rest"
  return 0
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

# An awk that leaves with `exit` and a sed that quits with `q` are the same hazard as grep -q
# (claude-config#1042). Each counted shape sits beside the nearest shape that must NOT count, so a
# counter that fixed the miss by counting every piped awk or sed fails here as surely as one that
# still counts none (L159): an exit inside END runs after the input was read to the end, a `q`
# inside a substitution is text, a program read from a file cannot be judged, and a comment or a
# logical OR is not a pipe.
{
  printf '#!/usr/bin/env bash\nset -uo pipefail\n'
  printf '%s\n' "cat file $_PIPE awk 'NR == 1 { print; exit }'"
  printf '%s\n' "cat file $_PIPE awk -F'\\t' -v k=\"\$v\" '\$1 == k { print \$2; exit }'"
  printf '%s\n' "cat file $_PIPE awk '" '  { n++ }' '  /needle/ { found = 1; exit }' "'"
  printf '%s\n' "cat file $_PIPE sed -n '1p;q'"
  printf '%s\n' "cat file $_PIPE sed 5q"
  printf '%s\n' "cat file $_PIPE awk '{ n++ } END { exit n ? 0 : 1 }'"
  printf '%s\n' "cat file $_PIPE awk '" '  { n++ }' '  END { if (n) exit 0; exit 1 }' "'"
  printf '%s\n' "cat file $_PIPE sed 's/q /x/'"
  printf '%s\n' "cat file $_PIPE sed -n '/q/p'"
  printf '%s\n' "cat file $_PIPE awk -f prog.awk"
  printf '%s\n' "# cat file $_PIPE awk '{ exit }'   <- a comment about one, not one"
  printf '%s\n' "[ -n \"\$x\" ] $_PIPE$_PIPE awk '{ exit }' file"
} > "$TMPROOT/probe-awk-sed.sh"
[ "$(count_uncommented "$TMPROOT/probe-awk-sed.sh")" = "5" ] \
  && check "#1042 the counter sees an awk that exits and a sed that quits, multi line bodies too, and not their harmless neighbours" ok \
  || check "#1042 the counter sees an awk that exits and a sed that quits, multi line bodies too, and not their harmless neighbours" "it counted $(count_uncommented "$TMPROOT/probe-awk-sed.sh") of 5"

# THE SAME READERS BEHIND A WRAPPER (claude-config#1104). The reader was recognised only when its
# name came straight after the pipe, so `| LC_ALL=C awk`, `| command sed` and `| env awk` that leave
# early were never counted, though the shell runs the very same program. Assignments, `command`
# and `env` (with its options and assignments) are read past, and a reader named by its path is
# the same reader. The last four lines must NOT count: an exit inside END, a `q` that is text, a
# wrapped reader that reads to the end, and a case pattern, which holds a `|` and is no pipe.
{
  printf '#!/usr/bin/env bash\nset -uo pipefail\n'
  printf '%s\n' "cat file $_PIPE LC_ALL=C awk 'NR == 1 { print; exit }'"
  printf '%s\n' "cat file $_PIPE command sed 5q"
  printf '%s\n' "cat file $_PIPE env LC_ALL=C awk '{ exit }'"
  printf '%s\n' "cat file $_PIPE env -i PATH=/bin grep -q needle"
  printf '%s\n' "cat file $_PIPE LANG=C command head -1"
  printf '%s\n' "cat file $_PIPE A=1 B=\"x y\" /usr/bin/awk '/n/ { exit }'"
  printf '%s\n' "cat file $_PIPE env -u TZ sed -n '1p;q'"
  printf '%s\n' "cat file $_PIPE LC_ALL=C awk '{ n++ } END { exit n ? 0 : 1 }'"
  printf '%s\n' "cat file $_PIPE command sed 's/q /x/'"
  printf '%s\n' "cat file $_PIPE env LC_ALL=C sort"
  printf '%s\n' "case \"\$x\" in grep${_PIPE}head) ;; esac"
} > "$TMPROOT/probe-wrapped.sh"
[ "$(count_uncommented "$TMPROOT/probe-wrapped.sh")" = "7" ] \
  && check "#1104 the counter reads past assignments, command and env to the reader, and not into a case pattern" ok \
  || check "#1104 the counter reads past assignments, command and env to the reader, and not into a case pattern" "it counted $(count_uncommented "$TMPROOT/probe-wrapped.sh") of 7"

# A PROGRAM READ FROM A FILE IS UNJUDGED, NOT CLEAN (claude-config#1104). Whether `awk -f prog` or
# `sed -f script` leaves early is decided by a file this counter does not read, so it was simply not
# counted, which reported a site nobody had judged as one that does not short circuit (L98). It is
# now named as unjudged, by line, wrapped or not and however the option is spelt; an inline program,
# a file program that is not piped into, and a comment are not.
{
  printf '#!/usr/bin/env bash\nset -uo pipefail\n'
  printf '%s\n' "cat file $_PIPE awk -f prog.awk"
  printf '%s\n' "cat file $_PIPE LC_ALL=C sed -f script.sed"
  printf '%s\n' "cat file $_PIPE env awk --file=prog.awk"
  printf '%s\n' "cat file $_PIPE awk -v k=1 -f prog.awk"
  printf '%s\n' "cat file $_PIPE awk '{ print }'"
  printf '%s\n' "awk -f prog.awk file"
  printf '%s\n' "# cat file $_PIPE awk -f prog.awk"
} > "$TMPROOT/probe-unjudged.sh"
[ "$(unjudged_lines "$TMPROOT/probe-unjudged.sh")" = "3 4 5 6" ] \
  && check "#1104 a piped awk or sed whose program is a file is named as unjudged, by line" ok \
  || check "#1104 a piped awk or sed whose program is a file is named as unjudged, by line" "it named lines '$(unjudged_lines "$TMPROOT/probe-unjudged.sh")', not 3 4 5 6"
[ "$(count_uncommented "$TMPROOT/probe-unjudged.sh")" = "0" ] \
  && check "#1104 and an unjudged site is not counted as one that short circuits" ok \
  || check "#1104 and an unjudged site is not counted as one that short circuits" "it counted $(count_uncommented "$TMPROOT/probe-unjudged.sh")"

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
# Everything this ratchet reads, committed or not, through the one lister every scanner here uses
# (claude-config#522). An uncommitted file is the one most likely to be wrong, and a ratchet that
# can only see it once it is committed speaks after the moment anybody would act (L456).
FILES="$(bash "$DIR/lib/repo-files.sh" "$ROOT" 2>/dev/null || true)"
UNCOMMITTED="$(bash "$DIR/lib/repo-files.sh" --uncommitted "$ROOT" 2>/dev/null || true)"
# A listing that came back empty read nothing, and every check below would pass over it (L98).
[ -n "$FILES" ] \
  && check "the files to judge were listed" ok \
  || check "the files to judge were listed" "lib/repo-files.sh gave nothing for $ROOT, so nothing below was read"
SOURCED="$(sourced_under_pipefail "$FILES")"
uncommitted_mark(){ # uncommitted_mark <repo relative path> -> " (not committed yet)" or nothing
  case "
$UNCOMMITTED
" in *"
$1
"*) printf ' (not committed yet)' ;; esac
  return 0
}
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
# The same one pass also names every pipe into an awk or sed program read from a file, which the
# counter cannot judge (claude-config#1104).
unlisted=""
unjudged=""
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  case "$rel" in *.sh|claude-sync) ;; *) continue ;; esac
  f="$ROOT/$rel"
  [ -f "$f" ] || continue
  runs_under_pipefail "$rel" || continue
  scanned="$(sc_scan "$f")"
  have="${scanned%%"$_SC_NL"*}"
  unj="${scanned#*"$_SC_NL"unjudged }"
  if [ "$unj" != "$scanned" ]; then
    for ln in $unj; do unjudged="$unjudged  $rel: line $ln$(uncommitted_mark "$rel")
"; done
  fi
  [ "${have:-0}" -gt 0 ] || continue
  case "
$(ratchet_read_baseline "$(cat "$BASELINE")")" in *"
$rel "*) ;; *) unlisted="$unlisted  $rel: $have$(uncommitted_mark "$rel")
" ;; esac
done <<EOF
$FILES
EOF

# ---------------------------------------------------------------------------
# THE FILE BEING WRITTEN RIGHT NOW (claude-config#376, claude-config#522).
#
# This used to report an uncommitted file's sites as a NOTICE and leave them out of the verdict, so
# that a local run could never fail where CI, which sees only commits, passed. #522 reversed that,
# and the reason is which way each choice lets local and CI disagree. Left out of the verdict, the
# local run is LAXER than CI: the ratchet passed while scanners-before-push.sh was untracked and
# failed the moment it was committed, which is the silence #376 was opened about with a notice in
# place of the silence. Counted, the local run is STRICTER than CI, and the only cost is a draft
# nobody meant to commit failing by name, marked above as not committed yet, where it can be seen.
# ---------------------------------------------------------------------------

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

# A one way door rather than a count, as for shipped code below: there were none once the one in
# the sync suite was converted, and a program in a file is judged by nobody, so a new one is named
# on the day it lands (claude-config#1104).
case "$unjudged" in
  *[![:space:]]*)
    check "no pipe runs into an awk or sed program read from a file, which cannot be judged here" "these do:
$unjudged  Give the program the input as a file or a here-string (awk -f prog <<< \"\$text\") rather than a pipe, or put the program inline so it can be read." ;;
  *) check "no pipe runs into an awk or sed program read from a file, which cannot be judged here" ok ;;
esac

# ---------------------------------------------------------------------------
# Uncommitted files, driven end to end against a throwaway repository (claude-config#376, #522).
# ---------------------------------------------------------------------------
# A guard seen only against passing input has not been shown to work (L1), and three outcomes have
# to stay apart: a clean untracked file passes, a site in an UNCOMMITTED file is counted, fails and
# is named as not committed yet, and the same site once COMMITTED still fails. Run as a nested
# copy of this very file against its own fixture, so what is proved is the code that ships rather
# than a restatement of it (L52).
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

      # A clean untracked file passes: reading it must not be mistaken for finding something.
      printf 'set -uo pipefail\necho clean\n' > "$sc_probe/fresh.sh"
      sc_out="$(sc_run)"; sc_rc=$?
      [ "$sc_rc" -eq 0 ] \
        && check "a clean uncommitted file passes" ok \
        || check "a clean uncommitted file passes" "the run failed ($sc_rc): $sc_out"

      # A site in an uncommitted file is COUNTED and fails, named as not committed yet so a draft
      # can be told from committed work at a glance.
      # ASSEMBLED, never written out: spelled literally this line would itself hold the shape this
      # suite counts, and the file would report ITSELF for ever, which is the guard working
      # correctly and is why every other pattern here is assembled too (L245).
      sc_bad='printf %s "$x" | gr'"ep -q needle"
      printf 'set -uo pipefail\n%s\n' "$sc_bad" > "$sc_probe/fresh.sh"
      sc_out="$(sc_run)"; sc_rc=$?
      [ "$sc_rc" -ne 0 ] \
        && check "a site in an uncommitted file is counted and fails" ok \
        || check "a site in an uncommitted file is counted and fails" "it passed: $sc_out"
      case "$sc_out" in
        *"fresh.sh: 1 (not committed yet)"*) check "and names the file as not committed yet" ok ;;
        *) check "and names the file as not committed yet" "it did not: $sc_out" ;;
      esac

      # THE SAME FILE, COMMITTED, still fails and is no longer called uncommitted, so the label
      # describes the file rather than being printed on every row (L159).
      git -C "$sc_probe" add fresh.sh >/dev/null 2>&1
      git -C "$sc_probe" -c commit.gpgsign=false commit -q -m add >/dev/null 2>&1
      sc_out="$(sc_run)"; sc_rc=$?
      [ "$sc_rc" -ne 0 ] \
        && check "the same file, once committed, is counted and fails" ok \
        || check "the same file, once committed, is counted and fails" "it still passed"
      case "$sc_out" in
        *"not committed yet"*) check "and is no longer called uncommitted" "it still is: $sc_out" ;;
        *) check "and is no longer called uncommitted" ok ;;
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
      git -C "$sc_probe" rm -q util.sh caller.sh >/dev/null 2>&1
      git -C "$sc_probe" -c commit.gpgsign=false commit -q -m unshared >/dev/null 2>&1

      # 3. A piped awk whose program is a FILE fails the tree check by file and line, with no count
      #    to its name, rather than passing as a site that does not short circuit (claude-config#1104).
      #    Assembled for the same reason as the rest, so this file holds no such pipe of its own.
      sc_unj="cat f $_PIPE awk -f prog.awk"
      printf '%s\n' 'set -uo pipefail' "$sc_unj" > "$sc_probe/unj.sh"
      git -C "$sc_probe" add unj.sh >/dev/null 2>&1
      git -C "$sc_probe" -c commit.gpgsign=false commit -q -m unj >/dev/null 2>&1
      sc_out="$(sc_run)"; sc_rc=$?
      case "$sc_rc:$sc_out" in
        0:*) check "#1104 a pipe into an awk program read from a file fails the tree check" "it passed" ;;
        *"unj.sh: line 2"*) check "#1104 a pipe into an awk program read from a file fails the tree check" ok ;;
        *) check "#1104 a pipe into an awk program read from a file fails the tree check" "it failed without naming unj.sh line 2: $sc_out" ;;
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
