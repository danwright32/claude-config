#!/usr/bin/env bash
#
# check-public-assets.sh
# Claude Code PreToolUse(Bash) hook.
#
# Goal: block a `git push` that leaves a served asset nothing references, or that adds or changes a
# raster image over the size cap (claude-config#429). L29 (dead code is worse than deleted code) had
# no check for assets: the dev team review of Slate (Denys Botsiun, 2026-09-18, Try-Pennie/slate#2561)
# found three logo SVGs nobody referenced and a 594 KB JPEG for one hero image, and nothing in any
# project measured either.
#
# The detector is lib/public-assets.py; this file only works out WHICH push and WHICH range, and
# turns the detector's answer into a refusal or a line. The rules, the exclusions and every
# measurement behind them are in that file's docstring. In short:
#
#   - Fires in every repo, on every push, and works out the repo's shape itself: `public/`,
#     `static/` or `assets/` at the root. No opt in file, nothing to remember to run.
#   - Compares the pushed tree (HEAD) with its merge-base, not a stored baseline, so a push fails
#     only on what IT did: adding an unreferenced asset, removing the last reference to one, or
#     adding or changing an image over the cap. A repo's existing dead assets are counted in the
#     summary and left alone.
#   - Cap: 250 KB (decimal), measured on Slate main 2026-09-18. The two rasters under `public/`
#     are 14 KB and 594 KB, so the cap sits in the gap between an icon and the review's finding
#     with room either side; the 186 tracked rasters elsewhere in the tree (review screenshots up
#     to 1.9 MB under `.claude/`, a 1.2 MB icon master) are not served and are out of scope.
#   - `.claude/` never counts as a reference. Measured: with it counted, the detector finds none of
#     the three SVGs, because the brand redesign planning docs name every one of them.
#   - Runtime on Slate main (2,204 tracked files): about 1.5 s wall, 0.4 s of it python.
#
# Allowlist: `.claude/hygiene-allow.txt` in the repo, one path or glob per line, a reason after a
# `#` (required). For an asset only loaded from outside the repo (a widget a partner page embeds, a
# file fetched by name) or an image that genuinely has to be that large.
#
# A chained `git commit && git push` is judged on the commits that exist when the hook runs, so an
# asset added by THAT commit is judged on the next push. A push on its own is the ordinary case.
#
# Outcomes (L11, L98):
#   clean          exit 0, the summary line on stdout (kept in the transcript).
#   nothing to judge (no asset directory)
#                  exit 0, ONE line on stdout saying so. Not stderr: Claude Code discards a
#                  PreToolUse hook's stderr on exit 0, so a line there would be theatre.
#   could not measure
#                  exit 1 with one line on stderr. A non-blocking error: the push runs and the first
#                  stderr line surfaces as a hook notice, the same shape require-tests-before-push.sh
#                  uses. Reserved for a detector that wanted to decide and could not.
#   findings       exit 2, the refusal on stderr, naming each file and what to do.
#
# Override: SKIP_ASSET_CHECK=1 git push ...  Explain to the user first, never skip silently.

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The detector, replaceable from the environment so the test can drive the arms below that a real
# repository cannot reach (a detector that could not measure, a detector that crashed).
SCANNER="${PUBLIC_ASSETS_SCANNER:-$HOOK_DIR/lib/public-assets.py}"

did_not_run() {
  echo "ASSET CHECK DID NOT RUN ($1). Push allowed ungated." >&2
  exit 1
}

# shellcheck source=lib/push-scope.sh
. "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null || did_not_run "shared push-scope library missing"

payload="$(cat)"
parsed="$(ps_parse_payload "$payload" segmented)" || exit 0
cmd="${parsed%%$'\x1f'*}"
cwd="${parsed#*$'\x1f'}"
[ -n "$cmd" ] || exit 0

ps_is_git_push "$cmd" || exit 0
if ps_has_override "$cmd" SKIP_ASSET_CHECK; then
  exit 0
