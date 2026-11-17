// area-check-named-texts.mjs <named.ts> <checkout root> <NAME> <commands.ts>: the list of texts the
// area check keeps for a script it lets through by name (payload/mods/area-check/hooks/named.ts),
// held to the texts themselves. A run is let through only while every listed text is unchanged, so a
// file the script sources or runs that the list lacks could change with nothing noticing (L96).
//
// Each shell text is read by mod-kit's reader of shell commands (commands.ts, the reader the area
// check itself reads a command with), which knows quoting, so a message quoting a run,
// `echo "(bash x.sh)"`, runs nothing (#3134). It reads what the shell runs wherever it runs it:
// after ; && and |, in $(...) and backticks, inside functions and subshells, a heredoc or a -c fed to
// a shell, and past the words that only run the next command. What it cannot read is refused, never
// skipped (fail closed):
//   - eval runs its words as a line, read here as one; eval of text the shell builds is refused
//   - a command named by a variable: the values this text gives the variable are read, and one
//     naming a program file is a run of it, one holding a shell, interpreter or source is refused,
//     and one this text never sets (a program the environment or PATH names) is printed as BYVALUE
//   - anything else the reader says it cannot read (ssh, an alias, a shell reading what feeds it)
// And a second reading, line by line, by the spelling this helper used before #3134: a line that
// spells a run or a source the whole reading did not find there is read again on its own, and is
// refused when it reads as a run there. So a line the quoting reading took for text is let pass
// only when the same reader, given that line alone, finds no run in it either.
//
// Printed, one fact a line, for the suite that asks (tests/area-check-named-reader.sh named_texts):
//   SCRIPT <path>     the script, from the root of its checkout
//   TEXT <path>       each listed text
//   LINES <n>         how many commands sourcing a file were found, across the listed texts
//   RUNS <n>          how many commands running a program file were found
//   RAN <where>       each of those runs, as text:line and the line itself, so a count the suite did
//                     not expect names what it counted
//   BYVALUE <where>   each command named by a variable this text never sets, as text:line and the
//                     word: it runs a program the environment or PATH names, which no list of texts
//                     can hold
//   PROBLEM <what>    a file sourced or run that the list lacks, a listed text nothing sources or
//                     runs, one that cannot be read, a line whose file cannot be named, or a command
//                     this reading cannot read
// The suite states how many LINES and RUNS it expects, since a reading gone blind finds none and
// would pass every check after it (L98).
import { readFileSync } from 'node:fs'
const [namedPath, root, entry, commandsPath] = process.argv.slice(2)
const named = (await import(namedPath))[entry]
if (!named) {
  console.log(`PROBLEM\tnamed.ts exports no ${entry}`)
  process.exit(0)
}
if (!commandsPath) throw new Error('no path to mod-kit hooks/commands.ts was given, so no text can be read')
const { pipeline } = await import(commandsPath)
const base = p => p.slice(p.lastIndexOf('/') + 1)
const listed = new Set(named.texts.map(base))
const used = new Set()
const problems = []
let lines = 0
let runs = 0
const ranAt = []
const byValue = []
const second = true  // control: no-second-reading
const FILE = String.raw`([A-Za-z0-9_.-]+\.(?:sh|py|mjs|cjs|js|ts|rb|pl))\b`
// A command word that is itself a program file, run by its path (`./x.sh`, `"$DIR/x.py"`).
const DIRECT = new RegExp(String.raw`^(?:[^\s|;&()<>'"]*/)?([A-Za-z0-9_.-]+\.(?:sh|py|mjs|cjs|js|ts|rb|pl))$`)
// A shell or interpreter, which given no program and no file runs what feeds it.
const INTERPRETER = /^(?:python3?(?:\.[0-9]+)?|node|bun|deno|ruby|perl|bash|sh|zsh|dash|ksh)$/
// A value that holds a shell, an interpreter, eval or a source as a word.
const SPELLED = /(?:^|[\s"'=(;&|`])(?:python3?|node|bun|deno|ruby|perl|bash|sh|zsh|dash|ksh|source|eval|\.)(?=$|[\s"';)`])/
// The file a word names: on the word itself, or through a variable the same text gives such a name.
const nameOf = (word, body) => {
  const direct = new RegExp(FILE).exec(word)?.[1]
  if (direct) return direct
  const v = /^"?\$\{?([A-Za-z_][A-Za-z0-9_]*)/.exec(word)?.[1]
  return (v && new RegExp(`^\\s*${v}=.*?${FILE}`, 'm').exec(body)?.[1]) || undefined
}

// The spelling read before #3134, now the second reading: where a command starts on a line, a line
// that sources a file (`. x`, `source x`), and one that runs a program file (an interpreter at the
// start of a command, and the first word after it that is no option). One given its program on the
// command line (`perl -e`, `python3 -c`, `python3 -`) names no file.
const START = String.raw`(?:^|[;&|{(]|\b(?:if|then|else|elif|do|while|until)\b|!)\s*`
const SOURCES = new RegExp(`${START}(?:\\.|source)\\s+(\\S.*)$`)
const RUNS = new RegExp(`${START}(?:python3?|node|bun|deno|ruby|perl|bash|sh|zsh)\\s+(\\S.*)$`)
const programWord = rest => {
  for (const word of rest.split(/\s+/)) {
    if (word === '-' || /^-[A-Za-z]*[ce]$/.test(word)) return null
    if (!word.startsWith('-')) return word
  }
  return null
}

const readAlone = line => {
  try {
    return pipeline(line)
  } catch {
    return undefined
  }
}
const nameWord = c => (c.words[0] === 'builtin' ? c.words[1] : c.words[0]) ?? ''

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
  const all = body.split('\n')
  const located = new Set()
  let cursor = 0
  const taken = new Map()
  // The line a command found in the whole text stands on: the first, from the last one found, whose
  // words read on their own give a command named the same with the same target that no command found
  // before has taken; else the first holding both words as text; else unknown. Only for saying where;
  // the count is the whole reading's.
  const locate = (w0, target) => {
    const tokens = [base(w0), target && base(target)].filter(Boolean)
    const order = [...all.keys()].slice(cursor).concat([...all.keys()].slice(0, cursor))
    const has = i => tokens.every(t => all[i].includes(t))
    const key = i => `${i}\t${w0}\t${target ?? ''}`
    const free = i => (readAlone(all[i]) ?? []).filter(d => nameWord(d) === w0 && (!target || d.words.includes(target) || d.script?.files.includes(target))).length > (taken.get(key(i)) ?? 0)
    const at = order.find(k => has(k) && free(k))
    const i = at ?? order.find(has)
    if (i === undefined) return '?'
    if (at !== undefined) taken.set(key(at), (taken.get(key(at)) ?? 0) + 1)
    cursor = i
    located.add(i)
    return i + 1
  }
  const checkName = (verb, word, where) => {
    const name = nameOf(word, body)
    if (!name) problems.push(`${text}:${where} ${verb} a file this suite cannot name: ${all[where - 1]?.trim() ?? word}`)
    else if (!listed.has(name)) problems.push(`${text}:${where} ${verb} ${name}, which ${entry}.texts does not list`)
    else used.add(name)
  }
  const ran = (w0, word) => {
    const where = locate(w0, word)
    runs++
    ranAt.push(`${text}:${where} ${all[where - 1]?.trim() ?? `${w0} ${word}`}`)
    checkName('runs', word, where)
  }
  const refuse = (w0, why) => {
    const where = locate(w0)
    problems.push(`${text}:${where} ${why}: ${all[where - 1]?.trim() ?? w0}`)
  }
  const judge = c => {
    const words = c.words[0] === 'builtin' ? c.words.slice(1) : c.words
    const w0 = words[0] ?? ''
    if (c.unread) {  // control: no-refusal
      if (w0 === 'eval') {
        const rest = words.slice(1)
        const evaled = rest.some(w => /[$`]/.test(w)) ? undefined : readAlone(rest.join(' '))
        if (!evaled) refuse(w0, 'evals text the shell builds as it runs, which this suite cannot read')
        else for (const d of evaled) judge(d)
        return
      }
      const v = /^\$\{?([A-Za-z_][A-Za-z0-9_]*)/.exec(w0)?.[1]
      if (!v) return refuse(w0, `runs what this suite cannot read (${c.unread})`)
      const values = [...body.matchAll(new RegExp(String.raw`(?:^|[^A-Za-z0-9_$])${v}=(.*)$`, 'gm'))].map(m => m[1])
      const file = values.map(x => new RegExp(FILE).exec(x)?.[1]).find(Boolean)
      if (file) return ran(w0, file)
      if (values.some(x => SPELLED.test(x))) return refuse(w0, `runs $${v}, which this text sets to a shell, interpreter or source this suite cannot follow`)
      const where = locate(w0)
      byValue.push(`${text}:${where} ${w0}`)
      return
    }
    if (w0 === '.' || w0 === 'source') {
      lines++
      const where = locate(w0, words[1])
      if (words[1] === undefined) problems.push(`${text}:${where} sources nothing it names: ${all[where - 1]?.trim()}`)
      else checkName('sources', words[1], where)
      return
    }
    if (c.script) {
      for (const f of c.script.files) ran(w0, f)
      return
    }
    if (c.program && 'unreadable' in c.program) return refuse(w0, `runs a program this suite cannot read (${c.program.unreadable})`)
    const direct = DIRECT.exec(w0)?.[1]
    if (direct) return ran(w0, w0)
    if (INTERPRETER.test(base(w0)) && !c.program) refuse(w0, `runs ${w0} on what feeds it, which this suite cannot read`)
  }
  let commands
  try {
    commands = pipeline(body)  // control: no-substitutions
  } catch (err) {
    problems.push(`${text} cannot be read as shell commands (${err.message})`)
    continue
  }
  for (const c of commands) judge(c)
  if (!second) continue
  for (const [i, line] of all.entries()) {
    if (located.has(i) || /^\s*#/.test(line)) continue
    const sourced = SOURCES.exec(line)
    const spelled = sourced ? sourced[1] : RUNS.exec(line) ? programWord(RUNS.exec(line)[1]) : null
    if (spelled === null) continue
    const alone = readAlone(line)
    if (alone === undefined || alone.some(d => d.script || d.unread || ['.', 'source'].includes(nameWord(d))))
      problems.push(`${text}:${i + 1} reads as a run or a source on its own line, and as text in the whole of ${text}: ${line.trim()}`)
  }
}
for (const text of named.texts) if (text !== named.script && !used.has(base(text))) problems.push(`${text} is listed and no listed text sources or runs it`)
if (named.texts[0] !== named.script) problems.push(`the list does not start with ${named.script}`)
console.log(`LINES\t${lines}`)
console.log(`RUNS\t${runs}`)
for (const r of ranAt) console.log(`RAN\t${r}`)
for (const b of byValue) console.log(`BYVALUE\t${b}`)
console.log(`SCRIPT\t${named.script}`)
for (const t of named.texts) console.log(`TEXT\t${t}`)
for (const p of problems) console.log(`PROBLEM\t${p}`)
