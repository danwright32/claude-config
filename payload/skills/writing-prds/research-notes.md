# Research notes behind this skill (2026-08-13)

Provenance for the output spec's choices. Principles folded into SKILL.md: problem stated as problem (Intercom, Figma's problem-alignment gate); one primary success measure with baseline (Lenny, Doshi); explicit non-goals (near-universal in strong templates); short document, 3 to 6 pages (Linear, practitioner consensus); open questions each with an owner; active voice with names; no ambiguous adjectives; link, don't embed; circulate for reaction, not approval (Lenny, Yamashita, Amazon's silent-reading review); living document that must track what is actually being built (Doshi).

Known disagreements deliberately resolved for Dan's context: Cagan argues a prototype should be the primary spec and documents go unread; Dan's workflow uses the PRD as the alignment artifact before planning, so this skill keeps the document primary but enforces Linear-style brevity. Amazon's PR-FAQ format was not adopted, but its "work backwards from the person affected" instinct survives in the problem-first ordering and reader-cold sentence check.

Sources read by the research pass:
1. Revisiting the Product Spec, SVPG: https://www.svpg.com/revisiting-the-product-spec/
2. Putting Amazon's PR/FAQ to Practice, Commoncog: https://commoncog.com/putting-amazons-pr-faq-to-practice/
3. Figma's Approach to Modern PRDs, Yuhki Yamashita: https://coda.io/@yuhki/figmas-approach-to-product-requirement-docs
4. For Better Products, Start With a Problem Statement, Intercom: https://www.intercom.com/blog/how-to-write-problem-statements/
5. Lenny's Product Requirements Template, Atlassian: https://www.atlassian.com/software/confluence/templates/lennys-product-requirements
6. How We Run Projects at Linear: https://linear.app/now/how-we-run-projects-at-linear
7. How to Write PRDs for AI Coding Agents, David Haberlah: https://medium.com/@haberlah/how-to-write-prds-for-ai-coding-agents-d60d72efb797
8. Write a PRD That Engineers Actually Read, Ideaplan: https://www.ideaplan.io/blog/how-to-write-a-prd
9. Shreyas Doshi on PRDs: https://x.com/shreyas/status/1249039986386583553

## The visual identity step (added 2026-09-07)

"Settling the visual identity" does not come from the sources above; none of them covers it. It is generalized from one worked case, eleven design rounds on Ovation's main screen with Dan on 2026-09-06, recorded in that project's memory (`dan-judges-design-by-looking`) and in its `docs/design/README.md`.

What is evidenced there: the round structure (render before asking, one variable per round, a switcher inside a full window, colour deferred until the structure is settled), Dan's objections turning out to be principles worth promoting into rules, and the committed self contained artifact with its decision record inside it.

What is inferred rather than measured: the placement. The argument for putting it at the start of the build, rather than anywhere else, is only that a screen already built in the real framework makes every subsequent round cost a rebuild. Nobody has run the alternative.

This step is also a partial concession to the one disagreement noted above. Cagan's position in source 1 is that a prototype should be the primary spec and documents go unread. Here the document stays primary for the problem, and a rendering becomes primary for the look.

The process itself moved to the `running-design-rounds` skill on 2026-09-07, so it can be reached from a build session rather than only from a PRD session. What stays here is the placement argument and this record.
