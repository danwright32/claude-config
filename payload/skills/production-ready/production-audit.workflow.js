export const meta = {
  name: 'production-audit',
  description: 'Audit a project for production readiness: profile, fan out 19 domain auditors, adversarially verify serious findings, synthesize an advisory report.',
  phases: [
    { title: 'Profile', detail: 'detect project type + applicable domains' },
    { title: 'Audit', detail: 'one specialist auditor per applicable domain' },
    { title: 'Verify', detail: 'refute high/critical missing findings' },
    { title: 'Synthesize', detail: 'dedup, rank, build the report' },
  ],
}

// args may arrive already-parsed (object) or as a JSON string depending on how
// the skill launched the workflow: handle both, like plan-council does.
let _a
try {
  _a = (typeof args === 'string' && args.trim())
    ? JSON.parse(args)
    : (args && typeof args === 'object' ? args : {})
} catch (e) {
  throw new Error(`production-audit ABORT: args was a string but not valid JSON, ${e.message}. Nothing spawned.`)
}
const { projectDir, repo, date, mode } = _a
if (!projectDir) throw new Error('args.projectDir is required (got: ' + JSON.stringify(args) + ')')

// --- The 19 auditor domains (split-finer, per DESIGN.md) ---
const DOMAINS = [
  { key: 'input-injection', title: 'Input, Injection & Web Hardening', checklist: [
    'Input validation / sanitization on all external input',
    'SQL / NoSQL / command injection prevention',
    'XSS prevention (output encoding, templating safety)',
    'CSRF protection on state-changing requests',
    'CORS policy is explicit and least-privilege',
    'Security headers: CSP, HSTS, X-Frame-Options, X-Content-Type-Options',
    'File-upload validation (type, size, storage safety)',
    'Webhook signature verification' ] },
  { key: 'auth-sessions', title: 'Authentication & Sessions', checklist: [
    'Authentication flows are sound and complete',
    'Session management (secure cookies, fixation prevention)',
    'Token expiry and rotation',
    'MFA available where appropriate',
    'Credential/password storage (hashing, never plaintext)',
    'Account recovery cannot be abused' ] },
  { key: 'authz', title: 'Authorization & Access Control', checklist: [
    'Authorization enforced server-side on every protected action',
    'Roles & permissions model is coherent',
    'Per-tenant access checks (no horizontal privilege escalation)',
    'Default-deny posture',
    'No vertical privilege-escalation paths' ] },
  { key: 'secrets-transport', title: 'Secrets & Transport Security', checklist: [
    'Secrets in a manager / env, never committed',
    'Secret rotation possible',
    'HTTPS/TLS enforced everywhere',
    'Certificate rotation handled',
    'No secret or PII leakage in logs or error messages' ] },
  { key: 'dependencies', title: 'Dependencies & Supply Chain', checklist: [
    'Dependency vulnerability scanning in place',
    'Patching cadence for known CVEs',
    'OSS license compliance',
    'Lockfiles committed and respected',
    'SBOM / signed artifacts where relevant' ] },
  { key: 'rate-limiting', title: 'Rate Limiting & Abuse Prevention', checklist: [
    'Rate limiting on public/expensive endpoints',
    'Abuse / bot prevention',
    'DoS protection',
    'Per-request resource limits',
    'Quota enforcement per tenant/user' ] },
  { key: 'data-isolation-pii', title: 'Data Isolation & PII', checklist: [
    'Multi-tenancy data isolation (e.g. row-level security)',
    'PII inventory and handling',
    'Data retention & deletion policy implemented',
    'Encryption at rest for sensitive data' ] },
  { key: 'compliance-audit', title: 'Compliance, Audit & Legal', checklist: [
    'Regulatory compliance posture (GDPR/CCPA/etc.)',
    'Audit trails for sensitive actions',
    'Tamper-evident logging',
    'Privacy policy, cookie consent, ToS present' ] },
  { key: 'functional-testing', title: 'Functional Testing', checklist: [
    'Unit tests for core logic',
    'Integration tests across boundaries',
    'End-to-end tests for critical flows',
    'Regression tests for fixed bugs',
    'Coverage thresholds enforced in CI' ] },
  { key: 'load-chaos', title: 'Load, Stress & Chaos', checklist: [
    'Load / stress testing performed',
    'Chaos engineering / failure injection',
    'Resilience testing under dependency failure',
    'Capacity validated against expected peak' ] },
  { key: 'code-quality', title: 'Code Review & Static Quality', checklist: [
    'Code review process & standards documented',
    'Linting enforced',
    'Typechecking enforced',
    'Static analysis / SAST',
    'Branch protection on main' ] },
  { key: 'error-handling', title: 'Error Handling & Fault Tolerance', checklist: [
    'Consistent error handling (no swallowed errors)',
    'Graceful degradation when dependencies fail',
    'Retry with backoff and idempotency',
    'Circuit breakers & fallback behavior' ] },
  { key: 'concurrency-caching', title: 'Concurrency & Caching', checklist: [
    'Concurrency handling & race-condition prevention',
    'Locking / transactions where needed',
    'Caching strategy is intentional',
    'Cache invalidation is correct' ] },
  { key: 'observability', title: 'Observability & Incident Response', checklist: [
    'Structured logging',
    'Metrics collection',
    'Distributed tracing where applicable',
    'Dashboards for key signals',
    'Alerting on SLO breaches / errors',
    'On-call runbooks',
    'Health / readiness checks',
    'SLOs / error budgets defined',
    'Error tracking (Sentry-style)' ] },
  { key: 'deployment', title: 'Deployment & Release', checklist: [
    'CI/CD pipeline automates build/test/deploy',
    'Zero-downtime deploys',
    'Rollback path',
    'Canary / blue-green where appropriate',
    'Environment parity (staging =~ prod)',
    'Feature flags for risky changes',
    'Config management (no hardcoded env values)' ] },
  { key: 'dr-backups', title: 'DR, Backups & Continuity', checklist: [
    'RTO / RPO defined',
    'Disaster recovery plan exists',
    'Backups taken AND restores tested',
    'Database migration safety (reversible, tested)',
    'Graceful shutdown (SIGTERM handling)' ] },
  { key: 'cost-capacity', title: 'Cost, Capacity & Performance', checklist: [
    'Cost monitoring & budget alerts',
    'Capacity planning',
    'Autoscaling configured',
    'Performance / latency budgets' ] },
  { key: 'accessibility', title: 'Accessibility', checklist: [
    'WCAG conformance for UI',
    'Keyboard navigation',
    'Screen-reader semantics (labels, roles, alt text)',
    'Color contrast',
    'Focus management' ] },
  { key: 'docs-architecture', title: 'Documentation & Architecture', checklist: [
    'Architecture Decision Records (ADRs)',
    'Architecture diagrams',
    'API contracts and versioning',
    'README / runbooks / onboarding docs' ] },
]

