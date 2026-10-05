import type { EngineInterface, Register } from 'claude-code'
import { editedUnder, insideRoot, latestRequest, othersEditing, othersInRepo, parseVerdict, shellWrites, watchedGit, type Rec, type ShellWrite, type Verdict } from './collide.ts'

// Collision guard (claude-config#605): two sessions in one checkout must not edit the same file or
// move the tree under each other. Who is open comes from the shared session registry; the verdict
// from Sonnet, which Dan chose over Haiku. Decisions settled with Dan on 2026-10-03 are on the
// issue: a Proceed is a toast, Worktree and Stop are the grey card, the other session hears by a
// message and a toast, and anything that cannot be judged or read is Stop.

const GUARD = 'Collision guard'
const MODEL = 'claude-sonnet-5-5'
const JUDGE_MS = 60_000
const WRITERS = new Set(['Edit', 'Write', 'MultiEdit', 'NotebookEdit'])
const SAFE = {
  Worktree: 'Move this work to its own worktree and redo it there.',
  Stop: 'Leave it to the other session, or ask Dan.',
} as const

const base = (p: string) => p.split('/').pop() ?? p
const relTo = (p: string, root: string | null) => (root && p.startsWith(root + '/') ? p.slice(root.length + 1) : p)

const run = async ($: EngineInterface, argv: string[]): Promise<string | undefined> => {
  try {
    const r = await $.process.run(argv, { timeoutMs: 10_000 })
    return r.exitCode === 0 ? r.stdout : undefined
  } catch {
    return undefined
  }
}

type Clash = {
  // What this session is about to do, as the judge and the message read it.
  action: string
  // How the card and the toasts name it: a file's name, or "this checkout".
  shortName: string
  // How the message to the other session names it.
  messageWhat: string
  where: 'file' | 'checkout'
  root: string | null
  others: Rec[]
}

const judge = async ($: EngineInterface, c: Clash): Promise<Verdict | undefined> => {
  const lines: string[] = []
  for (const o of c.others) {
    // Three different absences, said apart so the judge knows how much it is missing (L11).
    let request: string
    if (!o.transcriptPath) request = '(its transcript could not be found)'
    else {
      const tail = await run($, ['tail', '-c', '262144', o.transcriptPath])
      request = tail === undefined ? '(its transcript could not be read)' : (latestRequest(tail) ?? '(none in its transcript)')
    }
    lines.push(
      `Other session ${o.sessionId}, working in ${o.cwd}.`,
      `Its latest request: ${request}`,
      `Files it has edited, newest last: ${o.edits.slice(-20).join(', ') || '(none)'}`,
    )
  }
  const root = c.root
  const status = root ? await run($, ['git', '-C', root, 'status', '--short']) : undefined
  const branch = root ? await run($, ['git', '-C', root, 'branch', '--show-current']) : undefined
  const prompt = [
    'Two Claude Code sessions are working in the same git checkout. One is about to do something that may collide with the other.',
    `The action: ${c.action}`,
    ...lines,
    `The checkout: ${root ?? '(unknown)'}, on branch ${branch?.trim() || '(unknown)'}, with changes:\n${status?.trim() || '(none, or could not be read)'}`,
    'Answer with JSON only: {"verdict": "Proceed" | "Worktree" | "Stop", "reason": "<one short sentence>"}.',
    'Proceed when the two cannot interfere. Worktree when the action is fine but must happen in its own worktree. Stop when it must not happen now.',
  ].join('\n')
  const stop = new AbortController()
  $.clock.after(JUDGE_MS, () => stop.abort())
  try {
    const r = await $.model.complete({ model: MODEL, prompt, maxTokens: 300 }, { signal: stop.signal })
    return r.isAnswered ? parseVerdict(r.text) : undefined
  } catch {
    return undefined
  }
}

const refuse = async ($: EngineInterface, toolUseId: string, reason: string, safeWay: string, note?: string) => {
  await $.modkit.blocked({ toolUseId, guard: GUARD, reason, safeWay, ...(note ? { note } : {}) })
  return { deny: `Blocked: ${reason} ${safeWay}${note ? ` ${note}` : ''}` }
}

