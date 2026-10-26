export const meta = {
  name: 'production-audit',
  description: 'Audit a project for production readiness: profile, run 19 domain auditors four at a time, adversarially verify serious findings, synthesize an advisory report.',
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
// focus (optional string): what the person asked to be weighed more heavily. It ADDS emphasis to the
// profiler and to every auditor and never removes a checklist item, so the legal coverage no longer
// depends on somebody remembering to type it (claude-config#1753). Before this it existed only in a
// hand edited staged copy of this script.
const focus = typeof _a.focus === 'string' ? _a.focus.trim() : ''
// outsideSystems (optional list of names): systems OUTSIDE the repo that email, text or call
// consumers (a CRM's templates, an automation tool, a dialer), as the person named them when the
// audit was framed. The profiler cannot see them in the code, which is how a 2026-10-24 audit set
// sendsEmail false for a business that emails consumers from several outside systems.
const outsideSystems = Array.isArray(_a.outsideSystems) ? _a.outsideSystems.filter(x => typeof x === 'string' && x.trim()) : []
const focusLine = focus
  ? `\nThe person who started this audit asked for extra attention on: ${focus}. This adds to your checklist; it never replaces any item.`
  : ''

// At most four agents run at once, Dan's standing rule for every session (2026-10-16). The engine's
// own cap is min(16, cores - 2), so before this the 19 auditors and their refuters ran up to 16 at
// once and a 2026-10-24 run had to be batched in fours by hand. Every agent the audit and verify
// phases start goes through this gate; a slot is freed however its agent ends, a throw included.
const MAX_AGENTS_AT_ONCE = 4
let _running = 0
const _waiting = []
const limitedAgent = async (prompt, opts) => {
  if (_running >= MAX_AGENTS_AT_ONCE) await new Promise(resolve => _waiting.push(resolve))
  else _running++
  try {
    return await agent(prompt, opts)
  } finally {
    const next = _waiting.shift()
    if (next) next() // the slot passes straight to the next waiter, so the count never dips and refills
    else _running--
  }
}

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
    'Encryption at rest for sensitive data',
    'Third party resources: fonts, scripts, pixels and embeds fetched from third party servers hand every visitor IP to that party (Google Fonts loaded from Google is the common case); self host them or disclose them, and name each one',
    'Trackers and analytics load only after consent where consent is required, and honour an opt out once given',
    'Session recording and replay tools mask form inputs and personal data, and are disclosed (CIPA and state wiretap laws treat an undisclosed recording of what a visitor types as interception)' ] },
  { key: 'compliance-audit', title: 'Compliance, Audit & Legal', checklist: [
    'Regulatory compliance posture (GDPR/CCPA/etc.)',
    'Audit trails for sensitive actions',
    'Tamper-evident logging',
    'Privacy policy, cookie consent, ToS present',
    'Commercial email (CAN-SPAM), from EVERY system that emails consumers, inside the repo or outside it (CRM templates, automation tools): a valid postal address in every message; an unsubscribe that needs nothing but the email address; opt outs honoured within 10 business days and written to the field EVERY sender reads, so an unsubscribe recorded in one system stops mail from all of them; a one click List-Unsubscribe header for bulk senders. Name each outside system you could not inspect in notInspected',
    'Calls and texts (TCPA): the consent wording shown before a number is collected, how consent is captured, and proof of what the person was shown and when, kept for every consented number; quiet hours and opt out keywords for texts',
    'Opt out signals: Global Privacy Control is detected and honoured as an opt out of sale and sharing, and a do not sell or share link is present where state law requires one',
    'Children (COPPA): an age gate or a clear statement where the product could reach anyone under 13',
    'Subscriptions (state auto renewal laws): renewal terms shown clearly beside the purchase button, affirmative consent to them, and cancellation as easy as sign up',
    'User uploads: terms covering uploaded content, a takedown process, and a registered DMCA agent',
    'Sector rules from the profile: for a financial product GLBA (privacy notice and safeguards), FCRA (permissible purpose and adverse action notices where credit data is used), TILA (credit terms disclosed) and UDAAP (no unfair, deceptive or abusive claims); for health data HIPAA. Mark each na with the reason when the sector does not apply' ] },
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
    'WCAG 2.1 AA conformance for UI, graded as legal exposure (ADA lawsuits against public sites) as well as usability; tag a gap with law ADA on a public site',
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
  // consumerMessaging is required so an empty list is the profiler's answer, never a field it skipped.
  required: ['type', 'consumerMessaging', 'applicableDomains', 'naReasons'],
  properties: {
    type: { type: 'string' },
    stack: { type: 'string' },
    hosting: { type: 'string' },
    hasDatabase: { type: 'boolean' },
    multiTenant: { type: 'boolean' },
    handlesPII: { type: 'boolean' },
    sendsEmail: { type: 'boolean' },
    sendsEmailFromRepo: { type: 'boolean' },
    consumerMessaging: { type: 'array', items: {
      type: 'object', additionalProperties: false,
      required: ['system', 'channels', 'inRepo', 'evidence'],
      properties: {
        system: { type: 'string' },
        channels: { type: 'array', items: { type: 'string', enum: ['email', 'sms', 'call'] } },
        inRepo: { type: 'boolean' },
        evidence: { type: 'string' } } } },
    financialProduct: { type: 'boolean' },
    healthData: { type: 'boolean' },
    mayReachChildren: { type: 'boolean' },
    sellsSubscriptions: { type: 'boolean' },
    acceptsUserUploads: { type: 'boolean' },
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
// law: the law a gap exposes the business to (CAN-SPAM, TCPA, ADA, ...), empty when none. It is the
// "lawsuit risk" tag the 2026-10-24 report had to add by hand, and it rides on every finding into the
// backlog so the issue filed from it says which law is at stake.
const FINDING_PROPS = {
  check: { type: 'string' },
  law: { type: 'string' },
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
    // What the auditor could not look at (an outside system, a dashboard setting), with why. A system
    // it could not inspect is reported, never graded as passing because nothing was found.
    notInspected: { type: 'array', items: {
      type: 'object', additionalProperties: false,
      required: ['system', 'reason'],
      properties: { system: { type: 'string' }, reason: { type: 'string' } } } },
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
Consumer messaging is judged for the BUSINESS, not the repo: much consumer email, text and calling goes out from systems outside the code (CRM templates, marketing and automation tools, dialers), and a repo that sends nothing itself is no evidence that nobody is emailed. So:
- sendsEmailFromRepo: true only when this code itself sends email.
- sendsEmail: true when the business emails consumers from ANY system, in this repo or outside it.
- consumerMessaging: one entry per system, in the repo or outside it, that emails, texts or calls consumers, with inRepo and the evidence (path:line, or "named by the person"). Look for SDKs, API keys in env templates, webhooks, and integration names in docs and config. An empty list means you looked and found none.${outsideSystems.length ? `\nThe person who started the audit named these outside systems as ones that email, text or call consumers; include each: ${outsideSystems.join(', ')}.` : ''}
- financialProduct, healthData, mayReachChildren (anyone under 13), sellsSubscriptions, acceptsUserUploads: what the product does, from the code and its copy.${focusLine}
Then, from this domain list, return 'applicableDomains' (the keys that genuinely apply) and 'naReasons' (one short reason per key you excluded):
${domainList}
Ground every judgement in files you actually read.`,
  { schema: PROFILE_SCHEMA, label: 'profile', phase: 'Profile' },
)

// The legal domains are never left to the profiler's say so on a product the public can reach, that
// holds personal data, or that messages consumers: the 2026-10-24 profiler reasoned "the repo sends
// no email", and an exclusion like that is exactly what a rule stated only in a prompt cannot stop (L27).
const LEGAL_DOMAINS = ['compliance-audit', 'data-isolation-pii']
const legalExposure = profile.isPublic === true || profile.handlesPII === true || profile.sendsEmail === true
  || (Array.isArray(profile.consumerMessaging) && profile.consumerMessaging.length > 0)
if (legalExposure) {
  for (const key of LEGAL_DOMAINS) {
    if (!profile.applicableDomains.includes(key)) {
      const why = (profile.naReasons.find(n => n.domain === key) || {}).reason || 'no reason given'
      log(`Profile excluded ${key} ("${why}"), kept: the product is public, holds personal data or messages consumers.`)
      profile.applicableDomains.push(key)
    }
  }
}
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
Set 'law' on a finding to the law its gap exposes the business to (for example CAN-SPAM, TCPA, CIPA, COPPA, ADA, GLBA, FCRA, GDPR, CCPA), or an empty string when it exposes none.
Anything your domain covers that you could not inspect (a system outside the repo, a dashboard setting), list in 'notInspected' with the reason. Never grade what you could not see as passing.${focusLine}
Checklist:
${d.checklist.map((c, i) => `${i + 1}. ${c}`).join('\n')}
Return findings per the schema.`

const verifyFindings = async (res, d) => {
  if (!res) return { domain: d.key, findings: [] }
  const serious = res.findings.filter(f =>
    (f.severity === 'critical' || f.severity === 'high') && (f.status === 'missing' || f.status === 'partial'))
  if (!serious.length) return { domain: d.key, findings: res.findings }
  const verdicts = await parallel(serious.map(f => () =>
    limitedAgent(`Adversarially REFUTE this production-readiness finding for "${d.title}" in ${projectDir}.
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
  d => limitedAgent(auditPrompt(d), { schema: FINDINGS_SCHEMA, label: `audit:${d.key}`, phase: 'Audit' }),
  async (res, d) => {
    // A dead auditor is an unaudited domain, never a clean one: verifyFindings alone turns a null
    // into an empty findings list, which reads exactly like a domain with nothing wrong.
    const verified = await verifyFindings(res, d)
    return { ...verified, audited: !!res, notInspected: (res && Array.isArray(res.notInspected)) ? res.notInspected : [] }
  },
)
const unauditedDomains = applicable.filter((d, i) => !audited[i] || !audited[i].audited).map(d => d.key)
for (const k of unauditedDomains) log(`UNAUDITED: the ${k} auditor returned nothing, so that domain was not checked.`)

// Everything that could not be inspected: the auditors' own lists, plus every consumer messaging
// system the profile found that no compliance or personal data finding names at all, so an outside
// sender nobody looked at is reported rather than silently passing.
const notInspected = []
audited.forEach((a, i) => {
  if (!a) return
  for (const n of a.notInspected) notInspected.push({ system: n.system, reason: n.reason, domain: applicable[i].key })
})
const legalText = audited.filter(a => a && LEGAL_DOMAINS.includes(a.domain))
  .flatMap(a => [...a.findings.map(f => `${f.check} ${f.evidence}`), ...a.notInspected.map(n => n.system)])
  .join('\n').toLowerCase()
for (const m of (profile.consumerMessaging || [])) {
  if (!m || !m.system) continue
  if (!legalText.includes(String(m.system).toLowerCase())) {
    notInspected.push({ system: m.system, reason: 'it emails, texts or calls consumers, and no auditor reported on it', domain: 'compliance-audit' })
  }
}

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
- backlog: the deduped, severity-ordered list of actionable gaps (status missing|partial only), each ready to become a GitHub issue. Keep each finding's 'law' on its backlog item; when you merge findings, keep every law they named.`,
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
// A law named on an open input finding but on no backlog item was dropped by synthesis: the issue
// filed from it would not say which law is at stake, so it is reported rather than lost quietly.
const lawsIn = (list) => new Set(list.map(f => (f.law || '').trim()).filter(Boolean))
const backlogLaws = lawsIn(cleanBacklog)
const lawTagsLost = [...lawsIn(allFindings.filter(f => f.status === 'missing' || f.status === 'partial'))]
  .filter(l => !backlogLaws.has(l)).sort()
if (lawTagsLost.length) log(`Synthesis dropped the law tag from every finding naming: ${lawTagsLost.join(', ')}.`)
const report = { ...synth, backlog: cleanBacklog, severityCounts, lawTagsLost, notInspected, unauditedDomains }

return { profile, applicable: applicable.map(d => d.key), naDomains, report }
