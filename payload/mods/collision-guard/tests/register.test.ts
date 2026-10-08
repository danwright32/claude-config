import { expect, test, type Engine } from 'claude-code/testing'
import type { On, Register } from 'claude-code'
import { branchAt } from './mod-kit/hooks/branch.ts'

// Stand-ins for the two mods this one depends on. An inline plugin cannot reach this file's
// variables, so the registry stand-in asks the world below for the sessions (a process.run the
// world answers) and every write it or the kit is handed comes back as a transcript line. mod-kit's
// readers answer from the table below (`__modkit`), each answer measured from mod-kit's own reader
// for the request these tests make (#712, L48), as ask before saving's world holds one; mod-kit's
// own tests pin the reader. Its walk for a checkout asks the world's disk for each folder's .git
// entry, as mod-kit's does.
const deps: { name: string; register: Register } = {
  name: 'deps',
  register: on => {
    // mod-kit's retry of a mod's refused send (its hooks/send.ts), standing in: once more when
    // refused, never after a throw, the reason tidied. mod-kit's own tests prove the real one.
    on('session.send', async ($, e, next) => {
      let why = ''
      for (let attempt = 0; attempt < 2; attempt++) {
        try {
          const sent = await next(e)
          if (sent.isDelivered) return sent
          why = sent.reason
        } catch (err) {
          why = String((err as Error)?.message ?? err)
          break
        }
      }
      return { isDelivered: false, reason: why.trim().replace(/\.$/, '') || 'no reason given' }
    })
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      const kit = async (method: string, input: unknown) => {
        const r = await built.process.run(['__modkit', method, JSON.stringify(input)])
        if (r.exitCode !== 0) throw new Error(r.stderr)
        return r.stdout === '' ? undefined : JSON.parse(r.stdout)
      }
      return {
        ...built,
        modkit: {
          blocked: async (b: unknown) => built.ui.log('CARD ' + JSON.stringify(b)),
          commands: async (input: { command: string }) => kit('commands', input),
          writes: async (input: { command: string; cwd: string; home: string }) => kit('writes', input),
          git: async (input: { words: string[] }) => kit('git', input),
          // Where a checkout stands (#980), read by the world with mod-kit's own reader.
          branch: async (input: { path: string }) => (await kit('branch', input)) ?? null,
          // A folder with no .git entry the world names is none; one the world cannot read refuses.
          workingTree: async ({ path }: { path: string }) => {
            let dir = path.replace(/\/+$/, '') || '/'
            for (let looked = 0; looked < 64; looked++) {
              const s = (await built.fs.stat(`${dir === '/' ? '' : dir}/.git`).catch(() => undefined)) as { kind?: string } | undefined
              if (s?.kind === 'unreadable') throw new Error(`the disk cannot read ${dir}`)
              if (s && (s.kind === 'dir' || s.kind === 'file')) return dir
              if (dir === '/') return null
              dir = dir.slice(0, dir.lastIndexOf('/')) || '/'
            }
            throw new Error(`could not tell whether ${path} is in a checkout`)
          },
          // The kit's other members, which these tests never reach: each refuses by name if one ever is.
          repo: async () => { throw new Error("mod-kit's repo is not stood in by these tests") },
          gh: async () => { throw new Error("mod-kit's gh is not stood in by these tests") },
          ghRepo: async () => { throw new Error("mod-kit's ghRepo is not stood in by these tests") },
          linkRepo: async () => { throw new Error("mod-kit's linkRepo is not stood in by these tests") },
          card: async () => { throw new Error("mod-kit's card is not stood in by these tests") },
          pipeline: async () => { throw new Error("mod-kit's pipeline is not stood in by these tests") },
          bandRow: async () => { throw new Error("mod-kit's bandRow is not stood in by these tests") },
          clearBandRow: async () => { throw new Error("mod-kit's clearBandRow is not stood in by these tests") },
          pane: async () => { throw new Error("mod-kit's pane is not stood in by these tests") },
          clearPane: async () => { throw new Error("mod-kit's clearPane is not stood in by these tests") },
          screen: async () => { throw new Error("mod-kit's screen is not stood in by these tests") },
          // #939: a press raised by the kit's Button below, and whether a click lands; every Button here is clickable.
          press: async () => ({ isAnswered: false }),
          clickable: async () => true,
        },
        sessions: {
          list: async () => JSON.parse((await built.process.run(['__sessions'])).stdout),
          // A path naming 'unwritable' is one whose note the registry cannot write (#751).
          noteEdit: async ({ path }: { path: string }) => {
            if (path.includes('unwritable')) throw new Error("this session's record could not be written")
            await built.ui.log('EDIT ' + path)
          },
          setExtra: async () => undefined,
        },
      }
    })
  },
}
// A stand-in for Claude Code's built-in security default (#875), loaded in every test so none can
// pass on a hook that never runs. Seated outermost for a Team or Enterprise organization, it sends
// every classic hook event past the tier a person's own plugins load in. This is its own code for
// that event, copied from the 2.1.292 binary: `e("classic.*",(n,o,t)=>t.to(o,"append"))`. A
// headless debug run on 2026-10-06 logged it for this mod on every tool call:
// "...collision-guard...: classic.PreToolUse bypassed by cc-plugin-sec-default (tier user); beneath runs".
const secDefault: { name: string; tier: 'prepend'; register: Register } = {
  name: 'sec-default-stand-in',
  tier: 'prepend',
  register: on => {
    on('classic.*', ($, e, next) => next.to(e, 'append'))
  },
}
const withDeps = { plugins: [secDefault, deps] }

const rec = (id: string, over: Record<string, unknown> = {}) => ({
  v: 1,
  sessionId: id,
  cwd: '/repo',
  repoRoot: '/repo',
  startedAt: 0,
  lastSeen: 0,
  closedAt: null,
  transcriptPath: `/t/${id}.jsonl`,
  edits: [],
  extra: {},
  ...over,
})

