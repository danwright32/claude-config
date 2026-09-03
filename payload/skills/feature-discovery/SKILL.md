---
name: feature-discovery
description: Use when the user starts discussing, proposing, scoping, or asking to build a NEW feature, before any planning or implementation. Runs a clarifying interview so both the user and Claude fully understand the feature first.
---

# Feature Discovery

Before planning or building any new feature, make sure both you and the user fully
understand it. Do not jump to a plan or to code. Interview first.

## How to run it

Conduct the interview by invoking the **`grilling`** skill. That skill owns the
cadence: one question at a time, recommend an answer for each, explore the codebase
to answer a question yourself rather than asking when you can.

The list below is the **starting agenda**, not a script. It is a general checklist
the user sketched out, not the complete set of questions for any given feature.
Treat it as a floor:

- Skip items that are already answered or clearly irrelevant to this feature.
- Go beyond it. Generate feature-specific questions that this general list does not
  cover. The most valuable questions are usually the ones unique to this feature.

### Starting agenda

1. **Problem**: What problem are we solving? Who experiences it? How do we know it is real?
2. **User**, Who is this for? How many are affected? Who does not need this?
3. **Outcome**: What business or user outcome are we trying to achieve? How does it improve the product?
4. **Priority**: Why now? Why is this more important than other work?
5. **MVP**: What is the smallest version we could build to validate the idea?
6. **Success**: How will we measure success? What metrics or KPIs tell us it worked?
7. **Discovery**: How will users find or learn about this feature?
8. **Opportunity cost**: What happens if we do not build it?
9. **Alternatives**: Is there a simpler solution? Can we solve it without a new feature?
10. **Edge cases**: Empty states, large datasets, permissions, errors, concurrent edits, offline, other unusual conditions.
11. **Risks**: Technical, product, security, privacy, performance, scalability.
12. **Dependencies**: Existing systems affected: APIs, database, auth, billing, notifications, analytics.
13. **Non-functional requirements**: Performance, reliability, accessibility, security, compliance, localization, observability.
14. **Instrumentation**: What events to track? What dashboards or alerts do we need?
15. **Assumptions**: What are we assuming? How can we validate it?
16. **Unknowns**: What questions are still unanswered?

## After shared understanding

Once you and the user share a clear picture of the feature, continue down the normal
pipeline rather than building ad hoc:

- Hand off to `superpowers:brainstorming` to turn the understanding into a design,
  then `superpowers:writing-plans` for the implementation plan.
- For a large, ambiguous, or architectural feature, suggest the user run `/plan-lite`
  or `/plan-council` (user-invoked).

## When you start building

Apply these before writing new code:

1. **Standard library first**: Can this be solved using the language's standard library? If yes, use it.
2. **Existing dependency second**: Is there an existing, reliable dependency already in the project that does this? If yes, use it. Do not add a new one.

Also follow the project's standing rules (CLAUDE.md): consolidate instead of
duplicating logic, prefer the correct and robust approach over the fast one, default
to the cheapest approach that does the job, and write a failing test before the
implementation.
