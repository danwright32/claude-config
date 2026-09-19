# Lessons index: Codebase hygiene (generated, do not edit)

One SHORTENED line per lesson: the condition and the instruction, routinely dropping the
clause saying what the failure looks like. Read the whole entry before a rule decides
anything: `~/claude-config-sync/claude-sync lesson L174`, or the entry in ~/.claude/LESSONS.md,
which is NOT loaded into the session.

- L217. A guard whose forbidden values are DERIVED from a shipped dataset covers only what that dataset contains, so a real value never in it is exempt.
- L29. Dead code is worse than deleted code.
- L346. A recorded reason for LEAVING something as it is reads as a considered decision, so confirm the thing is still on a live path before writing one.
- L46. Stored data needs a reader, not just a writer.
- L30. Fix the class, not the instance.
- L31. Everything the product depends on lives in git.
- L32. Docs state testable claims.
- L210. A check keeping a document in sync by comparing a machine readable token leaves the sentence beside it unverified, and more trusted for passing.
- L41. A list that must mirror another source of truth is derived from it, never maintained by hand beside it.
- L96. A guard driven by a hand-written registry checks only what the registry lists, so anything missing from it is exempt from the check meant to catch it.
- L247. A sweep requiring every place doing X to also do Y must enumerate by the STATE reached, never one spelling of X, or another route is never enumerated.
- L452. Your code and somebody else's in one shared environment share EVERY namespace it offers, so close the rest in the same change as the one that collided.
- L450. When more than one control sits on an action, check each recogniser against the route the OTHERS push people onto, or one drops to zero coverage.
- L129. A category deliberately EXEMPTED from a check has no reviewer unless one is named in the same change, and the gap is invisible because it was right.
- L582. When one fact is recorded by two mechanisms that exclude each other's territory, assert their union against the real population.
- L57. A correction recorded only in memory or a transcript will recur, because the artifact that actually governs the behavior never changed.
- L61. A decision recorded on an issue is only true as of its date, so re-check it against what has shipped since before building to it.
- L62. A guard on a function's first line cannot protect against the cost of building its arguments, which every language evaluates before the call.
- L132. A generated catalogue a PERSON reviews must be derived from what is REACHABLE, or an entry for dead code is indistinguishable from a live one.
- L170. A criterion placed last in a strictly ordered comparison chain is consulted only on an exact tie above it, so a many-valued earlier one makes it inert.
- L501. A new thing cloned from a proven pattern copies it AS FIRST WRITTEN, corrections included, so clone the CURRENT version and re-check each constant.
- L195. A newly recorded lesson governs only the code written after it, so when you record one, sweep the OTHER projects for the same defect at once
- L233. In a list of exclusions, an entry carrying no written reason while its neighbours each carry one is evidence it was never reasoned about.
- L244. A file auto loaded into every session is believed without re-checking, so any status it records must be derived, or carry a check that fails on drift.
- L262. A constraint only ever satisfied as a side effect of somebody doing the work by hand stops holding the first time that work is GENERATED.
- L570. A sequence applied only incrementally forward is never run from empty, so a step depending on state one machine already had fails on every fresh one.
- L263. A shared NAME is read as evidence of shared BEHAVIOUR, so two same-named functions either side of a boundary can implement different rules forever.
- L370. Sharing a rule's DATA while copying the code that APPLIES it is not consolidation: the shared constant stops anyone asking whether the logic was copied.
- L274. An exception singling out ONE item must be answered by the ITEM, never a predicate repeated at each loop, or a later loop omits it.
- L281. Behaviour correct only as a SIDE EFFECT of an unrelated rule has no test, comment or owner, so the first change to that rule removes it silently.
- L286. A derivation every test needs is recomputed per test unless its default input is memoised, and the memo must not be able to capture an empty result.
- L542. Two similar rules that DIFFER may each be a recorded decision, so find the decision record for EACH side before making them agree.
- L374. A gitignore entry without a leading slash matches at EVERY depth, so a rule for one top level folder swallows any same named directory anywhere.
- L554. A generated file committed beside its source conflicts on every aggregate it carries, so two clean edits still collide over content nobody wrote.
- L422. A derived artifact COMMITTED beside its source claims to be current, so the check that regenerates and compares ships in the same change.
- L383. A derived value exposed as a computed property is re-run in full by EVERY reader, and the call site reads as a free field access.
- L471. A render body runs on events that change no data, so a whole collection derivation computed once per pass is still paid at an unpredictable rate.
- L556. Before asking whether two surfaces should agree, enumerate every place they ALREADY disagree, because the answer comes back as a rule about all of them.
- L562. A named rule is copied through its WORKED EXAMPLE, so an example that contradicts the rule teaches the inverse with the rule's authority behind it.
- L387. A change fixing a defect CLASS must have its own DIFF searched for a fresh instance, because it is written by somebody holding the class in mind.
- L585. A guard banning raw values in favour of tokens is blind to a token REFERENCED but never DEFINED, because there is no literal for it to find.
- L407. A constraint recorded only as a COMMENT is enforced by nothing, and sitting there makes it read as binding.
- L624. A step whose work list is what an earlier mechanism REPORTED loses every subject a later fix stops it reporting, and still has to act on them.
- L428. Adding a new threshold BESIDE an existing one leaves every reader of the old constant answering a superseded question, and no change rule fires.
- L429. A file the platform loads AUTOMATICALLY into every session has a size ceiling nothing measures, so check its size: past it the rules stop arriving.
- L437. Code lifted out of a file leaves behind everything it inherited from that file's AMBIENT SCOPE, and the inherited thing is usually a default.
- L631. Resolving a conflict by splicing both sides can drop the delimiter that closed the block, so check the file's STRUCTURE, not just that markers are gone.
- L655. Finding the right shared place to PUT new logic is not the same as checking whether it already EXISTS, and doing the first well hides the second.
- L683. A change that redefines the UNIT a number counts re-aims every consumer, so enumerate the readers from where the value is PUBLISHED, not from the issue.
- L481. A plan shipped with its own audit unresolved is read as THE plan, so file the correction as a gating issue alongside the phase issues.
