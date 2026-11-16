#!/bin/bash
# The area check lets `bash tools/check-mods.sh <mods folder>` run without judging the folder, by name
# (payload/mods/area-check/hooks/named.ts CHECK_MODS, claude-config#3022, signed off by Dan,
# 2026-11-16), because the script's own text cannot be read to say it only reads that folder. That is
# a claim about the script and the libraries it sources, so this suite holds it there, against the
# real ones (L96, L58):
#   - CHECK_MODS.texts is the script and exactly the files it and its libraries source, so a library
#     added to the script, or one the list names that nothing sources, turns red here.
#   - The real script, run from a throwaway checkout over a fixture mods folder there, leaves the
#     checkout as it found it. With a compiler named, nothing in the checkout changes at all: every
#     file byte for byte, no new file, an ignored one included. With none named it installs the
#     pinned compiler as a new worktree's first run does, and then every file git tracks or would
#     track is still byte for byte the same, git status is the same, and everything new is under the
#     ignored tools/typescript/node_modules. Its copies go under the temporary folder and its failure
#     logs under the cache folder, both seen to be written, so the run did its work (L98, L288).
#   - Each of those checks is seen to fail (L1): a copy of the script changed to append to a tracked
#     file, to add a new file, or to plant an ignored one is caught.
#   - The rule itself, run on mod-kit's REAL reader of a command and real git, lets through only that
#     script at its path from the root of a checkout of its repository, handed one folder, in a
#     command that sets no value and runs the script once, with nothing but a change of folder
#     before it and readers its output is piped into after it, with its texts
#     as the checkout left the default branch with them.
#     Every other shape, a changed text, a copy elsewhere, another repository, and everything chained
#     with the run is still judged.
# What it cannot prove, said so it is never claimed (L460): what the real claude command, the real
# compiler and each mod's own tests write when the script runs them. Here they are stand ins, since a
# suite never starts a real Claude or asks the registry. The area check does not judge them typed
# directly either (`claude plugin test <mod>`, tests/test-area-check-shell-reader.sh's blind spot).
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
finish(){
  echo "passed: $pass, failed: $fail"
  printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]
  exit $?
}

if ! command -v node >/dev/null 2>&1; then
  echo "FAIL: node is not installed, so the area check's list could not be read"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

NAMED="$ROOT/payload/mods/area-check/hooks/named.ts"
# Resolved, since git names a checkout by where it really is and macOS's temporary folder is a link.
TMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/test-area-check-check-mods.XXXXXX")" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

