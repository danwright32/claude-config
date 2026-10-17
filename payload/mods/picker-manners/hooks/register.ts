import type { EngineInterface, Register } from 'claude-code'
import type {} from '../types/index.d.ts'
import { asksQuiet, refusal } from './pickers.ts'
import { etDateOf, issueRefsIn, questionWords, withQuestion } from './mod-kit/openquestions.ts'

// Picker manners (#615), agreed with Dan on 2026-10-03 (docs/mods-design.md, "Picker manners (#615)").
//
// - Claude Code's own dialog asks every question this mod does not refuse (#744, decided with Dan on
//   2026-10-05). The band question it drew before is gone: its tool.call hook waited for a press
//   through the mod's own $ noun, which Claude Code cuts off at 10 seconds, so the dialog then asked
//   every question a second time.
// - One question per call (CLAUDE.md): more are refused, and so is none.
// - "no next issue" or "just give me the list" turns next issue pickers off for the session;
//   /pickers on brings them back.

const quietRef = { plugin: 'picker-manners', key: 'quiet' } as const

const QUIET_NOTE = [
  '# Next issue pickers are off',
  'Dan turned off next issue pickers for this session. Offer next issues as a plain list, never as a picker, whatever any other rule says, until he runs /pickers on.',
].join('\n')

// Whether a prompt is Dan's own words, asked of mod-kit's one reader (#1135). One that cannot answer
// (a mod-kit loaded before it had the reader, which a reload can leave, standing rule 5) reads the
// prompt as not his, the side that changes nothing here, said once in the transcript; the prompt
// itself always goes on (L73).
let toldNoReader = false
const dansWords = async ($: EngineInterface, origin: { readonly kind?: string } | undefined): Promise<boolean> => {
  try {
    return await $.modkit.isDans({ origin })
  } catch (err) {
    if (!toldNoReader) {
      toldNoReader = true
      $.ui.log(`Picker manners could not ask mod-kit whether your message was your own words (${err instanceof Error ? err.message : String(err)}), so it read it as not yours. A new session loads mod-kit again.`)
    }
    return false
  }
}

// #1279, Dan 2026-10-17: a question Dan is asked about an issue (owner/name#N, or issue #N in this
// session's repository) is added to the issue's Open questions section, checked off with his answer
// when he gave one, so /sleep asks one still open and never one he answered. Read and written whole
// through gh; a failure is said, since /sleep would otherwise never see the question.
// The session's repository as GitHub names it, or why it cannot be told (said, never dropped, L11).
const sessionRepo = async ($: EngineInterface): Promise<{ repo: string } | { why: string }> => {
  try {
    const here = await $.session.repo()
    const github = here ? (await $.modkit.repo({ root: here.root, remote: here.remote })).github : null
    return github ? { repo: github } : { why: 'this session is in no repository GitHub knows' }
  } catch (err) {
    return { why: `this session's repository could not be read: ${err instanceof Error ? err.message : String(err)}` }
  }
}
const ghLine = (r: { stderr: string; exitCode: number }) => r.stderr.trim().split('\n')[0] || `gh exited ${r.exitCode}`
const recordOnIssues = async ($: EngineInterface, question: string, answer: string | null) => {
  const bare = question.match(/\bissue\s+#\d+/gi) ?? []
  const here = bare.length ? await sessionRepo($) : null
  if (here && 'why' in here) for (const b of bare) $.ui.log(`Picker manners could not add this question to ${b.toLowerCase()}'s Open questions (${here.why}), so /sleep will not see it there.`)
  const refs = issueRefsIn(question, here && 'repo' in here ? here.repo : null)
  const words = questionWords(question)
  for (const ref of refs) {
    const said = (why: string) => $.ui.log(`Picker manners could not add this question to ${ref.repo}#${ref.issue}'s Open questions (${why}), so /sleep will not see it there.`)
    try {
      const view = await $.process.run(['gh', 'issue', 'view', String(ref.issue), '--repo', ref.repo, '--json', 'state,body'], { timeoutMs: 20_000 })
      if (view.exitCode !== 0) {
        said(ghLine(view))
        continue
      }
      const j = JSON.parse(view.stdout) as { state?: unknown; body?: unknown }
      if (String(j.state).toUpperCase() === 'CLOSED') continue
      const body = typeof j.body === 'string' ? j.body : ''
      const next = withQuestion(body, words, answer === null ? undefined : { answer, date: etDateOf(await $.clock.now()) })
      if (next === body) continue
      const edit = await $.process.run(['gh', 'issue', 'edit', String(ref.issue), '--repo', ref.repo, '--body-file', '-'], { timeoutMs: 20_000, stdin: next })
      if (edit.exitCode !== 0) said(ghLine(edit))
    } catch (err) {
      said(err instanceof Error ? err.message : String(err))
    }
  }
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({ name: 'pickers', description: 'Turns next issue pickers back on for this session.', argumentHint: 'on' })
    return next(e)
  })

  on('tool.call', { tool: 'AskUserQuestion' }, async ($, e, next) => {
    const why = refusal(e.questions ?? [], {
      quiet: (await $.state.get(quietRef)).value ?? false,
      source: (e.metadata as { source?: string } | undefined)?.source,
    })
    if (why) return { deny: why }
    const r = await next(e)
    // #1279: a question about an issue goes into that issue's Open questions, after the dialog has
    // answered and off its path, so a slow GitHub never holds the answer back.
    const question = String(e.questions?.[0]?.question ?? '')
    const answers = (r as { result?: { answers?: Record<string, unknown> } }).result?.answers
    const answer = typeof answers?.[question] === 'string' ? (answers[question] as string) : null
    if (!r.deny && question) $.clock.after(0, () => void recordOnIssues($, question, answer))
    return r
  })

  // What Dan types, at the Mac or from his phone through Remote Control, as mod-kit's one reader says
  // (#1135). A plugin's prompt, a handoff's opening one included, a peer's or a notice is not his.
  on('prompt.submit', async ($, e, next) => {
    if (!(await dansWords($, e.origin))) return next(e)
    if (asksQuiet(e.text) && !(await $.state.get(quietRef)).value) {
      await $.state.set(quietRef, true)
      $.ui.invalidate('prompt.section')
      $.ui.log('Next issue pickers are off for this session; /pickers on brings them back.')
    }
    return next(e)
  })

  // Claude reads this for as long as next issue pickers are off, so an offer it would make from
  // CLAUDE.md's issue loop rule, which carries no next-issue tag for the refusal to see, is a plain
  // list too (spec #615 point 4: this overrides the loop rule for that session only). The section is
  // assembled afresh for every request, so a compaction keeps it.
  on('prompt.section', { name: 'memory' }, async ($, e, next) => {
    const r = await next(e)
    if (!(await $.state.get(quietRef)).value) return r
    return { text: r.text ? `${r.text}\n\n${QUIET_NOTE}` : QUIET_NOTE }
  })

  on('command.run', { command: 'pickers' }, async ($, e) => {
    if (e.args.trim().toLowerCase() !== 'on') return { text: '/pickers on brings next issue pickers back; nothing else is understood.' }
    await $.state.set(quietRef, false)
    $.ui.invalidate('prompt.section')
    return { text: 'Next issue pickers are back on.' }
  })
}
