#!/bin/bash
# The programs mod-kit's write reader reads as only reading (claude-config#3323). A program the
# reader does not know, handed a word that spells a path, is read as a writer, and READ_ONLY in
# payload/mods/mod-kit/hooks/writes.ts is the exemption: 32 programs Dan signed off by name on
# 2026-11-21. Nothing joins it without his sign off, so this suite holds the list to the record of
# what he signed, the table in docs/mods-design.md under "The programs that only read":
#   - The same names both ways, exactly 32, so a program added to the code alone, or to the table
#     alone, turns red here (L96).
#   - Each row gives the reader's own reason, a sign off naming Dan, the date and the issue, and each
#     form of the program that writes (rg --pre, file -C and the rest), so a reason or a form changed
#     in one place alone turns red too.
#   - Against the real reader: each listed program handed a file is read as writing nothing, each of
#     its forms that writes is read as a writer, and `[[` and a made up name are read as programs it
#     does not know.
#   - Every name writes.ts compares a command's program against (a `name === '...'`, a key of a table
#     asked with the name, a member of a set asked with it) is read as known, so a branch added
#     without the reader counting it as read turns red. The names are scanned from the file's text,
#     and the scan finding too few is itself a failure (L100).
#   - gh is the one name compared against that is not read as known (claude-config#3412): it has a
#     reading of its own grammar that takes away only the words gh's manual proves are no path. It
#     is held here to staying a program the reader does not know, handed the file, in every form
#     that grammar does not prove, and to being on no list.
# Each docs check is then run against a table made wrong on purpose, and must fail there (L1).
#
# What this cannot catch, said so it is never claimed (L460): a reason that is false, a sign off
# typed in without Dan giving it, a new version of a listed program gaining an option that writes,
# another program installed under a listed name, and an option set in a config file rather than on
# the command (RIPGREP_CONFIG_PATH).
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
  echo "FAIL: node is not installed, so the write reader's list could not be read"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-read-only-programs.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
EXPECTED=24

cat >"$TMP/read.mjs" <<'JS'
import { readFileSync } from 'node:fs'
const [writesPath, docPath] = process.argv.slice(2)
const { READ_ONLY, commandWrites } = await import(writesPath)
const source = readFileSync(writesPath, 'utf8')
const doc = readFileSync(docPath, 'utf8')
let n = 0
const say = (name, ok, evidence) => {
  n++
  console.log(ok ? `PASS\t${name}` : `FAIL\t${name}\t${evidence}`)
}
const COUNT = 32
const SIGNED = /^Dan, 2026-11-21, #3323, "(Turn it round, with the list \(Recommended\)|Add them now)"$/
const listed = Object.keys(READ_ONLY)
const formsOf = name => (READ_ONLY[name].writes ?? []).map(w => w.form)

