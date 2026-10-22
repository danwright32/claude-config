#!/usr/bin/env bash
# Tests for tools/lib/pinned-compiler.sh, which gives a checkout of this repository the TypeScript
# compiler pinned in tools/typescript without anybody running npm ci there by hand (#1496). Every
# builder on 2026-10-21 and 22 had to, in each new worktree, and the full suite runs that forgot
# reported all 20 mods' types UNMEASURED.
#
# npm is a stub throughout (L2: no test reaches the network), standing in for npm ci by laying a
# node_modules with a .bin/tsc in the folder it is handed. The repositories are real git ones with
# real worktrees, since the shared install lives in the clone's common git folder and nothing but
# git can say where that is.
set -u

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/lib/pinned-compiler.sh"
REAL_TS="$DIR/typescript"

pass=0
fail=0
check() { # check <description> <result>
  if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi
}
T="$(mktemp -d "${TMPDIR:-/tmp}/test-pinned-compiler.XXXXXX")"
T="$(cd "$T" && pwd -P)"
trap 'rm -rf "$T"' EXIT

# The npm stand in. `ci --prefix <dir>` lays <dir>/node_modules as npm does for the pin: the package,
# its .bin/tsc as a relative link into it, and npm's hidden lockfile. Every call is logged.
#   FAKE_NPM_MODE=fail   exits 1 with npm's own words for a package missing from the cache, offline
#   FAKE_NPM_MODE=hang   starts a child that sleeps, records its pid, and waits on it
#   FAKE_NPM_BARRIER=d   waits until two installs have started, so they overlap, bounded by a limit
#                        the stub sets (not measured) so a lone install is never held for ever
NPM="$T/npm"; NPM_LOG="$T/npm-calls"
cat > "$NPM" <<'STUB'
#!/bin/bash
echo "$*" >> "$FAKE_NPM_LOG"
prefix=""; prev=""
for a in "$@"; do [ "$prev" = --prefix ] && prefix="$a"; prev="$a"; done
[ -f "$prefix/package-lock.json" ] || { echo "npm error code EUSAGE: no package-lock.json in $prefix" >&2; exit 1; }
if [ -n "${FAKE_NPM_BARRIER:-}" ]; then
  mkdir -p "$FAKE_NPM_BARRIER"; : > "$FAKE_NPM_BARRIER/$$"
  for _ in $(seq 1 200); do [ "$(ls "$FAKE_NPM_BARRIER" | wc -l)" -ge 2 ] && break; sleep 0.05; done
fi
case "${FAKE_NPM_MODE:-ok}" in
  fail) printf 'npm error code ENOTCACHED\nnpm error request to https://registry.npmjs.org/typescript failed: cache mode is only-if-cached\n' >&2; exit 1 ;;
  hang) sleep 300 & echo "$!" > "$FAKE_NPM_CHILD"; wait; exit 0 ;;
esac
nm="$prefix/node_modules"
mkdir -p "$nm/.bin" "$nm/typescript/bin" "$nm/@typescript/typescript-fake"
printf '#!/bin/bash\necho "fake tsc from %s"\n' "$(cksum < "$prefix/package-lock.json" | cut -d' ' -f1)" > "$nm/typescript/bin/tsc"
chmod +x "$nm/typescript/bin/tsc"
printf '{ "name": "typescript", "version": "7.0.2" }\n' > "$nm/typescript/package.json"
printf '{}\n' > "$nm/.package-lock.json"
ln -s ../typescript/bin/tsc "$nm/.bin/tsc"
echo "added 2 packages in 1s"
STUB
chmod +x "$NPM"

# A repository holding the pin as this one does, with its first commit made.
mkrepo(){ # $1 = repository folder
  mkdir -p "$1/tools/typescript"
  printf '{ "private": true, "devDependencies": { "typescript": "7.0.2" } }\n' > "$1/tools/typescript/package.json"
  printf '{ "lockfileVersion": 3, "packages": { "node_modules/typescript": { "version": "7.0.2" } } }\n' > "$1/tools/typescript/package-lock.json"
  # This repository's own ignore rule for the folder, read from its .gitignore rather than written
  # here, so the fixture ignores exactly what the real checkout does (L48).
  grep -E '^/?tools/typescript/node_modules' "$DIR/../.gitignore" > "$1/.gitignore"
  git -C "$1" init -q -b main
  git -C "$1" -c user.email=t@example.com -c user.name=t add .gitignore tools
  git -C "$1" -c user.email=t@example.com -c user.name=t commit -q -m pin
}
ensure(){ # $1 = the tools/typescript folder -> sets out and code
  out="$(FAKE_NPM_LOG="$NPM_LOG" PINNED_TS_NPM="$NPM" bash "$LIB" "$@" 2>&1)"; code=$?
}
# awk, never grep -c, which prints 0 AND fails on an empty log, so a fallback would print a second 0.
calls(){ awk 'END { print NR }' "$NPM_LOG" 2>/dev/null || echo 0; }

