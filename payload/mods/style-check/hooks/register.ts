import type { EngineInterface, Register } from 'claude-code'

// Style check at write time (claude-config#609). One rule, not two: the verdict is always the push
// hook's own scanner, hooks/lib/style-scan.py, run on the text about to be written (L370, L613).
// Nothing here knows which characters are forbidden.

const SLACK = new Set([
  'mcp__claude_ai_Slack__slack_send_message',
  'mcp__claude_ai_Slack__slack_send_message_draft',
  'mcp__claude_ai_Slack__slack_schedule_message',
])
// commit as git's subcommand, after any global options (-C <dir>, -c <k=v>, --flags), never a git
// command that merely mentions the word (git log --grep=commit).
const COMMIT = /\bgit(?:\s+-[Cc]\s+\S+|\s+--[\w-]+(?:=\S+)?)*\s+commit\b/
const GH_BODY = /\bgh\s+(?:issue|pr)\s+(?:create|edit|comment)\b/
const BODY_FILE = /(?:--body-file|--file|-F)[ =](?:"([^"]+)"|'([^']+)'|(\S+))/g

type Verdict = { kind: 'clean' } | { kind: 'hit'; lines: string } | { kind: 'unchecked'; why: string }

const scan = async ($: EngineInterface, text: string, path?: string): Promise<Verdict> => {
  const home = await $.env.get('HOME')
  if (!home) return { kind: 'unchecked', why: 'HOME is not set, so the scanner could not be found' }
  const argv = ['python3', `${home}/.claude/hooks/lib/style-scan.py`, '--plain', ...(path ? ['--path', path] : [])]
  try {
    const r = await $.process.run(argv, { stdin: text, timeoutMs: 10_000 })
    if (r.exitCode === 0) return { kind: 'clean' }
    if (r.exitCode === 1) return { kind: 'hit', lines: r.stdout.trim() }
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
      if (!COMMIT.test(cmd) && !GH_BODY.test(cmd)) return undefined
      // The message as written in the command, plus any file it is read from.
      const parts = [cmd]
      for (const m of cmd.matchAll(BODY_FILE)) {
        const f = m[1] ?? m[2] ?? m[3]
        if (!f || f === '-') continue
        try {
          parts.push(await $.fs.read(f))
        } catch {
          // A file that cannot be read is left to the command, which will fail on it itself.
        }
      }
      return { text: parts.join('\n') }
    }
    default:
      return SLACK.has(tool) ? { text: strings(e).join('\n') } : undefined
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
let sessionHits = 0
let sessionUnchecked = 0
const UNCHECKED_NOTE = "Style check couldn't run, so this wasn't checked for dashes or emoji. The push check still will."

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    sessionHits = 0
    sessionUnchecked = 0
    await $.command.register({ name: 'style-count', description: 'How many of my replies used a dash or emoji.' })
    return next(e)
  })

  on('command.run', { command: 'style-count' }, async $ => {
    const total = ((await $.store.get('chatHits')) as number | undefined) ?? 0
    const gap = sessionUnchecked === 0 ? '' : ` ${sessionUnchecked} ${sessionUnchecked === 1 ? 'reply' : 'replies'} this session could not be checked.`
    return { text: `Replies with a dash or emoji: ${sessionHits} this session, ${total} in total.${gap}` }
  })

  on('tool.call', async ($, e, next) => {
    const out = await outgoing($, String(e.tool), e as unknown as Record<string, unknown>)
    if (!out || !out.text) return next(e)
    const v = await scan($, out.text, out.path || undefined)
    if (v.kind === 'hit') {
      const where = lineWords(v.lines)
      $.modkit.blocked({ toolUseId: String((e as { tool_use_id?: string }).tool_use_id ?? ''), guard: GUARD, reason: `This text has a dash or emoji${where}.`, safeWay: FIX })
      await $.ui.toast('Blocked a dash or emoji.')
      return { deny: `Blocked: this text has a dash or emoji${where}. ${FIX}` }
    }
    if (v.kind === 'unchecked') {
      // The push gate is still the backstop, so this lets the write through, but says so rather than
      // passing as checked (L11).
      $.ui.log(UNCHECKED_NOTE)
      // Dan's line stays as he approved it; the cause goes to the debug log, never dropped.
      $.ui.log(`style-check: ${v.why}`, { to: 'debug' })
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
        sessionHits += 1
        await $.store.set('chatHits', (((await $.store.get('chatHits')) as number | undefined) ?? 0) + 1)
      } else if (v.kind === 'unchecked') {
        // Said once a session, and kept apart from the count (lessons review).
        if (sessionUnchecked === 0) $.ui.log(UNCHECKED_NOTE)
        sessionUnchecked += 1
        $.ui.log(`style-check: ${v.why}`, { to: 'debug' })
      }
    }
    return next(e)
  })
}
