#!/usr/bin/env bash
# Every file that used to travel and now belongs to each Mac moves without being lost
# (claude-config#1526, #1568).
#
# claude-sync's MOVED_TO_LOCAL lists "<old>|<new>" pairs: a file the payload used to carry, and the
# name each Mac keeps it under now, which LOCAL_FILE_GLOBS says is never sent and never deleted.
# The mirror deletes on a Mac whatever the payload stops carrying, so each move is only safe because
# the apply moves the installed copy BEFORE the mirror runs. This suite proves that for EVERY pair
# the script lists, read from the script itself rather than from a copy here, so a pair added later
# is proved on the day it lands (L247, L96):
#   1. The pairs #1568 moves are listed, each new name is one LOCAL_FILE_GLOBS keeps on each Mac, and
#      neither name of any pair is tracked here or stageable without a forced add.
#   2. Two fixture Macs hold every old file, as the previous version installed them. The change that
#      deletes them lands from a third clone, the way a pull request merge does. After a pull (Mac B)
#      and a sync (Mac A), every file is at its new name with the same bytes and the old name is gone.
#   3. Nothing local travels: the shared repository never holds a new name, an edited one, or a copy
#      recreated under an old name, while an ordinary edit sent beside them does arrive.
#
# tests/test-dev-update-registry.sh proves the first pair's readers; this proves the move for all.
# Every repository named here is invented. No work repository name belongs in this file.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
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

for tool in git rsync; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "FAIL: $tool is not on PATH, so this suite cannot run."
    printf 'SUITE-RESULT passed=0 failed=1\n'
    exit 1
  fi
done

# The two lists, read out of the script by name. Each is one array literal on one line.
MOVED_TO_LOCAL=(); LOCAL_FILE_GLOBS=()
eval "$(grep -E '^(MOVED_TO_LOCAL|LOCAL_FILE_GLOBS)=\(' "$SCRIPT")"
check "the script's MOVED_TO_LOCAL could be read (${#MOVED_TO_LOCAL[@]} pairs)" [ "${#MOVED_TO_LOCAL[@]}" -gt 0 ]
check "the script's LOCAL_FILE_GLOBS could be read" [ "${#LOCAL_FILE_GLOBS[@]}" -gt 0 ]

_tmp="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "${_tmp%/}/moved-to-local.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------- 1. the pairs
pairs=" ${MOVED_TO_LOCAL[*]} "
check "the sleep mode repository lists are moved to a Mac's own file" has "$pairs" " mods/sleep-repos.json|mods/sleep-repos.local.json "
check "the main into dev repository list is moved to a Mac's own file" has "$pairs" " hooks/main-to-dev-repos.txt|hooks/main-to-dev-repos.local.txt "
is_local_name(){   # $1 = a file name -> 0 when LOCAL_FILE_GLOBS keeps it on each Mac
  local g
  for g in "${LOCAL_FILE_GLOBS[@]}"; do
    # shellcheck disable=SC2254 # the pattern is meant to match as a glob
    case "$1" in $g) return 0 ;; esac
  done
  return 1
}
for entry in "${MOVED_TO_LOCAL[@]}"; do
  old="${entry%%|*}"; new="${entry#*|}"
  check "$new is a name each Mac keeps for itself" is_local_name "${new##*/}"
  check "$old is not tracked here" [ -z "$(git -C "$ROOT" ls-files --cached --others --exclude-standard -- "payload/$old")" ]
  check "$new is not tracked here, even force added" [ -z "$(git -C "$ROOT" ls-files --cached --others --exclude-standard -- "payload/$new")" ]
  check "$old is ignored by git here" git -C "$ROOT" check-ignore -q --no-index "payload/$old"
  check "$new is ignored by git here" git -C "$ROOT" check-ignore -q --no-index "payload/$new"
done

# ---------------------------------------------------------------- 2. the move loses nothing
BARE="$WORK/shared.git"; git init -q --bare -b main "$BARE"
RA="$WORK/cloneA"; RB="$WORK/cloneB"; RC="$WORK/cloneC"
git clone -q "$BARE" "$RA" 2>/dev/null; git clone -q "$BARE" "$RB" 2>/dev/null
HA="$WORK/macA"; HB="$WORK/macB"
CA="$HA/.claude"; CB="$HB/.claude"
mkdir -p "$CA" "$CB" "$WORK/before"
printf '{"hooks":{}}\n' > "$CA/settings.json"; printf '{"hooks":{}}\n' > "$CB/settings.json"
mkdir -p "$CA/skills/fixture-skill"
printf -- '---\nname: fixture-skill\ndescription: a fixture skill for the suite\n---\nbody\n' > "$CA/skills/fixture-skill/SKILL.md"
# One distinct invented content per pair, so a file that landed under the wrong name is caught too.
i=0
for entry in "${MOVED_TO_LOCAL[@]}"; do
  old="${entry%%|*}"
  mkdir -p "$(dirname "$CA/$old")"
  printf 'fixture %s for %s: acme/widget-%s\n' "$i" "$old" "$i" > "$CA/$old"
  cp "$CA/$old" "$WORK/before/$i"
  i=$((i + 1))
