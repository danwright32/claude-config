#!/usr/bin/env bash
#
# fixture-runner-home.sh: a config folder of its own for every run of run-all-tests.sh that a suite
# starts against fixture suites (claude-config#1970).
#
# run-all-tests.sh brackets the live stores of the config it is asked about: the rule files and
# settings.json under CLAUDE_HOME, and, only when that is this user's own ~/.claude, the clone
# register, the shell rc and the watcher's two markers in HOME. A suite that tests the runner starts
# it against fixture suites over and over (151 launches from test-run-all-tests.sh in one traced full
# run on 2026-10-31, and none from any other suite), and with CLAUDE_HOME left alone every one of
# those launches bracketed Dan's real ~/.claude. Under the
# full runner that is harmless since #1964, which leaves those stores to the enclosing run. Run on its
# own, the way builders run one suite, nothing encloses it, so each fixture run judges the real folder
# over its own short window, and the only change it can ever see there is somebody else's: a
# scheduled sync install, or Claude Code saving a picked setting, fails a fixture case that has
# nothing to do with either.
#
# So a suite that starts the runner against fixtures sources this and calls fixture_runner_home once,
# before its first launch, and every launch after inherits a throwaway config folder. Nothing a
# fixture run brackets is then a store anybody else writes.
#
# WHAT THE FOLDER CARRIES. The runner reads nothing from CLAUDE_HOME but the live stores it brackets
# (CLAUDE.md, LESSONS.md, LESSONS-INDEX.md, LESSONS-CORE.txt, each LESSONS-INDEX-*.md and
# LESSONS-CORE-*.md, settings.json), so that is what is planted here, each holding a little content,
# so a fixture run reads and compares real files as it did against the real folder rather than
# recording every store as absent. settings.json is a JSON object with a hooks block, the shape the
# runner's settings reading expects of a real Mac's. The Mac's own stores (the clone register, shell
# rc, watcher marker and hold file) are named through their seams, under the same throwaway folder,
# so an inherited seam cannot point a fixture run at the real ones either; the register names no
# clone, so no sync apply can ever excuse a change a fixture run sees. The one thing a run WRITES
# there is the full suite slot's queue, under state/full-run-slot, and only for a whole run
# (claude-config#2012), so a fixture's whole run queues in this folder, never behind this Mac's real
# runs.
#
# What this gives up, deliberately: a FIXTURE suite that writes the real ~/.claude is no longer
# caught by the fixture run around it. Those fixtures are written by the suite that starts them, and
# the guard on a suite writing the real folder is the run that suite itself is part of, whose window
# contains every fixture run's (#1964). A suite run on its own has no such run around it, before
# this change or after.
#
# A case that is ABOUT a home or a seam still names its own on the launch, which overrides this.
#
# Sourced, never executed.

# fixture_runner_home <throwaway dir>: plants the config folder and the Mac's stores under that
# directory and exports CLAUDE_HOME and every Mac store seam at them. Refuses, exporting nothing, a
# directory that is empty, the root, the home folder, or this user's own config folder.
fixture_runner_home(){
  local root="${1%/}"
  case "$root" in
    ''|/|"${HOME%/}"|"${HOME%/}/.claude")
      echo "fixture_runner_home: refusing '${1:-}', which is not a throwaway directory: a fixture run's config folder must never be a real one." >&2
      return 1 ;;
  esac
  mkdir -p "$root/claude-home" "$root/mac" || {
    echo "fixture_runner_home: could not create $root/claude-home, so the fixture runs would have no config folder of their own." >&2
    return 1
  }
  local h="$root/claude-home" f
  printf '# A fixture config folder (claude-config#1970)\n\nNothing here is a real rule.\n' > "$h/CLAUDE.md"
  printf '# Lessons\n\n## A section\n\n- L1. A fixture lesson.\n' > "$h/LESSONS.md"
  printf '# Lessons index: a section (generated)\n\n- L1. A fixture lesson.\n' > "$h/LESSONS-INDEX-a-section.md"
  printf '# Lessons core: a section (generated)\n\n- L1. A fixture lesson.\n' > "$h/LESSONS-CORE-a-section.md"
  printf 'L1\n' > "$h/LESSONS-CORE.txt"
  printf '{\n  "model": "opus",\n  "hooks": {}\n}\n' > "$h/settings.json"
  for f in CLAUDE.md LESSONS.md LESSONS-INDEX-a-section.md LESSONS-CORE-a-section.md LESSONS-CORE.txt settings.json; do
    [ -s "$h/$f" ] || {
      echo "fixture_runner_home: could not write $h/$f." >&2
      return 1
    }
  done
  : > "$root/mac/claude-sync-clones"
  printf '# a fixture shell rc\n' > "$root/mac/zshrc"
  export CLAUDE_HOME="$h"
  export SYNC_CLONE_REGISTRY="$root/mac/claude-sync-clones"
  export SYNC_ZSHRC="$root/mac/zshrc"
  export SYNC_WATCH_PID_FILE="$root/mac/claude-sync-watch.pid"
  export SYNC_HOLD_FILE="$root/mac/claude-sync-hold"
}
