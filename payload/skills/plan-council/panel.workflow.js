export const meta = {
  name: 'plan-council',
  description: 'Independent role-agents propose rival whole approaches, champion + red-team them, score against fixed criteria, and synthesize the BEST (not merely doable) plan, then reality-check it against the real codebase.',
  phases: [
    { title: 'Preflight' },
    { title: 'Independent passes' },
    { title: 'Distill options' },
    { title: 'Champion + red-team' },
    { title: 'Score & select' },
    { title: 'Synthesize' },
    { title: 'Reality-check' },
    { title: 'Lessons audit' },
    { title: 'Fix & reverify' },
    { title: 'Revise' },
  ],
}

// args (set by the plan-panel skill after the framing conversation):
//   { feature, constraints, weightedCriteria, roles:[{key,brief}], projectDir, repo }
// args may arrive already-parsed (object) or as a JSON string depending on the
// launch path — normalize so the framing inputs are never silently dropped.
let a
try {
  a = (typeof args === 'string' && args.trim())
    ? JSON.parse(args)
    : (args && typeof args === 'object' ? args : {})
} catch (e) {
  throw new Error(
    `plan-council ABORT (before any agent ran): args was a string but not valid JSON — ${e.message}. ` +
    `Nothing was spawned, no tokens burned. Re-launch passing args as a JSON object/string ` +
    `{feature, constraints, weightedCriteria, roles, projectDir, repo}.`
  )
}

// FAILSAFE: refuse to run blind. If the framing never reached the script (feature
// missing/empty), abort NOW — before the preflight or any role agent — so a missing
// spec costs ~0 tokens instead of a full multi-agent run against a vacuum.
if (!a.feature || !String(a.feature).trim()) {
  throw new Error(
    'plan-council ABORT (before any agent ran): no `feature` supplied — the framing step was ' +
    'skipped or args failed to reach the script. Refusing to spawn the panel and burn tokens. ' +
    'Expected args: {feature, constraints, weightedCriteria, roles:[{key,brief,agentType}], projectDir, repo}.'
  )
}
const feature = a.feature || 'UNSPECIFIED FEATURE — framing step was skipped'
const constraints = a.constraints || 'none captured'
const criteria = a.weightedCriteria ||
  'correctness & robustness (HIGHEST — right beats fast) · user impact (high) · cost / recurring spend (high — prefer free; a paid option must clearly earn its bill) · maintainability (high) · risk & reversibility (medium) · NOTE: build time / effort is explicitly NOT a criterion — never weight how long an option takes to build'
const roles = (a.roles && a.roles.length) ? a.roles : [
  { key: 'architect', brief: 'overall architecture, system fit, long-term maintainability', agentType: 'plan-architect' },
  { key: 'product', brief: 'is this the right thing for the customer; real value vs scope', agentType: 'plan-product' },
  { key: 'backend', brief: 'APIs, business logic, service boundaries, integrations', agentType: 'plan-backend' },
  { key: 'frontend', brief: 'UI implementation, client state, component design', agentType: 'plan-frontend' },
  { key: 'ux', brief: 'interaction craft, UI states, accessibility, clarity', agentType: 'plan-ux' },
  { key: 'data', brief: 'database schema, migrations, data integrity, query cost', agentType: 'plan-data' },
  { key: 'security', brief: 'authz/authn, data exposure, attack surface', agentType: 'plan-security' },
]
// Model diversity (research: same-model agents amplify shared priors). Run the
// red-team on a different model so its skepticism comes from different priors.
const REDTEAM_MODEL = a.redteamModel || 'sonnet'
const grounding =
  `Feature to plan: ${feature}\n` +
  `Hard constraints: ${constraints}\n` +
  `Project directory: ${a.projectDir || '(current working directory)'}\n` +
  `GROUND YOURSELF IN THE REAL CODE: read the relevant files, the project's CLAUDE.md, and the live database schema (Supabase MCP) if available. Do NOT invent files, APIs, or tables — only reference things you have verified exist.`

