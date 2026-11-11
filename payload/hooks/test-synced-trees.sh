#!/usr/bin/env bash
# lib/synced-trees.sh: a scan of the config reads only what the sync carries (claude-config#2750).
#
# Installed, a suite's own tree is ~/.claude, which also holds what each Mac keeps for itself. On
# 2026-11-11 test-bad-byte-locale.sh read an older copy of itself that a builder kept under
# state/session-notes/<project>/<session>/2721/base/hooks/ and failed 2 checks, and
# test-builder-briefs-hand-back.sh read a trashed skill under skills/.trash and failed 1, so the
# pull that had just installed the config said it FAILED over files no send will ever publish.
# synced_files lists only the trees the sync mirrors, with the skills entries it leaves alone taken
# out by lib/unmanaged-skills.sh. This suite holds it to that on a throwaway tree laid out like
# ~/.claude, and holds its list of trees to claude-sync's own.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/synced-trees.XXXXXXXX")" || exit 1
case "${WORK%/}" in ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$WORK'" >&2; exit 2 ;; esac
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $1"; }
check_eq(){ if [ "$2" = "$3" ]; then ok; else bad "$1: wanted '$2', got '$3'"; fi; }

if ! . "$DIR/lib/synced-trees.sh" || ! declare -F synced_files >/dev/null; then
  bad "lib/synced-trees.sh did not load, or defines no synced_files"
  printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
  exit 1
fi

# A throwaway tree laid out like an installed ~/.claude: every tree the sync mirrors, and beside and
# inside them, each kind of thing a Mac keeps for itself.
H="$WORK/home/.claude"
for f in \
  hooks/test-a.sh hooks/lib/x.sh hooks/__pycache__/x.cpython-312.pyc \
  agents/a.md commands/c.md audits/2026-01-01/a.md mods/m/hooks/r.ts \
  skills/real/SKILL.md skills/real/synced/inner.md skills/real/.trash/old/SKILL.md \
  skills/synced/acct/docx/SKILL.md skills/.trash/1791847280260-1-Ab/deep-research/SKILL.md \
  skills/cloudflare/SKILL.md \
  state/session-notes/p/s/2721/base/hooks/test-a.sh projects/p/x.jsonl plugins/cache/x/test-y.sh \
  todos/t.json CLAUDE.md settings.json; do
  mkdir -p "$H/$(dirname "$f")"
  : > "$H/$f"
done

listed(){ # listed <root> [tree...] -> what synced_files prints, relative to <root>, on one line
  local r="$1" out
  out="$(synced_files "$@")" || return $?
  printf '%s\n' "$out" | sed "s#^$r/##" | sort | tr '\n' ' '
}

got="$(listed "$H")"; rc=$?
check_eq "every tree: lists the config and nothing a Mac keeps for itself" \
  "0 agents/a.md audits/2026-01-01/a.md commands/c.md hooks/lib/x.sh hooks/test-a.sh mods/m/hooks/r.ts skills/real/SKILL.md skills/real/synced/inner.md " \
  "$rc $got"
got="$(listed "$H" skills agents)"; rc=$?
check_eq "named trees: lists only those" "0 agents/a.md skills/real/SKILL.md skills/real/synced/inner.md " "$rc $got"

# A tree the sync does not mirror is refused, never listed, so a caller cannot widen the scan back
# into a Mac's own folders by naming one.
out="$(synced_files "$H" state 2>&1)"; rc=$?
check_eq "naming state/ is refused" 2 "$rc"
case "$out" in *state*) ok ;; *) bad "the refusal of state/ does not name it: $out" ;; esac
# Nothing to read is a refusal, never an empty pass (L98).
out="$(synced_files "$WORK/nowhere" 2>&1)"; rc=$?
check_eq "a root that is not there is refused" 2 "$rc"
mkdir -p "$WORK/empty"
out="$(synced_files "$WORK/empty" 2>&1)"; rc=$?
check_eq "a root holding none of the trees is refused" 1 "$rc"
case "$out" in *"$WORK/empty"*) ok ;; *) bad "the refusal of an empty root does not name it: $out" ;; esac

# The list of trees is claude-sync's MIRROR_DIRS plus skills, which it mirrors on a path of its own.
# claude-sync keeps its own copy (fixtures copy it alone, with no payload beside it), so the two are
# compared here. Only a checkout has claude-sync; installed, this part is unmeasured, not passed.
mirror_dirs_of(){ # mirror_dirs_of <claude-sync> -> its MIRROR_DIRS, sorted, one line
  sed -n 's/^MIRROR_DIRS=(\([^)]*\)).*/\1/p' "$1" | tr ' ' '\n' | sed '/^$/d' | sort | tr '\n' ' '
}
ours="$(printf '%s\n' "${SYNCED_TREES[@]}" | grep -v -x skills | sort | tr '\n' ' ')"
printf '%s\n' 'MIRROR_DIRS=(hooks agents commands audits mods extra)   # a tree added on one side' > "$WORK/claude-sync.drifted"
[ "$(mirror_dirs_of "$WORK/claude-sync.drifted")" != "$ours" ] && ok \
  || bad "the comparison does not see a tree claude-sync mirrors that SYNCED_TREES lacks"
case " ${SYNCED_TREES[*]} " in *" skills "*) ok ;; *) bad "SYNCED_TREES does not hold skills" ;; esac
ROOT="$(bash "$DIR/lib/checkout-root.sh" "$DIR/.." 2>/dev/null)" || ROOT=""
if [ -n "$ROOT" ]; then
  theirs="$(mirror_dirs_of "$ROOT/claude-sync")"
  [ -n "$theirs" ] && ok || bad "no MIRROR_DIRS=( line was read from $ROOT/claude-sync, so the comparison below means nothing"
  check_eq "SYNCED_TREES, less skills, is claude-sync's MIRROR_DIRS" "$theirs" "$ours"
else
  echo "SUITE-PART-UNMEASURED SYNCED_TREES against claude-sync's MIRROR_DIRS: no checkout above $DIR, so there is no claude-sync to read"
fi

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
