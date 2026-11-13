import type { EngineInterface, Register } from 'claude-code'
import { errorText } from './mod-kit/skew.ts'
import type {} from '../types/index.d.ts'
import { asksQuiet, refusal } from './pickers.ts'
import { bareIssuesIn, etDateOf, issueRefsIn, leavesUnanswered, questionWords, withQuestion } from './mod-kit/openquestions.ts'
import { askAnyAccount, type GhRun } from './mod-kit/ghaccounts.ts'
import { guardAsks, guardIgnores } from './mod-kit/designquestions.ts'

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
      $.ui.log(`Picker manners could not ask mod-kit whether your message was your own words (${errorText(err, 'picker-manners')}), so it read it as not yours. A new session loads mod-kit again.`)
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
    return { why: `this session's repository could not be read: ${errorText(err, 'picker-manners')}` }
  }
}
const ghLine = (r: { stderr: string; exitCode: number }) => r.stderr.trim().split('\n')[0] || `gh exited ${r.exitCode}`
const notFound = (r: GhRun) => /Could not resolve to a Repository/i.test(r.stderr)
// What a failure says: the first one that is not another account's not found, as /sleep says it.
const saidOf = (failures: GhRun[]) => ghLine(failures.find(f => !notFound(f)) ?? (failures[0] as GhRun))
const recordOnIssues = async ($: EngineInterface, question: string, answer: string | null, choices: readonly string[]) => {
  // The bare issue #N references by the shared reader's own rule, so what is said matches what is dropped.
  const bare = bareIssuesIn(question)
  const here = bare.length ? await sessionRepo($) : null
  if (here && 'why' in here) for (const n of bare) $.ui.log(`Picker manners could not add this question to issue #${n}'s Open questions (${here.why}), so /sleep will not see it there.`)
  const refs = issueRefsIn(question, here && 'repo' in here ? here.repo : null)
  const words = questionWords(question)
  for (const ref of refs) {
    const said = (why: string) => $.ui.log(`Picker manners could not add this question to ${ref.repo}#${ref.issue}'s Open questions (${why}), so /sleep will not see it there.`)
    try {
      // As each account gh is logged in to, as /sleep asks: Dan's work repositories are visible only to
      // his work account (lessons review), through mod-kit's one helper.
      const gh = (argv: string[], env?: Record<string, string>, stdin?: string) =>
        $.process.run(argv, { timeoutMs: 20_000, ...(env ? { env } : {}), ...(stdin !== undefined ? { stdin } : {}) })
      const view = await askAnyAccount(gh, ['issue', 'view', String(ref.issue), '--repo', ref.repo, '--json', 'state,body,url'])
      if (!('stdout' in view)) {
        said(saidOf(view.failures))
        continue
      }
      const j = JSON.parse(view.stdout) as { state?: unknown; body?: unknown; url?: unknown }
      // gh issue view answers for a pull request's number too: its description is left alone.
      if (String(j.state).toUpperCase() === 'CLOSED' || /\/pull\/\d+/.test(String(j.url ?? ''))) continue
      const body = typeof j.body === 'string' ? j.body : ''
      const next = withQuestion(body, words, answer === null ? undefined : { answer, date: etDateOf(await $.clock.now()) }, choices)
      if (next === body) continue
      const edit = await askAnyAccount(gh, ['issue', 'edit', String(ref.issue), '--repo', ref.repo, '--body-file', '-'], notFound, next)
      if (!('stdout' in edit)) said(saidOf(edit.failures))
    } catch (err) {
      said(errorText(err, 'picker-manners'))
    }
  }
}

// The issues a question names, as a log line says them, without asking GitHub or the session's
// repository: owner/name#N as written, and a bare #N as issue #N.
const issuesNamedIn = (question: string) => [...issueRefsIn(question, null).map(x => `${x.repo}#${x.issue}`), ...bareIssuesIn(question).map(n => `issue #${n}`)]

// Work done after the dialog has answered and off its path, so a slow GitHub never holds the answer
// back. Whatever escapes it is said, never left as an unhandled rejection nobody reads (lessons review).
const reportingFailure = ($: EngineInterface, work: () => Promise<unknown>) => () =>
  void work().catch(err => $.ui.log(`Picker manners could not add this question to its issue's Open questions (${errorText(err, 'picker-manners')}), so /sleep will not see it there.`))
export const offTheDialog = ($: EngineInterface, work: () => Promise<unknown>) => $.clock.after(0, reportingFailure($, work))

