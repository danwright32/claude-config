// What holds a session's work in flight, one list for every mod that asks (#3770). Before it there
// were three copies of the question, each reading its own part: the goal box (agents, merges, open
// pull requests), the job watcher at an agent's stop (that agent's own tasks), and the overnight
// driver (busy.ts). The close this session card asks every part at once, so the parts live here,
// each a kind, and each reader takes the kinds it asks about by name, never by a copy of its own.
//
// Pure: each mod reads its own facts in place (the engine needs $ spelled at every call) and hands
// them here as a reading, a value or why it could not be read. A reading the reader asked for and did
// not hand over, or one that could not be read, is itself a hold, marked unread, so a fact that was
// never read never reads as nothing in flight (L10).
//
// It cannot be a member of mod-kit's noun: a mod must read it when mod-kit's loaded copy is the older
// one. So each mod that asks keeps a copy at hooks/mod-kit/inflight.ts, byte for byte, which
// tools/check-mod-shared-parts.sh holds to this one.

/** Each part of the work a session can have in flight. */
export type InflightKind =
  /** An agent the session started, running, pending or waiting. */
  | 'agent'
  /** A teammate the session started, idle between its turns: it counts until it ends. */
  | 'agent-idle'
  /** An agent a mod started, in any of those states. */
  | 'agent-plugin'
  /** A merge or deploy is it live has not settled, as the goal box reads it. */
  | 'merge'
  /** A pull request the session touched that GitHub says is still open, as the goal box reads it. */
  | 'pr'
  /** Background work Claude Code listed as in flight at the stop: a shell, Monitor, workflow or agent. */
  | 'task'
  /** A scheduled wake up, cron or /loop that will wake the session later. */
  | 'cron'
  /** A background job on the job watcher's list, or what it left running in its process group. */
  | 'job'
  /** A /goal still set, whose own check has not found it met. */
  | 'goal'
  /** A step on the manual steps card Dan has not done. */
  | 'steps'
  /** A compact the session queued, or the handoff note owed after one. */
  | 'compact'
  /** A prompt a mod is about to send, holding its reload until then. */
  | 'prompt'
  /** The turn's answer ends on a question to Dan. */
  | 'question'

/** Every kind, in the order a reader that asks about all of them lists them. */
export const INFLIGHT_KINDS: readonly InflightKind[] = ['agent', 'agent-idle', 'agent-plugin', 'task', 'job', 'cron', 'merge', 'pr', 'goal', 'steps', 'compact', 'prompt', 'question']

/**
 * What the Goal accomplished box refuses for (#1563, #1818): the session's own agents still working,
 * a merge or deploy not settled, a pull request it touched still open. A mod's own agent is not the
 * request's, and the steps card is not the work Dan asked for, so neither is one.
 */
export const BOX_KINDS: readonly InflightKind[] = ['agent', 'merge', 'pr']

/** One thing in flight, said as a sentence; `unread` when it is the reading itself that failed. */
export type InflightHold = { kind: InflightKind; text: string; unread?: true }

/** A fact as its mod read it, or why it could not be read. */
export type Reading<T> = { value: T } | { unread: string }

/** An agent as `$.agent.list()` lists it, the fields read here. */
export type InflightAgent = { id: string; name?: string; description?: string; status: string; spawnedBy?: unknown }

/** One task in Claude Code's list of work in flight at a stop (background_tasks). */
export type InflightTask = { id: string; what: string; type: string; status: string }

/** The facts each kind is judged from; a reader hands those its kinds need. */
export type InflightFacts = {
  /** `$.agent.list()`, for agent, agent-idle and agent-plugin. */
  agents?: Reading<unknown>
  /** The goal box's own sentences for the merges is it live has not settled (box.ts mergeHolds). */
  merges?: Reading<string[]>
  /** The goal box's own sentences for the pull requests still open (register.ts openHolds). */
  prs?: Reading<string[]>
  /** The stop's background_tasks, as Claude Code sent it. */
  tasks?: Reading<unknown>
  /** The stop's session_crons, as Claude Code sent it. */
  crons?: Reading<unknown>
  /** The job watcher's `$.jobs.list()`. */
  jobs?: Reading<unknown>
  /** mod-kit's reading of the session's /goal. */
  goal?: Reading<unknown>
  /** The manual steps card in $.state, null when none is pinned; `ignore` names a step not to count. */
  steps?: Reading<{ card: unknown; ignore?: string }>
  /** The status bar's compactQueued and compactFollowUp in $.state (absent when it is not loaded). */
  compact?: Reading<{ queued: unknown; followUp: unknown }>
  /** mod-kit's holds in $.state and the time now, ms since the epoch. */
  prompts?: Reading<{ holds: unknown; now: number }>
  /** The answer the turn ended with. */
  answer?: Reading<unknown>
}

const isObj = (x: unknown): x is Record<string, unknown> => typeof x === 'object' && x !== null && !Array.isArray(x)