# ---- The list, held to the texts ----
cat >"$TMP/texts.mjs" <<'JS'
import { readFileSync } from 'node:fs'
const [namedPath, root] = process.argv.slice(2)
const { CHECK_MODS } = await import(namedPath)
const base = p => p.slice(p.lastIndexOf('/') + 1)
const listed = new Set(CHECK_MODS.texts.map(base))
const sourced = new Set()
const problems = []
let lines = 0
// A line that sources a file: `. x` or `source x` at the start of a command.
const SOURCES = /(?:^|[;&|{(]|\b(?:if|then|else|elif|do|while|until)\b|!)\s*(?:\.|source)\s+(\S.*)$/
for (const text of CHECK_MODS.texts) {
  let body
  try {
    body = readFileSync(`${root}/${text}`, 'utf8')
  } catch (err) {
    problems.push(`${text} is listed and cannot be read (${err.code})`)
    continue
  }
  for (const [i, line] of body.split('\n').entries()) {
    if (/^\s*#/.test(line)) continue
    const m = SOURCES.exec(line)
    if (!m) continue
    lines++
    // The file is named on the line, or through a variable the same text gives a name ending in .sh.
    let name = /([A-Za-z0-9_.-]+\.sh)\b/.exec(m[1])?.[1]
    if (!name) {
      const v = /^"?\$\{?([A-Za-z_][A-Za-z0-9_]*)/.exec(m[1])?.[1]
      const set = v && new RegExp(`^\\s*${v}=.*?([A-Za-z0-9_.-]+\\.sh)\\b`, 'm').exec(body)
      name = set?.[1]
    }
    if (!name) problems.push(`${text}:${i + 1} sources a file this suite cannot name: ${line.trim()}`)
    else if (!listed.has(name)) problems.push(`${text}:${i + 1} sources ${name}, which CHECK_MODS.texts does not list`)
    else sourced.add(name)
  }
}
for (const text of CHECK_MODS.texts) if (text !== CHECK_MODS.script && !sourced.has(base(text))) problems.push(`${text} is listed and no listed text sources it`)
if (CHECK_MODS.texts[0] !== CHECK_MODS.script) problems.push(`the list does not start with ${CHECK_MODS.script}`)
console.log(`LINES\t${lines}`)
console.log(`SCRIPT\t${CHECK_MODS.script}`)
for (const t of CHECK_MODS.texts) console.log(`TEXT\t${t}`)
for (const p of problems) console.log(`PROBLEM\t${p}`)
JS
listed="$(node --experimental-strip-types --no-warnings "$TMP/texts.mjs" "$NAMED" "$ROOT" 2>&1)" || {
  check "named.ts's CHECK_MODS is read" "$listed"
  finish
}
TEXTS="$(printf '%s\n' "$listed" | sed -n 's/^TEXT	//p')"
SCRIPT="$(printf '%s\n' "$listed" | sed -n 's/^SCRIPT	//p')"
lines="$(printf '%s\n' "$listed" | sed -n 's/^LINES	//p')"
[ "$SCRIPT" = tools/check-mods.sh ] && [ -f "$ROOT/$SCRIPT" ] && check "the named script is tools/check-mods.sh, and it is there" ok \
  || check "the named script is tools/check-mods.sh, and it is there" "named: $SCRIPT"
# Five source lines today: three in the script, one in each of two libraries. Fewer than that and the
# reading of them has gone blind, which would pass every check below it (L98).
[ "${lines:-0}" -ge 5 ] && check "the lines that source a file are found" ok || check "the lines that source a file are found" "found ${lines:-none}: $listed"
problems="$(printf '%s\n' "$listed" | sed -n 's/^PROBLEM	//p')"
[ -z "$problems" ] && check "CHECK_MODS.texts is the script and exactly the files it and its libraries source" ok \
  || check "CHECK_MODS.texts is the script and exactly the files it and its libraries source" "$problems"

# ---- The real script over a throwaway checkout ----
mkmod(){   # $1 = mods dir  $2 = name
  mkdir -p "$1/$2/.claude-plugin" "$1/$2/hooks" "$1/$2/tests"
  printf '{ "name": "%s", "version": "0.1.0", "description": "x" }\n' "$2" > "$1/$2/.claude-plugin/plugin.json"
  printf '{ "modules": ["./register.ts"] }\n' > "$1/$2/hooks/hooks.json"
  printf 'export const register = () => {}\n' > "$1/$2/hooks/register.ts"
  printf 'export {}\n' > "$1/$2/tests/a.test.ts"
  printf '{ "extends": "./.claude-plugin/types/tsconfig.json" }\n' > "$1/$2/tsconfig.json"
}
# The pin, the pinned types and the record of known type errors the script reads: every file under
# tools/typescript that git tracks or would track, so never the ignored node_modules there.
DATA="$(bash "$ROOT/payload/hooks/lib/repo-files.sh" "$ROOT" tools/typescript)" && [ -n "$DATA" ] \
  && check "the data the script reads under tools/typescript is listed" ok || check "the data the script reads under tools/typescript is listed" "repo-files.sh gave: $DATA"
# A checkout holding the real script and libraries at their paths, the data they read, the real
# ignore rules, and four mods: one fine, one leaning on it, one validate refuses, one whose tests fail.
# $2, when given, is a sed program changing the copy of the script, for the controls.
make_repo(){   # $1 = folder  $2 = sed program for the script, or empty
  local repo="$1" t f
  mkdir -p "$repo"
  for t in $TEXTS tools/sec-default-bypassed-hooks.tsv .gitignore $DATA; do
    mkdir -p "$repo/$(dirname "$t")"
    cp "$ROOT/$t" "$repo/$t" || return 1
  done
  if [ -n "${2:-}" ]; then
    sed "$2" "$repo/$SCRIPT" > "$repo/$SCRIPT.changed" && mv "$repo/$SCRIPT.changed" "$repo/$SCRIPT" || return 1
    cmp -s "$ROOT/$SCRIPT" "$repo/$SCRIPT" && return 1
  fi
  for f in fine leaning broken-mod redtest; do mkmod "$repo/payload/mods" "$f"; done
  printf '{ "name": "leaning", "version": "0.1.0", "description": "x", "dependencies": ["fine"] }\n' > "$repo/payload/mods/leaning/.claude-plugin/plugin.json"
  printf '{ "name": "fine", "version": "0.1.0", "description": "x", "types": "./types/index.d.ts" }\n' > "$repo/payload/mods/fine/.claude-plugin/plugin.json"
  mkdir -p "$repo/payload/mods/fine/types"; printf 'export type F = 1\n' > "$repo/payload/mods/fine/types/index.d.ts"
  git -C "$repo" init -q -b main >/dev/null 2>&1 || return 1
  git -C "$repo" add -A >/dev/null 2>&1 || return 1
  git -C "$repo" -c user.email=t@example.com -c user.name=t commit -q -m fixture >/dev/null 2>&1 || return 1
  git -C "$repo" update-ref refs/remotes/origin/main HEAD
}
# Every path in a checkout outside its git folder, with what it holds: a file's hash, a link's target.
whole(){   # $1 = checkout
  (cd "$1" && find . -path ./.git -prune -o -print | LC_ALL=C sort | while IFS= read -r f; do
    if [ -L "$f" ]; then printf 'link %s -> %s\n' "$f" "$(readlink "$f")"
    elif [ -d "$f" ]; then printf 'dir %s\n' "$f"
    else printf '%s %s\n' "$(shasum "$f" | cut -c1-40)" "$f"; fi
  done)
}
# Every file git tracks or would track there, with its hash.
tracked(){   # $1 = checkout
  (cd "$1" && git ls-files -co --exclude-standard | LC_ALL=C sort | while IFS= read -r f; do
    if [ -f "$f" ]; then printf '%s %s\n' "$(shasum "$f" | cut -c1-40)" "$f"; else printf 'gone %s\n' "$f"; fi
  done)
}
status(){ git -C "$1" status --porcelain --untracked-files=all 2>&1; }
# Every line that differs between two listings. Through files, and read to its end, since a reader
# that stops early or a process substitution inside a captured function can lose lines on bash 3.2,
# and a lost line here would read as nothing having changed.
differing(){   # $1 = listing before  $2 = listing after
  printf '%s\n' "$1" > "$TMP/listing.before"; printf '%s\n' "$2" > "$TMP/listing.after"
  diff "$TMP/listing.before" "$TMP/listing.after" | grep '^[<>]'
}
# What changed between two listings, the first few lines of it on one line.
changed(){ differing "$1" "$2" | sed -n '1,6p' | paste -sd';' -; }

CLAUDE="$TMP/claude"; CALLS="$TMP/claude-calls"
cat > "$CLAUDE" <<'STUB'
#!/bin/bash
echo "$*" >> "$STUB_LOG"
[ "$1" = --version ] && { echo "2.1.291 (Claude Code)"; exit 0; }
case "$1 $2" in
  "plugin validate") case "$3" in *broken*) printf '  hooks: bad event\n\nValidation failed\n'; exit 1 ;; esac; echo 'Validation passed' ;;
  "plugin test") case "$3" in *redtest*) printf ' 0 pass\n 1 fail\n'; exit 1 ;; esac; printf ' 1 pass\n 0 fail\n' ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$CLAUDE"
