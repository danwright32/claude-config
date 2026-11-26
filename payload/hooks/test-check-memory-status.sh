#!/usr/bin/env bash
# Tests for check-memory-status.sh, which reads a memory folder for lines pairing a pull request or
# issue with a status word, asks GitHub for the real state, and prints the lines that disagree
# (claude-config#3552).
#
# Measured on 2026-11-24 on the work MacBook: one line of a memory index said a pull request was
# open and waiting on someone, and GitHub had reported it merged for 11 weeks. Every session on
# that Mac read the false status first thing.
#
# Four outcomes, and the point of the check is that they never read alike (L11, L98): a line that
# AGREES prints nothing; one that DISAGREES is printed; one that COULD NOT BE CHECKED (gh missing,
# not signed in, no network, a repository this account cannot see, a rate limit, a timeout) is
# printed as exactly that and never counted as agreeing; and one naming a number with NO
# REPOSITORY is skipped and said to be, never guessed. Each has its own exit code.
#
# gh is never the real one here: a stand in sits first on this suite's PATH, answers from a table
# the test writes, and logs every call, so the suite needs no network and can count calls (one per
# distinct reference, never one per line). Every repository name below is invented.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$DIR/check-memory-status.sh"

pass=0
fail=0
check() { # check <description> <result>   ("ok" passes, anything else is the failure text)
  if [[ "$2" == "ok" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $1 ($2)"
  fi
}
has() { # has <text> <needle>  -> ok, or what was missing
  case "$1" in *"$2"*) echo ok ;; *) echo "missing '$2' in: $1" ;; esac
}
lacks() { # lacks <text> <needle>
  case "$1" in *"$2"*) echo "unexpected '$2' in: $1" ;; *) echo ok ;; esac
}

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.memstatus.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-check-memory-status: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

# ---------------------------------------------------------------------------
# The stand in for gh. It answers `gh api repos/<owner>/<repo>/issues/<n> --jq ...` from a table of
# "<api path>|<exit code>|<what it prints>" lines, logs the api path of every call, and can be made
# to hang so the time limits are exercised. A path missing from the table answers as GitHub does for
# a repository this account cannot see.
# ---------------------------------------------------------------------------
mkdir -p "$TMPROOT/bin"
cat > "$TMPROOT/bin/gh" <<'STUB'
#!/usr/bin/env bash
path="${2:-}"
printf '%s\n' "$path" >> "$GH_FAKE_LOG"
if [ -n "${GH_FAKE_SLEEP:-}" ]; then sleep "$GH_FAKE_SLEEP"; fi
while IFS='|' read -r p rc out; do
  if [ "$p" = "$path" ]; then
    printf '%s\n' "$out"
    exit "$rc"
  fi
done < "$GH_FAKE_TABLE"
echo "gh: Not Found (HTTP 404)" >&2
exit 1
STUB
chmod +x "$TMPROOT/bin/gh"

n=0
run() { # run <folder> <table body> [VAR=value ...]  -> sets OUT, RC, CALLS (the logged api paths)
  local folder="$1" table="$2"; shift 2
  n=$((n + 1))
  printf '%s\n' "$table" > "$TMPROOT/table.$n"
  : > "$TMPROOT/log.$n"
  OUT="$(env PATH="$TMPROOT/bin:$PATH" GH_FAKE_TABLE="$TMPROOT/table.$n" GH_FAKE_LOG="$TMPROOT/log.$n" "$@" bash "$CHECK" "$folder" 2>&1)"
  RC=$?
  CALLS="$(cat "$TMPROOT/log.$n")"
}
mem() { # mem <folder name> <MEMORY.md body> [<entry file name> <body>]...  -> prints the folder
  local d="$TMPROOT/$1"; shift
  mkdir -p "$d"
  printf '%s\n' "$1" > "$d/MEMORY.md"; shift
  while [ "$#" -ge 2 ]; do printf '%s\n' "$2" > "$d/$1"; shift 2; done
  printf '%s' "$d"
}
calls_to() { # calls_to <api path>  -> how many times the last run asked for it
  local c=0 l
  while IFS= read -r l; do [ "$l" = "$1" ] && c=$((c + 1)); done <<EOF
$CALLS
EOF
  echo "$c"
}

