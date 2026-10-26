// production-audit.harness.cjs: runs production-audit.workflow.js as the Workflow engine does, with
// every agent stood in, so what the audit asks and reports is tested by running it, never by grepping
// the script's text (claude-config#1753).
//
//   node production-audit.harness.cjs <production-audit.workflow.js> <scenario>
//
// Prints one JSON line: the run's return value (`result`), every agent call it made (`calls`, label
// and prompt), its log lines, and the most agents it ever had running at once (`maxInFlight`).
// Exit 0 ran, 1 the script threw (the error printed), 2 usage. The script is compiled by
// workflow-syntax.js, the one reading of a workflow script shared with the syntax check.
// Every company and system named here is invented.
'use strict'
const fs = require('fs')
const path = require('path')
const { compile } = require(path.join(__dirname, '..', '..', 'hooks', 'lib', 'workflow-syntax.js'))

const [scriptPath, scenarioName] = process.argv.slice(2)
if (!scriptPath || !scenarioName) {
  console.error('Usage: production-audit.harness.cjs <production-audit.workflow.js> <scenario>')
  process.exit(2)
}

// The domain keys are read from the script's own prompt to the profiler, so a scenario that says
// "everything applies" means every domain the script has, not a copy of the list kept here.
const domainKeysFrom = (prompt) => [...prompt.matchAll(/^([a-z][a-z-]+): /gm)].map(m => m[1])

