#!/usr/bin/env bash
# The /pennie-dev-update registry lives on each Mac, never in this public repository
# (claude-config#1526).
#
# The registry names work repositories, the GitHub account that reads each one, and how each one
# deploys. It was tracked here as payload/skills/pennie-dev-update/repos.json, and this repository
# is public. It is now ~/.claude/skills/pennie-dev-update/repos.local.json, a name the sync treats as
# one Mac's own file (LOCAL_FILE_GLOBS in claude-sync): never sent, never deleted by an apply.
#
# What is held here, each part seen to fail before it was built (L1):
#   1. No registry is tracked in this repository, and the check that says so can see one.
#   2. The skill's scripts and the merge gate read ONE path, from ONE reader, and a missing
#      registry is refused by all of them with a message naming that path and what goes in it.
#   3. Moving the file cannot lose it. The sync deletes on a Mac whatever the payload stops
#      carrying, so the apply moves the installed copy to the local name BEFORE the mirror runs,
#      on whichever Mac pulls the change, and the gate then passes there.
#   4. The local file never travels: a send carries neither it nor a copy recreated under the old
#      name, and a pull leaves both alone.
#
# Every repository named here is invented (acme/...). No work repository name belongs in this file.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SCRIPT="$ROOT/claude-sync"
HOOK="$ROOT/payload/hooks/require-changelog-tag.sh"
READER="$ROOT/payload/hooks/lib/dev-update-registry.js"
GATHER="$ROOT/payload/skills/pennie-dev-update/gather.js"
LINT="$ROOT/payload/skills/pennie-dev-update/lint-post.js"
. "$ROOT/payload/hooks/lib/suite-deadline.sh" || {
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

for tool in git node jq python3 rsync; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "FAIL: $tool is not on PATH, so this suite cannot run."
    printf 'SUITE-RESULT passed=0 failed=1\n'
    exit 1
  fi
done

# Without the trailing slash TMPDIR carries on macOS, so every path built here is spelled the way the
# reader (node's path.join) normalises it, and a comparison is about the file rather than the slashes.
_tmp="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "${_tmp%/}/dev-update-registry.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
MERGE="gh pr me""rge"
REL_SKILL="skills/pennie-dev-update"
REL_OLD="$REL_SKILL/repos.json"
REL_NEW="$REL_SKILL/repos.local.json"
REGISTRY_JSON='{"repos":[{"name":"Widget","repo":"acme/widget","account":"acme-bot","deployRecord":"build_history","deployRecordFrom":"2026-01-01","changelogFrom":"2026-01-01"}]}'

# ---------------------------------------------------------------- 1. nothing tracked
# Every tracked file that is, or could be, a dev update registry: any JSON file directly in the
# skill's folder (its tests keep their fixtures under tests/), and any *.local.json anywhere, which
# is a Mac's own file by the sync's own definition and reaches a commit only by a forced add.
tracked_registries(){   # $1 = a git work tree
  git -C "$1" ls-files 2>/dev/null | grep -E '^payload/skills/pennie-dev-update/[^/]+\.json$|(^|/)[^/]*\.local\.json($|[.~])' || true
}
tracked="$(tracked_registries "$ROOT")"
check "no dev update registry is tracked in this repository (found: ${tracked:-none})" [ -z "$tracked" ]

# The check above can see one: a throwaway repository tracking each shape, and one tracking none.
G="$WORK/guard-repo"
git init -q "$G"
mkdir -p "$G/payload/skills/pennie-dev-update/tests" "$G/payload/hooks"
printf '{}\n' > "$G/payload/skills/pennie-dev-update/tests/fixture.json"
printf 'x\n' > "$G/payload/skills/pennie-dev-update/SKILL.md"
git -C "$G" add -A >/dev/null 2>&1
check "(control) a repository tracking no registry is clean" [ -z "$(tracked_registries "$G")" ]
printf '{"repos":[]}\n' > "$G/payload/skills/pennie-dev-update/repos.json"
printf '{"repos":[]}\n' > "$G/payload/hooks/repos.local.json"
printf '{"repos":[]}\n' > "$G/payload/skills/pennie-dev-update/repos.local.json.bak"
git -C "$G" add -f -A >/dev/null 2>&1
g_found="$(tracked_registries "$G")"
check "(control) a tracked repos.json in the skill folder is found" has "$g_found" "payload/skills/pennie-dev-update/repos.json"
check "(control) a force added *.local.json is found" has "$g_found" "payload/hooks/repos.local.json"
check "(control) and a force added copy of one" has "$g_found" "repos.local.json.bak"

# And the second line: git itself refuses to stage either name without a forced add.
check "the old registry name is ignored by git here" git -C "$ROOT" check-ignore -q --no-index "payload/$REL_OLD"
check "the local registry name is ignored by git here" git -C "$ROOT" check-ignore -q --no-index "payload/$REL_NEW"

# ---------------------------------------------------------------- 2. one path, one reader
# A home with the skill installed and no registry.
H1="$WORK/home one"
mkdir -p "$H1/.claude/$REL_SKILL"
WANT1="$H1/.claude/$REL_NEW"

reader_path="$(HOME="$H1" node "$READER" path 2>&1)"
check "the reader names the registry's one home ($reader_path)" [ "$reader_path" = "$WANT1" ]

# A fake gh, and a checkout of an invented repository, for the gate.
FAKEBIN="$WORK/fakebin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"auth status"*) printf 'Logged in to github.com account acme-bot (keyring)\n' ;;
  *"auth token -u "*) printf 'tok\n' ;;
  *"pr view"*) cat "$FAKE_PR_JSON" ;;
