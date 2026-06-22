# /production-ready Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a global, user-invoked `/production-ready` skill that audits a project against a broad production-readiness checklist using many parallel specialist agents, adversarially verifies the serious findings, and produces a severity-ranked advisory report that can be filed as GitHub issues.

**Architecture:** Mirrors `plan-council` — a `SKILL.md` runs the framing conversation, launches a Workflow, presents results, and files issues; `production-audit.workflow.js` runs the real multi-agent work (profile → 19 parallel domain auditors → adversarial verify → synthesize). A `healthcheck.sh` is the test harness, validating frontmatter + that the workflow parses.

**Tech Stack:** Markdown (SKILL.md), JavaScript (Workflow engine script — plain JS, no TypeScript, no `Date.now()`/`Math.random()`), Bash (healthcheck), `gh` CLI for issue filing, shared `~/.claude/skills/milestone/create-milestone.sh`.

## Global Constraints

- Location: `~/.claude/skills/production-ready/` (global skill).
- `~/.claude` is NOT a git repo: SKIP all `git add`/`git commit` steps; "commit" = the file is saved. The pre-push test gate does not apply.
- `SKILL.md` frontmatter MUST include `name: production-ready`, `disable-model-invocation: true`, and `allowed-tools: Read, Glob, Grep, Bash, WebFetch, AskUserQuestion, Workflow, Agent`.
- Workflow script: must `export const meta` as a PURE LITERAL with `name`, `description`, `phases`; no `Date.now()`/`Math.random()`/argless `new Date()`; date arrives via `args.date`.
- Decisions (verbatim from DESIGN.md, locked): read-only against audited code; auto-detect & tailor scope (N/A with reason); advisory only (no go/no-go); deep every run (all 19 auditors); split-finer 19 domains; include adversarial verify pass; file issues in the AUDITED repo labeled by domain + severity.
- Report saved to `docs/production-readiness/<date>-report.md` in the target repo, NOT committed by the skill.

---

### Task 1: Test harness + SKILL.md frontmatter

**Files:**
- Create: `~/.claude/skills/production-ready/healthcheck.sh`
- Create: `~/.claude/skills/production-ready/SKILL.md` (frontmatter + title only this task)

**Interfaces:**
- Produces: `healthcheck.sh` — exits 0 when all files are valid, non-zero with a message otherwise. Re-run after every later task.

- [ ] **Step 1: Write the failing test (`healthcheck.sh`)**

```bash
#!/usr/bin/env bash
# Validates the production-ready skill is well-formed. Run from anywhere.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail() { echo "HEALTHCHECK FAIL: $1" >&2; exit 1; }

# 1. SKILL.md exists with required frontmatter
SKILL="$DIR/SKILL.md"
[ -f "$SKILL" ] || fail "SKILL.md missing"
head -20 "$SKILL" | grep -q '^name: production-ready$' || fail "frontmatter missing 'name: production-ready'"
head -20 "$SKILL" | grep -q '^disable-model-invocation: true$' || fail "frontmatter missing disable-model-invocation"
head -20 "$SKILL" | grep -q '^allowed-tools:.*Workflow' || fail "frontmatter missing allowed-tools with Workflow"

# 2. Workflow script parses and declares meta.phases
WF="$DIR/production-audit.workflow.js"
[ -f "$WF" ] || fail "workflow script missing"
node --check "$WF" || fail "workflow script does not parse"
grep -q 'phases:' "$WF" || fail "workflow meta missing phases"

# 3. SKILL.md body documents the key sections
for marker in "## 1." "Workflow" "production-audit.workflow.js" "AskUserQuestion" "gh issue create"; do
  grep -qF "$marker" "$SKILL" || fail "SKILL.md missing section/marker: $marker"
done

echo "HEALTHCHECK OK"
```

- [ ] **Step 2: Make it executable and run it to verify it fails**

Run: `chmod +x ~/.claude/skills/production-ready/healthcheck.sh && ~/.claude/skills/production-ready/healthcheck.sh`
Expected: FAIL with `HEALTHCHECK FAIL: SKILL.md missing` (no files yet).

- [ ] **Step 3: Create `SKILL.md` with valid frontmatter + title (minimal)**

```markdown
---
name: production-ready
description: Audit a project against a broad production-readiness checklist before sharing it — many parallel specialist auditor agents grade security, data/privacy, testing, reliability, observability, deployment, DR, cost, accessibility, and docs; serious findings are adversarially verified; produces a severity-ranked advisory report and, on approval, files prioritized GitHub issues in the audited repo. User-invoked only (spawns many agents).
disable-model-invocation: true
allowed-tools: Read, Glob, Grep, Bash, WebFetch, AskUserQuestion, Workflow, Agent
---

# production-ready
```

- [ ] **Step 4: Run the test to confirm the frontmatter checks pass (workflow check still fails)**

