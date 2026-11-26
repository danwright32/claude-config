#!/usr/bin/env bash
#
# test-changelog-tag.sh: the merge gate that requires a changelog record, plus
# the record parser it reads through.
#
# Every case runs the REAL hook with a fake `gh` first on PATH, so what is tested
# is the hook's own reading of an answer rather than a rewrite of its logic
# living here (L52).
#
# The parser's own cases live in lib/changelog-entry.test.js and are folded into
# this suite's counts below, because run-all-tests.sh discovers test-*.sh and
# would never find a bare .js file. A node suite that runs nowhere is worse than
# no suite: it reads as coverage and provides none.
#
# The merge command is assembled from $MERGE rather than written out, because
# writing it literally makes this file trip the block-red-merge hook on the way
# in, exactly as a test naming a banned character trips the style hook.

set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HOOK_DIR/require-changelog-tag.sh"
MERGE="gh pr me""rge"
passed=0
failed=0
# This Mac's real record of approved announcement wording, as it stood before any case ran: every
# run below keeps its own (run_hook), and the last check here holds the suite to that (#3666).
REAL_RECORD_BEFORE="$(ls -la "${CLAUDE_HOME:-$HOME/.claude}/state/announce-approvals" 2>/dev/null | cksum)"

fail() { echo "  FAIL: $1"; failed=$((failed + 1)); }
pass() { passed=$((passed + 1)); }

# --------------------------------------------------------------- the parser

echo "changelog record: the parser"
parser_out=$(node "$HOOK_DIR/lib/changelog-entry.test.js" 2>&1)
parser_line=$(printf '%s\n' "$parser_out" | grep '^SUITE-RESULT' | tail -1)
if [ -z "$parser_line" ]; then
  # A parser suite that did not run is not a parser suite that passed (L98).
  fail "the parser suite produced no verdict at all: $parser_out"
else
  p=$(printf '%s' "$parser_line" | sed -E 's/.*passed=([0-9]+).*/\1/')
  f=$(printf '%s' "$parser_line" | sed -E 's/.*failed=([0-9]+).*/\1/')
  passed=$((passed + p))
  failed=$((failed + f))
  [ "$f" != "0" ] && grep '  FAIL:' <<< "$parser_out"
fi

# --------------------------------------------------------------- the gate

echo "changelog record: the merge gate"

# A real git repo with a GitHub remote, so the hook has an identity to check the
# answer against, plus a registry and a fake gh whose answer this test chooses.
#
# The fake gh is written by a plain heredoc, never one inside $(...): macOS ships
# bash 3.2, which mis-parses that and the whole suite fails to parse.
make_repo() {  # $1 = owner/name ; $2 = pr view json ; $3 = registry json, or MISSING
  local dir; dir=$(mktemp -d)
  mkdir -p "$dir/repo" "$dir/bin"
  ( cd "$dir/repo" && git init -q && git remote add origin "https://github.com/$1.git" )
  if [ "$3" = "MISSING" ]; then
    printf '%s' "$dir/absent.json" > "$dir/registry-path"
  else
    printf '%s' "$3" > "$dir/repos.json"
    printf '%s' "$dir/repos.json" > "$dir/registry-path"
  fi
  printf '%s' "$2" > "$dir/pr.json"
  cat > "$dir/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"auth status"*) printf 'Logged in to github.com account danwright32 (keyring)\n' ;;
  *"auth token -u "*) printf 'tok\n' ;;
  *"pr view"*) cat "$FAKE_PR_JSON" ;;
  # Which pull request a GraphQL merge's node is (claude-config#1181).
  *"api graphql"*)
    if [ -n "${FAKE_NODE_FAIL:-}" ]; then printf '%s\n' "$FAKE_NODE_FAIL" >&2; exit 1; fi
    printf '%s\n' "${FAKE_NODE_JSON:-}" ;;
esac
SH
  chmod +x "$dir/bin/gh"
  printf '%s' "$dir"
}

# The record of the wording Dan approved (claude-config#3666) is the fixture's own folder in every
# run, never this Mac's real one under ~/.claude/state. TALK names a session transcript for the
# payload to carry, as session s1; AGENT=1 makes the call a subagent's.
run_hook() {  # $1 = repo dir, $2 = command ; prints the hook's stdout
  printf '{"tool_input":{"command":%s},"cwd":%s%s%s}' \
    "$(printf '%s' "$2" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
    "$(printf '%s' "$1/repo" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
    "${TALK:+,\"session_id\":\"s1\",\"transcript_path\":$(printf '%s' "${TALK:-}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}" \
    "${AGENT:+,\"agent_id\":\"a9bba4c0ffee\"}" \
    | ( cd "$1/repo" \
        && PATH="$1/bin:$PATH" \
           FAKE_PR_JSON="$1/pr.json" \
           CHANGELOG_REGISTRY="$(cat "$1/registry-path")" \
           ANNOUNCE_APPROVALS_DIR="$1/approvals" \
           bash "$HOOK" )
}

# Matched with the shell's own builtins, WITHOUT a pipe, deliberately. A producer piped
# into a quiet grep is the short circuiting shape test-pipefail-shortcircuit.sh ratchets
# down: the reader leaves on its first match, the producer dies of SIGPIPE, and under
# `set -o pipefail` the pipeline reports a failure that never happened (L183). This suite
# was cloned from test-block-red-merge.sh and inherited that pattern as first written
# (L501). The builtins do the same job with no second process and nothing to break.
denied() { local re='"permissionDecision": *"deny"'; [[ "$1" =~ $re ]]; }
says() {  # $1 = the hook output, $2 = a LITERAL needle, matched case insensitively
  local was=0 found
  # `nocasematch` is a shell wide setting, so it is restored rather than switched off:
  # leaving it clear would be a silent change to any caller that had set it (L509). Restored by
  # shopt itself rather than an eval of what `shopt -p` printed, which the Slack drafts gate cannot
  # follow, so it stopped reading every variable of this suite (claude-config#2683).
  shopt -q nocasematch && was=1
  shopt -s nocasematch
  # "$2" is quoted, so a needle is a literal here where `grep -qi` read it as a regex.
  [[ "$1" == *"$2"* ]] && found=0 || found=1
  [ "$was" = 1 ] || shopt -u nocasematch
  return "$found"
}

# The start dates below are deliberately in the PAST. changelogFrom is a start
# date, so a fixture dated in the future puts its repo out of scope and every
# refusal case here quietly turns into an allow case, which is how this suite
# would pass while testing nothing.
REGISTRY='{"repos":[{"name":"PET","repo":"acme/widget","changelogFrom":"2026-01-01"}]}'
REGISTRY_NO_DATE='{"repos":[{"name":"PET","repo":"acme/widget"}]}'
REGISTRY_OTHER='{"repos":[{"name":"Slate","repo":"acme/slate","changelogFrom":"2026-01-01"}]}'

TAGGED='{"number":7,"url":"https://github.com/acme/widget/pull/7","author":{"login":"dwright-pennie"},"labels":[{"name":"changelog/visible"}],"body":"prose\n\n## Changelog\nThe board now says when Achieve is behind."}'
UNTAGGED='{"number":7,"url":"https://github.com/acme/widget/pull/7","author":{"login":"dwright-pennie"},"labels":[{"name":"priority-p2"}],"body":"prose only"}'
NOBLOCK='{"number":7,"url":"https://github.com/acme/widget/pull/7","author":{"login":"dwright-pennie"},"labels":[{"name":"changelog/visible"}],"body":"prose only"}'
TECHNICAL='{"number":7,"url":"https://github.com/acme/widget/pull/7","author":{"login":"dwright-pennie"},"labels":[{"name":"changelog/technical"}],"body":"prose only"}'
NONE_LBL='{"number":7,"url":"https://github.com/acme/widget/pull/7","author":{"login":"dwright-pennie"},"labels":[{"name":"changelog/none"}],"body":"prose only"}'
DEPENDABOT='{"number":7,"url":"https://github.com/acme/widget/pull/7","author":{"login":"app/dependabot"},"labels":[],"body":"Bumps wrangler."}'
WRONG_REPO='{"number":7,"url":"https://github.com/someone/else/pull/7","author":{"login":"dwright-pennie"},"labels":[],"body":"x"}'

# 1. The rule itself: an untagged pull request in a gated repo does not merge.
dir=$(make_repo acme/widget "$UNTAGGED" "$REGISTRY")
out=$(run_hook "$dir" "$MERGE 7 --squash")
if denied "$out"; then pass; else fail "an untagged PR merged in a gated repo: $out"; fi
# The refusal has to name what to add, or it is a dead end.
if says "$out" "changelog/visible"; then pass; else fail "the refusal does not name the labels to choose from: $out"; fi
rm -rf "$dir"

# 2. A properly tagged one goes through. Without this, case 1 is satisfied by a
#    gate that blocks everything (L159).
dir=$(make_repo acme/widget "$TAGGED" "$REGISTRY")
out=$(run_hook "$dir" "$MERGE 7 --squash")
if denied "$out"; then fail "a correctly tagged PR was blocked: $out"; else pass; fi
rm -rf "$dir"

# 3. Labelled visible but carrying no sentence. This is the case the whole
#    exercise exists for: a label alone still leaves the line to be written from
#    an engineering-voiced title months later.
dir=$(make_repo acme/widget "$NOBLOCK" "$REGISTRY")
out=$(run_hook "$dir" "$MERGE 7 --squash")
if denied "$out"; then pass; else fail "a visible PR with no Changelog block merged: $out"; fi
if says "$out" "## Changelog"; then pass; else fail "the refusal does not name the heading to add: $out"; fi
rm -rf "$dir"

# 4. Plumbing needs no sentence.
dir=$(make_repo acme/widget "$TECHNICAL" "$REGISTRY")
if denied "$(run_hook "$dir" "$MERGE 7 --squash")"; then
  fail "a technical PR was blocked for having no sentence"
else pass; fi
rm -rf "$dir"

dir=$(make_repo acme/widget "$NONE_LBL" "$REGISTRY")
if denied "$(run_hook "$dir" "$MERGE 7 --squash")"; then
  fail "a changelog/none PR was blocked"
else pass; fi
rm -rf "$dir"

# 5. Dependabot never writes a body block and merges itself, so gating it would
#    stall the auto-merge workflow permanently. Its changes are a standing
#    roll-up line in the update, not a per-change record.
dir=$(make_repo acme/widget "$DEPENDABOT" "$REGISTRY")
if denied "$(run_hook "$dir" "$MERGE 7 --squash")"; then
  fail "a dependabot PR was blocked, which would stall the auto-merge workflow"
else pass; fi
rm -rf "$dir"

# 6. Scope. A repo nobody has opted in stays untouched, or this gate would block
#    every merge in every other project on the machine.
dir=$(make_repo acme/widget "$UNTAGGED" "$REGISTRY_OTHER")
if denied "$(run_hook "$dir" "$MERGE 7 --squash")"; then
  fail "an unlisted repo was gated"
