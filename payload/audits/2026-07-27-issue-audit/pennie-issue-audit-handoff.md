# Handoff: Pennie-side issue triage for the global guidelines audit

## Context (read first)

Dan is mining every GitHub issue he has ever filed (open and closed, across all his
projects) for recurring root causes, to synthesize new global "how Claude Code should
build" guidelines. All code in these repos was written by Claude Code; Dan writes no code.

The personal-side repos (overture, playedit, nursedex, PostRoll, downbeat: 1,739 issues)
are already triaged on his other Mac. THIS machine's job is only the work-side repos,
because only this machine has GitHub access to them. The output file you produce will be
carried back to the other Mac and merged into the cross-project synthesis there.

## Repos to triage

1. Try-Pennie/slate
2. Try-Pennie/project-enrollment-tracker
3. Try-Pennie/bidspoke
4. dwright-pennie/new-agent-onboarding
5. The "Manager Goal Tracking" project, if it has a repo: search all accessible repos
   for names matching goal, track, tracking, or manager. If nothing matches, record
   "no repo found" in the output and move on. Ask Dan only if you find more than one
   plausible match.

## Ground rules

1. Read-only with respect to GitHub: never comment on, edit, label, close, or create
   issues anywhere during this task.
2. Never run `gh auth switch`. If more than one account is logged in, scope every call
   instead: `GH_TOKEN=$(gh auth token -u <account>) gh ...` using whichever account can
   see the Try-Pennie org (check with `gh auth status`).
3. Writing style for everything you produce: no em dashes, no en dashes, no hyphens used
   as sentence connectors or parenthetical breaks (hyphens inside words are fine), no
   emoji. Use commas, colons, parentheses, or separate sentences.

## Step 1: inventory (metadata only)

For each repo, download every issue's metadata and verify nothing was truncated:

```
gh issue list -R <owner>/<repo> --state all --limit 5000 --json number,title,state,createdAt,closedAt,labels > <repo>.json
```

Then compare `jq length` of the file against GitHub's own total:

```
gh api "search/issues?q=repo:<owner>/<repo>+type:issue" --jq .total_count
```

If the numbers disagree, paginate until they match before proceeding. Note that
`gh issue list` excludes pull requests, and PRs share the issue numbering, so the top
issue number being higher than the count is normal.

## Step 2: triage each repo (parallel agents are fine, one per repo)

Classify every issue from its title and labels into:

1. LESSON candidate: a defect, bug, regression, wrong assumption, silent failure,
   misdesign, or process failure that teaches something about how Claude should have
   built it.
2. FEATURE: new functionality, enhancement, plan or milestone record.
3. CHORE: cleanup, docs, dependency bumps.
4. UNCLEAR.

For promising but ambiguous titles, fetch the body and comments (the comments often hold
the real diagnosis):

```
gh issue view <number> -R <owner>/<repo> --json body,comments
```

Deep read up to about 40 issues per repo, prioritizing likely lessons.

For every LESSON issue, assign a root-cause family: a short kebab-case tag you invent and
reuse consistently. Examples of the granularity wanted: silent-failure-swallowed-error,
guessed-api-or-schema, untested-failure-path, stale-build-tested, concurrency-not-idempotent,
wrong-file-edited, false-green-test, missing-auth-scoping, platform-limit-ignored.
Then write a one-sentence lesson phrased as a forward-looking build-time rule, not a
description of the bug.

## Step 3: output

Produce ONE file, `pennie-triage.md`, saved somewhere easy for Dan to grab (his Desktop
is fine, tell him exactly where). Structure:

1. A header listing the repos covered and the date.
2. One section per repo: counts (total / lesson / feature / chore / unclear), then one
   subsection per root-cause family sorted by issue count descending, each listing its
   issue numbers with the one-line lesson per issue (a shared lesson line is fine when
   several issues teach the same thing). Prefix issue numbers with the repo name so they
   stay unambiguous after merging (for example slate#123).
3. A final short section: the 5 to 10 root-cause families that recur most across these
   repos, with one example lesson each.

## Step 4: hand back

Tell Dan the file is ready and where it is. He will carry it to the other Mac (AirDrop or
iCloud, his choice) and drop it into the session running the synthesis there. Do not
attempt to push it to GitHub or any external service.