// What mod-kit's readers give for each request these tests make (commands, writes and git), each
// measured from the reader itself (#712).
const KIT = new Map<string, unknown>([
  // #751: one command writing a file whose note fails beside one whose note lands, measured from
  // mod-kit's readers on 2026-10-05.
  ["commands {\"command\":\"echo x > unwritable.txt; echo y > fine.txt\"}", [["echo","x",">","unwritable.txt"],["echo","y",">","fine.txt"]]],
  ["git {\"words\":[\"echo\",\"x\",\">\",\"unwritable.txt\"]}", null],
  ["git {\"words\":[\"echo\",\"y\",\">\",\"fine.txt\"]}", null],
  ["writes {\"command\":\"echo x > unwritable.txt; echo y > fine.txt\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"unwritable.txt","path":"/repo/unwritable.txt"},{"word":"fine.txt","path":"/repo/fine.txt"}],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"git checkout main\"}", [["git","checkout","main"]]],
  ["git {\"words\":[\"git\",\"checkout\",\"main\"]}", {"sub":"checkout","args":["main"]}],
  ["writes {\"command\":\"git checkout main\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"git -C /other reset --hard origin/main\"}", [["git","-C","/other","reset","--hard","origin/main"]]],
  ["git {\"words\":[\"git\",\"-C\",\"/other\",\"reset\",\"--hard\",\"origin/main\"]}", {"sub":"reset","args":["--hard","origin/main"],"dir":"/other"}],
  ["writes {\"command\":\"git -C /other reset --hard origin/main\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"git status\"}", [["git","status"]]],
  ["git {\"words\":[\"git\",\"status\"]}", {"sub":"status","args":[]}],
  ["writes {\"command\":\"git status\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"printf 'one more line\\\\n' >> notes.txt\"}", [["printf","one more line\\n",">>","notes.txt"]]],
  ["git {\"words\":[\"printf\",\"one more line\\\\n\",\">>\",\"notes.txt\"]}", null],
  ["writes {\"command\":\"printf 'one more line\\\\n' >> notes.txt\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"notes.txt","path":"/repo/notes.txt"}],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"echo done >> notes.txt\"}", [["echo","done",">>","notes.txt"]]],
  ["git {\"words\":[\"echo\",\"done\",\">>\",\"notes.txt\"]}", null],
  ["writes {\"command\":\"echo done >> notes.txt\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"notes.txt","path":"/repo/notes.txt"}],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"printf x >> notes.txt; false\"}", [["printf","x",">>","notes.txt"],["false"]]],
  ["git {\"words\":[\"printf\",\"x\",\">>\",\"notes.txt\"]}", null],
  ["git {\"words\":[\"false\"]}", null],
  ["writes {\"command\":\"printf x >> notes.txt; false\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"notes.txt","path":"/repo/notes.txt"}],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"echo x >> notes.txt\"}", [["echo","x",">>","notes.txt"]]],
  ["git {\"words\":[\"echo\",\"x\",\">>\",\"notes.txt\"]}", null],
  ["writes {\"command\":\"echo x >> notes.txt\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"notes.txt","path":"/repo/notes.txt"}],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"sed -i \\\"\\\" s/a/b/ notes.txt\"}", [["sed","-i","","s/a/b/","notes.txt"]]],
  ["git {\"words\":[\"sed\",\"-i\",\"\",\"s/a/b/\",\"notes.txt\"]}", null],
  ["writes {\"command\":\"sed -i \\\"\\\" s/a/b/ notes.txt\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"notes.txt","path":"/repo/notes.txt","edits":true}],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"cat notes.txt\"}", [["cat","notes.txt"]]],
  ["git {\"words\":[\"cat\",\"notes.txt\"]}", null],
  ["writes {\"command\":\"cat notes.txt\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"python3 -c \\\"open('notes.txt','a').write('x')\\\"\"}", [["python3","-c","open('notes.txt','a').write('x')"]]],
  ["git {\"words\":[\"python3\",\"-c\",\"open('notes.txt','a').write('x')\"]}", null],
  ["writes {\"command\":\"python3 -c \\\"open('notes.txt','a').write('x')\\\"\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[],"changes":[],"unnamed":[{"what":"an inline python3 script","words":["python3","-c","open('notes.txt','a').write('x')"],"inputs":[],"targets":["/repo/notes.txt"]}]}],
  ["commands {\"command\":\"cp /tmp/notes.txt docs\"}", [["cp","/tmp/notes.txt","docs"]]],
  ["git {\"words\":[\"cp\",\"/tmp/notes.txt\",\"docs\"]}", null],
  ["writes {\"command\":\"cp /tmp/notes.txt docs\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"docs","path":"/repo/docs","sources":["/tmp/notes.txt"],"mayBeFolder":true}],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"cp /tmp/x.txt notes.txt\"}", [["cp","/tmp/x.txt","notes.txt"]]],
  ["git {\"words\":[\"cp\",\"/tmp/x.txt\",\"notes.txt\"]}", null],
  ["writes {\"command\":\"cp /tmp/x.txt notes.txt\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"notes.txt","path":"/repo/notes.txt","sources":["/tmp/x.txt"],"mayBeFolder":true}],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"echo x > notes.txt\"}", [["echo","x",">","notes.txt"]]],
  ["git {\"words\":[\"echo\",\"x\",\">\",\"notes.txt\"]}", null],
  ["writes {\"command\":\"echo x > notes.txt\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"notes.txt","path":"/repo/notes.txt"}],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"rm notes.txt\"}", [["rm","notes.txt"]]],
  ["git {\"words\":[\"rm\",\"notes.txt\"]}", null],
  ["writes {\"command\":\"rm notes.txt\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[],"changes":[{"word":"notes.txt","path":"/repo/notes.txt","does":"remove"}],"unnamed":[]}],
  ["commands {\"command\":\"unlink notes.txt\"}", [["unlink","notes.txt"]]],
  ["git {\"words\":[\"unlink\",\"notes.txt\"]}", null],
  ["writes {\"command\":\"unlink notes.txt\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[],"changes":[{"word":"notes.txt","path":"/repo/notes.txt","does":"remove"}],"unnamed":[]}],
  ["commands {\"command\":\"rm -f old.txt\"}", [["rm","-f","old.txt"]]],
  ["git {\"words\":[\"rm\",\"-f\",\"old.txt\"]}", null],
  ["writes {\"command\":\"rm -f old.txt\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[],"changes":[{"word":"old.txt","path":"/repo/old.txt","does":"remove"}],"unnamed":[]}],
  ["commands {\"command\":\"rm -rf src\"}", [["rm","-rf","src"]]],
  ["git {\"words\":[\"rm\",\"-rf\",\"src\"]}", null],
  ["writes {\"command\":\"rm -rf src\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[],"changes":[{"word":"src","path":"/repo/src","does":"remove","tree":true}],"unnamed":[]}],
  ["commands {\"command\":\"mv src /tmp/old-src\"}", [["mv","src","/tmp/old-src"]]],
  ["git {\"words\":[\"mv\",\"src\",\"/tmp/old-src\"]}", null],
  ["writes {\"command\":\"mv src /tmp/old-src\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"/tmp/old-src","path":"/tmp/old-src","sources":["/repo/src"],"mayBeFolder":true}],"changes":[{"word":"src","path":"/repo/src","does":"remove","tree":true}],"unnamed":[]}],
  ["commands {\"command\":\"cp -r /tmp/sub docs; rm -r docs/sub\"}", [["cp","-r","/tmp/sub","docs"],["rm","-r","docs/sub"]]],
  ["git {\"words\":[\"cp\",\"-r\",\"/tmp/sub\",\"docs\"]}", null],
  ["git {\"words\":[\"rm\",\"-r\",\"docs/sub\"]}", null],
  ["writes {\"command\":\"cp -r /tmp/sub docs; rm -r docs/sub\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"docs","path":"/repo/docs","sources":["/tmp/sub"],"mayBeFolder":true}],"changes":[{"word":"docs/sub","path":"/repo/docs/sub","does":"remove","tree":true}],"unnamed":[]}],
  ["commands {\"command\":\"cp /tmp/a.ts docs; rm -r docs\"}", [["cp","/tmp/a.ts","docs"],["rm","-r","docs"]]],
  ["git {\"words\":[\"cp\",\"/tmp/a.ts\",\"docs\"]}", null],
  ["git {\"words\":[\"rm\",\"-r\",\"docs\"]}", null],
  ["writes {\"command\":\"cp /tmp/a.ts docs; rm -r docs\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"docs","path":"/repo/docs","sources":["/tmp/a.ts"],"mayBeFolder":true}],"changes":[{"word":"docs","path":"/repo/docs","does":"remove","tree":true}],"unnamed":[]}],
  ["commands {\"command\":\"echo > d; rm -r d\"}", [["echo",">","d"],["rm","-r","d"]]],
  ["git {\"words\":[\"echo\",\">\",\"d\"]}", null],
  ["git {\"words\":[\"rm\",\"-r\",\"d\"]}", null],
  ["writes {\"command\":\"echo > d; rm -r d\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"d","path":"/repo/d"}],"changes":[{"word":"d","path":"/repo/d","does":"remove","tree":true}],"unnamed":[]}],
  ["commands {\"command\":\"rm '/Users/dan/Documents/Documents - Dan’s MacBook Pro/app.ts'\"}", [["rm","/Users/dan/Documents/Documents - Dan’s MacBook Pro/app.ts"]]],
  ["git {\"words\":[\"rm\",\"/Users/dan/Documents/Documents - Dan’s MacBook Pro/app.ts\"]}", null],
  ["writes {\"command\":\"rm '/Users/dan/Documents/Documents - Dan’s MacBook Pro/app.ts'\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[],"changes":[{"word":"/Users/dan/Documents/Documents - Dan’s MacBook Pro/app.ts","path":"/Users/dan/Documents/Documents - Dan’s MacBook Pro/app.ts","does":"remove"}],"unnamed":[]}],
  ["commands {\"command\":\"rm -r '/Users/dan/Documents/Documents - Dan’s MacBook Pro'\"}", [["rm","-r","/Users/dan/Documents/Documents - Dan’s MacBook Pro"]]],
  ["git {\"words\":[\"rm\",\"-r\",\"/Users/dan/Documents/Documents - Dan’s MacBook Pro\"]}", null],
  ["writes {\"command\":\"rm -r '/Users/dan/Documents/Documents - Dan’s MacBook Pro'\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[],"changes":[{"word":"/Users/dan/Documents/Documents - Dan’s MacBook Pro","path":"/Users/dan/Documents/Documents - Dan’s MacBook Pro","does":"remove","tree":true}],"unnamed":[]}],
  ["commands {\"command\":\"rm -r src/\"}", [["rm","-r","src/"]]],
  ["git {\"words\":[\"rm\",\"-r\",\"src/\"]}", null],
  ["writes {\"command\":\"rm -r src/\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[],"changes":[{"word":"src/","path":"/repo/src","does":"remove","tree":true}],"unnamed":[]}],
  ["commands {\"command\":\"rm -r src\"}", [["rm","-r","src"]]],
  ["git {\"words\":[\"rm\",\"-r\",\"src\"]}", null],
  ["writes {\"command\":\"rm -r src\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[],"changes":[{"word":"src","path":"/repo/src","does":"remove","tree":true}],"unnamed":[]}],
  ["commands {\"command\":\"echo x > /tmp/out.txt && echo y > /private/tmp/claude-501/s/scratchpad/674/n.md && echo z >> notes.txt\"}", [["echo","x",">","/tmp/out.txt"],["echo","y",">","/private/tmp/claude-501/s/scratchpad/674/n.md"],["echo","z",">>","notes.txt"]]],
  ["git {\"words\":[\"echo\",\"x\",\">\",\"/tmp/out.txt\"]}", null],
  ["git {\"words\":[\"echo\",\"y\",\">\",\"/private/tmp/claude-501/s/scratchpad/674/n.md\"]}", null],
  ["git {\"words\":[\"echo\",\"z\",\">>\",\"notes.txt\"]}", null],
  ["writes {\"command\":\"echo x > /tmp/out.txt && echo y > /private/tmp/claude-501/s/scratchpad/674/n.md && echo z >> notes.txt\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"/tmp/out.txt","path":"/tmp/out.txt"},{"word":"/private/tmp/claude-501/s/scratchpad/674/n.md","path":"/private/tmp/claude-501/s/scratchpad/674/n.md"},{"word":"notes.txt","path":"/repo/notes.txt"}],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"echo x > /tmp/out.txt; echo z >> notes.txt\"}", [["echo","x",">","/tmp/out.txt"],["echo","z",">>","notes.txt"]]],
  ["writes {\"command\":\"echo x > /tmp/out.txt; echo z >> notes.txt\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"/tmp/out.txt","path":"/tmp/out.txt"},{"word":"notes.txt","path":"/repo/notes.txt"}],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"echo x > /tmp/shared.txt\"}", [["echo","x",">","/tmp/shared.txt"]]],
  ["git {\"words\":[\"echo\",\"x\",\">\",\"/tmp/shared.txt\"]}", null],
  ["writes {\"command\":\"echo x > /tmp/shared.txt\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"/tmp/shared.txt","path":"/tmp/shared.txt"}],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"echo x >> /wt/feature/notes.txt\"}", [["echo","x",">>","/wt/feature/notes.txt"]]],
  ["git {\"words\":[\"echo\",\"x\",\">>\",\"/wt/feature/notes.txt\"]}", null],
  ["writes {\"command\":\"echo x >> /wt/feature/notes.txt\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"/wt/feature/notes.txt","path":"/wt/feature/notes.txt"}],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"echo a > /tmp/clone/x.txt; echo b > /private/tmp/claude-501/s/scratchpad/700/n.md; echo c > /Volumes/fast/tmp/clone/y.txt; echo d > /Users/dan/Desktop/n.txt; echo e >> notes.txt\"}", [["echo","a",">","/tmp/clone/x.txt"],["echo","b",">","/private/tmp/claude-501/s/scratchpad/700/n.md"],["echo","c",">","/Volumes/fast/tmp/clone/y.txt"],["echo","d",">","/Users/dan/Desktop/n.txt"],["echo","e",">>","notes.txt"]]],
  ["git {\"words\":[\"echo\",\"a\",\">\",\"/tmp/clone/x.txt\"]}", null],
  ["git {\"words\":[\"echo\",\"b\",\">\",\"/private/tmp/claude-501/s/scratchpad/700/n.md\"]}", null],
  ["git {\"words\":[\"echo\",\"c\",\">\",\"/Volumes/fast/tmp/clone/y.txt\"]}", null],
  ["git {\"words\":[\"echo\",\"d\",\">\",\"/Users/dan/Desktop/n.txt\"]}", null],
  ["git {\"words\":[\"echo\",\"e\",\">>\",\"notes.txt\"]}", null],
  ["writes {\"command\":\"echo a > /tmp/clone/x.txt; echo b > /private/tmp/claude-501/s/scratchpad/700/n.md; echo c > /Volumes/fast/tmp/clone/y.txt; echo d > /Users/dan/Desktop/n.txt; echo e >> notes.txt\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"/tmp/clone/x.txt","path":"/tmp/clone/x.txt"},{"word":"/private/tmp/claude-501/s/scratchpad/700/n.md","path":"/private/tmp/claude-501/s/scratchpad/700/n.md"},{"word":"/Volumes/fast/tmp/clone/y.txt","path":"/Volumes/fast/tmp/clone/y.txt"},{"word":"/Users/dan/Desktop/n.txt","path":"/Users/dan/Desktop/n.txt"},{"word":"notes.txt","path":"/repo/notes.txt"}],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"echo x > /Volumes/locked/notes.txt\"}", [["echo","x",">","/Volumes/locked/notes.txt"]]],
  ["git {\"words\":[\"echo\",\"x\",\">\",\"/Volumes/locked/notes.txt\"]}", null],
  ["writes {\"command\":\"echo x > /Volumes/locked/notes.txt\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"/Volumes/locked/notes.txt","path":"/Volumes/locked/notes.txt"}],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"bash <<'EOF'\\necho done >> notes.txt\\nEOF\"}", [["echo","done",">>","notes.txt"]]],
  ["writes {\"command\":\"bash <<'EOF'\\necho done >> notes.txt\\nEOF\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"notes.txt","path":"/repo/notes.txt"}],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"truncate -s 0 notes.txt\"}", [["truncate","-s","0","notes.txt"]]],
  ["git {\"words\":[\"truncate\",\"-s\",\"0\",\"notes.txt\"]}", null],
  ["writes {\"command\":\"truncate -s 0 notes.txt\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[],"changes":[{"word":"notes.txt","path":"/repo/notes.txt","does":"truncate"}],"unnamed":[]}],
  ["commands {\"command\":\"make >& notes.txt\"}", [["make",">&","notes.txt"]]],
  ["git {\"words\":[\"make\",\">&\",\"notes.txt\"]}", null],
  ["writes {\"command\":\"make >& notes.txt\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"notes.txt","path":"/repo/notes.txt"}],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"cat <<EOF\\nnote $(echo done >> notes.txt)\\nEOF\"}", [["echo","done",">>","notes.txt"],["cat","<<EOF"]]],
  ["git {\"words\":[\"cat\",\"<<EOF\"]}", null],
  ["writes {\"command\":\"cat <<EOF\\nnote $(echo done >> notes.txt)\\nEOF\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"notes.txt","path":"/repo/notes.txt"}],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"echo \\\"note `echo done >> notes.txt`\\\"\"}", [["echo","done",">>","notes.txt"],["echo","note `echo done >> notes.txt`"]]],
  ["git {\"words\":[\"echo\",\"note `echo done >> notes.txt`\"]}", null],
  ["writes {\"command\":\"echo \\\"note `echo done >> notes.txt`\\\"\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"notes.txt","path":"/repo/notes.txt"}],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"cat <<'EOF'\\nnote $(echo done >> notes.txt)\\nEOF\"}", [["cat","<<EOF"]]],
  ["writes {\"command\":\"cat <<'EOF'\\nnote $(echo done >> notes.txt)\\nEOF\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"echo 'note `echo done >> notes.txt`'\"}", [["echo","note `echo done >> notes.txt`"]]],
  ["writes {\"command\":\"echo 'note `echo done >> notes.txt`'\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"echo \\\"on $(git checkout main)\\\"\"}", [["git","checkout","main"],["echo","on $(git checkout main)"]]],
  ["git {\"words\":[\"echo\",\"on $(git checkout main)\"]}", null],
  ["writes {\"command\":\"echo \\\"on $(git checkout main)\\\"\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"echo \\\"on `git checkout main`\\\"\"}", [["git","checkout","main"],["echo","on `git checkout main`"]]],
  ["git {\"words\":[\"echo\",\"on `git checkout main`\"]}", null],
  ["writes {\"command\":\"echo \\\"on `git checkout main`\\\"\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"cat <<EOF\\non $(git checkout main)\\nEOF\"}", [["git","checkout","main"],["cat","<<EOF"]]],
  ["writes {\"command\":\"cat <<EOF\\non $(git checkout main)\\nEOF\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"echo 'on $(git checkout main)'\"}", [["echo","on $(git checkout main)"]]],
  ["writes {\"command\":\"echo 'on $(git checkout main)'\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"cat <<'EOF'\\non $(git checkout main)\\nEOF\"}", [["cat","<<EOF"]]],
  ["writes {\"command\":\"cat <<'EOF'\\non $(git checkout main)\\nEOF\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"bash -c 'echo done >> notes.txt'\"}", [["echo","done",">>","notes.txt"]]],
  ["writes {\"command\":\"bash -c 'echo done >> notes.txt'\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"notes.txt","path":"/repo/notes.txt"}],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"sh -c 'echo \\\"$(echo done >> notes.txt)\\\"'\"}", [["echo","done",">>","notes.txt"],["echo","$(echo done >> notes.txt)"]]],
  ["git {\"words\":[\"echo\",\"$(echo done >> notes.txt)\"]}", null],
  ["writes {\"command\":\"sh -c 'echo \\\"$(echo done >> notes.txt)\\\"'\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"notes.txt","path":"/repo/notes.txt"}],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"zsh -c 'echo \\\"`echo done >> notes.txt`\\\"'\"}", [["echo","done",">>","notes.txt"],["echo","`echo done >> notes.txt`"]]],
  ["git {\"words\":[\"echo\",\"`echo done >> notes.txt`\"]}", null],
  ["writes {\"command\":\"zsh -c 'echo \\\"`echo done >> notes.txt`\\\"'\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"notes.txt","path":"/repo/notes.txt"}],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"sh <<'EOF'\\nx=$(echo done >> notes.txt)\\nEOF\"}", [["echo","done",">>","notes.txt"]]],
  ["writes {\"command\":\"sh <<'EOF'\\nx=$(echo done >> notes.txt)\\nEOF\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"notes.txt","path":"/repo/notes.txt"}],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"echo 'echo done >> notes.txt' | bash\"}", [["echo","echo done >> notes.txt"],["echo","done",">>","notes.txt"]]],
  ["git {\"words\":[\"echo\",\"echo done >> notes.txt\"]}", null],
  ["writes {\"command\":\"echo 'echo done >> notes.txt' | bash\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"notes.txt","path":"/repo/notes.txt"}],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"diff <(echo done >> notes.txt) b.txt\"}", [["echo","done",">>","notes.txt"],["diff","<(echo done >> notes.txt)","b.txt"]]],
  ["writes {\"command\":\"diff <(echo done >> notes.txt) b.txt\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"notes.txt","path":"/repo/notes.txt"}],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"tee >(cat >> notes.txt) < b.txt\"}", [["cat",">>","notes.txt"],["tee",">(cat >> notes.txt)","<","b.txt"]]],
  ["git {\"words\":[\"cat\",\">>\",\"notes.txt\"]}", null],
  ["writes {\"command\":\"tee >(cat >> notes.txt) < b.txt\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"notes.txt","path":"/repo/notes.txt"}],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"cat > /dev/null <<'EOF'\\necho done >> notes.txt $(echo done >> notes.txt) <(echo done >> notes.txt)\\nEOF\"}", [["cat",">","/dev/null","<<EOF"]]],
  ["git {\"words\":[\"cat\",\">\",\"/dev/null\",\"<<EOF\"]}", null],
  ["writes {\"command\":\"cat > /dev/null <<'EOF'\\necho done >> notes.txt $(echo done >> notes.txt) <(echo done >> notes.txt)\\nEOF\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"echo \\\"<(echo done >> notes.txt)\\\"\"}", [["echo","<(echo done >> notes.txt)"]]],
  ["git {\"words\":[\"echo\",\"<(echo done >> notes.txt)\"]}", null],
  ["writes {\"command\":\"echo \\\"<(echo done >> notes.txt)\\\"\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[],"changes":[],"unnamed":[]}],
  ["git {\"words\":[\"diff\",\"<(echo done >> notes.txt)\",\"b.txt\"]}", null],
  ["git {\"words\":[\"tee\",\">(cat >> notes.txt)\",\"<\",\"b.txt\"]}", null],
  ["commands {\"command\":\"bash <<EOF\\necho \\\\$(echo done >> notes.txt)\\nEOF\"}", [["echo","done",">>","notes.txt"],["echo","$(echo done >> notes.txt)"]]],
  ["writes {\"command\":\"bash <<EOF\\necho \\\\$(echo done >> notes.txt)\\nEOF\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"notes.txt","path":"/repo/notes.txt"}],"changes":[],"unnamed":[]}],
])

type Judge = string | 'no-answer'
// Each send's outcome in turn: delivered, refused with this reason, or a throw.
type Send = true | { refused: string } | 'throws'
// How the call fares beneath the guard: it runs (the default), it runs and fails, or a later guard
// refuses it.
type Ran = 'ok' | 'error' | { deny: string }
type Opts = { self?: Record<string, unknown>; open?: unknown[]; unreadable?: string[]; judge?: Judge; repo?: string; branch?: string | { fails: string }; branchReaderFails?: string; sends?: Send[]; tail?: 'fails' | 'no-request'; ran?: Ran; gits?: Record<string, 'dir' | 'file'>; locked?: string; tmpdir?: string; listBreaks?: boolean }

const ok = (stdout: string) => ({ value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } })

// The Mac and the model beneath the guard. Everything that gets past it, every question put to the
// judge, every message sent and every card and toast is recorded.
const world = (engine: Engine, on: On, o: Opts = {}) => {
  const w = { o, reached: [] as string[], prompts: [] as { model: string; prompt: string }[], sent: [] as { to: unknown; text: string }[], toasts: [] as string[], cards: [] as Record<string, unknown>[], edits: [] as string[], runs: [] as string[] }
  on('process.run', function answer($, e) {
    const [cmd, ...args] = e.argv
    // mod-kit's readers, answered from the table; a request it has no answer for fails the test by
    // name rather than being read some other way. Not one of the runs a test watches.
    if (cmd === '__modkit' && args[0] === 'branch') {
      // Where a checkout stands (#980), read by a byte for byte copy of mod-kit's reader asking this
      // world's git; every folder is a checkout of its own here, as the git answers below treat it.
      if (o.branchReaderFails) return { value: { exitCode: 1, stdout: '', stderr: o.branchReaderFails, isStdoutTruncated: false, isStderrTruncated: false } }
      const { path } = JSON.parse(args[1] as string) as { path: string }
      const git = async (argv: string[]) => ((await answer($, { ...e, argv })) as { value: { exitCode: number; stdout: string; stderr: string } }).value
      return branchAt(path, async p => p, git).then(b => ok(b === null ? '' : JSON.stringify(b))) as never
    }
    if (cmd === '__modkit') {
      const key = `${args[0]} ${args[1]}`
      if (!KIT.has(key)) throw new Error(`the reader table has no answer for ${key}: measure it from mod-kit's reader and add it`)
      const out = KIT.get(key)
      return ok(out === null ? '' : JSON.stringify(out))
    }
    w.runs.push(e.argv.join(' '))
    if (cmd === '__sessions' && o.listBreaks) return ok('not json')
    if (cmd === '__sessions') return ok(JSON.stringify({ open: [rec('me', o.self), ...(o.open ?? [])], closed: [], unreadable: o.unreadable ?? [], selfId: 'me' }))
    if (cmd === 'tail' && o.tail === 'fails') return { value: { exitCode: 1, stdout: '', stderr: 'Permission denied', isStdoutTruncated: false, isStderrTruncated: false } }
    if (cmd === 'tail' && o.tail === 'no-request') return ok(JSON.stringify({ type: 'assistant', message: { role: 'assistant', content: 'hi' } }) + '\n')
    if (cmd === 'tail') {
      const user = { type: 'user', message: { role: 'user', content: 'restyle the invoice table' } }
      return ok(JSON.stringify(user) + '\n')
    }
    if (cmd === 'git' && args.includes('rev-parse')) return ok((o.repo ?? '/repo') + '\n')
    if (cmd === 'git' && args.includes('status')) return ok(' M src/InvoiceTable.tsx\n')
    // The branch each checkout is on: main unless a test says otherwise ('' is a detached head).
    if (cmd === 'git' && args.includes('branch')) {
      const b = o.branch ?? 'main'
      return typeof b === 'string' ? ok(`${b}\n`) : { value: { exitCode: 128, stdout: '', stderr: b.fails, isStdoutTruncated: false, isStderrTruncated: false } }
    }
    if (cmd === 'git' && args.includes('worktree')) return ok(`worktree ${o.repo ?? '/repo'}\nHEAD abc\nbranch refs/heads/main\n`)
    if (cmd === 'git' && args.includes('symbolic-ref')) return ok('origin/main\n')
    return { value: { exitCode: 1, stdout: '', stderr: 'unexpected', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('model.complete', ($, e) => {
    const req = e as unknown as { model: string; prompt: string }
    w.prompts.push({ model: req.model, prompt: req.prompt })
    if (o.judge === 'no-answer') return { value: { isAnswered: false, reason: 'api-error', status: 529, error: 'overloaded', usage: {} } } as never
    return { value: { isAnswered: true, text: o.judge ?? '{"verdict":"Proceed","reason":"They only read it."}', usage: {} } } as never
  })
  let sends = 0
  on('session.send', ($, e) => {
    w.sent.push(e as never)
    const outcome = o.sends?.[sends++] ?? true
    if (outcome === 'throws') throw new Error('the session has ended')
    if (outcome === true) return { isDelivered: true } as never
    return { isDelivered: false, reason: outcome.refused } as never
  })
  on('session.cwd', () => ({ value: '/repo' }) as never)
  // The .git entries on the disk, a folder or a linked worktree's file; anything else is no entry,
  // and a folder under `locked` is one the disk cannot read (a hook that throws is skipped by the
  // engine, so the world says so as a kind of its own, which the stand-in walk refuses on).
  const gits = o.gits
  const locked = o.locked
  if (gits || locked) {
    on('fs.stat', ($, e) => {
      const path = (e as unknown as { path: string }).path
      const kind = locked && path.startsWith(locked) ? 'unreadable' : (gits?.[path] ?? 'other')
      return { value: { kind, size: 0, mtimeMs: 0, isLink: false } } as never
    })
  }
  const tmpdir = o.tmpdir
  if (tmpdir) on('env.get', ($, e) => ({ value: (e as unknown as { name: string }).name === 'TMPDIR' ? tmpdir : undefined }) as never)
  on('ui.toast', ($, e) => {
    w.toasts.push(e.text)
    return { value: undefined }
  })
  on('ui.log', ($, e) => {
    if (e.text.startsWith('CARD ')) w.cards.push(JSON.parse(e.text.slice(5)))
    if (e.text.startsWith('EDIT ')) w.edits.push(e.text.slice(5))
    return { value: undefined }
  })
  on('clock.after', () => ({ value: undefined }) as never)
  // Core, standing in: the engine decides whether the call may run (the tool.check chain over every
  // plugin, with the call's id and its arguments as the permission decision reads them), then runs
  // it. The harness raises classic.PreToolUse above this hook as a session does, but not tool.check,
  // so it is raised here. Beneath every plugin's tool.check hook the rules allow the call.
  on('tool.check', () => ({ decision: 'allow' }))
  on('tool.call', async ($, e) => {
    const { tool, tool_use_id, agentId: _a, consent: _c, ...input } = e as unknown as Record<string, unknown>
    const verdict = await engine.tool.check({ tool: String(tool), input, ...(tool_use_id === undefined ? {} : { tool_use_id: String(tool_use_id) }) } as never)
    // A refusal there reaches the call as core reports it, an errored result whose text is the reason.
    if (verdict.decision === 'deny') return { isError: true, result: verdict.reason, text: verdict.reason ?? 'denied' } as never
    if (typeof o.ran === 'object') return { deny: o.ran.deny } as never
    w.reached.push(e.tool)
    if (o.ran === 'error') return { result: 'exit status 1', text: 'exit status 1', isError: true } as never
    return { result: 'ran', text: 'ran' } as never
  })
  return w
}

const edit = (path: string, id = 'c1') => ({ tool: 'Edit', file_path: path, old_string: 'a', new_string: 'b', tool_use_id: id }) as never
const bash = (command: string, id = 'c1') => ({ tool: 'Bash', command, tool_use_id: id }) as never
const refusal = (r: unknown) => {
  const x = r as { deny?: string; text?: string }
  return x.deny ?? x.text ?? ''
}

test('an edit nobody else is making goes through and is noted for the others', withDeps, async ($, on) => {
  const w = world($, on)
  await $.tool.call(edit('/repo/src/a.ts'))
  expect(w.reached).toContain('Edit')
  expect(w.prompts.length).toBe(0)
  expect(w.edits).toEqual(['/repo/src/a.ts'])
})

test('a note the registry cannot write never fails the call that already ran, and is said once (#751)', withDeps, async ($, on) => {
  const w = world($, on)
  const first = (await $.tool.call(edit('/repo/src/unwritable.ts', 'c1'))) as { isError?: boolean; text?: string; context?: string[] }
  expect(w.reached).toContain('Edit')
  expect(first.isError).not.toBe(true)
  expect(first.text).toBe('ran')
  expect((first.context ?? []).join(' ')).toContain("could not record that this session edited /repo/src/unwritable.ts: this session's record could not be written")
  // Said once until a note lands, never on every call.
  const second = (await $.tool.call(edit('/repo/src/unwritable.ts', 'c2'))) as { context?: string[] }
  expect((second.context ?? []).join(' ')).not.toContain('could not record')
  // One that lands rearms it.
  await $.tool.call(edit('/repo/src/fine.ts', 'c3'))
  expect(w.edits).toEqual(['/repo/src/fine.ts'])
  const again = (await $.tool.call(edit('/repo/src/unwritable.ts', 'c4'))) as { context?: string[] }
  expect((again.context ?? []).join(' ')).toContain('could not record')
})

test('a call whose notes partly land is still said once, never on every such call (#751)', withDeps, async ($, on) => {
  const w = world($, on)
  const said = async (id: string) => (((await $.tool.call(bash('echo x > unwritable.txt; echo y > fine.txt', id))) as { context?: string[] }).context ?? []).join(' ')
  expect(await said('m1')).toContain('could not record that this session edited /repo/unwritable.txt')
  expect(w.edits).toEqual(['/repo/fine.txt'])
  expect(await said('m2')).not.toContain('could not record')
  expect(await said('m3')).not.toContain('could not record')
})

test('an edit another open session made first is judged, and a Proceed goes through with a toast', withDeps, async ($, on) => {
  const w = world($, on, { open: [rec('them', { edits: ['/repo/src/InvoiceTable.tsx'] })] })
  await $.tool.call(edit('/repo/src/InvoiceTable.tsx'))
  expect(w.reached).toContain('Edit')
  expect(w.prompts[0]?.model).toBe('claude-sonnet-5-5')
  // The judge sees what the other session was last asked, read from its transcript.
  expect(w.prompts[0]?.prompt).toContain('restyle the invoice table')
  expect(w.prompts[0]?.prompt).toContain('/repo/src/InvoiceTable.tsx')
  expect(w.toasts).toContain('Checked with the other session: safe to edit InvoiceTable.tsx.')
})

test('a Worktree verdict blocks with the card and tells the other session', withDeps, async ($, on) => {
  const w = world($, on, { open: [rec('them', { edits: ['/repo/src/InvoiceTable.tsx'] })], judge: '{"verdict":"Worktree","reason":"Both change the header row."}' })
  const r = await $.tool.call(edit('/repo/src/InvoiceTable.tsx', 'wt1'))
  expect(w.reached).not.toContain('Edit')
  expect(refusal(r)).toBe(
    'Blocked: Another session is working on InvoiceTable.tsx. Both change the header row. Move this work to its own worktree and redo it there.',
  )
  expect(w.cards).toEqual([
    {
      toolUseId: 'wt1',
      guard: 'Collision guard',
      reason: 'Another session is working on InvoiceTable.tsx. Both change the header row.',
      safeWay: 'Move this work to its own worktree and redo it there.',
    },
  ])
  // The engine sends to the session by its id, stamped as coming from this mod.
  expect(w.sent).toEqual([
    {
      to: 'them',
      text: 'Another session wanted to edit "src/InvoiceTable.tsx" while you are working on it, so it was moved to its own worktree to redo its change there. Nothing here was touched.',
      origin: { kind: 'plugin', name: 'collision-guard' },
    },
  ])
})

test('a Stop verdict blocks with the card and tells the other session', withDeps, async ($, on) => {
  const w = world($, on, { open: [rec('them', { edits: ['/repo/src/InvoiceTable.tsx'] })], judge: '{"verdict":"Stop","reason":"They are mid rebase."}' })
  const r = await $.tool.call(edit('/repo/src/InvoiceTable.tsx'))
  expect(refusal(r)).toBe('Blocked: Another session is working on InvoiceTable.tsx. They are mid rebase. Leave it to the other session, or ask Dan.')
  expect(w.sent[0]?.text).toBe('Another session wanted to edit "src/InvoiceTable.tsx" while you are working on it, so it was stopped. Nothing here was touched.')
})

test('a judge that cannot answer stops the edit (the spec, L42)', withDeps, async ($, on) => {
  const w = world($, on, { open: [rec('them', { edits: ['/repo/src/a.ts'] })], judge: 'no-answer' })
  const r = await $.tool.call(edit('/repo/src/a.ts'))
  expect(w.reached).not.toContain('Edit')
  expect(refusal(r)).toBe("Blocked: Couldn't check with the other session's work, so this was stopped. Try again, or ask Dan.")
})

test('a verdict that cannot be read stops the edit too', withDeps, async ($, on) => {
  const w = world($, on, { open: [rec('them', { edits: ['/repo/src/a.ts'] })], judge: 'Sure, go ahead.' })
  await $.tool.call(edit('/repo/src/a.ts'))
  expect(w.reached).not.toContain('Edit')
})

test('a record that cannot be read stops a watched action and names it (Dan, 2026-10-03)', withDeps, async ($, on) => {
  const w = world($, on, { unreadable: ['abc.json'] })
  const r = await $.tool.call(edit('/repo/src/a.ts'))
  expect(w.reached).not.toContain('Edit')
  expect(refusal(r)).toBe(
    "Blocked: Couldn't read another session's record (abc.json), so this was stopped. Delete the damaged file in ~/.claude/state/sessions, or ask Dan.",
  )
})

test('a branch switch in a checkout another session works in is judged', withDeps, async ($, on) => {
  const w = world($, on, { open: [rec('them')], judge: '{"verdict":"Stop","reason":"They have uncommitted work."}' })
  const r = await $.tool.call(bash('git checkout main'))
  expect(w.reached).not.toContain('Bash')
  expect(refusal(r)).toBe('Blocked: Another session is working in this checkout. They have uncommitted work. Leave it to the other session, or ask Dan.')
  expect(w.sent[0]?.text).toBe('Another session wanted to run git checkout main in this checkout while you are working in it, so it was stopped. Nothing here was touched.')
})

// The branch the judge is told the checkout is on, pinned before the read moved onto mod-kit's
// branch reader (#980): the branch git names, or (unknown) for a detached head or a read that fails.
test('the judge is told the branch the checkout is on, or (unknown) when git names none (#980)', withDeps, async ($, on) => {
  const cases: [Opts['branch'], string][] = [
    [undefined, 'The checkout: /repo, on branch main, with changes:'],
    ['issue-980-reader', 'The checkout: /repo, on branch issue-980-reader, with changes:'],
    ['', 'The checkout: /repo, on branch (unknown), with changes:'],
    [{ fails: 'fatal: not a git repository' }, 'The checkout: /repo, on branch (unknown), with changes:'],
  ]
  const w = world($, on, { open: [rec('them')] })
  const o = w.o
  for (const [i, [branch, said]] of cases.entries()) {
    o.branch = branch
    await $.tool.call(bash('git checkout main', `b${i}`))
    expect(w.prompts[i]?.prompt).toContain(said)
  }
})

test("a branch mod-kit's reader cannot give is (unknown) to the judge, and the call is still judged (#980)", withDeps, async ($, on) => {
  const w = world($, on, { open: [rec('them')], branchReaderFails: 'mod-kit is not loaded' })
  await $.tool.call(bash('git checkout main'))
  expect(w.prompts[0]?.prompt).toContain('The checkout: /repo, on branch (unknown), with changes:')
  expect(w.reached).toContain('Bash')
  // Asked of mod-kit, never of git by hand.
  expect(w.runs.filter(r => r.includes('--show-current'))).toEqual([])
})

test('a branch switch with nobody else in the checkout goes through unjudged', withDeps, async ($, on) => {
  const w = world($, on, { open: [rec('elsewhere', { repoRoot: '/other' })] })
  await $.tool.call(bash('git checkout main'))
  expect(w.reached).toContain('Bash')
  expect(w.prompts.length).toBe(0)
})

test('a git -C into another checkout is judged against that checkout', withDeps, async ($, on) => {
  const w = world($, on, { open: [rec('them', { repoRoot: '/other' })], repo: '/other' })
  await $.tool.call(bash('git -C /other reset --hard origin/main'))
  expect(w.prompts.length).toBe(1)
  expect(w.prompts[0]?.prompt).toContain('git reset --hard origin/main')
})

test('an ordinary git command is not judged', withDeps, async ($, on) => {
  const w = world($, on, { open: [rec('them')] })
  await $.tool.call(bash('git status'))
  expect(w.reached).toContain('Bash')
  expect(w.prompts.length).toBe(0)
})

// The live check of #639 (2026-10-04): a guard message delivered to an interactive session arrived
// with origin { kind: 'peer', plugin: 'collision-guard', name: <the sending session's own name> }.
// So the plugin field names the guard, and `name` is a session name anybody could choose.
const MEASURED = { kind: 'peer', from: 'uds:/tmp/cc-socks/2012.sock', plugin: 'collision-guard', name: 'collision-throwaway-1004' }

test('the session that was working first gets a toast when it hears from the guard, in the shape the live check delivered before #700', withDeps, async ($, on) => {
  const w = world($, on)
  on('session.receive', ($, e) => ({ text: e.text }) as never)
  await $.session.receive({
    origin: MEASURED,
    text: 'Another session wanted to edit src/app.ts while you are working on it, so it was moved to its own worktree to redo its change there. Nothing here was touched.',
  } as never)
  expect(w.toasts).toContain('Another session wanted app.ts; it was moved to a worktree.')
})

test('a checkout wide action names the command in the toast, as delivered live', withDeps, async ($, on) => {
  const w = world($, on)
  on('session.receive', ($, e) => ({ text: e.text }) as never)
  await $.session.receive({
    origin: MEASURED,
    text: 'Another session wanted to run git switch -c window-two in this checkout while you are working in it, so it was moved to its own worktree to redo its change there. Nothing here was touched.',
  } as never)
  expect(w.toasts).toContain('Another session wanted git switch -c window-two; it was moved to a worktree.')
})

test('a session that merely calls itself collision-guard is not taken for the guard', withDeps, async ($, on) => {
  const w = world($, on)
  on('session.receive', ($, e) => ({ text: e.text }) as never)
  await $.session.receive({
    origin: { kind: 'peer', name: 'collision-guard' },
    text: 'Another session wanted to run git checkout main in this checkout while you are working in it, so it was stopped. Nothing here was touched.',
  } as never)
  expect(w.toasts).toEqual([])
})

const clash = (over: Opts = {}) => ({ open: [rec('them', { edits: ['/repo/src/InvoiceTable.tsx'] })], judge: '{"verdict":"Worktree","reason":"Both change the header row."}', ...over })

// The live check of #605 (2026-10-04): the message to the other session was refused (auto mode's
// classifier gave no verdict) and nothing said so. Decided with Dan: retry once, then say it on the card.
test('a send refused once is tried again, and a second try that lands says nothing more', withDeps, async ($, on) => {
  const w = world($, on, clash({ sends: [{ refused: 'Classifier unavailable' }, true] }))
  const r = await $.tool.call(edit('/repo/src/InvoiceTable.tsx', 'wt2'))
  expect(w.sent.length).toBe(2)
  expect(w.cards[0]?.note).toBeUndefined()
  expect(refusal(r)).not.toContain('could not be told')
})

test('a send refused twice is said on the card and in the refusal Claude reads', withDeps, async ($, on) => {
  const w = world($, on, clash({ sends: [{ refused: 'Classifier unavailable' }, { refused: 'Classifier unavailable' }] }))
  const r = await $.tool.call(edit('/repo/src/InvoiceTable.tsx', 'wt3'))
  expect(w.sent.length).toBe(2)
  expect(w.reached).not.toContain('Edit')
  expect(w.cards[0]?.note).toBe('The other session could not be told: Classifier unavailable.')
  expect(refusal(r)).toBe(
    'Blocked: Another session is working on InvoiceTable.tsx. Both change the header row. Move this work to its own worktree and redo it there. The other session could not be told: Classifier unavailable.',
  )
})

test('a send that throws is not tried again, since it may have landed, and is said with the error', withDeps, async ($, on) => {
  const w = world($, on, clash({ sends: ['throws', true] }))
  await $.tool.call(edit('/repo/src/InvoiceTable.tsx', 'wt4'))
  expect(w.sent.length).toBe(1)
  // The engine turns a throwing hook into its own error, so that is the text that arrives here.
  expect(w.cards[0]?.note).toBe('The other session could not be told: no implementation for session.send.')
})

test('a session whose transcript was not found is told to the judge as such', withDeps, async ($, on) => {
  const w = world($, on, clash({ open: [rec('them', { edits: ['/repo/src/InvoiceTable.tsx'], transcriptPath: null })] }))
  await $.tool.call(edit('/repo/src/InvoiceTable.tsx'))
  expect(w.prompts[0]?.prompt).toContain('Its latest request: (its transcript could not be found)')
})

test('a transcript that cannot be read is told to the judge as unreadable', withDeps, async ($, on) => {
  const w = world($, on, clash({ tail: 'fails' }))
  await $.tool.call(edit('/repo/src/InvoiceTable.tsx'))
  expect(w.prompts[0]?.prompt).toContain('Its latest request: (its transcript could not be read)')
})

test('a transcript with no request in it is told to the judge as such', withDeps, async ($, on) => {
  const w = world($, on, clash({ tail: 'no-request' }))
  await $.tool.call(edit('/repo/src/InvoiceTable.tsx'))
  expect(w.prompts[0]?.prompt).toContain('Its latest request: (none in its transcript)')
})

// #654: in the live check of #639 a session appended to a file with printf, its record kept no
// edits, and a second session editing that file would not have been judged.
test("the live check's printf append is noted as this session's edit, unjudged with nobody else on it", withDeps, async ($, on) => {
  const w = world($, on)
  await $.tool.call(bash(`printf 'one more line\\n' >> notes.txt`))
  expect(w.reached).toContain('Bash')
  expect(w.prompts.length).toBe(0)
  expect(w.edits).toEqual(['/repo/notes.txt'])
})

test('a shell write to a file another open session edited is judged like an edit, and a Stop blocks it', withDeps, async ($, on) => {
  const w = world($, on, { open: [rec('them', { edits: ['/repo/notes.txt'] })], judge: '{"verdict":"Stop","reason":"They are rewriting the notes."}' })
  const r = await $.tool.call(bash('echo done >> notes.txt', 'sh1'))
  expect(w.reached).not.toContain('Bash')
  expect(w.prompts[0]?.prompt).toContain('/repo/notes.txt')
  expect(w.prompts[0]?.prompt).toContain('echo done >> notes.txt')
  expect(refusal(r)).toBe('Blocked: Another session is working on notes.txt. They are rewriting the notes. Leave it to the other session, or ask Dan.')
  expect(w.cards[0]?.toolUseId).toBe('sh1')
  expect(w.sent[0]?.text).toBe('Another session wanted to edit "notes.txt" while you are working on it, so it was stopped. Nothing here was touched.')
  // Blocked, so it wrote nothing and is not noted.
  expect(w.edits).toEqual([])
})

// The decided rule (docs/mods-design.md, #654), pinned for #700: a command that ran is recorded even
// when it failed, since it may have written before it failed; only a refusal, a later guard's
// included, leaves the record alone.
test('a shell write whose command failed is still noted, since it may have written first', withDeps, async ($, on) => {
  const w = world($, on, { ran: 'error' })
  const r = await $.tool.call(bash('printf x >> notes.txt; false'))
  expect(w.reached).toContain('Bash')
  expect((r as { isError?: boolean }).isError).toBe(true)
  expect(w.edits).toEqual(['/repo/notes.txt'])
})

// A refusal from Claude Code's own permission step comes after the guard has judged, the one
// refusal it cannot wait for (#707: every guard's refusal comes first, tested below).
test('a shell write refused after it was judged, by the permission step, is not noted, and the refusal is passed on', withDeps, async ($, on) => {
  const w = world($, on, { open: [rec('them', { edits: ['/repo/notes.txt'] })], ran: { deny: 'Permission to use Bash was denied.' } })
  const r = await $.tool.call(bash('echo x >> notes.txt'))
  expect(w.toasts).toContain('Checked with the other session: safe to edit notes.txt.')
  expect(refusal(r)).toBe('Permission to use Bash was denied.')
  expect(w.edits).toEqual([])
})

test('a shell write judged Proceed goes through with the toast and is noted', withDeps, async ($, on) => {
  const w = world($, on, { open: [rec('them', { edits: ['/repo/notes.txt'] })] })
  await $.tool.call(bash('sed -i "" s/a/b/ notes.txt'))
  expect(w.reached).toContain('Bash')
  expect(w.toasts).toContain('Checked with the other session: safe to edit notes.txt.')
  expect(w.edits).toEqual(['/repo/notes.txt'])
})

test('a read only command on a file another session edited is neither judged nor noted', withDeps, async ($, on) => {
  const w = world($, on, { open: [rec('them', { edits: ['/repo/notes.txt'] })] })
  await $.tool.call(bash('cat notes.txt'))
  expect(w.reached).toContain('Bash')
  expect(w.prompts.length).toBe(0)
  expect(w.edits).toEqual([])
})

// Decided (docs/mods-design.md, #654): a write the command reader cannot see is not guessed at.
test('a script that writes the file is not seen, so it is neither judged nor noted', withDeps, async ($, on) => {
  const w = world($, on, { open: [rec('them', { edits: ['/repo/notes.txt'] })] })
  await $.tool.call(bash(`python3 -c "open('notes.txt','a').write('x')"`))
  expect(w.reached).toContain('Bash')
  expect(w.prompts.length).toBe(0)
  expect(w.edits).toEqual([])
})

test('a cp into a folder writes the file of the same name inside it', withDeps, async ($, on) => {
  const w = world($, on, { open: [rec('them', { edits: ['/repo/docs/notes.txt'] })] })
  on('fs.stat', ($, e) => ({ value: { kind: (e as unknown as { path: string }).path === '/repo/docs' ? 'dir' : 'other', size: 0, mtimeMs: 0, isLink: false } }) as never)
  await $.tool.call(bash('cp /tmp/notes.txt docs'))
  expect(w.prompts[0]?.prompt).toContain('/repo/docs/notes.txt')
  expect(w.edits).toEqual(['/repo/docs/notes.txt'])
})

test('a cp onto a path that cannot be looked at is taken as that file', withDeps, async ($, on) => {
  const w = world($, on, { open: [rec('them', { edits: ['/repo/notes.txt'] })] })
  await $.tool.call(bash('cp /tmp/x.txt notes.txt'))
  expect(w.prompts.length).toBe(1)
  expect(w.edits).toEqual(['/repo/notes.txt'])
})

test('a shell write with a record that cannot be read is stopped, as an edit is', withDeps, async ($, on) => {
  const w = world($, on, { unreadable: ['abc.json'] })
  const r = await $.tool.call(bash('echo x > notes.txt'))
  expect(w.reached).not.toContain('Bash')
  expect(refusal(r)).toContain("Couldn't read another session's record (abc.json)")
  expect(w.edits).toEqual([])
})

test('a shell write the judge cannot answer is stopped (L42)', withDeps, async ($, on) => {
  const w = world($, on, { open: [rec('them', { edits: ['/repo/notes.txt'] })], judge: 'no-answer' })
  const r = await $.tool.call(bash('echo x > notes.txt'))
  expect(w.reached).not.toContain('Bash')
  expect(refusal(r)).toBe("Blocked: Couldn't check with the other session's work, so this was stopped. Try again, or ask Dan.")
})

// #674: rm takes away a file another session is working on, the most destructive write there is.
test('an rm of a file another open session edited is judged, and a Stop blocks it with the card and the message', withDeps, async ($, on) => {
  const w = world($, on, { open: [rec('them', { edits: ['/repo/notes.txt'] })], judge: '{"verdict":"Stop","reason":"They are still writing it."}' })
  const r = await $.tool.call(bash('rm notes.txt', 'rm1'))
  expect(w.reached).not.toContain('Bash')
  expect(w.prompts[0]?.prompt).toContain('remove /repo/notes.txt with the shell command: rm notes.txt')
  expect(refusal(r)).toBe('Blocked: Another session is working on notes.txt. They are still writing it. Leave it to the other session, or ask Dan.')
  expect(w.cards[0]?.toolUseId).toBe('rm1')
  // Dan, 2026-10-04 (#700): a removal says remove, where #674 had kept the edit words.
  expect(w.sent[0]?.text).toBe('Another session wanted to remove "notes.txt" while you are working on it, so it was stopped. Nothing here was touched.')
  expect(w.edits).toEqual([])
})

test('an rm of a file another open session edited, judged Proceed, says safe to remove', withDeps, async ($, on) => {
  const w = world($, on, { open: [rec('them', { edits: ['/repo/notes.txt'] })] })
  await $.tool.call(bash('unlink notes.txt'))
  expect(w.toasts).toEqual(['Checked with the other session: safe to remove notes.txt.'])
  expect(w.reached).toContain('Bash')
})

test('an rm of a file nobody else edited goes through unjudged and is noted', withDeps, async ($, on) => {
  const w = world($, on, { open: [rec('them', { edits: ['/repo/other.txt'] })] })
  await $.tool.call(bash('rm -f old.txt'))
  expect(w.reached).toContain('Bash')
  expect(w.prompts.length).toBe(0)
  expect(w.edits).toEqual(['/repo/old.txt'])
})

test('an rm -r of a folder holding a file another session edited is judged on that file', withDeps, async ($, on) => {
  const w = world($, on, { open: [rec('them', { edits: ['/repo/src/deep/InvoiceTable.tsx', '/repo/README.md'] })] })
  await $.tool.call(bash('rm -rf src'))
  expect(w.prompts.length).toBe(1)
  expect(w.prompts[0]?.prompt).toContain('remove /repo/src and everything in it, including /repo/src/deep/InvoiceTable.tsx, with the shell command: rm -rf src')
  expect(w.toasts).toContain('Checked with the other session: safe to remove InvoiceTable.tsx.')
  expect(w.reached).toContain('Bash')
  expect(w.edits).toEqual(['/repo/src'])
})

test('an mv of a folder holding a file another session edited is judged on that file', withDeps, async ($, on) => {
  const w = world($, on, { open: [rec('them', { edits: ['/repo/src/a.ts'] })], judge: '{"verdict":"Stop","reason":"They are editing it."}' })
  const r = await $.tool.call(bash('mv src /tmp/old-src'))
  expect(w.reached).not.toContain('Bash')
  expect(w.prompts[0]?.prompt).toContain('remove /repo/src and everything in it, including /repo/src/a.ts, with the shell command: mv src /tmp/old-src')
  expect(refusal(r)).toContain('Another session is working on a.ts.')
  expect(w.sent[0]?.text).toBe('Another session wanted to remove "src/a.ts" while you are working on it, so it was stopped. Nothing here was touched.')
})

test('a folder copied in and then removed in one command keeps the removal (lessons review of #691)', withDeps, async ($, on) => {
  const w = world($, on, { open: [rec('them', { edits: ['/repo/docs/sub/a.ts'] })] })
  on('fs.stat', ($, e) => ({ value: { kind: (e as unknown as { path: string }).path === '/repo/docs' ? 'dir' : 'other', size: 0, mtimeMs: 0, isLink: false } }) as never)
  await $.tool.call(bash('cp -r /tmp/sub docs; rm -r docs/sub'))
  expect(w.prompts.length).toBe(1)
  expect(w.prompts[0]?.prompt).toContain('remove /repo/docs/sub and everything in it, including /repo/docs/sub/a.ts,')
})

// #700, the comment on it: a cp into an existing folder was turned into the file inside it, and a
// later rm -r of that same folder lost its removal, so another session's files there were never judged.
test('a copy into a folder that is then removed in one command keeps the removal of the folder', withDeps, async ($, on) => {
  const w = world($, on, { open: [rec('them', { edits: ['/repo/docs/b.ts'] })], judge: '{"verdict":"Stop","reason":"They are editing it."}' })
  on('fs.stat', ($, e) => ({ value: { kind: (e as unknown as { path: string }).path === '/repo/docs' ? 'dir' : 'other', size: 0, mtimeMs: 0, isLink: false } }) as never)
  const r = await $.tool.call(bash('cp /tmp/a.ts docs; rm -r docs'))
  expect(w.reached).not.toContain('Bash')
  expect(w.prompts.length).toBe(1)
  expect(w.prompts[0]?.prompt).toContain('remove /repo/docs and everything in it, including /repo/docs/b.ts, with the shell command:')
  expect(refusal(r)).toContain('Another session is working on b.ts.')
})

test('a file written and then removed as a folder in one command is judged as the folder', withDeps, async ($, on) => {
  const w = world($, on, { open: [rec('them', { edits: ['/repo/d/x.ts'] })] })
  await $.tool.call(bash('echo > d; rm -r d'))
  expect(w.prompts.length).toBe(1)
  expect(w.prompts[0]?.prompt).toContain('remove /repo/d and everything in it, including /repo/d/x.ts,')
})

// The coordinator on #691: a folder removal is judged once, naming every affected file, with one
// message to each other session naming its own files, never one judgment and toast per file.
test('an rm -r of a folder holding several edited files is judged once, with one message per other session', withDeps, async ($, on) => {
  const w = world($, on, {
    open: [rec('one', { edits: ['/repo/src/a.ts', '/repo/src/b.ts', '/repo/lib/x.ts'] }), rec('two', { edits: ['/repo/src/c.ts'] })],
    judge: '{"verdict":"Stop","reason":"Both are mid change."}',
  })
  const r = await $.tool.call(bash('rm -rf src'))
  expect(w.reached).not.toContain('Bash')
  expect(w.prompts.length).toBe(1)
  expect(w.prompts[0]?.prompt).toContain('remove /repo/src and everything in it, including /repo/src/a.ts, /repo/src/b.ts, /repo/src/c.ts, with the shell command: rm -rf src')
  expect(w.cards.length).toBe(1)
  expect(refusal(r)).toBe('Blocked: Another session is working on 3 files in src. Both are mid change. Leave it to the other session, or ask Dan.')
  expect(w.sent.map(s => [s.to, s.text])).toEqual([
    ['one', 'Another session wanted to remove "src/a.ts", "src/b.ts" while you are working on it, so it was stopped. Nothing here was touched.'],
    ['two', 'Another session wanted to remove "src/c.ts" while you are working on it, so it was stopped. Nothing here was touched.'],
  ])
})

test('a folder removal judged Proceed is one toast however many files it holds', withDeps, async ($, on) => {
  const w = world($, on, { open: [rec('one', { edits: ['/repo/src/a.ts', '/repo/src/b.ts'] })] })
  await $.tool.call(bash('rm -rf src'))
  expect(w.prompts.length).toBe(1)
  expect(w.toasts).toEqual(['Checked with the other session: safe to remove 2 files in src.'])
  expect(w.reached).toContain('Bash')
})

test('a removal naming several files is told in one toast with each file name, saying remove', withDeps, async ($, on) => {
  const w = world($, on)
  on('session.receive', ($, e) => ({ text: e.text }) as never)
  await $.session.receive({
    origin: MEASURED,
    text: 'Another session wanted to remove "src/a.ts", "src/b.ts" while you are working on it, so it was stopped. Nothing here was touched.',
  } as never)
  expect(w.toasts).toEqual(['Another session wanted to remove a.ts, b.ts; it was stopped.'])
})

// #700: the message names a path relative to the other session's repository, or the whole path
// when that is not known, and Dan's folders carry spaces and a curly apostrophe.
const SPACED = '/Users/dan/Documents/Documents - Dan\u2019s MacBook Pro'

test('a whole path with spaces and a curly apostrophe is named in the toast, sent and heard', withDeps, async ($, on) => {
  const w = world($, on, { open: [rec('them', { repoRoot: null, cwd: SPACED, edits: [`${SPACED}/app.ts`] })], judge: '{"verdict":"Stop","reason":"They are mid change."}' })
  on('session.receive', ($, e) => ({ text: e.text }) as never)
  await $.tool.call(edit(`${SPACED}/app.ts`))
  const text = w.sent[0]?.text as string
  expect(text).toBe(`Another session wanted to edit "${SPACED}/app.ts" while you are working on it, so it was stopped. Nothing here was touched.`)
  await $.session.receive({ origin: MEASURED, text } as never)
  expect(w.toasts).toEqual(['Another session wanted app.ts; it was stopped.'])
})

test('a removal of a whole path with spaces is named in the toast too', withDeps, async ($, on) => {
  const w = world($, on, { open: [rec('them', { repoRoot: null, cwd: SPACED, edits: [`${SPACED}/app.ts`] })], judge: '{"verdict":"Worktree","reason":"They are mid change."}' })
  on('session.receive', ($, e) => ({ text: e.text }) as never)
  await $.tool.call(bash(`rm '${SPACED}/app.ts'`))
  await $.session.receive({ origin: MEASURED, text: w.sent[0]?.text as string } as never)
  expect(w.toasts).toEqual(['Another session wanted to remove app.ts; it was moved to a worktree.'])
})

// #700, the finding Dan folded in: the list was split on comma space, so "Notes, draft.md" read as
// two files. Each name is now quoted in the message and read back whole.
test('a removal naming a file with a comma in it and one under spaces is sent and heard with each name whole', withDeps, async ($, on) => {
  const w = world($, on, {
    open: [rec('them', { repoRoot: null, cwd: SPACED, edits: [`${SPACED}/Notes, draft.md`, `${SPACED}/app.ts`] })],
    judge: '{"verdict":"Stop","reason":"They are mid change."}',
  })
  on('session.receive', ($, e) => ({ text: e.text }) as never)
  await $.tool.call(bash(`rm -r '${SPACED}'`))
  const text = w.sent[0]?.text as string
  expect(text).toBe(`Another session wanted to remove "${SPACED}/Notes, draft.md", "${SPACED}/app.ts" while you are working on it, so it was stopped. Nothing here was touched.`)
  await $.session.receive({ origin: MEASURED, text } as never)
  expect(w.toasts).toEqual(['Another session wanted to remove "Notes, draft.md", app.ts; it was stopped.'])
})

test('an rm -r of a folder the judge cannot answer for is stopped (L42)', withDeps, async ($, on) => {
  const w = world($, on, { open: [rec('them', { edits: ['/repo/src/a.ts'] })], judge: 'no-answer' })
  const r = await $.tool.call(bash('rm -r src/'))
  expect(w.reached).not.toContain('Bash')
  expect(refusal(r)).toBe("Blocked: Couldn't check with the other session's work, so this was stopped. Try again, or ask Dan.")
  expect(w.edits).toEqual([])
})

test('an rm -r with a record that cannot be read is stopped', withDeps, async ($, on) => {
  const w = world($, on, { unreadable: ['abc.json'] })
  const r = await $.tool.call(bash('rm -r src'))
  expect(w.reached).not.toContain('Bash')
  expect(refusal(r)).toContain("Couldn't read another session's record (abc.json)")
})

// #674: scratch outside the repository is not a session's edit, so it cannot push real edits out of
// the twenty the judge reads, nor raise a check between sessions sharing scratch space.
test('a shell write to /tmp or the scratchpad runs and is not noted, while one in the repository is', withDeps, async ($, on) => {
  const w = world($, on)
  await $.tool.call(bash('echo x > /tmp/out.txt && echo y > /private/tmp/claude-501/s/scratchpad/674/n.md && echo z >> notes.txt'))
  expect(w.reached).toContain('Bash')
  expect(w.edits).toEqual(['/repo/notes.txt'])
})

test('an Edit or Write outside the repository is not noted either', withDeps, async ($, on) => {
  const w = world($, on)
  await $.tool.call(edit('/private/tmp/claude-501/s/scratchpad/674/pr-body.md'))
  expect(w.reached).toContain('Edit')
  expect(w.edits).toEqual([])
})

test('a session outside any repository takes its own folder as the root', withDeps, async ($, on) => {
  const w = world($, on, { self: { repoRoot: null, cwd: '/repo' } })
  await $.tool.call(bash('echo x > /tmp/out.txt; echo z >> notes.txt'))
  expect(w.edits).toEqual(['/repo/notes.txt'])
})

test('a scratch file another session recorded before this change is still judged, and not noted here', withDeps, async ($, on) => {
  const w = world($, on, { open: [rec('them', { edits: ['/tmp/shared.txt'] })] })
  await $.tool.call(bash('echo x > /tmp/shared.txt'))
  expect(w.prompts.length).toBe(1)
  expect(w.edits).toEqual([])
})

// Dan, 2026-10-04 (#700): #674 recorded only paths inside the session's own root, which also dropped
// a file edited in another checkout, so a session working there was never judged against it.
test('an edit to a file in another checkout is recorded, found by its .git rather than by asking git', withDeps, async ($, on) => {
  const w = world($, on, { gits: { '/other/.git': 'dir' } })
  await $.tool.call(edit('/other/src/a.ts'))
  expect(w.edits).toEqual(['/other/src/a.ts'])
  expect(w.runs.filter(r => r.includes('/other'))).toEqual([])
})

test('a shell write into a linked worktree, whose .git is a file, is recorded', withDeps, async ($, on) => {
  const w = world($, on, { gits: { '/wt/feature/.git': 'file' } })
  await $.tool.call(bash('echo x >> /wt/feature/notes.txt'))
  expect(w.edits).toEqual(['/wt/feature/notes.txt'])
})

test('scratch is still left out, a checkout inside it included, and so is a path in no checkout', withDeps, async ($, on) => {
  const w = world($, on, {
    gits: { '/tmp/clone/.git': 'dir', '/private/tmp/claude-501/s/scratchpad/700/.git': 'dir', '/Volumes/fast/tmp/clone/.git': 'dir' },
    tmpdir: '/Volumes/fast/tmp/',
  })
  await $.tool.call(bash('echo a > /tmp/clone/x.txt; echo b > /private/tmp/claude-501/s/scratchpad/700/n.md; echo c > /Volumes/fast/tmp/clone/y.txt; echo d > /Users/dan/Desktop/n.txt; echo e >> notes.txt'))
  expect(w.reached).toContain('Bash')
  expect(w.edits).toEqual(['/repo/notes.txt'])
})

test('another session working in that checkout is judged against the file this one recorded there', withDeps, async ($, on) => {
  const w = world($, on, { open: [rec('them', { cwd: '/other', repoRoot: '/other', edits: ['/other/src/a.ts'] })], gits: { '/other/.git': 'dir' } })
  await $.tool.call(edit('/other/src/a.ts'))
  expect(w.prompts.length).toBe(1)
  expect(w.edits).toEqual(['/other/src/a.ts'])
})

// #712: the walk for a checkout is mod-kit's, which refuses rather than guess when the disk cannot
// answer (lessons review of #731). This guard had taken a failed look for "no checkout" and left the
// path out; now it is recorded, so another session working there is still judged against it.
test('a write to a path whose checkout the disk cannot say is recorded, never taken for no checkout', withDeps, async ($, on) => {
  const w = world($, on, { locked: '/Volumes/locked' })
  await $.tool.call(bash('echo x > /Volumes/locked/notes.txt'))
  expect(w.reached).toContain('Bash')
  expect(w.edits).toEqual(['/Volumes/locked/notes.txt'])
})

// #712: on mod-kit's readers, a shell fed its script by a heredoc is read as the commands it runs,
// and what this guard's own reader missed is judged: a file emptied by truncate, written by >&.
test('a write inside a heredoc fed to a shell, a truncate and a >& are judged like any other write', withDeps, async ($, on) => {
  const w = world($, on, { open: [rec('them', { edits: ['/repo/notes.txt'] })], judge: '{"verdict":"Stop","reason":"They are rewriting the notes."}' })
  for (const command of ["bash <<'EOF'\necho done >> notes.txt\nEOF", 'truncate -s 0 notes.txt', 'make >& notes.txt']) {
    const r = await $.tool.call(bash(command, 'hd1'))
    expect(refusal(r)).toBe('Blocked: Another session is working on notes.txt. They are rewriting the notes. Leave it to the other session, or ask Dan.')
  }
  expect(w.reached).toEqual([])
  expect(w.prompts.length).toBe(3)
})

// #965: the shell runs a command substitution in an unquoted heredoc's body before the command fed
// it starts, and one on the command line before the command it sits in. mod-kit's write reader now
// reports what each writes, so a write there to a file another session is editing is judged; under a
// quoted delimiter or in single quotes it is text, nothing is judged and the call goes through.
test('a write a command substitution makes, in an unquoted heredoc or on the command line, is judged; quoted, it is text', withDeps, async ($, on) => {
  const w = world($, on, { open: [rec('them', { edits: ['/repo/notes.txt'] })], judge: '{"verdict":"Stop","reason":"They are rewriting the notes."}' })
  for (const command of ['cat <<EOF\nnote $(echo done >> notes.txt)\nEOF', 'echo "note `echo done >> notes.txt`"']) {
    const r = await $.tool.call(bash(command, 'sub1'))
    expect(`${command}: ${refusal(r)}`).toBe(`${command}: Blocked: Another session is working on notes.txt. They are rewriting the notes. Leave it to the other session, or ask Dan.`)
  }
  expect(w.reached).toEqual([])
  for (const command of ["cat <<'EOF'\nnote $(echo done >> notes.txt)\nEOF", "echo 'note `echo done >> notes.txt`'"]) await $.tool.call(bash(command, 'sub2'))
  expect(w.reached).toEqual(['Bash', 'Bash'])
  expect(w.prompts.length).toBe(2)
})

// #974: mod-kit's command reader now gives the commands a substitution runs as commands of their own,
// so a branch switch inside $(...) or backticks, in a checkout another session works in, is judged as
// one on the command line is; in single quotes or a quoted heredoc it is text and goes through.
test('a branch switch a command substitution runs is judged; quoted, it is text', withDeps, async ($, on) => {
  const w = world($, on, { open: [rec('them')], judge: '{"verdict":"Stop","reason":"They have uncommitted work."}' })
  for (const command of ['echo "on $(git checkout main)"', 'echo "on `git checkout main`"', 'cat <<EOF\non $(git checkout main)\nEOF']) {
    const r = await $.tool.call(bash(command, 'sub3'))
    expect(`${command}: ${refusal(r)}`).toBe(`${command}: Blocked: Another session is working in this checkout. They have uncommitted work. Leave it to the other session, or ask Dan.`)
  }
  expect(w.reached).toEqual([])
  for (const command of ["echo 'on $(git checkout main)'", "cat <<'EOF'\non $(git checkout main)\nEOF"]) await $.tool.call(bash(command, 'sub4'))
  expect(w.reached).toEqual(['Bash', 'Bash'])
  expect(w.prompts.length).toBe(3)
})

// #975: a write inside a script a second shell runs (its -c, a quoted heredoc, a script piped to it),
// redirect or substitution, and one inside a process substitution, is read by mod-kit's write
// reader, so a write there to a file another session is editing is judged. A quoted heredoc fed to a
// program that is not a shell, and a process substitution in double quotes, are text.
test('a write in a shell script or a process substitution is judged; fed to another program, it is text', withDeps, async ($, on) => {
  const w = world($, on, { open: [rec('them', { edits: ['/repo/notes.txt'] })], judge: '{"verdict":"Stop","reason":"They are rewriting the notes."}' })
  const judged = [
    "bash -c 'echo done >> notes.txt'",
    "sh -c 'echo \"$(echo done >> notes.txt)\"'",
    "zsh -c 'echo \"`echo done >> notes.txt`\"'",
    "bash <<'EOF'\necho done >> notes.txt\nEOF",
    "sh <<'EOF'\nx=$(echo done >> notes.txt)\nEOF",
    // Unquoted, the outer shell takes the escape off, and the shell fed the body runs it.
    'bash <<EOF\necho \\$(echo done >> notes.txt)\nEOF',
    "echo 'echo done >> notes.txt' | bash",
    'diff <(echo done >> notes.txt) b.txt',
    'tee >(cat >> notes.txt) < b.txt',
  ]
  for (const command of judged) {
    const r = await $.tool.call(bash(command, 'sub5'))
    expect(`${command}: ${refusal(r)}`).toBe(`${command}: Blocked: Another session is working on notes.txt. They are rewriting the notes. Leave it to the other session, or ask Dan.`)
  }
  expect(w.reached).toEqual([])
  for (const command of ["cat > /dev/null <<'EOF'\necho done >> notes.txt $(echo done >> notes.txt) <(echo done >> notes.txt)\nEOF", 'echo "<(echo done >> notes.txt)"']) await $.tool.call(bash(command, 'sub6'))
  expect(w.reached).toEqual(['Bash', 'Bash'])
  expect(w.prompts.length).toBe(judged.length)
})

// #707: a guard that refuses decides before this one judges, whichever order the mods load in. The
// guard here stands in for no build, winding down, the secret guard and the style check (a mod's
// tests cannot load another mod's files): it refuses at tool.call anything naming NO-BUILD, as each
// of them refuses there. It is loaded above this guard (the prepend tier) and beneath it (append),
// the two places a mod can stand: the engine nests tiers as it nests mods by load order.
const Refuser = (tier: 'prepend' | 'append'): { name: string; tier: 'prepend' | 'append'; register: Register } => ({
  name: 'refuser',
  tier,
  register: on => {
    on('tool.call', async ($, e, next) => {
      const x = e as unknown as { command?: string; file_path?: string }
      if (`${x.command ?? ''} ${x.file_path ?? ''}`.includes('NO-BUILD')) return { deny: 'Blocked: no build is on.' }
      return next(e)
    })
  },
})
const STOP = '{"verdict":"Stop","reason":"They are mid rebase."}'
const clashes = { open: [rec('them', { edits: ['/repo/src/InvoiceTable.tsx', '/repo/src/NO-BUILD.tsx', '/repo/NO-BUILD.txt'] })], judge: STOP }

for (const [where, tier] of [['above', 'prepend'], ['beneath', 'append']] as const) {
  test(`a call a guard ${where} it refuses is never judged, told or toasted, while one it lets through still is (#707)`, { plugins: [secDefault, deps, Refuser(tier)] }, async ($, on) => {
    const w = world($, on, clashes)
    // The same fixture judges an allowed clash, so the silence below is the refusal deciding first.
    const judged = await $.tool.call(edit('/repo/src/InvoiceTable.tsx', 'ok1'))
    expect(refusal(judged)).toContain('Another session is working on InvoiceTable.tsx.')
    expect(w.prompts.length).toBe(1)
    expect(w.sent.length).toBe(1)
    for (const call of [edit('/repo/src/NO-BUILD.tsx', 'n1'), bash('echo x >> NO-BUILD.txt', 'n2'), bash('git checkout main && echo NO-BUILD', 'n3')]) {
      const r = await $.tool.call(call)
      expect(refusal(r)).toBe('Blocked: no build is on.')
    }
    expect(w.prompts.length).toBe(1)
    expect(w.sent.length).toBe(1)
    expect(w.toasts).toEqual([])
    expect(w.cards.map(c => c.toolUseId)).toEqual(['ok1'])
    expect(w.reached).toEqual([])
    expect(w.edits).toEqual([])
  })
}

// A settings hook (the payload write gate, the push gates) decides beneath every mod at
// classic.PreToolUse, which the test's own hook stands in for: its refusal comes first too.
test('a call a settings hook refuses is never judged, told or toasted (#707)', withDeps, async ($, on) => {
  const w = world($, on, clashes)
  on('classic.PreToolUse', ($, e) => ((e as unknown as { file_path?: string }).file_path?.includes('NO-BUILD') ? { deny: 'Blocked: the payload write gate refused it.' } : {}))
  const r = await $.tool.call(edit('/repo/src/NO-BUILD.tsx', 'g1'))
  expect(refusal(r)).toBe('Blocked: the payload write gate refused it.')
  expect(w.prompts).toEqual([])
  expect(w.sent).toEqual([])
  expect(w.toasts).toEqual([])
  expect(w.cards).toEqual([])
  expect(w.edits).toEqual([])
  // The same hook letting a clash through leaves it to be judged as before.
  await $.tool.call(edit('/repo/src/InvoiceTable.tsx', 'g2'))
  expect(w.prompts.length).toBe(1)
})

// A check that fails outright (here the session list cannot be read at all) refuses the call: a
// tool.check hook that fails is skipped and the verdict beneath allows it, which would let an edit
// through unjudged (L42, lessons review of #878).
test('a check that fails refuses the call rather than let it through unjudged', withDeps, async ($, on) => {
  const w = world($, on, { listBreaks: true })
  const r = await $.tool.call(edit('/repo/src/InvoiceTable.tsx', 'x1'))
  expect(refusal(r)).toContain('Blocked: the collision guard could not check this call against the other sessions')
  expect(w.reached).toEqual([])
  expect(w.edits).toEqual([])
})

// The plan is handed from the tool.check hook to the tool.call hook by the call's id. A call raised
// with none is given one by the engine (measured 2026-10-04), so two such calls are each noted as
// their own (lessons review of #707).
test('two calls raised without an id are each noted, never mixed up (#707 review)', withDeps, async ($, on) => {
  const w = world($, on)
  await Promise.all([
    $.tool.call({ tool: 'Edit', file_path: '/repo/src/a.ts', old_string: 'a', new_string: 'b' } as never),
    $.tool.call({ tool: 'Edit', file_path: '/repo/src/b.ts', old_string: 'a', new_string: 'b' } as never),
  ])
  expect([...w.edits].sort()).toEqual(['/repo/src/a.ts', '/repo/src/b.ts'])
})

// Both sides of that hand over read the key through one helper (#732). A call with no id cannot
// reach the guard by any route: the engine refuses a mod that hands a call on without its id and
// runs the call with the id it was raised under (measured here, Claude Code 2.1.289), so the plan
// the tool.check hook stores is the one the tool.call hook reads back.
const IdDropper: { name: string; tier: 'prepend'; register: Register } = {
  name: 'id-dropper',
  tier: 'prepend',
  register: on => {
    on('tool.call', async ($, e, next) => {
      const { tool_use_id: _dropped, ...rest } = e as unknown as Record<string, unknown>
      return next(rest as never)
    })
  },
}
test('a mod that hands a call on without its id cannot strip it, so the plan is read back under the id it was stored by (#732)', { plugins: [secDefault, deps, IdDropper] }, async ($, on) => {
  const w = world($, on)
  const seen: unknown[] = []
  on('classic.PreToolUse', ($, e) => {
    seen.push((e as unknown as { tool_use_id?: unknown }).tool_use_id)
    return {}
  })
  const r = await $.tool.call(edit('/repo/src/a.ts', 'd1'))
  expect(refusal(r)).toBe('ran')
  expect(seen).toEqual(['d1'])
  expect(w.edits).toEqual(['/repo/src/a.ts'])
})

// What a settings hook decides about a call the guard lets through is passed on as it was: an allow
// skips Claude Code's permission prompt, and a rewrite (rtk's) is what runs.
const Watcher: { name: string; tier: 'prepend'; register: Register } = {
  name: 'watcher',
  tier: 'prepend',
  register: on => {
    on('classic.PreToolUse', async ($, e, next) => {
      const r = await next(e)
      // Told to the world as a process it records, the one channel an inline plugin has to it.
      await $.process.run(['__decided', JSON.stringify(r)])
      return r
    })
  },
}
test('a settings hook decision on a call the guard lets through is passed on unchanged (#707)', { plugins: [secDefault, deps, Watcher] }, async ($, on) => {
  const w = world($, on, { open: [rec('them', { edits: ['/repo/notes.txt'] })] })
  on('classic.PreToolUse', () => ({ allow: true, additionalContext: ['from a settings hook'] }) as never)
  const r = await $.tool.call(bash('echo x >> notes.txt', 'p1'))
  expect(w.toasts).toEqual(['Checked with the other session: safe to edit notes.txt.'])
  const decided = w.runs.filter(x => x.startsWith('__decided ')).map(x => JSON.parse(x.slice('__decided '.length)))
  expect(decided).toEqual([{ allow: true, additionalContext: ['from a settings hook'] }])
  expect(refusal(r)).toBe('ran')
  expect(w.edits).toEqual(['/repo/notes.txt'])
})
