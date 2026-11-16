// The one reader of a patch every mod uses (#2992, L613): the files a unified diff changes, by the
// names on each side, its hunks, and how a patch command places those names. Scope modes (which
// files a git apply changed, #1123) and the Slack alert guard (what a patch does to a file that
// posts, #2971) each kept their own, and each got right a case the other got wrong: a hunk's
// removed line reading "-- x" over an added one reading "++ y" was a header to one, and git's own
// diff line naming a rename with no text changed was nothing to the other. A mod keeps a byte for
// byte copy at hooks/mod-kit/patch.ts, held to this one by tools/check-mod-shared-parts.sh, which
// fails a mod reading a patch by hand.

/** One hunk: its lines before and after, context included, so it reads as an Edit of one to the other. */
export type PatchHunk = { before: string; after: string }
/**
 * One file a patch changes: its name on each side as the patch writes it, quotes and escapes undone
 * (null for /dev/null, a file made or removed), each hunk, and `binary` when git gives its change as
 * a binary patch, which has no lines to read.
 */
export type PatchFile = { from: string | null; to: string | null; hunks: PatchHunk[]; binary?: true }
/**
 * Every file a patch names, and `unreadable`, why its hunks could not all be read: the first hunk
 * whose lines do not add up to its header, which is left out. Every file after such a hunk is
 * still named and its hunks read. A tool applying the patch refuses the whole of it then.
 */
export type PatchReading = { files: PatchFile[]; unreadable?: string }

// A name as git or diff writes it: a timestamp after a tab cut off, a name git quotes (one holding a
// quote, a backslash, a control or a non-ASCII character) read with its C escapes undone, octal
// escapes as the UTF-8 bytes they spell. A character written as itself is taken whole, both units
// of one outside the Basic Multilingual Plane together (#3021: taken a unit at a time, each half
// became a replacement character, and the name read named no file).
const unquoted = (q: string): string => {
  const bytes: number[] = []
  const ESC: Record<string, number> = { a: 7, b: 8, t: 9, n: 10, v: 11, f: 12, r: 13, '"': 34, '\\': 92 }
  for (let i = 1; i < q.length - 1; i++) {
    const c = String.fromCodePoint(q.codePointAt(i) as number)
    if (c !== '\\') {
      bytes.push(...new TextEncoder().encode(c))
      i += c.length - 1
      continue
    }
    const o = /^[0-7]{3}/.exec(q.slice(i + 1))
    if (o) {
      bytes.push(parseInt(o[0], 8))
      i += 3
    } else {
      const e = q[i + 1] as string
      bytes.push(ESC[e] ?? e.charCodeAt(0))
      i++
    }
  }
  return new TextDecoder().decode(new Uint8Array(bytes))
}
const nameOf = (raw: string): string | null => {
  const t = raw.trim()
  const name = /^"(?:[^"\\]|\\.)*"/.test(t) ? unquoted(/^"(?:[^"\\]|\\.)*"/.exec(t)?.[0] as string) : (t.split('\t')[0] ?? '').trim()
  return name === '/dev/null' ? null : name
}
// git's own diff line, `diff --git a/x b/y`: each side quoted or not. A name holding " b/" unquoted
// is read at its last " b/", the commoner case.
const gitLine = (rest: string): [string, string] | undefined => {
  const q = /^("(?:[^"\\]|\\.)*"|\S+) ("(?:[^"\\]|\\.)*")$/.exec(rest) ?? /^("(?:[^"\\]|\\.)*") (.+)$/.exec(rest)
  if (q) return [nameOf(q[1] as string) ?? '', nameOf(q[2] as string) ?? '']
  const cut = rest.lastIndexOf(' b/')
  return cut > 0 ? [rest.slice(0, cut), rest.slice(cut + 1)] : undefined
}

/**
 * Every file a patch names and changes, read as git apply, git am and patch read a unified diff (a
 * mail's text before its diff is skipped): git's diff line starts a file and names both sides,
 * which a `---` and `+++` pair under it then names exactly; a pair with no diff line above it is a
 * file of its own; and each hunk is walked by its header's counts, so a line inside it is never
 * taken for a header.
 */
export const readPatch = (text: string): PatchReading => {
  const lines = text.split('\n')
  const files: PatchFile[] = []
  let file: PatchFile | undefined
  // The file git's diff line started, until its own --- and +++ lines or a hunk.
  let opened: PatchFile | undefined
  let unreadable: string | undefined
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i] as string
    const d = /^diff --git (.+)$/.exec(line)
    if (d) {
      const both = gitLine(d[1] as string)
      file = { from: both ? both[0] : null, to: both ? both[1] : null, hunks: [] }
      files.push(file)
      opened = file
      continue
    }
    if (file && (line === 'GIT binary patch' || /^Binary files .* differ$/.test(line))) {
      file.binary = true
      continue
    }
    if (line.startsWith('--- ') && (lines[i + 1] ?? '').startsWith('+++ ')) {
      const from = nameOf(line.slice(4))
      const to = nameOf((lines[i + 1] as string).slice(4))
      if (opened) {
        opened.from = from
        opened.to = to
      } else {
        file = { from, to, hunks: [] }
        files.push(file)
      }
      opened = undefined
      i++
      continue
    }
    const h = /^@@ -\d+(?:,(\d+))? \+\d+(?:,(\d+))? @@/.exec(line)
    if (!h || !file) continue
    opened = undefined
    let [olds, news] = [Number(h[1] ?? 1), Number(h[2] ?? 1)]
    const before: string[] = []
    const after: string[] = []
    // Why this hunk cannot be read. The hunk is left out and the reading goes on from the line that
    // broke it (#3021: it stopped there, so every file after it went unnamed), which is read again
    // as what it may be, the next file's first line. So is the line that runs a hunk past its
    // header's counts (#3036): taken as the hunk's own, a `---` line there named no next file, and
    // that file's hunks were read as this file's. Only the first reason is kept.
    let broke: string | undefined
    while (!broke && (olds > 0 || news > 0)) {
      const l = lines[++i]
      if (l === undefined) {
        broke = 'a hunk ends before its lines add up to its header'
        break
      }
      if (l.startsWith('\\')) continue
      const [mark, body] = [l[0] ?? ' ', l.slice(1)]
      if (mark === ' ' || l === '') {
        before.push(body)
        after.push(body)
        olds--
        news--
      } else if (mark === '-') {
        before.push(body)
        olds--
      } else if (mark === '+') {
        after.push(body)
        news--
      } else {
        broke = `a hunk holds a line starting ${JSON.stringify(mark)}`
        i--
      }
      if (olds < 0 || news < 0) {
        broke = 'a hunk holds more lines than its header says'
        i--
      }
    }
    if (broke) unreadable ??= broke
    else file.hunks.push({ before: before.join('\n'), after: after.join('\n') })
  }
  return { files, ...(unreadable ? { unreadable } : {}) }
}

