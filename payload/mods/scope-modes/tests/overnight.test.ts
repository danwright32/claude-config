import { describe, expect, test } from 'claude-code/testing'
import type { Cmd } from '../hooks/nobuild.ts'
import { NEVER_ASKED, normRepo, overnightRefusal, primaryFrom, repoFromRemotes, type Look } from '../hooks/overnight.ts'
import { git, pipeline } from './mod-kit/hooks/commands.ts'
import { commandWrites } from './mod-kit/hooks/writes.ts'

// Sleep mode phase 3 (#834): what is refused overnight, by effect and by the repository a call
// reaches. Commands are read by mod-kit's own reader (its byte for byte copy under tests/mod-kit),
// as the mod reads them, so a quoted separator is read as it is in a session (#730). The disk's
// answers (which repository a folder's remotes name, whether a folder is a primary checkout) come
// from a stand in Look, so each case says what the disk holds.
const HOME = '/Users/x'
const CWD = '/Users/x/repo'
const REPOS: Record<string, string> = { '/Users/x/repo': 'o/r', '/Users/x/wt': 'o/r', '/Users/x/theirs': 'other/x' }
const PRIMARY: Record<string, boolean> = { '/Users/x/repo': true, '/Users/x/wt': false, '/Users/x/theirs': true }
const under = <T>(map: Record<string, T>, dir: string): T | null => {
  for (const [k, v] of Object.entries(map)) if (dir === k || dir.startsWith(`${k}/`)) return v
  return null
}
const look: Look = { repoOf: async dir => under(REPOS, dir), isPrimary: async dir => under(PRIMARY, dir) }

const cmds = (command: string): Cmd[] =>
  pipeline(command).map(c => {
    const g = git(c.words)
    return g ? { ...c, git: { sub: g.sub, args: g.args, dir: g.dir } } : c
  })
const bash = (command: string, o: { cwd?: string; ghRepo?: string; look?: Look } = {}) =>
  overnightRefusal({ tool: 'Bash', input: { command }, raw: command, commands: cmds(command), writes: commandWrites(command, o.cwd ?? CWD, HOME), cwd: o.cwd ?? CWD, home: HOME, ghRepo: o.ghRepo }, o.look ?? look)
const NONE = { files: [], changes: [], unnamed: [] }
const tool = (name: string, input: Record<string, unknown>) => overnightRefusal({ tool: name, input, raw: '', commands: [], writes: NONE, cwd: CWD, home: HOME }, look)

describe('ordinary overnight work is not on the list, so it goes ahead', () => {
  test('building, testing, committing, pushing a branch and opening a PR', async () => {
    for (const c of [
      'npm test 2>&1 | tail -20',
      'git status && git log --oneline -5 && git branch --show-current',
      'git add payload/a.ts && git commit -F /tmp/m.txt',
      'git push -u origin sleep-834',
      'git rebase origin/main',
      'gh pr create --title "x" --body-file /tmp/b.md',
      'gh pr view 5 --json state && gh issue view 834 --comments && gh issue list --limit 50',
      'gh api repos/o/r/pulls/5',
      `gh api graphql -f query='query { viewer { login } }'`,
      'gh pr merge 5 --squash',
      'claude-sync status',
      `psql -c 'select 1'`,
      'cat payload/LESSONS.md && grep -n L174 ~/.claude/LESSONS.md',
      'git commit -m "say LESSONS.md in a message"',
    ])
      expect({ c, r: await bash(c) }).toEqual({ c, r: undefined })
  })
  test('a branch checked out in a linked worktree, and a file put back in the primary one', async () => {
    expect(await bash('git checkout -b sleep-834', { cwd: '/Users/x/wt' })).toBeUndefined()
    expect(await bash('git switch main', { cwd: '/Users/x/wt' })).toBeUndefined()
    expect(await bash('git checkout -- payload/a.ts')).toBeUndefined()
  })
  test('editing code, and tools nobody listed', async () => {
    expect(await tool('Edit', { file_path: '/Users/x/repo/payload/a.ts' })).toBeUndefined()
    expect(await tool('mcp__playwright__browser_click', { element: 'x' })).toBeUndefined()
    expect(await tool('WebFetch', { url: 'https://example.com' })).toBeUndefined()
  })
})

