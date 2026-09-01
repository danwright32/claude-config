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

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HOOK_DIR/require-changelog-tag.sh"
MERGE="gh pr me""rge"
passed=0
failed=0

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
  [ "$f" != "0" ] && printf '%s\n' "$parser_out" | grep '  FAIL:'
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
esac
SH
  chmod +x "$dir/bin/gh"
  printf '%s' "$dir"
}

run_hook() {  # $1 = repo dir, $2 = command ; prints the hook's stdout
  printf '{"tool_input":{"command":%s},"cwd":%s}' \
    "$(printf '%s' "$2" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
    "$(printf '%s' "$1/repo" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
    | ( cd "$1/repo" \
        && PATH="$1/bin:$PATH" \
           FAKE_PR_JSON="$1/pr.json" \
           CHANGELOG_REGISTRY="$(cat "$1/registry-path")" \
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
  local prior found
  # `nocasematch` is a shell wide setting, so it is restored rather than switched off:
  # leaving it clear would be a silent change to any caller that had set it (L509).
  prior="$(shopt -p nocasematch)"
  shopt -s nocasematch
  # "$2" is quoted, so a needle is a literal here where `grep -qi` read it as a regex.
  [[ "$1" == *"$2"* ]] && found=0 || found=1
  eval "$prior"
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

# A repo listed but with no start date has not adopted the rule yet, and that
# includes the pull request that would add the date.
dir=$(make_repo acme/widget "$UNTAGGED" "$REGISTRY_NO_DATE")
if denied "$(run_hook "$dir" "$MERGE 7 --squash")"; then
  fail "a repo listed without a changelogFrom date was gated"
else pass; fi
rm -rf "$dir"

# The registry not being there at all means the dev update skill is not
# installed, so there is nothing to enforce.
dir=$(make_repo acme/widget "$UNTAGGED" MISSING)
if denied "$(run_hook "$dir" "$MERGE 7 --squash")"; then
  fail "a missing registry blocked the merge instead of standing down"
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

echo "  $passed passed, $failed failed"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
