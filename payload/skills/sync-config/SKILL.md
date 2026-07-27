---
name: sync-config
description: Use when the user asks to sync, pull, or update their shared ~/.claude config across Macs (e.g. "/sync-config", "sync my config", "pull my claude config", "claudesync"). Runs `claude-sync pull` and reports what changed.
---

# sync-config

Pulls the shared `~/.claude` config (hooks, skills, agents, commands, CLAUDE.md, RTK.md) from the config-sync repo onto this Mac.

## What to run

```bash
~/claude-config-sync/claude-sync pull
```

This brings the shared repo's config onto THIS Mac. It never touches the memory store, session history, caches, or the local permission list.

## Steps

1. Run the command above.
2. If it succeeds, relay the script's received-changes summary in plain language: it prints "Received changes from the shared repo:" followed by one line per file (added / updated / removed / renamed). If it prints "Already up to date", tell the user nothing new had to be pulled.
3. If it fails, surface the error verbatim and the likely cause. Common ones:
   - merge/conflict in the sync repo → tell the user, do not force anything.
   - secret-scan block → a credential was detected; report it, do not bypass.
4. If config files changed, note that some Claude Code changes (hooks, settings) may need a new session to take full effect.

## Notes

- This is the same action as the `claudesync` terminal alias.
- For the less-frequent operations (`push`, `status`, `sync`), run `~/claude-config-sync/claude-sync <cmd>` directly; this skill is pull-only by design.
- Do not bypass the script's secret scan or git safety checks.
