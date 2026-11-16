/**
 * Sleep mode's rule for the Chrome tools (#2064): a session may check its own work in the browser,
 * in a tab it created, on a test host. Pure functions: register.ts keeps the record of tabs and
 * reads the project's list, overnight.ts hands every mcp__claude-in-chrome__ call here.
 *
 * - A test host is the testing exception's local rule exactly: localhost, 127.0.0.1, [::1], or a
 *   name ending .localhost or .test. A project may list hosted test hosts on one line of its
 *   committed CLAUDE.md, "Sleep mode test hosts: qa.example.dev, staging.example.dev", each needing
 *   a test label (staging, dev, test, qa, sandbox, preview) before its last label, so a real account
 *   can never be listed as one.
 * - The record holds only tabs a tabs_create_mcp result announced on its first line, with the host
 *   each one's page is on, read from the LAST Tab Context block of every result (the extension
 *   appends the real one after any page text, so page text cannot forge it). A call that may move
 *   the page (a navigate, a click, typing, a form fill, a script) leaves its tab on no known host
 *   until a result says where it is. Inside one browser_batch, where no result arrives between
 *   items, nothing more runs on that tab after such an action until a navigate to a test host.
 * - A link clicked in the session's own tab can open a second tab in its group, which the session
 *   has to close (#3099). A second record holds the tabs every list of the group has named, and
 *   the ones first named after the session's own action in a tab it created (groupAfter). Such a
 *   tab can be closed and nothing more: its page is wherever the link led. A tab that was in the
 *   group before, or that appears with no action of the session behind it, is never one.
 * - Anything reaching past the session's tabs (recordings saved to disk, local files sent to a page,
 *   saved workflows, another browser) and any tool nobody listed here is refused.
 *
 * Each refusal reads after "so this did not", like every other overnight refusal.
 */

const C = 'mcp__claude-in-chrome__'

/** The tabs this session created, by tab id, with the host each one's page was last seen on. */
export type BrowserTabs = Record<string, { host: string | null }>
/**
 * The project's hosted test hosts, or why its CLAUDE.md on the default branch could not be read
 * (#2146). Unreadable lists no host, as an empty list does, but is said as not known, never as the
 * host being unlisted (L11).
 */
export type TestHosts = readonly string[] | { unreadable: string }
/**
 * What the session has read of its tab group beyond the tabs it created (#3099): every tab id a
 * result's list of the group has named, the ones its own action opened, and whether the next list
 * read is still the one that follows such an action.
 */
export type BrowserGroup = { seen: string[]; opened: string[]; watching: boolean }
/**
 * The tabs the session's own action opened, which it may close, or why that record could not be
 * read. Unreadable closes none of them, as an empty list does, but is said as not known, never as a
 * tab the session did not open (L11).
 */
export type OpenedTabs = readonly string[] | { unreadable: string }
/**
 * What a Chrome call is judged against: the record of tabs, the project's listed test hosts, and
 * the tabs the session's own action opened (none when not given).
 */
export type Browser = { tabs: BrowserTabs; listed: TestHosts; opened?: OpenedTabs }

const HOW_TO_LIST =
  "a test host is localhost, 127.0.0.1, [::1] or a name ending .localhost or .test, or a hosted one the project's CLAUDE.md on its default branch lists on a line reading Sleep mode test hosts: followed by the hosts"

const hostsOf = (listed: TestHosts): readonly string[] => ('unreadable' in listed ? [] : listed)

export const isTestHost = (host: string, listed: TestHosts): boolean => {
  const h = host.toLowerCase()
  if (!h) return false
  if (h === 'localhost' || h === '127.0.0.1' || h === '[::1]') return true
  if (h.endsWith('.localhost') || h.endsWith('.test')) return true
  return hostsOf(listed).some(l => l.toLowerCase() === h)
}

// Why a host that is not a test host is refused: not on the list, or the list not read (#2146).
const notTestHost = (listed: TestHosts) =>
  'unreadable' in listed
    ? `which is not a local test host, and whether the project lists it as a hosted one is not known, because ${listed.unreadable}`
    : 'which is not a test host'

/**
 * The hosts the default branch's CLAUDE.md lists, from git show's answer for `ref` in the checkout
 * at `where` (#2146). A branch carrying no CLAUDE.md lists nothing, in either of git's wordings (the
 * second when the working copy has one); any other failure is unreadable, with git's own reason.
 */
