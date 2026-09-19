# Lessons index: Security and privacy (generated, do not edit)

One SHORTENED line per lesson: the condition and the instruction, routinely dropping the
clause saying what the failure looks like. Read the whole entry before a rule decides
anything: `~/claude-config-sync/claude-sync lesson L174`, or the entry in ~/.claude/LESSONS.md,
which is NOT loaded into the session.

- L18. Enforce authorization at the database layer, not only in application code.
- L19. Secret checks fail closed and compare constant-time through one shared verifier.
- L42. A control that exists to protect someone fails closed, not open.
- L397. A control made of a write that ARMS it and a read that ENFORCES it needs BOTH halves checked, or a failed arming leaves enforcement with nothing to do.
- L43. A platform's built in request authentication is not caller authentication when it accepts your public client key.
- L72. A gate's stored DEFAULT must be its OFF value, so that FORGETTING to set it produces the safe state rather than the live one.
- L75. When identifying WHO or WHAT an outward action targets fails, refuse the action; never fall back to a nearby candidate.
- L124. A platform's DEFAULT grant may already give away what you are about to grant
- L541. A REVOKE that is PRESENT can still be ineffective: revoking from PUBLIC does not remove a grant made DIRECTLY to a role.
- L503. An over-broad permission is invisible, because the code never attempts what it is not meant to do, while a missing one fails loudly on the first run
- L123. Declining to PROVISION someone is not declining to AUTHENTICATE them
- L137. A grant checked only where it is GRANTED is never re-checked for anyone holding a session, so removing someone takes nothing away from them.
- L222. A privacy guard that scans your REPOSITORY cannot see what a tool PRINTS, so any tool reading a live system puts real customer data into transcripts.
- L155. An issue written with REAL measured evidence is what the implementer copies into fixtures, so redact identities where the evidence is RECORDED.
- L268. A BULK query over a protected collection leaks the WHOLE collection in its ERROR message
- L360. A value redacted where an object is CONSTRUCTED is unredacted by any later step that ENRICHES it, so give the enriching function the same gate.
- L388. A search matching a field the viewer cannot READ hands its content back one guess at a time through the result count, without ever displaying it.
- L616. A product whose access is a fixed list of named users needs a maintainer identity from the first migration, excluded from the users' notifications.
- L630. An entitlement DERIVED from a downstream artifact, access from a team or a role from an assignment, is absent for precisely the NEWEST subject.
- L653. A redaction wired to a record's structured fields leaves every free text field untouched, and a diagnostic print of the payload lands in exactly those.
- L657. A wildcard read crossing into a different retention or trust domain makes every future column an automatic disclosure nobody reviewed.
- L658. On a managed runtime a diagnostic print is an EGRESS rather than local output
- L446. A redaction implemented by overriding how a type DESCRIBES itself is bypassed by every renderer that REFLECTS it, and a reference type does not help.
- L669. Lengthening an expiry, TTL or retention window silently removes the ceiling it was placing on every OTHER staleness that window happened to bound
- L697. A robots Disallow and a noindex header cancel out: a disallowed page is never fetched, so allow the crawl and serve noindex to keep it out of search.
- L702. A SQL allow list returning NULL for an unlisted kind makes `if not (x = any(allowed))` skip and permit everything, so give the CASE an else that raises.
- L482. A privacy guard scoped to personal identity exempts everything else the dataset discloses, so define what makes it sensitive before scoping the guard.
- L484. Before a privacy sweep swaps a real name for an invented one, check whether code matches on or writes it; if so, exempt it instead.
- L489. A guard walking the WORKING TREE cannot see history, so a deleted secret stays readable while it reports clean: scan every reachable object.
