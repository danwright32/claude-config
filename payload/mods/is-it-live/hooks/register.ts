import type { EngineInterface, Register } from 'claude-code'
import type { IsItLive, IsItLiveCard, IsItLiveOwed } from '../types/index.d.ts'
import { type CardInput, MOD, buttonId, cardOf, cardText, isOut, liveList, messageRow, pinnable, reasonToRefuse, stateOf, titleOf } from './card.ts'
import { type MergeCall, type Proof, TOOL, VIEW_FIELDS, WAIT_MS, letGoOf, mergeCallOf, nudgeOf, proofOf, refusalOf } from './merges.ts'
import { errorText, missingOf, skewNews } from './mod-kit/skew.ts'

// Is it live (claude-config#617). After a merge, and after checking the project's deploy, Claude
// calls this mod's card tool with what it found; the mod confirms the merge with GitHub itself (L161:
// a fact the system can read is checked, never taken from the model), keeps the card per repository
// so /live can list it in any later session, toasts it, and, once a card says live, pins a message
// for whoever asked in the band until Dan presses Mark sent (#1335). Spec agreed with Dan 2026-10-03, looks settled 2026-10-04.
//
// The card's result row is mod-kit's boxed card ($.modkit.card, #663), the blocked card's shape:
// only mod-kit draws a result row (tools/check-mod-shared-parts.sh, L613). The same lines go to the
// model as the tool's text result, which is also what the row shows after a reload.

const KEEP = 50
const CARDS = 'cards:'

// GitHub's repository names are one name in any case (gh answers for danwright32/POSTROLL as for
// danwright32/PostRoll), so every key a repository is kept or asked under is folded to one case
// (#702, #704): a card Claude typed in lowercase, and wind down asking in GitHub's own spelling,
// meet on the same key.
const fold = (repo: string) => repo.toLowerCase()
const storeKey = (repo: string) => `${CARDS}${fold(repo)}`

// The verdicts other mods read (#687), in $.state: a state ref names its plugin, while $.store is
// "this plugin's own" with no plugin named, so which store a read made from scope-modes' hook
// reaches is not stated anywhere (and a test's mocked store cannot tell). A card made in another
// session is therefore no verdict here, and wind down asks for the card again rather than guess.
const verdictsRef = { plugin: 'is-it-live', key: 'verdicts' } as const
const verdictKey = (repo: string, pr: number) => `${fold(repo)}#${pr}`

const run = async ($: EngineInterface, argv: string[], cwd?: string) => {
  try {
    const r = await $.process.run(argv, { timeoutMs: 20_000, ...(cwd ? { cwd } : {}) })
    return r.exitCode === 0 ? { out: r.stdout } : { error: (r.stderr || r.stdout || `exit ${r.exitCode}`).trim() }
  } catch (err) {
    return { error: String((err as Error)?.message ?? err) }
  }
}

// The store keys a repository's cards are under: its folded key, and any key in another case an
// earlier build wrote (it kept the repo as Claude typed it), so none of those cards is lost.
const keysOf = async ($: EngineInterface, repo: string): Promise<string[]> =>
  (await $.store.keys()).filter(k => k.startsWith(CARDS) && fold(k.slice(CARDS.length)) === fold(repo))

// A repository's cards, the newest card for each PR, newest first.
const cardsOf = async ($: EngineInterface, repo: string): Promise<IsItLiveCard[]> => {
  const all: IsItLiveCard[] = []
  for (const k of await keysOf($, repo)) {
    const v = await $.store.get(k)
    if (Array.isArray(v)) all.push(...(v as IsItLiveCard[]))
  }
  const newest = new Map<number, IsItLiveCard>()
  for (const c of all) if (!newest.has(c.pr) || (newest.get(c.pr) as IsItLiveCard).at < c.at) newest.set(c.pr, c)
  return [...newest.values()].sort((a, b) => b.at - a.at)
}

// Kept under the folded key first, and only then are the keys in another case taken away (L5).
const saveCards = async ($: EngineInterface, repo: string, cards: IsItLiveCard[]) => {
  const key = storeKey(repo)
  await $.store.set(key, cards.slice(0, KEEP))
  for (const k of await keysOf($, repo)) if (k !== key) await $.store.delete(k)
}

