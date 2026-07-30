---
name: production-ready
description: Audit a project against a broad production-readiness checklist before sharing it — many parallel specialist auditor agents grade security, data/privacy, testing, reliability, observability, deployment, DR, cost, accessibility, and docs; serious findings are adversarially verified; produces a severity-ranked advisory report and, on approval, files prioritized GitHub issues in the audited repo. User-invoked only (spawns many agents).
disable-model-invocation: true
allowed-tools: Read, Glob, Grep, Bash, WebFetch, AskUserQuestion, Workflow, Agent
---

# production-ready

A heavyweight, user-invoked production-readiness auditor. A panel of independent specialist agents each grade one domain against the real codebase; serious gaps are adversarially verified; the result is a severity-ranked **advisory** report (no ship/no-ship gate) that, on your approval, becomes GitHub issues in the audited repo.

Gates marked 👤 require the user before continuing.

## 1. Frame the audit  👤
In conversation with the user, establish:
- The **target project directory** (absolute path, so agents read the right repo).
- The **GitHub repo** (`owner/name`) where issues will be filed (the audited repo).
- Any **known focus or exclusions** (e.g. "skip accessibility, it's an internal API").

Take a quick read of the repo (CLAUDE.md, manifest) so you can confirm the project type you expect. Then present the plan — "I'll run 19 domain auditors in parallel, verify the serious findings, and produce an advisory report" — and get a go-ahead with **AskUserQuestion**. This is heavy and spawns many agents, so confirm before launching.

## 2. Run the audit (Workflow engine)
Call the **Workflow** tool with:

    {
      scriptPath: "/Users/danhankins-wright/.claude/skills/production-ready/production-audit.workflow.js",
      args: {
        projectDir: "<absolute path to the repo>",
        repo: "<owner/name>",
        date: "<today's date YYYY-MM-DD>"
      }
    }

Pass `date` from your own context — the workflow engine cannot read the clock. It returns `{ profile, applicable, naDomains, report }`, where `report = { executiveSummary, whatsSolid, topRisks, severityCounts, backlog }`.

## 3. Save the report
Render a markdown report from the return value (executive summary, what's solid, top risks, severity counts, the N/A domains with reasons, then the full backlog grouped by domain with status/severity/evidence/remediation/effort). Save it to `docs/production-readiness/<date>-report.md` in the **target** repo. Do NOT commit it — tell the user it's there for review.

## 4. Present  👤
Give a plain-language summary for a product manager: how many critical/high/medium/low gaps, what's already solid, the top risks, and any domains skipped as N/A (with why). If the profile suggests grounding was partial (repo unreadable), say so. Advisory only — do not declare anything ship-blocking.

## 5. File issues  👤
Offer, via **AskUserQuestion**, to file the backlog as GitHub issues in the audited repo. On approval:
1. Ensure labels exist (create missing ones), one per domain key, plus the shared priority labels:

       bash ~/.claude/skills/milestone/ensure-priority-labels.sh "<owner/name>"
       gh label create "production-readiness" --color 5319E7 --description "Found by /production-ready" 2>/dev/null || true

   **Do NOT create `severity:*` labels.** They were retired on 2026-07-30: priority is the only urgency scale, and an issue carrying both said the same thing twice. The audit's own severity grading still drives the REPORT; it maps onto the label like this:

   | Audit severity | Label |
   |---|---|
   | critical | `priority-p0` |
   | high | `priority-p1` |
   | medium | `priority-p2` |
   | low | `priority-p3` |

   The scale and the rest of the rules live in `~/.claude/skills/milestone/NAMING.md`.

2. **Resolve the milestone BEFORE filing anything.** Every issue belongs to a milestone, and a gate blocks any `gh issue create` without one. Ask in the SAME AskUserQuestion as the filing approval: attach this backlog to an existing open milestone, or create one (a name like "Production readiness: <repo>" works). Read the open milestones first so the options are real:

       gh api "repos/<owner>/<name>/milestones?state=open&per_page=100" --jq '.[] | "#\(.number) \(.title)"'

   Then resolve it through the shared helper, which reuses a match, refuses to create a near duplicate, and only creates once the user has approved:

       bash ~/.claude/skills/milestone/ensure-milestone.sh "<owner/name>" "<milestone title>"                      # reuse only
       bash ~/.claude/skills/milestone/ensure-milestone.sh "<owner/name>" "<milestone title>" --create-approved    # after approval

   Use the exact title it reports on the `MILESTONE-TITLE` line: `gh` matches milestones by name, so a case variant will not be found.

3. File one issue per backlog item, each assigned to that milestone (group tightly-related items into one issue to avoid spam — especially `low` severity, which you may group by domain). Title = imperative summary; body = the gap, why it matters, the remediation direction, and the `path:line` evidence. Label with `production-readiness`, the matching `severity:*`, and the domain. **Never** apply any Claude/AI-attribution label.

       gh issue create --repo "<owner/name>" --title "<title>" --body "<body>" \
         --milestone "<milestone title>" \
         --label "production-readiness" --label "severity:high"

4. If `gh` is not installed/authenticated or the repo isn't resolvable, skip filing and tell the user — the saved report still captures everything.

## 6. Note on grouping
Milestone grouping now happens up front in step 5, not as an afterthought, so no issue is ever left unattached. If the audit backlog is large enough to deserve phases of its own, `~/.claude/skills/milestone/create-milestone.sh` still files a whole set in one call:

    DRY_RUN=1 bash ~/.claude/skills/milestone/create-milestone.sh "<owner/name>" <plan.json>   # preview
    bash ~/.claude/skills/milestone/create-milestone.sh "<owner/name>" <plan.json>             # create

## Notes
- **Cost is intended.** 19 domain auditors + a profiler + per-finding refute agents + a synthesizer is a lot of subagents per run. That depth is the point; it is why this is user-invoked only.
- **Grounding is mandatory.** Every auditor is told to read real code and cite `path:line`; the verify pass exists to overturn false "missing" findings.
- **First run = the prototype.** Expect to tune severity calibration and domain checklists after the first real audit.
