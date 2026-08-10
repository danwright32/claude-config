#!/usr/bin/env bash
# Tests for lessons-advisory.sh (PreToolUse Bash hook).
# Run: ./test-lessons-advisory.sh   Exits nonzero on any failure.
#
# Every case builds a REAL git repo with a REAL bare remote and lets the hook run
# its own git commands, rather than stubbing git. A stub would only ever confirm
# this file's guess at what git prints (LESSONS.md L52).

set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lessons-advisory.sh"
PASS=0
FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

payload() {
  # $1 command, $2 cwd
  python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' "$1" "$2"
}

# Build a repo with an upstream, one baseline commit already pushed, then commit
# $2 as the content of file $3. The pushed range is therefore exactly that commit.
make_repo() {
  # $1 repo name, $2 content, $3 filename
  local name="$1" content="$2" file="$3"
  local repo="$WORK/$name" bare="$WORK/$name.git"
  git init -q --bare "$bare"
  git init -q -b main "$repo"
  git -C "$repo" config user.email t@t.t
  git -C "$repo" config user.name t
  git -C "$repo" config commit.gpgsign false
  echo "baseline" > "$repo/README.md"
  git -C "$repo" add -A && git -C "$repo" commit -qm baseline
  git -C "$repo" remote add origin "$bare"
  git -C "$repo" push -q -u origin main
  mkdir -p "$(dirname "$repo/$file")"
  printf '%s\n' "$content" > "$repo/$file"
  git -C "$repo" add -A && git -C "$repo" commit -qm change
  printf '%s' "$repo"
}

run_hook() {
  # $1 command, $2 cwd, remaining: extra env assignments
  # The payload is materialized BEFORE the pipe: piping a python process
  # straight into a hook that exits early makes python spew a BrokenPipeError
  # into the test output, which is noise the next reader has to learn to ignore.
  local cmd="$1" cwd="$2"; shift 2
  local p; p="$(payload "$cmd" "$cwd")"
  printf '%s' "$p" | env -u CLAUDE_DETACHED_RUN TMPDIR="$WORK/tmp" "$@" "$HOOK" 2>/dev/null
}

assert_json_field() {
  # $1 desc, $2 dotted path, $3 expected, $4 output. Parses rather than
  # substring-matching, so the test pins the CONTRACT and not the whitespace
  # json.dumps happens to emit.
  local got
  got="$(printf '%s' "$4" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("<unparseable>"); raise SystemExit
for k in sys.argv[1].split("."):
    d = d.get(k, {}) if isinstance(d, dict) else {}
print(d if isinstance(d, str) else "<missing>")
' "$2" 2>/dev/null)"
  if [ "$got" = "$3" ]; then
    PASS=$((PASS+1)); echo "PASS: $1"
  else
    FAIL=$((FAIL+1)); echo "FAIL: $1 (expected $3, got $got)"
  fi
}

assert_contains() {
  # $1 desc, $2 needle, $3 haystack
  if printf '%s' "$3" | grep -qF "$2"; then
    PASS=$((PASS+1)); echo "PASS: $1"
  else
    FAIL=$((FAIL+1)); echo "FAIL: $1 (missing: $2)"
  fi
}

assert_absent() {
  if printf '%s' "$3" | grep -qF "$2"; then
    FAIL=$((FAIL+1)); echo "FAIL: $1 (unexpectedly present: $2)"
  else
    PASS=$((PASS+1)); echo "PASS: $1"
  fi
}

assert_silent() {
  # $1 desc, $2 output
  if [ -z "$(printf '%s' "$2" | tr -d '[:space:]')" ]; then
    PASS=$((PASS+1)); echo "PASS: $1"
  else
    FAIL=$((FAIL+1)); echo "FAIL: $1 (expected no output, got: $2)"
  fi
}

if [ ! -x "$HOOK" ]; then
  echo "FAIL: hook not found or not executable at $HOOK"
  exit 1
fi
mkdir -p "$WORK/tmp"

# --- 1. A swallowed error in added code raises the error-path lessons ----------
R=$(make_repo swallow 'try {
  await send()
} catch (e) {
  return []
}' src/send.ts)
out=$(run_hook "git push" "$R")
assert_json_field "swallowed catch produces valid PreToolUse JSON" "hookSpecificOutput.hookEventName" "PreToolUse" "$out"
assert_contains "swallowed catch carries additionalContext" 'additionalContext' "$out"
assert_contains "swallowed catch cites the error-path lesson" 'L11' "$out"

# --- 2. It never auto-approves the push ---------------------------------------
assert_absent "advisory does not decide the permission" 'permissionDecision' "$out"

