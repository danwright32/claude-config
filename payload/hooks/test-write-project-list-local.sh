#!/usr/bin/env bash
# Tests for lib/write-project-list-local.sh, which writes a Mac's own projects.local.txt from the
# last version of payload/CLAUDE.md that still listed that Mac's projects (claude-config#2112).
#
# The work MacBook's projects left the public CLAUDE.md for a file on that Mac only. A pull of the
# new payload replaces that Mac's CLAUDE.md, so the list it held would be gone from the file it was
# read from. It is never gone from the repository's history, and this writer is what brings it
# back from there, so the checks below care that it takes the RIGHT version (the newest one that
# still listed something, not the newest one), that it never writes over a file that is already
# there, that it says so when history holds nothing rather than writing an empty list, and that
# what it prints carries counts and paths, never the names it moved (they are work repositories).
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRITER="$DIR/lib/write-project-list-local.sh"
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

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.projlocal.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-write-project-list-local: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

# A stand in for ~/claude-config-sync: a repository whose payload/CLAUDE.md first lists MacTwo's
# projects, then, one commit later, keeps them in the local file instead, exactly the change
# #2112 made. Its own identity and no hooks, so nothing installed on this Mac judges its commits.
REPO="$TMPROOT/repo"
mkdir -p "$REPO/payload" "$TMPROOT/here/WorkOne" "$TMPROOT/here/WorkTwo" "$TMPROOT/here/Home"
printf '# fixture instructions\n' > "$TMPROOT/here/WorkOne/CLAUDE.md"
printf '# fixture instructions\n' > "$TMPROOT/here/WorkTwo/CLAUDE.md"
printf '# fixture instructions\n' > "$TMPROOT/here/Home/CLAUDE.md"
g() { git -C "$REPO" -c user.name=fixture -c user.email=fixture@example.invalid -c core.hooksPath=/dev/null -c commit.gpgsign=false "$@" >/dev/null 2>&1; }
g init -q

printf '%s\n' "## Projects" "" "On MacOne:" "- \`$TMPROOT/here/Home\`" "" "On MacTwo:" \
  "- \`$TMPROOT/here/WorkOne\`: the first one" "- \`$TMPROOT/here/WorkTwo\`" "" "## Writing Style" \
  > "$REPO/payload/CLAUDE.md"
g add payload/CLAUDE.md
g commit -q -m "list both Macs"
listed_sha="$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null)"

printf '%s\n' "## Projects" "" "On MacOne:" "- \`$TMPROOT/here/Home\`" "" "On MacTwo:" \
  "- Kept on that Mac only, in its own @projects.local.txt which the sync never carries." "" \
  "## Writing Style" > "$REPO/payload/CLAUDE.md"
g add payload/CLAUDE.md
g commit -q -m "move the second Mac's list to its own file"
CURRENT="$TMPROOT/current-CLAUDE.md"
cp "$REPO/payload/CLAUDE.md" "$CURRENT"

[ -n "$listed_sha" ] && [ "$(git -C "$REPO" rev-list --count HEAD 2>/dev/null)" = "2" ] \
  || { echo "FAIL: the fixture repository could not be built"; printf 'SUITE-RESULT passed=0 failed=1\n'; exit 1; }

write() { # write <host> <out> [repo]
  PROJECT_LIST_HOST="$1" PROJECT_LIST_LOCAL_FILE="$2" PROJECT_LIST_REPO="${3:-$REPO}" bash "$WRITER" 2>&1
}

# ---------------------------------------------------------------------------
# The ordinary case: the newest commit lists nothing for MacTwo, so the one before it is used.
# ---------------------------------------------------------------------------
OUT="$TMPROOT/home/projects.local.txt"
mkdir -p "$TMPROOT/home"
out_w="$(write MacTwo "$OUT")"; code_w=$?
[ "$code_w" -eq 0 ] \
  && check "the writer writes the local file from history" ok \
  || check "the writer writes the local file from history" "exit=$code_w out=$out_w"
