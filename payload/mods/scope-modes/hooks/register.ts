import type { EngineInterface, Register } from 'claude-code'
import type { ScopeModes, ScopeModesHeld, ScopeModesPlace, ScopeModesScope, ScopeModesTarget } from '../types/index.d.ts'
import { heldCard, heldTool, needsTheMac } from './away.ts'
import { noBuildRefusal, type Cmd } from './nobuild.ts'
import { isShell, programsOf } from './program.ts'
import { isDans, triggersIn, type Trigger } from './triggers.ts'
import { issuesOfBranch, newWork, outstanding, type DeployState, type Reading } from './winddown.ts'

// Scope modes (#616) and away and home (#621), one mod because they share one state: the status
// bar holds ONE list of modes for the band's amber line (no build or winding down, and away, can be
// on at once), and both are switched by Dan's own words read off the same prompt and both judge the
// same Bash calls. Settled with Dan on 2026-10-04 (docs/mods-design.md): the mode leads the amber
// line in the band in bold; coming home is a boxed card in the band; a message from the phone while
// home gets one line at the end of Claude's reply.
//
// Every mode lives in $.state, which a new session starts without: a new session is at home with no
// scope mode, and session.end (exit or /clear) turns them all off, so nothing carries over.

const MOD = 'scope-modes'
const MIN = 60_000
const RUN_MS = 20_000
const AWAY_TEXT = 'Dan switched every session on this Mac to away.'
const HOME_TEXT = 'Dan switched every session on this Mac to home.'
const PHONE_LINE = "You're on your phone. Reply away to switch every session."
const SCOPE_NAME: Record<ScopeModesScope, string> = { 'NO BUILD': 'No build', 'WINDING DOWN': 'Winding down' }

const scopeRef = { plugin: 'scope-modes', key: 'scope' } as const
const placeRef = { plugin: 'scope-modes', key: 'place' } as const
const heldRef = { plugin: 'scope-modes', key: 'held' } as const
const heldSeqRef = { plugin: 'scope-modes', key: 'heldSeq' } as const
const targetRef = { plugin: 'scope-modes', key: 'target' } as const
const justHomeRef = { plugin: 'scope-modes', key: 'justHome' } as const

// Where the last prompt came from, so the turn it started knows whether Dan wrote it on his phone.
let lastOrigin: string | undefined
let ticking = false
let statusNoted = false
// One finish check at a time: the turn end and the minute's tick share whichever is running.
let checking: Promise<string[] | null> | undefined

const msg = (err: unknown) => String((err as Error)?.message ?? err)

const scopeOf = async ($: EngineInterface) => (await $.state.get(scopeRef)).value ?? null
const placeOf = async ($: EngineInterface): Promise<ScopeModesPlace> => (await $.state.get(placeRef)).value ?? 'home'
const heldOf = async ($: EngineInterface) => (await $.state.get(heldRef)).value ?? []

// The band's amber line, through the status bar: the scope first, then away.
const showModes = async ($: EngineInterface) => {
  const scope = await scopeOf($)
  const modes = [...(scope ? [scope] : []), ...((await placeOf($)) === 'away' ? ['AWAY' as const] : [])]
  try {
    await $.statusbar.setModes({ modes })
  } catch (err) {
    // The mode still holds; only its label is missing. Said once, never silently (fail loud).
    if (!statusNoted) {
      statusNoted = true
      $.ui.toast(`The mode is on but cannot show in the band: ${msg(err)}`)
    }
  }
}

// The held card shows only at home, where Dan can press it.
const showHeld = async ($: EngineInterface) => {
  const card = (await placeOf($)) === 'home' ? heldCard(await heldOf($)) : undefined
  try {
    if (card) await $.modkit.bandRow(card)
    else await $.modkit.clearBandRow({ mod: MOD, id: 'held' })
  } catch (err) {
    $.ui.toast(`What was held while you were away cannot show in the band: ${msg(err)}`)
  }
}