export const committedHosts = (ref: string, where: string, shown: { exitCode: number; stdout: string; stderr: string }): TestHosts => {
  if (shown.exitCode === 0) return listedHosts(shown.stdout)
  if (/^fatal: path '[^']*' (?:does not exist in|exists on disk, but not in) '/m.test(shown.stderr)) return []
  const said = shown.stderr.trim()
  return { unreadable: `CLAUDE.md on ${ref} in ${where} could not be read (${said || `git show exited ${shown.exitCode} and said nothing`})` }
}

const TEST_LABEL = /^(staging|dev|test|qa|sandbox|preview)(\d+|-[a-z0-9-]+)?$/

/** The hosts the project's one "Sleep mode test hosts:" line lists, each carrying a test label. */
export const listedHosts = (claudeMd: string): string[] => {
  const line = /^Sleep mode test hosts:(.*)$/m.exec(claudeMd)
  if (!line) return []
  return (line[1] ?? '')
    .split(/[\s,]+/)
    .map(e => e.replace(/`/g, '').replace(/:\d+$/, '').toLowerCase())
    .filter(e => {
      const labels = e.split('.')
      return labels.length > 1 && labels.every(Boolean) && labels.slice(0, -1).some(l => TEST_LABEL.test(l))
    })
}

/**
 * The host a navigate opens, read as Chrome reads it: a web address without a scheme is https, and
 * any scheme but http and https names no host, which refuses.
 */
export const navigateHost = (url: string): string | null => {
  const u = url.trim()
  const scheme = /^([a-z][a-z0-9+.-]*):(?!\d)/i.exec(u)
  if (scheme && !/^https?$/i.test(scheme[1] ?? '')) return null
  try {
    return new URL(scheme ? u : `https://${u}`).hostname.toLowerCase() || null
  } catch {
    return null
  }
}

const short = (tool: string) => (tool.startsWith(C) ? tool.slice(C.length) : tool)
const tabOf = (input: Record<string, unknown>): string | null => {
  const t = input.tabId
  if (typeof t === 'number' && Number.isFinite(t)) return String(t)
  if (typeof t === 'string' && t.trim()) return t.trim()
  return null
}

const FREE = new Set(['tabs_context_mcp', 'tabs_create_mcp', 'list_connected_browsers'])
const ON_PAGE = new Set(['computer', 'read_page', 'find', 'form_input', 'get_page_text', 'javascript_tool', 'read_console_messages', 'read_network_requests', 'resize_window', 'upload_image'])
/** computer actions that cannot move the page; any other, or one nobody listed, may. */
const STILL = new Set(['screenshot', 'zoom', 'wait', 'scroll', 'scroll_to', 'hover'])

/** A call that acts on its page (a click, typing, a form fill, a script), and so can make it open a tab. */
const acts = (name: string, input: Record<string, unknown>) =>
  name === 'form_input' || name === 'javascript_tool' || (name === 'computer' && !STILL.has(String(input.action ?? '')))
const moves = (name: string, input: Record<string, unknown>) => name === 'navigate' || acts(name, input)

const notCreated = (tool: string, tab: string) =>
  `use ${tool} on tab ${tab}, which this session did not create (a tab made with tabs_create_mcp can be used on a test host)`
const unnamed = (tool: string) => `use ${tool} without naming a tab this session created`
// A close reaches one tab more than the rest (#3099), so its refusal says both ways a tab is
// closable, or that whether the session's own action opened it could not be read.
const notItsToClose = (tool: string, tab: string, opened: OpenedTabs) =>
  'unreadable' in opened
    ? `use ${tool} on tab ${tab}, which this session did not create, and whether its own action opened it is not known, because ${opened.unreadable}`
    : `use ${tool} on tab ${tab}, which this session did not create and did not see appear in its tab group after its own action (it can close a tab made with tabs_create_mcp, or one first listed in its tab group after its own click, typing, form fill or script in a tab it created)`

const navigateRefusal = (tool: string, input: Record<string, unknown>, tabs: BrowserTabs, listed: TestHosts) => {
  const tab = tabOf(input)
  if (!tab) return unnamed(tool)
  if (!tabs[tab]) return notCreated(tool, tab)
  const url = String(input.url ?? '').trim()
  if (url === 'back' || url === 'forward') return `go ${url} in the browser, where the page it lands on cannot be known before it loads`
  const host = navigateHost(url)
  if (!host) return `open ${url} in the browser, which is not a web address`
  if (!isTestHost(host, listed)) return `open ${host} in the browser, ${notTestHost(listed)}${'unreadable' in listed ? '' : ` (${HOW_TO_LIST})`}`
  return undefined
}

const onPageRefusal = (tool: string, input: Record<string, unknown>, tabs: BrowserTabs, listed: TestHosts) => {
  const tab = tabOf(input)
  if (!tab) return unnamed(tool)
  const seen = tabs[tab]
  if (!seen) return notCreated(tool, tab)
  if (seen.host === null) return `use ${tool} on tab ${tab}, whose page is not on a test host`
  if (!isTestHost(seen.host, listed)) return `use ${tool} on tab ${tab}, whose page is on ${seen.host}, ${notTestHost(listed)}`
  return undefined
}

const oneRefusal = (name: string, input: Record<string, unknown>, tabs: BrowserTabs, listed: TestHosts, opened: OpenedTabs): string | undefined => {
  const tool = `${C}${name}`
  if (FREE.has(name)) return undefined
  if (name === 'navigate') return navigateRefusal(tool, input, tabs, listed)
  if (name === 'tabs_close_mcp') {
    const tab = tabOf(input)
    if (!tab) return unnamed(tool)
    // The one call an opened tab is good for (#3099): every other rule here reads tabs alone.
    return tabs[tab] || (!('unreadable' in opened) && opened.includes(tab)) ? undefined : notItsToClose(tool, tab, opened)
  }
  if (ON_PAGE.has(name)) return onPageRefusal(tool, input, tabs, listed)
  return `use ${tool}, which reaches past the tabs this session created (sleep mode lets the browser be used only in its own tabs on a test host)`
}

const batchRefusal = (input: Record<string, unknown>, b: Browser): string | undefined => {
  const tool = `${C}browser_batch`
  if (!Array.isArray(input.actions)) return `use ${tool} with no list of actions`
  const tabs: BrowserTabs = { ...b.tabs }
  const moved = new Set<string>()
  for (const item of input.actions as unknown[]) {
    const it = (item && typeof item === 'object' ? item : {}) as { name?: unknown; input?: unknown }
    const name = short(String(it.name ?? ''))
    const args = (it.input && typeof it.input === 'object' ? it.input : {}) as Record<string, unknown>
    if (name === 'browser_batch') return `use ${tool} inside a browser_batch`
    const tab = tabOf(args)
    // After a call that may have moved the page, the tab's host is unknown, so every later action on
    // it (typing and every other screen action included) waits for a navigate to a test host, which
    // reads the host again (Dan, 2026-11-03). Across calls, a result's Tab Context reads it instead.
    if (tab && moved.has(tab) && name !== 'navigate')
      return `use ${C}${name} on tab ${tab} after an action in the same batch that may have left the test host`
    const why = oneRefusal(name, args, tabs, b.listed, b.opened ?? [])
    if (why) return why
    if (name === 'navigate' && tab) {
      tabs[tab] = { host: navigateHost(String(args.url ?? '')) }
      moved.delete(tab)
    } else if (tab && moves(name, args)) moved.add(tab)
  }
  return undefined
}

/**
 * Why a Chrome call is refused while asleep, or undefined when it may run. No record of tabs means
 * none was created, so every call that needs one is refused.
 */
export const browserRefusal = (tool: string, input: Record<string, unknown>, browser?: Browser): string | undefined => {
  const b: Browser = browser ?? { tabs: {}, listed: [] }
  const name = short(tool)
  if (name === 'browser_batch') return batchRefusal(input, b)
  return oneRefusal(name, input, b.tabs, b.listed, b.opened ?? [])
}

const CREATED = /^Created new tab\. Tab ID: (\d+)/
const NAVIGATED = /^Navigated to (\S+)/
const TAB_LINE = /^\s*•\s*tabId (\d+): .*\("([^"]*)"\)\s*$/gm

