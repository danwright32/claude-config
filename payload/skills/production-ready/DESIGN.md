# /production-ready: design spec

**Status:** approved-pending-review · **Date:** 2026-06-22

A global, user-invoked skill that audits a project against a broad production-readiness
checklist before it is shared. It fans out many independent specialist auditor agents
(one per concern domain), grounds every finding in the real code, adversarially
verifies the serious ones, and produces a severity-ranked advisory report, then, on
approval, files the gaps as GitHub issues in the audited repo.

Modeled on the existing `plan-council` skill: a `SKILL.md` that runs the framing
conversation and presents results + a Workflow script that runs the real multi-agent
work through genuinely independent subagents.

---

## Decisions (locked with the user)

1. **Output:** read-only graded report → on approval, file prioritized GitHub issues
   (optionally a milestone). Never modifies the audited code.
2. **Scope:** auto-detect project type and tailor which domains apply; non-applicable
   domains are reported as **N/A with a reason**, never silently dropped.
3. **Verdict:** advisory severity ranking, **no** hard go/no-go gate.
4. **Depth:** deep multi-agent every run (user-invoked; cost is intentional).
5. **Granularity:** split finer, ~19 focused auditor domains rather than ~10 broad ones.
6. **Verification:** include an adversarial verify pass on high-severity findings.
7. **Issue target:** the audited repo (owner/name gathered at framing).

---

## Architecture

```
~/.claude/skills/production-ready/
├── SKILL.md                     # framing conversation, launch, present, file issues
├── production-audit.workflow.js # the multi-agent engine (Workflow tool)
├── healthcheck.sh               # validates frontmatter + that the workflow script parses
└── DESIGN.md                    # this file
```

Reuses `~/.claude/skills/milestone/create-milestone.sh` for the optional milestone.

`SKILL.md` frontmatter: `disable-model-invocation: true` (user-invoked only),
`allowed-tools: Read, Glob, Grep, Bash, WebFetch, AskUserQuestion, Workflow, Agent`.

---

## Workflow phases (`production-audit.workflow.js`)

The workflow receives `args = { projectDir, repo, date, mode }` and returns a structured
result the SKILL renders + files.

### Phase 0: Profile & preflight
One agent reads the repo (CLAUDE.md, package manifest, framework files, infra/deploy
config, CI config, env templates) and emits a **project profile**:

- `type`: web-app | api | static-site | cli | library | mobile | other
- `stack`, `hosting` (e.g. Cloudflare Workers, Supabase, Vercel), `hasDatabase`,
  `multiTenant`, `handlesPII`, `sendsEmail`, `hasAuth`, `isPublic`, `usesCI`
- `applicableDomains`: which of the ~19 domains apply, and a one-line **reason** for each
  domain marked N/A.

Also a cheap reachability check: is the repo readable, is the GitHub repo resolvable
(`gh repo view`). Surfaced so the report can warn if grounding was partial.

### Phase 1: Parallel domain auditors
Fan out one specialist auditor per **applicable** domain. Each receives the profile +
`projectDir` + a domain-specific checklist embedded in its prompt, and is instructed to:

- **Ground every finding in real code**: read/grep the repo and cite `path:line`;
  never assert a gap without having looked.
- Also surface gaps **beyond** its checklist (the checklist is a floor, not a ceiling).
- Return findings against a fixed schema:
  `{ check, status: pass|partial|missing|na, severity: critical|high|medium|low,
     evidence: "path:line or why", remediation, effort: S|M|L }`

### Phase 2: Adversarial verification
For every **high or critical** finding with status `missing` or `partial`, spawn a
skeptic agent whose only job is to **refute** it by searching the codebase
(e.g. "auditor claims no rate limiting: prove there is some"). A finding that the
skeptic overturns is downgraded/dropped with a note. Keeps the report honest and
prevents false alarms (the classic "says auth is missing when it exists" failure).

### Phase 3: Synthesize
One synthesizer agent dedups findings across domains (the same missing security header
can surface in two auditors), ranks by severity, and produces:

- **Executive summary**: counts by severity, what's already solid, the top risks.
- **Per-domain sections**: each check with status, evidence, remediation, effort.
- **Prioritized remediation backlog**: flat, severity-ordered, ready to become issues.
- Any **grounding caveats** from preflight.

No go/no-go verdict (advisory, per decision 3).

---

## The ~19 auditor domains

Security is split into its constituent concerns (decision 5). Each maps to checks drawn
from the user's list plus the operability gaps research surfaced.

1. **Input, Injection & Web Hardening**: input validation/sanitization; SQL/NoSQL/command
   injection; XSS; CSRF; CORS; security headers (CSP, HSTS, X-Frame-Options); file-upload
   validation; webhook signature verification.