// --- Recorded lessons: the plan must not propose something already known to be a mistake ---
// LESSONS.md is the distilled record of defects found across every project (L1, L2, … ).
// A plan that violates one of them is a plan to repeat a known failure, so the audit is a
// GATE with a fix loop, not an appended note. The auditor reports whether it actually READ
// the file, because an audit that read nothing would otherwise be indistinguishable from a
// clean one (see LESSONS.md L68).
const LESSONS_PATH = '~/.claude/LESSONS.md'
const RULES_PATH = '~/.claude/CLAUDE.md'
const LESSONS_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['lessonsFileRead', 'lessonsSeen', 'verdict', 'violations'],
  properties: {
    lessonsFileRead: { type: 'boolean', description: `true ONLY if you actually read ${LESSONS_PATH} yourself in this task` },
    lessonsSeen: { type: 'number', description: 'how many distinct L-numbered lessons you found in the file (0 if you could not read it)' },
    verdict: { type: 'string', enum: ['clean', 'violations', 'could-not-audit'] },
    violations: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        required: ['lessonId', 'where', 'why', 'fix'],
        properties: {
          lessonId: { type: 'string', description: 'e.g. L13, or the CLAUDE.md rule name' },
          where: { type: 'string', description: 'the exact part of the plan that violates it' },
          why: { type: 'string' },
          fix: { type: 'string', description: 'the concrete change to the plan that would satisfy the lesson' },
        },
      },
    },
    notes: { type: 'string' },
  },
}
const auditLessons = (planText, label) => agent(
  `Audit this plan for "${feature}" against the RECORDED LESSONS — the distilled record of defects already paid for on past projects.\n\n` +
  `FIRST, read ${LESSONS_PATH} in full, and the build-time reliability rules in ${RULES_PATH}. Do not work from memory: report lessonsFileRead=false and verdict="could-not-audit" if you cannot read the lessons file, and NEVER report "clean" on a file you did not read.\n\n` +
  `${grounding}\n\nPLAN:\n${planText}\n\n` +
  `Go lesson by lesson. For each one that the plan VIOLATES, or that the plan silently ignores where it plainly applies (a background job with no failure alerting, a guard that fails open, a multi-step write that is not idempotent, a route with no tenant scoping, a destructive step with no backup or undo, an empty state rendered over an error, a count and its rows from two different predicates, a hand-maintained list mirroring a source of truth, a test that cannot fail), report it with the lesson id, the exact part of the plan at fault, why it is the same mistake, and the concrete fix.\n\n` +
  `Report ONLY real violations grounded in the plan's own text — do not pad the list with generic advice, and do not restate the reality-check's job (whether files and tables exist). Absence of a lesson from the plan is a violation only where that lesson plainly applies to what the plan is building.`,
  { label, phase: 'Lessons audit', schema: LESSONS_SCHEMA, effort: 'high' }
)
// An auditor that dies must never resolve to silence: parallel() yields null on failure,
// and a missing audit reads exactly like a clean one unless it is converted to a loud one.
const normalizeAudit = (res) => res || {
  lessonsFileRead: false, lessonsSeen: 0, verdict: 'could-not-audit', violations: [],
  notes: 'The lessons-audit agent failed or was skipped, so this plan was NEVER checked against LESSONS.md. Treat it as unaudited, not as clean.',
}
const auditFailed = (au) => au.verdict === 'could-not-audit' || !au.lessonsFileRead || !(au.lessonsSeen > 0)
// Same rule for the reality-check: a checker that died must not resolve to "holds".
const normalizeRC = (res) => res || {
  verdict: 'needs-fixes', confirmed: [], adjustments: [],
  broken: ['The reality-check agent failed or was skipped, so NOTHING in this plan was verified against the real codebase. Treat every concrete claim as unverified.'],
}