esac
SH
chmod +x "$FAKEBIN/gh"
CHECKOUT="$WORK/checkout"
git init -q "$CHECKOUT"
git -C "$CHECKOUT" remote add origin "https://github.com/acme/widget.git"
TAGGED='{"number":7,"url":"https://github.com/acme/widget/pull/7","author":{"login":"acme-dev"},"labels":[{"name":"changelog/technical"}],"body":"prose"}'
UNTAGGED='{"number":7,"url":"https://github.com/acme/widget/pull/7","author":{"login":"acme-dev"},"labels":[],"body":"prose"}'
printf '%s' "$TAGGED" > "$WORK/tagged.json"
printf '%s' "$UNTAGGED" > "$WORK/untagged.json"

gate(){   # $1 = HOME  $2 = the pull request json file  $3 = command -> the gate's stdout and stderr
  printf '{"tool_input":{"command":%s},"cwd":%s}' \
    "$(printf '%s' "$3" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
    "$(printf '%s' "$CHECKOUT" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
    | ( cd "$CHECKOUT" && env -u CHANGELOG_REGISTRY HOME="$1" PATH="$FAKEBIN:$PATH" FAKE_PR_JSON="$2" bash "$HOOK" 2>&1 )
}
denied(){ local re='"permissionDecision": *"deny"'; [[ "$1" =~ $re ]]; }

out_gate="$(gate "$H1" "$WORK/tagged.json" "$MERGE 7 --repo acme/widget --squash")"
check "the gate refuses a merge when the registry is missing (fail closed): $out_gate" denied "$out_gate"
check "and names the exact path to create" has "$out_gate" "$WANT1"
check "and says what goes in it: a repos list" has "$out_gate" '\"repos\"'
check "and the fields an entry carries" has "$out_gate" "changelogFrom"
check "and how to gate nothing on this Mac on purpose" has "$out_gate" '{\"repos\": []}'
check "and that it is a file this Mac keeps for itself" has "$out_gate" "never sent"
# An ordinary command is still not the gate's business.
out_ls="$(gate "$H1" "$WORK/tagged.json" "ls -la")"
check "an ordinary command is not refused over the missing registry" [ -z "$out_ls" ]

