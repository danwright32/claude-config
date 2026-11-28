import { expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import { SKIP_QUESTION, calledWith, fromInsideOutput, handedToUnknown } from '../hooks/rules.ts'
import { call, refusalOf, withKit, world } from './world.ts'

// #3602: a plain run of a test suite, held because text inside the suite file was read as a write
// of a screen file. Each case is the suite's own lines as they stood on the day it was held, at
// the path it was run by, and beside each stands a script that does write what it names, which is
// held before and after.

const run = async ($: Parameters<typeof call>[0], path: string) => refusalOf(await call($, { tool: 'Bash', command: `bash ${path}` }))
const files = (scripts: Record<string, string>) => ({ '/w/slate/app/page.tsx': 'x\n', ...Object.fromEntries(Object.entries(scripts).map(([path, text]) => [`/w/slate/${path}`, `${text}\n`])) })

// tools/test-lessons-core-rerank.sh, held twice on the night of 2026-11-26: line 30's helper, and
// the lines that hand it a page's name as the text a listing is expected to hold.
const RERANK_CHECK = 'check(){ if [[ "$3" == *"$2"* ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; echo "  expected to contain: $2"; echo "  actual: ${3:0:1500}"; fi; }'
const RERANK = [
  'pass=0; fail=0',
  RERANK_CHECK,
  'check_not(){ if [[ "$3" != *"$2"* ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 (must not contain \'$2\')"; echo "  actual: ${3:0:1500}"; fi; }',
  'page="$(ls "$STATE"/rerank-2026-10.html 2>/dev/null)"',
  'check "the page is left in the state folder, by month" "rerank-2026-10.html" "$page"',
  'check "and the list to apply beside it" "core-2026-10.txt" "$(ls "$STATE" 2>/dev/null)"',
  'check_not "and no page for the month before" "rerank-2026-09.html" "$(ls "$STATE" 2>/dev/null)"',
].join('\n')

test('#3602: a name handed to a helper the suite defines, which prints a piece of what it was handed, runs unasked', withKit, async ($, on) => {
  const w = world($, on, { files: files({ 'tools/test-lessons-core-rerank.sh': RERANK }) })
  expect(await run($, 'tools/test-lessons-core-rerank.sh')).toBe('')
  expect(w.ran.length).toBe(1)
})

test('#3602: a helper that hands on what it was handed, in whatever form it names it, is still held', withKit, async ($, on) => {
  const scripts: Record<string, string> = {
    // The suite's helper, with a writer of its second word added to its body.
    'tools/test-writes.sh': `${RERANK_CHECK.replace('echo "FAIL: $1";', 'echo "FAIL: $1"; prettier --write "$2";')}\ncheck "the page" "rerank-2026-10.html" "$page"`,
    // A piece of the word, a default for it, and the word with an ending taken off, each handed to a writer.
    'tools/test-piece.sh': 'show(){ prettier --write "${1:0:1500}"; }\nshow app/page.tsx',
    'tools/test-default.sh': 'show(){ prettier --write "${1:-none}"; }\nshow app/page.tsx',
    'tools/test-trimmed.sh': 'save(){ printf x > "${1%.bak}"; }\nsave app/globals.css',
    'tools/test-length.sh': 'save(){ printf "${#1}" > "$1"; }\nsave app/globals.css',
    'tools/test-rest.sh': 'show(){ prettier --write "${@:2}"; }\nshow x app/page.tsx',
    // Run as a command, and kept in a variable the body then writes.
    'tools/test-runs.sh': 'go(){ ${1:0:1500} --write app/page.tsx; }\ngo prettier',
    'tools/test-kept.sh': 'save(){ local f="${1:0:1500}"; printf x > "$f"; }\nsave app/globals.css',
    // A script named as a suite that writes a stylesheet itself.
    'tools/test-style.sh': `${RERANK}\nprintf 'a{}' > app/globals.css`,
  }
  const w = world($, on, { files: files(scripts) })
  for (const path of Object.keys(scripts)) expect({ path, held: (await run($, path)).includes(SKIP_QUESTION) }).toEqual({ path, held: true })
  expect(w.ran).toEqual([])
})

// payload/skills/disk-full/test-disk-full-skill.sh, held on 2026-11-25: its helper and its two
// loops, whose words are commands the skill's text must hold, each looked for with grep inside a
// command substitution.
// The second loop's fourth word in the suite, a file's size and dates asked in the BSD form, is
// left out: tests/test-stat-order.sh fails on that text in any file outside the disk skill.
const DISK = [
  'pass=0',
  'fail=0',
  'check() { # check <description> <result>   ("ok" passes, anything else is the failure text)',
  '  if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi',
  '}',
  "for swap_cmd in 'sysctl vm.swapusage' 'df -h /System/Volumes/VM' 'top -l 1 -o mem -n 10 -stats pid,command,mem,time'; do",
  '  check "the swap step runs: $swap_cmd" \\',
  '    "$(grep -qxF "$swap_cmd" <<< "$swap_code" && echo ok || echo "not a line in a block of the swap step")"',
  'done',
  "for want in 'python3 ~/.claude/hooks/lib/disk-writers.py' 'lsof +c 0 -n -P +L1' 'lsof -a -n -P -p <pid> +L1' \\",
  "    'memory_pressure | tail -1'; do",
  '  check "the writer step runs: $want" \\',
  '    "$(grep -qF -- "$want" <<< "$writer_code" && echo ok || echo "not in a block of the writer step")"',
  'done',
].join('\n')

test("#3602: the words of a suite's own for loop, named inside a command substitution, are no files it writes", withKit, async ($, on) => {
  const w = world($, on, { files: files({ 'payload/skills/disk-full/test-disk-full-skill.sh': DISK }) })
  expect(await run($, 'payload/skills/disk-full/test-disk-full-skill.sh')).toBe('')
  // With its output sent to a notes file, as the held call ran it.
  expect(refusalOf(await call($, { tool: 'Bash', command: 'bash payload/skills/disk-full/test-disk-full-skill.sh > /tmp/claude-501/-w-slate/s1/scratchpad/tests.txt 2>&1' }))).toBe('')
  expect(w.ran.length).toBe(2)
})

test('#3602: a loop that writes each of its words, or hands each to a program, is still held', withKit, async ($, on) => {
  const scripts: Record<string, string> = {
    'tools/test-loop-writes.sh': "for f in app/globals.css app/site.css; do\n  printf 'a{}' > \"$f\"\ndone",
    'tools/test-loop-hands.sh': 'for f in app/page.tsx app/site.tsx; do\n  prettier --write "$f"\ndone',
    // The loop's word reaches the helper as a word of its own, beside one a command prints.
    'tools/test-loop-helper.sh': 'fmt() { prettier --write "$1"; }\nfor f in app/page.tsx; do\n  fmt "$f" "$(grep -c x "$f")"\ndone',
    'tools/test-loop-unknown.sh': 'for f in app/page.tsx; do\n  mystery "$(grep -c x notes.txt)" "$f"\ndone',
  }
  const w = world($, on, { files: files(scripts) })
  for (const path of Object.keys(scripts)) expect({ path, held: (await run($, path)).includes(SKIP_QUESTION) }).toEqual({ path, held: true })
  expect(w.ran).toEqual([])
})

test('#3602: fromInsideOutput is true only of a plain name made from the text inside a command substitution', () => {
  const sub = '$(grep -qxF "$c" <<< "$code" && echo ok || echo "not a line")'
  expect(fromInsideOutput(sub, '/w/slate/tests/sysctl')).toBe(true)
  expect(fromInsideOutput('`grep -c "$c" notes.txt`', '/w/slate/tests/df')).toBe(true)
  expect(fromInsideOutput('$(grep -c ")" "$c")', '/w/slate/tests/df')).toBe(true)
  // A word that is no command's output, or whose name is spelled beside one.
  expect(fromInsideOutput('$f', '/w/slate/app/page.tsx')).toBe(false)
  expect(fromInsideOutput('$(git rev-parse --show-toplevel)/app/page.tsx', '/w/slate/app/page.tsx')).toBe(false)
  // A variable beside the substitution may spell the name itself.
  expect(fromInsideOutput('$f$(date +%s)', '/w/slate/app/page.tsx')).toBe(false)
  expect(fromInsideOutput('$(echo "(") $c $(echo ")")', '/w/slate/app/page.tsx')).toBe(false)
  expect(fromInsideOutput('`date` $c', '/w/slate/app/page.tsx')).toBe(false)
  // A name still holding its substitution, and a substitution never closed.
  expect(fromInsideOutput('x $(a | b) y', '/s/x $(a | b) y')).toBe(false)
  expect(fromInsideOutput('x `a` y', '/s/x `a` y')).toBe(false)
  expect(fromInsideOutput('$(echo x', '/w/slate/app/page.tsx')).toBe(false)
  expect(fromInsideOutput('`echo x', '/w/slate/app/page.tsx')).toBe(false)
})

test('#3602: handedToUnknown gives no plain name made inside a substitution, and still gives a word the shell hands on as written', () => {
  const run = (args: { word: string; path: string; unexpanded?: boolean }[]) => ({ script: 'mystery', what: 'a program the mods do not know', unknown: true as const, args })
  const sub = '$(grep -c "$c" notes.txt)'
  expect(handedToUnknown([run([{ word: sub, path: '/s/sysctl' }, { word: '$f', path: '/s/app/page.tsx' }])]).map(h => h.path)).toEqual(['/s/app/page.tsx'])
  expect(handedToUnknown([run([{ word: sub, path: '/s/app/page.tsx', unexpanded: true }])]).map(h => h.path)).toEqual(['/s/app/page.tsx'])
})

test('#3602: calledWith writes a word named through an operator as the whole word, and leaves what it cannot write', () => {
  expect(calledWith('echo "${3:0:1500}" "${1:-none}" "${2:+--flag}" ${#1} "${@:2}" "${1%.bak}" "${4:-none}" "${5:+x}" "${2//b/c}" "${12}" "${1:?usage}"', ['a', 'b', 'c'])).toBe(
    `echo "c" "a" "--flag" 0 "a b c" "a" "none" "" "b" "${calledWith('$9', [])}" "a"`,
  )
  // A variable named by the word, an assignment the shell refuses, the script's own name, and an
  // operand holding an expansion of its own are left for the caller to refuse.
  expect(calledWith('echo "${!1}" "${1:=x}" "${0}" "${1:-$2}" "${1:-"x"}"', ['a', 'b'])).toBe('echo "${!1}" "${1:=x}" "${0}" "${1:-b}" "${1:-"x"}"')
})