TSC="$TMP/tsc"; TSC_CALLS="$TMP/tsc-calls"
printf '#!/bin/bash\necho "$*" >> "%s"\nexit 0\n' "$TSC_CALLS" > "$TSC"; chmod +x "$TSC"
# npm, standing in: it lays the stand in compiler as the package's tsc, as an install would.
NPM="$TMP/npm"
cat > "$NPM" <<STUB
#!/bin/bash
prefix=""; prev=""
for a in "\$@"; do [ "\$prev" = --prefix ] && prefix="\$a"; prev="\$a"; done
mkdir -p "\$prefix/node_modules/.bin" "\$prefix/node_modules/typescript/bin"
cp "$TSC" "\$prefix/node_modules/typescript/bin/tsc"
ln -s ../typescript/bin/tsc "\$prefix/node_modules/.bin/tsc"
STUB
chmod +x "$NPM"
mkdir -p "$TMP/home" "$TMP/tmp"
KEPT="$TMP/home/.cache/claude-config/mod-test-failures"
# The script as the area check lets it through: `bash tools/check-mods.sh payload/mods` from the root
# of the checkout. Only the stand ins, and a home and temporary folder of its own, are set around it.
run_check(){   # $1 = checkout  rest = more of the environment -> sets out and code
  local repo="$1"; shift
  : > "$CALLS"; : > "$TSC_CALLS"
  out="$(cd "$repo" && env -u CHECK_MODS_FAILURE_OUTPUT -u CHECK_MODS_TS_DIR -u CHECK_MODS_BYPASS_KNOWN -u TSC_BIN -u XDG_CACHE_HOME \
    HOME="$TMP/home" TMPDIR="$TMP/tmp" STUB_LOG="$CALLS" CLAUDE_BIN="$CLAUDE" PINNED_TS_OFFLINE=1 "$@" bash tools/check-mods.sh payload/mods 2>&1)"; code=$?
}

