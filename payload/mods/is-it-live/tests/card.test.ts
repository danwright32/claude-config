import { expect, test } from 'claude-code/testing'
import { buttonId, cardOf, cardText, liveList, messageRow, reasonToRefuse, stateOf, titleOf } from '../hooks/card.ts'

// Is it live (claude-config#617): the card's state, words and the message row, settled with Dan on
// 2026-10-04 (docs/mods-design.md, Is it live).
const base = {
  repo: 'danwright32/slate',
  pr: 412,
  deploy: 'live' as const,
  checked: 'Loaded /bookings and saw the new filter.',
  changed: 'The bookings list now filters by venue. Old bookings keep their venue.',
  see: { link: 'https://slate.example.com/bookings', clicks: ['Open Bookings', 'Pick a venue in the filter'] },
}

test('the state comes from the deploy as Claude checked it, and live needs the check that proved it', () => {
  expect(stateOf('live')).toBe('live')
  expect(stateOf('deploying')).toBe('deploying')
  expect(stateOf('failed')).toBe('unconfirmed')
  expect(stateOf('unreachable')).toBe('unconfirmed')
  expect(stateOf('none')).toBe('no-deploy')
  expect(reasonToRefuse({ ...base, checked: '' })).toContain('how it was checked')
  expect(reasonToRefuse(base)).toBeUndefined()
})

test('the state leads the title', () => {
  expect(titleOf('live', 'Filter bookings by venue')).toBe('Live: Filter bookings by venue')
  expect(titleOf('deploying', 'x')).toBe('Merged, deploying: x')
  expect(titleOf('unconfirmed', 'x')).toBe('Could not confirm live: x')
  expect(titleOf('no-deploy', 'x')).toBe('Merged, no deploy step recorded: x')
})

test('what changed is two or three sentences, and a call missing a field is refused by name', () => {
  expect(reasonToRefuse({ ...base, changed: 'One sentence.' })).toContain('2 to 3 sentences')
  expect(reasonToRefuse({ ...base, changed: 'A. B. C. D.' })).toContain('2 to 3 sentences')
  expect(reasonToRefuse({ ...base, repo: 'slate' })).toContain('owner/name')
  expect(reasonToRefuse({ ...base, pr: 0 })).toContain('pull request number')
  expect(reasonToRefuse({ ...base, deploy: 'maybe' as never })).toContain('deploy')
  expect(reasonToRefuse({ ...base, see: { link: '', clicks: [] } })).toContain('link')
})

// The dashes are built from their code points so this file holds none for the style checks to find.
const EM = String.fromCharCode(0x2014)
const SPACED_HYPHEN = ` ${String.fromCharCode(0x2d)} `

test('a message needs someone other than Dan who asked, and is written without dashes', () => {
  const kris = { name: 'Kris', via: 'named' as const }
  expect(reasonToRefuse({ ...base, requester: kris })).toContain('message for Kris')
  expect(reasonToRefuse({ ...base, message: 'Fixed!' })).toContain('who asked')
  expect(reasonToRefuse({ ...base, requester: kris, message: `It is live ${EM} have a look.` })).toContain('dash')
  expect(reasonToRefuse({ ...base, requester: kris, message: `It is live${SPACED_HYPHEN}have a look.` })).toContain('dash')
  expect(reasonToRefuse({ ...base, requester: kris, message: 'It is live, have a look at the re-run.' })).toBeUndefined()
  expect(reasonToRefuse({ ...base, requester: { name: 'Dan', via: 'named' as const }, message: 'Done.' })).toContain('Dan')
  expect(reasonToRefuse({ ...base, requester: { name: 'Kris', via: 'issue' as const }, message: 'Done.' })).toContain('issue number')
  expect(reasonToRefuse({ ...base, requester: { name: 'Kris', via: 'email' as never }, message: 'Done.' })).toContain('via')
})

test('the card as text: title, what changed, how to see it, and why live could not be confirmed', () => {
  expect(cardText({ ...base, state: 'live', title: 'Filter bookings by venue', url: 'https://github.com/danwright32/slate/pull/412' })).toBe(
    [
      'Live: Filter bookings by venue',
      'The bookings list now filters by venue. Old bookings keep their venue.',
      'See it: https://slate.example.com/bookings',
      '1. Open Bookings',
      '2. Pick a venue in the filter',
    ].join('\n'),
  )
  const failed = cardText({ ...base, deploy: 'failed', checked: 'The deploy job failed at the build step.', state: 'unconfirmed', title: 'x', url: 'u' })
  expect(failed.split('\n')[1]).toBe('The deploy job failed at the build step.')
})