// --- Schemas ---
const PROFILE_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['type', 'applicableDomains', 'naReasons'],
  properties: {
    type: { type: 'string' },
    stack: { type: 'string' },
    hosting: { type: 'string' },
    hasDatabase: { type: 'boolean' },
    multiTenant: { type: 'boolean' },
    handlesPII: { type: 'boolean' },
    sendsEmail: { type: 'boolean' },
    hasAuth: { type: 'boolean' },
    isPublic: { type: 'boolean' },
    usesCI: { type: 'boolean' },
    applicableDomains: { type: 'array', items: { type: 'string' } },
    naReasons: { type: 'array', items: {
      type: 'object', additionalProperties: false,
      required: ['domain', 'reason'],
      properties: { domain: { type: 'string' }, reason: { type: 'string' } } } },
  },
}
const FINDING_PROPS = {
  check: { type: 'string' },
  status: { type: 'string', enum: ['pass', 'partial', 'missing', 'na'] },
  severity: { type: 'string', enum: ['critical', 'high', 'medium', 'low', 'none'] },
  evidence: { type: 'string' },
  remediation: { type: 'string' },
  effort: { type: 'string', enum: ['S', 'M', 'L'] },
}
const FINDINGS_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['domain', 'findings'],
  properties: {
    domain: { type: 'string' },
    findings: { type: 'array', items: {
      type: 'object', additionalProperties: false,
      required: ['check', 'status', 'severity', 'evidence', 'remediation', 'effort'],
      properties: FINDING_PROPS } },
  },
}
const REFUTE_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['refuted', 'reason'],
  properties: {
    refuted: { type: 'boolean' },
    reason: { type: 'string' },
    evidence: { type: 'string' },
  },
}
const SYNTH_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['executiveSummary', 'severityCounts', 'backlog'],
  properties: {
    executiveSummary: { type: 'string' },
    whatsSolid: { type: 'array', items: { type: 'string' } },
    topRisks: { type: 'array', items: { type: 'string' } },
    severityCounts: { type: 'object', additionalProperties: false,
      properties: { critical: { type: 'number' }, high: { type: 'number' }, medium: { type: 'number' }, low: { type: 'number' } } },
    backlog: { type: 'array', items: {
      type: 'object', additionalProperties: false,
      required: ['domain', 'check', 'status', 'severity', 'evidence', 'remediation', 'effort'],
      properties: { domain: { type: 'string' }, ...FINDING_PROPS } } },
  },
}

