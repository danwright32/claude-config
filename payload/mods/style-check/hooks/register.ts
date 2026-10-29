import type { EngineInterface, Register } from 'claude-code'
import { inputTexts } from './mod-kit/inputs.ts'

// Style check at write time (claude-config#609). One rule, not two: the verdict is always the push
// hook's own scanner, hooks/lib/style-scan.py, run on the text about to be written (L370, L613).
// Nothing here knows which characters are forbidden.

// The Slack tools that write text a teammate reads are named once, without their server, in
// hooks/lib/slack-write-tools.txt, which the session link gate reads too, so the two judge the same
// tools on every server: the claude.ai connector's and the Slack plugin's (claude-config#1905). Read
// for each MCP tool named slack_*, so an edit to the list counts at once. A list that cannot be read
// judges every slack_* tool rather than none: a Slack search with a dash in it is held for a look,
// which is the cheaper fault than a message to a teammate passing unchecked (L93).
const slackName = (tool: string): string | undefined => {
  const at = tool.lastIndexOf('__')
  const name = tool.slice(at + 2)
  return tool.startsWith('mcp__') && at > 'mcp_'.length && name.startsWith('slack_') ? name : undefined
}
const isSlackWrite = async ($: EngineInterface, tool: string): Promise<boolean> => {
  const name = slackName(tool)
  if (!name) return false
  const list = `${(await $.env.get('HOME')) ?? ''}/.claude/hooks/lib/slack-write-tools.txt`
  try {
    const names = (await $.fs.read(list)).split('\n').map(l => l.trim()).filter(l => l && !l.startsWith('#'))
    return names.includes(name)
  } catch (err) {
    $.ui.log(`style-check: could not read ${list}, so every Slack tool is judged: ${String(err).slice(0, 160)}`, { to: 'debug' })
    return true
  }
}
// Which commands carry a message is read from mod-kit's one shared reader ($.modkit.commands),
// never a pattern over the raw text (L613, L673): a git command whose subcommand is commit, after
// any global options (git -C <dir> commit), and gh issue or pr create, edit or comment.
const ghCarriesMessage = (words: string[]): boolean =>
  (words[0] ?? '').split('/').pop() === 'gh' && (words[1] === 'issue' || words[1] === 'pr') && ['create', 'edit', 'comment'].includes(words[2] ?? '')
// The files a message is read from: the word after -F, --file or --body-file, or joined with =.
const messageFiles = (words: string[]): string[] => {
  const out: string[] = []
  for (let i = 0; i < words.length; i++) {
    const w = words[i] as string
    const joined = /^(?:--body-file|--file)=(.+)$/.exec(w)
    if (joined) out.push(joined[1] as string)
    else if ((w === '-F' || w === '--file' || w === '--body-file') && words[i + 1] !== undefined) out.push(words[i + 1] as string)
  }
  return out.filter(f => f !== '-')
}

type Verdict = { kind: 'clean' } | { kind: 'hit'; lines: string } | { kind: 'unchecked'; why: string }

const scan = async ($: EngineInterface, text: string, path?: string): Promise<Verdict> => {
  // Every character the rule forbids lies outside ASCII, so plain ASCII is clean without starting a
  // process for it: most writes and replies (lessons review). The rule itself stays the scanner's.
  if (/^[\x00-\x7f]*$/.test(text)) return { kind: 'clean' }
  const home = await $.env.get('HOME')
  if (!home) return { kind: 'unchecked', why: 'HOME is not set, so the scanner could not be found' }
  const argv = ['python3', `${home}/.claude/hooks/lib/style-scan.py`, '--plain', ...(path ? ['--path', path] : [])]
  try {
    const r = await $.process.run(argv, { stdin: text, timeoutMs: 10_000 })
    if (r.exitCode === 0) return { kind: 'clean' }
    // A hit is exit 1 WITH lines: python itself failing also exits 1, with nothing on stdout and the
    // traceback on stderr, and that is a scanner that could not run (lessons review).
    if (r.exitCode === 1 && r.stdout.trim()) return { kind: 'hit', lines: r.stdout.trim() }
    return { kind: 'unchecked', why: `the scanner exited ${r.exitCode}: ${r.stderr.trim().slice(0, 160)}` }
  } catch (err) {
    return { kind: 'unchecked', why: `the scanner could not run: ${String(err).slice(0, 160)}` }
  }
}