OPEN_PR='pull-request open none'
MERGED_PR='pull-request closed 2026-09-07T12:00:00Z'
CLOSED_PR='pull-request closed none'
OPEN_ISSUE='issue open none'
CLOSED_ISSUE='issue closed none'

# ---------------------------------------------------------------------------
# AGREES: a line whose status matches GitHub prints nothing for that line, and the run is clean.
# ---------------------------------------------------------------------------
d="$(mem agrees "# Memory
- [Thing](thing.md): fixture-org/alpha#10 is still open, see it")"
run "$d" "repos/fixture-org/alpha/issues/10|0|$OPEN_PR"
check "a line that agrees with GitHub exits 0" "$([ "$RC" -eq 0 ] && echo ok || echo "rc $RC: $OUT")"
check "and prints nothing for that line" "$(lacks "$OUT" "line 2")"
check "and the summary counts it as agreeing" "$(has "$OUT" "1 agree")"
check "and GitHub was asked once" "$([ "$(calls_to repos/fixture-org/alpha/issues/10)" -eq 1 ] && echo ok || echo "calls: $CALLS")"

# ---------------------------------------------------------------------------
# DISAGREES: the false line from the measurement, a merged pull request said to be open. The output
# names the file, the line number and GitHub's state.
# ---------------------------------------------------------------------------
d="$(mem disagrees "# Memory
- intro line
- [Work PR](work-pr.md): fixture-org/beta#11 open, awaiting review")"
run "$d" "repos/fixture-org/beta/issues/11|0|$MERGED_PR"
check "a line GitHub contradicts exits 1" "$([ "$RC" -eq 1 ] && echo ok || echo "rc $RC: $OUT")"
check "and names the memory file" "$(has "$OUT" "MEMORY.md")"
check "and the line number" "$(has "$OUT" "line 3")"
check "and the reference" "$(has "$OUT" "fixture-org/beta#11")"
check "and the state GitHub reports" "$(has "$OUT" "merged")"
check "and never the line's own text, since memory is private and only the number is needed" "$(lacks "$OUT" "Work PR")"

# "not merged" agrees with an open or closed pull request and disagrees with a merged one. Case is
# ignored, because the measured line wrote "NOT merged".
d="$(mem notmerged "- fixture-org/beta#12 open against main, NOT merged
- fixture-org/beta#13 NOT merged")"
run "$d" "repos/fixture-org/beta/issues/12|0|$OPEN_PR
repos/fixture-org/beta/issues/13|0|$MERGED_PR"
check "'not merged' on a merged pull request is reported, whatever its case" "$(has "$OUT" "line 2")"
check "and 'open, not merged' on an open one is not" "$(lacks "$OUT" "line 1:")"
check "and the run exits 1" "$([ "$RC" -eq 1 ] && echo ok || echo "rc $RC: $OUT")"

# An issue: "pending" on a closed issue disagrees, and says closed rather than merged.
d="$(mem issue "- fixture-org/gamma#7 pending")"
run "$d" "repos/fixture-org/gamma/issues/7|0|$CLOSED_ISSUE"
check "a status word on a closed issue is reported as closed" "$(has "$OUT" "closed")"
check "and an issue is never called merged" "$(lacks "$OUT" "merged")"
check "and exits 1" "$([ "$RC" -eq 1 ] && echo ok || echo "rc $RC: $OUT")"

# A closed, unmerged pull request said to be awaiting something is stale too.
d="$(mem closedpr "- fixture-org/gamma#8 awaiting a reviewer")"
run "$d" "repos/fixture-org/gamma/issues/8|0|$CLOSED_PR"
check "'awaiting' on a pull request closed without merging is reported" "$([ "$RC" -eq 1 ] && echo ok || echo "rc $RC: $OUT")"

# A full GitHub link names its repository as well as owner/repo#N does.
d="$(mem url "- see https://github.com/fixture-org/delta/pull/21 still open")"
run "$d" "repos/fixture-org/delta/issues/21|0|$MERGED_PR"
check "a pull request link is read as its repository and number" "$(has "$OUT" "fixture-org/delta#21")"
check "and a stale one is reported" "$([ "$RC" -eq 1 ] && echo ok || echo "rc $RC: $OUT")"
d="$(mem urlissue "- https://github.com/fixture-org/delta/issues/22 pending")"
run "$d" "repos/fixture-org/delta/issues/22|0|$OPEN_ISSUE"
check "an issue link that agrees is clean" "$([ "$RC" -eq 0 ] && echo ok || echo "rc $RC: $OUT")"

