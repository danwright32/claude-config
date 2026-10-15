// panel-loop.harness.cjs: runs panel.workflow.js as the Workflow engine does, with every agent
// stood in, so the check loop's behaviour is tested rather than grepped (claude-config#1208).
//
//   node panel-loop.harness.cjs <panel.workflow.js> <scenario>
//
// Prints one JSON line: the run's return value (`result`), every agent call it made (`calls`, label
// and prompt), and its log lines. Exit 0 ran, 1 the script threw (the error printed), 2 usage.
// The script is compiled by workflow-syntax.js, the one reading of a workflow script, so the harness
// and the syntax check cannot disagree about what a script is.
'use strict'
const fs = require('fs')
const path = require('path')
const { compile } = require(path.join(__dirname, '..', '..', 'hooks', 'lib', 'workflow-syntax.js'))

const [scriptPath, scenarioName] = process.argv.slice(2)
if (!scriptPath || !scenarioName) {
  console.error('Usage: panel-loop.harness.cjs <panel.workflow.js> <scenario>')
  process.exit(2)
}

// A three item plan: Phase 2 refers to Phase 1 by name, Phase 3 to nothing.
const PLAN = '# Plan\n\nIntro line.\n\n## Phase 1 storage\nAdd the table.\n\n## Phase 2 api\nThe route reads the Phase 1 table.\n\n## Phase 3 ui\nShow the count.\n'
const FILES = ['LESSONS-INDEX-a.md', 'LESSONS-INDEX-b.md']
const cleanAudit = (extra = {}) => ({ indexFilesRead: FILES, lessonsSeen: 20, verdict: 'clean', violations: [], ...extra })
const holds = () => ({ verdict: 'holds', confirmed: ['all'], findings: [] })
// The item id the workflow gave a heading, read from the marked plan it showed the agent.
const idOf = (prompt, heading) => {
  const m = prompt.match(new RegExp(`<<(P\\d+)>>\\n${heading.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}`))
  return m ? m[1] : 'P-missing'
}
const findingIds = (prompt) => [...new Set([...prompt.matchAll(/\b(F\d+)\b/g)].map(m => m[1]))]

// Each scenario answers by label. Anything not answered here falls to the panel defaults below.
const scenarios = {
  // One blocking reality finding on Phase 2, fixed in round 1 and verified fixed.
  converges: {
    'reality-check': p => ({ verdict: 'needs-fixes', confirmed: [], findings: [{ item: idOf(p, '## Phase 2 api'), what: 'route path is wrong', fix: 'name the real route' }] }),
    'fix:1': p => ({ edits: [{ item: idOf(p, '## Phase 2 api'), text: '## Phase 2 api\nThe real route reads the Phase 1 table.\n' }], added: [], declined: [] }),
    'verify:1': p => ({ verdicts: findingIds(p).map(f => ({ finding: f, status: 'fixed', evidence: 'route named' })) }),
  },
  // The verifier never confirms, so the run stops at the ceiling with the finding open.
  ceiling: {
    'reality-check': p => ({ verdict: 'needs-fixes', confirmed: [], findings: [{ item: idOf(p, '## Phase 2 api'), what: 'route path is wrong', fix: 'name the real route' }] }),
    fix: p => ({ edits: [{ item: idOf(p, '## Phase 2 api'), text: '## Phase 2 api\nAnother try at the route.\n' }], added: [], declined: [] }),
    verify: p => ({ verdicts: findingIds(p).map(f => ({ finding: f, status: 'open', evidence: 'still wrong' })) }),
  },
  // Only an advisory lesson finding: no fix round at all, and it is handed to Dan.
  advisory: {
    'lessons-audit': p => cleanAudit({ verdict: 'violations', violations: [{ lessonId: 'L36', item: idOf(p, '## Phase 3 ui'), severity: 'advisory', where: 'the count', why: 'noisy', fix: 'quiet it' }] }),
  },
  // The verifier answers for no finding at all, so the one it skipped stays open.
  'verifier-omits': {
    'reality-check': p => ({ verdict: 'needs-fixes', confirmed: [], findings: [{ item: idOf(p, '## Phase 2 api'), what: 'route path is wrong', fix: 'name the real route' }] }),
    fix: p => ({ edits: [{ item: idOf(p, '## Phase 2 api'), text: '## Phase 2 api\nThe real route reads the Phase 1 table.\n' }], added: [], declined: [] }),
    verify: () => ({ verdicts: [] }),
  },
  // A fix to Phase 1 re-checks Phase 2, which names it, and never Phase 3.
  references: {
    'reality-check': p => ({ verdict: 'needs-fixes', confirmed: [], findings: [{ item: idOf(p, '## Phase 1 storage'), what: 'table name is wrong', fix: 'use the real table' }] }),
    'fix:1': p => ({ edits: [{ item: idOf(p, '## Phase 1 storage'), text: '## Phase 1 storage\nAdd the real table.\n' }], added: [], declined: [] }),
    'verify:1': p => ({ verdicts: findingIds(p).map(f => ({ finding: f, status: 'fixed', evidence: 'ok' })) }),
  },
  // The fixer declines the finding: it is Dan's, and the run is never clean.
  declined: {
    'lessons-audit': p => cleanAudit({ verdict: 'violations', violations: [{ lessonId: 'L5', item: idOf(p, '## Phase 1 storage'), severity: 'blocking', where: 'drop', why: 'no backup', fix: 'back up first' }] }),
    fix: p => ({ edits: [], added: [], declined: findingIds(p).map(f => ({ finding: f, reason: 'the table is empty by construction' })) }),
  },
  // The reality-check dies: the run can never read as verified.
  'dead-check': {
    'reality-check': () => null,
  },
  // The auditor skips a file: unaudited, never clean.
  unaudited: {
    'lessons-audit': () => cleanAudit({ indexFilesRead: [FILES[0]] }),
  },
  // Revise mode runs the same loop.
  revise: {
    revise: () => ({ plan: PLAN, responses: ['done'], openRisks: [] }),
    'reality-check': p => ({ verdict: 'needs-fixes', confirmed: [], findings: [{ item: idOf(p, '## Phase 2 api'), what: 'route path is wrong', fix: 'name the real route' }] }),
    'fix:1': p => ({ edits: [{ item: idOf(p, '## Phase 2 api'), text: '## Phase 2 api\nThe real route reads the Phase 1 table.\n' }], added: [], declined: [] }),
    'verify:1': p => ({ verdicts: findingIds(p).map(f => ({ finding: f, status: 'fixed', evidence: 'ok' })) }),
  },
}
const scenario = scenarios[scenarioName]
if (!scenario) {
  console.error(`panel-loop.harness: no scenario "${scenarioName}"; known: ${Object.keys(scenarios).join(', ')}`)
  process.exit(2)
}

