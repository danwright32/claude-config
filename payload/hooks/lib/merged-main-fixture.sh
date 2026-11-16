#!/usr/bin/env bash
#
# merged-main-fixture.sh: the repository a push gate's suite builds to show that a branch answers
# only for its own lines after it merges main in (claude-config#3015).
#
# Sourced by test suites only. No hook uses it.
#
# Every push gate that reads the committed range from the upstream's merge base used to blame a
# branch for whatever main gained since the branch was last pushed, once the branch merged main in.
# Each gate's suite proves its own fix in the same shape, so the shape is built here once rather
# than once per suite, where five copies would drift into five different fixtures (L613):
#
#   mmf_repo <root> <mode> <main path> <main content> [<conflict path> <resolution extra>]
#
# builds <root>/origin.git and <root>/work, and prints <root>/work:
#   1. main holds README.md and <conflict path> ("shared line"), pushed to origin;
#   2. branch feat adds notes/feat.txt and is pushed, so it tracks origin/feat;
#   3. main gains <main path> holding <main content> (the offending line), pushed;
#   4. feat merges origin/main. In mode conflict, each side first edits <conflict path>, and the
#      resolution keeps the branch's line and adds <resolution extra> after it, the line that is
#      still the branch's own and must still be judged. Mode pending builds the same conflict and
#      stages the same resolution but never commits it, so the merge is still in progress
#      (MERGE_HEAD names it), as it is when one command concludes it and pushes,
#      `git commit --no-edit && git push` (claude-config#3062).
# <conflict path> defaults to src/shared.ts. Contents are written with printf '%s', so a caller
# that wants a trailing newline puts one in.
#
#   mmf_built <work> <main path> : 0 when the fixture holds what the cases rest on: the branch
#                                  tracks origin/feat, main's file is in its tree, and exactly one
#                                  merge sits between the upstream and HEAD. Each suite asserts it,
#                                  because a fixture that silently failed to merge would make every
#                                  "the push is allowed" case pass for the wrong reason (L1).

mmf__git() {  # <work> <git args...>
  local w="$1"; shift
  git -C "$w" -c user.name=t -c user.email=t@t.t -c commit.gpgsign=false "$@"
}

mmf__write() {  # <file> <content>
  case "$1" in */*) mkdir -p "${1%/*}" ;; esac
  printf '%s' "$2" > "$1"
}

mmf_repo() {
  local root="$1" mode="$2" main_path="$3" main_content="$4"
  local conflict_path="${5:-src/shared.ts}" extra="${6:-}" w
  w="$root/work"
  mkdir -p "$root"
  git init -q --bare "$root/origin.git" >/dev/null 2>&1
  git init -q -b main "$w" >/dev/null 2>&1
  {
    mmf__write "$w/README.md" $'baseline\n'
    mmf__write "$w/$conflict_path" $'shared line\n'
    mmf__git "$w" add README.md "$conflict_path"
    mmf__git "$w" commit -qm init
    mmf__git "$w" remote add origin "$root/origin.git"
    mmf__git "$w" push -qu origin main

    mmf__git "$w" checkout -qb feat
    mmf__write "$w/notes/feat.txt" $'Feature notes.\n'
    mmf__git "$w" add notes/feat.txt
    mmf__git "$w" commit -qm feat
    mmf__git "$w" push -qu origin feat
    if [ "$mode" = conflict ] || [ "$mode" = pending ]; then
      mmf__write "$w/$conflict_path" $'shared line, as the branch has it\n'
      mmf__git "$w" add "$conflict_path"
      mmf__git "$w" commit -qm "feat edits the shared file"
    fi

    mmf__git "$w" checkout -q main
    mmf__write "$w/$main_path" "$main_content"
    mmf__git "$w" add "$main_path"
    if [ "$mode" = conflict ] || [ "$mode" = pending ]; then
      mmf__write "$w/$conflict_path" $'shared line, as main has it\n'
      mmf__git "$w" add "$conflict_path"
    fi
    mmf__git "$w" commit -qm "main gains a file"
    mmf__git "$w" push -q origin main

    mmf__git "$w" checkout -q feat
    mmf__git "$w" merge -q --no-edit origin/main
    if [ "$mode" = conflict ] || [ "$mode" = pending ]; then
      mmf__write "$w/$conflict_path" "shared line, as the branch has it
$extra"
      mmf__git "$w" add "$conflict_path"
      [ "$mode" = pending ] || mmf__git "$w" commit -q --no-edit
    fi
  } >/dev/null 2>&1
  printf '%s' "$w"
}

mmf_built() {  # <work> <main path>
  [ -e "$1/$2" ] || return 1
  [ "$(git -C "$1" rev-parse --abbrev-ref '@{u}' 2>/dev/null)" = origin/feat ] || return 1
  [ "$(git -C "$1" rev-list --merges --count '@{u}..HEAD' 2>/dev/null)" = 1 ] || return 1
  git -C "$1" diff --quiet HEAD 2>/dev/null || return 1
}

#   mmf_pending <work> <main path> : 0 when a pending fixture holds what its cases rest on: the
#                                    branch tracks origin/feat, the merge of main is still in
#                                    progress (MERGE_HEAD names it), no merge commit sits between
#                                    the upstream and HEAD yet, nothing is left unmerged, and main's
#                                    file is staged for the commit that would conclude the merge.
#                                    Asserted for the same reason as mmf_built (L1).
mmf_pending() {  # <work> <main path>
  [ -e "$1/$2" ] || return 1
  [ "$(git -C "$1" rev-parse --abbrev-ref '@{u}' 2>/dev/null)" = origin/feat ] || return 1
  git -C "$1" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 || return 1
  [ "$(git -C "$1" rev-list --merges --count '@{u}..HEAD' 2>/dev/null)" = 0 ] || return 1
  [ -z "$(git -C "$1" diff --name-only --diff-filter=U 2>/dev/null)" ] || return 1
  # Read into a variable first, never piped into a quiet grep, which can end the producer early and
  # fail the pipeline under pipefail on a fixture that is right (L183).
  local staged
  staged="$(git -C "$1" diff --cached --name-only 2>/dev/null)" || return 1
  case $'\n'"$staged"$'\n' in *$'\n'"$2"$'\n'*) return 0 ;; esac
  return 1
}
