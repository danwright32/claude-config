// Measured by tools/area-check-replay.ts from danwright32/claude-config on 2026-11-02: 30 days to de5db413a8, rules v2.
// Generated; measure again rather than edit (L48). The rows are in the parts beside this file, one
// per line (#2097), and each session's files are places in PATHS.
import type { ReplayInput, ReplaySummary } from '../../hooks/rules.ts'
import { ROWS as paths1 } from './paths-1.ts'
import { ROWS as issues1 } from './issues-1.ts'
import { ROWS as tracked1 } from './tracked-1.ts'
import { ROWS as growth1 } from './growth-1.ts'
import { ROWS as sessions1 } from './sessions-1.ts'

export const PATHS: string[] = [...paths1]

// Every day of the window in order, so a day with no rankable file is still a day.
const DAYS: string[] = [
  "2026-10-03",
  "2026-10-04",
  "2026-10-05",
  "2026-10-06",
  "2026-10-07",
  "2026-10-08",
  "2026-10-09",
  "2026-10-10",
  "2026-10-11",
  "2026-10-12",
  "2026-10-13",
  "2026-10-14",
  "2026-10-15",
  "2026-10-16",
  "2026-10-17",
  "2026-10-18",
  "2026-10-19",
  "2026-10-20",
  "2026-10-21",
  "2026-10-22",
  "2026-10-23",
  "2026-10-24",
  "2026-10-25",
  "2026-10-26",
  "2026-10-27",
  "2026-10-28",
  "2026-10-29",
  "2026-10-30",
  "2026-10-31",
  "2026-11-01",
  "2026-11-02",
]
const days: ReplayInput['days'] = {}
for (const d of DAYS) days[d] = { growth: {}, sizes: {} }
for (const [d, p, net, fixes, lines] of [...growth1]) {
  const day = days[d] ?? (days[d] = { growth: {}, sizes: {} })
  day.growth[p] = { net, fixes }
  day.sizes[p] = lines
}

export const MEASURED: { repo: string; head: string; rule: number; input: Omit<ReplayInput, 'sessions'> & { sessions: { id: string; day: string; own: number[]; files: number[] }[] }; summary: ReplaySummary } = {
  repo: "danwright32/claude-config",
  head: "de5db413a81799552cb75fc2b6cdb184d73f1fbb",
  rule: 2,
  input: { issues: [...issues1], tracked: [...tracked1], days, sessions: [...sessions1] },
  summary: {
    "sessions": 876,
    "judgedSessions": 687,
    "withHold": 327,
    "holds": 559,
    "byIssues": 378,
    "byGrowth": 261,
    "fourOrMore": 18,
    "histogram": {"0":549,"1":183,"2":87,"3":39,"4":12,"5":3,"6":1,"7":1,"9":1},
  },
}
