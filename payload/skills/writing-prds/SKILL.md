---
name: writing-prds
description: Use when Dan asks for a PRD, product brief, or requirements document, or wants to "plan out" a new product or feature from source materials (call transcripts, decks, recordings, prototypes), before any build planning or code. Also use when reviewing or revising an existing PRD. Also use at the start of building any product or feature that has an agreed PRD but whose look is not yet settled, when the first screen, UI, layout or visual identity is about to be designed or built.
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
7. **Settle the visual identity before the first screen is built.** Once the PRD is agreed and the main screen's content is known, the first build task is a design round, not code. Not earlier: there is nothing to draw before the PRD says what is on the screen. Not later: once a screen exists in the real framework every round costs a rebuild instead of an edit, and the question quietly changes from what this should look like to what is cheap to change now. Run it with the `design-rounds` skill, and treat its result as a settled artifact, not a sketch. Because this step runs in a later session than the PRD, delivering the PRD also opens a tracked issue for it, in the PRD's own milestone, so it survives the session that wrote the document.
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

The process lives in the `design-rounds` skill, which owns the six rules, the
switcher tool and the deliverable spec. Invoke it rather than restating it here. In
short: render before asking, one variable per round, one window in a switcher, colour
last, and the settled design ships as one self contained committed file with its
decision record inside it. Every decision with code consequences comes back here as
numbered requirements, so the PRD stays the single alignment document.

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