else pass; fi
rm -rf "$dir"

# A repo LISTED with no changelogFrom is an unfinished setup, not an opt out, and it refuses with
# its own message (claude-config#252). It used to take the bare exit 0, which is indistinguishable
# from a working gate on a repo whose start date has not arrived yet (L98, L11).
#
# Not hypothetical: the PET entry lost changelogFrom twice on 2026-08-31 to sessions that
# regenerated repos.json instead of read-modify-writing it, and nothing reported it either time.
# While it was missing, PET merges carried no changelog record and /pennie-dev-update silently
# degraded to reading pull request titles.
#
# The remedy stays reachable, which is the condition an exemption would otherwise be needed for
# (L362): the registry is each Mac's own file (repos.local.json, claude-config#1526), edited on the
# Mac with no pull request at all, so adding the date is not itself gated. ALLOW_UNTAGGED_MERGE=1 remains for anything else.
dir=$(make_repo acme/widget "$UNTAGGED" "$REGISTRY_NO_DATE")
out=$(run_hook "$dir" "$MERGE 7 --squash")
if denied "$out"; then pass; else fail "a repo listed without a changelogFrom date silently disabled the gate: $out"; fi
if says "$out" "changelogFrom"; then pass; else fail "the refusal does not name the field to fix: $out"; fi
if says "$out" "acme/widget"; then pass; else fail "the refusal does not name the repo it is about: $out"; fi
rm -rf "$dir"

# The genuinely ungated repo is the one NOT listed at all, and it must still merge freely in the
# same run, or the fix above has simply blocked everything (L159).
dir=$(make_repo acme/widget "$UNTAGGED" "$REGISTRY_OTHER")
if denied "$(run_hook "$dir" "$MERGE 7 --squash")"; then
  fail "an unlisted repo was gated by the missing-changelogFrom refusal"
else pass; fi
rm -rf "$dir"

# The registry not being there at all used to be a stand down, read as the dev update skill not
# being installed here. It is each Mac's own file since claude-config#1526, and every Mac carrying
# this gate carries the skill, so a missing one is a Mac that lost it or never made it, and standing
# down there would ungate every repo with nothing said (L98). It is refused like an unreadable one,
# naming the file to create.
dir=$(make_repo acme/widget "$TAGGED" MISSING)
out=$(run_hook "$dir" "$MERGE 7 --squash")
if denied "$out"; then pass; else fail "a missing registry was read as an opt out: $out"; fi
if says "$out" "$dir/absent.json"; then pass; else fail "the refusal does not name the file to create: $out"; fi
if says "$out" '{\"repos\": []}'; then pass; else fail "the refusal does not say how to gate nothing on purpose: $out"; fi
rm -rf "$dir"
# And gating nothing on purpose is a registry listing no repos, which merges freely.
dir=$(make_repo acme/widget "$UNTAGGED" '{"repos": []}')
if denied "$(run_hook "$dir" "$MERGE 7 --squash")"; then
  fail "a registry listing no repos still gated a merge"
else pass; fi
rm -rf "$dir"

# But a registry that EXISTS and cannot be parsed is a different answer. It means
# the gate cannot tell whether this repo is in scope, and an unreadable registry
# must not read as a deliberate opt out (L11, L214).
dir=$(make_repo acme/widget "$UNTAGGED" '{ not json')
out=$(run_hook "$dir" "$MERGE 7 --squash")
if denied "$out"; then pass; else fail "a corrupt registry was read as an opt out: $out"; fi
if says "$out" "repos.json"; then pass; else fail "the refusal does not name the file that could not be read: $out"; fi
rm -rf "$dir"

# A start date that has not arrived yet. The field is a start date, not an on
# switch, so a repo can be given its launch day in advance. Slate is the case
# this exists for.
dir=$(make_repo acme/widget "$UNTAGGED" '{"repos":[{"name":"PET","repo":"acme/widget","changelogFrom":"2099-01-01"}]}')
if denied "$(run_hook "$dir" "$MERGE 7 --squash")"; then
  fail "a repo whose changelog start date has not arrived was gated already"
else pass; fi
rm -rf "$dir"

# A start date nobody can parse is a config error, not a quiet stand down.
# Reading it as "not yet" would disable the gate on a typo and say nothing,
# which is indistinguishable from the gate passing (L98).
dir=$(make_repo acme/widget "$UNTAGGED" '{"repos":[{"name":"PET","repo":"acme/widget","changelogFrom":"September"}]}')
out=$(run_hook "$dir" "$MERGE 7 --squash")
if denied "$out"; then pass; else fail "an unparseable changelog start date silently disabled the gate: $out"; fi
if says "$out" "September"; then pass; else fail "the refusal does not quote the value it could not read: $out"; fi
# It must not read like the untagged refusal: the remedy is fixing the registry,
# not labelling the pull request (L11).
if says "$out" "changelogFrom"; then pass; else fail "the refusal does not name the field to fix: $out"; fi
rm -rf "$dir"

# 7. Anything that is not a merge is none of this hook's business.
dir=$(make_repo acme/widget "$UNTAGGED" "$REGISTRY")
if denied "$(run_hook "$dir" "gh pr view 7")"; then
  fail "the hook blocked a command that was not a merge"
else pass; fi
rm -rf "$dir"

# 8. The visible override, for the one case with no other route.
dir=$(make_repo acme/widget "$UNTAGGED" "$REGISTRY")
if denied "$(run_hook "$dir" "ALLOW_UNTAGGED_MERGE=1 $MERGE 7 --squash")"; then
  fail "the visible override did not let the merge through"
else pass; fi
rm -rf "$dir"

# 9. An answer about a DIFFERENT repo is not this pull request's record. Reading
#    one pull request and merging another is the mistake worth naming (L70).
dir=$(make_repo acme/widget "$WRONG_REPO" "$REGISTRY")
out=$(run_hook "$dir" "$MERGE 7 --squash")
if denied "$out"; then pass; else fail "an answer about another repo was accepted as this PR's record: $out"; fi
if says "$out" "someone/else"; then pass; else fail "the refusal does not name the repo it was told about: $out"; fi
rm -rf "$dir"

# 10. No answer at all. Merging blind loses the record silently, which is what
#     this gate exists to prevent, so it fails closed.
dir=$(make_repo acme/widget "" "$REGISTRY")
out=$(run_hook "$dir" "$MERGE 7 --squash")
if denied "$out"; then pass; else fail "an empty answer from gh let the merge through: $out"; fi
rm -rf "$dir"

# 11. A command that merely TALKS about merging is not a merge, and this gate is a
#     PreToolUse DENY, so a false positive refuses the WHOLE command and nothing in
#     it runs. Both times it happened on 2026-09-10 the command was writing an issue
#     body about merge tooling, and the heredoc that never ran surfaced one step
#     later as a missing file (claude-config#349).
#
#     The library has its own cases for the matcher. This one is here because a
#     correct predicate is worth nothing until the gate actually CALLS it (L3), and
#     this gate is the one where being wrong costs the most.
dir=$(make_repo acme/widget "$UNTAGGED" "$REGISTRY")
note="cat > docs/merge-notes.md <<'EOF'
The gate resolves the number; then $MERGE 7 --squash is what runs
EOF"
out=$(run_hook "$dir" "$note")
if denied "$out"; then fail "a heredoc about merging was refused as a merge: $out"; else pass; fi
out=$(run_hook "$dir" "gh issue comment 5 --body \"then run $MERGE\"")
if denied "$out"; then fail "an issue comment about merging was refused as a merge: $out"; else pass; fi
# And the positive control in the SAME fixture, so the two above are not passing
# because this repo, registry or fake gh happens to allow everything (L159).
out=$(run_hook "$dir" "$MERGE 7 --squash")
if denied "$out"; then pass; else fail "the real merge was not refused, so the cases above prove nothing: $out"; fi
rm -rf "$dir"

# 12. A merge through a repo's own wrapper carries the same record as any other, and the
#     gate was blind to every one of them (claude-config#351). It matters most in PET,
#     where block-red-merge REFUSES the direct command because the repo carries a commit
#     pinned tool, so the route this gate could not see was the only route available and
#     the gate was enforcing nothing at all in the repo it was built for.
dir=$(make_repo acme/widget "$UNTAGGED" "$REGISTRY")
for route in "venv/bin/python tools/wait_for_checks.py 7 --merge" \
             "npm run merge -- 7" \
             "bash .github/scripts/merge-pr.sh 7" \
             "./scripts/merge-when-green.sh 7"; do
  out=$(run_hook "$dir" "$route")
  if denied "$out"; then pass; else fail "an untagged PR merged through a wrapper: $route"; fi
done
# The tool merely WAITING for checks merges nothing, so it must not be gated: refusing it
# would block a person from looking at a pull request they have not tried to merge.
out=$(run_hook "$dir" "venv/bin/python tools/wait_for_checks.py 7")
if denied "$out"; then fail "waiting for checks was refused as a merge: $out"; else pass; fi
rm -rf "$dir"

# 13. And a TAGGED pull request goes through by those same routes, so case 12 is not
#     satisfied by a gate that refuses every wrapper regardless of the record (L159).
dir=$(make_repo acme/widget "$TAGGED" "$REGISTRY")
out=$(run_hook "$dir" "venv/bin/python tools/wait_for_checks.py 7 --merge")
if denied "$out"; then fail "a correctly tagged PR was blocked on the wrapper route: $out"; else pass; fi
rm -rf "$dir"

echo "changelog record: the repository the merge names, not the session's folder (#470)"

# The gate asked gh about the folder the session sits in whatever the merge named, so a merge
# carrying --repo, or a pull request given as a link, was answered about a repository holding no
# such pull request: the record was read from the wrong place, or not at all, and the refusal was
# the generic "gh returned nothing" that sends somebody to the override (L11, L36). block-red-merge
# was taught to resolve this in claude-config#463; this gate and the quiz were not.
#
# The fake gh resolves a repository the way the real one does: --repo or -R first, then the remote
# of the directory it runs in. It answers a pull request only for a repository with a file under
# prs/, and gh's own not found otherwise.
make_repo_pair() {  # $1 = registry json ; prints a fixture dir holding repo/ and other/
  local dir; dir=$(mktemp -d)
  mkdir -p "$dir/repo" "$dir/other" "$dir/bin" "$dir/prs"
  ( cd "$dir/repo" && git init -q && git remote add origin "https://github.com/acme/widget.git" )
  ( cd "$dir/other" && git init -q && git remote add origin "https://github.com/other/repo.git" )
  printf '%s' "$1" > "$dir/repos.json"
  printf '%s' "$dir/repos.json" > "$dir/registry-path"
  : > "$dir/pr.json"
  cat > "$dir/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALL_LOG"
repo="" prev=""
for a in "$@"; do
  case "$prev" in --repo|-R) repo="$a" ;; esac
  case "$a" in --repo=*) repo="${a#--repo=}" ;; esac
  prev="$a"
