# Lessons index (generated, do not edit)

One line per lesson: the rule itself, without the body or the provenance. Generated from
LESSONS.md, which is NOT loaded into the session. 188 lessons.

To read one in full, with its evidence: `~/claude-config-sync/claude-sync lesson L174`, or
read the entry straight out of ~/.claude/LESSONS.md. Do that whenever a rule below is about
to decide something: the body is where the failure it came from is described.

## Proof over green

- L1. A test or guard is only real once it has been seen to fail.
- L140. A test asserting that something THREW is satisfied by ANY throw, including one raised by its own fixture, so assert on the specific failure (the message, the type, the state left behind) rather than on the mere fact of an error.
- L154. A tool that reports whether a check CAUGHT a deliberate defect must name WHICH check fired, because a defect large enough to break everything makes every check fail and is indistinguishable from the one that should have.
- L177. When a failure reproduces only in an environment you cannot run (a CI runner, another machine, a device), make that environment PRINT the fact in question before changing any code, because a theory built from the symptom is cheap to believe and expensive to ship.
- L178. A check written as two conditions over one body of text is satisfied by two unrelated places in it, so it proves neither half and passes hardest when nothing works at all.
- L182. A ratchet or violation count driven to ZERO stops being read as a measurement and starts being read as proof the thing cannot occur, so nobody re-examines it.
- L151. Every outcome a guard's own contract ENUMERATES must have a test that PRODUCES that outcome, not merely a test that passes.
- L2. Tests must be structurally unable to touch live data, production services, or paid APIs.
- L3. Built is not wired, and wired is not proven.
- L4. A merged fix is not a deployed fix.
- L63. A regression guard must assert the quantity it exists to protect, never a proxy for it.
- L103. A guard that asserts the exact rendering of a value rather than the rule behind it fails the first legitimate refinement of that value, and when the value is a file's text it can also be satisfied by a comment ABOUT the thing, including one explaining that the thing was removed.
- L48. A test fixture that claims to come from real data must be measured from it, never shaped so the rule under test fires.
- L52. A test whose only outside dependency is a stub you wrote can only confirm your own assumption about the real interface.
- L58. Two systems that must agree cannot be verified against records one of them wrote into the other.
- L56. A new validator on a live data path must be calibrated against a sample fetched through the same code path it will guard, and must be observed for one real cycle before it is allowed to block.
- L68. A guard that reads live production data must assert the SIGNATURE of the failure it protects against, never the data's current emptiness.
- L65. A guard shipped deliberately inactive needs the issue that activates it filed in the same change.
- L70. A check whose expected value and its actual value come from the same lookup can only prove that lookup is self-consistent, never that it is correct.
- L82. When a platform primitive's DOCUMENTED guarantee is the entire reason a guard is safe (a clock that excludes sleep, a delivery that happens once, a write that is atomic), measure that guarantee on the real target before shipping.
- L188. A limit your code SETS (a minimum size, a timeout, a cap, a default) is only in force if nothing downstream recomputes it, because a framework or platform deriving the same value from other inputs overwrites yours silently and the line goes on reading as protection while protecting nothing, so measure the value in the RUNNING system rather than trusting the assignment.
- L84. A recorded expectation (a baseline screenshot, a golden file, an approved snapshot) captures whatever the surface happened to be showing when it was recorded, including an error or empty state caused by a dependency the harness never fed it, and then defends that broken state as correct for as long as it lives.
- L85. Two changes that are each green can merge into a broken main, because each one was verified against a base that did not contain the other.
- L88. A CI job that runs only when certain paths change must have those paths derived from every input its tests actually read, not from where the code under test lives.
- L92. When you make a removal or refusal durable by recording it against an identifier (an email, an id, a URL), every item the action can apply to must actually carry that identifier, or the ones lacking it silently keep the exact defect the recording was added to fix.
- L93. A guard that avoids a wrong action by falling back to a different action has only chosen which defect to ship, so name what the fallback gets wrong and measure how often the guard fires on real data.
- L98. A watcher, poller or wait-for-completion step that reports SUCCESS when it found NOTHING to watch is indistinguishable from one that saw everything pass.
- L171. A positive control proves the query SHAPE, never that the query reached the period you are asking about, so a control satisfiable by data from outside that period cannot detect a lagging pipeline and an absence there is worthless.
- L172. Before shipping a threshold, measure where it lands in the REAL distribution of the quantity it judges, because one sitting inside the dense middle turns the count it produces into noise: a small uniform shift carries dozens of items across at once and reads as a sudden regression rather than as the same population barely moving.
- L179. A status query about work in flight must be scoped to the exact revision it asks about, because a superseded run reports under the same check names and answers for the new one in both directions: a stale failure blocks a commit nothing has judged, and a stale pass merges one.
- L119. A detection that ACCUSES on an empty answer from an external provider's derived index (a commit-to-PR association, a search index, a related-records lookup) must confirm against the primary record before acting, because a missing index entry and a real violation are indistinguishable and the index can stay permanently incomplete rather than catch up.
- L173. A fallback added because a lookup failed must be reachable on EVERY way that lookup can fail, not only the flavour that was observed, because the remedy gets scoped to the symptom named in the incident report and is then absent in the neighbouring, worse failure.
- L120. A fan out that delivers only to recipients matching a subscription list reports SUCCESS when it matches ZERO of them, so a newly added event, topic or category is silently delivered to nobody while the send path looks healthy.
- L100. An operation that finds its target by matching text (a marker to insert at, a file to stash, a pattern to replace, a helper name to call) reports SUCCESS when it matches NOTHING, so the next step acts on a state nobody created.
- L143. A test double that selects what it intercepts by PATTERN (a route glob, a URL matcher, a path prefix) silently becomes NO double at all when the pattern misses, so the test talks to the real dependency and reports whatever that produces as the behaviour under test.
- L133. A detector that identifies records written BEFORE a fix must key on a recorded stamp, never on a property of the stored value itself, because a store that re-encodes on save normalizes that property away and the detector then reports every row as already correct.
- L101. A code path that switches behaviour on the SIZE of its input will always take the small branch under test, because a fixture is minimal by construction, so the mode that actually ships is the one never exercised and the suite is green the whole time.
- L102. A cost or latency measured while the expensive path is switched off measures the short circuit, not the work, so the number reads as reassurance for exactly the case nobody has tested.
- L104. A filter that identifies data by its SHAPE (a redaction regex, a content classifier, a profanity or spam rule) must be tested against the content it has to PRESERVE, not only against the content it has to catch, because the shape it matches is rarely unique to its target and an over match reads exactly like the feature working.
- L107. A number measured to justify a design decision must be produced by the code's own predicate, never by a query written beside it, because an ad-hoc reimplementation is a second definition that drifts silently and in the direction that flatters the argument being made.
- L156. A success check that looks for a SUBSTRING OF THE THING BEING TALKED TO (a hostname, a command name, a file path, a resource id) also matches the ERROR about it, because a failure message quotes its target, so match the shape of the SUCCESS output instead.
- L183. A pipeline under `set -o pipefail` can be failed by its PRODUCER being killed when a short-circuiting consumer (`grep -q`, `head`) exits first, so a correct check reports a failure that never happened.
- L115. A harness that measures whether content is VISIBLE must be checked against the substitutes its own renderer makes for content it cannot draw, because a placeholder is itself a mark on the page and measures as presence.
- L141. A visibility check that measures ink over a whole surface is answered by whatever that surface paints for ITSELF, a fill, a border, a panel, so the words it exists to check can be drawn in the background colour while the measurement barely moves.
- L147. A guard seen to fail on a fixture you chose has only been shown to work on the shape you had in mind, so measure how often it fires on the REAL values it will meet.
- L117. A per-item ceiling judged against a POOLED total cannot notice one item running away, because the expensive item is paid for out of the cheap ones' headroom, and a single-item run is the only size where the ceiling and the total are the same number.
- L130. A test fixture whose meaning is the RELATIONSHIP between a stored date and the clock (a show still ahead, a licence not yet expired, a record inside its retention window) must pin BOTH ends, because pinning only the fixture lets real time walk the pair into a different state and the test then passes while asserting about a case nobody chose.
- L134. A test that derives two inputs from the same LIVE shared resource read at different moments must ASSERT the separation it depends on, never assume it, because the healthy margin is usually one unit of that resource's own granularity and a single stale read closes it exactly.
- L135. A guard that matches source text over a WHOLE FILE is satisfied by any occurrence in it, so a second legitimate use of the same construct elsewhere in that file answers the check while the region it was written about is broken.
- L142. When phasing a risky change into observe then enforce, check WHICH half the observation covers: the observed half is usually the one you understand, and the harm usually lives in the other, so an observe phase that never exercises the dangerous path buys confidence about the wrong thing.
- L144. A monitor reporting whether an action HAPPENED must judge by the same predicate the action used to decide whether to ACT, or the two disagree precisely when the action correctly declined, and the resulting false alarm cannot be cleared by the remedy it names, because re-running the action makes it decline again.
- L146. To check that content reached a rendered surface, measure the surface WITHOUT that content and take the difference, because any quantity computed over the whole surface (ink, coverage, a pixel count) also counts the fill, the border and the controls, and can even RISE when the content is removed, since removing it changes what the commonest colour is.
- L165. A fixture built by damaging the END of something lets the scenario finish its real work before failing, so the case under test never occurs while the test reads as convincing, and it passes for a reason unrelated to what it claims.