// The card a band button names, in whichever repository it is kept: Copy and Mark sent are pressed
// in any session, so the session folder's own repository is no guide (#704). A button id is the
// repo and PR with every other character a hyphen, so an unsent message wins a collision.
const cardOfButton = async ($: EngineInterface, id: string): Promise<IsItLiveCard | undefined> => {
  const found: IsItLiveCard[] = []
  for (const k of await $.store.keys()) {
    if (!k.startsWith(CARDS)) continue
    const v = await $.store.get(k)
    if (!Array.isArray(v)) continue
    for (const c of v as IsItLiveCard[]) if (c.message && fold(buttonId(c.repo, c.pr)) === fold(id)) found.push(c)
  }
  return found.find(c => c.sentAt === undefined) ?? found[0]
}

// Every account gh is logged in to on this Mac is Dan's (danwright32, and dwright-pennie, which owns
// repo-digest): an issue filed from any of them is his or Claude's (#704). Read through gh's own
// list with only the logins taken, so no token is ever read. When gh cannot list them, the active
// account alone counts, and the card says so.
type Accounts = { logins: string[]; note?: string } | { error: string }
const accountsOf = async ($: EngineInterface): Promise<Accounts> => {
  const all = await run($, ['gh', 'auth', 'status', '--hostname', 'github.com', '--json', 'hosts', '--jq', '.hosts["github.com"][].login'])
  const logins = (all.out ?? '').split('\n').map(s => s.trim()).filter(Boolean)
  if (all.error === undefined && logins.length) return { logins }
  const me = await run($, ['gh', 'api', 'user', '--jq', '.login'])
  const login = (me.out ?? '').trim()
  if (me.error !== undefined || !login) return { error: me.error ?? 'gh named no account' }
  return { logins: [login], note: `could not list every gh account on this Mac (${all.error ?? 'it listed none'}), so only the active one counted as Dan's` }
}

const pin = async ($: EngineInterface, c: IsItLiveCard): Promise<string | undefined> => {
  if (!pinnable(c) || !c.requester || !c.message) return undefined
  try {
    await $.modkit.bandRow(messageRow({ repo: c.repo, pr: c.pr, requester: c.requester, message: c.message }) as never)
    return undefined
  } catch (err) {
    return String((err as Error)?.message ?? err)
  }
}

// ---- #1244: the card after every merge (merges.ts says why) ----

// Per session, in $.state: a new session owes nothing for another's merges. A card is kept in the
// store, which every session shares, so a card another session made for the PR settles it too.
const owedRef = { plugin: 'is-it-live', key: 'owed' } as const
const interactiveRef = { plugin: 'is-it-live', key: 'interactive' } as const
const refusedRef = { plugin: 'is-it-live', key: 'refused' } as const
// An error as words, a member mod-kit's loaded copy lacks said as the one sentence naming the skew
// and its remedy (#1281, mod-kit's hooks/skew.ts, of which hooks/mod-kit/skew.ts is the copy).
const msg = (err: unknown) => errorText(err, MOD)

const owedOf = async ($: EngineInterface): Promise<IsItLiveOwed[]> => (await $.state.get(owedRef)).value ?? []

// What GitHub says about the PR a merge named, asked in the folder the session's shell is in, since
// a merge naming no repository is the checkout's there. Never the exit code: `| tail` makes a failed
// merge exit 0, and `--delete-branch` in a worktree fails after merging (L161).
const ask = async ($: EngineInterface, m: { selector?: string; named?: string }, cwd: string, since: number): Promise<Proof> => {
  const r = await run($, ['gh', 'pr', 'view', ...(m.selector !== undefined ? [m.selector] : []), ...(m.named ? ['--repo', m.named] : []), '--json', VIEW_FIELDS], cwd)
  return r.error !== undefined ? { kind: 'unproven', why: `GitHub could not be asked: ${r.error}` } : proofOf(r.out as string, since)
}