# 1. A fresh worktree, with no node_modules at all, gets a compiler that runs, from one npm ci,
#    into the install every worktree of the clone shares, kept in the clone's common git folder.
R="$T/repo"; mkrepo "$R"
git -C "$R" worktree add -q "$T/wt1" -b wt1
git -C "$R" worktree add -q "$T/wt2" -b wt2
: > "$NPM_LOG"
ensure "$T/wt1/tools/typescript"
[ "$code" -eq 0 ] && check "a fresh worktree's pinned compiler is made available" ok || check "a fresh worktree's pinned compiler is made available" "exit=$code out=$out"
"$T/wt1/tools/typescript/node_modules/.bin/tsc" 2>/dev/null | grep -q '^fake tsc from ' \
  && check "and its node_modules/.bin/tsc runs" ok || check "and its node_modules/.bin/tsc runs" "$(ls -la "$T/wt1/tools/typescript/node_modules" 2>&1)"
[ "$(calls)" -eq 1 ] && grep -q -- '--prefer-offline' "$NPM_LOG" && grep -q '^ci ' "$NPM_LOG" \
  && check "installed by one npm ci from the lockfile, offline from the npm cache where it can be" ok \
  || check "installed by one npm ci from the lockfile, offline from the npm cache where it can be" "$(cat "$NPM_LOG")"
stores="$(find "$R/.git/pinned-typescript" -mindepth 2 -maxdepth 2 -name .complete 2>/dev/null | wc -l | tr -d ' ')"
[ "$stores" = 1 ] && check "into one shared install in the clone's common git folder" ok || check "into one shared install in the clone's common git folder" "found $stores in $R/.git/pinned-typescript"
[ -d "$T/wt1/tools/typescript/node_modules" ] && [ ! -L "$T/wt1/tools/typescript/node_modules" ] \
  && check "node_modules is a real folder, so the existing ignore rule for it still holds" ok \
  || check "node_modules is a real folder, so the existing ignore rule for it still holds" "$(ls -la "$T/wt1/tools/typescript")"
[ -z "$(git -C "$T/wt1" status --porcelain)" ] && check "and the worktree shows nothing new to git" ok || check "and the worktree shows nothing new to git" "$(git -C "$T/wt1" status --porcelain)"
printf '%s\n' "$out" | grep -q 'installed' && check "the run says it installed the compiler, rather than doing it silently" ok \
  || check "the run says it installed the compiler, rather than doing it silently" "$out"

# 2. Another worktree, and the main checkout, are linked to that install with no npm at all.
ensure "$T/wt2/tools/typescript"
[ "$code" -eq 0 ] && "$T/wt2/tools/typescript/node_modules/.bin/tsc" 2>/dev/null | grep -q '^fake tsc' \
  && check "a second worktree gets the compiler too" ok || check "a second worktree gets the compiler too" "exit=$code out=$out"
ensure "$R/tools/typescript"
[ "$code" -eq 0 ] && "$R/tools/typescript/node_modules/.bin/tsc" 2>/dev/null | grep -q '^fake tsc' \
  && check "and so does the main checkout" ok || check "and so does the main checkout" "exit=$code out=$out"
[ "$(calls)" -eq 1 ] && check "without running npm again" ok || check "without running npm again" "$(cat "$NPM_LOG")"
# Run again where it is already there: nothing to do, nothing said, no npm.
ensure "$T/wt2/tools/typescript"
[ "$code" -eq 0 ] && [ -z "$out" ] && [ "$(calls)" -eq 1 ] && check "a checkout that already has it is left alone, quietly" ok \
  || check "a checkout that already has it is left alone, quietly" "exit=$code calls=$(calls) out=$out"

