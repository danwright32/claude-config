import type { Register } from 'claude-code'

// The probe of tests/fs-kind-engine-check.sh (claude-config#1830), never installed: that script
// loads it with --plugin-dir into a headless Claude Code session whose model is the scripted
// stand-in, in a scratch HOME, so it is the only mod there.
//
// On the one Bash call whose command carries PROBE-TAG=fs-kinds, before the call runs, it asks the
// engine's $.fs about the folder FS_KIND_PROBE_DIR names, which the script fills with a real fifo
// (probe.fifo, made by mkfifo), a link to /dev/stdin (stdin.link) and an ordinary file (plain.txt,
// the control), asks about /dev/null and /dev/stdin themselves, and appends one key=value line per
// answer to FS_KIND_PROBE_OUT:
//
//   fifo, devnull, stdin, stdin_link, plain
//                                    $.fs.stat(path, { resolve: true }).kind of each, asked as
//                                    mod-kit asks, links followed
//   list_fifo, list_plain            the kind a listing of the folder gives each
//   list_files                       every name the listing calls a file, joined by commas
//   done=1                           last, so a record cut short reads as one
//
// A look that throws is written as error:<message>. mod-kit's inputTexts and currentText
// (hooks/inputs.ts, #1765, #1814) never open a path whose stat is not `file`, and the design round
// guard reads only what a listing calls a file, so a fifo or a device read as `file` would bring
// back the hangs those fixes ended.
const kindOf = async (look: () => Promise<{ kind: string }>): Promise<string> => {
  try {
    return (await look()).kind
  } catch (err) {
    return `error:${err instanceof Error ? err.message : String(err)}`.replace(/\s+/g, ' ')
  }
}

export const register: Register = on => {
  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const command = String((e as unknown as Record<string, unknown>).command ?? '')
    if (!/PROBE-TAG=fs-kinds(\s|$)/.test(command)) return next(e)
    const [out, dir] = await Promise.all([$.env.get('FS_KIND_PROBE_OUT'), $.env.get('FS_KIND_PROBE_DIR')])
    if (!out || !dir) return next(e)
    const lines: string[] = []
    lines.push(`fifo=${await kindOf(() => $.fs.stat(`${dir}/probe.fifo`, { resolve: true }))}`)
    lines.push(`devnull=${await kindOf(() => $.fs.stat('/dev/null', { resolve: true }))}`)
    lines.push(`stdin=${await kindOf(() => $.fs.stat('/dev/stdin', { resolve: true }))}`)
    lines.push(`stdin_link=${await kindOf(() => $.fs.stat(`${dir}/stdin.link`, { resolve: true }))}`)
    lines.push(`plain=${await kindOf(() => $.fs.stat(`${dir}/plain.txt`, { resolve: true }))}`)
    try {
      const entries = await $.fs.list(dir)
      const kind = (name: string) => entries.find(x => x.name === name)?.kind ?? 'missing'
      lines.push(`list_fifo=${kind('probe.fifo')}`, `list_plain=${kind('plain.txt')}`)
      lines.push(`list_files=${entries.filter(x => x.kind === 'file').map(x => x.name).join(',')}`)
    } catch (err) {
      const why = `error:${err instanceof Error ? err.message : String(err)}`.replace(/\s+/g, ' ')
      lines.push(`list_fifo=${why}`, `list_plain=${why}`, `list_files=${why}`)
    }
    lines.push('done=1')
    await $.process.run(['sh', '-c', 'printf "%s\\n" "$1" >> "$2"', '_', lines.join('\n'), out])
    return next(e)
  })
}