out_gather="$(HOME="$H1" node "$GATHER" gather --now 2026-10-08T16:00:00Z --out "$WORK/g.json" 2>&1)"; rc_gather=$?
check "gather.js refuses with no registry (exit $rc_gather)" [ "$rc_gather" -ne 0 ]
check "and names the same path the gate does: $out_gather" has "$out_gather" "$WANT1"
check "and says what goes in it" has "$out_gather" "changelogFrom"
out_ghcmd="$(HOME="$H1" node "$GATHER" gh -- issue list --repo acme/widget 2>&1)"; rc_ghcmd=$?
check "gather.js gh refuses with no registry, naming the path" [ "$rc_ghcmd" -ne 0 ]
check "gather.js gh names the same path: $out_ghcmd" has "$out_ghcmd" "$WANT1"
printf 'Updates for October :thread:\n' > "$WORK/draft.txt"
out_lint="$(HOME="$H1" node "$LINT" "$WORK/draft.txt" 2>&1)"; rc_lint=$?
check "lint-post.js refuses with no registry (exit $rc_lint)" [ "$rc_lint" -eq 2 ]
check "and names the same path: $out_lint" has "$out_lint" "$WANT1"

# With the registry in place the same gate reads it: an untagged merge into the listed repo is
# refused for its record, and a tagged one merges. The control that the refusal above was the
# missing file and not a fixture that refuses everything (L159).
H2="$WORK/home two"
mkdir -p "$H2/.claude/$REL_SKILL"
printf '%s\n' "$REGISTRY_JSON" > "$H2/.claude/$REL_NEW"
out_untagged="$(gate "$H2" "$WORK/untagged.json" "$MERGE 7 --repo acme/widget --squash")"
check "with the registry present, an untagged merge in a listed repo is refused for its record" denied "$out_untagged"
check "and the refusal is about the record, not the registry" lacks "$out_untagged" "$H2/.claude/$REL_NEW"
out_tagged="$(gate "$H2" "$WORK/tagged.json" "$MERGE 7 --repo acme/widget --squash")"
check "with the registry present, a tagged merge goes through: $out_tagged" [ -z "$out_tagged" ]
# The deliberate opt out the message offers really opts out.
H3="$WORK/home three"
mkdir -p "$H3/.claude/$REL_SKILL"
printf '{"repos": []}\n' > "$H3/.claude/$REL_NEW"
out_empty="$(gate "$H3" "$WORK/untagged.json" "$MERGE 7 --repo acme/widget --squash")"
check "a registry listing no repos gates nothing: $out_empty" [ -z "$out_empty" ]
# And an unreadable one is still refused, as before.
printf '{ not json\n' > "$H3/.claude/$REL_NEW"
out_bad="$(gate "$H3" "$WORK/untagged.json" "$MERGE 7 --repo acme/widget --squash")"
check "an unreadable registry is still refused" denied "$out_bad"