// A profile as the profiler would return it. The repo sends no email of its own; consumer email goes
// out from an outside CRM, which is exactly the case the 2026-10-24 run missed.
const profileFor = (prompt, extra = {}) => ({
  type: 'web-app', stack: 'next', hosting: 'edge', hasDatabase: true, multiTenant: false,
  handlesPII: true, sendsEmail: true, sendsEmailFromRepo: false, hasAuth: false, isPublic: true, usesCI: true,
  consumerMessaging: [{ system: 'Larkspur CRM', channels: ['email'], inRepo: false, evidence: 'docs/integrations.md:4' }],
  financialProduct: true, healthData: false, mayReachChildren: false, sellsSubscriptions: false, acceptsUserUploads: false,
  applicableDomains: domainKeysFrom(prompt), naReasons: [],
  ...extra,
})
const noFindings = (prompt) => ({ domain: (prompt.match(/"([^"]+)" production-readiness auditor/) || [])[1] || 'x', findings: [] })
const canSpamGap = {
  check: 'Commercial email carries a postal address', status: 'missing', severity: 'high',
  evidence: 'templates/welcome.html:1', remediation: 'add the address', effort: 'S', law: 'CAN-SPAM',
}

const scenarios = {
  // Every domain applies, the compliance auditor reports one CAN-SPAM gap and names nothing it
  // could not inspect, and synthesis keeps the law on the backlog item.
  default: {
    profile: p => profileFor(p),
    'audit:compliance-audit': () => ({ domain: 'compliance-audit', findings: [canSpamGap] }),
    synthesize: () => ({ executiveSummary: 's', severityCounts: {}, backlog: [{ domain: 'compliance-audit', ...canSpamGap }] }),
  },
  // As default, with a hand written focus.
  focus: {
    profile: p => profileFor(p),
  },
  // The profiler marks the legal domains not applicable on a public site that holds personal data.
  'drops-legal': {
    profile: p => profileFor(p, {
      applicableDomains: domainKeysFrom(p).filter(k => k !== 'compliance-audit' && k !== 'data-isolation-pii'),
      naReasons: [{ domain: 'compliance-audit', reason: 'repo sends no email' }, { domain: 'data-isolation-pii', reason: 'no tenants' }],
    }),
  },
  // A genuinely internal tool: no public surface, no personal data, no consumer messaging.
  'internal-tool': {
    profile: p => profileFor(p, {
      isPublic: false, handlesPII: false, sendsEmail: false, consumerMessaging: [],
      applicableDomains: domainKeysFrom(p).filter(k => k !== 'compliance-audit'),
      naReasons: [{ domain: 'compliance-audit', reason: 'internal build tool' }],
    }),
  },
  // The compliance auditor names the CRM as not inspectable; a second outside system (from the
  // person's answer) is named by nobody at all.
  'not-inspected': {
    profile: p => profileFor(p, {
      consumerMessaging: [
        { system: 'Larkspur CRM', channels: ['email'], inRepo: false, evidence: 'docs/integrations.md:4' },
        { system: 'Quillfeather Dialer', channels: ['sms', 'call'], inRepo: false, evidence: 'named by the person' },
      ],
    }),
    'audit:compliance-audit': () => ({ domain: 'compliance-audit', findings: [], notInspected: [{ system: 'Larkspur CRM', reason: 'templates live in the CRM, not the repo' }] }),
  },
  // The compliance auditor inspected the CRM's templates and says so in its evidence.
  'crm-inspected': {
    profile: p => profileFor(p),
    'audit:compliance-audit': () => ({ domain: 'compliance-audit', findings: [{ ...canSpamGap, evidence: 'Larkspur CRM template "Welcome" has no footer' }] }),
  },
  // Synthesis drops the law tag from the only legal finding.
  'law-dropped': {
    profile: p => profileFor(p),
    'audit:compliance-audit': () => ({ domain: 'compliance-audit', findings: [canSpamGap] }),
    synthesize: () => {
      const { law, ...rest } = canSpamGap // eslint-disable-line no-unused-vars
      return { executiveSummary: 's', severityCounts: {}, backlog: [{ domain: 'compliance-audit', ...rest }] }
    },
  },
  // The compliance auditor dies: the legal checks never ran, and that must be said, never read as clean.
  'dead-auditor': {
    profile: p => profileFor(p),
    'audit:compliance-audit': () => { throw new Error('agent died') },
  },
  // The same death as the Workflow engine reports it: agent() returns null when a subagent dies.
  'dead-auditor-null': {
    profile: p => profileFor(p),
    'audit:compliance-audit': () => null,
  },
}
const scenario = scenarios[scenarioName]
if (!scenario) {
  console.error(`production-audit.harness: no scenario "${scenarioName}"; known: ${Object.keys(scenarios).join(', ')}`)
  process.exit(2)
}
const defaults = {
  profile: p => profileFor(p),
  audit: noFindings,
  verify: () => ({ refuted: false, reason: 'stands' }),
  synthesize: () => ({ executiveSummary: 's', severityCounts: {}, backlog: [] }),
}
const answerFor = (label) => {
  const stem = String(label).split(':')[0]
  return scenario[label] || scenario[stem] || defaults[label] || defaults[stem]
}

const calls = []
const logs = []
let inFlight = 0
let maxInFlight = 0
// Each stand in agent yields to the event loop a few times before answering, so agents genuinely
// overlap and the most ever running at once is a real measurement rather than always one.
const yieldTicks = (n) => n > 0 ? new Promise(r => setImmediate(r)).then(() => yieldTicks(n - 1)) : Promise.resolve()
const agent = async (prompt, opts = {}) => {
  calls.push({ label: opts.label, prompt })
  inFlight++
  maxInFlight = Math.max(maxInFlight, inFlight)
  try {
    await yieldTicks(3)
    const answer = answerFor(opts.label)
    if (!answer) throw new Error(`production-audit.harness: no answer for agent "${opts.label}"`)
    return answer(prompt, opts)
  } finally {
    inFlight--
  }
}
// As the engine: every task runs, and one that fails resolves to null rather than failing the rest.
const parallel = async (tasks) => Promise.all(tasks.map(t => Promise.resolve().then(t).catch(() => null)))
// As the engine: each item runs through every stage with no barrier; a stage that throws drops that
// item to null and skips its remaining stages. Each stage gets (prevResult, originalItem, index).
const pipeline = async (items, ...stages) => Promise.all(items.map(async (item, i) => {
  let prev = item
  try {
    for (const s of stages) prev = await s(prev, item, i)
    return prev
  } catch (e) {
    return null
  }
}))
const phase = () => {}
const log = (line) => { logs.push(String(line)) }

const args = {
  projectDir: '/p', repo: 'o/r', date: '2026-10-26',
  ...(scenarioName === 'focus' ? { focus: 'consumer email sent from the CRM' } : {}),
  ...(scenarioName === 'not-inspected' ? { outsideSystems: ['Quillfeather Dialer'] } : {}),
}

const run = compile(fs.readFileSync(scriptPath, 'utf8'), ['args', 'agent', 'parallel', 'pipeline', 'phase', 'log'])
run(args, agent, parallel, pipeline, phase, log).then(
  result => { process.stdout.write(JSON.stringify({ result, calls, logs, maxInFlight }) + '\n') },
  err => { console.error(`production-audit.harness: the script threw: ${err && err.stack ? err.stack : err}`); process.exit(1) },
)
