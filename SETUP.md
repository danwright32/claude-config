# Setup — shared between two GitHub accounts

The repo is **owned by the OTHER Mac's account** and this Mac (`dwright-pennie`)
is added as a collaborator. Replace `danwright32` below with the other account's
GitHub username.

---

## Step 1 — ON THE OTHER MAC (its own account): create the repo + invite this Mac

```bash
# make sure gh is logged into the OTHER account
gh auth status

# create the empty private repo under the other account
gh repo create claude-config-sync --private

# give this Mac's account write access
gh api -X PUT repos/danwright32/claude-config/collaborators/dwright-pennie \
  -f permission=push
```

Then tell me the username `danwright32`. I'll finish Step 2 from this Mac.

---

## Step 2 — ON THIS MAC (`dwright-pennie`): accept invite, push the content

(I run these for you once I have the username.)

```bash
# accept the collaborator invite
inv=$(gh api user/repository_invitations --jq '.[] | select(.repository.name=="claude-config-sync") | .id')
gh api -X PATCH "user/repository_invitations/$inv"

# wire up the remote and push the already-built repo
cd ~/claude-config-sync
git branch -M main
git remote add origin https://github.com/danwright32/claude-config.git
git push -u origin main

# turn on monthly auto-pull on this Mac
./claude-sync install-schedule
```

---

## Step 3 — ON THE OTHER MAC: clone and do the first pull

> ⚠️ First-sync direction: `pull` makes the other Mac's hooks/skills/agents/commands
> **match this Mac's**. Any custom skill that exists ONLY on the other Mac (and isn't
> a plugin skill) would be removed locally. If the other Mac has keepers, run
> `./claude-sync push` there FIRST to send them up, before this Mac pushes — or just
> back up `~/.claude/skills` first. If you want this Mac to be the source of truth,
> skip straight to pull.

```bash
git clone https://github.com/danwright32/claude-config.git ~/claude-config-sync
cd ~/claude-config-sync
./claude-sync pull               # brings shared config onto the other Mac
./claude-sync install-schedule   # monthly auto-pull there too
```

---

## Daily use, from then on

```bash
cd ~/claude-config-sync
./claude-sync push     # after a big change, send it up (run by hand)
./claude-sync pull     # get the other Mac's changes (also runs monthly on its own)
./claude-sync status   # preview differences, changes nothing
```

## Note — this only syncs skills/hooks/agents/commands

It does NOT install plugins, `rtk`, `terminal-notifier`, the `cc` alias, MCP servers,
or your global `CLAUDE.md`. For a brand-new Mac, do those once from the transfer
bundle (`~/Downloads/claude-setup-INSTRUCTIONS.txt`), then use this repo for ongoing
sync of the parts you chose.
