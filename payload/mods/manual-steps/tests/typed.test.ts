import { describe, expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import { apartFromTyped, onCard, typedCommands } from '../hooks/typed.ts'
import { waitingPhrase } from '../hooks/waiting.ts'
import type { StepsCard } from '../types/index.d.ts'
import { HELD, PASSED, REPLIES, type Reply } from './typed-replies.ts'

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
  test('"you have to" and "you must" are held however the sentence opens, with or without a comma', () => {
    expect(typedCommands('Before I can go on you have to type `/compact`.')).toEqual(['/compact'])
    expect(typedCommands('After the merge you must run `/reload-plugins`.')).toEqual(['/reload-plugins'])
    expect(typedCommands("For this to load you'll have to run `/reload-plugins`.")).toEqual(['/reload-plugins'])
  })
  test('"that", "why" and "said" before "you must" are a report only in the wordings of one', () => {
    expect(typedCommands('The upshot is that you must run `/reload-plugins`.')).toEqual(['/reload-plugins'])
    expect(typedCommands('I cannot type slash commands, which is why you must run `/reload-plugins`.')).toEqual(['/reload-plugins'])
    expect(typedCommands('As I said you must run `/reload-plugins`.')).toEqual(['/reload-plugins'])
    expect(typedCommands('The guide explains why you should run `/sync-config` on both Macs.')).toEqual([])
    expect(typedCommands('The second review found that you must type `/reload-plugins` twice on that build.')).toEqual([])
    expect(typedCommands('I told the builder that you should run `/reload-plugins` only after the merge.')).toEqual([])
  })
  test('a suggestion with "should" that names a moment to type it is held', () => {
    expect(typedCommands('I think you should run `/reload-plugins` now.')).toEqual(['/reload-plugins'])
    expect(typedCommands('This session is long enough that you should type `/compact` right away.')).toEqual(['/compact'])
    // "Think" and "enough that" excuse "should", never "must" or "have to".
    expect(typedCommands('I think you have to run `/reload-plugins`.')).toEqual(['/reload-plugins'])
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
  test('"is yours:" followed by one command is held whatever is said of it, and so are two commands that are two steps', () => {
    expect(typedCommands('The last step is yours: `/reload-plugins` will load the new guard.')).toEqual(['/reload-plugins'])
    expect(typedCommands('The choice is yours: `/compact`.')).toEqual(['/compact'])
    expect(typedCommands('The next two steps are yours: `/compact`, then `/reload-plugins`.')).toEqual(['/compact'])
    // "Or" between two commands is a choice under any label.
    expect(typedCommands('Next is yours: `/plan-lite` for a quick plan or `/plan-council` for the panel.')).toEqual([])
  })

  test('a label naming what follows as the session\'s own work is its own, whatever it said of Dan before that', () => {
    expect(typedCommands('After you approve the plan I will do two things: run `/code-review` on the diff and merge it.')).toEqual([])
    expect(typedCommands('What I will do for you next:\n1. Run `/code-review` on the diff.')).toEqual([])
  })
  test('a label that says "I will" and then what Dan does hands the command to him', () => {
    expect(typedCommands('I will keep going after you do one thing: type `/reload-plugins`.')).toEqual(['/reload-plugins'])
    expect(typedCommands('What I will do after you have done your part: type `/reload-plugins`.')).toEqual(['/reload-plugins'])
    // "I will" of something other than the list that follows names no work of the session's there.
    expect(typedCommands("While I'll watch the build for you: run `/reload-plugins`.")).toEqual(['/reload-plugins'])
    expect(typedCommands('I ask two things:\n1. Run `/reload-plugins`.\n2. Tell me what the band shows.')).toEqual(['/reload-plugins'])
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
    expect(typedCommands('Close the other tab, and then type `/compact`.')).toEqual(['/compact'])
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
    // An offer in the sentence before says nothing of the block either.
    expect(typedCommands('You could do the rest by hand. Paste this:\n\n```\n/goal clear\n```')).toEqual(['/goal'])
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
    expect(typedCommands('Run `/sync-config` on the work MacBook tomorrow.')).toEqual([])
    expect(typedCommands('Type `/reload-plugins` in the morning and the new band will show.')).toEqual([])
    expect(typedCommands('Paste this tomorrow:\n\n```\n/plan-council Plan the import\n```')).toEqual([])
  })
  test('a word meaning at once beside a time for later is held', () => {
    expect(typedCommands('For the morning: run `/reload-plugins` now.')).toEqual(['/reload-plugins'])
    expect(typedCommands('Type `/compact` tonight when you are back.')).toEqual(['/compact'])
    expect(typedCommands("When you're back, run `/reload-plugins` first.")).toEqual(['/reload-plugins'])
    expect(typedCommands('For the morning, paste this now:\n\n```\n/plan-council Plan the import\n```')).toEqual(['/plan-council'])
    // Each of two commands is judged by its own words: the one for tomorrow passes.
    expect(typedCommands('Run `/sync-config` tomorrow and `/compact` now.')).toEqual([])
    expect(typedCommands('Run `/sync-config` tomorrow, then type `/compact` now.')).toEqual(['/compact'])
  })
  test('a time that does not end the words right after the command is said of something else, and held', () => {
    expect(typedCommands('Run `/reload-plugins` in the morning-report tab.')).toEqual(['/reload-plugins'])
    expect(typedCommands('Run `/compact` in the session that ends tomorrow.')).toEqual(['/compact'])
    expect(typedCommands('Run `/reload-plugins` or lose the fix by tomorrow.')).toEqual(['/reload-plugins'])
    expect(typedCommands('Run `/reload-plugins` so the guard is live in the morning.')).toEqual(['/reload-plugins'])
    expect(typedCommands('Run `/compact` since the long run starts tomorrow.')).toEqual(['/compact'])
    expect(typedCommands('Run `/reload-plugins` before you go, then when you get back the band will be there.')).toEqual(['/reload-plugins'])
    expect(typedCommands('Type this in the morning session tab:\n\n```\n/reload-plugins\n```')).toEqual(['/reload-plugins'])
  })
  test('a label that says more than the time is no time for later, and held', () => {
    expect(typedCommands('Tomorrow is too late: run `/reload-plugins`.')).toEqual(['/reload-plugins'])
    expect(typedCommands('Before the morning sync: run `/reload-plugins`.')).toEqual(['/reload-plugins'])
    expect(typedCommands('Your next step for the morning sync is `/sync-config`.')).toEqual(['/sync-config'])
  })
  test('a time said in the reason for the command, or in telling what happened, is not when to type it', () => {
    expect(typedCommands('Run `/reload-plugins` to load the guard I merged in the morning.')).toEqual(['/reload-plugins'])
    expect(typedCommands('The guard I merged in the morning needs you to type `/reload-plugins`.')).toEqual(['/reload-plugins'])
    expect(typedCommands('Run `/reload-plugins` so the next session loads the guard.')).toEqual(['/reload-plugins'])
    expect(typedCommands("Type `/compact` before tomorrow's run.")).toEqual(['/compact'])
    // A colon inside a time of day ends no label.
    expect(typedCommands('The compact I queued in the morning at 3:52 never ran, so type `/compact` now.')).toEqual(['/compact'])
  })
  test('a command the label or the next sentence puts off to the morning passes', () => {
    expect(typedCommands('A note for the morning: the old guard stays loaded until you run `/reload-plugins`.')).toEqual([])
    expect(typedCommands('Run `/reload-plugins` when you wake.')).toEqual([])
    expect(typedCommands('Loading the new guard needs you to type `/reload-plugins`. Nothing tonight depends on it, and it can wait for the morning.')).toEqual([])
    expect(typedCommands('The old copy stays loaded until you run `/reload-plugins`. I have put that down for the morning.')).toEqual([])
  })
  test('a next sentence that puts something else off, or says more of the command, leaves it held', () => {
    expect(typedCommands('Type `/compact` now. The merge queue can wait for the morning.')).toEqual(['/compact'])
    expect(typedCommands('Type `/compact` now. It is the only way to shrink this session.')).toEqual(['/compact'])
    expect(typedCommands('Type `/compact` now.\n\nThat list is for the morning.')).toEqual(['/compact'])
    expect(typedCommands('Run `/reload-plugins`. This cannot wait for the morning.')).toEqual(['/reload-plugins'])
    expect(typedCommands('Run `/reload-plugins`. It can wait no longer.')).toEqual(['/reload-plugins'])
    expect(typedCommands('Run `/reload-plugins`. This branch can wait.')).toEqual(['/reload-plugins'])
    expect(typedCommands('Run `/reload-plugins`. Do it before the review, and that can wait.')).toEqual(['/reload-plugins'])
    // After a clause with a subject of its own, "it" is that subject.
    expect(typedCommands('Run `/reload-plugins`. The merge queue is stuck, and it can wait for the morning.')).toEqual(['/reload-plugins'])
    expect(typedCommands('Run `/reload-plugins`. No test needs it tonight, so it can wait until tomorrow.')).toEqual([])
    // The command's own sentence says now, which the next sentence cannot take back.
    expect(typedCommands('Type `/compact` now. It can wait for the morning.')).toEqual(['/compact'])
  })
  test('another way offered in the next sentence makes the command an offer, and a consequence there does not', () => {
    expect(typedCommands('To free some room, type `/compact`. Or open a new session and carry on from the note.')).toEqual([])
    expect(typedCommands('Type `/compact` now. Or the next request will fail.')).toEqual(['/compact'])
    expect(typedCommands('Type `/compact`. Or leave it and this session ends at the limit.')).toEqual(['/compact'])
    expect(typedCommands('Run `/reload-plugins`. Or start with the pull, both are needed.')).toEqual(['/reload-plugins'])
  })
  test('a command handed over for a moment that is Dan\'s to choose today is held', () => {
    expect(typedCommands("When you're ready, start `/plan-council` with this brief:")).toEqual(['/plan-council'])
    expect(typedCommands('The old area check is still loaded, so run `/reload-plugins` when you get a moment.')).toEqual(['/reload-plugins'])
  })
  test('as built today, a command put off in words the rules do not know is held', () => {
    // The next sentence puts it off with a verb other than "can wait" and "have put down".
    expect(typedCommands('The old copy stays loaded until you run `/reload-plugins`. That is noted for the morning.')).toEqual(['/reload-plugins'])
    // The label names the time among other words.
    expect(typedCommands('Something to look for in the morning: the old copy stays loaded until you run `/reload-plugins`.')).toEqual(['/reload-plugins'])
  })
  test('as built today, a loose time is read as now and held', () => {
    expect(typedCommands('Run `/reload-plugins` at your convenience.')).toEqual(['/reload-plugins'])
    expect(typedCommands('Run `/reload-plugins` before the next build.')).toEqual(['/reload-plugins'])
  })
  test('a command offered beside another way passes, and one with its consequence after "or" is held', () => {
    expect(typedCommands('Run `/compact`, or start a fresh session.')).toEqual([])
    expect(typedCommands('Run `/reload-plugins` or the new guard stays unloaded.')).toEqual(['/reload-plugins'])
  })
  test('"or" with anything but a new session is no other way, and neither is a new session the command is typed in', () => {
    expect(typedCommands('Run `/reload-plugins`, or keep seeing the old error on every edit.')).toEqual(['/reload-plugins'])
    expect(typedCommands('Run `/reload-plugins`, or leave me stuck here.')).toEqual(['/reload-plugins'])
    expect(typedCommands('Run `/reload-plugins` here, or open a new tab and run it there.')).toEqual(['/reload-plugins'])
    // Before the command, "or" is said of something else.
    expect(typedCommands('Stay here or open a new session, as you like: run `/reload-plugins` in it.')).toEqual(['/reload-plugins'])
    // The words that introduce a block cannot name another way: the block is what they hand over.
    expect(typedCommands('Paste this, or open a new session:\n\n```\n/reload-plugins\n```')).toEqual(['/reload-plugins'])
  })
})

// A hook that never yields is stopped after about six seconds and the turn ends unheld, so the time
// the check takes is part of what it holds. Each run is judged against plain words of the same
// length timed in the same run, never against a fixed time, which would measure the Mac's load.
describe('typedCommands, the cost of a long reply', () => {
  const fastest = (text: string): number => {
    let best = Number.POSITIVE_INFINITY
    for (let i = 0; i < 3; i++) {
      const t0 = performance.now()
      typedCommands(text)
      best = Math.min(best, performance.now() - t0)
    }
    return best
  }
  const of = (unit: string): string => unit.repeat(Math.ceil(40_000 / unit.length))
  for (const unit of ['and ', 'so ', 'but ', 'then ', ', so ', ', then ', 'and you must run ', 'you should ', 'or ', 'it can wait ', 'tomorrow ', 'is yours: ']) {
    test(`40,000 characters of "${unit}" cost no more than twenty times plain words of that length`, () => {
      const plain = fastest(of('word '))
      expect(fastest(of(unit)) / plain).toBeLessThan(20)
    })
  }
})

// The review of pull request 3889. A miss (a command to type now left in prose) is the fault the
// check exists to stop, and a false hold costs one exchange. So a rule that lets a reply pass has to
// recognise the harmless shape, and every reply of tests/typed-replies.ts that hands a command over
// to type now and was held before #3865 has a test of its own here.
const held = ([, kind, , want, text]: Reply): boolean => {
  const got = typedCommands(text)
  return kind === 'H' ? want.every(c => got.includes(c)) : got.length > 0
}
const ids = (replies: readonly Reply[]): string[] => replies.map(r => r[0])

describe('typedCommands, the table of invented replies', () => {
  test('the table has 155 commands to type now, 143 of them held before #3865, 72 replies that hand nothing over and 11 for later', () => {
    expect(REPLIES.filter(r => r[1] === 'H').length).toBe(155)
    expect(REPLIES.filter(r => r[1] === 'H' && r[2] === HELD).length).toBe(143)
    expect(REPLIES.filter(r => r[1] === 'N').length).toBe(72)
    expect(REPLIES.filter(r => r[1] === 'L').length).toBe(11)
    expect(new Set(ids(REPLIES)).size).toBe(REPLIES.length)
  })
  for (const [id, , , want, text] of REPLIES.filter(r => r[1] === 'H' && r[2] === HELD)) {
    test(`${id}, a command to type now that was held before #3865, is still held`, () => {
      const got = typedCommands(text)
      expect(want.filter(c => !got.includes(c))).toEqual([])
    })
  }
  test('of the 12 commands to type now that were missed before #3865, nine are held and three are still missed, as built today', () => {
    const missedBefore = REPLIES.filter(r => r[1] === 'H' && r[2] === PASSED)
    expect(ids(missedBefore.filter(held))).toEqual(['H094', 'H108', 'H111', 'H123', 'H124', 'H125', 'H126', 'H127', 'H148'])
    // "anything new" read as a standing rule, a block fenced with tildes, and "later is too late".
    expect(ids(missedBefore.filter(r => !held(r)))).toEqual(['H023', 'H112', 'H149'])
  })
  test('a command handed over for later or beside a new session passes, and a loose time is held', () => {
    const later = REPLIES.filter(r => r[1] === 'L')
    expect(ids(later.filter(held))).toEqual(['L10'])
  })
  test('as built today, 11 of the 72 replies that hand nothing over are held, each at the cost of one exchange', () => {
    const nothing = REPLIES.filter(r => r[1] === 'N')
    // Held before #3865 as well: a plan under a label naming nobody, a rule or a help text quoted
    // with no quote marks, and a hand over the session says it made.
    expect(ids(nothing.filter(r => r[2] === HELD && held(r)))).toEqual(['N26', 'N29', 'N39', 'N44', 'N49', 'N52', 'N70'])
    // Held since #3865: ", then" after imperatives that are the session's own plan, and a project
    // folder of one word after "your next step is to use".
    expect(ids(nothing.filter(r => r[2] === PASSED && held(r)))).toEqual(['N11', 'N25', 'N67', 'N68'])
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
    expect(leftOver('Run `/compact`. Tell me once the command is done.', ['/compact'])).toBeNull()
  })
  test('asking to be told when something else has finished keeps its own ask (#3865)', () => {
    // A word of the command's own name is no sign the report is about it: "the code", "the next".
    expect(leftOver('Run `/code-review` on your branch. Tell me when the code is merged.', ['/code-review'])).not.toBeNull()
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
