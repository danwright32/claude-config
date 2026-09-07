---
name: writing-prds
description: Use when Dan asks for a PRD, product brief, or requirements document, or wants to "plan out" a new product or feature from source materials (call transcripts, decks, recordings, prototypes), before any build planning or code. Also use when reviewing or revising an existing PRD.
---

# Writing PRDs

## Overview

A PRD's job is to align the people deciding and the people building on the problem, the success measure, and what is settled versus proposed. The document is right when it is in the shape of the problem, not the shape of the request that asked for it.

**The Iron Rule: no drafting before the interview.** A PRD written straight from the request will be full of invented decisions that read as settled. Every unsettled decision an author invents forecloses the real conversation it was supposed to trigger.

## Process (in order, no skipping)

1. **Ingest every source completely.** Read all provided materials (transcripts, decks, recordings, prototypes, linked repos) before forming a view. For a recording, extract and view frames; for a repo, read its docs. Then play back your understanding and have Dan confirm or correct it before anything else.
2. **Invite the brain dump.** Ask Dan to dump everything in his head, unstructured: what he privately thinks it's for, stakeholder noise, worries, constraints, what he knows about the users. Never start from a clean, organized prompt; a clean prompt produces a document in the prompt's shape.
3. **Report gaps before asking questions.** After the dump, state plainly: "here is what is genuinely unresolved" (the uncomfortable specifics, not "define your metrics").
4. **Interview one question at a time** via AskUserQuestion pickers, each with a recommended answer first. Required questions, beyond whatever is feature-specific:
   1. "What is the ONE thing that must be true for this to be a success?" If Dan cannot answer, he is not ready to write the PRD, and that is the finding.
   2. If the product claims to improve anything: "what is the baseline, and how is it captured?"
   3. Who is the design-center user when decisions conflict.
   4. For every contested or consequential decision: whose sign-off does it need, by name.
5. **Stress-test the problem statement.** Before drafting, check it for solution language (a problem section that names the feature is a feature brief) and for unverifiable claims.
6. **Draft to the output spec below**, then deliver as a file plus a shareable artifact, and end with the list of what needs whose sign-off. Circulate for reaction, not approval.
7. **Settle the visual identity before the first screen is built.** Once the PRD is agreed and the main screen's content is known, the first build task is a design round, not code. Not earlier: there is nothing to draw before the PRD says what is on the screen. Not later: once a screen exists in the real framework every round costs a rebuild instead of an edit, and the question quietly changes from what this should look like to what is cheap to change now. Run it as the section below describes and treat its result as a settled artifact, not a sketch.
8. **Keep it alive.** When Dan corrects any point, update every place it appears (sections cross-reference each other), fix all cross-reference numbers if items are added or removed, re-verify the numbering, and re-publish the same artifact URL. A PRD that diverges from the current understanding is worse than none.

## Output spec

The finished PRD has these parts, in this order, and these properties:

1. **Header:** title, "Status: Draft for review by [named person]", date, author Dan.
2. **Problem.** Problem language only, with observable symptoms (numbered), and the domain insight in the domain owner's framing with attribution. No feature names here.
3. **What this product is.** A few sentences plus its major halves. Names what already exists (a prototype, a spreadsheet) and what this adds.
4. **Who it is for.** Numbered users with the design center first, each with what they get; ends with who it is NOT for.
5. **What success must look like.** ONE primary measure first, explicitly ranked seconds, the baseline requirement, and slow business metrics marked as directional rather than pass/fail. Every number in this section (and anywhere) comes from a source or from Dan; a number nobody stated is written as TBD with an open question, never invented.
6. **The model.** Enumerate concretely what the product must deliver or what mastery/completeness means (skills, capabilities, requirements), each one verifiable. This list is what reporting and grading key against.
7. **How it works, at the product level.** Modes and flows only; no schemas, stacks, or implementation. Link, don't embed.
8. **Non-goals.** Each with the reason it is out, not just the exclusion.
9. **Decision attribution, everywhere.** Every consequential decision is either agreed (by whom) or opens with "Proposed, not yet agreed:" naming whose sign-off it needs and pointing to its open question. The same status appears at every mention of that decision, not just one.
10. **Open questions and risks.** Numbered under their own section's number so they can be referenced (if open questions are section 8, they are 8.1, 8.2, and cross-references elsewhere say 8.1), each stating who owns it and what happens if it stays unresolved. Honest unknowns beat false completeness.
11. **Later versions.** Marked "directional, not committed"; proposed items keep their "pending [name]" tags here too.
12. **Style:** plain language a non-engineer reads cold; numbered lists, never bullets; no dashes as punctuation, no emoji; testable wording (no "fast", "intuitive", "easily"); active voice with names; 3 to 6 pages. Read every sentence cold as its named reviewer and check it does not overstate anyone's position (what someone "did not object to" is not what they agreed to).

