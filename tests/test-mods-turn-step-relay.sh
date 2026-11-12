#!/bin/bash
# No mod in this payload registers a turn.step hook that only relays the model's stream (#2726).
# Claude Code carries every model response of every agent through the hooks worker while such a hook
# is registered, and when it replaces a wedged worker mid stream the pieces in transit are in
# neither half: a tool call's input then runs with 15 to 22 characters missing (measured, 3 of 5
# probe runs). The status bar's relay was the only one, and Dan moved it off turn.step on 2026-11-11;
# this keeps the exposure from coming back.
#   - The scan tokenises with the pinned TypeScript compiler's scanner, never by matching quotes (#2779).
#   - The scanner reads every hook source file under payload/mods/*/hooks (tests folders aside), and
#     finds every place the file names turn.step outside a comment.
#   - Each must be an on('turn.step', ...) call written inline; one whose every yield passes the
#     response on unchanged (yield* next(...), or yield of the loop variable of a for await over
#     next(...)) is a relay and fails. A hook that yields anything else changes the stream and is
#     not a relay. A name it cannot read (a hook passed by name, turn.step in a variable) fails too,
#     since an unread hook cannot be cleared (L247).
#   - Fixtures prove each verdict, the status bar's own hook as it was before #2726 among them (L1),
#     and the real tree must have hook files to read, so an empty enumeration cannot pass (L98).
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
  echo "FAIL: node is not installed, so the turn.step relay scan could not be run"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

# The pinned compiler (#1496), linked in for a checkout that lacks it. Without it the files cannot be
# read, which fails rather than passes (L98, L411).
TS_DIR="${CHECK_MODS_TS_DIR:-$ROOT/tools/typescript}"
PINNED_TS_WHY=""
if . "$ROOT/tools/lib/pinned-compiler.sh" 2>/dev/null; then
  pinned_compiler_ensure "$TS_DIR" >/dev/null 2>&1 || true
else
  PINNED_TS_WHY="tools/lib/pinned-compiler.sh is missing"
fi
if [ ! -f "$TS_DIR/node_modules/typescript/dist/ast/index.js" ]; then
  echo "FAIL: the pinned TypeScript compiler is not in $TS_DIR, so the turn.step relay scan could not read any file ${PINNED_TS_WHY}"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-mods-turn-step-relay.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/scan.mjs" <<'JS'
import { readFileSync, readdirSync, statSync, existsSync } from 'node:fs'
import { join, relative } from 'node:path'
import { pathToFileURL } from 'node:url'
const [mods, tsDir] = process.argv.slice(2)
const ast = await import(pathToFileURL(join(tsDir, 'node_modules', 'typescript', 'dist', 'ast', 'index.js')).href)
const files = []
const walk = d => {
  for (const n of readdirSync(d).sort()) {
    const p = join(d, n)
    if (statSync(p).isDirectory()) { if (n !== 'tests' && n !== 'node_modules') walk(p) }
    else if (/\.(ts|tsx|js|jsx|mjs|mts)$/.test(n) && !/\.d\.ts$/.test(n)) files.push(p)
  }
}
for (const mod of readdirSync(mods).sort()) {
  const h = join(mods, mod, 'hooks')
  if (existsSync(h) && statSync(h).isDirectory()) walk(h)
}
// Two copies of the text, the same length: comments blanked, and comments and string contents blanked.
// The pinned TypeScript compiler's own scanner reads the file, so where a string, a template (nested
// ones, and ${...} expressions, included), a regular expression or a comment starts and ends is the
// language's answer, never a guess at the next quote or backtick (#2779). Positions in the two copies
// are the file's own, so a character offset into either is an offset into the file.
const SK = ast.SyntaxKind
const VALUE_END = new Set([SK.Identifier, SK.NumericLiteral, SK.BigIntLiteral, SK.StringLiteral, SK.NoSubstitutionTemplateLiteral,
  SK.TemplateTail, SK.RegularExpressionLiteral, SK.CloseParenToken, SK.CloseBracketToken, SK.CloseBraceToken, SK.ThisKeyword,
  SK.SuperKeyword, SK.TrueKeyword, SK.FalseKeyword, SK.NullKeyword, SK.PlusPlusToken, SK.MinusMinusToken, SK.PrivateIdentifier])
