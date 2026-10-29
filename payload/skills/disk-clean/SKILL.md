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
- `review-check.sh`: takes the selection pasted from the review page and either refuses it (exit 2
  unusable, 3 not the last scan, 4 nonce from another copy of the page, 5 count does not match the
  ids, 6 an id not offerable now, 7 nothing chosen) or writes disk-remove's plan and prints what
  it will remove, by category and by path (#1807).
- `review-page.sh --out <folder> [--clear-clipboard]`: renders the last scan into the one review
  page, `review-page.html` filled in, with its nonce beside it, drawn to the design Dan settled
  (`docs/design/disk-clean-review-page.html`). Exit 0 written, 3 written but the clipboard could
  not be cleared, 2 refused (#1807).
- `review-lib.sh`: the nonce a review page carries (`dcrv_write_nonce`, `dcrv_read_nonce`),
  clearing the clipboard before the page opens (`dcrv_clear_clipboard`), and the words for an
  item's size and marks.

Removal is `~/.claude/hooks/lib/disk-remove.sh`, never anything in this folder.