## Data safety

- L5. Never destroy good state before its replacement is verified to exist.
- L95. Adding a WRITE to an error path re-audits every error that can reach it
- L7. User data gets a rotating backup and a restore path from day one.
- L8. Own your paths.
- L9. Destructive actions get confirmation or undo from the first build, and any automatic deletion or retention policy is the user's product decision, never a silent default.
- L40. A check that decides to SKIP work must compare something that changes whenever the content changes.
- L105. A read, modify, write cycle whose read answers EMPTY when it fails will erase the whole record the first time the read fails, and it does so at the exact moment the record is worth having.
- L116. A rule that only encodes somebody's PREFERENCE must be enforced by filtering what is shown, never by deleting the data it filters, because a preference can be reversed and the data cannot be brought back.
- L136. Clearing a field to CORRECT bad data is a state change whose consequences live in every reader of that field, and a constant named for the empty case (a noManager message, a notSet label) can be a hard REFUSAL rather than a graceful fallback, so read what the null branch DOES before writing the null.
- L168. A parameter a function needs in order to be CORRECT must never carry a default standing for absent, because a caller that forgets it then receives silently missing data instead of a compile error, and the failure surfaces far away as a blank value rather than as a refusal.
- L174. Shortening a retention or expiry window makes every later step keyed to a longer window unreachable, and that step goes on reading as an active safeguard rather than as dead code.