describe('issue, label and milestone writes', () => {
  test('every gh issue and gh label write is refused', async () => {
    expect(await bash('gh issue create --title x --body y')).toBe('run gh issue create')
    expect(await bash('gh issue edit 5 --add-label priority-p1')).toBe('run gh issue edit')
    expect(await bash('gh issue close 5')).toBe('run gh issue close')
    expect(await bash('gh issue delete 5 --yes')).toBe('run gh issue delete')
    expect(await bash('gh label create sleep')).toBe('run gh label create')
  })
  test('labels and milestones set on a PR are refused', async () => {
    expect(await bash('gh pr edit 5 --add-label bug')).toBe('set labels or a milestone on a PR')
    expect(await bash('gh pr edit 5 --milestone "Sleep mode"')).toBe('set labels or a milestone on a PR')
    expect(await bash('gh pr create --title x --label=bug')).toBe('set labels or a milestone on a PR')
    expect(await bash('gh pr edit 5 --title y')).toBeUndefined()
  })
  test('the same writes through gh api, REST or GraphQL', async () => {
    expect(await bash('gh api -X POST repos/o/r/milestones -f title=x')).toBe('change issues, labels or milestones through the GitHub API')
    expect(await bash('gh api repos/o/r/issues -f title=x')).toBe('change issues, labels or milestones through the GitHub API')
    expect(await bash('gh api -X PATCH repos/o/r/issues/5 -f state=closed')).toBe('change issues, labels or milestones through the GitHub API')
    expect(await bash(`gh api graphql -f query='mutation { createIssue(input: {}) { issue { id } } }'`)).toBe('call the GitHub API to run createIssue')
    expect(await bash('gh api graphql --input q.json')).toBe('call the GitHub API with a GraphQL document that could not be read')
  })
})

