import { expect, mock } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import { pipeline } from './mod-kit/hooks/commands.ts'
import * as request from '../hooks/request.ts'
import type { On, Register } from 'claude-code'
import DESIGN_FIXTURE from './1563-goal-box.fixture.ts'
import { CLOSE_HEADING, CLOSE_TITLE, PROCESS_TIMEOUT_MS, QUIET_MS } from '../hooks/close.ts'
import { answeredCommand, answersMainReview, canBeTurnWork, reviewRead } from '../hooks/review.ts'

// The Goal accomplished box (claude-config#1563) in a session: shown once when a /goal is met (the
// session is sent a prompt of its own asking for it once the turn has ended, since the met record
// lands after the Stop hooks, so that path reads no Stop) or when Claude judges the work Dan asked for
// finished and calls the tool; never while a merge, a deploy, an agent or a pull request is in flight.
// The close this session card (#3770) does hook classic.Stop, to record the stop's background lists.

const T = `${'/Users'}/dan/.claude/projects/-repo/s1.jsonl`
const TOOL = 'mcp__goal-box__goal_accomplished'
type Goal = { state: 'set'; condition: string } | { state: 'none'; met?: { condition: string; reason: string; id: string } } | { state: 'unreadable'; why: string }
type Card = { toolUseId: string; border?: string; title: { text: string; color?: string; bold?: boolean }[]; lines: { text: string; color?: string }[][] }

// mod-kit, standing in: a mod cannot import another mod's files, and a plugin in a test runs apart
// from the test's module, so it asks the world (process.run '__modkit') what the transcript's goal
// is and whether drawing the card fails. mod-kit's own tests prove the real reader on real records.
const kit: { name: string; register: Register } = {
  name: 'mod-kit',
  register: on => {
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      const ask = async (what: string, arg = '') => JSON.parse((await built.process.run(['__modkit', what, arg])).stdout)
      const modkit = {
        card: async (c: { toolUseId: string }) => {
          const r = await built.process.run(['__modkit', 'card', JSON.stringify(c)])
          if (r.exitCode !== 0) throw new Error(r.stderr)
        },
        screen: async (call: unknown) => (JSON.stringify(call).includes('SCREEN-REFUSES') ? { deny: 'Blocked: this carries a secret.' } : null),
        goal: async ({ transcript }: { transcript: string }) => ask('goal', transcript),
        // The one reader of Dan's own words (#1135): what he types at the terminal or from his phone.
        isDans: async ({ origin }: { origin?: { readonly kind?: string } }) => origin?.kind === 'composer' || origin?.kind === 'bridge',
        // The kit's other members, which these tests never reach: each refuses by name if one ever is.
        blocked: async () => { throw new Error("mod-kit's blocked is not stood in by these tests") },
        commands: async () => { throw new Error("mod-kit's commands is not stood in by these tests") },
        writes: async () => { throw new Error("mod-kit's writes is not stood in by these tests") },
        git: async () => { throw new Error("mod-kit's git is not stood in by these tests") },
        gh: async () => { throw new Error("mod-kit's gh is not stood in by these tests") },
        mergeHelper: async () => { throw new Error("mod-kit's mergeHelper is not stood in by these tests") },
        ghRepo: async () => { throw new Error("mod-kit's ghRepo is not stood in by these tests") },
        // The one reader of a github.com link's repository, standing in: owner/name as the link spells it.
        linkRepo: async ({ link }: { link: string }) => {
          const parts = link.startsWith('https://github.com/') ? new URL(link).pathname.split('/').filter(Boolean) : []
          return parts.length >= 2 ? `${parts[0]}/${parts[1]}` : null
        },
        // #3770: the one reader of a shell command, standing in: what the world says it reads.
        pipeline: async ({ command }: { command: string }) => {
          const r = await built.process.run(['__modkit', 'pipeline', command])
          if (r.exitCode !== 0) throw new Error(r.stderr)
          return JSON.parse(r.stdout)
        },
        pythonText: async () => { throw new Error("mod-kit's pythonText is not stood in by these tests") },
        login: async () => { throw new Error("mod-kit's login is not stood in by these tests") },
        account: async () => { throw new Error("mod-kit's account is not stood in by these tests") },
        workingTree: async () => { throw new Error("mod-kit's workingTree is not stood in by these tests") },
        repo: async () => { throw new Error("mod-kit's repo is not stood in by these tests") },
        branch: async () => { throw new Error("mod-kit's branch is not stood in by these tests") },
        bandRow: async () => { throw new Error("mod-kit's bandRow is not stood in by these tests") },
        clearBandRow: async () => { throw new Error("mod-kit's clearBandRow is not stood in by these tests") },
        pane: async () => { throw new Error("mod-kit's pane is not stood in by these tests") },
        clearPane: async () => { throw new Error("mod-kit's clearPane is not stood in by these tests") },
        press: async () => { throw new Error("mod-kit's press is not stood in by these tests") },
        clickable: async () => { throw new Error("mod-kit's clickable is not stood in by these tests") },
        typedAnswer: async () => { throw new Error("mod-kit's typedAnswer is not stood in by these tests") },
        // #2132: a hold on goal-box's reload and its letting go, asked of the world, which keeps
        // them in order beside each prompt sent and can refuse one as mod-kit would.
        hold: async (input: unknown) => {
          const r = await built.process.run(['__modkit', 'hold', JSON.stringify(input)])
          if (r.exitCode !== 0) throw new Error(r.stderr)
        },
        release: async (input: unknown) => {
          const r = await built.process.run(['__modkit', 'release', JSON.stringify(input)])
          if (r.exitCode !== 0) throw new Error(r.stderr)
        },
      }
      return { ...built, modkit }
    })
    // #3770: mod-kit's holds on a mod's reload, as its state keeps them, written from the world's.
    on('turn.complete', async ($, e, next) => {
      const holds = JSON.parse((await $.process.run(['__others', 'holds'])).stdout) as unknown
      if (holds !== null) await $.state.set({ plugin: 'mod-kit', key: 'holds' } as never, holds as never)
      return next(e)
    })
  },
}

// is it live, standing in: its session state, as its own contract has it, which this mod reads,
// written from what the world says at the session's start, and again at each turn end before this
// mod reads it, as is it live's own record moves while a session runs (a deploy going live, #2523).
const live: { name: string; register: Register } = {
  name: 'is-it-live',
  register: on => {
    on('session.start', async ($, e, next) => {
      const facts = JSON.parse((await $.process.run(['__live'])).stdout) as { owed: unknown; verdicts: unknown }
      await $.state.set({ plugin: 'is-it-live', key: 'owed' } as never, facts.owed as never)
      await $.state.set({ plugin: 'is-it-live', key: 'verdicts' } as never, facts.verdicts as never)
      return next(e)
    })
    on('turn.complete', async ($, e, next) => {
      const facts = JSON.parse((await $.process.run(['__live'])).stdout) as { owed: unknown; verdicts: unknown }
      await $.state.set({ plugin: 'is-it-live', key: 'owed' } as never, facts.owed as never)
      await $.state.set({ plugin: 'is-it-live', key: 'verdicts' } as never, facts.verdicts as never)
      return next(e)
    })
  },
}
// The session registry, standing in: this session's record names the transcript the world says.
const registry: { name: string; register: Register } = {
  name: 'session-registry',
  register: on => {
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      const sessions = {
        list: async () => {
          const r = await built.process.run(['__sessions'])
          if (r.exitCode !== 0) throw new Error(r.stderr)
          return JSON.parse(r.stdout)
        },
        noteEdit: async () => { throw new Error("the registry's noteEdit is not stood in by these tests") },
        setExtra: async () => { throw new Error("the registry's setExtra is not stood in by these tests") },
      }
      return { ...built, sessions }
    })
  },
}
// #3770: the mods the close this session card reads, standing in. Each keeps what the world says in
// its own state at each turn end, as the real one keeps it while a session runs, or answers its noun
// from the world: manual steps' card and noun, the status bar's queued compact, the job watcher's list.
const stepsMod: { name: string; register: Register } = {
  name: 'manual-steps',
  register: on => {
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      const call = async (what: string, input: unknown) => {
        const r = await built.process.run(['__steps', what, JSON.stringify(input)])
        if (r.exitCode !== 0) throw new Error(r.stderr)
        return JSON.parse(r.stdout)
      }
      const manualSteps = { add: (i: unknown) => call('add', i), finish: (i: unknown) => call('finish', i), withdraw: (i: unknown) => call('withdraw', i) }
      return { ...built, manualSteps }
    })
    on('turn.complete', async ($, e, next) => {
      await $.state.set({ plugin: 'manual-steps', key: 'card' } as never, JSON.parse((await $.process.run(['__others', 'card'])).stdout) as never)
      // #3864: its record that the session recorded the last open step of a card.
      await $.state.set({ plugin: 'manual-steps', key: 'emptied' } as never, JSON.parse((await $.process.run(['__others', 'emptied'])).stdout) as never)
      return next(e)
    })
  },
}
const statusBar: { name: string; register: Register } = {
  name: 'status-bar',
  register: on => {
    on('turn.complete', async ($, e, next) => {
      const c = JSON.parse((await $.process.run(['__others', 'compact'])).stdout) as { queued: unknown; followUp: unknown }
      await $.state.set({ plugin: 'status-bar', key: 'compactQueued' } as never, c.queued as never)
      await $.state.set({ plugin: 'status-bar', key: 'compactFollowUp' } as never, c.followUp as never)
      return next(e)
    })
  },
}
const watcher: { name: string; register: Register } = {
  name: 'job-watcher',
  register: on => {
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      const list = async () => {
        const r = await built.process.run(['__jobs'])
        if (r.exitCode !== 0) throw new Error(r.stderr)
        return JSON.parse(r.stdout)
      }
      return { ...built, jobs: { list, agents: async () => [] } }
    })
  },
}
// Scope modes, standing in: its noun's one sleep predicate, answered from the world.
const sleepMod: { name: string; register: Register } = {
  name: 'scope-modes',
  register: on => {
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      const isAsleep = async () => JSON.parse((await built.process.run(['__sleep'])).stdout) === true
      return { ...built, scopeModes: { isAsleep } }
    })
  },
}
type Owed = { key: string; how: 'merged' | 'unproven' | 'waiting'; pr: number; at: number; cwd: string; repo?: string; named?: string; selector?: string }

type Gh = { exitCode: number; stdout: string; stderr?: string }
type World = {
  goal: Goal
  /** Why mod-kit refuses to draw the card, or '' when it draws it. */
  cardFails: string
  /** The cards mod-kit was asked to draw, in order. */
  cards: Card[]
  owed: Owed[]
  verdicts: Record<string, { state: string; at: number }>
  /** This session's transcript as its registry record names it ('' when it names none). */
  transcript: string
  /**
   * How the session registry holds this session (#2898): open, as a live session's record is; closed,
   * as the real registry lists a live session whose record a session end it outlived closed (no
   * transcript looked up for it); or absent, with no id of its own (selfId null).
   */
  registry: 'open' | 'closed' | 'closed naming it' | 'absent'
  /** Where a transcript is on disk, by path; a string is the error checking that path gives. */
  disk: Record<string, true | string>
  /** The folder the session is in now, where it started in /repo. */
  here: string
  /** The transcript's pr-link records, as Claude Code writes them. */
  links: string[]
  /** What `gh pr list --state open` answers per repository; absent answers an empty list. */
  open: Record<string, Gh>
  /** null stands for an entry of the list that is not an agent at all, handed over as it is. */
  agents: ({ id: string; status: string; spawnedBy?: string; description?: string } | null)[]
  /** Why `$.agent.list()` throws, or '' when it lists `agents`. */
  agentsFail: string
  /** How each of the mod's own next prompts fails, in order: thrown, or dropped by a hook beneath. */
  submitFails: ('throw' | 'drop')[]
  /** #2132: each hold, letting go and prompt the mod sent, in order; and why mod-kit refuses a hold, or ''. */
  held: string[]
  holdFails: string
  /** What `gh pr view` answers, by the repository it names (or the folder it runs in) and the account's token. */
  view: (q: { pr: string; repo?: string; cwd?: string; token?: string }) => Gh
  /** #3770: the manual steps card in manual steps' state, null when none is pinned. */
  stepsCard: unknown
  /** #3864: manual steps' record that the last open step of a card was recorded; absent is none yet. */
  stepsEmptied?: unknown
  compactQueued: unknown
  compactFollowUp: unknown
  /** mod-kit's holds in its state (null leaves them unset). */
  holds: unknown
  /** The job watcher's list, or why it throws. */
  jobs: unknown[]
  jobsFail: string
  /** What the look for a process carrying this session's id answers. */
  procs: Gh
  /** The look runs until its time limit passes on the engine's clock, then throws or exits killed. */
  procsTimeout?: 'throws' | 'exits'
  /** Taking the process list itself fails: ps throws, or ends with exit code 1. */
  psFails?: 'throws' | 'exits'
  /** The process list comes back marked as cut short (isStdoutTruncated). */
  psCut?: boolean
  /** What mod-kit's reader reads a command as, or why it throws. */
  reader: (command: string) => unknown[] | { fails: string }
  /** The cards pinned through manual steps' noun, and the titles withdrawn, in order. */
  pinned: { heading: string; step: Record<string, unknown> }[]
  /**
   * How manual steps' noun answers a pin, one of everything its add can do (manual-steps
   * hooks/register.tsx addStep and its noun): shown; not shown, with one of its four reasons;
   * refused (its deny); threw (its own method, when its hook did not answer); an answer that says
   * nothing; or no answer yet, until `releasePin` is called.
   */
  pinAnswer: PinAnswer
  pinCalls: number
  releasePin: () => void
  /** Scope modes' sleep predicate: true while Dan is asleep (sleep mode). */
  asleep?: boolean
  /** Why manual steps' noun throws on a withdraw, or '' when it withdraws. */
  withdrawFails: string
  withdrawn: string[]
  /** Each file written, by path: its last text. */
  written: Record<string, string>
  /**
   * Why asking for this session's id is refused, or '' when it answers. While set, every ask is
   * refused but the one that comes straight after HOME is read, which is where the reasons file is
   * written, so the reasons stay readable in a test.
   */
  idFails?: string
  /**
   * #3843: what a tool call answers at the bottom, by its tool_use_id; absent answers nothing of
   * note. An AskUserQuestion answers as Claude Code's dialog does, `{ result: { questions, answers } }`.
   */
  toolAnswers?: Record<string, unknown>
  /** #3843: what the run of the end of turn review's own test answers in place of yes or no. */
  workTest?: Gh
  /**
   * #3843: what the read of the end of turn review's record answers (hooks/lib/review-record.py
   * `state`); absent answers that no review was handed over this turn.
   */
  review?: Gh
  /**
   * #3843: the run of the end of turn review's own test answers only once `releaseWorkTest` is
   * called; and each tool call that reached the bottom, where the tool itself starts, by its
   * tool_use_id, in order.
   */
  workTestWaits?: boolean
  releaseWorkTest: () => void
  began: string[]
  /** #3843: a line the mod logs that matches this cannot be written: the log throws. */
  logFails?: RegExp
}
// manual steps' four reasons for not showing a step it was handed (addStep, word for word).
const NOT_SHOWN = {
  'not shown: nobody at the prompt': 'this session has nobody at its prompt',
  'not shown: carried steps held': 'the steps carried from an earlier session are held until Claude checks them again',
  'not shown: taken away': 'the card was taken away as it was added',
  'not shown: not drawn': 'the card could not be shown (no pane)',
} as const
type PinAnswer = 'shown' | keyof typeof NOT_SHOWN | 'refused' | 'threw' | 'says nothing' | 'null' | 'no answer yet'
const link = (repo: string, pr: number, at = '2026-10-24T18:00:00.000Z') =>
  JSON.stringify({ type: 'pr-link', sessionId: 's1', prNumber: pr, prUrl: `https://github.com/${repo}/pull/${pr}`, prRepository: repo, timestamp: at })
// #3843: where the end of turn review's test is installed, and what it says of each tool name these
// tests use. Not a copy of its rule: tests/test-goal-box-work-test.sh runs the mod's own command
// against the real payload/hooks/turn-worked.py and fails when one of these rows is not what it says.
const WORK_TEST_FILE = `${'/Users'}/dan/.claude/hooks/turn-worked.py`
const WORK_TEST_SAYS: Record<string, 'yes' | 'no'> = {
  Edit: 'yes',
  Write: 'yes',
  Bash: 'yes',
  Agent: 'yes',
  'mcp__is-it-live__card': 'yes',
  'mcp__goal-box__goal_accomplished': 'yes',
  Read: 'no',
  Grep: 'no',
  AskUserQuestion: 'no',
}
// #3843: where the end of turn review's record is read from, and what its reader prints for each
// state. Not a copy of its rule: tests/test-goal-box-review-record.sh runs the mod's own command
// against the real payload/hooks/lib/review-record.py and fails when it prints another shape.
const REVIEW_FILE = `${'/Users'}/dan/.claude/hooks/lib/review-record.py`
const reviewSays = (state: 'none' | 'handed' | 'answered'): Gh => ({ exitCode: 0, stdout: `${JSON.stringify(state === 'none' ? { state, turn: 'p1' } : { state, turn: 'p1', handed_at: 1_800_000_000, label: 'SESSION REFLECTION' })}\n` })
// A turn whose end of turn review has been handed over and answered: what a test of something else
// says of the review when its session works and then shows the box in one turn.
const REVIEWED = { review: reviewSays('answered') }

const world = (on: On, init: Partial<World> = {}) => {
  const w: World = { goal: { state: 'none' }, cardFails: '', cards: [], transcript: T, registry: 'open', disk: {}, here: '/repo', owed: [], verdicts: {}, links: [], open: {}, agents: [], agentsFail: '', submitFails: [], held: [], holdFails: '', view: () => ({ exitCode: 1, stdout: '', stderr: 'unexpected' }), stepsCard: null, compactQueued: false, compactFollowUp: null, holds: [], jobs: [], jobsFail: '', procs: { exitCode: 0, stdout: '{"found":[]}' }, reader: () => [], pinned: [], pinAnswer: 'shown', pinCalls: 0, releasePin: () => undefined, withdrawFails: '', withdrawn: [], written: {}, releaseWorkTest: () => undefined, began: [], ...init }
  // Made before any run can ask for it, so letting go works whenever the test does it.
  const workTestOut = new Promise<void>(open => (w.releaseWorkTest = open))
  const runs: string[][] = []
  const reviewAsks: string[][] = []
  const views: { pr: string; repo?: string; cwd?: string; token?: string; fields?: string }[] = []
  const submitted: { text: string; origin: unknown }[] = []
  const tools: { name: string; isDeferred?: unknown; description: string }[] = []
  const logs: string[] = []
  const clock = mock.clock(on, { now: 1_800_000_000_000 })
  on('process.run', ($, e) => {
    // A command run after HOME was read is not an ask for the id "straight after" it (idFails): the
    // box reads HOME to find the review's record (#3843) and then runs its reader.
    afterHome = false
    runs.push([...e.argv])
    const ok = (stdout: string, exitCode = 0, stderr = '') => ({ value: { exitCode, stdout, stderr, isStdoutTruncated: false, isStderrTruncated: false } }) as never
    // #3843: the end of turn review's own test of a tool's name, run from its file by path.
    if (e.argv[0] === 'python3' && e.argv[e.argv.length - 2] === WORK_TEST_FILE) {
      if (w.workTest) return ok(w.workTest.stdout, w.workTest.exitCode, w.workTest.stderr ?? '')
      const said = WORK_TEST_SAYS[e.argv[e.argv.length - 1] as string]
      const answer = said === undefined ? ok('', 1, `the stand in for the review's test has no answer for ${e.argv[e.argv.length - 1]}`) : ok(`${said}\n`)
      return w.workTestWaits ? (workTestOut.then(() => answer) as never) : answer
    }
    // #3843: the read of the end of turn review's record, run from its file by path.
    if (e.argv[0] === 'python3' && e.argv.includes(REVIEW_FILE)) {
      reviewAsks.push([...e.argv])
      const said = w.review ?? reviewSays('none')
      return ok(said.stdout, said.exitCode, said.stderr ?? '')
    }
    if (e.argv[0] === '__modkit') {
      if (e.argv[1] === 'card') {
        if (w.cardFails) return ok('', 1, w.cardFails)
        w.cards.push(JSON.parse(e.argv[2] as string) as Card)
        return ok('')
      }
      if (e.argv[1] === 'hold' || e.argv[1] === 'release') {
        if (e.argv[1] === 'hold' && w.holdFails) return ok('', 1, w.holdFails)
        w.held.push(`${e.argv[1]} ${e.argv[2]}`)
        return ok('')
      }
      if (e.argv[1] === 'pipeline') {
        const read = w.reader(e.argv[2] as string)
        return 'fails' in read ? ok('', 1, read.fails) : ok(JSON.stringify(read))
      }
      return ok(JSON.stringify(w.goal))
    }
    if (e.argv[0] === '__steps') {
      const input = JSON.parse(e.argv[2] as string) as { heading: string; step: Record<string, unknown>; title: string }
      if (e.argv[1] === 'add') {
        w.pinCalls++
        const a = w.pinAnswer
        if (a === 'refused') return ok('', 1, 'Refused: a step needs its direct link or a location Dan can find')
        if (a === 'threw') return ok('', 1, "the manual steps mod's own hook did not answer")
        if (a === 'says nothing') return ok('{}')
        if (a === 'null') return ok('null')
        if (a === 'no answer yet') return new Promise(res => (w.releasePin = () => res(ok(JSON.stringify({ isShown: true }))))) as never
        if (a !== 'shown') return ok(JSON.stringify({ isShown: false, reason: NOT_SHOWN[a] }))
        w.pinned.push({ heading: input.heading, step: input.step })
        return ok(JSON.stringify({ isShown: true }))
      }
      if (w.withdrawFails) return ok('', 1, w.withdrawFails)
      w.withdrawn.push(input.title)
      return ok(JSON.stringify({ isWithdrawn: true }))
    }
    if (e.argv[0] === '__others') {
      if (e.argv[1] === 'card') return ok(JSON.stringify(w.stepsCard))
      if (e.argv[1] === 'emptied') return ok(JSON.stringify(w.stepsEmptied ?? null))
      if (e.argv[1] === 'compact') return ok(JSON.stringify({ queued: w.compactQueued, followUp: w.compactFollowUp }))
      return ok(JSON.stringify(w.holds))
    }
    if (e.argv[0] === '__sleep') return ok(JSON.stringify(w.asleep === true))
    if (e.argv[0] === '__jobs') return w.jobsFail ? ok('', 1, w.jobsFail) : ok(JSON.stringify(w.jobs))
    if (e.argv[0] === 'ps') {
      if (w.psFails === 'throws') return Promise.reject(new Error('ps could not be started')) as never
      if (w.psFails === 'exits') return ok('', 1, 'ps: the process list could not be read')
      if (w.psCut) return { value: { exitCode: 0, stdout: '4321 1 node\n', stderr: '', isStdoutTruncated: true, isStderrTruncated: false } } as never
      return ok('4321 1 node\n')
    }
    if (e.argv[0] === 'python3') {
      // The look is handed the process list on its standard input and a time limit of its own.
      const init = (e as { init?: { stdin?: string; timeoutMs?: number } }).init
      if (init?.stdin !== '4321 1 node\n' || !init.timeoutMs) return ok('', 1, 'the look was not handed the process list and a time limit')
      const limit = init.timeoutMs
      if (w.procsTimeout === 'throws') return clock.sleep(limit).then(() => Promise.reject(new Error('the look ran past its time limit'))) as never
      if (w.procsTimeout === 'exits') return clock.sleep(limit).then(() => ok('', 143, 'killed: ran past its time limit')) as never
      return ok(w.procs.stdout, w.procs.exitCode, w.procs.stderr ?? '')
    }
    if (e.argv[0] === '__sessions') {
      const me = { sessionId: 's1', transcriptPath: w.transcript || null, ...(w.transcript ? {} : { transcriptUnread: 'the transcript search was cut off' }) }
      if (w.registry === 'closed') return ok(JSON.stringify({ open: [], closed: [{ sessionId: 's1', transcriptPath: null }], unreadable: [], selfId: 's1' }))
      if (w.registry === 'closed naming it') return ok(JSON.stringify({ open: [], closed: [{ sessionId: 's1', transcriptPath: w.transcript }], unreadable: [], selfId: 's1' }))
      if (w.registry === 'absent') return ok(JSON.stringify({ open: [], closed: [], unreadable: [], selfId: null }))
      return ok(JSON.stringify({ open: [me], closed: [], unreadable: [], selfId: 's1' }))
    }
    if (e.argv[0] === '__live') return ok(JSON.stringify({ owed: w.owed, verdicts: w.verdicts }))
    if (e.argv[0] === 'bash' && e.argv.includes('"type":"pr-link"')) {
      if (e.argv[e.argv.length - 1] !== T) return ok('', 2, `grep: ${e.argv[e.argv.length - 1]}: No such file or directory`)
      return w.links.length ? ok(`${w.links.join('\n')}\n`) : ok('', 1)
    }
    const a = e.argv.join(' ')
    if (a.startsWith('gh pr list')) {
      const repo = e.argv[e.argv.indexOf('--repo') + 1] as string
      const g = w.open[repo] ?? { exitCode: 0, stdout: '[]' }
      return ok(g.stdout, g.exitCode, g.stderr ?? '')
    }
    if (a.startsWith('gh pr view')) {
      const init = (e as { init?: { cwd?: string; env?: Record<string, string> } }).init
      const at = (flag: string) => (e.argv.includes(flag) ? (e.argv[e.argv.indexOf(flag) + 1] as string) : undefined)
      const repo = at('--repo')
      const q = { pr: e.argv[3] as string, ...(repo ? { repo } : {}), ...(init?.cwd ? { cwd: init.cwd } : {}), ...(init?.env?.GH_TOKEN ? { token: init.env.GH_TOKEN } : {}) }
      const fields = at('--json')
      views.push({ ...q, ...(fields ? { fields } : {}) })
      const g = w.view(q)
      return ok(g.stdout, g.exitCode, g.stderr ?? '')
    }
    if (a.startsWith('gh auth status')) return ok('', 0, '  Logged in to github.com account danwright32 (keyring)\n')
    if (a.startsWith('gh auth token')) return ok('gho_test_not_a_token\n')
    return ok('', 1, 'unexpected')
  })
  on('agent.list', () => {
    if (w.agentsFail) return { deny: w.agentsFail } as never
    return { value: w.agents.map(a => (a === null ? a : { description: 'a task', type: 'general-purpose', ...a })) } as never
  })
  let afterHome = false
  on('session.id', () => {
    const answers = !w.idFails || afterHome
    afterHome = false
    return (answers ? { value: 's1' } : { deny: w.idFails }) as never
  })
  on('session.cwd', () => ({ value: w.here }) as never)
  on('env.get', ($, e) => {
    afterHome = (e as unknown as { name: string }).name === 'HOME'
    return ({ value: afterHome ? `${'/Users'}/dan` : undefined }) as never
  })
  on('fs.exists', ($, e) => {
    const at = w.disk[e.path]
    return (typeof at === 'string' ? { deny: at } : { value: at === true }) as never
  })
  on('session.start', ($, e) => ({ cwd: e.cwd }) as never)
  on('turn.complete', ($, e) => ({ text: e.answer }) as never)
  on('turn.start', ($, e) => ({ turnId: e.turnId }) as never)
  on('classic.Stop', () => ({}) as never)
  // Every other tool runs and answers nothing of note (#3770: the Bash calls the card reads).
  on('tool.call', ($, e) => {
    const id = String((e as { tool_use_id?: unknown }).tool_use_id)
    w.began.push(id)
    return (w.toolAnswers?.[id] ?? { result: '', text: '' }) as never
  })
  on('fs.write', ($, e) => {
    w.written[e.path] = e.text
    return { value: undefined } as never
  })
  on('tool.register', ($, e) => {
    tools.push({ name: e.name, isDeferred: (e as { isDeferred?: unknown }).isDeferred, description: e.description })
    return { value: { tool: `mcp__goal-box__${e.name}` } } as never
  })
  on('prompt.submit', ($, e) => {
    if ((e.origin as { kind?: string } | undefined)?.kind === 'plugin') {
      w.held.push('submit')
      const fails = w.submitFails.shift()
      if (fails === 'throw') throw new Error('the session is shutting down')
      if (fails === 'drop') return { drop: 'held by a guard beneath' } as never
    }
    submitted.push({ text: e.text, origin: e.origin })
    return { text: e.text } as never
  })
  on('ui.log', ($, e) => {
    if (w.logFails?.test(String((e as { text?: string }).text))) throw new Error('the log could not be written')
    logs.push(String((e as { text?: string }).text))
    return { value: undefined } as never
  })
  return { w, clock, cards: async () => w.cards, runs: () => runs.filter(a => !a[0]?.startsWith('__')), submitted, tools, logs, views, reviewAsks }
}

