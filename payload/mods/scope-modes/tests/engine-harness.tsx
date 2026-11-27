// The engine test harness of scope-modes (#3446): the Mac, GitHub and the person beneath the mod
// (world), the mods it depends on standing in, and the calls a test drives it with (start, command,
// say, bash, call). It lived inside register.test.tsx, exported nothing, and so every new engine test
// had to be added to that one file. Any test file in this folder can import it now; each file that
// makes a world calls closingChecks() as its last line, so the waits and questions of every world
// it made are judged by the same two checks register.test.tsx has always ended with. The runner
// gives each test file a process of its own, so a file's worlds are never seen by another file's
// checks.
import { expect, mock } from 'claude-code/testing'
import { never, test } from './mod-kit/tests/hang-ceiling.ts'
import type { On, Register } from 'claude-code'
import type {} from '../types/index.d.ts'
import { git, pipeline, type Command } from './mod-kit/hooks/commands.ts'
import { commandWrites } from './mod-kit/hooks/writes.ts'
import { GOAL_MARK, goalAt } from './mod-kit/hooks/goal.ts'
import { ghArgs, mergeHelperArgs } from './mod-kit/hooks/gh.ts'
import { ghRepo, githubRepo, linkRepo, repoName } from './mod-kit/hooks/repo.ts'
import { branchAt } from './mod-kit/hooks/branch.ts'
import { isDans } from './mod-kit/hooks/origin.ts'
import { isOwnDialog } from '../hooks/mod-kit/asked.ts'

// The three mods this one depends on, standing in (a mod cannot import another mod's files):
// mod-kit's band, card and send retry, the status bar's setModes, and the session registry's list.
// One plugin named mod-kit, so a band button it draws is pressed as mod-kit's. Each call it is
// handed comes back to the world as a transcript line the world reads (BAND, CLEAR, CARD, MODES);
// the registry asks the world for the sessions with a process.run. mod-kit's readers are its own:
// the stand-in asks the world (`__modkit`), which reads with a byte for byte copy of mod-kit's
// reader under tests/mod-kit, held to mod-kit's by tools/check-mod-shared-parts.sh, so a quoted
// separator is read as it is in a session (#730: the stand-in reader split inside quotes).
export type Part = { text?: string; color?: string; button?: string; label?: string }
export type Line = Part[] | { divider: true }
export type Row = { mod: string; id: string; slot: string; frame?: { kind: string }; lines: Line[] }
export const deps: { name: string; register: Register } = {
  name: 'mod-kit',
  register: on => {
    // mod-kit's retry of a mod's refused send (its hooks/send.ts), standing in: once more when
    // refused, never after a throw, the reason tidied. mod-kit's own tests prove the real one.
    on('session.send', async ($, e, next) => {
      let why = ''
      for (let attempt = 0; attempt < 2; attempt++) {
        try {
          const sent = await next(e)
          if (sent.isDelivered) return sent
          why = sent.reason
        } catch (err) {
          why = String((err as Error)?.message ?? err)
          break
        }
      }
      return { isDelivered: false, reason: why.trim().replace(/\.$/, '') || 'no reason given' }
    })
    // #3321: standing where picker manners does, another mod's hook on every question: it reads
    // scope modes' own state and hands that and the call it got to the world, which judges whether
    // the mod had kept that very dialog as its own. A world that answers no such run changes nothing.
    on('tool.call', { tool: 'AskUserQuestion' }, async ($, e, next) => {
      try {
        const value = (await $.state.get({ plugin: 'scope-modes', key: 'asking' })).value
        await $.process.run(['__own', JSON.stringify({ value: value ?? null, call: e })])
      } catch {
        // No world beneath, or one that refuses the run: the question goes on as it would.
      }
      return next(e)
    })
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      const rows = async () => (((await built.state.get({ plugin: 'mod-kit', key: 'band' })) as { value?: Row[] }).value ?? [])
      // mod-kit's own readers, asked of the world, which reads with mod-kit's copy.
      const kit = async (method: string, input: unknown) => {
        const r = await built.process.run(['__modkit', method, JSON.stringify(input)])
        if (r.exitCode !== 0) throw new Error(r.stderr)
        return r.stdout === '' ? undefined : JSON.parse(r.stdout)
      }
      const modkit = {
          blocked: async (b: unknown) => built.ui.log('CARD ' + JSON.stringify(b)),
          pipeline: async (input: { command: string }) => kit('pipeline', input),
          writes: async (input: { command: string; cwd: string; home: string }) => kit('writes', input),
          git: async (input: { words: string[] }) => kit('git', input),
          gh: async (input: { words: string[] }) => kit('gh', input),
          mergeHelper: async (command: Command) => kit('mergeHelper', command),
          goal: async (input: { transcript: string }) => kit('goal', input),
          repo: async (input: { root?: string | null; remote: string | null }) => kit('repo', input),
          ghRepo: async (input: { spelling: string }) => kit('ghRepo', input),
          linkRepo: async (input: { link: string }) => kit('linkRepo', input),
          bandRow: async (row: Row) => {
            built.ui.log('BAND ' + JSON.stringify(row))
            await built.state.set({ plugin: 'mod-kit', key: 'band' }, [...(await rows()).filter(r => !(r.mod === row.mod && r.id === row.id)), row] as never)
          },
          clearBandRow: async ({ mod, id }: { mod: string; id: string }) => {
            built.ui.log('CLEAR ' + id)
            await built.state.set({ plugin: 'mod-kit', key: 'band' }, (await rows()).filter(r => !(r.mod === mod && r.id === id)) as never)
          },
          // The screen (#707): refuses a call carrying SCREEN-REFUSES, as the secret guard refuses a
          // token; mod-kit's own tests prove the real one asks the secret guard.
          screen: async (call: unknown) => (JSON.stringify(call).includes('SCREEN-REFUSES') ? { deny: 'Blocked: this message contains a secret. Refer to it by its name, not its value.' } : null),
          // #939: a press raised by the kit's Button below, and whether a click lands; every Button here is clickable.
          press: async () => ({ isAnswered: false }),
          clickable: async () => true,
          // The kit's other members, which these tests never reach: each refuses by name if one ever is.
          card: async () => { throw new Error("mod-kit's card is not stood in by these tests") },
          commands: async () => { throw new Error("mod-kit's commands is not stood in by these tests") },
          workingTree: async (input: { path: string }) => (await kit('workingTree', input)) ?? null,
          branch: async (input: { path: string }) => (await kit('branch', input)) ?? null,
          pane: async () => { throw new Error("mod-kit's pane is not stood in by these tests") },
          clearPane: async () => { throw new Error("mod-kit's clearPane is not stood in by these tests") },
          // #1135: whether a prompt is Dan's words, read by the world with mod-kit's own copy.
          isDans: async (input: { origin: unknown }) => {
            // A mod-kit loaded before it had the reader (a reload can leave one, standing rule 5).
            if ((input as { origin?: { breaks?: true } }).origin?.breaks) throw new TypeError('$.modkit.isDans is not a function')
            return kit('isDans', input)
          },
          typedAnswer: async () => { throw new Error("mod-kit's typedAnswer is not stood in by these tests") },
          // #2132: a hold on scope-modes' reload and its letting go, asked of the world, which keeps
          // them in order beside each prompt and question and can refuse one as mod-kit would.
          hold: async (input: unknown) => {
            await kit('hold', input)
          },
          release: async (input: unknown) => {
            await kit('release', input)
          },
          pythonText: async () => { throw new Error("mod-kit's pythonText is not stood in by these tests") },
          login: async () => { throw new Error("mod-kit's login is not stood in by these tests") },
          account: async () => { throw new Error("mod-kit's account is not stood in by these tests") },
      }
      // A mod-kit loaded before it had these members (#1281): a mod reloaded before the mod-kit it
      // depends on keeps the older one, so each is not there at all, as in a session. Named by a
      // plugin in the fold, kit-lacks-<member in kebab case>, since this plugin runs apart from the test's module.
      for (const p of e.plugins) {
        const lacks = /^kit-lacks-([a-z-]+)$/.exec(p)?.[1]?.replace(/-([a-z])/g, (_m: string, c: string) => c.toUpperCase())
        if (lacks) delete (modkit as Record<string, unknown>)[lacks]
      }
      return {
        ...built,
        modkit,
        statusbar: {
          setModes: async ({ modes }: { modes: string[] }) => built.ui.log('MODES ' + JSON.stringify(modes)),
          setMode: async () => undefined,
        },
        sessions: {
          list: async () => {
            const r = await built.process.run(['__sessions'])
            if (r.exitCode !== 0) throw new Error(r.stderr)
            return JSON.parse(r.stdout)
          },
          noteEdit: async () => undefined,
          setExtra: async () => undefined,
        },
      }
    })
    // The band as mod-kit draws it, enough to press a button by its key.
    on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
      const rows = ((await $.state.get({ plugin: 'mod-kit', key: 'band' })) as { value?: Row[] }).value ?? []
      if (!rows.length) return next(e)
      const { Box, Button, Text } = $.ui.resolve(e)
      return (
        <Box flexDirection="column">
          {rows.flatMap(r =>
            r.lines.map((l, n) =>
              Array.isArray(l) ? (
                <Box key={`${r.id}${n}`} flexDirection="row">
                  {l.map((p, i) => (p.button ? <Button key={`${r.mod}:${p.button}`} label={p.label as string} onPress={press => void $.modkit.press({ element: press.element, surface: String(press.surface), how: 'click' })} /> : <Text key={String(i)}>{p.text}</Text>))}
                </Box>
              ) : (
                <Text key={`${r.id}${n}`}>----</Text>
              ),
            ),
          )}
        </Box>
      )
    })
  },
}
// is it live's verdict, standing in as its own plugin so a test can leave it out: asked of the
// world as a process.run (__verdict).
export const isItLive: { name: string; register: Register } = {
  name: 'is-it-live',
  register: on => {
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      return {
        ...built,
        isItLive: {
          verdict: async ({ repo, pr }: { repo: string; pr: number }) => {
            const r = await built.process.run(['__verdict', repo, String(pr)])
            if (r.exitCode !== 0) throw new Error(r.stderr)
            return JSON.parse(r.stdout)
          },
        },
      }
    })
  },
}
export const withDeps = { plugins: [deps, isItLive] }
// #1281: the same, with a mod-kit loaded before it had mergeHelper.
export const withOldKit = { plugins: [deps, isItLive, { name: 'kit-lacks-merge-helper', register: (() => undefined) as Register }] }
export const withoutIsItLive = { plugins: [deps] }
// The manual steps mod's noun (#1107), standing in as its own plugin: each call is logged (STEPS add,
// STEPS finish) and answered as shown and finished; left out, it stands for the mod not being loaded.
// The manual steps mod's own tests prove the real card.
const stepsNoun: { name: string; register: Register } = {
  name: 'manual-steps',
  register: on => {
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      return {
        ...built,
        manualSteps: {
          add: async (x: unknown) => {
            built.ui.log('STEPS add ' + JSON.stringify(x))
            return { isShown: true }
          },
          // Fails while the world holds /Users/<name>/finish-fails, as a card that cannot be written would.
          finish: async (x: unknown) => {
            built.ui.log('STEPS finish ' + JSON.stringify(x))
            if (await built.fs.exists(`${'/Users'}/x/finish-fails`)) throw new Error('the steps card changed under every one of 10 attempts to update it')
            return { isFinished: true }
          },
        },
      }
    })
  },
}
export const withSteps = { plugins: [deps, isItLive, stepsNoun] }
// The job watcher's noun (#2511), standing in as its own plugin: its job list and its quiet agents,
// asked of the world as process.runs (__jobs, __quiet); left out, it stands for the watcher not loaded.
const jobsNoun: { name: string; register: Register } = {
  name: 'job-watcher',
  register: on => {
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      const ask = async (what: string) => {
        const r = await built.process.run([what])
        if (r.exitCode !== 0) throw new Error(r.stderr)
        return JSON.parse(r.stdout)
      }
      return { ...built, jobs: { list: () => ask('__jobs'), agents: () => ask('__quiet') } }
    })
  },
}
export const withJobs = { plugins: [deps, isItLive, jobsNoun] }
export const keptJob = (o: Record<string, unknown> = {}) => ({ id: 'b1', label: 'wait for the push', runMs: 60_000, kept: true, stuck: false, state: 'running', owner: null, ownerId: null, stall: null, quietMs: null, ...o })

