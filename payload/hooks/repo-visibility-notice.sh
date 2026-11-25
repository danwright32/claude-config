#!/usr/bin/env bash
#
# repo-visibility-notice.sh
# Claude Code SessionStart hook (every source: startup, resume, /clear, compaction).
#
# Says, once at a session's start, when the repository the session is in is not as visible on
# GitHub as the repository itself says it is meant to be (claude-config#3582).
#
# WHY. On 2026-11-24 the config repository was private for some hours and nobody was told. Two
# things rest on its being public, and neither says so when it stops:
#   * .github/workflows/tests.yml is sized for a public repository's runners, which are 4 cores and
#     free. A private repository gets 2 core runners and is billed for their minutes, so suites
#     sized for 4 cores ran past their limits that afternoon and the account's minutes ran out.
#   * The work names publish gate (work_names_publish_gate.py) judges text posted to a PUBLIC
#     repository and lets a private one through unread, so text posted meanwhile was judged by
#     nothing, and was public, unjudged, the moment the repository turned public again.
#
# THE EXPECTATION HAS ONE HOME: the file .github/expected-visibility at the repository's root, whose
# first line that is not a comment is public, private or internal. A checkout that does not hold it
# yet, being behind its origin, is judged by the copy on origin's default branch as last fetched. A
# repository with no such file in either place is never asked about, so this costs every other
# project no call and no line.
#
# WHAT IT SAYS. Nothing when GitHub agrees with the file (an alert posts only when there is
# something to look into). One notice when it does not, naming the repository, what it is, what
# that costs, and for a repository meant to be public the command to run before it turns public
# again (lib/posted-text-scan.py). And one line when it COULD NOT TELL (gh failed, answered
# something that is no visibility, or outlasted its bound; the file or the origin could not be
# read), because silence here means checked and as expected, never unchecked (L98, L11).
#
# WHAT IT COSTS. One `gh repo view <owner/name> --json visibility` per session start, in a
# repository that carries the file, and nothing anywhere else. Measured 2026-11-24 on the personal
# MacBook, the hook whole: ten runs with the file took 0.32 to 0.54 seconds, after a first run of
# 1.2; five in a repository with no file took 0.06 to 0.07, and three outside any repository 0.03.
# Never per prompt: it is wired to
# SessionStart only, which test-repo-visibility-notice.sh holds. The call is bounded
# (BOUND_SECONDS, a setting, not a measurement) well inside the hook's timeout in
# settings.hooks.json, and a call that outlasts it is said as one that could not tell.
#
# REPO_VISIBILITY_BOUND_SECONDS replaces the bound, for the suite, and is read only under
# HOOK_TESTS_RUNNING=1, so nothing in a real session's environment can hold the hook past its
# timeout.
#
# stdout on exit 0 is added to the session's context. It never blocks: every path exits 0.

BOUND_SECONDS=4
NAME="Repository visibility"

