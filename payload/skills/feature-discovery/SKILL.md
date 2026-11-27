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
7. **Discovery**: How will users find or learn about this feature? Where the project announces to agents, also ask Dan whether this feature is announced (below).
8. **Opportunity cost**: What happens if we do not build it?
9. **Alternatives**: Is there a simpler solution? Can we solve it without a new feature?
10. **Edge cases**: Empty states, large datasets, permissions, errors, concurrent edits, offline, other unusual conditions.
11. **Risks**: Technical, product, security, privacy, performance, scalability.
12. **Dependencies**: Existing systems affected: APIs, database, auth, billing, notifications, analytics.
13. **Non-functional requirements**: Performance, reliability, accessibility, security, compliance, localization, observability.
14. **Instrumentation**: What events to track? What dashboards or alerts do we need?
15. **Assumptions**: What are we assuming? How can we validate it?
16. **Unknowns**: What questions are still unanswered?

### Item 7, where the project announces to agents: ask whether this feature is announced

Some work apps post a change to their agents in an announcements channel, under the
`changelog/announce` label, when agents must or can act differently because of it. Whether a
feature is announced is Dan's decision, made here (his words, 2026-11-25: "it should ask me before
applying the label. It can be part of the new feature discovery"). The wording of the post is a
separate approval, asked at pull request time.

Find out whether the project announces: `node ~/.claude/hooks/lib/dev-update-registry.js
announce-channel <owner/name>` prints a `channel` when its entry in this Mac's dev update registry
names one. With no channel, do not ask, and say nothing about announcing.

With a channel, ask Dan with ONE AskUserQuestion picker of one question, in the main session:

- the question: `Will "<feature name>" be announced to agents when it ships? The test: agents must or can act differently.`
- the options: `Announce it` and `Not announcing`
- the metadata: `{"source": "announce-discovery", "repo": "<owner/name>", "feature": "<feature name>"}`

The question must name the feature in the very words of the metadata's `feature`, and must hold the
words `agents must or can act differently`: without both, his answer does not count. Neither does
an answer he typed words beside, which is a change he wants: read it and ask again. Name the feature
in the picker exactly as its milestone will be titled (a few words, no punctuation; letter case and
spacing aside): his answer counts for a milestone only under that one name, and the plan has no
second place to give another. If the title changes after he answered, he is asked again under the
new title.

His answer goes into the plan the milestone is made from, as `"announce": "yes"` or
`"announce": "no"` (`~/.claude/skills/milestone/SKILL.md`, step 2). The milestone helper takes
either only as his own answer to this picker, and the pull request that finishes a feature he said
yes to cannot merge under another label unless he declines in a picker.

## After shared understanding

Once you and the user share a clear picture of the feature, continue down the normal
pipeline rather than building ad hoc. First, where it applies, offer a picture of the parts.

### Offer a picture of the parts

When the feature has two or more moving parts that hand data to each other (screens, services,
jobs, stores, outside systems), offer Dan a simple diagram of those parts and the data passing
between them, before the hand off below. Ask with an AskUserQuestion picker, and draw it only when
Dan says yes. Skip the offer when the feature has one moving part.

Show it as a published artifact with the Artifact tool, loading the artifact-diagramming skill first,
never only as a file or a file card in the chat, which Dan cannot see. Keep it small: one box per
part and one labelled arrow per flow of data, named in Dan's words rather than the code's. If
drawing it shows a part or a flow the interview never covered, ask about it before moving on.

### Write down what must always be true

Before the hand off, write the feature's `Must always be true` list and ask Dan to approve it. The
list's rules, and what each line of it says, live in one place,
`~/.claude/skills/milestone/MUST-ALWAYS-BE-TRUE.md`: read it and follow it, never a shape remembered
from an earlier plan. The approved list goes into the design and the plan unchanged.

### Then hand off

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