const hold = async ($: EngineInterface, label: string, prompt: string) => {
  const held = await heldOf($)
  if (held.some(h => h.prompt === prompt)) return
  const seq = ((await $.state.get(heldSeqRef)).value ?? 0) + 1
  await $.state.set(heldSeqRef, seq)
  await $.state.set(heldRef, [...held, { id: String(seq), label, prompt }])
}

// Every simple command a Bash call runs, through mod-kit's one reader, each with its git reading
// and the program it runs (program.ts). A shell's program is more commands, so one the reader kept
// as text (`bash -lc '...'`, a here-string, echo piped in) is read the same way, as mod-kit reads
// `bash -c` (#702). Nesting past a few shells deep is not read, and says so.
const NEST = 3
const readCommands = async ($: EngineInterface, raw: string, depth = 0): Promise<Cmd[]> => {
  const list = await $.modkit.commands({ command: raw })
  const programs = programsOf(list)
  const out: Cmd[] = []
  for (let i = 0; i < list.length; i++) {
    const words = list[i] as string[]
    const g = await $.modkit.git({ words })
    const p = programs[i]
    const inner = p && 'text' in p && isShell(words) ? p.text : undefined
    const program = inner !== undefined && depth >= NEST ? { unreadable: 'nested too deep in shells to read' } : p
    out.push({ words, ...(g ? { git: { sub: g.sub, args: g.args } } : {}), ...(program ? { program } : {}) })
    if (inner !== undefined && depth < NEST) out.push(...(await readCommands($, inner, depth + 1)))
  }
  return out
}

const run = async ($: EngineInterface, argv: string[]) => {
  try {
    return await $.process.run(argv, { timeoutMs: RUN_MS })
  } catch (err) {
    return { exitCode: -1, stdout: '', stderr: msg(err), isStdoutTruncated: false, isStderrTruncated: false }
  }
}

