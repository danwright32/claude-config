// #960: which mods to load again when mod-kit itself reloads mid session. The reasons are in
// register.tsx beside reloadDependents, which reads the disk and calls these.

/** The mods a manifest's text names as its dependencies; throws when the text is not a manifest. */
export const dependsOn = (text: string): string[] => {
  const manifest = JSON.parse(text) as { dependencies?: unknown }
  const deps = manifest.dependencies ?? []
  if (!Array.isArray(deps) || deps.some(d => typeof d !== 'string')) throw new Error('its dependencies are not a list of mod names')
  return deps as string[]
}

/** The newest modification time among the files listed, 0 when there are none. */
export const newestFile = (entries: readonly { kind: string; mtimeMs: number }[]): number =>
  entries.reduce((max, e) => (e.kind === 'file' && e.mtimeMs > max ? e.mtimeMs : max), 0)
