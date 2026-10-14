// The commands that merge, or look as though they might, through the GitHub API, and every merge route
// behind each word that only runs the command after it (claude-config#1181).
//
// Two recognisers answer "does this command merge a pull request": the overnight judge here
// (mergedeploy.ts, actsOf) and the daytime merge gates (payload/hooks/lib/merge-target.sh,
// mt_runs_merge, which block-red-merge.sh, pr-review-gate.sh and require-changelog-tag.sh ask). They
// are written in two languages and read the shell through two readers, so they cannot share code;
// they share this table instead. mergedeploy.test.ts holds the mod to `merge` on every row, and
// payload/hooks/test-merge-target.sh holds the gates to `gates` where a row has one and to `merge`
// where it does not, so a change to either recogniser that the other does not make fails a suite
// (L450, L582). The gates' suite reads each row as JSON, so every row stays on ONE line, written
// with double quotes, and no row ever spans two.
//
// `gates` is written only where the two answers differ ON PURPOSE, and `why` says what the purpose
// is. Any row without it is a route both must judge alike.
//
// A word in front of gh that only runs it (rtk, env with its options and NAME=value settings, sudo
// with its options) is read by each side's own shell reader before either recogniser sees the
// command, so the table carries each of those wrappers in front of each route (gh pr merge, the REST
// merge endpoint, a GraphQL merge mutation): writing it found the two readers disagreeing in both
// directions (the mod's did not read rtk, which rtk-rewrite.sh writes in front of every gh command;
// the gates' did not read env or sudo), and Dan folded the fix into #1181.
//
// gh reads a flag of the subcommand written BEFORE it (`gh -R acme/widget pr merge 7`, `gh -X PUT api
// ...`), because its command library finds the subcommand by passing over the flags first and then
// hands every flag to that subcommand (measured on gh 2.89.0, 2026-10-14). The rows from #1186 carry
// each spelling of the repository flag in that place, behind each wrapper, on both routes that take
// a repository from it. Before #1186 the gates read none of them as a merge, so a merge with the flag
// in front went past all three unjudged.
//
// `repo`, where a row has it, is the repository both must say the merge is about, as owner/name in
// lower case, or null for one that cannot be told, which both refuse rather than judge the checkout's
// pull request in its place (L75). The mod reads it as each merge act's repo; the gates' suite as
// mt_repo_flag, and null as mt_api_merge_untold refusing. A row leaves it out where the mod refuses
// every flag it cannot read in front of a subcommand and the gates read that flag as gh does.

export type ApiMergeCase = { command: string; merge: boolean; gates?: boolean; why?: string; repo?: string | null }

