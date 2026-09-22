# Lessons index: External systems (generated, do not edit)

One SHORTENED line per lesson: the condition and the instruction, routinely dropping the
clause saying what the failure looks like. Read the whole entry before a rule decides
anything: `~/claude-config-sync/claude-sync lesson L174`, or the entry in ~/.claude/LESSONS.md,
which is NOT loaded into the session.

- L477. A browser error reporter files every uncaught error on the page as yours, including a host in-app browser's injected script: check your bundle first.
- L513. A value a platform REPORTS is what is currently configured, never what is available
- L23. Treat every external response as hostile and every event stream as unordered, late, and duplicated.
- L425. A decoder that declares only the fields it needs today silently discards every sibling in the same object, and nothing anywhere reports the loss
- L24. State the expected data volume before writing any query or loop.
- L81. A batch must be sized in the UNIT the limit is actually expressed in, measured from the real inputs, never in a proxy unit calibrated on one sample.
- L87. A change that multiplies how many items a request carries inherits that request's aggregate limit, and proving it correct says nothing about the fit.
- L25. Pin everything.
- L26. Twin implementations in two languages consume one shared committed fixture
- L127. An identifier you SUPPLY to an external system is a request, never a fact, so read back the one it assigned before storing it as a key.
- L157. An atomic operation guarantees only its own span, so acting on a judgement formed BEFORE it reintroduces the race the atomicity appears to close.
- L159. A test asserting something did NOT happen is satisfied by a fixture where it COULD not, so prove the positive fires in the SAME fixture first.
- L181. Inferring a person DID something must key on the provider's own committed state marker, never an attribute a merely started attempt also has.
- L237. Addressing something by its POSITION measures whatever currently occupies that position, so prove the thing you named is there, and refuse if not.
- L190. A read back verifying another application performed a write must be proved to read the store THAT application writes to, not a second subscriber.
- L193. A feature resolving user values through a stored REFERENCE dataset is only as complete as that dataset, so measure the join's real hit rate first.
- L198. A check verifying another system's work must match values no more strictly than that system does, or it reports failure on every correct run.
- L265. Before building a path that carries on past an external service's negative verdict, check whether that service is also the GATE on the action
- L266. Removing a prefix by SUBSTRING REPLACEMENT matches anywhere in the value, not only at the start
- L271. A cross repository deliverable phrased as what YOUR side must WRITE says nothing about whether the consuming side can READ it
- L273. A normalization written to make a comparison forgiving covers only the character class its author thought of, so state its reason and cover them all.
- L280. A rule enforced at ONE stage of a pipeline is not enforced by the pipeline: every later stage that rewrites the content can reintroduce it.
- L534. A platform setting whose DEFAULT is derived from another setting flips silently when you flip that other one
- L552. Pinning a tool's VERSION pins its output only when the tool works locally; one that delegates to a hosted service emits whatever the server makes today.
- L670. A refusal from an INTERMEDIARY in front of an API
- L674. A fault found only when live traffic HAPPENS to exercise a path has a detection delay set by that path's rate, and its recovery is silent.
- L685. A PostgREST upsert is an INSERT, so a PARTIAL row hits every NOT NULL constraint and can never upsert onto an existing row. A refresh is an UPDATE.
- L705. A bulk upsert with rows of DIFFERENT key sets writes NULL into every key a row omits but a sibling carries, so give every row the same keys.
- L496. A lockfile inside a generated or gitignored directory pins nothing, since the only copy is on the machine that made it and CI resolves afresh.
- L499. A framework's error message names the case its author imagined, not the condition it tests, so read the throw site before believing it.
- L726. Send an email's text part quoted-printable, never 7bit long lines: the sending service may hard wrap them, so judge by the raw message that arrived.
