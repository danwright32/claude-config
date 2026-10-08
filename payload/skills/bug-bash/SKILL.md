---
name: bug-bash
description: Use when Dan asks for a bug bash, an exploratory test pass, or several AI explorers walking a web project's screens to find bugs before he walks them himself. User invoked only, because it dispatches many paid agents.
disable-model-invocation: true
allowed-tools: Read, Glob, Grep, Bash, Write, Edit, AskUserQuestion, Agent
---

# bug-bash

Explorers find candidates; a failing test decides what is a bug. A finding reaches Dan as a bug only
once a test reproduces it and fails **for the reason the explorer gave**. Everything else is listed
separately, as a risk it could not verify locally or as a rejection with its reason. This is the
reproduce before you fix rule (L681) applied to discovery.

Seeing it yourself is not reproducing it. "I reproduced it twice by hand" is a lead with better
odds, not a confirmed bug: write the test.

## 1. Plan and approval (Dan)

Agree the areas of the app (from its navigation) and the personas below, then state the agent count
(explorers at most 4 at a time, plus one verifier per area) and that every agent run is paid. Get a
go ahead with **AskUserQuestion** before dispatching anything.

Personas, one per explorer charter: a first time visitor; someone checking numbers and copy;
someone typing odd input (emoji, very long, empty, pasted whitespace); someone reloading or going
Back mid flow; someone driving error paths (offline, expired session, double submit).

## 2. Target: a local production build, proved

1. Start the project's local stack the way its own e2e suite does (Slate's `pnpm test:e2e` stack is
   the model): a throwaway database with seed data. Read the env it runs with and confirm no URL or
   key points at production (L719); a dev server wired to production looks like everything working.
