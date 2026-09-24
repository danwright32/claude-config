#!/usr/bin/env bash
# Tests for find-prior-verdicts.sh, and for the two planning skills running it before any
# grilling question (claude-config#559).
#
# A fake gh on PATH stands in for GitHub, so nothing here reaches the network. Each fixture
# repository is a throwaway git repo, because the helper dates a document hit from git.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/find-prior-verdicts.sh"
LITE="$DIR/../plan-lite/SKILL.md"
COUNCIL="$DIR/SKILL.md"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
check() { # check <description> <expected-substring> <actual>
  if [[ "$3" == *"$2"* ]]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "FAIL: $1"; echo "  expected to contain: $2"; echo "  actual: $3"; fi
}
check_not() { # check_not <description> <forbidden-substring> <actual>
  if [[ "$3" != *"$2"* ]]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "FAIL: $1 (should not contain '$2')"; echo "  actual: $3"; fi
}
check_eq() { # check_eq <description> <expected> <actual>
  if [[ "$3" == "$2" ]]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "FAIL: $1 (expected '$2', got '$3')"; fi
}

# --- the fake gh: answers issue searches from a fixture, or fails on demand ---
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_CALLS"
if [ -n "${GH_FAIL:-}" ]; then echo "gh: simulated API failure" >&2; exit 1; fi
case "$*" in
  *"issue list"*)
    case "$*" in
      *"path scoped"*) printf '541\tCLOSED\t2026-09-23\tRejected: path scoped lesson rules\n' ;;
      *) : ;;
    esac ;;
  *) echo "fake gh: unexpected call: $*" >&2; exit 3 ;;
esac
STUB
chmod +x "$TMP/bin/gh"
export GH_CALLS="$TMP/gh-calls"
: >"$GH_CALLS"

mkrepo() { # mkrepo <dir>: a git repo with a decision record naming one rejected route
  mkdir -p "$1/docs"
  git -C "$1" init -q
  printf '# Design\n\nSome intro.\n\n## Lessons loading\n\nPath scoped lesson rules were planned and REJECTED on 2026-09-23.\n' >"$1/DESIGN.md"
  printf '# Readme\n\nNothing relevant.\n' >"$1/README.md"
  printf '# Old notes\n\nThe path scoped idea appears here too.\n' >"$1/docs/notes.md"
  printf 'path scoped, but in source code, never a decision record\n' >"$1/main.sh"
  git -C "$1" add -A
  GIT_AUTHOR_DATE=2026-09-23T10:00:00 GIT_COMMITTER_DATE=2026-09-23T10:00:00 \
    git -C "$1" -c user.name=t -c user.email=t@t commit -q -m init
}
REPO="$TMP/repo"
mkrepo "$REPO"

run() { PATH="$TMP/bin:$PATH" bash "$SCRIPT" "$@" 2>&1; }

# 1. A hit in a decision record is quoted with its file, line and the date that line landed.
out="$(run --dir "$REPO" --repo acme/widgets "path scoped")"; rc=$?
check_eq "a search that ran exits 0" "0" "$rc"
check "the DESIGN.md hit names its file and line" "DESIGN.md:7" "$out"
check "the DESIGN.md hit carries the line itself" "REJECTED on 2026-09-23" "$out"
check "the hit is dated from git" "2026-09-23" "$out"
check "docs markdown is searched" "docs/notes.md:3" "$out"
check_not "source code is not a decision record" "main.sh" "$out"
check "a matching closed issue is quoted with its number" "#541" "$out"
check "the closed issue carries its state" "CLOSED" "$out"
check_not "a search with hits never says none were found" "NONE FOUND" "$out"
check "the issue search asks for every state, closed included" "--state all" "$(cat "$GH_CALLS")"

# 2. No hit anywhere says so plainly, naming what was searched.
: >"$GH_CALLS"
out="$(run --dir "$REPO" --repo acme/widgets "carrier pigeons")"; rc=$?
check_eq "an empty search still exits 0" "0" "$rc"
check "an empty search says NONE FOUND" "NONE FOUND" "$out"
check "an empty search names the documents it read" "DESIGN.md" "$out"
check "an empty search names the issue search" "acme/widgets" "$out"

# 3. gh failing is COULD NOT SEARCH, never NONE FOUND, and the exit says so.
out="$(GH_FAIL=1 run --dir "$REPO" --repo acme/widgets "carrier pigeons")"; rc=$?
check_eq "a failed issue search exits 2" "2" "$rc"
check "a failed issue search says COULD NOT SEARCH" "COULD NOT SEARCH" "$out"
check_not "a failed issue search never claims nothing was found" "NONE FOUND" "$out"

# 4. Several terms are each searched, and a hit on any one counts.
: >"$GH_CALLS"
out="$(run --dir "$REPO" --repo acme/widgets "carrier pigeons" "path scoped")"
check "a second term's hit is reported" "DESIGN.md:7" "$out"
check_eq "each term is its own issue search" "2" "$(grep -c 'issue list' "$GH_CALLS")"

# 5. Refusals: no terms, or a directory that is not a git repo.
out="$(run --dir "$REPO" --repo acme/widgets)"; rc=$?
check_eq "no search terms is refused" "64" "$rc"
mkdir -p "$TMP/notrepo"
out="$(run --dir "$TMP/notrepo" --repo acme/widgets "x")"; rc=$?
check_eq "a directory outside git is refused" "2" "$rc"
check "the refusal says why" "COULD NOT SEARCH" "$out"

# 5b. A flag that needs a value, given last, is refused at once. `shift 2` with one argument left
#     fails without shifting, so the parser used to loop for ever (found by the first real PR lessons
#     review, 2026-09-24). Run in the background and waited on, bounded, so a regression fails here
#     rather than hanging the suite.
for flag in --dir --repo; do
  PATH="$TMP/bin:$PATH" bash "$SCRIPT" "x" "$flag" >"$TMP/trail.out" 2>&1 &
  pid=$!; t0=$SECONDS
  while kill -0 "$pid" 2>/dev/null && [ $((SECONDS - t0)) -lt 5 ]; do sleep 0.1; done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    fail=$((fail + 1)); echo "FAIL: $flag given last hangs instead of being refused"
  else
    wait "$pid"; rc=$?
    check_eq "$flag given last is refused as a usage error" "64" "$rc"
    check "and says which flag lacks its value" "$flag needs a value" "$(cat "$TMP/trail.out")"
  fi
done

# 6. Both skills run the search BEFORE they invoke grilling, and quote the date.
for skill in "$LITE" "$COUNCIL"; do
  name="$(basename "$(dirname "$skill")")"
  helper_line="$(grep -n -m1 'find-prior-verdicts.sh' "$skill" | cut -d: -f1)"
  grill_line="$(grep -n -m1 'invoke the `grilling` skill' "$skill" | cut -d: -f1)"
  if [[ -n "$helper_line" && -n "$grill_line" && "$helper_line" -lt "$grill_line" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $name runs find-prior-verdicts.sh before invoking grilling (helper line '${helper_line:-none}', grilling line '${grill_line:-none}')"
  fi
  check "$name tells Dan the date of an earlier verdict" "yes" "$(grep -q 'with its date' "$skill" && echo yes || echo 'no line saying with its date')"
  check "$name says plainly when nothing was found" "yes" "$(grep -q 'NONE FOUND' "$skill" && echo yes || echo 'no NONE FOUND instruction')"
done

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
