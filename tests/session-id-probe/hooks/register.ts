import type { Register } from 'claude-code'
import { pollLib, takeLook } from './mod-kit/ghpoll.ts'

// The probe of tests/test-session-id-agreement.sh (claude-config#1575), never installed: that suite
// copies it into a scratch HOME with the real mod-kit hooks/ghpoll.ts beside it as
// ./mod-kit/ghpoll.ts, and loads it with --plugin-dir.
//
// On every Bash call whose command carries PROBE-TAG=<tag>, before the call runs, it appends one
// line to SESSION_ID_PROBE_OUT: the tag, $.session.id(), the agentId of a subagent's call, the
// CLAUDE_CODE_SESSION_ID of the mod's own environment, and the answer to one look taken through
// ghpoll.ts exactly as status-bar and scope-modes build it (the session is $.session.id()), at the
// same fixed moment the suite's Bash calls use.
const PROBE_NOW_MS = 1_000_000_000

export const register: Register = on => {
  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const [out, home] = await Promise.all([$.env.get('SESSION_ID_PROBE_OUT'), $.env.get('HOME')])
    const tag = /PROBE-TAG=(\S+)/.exec(String((e as unknown as Record<string, unknown>).command ?? ''))?.[1]
    if (out && home && tag) {
      const id = await $.session.id()
      const own = (await $.env.get('CLAUDE_CODE_SESSION_ID')) ?? ''
      let look: string
      try {
        const t = await takeLook({ run: (argv, env) => $.process.run(argv, env ? { env } : {}), lib: pollLib(home), session: id }, PROBE_NOW_MS)
        look = t.take ? 'ok' : `wait ${t.why}`
      } catch (err) {
        look = `error ${err instanceof Error ? err.message : String(err)}`.replace(/\s+/g, ' ')
      }
      const line = [tag, id, e.agentId ?? '', own, look].join('\t') + '\n'
      await $.process.run(['sh', '-c', 'printf %s "$1" >> "$2"', '_', line, out])
    }
    return next(e)
  })
}
