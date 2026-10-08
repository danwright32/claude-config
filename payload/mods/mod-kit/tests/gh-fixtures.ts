// The spellings every reading of a repository outside a git remote is pinned on (#961), one table
// so no mod tests its reading against cases another never sees. A mod's tests use a byte for byte
// copy of this file under their tests/mod-kit/tests, held to this one by
// tools/check-mod-shared-parts.sh.
//
// GH_REPO_FIXTURES: a repository as gh reads one (-R, GH_REPO, a `gh repo` positional, an
// endpoint's owner/name), where owner/name alone IS a repository, and the answer mod-kit's ghRepo
// gives, as owner/name in lower case, or null for none.
//
// LINK_FIXTURES: a github.com link (a pull request's, an issue's, the repository's own page) and the
// repository mod-kit's linkRepo reads it as, as owner/name the link spells it, or null for none.

export type GhRepoFixture = { why: string; spelling: string; repo: string | null }
export type LinkFixture = { why: string; link: string; repo: string | null }

export const GH_REPO_FIXTURES: readonly GhRepoFixture[] = [
  { why: 'owner/name alone', spelling: 'o/r', repo: 'o/r' },
  { why: 'owner/name in capitals', spelling: 'O/R', repo: 'o/r' },
  { why: 'an owner with a dot in it', spelling: 'my.org/x', repo: 'my.org/x' },
  { why: 'owner/name with .git', spelling: 'o/r.git', repo: 'o/r' },
  { why: 'owner/name with a trailing slash', spelling: 'o/r/', repo: 'o/r' },
  { why: 'spaces around it', spelling: '  o/r  ', repo: 'o/r' },
  { why: 'github.com before it, with no scheme', spelling: 'github.com/o/r', repo: 'o/r' },
  { why: 'the www host before it, with no scheme', spelling: 'www.github.com/o/r', repo: 'o/r' },
  { why: 'the host and the name in capitals, with no scheme', spelling: 'GitHub.com/O/R', repo: 'o/r' },
  { why: 'another host before it', spelling: 'ghe.example.com/o/r', repo: null },
  { why: 'github.com before an owner alone', spelling: 'github.com/o', repo: null },
  { why: 'https', spelling: 'https://github.com/Other/X', repo: 'other/x' },
  { why: 'https with .git', spelling: 'https://github.com/o/r.git', repo: 'o/r' },
  { why: 'https with .git and a trailing slash', spelling: 'https://github.com/o/r.git/', repo: 'o/r' },
  { why: 'http', spelling: 'http://github.com/o/r', repo: 'o/r' },
  { why: 'https with a user and a password', spelling: 'https://user:pw@github.com/o/r', repo: 'o/r' },
  { why: 'https on the www host', spelling: 'https://www.github.com/o/r', repo: 'o/r' },
  { why: 'the scheme and the host in capitals', spelling: 'HTTPS://GITHUB.COM/o/r', repo: 'o/r' },
  { why: 'https with a port', spelling: 'https://github.com:443/o/r', repo: 'o/r' },
  { why: 'ssh, the scp form', spelling: 'git@github.com:o/r.git', repo: 'o/r' },
  { why: 'an ssh address', spelling: 'ssh://git@github.com/o/r', repo: 'o/r' },
  { why: 'an ssh address with a port', spelling: 'ssh://git@github.com:22/o/r', repo: 'o/r' },
  { why: 'the git protocol', spelling: 'git://github.com/o/r', repo: 'o/r' },
  { why: 'the scp form with no user, which gh does not read as an address', spelling: 'github.com:o/r', repo: null },
  { why: 'the scp form with another user, which gh does not read as an address either', spelling: 'dan@github.com:o/r', repo: null },
  { why: '.git in capitals on an address', spelling: 'https://github.com/o/r.GIT', repo: 'o/r' },
  { why: 'another host over https', spelling: 'https://gitlab.com/o/r', repo: null },
  { why: 'a host that only ends in github.com', spelling: 'git@evilgithub.com:o/r.git', repo: null },
  { why: 'a host that only starts with github.com', spelling: 'git@github.com.evil.io:o/r.git', repo: null },
  { why: 'more than owner and name', spelling: 'a/b/c', repo: null },
  { why: 'more than owner and name on GitHub', spelling: 'git@github.com:o/r/extra.git', repo: null },
  { why: 'an owner alone on GitHub', spelling: 'https://github.com/o', repo: null },
  { why: 'a name alone', spelling: 'r', repo: null },
  { why: 'nothing', spelling: '', repo: null },
  { why: 'a file address', spelling: 'file:///srv/o/r', repo: null },
  { why: 'a relative path', spelling: './o/r', repo: null },
  { why: "gh api's placeholders", spelling: '{owner}/{repo}', repo: null },
  { why: 'a space in the name', spelling: 'o/r r', repo: null },
]

export const LINK_FIXTURES: readonly LinkFixture[] = [
  { why: 'a pull request', link: 'https://github.com/o/r/pull/5', repo: 'o/r' },
  { why: 'in the case the link spells it', link: 'https://github.com/Owner/Repo/pull/5', repo: 'Owner/Repo' },
  { why: 'an owner with a dot in it', link: 'https://github.com/my.org/x/pull/12', repo: 'my.org/x' },
  { why: "a pull request's tab", link: 'https://github.com/o/r/pull/5/files', repo: 'o/r' },
  { why: 'a trailing slash', link: 'https://github.com/o/r/pull/5/', repo: 'o/r' },
  { why: 'a comment anchor', link: 'https://github.com/o/r/pull/5#discussion_r1', repo: 'o/r' },
  { why: 'a query', link: 'https://github.com/o/r/pull/5?w=1', repo: 'o/r' },
  { why: 'the scheme and the host in capitals', link: 'HTTPS://GITHUB.COM/o/r/pull/5', repo: 'o/r' },
  { why: 'the www host', link: 'https://www.github.com/o/r/pull/5', repo: 'o/r' },
  { why: 'http', link: 'http://github.com/o/r/pull/5', repo: 'o/r' },
  { why: 'no scheme', link: 'github.com/o/r/pull/5', repo: 'o/r' },
  { why: 'an issue', link: 'https://github.com/o/r/issues/9', repo: 'o/r' },
  { why: "the repository's own page", link: 'https://github.com/o/r', repo: 'o/r' },
  { why: 'a host that only ends in github.com', link: 'https://evilgithub.com/o/r/pull/5', repo: null },
  { why: 'a host that only starts with github.com', link: 'https://github.com.evil.io/o/r/pull/5', repo: null },
  { why: 'an owner alone', link: 'https://github.com/o', repo: null },
  { why: 'a trailing new line', link: 'https://github.com/o/r/pull/5\n', repo: null },
  { why: 'a space before it', link: ' https://github.com/o/r/pull/5', repo: null },
  { why: 'a port', link: 'https://github.com:443/o/r/pull/5', repo: null },
  { why: 'a user', link: 'https://dan@github.com/o/r/pull/5', repo: null },
  { why: 'a space in the owner', link: 'https://github.com/o r/x/pull/5', repo: null },
  { why: 'nothing', link: '', repo: null },
]
