#!/usr/bin/env bash
# Tests for check-project-list.sh, which reads the Projects section of the synced CLAUDE.md and
# fails when a path listed for THIS Mac is not there (claude-config#122).
#
# The section named four projects by absolute path and not one of them existed on this machine.
# That file loads at the start of every session on both Macs, so it was read constantly and was
# wrong on at least one of them, and tracing it cost a search of the whole home directory before it
# became clear they were simply elsewhere. It is the shape L153 warns about, a path recording where
# something happened to be rather than what it is, made worse by one file being shared between two
# machines whose contents differ.
#
# A list kept by hand beside the thing it describes drifts (L41), and the only cheap way to stop
# that here is to check it. So the checks below care about three things: that a missing path is
# REPORTED rather than passed over, that a machine the list says nothing about is a distinct and
# stated outcome rather than a quiet pass (L98, L11), and that a section holding nothing at all is
# refused rather than read as a clean inventory.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$DIR/check-project-list.sh"

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

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.projlist.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-check-project-list: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

mkfile() { # mkfile <name> <body>  -> prints the path
  local f="$TMPROOT/$1"
  printf '%s\n' "$2" > "$f"
  printf '%s' "$f"
}
run() { # run <file> <host>
  PROJECT_LIST_FILE="$1" PROJECT_LIST_HOST="$2" bash "$CHECK" 2>&1
}

mkdir -p "$TMPROOT/here/AppOne" "$TMPROOT/here/AppTwo"
# Each fixture project carries its own instructions file, because the check asks two questions of
# every entry and a test about the PATH must not fail for the other reason.
: > "$TMPROOT/here/AppOne/CLAUDE.md"
: > "$TMPROOT/here/AppTwo/CLAUDE.md"

GOOD="$(mkfile good.md "## Projects

