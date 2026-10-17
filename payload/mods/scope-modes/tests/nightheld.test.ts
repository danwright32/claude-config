import { describe, expect, test } from 'claude-code/testing'
import { ASLEEP_DELIVERY, deliveryOf, heldAsleep, heldAtWake, heldUntilWake } from '../hooks/nightheld.ts'

// #1284: while asleep nothing is handed to Dan, in any session; what a session would have delivered
// is held and delivered when sleep mode ends, so every session reports at the same moment.

// The two dashes the style rule bans, named by code point so this file holds neither.
const DASHES = new RegExp(`[${String.fromCharCode(0x2014, 0x2013)}]| - `)

describe('deliveryOf: a call that hands Dan a result', () => {
  test('an Artifact publish, the default action or named, is a delivery, named by its file', () => {
    expect(deliveryOf('Artifact', { file_path: '/s/sleep-wake/status.html' })).toBe('Publish status.html')
    expect(deliveryOf('Artifact', { action: 'publish', file_path: '/s/page.html', url: 'https://claude.ai/code/artifact/abc' })).toBe('Publish page.html')
  })
  test("the Artifact open action is one too, named by its link without the query that can carry a token", () => {
    expect(deliveryOf('Artifact', { action: 'open', url: 'https://claude.ai/artifact/abc?t=x#f' })).toBe('Open https://claude.ai/artifact/abc')
  })
  test('an asset upload, a read, a list, a delete, a pin and a quickstart hand Dan nothing', () => {
    for (const action of ['read', 'list', 'delete', 'pin', 'unpin', 'quickstart'])
      expect(deliveryOf('Artifact', { action, url: 'https://claude.ai/artifact/abc' })).toBeUndefined()
    expect(deliveryOf('Artifact', { action: 'publish', asset: true, url: 'https://claude.ai/artifact/abc', file_path: '/s/a.png' })).toBeUndefined()
  })
  test('a Claude doc made, by create or a batch that creates, is a delivery; a batch editing one is too', () => {
    expect(deliveryOf('mcp__claude_ai_Claude_Docs__create', { title: 'Night notes' })).toBe('Publish a Claude doc')
    expect(deliveryOf('mcp__claude_ai_Claude_Docs__batch', { container: { kind: 'project', create: { name: 'Bidspoke morning status' } } })).toBe('Publish a Claude doc')
    expect(deliveryOf('mcp__claude_ai_Claude_Docs__update', { ref: { object: 'node', id: 'n' }, payload: 'x' })).toBe('Publish a Claude doc')
    expect(deliveryOf('mcp__claude_ai_Claude_Docs__read', { container: { kind: 'project', id: 'p' } })).toBeUndefined()
  })
  test('any other tool is no delivery', () => {
    expect(deliveryOf('Bash', { command: 'open -a Preview a.pdf' })).toBeUndefined()
    expect(deliveryOf('Write', { file_path: '/s/a.html' })).toBeUndefined()
  })
})

describe('heldUntilWake: how a held delivery is refused', () => {
  const h = heldUntilWake('Publish status.html')
  test('Claude is told it did not run, to keep the file, and that it is asked to deliver it at wake', () => {
    expect(h.deny).toBe(
      'Held until Dan wakes: sleep mode is on, so nothing is published or opened for him tonight, and "Publish status.html" did not run. Keep what it would have shown as it is and carry on; when sleep mode ends this session is asked to deliver it, where Dan is then. Do not publish it another way.',
    )
  })
  test('the card says it waits for the morning, never that a page is published instead', () => {
    expect(h.card).toEqual({ guard: 'Asleep', reason: 'Held for the morning: Publish status.html.', safeWay: 'Claude delivers it when you wake.' })
    expect(JSON.stringify(h)).not.toMatch(/private claude\.ai page|private page/)
  })
})

describe('heldAsleep: what needs Dan at the Mac, held while he sleeps', () => {
  const h = heldAsleep('Show a dialog on the Mac')
  test('it waits for the morning in the held card, and Claude is never told to publish a page instead', () => {
    expect(h.deny).toBe('Held: Dan is asleep, so "Show a dialog on the Mac" waits in the held card for the morning. Leave it, say in your final message what is waiting on him, and carry on; publish nothing in its place.')
    expect(h.card).toEqual({ guard: 'Asleep', reason: 'Held for the morning: Show a dialog on the Mac.', safeWay: 'It waits in the held card until you are up.' })
    expect(JSON.stringify(h)).not.toMatch(/private claude\.ai page|private page/)
  })
})

describe('the note every prompt carries while asleep', () => {
  test('it says to hand Dan nothing tonight and deliver at wake, never to publish a page now', () => {
    expect(ASLEEP_DELIVERY).toMatch(/^Dan is asleep, so hand him nothing tonight: publish no page and open nothing for him to read\./)
    expect(ASLEEP_DELIVERY).toMatch(/when sleep mode ends, this session is asked to deliver what it held/)
    expect(ASLEEP_DELIVERY).not.toMatch(/deliver results as a private claude\.ai page/)
  })
  test('it keeps what away holds on the Mac', () => {
    expect(ASLEEP_DELIVERY).toMatch(/Do not show a dialog, run a script whose text cannot be read, type or click into anything but a test build/)
  })
})

describe('heldAtWake: what a session is told to deliver when sleep mode ends', () => {
  test('nothing held says nothing', () => {
    expect(heldAtWake([])).toBe('')
  })
  test('each held call is named, and the calls ride in the data block, to be done where Dan is now', () => {
    const s = heldAtWake([
      { label: 'Publish status.html', call: 'Artifact {"file_path":"/s/status.html"}' },
      { label: 'Open https://claude.ai/artifact/abc', call: 'Artifact {"action":"open","url":"https://claude.ai/artifact/abc"}' },
    ])
    expect(s).toMatch(/^While Dan slept, this session held 2 things it would have handed him: Publish status\.html; Open https:\/\/claude\.ai\/artifact\/abc\. Deliver each now, where he is now/)
    expect(s).toContain('<untrusted-overnight-text>\nArtifact {"file_path":"/s/status.html"}\nArtifact {"action":"open","url":"https://claude.ai/artifact/abc"}\n</untrusted-overnight-text>')
  })
  test('one held thing reads as one', () => {
    expect(heldAtWake([{ label: 'Publish a Claude doc', call: 'x' }])).toMatch(/^While Dan slept, this session held one thing it would have handed him: Publish a Claude doc\./)
  })
  test('none of it uses a dash as punctuation', () => {
    expect(heldAtWake([{ label: 'Publish a.html', call: 'x' }]) + ASLEEP_DELIVERY + heldUntilWake('x').deny).not.toMatch(DASHES)
  })
})
