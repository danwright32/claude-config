import { describe, expect, test } from 'claude-code/testing'
import { cardFrom, cardLines, carriedNote, finish, finishedWhen, fold, keepFinished, nextStep, paneColumns, sent } from '../hooks/card.ts'
import type { StepsCard } from '../types/index.d.ts'

const step = (over: Record<string, unknown> = {}) => ({ title: 'Turn on the WAF rule', url: 'https://dash.cloudflare.com/waf', checked: 'not-done', ...over })
const made = (input: unknown): StepsCard => {
  const r = cardFrom(input)
  if ('refusal' in r) throw new Error(r.refusal)
  return r.card
}

describe('cardFrom', () => {
  test('refuses a step with no link and no exact location, naming the step', () => {
    const r = cardFrom({ heading: 'Cloudflare', steps: [step(), step({ title: 'Save it', url: undefined })] })
    expect('refusal' in r && r.refusal).toMatch(/^Step 2 \(Save it\) has no link or exact location/)
  })
  test('takes an exact location in place of a link', () => {
    const c = made({ heading: 'Salesforce', steps: [step({ url: undefined, location: 'Salesforce desktop app, Setup, Object Manager' })] })
    expect(c.steps[0]?.location).toBe('Salesforce desktop app, Setup, Object Manager')
  })
  // #872: the card draws "Where:" and "What to do:" itself, so a label the author wrote is taken off
  // rather than drawn twice, however it is cased or spaced. A location that was only a label is none.
  test('takes off a label the author already wrote, so the card never doubles it', () => {
    const c = made({
      heading: 'x',
      steps: [step({ url: undefined, location: 'where:  Keychain Access, login', clicks: 'What To Do : File, New Password Item' }), step({ title: 'B', clicks: 'Then: Save' })],
    })
    expect(c.steps[0]).toMatchObject({ location: 'Keychain Access, login', clicks: 'File, New Password Item' })
    expect(c.steps[1]?.clicks).toBe('Save')
    // Only a leading label: the same words later in the text stay.
    expect(made({ heading: 'x', steps: [step({ clicks: 'Settings, then: Where: to send' })] }).steps[0]?.clicks).toBe('Settings, then: Where: to send')
    const r = cardFrom({ heading: 'x', steps: [step({ url: undefined, location: 'Where:' })] })
    expect('refusal' in r && r.refusal).toMatch(/^Step 1 .*has no link or exact location/)
  })
  test('refuses a link that is not a web address', () => {
    const r = cardFrom({ heading: 'x', steps: [step({ url: 'dash.cloudflare.com' })] })
    expect('refusal' in r && r.refusal).toMatch(/Step 1 .*link .*https/)
  })
  // The whole link, not only its start (#708 lessons review): a space or a control character
  // anywhere in it is no address, and a control character would reach the terminal's hyperlink.
  test('refuses a link with a space or a control character anywhere in it', () => {
    for (const url of ['https://dash.cloudflare.com/waf rules', 'https://dash.cloudflare.com/\u001b]8;;\u0007', 'https://a.example/\u0000', 'https://a\u0007b.example/x'])
      expect(cardFrom({ heading: 'x', steps: [step({ url })] })).toMatchObject({ refusal: expect.stringMatching(/Step 1 .*link .*https/) })
  })
  test('refuses a step that does not say whether it was checked against the current state', () => {
    const r = cardFrom({ heading: 'x', steps: [step({ checked: undefined })] })
    expect('refusal' in r && r.refusal).toMatch(/Step 1 .*checked.*already-done, not-done or cannot-check/)
  })
  test('refuses no heading, no steps, and a step with no title', () => {
    expect('refusal' in cardFrom({ steps: [step()] })).toBe(true)
    expect('refusal' in cardFrom({ heading: 'x', steps: [] })).toBe(true)
    expect('refusal' in cardFrom({ heading: 'x', steps: [step({ title: ' ' })] })).toBe(true)
    expect('refusal' in cardFrom(null)).toBe(true)
  })
  test('a step found already done arrives finished, as already done', () => {
    const c = made({ heading: 'x', steps: [step({ checked: 'already-done' }), step({ title: 'Second' })] })
    expect(c.steps.map(s => s.finished)).toEqual(['already', undefined])
    expect(nextStep(c)).toBe(1)
  })
})