On MacOne:
- \`$TMPROOT/here/AppOne\`: something
- \`$TMPROOT/here/AppTwo\`

On MacTwo:
- \`$TMPROOT/nowhere/AppThree\`

## Writing Style")"

# ---------------------------------------------------------------------------
# The ordinary case, and the control that matters: the OTHER Mac's entry is deliberately a path
# that does not exist here, so a check reading the whole section rather than this machine's block
# would fail, and passing proves it read the right block.
# ---------------------------------------------------------------------------
out_ok="$(run "$GOOD" MacOne)"; code_ok=$?
[ "$code_ok" -eq 0 ] \
  && check "a list whose paths are all present passes" ok \
  || check "a list whose paths are all present passes" "exit=$code_ok out=$out_ok"
grep -q '2' <<< "$out_ok" \
  && check "and says how many it checked" ok \
  || check "and says how many it checked" "out=$out_ok"
grep -q 'AppThree' <<< "$out_ok" \
  && check "the other Mac's entries are not checked here" "it complained about AppThree" \
  || check "the other Mac's entries are not checked here" ok

# ---------------------------------------------------------------------------
# A path that is not there. This is the whole point, and it is watched failing before anything
# below is trusted (L1).
# ---------------------------------------------------------------------------
BAD="$(mkfile bad.md "## Projects

On MacOne:
- \`$TMPROOT/here/AppOne\`
- \`$TMPROOT/here/Vanished\`

## Writing Style")"
out_bad="$(run "$BAD" MacOne)"; code_bad=$?
[ "$code_bad" -eq 1 ] \
  && check "a path that is not there fails the check" ok \
  || check "a path that is not there fails the check" "exit=$code_bad out=$out_bad"
grep -q 'Vanished' <<< "$out_bad" \
  && check "and names the one it could not find" ok \
  || check "and names the one it could not find" "out=$out_bad"
grep -q 'AppOne' <<< "$out_bad" \
  && check "and does not accuse the ones it did find" "it named AppOne too" \
  || check "and does not accuse the ones it did find" ok

# ---------------------------------------------------------------------------
# A machine the list says nothing about: the CI runner, or a third Mac. Passing is right, saying
# so is what stops it being read as a clean inventory of a machine nobody listed (L11, L98).
# ---------------------------------------------------------------------------
out_other="$(run "$GOOD" SomeRunner)"; code_other=$?
[ "$code_other" -eq 0 ] \
  && check "a machine the list does not mention is not a failure" ok \
  || check "a machine the list does not mention is not a failure" "exit=$code_other out=$out_other"
grep -qi 'no entries for' <<< "$out_other" \
  && check "but it says it checked nothing rather than reporting a clean list" ok \
  || check "but it says it checked nothing rather than reporting a clean list" "out=$out_other"

# ---------------------------------------------------------------------------
# Ways of reading nothing, each its own outcome. A section that has gone missing and one that is
# present but empty are different faults and must not share an answer (L11).
# ---------------------------------------------------------------------------
NOSEC="$(mkfile nosec.md "## Writing Style

- no dashes")"
out_nosec="$(run "$NOSEC" MacOne)"; code_nosec=$?
[ "$code_nosec" -eq 2 ] \
  && check "a file with no Projects section is refused" ok \
  || check "a file with no Projects section is refused" "exit=$code_nosec out=$out_nosec"

EMPTYSEC="$(mkfile emptysec.md "## Projects

## Writing Style")"
out_empty="$(run "$EMPTYSEC" MacOne)"; code_empty=$?
[ "$code_empty" -eq 2 ] \
  && check "a Projects section listing no machine at all is refused too" ok \
  || check "a Projects section listing no machine at all is refused too" "exit=$code_empty out=$out_empty"
[ "$out_nosec" != "$out_empty" ] \
  && check "and the two refusals do not say the same thing" ok \
  || check "and the two refusals do not say the same thing" "both said: $out_nosec"

out_missing="$(PROJECT_LIST_FILE="$TMPROOT/not-here.md" PROJECT_LIST_HOST=MacOne bash "$CHECK" 2>&1)"; code_missing=$?
[ "$code_missing" -eq 2 ] \
  && check "a file that does not exist is refused" ok \
  || check "a file that does not exist is refused" "exit=$code_missing out=$out_missing"

# ---------------------------------------------------------------------------
# A tilde is how these paths are written, because a real home directory in a synced file is wrong
# on every other Mac and is refused by check-home-paths.sh. So it has to be expanded.
# ---------------------------------------------------------------------------
# HOME is SET here rather than read, so the assertion is about the expansion and not about what the
# real home directory happens to contain on the machine running this (L411, L504).
mkdir -p "$TMPROOT/fakehome"
: > "$TMPROOT/fakehome/CLAUDE.md"
TILDE="$(mkfile tilde.md "## Projects

On MacOne:
- \`~\`: the home directory, which this test supplies

## Writing Style")"
out_tilde="$(HOME="$TMPROOT/fakehome" PROJECT_LIST_FILE="$TILDE" PROJECT_LIST_HOST=MacOne bash "$CHECK" 2>&1)"; code_tilde=$?
[ "$code_tilde" -eq 0 ] \
  && check "a path written with a tilde is expanded, not taken literally" ok \
  || check "a path written with a tilde is expanded, not taken literally" "exit=$code_tilde out=$out_tilde"

# And the failure it guards against, watched: with the tilde unexpanded there is no such directory,
# which is the missing path outcome rather than this one.
out_tilde_lit="$(HOME="$TMPROOT/nowhere-at-all" PROJECT_LIST_FILE="$TILDE" PROJECT_LIST_HOST=MacOne bash "$CHECK" 2>&1)"; code_tilde_lit=$?
[ "$code_tilde_lit" -eq 1 ] \
  && check "and a tilde pointing nowhere is reported as a missing path" ok \
  || check "and a tilde pointing nowhere is reported as a missing path" "exit=$code_tilde_lit out=$out_tilde_lit"

# ---------------------------------------------------------------------------
# A listed project carrying no instructions file of its own. The Projects section exists so that a
# session started in one of these repositories reads that repository's own context, and a project
# with neither CLAUDE.md nor AGENTS.md gets whatever sits ABOVE it instead: on 2026-09-19 that was
# a stray Vercel best practices file in the home directory, loaded as project instructions into a
# Swift app and a bash tool. The path being present says nothing about that, so it is its own
# question with its own exit code (L11).
#
# AGENTS.md counts, because the predicate has to be the one Claude Code itself uses when it decides
# what to load, not a stricter one of our own (L144). NurseDex carries an AGENTS.md and no
# CLAUDE.md, and it is correctly provided for.
# ---------------------------------------------------------------------------
mkdir -p "$TMPROOT/here/WithClaude" "$TMPROOT/here/WithAgents" "$TMPROOT/here/Bare"
: > "$TMPROOT/here/WithClaude/CLAUDE.md"
: > "$TMPROOT/here/WithAgents/AGENTS.md"

NOFILE="$(mkfile nofile.md "## Projects

On MacOne:
- \`$TMPROOT/here/WithClaude\`
- \`$TMPROOT/here/Bare\`

## Writing Style")"
out_nofile="$(run "$NOFILE" MacOne)"; code_nofile=$?
[ "$code_nofile" -eq 3 ] \
  && check "a listed project with no instructions file of its own is reported" ok \
  || check "a listed project with no instructions file of its own is reported" "exit=$code_nofile out=$out_nofile"
grep -q 'Bare' <<< "$out_nofile" \
  && check "and names the one that carries nothing" ok \
  || check "and names the one that carries nothing" "out=$out_nofile"
grep -q 'WithClaude' <<< "$out_nofile" \
  && check "and does not accuse the one that carries a CLAUDE.md" "it named WithClaude too" \
  || check "and does not accuse the one that carries a CLAUDE.md" ok

AGENTSOK="$(mkfile agentsok.md "## Projects

On MacOne:
- \`$TMPROOT/here/WithAgents\`

## Writing Style")"
out_agents="$(run "$AGENTSOK" MacOne)"; code_agents=$?
[ "$code_agents" -eq 0 ] \
  && check "an AGENTS.md is a project's own instructions too, which is what Claude Code loads" ok \
  || check "an AGENTS.md is a project's own instructions too, which is what Claude Code loads" "exit=$code_agents out=$out_agents"

# A path that is not there and a path with no instructions file, in one list. The missing path wins
# and says so: there is no useful answer to "what does that directory contain" when the directory
# is not there, and reporting the weaker fault would send somebody looking for the wrong thing.
BOTH="$(mkfile both.md "## Projects

On MacOne:
- \`$TMPROOT/here/Bare\`
- \`$TMPROOT/here/Vanished\`

## Writing Style")"
out_both="$(run "$BOTH" MacOne)"; code_both=$?
[ "$code_both" -eq 1 ] \
  && check "a missing path outranks a missing instructions file" ok \
  || check "a missing path outranks a missing instructions file" "exit=$code_both out=$out_both"
grep -q 'Vanished' <<< "$out_both" \
  && check "and the message is the one about the path" ok \
  || check "and the message is the one about the path" "out=$out_both"

[ "$code_nofile" != "$code_bad" ] \
  && check "the two faults do not share an exit code" ok \
  || check "the two faults do not share an exit code" "both exited $code_bad"

# ---------------------------------------------------------------------------
# The real file, last, by which point the checker has been watched failing several ways. On this
# Mac it names real projects; on the CI runner it names neither Mac and says so.
#
# The PATH half is asserted here, because the list controls it: an entry naming somewhere that is
# not on this machine is always wrong, and nothing outside this repository can make it right.
#
# The INSTRUCTIONS half deliberately is NOT asserted here, and that is not a softening. A checkout
# standing on a branch created before its CLAUDE.md landed genuinely has no file on disk, which is
# a true finding about that checkout and a false one about the project, and it is not fixable from
# here: the branch belongs to whoever is working in it. A red here would be indistinguishable from
# a real defect (L411) and would block every unrelated push in this repository for as long as it
# lasted (L538). The live state is reported where it can be acted on instead, by
# project-list-nudge.sh, once per session. What the checker DOES with a bare project is proven
# above, on fixtures this suite controls.
# ---------------------------------------------------------------------------
out_real="$(bash "$CHECK" 2>&1)"; code_real=$?
[ "$code_real" -ne 1 ] \
  && check "every project the real list names for this machine is on it" ok \
  || check "every project the real list names for this machine is on it" "exit=$code_real out=$out_real"
[ "$code_real" -ne 2 ] \
  && check "and the real list could be read at all" ok \
  || check "and the real list could be read at all" "exit=$code_real out=$out_real"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