/**
 * The files a patch changes with every hunk read: undefined for text no file can be read from
 * whole, which names none, holds a hunk that does not add up, or gives a change as a binary patch.
 */
export const patchFiles = (text: string): PatchFile[] | undefined => {
  const r = readPatch(text)
  return r.unreadable || !r.files.length || r.files.some(f => f.binary) ? undefined : r.files
}

/** How a patch command places the names its patch gives (patchPlacing). */
export type PatchPlacing = { strip?: number; into: string; target?: string; reverse?: true }
/**
 * How a patch command places the files its patch names (#2971): the leading folders it strips from
 * each name (`-p`; undefined where the command gives none, so placedName takes git's default), the
 * folder it applies in below where it runs (`patch -d`, `git apply --directory`, which git reads from
 * the top of the checkout), for patch a file named to take every hunk, and whether it applies the
 * patch in reverse (`-R`, `--reverse`), when each hunk's after is what the file held and its before is
 * what it is left holding. `words` are the patch program's own words after its name: git apply's
 * after `apply`, patch's after `patch`.
 */
export const patchPlacing = (words: readonly string[], git: boolean): PatchPlacing => {
  let strip: number | undefined
  let reverse = false
  let into = ''
  const ops: string[] = []
  const VALUED = git ? new Set(['-p', '-C', '--directory', '--exclude', '--include']) : new Set(['-i', '-p', '-d', '-o', '-r', '-B', '-D', '-F', '-V', '-z', '--input', '--directory', '--output'])
  for (let i = 0; i < words.length; i++) {
    const a = words[i] as string
    const p = /^(?:-p|--strip=)(\d+)$/.exec(a)
    if (p) strip = Number(p[1])
    else if (a === '-R' || a === '--reverse') reverse = true
    else if (a === '-p' && /^\d+$/.test(words[i + 1] ?? '')) strip = Number(words[++i])
    else if (/^--directory=/.test(a)) into = a.slice('--directory='.length)
    else if ((a === '--directory' || (!git && a === '-d')) && words[i + 1] !== undefined) into = words[++i] as string
    else if (VALUED.has(a)) i++
    // A redirect and the word it takes (`< fix.diff`, `<<'EOF'`), which feed it and name no file to patch.
    else if (/^(?:\d*(?:<<-?|<<<|<|>>|>|>\|)|&>>?)$/.test(a)) i++
    else if (!a.startsWith('-') && !/^(?:\d*[<>]|&>)/.test(a)) ops.push(a)
  }
  return { ...(strip === undefined ? {} : { strip }), into: into.replace(/\/+$/, ''), ...(!git && ops[0] !== undefined ? { target: ops[0] } : {}), ...(reverse ? { reverse: true as const } : {}) }
}

/** Whether a file's names carry git's a/ and b/ on both sides, as a diff git wrote does. */
export const gitNamed = (f: PatchFile): boolean => (f.to === null || f.to.startsWith('b/')) && (f.from === null || f.from.startsWith('a/'))

/**
 * Where one name of a file lands, relative to the folder the command applies in (its `into` not
 * included): the file patch was named, else the name with its leading folders stripped, by the
 * command's -p, or by default 1 for git apply and git am, and for patch 1 when git's a/ and b/ are on
 * both sides, else 0. Undefined when nothing is left of it.
 */
export const placedName = (name: string, f: PatchFile, placing: PatchPlacing, git: boolean): string | undefined => {
  if (placing.target) return placing.target
  const rel = name.split('/').slice(placing.strip ?? (git || gitNamed(f) ? 1 : 0)).join('/')
  return rel || undefined
}

/**
 * The paths a patch command changes (#1123), every name on both sides of every file but /dev/null,
 * placed as the command places them, below its folder (`into`), relative to where it applies.
 */
export const patchedPaths = (words: readonly string[], git: boolean, text: string): string[] => {
  const placing = patchPlacing(words, git)
  const out: string[] = []
  for (const f of readPatch(text).files) {
    for (const name of [f.from, f.to]) {
      if (name === null) continue
      const rel = placedName(name, f, placing, git)
      if (rel === undefined) continue
      const path = placing.into ? `${placing.into}/${rel}` : rel
      if (!out.includes(path)) out.push(path)
    }
  }
  return out
}