# ---------------------------------------------------------------- 3. the move loses nothing
# Two Macs and the shared repository, as the #1009 cases in test-claude-sync.sh build them. Both
# hold the skill with the registry under its OLD tracked name, as every Mac does before this change.
BARE="$WORK/shared.git"; git init -q --bare -b main "$BARE"
RA="$WORK/cloneA"; RB="$WORK/cloneB"; RC="$WORK/cloneC"
git clone -q "$BARE" "$RA" 2>/dev/null; git clone -q "$BARE" "$RB" 2>/dev/null
HA="$WORK/macA"; HB="$WORK/macB"
CA="$HA/.claude"; CB="$HB/.claude"
mkdir -p "$CA/$REL_SKILL" "$CB"
printf '{"hooks":{}}\n' > "$CA/settings.json"; printf '{"hooks":{}}\n' > "$CB/settings.json"
printf -- '---\nname: pennie-dev-update\ndescription: a fixture skill for the suite\n---\nbody\n' > "$CA/$REL_SKILL/SKILL.md"
printf '%s\n' "$REGISTRY_JSON" > "$CA/$REL_OLD"
SENV=(SYNC_NO_NOTIFY=1 SYNC_NO_HOOK_TESTS=1 SYNC_NO_SEND_TESTS=1 SYNC_CLAUDE_BIN="$WORK/no-claude")
# The sync runs with a HOME of its own beside the fixture's. Under run-all-tests.sh the apply refuses
# a CLAUDE_HOME that is HOME/.claude (the real config, as far as it can tell), which is the shape the
# gate below needs, so the two are given different homes rather than the refusal being switched off.
mkdir -p "$WORK/sync-home-A" "$WORK/sync-home-B"
syncA(){ env "${SENV[@]}" HOME="$WORK/sync-home-A" CLAUDE_HOME="$CA" SYNC_REPO="$RA" SYNC_HOSTNAME=fixtureMacA bash "$SCRIPT" "$@" 2>&1; }
syncB(){ env "${SENV[@]}" HOME="$WORK/sync-home-B" CLAUDE_HOME="$CB" SYNC_REPO="$RB" SYNC_HOSTNAME=fixtureMacB bash "$SCRIPT" "$@" 2>&1; }

# Before the change: the file is tracked and installed on both Macs, which is where both are
# today. The exclusion that keeps a copy under the old name from travelling arrives with this
# change, so the starting point is committed and installed directly, as the old version did it.
mkdir -p "$RA/payload" "$CB/skills"
cp -R "$CA/skills" "$RA/payload/"
cp -R "$CA/$REL_SKILL" "$CB/skills/"
git -C "$RA" add -A payload >/dev/null 2>&1
git -C "$RA" -c user.name=fixture -c user.email=fixture@example.invalid commit -q -m "fixture: the registry as tracked before #1526" >/dev/null 2>&1
git -C "$RA" push -q origin main >/dev/null 2>&1
# Each clone at that commit with it recorded as applied, as a Mac the previous version installed it
# on is. Not a pull through this version: that would already move the file, before the change it is
# meant to meet has arrived.
git -C "$RB" pull -q origin main >/dev/null 2>&1
git -C "$RA" rev-parse HEAD > "$RA/.last-applied"
git -C "$RB" rev-parse HEAD > "$RB/.last-applied"
check "(setup) Mac B holds the registry under its old name before the change" cmp -s "$CB/$REL_OLD" "$CA/$REL_OLD"
check "(setup) and its clone is at the commit tracking it" git -C "$RB" cat-file -e "HEAD:payload/$REL_OLD"
cp "$CB/$REL_OLD" "$WORK/macB-registry-before.json"

# The change lands from elsewhere (a pull request merged on GitHub): the tracked file is deleted.
git clone -q "$BARE" "$RC" 2>/dev/null
git -C "$RC" rm -q "payload/$REL_OLD"
git -C "$RC" -c user.name=fixture -c user.email=fixture@example.invalid commit -q -m "fixture: #1526 removes the tracked registry" >/dev/null 2>&1
git -C "$RC" push -q origin main >/dev/null 2>&1

out_pullB="$(syncB pull)"
check "after the pull Mac B's registry is at the local name" [ -f "$CB/$REL_NEW" ]
check "with exactly the content it held before" cmp -s "$CB/$REL_NEW" "$WORK/macB-registry-before.json"
check "and the old name is gone from Mac B" [ ! -e "$CB/$REL_OLD" ]
check "and the pull said what it moved: $out_pullB" has "$out_pullB" "repos.local.json"
check "and the skill itself is still installed on Mac B" [ -f "$CB/$REL_SKILL/SKILL.md" ]
out_gateB="$(gate "$HB" "$WORK/tagged.json" "$MERGE 7 --repo acme/widget --squash")"
check "and the gate passes a tagged merge on Mac B: $out_gateB" [ -z "$out_gateB" ]
out_gateB2="$(gate "$HB" "$WORK/untagged.json" "$MERGE 7 --repo acme/widget --squash")"
check "and still refuses an untagged one there, so it read the moved registry" denied "$out_gateB2"