done
SENV=(SYNC_NO_NOTIFY=1 SYNC_NO_HOOK_TESTS=1 SYNC_NO_SEND_TESTS=1 SYNC_CLAUDE_BIN="$WORK/no-claude")
mkdir -p "$WORK/sync-home-A" "$WORK/sync-home-B"
syncA(){ env "${SENV[@]}" HOME="$WORK/sync-home-A" CLAUDE_HOME="$CA" SYNC_REPO="$RA" SYNC_HOSTNAME=fixtureMacA bash "$SCRIPT" "$@" 2>&1; }
syncB(){ env "${SENV[@]}" HOME="$WORK/sync-home-B" CLAUDE_HOME="$CB" SYNC_REPO="$RB" SYNC_HOSTNAME=fixtureMacB bash "$SCRIPT" "$@" 2>&1; }

# Before the change: every old file tracked and installed on both Macs, committed and installed
# directly as the previous version did it, since this version would already move them.
mkdir -p "$RA/payload"
cp -R "$CA/." "$RA/payload/"
rm -f "$RA/payload/settings.json"
cp -R "$CA/." "$CB/"
git -C "$RA" add -A payload >/dev/null 2>&1
git -C "$RA" -c user.name=fixture -c user.email=fixture@example.invalid commit -q -m "fixture: the files as tracked before they moved" >/dev/null 2>&1
git -C "$RA" push -q origin main >/dev/null 2>&1
git -C "$RB" pull -q origin main >/dev/null 2>&1
git -C "$RA" rev-parse HEAD > "$RA/.last-applied"
git -C "$RB" rev-parse HEAD > "$RB/.last-applied"
i=0
for entry in "${MOVED_TO_LOCAL[@]}"; do
  old="${entry%%|*}"
  check "(setup) Mac B holds $old before the change" cmp -s "$CB/$old" "$WORK/before/$i"
  check "(setup) and its clone is at the commit tracking it" git -C "$RB" cat-file -e "HEAD:payload/$old"
  i=$((i + 1))
done

# The change lands from elsewhere: every old file is deleted from the payload.
git clone -q "$BARE" "$RC" 2>/dev/null
for entry in "${MOVED_TO_LOCAL[@]}"; do git -C "$RC" rm -q "payload/${entry%%|*}"; done
git -C "$RC" -c user.name=fixture -c user.email=fixture@example.invalid commit -q -m "fixture: the files leave the payload" >/dev/null 2>&1
git -C "$RC" push -q origin main >/dev/null 2>&1

out_pullB="$(syncB pull)"
out_syncA="$(syncA sync)"
i=0
for entry in "${MOVED_TO_LOCAL[@]}"; do
  old="${entry%%|*}"; new="${entry#*|}"
  check "after the pull Mac B holds $new with exactly the content $old had" cmp -s "$CB/$new" "$WORK/before/$i"
  check "and $old is gone from Mac B" [ ! -e "$CB/$old" ]
  check "and the pull said it moved $old: $out_pullB" has "$out_pullB" "moved $old to $new"
  check "after a sync Mac A holds $new with exactly the content $old had" cmp -s "$CA/$new" "$WORK/before/$i"
  check "and $old is gone from Mac A" [ ! -e "$CA/$old" ]
  i=$((i + 1))
done

# ---------------------------------------------------------------- 3. nothing local travels
main_tree(){ git -C "$BARE" ls-tree -r --name-only main 2>/dev/null; }
printf -- '---\nname: fixture-skill\ndescription: a fixture skill for the suite\n---\nbody two\n' > "$CB/skills/fixture-skill/SKILL.md"
for entry in "${MOVED_TO_LOCAL[@]}"; do
  old="${entry%%|*}"; new="${entry#*|}"
  printf 'edited on Mac B\n' >> "$CB/$new"
  printf 'recreated under the old name by habit\n' > "$CB/$old"
done
out_syncB="$(syncB sync)"
check "(control) Mac B's ordinary edit reached the shared repository: $out_syncB" \
  has "$(git -C "$BARE" show main:payload/skills/fixture-skill/SKILL.md 2>/dev/null)" "body two"
tree_now="$(main_tree)"
for entry in "${MOVED_TO_LOCAL[@]}"; do
  old="${entry%%|*}"; new="${entry#*|}"
  check "the shared repository never holds $new" lacks "$tree_now" "payload/$new"
  check "nor a copy recreated under $old" lacks "$tree_now" "payload/$old"
  check "and Mac B's edited $new is kept, its edit intact" has "$(cat "$CB/$new" 2>/dev/null)" "edited on Mac B"
done

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