export const MIN = 60_000
export const T0 = 1_000_000
export const BOOT = 1759800000
export const SESSION = '11111111-2222-3333-4444-555555555555'
export const SCRATCH = '/private/tmp/claude-501/-Users-x-proj/s1/scratchpad'
export const AWAY_TEXT = 'Dan switched every session on this Mac to away.'
export const PHONE_LINE = "You're on your phone. Reply away to switch every session."

// The machine wide sleep record (#840), which most nights begin from.
export const SLEEP = `${'/Users'}/x/.claude/state/sleep`
export const CURRENT = `${SLEEP}/current.json`
// T0 is 7:16 PM ET on Wed Dec 31 1969, so the night is Dec 31 and sleep ends at noon ET on Jan 1,
// 17:00 UTC (EST).
export const UNTIL = Date.UTC(1970, 0, 1, 17)
export const asleepRecord = (extra: Record<string, unknown> = {}) =>
  JSON.stringify({ v: 1, generation: 'g0', since: T0 - 5 * MIN, until: UNTIL, night: '1969-12-31', bootTime: BOOT, report: `${'/Users'}/x/Downloads/Sleep report 1969-12-31.md`, startedBy: { sessionId: 's9', cwd: '/other' }, workers: ['s9'], placeBefore: 'home', ...extra })
// A night asleep with these per repository merge and deploy lists (#843).
export const night = (repos: unknown) => ({ files: { [CURRENT]: asleepRecord({ repos }) } })

