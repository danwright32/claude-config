// area-check-replay.ts: replay a real repository's last N days through the area check's own rules
// (payload/mods/area-check/hooks/rules.ts), each commit on the default branch standing in for one
// session, and report how many would have been held (claude-config#1508). The same measurement as
// the calibration on #1506, but judged by the mod's code itself rather than a script beside it (L107).
//
//   node tools/area-check-replay.ts <checkout> --repo <owner/name> [--account <gh account>]
//        [--days 30] [--names] [--fixture <file.ts>]
//
// What a commit stands for: the files it modified or renamed (a new file is never judged, decision 2),
// its own issues the #N its subject names (a squash title carries the issue and the pull request), and
// the growth ranking of its day, made at that day's last commit over the 90 days before it. Issues are
// today's open list: what was open on each day is not recoverable, which the report says.
//
// Read only: nothing in the checkout is changed, nothing is fetched (the report names the origin head
// it read, so a stale one shows). File names are printed only with --names, since a work repository's
// paths do not belong in this public repository's pull requests (L155). --fixture writes the replay's
// input, trimmed to what decides it, with the summary it gave, for the mod's own replay test.
//
// Exit codes, each distinct (L11): 0 replayed, 2 bad arguments, 3 a read failed (git, gh, the path
// reader), each said on stderr.
import { execFileSync } from 'node:child_process'
import { writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  GROWTH_DAYS,
  GROWTH_MIN,
  ISSUE_LIMIT,
  RULE_VERSION,
  SIZE_MIN,
  fileKind,
  issuesRead,
  parseLineCounts,
  parseNumstat,
  replay,
  sizeCandidates,
  toCached,
  type CachedIssue,
  type Growth,
  type ReplayInput,
} from '../payload/mods/area-check/hooks/rules.ts'

const here = dirname(fileURLToPath(import.meta.url))
const EXTRACTOR = join(here, '..', 'payload', 'hooks', 'lib', 'match-open-issues.py')

const fail = (code: number, why: string): never => {
  process.stderr.write(`area-check-replay: ${why}\n`)
  process.exit(code)
}

const args = process.argv.slice(2)
const flag = (name: string) => {
  const i = args.indexOf(name)
  if (i < 0) return undefined
  const v = args[i + 1]
  if (v === undefined || v.startsWith('--')) fail(2, `${name} needs a value`)
  args.splice(i, 2)
  return v
}
const names = args.includes('--names')
if (names) args.splice(args.indexOf('--names'), 1)
const repo = flag('--repo')
const account = flag('--account')
const days = Number(flag('--days') ?? 30)
const fixture = flag('--fixture')
const checkout = args[0]
if (!checkout || args.length !== 1 || !repo || !/^[\w.-]+\/[\w.-]+$/.test(repo) || !Number.isInteger(days) || days < 1)
  fail(2, 'usage: node tools/area-check-replay.ts <checkout> --repo <owner/name> [--account <gh account>] [--days 30] [--names] [--fixture <file.ts>]')

const run = (cmd: string, argv: string[], opts: { input?: string; env?: NodeJS.ProcessEnv; ok?: number[] } = {}): string => {
  try {
    return execFileSync(cmd, argv, { input: opts.input, env: opts.env ?? process.env, maxBuffer: 512 * 1024 * 1024, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] })
  } catch (err) {
    const e = err as { status?: number; stdout?: string; stderr?: string }
    if (opts.ok?.includes(e.status ?? -1)) return e.stdout ?? ''
    return fail(3, `${cmd} ${argv.slice(0, 4).join(' ')} failed: ${String(e.stderr ?? err).trim().split('\n')[0]}`)
  }
}
const git = (argv: string[], ok?: number[]) => run('git', ['-C', checkout as string, ...argv], ok ? { ok } : {})

// The default branch as origin names it.
const def = git(['symbolic-ref', '--short', 'refs/remotes/origin/HEAD']).trim()
if (!def.startsWith('origin/')) fail(3, `origin names no default branch in ${checkout}`)
const head = git(['rev-parse', '--verify', `${def}^{commit}`]).trim()
const headDate = git(['log', '-1', '--format=%cI', head]).trim()

// Today's open issues, unfiltered (L1014), as the mod reads them, through the shared path reader.
const env = { ...process.env }
if (account) env.GH_TOKEN = run('gh', ['auth', 'token', '-u', account]).trim()
const listed = issuesRead(run('gh', ['issue', 'list', '--repo', repo as string, '--state', 'open', '--limit', String(ISSUE_LIMIT), '--json', 'number,title,body,labels'], { env }))
if (listed.state === 'unread') fail(3, `the open issues could not be read: ${listed.why}`)
const rows = listed.state === 'unread' ? [] : listed.rows
const refs = JSON.parse(run('python3', [EXTRACTOR, '--paths'], { input: JSON.stringify(rows.map(({ number, title, body }) => ({ number, title, body }))) })) as Record<string, string[]>
const issues: CachedIssue[] = toCached(rows, refs)

// The sessions: each commit in the window, newest first from git, replayed oldest first.
const log = git(['log', head, `--since=${days}.days`, '-M', '--name-status', '--format=%x1e%H%x09%cI%x09%s'])
type Commit = { sha: string; at: string; subject: string; files: string[] }
const commits: Commit[] = []
for (const rec of log.split('\x1e')) {
  if (!rec.trim()) continue
  const [first = '', ...rest] = rec.split('\n')
  const [sha = '', at = '', ...subj] = first.split('\t')
  const files: string[] = []
  for (const line of rest) {
    const parts = line.split('\t')
    const status = parts[0] ?? ''
    if (status === 'M') files.push(parts[1] as string)
    else if (status.startsWith('R')) files.push(parts[2] as string)
  }
  commits.push({ sha, at, subject: subj.join('\t'), files })
}
commits.reverse()

