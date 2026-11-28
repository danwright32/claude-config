import { describe, expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import { apartFromTyped, onCard, typedCommands } from '../hooks/typed.ts'
import { waitingPhrase } from '../hooks/waiting.ts'
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

  test('"use" after "your next step is to" hands a command over, and a system folder is no command', () => {
    expect(typedCommands('Your next step is to use `/plan-council`.')).toEqual(['/plan-council'])
    expect(typedCommands('Your next step is to use `/tmp`')).toEqual([])
    expect(typedCommands('Your next step is to use `/tmp` for the copy.')).toEqual([])
    expect(typedCommands('Your next move is to begin `/plan-council`.')).toEqual(['/plan-council'])
    // "use" leading a sentence still names a skill or a folder, and is not read.
    expect(typedCommands('Use `/plan-council` for a change this size.')).toEqual([])
  })
  test('as built today, a project folder of one word after "your next step is to use" is held as a command', () => {
    expect(typedCommands('Your next step is to use `/dist` for the copy.')).toEqual(['/dist'])
  })
})

// #3865. Each rule has its two sides in view: what it passes, and the hand over beside it that
// stays held. A test named "as built today" pins a reading that is open to question, kept because
// a sentence of the same shape has to be read that way.
describe('typedCommands, the misreads of #3865', () => {
  test('"you should", "you must" and "you have to" inside a sentence are a suggestion or a report, and pass', () => {
    expect(typedCommands('This feature is big enough that you should start `/plan-council` for it.')).toEqual([])
    expect(typedCommands('I think you should run `/plan-lite` on this before we build.')).toEqual([])
    expect(typedCommands('The README says you should run `/init` first.')).toEqual([])
    expect(typedCommands('In the old design you must type `/compact` yourself, which is the problem.')).toEqual([])
  })
  test('"you should", "you must" and "you have to" leading a sentence or a clause are held', () => {
    expect(typedCommands('You should now run `/reload-plugins`.')).toEqual(['/reload-plugins'])
    expect(typedCommands('I cannot clear it myself; you have to type `/goal clear`.')).toEqual(['/goal'])
    expect(typedCommands('The fix is merged, so you should run `/reload-plugins`.')).toEqual(['/reload-plugins'])
    expect(typedCommands('To load it, you have to run `/reload-plugins`.')).toEqual(['/reload-plugins'])
    expect(typedCommands('That means you must type `/compact` before the next turn.')).toEqual(['/compact'])
    expect(typedCommands('The fix is merged and you should now run `/reload-plugins`.')).toEqual(['/reload-plugins'])
    expect(typedCommands('The queued compact cannot run but you have to type `/compact` before the next turn.')).toEqual(['/compact'])
    expect(typedCommands("I can't type slash commands, so you'll have to run `/reload-plugins`.")).toEqual(['/reload-plugins'])
  })
  test('as built today, "you have to" after an opening clause with no comma is missed', () => {
    expect(typedCommands('Before I can go on you have to type `/compact`.')).toEqual([])
  })

  test('"is yours:" followed by a choice between commands passes', () => {
    expect(typedCommands('The call is yours: `/plan-lite` is lighter and `/plan-council` goes deeper.')).toEqual([])
    expect(typedCommands('The decision is yours: keep `/plan-lite` or move to `/plan-council`.')).toEqual([])
  })
  test('"is yours:" followed by what to do with the command, or by the command alone, is held', () => {
    expect(typedCommands('Next is yours: paste the brief below into `/plan-council`.')).toEqual(['/plan-council'])
    expect(typedCommands('The next step is yours: `/plan-council`.')).toEqual(['/plan-council'])
    expect(typedCommands('The next step is yours: `/plan-council` with the brief below.')).toEqual(['/plan-council'])
  })

  test('a label that says the session will do the work is its own, whatever it says of Dan', () => {
    expect(typedCommands('After you approve the plan I will do two things: run `/code-review` on the diff and merge it.')).toEqual([])
    expect(typedCommands('What I will do for you next:\n1. Run `/code-review` on the diff.')).toEqual([])
  })
  test('as built today, the session\'s own plan under a label that names nobody is held', () => {
    expect(typedCommands('Next: run `/code-review` on the diff, then merge.')).toEqual(['/code-review'])
    expect(typedCommands('Before merging:\n- Run `/no-ai-tells` on the description')).toEqual(['/no-ai-tells'])
    // The same shape is a hand over, which is why it is held.
    expect(typedCommands('To plan it: type `/plan-lite`.')).toEqual(['/plan-lite'])
  })
  test('a label that says the session needs something from Dan hands the command to him', () => {
    expect(typedCommands('**One thing I need from you:** type `/reload-plugins`.')).toEqual(['/reload-plugins'])
    expect(typedCommands('One thing I will need from you: type `/reload-plugins`.')).toEqual(['/reload-plugins'])
  })

  test('an imperative after ", then" in a sentence of imperatives is held', () => {
    expect(typedCommands('Close the other tab, then type `/compact`.')).toEqual(['/compact'])
    expect(typedCommands('Run `/reload-plugins`, then type `/compact`.')).toEqual(['/reload-plugins', '/compact'])
  })
  test('", then" after the session\'s own work, or after a condition, passes', () => {
    expect(typedCommands("I'll merge it, then run `/code-review`.")).toEqual([])
    expect(typedCommands('If you want a fuller plan, then run `/plan-council`.')).toEqual([])
  })
  test('"go ahead and" before the imperative is held', () => {
    expect(typedCommands('Go ahead and run `/reload-plugins`.')).toEqual(['/reload-plugins'])
  })

  test('"before anything else" is no standing rule, and "on anything other people will read" is one', () => {
    expect(typedCommands('Run `/reload-plugins` before anything else.')).toEqual(['/reload-plugins'])
    expect(typedCommands('Run `/no-ai-tells` on anything other people will read.')).toEqual([])
  })
  test('a web word naming something built for web addresses does not make the command a route', () => {
    expect(typedCommands('Type `/reload-plugins` to load the new URL guard.')).toEqual(['/reload-plugins'])
    expect(typedCommands('Paste this to plan the route check:\n\n```\n/plan-council Plan the route check\n```')).toEqual(['/plan-council'])
    expect(typedCommands('Start `/login` and watch the redirect.')).toEqual([])
    expect(typedCommands('The endpoint to probe is:\n\n```\n/health\n```')).toEqual([])
  })
  test('a code block is judged by the sentence that introduces it, not by the sentence before that one', () => {
    expect(typedCommands('You ran the first half. Paste the second:\n\n```\n/plan-council Plan the rest\n```')).toEqual(['/plan-council'])
    expect(typedCommands('The route check is fixed. Paste this to plan the rest:\n```\n/plan-council Plan the rest\n```')).toEqual(['/plan-council'])
    expect(typedCommands('You typed this a minute ago:\n\n```\n/compact\n```')).toEqual([])
    expect(typedCommands('Paste the first half. You ran this one already:\n\n```\n/compact\n```')).toEqual([])
  })
  test('a list under a line saying what the session needs is Dan\'s, and one under what it did or will do is its own', () => {
    expect(typedCommands('I need two things:\n1. Run `/reload-plugins`.\n2. Tell me what the band shows.')).toEqual(['/reload-plugins'])
    expect(typedCommands('What I did:\n1. Run `/code-review` on the diff.')).toEqual([])
    expect(typedCommands('What I will do next:\n1. Run `/code-review` on the diff.')).toEqual([])
  })

  test('a code block never closed hides nothing after it', () => {
    expect(typedCommands('Here is the diff:\n```\n- old line\nType `/reload-plugins` to load it.')).toEqual(['/reload-plugins'])
    expect(typedCommands('Paste this:\n```\n/goal clear')).toEqual(['/goal'])
  })
  test('file text inside a code block that is closed still passes', () => {
    expect(typedCommands('Here is the skill text:\n\n```\nRun `/sync-config` after each pull.\n```')).toEqual([])
    // With no word of its own that excuses it, only the block does.
    expect(typedCommands('Here is the note it wrote:\n\n```\nType `/reload-plugins` to load it.\n```')).toEqual([])
  })

  test('a command handed over for later passes', () => {
    expect(typedCommands('For the morning: run `/reload-plugins`.')).toEqual([])
    expect(typedCommands('Run `/reload-plugins` when you are back.')).toEqual([])
    expect(typedCommands("When you're back, run `/reload-plugins`.")).toEqual([])
    expect(typedCommands('Type `/reload-plugins` tomorrow.')).toEqual([])
    expect(typedCommands('For the morning, paste this:\n\n```\n/plan-council Plan the import\n```')).toEqual([])
  })
  test('a command the label or the next sentence puts off to the morning passes', () => {
    expect(typedCommands('One thing to expect when you wake: this session runs the old guard until you run `/reload-plugins`.')).toEqual([])
    expect(typedCommands('Loading the new guard needs you to type `/reload-plugins`. Nothing tonight depends on it, so it can wait until morning.')).toEqual([])
    expect(typedCommands('This session keeps the old copy until you run `/reload-plugins`. That is on the list for when you wake.')).toEqual([])
  })
  test('a next sentence that puts something else off, or says more of the command, leaves it held', () => {
    expect(typedCommands('Type `/compact` now. The merge queue can wait until morning.')).toEqual(['/compact'])
    expect(typedCommands('Type `/compact` now. It is the only way to shrink this session.')).toEqual(['/compact'])
    expect(typedCommands('Type `/compact` now.\n\nThat list is for the morning.')).toEqual(['/compact'])
  })
  test('another way offered in the next sentence makes the command an offer, and a consequence there does not', () => {
    expect(typedCommands('To shrink it now, type `/compact` yourself. Or start a fresh session from the note.')).toEqual([])
    expect(typedCommands('Type `/compact` now. Or the next request will fail.')).toEqual(['/compact'])
  })
  test('a command handed over for a moment that is Dan\'s to choose today is held', () => {
    expect(typedCommands("When you're ready, start `/plan-council` with this brief:")).toEqual(['/plan-council'])
    expect(typedCommands('The old area check is still loaded, so run `/reload-plugins` when you get a moment.')).toEqual(['/reload-plugins'])
  })
  test('as built today, a loose time is read as now and held', () => {
    expect(typedCommands('Run `/reload-plugins` at your convenience.')).toEqual(['/reload-plugins'])
    expect(typedCommands('Run `/reload-plugins` before the next build.')).toEqual(['/reload-plugins'])
  })
  test('a command offered beside another way passes, and one with its consequence after "or" is held', () => {
    expect(typedCommands('Run `/compact`, or start a fresh session.')).toEqual([])
    expect(typedCommands('Run `/reload-plugins` or the new guard stays unloaded.')).toEqual(['/reload-plugins'])
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
  // What the turn's end asks the prose check of a reply once its held commands are out
  // (hooks/register.tsx): a phrase left over is another step, and gets an ask of its own.
  const leftOver = (said: string, commands: readonly string[]) => waitingPhrase(apartFromTyped(said, commands))
  test('asking to be told the command is done, in the next sentence, is the same step: one ask', () => {
    expect(leftOver('Type `/reload-plugins`. Tell me when it is done.', ['/reload-plugins'])).toBeNull()
    expect(leftOver("Type `/reload-plugins`.\n\nTell me once it's loaded.", ['/reload-plugins'])).toBeNull()
    expect(leftOver("Run `/compact`. Tell me it's done.", ['/compact'])).toBeNull()
    expect(leftOver('Type `/reload-plugins`. Tell me when you have run it.', ['/reload-plugins'])).toBeNull()
  })
  test('another step after the command keeps its own ask, a report back on something else included', () => {
    expect(leftOver('Type `/reload-plugins`. Tell me when you have clicked **Approve** on the deploy page.', ['/reload-plugins'])).not.toBeNull()
    expect(leftOver('Run `/reload-plugins`.\nThe deploy is still waiting on you: click **Approve** on the page.', ['/reload-plugins'])).not.toBeNull()
    // Only the sentence right after it: with another between, "it" need not be the command.
    expect(leftOver('Type `/reload-plugins`. The tests pass. Tell me when it is done.', ['/reload-plugins'])).not.toBeNull()
    // Not held, nothing is taken out: the report back is the whole reply's step.
    expect(leftOver('Tell me when it is done.', ['/reload-plugins'])).not.toBeNull()
  })
  test('asking to be told when what the command starts has finished is the same step: one ask (#3865)', () => {
    expect(leftOver('Paste this:\n\n```\n/plan-council Plan the venue import\n```\n\nTell me when the panel has finished.', ['/plan-council'])).toBeNull()
    expect(leftOver('Type `/reload-plugins`. Tell me when the reload has finished.', ['/reload-plugins'])).toBeNull()
    expect(leftOver('Run `/compact`. Tell me once the command is done.', ['/compact'])).toBeNull()
  })
  test('asking to be told when something else has finished keeps its own ask (#3865)', () => {
    expect(leftOver('Paste this:\n\n```\n/plan-council Plan the venue import\n```\n\nTell me when the deploy has finished.', ['/plan-council'])).not.toBeNull()
    expect(leftOver('Type `/reload-plugins`. Tell me when the panel has finished.', ['/reload-plugins'])).not.toBeNull()
  })
  test('a command in a code block never closed takes out its own paragraph, not the rest of the reply (#3865)', () => {
    const said = 'Paste this:\n\n```\n/goal clear\n\nThe deploy is still waiting on you: click **Approve** on the page.'
    expect(typedCommands(said)).toEqual(['/goal'])
    expect(leftOver(said, ['/goal'])).not.toBeNull()
    expect(apartFromTyped(said, ['/goal'])).not.toMatch(/goal clear/)
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