// The repository GitHub's own link for the PR names, read by mod-kit's one reader, as a card is kept.
const repoOfLink = async ($: EngineInterface, url: string, named: string | undefined): Promise<string | undefined> => {
  try {
    return (await $.modkit.linkRepo({ link: url })) ?? named
  } catch {
    return named
  }
}

// Each merge a Bash call made at once, read by mod-kit's command and gh readers: gh pr merge in any
// spelling mod-kit reads (behind rtk, sudo, an assignment), and the merge helper, found and read as
// the gh pr merge it runs by mod-kit alone (#1251).
// A mod-kit whose loaded copy lacks the merge helper's reader (#1281) leaves the gh merges read by
// the readers it has: whether a command ran the helper is the one thing not known, kept as `skew`.
const mergesIn = async ($: EngineInterface, command: string): Promise<{ calls: MergeCall[]; skew?: unknown }> => {
  const out: MergeCall[] = []
  let skew: unknown
  for (const c of await $.modkit.pipeline({ command })) {
    const direct = mergeCallOf(await $.modkit.gh({ words: c.words }))
    if (direct) {
      out.push(direct)
      continue
    }
    try {
      const viaHelper = mergeCallOf(await $.modkit.mergeHelper(c))
      if (viaHelper) out.push(viaHelper)
    } catch (err) {
      if (missingOf(err)?.kind !== 'member') throw err
      skew = err
    }
  }
  return { calls: out, ...(skew === undefined ? {} : { skew }) }
}

// What each merge in a finished Bash call owes, kept, and the line its result carries.
const afterMerges = async ($: EngineInterface, calls: MergeCall[], at: number, how: { failed: boolean; background: boolean; agent: boolean }): Promise<string[]> => {
  const cwd = await $.session.cwd()
  const lines: string[] = []
  const added: IsItLiveOwed[] = []
  for (const m of calls) {
    const named = m.named ?? undefined
    const p: Proof = m.named === null ? { kind: 'unproven', why: 'the repository it names could not be read' } : await ask($, { ...(m.selector !== undefined ? { selector: m.selector } : {}), ...(named ? { named } : {}) }, cwd, at)
    let o: IsItLiveOwed | undefined
    if (p.kind === 'merged') {
      const repo = await repoOfLink($, p.url, named)
      o = { key: repo ? `${fold(repo)}#${p.pr}` : `#${p.pr}@${at}`, how: 'merged', pr: p.pr, at, cwd, ...(repo ? { repo } : {}) }
    } else if (m.pr === undefined || p.kind === 'closed' || (p.kind === 'open' && !how.background)) {
      // Merged nothing (refused, still open, closed), or names no number to hold it by.
      o = undefined
    } else if (how.background) {
      o = { key: `wait:${named ?? cwd}#${m.pr}@${at}`, how: 'waiting', pr: m.pr, at, cwd, ...(m.selector !== undefined ? { selector: m.selector } : {}), ...(named ? { named, repo: named } : {}) }
    } else if (p.kind === 'unproven' && !how.failed) {
      o = { key: named ? `${named}#${m.pr}` : `#${m.pr}@${at}`, how: 'unproven', pr: m.pr, at, cwd, why: p.why, ...(named ? { repo: named } : {}) }
    }
    if (!o) continue
    added.push(o)
    lines.push(nudgeOf(o, how.agent))
  }
  if (added.length) {
    const keys = new Set(added.map(o => o.key))
    await $.state.set(owedRef, [...(await owedOf($)).filter(o => !keys.has(o.key)), ...added])
  }
  return lines
}

// Whether a card made at or after the merge is kept for it: under its repository, by this session
// or any other. A merge whose repository was not read is settled only by a card this session made
// for its number, the card Claude makes when told about it; a card another session kept for some
// other repository's PR of that number is no card for it (lessons review of #1244).
const carded = async ($: EngineInterface, o: IsItLiveOwed): Promise<boolean> => {
  if (o.repo) return (await cardsOf($, o.repo)).some(c => c.pr === o.pr && c.at >= o.at)
  const verdicts = (await $.state.get(verdictsRef)).value ?? {}
  return Object.entries(verdicts).some(([k, v]) => k.endsWith(`#${o.pr}`) && v.at >= o.at)
}