REPO="$TMP/repo"
make_repo "$REPO" "" && [ -z "$(status "$REPO")" ] && check "the throwaway checkout is made, clean, with the real script in it" ok \
  || check "the throwaway checkout is made, clean, with the real script in it" "status: $(status "$REPO")"
cmp -s "$ROOT/$SCRIPT" "$REPO/$SCRIPT" && check "and its script is the real one, byte for byte" ok || check "and its script is the real one, byte for byte" "the copy differs"

# 1. A compiler named: nothing in the checkout changes at all.
whole_before="$(whole "$REPO")"; status_before="$(status "$REPO")"
run_check "$REPO" TSC_BIN="$TSC"
[ "$code" -eq 1 ] && printf '%s\n' "$out" | grep 'broken-mod' | grep -q 'bad event' && printf '%s\n' "$out" | grep -q 'redtest' \
  && check "the run did its work: it failed the two mods that fail, by name" ok \
  || check "the run did its work: it failed the two mods that fail, by name" "exit=$code out=$out"
[ "$(grep -c "^plugin validate payload/mods/" "$CALLS")" -eq 4 ] && check "it asked claude about each of the four mods in the checkout" ok \
  || check "it asked claude about each of the four mods in the checkout" "$(cat "$CALLS")"
[ "$(grep -c -- "^-p $TMP/tmp/check-mods\.[A-Za-z0-9]*/" "$TSC_CALLS")" -eq 4 ] && check "it type checked each in a copy under the temporary folder, outside the checkout" ok \
  || check "it type checked each in a copy under the temporary folder, outside the checkout" "$(cat "$TSC_CALLS")"
[ -n "$(ls -A "$KEPT" 2>/dev/null)" ] && check "it kept the failed mods' output under the cache folder, outside the checkout" ok \
  || check "it kept the failed mods' output under the cache folder, outside the checkout" "nothing under $KEPT; out=$out"
whole_after="$(whole "$REPO")"
[ "$whole_after" = "$whole_before" ] && check "with a compiler named, every path in the checkout is byte for byte as it was, and none is new" ok \
  || check "with a compiler named, every path in the checkout is byte for byte as it was, and none is new" "$(changed "$whole_before" "$whole_after")"
[ "$(status "$REPO")" = "$status_before" ] && check "and git status is as it was" ok || check "and git status is as it was" "now: $(status "$REPO")"

# 2. No compiler named, as in a new worktree: the pinned one is installed, into ignored folders only.
tracked_before="$(tracked "$REPO")"
run_check "$REPO" PINNED_TS_NPM="$NPM"
printf '%s\n' "$out" | grep -q 'pinned TypeScript compiler was installed' && [ -x "$REPO/tools/typescript/node_modules/.bin/tsc" ] \
  && check "with no compiler named, the run installs the pinned one into the checkout's tools/typescript/node_modules" ok \
  || check "with no compiler named, the run installs the pinned one into the checkout's tools/typescript/node_modules" "exit=$code out=$out"
[ "$(grep -c -- "^-p $TMP/tmp/check-mods\.[A-Za-z0-9]*/" "$TSC_CALLS")" -eq 4 ] && check "and type checks each mod with it" ok || check "and type checks each mod with it" "$(cat "$TSC_CALLS")"
tracked_after="$(tracked "$REPO")"
[ "$tracked_after" = "$tracked_before" ] && check "every file git tracks or would track is byte for byte as it was, and none is new" ok \
  || check "every file git tracks or would track is byte for byte as it was, and none is new" "$(changed "$tracked_before" "$tracked_after")"
