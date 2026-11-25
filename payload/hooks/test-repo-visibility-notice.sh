#!/usr/bin/env bash
# repo-visibility-notice.sh: a session is told at its start when a repository's visibility on
# GitHub is not what the repository says it is meant to be (claude-config#3582).
#
# On 2026-11-24 this repository was private for some hours and nobody was told. Its workflow is
# sized for a public repository's free 4 core runners, and the work names publish gate judges only
# text posted to a public repository, so the cost was suites running past their limits on billed 2
# core runners and posted text nothing judged. This suite holds:
#   1. A repository that states no expectation is never asked about: no call, no line.
#   2. A repository that is what it says it is meant to be costs one call and says nothing.
#   3. One that is not gets one notice naming the repository, what it is, what that costs and the
#      command to run before it turns public again.
#   4. When it cannot tell (gh fails, answers something else, outlasts its bound, the expectation
#      or the remote cannot be read) it says it could not tell, and never that all is well.
#   5. This repository states its own expectation, the workflow's comment points at it, and the
#      hook is wired to SessionStart.
#
# gh is a stand in on the PATH, never the network. Every name here is invented.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/repo-visibility-notice.sh"
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

for tool in git python3 jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "FAIL: $tool is not on PATH, so this suite cannot run."
    printf 'SUITE-RESULT passed=0 failed=1\n'
    exit 1
  fi
done
if [ ! -f "$HOOK" ]; then
  echo "FAIL: there is no repo-visibility-notice.sh beside this suite at $HERE, so nobody is told when this repository stops being public (claude-config#3582)."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

_tmp="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "${_tmp%/}/repo-visibility.XXXXXX")" || exit 1
case "${WORK%/}" in ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$WORK'" >&2; exit 2 ;; esac
trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"; mkdir -p "$BIN"
CALLS="$WORK/gh-calls"; : > "$CALLS"
ANSWER="$WORK/answer"

# A fake gh: it prints what the answer file holds, or fails, or sleeps first, as the case set it.
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_CALLS"
[ -f "$FAKE_ANSWER.sleep" ] && sleep "$(cat "$FAKE_ANSWER.sleep")"
if [ -f "$FAKE_ANSWER.fail" ]; then cat "$FAKE_ANSWER.fail" >&2; exit 1; fi
cat "$FAKE_ANSWER"
SH
chmod +x "$BIN/gh"

repo(){   # $1 = folder name, $2 = origin address or "", $3 = the expectation file's text or ""
  R="$WORK/$1"
  mkdir -p "$R/sub/folder"
  git -C "$R" init -q
  [ -z "$2" ] || git -C "$R" remote add origin "$2"
  if [ -n "$3" ]; then mkdir -p "$R/.github"; printf '%s\n' "$3" > "$R/.github/expected-visibility"; fi
}
answer(){ rm -f "$ANSWER" "$ANSWER.fail" "$ANSWER.sleep"; printf '%s\n' "$1" > "$ANSWER"; }
start(){   # $1 = the cwd the session starts in; output in out, exit code in rc
  : > "$CALLS"
  out="$(jq -nc --arg d "$1" '{hook_event_name:"SessionStart",session_id:"s1",source:"startup",cwd:$d}' \
    | env HOOK_TESTS_RUNNING=1 PATH="$BIN:$PATH" FAKE_CALLS="$CALLS" FAKE_ANSWER="$ANSWER" \
        REPO_VISIBILITY_BOUND_SECONDS="${BOUND:-}" bash "$HOOK" 2>&1)"; rc=$?
}
asked(){ wc -l < "$CALLS" | tr -d ' '; }

# ================================================================ 1. no expectation, no call
repo plain "https://github.com/danwright-test/plain.git" ""
answer PRIVATE
start "$R"
check "a repository that states no expectation gets no line: $out" [ -z "$out" ]
check "and exits 0: rc=$rc" [ "$rc" -eq 0 ]
check "and GitHub is never asked about it: $(asked)" [ "$(asked)" = "0" ]
start "$WORK"
check "a folder that is no repository gets no line and no call: $out" [ -z "$out" ]
check "and asked nothing: $(asked)" [ "$(asked)" = "0" ]

# ================================================================ 2. as expected says nothing
repo notes "https://github.com/danwright-test/notes.git" "# what it is meant to be
public"
answer PUBLIC
start "$R"
check "a repository that is public as it says it is meant to be gets no line: $out" [ -z "$out" ]
check "and exits 0: rc=$rc" [ "$rc" -eq 0 ]
check "and that cost exactly one call: $(asked)" [ "$(asked)" = "1" ]
check "the call is a read of the repository's visibility: $(cat "$CALLS")" has "$(cat "$CALLS")" "repo view danwright-test/notes --json visibility"

