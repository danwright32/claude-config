#!/usr/bin/env bash
#
# check-bundle-budget.sh
# Claude Code PreToolUse(Bash) hook.
#
# Goal: block a `git push` whose client bundle has grown past a recorded budget, so a dependency
# joining the customer facing hot path is caught on the day it lands rather than by an outside
# reviewer (claude-config#432). Slate shipped Luxon in the embed bundle and nobody knew until
# Try-Pennie/slate#2566 said so: no project measured what its client bundle weighed, so the
# addition passed every green check.
#
# WHAT IT MEASURES. The summed gzipped size of the client chunks the build left behind, in exactly
# two shapes: Next.js (`.next/static/chunks/**/*.js`, or the OpenNext copy under
# `.open-next/assets/_next/static/chunks/`) and Vite (`dist/assets/*.js`). Any other build output
# is refused by NAME and not judged, so a wrong directory can never produce a confident number. The
# measurer is lib/bundle-budget.py (python3, gzip from the stdlib); the rule lives there, once, and
# the test drives it through this hook.
#
# IT ONLY MEANS SOMETHING AFTER A BUILD. A build tree has two verdicts, before and after a build
# (L461). The newest chunk's mtime is compared with HEAD's commit time (`git log -1 --format=%ct`):
# a build older than the commit being pushed is reported as stale and nothing is judged, and no
# build output at all is one skip line. Both exit 0, in their own words, so neither can be read as
# a pass (L98, L11). When the command commits before it pushes, HEAD is still the previous commit,
# so the build is judged against that: fresh enough to be about this tree, not this exact commit.
#
# THE RECORD (a stored baseline, which this guard cannot avoid: there is no merge-base to diff a
# build against). One file per repository at
#     $HOME/.claude/state/bundle-budget/<sha256 of the origin remote URL>.txt
# holding the last accepted total and the date, in the shared ratchet's `<path>: <count>` shape
# (lib/ratchet.py reads it). The first measurement records and passes, saying so. The record only
# ever goes DOWN on its own (a smaller total replaces it) or is raised by the acceptance hatch
# below, so growth inside the margin never ratchets the budget upward one small step at a time.
# BUNDLE_BUDGET_STATE_DIR overrides the directory, which is how the test keeps its records out of
# the real home.
#
# THE MARGINS, measured 2026-09-18 on the Slate checkout's build of 2026-09-06 (34 chunks in
# .next/static/chunks, and the identical 34 in .open-next, which is why only the newer set is
# read): total 387,996 bytes gzipped (1,249,036 raw); median chunk 6,533 gzipped, p90 34,642; the
# five largest 73,110 / 61,751 / 39,373 / 34,642 / 22,886. The fifth is the Luxon chunk the review
# found (2uo7pjh3fqjgn.js: 72,902 raw, holds `Invalid DateTime` and `fromISO`; luxon.min.js alone
# gzips to 24,238). Without it the total is 365,110, so Luxon joining the bundle is a growth of
# 22,886 bytes, +6.3%.
#   Growth blocks when it exceeds BOTH 3% AND 10,240 bytes (10 KB) gzipped.
#   At Slate's size 3% is 10,953 bytes, so the Luxon addition is caught with about 2x headroom, and
#   stays caught until the bundle passes 763 KB. The brief's starting point of 5% (18,256 bytes at
#   Slate's size) would also catch it today, but with only 1.25x headroom and it would stop catching
#   it once the bundle reached 458 KB, which is not far off; the percentage is there for large
#   bundles where 10 KB is noise, not to let the finding this guard exists for slip under it (L172).
#   A median chunk (6.5 KB, an ordinary new page) passes both; a p90 chunk (34 KB) fails and is worth
#   an explicit acceptance. Only ONE build was available to measure, so how often ordinary work
#   crosses the margin is not known yet (L147); revisit the numbers once the record has seen a few
#   weeks of pushes. The Slate main copy handed to this work had no build output, so the numbers
#   come from the main checkout's build of 2026-09-06 rather than from HEAD.
#
# Overrides, each good for ONE push and to be explained to the user first, never silently:
#   ACCEPT_BUNDLE_GROWTH=1 git push ...      the growth is intended; record the new total and pass
#   SKIP_BUNDLE_BUDGET_CHECK=1 git push ...  do not judge this push at all, and record nothing
#
# Fails OPEN on anything it cannot read (no repo, no origin remote, no HEAD, the measurer refusing
# its arguments), and says so in one line.

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/push-scope.sh
. "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null || exit 0

payload="$(cat)"

parsed="$(ps_parse_payload "$payload" segmented)" || exit 0
cmd="${parsed%%$'\x1f'*}"
cwd="${parsed#*$'\x1f'}"
[ -n "$cmd" ] || exit 0

ps_is_git_push "$cmd" || exit 0
ps_has_override "$cmd" SKIP_BUNDLE_BUDGET_CHECK && exit 0

# A flag word rather than an array: the Mac's bash 3.2 rejects an empty array expansion under
# `set -u`, and a hook that dies there would fail open with no line saying so.
accept=""
ps_has_override "$cmd" ACCEPT_BUNDLE_GROWTH && accept="--accept"

repo_dir="$(ps_repo_dir "$cmd" "$cwd")" || exit 0
[ -n "$repo_dir" ] || exit 0
cd "$repo_dir" 2>/dev/null || exit 0

# The record is keyed by the remote, never by the path: a worktree and its checkout are one
# repository with one bundle, and a repository that moves keeps its budget.
remote="$(git remote get-url origin 2>/dev/null)"
if [ -z "$remote" ]; then
  echo "bundle-budget: this repository has no origin remote to key a budget on, so the bundle weight was not judged."
  exit 0
fi

head_time="$(git log -1 --format=%ct 2>/dev/null)"
case "$head_time" in
  ''|*[!0-9]*)
    echo "bundle-budget: could not read HEAD's commit time, so whether the build is fresh is unknown and the bundle was not judged."
    exit 0 ;;
esac

state_dir="${BUNDLE_BUDGET_STATE_DIR:-$HOME/.claude/state/bundle-budget}"

out="$(python3 "$HOOK_DIR/lib/bundle-budget.py" --repo "$repo_dir" --head-time "$head_time" \
  --remote "$remote" --state-dir "$state_dir" $accept 2>&1)"; rc=$?

case "$rc" in
  0)
    # A pass, a first record, a skip or a stale build: one line each, on stdout, where a reader
    # looking at the transcript finds it and the push goes ahead.
    [ -n "$out" ] && printf '%s\n' "$out"
    exit 0 ;;
  2)
    {
      printf '%s\n' "$out"
      echo ""
      echo "Find what joined the client bundle (a dependency imported from a client component or"
      echo "the embed is the usual cause) and keep it off the hot path, then rebuild and push again."
      echo "OVERRIDE: if the growth is intended, record the new total and push with:"
      echo "    ACCEPT_BUNDLE_GROWTH=1 <your original git push command>"
      echo "To push without judging the bundle at all this once (nothing is recorded):"
      echo "    SKIP_BUNDLE_BUDGET_CHECK=1 <your original git push command>"
      echo "BEFORE overriding you MUST explain to the user, in plain non-technical language, WHY"
      echo "the growth is acceptable here, so they can judge whether it makes sense. Never"
      echo "override silently."
    } >&2
    exit 2 ;;
  *)
    echo "bundle-budget: the measurer could not run (exit $rc), so the bundle was not judged. It said: ${out:-nothing}"
    exit 0 ;;
esac
