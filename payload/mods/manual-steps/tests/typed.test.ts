import { describe, expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import { onCard, typedCommands } from '../hooks/typed.ts'
import type { StepsCard } from '../types/index.d.ts'

// #3652: a slash command Dan has to type himself, handed over in a reply, is a manual step like any
// other, and the card is what keeps it in front of him. Only a command HANDED to him counts: one
// named, explained, offered as an option or run by Claude passes (measured, docs/mods-design.md
// "Manual steps").

describe('typedCommands', () => {
  test('the 2026-11-25 hand off: start it, with the brief in a code block', () => {
    const said = 'Your next move after those is to start `/plan-council` with this brief:\n\n```\n/plan-council Plan the import\n```'
    expect(typedCommands(said)).toEqual(['/plan-council'])
  })

  test('a code block that opens with a slash command is a command to type', () => {
    expect(typedCommands('Paste this:\n\n```\n/goal clear\n```')).toEqual(['/goal'])
    expect(typedCommands('```text\n/loop 5m /next-issue\n```')).toEqual(['/loop'])
  })

  test('an imperative to type, run, start or paste a slash command, leading its sentence or line', () => {
    expect(typedCommands('Type `/reload-plugins` and press Return.')).toEqual(['/reload-plugins'])
    expect(typedCommands('Next, run `/sync-config` on the work MacBook.')).toEqual(['/sync-config'])
    expect(typedCommands('1. Start **/plan-lite** with the brief below')).toEqual(['/plan-lite'])
    expect(typedCommands('Your next step is `/plan-council`.')).toEqual(['/plan-council'])
  })

  // The shapes the 30 days to 2026-11-25 handed Dan a command in, each worded afresh here.
  test('after a label, behind please or so, as "to do this, type", or said of Dan in the sentence', () => {
    expect(typedCommands('**One thing only you can do:** type `/reload-plugins`. The old mods are still loaded.')).toEqual(['/reload-plugins'])
    expect(typedCommands('**Please type `/compact` now.** The session is near its limit.')).toEqual(['/compact'])
    expect(typedCommands('The old area check is still loaded, so run `/reload-plugins` when you get a moment.')).toEqual(['/reload-plugins'])
    expect(typedCommands('To clear the goal, type `/goal clear`; I cannot run that myself.')).toEqual(['/goal'])
    expect(typedCommands('**To use the new picker here,** run `/reload-plugins`.')).toEqual(['/reload-plugins'])
    expect(typedCommands('This session keeps the old copies until you run `/reload-plugins`.')).toEqual(['/reload-plugins'])
    expect(typedCommands('Reloading it needs you to type `/reload-plugins`.')).toEqual(['/reload-plugins'])
    expect(typedCommands('Remember to type /reload-plugins in any open session.')).toEqual(['/reload-plugins'])
  })

  test('a command offered beside another way, or as what it would do, passes', () => {
    expect(typedCommands('You can type /compact, or start a fresh session from the note.')).toEqual([])
    expect(typedCommands('Typing `/compact` would shrink it.')).toEqual([])
    expect(typedCommands('Once it installs I will ask you to run `/reload-plugins` and look at it with me.')).toEqual([])
    expect(typedCommands('After a pull it now tells you to run `/reload-plugins`.')).toEqual([])
  })

  test('a command named, explained or offered passes', () => {
    expect(typedCommands('`/plan-council` runs a whole panel; `/plan-lite` is lighter.')).toEqual([])
    expect(typedCommands('If you want a fuller plan, you could start `/plan-council` later.')).toEqual([])
    expect(typedCommands('Want me to start `/plan-lite` instead?')).toEqual([])
    expect(typedCommands('Run `/plan-council` if the scope grows.')).toEqual([])
    expect(typedCommands('Whenever you like, type `/goal clear`.')).toEqual([])
  })

  test('a command Claude runs itself, or ran, passes', () => {
    expect(typedCommands("I'll run `/next-issue` once this merges.")).toEqual([])
    expect(typedCommands('I ran `/sync-config` and it pulled two files.')).toEqual([])
    expect(typedCommands('Running `/next-issue` now.')).toEqual([])
  })

  test('a path is not a command, in a code block or after run', () => {
    expect(typedCommands('```\n/Volumes/Backup/file.txt\n```')).toEqual([])
    expect(typedCommands('```\n/tmp/build.log\n```')).toEqual([])
    expect(typedCommands('Run `/usr/bin/true` to check.')).toEqual([])
    // Lower case only: a folder named after a verb is not a command (lessons review, fb7e67d).
    expect(typedCommands('Use `/Applications` for the copy.')).toEqual([])
    expect(typedCommands('Type `/Library` into the Go to Folder box.')).toEqual([])
  })

  test('a command quoted on its line passes', () => {
    expect(typedCommands('The rule says "type `/goal clear`" when the goal is done.')).toEqual([])
  })
})

describe('onCard', () => {
  const card = (steps: StepsCard['steps']): StepsCard => ({ heading: 'h', steps })
  test('an unfinished step naming the command in its value, title or actions holds it', () => {
    expect(onCard(card([{ title: 'Start planning', location: 'x', value: '/plan-council brief' }]), '/plan-council')).toBe(true)
    expect(onCard(card([{ title: 'Type /goal clear', location: 'x' }]), '/goal')).toBe(true)
    expect(onCard(card([{ title: 'Plan', location: 'x', clicks: ['Paste /plan-lite and press Return'] }]), '/plan-lite')).toBe(true)
  })
  test('a finished step, another command, or no card does not', () => {
    expect(onCard(card([{ title: 'Start', location: 'x', value: '/plan-council', finished: 'checked' }]), '/plan-council')).toBe(false)
    expect(onCard(card([{ title: 'Start', location: 'x', value: '/plan-council-x' }]), '/plan-council')).toBe(false)
    expect(onCard(null, '/plan-council')).toBe(false)
  })
})