## Settling the visual identity

This runs once, early in the build, and produces one committed file. Six things make it work:

1. **Render, do not describe.** Dan does not pick a design from prose. Asked to choose between characters named in words he said "I think I need to see renderings of these to get an idea. I'm not really sure." Build the options, show them, ask afterwards.
2. **One variable per round, everything else held byte identical.** Rounds that moved several things at once produced "still not loving any of them" and no usable signal. Rounds that moved one produced a precise answer every time. Expect eight to a dozen rounds and plan for them.
3. **One window, full context, in a switcher.** Render the whole screen including the surrounding chrome, and let him swap options in place with buttons. A difference you scroll between is remembered; a difference that swaps under a frame that stays put is seen. His words: "render the whole page. I need the context", then "would it be possible for you to show it to me through a switch".
4. **Colour last.** Settle structure, type and density in black and white first. Colour arguments absorb the attention that layout needs ("let's just do black and work on the rest of it before the color").
5. **Treat every objection as a candidate rule.** Check it against the product, and where it holds, promote it into a standing rule with its reason rather than applying it once. "I don't think I like red because that feels like something is wrong" became a rule that red is reserved for the one place something is genuinely wrong.
6. **Count the facts before showing any chrome.** No number may appear twice. A sidebar was rejected on sight for stating the same count in two places.

**The deliverable.** The settled design is ONE self contained file committed in the repo: no build step, no hosted URL, fonts and assets embedded so it renders identically with no network, forever. Its decision record lives inside it, each decision with the reason it was made. Beside it, name the parts that are idioms of the rendering medium rather than design decisions, so they are translated rather than copied when the real screen is built. Ovation's `docs/design/` is the worked example: an HTML file standing in for a SwiftUI window, with its three web idioms named in the README. Every decision with code consequences also goes back into the PRD as numbered requirements, so the PRD stays the single alignment document.

## Red flags, stop and interview instead

| Rationalization | Reality |
|---|---|
| "The request already has enough detail" | Detail in the request is the prompt's shape, not the problem's. Dump and interview first. |
| "I'll just mark my guesses as assumptions" | A page of assumptions is a PRD nobody decided. Ask, or write "Proposed, needs [name]". |
| "They want the document, not questions" | The interview is minutes. A PRD full of invented settled decisions costs the team weeks. |
| "I'll fill in a reasonable metric target" | An invented number reads as a commitment forever. TBD plus an owner is the honest version. |
| "This decision is obviously right" | Then the named owner will approve it in one click. Attribute it anyway. |
| "I'll describe the design options and let him pick" | Nobody picks a design from prose. Renderings first, question second. |
| "Colour and layout can be settled in one round" | Colour absorbs the attention layout needed. Black and white until the structure is settled. |

## Common mistakes

1. A problem section that describes the solution (check: does it name the feature?).
2. Five co-equal success metrics and no primary one.
3. Decisions that silently harden: something proposed once, then referenced later as settled.
4. Spec-level detail (data rules, provisioning, save semantics) in a purpose document.
5. Fixing a correction in one section while its other mentions and cross-references still say the old thing.