// --- Revise mode (re-run incorporating the human's GitHub Discussion comments) ---
if (a.mode === 'revise') {
  const prior = a.priorPlan || '(no prior plan supplied)'
  const comments = a.comments || '(no comments supplied)'
  const REVISE_SCHEMA = {
    type: 'object', additionalProperties: false,
    required: ['plan', 'responses', 'openRisks'],
    properties: {
      plan: { type: 'string', description: 'the revised full plan in markdown' },
      responses: { type: 'array', items: { type: 'string' }, description: 'point-by-point: how each comment was addressed, or why pushed back' },
      openRisks: { type: 'array', items: { type: 'string' } },
    },
  }
  phase('Revise')
  const revised = await agent(
    `The human reviewed this plan for "${feature}" and left comments. Revise the plan to ADDRESS each comment specifically — change it where they are right, push back with reasons where they are not.\n${grounding}\n\nPRIOR PLAN:\n${prior}\n\nHUMAN COMMENTS:\n${comments}`,
    { label: 'revise', phase: 'Revise', schema: REVISE_SCHEMA, effort: 'high' }
  )
  phase('Reality-check')
  const REVISE_RC_SCHEMA = { type: 'object', additionalProperties: false, required: ['verdict', 'confirmed', 'broken'], properties: { verdict: { type: 'string', enum: ['holds', 'needs-fixes'] }, confirmed: { type: 'array', items: { type: 'string' } }, broken: { type: 'array', items: { type: 'string' } }, adjustments: { type: 'array', items: { type: 'string' } } } }
  const reviseRcPrompt = (planText) =>
    `Reality-check this REVISED plan against the actual codebase and data.\n${grounding}\n\nPlan:\n${planText}\n\nVerify every concrete claim (files, APIs, tables, constraints) by reading the real code/schema. Report what holds, what is broken, and concrete adjustments.`
  let reviseFinal = revised
  let [reviseRC0, reviseAudit0] = await parallel([
    () => agent(reviseRcPrompt(revised.plan), { label: 'reality-check', phase: 'Reality-check', effort: 'high', schema: REVISE_RC_SCHEMA }),
    () => auditLessons(revised.plan, 'lessons-audit'),
  ])
  let reviseRC = normalizeRC(reviseRC0)
  let reviseAudit = normalizeAudit(reviseAudit0)
  if (auditFailed(reviseAudit)) log(`LESSONS AUDIT DID NOT RUN CLEANLY (${reviseAudit.verdict}, read=${reviseAudit.lessonsFileRead}, lessons seen=${reviseAudit.lessonsSeen}) — the revised plan is UNAUDITED against LESSONS.md, not clean.`)

  // One bounded correction round: revise mode stays light, but a known-bad proposal
  // must be FIXED in the plan text, never merely reported beside it.
  const reviseProblems = reviseRC.broken.length + reviseAudit.violations.length
  if (reviseProblems > 0) {
    phase('Fix & reverify')
    log(`Revised plan has ${reviseRC.broken.length} broken claim(s) and ${reviseAudit.violations.length} lesson violation(s) — correcting inline.`)
    reviseFinal = await agent(
      `Correct this revised plan IN PLACE. Fix each broken claim and each recorded-lesson violation directly in the plan text; do NOT append correction notes. Keep everything already correct, and keep the point-by-point responses to the human's comments.\n${grounding}\n\nBROKEN CLAIMS:\n${JSON.stringify(reviseRC.broken, null, 2)}\nLESSON VIOLATIONS (from ${LESSONS_PATH} — each names the lesson, the offending part, and the fix; apply the fix):\n${JSON.stringify(reviseAudit.violations, null, 2)}\n\nCURRENT PLAN:\n${reviseFinal.plan}\n\nReturn the fully corrected plan with the same structure.`,
      { label: 'fix:1', phase: 'Fix & reverify', schema: REVISE_SCHEMA, effort: 'high' }
    )
    const [reviseRC1, reviseAudit1] = await parallel([
      () => agent(reviseRcPrompt(reviseFinal.plan), { label: 'reverify:1', phase: 'Fix & reverify', effort: 'high', schema: REVISE_RC_SCHEMA }),
      () => auditLessons(reviseFinal.plan, 'reaudit:1'),
    ])
    reviseRC = normalizeRC(reviseRC1)
    reviseAudit = normalizeAudit(reviseAudit1)
  }
  return { mode: 'revise', feature, revised: reviseFinal, realityCheck: reviseRC, lessonsAudit: reviseAudit }
}

