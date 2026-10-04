import type { EngineInterface, Register } from 'claude-code'
import type { HandoffShown } from '../types/index.d.ts'
import { ageOf, bandLines, changesOf, keyOf, namesIn, readingOf } from './handoff.ts'
import type { Name, Reading } from './handoff.ts'

// The handoff (#613), settled with Dan on 2026-10-03 and in the design rounds of 2026-10-04
// (docs/mods-design.md, "Handoff (#613)").
//
// - /handoff, run only by Dan, asks Claude to write the next session's opening prompt and save it
//   with this mod's save tool, which refuses unless /handoff ran in this session (Claude never
//   writes one on its own). One per repository: a new one archives the one it replaces.
// - At the next interactive session start in that repository (any worktree of it), the band shows
//   "Handoff saved 3h ago: <title>" with Use and Dismiss, and each issue, PR or milestone it names
//   that closed, merged or changed since gets a grey line of its own, re-read from GitHub first so
//   a handoff never reads as current when it is not (L61).
// - Use submits it as Dan's prompt; Use or Dismiss archives it, never deletes it, and the archive
//   is claimed with one atomic move, so two sessions cannot both pick it up.
//
// Kept per Mac in ~/.claude/state/handoff/<repository>/ (never synced): current.json, and every
// handoff it replaced, used or dismissed under archive/.

const MOD = 'handoff'
const shownRef = { plugin: 'handoff', key: 'shown' } as const
const armedRef = { plugin: 'handoff', key: 'armed' } as const

type Saved = { v: 1; repo: string; savedAt: number; title: string; prompt: string; baseline: Reading[] }

const WRITE = (notes: string) =>
  [
    'Dan ran /handoff: write the opening prompt for the next session in this project, then save it.',
    'Write it as Dan would type it to start that session: what to pick up; what to read first (issues and their latest comments, discussions, memory notes, docs), named by number or path; every constraint Dan has stated for this work, in his words; and the state being left behind (open PRs, unmerged branches and worktrees, anything still running).',
    'Save it by calling mcp__handoff__save with `title`, a few words saying what to pick up (as "Continue milestone 18 design rounds"), and `prompt`, the whole opening prompt.',
    'Then show Dan the saved prompt exactly as saved, and say he can ask for changes, each of which you save again the same way.',
    ...(notes.trim() ? [`Dan added: ${notes.trim()}`] : []),
  ].join('\n\n')

const isReading = (r: unknown): r is Reading => {
  const o = r as Record<string, unknown>
  return !!o && typeof o.number === 'number' && typeof o.kind === 'string' && (typeof o.error === 'string' || (typeof o.state === 'string' && typeof o.updatedAt === 'string'))
}

// A saved handoff read whole, or why it cannot be trusted: a damaged file, or one written for a
// different repository whose folder name happens to match (keyOf folds every odd character to _).
const parse = (text: string, repo: string): Saved | string => {
  let j: Partial<Saved>
  try {
    j = JSON.parse(text) as Partial<Saved>
  } catch (err) {
    return `not JSON (${String((err as Error).message ?? err)})`
  }
  if (j.v !== 1 || typeof j.savedAt !== 'number' || typeof j.title !== 'string' || typeof j.prompt !== 'string' || !Array.isArray(j.baseline) || !j.baseline.every(isReading)) return 'not a handoff this mod wrote'
  if (j.repo !== repo) return `written for ${String(j.repo)}, not ${repo}`
  return j as Saved
}

const firstLine = (s: string) => s.trim().split('\n')[0] ?? ''

// Where this session's handoff lives: the repository's main working tree, so every worktree of it
// shares one; the session's own folder when it is not in a repository.
const place = async ($: EngineInterface) => {
  const home = await $.env.get('HOME')
  if (!home) throw new Error('HOME is not set')
  const repo = await $.session.repo().catch(() => null)
  const root = repo?.root ?? (await $.session.root())
  const key = keyOf(root)
  const dir = `${home}/.claude/state/handoff/${key}`
  return { root, key, dir, current: `${dir}/current.json` }
}

const run = async ($: EngineInterface, argv: string[], cwd?: string) => $.process.run(argv, { cwd, timeoutMs: 20_000 })

