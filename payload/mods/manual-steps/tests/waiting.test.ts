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
