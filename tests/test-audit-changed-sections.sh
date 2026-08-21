#!/usr/bin/env bash
# Tests for audit-changed-sections.sh, which runs, on its own, every suite section a push touched
# (claude-config#105).
#
# The whole point of the thing under test is to notice a section that cannot run alone, so every
# check below is run against a throwaway git repo built to hold the answer it expects. A derivation
# that found NOTHING is the failure this is most likely to have, and it is asserted separately from
# a run that legitimately had nothing to do, because the two are indistinguishable in the output
# unless they are worded differently (L98, L11).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIT="$DIR/audit-changed-sections.sh"

pass=0; fail=0
check(){ if [[ "$2" == "ok" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 ($2)"; fi; }

# Named from an explicit template, like everything else this repo creates in the temp directory, so
# a copy an interrupted run leaves behind can be attributed to this test rather than swept by age.
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-audit-test.XXXXXXXX")" || TMPROOT=""
# The cleanup below is an `rm -rf` on a path from a command that can fail. An empty or unexpected
# value there would aim it somewhere real, so it is refused UP FRONT rather than relied on being
# harmless (L5, L9). The suite next door already holds this line for its own lock directory.
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}"|"${TMPDIR:-/tmp}"|"${TMPDIR:-/tmp}"/)
    echo "test-audit-changed-sections: refusing to run: the throwaway directory came back as '${TMPROOT}', which is not a directory of this test's own." >&2
    exit 2 ;;
esac
[ -d "$TMPROOT" ] || { echo "test-audit-changed-sections: '$TMPROOT' is not a directory, so nothing was created to work in." >&2; exit 2; }
trap 'rm -rf "$TMPROOT"' EXIT

# A tiny stand-in suite with the same shape as the real one: a preamble, headings, and a
# SECTION_ONLY knob. Using the real 4700 line suite here would make every check cost minutes and
# would test the sync tool rather than this script.
mkrepo(){                 # $1 = repo name -> prints its path
  local r="$TMPROOT/$1"
  mkdir -p "$r/tests"
  cat > "$r/tests/test-claude-sync.sh" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
PREAMBLE=1
if [ -n "${SECTION_LIST:-}" ]; then
  # Real line numbers, derived from this file, but titles deliberately NOT the text a naive grep
  # would produce: the headings below say "== alpha ==" and this says "== LISTED alpha ==". So a
  # caller reporting the LISTED form can only have asked, and one that greps the file cannot.
  # The numbers have to be derived rather than written down for the same reason the real thing
  # derives them: editing this fixture moves every line below the edit.
  while IFS= read -r _l; do
    _n="${_l%%:*}"; _r="${_l#*:}"
    _t="${_r#section \"}"; _t="${_t%\"}"
    printf '%s\t%s\n' "$_n" "== LISTED ${_t#== }"
  done < <(grep -n '^section "' "$0")
  exit 0
fi
if [ -n "${SECTION_ONLY:-}" ]; then
  echo "ran only: $SECTION_ONLY"
  case "$SECTION_ONLY" in
    *BROKEN*) echo "  FAILING"; exit 1 ;;
  esac
  echo "PASS=1 FAIL=0"
  exit 0
fi
section "== alpha =="
echo a
section "== beta =="
echo b
section "== BROKEN gamma =="
echo c
FAKE
  git -C "$r" init -q 2>/dev/null
  git -C "$r" config user.email t@t; git -C "$r" config user.name t
  git -C "$r" add -A; git -C "$r" commit -qm base
  printf '%s' "$r"
}

run(){ ( cd "$1" && AUDIT_SUITE="$1/tests/test-claude-sync.sh" bash "$AUDIT" HEAD 2>&1 ); }

# --- nothing changed: a legitimate nothing-to-do, and it must SAY that rather than look like a
#     successful audit of everything.
R1="$(mkrepo untouched)"
o1="$(run "$R1")"; c1=$?
[ "$c1" -eq 0 ] && check "an untouched suite exits clean" ok || check "an untouched suite exits clean" "exit=$c1 out=$o1"
printf '%s' "$o1" | grep -qi 'unchanged' \
  && check "and says it had nothing to run, not that everything passed" ok \
  || check "and says it had nothing to run, not that everything passed" "out=$o1"

# --- one section edited: exactly that one is run, and the others are not.
R2="$(mkrepo oneedit)"
perl -pi -e 's/^echo b$/echo b-edited/' "$R2/tests/test-claude-sync.sh"
o2="$(run "$R2")"; c2=$?
[ "$c2" -eq 0 ] && check "a green changed section passes" ok || check "a green changed section passes" "exit=$c2 out=$o2"
printf '%s' "$o2" | grep -q 'LISTED beta' \
  && check "the changed section is the one that ran" ok \
  || check "the changed section is the one that ran" "out=$o2"
# The decisive one: the name can only have come from asking the suite, because the suite's own
# heading lines say something different. Two implementations of "where do the sections start" would
# have produced the file's text instead (claude-config#114).
printf '%s' "$o2" | grep -q 'LISTED' \
  && check "the audit asked the suite rather than grepping the file itself" ok \
  || check "the audit asked the suite rather than grepping the file itself" "out=$o2"
printf '%s' "$o2" | grep -q 'alpha' \
  && check "an untouched section is not run" "out=$o2" \
  || check "an untouched section is not run" ok
printf '%s' "$o2" | grep -qE 'audited 1 ' \
  && check "it reports how many sections it audited" ok \
  || check "it reports how many sections it audited" "out=$o2"

# --- a changed section that cannot run alone: the whole reason this exists.
R3="$(mkrepo brokenedit)"
perl -pi -e 's/^echo c$/echo c-edited/' "$R3/tests/test-claude-sync.sh"
o3="$(run "$R3")"; c3=$?
[ "$c3" -ne 0 ] && check "a changed section that fails alone fails the audit" ok \
                || check "a changed section that fails alone fails the audit" "exit=$c3 out=$o3"
printf '%s' "$o3" | grep -q 'LISTED BROKEN gamma' \
  && check "and names which section could not run alone" ok \
  || check "and names which section could not run alone" "out=$o3"

# --- a preamble edit touches everything, so it is NOT silently audited as zero sections. The full
#     suite already covers it; what matters is that this says so rather than reporting a clean
#     audit of nothing.
R4="$(mkrepo preambleedit)"
perl -pi -e 's/^PREAMBLE=1$/PREAMBLE=2/' "$R4/tests/test-claude-sync.sh"
o4="$(run "$R4")"; c4=$?
[ "$c4" -eq 0 ] && check "a preamble edit exits clean" ok || check "a preamble edit exits clean" "exit=$c4 out=$o4"
printf '%s' "$o4" | grep -qi 'preamble' \
  && check "and says the change was in the preamble" ok \
  || check "and says the change was in the preamble" "out=$o4"

# --- two sections edited: both run, and the count says two.
R5="$(mkrepo twoedits)"
perl -pi -e 's/^echo a$/echo a-edited/; s/^echo b$/echo b-edited/' "$R5/tests/test-claude-sync.sh"
o5="$(run "$R5")"; c5=$?
printf '%s' "$o5" | grep -qE 'audited 2 ' \
  && check "two changed sections are both audited" ok \
  || check "two changed sections are both audited" "exit=$c5 out=$o5"

# --- a deletion inside a section still attributes to that section, rather than deriving nothing.
#     A hunk that only removes lines has no lines on the new side at all, which is exactly how a
#     derivation quietly comes back empty.
R6="$(mkrepo deletion)"
perl -ni -e 'print unless /^echo b$/' "$R6/tests/test-claude-sync.sh"
o6="$(run "$R6")"; c6=$?
printf '%s' "$o6" | grep -q 'LISTED beta' \
  && check "a pure deletion still attributes to its section" ok \
  || check "a pure deletion still attributes to its section" "exit=$c6 out=$o6"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
