import { describe, expect, test } from 'claude-code/testing'
import { cardFrom, cardLines, carriedNote, finish, fold, nextStep, sent } from '../hooks/card.ts'
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
  test('not done reopens a step whose Done was sent', () => {
    const c = sent(made({ heading: 'x', steps: [step()] }), 0, true)
    expect(c.steps[0]?.isSent).toBe(true)
    const r = finish(c, 1, 'not-done')
    if ('refusal' in r) throw new Error(r.refusal)
    expect(r.card.steps[0]).toMatchObject({ isSent: false })
    expect(r.card.steps[0]?.finished).toBeUndefined()
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
    expect(l[0]).toEqual([{ text: 'Cloudflare WAF', color: 'warning' }])
    expect(l.map(textOf)).toEqual([
      'Cloudflare WAF',
      '1. Create the API token  already done',
      '2. Turn on the rule  [done]',
      'https://dash.cloudflare.com/waf  [copy-link]',
      'Security, WAF, Custom rules, Deploy',
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
  // with an ellipsis, now that mod-kit's left rule spans wrapped lines. The link and the value are
  // still cut, since Copy link and Copy each take them whole.
  test('the click path and an exact location wrap; the link and the value do not', () => {
    const c = made({
      heading: 'x',
      steps: [step({ clicks: 'Settings, Security, Web application firewall, Custom rules, Create rule', value: 'ip.src eq 1.2.3.4' })],
    })
    const l = lines(c) as (P & { wrap?: boolean })[][]
    expect(l.find(x => x[0]?.text?.startsWith('Settings'))?.[0]?.wrap).toBe(true)
    expect(l.find(x => x[0]?.text?.startsWith('https://'))?.[0]?.wrap).toBeUndefined()
    expect(l.find(x => x[0]?.text === 'ip.src eq 1.2.3.4')?.[0]?.wrap).toBeUndefined()
    const at = made({ heading: 'x', steps: [step({ url: undefined, location: 'Salesforce desktop app, Setup, Object Manager, Account, Fields' })] })
    expect((lines(at) as (P & { wrap?: boolean })[][]).find(x => x[0]?.text?.startsWith('Salesforce'))?.[0]?.wrap).toBe(true)
  })

  test('a finished step is dimmed and struck through, then how it finished: already done and per you grey, checked green', () => {
    let c = made({ heading: 'x', steps: [step({ checked: 'already-done', title: 'A' }), step({ title: 'B' }), step({ title: 'C' })] })
    const r1 = finish(c, 2, 'checked')
    if ('refusal' in r1) throw new Error(r1.refusal)
    const r2 = finish(r1.card, 3, 'per-you')
    if ('refusal' in r2) throw new Error(r2.refusal)
    c = r2.card
    const l = lines(c)
    for (const n of [1, 2, 3]) expect(l[n]?.[0]).toMatchObject({ dim: true, strikethrough: true })
    expect(l[1]?.[1]).toEqual({ text: '  already done', dim: true })
    expect(l[2]?.[1]).toEqual({ text: '  checked', color: 'success' })
    expect(l[3]?.[1]).toEqual({ text: '  done, per you', dim: true })
  })

  test('an exact location stands where the link would, and a sent Done reads as sent', () => {
    const c = sent(made({ heading: 'x', steps: [step({ url: undefined, location: 'Keychain Access, login' })] }), 0, true)
    const l = lines(c)
    expect(l.map(textOf)).toEqual(['x', '1. Turn on the WAF rule  sent', 'Keychain Access, login'])
  })

  // A long dashboard link cut at the edge still opens and copies whole (#708): it is a link part,
  // which mod-kit draws as Claude Code's Link, so the address travels with it however much shows,
  // and Copy link beside it, since Claude Code draws no hyperlinks on Apple Terminal.
  test('the open step\'s link is a link part carrying the whole address, with Copy link; an exact location stays text', () => {
    const url = `https://dash.cloudflare.com/${'a'.repeat(200)}/security/waf/custom-rules?zone=example.com`
    const l = lines(made({ heading: 'x', steps: [step({ url, clicks: 'Security, WAF' })] })) as (P & { href?: string; label?: string })[][]
    expect(l[2]).toEqual([{ text: url, href: url, indent: 3 }, { text: '  ' }, { button: 'copy-link', label: 'Copy link' }])
    // The click path is not a link.
    expect(l[3]?.[0]?.href).toBeUndefined()
    const at = lines(made({ heading: 'x', steps: [step({ url: undefined, location: 'Keychain Access, login' })] })) as (P & { href?: string })[][]
    // Text, never a link; it wraps rather than being cut (#734).
    expect(at[2]).toEqual([{ text: 'Keychain Access, login', indent: 3, wrap: true }])
  })

  test('a value of several lines shows on one line, and the indent follows the number width', () => {
    const steps = Array.from({ length: 10 }, (_, i) => step({ checked: i < 9 ? 'already-done' : 'not-done', title: `S${i + 1}`, value: i === 9 ? 'a\nb' : undefined }))
    const l = lines(made({ heading: 'x', steps }))
    const value = l.find(x => x.some(p => p.button === 'copy'))
    expect(value?.[0]).toMatchObject({ text: 'a b', indent: 4 })
  })
})
