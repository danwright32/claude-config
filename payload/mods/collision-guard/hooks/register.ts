import type { EngineInterface, Register } from 'claude-code'
import { editedUnder, insideRoot, isScratch, judgedWrites, latestRequest, othersEditing, othersInRepo, parseVerdict, quoteNames, wantedFiles, watchedGit, type Rec, type ShellWrite, type Verdict } from './collide.ts'

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
  // How the message to the other session names it; per session when each has its own files at
  // stake, as in a folder removal (#674).
  messageWhat: string | ((o: Rec) => string)
  // What it does, as the toast and the message say it: edit or remove a file (a removal says so,
  // Dan, 2026-10-04, #700), or run a checkout wide git command.
  doing: 'edit' | 'remove' | 'run'
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
    await $.ui.toast(c.doing === 'run' ? `Checked with the other session: safe to run ${c.action}.` : `Checked with the other session: safe to ${c.doing} ${c.shortName}.`)
    return undefined
  }
  const outcome = v.verdict === 'Worktree' ? 'it was moved to its own worktree to redo its change there' : 'it was stopped'
  const message = (o: Rec) => {
    const what = typeof c.messageWhat === 'string' ? c.messageWhat : c.messageWhat(o)
    return c.doing === 'run'
      ? `Another session wanted to run ${what} in this checkout while you are working in it, so ${outcome}. Nothing here was touched.`
      : `Another session wanted to ${c.doing} ${what} while you are working on it, so ${outcome}. Nothing here was touched.`
  }
  // The block stands whether or not the other session hears of it; one that cannot is said so.
  // mod-kit tries a refused send once more (its hooks/send.ts), so a refusal here is the second.
  const unheard: string[] = []
  for (const o of c.others) {
    const sent = await $.session.send({ to: { sessionId: o.sessionId }, text: message(o) })
    if (!sent.isDelivered) unheard.push(sent.reason)
  }
  const note = !unheard.length
    ? undefined
    : c.others.length === 1
      ? `The other session could not be told: ${unheard[0]}.`
      : `${unheard.length} of the other sessions could not be told: ${unheard.join('; ')}.`
  const reason = c.doing === 'run' ? `Another session is working in this checkout. ${v.reason}` : `Another session is working on ${c.shortName}. ${v.reason}`
  return refuse($, toolUseId, reason, SAFE[v.verdict], note)
}

// The files a Bash call writes, as far as its words name them, read by mod-kit's one write reader
// (#712) and judged as collide.ts's judgedWrites says. A cp or mv onto one existing folder lands
// inside it; a path the disk cannot answer for is taken as the file itself, the reading that still
// judges a clash on that name.
const writtenFiles = async ($: EngineInterface, command: string): Promise<ShellWrite[]> => {
  const cwd = await $.session.cwd()
  const home = (await $.env.get('HOME').catch(() => undefined)) ?? ''
  const out: ShellWrite[] = []
  for (const w of judgedWrites(await $.modkit.writes({ command, cwd, home }))) {
    let isDir = false
    if (w.sources) isDir = (await $.fs.stat(w.path).catch(() => undefined))?.kind === 'dir'
    const { sources, ...write } = w
    const found: ShellWrite[] = isDir && sources ? sources.map(s => ({ path: `${w.path}/${base(s)}` })) : [write]
    // The folder copied into is also removed later in the command (cp a x; rm -r x): the files
    // landing inside it do not stand for that removal, so it is kept too (#700).
    if (isDir && sources && write.removes) found.push(write)
    // A file named twice is kept once, keeping a removal's flags whichever came first, as
    // judgedWrites does (lessons review of #691).
    for (const f of found) {
      const had = out.find(o => o.path === f.path)
      if (!had) out.push(f)
      else Object.assign(had, f.removes ? { removes: true } : {}, f.tree ? { tree: true } : {})
    }
  }
  return out
}

// The session's own root (#674): its repository, or its own folder when it works outside one. This
// session's record says; before the registry has written one, git is asked, then the folder.
const recordRoot = async ($: EngineInterface, list: { open: Rec[]; selfId: string | null }): Promise<string> => {
  const me = list.open.find(r => r.sessionId === list.selfId)
  if (me) return me.repoRoot ?? me.cwd
  const cwd = await $.session.cwd()
  return (await run($, ['git', '-C', cwd, 'rev-parse', '--show-toplevel']))?.trim() || cwd
}