input="$(cat 2>/dev/null || true)"
# Its own folder by parameter expansion, set once and plainly, so every gate that reads this script
# can work out the library it sources. The same folder written in full is only for the notice.
case "${BASH_SOURCE[0]}" in */*) HOOK_DIR="${BASH_SOURCE[0]%/*}" ;; *) HOOK_DIR=. ;; esac
HOOK_SHOWN="$(cd "$HOOK_DIR" 2>/dev/null && pwd)" || HOOK_SHOWN="$HOOK_DIR"

cwd="$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace"))
    print(d.get("cwd") or "" if isinstance(d, dict) else "")
except Exception:
    print("")
' 2>/dev/null)"
cwd="${cwd:-${CLAUDE_PROJECT_DIR:-$PWD}}"

# No repository, or one that states no expectation: nothing to check, and nothing is asked.
top="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || exit 0

cannot_tell() {   # $1 = what it was about, $2 = why
  printf '[%s] could not tell whether %s: %s. Nothing was checked, so this is not a statement that it is.\n' "$NAME" "$1" "$2"
  exit 0
}

expect_file="$top/.github/expected-visibility"
if [ -f "$expect_file" ]; then
  # A file that is there and cannot be read is its own cause, said as that and not as a bad value.
  expect_text="$(cat "$expect_file" 2>/dev/null)" \
    || cannot_tell "this repository is as visible as it is meant to be" "its .github/expected-visibility is there but could not be read"
else
  # A checkout behind its origin may not hold the file yet: this repository's primary checkout was
  # 474 commits behind main on the night this was written, and a session started there is the one
  # that most needs telling. So the copy on origin's default branch, as last fetched, is read
  # then. That is a local read, with no network in it.
  expect_text=""
  for ref in refs/remotes/origin/HEAD refs/remotes/origin/main refs/remotes/origin/master; do
    expect_text="$(git -C "$top" show "$ref:.github/expected-visibility" 2>/dev/null)" && break
    expect_text=""
  done
  [ -n "$expect_text" ] || exit 0
fi

# The first line that is not a comment or blank, its first word. awk reads to the end and never
# leaves early, so nothing upstream of it is cut off mid write (test-pipefail-shortcircuit.sh).
expected="$(printf '%s\n' "$expect_text" | awk '!/^[[:space:]]*#/ && NF && !seen { seen = 1; print tolower($1) }')"
case "$expected" in
  public|private|internal) ;;
  *) cannot_tell "this repository is as visible as it is meant to be" \
       "the first line of its .github/expected-visibility that is not a comment is not public, private or internal" ;;
esac

origin="$(git -C "$top" remote get-url origin 2>/dev/null)" \
  || cannot_tell "this repository is still $expected, as its .github/expected-visibility says" "it has no origin remote to ask GitHub about"
slug=""
case "$origin" in
  https://github.com/*) slug="${origin#https://github.com/}" ;;
  ssh://git@github.com/*) slug="${origin#ssh://git@github.com/}" ;;
  git@github.com:*) slug="${origin#git@github.com:}" ;;
esac
slug="${slug%/}"; slug="${slug%.git}"
case "$slug" in
  */*/*|""|/*|*/|*[!A-Za-z0-9_./-]*) slug="" ;;
  */*) ;;
  *) slug="" ;;
esac
[ -n "$slug" ] \
  || cannot_tell "this repository is still $expected, as its .github/expected-visibility says" "its origin remote is not a GitHub repository address this can read"

bound="$BOUND_SECONDS"
if [ "${HOOK_TESTS_RUNNING:-}" = "1" ] && [ -n "${REPO_VISIBILITY_BOUND_SECONDS:-}" ]; then
  bound="$REPO_VISIBILITY_BOUND_SECONDS"
fi
still="$slug is still $expected, as its .github/expected-visibility says"
# The stand in answers 125, the library's own code for having run nothing.
. "$HOOK_DIR/lib/bounded-run.sh" 2>/dev/null || bounded_run() {
  BOUNDED_RC=125; BOUNDED_OUT="lib/bounded-run.sh is missing beside this hook"; }
command -v gh >/dev/null 2>&1 || cannot_tell "$still" "gh is not on PATH"
bounded_run "$bound" gh repo view "$slug" --json visibility --jq .visibility
case "$BOUNDED_RC" in
  0) ;;
  124) cannot_tell "$still" "gh did not answer within $bound seconds" ;;
  *) cannot_tell "$still" "gh could not read it (exit $BOUNDED_RC): $(printf '%s' "$BOUNDED_OUT" | tr '\n' ' ' | cut -c1-200)" ;;
esac
actual="$(printf '%s' "$BOUNDED_OUT" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
case "$actual" in
  public|private|internal) ;;
  *) cannot_tell "$still" "gh answered with something that is not a visibility" ;;
esac

# As expected: nothing to look into, so nothing is said.
[ "$actual" != "$expected" ] || exit 0

shown="$(printf '%s' "$actual" | tr '[:lower:]' '[:upper:]')"
if [ "$expected" = "public" ]; then
  printf '[%s] %s is %s on GitHub, and its .github/expected-visibility says public. Tell Dan now, before anything else. While it is not public: GitHub Actions gives it 2 core runners and bills their minutes, where a public repository gets 4 cores free, so suites sized for 4 cores run past their limits and the account'"'"'s minutes run down; and the work names publish gate does not judge text posted to it, so a work name posted now is public, unjudged, the moment it turns public again. Before it does, run `python3 %s/lib/posted-text-scan.py %s --since <when it stopped being public, as an ISO time with its zone>` and act on what it reports (claude-config#3582).\n' \
    "$NAME" "$slug" "$shown" "$HOOK_SHOWN" "$slug"
elif [ "$actual" = "public" ]; then
  printf '[%s] %s is PUBLIC on GitHub, and its .github/expected-visibility says %s. Tell Dan now, before anything else: every file, commit, issue and comment in it can be read by anyone (claude-config#3582).\n' \
    "$NAME" "$slug" "$expected"
else
  printf '[%s] %s is %s on GitHub, and its .github/expected-visibility says %s. Tell Dan: who can read it is not who it was meant for (claude-config#3582).\n' \
    "$NAME" "$slug" "$shown" "$expected"
fi
exit 0