done
[ -n "$repo" ] || repo=$(git config --get remote.origin.url 2>/dev/null | sed -E 's#^https://github.com/##; s#[.]git$##')
case "$*" in
  *"auth status"*) printf 'Logged in to github.com account danwright32 (keyring)\n' ;;
  *"auth token -u "*) printf 'tok\n' ;;
  *"pr view"*)
    f="$FIXTURE/prs/$(printf '%s' "$repo" | tr / _)"
    if [ -f "$f" ]; then cat "$f"; exit 0; fi
    echo "GraphQL: Could not resolve to a PullRequest with the number of 7. (repository.pullRequest)" >&2
    exit 1 ;;
esac
SH
  chmod +x "$dir/bin/gh"
  printf '%s' "$dir"
}

pair() {  # $1 = registry json ; sets dir, FIXTURE and GH_CALL_LOG
  dir=$(make_repo_pair "$1")
  FIXTURE="$dir"; GH_CALL_LOG="$dir/gh-calls.log"; export FIXTURE GH_CALL_LOG; : > "$GH_CALL_LOG"
}
asked_about() {  # $1 = a literal the gh call log must hold
  case "$(cat "$GH_CALL_LOG")" in *"$1"*) return 0 ;; *) return 1 ;; esac
}

REG_ALL='{"repos":[{"name":"PET","repo":"acme/widget","changelogFrom":"2026-01-01"},
  {"name":"Other","repo":"other/repo","changelogFrom":"2026-01-01"},
  {"name":"Nowhere","repo":"nobody/there","changelogFrom":"2026-01-01"}]}'
REG_OTHER_ONLY='{"repos":[{"name":"Other","repo":"other/repo","changelogFrom":"2026-01-01"}]}'
REG_WIDGET_ONLY='{"repos":[{"name":"PET","repo":"acme/widget","changelogFrom":"2026-01-01"}]}'
TAGGED_OTHER='{"number":7,"url":"https://github.com/other/repo/pull/7","author":{"login":"dwright-pennie"},"labels":[{"name":"changelog/visible"}],"body":"prose\n\n## Changelog\nThe board now says when Achieve is behind."}'
UNTAGGED_OTHER='{"number":7,"url":"https://github.com/other/repo/pull/7","author":{"login":"dwright-pennie"},"labels":[{"name":"priority-p2"}],"body":"prose only"}'

# The issue's own case: --repo names a repository other than the folder, and the record is read
# from THAT repository. The folder's own pull request is untagged, so a gate still asking about the
# folder refuses this merge.
for form in "--repo other/repo" "-R other/repo" "--repo=other/repo"; do
  pair "$REG_ALL"
  printf '%s' "$TAGGED_OTHER" > "$dir/prs/other_repo"
  printf '%s' "$UNTAGGED" > "$dir/prs/acme_widget"
  out=$(run_hook "$dir" "$MERGE 7 $form --squash")
  if denied "$out"; then fail "a tagged PR named by [$form] was refused: $out"; else pass; fi
  if asked_about "pr view 7 --repo other/repo"; then pass; else
    fail "[$form] did not make the gate ask gh about other/repo: $(cat "$GH_CALL_LOG")"
  fi
  rm -rf "$dir"
done

# Never loosened: an untagged pull request in the named repository is still refused, and the
# refusal is the record's own, not a failure to find the pull request.
pair "$REG_ALL"
printf '%s' "$UNTAGGED_OTHER" > "$dir/prs/other_repo"
printf '%s' "$TAGGED" > "$dir/prs/acme_widget"
out=$(run_hook "$dir" "$MERGE 7 --repo other/repo --squash")
if denied "$out"; then pass; else fail "an untagged PR named by --repo merged: $out"; fi
if says "$out" "changelog/visible"; then pass; else
  fail "the refusal for a named repository does not name the labels to choose from: $out"; fi
rm -rf "$dir"

# Scope follows the repository the merge is about, not the folder. A repository gated by the
# registry is gated however the merge names it.
pair "$REG_OTHER_ONLY"
printf '%s' "$UNTAGGED_OTHER" > "$dir/prs/other_repo"
printf '%s' "$TAGGED" > "$dir/prs/acme_widget"
out=$(run_hook "$dir" "$MERGE 7 --repo other/repo --squash")
if denied "$out"; then pass; else
  fail "a gated repository named by --repo was read as out of scope, because the folder's repository is not listed: $out"; fi
rm -rf "$dir"

# And the other direction, so the case above is not satisfied by a gate that stopped reading the
# registry at all (L159): a repository nobody listed still merges freely from a folder that IS
# listed.
pair "$REG_WIDGET_ONLY"
printf '%s' "$UNTAGGED_OTHER" > "$dir/prs/other_repo"
printf '%s' "$UNTAGGED" > "$dir/prs/acme_widget"
out=$(run_hook "$dir" "$MERGE 7 --repo other/repo --squash")
if denied "$out"; then
  fail "a repository nobody gated was gated because the session's folder is listed: $out"; else pass; fi
rm -rf "$dir"

# NOT FOUND is its own refusal, naming the repository that was searched, rather than the generic
# sentence about gh returning nothing, which is a different fault with a different remedy (L11).
pair "$REG_ALL"
printf '%s' "$TAGGED_OTHER" > "$dir/prs/other_repo"
out=$(run_hook "$dir" "$MERGE 7 --repo nobody/there --squash")
if denied "$out"; then pass; else fail "a pull request that does not exist merged: $out"; fi
if says "$out" "no pull request #7 was found in nobody/there"; then pass; else
  fail "the not found refusal does not say so, naming the repository searched: $out"; fi
if says "$out" "returned nothing"; then
  fail "the not found refusal reads as gh having failed to answer: $out"; else pass; fi
rm -rf "$dir"

# A pull request given as a link names both the repository and the number, which is what gh does
# with it, so the record is read from there too.
pair "$REG_ALL"
printf '%s' "$TAGGED_OTHER" > "$dir/prs/other_repo"
printf '%s' "$UNTAGGED" > "$dir/prs/acme_widget"
out=$(run_hook "$dir" "$MERGE https://github.com/other/repo/pull/7 --squash")
if denied "$out"; then fail "a tagged PR given as a link was refused: $out"; else pass; fi
if asked_about "pr view 7 --repo other/repo"; then pass; else
  fail "a link did not make the gate ask gh about other/repo pull request 7: $(cat "$GH_CALL_LOG")"; fi
rm -rf "$dir"

# And the link route is not a way past the record either.
pair "$REG_ALL"
printf '%s' "$UNTAGGED_OTHER" > "$dir/prs/other_repo"
printf '%s' "$TAGGED" > "$dir/prs/acme_widget"
out=$(run_hook "$dir" "$MERGE https://github.com/other/repo/pull/7 --squash")
if denied "$out"; then pass; else fail "an untagged PR given as a link merged: $out"; fi
rm -rf "$dir"
unset FIXTURE GH_CALL_LOG

echo "changelog record: the reader the shared library needs (#475)"

# Which pull request and which repository the merge names are read with python3 in
# lib/merge-target.sh. Where that reader is absent both come back empty, so this gate read the
# record of whatever pull request the current branch resolves to. It has to refuse, and name the
# reader: "no pull request was found" is a true sentence about a different fault whose remedy,
# naming a repository, cannot clear this one (L11).
nopython_bin() {  # $1 = a fixture dir holding bin/gh ; prints a bin directory with no python3
  local out="$1/nopython" t p
  mkdir -p "$out"
  for t in bash sh git jq node grep sed awk tr cat cut head sort dirname basename env uname mkdir mv rm; do
    p="$(command -v "$t" 2>/dev/null)"
    [ -n "$p" ] && [ "$p" != "$1/bin/$t" ] && ln -s "$p" "$out/$t" 2>/dev/null
  done
  ln -s "$1/bin/gh" "$out/gh" 2>/dev/null
  printf '%s' "$out"
}

run_hook_nopython() {  # $1 = repo dir, $2 = command ; the hook run with no python3 on PATH
  local nopy; nopy="$(nopython_bin "$1")"
  printf '{"tool_input":{"command":%s},"cwd":%s}' \
    "$(printf '%s' "$2" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
    "$(printf '%s' "$1/repo" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
    | ( cd "$1/repo" \
        && PATH="$nopy" \
           FAKE_PR_JSON="$1/pr.json" \
           CHANGELOG_REGISTRY="$(cat "$1/registry-path")" \
           bash "$HOOK" )
}

# TAGGED, deliberately: the record that MERGES when the command can be read, so a refusal here is
# the missing reader's doing rather than a fixture that refuses everything (L159).
dir=$(make_repo acme/widget "$TAGGED" "$REGISTRY")
if PATH="$(nopython_bin "$dir")" bash -c 'command -v python3 >/dev/null 2>&1'; then
  fail "the bare directory still reaches a python3, so this case measures nothing"
else pass; fi
out=$(run_hook_nopython "$dir" "$MERGE 7 --repo acme/widget --squash")
if denied "$out"; then pass; else
  fail "with no python3 the gate read a record it could not attribute to this pull request: $out"; fi
if says "$out" "python3"; then pass; else
  fail "the refusal does not name the reader that is missing: $out"; fi
if says "$out" "was found in"; then
  fail "the missing reader was reported as the pull request not existing: $out"; else pass; fi
# The control: the same record and the same command with python3 on PATH merges.
if denied "$(run_hook "$dir" "$MERGE 7 --repo acme/widget --squash")"; then
  fail "the control case refused a tagged merge, so the case above proves nothing"
else pass; fi
rm -rf "$dir"

# A wrapper route reads its number with the SHELL and names no repository at all, so python3's
# absence takes nothing away from it and there is nothing to refuse. A guard that refused here
# would be refusing over a reader that route never used (L324, L54).
dir=$(make_repo acme/widget "$TAGGED" "$REGISTRY")
out=$(run_hook_nopython "$dir" "npm run merge -- 7")
if denied "$out"; then
  fail "a wrapper merge was refused over a reader it never needed: $out"; else pass; fi
rm -rf "$dir"

echo "changelog record: the reader the PAYLOAD needs (#480)"

# The command this gate judges is read out of the hook payload, which is JSON, and that read used
# to be a bare jq sitting ABOVE the `command -v jq` further down. With no jq the command came back
# EMPTY, mt_runs_merge answered no, and the gate exited 0 on every merge with nothing said, never
# reaching the check that would have named jq. An absent reader is the one failure indistinguishable
# from a clean run (L490, L42, L98).
bin_without() {  # $1 = a fixture dir holding bin/gh, $2.. = the tools to leave OUT
  local out="$1/without-$2" t p drop
  mkdir -p "$out"
  for t in bash sh git jq node python3 grep sed awk tr cat cut head sort dirname basename env uname mkdir mv rm; do
    drop=0
    for p in "${@:2}"; do [ "$t" = "$p" ] && drop=1; done
    [ "$drop" = 1 ] && continue
    p="$(command -v "$t" 2>/dev/null)"
    [ -n "$p" ] && [ "$p" != "$1/bin/$t" ] && ln -s "$p" "$out/$t" 2>/dev/null
  done
  ln -s "$1/bin/gh" "$out/gh" 2>/dev/null
  printf '%s' "$out"
}