# 3. A compiler somebody installed by hand (a real node_modules, as npm ci leaves) is never touched.
R3="$T/repo3"; mkrepo "$R3"
mkdir -p "$R3/tools/typescript/node_modules/.bin"; printf '#!/bin/bash\necho by hand\n' > "$R3/tools/typescript/node_modules/.bin/tsc"; chmod +x "$R3/tools/typescript/node_modules/.bin/tsc"
: > "$NPM_LOG"
ensure "$R3/tools/typescript"
[ "$code" -eq 0 ] && [ "$("$R3/tools/typescript/node_modules/.bin/tsc")" = "by hand" ] && [ "$(calls)" -eq 0 ] && [ ! -e "$R3/.git/pinned-typescript" ] \
  && check "a compiler installed by hand is used as it is" ok || check "a compiler installed by hand is used as it is" "exit=$code calls=$(calls) out=$out"
# A node_modules that is not this install's and holds no compiler is left as it is, and said.
R3B="$T/repo3b"; mkrepo "$R3B"; mkdir -p "$R3B/tools/typescript/node_modules/leftpad"
ensure "$R3B/tools/typescript"
[ "$code" -ne 0 ] && [ -d "$R3B/tools/typescript/node_modules/leftpad" ] && printf '%s\n' "$out" | grep -q 'npm ci --prefix' \
  && check "a node_modules nobody can vouch for is never overwritten, and the way to replace it is named" ok \
  || check "a node_modules nobody can vouch for is never overwritten, and the way to replace it is named" "exit=$code out=$out"

# 4. Two suites installing at once (L33): both get a compiler that runs, one install is published,
#    and nothing half made is left behind. First two worktrees of one fresh clone, then the same
#    worktree twice.
R4="$T/repo4"; mkrepo "$R4"
git -C "$R4" worktree add -q "$T/wt4a" -b a
git -C "$R4" worktree add -q "$T/wt4b" -b b
: > "$NPM_LOG"
(FAKE_NPM_BARRIER="$T/barrier4" FAKE_NPM_LOG="$NPM_LOG" PINNED_TS_NPM="$NPM" bash "$LIB" "$T/wt4a/tools/typescript" > "$T/c4a.out" 2>&1; echo $? > "$T/c4a.code") &
(FAKE_NPM_BARRIER="$T/barrier4" FAKE_NPM_LOG="$NPM_LOG" PINNED_TS_NPM="$NPM" bash "$LIB" "$T/wt4b/tools/typescript" > "$T/c4b.out" 2>&1; echo $? > "$T/c4b.code") &
wait
[ "$(cat "$T/c4a.code")" = 0 ] && [ "$(cat "$T/c4b.code")" = 0 ] \
  && "$T/wt4a/tools/typescript/node_modules/.bin/tsc" | grep -q '^fake tsc' && "$T/wt4b/tools/typescript/node_modules/.bin/tsc" | grep -q '^fake tsc' \
  && check "two installs at once into one clone both end with a compiler that runs" ok \
  || check "two installs at once into one clone both end with a compiler that runs" "a=$(cat "$T/c4a.code") $(cat "$T/c4a.out") b=$(cat "$T/c4b.code") $(cat "$T/c4b.out")"
[ "$(calls)" -eq 2 ] && check "and they really did overlap (both ran npm)" ok || check "and they really did overlap (both ran npm)" "$(cat "$NPM_LOG")"
left="$(ls -A "$R4/.git/pinned-typescript")"
[ "$(printf '%s\n' "$left" | grep -c .)" = 1 ] && [ -f "$R4/.git/pinned-typescript/$left/.complete" ] \
  && check "one install is published and no half made copy is left beside it" ok || check "one install is published and no half made copy is left beside it" "$left"
R4S="$T/repo4s"; mkrepo "$R4S"
: > "$NPM_LOG"
(FAKE_NPM_BARRIER="$T/barrier4s" FAKE_NPM_LOG="$NPM_LOG" PINNED_TS_NPM="$NPM" bash "$LIB" "$R4S/tools/typescript" > "$T/c4c.out" 2>&1; echo $? > "$T/c4c.code") &
(FAKE_NPM_BARRIER="$T/barrier4s" FAKE_NPM_LOG="$NPM_LOG" PINNED_TS_NPM="$NPM" bash "$LIB" "$R4S/tools/typescript" > "$T/c4d.out" 2>&1; echo $? > "$T/c4d.code") &
wait
[ "$(cat "$T/c4c.code")" = 0 ] && [ "$(cat "$T/c4d.code")" = 0 ] && "$R4S/tools/typescript/node_modules/.bin/tsc" | grep -q '^fake tsc' \
  && [ -z "$(git -C "$R4S" status --porcelain)" ] \
  && check "two installs at once into the same checkout both succeed and leave it clean" ok \
  || check "two installs at once into the same checkout both succeed and leave it clean" "c=$(cat "$T/c4c.out") d=$(cat "$T/c4d.out") $(git -C "$R4S" status --porcelain)"