type Engine = Parameters<Parameters<typeof test>[2]>[0]
const start = async ($: Engine, isInteractive = true) => {
  await $.session.start({ cwd: '/repo', surface: isInteractive ? 'terminal' : null, isInteractive } as never)
}
// Dan types a message, or something else sends one.
const says = ($: Engine, text: string, kind = 'composer') => $.prompt.submit({ text, origin: { kind }, wait: false } as never)
type Out = { deny?: string; result?: unknown; text?: string; context?: readonly string[] }
const box = async ($: Engine, input: Record<string, unknown>, id = 'b1', more: Record<string, unknown> = {}) =>
  (await $.tool.call({ tool: TOOL, tool_use_id: id, ...input, ...more } as never)) as Out
const textOf = (o: Out) => String(o.deny ?? o.text ?? o.result ?? '')
const turnEnds = ($: Engine, more: Record<string, unknown> = {}) =>
  $.turn.complete({ answer: 'done', durationMs: 10, isAborted: false, turnId: 't1', reason: 'answer', ...more } as never)

const ASKED = { goal: 'Show a green box when the goal is met', shipped: ['#1563 closed: Goal accomplished box', 'PR #1700 merged and live'] }
const DESIGN: { goal: string; shipped: string[] } = DESIGN_FIXTURE
const MET = { state: 'none' as const, met: { condition: 'complete issue 1563', reason: 'Issue #1563 is closed and PR #1700 is merged.', id: 'met-1' } }
const withKit = { plugins: [kit, registry] }
const withLive = { plugins: [kit, registry, live] }
const withAll = { plugins: [kit, registry, live, stepsMod, statusBar, watcher, sleepMod] }

test('the tool is offered to an interactive session with its rules in the prompt, never to a headless one', withKit, async ($, on) => {
  const { tools, cards } = world(on)
  await start($)
  expect(tools.map(t => t.name)).toEqual(['goal_accomplished'])
  expect(tools[0]?.isDeferred).toBe(false)
  expect(tools[0]?.description).toMatch(/once/)
  // #3843: the description says when a later call is right, so "once" is not read as never again.
  expect(tools[0]?.description).toMatch(/again once work he then picked in a picker is finished/)
  expect(tools[0]?.description).not.toMatch(/at most once per request/)
  expect(tools[0]?.description).toMatch(/\/goal/)
})

test('a headless session is not offered the tool', withKit, async ($, on) => {
  const { tools, cards } = world(on)
  await start($, false)
  expect(tools).toEqual([])
})

test('the work Dan asked for, finished: the box is the tool result, drawn as the green headed card, the goal then each thing shipped', withKit, async ($, on) => {
  const { cards } = world(on)
  await start($)
  await says($, 'Add the goal box from issue 1563')
  const r = await box($, ASKED)
  expect(r.deny).toBeUndefined()
  // #2512: the text result leads with the goal and the shipped lines follow at once, so Claude
  // Code's collapse of a tool result after its first lines (where the card is not drawn: a resumed
  // session) still shows the goal and what shipped at rest, never a heading alone above "+5 lines".
  expect(textOf(r).split('\n')).toEqual(['GOAL ACCOMPLISHED: Show a green box when the goal is met', '• #1563 closed: Goal accomplished box', '• PR #1700 merged and live'])
  expect((r.context ?? []).join(' ')).toMatch(/do not repeat/i)
  const [c] = await cards()
  expect(c?.toolUseId).toBe('b1')
  expect(c?.title).toEqual([{ text: 'GOAL ACCOMPLISHED', color: 'success', bold: true }])
  expect(c?.lines.map(l => l.map(x => x.text).join(''))).toEqual(['Show a green box when the goal is met', '• #1563 closed: Goal accomplished box', '• PR #1700 merged and live'])
  // Settled with Dan in the #1563 design round (2026-10-24, "Green border and heading"): the border,
  // the heading and the bullets green; the goal and the shipped lines plain.
  expect(c?.border).toBe('success')
  expect(c?.lines[0]?.map(x => x.color)).toEqual([undefined])
  expect(c?.lines.slice(1).map(l => l.map(x => x.color))).toEqual([['success', undefined], ['success', undefined]])
})

// The settled design's own goal and shipped lines (docs/design/1563-goal-box.html draws them from
// its committed fixture; a mod's test loads only code, so the copy here is that file's bytes behind
// `export default `, and tests/test-mods.sh holds it byte for byte to the design's),
// drawn by the mod as the design's card draws them: the bold green heading, the goal first in plain
// text, then each shipped line behind a green bullet, in a green border (claude-config#1729).
test('the settled design\'s fixture, drawn by the mod, is the card the design draws', withKit, async ($, on) => {
  const { cards } = world(on)
  await start($)
  await says($, 'Finish the open issues')
  expect(DESIGN.shipped.length).toBeGreaterThan(0)
  expect((await box($, DESIGN)).deny).toBeUndefined()
  const [c] = await cards()
  expect(c?.title).toEqual([{ text: 'GOAL ACCOMPLISHED', color: 'success', bold: true }])
  expect(c?.border).toBe('success')
  expect(c?.lines.map(l => l.map(x => x.text).join(''))).toEqual([DESIGN.goal, ...DESIGN.shipped.map(s => `• ${s}`)])
  expect(c?.lines[0]?.map(x => x.color)).toEqual([undefined])
  expect(c?.lines.slice(1).map(l => l[0]?.color)).toEqual(DESIGN.shipped.map(() => 'success'))
})

test('never twice for one request: a second call is refused until Dan asks for something new', withKit, async ($, on) => {
  const { cards } = world(on)
  await start($)
  await says($, 'Add the goal box')
  expect((await box($, ASKED, 'b1')).deny).toBeUndefined()
  const again = await box($, ASKED, 'b2')
  expect(again.deny).toMatch(/already shown for this request/)
  // A background task's notice, or another plugin's message, is not Dan asking for something new.
  await says($, '<task-notification>done</task-notification>', 'task-notification')
  expect((await box($, ASKED, 'b3')).deny).toMatch(/already shown/)
  await says($, 'Now make the status bar quieter')
  expect((await box($, { goal: 'Quieter status bar', shipped: ['#1701 closed'] }, 'b4')).deny).toBeUndefined()
  expect((await cards()).map(c => c.toolUseId)).toEqual(['b1', 'b4'])
})

test('two calls at once show one box: the second is refused', withKit, async ($, on) => {
  const { cards } = world(on)
  await start($)
  await says($, 'Add the goal box')
  const [a, b] = await Promise.all([box($, ASKED, 'p1'), box($, ASKED, 'p2')])
  expect([a.deny, b.deny].filter(d => d === undefined)).toHaveLength(1)
  expect(String(a.deny ?? b.deny)).toMatch(/already shown/)
  expect(await cards()).toHaveLength(1)
})

test('two calls at once for a met /goal show one box', withKit, async ($, on) => {
  const { cards } = world(on, { goal: MET })
  await start($)
  const [a, b] = await Promise.all([box($, ASKED, 'g1'), box($, ASKED, 'g2')])
  expect([a.deny, b.deny].filter(d => d === undefined)).toHaveLength(1)
  expect(await cards()).toHaveLength(1)
})

