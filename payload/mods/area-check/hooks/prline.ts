import { DECISIONS, type Decision } from './rules.ts'

// The area check line in a pull request description (#1510, plan phase 5.2). Every file the area
// check decided on a branch, at the merge base that branch had with the default branch, carries one
// line in the pull request made from it: `Area check: <file>: <decision>, <reason>`. Pure: register.ts
// reads the log (the live file plus every rotated decisions file, filtered to one repository and
// branch by READ_SCRIPT below), the command through mod-kit's readers and GitHub for a merge; this
// says which decisions the branch holds, which lines the description lacks, and the words of a
// refusal. ROTATE_SCRIPT, run at session start, keeps the live file small without deleting anything.
//
// The match is by repository, branch and merge base, so a branch name used again later starts clean.
// A rebase moves the merge base, so decisions taken before it stop matching (a known gap, named in
// the README and the design record). Where either merge base could not be read, the branch alone
// decides, and the refusal says so.

/** One decision as the log keeps it: a `decided` record (version 3), or Dan's standing answer applied to a `judged` one. */
export type PrDecision = {
  repo: string
  path: string
  branch: string
  mergeBase: string | null
  decision: Decision
  reason?: string
  issue?: number
  by?: 'dan'
}

/** The two answers of Dan's that a `judged` record applies without asking, as the decision each stands for. */
const APPLIED: Readonly<Record<string, Decision>> = { 'Proceed anyway': 'proceed', 'Restructure first': 'restructure' }

const isObject = (x: unknown): x is Record<string, unknown> => typeof x === 'object' && x !== null && !Array.isArray(x)
const text = (x: unknown): x is string => typeof x === 'string' && x.length > 0
const baseOf = (x: unknown): string | null | undefined => (x === null ? null : typeof x === 'string' && x ? x : undefined)

/**
 * The decisions in the lines the read gave (each holding `"kind":"decided"` or `"applied":`), in log
 * order. A line that is not JSON, or a decision missing a field it must carry, is MALFORMED: skipped
 * and returned, so the caller can name it (never read as no decision). A `decided` record older
 * than version 3 carries no branch and is left out, not malformed; so is a record of another kind
 * the marks happened to match, and a judged record with no answer applied.
 */
export const readDecisions = (out: string): { decisions: PrDecision[]; malformed: string[] } => {
  const decisions: PrDecision[] = []
  const malformed: string[] = []
  for (const line of out.split('\n')) {
    if (!line.trim()) continue
    let r: unknown
    try {
      r = JSON.parse(line)
    } catch {
      malformed.push(line)
      continue
    }
    if (!isObject(r)) {
      malformed.push(line)
      continue
    }
    if (r.kind === 'decided') {
      if (typeof r.v !== 'number' || r.v < 3) continue
      // A decision taken on a detached head has no branch, so no pull request is made from it.
      if (r.branch === null) continue
      const mergeBase = baseOf(r.mergeBase)
      const decision = DECISIONS.find(d => d === r.decision)
      if (!text(r.repo) || !text(r.path) || !text(r.branch) || mergeBase === undefined || !decision) {
        malformed.push(line)
        continue
      }
      if (decision === 'fold' && (typeof r.issue !== 'number' || !Number.isInteger(r.issue))) {
        malformed.push(line)
        continue
      }
      decisions.push({
        repo: r.repo, path: r.path, branch: r.branch, mergeBase, decision,
        ...(typeof r.reason === 'string' ? { reason: r.reason } : {}),
        ...(typeof r.issue === 'number' ? { issue: r.issue } : {}),
        ...(r.by === 'dan' ? { by: 'dan' as const } : {}),
      })
      continue
    }
    if (r.kind === 'judged' && r.applied !== undefined) {
      const decision = typeof r.applied === 'string' ? APPLIED[r.applied] : undefined
      // A judged record on a detached head has no branch, so no pull request is made from it.
      if (r.branch === null) continue
      // A judged record of an older version carries no branch field at all: not relevant to any branch, not damage.
      if (r.branch === undefined) continue
      const mergeBase = baseOf(r.mergeBase)
      if (!decision || !text(r.repo) || !text(r.path) || !text(r.branch) || mergeBase === undefined) {
        malformed.push(line)
        continue
      }
      decisions.push({ repo: r.repo, path: r.path, branch: r.branch, mergeBase, decision, by: 'dan' })
    }
  }
  return { decisions, malformed }
}

