---
name: audit-sessions
description: Audit recent Claude Code sessions for recurring friction with parallel sub-agents, cluster the findings across projects, and propose fixes (new skills, hooks, CLAUDE.md rules) as a picker. Use when the user asks to audit their sessions, find where they keep hitting friction, or review how Claude Code has been working for them. Trigger, /audit-sessions [days]
---

# audit-sessions

Turns two weeks of transcripts into a ranked list of friction clusters and a picker of concrete fixes. First run: 2026-07-02 (found the "what's next" loop, the SQL relay, and the test-gate bounce; shipped /next-issue, /db-apply, hook tuning). Rerun monthly-ish or after workflow changes.

## 1. Extract (script, no agents)

Run the bundled condenser. Default window 14 days; take an override from the invocation args:

    python3 ~/.claude/skills/audit-sessions/extract_friction.py --days 14 --out <scratchpad>/audit

It auto-discovers project transcript dirs (skipping tmp and worktree noise, and any project with fewer than 3 sessions in the window) and writes one `friction_<project>.txt` per project: USER messages, INTERRUPT markers, SLASH commands, and tool-error signatures per session. Report the per-project stats line to the user before fanning out.

## 2. Fan out (one agent per project, in parallel, single message)

For each friction file, launch one general-purpose agent. Prompt essentials (keep all of these):
- Context: Dan is a product manager who does not write code; all code is written by Claude.
- Read the whole file in chunks (offset/limit).
- Hunt: interruptions and what he said right after; corrections and frustration ("no", "again", "still", "you didn't", "I already told you"); the same multi-step routine requested repeatedly; recurring tool-error signatures; preference violations (dashes, missing pickers, paid options); failed deploy/build/test loops.
- Return ONLY a markdown report: ranked friction themes (frequency, 2 to 4 verbatim dated quotes, root-cause category, one-line remedy type), then recurring routines (slash-command candidates), then what is working well (do not break).

## 3. Cluster across projects

Merge the reports yourself (no extra agent needed). Group recurring friction into named clusters ranked by total frequency and cost. Distinguish: behavior that a CLAUDE.md rule fixes, a routine that a skill automates, a defect that a hook or script fixes, and one-off noise (drop it). Check each cluster against the current CLAUDE.md and hooks first: do not propose a rule that already exists; propose why it is not landing instead.

## 4. Deliver and act

Report to the user: clusters ranked with evidence counts and a plain-language explanation, what is working well, then proposed fixes (all free unless something paid is clearly better, presented as a choice). End with an AskUserQuestion multi-select picker of the top 4 fixes. Implement what gets selected (test-first for any code, including hook scripts: see `test-stop-hooks.sh` and `test-require-tests-before-push.sh` in `~/.claude/hooks/` for the harness pattern). Save the outcome to project memory: clusters found, fixes shipped, fixes pending.