# ================================================================ 3. not as expected
answer PRIVATE
start "$R"
check "a repository meant to be public that is private gets a notice, exit 0: rc=$rc" [ "$rc" -eq 0 ]
check "it names the repository: $out" has "$out" "danwright-test/notes"
check "it says it is private: $out" has "$out" "PRIVATE"
check "it says what it is meant to be: $out" has "$out" "says public"
check "it says the runners are 2 core: $out" has "$out" "2 core"
check "it says their minutes are billed: $out" has "$out" "bills"
check "it says the publish gate does not judge text posted to it: $out" has "$out" "publish gate"
check "it names the command to run before it turns public again: $out" has "$out" "lib/posted-text-scan.py danwright-test/notes --since"
check "the command it names is shipped beside the hook" [ -f "$HERE/lib/posted-text-scan.py" ]
check "it says to tell Dan: $out" has "$out" "Tell Dan"
check "it is one notice, said once: $(printf '%s\n' "$out" | grep -c 'Repository visibility')" [ "$(printf '%s\n' "$out" | grep -c 'Repository visibility')" = "1" ]
start "$R/sub/folder"
check "a session started in a folder inside the repository is told the same: $out" has "$out" "PRIVATE"
answer INTERNAL
start "$R"
check "internal is not public either: $out" has "$out" "INTERNAL"
answer private
start "$R"
check "the answer is read whatever its letter case: $out" has "$out" "PRIVATE"
repo sshform "git@github.com:danwright-test/notes.git" "public"
answer PRIVATE
start "$R"
check "an origin written the ssh way is read: $out" has "$out" "danwright-test/notes is PRIVATE"
# A checkout behind its origin may not hold the file yet (this repository's primary checkout was 474
# commits behind main the night this was written). The copy on origin's default branch, as last
# fetched, is read then, which asks the network nothing.
repo behind "https://github.com/danwright-test/notes.git" ""
commit(){ git -C "$R" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q "$@"; }
commit --allow-empty -m "before the file"
mkdir -p "$R/.github"; printf 'public\n' > "$R/.github/expected-visibility"
git -C "$R" add .github/expected-visibility
commit -m "state what it is meant to be"
git -C "$R" update-ref refs/remotes/origin/main HEAD
git -C "$R" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
git -C "$R" reset -q --hard HEAD~1
check "(the fixture) the checkout itself does not hold the file" [ ! -e "$R/.github/expected-visibility" ]
answer PRIVATE
start "$R"
check "a checkout that does not hold the file yet is judged by origin's copy of it: $out" has "$out" "danwright-test/notes is PRIVATE"
answer PUBLIC
start "$R"
check "and says nothing when GitHub agrees with origin's copy: $out" [ -z "$out" ]
repo quiet "https://github.com/danwright-test/quiet" "private"
answer PUBLIC
start "$R"
check "a repository meant to be private that is public gets a notice: $out" has "$out" "danwright-test/quiet is PUBLIC"
check "which says anyone can read it: $out" has "$out" "anyone"
check "and does not talk about runners, which is the other case's cost: $out" lacks "$out" "2 core"
answer PRIVATE
start "$R"
check "and one that is private as meant gets no line: $out" [ -z "$out" ]

# ================================================================ 4. it says when it cannot tell
cannot(){   # $1 = what the case is
  check "$1: it says it could not tell: $out" has "$out" "could not tell"
  check "$1: exit 0, a notice never stops a session: rc=$rc" [ "$rc" -eq 0 ]
  check "$1: it claims nothing about what the repository is: $out" lacks "$out" "is PRIVATE"
  check "$1: and nothing about its cost: $out" lacks "$out" "2 core"
}
R="$WORK/notes"
answer PUBLIC
echo "gh: HTTP 503: Service Unavailable" > "$ANSWER.fail"
start "$R"
cannot "gh fails"
check "gh fails: it gives gh's reason: $out" has "$out" "503"
answer "something else"
start "$R"
cannot "an answer that is no visibility"
answer ""
start "$R"
cannot "an empty answer"
answer PUBLIC
echo 30 > "$ANSWER.sleep"
started=$SECONDS
BOUND=1 start "$R"
cannot "gh outlasts its bound"
check "gh outlasts its bound: the hook ended near the bound, not at gh's end: $((SECONDS - started))s" [ "$((SECONDS - started))" -lt 15 ]
answer PUBLIC
repo odd "https://github.com/danwright-test/odd.git" "sometimes"
start "$R"
cannot "an expectation that is none of the three"
check "an expectation that is none of the three: GitHub is not asked: $(asked)" [ "$(asked)" = "0" ]
# A file that is there and cannot be read is said as that, never as a file holding a bad value. A
# user who can read any file (root) cannot set this state up, and says so instead of failing.
repo locked "https://github.com/danwright-test/locked.git" "public"
chmod 000 "$R/.github/expected-visibility"
if cat "$R/.github/expected-visibility" >/dev/null 2>&1; then
  echo "note: this user can read a file with no read permission, so the unreadable expectation file case was not measured here."
