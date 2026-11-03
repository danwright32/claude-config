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
 *   until a result says where it is.
 * - Anything reaching past the session's tabs (recordings saved to disk, local files sent to a page,
 *   saved workflows, another browser) and any tool nobody listed here is refused.
 *
 * Each refusal reads after "so this did not", like every other overnight refusal.
 */

const C = 'mcp__claude-in-chrome__'

/** The tabs this session created, by tab id, with the host each one's page was last seen on. */
export type BrowserTabs = Record<string, { host: string | null }>
/** What a Chrome call is judged against: the record of tabs, and the project's listed test hosts. */
export type Browser = { tabs: BrowserTabs; listed: readonly string[] }

const HOW_TO_LIST =
  "a test host is localhost, 127.0.0.1, [::1] or a name ending .localhost or .test, or a hosted one the project's CLAUDE.md on its default branch lists on a line reading Sleep mode test hosts: followed by the hosts"

export const isTestHost = (host: string, listed: readonly string[]): boolean => {
  const h = host.toLowerCase()
  if (!h) return false
  if (h === 'localhost' || h === '127.0.0.1' || h === '[::1]') return true
  if (h.endsWith('.localhost') || h.endsWith('.test')) return true
  return listed.some(l => l.toLowerCase() === h)
}

const TEST_LABEL = /^(staging|dev|test|qa|sandbox|preview)(\d+|-[a-z0-9-]+)?$/

/** The hosts the project's one "Sleep mode test hosts:" line lists, each carrying a test label. */
export const listedHosts = (claudeMd: string): string[] => {
  const line = /^Sleep mode test hosts:(.*)$/m.exec(claudeMd)
  if (!line) return []
  return line[1]
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
  if (scheme && !/^https?$/i.test(scheme[1])) return null
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

const moves = (name: string, input: Record<string, unknown>) =>
  name === 'navigate' || name === 'form_input' || name === 'javascript_tool' || (name === 'computer' && !STILL.has(String(input.action ?? '')))

const notCreated = (tool: string, tab: string) =>
  `use ${tool} on tab ${tab}, which this session did not create (a tab made with tabs_create_mcp can be used on a test host)`
const unnamed = (tool: string) => `use ${tool} without naming a tab this session created`

const navigateRefusal = (tool: string, input: Record<string, unknown>, tabs: BrowserTabs, listed: readonly string[]) => {
  const tab = tabOf(input)
  if (!tab) return unnamed(tool)
  if (!tabs[tab]) return notCreated(tool, tab)
  const url = String(input.url ?? '').trim()
  if (url === 'back' || url === 'forward') return `go ${url} in the browser, where the page it lands on cannot be known before it loads`
  const host = navigateHost(url)
  if (!host) return `open ${url} in the browser, which is not a web address`
  if (!isTestHost(host, listed)) return `open ${host} in the browser, which is not a test host (${HOW_TO_LIST})`
  return undefined
}

const onPageRefusal = (tool: string, input: Record<string, unknown>, tabs: BrowserTabs, listed: readonly string[]) => {
  const tab = tabOf(input)
  if (!tab) return unnamed(tool)
  const seen = tabs[tab]
  if (!seen) return notCreated(tool, tab)
  if (seen.host === null) return `use ${tool} on tab ${tab}, whose page is not on a test host`
  if (!isTestHost(seen.host, listed)) return `use ${tool} on tab ${tab}, whose page is on ${seen.host}, which is not a test host`
  return undefined
}

const oneRefusal = (name: string, input: Record<string, unknown>, tabs: BrowserTabs, listed: readonly string[]): string | undefined => {
  const tool = `${C}${name}`
  if (FREE.has(name)) return undefined
  if (name === 'navigate') return navigateRefusal(tool, input, tabs, listed)
  if (name === 'tabs_close_mcp') {
    const tab = tabOf(input)
    if (!tab) return unnamed(tool)
    return tabs[tab] ? undefined : notCreated(tool, tab)
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
    // After a call that may have moved the page, the page's own text, form fields and scripts wait
    // for a navigate back to a test host; the screen (a screenshot, a click, typing) carries on, as
    // a click does in its own call until its result says where the page went.
    if (tab && moved.has(tab) && name !== 'navigate' && name !== 'computer')
      return `use ${C}${name} on tab ${tab} after an action in the same batch that may have left the test host`
    const why = oneRefusal(name, args, tabs, b.listed)
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
  return oneRefusal(name, input, b.tabs, b.listed)
}

const CREATED = /^Created new tab\. Tab ID: (\d+)/
const NAVIGATED = /^Navigated to (\S+)/
const TAB_LINE = /^\s*•\s*tabId (\d+): .*\("([^"]*)"\)\s*$/gm

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
    if (made) next[made[1]] = { host: null }
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
    if (tab && next[tab] && went) next[tab] = { host: navigateHost(went[1]) }
  }
  const all = textBlocks.join('\n')
  const at = all.lastIndexOf('Tab Context:')
  if (at >= 0) {
    for (const m of all.slice(at).matchAll(TAB_LINE)) if (next[m[1]]) next[m[1]] = { host: navigateHost(m[2]) }
  }
  return next
}
