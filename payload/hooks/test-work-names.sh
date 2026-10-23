#!/usr/bin/env bash
# The scanner that keeps the work GitHub organisations out of this public repository (claude-config#1568).
#
# The work's private repositories live under two GitHub organisations, and this repository is
# public. Their names were written into 37 tracked files and more (lists the code reads, test
# fixtures, comments, lesson provenance), and each one tells a stranger exactly where to look.
# payload/hooks/lib/work-names.py is the one scanner that finds them, and this suite holds:
#   2. The scanner can see one: an organisation it is told about by hash is found as an owner, in a
#      URL, inside a longer hyphenated name and in any letter case, and a clean tree is clean.
#   3. The registry half: the owner of every repository in a fixture registry is found, a missing
#      registry is said rather than read as empty, and an unreadable one is refused.
#   4. Nothing the scanner prints repeats a name it found (CI logs of a public repository are
#      public too), only where it is.
# Two more parts arrive with the move of sleep mode's repository lists, the last tracked list that
# still names an organisation (claude-config#1568): (1) nothing this repository publishes names one,
# over the whole tree, and (5) a send refuses to publish a file naming one. Both would fail on that
# list while it is tracked, and its move waits on a decision of Dan's.
#
# The scanner holds the two organisation names only as sha256 hashes, and this suite tests with an
# invented organisation handed in the same way (WORK_NAMES_EXTRA_HASHES). No work organisation or
# repository name belongs in this file.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SCAN="$HERE/lib/work-names.py"
. "$HERE/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

pass=0; fail=0
check(){   # $1 = name  $2.. = a command that succeeds when the check holds
  local name="$1"; shift
  if "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $name"; fi
}
has(){ [[ "$1" == *"$2"* ]]; }
lacks(){ [[ "$1" != *"$2"* ]]; }

for tool in node python3 shasum; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "FAIL: $tool is not on PATH, so this suite cannot run."
    printf 'SUITE-RESULT passed=0 failed=1\n'
    exit 1
  fi
done

_tmp="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "${_tmp%/}/work-names.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# An invented organisation, handed to the scanner by hash exactly as the real two are built in.
FAKE_ORG="Acme-HQ"
FAKE_HASH="$(printf '%s' "acme-hq" | shasum -a 256 | cut -d' ' -f1)"
EMPTY_HOME="$WORK/empty-home"; mkdir -p "$EMPTY_HOME"

# ---------------------------------------------------------------- 2. the scanner can see one
T="$WORK/tree"; mkdir -p "$T/sub"
printf 'a clean line about acme/widget#3\n' > "$T/clean.md"
printf 'line one\nsee %s/widget#3 for the story\n' "$FAKE_ORG" > "$T/owner.md"
printf 'url https://github.com/%s/widget/pull/9\n' "$(printf '%s' "$FAKE_ORG" | tr '[:lower:]' '[:upper:]')" > "$T/sub/url.txt"
printf '{"waitOwners": ["studio-%s-partner"]}\n' "$(printf '%s' "$FAKE_ORG" | tr '[:upper:]' '[:lower:]')" > "$T/embedded.json"
printf 'touch "$FAKE/%s_widget"\n' "$FAKE_ORG" > "$T/fixture.sh"
printf 'acmehq and acme hq and acme_hq are other names\n' > "$T/lookalike.md"
printf 'binary\000%s/widget\n' "$FAKE_ORG" > "$T/blob.bin"