# A copy left by an install that was killed part way is cleared by the next one.
R4K="$T/repo4k"; mkrepo "$R4K"; mkdir -p "$R4K/.git/pinned-typescript/.abc.tmp.99999999/node_modules"
ensure "$R4K/tools/typescript"
[ "$code" -eq 0 ] && [ ! -e "$R4K/.git/pinned-typescript/.abc.tmp.99999999" ] \
  && check "a half made copy from an install that was killed is cleared" ok || check "a half made copy from an install that was killed is cleared" "exit=$code $(ls -A "$R4K/.git/pinned-typescript")"

# 5. Where it genuinely cannot install, it says why, in words a caller carries on its UNMEASURED
#    line, and leaves nothing behind: no npm, npm failing offline, npm that does not answer in time.
R5="$T/repo5"; mkrepo "$R5"
: > "$NPM_LOG"
out="$(PINNED_TS_NPM="$T/no-such-npm" bash "$LIB" "$R5/tools/typescript" 2>&1)"; code=$?
[ "$code" -eq 1 ] && printf '%s\n' "$out" | grep -q 'npm is not installed' \
  && check "with no npm it fails, saying npm is not installed" ok || check "with no npm it fails, saying npm is not installed" "exit=$code out=$out"
[ ! -e "$R5/tools/typescript/node_modules" ] && [ -z "$(ls -A "$R5/.git/pinned-typescript" 2>/dev/null)" ] \
  && check "and leaves nothing behind" ok || check "and leaves nothing behind" "$(ls -A "$R5/tools/typescript" "$R5/.git/pinned-typescript" 2>&1)"
if [ -x /usr/bin/npm ] || [ -x /bin/npm ]; then
  echo "SUITE-PART-UNMEASURED no npm on PATH: this machine has npm in /usr/bin or /bin, so a PATH without it cannot be made"
else
  out="$(PATH=/usr/bin:/bin bash "$LIB" "$R5/tools/typescript" 2>&1)"; code=$?
  [ "$code" -eq 1 ] && printf '%s\n' "$out" | grep -q 'npm is not installed' && check "with no npm on PATH it says so too" ok || check "with no npm on PATH it says so too" "exit=$code out=$out"
fi
out_fail="$(FAKE_NPM_MODE=fail FAKE_NPM_LOG="$NPM_LOG" PINNED_TS_NPM="$NPM" bash "$LIB" "$R5/tools/typescript" 2>&1)"; code=$?
[ "$code" -eq 1 ] && printf '%s\n' "$out_fail" | grep -q 'npm ci exited 1' && printf '%s\n' "$out_fail" | grep -q 'ENOTCACHED' \
  && check "npm failing offline is named with npm's own words" ok || check "npm failing offline is named with npm's own words" "exit=$code out=$out_fail"
[ ! -e "$R5/tools/typescript/node_modules" ] && [ -z "$(ls -A "$R5/.git/pinned-typescript" 2>/dev/null)" ] \
  && check "and a failed install leaves nothing behind" ok || check "and a failed install leaves nothing behind" "$(ls -A "$R5/.git/pinned-typescript" 2>&1)"
# Offline only, as a test suite asks (test-mods.sh sets it, so no suite run reaches the registry):
# npm is told --offline, never --prefer-offline, and a package missing from the cache says so.
: > "$NPM_LOG"
out="$(PINNED_TS_OFFLINE=1 FAKE_NPM_MODE=fail FAKE_NPM_LOG="$NPM_LOG" PINNED_TS_NPM="$NPM" bash "$LIB" "$R5/tools/typescript" 2>&1)"; code=$?
grep -q -- '--offline' "$NPM_LOG" && ! grep -q -- '--prefer-offline' "$NPM_LOG" \
  && check "with PINNED_TS_OFFLINE set npm is told never to ask the registry" ok || check "with PINNED_TS_OFFLINE set npm is told never to ask the registry" "$(cat "$NPM_LOG")"
[ "$code" -eq 1 ] && printf '%s\n' "$out" | grep -q 'PINNED_TS_OFFLINE' \
  && check "and a package missing from the cache says the registry was not asked, and why" ok \
  || check "and a package missing from the cache says the registry was not asked, and why" "exit=$code out=$out"