grep -qF -- "- \`$TMPROOT/here/WorkOne\`: the first one" "$OUT" 2>/dev/null \
  && check "and carries each entry line as it was written, description included" ok \
  || check "and carries each entry line as it was written, description included" "file=$(cat "$OUT" 2>/dev/null)"
grep -qF -- "- \`$TMPROOT/here/WorkTwo\`" "$OUT" 2>/dev/null \
  && check "and every entry, not just the first" ok \
  || check "and every entry, not just the first" "file=$(cat "$OUT" 2>/dev/null)"
grep -q "Home" "$OUT" 2>/dev/null \
  && check "and never the other machine's entries" "found MacOne's entry" \
  || check "and never the other machine's entries" ok
grep -q "$listed_sha" <<< "$out_w" \
  && check "and says which commit it took them from" ok \
  || check "and says which commit it took them from" "out=$out_w"
grep -q '2 entries' <<< "$out_w" \
  && check "and how many" ok \
  || check "and how many" "out=$out_w"
grep -q 'WorkOne\|WorkTwo' <<< "$out_w" \
  && check "and never prints a name it moved" "out=$out_w" \
  || check "and never prints a name it moved" ok
ls "$TMPROOT/home" | grep -qv '^projects\.local\.txt$' \
  && check "and leaves no half written copy beside it" "dir=$(ls "$TMPROOT/home")" \
  || check "and leaves no half written copy beside it" ok

# What it wrote is what the check reads: the round trip passes with both entries counted.
out_rt="$(PROJECT_LIST_FILE="$CURRENT" PROJECT_LIST_LOCAL_FILE="$OUT" PROJECT_LIST_HOST=MacTwo bash "$CHECK" 2>&1)"; code_rt=$?
[ "$code_rt" -eq 0 ] && grep -q '2 project(s)' <<< "$out_rt" \
  && check "the file it writes is read by check-project-list.sh as this machine's list" ok \
  || check "the file it writes is read by check-project-list.sh as this machine's list" "exit=$code_rt out=$out_rt"

# ---------------------------------------------------------------------------
# Run twice: an existing file is never written over, whatever it holds.
# ---------------------------------------------------------------------------
printf '%s\n' "- \`$TMPROOT/here/EditedByHand\`" > "$OUT"
out_t="$(write MacTwo "$OUT")"; code_t=$?
[ "$code_t" -eq 0 ] \
  && check "a second run is not an error" ok \
  || check "a second run is not an error" "exit=$code_t out=$out_t"
grep -q 'EditedByHand' "$OUT" && ! grep -q 'WorkOne' "$OUT" \
  && check "and leaves the file already there exactly as it was" ok \
  || check "and leaves the file already there exactly as it was" "file=$(cat "$OUT")"
grep -q 'already' <<< "$out_t" \
  && check "and says it was already there" ok \
  || check "and says it was already there" "out=$out_t"

# ---------------------------------------------------------------------------
# Nothing to take: refused, and no file, so the check goes on saying the list is missing.
# ---------------------------------------------------------------------------
NONE="$TMPROOT/none/projects.local.txt"
mkdir -p "$TMPROOT/none"
out_n="$(write MacThree "$NONE")"; code_n=$?
[ "$code_n" -eq 3 ] \
  && check "a machine no version of the file ever listed is refused" ok \
  || check "a machine no version of the file ever listed is refused" "exit=$code_n out=$out_n"
[ ! -e "$NONE" ] \
  && check "and no empty file is written in its place" ok \
  || check "and no empty file is written in its place" "file=$(cat "$NONE")"

out_r="$(write MacTwo "$NONE" "$TMPROOT/no-such-repo")"; code_r=$?
[ "$code_r" -eq 2 ] \
  && check "a repository that is not there is refused" ok \
  || check "a repository that is not there is refused" "exit=$code_r out=$out_r"
grep -q 'no-such-repo' <<< "$out_r" \
  && check "and named" ok \
  || check "and named" "out=$out_r"
[ ! -e "$NONE" ] \
  && check "and nothing is written" ok \
  || check "and nothing is written" "file=$(cat "$NONE")"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
