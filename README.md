# claude-config-sync

Two-way sync of selected `~/.claude` config between my Macs.

## What syncs

- `payload/hooks/` — automation scripts
- `payload/skills/` — custom + installed skills (plugin-managed skills excluded, see below)
- `payload/agents/` — the `plan-*` agents
- `payload/commands/` — slash commands
- `payload/settings.hooks.json` — **only** the `hooks` block of `settings.json`, with the home path stored as `__CLAUDE_HOME__` so it works on any Mac

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

`install-autosync` sets up two launchd agents (and retires older ones):

- **`com.claudesync.watch`** — an fswatch process that runs a two-way `sync` on
  every change to a synced folder, however deep, so edits push within seconds.
  Requires fswatch: `brew install fswatch` (then re-run `install-autosync`).
- **`com.claudesync.timer`** — a periodic two-way `sync` (default weekly,
  `SYNC_INTERVAL=<seconds>`) so the other Mac's changes arrive even when this Mac
  makes no local edits.

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