Run: `~/.claude/skills/production-ready/healthcheck.sh`
Expected: FAIL with `HEALTHCHECK FAIL: workflow script missing` (frontmatter checks now pass; we've advanced past them).

- [ ] **Step 5: "Commit"** — `~/.claude` is not a git repo, so no commit. Files are saved; proceed.

---

### Task 2: The audit workflow (`production-audit.workflow.js`)

**Files:**
- Create: `~/.claude/skills/production-ready/production-audit.workflow.js`

**Interfaces:**
- Consumes: `args = { projectDir: string, repo: string, date: string, mode?: string }` (provided by SKILL.md in Task 3).
- Produces: returns `{ profile, applicable, naDomains, report }` where `report = { executiveSummary, whatsSolid[], topRisks[], severityCounts{critical,high,medium,low}, backlog[] }` and each backlog item is `{ domain, check, status, severity, evidence, remediation, effort }`. The `status` enum is `pass|partial|missing|na`; `severity` is `critical|high|medium|low|none`; `effort` is `S|M|L`.

- [ ] **Step 1: Write the full workflow script**

```javascript
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

const { projectDir, repo, date, mode } = args || {}
if (!projectDir) throw new Error('args.projectDir is required')

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
    'Environment parity (staging ≈ prod)',
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
Finding: "${f.check}" — claimed ${f.status} (${f.severity}). Stated evidence: ${f.evidence}.
Search the codebase to prove the claim WRONG (e.g. the protection actually exists). Default refuted=false if you cannot disprove it. Cite path:line.`,
      { schema: REFUTE_SCHEMA, label: `verify:${d.key}`, phase: 'Verify' })
      .then(v => ({ f, v }))))
  const refutedSet = new Set(verdicts.filter(Boolean).filter(x => x.v && x.v.refuted).map(x => x.f.check))
  const findings = res.findings.map(f => refutedSet.has(f.check)
    ? { ...f, status: 'pass', severity: 'none', evidence: `${f.evidence} — overturned on verification` }
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
  `You are synthesizing a production-readiness report (ADVISORY — no go/no-go verdict). Project: ${repo || projectDir}.
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

return { profile, applicable: applicable.map(d => d.key), naDomains, report: synth }
```

- [ ] **Step 2: Run the test to verify it now passes the parse + phases checks**

Run: `~/.claude/skills/production-ready/healthcheck.sh`
Expected: FAIL with `HEALTHCHECK FAIL: SKILL.md missing section/marker: ## 1.` (parse + `phases:` checks now pass; only the SKILL.md body markers remain — that's Task 3).

- [ ] **Step 3: "Commit"** — save only (no git). Proceed.

---

### Task 3: SKILL.md body (framing → launch → present → file issues)

**Files:**
- Modify: `~/.claude/skills/production-ready/SKILL.md` (append body after the title)

**Interfaces:**
- Consumes: the workflow's return shape from Task 2 (`{ profile, applicable, naDomains, report }`).
- Produces: the runbook the main agent follows when the user invokes `/production-ready`.

- [ ] **Step 1: Append the body to `SKILL.md`**

````markdown

A heavyweight, user-invoked production-readiness auditor. A panel of independent specialist agents each grade one domain against the real codebase; serious gaps are adversarially verified; the result is a severity-ranked **advisory** report (no ship/no-ship gate) that, on your approval, becomes GitHub issues in the audited repo.

Gates marked 👤 require the user before continuing.

## 1. Frame the audit  👤
In conversation with the user, establish:
- The **target project directory** (absolute path, so agents read the right repo).
- The **GitHub repo** (`owner/name`) where issues will be filed (the audited repo).
- Any **known focus or exclusions** (e.g. "skip accessibility, it's an internal API").

Take a quick read of the repo (CLAUDE.md, manifest) so you can confirm the project type you expect. Then present the plan — "I'll run 19 domain auditors in parallel, verify the serious findings, and produce an advisory report" — and get a go-ahead with **AskUserQuestion**. This is heavy and spawns many agents, so confirm before launching.

## 2. Run the audit (Workflow engine)
Call the **Workflow** tool with:

    {
      scriptPath: "/Users/danhankins-wright/.claude/skills/production-ready/production-audit.workflow.js",
      args: {
        projectDir: "<absolute path to the repo>",
        repo: "<owner/name>",
        date: "<today's date YYYY-MM-DD>"
      }
    }

Pass `date` from your own context — the workflow engine cannot read the clock. It returns `{ profile, applicable, naDomains, report }`, where `report = { executiveSummary, whatsSolid, topRisks, severityCounts, backlog }`.

## 3. Save the report
Render a markdown report from the return value (executive summary, what's solid, top risks, severity counts, the N/A domains with reasons, then the full backlog grouped by domain with status/severity/evidence/remediation/effort). Save it to `docs/production-readiness/<date>-report.md` in the **target** repo. Do NOT commit it — tell the user it's there for review.

## 4. Present  👤
Give a plain-language summary for a product manager: how many critical/high/medium/low gaps, what's already solid, the top risks, and any domains skipped as N/A (with why). If the profile suggests grounding was partial (repo unreadable), say so. Advisory only — do not declare anything ship-blocking.

## 5. File issues  👤
Offer, via **AskUserQuestion**, to file the backlog as GitHub issues in the audited repo. On approval:
1. Ensure labels exist (create missing ones), one per domain key plus severity labels:

       gh label create "severity:critical" --color B60205 --description "Production-readiness: critical" 2>/dev/null || true
       gh label create "severity:high"     --color D93F0B --description "Production-readiness: high"     2>/dev/null || true
       gh label create "severity:medium"   --color FBCA04 --description "Production-readiness: medium"   2>/dev/null || true
       gh label create "severity:low"       --color 0E8A16 --description "Production-readiness: low"       2>/dev/null || true
       gh label create "production-readiness" --color 5319E7 --description "Found by /production-ready"    2>/dev/null || true

2. File one issue per backlog item (group tightly-related items into one issue to avoid spam — especially `low` severity, which you may group by domain). Title = imperative summary; body = the gap, why it matters, the remediation direction, and the `path:line` evidence. Label with `production-readiness`, the matching `severity:*`, and the domain. **Never** apply any Claude/AI-attribution label.

       gh issue create --repo "<owner/name>" --title "<title>" --body "<body>" \
         --label "production-readiness" --label "severity:high"

3. If `gh` is not installed/authenticated or the repo isn't resolvable, skip filing and tell the user — the saved report still captures everything.

## 6. Offer a tracking milestone  👤
Optionally offer (AskUserQuestion) to group the issues under a GitHub milestone via the shared helper:

    DRY_RUN=1 bash ~/.claude/skills/milestone/create-milestone.sh "<owner/name>" <plan.json>   # preview
    bash ~/.claude/skills/milestone/create-milestone.sh "<owner/name>" <plan.json>             # create

## Notes
- **Cost is intended.** 19 domain auditors + a profiler + per-finding refute agents + a synthesizer is a lot of subagents per run. That depth is the point; it is why this is user-invoked only.
- **Grounding is mandatory.** Every auditor is told to read real code and cite `path:line`; the verify pass exists to overturn false "missing" findings.
- **First run = the prototype.** Expect to tune severity calibration and domain checklists after the first real audit.
````

- [ ] **Step 2: Run the test to verify everything passes**

Run: `~/.claude/skills/production-ready/healthcheck.sh`
Expected: `HEALTHCHECK OK`

- [ ] **Step 3: "Commit"** — save only (no git). Skill is complete.

---

### Task 4: First real-run prototype (manual, user-driven)

**Files:** none (validation only).

- [ ] **Step 1: Pick a target.** Ask the user which repo to audit first (e.g. Bidspoke). Confirm `gh auth status` succeeds for that repo's owner.
- [ ] **Step 2: Invoke `/production-ready`** against that repo and walk the gates.
- [ ] **Step 3: Sanity-check the output** — do auditors cite real `path:line`s? Did the verify pass overturn any false alarms? Is the severity split sensible?
- [ ] **Step 4: Tune** the `DOMAINS` checklists / severity guidance in `production-audit.workflow.js` based on what the first run got wrong, and update DESIGN.md's "open items" accordingly.

---

## Self-Review

**1. Spec coverage:** profile/tailor (Task 2 Phase 0 + naDomains) ✓; 19 split-finer domains (Task 2 DOMAINS) ✓; deep-every-run (no quick mode) ✓; adversarial verify (Task 2 `verifyFindings`) ✓; advisory only — no go/no-go (synth prompt + present step) ✓; read-only against code (auditors only read/grep; no edits) ✓; report saved to `docs/production-readiness/<date>-report.md`, not committed (Task 3 step 3) ✓; file issues in audited repo, domain + severity labels, no AI label (Task 3 step 5) ✓; optional milestone via shared helper (Task 3 step 6) ✓; healthcheck as the test (Task 1) ✓.

**2. Placeholder scan:** `<owner/name>`, `<title>`, `<body>`, `<date>` are runtime values the skill fills, not plan placeholders — acceptable. No "TODO"/"implement later" in code steps.

**3. Type consistency:** `status` enum `pass|partial|missing|na`, `severity` `critical|high|medium|low|none`, `effort` `S|M|L` consistent across FINDING_PROPS, FINDINGS_SCHEMA, SYNTH_SCHEMA, and the return shape documented in Task 2 interfaces and consumed in Task 3. `verifyFindings` downgrades to `status:'pass', severity:'none'` (both valid enum values). Workflow return `{ profile, applicable, naDomains, report }` matches Task 3's consume block.