// The panel before the checks, answered plainly so every scenario reaches the loop.
const defaults = {
  preflight: () => ({ repoReadable: true, notes: '' }),
  pass: () => ({ role: 'x', approach: 'a', risks: [], hardConstraints: [], confidence: 'high' }),
  distill: () => ({ options: [{ id: 'o1', name: 'One', summary: 's', keyChoices: ['k'], cost: 'free' }, { id: 'o2', name: 'Two', summary: 's', keyChoices: ['k'], cost: 'free' }] }),
  champion: () => ({ optionId: 'o1', caseFor: 'good', confidence: 'high' }),
  redteam: () => ({ optionId: 'o1', caseAgainst: 'bad', confidence: 'low' }),
  judge: () => ({ winnerId: 'o1', scores: [], rationale: 'r', runnerUpBestIdeas: [] }),
  synthesize: () => ({ title: 'T', plan: PLAN, overruledDissent: ['kept from the debate'], idealVsDoable: 'i', escalatedDecisions: [], openRisks: [] }),
  'reality-check': holds,
  'lessons-audit': () => cleanAudit(),
  recheck: holds,
  reaudit: () => cleanAudit(),
  consistency: holds,
  fix: () => ({ edits: [], added: [], declined: [] }),
  verify: () => ({ verdicts: [] }),
}
// The most specific answer for a label: the scenario's exact label, then its stem, then the defaults.
const answerFor = (label) => {
  const stem = String(label).split(':')[0]
  return scenario[label] || scenario[stem] || defaults[label] || defaults[stem]
}

const calls = []
const logs = []
const agent = async (prompt, opts = {}) => {
  calls.push({ label: opts.label, prompt })
  const answer = answerFor(opts.label)
  if (!answer) throw new Error(`panel-loop.harness: no answer for agent "${opts.label}"`)
  return answer(prompt, opts)
}
// As the engine: every task runs, and one that fails resolves to null rather than failing the rest.
const parallel = async (tasks) => Promise.all(tasks.map(t => Promise.resolve().then(t).catch(() => null)))
const phase = () => {}
const log = (line) => { logs.push(String(line)) }

const args = {
  feature: 'a feature', constraints: 'none', projectDir: '/p', repo: 'o/r', usesSupabase: false,
  roles: [{ key: 'architect', brief: 'b' }],
  lessonIndexFiles: FILES.map(f => `/home/.claude/${f}`),
  ...(scenarioName === 'revise' ? { mode: 'revise', priorPlan: PLAN, comments: 'please fix' } : {}),
}

const run = compile(fs.readFileSync(scriptPath, 'utf8'), ['args', 'agent', 'parallel', 'phase', 'log'])
run(args, agent, parallel, phase, log).then(
  result => { process.stdout.write(JSON.stringify({ result, calls, logs }) + '\n') },
  err => { console.error(`panel-loop.harness: the script threw: ${err && err.stack ? err.stack : err}`); process.exit(1) },
)