describe('finish', () => {
  test('marks a step checked or done per you, and refuses a step out of range or already finished', () => {
    const c = made({ heading: 'x', steps: [step(), step({ title: 'Second' })] })
    const a = finish(c, 1, 'checked')
    if ('refusal' in a) throw new Error(a.refusal)
    expect(a.card.steps[0]?.finished).toBe('checked')
    const b = finish(a.card, 2, 'per-you')
    if ('refusal' in b) throw new Error(b.refusal)
    expect(b.card.steps[1]?.finished).toBe('per-you')
    expect(nextStep(b.card)).toBeUndefined()
    expect('refusal' in finish(c, 3, 'checked')).toBe(true)
    expect('refusal' in finish(a.card, 1, 'per-you')).toBe(true)
    expect('refusal' in finish(c, 1, 'maybe' as never)).toBe(true)
  })
  // #886: "step 2 done" with step 1 open was recorded as both, and the card claimed an install Dan
  // never did. Only the open step takes a verdict; any other is refused with the ask.
  test('a verdict on a step that is not the open one is refused, telling Claude to ask Dan which step he means', () => {
    const c = made({ heading: 'x', steps: [step({ title: 'Pull' }), step({ title: 'Install the checker' }), step({ title: 'Run the check' })] })
    for (const v of ['checked', 'per-you', 'not-done'] as const) {
      const r = finish(c, 2, v)
      expect('refusal' in r && r.refusal).toMatch(/^Step 2 \(Install the checker\) is not the open step; step 1 \(Pull\) is\. .*Ask Dan which step he means/)
    }
    expect('refusal' in finish(c, 1, 'per-you')).toBe(false)
  })
  test('a verdict records when the step finished, and whether Dan pressed its Done', () => {
    const c = made({ heading: 'x', steps: [step(), step({ title: 'Second' })] })
    const a = finish(sent(c, 0, true), 1, 'per-you', 1234)
    if ('refusal' in a) throw new Error(a.refusal)
    expect(a.card.steps[0]).toMatchObject({ finished: 'per-you', finishedAt: 1234, isPressed: true, isSent: false })
    const b = finish(a.card, 2, 'per-you', 5678)
    if ('refusal' in b) throw new Error(b.refusal)
    expect(b.card.steps[1]).toMatchObject({ finished: 'per-you', finishedAt: 5678 })
    expect(b.card.steps[1]?.isPressed).toBeUndefined()
  })
  // #872: a step that cannot be done yet comes off the card honestly, as withdrawn rather than done.
  test('withdrawn takes a step off, the open one or a later one, and the card moves on', () => {
    const c = sent(made({ heading: 'x', steps: [step(), step({ title: 'Second' }), step({ title: 'Third' })] }), 0, true)
    const a = finish(c, 3, 'withdrawn')
    if ('refusal' in a) throw new Error(a.refusal)
    expect(a.card.steps[2]?.finished).toBe('withdrawn')
    const b = finish(a.card, 1, 'withdrawn')
    if ('refusal' in b) throw new Error(b.refusal)
    expect(b.card.steps[0]).toMatchObject({ finished: 'withdrawn', isSent: false })
    expect(nextStep(b.card)).toBe(1)
    expect('refusal' in finish(b.card, 1, 'withdrawn')).toBe(true)
  })
  test('not done reopens a step whose Done was sent', () => {
    const c = sent(made({ heading: 'x', steps: [step()] }), 0, true)
    expect(c.steps[0]?.isSent).toBe(true)
    const r = finish(c, 1, 'not-done')
    if ('refusal' in r) throw new Error(r.refusal)
    expect(r.card.steps[0]).toMatchObject({ isSent: false })
    expect(r.card.steps[0]?.finished).toBeUndefined()
    // That Done was answered (#886 review): a later verdict on his words must not say he pressed it.
    expect(r.card.steps[0]?.isPressed).toBeUndefined()
  })
})