else
  start "$R"
  cannot "an expectation file that cannot be read"
  check "an expectation file that cannot be read: it says the file could not be read: $out" has "$out" "is there but could not be read"
  check "an expectation file that cannot be read: GitHub is not asked: $(asked)" [ "$(asked)" = "0" ]
fi
chmod 644 "$R/.github/expected-visibility"
repo elsewhere "https://example.com/danwright-test/notes.git" "public"
start "$R"
cannot "an origin that is not GitHub"
repo noremote "" "public"
start "$R"
cannot "no origin at all"
# The longer bound is a test setting: a real session's environment cannot hold the hook past its timeout.
answer PUBLIC
: > "$CALLS"
out="$(jq -nc --arg d "$WORK/notes" '{hook_event_name:"SessionStart",cwd:$d}' \
  | env HOOK_TESTS_RUNNING=0 PATH="$BIN:$PATH" FAKE_CALLS="$CALLS" FAKE_ANSWER="$ANSWER" REPO_VISIBILITY_BOUND_SECONDS=nonsense bash "$HOOK" 2>&1)"; rc=$?
check "outside a test run a bound named in the environment is not read: rc=$rc $out" [ -z "$out" ]
# A payload that cannot be read falls back to the folder the hook runs in.
answer PRIVATE
out="$(cd "$WORK/notes" && printf 'not json' | env HOOK_TESTS_RUNNING=1 PATH="$BIN:$PATH" FAKE_CALLS="$CALLS" FAKE_ANSWER="$ANSWER" bash "$HOOK" 2>&1)"; rc=$?
check "a payload that cannot be read still judges the folder the hook runs in: $out" has "$out" "PRIVATE"

# ================================================================ 5. this repository
# The repository's own files are judged where the repository is, a checkout or CI. Installed under
# ~/.claude there is no .github folder beside the hooks, and saying so is not a failure.
if ROOT="$(bash "$HERE/lib/checkout-root.sh" "$HERE/.." 2>/dev/null)" && [ -n "$ROOT" ]; then
  EXPECT="$ROOT/.github/expected-visibility"
  check "this repository states what it is meant to be" [ -f "$EXPECT" ]
  check "and it is meant to be public" [ "$(awk '!/^[[:space:]]*#/ && NF && !seen { seen = 1; print $1 }' "$EXPECT" 2>/dev/null)" = "public" ]
  check "the workflow's comment about free runners points at that file, the assumption's one home" \
    grep -q "expected-visibility" "$ROOT/.github/workflows/tests.yml"
else
  echo "note: this copy of the suite is not in a checkout, so the repository's own expectation file and workflow comment were not judged here; the checkout's run and CI judge them."
fi
# The hooks block, by the one lookup: settings.hooks.json in the checkout, settings.json installed.
. "$HERE/lib/settings-file.sh" 2>/dev/null || hook_settings_file() { return 1; }
SETTINGS="$(hook_settings_file "$HERE/..")" || SETTINGS=""
check "the file holding the hooks block is beside the hooks: ${SETTINGS:-none found}" [ -n "$SETTINGS" ]
holds(){ jq -e "$1" "$SETTINGS" >/dev/null 2>&1; }   # $1 = a jq test of the hooks block
check "the hook is wired to SessionStart" \
  holds '[.hooks.SessionStart[].hooks[].command] | any(endswith("/hooks/repo-visibility-notice.sh"))'
check "once, with a timeout longer than its own bound" \
  holds '[.hooks.SessionStart[].hooks[] | select(.command | endswith("/hooks/repo-visibility-notice.sh")) | .timeout] | length == 1 and all(. >= 10)'
check "and to no other event, where it would be a network call on every prompt or tool call" \
  holds '[.hooks | to_entries[] | select(.key != "SessionStart") | .value[].hooks[].command] | all(endswith("/hooks/repo-visibility-notice.sh") | not)'
check "(control) the same test of the hooks block can fail: a hook that is not there is not found" \
  bash -c '[ -n "$1" ] && ! jq -e "[.hooks.SessionStart[].hooks[].command] | any(endswith(\"/hooks/no-such-hook.sh\"))" "$1" >/dev/null 2>&1' _ "$SETTINGS"

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