// The design round guard's answer checked off on its issue, started on a timer (designRound.answered,
// below). #2408: the engine skips a listener that throws without the guard hearing of it (PR #2405),
// so anything stopping the work being started ($.clock.after throwing) is logged here and never
// thrown: the guard keeps his answer, and the question stays open on its issue. What the work itself
// meets is logged by recordOnIssues and reportingFailure. The timer is offTheDialog's, which the noun
// waits check reads as work after the noun answered; a function written in place handed to
// reportingFailure here would be read as the noun's own code, gh's 20 s included (#2333).
export const checkOffAnswered = async ($: EngineInterface, e: { question: string; answer: string; options: readonly string[] }) => {
  try {
    offTheDialog($, () => recordOnIssues($, e.question, e.answer, e.options))
  } catch (err) {
    const named = issuesNamedIn(e.question)
    const where = named.length ? `${named.map(x => `${x}'s`).join(', ')} Open questions` : "its issue's Open questions"
    try {
      await $.ui.log(`Picker manners could not check your answer off in ${where} (${errorText(err, 'picker-manners')}), so the question stays open there; the design round guard has your answer all the same.`)
    } catch {
      // Nowhere left to say it; the guard has his answer all the same.
    }
  }
}

export const register: Register = on => {
  // #2261: a hook on a noun no loaded mod provides stops this whole mod loading, so with the design
  // round guard's member absent the same no-op bottom it provides is put here too, and nothing
  // raises it. #2862: only when absent. Claude Code 2.1.323 refuses an engine.create that replaces a
  // member another plugin added, and unloads this whole mod, so the guard's own member is kept as
  // it is. Its module failing to load is how it comes to be absent, since Claude Code loads no
  // picker manners at all without the guard's plugin (dependency-unsatisfied, measured on 2.1.323).
  // The bottom is written FIRST and the built $ spread over it, so the guard's member, when there,
  // is the one returned, untouched; reading built.designRound to decide is itself refused ("used as
  // a value"). tests/test-mods-load-engine.sh loads both cases on the real engine.
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    return { designRound: { answered: async () => undefined }, ...built }
  })

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
    // #1279: a question about an issue goes into that issue's Open questions.
    const question = String(e.questions?.[0]?.question ?? '')
    const answers = (r as { result?: { answers?: Record<string, unknown> } }).result?.answers
    // A multi-select answer arrives as a list, and is an answer all the same (lessons review).
    const given = answers?.[question]
    const picked = typeof given === 'string' ? given : Array.isArray(given) && given.length ? given.map(String).join(', ') : null
    // #1774: /sleep's before bed dialog reaches this hook too, and its skip and go to sleep put the
    // question off rather than answer it, so the item stays open to be asked another night.
    const answer = picked !== null && leavesUnanswered(picked) ? null : picked
    // #1775: an item added open carries the answers the dialog offered, so /sleep offers them too.
    const choices = (e.questions?.[0]?.options ?? []).map(o => String(o.label ?? ''))
    if (r.deny || !question) return r
    // #2253: the design round guard counts only its own picker, so a question in its words asked
    // without its source is never written onto the issue, where a checked box reads as settled.
    if (guardIgnores(question, (e.metadata as { source?: unknown } | undefined)?.source)) {
      const refs = issuesNamedIn(question)
      const where = refs.length ? `${refs.map(x => `${x}'s`).join(', ')} Open questions` : 'any issue'
      $.ui.log(`Picker manners: this question was not added to ${where}, since the design round guard counts only its own picker, so this answer lets no edit through.`)
      const told = `Dan's answer to this question lets no edit through: the design round guard counts only its own picker, asked with the metadata its refusal of an edit gives, so nothing is recorded and it was not added to ${where}. Tell Dan that in one line; when the guard refuses an edit, ask its question the way that refusal says.`
      return r.deny !== undefined ? r : { ...r, context: [...(r.context ?? []), told] }
    }
    // #2261: the guard's own picker is written onto its issue only once the guard says it recorded
    // the answer (designRound.answered, below): an answer in Dan's own words, Run design rounds, Not
    // yet and a dialog that closed while he was away record nothing, so a checked box there would
    // read as settled while every edit stayed held. Nothing is added open either, since /sleep never
    // asks a guard question.
    if (guardAsks((e.metadata as { source?: unknown } | undefined)?.source)) return r
    offTheDialog($, () => recordOnIssues($, question, answer, choices))
    return r
  })

  // #2261: the design round guard has written down Dan's answer to its own picker, so the question
  // goes onto its issue checked off with that answer, off the dialog's path as every other one is.
  // With the guard not loaded nothing raises this, and nothing is written: the safe direction. This is
  // a call to a noun, which Claude Code cuts off at 10 s while gh is given 20, so GitHub is handed to
  // offTheDialog's timer, which the noun waits check reads as work after the noun answered (#939, #2299).
  on('designRound.answered', async ($, e, next) => {
    await checkOffAnswered($, e)
    return next(e)
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