// --- Preflight: confirm the grounding sources are actually reachable ---
const PREFLIGHT_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['repoReadable', 'schemaReachable', 'notes'],
  properties: {
    repoReadable: { type: 'boolean' },
    schemaReachable: { type: 'boolean' },
    notes: { type: 'string' },
  },
}
phase('Preflight')
const preflight = await agent(
  `Quick grounding probe for planning "${feature}". Project directory: ${a.projectDir || '(current working directory)'}.\n(1) Can you actually read this project's source files and its CLAUDE.md? Try listing/reading one or two.\n(2) Can you reach the live database schema via the Supabase MCP tools? Try one cheap call.\nReport a boolean for each plus a short note on anything you could NOT access. Be honest — a "false" here is valuable, not a failure.`,
  { label: 'preflight', phase: 'Preflight', schema: PREFLIGHT_SCHEMA }
)
// THREE states, not two. `agent()` returns null when the subagent dies on a terminal
// API error after retries, and reading a field off that null used to crash the whole
// run with "null is not an object", which names the wrong thing and loses every agent
// that had not started (observed 2026-08-27: "Connection lost mid-response" during the
// probe killed a six-role run before any panelist worked). A probe that NEVER RAN is
// its own outcome and must not read as one that ran clean (L98, L11): the skill tells
// the caller to warn the user on a grounding gap, so silence here would be reported as
// verified reachability.
if (!preflight) {
  log(`PREFLIGHT DID NOT RUN: the probe agent died, usually a transient API error. Continuing, but reachability is UNVERIFIED rather than confirmed, and the plan must be reported that way.`)
} else if (!preflight.repoReadable || !preflight.schemaReachable) {
  log(`GROUNDING GAP: repoReadable=${preflight.repoReadable} schemaReachable=${preflight.schemaReachable}: ${preflight.notes}. The plan will explicitly mark where it is ungrounded.`)
}

const PASS_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['role', 'approach', 'risks', 'hardConstraints', 'confidence'],
  properties: {
    role: { type: 'string' },
    approach: { type: 'string', description: "this role's opinionated, codebase-specific recommendation" },
    risks: { type: 'array', items: { type: 'string' } },
    hardConstraints: { type: 'array', items: { type: 'string' } },
    openQuestions: { type: 'array', items: { type: 'string' } },
    confidence: { type: 'string', enum: ['low', 'medium', 'high'], description: 'how confident you are, given how much you could actually verify' },
  },
}

phase('Independent passes')
const passes = (await parallel(roles.map(r => () =>
  agent(
    `You are the ${r.key.toUpperCase()} on a feature-planning panel. Your lens: ${r.brief}.\n${grounding}\n\nWrite YOUR independent recommendation for how to build this feature. You have NOT seen the other panelists and must not assume their views. Be specific to this codebase, take a clear position, surface the risks only your lens would catch, and state your confidence (low/medium/high) honestly given how much you could actually verify.`,
    { label: `pass:${r.key}`, phase: 'Independent passes', schema: PASS_SCHEMA, ...(r.agentType ? { agentType: r.agentType } : {}) }
  )
))).filter(Boolean)

const OPTIONS_SCHEMA = {
  type: 'object', additionalProperties: false, required: ['options'],
  properties: {
    options: {
      type: 'array', minItems: 2, maxItems: 3,
      items: {
        type: 'object', additionalProperties: false,
        required: ['id', 'name', 'summary', 'keyChoices', 'cost'],
        properties: {
          id: { type: 'string' }, name: { type: 'string' },
          summary: { type: 'string' }, keyChoices: { type: 'array', items: { type: 'string' } },
          cost: { type: 'string', description: 'free / cheapest, or the rough recurring $ and exactly what the money buys over the free option' },
        },
      },
    },
  },
}