NOREAD_OUT=""; NOREAD_RC=0
run_hook_on() {  # $1 = repo dir, $2 = bin dir, $3 = command ; stdout and stderr together, with rc
  NOREAD_OUT="$(printf '{"tool_input":{"command":%s},"cwd":%s}' \
    "$(printf '%s' "$3" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
    "$(printf '%s' "$1/repo" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
    | ( cd "$1/repo" \
        && PATH="$2" \
           FAKE_PR_JSON="$1/pr.json" \
           CHANGELOG_REGISTRY="$(cat "$1/registry-path")" \
           ANNOUNCE_APPROVALS_DIR="$1/approvals" \
           bash "$HOOK" 2>&1 ))"
  NOREAD_RC=$?
}

# TAGGED, deliberately: the record that MERGES when the command can be read, so a refusal here is
# the missing reader's doing rather than a fixture that refuses everything (L159).
dir=$(make_repo acme/widget "$TAGGED" "$REGISTRY")
noread="$(bin_without "$dir" jq python3)"
if PATH="$noread" bash -c 'command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1'; then
  fail "the bare directory still reaches a jq or a python3, so these cases measure nothing"
else pass; fi

run_hook_on "$dir" "$noread" "$MERGE 7 --repo acme/widget --squash"
if [ "$NOREAD_RC" -eq 2 ]; then pass; else
  fail "with no payload reader at all the gate allowed the merge (rc=$NOREAD_RC): $NOREAD_OUT"; fi
if says "$NOREAD_OUT" "jq"; then pass; else
  fail "the refusal does not name jq, one of the two readers that is missing: $NOREAD_OUT"; fi
if says "$NOREAD_OUT" "python3"; then pass; else
  fail "the refusal does not name python3, the other reader it would have taken: $NOREAD_OUT"; fi

# An ordinary command is not refused, however bare the PATH is: a gate that stopped every Bash call
# on such a machine is one nobody keeps (L36, L54).
run_hook_on "$dir" "$noread" "ls -la"
if [ "$NOREAD_RC" -eq 0 ] && [ -z "$NOREAD_OUT" ]; then pass; else
  fail "an ordinary command was refused because the payload could not be read (rc=$NOREAD_RC): $NOREAD_OUT"; fi

# The documented override still clears it, read off the payload text because the command itself
# cannot be parsed here. A refusal nothing in the session can clear is a dead end (L109).
run_hook_on "$dir" "$noread" "ALLOW_UNTAGGED_MERGE=1 $MERGE 7 --repo acme/widget --squash"
if [ "$NOREAD_RC" -eq 0 ] && [ -z "$NOREAD_OUT" ]; then pass; else
  fail "the visible override did not clear the unreadable payload refusal (rc=$NOREAD_RC): $NOREAD_OUT"; fi

# jq alone missing, python3 present: the command IS readable, so the gate knows this is a merge,
# and it must still refuse, because the record it is looking for arrives inside gh's JSON answer
# and nothing left on the machine can read one. This is the half a python3 shaped fix would leave
# passing silently.
nojq="$(bin_without "$dir" jq)"
if PATH="$nojq" bash -c 'command -v jq >/dev/null 2>&1'; then
  fail "the bare directory still reaches a jq, so this case measures nothing"
else pass; fi
if PATH="$nojq" bash -c 'command -v python3 >/dev/null 2>&1'; then pass; else
  fail "the bare directory has no python3 either, so this case cannot separate the two"; fi
run_hook_on "$dir" "$nojq" "$MERGE 7 --repo acme/widget --squash"
if [ "$NOREAD_RC" -eq 2 ]; then pass; else
  fail "with no jq the gate allowed the merge (rc=$NOREAD_RC): $NOREAD_OUT"; fi
if says "$NOREAD_OUT" "jq"; then pass; else
  fail "the refusal does not name jq: $NOREAD_OUT"; fi
# With the override typed the merge goes through, as it always did. But gh's answer was never read,
# so the pull request may be an announcement, which the override does not cover, and the allow says
# so instead of saying nothing (claude-config#3665; Dan, 2026-11-25).
run_hook_on "$dir" "$nojq" "ALLOW_UNTAGGED_MERGE=1 $MERGE 7 --repo acme/widget --squash"
if [ "$NOREAD_RC" -eq 0 ] && says "$NOREAD_OUT" '"systemMessage"' && says "$NOREAD_OUT" "jq is not installed" && says "$NOREAD_OUT" "an announcement" && says "$NOREAD_OUT" "could not be ruled out"; then pass; else
  fail "#3665 with the override typed and no jq, the merge was refused, or let through with nothing said about an announcement (rc=$NOREAD_RC): $NOREAD_OUT"; fi
# The control, same fixture and same command with both readers present: it merges, so every
# refusal above is the reader's absence rather than a fixture that refuses everything (L159).
if denied "$(run_hook "$dir" "$MERGE 7 --repo acme/widget --squash")"; then
  fail "the control case refused a tagged merge, so the cases above prove nothing"
else pass; fi
rm -rf "$dir"

# A missing registry is no longer a stand down (claude-config#1526), so with no payload reader the
# merge is refused whether or not the registry is there: the rule applies on every Mac carrying
# this gate, and nothing here can read the command to say otherwise.
dir=$(make_repo acme/widget "$TAGGED" "$REGISTRY")
printf '%s' "$dir/no-such-registry.json" > "$dir/registry-path"
noread="$(bin_without "$dir" jq python3)"
run_hook_on "$dir" "$noread" "$MERGE 7 --repo acme/widget --squash"
if [ "$NOREAD_RC" -eq 2 ]; then pass; else
  fail "with no payload reader and no registry the merge was allowed (rc=$NOREAD_RC): $NOREAD_OUT"; fi
rm -rf "$dir"

echo "changelog record: every merge in a command is judged, not only the first (#1062)"

# The gate read the FIRST merge's record. So a tagged pull request merged first, then an untagged
# one from another checkout of a gated repository, went through on the first one's record and the
# second change was lost from the next manager update. gh answers by number here, so only the
# second is untagged.
dir=$(make_repo acme/widget "$TAGGED" "$REGISTRY")
dir2=$(make_repo acme/widget "$TAGGED" "$REGISTRY")
printf '%s' "${UNTAGGED/pull\/7/pull/8}" > "$dir/pr8.json"
cat > "$dir/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"auth status"*) printf 'Logged in to github.com account danwright32 (keyring)\n' ;;
  *"auth token -u "*) printf 'tok\n' ;;
  *"pr view 8"*) cat "$(dirname "$FAKE_PR_JSON")/pr8.json" ;;
  *"pr view"*) cat "$FAKE_PR_JSON" ;;
esac
SH
chmod +x "$dir/bin/gh"
out=$(run_hook "$dir" "$MERGE 7 --squash")
if denied "$out"; then fail "control: the tagged merge alone was refused: $out"; else pass; fi
out=$(run_hook "$dir" "$MERGE 7 --squash; cd $dir2/repo && $MERGE 8 --squash")
if denied "$out"; then pass; else
  fail "a second merge, of an untagged pull request in another checkout, went through on the first one's record: $out"
fi
if says "$out" "more than one pull request"; then pass; else
  fail "the refusal does not say the command merges more than one pull request: $out"
fi
rm -rf "$dir" "$dir2"

# But only where this gate has a rule (merge time lessons review of #1072). Two merges in
# repositories the registry does not gate carry no changelog record to lose, so refusing them with a
# sentence about changelog records claimed a rule that does not apply there (L11).
dir=$(make_repo acme/ungated-one "$TAGGED" "$REGISTRY")
dir2=$(make_repo acme/ungated-two "$TAGGED" "$REGISTRY")
out=$(run_hook "$dir" "$MERGE 7 --squash; cd $dir2/repo && $MERGE 8 --squash")
if [ -z "$out" ]; then pass; else
  fail "two merges in repositories the registry does not gate were refused over a rule that does not apply there: $out"
fi
rm -rf "$dir2"
# ...while a second merge into a GATED repository, after a first into an ungated one, is still
# refused: the scope that matters is every target's, not the first one's.
dir2=$(make_repo acme/widget "$UNTAGGED" "$REGISTRY")
out=$(run_hook "$dir" "$MERGE 7 --squash; cd $dir2/repo && $MERGE 8 --squash")
if denied "$out" && says "$out" "more than one pull request"; then pass; else
  fail "a second merge into a gated repository, after one into an ungated repository, was not refused: $out"
fi
out=$(run_hook "$dir" "$MERGE 7 --squash; $MERGE 8 --repo acme/widget --squash")
if denied "$out"; then pass; else
  fail "a second merge naming a gated repository with --repo was not refused: $out"
fi
rm -rf "$dir" "$dir2"

# THE OVERRIDE DOES NOT CLEAR IT (Dan, 2026-11-25, claude-config#3666: "Refuse it"). Phase 1 let a
# command merging several pull requests through when ALLOW_UNTAGGED_MERGE=1 was typed, with a
# sentence that an announcement could not be ruled out, and no case here held that path either way.
# The gate reads one pull request per command, so an announcement among the others merged with its
# post and its approval unjudged, which is the one thing the override does not cover. The remedy is
# always open, one pull request per command, and that is what separates this from a pull request
# that cannot be read at all, where the override still lets the merge through and says so.
dir=$(make_repo acme/widget "$TAGGED" "$REGISTRY")
dir2=$(make_repo acme/widget "$TAGGED" "$REGISTRY")
SEVERAL="$MERGE 7 --squash; cd $dir2/repo && $MERGE 8 --squash"
out=$(run_hook "$dir" "ALLOW_UNTAGGED_MERGE=1 $SEVERAL" 2>/dev/null)
if denied "$out" && says "$out" "more than one pull request"; then pass; else
  fail "#3666 with the override typed, a command merging more than one pull request was let through: $out"
fi
if says "$out" "Merge one pull request per command"; then pass; else
  fail "#3666 the refusal under the override does not say to merge one pull request per command: $out"
fi
if says "$out" "ALLOW_UNTAGGED_MERGE=1 does not clear this"; then pass; else
  fail "#3666 the refusal under the override does not say the override does not clear it: $out"
fi
# Typed on the second merge instead of the first, it is the same command and the same refusal.
out=$(run_hook "$dir" "$MERGE 7 --squash; cd $dir2/repo && ALLOW_UNTAGGED_MERGE=1 $MERGE 8 --squash" 2>/dev/null)
if denied "$out" && says "$out" "Merge one pull request per command"; then pass; else
  fail "#3666 with the override typed on the second merge, the command was let through: $out"