start=$(date +%s)
out="$(FAKE_NPM_MODE=hang FAKE_NPM_CHILD="$T/hang-child" FAKE_NPM_LOG="$NPM_LOG" PINNED_TS_NPM="$NPM" PINNED_TS_INSTALL_DEADLINE=1 bash "$LIB" "$R5/tools/typescript" 2>&1)"; code=$?
took=$(( $(date +%s) - start ))
[ "$code" -eq 1 ] && [ "$took" -lt 15 ] && printf '%s\n' "$out" | grep -q 'did not finish within 1 s' \
  && check "an npm that does not answer is stopped at the deadline and said as that" ok \
  || check "an npm that does not answer is stopped at the deadline and said as that" "exit=$code took=${took}s out=$out"
child="$(cat "$T/hang-child" 2>/dev/null)"
[ -n "$child" ] && ! kill -0 "$child" 2>/dev/null && check "and what npm started is stopped with it" ok \
  || { [ -n "$child" ] && kill "$child" 2>/dev/null; check "and what npm started is stopped with it" "pid ${child:-unrecorded} still running"; }
out="$(PINNED_TS_INSTALL_DEADLINE=soon PINNED_TS_NPM="$NPM" bash "$LIB" "$R5/tools/typescript" 2>&1)"; code=$?
[ "$code" -eq 1 ] && printf '%s\n' "$out" | grep -q "PINNED_TS_INSTALL_DEADLINE='soon'" \
  && check "a deadline that is not a number of seconds is refused rather than guessed" ok || check "a deadline that is not a number of seconds is refused rather than guessed" "exit=$code out=$out"
# Outside any git checkout there is no shared place to keep it, and that is said too.
mkdir -p "$T/loose/typescript"; cp "$R/tools/typescript/package.json" "$R/tools/typescript/package-lock.json" "$T/loose/typescript/"
out="$(GIT_CEILING_DIRECTORIES="$T" PINNED_TS_NPM="$NPM" FAKE_NPM_LOG="$NPM_LOG" bash "$LIB" "$T/loose/typescript" 2>&1)"; code=$?
[ "$code" -eq 1 ] && printf '%s\n' "$out" | grep -q 'not in a git checkout' \
  && check "outside a git checkout it says there is nowhere shared to install to" ok || check "outside a git checkout it says there is nowhere shared to install to" "exit=$code out=$out"
out="$(PINNED_TS_NPM="$NPM" bash "$LIB" "$T/empty-dir-that-is-not-there" 2>&1)"; code=$?
[ "$code" -eq 1 ] && check "a folder that is not there is refused" ok || check "a folder that is not there is refused" "exit=$code out=$out"

# 6. When the pin moves, a linked checkout follows it: a new install for the new lockfile, the old
#    one kept for any checkout still on it.
: > "$NPM_LOG"
before="$("$T/wt1/tools/typescript/node_modules/.bin/tsc")"
printf '{ "lockfileVersion": 3, "packages": { "node_modules/typescript": { "version": "7.0.3" } } }\n' > "$T/wt1/tools/typescript/package-lock.json"
ensure "$T/wt1/tools/typescript"
after="$("$T/wt1/tools/typescript/node_modules/.bin/tsc" 2>&1)"
[ "$code" -eq 0 ] && [ "$(calls)" -eq 1 ] && [ "$before" != "$after" ] \
  && check "a checkout whose lockfile changed is relinked to an install of the new pin" ok \
  || check "a checkout whose lockfile changed is relinked to an install of the new pin" "exit=$code calls=$(calls) before=$before after=$after out=$out"
"$T/wt2/tools/typescript/node_modules/.bin/tsc" | grep -qxF "$before" \
  && check "while a checkout still on the old pin keeps working" ok || check "while a checkout still on the old pin keeps working" "$("$T/wt2/tools/typescript/node_modules/.bin/tsc" 2>&1)"

# 7. A shared install that has gone (somebody cleared .git) is made again, and relinked.
rm -rf "$R/.git/pinned-typescript"
: > "$NPM_LOG"
ensure "$T/wt2/tools/typescript"
[ "$code" -eq 0 ] && [ "$(calls)" -eq 1 ] && "$T/wt2/tools/typescript/node_modules/.bin/tsc" | grep -q '^fake tsc' \
  && check "a linked checkout whose shared install was removed gets it back" ok || check "a linked checkout whose shared install was removed gets it back" "exit=$code calls=$(calls) out=$out"