describe('gh overnight: a short list of reads anywhere, a short list of writes on this repository, nothing else', () => {
  const other = 'write to other/x from a checkout of o/r'
  const unresolved = 'write to GitHub where the repository it reaches could not be resolved'
  test('a write not on the list is refused even on this repository (#834 review of 3f7151c)', async () => {
    expect(await bash('gh repo delete --yes')).toBe('run gh repo delete')
    expect(await bash('gh repo delete o/r --yes')).toBe('run gh repo delete')
    expect(await bash('gh release delete v1 -y')).toBe('run gh release delete')
    expect(await bash('gh release create v1')).toBe('run gh release create')
    expect(await bash('gh secret set TOKEN --body x')).toBe('run gh secret set')
    expect(await bash('gh workflow run deploy.yml')).toBe('run gh workflow run')
    expect(await bash('gh run rerun 5')).toBe('run gh run rerun')
    expect(await bash('gh pr close 5')).toBe('run gh pr close')
    expect(await bash('gh pr review 5 --approve')).toBe('run gh pr review')
    expect(await bash('gh gist create notes.md')).toBe('run gh gist create')
    expect(await bash('gh frobnicate now')).toBe('run gh frobnicate now')
    expect(await bash('gh api -X POST repos/o/r/pulls -f title=x')).toBe('call the GitHub API to POST repos/o/r/pulls')
    expect(await bash('gh api -X PUT repos/o/r/pulls/5/merge')).toBe('call the GitHub API to PUT repos/o/r/pulls/5/merge')
    expect(await bash('gh api -X POST user/repos -f name=x')).toBe('call the GitHub API to POST user/repos')
  })
  test('a listed write may carry only the flags its job needs', async () => {
    expect(await bash('gh pr edit 5 --title y --body z')).toBeUndefined()
    expect(await bash('gh pr edit 5 --base other')).toBe('run gh pr edit with --base')
    expect(await bash('gh pr edit 5 --add-reviewer x')).toBe('run gh pr edit with --add-reviewer')
    expect(await bash('gh pr ready 5')).toBeUndefined()
    expect(await bash('gh pr ready 5 --undo')).toBe('run gh pr ready with --undo')
  })
  test('the listed writes go ahead on this repository and are refused on another', async () => {
    expect(await bash('gh pr create --title x --body-file /tmp/b.md')).toBeUndefined()
    expect(await bash('gh pr merge 5 --squash')).toBeUndefined()
    expect(await bash('gh pr ready https://github.com/other/x/pull/5')).toBe(other)
    expect(await bash('gh pr merge https://github.com/other/x/pull/5 --squash')).toBe(other)
    expect(await bash('gh pr create -R other/x --title x --body y')).toBe(other)
  })
  test('every spelling gh accepts is read the same (ghargs.ts)', async () => {
    expect(await bash('gh api --method=DELETE repos/o/r/git/refs/heads/x')).toBe('delete a branch')
    expect(await bash('gh api -XDELETE repos/o/r/git/refs/heads/x')).toBe('delete a branch')
    expect(await bash('gh api -XPOST repos/other/x/issues/5/comments -fbody=x')).toBe(other)
    expect(await bash('gh pr comment 5 -Rother/x -b hi')).toBe(other)
    expect(await bash('gh pr comment 5 --repo=other/x -b hi')).toBe(other)
    expect(await bash('gh pr comment 5 -R my.org/x -b hi')).toBe('write to my.org/x from a checkout of o/r')
    expect(await bash('gh pr merge 5 -sd')).toBe('delete a branch')
    expect(await bash('gh pr close 5 -d')).toBe('delete a branch')
    // Global flags before the subcommand (#834 review of 8bbd403).
    expect(await bash('gh -R other/x pr merge 5')).toBe(other)
    expect(await bash('gh --repo=other/x pr merge 3')).toBe(other)
    expect(await bash('gh --frob x pr merge 5')).toBe(unresolved)
    // A flag between the subcommand and its action cannot pass its value off as a read action.
    expect(await bash('gh pr --body view close 5 -R other/x')).toBe(unresolved)
    expect(await bash('gh issue --title list create')).toBe(unresolved)
    // GH_REPO set through env reaches gh too.
    expect(await bash('env GH_REPO=other/x gh issue comment 5 --body x')).toBe(unresolved)
  })
  test('a gh write reached through a wrapper, or with a GH_ variable set, cannot be resolved; a read still can (#834 review of af10401)', async () => {
    for (const c of [
      'env gh pr merge 5',
      'command gh pr merge 5',
      'nohup gh pr merge 5',
      'echo 5 | xargs gh pr merge',
      `bash -c 'gh pr merge 5'`,
      `sh -c "gh pr merge 5"`,
      `eval "gh pr merge 5"`,
      `source <(echo gh pr merge 5)`,
      'time gh pr merge 5',
      'sudo gh pr merge 5',
      'GH_TOKEN=abc gh pr merge 5',
      'GH_HOST=example.com gh pr merge 5',
    ])
      expect({ c, r: await bash(c) }).toEqual({ c, r: unresolved })
    expect(await bash('env gh pr view 5')).toBeUndefined()
    expect(await bash(`bash -c 'gh issue list'`)).toBeUndefined()
    // gh named only inside a message is no gh call.
    expect(await bash('git commit -m "read the gh reply"')).toBeUndefined()
  })
  test('a merge may carry only its method, subject and --auto; --admin is refused (#834 review of 1b556d3)', async () => {
    expect(await bash('gh pr merge 5 --squash --subject x --body y')).toBeUndefined()
    expect(await bash('gh pr merge 5 --squash --admin')).toBe('run gh pr merge with --admin')
    expect(await bash('gh pr merge 5 --auto --squash')).toBeUndefined()
    expect(await bash('gh pr create --title x --body y --base main --head b --draft')).toBeUndefined()
    expect(await bash('gh pr create --title x --body y --reviewer someone')).toBe('run gh pr create with --reviewer')
  })
  test('gh run by any wrapper the reader does not look past is refused (#834 review of 46f07ff)', async () => {
    expect(await bash('setsid gh issue comment 5 --body x')).toBe(unresolved)
    expect(await bash('stdbuf -o0 gh pr merge 5 --squash')).toBe(unresolved)
    expect(await bash('chronic /opt/homebrew/bin/gh pr merge 5')).toBe(unresolved)
    expect(await bash('timeout 30 gh pr merge 5')).toBe(unresolved)
    expect(await bash('frobwrap --quiet gh issue comment 5 --body x')).toBe(unresolved)
    expect(await bash('frobwrap 5 gh pr merge 5')).toBe(unresolved)
    // Saying the word inside quotes is not running it.
    expect(await bash('echo "gh is slow today"')).toBeUndefined()
    // Finding where gh is runs nothing (#834 review of 00abaed).
    expect(await bash('which gh && command -v gh && type gh')).toBeUndefined()
    // A file that happens to be named gh is not the gh program.
    expect(await bash('cat ./gh && ls bin/gh && chmod +x scripts/gh')).toBeUndefined()
    expect(await bash('nohupish /opt/homebrew/bin/gh pr merge 5')).toBe(unresolved)
  })
  test('code the reader cannot read, or that runs gh, git or a database itself, is refused (#834 review of 46f07ff)', async () => {
    expect(await bash(`python3 -c "import subprocess; subprocess.run(['gh', 'pr', 'close', '5'])"`)).toBe('run code that runs gh, git or a database client, which cannot be judged')
    expect(await bash(`node -e "eval(process.argv[1])" x`)).toMatch(/^run code (this reader cannot read|that runs)/)
    expect(await bash(`python3 -c "print(1 + 1)"`)).toBeUndefined()
  })
  test('any GH_ variable set before gh cannot be resolved (#834 review of 1b556d3)', async () => {
    expect(await bash('GH_CONFIG_DIR=/tmp/other gh pr merge 5 --squash')).toBe(unresolved)
    expect(await bash('GH_PATH=/x gh issue comment 5 --body y')).toBe(unresolved)
  })
  test('gh in command position after a shell keyword or an assignment is gh run directly (#834 review of 98a40f1)', async () => {
    expect(await bash('if gh pr view 5; then gh pr merge 5 --squash; fi')).toBeUndefined()
    expect(await bash('while ! gh pr checks 5; do sleep 30; done; gh pr merge 5 --squash')).toBeUndefined()
    expect(await bash('PAGER=cat gh pr merge 5 --squash')).toBeUndefined()
  })
  test('quoted text and a heredoc body are never judged as commands (#834 review of 3f7151c)', async () => {
    expect(await bash('gh issue comment 834 --body "see env gh pr close"')).toBeUndefined()
    expect(await bash(`gh issue comment 834 --body 'nohup gh was wrong, GH_TOKEN too'`)).toBeUndefined()
    expect(await bash(`gh issue comment 834 -F - <<'EOF'\nsudo gh pr close 5\nEOF`)).toBeUndefined()
  })
  test('a body that begins with a dash, or read from standard input, is still a comment on this repository', async () => {
    expect(await bash(`gh issue comment 834 --body '- fixed the parser'`)).toBeUndefined()
    expect(await bash('gh issue comment 834 --body-file -')).toBeUndefined()
    expect(await bash('gh pr create --title x -F -')).toBeUndefined()
  })
  test('a gh api call to another GitHub host cannot be resolved', async () => {
    expect(await bash('gh api --hostname ghe.example.com -X POST repos/o/r/issues/5/comments -f body=x')).toBe(unresolved)
    expect(await bash('gh api --hostname github.com repos/o/r/issues/5/comments -X POST -f body=x')).toBeUndefined()
  })
  test('a review through the API is refused as gh pr review is; a PR comment through the API goes ahead (#834 review of f0c7cdc)', async () => {
    expect(await bash('gh api repos/o/r/pulls/5/reviews -f event=APPROVE')).toBe('call the GitHub API to POST repos/o/r/pulls/5/reviews')
    expect(await bash('gh api repos/o/r/pulls/5/comments -f body=x -f commit_id=abc -f path=a.ts -F line=3')).toBeUndefined()
  })
  test('editing or deleting a comment is refused outright', async () => {
    expect(await bash('gh issue comment 5 --delete-last --yes')).toBe('edit or delete a comment')
    expect(await bash('gh pr comment 5 --edit-last --body x')).toBe('edit or delete a comment')
  })
  test('a known read goes ahead on any repository', async () => {
    expect(await bash('gh pr view 5 -R other/x')).toBeUndefined()
    expect(await bash('gh -R other/x pr view 5')).toBeUndefined()
    expect(await bash('gh issue list -R other/x')).toBeUndefined()
    expect(await bash('gh pr diff 5 -R other/x && gh pr checks 5 -R other/x && gh run view 1 -R other/x --log')).toBeUndefined()
    expect(await bash('gh api repos/other/x/pulls')).toBeUndefined()
    expect(await bash('gh search issues sleep --owner other')).toBeUndefined()
    expect(await bash('gh label list')).toBeUndefined()
  })
  test('every GraphQL mutation is refused, by its exact name', async () => {
    expect(await bash(`gh api graphql -f query='mutation { refreshThing(input: {}) { ok } }'`)).toBe('call the GitHub API to run refreshThing')
    expect(await bash(`gh api graphql -f query='mutation { addComment(input: {}) { clientMutationId } }'`)).toBe('call the GitHub API to run addComment')
    expect(await bash(`gh api graphql -f query='mutation { addLabelsToLabelable(input: {}) { clientMutationId } }'`)).toBe('call the GitHub API to run addLabelsToLabelable')
  })
})