/** The decisions of one repository, any branch: what decides whether the pull request side is asked at all. */
export const inRepo = (decisions: readonly PrDecision[], repo: string): PrDecision[] =>
  decisions.filter(d => d.repo.toLowerCase() === repo.toLowerCase())

/** One file decided on the branch: every decision taken on it there, the latest last. */
export type BranchFile = { path: string; decisions: PrDecision[] }

/**
 * The files decided on this branch at this merge base, sorted by path. `loose` is true when a
 * decision matched by branch alone, because its merge base or the branch's could not be read.
 */
export const onBranch = (decisions: readonly PrDecision[], at: { repo: string; branch: string; mergeBase: string | null }): { files: BranchFile[]; loose: boolean } => {
  const byPath = new Map<string, PrDecision[]>()
  let loose = false
  for (const d of inRepo(decisions, at.repo)) {
    if (d.branch !== at.branch) continue
    if (d.mergeBase !== null && at.mergeBase !== null && d.mergeBase !== at.mergeBase) continue
    if (d.mergeBase === null || at.mergeBase === null) loose = true
    byPath.set(d.path, [...(byPath.get(d.path) ?? []), d])
  }
  const files = [...byPath.entries()].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)).map(([path, ds]) => ({ path, decisions: ds }))
  return { files, loose }
}

/** The line a decision asks for, exactly as it may be pasted. */
export const lineFor = (d: PrDecision): string => {
  const head = `Area check: ${d.path}: ${d.decision}`
  if (d.decision === 'fold') return `${head}, Refs #${String(d.issue)}`
  if (d.by === 'dan') return d.decision === 'restructure' ? `${head}, Dan chose Restructure first` : `${head}, Dan chose Proceed anyway`
  return d.reason ? `${head}, ${d.reason.trim().split('\n')[0]}` : head
}

// A line in a description: an optional bullet, the file in backticks or not, the decision, the rest.
const LINE = /^[ \t]*(?:[-*][ \t]+)?Area check:[ \t]*`?([^`\n]+?)`?:[ \t]*(proceed|fold|restructure)\b(.*)$/gim
const FOLD_REF = /\b(?:Refs|Closes)[ \t]+#(\d+)\b/gi

/** The area check lines a description carries, each file with the decisions and the rest of its lines. */
export const linesIn = (body: string): { path: string; decision: Decision; rest: string }[] =>
  [...body.matchAll(LINE)].map(m => ({ path: (m[1] as string).trim(), decision: (m[2] as string).toLowerCase() as Decision, rest: m[3] as string }))

/**
 * The files whose line the description lacks. A file's line names any decision taken on it on the
 * branch; a fold line must also carry `Refs #N` or `Closes #N` for an issue folded into that file.
 */
export const missingFrom = (files: readonly BranchFile[], body: string): BranchFile[] => {
  const lines = linesIn(body)
  return files.filter(f => !lines.some(l => {
    if (l.path !== f.path || !f.decisions.some(d => d.decision === l.decision)) return false
    if (l.decision !== 'fold') return true
    const folded = new Set(f.decisions.filter(d => d.decision === 'fold').map(d => d.issue))
    return [...l.rest.matchAll(FOLD_REF)].some(m => folded.has(Number(m[1])))
  }))
}

/** The line to paste for each file: the latest decision taken on it. */
export const linesToPaste = (files: readonly BranchFile[]): string[] => files.map(f => lineFor(f.decisions[f.decisions.length - 1] as PrDecision))

// ---- The words ----

