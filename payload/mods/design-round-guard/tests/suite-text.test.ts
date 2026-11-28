import { expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import { SKIP_QUESTION } from '../hooks/rules.ts'
import { call, refusalOf, withKit, world } from './world.ts'

// #3602: scripts whose helper names what it was handed through an operator, or whose loop words
// are cut up inside a command substitution. Every script here that is held really writes a screen
// file, or hands one to a writer, when it runs. Two suites of this repository have the same shapes
// and write nothing; they stay held with them until the guard can tell the two apart (#3602).

const run = async ($: Parameters<typeof call>[0], path: string) => refusalOf(await call($, { tool: 'Bash', command: `bash ${path}` }))
const files = (scripts: Record<string, string>) => ({ '/w/slate/app/page.tsx': 'x\n', ...Object.fromEntries(Object.entries(scripts).map(([path, text]) => [`/w/slate/${path}`, `${text}\n`])) })
const allHeld = async ($: Parameters<typeof call>[0], on: Parameters<typeof world>[1], scripts: Record<string, string>) => {
  const w = world($, on, { files: files(scripts) })
  for (const path of Object.keys(scripts)) expect({ path, held: (await run($, path)).includes(SKIP_QUESTION) }).toEqual({ path, held: true })
  expect(w.ran).toEqual([])
}

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

// From payload/skills/disk-full/test-disk-full-skill.sh: its helper and its two loops, whose words
// are commands the skill's text must hold, each looked for with grep inside a command substitution.
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

test('#3602: a helper that only prints the word it was handed, and a loop word a quiet grep reads inside a substitution, run unasked', withKit, async ($, on) => {
  const scripts: Record<string, string> = {
    'tools/test-prints-word.sh': 'show(){ echo "got: $1"; }\nshow app/page.tsx',
    'tools/test-loop-quiet.sh': 'check(){ echo "$1"; }\nfor want in \'python3 app/page.tsx\'; do\n  check "$(grep -q "$want" notes.txt && echo ok)"\ndone',
  }
  const w = world($, on, { files: files(scripts) })
  for (const path of Object.keys(scripts)) expect({ path, said: await run($, path) }).toEqual({ path, said: '' })
  expect(w.ran.length).toBe(2)
})

test('#3602: the two suites of this repository whose helper prints a piece, or whose loop words are looked for inside a substitution, are held like the scripts that write', withKit, async ($, on) => {
  await allHeld($, on, {
    'tools/test-lessons-core-rerank.sh': RERANK,
    'payload/skills/disk-full/test-disk-full-skill.sh': DISK,
    'tools/test-prints-piece.sh': 'show(){ echo "first: ${2:0:3} of ${#2}"; printf \'%s\\n\' "${1:-none}" "${3:-}" "${1:?usage}" "${4:+}"; }\nshow app/page.tsx "$x"',
    'tools/test-prints-rest.sh': 'show(){ echo "got: ${@:2}"; printf \'%s\\n\' "${3##*/}"; }\nshow app/page.tsx one "$two"',
  })
})

test('#3602: a helper that hands on what it was handed, in whatever form it names it, is held', withKit, async ($, on) => {
  await allHeld($, on, {
    // The suite's helper, with a writer of its second word added to its body.
    'tools/test-writes.sh': `${RERANK_CHECK.replace('echo "FAIL: $1";', 'echo "FAIL: $1"; prettier --write "$2";')}\ncheck "the page" "rerank-2026-10.html" "$page"`,
    // A piece of the word, a default for it, and the word with an ending taken off, each handed to a writer.
    'tools/test-piece.sh': 'show(){ prettier --write "${1:0:1500}"; }\nshow app/page.tsx',
    'tools/test-default.sh': 'show(){ prettier --write "${1:-none}"; }\nshow app/page.tsx',
    'tools/test-trimmed.sh': 'save(){ printf x > "${1%.bak}"; }\nsave app/globals.css',
    'tools/test-length.sh': 'save(){ printf "${#1}" > "$1"; }\nsave app/globals.css',
    'tools/test-rest.sh': 'show(){ prettier --write "${@:2}"; }\nshow x app/page.tsx',
    'tools/test-replaced.sh': 'save(){ printf x > "${1/page.tsx/globals.css}"; }\nsave app/page.tsx',
    'tools/test-replaced-prints.sh': 'show(){ echo "${1/page.tsx/globals.css}"; }\nshow app/page.tsx',
    // Run as a command, and kept in a variable the body then writes.
    'tools/test-runs.sh': 'go(){ ${1:0:1500} --write app/page.tsx; }\ngo prettier',
    'tools/test-kept.sh': 'save(){ local f="${1:0:1500}"; printf x > "$f"; }\nsave app/globals.css',
    // A script named as a suite that writes a stylesheet itself.
    'tools/test-style.sh': `${RERANK}\nprintf 'a{}' > app/globals.css`,
  })
})

// Each call below hands the helper a screen file the body does not touch, and each body writes
// another screen file, or may, through text the reader of the script's own lines cannot see.

test('#3602: a piece of a word, or a count of one, as a flag, a program, an operand or one part of a name, is held whatever command it stands in', withKit, async ($, on) => {
  await allHeld($, on, {
    'tools/test-count-part.sh': 'save(){ printf y > "app/page${#1}.tsx"; }\nsave app/site.tsx',
    'tools/test-piece-part.sh': 'save(){ printf y > "app/${2:0:4}.tsx"; }\nsave app/site.tsx pageXYZ',
    'tools/test-piece-live.sh': 'save(){ printf y > "app/${2:0:4}.tsx"; }\nsave app/site.tsx "$name"',
    'tools/test-piece-flag.sh': 'fmt(){ sed "${2:0:2}" s/a/b/ app/page.tsx; }\nfmt app/site.tsx -i',
    'tools/test-piece-flag-word.sh': 'fmt(){ sed "${2:0:2}" s/a/b/ "$1"; }\nfmt app/page.tsx -i',
    'tools/test-piece-flag-piece.sh': 'fmt(){ sed "${2:0:2}" s/a/b/ "${1:0:100}"; }\nfmt app/page.tsx -i',
    'tools/test-piece-flag-unknown.sh': 'fmt(){ sed "${2:0:2}" s/a/b/ "$f"; }\nfmt app/site.tsx -i',
    'tools/test-piece-write-unknown.sh': 'save(){ printf y > "${2%.bak}"; }\nsave app/site.tsx "$name"',
    'tools/test-piece-touch-unknown.sh': 'save(){ touch "${2%.bak}"; }\nsave app/site.tsx "$name"',
    'tools/test-trim-other.sh': 'save(){ printf y > "${2%.bak}"; }\nsave app/site.tsx app/page.tsx.bak',
    'tools/test-offset-other.sh': 'save(){ printf y > "${2:0:12}"; }\nsave app/site.tsx app/page.tsxZZ',
    'tools/test-piece-runs.sh': 'go(){ "${2:0:8}" --write "$3"; }\ngo app/site.tsx prettier "$f"',
    'tools/test-piece-later.sh': 'go(){ xargs "${2:0:8}" --write; }\ngo app/site.tsx prettier',
    'tools/test-piece-shell.sh': 'go(){ bash -c "${2:0:40}"; }\ngo app/site.tsx "$cmd"',
    'tools/test-piece-remote.sh': 'go(){ ssh "$3" "${2:0:40}"; }\ngo app/site.tsx "$cmd" "$host"',
    'tools/test-piece-command.sh': 'go(){ command "${2:0:8}" --write "$3"; }\ngo app/site.tsx prettier "$f"',
    'tools/test-piece-behind.sh': 'go(){ timeout 5 "${2:0:8}" --write "$3"; }\ngo app/site.tsx prettier "$f"',
    'tools/test-piece-inner.sh': 'fmt(){ sed "$1" s/a/b/ "$f"; }\nshow(){ fmt "${2:0:2}"; }\nshow app/site.tsx -i',
    'tools/test-piece-kept.sh': 'save(){ printf -v f %s "${2:0:12}"; printf y > "$f"; }\nsave app/site.tsx app/page.tsxZZ',
    'tools/test-piece-read.sh': 'save(){ read -r f <<< "${2:0:12}"; printf y > "$f"; }\nsave app/site.tsx app/page.tsxZZ',
    // A program the write reader knows as a reader, made a writer by the piece: no word beside the
    // piece has the shape of a screen file.
    'tools/test-piece-sed-glob.sh': 'fmt(){ sed "${2:0:2}" s/a/b/ app/*; }\nfmt app/site.tsx -i',
    'tools/test-piece-sort.sh': 'srt(){ sort "${2%X}" notes.txt; }\nsrt app/site.tsx -oapp/page.tsxX',
    'tools/test-piece-find.sh': 'clean(){ find app "${2%X}"; }\nclean app/site.tsx -deleteX',
    'tools/test-piece-awk.sh': 'gen(){ awk "${2%X}" notes.txt; }\ngen app/site.tsx \'BEGIN{print 1 > "app/page.tsx"}X\'',
    'tools/test-piece-git.sh': 'go(){ git ${2:0:8} -- app; }\ngo app/site.tsx checkout',
    'tools/test-piece-curl.sh': 'get(){ curl "${2%X}" https://example.com/x; }\nget app/site.tsx -oapp/page.tsxX',
    'tools/test-piece-dd.sh': 'cp2(){ dd "${2%X}" if=notes.txt; }\ncp2 app/site.tsx of=app/page.tsxX',
    'tools/test-piece-perl.sh': 'fmt(){ perl "${2:0:2}" -pe s/a/b/ app/*; }\nfmt app/site.tsx -i',
  })
})

test('#3602: a piece that is only printed is held, since what is printed can reach a writer in the body, at the call, or through a function named echo', withKit, async ($, on) => {
  await allHeld($, on, {
    'tools/test-piece-piped.sh': 'go(){ echo "${2:0:12}" | xargs touch; }\ngo app/site.tsx app/page.tsxZZ',
    'tools/test-print-group.sh': 'go(){ { echo "${2:0:12}"; } | xargs touch; }\ngo app/site.tsx app/page.tsxZZ',
    'tools/test-print-subshell.sh': 'go(){ ( echo "${2:0:12}" ) | xargs touch; }\ngo app/site.tsx app/page.tsxZZ',
    'tools/test-print-tee.sh': 'go(){ { echo "${2:0:12}"; echo x; } | tee /dev/null | xargs touch; }\ngo app/site.tsx app/page.tsxZZ',
    'tools/test-print-process.sh': 'save(){ while read -r f; do printf y > "$f"; done < <(echo "${2%.bak}"); }\nsave app/site.tsx app/page.tsx.bak',
    'tools/test-print-file-run.sh': 'go(){ echo "${2:0:40}" > /tmp/run.sh; bash /tmp/run.sh; }\ngo app/site.tsx \'prettier --write app\'',
    'tools/test-print-loop.sh': 'go(){ for i in 1; do echo "${2:0:12}"; done | xargs touch; }\ngo app/site.tsx app/page.tsxZZ',
    // The body only prints. The writer stands where the helper is called, or is the script's own echo.
    'tools/test-print-call-piped.sh': 'go(){ echo "${2:0:12}"; }\ngo app/site.tsx app/page.tsxZZ | xargs touch',
    'tools/test-print-call-inside.sh': 'go(){ echo "${2:0:12}"; }\ntouch "$(go app/site.tsx app/page.tsxZZ)"',
    'tools/test-print-outer-piped.sh': 'go(){ echo "${2:0:12}"; }\nouter(){ go app/site.tsx app/page.tsxZZ; }\nouter | xargs touch',
    'tools/test-print-call-file-run.sh': 'go(){ echo "${2:0:40}"; }\ngo app/site.tsx \'prettier --write app\' > /tmp/run.sh\nbash /tmp/run.sh',
    'tools/test-print-own-echo.sh': 'echo(){ touch "$@"; }\ngo(){ echo "${2:0:12}"; }\ngo app/site.tsx app/page.tsxZZ',
  })
})

test('#3602: a piece that is only printed is held where the command that runs the script pipes what it prints to a writer', withKit, async ($, on) => {
  const w = world($, on, { files: files({ 'tools/test-print-command.sh': 'go(){ echo "${2:0:12}"; }\ngo app/site.tsx app/page.tsxZZ' }) })
  expect(refusalOf(await call($, { tool: 'Bash', command: 'bash tools/test-print-command.sh | xargs touch' }))).toContain(SKIP_QUESTION)
  expect(w.ran).toEqual([])
})

test("#3602: a default's or an alternative's own text is held, however many words the shell makes of the call", withKit, async ($, on) => {
  await allHeld($, on, {
    'tools/test-alt-text.sh': 'save(){ printf y > ${1:+app/page.tsx}; }\nsave app/site.tsx',
    'tools/test-default-text.sh': 'save(){ printf y > "${2:-app/page.tsx}"; }\nsave app/site.tsx',
    'tools/test-default-part.sh': 'save(){ printf y > "app/${2:-page}.tsx"; }\nsave app/site.tsx',
    'tools/test-default-live.sh': 'save(){ printf y > "${2:-app/page.tsx}"; }\nsave app/site.tsx "$none"',
    'tools/test-alt-flag.sh': 'fmt(){ sed ${1:+-i} s/a/b/ app/page.tsx; }\nfmt app/site.tsx',
    // A word of the call that the shell makes none of, or several: the words after it move.
    'tools/test-default-all.sh': 'save(){ echo "$2"; printf y > "${3:-app/page.tsx}"; }\nsave "$@" app/site.tsx notes.txt',
    'tools/test-default-bare.sh': 'save(){ echo "$2"; printf y > "${3:-app/page.tsx}"; }\nsave $OPT app/site.tsx notes.txt',
    'tools/test-default-dash-all.sh': 'save(){ echo "$2"; printf y > "${3-app/page.tsx}"; }\nsave "$@" app/site.tsx notes.txt',
    'tools/test-default-array.sh': 'save(){ echo "$2"; printf y > "${3:-app/page.tsx}"; }\nsave "${ARGS[@]}" app/site.tsx notes.txt',
    'tools/test-default-output.sh': 'save(){ echo "$2"; printf y > "${3:-app/page.tsx}"; }\nsave $(cat opts.txt) app/site.tsx notes.txt',
    'tools/test-alt-bare.sh': 'fmt(){ sed ${3:+-i} s/a/b/ app/page.tsx; }\nfmt $EXTRA app/site.tsx',
    'tools/test-alt-pattern.sh': 'fmt(){ sed ${3:+-i} s/a/b/ app/page.tsx; }\nfmt app/site.tsx notes*',
    'tools/test-alt-one-letter.sh': 'fmt(){ sed ${3:+-i} s/a/b/ app/page.tsx; }\nfmt app/site.tsx note?.txt',
    'tools/test-alt-braces.sh': 'fmt(){ sed ${3:+-i} s/a/b/ app/page.tsx; }\nfmt app/site.tsx {a,b}',
  })
})

test('#3602: a default or a usage check that gives the word of the call is held, where that word is a flag, a program or one part of a name', withKit, async ($, on) => {
  await allHeld($, on, {
    'tools/test-default-gives-flag.sh': 'fmt(){ sed "${2:-x}" s/a/b/ app/page.tsx; }\nfmt app/site.tsx -i',
    'tools/test-usage-gives-flag.sh': 'fmt(){ sed "${2:?usage}" s/a/b/ app/page.tsx; }\nfmt app/site.tsx -i',
    'tools/test-default-gives-part.sh': 'save(){ printf y > "app/${2:-x}.tsx"; }\nsave app/site.tsx page',
    'tools/test-dash-gives-flag.sh': 'fmt(){ sed "${2-x}" s/a/b/ app/page.tsx; }\nfmt app/site.tsx -i',
    'tools/test-default-gives-program.sh': 'go(){ "${2:-true}" --write app; }\ngo app/site.tsx prettier',
    'tools/test-usage-gives-part.sh': 'save(){ printf y > "app/${2:?need}.tsx"; }\nsave app/site.tsx page',
  })
})

test('#3602: a loop word holding a space, cut up inside a command substitution and handed on, is held', withKit, async ($, on) => {
  await allHeld($, on, {
    'tools/test-spaced-echo.sh': "for pair in 'app/page.tsx app/site.tsx'; do\n  mystery $(echo $pair)\ndone",
    'tools/test-spaced-cut.sh': "for spec in 'light app/page.tsx'; do\n  mystery \"$(echo \"$spec\" | cut -d' ' -f2)\"\ndone",
    'tools/test-spaced-cut-helper.sh': "fix(){ prettier --write \"$1\"; }\nfor spec in 'light app/page.tsx'; do\n  fix \"$(echo \"$spec\" | cut -d' ' -f2)\"\ndone",
    'tools/test-spaced-tail-helper.sh': "fix(){ prettier --write \"$1\"; }\nfor spec in 'light app/page.tsx'; do\n  fix \"$(printf '%s\\n' $spec | tail -1)\"\ndone",
    'tools/test-spaced-backquote.sh': "for pair in 'app/page.tsx app/site.tsx'; do\n  mystery `echo $pair`\ndone",
    // The substitution prints text typed in it, and the helper makes a name of that.
    'tools/test-spaced-joined.sh': "fix(){ prettier --write \"app/$1.tsx\"; }\nfor f in 'x app/site.tsx'; do\n  fix \"$(grep -q \"$f\" notes.txt && echo page)\"\ndone",
  })
})

test('#3602: a loop that writes each of its words, or hands each to a program, is held', withKit, async ($, on) => {
  await allHeld($, on, {
    'tools/test-loop-writes.sh': "for f in app/globals.css app/site.css; do\n  printf 'a{}' > \"$f\"\ndone",
    'tools/test-loop-hands.sh': 'for f in app/page.tsx app/site.tsx; do\n  prettier --write "$f"\ndone',
    // The loop's word reaches the helper as a word of its own, beside one a command prints.
    'tools/test-loop-helper.sh': 'fmt() { prettier --write "$1"; }\nfor f in app/page.tsx; do\n  fmt "$f" "$(grep -c x "$f")"\ndone',
    'tools/test-loop-unknown.sh': 'for f in app/page.tsx; do\n  mystery "$(grep -c x notes.txt)" "$f"\ndone',
  })
})

// Held through mod-kit reading an array's values as commands of their own. A change to that
// reading has to go on holding both.
test('#3602: an array holding a command that is run afterwards, or names handed to a program, is held', withKit, async ($, on) => {
  await allHeld($, on, {
    'tools/test-array-runs.sh': 'cmd=( prettier --write app/page.tsx )\n"${cmd[@]}"',
    'tools/test-array-hands.sh': 'files=( notes.txt app/page.tsx )\nmystery "${files[@]}"',
  })
})