test('not while a merge is unconfirmed or a deploy is not live: refused naming each, shown once settled', withLive, async ($, on) => {
  const { cards } = world(on, {
    owed: [{ key: 'k', how: 'waiting', pr: 1700, at: 1, cwd: '/repo', repo: 'danwright32/claude-config' }],
    verdicts: { 'danwright32/claude-config#1699': { state: 'deploying', at: 1 }, 'danwright32/claude-config#1698': { state: 'unconfirmed', at: 1 }, 'danwright32/claude-config#1697': { state: 'live', at: 1 } },
  })
  await start($)
  await says($, 'Add the goal box')
  const r = await box($, ASKED)
  expect(r.deny).toMatch(/the merge of danwright32\/claude-config#1700 has not been confirmed/)
  expect(r.deny).toMatch(/danwright32\/claude-config#1699 is still deploying/)
  expect(r.deny).toMatch(/danwright32\/claude-config#1698's deploy was not confirmed live/)
  expect(r.deny).not.toMatch(/1697/)
  expect(await cards()).toEqual([])
})

// #1818: a merge the helper made in the background is "waiting" in is it live's record until a turn
// end asks GitHub again, and that ask can fail (one account, a folder since removed) or never come, so
// the box asks GitHub itself, as each account, with `gh pr view`. It counts only an answer that says
// MERGED for that exact pull request in that exact repository; a call that failed, or an answer about
// another number or repository, still holds the box.
const WORK_REPO = 'acme-hq/booking'
const RAN = 1_799_999_000_000
const MERGED_AT = 1_799_999_500_000
const waiting = (pr: number, more: Partial<Owed> = {}): Owed => ({ key: `wait:${WORK_REPO}#${pr}@${RAN}`, how: 'waiting', pr, at: RAN, cwd: '/gone/worktree', selector: String(pr), named: WORK_REPO, repo: WORK_REPO, ...more })
const answer = (pr: number, more: Record<string, unknown> = {}): Gh => ({
  exitCode: 0,
  stdout: JSON.stringify({ number: pr, state: 'MERGED', mergedAt: new Date(MERGED_AT).toISOString(), url: `https://github.com/${WORK_REPO}/pull/${pr}`, ...more }),
})

test('a background merge GitHub says is MERGED, for that number in that repository, holds nothing once its card is made', withLive, async ($, on) => {
  const { views } = world(on, { owed: [waiting(4284)], verdicts: { [`${WORK_REPO}#4284`]: { state: 'live', at: MERGED_AT + 1 } }, view: q => answer(Number(q.pr)) })
  await start($)
  await says($, 'Finish milestone 77')
  expect((await box($, ASKED)).deny).toBeUndefined()
  // Asked by its repository, never the folder it was merged from (which may be gone), with every field the check reads.
  expect(views).toEqual([{ pr: '4284', repo: WORK_REPO, fields: 'number,state,mergedAt,url' }])
})

test('a background merge GitHub confirms but no card has been made for holds the box as owed its card, not as unconfirmed', withLive, async ($, on) => {
  world(on, { owed: [waiting(4284)], verdicts: { [`${WORK_REPO}#4284`]: { state: 'live', at: RAN - 1 } }, view: q => answer(Number(q.pr)) })
  await start($)
  await says($, 'Finish milestone 77')
  const r = await box($, ASKED)
  expect(r.deny).toMatch(/acme-hq\/booking#4284 was merged and has no is it live card yet/)
  expect(r.deny).not.toMatch(/not been confirmed/)
})

test('a merge GitHub only answers for as another account is confirmed: asked as each account gh is logged in to', withLive, async ($, on) => {
  const { views } = world(on, {
    owed: [waiting(4284)],
    verdicts: { [`${WORK_REPO}#4284`]: { state: 'live', at: MERGED_AT } },
    view: q => (q.token ? answer(Number(q.pr)) : { exitCode: 1, stdout: '', stderr: 'GraphQL: Could not resolve to a Repository with the name acme-hq/booking.' }),
  })
  await start($)
  await says($, 'Finish milestone 77')
  expect((await box($, ASKED)).deny).toBeUndefined()
  expect(views.map(v => v.token ?? 'active')).toEqual(['active', 'gho_test_not_a_token'])
})

test('no other answer confirms a background merge: a failed call, another number, another repository, open, or no merge time', withLive, async ($, on) => {
  const { w } = world(on, { owed: [waiting(4284)], verdicts: { [`${WORK_REPO}#4284`]: { state: 'live', at: MERGED_AT + 1 } } })
  await start($)
  await says($, 'Finish milestone 77')
  const refused: [string, Gh, RegExp][] = [
    ['a call that failed for every account', { exitCode: 1, stdout: '', stderr: 'error connecting to api.github.com' }, /error connecting to api\.github\.com/],
    ['an answer about another pull request', answer(4285), /#4285/],
    ['an answer whose number and link disagree', answer(4284, { url: `https://github.com/${WORK_REPO}/pull/4285` }), /pull\/4285/],
    ['an answer about another repository', answer(4284, { url: 'https://github.com/acme-hq/other/pull/4284' }), /acme-hq\/other/],
    ['a pull request still open', answer(4284, { state: 'OPEN', mergedAt: null }), /GitHub says it is still open/],
    ['a merge with no time', answer(4284, { mergedAt: null }), /no time/],
    ['an answer that is not JSON', { exitCode: 0, stdout: 'MERGED' }, /could not be read/],
  ]
  for (const [what, g, why] of refused) {
    w.view = () => g
    const deny = (await box($, ASKED)).deny ?? ''
    expect({ what, unconfirmed: /the merge of acme-hq\/booking#4284 has not been confirmed yet/.test(deny), why: why.test(deny) }).toEqual({ what, unconfirmed: true, why: true })
  }
  w.view = q => answer(Number(q.pr))
  expect((await box($, ASKED)).deny).toBeUndefined()
})

// #1991: is it live's turn end and the box ask GitHub through one check (mod-kit's prmerged.ts), so
// they settle a background merge alike: one GitHub says was closed unmerged, or whose number is no
// pull request in that repository, merged nothing, is let go at is it live's turn end, and owes no
// card, so it holds the box no longer.
test('a background merge GitHub says was closed, or names no pull request, holds nothing, as is it live lets it go', withLive, async ($, on) => {
  const { w } = world(on, { owed: [waiting(4284)] })
  await start($)
  await says($, 'Finish milestone 77')
  w.view = () => answer(4284, { state: 'CLOSED', mergedAt: null })
  expect((await box($, ASKED)).deny).toBeUndefined()
  // A box is shown once per request, so the next answer is asked under a new one.
  await says($, 'Finish milestone 78')
  w.view = () => ({ exitCode: 1, stdout: '', stderr: 'GraphQL: Could not resolve to a PullRequest with the number of 4284. (repository.pullRequest)' })
  expect((await box($, ASKED)).deny).toBeUndefined()
})

test('a background merge GitHub says merged before the helper run started still counts, settled by a card made since it merged (#1991)', withLive, async ($, on) => {
  const earlier = (at: number) => answer(4284, { mergedAt: new Date(at).toISOString() })
  world(on, { owed: [waiting(4284)], verdicts: { [`${WORK_REPO}#4284`]: { state: 'live', at: RAN - 3_000_000 } }, view: () => earlier(RAN - 3_600_000) })
  await start($)
  await says($, 'Finish milestone 77')
  expect((await box($, ASKED)).deny).toBeUndefined()
})

test('a pull request the helper was run for twice is asked about once and named once', withLive, async ($, on) => {
  const { views } = world(on, { owed: [waiting(4290), waiting(4290, { key: `wait:${WORK_REPO}#4290@${RAN + 5}`, at: RAN + 5 })] })
  await start($)
  await says($, 'Finish milestone 77')
  const r = await box($, ASKED)
  expect(r.deny?.match(/acme-hq\/booking#4290/g)).toHaveLength(1)
  expect(views.filter(v => !v.token)).toHaveLength(1)
})

test('a background merge naming no repository is asked about in the folder it was merged from, and named by the link GitHub gives', withLive, async ($, on) => {
  const { views } = world(on, {
    owed: [{ key: `wait:/repo#4284@${RAN}`, how: 'waiting', pr: 4284, at: RAN, cwd: '/repo', selector: '4284' }],
    verdicts: { [`${WORK_REPO}#4284`]: { state: 'live', at: MERGED_AT + 1 } },
    view: q => (q.cwd === '/repo' && !q.repo ? answer(Number(q.pr)) : { exitCode: 1, stdout: '', stderr: 'unexpected' }),
  })
  await start($)
  await says($, 'Finish milestone 77')
  expect((await box($, ASKED)).deny).toBeUndefined()
  expect(views[0]).toEqual({ pr: '4284', cwd: '/repo', fields: 'number,state,mergedAt,url' })
})

// is it live crosses a carded merge off its record only at a turn end, so a card made since then is
// read from its verdicts: one made since the merge settles it, one older (another merge's) does not.
const MERGED_4305: Owed = { key: `${WORK_REPO}#4305`, how: 'merged', pr: 4305, at: RAN, cwd: '/repo', repo: WORK_REPO }
test('a merge is it live has not yet crossed off is settled by a card made since it merged', withLive, async ($, on) => {
  world(on, { owed: [MERGED_4305], verdicts: { [`${WORK_REPO}#4305`]: { state: 'live', at: RAN + 1 } } })
  await start($)
  await says($, 'Finish milestone 77')
  expect((await box($, ASKED)).deny).toBeUndefined()
})

test('a card made before the merge does not settle it', withLive, async ($, on) => {
  world(on, { owed: [MERGED_4305], verdicts: { [`${WORK_REPO}#4305`]: { state: 'live', at: RAN - 1 } } })
  await start($)
  await says($, 'Finish milestone 77')
  expect((await box($, ASKED)).deny).toMatch(/acme-hq\/booking#4305 was merged and has no is it live card yet/)
})

// L50: is it live's record is another mod's state, read here; one not in the shape its contract
// says (an older or newer copy of that mod) holds the box, saying so, rather than failing the call.
test("an is it live record not in its contract's shape holds the box, saying so", withLive, async ($, on) => {
  const { cards } = world(on, { owed: 'not a list' as never, verdicts: { 'danwright32/claude-config#1699': null as never } })
  await start($)
  await says($, 'Add the goal box')
  const r = await box($, ASKED)
  expect(r.deny).toMatch(/is it live's record of this session's merges could not be read/)
  expect(await cards()).toEqual([])
})

test('a merge settled as live holds nothing', withLive, async ($, on) => {
  const { cards } = world(on, { verdicts: { 'danwright32/claude-config#1697': { state: 'live', at: 1 }, 'danwright32/claude-config#1696': { state: 'no-deploy', at: 1 } } })
  await start($)
  await says($, 'Add the goal box')
  expect((await box($, ASKED)).deny).toBeUndefined()
})

test('not while a pull request this session touched is still open: GitHub asked once per repository, as each account', withKit, async ($, on) => {
  const { w, runs, cards } = world(on, {
    links: [link('danwright32/claude-config', 1700), link('danwright32/claude-config', 1700, '2026-10-24T18:05:00.000Z'), link('danwright32/claude-config', 1701), link('DanWright32/Overture', 4694)],
    open: { 'danwright32/claude-config': { exitCode: 0, stdout: JSON.stringify([{ number: 1701 }, { number: 1650 }]) } },
  })
  await start($)
  await says($, 'Add the goal box')
  const r = await box($, ASKED)
  expect(r.deny).toMatch(/danwright32\/claude-config#1701 is still open/)
  expect(r.deny).not.toMatch(/1700|1650|4694/)
  expect(runs().filter(a => a[0] === 'gh' && a[1] === 'pr').map(a => a[a.indexOf('--repo') + 1])).toEqual(['danwright32/claude-config', 'danwright32/overture'])
  w.open = {}
  expect((await box($, ASKED, 'b2')).deny).toBeUndefined()
})

test('a pull request GitHub cannot be asked about holds the box, saying it could not be confirmed', withKit, async ($, on) => {
  const { cards } = world(on, { links: [link('danwright32/claude-config', 1700)], open: { 'danwright32/claude-config': { exitCode: 1, stdout: '', stderr: 'error connecting to api.github.com' } } })
  await start($)
  await says($, 'Add the goal box')
  const r = await box($, ASKED)
  expect(r.deny).toMatch(/could not ask GitHub whether danwright32\/claude-config's pull requests .*are still open \(error connecting to api.github.com\)/)
  expect(await cards()).toEqual([])
})

test("a transcript whose pull requests cannot be read holds the box, saying why", withKit, async ($, on) => {
  const { cards } = world(on, { transcript: '/elsewhere.jsonl' })
  await start($)
  await says($, 'Add the goal box')
  const r = await box($, ASKED)
  expect(r.deny).toMatch(/pull requests this session touched could not be read \(grep: \/elsewhere.jsonl: No such file or directory\)/)
  expect(await cards()).toEqual([])
})

test("a session whose transcript the registry cannot name holds the box, saying why", withKit, async ($, on) => {
  const { cards } = world(on, { transcript: '' })
  await start($)
  await says($, 'Add the goal box')
  expect((await box($, ASKED)).deny).toMatch(/the transcript search was cut off/)
  expect(await cards()).toEqual([])
})

// #2898: a live session the registry counts as ended, or holds no record of, was refused with "this
// session's transcript was not found in the session registry" though its transcript sat where Claude
// Code keeps it. Reproduced against the real registry: a session end the process outlives (a resume
// keeping its id, before the look that reopens it; any other reason, for good) leaves the record
// closed, and a closed record's transcript is never looked up. So the session's own transcript is
// first the one at its id's path, as scope-modes finds its own (#1678), and the registry's after.
for (const registry of ['closed', 'absent'] as const) {
  test(`a live session the registry holds as ${registry} finds its transcript at its id's path, and the box shows (#2898)`, withKit, async ($, on) => {
    const { cards } = world(on, { registry, disk: { [T]: true }, links: [link('danwright32/claude-config', 1700)] })
    await start($)
    await says($, 'Add the goal box')
    const r = await box($, ASKED)
    expect(r.deny).toBeUndefined()
    expect(await cards()).toHaveLength(1)
  })
}

test("a record the registry counts as ended that still names its transcript is used, as it was before (#2898)", withKit, async ($, on) => {
  const { cards } = world(on, { registry: 'closed naming it' })
  await start($)
  await says($, 'Add the goal box')
  expect((await box($, ASKED)).deny).toBeUndefined()
  expect(await cards()).toHaveLength(1)
})

test("the transcript is looked for in the folder the session started in, after it moved into another (#2898)", withKit, async ($, on) => {
  const { cards } = world(on, { registry: 'closed', disk: { [T]: true }, here: '/repo/.claude/worktrees/fix' })
  await start($)
  await says($, 'Add the goal box')
  expect((await box($, ASKED)).deny).toBeUndefined()
  expect(await cards()).toHaveLength(1)
})

test("a transcript found nowhere is refused saying where it looked and how the registry holds the session, never that a goal is open (#2898)", withKit, async ($, on) => {
  const { w, cards } = world(on, { registry: 'absent' })
  await start($)
  await says($, 'Add the goal box')
  const absent = (await box($, ASKED)).deny ?? ''
  expect(absent).toContain(`not at ${T}`)
  expect(absent).toMatch(/the session registry has no record of this session/)
  expect(absent).not.toMatch(/not found in the session registry|still set/)
  w.registry = 'closed'
  const closed = (await box($, ASKED, 'b2')).deny ?? ''
  expect(closed).toMatch(/the session registry counts this session as ended, so it did not look its transcript up/)
  expect(await cards()).toEqual([])
})

test("a check at the id's path that fails is said beside the registry's why, and the registry's transcript is used when it names one (#2898)", withKit, async ($, on) => {
  const { w, cards } = world(on, { transcript: '', disk: { [T]: "EACCES: permission denied, stat" } })
  await start($)
  await says($, 'Add the goal box')
  const r = (await box($, ASKED)).deny ?? ''
  expect(r).toContain(`whether it is at ${T} could not be checked`)
  expect(r).toMatch(/permission denied/)
  expect(r).toMatch(/the transcript search was cut off/)
  w.transcript = T
  expect((await box($, ASKED, 'b2')).deny).toBeUndefined()
  expect(await cards()).toHaveLength(1)
})

test('not while an agent this session started is still running; one a plugin started, or one finished, holds nothing', withKit, async ($, on) => {
  const { w, cards } = world(on, { agents: [{ id: 'a1', status: 'running', description: 'Fix issue 1702' }, { id: 'a2', status: 'completed' }, { id: 'a3', status: 'running', spawnedBy: 'auto-session-name' }, { id: 'a4', status: 'idle' }] })
  await start($)
  await says($, 'Add the goal box')
  const r = await box($, ASKED)
  expect(r.deny).toMatch(/the agent "Fix issue 1702" is still running/)
  expect(r.deny).not.toMatch(/a3|auto-session-name/)
  w.agents = [{ id: 'a1', status: 'completed' }]
  expect((await box($, ASKED, 'b2')).deny).toBeUndefined()
})

// #3770: the box's holds now come from mod-kit's one list of what is in flight (hooks/mod-kit/
// inflight.ts), asked for the box's three kinds. Written against the box as it was before that
// change and passing there: the whole refusal, word for word and in order, is what it was.
test('parity: an agent, a merge and an open pull request refuse in the same words and order as before the shared list (#3770)', withLive, async ($, on) => {
  const { w } = world(on, {
    agents: [{ id: 'a1', status: 'running', description: 'Fix issue 1702' }, { id: 'a2', status: 'idle' }, { id: 'a3', status: 'waiting', spawnedBy: 'auto-session-name' }, { id: 'a4', status: 'pending', description: 'Second' }],
    verdicts: { 'danwright32/claude-config#1699': { state: 'deploying', at: 1 } },
    links: [link('danwright32/claude-config', 1701)],
    open: { 'danwright32/claude-config': { exitCode: 0, stdout: JSON.stringify([{ number: 1701 }]) } },
  })
  await start($)
  await says($, 'Add the goal box')
  expect((await box($, ASKED)).deny).toBe(
    'No box yet: the agent "Fix issue 1702" is still running; the agent "Second" is still pending; danwright32/claude-config#1699 is still deploying: check it is live and call the is it live card tool again; danwright32/claude-config#1701 is still open: merge it, or close it if it is not part of this work.',
  )
  w.agentsFail = 'the agent list is gone'
  const r = (await box($, ASKED, 'b2')).deny ?? ''
  expect(r).toMatch(/^No box yet: the session's agents could not be listed \(.*the agent list is gone.*\), so whether one is still working is not known; /)
  // An entry of the list that is not an agent holds the box as unread, rather than throwing out of it.
  w.agentsFail = ''
  w.agents = [null, { id: 'a1', status: 'running', description: 'Fix issue 1702' }]
  expect((await box($, ASKED, 'b3')).deny ?? '').toMatch(/^No box yet: .*an entry of the agent list is not an agent/)
})

test('a /goal still set is never shown over, and a goal that cannot be read holds the box', withKit, async ($, on) => {
  const { cards } = world(on, { goal: { state: 'set', condition: 'complete milestone 80' } })
  await start($)
  await says($, 'Add the goal box')
  expect((await box($, ASKED)).deny).toMatch(/the \/goal "complete milestone 80" is still set/)
})

test('a /goal that cannot be read holds the box, saying why', withKit, async ($, on) => {
  const { cards } = world(on, { goal: { state: 'unreadable', why: 'grep: read error' } })
  await start($)
  await says($, 'Add the goal box')
  expect((await box($, ASKED)).deny).toMatch(/could not be read \(grep: read error\)/)
})

// Measured on 2.1.310: the met record is written after the Stop hooks, before the turn ends, so the
// mod asks at turn.complete and reads no Stop for it (#875); classic.Stop is the close card's alone.
test('a /goal met: once the turn has ended the session is sent one prompt to show the box, which names the goal', withKit, async ($, on) => {
  const { w, submitted, cards } = world(on, { goal: { state: 'set', condition: 'complete issue 1563' } })
  await start($)
  await turnEnds($)
  expect(submitted).toEqual([])
  w.goal = MET
  await turnEnds($)
  expect(submitted.map(s => s.text)).toEqual([expect.stringContaining('GOAL ACCOMPLISHED. The /goal "complete issue 1563" was judged met.')])
  expect(submitted[0]?.text).toContain(TOOL)
  await turnEnds($)
  expect(submitted).toHaveLength(1)
  const r = await box($, { goal: 'whatever Claude calls it', shipped: ['#1563 closed'] })
  expect(r.deny).toBeUndefined()
  expect(textOf(r).split('\n')[0]).toBe('GOAL ACCOMPLISHED: complete issue 1563')
  // Once shown, never again for that goal, nor for the request it answered, until Dan asks for more.
  expect((await box($, { goal: 'again', shipped: ['x'] }, 'b2')).deny).toMatch(/already shown/)
  await turnEnds($)
  expect(submitted).toHaveLength(1)
  expect(await cards()).toHaveLength(1)
})

// L368: a met goal is recorded as asked about only once its prompt has entered, so a failure (one
// thrown, or one a hook beneath dropped) is said and asked again at the next turn end, never lost.
test('a prompt for a met goal that could not be sent is said and sent again at the next turn end', withKit, async ($, on) => {
  const { submitted, logs } = world(on, { goal: MET, submitFails: ['throw', 'drop'] })
  await start($)
  await turnEnds($)
  expect(submitted).toEqual([])
  expect(logs.join('\n')).toMatch(/could not be asked for \(.+\); it is asked again at the next turn end/)
  await turnEnds($)
  expect(submitted).toEqual([])
  expect(logs.join('\n')).toMatch(/could not be asked for \(held by a guard beneath\); it is asked again at the next turn end/)
  await turnEnds($)
  expect(submitted.map(x => x.text)).toEqual([expect.stringContaining('GOAL ACCOMPLISHED. The /goal "complete issue 1563" was judged met.')])
  await turnEnds($)
  expect(submitted).toHaveLength(1)
})

// #2132: the prompt for a met goal waits until the session is idle, and mod-kit's reload of goal-box
// in that time would drop it, so it holds that reload back until sent, thrown or dropped.
const GOAL_HELD = `hold ${JSON.stringify({ mod: 'goal-box', id: 'ask', what: 'the prompt asking for the Goal accomplished box', ms: 60 * 60_000 })}`
const GOAL_LET_GO = `release ${JSON.stringify({ mod: 'goal-box', id: 'ask' })}`
test('the prompt for a met goal holds back a reload of goal-box while it waits, and lets go sent, thrown or dropped (#2132)', withKit, async ($, on) => {
  const { w } = world(on, { goal: MET, submitFails: ['throw', 'drop'] })
  await start($)
  await turnEnds($)
  await turnEnds($)
  await turnEnds($)
  expect(w.held).toEqual([GOAL_HELD, 'submit', GOAL_LET_GO, GOAL_HELD, 'submit', GOAL_LET_GO, GOAL_HELD, 'submit', GOAL_LET_GO])
})

test('a hold mod-kit refuses is said in the debug log, and the prompt for a met goal is sent as before (#2132)', withKit, async ($, on) => {
  const { w, submitted, logs } = world(on, { goal: MET, holdFails: 'mod-kit is not loaded' })
  await start($)
  await turnEnds($)
  expect(w.held).toEqual(['submit'])
  expect(submitted).toHaveLength(1)
  expect(logs).toContain('goal-box: could not hold back a reload while it waits on the prompt asking for the Goal accomplished box, so one now would drop that wait (mod-kit is not loaded)')
})

test("a subagent's turn end, or an interrupted turn, never sends the prompt", withKit, async ($, on) => {
  const { submitted } = world(on, { goal: MET })
  await start($)
  await turnEnds($, { agentId: 'a1' })
  await turnEnds($, { isAborted: true, reason: 'aborted' })
  expect(submitted).toEqual([])
})

test('a headless session is never asked to show the box', withKit, async ($, on) => {
  const { submitted } = world(on, { goal: MET })
  await start($, false)
  await turnEnds($)
  expect(submitted).toEqual([])
})

test('a met goal whose box is held by an open merge is not shown; asked once, it is not asked again', withLive, async ($, on) => {
  const { submitted, cards } = world(on, { goal: MET, owed: [{ key: 'k', how: 'waiting', pr: 1700, at: 1, cwd: '/repo', repo: 'danwright32/claude-config' }] })
  await start($)
  await turnEnds($)
  expect(submitted).toHaveLength(1)
  expect((await box($, { goal: 'x', shipped: ['y'] })).deny).toMatch(/has not been confirmed/)
  await turnEnds($)
  expect(submitted).toHaveLength(1)
  expect(await cards()).toEqual([])
})

// #2523: with no /goal, the only reminder to call the tool was the session reflection's last line,
// and a reflection folded into the issue review dropped it (L27). So the mod asks too, at the turn
// end where work measurably shipped: an is it live card made since Dan's last message, nothing still
// in flight, and no box for this request. Once per request, whatever the session then decides.
const NOW = 1_800_000_000_000
const CARDED = { 'danwright32/claude-config#1700': { state: 'live', at: NOW } }
const ASKS_DONE = 'GOAL ACCOMPLISHED? Since Dan\'s last message'
test('no /goal: a merge carded since Dan\'s message, nothing in flight and no box, and the session is asked once whether the work is finished (#2523)', withLive, async ($, on) => {
  const { submitted, cards } = world(on, { verdicts: CARDED })
  await start($)
  await turnEnds($)
  expect(submitted).toEqual([])
  await says($, 'Merge PR 1700')
  await turnEnds($)
  expect(submitted.filter(s => s.text.startsWith(ASKS_DONE))).toHaveLength(1)
  expect(submitted.at(-1)?.text).toContain(TOOL)
  expect(submitted.at(-1)?.origin).toMatchObject({ kind: 'plugin' })
  await turnEnds($)
  expect(submitted.filter(s => s.text.startsWith(ASKS_DONE))).toHaveLength(1)
  expect((await box($, ASKED)).deny).toBeUndefined()
  expect(await cards()).toHaveLength(1)
})

test('no /goal: a box already shown for the request asks nothing (#2523)', withLive, async ($, on) => {
  const shown = world(on, { verdicts: CARDED })
  await start($)
  await says($, 'Merge PR 1700')
  expect((await box($, ASKED)).deny).toBeUndefined()
  await turnEnds($)
  expect(shown.submitted.filter(s => s.text.startsWith(ASKS_DONE))).toEqual([])
})

test('no /goal: a card made before Dan\'s message asks nothing (#2523)', withLive, async ($, on) => {
  const { submitted } = world(on, { verdicts: { 'danwright32/claude-config#1700': { state: 'live', at: NOW - 1 } } })
  await start($)
  await says($, 'Now make the status bar quieter')
  await turnEnds($)
  expect(submitted.filter(s => s.text.startsWith(ASKS_DONE))).toEqual([])
})

test('no /goal: an agent still running, or a deploy not yet live, asks nothing; once settled it asks (#2523)', withLive, async ($, on) => {
  const { w, submitted } = world(on, { verdicts: { 'danwright32/claude-config#1700': { state: 'deploying', at: NOW } }, agents: [{ id: 'a1', status: 'running', description: 'Fix issue 1702' }] })
  await start($)
  await says($, 'Merge PR 1700')
  await turnEnds($)
  expect(submitted.filter(s => s.text.startsWith(ASKS_DONE))).toEqual([])
  w.verdicts = CARDED
  await turnEnds($)
  expect(submitted.filter(s => s.text.startsWith(ASKS_DONE))).toEqual([])
  w.agents = [{ id: 'a1', status: 'completed' }]
  await turnEnds($)
  expect(submitted.filter(s => s.text.startsWith(ASKS_DONE))).toHaveLength(1)
})

test('no /goal: a /goal still set, a subagent or an interrupted turn is never asked (#2523)', withLive, async ($, on) => {
  const { w, submitted } = world(on, { verdicts: CARDED, goal: { state: 'set', condition: 'complete milestone 80' } })
  await start($)
  await says($, 'Merge PR 1700')
  await turnEnds($)
  w.goal = { state: 'none' }
  await turnEnds($, { agentId: 'a1' })
  await turnEnds($, { isAborted: true, reason: 'aborted' })
  expect(submitted.filter(s => s.text.startsWith(ASKS_DONE))).toEqual([])
})

test('no /goal: a headless session is never asked (#2523)', withLive, async ($, on) => {
  const { submitted } = world(on, { verdicts: CARDED })
  await start($, false)
  await says($, 'Merge PR 1700')
  await turnEnds($)
  expect(submitted.filter(s => s.text.startsWith(ASKS_DONE))).toEqual([])
})

test('no /goal: a question that could not be sent is said and sent again at the next turn end (#2523)', withLive, async ($, on) => {
  const { submitted, logs } = world(on, { verdicts: CARDED, submitFails: ['drop'] })
  await start($)
  await says($, 'Merge PR 1700')
  await turnEnds($)
  expect(submitted.filter(s => s.text.startsWith(ASKS_DONE))).toEqual([])
  expect(logs.join('\n')).toMatch(/could not be asked whether the work is finished \(held by a guard beneath\); it is asked again at the next turn end/)
  await turnEnds($)
  expect(submitted.filter(s => s.text.startsWith(ASKS_DONE))).toHaveLength(1)
})

test('a subagent cannot show the box, and a call a guard refuses is refused before anything is read', withKit, async ($, on) => {
  const { runs, cards } = world(on)
  await start($)
  await says($, 'Add the goal box')
  expect((await box($, ASKED, 'b1', { agentId: 'a1' })).deny).toMatch(/only the main conversation/i)
  expect((await box($, { goal: 'SCREEN-REFUSES', shipped: ['x'] })).deny).toBe('Blocked: this carries a secret.')
  expect(runs()).toEqual([])
  expect(await cards()).toEqual([])
})

test('a call missing the goal or what shipped is refused by name', withKit, async ($, on) => {
  const { cards } = world(on)
  await start($)
  await says($, 'Add the goal box')
  expect((await box($, { goal: '', shipped: ['x'] })).deny).toMatch(/goal must be/)
  expect((await box($, { goal: 'x', shipped: [] })).deny).toMatch(/shipped is empty/)
  expect((await box($, { goal: 'x', shipped: ['ok', 7] })).deny).toMatch(/shipped line 2/)
  expect((await box($, { goal: 'x' })).deny).toMatch(/shipped must be a list/)
})

test("mod-kit unable to draw the card still shows the box as text, the goal first, and says why in the debug log", withKit, async ($, on) => {
  const { logs, cards } = world(on, { cardFails: 'a card needs a title of one or more runs' })
  await start($)
  await says($, 'Add the goal box')
  const r = await box($, ASKED)
  expect(r.deny).toBeUndefined()
  expect(textOf(r).split('\n')[0]).toBe('GOAL ACCOMPLISHED: Show a green box when the goal is met')
  expect(logs.join('\n')).toMatch(/goal-box: the card could not be drawn \(a card needs a title/)
})

// ---- The close this session card (#3770) ----
// Dan, 2026-11-26: pinned only once the Goal accomplished box was shown for his latest request,
// every reading is clean and the session has stayed quiet for QUIET_MS; down at any new turn; back
// only after the next box. A reading that cannot be taken withholds it, with two exceptions, both in
// the check for a process left behind, both noted in the reasons file and neither a reason to pin:
// a process whose own parents cannot be followed, and a check that could not be finished at all.
// The two readings of a process a command left behind (3.76.1) can only withhold it.
const REASONS = `${'/Users'}/dan/.claude/state/close-session/s1.json`
type Engine$ = Parameters<Parameters<typeof test>[2]>[0]
const stopped = ($: Engine$, more: Record<string, unknown> = {}) =>
  ($ as unknown as { classic: { Stop: (e: unknown) => Promise<unknown> } }).classic.Stop({ session_id: 's1', transcript_path: T, stop_hook_active: false, background_tasks: [], session_crons: [], ...more })
const turnStarts = ($: Engine$, turnId = 't2') => ($ as unknown as { turn: { start: (e: unknown) => Promise<unknown> } }).turn.start({ text: '', turnId })
// One turn of work that ends with the box shown, its stop and its end, then the quiet period.
const workedAndQuiet = async ($: Engine$, clock: { advance: (ms: number) => Promise<void> }, o: { stop?: Record<string, unknown>; answer?: string; box?: boolean; id?: string } = {}) => {
  if (o.box !== false) expect((await box($, ASKED, o.id ?? 'b1')).deny).toBeUndefined()
  await stopped($, o.stop)
  await turnEnds($, { answer: o.answer ?? 'Merged and live.' })
  await clock.advance(QUIET_MS)
}
const reasonsOf = (w: World) => JSON.parse(w.written[REASONS] ?? 'null') as { pinned: boolean; reasons: string[]; notes?: string[]; attached?: number | null } | null
const bash = ($: Engine$, command: string, more: Record<string, unknown> = {}) => $.tool.call({ tool: 'Bash', tool_use_id: 'x1', command, ...more } as never)
// The look for a process left behind, among the python3 runs: the one program handed over with -c
// straight after -I (the box's own read of the review's record, #3843, runs a file by path).
const isLook = (a: string[]) => a[0] === 'python3' && a[2] === '-c'

test('all clear: once the box is shown and the session stays quiet, exactly one card is pinned, for this session alone and with no Done (#3770)', withAll, async ($, on) => {
  const { w, clock } = world(on)
  await start($)
  await says($, 'Add the goal box')
  await workedAndQuiet($, clock)
  expect(w.pinned).toHaveLength(1)
  expect(w.pinned[0]?.heading).toBe(CLOSE_HEADING)
  expect(w.pinned[0]?.heading).toBe('Nothing this session can see is running or waiting')
  expect(w.pinned[0]?.step).toMatchObject({ title: 'Close this session if you have nothing more for it', sessionOnly: true, noDone: true, clicks: ['Type /exit and press Return', 'Or close the tab'] })
  expect(String(w.pinned[0]?.step.location)).toMatch(/^The Terminal tab showing this session/)
  expect(reasonsOf(w)).toMatchObject({ pinned: true, reasons: [] })
  // Nothing more pinned while the session stays quiet.
  await clock.advance(QUIET_MS * 3)
  expect(w.pinned).toHaveLength(1)
})

test('each reading false in turn withholds the card and writes its reason; all clear again pins it (#3770)', withAll, async ($, on) => {
  const { w, clock } = world(on, { links: [link('danwright32/claude-config', 1701)] })
  await start($)
  await says($, 'Add the goal box')
  expect((await box($, ASKED)).deny).toBeUndefined()
  const cases: [string, () => void, () => void, Record<string, unknown>?, string?][] = [
    ['the agent "Mate" is idle', () => (w.agents = [{ id: 'a1', status: 'idle', description: 'Mate' }]), () => (w.agents = [])],
    ['the agent "Fixer", which a mod started', () => (w.agents = [{ id: 'a1', status: 'running', description: 'Fixer', spawnedBy: 'x' }]), () => (w.agents = [])],
    ['background shell b1', () => undefined, () => undefined, { background_tasks: [{ id: 'b1', type: 'shell', status: 'running', command: 'npm test' }] }],
    ['background monitor m1', () => undefined, () => undefined, { background_tasks: [{ id: 'm1', type: 'monitor', status: 'running', description: 'watch CI' }] }],
    ['scheduled wake up', () => undefined, () => undefined, { session_crons: [{ id: 'c1', schedule: '*/5 * * * *', recurring: true, prompt: '/loop' }] }],
    ['the background job "dev server", kept', () => (w.jobs = [{ id: 'j1', label: 'dev server', kept: true, state: 'running' }]), () => (w.jobs = [])],
    ['is still deploying', () => (w.verdicts = { 'danwright32/claude-config#1699': { state: 'deploying', at: 1 } }), () => (w.verdicts = {})],
    ['danwright32/claude-config#1701 is still open', () => (w.open = { 'danwright32/claude-config': { exitCode: 0, stdout: '[{"number":1701}]' } }), () => (w.open = {})],
    ['the /goal "ship it" is still set', () => (w.goal = { state: 'set', condition: 'ship it' }), () => (w.goal = { state: 'none' })],
    ['the manual step "Add the key" is not done', () => (w.stepsCard = { heading: 'h', steps: [{ title: 'Add the key', url: 'https://a.example', pinnedBy: 's1' }] }), () => (w.stepsCard = null)],
    ['a compact is queued', () => (w.compactQueued = true), () => (w.compactQueued = false)],
    ['handoff note', () => (w.compactFollowUp = { note: 'n', ranAt: 1, compacted: true }), () => (w.compactFollowUp = null)],
    ['is-it-live is waiting to send the prompt for a card', () => (w.holds = [{ mod: 'is-it-live', id: 'p', what: 'the prompt for a card', until: 1_900_000_000_000 }]), () => (w.holds = [])],
    ["the turn's answer ends on a question", () => undefined, () => undefined, undefined, 'Merged.\n\nShall I close the issue?'],
  ]
  for (const [words, bad, good, stop, answer] of cases) {
    bad()
    await stopped($, stop)
    await turnEnds($, { answer: answer ?? 'Merged and live.' })
    await clock.advance(QUIET_MS)
    expect({ words, pinned: w.pinned.length }).toEqual({ words, pinned: 0 })
    expect({ words, reasons: (reasonsOf(w)?.reasons ?? []).join(' | ') }).toEqual({ words, reasons: expect.stringContaining(words) })
    expect(reasonsOf(w)?.pinned).toBe(false)
    good()
  }
  await stopped($)
  await turnEnds($)
  await clock.advance(QUIET_MS)
  expect(w.pinned).toHaveLength(1)
})

// #3770, reopened 2026-11-26. Dan's first real test: no card after five minutes, and five of the
// eleven reasons written were undone steps other sessions had pinned, carried into this session's
// card from the store its folder shares with them. His answer: "Only that session's own steps". A
// step says which session pinned it (manual steps' pinnedBy), and this session is 's1' here.
test("another session's undone step on this session's card does not withhold the close card (#3770)", withAll, async ($, on) => {
  const { w, clock } = world(on, { stepsCard: { heading: 'h', steps: [{ title: 'Post the note', url: 'https://a.example', pinnedBy: 's2' }] } })
  await start($)
  await says($, 'Add the goal box')
  await workedAndQuiet($, clock)
  expect(reasonsOf(w)).toMatchObject({ pinned: true, reasons: [] })
  expect(w.pinned).toHaveLength(1)
})

// The shape Dan's test session held: it ran where no repository is, so one key of the store had
// collected steps from sessions working in several other projects, all kept before a step recorded
// its session (manual steps stamps those as an earlier session's when it carries them in).
test("undone steps that sessions working in other projects left under this folder's key do not withhold the close card (#3770)", withAll, async ($, on) => {
  const others = [
    { title: 'Renew the certificate', url: 'https://certs.example', pinnedBy: 'an earlier session' },
    { title: 'Approve the invoice run', location: 'The invoicing app, Runs', pinnedBy: 'an earlier session' },
    { title: 'Rotate the signing key', location: 'The keys page', pinnedBy: 's3' },
  ]
  const { w, clock } = world(on, { stepsCard: { heading: 'Carried', steps: others } })
  await start($)
  await says($, 'Add the goal box')
  await workedAndQuiet($, clock)
  expect(reasonsOf(w)).toMatchObject({ pinned: true, reasons: [] })
  expect(w.pinned).toHaveLength(1)
})

test("this session's own undone step still withholds the close card, and is the only step named, beside another session's (#3770)", withAll, async ($, on) => {
  const { w, clock } = world(on, { stepsCard: { heading: 'h', steps: [{ title: 'Theirs', url: 'https://a.example', pinnedBy: 's2' }, { title: 'Mine', url: 'https://b.example', pinnedBy: 's1' }] } })
  await start($)
  await says($, 'Add the goal box')
  await workedAndQuiet($, clock)
  expect(w.pinned).toEqual([])
  expect(reasonsOf(w)).toMatchObject({ pinned: false, reasons: ['the manual step "Mine" is not done'] })
})

test('an undone step that does not say which session pinned it withholds the close card as unread, saying so (#3770)', withAll, async ($, on) => {
  const { w, clock } = world(on, { stepsCard: { heading: 'h', steps: [{ title: 'Pinned before', url: 'https://a.example' }] } })
  await start($)
  await says($, 'Add the goal box')
  await workedAndQuiet($, clock)
  expect(w.pinned).toEqual([])
  expect(reasonsOf(w)?.reasons.join(' | ')).toMatch(/"Pinned before" is not done, and the card does not say which session pinned it/)
})

// The steps reading asks for this session's id to tell its own steps from other sessions'. When
// that ask is refused the list is handed no id, never this session's guessed, and an undone step
// on the card then holds it as unread.
test("this session's id refused while its card holds an undone step withholds the close card, saying whose step it is could not be read (#3770)", withAll, async ($, on) => {
  const { w, clock } = world(on, { stepsCard: { heading: 'h', steps: [{ title: 'Mine', url: 'https://b.example', pinnedBy: 's1' }] } })
  await start($)
  await says($, 'Add the goal box')
  w.idFails = 'the session id could not be read'
  await workedAndQuiet($, clock)
  expect(w.pinned).toEqual([])
  expect(reasonsOf(w)?.reasons.join(' | ')).toMatch(/"Mine" is not done, and this session's id was not handed over, so whose step it is could not be read/)
})

test('a reading that cannot be taken withholds the card as unread: no stop recorded, a list missing, a noun that throws, a goal unreadable (#3770)', withAll, async ($, on) => {
  const { w, clock } = world(on)
  await start($)
  await says($, 'Add the goal box')
  expect((await box($, ASKED)).deny).toBeUndefined()
  // The turn's stop never reached the mod (a missing managed setting, #875).
  await turnEnds($)
  await clock.advance(QUIET_MS)
  expect(w.pinned).toEqual([])
  expect(reasonsOf(w)?.reasons.join(' ')).toMatch(/background work in flight .* could not be read/)
  const cases: [() => void, () => void, Record<string, unknown> | undefined, RegExp][] = [
    [() => undefined, () => undefined, { background_tasks: undefined }, /background work in flight .* could not be read/],
    [() => undefined, () => undefined, { session_crons: 'x' }, /scheduled wake ups .* could not be read/],
    [() => (w.jobsFail = 'the job record could not be read'), () => (w.jobsFail = ''), undefined, /job watcher's list of background jobs could not be read \(.*the job record could not be read/],
    [() => (w.agentsFail = 'agents gone'), () => (w.agentsFail = ''), undefined, /agents could not be listed/],
    [() => (w.agents = [null]), () => (w.agents = []), undefined, /an entry of the agent list is not an agent/],
    [() => (w.goal = { state: 'unreadable', why: 'grep failed' }), () => (w.goal = { state: 'none' }), undefined, /\/goal could not be read \(grep failed\)/],
    [() => (w.stepsCard = { steps: 'x' }), () => (w.stepsCard = null), undefined, /manual steps card could not be read/],
  ]
  for (const [bad, good, stop, words] of cases) {
    bad()
    await stopped($, stop)
    await turnEnds($)
    await clock.advance(QUIET_MS)
    expect(w.pinned).toEqual([])
    expect(reasonsOf(w)?.reasons.join(' ')).toMatch(words)
    good()
  }
})

// The quiet period outlasts the subagent harvest's 180 second limit (its async end of turn hook) by 30
// seconds, so the card cannot go up while that hook may still be running: nothing at 180, the card at 210.
test('the card waits 3 minutes 30 seconds after a turn ends: nothing at 180 seconds, the card at 210 (#3770)', withAll, async ($, on) => {
  const { w, clock } = world(on)
  await start($)
  await says($, 'Add the goal box')
  expect((await box($, ASKED)).deny).toBeUndefined()
  await stopped($)
  await turnEnds($)
  await clock.advance(180_000)
  expect(w.pinned).toEqual([])
  await clock.advance(29_999)
  expect(w.pinned).toEqual([])
  await clock.advance(1)
  expect(w.pinned).toHaveLength(1)
})

test('a turn that starts inside the quiet period pins nothing, and nor does its own end until it has been quiet (#3770)', withAll, async ($, on) => {
  const { w, clock } = world(on)
  await start($)
  await says($, 'Add the goal box')
  expect((await box($, ASKED)).deny).toBeUndefined()
  await stopped($)
  await turnEnds($)
  await clock.advance(QUIET_MS - 1)
  await turnStarts($)
  await clock.advance(QUIET_MS * 2)
  expect(w.pinned).toEqual([])
  // A message of any origin inside the quiet period does the same.
  await stopped($)
  await turnEnds($)
  await clock.advance(QUIET_MS - 1)
  await says($, '<task-notification>done</task-notification>', 'task-notification')
  await clock.advance(QUIET_MS * 2)
  expect(w.pinned).toEqual([])
  await stopped($)
  await turnEnds($)
  await clock.advance(QUIET_MS)
  expect(w.pinned).toHaveLength(1)
})

test('a session Dan only chatted with, with no box, never gets the card, and says why (#3770)', withAll, async ($, on) => {
  const { w, clock } = world(on)
  await start($)
  await says($, 'What does the job watcher do?')
  await workedAndQuiet($, clock, { box: false })
  await clock.advance(QUIET_MS * 3)
  expect(w.pinned).toEqual([])
  expect(reasonsOf(w)).toMatchObject({ pinned: false, reasons: [expect.stringMatching(/no Goal accomplished box/)] })
})

// The card is this request's only once its pin came back shown. Three review findings were each one
// outcome that kept the claim without a card (#3770), so every outcome manual steps' noun can have is
// a row: whether a later quiet end under the same request tries again, and what the reasons file says.
const PIN_ROWS: [PinAnswer, RegExp | undefined][] = [
  ['shown', undefined],
  ['not shown: nobody at the prompt', /the card could not be shown \(this session has nobody at its prompt\)/],
  ['not shown: carried steps held', /the card could not be shown \(the steps carried from an earlier session are held/],
  ['not shown: taken away', /the card could not be shown \(the card was taken away as it was added\)/],
  ['not shown: not drawn', /the card could not be shown \(the card could not be shown \(no pane\)\)/],
  ['refused', /the card could not be pinned \(.*Refused: a step needs its direct link/],
  ['threw', /the card could not be pinned \(.*the manual steps mod's own hook did not answer/],
  ['says nothing', /the card could not be shown \(its answer did not say it was shown\)/],
  ['null', /the card could not be shown \(its answer did not say it was shown\)/],
  ['no answer yet', undefined],
]
for (const [answer, why] of PIN_ROWS) {
  test(`a pin that comes back ${answer}: ${answer === 'shown' ? 'the request has its card, and no later quiet end pins again' : 'nothing is claimed, and the next quiet end under the same request tries again'} (#3770)`, withAll, async ($, on) => {
    const { w, clock } = world(on, { pinAnswer: answer })
    await start($)
    await says($, 'Add the goal box')
    await workedAndQuiet($, clock)
    expect(w.pinCalls).toBe(1)
    if (why) expect(reasonsOf(w)).toMatchObject({ pinned: false, reasons: [expect.stringMatching(why)] })
    w.pinAnswer = 'shown'
    const quietEnd = async () => {
      await stopped($)
      await turnEnds($)
      await clock.advance(QUIET_MS)
    }
    await quietEnd()
    expect({ answer, tries: w.pinCalls, pinned: w.pinned.length }).toEqual({ answer, tries: answer === 'shown' ? 1 : 2, pinned: 1 })
    expect(reasonsOf(w)).toMatchObject({ pinned: true, reasons: [] })
    // Shown now, so the claim holds: no further quiet end under this request pins again.
    w.releasePin()
    await quietEnd()
    expect({ answer, tries: w.pinCalls }).toEqual({ answer, tries: answer === 'shown' ? 1 : 2 })
  })
}

test('a pin still out when a new turn starts is taken down as soon as it comes back shown (#3770)', withAll, async ($, on) => {
  const { w, clock } = world(on, { pinAnswer: 'no answer yet' })
  await start($)
  await says($, 'Add the goal box')
  await workedAndQuiet($, clock)
  await turnStarts($)
  expect(w.withdrawn).toEqual([])
  w.releasePin()
  await clock.settle()
  expect(w.withdrawn).toEqual([CLOSE_TITLE])
})

test('a card that could not be taken down at a new turn is tried again at the next one (#3770)', withAll, async ($, on) => {
  const { w, clock } = world(on, { withdrawFails: "the manual steps mod's own hook did not answer" })
  await start($)
  await says($, 'Add the goal box')
  await workedAndQuiet($, clock)
  expect(w.pinned).toHaveLength(1)
  await turnStarts($)
  expect(w.withdrawn).toEqual([])
  w.withdrawFails = ''
  await turnStarts($, 't3')
  expect(w.withdrawn).toEqual([CLOSE_TITLE])
  // Taken down, so the turn after has nothing to take down.
  await turnStarts($, 't4')
  expect(w.withdrawn).toEqual([CLOSE_TITLE])
})

test('while Dan is asleep a stop records nothing, so its lists read as unread and no card is pinned; after he wakes it can be (#3770)', withAll, async ($, on) => {
  const { w, clock } = world(on, { asleep: true })
  await start($)
  await says($, 'Add the goal box')
  await workedAndQuiet($, clock)
  expect(w.pinned).toEqual([])
  expect(reasonsOf(w)?.reasons.join(' ')).toMatch(/background work in flight .* could not be read \(this turn's stop was not recorded\)/)
  w.asleep = false
  await stopped($)
  await turnEnds($)
  await clock.advance(QUIET_MS)
  expect(w.pinned).toHaveLength(1)
})

test('a headless session never gets the card (#3770)', withAll, async ($, on) => {
  const { w, clock } = world(on)
  await start($, false)
  await says($, 'Add the goal box')
  await stopped($)
  await turnEnds($)
  await clock.advance(QUIET_MS)
  expect(w.pinned).toEqual([])
})

test('a new turn withdraws the card; a second idle end under the same request pins nothing; the next request with its box pins it again, once (#3770)', withAll, async ($, on) => {
  const { w, clock } = world(on)
  await start($)
  await says($, 'Add the goal box')
  await workedAndQuiet($, clock)
  expect(w.pinned).toHaveLength(1)
  // A wake up, a task notification or a mod's prompt starts a turn: the card comes down, withdrawn.
  await turnStarts($)
  expect(w.withdrawn).toEqual([CLOSE_TITLE])
  await stopped($)
  await turnEnds($)
  await clock.advance(QUIET_MS)
  expect(w.pinned).toHaveLength(1)
  // Dan asks for more: no card until its own box.
  await says($, 'Now make the status bar quieter')
  await workedAndQuiet($, clock, { box: false })
  expect(w.pinned).toHaveLength(1)
  expect(reasonsOf(w)?.reasons.join(' ')).toMatch(/no Goal accomplished box/)
  await workedAndQuiet($, clock, { id: 'b2' })
  expect(w.pinned).toHaveLength(2)
  await turnStarts($, 't3')
  expect(w.withdrawn).toEqual([CLOSE_TITLE, CLOSE_TITLE])
})

test('a process carrying this session\'s id withholds the card; a look that fails or runs past its time limit says nothing either way, so the other readings decide (#3770)', withAll, async ($, on) => {
  const { w, clock, runs } = world(on, { procs: { exitCode: 0, stdout: JSON.stringify({ found: [{ pid: 4321, name: 'node' }] }) } })
  await start($)
  await says($, 'Add the goal box')
  await workedAndQuiet($, clock)
  expect(w.pinned).toEqual([])
  expect(reasonsOf(w)?.reasons.join(' ')).toMatch(/process 4321 \(node\).* carries this session's id/)
  // The look is handed this session's id and a time limit of its own.
  const look = runs().find(isLook)
  expect(look?.includes('s1')).toBe(true)
  // A look that fails says nothing either way: the other readings decide.
  w.procs = { exitCode: 1, stdout: '', stderr: 'python3: not found' }
  await stopped($)
  await turnEnds($)
  await clock.advance(QUIET_MS)
  expect(w.pinned).toHaveLength(1)
  // A look that runs past its time limit, on the engine's clock, says nothing either way too, whether
  // the run then throws or answers as a killed process: the card waits for the limit, then the other
  // readings decide. Each under a new request of Dan's, since the card goes up once per request.
  for (const [i, how] of (['throws', 'exits'] as const).entries()) {
    w.procsTimeout = how
    await says($, `And one more thing ${i}`)
    await workedAndQuiet($, clock, { id: `b${i + 2}` })
    expect({ how, pinned: w.pinned.length }).toEqual({ how, pinned: 1 + i })
    await clock.advance(PROCESS_TIMEOUT_MS)
    expect({ how, pinned: w.pinned.length }).toEqual({ how, pinned: 2 + i })
    expect(reasonsOf(w)?.reasons).toEqual([])
  }
})

// #3770, reopened: six of the eleven reasons in Dan's test were the session's own connected servers,
// which carry its id for as long as it is open. The look now follows each carrier's parents by pid
// (tests/test-close-card-process-look.sh runs it on real processes) and answers `found` for one left
// behind, `unread` for one whose own parents could not be followed, and a count of those still
// attached to the session, which withhold nothing (`unplaced` and `own`, for a look that could not
// follow its own line, are further down). Dan, 2026-11-26, by picker: "2.1 Unreadable
// counts as nothing". One whose parents could not be followed is no reason either way: it never
// withholds the card and never pins it, and the reasons file keeps it as a note, seen and not counted.
const UNREAD_NOTE = "process 777 (node) carries this session's id, and whether it is still attached to this session could not be read (process 700, a parent of it, is not in the process list), so it was seen and not counted"
test("processes carrying this session's id that are still attached to it withhold nothing; nor does one whose parents could not be followed, which the reasons file notes as seen and not counted (#3770)", withAll, async ($, on) => {
  const { w, clock } = world(on, { procs: { exitCode: 0, stdout: JSON.stringify({ found: [], unread: [], attached: 6 }) } })
  await start($)
  await says($, 'Add the goal box')
  await workedAndQuiet($, clock)
  expect(reasonsOf(w)).toMatchObject({ pinned: true, reasons: [], notes: [] })
  expect(w.pinned).toHaveLength(1)
  w.procs = { exitCode: 0, stdout: JSON.stringify({ found: [], unread: [{ pid: 777, name: 'node', why: 'process 700, a parent of it, is not in the process list' }], attached: 6 }) }
  await says($, 'And one more thing')
  await workedAndQuiet($, clock, { id: 'b2' })
  expect(w.pinned).toHaveLength(2)
  expect(reasonsOf(w)).toMatchObject({ pinned: true, reasons: [], notes: [UNREAD_NOTE] })
})

test("an unread process beside one left behind changes nothing: the one left behind still withholds the card, and the unread one is only a note (#3770)", withAll, async ($, on) => {
  const procs = { found: [{ pid: 4321, name: 'node' }], unread: [{ pid: 777, name: 'node', why: 'process 700, a parent of it, is not in the process list' }], attached: 0 }
  const { w, clock } = world(on, { procs: { exitCode: 0, stdout: JSON.stringify(procs) } })
  await start($)
  await says($, 'Add the goal box')
  await workedAndQuiet($, clock)
  expect(w.pinned).toEqual([])
  expect(reasonsOf(w)?.pinned).toBe(false)
  expect(reasonsOf(w)?.reasons).toEqual(["process 4321 (node) carries this session's id and its parents no longer lead to this session, so something this session started was left running"])
  expect(reasonsOf(w)?.notes).toEqual([UNREAD_NOTE])
})

test('a look that answers garbled output withholds nothing, so the other readings decide and the card is pinned (#3770)', withAll, async ($, on) => {
  const { w, clock } = world(on, { procs: { exitCode: 0, stdout: 'garbled' } })
  await start($)
  await says($, 'Add the goal box')
  await workedAndQuiet($, clock)
  expect(w.pinned).toHaveLength(1)
  expect(reasonsOf(w)?.reasons).toEqual([])
})

// An independent review of the change above (2026-11-27) found the look calling a process unread
// for two different reasons, that process's parents could not be followed or the look's OWN could
// not be, and both had become a note. Dan's choice covers the first only. When the look cannot find
// its own place, a process whose parents were followed to the system's first process cannot be told
// apart from one still attached, so the look hands those back apart (`unplaced`, with `own` saying
// why its own line failed) and the card is withheld, as it was before that change.
const OWN_CUT = 'process 110, a parent of it, is not in the process list'
test("the check could not find its own place among the processes: a process whose own parents lead to the system's first process withholds the card, and the reason says why in plain words (#3770, the review's RED1)", withAll, async ($, on) => {
  // What the look answers for the review's planted world T2: 400 has the system's first process for
  // a parent, and one row of the look's own line above the session's process is missing.
  const { w, clock } = world(on, { procs: { exitCode: 0, stdout: JSON.stringify({ found: [], unread: [], unplaced: [{ pid: 400, name: 'node' }], own: OWN_CUT, attached: 1 }) } })
  await start($)
  await says($, 'Add the goal box')
  await workedAndQuiet($, clock)
  expect(w.pinned).toEqual([])
  expect(reasonsOf(w)?.pinned).toBe(false)
  expect(reasonsOf(w)?.reasons).toEqual([
    "the check for a process left behind could not find its own place among the processes (process 110, a parent of it, is not in the process list), so it could not tell whether these are still attached to this session or were left running, and each carries this session's id: process 400 (node)",
  ])
  expect(reasonsOf(w)?.notes).toEqual([])
})

test("the check could not find its own place at all, so every process carrying this session's id, the connected servers included, cannot be told apart: the card is withheld and one reason names them all (#3770, the review's T3)", withAll, async ($, on) => {
  const procs = { found: [], unread: [], unplaced: [{ pid: 300, name: 'node' }, { pid: 400, name: 'node' }], own: 'process 850, a parent of it, is not in the process list', attached: 0 }
  const { w, clock } = world(on, { procs: { exitCode: 0, stdout: JSON.stringify(procs) } })
  await start($)
  await says($, 'Add the goal box')
  await workedAndQuiet($, clock)
  expect(w.pinned).toEqual([])
  expect(reasonsOf(w)?.reasons).toEqual([
    "the check for a process left behind could not find its own place among the processes (process 850, a parent of it, is not in the process list), so it could not tell whether these are still attached to this session or were left running, and each carries this session's id: process 300 (node), process 400 (node)",
  ])
  // It is withheld again under the next request, for as long as the check cannot find its place.
  // An answer naming such processes with no reason given (the check never prints that) withholds too.
  w.procs = { exitCode: 0, stdout: JSON.stringify({ found: [], unread: [], unplaced: [{ pid: 400, name: 'node' }], attached: 0 }) }
  await says($, 'And one more thing')
  await workedAndQuiet($, clock, { id: 'b2' })
  expect(w.pinned).toEqual([])
  expect(reasonsOf(w)?.pinned).toBe(false)
  expect(reasonsOf(w)?.reasons.join(' ')).toMatch(/could not find its own place among the processes \(it gave no reason\).*: process 400 \(node\)$/)
})

test("the two reasons a process is not placed stay apart: one whose own parents could not be followed is a note and never a hold, even while the check's own place is unknown; one that only the check's own place could tell apart withholds (#3770)", withAll, async ($, on) => {
  const unread = [{ pid: 777, name: 'node', why: 'process 700, a parent of it, is not in the process list' }]
  const { w, clock } = world(on, { procs: { exitCode: 0, stdout: JSON.stringify({ found: [], unread, unplaced: [{ pid: 400, name: 'node' }], own: OWN_CUT, attached: 1 }) } })
  await start($)
  await says($, 'Add the goal box')
  await workedAndQuiet($, clock)
  expect(w.pinned).toEqual([])
  expect(reasonsOf(w)?.reasons).toHaveLength(1)
  expect(reasonsOf(w)?.reasons[0]).toMatch(/could not find its own place among the processes .*: process 400 \(node\)$/)
  expect(reasonsOf(w)?.reasons[0]).not.toMatch(/777/)
  expect(reasonsOf(w)?.notes).toEqual([UNREAD_NOTE])
  // With nothing that needed the check's own place, the same failing withholds nothing and is a note
  // beside the unread process's own: the card is pinned.
  w.procs = { exitCode: 0, stdout: JSON.stringify({ found: [], unread, unplaced: [], own: OWN_CUT, attached: 1 }) }
  await says($, 'And one more thing')
  await workedAndQuiet($, clock, { id: 'b2' })
  expect(w.pinned).toHaveLength(1)
  expect(reasonsOf(w)).toMatchObject({ pinned: true, reasons: [] })
  expect(reasonsOf(w)?.notes).toEqual([
    "the check for a process left behind could not find its own place among the processes (process 110, a parent of it, is not in the process list); it saw no process carrying this session's id that needed that place to be told apart, so this withheld nothing",
    UNREAD_NOTE,
  ])
})

test('the pin does not come back shown while an unread process was seen: the reasons file written then keeps the note beside why the card is not up (#3770, the review\'s RV5)', withAll, async ($, on) => {
  const { w, clock } = world(on, { pinAnswer: 'not shown: carried steps held', procs: { exitCode: 0, stdout: JSON.stringify({ found: [], unread: [{ pid: 777, name: 'node', why: 'process 700, a parent of it, is not in the process list' }], attached: 6 }) } })
  await start($)
  await says($, 'Add the goal box')
  await workedAndQuiet($, clock)
  expect(w.pinned).toEqual([])
  expect(reasonsOf(w)?.pinned).toBe(false)
  expect(reasonsOf(w)?.reasons.join(' ')).toMatch(/could not be shown/)
  expect(reasonsOf(w)?.notes).toEqual([UNREAD_NOTE])
  expect(reasonsOf(w)?.attached).toBe(6)
})

// A check that could not be finished still says nothing either way, so the other readings decide
// (the rule is older than this change and is Dan's to change). What changed is that it leaves a
// trace: a note in the reasons file and a line in the debug log, where before it left neither or one.
const UNFINISHED: { name: string; init: Partial<World>; note: RegExp; lookRuns: boolean }[] = [
  { name: 'the check ends with an exit code other than 0', init: { procs: { exitCode: 1, stdout: '', stderr: 'python3: not found' } }, note: /^the check for a process left behind ended with exit code 1, so it said nothing either way: the other readings decided, and a process left behind would not have been seen$/, lookRuns: true },
  { name: 'the check runs past its time limit and the run throws', init: { procsTimeout: 'throws' }, note: /^the check for a process left behind could not run \(.+\), so it said nothing either way: the other readings decided, and a process left behind would not have been seen$/, lookRuns: true },
  { name: 'the check runs past its time limit and is killed', init: { procsTimeout: 'exits' }, note: /^the check for a process left behind ended with exit code 143, so it said nothing either way: /, lookRuns: true },
  { name: 'the check prints something that is not JSON', init: { procs: { exitCode: 0, stdout: 'garbled' } }, note: /^the check for a process left behind printed something that is not its answer, so it said nothing either way: /, lookRuns: true },
  { name: 'ps ends with an exit code other than 0', init: { psFails: 'exits' }, note: /^the check for a process left behind was not run, because the list of this user's processes could not be taken \(ps ended with exit code 1\), so it said nothing either way: /, lookRuns: false },
  { name: 'ps throws', init: { psFails: 'throws' }, note: /^the check for a process left behind could not run \(.+\), so it said nothing either way: /, lookRuns: false },
]
for (const c of UNFINISHED) {
  test(`a check for a process left behind that could not be finished (${c.name}) decides nothing, as before, and now says so in the reasons file's notes and in the debug log (#3770)`, withAll, async ($, on) => {
    const { w, clock, logs, runs } = world(on, c.init)
    await start($)
    await says($, 'Add the goal box')
    await workedAndQuiet($, clock)
    await clock.advance(PROCESS_TIMEOUT_MS)
    // What the card decides is unchanged: the other readings are clean, so it is pinned.
    expect(w.pinned).toHaveLength(1)
    expect(reasonsOf(w)).toMatchObject({ pinned: true, reasons: [], attached: null })
    const notes = reasonsOf(w)?.notes ?? []
    expect(notes).toHaveLength(1)
    expect(notes[0]).toMatch(c.note)
    expect(logs).toContain(`goal-box: ${notes[0]}`)
    expect(runs().some(isLook)).toBe(c.lookRuns)
  })
}

test('a process list that was cut short is a check that could not be finished: what it did see still decides, and a note and a debug line say a process past the cut was not looked at (#3770)', withAll, async ($, on) => {
  const CUT = "the list of this user's processes was cut short before its end, so the check for a process left behind could not be finished: a process past the cut was not looked at"
  const { w, clock, logs } = world(on, { psCut: true, procs: { exitCode: 0, stdout: JSON.stringify({ found: [{ pid: 4321, name: 'node' }], unread: [], unplaced: [], own: null, attached: 2 }) } })
  await start($)
  await says($, 'Add the goal box')
  await workedAndQuiet($, clock)
  // The one it found left behind withholds the card as ever.
  expect(w.pinned).toEqual([])
  expect(reasonsOf(w)?.reasons).toEqual(["process 4321 (node) carries this session's id and its parents no longer lead to this session, so something this session started was left running"])
  expect(reasonsOf(w)?.notes).toEqual([CUT])
  expect(logs).toContain(`goal-box: ${CUT}`)
  // With nothing found in the part it saw, the card is pinned, as before, and the note is kept.
  w.procs = { exitCode: 0, stdout: JSON.stringify({ found: [], unread: [], unplaced: [], own: null, attached: 2 }) }
  await says($, 'And one more thing')
  await workedAndQuiet($, clock, { id: 'b2' })
  expect(w.pinned).toHaveLength(1)
  expect(reasonsOf(w)).toMatchObject({ pinned: true, reasons: [], notes: [CUT], attached: 2 })
})

test("the reasons file records how many processes the check counted as still attached, so a check that saw none at all can be told from a clean one; nothing is decided from the count (#3770, the review's RV8)", withAll, async ($, on) => {
  // Attached 0 with nothing found: in a session with connected servers this is a check that saw no
  // environment at all. The card is pinned as before; the file now says 0.
  const { w, clock } = world(on, { procs: { exitCode: 0, stdout: JSON.stringify({ found: [], unread: [], unplaced: [], own: null, attached: 0 }) } })
  await start($)
  await says($, 'Add the goal box')
  await workedAndQuiet($, clock)
  expect(w.pinned).toHaveLength(1)
  expect(reasonsOf(w)).toMatchObject({ pinned: true, reasons: [], notes: [], attached: 0 })
  // A count is written when the card is withheld too.
  w.procs = { exitCode: 0, stdout: JSON.stringify({ found: [{ pid: 4321, name: 'node' }], unread: [], unplaced: [], own: null, attached: 6 }) }
  await says($, 'And one more thing')
  await workedAndQuiet($, clock, { id: 'b2' })
  expect(w.pinned).toHaveLength(1)
  expect(reasonsOf(w)).toMatchObject({ pinned: false, attached: 6 })
  // An answer that gives no count, or one that is not a number, is written as null, never as 0.
  for (const [i, attached] of [undefined, 'many', -1, 2.5].entries()) {
    w.procs = { exitCode: 0, stdout: JSON.stringify({ found: [], unread: [], attached }) }
    await says($, `And another ${i}`)
    await workedAndQuiet($, clock, { id: `c${i}` })
    expect({ attached, written: reasonsOf(w)?.attached }).toEqual({ attached, written: null })
  }
})

test('a command that put something in the background withholds the card for the rest of the session, across later requests and boxes (#3770)', withAll, async ($, on) => {
  const { w, clock } = world(on, { ...REVIEWED, reader: c => (c.includes('&') ? [{ words: ['sleep', '600'], background: true }] : [{ words: ['ls'] }]) })
  await start($)
  await says($, 'Add the goal box')
  await bash($, 'ls')
  await bash($, 'sleep 600 &')
  await workedAndQuiet($, clock)
  expect(w.pinned).toEqual([])
  const why = reasonsOf(w)?.reasons.join(' ') ?? ''
  expect(why).toMatch(/put a process in the background/)
  // Never the command's own text.
  expect(why).not.toMatch(/sleep 600/)
  await says($, 'Now make the status bar quieter')
  await workedAndQuiet($, clock, { id: 'b2' })
  expect(w.pinned).toEqual([])
  expect(reasonsOf(w)?.reasons.join(' ')).toMatch(/put a process in the background/)
})

// Through mod-kit's own reader (a byte copy in tests/mod-kit, held to its source by the shared parts
// check), so each row is a real command text read as the session's would be, never a reading made up.
const realReader = (c: string) => pipeline(c) as unknown[]

test('a Bash call run in the background, which the job watcher tracks, does not trip it; nor does a subagent\'s (#3770)', withAll, async ($, on) => {
  const { w, clock } = world(on, { ...REVIEWED, reader: realReader })
  await start($)
  await says($, 'Add the goal box')
  await bash($, 'sleep 600 &', { run_in_background: true })
  await bash($, 'nohup sleep 600 &', { agentId: 'agent-1' })
  await workedAndQuiet($, clock)
  expect(w.pinned).toHaveLength(1)
})

// Each detacher in a session of its own, since one trip keeps the card down for the rest of a session.
const DETACH_ROWS: [string, RegExp | undefined][] = [
  ['nohup sleep 600 > /dev/null 2>&1', /ran a command under nohup/],
  ['setsid sleep 600', /ran a command under setsid/],
  ['setsid -f sleep 600', /ran a command under setsid/],
  ['disown -a', /ran disown/],
  ['sleep 600 & disown', /put a process in the background with &/],
  // A redirect's & and a && mark nothing.
  ['ls > out.txt 2>&1 && pwd', undefined],
]
for (const [command, why] of DETACH_ROWS) {
  test(`${why ? 'trips it' : 'does not trip it'}: ${command} (#3770)`, withAll, async ($, on) => {
    const { w, clock } = world(on, { ...REVIEWED, reader: realReader })
    await start($)
    await says($, 'Add the goal box')
    await bash($, command)
    await workedAndQuiet($, clock)
    if (!why) return expect({ command, pinned: w.pinned.length, reasons: reasonsOf(w)?.reasons }).toEqual({ command, pinned: 1, reasons: [] })
    expect({ command, pinned: w.pinned.length }).toEqual({ command, pinned: 0 })
    expect(reasonsOf(w)?.reasons.join(' ')).toMatch(why)
  })
}

test('a command the reader is unsure of, or cannot read at all, counts as one that may have left something behind (#3770)', withAll, async ($, on) => {
  const { w, clock } = world(on, { ...REVIEWED, reader: c => (c === 'eval x' ? [{ words: ['eval', 'x'], unread: 'eval runs text the shell builds' }] : { fails: 'the reader threw' }) })
  await start($)
  await says($, 'Add the goal box')
  await bash($, 'eval x')
  await workedAndQuiet($, clock)
  expect(w.pinned).toEqual([])
  expect(reasonsOf(w)?.reasons.join(' ')).toMatch(/could not be read in full \(eval runs text the shell builds\)/)
})

test('a command the reader throws on trips it too (#3770)', withAll, async ($, on) => {
  const { w, clock } = world(on, { ...REVIEWED, reader: () => ({ fails: 'the reader threw' }) })
  await start($)
  await says($, 'Add the goal box')
  await bash($, 'anything')
  await workedAndQuiet($, clock)
  expect(w.pinned).toEqual([])
  expect(reasonsOf(w)?.reasons.join(' ')).toMatch(/could not be read in full/)
})

// ---- #3843: work Dan picks in a picker ----
// Dan's answer on the issue (2026-11-27): an answer he gives in a picker is a new request only when
// the session then does work. Before it, a box was owed for work he picked and none could be shown
// until he typed again. The events here stand in for a session: the picker's answer is what Claude
// Code's dialog hands a tool.call hook, and the end of turn review's own test of a tool's name
// answers from WORK_TEST_SAYS above.
const QUESTION = 'Which follow up should be done now?'
const PICKER = { questions: [{ question: QUESTION, header: 'Next', options: [{ label: 'Fix the count', description: '' }, { label: 'Leave it', description: '' }], multiSelect: false }] }
const PICKED = { result: { questions: PICKER.questions, answers: { [QUESTION]: 'Fix the count' } }, text: '' }
// The session asks Dan a picker, which comes back as `answer` says (PICKED: he chose).
const picks = (w: World, $: Engine$, id: string, answer: unknown = PICKED, more: Record<string, unknown> = {}) => {
  w.toolAnswers = { ...w.toolAnswers, [id]: answer }
  return $.tool.call({ tool: 'AskUserQuestion', tool_use_id: id, ...PICKER, ...more } as never)
}
// The session calls a tool; `answer` is what the call comes back with where it is not a plain result.
const does = (w: World, $: Engine$, tool: string, id: string, more: Record<string, unknown> = {}, answer?: unknown) => {
  if (answer !== undefined) w.toolAnswers = { ...w.toolAnswers, [id]: answer }
  return $.tool.call({ tool, tool_use_id: id, ...more } as never)
}
const MORE = { goal: 'Fix the count', shipped: ['#3850 closed: the count'] }
// These tests work and then show the box in one turn, so each says its turn's end of turn review is
// on record as answered (REVIEWED): the picker Dan answers in them is asked after it. What the box
// does while that review is still to come, or not yet answered, is the next section's.
const reviewed = (on: On, init: Partial<World> = {}) => world(on, { ...REVIEWED, ...init })
// One request of Dan's, typed, and its box shown.
const askedAndShown = async ($: Engine$, text: string, id: string) => {
  await says($, text)
  expect((await box($, ASKED, id)).deny).toBeUndefined()
}

test('work Dan picked in a picker, finished: the box is shown again with no new message from him (#3843)', withKit, async ($, on) => {
  const { w, cards } = reviewed(on)
  await start($)
  await askedAndShown($, 'Run the monthly sync', 'b1')
  await picks(w, $, 'q1')
  await does(w, $, 'Edit', 'e1', { file_path: '/repo/a.ts' })
  expect((await box($, MORE, 'b2')).deny).toBeUndefined()
  expect((await cards()).map(c => c.toolUseId)).toEqual(['b1', 'b2'])
  // Once for that work too: a third call with nothing new picked is refused.
  expect((await box($, MORE, 'b3')).deny).toMatch(/already shown for this request/)
})

test('a picker answer with nothing done after it earns no box, and the refusal says so (#3843)', withKit, async ($, on) => {
  const { w, cards } = reviewed(on)
  await start($)
  await askedAndShown($, 'Run the monthly sync', 'b1')
  await picks(w, $, 'q1')
  const none = await box($, MORE, 'b2')
  expect(none.deny).toMatch(/Dan has answered a picker since, and nothing has been changed since his answer/)
  expect(none.deny).toMatch(/an answer alone is not a new request/)
  // Reading is not work, by the end of turn review's own test.
  await does(w, $, 'Read', 'r1', { file_path: '/repo/a.ts' })
  await does(w, $, 'Grep', 'g1', { pattern: 'count' })
  expect((await box($, MORE, 'b3')).deny).toMatch(/nothing has been changed since his answer/)
  await does(w, $, 'Bash', 'x9', { command: 'gh issue close 3850' })
  expect((await box($, MORE, 'b4')).deny).toBeUndefined()
  expect((await cards()).map(c => c.toolUseId)).toEqual(['b1', 'b4'])
})

// Every way a picker comes back that is not Dan answering it. The third part is what the debug log
// says of the result's shape: nothing for the three causes this mod knows (dismissed, failed, closed
// while he was away), and for every other the keys the result held, so a result whose shape this
// mod does not read shows at the first real picker and never passes as a quiet day.
const NO_ANSWER: [string, unknown, RegExp | null][] = [
  ['dismissed', { deny: 'The user does not want to answer right now' }, null],
  ['failed', { isError: true, text: 'The dialog could not be shown', result: 'The dialog could not be shown' }, null],
  ['closed by itself while he was away', { result: { questions: PICKER.questions, answers: { [QUESTION]: 'Fix the count' }, afkTimeoutMs: 60_000 }, text: '' }, null],
  ['answered with nothing', { result: { questions: PICKER.questions, answers: {} }, text: '' }, /\(its result holds: questions, answers\)/],
  ['answered with an empty answer', { result: { questions: PICKER.questions, answers: { [QUESTION]: '  ' } }, text: '' }, /\(its result holds: questions, answers\)/],
  // A reply typed in place of a choice comes back as `response` (TYPED below): only his own words count.
  ['answered with a typed reply that is empty', { result: { questions: PICKER.questions, answers: {}, response: '  ' }, text: '' }, /\(its result holds: questions, answers, response\)/],
  ['answered with a typed reply that is not text', { result: { questions: PICKER.questions, answers: {}, response: 7 }, text: '' }, /\(its result holds: questions, answers, response\)/],
  ['closed by itself while he was away, holding a typed reply', { result: { questions: PICKER.questions, answers: {}, response: 'Fix the count', afkTimeoutMs: 60_000 }, text: '' }, null],
  ['a result that is not a dialog\'s', { result: 'ok', text: 'ok' }, /\(its result is a string, where this mod reads an object; the call came back holding: result, text\)/],
  // The shapes this mod has never seen, which is what a change in Claude Code would look like.
  ['answered under a name this mod does not read', { result: { questions: PICKER.questions, selections: { [QUESTION]: 'Fix the count' } }, text: '' }, /\(its result holds: questions, selections\)/],
  ['answered in a result keyed by the question itself', { result: { [QUESTION]: 'Fix the count', questions: PICKER.questions }, text: '' }, /\(its result holds: questions, and 1 more not named here\)/],
]
for (const [how, answer] of NO_ANSWER)
  test(`a picker ${how} is no answer: work after it opens no new box (#3843)`, withKit, async ($, on) => {
    const { w, cards } = reviewed(on)
    await start($)
    await askedAndShown($, 'Run the monthly sync', 'b1')
    await picks(w, $, 'q1', answer)
    await does(w, $, 'Edit', 'e1', { file_path: '/repo/a.ts' })
    const again = await box($, MORE, 'b2')
    expect(again.deny).toMatch(/already shown for this request/)
    // The refusal says what would count, so a session knows when a later call is right.
    expect(again.deny).toMatch(/a message he types, or work you do after an answer he gives in a picker/)
    // The control: the same steps with his answer show the box.
    await picks(w, $, 'q2')
    await does(w, $, 'Edit', 'e2', { file_path: '/repo/a.ts' })
    expect((await box($, MORE, 'b3')).deny).toBeUndefined()
    expect((await cards()).map(c => c.toolUseId)).toEqual(['b1', 'b3'])
  })

// What the debug log says of each of those rows, in tests of their own that show no box: the line is
// written when the picker comes back, whatever follows. SHAPE_LINE is the one line the log holds
// about a picker's result in no shape this mod reads.
const SHAPE_LINE = /a picker came back with no answer of Dan's in a shape this mod reads/
for (const [how, answer, shape] of NO_ANSWER)
  test(`a picker ${how}: the debug log ${shape ? 'names the keys its result held, and nothing he was asked or answered' : 'says nothing of its shape'} (#3843)`, withKit, async ($, on) => {
    const { w, logs } = world(on)
    await start($)
    await says($, 'Run the monthly sync')
    await picks(w, $, 'q1', answer)
    const said = logs.filter(l => SHAPE_LINE.test(l))
    expect(said.length).toBe(shape ? 1 : 0)
    if (shape) {
      expect(said[0]).toMatch(shape)
      expect(said[0]).toMatch(/so it is not counted as an answer of his and no picked work begins from it/)
      // Keys only: never a word of what was asked or of what came back.
      expect(said[0]).not.toContain(QUESTION)
      expect(said[0]).not.toContain('Fix the count')
      expect(said[0]).not.toContain('Leave it')
    }
    // The control: a picker he answered says nothing of a shape.
    await picks(w, $, 'q2')
    expect(logs.filter(l => SHAPE_LINE.test(l)).length).toBe(shape ? 1 : 0)
  })

// The reading behind those rows, asked directly for what the events above cannot hand a hook (a call
// that came back as no object at all, or with no result: the engine here takes neither from a test's
// own answer) and for the two limits on what is named: at most twelve names,
// and never one that is not a plain field name, since a result keyed by a question would otherwise
// put his question in the log.
test("a picker's result is read once for the count and the debug log: each way back has one name, and only field names are ever said (#3843)", async () => {
  const came = (r: unknown, call: unknown = PICKER) => request.pickerCame(r, call)
  expect(came(PICKED)).toEqual({ how: 'answer' })
  expect(came({ deny: 'The user does not want to answer right now' })).toEqual({ how: 'known' })
  expect(came({ isError: true, result: 'The dialog could not be shown' })).toEqual({ how: 'known' })
  expect(came({ result: { answers: { [QUESTION]: 'Fix the count' }, afkTimeoutMs: 60_000 } })).toEqual({ how: 'known' })
  expect(came(null)).toEqual({ how: 'shape', holds: 'the call came back as null' })
  expect(came(undefined)).toEqual({ how: 'shape', holds: 'the call came back as nothing' })
  expect(came('Fix the count')).toEqual({ how: 'shape', holds: 'the call came back as a string' })
  expect(came([PICKED])).toEqual({ how: 'shape', holds: 'the call came back as a list' })
  expect(came({ text: '' })).toEqual({ how: 'shape', holds: 'it has no result; the call came back holding: text' })
  expect(came({ result: null })).toEqual({ how: 'shape', holds: 'its result is null, where this mod reads an object; the call came back holding: result' })
  expect(came({ result: [{ question: QUESTION, answer: 'Fix the count' }], text: '' })).toEqual({ how: 'shape', holds: 'its result is a list, where this mod reads an object; the call came back holding: result, text' })
  expect(came({ result: {} })).toEqual({ how: 'shape', holds: 'its result holds: no keys' })
  const many = Object.fromEntries(Array.from({ length: 15 }, (_, i) => [`field${i}`, 'Fix the count']))
  expect(came({ result: many })).toEqual({ how: 'shape', holds: `its result holds: ${Array.from({ length: 12 }, (_, i) => `field${i}`).join(', ')}, and 3 more not named here` })
  expect(came({ result: { [QUESTION]: 'Fix the count', 'Leave it': true } })).toEqual({ how: 'shape', holds: 'its result holds: 2 keys not named here' })
  // A picker he could not read whole is that, whatever came back: the call is judged first.
  expect(came(PICKED, { ...PICKER, note: TOO_LONG }).how).toBe('unread')
  expect(came(null, { ...PICKER, note: TOO_LONG }).how).toBe('unread')
  // The count reads the same reading: only the first of the four is an answer.
  expect(request.answered(PICKED, PICKER)).toBe(true)
  expect(request.answered({ result: many }, PICKER)).toBe(false)
})

// What counts as work after his answer: a call of the main conversation that ran, whose tool the end
// of turn review's own test (payload/hooks/turn-worked.py) counts as able to change something.
const WORK_ROWS: [string, string, Record<string, unknown>, unknown, boolean][] = [
  ['an edit', 'Edit', { file_path: '/repo/a.ts' }, undefined, true],
  ['a write', 'Write', { file_path: '/repo/b.ts' }, undefined, true],
  ['a command', 'Bash', { command: 'gh pr merge 12' }, undefined, true],
  ['an agent', 'Agent', { prompt: 'Fix the count' }, undefined, true],
  ['a connected tool that acts', 'mcp__is-it-live__card', {}, undefined, true],
  ['a read', 'Read', { file_path: '/repo/a.ts' }, undefined, false],
  ['a search', 'Grep', { pattern: 'count' }, undefined, false],
  // Claude Code marks the result of a call whose tool held its input read only (`isReadOnly: true`,
  // "Bash `ls`: set"; for a connected tool, its server's declaration). Such a call changed nothing,
  // whatever the review's test says of its tool's name.
  ['a command whose result Claude Code marked read only', 'Bash', { command: 'git status' }, { result: '', text: '', isReadOnly: true }, false],
  ['a connected tool its server declares read only', 'mcp__is-it-live__card', {}, { result: '', text: '', isReadOnly: true }, false],
  // Never read only by default: a result without the mark, or with anything but true there, is
  // judged by the review's own test of the tool's name, as every call was before the mark was read.
  ['a command that only reads, whose result carries no read only mark: the review\'s test still decides, and', 'Bash', { command: 'git status' }, { result: '', text: '' }, true],
  ['a command whose result says false where the read only mark goes: the review\'s test still decides, and', 'Bash', { command: 'git status' }, { result: '', text: '', isReadOnly: false }, true],
  ['an edit a guard refused, which changed nothing', 'Edit', { file_path: '/repo/a.ts' }, { deny: 'held by a guard' }, false],
  // A settings hook's refusal reaches a mod as an errored result, as a command that failed does.
  ['an edit that came back as an error, as one a hook refused does', 'Edit', { file_path: '/repo/a.ts' }, { isError: true, result: 'refused by a hook', text: 'refused by a hook' }, false],
  ["a subagent's edit, which is not the main conversation's", 'Edit', { file_path: '/repo/a.ts', agentId: 'a1' }, undefined, false],
  ['a second picker he answers', 'AskUserQuestion', PICKER, PICKED, false],
]
for (const [what, tool, input, answer, counts] of WORK_ROWS)
  test(`after a picker answer, ${what} ${counts ? 'is work: the box is shown' : 'is not work: no box'} (#3843)`, withKit, async ($, on) => {
    const { w } = reviewed(on)
    await start($)
    await askedAndShown($, 'Run the monthly sync', 'b1')
    await picks(w, $, 'q1')
    await does(w, $, tool, 'w1', input, answer)
    const r = await box($, MORE, 'b2')
    if (counts) expect(r.deny).toBeUndefined()
    else expect(r.deny).toMatch(/nothing has been changed since his answer/)
  })

test("the box's own tool is never work: a refused call after a picker answer does not earn the next one (#3843)", withKit, async ($, on) => {
  const { w, cards } = world(on)
  await start($)
  await askedAndShown($, 'Run the monthly sync', 'b1')
  await picks(w, $, 'q1')
  expect((await box($, MORE, 'b2')).deny).toMatch(/nothing has been changed since his answer/)
  expect((await box($, MORE, 'b3')).deny).toMatch(/nothing has been changed since his answer/)
  expect((await cards()).map(c => c.toolUseId)).toEqual(['b1'])
})

test('two calls at once after one answer are one new request, not two (#3843)', withKit, async ($, on) => {
  const { w } = reviewed(on)
  await start($)
  await askedAndShown($, 'Run the monthly sync', 'b1')
  await picks(w, $, 'q1')
  await Promise.all([does(w, $, 'Edit', 'e1', { file_path: '/repo/a.ts' }), does(w, $, 'Edit', 'e2', { file_path: '/repo/b.ts' })])
  expect((await box($, MORE, 'b2')).deny).toBeUndefined()
  expect((await box($, MORE, 'b3')).deny).toMatch(/already shown for this request/)
})

// The review of pull request 3852: the test above passes with his answer counted twice, since every
// reader of the count asks only whether it is at least some value. So the count itself is read here.
// It is read as a hook reads it (a test's own engine holds no state): asked for through a tool no
// case here uses (ToolSearch), and answered as a refusal, which is never work. A stand in mod's
// hooks are loaded by themselves, so the tool's name is written out in it.
const counter: { name: string; register: Register } = {
  name: 'request-counter',
  register: on => {
    on('tool.call', { tool: 'ToolSearch' }, async $ => ({ deny: String((await $.state.get({ plugin: 'goal-box', key: 'prompts' })).value ?? 0) }))
  },
}
const requests = async ($: Engine$) => Number(((await $.tool.call({ tool: 'ToolSearch', tool_use_id: 'count' } as never)) as Out).deny)
// Where a case below asks whether work after an answer counted, it reads the count and shows no box
// after the work, so it says the same thing whatever else may hold a box in a turn that did work.
const withCount = { plugins: [kit, registry, counter] }

test('two calls at once after one answer count his answer once: the count of his requests goes up by one (#3843)', withCount, async ($, on) => {
  const { w } = world(on)
  await start($)
  await askedAndShown($, 'Run the monthly sync', 'b1')
  expect(await requests($)).toBe(1)
  await picks(w, $, 'q1')
  await Promise.all([does(w, $, 'Edit', 'e1', { file_path: '/repo/a.ts' }), does(w, $, 'Edit', 'e2', { file_path: '/repo/b.ts' })])
  expect(await requests($)).toBe(2)
  // A later call, with no answer waiting, counts nothing more.
  await does(w, $, 'Write', 'w1', { file_path: '/repo/c.ts' })
  expect(await requests($)).toBe(2)
})

// The box's own call never reaches the count of work. Its own hook is registered above the hook that
// watches every call, so it stands outside it ("a plugin's registrations nest in order, first
// outermost"), answers its tool and passes nothing down. So a box that is shown while an answer
// waits is no more work after that answer than one that is refused. The watching hook also leaves
// the tool out by name, which is reached only if that order changes: this case passes with either
// guard in place and fails with both gone (seen with the box's hook made to pass its call down and
// the name taken out).
test("the box's own tool is not work when it is shown either: a box shown while an answer waits does not earn another (#3843)", withKit, async ($, on) => {
  const { w, cards } = world(on)
  await start($)
  await says($, 'Run the monthly sync')
  await picks(w, $, 'q1')
  // The box for his message, shown while his answer waits with nothing done after it.
  expect((await box($, ASKED, 'b1')).deny).toBeUndefined()
  expect((await box($, MORE, 'b2')).deny).toMatch(/nothing has been changed since his answer/)
  expect((await cards()).map(c => c.toolUseId)).toEqual(['b1'])
})

// A reply Dan types into a picker instead of choosing comes back as `response`, beside `answers`
// with nothing in it (Claude Code's typings of the tool's result: "Freeform text the user typed
// instead of selecting a structured option"). Those are his own words, so it is an answer of his.
const TYPED = { result: { questions: PICKER.questions, answers: {}, response: 'Fix the count, and the total too' }, text: '' }
test('a reply Dan types into a picker instead of choosing is his answer: work after it counts as a request of his (#3843)', withCount, async ($, on) => {
  const { w } = world(on)
  await start($)
  await askedAndShown($, 'Run the monthly sync', 'b1')
  await picks(w, $, 'q1', TYPED)
  expect((await box($, MORE, 'b2')).deny).toMatch(/Dan has answered a picker since, and nothing has been changed since his answer/)
  expect(await requests($)).toBe(1)
  await does(w, $, 'Edit', 'e1', { file_path: '/repo/a.ts' })
  expect(await requests($)).toBe(2)
})

// Dan's rule holds to the turn he answered in. An answer nothing followed stops waiting when that
// turn ends, so a turn he did not start (a prompt a mod sends, a wake up, a job's notice) cannot do
// work that counts as picked by an answer he gave before it.
test('an answer nothing followed stops waiting when its turn ends: work in a later turn Dan did not start opens no new box (#3843)', withCount, async ($, on) => {
  const { w, cards } = world(on)
  await start($)
  await askedAndShown($, 'Run the monthly sync', 'b1')
  await picks(w, $, 'q1')
  await turnEnds($)
  await turnStarts($, 't2')
  await does(w, $, 'Edit', 'e1', { file_path: '/repo/a.ts' })
  const later = await box($, MORE, 'b2')
  expect(later.deny).toMatch(/already shown for this request; it shows again once Dan has asked for something new/)
  expect(later.deny).not.toMatch(/since his answer/)
  expect(await requests($)).toBe(1)
  // The control: an answer and the work after it in one turn still count as a request of his. Until
  // the work, the refusal says how long his answer waits.
  await picks(w, $, 'q2')
  expect((await box($, MORE, 'b3')).deny).toMatch(/do it in this turn, then call this tool again: his answer waits only until the turn it was given in ends\.$/)
  await does(w, $, 'Edit', 'e2', { file_path: '/repo/a.ts' })
  expect(await requests($)).toBe(2)
  expect((await cards()).map(c => c.toolUseId)).toEqual(['b1'])
})

test("a turn Dan interrupted ends his waiting answer as well, and a subagent's turn end does not (#3843)", withCount, async ($, on) => {
  const { w } = world(on)
  await start($)
  await askedAndShown($, 'Run the monthly sync', 'b1')
  await picks(w, $, 'q1')
  // A subagent's turn ending is not the conversation's: his answer still waits, and work counts.
  await turnEnds($, { agentId: 'a1' })
  await does(w, $, 'Edit', 'e1', { file_path: '/repo/a.ts' })
  expect(await requests($)).toBe(2)
  // A turn he interrupted is the conversation's: the answer he gave in it stops waiting.
  await picks(w, $, 'q2')
  await turnEnds($, { reason: 'aborted', isAborted: true })
  await turnStarts($, 't2')
  await does(w, $, 'Edit', 'e2', { file_path: '/repo/a.ts' })
  expect(await requests($)).toBe(2)
})

test("an answer whose following work could not be read stops waiting when its turn ends too, and the debug log says so (#3843)", withKit, async ($, on) => {
  const { w, logs } = world(on, { workTest: { exitCode: 1, stdout: '', stderr: "python3: can't open file" } })
  await start($)
  await askedAndShown($, 'Run the monthly sync', 'b1')
  await picks(w, $, 'q1')
  await does(w, $, 'Edit', 'e1', { file_path: '/repo/a.ts' })
  expect((await box($, MORE, 'b2')).deny).toMatch(/could not be read \(.*can't open file.*\)/)
  await turnEnds($)
  await turnStarts($, 't2')
  delete w.workTest
  await does(w, $, 'Edit', 'e2', { file_path: '/repo/a.ts' })
  const later = await box($, MORE, 'b3')
  expect(later.deny).toMatch(/already shown for this request; it shows again once Dan has asked for something new/)
  expect(later.deny).not.toMatch(/since his answer/)
  expect(logs.join('\n')).toMatch(/the turn Dan answered a picker in has ended, and whether anything was changed after his answer could not be read \(.*can't open file.*\)/)
})

// How many times the end of turn review's test was run for one tool's name.
const asksOf = (runs: () => string[][], tool: string) => runs().filter(a => a[a.length - 2] === WORK_TEST_FILE && a[a.length - 1] === tool).length

// The review of pull request 3852: each run holds a call's result back for up to WORK_TEST_MS, and a
// run that could not be read was made again on every later call while his answer waited.
test("a test that cannot be read is run once for each tool's name in a turn, not on every call, and the refusal says so (#3843)", withKit, async ($, on) => {
  const broken = { exitCode: 1, stdout: '', stderr: "python3: can't open file" }
  const { w, runs } = world(on, { workTest: broken })
  await start($)
  await askedAndShown($, 'Run the monthly sync', 'b1')
  await picks(w, $, 'q1')
  await does(w, $, 'Edit', 'e1', { file_path: '/repo/a.ts' })
  await does(w, $, 'Edit', 'e2', { file_path: '/repo/a.ts' })
  await does(w, $, 'Edit', 'e3', { file_path: '/repo/a.ts' })
  expect(asksOf(runs, 'Edit')).toBe(1)
  // Another tool's name is asked about, once.
  await does(w, $, 'Write', 'w1', { file_path: '/repo/b.ts' })
  await does(w, $, 'Write', 'w2', { file_path: '/repo/b.ts' })
  expect(asksOf(runs, 'Write')).toBe(1)
  const r = await box($, MORE, 'b2')
  expect(r.deny).toMatch(/could not be read \(.*can't open file.*\)/)
  expect(r.deny).toMatch(/That is not asked again for the same tool in this turn, so call again after a call of a different tool that changes something/)
  // The test can be run again now. A tool already asked about this turn is still not asked again:
  // its calls stay unread, never counted and never taken as no work.
  delete w.workTest
  await does(w, $, 'Edit', 'e4', { file_path: '/repo/a.ts' })
  expect(asksOf(runs, 'Edit')).toBe(1)
  expect((await box($, MORE, 'b3')).deny).toMatch(/could not be read/)
  // A tool not yet asked about this turn is, and its call counts.
  await does(w, $, 'Bash', 'x1', { command: 'gh issue close 3850' })
  expect((await box($, MORE, 'b4')).deny).toBeUndefined()
  // The limit is one turn's: in the next turn the same tool's name is asked about afresh.
  w.workTest = broken
  await turnEnds($)
  await turnStarts($, 't2')
  await picks(w, $, 'q2')
  await does(w, $, 'Edit', 'e5', { file_path: '/repo/a.ts' })
  expect(asksOf(runs, 'Edit')).toBe(2)
})

// #3321: Dan's answer covers only text he could read. Claude Code's dialog cuts a long question and
// draws some text as nothing, so a picker whose call fails mod-kit's one check of text a person
// approves in a picker (askFault, hooks/mod-kit/shown.ts) is no answer here, whatever came back:
// no picked work begins from it. tools/check-mod-shared-parts.sh holds every mod that reads a
// picker's answers to that check.
const TOO_LONG = `Which follow up should be done now? ${'Fix the count, and the total beside it. '.repeat(40)}`
const UNREAD_PICKERS: [string, Record<string, unknown>, RegExp][] = [
  ['whose question is longer than the dialog shows whole', { questions: [{ ...PICKER.questions[0], question: TOO_LONG }] }, /The question would not reach Dan as written: it is \d+ UTF-16 code units/],
  ['with an answer whose description is longer than the dialog shows whole', { questions: [{ ...PICKER.questions[0], options: [{ label: 'Fix the count', description: TOO_LONG }, { label: 'Leave it', description: '' }] }] }, /Field "options" of the question would not reach Dan as written/],
  ['sent with a field beside its questions that is longer than the dialog shows whole', { note: TOO_LONG }, /Field "note" would not reach Dan as written/],
]
for (const [how, more, said] of UNREAD_PICKERS)
  test(`a picker ${how} is no answer, whatever came back: work after it is not picked work, and the debug log says why (#3843, #3321)`, withCount, async ($, on) => {
    const { w, logs } = world(on)
    await start($)
    await askedAndShown($, 'Run the monthly sync', 'b1')
    await picks(w, $, 'q1', PICKED, more)
    await does(w, $, 'Edit', 'e1', { file_path: '/repo/a.ts' })
    expect(await requests($)).toBe(1)
    const again = await box($, MORE, 'b2')
    expect(again.deny).toMatch(/already shown for this request; it shows again once Dan has asked for something new/)
    expect(again.deny).not.toMatch(/since his answer/)
    expect(logs.join('\n')).toMatch(said)
    expect(logs.join('\n')).toMatch(/so the answer that came back is not counted as an answer of his/)
    // The control: the same picker as he could read it whole is an answer, and work after it counts.
    await picks(w, $, 'q2')
    await does(w, $, 'Edit', 'e2', { file_path: '/repo/a.ts' })
    expect(await requests($)).toBe(2)
  })

test('a message Dan types after a picker answer is the request: the answer left waiting opens nothing more (#3843)', withKit, async ($, on) => {
  const { w } = world(on)
  await start($)
  await askedAndShown($, 'Run the monthly sync', 'b1')
  await picks(w, $, 'q1')
  await askedAndShown($, 'Now make the status bar quieter', 'b2')
  await does(w, $, 'Edit', 'e1', { file_path: '/repo/a.ts' })
  const r = await box($, MORE, 'b3')
  expect(r.deny).toMatch(/already shown for this request/)
  expect(r.deny).not.toMatch(/since his answer/)
})

test("the review's test of a tool that cannot be run: the refusal says whether work followed his answer is not known, and it counts once it can be (#3843)", withKit, async ($, on) => {
  const { w, logs } = reviewed(on, { workTest: { exitCode: 1, stdout: '', stderr: "python3: can't open file" } })
  await start($)
  await askedAndShown($, 'Run the monthly sync', 'b1')
  await picks(w, $, 'q1')
  await does(w, $, 'Edit', 'e1', { file_path: '/repo/a.ts' })
  const r = await box($, MORE, 'b2')
  expect(r.deny).toMatch(/whether anything has been changed since his answer could not be read \(.*can't open file.*\)/)
  expect(r.deny).not.toMatch(/nothing has been changed/)
  // An answer that is neither yes nor no is unread too, never taken for no. Each of these calls is
  // of a tool not yet asked about this turn: one that was is not asked about again in it (above).
  w.workTest = { exitCode: 0, stdout: 'maybe\n' }
  await does(w, $, 'Write', 'e2', { file_path: '/repo/a.ts' })
  expect((await box($, MORE, 'b3')).deny).toMatch(/could not be read \(.*maybe.*\)/)
  delete w.workTest
  await does(w, $, 'Bash', 'e3', { command: 'gh issue close 3850' })
  expect((await box($, MORE, 'b4')).deny).toBeUndefined()
  expect(logs.join('\n')).toMatch(/whether Edit can change something could not be read/)
})

test('picked work finished and shipped, and no box for it: the session is asked whether the work is finished, once something shipped since the last box (#3843, #2523)', withLive, async ($, on) => {
  const { w, clock, submitted } = world(on, { verdicts: CARDED })
  const asked = () => submitted.filter(s => s.text.startsWith(ASKS_DONE))
  await start($)
  await askedAndShown($, 'Merge PR 1700', 'b1')
  await turnEnds($)
  expect(asked()).toEqual([])
  await picks(w, $, 'q1')
  await does(w, $, 'Edit', 'e1', { file_path: '/repo/a.ts' })
  await turnEnds($)
  // The card for PR 1700 was made before the box shown for his message, and that box covered it.
  // Nothing has shipped for the work he picked, so "work shipped" was not measured for it: no question.
  expect(asked()).toEqual([])
  await clock.advance(60_000)
  w.verdicts = { ...CARDED, 'danwright32/claude-config#1702': { state: 'live', at: NOW + 60_000 } }
  await turnEnds($)
  expect(asked()).toHaveLength(1)
  // What it says is what was measured: a box was shown since his message, none for what he picked.
  expect(asked()[0]?.text).toMatch(/no Goal accomplished box was shown for what he last asked for/)
})

test('a picker answered mid turn, with no box yet, does not lose the question for work that shipped before it (#3843, #2523)', withLive, async ($, on) => {
  const { w, clock, submitted } = world(on, { verdicts: CARDED })
  await start($)
  await says($, 'Merge PR 1700')
  // The card for PR 1700 is made at his message's time; the picker comes a minute later. Were the
  // request's time moved to the picked work, that card would fall before it and nothing be asked.
  await clock.advance(60_000)
  await picks(w, $, 'q1')
  await does(w, $, 'Edit', 'e1', { file_path: '/repo/a.ts' })
  await turnEnds($)
  expect(submitted.filter(s => s.text.startsWith(ASKS_DONE))).toHaveLength(1)
})

// The close this session card reads the same count of requests (#3770), so work Dan picked is his
// latest request there too: the card waits for that work's box, and can go up again after it.
test("work Dan picked is his latest request for the close card too: no card until that work's box is shown (#3843, #3770)", withAll, async ($, on) => {
  const { w, clock } = world(on)
  await start($)
  await says($, 'Run the monthly sync')
  await workedAndQuiet($, clock)
  expect(w.pinned).toHaveLength(1)
  await turnStarts($, 't2')
  await picks(w, $, 'q1')
  await does(w, $, 'Edit', 'e1', { file_path: '/repo/a.ts' })
  await workedAndQuiet($, clock, { box: false })
  expect(w.pinned).toHaveLength(1)
  expect(reasonsOf(w)).toMatchObject({ pinned: false })
  expect(reasonsOf(w)?.reasons.join(' ')).toMatch(/no Goal accomplished box was shown for Dan's latest request/)
  await turnStarts($, 't3')
  await workedAndQuiet($, clock, { id: 'b2' })
  expect(w.pinned).toHaveLength(2)
})

// ---- #3843, second half: the box waits for the end of turn review ----
// Dan's answers on the issue (2026-11-27): hold the box "until the review is answered", and, of how
// the box is to know, "The review says so itself". The review's record is hooks/lib/review-record.py's
// (its own suite, payload/hooks/test-review-record.sh, holds what it records and when a record ends);
// here its reader answers what each test says, and the session's events stand in for a turn.
const ASKS_AGAIN = 'GOAL ACCOMPLISHED BOX WAITING.'
const LAST_STEP = `python3 ~/.claude/hooks/lib/review-record.py answered --transcript '${T}'`
const edits = (w: World, $: Engine$, id = 'e1') => does(w, $, 'Edit', id, { file_path: '/repo/a.ts' })

test('a turn that has changed something: the box waits for its end of turn review, and the refusal says what to do (#3843)', withKit, async ($, on) => {
  const { w, cards, reviewAsks } = world(on)
  await start($)
  await says($, 'Run the monthly sync')
  await edits(w, $)
  const r = await box($, ASKED)
  expect(r.deny).toMatch(/^No box yet: this turn has changed something, so its end of turn review is still to come, and the box waits until Dan has answered the end of turn review\./)
  // Words the session can act on: end the turn, do the review, record its last step, call again.
  expect(r.deny).toMatch(/End your turn without the box\. When the review is handed to you, do it\./)
  expect(r.deny).toContain(`run \`${LAST_STEP}\` and then call this tool again, as the review's last step`)
  expect(r.deny).toMatch(/If no review is handed to you when the turn ends, you are asked once to call this tool again\.$/)
  expect(await cards()).toEqual([])
  // The record is read by its one owner, from where the sync installs it, for this session's transcript.
  expect(reviewAsks).toEqual([['python3', '-I', '-B', REVIEW_FILE, 'state', '--transcript', T]])
})

test('a review handed over and not yet answered holds the box; once its last step has recorded the answer, the same call shows it (#3843)', withKit, async ($, on) => {
  const { w, cards } = world(on)
  await start($)
  await says($, 'Run the monthly sync')
  await edits(w, $)
  w.review = reviewSays('handed')
  const r = await box($, ASKED)
  expect(r.deny).toMatch(/^No box yet: the end of turn review was handed to you this turn and is not on record as answered, and the box waits until Dan has answered the end of turn review\. Finish the review first\./)
  expect(r.deny).toContain(`Once Dan has answered what the review asked, or it asked him nothing, run \`${LAST_STEP}\` and then call this tool again, as the review's last step.`)
  expect(await cards()).toEqual([])
  w.review = reviewSays('answered')
  expect((await box($, ASKED, 'b2')).deny).toBeUndefined()
  expect((await cards()).map(c => c.toolUseId)).toEqual(['b2'])
})

test('the record decides, not what the mod saw: a review on record as handed over holds the box in a turn the mod saw no work in (#3843)', withKit, async ($, on) => {
  const { w } = world(on, { review: reviewSays('handed') })
  await start($)
  await says($, 'Run the monthly sync')
  expect((await box($, ASKED)).deny).toMatch(/was handed to you this turn and is not on record as answered/)
})

test('work Dan picked after an answered review, finished: shown; with the review still to come it waits like any other (#3843)', withKit, async ($, on) => {
  const { w } = world(on)
  await start($)
  await askedAndShown($, 'Run the monthly sync', 'b1')
  await picks(w, $, 'q1')
  await edits(w, $)
  expect((await box($, MORE, 'b2')).deny).toMatch(/its end of turn review is still to come/)
  w.review = reviewSays('answered')
  expect((await box($, MORE, 'b3')).deny).toBeUndefined()
})

test('a turn that changed nothing holds nothing: the box shows as before, reads and a picker included (#3843)', withKit, async ($, on) => {
  const { w, cards } = world(on)
  await start($)
  await says($, 'Is the monthly sync done?')
  await does(w, $, 'Read', 'r1', { file_path: '/repo/a.ts' })
  await does(w, $, 'Grep', 'g1', { pattern: 'count' })
  await picks(w, $, 'q1')
  expect((await box($, ASKED)).deny).toBeUndefined()
  expect((await cards()).map(c => c.toolUseId)).toEqual(['b1'])
})

// What makes a review still to come is what the review hooks count at the turn's end: a tool the
// review's test counts, named in the main conversation's transcript, whatever became of the call.
const TO_COME_ROWS: [string, string, Record<string, unknown>, unknown, boolean][] = [
  ['an edit', 'Edit', { file_path: '/repo/a.ts' }, undefined, true],
  ['a command', 'Bash', { command: 'gh pr merge 12' }, undefined, true],
  ['a connected tool that acts', 'mcp__is-it-live__card', {}, undefined, true],
  ['an edit a guard refused, which the review hooks count all the same', 'Edit', { file_path: '/repo/a.ts' }, { deny: 'held by a guard' }, true],
  ['an edit that came back as an error', 'Edit', { file_path: '/repo/a.ts' }, { isError: true, result: 'refused by a hook', text: 'refused by a hook' }, true],
  ['a read', 'Read', { file_path: '/repo/a.ts' }, undefined, false],
  ["a subagent's edit, which is not in the main conversation's transcript", 'Edit', { file_path: '/repo/a.ts', agentId: 'a1' }, undefined, false],
  ['a picker Dan answers', 'AskUserQuestion', PICKER, PICKED, false],
]
for (const [what, tool, input, answer, holds] of TO_COME_ROWS)
  test(`${what} ${holds ? 'means a review is to come: the box waits' : 'brings no review: the box shows'} (#3843)`, withKit, async ($, on) => {
    const { w } = world(on)
    await start($)
    await says($, 'Run the monthly sync')
    await does(w, $, tool, 'w1', input, answer)
    const r = await box($, ASKED)
    if (holds) expect(r.deny).toMatch(/its end of turn review is still to come/)
    else expect(r.deny).toBeUndefined()
  })

test("the box's own tool is never the turn's work: a call refused for something else does not hold the next one (#3843)", withKit, async ($, on) => {
  const { w } = world(on, { agents: [{ id: 'a1', status: 'running' }] })
  await start($)
  await says($, 'Run the monthly sync')
  expect((await box($, ASKED)).deny).toMatch(/still running/)
  w.agents = []
  expect((await box($, ASKED, 'b2')).deny).toBeUndefined()
})

// The test above passes whether or not the box's own tool is left out, because the box's own hook
// answers its call and passes nothing on, so the hook that reads every call never sees it. Leaving
// it out is the second guard, for the day the two hooks change places, and it is held here on the
// rule itself (review.ts canBeTurnWork), which is what that hook asks before it reads a call.
const CAN_BE_WORK_ROWS: [string, { tool: string; agentId?: string }, boolean][] = [
  ["an edit of the main conversation's", { tool: 'Edit' }, true],
  ["a read of the main conversation's, which the review's own test then says no to", { tool: 'Read' }, true],
  ["the box's own tool, which the review's own test would count by its name", { tool: TOOL }, false],
  ['the picker', { tool: 'AskUserQuestion' }, false],
  ["a subagent's edit", { tool: 'Edit', agentId: 'a1' }, false],
]
for (const [what, call, read] of CAN_BE_WORK_ROWS)
  test(`${what} is ${read ? 'read' : 'never read'} for being the turn's work (#3843)`, async () => {
    expect(canBeTurnWork(call)).toBe(read)
  })

test("the review's own test of a tool's name runs beside the call, never ahead of it: the tool starts while that test is still out, the call comes back only once the turn is noted, and the box then waits (#3843)", withKit, async ($, on) => {
  const { w, clock } = world(on, { workTestWaits: true })
  await start($)
  await says($, 'Run the monthly sync')
  let back = false
  const call = edits(w, $).then(r => {
    back = true
    return r
  })
  try {
    await clock.settle()
    expect({ began: w.began, back }).toEqual({ began: ['e1'], back: false })
  } finally {
    w.releaseWorkTest()
    await call
  }
  expect((await box($, ASKED)).deny).toMatch(/its end of turn review is still to come/)
})

test('work in an earlier turn does not hold this turn: the hold ends with the turn it began in (#3843)', withKit, async ($, on) => {
  const { w } = world(on)
  await start($)
  await says($, 'Run the monthly sync')
  await edits(w, $)
  await turnEnds($)
  await turnStarts($, 't2')
  expect((await box($, ASKED)).deny).toBeUndefined()
})

test('a box already shown for the request is refused as already shown, never as waiting for a review (#3843)', withKit, async ($, on) => {
  const { w } = world(on)
  await start($)
  await askedAndShown($, 'Run the monthly sync', 'b1')
  await edits(w, $)
  const r = await box($, ASKED, 'b2')
  expect(r.deny).toMatch(/already shown for this request/)
  expect(r.deny).not.toMatch(/end of turn review/)
})

test("no review at the turn's end: the session is asked once to call again, and that call shows the box (#3843)", withKit, async ($, on) => {
  const { w, cards, submitted } = world(on)
  const asked = () => submitted.filter(s => s.text.startsWith(ASKS_AGAIN))
  await start($)
  await says($, 'Run the monthly sync')
  await edits(w, $)
  expect((await box($, ASKED)).deny).toMatch(/its end of turn review is still to come/)
  expect(asked()).toEqual([])
  // The turn ends and no review was handed over (the hooks' kill switch, say): nothing recorded.
  await turnEnds($)
  expect(asked()).toHaveLength(1)
  expect(asked()[0]?.origin).toMatchObject({ kind: 'plugin' })
  expect(asked()[0]?.text).toMatch(/was refused until the end of turn review had run and Dan had answered it\. That turn has ended and no box was shown since\./)
  expect(asked()[0]?.text).toContain(`call ${TOOL} again now`)
  // #3864: a box held back must be said in one line, so Dan can tell it from one forgotten, and
  // only the session's own part of the request has to be finished.
  expect(asked()[0]?.text.endsWith(HELD_TAIL)).toBe(true)
  expect(asked()[0]?.text).toContain(`If ${YOURS_DONE}, call ${TOOL} again now`)
  // Sent as the mod's other prompts are: mod-kit's reload held back until it has gone (#2132).
  expect(w.held.filter(h => h === 'submit' || h.includes('ask-after-review'))).toHaveLength(3)
  // The message starts a turn that has changed nothing, so the call it asks for is not held.
  await turnStarts($, 't2')
  expect((await box($, ASKED, 'b2')).deny).toBeUndefined()
  expect((await cards()).map(c => c.toolUseId)).toEqual(['b2'])
  await turnEnds($)
  expect(asked()).toHaveLength(1)
})

test('never more than one such message for one request, and a new request of his can earn its own (#3843)', withKit, async ($, on) => {
  const { w, submitted } = world(on)
  const asked = () => submitted.filter(s => s.text.startsWith(ASKS_AGAIN))
  await start($)
  await says($, 'Run the monthly sync')
  await edits(w, $)
  expect((await box($, ASKED)).deny).toMatch(/still to come/)
  await turnEnds($)
  expect(asked()).toHaveLength(1)
  // The turn the message starts does more work, is held again, and ends again with no box.
  await turnStarts($, 't2')
  await edits(w, $, 'e2')
  expect((await box($, ASKED, 'b2')).deny).toMatch(/still to come/)
  await turnEnds($)
  await turnEnds($)
  expect(asked()).toHaveLength(1)
  await says($, 'Now make the status bar quieter')
  await edits(w, $, 'e3')
  expect((await box($, ASKED, 'b3')).deny).toMatch(/still to come/)
  await turnEnds($)
  expect(asked()).toHaveLength(2)
})

test('a box shown after the hold, or no hold at all, asks nothing at the turn end; nor does a turn end that is not the main conversation finishing (#3843)', withKit, async ($, on) => {
  const { w, submitted } = world(on)
  const asked = () => submitted.filter(s => s.text.startsWith(ASKS_AGAIN))
  await start($)
  await says($, 'Run the monthly sync')
  await edits(w, $)
  await turnEnds($)
  expect(asked()).toEqual([])
  await says($, 'And the weekly one')
  await edits(w, $, 'e2')
  expect((await box($, ASKED)).deny).toMatch(/still to come/)
  // A subagent's turn end and an interrupted turn are not the turn's end.
  await turnEnds($, { agentId: 'a1' })
  await turnEnds($, { reason: 'interrupt' })
  expect(asked()).toEqual([])
  w.review = reviewSays('answered')
  expect((await box($, ASKED, 'b2')).deny).toBeUndefined()
  await turnEnds($)
  expect(asked()).toEqual([])
})

test('a headless session is never sent the message (#3843)', withKit, async ($, on) => {
  const { w, submitted } = world(on)
  await start($, false)
  await says($, 'Run the monthly sync')
  await edits(w, $)
  await box($, ASKED)
  await turnEnds($)
  expect(submitted.filter(s => s.text.startsWith(ASKS_AGAIN))).toEqual([])
})

test('the message waits while something is in flight, and is sent at the next turn end once it has settled (#3843)', withKit, async ($, on) => {
  const { w, submitted } = world(on)
  const asked = () => submitted.filter(s => s.text.startsWith(ASKS_AGAIN))
  await start($)
  await says($, 'Run the monthly sync')
  await edits(w, $)
  expect((await box($, ASKED)).deny).toMatch(/still to come/)
  w.agents = [{ id: 'a1', status: 'running' }]
  await turnEnds($)
  expect(asked()).toEqual([])
  w.agents = []
  await turnEnds($)
  expect(asked()).toHaveLength(1)
})

test('a message that could not be sent is said and sent again at the next turn end (#3843)', withKit, async ($, on) => {
  const { w, submitted, logs } = world(on, { submitFails: ['throw', 'drop'] })
  const asked = () => submitted.filter(s => s.text.startsWith(ASKS_AGAIN))
  await start($)
  await says($, 'Run the monthly sync')
  await edits(w, $)
  expect((await box($, ASKED)).deny).toMatch(/still to come/)
  await turnEnds($)
  await turnEnds($)
  expect(asked()).toEqual([])
  expect(logs.filter(l => /could not be asked to call the Goal accomplished box again \(.+\); it is asked again at the next turn end/.test(l))).toHaveLength(2)
  await turnEnds($)
  expect(asked()).toHaveLength(1)
})

test('two calls at once while the review is to come are both refused, and two turn ends at once send one message (#3843)', withKit, async ($, on) => {
  const { w, cards, submitted } = world(on)
  await start($)
  await says($, 'Run the monthly sync')
  await edits(w, $)
  const both = await Promise.all([box($, ASKED, 'b1'), box($, ASKED, 'b2')])
  expect(both.map(r => /still to come/.test(r.deny ?? ''))).toEqual([true, true])
  expect(await cards()).toEqual([])
  await Promise.all([turnEnds($), turnEnds($)])
  expect(submitted.filter(s => s.text.startsWith(ASKS_AGAIN))).toHaveLength(1)
})

test("the message is the turn end's one question: where work shipped too, the session is not also asked whether it is finished (#3843, #2523)", withLive, async ($, on) => {
  const { w, submitted } = world(on, { verdicts: CARDED })
  await start($)
  await says($, 'Merge PR 1700')
  await edits(w, $)
  expect((await box($, ASKED)).deny).toMatch(/still to come/)
  await turnEnds($)
  await turnEnds($)
  expect(submitted.filter(s => s.text.startsWith(ASKS_AGAIN))).toHaveLength(1)
  expect(submitted.filter(s => s.text.startsWith(ASKS_DONE))).toEqual([])
})

test('work Dan picked after a held call still gets the message: the hold is remembered across the new request it opens (#3843)', withKit, async ($, on) => {
  const { w, submitted } = world(on)
  await start($)
  await says($, 'Run the monthly sync')
  await edits(w, $)
  expect((await box($, ASKED)).deny).toMatch(/still to come/)
  await picks(w, $, 'q1')
  await edits(w, $, 'e2')
  await turnEnds($)
  expect(submitted.filter(s => s.text.startsWith(ASKS_AGAIN))).toHaveLength(1)
})

// A record that cannot be read never holds the box and is never taken for answered in silence.
const UNREAD_ROWS: [string, Gh, RegExp][] = [
  ['its reader exits with an error', { exitCode: 3, stdout: '', stderr: 'review-record: /t/s1.jsonl.review-handed.json does not hold a record (Expecting value)' }, /does not hold a record \(Expecting value\)/],
  ['its reader is not installed', { exitCode: 2, stdout: '', stderr: "python3: can't open file 'review-record.py'" }, /can't open file/],
  ['its reader prints something that is not its answer', { exitCode: 0, stdout: 'garbled' }, /answered "garbled", which names no state/],
  ['its reader names a state the mod does not know', { exitCode: 0, stdout: '{"state": "pending"}' }, /which names no state/],
]
for (const [how, said, why] of UNREAD_ROWS)
  test(`the review's record cannot be read (${how}): the box shows, and says it did not wait (#3843)`, withAll, async ($, on) => {
    const { w, clock, cards, logs } = world(on, { review: said })
    await start($)
    await says($, 'Run the monthly sync')
    await edits(w, $)
    const r = await box($, ASKED)
    expect(r.deny).toBeUndefined()
    expect((await cards()).map(c => c.toolUseId)).toEqual(['b1'])
    const told = logs.filter(l => l.startsWith('The Goal accomplished box was shown without waiting for the end of turn review: '))
    expect(told).toHaveLength(1)
    expect(told[0]).toMatch(/the end of turn review's record could not be read/)
    expect(told[0]).toMatch(why)
    // The session is told too, and the close card's reasons file keeps it as a note.
    expect((r.context ?? []).join(' ')).toMatch(/shown without waiting for the end of turn review/)
    await stopped($)
    await turnEnds($)
    await clock.advance(QUIET_MS)
    expect(reasonsOf(w)?.notes).toContain(told[0])
  })

test('a record read cleanly says nothing of the kind: no log line, no note (#3843)', withAll, async ($, on) => {
  const { w, clock, logs } = world(on, REVIEWED)
  await start($)
  await says($, 'Run the monthly sync')
  await edits(w, $)
  const r = await box($, ASKED)
  expect(r.deny).toBeUndefined()
  expect(logs.filter(l => /without waiting/.test(l))).toEqual([])
  expect((r.context ?? []).join(' ')).not.toMatch(/without waiting/)
  await stopped($)
  await turnEnds($)
  await clock.advance(QUIET_MS)
  expect(reasonsOf(w)?.notes).toEqual([])
})

test("whether the turn changed something cannot be read (the review's test will not run): the box shows, and says so (#3843)", withKit, async ($, on) => {
  const { w, logs } = world(on, { workTest: { exitCode: 1, stdout: '', stderr: "python3: can't open file" } })
  await start($)
  await says($, 'Run the monthly sync')
  await edits(w, $)
  expect((await box($, ASKED)).deny).toBeUndefined()
  expect(logs.filter(l => /shown without waiting for the end of turn review: whether this turn changed something, and so whether an end of turn review is still to come, could not be read \(.*can't open file.*\)/.test(l))).toHaveLength(1)
})

test('while Dan is asleep the reviews stand down, so the box does not wait for one and the record is not asked (#3843)', withAll, async ($, on) => {
  const { w, reviewAsks } = world(on, { asleep: true, review: reviewSays('handed') })
  await start($)
  await says($, 'Run the monthly sync')
  await edits(w, $)
  expect((await box($, ASKED)).deny).toBeUndefined()
  expect(reviewAsks).toEqual([])
})

test("the reviews switched off for this conversation (the Stop hooks' own switch file beside its transcript): no review will run, so the box shows as it did and the record is not asked (#3843)", withKit, async ($, on) => {
  const { w, cards, submitted, reviewAsks } = world(on, { disk: { [`${T}.skip-stop-hooks`]: true }, review: reviewSays('handed') })
  await start($)
  await says($, 'Run the monthly sync')
  await edits(w, $)
  expect((await box($, ASKED)).deny).toBeUndefined()
  expect((await cards()).map(c => c.toolUseId)).toEqual(['b1'])
  expect(reviewAsks).toEqual([])
  await turnEnds($)
  expect(submitted.filter(s => s.text.startsWith(ASKS_AGAIN))).toEqual([])
})

test('whether the reviews are switched off cannot be checked: the box waits as if they were on, and the turn end message still covers it (#3843)', withKit, async ($, on) => {
  const { w, logs } = world(on, { disk: { [`${T}.skip-stop-hooks`]: 'the folder could not be read' } })
  await start($)
  await says($, 'Run the monthly sync')
  await edits(w, $)
  expect((await box($, ASKED)).deny).toMatch(/its end of turn review is still to come/)
  expect(logs.filter(l => /whether the end of turn reviews are switched off for this conversation could not be checked \(.*the folder could not be read.*\)/.test(l))).toHaveLength(1)
})

test('a review handed over and never answered does not hold his next request: the record ends with its turn (#3843)', withKit, async ($, on) => {
  const { w, submitted } = world(on)
  await start($)
  await says($, 'Run the monthly sync')
  await edits(w, $)
  w.review = reviewSays('handed')
  expect((await box($, ASKED)).deny).toMatch(/not on record as answered/)
  await turnEnds($)
  // Dan closed the review's picker. His next message is a new turn, where the record's own reader
  // answers none for a hand over of the turn before (test-review-record.sh holds that to the file).
  w.review = reviewSays('none')
  await says($, 'Never mind that. Is it done?')
  expect((await box($, ASKED, 'b2')).deny).toBeUndefined()
  // And the mod never asked for the box behind the review he left unanswered.
  expect(submitted.filter(s => s.text.startsWith(ASKS_AGAIN))).toEqual([])
})

// ---- The one message asks the record first ----
// A message sent where the review was handed over and Dan closed its picker would be the next
// prompt: the record reads none under it, and the box would show behind a review nobody answered.
test("a review handed over and left unanswered when the turn ends: the mod sends nothing, at that turn end or a later one of the same request, and no box shows (#3843)", withKit, async ($, on) => {
  const { w, cards, submitted, reviewAsks, logs } = world(on)
  const asked = () => submitted.filter(s => s.text.startsWith(ASKS_AGAIN))
  await start($)
  await says($, 'Run the monthly sync')
  await edits(w, $)
  expect((await box($, ASKED)).deny).toMatch(/still to come/)
  expect(reviewAsks).toHaveLength(1)
  // The turn ends, the hooks hand the review over, and Dan closes its picker without answering.
  w.review = reviewSays('handed')
  await turnEnds($)
  expect(asked()).toEqual([])
  // The record was asked at the turn's end, by its one owner, for this session's transcript.
  expect(reviewAsks).toEqual([['python3', '-I', '-B', REVIEW_FILE, 'state', '--transcript', T], ['python3', '-I', '-B', REVIEW_FILE, 'state', '--transcript', T]])
  expect(logs.filter(l => /handed over this turn and Dan has not answered it, so the session is not asked to call the Goal accomplished box again for this request/.test(l))).toHaveLength(1)
  // A turn somebody else starts (a job's notice) ends with nothing handed over: still nothing sent,
  // since the review of this request went unanswered.
  w.review = reviewSays('none')
  await turnStarts($, 't2')
  await turnEnds($)
  expect(asked()).toEqual([])
  expect(await cards()).toEqual([])
  // His own next message is a new request, and can earn its own message.
  await says($, 'Now make the status bar quieter')
  await edits(w, $, 'e2')
  expect((await box($, ASKED, 'b2')).deny).toMatch(/still to come/)
  await turnEnds($)
  expect(asked()).toHaveLength(1)
})

test("a review answered by the turn's end, with no box shown since: the session is still asked once (#3843)", withKit, async ($, on) => {
  const { w, submitted } = world(on)
  await start($)
  await says($, 'Run the monthly sync')
  await edits(w, $)
  expect((await box($, ASKED)).deny).toMatch(/still to come/)
  w.review = reviewSays('answered')
  await turnEnds($)
  expect(submitted.filter(s => s.text.startsWith(ASKS_AGAIN))).toHaveLength(1)
})

test("the record cannot be read at the turn's end: the message is sent, and Dan is told it was sent without knowing (#3843)", withKit, async ($, on) => {
  const { w, submitted, logs } = world(on)
  await start($)
  await says($, 'Run the monthly sync')
  await edits(w, $)
  expect((await box($, ASKED)).deny).toMatch(/still to come/)
  w.review = UNREAD_AT_END
  await turnEnds($)
  expect(submitted.filter(s => s.text.startsWith(ASKS_AGAIN))).toHaveLength(1)
  expect(logs.filter(l => PROMPTED_UNREAD.test(l))).toHaveLength(1)
})

test("a record read cleanly at the turn's end says nothing of the kind (#3843)", withKit, async ($, on) => {
  const { w, submitted, logs } = world(on)
  await start($)
  await says($, 'Run the monthly sync')
  await edits(w, $)
  expect((await box($, ASKED)).deny).toMatch(/still to come/)
  await turnEnds($)
  expect(submitted.filter(s => s.text.startsWith(ASKS_AGAIN))).toHaveLength(1)
  expect(logs.filter(l => /without knowing/.test(l))).toEqual([])
})

test("Dan asleep by the turn's end, after a box was held while he was awake: no review will be handed over, so the record is not asked and the message is sent (#3843)", withAll, async ($, on) => {
  const { w, submitted, reviewAsks } = world(on)
  await start($)
  await says($, 'Run the monthly sync')
  await edits(w, $)
  expect((await box($, ASKED)).deny).toMatch(/still to come/)
  w.asleep = true
  w.review = reviewSays('handed')
  await turnEnds($)
  expect(submitted.filter(s => s.text.startsWith(ASKS_AGAIN))).toHaveLength(1)
  expect(reviewAsks).toHaveLength(1)
})

// The mod's two older prompts at a turn's end start a new turn just as the message above does, so
// each would show the box behind an unanswered review the same way. No prompt of the mod about the
// box is sent over a review that is handed over and not answered.
const GOAL_PROMPT = 'GOAL ACCOMPLISHED. The /goal'

test("an unanswered review at the turn's end stops the question about shipped work too, with or without an earlier refused call, and for the rest of the request (#3843, #2523)", withLive, async ($, on) => {
  const { w, submitted, logs } = world(on, { verdicts: CARDED })
  const prompts = () => submitted.filter(s => s.text.startsWith(ASKS_DONE) || s.text.startsWith(ASKS_AGAIN))
  await start($)
  // No call for the box was refused this request: only the shipped work would ask.
  await says($, 'Merge PR 1700')
  await edits(w, $)
  w.review = reviewSays('handed')
  await turnEnds($)
  expect(prompts()).toEqual([])
  expect(logs.filter(l => /handed over this turn and Dan has not answered it, so the session is not asked whether the work is finished for this request/.test(l))).toHaveLength(1)
  // A turn somebody else starts ends with nothing handed over: the request's question stays spent.
  w.review = reviewSays('none')
  await turnStarts($, 't2')
  await turnEnds($)
  expect(prompts()).toEqual([])
  // With a refused call as well, neither prompt goes.
  await says($, 'And merge PR 1701')
  await edits(w, $, 'e2')
  expect((await box($, ASKED)).deny).toMatch(/still to come/)
  w.review = reviewSays('handed')
  await turnEnds($)
  expect(prompts()).toEqual([])
})

test("an unanswered review at the turn's end holds back the prompt for a met /goal, which is sent at the next turn end without one (#3843)", withKit, async ($, on) => {
  const { w, submitted, logs } = world(on, { goal: MET, review: reviewSays('handed') })
  const prompts = () => submitted.filter(s => s.text.startsWith(GOAL_PROMPT))
  await start($)
  await turnEnds($)
  expect(prompts()).toEqual([])
  expect(logs.filter(l => /handed over this turn and Dan has not answered it, so the prompt for the met \/goal waits for a later turn end/.test(l))).toHaveLength(1)
  w.review = reviewSays('none')
  await turnEnds($)
  expect(prompts()).toHaveLength(1)
  await turnEnds($)
  expect(prompts()).toHaveLength(1)
})

const UNREAD_AT_END = { exitCode: 3, stdout: '', stderr: 'review-record: the transcript could not be read (timed out)' }
const PROMPTED_UNREAD = /^The session was sent a prompt about the Goal accomplished box without knowing whether an end of turn review is waiting for Dan: the end of turn review's record could not be read \(review-record: the transcript could not be read \(timed out\)\)\.$/

test("the record cannot be read at the turn's end: the question about shipped work is still asked, and Dan is told it was sent without knowing (#3843, #2523)", withLive, async ($, on) => {
  const { submitted, logs } = world(on, { verdicts: CARDED, review: UNREAD_AT_END })
  await start($)
  await says($, 'Merge PR 1700')
  await turnEnds($)
  expect(submitted.filter(s => s.text.startsWith(ASKS_DONE))).toHaveLength(1)
  expect(logs.filter(l => PROMPTED_UNREAD.test(l))).toHaveLength(1)
})

test("the record cannot be read at the turn's end: the prompt for a met /goal is still sent, and Dan is told it was sent without knowing (#3843)", withKit, async ($, on) => {
  const { submitted, logs } = world(on, { goal: MET, review: UNREAD_AT_END })
  await start($)
  await turnEnds($)
  expect(submitted.filter(s => s.text.startsWith(GOAL_PROMPT))).toHaveLength(1)
  expect(logs.filter(l => PROMPTED_UNREAD.test(l))).toHaveLength(1)
})

test("a turn end that sends no prompt does not ask the record at all (#3843)", withLive, async ($, on) => {
  const { w, reviewAsks } = world(on)
  await start($)
  await says($, 'Is the monthly sync done?')
  await edits(w, $)
  await turnEnds($)
  expect(reviewAsks).toEqual([])
})

// ---- A hold and its message belong to one request; what counts as the turn's work after a failed
// read; who may answer the review; a met /goal's own prompt; a note that cannot be kept ----

test("a box held in one request, its turn interrupted, then Dan asks for something new: the old request's message is never sent under the new one (#3843)", withKit, async ($, on) => {
  const { w, submitted } = world(on)
  const asked = () => submitted.filter(s => s.text.startsWith(ASKS_AGAIN))
  await start($)
  await says($, 'Run the monthly sync')
  await edits(w, $)
  expect((await box($, ASKED)).deny).toMatch(/still to come/)
  await turnEnds($, { reason: 'interrupt' })
  await says($, 'Is the weekly one done?')
  await turnEnds($)
  expect(asked()).toEqual([])
  // The same where the message was only waiting on something in flight when he typed.
  await edits(w, $, 'e2')
  expect((await box($, ASKED, 'b2')).deny).toMatch(/still to come/)
  w.agents = [{ id: 'a1', status: 'running' }]
  await turnEnds($)
  w.agents = []
  await says($, 'And the yearly one?')
  await turnEnds($)
  expect(asked()).toEqual([])
})

test('work Dan picked in the turn the message starts is a request of its own: held again it earns one more message, and no third (#3843)', withKit, async ($, on) => {
  const { w, submitted } = world(on)
  const asked = () => submitted.filter(s => s.text.startsWith(ASKS_AGAIN))
  await start($)
  await says($, 'Run the monthly sync')
  await edits(w, $)
  expect((await box($, ASKED)).deny).toMatch(/still to come/)
  await turnEnds($)
  expect(asked()).toHaveLength(1)
  await turnStarts($, 't2')
  await picks(w, $, 'q1')
  await edits(w, $, 'e2')
  expect((await box($, MORE, 'b2')).deny).toMatch(/still to come/)
  await turnEnds($)
  expect(asked()).toHaveLength(2)
  await turnStarts($, 't3')
  await turnEnds($)
  expect(asked()).toHaveLength(2)
})

test("the review's test could not be run for the turn's first tool: a later call whose answer is already known still makes it a turn with a review to come, with no second run (#3843)", withKit, async ($, on) => {
  const { w, runs } = world(on)
  const tests = () => runs().filter(a => a.includes(WORK_TEST_FILE)).map(a => a[a.length - 1])
  await start($)
  // An earlier turn: the review's test says yes of Edit, and the mod keeps that for the session.
  await says($, 'Run the monthly sync')
  await edits(w, $)
  await turnEnds($)
  await says($, 'And the weekly one')
  w.workTest = { exitCode: 1, stdout: '', stderr: "python3: can't open file" }
  await does(w, $, 'Write', 'w1', { file_path: '/repo/b.ts' })
  await edits(w, $, 'e2')
  expect(tests()).toEqual(['Edit', 'Write'])
  expect((await box($, ASKED)).deny).toMatch(/its end of turn review is still to come/)
})

test('a refusal made once the request has had its one message no longer promises it, and the message says to call before anything else (#3843)', withKit, async ($, on) => {
  const { w, submitted } = world(on)
  await start($)
  await says($, 'Run the monthly sync')
  await edits(w, $)
  expect((await box($, ASKED)).deny).toMatch(/If no review is handed to you when the turn ends, you are asked once to call this tool again\.$/)
  await turnEnds($)
  const message = submitted.filter(s => s.text.startsWith(ASKS_AGAIN))
  expect(message).toHaveLength(1)
  expect(message[0]?.text).toMatch(/Call it before anything else in this turn: a command or an edit first, the review's last step included, makes this a turn with a review of its own to come, and the call waits again\./)
  // The session runs the review's last step first all the same, as the earlier refusal told it to.
  await turnStarts($, 't2')
  await does(w, $, 'Bash', 'c1', { command: LAST_STEP })
  const r = await box($, ASKED, 'b2')
  expect(r.deny).toMatch(/its end of turn review is still to come/)
  expect(r.deny).not.toMatch(/you are asked once/)
  expect(r.deny).toMatch(/Nothing asks you to call this tool again when this turn ends: that is done once for a request, and for this one it has been done or a review handed over for it was left unanswered\. The box for this request now comes only through a review that is handed to you and answered\.$/)
  await turnEnds($)
  expect(submitted.filter(s => s.text.startsWith(ASKS_AGAIN))).toHaveLength(1)
})

// Only the main conversation answers its end of turn review. A subagent's Bash call carries the main
// session's id (read in a subagent's own shell on 2026-11-27), so the last step run by a subagent,
// or by a fork that inherited the instruction, would mark the main session's review answered.
const ANSWERS_ROWS: [string, string, boolean][] = [
  ['the last step as the instruction writes it', 'python3 ~/.claude/hooks/lib/review-record.py answered', true],
  ["the last step as the refusal writes it, naming this session's transcript", LAST_STEP, true],
  ["the last step naming this session's transcript without quotes", `python3 ~/.claude/hooks/lib/review-record.py answered --transcript ${T}`, true],
  ['the last step after another command', `cd /repo && python3 "$HOME/.claude/hooks/lib/review-record.py" answered`, true],
  ['the last step naming another transcript, as a test of the record does', "python3 payload/hooks/lib/review-record.py answered --transcript '/scratch/t/s9.jsonl'", false],
  ["the record's reader", `python3 ~/.claude/hooks/lib/review-record.py state --transcript '${T}'`, false],
  ["the record's own suite", 'bash payload/hooks/test-review-record.sh', false],
  ['a search for the word', 'grep -n answered payload/hooks/lib/review-record.py', false],
]
for (const [what, command, answers] of ANSWERS_ROWS) {
  test(`${what} ${answers ? "would answer the main conversation's review" : 'answers nothing of the main conversation'} (#3843)`, async () => {
    expect(answersMainReview(command, T)).toBe(answers)
  })
  test(`a subagent running ${what} is ${answers ? 'refused, and nothing runs' : 'let through'}; the main conversation always is (#3843)`, withKit, async ($, on) => {
    const { w } = world(on)
    await start($)
    await says($, 'Run the monthly sync')
    const sub = (await does(w, $, 'Bash', 's1', { command, agentId: 'a1' })) as { deny?: string }
    if (answers) expect(sub.deny).toMatch(/^Not run: only the main conversation records that its end of turn review was answered/)
    else expect(sub.deny).toBeUndefined()
    expect(w.began.includes('s1')).toBe(!answers)
    expect(((await does(w, $, 'Bash', 'm1', { command })) as { deny?: string }).deny).toBeUndefined()
    expect(w.began).toContain('m1')
  })
}

test("a subagent's last step naming a transcript is refused while this session's own transcript cannot be found, since which record it would mark is not known (#3843)", withKit, async ($, on) => {
  const { w } = world(on, { transcript: '', registry: 'absent' })
  await start($)
  const sub = (await does(w, $, 'Bash', 's1', { command: "python3 payload/hooks/lib/review-record.py answered --transcript '/scratch/t/s9.jsonl'", agentId: 'a1' })) as { deny?: string }
  expect(sub.deny).toMatch(/^Not run: only the main conversation records/)
  expect(answersMainReview("python3 payload/hooks/lib/review-record.py answered --transcript '/scratch/t/s9.jsonl'", undefined)).toBe(true)
})

test('a met /goal whose box was held for the review: the one message stands in for its prompt at that turn end, and once its box is shown its own prompt is never sent, nor the record asked for it (#3843)', withKit, async ($, on) => {
  const { w, submitted, cards, reviewAsks } = world(on, { goal: MET })
  const of = (start: string) => submitted.filter(s => s.text.startsWith(start))
  await start($)
  await says($, 'Run the monthly sync')
  await edits(w, $)
  expect((await box($, ASKED)).deny).toMatch(/still to come/)
  await turnEnds($)
  expect([of(ASKS_AGAIN).length, of(GOAL_PROMPT).length]).toEqual([1, 0])
  await turnStarts($, 't2')
  expect((await box($, ASKED, 'b2')).deny).toBeUndefined()
  expect((await cards()).map(c => c.toolUseId)).toEqual(['b2'])
  const asks = reviewAsks.length
  await turnEnds($)
  await turnEnds($)
  expect([of(ASKS_AGAIN).length, of(GOAL_PROMPT).length]).toEqual([1, 0])
  expect(reviewAsks.length).toBe(asks)
})

test('a met /goal whose box was held and then not called for: its own prompt is sent at the next turn end, so its box is not lost (#3843)', withKit, async ($, on) => {
  const { w, submitted } = world(on, { goal: MET })
  const of = (start: string) => submitted.filter(s => s.text.startsWith(start))
  await start($)
  await says($, 'Run the monthly sync')
  await edits(w, $)
  expect((await box($, ASKED)).deny).toMatch(/still to come/)
  await turnEnds($)
  await turnStarts($, 't2')
  await turnEnds($)
  await turnEnds($)
  expect([of(ASKS_AGAIN).length, of(GOAL_PROMPT).length]).toEqual([1, 1])
})

test('the note that a box was shown without waiting cannot be kept: the box is drawn all the same, never claimed and lost, and Dan is still told (#3843)', withKit, async ($, on) => {
  const { w, cards, logs } = world(on, { review: UNREAD_AT_END })
  on('state.set', async ($, e, next) => ((e as { key?: string }).key === 'reviewUnread' ? ({ deny: 'state store unavailable' } as never) : next(e)))
  await start($)
  await says($, 'Run the monthly sync')
  await edits(w, $)
  const r = await box($, ASKED)
  expect(r.deny).toBeUndefined()
  expect((await cards()).map(c => c.toolUseId)).toEqual(['b1'])
  expect(logs.filter(l => l.startsWith('The Goal accomplished box was shown without waiting for the end of turn review: '))).toHaveLength(1)
  expect(logs.filter(l => /could not be kept for the close card's reasons file \(.*state store unavailable.*\)/.test(l))).toHaveLength(1)
})

test('the line that says a box was shown without waiting cannot be written: the box is drawn all the same, never claimed and lost (#3843)', withKit, async ($, on) => {
  const { w, cards } = world(on, { review: UNREAD_AT_END, logFails: /shown without waiting/ })
  await start($)
  await says($, 'Run the monthly sync')
  await edits(w, $)
  const r = await box($, ASKED)
  expect(r.deny).toBeUndefined()
  expect((await cards()).map(c => c.toolUseId)).toEqual(['b1'])
  // The session is still told, in the call's own answer.
  expect((r.context ?? []).join(' ')).toMatch(/shown without waiting for the end of turn review/)
})

test("the note that a box was shown without waiting belongs to its request: a later request's reasons file does not repeat it (#3843)", withAll, async ($, on) => {
  const { w, clock } = world(on, { review: UNREAD_AT_END })
  await start($)
  await says($, 'Run the monthly sync')
  await edits(w, $)
  expect((await box($, ASKED)).deny).toBeUndefined()
  await stopped($)
  await turnEnds($)
  await clock.advance(QUIET_MS)
  expect(reasonsOf(w)?.notes).toHaveLength(1)
  w.review = reviewSays('answered')
  await says($, 'Now the weekly one')
  await turnStarts($, 't2')
  await edits(w, $, 'e2')
  expect((await box($, ASKED, 'b2')).deny).toBeUndefined()
  await stopped($)
  await turnEnds($)
  await clock.advance(QUIET_MS)
  expect(reasonsOf(w)?.notes).toEqual([])
})

test('the tool says in its description that it waits for the review (#3843)', withKit, async ($, on) => {
  const { tools } = world(on)
  await start($)
  expect(tools[0]?.description).toMatch(/In a turn that has changed something it also waits until the end of turn review has run and Dan has answered it/)
})

test("the review's last step is one command whatever the transcript's path holds, and the reader's answer is held to its three words (#3843)", withKit, async () => {
  // The work MacBook keeps its projects under a folder with an apostrophe and spaces in its name.
  // The folder is put together here, as T is, so no line of this file names a home directory.
  const under = `${'/Users'}/dan/Documents - Dan`
  expect(answeredCommand(`${under}'s MacBook Pro/.claude/projects/-repo/s1.jsonl`)).toBe(
    `python3 ~/.claude/hooks/lib/review-record.py answered --transcript '${under}'\\''s MacBook Pro/.claude/projects/-repo/s1.jsonl'`,
  )
  // And that command, quoted so, is known for the main conversation's last step under such a path.
  const apostrophe = `${under}'s MacBook Pro/.claude/projects/-repo/s1.jsonl`
  expect(answersMainReview(answeredCommand(apostrophe), apostrophe)).toBe(true)
  expect(answersMainReview(answeredCommand(`${under}/other.jsonl`), apostrophe)).toBe(false)
  expect(reviewRead({ exitCode: 0, stdout: '{"state": "handed", "turn": "p1"}\n', stderr: '' })).toEqual({ state: 'handed' })
  expect(reviewRead({ exitCode: 0, stdout: '{"state": "none"}', stderr: 'a warning' })).toEqual({ state: 'none' })
  expect(reviewRead({ exitCode: 3, stdout: '{"state": "answered"}', stderr: 'review-record: it could not be read\n' })).toEqual({ unread: 'review-record: it could not be read' })
  expect(reviewRead({ exitCode: 1, stdout: '', stderr: '' })).toEqual({ unread: "the read of the review's record exited 1" })
  const odd = reviewRead({ exitCode: 0, stdout: 'null', stderr: '' })
  expect('unread' in odd ? odd.unread : 'read as a state').toMatch(/names no state/)
})

// ---- What does not hold the box, and what a session says when it holds it (#3864) ----
// What only Dan can do holds no box: a draft he sends, a check /check-later has scheduled and work
// he declined in a picker are not the session's unfinished work, and the description says so. A
// session that holds the box for work of its own is asked for one line, because silence there
// reads to Dan the same as a box forgotten.
const HELD_TAIL = 'If part of it is still yours to do, do not call it, and say in one line what the box is waiting on, unless you have said so already and it has not changed.'
const YOURS_DONE = 'every part of what Dan asked for that is yours to do is finished'

test("the description says what does not hold the box: a step that is Dan's alone, a check /check-later scheduled, work he declined in a picker (#3864)", withKit, async ($, on) => {
  const { tools } = world(on)
  await start($)
  const said = tools[0]?.description ?? ''
  expect(said).toMatch(/These do not hold the box, since none is work of yours: a step only Dan can take \(a draft he sends, a command he types, a setting he changes\), a check \/check-later has put on the To Do list, and work he declined in a picker\./)
  // His step holds the box only with work behind it.
  expect(said).toMatch(/A step of his on the steps card holds the box only while work of your own waits behind it\./)
  // The opening sentence asks for the session's own part, so it does not contradict the list above.
  expect(said).toMatch(/is finished: every part of his request that is yours to do done, every pull request merged/)
  expect(said).not.toMatch(/every part of his request done/)
  // What the tool itself refuses for is said as before.
  expect(said).toMatch(/It refuses while anything is still in flight \(an agent still running, a merge or deploy not confirmed, a pull request this session touched still open\)/)
})

test('the description says a box held back is said in one line, once, and never asks for silence (#3864)', withKit, async ($, on) => {
  const { tools } = world(on)
  await start($)
  const said = tools[0]?.description ?? ''
  expect(said).toMatch(/If you hold the box back because part of the request is still yours to do, say in one line what the box is waiting on, unless you have said so already and it has not changed\./)
  expect(said).not.toMatch(/say nothing/)
})

test('the question about shipped work asks for one line where the box is held, in place of silence (#3864, #2523)', withLive, async ($, on) => {
  const { submitted } = world(on, { verdicts: CARDED })
  await start($)
  await says($, 'Merge PR 1700')
  await turnEnds($)
  const asked = submitted.filter(s => s.text.startsWith(ASKS_DONE))
  expect(asked).toHaveLength(1)
  expect(asked[0]?.text.endsWith(HELD_TAIL)).toBe(true)
  expect(asked[0]?.text).not.toMatch(/say nothing/)
  // Only the session's own part has to be finished: what is left for Dan alone holds no box.
  expect(asked[0]?.text).toContain(`If ${YOURS_DONE}, call ${TOOL} now`)
})

// ---- The prompt once the last step on the steps card is recorded (#3864) ----
// The end of turn review asks for the box while a card's steps are still open, and nothing asked
// again once Dan had done them. Manual steps keeps a record of the session recording a card's last
// open step (when, and how many of the session's own steps were done), and at the turn's end this
// mod asks the session once for each such record, with no /goal set.
const ASKS_CARD = 'GOAL ACCOMPLISHED? Every step on the manual steps card has now been recorded'
const EMPTIED = { at: NOW + 60_000, done: 2 }
const cardAsks = <S extends { text: string }>(submitted: S[]): S[] => submitted.filter(s => s.text.startsWith(ASKS_CARD))

test('no /goal: the last step on the steps card recorded, and no box for the request, and the session is asked once (#3864)', withAll, async ($, on) => {
  const { w, submitted, cards } = world(on)
  await start($)
  await says($, 'Run the one off test and tell the team')
  await turnEnds($)
  expect(cardAsks(submitted)).toEqual([])
  w.stepsEmptied = EMPTIED
  await turnEnds($)
  expect(cardAsks(submitted)).toHaveLength(1)
  const asked = cardAsks(submitted)[0]
  expect(asked?.origin).toMatchObject({ kind: 'plugin' })
  expect(asked?.text).toBe(
    `${ASKS_CARD}, and no Goal accomplished box was shown for what Dan last asked for. If ${YOURS_DONE}, call ${TOOL} now, before anything else in this turn, with goal set to what he asked for and shipped listing what shipped, one short line each. ${HELD_TAIL}`,
  )
  // Sent as the mod's other prompts are: mod-kit's reload held back until it has gone (#2132).
  expect(w.held.filter(h => h === 'submit' || h.includes('ask-after-card'))).toHaveLength(3)
  // Not twice for one record, however many turns end.
  await turnStarts($, 't2')
  await turnEnds($)
  await turnEnds($)
  expect(cardAsks(submitted)).toHaveLength(1)
  // The turn the prompt starts has changed nothing, so the call it asks for shows the box.
  expect((await box($, ASKED)).deny).toBeUndefined()
  expect(await cards()).toHaveLength(1)
})

test('no /goal: a second card worked through later in the same request is asked about once more (#3864)', withAll, async ($, on) => {
  const { w, submitted } = world(on, { stepsEmptied: EMPTIED })
  await start($)
  await says($, 'Run the one off test and tell the team')
  await turnEnds($)
  expect(cardAsks(submitted)).toHaveLength(1)
  w.stepsEmptied = { at: EMPTIED.at + 1, done: 1 }
  await turnEnds($)
  await turnEnds($)
  expect(cardAsks(submitted)).toHaveLength(2)
})

test('a /goal still set: the steps card emptying asks nothing, then or once the goal is cleared (#3864)', withAll, async ($, on) => {
  const { w, submitted } = world(on, { stepsEmptied: EMPTIED, goal: { state: 'set', condition: 'complete milestone 80' } })
  await start($)
  await says($, 'Run the one off test and tell the team')
  await turnEnds($)
  expect(cardAsks(submitted)).toEqual([])
  w.goal = { state: 'none' }
  await turnEnds($)
  expect(cardAsks(submitted)).toEqual([])
})

test('a /goal that could not be read: nothing is asked yet, and it is asked once the goal reads as none (#3864)', withAll, async ($, on) => {
  const { w, submitted } = world(on, { stepsEmptied: EMPTIED, goal: { state: 'unreadable', why: 'the transcript could not be read' } })
  await start($)
  await says($, 'Run the one off test and tell the team')
  await turnEnds($)
  expect(cardAsks(submitted)).toEqual([])
  w.goal = { state: 'none' }
  await turnEnds($)
  expect(cardAsks(submitted)).toHaveLength(1)
})

test('a met /goal whose box is still owed is asked for by its own prompt alone; with that box shown, a card worked through for a later request is asked about (#3864)', withAll, async ($, on) => {
  const { w, submitted } = world(on, { stepsEmptied: EMPTIED, goal: MET })
  await start($)
  await says($, 'Finish issue 1563')
  await turnEnds($)
  expect(submitted.filter(s => s.text.startsWith(GOAL_PROMPT))).toHaveLength(1)
  expect(cardAsks(submitted)).toEqual([])
  expect((await box($, ASKED)).deny).toBeUndefined()
  // The box for the goal covers that request, so the card that emptied under it asks nothing.
  await turnEnds($)
  expect(cardAsks(submitted)).toEqual([])
  await says($, 'Now run the one off test')
  w.stepsEmptied = { at: EMPTIED.at + 5, done: 1 }
  await turnEnds($)
  expect(cardAsks(submitted)).toHaveLength(1)
})

test("a subagent's turn end and an interrupted turn ask nothing about the card, and the main conversation's next turn end still asks (#3864)", withAll, async ($, on) => {
  const { submitted } = world(on, { stepsEmptied: EMPTIED })
  await start($)
  await says($, 'Run the one off test and tell the team')
  await turnEnds($, { agentId: 'a1' })
  await turnEnds($, { isAborted: true, reason: 'aborted' })
  expect(cardAsks(submitted)).toEqual([])
  await turnEnds($)
  expect(cardAsks(submitted)).toHaveLength(1)
})

test('a headless session is never asked about the card (#3864)', withAll, async ($, on) => {
  const { submitted } = world(on, { stepsEmptied: EMPTIED })
  await start($, false)
  await says($, 'Run the one off test and tell the team')
  await turnEnds($)
  expect(cardAsks(submitted)).toEqual([])
})

test('a card whose steps were all taken off undone asks nothing, then or later (#3864)', withAll, async ($, on) => {
  const { submitted, logs } = world(on, { stepsEmptied: { at: EMPTIED.at, done: 0 } })
  await start($)
  await says($, 'Run the one off test and tell the team')
  await turnEnds($)
  await turnEnds($)
  expect(cardAsks(submitted)).toEqual([])
  expect(logs.filter(l => /no step on the steps card that emptied was done in this session, so the session is not asked about the Goal accomplished box/.test(l))).toHaveLength(1)
})

test('a box already shown for the request: the card emptying asks nothing, and nothing once Dan asks for something new (#3864)', withAll, async ($, on) => {
  const { w, submitted } = world(on)
  await start($)
  await says($, 'Run the one off test and tell the team')
  expect((await box($, ASKED)).deny).toBeUndefined()
  w.stepsEmptied = EMPTIED
  await turnEnds($)
  expect(cardAsks(submitted)).toEqual([])
  await says($, 'Now make the status bar quieter')
  await turnEnds($)
  expect(cardAsks(submitted)).toEqual([])
})

test('a card that emptied before Dan asked this session for anything asks nothing, then or after his first message (#3864)', withAll, async ($, on) => {
  const { submitted } = world(on, { stepsEmptied: EMPTIED })
  await start($)
  await turnEnds($)
  expect(cardAsks(submitted)).toEqual([])
  await says($, 'Run the one off test and tell the team')
  await turnEnds($)
  expect(cardAsks(submitted)).toEqual([])
})

test('an agent still running, or a pull request still open: the card emptying asks nothing until it is settled, then asks once (#3864)', withAll, async ($, on) => {
  const { w, submitted } = world(on, { stepsEmptied: EMPTIED, agents: [{ id: 'a1', status: 'running', description: 'Fix issue 1702' }], links: [link('danwright32/claude-config', 1700)], open: { 'danwright32/claude-config': { exitCode: 0, stdout: '[{"number":1700}]' } } })
  await start($)
  await says($, 'Run the one off test and tell the team')
  await turnEnds($)
  expect(cardAsks(submitted)).toEqual([])
  w.agents = [{ id: 'a1', status: 'completed' }]
  await turnEnds($)
  expect(cardAsks(submitted)).toEqual([])
  w.open = {}
  await turnEnds($)
  await turnEnds($)
  expect(cardAsks(submitted)).toHaveLength(1)
})

test("an unanswered review at the turn's end stops the prompt about the card, for that record for good (#3864, #3843)", withAll, async ($, on) => {
  const { w, submitted, logs } = world(on, { stepsEmptied: EMPTIED, review: reviewSays('handed') })
  await start($)
  await says($, 'Run the one off test and tell the team')
  await turnEnds($)
  expect(cardAsks(submitted)).toEqual([])
  expect(logs.filter(l => /handed over this turn and Dan has not answered it, so the session is not asked about the Goal accomplished box now the steps card has emptied/.test(l))).toHaveLength(1)
  w.review = reviewSays('none')
  await turnStarts($, 't2')
  await turnEnds($)
  expect(cardAsks(submitted)).toEqual([])
})

test("the review's record cannot be read at the turn's end: the prompt about the card is still sent, and Dan is told it was sent without knowing (#3864, #3843)", withAll, async ($, on) => {
  const { submitted, logs } = world(on, { stepsEmptied: EMPTIED, review: UNREAD_AT_END })
  await start($)
  await says($, 'Run the one off test and tell the team')
  await turnEnds($)
  expect(cardAsks(submitted)).toHaveLength(1)
  expect(logs.filter(l => PROMPTED_UNREAD.test(l))).toHaveLength(1)
})

test('a prompt about the card that could not be sent is said and sent again at the next turn end (#3864)', withAll, async ($, on) => {
  const { submitted, logs } = world(on, { stepsEmptied: EMPTIED, submitFails: ['drop'] })
  await start($)
  await says($, 'Run the one off test and tell the team')
  await turnEnds($)
  expect(cardAsks(submitted)).toEqual([])
  expect(logs.join('\n')).toMatch(/The last step on the steps card was recorded, but the session could not be asked about the Goal accomplished box \(held by a guard beneath\); it is asked again at the next turn end\./)
  await turnEnds($)
  await turnEnds($)
  expect(cardAsks(submitted)).toHaveLength(1)
})

test("one prompt a turn end: where work shipped too, only that question is sent, and the card's is not sent after it (#3864, #2523)", withAll, async ($, on) => {
  const { submitted } = world(on, { stepsEmptied: EMPTIED, verdicts: CARDED })
  await start($)
  await says($, 'Merge PR 1700')
  await turnEnds($)
  expect(submitted.filter(s => s.text.startsWith(ASKS_DONE))).toHaveLength(1)
  expect(cardAsks(submitted)).toEqual([])
  await turnStarts($, 't2')
  await turnEnds($)
  expect(cardAsks(submitted)).toEqual([])
})

test("one prompt a turn end: a question about shipped work that could not be sent is not followed by the card's prompt, and stands in for it once it is sent (#3864, #2523)", withAll, async ($, on) => {
  const { submitted, logs } = world(on, { stepsEmptied: EMPTIED, verdicts: CARDED, submitFails: ['drop'] })
  await start($)
  await says($, 'Merge PR 1700')
  await turnEnds($)
  expect(submitted.filter(s => s.text.startsWith(ASKS_DONE))).toEqual([])
  expect(cardAsks(submitted)).toEqual([])
  expect(logs.filter(l => /could not be asked/.test(l))).toHaveLength(1)
  await turnEnds($)
  expect(submitted.filter(s => s.text.startsWith(ASKS_DONE))).toHaveLength(1)
  expect(cardAsks(submitted)).toEqual([])
  await turnStarts($, 't2')
  await turnEnds($)
  expect(cardAsks(submitted)).toEqual([])
})

test("one prompt a turn end: the message after a refused call stands in for the card's prompt too (#3864, #3843)", withAll, async ($, on) => {
  const { w, submitted } = world(on)
  await start($)
  await says($, 'Run the one off test and tell the team')
  await edits(w, $)
  expect((await box($, ASKED)).deny).toMatch(/its end of turn review is still to come/)
  w.stepsEmptied = EMPTIED
  await turnEnds($)
  expect(submitted.filter(s => s.text.startsWith(ASKS_AGAIN))).toHaveLength(1)
  expect(cardAsks(submitted)).toEqual([])
  await turnStarts($, 't2')
  await turnEnds($)
  expect(cardAsks(submitted)).toEqual([])
})

test("manual steps' record in a shape this mod does not read asks nothing and is said in the debug log, never taken for a card worked through (#3864)", withAll, async ($, on) => {
  const { w, submitted, logs } = world(on, { stepsEmptied: { at: 'yesterday', done: 2 } })
  await start($)
  await says($, 'Run the one off test and tell the team')
  await turnEnds($)
  w.stepsEmptied = { at: EMPTIED.at }
  await turnEnds($)
  w.stepsEmptied = 'emptied'
  await turnEnds($)
  expect(cardAsks(submitted)).toEqual([])
  expect(logs.filter(l => /manual steps' record that the steps card emptied could not be read \(/.test(l))).toHaveLength(3)
})

test('with manual steps not loaded there is no record, and nothing is asked about a card (#3864)', withLive, async ($, on) => {
  const { submitted, logs } = world(on, { stepsEmptied: EMPTIED })
  await start($)
  await says($, 'Run the one off test and tell the team')
  await turnEnds($)
  expect(cardAsks(submitted)).toEqual([])
  expect(logs.filter(l => /steps card emptied/.test(l))).toEqual([])
})

test("the box's own refusals stand after the card empties: an agent running, a merge not confirmed and an unanswered review each still refuse the call (#3864)", withAll, async ($, on) => {
  const { w, cards } = world(on, { stepsEmptied: EMPTIED, agents: [{ id: 'a1', status: 'running', description: 'Fix issue 1702' }] })
  await start($)
  await says($, 'Run the one off test and tell the team')
  await turnEnds($)
  expect((await box($, ASKED)).deny).toMatch(/^No box yet: .*Fix issue 1702/)
  w.agents = []
  w.verdicts = { 'danwright32/claude-config#1700': { state: 'deploying', at: NOW } }
  await turnEnds($)
  expect((await box($, ASKED)).deny).toMatch(/still deploying/)
  w.verdicts = {}
  await turnEnds($)
  w.review = reviewSays('handed')
  expect((await box($, ASKED)).deny).toMatch(/the end of turn review was handed to you this turn and is not on record as answered/)
  expect(await cards()).toEqual([])
})

// The prompt says every step on the card has been recorded, so the card is read when it is sent.
const OPEN_CARD = { heading: 'Next', steps: [{ title: 'Paste the token', url: 'https://a.example' }] }

test('a card with an open step pinned since the last one emptied: nothing is asked while a step is open, and it is asked once none is (#3864)', withAll, async ($, on) => {
  const { w, submitted, runs } = world(on, { stepsEmptied: EMPTIED, stepsCard: OPEN_CARD, links: [link('danwright32/claude-config', 1700)] })
  await start($)
  await says($, 'Run the one off test and tell the team')
  await turnEnds($)
  await turnEnds($)
  expect(cardAsks(submitted)).toEqual([])
  // An open step is read before what is in flight, so a record that waits on one asks GitHub nothing.
  expect(runs().filter(a => a[0] === 'gh')).toEqual([])
  // A step finished and others still open is still a card with an open step.
  w.stepsCard = { heading: 'Next', steps: [{ title: 'Add the key', url: 'https://b.example', finished: 'checked' }, ...OPEN_CARD.steps] }
  await turnEnds($)
  expect(cardAsks(submitted)).toEqual([])
  w.stepsCard = { heading: 'Next', steps: [{ title: 'Add the key', url: 'https://b.example', finished: 'checked' }, { ...OPEN_CARD.steps[0], finished: 'withdrawn' }] }
  await turnEnds($)
  await turnEnds($)
  expect(cardAsks(submitted)).toHaveLength(1)
})

test('a steps card that cannot be read: nothing is asked and the debug log says why, and it is asked once the card reads as gone (#3864)', withAll, async ($, on) => {
  const { w, submitted, logs } = world(on, { stepsEmptied: EMPTIED, stepsCard: { steps: 'x' } })
  await start($)
  await says($, 'Run the one off test and tell the team')
  await turnEnds($)
  w.stepsCard = 'a card'
  await turnEnds($)
  expect(cardAsks(submitted)).toEqual([])
  expect(logs.filter(l => /the manual steps card could not be read \(it is not a card\), so whether a step on it is still open is not known and the session is not asked about the Goal accomplished box/.test(l))).toHaveLength(2)
  w.stepsCard = null
  await turnEnds($)
  expect(cardAsks(submitted)).toHaveLength(1)
})

test("one prompt a turn end: the message after a refused call that could not be sent is not followed by the card's prompt, and stands in for it once it is sent (#3864, #3843)", withAll, async ($, on) => {
  const { w, submitted, logs } = world(on, { submitFails: ['drop'] })
  await start($)
  await says($, 'Run the one off test and tell the team')
  await edits(w, $)
  expect((await box($, ASKED)).deny).toMatch(/its end of turn review is still to come/)
  w.stepsEmptied = EMPTIED
  await turnEnds($)
  expect(submitted.filter(s => s.text.startsWith(ASKS_AGAIN))).toEqual([])
  expect(cardAsks(submitted)).toEqual([])
  expect(logs.filter(l => /could not be asked to call the Goal accomplished box again/.test(l))).toHaveLength(1)
  await turnStarts($, 't2')
  await turnEnds($)
  expect(submitted.filter(s => s.text.startsWith(ASKS_AGAIN))).toHaveLength(1)
  expect(cardAsks(submitted)).toEqual([])
  await turnStarts($, 't3')
  await turnEnds($)
  expect(cardAsks(submitted)).toEqual([])
})

test("the same once a met /goal's box has been shown: the message that could not be sent is not followed by the card's prompt (#3864, #3843)", withAll, async ($, on) => {
  const { w, submitted } = world(on, { goal: MET })
  await start($)
  await says($, 'Finish issue 1563')
  expect((await box($, ASKED)).deny).toBeUndefined()
  await says($, 'Now run the one off test')
  await edits(w, $)
  expect((await box($, ASKED, 'b2')).deny).toMatch(/its end of turn review is still to come/)
  w.stepsEmptied = EMPTIED
  w.submitFails = ['drop']
  await turnEnds($)
  expect(submitted.filter(s => s.text.startsWith(ASKS_AGAIN))).toEqual([])
  expect(cardAsks(submitted)).toEqual([])
  await turnStarts($, 't2')
  await turnEnds($)
  expect(submitted.filter(s => s.text.startsWith(ASKS_AGAIN))).toHaveLength(1)
  expect(cardAsks(submitted)).toEqual([])
})

// A record that waits is asked about only under the request it emptied under.
const PR_OPEN = { links: [link('danwright32/claude-config', 1700)], open: { 'danwright32/claude-config': { exitCode: 0, stdout: '[{"number":1700}]' } } }

test("a record that waited behind an open pull request is not asked about under Dan's next message, then or later (#3864)", withAll, async ($, on) => {
  const { w, submitted, logs, clock } = world(on, { stepsEmptied: EMPTIED, ...PR_OPEN })
  await start($)
  await says($, 'Run the one off test and tell the team')
  await turnEnds($)
  expect(cardAsks(submitted)).toEqual([])
  await clock.advance(EMPTIED.at - NOW + 1)
  await says($, 'Now make the status bar quieter')
  w.open = {}
  await turnEnds($)
  await turnEnds($)
  expect(cardAsks(submitted)).toEqual([])
  expect(logs.filter(l => /the steps card emptied before Dan's latest message, so the session is not asked about the Goal accomplished box/.test(l))).toHaveLength(1)
})

test('a card that emptied in the very millisecond of his message is asked about (#3864)', withAll, async ($, on) => {
  const { submitted } = world(on, { stepsEmptied: { at: NOW, done: 1 } })
  await start($)
  await says($, 'Run the one off test and tell the team')
  await turnEnds($)
  expect(cardAsks(submitted)).toHaveLength(1)
})

for (const [when, at] of [['before', NOW + 1_000], ['in the very millisecond of', NOW + 5_000]] as const)
  test(`a card that emptied ${when} the last box shown is not asked about under work Dan then picks in a picker (#3864, #3843)`, withAll, async ($, on) => {
    const { w, submitted, logs, clock } = reviewed(on, { stepsEmptied: { at, done: 2 } })
    await start($)
    await says($, 'Run the one off test and tell the team')
    await clock.advance(5_000)
    expect((await box($, ASKED, 'b1')).deny).toBeUndefined()
    await picks(w, $, 'q1')
    await does(w, $, 'Edit', 'e1', { file_path: '/repo/a.ts' })
    await turnEnds($)
    await turnEnds($)
    expect(cardAsks(submitted)).toEqual([])
    expect(logs.filter(l => /a Goal accomplished box was shown after the steps card emptied, so the session is not asked about the Goal accomplished box/.test(l))).toHaveLength(1)
  })

test('a card that emptied after the last box shown is asked about under work Dan picked in a picker (#3864, #3843)', withAll, async ($, on) => {
  const { w, submitted, clock } = reviewed(on)
  await start($)
  await says($, 'Run the one off test and tell the team')
  await clock.advance(5_000)
  expect((await box($, ASKED, 'b1')).deny).toBeUndefined()
  await picks(w, $, 'q1')
  await does(w, $, 'Edit', 'e1', { file_path: '/repo/a.ts' })
  w.stepsEmptied = { at: NOW + 5_001, done: 1 }
  await turnEnds($)
  expect(cardAsks(submitted)).toHaveLength(1)
})
