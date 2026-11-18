#!/bin/bash
# The two checkout folders a mod chooses between, read from REAL linked worktrees (#996).
#
# Claude Code's $.session.repo().root is the project's main working tree even for a session in a
# linked worktree: measured on 2.1.295 on 2026-10-08 with a throwaway session in a worktree under
# .claude/worktrees, in a subfolder of one, and in one outside the main tree, which named the main
# tree each time. That half needs a real Claude session, so it is recorded in #996 and in the
# comments of each reader, not run here (a test never starts a paid session, L2). The other half,
# what mod-kit's own readers give for the session's folder, is read here with the readers
# themselves (mod-kit's tree.ts walk, branch.ts and repo.ts, under node) against real git, since
# the mods' own tests cannot touch the disk:
#   - $.modkit.branch from a worktree's folder: `root` is that worktree, `main` the main tree;
#     from the main checkout both are the main tree. Readers wanting the session's own checkout
#     (scope-modes' bedtime reading of its repository) take the first; readers wanting the project
#     (the handoff, the steps card, the overnight queue, the session name) take $.session.repo().
#   - The origin read in a worktree is the origin read in its main tree, so moving scope-modes'
#     bedtime read of this session's repository from the main tree to its own checkout asks GitHub
#     about the same repository.
#   - mod-kit's repo reader names the main tree, as $.session.repo() hands it over, by the
#     project's folder, so a worktree session is named for its project.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
. "$ROOT/payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?
pass=0; fail=0
check(){   # $1 = name  $2 = "ok" or the evidence of failure
  if [ "$2" = ok ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1: $2"; fi
}

if ! command -v node >/dev/null 2>&1; then
  echo "FAIL: node is not installed, so mod-kit's readers could not be run"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# git lists worktrees by their real path, so the fixture is named by its real path too (/var is
# /private/var on macOS).
TMP="$(cd -P "$TMP" && pwd)"
MAIN="$TMP/Bidspoke main"
INSIDE="$MAIN/.claude/worktrees/agent-1"
OUTSIDE="$TMP/outside wt"
g(){ git -c user.name=t -c user.email=t@t "$@"; }
if ! { g init -q -b main "$MAIN" && g -C "$MAIN" commit -q --allow-empty -m init &&
       g -C "$MAIN" remote add origin git@github.com:o/bidspoke.git &&
       g -C "$MAIN" worktree add -q -b agent-1 "$INSIDE" &&
       g -C "$MAIN" worktree add -q -b outside-1 "$OUTSIDE" && mkdir -p "$INSIDE/src/deep"; } >"$TMP/setup.log" 2>&1; then
  echo "FAIL: the real repository and its linked worktrees could not be made: $(cat "$TMP/setup.log")"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

KIT="$ROOT/payload/mods/mod-kit/hooks"
cat >"$TMP/read.mjs" <<'JS'
import { existsSync } from 'node:fs'
import { execFile } from 'node:child_process'
import { pathToFileURL } from 'node:url'
const [kit, ...paths] = process.argv.slice(2)
const { workingTree } = await import(pathToFileURL(`${kit}/tree.ts`).href)
const { branchAt } = await import(pathToFileURL(`${kit}/branch.ts`).href)
const { repoName } = await import(pathToFileURL(`${kit}/repo.ts`).href)
const walk = p => workingTree(p, async dir => existsSync(`${dir === '/' ? '' : dir}/.git`))
const run = argv => new Promise(resolve => execFile(argv[0], argv.slice(1), (err, stdout, stderr) => resolve({ exitCode: err ? (typeof err.code === 'number' ? err.code : 1) : 0, stdout, stderr })))
for (const p of paths) {
  const b = await branchAt(p, walk, run)
  console.log(JSON.stringify({ from: p, root: b?.root ?? null, main: b?.main ?? null, unreadable: b?.unreadable ?? null, nameOfMain: b?.main ? repoName({ root: b.main, remote: null }) : null }))
}
JS
out="$(node --experimental-strip-types --no-warnings "$TMP/read.mjs" "$KIT" "$INSIDE/src/deep" "$OUTSIDE" "$MAIN" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
  check "mod-kit's readers ran under node" "exit=$rc out=$out"
else
  field(){ printf '%s\n' "$out" | python3 -c 'import json,sys
want, key = sys.argv[1], sys.argv[2]
for line in sys.stdin:
    j = json.loads(line)
    if j["from"] == want: print(j[key]); break' "$1" "$2"; }
  [ "$(field "$INSIDE/src/deep" root)" = "$INSIDE" ] && check "from a folder inside a worktree under .claude/worktrees, the branch reader's root is that worktree" ok \
    || check "from a folder inside a worktree under .claude/worktrees, the branch reader's root is that worktree" "$out"
  [ "$(field "$INSIDE/src/deep" main)" = "$MAIN" ] && check "from that worktree, the branch reader's main is the main working tree" ok \
    || check "from that worktree, the branch reader's main is the main working tree" "$out"
  [ "$(field "$OUTSIDE" root)" = "$OUTSIDE" ] && [ "$(field "$OUTSIDE" main)" = "$MAIN" ] && check "from a worktree outside the main tree: root is the worktree, main the main tree" ok \
    || check "from a worktree outside the main tree: root is the worktree, main the main tree" "$out"
  [ "$(field "$MAIN" root)" = "$MAIN" ] && [ "$(field "$MAIN" main)" = "$MAIN" ] && check "from the main checkout, root and main are both the main tree" ok \
    || check "from the main checkout, root and main are both the main tree" "$out"
  [ "$(field "$OUTSIDE" nameOfMain)" = "Bidspoke main" ] && check "the repo reader names the main tree, as \$.session.repo() hands it over, by the project's folder" ok \
    || check "the repo reader names the main tree, as \$.session.repo() hands it over, by the project's folder" "$out"
fi

# The question scope-modes asks of the session's checkout at bedtime has one answer across the
# worktrees of a project.
for wt in "$INSIDE" "$OUTSIDE"; do
  a="$(git -C "$wt" remote -v 2>&1)"; b="$(git -C "$MAIN" remote -v 2>&1)"
  [ -n "$a" ] && [ "$a" = "$b" ] && check "the origin read in $(basename "$wt") is the main tree's" ok \
    || check "the origin read in $(basename "$wt") is the main tree's" "worktree: $a / main: $b"
done

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
