import type { EngineInterface, Register } from 'claude-code'
import { latestRequest, othersEditing, othersInRepo, parseVerdict, watchedGit, type Rec, type Verdict } from './collide.ts'

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
    const tail = o.transcriptPath ? await run($, ['tail', '-c', '262144', o.transcriptPath]) : undefined
    const request = tail === undefined ? undefined : latestRequest(tail)
    lines.push(
      `Other session ${o.sessionId}, working in ${o.cwd}.`,
      `Its latest request: ${request ?? '(could not be read)'}`,
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

const refuse = async ($: EngineInterface, toolUseId: string, reason: string, safeWay: string) => {
  await $.modkit.blocked({ toolUseId, guard: GUARD, reason, safeWay })
  return { deny: `Blocked: ${reason} ${safeWay}` }
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
  for (const o of c.others) {
    try {
      await $.session.send({ to: { sessionId: o.sessionId }, text: message })
    } catch {
      // A session that ended since the list was read cannot be told; the block stands regardless.
    }
  }
  const reason = c.where === 'file' ? `Another session is working on ${c.shortName}. ${v.reason}` : `Another session is working in this checkout. ${v.reason}`
  return refuse($, toolUseId, reason, SAFE[v.verdict])
}

const unreadableRefusal = ($: EngineInterface, toolUseId: string, names: string[]) =>
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
      if (!result.deny && !result.isError) await $.sessions.noteEdit({ path })
      return result
    }

    if (e.tool === 'Bash') {
      for (const words of await $.modkit.commands({ command: String(input.command ?? '') })) {
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
    }
    return next(e)
  })

  // The session that was working first: the message reached its conversation (the standard incoming
  // message, collision round 1), and Dan gets a toast.
  on('session.receive', async ($, e, next) => {
    // The send side is stamped { kind: 'plugin', name }; a receiving session may carry the plugin as
    // `plugin`. Either names this guard (lessons review of #632; the live check settles which).
    const origin = e.origin as { kind?: string; plugin?: string; name?: string }
    if ((origin.plugin === 'collision-guard' || origin.name === 'collision-guard') && e.text.startsWith('Another session wanted')) {
      const outcome = /moved to its own worktree/.test(e.text) ? 'it was moved to a worktree' : 'it was stopped'
      const file = /wanted to edit (\S+) while/.exec(e.text)?.[1]
      const action = /wanted to run (.+?) in this checkout/.exec(e.text)?.[1]
      await $.ui.toast(`Another session wanted ${file ? base(file) : (action ?? 'your files')}; ${outcome}.`)
    }
    return next(e)
  })
}