// Each day's ranking, at that day's last commit, over the 90 days before it.
const dayOf = (iso: string) => new Date(iso).toISOString().slice(0, 10)
const lastOfDay = new Map<string, Commit>()
for (const c of commits) lastOfDay.set(dayOf(c.at), c)
const dayFacts: ReplayInput['days'] = {}
for (const [day, c] of lastOfDay) {
  const since = new Date(new Date(c.at).getTime() - GROWTH_DAYS * 86_400_000).toISOString()
  const growth = parseNumstat(git(['log', c.sha, `--since=${since}`, '--numstat', '-M', '--format=%x1e%s']))
  const cands = sizeCandidates(growth)
  const sizes = cands.length ? parseLineCounts(git(['grep', '-c', '', c.sha, '--', ...cands], [0, 1]), c.sha) : {}
  // Only what the bar can pick is kept: a file below either minimum is never ranked.
  const kept: Record<string, Growth> = {}
  const keptSizes: Record<string, number> = {}
  for (const p of cands) {
    if ((sizes[p] ?? 0) < SIZE_MIN) continue
    kept[p] = growth[p] as Growth
    keptSizes[p] = sizes[p] as number
  }
  dayFacts[day] = { growth: kept, sizes: keptSizes }
}

const tracked = git(['ls-tree', '-r', '--name-only', head]).split('\n').filter(Boolean)
const input: ReplayInput = {
  issues,
  tracked,
  days: dayFacts,
  sessions: commits.map(c => ({ id: c.sha.slice(0, 10), day: dayOf(c.at), own: [...c.subject.matchAll(/#(\d+)\b/g)].map(m => Number(m[1])), files: c.files })),
}
const result = replay(input)
const s = result.summary
const pct = (n: number, of: number) => (of ? `${Math.round((100 * n) / of)}%` : 'n/a')
const structural = issues.filter(i => i.structural.length).length
const lines = [
  `Replay of ${repo}, ${days} days to ${head.slice(0, 10)} (${headDate}), rules v${RULE_VERSION}.`,
  `Open issues read today: ${rows.length}${listed.state === 'truncated' ? ' (TRUNCATED at the limit)' : ''}, ${structural} with a structural label. What was open on each day is not recoverable, so today's list stands for every day.`,
  `Sessions (commits): ${s.sessions}; with a judged source or test file: ${s.judgedSessions}.`,
  `Would hold at least once: ${s.withHold} (${pct(s.withHold, s.judgedSessions)} of judged sessions); four or more holds: ${s.fourOrMore}.`,
  `Holds: ${s.holds} (by issues ${s.byIssues}, by the growth bar ${s.byGrowth}).`,
  `Holds per session: ${Object.entries(s.histogram).sort((a, b) => Number(a[0]) - Number(b[0])).map(([k, v]) => `${k}: ${v}`).join(', ')}.`,
]
if (names) for (const r of result.sessions) if (r.held) lines.push(`  ${r.id} ${r.held} of ${r.judged}: ${r.holds.map(h => `${h.path} (${h.why.join('+')})`).join(', ')}`)
process.stdout.write(lines.join('\n') + '\n')

if (fixture) {
  // Trimmed to what decides the replay: tracked files sharing a basename with a path an issue names
  // or a session edits (which is all uniqueness reads), issues naming any path, and judged files only.
  const base = (p: string) => p.slice(p.lastIndexOf('/') + 1)
  const sessions = input.sessions.map(x => ({ ...x, files: x.files.filter(f => fileKind(f) !== null) }))
  const wanted = new Set([...issues.flatMap(i => i.refs), ...sessions.flatMap(x => x.files)].map(base))
  const trimmed: ReplayInput = {
    issues: issues.filter(i => i.refs.length),
    tracked: tracked.filter(p => wanted.has(base(p))),
    days: dayFacts,
    sessions,
  }
  const again = replay(trimmed).summary
  if (JSON.stringify(again) !== JSON.stringify(s)) fail(3, 'the trimmed fixture replays differently from the whole input, so it was not written')
  // Each session's files by their place in one list of paths, which keeps the fixture a third the size.
  const paths = [...new Set(sessions.flatMap(x => x.files))].sort()
  const at = new Map(paths.map((p, i) => [p, i]))
  const packed = { ...trimmed, sessions: sessions.map(x => ({ ...x, files: x.files.map(f => at.get(f) as number) })) }
  writeFileSync(
    fixture,
    `// Measured by tools/area-check-replay.ts from ${repo} on ${new Date().toISOString().slice(0, 10)}: ${days} days to ${head.slice(0, 10)}, rules v${RULE_VERSION}.\n` +
      `// Generated; measure again rather than edit (L48). Each session's files are places in PATHS.\n` +
      `import type { ReplayInput, ReplaySummary } from '../hooks/rules.ts'\n\n` +
      `export const PATHS: string[] = ${JSON.stringify(paths)}\n\n` +
      `export const MEASURED: { repo: string; head: string; rule: number; input: Omit<ReplayInput, 'sessions'> & { sessions: { id: string; day: string; own: number[]; files: number[] }[] }; summary: ReplaySummary } = ${JSON.stringify({ repo, head, rule: RULE_VERSION, input: packed, summary: s })}\n`,
  )
}