describe('comments go only to the repository the checkout is', () => {
  test('a comment on this repository goes ahead', async () => {
    expect(await bash('gh issue comment 834 --body "parked: needs a decision"')).toBeUndefined()
    expect(await bash('gh pr comment 5 -R o/r --body x')).toBeUndefined()
    expect(await bash('gh issue comment https://github.com/o/r/issues/834 --body x')).toBeUndefined()
    expect(await bash('gh api repos/o/r/issues/834/comments -f body=x')).toBeUndefined()
    expect(await bash('gh api repos/{owner}/{repo}/issues/834/comments -f body=x')).toBeUndefined()
    expect(await bash('cd /Users/x/wt && gh issue comment 834 --body x', { cwd: '/tmp' })).toBeUndefined()
  })
  test('a comment on another repository is refused', async () => {
    expect(await bash('gh issue comment 5 -R other/x --body x')).toBe('write to other/x from a checkout of o/r')
    expect(await bash('gh pr comment https://github.com/other/x/pull/3 --body x')).toBe('write to other/x from a checkout of o/r')
    expect(await bash('gh api repos/other/x/issues/5/comments -f body=x')).toBe('write to other/x from a checkout of o/r')
    expect(await bash('gh issue comment 5 --body x', { ghRepo: 'other/x' })).toBe('write to other/x from a checkout of o/r')
  })
  test('a comment whose repository cannot be resolved is refused (L75)', async () => {
    const unresolved = 'write to GitHub where the repository it reaches could not be resolved'
    expect(await bash('GH_REPO=other/x gh issue comment 5 --body x')).toBe(unresolved)
    expect(await bash('gh issue comment 5 --body x', { cwd: '/tmp' })).toBe(unresolved)
    expect(await bash('cd "$DIR" && gh issue comment 5 --body x')).toBe(unresolved)
    expect(await bash('gh issue comment 5 --body x', { look: { ...look, repoOf: async () => null } })).toBe(unresolved)
  })
})

