# Lessons core: Codebase hygiene (generated, do not edit)

The lessons of this section chosen for every session, one SHORTENED line each; the rest are in
the library (~/.claude/LESSONS-INDEX-*.md), and every PR lessons review reads them all. Read
the whole entry before a rule decides anything: `~/claude-config-sync/claude-sync lesson L174`.

- L217. A guard whose forbidden values are DERIVED from a shipped dataset covers only what that dataset contains, so a real value never in it is exempt.
- L346. A recorded reason for LEAVING something as it is reads as a considered decision, so confirm the thing is still on a live path before writing one.
- L46. Stored data needs a reader, not just a writer.
- L30. Fix the class, not the instance.
- L31. Everything the product depends on lives in git.
- L96. A guard driven by a hand-written registry checks only what the registry lists, so anything missing from it is exempt from the check meant to catch it.
- L247. A sweep requiring every place doing X to also do Y must enumerate by the STATE reached, never one spelling of X, or another route is never enumerated.
- L450. When more than one control sits on an action, check each recogniser against the route the OTHERS push people onto, or one drops to zero coverage.
- L129. A category deliberately EXEMPTED from a check has no reviewer unless one is named in the same change, and the gap is invisible because it was right.
- L582. When one fact is recorded by two mechanisms that exclude each other's territory, assert their union against the real population.
- L57. A correction recorded only in memory or a transcript will recur, because the artifact that actually governs the behavior never changed.
- L61. A decision recorded on an issue is only true as of its date, so re-check it against what has shipped since before building to it.
- L132. A generated catalogue a PERSON reviews must be derived from what is REACHABLE, or an entry for dead code is indistinguishable from a live one.
- L195. A newly recorded lesson governs only the code written after it, so when you record one, sweep the OTHER projects for the same defect at once
- L244. A file auto loaded into every session is believed without re-checking, so any status it records must be derived, or carry a check that fails on drift.
- L262. A constraint only ever satisfied as a side effect of somebody doing the work by hand stops holding the first time that work is GENERATED.
- L570. A sequence applied only incrementally forward is never run from empty, so a step depending on state one machine already had fails on every fresh one.
- L263. A shared NAME is read as evidence of shared BEHAVIOUR, so two same-named functions either side of a boundary can implement different rules forever.
- L370. Sharing a rule's DATA while copying the code that APPLIES it is not consolidation: the shared constant stops anyone asking whether the logic was copied.
- L281. Behaviour correct only as a SIDE EFFECT of an unrelated rule has no test, comment or owner, so the first change to that rule removes it silently.
- L542. Two similar rules that DIFFER may each be a recorded decision, so find the decision record for EACH side before making them agree.
- L554. A generated file committed beside its source conflicts on every aggregate it carries, so two clean edits still collide over content nobody wrote.
- L556. Before asking whether two surfaces should agree, enumerate every place they ALREADY disagree, because the answer comes back as a rule about all of them.
- L562. A named rule is copied through its WORKED EXAMPLE, so an example that contradicts the rule teaches the inverse with the rule's authority behind it.
- L624. A step whose work list is what an earlier mechanism REPORTED loses every subject a later fix stops it reporting, and still has to act on them.
- L429. A file the platform loads AUTOMATICALLY into every session has a size ceiling nothing measures, so check its size: past it the rules stop arriving.
- L631. Resolving a conflict by splicing both sides can drop the delimiter that closed the block, so check the file's STRUCTURE, not just that markers are gone.
- L655. Finding the right shared place to PUT new logic is not the same as checking whether it already EXISTS, and doing the first well hides the second.
- L683. A change that redefines the UNIT a number counts re-aims every consumer, so enumerate the readers from where the value is PUBLISHED, not from the issue.
- L481. A plan shipped with its own audit unresolved is read as THE plan, so file the correction as a gating issue alongside the phase issues.