// gh's closingIssuesReferences entry: the repository is {id, name, owner: {id, login}} (#2065).
export type ClosingRefFixture = { id?: string; number: number; url?: string; repository?: { id?: string; name?: string; owner?: { id?: string; login?: string } } }
export type Session = { sessionId: string; repoRoot?: string; extra?: Record<string, unknown>; transcriptPath?: string | null; transcriptUnread?: string }
// The goal every session has set with /goal unless a test says otherwise (#1242).
export const DEFAULT_GOAL = 'Close #7'
// The one PR GitHub holds, found by `gh pr list --head` only for its own branch (scope-modes-616
// unless headRefName says otherwise) and by `gh pr view` only by its own number.
export type GhPr = {
  number: number
  state: string
  url?: string
  headRefName?: string
  headRefOid?: string
  closingIssuesReferences: ClosingRefFixture[]
  closedAt?: string
  comments?: { body: string; createdAt: string }[]
  /** The PR's description (#1812: the issues it refers to, and its stated next step). */
  body?: string
}
// `others` are PRs GitHub also holds, found only by `gh pr view` by number (#856). `notPrs` are
// numbers that are issues, which `gh pr view` refuses as GitHub does (#1767).
export type Gh = { pr: GhPr | null; others?: GhPr[]; issues: Record<number, string>; fails?: string; notPrs?: number[] }
export type Opts = {
  /** What a `gh pr create` call prints, as gh does: the new PR's link. */
  created?: string
  /** is it live's verdict for the PR asked about: a card's state, no card, or a read that throws. */
  verdict?: { state: string; at: number } | null | { throws: string }
  open?: Session[]
  unreadable?: string[]
  sends?: (true | { refused: string })[]
  branch?: string
  gh?: Gh
  branchHere?: boolean
  branchOnGitHub?: boolean
  worktrees?: string
  ask?: string
  /** The Mac's files beneath the sleep record (#840), by path; mv, ln and rm act on them. */
  files?: Record<string, string>
  /** This boot's start, as sysctl gives it; null when sysctl fails. */
  boot?: number | null
  /** This boot's session (kern.bootsessionuuid), as sysctl gives it; null when sysctl fails. */
  session?: string | null
  /** A move or link of the sleep record that fails for a reason other than the file being gone. */
  mvFails?: string
  lnFails?: string
  notifyFails?: boolean
  /** The night's notes file cannot be appended to (#841): the shell's own words. */
  noteFails?: string
  /** A new record written over the old one just before the first move of it: a sleep begun between a read and a move. */
  replacedBeforeMove?: string
  /** Each folder's origin remote (#843); /repo is o/r unless said. */
  origins?: Record<string, string>
  /** The repositories GitHub shows to the active account (`default`) and to each other account's token, by account. */
  githubRepos?: Record<string, string[]>
  /** Dan's bedtime answer, or none: the question waits until the test moves the clock. */
  repoAnswer?: string | null
  /** A sleep record another /sleep places the moment this one takes the preparing marker (#843). */
  recordOnMarker?: string
  /** Run once, the moment a /sleep links its preparing marker, before that link returns (#2582). */
  onPreparingLinked?: () => Promise<unknown>
  /** Dan's bedtime answer, given only when this settles (#843). */
  repoAnswerLate?: Promise<string>
  /** origin/HEAD's branch, main unless said (#843). */
  defaultBranch?: string
  /** gh repo view under another account's token fails for a reason other than not found (#843). */
  ghRepoViewFailsWithToken?: string
  /** gh repo view fails for a reason other than the repository being unknown (#843): its stderr. */
  ghRepoViewFails?: string
  /** The session registry answers with no lists at all (#843). */
  registryGarbled?: boolean
  /** The branch checked out in each folder other than /repo (#843). */
  branches?: Record<string, string>
  /** A link of the preparing marker or the answers lock that fails (#843). */
  markerFails?: string
  /** The report script (#835) failing, by what it was asked to do (start, note, render), with its stderr. */
  reportFails?: Record<string, string>
  /** HOME stops reading once a note is written, so the final render's own setup throws. */
  homeGoneAfterNote?: boolean
  /** The session's GH_REPO, unset by default (#961). */
  ghRepoEnv?: string
  /** What this session's usage reads, or a read that throws. */
  usage?: { cost?: { usd: number }; rateLimits: { kind: string; percentUsed: number; resetsAt?: string }[] } | { throws: string }
  /** /repo is a linked worktree rather than a primary checkout (#834). */
  linkedWorktree?: boolean
  /**
   * The wake check's reads (#834), each command line's own answer: its output, or a failure. The
   * installed LESSONS.md is read through $.fs.stat (#2016), answered under `mtime <path>` in
   * milliseconds, or the failure $.fs.stat rejects with.
   */
  night?: Record<string, string | { fails: string }>
  /** How long each of the wake check's GitHub reads takes on the engine's clock, never the real one (#1147). */
  nightReadMs?: number
  /** What the permission step beneath answers a permission request with (#834). */
  beneathDecision?: { behavior: 'deny'; message: string }
  /** Whether the step beneath a classifier refusal asks for a retry (#834). */
  beneathRetries?: boolean
  /** What `sleep-queue.sh claims` prints (#844): one JSON line per issue claimed tonight. */
  claims?: string
  /** What `sleep-queue.sh work` prints for each issue, its branch tip and its worktree's checkout (#844, #1119). */
  work?: Record<number, string>
  /** What pmset says this Mac is drawing power from (#844), or how it fails (#1545). */
  power?: 'ac' | 'battery' | { fails: string }
  /** Another session records the next power change, with this source, just before this one's ln of it (#1545). */
  powerRacedBy?: string
  caffeinateFails?: boolean
  /** The session is in no repository (#844). */
  noRepo?: boolean
  /** The session's origin as $.session.repo() gives it (#951); by default git@github.com:o/r.git. */
  remote?: string | null
  /** mod-kit's walk for the checkout a folder sits in fails (#996), with what it threw. */
  workingTreeFails?: string
  /**
   * The checkout a path under each prefix sits in, for mod-kit's walk (#1269): null for none. A path
   * under no prefix here is its own checkout, as before.
   */
  trees?: Record<string, string | null>
  /** The folders git status finds uncommitted changes in (#996); none by default. */
  dirty?: string[]
  /** The files git status names in those folders (#1051); app.ts unless said. */
  dirtyFiles?: string[]
  /** What `git stash show --name-only` names in the newest stash (#1123), or how it fails; none by default. */
  stash?: string[] | { fails: string }
  /** Files that are there but cannot be read (#1123 lessons review). */
  unreadableFiles?: string[]
  /**
   * Paths that are there and are no regular file (a fifo, a link to a device, #1765). A read of one,
   * or of any device, never answers, as the real one does, and resolves the world's readAttempted.
   */
  fifos?: string[]
  /** A `git switch -c` or `git checkout -b` that runs but leaves the checkout where it was (#1051). */
  switchFails?: boolean
  /** mod-kit's branch reader fails (#980), with what it threw. */
  branchReaderFails?: string
  /** The session's folder, /repo unless said: a linked worktree of /repo, whose main working tree stays /repo (#980 review). */
  cwd?: string
  /** mod-kit's repo reader fails (#979 review). */
  repoReaderFails?: boolean
  /** mod-kit's readers of a repository gh spells and of a github.com link fail (#961). */
  ghRepoReaderFails?: boolean
  linkReaderFails?: boolean
  /** mod-kit's reader of the merge helper fails (#1251). */
  mergeHelperReaderFails?: boolean
  /** mod-kit's git reader is a copy loaded before it said which repository a command names (#3398). */
  oldGitReader?: boolean
  /** `touch` failing, with its stderr (#1281: the driver touches this mod's manifest to load it again). */
  touchFails?: string
  /** mod-kit's reader of a transcript's /goal fails (#1252). */
  goalReaderFails?: boolean
  /** What the session registry's list says of this session (s1) beyond its id (#1636). */
  selfSession?: Omit<Session, 'sessionId'>
  /** mod-kit's link reader fails only for a link holding this text (#961). */
  linkReaderFailsOn?: string
  /** What `ps -o args=` says the recorded process is now (#844): by default the hold /sleep started. */
  psArgs?: string
  /**
   * What `pgrep -lf merge-when-ready` prints (#2901): one line per process on this Mac running the
   * merge helper, its pid and its words. None running unless said (pgrep's exit 1); `{ fails }` is
   * pgrep failing some other way.
   */
  helpers?: string | { fails: string }
  /** Held until the test lets it go: the next `sleep-queue.sh claims` waits on it (#844, a Stop and a failure at once). */
  claimsGate?: Promise<void>
  /** Which writes of the driver's counter fail, counted from 1 (#844). */
  driverWriteFails?: number[]
  /** Dan's answer to each before bed question about an issue (#836), by the question as the dialog shows it: null never answers, a promise answers when it settles, '__dismissed' throws. */
  issueAnswers?: Record<string, string | null | Promise<string>>
  /** Each issue's labels as gh reads them (#836). */
  issueLabels?: Record<number, string[]>
  /** Each issue's body as gh issue view gives it (#1279: its Open questions section), by number. */
  issueBodies?: Record<number, string>
  /** Numbers that are pull requests, which gh issue view answers for too, with a pull link (#1279). */
  pullNumbers?: number[]
  /** gh issue edit failing, with its stderr (#1279: checking an answered question off). */
  editFails?: string
  /** This session's background agents as Claude Code lists them (#2511): none unless said, or a list that cannot be read. */
  agents?: { id: string; status: string }[] | { throws: string }
  /** The job watcher's job list (#2511), none unless said, or a list it refuses. */
  jobs?: Record<string, unknown>[] | { throws: string }
  /** The running agents the job watcher judged quiet past twenty minutes (#2511), none unless said, or a refusal. */
  quiet?: { name: string; quietMs: number }[] | { throws: string }
  /** gh issue view failing, with its stderr (#836). */
  issueViewFails?: string
  /** gh issue view failing for one issue, with its stderr, by number (#2585). */
  issueViewFailsOn?: Record<number, string>
  /** Each issue's comments as gh issue view gives them, oldest first, by number (#1812). */
  issueComments?: Record<number, string[]>
  /** gh issue comment failing on an issue, with its stderr (#836). */
  commentFails?: Record<number, string>
  /** ls of a folder failing for a reason other than the folder being absent (#836). */
  lsFails?: string
  /** Reading this session's folder throws (#836: after the unanswered list is written). */
  cwdThrows?: boolean
  /** The folder read throws once a sleep record is in place, so /sleep itself can start (#3136). */
  cwdThrowsAsleep?: boolean
  /** The session registry's answer as raw text, in place of the usual one (#837). */
  registryAnswer?: string
  /** The next prompts beneath the mod that fail, counted (#837: a prompt that never entered). */
  promptFails?: number
  /** #2132: mod-kit refuses the hold on scope-modes' reload with this, as an older or missing mod-kit would. */
  holdFails?: string
  /** Opening the report in BBEdit failing (#837): the helper's words, and open -a BBEdit's. */
  openFails?: { helper?: string; open?: string }
  /** `sleep-queue.sh release` refusing, with what it printed (#922: its answer can quote a worker's why). */
  releaseFails?: string
  /**
   * Folders removed from the disk (#1059): a process started in one fails to start, naming the
   * command as the real spawn does, and git -C one cannot change to it. Every other checkout
   * folder (/repo and the session's own) is there.
   */
  gone?: string[]
  /** A folder that is still there when looked for, and removed the moment a process is started in it (#1059). */
  vanishOnSpawn?: string
  /** A tool call naming this text is refused by a guard beneath the mod (#1108). */
  refusedBeneath?: string
  /** Each session's /goal as its transcript records it (#1242), by session id: null for none, or a read that fails; DEFAULT_GOAL unless said. */
  goals?: Record<string, string | null | { fails: string }>
  /** A hook beneath blocks every Stop, as Claude Code's /goal hook does while its condition does not hold (#1242). */
  goalHookBlocks?: boolean
  /** The issues milestone-candidates.sh finds a proposal already is (#1389), by the title asked about: its CLOSE-MATCH. */
  filedOnGitHub?: Record<string, { number: number; closed?: boolean }>
  /** milestone-candidates.sh unable to read GitHub (#1389): its stderr, with exit 6. */
  dupCheckFails?: string
  /** What a `gh issue create` call prints, as gh does: the new issue's link (#1389). */
  issueCreated?: string
  /** The engine's clock at the start, in ms; T0 unless said (#1479). */
  now?: number
  /**
   * The polling policy's answers (hooks/lib/gh-poll.sh, #1482), as its command prints them: a look
   * held (`take`, a `wait` line) and what a failed read's error is to it (`failed`). Every look is
   * taken and every failure is `other` unless said; `next` answers as the library does, the wait
   * doubled up to the caller's ceiling, or its base on a change (hooks/test-gh-poll.sh holds the
   * library to that). `budget` is the session's looks for each clock minute (#2433): past it, a look
   * is held for the rest of that minute, as the library's cap holds it.
   */
  poll?: { take?: string; failed?: string; budget?: number }
  /**
   * The command abandoned (#1677): from the first process.run whose words hold this text, the engine
   * refuses every process and file call, as Claude Code does once a command is interrupted or its
   * question dismissed, with its own words ("$.process.run(mkdir) aborted").
   */
  refuseFrom?: string
  /** Paths whether a file is at cannot be checked (#1678): fs.exists fails for each. */
  existsFails?: string[]
  /** Folders whose listing fails (#1725). */
  listFails?: string[]
  /**
   * The project's CLAUDE.md as git show reads it from the default branch (#2064): by ref, origin/HEAD
   * and origin/main, one not given failing as git does for a ref carrying no CLAUDE.md. Neither
   * given is a repository whose default branch carries no CLAUDE.md.
   */
  committedClaudeMd?: { head?: string; main?: string }
  /** git show's error when the committed CLAUDE.md cannot be read at all (#2146). */
  committedClaudeMdUnreadable?: string
}

export const ok = (stdout = '') => ({ value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } })
export const fail = (exitCode: number, stderr = '') => ({ value: { exitCode, stdout: '', stderr, isStdoutTruncated: false, isStderrTruncated: false } })

