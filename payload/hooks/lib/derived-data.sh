#!/usr/bin/env bash
# derived-data.sh: which Xcode build caches can never be used again (claude-config#1369).
#
# Sourced, never run. ONE copy of the orphan rule for every project on the Mac. It was LIFTED from
# Overture's scripts/lib/derived-data.sh (overture#2596, closing overture#2585, lesson L114), where it
# was written, tested, and run only inside Overture's own test-all, so the leftovers of every other
# project, and Overture's own whenever its suite had not run lately, stayed on disk. The functions
# keep Overture's names and answers so Overture can source this copy instead of keeping its own
# (that switch is a follow up in the Overture repository, tracked on this repository's #1369,
# which stays open for it). What this copy adds is marked below:
# saying WHY a folder could not be attributed, and keeping an orphan a build may still be using.
# Overture's free space warning (derived_data_space_warning, derived_data_available_gib) is not
# lifted: claude-config has its own warning, check-free-space.sh, and two would disagree.
#
# Why it exists. Xcode keys ~/Library/Developer/Xcode/DerivedData by the workspace's PATH, so every
# agent worktree, scratch copy and temporary gate tree that is ever built starts a fresh folder (about
# 2.5 GB for Overture, 0.9 GB for Ovation), and nothing removes it when the path goes. On 2026-10-19
# Daniels-MacBook-Pro-2 held 30 such folders, about 48.6 GB, all pointing at paths that no longer
# existed. On 2026-08-12 the same leak filled the disk outright (148 GB, 101 of 105 folders dead).
#
# The safety property everything rests on: a folder whose WorkspacePath NO LONGER EXISTS can never be
# reused by anything, so deleting it costs nobody a rebuild. Every other answer, including every
# answer this file cannot work out, keeps the folder.
#
# Nothing in this file runs by itself. derived-data-sweep.sh lists by default and deletes with
# --delete, and since Dan's decision on #1369 (2026-10-20, L9) the low free space warning starts that
# deletion on its own unless FREE_SPACE_DERIVED_DATA_AUTO_DELETE is 0 on the Mac.
#
# Environment, every one a seam so a fixture drives the real functions against a throwaway directory
# and never reaches the real one (L2):
#   XCODE_DERIVED_DATA_ROOT      the DerivedData folder (default ~/Library/Developer/Xcode/DerivedData)
#   DERIVED_DATA_RECENT_MINUTES  an orphan with anything modified this recently is kept (default 60;
#                                0 turns the check off; anything that is not a number keeps everything)
#   DERIVED_DATA_PS              the program asked for the process list (default ps)

# Where Xcode keeps its build output.
derived_data_root() {
  printf '%s' "${XCODE_DERIVED_DATA_ROOT:-${HOME}/Library/Developer/Xcode/DerivedData}"
}

# The workspace one build folder belongs to, or an empty string when that cannot be read.
#
# Empty is the answer for every failure (no plist, no such key, no reader on this machine), because
# the caller treats an unreadable answer as a reason to KEEP. PlistBuddy first because it is the one
# measured against real Xcode output (Overture, 2026-08-12), then plutil, then Python's plistlib,
# which reads the binary and XML forms alike and is what answers on the Linux CI runner, where the
# first two do not exist (added here; Overture's copy ran only on a Mac).
derived_data_workspace_path() {
  local dir="${1:-}"
  local plist="${dir}/info.plist"
  [[ -n "${dir}" && -r "${plist}" ]] || return 0

  local path=""
  if [[ -x /usr/libexec/PlistBuddy ]]; then
    path="$(/usr/libexec/PlistBuddy -c 'Print :WorkspacePath' "${plist}" 2>/dev/null)" || path=""
  fi
  if [[ -z "${path}" ]] && command -v plutil >/dev/null 2>&1; then
    path="$(plutil -extract WorkspacePath raw -o - "${plist}" 2>/dev/null)" || path=""
  fi
  if [[ -z "${path}" ]] && command -v python3 >/dev/null 2>&1; then
    path="$(python3 -I -c '
import plistlib, sys
try:
    with open(sys.argv[1], "rb") as f:
        value = plistlib.load(f).get("WorkspacePath", "")
except Exception:
    value = ""
print(value if isinstance(value, str) else "", end="")
' "${plist}" 2>/dev/null)" || path=""
  fi
  printf '%s' "${path}"
}

