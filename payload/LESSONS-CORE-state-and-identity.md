# Lessons core: State and identity (generated, do not edit)

The lessons of this section chosen for every session, one SHORTENED line each; the rest are in
the library (~/.claude/LESSONS-INDEX-*.md), and every PR lessons review reads them all. Read
the whole entry before a rule decides anything: `~/claude-config-sync/claude-sync lesson L174`.

- L342. Share a predicate only where both call sites ask the SAME question.
- L55. A reader whose correctness depends on which code path produced the state it reads breaks silently when a second path starts producing that state.
- L83. A fact that could sit at either of two levels must have ONE declared home, and every writer and reader must use it.
- L275. An image drawn small must be DECODED small: the renderer decodes the whole source file, and the platform drops that texture on leaving the foreground.
- L162. A completion flag written only by actions INSIDE your product is permanently wrong for anyone doing the work in the tool it really lives in.
- L163. When the model has no field for a fact, never express it by NEGATING a neighbouring one, which is still read as its own fact everywhere else.
- L454. A local copy of something that lives elsewhere is named after what it mirrors, so state what a report was read against and check it against the source.
- L507. A category defined as a REMAINDER records no members, so it can never be enumerated or audited; record its members when it is computed.
- L204. When a change removes an invariant other code relied on, search for the invariant itself rather than reasoning about the feature; it lives in comments.
- L261. Several behaviours a design treats as ONE condition, this run is not real or this tenant is internal, must all read ONE predicate.
- L332. A repair wired to STARTUP is blind to everything the running system writes after it, so the state a person actually works in is the unrepaired one.
- L358. A unique user count from client side analytics counts identities it ISSUED, and any isolated storage turns one person into several, always inflating.
- L594. A control holding several values in ONE text box is edited a fragment at a time, and deleting one leaves a value well formed under another reading.
- L389. A writer that only fills records going FORWARD never reaches anything that existed when it shipped, so consumers run correctly over an empty set.
- L580. Editing by DELETING and RECREATING discards the run history, metrics and audit trail with it, so use an in place alter where the platform offers one.
- L432. A default RE-DERIVED from a sibling field whenever that field changes hides itself, and only the constant DIFFERENCE between the two reveals it.
- L636. When an automation creates a record only a person can advance, record that it is WAITING and why, or the queue awaiting a human is invisible.
- L650. A mapping that MERGES several values onto one label is correct only while they still mean the same thing, and no per row test can see the fault.
- L1003. A cache invalidated by any change to the whole collection never survives a write, so scope invalidation to the members the value depends on.
- L1005. A conflict check keyed only on the slot makes the subject clash with itself, so compare identity too, or a real clash and the same record read alike.