// What each kind's reading is, as a sentence names it when it could not be read.
const READ_AS: Record<InflightKind, string> = {
  agent: "the session's agents",
  'agent-idle': "the session's agents",
  'agent-plugin': "the session's agents",
  merge: "is it live's record of this session's merges",
  pr: 'the pull requests this session touched',
  task: "Claude Code's list of background work in flight at this turn's stop",
  cron: "Claude Code's list of scheduled wake ups at this turn's stop",
  job: "the job watcher's list of background jobs",
  goal: "this session's /goal",
  steps: 'the manual steps card',
  compact: "the status bar's record of a queued compact",
  prompt: "mod-kit's list of prompts a mod is about to send",
  question: "the turn's answer",
}

const unreadHold = (kind: InflightKind, why: string): InflightHold =>
  kind === 'agent' || kind === 'agent-idle' || kind === 'agent-plugin'
    ? { kind, unread: true, text: `the session's agents could not be listed (${why}), so whether one is still working is not known` }
    : { kind, unread: true, text: `${READ_AS[kind]} could not be read (${why}), so whether anything is in flight there is not known` }

const NOT_HANDED = 'it was not read'

/** Claude Code's statuses for a task it has ended (TaskStop's "is not running (status: completed)", 2.1.309). */
export const FINISHED_TASK_STATUSES: ReadonlySet<string> = new Set(['completed', 'failed', 'killed', 'stopped'])
/** Whether a task Claude Code listed with `status` has ended. Any other status, an unknown one included, has not. */
export const taskFinished = (status: string): boolean => FINISHED_TASK_STATUSES.has(status)

/**
 * The tasks in the background_tasks a stop carries (the whole session's work in flight, whoever
 * started it), each with what it runs as `short` cuts it. Undefined when the list is missing or is
 * not a list, so a caller can tell an unreadable list from an empty one (L10); an entry naming no
 * task is passed over.
 */
export const tasksIn = (raw: unknown, short: (what: string) => string = s => s): InflightTask[] | undefined => {
  if (!Array.isArray(raw)) return undefined
  return raw.flatMap(t => {
    const e = isObj(t) ? t : {}
    if (typeof e.id !== 'string' || !e.id) return []
    const what = typeof e.command === 'string' && e.command ? e.command : typeof e.description === 'string' ? e.description : ''
    return [{ id: e.id, what: short(what || e.id), type: typeof e.type === 'string' ? e.type : '', status: typeof e.status === 'string' ? e.status : '' }]
  })
}

const agentName = (a: InflightAgent) => a.description || a.name || a.id
const ACTIVE = new Set(['running', 'pending', 'waiting'])

