// The one reader of quoted strings that are not shell, and of YAML flow lists (#2467). mod-kit's
// command reader ($.modkit.commands) reads shell only: it glues a flow list's brackets and commas
// onto its words and knows nothing of YAML's '' escape. The design round guard read TypeScript
// strings its own way (#1144) and the Slack alert guard GitLab's flow lists (#2448); both now read
// with this. Pure. Kept here once and copied byte for byte into each mod that reads with it
// (hooks/mod-kit/quoted.ts, which tools/check-mod-shared-parts.sh holds to this one), since a mod
// cannot import another mod's files.

/**
 * Where the quoted string opening at `i` closes: the offset of its closing quote, or -1 when it does
 * not close (or `i` holds no quote). `code` reads a TypeScript or JavaScript string: a backslash
 * escapes the next character, an escaped line break included, and a bare line break leaves it
 * unclosed. `yaml` reads a YAML scalar, which runs on over line breaks: in double quotes a backslash
 * escapes the next character, in single quotes `''` is one quote and a backslash is itself.
 */
export const quotedEnd = (text: string, i: number, style: 'code' | 'yaml'): number => {
  const q = text[i]
  if (q !== '"' && q !== "'") return -1
  const doubled = style === 'yaml' && q === "'"
  for (let j = i + 1; j < text.length; j++) {
    const c = text[j]
    if (doubled) {
      if (c !== q) continue
      if (text[j + 1] === q) j++
      else return j
    } else if (c === '\\') j++
    else if (c === q) return j
    else if (c === '\n' && style === 'code') return -1
  }
  return -1
}

/** A YAML scalar as the shell receives it: a quoted one with its quoting undone, a plain one as written. */
export const yamlScalar = (s: string): string => {
  if (s.length >= 2 && s.startsWith("'") && s.endsWith("'")) return s.slice(1, -1).replace(/''/g, "'")
  if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) return s.slice(1, -1).replace(/\\(.)/g, (_, c: string) => (c === 'n' ? '\n' : c === 't' ? '\t' : c))
  return s
}

/**
 * The items of the YAML flow list opening at the first `[` of `text` (`["a", "b"]`), read on over
 * line breaks until the list closes, each with its quoting undone; an empty item is dropped, and a
 * list that never closes keeps every item it read. A quote opens a scalar only at an item's start,
 * as YAML reads one, so `echo don't` is a plain item, and a quoted item's commas and brackets are
 * its own. A `#` after a space starts a comment to the end of its line. A nested list or mapping is
 * kept whole as one item's text.
 */
export const yamlFlowList = (text: string): string[] => {
  const items: string[] = []
  let cur = ''
  let depth = 0
  const read = () => [...items, cur].map(s => yamlScalar(s.trim())).filter(Boolean)
  for (let i = 0; i < text.length; ) {
    const c = text[i] as string
    if ((c === '"' || c === "'") && !cur.trim()) {
      const e = quotedEnd(text, i, 'yaml')
      const end = e < 0 ? text.length : e + 1
      cur += text.slice(i, end).replace(/\n/g, ' ')
      i = end
      continue
    }
    if (c === '#' && /\s/.test(text[i - 1] ?? ' ')) {
      const e = text.indexOf('\n', i)
      i = e < 0 ? text.length : e
      continue
    }
    if (c === '[' || c === '{') {
      if (++depth > 1) cur += c
    } else if (c === ']' || c === '}') {
      if (--depth === 0) return read()
      cur += c
    } else if (c === ',' && depth === 1) {
      items.push(cur)
      cur = ''
    } else cur += c === '\n' ? ' ' : c
    i++
  }
  return read()
}
