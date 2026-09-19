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
# (L362): repos.json lives in this repo, whose own slug is not in the registry, so the change that
# adds the date is not itself gated. ALLOW_UNTAGGED_MERGE=1 remains for anything else.
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
# The control, same fixture and same command with both readers present: it merges, so every
# refusal above is the reader's absence rather than a fixture that refuses everything (L159).
if denied "$(run_hook "$dir" "$MERGE 7 --repo acme/widget --squash")"; then
  fail "the control case refused a tagged merge, so the cases above prove nothing"
else pass; fi
rm -rf "$dir"

# And the one absence that is a genuine stand down stays one: with no registry there is no dev
# update for a record to feed, so there is no rule here to refuse over, whatever is missing
# from PATH (L324).
dir=$(make_repo acme/widget "$TAGGED" "$REGISTRY")
printf '%s' "$dir/no-such-registry.json" > "$dir/registry-path"
noread="$(bin_without "$dir" jq python3)"
run_hook_on "$dir" "$noread" "$MERGE 7 --repo acme/widget --squash"
if [ "$NOREAD_RC" -eq 0 ] && [ -z "$NOREAD_OUT" ]; then pass; else
  fail "a machine with no dev update tooling was refused over a rule that does not apply there (rc=$NOREAD_RC): $NOREAD_OUT"; fi
rm -rf "$dir"

echo "  $passed passed, $failed failed"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