# False when the path names a volume that is not currently mounted.
#
# The one way the orphan rule could fail open: an unplugged external drive makes every workspace on
# it look deleted, and its folders would be reclaimed while the work they belong to is fine.
derived_data_volume_is_available() {
  local path="${1:-}" volume
  case "${path}" in
    /Volumes/*)
      volume="/Volumes/$(printf '%s' "${path#/Volumes/}" | cut -d/ -f1)"
      [[ -d "${volume}" ]] || return 1
      ;;
  esac
  return 0
}

# One of: shared-cache, unreadable, live, orphan. Only "orphan" can ever be deleted.
#
#   shared-cache  ModuleCache.noindex and friends. Not keyed by a workspace, shared by every project,
#                 so the orphan rule cannot speak about them and nothing here touches them.
#   unreadable    Anything this file could not settle (derived_data_unreadable_reason says why). Kept.
#   live          The workspace is still on disk. Kept.
#   orphan        The workspace is gone. Nothing can ever use this folder again.
derived_data_classify() {
  local dir="${1:-}"
  [[ -n "${dir}" && -d "${dir}" ]] || { printf 'unreadable'; return 0; }

  case "$(basename "${dir}")" in
    *.noindex) printf 'shared-cache'; return 0 ;;
  esac

  local workspace
  workspace="$(derived_data_workspace_path "${dir}")"
  # A relative path is refused rather than resolved against whatever directory the caller is in.
  if [[ -z "${workspace}" || "${workspace}" != /* ]]; then
    printf 'unreadable'
    return 0
  fi
  if ! derived_data_volume_is_available "${workspace}"; then
    printf 'unreadable'
    return 0
  fi
  if [[ -e "${workspace}" ]]; then
    printf 'live'
  else
    printf 'orphan'
  fi
  return 0
}

# Added here. Why derived_data_classify said "unreadable": one of not-a-folder, no-info-plist,
# no-workspace-path (no key, or an empty one), relative-path, volume-not-mounted, or none when it is
# not unreadable at all. The sweep reports these apart because each asks something different of the
# reader (L11): a missing plist cannot be attributed by anyone, an unplugged drive will come back.
derived_data_unreadable_reason() {
  local dir="${1:-}" workspace
  [[ -n "${dir}" && -d "${dir}" ]] || { printf 'not-a-folder'; return 0; }
  [[ -r "${dir}/info.plist" ]] || { printf 'no-info-plist'; return 0; }
  workspace="$(derived_data_workspace_path "${dir}")"
  [[ -n "${workspace}" ]] || { printf 'no-workspace-path'; return 0; }
  [[ "${workspace}" == /* ]] || { printf 'relative-path'; return 0; }
  derived_data_volume_is_available "${workspace}" || { printf 'volume-not-mounted'; return 0; }
  printf 'none'
}

# Added here. Succeeds, printing why, when a folder may still be in use and must be kept even though
# its workspace is gone; fails, printing nothing, when nothing suggests it is.
#
# Two signs, both from the issue: anything inside written in the last DERIVED_DATA_RECENT_MINUTES
# (searched all the way down, since a build writes deep in Build/Intermediates.noindex and the
# folder's own date does not move for that), or a running xcodebuild whose command line names the
# folder or the workspace it recorded. An xcodebuild started inside a checkout with no path on its
# command line names neither, which is what the recent write check is for.
#
# Every answer it cannot get keeps the folder: a window that is not a number, a search that fails,
# a process list that cannot be read. Read as "nothing is running", each of those would delete under
# a live build (L50, L98).
derived_data_in_use() {
  local dir="${1:-}" minutes="${DERIVED_DATA_RECENT_MINUTES-60}" ps_bin="${DERIVED_DATA_PS:-ps}"
  local workspace found processes line pid

  case "${minutes}" in
    ''|*[!0-9]*) printf 'DERIVED_DATA_RECENT_MINUTES is "%s", not a number, so nothing can say it is idle' "${minutes}"; return 0 ;;
  esac

  if [[ "${minutes}" -gt 0 ]]; then
    # -quit stops at the first match rather than a pipe into head, whose early exit would fail the
    # producer under pipefail (L183).
    found="$(find "${dir}" -mmin "-${minutes}" -print -quit 2>/dev/null)"
    if [[ -n "${found}" ]]; then
      printf 'modified in the last %s minutes' "${minutes}"
      return 0
    fi
    if ! find "${dir}" -maxdepth 0 >/dev/null 2>&1; then
      printf 'could not read whether anything in it changed in the last %s minutes' "${minutes}"
      return 0
    fi
  fi

  if ! processes="$("${ps_bin}" -axo pid=,command= 2>/dev/null)"; then
    printf 'the process list could not be read, so nothing can say no build is using it'
    return 0
  fi
  workspace="$(derived_data_workspace_path "${dir}")"
  while IFS= read -r line; do
    case "${line}" in *xcodebuild*) ;; *) continue ;; esac
    if [[ "${line}" == *"${dir}"* ]] || { [[ -n "${workspace}" ]] && [[ "${line}" == *"${workspace}"* ]]; }; then
      pid="$(printf '%s' "${line}" | awk '{print $1}')"
      printf 'named by a running xcodebuild (pid %s)' "${pid}"
      return 0
    fi
  done <<< "${processes}"
  return 1
}

# Every folder under ROOT whose workspace is gone, one path per line, whether or not it is in use.
derived_data_orphans() {
  local root="${1:-$(derived_data_root)}"
  [[ -d "${root}" ]] || return 0

  local dir
  for dir in "${root}"/*/; do
    dir="${dir%/}"
    [[ -d "${dir}" ]] || continue
    if [[ "$(derived_data_classify "${dir}")" == "orphan" ]]; then
      printf '%s\n' "${dir}"
    fi
  done
  return 0
}

