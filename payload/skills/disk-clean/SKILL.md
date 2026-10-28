---
name: disk-clean
description: Being built and not ready to use (Disk cleanup skill milestone, claude-config#1804). Do not invoke it; for a full or nearly full disk use the disk-full skill.
disable-model-invocation: true
---

# disk-clean

Not ready. This placeholder exists so the skill's folder can sync while it is being built: the
config sync refuses to carry a skills folder that holds no SKILL.md. Phase #1808 replaces it with the
real skill.

What is here so far, for whoever builds the next phase:

- `scan.sh`: the read only scan (#1806). It writes `~/.claude/state/disk-clean/last-scan.json` and
  removes nothing.
- `categories/<name>.sh`: one module per category, each answering `scan` and `judge <target>`.
- `scan-lib.sh`: what the scan and the modules share.

Removal is `~/.claude/hooks/lib/disk-remove.sh`, never anything in this folder.
