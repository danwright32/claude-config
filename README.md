# claude-config-sync

Two-way sync of selected `~/.claude` config between my Macs.

This file says what the tool does. [DESIGN.md](DESIGN.md) says what was tried and rejected, where
every threshold's number came from, and how much each guard is actually proven. Read it before
changing a design decision, so an approach that was already measured and discarded does not come
back.

## What syncs

- `payload/hooks/` — automation scripts
- `payload/skills/` — custom + installed skills (plugin-managed skills excluded, see below)
- `payload/agents/` — the `plan-*` agents
- `payload/commands/` — slash commands
- `payload/settings.hooks.json` — **only** the `hooks` block of `settings.json`, with the home path stored as `__CLAUDE_HOME__` so it works on any Mac
- `payload/CLAUDE.md` and `payload/RTK.md` — your global rules files, synced verbatim (standing cross-project instructions travel here)

## What NEVER syncs (stays private to each Mac)

Memory store, session history, caches, the rest of `settings.json` (model / effort / plugins),
and the local permission list (`settings.local.json`). A `pull` cannot overwrite any of these.

Plugin-managed skills are excluded so plugin updates don't cause churn:
`agents-sdk, cloudflare, cloudflare-email-service, durable-objects, sandbox-sdk,
turnstile-spin, web-perf, workers-best-practices, wrangler, plannotator-compound`
(edit `PLUGIN_SKILLS` in `claude-sync` to change this).

## Use

```bash
./claude-sync push              # send this Mac's config up
./claude-sync pull              # bring shared config down
./claude-sync sync              # two-way: send local, then receive remote
./claude-sync status            # show differences, no changes
./claude-sync install-autosync  # background auto-sync (see below)
```

## Automatic sync

`install-autosync` sets up two launchd agents (and retires older ones), and installs
the `claudesync` shell alias:

- **`com.claudesync.watch`** — an fswatch process that runs a two-way `sync` on
  every change to a synced folder, however deep, so edits push within seconds.
  Requires fswatch: `brew install fswatch` (then re-run `install-autosync`).
- **`com.claudesync.timer`** — a periodic two-way `sync` (default weekly,
  `SYNC_INTERVAL=<seconds>`) so the other Mac's changes arrive even when this Mac
  makes no local edits.

It also adds this to `~/.zshrc`, so the shortcut arrives with the rest of the setup
instead of being added by hand on each Mac (`~/.zshrc` is deliberately not synced):

    alias claudesync='<repo>/claude-sync pull'

That step is idempotent: it never appends a second copy, it treats a `~` and the
expanded home directory as the same path, and if a `claudesync` alias already exists
pointing somewhere else it leaves your line alone and tells you rather than rewriting
your shell config. Override the target file with `SYNC_ZSHRC=<path>`.

Sending is automatic on change; receiving is automatic on the timer. A no-op sync
writes nothing (idempotent), so the watcher never re-triggers itself. On a merge
conflict the background job stops and fires a desktop notification.

## Secret scan

Every push/sync scans the payload and aborts if it finds a credential shape.
Accept a known string by adding the sha256 of the matched text to
`.secret-allowlist`, or bypass once with `SYNC_SKIP_SECRET_SCAN=1`.

## Tests

```bash
bash tests/test-claude-sync.sh
```

Run one part while iterating, which stops after the section you name:

```bash
SECTION_UNTIL="conflict copies" bash tests/test-claude-sync.sh
```

It runs from the start up to and including that section, because the sections build on each
other and running one alone reports failures the code did not cause. A name matching nothing
is an error, not a quiet pass.

One run at a time, and none of them open ended:

| Setting | Default | What it does |
| --- | --- | --- |
| `SUITE_TIMEOUT` | `900` | Seconds before a stalled run is killed and told which section it died in. A full run measured 123 seconds on 2026-08-17, so this is roughly 7x. `0` disables it. |
| `SUITE_LOCK` | `$TMPDIR/claude-sync-suite.lock` | Where the one run at a time lock lives. A second run REFUSES, naming the process that holds it and how long it has been going, rather than queueing. |
| `SUITE_NO_LOCK` | unset | Run without taking the lock. For when you know the run it names has finished. |
| `SUITE_LOCK_MAX_AGE` | `1800` | Seconds after which a lock from ANOTHER machine is broken. A lock from this machine is judged by whether its process is alive, never by the clock, so a clock jump cannot break a live one. |
| `SUITE_MAX_DEPTH` | `1` | How deeply a run may be nested inside another. The suite runs itself as a subprocess in places, and past this it refuses to start rather than multiplying. |

`claude-sync status` also reports watcher processes and test runs the tool left behind, counting
how many started independently and how deeply they are nested. It stays silent for one watcher
and one run, which is what a healthy machine looks like.

## Local state (per Mac, never synced)

Six things hold state outside `payload/`. All are gitignored, so a fresh clone starts without
them. A folder COPIED or RESTORED from a backup carries stale ones, which is why each has a
defined answer for being absent or untrustworthy.

| File | Written by | Read by | Missing or stale |
| --- | --- | --- | --- |
| `.last-applied` | every apply | the guard that blocks sending while behind | absent means nothing is protected yet, so sending is allowed |
| `.last-success` | a successful fetch, and a successful push | the outage clock | absent, unparseable, or dated in the FUTURE all mean "no record", which alerts rather than staying quiet |
| `.outage-log` | every outage decision | `claude-sync status` | absent means no decisions yet, and a line that will not parse is counted and reported as unreadable rather than skipped |
| `.sync-lock/` | any mutating run | every mutating run | a lock from THIS Mac whose process is alive is respected whatever its age; one from another Mac, or with no Mac recorded, is broken once older than an hour |
| `state/` | every apply | nothing reads the local copy; it exists so a marker is only republished when it changes | absent just means the next apply republishes |
| `refs/claude-sync-state` | every apply, pushed per Mac | `claude-sync verify` | nothing published means "cannot be answered", never agreement; a Mac silent for 60 days is reported as retired |

None of this travels between Macs except the published refs, and those deliberately never
land on the config branch: a marker commit there is a commit the other Mac does not have,
which the send guard correctly reads as being behind, and every send is then skipped.
