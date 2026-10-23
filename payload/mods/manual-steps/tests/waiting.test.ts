import { describe, expect, test } from 'claude-code/testing'
import { waitingPhrase } from '../hooks/waiting.ts'

// #863: what in Claude's own final message says a step is waiting on Dan. Narrow on purpose: it was
// measured on real turn final messages before it shipped (docs/mods-design.md "Manual steps"), so a
// change here is measured again rather than widened by guesswork (L172, L36).

describe('waitingPhrase', () => {
  test('the 2026-10-06 wording that left Dan with a command he never saw', () => {
    const said = "The one thing still waiting on you is the migration command from my earlier message. #3415 merges after that, and it's the last piece of the goal."
    expect(waitingPhrase(said)).toBe('waiting on you')
  })

  // #1608: the 2026-10-23 Downbeat turn, whose step was in its second to last message and whose
  // last message, the reflection, pointed back at it. Neither used any phrase of the #863 list.
  test('the 2026-10-23 Downbeat wording, the step and the reflection after it, each fire (#1608)', () => {
    const step = "One thing is still yours to do. In Settings, Venues, Carnegie Hall, click the × next to jbentley, then type ... and click Add. Tell me when it's done"
    const reflection = 'The only thing still open is the Settings swap I described above'
    expect(waitingPhrase(step)).toBe('yours to do')
    expect(waitingPhrase(reflection)).toBe('still open is the Settings swap I described above')
  })

  // #1608's phrases, each measured on the turns of the 30 days to 2026-10-23 (docs/mods-design.md
  // "Manual steps"). The sentences are paraphrased from what fired, never copied.
  test('the hand off shapes #1608 added fire, each on the words that make it a step', () => {
    for (const [said, phrase] of [
      ['Reinstalling the app is yours to run: `bash scripts/install.sh`.', 'yours to run'],
      ['The one step left is yours: press Update in the app.', 'step left is yours'],
      ['3. **One check is still yours:** open the app and import the file again.', 'check is still yours'],
      ['3. Tell me when that is saved and I will rerun the scan.', 'Tell me when'],
      ["Tell me once you've signed in and I'll read the thread.", 'Tell me once'],
      ['1. Click **Deploy**, then **Manage deployments**.', 'Click'],
      ['3. Click the × next to the old address.', 'Click'],
      ['2. Choose "claude.ai Google Calendar" from the list.', 'Choose'],
      ['Type `/goal clear` to release the session.', 'Type'],
      ['Paste it into the prompt with the `!` and press Return.', 'Paste'],
      ['In Settings, Venues, the hall, remove the old address.', 'In Settings'],
      ['2. Go to the **Venues** tab and select **the hall**.', 'Go to the **Venues** tab and select'],
    ] as const)
      expect(waitingPhrase(said)).toBe(phrase)
  })

  // What a wider phrase fired on in the same 30 days that was not a step for Dan (#1608).
  test('the shapes #1608 measured and left out, and the near misses of those it kept, pass', () => {
    for (const said of [
      'The watcher will tell me when each pull request merges.',
      "Tell me when you'd like the next wave.",
      'The yes or no call is yours to make.',
      'The decision is yours whenever the next screen is settled.',
      'Its heading reads "waiting" while the open step is yours.',
      'Opening the round in Chrome now. Press 1, 2 or 3 to swap.',
      'Type checking, then commit:',
      '- **Type check fix (#953):** it was split into two parts.',
      'The only window still open is this one.',
      'After a replacement you would press Connect again in Settings, Integrations.',
      'The click handler in `pane.tsx` now types the value itself.',
    ])
      expect(waitingPhrase(said)).toBeNull()
  })

  test("#1608's phrases negated or quoted pass", () => {
    for (const said of [
      'Nothing here is yours to do.',
      'The card used to say "yours to do" beside each step.',
      'The draft step read "Tell me when it is done" before I changed it.',
    ])
      expect(waitingPhrase(said)).toBeNull()
  })

  test('the other ways a step is handed over in prose, found in real transcripts', () => {
    for (const [said, phrase] of [
      ['All 12 merges are still blocked on the one fast reply check. Once you run the command from my last message, I\'ll record that reply.', 'Once you run'],
      ['Once everything above is merged, you\'ll need to run `/goal clear`, because I can\'t clear it myself.', "you'll need to run"],
      ['The one open point is #639, which is waiting on you. In window 1, choose "Yes, I trust this folder".', 'waiting on you'],
      ['**Waiting on you:** #771, check that the card shows once at the next merge.', 'Waiting on you'],
      ['The deploy needs you to paste the key into the dashboard.', 'needs you to paste'],
      ['That is your step: approve the app in the Google console.', 'your step'],
      // A curly apostrophe is how a reply often arrives.
      ['Once you’ve run the migration, I’ll merge.', 'Once you’ve run'],
    ] as const)
      expect(waitingPhrase(said)).toBe(phrase)
  })

  test('ordinary prose passes', () => {
    for (const said of [
      'Merged #812 and the deploy is live. Nothing else is open.',
      'The tests pass and the PR is up; I am watching CI.',
      'Waiting on your other window to merge #767.',
      "I've stopped and I'm waiting for you. You turned down the picker without a note.",
      'Once the run finishes I will merge it.',
    ])
      expect(waitingPhrase(said)).toBeNull()
  })

  test('a sentence saying nothing is waiting on Dan passes', () => {
    for (const said of [
      'The three issues are filed and nothing else is waiting on you.',
      'Every open design question is now settled, and nothing is waiting on you for design.',
      'This is no longer waiting on you.',
    ])
      expect(waitingPhrase(said)).toBeNull()
  })

  // Lessons review of PR 866: a negation elsewhere in the sentence says nothing about the phrase.
  test('a negation in another clause, or far from the phrase, does not hide a real hand-off', () => {
    for (const said of [
      "The deploy did not finish, so it's waiting on you: run the migration from the dashboard.",
      "So this show isn't hidden, and it's still waiting on you in Reached out.",
      "I can't apply it from here because the console is not reachable from this Mac, which leaves it waiting on you.",
    ])
      expect(waitingPhrase(said)).toBe('waiting on you')
  })

  test('the phrase quoted, as the name of a notification or a state, passes', () => {
    for (const said of [
      'Its permission request is notified as "is waiting on you", and nothing else notifies it.',
      'the session shows "waiting on you" indefinitely, and the idle notification is suppressed.',
      "you'd get no “waiting on you” mark and no notification.",
    ])
      expect(waitingPhrase(said)).toBeNull()
  })
})