const mask = text => {
  const code = text.split(''), bare = text.split('')
  const sc = ast.createScanner(true, ast.LanguageVariant.Standard, text)
  const blank = (a, b, both) => { for (let k = a; k < b; k++) if (text[k] !== '\n') { bare[k] = ' '; if (both) code[k] = ' ' } }
  const stack = []   // 'b' for an open brace, 't' for a ${ inside a template
  let prev, last = 0
  for (let tok = sc.scan(); tok !== SK.EndOfFile; tok = sc.scan()) {
    if (tok === SK.SlashToken || tok === SK.SlashEqualsToken) { if (!VALUE_END.has(prev)) tok = sc.reScanSlashToken() }
    else if (tok === SK.CloseBraceToken && stack[stack.length - 1] === 't') tok = sc.reScanTemplateToken(false)
    const a = sc.getTokenStart(), b = sc.getTokenEnd()
    blank(last, a, true)   // whatever the scanner skipped between tokens: comments (and white space)
    last = b
    if (tok === SK.OpenBraceToken) stack.push('b')
    else if (tok === SK.CloseBraceToken) stack.pop()
    else if (tok === SK.TemplateHead) { stack.push('t'); blank(a + 1, b - 2, false) }
    else if (tok === SK.TemplateMiddle) blank(a + 1, b - 2, false)
    else if (tok === SK.TemplateTail) { stack.pop(); blank(a + 1, b - 1, false) }
    else if (tok === SK.NoSubstitutionTemplateLiteral || tok === SK.StringLiteral) blank(a + 1, b - 1, false)
    else if (tok === SK.RegularExpressionLiteral) blank(a, b, false)
    prev = tok
  }
  blank(last, text.length, true)
  return { code: code.join(''), bare: bare.join('') }
}
const lineOf = (text, at) => text.slice(0, at).split('\n').length
const closing = (bare, open) => {
  let depth = 0
  for (let k = open; k < bare.length; k++) {
    if (bare[k] === '(') depth++
    else if (bare[k] === ')' && --depth === 0) return k
  }
  return -1
}
// A hook that passes every piece of the response on as it came: delegation to next's stream, or the
// loop variable of a for await over it, yielded as is.
const relays = call => {
  const loops = [...call.matchAll(/for\s+await\s*\(\s*(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s+of\s+next\s*\(/g)].map(m => m[1])
  const yields = [...call.matchAll(/\byield\b\s*(\*)?\s*([^\n;}]*)/g)]
  if (yields.length === 0) return false
  return yields.every(([, star, rest]) => {
    const r = rest.trim()
    if (star) return /^next\s*\(/.test(r)
    return loops.some(v => r === v)
  })
}
let read = 0
for (const f of files) {
  const text = readFileSync(f, 'utf8')
  read++
  const { code, bare } = mask(text)
  const rel = relative(join(mods, '..', '..'), f)
  for (const m of code.matchAll(/(['"`])turn\.step\1/g)) {
    const at = m.index
    const before = bare.slice(Math.max(0, at - 40), at)
    const opener = before.match(/\bon\s*\(\s*$/)
    if (!opener) { console.log(JSON.stringify({ rel, line: lineOf(text, at), verdict: 'unreadable', why: 'turn.step named outside an on(...) call' })); continue }
    const open = at - (before.length - opener.index) + opener[0].indexOf('(')
    const close = closing(bare, open)
    if (close < 0) { console.log(JSON.stringify({ rel, line: lineOf(text, at), verdict: 'unreadable', why: 'the on(...) call never closes' })); continue }
    const call = code.slice(open, close + 1)
    if (!/function\s*\*|=>/.test(call)) { console.log(JSON.stringify({ rel, line: lineOf(text, at), verdict: 'unreadable', why: 'the hook is not written inline' })); continue }
    console.log(JSON.stringify({ rel, line: lineOf(text, at), verdict: relays(call) ? 'relay' : 'ok' }))
  }
}
console.log(JSON.stringify({ read }))
JS

scan(){ node --no-warnings "$TMP/scan.mjs" "$1" "$TS_DIR" 2>&1; }
fixture(){   # $1 = mod name; the hook file's text on stdin
  mkdir -p "$TMP/fx/$1/payload/mods/$1/hooks"
  cat >"$TMP/fx/$1/payload/mods/$1/hooks/register.ts"
}
verdict(){   # $1 = fixture name  $2 = expected verdict line fragment
  local out; out="$(scan "$TMP/fx/$1/payload/mods")"
  case "$out" in *"$2"*) check "$1 reads as $2" ok ;; *) check "$1 reads as $2" "$out" ;; esac
}

# The status bar's hook as it stood before #2726, character for character.
fixture status-bar-before <<'TS'
export const register = on => {
  on('turn.step', async function* ($, e, next) {
    if (interactive && e.agentId === undefined) {
      // Also what takes this conversation's quiet background commands off the band while Claude
      // works (#1583): cacheMoved below draws the band again from it.
      await setTurnRunning($, true)
      try {
        await $.state.set(cacheRef, (await $.clock.now()) + CACHE_MS)
        $.clock.after(0, () => void cacheMoved($))
      } catch (err) {
        $.ui.log(`status-bar: could not restart the cache clock: ${msg(err)}`, { to: 'debug' })
      }
    }
    return yield* next(e)
  })
}
TS
verdict status-bar-before '"verdict":"relay"'

# The probe that reproduced the loss: a for await relay with a matcher.
fixture probe-loop <<'TS'
export const register = on => {
  on("turn.step", { agentId: undefined }, async function* ($, e, next) {
    let pieces = 0
    for await (const c of next(e)) {
      if (c.kind === 'input') pieces++
      yield c
    }
    $.ui.log(`relayed ${pieces}`)
  })
}
TS
verdict probe-loop '"verdict":"relay"'

# A hook that rewrites what it passes on is not a relay.
fixture rewriter <<'TS'
export const register = on => {
  on('turn.step', async function* ($, e, next) {
    for await (const c of next(e)) {
      yield c.kind === 'text' ? { ...c, text: c.text.toUpperCase() } : c
    }
  })
}
TS
verdict rewriter '"verdict":"ok"'

# One that answers without sending a request yields nothing and relays nothing.
fixture answerer <<'TS'
export const register = on => {
  on('turn.step', async function* ($, e) {
    return { turnId: e.turnId, index: e.index, answer: '', toolUses: [] }
  })
}
TS
verdict answerer '"verdict":"ok"'

# A hook passed by name, and turn.step held in a variable, cannot be read, so they fail.
fixture by-name <<'TS'
const relay = async function* ($, e, next) { return yield* next(e) }
export const register = on => { on('turn.step', relay) }
TS
verdict by-name '"verdict":"unreadable"'
fixture in-a-variable <<'TS'
const EVENT = 'turn.step'
export const register = on => { on(EVENT, async function* ($, e, next) { return yield* next(e) }) }
TS
verdict in-a-variable '"verdict":"unreadable"'

# A comment naming a relay is no registration.
fixture comment-only <<'TS'
// The status bar once had on('turn.step', async function* ($, e, next) { return yield* next(e) }).
/* on("turn.step", relay) */
export const register = on => { on('turn.start', ($, e, next) => next(e)) }
TS
out="$(scan "$TMP/fx/comment-only/payload/mods")"
case "$out" in *verdict*) check "a comment naming turn.step is not read as a hook" "$out" ;; *'{"read":1}'*) check "a comment naming turn.step is not read as a hook" ok ;; *) check "a comment naming turn.step is not read as a hook" "$out" ;; esac

# A template nested inside ${...} (L1: fails on a reader that ends a template at the next backtick).
fixture nested-template <<'TS'
const label = `a ${ x ? `b ${ y }` : '`' } c`; export const register = on => { on('turn.step', async function* ($, e, next) { return yield* next(e) }) }
TS
verdict nested-template '"verdict":"relay"'
fixture nested-template-two <<'TS'
const a = `${`${'`'}`}`, b = `}${'`'}`; export const register = on => { on('turn.step', async function* ($, e, next) { return yield* next(e) }) }
TS
verdict nested-template-two '"verdict":"relay"'
# A regex literal holding a quote or backtick, and a division, do not open a string.
fixture regex-literal <<'TS'
const r = /['"`]/g, h = 4 / 2 / 1; export const register = on => { on('turn.step', async function* ($, e, next) { return yield* next(e) }) }
TS
verdict regex-literal '"verdict":"relay"'

# The real tree.
out="$(scan "$ROOT/payload/mods")"; rc=$?
if [ "$rc" -ne 0 ]; then
  check "the scan ran over payload/mods" "exit=$rc out=$out"
else
  n="$(printf '%s\n' "$out" | sed -n -E 's/^\{"read":([0-9]+)\}$/\1/p')"
  # 173 on 2026-11-11; a reader finding far fewer has stopped walking the tree.
  [ -n "$n" ] && [ "$n" -ge 100 ] && check "the scan read the real mods' hook files ($n)" ok || check "the scan read the real mods' hook files" "read ${n:-none}: $out"
  bad="$(printf '%s\n' "$out" | grep -E '"verdict":"(relay|unreadable)"')"
  [ -z "$bad" ] && check "no mod registers a turn.step hook that only relays, or one the scan cannot read" ok \
    || check "no mod registers a turn.step hook that only relays, or one the scan cannot read" "a turn.step hook carries every model response through the hooks worker, and Claude Code drops pieces of a tool call's input when it replaces that worker mid stream (#2726). Hear the moment another way (turn.start, session.append, tool.call): $bad"
fi

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