// The table as the docs hold it: the rows under the heading, up to the next heading.
const rowsIn = text => {
  const at = text.indexOf('\n### The programs that only read')
  if (at < 0) return null
  const end = text.indexOf('\n### ', at + 1)
  const rows = []
  for (const line of text.slice(at, end < 0 ? undefined : end).split('\n')) {
    const m = /^\| `(.+?)` \| (.*) \| (.*) \| (.*) \|$/.exec(line)
    if (m) rows.push({ name: m[1], why: m[2], forms: m[3], signed: m[4] })
  }
  return rows
}
// Each docs check as [name, ok, evidence], so the same checks run on a table made wrong on purpose.
const docChecks = text => {
  const rows = rowsIn(text) ?? []
  const names = rows.map(r => r.name)
  const row = name => rows.find(r => r.name === name)
  const missing = listed.filter(x => !names.includes(x))
  const extra = names.filter(x => !listed.includes(x))
  const reasons = rows.filter(r => listed.includes(r.name) && r.why !== READ_ONLY[r.name].why).map(r => r.name)
  const unsigned = rows.filter(r => !SIGNED.test(r.signed)).map(r => r.name)
  const forms = listed.filter(x => {
    const cell = row(x)?.forms ?? ''
    const want = formsOf(x)
    const got = [...cell.matchAll(/`([^`]+)`/g)].map(m => m[1])
    return want.length ? want.join('\n') !== got.join('\n') : cell !== 'none'
  })
  return [
    ['the table has exactly 32 rows, each name once', rows.length === COUNT && new Set(names).size === COUNT, `${rows.length} rows, ${new Set(names).size} distinct`],
    ['every program the reader lists has a row in the table', missing.length === 0, `no row for: ${missing.join(', ')}`],
    ['every row in the table is a program the reader lists', extra.length === 0, `not in READ_ONLY: ${extra.join(', ')}`],
    ["every row gives the reader's own reason", reasons.length === 0 && rows.every(r => r.why.trim() !== ''), `the reason differs for: ${reasons.join(', ')}`],
    ["every row carries Dan's sign off, with the date, the issue and his answer", rows.length > 0 && unsigned.length === 0, `no sign off on: ${unsigned.join(', ')}`],
    ['every row names exactly the forms of its program that the reader reads as a writer', forms.length === 0, `the forms differ for: ${forms.join(', ')}`],
  ]
}

say('the docs hold the section "The programs that only read"', rowsIn(doc) !== null, 'no heading "### The programs that only read" in docs/mods-design.md')
say('the reader lists exactly 32 programs, each with a reason', listed.length === COUNT && listed.every(x => typeof READ_ONLY[x].why === 'string' && READ_ONLY[x].why.trim() !== ''), `${listed.length} listed`)
for (const [name, ok, evidence] of docChecks(doc)) say(name, ok, evidence)
const allForms = listed.flatMap(x => formsOf(x).map(f => `${x} ${f}`))
say('the reader holds five forms that write', allForms.length === 5, allForms.join(', '))

// Against the real reader.
const read = c => commandWrites(c, '/w/app', '/Users/dan')
const unknownIn = c => (read(c).runs ?? []).filter(r => r.unknown)
const handed = name => (name === '[' ? '[ -f src/a.txt ]' : `${name} src/a.txt`)
const notQuiet = listed.filter(x => {
  const w = read(handed(x))
  return (w.runs ?? []).length || w.files.length || w.changes.length || w.unnamed.length
})
say('each listed program handed a file is read as writing nothing', notQuiet.length === 0, `read as writing: ${notQuiet.join(', ')}`)
const notHeld = listed.flatMap(x => (READ_ONLY[x].writes ?? []).filter(w => !unknownIn(`${x} ${w.form} x src/a.txt`).some(r => r.what.includes(w.form) && r.args.some(a => a.path === '/w/app/src/a.txt'))).map(w => `${x} ${w.form}`))
say('each form of a listed program that writes is read as a writer of what it is handed', notHeld.length === 0, `not read as a writer: ${notHeld.join(', ')}`)
// The control for the two checks around it: the reader does mark a program it does not know.
const strangers = ['[[ -f src/a.txt ]]', 'mystery src/a.txt', 'prettier --write src/a.txt'].filter(c => unknownIn(c).length !== 1)
say('`[[` and a program on no list are read as programs the reader does not know', strangers.length === 0, `not marked: ${strangers.join(' | ')}`)

// Every name the reader compares a command's program against. Single letters are option names
// compared in the readers of one program's options, never a program; `[` and `.` are programs.
const names = new Set()
const add = x => {
  if (/^[A-Za-z_][A-Za-z0-9_.+-]+$/.test(x) || x === '[' || x === '.') names.add(x)
}
for (const m of source.matchAll(/\bname === '([^']+)'/g)) add(m[1])
const asked = new Set()
for (const m of source.matchAll(/\bown\(([A-Z][A-Z_]*), name\)/g)) asked.add(m[1])
for (const m of source.matchAll(/\b([A-Z][A-Z_]*)\.has\(name\)/g)) asked.add(m[1])
const unparsed = []
for (const id of asked) {
  const at = source.search(new RegExp(`^(?:export )?const ${id}\\b`, 'm'))
  if (at < 0) {
    unparsed.push(id)
    continue
  }
  const line = source.slice(at, source.indexOf('\n', at))
  const set = /= new Set\(\[(.*)\]\)$/.exec(line)
  if (set) {
    for (const m of set[1].matchAll(/'([^']+)'/g)) add(m[1])
  } else if (line.endsWith('{')) {
    const body = source.slice(at, source.indexOf('\n}\n', at))
    for (const m of body.matchAll(/^  (?:'([^']+)'|([A-Za-z_][A-Za-z0-9_]*)):/gm)) add(m[1] ?? m[2])
  } else {
    const inline = /= \{(.*)\}$/.exec(line)
    if (!inline) unparsed.push(id)
    else for (const m of inline[1].matchAll(/(?:^|,)\s*(?:'([^']+)'|([A-Za-z_][A-Za-z0-9_]*)):/g)) add(m[1] ?? m[2])
  }
}
// 87 names were read out of the file on 2026-11-21, when Dan decided; fewer found is a broken scan.
say('the scan of writes.ts finds the names it compares against', names.size >= 87 && unparsed.length === 0 && ['tee', 'dd', 'cp', 'gzip', 'rm', 'vim', 'grep', 'printf', 'export'].every(x => names.has(x)), `${names.size} names found; tables it could not read: ${unparsed.join(', ') || 'none'}`)
// The three that unpack are known in the form that unpacks, and by design not in any other.
const UNPACKS = { tar: 'tar -xf src/a.tgz', bsdtar: 'bsdtar -xf src/a.tgz', gtar: 'gtar -xf src/a.tgz', cpio: 'cpio -i -F src/a.cpio', unzip: 'unzip src/a.zip' }
// gh (#3412) is compared against by name and is NOT read as known: it is on no list, least of all
// the 32, and stays a program the reader does not know. Its own grammar only takes away the words
// that grammar proves are no path, so it is asked here in a form where every word is one, and the
// two checks after this one hold it to being a stranger in every form the grammar does not cover.
const GH_ALL_PROVED = 'gh pr view 5 --json src/a.txt'
const unread = [...names].filter(x => unknownIn(x === 'gh' ? GH_ALL_PROVED : (UNPACKS[x] ?? handed(x))).length)
say('every name writes.ts compares a command against is read as known', unread.length === 0, `read as a program the reader does not know: ${unread.join(', ')}`)
say('writes.ts compares a command against gh, so the checks on it below are not vacuous', names.has('gh'), 'gh is not among the names scanned out of writes.ts')
const handedTo = c => unknownIn(c).filter(r => r.what === 'a program the write reader does not know' && r.script === 'gh').flatMap(r => r.args.map(a => a.path))
const ghStranger = [
  'gh src/a.txt', 'gh mystery src/a.txt', 'gh pr mystery src/a.txt', 'gh release download v1 --dir src/a.txt', 'gh run download 5 -D src/a.txt', 'gh repo clone o/r src/a.txt',
  'gh gist clone abc src/a.txt', 'gh extension install src/a.txt', 'gh pr view 5 --output src/a.txt', 'gh pr view 5 --json state -o src/a.txt', 'gh pr list src/a.txt',
  'gh pr create --title T --body-file src/a.txt', 'gh issue comment 5 -F src/a.txt', 'gh api repos/o/r/issues --input src/a.txt', 'gh pr create --title "$T" --json src/a.txt',
].filter(c => !handedTo(c).includes('/w/app/src/a.txt'))
say('gh handed a file in any form its grammar does not prove is no path is read as a program the reader does not know, handed that file', ghStranger.length === 0, `not handed the file: ${ghStranger.join(' | ')}`)
say('gh is not on the list of programs that only read', !listed.includes('gh'), 'gh is listed in READ_ONLY')
const listing = ['tar -tf src/a.tgz', 'cpio -o -F src/a.cpio', 'unzip -l src/a.zip'].filter(c => unknownIn(c).length !== 1)
say('a form of tar, cpio or unzip that unpacks nothing is read as a program the reader does not know', listing.length === 0, `not marked: ${listing.join(' | ')}`)
const unpacked = Object.values(UNPACKS).filter(c => !read(c).unnamed.some(u => /^an archive \S+ unpacks$/.test(u.what)))
say('an unpack is read as a write the words do not name', unpacked.length === 0, `not read as an unpack: ${unpacked.join(' | ')}`)

// The controls: each docs check fails on a table made wrong in the one way it guards.
const failing = (text, check) => docChecks(text).filter(([, ok]) => !ok).map(([name]) => name).includes(check)
const row = name => doc.split('\n').find(l => l.startsWith(`| \`${name}\` |`)) ?? ''
const control = (name, changed, check) => say(name, changed !== doc && failing(changed, check), changed === doc ? 'the table was not changed, so nothing was tried' : 'the check passed on the changed table')
control('control: a table missing a listed program is caught', doc.replace(`${row('wc')}\n`, ''), 'every program the reader lists has a row in the table')
control('control: a row for a program the reader does not list is caught', doc.replace(row('wc'), `${row('wc')}\n${row('wc').replace('`wc`', '`awk`')}`), 'every row in the table is a program the reader lists')
control('control: a reason changed in the table alone is caught', doc.replace(row('wc'), row('wc').replace(READ_ONLY.wc.why, 'counts things')), "every row gives the reader's own reason")
control('control: a row with no sign off is caught', doc.replace(row('wc'), row('wc').replace('Dan, 2026-11-21, #3323, ', '')), "every row carries Dan's sign off, with the date, the issue and his answer")
control('control: a form that writes left out of its row is caught', doc.replace(row('file'), row('file').replace('`-C`', 'none')), 'every row names exactly the forms of its program that the reader reads as a writer')
console.log(`DONE\t${n}`)
JS

out="$(node --experimental-strip-types --no-warnings "$TMP/read.mjs" "$ROOT/payload/mods/mod-kit/hooks/writes.ts" "$ROOT/docs/mods-design.md" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
  check "the real reader and the docs were read under node" "exit=$rc out=$out"
else
  seen=0
  while IFS=$'\t' read -r verdict name evidence; do
    case "$verdict" in
      PASS) seen=$((seen + 1)); check "$name" ok ;;
      FAIL) seen=$((seen + 1)); check "$name" "$evidence" ;;
    esac
  done <<<"$out"
  done_line="$(printf '%s\n' "$out" | grep -c "^DONE	$EXPECTED\$")"
  # Judged by the count run against the count expected, so a check that never ran is a failure (L288).
  [ "$seen" -eq "$EXPECTED" ] && [ "$done_line" -eq 1 ] && check "all $EXPECTED checks ran" ok || check "all $EXPECTED checks ran" "$seen ran: $out"
fi

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