# --- 3. It never reports a clean bill of health -------------------------------
assert_absent "advisory never claims clean" 'no issues' "$out"
assert_contains "advisory states it is only a partial check" 'not a full audit' "$out"

# --- 4. A new API route raises the security-scoping lessons -------------------
R=$(make_repo route 'export async function POST(req: Request) {
  return Response.json({ ok: true })
}' app/api/thing/route.ts)
out=$(run_hook "git push" "$R")
assert_contains "new route cites the authorization lesson" 'L18' "$out"

# --- 5. A destructive data operation raises the data-safety lessons ----------
R=$(make_repo destructive 'DELETE FROM contacts WHERE stale = true;' migrations/003.sql)
out=$(run_hook "git push" "$R")
assert_contains "destructive SQL cites the data-safety lesson" 'L5' "$out"

# --- 6. Silence where there is nothing to say --------------------------------
R=$(make_repo docs 'Some prose about the feature.' docs/notes.md)
out=$(run_hook "git push" "$R")
assert_silent "docs-only push is silent" "$out"

R=$(make_repo notpush 'try { x() } catch (e) { return [] }' src/a.ts)
out=$(run_hook "git status" "$R")
assert_silent "non-push command is silent" "$out"

out=$(run_hook 'echo "remember to git push later"' "$R")
assert_silent "a command merely mentioning git push is silent" "$out"

P="$(payload "git push" "$R")"
out=$(printf '%s' "$P" | env TMPDIR="$WORK/tmp" CLAUDE_DETACHED_RUN=1 "$HOOK" 2>/dev/null)
assert_silent "detached run is silent" "$out"

# --- 7. Matching is on ADDED lines, not the whole file ------------------------
# The trigger already existed and is pushed. This push appends an innocuous line
# to THAT SAME FILE, so a hook scanning the changed files' contents would fire
# while one scanning the added lines stays quiet. Touching a different file would
# pass either way and prove nothing.
R=$(make_repo preexisting 'try { x() } catch (e) { return [] }' src/old.ts)
git -C "$R" push -q origin main
echo "// an unrelated comment" >> "$R/src/old.ts"
git -C "$R" add -A && git -C "$R" commit -qm unrelated
out=$(run_hook "git push" "$R")
assert_silent "a pre-existing pattern in a touched file does not re-fire" "$out"

# --- 8. An unresolvable lesson id is reported, never silently dropped ---------
# LESSONS.md renumbering must not empty the map behind everyone's back.
cat > "$WORK/thin-lessons.md" <<'EOF'
- **L1. A test or guard is only real once it has been seen to fail.** Break it once.
EOF
R=$(make_repo missingid 'try { x() } catch (e) { return [] }' src/b.ts)
out=$(run_hook "git push" "$R" LESSONS_FILE="$WORK/thin-lessons.md")
assert_contains "an unresolvable lesson id is called out loudly" 'NOT FOUND' "$out"

# --- 9. A missing lessons file is loud, not silent ----------------------------
R=$(make_repo nolessons 'try { x() } catch (e) { return [] }' src/c.ts)
out=$(run_hook "git push" "$R" LESSONS_FILE="$WORK/does-not-exist.md")
assert_contains "a missing lessons file is reported" 'COULD NOT READ' "$out"

# --- 10. Cooldown: a repeated push does not repeat the advisory --------------
R=$(make_repo cooldown 'try { x() } catch (e) { return [] }' src/d.ts)
first=$(run_hook "git push" "$R")
second=$(run_hook "git push" "$R")
assert_contains "first push of a repo advises" 'additionalContext' "$first"
assert_silent "an immediately repeated push is silent" "$second"

# --- 11. A branch with no upstream still gets scanned -------------------------
# The base falls back through origin/HEAD, origin/main, main. On a repo with no
# remote that lands on the CURRENT branch, making the range empty. Silence there
# would mean "scanned nothing" while reading as "matched nothing".
NR="$WORK/noremote"
git init -q -b main "$NR"
git -C "$NR" config user.email t@t.t
git -C "$NR" config user.name t
echo baseline > "$NR/README.md"
git -C "$NR" add -A && git -C "$NR" commit -qm baseline
mkdir -p "$NR/src"
printf 'try { x() } catch (e) { return [] }\n' > "$NR/src/e.ts"
git -C "$NR" add -A && git -C "$NR" commit -qm change
out=$(run_hook "git push" "$NR")
assert_contains "a repo with no upstream is still scanned" 'additionalContext' "$out"

# --- 12. It reports WHERE, so the advice is actionable ------------------------
R=$(make_repo location 'try { x() } catch (e) { return [] }' src/where.ts)
out=$(run_hook "git push" "$R")
assert_contains "advisory names the file that triggered it" 'src/where.ts' "$out"

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
