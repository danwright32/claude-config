#!/usr/bin/env bash
# settings-file.sh: which file holds the hooks block beside a copy of the hooks (claude-config#1237).
#
# Sourced by the hook suites, never run. In the repository the hooks block is
# payload/settings.hooks.json; installed under ~/.claude it is the "hooks" key of settings.json, the
# file Claude Code actually reads. claude-sync runs these suites from the installed copy after every
# pull, so a suite naming only the repository's spelling fails there, or declares itself not run, on
# every Mac. Fifteen suites wrote the lookup out for themselves, three of them with the repository's
# spelling alone (measured 2026-10-16); this is the one copy, and test-settings-file.sh fails on a
# suite that writes the path out again.
#
#   hook_settings_file <dir>   prints the settings file in <dir>, the directory the hooks directory
#                              sits in, and returns 1, printing nothing, when <dir> holds neither.
#
# settings.hooks.json wins where both exist: inside the checkout it is the statement of what the sync
# will install, and an installed copy beside it would answer for an older version.
hook_settings_file() {
  local dir="${1%/}" f
  for f in "$dir/settings.hooks.json" "$dir/settings.json"; do
    if [ -f "$f" ]; then
      printf '%s\n' "$f"
      return 0
    fi
  done
  return 1
}