# ---------------------------------------------------------------------------
# NOT A PAIR: a number with no status word, a status word with no number, and a word that only
# CONTAINS a status word. None is reported, and none costs a call.
# ---------------------------------------------------------------------------
d="$(mem notpairs "- fixture-org/eps#30 merged last week, see it
- the vendor check is still pending
- awaiting nothing in particular
- fixture-org/eps#31 was opened and then reopened")"
run "$d" "repos/fixture-org/eps/issues/30|0|$OPEN_PR
repos/fixture-org/eps/issues/31|0|$MERGED_PR"
check "a number with no status word, or a status word with no number, is not reported" "$([ "$RC" -eq 0 ] && echo ok || echo "rc $RC: $OUT")"
check "and GitHub is never asked about a number with no status word" "$([ -z "$CALLS" ] && echo ok || echo "calls: $CALLS")"
check "and 'opened' or 'reopened' is not the word 'open'" "$(lacks "$OUT" "line 4")"
check "and the run says it found no pair rather than passing silently" "$(has "$OUT" "no line")"

# ---------------------------------------------------------------------------
# SKIPPED: a number with no repository is never guessed. Its lines are counted and named, gh is not
# asked, and the run does not exit clean.
# ---------------------------------------------------------------------------
d="$(mem bare "# Memory
- PR #40 open, awaiting review
- issue 41 still pending
- alpha#42 pending")"
run "$d" ""
check "a status line naming a bare number exits 4" "$([ "$RC" -eq 4 ] && echo ok || echo "rc $RC: $OUT")"
check "and says how many lines were skipped" "$(has "$OUT" "3 line(s)")"
check "and names their line numbers" "$(has "$OUT" "MEMORY.md lines 2, 3, 4")"
check "and says no repository is guessed" "$(has "$OUT" "guess")"
check "and never asks GitHub" "$([ -z "$CALLS" ] && echo ok || echo "calls: $CALLS")"

# ---------------------------------------------------------------------------
# VOLUME: one call per distinct reference, however many lines and files name it. The entry files
# beside the index are read too, and a disagreement in one is reported under its own name.
# ---------------------------------------------------------------------------
d="$(mem volume "- fixture-org/zeta#50 open
- fixture-org/zeta#50 still open
- Fixture-Org/Zeta#50 pending" entry-one.md "- fixture-org/zeta#50 awaiting merge
- fixture-org/zeta#51 open" entry-two.md "- fixture-org/zeta#50 open")"
run "$d" "repos/fixture-org/zeta/issues/50|0|$OPEN_PR
repos/fixture-org/zeta/issues/51|0|$MERGED_PR"
check "a reference named on five lines in three files is asked about once" "$([ "$(calls_to repos/fixture-org/zeta/issues/50)" -eq 1 ] && echo ok || echo "calls: $CALLS")"
check "and two distinct references cost two calls in all" "$([ "$(printf '%s\n' "$CALLS" | grep -c .)" -eq 2 ] && echo ok || echo "calls: $CALLS")"
check "an entry file's disagreement is reported under its own name" "$(has "$OUT" "entry-one.md line 2")"
check "and the index lines that agree are not" "$(lacks "$OUT" "MEMORY.md line")"

# ---------------------------------------------------------------------------
# COULD NOT CHECK: every way gh can fail is printed as "could not check" with its own reason, never
# counted as agreeing, and exits 3.
# ---------------------------------------------------------------------------
d="$(mem cannot "- fixture-org/eta#60 still open")"
cannot_case() { # cannot_case <what> <exit code> <gh output> <reason the check must give>
  run "$d" "repos/fixture-org/eta/issues/60|$2|$3"
  check "$1: exits 3" "$([ "$RC" -eq 3 ] && echo ok || echo "rc $RC: $OUT")"
  check "$1: says it could not check" "$(has "$OUT" "could not check fixture-org/eta#60")"
  check "$1: gives the reason" "$(has "$OUT" "$4")"
  check "$1: and never counts it as agreeing" "$(has "$OUT" "0 agree")"
}
cannot_case "not signed in" 4 "To get started with GitHub CLI, please run:  gh auth login" "not signed in"
cannot_case "a token GitHub refuses" 1 "gh: Bad credentials (HTTP 401)" "not signed in"
cannot_case "no network" 1 "error connecting to api.github.com" "could not reach GitHub"
cannot_case "a repository this account cannot see" 1 "gh: Not Found (HTTP 404)" "not visible to this account"
cannot_case "a rate limit" 1 "gh: API rate limit exceeded for user ID 1. (HTTP 403)" "rate limit"
cannot_case "an answer that is not a state" 0 "something else entirely" "not a state"
cannot_case "any other failure" 7 "gh: something unforeseen" "gh exited 7"

