import { ghWords, type Cmd } from '../hooks/nobuild.ts'
import { gitRead } from '../hooks/gitplace.ts'
import { git, pipeline } from './mod-kit/hooks/commands.ts'
import { ghArgs, mergeHelperArgs } from './mod-kit/hooks/gh.ts'

// A Bash call's commands as the mod reads them in a session (register.ts, readCommands): mod-kit's
// pipeline, each command with its git reading and its gh readings (#961, the merge helper's #1251),
// each read by a byte for byte copy of mod-kit's own reader under tests/mod-kit, held to mod-kit's
// by tools/check-mod-shared-parts.sh, so a quoted separator is read as it is in a session (#730).
// The git reading is asked with the settings written in front of the command and carried whole
// (gitRead, #3398), exactly as register.ts carries it.
export const readCommands = (command: string): Cmd[] =>
  pipeline(command).map(c => {
    const g = git(c.words, c.env ?? [])
    const cmd: Cmd = g ? { ...c, git: gitRead(g) } : { ...c }
    const ghAt = ghWords(c.words)
    const gh = ghAt ? ghArgs(ghAt) : undefined
    if (gh) cmd.gh = gh
    const helper = mergeHelperArgs(c)
    if (helper) cmd.mergeHelper = helper
    return cmd
  })