// Which paths this session wrote are recorded as its edits. Anything inside its own root, and
// anything inside another git working tree (Dan, 2026-10-04, #700), so a session working in that
// checkout is judged against it. Scratch outside its root is never recorded (#674): it would push
// real edits out of the twenty the judge reads and raise checks between sessions sharing scratch.
// Nor is a path in no checkout at all. The working tree is found on the disk by its .git entry,
// never by running git per path, through mod-kit's one walk for it ($.modkit.workingTree, #712);
// nothing is kept between calls, so a checkout cloned during the session counts at once. A path
// whose checkout the disk cannot say (a folder it cannot read, or one deeper than the walk goes) is
// recorded: noting it costs at most a judgment that comes back Proceed, where leaving it out would
// hide a real clash from the other session (mod-kit refuses rather than guessing, lessons review of
// #731; this guard had taken a failed look for no checkout).
const recorder = async ($: EngineInterface, list: { open: Rec[]; selfId: string | null }) => {
  const root = await recordRoot($, list)
  const tmpdir = await $.env.get('TMPDIR').catch(() => undefined)
  const inCheckout = (path: string): Promise<boolean> =>
    $.modkit.workingTree({ path }).then(
      tree => tree !== null,
      () => true,
    )
  return async (path: string): Promise<boolean> => insideRoot(path, root) || (!isScratch(path, tmpdir) && (await inCheckout(path)))
}

const unreadableRefusal =($: EngineInterface, toolUseId: string, names: string[]) =>
  refuse($, toolUseId, `Couldn't read another session's record (${names.join(', ')}), so this was stopped.`, 'Delete the damaged file in ~/.claude/state/sessions, or ask Dan.')

// What a call the guard let through notes as this session's edits once it has run: the registry as
// it was judged against, and the paths. `strict` notes them only when the call ran without error
// (an Edit that failed wrote nothing); a shell command that failed may have written first.
type ToNote = { list: { open: Rec[]; selfId: string | null }; paths: string[]; strict: boolean }

const watches = (tool: string) => WRITERS.has(tool) || tool === 'Bash'

// Judges one call against the other sessions: the refusal, what to note once it runs, or undefined
// when it writes nothing worth noting.
const check = async ($: EngineInterface, input: Record<string, unknown>): Promise<{ deny: string } | ToNote | undefined> => {
  const toolUseId = String(input.tool_use_id ?? '')
  if (WRITERS.has(String(input.tool))) {
    const path = String(input.file_path ?? input.notebook_path ?? '')
    if (!path) return undefined
    const list = await $.sessions.list()
    if (list.unreadable.length) return unreadableRefusal($, toolUseId, list.unreadable)
    const others = othersEditing(list.open, list.selfId, path)
    if (others.length) {
      const root = others[0]?.repoRoot ?? null
      const blocked = await decide($, toolUseId, { action: `edit ${path}`, shortName: base(path), messageWhat: quoteNames([relTo(path, root)]), doing: 'edit', root, others })
      if (blocked) return blocked
    }
    return { list, paths: [path], strict: true }
  }

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
    const blocked = await decide($, toolUseId, { action, shortName: action, messageWhat: action, doing: 'run', root, others })
    if (blocked) return blocked
  }

  // The files the command writes (#654), judged against the other sessions' edits the same way an
  // Edit is, and noted as this session's own once it has run. An rm is judged the same way (#674),
  // and an rm -r or mv of a folder once, on every file another session edited inside it: one
  // judgment, one card or toast, and one message to each session naming its own files.
  const written = await writtenFiles($, command)
  if (!written.length) return undefined
  const list = await $.sessions.list()
  if (list.unreadable.length) return unreadableRefusal($, toolUseId, list.unreadable)
  for (const w of written) {
    const files = w.tree ? editedUnder(list.open, list.selfId, w.path) : [w.path]
    const others = [...new Set(files.flatMap(p => othersEditing(list.open, list.selfId, p)))]
    if (!others.length) continue
    const root = others[0]?.repoRoot ?? null
    const one = files.length === 1 ? (files[0] as string) : undefined
    const what = !w.removes ? `write ${w.path}` : one === w.path ? `remove ${w.path}` : `remove ${w.path} and everything in it, including ${files.join(', ')},`
    const blocked = await decide($, toolUseId, {
      action: `${what} with the shell command: ${command}`,
      shortName: one ? base(one) : `${files.length} files in ${base(w.path)}`,
      messageWhat: one ? quoteNames([relTo(one, root)]) : o => quoteNames(files.filter(p => o.edits.includes(p)).map(p => relTo(p, root))),
      doing: w.removes ? 'remove' : 'edit',
      root,
      others,
    })
    if (blocked) return blocked
  }
  return { list, paths: written.map(w => w.path), strict: false }
}

// Handed from the tool.check hook that let a call through to the tool.call hook around it,
// by the call's id, so only a call this guard judged and let through is noted.
const toNote = new Map<string, ToNote>()
// Whether Claude was told a note could not be written, since the last one that landed (#751).
let toldUnnoted = false
// The one spelling of that key, for the side that stores a plan and the side that reads it back
// (#732): two spellings would part on a call with no id and the edit would never be noted.
const planKey = (e: unknown) => String((e as { tool_use_id?: unknown }).tool_use_id ?? '')