export const LOG_SHOWN = '~/.claude-area-check/log.jsonl'
const THIS_MAC = `It read this Mac's log only (${LOG_SHOWN}), so a file decided on another Mac is not asked for.`
const plural = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`
const shorten = (s: string) => (s.length > 120 ? `${s.slice(0, 117)}...` : s)

/** The sentence naming the log lines skipped, for a refusal. */
export const malformedNote = (malformed: readonly string[]): string =>
  malformed.length === 0
    ? ''
    : `${plural(malformed.length, 'line of the log', 'lines of the log')} could not be read and ${malformed.length === 1 ? 'was' : 'were'} skipped, the first: ${shorten(malformed[0] as string)}`

/** The dim line naming the log lines skipped, on a command let through. */
export const malformedDim = (malformed: readonly string[]): string =>
  `The area check skipped ${plural(malformed.length, 'line of its log', 'lines of its log')} (${LOG_SHOWN}) it could not read, the first: ${shorten(malformed[0] as string)}`

export type Refusing = {
  /** What is refused, as the command names it: `gh pr create`, `gh pr edit`, `gh pr merge`. */
  verb: string
  branch: string
  files: readonly BranchFile[]
  loose: boolean
  malformed: readonly string[]
}

const tail = (r: Refusing) =>
  [
    r.loose ? 'A merge base could not be read, so these decisions were matched by branch alone.' : '',
    THIS_MAC,
    malformedNote(r.malformed),
  ].filter(Boolean)

/** The description lacks lines: every line to paste, and where to put them for this command. */
export const missingRefusal = (r: Refusing & { where: 'command' | 'github'; selector?: string }): string => {
  const n = plural(r.files.length, 'file', 'files')
  const how = r.where === 'github'
    ? `Add each line below to the pull request's description on GitHub (gh pr edit${r.selector ? ` ${r.selector}` : ''} --body-file <a file holding the whole description>), then merge again:`
    : 'Add each line below to the description, then run the command again:'
  return [`The area check refused this ${r.verb}: the description lacks the area check line for ${n} decided on branch ${r.branch}. ${how}`, ...linesToPaste(r.files), ...tail(r)].join('\n')
}

/** gh pr create with no description given: ask for --body or --body-file, carrying the lines. */
export const noBodyRefusal = (r: Refusing): string =>
  [`The area check refused this ${r.verb}: it gives no description to check, and ${plural(r.files.length, 'file was', 'files were')} decided on branch ${r.branch}. Give the description with --body or --body-file, carrying each line below:`, ...linesToPaste(r.files), ...tail(r)].join('\n')

/**
 * A --body whose command substitution mod-kit's reader marks unresolved (#2166): its text is unknown,
 * so it is refused with why, the ways to give it that can be read, and the lines it must carry.
 */
export const bodyUnresolvedRefusal = (r: Refusing, why: string): string =>
  [`The area check refused this ${r.verb}: it could not work out the description its --body gives (${why}), and ${plural(r.files.length, 'file was', 'files were')} decided on branch ${r.branch}. Give the description with --body-file and a file, with --body-file - fed by a heredoc, or with --body "$(cat <<'EOF' ... EOF)", carrying each line below:`, ...linesToPaste(r.files), ...tail(r)].join('\n')

/** The description file could not be read: named, never read as a description without lines. */
export const bodyUnreadableRefusal = (verb: string, file: string, why: string): string =>
  file === 'standard input'
    ? `The area check refused this ${verb}: its description comes from standard input (${why}), which the area check cannot read, and files were decided on this branch. Give it with --body, with --body-file and a file, or with --body-file - fed by a heredoc.`
    : `The area check refused this ${verb}: it could not read the description file ${file} (${why}), and files were decided on this branch. Check the path, or give the description with --body.`

/** The log could not be read: named, with why and the way back, never read as no decisions. */
export const logUnreadableRefusal = (verb: string, why: string): string =>
  `The area check refused this ${verb}: it could not read its log ${LOG_SHOWN} (${why}), so it cannot tell which files were decided on this branch. It reads this Mac's log only. If the log was deleted, a new session writes it again (and reads as no decisions); if it cannot be read, make it readable to you again. Then run the command again.`

