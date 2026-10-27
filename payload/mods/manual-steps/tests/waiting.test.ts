import { describe, expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import { saysNoneNow, waitingPhrase } from '../hooks/waiting.ts'

// #863: what in a message of Claude's says a step is waiting on Dan, judged on every message of the
// turn since #1608. Narrow on purpose: each phrase was measured on real turns before it shipped
// (docs/mods-design.md "Manual steps"), so a change here is measured again rather than widened by
// guesswork (L172, L36).

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

  // #1613: "waiting on you" read over whole turns fired as often on things that are not a step as on
  // steps. Each of these is paraphrased from a measured false alarm of the 30 days to 2026-10-24.
  test('"waiting on you" said of a decision, a question, a reply or an OK passes (#1613)', () => {
    for (const said of [
      '**Waiting on you:**\n1. **PR #12 (#40):** built and held. Your decision on #40 clashes with #41, and the PR comment sets out the choice.',
      '**Two PRs are ready but waiting on you:**\n- **PR #12:** held on purpose, because your decision on #40 clashes with #41.',
      '#1171 is still waiting on you to answer one design guard question:',
      'Still waiting on you, from my last message: reply "skip ok for 712" to let it past the gate, or tell me to add a test.',
      '**Waiting on you:**\n- **#583 and #601:** ready to merge, but they loosen what the review accepts, so they need your OK.',
      'Whether the charger reminder should also go out in the evening is the one thing waiting on you. Until you answer, the issue stays as filed.',
      '**Waiting on you at noon:**\n- **#1483:** needs your answer to the design round guard.',
      'Still waiting on you. Nothing more can move without your sign-off.',
    ])
      expect(waitingPhrase(said)).toBeNull()
  })

  test('"waiting on you" naming no step at all passes (#1613)', () => {
    for (const said of [
      'Still waiting on you for #1107 and #1077.',
      '#1483 has one commit that is only local and not pushed, waiting on you.',
      'Waiting on you.',
    ])
      expect(waitingPhrase(said)).toBeNull()
  })

  test('"waiting on you" describing a kind of thing, rather than handing one over, passes (#1613)', () => {
    for (const said of [
      '3. Send you a final status covering what merged, what is waiting on you, and anything left open.',
      "3. Send you a final status covering what merged, what's waiting on you, and anything left open.",
      'Your count also includes the replies waiting on you. Check how many are nudges.',
      'So the milestone gets to two open issues, both waiting on you, and I can run nothing further.',
      'Every open issue is now either being worked on or waiting on you (#771, #808). I will walk you through them once the agents finish.',
      'After it merges, everything left in Ungrouped will be waiting on you.',
      'Two agents are running: #863 (steps waiting on you go on the card) and #867.',
      '- **Things waiting on you go amber.** Use and Dismiss stay grey.',
      'Now the two issues waiting on you, one at a time:',
      'The status bar shows that something is waiting on you until you click Done.',
      'Next is the notification when a session starts waiting on you. Here is the wording to check:',
    ])
      expect(waitingPhrase(said)).toBeNull()
  })

  test('"waiting on you" about the steps card, which already shows the step, passes (#1613)', () => {
    for (const said of [
      'The card is the only thing still waiting on you. I will check each step when you press Done.',
      'If the last message says a step is waiting on you but none is on the steps card, the session is held. Run it again to see.',
    ])
      expect(waitingPhrase(said)).toBeNull()
  })

  test('"waiting on you" inside a quotation that started earlier on the line passes (#1613)', () => {
    for (const said of [
      'A sentence like "The deploy did not finish, so it\'s waiting on you" never fires, and the test should change.',
      'A message like “the build failed, still waiting on you” could slip past the check.',
    ])
      expect(waitingPhrase(said)).toBeNull()
  })

  // Paraphrased from every real hand off the phrase made in the same 30 days, and the two of the
  // days before that the transcripts still hold: narrowing must keep each one.
  test('"waiting on you" handing Dan a step still fires (#1613)', () => {
    for (const said of [
      'The only thing still waiting on you is the merge command in my last message, and only if you want that PR merged.',
      '**Waiting on you:**\n\n1. **A day of use (#3660).** Use the app normally, including one scout.\n2. **The redesign.** Its decisions are on the discussion.',
      '**Still waiting on you:** the first real send (#42), and real receipts for the reader tests (#73).',
      '4. **Still waiting on you from earlier:**\n   - the first real invoice send (#42);\n   - 20 receipts for the reader verdict (#74).',
      'The one thing waiting on you is running the sync command on the work MacBook.',
      '**Waiting on you:**\n* **#771:** check that the card shows once at the next merge.',
      '**Waiting on you. Each needs the pull first:**\n1. **#808:** the Safari sign out live test.',
      '**Waiting on you (these can start now):**\n- **#808:** test the Safari sign out.',
      'Still waiting on you, for another time:\n- **#876:** the settings files.\n- **#875:** short live checks.',
      '- **Waiting on you or an event:**\n  - #848: an hour of use on the work MacBook, then one command.',
      '**Waiting on you:** the two bug bash setup steps, whenever you are ready.',
      "- **#42, sending:** it's waiting on you. The steps are to reinstall the app and fill in `sending.json`.",
      'Waiting on you: run `/goal clear` to end the session.',
      'Still waiting on you from last night: try the new checkbox on the test show. Type the name and tick the box.',
      'One thing still waiting on you, from the reflection: the installed app is old. Run `mac/build-install.sh`, then relaunch.',
      '3. **Still waiting on you:** the remote main still points at the bad commit, so these three commands have to come from you.',
    ])
      expect(waitingPhrase(said)).toBe(said.match(/waiting on you/i)?.[0] ?? '')
  })

  // Lessons review of PR 866: a negation elsewhere in the sentence says nothing about the phrase.
  test('a negation in another clause, or far from the phrase, does not hide a real hand-off', () => {
    for (const said of [
      "The deploy did not finish, so it's waiting on you: run the migration from the dashboard.",
      "So this show isn't hidden, and it's still waiting on you in Reached out: send the follow up.",
      "I can't apply it from here because the console is not reachable from this Mac, which leaves it waiting on you.",
    ])
      expect(waitingPhrase(said)).toBe('waiting on you')
  })

  // #1680: #863's other four phrases, measured over whole turns of the 30 days to 2026-10-25, each
  // sentence paraphrased from what fired, never copied.
  test('"once you approve" a decision, or "once you click Done" on the card, passes (#1680)', () => {
    for (const said of [
      'The sleep work will get its own milestone once you approve the plan.',
      "Once you approve a lesson in the picker, it's written without a second question.",
      'Its heading reads "waiting" while the step is open, and drops it once you click Done.',
      "The row goes grey once you've clicked **Done** on the card.",
    ])
      expect(waitingPhrase(said)).toBeNull()
  })

  test('a later or conditional "you need to", and the phrases quoted, pass (#1680)', () => {
    for (const said of [
      "A fifth agent is building the permission test, and I'll tell you before you need to click Allow.",
      'If you need to run it again, the command is in the README.',
      'The other phrases still misfire ("once you approve" for a plan, "before you need to click Allow" about a later sign in).',
      'Sentences like "the calendar needs you to sign in" and "that is your step" were read one by one.',
    ])
      expect(waitingPhrase(said)).toBeNull()
  })

  // Every real hand off the four made in those 30 days, paraphrased: narrowing must keep each one.
  test("#863's other four handing Dan a step still fire (#1680)", () => {
    for (const [said, phrase] of [
      ["Once everything above is merged, you'll need to run `/goal clear`, since I can't clear it myself.", "you'll need to run"],
      ['Once you run the command from my last message, I will record the reply and start the merges.', 'Once you run'],
      ["I'll test the permissions with the public key once you've pasted the database change.", "once you've pasted"],
      ["Once it's installed, that check needs you to run `/login` once.", 'needs you to run'],
      ["The tracker redeploy: that's your step, already noted.", 'your step'],
      ["Once you've run `/winddown off`, I'll open the one line pull request.", "Once you've run"],
      ["My output doesn't reach your screen, so you'll need to run it yourself: paste this into the prompt.", "you'll need to run"],
      ["Nothing needs you beyond step 4, and I'll find the log line once you've run it.", "once you've run"],
      ["To clear the goal you need to run one command yourself, because I can't; it's on the card.", 'you need to run'],
      ['The test I run after your step will show which, and I will send a corrected file.', 'your step'],
      ['The calendar connection needs you to sign in before I can change it.', 'needs you to sign in'],
      // Not among the 30 days' hits: an approval that is a step, of a pull request on GitHub.
      ['Once you approve the pull request on GitHub, I will merge it.', 'Once you approve'],
    ] as const)
      expect(waitingPhrase(said)).toBe(phrase)
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

// #1811: numbered steps handed to Dan in a reply. Measured on 2026-10-27 over the 19,420 messages
// Claude wrote in this Mac's transcripts: 20 held two or more numbered lines that begin with something
// a person does at a screen, and every one of the 20 was steps for Dan. One such line alone, or
// numbered lines of Claude's own plan, is not.
describe('numbered steps in a reply (#1811)', () => {
  test('two or more numbered lines that open, click, press or paste are steps for Dan', () => {
    const said = "Here is the fix:\n\n1. Open the read workflow's run history.\n2. Open any of today's failures that took under a second.\n3. Tell me what the error says."
    expect(waitingPhrase(said)).toMatch(/^1\. Open\b/)
    expect(waitingPhrase('1. Type `/config`.\n2. Turn on **Enable Remote Control for all sessions**.')).toMatch(/^1\. Type\b/)
  })

  test('one numbered line alone, or a numbered plan of Claude\'s own work, is not', () => {
    expect(waitingPhrase('1. Open the transcript and read the last turn.\n\nThat is all I need.')).toBeNull()
    expect(waitingPhrase('My plan:\n1. Write the failing test.\n2. Add the reader.\n3. Run the suite.')).toBeNull()
  })
})

describe('saysNoneNow (#1811)', () => {
  test('the sentence the refusal asks for, and its plain variants, say none of the steps are Dan\'s now', () => {
    for (const said of [
      'None of these steps are yours to do now.',
      'Published the page. None of the steps on the page are yours to do now: they wait on the merge.',
      'none of them are yours to do now',
      'Nothing on this page is yours to do now.',
      'Nothing here is yours to do now.',
      'None of its edits are yours to do now.',
    ])
      expect(saysNoneNow([said])).toBe(true)
  })

  test('the sentence quoted, or a sentence that hands over a step, does not', () => {
    for (const said of [
      'The refusal asks me to say "None of these steps are yours to do now" when that is true.',
      'Nothing changed, but step 2 is yours to do now.',
      'Step 2 is yours to do now.',
      'The page is published.',
    ])
      expect(saysNoneNow([said])).toBe(false)
  })

  test('it is read across every message of the turn', () => {
    expect(saysNoneNow(['The page is up.', 'None of these steps are yours to do now.'])).toBe(true)
    expect(saysNoneNow([])).toBe(false)
  })
})