fi
# Without the override the refusal no longer offers it, since typing it now changes nothing (L111).
out=$(run_hook "$dir" "$SEVERAL")
if denied "$out" && ! says "$out" "Deliberate override"; then pass; else
  fail "#3666 the refusal of several merges still offers an override that no longer clears it: $out"
fi
rm -rf "$dir2"
# Still possible: the same two, each as a command of its own, merge.
out=$(run_hook "$dir" "$MERGE 7 --squash")
if denied "$out"; then fail "#3666 control: one merge per command was refused: $out"; else pass; fi
# And where no target is gated the override changes nothing: nothing is read and nothing is said.
rm -rf "$dir"
dir=$(make_repo acme/ungated-one "$TAGGED" "$REGISTRY")
dir2=$(make_repo acme/ungated-two "$TAGGED" "$REGISTRY")
out=$(run_hook "$dir" "ALLOW_UNTAGGED_MERGE=1 $MERGE 7 --squash; cd $dir2/repo && $MERGE 8 --squash" 2>/dev/null)
if [ -z "$out" ]; then pass; else
  fail "#3666 two merges in repositories the registry does not gate were refused under the override: $out"
fi
rm -rf "$dir" "$dir2"

# With no python3 nothing can read which pull request each merge is aimed at, and the reader check
# above covers only the direct form. Two merges through a repo's own merge tool, in a gated
# repository, were read as one merge and judged by the first (lessons review of #1072, L490).
dir=$(make_repo acme/widget "$TAGGED" "$REGISTRY")
nopy="$(bin_without "$dir" python3)"
run_hook_on "$dir" "$nopy" "./scripts/merge-when-green.sh 7; ./scripts/merge-when-green.sh 8"
if denied "$NOREAD_OUT" && says "$NOREAD_OUT" "more than one merge"; then pass; else
  fail "with no python3, two merges through a merge tool were not refused by name (rc=$NOREAD_RC): $NOREAD_OUT"
fi
run_hook_on "$dir" "$nopy" "./scripts/merge-when-green.sh 7"
if says "$NOREAD_OUT" "more than one merge"; then
  fail "control: with no python3, one merge through a merge tool was refused as several: $NOREAD_OUT"; else pass; fi
rm -rf "$dir"

echo "changelog record: a merge through the GitHub API (claude-config#1181)"

# Before #1181 these merged with no record read: the recogniser did not know the routes, and the
# hook was registered behind an `if` of Bash(gh pr merge*), so Claude Code never ran it for them.
NODE_WIDGET='{"data":{"node":{"__typename":"PullRequest","number":7,"repository":{"nameWithOwner":"acme/widget"}}}}'
GQL_MERGE="gh api graphql -f query='mutation { mergePullRequest(input: {pullRequestId: \"PR_x\"}) { clientMutationId } }'"
GQL_AUTO="gh api graphql -f query='mutation { enablePullRequestAutoMerge(input: {pullRequestId: \"PR_x\"}) { clientMutationId } }'"

dir=$(make_repo acme/widget "$UNTAGGED" "$REGISTRY")
for c in "gh api -X PUT repos/acme/widget/pulls/7/merge -f merge_method=squash" \
         "gh api --method PUT 'repos/{owner}/{repo}/pulls/7/merge'" \
         "GH_TOKEN=x gh api -XPUT https://api.github.com/repos/acme/widget/pulls/7/merge"; do
  out=$(run_hook "$dir" "$c")
  if denied "$out" && says "$out" "changelog/visible"; then pass; else fail "#1181 an untagged PR merged through the REST endpoint [$c]: $out"; fi
done
for c in "$GQL_MERGE" "$GQL_AUTO"; do
  out=$(FAKE_NODE_JSON="$NODE_WIDGET" run_hook "$dir" "$c")
  if denied "$out" && says "$out" "changelog/visible"; then pass; else fail "#1181 an untagged PR merged through a GraphQL mutation [$c]: $out"; fi
done
# Behind a word that only runs the command after it, each route is the same merge (#1181).
for c in "env GH_TOKEN=x $MERGE 7 --squash" "sudo -u dan $MERGE 7 --squash" "sudo env GH_TOKEN=x rtk gh api -X PUT repos/acme/widget/pulls/7/merge"; do
  out=$(run_hook "$dir" "$c")
  if denied "$out" && says "$out" "changelog/visible"; then pass; else fail "#1181 an untagged PR merged behind a runner [$c]: $out"; fi
done
out=$(FAKE_NODE_JSON="$NODE_WIDGET" run_hook "$dir" "env GH_TOKEN=x $GQL_MERGE")
if denied "$out" && says "$out" "changelog/visible"; then pass; else fail "#1181 an untagged PR merged through GraphQL behind env: $out"; fi
# The failure path: a node GitHub cannot resolve is refused by name, not read as the current branch's.
out=$(FAKE_NODE_FAIL="gh: Could not resolve to a node with the global id of 'PR_x'" run_hook "$dir" "$GQL_MERGE")
if denied "$out" && says "$out" "GitHub could not say which pull request that is" && says "$out" "ALLOW_UNTAGGED_MERGE=1"; then pass
else fail "#1181 a GraphQL merge whose node cannot be resolved was not refused by name: $out"; fi
# Calls that merge nothing pass untouched.
for c in "gh api repos/acme/widget/pulls/7/merge" "gh api -X PUT repos/acme/widget/pulls/7 -f title=merge"; do
  out=$(run_hook "$dir" "$c")
  if [ -z "$out" ]; then pass; else fail "#1181 a gh api call that merges nothing was not let through untouched [$c]: $out"; fi
done
rm -rf "$dir"

dir=$(make_repo acme/widget "$TAGGED" "$REGISTRY")
out=$(run_hook "$dir" "gh api -X PUT repos/acme/widget/pulls/7/merge")
if denied "$out"; then fail "#1181 a tagged PR merged through the REST endpoint was refused: $out"; else pass; fi
out=$(FAKE_NODE_JSON="$NODE_WIDGET" run_hook "$dir" "$GQL_MERGE")
if denied "$out"; then fail "#1181 a tagged PR merged through GraphQL was refused: $out"; else pass; fi
rm -rf "$dir"

# A REST merge into a repository the registry does not gate stands down, as gh pr merge does there.
dir=$(make_repo acme/widget "$UNTAGGED" "$REGISTRY_OTHER")
out=$(run_hook "$dir" "gh api -X PUT repos/acme/widget/pulls/7/merge")
if denied "$out"; then fail "#1181 a REST merge in an ungated repository was refused: $out"; else pass; fi
rm -rf "$dir"

echo "changelog record: a repository flag in front of the subcommand (claude-config#1186)"

# Before #1186 a merge with -R in front of pr merge merged with no record read.
dir=$(make_repo acme/widget "$UNTAGGED" "$REGISTRY")
for c in "gh -R acme/widget pr merge 7 --squash" "gh --repo=acme/widget api -X PUT 'repos/{owner}/{repo}/pulls/7/merge'" \
         "sudo env GH_TOKEN=x rtk gh -Racme/widget pr merge 7"; do
  out=$(run_hook "$dir" "$c")
  if denied "$out" && says "$out" "changelog/visible"; then pass; else fail "#1186 an untagged PR merged with the repository flag in front [$c]: $out"; fi
done
# The failure path: a repository flag gh cannot read is refused by name.
out=$(run_hook "$dir" "gh -R nonsense pr merge 7")
if denied "$out" && says "$out" 'as \"nonsense\"' && says "$out" "ALLOW_UNTAGGED_MERGE=1"; then pass
else fail "#1186 a merge naming an unreadable repository was not refused by name: $out"; fi
rm -rf "$dir"
dir=$(make_repo acme/widget "$TAGGED" "$REGISTRY")
out=$(run_hook "$dir" "gh -R acme/widget pr merge 7 --squash")
if denied "$out"; then fail "#1186 a tagged PR merged with the repository flag in front was refused: $out"; else pass; fi
rm -rf "$dir"

echo "changelog record: the announce label (claude-config#3665)"

# A fourth label, for a change whose agents must or can act differently. Its pull request carries the
# sentence for managers and the whole post for agents. It is in use only in a repository whose
# registry entry names an announcements channel, and refused at merge everywhere else. Every
# repository and channel id here is invented.
REGISTRY_ANNOUNCES='{"repos":[{"name":"Widget","repo":"acme/widget","changelogFrom":"2026-01-01","announceChannel":"C0000TEST02"}]}'
# The managers' channel is the file's own key and says nothing about announcements.
REGISTRY_MANAGERS_ONLY='{"repos":[{"name":"Widget","repo":"acme/widget","changelogFrom":"2026-01-01"}],"slackChannel":"C0000TEST01"}'
REGISTRY_BAD_ANNOUNCE='{"repos":[{"name":"Widget","repo":"acme/widget","changelogFrom":"2026-01-01","announceChannel":"#announcements"}]}'
pr_json() {  # $1 = the label, $2 = the body as a JSON string's inside
  printf '{"number":7,"url":"https://github.com/acme/widget/pull/7","author":{"login":"dwright-pennie"},"labels":[{"name":"%s"}],"body":"%s"}' "$1" "$2"
}
A_SENTENCE='prose\n\n## Changelog\nAgents can now hand a call back to the queue.'
A_POST='## Announcement\n@here\n**Handing a call back**\n\nYou can now hand a call back to the queue.\n\n- Press Hand back\n- Pick a reason\n\nMore in [the guide](https://example.com/guide).\n\n## Testing\nran it'
ANNOUNCE_FULL="$(pr_json changelog/announce "$A_SENTENCE\\n\\n$A_POST")"
ANNOUNCE_NO_POST="$(pr_json changelog/announce "$A_SENTENCE")"
ANNOUNCE_NO_SENTENCE="$(pr_json changelog/announce "prose\\n\\n$A_POST")"
ANNOUNCE_DASHED="$(pr_json changelog/announce "$A_SENTENCE\\n\\n## Announcement\\n@here\\nHand back - then pick a reason.")"
ANNOUNCE_NO_OPENER="$(pr_json changelog/announce "$A_SENTENCE\\n\\n## Announcement\\nHi team\\nYou can now hand a call back.")"
VISIBLE_WITH_POST="$(pr_json changelog/visible "$A_SENTENCE\\n\\n$A_POST")"
# approved_on_record <fixture dir>: Dan's approval of the wording in that fixture's pull request, as
# a line on the fixture's own record, its hash asked of the library that owns it (claude-config#3666).
approved_on_record() {
  mkdir -p "$1/approvals"
  printf '{"kind": "approved", "repo": "acme/widget", "hash": "%s"}\n' \
    "$(jq -r '.body' "$1/pr.json" | node "$HOOK_DIR/lib/changelog-entry.js" announcement-hash --body | jq -r '.hash')" >> "$1/approvals/record.jsonl"
}