// Checked, judged and acted on. undefined means go ahead.
const decide = async ($: EngineInterface, toolUseId: string, c: Clash) => {
  const v = await judge($, c)
  if (!v) return refuse($, toolUseId, "Couldn't check with the other session's work, so this was stopped.", 'Try again, or ask Dan.')
  if (v.verdict === 'Proceed') {
    await $.ui.toast(c.where === 'file' ? `Checked with the other session: safe to edit ${c.shortName}.` : `Checked with the other session: safe to run ${c.action}.`)
    return undefined
  }
  const outcome = v.verdict === 'Worktree' ? 'it was moved to its own worktree to redo its change there' : 'it was stopped'
  const message =
    c.where === 'file'
      ? `Another session wanted to edit ${c.messageWhat} while you are working on it, so ${outcome}. Nothing here was touched.`
      : `Another session wanted to run ${c.messageWhat} in this checkout while you are working in it, so ${outcome}. Nothing here was touched.`
  // The block stands whether or not the other session hears of it; one that cannot is said so.
  // mod-kit tries a refused send once more (its hooks/send.ts), so a refusal here is the second.
  const unheard: string[] = []
  for (const o of c.others) {
    const sent = await $.session.send({ to: { sessionId: o.sessionId }, text: message })
    if (!sent.isDelivered) unheard.push(sent.reason)
  }
  const note = !unheard.length
    ? undefined
    : c.others.length === 1
      ? `The other session could not be told: ${unheard[0]}.`
      : `${unheard.length} of the other sessions could not be told: ${unheard.join('; ')}.`
  const reason = c.where === 'file' ? `Another session is working on ${c.shortName}. ${v.reason}` : `Another session is working in this checkout. ${v.reason}`
  return refuse($, toolUseId, reason, SAFE[v.verdict], note)
}

// The files a Bash call writes, as far as its words name them (collide.ts, shellWrites). A cp or mv
// onto one existing folder lands inside it; a path the disk cannot answer for is taken as the file
// itself, the reading that still judges a clash on that name.
const writtenFiles = async ($: EngineInterface, cmds: string[][]): Promise<ShellWrite[]> => {
  const cwd = await $.session.cwd()
  const home = await $.env.get('HOME').catch(() => undefined)
  const out: ShellWrite[] = []
  for (const w of shellWrites(cmds, cwd, home)) {
    let isDir = false
    if (w.sources) isDir = (await $.fs.stat(w.path).catch(() => undefined))?.kind === 'dir'
    const { sources, ...write } = w
    const found = isDir && sources ? sources.map(s => ({ path: `${w.path}/${base(s)}` })) : [write]
    // A file named twice is kept once, keeping a removal's flags whichever came first, as
    // shellWrites does (lessons review of #691).
    for (const f of found) {
      const had = out.find(o => o.path === f.path)
      if (!had) out.push(f)
      else Object.assign(had, f.removes ? { removes: true } : {}, f.tree ? { tree: true } : {})
    }
  }
  return out
}

// The folder a session's edits are recorded within (#674): its repository, or its own folder when
// it works outside one. Scratch (/tmp, the scratchpad) lies outside it, and recording it would push
// real edits out of the twenty the judge reads and raise checks between sessions sharing scratch.
// This session's record says; before the registry has written one, git is asked, then the folder.
const recordRoot = async ($: EngineInterface, list: { open: Rec[]; selfId: string | null }): Promise<string> => {
  const me = list.open.find(r => r.sessionId === list.selfId)
  if (me) return me.repoRoot ?? me.cwd
  const cwd = await $.session.cwd()
  return (await run($, ['git', '-C', cwd, 'rev-parse', '--show-toplevel']))?.trim() || cwd
}

const unreadableRefusal =($: EngineInterface, toolUseId: string, names: string[]) =>
  refuse($, toolUseId, `Couldn't read another session's record (${names.join(', ')}), so this was stopped.`, 'Delete the damaged file in ~/.claude/state/sessions, or ask Dan.')