const strings = (v: unknown, out: string[] = []): string[] => {
  if (typeof v === 'string') out.push(v)
  else if (Array.isArray(v)) for (const x of v) strings(x, out)
  else if (v && typeof v === 'object') for (const x of Object.values(v)) strings(x, out)
  return out
}

// What a tool call is about to write, and where: the text the rule applies to, never the text
// being replaced (an Edit's old_string is what is already there).
const outgoing = async ($: EngineInterface, tool: string, e: Record<string, unknown>): Promise<{ text: string; path?: string } | undefined> => {
  switch (tool) {
    case 'Write':
      return { text: String(e.content ?? ''), path: String(e.file_path ?? '') }
    case 'Edit':
      return { text: String(e.new_string ?? ''), path: String(e.file_path ?? '') }
    case 'MultiEdit': {
      const edits = Array.isArray(e.edits) ? (e.edits as { new_string?: unknown }[]) : []
      return { text: edits.map(x => String(x.new_string ?? '')).join('\n'), path: String(e.file_path ?? '') }
    }
    case 'NotebookEdit':
      return { text: String(e.new_source ?? ''), path: String(e.notebook_path ?? '') }
    case 'Bash': {
      const cmd = String(e.command ?? '')
      const msgs: string[][] = []
      for (const words of await $.modkit.commands({ command: cmd })) {
        if (ghCarriesMessage(words) || (await $.modkit.git({ words }))?.sub === 'commit') msgs.push(words)
      }
      if (msgs.length === 0) return undefined
      // The message as written in the command, plus any file it is read from. Quotes are already
      // gone, so a -F inside a quoted message is words, never a flag (lessons review). A message
      // file that is a device or a fifo (-F /dev/stdin) is never opened, since the read waits for
      // ever and the commit never runs (#1765): its text is the heredoc, which is in the command.
      const parts = [cmd]
      for (const f of msgs.flatMap(messageFiles)) {
        try {
          parts.push(...(await inputTexts({ exists: p => $.fs.exists(p), stat: (p, o) => $.fs.stat(p, o), read: p => $.fs.read(p) }, [f])))
        } catch {
          // A file that cannot be read is left to the command, which will fail on it itself.
        }
      }
      return { text: parts.join('\n') }
    }
    default:
      return (await isSlackWrite($, tool)) ? { text: strings(e).join('\n') } : undefined
  }
}

// Wording settled with Dan, 2026-10-03 (docs/mods-design.md).
const GUARD = 'Style check'
const FIX = 'Use a comma, colon or parentheses.'
const lineWords = (scannerOut: string): string => {
  const ns = [...scannerOut.matchAll(/^line (\d+):/gm)].map(m => m[1] as string)
  if (ns.length === 0) return ''
  if (ns.length === 1) return ` on line ${ns[0]}`
  return ` on lines ${ns.slice(0, -1).join(', ')} and ${ns[ns.length - 1]}`
}
// Replies counted this session; the total across sessions is in the mod's store. Replies the
// scanner could not check are counted apart, so a broken scanner never reads as clean writing.
// This session's counts are in $.state (#1703), which the engine holds for the session across a hot
// reload: a reload fires session.start again in a fresh module, and the counts kept here started
// again from nought while the session went on. Each is counted by version, retried, so two replies
// counted at once both land (assume it runs twice). A count that cannot be written is said with the
// count, never left to read as complete.
const COUNT_TRIES = 5
const countHit = async ($: EngineInterface) => {
  for (let i = 0; i < COUNT_TRIES; i++) {
    const held = await $.state.get({ plugin: 'style-check', key: 'hits' })
    if ((await $.state.set({ plugin: 'style-check', key: 'hits' }, (held.value ?? 0) + 1, { ifVersion: held.version })).isSet) return
  }
  throw new Error(`the count kept changing underneath ${COUNT_TRIES} writes in a row`)
}
const countUnchecked = async ($: EngineInterface) => {
  for (let i = 0; i < COUNT_TRIES; i++) {
    const held = await $.state.get({ plugin: 'style-check', key: 'unchecked' })
    if ((await $.state.set({ plugin: 'style-check', key: 'unchecked' }, (held.value ?? 0) + 1, { ifVersion: held.version })).isSet) return
  }
  throw new Error(`the count kept changing underneath ${COUNT_TRIES} writes in a row`)
}
// Whether a reply this session could not be counted: /style-count then says its count may be short.
// A session fact like the counts it qualifies, so kept in $.state with them (push review of PR for
// #1703); this module's own flag holds it too, for when that write fails as well.
let uncounted = false
const counting = async ($: EngineInterface, which: 'hits' | 'unchecked') => {
  try {
    if (which === 'hits') await countHit($)
    else await countUnchecked($)
  } catch (err) {
    uncounted = true
    $.ui.log(`style-check: could not count a reply for this session: ${err instanceof Error ? err.message : String(err)}`, { to: 'debug' })
    try {
      await $.state.set({ plugin: 'style-check', key: 'uncounted' }, true)
    } catch (again) {
      $.ui.log(`style-check: could not keep that this session's count may be short: ${again instanceof Error ? again.message : String(again)}`, { to: 'debug' })
    }
  }
}
// Said once in this module's life: a reload says it once more at most.
let noteSaid = false
let countChain: Promise<unknown> = Promise.resolve()
const UNCHECKED_NOTE = "Style check couldn't run, so this wasn't checked for dashes or emoji. The push check still will."
// Dan's note, once a session however many checks fail; each cause goes to the debug log.
const unchecked = ($: EngineInterface, why: string) => {
  if (!noteSaid) $.ui.log(UNCHECKED_NOTE)
  noteSaid = true
  $.ui.log(`style-check: ${why}`, { to: 'debug' })
}