describe('fold', () => {
  test('adds the other card\'s unfinished steps under its heading, and folding twice adds nothing more', () => {
    const into = made({ heading: 'Cloudflare WAF', steps: [step()] })
    const from = made({ heading: 'DNS', steps: [step({ title: 'Made the record', checked: 'already-done' }), step({ title: 'Add the CNAME', url: 'https://d.example' })] })
    const once = fold(into, from)
    expect(once.steps.map(s => s.title)).toEqual(['Turn on the WAF rule', 'DNS: Add the CNAME'])
    expect(fold(once, from)).toEqual(once)
    // A malformed card kept from before adds nothing.
    expect(fold(into, { heading: 'x', steps: 'no' } as never)).toEqual(into)
  })

  // #734: a step held under both the repository root and a pre-#708 worktree key is the same step,
  // listed once on the very first fold, whether the root's copy is still open or finished.
  test('a step the card already holds is not listed again on the first fold, under its heading', () => {
    const cname = step({ title: 'Add the CNAME', url: 'https://d.example' })
    const into = made({ heading: 'DNS', steps: [cname, step()] })
    const from = made({ heading: 'DNS', steps: [cname] })
    expect(fold(into, from)).toEqual(into)
    const finished = { ...into, steps: into.steps.map((s, i) => (i === 0 ? { ...s, finished: 'checked' as const } : s)) }
    expect(fold(finished, from)).toEqual(finished)
    // The same title at another link is another step, and is still added.
    const other = made({ heading: 'DNS', steps: [step({ title: 'Add the CNAME', url: 'https://e.example' })] })
    expect(fold(into, other).steps.map(s => s.title)).toEqual(['Add the CNAME', 'Turn on the WAF rule', 'DNS: Add the CNAME'])
  })
})

describe('keepFinished', () => {
  // #886: a card pinned again replaces the old one, and a step found done would lose how and when it
  // finished, reading as "already done" with no time. It keeps them, and one from a held card is
  // from an earlier session.
  test('a step pinned again as already done keeps how and when it finished; a step it does not match stays already done', () => {
    const prior: StepsCard = {
      heading: 'x',
      steps: [
        { title: 'A', url: 'https://a.example', finished: 'per-you', finishedAt: 10, isPressed: true },
        { title: 'B', url: 'https://b.example' },
      ],
    }
    const next = made({ heading: 'x', steps: [step({ title: 'A', url: 'https://a.example', checked: 'already-done' }), step({ title: 'C', url: 'https://c.example', checked: 'already-done' }), step({ title: 'B', url: 'https://b.example' })] })
    const kept = keepFinished(next, prior)
    expect(kept.steps[0]).toEqual({ title: 'A', url: 'https://a.example', finished: 'per-you', finishedAt: 10, isPressed: true })
    expect(kept.steps[1]).toEqual({ title: 'C', url: 'https://c.example', finished: 'already' })
    expect(kept.steps[2]?.finished).toBeUndefined()
    expect(keepFinished(next, { ...prior, isCarried: true }).steps[0]).toMatchObject({ finished: 'per-you', isEarlier: true })
    expect(keepFinished(next, null)).toEqual(next)
  })
})

describe('carriedNote', () => {
  // Telling Dan they are all done wrote nothing, so the kept card came back every session (#708).
  // The note's only way out is the steps tool, where a step found done is already-done and a card
  // with every step so is cleared; register.test proves that route clears the kept card.
  test('asks for every step to go back through the steps tool, a done one as already-done, and offers no way out that keeps the card', () => {
    const note = carriedNote(made({ heading: 'Cloudflare WAF', steps: [step(), step({ title: 'Purge the cache' })] }))
    expect(note).toMatch(/steps tool/)
    expect(note).toMatch(/already-done/)
    expect(note).toMatch(/clear/)
    expect(note).not.toMatch(/or tell Dan they are all done/)
  })
})