export const register: Register = on => {
  on('tool.call', async ($, e, next) => {
    const input = e as unknown as Record<string, unknown>
    const toolUseId = String(input.tool_use_id ?? '')

    if (WRITERS.has(String(e.tool))) {
      const path = String(input.file_path ?? input.notebook_path ?? '')
      if (!path) return next(e)
      const list = await $.sessions.list()
      if (list.unreadable.length) return unreadableRefusal($, toolUseId, list.unreadable)
      const others = othersEditing(list.open, list.selfId, path)
      if (others.length) {
        const root = others[0]?.repoRoot ?? null
        const blocked = await decide($, toolUseId, { action: `edit ${path}`, shortName: base(path), messageWhat: relTo(path, root), where: 'file', root, others })
        if (blocked) return blocked
      }
      const result = await next(e)
      if (!result.deny && !result.isError && insideRoot(path, await recordRoot($, list))) await $.sessions.noteEdit({ path })
      return result
    }

    if (e.tool === 'Bash') {
      const command = String(input.command ?? '')
      const cmds = await $.modkit.commands({ command })
      for (const words of cmds) {
        const g = await $.modkit.git({ words })
        const action = g ? watchedGit(g) : undefined
        if (!g || !action) continue
        const dir = g.dir ?? (await $.session.cwd())
        const root = (await run($, ['git', '-C', dir, 'rev-parse', '--show-toplevel']))?.trim() || null
        const list = await $.sessions.list()
        if (list.unreadable.length) return unreadableRefusal($, toolUseId, list.unreadable)
        const others = othersInRepo(list.open, list.selfId, root)
        if (!others.length) continue
        const blocked = await decide($, toolUseId, { action, shortName: action, messageWhat: action, where: 'checkout', root, others })
        if (blocked) return blocked
      }

      // The files the command writes (#654), judged against the other sessions' edits the same way
      // an Edit is, and noted as this session's own once it has run. An rm is judged the same way
      // (#674), and an rm -r on every file another session edited inside the folder it takes away.
      const written = await writtenFiles($, cmds)
      if (!written.length) return next(e)
      const list = await $.sessions.list()
      if (list.unreadable.length) return unreadableRefusal($, toolUseId, list.unreadable)
      for (const w of written) {
        for (const path of w.tree ? editedUnder(list.open, list.selfId, w.path) : [w.path]) {
          const others = othersEditing(list.open, list.selfId, path)
          if (!others.length) continue
          const root = others[0]?.repoRoot ?? null
          const what = !w.removes ? `write ${path}` : path === w.path ? `remove ${path}` : `remove ${path} (inside ${w.path})`
          const blocked = await decide($, toolUseId, {
            action: `${what} with the shell command: ${command}`,
            shortName: base(path),
            messageWhat: relTo(path, root),
            where: 'file',
            root,
            others,
          })
          if (blocked) return blocked
        }
      }
      const result = await next(e)
      // A command that failed may still have written before it failed (printf >> f; false), so only
      // a refusal leaves the record alone. Scratch outside the session's root is never recorded.
      if (!result.deny) {
        const root = await recordRoot($, list)
        for (const w of written) if (insideRoot(w.path, root)) await $.sessions.noteEdit({ path: w.path })
      }
      return result
    }
    return next(e)
  })

  // The session that was working first: the message reached its conversation (the standard incoming
  // message, collision round 1), and Dan gets a toast.
  on('session.receive', async ($, e, next) => {
    // Settled by the live check of #639 (2026-10-04): a delivered message carries the sending plugin
    // as `plugin`, while `name` is the sending session's own name, which any session can be given.
    const origin = e.origin as { kind?: string; plugin?: string }
    if (origin.plugin === 'collision-guard' && e.text.startsWith('Another session wanted')) {
      const outcome = /moved to its own worktree/.test(e.text) ? 'it was moved to a worktree' : 'it was stopped'
      const file = /wanted to edit (\S+) while/.exec(e.text)?.[1]
      const action = /wanted to run (.+?) in this checkout/.exec(e.text)?.[1]
      await $.ui.toast(`Another session wanted ${file ? base(file) : (action ?? 'your files')}; ${outcome}.`)
    }
    return next(e)
  })
}