// The Mac, GitHub and the person beneath the mod. Everything that gets past the mod is recorded.
export const world = (on: On, o: Opts = {}) => {
  if (!closing.registered) throw new Error('this file makes a world but never calls closingChecks() from engine-harness.tsx, so no check reads the waits and questions of its worlds: call it as the last line of the file')
  if (closing.ran) throw new Error('a world was made after this file\'s closing checks ran, so they never read it: call closingChecks() as the last line of the file')
  let attempted: () => void = () => undefined
  const readAttempted = new Promise<'read attempted'>(resolve => {
    attempted = () => resolve('read attempted')
  })
  const w = {
    o,
    reached: [] as string[],
    cards: [] as Record<string, unknown>[],
    bands: [] as Row[],
    cleared: [] as string[],
    modes: [] as string[][],
    toasts: [] as string[],
    sent: [] as { to: unknown; text: string }[],
    prompts: [] as string[],
    runs: [] as string[][],
    /** Each time the wake check dated the installed LESSONS.md through $.fs.stat (#2016). */
    lessonsStats: 0,
    /** Every mv, ln and rm, in order, as the Mac saw them (#843). */
    fileOps: [] as string[][],
    asked: [] as string[],
    /** The timeout each read of an issue's state was given, in order (#2585: /sleep reads while Dan waits). */
    issueViewTimeouts: [] as (number | undefined)[],
    /** The choices each question offered, in the order asked (#836). */
    askedOptions: [] as string[][],
    /** Every comment posted on an issue (#836). */
    comments: [] as { repo: string; issue: string; body: string }[],
    edits: [] as { repo: string; issue: number; body: string }[],
    tools: [] as string[],
    logs: [] as string[],
    files: { ...o.files } as Record<string, string>,
    fsWrites: [] as string[],
    notified: [] as string[],
    appended: [] as { file: string; line: string }[],
    reports: [] as { op: string; record: string; final?: boolean }[],
    homeGone: false,
    /** What reached the screen and GitHub, in order: each modes change, and the wake check's first read (#834). */
    order: [] as string[],
    /** #2132: each hold on scope-modes' reload, its letting go, each prompt and each question the mod asks, in order. */
    held: [] as string[],
    /** #2132: the holds standing now, by id. */
    holding: new Set<string>(),
    /** #2132: each prompt or question the mod made with no hold standing, which a reload would drop. */
    unheld: [] as string[],
    /** #3321: how many questions the mod asked itself, and each one asked while its own state did not hold that very dialog. */
    ownAsks: 0,
    unowned: [] as string[],
    /** Reading this session's id throws from now on (#834: a permission decision that throws). */
    idThrows: false,
    released: [] as string[][],
    releasedBy: [] as string[],
    workAsked: [] as string[],
    caffeinated: [] as string[],
    killed: [] as string[],
    /** How many times pmset was asked what the Mac draws from (#1545). */
    powerReads: 0,
    /** Every opening of a file in BBEdit that succeeded, as run (#837). */
    opened: [] as string[][],
    /** Every transcript whose goal was read (#1242). */
    goalReads: [] as string[],
    /** How many Stops reached the hooks beneath the mod (#1242). */
    beneathStops: 0,
    /** Every run of milestone-candidates.sh, its arguments after the script (#1389). */
    dupChecks: [] as string[][],
    /** Every slash command the mod registered, with the description the menu shows (#1479). */
    commands: [] as { name: string; description: string }[],
    /** Every call of the polling policy, gh-poll.sh, with the environment it was given (#1482). */
    polls: [] as { argv: string[]; env?: Record<string, string> }[],
    /** Whether the engine is refusing every call, once `refuseFrom` was met (#1677). */
    refusing: false,
    /** Each device or fifo a hook opened (#1765), which should stay empty. */
    devicesOpened: [] as string[],
    /** Every pgrep the mod ran, its arguments (#2901). */
    pgreps: [] as string[][],
  }
  // The engine's refusal, which reaches the mod as the call failing with these words.
  const refused = (call: string) => ({ deny: `$.${call} aborted` }) as never
  const clock = mock.clock(on, { now: o.now ?? T0 })
  // HOME, gone once `homeGoneAfterNote` has seen a note written: the only way left for the final render to throw.
  on('env.get', ($, e) => {
    const name = (e as unknown as { name: string }).name
    return { value: name === 'HOME' && !w.homeGone ? `${'/Users'}/x` : name === 'GH_REPO' ? w.o.ghRepoEnv : undefined } as never
  })
  // The Mac's files, in memory, for the sleep record (#840). Every move and link is one step, as
  // rename and link are on the disk, so of two sessions moving one record exactly one succeeds.
  let driverWrites = 0
  on('fs.write', ($, e) => {
    if (w.refusing) return refused('fs.write')
    if (e.path.includes('/state/sleep/driver/') && o.driverWriteFails?.includes(++driverWrites)) throw new Error('EIO: i/o error, write')
    w.fsWrites.push(e.path)
    w.files[e.path] = e.text
    return { value: undefined }
  })
  const isOther = (path: string) => path.startsWith('/dev/') || (o.fifos ?? []).includes(path)
  on('fs.read', async ($, e) => {
    if (w.refusing) return refused('fs.read')
    if (isOther(e.path)) {
      w.devicesOpened.push(e.path)
      attempted()
      return { value: await never<string>() } as never
    }
    if (o.unreadableFiles?.includes(e.path)) return { deny: `EACCES: permission denied, open '${e.path}'` } as never
    if (!(e.path in w.files)) throw new Error(`ENOENT: no such file or directory, open '${e.path}'`)
    return { value: w.files[e.path] as string } as never
  })
  // A folder's entries, from the files a test put there (#1725: the long folder spelling is found by
  // listing ~/.claude/projects).
  on('fs.list', ($, e) => {
    if (w.refusing) return refused('fs.list')
    if (o.listFails?.includes(e.path)) return { deny: `EACCES: permission denied, scandir '${e.path}'` } as never
    const names = new Map<string, 'file' | 'dir'>()
    for (const f of Object.keys(w.files)) {
      if (!f.startsWith(`${e.path}/`)) continue
      const rest = f.slice(e.path.length + 1)
      const cut = rest.indexOf('/')
      names.set(cut < 0 ? rest : rest.slice(0, cut), cut < 0 ? 'file' : 'dir')
    }
    return { value: [...names].map(([name, kind]) => ({ name, kind, size: 0, mtimeMs: 0, isLink: false })) } as never
  })
  // A checkout folder (/repo, the session's own) is there unless a test removed it (#1059).
  const isGone = (dir: string) => (o.gone ?? []).includes(dir)
  const isCheckout = (dir: string) => dir === '/repo' || dir === (o.cwd ?? '/repo')
  on('fs.exists', ($, e) => w.refusing ? refused('fs.exists') : o.existsFails?.includes(e.path) ? ({ deny: `EACCES: permission denied, stat '${e.path}'` } as never) : ({ value: (isCheckout(e.path) && !isGone(e.path)) || isOther(e.path) || e.path in w.files || Object.keys(w.files).some(f => f.startsWith(`${e.path}/`)) }) as never)
  // What is at a path (#1765): a file the test put, a folder (a checkout, or one above a file), or
  // something else.
  on('fs.stat', ($, e) => {
    if (w.refusing) return refused('fs.stat')
    // The installed LESSONS.md the wake check dates (#2016): a quiet night's, changed long before.
    if (e.path === `${'/Users'}/x/.claude/LESSONS.md` && !(e.path in w.files)) {
      w.lessonsStats += 1
      const said = o.night?.[`mtime ${e.path}`]
      // A deny is how a test rejects the call: a hook that throws is skipped. The engine names the
      // call before the reason, as the real one does ("scope-modes: $.fs.stat(<path>) failed: ENOENT").
      if (said !== undefined && typeof said !== 'string') return { deny: said.fails } as never
      return { value: { kind: 'file', size: 1, mtimeMs: said === undefined ? 1000 : Number(said), isLink: false } } as never
    }
    if (isOther(e.path)) return { value: { kind: 'other', size: 0, mtimeMs: 0, isLink: false } } as never
    if (e.path in w.files) return { value: { kind: 'file', size: 1, mtimeMs: 0, isLink: false } } as never
    if ((isCheckout(e.path) && !isGone(e.path)) || Object.keys(w.files).some(f => f.startsWith(`${e.path}/`))) return { value: { kind: 'dir', size: 0, mtimeMs: 0, isLink: false } } as never
    throw new Error(`ENOENT: no such file or directory, stat '${e.path}'`)
  })
  // Each wake check read already moved on the engine's clock, so answering it moves it no further.
  const timed = new WeakSet<object>()
  on('process.run', function answer($, e) {
    const argv = [...e.argv]
    const [cmd, ...a] = argv
    if (o.refuseFrom && argv.join(' ').includes(o.refuseFrom)) w.refusing = true
    if (w.refusing) return refused(`process.run(${cmd})`)
    if (o.nightReadMs && cmd === 'gh' && (a[0] === 'api' || a[0] === 'search' || (a[0] === 'run' && a[1] === 'list')) && !timed.has(e)) {
      timed.add(e)
      return clock.advance(o.nightReadMs).then((): unknown => answer($, e)) as never
    }
    // A process started in a folder that is not there fails to start, and the error names the
    // command, not the folder (measured in #1059: spawn('gh', ..., { cwd: '/nonexistent' })).
    const at = e.init?.cwd
    if (at !== undefined && o.vanishOnSpawn === at) {
      o.gone = [...(o.gone ?? []), at]
      o.vanishOnSpawn = undefined
    }
    if (at !== undefined && isGone(at)) throw new Error(`ENOENT: no such file or directory, posix_spawn '${cmd}'`)
    if (cmd === 'git' && a[0] === '-C' && isGone(a[1] as string)) return fail(128, `fatal: cannot change to '${a[1]}': No such file or directory`)
    const ops = a.filter(x => !x.startsWith('-'))
    if (cmd === 'mv' || cmd === 'ln' || cmd === 'rm') w.fileOps.push(argv)
    if (cmd === 'sysctl' && ops[0] === 'kern.boottime') return o.boot === null ? fail(1, 'sysctl: unknown oid') : ok(`{ sec = ${o.boot ?? BOOT}, usec = 5 } Tue Oct  6 09:00:00 2026\n`)
    if (cmd === 'sysctl' && ops[0] === 'kern.bootsessionuuid') return o.session === null ? fail(1, 'sysctl: unknown oid') : ok(`${o.session ?? SESSION}\n`)
    if (cmd === 'mkdir') return ok()
    // The project's CLAUDE.md on its default branch (#2064), never the working copy's.
    if (cmd === 'git' && a[0] === '-C' && a[2] === 'show' && /^origin\/(?:HEAD|main):CLAUDE\.md$/.test(a[3] ?? '')) {
      // Recorded here because this answer returns before the general record of runs below.
      w.runs.push(argv)
      if (o.committedClaudeMdUnreadable !== undefined) return fail(128, o.committedClaudeMdUnreadable)
      const text = a[3]?.startsWith('origin/HEAD') ? o.committedClaudeMd?.head : o.committedClaudeMd?.main
      return text === undefined ? fail(128, `fatal: path 'CLAUDE.md' does not exist in '${a[3]?.split(':')[0]}'`) : ok(text)
    }
    // grep -o -E <pattern> <file> over the world's files (#1287: a session's title from its transcript).
    if (cmd === 'grep' && a[0] === '-o' && a[1] === '-E') {
      const file = a[3] as string
      if (!(file in w.files)) return fail(2, `grep: ${file}: No such file or directory`)
      const found = (w.files[file] as string).match(new RegExp(a[2] as string, 'g'))
      return found ? ok(`${found.join('\n')}\n`) : fail(1)
    }
    // A folder's names, from the files beneath it (#836).
    if (cmd === 'ls') {
      const dir = String(ops[ops.length - 1]).replace(/\/+$/, '')
      if (o.lsFails) return fail(1, `ls: ${dir}: ${o.lsFails}`)
      const names = [...new Set(Object.keys(w.files).filter(f => f.startsWith(`${dir}/`)).map(f => f.slice(dir.length + 1).split('/')[0] as string))].sort()
      return names.length ? ok(`${names.join('\n')}\n`) : fail(1, `ls: ${dir}: No such file or directory`)
    }
    if (cmd === 'mv') {
      const [from, to] = ops as [string, string]
      if (!(from in w.files)) return fail(1, `mv: rename ${from} to ${to}: No such file or directory`)
      if (o.mvFails) return fail(1, `mv: rename ${from} to ${to}: ${o.mvFails}`)
      if (o.replacedBeforeMove && from.endsWith('/current.json')) {
        w.files[from] = o.replacedBeforeMove
        o.replacedBeforeMove = undefined
      }
      if (a.includes('-n') && to in w.files) return ok()
      w.files[to] = w.files[from] as string
      delete w.files[from]
      return ok()
    }
    if (cmd === 'ln') {
      const [from, to] = ops as [string, string]
      if (o.lnFails && to.endsWith('/current.json')) return fail(1, `ln: ${to}: ${o.lnFails}`)
      if (o.markerFails && !to.endsWith('/current.json')) return fail(1, `ln: ${to}: ${o.markerFails}`)
      if (o.powerRacedBy && to.includes('/state/sleep/power/')) {
        w.files[to] = o.powerRacedBy
        o.powerRacedBy = undefined
      }
      if (to in w.files) return fail(1, `ln: ${to}: File exists`)
      if (!(from in w.files)) return fail(1, `ln: ${from}: No such file or directory`)
      w.files[to] = w.files[from] as string
      // Another /sleep finishing just as this one takes the marker (#843).
      if (o.recordOnMarker && to.endsWith('/state/sleep/preparing')) w.files[`${'/Users'}/x/.claude/state/sleep/current.json`] = o.recordOnMarker
      const linked = o.onPreparingLinked
      if (linked && to.endsWith('/state/sleep/preparing')) {
        o.onPreparingLinked = undefined
        return linked().then(() => ok()) as never
      }
      return ok()
    }
    if (cmd === 'rm') {
      for (const f of ops) for (const k of Object.keys(w.files)) if (k === f || (a.includes('-rf') && k.startsWith(`${f}/`))) delete w.files[k]
      return ok()
    }
    if (cmd === 'python3' && a[0] === `${'/Users'}/x/.claude/hooks/lib/sleep-report.py`) {
      // The night's report and its notes (#835): python3 sleep-report.py <op> --record <path> [--line <json>] [--final]
      const [, op, ...rest] = a as [string, string, ...string[]]
      const arg = (k: string) => rest[rest.indexOf(k) + 1] as string
      w.reports.push({ op, record: arg('--record'), ...(rest.includes('--final') ? { final: true } : {}) })
      if (op === 'note' && o.noteFails) return fail(1, o.noteFails)
      if (o.reportFails?.[op]) return fail(1, o.reportFails[op])
      if (op === 'note') w.appended.push({ file: arg('--record'), line: arg('--line') })
      // After the night's end note, never the overnight check's line written before it (#2766).
      if (op === 'note' && o.homeGoneAfterNote && /"kind":"(?:woke|limit)"/.test(arg('--line'))) w.homeGone = true
      // Every render writes what the report says needs Dan beside the notes (#1665), as the real
      // script does: a fixture given there stands for the rows the notes give, marked final by the
      // wake render; with none, the night had none.
      if (op === 'render' || op === 'start' || op === 'note') {
        try {
          const rec = JSON.parse(w.files[arg('--record')] ?? '') as { generation?: unknown }
          if (typeof rec.generation === 'string') {
            const at = `${'/Users'}/x/.claude/state/sleep/notes/${rec.generation.replace(/[^\w.-]/g, '_')}.needs.json`
            let had: Record<string, unknown> | null = null
            try {
              had = at in w.files ? (JSON.parse(w.files[at] as string) as Record<string, unknown>) : null
            } catch {
              had = null
            }
            if (!(at in w.files) || had) w.files[at] = JSON.stringify({ v: 1, generation: rec.generation, final: rest.includes('--final'), rows: had?.rows ?? [] })
          }
        } catch {
          // A record that is not JSON names no night.
        }
      }
      // The final render leaves the report the record names on the disk (#837: wake opens it).
      if (op === 'render' && rest.includes('--final')) {
        try {
          const rec = JSON.parse(w.files[arg('--record')] ?? '') as { report?: unknown }
          if (typeof rec.report === 'string') w.files[rec.report] = '# Sleep report\n'
        } catch {
          // A record that is not JSON names no report.
        }
      }
      return ok()
    }
    // Opening the night's report (#837): the BBEdit helper, then BBEdit by name.
    if (cmd === '/Applications/BBEdit.app/Contents/Helpers/bbedit_tool') {
      if (o.openFails?.helper) return fail(1, o.openFails.helper)
      w.opened.push(argv)
      return ok()
    }
    if (cmd === 'open' && a[0] === '-a' && a[1] === 'BBEdit') {
      if (o.openFails?.open) return fail(1, o.openFails.open)
      w.opened.push(argv)
      return ok()
    }
    if (cmd === 'terminal-notifier') {
      if (o.notifyFails) return fail(1, 'terminal-notifier: no permission to notify')
      w.notified.push(a[a.indexOf('-message') + 1] as string)
      return ok()
    }
    // mod-kit's readers, read here with its copy; a command naming __reader_fails stands for a
    // reader that throws. Not one of the runs a test watches, which reach the Mac.
    // #3321: what the reader in the mod-kit stand in saw as a question was asked. A question the
    // mod asks through $.ui.ask carries a generated toolu_ id; it must be a dialog the mod had kept
    // as its own, word for word as a hook gets it.
    if (cmd === '__own') {
      const seen = JSON.parse(a[0] as string) as { value: unknown; call: Record<string, unknown> & { questions?: { question?: unknown }[] } }
      if (/^toolu_/.test(String(seen.call.tool_use_id))) {
        w.ownAsks++
        if (!isOwnDialog(seen.value, seen.call)) w.unowned.push(`ask ${String(seen.call.questions?.[0]?.question).slice(0, 60)}`)
      }
      return ok('')
    }
    if (cmd === '__modkit' && (a[0] === 'hold' || a[0] === 'release')) {
      if (a[0] === 'hold' && o.holdFails) return fail(1, o.holdFails)
      const { id } = JSON.parse(a[1] as string) as { id: string }
      if (a[0] === 'hold') w.holding.add(id)
      else w.holding.delete(id)
      w.held.push(`${a[0]} ${a[1]}`)
      return ok('')
    }
    if (cmd === '__modkit') {
      const input = JSON.parse(a[1] as string) as { command?: string; cwd?: string; home?: string; words?: string[]; env?: string[]; root?: string | null; remote?: string | null; path?: string; spelling?: string; link?: string }
      if ((input.command ?? '').includes('__reader_fails')) return fail(1, 'the reader broke')
      if (a[0] === 'repo' && o.repoReaderFails) return fail(1, 'mod-kit is not loaded')
      if (a[0] === 'repo') return ok(JSON.stringify({ github: githubRepo(input.remote), name: repoName({ root: input.root, remote: input.remote }) }))
      if (a[0] === 'ghRepo' && o.ghRepoReaderFails) return fail(1, 'mod-kit is not loaded')
      if (a[0] === 'ghRepo') return ok(JSON.stringify(ghRepo(input.spelling)))
      // Where a checkout stands (#980), read by mod-kit's own reader asking this world's git. Every
      // folder is a checkout of its own here, as the git answers below treat it, except the
      // session's when it is in no repository.
      // The checkout a folder sits in (#996), as the branch reader's walk below finds it.
      if (a[0] === 'workingTree' && o.workingTreeFails) return fail(1, o.workingTreeFails)
      if (a[0] === 'workingTree') {
        // An installed app is in no checkout, as on the Mac.
        const under = Object.entries({ '/Applications/': null, ...o.trees }).find(([prefix]) => (input.path ?? '').startsWith(prefix))
        if (under) return ok(JSON.stringify(under[1]))
        return ok(JSON.stringify(o.noRepo && input.path === '/repo' ? null : (input.path ?? null)))
      }
      // A transcript's /goal (#1252), read by mod-kit's own reader asking this world's shell.
      if (a[0] === 'goal' && o.goalReaderFails) return fail(1, 'mod-kit is not loaded')
      if (a[0] === 'goal') {
        const sh = async (argv: string[]) => ((await answer($, { ...e, argv })) as { value: { exitCode: number; stdout: string; stderr: string } }).value
        return goalAt((input as { transcript?: string }).transcript ?? '', sh).then(g => ok(JSON.stringify(g)))
      }
      if (a[0] === 'branch') {
        if (o.branchReaderFails) return fail(1, o.branchReaderFails)
        const walk = async (p: string) => (o.noRepo && p === '/repo' ? null : p)
        const git = async (args: string[]) => ((await answer($, { ...e, argv: args })) as { value: { exitCode: number; stdout: string; stderr: string } }).value
        return branchAt(input.path ?? '', walk, git).then(b => ok(b === null ? '' : JSON.stringify(b)))
      }
      if (a[0] === 'linkRepo' && (o.linkReaderFails || (o.linkReaderFailsOn !== undefined && (input.link ?? '').includes(o.linkReaderFailsOn)))) return fail(1, 'mod-kit is not loaded')
      if (a[0] === 'linkRepo') return ok(JSON.stringify(linkRepo(input.link)))
      if (a[0] === 'isDans') return ok(JSON.stringify(isDans((input as { origin?: never }).origin)))
      if (a[0] === 'mergeHelper' && o.mergeHelperReaderFails) return fail(1, 'mod-kit is not loaded')
      // The git reader as mod-kit answered before it said which repository a command names (#3337,
      // #3398): the last -C alone, with no setting read.
      if (a[0] === 'git' && o.oldGitReader) {
        const old = git(input.words ?? [])
        return ok(old === undefined ? '' : JSON.stringify({ sub: old.sub, args: old.args, dir: old.dir }))
      }
      const out = a[0] === 'pipeline' ? pipeline(input.command ?? '') : a[0] === 'writes' ? commandWrites(input.command ?? '', input.cwd ?? '', input.home ?? '') : a[0] === 'gh' ? ghArgs(input.words ?? []) : a[0] === 'mergeHelper' ? mergeHelperArgs(JSON.parse(a[1] as string) as Command) : git(input.words ?? [], input.env ?? [])
      return ok(out === undefined ? '' : JSON.stringify(out))
    }
    // The overnight driver's reads and writes (#844): the queue, the sleep/ branches, power and caffeinate.
    if (cmd === 'bash' && a[0] === `${'/Users'}/x/.claude/hooks/lib/sleep-queue.sh`) {
      if (a[1] === 'claims' && o.claimsGate) {
        const gate = o.claimsGate
        o.claimsGate = undefined
        return gate.then(() => ok(o.claims ?? '')) as never
      }
      if (a[1] === 'claims') return ok(o.claims ?? '')
      if (a[1] === 'work') {
        w.workAsked.push(a.slice(2).join(' '))
        return ok(o.work?.[Number(a[3])] ?? 'branch\t\nworktree\t\n')
      }
      if (a[1] === 'release') {
        w.released.push(a.slice(2))
        w.releasedBy.push(String(e.init?.env?.SLEEP_NOTE_BY_DRIVER))
        if (o.releaseFails) return fail(1, o.releaseFails)
        return ok(`released\t${a[3]}\t${a[5]}\n`)
      }
    }
    // A session's goal records, as the shell finds them in its transcript by their mark (#1242): the
    // goal a test gives it, none (grep finds nothing and exits 1), or a read that fails.
    if (cmd === 'bash' && a[0] === '-c' && a[3] === GOAL_MARK) {
      w.goalReads.push(a[4] as string)
      const id = String(a[4]).split('/').pop()?.replace(/\.jsonl$/, '') ?? ''
      const g = o.goals && id in o.goals ? o.goals[id] : DEFAULT_GOAL
      if (g === null || g === undefined) return fail(1)
      if (typeof g === 'object') return fail(2, g.fails)
      return ok(`${JSON.stringify({ type: 'attachment', attachment: { type: 'goal_status', met: false, sentinel: true, condition: g } })}\n`)
    }
    if (cmd === 'pmset') {
      w.powerReads++
      const p = w.o.power
      if (typeof p === 'object') return fail(1, p.fails)
      return ok(p === 'battery' ? "Now drawing from 'Battery Power'\n" : "Now drawing from 'AC Power'\n")
    }
    if (cmd === 'sh' && String(a[1]).startsWith('caffeinate')) {
      if (o.caffeinateFails) return fail(127, 'sh: caffeinate: not found')
      w.caffeinated.push(a[a.length - 1] as string)
      return ok('4242\n')
    }
    if (cmd === 'ps') return ok(`${o.psArgs ?? `caffeinate -i -t ${w.caffeinated[0] ?? ''}`}\n`)
    // The merge helpers running on this Mac (#2901), as pgrep -lf prints them.
    if (cmd === 'pgrep') {
      w.pgreps.push(a)
      const h = o.helpers
      if (typeof h === 'object') return fail(2, h.fails)
      return h ? ok(h) : fail(1)
    }
    if (cmd === 'kill') {
      w.killed.push(a[0] as string)
      return ok()
    }
    // The duplicate check the end of turn review files by (#1389): a close match for a title GitHub
    // already holds, as milestone-candidates.sh prints it, nothing to report (exit 1), or a read
    // that failed (exit 6).
    if (cmd === 'bash' && a[0] === `${'/Users'}/x/.claude/skills/milestone/milestone-candidates.sh`) {
      w.dupChecks.push(a.slice(1))
      if (o.dupCheckFails) return fail(6, o.dupCheckFails)
      const like = a[a.indexOf('--like') + 1] as string
      const found = o.filedOnGitHub?.[like]
      if (!found) return { value: { exitCode: 1, stdout: `NO-CANDIDATES ${a[1]} has nothing like this.\n`, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
      return ok(`CANDIDATES-FOR ${a[1]}\nHOLDING-PEN Ungrouped open=3\nCLOSE-MATCH 0.900 #${found.number} ${like} [in: Ungrouped] [shares: total]${found.closed ? ' [closed]' : ''}\nCLOSE-MATCH-COUNT 1\n`)
    }
    // The polling policy (#1482), answered as Opts.poll says.
    if (cmd === 'bash' && a[0] === `${'/Users'}/x/.claude/hooks/lib/gh-poll.sh`) {
      w.polls.push({ argv: [...argv], ...(e.init?.env ? { env: { ...e.init.env } } : {}) })
      if (a[1] === 'take' && o.poll?.budget !== undefined) {
        const secs = Number(a[2])
        const minute = Math.floor(secs / 60)
        const used = w.polls.filter(p => p.argv[2] === 'take' && Math.floor(Number(p.argv[3]) / 60) === minute).length
        return ok(used <= o.poll.budget ? 'ok\n' : `wait\tcap\t${60 - (secs % 60)}\n`)
      }
      if (a[1] === 'take') return ok(`${o.poll?.take ?? 'ok'}\n`)
      if (a[1] === 'failed') return ok(`${o.poll?.failed ?? 'other'}\n`)
      if (a[1] === 'answered') return ok('ok\n')
      if (a[1] === 'next') {
        const [wait, changed, base, max] = a.slice(2).map(Number) as [number, number, number, number]
        return ok(`${changed === 1 ? base : Math.min(wait * 2, max)}\n`)
      }
    }
    w.runs.push(argv)
    // A mod's own manifest touched so it loads again (#1281).
    if (cmd === 'touch') return o.touchFails ? fail(1, o.touchFails) : ok()
    if (cmd === '__sessions') {
      if (o.unreadable?.includes('*')) return fail(1, 'the sessions folder could not be read')
      // A registry answer missing its lists, so enrolment throws reading it (#843).
      if (o.registryGarbled) return ok('{}')
      if (o.registryAnswer !== undefined) return ok(o.registryAnswer)
      // Each session's transcript where the registry finds it (#1242), unless a test says where.
      const withTranscript = (s: Session) => ({ transcriptPath: `${'/Users'}/x/.claude/projects/-repo/${s.sessionId}.jsonl`, ...s })
      return ok(JSON.stringify({ open: [{ sessionId: 's1', ...o.selfSession }, ...(o.open ?? [])].map(withTranscript), closed: [], unreadable: o.unreadable ?? [], selfId: 's1' }))
    }
    if (cmd === '__verdict') {
      const v = o.verdict ?? null
      return v && 'throws' in v ? fail(1, v.throws) : ok(JSON.stringify(v))
    }
    // The job watcher's answers (#2511): its job list, and the running agents it judged quiet.
    if (cmd === '__jobs' || cmd === '__quiet') {
      const v = cmd === '__jobs' ? (o.jobs ?? []) : (o.quiet ?? [])
      return 'throws' in v ? fail(1, v.throws) : ok(JSON.stringify(v))
    }
    // Sleep mode phase 7 (#843): each folder's origin, GitHub's answer to a repo view by account, and gh's accounts.
    if (cmd === 'gh' && a[0] === 'repo' && a[1] === 'view' && o.ghRepoViewFails) return fail(1, o.ghRepoViewFails)
    if (cmd === 'gh' && a[0] === 'repo' && a[1] === 'view' && o.ghRepoViewFailsWithToken && e.init?.env?.GH_TOKEN) return fail(1, o.ghRepoViewFailsWithToken)
    if (cmd === 'gh' && a[0] === 'repo' && a[1] === 'view') {
      const token = e.init?.env?.GH_TOKEN
      const seen = token ? (o.githubRepos?.[token] ?? []) : (o.githubRepos?.default ?? [])
      return seen.some(r => r.toLowerCase() === String(a[2]).toLowerCase()) ? ok(JSON.stringify({ nameWithOwner: a[2] })) : fail(1, `GraphQL: Could not resolve to a Repository with the name '${a[2]}'. (repository)`)
    }
    if (cmd === 'gh' && a[0] === 'auth' && a[1] === 'status') return ok(Object.keys(o.githubRepos ?? {}).filter(k => k !== 'default').map(k => `  Logged in to github.com account ${k} (keyring)`).join('\n'))
    if (cmd === 'gh' && a[0] === 'auth' && a[1] === 'token') return ok(`${a[3]}\n`)
    if (cmd === 'git' && a.includes('--show-current') && o.branch === '__fails') return fail(128, 'fatal: not a git repository')
    if (cmd === 'git' && a.includes('--show-current') && o.branches?.[a[1] as string] !== undefined) return ok(`${o.branches[a[1] as string]}\n`)
    if (cmd === 'git' && a.includes('--show-current')) return ok(`${o.branch ?? 'scope-modes-616'}\n`)
    if (cmd === 'git' && a.includes('symbolic-ref')) return ok(`origin/${o.defaultBranch ?? 'main'}\n`)
    if (cmd === 'git' && a.includes('--list')) return ok(o.branchHere === false ? '' : `  ${o.branch ?? 'scope-modes-616'}\n`)
    if (cmd === 'git' && a.includes('ls-remote')) return o.branchOnGitHub === false ? fail(2) : ok(`abc\trefs/heads/${o.branch ?? 'scope-modes-616'}\n`)
    if (cmd === 'git' && a.includes('worktree')) return ok(o.worktrees ?? `worktree /repo\nbranch refs/heads/main\n`)
    if (cmd === 'git' && a.includes('stash') && a.includes('show')) {
      const s = o.stash ?? []
      return 'fails' in s ? fail(1, s.fails) : ok(s.map(f => `${f}\n`).join(''))
    }
    if (cmd === 'git' && a.includes('status')) return ok(o.dirty?.includes(a[a.indexOf('-C') + 1] as string) ? (o.dirtyFiles ?? ['app.ts']).map(f => ` M ${f}\n`).join('') : '')
    // What the overnight rules ask of the disk (#834): /repo is a primary checkout of o/r unless a
    // test says otherwise, and every other folder is in no repository.
    if (cmd === 'git' && a.includes('remote')) {
      const dir = a[a.indexOf('-C') + 1] as string
      if (dir === `${'/Users'}/x/claude-config-sync`) return ok('origin\tgit@github.com:o/claude-config.git (fetch)\n')
      // Each folder's origin a test names (#843).
      const named = o.origins?.[dir]
      if (named) return ok(`origin\t${named} (fetch)\n`)
      return dir === '/repo' ? ok('origin\tgit@github.com:o/r.git (fetch)\n') : fail(128, 'fatal: not a git repository')
    }
    if (cmd === 'git' && a.includes('--git-common-dir')) {
      const dir = a[a.indexOf('-C') + 1] as string
      if (dir !== '/repo') return fail(128, 'fatal: not a git repository')
      return ok(o.linkedWorktree ? '/main/.git/worktrees/repo\n/main/.git\n' : '/repo/.git\n/repo/.git\n')
    }
    // The wake check's reads (#834): a quiet night unless a test gives one of them its own answer.
    const said = o.night?.[argv.join(' ')]
    if (said !== undefined) return typeof said === 'string' ? ok(said) : fail(1, said.fails)
    if (cmd === 'gh' && a[0] === 'api' && a[1] === 'user') {
      w.order.push('github')
      return ok('dan\n')
    }
    if (cmd === 'gh' && a[0] === 'api' && /^(?:users\/dan\/events|repos\/[^/]+\/[^/]+\/(?:milestones|commits))/.test(a[1] ?? '')) return ok('[]')
    if (cmd === 'gh' && a[0] === 'api' && /^repos\/[^/]+\/[^/]+\/actions\/runs\?/.test(a[1] ?? '')) return ok('{"total_count":0,"workflow_runs":[]}')
    if (cmd === 'gh' && (a[0] === 'search' || (a[0] === 'run' && a[1] === 'list'))) return ok('[]')
    if (cmd === 'gh') {
      const gh = o.gh ?? { pr: null, issues: {} }
      if (gh.fails) return fail(1, gh.fails)
      const head = gh.pr?.headRefName ?? 'scope-modes-616'
      if (a[0] === 'pr' && a[1] === 'list') return ok(JSON.stringify(gh.pr && a[a.indexOf('--head') + 1] === head ? [{ headRefName: head, ...gh.pr }] : []))
      if (a[0] === 'pr' && a[1] === 'view') {
        if (gh.pr && a[2] === String(gh.pr.number)) return ok(JSON.stringify({ headRefName: head, ...gh.pr }))
        const other = gh.others?.find(p => a[2] === String(p.number))
        // GitHub's own words for a number that is an issue (measured 2026-10-26 on claude-config#1702).
        if (!other && gh.notPrs?.includes(Number(a[2]))) return fail(1, `GraphQL: Could not resolve to a PullRequest with the number of ${a[2]}. (repository.pullRequest)`)
        return other ? ok(JSON.stringify(other)) : fail(1, 'no pull requests found')
      }
      if (a[0] === 'issue' && a[1] === 'view' && (gh as { garbled?: boolean }).garbled) return ok('<html>rate limited</html>')
      if (a[0] === 'issue' && a[1] === 'view' && a.includes('state,labels')) w.issueViewTimeouts.push(e.init?.timeoutMs)
      if (a[0] === 'issue' && a[1] === 'view' && o.issueViewFails) return fail(1, o.issueViewFails)
      if (a[0] === 'issue' && a[1] === 'view' && o.issueViewFailsOn?.[Number(a[2])]) return fail(1, o.issueViewFailsOn[Number(a[2])] as string)
      if (a[0] === 'issue' && a[1] === 'view') return ok(JSON.stringify({ state: gh.issues[Number(a[2])] ?? 'OPEN', labels: (o.issueLabels?.[Number(a[2])] ?? []).map(name => ({ name })), body: o.issueBodies?.[Number(a[2])] ?? 'The issue.\n\n## Open questions\n\nNone', comments: (o.issueComments?.[Number(a[2])] ?? []).map(body => ({ body })), url: `https://github.com/o/r/${o.pullNumbers?.includes(Number(a[2])) ? 'pull' : 'issues'}/${a[2]}` }))
      // An issue's body written whole (#1279), from standard input.
      if (a[0] === 'issue' && a[1] === 'edit') {
        if (o.editFails) return fail(1, o.editFails)
        const body = String(e.init?.stdin ?? '')
        w.edits.push({ repo: a[a.indexOf('--repo') + 1] as string, issue: Number(a[2]), body })
        o.issueBodies = { ...(o.issueBodies ?? {}), [Number(a[2])]: body }
        return ok(`https://github.com/o/r/issues/${a[2]}\n`)
      }
      // A decision posted on an issue (#836): gh prints the new comment's link.
      if (a[0] === 'issue' && a[1] === 'comment') {
        const repo = a[a.indexOf('--repo') + 1] as string
        if (o.commentFails?.[Number(a[2])]) return fail(1, o.commentFails[Number(a[2])])
        w.comments.push({ repo, issue: a[2] as string, body: a[a.indexOf('--body') + 1] as string })
        return ok(`https://github.com/${repo}/issues/${a[2]}#issuecomment-1\n`)
      }
    }
    return fail(1, `unexpected: ${argv.join(' ')}`)
  })
  on('session.id', () => {
    if (w.idThrows) throw new Error('the session id could not be read')
    return { value: 's1' } as never
  })
  on('agent.list', () => {
    const a = o.agents ?? []
    if ('throws' in a) throw new Error(a.throws)
    return { value: a.map(x => ({ description: 'a builder', type: 'general-purpose', ...x })) } as never
  })
  on('session.usage', () => {
    const u = o.usage ?? { cost: { usd: 1.5 }, rateLimits: [{ kind: 'five_hour', percentUsed: 40 }] }
    if ('throws' in u) throw new Error(u.throws)
    return { value: { startedAt: T0, context: { window: 200_000, percent: 10 }, ...u } } as never
  })
  on('session.cwd', () => {
    if (o.cwdThrows) throw new Error('the folder could not be read')
    if (o.cwdThrowsAsleep && Object.keys(w.files).some(f => f.endsWith('/sleep/current.json'))) throw new Error('the folder could not be read')
    return { value: o.cwd ?? '/repo' } as never
  })
  on('session.repo', () => ({ value: o.noRepo ? null : { root: '/repo', remote: o.remote === undefined ? 'git@github.com:o/r.git' : o.remote, internal: false, name: null } }) as never)
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('session.end', ($, e) => ({ sessionId: e.sessionId }) as never)
  on('command.register', ($, e) => {
    const c = e as unknown as { name: string; description: string }
    w.commands.push({ name: c.name, description: c.description })
    return { value: undefined } as never
  })
  on('tool.register', ($, e) => {
    w.tools.push(String((e as { name?: string }).name))
    return { value: undefined } as never
  })
  let sends = 0
  on('session.send', ($, e) => {
    w.sent.push({ to: e.to, text: e.text })
    const outcome = o.sends?.[sends++] ?? true
    return (outcome === true ? { isDelivered: true } : { isDelivered: false, reason: outcome.refused }) as never
  })
  on('prompt.submit', ($, e) => {
    // A prompt the mod sends itself, never one a test types as Dan (#2132), is a wait a reload drops.
    const from = (e as unknown as { origin?: { kind?: string; name?: string } }).origin
    if (from?.kind === 'plugin' && from.name === 'scope-modes') {
      w.held.push('submit')
      if (!w.holding.size) w.unheld.push(`submit ${e.text.slice(0, 60)}`)
    }
    if (o.promptFails) {
      o.promptFails--
      throw new Error('the prompt could not be entered')
    }
    w.prompts.push(e.text)
    return { text: e.text, context: e.context } as never
  })
  on('turn.complete', ($, e) => ({ text: e.answer }) as never)
  on('turn.start', ($, e) => ({ turnId: e.turnId }) as never)
  on('session.receive', ($, e) => ({ text: e.text }) as never)
  // A hook beneath the mod that blocks every Stop, as Claude Code's own /goal hook does while its
  // condition does not hold (measured on 2.1.301, #1242); each time it is reached is counted.
  on('classic.Stop', () => {
    w.beneathStops++
    return (o.goalHookBlocks ? { block: '[Close #7]: not yet' } : {}) as never
  })
  on('classic.PermissionRequest', () => (o.beneathDecision ? { decision: o.beneathDecision } : {}) as never)
  on('classic.PermissionDenied', () => (o.beneathRetries ? { retry: true } : {}) as never)
  on('classic.StopFailure', () => ({}) as never)
  on('ui.toast', ($, e) => {
    w.toasts.push(e.text)
    return { value: undefined }
  })
  on('ui.log', ($, e) => {
    w.logs.push(e.text)
    const [tag, ...rest] = e.text.split(' ')
    const body = rest.join(' ')
    if (tag === 'CARD') w.cards.push(JSON.parse(body))
    if (tag === 'BAND') w.bands.push(JSON.parse(body))
    if (tag === 'CLEAR') w.cleared.push(body)
    if (tag === 'MODES') {
      w.modes.push(JSON.parse(body))
      w.order.push(`modes ${body}`)
    }
    return { value: undefined }
  })
  on('tool.call', ($, e) => {
    // $.ui.ask raises the AskUserQuestion dialog as a tool call; Dan answers it here.
    if (e.tool === 'AskUserQuestion') {
      const first = (e as unknown as { questions: { question: string; options?: unknown[] }[] }).questions[0]
      const q = String(first?.question)
      // A question the mod asks through $.ui.ask: the engine gives its call a generated toolu_ id,
      // where a test's own call for Claude carries a short one of its own ('q1', 'p1').
      if (/^toolu_/.test(String((e as unknown as { tool_use_id?: unknown }).tool_use_id))) {
        w.held.push('ask')
        if (!w.holding.size) w.unheld.push(`ask ${q.slice(0, 60)}`)
      }
      w.asked.push(q)
      w.askedOptions.push((first?.options ?? []).map(x => (x && typeof x === 'object' ? String((x as { label?: unknown }).label) : String(x))))
      // A before bed question about an issue (#836), answered as the test says.
      if (o.issueAnswers && Object.prototype.hasOwnProperty.call(o.issueAnswers, q)) {
        const given = o.issueAnswers[q]
        const qs = (e as unknown as { questions: unknown[] }).questions
        const reply = (a: string) => ({ result: { questions: qs, answers: { [q]: a } }, text: `answered ${a}` })
        if (given === null || given === undefined) return never() as never
        if (given === '__dismissed') throw new Error('the dialog was dismissed')
        if (typeof given === 'string') return reply(given) as never
        return given.then(reply) as never
      }
      if (q.endsWith('what may Claude do?') && o.repoAnswer === null) return never() as never
      // An answer Dan gives only when the test lets it go: after the wait, as late as it likes (#843).
      if (q.endsWith('what may Claude do?') && o.repoAnswerLate) {
        const qs = (e as unknown as { questions: unknown[] }).questions
        return o.repoAnswerLate.then(a => ({ result: { questions: qs, answers: { [q]: a } }, text: `answered ${a}` })) as never
      }
      if (q.endsWith('what may Claude do?') && o.repoAnswer === '__dismissed') throw new Error('the dialog was dismissed')
      if (q.endsWith('what may Claude do?') && o.repoAnswer !== undefined) {
        const a = o.repoAnswer
        return { result: { questions: (e as unknown as { questions: unknown[] }).questions, answers: { [q]: a } }, text: `answered ${a}` } as never
      }
      return { result: { questions: (e as unknown as { questions: unknown[] }).questions, answers: { [q]: o.ask ?? 'Yes' } }, text: `answered ${o.ask ?? 'Yes'}` } as never
    }
    const command = (e as { command?: string }).command
    // A call a guard beneath refuses (#1108): it never ran, so it wrote nothing.
    if (o.refusedBeneath && String(command ?? (e as { file_path?: string }).file_path).includes(o.refusedBeneath)) return { deny: 'refused beneath' } as never
    w.reached.push(String(command ?? (e as { file_path?: string }).file_path ?? e.tool))
    // A branch started by switch or checkout moves the checkout onto it, unless the test says it fails (#1051).
    const started = /\bgit (?:switch -c|checkout -b) (\S+)/.exec(command ?? '')
    if (started && !o.switchFails) o.branch = started[1]
    if (/\bpr create\b/.test(command ?? '') && o.created) return { result: { stdout: o.created, stderr: '' }, text: o.created } as never
    if (/\bissue create\b/.test(command ?? '') && o.issueCreated) return { result: { stdout: o.issueCreated, stderr: '' }, text: o.issueCreated } as never
    return { result: 'ran', text: 'ran' } as never
  })
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine</Text>
  })
  everyWorld.push(w)
  return { w, clock, readAttempted }
}
// #2132: every world made in this file, so its closing checks can read every wait the mod made in all of them.
const everyWorld: { o: Opts; held: string[]; unheld: string[]; ownAsks: number; unowned: string[] }[] = []
// #3446: whether this file registered its closing checks, and whether they have begun to run. A
// world made in a file that never registered them, or made after they ran, is refused by world().
const closing = { registered: false, ran: false }