scan_tree(){   # $1 = HOME  $2.. = files relative to $T -> output, rc in scan_rc
  local home="$1"; shift
  scan_out="$( cd "$T" && HOME="$home" WORK_NAMES_EXTRA_HASHES="$FAKE_HASH" python3 "$SCAN" --root "$T" "$@" 2>&1 )"; scan_rc=$?
}
scan_tree "$EMPTY_HOME" clean.md lookalike.md
check "(control) a tree with no organisation name is clean (exit $scan_rc): $scan_out" [ "$scan_rc" -eq 0 ]
scan_tree "$EMPTY_HOME" owner.md
check "an organisation as an owner is found (exit $scan_rc)" [ "$scan_rc" -eq 1 ]
check "and named by file and line: $scan_out" has "$scan_out" "owner.md:2"
scan_tree "$EMPTY_HOME" sub/url.txt
check "in a URL, in capitals: $scan_out" has "$scan_out" "sub/url.txt:1"
scan_tree "$EMPTY_HOME" embedded.json
check "inside a longer hyphenated owner: $scan_out" has "$scan_out" "embedded.json:1"
scan_tree "$EMPTY_HOME" fixture.sh
check "before an underscore in a fixture name: $scan_out" has "$scan_out" "fixture.sh:1"
scan_tree "$EMPTY_HOME" blob.bin
check "a binary file is not read as text (exit $scan_rc)" [ "$scan_rc" -eq 0 ]
scan_tree "$EMPTY_HOME" clean.md owner.md sub/url.txt embedded.json fixture.sh lookalike.md
check "every hit in one run is reported, and only those: $scan_out" [ "$(grep -c ': a work organisation' <<<"$scan_out")" -eq 4 ]
# 4. What it prints never repeats what it found, in any case.
check "the output never repeats the name it found: $scan_out" lacks "$(printf '%s' "$scan_out" | tr '[:upper:]' '[:lower:]')" "acme-hq"
# Paths come from a NUL separated list as well as from arguments, which is how this suite feeds it.
nul_out="$( cd "$T" && printf 'owner.md\0clean.md\0' | HOME="$EMPTY_HOME" WORK_NAMES_EXTRA_HASHES="$FAKE_HASH" python3 "$SCAN" --root "$T" --files0-from - 2>&1 )"; nul_rc=$?
check "a NUL separated list is read too (exit $nul_rc): $nul_out" [ "$nul_rc" -eq 1 ]
# Without the extra hash, the invented organisation is nobody's: the hit above came from the hash.
plain_out="$( cd "$T" && HOME="$EMPTY_HOME" python3 "$SCAN" --root "$T" owner.md 2>&1 )"; plain_rc=$?
check "(control) the invented organisation is found only because the suite named it: $plain_out" [ "$plain_rc" -eq 0 ]
# A file the list names that is not there is a fault in the list, never a clean file (L98).
scan_tree "$EMPTY_HOME" clean.md missing.md
check "a listed file that cannot be read is refused (exit $scan_rc): $scan_out" [ "$scan_rc" -eq 2 ]

# ---------------------------------------------------------------- 3. the registry half
check "with no registry the scan says only the built in names were checked: $plain_out" has "$plain_out" "no dev update registry"
check "and names where it looked" has "$plain_out" "$EMPTY_HOME/.claude/skills/pennie-dev-update/repos.local.json"
RH="$WORK/registry-home"; mkdir -p "$RH/.claude/skills/pennie-dev-update"
printf '{"repos":[{"name":"Widget","repo":"Globex-Work/widget","account":"globex-bot"}]}\n' > "$RH/.claude/skills/pennie-dev-update/repos.local.json"
printf 'the board lives in globex-work/widget\n' > "$T/registry.md"
scan_tree "$RH" clean.md registry.md
check "the owner of a repository in this Mac's registry is found (exit $scan_rc): $scan_out" [ "$scan_rc" -eq 1 ]
check "and the hit says it came from the registry: $scan_out" has "$scan_out" "registry.md:1: a name from this Mac's dev update registry"
check "and never repeats it: $scan_out" lacks "$(printf '%s' "$scan_out" | tr '[:upper:]' '[:lower:]')" "globex-work"
check "and the summary says the registry was read" has "$scan_out" "1 owner from"
scan_tree "$EMPTY_HOME" registry.md
check "(control) without the registry the same file is clean (exit $scan_rc)" [ "$scan_rc" -eq 0 ]
# The coverage check the real registry is held to below can fail: an owner no built in hash covers.
unc_out="$(HOME="$RH" python3 "$SCAN" --uncovered-owners 2>&1)"; unc_rc=$?
check "(control) a registry owner the built in names do not cover is reported (exit $unc_rc): $unc_out" [ "$unc_rc" -eq 1 ]
check "and the report never repeats it" lacks "$unc_out" "globex"
printf '{ not json\n' > "$RH/.claude/skills/pennie-dev-update/repos.local.json"
scan_tree "$RH" clean.md
check "an unreadable registry is refused, never read as empty (exit $scan_rc): $scan_out" [ "$scan_rc" -eq 2 ]
check "and says why" has "$scan_out" "not valid JSON"

# The two built in hashes cover every owner in the registry on a Mac that has one, so the check CI
# runs (with no registry) is the same check for the organisations that matter. Only measurable where
# a registry is, and said plainly where it is not, never failed for it (L411).
cover_out="$(python3 "$SCAN" --uncovered-owners 2>&1)"; cover_rc=$?
case "$cover_out" in
  *"no dev update registry"*) echo "note: this machine has no dev update registry, so whether the built in names cover its owners was not measured here." ;;
  *) check "every owner in this Mac's registry is one the built in names cover (exit $cover_rc): $cover_out" [ "$cover_rc" -eq 0 ] ;;
esac

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