// Each name as GitHub has it now, all at once; a failure is a reading of its own, never dropped.
const readAll = async ($: EngineInterface, root: string, names: readonly Name[]): Promise<Reading[]> =>
  Promise.all(
    names.map(async (n): Promise<Reading> => {
      const path = n.kind === 'milestone' ? `repos/{owner}/{repo}/milestones/${n.number}` : `repos/{owner}/{repo}/issues/${n.number}`
      try {
        const r = await run($, ['gh', 'api', path], root)
        if (r.exitCode !== 0) return { ...n, error: firstLine(r.stderr) || `gh exited ${r.exitCode}` }
        return readingOf(n, JSON.parse(r.stdout))
      } catch (err) {
        return { ...n, error: firstLine(String((err as Error).message ?? err)) || 'gh could not be run' }
      }
    }),
  )

// Moves the current handoff into the archive: the one step that claims it, so of two sessions
// pressing at once exactly one move succeeds (assume it runs twice). Says where it went, or why not.
const archive = async ($: EngineInterface, dir: string, reason: 'used' | 'dismissed' | 'replaced'): Promise<{ to: string } | { error: string }> => {
  await run($, ['mkdir', '-p', `${dir}/archive`])
  const to = `${dir}/archive/${await $.clock.now()}-${reason}.json`
  const mv = await run($, ['mv', `${dir}/current.json`, to])
  return mv.exitCode === 0 ? { to } : { error: firstLine(mv.stderr) || `mv exited ${mv.exitCode}` }
}

// Puts a claimed handoff back as the saved one, but never over a handoff saved since: that one is
// newer, and the claimed one stays in the archive. True when it went back.
const restore = async ($: EngineInterface, from: string, current: string): Promise<boolean> => {
  if (await $.fs.exists(current)) return false
  const mv = await run($, ['mv', '-n', from, current])
  return mv.exitCode === 0 && !(await $.fs.exists(from))
}

const clearBand = async ($: EngineInterface) => {
  await $.state.set(shownRef, null)
  await $.modkit.clearBandRow({ mod: MOD, id: 'handoff' })
}

// The band at session start: the saved handoff with what changed since, once GitHub has answered.
const offer = async ($: EngineInterface) => {
  const p = await place($)
  if (!(await $.fs.exists(p.current))) return
  const read = await $.fs.read(p.current).then(
    t => parse(t, p.root),
    err => `unreadable (${String((err as Error).message ?? err)})`,
  )
  if (typeof read === 'string') {
    $.ui.log(`The saved handoff could not be read (${p.current}): ${read}.`)
    return
  }
  const now = await readAll($, p.root, namesIn(`${read.title}\n${read.prompt}`))
  const lines = bandLines({ age: ageOf((await $.clock.now()) - read.savedAt), title: read.title, changes: changesOf(read.baseline, now) })
  await $.modkit.bandRow({ mod: MOD, id: 'handoff', slot: 'handoff', lines } as never)
  await $.state.set(shownRef, { key: p.key, savedAt: read.savedAt } satisfies HandoffShown)
}

const message = (err: unknown) => String((err as Error)?.message ?? err)