// The question the answer ends on: its last paragraph, once trimmed, ending in a question mark.
const endsOnQuestion = (text: string) => {
  const paragraphs = text.trim().split(/\n\s*\n/)
  return /\?["')\]]*$/.test((paragraphs[paragraphs.length - 1] ?? '').trim())
}

type Judge = (value: unknown) => InflightHold[] | { unread: string }

const judgeAgents: Judge = value => {
  if (!Array.isArray(value)) return { unread: 'the agent list is not a list' }
  const out: InflightHold[] = []
  for (const raw of value) {
    const a = raw as InflightAgent
    const mine = a.spawnedBy === undefined
    if (mine && ACTIVE.has(a.status)) out.push({ kind: 'agent', text: `the agent "${agentName(a)}" is still ${a.status}` })
    else if (mine && a.status === 'idle') out.push({ kind: 'agent-idle', text: `the agent "${agentName(a)}" is idle and has not ended` })
    else if (!mine && (ACTIVE.has(a.status) || a.status === 'idle')) out.push({ kind: 'agent-plugin', text: `the agent "${agentName(a)}", which a mod started, is still ${a.status}` })
  }
  return out
}

const judgeTexts = (kind: InflightKind): Judge => value => {
  if (!Array.isArray(value) || !value.every(t => typeof t === 'string')) return { unread: 'it is not a list of sentences' }
  return value.map(text => ({ kind, text }))
}

const judgeTasks: Judge = value => {
  const tasks = tasksIn(value)
  if (!tasks) return { unread: 'it is missing or is not a list' }
  return tasks.filter(t => !taskFinished(t.status)).map(t => ({ kind: 'task' as const, text: `the background ${t.type || 'task'} ${t.id} (${t.what}) is still ${t.status || 'listed as in flight'}` }))
}

const judgeCrons: Judge = value => {
  if (!Array.isArray(value)) return { unread: 'it is missing or is not a list' }
  return value.map(c => {
    const e = isObj(c) ? c : {}
    const when = typeof e.schedule === 'string' && e.schedule ? ` (${e.schedule})` : ''
    return { kind: 'cron' as const, text: `a scheduled wake up${when} will wake this session later` }
  })
}

const judgeJobs: Judge = value => {
  if (!Array.isArray(value)) return { unread: 'it is not a list' }
  return value.map(j => {
    const e = isObj(j) ? j : {}
    const label = typeof e.label === 'string' && e.label ? e.label : typeof e.id === 'string' ? e.id : 'a job'
    const state = typeof e.state === 'string' && e.state ? e.state : 'running'
    return { kind: 'job' as const, text: `the background job "${label}"${e.kept === true ? ', kept,' : ''} is still ${state}` }
  })
}

const judgeGoal: Judge = value => {
  const g = isObj(value) ? value : {}
  if (g.state === 'none') return []
  if (g.state === 'set') return [{ kind: 'goal', text: `the /goal "${typeof g.condition === 'string' ? g.condition : ''}" is still set and its own check has not found it met` }]
  if (g.state === 'unreadable') return { unread: typeof g.why === 'string' ? g.why : 'no reason given' }
  return { unread: 'it is not a goal reading' }
}

const judgeSteps: Judge = value => {
  const { card, ignore } = (isObj(value) ? value : {}) as { card?: unknown; ignore?: unknown }
  if (card === null || card === undefined) return []
  if (!isObj(card) || !Array.isArray(card.steps)) return { unread: 'the card is not one' }
  return card.steps.flatMap(s => {
    const e = isObj(s) ? s : {}
    if (e.finished || (typeof ignore === 'string' && e.title === ignore)) return []
    return [{ kind: 'steps' as const, text: `the manual step "${typeof e.title === 'string' ? e.title : ''}" is not done` }]
  })
}

const judgeCompact: Judge = value => {
  const { queued, followUp } = (isObj(value) ? value : {}) as { queued?: unknown; followUp?: unknown }
  const out: InflightHold[] = []
  if (queued === true) out.push({ kind: 'compact', text: 'a compact is queued for the end of this turn' })
  if (followUp !== undefined && followUp !== null) out.push({ kind: 'compact', text: 'the handoff note after a compact has not been read back yet' })
  return out
}

const judgePrompts: Judge = value => {
  const { holds, now } = (isObj(value) ? value : {}) as { holds?: unknown; now?: unknown }
  if (typeof now !== 'number') return { unread: 'the time could not be read' }
  if (holds === undefined || holds === null) return []
  if (!Array.isArray(holds)) return { unread: 'it is not a list' }
  return holds.flatMap(h => {
    const e = isObj(h) ? h : {}
    if (typeof e.until !== 'number' || e.until <= now) return []
    return [{ kind: 'prompt' as const, text: `${typeof e.mod === 'string' ? e.mod : 'a mod'} is waiting to send ${typeof e.what === 'string' ? e.what : 'a prompt'}` }]
  })
}

const judgeAnswer: Judge = value => {
  if (typeof value !== 'string') return { unread: 'it is not text' }
  return endsOnQuestion(value) ? [{ kind: 'question', text: "the turn's answer ends on a question to Dan" }] : []
}

// Each fact, the kinds it is judged for, and how.
const PARTS: { fact: keyof InflightFacts; kinds: InflightKind[]; judge: Judge }[] = [
  { fact: 'agents', kinds: ['agent', 'agent-idle', 'agent-plugin'], judge: judgeAgents },
  { fact: 'tasks', kinds: ['task'], judge: judgeTasks },
  { fact: 'jobs', kinds: ['job'], judge: judgeJobs },
  { fact: 'crons', kinds: ['cron'], judge: judgeCrons },
  { fact: 'merges', kinds: ['merge'], judge: judgeTexts('merge') },
  { fact: 'prs', kinds: ['pr'], judge: judgeTexts('pr') },
  { fact: 'goal', kinds: ['goal'], judge: judgeGoal },
  { fact: 'steps', kinds: ['steps'], judge: judgeSteps },
  { fact: 'compact', kinds: ['compact'], judge: judgeCompact },
  { fact: 'prompts', kinds: ['prompt'], judge: judgePrompts },
  { fact: 'answer', kinds: ['question'], judge: judgeAnswer },
]

/**
 * Everything in flight of the kinds asked about, from the facts handed over, in the order the parts
 * are listed. A kind asked about whose fact was not handed over, or could not be read, is one unread
 * hold naming why, never nothing in flight. Empty only when every kind asked about was read clean.
 */
export const inflightHolds = (facts: InflightFacts, kinds: readonly InflightKind[]): InflightHold[] => {
  const want = new Set(kinds)
  const out: InflightHold[] = []
  for (const part of PARTS) {
    const first = part.kinds.find(k => want.has(k))
    if (first === undefined) continue
    const r = facts[part.fact] as Reading<unknown> | undefined
    if (r === undefined || 'unread' in r) {
      out.push(unreadHold(first, r === undefined ? NOT_HANDED : r.unread))
      continue
    }
    const judged = part.judge(r.value)
    if ('unread' in judged) out.push(unreadHold(first, judged.unread))
    else out.push(...judged.filter(h => want.has(h.kind)))
  }
  return out
}