# R7, and what "ships inert" means: while no registry entry names a channel, a pull request carrying
# the label is refused however complete its writing. Each registry here is one a Mac has today.
for reg in "$REGISTRY" "$REGISTRY_MANAGERS_ONLY"; do
  dir=$(make_repo acme/widget "$ANNOUNCE_FULL" "$reg")
  out=$(run_hook "$dir" "$MERGE 7 --squash")
  if denied "$out"; then pass; else fail "#3665 an announce PR merged in a repository whose registry entry names no announcements channel: $out"; fi
  if says "$out" "changelog/announce" && says "$out" "announceChannel"; then pass; else fail "#3665 the refusal does not name the label and the registry key: $out"; fi
  # A lost key looks the same, so it says so and says how to check.
  if says "$out" "lost its announceChannel key" && says "$out" "dev-update-registry.js announce-channel acme/widget"; then pass
  else fail "#3665 the refusal does not say a lost key looks the same, or how to check: $out"; fi
  # It never sends the reader to the label it has just refused.
  if says "$out" "use one of: changelog/visible, changelog/technical, changelog/none."; then pass; else fail "#3665 the refusal does not name the labels this repository takes: $out"; fi
  rm -rf "$dir"
done
# An incomplete one is told the same thing, not to finish writing for a label it cannot use.
dir=$(make_repo acme/widget "$ANNOUNCE_NO_POST" "$REGISTRY")
out=$(run_hook "$dir" "$MERGE 7 --squash")
if denied "$out" && says "$out" "is not in use here"; then pass; else fail "#3665 an incomplete announce PR where the label is not in use was not told so: $out"; fi
rm -rf "$dir"

# R7 and R1, still possible: where the entry names a channel, one carrying both pieces merges, once
# Dan has approved its wording (claude-config#3666, below).
dir=$(make_repo acme/widget "$ANNOUNCE_FULL" "$REGISTRY_ANNOUNCES")
approved_on_record "$dir"
out=$(run_hook "$dir" "$MERGE 7 --squash")
if denied "$out"; then fail "#3665 an announce PR carrying the sentence and the post was refused where the repository announces: $out"; else pass; fi
rm -rf "$dir"
# And the other three labels merge there as they always did.
for tagged in "$TAGGED" "$TECHNICAL" "$NONE_LBL"; do
  dir=$(make_repo acme/widget "$tagged" "$REGISTRY_ANNOUNCES")
  out=$(run_hook "$dir" "$MERGE 7 --squash")
  if denied "$out"; then fail "#3665 a PR under one of the first three labels was refused where the repository announces: $out"; else pass; fi
  rm -rf "$dir"
done

# R1: no post for agents, no merge. And no sentence for managers, no merge.
dir=$(make_repo acme/widget "$ANNOUNCE_NO_POST" "$REGISTRY_ANNOUNCES")
out=$(run_hook "$dir" "$MERGE 7 --squash")
if denied "$out"; then pass; else fail "#3665 an announce PR with no Announcement block merged: $out"; fi
if says "$out" "## Announcement" && says "$out" "@here"; then pass; else fail "#3665 the refusal does not name the heading to add and how the post opens: $out"; fi
rm -rf "$dir"
dir=$(make_repo acme/widget "$ANNOUNCE_NO_SENTENCE" "$REGISTRY_ANNOUNCES")
out=$(run_hook "$dir" "$MERGE 7 --squash")
if denied "$out" && says "$out" "## Changelog"; then pass; else fail "#3665 an announce PR with no Changelog sentence merged, or was not told what to add: $out"; fi
rm -rf "$dir"

# What the post may hold is the gate's to judge: a dash as punctuation, and a post that does not
# open with @here.
dir=$(make_repo acme/widget "$ANNOUNCE_DASHED" "$REGISTRY_ANNOUNCES")
out=$(run_hook "$dir" "$MERGE 7 --squash")
if denied "$out" && says "$out" "dash as punctuation" && says "$out" "Hand back - then pick a reason."; then pass
else fail "#3665 a post with a dash as punctuation merged, or the refusal does not quote the line: $out"; fi
rm -rf "$dir"
dir=$(make_repo acme/widget "$ANNOUNCE_NO_OPENER" "$REGISTRY_ANNOUNCES")
out=$(run_hook "$dir" "$MERGE 7 --squash")
if denied "$out" && says "$out" "does not open with @here"; then pass; else fail "#3665 a post that does not open with @here merged: $out"; fi
rm -rf "$dir"

# Another label over an Announcement block: a post written and never drafted.
dir=$(make_repo acme/widget "$VISIBLE_WITH_POST" "$REGISTRY_ANNOUNCES")
out=$(run_hook "$dir" "$MERGE 7 --squash")
if denied "$out" && says "$out" "carries an Announcement block" && says "$out" "relabel it changelog/announce"; then pass
else fail "#3665 a visible PR carrying an Announcement block merged where the repository announces: $out"; fi
rm -rf "$dir"
dir=$(make_repo acme/widget "$VISIBLE_WITH_POST" "$REGISTRY")
out=$(run_hook "$dir" "$MERGE 7 --squash")
if denied "$out" && says "$out" "delete the block"; then pass; else fail "#3665 a visible PR carrying an Announcement block merged where the repository does not announce: $out"; fi
if says "$out" "relabel it changelog/announce"; then fail "#3665 a repository that does not announce was told to relabel to the label it is refused for: $out"; else pass; fi
rm -rf "$dir"

# The labels a refusal offers are the ones THAT repository takes.
dir=$(make_repo acme/widget "$UNTAGGED" "$REGISTRY_ANNOUNCES")
out=$(run_hook "$dir" "$MERGE 7 --squash")
if denied "$out" && says "$out" "changelog/visible, changelog/technical, changelog/none, changelog/announce"; then pass
else fail "#3665 an untagged PR where the repository announces was not offered all four labels: $out"; fi
rm -rf "$dir"
dir=$(make_repo acme/widget "$UNTAGGED" "$REGISTRY")
out=$(run_hook "$dir" "$MERGE 7 --squash")
if denied "$out" && ! says "$out" "changelog/announce"; then pass; else fail "#3665 an untagged PR where the repository does not announce was offered the announce label: $out"; fi
rm -rf "$dir"

# An announcements channel that is not a channel id is a config error, refused for every merge there
# with its own message, as a start date that is not a date is: read as "names none" it would switch
# the label off in silence (L98).
for tagged in "$TECHNICAL" "$ANNOUNCE_FULL"; do
  dir=$(make_repo acme/widget "$tagged" "$REGISTRY_BAD_ANNOUNCE")
  out=$(run_hook "$dir" "$MERGE 7 --squash")
  if denied "$out" && says "$out" "not a Slack channel id" && says "$out" "#announcements" && says "$out" "announceChannel"; then pass
  else fail "#3665 a merge went through, or was refused in other words, where the announcements channel is not a channel id: $out"; fi
  rm -rf "$dir"
done
# No refusal of a pull request carrying the announce label offers the override, which does not cover
# it: not the refusals that exist only for that label, and not the ones it shares with a visible
# pull request (its Changelog sentence, a second label). Each says the override does not cover it,
# so nobody spends a merge finding that out.
ANNOUNCE_AND_VISIBLE='{"number":7,"url":"https://github.com/acme/widget/pull/7","author":{"login":"dwright-pennie"},"labels":[{"name":"changelog/announce"},{"name":"changelog/visible"}],"body":"prose\n\n## Changelog\nAgents can now hand a call back to the queue."}'
for each in "$ANNOUNCE_FULL|$REGISTRY" "$ANNOUNCE_NO_SENTENCE|$REGISTRY_ANNOUNCES" "$ANNOUNCE_AND_VISIBLE|$REGISTRY_ANNOUNCES"; do
  dir=$(make_repo acme/widget "${each%%|*}" "${each#*|}")
  out=$(run_hook "$dir" "$MERGE 7 --squash")
  if denied "$out" && ! says "$out" "Deliberate override" && ! says "$out" "re-run with ALLOW_UNTAGGED_MERGE"; then pass
  else fail "#3665 a refusal of a pull request carrying the announce label offers the override: $out"; fi
  if says "$out" "ALLOW_UNTAGGED_MERGE=1 does not cover"; then pass; else fail "#3665 a refusal of a pull request carrying the announce label does not say the override does not cover it: $out"; fi
  rm -rf "$dir"
done

# THE OVERRIDE DOES NOT COVER AN ANNOUNCEMENT (Dan, 2026-11-25: "No, announce is exempt"). The gate
# left on ALLOW_UNTAGGED_MERGE=1 before it read anything, so a merge carrying it took an announce
# pull request with no post (R1) or in a repository naming no channel (R7). Now, in a repository the
# registry gates, the pull request is read with the override typed, and one carrying the announce
# label is judged in full, as if the override were not there.
OVERRIDDEN="ALLOW_UNTAGGED_MERGE=1 $MERGE 7 --squash"
# R1 under the override: no post, no sentence, a post that does not open with @here, a second label.
for each in "$ANNOUNCE_NO_POST|## Announcement" "$ANNOUNCE_NO_SENTENCE|## Changelog" "$ANNOUNCE_NO_OPENER|does not open with @here" "$ANNOUNCE_DASHED|dash as punctuation" "$ANNOUNCE_AND_VISIBLE|more than one changelog label"; do
  dir=$(make_repo acme/widget "${each%%|*}" "$REGISTRY_ANNOUNCES")
  out=$(run_hook "$dir" "$OVERRIDDEN")
  if denied "$out" && says "$out" "${each#*|}"; then pass
  else fail "#3665 R1: the override let an announce pull request merge that would be refused without it (wanted a refusal saying '${each#*|}'): $out"; fi
  if says "$out" "ALLOW_UNTAGGED_MERGE=1 does not cover"; then pass; else fail "#3665 the refusal under the override does not say the override does not cover an announcement: $out"; fi
  rm -rf "$dir"
done
# R7 under the override: complete writing, and a repository whose entry names no channel.
for reg in "$REGISTRY" "$REGISTRY_MANAGERS_ONLY"; do
  dir=$(make_repo acme/widget "$ANNOUNCE_FULL" "$reg")
  out=$(run_hook "$dir" "$OVERRIDDEN")
  if denied "$out" && says "$out" "is not in use here" && says "$out" "ALLOW_UNTAGGED_MERGE=1 does not cover"; then pass
  else fail "#3665 R7: the override let an announce pull request merge in a repository whose registry entry names no announcements channel: $out"; fi
  rm -rf "$dir"