describe('cardLines', () => {
  type P = { text?: string; button?: string; color?: string; bold?: boolean; dim?: boolean; strikethrough?: boolean; indent?: number }
  const lines = (c: StepsCard) => cardLines(c) as P[][]
  const textOf = (l: P[]) => l.map(p => p.text ?? `[${p.button}]`).join('')
  // #872: the card draws each label itself, bold and whole, under the step's title.
  const WHERE = { text: 'Where: ', bold: true, whole: true, indent: 3 }
  const WHAT = { text: 'What to do: ', bold: true, whole: true, indent: 3 }

  test('an amber heading, only the next step open, later steps by title alone', () => {
    const c = made({
      heading: 'Cloudflare WAF',
      steps: [
        step({ checked: 'already-done', title: 'Create the API token' }),
        step({ title: 'Turn on the rule', clicks: 'Security, WAF, Custom rules, Deploy', value: 'ip.src eq 1.2.3.4' }),
        step({ title: 'Purge the cache' }),
      ],
    })
    const l = lines(c)
    // While the open step is Dan's to do, the heading says so (#863), on the card's own line rather
    // than a second row beside it.
    expect(l[0]).toEqual([{ text: 'Cloudflare WAF', color: 'warning' }, { text: '  waiting on you', dim: true }])
    expect(l.map(textOf)).toEqual([
      'Cloudflare WAF  waiting on you',
      '1. Create the API token  already done before this card',
      '2. Turn on the rule  [done]',
      'Where: https://dash.cloudflare.com/waf  [copy-link]',
      'What to do: Security, WAF, Custom rules, Deploy',
      'ip.src eq 1.2.3.4  [copy]',
      '3. Purge the cache',
    ])
    // The step to do is bold in the terminal's own text colour; its details sit under its title.
    expect(l[2]?.[0]).toMatchObject({ bold: true })
    expect(l[2]?.[0]?.color).toBeUndefined()
    expect(l.slice(3, 6).every(x => x[0]?.indent === 3)).toBe(true)
    // A later step is plain: not bold, not dim.
    expect(l[6]).toEqual([{ text: '3. Purge the cache' }])
  })

  // #734: a long click path or exact location wraps under its step rather than being cut at the edge
  // with an ellipsis, now that mod-kit's left rule spans wrapped lines. #939 reversed the link and the
  // value being cut: they were cut because Copy link and Copy took them whole, and where a click cannot
  // reach those buttons (Apple Terminal, the main screen) a cut address could not be had at all, so
  // they wrap too and can be selected whole.
  test('the click path, an exact location, the link and the value all wrap', () => {
    const c = made({
      heading: 'x',
      steps: [step({ clicks: 'Settings, Security, Web application firewall, Custom rules, Create rule', value: 'ip.src eq 1.2.3.4' })],
    })
    const l = lines(c) as (P & { wrap?: boolean })[][]
    expect(l.find(x => x[1]?.text?.startsWith('Settings'))?.[1]?.wrap).toBe(true)
    expect(l.find(x => x[1]?.text?.startsWith('https://'))?.[1]?.wrap).toBe(true)
    expect(l.find(x => x[0]?.text === 'ip.src eq 1.2.3.4')?.[0]?.wrap).toBe(true)
    const at = made({ heading: 'x', steps: [step({ url: undefined, location: 'Salesforce desktop app, Setup, Object Manager, Account, Fields' })] })
    expect((lines(at) as (P & { wrap?: boolean })[][]).find(x => x[1]?.text?.startsWith('Salesforce'))?.[1]?.wrap).toBe(true)
  })

  // #939: Dan, 2026-10-08, "I also can't click done here" and "copy link doesn't work here". Where a
  // click cannot reach a button mod-kit draws its instead text: Done says what to type, which is what
  // Done would have sent, and Copy link and Copy draw nothing, since the link and the value beside them
  // are the text to select.
  test('every button carries what is drawn where a click cannot reach it: Done the words to type, Copy link and Copy nothing', () => {
    const c = made({ heading: 'x', steps: [step({ checked: 'already-done', title: 'A' }), step({ title: 'B', value: 'ip.src eq 1.2.3.4' })] })
    const buttons = (cardLines(c) as (P & { instead?: P[] })[][]).flat().filter(p => p.button)
    expect(buttons).toEqual([
      { button: 'done', label: 'Done', instead: [{ text: 'type: ', dim: true }, { text: 'step 2 done' }] },
      { button: 'copy-link', label: 'Copy link', instead: [] },
      { button: 'copy', label: 'Copy', instead: [] },
    ])
    // The words to type are the very prompt a press of Done sends, so Claude reads both the same way.
    expect(buttons[0]?.instead?.map(r => r.text).join('')).toBe('type: step 2 done')
  })

  // #939: a docked pane asks to be as wide as its widest line, so the words drawn in Done's place,
  // wider than "[ Done ]", are not cut at the dock's edge.
  test('the pane asks for the width of the words drawn in place of Done', () => {
    const title = 'T'.repeat(40)
    const c = made({ heading: 'x', steps: [step({ title, url: undefined, location: 'here' })] })
    // The rule, "1. ", the title, two spaces, then "type: step 1 done".
    expect(paneColumns(c)).toBe(2 + 3 + title.length + 2 + 'type: step 1 done'.length)
  })

  // #886: grey reads as old, so only a step finished before this card is grey. One finished in this
  // session is struck through in the terminal's own colour with the time it finished, and a Done
  // Dan pressed reads differently from a step Claude recorded on his word.
  test('a step finished in this session is struck through, not grey, with the time it finished; Done pressed and per you read differently', () => {
    const T = Date.UTC(2026, 9, 7, 19, 41)
    let c = made({ heading: 'x', steps: [step({ checked: 'already-done', title: 'A' }), step({ title: 'B' }), step({ title: 'C' }), step({ title: 'D' }), step({ title: 'E' })] })
    const verdict = (n: number, v: 'checked' | 'per-you') => {
      const r = finish(c, n, v, T)
      if ('refusal' in r) throw new Error(r.refusal)
      c = r.card
    }
    verdict(2, 'checked')
    c = sent(c, 2, true)
    verdict(3, 'per-you')
    verdict(4, 'per-you')
    const l = cardLines(c, { now: T + 60_000, timeZone: 'America/New_York' }) as P[][]
    expect(l[1]).toEqual([{ text: '1. A', dim: true, strikethrough: true }, { text: '  already done before this card', dim: true }])
    expect(l[2]).toEqual([{ text: '2. B', strikethrough: true }, { text: '  checked on Oct 7 at 3:41 PM', color: 'success' }])
    expect(l[3]).toEqual([{ text: '3. C', strikethrough: true }, { text: '  done, you pressed Done on Oct 7 at 3:41 PM' }])
    expect(l[4]).toEqual([{ text: '4. D', strikethrough: true }, { text: '  done, per you, recorded on Oct 7 at 3:41 PM' }])
    expect(l[5]?.[0]).toMatchObject({ text: '5. E', bold: true })
  })

  // #886 review: the time goes with being taken off, never with "not done", which read as the step
  // not being done at that moment.
  test('a withdrawn step says when it was taken off, in this session and an earlier one', () => {
    const T = Date.UTC(2026, 9, 7, 19, 41)
    const r = finish(made({ heading: 'x', steps: [step({ title: 'A' }), step({ title: 'B' })] }), 1, 'withdrawn', T)
    if ('refusal' in r) throw new Error(r.refusal)
    const at = { now: T, timeZone: 'America/New_York' }
    expect((cardLines(r.card, at) as P[][])[1]).toEqual([{ text: '1. A', dim: true }, { text: '  taken off on Oct 7 at 3:41 PM, not done', dim: true }])
    expect((cardLines({ ...r.card, isCarried: true }, { ...at, now: T + 3 * 86_400_000 }) as P[][])[1]?.[1]).toEqual({
      text: '  taken off in an earlier session on Oct 7 at 3:41 PM, not done',
      dim: true,
    })
    // Kept before #886, with no time: the same words, without one.
    const untimed = finish(made({ heading: 'x', steps: [step({ title: 'A' }), step({ title: 'B' })] }), 1, 'withdrawn')
    if ('refusal' in untimed) throw new Error(untimed.refusal)
    expect((cardLines({ ...untimed.card, isCarried: true }, at) as P[][])[1]?.[1]).toEqual({ text: '  taken off in an earlier session, not done', dim: true })
  })

  // #886 review: a card nobody redraws keeps its text past midnight, so a time with no date would
  // read as today on the next day. The date is always there, read in the zone given.
  test('when a step finished always carries its date, so it never goes stale, in the zone given', () => {
    const T = Date.UTC(2026, 9, 7, 19, 41)
    const ny = 'America/New_York'
    expect(finishedWhen(T, { now: T, timeZone: ny })).toBe('on Oct 7 at 3:41 PM')
    expect(finishedWhen(T, { now: T + 86_400_000, timeZone: ny })).toBe('on Oct 7 at 3:41 PM')
    expect(finishedWhen(T, { now: T, timeZone: 'Asia/Kolkata' })).toBe('on Oct 8 at 1:11 AM')
    expect(finishedWhen(T, { now: Date.UTC(2027, 0, 2), timeZone: ny })).toBe('on Oct 7, 2026 at 3:41 PM')
  })

  test('a step finished in an earlier session is grey, says so, and shows when it finished', () => {
    const T = Date.UTC(2026, 9, 7, 19, 41)
    const DAY = 86_400_000
    const card: StepsCard = {
      heading: 'Chrome sign out',
      isCarried: true,
      steps: [
        { title: 'Sign out', url: 'https://a.example', finished: 'per-you', finishedAt: T - 3 * DAY },
        { title: 'Clear cookies', url: 'https://b.example', finished: 'checked', finishedAt: T - 60 * 60_000, isPressed: true },
        { title: 'Old', url: 'https://c.example', finished: 'per-you', isPressed: true },
        { title: 'Sign in again', url: 'https://d.example' },
      ],
    }
    const l = cardLines(card, { now: T, timeZone: 'America/New_York' }) as P[][]
    expect(l[1]).toEqual([{ text: '1. Sign out', dim: true, strikethrough: true }, { text: '  done, per you, in an earlier session on Oct 4 at 3:41 PM', dim: true }])
    expect(l[2]).toEqual([{ text: '2. Clear cookies', dim: true, strikethrough: true }, { text: '  checked in an earlier session on Oct 7 at 2:41 PM', dim: true }])
    // Kept before #886, with no time: said to be earlier all the same.
    expect(l[3]).toEqual([{ text: '3. Old', dim: true, strikethrough: true }, { text: '  done, you pressed Done, in an earlier session', dim: true }])
    // A step pinned again from the held card keeps the same reading.
    const again = keepFinished(made({ heading: 'Chrome sign out', steps: [step({ title: 'Sign out', url: 'https://a.example', checked: 'already-done' }), step({ title: 'Sign in again', url: 'https://d.example' })] }), card)
    expect((cardLines(again, { now: T, timeZone: 'America/New_York' }) as P[][])[1]?.[1]).toEqual({ text: '  done, per you, in an earlier session on Oct 4 at 3:41 PM', dim: true })
  })

  // #872: withdrawn reads as removed, never as done: dimmed but not struck through, which is how a
  // finished step reads, and says it was not done.
  test('a withdrawn step is dimmed, not struck through, and says it was taken off not done', () => {
    const r = finish(made({ heading: 'x', steps: [step({ title: 'A' }), step({ title: 'B' })] }), 1, 'withdrawn')
    if ('refusal' in r) throw new Error(r.refusal)
    const l = lines(r.card)
    expect(l[1]).toEqual([{ text: '1. A', dim: true }, { text: '  taken off, not done', dim: true }])
    expect(l[2]?.[0]).toMatchObject({ text: '2. B', bold: true })
  })

  test('an exact location stands where the link would, and a sent Done reads as sent', () => {
    const c = sent(made({ heading: 'x', steps: [step({ url: undefined, location: 'Keychain Access, login' })] }), 0, true)
    const l = lines(c)
    // Sent, the step waits on Claude rather than on Dan, so the heading no longer says it waits on him (#863).
    expect(l.map(textOf)).toEqual(['x', '1. Turn on the WAF rule  sent', 'Where: Keychain Access, login'])
  })

  // A long dashboard link cut at the edge still opens and copies whole (#708): it is a link part,
  // which mod-kit draws as Claude Code's Link, so the address travels with it however much shows,
  // and Copy link beside it, since Claude Code draws no hyperlinks on Apple Terminal.
  test('the open step\'s link is a link part carrying the whole address, with Copy link; an exact location stays text', () => {
    const url = `https://dash.cloudflare.com/${'a'.repeat(200)}/security/waf/custom-rules?zone=example.com`
    const l = lines(made({ heading: 'x', steps: [step({ url, clicks: 'Security, WAF' })] })) as (P & { href?: string; label?: string })[][]
    expect(l[2]).toEqual([WHERE, { text: url, href: url, wrap: true }, { text: '  ' }, { button: 'copy-link', label: 'Copy link', instead: [] }])
    // The click path is not a link.
    expect(l[3]?.[1]?.href).toBeUndefined()
    const at = lines(made({ heading: 'x', steps: [step({ url: undefined, location: 'Keychain Access, login' })] })) as (P & { href?: string })[][]
    // Text, never a link; it wraps rather than being cut (#734).
    expect(at[2]).toEqual([WHERE, { text: 'Keychain Access, login', wrap: true }])
  })

  // #872: a bare location line read to Dan as an unexplained fragment, so the card labels each part
  // of the open step itself: "Where:" before the link or location, "What to do:" before the clicks,
  // each bold and drawn whole, once. The value stays on its own line with Copy.
  test('the open step labels its link or location and its clicks, each label once and bold; the value has none', () => {
    const at = lines(made({ heading: 'x', steps: [step({ url: undefined, location: 'Keychain Access, login', clicks: 'File, New Password Item', value: 'hunter2' })] }))
    expect(at.slice(2)).toEqual([
      [WHERE, { text: 'Keychain Access, login', wrap: true }],
      [WHAT, { text: 'File, New Password Item', wrap: true }],
      [{ text: 'hunter2', indent: 3, wrap: true }, { text: '  ' }, { button: 'copy', label: 'Copy', instead: [] }],
    ])
    const all = at.flat().map(p => p.text ?? '').join('\n')
    expect(all.match(/Where:/g)).toHaveLength(1)
    expect(all.match(/What to do:/g)).toHaveLength(1)
    // A later step is its title alone, so it carries no labels either.
    const two = lines(made({ heading: 'x', steps: [step({ clicks: 'A, B' }), step({ title: 'Later', clicks: 'C, D' })] }))
    expect(two.flat().filter(p => p.text === 'Where: ' || p.text === 'What to do: ')).toHaveLength(2)
  })

  // #872, Dan after a step whose What to do held four actions in one sentence: "step 4 would've been a
  // lot clearer if it had a sub list where all of the steps in what to do were also numbered". So
  // clicks given as a list are drawn under the bold label, one numbered action per line.
  test('a four action step renders 1 to 4 under the bold What to do label, one action per line', () => {
    const actions = ['Open Terminal', 'Paste the command and press Return', 'Type /clear', 'Type /exit']
    const c = made({ heading: 'x', steps: [step({ clicks: actions, value: 'claude --resume' })] })
    expect(c.steps[0]?.clicks).toEqual(actions)
    const l = lines(c)
    expect(l[3]).toEqual([WHAT])
    expect(l.slice(4, 8)).toEqual(actions.map((a, k) => [{ text: `${k + 1}. `, whole: true, indent: 5 }, { text: a, wrap: true }]))
    expect(l.map(textOf).slice(3, 9)).toEqual([
      'What to do: ',
      '1. Open Terminal',
      '2. Paste the command and press Return',
      '3. Type /clear',
      '4. Type /exit',
      'claude --resume  [copy]',
    ])
  })

  test('an action list takes off a label and numbers the author wrote, drops empty actions, and one action is a line', () => {
    const c = made({ heading: 'x', steps: [step({ clicks: ['What to do: 1. Open Terminal', ' ', '2) Type /exit'] }), step({ title: 'B', clicks: ['Save'] })] })
    expect(c.steps[0]?.clicks).toEqual(['Open Terminal', 'Type /exit'])
    // A list of one is drawn as the plain string always was: beside the label, unnumbered.
    expect(c.steps[1]?.clicks).toBe('Save')
    // Only a list number, which a space follows: a number that is the action's own text stays whole.
    expect(made({ heading: 'x', steps: [step({ clicks: ['1.5x zoom', '2.5 GB limit: raise it', '3)Save'] })] }).steps[0]?.clicks).toEqual([
      '1.5x zoom',
      '2.5 GB limit: raise it',
      '3)Save',
    ])
    // A list with nothing in it is no clicks at all, and one holding a non string is refused.
    expect(made({ heading: 'x', steps: [step({ clicks: [' '] })] }).steps[0]?.clicks).toBeUndefined()
    const r = cardFrom({ heading: 'x', steps: [step({ clicks: ['Open', 3] })] })
    expect('refusal' in r && r.refusal).toMatch(/^Step 1 .*clicks/)
  })

  test('a step with a link gets "Where:" on the link line', () => {
    const l = lines(made({ heading: 'x', steps: [step({ clicks: 'Security, WAF' })] })) as (P & { href?: string })[][]
    expect(l[2]?.[0]).toEqual(WHERE)
    expect(l[2]?.[1]?.href).toBe('https://dash.cloudflare.com/waf')
    expect(l[3]?.[0]).toEqual(WHAT)
  })

  test('a value of several lines shows on one line, and the indent follows the number width', () => {
    const steps = Array.from({ length: 10 }, (_, i) => step({ checked: i < 9 ? 'already-done' : 'not-done', title: `S${i + 1}`, value: i === 9 ? 'a\nb' : undefined }))
    const l = lines(made({ heading: 'x', steps }))
    const value = l.find(x => x.some(p => p.button === 'copy'))
    expect(value?.[0]).toMatchObject({ text: 'a b', indent: 4 })
  })
})
