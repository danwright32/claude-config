// The repositories every mod's reading of a session's repository is pinned on (#951), one table so
// no mod tests its reading against cases another never sees. A mod's tests use a byte for byte copy
// of this file under their tests/mod-kit/tests, held to this one by tools/check-mod-shared-parts.sh.
//
// Each row is a repository as a mod hands it to mod-kit's repo reader (`root`, a checkout folder, and
// `remote`, the origin's address or null) and the two answers the reader gives for it: `github`, the
// GitHub repository as owner/name in the case written (a mod that keys on lower case lowers it
// itself), and `name`, what the repository is called, from the origin on any host, else from the
// checkout. A root from $.session.repo() is the project's main working tree, even for a session in a
// linked worktree (measured on Claude Code 2.1.295, #996: from a worktree under .claude/worktrees, a
// subfolder of one, and one outside the main tree, it named the main tree each time). A worktree's
// own folder comes only from elsewhere, such as $.modkit.branch's `root`; its rows say so.

export type RepoFixture = { why: string; root: string; remote: string | null; github: string | null; name: string | null }

const ROOT = '/Users/x/Apps/folder'
const DOCS = '/Users/x/Documents/Documents - Dan’s MacBook Pro'

export const REPO_FIXTURES: readonly RepoFixture[] = [
  { why: 'ssh, the scp form', root: ROOT, remote: 'git@github.com:danwright32/claude-config.git', github: 'danwright32/claude-config', name: 'claude-config' },
  { why: 'https with .git', root: ROOT, remote: 'https://github.com/danwright32/Overture.git', github: 'danwright32/Overture', name: 'Overture' },
  { why: 'https without .git', root: ROOT, remote: 'https://github.com/danwright32/Overture', github: 'danwright32/Overture', name: 'Overture' },
  { why: 'https with .git and a trailing slash', root: ROOT, remote: 'https://github.com/danwright32/Overture.git/', github: 'danwright32/Overture', name: 'Overture' },
  { why: 'a trailing slash alone', root: ROOT, remote: 'https://github.com/o/r/', github: 'o/r', name: 'r' },
  { why: 'an ssh address', root: ROOT, remote: 'ssh://git@github.com/danwright32/PostRoll.git', github: 'danwright32/PostRoll', name: 'PostRoll' },
  { why: 'an ssh address with a port', root: ROOT, remote: 'ssh://git@github.com:22/danwright32/PostRoll.git', github: 'danwright32/PostRoll', name: 'PostRoll' },
  { why: 'the git protocol', root: ROOT, remote: 'git://github.com/o/r.git', github: 'o/r', name: 'r' },
  { why: 'https with a user', root: ROOT, remote: 'https://dan@github.com/o/r.git', github: 'o/r', name: 'r' },
  { why: 'an owner with a dot in it', root: ROOT, remote: 'git@github.com:my.org/x.git', github: 'my.org/x', name: 'x' },
  { why: 'the host in capitals', root: ROOT, remote: 'https://GitHub.com/o/r.git', github: 'o/r', name: 'r' },
  { why: 'the www host', root: ROOT, remote: 'https://www.github.com/o/r', github: 'o/r', name: 'r' },
  { why: 'the scp form with no user', root: ROOT, remote: 'github.com:o/r.git', github: 'o/r', name: 'r' },
  { why: 'a trailing new line', root: ROOT, remote: 'git@github.com:o/r.git\n', github: 'o/r', name: 'r' },
  { why: 'another host over https', root: ROOT, remote: 'https://gitlab.com/team/thing.git', github: null, name: 'thing' },
  { why: 'another host over ssh, with a port and subgroups', root: ROOT, remote: 'ssh://git@gitlab.example.com:2222/team/Sub/Thing.git', github: null, name: 'Thing' },
  { why: 'a host that only ends in github.com', root: ROOT, remote: 'git@evilgithub.com:o/r.git', github: null, name: 'r' },
  { why: 'a host that only starts with github.com', root: ROOT, remote: 'git@github.com.evil.io:o/r.git', github: null, name: 'r' },
  { why: 'more than owner and name on GitHub', root: ROOT, remote: 'git@github.com:o/r/extra.git', github: null, name: 'extra' },
  { why: 'a local path', root: ROOT, remote: '/srv/git/thing.git', github: null, name: 'thing' },
  { why: 'a local path with spaces and a curly apostrophe', root: ROOT, remote: `${DOCS}/Repos/Bidspoke.git`, github: null, name: 'Bidspoke' },
  { why: 'a local checkout by its .git folder', root: ROOT, remote: '/srv/repo/.git', github: null, name: 'repo' },
  { why: 'a file address', root: ROOT, remote: 'file:///srv/git/thing.git', github: null, name: 'thing' },
  { why: 'owner/name alone, which git reads as a relative path', root: ROOT, remote: 'o/r', github: null, name: 'r' },
  { why: 'github.com/o/r with no scheme, which git reads as a relative path', root: ROOT, remote: 'github.com/o/r', github: null, name: 'r' },
  { why: 'no origin: the checkout folder', root: '/Users/x/Apps/Overture', remote: null, github: null, name: 'Overture' },
  { why: 'an empty origin: the checkout folder', root: '/Users/x/Apps/Overture', remote: '', github: null, name: 'Overture' },
  { why: "a session in a linked worktree, as $.session.repo() gives it: the main working tree", root: '/Users/x/Apps/claude-config', remote: null, github: null, name: 'claude-config' },
  { why: "a session in a linked worktree under spaces and a curly apostrophe, as $.session.repo() gives it", root: `${DOCS}/Bidspoke`, remote: null, github: null, name: 'Bidspoke' },
  { why: "a worktree's own folder (never from $.session.repo()) names its parent", root: '/Users/x/Apps/claude-config/.claude/worktrees/agent-ac031537', remote: null, github: null, name: 'claude-config' },
  { why: "a worktree's own folder with a trailing slash", root: '/Users/x/Apps/claude-config/.claude/worktrees/issue-945/', remote: null, github: null, name: 'claude-config' },
  { why: "a worktree's own folder under spaces and a curly apostrophe", root: `${DOCS}/Bidspoke/.claude/worktrees/agent-1`, remote: null, github: null, name: 'Bidspoke' },
  { why: 'the origin wins over the folder', root: '/Users/x/Apps/old-folder-name', remote: 'git@github.com:danwright32/PostRoll.git', github: 'danwright32/PostRoll', name: 'PostRoll' },
  { why: "the origin wins over a worktree's own folder", root: '/Users/x/Apps/claude-config/.claude/worktrees/agent-1', remote: 'git@github.com:danwright32/claude-config.git', github: 'danwright32/claude-config', name: 'claude-config' },
]