describe('LESSONS.md, written by any route in command position (L673)', () => {
  test('an edit tool, a redirect, sed, a copy, a removal, git putting it back, inline code', async () => {
    expect(await tool('Edit', { file_path: '/Users/x/repo/payload/LESSONS.md' })).toBe('write to LESSONS.md')
    expect(await tool('Write', { file_path: '/Users/x/.claude/lessons.md' })).toBe('write to LESSONS.md')
    for (const c of [
      'echo "- L999. x" >> payload/LESSONS.md',
      `sed -i '' 's/a/b/' payload/LESSONS.md`,
      'cp /tmp/l.md ~/.claude/LESSONS.md',
      'ln -sf /tmp/l.md payload/LESSONS.md',
      'git mv notes.md payload/LESSONS.md',
      'mv /tmp/l.md payload/LESSONS.md',
      'echo x | tee -a payload/LESSONS.md',
      'rm payload/LESSONS.md',
      'git checkout HEAD~1 -- payload/LESSONS.md',
      `python3 -c "open('payload/LESSONS.md', 'a').write('x')"`,
    ])
      expect({ c, r: await bash(c) }).toEqual({ c, r: 'write to LESSONS.md' })
  })
})

describe('outward tools: every write under claude.ai, Chrome and PostHog, and database writes', () => {
  test('a write is refused, a read goes ahead', async () => {
    expect(await tool('mcp__claude_ai_Slack__slack_send_message', { text: 'x' })).toBe('use mcp__claude_ai_Slack__slack_send_message')
    expect(await tool('mcp__claude_ai_Slack__slack_read_channel', {})).toBeUndefined()
    expect(await tool('mcp__claude_ai_Google_Calendar__create_event', {})).toBe('use mcp__claude_ai_Google_Calendar__create_event')
    expect(await tool('mcp__claude_ai_SFDC_USE__updateSobjectRecord', {})).toBe('use mcp__claude_ai_SFDC_USE__updateSobjectRecord')
    expect(await tool('mcp__claude_ai_SFDC_-_Read_Only__soqlQuery', {})).toBeUndefined()
    expect(await tool('mcp__claude-in-chrome__navigate', { url: 'https://x' })).toBe('use mcp__claude-in-chrome__navigate')
    expect(await tool('mcp__claude-in-chrome__read_page', {})).toBeUndefined()
    expect(await tool('mcp__posthog__exec', { command: 'x' })).toBe('use mcp__posthog__exec')
    // A name that says neither is refused: only a name that reads is let through.
    expect(await tool('mcp__claude_ai_Google_Calendar__suggest_time', {})).toBe('use mcp__claude_ai_Google_Calendar__suggest_time')
  })
  test('Supabase and psql by the SQL they run', async () => {
    expect(await tool('mcp__claude_ai_Supabase__execute_sql', { query: 'select 1' })).toBeUndefined()
    expect(await tool('mcp__claude_ai_Supabase__execute_sql', { query: 'delete from t' })).toMatch(/delete|change/i)
    expect(await tool('mcp__claude_ai_Supabase__apply_migration', { query: 'x' })).toBe('apply_migration')
    expect(await tool('mcp__claude_ai_Supabase__list_tables', {})).toBeUndefined()
    expect(await tool('Skill', { skill: 'db-apply' })).toBe('run the db-apply skill')
    expect(await bash(`psql "$DATABASE_URL" -c 'update t set a = 1'`)).toMatch(/update|change/i)
    expect(await bash('supabase db push')).toBe('change a database with supabase')
    // One list of database clients for no build and overnight (L370), sqlite3 included.
    expect(await bash(`sqlite3 data.db 'delete from t'`)).toMatch(/delete|change/i)
    expect(await bash(`sqlite3 data.db 'select 1'`)).toBeUndefined()
  })
})