// The merges still owed a card at a turn end: a background merge GitHub now says merged becomes
// owed, one closed or past its wait is let go, and a merge with a card is settled.
const owedNow = async ($: EngineInterface): Promise<IsItLiveOwed[]> => {
  const now = await $.clock.now()
  const kept: IsItLiveOwed[] = []
  for (const o of await owedOf($)) {
    let x: IsItLiveOwed | undefined = o
    if (o.how === 'waiting') {
      if (now - o.at > WAIT_MS) {
        $.ui.log(`is-it-live: stopped asking GitHub about #${o.pr}, merged in the background, after ${WAIT_MS / 3_600_000} hours`, { to: 'debug' })
        continue
      }
      const p = await ask($, o, o.cwd, o.at)
      if (p.kind === 'closed') continue
      if (p.kind === 'merged') {
        const repo = await repoOfLink($, p.url, o.named)
        x = { key: repo ? `${fold(repo)}#${p.pr}` : `#${p.pr}@${o.at}`, how: 'merged', pr: p.pr, at: o.at, cwd: o.cwd, ...(repo ? { repo } : {}) }
      }
    }
    if (x.how !== 'waiting' && (await carded($, x))) continue
    kept.push(x)
  }
  await $.state.set(owedRef, kept)
  return kept.filter(o => o.how !== 'waiting')
}

// #771: the card's facts showed up to four times after a merge, the last being Claude's own reply
// restating it. Said in the tool's description and again in every answer.
const SEEN = 'Dan has already seen this card in the chat, drawn in full: do not restate any of it in your reply, and add no sentence that repeats it.'

const DESCRIPTION = [
  'Shows Dan the card for a merged pull request, once you have checked whether it is live.',
  'Call it after every merge: first while the deploy runs (deploy "deploying"), and again once you have checked it.',
  'deploy is "live" only when you confirmed the change itself is live (say how in checked); "failed" or "unreachable" when you could not confirm it (say why in checked); "none" when the project has no recorded deploy step.',
  'changed: what changed, in 2 to 3 plain sentences. see: the direct link and the exact clicks to see it.',
  'requester and message ONLY when someone other than Dan asked: an issue another person reported (via "issue" with its number), a pasted Slack thread ("slack"), or a person Dan named ("named"). The message is in Dan\'s voice, with no dashes.',
  'The message tells them the change is live, so Dan is shown it only once a card for that PR says "live", or "none" (with no deploy step, merging is going live): it is required on those calls, and one passed on an earlier call ("deploying", "failed", "unreachable") is held until then.',
  SEEN,
].join(' ')

const SCHEMA = {
  type: 'object',
  properties: {
    repo: { type: 'string', description: 'owner/name' },
    pr: { type: 'integer' },
    deploy: { type: 'string', enum: ['live', 'deploying', 'failed', 'unreachable', 'none'] },
    checked: { type: 'string' },
    changed: { type: 'string' },
    see: { type: 'object', properties: { link: { type: 'string' }, clicks: { type: 'array', items: { type: 'string' } } }, required: ['link', 'clicks'] },
    requester: { type: 'object', properties: { name: { type: 'string' }, via: { type: 'string', enum: ['issue', 'slack', 'named'] }, issue: { type: 'integer' } }, required: ['name', 'via'] },
    message: { type: 'string' },
  },
  required: ['repo', 'pr', 'deploy', 'changed', 'see'],
}