# The Mac the change did not come from either, by the two way path (send, then receive).
out_syncA="$(syncA sync)"
check "Mac A's registry is at the local name after a sync" cmp -s "$CA/$REL_NEW" "$WORK/macB-registry-before.json"
check "and the old name is gone from Mac A" [ ! -e "$CA/$REL_OLD" ]

# A second pull finds nothing to move and moves nothing (the move runs on every apply).
out_pullB2="$(syncB pull)"
check "a later pull leaves the local registry exactly as it was" cmp -s "$CB/$REL_NEW" "$WORK/macB-registry-before.json"
check "and says nothing about moving it" lacks "$out_pullB2" "moved $REL_OLD"

# ---------------------------------------------------------------- 4. the local file never travels
main_tree(){ git -C "$BARE" ls-tree -r --name-only main 2>/dev/null; }
check "the shared repository carries no local registry after Mac A's sync" lacks "$(main_tree)" "repos.local.json"
check "and no registry under the old name" lacks "$(main_tree)" "payload/$REL_OLD"
# An edit on Mac B is sent like any other file beside it, and the registry still is not.
printf -- '---\nname: pennie-dev-update\ndescription: a fixture skill for the suite\n---\nbody two\n' > "$CB/$REL_SKILL/SKILL.md"
printf '%s\n' '{"repos":[{"name":"Widget","repo":"acme/widget","account":"acme-bot","changelogFrom":"2026-02-02"}]}' > "$CB/$REL_NEW"
cp "$CB/$REL_NEW" "$WORK/macB-registry-edited.json"
syncB sync >/dev/null
check "(control) Mac B's skill edit did reach the shared repository" has "$(git -C "$BARE" show main:payload/$REL_SKILL/SKILL.md 2>/dev/null)" "body two"
check "while its edited local registry did not" lacks "$(main_tree)" "repos.local.json"
check "and Mac B's local registry is untouched by its own sync" cmp -s "$CB/$REL_NEW" "$WORK/macB-registry-edited.json"
# A copy recreated under the OLD name, by old habit, is not sent either, and the next apply folds
# it into the local file's place without destroying either copy.
printf '%s\n' '{"repos":[{"name":"Other","repo":"acme/other","account":"acme-bot"}]}' > "$CB/$REL_OLD"
cp "$CB/$REL_OLD" "$WORK/macB-old-habit.json"
out_syncB="$(syncB sync)"
check "a copy recreated under the old name is never sent" lacks "$(main_tree)" "payload/$REL_OLD"
check "the local registry wins over it, unchanged" cmp -s "$CB/$REL_NEW" "$WORK/macB-registry-edited.json"
# Read whole and the first line taken by expansion, never through head, which would short circuit
# the producer (test-pipefail-shortcircuit.sh).
aside="$(find "$CB/$REL_SKILL" -name 'repos.local.json.*' -type f 2>/dev/null)"
aside="${aside%%$'\n'*}"
check "and the differing old copy is set aside, not destroyed: ${aside:-none}" cmp -s "${aside:-/nonexistent}" "$WORK/macB-old-habit.json"
check "and the pull named where it put it: $out_syncB" has "$out_syncB" "${aside##*/}"
check "and the set aside copy is not sent either" lacks "$(main_tree)" "${aside##*/}"
# Mac A's own local registry survives Mac B's changes arriving.
syncA pull >/dev/null
check "Mac A's local registry survives the pull of Mac B's edits" cmp -s "$CA/$REL_NEW" "$WORK/macB-registry-before.json"

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
