import { expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import { commandWrites } from './mod-kit/hooks/writes.ts'
import { mentioned, removalCandidates } from '../hooks/rules.ts'

// #3491: mod-kit's reader took `$'...'` for a plain single quoted string, so a command that set
// `x=$'it\'s'` and then removed a memory folder gave the mod nothing to read: the removal after the
// string was no candidate, and nothing was asked. Bash and zsh close that string and run the removal.
// Read as the mod reads a call: mod-kit's own reader, handed to the mod's own rule for what a
// removal would take.
const HOME = `${'/Users'}/dan`
const SLATE = `${HOME}/Apps/slate`
const BS = '\\'
const MEMORY = '~/.claude/projects/p/memory'
const candidates = async (command: string) =>
  (await removalCandidates(commandWrites(command, SLATE, HOME), HOME, async () => false, command, async () => false)).map(c => [c.file, c.how, c.tree === true])

test("#3491: a removal of a memory folder after a $'...' string holding an escaped quote is still a candidate to ask about", async () => {
  // The control: typed alone it is a candidate, so the lines below are judged for it and nothing else.
  const alone = await candidates(`rm -rf ${MEMORY}`)
  expect(alone).toEqual([[MEMORY, 'delete', true]])
  for (const command of [`x=$'it${BS}'s'\nrm -rf ${MEMORY}`, `x=$'it${BS}'s'; rm -rf ${MEMORY}`, `echo $'it${BS}'s' && rm -rf ${MEMORY}`])
    expect({ command, candidates: await candidates(command) }).toEqual({ command, candidates: alone })
})

// The fix round on pull request #3493. Where the reader cannot read a text as the shell that runs it
// does, it gives no removal, so the rule above has no candidate and the removal question is not
// asked. What it does give is the command marked unread, and the mod asks about an unread command
// through the lasting memory its words name (register.ts, lastingTargets; the question itself is
// pinned for an unread command in register.test.tsx, #3021). This is that route, by the mod's own
// rule for what a text names: the write reader's unread commands, and what their words mention.
const namedByUnread = async (command: string) => {
  const out: string[] = []
  for (const u of commandWrites(command, SLATE, HOME).unread ?? []) out.push(...(await mentioned(u.words.join('\n'), HOME, async () => false, undefined, u.folder, command)))
  return out
}

test('#3491: a removal after a quote bash and zsh read differently is unread, and its words name the memory folder to ask about', async () => {
  // Measured 2026-11-23: zsh reads `$$'a\'b'` as its own number and a `$'...'` string and runs the
  // removal; bash reads a plain quote and runs none of it. The reader said nothing of the removal.
  for (const command of [`x=$$'a${BS}'b'\nrm -rf ${MEMORY} # it's`, `p1 $$'a${BS}'b' ; rm -rf ${MEMORY} # it's`])
    expect({ command, candidates: await candidates(command), named: await namedByUnread(command) }).toEqual({ command, candidates: [], named: [MEMORY] })
  // The control: a removal typed alone is read whole, so nothing is unread and nothing is named this way.
  expect(await namedByUnread(`rm -rf ${MEMORY}`)).toEqual([])
})

test("#3491: a line bash and zsh refuse and dash would run past its $'...' string is unread, and its words name the memory folder", async () => {
  // Before #3491 the reader read this as dash does and gave the removal as a candidate. bash and zsh
  // run none of it (a syntax error, measured), and the reader now stops in the string: no candidate,
  // and the command it stops in is unread with the folder among its words.
  const command = `echo $'a${BS}' > x.txt ; rm -rf ${MEMORY} ; echo 'b'`
  expect({ candidates: await candidates(command), named: await namedByUnread(command) }).toEqual({ candidates: [], named: [MEMORY] })
})
