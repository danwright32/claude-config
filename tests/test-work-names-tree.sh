#!/usr/bin/env bash
# Nothing this public repository publishes names a work GitHub organisation (claude-config#1568).
#
# payload/hooks/test-work-names.sh proves the scanner, hooks/lib/work-names.py, on fixtures, and runs
# beside the hooks on every Mac. This suite needs the repository, so it lives here:
#   1. The whole tree: every file git would publish, tracked or not yet committed, is clean. Read
#      with the real HOME, so a Mac with the dev update registry also checks its owners, and CI,
#      which has none, checks the two built in organisation names and says so.
#   2. A send refuses to publish a file naming one. A lesson written on a Mac reaches the shared
#      repository through claude-sync with no pull request, so the whole tree check would only see
#      it after it was public (L280). The refusal names the file and line, never the name.
# The suite tests with an invented organisation handed to the scanner by hash
# (WORK_NAMES_EXTRA_HASHES), as the real two are built in. No work organisation or repository name
# belongs in this file.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SCAN="$ROOT/payload/hooks/lib/work-names.py"
SCRIPT="$ROOT/claude-sync"
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

for tool in git node python3 rsync shasum; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "FAIL: $tool is not on PATH, so this suite cannot run."
    printf 'SUITE-RESULT passed=0 failed=1\n'
    exit 1
  fi
done

_tmp="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "${_tmp%/}/work-names-tree.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
FAKE_ORG="Acme-HQ"
FAKE_HASH="$(printf '%s' "acme-hq" | shasum -a 256 | cut -d' ' -f1)"

# ---------------------------------------------------------------- 1. the whole tree
# Every file git would publish: tracked, and untracked but not ignored, so a file written a moment
# ago is judged before it is committed (L456).
tree_out="$(git -C "$ROOT" ls-files --cached --others --exclude-standard -z \
  | python3 "$SCAN" --root "$ROOT" --files0-from - 2>&1)"; tree_rc=$?
check "no file this repository publishes names a work organisation (exit $tree_rc): $tree_out" [ "$tree_rc" -eq 0 ]
check "and the scan said what it checked: $tree_out" has "$tree_out" "work organisation"
# The same listing does see one: in a throwaway repository, a file naming the invented organisation
# and not yet committed is found by it (L1).
PLANTED="$WORK/planted"; git init -q "$PLANTED"
printf 'clean\n' > "$PLANTED/clean.md"; git -C "$PLANTED" add clean.md
printf 'see %s/widget#3\n' "$FAKE_ORG" > "$PLANTED/new.md"
plant_out="$(git -C "$PLANTED" ls-files --cached --others --exclude-standard -z \
  | WORK_NAMES_EXTRA_HASHES="$FAKE_HASH" python3 "$SCAN" --root "$PLANTED" --files0-from - 2>&1)"; plant_rc=$?
check "(control) the same listing finds a name in a file not yet committed (exit $plant_rc)" [ "$plant_rc" -eq 1 ]
check "and names that file: $plant_out" has "$plant_out" "new.md:1"

# ---------------------------------------------------------------- 2. a send refuses to publish one
BARE="$WORK/shared.git"; git init -q --bare -b main "$BARE"
RA="$WORK/cloneA"; git clone -q "$BARE" "$RA" 2>/dev/null
HA="$WORK/macA"; CA="$HA/.claude"
mkdir -p "$CA/skills/fixture-skill" "$WORK/sync-home-A"
printf '{"hooks":{}}\n' > "$CA/settings.json"
printf -- '---\nname: fixture-skill\ndescription: a fixture skill for the suite\n---\nbody\n' > "$CA/skills/fixture-skill/SKILL.md"
SENV=(SYNC_NO_NOTIFY=1 SYNC_NO_HOOK_TESTS=1 SYNC_NO_SEND_TESTS=1 SYNC_CLAUDE_BIN="$WORK/no-claude")
syncA(){ env "${SENV[@]}" HOME="$WORK/sync-home-A" CLAUDE_HOME="$CA" SYNC_REPO="$RA" SYNC_HOSTNAME=fixtureMacA \
  WORK_NAMES_EXTRA_HASHES="$FAKE_HASH" bash "$SCRIPT" "$@" 2>&1; }