[ "$(status "$REPO")" = "$status_before" ] && check "git status is as it was" ok || check "git status is as it was" "now: $(status "$REPO")"
whole_now="$(whole "$REPO")"
installed="$(differing "$whole_before" "$whole_now" | grep -c '^> [^ ]* \./tools/typescript/node_modules\(/\| \|$\)')"
[ "$installed" -ge 2 ] && check "the listing sees what the install put in the checkout" ok || check "the listing sees what the install put in the checkout" "$installed new paths under tools/typescript/node_modules"
new="$(differing "$whole_before" "$whole_now" | grep -v '^> [^ ]* \./tools/typescript/node_modules\(/\| \|$\)' | sed -n '1,6p' | paste -sd';' -)"
[ -z "$new" ] && check "and everything new in the checkout is under the ignored tools/typescript/node_modules" ok \
  || check "and everything new in the checkout is under the ignored tools/typescript/node_modules" "$new"
git -C "$REPO" check-ignore -q tools/typescript/node_modules && check "which the repository's own ignore rules cover" ok \
  || check "which the repository's own ignore rules cover" "tools/typescript/node_modules is not ignored in the checkout"

# 3. The controls (L1): a script that writes into the checkout is caught by each check above.
control(){   # $1 = name  $2 = sed program  $3 = whole | tracked  $4 = what the difference must name
  local repo="$TMP/control-$1" before after seen
  make_repo "$repo" "$2" || { check "control $1: a changed copy of the script is made" "the script did not change, or the checkout could not be made"; return; }
  if [ "$3" = whole ]; then before="$(whole "$repo")"; else before="$(tracked "$repo")"; fi
  run_check "$repo" TSC_BIN="$TSC"
  if [ "$3" = whole ]; then after="$(whole "$repo")"; else after="$(tracked "$repo")"; fi
  seen="$(changed "$before" "$after")"
  case "$seen" in *"$4"*) check "control $1 is caught, naming $4" ok ;; *) check "control $1 is caught, naming $4" "the listing showed: ${seen:-no difference}; out=$out" ;; esac
}
AFTER_DIR='/^dir="\${dir%\/}"$/a\'
control "appending to a tracked file" "$AFTER_DIR
printf '// x\\\\n' >> \"\$dir/fine/hooks/register.ts\"
" tracked "payload/mods/fine/hooks/register.ts"
[ -n "$(status "$TMP/control-appending to a tracked file")" ] && check "and git status shows it" ok || check "and git status shows it" "git status is empty"
control "adding a new file" "$AFTER_DIR
: > \"\$dir/fine/hooks/new.ts\"
" tracked "payload/mods/fine/hooks/new.ts"
[ -n "$(status "$TMP/control-adding a new file")" ] && check "and git status shows it" ok || check "and git status shows it" "git status is empty"
control "planting an ignored file" "$AFTER_DIR
mkdir -p tools/typescript/node_modules; : > tools/typescript/node_modules/planted
" whole "tools/typescript/node_modules/planted"