export type $T = {
  session: { start: (e: never) => Promise<unknown>; end: (e: never) => Promise<unknown>; receive: (e: never) => Promise<unknown> }
  tool: { call: (e: never) => Promise<unknown> }
  command: { run: (e: never) => Promise<unknown> }
  prompt: { submit: (e: never) => Promise<unknown> }
  turn: { complete: (e: never) => Promise<unknown> }
  classic: { Stop: (e: never) => Promise<unknown>; PermissionRequest: (e: never) => Promise<unknown>; PermissionDenied: (e: never) => Promise<unknown> }
}
export const start = async ($: $T, clock: { settle: () => Promise<void> }) => {
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true } as never)
  await clock.settle()
}
export const command = async ($: $T, name: string, origin: string = 'composer') =>
  (await $.command.run({ command: name, args: '', origin: { kind: origin }, presentation: {} } as never)) as { text?: string; context?: string[] }
export const say = async ($: $T, text: string, origin: string | object = 'composer') =>
  (await $.prompt.submit({ text, origin: typeof origin === 'string' ? { kind: origin } : origin, wait: false } as never)) as { text: string; context?: string[] }
export const bash = (command: string, id = 'c1') => ({ tool: 'Bash', command, tool_use_id: id }) as never
// What away and sleep still hold after #1269, standing for "needs Dan at the Mac" wherever a test
// asks only whether a call is held: a dialog waits for a press nobody is there to give.
export const DIALOG = `osascript -e 'display dialog "Done?"'`
export const edit = (path: string, id = 'c1') => ({ tool: 'Edit', file_path: path, old_string: 'a', new_string: 'b', tool_use_id: id }) as never
export const call = async ($: $T, e: never) => {
  const r = (await $.tool.call(e)) as { deny?: string; text?: string }
  return r.deny ?? r.text ?? ''
}
export const stop = async ($: $T) => (await $.classic.Stop({ stop_hook_active: false } as never)) as { block?: string }
export const lastModes = (w: { modes: string[][] }) => w.modes[w.modes.length - 1]