describe('the checkout, force pushes, branch deletes and the live config', () => {
  test('a branch checkout or switch in a primary checkout is refused (H7)', async () => {
    expect(await bash('git checkout main')).toBe('run git checkout in a primary checkout')
    expect(await bash('git switch -c x')).toBe('run git switch in a primary checkout')
    expect(await bash('git -C /Users/x/repo checkout main', { cwd: '/Users/x/wt' })).toBe('run git checkout in a primary checkout')
    expect(await bash('cd /Users/x/repo && git checkout -b x', { cwd: '/Users/x/wt' })).toBe('run git checkout in a primary checkout')
    expect(await bash('git checkout -- .')).toBe('run git checkout in a primary checkout')
  })
  test('one whose checkout cannot be told is refused', async () => {
    expect(await bash('git checkout main', { cwd: '/tmp/somewhere' })).toBe('run git checkout where it could not be told whether this is a primary checkout')
  })
  test('force pushes', async () => {
    for (const c of ['git push --force', 'git push -f origin x', 'git push -uf origin x', 'git push --force-with-lease origin x', 'git push origin +x', 'git push origin HEAD:+main', 'git push origin --force-with-lease=x:abc x', 'git push --force-if-includes --force-with-lease origin x', 'git push -fu origin x', 'git push --mirror', 'git push --forc origin x', 'git push --force-with origin x', 'git push --mirr'])
      expect({ c, r: await bash(c) }).toEqual({ c, r: 'force push' })
    expect(await bash('git push --follow-tags origin x')).toBeUndefined()
  })
  test('branch deletes, locally, on GitHub and through a merge', async () => {
    for (const c of ['git push origin --delete x', 'git push origin :x', 'git push -d origin x', 'git branch -D x', 'git branch -d x', 'git branch --del x', 'git push origin --dele x', 'gh pr merge 5 --squash --delete-branch', 'gh pr merge 5 -sd', 'gh api -X DELETE repos/o/r/git/refs/heads/x', 'git update-ref -d refs/heads/x'])
      expect({ c, r: await bash(c) }).toEqual({ c, r: 'delete a branch' })
    expect(await bash('gh api -X PATCH repos/o/r/git/refs/heads/x -F force=true -f sha=abc')).toBe('force push')
  })
  test('claude-sync pull and install, by any path to it', async () => {
    expect(await bash('claude-sync pull')).toBe('run claude-sync pull')
    expect(await bash('~/claude-config-sync/claude-sync install-autosync')).toBe('run claude-sync install-autosync')
    expect(await bash('bash ~/claude-config-sync/claude-sync sync')).toBe('run claude-sync sync')
  })
})