# ---- The rule, on the real reader and real git ----
cat >"$TMP/rule.mjs" <<'JS'
import { spawnSync } from 'node:child_process'
import { appendFileSync, existsSync, mkdirSync, copyFileSync, statSync } from 'node:fs'
import { dirname } from 'node:path'
const [namedPath, writesPath, rulesPath, repo] = process.argv.slice(2)
const { CHECK_MODS, namedReaders } = await import(namedPath)
const { commandWrites, pipelineIn } = await import(writesPath)
const { shellTargets } = await import(rulesPath)
const HOME = '/Users/dan'
const git = (...args) => spawnSync('git', ['-C', repo, '-c', 'user.email=t@example.com', '-c', 'user.name=t', ...args], { encoding: 'utf8' })
const facts = (github, cwd) => ({
  commands: async command => pipelineIn(command, cwd, HOME),
  checkout: async path => {
    const r = spawnSync('git', ['-C', dirname(path), 'rev-parse', '--show-toplevel'], { encoding: 'utf8' })
    return r.status === 0 ? { root: r.stdout.trim(), github, defaultBranch: 'main' } : { unread: 'it is in no checkout' }
  },
  isFolder: async path => existsSync(path) && statSync(path).isDirectory(),
  git: async (root, args) => spawnSync('git', ['-C', root, ...args]).status ?? 2,
})
const say = (name, ok, evidence) => console.log(ok ? `PASS\t${name}` : `FAIL\t${name}\t${evidence}`)
// What the area check goes on to judge for a command, and what the rule decided for each named run.
const read = async (command, cwd = repo, github = CHECK_MODS.repo) => {
  const r = await namedReaders(command, commandWrites(command, cwd, HOME), facts(github, cwd))
  return { judged: shellTargets(r.writes, HOME).map(t => t.path ?? t.word), named: r.named }
}
const through = async (name, command, cwd) => {
  const r = await read(command, cwd)
  say(name, r.judged.length === 0 && r.named.length === 1 && r.named[0].passed === true, `${command} gave ${JSON.stringify(r)}`)
}
const judged = async (name, command, wants, why, github) => {
  const r = await read(command, repo, github)
  const ok = wants.every(w => r.judged.includes(w)) && r.named.every(n => !n.passed) && (why === undefined || r.named.some(n => (n.why ?? '').includes(why)))
  say(name, ok, `${command} gave ${JSON.stringify(r)}`)
}
const MODS = `${repo}/payload/mods`
const RUN = 'bash tools/check-mods.sh payload/mods'

await through('the run from the root of the checkout is let through, judging nothing', RUN)
await through('run directly, by its path from the root', './tools/check-mods.sh payload/mods')
await through('by its whole path, its output piped to a reader', `bash ${repo}/tools/check-mods.sh ${MODS} 2>&1 | tail -n 40`)
await through('from a folder inside the checkout', 'cd payload && bash ../tools/check-mods.sh mods')

await judged('the same path in a clone of another repository is judged', RUN, [MODS], 'never danwright32/claude-config', 'someone/else')
await judged('in a checkout of no GitHub repository it is judged', RUN, [MODS], 'no GitHub repository', null)
mkdirSync(`${repo}/copy/tools`, { recursive: true })
copyFileSync(`${repo}/tools/check-mods.sh`, `${repo}/copy/tools/check-mods.sh`)
await judged('a copy elsewhere in the checkout is judged', 'bash copy/tools/check-mods.sh payload/mods', [MODS], 'not tools/check-mods.sh at the root')
await judged('a script of that name in no checkout is judged', 'bash /nowhere/tools/check-mods.sh payload/mods', [MODS], 'its checkout cannot be read')
await judged('handed two folders, both are judged', 'bash tools/check-mods.sh payload/mods payload/hooks', [MODS, `${repo}/payload/hooks`], 'more than the one folder')
await judged('with a value set in front of it, it is judged', 'TMPDIR=payload/mods bash tools/check-mods.sh payload/mods', [MODS], 'sets a value')
await judged('with a value exported before it, it is judged', 'export CLAUDE_BIN=/tmp/x; bash tools/check-mods.sh payload/mods', [MODS], 'sets a value')
// A value set with no equals sign, by a command that runs first: only a change of folder may.
const BEFORE = 'runs in the same command'
// Written after it, a command still runs before it the second time round a loop, or once a function is called.
await judged('in a loop that reads and exports a value after it, it is judged', 'for i in 1 2; do bash tools/check-mods.sh payload/mods; read TMPDIR <<< payload/mods; export TMPDIR; done', [MODS], BEFORE)
await judged('in a function called after a value is read and exported, it is judged', 'f() { bash tools/check-mods.sh payload/mods; }; read TMPDIR <<< payload/mods; export TMPDIR; f', [MODS], BEFORE)
await through('its output piped through two readers is let through', 'cd payload && bash ../tools/check-mods.sh mods 2>&1 | grep -v ok | tail -n 40')
await judged('after a value read and exported, it is judged', 'read TMPDIR <<< payload/mods; export TMPDIR; bash tools/check-mods.sh payload/mods', [MODS], BEFORE)
await judged('after a value printed into a variable and exported, it is judged', 'printf -v TMPDIR %s payload/mods; export TMPDIR; bash tools/check-mods.sh payload/mods', [MODS], BEFORE)
await judged('after a sourced file, it is judged', '. ./env.sh; bash tools/check-mods.sh payload/mods', [MODS], BEFORE)
await judged('inside a loop that names a variable, it is judged', 'for TMPDIR in payload/mods; do export TMPDIR; bash tools/check-mods.sh payload/mods; done', [MODS], BEFORE)
await judged('run twice with a value exported between, both are judged', 'bash tools/check-mods.sh payload/mods; export TMPDIR; bash tools/check-mods.sh payload/mods', [MODS], 'run more than once')
await judged('run by another shell, it is judged', 'sh tools/check-mods.sh payload/mods', [MODS])
await judged('handed a file, the file is judged', 'bash tools/check-mods.sh payload/mods/fine/hooks/register.ts', [`${MODS}/fine/hooks/register.ts`], 'is no folder on the disk')
await judged('handed a name built as the command runs, it is judged', 'bash tools/check-mods.sh "$MODS"', ['$MODS'], 'cannot be read as the one folder')
await judged('handed a pattern, it is judged', 'bash tools/check-mods.sh payload/*', ['payload/*'], 'cannot be read as the one folder')
{
  const r = await read(`${RUN} > payload/mods/fine/hooks/register.ts`)
  say('its output sent into a file under the folder still judges that file', r.judged.length === 1 && r.judged[0] === `${MODS}/fine/hooks/register.ts` && r.named[0].passed === true, JSON.stringify(r))
}
{
  const r = await read(`${RUN} && sed -i '' 's/a/b/' payload/mods/fine/hooks/register.ts`)
  say('chained with an edit, the edit and the folder are both judged', r.judged.includes(`${MODS}/fine/hooks/register.ts`) && r.judged.includes(MODS) && !r.named[0].passed, JSON.stringify(r))
}
{
  const r = await read(`${RUN} && bash copy/tools/check-mods.sh payload/mods`)
  say('another script handed the same folder in the same command keeps the folder judged', r.judged.includes(MODS) && r.named.every(n => !n.passed), JSON.stringify(r))
}

