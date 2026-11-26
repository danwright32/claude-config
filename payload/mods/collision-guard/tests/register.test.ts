import { expect, type Engine } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import type { On, Register } from 'claude-code'
import { branchAt } from './mod-kit/hooks/branch.ts'
import { reasonOf, standInCore } from './mod-kit/tests/core.ts'

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
      const made = {
        ...built,
        modkit: {
          blocked: async (b: unknown) => built.ui.log('CARD ' + JSON.stringify(b)),
          commands: async (input: { command: string }) => kit('commands', input),
          writes: async (input: { command: string; cwd: string; home: string }) => kit('writes', input),
          git: async (input: { words: string[]; env?: readonly string[] }) => kit('git', input),
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
          mergeHelper: async () => { throw new Error("mod-kit's mergeHelper is not stood in by these tests") },
          goal: async () => { throw new Error("mod-kit's goal is not stood in by these tests") },
          ghRepo: async () => { throw new Error("mod-kit's ghRepo is not stood in by these tests") },
          linkRepo: async () => { throw new Error("mod-kit's linkRepo is not stood in by these tests") },
          card: async () => { throw new Error("mod-kit's card is not stood in by these tests") },
          // #3398: each command with the settings in front of it and the folder a cd leaves it in,
          // and what a variable the call itself sets holds, which the guard asks to have followed.
          pipeline: async (input: { command: string; cwd?: string; home?: string; follow?: boolean }) => kit('pipeline', input),
          bandRow: async () => { throw new Error("mod-kit's bandRow is not stood in by these tests") },
          clearBandRow: async () => { throw new Error("mod-kit's clearBandRow is not stood in by these tests") },
          pane: async () => { throw new Error("mod-kit's pane is not stood in by these tests") },
          clearPane: async () => { throw new Error("mod-kit's clearPane is not stood in by these tests") },
          screen: async () => { throw new Error("mod-kit's screen is not stood in by these tests") },
          // #939: a press raised by the kit's Button below, and whether a click lands; every Button here is clickable.
          press: async () => ({ isAnswered: false }),
          clickable: async () => true,
          isDans: async () => { throw new Error("mod-kit's isDans is not stood in by these tests") },
          typedAnswer: async () => { throw new Error("mod-kit's typedAnswer is not stood in by these tests") },
          hold: async () => { throw new Error("mod-kit's hold is not stood in by these tests") },
          release: async () => { throw new Error("mod-kit's release is not stood in by these tests") },
          pythonText: async () => { throw new Error("mod-kit's pythonText is not stood in by these tests") },
          login: async () => { throw new Error("mod-kit's login is not stood in by these tests") },
          account: async () => { throw new Error("mod-kit's account is not stood in by these tests") },
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
      // #1299: a provider loaded before it had a member, named by a plugin in the fold,
      // <kit or sessions>-lacks-<member in kebab case>, since this plugin runs apart from the test's
      // module; the call site then throws in the mod itself, as the runtime words it.
      for (const p of e.plugins) {
        const m = /^(kit|sessions)-lacks-([a-z-]+)$/.exec(p)
        if (!m) continue
        const member = (m[2] as string).replace(/-([a-z])/g, (_x: string, c: string) => c.toUpperCase())
        delete (made as unknown as Record<string, Record<string, unknown>>)[m[1] === 'kit' ? 'modkit' : 'sessions']?.[member]
      }
      return made
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
// #1299: the same, with a session registry loaded before it had list, or noteEdit.
const withOldList = { plugins: [secDefault, deps, { name: 'sessions-lacks-list', register: (() => undefined) as Register }] }
const withOldNote = { plugins: [secDefault, deps, { name: 'sessions-lacks-note-edit', register: (() => undefined) as Register }] }

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
  // #3398: a repository named that is a linked worktree's, measured from mod-kit's readers on 2026-11-22.
  ["commands {\"command\":\"git --git-dir=/main/.git/worktrees/w checkout main\"}",[["git","--git-dir=/main/.git/worktrees/w","checkout","main"]]],
  ["pipeline {\"command\":\"git --git-dir=/main/.git/worktrees/w checkout main\",\"cwd\":\"/repo\",\"home\":\"\",\"follow\":true}",[{"words":["git","--git-dir=/main/.git/worktrees/w","checkout","main"],"folder":"/repo"}]],
  ["git {\"words\":[\"git\",\"--git-dir=/main/.git/worktrees/w\",\"checkout\",\"main\"]}",{"sub":"checkout","args":["main"],"gitDir":"/main/.git/worktrees/w"}],
  ["writes {\"command\":\"git --git-dir=/main/.git/worktrees/w checkout main\",\"cwd\":\"/repo\",\"home\":\"\"}",{"files":[],"changes":[],"unnamed":[]}],
  // #3398: the folder and settings of each watched git command these tests already ran, measured from mod-kit's pipeline reader on 2026-11-22.
  ["pipeline {\"command\":\"git checkout main\",\"cwd\":\"/repo\",\"home\":\"\",\"follow\":true}",[{"words":["git","checkout","main"],"folder":"/repo"}]],
  ["pipeline {\"command\":\"git -C /other reset --hard origin/main\",\"cwd\":\"/repo\",\"home\":\"\",\"follow\":true}",[{"words":["git","-C","/other","reset","--hard","origin/main"],"folder":"/repo"}]],
  ["pipeline {\"command\":\"git switch -c window-two\",\"cwd\":\"/repo\",\"home\":\"\",\"follow\":true}",[{"words":["git","switch","-c","window-two"],"folder":"/repo"}]],
  ["pipeline {\"command\":\"git checkout main && echo NO-BUILD\",\"cwd\":\"/repo\",\"home\":\"\",\"follow\":true}",[{"words":["git","checkout","main"],"folder":"/repo"},{"words":["echo","NO-BUILD"],"folder":"/repo"}]],
  ["pipeline {\"command\":\"echo \\\"on $(git checkout main)\\\"\",\"cwd\":\"/repo\",\"home\":\"\",\"follow\":true}",[{"words":["git","checkout","main"],"substitution":true,"folder":"/repo"},{"words":["echo","on $(git checkout main)"],"derived":[null,{"unresolved":"it runs git, whose output this reader does not know","commands":[{"words":["git","checkout","main"],"substitution":true}]}],"folder":"/repo"}]],
  ["pipeline {\"command\":\"echo \\\"on `git checkout main`\\\"\",\"cwd\":\"/repo\",\"home\":\"\",\"follow\":true}",[{"words":["git","checkout","main"],"substitution":true,"folder":"/repo"},{"words":["echo","on `git checkout main`"],"derived":[null,{"unresolved":"it runs git, whose output this reader does not know","commands":[{"words":["git","checkout","main"],"substitution":true}]}],"folder":"/repo"}]],
  ["pipeline {\"command\":\"cat <<EOF\\non $(git checkout main)\\nEOF\",\"cwd\":\"/repo\",\"home\":\"\",\"follow\":true}",[{"words":["git","checkout","main"],"substitution":true,"folder":"/repo"},{"words":["cat","<<EOF"],"heredocs":[{"word":1,"body":"on $(git checkout main)","quoted":false}],"folder":"/repo"}]],
  // #3398: a git command naming its repository, its folder or a chain of folders, measured from mod-kit's readers on 2026-11-22.
  ["commands {\"command\":\"git --git-dir=/other/.git --work-tree=/other checkout main\"}",[["git","--git-dir=/other/.git","--work-tree=/other","checkout","main"]]],
  ["pipeline {\"command\":\"git --git-dir=/other/.git --work-tree=/other checkout main\",\"cwd\":\"/repo\",\"home\":\"\",\"follow\":true}",[{"words":["git","--git-dir=/other/.git","--work-tree=/other","checkout","main"],"folder":"/repo"}]],
  ["git {\"words\":[\"git\",\"--git-dir=/other/.git\",\"--work-tree=/other\",\"checkout\",\"main\"]}",{"sub":"checkout","args":["main"],"gitDir":"/other/.git","workTree":"/other"}],
  ["writes {\"command\":\"git --git-dir=/other/.git --work-tree=/other checkout main\",\"cwd\":\"/repo\",\"home\":\"\"}",{"files":[],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"git --git-dir=/other/.git checkout main\"}",[["git","--git-dir=/other/.git","checkout","main"]]],
  ["pipeline {\"command\":\"git --git-dir=/other/.git checkout main\",\"cwd\":\"/repo\",\"home\":\"\",\"follow\":true}",[{"words":["git","--git-dir=/other/.git","checkout","main"],"folder":"/repo"}]],
  ["git {\"words\":[\"git\",\"--git-dir=/other/.git\",\"checkout\",\"main\"]}",{"sub":"checkout","args":["main"],"gitDir":"/other/.git"}],
  ["writes {\"command\":\"git --git-dir=/other/.git checkout main\",\"cwd\":\"/repo\",\"home\":\"\"}",{"files":[],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"GIT_DIR=/other/.git GIT_WORK_TREE=/other git checkout main\"}",[["git","checkout","main"]]],
  ["pipeline {\"command\":\"GIT_DIR=/other/.git GIT_WORK_TREE=/other git checkout main\",\"cwd\":\"/repo\",\"home\":\"\",\"follow\":true}",[{"words":["git","checkout","main"],"env":["GIT_DIR=/other/.git","GIT_WORK_TREE=/other"],"folder":"/repo"}]],
  ["git {\"words\":[\"git\",\"checkout\",\"main\"],\"env\":[\"GIT_DIR=/other/.git\",\"GIT_WORK_TREE=/other\"]}",{"sub":"checkout","args":["main"],"gitDir":"/other/.git","workTree":"/other"}],
  ["writes {\"command\":\"GIT_DIR=/other/.git GIT_WORK_TREE=/other git checkout main\",\"cwd\":\"/repo\",\"home\":\"\"}",{"files":[],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"cd /other && git -C sub checkout main\"}",[["cd","/other"],["git","-C","sub","checkout","main"]]],
  ["pipeline {\"command\":\"cd /other && git -C sub checkout main\",\"cwd\":\"/repo\",\"home\":\"\",\"follow\":true}",[{"words":["cd","/other"],"folder":"/repo"},{"words":["git","-C","sub","checkout","main"],"folder":"/other"}]],
  ["git {\"words\":[\"git\",\"-C\",\"sub\",\"checkout\",\"main\"]}",{"sub":"checkout","args":["main"],"dir":"sub"}],
  ["writes {\"command\":\"cd /other && git -C sub checkout main\",\"cwd\":\"/repo\",\"home\":\"\"}",{"files":[],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"cd /other && git checkout main\"}",[["cd","/other"],["git","checkout","main"]]],
  ["pipeline {\"command\":\"cd /other && git checkout main\",\"cwd\":\"/repo\",\"home\":\"\",\"follow\":true}",[{"words":["cd","/other"],"folder":"/repo"},{"words":["git","checkout","main"],"folder":"/other"}]],
  ["writes {\"command\":\"cd /other && git checkout main\",\"cwd\":\"/repo\",\"home\":\"\"}",{"files":[],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"git -C /other -C sub checkout main\"}",[["git","-C","/other","-C","sub","checkout","main"]]],
  ["pipeline {\"command\":\"git -C /other -C sub checkout main\",\"cwd\":\"/repo\",\"home\":\"\",\"follow\":true}",[{"words":["git","-C","/other","-C","sub","checkout","main"],"folder":"/repo"}]],
  ["git {\"words\":[\"git\",\"-C\",\"/other\",\"-C\",\"sub\",\"checkout\",\"main\"]}",{"sub":"checkout","args":["main"],"dir":"sub","chained":"/other/sub"}],
  ["writes {\"command\":\"git -C /other -C sub checkout main\",\"cwd\":\"/repo\",\"home\":\"\"}",{"files":[],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"git -C \\\"$X\\\" checkout main\"}",[["git","-C","$X","checkout","main"]]],
  ["pipeline {\"command\":\"git -C \\\"$X\\\" checkout main\",\"cwd\":\"/repo\",\"home\":\"\",\"follow\":true}",[{"words":["git","-C","$X","checkout","main"],"folder":"/repo"}]],
  ["git {\"words\":[\"git\",\"-C\",\"$X\",\"checkout\",\"main\"]}",{"sub":"checkout","args":["main"],"dir":"$X"}],
  ["writes {\"command\":\"git -C \\\"$X\\\" checkout main\",\"cwd\":\"/repo\",\"home\":\"\"}",{"files":[],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"git -C /a -C \\\"$B\\\" checkout main\"}",[["git","-C","/a","-C","$B","checkout","main"]]],
  ["pipeline {\"command\":\"git -C /a -C \\\"$B\\\" checkout main\",\"cwd\":\"/repo\",\"home\":\"\",\"follow\":true}",[{"words":["git","-C","/a","-C","$B","checkout","main"],"folder":"/repo"}]],
  ["git {\"words\":[\"git\",\"-C\",\"/a\",\"-C\",\"$B\",\"checkout\",\"main\"]}",{"sub":"checkout","args":["main"],"dir":"$B","chained":null}],
  ["writes {\"command\":\"git -C /a -C \\\"$B\\\" checkout main\",\"cwd\":\"/repo\",\"home\":\"\"}",{"files":[],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"cd \\\"$X\\\" && git checkout main\"}",[["cd","$X"],["git","checkout","main"]]],
  ["pipeline {\"command\":\"cd \\\"$X\\\" && git checkout main\",\"cwd\":\"/repo\",\"home\":\"\",\"follow\":true}",[{"words":["cd","$X"],"folder":"/repo"},{"words":["git","checkout","main"],"folder":null}]],
  ["git {\"words\":[\"cd\",\"$X\"]}",null],
  ["writes {\"command\":\"cd \\\"$X\\\" && git checkout main\",\"cwd\":\"/repo\",\"home\":\"\"}",{"files":[],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"git --git-dir=\\\"$G\\\" checkout main\"}",[["git","--git-dir=$G","checkout","main"]]],
  ["pipeline {\"command\":\"git --git-dir=\\\"$G\\\" checkout main\",\"cwd\":\"/repo\",\"home\":\"\",\"follow\":true}",[{"words":["git","--git-dir=$G","checkout","main"],"folder":"/repo"}]],
  ["git {\"words\":[\"git\",\"--git-dir=$G\",\"checkout\",\"main\"]}",{"sub":"checkout","args":["main"],"gitDir":"$G"}],
  ["writes {\"command\":\"git --git-dir=\\\"$G\\\" checkout main\",\"cwd\":\"/repo\",\"home\":\"\"}",{"files":[],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"export GIT_DIR=/other/.git; git checkout main\"}",[["export","GIT_DIR=/other/.git"],["git","checkout","main"]]],
  ["pipeline {\"command\":\"export GIT_DIR=/other/.git; git checkout main\",\"cwd\":\"/repo\",\"home\":\"\",\"follow\":true}",[{"words":["export","GIT_DIR=/other/.git"],"folder":"/repo"},{"words":["git","checkout","main"],"folder":"/repo"}]],
  ["git {\"words\":[\"export\",\"GIT_DIR=/other/.git\"]}",null],
  ["writes {\"command\":\"export GIT_DIR=/other/.git; git checkout main\",\"cwd\":\"/repo\",\"home\":\"\"}",{"files":[],"changes":[],"unnamed":[]}],
  ["pipeline {\"command\":\"git status\",\"cwd\":\"/repo\",\"home\":\"\",\"follow\":true}",[{"words":["git","status"],"folder":"/repo"}]],
  ["commands {\"command\":\"git -C /other log\"}",[["git","-C","/other","log"]]],
  ["pipeline {\"command\":\"git -C /other log\",\"cwd\":\"/repo\",\"home\":\"\",\"follow\":true}",[{"words":["git","-C","/other","log"],"folder":"/repo"}]],
  ["git {\"words\":[\"git\",\"-C\",\"/other\",\"log\"]}",{"sub":"log","args":[],"dir":"/other"}],
  ["writes {\"command\":\"git -C /other log\",\"cwd\":\"/repo\",\"home\":\"\"}",{"files":[],"changes":[],"unnamed":[]}],
  // #3398: a folder named with a variable the call itself sets, followed and not, measured from mod-kit's readers on 2026-11-22.
  ["commands {\"command\":\"W=/other; git -C \\\"$W\\\" checkout main\"}",[["git","-C","$W","checkout","main"]]],
  ["pipeline {\"command\":\"W=/other; git -C \\\"$W\\\" checkout main\",\"cwd\":\"/repo\",\"home\":\"\",\"follow\":true}",[{"words":["git","-C","$W","checkout","main"],"followed":[null,null,"/other",null,null],"folder":"/repo"}]],
  ["git {\"words\":[\"git\",\"-C\",\"$W\",\"checkout\",\"main\"]}",{"sub":"checkout","args":["main"],"dir":"$W"}],
  ["git {\"words\":[\"git\",\"-C\",\"/other\",\"checkout\",\"main\"]}",{"sub":"checkout","args":["main"],"dir":"/other"}],
  ["writes {\"command\":\"W=/other; git -C \\\"$W\\\" checkout main\",\"cwd\":\"/repo\",\"home\":\"\"}",{"files":[],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"R=/other\\ngit -C $R reset --hard origin/main\"}",[["git","-C","$R","reset","--hard","origin/main"]]],
  ["pipeline {\"command\":\"R=/other\\ngit -C $R reset --hard origin/main\",\"cwd\":\"/repo\",\"home\":\"\",\"follow\":true}",[{"words":["git","-C","$R","reset","--hard","origin/main"],"followed":[null,null,"/other",null,null,null],"folder":"/repo"}]],
  ["git {\"words\":[\"git\",\"-C\",\"$R\",\"reset\",\"--hard\",\"origin/main\"]}",{"sub":"reset","args":["--hard","origin/main"],"dir":"$R"}],
  ["writes {\"command\":\"R=/other\\ngit -C $R reset --hard origin/main\",\"cwd\":\"/repo\",\"home\":\"\"}",{"files":[],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"W=sub; git -C /other -C \\\"${W}\\\" checkout main\"}",[["git","-C","/other","-C","${W}","checkout","main"]]],
  ["pipeline {\"command\":\"W=sub; git -C /other -C \\\"${W}\\\" checkout main\",\"cwd\":\"/repo\",\"home\":\"\",\"follow\":true}",[{"words":["git","-C","/other","-C","${W}","checkout","main"],"followed":[null,null,null,null,"sub",null,null],"folder":"/repo"}]],
  ["git {\"words\":[\"git\",\"-C\",\"/other\",\"-C\",\"${W}\",\"checkout\",\"main\"]}",{"sub":"checkout","args":["main"],"dir":"${W}","chained":null}],
  ["writes {\"command\":\"W=sub; git -C /other -C \\\"${W}\\\" checkout main\",\"cwd\":\"/repo\",\"home\":\"\"}",{"files":[],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"W=/a; W=/other; git -C \\\"$W\\\" checkout main\"}",[["git","-C","$W","checkout","main"]]],
  ["pipeline {\"command\":\"W=/a; W=/other; git -C \\\"$W\\\" checkout main\",\"cwd\":\"/repo\",\"home\":\"\",\"follow\":true}",[{"words":["git","-C","$W","checkout","main"],"folder":"/repo"}]],
  ["writes {\"command\":\"W=/a; W=/other; git -C \\\"$W\\\" checkout main\",\"cwd\":\"/repo\",\"home\":\"\"}",{"files":[],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"git -C \\\"$W\\\" checkout main; W=/other\"}",[["git","-C","$W","checkout","main"]]],
  ["pipeline {\"command\":\"git -C \\\"$W\\\" checkout main; W=/other\",\"cwd\":\"/repo\",\"home\":\"\",\"follow\":true}",[{"words":["git","-C","$W","checkout","main"],"folder":"/repo"}]],
  ["writes {\"command\":\"git -C \\\"$W\\\" checkout main; W=/other\",\"cwd\":\"/repo\",\"home\":\"\"}",{"files":[],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"(W=/other); git -C \\\"$W\\\" checkout main\"}",[["("],[")"],["git","-C","$W","checkout","main"]]],
  ["pipeline {\"command\":\"(W=/other); git -C \\\"$W\\\" checkout main\",\"cwd\":\"/repo\",\"home\":\"\",\"follow\":true}",[{"words":["("],"folder":"/repo"},{"words":[")"],"folder":"/repo"},{"words":["git","-C","$W","checkout","main"],"folder":"/repo"}]],
  ["git {\"words\":[\"(\"]}",null],
  ["git {\"words\":[\")\"]}",null],
  ["writes {\"command\":\"(W=/other); git -C \\\"$W\\\" checkout main\",\"cwd\":\"/repo\",\"home\":\"\"}",{"files":[],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"f() { W=/other; }; f; git -C \\\"$W\\\" checkout main\"}",[["f()"],["}"],["f"],["git","-C","$W","checkout","main"]]],
  ["pipeline {\"command\":\"f() { W=/other; }; f; git -C \\\"$W\\\" checkout main\",\"cwd\":\"/repo\",\"home\":\"\",\"follow\":true}",[{"words":["f()"],"folder":"/repo"},{"words":["}"],"folder":"/repo"},{"words":["f"],"folder":"/repo"},{"words":["git","-C","$W","checkout","main"],"folder":"/repo"}]],
  ["git {\"words\":[\"f()\"]}",null],
  ["git {\"words\":[\"}\"]}",null],
  ["git {\"words\":[\"f\"]}",null],
  ["writes {\"command\":\"f() { W=/other; }; f; git -C \\\"$W\\\" checkout main\",\"cwd\":\"/repo\",\"home\":\"\"}",{"files":[],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"W=$(pwd); git -C \\\"$W\\\" checkout main\"}",[["pwd"],["git","-C","$W","checkout","main"]]],
  ["pipeline {\"command\":\"W=$(pwd); git -C \\\"$W\\\" checkout main\",\"cwd\":\"/repo\",\"home\":\"\",\"follow\":true}",[{"words":["pwd"],"substitution":true,"folder":"/repo"},{"words":["git","-C","$W","checkout","main"],"folder":"/repo"}]],
  ["git {\"words\":[\"pwd\"]}",null],
  ["writes {\"command\":\"W=$(pwd); git -C \\\"$W\\\" checkout main\",\"cwd\":\"/repo\",\"home\":\"\"}",{"files":[],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"W=/other && git -C \\\"$W\\\" checkout main\"}",[["git","-C","$W","checkout","main"]]],
  ["pipeline {\"command\":\"W=/other && git -C \\\"$W\\\" checkout main\",\"cwd\":\"/repo\",\"home\":\"\",\"follow\":true}",[{"words":["git","-C","$W","checkout","main"],"folder":"/repo"}]],
  ["writes {\"command\":\"W=/other && git -C \\\"$W\\\" checkout main\",\"cwd\":\"/repo\",\"home\":\"\"}",{"files":[],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"W=/other git -C \\\"$W\\\" checkout main\"}",[["git","-C","$W","checkout","main"]]],
  ["pipeline {\"command\":\"W=/other git -C \\\"$W\\\" checkout main\",\"cwd\":\"/repo\",\"home\":\"\",\"follow\":true}",[{"words":["git","-C","$W","checkout","main"],"env":["W=/other"],"folder":"/repo"}]],
  ["git {\"words\":[\"git\",\"-C\",\"$W\",\"checkout\",\"main\"],\"env\":[\"W=/other\"]}",{"sub":"checkout","args":["main"],"dir":"$W"}],
  ["writes {\"command\":\"W=/other git -C \\\"$W\\\" checkout main\",\"cwd\":\"/repo\",\"home\":\"\"}",{"files":[],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"export W=/other; git -C \\\"$W\\\" checkout main\"}",[["export","W=/other"],["git","-C","$W","checkout","main"]]],
  ["pipeline {\"command\":\"export W=/other; git -C \\\"$W\\\" checkout main\",\"cwd\":\"/repo\",\"home\":\"\",\"follow\":true}",[{"words":["export","W=/other"],"folder":"/repo"},{"words":["git","-C","$W","checkout","main"],"folder":"/repo"}]],
  ["git {\"words\":[\"export\",\"W=/other\"]}",null],
  ["writes {\"command\":\"export W=/other; git -C \\\"$W\\\" checkout main\",\"cwd\":\"/repo\",\"home\":\"\"}",{"files":[],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"REPO=/other; git -C \\\"$REPO\\\" checkout main\"}",[["git","-C","$REPO","checkout","main"]]],
  ["pipeline {\"command\":\"REPO=/other; git -C \\\"$REPO\\\" checkout main\",\"cwd\":\"/repo\",\"home\":\"\",\"follow\":true}",[{"words":["git","-C","$REPO","checkout","main"],"folder":"/repo"}]],
  ["git {\"words\":[\"git\",\"-C\",\"$REPO\",\"checkout\",\"main\"]}",{"sub":"checkout","args":["main"],"dir":"$REPO"}],
  ["writes {\"command\":\"REPO=/other; git -C \\\"$REPO\\\" checkout main\",\"cwd\":\"/repo\",\"home\":\"\"}",{"files":[],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"wt=/other; git -C \\\"$wt\\\" checkout main\"}",[["git","-C","$wt","checkout","main"]]],
  ["pipeline {\"command\":\"wt=/other; git -C \\\"$wt\\\" checkout main\",\"cwd\":\"/repo\",\"home\":\"\",\"follow\":true}",[{"words":["git","-C","$wt","checkout","main"],"folder":"/repo"}]],
  ["git {\"words\":[\"git\",\"-C\",\"$wt\",\"checkout\",\"main\"]}",{"sub":"checkout","args":["main"],"dir":"$wt"}],
  ["writes {\"command\":\"wt=/other; git -C \\\"$wt\\\" checkout main\",\"cwd\":\"/repo\",\"home\":\"\"}",{"files":[],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"W=~/other; git -C \\\"$W\\\" checkout main\"}",[["git","-C","$W","checkout","main"]]],
  ["pipeline {\"command\":\"W=~/other; git -C \\\"$W\\\" checkout main\",\"cwd\":\"/repo\",\"home\":\"\",\"follow\":true}",[{"words":["git","-C","$W","checkout","main"],"folder":"/repo"}]],
  ["writes {\"command\":\"W=~/other; git -C \\\"$W\\\" checkout main\",\"cwd\":\"/repo\",\"home\":\"\"}",{"files":[],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"W=\\\"/my other\\\"; git -C \\\"$W\\\" checkout main\"}",[["git","-C","$W","checkout","main"]]],
  ["pipeline {\"command\":\"W=\\\"/my other\\\"; git -C \\\"$W\\\" checkout main\",\"cwd\":\"/repo\",\"home\":\"\",\"follow\":true}",[{"words":["git","-C","$W","checkout","main"],"folder":"/repo"}]],
  ["writes {\"command\":\"W=\\\"/my other\\\"; git -C \\\"$W\\\" checkout main\",\"cwd\":\"/repo\",\"home\":\"\"}",{"files":[],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"W=/other; git -C \\\"$W/sub\\\" checkout main\"}",[["git","-C","$W/sub","checkout","main"]]],
  ["pipeline {\"command\":\"W=/other; git -C \\\"$W/sub\\\" checkout main\",\"cwd\":\"/repo\",\"home\":\"\",\"follow\":true}",[{"words":["git","-C","$W/sub","checkout","main"],"folder":"/repo"}]],
  ["git {\"words\":[\"git\",\"-C\",\"$W/sub\",\"checkout\",\"main\"]}",{"sub":"checkout","args":["main"],"dir":"$W/sub"}],
  ["writes {\"command\":\"W=/other; git -C \\\"$W/sub\\\" checkout main\",\"cwd\":\"/repo\",\"home\":\"\"}",{"files":[],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"W=/other; git -C \\\"$W\\\" checkout main; cat <<EOF\\nx\\nEOF\"}",[["git","-C","$W","checkout","main"],["cat","<<EOF"]]],
  ["pipeline {\"command\":\"W=/other; git -C \\\"$W\\\" checkout main; cat <<EOF\\nx\\nEOF\",\"cwd\":\"/repo\",\"home\":\"\",\"follow\":true}",[{"words":["git","-C","$W","checkout","main"],"folder":"/repo"},{"words":["cat","<<EOF"],"heredocs":[{"word":1,"body":"x","quoted":false}],"folder":"/repo"}]],
  ["writes {\"command\":\"W=/other; git -C \\\"$W\\\" checkout main; cat <<EOF\\nx\\nEOF\",\"cwd\":\"/repo\",\"home\":\"\"}",{"files":[],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"d=$(mktemp -d) && cd \\\"$d\\\" && git checkout -q x\"}",[["mktemp","-d"],["cd","$d"],["git","checkout","-q","x"]]],
  ["pipeline {\"command\":\"d=$(mktemp -d) && cd \\\"$d\\\" && git checkout -q x\",\"cwd\":\"/repo\",\"home\":\"\",\"follow\":true}",[{"words":["mktemp","-d"],"substitution":true,"folder":null},{"words":["cd","$d"],"folder":"/repo"},{"words":["git","checkout","-q","x"],"folder":null}]],
  ["git {\"words\":[\"mktemp\",\"-d\"]}",null],
  ["git {\"words\":[\"cd\",\"$d\"]}",null],
  ["git {\"words\":[\"git\",\"checkout\",\"-q\",\"x\"]}",{"sub":"checkout","args":["-q","x"]}],
  ["writes {\"command\":\"d=$(mktemp -d) && cd \\\"$d\\\" && git checkout -q x\",\"cwd\":\"/repo\",\"home\":\"\"}",{"files":[],"changes":[],"unnamed":[]}],
  // #3323: a program the reader does not know, handed words that spell a path, measured from mod-kit's readers on 2026-11-21.
  ["commands {\"command\":\"prettier --write notes.txt\"}",[["prettier","--write","notes.txt"]]],
  ["git {\"words\":[\"prettier\",\"--write\",\"notes.txt\"]}",null],
  ["writes {\"command\":\"prettier --write notes.txt\",\"cwd\":\"/repo\",\"home\":\"\"}",{"files":[],"changes":[],"unnamed":[],"runs":[{"what":"a program the write reader does not know","script":"prettier","tool":true,"unknown":true,"why":"prettier is a program the mods do not know, so what it does with a file it is handed cannot be read before it runs","remedy":"To only read a file, use a program the mods know only reads (cat, grep, head, tail, wc, diff and the others listed under \"The programs that only read\" in claude-config's docs/mods-design.md). If prettier only reads too, ask Dan to add it to that list: only he may.","args":[{"word":"notes.txt","path":"/repo/notes.txt"}]}]}],
  ["commands {\"command\":\"gh pr checkout 5\"}",[["gh","pr","checkout","5"]]],
  ["git {\"words\":[\"gh\",\"pr\",\"checkout\",\"5\"]}",null],
  ["writes {\"command\":\"gh pr checkout 5\",\"cwd\":\"/repo\",\"home\":\"\"}",{"files":[],"changes":[],"unnamed":[],"runs":[{"what":"a program the write reader does not know","script":"gh","tool":true,"unknown":true,"why":"gh is a program the mods do not know, so what it does with a file it is handed cannot be read before it runs","remedy":"To only read a file, use a program the mods know only reads (cat, grep, head, tail, wc, diff and the others listed under \"The programs that only read\" in claude-config's docs/mods-design.md). If gh only reads too, ask Dan to add it to that list: only he may.","args":[{"word":"pr","path":"/repo/pr"},{"word":"checkout","path":"/repo/checkout"},{"word":"5","path":"/repo/5"}]}]}],
  ["commands {\"command\":\"prettier --check other.txt && ./tidy.sh other.txt\"}",[["prettier","--check","other.txt"],["./tidy.sh","other.txt"]]],
  ["git {\"words\":[\"prettier\",\"--check\",\"other.txt\"]}",null],
  ["git {\"words\":[\"./tidy.sh\",\"other.txt\"]}",null],
  ["writes {\"command\":\"prettier --check other.txt && ./tidy.sh other.txt\",\"cwd\":\"/repo\",\"home\":\"\"}",{"files":[],"changes":[],"unnamed":[],"runs":[{"what":"a program the write reader does not know","script":"prettier","tool":true,"unknown":true,"why":"prettier is a program the mods do not know, so what it does with a file it is handed cannot be read before it runs","remedy":"To only read a file, use a program the mods know only reads (cat, grep, head, tail, wc, diff and the others listed under \"The programs that only read\" in claude-config's docs/mods-design.md). If prettier only reads too, ask Dan to add it to that list: only he may.","args":[{"word":"other.txt","path":"/repo/other.txt"}]},{"what":"a script file run directly","script":"./tidy.sh","path":"/repo/tidy.sh","args":[{"word":"other.txt","path":"/repo/other.txt"}]}]}],
  // #1592: a script file handed files as its arguments, measured from mod-kit's readers on 2026-10-23.
  ["commands {\"command\":\"python3 tools/fix.py notes.txt\"}",[["python3","tools/fix.py","notes.txt"]]],
  ["git {\"words\":[\"python3\",\"tools/fix.py\",\"notes.txt\"]}",null],
  ["writes {\"command\":\"python3 tools/fix.py notes.txt\",\"cwd\":\"/repo\",\"home\":\"\"}",{"files":[],"changes":[],"unnamed":[],"runs":[{"what":"a python3 script file","script":"tools/fix.py","path":"/repo/tools/fix.py","args":[{"word":"notes.txt","path":"/repo/notes.txt"}]}]}],
  ["commands {\"command\":\"python3 tools/fix.py --check other.txt\"}",[["python3","tools/fix.py","--check","other.txt"]]],
  ["git {\"words\":[\"python3\",\"tools/fix.py\",\"--check\",\"other.txt\"]}",null],
  ["writes {\"command\":\"python3 tools/fix.py --check other.txt\",\"cwd\":\"/repo\",\"home\":\"\"}",{"files":[],"changes":[],"unnamed":[],"runs":[{"what":"a python3 script file","script":"tools/fix.py","path":"/repo/tools/fix.py","args":[{"word":"other.txt","path":"/repo/other.txt"}]}]}],
  ["commands {\"command\":\"./tidy.sh notes.txt\"}",[["./tidy.sh","notes.txt"]]],
  ["git {\"words\":[\"./tidy.sh\",\"notes.txt\"]}",null],
  ["writes {\"command\":\"./tidy.sh notes.txt\",\"cwd\":\"/repo\",\"home\":\"\"}",{"files":[],"changes":[],"unnamed":[],"runs":[{"what":"a script file run directly","script":"./tidy.sh","path":"/repo/tidy.sh","args":[{"word":"notes.txt","path":"/repo/notes.txt"}]}]}],
  // #1136: what git itself changes, measured from mod-kit's readers on 2026-10-13.
  ["commands {\"command\":\"git checkout main -- notes.txt\"}",[["git","checkout","main","--","notes.txt"]]],
  ["git {\"words\":[\"git\",\"checkout\",\"main\",\"--\",\"notes.txt\"]}",{"sub":"checkout","args":["main","--","notes.txt"]}],
  ["writes {\"command\":\"git checkout main -- notes.txt\",\"cwd\":\"/repo\",\"home\":\"\"}",{"files":[],"changes":[],"unnamed":[],"byGit":[{"word":"notes.txt","path":"/repo/notes.txt","does":"write","tree":true,"from":"main"}]}],
  ["commands {\"command\":\"git restore notes.txt\"}",[["git","restore","notes.txt"]]],
  ["git {\"words\":[\"git\",\"restore\",\"notes.txt\"]}",{"sub":"restore","args":["notes.txt"]}],
  ["writes {\"command\":\"git restore notes.txt\",\"cwd\":\"/repo\",\"home\":\"\"}",{"files":[],"changes":[],"unnamed":[],"byGit":[{"word":"notes.txt","path":"/repo/notes.txt","does":"write","tree":true,"from":""}]}],
  ["commands {\"command\":\"git rm notes.txt\"}",[["git","rm","notes.txt"]]],
  ["git {\"words\":[\"git\",\"rm\",\"notes.txt\"]}",{"sub":"rm","args":["notes.txt"]}],
  ["writes {\"command\":\"git rm notes.txt\",\"cwd\":\"/repo\",\"home\":\"\"}",{"files":[],"changes":[],"unnamed":[],"byGit":[{"word":"notes.txt","path":"/repo/notes.txt","does":"remove"}]}],
  ["commands {\"command\":\"git mv notes.txt docs/old.txt\"}",[["git","mv","notes.txt","docs/old.txt"]]],
  ["git {\"words\":[\"git\",\"mv\",\"notes.txt\",\"docs/old.txt\"]}",{"sub":"mv","args":["notes.txt","docs/old.txt"]}],
  ["writes {\"command\":\"git mv notes.txt docs/old.txt\",\"cwd\":\"/repo\",\"home\":\"\"}",{"files":[],"changes":[],"unnamed":[],"byGit":[{"word":"docs/old.txt","path":"/repo/docs/old.txt","does":"write"},{"word":"docs/old.txt/notes.txt","path":"/repo/docs/old.txt/notes.txt","does":"write","tree":true},{"word":"notes.txt","path":"/repo/notes.txt","does":"remove","tree":true}]}],
  ["commands {\"command\":\"git rm -r src\"}",[["git","rm","-r","src"]]],
  ["git {\"words\":[\"git\",\"rm\",\"-r\",\"src\"]}",{"sub":"rm","args":["-r","src"]}],
  ["writes {\"command\":\"git rm -r src\",\"cwd\":\"/repo\",\"home\":\"\"}",{"files":[],"changes":[],"unnamed":[],"byGit":[{"word":"src","path":"/repo/src","does":"remove","tree":true}]}],
  // #751: one command writing a file whose note fails beside one whose note lands, measured from
  // mod-kit's readers on 2026-10-05.
  ["commands {\"command\":\"echo x > unwritable.txt; echo y > fine.txt\"}", [["echo","x",">","unwritable.txt"],["echo","y",">","fine.txt"]]],
  ["git {\"words\":[\"echo\",\"x\",\">\",\"unwritable.txt\"]}", null],
  ["git {\"words\":[\"echo\",\"y\",\">\",\"fine.txt\"]}", null],
  ["writes {\"command\":\"echo x > unwritable.txt; echo y > fine.txt\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"unwritable.txt","path":"/repo/unwritable.txt"},{"word":"fine.txt","path":"/repo/fine.txt"}],"changes":[],"unnamed":[],"stdout":[{"word":"unwritable.txt","path":"/repo/unwritable.txt"},{"word":"fine.txt","path":"/repo/fine.txt"}]}],
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
  ["writes {\"command\":\"printf 'one more line\\\\n' >> notes.txt\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"notes.txt","path":"/repo/notes.txt"}],"changes":[],"unnamed":[],"stdout":[{"word":"notes.txt","path":"/repo/notes.txt"}]}],
  ["commands {\"command\":\"echo done >> notes.txt\"}", [["echo","done",">>","notes.txt"]]],
  ["git {\"words\":[\"echo\",\"done\",\">>\",\"notes.txt\"]}", null],
  ["writes {\"command\":\"echo done >> notes.txt\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"notes.txt","path":"/repo/notes.txt"}],"changes":[],"unnamed":[],"stdout":[{"word":"notes.txt","path":"/repo/notes.txt"}]}],
  ["commands {\"command\":\"printf x >> notes.txt; false\"}", [["printf","x",">>","notes.txt"],["false"]]],
  ["git {\"words\":[\"printf\",\"x\",\">>\",\"notes.txt\"]}", null],
  ["git {\"words\":[\"false\"]}", null],
  ["writes {\"command\":\"printf x >> notes.txt; false\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"notes.txt","path":"/repo/notes.txt"}],"changes":[],"unnamed":[],"stdout":[{"word":"notes.txt","path":"/repo/notes.txt"}]}],
  ["commands {\"command\":\"echo x >> notes.txt\"}", [["echo","x",">>","notes.txt"]]],
  ["git {\"words\":[\"echo\",\"x\",\">>\",\"notes.txt\"]}", null],
  ["writes {\"command\":\"echo x >> notes.txt\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"notes.txt","path":"/repo/notes.txt"}],"changes":[],"unnamed":[],"stdout":[{"word":"notes.txt","path":"/repo/notes.txt"}]}],
  ["commands {\"command\":\"sed -i \\\"\\\" s/a/b/ notes.txt\"}", [["sed","-i","","s/a/b/","notes.txt"]]],
  ["git {\"words\":[\"sed\",\"-i\",\"\",\"s/a/b/\",\"notes.txt\"]}", null],
  ["writes {\"command\":\"sed -i \\\"\\\" s/a/b/ notes.txt\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"notes.txt","path":"/repo/notes.txt","edits":true}],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"cat notes.txt\"}", [["cat","notes.txt"]]],
  ["git {\"words\":[\"cat\",\"notes.txt\"]}", null],
  ["writes {\"command\":\"cat notes.txt\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"python3 -c \\\"open('notes.txt','a').write('x')\\\"\"}", [["python3","-c","open('notes.txt','a').write('x')"]]],
  ["git {\"words\":[\"python3\",\"-c\",\"open('notes.txt','a').write('x')\"]}", null],
  ["writes {\"command\":\"python3 -c \\\"open('notes.txt','a').write('x')\\\"\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[],"changes":[],"unnamed":[{"what":"an inline python3 script","words":["python3","-c","open('notes.txt','a').write('x')"],"inputs":[],"targets":["/repo/notes.txt"],"program":"open('notes.txt','a').write('x')","folder":"/repo"}]}],
  ["commands {\"command\":\"cp /tmp/notes.txt docs\"}", [["cp","/tmp/notes.txt","docs"]]],
  ["git {\"words\":[\"cp\",\"/tmp/notes.txt\",\"docs\"]}", null],
  ["writes {\"command\":\"cp /tmp/notes.txt docs\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"docs","path":"/repo/docs","sources":["/tmp/notes.txt"],"mayBeFolder":true}],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"cp /tmp/x.txt notes.txt\"}", [["cp","/tmp/x.txt","notes.txt"]]],
  ["git {\"words\":[\"cp\",\"/tmp/x.txt\",\"notes.txt\"]}", null],
  ["writes {\"command\":\"cp /tmp/x.txt notes.txt\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"notes.txt","path":"/repo/notes.txt","sources":["/tmp/x.txt"],"mayBeFolder":true}],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"echo x > notes.txt\"}", [["echo","x",">","notes.txt"]]],
  ["git {\"words\":[\"echo\",\"x\",\">\",\"notes.txt\"]}", null],
  ["writes {\"command\":\"echo x > notes.txt\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"notes.txt","path":"/repo/notes.txt"}],"changes":[],"unnamed":[],"stdout":[{"word":"notes.txt","path":"/repo/notes.txt"}]}],
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
  ["writes {\"command\":\"mv src /tmp/old-src\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"/tmp/old-src","path":"/tmp/old-src","sources":["/repo/src"],"mayBeFolder":true}],"changes":[{"word":"src","path":"/repo/src","does":"remove","tree":true,"to":{"word":"/tmp/old-src","path":"/tmp/old-src"}}],"unnamed":[]}],
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
  ["writes {\"command\":\"echo > d; rm -r d\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"d","path":"/repo/d"}],"changes":[{"word":"d","path":"/repo/d","does":"remove","tree":true}],"unnamed":[],"stdout":[{"word":"d","path":"/repo/d"}]}],
  ["commands {\"command\":\"rm '/Users\/dan/Documents/Documents - Dan’s MacBook Pro/app.ts'\"}", [["rm","/Users\/dan/Documents/Documents - Dan’s MacBook Pro/app.ts"]]],
  ["git {\"words\":[\"rm\",\"/Users\/dan/Documents/Documents - Dan’s MacBook Pro/app.ts\"]}", null],
  ["writes {\"command\":\"rm '/Users\/dan/Documents/Documents - Dan’s MacBook Pro/app.ts'\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[],"changes":[{"word":"/Users\/dan/Documents/Documents - Dan’s MacBook Pro/app.ts","path":"/Users\/dan/Documents/Documents - Dan’s MacBook Pro/app.ts","does":"remove"}],"unnamed":[]}],
  ["commands {\"command\":\"rm -r '/Users\/dan/Documents/Documents - Dan’s MacBook Pro'\"}", [["rm","-r","/Users\/dan/Documents/Documents - Dan’s MacBook Pro"]]],
  ["git {\"words\":[\"rm\",\"-r\",\"/Users\/dan/Documents/Documents - Dan’s MacBook Pro\"]}", null],
  ["writes {\"command\":\"rm -r '/Users\/dan/Documents/Documents - Dan’s MacBook Pro'\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[],"changes":[{"word":"/Users\/dan/Documents/Documents - Dan’s MacBook Pro","path":"/Users\/dan/Documents/Documents - Dan’s MacBook Pro","does":"remove","tree":true}],"unnamed":[]}],
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
  ["writes {\"command\":\"echo x > /tmp/out.txt && echo y > /private/tmp/claude-501/s/scratchpad/674/n.md && echo z >> notes.txt\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"/tmp/out.txt","path":"/tmp/out.txt"},{"word":"/private/tmp/claude-501/s/scratchpad/674/n.md","path":"/private/tmp/claude-501/s/scratchpad/674/n.md"},{"word":"notes.txt","path":"/repo/notes.txt"}],"changes":[],"unnamed":[],"stdout":[{"word":"/tmp/out.txt","path":"/tmp/out.txt"},{"word":"/private/tmp/claude-501/s/scratchpad/674/n.md","path":"/private/tmp/claude-501/s/scratchpad/674/n.md"},{"word":"notes.txt","path":"/repo/notes.txt"}]}],
  ["commands {\"command\":\"echo x > /tmp/out.txt; echo z >> notes.txt\"}", [["echo","x",">","/tmp/out.txt"],["echo","z",">>","notes.txt"]]],
  ["writes {\"command\":\"echo x > /tmp/out.txt; echo z >> notes.txt\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"/tmp/out.txt","path":"/tmp/out.txt"},{"word":"notes.txt","path":"/repo/notes.txt"}],"changes":[],"unnamed":[],"stdout":[{"word":"/tmp/out.txt","path":"/tmp/out.txt"},{"word":"notes.txt","path":"/repo/notes.txt"}]}],
  ["commands {\"command\":\"echo x > /tmp/shared.txt\"}", [["echo","x",">","/tmp/shared.txt"]]],
  ["git {\"words\":[\"echo\",\"x\",\">\",\"/tmp/shared.txt\"]}", null],
  ["writes {\"command\":\"echo x > /tmp/shared.txt\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"/tmp/shared.txt","path":"/tmp/shared.txt"}],"changes":[],"unnamed":[],"stdout":[{"word":"/tmp/shared.txt","path":"/tmp/shared.txt"}]}],
  ["commands {\"command\":\"echo x >> /wt/feature/notes.txt\"}", [["echo","x",">>","/wt/feature/notes.txt"]]],
  ["git {\"words\":[\"echo\",\"x\",\">>\",\"/wt/feature/notes.txt\"]}", null],
  ["writes {\"command\":\"echo x >> /wt/feature/notes.txt\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"/wt/feature/notes.txt","path":"/wt/feature/notes.txt"}],"changes":[],"unnamed":[],"stdout":[{"word":"/wt/feature/notes.txt","path":"/wt/feature/notes.txt"}]}],
  ["commands {\"command\":\"echo a > /tmp/clone/x.txt; echo b > /private/tmp/claude-501/s/scratchpad/700/n.md; echo c > /Volumes/fast/tmp/clone/y.txt; echo d > /Users\/dan/Desktop/n.txt; echo e >> notes.txt\"}", [["echo","a",">","/tmp/clone/x.txt"],["echo","b",">","/private/tmp/claude-501/s/scratchpad/700/n.md"],["echo","c",">","/Volumes/fast/tmp/clone/y.txt"],["echo","d",">","/Users\/dan/Desktop/n.txt"],["echo","e",">>","notes.txt"]]],
  ["git {\"words\":[\"echo\",\"a\",\">\",\"/tmp/clone/x.txt\"]}", null],
  ["git {\"words\":[\"echo\",\"b\",\">\",\"/private/tmp/claude-501/s/scratchpad/700/n.md\"]}", null],
  ["git {\"words\":[\"echo\",\"c\",\">\",\"/Volumes/fast/tmp/clone/y.txt\"]}", null],
  ["git {\"words\":[\"echo\",\"d\",\">\",\"/Users\/dan/Desktop/n.txt\"]}", null],
  ["git {\"words\":[\"echo\",\"e\",\">>\",\"notes.txt\"]}", null],
  ["writes {\"command\":\"echo a > /tmp/clone/x.txt; echo b > /private/tmp/claude-501/s/scratchpad/700/n.md; echo c > /Volumes/fast/tmp/clone/y.txt; echo d > /Users\/dan/Desktop/n.txt; echo e >> notes.txt\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"/tmp/clone/x.txt","path":"/tmp/clone/x.txt"},{"word":"/private/tmp/claude-501/s/scratchpad/700/n.md","path":"/private/tmp/claude-501/s/scratchpad/700/n.md"},{"word":"/Volumes/fast/tmp/clone/y.txt","path":"/Volumes/fast/tmp/clone/y.txt"},{"word":"/Users\/dan/Desktop/n.txt","path":"/Users\/dan/Desktop/n.txt"},{"word":"notes.txt","path":"/repo/notes.txt"}],"changes":[],"unnamed":[],"stdout":[{"word":"/tmp/clone/x.txt","path":"/tmp/clone/x.txt"},{"word":"/private/tmp/claude-501/s/scratchpad/700/n.md","path":"/private/tmp/claude-501/s/scratchpad/700/n.md"},{"word":"/Volumes/fast/tmp/clone/y.txt","path":"/Volumes/fast/tmp/clone/y.txt"},{"word":"/Users\/dan/Desktop/n.txt","path":"/Users\/dan/Desktop/n.txt"},{"word":"notes.txt","path":"/repo/notes.txt"}]}],
  ["commands {\"command\":\"echo x > /Volumes/locked/notes.txt\"}", [["echo","x",">","/Volumes/locked/notes.txt"]]],
  ["git {\"words\":[\"echo\",\"x\",\">\",\"/Volumes/locked/notes.txt\"]}", null],
  ["writes {\"command\":\"echo x > /Volumes/locked/notes.txt\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"/Volumes/locked/notes.txt","path":"/Volumes/locked/notes.txt"}],"changes":[],"unnamed":[],"stdout":[{"word":"/Volumes/locked/notes.txt","path":"/Volumes/locked/notes.txt"}]}],
  ["commands {\"command\":\"bash <<'EOF'\\necho done >> notes.txt\\nEOF\"}", [["echo","done",">>","notes.txt"]]],
  ["writes {\"command\":\"bash <<'EOF'\\necho done >> notes.txt\\nEOF\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"notes.txt","path":"/repo/notes.txt"}],"changes":[],"unnamed":[],"stdout":[{"word":"notes.txt","path":"/repo/notes.txt"}]}],
  ["commands {\"command\":\"truncate -s 0 notes.txt\"}", [["truncate","-s","0","notes.txt"]]],
  ["git {\"words\":[\"truncate\",\"-s\",\"0\",\"notes.txt\"]}", null],
  ["writes {\"command\":\"truncate -s 0 notes.txt\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[],"changes":[{"word":"notes.txt","path":"/repo/notes.txt","does":"truncate"}],"unnamed":[]}],
  ["commands {\"command\":\"make >& notes.txt\"}", [["make",">&","notes.txt"]]],
  ["git {\"words\":[\"make\",\">&\",\"notes.txt\"]}", null],
  ["writes {\"command\":\"make >& notes.txt\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"notes.txt","path":"/repo/notes.txt"}],"changes":[],"unnamed":[],"stdout":[{"word":"notes.txt","path":"/repo/notes.txt"}]}],
  ["commands {\"command\":\"cat <<EOF\\nnote $(echo done >> notes.txt)\\nEOF\"}", [["echo","done",">>","notes.txt"],["cat","<<EOF"]]],
  ["git {\"words\":[\"cat\",\"<<EOF\"]}", null],
  ["writes {\"command\":\"cat <<EOF\\nnote $(echo done >> notes.txt)\\nEOF\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"notes.txt","path":"/repo/notes.txt"}],"changes":[],"unnamed":[],"stdout":[{"word":"notes.txt","path":"/repo/notes.txt"}]}],
  ["commands {\"command\":\"echo \\\"note `echo done >> notes.txt`\\\"\"}", [["echo","done",">>","notes.txt"],["echo","note `echo done >> notes.txt`"]]],
  ["git {\"words\":[\"echo\",\"note `echo done >> notes.txt`\"]}", null],
  ["writes {\"command\":\"echo \\\"note `echo done >> notes.txt`\\\"\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"notes.txt","path":"/repo/notes.txt"}],"changes":[],"unnamed":[],"stdout":[{"word":"notes.txt","path":"/repo/notes.txt"}]}],
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
  ["writes {\"command\":\"bash -c 'echo done >> notes.txt'\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"notes.txt","path":"/repo/notes.txt"}],"changes":[],"unnamed":[],"stdout":[{"word":"notes.txt","path":"/repo/notes.txt"}]}],
  ["commands {\"command\":\"sh -c 'echo \\\"$(echo done >> notes.txt)\\\"'\"}", [["echo","done",">>","notes.txt"],["echo","$(echo done >> notes.txt)"]]],
  ["git {\"words\":[\"echo\",\"$(echo done >> notes.txt)\"]}", null],
  ["writes {\"command\":\"sh -c 'echo \\\"$(echo done >> notes.txt)\\\"'\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"notes.txt","path":"/repo/notes.txt"}],"changes":[],"unnamed":[],"stdout":[{"word":"notes.txt","path":"/repo/notes.txt"}]}],
  ["commands {\"command\":\"zsh -c 'echo \\\"`echo done >> notes.txt`\\\"'\"}", [["echo","done",">>","notes.txt"],["echo","`echo done >> notes.txt`"]]],
  ["git {\"words\":[\"echo\",\"`echo done >> notes.txt`\"]}", null],
  ["writes {\"command\":\"zsh -c 'echo \\\"`echo done >> notes.txt`\\\"'\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"notes.txt","path":"/repo/notes.txt"}],"changes":[],"unnamed":[],"stdout":[{"word":"notes.txt","path":"/repo/notes.txt"}]}],
  ["commands {\"command\":\"sh <<'EOF'\\nx=$(echo done >> notes.txt)\\nEOF\"}", [["echo","done",">>","notes.txt"]]],
  ["writes {\"command\":\"sh <<'EOF'\\nx=$(echo done >> notes.txt)\\nEOF\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"notes.txt","path":"/repo/notes.txt"}],"changes":[],"unnamed":[],"stdout":[{"word":"notes.txt","path":"/repo/notes.txt"}]}],
  ["commands {\"command\":\"echo 'echo done >> notes.txt' | bash\"}", [["echo","echo done >> notes.txt"],["echo","done",">>","notes.txt"]]],
  ["git {\"words\":[\"echo\",\"echo done >> notes.txt\"]}", null],
  ["writes {\"command\":\"echo 'echo done >> notes.txt' | bash\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"notes.txt","path":"/repo/notes.txt"}],"changes":[],"unnamed":[],"stdout":[{"word":"notes.txt","path":"/repo/notes.txt"}]}],
  ["commands {\"command\":\"diff <(echo done >> notes.txt) b.txt\"}", [["echo","done",">>","notes.txt"],["diff","<(echo done >> notes.txt)","b.txt"]]],
  ["writes {\"command\":\"diff <(echo done >> notes.txt) b.txt\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"notes.txt","path":"/repo/notes.txt"}],"changes":[],"unnamed":[],"stdout":[{"word":"notes.txt","path":"/repo/notes.txt"}]}],
  ["commands {\"command\":\"tee >(cat >> notes.txt) < b.txt\"}", [["cat",">>","notes.txt"],["tee",">(cat >> notes.txt)","<","b.txt"]]],
  ["git {\"words\":[\"cat\",\">>\",\"notes.txt\"]}", null],
  ["writes {\"command\":\"tee >(cat >> notes.txt) < b.txt\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"notes.txt","path":"/repo/notes.txt"}],"changes":[],"unnamed":[],"stdout":[{"word":"notes.txt","path":"/repo/notes.txt"}]}],
  ["commands {\"command\":\"cat > /dev/null <<'EOF'\\necho done >> notes.txt $(echo done >> notes.txt) <(echo done >> notes.txt)\\nEOF\"}", [["cat",">","/dev/null","<<EOF"]]],
  ["git {\"words\":[\"cat\",\">\",\"/dev/null\",\"<<EOF\"]}", null],
  ["writes {\"command\":\"cat > /dev/null <<'EOF'\\necho done >> notes.txt $(echo done >> notes.txt) <(echo done >> notes.txt)\\nEOF\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"echo \\\"<(echo done >> notes.txt)\\\"\"}", [["echo","<(echo done >> notes.txt)"]]],
  ["git {\"words\":[\"echo\",\"<(echo done >> notes.txt)\"]}", null],
  ["writes {\"command\":\"echo \\\"<(echo done >> notes.txt)\\\"\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[],"changes":[],"unnamed":[]}],
  ["git {\"words\":[\"diff\",\"<(echo done >> notes.txt)\",\"b.txt\"]}", null],
  ["git {\"words\":[\"tee\",\">(cat >> notes.txt)\",\"<\",\"b.txt\"]}", null],
  ["commands {\"command\":\"bash <<EOF\\necho \\\\$(echo done >> notes.txt)\\nEOF\"}", [["echo","done",">>","notes.txt"],["echo","$(echo done >> notes.txt)"]]],
  ["writes {\"command\":\"bash <<EOF\\necho \\\\$(echo done >> notes.txt)\\nEOF\",\"cwd\":\"/repo\",\"home\":\"\"}", {"files":[{"word":"notes.txt","path":"/repo/notes.txt"}],"changes":[],"unnamed":[],"stdout":[{"word":"notes.txt","path":"/repo/notes.txt"}]}],
  // #3021: commands whose effect cannot be read, measured from mod-kit's readers on 2026-11-15.
  ["commands {\"command\":\"eval \\\"$BUILD_STEP\\\"\"}",[["eval","$BUILD_STEP"]]],
  ["git {\"words\":[\"eval\",\"$BUILD_STEP\"]}",null],
  ["writes {\"command\":\"eval \\\"$BUILD_STEP\\\"\",\"cwd\":\"/repo\",\"home\":\"\"}",{"files":[],"changes":[],"unnamed":[],"unread":[{"words":["eval","$BUILD_STEP"],"why":"run as text by eval, so what it runs cannot be read","folder":"/repo"}]}],
  ["commands {\"command\":\"ls src\"}",[["ls","src"]]],
  ["git {\"words\":[\"ls\",\"src\"]}",null],
  ["writes {\"command\":\"ls src\",\"cwd\":\"/repo\",\"home\":\"\"}",{"files":[],"changes":[],"unnamed":[]}],
  ["commands {\"command\":\"cd /other && eval \\\"$BUILD_STEP\\\"\"}",[["cd","/other"],["eval","$BUILD_STEP"]]],
  ["git {\"words\":[\"cd\",\"/other\"]}",null],
  ["writes {\"command\":\"cd /other && eval \\\"$BUILD_STEP\\\"\",\"cwd\":\"/repo\",\"home\":\"\"}",{"files":[],"changes":[],"unnamed":[],"unread":[{"words":["eval","$BUILD_STEP"],"why":"run as text by eval, so what it runs cannot be read","folder":"/other"}]}],
  ["commands {\"command\":\"eval \\\"$BUILD_STEP\\\" && \\\"$RUNNER\\\" --fix\"}",[["eval","$BUILD_STEP"],["$RUNNER","--fix"]]],
  ["git {\"words\":[\"$RUNNER\",\"--fix\"]}",null],
  ["writes {\"command\":\"eval \\\"$BUILD_STEP\\\" && \\\"$RUNNER\\\" --fix\",\"cwd\":\"/repo\",\"home\":\"\"}",{"files":[],"changes":[],"unnamed":[],"unread":[{"words":["eval","$BUILD_STEP"],"why":"run as text by eval, so what it runs cannot be read","folder":"/repo"},{"words":["$RUNNER","--fix"],"why":"named by a value the shell expands, so what it runs cannot be read","folder":"/repo"}]}],
  ["commands {\"command\":\"cd \\\"$D\\\" && eval \\\"$BUILD_STEP\\\"\"}",[["cd","$D"],["eval","$BUILD_STEP"]]],
  ["git {\"words\":[\"cd\",\"$D\"]}",null],
  ["writes {\"command\":\"cd \\\"$D\\\" && eval \\\"$BUILD_STEP\\\"\",\"cwd\":\"/repo\",\"home\":\"\"}",{"files":[],"changes":[],"unnamed":[],"unread":[{"words":["eval","$BUILD_STEP"],"why":"run as text by eval, so what it runs cannot be read"}]}],
])

type Judge = string | 'no-answer'
// Each send's outcome in turn: delivered, refused with this reason, or a throw.
type Send = true | { refused: string } | 'throws'
// How the call fares beneath the guard: it runs (the default), it runs and fails, or a later guard
// refuses it.
type Ran = 'ok' | 'error' | { deny: string }
type Opts = { self?: Record<string, unknown>; open?: unknown[]; unreadable?: string[]; judge?: Judge; repo?: string; branch?: string | { fails: string }; branchReaderFails?: string; sends?: Send[]; tail?: 'fails' | 'no-request'; ran?: Ran; gits?: Record<string, 'dir' | 'file'>; locked?: string; tmpdir?: string; listBreaks?: boolean; tops?: Record<string, string | null | { says: string }> }

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
    // #3398: what git answers a rev-parse question put with these exact words, where a test says:
    // a folder, or null for a question git fails (no such folder, no repository there). `says` is
    // git failing in other words of its own (lessons review of #3398): every such failure exits 128,
    // whatever it is, so only the words tell nothing there from a question git could not answer.
    if (cmd === 'git' && args.includes('rev-parse') && o.tops && args.join(' ') in o.tops) {
      const top = o.tops[args.join(' ')] as string | null | { says: string }
      if (top !== null && typeof top === 'object') return { value: { exitCode: 128, stdout: '', stderr: top.says, isStdoutTruncated: false, isStderrTruncated: false } }
      return top === null ? { value: { exitCode: 128, stdout: '', stderr: 'fatal: not a git repository', isStdoutTruncated: false, isStderrTruncated: false } } : ok(`${top}\n`)
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
  // Core, standing in (mod-kit's tests/core.ts): the tool.check chain over every plugin decides
  // whether the call may run, then it runs. Beneath every plugin's tool.check hook the rules allow it.
  const core = standInCore(engine, on)
  on('tool.call', async ($, e) => {
    const c = await core(e)
    if ('refused' in c) return c.refused as never
    if (typeof o.ran === 'object') return { deny: o.ran.deny } as never
    w.reached.push(e.tool)
    if (o.ran === 'error') return { result: 'exit status 1', text: 'exit status 1', isError: true } as never
    return { result: 'ran', text: 'ran' } as never
  })
  return w
}

const edit = (path: string, id = 'c1') => ({ tool: 'Edit', file_path: path, old_string: 'a', new_string: 'b', tool_use_id: id }) as never
const bash = (command: string, id = 'c1') => ({ tool: 'Bash', command, tool_use_id: id }) as never
// The guard's own reason, in whichever form Claude Code wraps a refusal (#1484).
const refusal = (r: unknown) => reasonOf(r, 'collision-guard')

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

// #3398: git acts on the repository a command names, never on the folder the call was typed in.
// The guard asked only about the folder the last -C names, read from the session's folder, with no
// settings handed to mod-kit's git reader and no cd followed. Each case here ran unjudged until
// then: the session's own checkout (/repo) has nobody else in it, and the checkout the command
// really acts on (/other) has another session at work.
const inOther = () => [rec('them', { cwd: '/other', repoRoot: '/other' })]
const revParses = (w: { runs: string[] }) => w.runs.filter(r => r.startsWith('git ') && r.includes('rev-parse'))
const stopped = '{"verdict":"Stop","reason":"They have uncommitted work."}'

test('a branch switch naming another repository by --git-dir and --work-tree is judged against the sessions there (#3398)', withDeps, async ($, on) => {
  const named = '-C /repo --git-dir=/other/.git --work-tree=/other rev-parse'
  const w = world($, on, { open: inOther(), judge: stopped, tops: { [`${named} --show-toplevel`]: '/other', '-C /other rev-parse --show-toplevel': '/other', [`${named} --absolute-git-dir`]: '/other/.git' } })
  const r = await $.tool.call(bash('git --git-dir=/other/.git --work-tree=/other checkout main'))
  expect(w.reached).not.toContain('Bash')
  expect(refusal(r)).toBe('Blocked: Another session is working in this checkout. They have uncommitted work. Leave it to the other session, or ask Dan.')
  expect(w.prompts.length).toBe(1)
  expect(w.prompts[0]?.prompt).toContain('The checkout: /other, on branch')
  expect(w.sent[0]?.text).toBe('Another session wanted to run git checkout main in this checkout while you are working in it, so it was stopped. Nothing here was touched.')
})

test('the same naming through GIT_DIR and GIT_WORK_TREE in front of the command is read too (#3398)', withDeps, async ($, on) => {
  const named = '-C /repo --git-dir=/other/.git --work-tree=/other rev-parse'
  const w = world($, on, { open: inOther(), tops: { [`${named} --show-toplevel`]: '/other', '-C /other rev-parse --show-toplevel': '/other', [`${named} --absolute-git-dir`]: '/other/.git' } })
  await $.tool.call(bash('GIT_DIR=/other/.git GIT_WORK_TREE=/other git checkout main'))
  expect(w.prompts.length).toBe(1)
  expect(w.prompts[0]?.prompt).toContain('The checkout: /other, on branch')
})

test('a repository named alone has its own checkout judged, where its branch moves, beside the folder the files land in (#3398)', withDeps, async ($, on) => {
  // Measured with git 2.51.1: with only the repository named, the files land in the folder the
  // command runs in, and the branch that moves is the named repository's.
  const named = '-C /repo --git-dir=/other/.git rev-parse'
  // The checkout around the named repository is found by mod-kit's walk for one, on the disk.
  const w = world($, on, { open: inOther(), gits: { '/other/.git': 'dir' }, tops: { [`${named} --show-toplevel`]: '/repo', [`${named} --absolute-git-dir`]: '/other/.git' } })
  await $.tool.call(bash('git --git-dir=/other/.git checkout main'))
  expect(w.prompts.length).toBe(1)
  expect(w.prompts[0]?.prompt).toContain('The checkout: /other, on branch')
})

test("another session's checkout that git says is the named repository is judged, wherever the repository sits (#3398)", withDeps, async ($, on) => {
  // A linked worktree's repository is a folder inside the main checkout's, which no walk up from
  // it finds the worktree by: git is asked of each other session's checkout which repository it is.
  const named = '-C /repo --git-dir=/main/.git/worktrees/w rev-parse'
  const tops = { [`${named} --show-toplevel`]: '/repo', [`${named} --absolute-git-dir`]: '/main/.git/worktrees/w', '-C /wt rev-parse --absolute-git-dir': '/main/.git/worktrees/w' }
  const w = world($, on, { open: [rec('them', { cwd: '/wt', repoRoot: '/wt' })], tops })
  await $.tool.call(bash('git --git-dir=/main/.git/worktrees/w checkout main'))
  expect(w.prompts.length).toBe(1)
  expect(w.prompts[0]?.prompt).toContain('The checkout: /wt, on branch')
})

test('a relative -C after a cd, and a command after a cd, are judged where the cd leaves the shell (#3398)', withDeps, async ($, on) => {
  // What the guard asked until now: sub read from the session's folder, where there is none.
  const tops = { '-C sub rev-parse --show-toplevel': null, '-C /other -C sub rev-parse --show-toplevel': '/other', '-C /other rev-parse --show-toplevel': '/other' }
  const w = world($, on, { open: inOther(), tops })
  await $.tool.call(bash('cd /other && git -C sub checkout main', 'c1'))
  expect(w.prompts.length).toBe(1)
  expect(w.prompts[0]?.prompt).toContain('The checkout: /other, on branch')
  await $.tool.call(bash('cd /other && git checkout main', 'c2'))
  expect(w.prompts.length).toBe(2)
  expect(w.prompts[1]?.prompt).toContain('The checkout: /other, on branch')
})

test('more than one -C is judged in the folder git chains them to, never the last one read alone (#3398)', withDeps, async ($, on) => {
  const w = world($, on, { open: inOther(), tops: { '-C sub rev-parse --show-toplevel': null, '-C /other/sub rev-parse --show-toplevel': '/other' } })
  await $.tool.call(bash('git -C /other -C sub checkout main'))
  expect(w.prompts.length).toBe(1)
  expect(w.prompts[0]?.prompt).toContain('The checkout: /other, on branch')
})

test('a watched git command whose repository cannot be told is stopped while another session is open, saying how to write it (#3398)', withDeps, async ($, on) => {
  const cases: [string, string][] = [
    ['git -C "$X" checkout main', 'the shell fills in the folder -C names ($X)'],
    ['git -C /a -C "$B" checkout main', 'its -C options lead to a folder the shell fills in'],
    ['cd "$X" && git checkout main', 'the cd before it cannot be followed'],
    ['git --git-dir="$G" checkout main', 'it names its repository as $G, which the guard cannot follow to a folder'],
    ['export GIT_DIR=/other/.git; git checkout main', 'the call names GIT_DIR somewhere other than as a setting on the git command itself'],
  ]
  // The other session is in a checkout nothing in the command's words leads to.
  const w = world($, on, { open: [rec('far', { cwd: '/far', repoRoot: '/far' })], tops: { '-C $X rev-parse --show-toplevel': null, '-C $B rev-parse --show-toplevel': null } })
  for (const [i, [command, why]] of cases.entries()) {
    const r = await $.tool.call(bash(command, `u${i}`))
    expect(refusal(r)).toBe(
      `Blocked: Couldn't tell which checkout git checkout main acts on (${why}), and another session is open, so this was stopped. Run it with every folder it names written out in full (git -C /path/to/checkout ...), or ask Dan.`,
    )
  }
  expect(w.reached).not.toContain('Bash')
  // Nothing was put to the judge and no session was told: there is no checkout to name to either.
  expect(w.prompts.length).toBe(0)
  expect(w.sent.length).toBe(0)
})

test('with no other session open, a command whose repository cannot be told goes through as it always did (#3398)', withDeps, async ($, on) => {
  const w = world($, on, { tops: { '-C $X rev-parse --show-toplevel': null } })
  await $.tool.call(bash('git -C "$X" checkout main', 'a1'))
  await $.tool.call(bash('cd "$X" && git checkout main', 'a2'))
  expect(w.reached.filter(t => t === 'Bash').length).toBe(2)
  expect(w.prompts.length).toBe(0)
})

// #3398 (Dan, 2026-11-22: "Follow the variable first"): a folder named with a variable the call
// itself sets is judged by the folder the variable holds, where mod-kit's reader says the call's
// own text makes that certain. Counted that day, it was the form of nearly every watched command
// the guard could not tell (12 of 13 past commands on one Mac, 11 of 12 on the other), and each
// was stopped. What git is asked with the variable as typed, the question the guard always put,
// finds nothing, as it did.
const typed = { '-C $W rev-parse --show-toplevel': null, '-C $R rev-parse --show-toplevel': null, '-C ${W} rev-parse --show-toplevel': null }

test('a folder named with a variable the call sets is judged by the folder it holds: held where another session is at work there (#3398)', withDeps, async ($, on) => {
  const w = world($, on, { open: inOther(), judge: stopped, tops: { ...typed, '-C /other rev-parse --show-toplevel': '/other' } })
  const r = await $.tool.call(bash('W=/other; git -C "$W" checkout main', 'f1'))
  expect(w.reached).not.toContain('Bash')
  expect(refusal(r)).toBe('Blocked: Another session is working in this checkout. They have uncommitted work. Leave it to the other session, or ask Dan.')
  expect(w.prompts.length).toBe(1)
  expect(w.prompts[0]?.prompt).toContain('The checkout: /other, on branch')
  // git is asked about the folder the variable holds, beside the question it was always asked.
  expect(revParses(w)).toEqual(['git -C $W rev-parse --show-toplevel', 'git -C /other rev-parse --show-toplevel'])
  // Set on a line of its own and used bare, it is read the same way.
  await $.tool.call(bash('R=/other\ngit -C $R reset --hard origin/main', 'f2'))
  expect(w.prompts.length).toBe(2)
  expect(w.prompts[1]?.prompt).toContain('The checkout: /other, on branch')
})

test('a followed folder that is one of a chain of -C is judged where git chains them to (#3398)', withDeps, async ($, on) => {
  const w = world($, on, { open: inOther(), tops: { ...typed, '-C /other/sub rev-parse --show-toplevel': '/other' } })
  await $.tool.call(bash('W=sub; git -C /other -C "${W}" checkout main'))
  expect(w.prompts.length).toBe(1)
  expect(w.prompts[0]?.prompt).toContain('The checkout: /other, on branch')
  expect(revParses(w)).toEqual(['git -C ${W} rev-parse --show-toplevel', 'git -C /other/sub rev-parse --show-toplevel'])
})

test('a followed folder where no other session is at work runs, with nothing put to the judge (#3398)', withDeps, async ($, on) => {
  const w = world($, on, { open: [rec('far', { cwd: '/far', repoRoot: '/far' })], tops: { ...typed, '-C /other rev-parse --show-toplevel': '/other' } })
  await $.tool.call(bash('W=/other; git -C "$W" checkout main'))
  expect(w.reached.filter(t => t === 'Bash').length).toBe(1)
  expect(w.prompts.length).toBe(0)
  expect(revParses(w)).toEqual(['git -C $W rev-parse --show-toplevel', 'git -C /other rev-parse --show-toplevel'])
})

test('a followed folder git cannot answer for stops the command, never reads as no checkout there (#3398)', withDeps, async ($, on) => {
  const w = world($, on, { open: inOther(), tops: { ...typed, '-C /other rev-parse --show-toplevel': { says: 'fatal: unable to read tree' } } })
  const r = await $.tool.call(bash('W=/other; git -C "$W" checkout main'))
  expect(w.reached).not.toContain('Bash')
  expect(refusal(r)).toContain("Couldn't tell which checkout git checkout main acts on")
  expect(refusal(r)).toContain('Try again, or ask Dan.')
})

test('a variable the call does not set once, plainly, before anything runs is not followed, and the command is still stopped (#3398)', withDeps, async ($, on) => {
  const filled = (word: string) => `the shell fills in the folder -C names (${word})`
  const cases: [string, string, string][] = [
    // Never a guess: each of these may hold another folder, or none, when git runs.
    ['W=/a; W=/other; git -C "$W" checkout main', filled('$W'), 'set twice'],
    ['git -C "$W" checkout main; W=/other', filled('$W'), 'set after it is used'],
    ['(W=/other); git -C "$W" checkout main', filled('$W'), 'set in a subshell'],
    ['f() { W=/other; }; f; git -C "$W" checkout main', filled('$W'), 'set in a function'],
    ['W=$(pwd); git -C "$W" checkout main', filled('$W'), "set from a command's output"],
    ['W=/other git -C "$W" checkout main', filled('$W'), 'a setting in front of the command, which reaches git and not the word'],
    // Kept strict, each Dan's to widen (the pull request's "For Dan" list).
    ['W=/other && git -C "$W" checkout main', filled('$W'), 'set before an &&'],
    ['export W=/other; git -C "$W" checkout main', filled('$W'), 'set by export'],
    ['REPO=/other; git -C "$REPO" checkout main', filled('$REPO'), 'a name all capitals, which a shell may keep for itself'],
    ['wt=/other; git -C "$wt" checkout main', filled('$wt'), 'a name all small letters'],
    ['W=~/other; git -C "$W" checkout main', filled('$W'), 'a value the shell fills in'],
    ['W="/my other"; git -C "$W" checkout main', filled('$W'), 'a value with a space'],
    ['W=/other; git -C "$W/sub" checkout main', filled('$W/sub'), 'used with more text beside it'],
    ['W=/other; git -C "$W" checkout main; cat <<EOF\nx\nEOF', filled('$W'), 'a call holding a heredoc'],
  ]
  // The other session is where the variable would lead: followed, each would be put to the judge.
  const w = world($, on, { open: inOther(), tops: { ...typed, '-C $REPO rev-parse --show-toplevel': null, '-C $wt rev-parse --show-toplevel': null, '-C $W/sub rev-parse --show-toplevel': null } })
  for (const [i, [command, why, what]] of cases.entries()) {
    const r = await $.tool.call(bash(command, `n${i}`))
    expect(`${what}: ${refusal(r)}`).toBe(
      `${what}: Blocked: Couldn't tell which checkout git checkout main acts on (${why}), and another session is open, so this was stopped. Run it with every folder it names written out in full (git -C /path/to/checkout ...), or ask Dan.`,
    )
  }
  expect(w.reached).not.toContain('Bash')
  expect(w.prompts.length).toBe(0)
  expect(w.sent.length).toBe(0)
})

test('a command behind a cd into a folder a command makes is not followed and is still stopped (#3398)', withDeps, async ($, on) => {
  // The one past command of the 13 counted that is not the variable form: out of this change's reach.
  const w = world($, on, { open: inOther() })
  const r = await $.tool.call(bash('d=$(mktemp -d) && cd "$d" && git checkout -q x'))
  expect(refusal(r)).toBe(
    "Blocked: Couldn't tell which checkout git checkout -q x acts on (the cd before it cannot be followed), and another session is open, so this was stopped. Run it with every folder it names written out in full (git -C /path/to/checkout ...), or ask Dan.",
  )
  expect(w.reached).not.toContain('Bash')
  expect(w.prompts.length).toBe(0)
})

// FOR DAN TO DECIDE (#3398): these are judged only because of the folder the guard always asked
// about, which is not where git runs them. Read as git reads them, neither touches /repo, so with
// nobody in /other they would run unjudged. That is the correct reading and a loosening, so the old
// question is still put beside the new one and these stay judged until Dan says to drop it.
test("what the old reading judged is still judged: the session's own checkout, for a chain or a cd leading elsewhere (#3398, Dan's to decide)", withDeps, async ($, on) => {
  // /repo/sub is a folder of the session's checkout, so the last -C read alone lands in /repo.
  const tops = { '-C sub rev-parse --show-toplevel': '/repo', '-C /other/sub rev-parse --show-toplevel': '/other', '-C /other rev-parse --show-toplevel': '/other' }
  const w = world($, on, { open: [rec('them')], tops })
  await $.tool.call(bash('git -C /other -C sub checkout main', 'p1'))
  expect(w.prompts.length).toBe(1)
  expect(w.prompts[0]?.prompt).toContain('The checkout: /repo, on branch')
  await $.tool.call(bash('cd /other && git checkout main', 'p2'))
  expect(w.prompts.length).toBe(2)
  expect(w.prompts[1]?.prompt).toContain('The checkout: /repo, on branch')
})

test('the controls: a plain command, one -C and a command in the folder it runs in ask git exactly what they always asked (#3398)', withDeps, async ($, on) => {
  // Not watched: nothing is asked of git at all.
  const quiet = world($, on, { open: [rec('them')] })
  await $.tool.call(bash('git status', 'k1'))
  await $.tool.call(bash('git -C /other log', 'k2'))
  expect(revParses(quiet)).toEqual([])
  expect(quiet.prompts.length).toBe(0)
  expect(quiet.reached.filter(t => t === 'Bash').length).toBe(2)
})

test('the controls: a watched command in the folder it runs in, and one with one -C, put one question to git and are judged as before (#3398)', withDeps, async ($, on) => {
  const here = world($, on, { open: [rec('them')] })
  await $.tool.call(bash('git checkout main'))
  expect(revParses(here)).toEqual(['git -C /repo rev-parse --show-toplevel'])
  expect(here.prompts.length).toBe(1)
  expect(here.prompts[0]?.prompt).toContain('The checkout: /repo, on branch')
})

test('the controls: one -C into another checkout puts its one question to git and is judged there as before (#3398)', withDeps, async ($, on) => {
  const there = world($, on, { open: [rec('them', { repoRoot: '/other' })], repo: '/other' })
  await $.tool.call(bash('git -C /other reset --hard origin/main'))
  expect(revParses(there)).toEqual(['git -C /other rev-parse --show-toplevel'])
  expect(there.prompts.length).toBe(1)
  expect(there.prompts[0]?.prompt).toContain('The checkout: /other, on branch')
})

// Lessons review of #3398: a lookup in that path that FAILED was read as "no checkout there", so
// the command ran with nothing asked beside a session it really acts on. Nothing there is an
// answer (git says so in words of its own, mod-kit's walk answers null); a question nobody could
// answer is not one, and stops the command (Dan, 2026-10-03: anything that cannot be judged or
// read is Stop).
const namedAlone = '-C /repo --git-dir=/other/.git rev-parse'
const namedLinked = '-C /repo --git-dir=/main/.git/worktrees/w rev-parse'
// Words of git's that are none of its nothing there answers. The first is measured from git 2.51.1
// asked about a folder it may not enter; the second is git's own wording, not measured here.
const denied = (folder: string) => `fatal: cannot change to '${folder}': Permission denied`
const unanswered = 'fatal: unknown error occurred while reading the configuration files'
const couldNotTell = (why: string) => `Blocked: Couldn't tell which checkout git checkout main acts on (${why}), and another session is open, so this was stopped. Try again, or ask Dan.`
// A session whose own repository could not be read, matched to a checkout by its folder.
const byFolder = (cwd: string) => [rec('them', { cwd, repoRoot: null })]

test('a named repository whose checkout mod-kit could not look for stops the command, never reads as no checkout (#3398 review)', withDeps, async ($, on) => {
  const w = world($, on, { open: byFolder('/other'), locked: '/other', tops: { [`${namedAlone} --show-toplevel`]: '/repo', [`${namedAlone} --absolute-git-dir`]: '/other/.git' } })
  const r = await $.tool.call(bash('git --git-dir=/other/.git checkout main'))
  expect(w.reached).not.toContain('Bash')
  expect(refusal(r)).toBe(couldNotTell('the checkout around /other/.git could not be looked for: the disk cannot read /other/.git'))
  expect(w.cards.length).toBe(1)
  // There is no checkout to name to the judge or to a session.
  expect(w.prompts.length).toBe(0)
  expect(w.sent.length).toBe(0)
})

test('the control: a named repository mod-kit finds no checkout around has nobody to ask there (#3398 review)', withDeps, async ($, on) => {
  const w = world($, on, { open: byFolder('/other'), gits: {}, tops: { [`${namedAlone} --show-toplevel`]: '/repo', [`${namedAlone} --absolute-git-dir`]: '/other/.git' } })
  await $.tool.call(bash('git --git-dir=/other/.git checkout main'))
  expect(w.reached).toEqual(['Bash'])
  expect(w.prompts.length).toBe(0)
  expect(w.cards.length).toBe(0)
})

test('the control: with no other session open no lookup is made, so one that would fail stops nothing (#3398 review)', withDeps, async ($, on) => {
  const w = world($, on, { locked: '/other', tops: { [`${namedAlone} --show-toplevel`]: { says: unanswered }, [`${namedAlone} --absolute-git-dir`]: { says: unanswered } } })
  await $.tool.call(bash('git --git-dir=/other/.git checkout main'))
  expect(w.reached).toEqual(['Bash'])
  expect(revParses(w)).toEqual(['git -C /repo rev-parse --show-toplevel'])
  expect(w.cards.length).toBe(0)
})

test('git failing to say which checkout the command runs in stops it (#3398 review)', withDeps, async ($, on) => {
  const w = world($, on, { open: inOther(), tops: { '-C /other rev-parse --show-toplevel': { says: denied('/other') } } })
  const r = await $.tool.call(bash('cd /other && git checkout main'))
  expect(w.reached).not.toContain('Bash')
  expect(refusal(r)).toBe(couldNotTell(`git did not say which checkout it runs in: ${denied('/other')}`))
  expect(w.prompts.length).toBe(0)
})

test('git failing to say where a named repository puts its files stops the command (#3398 review)', withDeps, async ($, on) => {
  const tops = { [`${namedAlone} --show-toplevel`]: { says: unanswered }, [`${namedAlone} --absolute-git-dir`]: '/other/.git' }
  const w = world($, on, { open: [rec('them', { cwd: '/x', repoRoot: '/x' })], gits: {}, tops })
  const r = await $.tool.call(bash('git --git-dir=/other/.git checkout main'))
  expect(w.reached).not.toContain('Bash')
  expect(refusal(r)).toBe(couldNotTell(`git did not say where its files land: ${unanswered}`))
  expect(w.prompts.length).toBe(0)
})

test('git failing to say which checkout the files land in stops the command, never judging the folder alone (#3398 review)', withDeps, async ($, on) => {
  // The repository keeps its working folder in its settings: a folder inside another checkout.
  const tops = { [`${namedAlone} --show-toplevel`]: '/x/sub', '-C /x/sub rev-parse --show-toplevel': { says: denied('/x/sub') }, [`${namedAlone} --absolute-git-dir`]: '/other/.git' }
  const w = world($, on, { open: [rec('them', { cwd: '/x', repoRoot: '/x' })], gits: {}, tops })
  const r = await $.tool.call(bash('git --git-dir=/other/.git checkout main'))
  expect(w.reached).not.toContain('Bash')
  expect(refusal(r)).toBe(couldNotTell(`git did not say which checkout /x/sub is in: ${denied('/x/sub')}`))
  expect(w.prompts.length).toBe(0)
})

test('git failing to say which repository the command names stops it (#3398 review)', withDeps, async ($, on) => {
  const tops = { [`${namedAlone} --show-toplevel`]: '/repo', [`${namedAlone} --absolute-git-dir`]: { says: unanswered } }
  const w = world($, on, { open: byFolder('/other'), gits: { '/other/.git': 'dir' }, tops })
  const r = await $.tool.call(bash('git --git-dir=/other/.git checkout main'))
  expect(w.reached).not.toContain('Bash')
  expect(refusal(r)).toBe(couldNotTell(`git did not say which repository it names: ${unanswered}`))
  expect(w.prompts.length).toBe(0)
})

test("git failing to say whether another session's checkout is the named repository stops the command (#3398 review)", withDeps, async ($, on) => {
  const tops = { [`${namedLinked} --show-toplevel`]: '/repo', [`${namedLinked} --absolute-git-dir`]: '/main/.git/worktrees/w', '-C /wt rev-parse --absolute-git-dir': { says: denied('/wt') } }
  const w = world($, on, { open: [rec('them', { cwd: '/wt', repoRoot: '/wt' })], gits: {}, tops })
  const r = await $.tool.call(bash('git --git-dir=/main/.git/worktrees/w checkout main'))
  expect(w.reached).not.toContain('Bash')
  expect(refusal(r)).toBe(couldNotTell(`git did not say whether /wt is a checkout of the repository it names: ${denied('/wt')}`))
  expect(w.prompts.length).toBe(0)
})

test('the controls: what git says when there is nothing there is still an answer, nobody to ask (#3398 review)', withDeps, async ($, on) => {
  // Each wording measured from git 2.51.1, which exits 128 for all of them: no repository (the
  // world's null), no such folder, and no working folder (a bare repository).
  const gone = (folder: string) => ({ says: `fatal: cannot change to '${folder}': No such file or directory` })
  const tops = {
    '-C /other rev-parse --show-toplevel': gone('/other'),
    '-C sub rev-parse --show-toplevel': null,
    '-C /other/sub rev-parse --show-toplevel': null,
    [`${namedAlone} --show-toplevel`]: { says: 'fatal: this operation must be run in a work tree' },
    [`${namedAlone} --absolute-git-dir`]: null,
    [`${namedLinked} --show-toplevel`]: '/repo',
    [`${namedLinked} --absolute-git-dir`]: '/main/.git/worktrees/w',
    '-C /other rev-parse --absolute-git-dir': gone('/other'),
    '-C /wt rev-parse --absolute-git-dir': null,
  }
  const w = world($, on, { open: [...inOther(), rec('more', { cwd: '/wt', repoRoot: '/wt' })], gits: {}, tops })
  await $.tool.call(bash('cd /other && git checkout main', 'n1'))
  await $.tool.call(bash('git -C /other -C sub checkout main', 'n2'))
  await $.tool.call(bash('git --git-dir=/other/.git checkout main', 'n3'))
  await $.tool.call(bash('git --git-dir=/main/.git/worktrees/w checkout main', 'n4'))
  expect(w.reached).toEqual(['Bash', 'Bash', 'Bash', 'Bash'])
  expect(w.prompts.length).toBe(0)
  expect(w.cards.length).toBe(0)
})

// #1491: from 2.1.307 every plugin's tool.check hook judges a mod's own $.tool.call, the job
// watcher's TaskStop among them, sent with no call id. A stop changes no file, so it is never judged
// here, even with another session's edits on a record that cannot be read and a judge saying Stop.
test("a TaskStop, the job watcher's own with no call id or Claude's with one, goes through unjudged (#1491)", withDeps, async ($, on) => {
  const w = world($, on, { open: [rec('them', { edits: ['/repo/src/a.ts'] })], unreadable: ['/sessions/x.json'], judge: '{"verdict":"Stop","reason":"x"}' })
  const own = (await $.tool.call({ tool: 'TaskStop', task_id: 'b1' } as never)) as { deny?: string; isError?: boolean }
  const claudes = (await $.tool.call({ tool: 'TaskStop', task_id: 'b2', tool_use_id: 'c9' } as never)) as { deny?: string; isError?: boolean }
  expect([own.deny, own.isError, claudes.deny, claudes.isError]).toEqual([undefined, undefined, undefined, undefined])
  expect(w.reached).toEqual(['TaskStop', 'TaskStop'])
  expect(w.prompts.length).toBe(0)
})

test('an ordinary git command is not judged', withDeps, async ($, on) => {
  const w = world($, on, { open: [rec('them')] })
  await $.tool.call(bash('git status'))
  expect(w.reached).toContain('Bash')
  expect(w.prompts.length).toBe(0)
})

// #3021: a command mod-kit marks `unread` (eval, a command a value names, an alias, ssh, a trap whose
// text the shell expands) may switch the branch or write any file, and its words say neither, so the
// guard read it as doing nothing and it ran unjudged beside another session. It is put to the judge
// as a checkout wide git command is, against the checkout it runs in.
const UNREAD_EVAL = 'eval $BUILD_STEP: run as text by eval, so what it runs cannot be read'

test('a command whose effect cannot be read, in a checkout another session works in, is judged, and a Stop blocks it (#3021)', withDeps, async ($, on) => {
  const w = world($, on, { open: [rec('them')], judge: '{"verdict":"Stop","reason":"They are mid rebase."}' })
  const r = await $.tool.call(bash('eval "$BUILD_STEP"'))
  expect(w.reached).not.toContain('Bash')
  expect(w.prompts.length).toBe(1)
  expect(w.prompts[0]?.prompt).toContain(`The action: run a command whose effect cannot be read (${UNREAD_EVAL}) with the shell command: eval "$BUILD_STEP"\n`)
  expect(refusal(r)).toBe('Blocked: Another session is working in this checkout. They are mid rebase. Leave it to the other session, or ask Dan.')
  expect(w.sent[0]?.text).toBe('Another session wanted to run eval $BUILD_STEP in this checkout while you are working in it, so it was stopped. Nothing here was touched.')
})

test('one judged Proceed runs with a toast naming it, and two in one checkout are judged once (#3021)', withDeps, async ($, on) => {
  const w = world($, on, { open: [rec('them')] })
  await $.tool.call(bash('eval "$BUILD_STEP"'))
  expect(w.reached).toEqual(['Bash'])
  expect(w.toasts).toContain('Checked with the other session: safe to run eval $BUILD_STEP.')
  await $.tool.call(bash('eval "$BUILD_STEP" && "$RUNNER" --fix', 'c2'))
  expect(w.prompts.length).toBe(2)
  expect(w.prompts[1]?.prompt).toContain(`The action: run 2 commands whose effect cannot be read (${UNREAD_EVAL}; $RUNNER --fix: named by a value the shell expands, so what it runs cannot be read) with the shell command: `)
  expect(w.toasts).toContain('Checked with the other session: safe to run 2 commands that cannot be read.')
  // What it wrote, if anything, is not known, so nothing is noted as this session's edit.
  expect(w.edits).toEqual([])
})

test('one the judge cannot answer for is stopped (L42, #3021)', withDeps, async ($, on) => {
  const w = world($, on, { open: [rec('them')], judge: 'no-answer' })
  const r = await $.tool.call(bash('eval "$BUILD_STEP"'))
  expect(w.reached).not.toContain('Bash')
  expect(refusal(r)).toBe("Blocked: Couldn't check with the other session's work, so this was stopped. Try again, or ask Dan.")
})

test('one beside a record that cannot be read is stopped and names the record (#3021)', withDeps, async ($, on) => {
  const w = world($, on, { unreadable: ['/sessions/x.json'] })
  const r = await $.tool.call(bash('eval "$BUILD_STEP"'))
  expect(w.reached).not.toContain('Bash')
  expect(refusal(r)).toContain("Couldn't read another session's record (/sessions/x.json)")
})

test('one with nobody else in the checkout runs unjudged (#3021)', withDeps, async ($, on) => {
  const w = world($, on, { open: [rec('elsewhere', { repoRoot: '/other' })] })
  await $.tool.call(bash('eval "$BUILD_STEP"'))
  expect(w.reached).toEqual(['Bash'])
  expect(w.prompts.length).toBe(0)
})

test('a command that can be read and writes nothing is still unjudged beside another session (#3021 control)', withDeps, async ($, on) => {
  const w = world($, on, { open: [rec('them')] })
  await $.tool.call(bash('ls src'))
  expect(w.reached).toEqual(['Bash'])
  expect(w.prompts.length).toBe(0)
})

test("one is judged against the checkout it runs in: the folder a cd before it leads to, or the session's own where that cannot be followed (#3021)", withDeps, async ($, on) => {
  const w = world($, on, { open: [rec('them', { repoRoot: '/other' })], repo: '/other' })
  await $.tool.call(bash('cd /other && eval "$BUILD_STEP"'))
  expect(w.runs).toContain('git -C /other rev-parse --show-toplevel')
  expect(w.prompts.length).toBe(1)
  await $.tool.call(bash('cd "$D" && eval "$BUILD_STEP"', 'c2'))
  expect(w.runs).toContain('git -C /repo rev-parse --show-toplevel')
  expect(w.prompts.length).toBe(2)
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

// #1592: a script file handed a file another session edited ran unjudged, since mod-kit's reader
// gives a script's arguments apart, in `runs` (#1586). Each is judged as an Edit of it is.
test('a script file handed a file another open session edited is judged like an edit, and a Stop blocks it (#1592)', withDeps, async ($, on) => {
  const w = world($, on, { open: [rec('them', { edits: ['/repo/notes.txt'] })], judge: '{"verdict":"Stop","reason":"They are rewriting the notes."}' })
  const r = await $.tool.call(bash('python3 tools/fix.py notes.txt', 'sc1'))
  expect(w.reached).not.toContain('Bash')
  expect(w.prompts[0]?.prompt).toContain('/repo/notes.txt')
  expect(w.prompts[0]?.prompt).toContain('python3 tools/fix.py notes.txt')
  expect(refusal(r)).toBe('Blocked: Another session is working on notes.txt. They are rewriting the notes. Leave it to the other session, or ask Dan.')
  expect(w.cards[0]?.toolUseId).toBe('sc1')
  expect(w.sent[0]?.text).toBe('Another session wanted to edit "notes.txt" while you are working on it, so it was stopped. Nothing here was touched.')
  expect(w.edits).toEqual([])
})

test('a script file handed that file, judged Proceed, runs once with the toast and is noted; handed another file it runs unjudged (#1592)', withDeps, async ($, on) => {
  const w = world($, on, { open: [rec('them', { edits: ['/repo/notes.txt'] })] })
  await $.tool.call(bash('./tidy.sh notes.txt', 'sc2'))
  expect(w.reached).toEqual(['Bash'])
  expect(w.toasts).toContain('Checked with the other session: safe to edit notes.txt.')
  expect(w.edits).toEqual(['/repo/notes.txt'])
  await $.tool.call(bash('python3 tools/fix.py --check other.txt', 'sc3'))
  expect(w.reached).toEqual(['Bash', 'Bash'])
  expect(w.prompts.length).toBe(1)
  expect(w.edits).toEqual(['/repo/notes.txt', '/repo/other.txt'])
})

// #3323 (Dan, 2026-11-21, "Turn it round, with the list (Recommended)"): a program mod-kit's write
// reader does not know was read as writing nothing, so one handed a file another session edited
// ran unjudged. It is now judged as an edit of that file is, the question naming the program.
test('a program the write reader does not know, handed a file another open session edited, is judged, naming the program, and a Stop blocks it (#3323)', withDeps, async ($, on) => {
  const w = world($, on, { open: [rec('them', { edits: ['/repo/notes.txt'] })], judge: '{"verdict":"Stop","reason":"They are rewriting the notes."}' })
  const r = await $.tool.call(bash('prettier --write notes.txt', 'un1'))
  expect(w.reached).not.toContain('Bash')
  expect(w.prompts[0]?.prompt).toContain('hand /repo/notes.txt to prettier (a program the write reader does not know), which may write it, with the shell command: prettier --write notes.txt')
  expect(refusal(r)).toBe('Blocked: Another session is working on notes.txt. They are rewriting the notes. Leave it to the other session, or ask Dan.')
  expect(w.edits).toEqual([])
})

// What such a program is handed is judged and never noted as this session's edit. Most words it is
// handed spell a path without being a file it writes (`gh pr checkout 5` hands pr, checkout and 5 in the
// checkout), a session's edits are capped at twenty, and each one noted is a file another session
// would be asked about. So a real write by such a program is still not recorded as an edit, as it
// was not before. A script handed the file is noted, as it was.
test("such a program judged Proceed runs, and what it was handed is not noted as this session's edit; a program that only reads is neither judged nor noted (#3323)", withDeps, async ($, on) => {
  const w = world($, on, { open: [rec('them', { edits: ['/repo/notes.txt'] })] })
  await $.tool.call(bash('prettier --write notes.txt', 'un2'))
  expect(w.reached).toEqual(['Bash'])
  expect(w.toasts).toContain('Checked with the other session: safe to edit notes.txt.')
  expect(w.prompts.length).toBe(1)
  expect(w.edits).toEqual([])
  await $.tool.call(bash('gh pr checkout 5', 'un3'))
  await $.tool.call(bash('cat notes.txt', 'un4'))
  expect(w.reached).toEqual(['Bash', 'Bash', 'Bash'])
  expect(w.prompts.length).toBe(1)
  expect(w.edits).toEqual([])
  // Handed the same file beside a script that is handed it: an edit, noted.
  await $.tool.call(bash('prettier --check other.txt && ./tidy.sh other.txt', 'un6'))
  expect(w.edits).toEqual(['/repo/other.txt'])
})

// Decided (docs/mods-design.md, #654): a write the command reader cannot see is not guessed at.
test('a script whose own text writes the file, handed it as no argument, is not seen, so it is neither judged nor noted', withDeps, async ($, on) => {
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

// #1136: what git itself changes is judged as a shell write is (Dan, 2026-10-13): a checkout of a
// path or a restore puts back a file another session is editing, git rm or a git mv takes it away.
for (const [command, doing, said] of [
  ['git checkout main -- notes.txt', 'edit', 'write /repo/notes.txt with the shell command: git checkout main -- notes.txt'],
  ['git restore notes.txt', 'edit', 'write /repo/notes.txt with the shell command: git restore notes.txt'],
  ['git rm notes.txt', 'remove', 'remove /repo/notes.txt with the shell command: git rm notes.txt'],
  ['git mv notes.txt docs/old.txt', 'remove', 'remove /repo/notes.txt with the shell command: git mv notes.txt docs/old.txt'],
] as const) {
  test(`${command} on a file another open session edited is judged, and a Stop blocks it`, withDeps, async ($, on) => {
    const w = world($, on, { open: [rec('them', { edits: ['/repo/notes.txt'] })], judge: '{"verdict":"Stop","reason":"They are still writing it."}' })
    const r = await $.tool.call(bash(command, 'g1'))
    expect(w.reached).not.toContain('Bash')
    expect(w.prompts[0]?.prompt).toContain(said)
    expect(refusal(r)).toBe('Blocked: Another session is working on notes.txt. They are still writing it. Leave it to the other session, or ask Dan.')
    expect(w.sent[0]?.text).toBe(`Another session wanted to ${doing} "notes.txt" while you are working on it, so it was stopped. Nothing here was touched.`)
    expect(w.edits).toEqual([])
  })
}

test('git rm -r of a folder holding a file another session edited is judged on that file, and noted once it runs', withDeps, async ($, on) => {
  const w = world($, on, { open: [rec('them', { edits: ['/repo/src/deep/InvoiceTable.tsx'] })] })
  await $.tool.call(bash('git rm -r src'))
  expect(w.prompts[0]?.prompt).toContain('remove /repo/src and everything in it, including /repo/src/deep/InvoiceTable.tsx, with the shell command: git rm -r src')
  expect(w.reached).toContain('Bash')
  expect(w.edits).toEqual(['/repo/src'])
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
const SPACED = `${'/Users'}/dan/Documents/Documents - Dan\u2019s MacBook Pro`

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
  await $.tool.call(bash(`echo a > /tmp/clone/x.txt; echo b > /private/tmp/claude-501/s/scratchpad/700/n.md; echo c > /Volumes/fast/tmp/clone/y.txt; echo d > ${'/Users'}/dan/Desktop/n.txt; echo e >> notes.txt`))
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

// #1299: a call to the session registry's noun that fails for a member an older loaded copy lacks is
// said as the two mods out of step, in the refusal and in the note, never as the raw TypeError.
test('a session registry older than the collision guard is said as out of step, never as a TypeError (#1299)', withOldList, async ($, on) => {
  const w = world($, on)
  const r = await $.tool.call(edit('/repo/src/InvoiceTable.tsx', 'k1'))
  expect(refusal(r)).toContain('collision-guard and session-registry are out of step in this session: the session-registry loaded here has no list')
  expect(refusal(r)).not.toContain('is not a function')
  expect(w.edits).toEqual([])
})

test('a note an older session registry cannot take is said as out of step, never as a TypeError (#1299)', withOldNote, async ($, on) => {
  const v = world($, on)
  const noted = (((await $.tool.call(edit('/repo/src/skewed.ts', 'k2'))) as { context?: string[] }).context ?? []).join(' ')
  expect(noted).toContain('could not record that this session edited /repo/src/skewed.ts: collision-guard and session-registry are out of step in this session: the session-registry loaded here has no noteEdit')
  expect(noted).not.toContain('is not a function')
  expect(v.edits).toEqual([])
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
