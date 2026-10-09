# Lessons core: Data safety (generated, do not edit)

The lessons of this section chosen for every session, one SHORTENED line each; the rest are in
the library (~/.claude/LESSONS-INDEX-*.md), and every PR lessons review reads them all. Read
the whole entry before a rule decides anything: `~/claude-config-sync/claude-sync lesson L174`.

- L285. A store several consumers draw from must be drained by the key it is written by, or a coarser clear destroys work belonging to consumers it cannot see.
- L206. A tool mode whose NAME reads like an inspection must not create or modify live data: it gets run to look around by somebody in a hurry.
- L5. Never destroy good state before its replacement is verified to exist.
- L95. Adding a WRITE to an error path re-audits every error that can reach it
- L7. User data gets a rotating backup and a restore path from day one.
- L9. Destructive actions get confirmation or undo from the first build, and any automatic deletion or retention policy is the user's decision, never a default.
- L136. Clearing a field to CORRECT bad data changes state for every reader of it, and the constant named for the empty case can be a refusal, so read it first.
- L174. Shortening a retention or expiry window makes every later step keyed to a longer one unreachable, while it still reads as an active safeguard.
- L191. A write into a CAPPED or rolling store EVICTS the oldest real records, so a cheap writer destroys the expensive observations the store exists to hold.
- L202. Evidence attached to a record swept on a retention schedule inherits that lifetime, so it is gone before the investigation that needs it arrives.
- L256. Before dropping a stored column, measure it against its DECLARED DEFAULT rather than null, which reports a harmless column as full of data.
- L598. A page already open is a client of whichever version was live when it loaded, so every deploy breaks whatever that page minted at BUILD time.
- L267. Running a new version that AUTO MIGRATES a shared store consumes your ability to run the PREVIOUS version against it
- L338. Archiving a run's INPUTS and OUTPUTS but not what it DID leaves the only question anybody asks later unanswerable, while reading as complete evidence.
- L381. A mirrored directory has ONE authoritative side: an edit to the other is silently reverted, and a new file there is deleted outright.
- L559. A rule deciding whether a record COUNTS belongs where it is READ, never also where it is WRITTEN, or reversing the rule later recovers nothing.
- L601. A claim that there is NOTHING TO CORRECT must be measured across every field the change can touch, not only the one the change was framed around.
- L592. Two datasets meant to be read TOGETHER must be retained on the same boundary
- L595. A configuration value that can live in more than one store
- L599. Repairing a monitor that compares against a STORED BASELINE makes its first run a report about the OUTAGE rather than about the present
- L436. An import's completeness is a property of the PERIOD it must cover, not the source it reads, so establish the earliest record the business has.
- L649. An automation that performs the same state change as an existing human control inherits the ACTION but not the SAFEGUARD around it
- L667. Put a refusal at the first step that can answer it: added to a LATE step it makes the rare leftover happen on every ordinary refused attempt.
- L698. A build that bakes env files into the artifact ships every local env file, so prove a throwaway deploy holds NO production credential by reading it.
- L719. Whatever structurally stops the TESTS touching production must also stop the DEV SERVER, whose only symptom for pointing at it is that everything works.
- L1010. A schema version a store was written by is immutable: editing its frozen shape orphans every such store, so add a new version and a stage instead.
