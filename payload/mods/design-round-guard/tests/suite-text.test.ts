import { expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import { OWN_PIECE, OWN_PIECE_END, SKIP_QUESTION, calledWith, fromInsideOutput, handedToUnknown } from '../hooks/rules.ts'
import { call, refusalOf, withKit, world } from './world.ts'

// #3602: a plain run of a test suite must not be held for text inside the suite file that only
// names a screen file. Each case holds lines copied from a suite of this repository, placed at the
// suite's own path, and beside each stands a script that does write what it names, which is held.

const run = async ($: Parameters<typeof call>[0], path: string) => refusalOf(await call($, { tool: 'Bash', command: `bash ${path}` }))
const files = (scripts: Record<string, string>) => ({ '/w/slate/app/page.tsx': 'x\n', ...Object.fromEntries(Object.entries(scripts).map(([path, text]) => [`/w/slate/${path}`, `${text}\n`])) })

// From tools/test-lessons-core-rerank.sh: a helper that compares two strings and prints the start
// of one, and the lines that hand it a page's name as the text a listing is expected to hold.
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
    // A replacement can spell a name the word does not hold, so its body is not read at all.
    'tools/test-replaced.sh': 'save(){ printf x > "${1/page.tsx/globals.css}"; }\nsave app/page.tsx',
    'tools/test-replaced-prints.sh': 'show(){ echo "${1/page.tsx/globals.css}"; }\nshow app/page.tsx',
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

test('#3602: a helper whose body spells a name, a flag or a count through an operator, where the reader cannot see what it spells, is still held', withKit, async ($, on) => {
  // Each call hands the helper a screen file the body does not touch, and each body really writes
  // another screen file, or may.
  const scripts: Record<string, string> = {
    // An alternative's or a default's own text, as the whole name, one part of it, or a flag.
    'tools/test-alt-text.sh': 'save(){ printf y > ${1:+app/page.tsx}; }\nsave app/site.tsx',
    'tools/test-default-text.sh': 'save(){ printf y > "${2:-app/page.tsx}"; }\nsave app/site.tsx',
    'tools/test-default-part.sh': 'save(){ printf y > "app/${2:-page}.tsx"; }\nsave app/site.tsx',
    'tools/test-default-live.sh': 'save(){ printf y > "${2:-app/page.tsx}"; }\nsave app/site.tsx "$none"',
    'tools/test-alt-flag.sh': 'fmt(){ sed ${1:+-i} s/a/b/ app/page.tsx; }\nfmt app/site.tsx',
    // A count, or a piece of a word that names no file, as one part of a name or as a flag.
    'tools/test-count-part.sh': 'save(){ printf y > "app/page${#1}.tsx"; }\nsave app/site.tsx',
    'tools/test-piece-part.sh': 'save(){ printf y > "app/${2:0:4}.tsx"; }\nsave app/site.tsx pageXYZ',
    'tools/test-piece-live.sh': 'save(){ printf y > "app/${2:0:4}.tsx"; }\nsave app/site.tsx "$name"',
    'tools/test-piece-flag.sh': 'fmt(){ sed "${2:0:2}" s/a/b/ app/page.tsx; }\nfmt app/site.tsx -i',
    'tools/test-piece-flag-word.sh': 'fmt(){ sed "${2:0:2}" s/a/b/ "$1"; }\nfmt app/page.tsx -i',
    'tools/test-piece-flag-piece.sh': 'fmt(){ sed "${2:0:2}" s/a/b/ "${1:0:100}"; }\nfmt app/page.tsx -i',
    // Beside a name the reader cannot follow, and as a name it cannot follow itself.
    'tools/test-piece-flag-unknown.sh': 'fmt(){ sed "${2:0:2}" s/a/b/ "$f"; }\nfmt app/site.tsx -i',
    'tools/test-piece-write-unknown.sh': 'save(){ printf y > "${2%.bak}"; }\nsave app/site.tsx "$name"',
    'tools/test-piece-touch-unknown.sh': 'save(){ touch "${2%.bak}"; }\nsave app/site.tsx "$name"',
    // A piece that spells a screen file the whole word does not, written beside a word the call
    // hands and the body leaves alone.
    'tools/test-trim-other.sh': 'save(){ printf y > "${2%.bak}"; }\nsave app/site.tsx app/page.tsx.bak',
    'tools/test-offset-other.sh': 'save(){ printf y > "${2:0:12}"; }\nsave app/site.tsx app/page.tsxZZ',
    // A piece run as the command, run later, handed to another helper, piped on, or kept.
    'tools/test-piece-runs.sh': 'go(){ "${2:0:8}" --write "$3"; }\ngo app/site.tsx prettier "$f"',
    'tools/test-piece-later.sh': 'go(){ xargs "${2:0:8}" --write; }\ngo app/site.tsx prettier',
    'tools/test-piece-shell.sh': 'go(){ bash -c "${2:0:40}"; }\ngo app/site.tsx "$cmd"',
    'tools/test-piece-remote.sh': 'go(){ ssh "$3" "${2:0:40}"; }\ngo app/site.tsx "$cmd" "$host"',
    'tools/test-piece-command.sh': 'go(){ command "${2:0:8}" --write "$3"; }\ngo app/site.tsx prettier "$f"',
    'tools/test-piece-behind.sh': 'go(){ timeout 5 "${2:0:8}" --write "$3"; }\ngo app/site.tsx prettier "$f"',
    'tools/test-piece-inner.sh': 'fmt(){ sed "$1" s/a/b/ "$f"; }\nshow(){ fmt "${2:0:2}"; }\nshow app/site.tsx -i',
    'tools/test-piece-piped.sh': 'go(){ echo "${2:0:12}" | xargs touch; }\ngo app/site.tsx app/page.tsxZZ',
    'tools/test-piece-kept.sh': 'save(){ printf -v f %s "${2:0:12}"; printf y > "$f"; }\nsave app/site.tsx app/page.tsxZZ',
    'tools/test-piece-read.sh': 'save(){ read -r f <<< "${2:0:12}"; printf y > "$f"; }\nsave app/site.tsx app/page.tsxZZ',
  }
  const w = world($, on, { files: files(scripts) })
  for (const path of Object.keys(scripts)) expect({ path, held: (await run($, path)).includes(SKIP_QUESTION) }).toEqual({ path, held: true })
  expect(w.ran).toEqual([])
})

test('#3602: a helper that only prints a piece of a word, its length, or the word with a default, runs unasked', withKit, async ($, on) => {
  const scripts: Record<string, string> = {
    'tools/test-prints-piece.sh': 'show(){ echo "first: ${2:0:3} of ${#2}"; printf \'%s\\n\' "${1:-none}" "${3:-}" "${1:?usage}" "${4:+}"; }\nshow app/page.tsx "$x"',
    'tools/test-prints-rest.sh': 'show(){ echo "got: ${@:2}"; printf \'%s\\n\' "${3##*/}"; }\nshow app/page.tsx one "$two"',
  }
  const w = world($, on, { files: files(scripts) })
  for (const path of Object.keys(scripts)) expect({ path, said: await run($, path) }).toEqual({ path, said: '' })
  expect(w.ran.length).toBe(2)
})

// From payload/skills/disk-full/test-disk-full-skill.sh: its helper and its two loops, whose words
// are commands the skill's text must hold, each looked for with grep inside a command substitution.
// Nothing in them writes a file.
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
  // With its output sent to a file in the scratchpad.
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

// Held through mod-kit reading an array's values as commands of their own. A change to that
// reading has to go on holding both.
test('#3602: an array holding a command that is run afterwards, or names handed to a program, is held', withKit, async ($, on) => {
  const scripts: Record<string, string> = {
    'tools/test-array-runs.sh': 'cmd=( prettier --write app/page.tsx )\n"${cmd[@]}"',
    'tools/test-array-hands.sh': 'files=( notes.txt app/page.tsx )\nmystery "${files[@]}"',
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

test('#3602: calledWith writes a piece of a word between its marks, a default or an alternative only where the shell gives the word or nothing, and leaves what it cannot write', () => {
  const none = calledWith('$9', []) as string
  const piece = (word: string): string => `${OWN_PIECE}${word}${OWN_PIECE_END}`
  expect(calledWith('echo "${3:0:1500}" ${#1} "${@:2}" "${1%.bak}" "${2##*/}" "${12}" "${4:0:2}"', ['a', 'b', 'c'])).toBe(
    `echo "${piece('c')}" ${piece('0')} "${piece('a b c')}" "${piece('a')}" "${piece('b')}" "${none}" "${piece(none)}"`,
  )
  // The word itself where the call typed one, and nothing where the shell gives nothing.
  expect(calledWith('echo "${1:-none}" "${1-none}" "${1:?usage}" "${4:-}" "${4:+x}" "${2:+}" "${@:-none}"', ['a', 'b', 'c'])).toBe('echo "a" "a" "a" "" "" "" "a b c"')
  // An operand's own text is never written in: where the shell would give it, the body is not read.
  for (const form of ['${4:-none}', '${4-none}', '${2:+--flag}', '${2+x}', '${4:?usage}', '${1:-none}x${5:-y}']) expect({ form, got: calledWith(`echo "${form}"`, ['a', 'b', 'c']) }).toEqual({ form, got: undefined })
  // A word of the call the shell has still to expand may come out empty, and so may an empty one.
  expect(calledWith('echo "${1:-x}"', [none])).toBe(undefined)
  expect(calledWith('echo "${1:+x}"', [none])).toBe(undefined)
  expect(calledWith('echo "${1-x}" "${1:?usage}" "${1:-}"', [none])).toBe(`echo "${none}" "${none}" "${none}"`)
  expect(calledWith('echo "${1:-x}"', [''])).toBe(undefined)
  expect(calledWith('echo "${1+x}"', [''])).toBe(undefined)
  expect(calledWith('echo "${1-x}" "${1:+x}"', [''])).toBe('echo "" ""')
  // A variable named by the word, an assignment the shell refuses, the script's own name, an
  // operand holding an expansion of its own, and a replacement or a change of case, whose text the
  // word does not hold, are left for the caller to refuse.
  expect(calledWith('echo "${!1}" "${1:=x}" "${0}" "${1:-$2}" "${1:-"x"}" "${1/a/app/page.tsx}" "${2//b/c}" "${1^^}" "${1,}"', ['a', 'b'])).toBe(
    'echo "${!1}" "${1:=x}" "${0}" "${1:-b}" "${1:-"x"}" "${1/a/app/page.tsx}" "${2//b/c}" "${1^^}" "${1,}"',
  )
})