test('the boxed card: the state word leads the title in its colour, then what changed and how to see it', () => {
  const live = cardOf({ ...base, state: 'live', title: 'Filter bookings by venue', url: 'u' })
  expect(live.title).toEqual([{ text: 'Live:', color: 'success', bold: true }, { text: ' Filter bookings by venue' }])
  expect(live.lines).toEqual([
    [{ text: 'The bookings list now filters by venue. Old bookings keep their venue.' }],
    [{ text: 'See it: ' }, { text: 'https://slate.example.com/bookings' }],
    [{ text: '1. Open Bookings' }],
    [{ text: '2. Pick a venue in the filter' }],
  ])
  // Grey for a deploy still running, amber for live that could not be confirmed (design round).
  expect(cardOf({ ...base, deploy: 'deploying', state: 'deploying', title: 'x', url: 'u' }).title[0]).toEqual({ text: 'Merged, deploying:', color: 'gray', bold: true })
  const failed = cardOf({ ...base, deploy: 'failed', checked: 'The deploy job failed at the build step.', state: 'unconfirmed', title: 'x', url: 'u' })
  expect(failed.title[0]).toEqual({ text: 'Could not confirm live:', color: 'warning', bold: true })
  expect(failed.lines[0]).toEqual([{ text: 'The deploy job failed at the build step.' }])
  expect(cardOf({ ...base, deploy: 'none', state: 'no-deploy', title: 'x', url: 'u' }).title[0].text).toBe('Merged, no deploy step recorded:')
})

test('the text the model reads says what the boxed card says, line for line', () => {
  const c = { ...base, deploy: 'failed' as const, checked: 'Timed out.', state: 'unconfirmed' as const, title: 'Filter bookings by venue', url: 'u' }
  const boxed = cardOf(c)
  expect(cardText(c)).toBe([boxed.title, ...boxed.lines].map(l => l.map(r => r.text).join('')).join('\n'))
})

test('the message row: a violet heading naming who asked, the message, then Copy and Mark sent', () => {
  const row = messageRow({ repo: 'danwright32/slate', pr: 412, requester: { name: 'Kris', via: 'named' }, message: 'The venue filter is live now.' })
  expect(row.slot).toBe('message')
  expect(row.mod).toBe('is-it-live')
  expect(row.id).toBe(buttonId('danwright32/slate', 412))
  const [head, body, buttons] = row.lines as { text?: string; color?: string; button?: string; label?: string }[][]
  expect(head).toEqual([{ text: 'Message for Kris', color: 'magenta', bold: true }])
  expect(body?.[0]?.text).toBe('The venue filter is live now.')
  expect(buttons?.map(b => `${b.button}:${b.label}`)).toEqual([`copy-${row.id}:Copy`, `sent-${row.id}:Mark sent`])
  // A button id carries no character a key could not hold.
  expect(buttonId('danwright32/slate.web', 7)).toBe('danwright32-slate-web-7')
})

test("/live lists the project's recent cards, newest first, and every unsent message", () => {
  const cards = [
    { repo: 'r/s', pr: 1, title: 'Old', state: 'live' as const, at: 1, url: 'u1' },
    { repo: 'r/s', pr: 2, title: 'New', state: 'deploying' as const, at: 2, url: 'u2', requester: { name: 'Kris', via: 'named' as const }, message: 'Soon.' },
    { repo: 'r/s', pr: 3, title: 'Sent', state: 'live' as const, at: 3, url: 'u3', requester: { name: 'Ana', via: 'slack' as const }, message: 'Done.', sentAt: 4 },
  ]
  expect(liveList(cards)).toBe(['- Live: Sent (#3)', '- Merged, deploying: New (#2)', '- Live: Old (#1)', '', 'Not sent yet:', '- Message for Kris (#2): Soon.'].join('\n'))
  expect(liveList([])).toBe('No merged changes have a card in this project yet.')
})
