# claude-config

The shared `~/.claude` config for both Macs, and `claude-sync`, the tool that moves it between
them. Everything under `payload/` is installed into `~/.claude`; everything outside it belongs to
the repository and is never installed.

## There are two CLAUDE.md files here, and they are not the same file

- `payload/CLAUDE.md` is the global config that loads into every session in every project on both
  Macs. Changing it changes how Claude behaves everywhere.
- `CLAUDE.md` at the root, this file, describes this repository and loads only in sessions here.

Check which one a change is meant for before editing. They are one directory apart.

## Where things are

- `payload/` is the config: the global `CLAUDE.md`, the `LESSONS-INDEX-*.md` files that load into
  every session, the full `LESSONS.md` that deliberately does not, plus `hooks/`, `skills/`,
  `commands/`, `agents/`, and `settings.hooks.json`, which is named `settings.json` once installed.
- `claude-sync` is the whole sync tool, one bash script at the repository root.
- `README.md` is the operator's manual and `DESIGN.md` the design record. Both are long, both are
  current, and the section covering whatever is being changed is worth reading first.
- `tests/` and `tools/` hold suites and helpers that are not installed anywhere.

## Build and test

There is nothing to build. Every suite in the repository runs with:

    bash payload/hooks/run-all-tests.sh

Suites are discovered from disk by the `test-*.sh` name across the whole repository, never from a
list, so a suite added anywhere runs on the day it lands. A new suite named any other way is run by
nothing.

Read a lesson in full, rather than its shortened index line, with:

    ~/claude-config-sync/claude-sync lesson L174

## What to know before editing

- Editing a file under `payload/` does not change the session doing the editing. Rule files are
  read once at startup and a running session keeps the copy it loaded, so a change takes effect on
  a pull and a new session. `hooks/rule-files-changed.sh` says when this session's copy has gone
  stale.
- `~/claude-config-sync` is a second clone of this same repository and is the one the scheduled
  sync actually runs from. This checkout is where the work is done.
- The sync mirrors the payload, and what the payload does not carry is deleted on the other Mac.
  An exclusion therefore has to come from the receiving side, not from leaving a file out.
- The hooks that gate a push (tests, style, issue fields) run from the installed copy in
  `~/.claude`, not from this checkout, so a hook fixed here still blocks until it is installed.