2. Build and serve a **production build** on a spare port, never `dev`.
3. Prove it, and stop on any refusal:

       bash ~/.claude/skills/bug-bash/target-guard.sh "<url>"

   It prints `LOCAL <url>`, or refuses a host that is not this machine (real users), a redirect off
   it, or a dev server it recognises (Next.js, Vite and what serves through it, webpack's): a first
   compile reads as a dead link. Against a deployment Dan names, only ever run it with
   `--read-only`, behind the read only proxy, which refuses every request that could change
   something and every WebSocket, outside the browser, and behind the egress rule, which refuses
   every other program on this Mac a connection to the deployment for the length of the run, so a
   browser started some other way cannot reach it either. Start the proxy in the background, in
   the `_bugbash` group the rule lets through and with `--egress`, wait until
   `<run dir>/proxy/proxy.json` exists (it is written once the proxy listens, and removed when it
   stops) and its `pid` is a child of the `sudo` you started (`ps -o ppid= -p <pid>` prints that
   sudo's pid; the pid your shell holds is sudo's, never the proxy's), then pass its `proxy` value:

       sudo -n -g _bugbash "$(command -v node)" ~/.claude/skills/bug-bash/read-only-proxy.js --state "<run dir>/proxy" --egress
       bash ~/.claude/skills/bug-bash/target-guard.sh --read-only --proxy "<proxy>" "<url>"

   The guard refuses (exit 7) unless that proxy answers and refuses a test write, then loads the
   egress rule and refuses (exit 8, naming why) unless it is in force. It prints
   `READ-ONLY <url> via <proxy>`; every explorer then gets `BUG_BASH_PROXY=<proxy>` and launches
   with `readOnly: true`, and every finding is at most a risk. `<run dir>/proxy/requests.log`
   lists what was forwarded and refused. Stop the proxy (the `pid` in proxy.json) when the run
   ends: it takes the egress rule away as it stops. Until then Dan's own browser cannot reach that
   site either (nor, on a shared hosting address, its neighbours there); a rule left by a proxy
   killed outright is removed by the next egress call of any kind.
   If a site ever seems blocked on this Mac, Dan runs `bash ~/.claude/skills/bug-bash/egress.sh status`: it removes a rule whose run has ended and says whether one is still loaded, and for whom.

   The rule needs a one time setup on each Mac, which needs Dan's password and his sign off on
   the sudo grant it adds (claude-config#813). Until that is done the guard refuses every read only
   run against a deployment, so stop and tell him; after it, he runs
   `bash ~/.claude/skills/bug-bash/egress.sh selftest` and the run waits for its `PASS`.

   A local build has no real users, so a read only run against one needs the proxy (started
   plainly, `node ~/.claude/skills/bug-bash/read-only-proxy.js --state "<run dir>/proxy"`) but not
   the rule.

## 3. Explore (at most 4 agents at a time)

Each explorer gets one area, one persona, a charter of five to ten one sentence goals, and its own
output directory `<scratchpad>/bug-bash/<run>/explorer-<n>/`. Tell each explorer:

- Drive a **headless Playwright browser of your own**, from a script you write in your output
  directory, started only through
  `require(process.env.HOME + '/.claude/skills/bug-bash/explorer-browser.js').launch({ chromium, readOnly })`
  with `chromium` from the project's own `node_modules/playwright`. In a read only run it
  refuses to start unless the read only proxy in `BUG_BASH_PROXY` answers, sends everything through
  it, and aborts every request that is not a read before it leaves. A browser launched any other
  way never meets the proxy (against a deployment the egress rule refuses it the site; against a
  local build nothing does), so launch none. Never the Playwright MCP browser (one browser for the whole session; the
  `playwright-subagent-gate` hook refuses it) and never Claude in Chrome (Dan's real browser and
  sign ins). Measured on 2026-10-05: four such browsers launched at once ran in 1.2 to 1.5 s, and a
  cookie set in one was absent from the other three.
- Wait on what the page shows, follow new tabs, and screenshot every finding.
- Return a JSON list: `id`, `area`, `persona`, `title`, steps to reproduce, expected, actual,
  screenshot path.

If the project has no Playwright installed, stop and ask Dan; installing one is his call.

## 4. Merge

Read every explorer's list together. Merge duplicates. Set aside, as `local-setup`, what the seed
data or local stack explains, saying how.

## 5. Verify (one agent per area)

The verifier writes one test per finding in the project's own e2e framework, in a quarantine folder
the merge gate does not run (`<e2e dir>/bug-bash/`, each file naming its finding). Prove the gate
skips it with the runner's own listing (for Playwright, `npx playwright test --list`); if it does
not, add the folder to the gate's ignore setting first. Run each test against the production build:

| Test result | Status |
|---|---|
| fails, and the failure is the explorer's reason | `confirmed`, with `test`, the quoted `failure`, and `reason_match` |
| fails for some other reason | `rejected`, `failed-for-other-reason` |
| passes | `rejected`, `not-reproduced` |
| cannot be exercised locally (a third party, production data) | `unverified`, with `why_unverified` |

Other rejection reasons: `local-setup`, `explorer-artifact` (a new tab, a slow first load),
`works-as-designed`, `duplicate`.

A confirmed bug's test stays in quarantine until its fix lands; the fix's pull request moves it into
the main suite, now passing, as its regression test.

## 6. Report

Report only once every finding has one of the three statuses; a test still running means waiting
for it, never a "pending" line beside the report. Write the run's findings file (shape in `report.py`'s header) with `cost.model_calls` set to the
number of agent runs dispatched (explorers, merge, verifiers), then:

    python3 ~/.claude/skills/bug-bash/report.py "<findings.json>"

It refuses a confirmed finding missing any of its three pieces of evidence, and prints confirmed
bugs, then unverifiable risks, then rejections grouped by reason, then the cost. Give Dan that
report, then offer to file the confirmed bugs as issues (each naming its quarantined test) with
**AskUserQuestion**.

## Rationalizations

| Thought | Reality |
|---|---|
| "I reproduced it by hand, that is enough" | Only a failing test is evidence the next reader can rerun. |
| "The test goes in with the fix" | Write it now, quarantined; the fix may be weeks away. |
| "It runs locally, so it is free" | Every agent run is paid. The report says how many. |
| "The dev server is already up" | Its first compile reads as a dead link. Production build only. |
| "I'll list it as pending and send the rest" | Wait for its test; the report holds only the three statuses. |
| "It probably reproduces in production" | Then it is a risk, not a bug, until a test fails. |
