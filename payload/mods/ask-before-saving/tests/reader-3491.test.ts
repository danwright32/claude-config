import { expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import { commandWrites } from './mod-kit/hooks/writes.ts'
import { removalCandidates } from '../hooks/rules.ts'

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