phase('Distill options')
const distilled = await agent(
  `Independent panel recommendations:\n${JSON.stringify(passes, null, 2)}\n\nSynthesize them into 2-3 DISTINCT, WHOLE, internally-coherent candidate approaches to "${feature}". Each option must be a genuinely different bet (e.g. thin-slice-now vs durable-foundation vs buy-don't-build) — do NOT blend them into one compromise.\n\nCOST SPREAD IS REQUIRED: at least ONE option must be the free / cheapest-possible approach (reuse what already exists, no new paid services). Include a NON-FREE option ONLY when its extra spend buys a genuinely meaningful win, and then state plainly what the money buys over the free option. Never pad the slate with a paid option that is not clearly better. Give each a short id, name, summary, key choices, and a cost note.`,
  { label: 'distill', phase: 'Distill options', schema: OPTIONS_SCHEMA }
)
const options = distilled.options

phase('Champion + red-team')
const advocacy = (await parallel(options.flatMap(o => [
  () => agent(
    `Champion this approach to "${feature}":\nName: ${o.name}\nSummary: ${o.summary}\nKey choices: ${o.keyChoices.join('; ')}\n${grounding}\n\nArgue the STRONGEST possible case that THIS is the best plan. Be concrete and grounded, and state your confidence (low/medium/high).`,
    { label: `champion:${o.id}`, phase: 'Champion + red-team',
      schema: { type: 'object', additionalProperties: false, required: ['optionId', 'caseFor', 'confidence'], properties: { optionId: { type: 'string' }, caseFor: { type: 'string' }, confidence: { type: 'string', enum: ['low', 'medium', 'high'] } } } }
  ).then(x => ({ ...x, optionId: o.id, kind: 'for' })),
  () => agent(
    `RED-TEAM this approach to "${feature}":\nName: ${o.name}\nSummary: ${o.summary}\nKey choices: ${o.keyChoices.join('; ')}\n${grounding}\n\nTry to KILL it. Find the failure modes, hidden costs, and reasons it would NOT be the best plan. Default to skeptical; assume it has a flaw and find it.\n\nYOUR SHARPEST WEAPON IS THE RECORD: read ${LESSONS_PATH} (the distilled defects already paid for on past projects) and ${RULES_PATH}. Where this approach repeats one of them, say so and CITE the lesson id (e.g. "L13: the nightly job has no alert on the absence of a run"). A cited lesson is a defect this project has already shipped once, so it is worth more than a hypothetical objection.\n\nState your confidence (low/medium/high) in your strongest objection.`,
    { label: `redteam:${o.id}`, phase: 'Champion + red-team', model: REDTEAM_MODEL, agentType: 'plan-redteam',
      schema: { type: 'object', additionalProperties: false, required: ['optionId', 'caseAgainst', 'confidence'], properties: { optionId: { type: 'string' }, caseAgainst: { type: 'string' }, confidence: { type: 'string', enum: ['low', 'medium', 'high'] } } } }
  ).then(x => ({ ...x, optionId: o.id, kind: 'against' })),
]))).filter(Boolean)

const SELECT_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['winnerId', 'scores', 'rationale'],
  properties: {
    winnerId: { type: 'string' }, rationale: { type: 'string' },
    scores: {
      type: 'array',
      items: { type: 'object', additionalProperties: false, required: ['optionId', 'score', 'notes'], properties: { optionId: { type: 'string' }, score: { type: 'number' }, notes: { type: 'string' } } },
    },
    runnerUpBestIdeas: { type: 'array', items: { type: 'string' } },
  },
}