done
# And one whose channel is not a channel id: the announce pull request is refused in those words,
# while any other pull request there takes the override as it always did.
dir=$(make_repo acme/widget "$ANNOUNCE_FULL" "$REGISTRY_BAD_ANNOUNCE")
out=$(run_hook "$dir" "$OVERRIDDEN")
if denied "$out" && says "$out" "not a Slack channel id" && says "$out" "ALLOW_UNTAGGED_MERGE=1 does not cover"; then pass
else fail "#3665 the override let an announce pull request merge where the announcements channel is not a channel id: $out"; fi
rm -rf "$dir"
dir=$(make_repo acme/widget "$TECHNICAL" "$REGISTRY_BAD_ANNOUNCE")
out=$(run_hook "$dir" "$OVERRIDDEN")
if [ -z "$out" ]; then pass; else fail "#3665 the override no longer covers a pull request that is not an announcement where the channel is not a channel id: $out"; fi
rm -rf "$dir"
# Still possible: an announce pull request carrying both pieces, its wording approved, merges with
# the override typed too.
dir=$(make_repo acme/widget "$ANNOUNCE_FULL" "$REGISTRY_ANNOUNCES")
approved_on_record "$dir"
out=$(run_hook "$dir" "$OVERRIDDEN")
if [ -z "$out" ]; then pass; else fail "#3665 a complete announce pull request was refused, or drew a notice, with the override typed where the repository announces: $out"; fi
rm -rf "$dir"
# For every other pull request the override is what it always was: the merge goes through and
# nothing is said. A record the gate would refuse under each of the other labels, and no label.
for other in "$UNTAGGED" "$NOBLOCK" "$VISIBLE_WITH_POST" "$TECHNICAL"; do
  dir=$(make_repo acme/widget "$other" "$REGISTRY_ANNOUNCES")
  out=$(run_hook "$dir" "$OVERRIDDEN")
  if [ -z "$out" ]; then pass; else fail "#3665 the override no longer lets a pull request that is not an announcement through in silence: $out"; fi
  rm -rf "$dir"
done
# A repository the registry does not gate is none of this: nothing is read and nothing is said.
dir=$(make_repo acme/widget "" "$REGISTRY_OTHER")
out=$(run_hook "$dir" "$OVERRIDDEN")
if [ -z "$out" ]; then pass; else fail "#3665 the override drew a refusal or a notice in a repository the registry does not gate: $out"; fi
rm -rf "$dir"

# LET THROUGH, SAID OUT LOUD (Dan, 2026-11-25). The override is the remedy the gate itself names for a
# pull request it cannot read, so there it still lets the merge through. But a pull request nobody
# read may be an announcement, and a silent allow would say it was not: the allow carries one
# sentence, to the person and to the session, that an announcement could not be ruled out. The
# notice's second copy, on stderr for the debug log, is dropped in these runs so this suite's own
# output stays its verdicts.
said_out_loud() {  # $1 = the hook output, $2 = what could not be read ; true when it is an allow carrying the notice
  ! denied "$1" && says "$1" '"systemMessage"' && says "$1" '"additionalContext"' \
    && says "$1" "$2" && says "$1" "an announcement" && says "$1" "could not be ruled out"
}
dir=$(make_repo acme/widget "" "$REGISTRY")
out=$(run_hook "$dir" "$OVERRIDDEN" 2>/dev/null)
if said_out_loud "$out" "gave no answer about"; then pass
else fail "#3665 with the override typed and the pull request unreadable, the merge was refused, or let through with nothing said about an announcement: $out"; fi
rm -rf "$dir"
# An answer about another repository's pull request is not a reading of this one.
dir=$(make_repo acme/widget "$WRONG_REPO" "$REGISTRY")
out=$(run_hook "$dir" "$OVERRIDDEN" 2>/dev/null)
if said_out_loud "$out" "the only answer gh gave was about" && says "$out" "someone/else"; then pass
else fail "#3665 with the override typed and an answer about another repository, nothing was said about an announcement: $out"; fi
rm -rf "$dir"
# Where the registry cannot say whether the repository is gated, the pull request is never read
# either, and the same is said.
for reg in MISSING 'not json' "$REGISTRY_NO_DATE"; do
  dir=$(make_repo acme/widget "$ANNOUNCE_NO_POST" "$reg")
  out=$(run_hook "$dir" "$OVERRIDDEN" 2>/dev/null)
  if said_out_loud "$out" "registry"; then pass
  else fail "#3665 with the override typed and a registry that cannot say whether the repository is gated ($reg), nothing was said about an announcement: $out"; fi
  rm -rf "$dir"
done
# While the refusals it always gave still do.
dir=$(make_repo acme/widget "$UNTAGGED" "$REGISTRY")
out=$(run_hook "$dir" "$MERGE 7 --squash")
if says "$out" "ALLOW_UNTAGGED_MERGE=1"; then pass; else fail "#3665 the untagged refusal lost its override line: $out"; fi
rm -rf "$dir"

# A judge that fails is not a record that passed (L98). The gate read "nothing printed" as the
# passing answer, so a library that threw while judging let every merge through. Driven with a copy
# of the hooks whose judge throws, and whose every other answer is the real library's.
BROKEN="$(mktemp -d)"
cp "$HOOK" "$BROKEN/"
cp -R "$HOOK_DIR/lib" "$BROKEN/lib"
mv "$BROKEN/lib/changelog-entry.js" "$BROKEN/lib/changelog-entry.real.js"
cat > "$BROKEN/lib/changelog-entry.js" <<'JS'
const real = require('./changelog-entry.real.js');
module.exports = Object.assign({}, real, { gateRefusal: function () { throw new Error('the judge broke'); } });
JS
dir=$(make_repo acme/widget "$TAGGED" "$REGISTRY")
out=$(HOOK="$BROKEN/require-changelog-tag.sh" run_hook "$dir" "$MERGE 7 --squash")
if denied "$out" && says "$out" "produced no verdict at all"; then pass
else fail "#3665 a merge went through, or was refused in other words, when the judge itself failed: $out"; fi
rm -rf "$dir"
# The same copy with the judge left alone takes the same pull request, so it is the judge that the
# refusal above was about.
cp "$BROKEN/lib/changelog-entry.real.js" "$BROKEN/lib/changelog-entry.js"
dir=$(make_repo acme/widget "$TAGGED" "$REGISTRY")
out=$(HOOK="$BROKEN/require-changelog-tag.sh" run_hook "$dir" "$MERGE 7 --squash")
if denied "$out"; then fail "#3665 the copied hooks refused a correctly tagged PR with a working judge: $out"; else pass; fi
rm -rf "$dir"
# Under the override a judge that fails is judged by what could still be told. A pull request
# carrying the announce label is refused, since the override does not cover it and nothing judged
# its post. One that does not carry it takes the override as it always did.
cat > "$BROKEN/lib/changelog-entry.js" <<'JS'
const real = require('./changelog-entry.real.js');
module.exports = Object.assign({}, real, { gateRefusal: function () { throw new Error('the judge broke'); } });
JS
dir=$(make_repo acme/widget "$ANNOUNCE_FULL" "$REGISTRY_ANNOUNCES")
out=$(HOOK="$BROKEN/require-changelog-tag.sh" run_hook "$dir" "$OVERRIDDEN")
if denied "$out" && says "$out" "produced no verdict at all" && says "$out" "ALLOW_UNTAGGED_MERGE=1 does not cover"; then pass
else fail "#3665 the override let an announce pull request merge when the judge itself failed: $out"; fi
rm -rf "$dir"
dir=$(make_repo acme/widget "$TAGGED" "$REGISTRY_ANNOUNCES")
out=$(HOOK="$BROKEN/require-changelog-tag.sh" run_hook "$dir" "$OVERRIDDEN")
if [ -z "$out" ]; then pass; else fail "#3665 the override no longer covers a pull request that is not an announcement when the judge fails: $out"; fi
rm -rf "$dir"
# And when not even the label can be told, the merge goes through and that is said out loud.
cat > "$BROKEN/lib/changelog-entry.js" <<'JS'
const real = require('./changelog-entry.real.js');
module.exports = Object.assign({}, real, { carriesAnnounce: function () { throw new Error('the label reader broke'); } });
JS
dir=$(make_repo acme/widget "$ANNOUNCE_NO_POST" "$REGISTRY_ANNOUNCES")
out=$(HOOK="$BROKEN/require-changelog-tag.sh" run_hook "$dir" "$OVERRIDDEN" 2>/dev/null)
if said_out_loud "$out" "failed while reading the pull request's labels"; then pass
else fail "#3665 with the override typed and the label reader failing, nothing was said about an announcement: $out"; fi
rm -rf "$dir" "$BROKEN"

echo "changelog record: the wording Dan approved is the wording that merges (claude-config#3666)"

# R2. A change labelled changelog/announce never merges from a session unless Dan approved that
# exact wording after it was opened in front of him. The gate hashes the Announcement block as
# GitHub holds it and asks lib/announce-approval.py, whose own suite (test-announce-approval.sh)
# holds what counts as his approval. Every refusal is a deny, never a permission prompt.
asks_dan() {  # $1 = the hook output ; true when it is a refusal telling the session to ask him with the picker
  denied "$1" && ! says "$1" '"permissionDecision": "ask"' && says "$1" "AskUserQuestion" && says "$1" "Approve the wording" \
    && says "$1" "--front-window" && says "$1" "ALLOW_UNTAGGED_MERGE=1 does not cover"
}
dir=$(make_repo acme/widget "$ANNOUNCE_FULL" "$REGISTRY_ANNOUNCES")
out=$(run_hook "$dir" "$MERGE 7 --squash")
if asks_dan "$out" && says "$out" "Dan has not approved this wording for acme/widget"; then pass
else fail "#3666 R2: an announce pull request merged, or was refused in other words, with wording Dan never approved: $out"; fi
# The override does not cover it.
out=$(run_hook "$dir" "$OVERRIDDEN")
if asks_dan "$out"; then pass; else fail "#3666 R2: the override let an announce pull request merge with wording Dan never approved: $out"; fi
if [ -e "$dir/approvals/record.jsonl" ]; then fail "#3666 a refused merge wrote to the record: $(cat "$dir/approvals/record.jsonl")"; else pass; fi
# Still possible: once the wording is on the record it merges, in a session that never asked him.
approved_on_record "$dir"
out=$(run_hook "$dir" "$MERGE 7 --squash")
if [ -z "$out" ]; then pass; else fail "#3666 R2 still possible: wording Dan approved was refused, or drew a notice: $out"; fi
# The same description as GitHub returns it once edited on its own page (CRLF) is the same wording,
# and so is one edited anywhere outside the block.
python3 - "$dir/pr.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["body"] = d["body"].replace("ran it", "ran it twice, and reworded the summary").replace("\n", "\r\n")
json.dump(d, open(sys.argv[1], "w"))
PY
out=$(run_hook "$dir" "$MERGE 7 --squash")
if [ -z "$out" ]; then pass; else fail "#3666 an edit elsewhere in the description, or GitHub's line endings, was refused as other wording: $out"; fi
# A wording edit after his approval, by any route (the description is whatever GitHub holds at the
# merge), is other wording.
python3 - "$dir/pr.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["body"] = d["body"].replace("Pick a reason", "Pick any reason")
json.dump(d, open(sys.argv[1], "w"))
PY
out=$(run_hook "$dir" "$MERGE 7 --squash")
if asks_dan "$out"; then pass; else fail "#3666 R2: wording edited after Dan approved it merged: $out"; fi
rm -rf "$dir"