// What winding down finishes: the branch this session is on, read when it turns on. Not in a
// repository is an answer (nothing to finish); a read that fails is not, and is said (L11).
type TargetRead = ScopeModesTarget | null | { unreadable: string }
const readTarget = async ($: EngineInterface): Promise<TargetRead> => {
  let repo
  try {
    repo = await $.session.repo()
  } catch (err) {
    return { unreadable: msg(err) }
  }
  if (!repo) return null
  let cwd: string
  try {
    cwd = await $.session.cwd()
  } catch (err) {
    return { unreadable: msg(err) }
  }
  const b = await run($, ['git', '-C', cwd, 'branch', '--show-current'])
  if (b.exitCode !== 0) return { unreadable: b.stderr.trim() || `git exited ${b.exitCode}` }
  const branch = b.stdout.trim()
  // origin/HEAD is often never set locally, so its absence falls back to the usual names.
  const head = await run($, ['git', '-C', repo.root, 'symbolic-ref', '--short', 'refs/remotes/origin/HEAD'])
  const defaultBranch = head.exitCode === 0 ? head.stdout.trim().replace(/^origin\//, '') : undefined
  // A detached head has no branch to finish.
  const isDefault = !branch || (defaultBranch ? branch === defaultBranch : ['main', 'master'].includes(branch))
  return { root: repo.root, branch, isDefault, issues: issuesOfBranch(branch), pr: null }
}

type PrJson = { number?: number; state?: string; url?: string; closingIssuesReferences?: { number?: number }[] }

type IsItLiveNoun = { verdict: (q: { repo: string; pr: number }) => Promise<{ state: DeployState } | null> }

// The deploy as is it live's card for this PR says (#687), never Claude's word. The repository is
// the one GitHub's own link for the PR names. An absent mod is unmeasured, never live; a read that
// throws (a withheld noun, a state that cannot be read) is said as unreadable.
const readDeploy = async ($: EngineInterface, pr: { number: number; url?: string }): Promise<Reading['deploy']> => {
  const repo = /^https:\/\/github\.com\/([\w.-]+\/[\w.-]+)\/pull\/\d+/.exec(pr.url ?? '')?.[1]
  if (!repo) return { unreadable: `GitHub gave no link for PR #${pr.number}` }
  try {
    const v = await ($ as unknown as { isItLive: IsItLiveNoun }).isItLive.verdict({ repo, pr: pr.number })
    return v ? { state: v.state } : null
  } catch (err) {
    // A noun of $ may only be spelled at its call site (the engine refuses `in $` or reading
    // $.isItLive as a value), so absence is told by the call: a missing noun is a TypeError from
    // reading .verdict off undefined, while whatever the noun itself throws reaches here wrapped as
    // the engine's HooksError (measured in the tests). Either way it is never live.
    if (err instanceof TypeError) return { unmeasured: 'the is it live mod is not loaded' }
    return { unreadable: msg(err) }
  }
}

const readWind = async ($: EngineInterface, t: ScopeModesTarget): Promise<Reading> => {
  const r: Reading = { branch: t.branch, isDefault: t.isDefault, pr: null, branchHere: false, branchOnGitHub: false, worktreeOnBranch: false, deploy: null, dirty: false }
  let prUrl: string | undefined
  const gh = async (args: string[]) => {
    const out = await $.process.run(['gh', ...args], { timeoutMs: RUN_MS, cwd: t.root }).catch(err => ({ exitCode: -1, stdout: '', stderr: msg(err) }))
    return out
  }
  if (t.branch) {
    const found = t.pr
      ? await gh(['pr', 'view', String(t.pr), '--json', 'number,state,url,closingIssuesReferences'])
      : await gh(['pr', 'list', '--head', t.branch, '--state', 'all', '--limit', '1', '--json', 'number,state,url,closingIssuesReferences'])
    if (found.exitCode !== 0) return { ...r, pr: { unreadable: found.stderr.trim() || `gh exited ${found.exitCode}` } }
    let pr: PrJson | undefined
    try {
      const j = JSON.parse(found.stdout) as PrJson | PrJson[]
      pr = Array.isArray(j) ? j[0] : j
    } catch {
      return { ...r, pr: { unreadable: 'gh answered something that is not JSON' } }
    }
    if (pr && typeof pr.number === 'number') {
      if (!t.pr) await $.state.set(targetRef, { ...t, pr: pr.number })
      const state = pr.state === 'MERGED' || pr.state === 'CLOSED' ? pr.state : 'OPEN'
      const issues: { number: number; state: 'OPEN' | 'CLOSED' }[] = []
      for (const ref of pr.closingIssuesReferences ?? []) {
        if (typeof ref.number !== 'number') continue
        const v = await gh(['issue', 'view', String(ref.number), '--json', 'state'])
        if (v.exitCode !== 0) return { ...r, pr: { unreadable: `issue #${ref.number}: ${v.stderr.trim()}` } }
        const s = (JSON.parse(v.stdout) as { state?: string }).state
        issues.push({ number: ref.number, state: s === 'CLOSED' ? 'CLOSED' : 'OPEN' })
      }
      r.pr = { number: pr.number, state, issues }
      prUrl = typeof pr.url === 'string' ? pr.url : undefined
    }
  }
  // The deploy and the cleanup are read only once the PR is merged, so an open PR costs one gh call a check.
  if (r.pr && !('unreadable' in r.pr) && r.pr.state === 'MERGED') {
    r.deploy = await readDeploy($, { number: r.pr.number, url: prUrl })
    const here = await run($, ['git', '-C', t.root, 'branch', '--list', t.branch])
    r.branchHere = here.exitCode === 0 ? here.stdout.trim() !== '' : { unreadable: here.stderr.trim() }
    // ls-remote --exit-code answers 2 when no such branch, and anything else nonzero is a failed read.
    const remote = await run($, ['git', '-C', t.root, 'ls-remote', '--exit-code', '--heads', 'origin', t.branch])
    r.branchOnGitHub = remote.exitCode === 0 ? true : remote.exitCode === 2 ? false : { unreadable: remote.stderr.trim() || 'could not reach origin' }
    const wt = await run($, ['git', '-C', t.root, 'worktree', 'list', '--porcelain'])
    r.worktreeOnBranch = wt.exitCode === 0 ? wt.stdout.split('\n').includes(`branch refs/heads/${t.branch}`) : { unreadable: wt.stderr.trim() }
  }
  if (t.isDefault && r.pr === null) {
    const st = await run($, ['git', '-C', t.root, 'status', '--porcelain'])
    r.dirty = st.exitCode === 0 ? st.stdout.trim() !== '' : { unreadable: st.stderr.trim() }
  }
  return r
}

// What is still to do, or null when winding down is not on.
const check = ($: EngineInterface): Promise<string[] | null> => {
  if (checking) return checking
  checking = (async () => {
    if ((await scopeOf($)) !== 'WINDING DOWN') return null
    let t = (await $.state.get(targetRef)).value ?? null
    if (t && 'unreadable' in t) {
      const again = await readTarget($)
      await $.state.set(targetRef, again)
      if (again && 'unreadable' in again) return [`what this session is working on could not be read (${again.unreadable})`]
      t = again
    }
    // Outside a repository there is no PR, branch or deploy to finish.
    if (!t) return []
    // A check that throws must refuse the turn end: a Stop hook that fails is skipped, which would
    // let the turn end unfinished (L42).
    try {
      return outstanding(await readWind($, t))
    } catch (err) {
      return [`the finish check failed (${msg(err)})`]
    }
  })().finally(() => {
    checking = undefined
  })
  return checking
}

const finish = async ($: EngineInterface) => {
  await $.state.set(scopeRef, null)
  await $.state.set(targetRef, null)
  await showModes($)
  $.ui.toast('Wind down finished: safe to close this session.')
}

const setScope = async ($: EngineInterface, scope: ScopeModesScope | null) => {
  await $.state.set(scopeRef, scope)
  await $.state.set(targetRef, scope === 'WINDING DOWN' ? await readTarget($) : null)
  await showModes($)
}

type Told = { told: number; failed: string[]; unknown?: string }
const tellOthers = async ($: EngineInterface, place: ScopeModesPlace): Promise<Told> => {
  let list
  try {
    list = await $.sessions.list()
  } catch (err) {
    return { told: 0, failed: [], unknown: `the session registry could not be read (${msg(err)})` }
  }
  const out: Told = { told: 0, failed: [] }
  // A record that cannot be read may be a live session: said, never read as no session (L215).
  if (list.unreadable.length) out.unknown = `the session registry could not read ${list.unreadable.join(', ')}`
  for (const o of list.open) {
    if (o.sessionId === list.selfId) continue
    // mod-kit tries a refused send once more (its hooks/send.ts), so a refusal here is the second.
    const sent = await $.session.send({ to: { sessionId: o.sessionId }, text: place === 'away' ? AWAY_TEXT : HOME_TEXT })
    if (!sent.isDelivered) out.failed.push(sent.reason)
    else out.told++
  }
  return out
}

const setPlace = async ($: EngineInterface, place: ScopeModesPlace) => {
  await $.state.set(placeRef, place)
  await $.state.set(justHomeRef, place === 'home')
  await showModes($)
  await showHeld($)
}

const placeSentence = (place: ScopeModesPlace, t: Told) => {
  const name = place === 'away' ? 'Away' : 'Home'
  let s = `${name} is on in this session${t.told ? ` and ${t.told} other${t.told === 1 ? '' : 's'}` : ''}.`
  if (t.failed.length) s += ` ${t.failed.length} could not be told: ${[...new Set(t.failed)].join('; ')}.`
  if (t.unknown) s += ` The other sessions could not be told: ${t.unknown}.`
  return s
}

// What the modes on make of one tool call: the refusal to answer it with, or undefined to let it run.
type Judged = { tool: string; input: Record<string, unknown>; toolUseId: string; scope: ScopeModesScope | null; away: boolean }
const judge = async ($: EngineInterface, j: Judged): Promise<{ deny: string } | undefined> => {
  const { tool, input, toolUseId, scope, away } = j
  const raw = tool === 'Bash' ? String(input.command ?? '') : ''
  const commands = raw ? await readCommands($, raw) : []

  if (scope === 'NO BUILD') {
    const r = noBuildRefusal({ tool, input, commands })
    if (r) {
      await $.modkit.blocked({ toolUseId, guard: 'No build', reason: `No build is on, so this would not ${r.what}.`, safeWay: 'Claude asks you: Switch to build?' })
      return {
        deny: `Blocked: no build is on, so this did not ${r.what}.${r.hint ? ` ${r.hint}` : ''} Ask Dan one question by calling mcp__scope-modes__switch_to_build, naming what you would change; carry on with what no build allows until he says yes.`,
      }
    }
  }
  if (scope === 'WINDING DOWN') {
    const t = (await $.state.get(targetRef)).value ?? null
    const r = newWork({ tool, input, commands, issues: t && 'issues' in t ? t.issues : [] })
    if (r) {
      await $.modkit.blocked({ toolUseId, guard: 'Winding down', reason: `Winding down, so this would not ${r.what}.`, safeWay: 'Claude finishes this issue and files anything else.' })
      return { deny: `Blocked: winding down, so this did not ${r.what}. Finish this issue; file anything new as an issue instead of working on it.` }
    }
  }
  if (away) {
    // A Bash call by what its commands do on the Mac; another tool by what it opens (#702).
    const label = raw ? needsTheMac({ raw, commands }) : heldTool(tool, input)
    if (label) {
      const { tool: _t, tool_use_id: _id, agentId: _a, consent: _c, ...args } = input
      await hold($, label, `Do it now. What was held: ${raw || `${tool} ${JSON.stringify(args)}`}`)
      await $.modkit.blocked({ toolUseId, guard: 'Away', reason: `Held for when you are back: ${label}.`, safeWay: 'Claude publishes a private page for your phone instead.' })
      return {
        deny: `Held: Dan is away from the Mac, so "${label}" waits for him to come back. Publish what he needs to see as a private claude.ai page instead (the Artifact tool).`,
      }
    }
  }
  return undefined
}

const SCOPE_NOTE: Record<ScopeModesScope, string> = {
  'NO BUILD': 'No build is on: read, research, run tests and checks, write scratchpad notes and do GitHub issue, milestone and label work. No edits outside the scratchpad, commits, branches, PRs, deploys or data changes.',
  'WINDING DOWN':
    "Winding down is on: finish this issue (PR merged, deploy live, worktree and branch cleaned, issue closed) and start nothing new. Fix only what blocks this issue's merge or deploy; file anything else. After the merge, check the deploy and make the is it live card (mcp__is-it-live__card): winding down finishes only once that card says Live or no deploy step recorded.",
}
const AWAY_NOTE =
  'Dan is away from the Mac. Deliver results as a private claude.ai page he can read on his phone (the Artifact tool). Open nothing on the Mac and take no focus: anything that needs him at the Mac is held for when he is back.'
const HOME_NOTE = 'Dan is back at the Mac: deliver results as CLAUDE.md says (HTML in Chrome, drafts in BBEdit, images and PDFs in Preview).'

export const register: Register = on => {
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    const scopeModes: ScopeModes = {
      isAway: async () => ((await built.state.get(placeRef)).value ?? 'home') === 'away',
      hold: async ({ label, prompt }) => {
        if (((await built.state.get(placeRef)).value ?? 'home') !== 'away') return { isHeld: false }
        const held = (await built.state.get(heldRef)).value ?? []
        if (!held.some(h => h.prompt === prompt)) {
          const seq = ((await built.state.get(heldSeqRef)).value ?? 0) + 1
          await built.state.set(heldSeqRef, seq)
          await built.state.set(heldRef, [...held, { id: String(seq), label, prompt }])
        }
        return { isHeld: true }
      },
    }
    return { ...built, scopeModes }
  })

  on('session.start', async ($, e, next) => {
    for (const [name, description] of [
      ['nobuild', 'No build: read, research and file only, until /build.'],
      ['winddown', 'Wind down: finish this issue, start nothing new, then stop.'],
      ['build', 'Turn no build or winding down off.'],
      ['away', "Away: every session publishes pages for the phone and opens nothing on the Mac."],
      ['home', 'Home: every session delivers on the Mac again.'],
    ] as const)
      await $.command.register({ name, description, immediate: true })
    await $.tool.register({
      name: 'switch_to_build',
      description:
        'While no build is on, ask Dan whether to switch to build. Name the change you would make. Only his yes turns no build off; call it once after a no build refusal, never again for the same change after a no.',
      inputSchema: { type: 'object', properties: { change: { type: 'string', description: 'What you would change, as a short phrase ("edit app.ts to fix the date parse")' } }, required: ['change'] },
    })
    if (!ticking) {
      ticking = true
      // Winding down ends itself once it is live, watched each minute rather than only at turn end.
      $.clock.every(MIN, async () => {
        try {
          const left = await check($)
          if (left && left.length === 0) await finish($)
        } catch (err) {
          $.ui.log(`scope-modes: the wind down check failed: ${msg(err)}`, { to: 'debug' })
        }
      })
    }
    return next(e)
  })

  // The commands, which say which mode turned on, and confirm the off.
  on('command.run', { command: 'nobuild' }, async $ => {
    await setScope($, 'NO BUILD')
    return { text: 'No build is on.', context: [`Dan turned on no build. ${SCOPE_NOTE['NO BUILD']}`] }
  })
  on('command.run', { command: 'winddown' }, async $ => {
    await setScope($, 'WINDING DOWN')
    return { text: 'Winding down is on.', context: [`Dan turned on winding down. ${SCOPE_NOTE['WINDING DOWN']}`] }
  })
  on('command.run', { command: 'build' }, async $ => {
    const scope = await scopeOf($)
    if (!scope) return { text: 'No scope mode was on.' }
    await setScope($, null)
    return { text: `${SCOPE_NAME[scope]} is off.`, context: [`Dan turned ${SCOPE_NAME[scope].toLowerCase()} off: build as usual.`] }
  })
  on('command.run', { command: 'away' }, async $ => {
    await setPlace($, 'away')
    return { text: placeSentence('away', await tellOthers($, 'away')) }
  })
  on('command.run', { command: 'home' }, async $ => {
    await setPlace($, 'home')
    return { text: placeSentence('home', await tellOthers($, 'home')) }
  })

  // Dan's own words switch modes; every prompt carries what is on, so Claude never guesses.
  on('prompt.submit', async ($, e, next) => {
    lastOrigin = e.origin.kind
    const notes: string[] = []
    if (isDans(e.origin)) {
      for (const t of triggersIn(e.text) as Trigger[]) {
        if (t.kind === 'scope') {
          await setScope($, t.scope)
          notes.push(`${SCOPE_NAME[t.scope]} just turned on from Dan's message. Say so in one line first.`)
        } else if (t.kind === 'build') {
          const was = await scopeOf($)
          if (was) {
            await setScope($, null)
            notes.push(`${SCOPE_NAME[was]} just turned off from Dan's message. Say so in one line first.`)
          }
        } else {
          await setPlace($, t.place)
          const told = await tellOthers($, t.place)
          notes.push(`Dan's message switched every session to ${t.place}. Say so in one line first: "${placeSentence(t.place, told)}"`)
        }
      }
    }
    const scope = await scopeOf($)
    if (scope) notes.push(SCOPE_NOTE[scope])
    if ((await placeOf($)) === 'away') notes.push(AWAY_NOTE)
    else if ((await $.state.get(justHomeRef)).value) {
      notes.push(HOME_NOTE)
      await $.state.set(justHomeRef, false)
    }
    return next(notes.length ? { ...e, context: [...(e.context ?? []), ...notes] } : e)
  })

  // A message from the phone while home: one line at the end of the reply (picker, 2026-10-04).
  on('turn.complete', async ($, e, next) => {
    const r = await next(e)
    if (e.agentId !== undefined || e.reason !== 'answer') return r
    if (lastOrigin === 'bridge' && (await placeOf($)) === 'home') return { ...r, text: PHONE_LINE }
    return r
  })

  // The switch arriving from another session's scope modes: applied, and taken, so it never reaches
  // the model as a message. The plugin field is the sender's claim; the worst a forged one can do
  // is switch where this session delivers, which the band then shows.
  on('session.receive', async ($, e, next) => {
    const origin = e.origin as { plugin?: string }
    if (origin.plugin === MOD && (e.text === AWAY_TEXT || e.text === HOME_TEXT)) {
      await setPlace($, e.text === AWAY_TEXT ? 'away' : 'home')
      return { consumed: `scope-modes: switched to ${e.text === AWAY_TEXT ? 'away' : 'home'} from another session` }
    }
    return next(e)
  })

  on('tool.call', async ($, e, next) => {
    const input = e as unknown as Record<string, unknown>
    const tool = String(e.tool)
    const toolUseId = String(input.tool_use_id ?? '')

    if (tool === 'mcp__scope-modes__switch_to_build') {
      if ((await scopeOf($)) !== 'NO BUILD') return { result: 'No build is not on.', text: 'No build is not on.' }
      const change = String(input.change ?? '').trim().replace(/[.?]+$/, '') || 'make a change'
      let answer: string
      try {
        answer = await $.ui.ask(`Claude wants to ${change}. Switch to build?`, ['Yes', 'No'])
      } catch (err) {
        const text = `Dan was not asked (${msg(err)}): no build stays on.`
        return { result: text, text }
      }
      if (answer === 'Yes') {
        await setScope($, null)
        await $.ui.toast('No build is off.')
        return { result: 'Dan said yes: no build is off.', text: 'Dan said yes: no build is off.' }
      }
      const text = `Dan said no: no build stays on.${answer !== 'No' ? ` He wrote: ${answer}` : ''}`
      return { result: text, text }
    }

    const scope = await scopeOf($)
    const away = (await placeOf($)) === 'away'
    if (!scope && !away) return next(e)

    // A judge that throws refuses the call rather than letting it through: a tool call hook that
    // fails is skipped, which would run the very thing the mode is on to stop (L42).
    let refused: { deny: string } | undefined
    try {
      refused = await judge($, { tool, input, toolUseId, scope, away })
    } catch (err) {
      const modes = [...(scope ? [SCOPE_NAME[scope].toLowerCase()] : []), ...(away ? ['away'] : [])].join(' and ')
      refused = { deny: `Blocked: ${modes} is on and its check of this call failed (${msg(err)}), so the call did not run. Try it again; if it fails the same way, tell Dan.` }
    }
    return refused ?? next(e)
  })

  // A held row's button: asks Claude to do that one thing, now that Dan is here and chose it.
  on('ui.press', { plugin: 'mod-kit' }, async ($, e, next) => {
    const prefix = `${MOD}:held-`
    if (!e.element.startsWith(prefix)) return next(e)
    const id = e.element.slice(prefix.length)
    const held = await heldOf($)
    const item = held.find(h => h.id === id)
    if (!item) return { element: e.element }
    await $.state.set(heldRef, held.filter(h => h.id !== id))
    await showHeld($)
    await $.prompt.submit({ text: `Dan is back and picked this from what was held while he was away: ${item.label}. ${item.prompt}` })
    return { element: e.element }
  })

  // Winding down refuses the turn end until finished; Claude keeps watching CI and the deploy.
  on('classic.Stop', async ($, e, next) => {
    const left = await check($)
    if (left === null) return next(e)
    if (left.length === 0) {
      await finish($)
      return next(e)
    }
    return {
      block: `Winding down is not finished: ${left.join('; ')}. Keep watching CI and the deploy, fix only what blocks this issue's merge or deploy, and file anything else. If you need Dan, ask him with a question rather than ending the turn.`,
    }
  })

  // Off automatically at session end, never carried into a new session.
  on('session.end', async ($, e, next) => {
    await $.state.set(scopeRef, null)
    await $.state.set(targetRef, null)
    await $.state.set(placeRef, 'home')
    await $.state.set(justHomeRef, false)
    await $.state.set(heldRef, [] as ScopeModesHeld[])
    lastOrigin = undefined
    await showModes($)
    await showHeld($)
    return next(e)
  })
}
