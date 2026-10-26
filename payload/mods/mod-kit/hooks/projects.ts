// Where Claude Code keeps a session's transcript (#1725): ~/.claude/projects/<folder>/<session id>.jsonl,
// the folder being the directory the session started in, spelled with every character but a letter
// or a digit made a hyphen, and, past 200 characters, cut to its first 200 with a hyphen and a hash
// of the path after it. Measured on the real engine (2.1.310, 2026-10-25) by starting headless
// sessions in a folder holding a dot, a space and an underscore, and in one 339 characters long. On
// this Mac (2026-10-25) 9,030 of 9,045 transcripts sat in the spelling of the first folder they
// record; 12 record none, and 3 began in a checkout and moved into a worktree, filed by the worktree,
// which the registry's search by the session id still finds. The
// hash is Claude Code's own and is not worked out here: a long folder is found by listing for its
// first 200 characters and a hyphen.
//
// Folders whose names keep their dots and spaces (`...NurseDex-.claude-worktrees-...`) are not
// Claude Code's: the Vercel plugin writes them (0.24.0, hooks/hook-env.mjs, which makes only each
// slash a hyphen) for its own skill-injections.jsonl: on 2026-10-25 each of the 48 folders on this
// Mac not spelled by the rule above held that file alone and no transcript, so they are no spelling
// to look in.
//
// The one reader of that layout, pure, kept here and copied byte for byte into each mod that looks
// a transcript up (hooks/mod-kit/projects.ts in the session registry and scope-modes, which
// tools/check-mod-shared-parts.sh holds to this one), since a mod cannot import another's files.

// The longest spelling Claude Code keeps whole.
const MAX = 200

// The folder for a directory: its whole name, or, for a long one, the start every name it can have
// begins with.
export const projectFolder = (cwd: string): { name: string } | { prefix: string } => {
  const spelled = cwd.replace(/[^A-Za-z0-9]/g, '-')
  return spelled.length <= MAX ? { name: spelled } : { prefix: `${spelled.slice(0, MAX)}-` }
}

type Listing = (dir: string) => Promise<readonly { name: string; kind: string }[]>

// Every place the transcript of session `id`, started in `cwd`, can be, under `projects` (the
// ~/.claude/projects folder): one path, named with nothing read, for an ordinary folder; for a long
// one, a path in each folder of that start with a hash after it, which takes a listing of
// `projects`. A listing that fails throws, so the caller says it rather than taking it for none.
// Whether a file is at a place is the caller's to check.
export const transcriptPlaces = async (list: Listing, projects: string, cwd: string, id: string): Promise<string[]> => {
  const f = projectFolder(cwd)
  if ('name' in f) return [`${projects}/${f.name}/${id}.jsonl`]
  const hashed = (await list(projects)).filter(e => e.kind === 'dir' && e.name.startsWith(f.prefix) && /^[0-9a-z]+$/.test(e.name.slice(f.prefix.length)))
  return hashed.map(e => e.name).sort().map(name => `${projects}/${name}/${id}.jsonl`)
}