# Added here. The orphans under ROOT that nothing suggests are in use: what --delete removes.
derived_data_reclaimable() {
  local root="${1:-$(derived_data_root)}" dir
  while IFS= read -r dir; do
    [[ -n "${dir}" ]] || continue
    derived_data_in_use "${dir}" >/dev/null || printf '%s\n' "${dir}"
  done < <(derived_data_orphans "${root}")
  return 0
}

# Deletes every reclaimable folder under ROOT and prints how many went. Each one is judged again
# immediately before it is removed, so a build that started since the list was made keeps its
# folder. A folder that cannot be removed is named on stderr and NOT counted, so the number reported
# is what happened rather than what was attempted (L12). Overture's copy had no in use guard.
derived_data_reclaim() {
  local root="${1:-$(derived_data_root)}"
  local removed=0 dir
  while IFS= read -r dir; do
    [[ -n "${dir}" ]] || continue
    if derived_data_remove_if_reclaimable "${dir}" >/dev/null; then
      removed=$((removed + 1))
    fi
  done < <(derived_data_reclaimable "${root}")
  printf '%s\n' "${removed}"
  return 0
}

# Added here. Removes one folder only if it is still an orphan nobody is using, judged now. Succeeds
# when it was removed; fails, saying why on stderr when it tried and could not, when it was not.
derived_data_remove_if_reclaimable() {
  local dir="${1:-}"
  [[ -d "${dir}" ]] || return 1
  [[ "$(derived_data_classify "${dir}")" == "orphan" ]] || return 1
  derived_data_in_use "${dir}" >/dev/null && return 1
  if rm -rf "${dir}" 2>/dev/null && [[ ! -e "${dir}" ]]; then
    return 0
  fi
  echo "derived-data: could not remove ${dir}" >&2
  return 1
}

# Size of a folder in whole KiB, or an empty string when it cannot be read: never zero for a folder
# nobody measured. `du` is an upper bound on what deleting it frees, because APFS clones and hard
# links are counted in full; only df before and after measures the gain.
derived_data_size_kib() {
  local path="${1:-}" kib
  [[ -d "${path}" ]] || return 0
  kib="$(du -sk "${path}" 2>/dev/null | awk '{print $1}')" || kib=""
  [[ "${kib}" =~ ^[0-9]+$ ]] || return 0
  printf '%s' "${kib}"
}

# The same in whole MiB, kept under Overture's name so its report can use this copy unchanged.
derived_data_size_mib() {
  local kib
  kib="$(derived_data_size_kib "${1:-}")"
  [[ -n "${kib}" ]] || return 0
  printf '%s' "$((kib / 1024))"
}
