// The issues each branch name names, for the hooks and libraries outside the mods (#1475). It runs
// mod-kit's issuesOfBranch, the one reader of them, so a library never keeps a reading of its own:
// sleep-queue.py had one, and it drifted from mod-kit's until a plan's step and an agent's random
// id each kept an issue out of the night. hooks/test-branch-issue-reader.sh fails on another.
//
//   node --experimental-strip-types --no-warnings branch-issues.mjs < names
//
// Names one per line on standard input; out, one JSON object of each name and its issues. Where
// mod-kit is not beside it the import fails and node exits non zero, printing no answer, so a
// caller can never read a missing reader as branches naming nothing.
import { readFileSync } from 'node:fs'
import { issuesOfBranch } from '../../mods/mod-kit/hooks/branch.ts'

const names = readFileSync(0, 'utf8').split('\n').map(n => n.trim()).filter(Boolean)
process.stdout.write(`${JSON.stringify(Object.fromEntries(names.map(n => [n, issuesOfBranch(n)])))}\n`)