// The last line of every test file that makes a world (#3446), so its two checks are the file's
// last tests and read every wait the mod made in every test above them. `holds` is every kind of
// hold the file's tests reach, so a site that stops being exercised fails here too, and
// `ownAsksOver` the count the questions the mod asked itself must pass, which shows they were
// reached at all. A file that leaves it out says its tests make the mod ask Dan nothing, and the
// count must then be 0.
export const closingChecks = (expected: { holds: string[]; ownAsksOver?: number }) => {
  closing.registered = true
  // Each one was held, and every kind of wait the file expects was reached at least once.
  test('every prompt the mod sends and every question it asks Dan holds back a reload of scope-modes while it waits (#2132)', async () => {
    closing.ran = true
    const worlds = everyWorld.filter(x => !x.o.holdFails)
    expect(worlds.flatMap(x => x.unheld)).toEqual([])
    const ids = new Set(worlds.flatMap(x => x.held.filter(h => h.startsWith('hold ')).map(h => (JSON.parse(h.slice(5)) as { id: string }).id.replace(/ \d+$/, ''))))
    expect([...ids].sort()).toEqual([...expected.holds].sort())
  })

  // #3321: a question the mod asks through its own dialog reaches picker manners with nothing on it
  // saying a mod raised it, so the mod keeps the dialog in its own state, which only it can write,
  // for as long as it is open, through mod-kit's recorder, and picker manners reads that. Last in
  // the file like the case above: of every question the mod asked in every test, each was a dialog
  // its state held, word for word as another mod's hook gets it (the engine's own chip over a
  // question that gives none included), and the count shows the questions were reached at all.
  test('every question the mod asks Dan itself is kept as its own dialog while it is open (#3321)', async () => {
    closing.ran = true
    expect(everyWorld.flatMap(x => x.unowned)).toEqual([])
    const asks = everyWorld.reduce((n, x) => n + x.ownAsks, 0)
    if (expected.ownAsksOver === undefined) expect(asks).toBe(0)
    else expect(asks).toBeGreaterThan(expected.ownAsksOver)
  })
}