# The whole route, from his answer to the merge: the session wrote the post to a file, opened it in
# front of him and asked the picker, and the gate reads that from the session's transcript, writes
# his approval to the record, and lets the merge through.
if . "$HOOK_DIR/lib/announce-approval-fixture.sh" 2>/dev/null && declare -F aaf_shown >/dev/null; then pass
else fail "#3666 lib/announce-approval-fixture.sh is missing beside this suite, so no session could be built"; aaf_shown() { :; }; aaf_talk() { :; }; fi
# The post in ANNOUNCE_FULL's Announcement block, as the file the session shows him holds it.
WORDING='@here
**Handing a call back**

You can now hand a call back to the queue.

- Press Hand back
- Pick a reason

More in [the guide](https://example.com/guide).'
dir=$(make_repo acme/widget "$ANNOUNCE_FULL" "$REGISTRY_ANNOUNCES")
shown_file="$(aaf_shown "$dir/wording" "$dir/talk.jsonl" "$WORDING")"
out=$(TALK="$dir/talk.jsonl" run_hook "$dir" "$MERGE 7 --squash")
if asks_dan "$out"; then pass; else fail "#3666 R2: wording opened in front of Dan and never approved merged: $out"; fi
aaf_talk "$dir/talk.jsonl" ask acme/widget "$shown_file" "Not yet"
out=$(TALK="$dir/talk.jsonl" run_hook "$dir" "$MERGE 7 --squash")
if asks_dan "$out"; then pass; else fail "#3666 R2: Dan's Not yet let the merge through: $out"; fi
aaf_talk "$dir/talk.jsonl" bash "$AAF_BBEDIT --front-window $shown_file"
aaf_talk "$dir/talk.jsonl" ask acme/widget "$shown_file"
# A subagent's merge counts his picker for that call and writes nothing.
out=$(TALK="$dir/talk.jsonl" AGENT=1 run_hook "$dir" "$MERGE 7 --squash")
if [ -z "$out" ] && ! grep -q '"kind": "approved"' "$dir/approvals/record.jsonl" 2>/dev/null; then pass
else fail "#3666 a subagent's merge was refused on Dan's picker, or wrote his approval to the record: $out $(cat "$dir/approvals/record.jsonl" 2>/dev/null)"; fi
out=$(TALK="$dir/talk.jsonl" run_hook "$dir" "$MERGE 7 --squash")
if [ -z "$out" ]; then pass; else fail "#3666 R2 still possible: the wording Dan approved in this session's picker was refused: $out"; fi
if grep -q '"kind": "approved"' "$dir/approvals/record.jsonl" 2>/dev/null && grep -q '"repo": "acme/widget"' "$dir/approvals/record.jsonl"; then pass
else fail "#3666 his approval was not written to the record: $(cat "$dir/approvals/record.jsonl" 2>/dev/null)"; fi
# So a later session, holding no picker, merges it overnight.
out=$(run_hook "$dir" "$MERGE 7 --squash")
if [ -z "$out" ]; then pass; else fail "#3666 R2 still possible: a later session was refused wording already on the record: $out"; fi

# A merged announcement's wording is marked used, with each issue it closes and its milestone, for
# the later check that a feature Dan said yes to announcing does not finish under another label.
used_line() { grep '"kind": "used"' "$1/approvals/record.jsonl" 2>/dev/null | tail -1; }
if says "$(used_line "$dir")" '"pr": 7' && says "$(used_line "$dir")" '"closes": null' && says "$(used_line "$dir")" '"unread"'; then pass
else fail "#3666 a merge whose closing issues GitHub did not give was not marked used with them unread: $(cat "$dir/approvals/record.jsonl" 2>/dev/null)"; fi
CLOSING='{"data":{"repository":{"pullRequest":{"closingIssuesReferences":{"nodes":[{"number":12,"repository":{"nameWithOwner":"acme/widget"},"milestone":{"title":"Hand back"}},{"number":13,"repository":{"nameWithOwner":"acme/widget"},"milestone":null}]}}}}}'
out=$(FAKE_NODE_JSON="$CLOSING" run_hook "$dir" "$MERGE 7 --squash")
if [ -z "$out" ]; then pass; else fail "#3666 the merge was refused, or drew a notice, once its closing issues could be read: $out"; fi
if says "$(used_line "$dir")" '"issue": 12' && says "$(used_line "$dir")" '"milestone": "Hand back"' && says "$(used_line "$dir")" '"issue": 13' && says "$(used_line "$dir")" '"milestone": null'; then pass
else fail "#3666 the used line does not name each issue the pull request closes with its milestone: $(used_line "$dir")"; fi

# ONE APPROVAL COVERS ONE PULL REQUEST (Dan, 2026-11-25, by picker: "One approval, one pull
# request"). Pull request 7 used his approval above. Pull request 8, carrying the same wording, is
# not approved and asks him again, in this session (which holds the picker 7 used) and in a later one.
pr_number() {  # $1 = fixture dir, $2 = the number its pull request now carries
  jq -c --argjson n "$2" '.number = $n | .url = "https://github.com/acme/widget/pull/\($n)"' "$1/pr.json" > "$1/pr.json.new" && mv "$1/pr.json.new" "$1/pr.json"
}
used_by() { grep -c "\"kind\": \"used\".*\"pr\": $2[,}]" "$1/approvals/record.jsonl" 2>/dev/null || true; }
if grep '"kind": "used"' "$dir/approvals/record.jsonl" | head -1 | grep -q '"claim": true.*"pr": 7'; then pass
else fail "#3666 the first line recording pull request 7's use of the approval is not its claim: $(cat "$dir/approvals/record.jsonl")"; fi
pr_number "$dir" 8
for talk in "" "$dir/talk.jsonl"; do
  out=$(TALK="$talk" run_hook "$dir" "$MERGE 8 --squash")
  if asks_dan "$out" && says "$out" "used by another pull request" && says "$out" "pull request 7 used that approval" && says "$out" "one approval covers one pull request"; then pass
  else fail "#3666 R2: a second pull request merged, or was refused in other words, on wording whose one approval pull request 7 used (transcript '${talk:-none}'): $out"; fi
done
if [ "$(used_by "$dir" 8)" = 0 ]; then pass; else fail "#3666 a refused pull request was recorded as using the approval: $(cat "$dir/approvals/record.jsonl")"; fi
# The override does not clear it.
out=$(run_hook "$dir" "ALLOW_UNTAGGED_MERGE=1 $MERGE 8 --squash")
if asks_dan "$out" && says "$out" "used by another pull request"; then pass
else fail "#3666 R2: the override let a second pull request merge on an approval another one used: $out"; fi
# Still possible: the pull request that used it tries its merge again, and nothing more is recorded.
pr_number "$dir" 7
before=$(used_by "$dir" 7)
out=$(run_hook "$dir" "$MERGE 7 --squash")
if [ -z "$out" ] && [ "$(used_by "$dir" 7)" = "$before" ]; then pass
else fail "#3666 R2 still possible: the pull request that used the approval was refused its merge again, or was recorded again: $out $(cat "$dir/approvals/record.jsonl")"; fi
# Still possible: asked again, his second approval of the same wording covers the second pull request.
aaf_talk "$dir/talk.jsonl" bash "$AAF_BBEDIT --front-window $shown_file"
aaf_talk "$dir/talk.jsonl" ask acme/widget "$shown_file"
pr_number "$dir" 8
out=$(TALK="$dir/talk.jsonl" run_hook "$dir" "$MERGE 8 --squash")
if [ -z "$out" ] && [ "$(used_by "$dir" 8)" -ge 1 ]; then pass
else fail "#3666 R2 still possible: a second pull request was refused after Dan approved the same wording a second time, or was not recorded as using it: $out $(cat "$dir/approvals/record.jsonl")"; fi
rm -rf "$dir"

# A USE THAT CANNOT BE RECORDED REFUSES THE MERGE (Dan, 2026-11-25, by picker: "Refuse the merge").
# The record holds his approval and can no longer be written: the merge is refused saying what could
# not be written and where, and the remedy is the record, not asking him again.
dir=$(make_repo acme/widget "$ANNOUNCE_FULL" "$REGISTRY_ANNOUNCES")
approved_on_record "$dir"
chmod 400 "$dir/approvals/record.jsonl"; chmod 500 "$dir/approvals"
out=$(run_hook "$dir" "$MERGE 7 --squash")
chmod 700 "$dir/approvals"; chmod 600 "$dir/approvals/record.jsonl"
if denied "$out" && says "$out" "could not be recorded" && says "$out" "$dir/approvals/record.jsonl, could not be written" \
  && says "$out" "run the same merge again" && ! says "$out" "AskUserQuestion" && ! says "$out" "is not wording Dan approved" \
  && says "$out" "ALLOW_UNTAGGED_MERGE=1 does not cover"; then pass
else fail "#3666 R2: an announce pull request merged, or was refused in other words, when its use of Dan's approval could not be recorded: $out"; fi
out=$(run_hook "$dir" "ALLOW_UNTAGGED_MERGE=1 $MERGE 7 --squash")
if [ -z "$out" ] && [ "$(used_by "$dir" 7)" -ge 1 ]; then pass
else fail "#3666 R2 still possible: the same merge was refused once the record could be written, or was not recorded: $out"; fi
rm -rf "$dir"

# A check that fails is not an approval (L98). Driven with a copy of the hooks whose approval
# library throws, and whose every other answer is the real one.
BROKEN="$(mktemp -d)"
cp "$HOOK" "$BROKEN/"
cp -R "$HOOK_DIR/lib" "$BROKEN/lib"
printf 'raise RuntimeError("the approval reader broke")\n' > "$BROKEN/lib/announce-approval.py"
dir=$(make_repo acme/widget "$ANNOUNCE_FULL" "$REGISTRY_ANNOUNCES")
approved_on_record "$dir"
out=$(HOOK="$BROKEN/require-changelog-tag.sh" run_hook "$dir" "$MERGE 7 --squash")
if denied "$out" && says "$out" "produced no verdict" && says "$out" "lib/announce-approval.py" && says "$out" "ALLOW_UNTAGGED_MERGE=1 does not cover"; then pass
else fail "#3666 an announce pull request merged, or was refused in other words, when the approval check itself failed: $out"; fi
# The same copy takes any other pull request, so it is the approval check the refusal was about.
printf '%s' "$TAGGED" > "$dir/pr.json"
out=$(HOOK="$BROKEN/require-changelog-tag.sh" run_hook "$dir" "$MERGE 7 --squash")
if [ -z "$out" ]; then pass; else fail "#3666 a pull request that is no announcement was refused over the approval check: $out"; fi
rm -rf "$dir" "$BROKEN"

# No case above wrote this Mac's real record.
if [ "$(ls -la "${CLAUDE_HOME:-$HOME/.claude}/state/announce-approvals" 2>/dev/null | cksum)" = "$REAL_RECORD_BEFORE" ]; then pass
else fail "#3666 this Mac's real record of approved wording changed while the suite ran"; fi

echo "  $passed passed, $failed failed"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