# gh not on the PATH at all. The PATH is built from links to only the tools the check needs, so the
# real gh (in /usr/bin on a CI runner) cannot be found either.
mkdir -p "$TMPROOT/nogh"
for tool in bash env perl tr cat; do
  real="$(command -v "$tool" 2>/dev/null)" && ln -sf "$real" "$TMPROOT/nogh/$tool"
done
n=$((n + 1)); : > "$TMPROOT/log.$n"
OUT="$(env PATH="$TMPROOT/nogh" GH_FAKE_LOG="$TMPROOT/log.$n" bash "$CHECK" "$d" 2>&1)"; RC=$?
check "gh missing: exits 3" "$([ "$RC" -eq 3 ] && echo ok || echo "rc $RC: $OUT")"
check "gh missing: says it could not check, and why" "$(has "$OUT" "gh is not installed")"
check "gh missing: never counts it as agreeing" "$(has "$OUT" "0 agree")"

# A call that hangs is stopped at the per call limit, and the overall limit stops asking at all.
run "$d" "repos/fixture-org/eta/issues/60|0|$OPEN_PR" GH_FAKE_SLEEP=5 MEMORY_STATUS_CALL_SECONDS=1
check "a call past its limit exits 3" "$([ "$RC" -eq 3 ] && echo ok || echo "rc $RC: $OUT")"
check "and says gh did not answer in time" "$(has "$OUT" "did not answer within 1")"
d2="$(mem overall "- fixture-org/eta#61 open
- fixture-org/eta#62 open
- fixture-org/eta#63 open")"
run "$d2" "repos/fixture-org/eta/issues/61|0|$OPEN_PR
repos/fixture-org/eta/issues/62|0|$OPEN_PR
repos/fixture-org/eta/issues/63|0|$OPEN_PR" GH_FAKE_SLEEP=3 MEMORY_STATUS_CALL_SECONDS=10 MEMORY_STATUS_TOTAL_SECONDS=1
check "the overall limit stops further calls" "$([ "$(printf '%s\n' "$CALLS" | grep -c .)" -eq 1 ] && echo ok || echo "calls: $CALLS")"
check "and the references never asked are said to be unchecked for that reason" "$(has "$OUT" "overall limit")"
check "and the run exits 3" "$([ "$RC" -eq 3 ] && echo ok || echo "rc $RC: $OUT")"

# The limits are read as numbers above zero with leading zeros cut: 08 is eight seconds, not an
# octal error that leaves the remaining time empty (the lessons review of 523d52e), and a value that
# is not a number above zero is refused rather than run unbounded or not at all.
run "$d" "repos/fixture-org/eta/issues/60|0|$OPEN_PR" MEMORY_STATUS_TOTAL_SECONDS=08 MEMORY_STATUS_CALL_SECONDS=09
check "limits written with a leading zero are read as decimal" "$([ "$RC" -eq 0 ] && echo ok || echo "rc $RC: $OUT")"
check "and the reference is still asked about" "$([ "$(calls_to repos/fixture-org/eta/issues/60)" -eq 1 ] && echo ok || echo "calls: $CALLS")"
for bad in 0 00 abc -5; do
  run "$d" "" MEMORY_STATUS_TOTAL_SECONDS="$bad"
  check "an overall limit of '$bad' is refused with exit 2" "$([ "$RC" -eq 2 ] && echo ok || echo "rc $RC: $OUT")"
  run "$d" "" MEMORY_STATUS_CALL_SECONDS="$bad"
  check "a per call limit of '$bad' is refused with exit 2" "$([ "$RC" -eq 2 ] && echo ok || echo "rc $RC: $OUT")"
