// area-check-named-texts.mjs <named.ts> <checkout root> <NAME>: the list of texts the area check
// keeps for a script it lets through by name (payload/mods/area-check/hooks/named.ts), held to the
// texts themselves. A run is let through only while every listed text is unchanged, so a file the
// script sources or runs that the list lacks could change with nothing noticing (L96).
//
// Printed, one fact a line, for the suite that asks (tests/area-check-named-reader.sh named_texts):
//   SCRIPT <path>     the script, from the root of its checkout
//   TEXT <path>       each listed text
//   LINES <n>         how many lines sourcing a file were found, across the listed texts
//   RUNS <n>          how many lines running a program file were found
//   PROBLEM <what>    a file sourced or run that the list lacks, a listed text nothing sources or
//                     runs, one that cannot be read, or a line whose file cannot be named
// The suite states how many LINES and RUNS it expects, since a reading gone blind finds none and
// would pass every check after it (L98).
import { readFileSync } from 'node:fs'
const [namedPath, root, entry] = process.argv.slice(2)
const named = (await import(namedPath))[entry]
if (!named) {
  console.log(`PROBLEM\tnamed.ts exports no ${entry}`)
  process.exit(0)
}
const base = p => p.slice(p.lastIndexOf('/') + 1)
const listed = new Set(named.texts.map(base))
const used = new Set()
const problems = []
let lines = 0
let runs = 0
// Where a command starts on a line.
const START = String.raw`(?:^|[;&|{(]|\b(?:if|then|else|elif|do|while|until)\b|!)\s*`
// A line that sources a file: `. x` or `source x` at the start of a command.
const SOURCES = new RegExp(`${START}(?:\\.|source)\\s+(\\S.*)$`)
// A line that runs a program file: an interpreter at the start of a command, and its first word.
// One given a program on the command line (`perl -e`, `python3 -c`, `python3 -`) names no file.
const RUNS = new RegExp(`${START}(?:python3?|node|bun|deno|ruby|perl|bash|sh|zsh)\\s+(\\S+)`)
const FILE = String.raw`([A-Za-z0-9_.-]+\.(?:sh|py|mjs|cjs|js|ts|rb|pl))\b`
// The file a word names: on the word itself, or through a variable the same text gives such a name.
const nameOf = (word, body) => {
  const direct = new RegExp(FILE).exec(word)?.[1]
  if (direct) return direct
  const v = /^"?\$\{?([A-Za-z_][A-Za-z0-9_]*)/.exec(word)?.[1]
  return (v && new RegExp(`^\\s*${v}=.*?${FILE}`, 'm').exec(body)?.[1]) || undefined
}
for (const text of named.texts) {
  let body
  try {
    body = readFileSync(`${root}/${text}`, 'utf8')
  } catch (err) {
    problems.push(`${text} is listed and cannot be read (${err.code})`)
    continue
  }
  // Only a shell text sources or runs by these spellings; another program's imports are its suite's.
  if (!text.endsWith('.sh')) continue
  for (const [i, line] of body.split('\n').entries()) {
    if (/^\s*#/.test(line)) continue
    const sourced = SOURCES.exec(line)
    const ran = sourced ? null : RUNS.exec(line)
    if (ran && ran[1].startsWith('-')) continue
    const m = sourced ?? ran
    if (!m) continue
    if (sourced) lines++
    else runs++
    const verb = sourced ? 'sources' : 'runs'
    const name = nameOf(m[1], body)
    if (!name) problems.push(`${text}:${i + 1} ${verb} a file this suite cannot name: ${line.trim()}`)
    else if (!listed.has(name)) problems.push(`${text}:${i + 1} ${verb} ${name}, which ${entry}.texts does not list`)
    else used.add(name)
  }
}
for (const text of named.texts) if (text !== named.script && !used.has(base(text))) problems.push(`${text} is listed and no listed text sources or runs it`)
if (named.texts[0] !== named.script) problems.push(`the list does not start with ${named.script}`)
console.log(`LINES\t${lines}`)
console.log(`RUNS\t${runs}`)
console.log(`SCRIPT\t${named.script}`)
for (const t of named.texts) console.log(`TEXT\t${t}`)
for (const p of problems) console.log(`PROBLEM\t${p}`)