// Use and Dismiss each claim the handoff on the band by moving it into the archive. A claim that
// finds nothing (another session took it) or a different handoff (one saved since replaced it)
// acts on nothing and says so; the replacement is put back and shown instead.
const claim = async ($: EngineInterface, reason: 'used' | 'dismissed'): Promise<{ rec: Saved; back: () => Promise<boolean> } | undefined> => {
  const shown = (await $.state.get(shownRef)).value
  if (!shown) return undefined
  const p = await place($)
  const moved = await archive($, p.dir, reason)
  if ('error' in moved) {
    $.ui.toast('This handoff was already used or dismissed in another session.')
    await clearBand($)
    return undefined
  }
  const taken = moved.to
  const back = async () => restore($, taken, p.current)
  const rec = await $.fs.read(taken).then(
    t => parse(t, p.root),
    err => `unreadable (${message(err)})`,
  )
  if (typeof rec === 'string' || rec.savedAt !== shown.savedAt) {
    await back()
    await clearBand($)
    await offer($)
    if (typeof rec !== 'string') $.ui.toast('The handoff was replaced since this session started; the band now shows the new one.')
    return undefined
  }
  return { rec, back }
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({ name: 'handoff', description: "Writes the next session's opening prompt for this project.", argumentHint: '[notes]' })
    await $.tool.register({
      name: 'save',
      description: "Saves the next session's opening prompt for this repository. Only after Dan runs /handoff.",
      inputSchema: {
        type: 'object',
        properties: {
          title: { type: 'string', description: 'A few words on what to pick up, e.g. "Continue milestone 18 design rounds".' },
          prompt: { type: 'string', description: 'The whole opening prompt, as Dan would type it.' },
        },
        required: ['title', 'prompt'],
      },
    })
    // A session with no one at the prompt has no band: it reads nothing and offers nothing.
    if (e.isInteractive) {
      $.clock.after(0, () =>
        void offer($).catch(err => $.ui.log(`The saved handoff could not be offered: ${message(err)}.`)),
      )
    }
    return next(e)
  })

  on('command.run', { command: 'handoff' }, async ($, e) => {
    await $.state.set(armedRef, true)
    // Submitted once the command has finished: from inside command.run the prompt would wait on the
    // turn this hook holds, and the engine refuses it.
    $.clock.after(0, () => void $.prompt.submit({ text: WRITE(e.args) }).catch(err => $.ui.toast(`/handoff could not ask for the handoff: ${message(err)}`)))
    return {}
  })

  on('tool.call', { tool: 'mcp__handoff__save' }, async ($, e) => {
    if (!(await $.state.get(armedRef)).value) return { deny: 'A handoff is written only when Dan runs /handoff.' }
    const input = e as unknown as { title?: unknown; prompt?: unknown }
    const title = typeof input.title === 'string' ? input.title.trim() : ''
    const prompt = typeof input.prompt === 'string' ? input.prompt.trim() : ''
    if (!title || !prompt) return { deny: 'The handoff needs a title of a few words and the whole opening prompt.' }
    const p = await place($)
    const record: Saved = { v: 1, repo: p.root, savedAt: await $.clock.now(), title, prompt, baseline: await readAll($, p.root, namesIn(`${title}\n${prompt}`)) }
    // Written whole beside it, then moved into place; the one it replaces is archived first.
    const tmp = `${p.dir}/.current.json.tmp`
    await $.fs.write(tmp, JSON.stringify(record))
    if (await $.fs.exists(p.current)) {
      const old = await archive($, p.dir, 'replaced')
      // Never written over: a handoff that cannot be archived keeps its place, and this save fails.
      if ('error' in old) return { deny: `The handoff could not be saved: the one it replaces could not be archived (${old.error})` }
    }
    const mv = await run($, ['mv', tmp, p.current])
    if (mv.exitCode !== 0) return { deny: `The handoff could not be saved: ${firstLine(mv.stderr) || `mv exited ${mv.exitCode}`}` }
    // A band showing the handoff this one replaced would offer a handoff that is no longer saved.
    if ((await $.state.get(shownRef)).value) await clearBand($)
    return { result: `Saved. The next session started in this repository offers it above the prompt.\n\n${prompt}` }
  })

  on('ui.press', { plugin: 'mod-kit', element: 'handoff:use' }, async ($, e) => {
    const got = await claim($, 'used')
    if (!got) return { element: e.element }
    try {
      await $.prompt.submit({ text: got.rec.prompt, asUser: true })
    } catch (err) {
      // Not sent, so not used: it goes back to being the saved handoff, still on the band, unless a
      // newer one was saved meanwhile, which it must not overwrite.
      if (await got.back()) $.ui.toast(`Use did not send the handoff: ${message(err)}`)
      else {
        $.ui.toast(`Use did not send the handoff: ${message(err)}. A newer one was saved meanwhile, so this one stays in the archive.`)
        await clearBand($)
      }
      return { element: e.element }
    }
    await clearBand($)
    return { element: e.element }
  })

  on('ui.press', { plugin: 'mod-kit', element: 'handoff:dismiss' }, async ($, e) => {
    if (await claim($, 'dismissed')) await clearBand($)
    return { element: e.element }
  })
}