export const register: Register = on => {
  // Wind down (scope-modes, #687) finishes only on what the card says, never on Claude's report.
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    const isItLive: IsItLive = {
      verdict: async ({ repo, pr }) => {
        if (typeof repo !== 'string' || !/^[\w.-]+\/[\w.-]+$/.test(repo)) throw new Error(`is-it-live: repo must be owner/name, not ${JSON.stringify(repo)}`)
        if (!Number.isInteger(pr) || pr <= 0) throw new Error(`is-it-live: pr must be the pull request number, not ${JSON.stringify(pr)}`)
        const all = (await built.state.get(verdictsRef)).value ?? {}
        const key = verdictKey(repo, pr)
        if (Object.prototype.hasOwnProperty.call(all, key)) return all[key] ?? null
        // A verdict an earlier build kept under the repo as Claude typed it, kept over a hot reload.
        const other = Object.keys(all).find(k => fold(k) === key)
        return other === undefined ? null : (all[other] ?? null)
      },
    }
    return { ...built, isItLive }
  })

  on('session.start', async ($, e, next) => {
    // A turn end is refused for a missing card only where somebody is at the prompt to see it (#1244).
    await $.state.set(interactiveRef, e.isInteractive === true)
    await $.tool.register({ name: 'card', description: DESCRIPTION, inputSchema: SCHEMA })
    await $.command.register({ name: 'live', description: "This project's recent change cards, and the messages not yet sent." })
    return next(e)
  })

  // Answered here and never passed down, so the guards beneath (the secret guard) are asked through
  // mod-kit's screen before the card or its message is kept, toasted or pinned with Copy (#707).
  on('tool.call', { tool: TOOL }, async ($, e) => {
    const refused = await $.modkit.screen(e)
    if (refused) return refused
    const { tool: _t, tool_use_id: toolUseId, agentId: _a, consent: _c, ...raw } = e as unknown as Record<string, unknown>
    const input = raw as unknown as CardInput
    const why = reasonToRefuse(input)
    if (why) return { deny: `No card: ${why}` }

    // The merge, from GitHub: a card for an unmerged change would be the false "done" it exists to stop.
    const pr = await run($, ['gh', 'pr', 'view', String(input.pr), '--repo', input.repo, '--json', 'state,title,url'])
    if (pr.error !== undefined) return { deny: `No card: could not confirm #${input.pr} is merged (${pr.error}).` }
    let facts: { state?: string; title?: string; url?: string }
    try {
      facts = JSON.parse(pr.out as string)
    } catch {
      return { deny: `No card: GitHub's answer about #${input.pr} could not be read.` }
    }
    if (facts.state !== 'MERGED') {
      // GitHub says it never merged, so a merge this session could not confirm for it is settled
      // (#1244): one whose repository was not read, or was read as this one.
      if (facts.state === 'OPEN' || facts.state === 'CLOSED') {
        const left = (await owedOf($)).filter(o => !(o.pr === input.pr && o.how === 'unproven' && (!o.repo || fold(o.repo) === fold(input.repo))))
        await $.state.set(owedRef, left)
      }
      return { deny: `No card: #${input.pr} is ${String(facts.state ?? 'unknown').toLowerCase()}, not merged.` }
    }

    // An issue Dan or Claude filed is filed from Dan's own account, and gets no message (the spec).
    const notes: string[] = []
    let requester = input.requester
    let message = input.message
    if (requester?.via === 'issue') {
      const issue = await run($, ['gh', 'issue', 'view', String(requester.issue), '--repo', input.repo, '--json', 'author'])
      let author: string | undefined
      try {
        author = issue.out !== undefined ? (JSON.parse(issue.out) as { author?: { login?: string } }).author?.login : undefined
      } catch {
        author = undefined
      }
      const mine = author ? await accountsOf($) : undefined
      if (!author || !mine || 'error' in mine) return { deny: `No card: could not read who filed issue #${requester.issue} (${issue.error ?? (mine && 'error' in mine ? mine.error : undefined) ?? 'no author in the answer'}).` }
      if (mine.note) notes.push(`Who filed issue #${requester.issue}: is it live ${mine.note}.`)
      // GitHub logins are one name in any case.
      if (mine.logins.some(l => fold(l) === fold(author as string))) {
        notes.push(`The message for ${requester.name} was dropped: issue #${requester.issue} was filed from your own account, so Dan or you asked for it.`)
        requester = undefined
        message = undefined
      }
    }

    const state = stateOf(input.deploy)
    const title = facts.title ?? `#${input.pr}`
    const now = await $.clock.now()
    // Kept under the repository as GitHub's own link names it, so a card Claude typed in another
    // case or under an old name is found by /live, by Copy and Mark sent, and by wind down (#702).
    // The link is read by mod-kit's one reader of a github.com link (#961); one it cannot read keeps
    // the card under the repository Claude gave, and says so.
    let linked: string | null = null
    try {
      linked = facts.url ? await $.modkit.linkRepo({ link: facts.url }) : null
    } catch (err) {
      notes.push(`GitHub's link for #${input.pr} could not be read (${String((err as Error)?.message ?? err)}), so the card is kept under ${input.repo} as given.`)
    }
    const repo = linked ?? input.repo
    const had = await cardsOf($, repo)
    const before = had.find(c => c.pr === input.pr)
    const kept: IsItLiveCard = { repo, pr: input.pr, title, url: facts.url ?? '', state, at: now }
    if (requester && message) {
      kept.requester = requester
      kept.message = message
      // A message already marked sent stays sent only while it is the same message.
      if (before?.sentAt !== undefined && before.message === message) kept.sentAt = before.sentAt
    } else if (before?.requester && before.message) {
      // A card naming nobody leaves the message an earlier card owed as it was, sent or not: it
      // waits until Dan presses Mark sent (#704), never until the next card. That holds too when
      // this card's requester was dropped as Dan's own, since the earlier one asked for something
      // else; Claude is told it still waits, beside the note that this card's was dropped.
      kept.requester = before.requester
      kept.message = before.message
      if (before.sentAt !== undefined) kept.sentAt = before.sentAt
      else if (input.requester) notes.push(`The earlier message for ${before.requester.name} still waits until Dan marks it sent.`)
    }
    await saveCards($, repo, [kept, ...had.filter(c => c.pr !== input.pr)])
    const verdicts = (await $.state.get(verdictsRef)).value ?? {}
    await $.state.set(verdictsRef, { ...verdicts, [verdictKey(repo, input.pr)]: { state, at: now } })
    // Taken out of the band when the card carries no message for it, or holds it until live (#1335).
    if (!kept.message || !pinnable(kept)) await $.modkit.clearBandRow({ mod: MOD, id: buttonId(repo, input.pr) }).catch(() => undefined)
    const unpinned = await pin($, kept)
    if (unpinned) notes.push(`The message for ${kept.requester?.name} could not be pinned in the band (${unpinned}); /live lists it.`)
    // Who a held message is for: the one this card keeps, or the requester this call named before
    // writing it, whose message the live call owes. A message Dan marked sent waits for nothing.
    const waiting = isOut(state) || kept.sentAt !== undefined ? undefined : (kept.requester ?? requester)
    if (waiting)
      notes.push(`The message for ${waiting.name} is held, not shown to Dan, until a card for #${input.pr} says live: once you confirm it is live, call this again with deploy "live"${kept.message ? '' : ' and the message'}.`)

    const { requester: _r, message: _m, ...rest } = input
    const shown = { ...rest, ...(waiting ? { requester: waiting } : {}), state, title, url: kept.url }
    try {
      await $.modkit.card({ toolUseId: String(toolUseId ?? ''), ...cardOf(shown) })
    } catch (err) {
      notes.push(`The card could not be drawn boxed (${String((err as Error)?.message ?? err)}), so it shows as text.`)
    }
    $.ui.toast(titleOf(state, title))
    return {
      result: cardText(shown),
      context: [...notes, SEEN],
    }
  })

  // #1244: a Bash call that merges carries a line saying to show the card, once GitHub says what
  // the merge did. Passed down first and changed only by that line, so every guard beneath still
  // judges the call; a call refused before it ran merged nothing.
  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const input = e as unknown as Record<string, unknown>
    const command = String(input.command ?? '')
    // No merge spelling mod-kit reads lacks the word, so most calls are passed without reading.
    if (!/merge/i.test(command)) return next(e)
    const at = await $.clock.now()
    const done = await next(e)
    if (done.deny !== undefined) return done
    try {
      const { calls, skew } = await mergesIn($, command)
      // Said where Claude reads it on each such call, since a merge this missed would go unseen; Dan
      // is told once (#1281).
      const unread: string[] = []
      if (skew !== undefined) {
        const news = skewNews(skew, MOD)
        if (news) $.ui.toast(news)
        unread.push(`is it live could not tell whether this command also ran the merge helper (${msg(skew)}). If it merged a pull request, show Dan its is it live card: load the card tool with ToolSearch with the query "select:${TOOL}".`)
      }
      if (!calls.length) return unread.length ? { ...done, context: [...(done.context ?? []), ...unread] } : done
      const background = input.run_in_background === true || typeof (done.result as { backgroundTaskId?: unknown } | undefined)?.backgroundTaskId === 'string'
      const lines = [...(await afterMerges($, calls, at, { failed: done.isError === true, background, agent: e.agentId !== undefined })), ...unread]
      return lines.length ? { ...done, context: [...(done.context ?? []), ...lines] } : done
    } catch (err) {
      // Said where Claude reads it: a merge this missed would otherwise go unseen (fail loud).
      $.ui.log(`is-it-live: could not read whether a Bash call merged a PR: ${msg(err)}`, { to: 'debug' })
      return { ...done, context: [...(done.context ?? []), `is it live could not tell whether this command merged a pull request (${msg(err)}). If it did, show Dan its is it live card: load the card tool with ToolSearch with the query "select:${TOOL}".`] }
    }
  })

  // #1244: the turn does not end while a PR merged in this session has no card. Asked after the
  // hooks beneath (wind down, the overnight driver), whose block is kept beside this one. Refused
  // once per merge in a chain of turn ends, so a card that cannot be made (GitHub not answering)
  // never traps the turn, a sleeping worker's included: the next end in the chain goes ahead, said.
  on('classic.Stop', async ($, e, next) => {
    const r = await next(e)
    if ((await $.state.get(interactiveRef)).value !== true) return r
    let owed: IsItLiveOwed[]
    try {
      owed = await owedNow($)
    } catch (err) {
      $.ui.toast(`Is it live could not check this turn's merges for a card: ${msg(err)}`)
      return r
    }
    if (!owed.length) return r
    const held = (await $.state.get(refusedRef)).value
    const before = e.stop_hook_active && held ? held : { keys: [], told: [] }
    const fresh = owed.filter(o => !before.keys.includes(o.key))
    if (!fresh.length) {
      const untold = owed.filter(o => !before.told.includes(o.key))
      if (untold.length) {
        $.ui.toast(letGoOf(untold))
        await $.state.set(refusedRef, { keys: before.keys, told: [...before.told, ...untold.map(o => o.key)] })
      }
      return r
    }
    await $.state.set(refusedRef, { keys: [...before.keys, ...fresh.map(o => o.key)], told: before.told })
    const ours = refusalOf(owed)
    return { ...r, block: r.block ? `${r.block}\n\n${ours}` : ours }
  })

  // #771: the call's own row is Claude Code's echo of the tool's input, which carried every fact the
  // card under it shows (the changed text, checked, see, the message). Drawn naming the change
  // alone, so the card is the one place they are read. A call missing either field keeps its whole
  // row, so the refusal under it reads against what was sent (and the engine is never handed a
  // field left undefined, which it cannot draw).
  on('ui.render', { component: 'ToolUse', props: { tool: TOOL } }, ($, e, next) => {
    const input = e.props.input as { repo?: unknown; pr?: unknown } | null | undefined
    if (typeof input?.repo !== 'string' || typeof input?.pr !== 'number') return next(e)
    return next({ ...e, props: { ...e.props, input: { repo: input.repo, pr: input.pr } } })
  })

  // Copy and Mark sent, on any message this mod pinned, pressed by a click or by /press (#939):
  // mod-kit raises both as modkit.press. One hook for all of them: the buttons are named after their
  // card, so they cannot be listed when the module loads.
  on('modkit.press', async ($, e, next) => {
    const m = new RegExp(`^${MOD}:(copy|sent)-(.+)$`).exec(String(e.element ?? ''))
    if (!m) return next(e)
    // A copy, or a card saved and its row cleared: well inside a noun's 10 s (#744), so the press is
    // answered once its work is done.
    const answered = { value: { isAnswered: true } }
    const [, verb, id] = m
    const c = await cardOfButton($, String(id))
    if (!c || !c.message) {
      $.ui.toast('That message is no longer kept.')
      return answered
    }
    if (verb === 'copy') {
      const r = await $.ui.copy({ text: c.message, surface: e.surface as never })
      if (!r.isCopied) $.ui.toast(`Not copied: ${r.reason}`)
    } else {
      const at = await $.clock.now()
      const cards = await cardsOf($, c.repo)
      await saveCards($, c.repo, cards.map(x => (x.pr === c.pr ? { ...x, sentAt: at } : x)))
      // The row is cleared under the id it was pinned with, which an earlier build may have spelled
      // in another case.
      await $.modkit.clearBandRow({ mod: MOD, id: String(id) })
      if (id !== buttonId(c.repo, c.pr)) await $.modkit.clearBandRow({ mod: MOD, id: buttonId(c.repo, c.pr) })
    }
    return answered
  })

  on('command.run', { command: 'live' }, async $ => {
    // owner/name from the session's origin, read by mod-kit's one reader (#951).
    // A reading that fails is said as that, never as a folder with no GitHub repository (#979 review).
    let repo: string | null
    try {
      const here = await $.session.repo()
      repo = here ? (await $.modkit.repo({ root: here.root, remote: here.remote })).github : null
    } catch (err) {
      return { text: `This session's repository could not be read (${String((err as Error)?.message ?? err)}), so its cards cannot be listed.` }
    }
    if (!repo) return { text: 'This folder has no GitHub repository, so it has no cards.' }
    // Cards are kept under the name GitHub's own link gives the repository, which after a rename is
    // not the name a checkout's origin may still carry, so GitHub is asked for its name now (it
    // follows renames). When it cannot be asked, the remote's name alone is read, and /live says so.
    const now = await run($, ['gh', 'repo', 'view', repo, '--json', 'nameWithOwner', '--jq', '.nameWithOwner'])
    const current = (now.out ?? '').trim()
    const names = [repo, ...(current && fold(current) !== fold(repo) ? [current] : [])]
    const all: IsItLiveCard[] = []
    for (const name of names) all.push(...(await cardsOf($, name)))
    // Both names are one repository, so a PR is one card: the newest, whichever name it is under.
    const byPr = new Map<number, IsItLiveCard>()
    for (const c of all) {
      const seen = byPr.get(c.pr)
      if (!seen || c.at > seen.at) byPr.set(c.pr, c)
    }
    // A message waits until Dan presses Mark sent (#704), so one an older card under the other name
    // still owes is not dropped with that card: it is listed with the newest, and pinned from the
    // card that holds it, which is the one Mark sent then finds.
    const owes = (c: IsItLiveCard) => Boolean(c.requester && c.message && c.sentAt === undefined)
    const shown = [...byPr.values()]
      .map(c => ({ c, owing: owes(c) ? c : all.filter(o => o.pr === c.pr && owes(o)).sort((a, b) => b.at - a.at)[0] }))
      .sort((a, b) => b.c.at - a.c.at)
    // Newest first across both names, as cardsOf gives one name's: the band pins in this order.
    // Every message not yet sent whose change is out is pinned again, so Copy and Mark sent are at
    // hand in any session; one whose change is not is held (#1335). Whether it is out is the newest
    // card's state for the PR, as the list below says, wherever the message is kept.
    for (const { c, owing } of shown) if (owing) await pin($, { ...owing, state: c.state })
    const cards = shown.map(({ c, owing }) => (owing && owing !== c ? { ...c, requester: owing.requester, message: owing.message, sentAt: undefined } : c))
    const unasked = now.error !== undefined ? `\n\nGitHub could not be asked for the name this repository has now (${now.error}), so any cards kept under another name for it may be missing.` : ''
    return { text: liveList(cards) + unasked }
  })
}
