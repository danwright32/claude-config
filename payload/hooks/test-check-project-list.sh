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
TILDE="$(mkfile tilde.md "## Projects

On MacOne:
- \`~\`: the home directory itself, which certainly exists

## Writing Style")"
out_tilde="$(run "$TILDE" MacOne)"; code_tilde=$?
[ "$code_tilde" -eq 0 ] \
  && check "a path written with a tilde is expanded, not taken literally" ok \
  || check "a path written with a tilde is expanded, not taken literally" "exit=$code_tilde out=$out_tilde"

# ---------------------------------------------------------------------------
# The real file, last, by which point the checker has been watched failing five ways. On this Mac
# it names real projects; on the CI runner it names neither Mac and says so.
# ---------------------------------------------------------------------------
out_real="$(bash "$CHECK" 2>&1)"; code_real=$?
[ "$code_real" -eq 0 ] \
  && check "the real project list is correct for this machine" ok \
  || check "the real project list is correct for this machine" "exit=$code_real out=$out_real"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