// --- Phase 0: profile ---
phase('Profile')
const domainList = DOMAINS.map(d => `${d.key}: ${d.title}`).join('\n')
const profile = await agent(
  `You are profiling a codebase to scope a production-readiness audit. Project directory: ${projectDir}.
Read CLAUDE.md, the package manifest, framework/config files, CI config, infra/deploy config, and env templates.
Decide the project 'type' (web-app | api | static-site | cli | library | mobile | other) and the booleans in the schema.
Then, from this domain list, return 'applicableDomains' (the keys that genuinely apply) and 'naReasons' (one short reason per key you excluded):
${domainList}
Ground every judgement in files you actually read.`,
  { schema: PROFILE_SCHEMA, label: 'profile', phase: 'Profile' },
)

const applicable = DOMAINS.filter(d => profile.applicableDomains.includes(d.key))
const naDomains = DOMAINS.filter(d => !applicable.includes(d))
  .map(d => ({ key: d.key, title: d.title,
    reason: (profile.naReasons.find(n => n.domain === d.key) || {}).reason || 'not applicable to this project type' }))
log(`Profile: ${profile.type}. Auditing ${applicable.length}/${DOMAINS.length} domains.`)

// --- Phases 1+2: audit each applicable domain, then verify its serious findings ---
const auditPrompt = (d) =>
  `You are a "${d.title}" production-readiness auditor. Project profile: ${JSON.stringify(profile)}. Project directory: ${projectDir}.
Audit ONLY your domain. For each checklist item, inspect the REAL code (read/grep under ${projectDir}) and cite path:line in 'evidence'. NEVER assert a gap without having looked. Also surface gaps beyond the checklist as extra findings.
Use status 'na' (severity 'none') for items that don't apply to this project, with a one-line reason in evidence.
Checklist:
${d.checklist.map((c, i) => `${i + 1}. ${c}`).join('\n')}
Return findings per the schema.`

const verifyFindings = async (res, d) => {
  if (!res) return { domain: d.key, findings: [] }
  const serious = res.findings.filter(f =>
    (f.severity === 'critical' || f.severity === 'high') && (f.status === 'missing' || f.status === 'partial'))
  if (!serious.length) return { domain: d.key, findings: res.findings }
  const verdicts = await parallel(serious.map(f => () =>
    agent(`Adversarially REFUTE this production-readiness finding for "${d.title}" in ${projectDir}.
Finding: "${f.check}", claimed ${f.status} (${f.severity}). Stated evidence: ${f.evidence}.
Search the codebase to prove the claim WRONG (e.g. the protection actually exists). Default refuted=false if you cannot disprove it. Cite path:line.`,
      { schema: REFUTE_SCHEMA, label: `verify:${d.key}`, phase: 'Verify' })
      .then(v => ({ f, v }))))
  const refutedSet = new Set(verdicts.filter(Boolean).filter(x => x.v && x.v.refuted).map(x => x.f.check))
  const findings = res.findings.map(f => refutedSet.has(f.check)
    ? { ...f, status: 'pass', severity: 'none', evidence: `${f.evidence}, overturned on verification` }
    : f)
  return { domain: d.key, findings }
}

phase('Audit')
const audited = await pipeline(
  applicable,
  d => agent(auditPrompt(d), { schema: FINDINGS_SCHEMA, label: `audit:${d.key}`, phase: 'Audit' }),
  (res, d) => verifyFindings(res, d),
)

// --- Phase 3: synthesize ---
phase('Synthesize')
const allFindings = audited.filter(Boolean).flatMap(a =>
  a.findings.map(f => ({ domain: a.domain, ...f })))
const synth = await agent(
  `You are synthesizing a production-readiness report (ADVISORY, no go/no-go verdict). Project: ${repo || projectDir}.
Here are all verified findings across domains as JSON:
${JSON.stringify(allFindings)}
Dedup findings that describe the same gap across domains. Rank by severity. Produce:
- executiveSummary (plain language, a few sentences),
- whatsSolid (things already done well),
- topRisks (the few most important gaps),
- severityCounts (count of critical/high/medium/low among status missing|partial),
- backlog: the deduped, severity-ordered list of actionable gaps (status missing|partial only), each ready to become a GitHub issue.`,
  { schema: SYNTH_SCHEMA, label: 'synthesize', phase: 'Synthesize' },
)

// Deterministic post-processing: on the first real run the model's own
// severityCounts undercounted (14 vs 21 high) and a few status:'pass' items
// leaked into the backlog. Recompute both from the data so the report is exact.
const cleanBacklog = (synth.backlog || []).filter(b => b.status === 'missing' || b.status === 'partial')
const severityCounts = { critical: 0, high: 0, medium: 0, low: 0 }
for (const b of cleanBacklog) {
  if (severityCounts[b.severity] !== undefined) severityCounts[b.severity]++
}
const report = { ...synth, backlog: cleanBacklog, severityCounts }

return { profile, applicable: applicable.map(d => d.key), naDomains, report }