# 8. The real pinned compiler, through the links, where this checkout has it linked: TypeScript 7 is
#    a native binary that finds its platform package beside it, so it is run rather than assumed.
if [ -f "$REAL_TS/node_modules/.pinned-typescript-store" ] && [ -x "$REAL_TS/node_modules/.bin/tsc" ]; then
  v="$("$REAL_TS/node_modules/.bin/tsc" --version 2>&1)"
  printf '%s\n' "$v" | grep -q "^Version $(jq -r '.devDependencies.typescript' "$REAL_TS/package.json")" \
    && check "the real pinned compiler runs through the links in this checkout" ok || check "the real pinned compiler runs through the links in this checkout" "$v"
else
  echo "SUITE-PART-UNMEASURED the real compiler through the links: this checkout's tools/typescript is not linked to a shared install"
fi

# 9. Pruning the shared installs no checkout links to (#1507). Each is about 30 MB, one per pin the
#    clone has ever been on, and nothing removed them. The prune keeps every install any worktree's
#    node_modules links to (read from `git worktree list`, never guessed), the current pin's, and an
#    install still being made by a running process; it removes the rest, and nothing outside the
#    store. Every repository here is a throwaway one under $T, never this checkout's own store.
R9="$T/repo9"; mkrepo "$R9"; ROOT9="$R9/.git/pinned-typescript"
git -C "$R9" worktree add -q "$T/wt9a" -b a9
git -C "$R9" worktree add -q "$T/wt9b" -b b9
pin9(){ printf '{ "lockfileVersion": 3, "packages": { "node_modules/typescript": { "version": "%s" } } }\n' "$2" > "$1/package-lock.json"; }
store_of(){ cat "$1/node_modules/.pinned-typescript-store" 2>/dev/null; }
ensure "$T/wt9a/tools/typescript"; ensure "$T/wt9b/tools/typescript"; ensure "$R9/tools/typescript"
KA="$(store_of "$T/wt9a/tools/typescript")"
# An install from a pin weeks old that no checkout links to any more, as a moved pin leaves behind.
mkdir -p "$ROOT9/oldpin-fake-arch/node_modules/.bin"; : > "$ROOT9/oldpin-fake-arch/.complete"
# Things in the store that are not installs: a link pointing outside it (what it points at must never
# be touched, nor the link followed) and a file somebody left there.
mkdir -p "$T/outside9"; echo precious > "$T/outside9/keep"; ln -s "$T/outside9" "$ROOT9/stray-link"; echo note > "$ROOT9/by-hand.txt"
pin9 "$T/wt9a/tools/typescript" 7.1.0
: > "$NPM_LOG"
ensure "$T/wt9a/tools/typescript"
KB="$(store_of "$T/wt9a/tools/typescript")"
[ "$code" -eq 0 ] && [ "$(calls)" -eq 1 ] && [ -n "$KB" ] && [ "$KB" != "$KA" ] && [ -f "$KB/.complete" ] \
  && check "#1507 a new pin is installed (the case the prune runs after)" ok || check "#1507 a new pin is installed (the case the prune runs after)" "exit=$code calls=$(calls) KA=$KA KB=$KB out=$out"
[ ! -e "$ROOT9/oldpin-fake-arch" ] && check "#1507 an old install no checkout links to is removed once a new pin is installed" ok \
  || check "#1507 an old install no checkout links to is removed once a new pin is installed" "$(ls -A "$ROOT9")"
printf '%s\n' "$out" | grep -q 'removed 1 shared install' && check "#1507 and the run says what it removed" ok || check "#1507 and the run says what it removed" "$out"
[ -f "$KA/.complete" ] && "$T/wt9b/tools/typescript/node_modules/.bin/tsc" | grep -q '^fake tsc' \
  && check "#1507 an old install a worktree still links to is kept, and that worktree's compiler still runs" ok \
  || check "#1507 an old install a worktree still links to is kept, and that worktree's compiler still runs" "$(ls -A "$ROOT9")"
[ -f "$KB/.complete" ] && check "#1507 the current pin's install is kept" ok || check "#1507 the current pin's install is kept" "$(ls -A "$ROOT9")"
[ "$(cat "$T/outside9/keep" 2>/dev/null)" = precious ] && [ -L "$ROOT9/stray-link" ] && [ -f "$ROOT9/by-hand.txt" ] \
  && check "#1507 nothing in the store that is not an install is removed, and a link out of it is never followed" ok \
  || check "#1507 nothing in the store that is not an install is removed, and a link out of it is never followed" "$(ls -lA "$ROOT9" "$T/outside9" 2>&1)"

