#!/usr/bin/env bash
#
# unmanaged-skills.sh: the entries under skills/ that claude-sync never carries (claude-config#415).
#
# ONE list, read by every one of the things that have to agree about it (L41):
#   claude-sync          sources the copy in its OWN checkout's payload/hooks/lib, because that
#                        checkout is what defines what a send carries. It does not fall back to the
#                        copy installed under the live config: an older list there would silently
#                        change what is sent.
#   check-home-paths.sh  sources the copy beside itself, which is payload/hooks/lib in the repo and
#                        ~/.claude/hooks/lib on a Mac, where no repo sits beside it. hooks/ is a
#                        mirrored directory, so the installed copy is the one the last apply wrote.
#   the skill scans      test-gates-fail-closed.sh and test-python-bad-bytes.sh read every script
#                        under skills/, which on a Mac includes what the sync leaves alone, so they
#                        filter what they read through carried_skill_paths (claude-config#2001).
#
# Before this file the two disagreed: the sync left the Claude app's downloaded skills out of every
# send, and the check scanned them anyway, so a login to a second account (which downloads that
# account's skills) failed the hook suite on a file no send will ever publish (L36).
#
# What each side does when this file cannot be read is decided by that side, and written there.
#
# Sourced, never executed. Defines UNMANAGED_SKILLS_LIB_LOADED last, so a reader can tell a file
# that was sourced to the end from one that was truncated or is something else under this name.

# Skills that the plugins install and manage, excluded so the repo stays clean and plugin updates
# do not create churn. Edit this list if you install one of these standalone and want it synced.
PLUGIN_SKILLS=(agents-sdk cloudflare cloudflare-email-service durable-objects \
  sandbox-sdk turnstile-spin web-perf workers-best-practices wrangler \
  plannotator-compound)

# Top level entries under skills/ that the Claude app itself downloads and maintains on each Mac:
# skills/synced/<bucket>/ holds the account's built in skills (docx, pptx, pdf and the rest) plus
# a manifest.json the app rewrites. They are not config, each Mac fetches its own, and the app
# names the bucket after the account, so carrying them would only ship a second copy for the app
# to fight over. Seen on Dans-MacBook-Pro 2026-09-16, when a pull announced about 200 of those
# files as unsent local edits bound for the shared repo. Matched at the TOP of skills/ only: a
# folder that happens to be called `synced` inside a real skill is ordinary config.
PLATFORM_SKILL_DIRS=(synced)

# Where Claude Code sets aside a skill it removes or replaces on the Mac it runs on:
# skills/.trash/<stamp>/<skill>/. Per Mac working state, never config. On 2026-10-09 a send from
# the work MacBook carried one to the shared repo holding copies of four plugin skills
# (claude-config#1009). Matched at ANY depth under skills/, like the plugin skills, because a .trash
# folder inside a skill is the same thing in a different place. Left out by the send and by the
# apply alike: the apply mirrors with --delete, so an exclusion on the sending side alone would
# have each pull delete the receiving Mac's own .trash.
SKILL_TRASH_DIRS=(.trash)

# One answer to "does the sync leave this skills/ entry alone entirely", for every reader that
# walks skills/ by name, so a new kind of unmanaged entry is added once rather than per loop.
unmanaged_skill_entry(){   # $1 = a top level name under skills/
  local s
  for s in "${PLUGIN_SKILLS[@]}" "${PLATFORM_SKILL_DIRS[@]}" "${SKILL_TRASH_DIRS[@]}"; do [ "$1" = "$s" ] && return 0; done
  return 1
}

# The rsync excludes, and the one statement of how each list is MATCHED. Plugin skill names stay
# unanchored as they always were, so rsync drops them at any depth, and so does a .trash folder; the platform's entries are
# anchored to the top of skills/ with a leading slash, for the reason given where
# PLATFORM_SKILL_DIRS is defined. check-home-paths.sh reads these lines rather than the arrays, so
# the check follows whatever anchoring is written here.
skill_excludes(){
  local s
  for s in "${PLUGIN_SKILLS[@]}" "${SKILL_TRASH_DIRS[@]}"; do printf -- "--exclude=%s\n" "$s"; done
  for s in "${PLATFORM_SKILL_DIRS[@]}"; do printf -- "--exclude=/%s\n" "$s"; done
}

# The same lines read as names, for every reader that walks skills/ itself rather than through
# rsync: check-home-paths.sh and the scans in test-gates-fail-closed.sh and test-python-bad-bytes.sh
# (claude-config#2001). Read off skill_excludes, so they match what rsync leaves out: a line
# `--exclude=/NAME` goes into SKILL_EXCLUDE_TOP (only the entry at the top of skills/), and a line
# `--exclude=NAME` into SKILL_EXCLUDE_ANY (any file or folder of that name at any depth).
skill_exclude_names(){
  local ex name excludes
  SKILL_EXCLUDE_TOP=()
  SKILL_EXCLUDE_ANY=()
  # Read whole first, then fed from a here document: bash 3.2 never waits for a process
  # substitution's child, and its exit can cut short what the caller prints (L1035, #1984).
  excludes="$(skill_excludes)" || true
  while IFS= read -r ex; do
    name="${ex#--exclude=}"
    case "$name" in
      '') ;;
      /*) SKILL_EXCLUDE_TOP+=("${name#/}") ;;
      *)  SKILL_EXCLUDE_ANY+=("$name") ;;
    esac
  done <<EXCLUDES
$excludes
EXCLUDES
}

# A filter: paths on stdin, one per line, and out only those the sync carries. $1 is the skills
# folder the paths sit under; a path not under it is passed through, since it is not this list's to
# judge.
carried_skill_paths(){   # $1 = the skills folder
  local root="${1%/}" p rel n skip
  [ -n "$root" ] || { echo "carried_skill_paths: no skills folder was named, so nothing can be judged" >&2; return 2; }
  skill_exclude_names
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    rel="${p#"$root"/}"
    skip=0
    if [ "$rel" != "$p" ]; then
      for n in ${SKILL_EXCLUDE_TOP[@]+"${SKILL_EXCLUDE_TOP[@]}"}; do
        case "$rel/" in "$n"/*) skip=1; break ;; esac
      done
      [ "$skip" -eq 1 ] || for n in ${SKILL_EXCLUDE_ANY[@]+"${SKILL_EXCLUDE_ANY[@]}"}; do
        case "/$rel/" in *"/$n/"*) skip=1; break ;; esac
      done
    fi
    [ "$skip" -eq 1 ] || printf '%s\n' "$p"
  done
}

UNMANAGED_SKILLS_LIB_LOADED=1
