# Lessons core: External systems (generated, do not edit)

The lessons of this section chosen for every session, one SHORTENED line each; the rest are in
the library (~/.claude/LESSONS-INDEX-*.md), and every PR lessons review reads them all. Read
the whole entry before a rule decides anything: `~/claude-config-sync/claude-sync lesson L174`.

- L477. A browser error reporter files every uncaught error on the page as yours, including a host in-app browser's injected script: check your bundle first.
- L513. A value a platform REPORTS is what is currently configured, never what is available
- L24. State the expected data volume before writing any query or loop.
- L81. A batch must be sized in the UNIT the limit is actually expressed in, measured from the real inputs, never in a proxy unit calibrated on one sample.
- L87. A change that multiplies how many items a request carries inherits that request's aggregate limit, and proving it correct says nothing about the fit.
- L237. Addressing something by its POSITION measures whatever currently occupies that position, so prove the thing you named is there, and refuse if not.
- L193. A feature resolving user values through a stored REFERENCE dataset is only as complete as that dataset, so measure the join's real hit rate first.
- L265. Before building a path that carries on past an external service's negative verdict, check whether that service is also the GATE on the action
- L271. A cross repository deliverable phrased as what YOUR side must WRITE says nothing about whether the consuming side can READ it
- L280. A rule enforced at ONE stage of a pipeline is not enforced by the pipeline: every later stage that rewrites the content can reintroduce it.
- L534. A platform setting whose DEFAULT is derived from another setting flips silently when you flip that other one
- L552. Pinning a tool's VERSION pins its output only when the tool works locally; one that delegates to a hosted service emits whatever the server makes today.
- L670. A refusal from an INTERMEDIARY in front of an API
- L674. A fault found only when live traffic HAPPENS to exercise a path has a detection delay set by that path's rate, and its recovery is silent.
- L496. A lockfile inside a generated or gitignored directory pins nothing, since the only copy is on the machine that made it and CI resolves afresh.
- L499. A framework's error message names the case its author imagined, not the condition it tests, so read the throw site before believing it.
- L726. Gmail's send API drops quoted-printable and hard wraps plain text at ~72; send an HTML part, and judge only the delivered raw.