phase('Score & select')
const selection = await agent(
  `Feature: ${feature}\nWeighted criteria that define "best": ${criteria}\nCandidate options:\n${JSON.stringify(options, null, 2)}\nChampion & red-team cases:\n${JSON.stringify(advocacy, null, 2)}\n\nBLIND JUDGING: you are NOT told which specialist or role favored which option, and you must NOT infer or weight by any author's seniority — judge each option purely on its merits against the criteria. WEIGHT BY CONFIDENCE: each case carries a stated confidence; a low-confidence claim must not outweigh a well-supported one.\n\nA red-team objection that CITES a recorded lesson id (from ${LESSONS_PATH}) is evidence of a defect this project has already shipped once, not a hypothetical — weight it accordingly, and score an option down on correctness & robustness where it repeats a recorded mistake and does nothing to prevent it.\n\nScore EACH option 0-10 against the weighted criteria, with reasons. Then pick the highest-scoring option that SURVIVES its red-team. Choose the BEST plan, not the most comfortable or easiest-to-ship — if the more ambitious option scores higher and survives, pick it. COST IS FIRST-CLASS: do not pick a paid option over a free/cheapest one that scores nearly as well — prefer free unless the paid option is clearly, materially better on the weighted criteria. IGNORE BUILD TIME / EFFORT: the user's standing rule is "right is always better than fast" — NEVER prefer an option because it is quicker or easier to build; when options differ on correctness vs. build speed, the more correct/robust one wins. (Recurring cost still counts; build effort does not.) List the runner-up's best ideas worth grafting into the winner.`,
  { label: 'judge', phase: 'Score & select', schema: SELECT_SCHEMA, effort: 'high' }
)
const winner = options.find(o => o.id === selection.winnerId) || options[0]

const PLAN_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['title', 'plan', 'overruledDissent', 'idealVsDoable', 'escalatedDecisions', 'openRisks'],
  properties: {
    title: { type: 'string' },
    plan: { type: 'string', description: 'the full phased implementation plan in markdown, concrete and grounded in this codebase' },
    overruledDissent: { type: 'array', items: { type: 'string' } },
    idealVsDoable: { type: 'string', description: 'what the ideal version would add beyond what is being recommended now, and why it is deferred' },
    escalatedDecisions: {
      type: 'array',
      items: { type: 'object', additionalProperties: false, required: ['question', 'options'], properties: { question: { type: 'string' }, options: { type: 'array', items: { type: 'string' } } } },
    },
    openRisks: { type: 'array', items: { type: 'string' } },
  },
}

phase('Synthesize')
const draft = await agent(
  `Write the implementation plan for "${feature}" from the winning approach "${winner.name}" (${winner.summary}).\nGraft in these runner-up ideas where they strengthen it: ${(selection.runnerUpBestIdeas || []).join('; ') || '(none)'}\nJudge rationale: ${selection.rationale}\nFull champion/red-team context:\n${JSON.stringify(advocacy)}\n\nBEFORE writing, read ${LESSONS_PATH} and the build-time rules in ${RULES_PATH}, and design against them: every failure path surfaces loudly, every multi-step write survives running twice, every route states who may call it and whose data it touches, every destructive step keeps the good state until its replacement is verified, and every guard is one that can be seen to fail. The plan is audited against that file after you write it, so build it in now rather than having it corrected out of you.\n\nProduce: (1) a phased, concrete plan grounded in this codebase; (2) dissent you overruled and WHY; (3) the IDEAL-vs-DOABLE gap — what the best version would add and why it is deferred; (4) escalatedDecisions — EVERY product / scope / cost trade-off where reasonable people could choose differently MUST go here for the human to decide; do NOT 'lock' such a call yourself. This includes scope (build one thing vs two), thin-vs-full, and especially FREE-vs-PAID: if a non-free option is meaningfully better than the free one, put 'ship the free way' vs 'pay for the better way' here as an explicit decision with the cost named. Lock ONLY purely technical decisions that have one clearly-correct answer; (5) open risks and unknowns.`,
  { label: 'synthesize', phase: 'Synthesize', schema: PLAN_SCHEMA, effort: 'high' }
)

const RC_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['verdict', 'confirmed', 'broken'],
  properties: {
    verdict: { type: 'string', enum: ['holds', 'needs-fixes'] },
    confirmed: { type: 'array', items: { type: 'string' } },
    broken: { type: 'array', items: { type: 'string' } },
    adjustments: { type: 'array', items: { type: 'string' } },
  },
}