export const register: Register = on => {
  // Fires once per process and again at every hot reload of the mod (never at /clear), so it leaves
  // this session's counts as they stand (#1703); a new process starts with none.
  on('session.start', async ($, e, next) => {
    noteSaid = false
    uncounted = false
    await $.command.register({ name: 'style-count', description: 'How many of my replies used a dash or emoji.' })
    return next(e)
  })

  on('command.run', { command: 'style-count' }, async $ => {
    const total = ((await $.store.get('chatHits')) as number | undefined) ?? 0
    const sessionHits = (await $.state.get({ plugin: 'style-check', key: 'hits' })).value ?? 0
    const sessionUnchecked = (await $.state.get({ plugin: 'style-check', key: 'unchecked' })).value ?? 0
    const gap = sessionUnchecked === 0 ? '' : ` ${sessionUnchecked} ${sessionUnchecked === 1 ? 'reply' : 'replies'} this session could not be checked.`
    const kept = (await $.state.get({ plugin: 'style-check', key: 'uncounted' }).catch(() => ({ value: undefined }))).value === true
    const short = uncounted || kept ? ' This session count may be short: a reply could not be counted.' : ''
    return { text: `Replies with a dash or emoji: ${sessionHits} this session, ${total} in total.${gap}${short}` }
  })

  on('tool.call', async ($, e, next) => {
    const out = await outgoing($, String(e.tool), e as unknown as Record<string, unknown>)
    if (!out || !out.text) return next(e)
    const v = await scan($, out.text, out.path || undefined)
    if (v.kind === 'hit') {
      const where = lineWords(v.lines)
      await $.modkit.blocked({ toolUseId: String((e as { tool_use_id?: string }).tool_use_id ?? ''), guard: GUARD, reason: `This text has a dash or emoji${where}.`, safeWay: FIX })
      await $.ui.toast('Blocked a dash or emoji.')
      return { deny: `Blocked: this text has a dash or emoji${where}. ${FIX}` }
    }
    if (v.kind === 'unchecked') {
      // The push gate is still the backstop, so this lets the write through, but says so rather than
      // passing as checked (L11).
      unchecked($, v.why)
    }
    return next(e)
  })

  // A chat reply cannot be refused once written: count it and say so.
  on('session.append', { door: 'response' }, async ($, e, next) => {
    const text = e.message.content
      .map(b => (b as { type?: string; text?: string }).type === 'text' ? ((b as { text?: string }).text ?? '') : '')
      .join('\n')
    if (text) {
      const v = await scan($, text)
      if (v.kind === 'hit') {
        // Counted silently, read with /style-count (Dan, 2026-10-03).
        await counting($, 'hits')
        // One queue for the stored total, so two replies counted at once both land (L690).
        const counted = countChain.then(async () => {
          await $.store.set('chatHits', (((await $.store.get('chatHits')) as number | undefined) ?? 0) + 1)
        })
        countChain = counted.catch(() => undefined)
        await counted
      } else if (v.kind === 'unchecked') {
        // Kept apart from the count (lessons review).
        await counting($, 'unchecked')
        unchecked($, v.why)
      }
    }
    return next(e)
  })
}
