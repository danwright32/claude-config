# Lessons core: UX completeness (generated, do not edit)

The lessons of this section chosen for every session, one SHORTENED line each; the rest are in
the library (~/.claude/LESSONS-INDEX-*.md), and every PR lessons review reads them all. Read
the whole entry before a rule decides anything: `~/claude-config-sync/claude-sync lesson L174`.

- L341. A curve assembled from piecewise segments must be checked for continuity of its RATE OF CHANGE, not only its value; the step in the rate is what shows.
- L149. A colour token clearing the level for an icon or border does not clear it for TEXT, which needs 4.5:1 against an interface component's 3:1.
- L21. Read every new user-facing sentence cold, rendered, in the state that produces it.
- L118. One word must name one unit across the product, and a qualifier is not enough to separate two: each sentence reads right and only the pair is wrong.
- L22. Walk the whole flow as the user before calling it done.
- L49. A control must look like a control at rest, not only on hover and not only in a tooltip.
- L64. What a person reviews must be exactly what ships, WHO it goes to included, so anything the system composes or chooses belongs in the review.
- L69. A preview or approval surface must render the content on both light and dark backgrounds.
- L76. A region that clips its content must show, at rest and with no interaction, that content continues past the edge, and stop showing it at the end.
- L79. A notice placed in a container the platform may collapse or truncate is not shipped until it has been seen at the window size the person actually uses.
- L111. A message telling someone HOW to recover must name an action that changes the state they are stuck in, so trace the step against the stored state first.
- L399. An instruction to a person must be written in the vocabulary of the place they will act, never in the terms of the constraint that motivated it.
- L112. An alert's urgency is set by what the reader must DO and how soon, never by whether something is broken.
- L126. An action offered only on a transient surface cannot serve a condition that PERSISTS, so every encounter after the first finds the fault and no remedy.
- L180. A confirmation's consequence sentence must be derived from the state it is about to change, or it reads the same taking one row or a subtree of ten.
- L568. Replacing a native form control drops submission by name, keyboard operation, type ahead, screen reader semantics, and freedom from being clipped.
- L207. A constraint imposed by the surface your output is DISPLAYED on leaves no trace in the artifact or any check, so it is only found on a real device.
- L221. A limit calibrated against the DEVICE somebody owns is looser than the same device turned down, so calibrate against its most constrained SETTING.
- L569. A surface token is one half of a pair with the surface BEHIND it, so checking only what sits ON it says nothing about whether the surface is visible.
- L213. A colour token meaningful only as a PAIR must be overridden as a pair, or a call site swapping one keeps the other and the content becomes invisible.
- L232. A minimum reserved for one part of a shared space is SUBTRACTED from whatever shares it, so check it for being too LARGE as much as too small.
- L269. A finding the system cannot verify was acted on must carry its own resolve and dismiss controls, or it stands after the work and teaches people to skim.
- L526. A store collecting items for a PERSON to act on is only as useful as the rate they can be taken out of it, so size the drain against the rate it fills.
- L279. A record's usefulness depending on a COMBINATION of optional inputs is stated nowhere, so name it on the form and label the partly filled state.
- L330. An acknowledgement a person gives must be consulted by EVERY rule raising that question, or a second rule asks on with nothing able to satisfy it.
- L546. A screen no navigation links to works perfectly for whoever built it, and is invisible to every test, review and build until somebody needs it.
- L558. A mark drawn BESIDE a caption of the same fact is decoration, so a spec asking for BOTH ships the duplication as a requirement.
- L587. A key and the THING it describes are two consumers of one style record, so a field only ONE reads makes the key describe a treatment the thing lacks.
- L410. An automatic pass beside a manual control hides every case the control's gate cannot express, so compare the two predicates before removing the pass.
- L606. UI ships unseen by two routes, a two row fixture and a green suite, and each reads as having looked.
- L607. The native control and the framework's default surface are what SHIP when nothing replaces them, and they read as the OS pasted into the product.
- L609. Ordering a screen by the shape of the DATA puts what the reader scans for wherever it falls, and gives the commonest value the heaviest treatment.
- L613. A shared component made to end N copies converts the one site in front of you and leaves the rest, with the superseded thing arguing for itself.
- L648. When a quantity can be wrong in two directions and one hides content, never aim for the exact value: bias hard toward the harmless side and say why.
- L666. Building a replacement for a live system gets parity checks about the DATA and none about the SCREEN, so whatever the incumbent accumulated is dropped.
- L677. A step removed from a flow takes with it every capability that only that step offered
- L678. A warning is read by its PRESENCE, so a surface that never got one is indistinguishable from a surface with nothing to warn about.
- L449. Automating a task changes what every counter of it MEANS, from work waiting to a fact about the data, and nothing re-examines the counter.
- L717. A screen that refreshes only when an action SUCCEEDS contradicts its message on outcomes where the record may have changed, so decide per outcome.
- L1007. An action word derived from a STATE must name something the rules PERMIT in that state, or honouring it later means building the forbidden action.
- L1008. A control that records a value is gated on its absence, so unless some surface shows and edits the recorded value, a wrong answer is permanent.