describe('what is never approved, and the disk readers', () => {
  test('a question and the plan approval are never approved overnight (H8)', () => {
    expect([...NEVER_ASKED].sort()).toEqual(['AskUserQuestion', 'ExitPlanMode'])
  })
  test('normRepo reads every spelling of a GitHub repository', () => {
    expect(normRepo('O/R')).toBe('o/r')
    expect(normRepo('github.com/o/r')).toBe('o/r')
    expect(normRepo('https://github.com/o/r.git')).toBe('o/r')
    expect(normRepo('git@github.com:o/r.git')).toBe('o/r')
    expect(normRepo('ssh://git@github.com/o/r')).toBe('o/r')
    expect(normRepo('https://gitlab.com/o/r')).toBeNull()
    expect(normRepo('r')).toBeNull()
  })
  test('one GitHub repository across the remotes, or none said', () => {
    expect(repoFromRemotes('origin\tgit@github.com:o/r.git (fetch)\norigin\tgit@github.com:o/r.git (push)\n')).toBe('o/r')
    // A fork's upstream is where gh may send a comment, so two repositories cannot be resolved.
    expect(repoFromRemotes('origin\tgit@github.com:o/r.git (fetch)\nupstream\thttps://github.com/other/x (fetch)\n')).toBeNull()
    expect(repoFromRemotes('')).toBeNull()
  })
  test('a primary checkout has its git folder and its common one the same', () => {
    expect(primaryFrom('/Users/x/repo/.git\n/Users/x/repo/.git\n')).toBe(true)
    expect(primaryFrom('/Users/x/repo/.git/worktrees/wt\n/Users/x/repo/.git\n')).toBe(false)
    expect(primaryFrom('')).toBeNull()
  })
})