/**
 * The group's tabs as a result's LAST Tab Context lists them, each id with its page's address, or
 * null when the result carries no list (a refused call, or one that failed before the browser).
 */
const listedTabs = (textBlocks: string[]): [id: string, url: string][] | null => {
  const all = textBlocks.join('\n')
  const at = all.lastIndexOf('Tab Context:')
  if (at < 0) return null
  return [...all.slice(at).matchAll(TAB_LINE)].flatMap(([, id, url]) => (id && url !== undefined ? [[id, url] as [string, string]] : []))
}

/** Whether a call acted on the page of a tab the session created, alone or as an item of a batch. */
const actedInOwnTab = (name: string, input: Record<string, unknown>, tabs: BrowserTabs): boolean => {
  if (name !== 'browser_batch') {
    const tab = tabOf(input)
    return !!tab && !!tabs[tab] && acts(name, input)
  }
  if (!Array.isArray(input.actions)) return false
  return (input.actions as unknown[]).some(item => {
    const it = (item && typeof item === 'object' ? item : {}) as { name?: unknown; input?: unknown }
    const args = (it.input && typeof it.input === 'object' ? it.input : {}) as Record<string, unknown>
    const inner = short(String(it.name ?? ''))
    return inner !== 'browser_batch' && actedInOwnTab(inner, args, tabs)
  })
}