main_tree(){ git -C "$BARE" ls-tree -r --name-only main 2>/dev/null; }
out_first="$(syncA sync)"
check "(control) a clean skill is sent: $out_first" has "$(main_tree)" "payload/skills/fixture-skill/SKILL.md"
printf -- '---\nname: fixture-skill\ndescription: a fixture skill for the suite\n---\nbody, from %s/widget#4\n' "$FAKE_ORG" > "$CA/skills/fixture-skill/SKILL.md"
out_named="$(syncA sync)"
check "a send carrying an organisation name is refused: $out_named" has "$out_named" "names a work organisation"
check "and names the file and line" has "$out_named" "skills/fixture-skill/SKILL.md:5"
check "and the shared repository never received it" lacks "$(git -C "$BARE" show main:payload/skills/fixture-skill/SKILL.md 2>/dev/null)" "widget#4"
check "and the refusal never repeats the name" lacks "$(printf '%s' "$out_named" | tr '[:upper:]' '[:lower:]')" "acme-hq"
# A send alone ends at the refusal and leaves the staged edit uncommitted in the clone. The refusal
# is recorded where the secret scan records its own, as this scan's, and the sentence a later pull
# gives for leftover edits names this scan, never the secret scan (L11). That sentence is read from
# the script's own function, cut out by name.
out_send="$(syncA send)"
check "a send alone is refused too: $out_send" has "$out_send" "names a work organisation"
record="$(cat "$RA/.send-refused" 2>/dev/null)"
check "the refusal is recorded as this scan's: $record" has "$record" "work-names"
check "with where it found the name" has "$record" "skills/fixture-skill/SKILL.md:5"
cause="$( SEND_REFUSED_FILE="$RA/.send-refused" SYNC_REPO="$RA"
  eval "$(sed -n '/^age_in_words(){/,/^}/p;/^pending_edits_cause(){/,/^}/p' "$SCRIPT")"
  pending_edits_cause )"
check "the leftover edits are put down to the work names scan: $cause" has "$cause" "the work names scan last refused a send"
check "and not to the secret scan" lacks "$cause" "secret scan"
# A registry that cannot be read leaves the scan unable to judge, and that is a refusal, never a pass.
mkdir -p "$WORK/sync-home-A/.claude/skills/pennie-dev-update"
printf '{ not json\n' > "$WORK/sync-home-A/.claude/skills/pennie-dev-update/repos.local.json"
out_unjudged="$(syncA send)"
check "a send the scan cannot judge is refused: $out_unjudged" has "$out_unjudged" "could not judge"
rm -f "$WORK/sync-home-A/.claude/skills/pennie-dev-update/repos.local.json"
printf -- '---\nname: fixture-skill\ndescription: a fixture skill for the suite\n---\nbody, from widget#4\n' > "$CA/skills/fixture-skill/SKILL.md"
out_fixed="$(syncA sync)"
check "once the name is gone the same send goes through: $out_fixed" has "$(git -C "$BARE" show main:payload/skills/fixture-skill/SKILL.md 2>/dev/null)" "from widget#4"

# ---------------------------------------------------------------- 3. a scan of nothing is no pass
# The function itself, cut out of the script by name and run with the send's variables, for the two
# ways its file list can fail to exist: git could not list the clone, and a listing that found
# nothing. Each is a refusal handed back, never a clean pass over zero files (L98).
SWN="$(sed -n '/^scan_work_names(){/,/^}/p' "$SCRIPT")"
check "scan_work_names was cut from claude-sync whole" has "$SWN" 'die "$refusal"'
run_swn(){   # $1 = SYNC_REPO  $2 = SYNC_NO_GIT -> SEND_REFUSED, or "passed"
  ( SYNC_REPO="$1" PAYLOAD="$1/payload" SYNC_SELF_PAYLOAD="$ROOT/payload" SYNC_NO_GIT="$2" \
    SCAN_REFUSAL_DEFERRED=1 SEND_REFUSED="" SEND_REFUSED_FILE=""
    die(){ echo "DIED: $*"; exit 1; }
    eval "$SWN"
    scan_work_names
    printf '%s' "${SEND_REFUSED:-passed}" )
}
BROKEN="$WORK/broken-clone"; mkdir -p "$BROKEN/payload"
printf 'x\n' > "$BROKEN/payload/a.md"
printf 'not a gitdir\n' > "$BROKEN/.git"
out_broken="$(run_swn "$BROKEN" 0)"
check "a clone git cannot list is refused, not passed: $out_broken" has "$out_broken" "could not be listed"
EMPTY="$WORK/empty-clone"; mkdir -p "$EMPTY/payload"
out_empty="$(run_swn "$EMPTY" 1)"
check "a listing that found nothing is refused, not passed: $out_empty" has "$out_empty" "found none"
printf 'x\n' > "$EMPTY/payload/a.md"
out_one="$(run_swn "$EMPTY" 1)"
check "(control) the same clone with a clean file in it passes: $out_one" [ "$out_one" = passed ]
# The scratch file the scan makes is one the reaper sweeps (#36 in test-claude-sync.sh derives the
# same from every mktemp; this names the one this scan added).
check "the scan's scratch name is one the reaper sweeps" has "$(grep -E '^SYNC_SCRATCH_NAMES=' "$SCRIPT")" "claude-sync-work-names."

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
