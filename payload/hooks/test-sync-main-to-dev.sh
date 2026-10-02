#!/usr/bin/env bash
# WHOLE-HOOK tests for sync-main-to-dev.sh: feeds it real PostToolUse(Bash) payloads with a fake gh
# on PATH and asserts what it CALLED (the GitHub merges API, or nothing) and what it SAID.
#
# The rule it carries (Denys, trypennie, 2026-10-01): after a merge to main, merge main into dev so
# staging matches production. So the cases that matter are the ones where it must NOT act (another
# repo, a PR into dev, a PR that has not merged yet, a mere mention of a merge) as much as the one
# where it must, and every way the sync can fail must be said rather than swallowed.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/sync-main-to-dev.sh"

pass=0
fail=0

# Two real repos with real remotes, because mt_pr_view refuses an answer that is not about the repo
# the remote names. The fake gh never reaches the network (L2): it answers pr view from a file the
# case writes, and records every api call so a case can assert the merge was or was not requested.
FIXTURE="$(mktemp -d)"
mkdir -p "$FIXTURE/tp" "$FIXTURE/other" "$FIXTURE/bin"
( cd "$FIXTURE/tp" && git init -q && git remote add origin "https://github.com/Halo-lab-Trypennie/trypennie.git" )
( cd "$FIXTURE/other" && git init -q && git remote add origin "https://github.com/acme/widget.git" )
cat > "$FIXTURE/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"auth status"*) printf 'Logged in to github.com account danwright32 (keyring)\n' ;;
  *"auth token -u "*) printf 'tok\n' ;;
  *"pr view"*) [ -f "$FAKE_PR_JSON" ] && cat "$FAKE_PR_JSON" ;;
  api*)
    printf '%s\n' "$*" >> "$FAKE_API_LOG"
    case "${FAKE_MERGE_STATUS:-201}" in
      201) printf 'HTTP/2.0 201 Created\r\nContent-Type: application/json\r\n\r\n{"sha":"abc1234def"}\n' ;;
      204) printf 'HTTP/2.0 204 No Content\r\n\r\n' ;;
      409) printf 'HTTP/2.0 409 Conflict\r\n\r\n{"message":"Merge conflict"}\n'; exit 1 ;;
      500) printf 'HTTP/2.0 500 Internal Server Error\r\n\r\n{"message":"boom"}\n'; exit 1 ;;
    esac
    ;;
esac
SH
chmod +x "$FIXTURE/bin/gh"
export FAKE_PR_JSON="$FIXTURE/pr.json"
export FAKE_API_LOG="$FIXTURE/api.log"

holds() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
check() {  # $1 = description, then a command that must succeed
  local desc="$1"; shift
  if "$@"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $desc"; fi
}

pr() {  # $1 = slug, $2 = state, $3 = base
  printf '{"number":7,"url":"https://github.com/%s/pull/7","state":"%s","baseRefName":"%s"}' "$1" "$2" "$3" > "$FAKE_PR_JSON"
}

OUT=""
fire() {  # $1 = repo dir, $2 = command, [$3 = env assignment]
  local payload
  rm -f "$FAKE_API_LOG"
  payload="$(python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' "$2" "$1")"
  OUT="$(printf '%s' "$payload" | ( cd "$1" && env "PATH=$FIXTURE/bin:$PATH" ${3:+"$3"} "$HOOK" ) 2>/dev/null)"
}
called_merge() { [ -f "$FAKE_API_LOG" ] && holds "$(cat "$FAKE_API_LOG")" "repos/Halo-lab-Trypennie/trypennie/merges"; }
no_call() { [ ! -s "$FAKE_API_LOG" ]; }
quiet() { [ -z "$OUT" ]; }

TP=Halo-lab-Trypennie/trypennie

# --- The one case it exists for: a trypennie PR merged into main ---
pr "$TP" MERGED main; FAKE_MERGE_STATUS=201; export FAKE_MERGE_STATUS
fire "$FIXTURE/tp" "gh pr merge 7 --squash"
check "a trypennie merge to main requests the merges API" called_merge
check "it asks to merge main INTO dev, never the reverse" holds "$(cat "$FAKE_API_LOG" 2>/dev/null)" "base=dev"
check "with main as the head" holds "$(cat "$FAKE_API_LOG" 2>/dev/null)" "head=main"
check "and says it merged" holds "$OUT" "merged main into dev"
check "naming the commit it made" holds "$OUT" "abc1234"

# The same merge named with -R from a folder that is not trypennie at all, which is the shape a
# session outside any trypennie checkout produces.
fire "$FIXTURE/other" "gh pr merge 7 -R Halo-lab-Trypennie/trypennie --squash"
check "a merge named with -R from another folder still syncs" called_merge
fire "$FIXTURE/other" "gh pr merge 7 -R halo-lab-trypennie/TRYPENNIE --squash"
check "the slug is matched case insensitively" called_merge

# --- The outcomes it must say apart ---
FAKE_MERGE_STATUS=204
fire "$FIXTURE/tp" "gh pr merge 7 --squash"
check "already level says so" holds "$OUT" "already"
FAKE_MERGE_STATUS=409
fire "$FIXTURE/tp" "gh pr merge 7 --squash"
check "a conflict is named as a conflict" holds "$OUT" "CONFLICT"
check "and is not reported as merged" eval '! holds "$OUT" "merged main into dev"'
FAKE_MERGE_STATUS=500
fire "$FIXTURE/tp" "gh pr merge 7 --squash"
check "any other failure is said, not swallowed" holds "$OUT" "FAILED"
check "with what GitHub answered" holds "$OUT" "500"
FAKE_MERGE_STATUS=201

# --- Where it must not act ---
pr "acme/widget" MERGED main
fire "$FIXTURE/other" "gh pr merge 7 --squash"
check "another repo makes no call" no_call
check "and says nothing" quiet

pr "$TP" MERGED dev
fire "$FIXTURE/tp" "gh pr merge 7 --squash"
check "a trypennie PR into dev makes no call" no_call
check "and says nothing" quiet

pr "$TP" OPEN main
fire "$FIXTURE/tp" "gh pr merge 7 --squash --auto"
check "a PR that has not merged yet makes no call" no_call
check "but says dev still needs syncing once it lands" holds "$OUT" "not merged yet"

rm -f "$FAKE_PR_JSON"
fire "$FIXTURE/tp" "gh pr merge 7 --squash"
check "an unreadable PR makes no call" no_call
check "and says the sync did not happen" holds "$OUT" "did NOT"

pr "$TP" MERGED main
fire "$FIXTURE/tp" 'echo "then gh pr merge 7"'
check "a mere mention of a merge makes no call" no_call
check "and says nothing" quiet
fire "$FIXTURE/tp" "gh pr view 7"
check "viewing a PR makes no call" no_call
fire "$FIXTURE/tp" "SKIP_MAIN_DEV_SYNC=1 gh pr merge 7"
check "the documented override makes no call" no_call

# Positive control for the list file: trypennie is in the SHIPPED list, so the cases above exercised
# the real registry rather than a fixture copy of it.
check "trypennie is listed in the shipped repo list" grep -qix "$TP" "$DIR/main-to-dev-repos.txt"

rm -rf "$FIXTURE"
echo
echo "passed: $pass   failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