fi

# The repo comes from the command first and the session cwd second, through the shared helper, so a
# `cd <repo> && git push` from a session rooted elsewhere is judged like any other push.
repo_dir="$(ps_repo_dir "$cmd" "$cwd")" || exit 0
[ -n "$repo_dir" ] || exit 0
cd "$repo_dir" 2>/dev/null || exit 0

[ -f "$SCANNER" ] || did_not_run "detector $SCANNER missing"
command -v python3 >/dev/null 2>&1 || did_not_run "python3 not found"

base="$(ps_base_ref || true)"
mb="$(ps_merge_base "$base")"

out="$(python3 "$SCANNER" --repo "$repo_dir" --head HEAD --base "$mb" 2>&1)"
rc=$?

# A judged run always ends with the detector's "Checked ..." summary. Python exits 1 on an uncaught
# exception too, so exit 1 WITHOUT that line is a crash, not a set of findings, and is reported as
# not having run rather than turned into a refusal about something nobody measured (L11).
summary="$(printf '%s\n' "$out" | awk '/^Checked /{s = $0} END{print s}')"
last_line="$(printf '%s\n' "$out" | awk 'NF{s = $0} END{print s}')"

case "$rc" in
  0)
    printf '%s\n' "$out"
    exit 0 ;;
  2)
    printf 'ASSET CHECK SKIPPED: %s\n' "$out"
    exit 0 ;;
  1)
    [ -n "$summary" ] || did_not_run "detector exited 1 without a summary: $last_line" ;;
  3)
    did_not_run "$(printf '%s\n' "$out" | awk 'NR == 1')" ;;
  *)
    did_not_run "detector exited $rc: $last_line" ;;
esac

# Say only what was measured: the headline is built from the kinds of finding actually present.
unref=0; oversize=0
while IFS= read -r line; do
  case "$line" in
    *"references it"*) unref=1 ;;
    *"over the "*" cap"*) oversize=1 ;;
  esac
done <<< "$out"
# Findings this hook cannot classify are not something it can write a refusal about.
[ "$unref" -eq 1 ] || [ "$oversize" -eq 1 ] || did_not_run "detector reported findings this hook could not read: $last_line"

{
  if [ "$unref" -eq 1 ] && [ "$oversize" -eq 1 ]; then
    echo "PUSH BLOCKED: this push leaves a served asset that nothing references, and carries an"
    echo "image over the size cap."
  elif [ "$unref" -eq 1 ]; then
    echo "PUSH BLOCKED: this push leaves a served asset that nothing in the repo references."
  else
    echo "PUSH BLOCKED: this push carries an image over the size cap."
  fi
  echo ""
  printf '%s\n' "$out"
  echo ""
  echo "What to do:"
  if [ "$unref" -eq 1 ]; then
    echo "  - An asset nothing references: delete it, or reference it from the code that should load"
    echo "    it (by its served path, such as /brand/x.svg, or by its file name)."
  fi
  if [ "$oversize" -eq 1 ]; then
    echo "  - An image over the cap: re-encode it at the size it is displayed (WebP or AVIF) and"
    echo "    commit the smaller file."
  fi
  echo "  - An asset only loaded from outside this repo (a script a partner page embeds, a file"
  echo "    fetched by name), or an image that has to be this large: add a line to"
  echo "    .claude/hygiene-allow.txt in this repo, with the reason after a #, then push again:"
  echo "        public/widget.js  # loaded by partner landing pages, never referenced here"
  echo "OVERRIDE: if this is a false positive, re-run with:"
  echo "    SKIP_ASSET_CHECK=1 <your original git push command>"
  echo "BEFORE overriding you MUST explain to the user, in plain non-technical"
  echo "language, WHY skipping is legitimate here, so they can judge whether it"
  echo "makes sense. Never override silently."
} >&2
exit 2
