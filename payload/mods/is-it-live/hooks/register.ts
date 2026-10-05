import type { EngineInterface, Register } from 'claude-code'
import type { IsItLive, IsItLiveCard } from '../types/index.d.ts'
import { type CardInput, MOD, buttonId, cardOf, cardText, liveList, messageRow, reasonToRefuse, stateOf, titleOf } from './card.ts'

// Is it live (claude-config#617). After a merge, and after checking the project's deploy, Claude
// calls this mod's card tool with what it found; the mod confirms the merge with GitHub itself (L161:
// a fact the system can read is checked, never taken from the model), keeps the card per repository
// so /live can list it in any later session, toasts it, and pins a message for whoever asked in the
// band until Dan presses Mark sent. Spec agreed with Dan 2026-10-03, looks settled 2026-10-04.
//
// The card's result row is mod-kit's boxed card ($.modkit.card, #663), the blocked card's shape:
// only mod-kit draws a result row (tools/check-mod-shared-parts.sh, L613). The same lines go to the
// model as the tool's text result, which is also what the row shows after a reload.

const TOOL = `mcp__${MOD}__card`
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

// owner/name as GitHub's own link for the PR spells it: after a rename, the name it has now.
const repoOfUrl = (url: string | undefined): string | undefined => /^https:\/\/github\.com\/([\w.-]+\/[\w.-]+)\/pull\/\d+/.exec(url ?? '')?.[1]

const run = async ($: EngineInterface, argv: string[]) => {
  try {
    const r = await $.process.run(argv, { timeoutMs: 20_000 })
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

// owner/name from the origin remote, ssh or https.
const repoOf = (remote: string | null | undefined): string | undefined => {
  const m = /github\.com[:/]([\w.-]+\/[\w.-]+?)(?:\.git)?\/?$/.exec(remote ?? '')
  return m?.[1]
}

const pin = async ($: EngineInterface, c: IsItLiveCard): Promise<string | undefined> => {
  if (!c.requester || !c.message || c.sentAt !== undefined) return undefined
  try {
    await $.modkit.bandRow(messageRow({ repo: c.repo, pr: c.pr, requester: c.requester, message: c.message }) as never)
    return undefined
  } catch (err) {
    return String((err as Error)?.message ?? err)
  }
}

const DESCRIPTION = [
  'Shows Dan the card for a merged pull request, once you have checked whether it is live.',
  'Call it after every merge: first while the deploy runs (deploy "deploying"), and again once you have checked it.',
  'deploy is "live" only when you confirmed the change itself is live (say how in checked); "failed" or "unreachable" when you could not confirm it (say why in checked); "none" when the project has no recorded deploy step.',
  'changed: what changed, in 2 to 3 plain sentences. see: the direct link and the exact clicks to see it.',
  'requester and message ONLY when someone other than Dan asked: an issue another person reported (via "issue" with its number), a pasted Slack thread ("slack"), or a person Dan named ("named"). The message is in Dan\'s voice, with no dashes.',
  'The card is shown in the chat as it stands: add no sentence that repeats it.',
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
    await $.tool.register({ name: 'card', description: DESCRIPTION, inputSchema: SCHEMA })
    await $.command.register({ name: 'live', description: "This project's recent change cards, and the messages not yet sent." })
    return next(e)
  })

  on('tool.call', { tool: TOOL }, async ($, e) => {
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
    if (facts.state !== 'MERGED') return { deny: `No card: #${input.pr} is ${String(facts.state ?? 'unknown').toLowerCase()}, not merged.` }

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
        notes.push(`The message was dropped: issue #${requester.issue} was filed from your own account, so Dan or you asked for it.`)
        requester = undefined
        message = undefined
      }
    }

    const state = stateOf(input.deploy)
    const title = facts.title ?? `#${input.pr}`
    const now = await $.clock.now()
    // Kept under the repository as GitHub's own link names it, so a card Claude typed in another
    // case or under an old name is found by /live, by Copy and Mark sent, and by wind down (#702).
    const repo = repoOfUrl(facts.url) ?? input.repo
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
      // waits until Dan presses Mark sent (#704), never until the next card.
      kept.requester = before.requester
      kept.message = before.message
      if (before.sentAt !== undefined) kept.sentAt = before.sentAt
    }
    await saveCards($, repo, [kept, ...had.filter(c => c.pr !== input.pr)])
    const verdicts = (await $.state.get(verdictsRef)).value ?? {}
    await $.state.set(verdictsRef, { ...verdicts, [verdictKey(repo, input.pr)]: { state, at: now } })
    // Taken out of the band when the card carries no message for it.
    if (!kept.message) await $.modkit.clearBandRow({ mod: MOD, id: buttonId(repo, input.pr) }).catch(() => undefined)
    const unpinned = await pin($, kept)
    if (unpinned) notes.push(`The message for ${kept.requester?.name} could not be pinned in the band (${unpinned}); /live lists it.`)

    const shown = { ...input, state, title, url: kept.url }
    try {
      await $.modkit.card({ toolUseId: String(toolUseId ?? ''), ...cardOf(shown) })
    } catch (err) {
      notes.push(`The card could not be drawn boxed (${String((err as Error)?.message ?? err)}), so it shows as text.`)
    }
    $.ui.toast(titleOf(state, title))
    return {
      result: cardText(shown),
      context: [...notes, 'The card is shown in the chat as it stands: add no sentence that repeats it.'],
    }
  })

  // Copy and Mark sent, on any message this mod pinned. One hook for all of them: the buttons are
  // named after their card, so they cannot be listed when the module loads.
  on('ui.press', { plugin: 'mod-kit' }, async ($, e, next) => {
    const m = new RegExp(`^${MOD}:(copy|sent)-(.+)$`).exec(String(e.element ?? ''))
    if (!m) return next(e)
    const [, verb, id] = m
    const c = await cardOfButton($, String(id))
    if (!c || !c.message) {
      $.ui.toast('That message is no longer kept.')
      return { element: e.element }
    }
    if (verb === 'copy') {
      const r = await $.ui.copy({ text: c.message, surface: e.surface })
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
    return { element: e.element }
  })

  on('command.run', { command: 'live' }, async $ => {
    const repo = repoOf((await $.session.repo())?.remote)
    if (!repo) return { text: 'This folder has no GitHub repository, so it has no cards.' }
    // Cards are kept under the name GitHub's own link gives the repository, which after a rename is
    // not the name a checkout's origin may still carry, so GitHub is asked for its name now (it
    // follows renames). When it cannot be asked, the remote's name alone is read, and /live says so.
    const now = await run($, ['gh', 'repo', 'view', repo, '--json', 'nameWithOwner', '--jq', '.nameWithOwner'])
    const current = (now.out ?? '').trim()
    const names = [repo, ...(current && fold(current) !== fold(repo) ? [current] : [])]
    const byPr = new Map<string, IsItLiveCard>()
    for (const name of names) for (const c of await cardsOf($, name)) byPr.set(`${fold(c.repo)}#${c.pr}`, c)
    const cards = [...byPr.values()]
    // Every message not yet sent is pinned again, so Copy and Mark sent are at hand in any session.
    for (const c of cards) await pin($, c)
    const unasked = now.error !== undefined ? `\n\nGitHub could not be asked for the name this repository has now (${now.error}), so cards kept under another name for it are not listed.` : ''
    return { text: liveList(cards) + unasked }
  })
}