## Honest failure

- L184. Judge a command by its EXIT CODE, never by a line of its output, because a tool's final line is routinely a different measurement than its verdict and is usually the more reassuring of the two.
- L10. An error state and an empty state are different screens.
- L11. Distinct causes get distinct messages, and a message may claim only what its check actually measured.
- L12. Show success only after the write commits, and report what verifiably happened.
- L13. Background jobs and webhooks alert on failure and on the absence of an expected run.
- L53. Two independent checks must never share one status field.
- L90. A counter or category whose only input is a value nothing in the system ever writes reports ZERO, and zero is indistinguishable from a true measurement.
- L47. A batch that partly fails must record the attempt on the items it failed, not only on the ones it completed.
- L67. A placeholder rendered in place of a missing required value (no subject, unknown, not set) is a DETECTION that the value is absent, so it must block the action it appears in, never merely label it.
- L138. A templating or interpolation layer usually renders a MISSING setting as an EMPTY value rather than an absent one, so every absence check written as a null fallback silently accepts it and the default it promises never applies.
- L152. A change is usually reported by the surfaces that show what is still OUTSTANDING (a badge, a waiting list, a standing question), so an operation that RESOLVES everything silences every one of them and the most complete success is the one the product says least about.
- L50. A value parsed from storage or input must never feed a comparison directly.
- L71. A watchdog must not share the abort-on-error behaviour of the work it watches
- L77. An error deliberately classified as EXPECTED (a lost race, a declined payment, a rejected duplicate, a taken slot) must still be counted against a RATE.
- L94. A request or payload assembled in two places, a builder plus a caller that adds more fields, has nowhere its completeness can be seen, so a field missing from both halves is invisible to a reader of either.
- L78. A report of what changed must be assembled from the finished state, never from one of the code paths that change it.
- L106. A liveness signal emitted on a timer (a heartbeat, a keepalive, a still-working marker) proves only that its EMITTER is alive, never that the work is progressing, so a live signal over dead work is indistinguishable from a healthy run.
- L108. A check that validates a value's recognisable PREFIX or shape, but not its completeness, accepts a truncated paste and then stays silent, and that silence reads as confirmation the whole value is good.
- L109. A refusal message that can only be spoken by an action, while the same predicate that would produce it disables that action, can never be spoken, so the person is left with a dead control and no reason while the code reads as careful and its tests pass.
- L110. A wait for a condition with no deadline cannot fail, it can only hang, and a hang is worse than a failure because it is indistinguishable from slowness and holds whatever shared resource it acquired.
- L121. A retry or self heal step that decides from a RECORDED success marker (a stored status, an effects string, an ok field) cannot notice that the artifact it created has since been deleted, so it suppresses its own repair permanently.
- L122. A permission or capability check written as equality against ONE rank of a ranked vocabulary silently excludes every rank ABOVE it, so the most privileged person is the one refused.
- L125. A function answering WHEN something comes due must not fold in the test for whether it is due YET, because reporting nothing for a moment still in the future is indistinguishable from having no moment at all, and any fold that takes the soonest of several such clocks then confidently names a later one.
- L139. A minimum volume floor added so a RATE is not noisy at small samples also silences the SATURATION case, because a proportion cannot tell one bad out of two from twelve bad out of twelve.
- L148. A durable control whose failure reason is written only to a surface that dies with the attempt (a terminal window that closes, a process's stderr, a toast) leaves the person facing the same control, the same unchanged condition, and no way to learn why it did nothing, so pressing it again is the only diagnosis available.
- L158. When the text a failure is diagnosed FROM can come from more than one place (a launcher shell and the process it launched, a supervisor and its child), a rule that takes whichever place is non empty hands the diagnosis to the launcher, because the launcher speaks exactly when the real work never started.
- L160. A condition is only OVER once it has stayed healthy for a re-arm window, never on the first healthy sample, and its duration must be measured to the last observed failure rather than to the moment the all clear is sent.
- L164. Failure recording that lives INSIDE the program a launcher starts cannot record any failure of the launcher itself, so a missing directory, a bad path or an unreadable interpreter leaves no trace at all and reads exactly like the control never having been pressed.

## State and identity

- L14. Derived state re-derives on every input that feeds it, and every action updates every surface showing what it changed.
- L15. Key everything on stable identifiers.
- L145. Changing a record's identity IN PLACE can land on an identity another record already holds, so check the destination is free before writing it.
- L153. A path built from the user's home directory plus a literal folder name records where something happened to be, not what it is, so the first time anyone moves it the code points at nothing.
- L16. A count and the rows it promises come from one shared predicate
- L17. Long-running work belongs to an owner that outlives the screen that started it
- L55. A reader whose correctness depends on which code path produced the state it reads breaks silently when a second path starts producing that state.
- L59. Bookkeeping state that changes for reasons unrelated to the data (a scroll position, an in flight animation, a hover, a tick) must not live on the component that derives the expensive data, because every such write pays the whole derivation again.
- L60. A one-shot trigger (navigate to, scroll to, present, run once) must carry an event with its own identity, never the destination value, because a change-detecting effect cannot see a repeat request for the same target and silently drops it.
- L83. A fact that could sit at either of two levels (the organisation or the contact, the order or its line, the show or the person on it) must have ONE declared home, and every writer and reader must use it.
- L86. A short lived component that registers actions, observers or callbacks into a longer lived shared host (an undo stack, a notification center, an event target, a subscription registry) must either own a private instance of that host or deregister on teardown, because these hosts routinely hold unowned references and outlive the component.
- L89. When two controls can write the same stored field, their option lists are one vocabulary and must be reconciled against each other, not each against some third reference.
- L91. A user action's visible response must not wait on a derivation whose cost scales with the whole collection rather than with what changed.
- L131. A map keyed by a value the real data can repeat (a date, a name, a day) silently keeps the LAST writer and discards every earlier one, and because the surface renders one row per key the loss is invisible on the very screen that exists to report it.
- L162. A completion flag whose only writers are actions performed INSIDE your product is permanently wrong for anyone who does the work in the tool that work actually lives in (a mail client, a CRM, a calendar), so when the truth is visible in a system you already read, derive it from there rather than waiting to be told.
- L163. When the model has no field for a fact, never express that fact by NEGATING a neighbouring one, because the negated field goes on being read as its own fact everywhere else and the system then confidently asserts the opposite of what happened.
- L166. An action that carries out a decision must be addressed by every attribute the decision was made over, because an instruction scoped by fewer names a FAMILY where the decision named one MEMBER, and it silently acts on the records the decision deliberately excluded.
- L169. A variable recording that a step has ALREADY HAPPENED is inherited by every process that step starts, so a descendant reads it as true of ITSELF and skips work it never did.
- L175. A value read once at startup is only true at startup, and when the thing it describes lives OUTSIDE the program (a checkout, a config file, a device, another service) there is no action inside the program to hang a re-read on, so it goes stale invisibly and its silence reads as an assurance.
- L176. A field name that asserts a ROLE or a DIRECTION (who referred whom, source versus destination, sender versus recipient, parent versus child) must be verified against the code that RENDERS it, because the rendered wording is the authority and a backwards name silently recruits every future writer into filling it the wrong way round, with nothing anywhere reporting a problem.
- L185. A statement that NORMALIZES a value on the way in (a COALESCE, a lowercase, a trim, a default standing for absent) must group or deduplicate by the NORMALIZED form, never by the raw one, because two raw spellings that normalize to the same thing survive as separate groups and then collide on one stored key.
- L186. A durable record that exists to stop an action repeating is only as durable as its KEY.

## Security and privacy

- L18. Enforce authorization at the database layer, not only in application code.
- L19. Secret checks fail closed and compare constant-time through one shared verifier.
- L42. A control that exists to protect someone fails closed, not open.
- L43. A platform's built in request authentication is not caller authentication when it accepts your public client key.
- L72. A gate's stored DEFAULT must be its OFF value, so that FORGETTING to set it produces the safe state rather than the live one.
- L75. When identifying WHO or WHAT an outward action targets fails, refuse the action; never fall back to a nearby candidate.
- L124. A platform's DEFAULT grant may already give away what you are about to grant
- L123. Declining to PROVISION someone is not declining to AUTHENTICATE them
- L137. A grant checked only where it is GRANTED (a login, a signup, an invite) is never re-checked for anyone already holding a session, so removing someone from an access list takes nothing away from the people most likely to be removed, and the gap stays invisible until the first real removal.
- L155. An issue or plan written with REAL measured evidence becomes the source whoever implements it copies into fixtures, so redact people's identities where the evidence is RECORDED rather than trusting the implementer to anonymise it later.

## UX completeness

- L20. Accessibility is part of building each control.
- L149. A colour token that clears the level for an icon or a border does not thereby clear it for TEXT, because an interface component needs 3:1 and body text needs 4.5:1, so an accent reused for a label ships under the line while every check that measures whether it DREW reports it as fine.
- L21. Read every new user-facing sentence cold, rendered, in the state that produces it.
- L118. One word must name one unit across the whole product, and an added qualifier is not enough to separate two, because each sentence is correct read alone and the contradiction exists only in the reading.
- L22. Walk the whole flow as the user before calling it done.
- L44. A request to stop, cancel, or undo gets its own acknowledged state the instant it is accepted, distinct from both running and stopped.
- L45. When filtered views are the only way to reach records, the filters must cover the whole state space between them.
- L49. A control must look like a control at rest, not only on hover and not only in a tooltip.
- L54. A guard may refuse only what the system genuinely cannot do; when the work is possible, confirm it instead of blocking it.
- L64. What a person reviews and approves must be exactly what ships, including WHO it goes to, so anything the system composes onto it (a greeting, a header, a footer) or chooses on its behalf (which of several addresses, accounts or targets) belongs in the reviewed artifact.
- L69. A preview or approval surface must render the content on both light and dark backgrounds.
- L76. A region that clips its content must show, at rest and with no interaction, that content continues past the edge, and must stop showing it once the end is reached.
- L79. A notice placed in a container the platform may collapse, overflow or truncate (a toolbar slot, a header that condenses, a single row) is not shipped until it has been seen at the window size the person actually uses.
- L80. When a message names a specific record, source or item so the person can act on it, the surface showing it must carry that action.
- L97. An undo whose input is the very thing the action removed from the screen is not an undo, because the action destroys the only key to its own reversal.
- L99. A client side input mask or cap must never be stricter than the validator that accepts the value, because the form then refuses input the server would take and the person is blocked by a rule nothing states.
- L150. A writer that accepts a value on its own terms must accept only what its READER can actually consume, so validate at the write against the reader's own predicate rather than a looser one.
- L111. A message that tells someone HOW to recover must name an action that actually changes the state they are stuck in, so trace the suggested step against the stored state before shipping it.
- L112. An alert's urgency is set by what the reader must DO and how soon, never by whether something is broken.
- L113. A lookup table keyed by a vocabulary (a colour by status, an icon by type, a label by code) must have its completeness enforced by the type system or a test, because a missing key silently takes the default branch, and a default is indistinguishable from a deliberate choice.
- L126. An action offered only on a transient surface (a run summary, a status message, a toast) cannot serve a condition that PERSISTS in the data, because the notice clears while the state stays, so every encounter after the first finds the fault still named and the remedy gone.
- L180. A confirmation dialog's consequence sentence must be derived from the state it is about to change, never asserted, because a warning shown on every delete carries no information and reads identically whether it is taking one row or a subtree of ten.
- L187. A control gated on a collection holding MORE THAN ONE member is absent in the commonest case, which is one member.

## External systems

- L23. Treat every external response as hostile and every event stream as unordered, late, and duplicated.
- L24. State the expected data volume before writing any query or loop.
- L81. A batch must be sized in the UNIT the limit is actually expressed in, measured from the real inputs, never in a proxy unit calibrated on one sample.
- L87. A change that multiplies how many items an existing request carries inherits that request's aggregate limit, and proving the change correct says nothing about whether it still fits.
- L25. Pin everything.
- L26. Twin implementations in two languages consume one shared committed fixture
- L127. An identifier you SUPPLY to an external system is a request, never a fact, so read back the one it actually assigned before storing it as the key to any later operation.
- L157. An atomic operation guarantees only its own span, so acting on a judgement formed BEFORE it (remove this lock because it was stale, revoke this token because it had expired, evict this entry because it was cold) reintroduces the race the atomicity appears to close, and reads as rigorous precisely because the primitive really is atomic.
- L159. A test asserting that something did NOT happen is satisfied by a fixture in which it COULD not happen, so prove the positive case fires in the SAME fixture before trusting the negative.
- L181. Inferring that a person DID something from a provider's record must key on that provider's own committed state marker, never on an attribute a merely started attempt shares with a finished one (its author, its recipient, its subject), because platforms routinely return drafts, pending items and abandoned attempts in the same collection as completed ones.

## Building with AI

- L27. A rule that lives only in a prompt is a hope.
- L28. Treat a detached AI run as an untrusted subprocess.
- L128. A field whose only writer is an AI prompt, and whose ABSENCE is itself a legitimate value in the domain, cannot tell a model that IGNORED the instruction from one that judged the field inapplicable, so the feature stays dormant forever while every reader reports its honest default.
- L161. When an AI writes a fact the system ALREADY HOLDS the true value for (a date, a venue, a price, a name), check what it wrote AGAINST that value rather than merely checking that something is there, because a presence check passes a contradicted fact, and a wrong fact reaching a stranger is worse than an omitted one, which at least reads as missing.
- L167. An AI writer that can READ the code consuming its output derives its contract from that code's permissiveness, so an optional field is not neutral, it is permission: any combination the schema tolerates will eventually be emitted and defended as valid.

## Codebase hygiene

- L29. Dead code is worse than deleted code.
- L46. Stored data needs a reader, not just a writer.
- L30. Fix the class, not the instance.
- L31. Everything the product depends on lives in git.
- L32. Docs state testable claims.
- L41. A list that must mirror another source of truth is derived from it, never maintained by hand beside it.
- L96. A guard driven by a hand-written registry checks only what the registry lists, so anything missing from it is exempt from the very check meant to catch it, and the guard reports green while blind.
- L129. A category deliberately EXEMPTED from a review or check, for a CORRECT reason, has no reviewer at all unless one is named in the same change, and the gap is invisible precisely because the exemption was right.
- L57. A correction recorded only in memory or a transcript will recur, because the artifact that actually governs the behavior never changed.
- L61. A decision recorded on an issue is only true as of its date, so re-check it against what has shipped since before building to it.
- L62. A guard on a function's first line cannot protect against the cost of building its arguments, because every language evaluates those before the call runs.
- L132. A generated catalogue that a PERSON reviews (a copy inventory, an API surface list, a route map) must be derived from what is REACHABLE, not from what merely appears in the source, because an entry for code nothing calls is indistinguishable from a live one and every reader spends real attention reasoning about a surface that cannot exist.
- L170. A criterion placed last in a strictly ordered comparison chain is consulted only on an exact tie of everything above it, so any earlier criterion carrying many distinct values (a count, a rating, a timestamp) makes it permanently inert while the code reads as a criterion that ranks.
- L501. A new thing built by cloning a proven pattern copies that pattern AS FIRST WRITTEN, including every value already corrected in the original, so clone the CURRENT version and re-check each constant against the rule it has to satisfy.

## Cross-system reliability

- L33. Make the pair of a database write and an external side effect crash-safe.
- L34. Verify domain and vendor data semantics against real samples before building on them.
- L35. Classify errors once, explicitly.
- L36. An alert that cries wolf gets ignored.
- L37. History is stamped at write time.
- L38. Deletes, renames, and state exits enumerate every derived resource.
- L39. One timezone, one date helper.
- L51. A time based threshold is only as timely as the schedule that evaluates it.
- L66. When several records are collapsed onto one shared external identifier (one email thread, one payment, one batch call), decide for EACH downstream fact whether it belongs to the group or to one member, and refuse to write a member level fact the external system does not name.
- L73. Independent steps sharing one handler each need their own failure boundary.
- L74. A deadline, age or due date computed from the current clock at read time can never age, because every evaluation moves it forward with the clock.
- L114. A tool that creates a throwaway workspace must also remove what that workspace caused to be created OUTSIDE it.
