import { describe, expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import { apartFromTyped, onCard, typedCommands } from '../hooks/typed.ts'
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

// The independent review of pull request 3677 ran these against the recogniser as first built. The
// two lists are held together: a fix for one must not bring the other back.

// Hand overs that passed unheld, each a step for Dan. With a card of other steps pinned, each is the
// forgotten step of #3652.
const MISSES: readonly [string, string, string][] = [
  ['H2', "When you're ready, start `/plan-council` with this brief:", '/plan-council'],
  ['M1', 'I merged the fix, so run `/reload-plugins` to load it.', '/reload-plugins'],
  ['M2', 'The old copy will stay loaded until you run `/reload-plugins`.', '/reload-plugins'],
  ['M3', 'Type `/reload-plugins`, then tell me if the card shows the new text.', '/reload-plugins'],
  ['M4', '**One thing I need from you:** type `/reload-plugins`.', '/reload-plugins'],
  ['M5', 'Type **`/compact`** now.', '/compact'],
  ['M6', 'Just type `/reload-plugins`.', '/reload-plugins'],
  ['M7', 'After those two, start `/plan-council` with the brief below.', '/plan-council'],
  ['M8', 'Open a new session and run `/plan-council` there.', '/plan-council'],
  ['M9', 'You should now run `/reload-plugins`.', '/reload-plugins'],
  ['M10', 'Your next move: `/plan-council`.', '/plan-council'],
  ['M11', 'I cannot clear it myself; you have to type `/goal clear`.', '/goal'],
  ['M12', 'Start `/plan-council` with this brief (it might take ten minutes).', '/plan-council'],
  ['M13', 'Next is yours: paste the brief below into `/plan-council`.', '/plan-council'],
  ['M14', 'The next move is yours: start planning with `/plan-council`, using the brief below.', '/plan-council'],
  ['M15', 'Type /mcp__github__review to start it.', '/mcp__github__review'],
  ['M16', 'Your next move after those is to begin `/plan-council`.', '/plan-council'],
]

// Replies that were held and hand Dan nothing: the global rule file's own lines quoted, file text and
// a block quote shown, the session's own plan, an example, a command already typed, and a one word
// route or path.
const FALSE_ALARMS: readonly [string, string][] = [
  ['F1', '- **Run `/no-ai-tells` on anything other people will read before it is posted or sent:** PR and issue comments.'],
  ['F2', 'To run SQL or migrations, use the `/db-apply` skill instead of handing SQL to the user.'],
  ['F3', 'Use `/tmp` for the copy.'],
  ['F4', 'The endpoint to probe is:\n\n```\n/health\n```'],
  ['F5', 'You typed this a minute ago:\n\n```\n/compact\n```'],
  ['F6', '- Type `/reload-plugins` and press Return. (an example the check holds)'],
  ['F7', '> The mod is stale. Run `/reload-plugins`.'],
  ['F8', 'Enter `/admin` after the domain to reach the dashboard.'],
  ['F9', 'Plan:\n1. Run `/code-review` on the diff.\n2. Fix what it finds.'],
  ['F11', 'Here is the skill text:\n\n```\nRun `/sync-config` after each pull.\n```'],
  ['F13', 'Start `/login` and watch the redirect.'],
]

describe('typedCommands, the review of pull request 3677', () => {
  for (const [id, said, command] of MISSES) {
    test(`${id} is a hand over and is held: ${said}`, () => {
      expect(typedCommands(said)).toEqual([command])
    })
  }
  for (const [id, said] of FALSE_ALARMS) {
    test(`${id} hands Dan nothing and passes: ${said.replace(/\n+/g, ' / ')}`, () => {
      expect(typedCommands(said)).toEqual([])
    })
  }

  test('a rule that lets a false alarm pass does not let the hand over beside it pass', () => {
    // A standing rule passes on its general word, never on "every" or "any" alone.
    expect(typedCommands('Run `/reload-plugins` in every open session.')).toEqual(['/reload-plugins'])
    // A route passes on what its sentence says of it, never on its name: `/login` is a command too.
    expect(typedCommands('Type `/login` to sign in again.')).toEqual(['/login'])
    expect(typedCommands('Start `/login` now.')).toEqual(['/login'])
    // A list is the session's own plan when the line that introduces it says so, never by being a list.
    expect(typedCommands('Two steps for you:\n1. Run `/reload-plugins`.\n2. Tell me what the card shows.')).toEqual(['/reload-plugins'])
    expect(typedCommands('What I will do next:\n1. Run `/code-review` on the diff.')).toEqual([])
    // A block quote and file text shown in a code block are passed over; the words around them are not.
    expect(typedCommands('> The mod is stale.\n\nRun `/reload-plugins`.')).toEqual(['/reload-plugins'])
    expect(typedCommands('The skill text:\n\n```\nRun `/sync-config` after each pull.\n```\n\nType `/reload-plugins` to load it.')).toEqual(['/reload-plugins'])
    // A skill named is the session's to run; the same command handed over is Dan's.
    expect(typedCommands('Run the `/db-apply` skill for the migration.')).toEqual([])
    expect(typedCommands('Run `/sync-config` on the work MacBook.')).toEqual(['/sync-config'])
    // What follows "then" is another thing, so its "if" does not make the command an offer; an "if"
    // on the command itself still does.
    expect(typedCommands('Run `/plan-council` if the scope grows, then tell me.')).toEqual([])
    // Said of a later, conditional need, it is still no step now.
    expect(typedCommands("I'll tell you when you need to run `/reload-plugins`.")).toEqual([])
    expect(typedCommands("I'll remember to run `/sync-config` after the merge.")).toEqual([])
  })
})

describe('apartFromTyped', () => {
  test('takes out the sentence, or the code block and the line that introduces it, that hands the command over', () => {
    expect(apartFromTyped('The tests pass. Type `/plan-council` with the brief below. Then press Return.', ['/plan-council'])).not.toMatch(/plan-council/)
    expect(apartFromTyped('The tests pass. Type `/plan-council` with the brief below. Then press Return.', ['/plan-council'])).toMatch(/The tests pass\..*Then press Return\./s)
    expect(apartFromTyped('Paste this:\n\n```\n/goal clear\n```\n\nThe deploy is live.', ['/goal']).trim()).toBe('The deploy is live.')
  })
  test('leaves a command it was not asked about, and text that hands none over, as written', () => {
    const said = 'Type `/compact` now. Then run `/reload-plugins`.'
    expect(apartFromTyped(said, ['/compact'])).toMatch(/reload-plugins/)
    expect(apartFromTyped('Merged #12 and the deploy is live.', ['/compact'])).toBe('Merged #12 and the deploy is live.')
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