// ---- The log's rotation, and the read of one branch's decisions (#2143) ----
//
// The log grows about 100 KB a day and is never cut. At session start, once it is over ROTATE_BYTES,
// it is renamed into rotated/<stamp>.rotating (a rename, so nothing is copied and a line being
// appended lands whole in one file or the other) and a new log is begun. Ten minutes later, well past
// the five seconds any append may still be writing to the old name, a later session start SETTLES it:
// its decision lines are written whole to a temporary file, which is renamed to
// rotated/<stamp>.decisions.jsonl, and only then is the .rotating file renamed to rotated/<stamp>.jsonl,
// the archive. Nothing is ever deleted: retention is Dan's call (L9). A crash between any two steps
// leaves a line in two files at worst, read once below; two sessions settling at once write the same
// bytes. A gh pr command reads the decision files, any .rotating file and the log, so it scans the
// decisions plus at most a few MiB of log, never the whole history, and every decision is still there.
// Both scripts are proved against a real shell and awk by tests/test-area-check-log-rotation.sh.

/** The log is rotated at a session start once it is over this many bytes: about forty days of log, a scan of tens of milliseconds. */
export const ROTATE_BYTES = 4 * 1024 * 1024
/** A rotated log is settled once it has not been written for this many minutes. */
export const SETTLE_MINUTES = 10
/** The two marks a decision line carries: a `decided` record, or a `judged` one Dan's standing answer applied. */
export const MARKS = ['"kind":"decided"', '"applied":'] as const

/** The name a rotation gives the log it moves aside: the time and the session, so two can never share one. */
export const rotationStamp = (atMs: number, session: string): string =>
  `${new Date(atMs).toISOString().replace(/[:.]/g, '-')}-${session.replace(/[^A-Za-z0-9-]/g, '-')}`

/**
 * The rotation and the settling, one sh call at session start. Arguments: the folder, the stamp,
 * ROTATE_BYTES, SETTLE_MINUTES and the two MARKS. A log another session rotated first is not an
 * error; a rename that fails while the log is still too big is, and leaves the log where it was.
 */
export const ROTATE_SCRIPT = [
  'set -o pipefail',
  'd=$1; stamp=$2; max=$3; mins=$4',
  'log=$d/log.jsonl; r=$d/rotated',
  'mkdir -p "$r" || exit 1',
  'if [ -f "$log" ] && [ "$(($(wc -c < "$log")))" -gt "$max" ]; then',
  '  to=$r/$stamp.rotating',
  '  if [ -e "$to" ]; then echo "$to already exists, so the log was left where it is" >&2; exit 1; fi',
  '  if e=$(mv "$log" "$to" 2>&1); then',
  '    : >> "$log" || exit 1',
  '  elif [ -f "$log" ] && [ "$(($(wc -c < "$log")))" -gt "$max" ]; then',
  '    echo "$e" >&2; exit 1',
  '  fi',
  'fi',
  'find "$r" -type f -name "*.rotating" -mmin "+$mins" | while IFS= read -r f; do',
  '  base=${f%.rotating}',
  '  if [ -e "$base.jsonl" ]; then',
  '    if [ -e "$f" ]; then echo "$base.jsonl already exists beside $f, so it was left unsettled" >&2; exit 1; fi',
  '    continue',
  '  fi',
  '  tmp=$base.decisions.$$.tmp',
  '  LC_ALL=C grep -a -F -e "$5" -e "$6" -- "$f" > "$tmp"',
  '  st=$?',
  '  if [ "$st" -gt 1 ]; then',
  '    rm -f "$tmp"',
  '    if [ -e "$f" ]; then exit 1; fi',
  '    continue',
  '  fi',
  '  mv "$tmp" "$base.decisions.jsonl" || exit 1',
  '  if ! e=$(mv "$f" "$base.jsonl" 2>&1) && [ -e "$f" ]; then echo "$e" >&2; exit 1; fi',
  'done',
].join('\n')