/**
 * The record of the group after a Chrome call's result (#3099), given the tabs the session created
 * as they stand after that same result. A tab is opened by the session's own action when all of
 * these hold, and it may then be closed and nothing more:
 * - no list read before named it, and an earlier list exists to say so (the first list read is
 *   only what was already there);
 * - the session did not create it;
 * - it is first named by the list in the result of a call that acted on the page of a tab the
 *   session created, or by the next list read after that result, since a page can open a tab a
 *   moment after the click returns. A list after that one opens nothing.
 * A call whose result carries no list never ran in the browser as far as this can tell, so it
 * starts no watch. An opened tab leaves when a list stops naming it, or when its close's result
 * carries no list; having been seen, it is never opened again. Always a new record.
 */
export const groupAfter = (group: BrowserGroup | null, tabs: BrowserTabs, tool: string, input: Record<string, unknown>, textBlocks: string[]): BrowserGroup | null => {
  const name = short(tool)
  const listed = listedTabs(textBlocks)
  const had = (group?.opened ?? []).filter(id => !tabs[id])
  if (!listed) {
    if (!group) return null
    const closed = name === 'tabs_close_mcp' ? tabOf(input) : null
    return { seen: [...group.seen], opened: had.filter(id => id !== closed), watching: group.watching }
  }
  const ids = [...new Set(listed.map(([id]) => id))]
  const watching = actedInOwnTab(name, input, tabs)
  if (!group) return { seen: ids, opened: [], watching }
  const still = had.filter(id => ids.includes(id))
  const fresh = watching || group.watching ? ids.filter(id => !group.seen.includes(id) && !tabs[id]) : []
  return { seen: [...new Set([...group.seen, ...ids])], opened: [...still, ...fresh], watching }
}

/**
 * The record of tabs after a Chrome call's result: a created tab added, a closed one removed, a
 * call that may have moved its page leaving its tab on no known host, then every recorded tab the
 * result's last Tab Context names set to the host it shows. Always a new record.
 */
export const tabsAfter = (tabs: BrowserTabs, tool: string, input: Record<string, unknown>, textBlocks: string[]): BrowserTabs => {
  const next: BrowserTabs = Object.fromEntries(Object.entries(tabs).map(([k, v]) => [k, { host: v.host }]))
  const name = short(tool)
  const first = textBlocks[0] ?? ''
  if (name === 'tabs_create_mcp') {
    const made = CREATED.exec(first)
    if (made?.[1]) next[made[1]] = { host: null }
  }
  if (name === 'tabs_close_mcp') {
    const tab = tabOf(input)
    if (tab) delete next[tab]
  }
  const movedTabs: string[] = []
  if (name === 'browser_batch' && Array.isArray(input.actions)) {
    for (const item of input.actions as unknown[]) {
      const it = (item && typeof item === 'object' ? item : {}) as { name?: unknown; input?: unknown }
      const args = (it.input && typeof it.input === 'object' ? it.input : {}) as Record<string, unknown>
      const tab = tabOf(args)
      if (tab && moves(short(String(it.name ?? '')), args)) movedTabs.push(tab)
    }
  } else if (moves(name, input)) {
    const tab = tabOf(input)
    if (tab) movedTabs.push(tab)
  }
  for (const tab of movedTabs) if (next[tab]) next[tab] = { host: null }
  if (name === 'navigate') {
    const tab = tabOf(input)
    const went = NAVIGATED.exec(first)
    if (tab && next[tab] && went?.[1]) next[tab] = { host: navigateHost(went[1]) }
  }
  for (const [id, url] of listedTabs(textBlocks) ?? []) if (next[id]) next[id] = { host: navigateHost(url) }
  return next
}