# Run on its own (--prune), from a checkout whose own pin is installed but which links to nothing.
# An install linked from a node_modules outside tools/typescript is kept from the record of where it
# was linked; one whose only worktree was deleted by hand is removed; in flight installs are judged
# by their pid, alive (including one belonging to another user, which kill -0 cannot signal) or not.
mkdir -p "$T/wt9b/elsewhere/typescript"; cp "$T/wt9b/tools/typescript/package.json" "$T/wt9b/elsewhere/typescript/"; pin9 "$T/wt9b/elsewhere/typescript" 7.3.0
ensure "$T/wt9b/elsewhere/typescript"; KE="$(store_of "$T/wt9b/elsewhere/typescript")"
git -C "$R9" worktree add -q "$T/wt9d" -b d9; pin9 "$T/wt9d/tools/typescript" 7.4.0
ensure "$T/wt9d/tools/typescript"; KD="$(store_of "$T/wt9d/tools/typescript")"
git -C "$R9" worktree add -q "$T/wt9c" -b c9; pin9 "$T/wt9c/tools/typescript" 7.2.0
ensure "$T/wt9c/tools/typescript"; KC="$(store_of "$T/wt9c/tools/typescript")"
rm -rf "$T/wt9c/tools/typescript/node_modules" "$T/wt9d"
mkdir -p "$ROOT9/.k1.tmp.$$" "$ROOT9/.k2.tmp.1" "$ROOT9/.k3.tmp.99999999" "$ROOT9/.k4.pruning.99999999"
out="$(bash "$LIB" --prune "$T/wt9c/tools/typescript" 2>&1)"; code=$?
[ "$code" -eq 0 ] && [ -n "$KD" ] && [ ! -e "$KD" ] \
  && check "#1507 an install whose only worktree was deleted by hand is removed" ok || check "#1507 an install whose only worktree was deleted by hand is removed" "exit=$code KD=$KD out=$out $(ls -A "$ROOT9")"
[ -n "$KC" ] && [ -f "$KC/.complete" ] && check "#1507 the pin of the checkout pruned from is kept though nothing links to it yet" ok \
  || check "#1507 the pin of the checkout pruned from is kept though nothing links to it yet" "KC=$KC $(ls -A "$ROOT9")"
[ -f "$KA/.complete" ] && [ -f "$KB/.complete" ] && check "#1507 installs the main checkout and a worktree link to are kept" ok || check "#1507 installs the main checkout and a worktree link to are kept" "$(ls -A "$ROOT9")"
[ -n "$KE" ] && [ -f "$KE/.complete" ] && check "#1507 an install linked from outside tools/typescript is kept, from the record of where it was linked" ok \
  || check "#1507 an install linked from outside tools/typescript is kept, from the record of where it was linked" "KE=$KE $(ls -A "$ROOT9")"
[ -d "$ROOT9/.k1.tmp.$$" ] && check "#1507 an install in flight under a live pid is kept" ok || check "#1507 an install in flight under a live pid is kept" "$(ls -A "$ROOT9")"
[ -d "$ROOT9/.k2.tmp.1" ] && check "#1507 and so is one whose live pid belongs to another user" ok || check "#1507 and so is one whose live pid belongs to another user" "$(ls -A "$ROOT9")"
[ ! -e "$ROOT9/.k3.tmp.99999999" ] && [ ! -e "$ROOT9/.k4.pruning.99999999" ] \
  && check "#1507 a dead pid's leftover is removed" ok || check "#1507 a dead pid's leftover is removed" "$(ls -A "$ROOT9")"

# A worktree git says is locked and whose folder cannot be read (a removable disk not mounted) may
# link to anything, so nothing is removed and the reason is said.
git -C "$R9" worktree add -q "$T/wt9l" -b l9
git -C "$R9" worktree lock "$T/wt9l"
mv "$T/wt9l" "$T/wt9l.away"
mkdir -p "$ROOT9/oldpin2-fake-arch/node_modules"; : > "$ROOT9/oldpin2-fake-arch/.complete"
out="$(bash "$LIB" --prune "$T/wt9c/tools/typescript" 2>&1)"; code=$?
[ "$code" -ne 0 ] && [ -d "$ROOT9/oldpin2-fake-arch" ] && printf '%s\n' "$out" | grep -q 'locked' \
  && check "#1507 a locked worktree that cannot be read stops the prune, removing nothing, and says why" ok \
  || check "#1507 a locked worktree that cannot be read stops the prune, removing nothing, and says why" "exit=$code out=$out $(ls -A "$ROOT9")"
mv "$T/wt9l.away" "$T/wt9l"; git -C "$R9" worktree unlock "$T/wt9l"