/**
 * The read, one sh call per gh pr command and branch. Arguments: the folder, the repository's
 * needle, the branch's needle (empty for the repository's count alone) and the two MARKS, all
 * handed to awk through its environment, never awk -v, which reads backslashes as escapes. One pass
 * over every decision file, any .rotating file and the log prints `cut <line>` for a decision line
 * cut short (any repository), `line <line>` for one naming the repository and the branch, and last
 * `repo <n>`, how many lines named the repository. A file a settle or a rotation renamed while it was
 * being read makes the list of files change, and the read is made again, at most twice more.
 */
export const READ_SCRIPT = [
  'd=$1',
  'AC_REPO=$2 AC_BRANCH=$3 AC_DECIDED=$4 AC_APPLIED=$5',
  'export AC_REPO AC_BRANCH AC_DECIDED AC_APPLIED',
  "nl='",
  "'",
  'files() {',
  '  for f in "$d"/rotated/*.decisions.jsonl "$d"/rotated/*.rotating "$d"/log.jsonl; do',
  '    if [ -e "$f" ]; then printf "%s\\n" "$f"; fi',
  '  done',
  '}',
  'tries=0',
  'while :; do',
  '  list=$(files)',
  '  if [ -z "$list" ]; then echo "$d/log.jsonl: No such file or directory" >&2; exit 2; fi',
  '  set -f; IFS=$nl; set -- $list; unset IFS; set +f',
  '  for f in "$@"; do',
  '    if [ -e "$f" ] && [ ! -r "$f" ]; then echo "$f: Permission denied" >&2; exit 2; fi',
  '  done',
  "  out=$(LC_ALL=C awk '",
  '    BEGIN { repo = ENVIRON["AC_REPO"]; branch = ENVIRON["AC_BRANCH"]; m1 = ENVIRON["AC_DECIDED"]; m2 = ENVIRON["AC_APPLIED"]; n = 0 }',
  '    index($0, m1) || index($0, m2) {',
  '      if (substr($0, length($0), 1) != "}") { print "cut " $0; next }',
  '      if (!index(tolower($0), repo)) next',
  '      n++',
  '      if (branch != "" && index($0, branch)) print "line " $0',
  '    }',
  '    END { print "repo " n }',
  "  ' \"$@\")",
  '  st=$?',
  '  if [ "$st" -eq 0 ]; then printf "%s\\n" "$out"; exit 0; fi',
  '  tries=$((tries + 1))',
  '  if [ "$tries" -ge 3 ] || [ "$(files)" = "$list" ]; then exit "$st"; fi',
  'done',
].join('\n')

/** What the read finds among a repository's lines: lowercased, as inRepo compares. */
export const repoNeedle = (repo: string): string => `"repo":${JSON.stringify(repo.toLowerCase())}`
/** What the read finds a branch by: exactly as the record writes it, as onBranch compares. */
export const branchNeedle = (branch: string): string => `"branch":${JSON.stringify(branch)}`

/** One read: the branch's decisions (a prefilter, so still matched by inRepo and onBranch), the lines it could not read, and how many lines named the repository. */
export type LogRead = { decisions: PrDecision[]; malformed: string[]; count: number } | { why: string }

/**
 * The read's output, a line found in two files (a crash mid settle) taken once. Output that does not
 * end with the count, or holds a line the read never prints, was cut short: never read as decisions.
 */
export const readOf = (stdout: string): LogRead => {
  const lines = stdout.split('\n')
  if (lines[lines.length - 1] === '') lines.pop()
  const count = /^repo (\d+)$/.exec(lines.pop() ?? '')
  if (!count) return { why: 'its read ended before it said how many decisions it found' }
  const found = new Set<string>()
  const cut = new Set<string>()
  for (const l of lines) {
    if (l.startsWith('line ')) found.add(l.slice(5))
    else if (l.startsWith('cut ')) cut.add(l.slice(4))
    else return { why: 'its read gave a line it does not print' }
  }
  const r = readDecisions([...found].join('\n'))
  return { decisions: r.decisions, malformed: [...cut, ...r.malformed], count: Number(count[1]) }
}
