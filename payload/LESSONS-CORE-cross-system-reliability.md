# Lessons core: Cross-system reliability (generated, do not edit)

The lessons of this section chosen for every session, one SHORTENED line each; the rest are in
the library (~/.claude/LESSONS-INDEX-*.md), and every PR lessons review reads them all. Read
the whole entry before a rule decides anything: `~/claude-config-sync/claude-sync lesson L174`.

- L276. A CI job is priced in the runner's multiplier times its rounded-up minutes, and that price is set before the job is added.
- L512. A process that advances strictly forward and never revisits needs a targeted redo path built in from the start wherever completeness matters downstream.
- L240. A background job killed in the same breath it is started can outlive the kill, and a wait on it then blocks for that job's whole lifetime.
- L321. The pid a shell records for a background job names the WRAPPER, not the work, so start it under job control and signal its process GROUP.
- L235. A background process inherits the stdout it was started with, so one still running holds a capture or a runner's pipe open after its parent exits.
- L33. Make the pair of a database write and an external side effect crash-safe.
- L34. Verify domain and vendor data semantics against real samples before building on them.
- L35. Classify errors once, explicitly.
- L36. An alert that cries wolf gets ignored.
- L635. Measuring how often an alert FIRES says nothing about whether its findings can be ACTED on
- L51. A time based threshold is only as timely as the schedule that evaluates it.
- L66. When several records collapse onto one shared external identifier, decide for EACH fact whether it belongs to the group or to one member.
- L227. A limit cannot be raised on its own
- L519. A repair, backfill or catch-up tool must not take the same exclusion lock as the live job it repairs
- L255. A consumer that gates on an exact SET of accepted format versions turns the producer's next additive bump into a total outage of itself
- L258. A consumer that acknowledges work by DELETING the record makes an absent record mean both "consumed successfully" and "never written"
- L522. A budget calibrated for ONE execution context is wrong when the same code is reached from another, because the platform ceiling differs.
- L533. A job on a sparse schedule whose only remedy is running it again needs an automatic re-attempt in the same period, or one failure costs the interval.
- L386. A scheduled job's DECLARED time is not when it runs, so two scheduled jobs must never be ordered by clock arithmetic between their crons.
- L379. Doing by hand what a tool normally does omits the tool's OTHER writes, most often the record some monitor reads.
- L390. In a two way sync, a file REGENERATED from one side gets none of the protection the mirrored files beside it get.
- L625. A two way mirror transmits what EXISTS and cannot transmit a REMOVAL, so a replica that has not received a deletion restores the deleted item.
- L409. Two primitives giving the same visible exclusion differ in what happens when their HOLDER DIES, so swapping one for the other ships a regression.
- L617. An operation keeping progress in on disk resumable state leaves it behind when killed, and the leftover reads as HEALTHY to every content check.
- L620. When replicating a system's behaviour, enumerate its inputs from what it ACTUALLY consults, never from the upstream source they should come from.
- L423. Configuration INSTALLED into the platform is a COPY, so changing its definition changes nothing until each machine re-runs the installer.
- L1011. Stop a process by the PID you traced, never by matching command text: the match finds nothing and its zero reads as success.
- L640. A migration applied before the code that needs it deploys must leave the DEPLOYED code working, because the two are live together during the deploy.
- L642. In a SQUASH MERGE repo no merged branch is ever an ancestor of main, so every local way of asking whether a branch shipped reports it as UNMERGED.
- L689. Monitor a deadline by the GAP between promised and actual completion, never only whether the work happened: a late job passes an absence check.
- L468. A closing keyword works only before #N or owner/repo#N; a short prefix like repo#N leaves the issue open, so write Closes #N and confirm it closed.
- L469. A manual check saying "open the app" tests whichever same-named copy macOS picks; open it by path, and confirm from that copy's data before recording.
- L470. A process crash is attributed by the runner to whatever item was current, so confirm the named item's body really ran before investigating it.
- L476. A pull request reported as CONFLICTING has no workflow run scheduled at all, so read mergeable before investigating checks that never appear.
- L715. A long running process runs the code it parsed at START, so a guard shipped into its script is inert until it restarts, and nothing says so.
