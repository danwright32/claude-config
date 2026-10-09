import { ghWords, helperWords, type Cmd } from '../hooks/nobuild.ts'
import { git, pipeline } from './mod-kit/hooks/commands.ts'
import { ghArgs } from './mod-kit/hooks/gh.ts'

// A Bash call's commands as the mod reads them in a session (register.ts, readCommands): mod-kit's
// pipeline, each command with its git reading and its gh readings (#961), each read by a byte for
// byte copy of mod-kit's own reader under tests/mod-kit, held to mod-kit's by
// tools/check-mod-shared-parts.sh, so a quoted separator is read as it is in a session (#730).
export const readCommands = (command: string): Cmd[] =>
  pipeline(command).map(c => {
    const g = git(c.words)
    const cmd: Cmd = g ? { ...c, git: { sub: g.sub, args: g.args, ...(g.dir !== undefined ? { dir: g.dir } : {}) } } : { ...c }
    const ghAt = ghWords(c.words)
    const gh = ghAt ? ghArgs(ghAt) : undefined
    if (gh) cmd.gh = gh
    const helperAt = helperWords(c.words)
    const helper = helperAt ? ghArgs(helperAt) : undefined
    if (helper) cmd.mergeHelper = helper
    return cmd
  })
