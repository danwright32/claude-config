import type { EngineInterface, Register } from 'claude-code'

// Style check at write time (claude-config#609). One rule, not two: the verdict is always the push
// hook's own scanner, hooks/lib/style-scan.py, run on the text about to be written (L370, L613).
// Nothing here knows which characters are forbidden.

const SLACK = new Set([
  'mcp__claude_ai_Slack__slack_send_message',
  'mcp__claude_ai_Slack__slack_send_message_draft',
  'mcp__claude_ai_Slack__slack_schedule_message',
])
const COMMIT = /\bgit\b[^\n;&|]*\bcommit\b/
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

const FIX =
  'Rewrite it: a period, comma, colon or parentheses in place of the dash, and no emoji. Code that must name one of these characters writes it as an escape (\\u2014).'

export const register: Register = on => {
  on('tool.call', async ($, e, next) => {
    const out = await outgoing($, String(e.tool), e as unknown as Record<string, unknown>)
    if (!out || !out.text) return next(e)
    const v = await scan($, out.text, out.path || undefined)
    if (v.kind === 'hit') {
      await $.ui.toast('style-check: refused text with a dash or emoji')
      return { deny: `style-check: refused, because this carries an em dash, en dash or emoji, which the Writing Style rule forbids:\n${v.lines}\n${FIX}` }
    }
    if (v.kind === 'unchecked') {
      // The push gate is still the backstop, so this lets the write through, but says so rather than
      // passing as checked (L11).
      $.ui.log(`style-check: could not check ${String(e.tool)} (${v.why}); the push hook still will.`)
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
        const n = (((await $.store.get('chatHits')) as number | undefined) ?? 0) + 1
        await $.store.set('chatHits', n)
        await $.ui.toast(`style-check: a chat reply used a dash or emoji (${n} so far)`)
      }
    }
    return next(e)
  })
}
