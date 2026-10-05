// workflow-syntax.js: check a Workflow script parses the way the Workflow engine runs it.
//
//   node ~/.claude/hooks/lib/workflow-syntax.js <script.workflow.js> [...]
//
// A workflow script is the body of an async function: it starts `export const meta = {...}`,
// awaits at the top level and ends with a top level `return`. `node --check` reads it as a file
// instead, and a node that detects module syntax from that `export` reads it as an ES module, where
// a top level return is a syntax error, so a healthy script failed on CI's node while passing on a
// Mac's (claude-config#587, PR #798). This parses each file as the engine does, an async function
// body with the meta's `export` taken off, and never runs it.
//
// Exit 0 when every file parses; 1 naming each one that does not, with the parser's message; 2 on
// usage or any file it cannot read, after every file has been checked.
const fs = require('fs')

const files = process.argv.slice(2)
if (!files.length) {
  console.error('Usage: workflow-syntax.js <script.workflow.js> [...]')
  process.exit(2)
}
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor
let failed = 0
let unreadable = 0
// Every file is checked, an unreadable one included, so one bad path never hides the rest.
for (const f of files) {
  let src
  try {
    src = fs.readFileSync(f, 'utf8')
  } catch (e) {
    unreadable++
    console.error(`workflow-syntax: cannot read ${f}: ${e.message}`)
    continue
  }
  try {
    new AsyncFunction(src.replace(/^(\s*)export\s+(?=const\s+meta\b)/m, '$1'))
  } catch (e) {
    failed++
    console.error(`workflow-syntax: ${f} does not parse as a workflow script: ${e.message}`)
  }
}
process.exit(unreadable ? 2 : failed ? 1 : 0)