2. **Authentication & Sessions**: authN flows; session management; token expiry &
   rotation; MFA; credential/password storage; account-recovery safety.
3. **Authorization & Access Control**: authZ; roles & permissions; per-tenant access
   checks; privilege-escalation paths; default-deny.
4. **Secrets & Transport Security**: secrets management/rotation; HTTPS/TLS; cert
   rotation; secret/PII leakage in logs & error messages.
5. **Dependencies & Supply Chain**: dependency scanning; vulnerability patching cadence;
   OSS license compliance; lockfiles; SBOM/signed artifacts.
6. **Rate Limiting & Abuse Prevention**: rate limiting; abuse/bot prevention; DoS
   protection; per-request resource limits; quota enforcement.
7. **Data Isolation & PII**: multi-tenancy data isolation (e.g. RLS); PII inventory &
   handling; data retention & deletion policy; encryption at rest.
8. **Compliance, Audit & Legal**: regulatory compliance (GDPR/CCPA/etc.); audit trails &
   tamper-evident logging; privacy policy, cookie consent, ToS.
9. **Functional Testing**: unit, integration, e2e, regression tests; coverage thresholds
   enforced in CI.
10. **Load, Stress & Chaos**: load/stress testing; chaos engineering; resilience testing;
    capacity validation under failure.
11. **Code Review & Static Quality**: code review process & standards; linting;
    typechecking; static analysis; branch protection.
12. **Error Handling & Fault Tolerance**: error handling; graceful degradation; retry with
    backoff & idempotency; circuit breakers & fallback behavior.
13. **Concurrency & Caching**: concurrency handling & race-condition prevention; locking;
    caching strategy & invalidation correctness.
14. **Observability & Incident Response**: structured logging; metrics; tracing;
    dashboards; alerting; on-call runbooks; health/readiness checks; SLOs/error budgets;
    error tracking (Sentry-style).
15. **Deployment & Release**: CI/CD pipeline; zero-downtime deploys; rollback; canary/
    blue-green; environment parity (staging≈prod); feature flags; config management.
16. **DR, Backups & Continuity**: RTO/RPO; disaster recovery plan; backups + **tested**
    restores; DB migration safety; graceful shutdown (SIGTERM).
17. **Cost, Capacity & Performance**: cost monitoring & budget alerts; capacity planning;
    autoscaling; performance/latency budgets.
18. **Accessibility**: WCAG conformance; keyboard nav; screen-reader semantics; contrast;
    focus management. (N/A for non-UI projects.)
19. **Documentation & Architecture**: ADRs; architecture diagrams; API contracts &
    versioning; README/runbooks/onboarding docs.

Auditors run concurrently up to the Workflow engine's cap (~min(16, cores−2)); the rest
queue and still complete. Heavy by design (decision 4).

---

## Output & record (SKILL.md)

1. Save the report to `docs/production-readiness/<date>-report.md` in the target repo
   (date passed in via `args.date`; the SKILL has the current date: the workflow engine
   cannot call `Date.now()`). **Not auto-committed**: the user reviews it first.
2. Plain-language summary in chat (PM-friendly): counts by severity, what's solid, top
   risks, any grounding caveats.
3. On approval via **AskUserQuestion**, file one GitHub issue per finding (grouping tightly
   related ones), in the **audited repo**, labeled by **domain** + **severity**
   (`severity:critical`, etc.). Create missing labels first (`gh label create`). Never
   apply any Claude/AI-attribution label.
4. Optionally offer a tracking **milestone** via the shared `create-milestone.sh`
   (`DRY_RUN=1` preview first).
5. If `gh` is unavailable or the dir isn't a GitHub repo: skip filing, just deliver the
   report so findings can be captured manually.

---

## Testing approach (test-first where it fits)

- **`healthcheck.sh`** (the testable unit): asserts `SKILL.md` has valid frontmatter with
  `name: production-ready`, that `production-audit.workflow.js` parses (`node --check`),
  and that `meta.phases` is present. Written before the workflow, à la
  `plan-council/healthcheck.sh`. Runnable in CI / locally.
- The workflow's agent logic is exercised by a real first run against an actual project
  (the user's call which repo): treated as the prototype run, like plan-council.
- Issue-filing reuses the already-tested `create-milestone.sh` for milestones; the
  per-finding `gh issue create` path is thin and validated on the first real run with a
  dry preview.

---

## Open items for the first real run

- Tune severity calibration per domain after seeing one real report.
- Decide whether very-low-value findings should be summarized rather than each filed as
  an issue (avoid issue spam): likely group by domain.
- Confirm the report directory `docs/production-readiness/` is acceptable per target repo.