// Reality-check (does the plan match the code?) and lessons audit (does the plan repeat a
// known mistake?) are independent questions, so they run side by side and BOTH feed the
// same fix loop. Neither is allowed to be merely advisory.
phase('Reality-check')
let finalPlan = draft
const rcPrompt = (planText, corrected) => corrected
  ? `Reality-check this CORRECTED plan against the ACTUAL codebase and data.\n${grounding}\n\nPlan:\n${planText}\n\nVerify every concrete claim (files, paths, line numbers, APIs, tables, constraints) by reading the real code/schema. Report what holds and anything still broken.`
  : `Reality-check this plan against the ACTUAL codebase and data.\n${grounding}\n\nPlan:\n${planText}\n\nVerify every concrete assumption: do the referenced files, components, APIs, and tables actually exist? Are the file paths and line numbers correct? Does the data model support it? Does anything violate the stated constraints (${constraints})? Read the real code and schema to confirm — do not take the plan's word for it. Report what holds, what is broken, and concrete adjustments.`

let [rc0, audit0] = await parallel([
  () => agent(rcPrompt(finalPlan.plan, false), { label: 'reality-check', phase: 'Reality-check', schema: RC_SCHEMA, effort: 'high' }),
  () => auditLessons(finalPlan.plan, 'lessons-audit'),
])
let realityCheck = normalizeRC(rc0)
let lessonsAudit = normalizeAudit(audit0)
if (auditFailed(lessonsAudit)) {
  log(`LESSONS AUDIT DID NOT RUN CLEANLY (${lessonsAudit.verdict}, read=${lessonsAudit.lessonsFileRead}, lessons seen=${lessonsAudit.lessonsSeen}) — this plan is UNAUDITED against LESSONS.md, not clean. ${lessonsAudit.notes || ''}`)
}

// Fix-and-reverify: if either check found a problem, correct the plan IN PLACE (not as an
// appended note) and re-run BOTH checks. Bounded to 2 rounds so it converges.
let rcRounds = 0
const stillBroken = () => (realityCheck.verdict === 'needs-fixes' || (realityCheck.broken && realityCheck.broken.length))
const stillViolating = () => lessonsAudit.violations.length > 0
while ((stillBroken() || stillViolating()) && rcRounds < 2) {
  rcRounds++
  log(`Round ${rcRounds}: ${(realityCheck.broken || []).length} broken item(s), ${lessonsAudit.violations.length} recorded-lesson violation(s) — correcting the plan inline.`)
  phase('Fix & reverify')
  finalPlan = await agent(
    `This plan failed its checks. Correct EACH item directly in the plan text — fix the wrong file paths, line numbers, and claims in place, and change the DESIGN where it repeats a recorded mistake; do NOT just append correction notes. Keep everything that was already correct.\n${grounding}\n\n` +
    `BROKEN CLAIMS (reality-check):\n${JSON.stringify(realityCheck.broken || [], null, 2)}\n` +
    `ADJUSTMENTS:\n${JSON.stringify(realityCheck.adjustments || [], null, 2)}\n` +
    `RECORDED-LESSON VIOLATIONS (from ${LESSONS_PATH} — each names the lesson, the offending part of the plan, and the fix; APPLY the fix, and if you genuinely disagree with one, put it in overruledDissent with your reason rather than silently ignoring it):\n${JSON.stringify(lessonsAudit.violations, null, 2)}\n\n` +
    `CURRENT PLAN:\n${finalPlan.plan}\n\nReturn the fully corrected plan with the same structure.`,
    { label: `fix:${rcRounds}`, phase: 'Fix & reverify', schema: PLAN_SCHEMA, effort: 'high' }
  )
  const [rcN, auditN] = await parallel([
    () => agent(rcPrompt(finalPlan.plan, true), { label: `reverify:${rcRounds}`, phase: 'Fix & reverify', schema: RC_SCHEMA, effort: 'high' }),
    () => auditLessons(finalPlan.plan, `reaudit:${rcRounds}`),
  ])
  realityCheck = normalizeRC(rcN)
  lessonsAudit = normalizeAudit(auditN)
}

return { feature, criteria, preflight, options, passes, advocacy, selection, winner, plan: finalPlan, realityCheck, lessonsAudit, rcRounds }
