// One gh call as each account gh is logged in to, until one answers: Dan's work repositories are
// visible only to his work account. The active account first, then each other's token, scoped to the
// call (never gh auth switch, which other sessions share) and never printed. `tryNext` says which
// failures are worth asking the next account about; a write passes only GitHub's own not found, so a
// write that may have landed is never sent again as another account (assume it runs twice).
//
// The one copy (#1279 lessons review: scope modes had it, and picker manners needed it too). Pure: the
// caller hands in how to run a command, spelled with its own `$` in place, since a mod cannot hand `$`
// on. Kept here and copied byte for byte into each mod that uses it (hooks/mod-kit/ghaccounts.ts,
// which tools/check-mod-shared-parts.sh holds to this one).

export type GhRun = { exitCode: number; stdout: string; stderr: string }
export type GhRunner = (argv: string[], env?: Record<string, string>, stdin?: string) => Promise<GhRun>

export const askAnyAccount = async (run: GhRunner, args: string[], tryNext: (r: GhRun) => boolean = () => true, stdin?: string): Promise<{ stdout: string } | { failures: GhRun[] }> => {
  const first = await run(['gh', ...args], undefined, stdin)
  if (first.exitCode === 0) return { stdout: first.stdout }
  const failures: GhRun[] = [first]
  if (!tryNext(first)) return { failures }
  const status = await run(['gh', 'auth', 'status'])
  for (const a of new Set([...`${status.stdout}\n${status.stderr}`.matchAll(/account (\S+)/g)].map(m => m[1] as string))) {
    const tok = await run(['gh', 'auth', 'token', '-u', a])
    if (tok.exitCode !== 0 || !tok.stdout.trim()) continue
    const r = await run(['gh', ...args], { GH_TOKEN: tok.stdout.trim() }, stdin)
    if (r.exitCode === 0) return { stdout: r.stdout }
    failures.push(r)
    if (!tryNext(r)) break
  }
  return { failures }
}
