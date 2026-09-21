# Lessons index: Data safety (generated, do not edit)

One SHORTENED line per lesson: the condition and the instruction, routinely dropping the
clause saying what the failure looks like. Read the whole entry before a rule decides
anything: `~/claude-config-sync/claude-sync lesson L174`, or the entry in ~/.claude/LESSONS.md,
which is NOT loaded into the session.

- L285. A store several consumers draw from must be drained by the key it is written by, or a coarser clear destroys work belonging to consumers it cannot see.
- L206. A tool mode whose NAME reads like an inspection must not create or modify live data: it gets run to look around by somebody in a hurry.
- L201. A seam or flag that keeps a test off live data on the way IN (a loadingSaved flag, an injected path the loader alone uses) does not cover the way OUT
- L5. Never destroy good state before its replacement is verified to exist.
- L567. A stored verification that AUTHORISES an irreversible action must be refused on its AGE at use: a past measurement looks exactly like a current one.
- L95. Adding a WRITE to an error path re-audits every error that can reach it
- L7. User data gets a rotating backup and a restore path from day one.
- L8. Own your paths.
- L574. An undo that restores FEWER fields than the action changed is not its inverse, so any copy calling it reversible is a claim about two separate writes.
- L9. Destructive actions get confirmation or undo from the first build, and any automatic deletion or retention policy is the user's decision, never a default.
- L40. A check that decides to SKIP work must compare something that changes whenever the content changes.
- L105. A read, modify, write cycle whose read answers EMPTY on failure erases the whole record the first time it fails, when the record is worth most.
- L116. A rule encoding only a PREFERENCE must filter what is shown, never delete the data, because a preference can be reversed and the data cannot.
- L136. Clearing a field to CORRECT bad data changes state for every reader of it, and the constant named for the empty case can be a refusal, so read it first.
- L168. A parameter a function needs to be CORRECT must never default to a value standing for absent, or a forgetful caller gets missing data, not an error.
- L174. Shortening a retention or expiry window makes every later step keyed to a longer one unreachable, while it still reads as an active safeguard.
- L191. A write into a CAPPED or rolling store EVICTS the oldest real records, so a cheap writer destroys the expensive observations the store exists to hold.
- L202. Evidence attached to a record swept on a retention schedule inherits that lifetime, so it is gone before the investigation that needs it arrives.
- L211. A cleanup deleting whatever its read did not mention must refuse on a SHORT read, not only a failed one, or incompleteness becomes permanent deletion.
- L219. A test that drives a real browser and does not assert on its CONSOLE discards a diagnosis the browser already made
- L256. Before dropping a stored column, measure it against its DECLARED DEFAULT rather than null, which reports a harmless column as full of data.
- L260. Two outcomes a guard gives distinct MESSAGES but the same CONSEQUENCE are one outcome in practice
- L598. A page already open is a client of whichever version was live when it loaded, so every deploy breaks whatever that page minted at BUILD time.
- L267. Running a new version that AUTO MIGRATES a shared store consumes your ability to run the PREVIOUS version against it
- L338. Archiving a run's INPUTS and OUTPUTS but not what it DID leaves the only question anybody asks later unanswerable, while reading as complete evidence.
- L377. Retiring a feature must delete the STORED POINTERS to what it produced, not only its writer and screen, or a generic consumer acts on every one left.
- L381. A mirrored directory has ONE authoritative side: an edit to the other is silently reverted, and a new file there is deleted outright.
- L559. A rule deciding whether a record COUNTS belongs where it is READ, never also where it is WRITTEN, or reversing the rule later recovers nothing.
- L392. A one time correction skipping rows for a state that can END postpones rather than exempts them, and nothing re-runs when that state ends.
- L601. A claim that there is NOTHING TO CORRECT must be measured across every field the change can touch, not only the one the change was framed around.
- L575. Deleting cached content must clear the marker recording its coverage, a cursor, sync token or last refreshed stamp, in the same write.
- L592. Two datasets meant to be read TOGETHER must be retained on the same boundary
- L595. A configuration value that can live in more than one store
- L599. Repairing a monitor that compares against a STORED BASELINE makes its first run a report about the OUTAGE rather than about the present
- L615. Write a RESTRICTION's condition as the reason for restricting, never as a broader property that happens to include it
- L436. An import's completeness is a property of the PERIOD it must cover, not the source it reads, so establish the earliest record the business has.
- L443. An object held in memory from before another writer changed the record writes the old values back, so a field owned elsewhere must not be saved from it.
- L649. An automation that performs the same state change as an existing human control inherits the ACTION but not the SAFEGUARD around it
- L667. Put a refusal at the first step that can answer it: added to a LATE step it makes the rare leftover happen on every ordinary refused attempt.
- L474. Opening a live SQLite store read only still rewrites its shm file beside it, so a guard must read a copy of the store, wal and shm instead.
- L698. A build that bakes env files into the artifact ships every local env file, so prove a throwaway deploy holds NO production credential by reading it.
- L719. Whatever structurally stops the TESTS touching production must also stop the DEV SERVER, whose only symptom for pointing at it is that everything works.
