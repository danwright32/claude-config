---
name: nudge
disable-model-invocation: true
description: Reply in a Slack thread as Nudge Bot with a friendly reminder (picked at random from this Mac's own list) when someone posted without tagging the team they needed. Use when the user types /nudge with a Slack message link.
trigger: /nudge
---

# /nudge

```
/nudge <slack message link>
```

Run, with the link exactly as the user gave it:

```
python3 ~/.claude/skills/nudge/nudge.py "<link>"
```

Report the result in one line: on `POSTED`, the line that went out and the link the script printed;
on `NOT POSTED`, the reason it printed, which already says what to do. Never retry a refusal.

It posts one random line, as the Nudge Bot Slack app, in the thread of the linked message (a link
to a reply posts in that reply's thread). Nothing is pinged: the text goes out with `link_names`
off, so a team handle in it stays plain text. The person who started the thread is notified anyway,
because Slack subscribes them to their own thread. It keeps no record and does not check whether
the thread was already nudged (Dan, 2026-10-28: "as lightweight as possible").

## What lives where (this Mac only)

- **Token:** the login Keychain, service `nudge-bot-slack`. Never a file, a command line the user
  sees, or the chat. To replace it, open a placeholder file in BBEdit for the user to paste into,
  then store it with `security add-generic-password -U -s nudge-bot-slack -a "$USER" -w "$(cat <file>)"`
  and delete the file.
- **Lines:** `lines.local.txt` beside this file, one per line, `#` lines skipped. It stays on this
  Mac, because the sync never carries `*.local.*` files, so the team name and the wording never
  reach the shared repository. On a Mac without it the script refuses and names the missing file.
- **Slack app:** "Nudge Bot". `chat:write.public` lets it post in any public channel without
  joining; a private channel needs `/invite @Nudge Bot` once.

Tests: `python3 ~/.claude/hooks/lib/skill-python-tests.py ~/.claude/skills/nudge`.
