import { expect, test } from 'claude-code/testing'
import type { Register } from 'claude-code'
import { typedAnswerText, typedMissing, typedToast } from '../hooks/typed.ts'

// A typed answer to a mod's question (#1138, #1145): when Dan types instead of choosing, nothing is
// recorded, and both the design round guard and ask before saving say so the same way: Dan in a
// toast, and Claude told to say so in one line, answer what he said, and ask again. One wording, in
// mod-kit, so the two cannot drift.
const DASHES = new RegExp(`[${String.fromCharCode(0x2014)}${String.fromCharCode(0x2013)}]`)
const SAID = { guard: 'Ask before saving', typed: 'only for the web app', still: 'nothing was saved', again: 'ask him the same question again, with the same metadata' }

test("what Dan and Claude are told: his words quoted, what stays as it was, and the question to ask again", () => {
  const text = typedAnswerText(SAID)
  expect(text).toBe(
    'Dan typed "only for the web app" instead of choosing an answer, so it was not recorded, and nothing was saved. ' +
      'Tell him in one line that his typed answer was not recorded, because only choosing one of the answers counts; answer what he said if it asks something; then ask him the same question again, with the same metadata.',
  )
  expect(typedToast('Ask before saving')).toBe('Ask before saving: your typed answer was not recorded, because only choosing one of the answers counts. Choose one when Claude asks again.')
  for (const t of [text, typedToast("x")]) expect(DASHES.test(t)).toBe(false)
  // An input missing a part names it, rather than tell Claude half a sentence.
  expect(typedMissing(SAID)).toBeUndefined()
  expect(typedMissing({ ...SAID, again: ' ', still: undefined as never })).toBe('$.modkit.typedAnswer needs still, again as words')
  expect(typedMissing(undefined)).toBe('$.modkit.typedAnswer needs guard, typed, still, again as words')
})

// The noun the guards call, asked from another plugin as a mod asks it.
const asker: { name: string; register: Register } = {
  name: 'asker',
  register: on => {
    on('tool.call', { tool: 'Bash' }, async ($, e) => {
      try {
        return { deny: await $.modkit.typedAnswer(JSON.parse(String((e as { command?: string }).command))) }
      } catch (err) {
        return { deny: `threw: ${err instanceof Error ? err.message : String(err)}` }
      }
    })
  },
}

test('$.modkit.typedAnswer shows Dan the toast and hands back what Claude is told', { plugins: [asker] }, async ($, on) => {
  const toasts: string[] = []
  let toastFails = false
  on('ui.toast', ($$, e) => {
    if (toastFails) throw new Error('no toast here')
    toasts.push(String(e.text))
    return { value: undefined }
  })
  const ask = async (input: unknown) => ((await $.tool.call({ tool: 'Bash', command: JSON.stringify(input) } as never)) as { deny?: string }).deny ?? ''
  expect(await ask(SAID)).toBe(typedAnswerText(SAID))
  expect(toasts).toEqual([typedToast('Ask before saving')])
  // A toast the engine cannot show it drops and logs itself, never throwing to the member: Claude is
  // told the same, and is told to say it in one line, so Dan still hears it.
  toastFails = true
  expect(await ask(SAID)).toBe(typedAnswerText(SAID))
  expect(toasts.length).toBe(1)
  // An input missing a part is refused by name, and no toast is shown for it.
  toastFails = false
  expect(await ask({ ...SAID, again: '' })).toBe('threw: $.modkit.typedAnswer needs again as words')
  expect(toasts.length).toBe(1)
})
