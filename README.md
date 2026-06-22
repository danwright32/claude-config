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
./claude-sync pull              # bring shared config down (auto-runs on schedule)
./claude-sync status            # show differences, no changes
./claude-sync install-schedule  # set up the daily auto-pull
```

`pull` happens automatically on a schedule; run `push` by hand after a big change.

## Tests

```bash
bash tests/test-claude-sync.sh
```