done

# Precedence: a disagreement outranks a reference that could not be checked, which outranks a
# skipped line, and each is still printed.
d="$(mem mixed "- fixture-org/theta#70 open
- fixture-org/theta#71 open
- PR #72 open")"
run "$d" "repos/fixture-org/theta/issues/70|0|$MERGED_PR
repos/fixture-org/theta/issues/71|1|error connecting to api.github.com"
check "a disagreement beside an unchecked and a skipped line exits 1" "$([ "$RC" -eq 1 ] && echo ok || echo "rc $RC: $OUT")"
check "and still says what could not be checked" "$(has "$OUT" "could not check fixture-org/theta#71")"
check "and what was skipped" "$(has "$OUT" "MEMORY.md line 3")"
d="$(mem mixed2 "- fixture-org/theta#71 open
- PR #72 open")"
run "$d" "repos/fixture-org/theta/issues/71|1|error connecting to api.github.com"
check "an unchecked reference beside a skipped line exits 3, not 4" "$([ "$RC" -eq 3 ] && echo ok || echo "rc $RC: $OUT")"

# ---------------------------------------------------------------------------
# NOTHING TO READ, and a wrong call, are refusals (exit 2), never a clean pass.
# ---------------------------------------------------------------------------
OUT="$(bash "$CHECK" 2>&1)"; RC=$?
check "no folder named exits 2" "$([ "$RC" -eq 2 ] && echo ok || echo "rc $RC: $OUT")"
OUT="$(bash "$CHECK" "$TMPROOT/no-such-folder" 2>&1)"; RC=$?
check "a folder that is not there exits 2" "$([ "$RC" -eq 2 ] && echo ok || echo "rc $RC: $OUT")"
mkdir -p "$TMPROOT/empty"
OUT="$(bash "$CHECK" "$TMPROOT/empty" 2>&1)"; RC=$?
check "a folder holding no memory file exits 2" "$([ "$RC" -eq 2 ] && echo ok || echo "rc $RC: $OUT")"
OUT="$(bash "$CHECK" --fix "$TMPROOT/empty" 2>&1)"; RC=$?
check "an argument it does not know exits 2, rather than running as if it were not there" "$([ "$RC" -eq 2 ] && echo ok || echo "rc $RC: $OUT")"

# A file it cannot read is not a file with nothing stale in it. Only measurable where chmod can take
# read access away, which it cannot for root, so it says UNMEASURED there (L411).
d="$(mem unreadable "- nothing here" locked.md "- fixture-org/iota#80 open")"
chmod 000 "$d/locked.md"
if [ -r "$d/locked.md" ]; then
  echo "SUITE-PART-UNMEASURED an unreadable memory file, because this user can read a file with no permissions"
else
  run "$d" ""
  check "a memory file it cannot read exits 3" "$([ "$RC" -eq 3 ] && echo ok || echo "rc $RC: $OUT")"
  check "and names it" "$(has "$OUT" "locked.md")"
fi
chmod 600 "$d/locked.md"

# ---------------------------------------------------------------------------
# PRINT ONLY: the folder is byte for byte what it was, and nothing was added to it.
# ---------------------------------------------------------------------------
d="$(mem readonly "- fixture-org/kappa#90 open" entry.md "- fixture-org/kappa#91 pending")"
before="$(cd "$d" && ls -lA && ls -ld . && cat ./*.md)"
run "$d" "repos/fixture-org/kappa/issues/90|0|$MERGED_PR
repos/fixture-org/kappa/issues/91|0|$CLOSED_ISSUE"
after="$(cd "$d" && ls -lA && ls -ld . && cat ./*.md)"
check "a run that finds stale lines changes nothing in the folder" "$([ "$before" = "$after" ] && echo ok || echo "the folder changed")"

# ---------------------------------------------------------------------------
# The status words are ONE list in the check, so a word added there is added everywhere it is read.
# ---------------------------------------------------------------------------
words_lines="$(grep -c '^STATUS_WORDS=' "$CHECK")"
check "the status words are declared once" "$([ "$words_lines" -eq 1 ] && echo ok || echo "found $words_lines declarations")"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