# A checkout that links to an install after the prune judged it unlinked (another worktree's check
# starting at that moment) gets it put back, not deleted. The seam links a folder to it, recorded in
# the install's own .links, which is the record the prune must still read once the install is
# renamed aside.
printf '#!/bin/bash\nmkdir -p "%s/node_modules"\nprintf "%%s\\n" "$1" > "%s/node_modules/.pinned-typescript-store"\nprintf "%%s\\n" "%s/node_modules" >> "$1/.links"\n' "$T/late9" "$T/late9" "$T/late9" > "$T/seam9late"; chmod +x "$T/seam9late"
out="$(PINNED_TS_TEST_BEFORE_REMOVE="$T/seam9late" bash "$LIB" --prune "$T/wt9c/tools/typescript" 2>&1)"; code=$?
[ "$code" -eq 0 ] && [ -f "$ROOT9/oldpin2-fake-arch/.complete" ] && [ -f "$T/late9/node_modules/.pinned-typescript-store" ] \
  && check "#1507 an install linked in the moment before it is removed is put back" ok \
  || check "#1507 an install linked in the moment before it is removed is put back" "exit=$code out=$out late=$(ls -A "$T/late9" 2>&1) $(ls -A "$ROOT9")"
rm -rf "$T/late9"

# status counts the shared installs and their size, and how many no checkout links to, without
# removing any. Installs now: KA, KB, KC, KE and oldpin2 (the in flight folders are not installs);
# linked by none, judged from the main checkout's pin: KC (its checkout links nothing) and oldpin2.
mkdir -p "$R9/tools/lib" "$T/home9"; cp "$LIB" "$R9/tools/lib/"
out="$(CLAUDE_HOME="$T/home9" SYNC_REPO="$R9" SYNC_NO_NOTIFY=1 bash "$DIR/../claude-sync" status 2>&1)"
line="$(printf '%s\n' "$out" | grep 'shared TypeScript compiler install')"
printf '%s\n' "$line" | grep -q '5 shared TypeScript compiler installs' && printf '%s\n' "$line" | grep -Eq '[0-9]+ (KB|MB)' \
  && check "#1507 status shows the count and total size of the shared installs" ok || check "#1507 status shows the count and total size of the shared installs" "$out"
printf '%s\n' "$line" | grep -q '2 linked by no checkout' && check "#1507 and how many no checkout links to" ok || check "#1507 and how many no checkout links to" "$line"
[ -d "$ROOT9/oldpin2-fake-arch" ] && check "#1507 and removes nothing" ok || check "#1507 and removes nothing" "$(ls -A "$ROOT9")"
out="$(CLAUDE_HOME="$T/home9" SYNC_REPO="$R3" SYNC_NO_NOTIFY=1 bash "$DIR/../claude-sync" status 2>&1)"
! printf '%s\n' "$out" | grep -q 'shared TypeScript compiler' && check "#1507 a clone with no shared installs says nothing about them" ok \
  || check "#1507 a clone with no shared installs says nothing about them" "$out"

# An install pruned in the moment between being found whole and being linked (a prune from another
# worktree at the same time) is installed again rather than linked broken. The seam removes the
# store once, at exactly that moment.
R9R="$T/repo9r"; mkrepo "$R9R"; git -C "$R9R" worktree add -q "$T/wt9r" -b r9
ensure "$R9R/tools/typescript"
printf '#!/bin/bash\n[ -e "%s" ] && exit 0\n: > "%s"\nrm -rf "$1"\n' "$T/seam9.done" "$T/seam9.done" > "$T/seam9"; chmod +x "$T/seam9"
: > "$NPM_LOG"
out="$(PINNED_TS_TEST_BEFORE_LINK="$T/seam9" FAKE_NPM_LOG="$NPM_LOG" PINNED_TS_NPM="$NPM" bash "$LIB" "$T/wt9r/tools/typescript" 2>&1)"; code=$?
[ -e "$T/seam9.done" ] && [ "$code" -eq 0 ] && [ "$(calls)" -eq 1 ] && "$T/wt9r/tools/typescript/node_modules/.bin/tsc" | grep -q '^fake tsc' \
  && check "#1507 an install pruned between being found and being linked is installed again" ok \
  || check "#1507 an install pruned between being found and being linked is installed again" "seam=$([ -e "$T/seam9.done" ] && echo ran || echo not-run) exit=$code calls=$(calls) out=$out"

[ -x "$LIB" ] && check "tools/lib/pinned-compiler.sh is executable" ok || check "tools/lib/pinned-compiler.sh is executable" "not executable"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
