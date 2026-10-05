// Commands as mod-kit's reader hands them over (`$.modkit.pipeline`): heredoc bodies dropped,
// quotes removed, `bash -c` already read as the commands it runs, and each command with the words
// of the one a | feeds it from. Split here by hand: a '|' between two commands is a pipe, and two
// commands side by side are a list (;, && or a new line), which feeds nothing (#724).
export type Listed = { words: string[]; pipedFrom?: string[] }
export const listed = (...items: (string[] | '|')[]): Listed[] => {
  const out: Listed[] = []
  items.forEach((item, i) => {
    if (item === '|') return
    const before = items[i - 1] === '|' ? out[out.length - 1] : undefined
    out.push(before ? { words: item, pipedFrom: before.words } : { words: item })
  })
  return out
}