export const register: Register = on => {
  // Judged at tool.check (#875), which the engine raises inside tool.call once every mod's tool.call
  // hook and the settings PreToolUse hooks have passed the call on (#707): a call no build, winding
  // down, the secret guard, the style check or a settings hook refuses is refused before Sonnet is
  // asked, another session is told or a toast says safe, whichever order the mods load in, and
  // next(e) here runs only the verdict beneath, never the tool. It was classic.PreToolUse, which
  // never ran: Claude Code's built-in security default sends every classic event past the user tier
  // this mod loads in, for a Team or Enterprise organization (a headless debug run, 2026-10-06).
  on('tool.check', async ($, e, next) => {
    const decided = await next(e)
    if (decided.decision === 'deny' || !watches(e.tool)) return decided
    // A query ($.tool.check) carries no call id and runs nothing: no session is asked or told about
    // an edit that is only being looked at, and the real call is judged when it is made.
    if (e.tool_use_id === undefined) return decided
    const input: Record<string, unknown> = { ...((e.input ?? {}) as Record<string, unknown>), tool: e.tool, tool_use_id: e.tool_use_id }
    const c = await check($, input)
    if (c && 'deny' in c) return { decision: 'deny', reason: c.deny }
    // Keyed by the call's id, which the engine gives every call, one raised without any included,
    // and which no mod above can strip (measured 2026-10-04, and tested), so two calls never share
    // a plan.
    if (c) toNote.set(planKey(e), c)
    return decided
  })

  on('tool.call', async ($, e, next) => {
    if (!watches(String(e.tool))) return next(e)
    const id = planKey(e)
    let result: Awaited<ReturnType<typeof next>>
    let plan: ToNote | undefined
    try {
      result = await next(e)
    } finally {
      plan = toNote.get(id)
      toNote.delete(id)
    }
    // A refusal leaves the record alone, whoever made it. A shell command that failed may still
    // have written before it failed (printf >> f; false), so only an Edit's failure does too.
    if (!plan || result.deny !== undefined || (plan.strict && result.isError)) return result
    // The tool has already run, so a note that cannot be written never fails the call (#751): Claude
    // is told once, until a note lands, as the job watcher's publishSafely does.
    let unnoted: string | undefined
    try {
      const recorded = await recorder($, plan.list)
      for (const path of plan.paths) {
        if (!(await recorded(path))) continue
        try {
          await $.sessions.noteEdit({ path })
        } catch (err) {
          unnoted ??= `The collision guard could not record that this session edited ${path}: ${err instanceof Error ? err.message : String(err)}. Other sessions will not be warned before they change it.`
        }
      }
    } catch (err) {
      unnoted ??= `The collision guard could not record this session's edits: ${err instanceof Error ? err.message : String(err)}. Other sessions will not be warned before they change them.`
    }
    // Rearmed only by a call whose every note landed: one that lands beside one that fails is the
    // same trouble, and said once (lessons review of PR 794).
    if (unnoted === undefined) {
      toldUnnoted = false
      return result
    }
    if (toldUnnoted || result.isError) return result
    toldUnnoted = true
    return { ...result, context: [...(result.context ?? []), unnoted] }
  })

  // The session that was working first: the message reached its conversation (the standard incoming
  // message, collision round 1), and Dan gets a toast.
  on('session.receive', async ($, e, next) => {
    // Settled by the live check of #639 (2026-10-04): a delivered message carries the sending plugin
    // as `plugin`, while `name` is the sending session's own name, which any session can be given.
    const origin = e.origin as { kind?: string; plugin?: string }
    if (origin.plugin === 'collision-guard' && e.text.startsWith('Another session wanted')) {
      const outcome = /moved to its own worktree/.test(e.text) ? 'it was moved to a worktree' : 'it was stopped'
      // The message is plain text, the only thing a send carries, so the files are read back out of
      // it as the sender quoted them (collide.ts, wantedFiles), each name whole (#700). A folder
      // removal names several (#674), and a removal says so (#700). In the toast a name holding a
      // comma is quoted, so the list still reads as the files it is.
      const wanted = wantedFiles(e.text)
      const action = /wanted to run (.+?) in this checkout/.exec(e.text)?.[1]
      const names = wanted?.names.map(base).map(n => (n.includes(',') ? `"${n}"` : n)).join(', ')
      const what = wanted ? `${wanted.verb === 'remove' ? 'to remove ' : ''}${names}` : (action ?? 'your files')
      await $.ui.toast(`Another session wanted ${what}; ${outcome}.`)
    }
    return next(e)
  })
}