export const API_MERGE_CASES: ApiMergeCase[] = [
  {"command": "gh api -X PUT repos/acme/widget/pulls/7/merge", "merge": true},
  {"command": "gh api --method PUT repos/acme/widget/pulls/7/merge -f merge_method=squash", "merge": true},
  {"command": "gh api -X put /repos/acme/widget/pulls/7/merge", "merge": true},
  {"command": "gh api -XPUT repos/acme/widget/pulls/7/merge", "merge": true},
  {"command": "gh api --method=PUT https://api.github.com/repos/acme/widget/pulls/7/merge", "merge": true},
  {"command": "gh api repos/acme/widget/pulls/7/merge -X PUT -f sha=a1b2c3d4", "merge": true},
  {"command": "gh api repos/acme/widget/pulls/7/merge -f merge_method=squash", "merge": true},
  {"command": "gh api -X PUT repos/{owner}/{repo}/pulls/7/merge", "merge": true},
  {"command": "GH_TOKEN=abc gh api -X PUT repos/acme/widget/pulls/7/merge", "merge": true},
  {"command": "cd /tmp && gh api -X PUT repos/acme/widget/pulls/7/merge", "merge": true},
  {"command": "gh api graphql -f query='mutation { mergePullRequest(input: {pullRequestId: \"PR_kwDOA1\"}) { clientMutationId } }'", "merge": true},
  {"command": "gh api graphql -f query='mutation($id: ID!) { mergePullRequest(input: {pullRequestId: $id, mergeMethod: SQUASH}) { clientMutationId } }' -f id=PR_kwDOA1", "merge": true},
  {"command": "gh api graphql -f query='mutation { m: mergePullRequest(input: {pullRequestId: \"PR_kwDOA1\"}) { clientMutationId } }'", "merge": true},
  {"command": "gh api graphql -f query='mutation { enablePullRequestAutoMerge(input: {pullRequestId: \"PR_kwDOA1\"}) { clientMutationId } }'", "merge": true},
  {"command": "gh api graphql -f query='mutation { enqueuePullRequest(input: {pullRequestId: \"PR_kwDOA1\"}) { clientMutationId } }'", "merge": true},
  {"command": "gh api graphql -F query=@merge.graphql", "merge": true},
  {"command": "gh api graphql -F query=@q.graphql", "merge": true, "gates": false, "why": "the gates look further only at a command naming a merge, which this one does not, and the document it sends is in a file neither can read; the mod judges a night with nobody watching and refuses every document it cannot read"},
  {"command": "gh api -X PUT repos/acme/widget/merges -f base=main -f head=fix", "merge": true, "gates": false, "why": "merges one branch into another with no pull request, so there is no pull request whose checks, review or changelog record a gate could read"},
  {"command": "gh api graphql -f query='mutation { mergeBranch(input: {repositoryId: \"R_1\", base: \"main\", head: \"fix\"}) { clientMutationId } }'", "merge": true, "gates": false, "why": "merges one branch into another with no pull request, so there is no pull request whose checks, review or changelog record a gate could read"},
  {"command": "gh api repos/acme/widget/pulls/7/merge", "merge": false},
  {"command": "gh api -X GET repos/acme/widget/pulls/7/merge", "merge": false},
  {"command": "gh api -X PUT repos/acme/widget/pulls/7", "merge": false},
  {"command": "gh api -X PATCH repos/acme/widget/pulls/7 -f title=merge", "merge": false},
  {"command": "gh api graphql -f query='query { repository(owner: \"acme\", name: \"widget\") { pullRequest(number: 7) { mergeable } } }'", "merge": false},
  {"command": "gh api graphql -f query='mutation { addComment(input: {subjectId: \"PR_kwDOA1\", body: \"merge soon\"}) { clientMutationId } }'", "merge": false},
  {"command": "echo 'gh api -X PUT repos/acme/widget/pulls/7/merge'", "merge": false},
  {"command": "rtk gh pr merge 7 --squash", "merge": true},
  {"command": "rtk gh api -X PUT repos/acme/widget/pulls/7/merge", "merge": true},
  {"command": "rtk gh api graphql -f query='mutation { mergePullRequest(input: {pullRequestId: \"PR_kwDOA1\"}) { clientMutationId } }'", "merge": true},
  {"command": "env GH_TOKEN=abc gh pr merge 7 --squash", "merge": true},
  {"command": "env GH_TOKEN=abc gh api -X PUT repos/acme/widget/pulls/7/merge", "merge": true},
  {"command": "env GH_TOKEN=abc gh api graphql -f query='mutation { mergePullRequest(input: {pullRequestId: \"PR_kwDOA1\"}) { clientMutationId } }'", "merge": true},
  {"command": "env -u GH_HOST GH_TOKEN=abc gh pr merge 7 --squash", "merge": true},
  {"command": "env -u GH_HOST GH_TOKEN=abc gh api -X PUT repos/acme/widget/pulls/7/merge", "merge": true},
  {"command": "env -u GH_HOST GH_TOKEN=abc gh api graphql -f query='mutation { mergePullRequest(input: {pullRequestId: \"PR_kwDOA1\"}) { clientMutationId } }'", "merge": true},
  {"command": "sudo gh pr merge 7 --squash", "merge": true},
  {"command": "sudo gh api -X PUT repos/acme/widget/pulls/7/merge", "merge": true},
  {"command": "sudo gh api graphql -f query='mutation { mergePullRequest(input: {pullRequestId: \"PR_kwDOA1\"}) { clientMutationId } }'", "merge": true},
  {"command": "sudo -u dan -E gh pr merge 7 --squash", "merge": true},
  {"command": "sudo -u dan -E gh api -X PUT repos/acme/widget/pulls/7/merge", "merge": true},
  {"command": "sudo -u dan -E gh api graphql -f query='mutation { mergePullRequest(input: {pullRequestId: \"PR_kwDOA1\"}) { clientMutationId } }'", "merge": true},
  {"command": "sudo env GH_TOKEN=abc rtk gh pr merge 7 --squash", "merge": true},
  {"command": "sudo env GH_TOKEN=abc rtk gh api -X PUT repos/acme/widget/pulls/7/merge", "merge": true},
  {"command": "sudo env GH_TOKEN=abc rtk gh api graphql -f query='mutation { mergePullRequest(input: {pullRequestId: \"PR_kwDOA1\"}) { clientMutationId } }'", "merge": true},
  {"command": "rtk gh pr view 7 --json mergeable", "merge": false},
  {"command": "env GH_TOKEN=abc gh api repos/acme/widget/pulls/7/merge", "merge": false},
  {"command": "sudo -u dan gh api -X PUT repos/acme/widget/pulls/7 -f title=merge", "merge": false},
  {"command": "env GH_TOKEN=abc echo gh pr merge 7", "merge": false},
  {"command": "gh -R acme/widget pr merge 7 --squash", "merge": true, "repo": "acme/widget"},
  {"command": "gh --repo acme/widget pr merge 7 --squash", "merge": true, "repo": "acme/widget"},
  {"command": "gh --repo=acme/widget pr merge 7 --squash", "merge": true, "repo": "acme/widget"},
  {"command": "gh -Racme/widget pr merge 7 --squash", "merge": true, "repo": "acme/widget"},
  {"command": "gh -R Acme/Widget pr merge 7 --squash", "merge": true, "repo": "acme/widget"},
  {"command": "gh -R https://github.com/acme/widget pr merge 7 --squash", "merge": true, "repo": "acme/widget"},
  {"command": "gh -R acme/other pr merge 7 --repo acme/widget", "merge": true, "repo": "acme/widget"},
  {"command": "gh pr merge 7 -sR acme/widget", "merge": true, "repo": "acme/widget"},
  {"command": "gh pr merge 7 -sdRacme/widget", "merge": true, "repo": "acme/widget"},
  {"command": "gh pr -R acme/widget merge 7 --squash", "merge": true},
  {"command": "gh -R acme/widget api -X PUT 'repos/{owner}/{repo}/pulls/7/merge'", "merge": true, "repo": "acme/widget"},
  {"command": "gh --repo=acme/widget api -X PUT repos/acme/widget/pulls/7/merge", "merge": true, "repo": "acme/widget"},
  {"command": "gh -R acme/widget api graphql -f query='mutation { mergePullRequest(input: {pullRequestId: \"PR_kwDOA1\"}) { clientMutationId } }'", "merge": true},
  {"command": "gh -X PUT api repos/acme/widget/pulls/7/merge", "merge": true},
  {"command": "rtk gh -R acme/widget pr merge 7 --squash", "merge": true, "repo": "acme/widget"},
  {"command": "rtk gh --repo=acme/widget api -X PUT 'repos/{owner}/{repo}/pulls/7/merge'", "merge": true, "repo": "acme/widget"},
  {"command": "env GH_TOKEN=abc gh --repo acme/widget pr merge 7 --squash", "merge": true, "repo": "acme/widget"},
  {"command": "env -u GH_HOST GH_TOKEN=abc gh -R acme/widget api -X PUT 'repos/{owner}/{repo}/pulls/7/merge'", "merge": true, "repo": "acme/widget"},
  {"command": "sudo gh -Racme/widget pr merge 7 --squash", "merge": true, "repo": "acme/widget"},
  {"command": "sudo -u dan -E gh --repo=acme/widget pr merge 7 --squash", "merge": true, "repo": "acme/widget"},
  {"command": "sudo env GH_TOKEN=abc rtk gh -R acme/widget pr merge 7 --squash", "merge": true, "repo": "acme/widget"},
  {"command": "sudo env GH_TOKEN=abc rtk gh -R acme/widget api -X PUT 'repos/{owner}/{repo}/pulls/7/merge'", "merge": true, "repo": "acme/widget"},
  {"command": "gh -R nonsense pr merge 7 --squash", "merge": true, "repo": null},
  {"command": "gh --repo=a/b/c/d pr merge 7 --squash", "merge": true, "repo": null},
  {"command": "gh pr merge 7 --squash -R", "merge": true, "repo": null},
  {"command": "env GH_TOKEN=abc gh -R nonsense pr merge 7 --squash", "merge": true, "repo": null},
  {"command": "gh -R nonsense api -X PUT 'repos/{owner}/{repo}/pulls/7/merge'", "merge": true, "repo": null},
  {"command": "gh -R acme/widget pr view 7 --json mergeable", "merge": false},
  {"command": "rtk gh --repo=acme/widget api repos/acme/widget/pulls/7/merge", "merge": false},
  {"command": "gh -R pr merge 7", "merge": false},
  {"command": "gh --squash pr merge 7", "merge": true, "gates": false, "why": "gh reads a flag it does not know in front of a subcommand as taking the next word, so it takes pr as the value of --squash, looks for a command named merge, has none, and runs nothing (measured on gh 2.89.0); the gates read it as gh does, and the mod refuses every flag in front of a subcommand that it does not know"},
]
