#!/usr/bin/env bash
# Run this repo's test suite as LINUX, from a Mac, in a container matching what CI uses.
#
# It exists because a defect that only appears on the runner costs a push and a five minute wait
# per attempt, and two shipped on 2026-09-07 that were green on every machine anybody looks at: a
# tab escape in a grep pattern that BSD grep honours and GNU grep does not, and a git call with no
# identity, which works wherever git can find one. The second could not be reproduced on a Mac at
# all until the runner was made to print what it saw (claude-config#335, #337).
#
#   tests/run-on-linux.sh                          the whole suite
#   tests/run-on-linux.sh tests/test-claude-sync.sh one suite file
#   SECTION_ONLY='...' tests/run-on-linux.sh        one section, the same knob the suite takes
#
# The container carries NO git identity, deliberately. That is what a runner is, and it is the
# condition the second defect above needed. Anything that has to commit must bring its own.
#
# PROVEN to stand in for the runner, on 2026-09-07, rather than assumed: the pre-fix tool and its
# ORIGINAL fixture, the pair that was green on both Macs and red only on CI, were run through this
# and produced the same five failures with git's own "Committer identity unknown" in them. That
# took under a minute against the five it costs to ask the runner. The claim is worth re-making
# after any change to the image or the tool list below, because a container that no longer matches
# is a reassuring lie rather than a broken one: it would go on passing.
set -uo pipefail

# Captured BEFORE anything changes directory, because a path re-derived from $0 afterwards is
# relative to where the script was invoked from rather than where it lives (L372).
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

WORKFLOW="$ROOT/.github/workflows/tests.yml"

# The image is DERIVED from what the workflow declares it runs on, never written here as a second
# copy of that decision (L41). A workflow moved to another operating system must not leave this
# script quietly claiming to reproduce CI.
runner="$(sed 's/#.*//' "$WORKFLOW" 2>/dev/null | awk -F'runs-on:' '/runs-on:/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}')"
case "$runner" in
  ubuntu-latest|ubuntu-24.04) IMAGE=ubuntu:24.04 ;;
  ubuntu-22.04)               IMAGE=ubuntu:22.04 ;;
  '')
    echo "run-on-linux: could not read what $WORKFLOW runs on, so there is no way to know which image would reproduce it. Refusing rather than guessing an image and reporting its result as CI's." >&2
    exit 2 ;;
  *)
    echo "run-on-linux: the workflow now runs on '$runner', which this has no image for, so it can no longer claim to reproduce CI. Add the image for it here, or say why a container cannot." >&2
    exit 2 ;;
esac

# What the workflow's own environment step probes is what has to be present in the image. The list
# lives beside the mapping to packages rather than being maintained twice, and a check in the suite
# holds every probed command to having an entry here, so a dependency added to CI cannot be missing
# from this without something saying so (L96).
#
# command:package. bash and perl ship in the base image and are named anyway, so the list can be
# compared against the workflow's without an exception nobody can see.
TOOL_PACKAGES="bash:bash git:git rsync:rsync jq:jq perl:perl pgrep:procps"

if ! command -v docker >/dev/null 2>&1; then
  echo "run-on-linux: docker is not installed, so the Linux run could not be made. This is UNMEASURED, not a pass. Install Docker Desktop, or run the suite on the real runner by pushing." >&2
  exit 3
fi
if ! docker info >/dev/null 2>&1; then
  echo "run-on-linux: docker is installed but its daemon is not running, so the Linux run could not be made. This is UNMEASURED, not a pass. Start Docker Desktop and try again." >&2
  exit 3
fi

packages="$(printf '%s\n' $TOOL_PACKAGES | awk -F: '{print $2}' | sort -u | tr '\n' ' ')"
target="${1:-}"

# The checkout is mounted READ ONLY and copied inside, so a run cannot touch the working tree this
# was launched from. The suite writes scratch, clones fixtures and kills process trees; none of that
# belongs anywhere near the tree somebody is editing (L2).
docker run --rm -i \
  -v "$ROOT:/src:ro" \
  -e SECTION_ONLY -e SECTION_UNTIL -e SECTION_LIST -e SUITE_JOBS -e SUITE_DEBUG \
  -e TARGET="$target" -e PACKAGES="$packages" \
  "$IMAGE" bash -c '
    set -uo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null 2>&1 || { echo "run-on-linux: apt-get update failed inside the container, so the tools the suite needs are not there. UNMEASURED." >&2; exit 3; }
    # shellcheck disable=SC2086
    apt-get install -y -qq $PACKAGES >/dev/null 2>&1 || { echo "run-on-linux: could not install [$PACKAGES] inside the container. UNMEASURED." >&2; exit 3; }
    cp -a /src /work && cd /work || { echo "run-on-linux: could not copy the checkout into the container. UNMEASURED." >&2; exit 3; }
    # Deliberately no git identity: that is what a runner is, and it is the condition a whole class
    # of defect needs in order to appear at all.
    if [ -n "${TARGET:-}" ]; then bash "$TARGET"; else bash payload/hooks/run-all-tests.sh; fi
  '