// A changed text is not the text the suite proved: an edit not committed, one committed on the
// branch, and an edit to a library; back as it was, the run is let through again.
const CHANGED = 'has changed since this checkout left origin/main'
appendFileSync(`${repo}/tools/check-mods.sh`, '# changed\n')
await judged('the script edited and not committed is judged', RUN, [MODS], CHANGED)
git('commit', '-q', '-a', '-m', 'change the script')
await judged('the script changed in a commit on the branch is judged', RUN, [MODS], CHANGED)
git('checkout', '-q', 'origin/main', '--', 'tools/check-mods.sh')
git('commit', '-q', '-a', '-m', 'put the script back')
await through('the script put back as the default branch has it is let through again', RUN)
for (const lib of CHECK_MODS.texts.slice(1)) {
  appendFileSync(`${repo}/${lib}`, '# changed\n')
  await judged(`${lib} edited is judged`, RUN, [MODS], CHANGED)
  git('checkout', '-q', '--', lib)
}
await through('every library put back, the run is let through again', RUN)
git('update-ref', '-d', 'refs/remotes/origin/main')
await judged('with no origin/main to compare with, it is judged', RUN, [MODS], 'git could not compare its text')
JS
EXPECTED=35
ruled="$(node --experimental-strip-types --no-warnings "$TMP/rule.mjs" "$NAMED" "$ROOT/payload/mods/mod-kit/hooks/writes.ts" "$ROOT/payload/mods/area-check/hooks/rules.ts" "$REPO" 2>&1)" || {
  check "the rule runs on the real reader" "$ruled"
  finish
}
ran=0
while IFS=$'\t' read -r verdict name evidence; do
  case "$verdict" in
    PASS) ran=$((ran + 1)); check "$name" ok ;;
    FAIL) ran=$((ran + 1)); check "$name" "$evidence" ;;
    *) [ -z "$verdict" ] || check "the rule's output is read" "an unexpected line: $verdict $name" ;;
  esac
done <<< "$ruled"
[ "$ran" -eq "$EXPECTED" ] && check "all $EXPECTED checks of the rule ran" ok || check "all $EXPECTED checks of the rule ran" "$ran ran"

finish
