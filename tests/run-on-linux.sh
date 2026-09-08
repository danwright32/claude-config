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
#   SYNC_LINUX_PRINT_PLAN=1 tests/run-on-linux.sh  what it would do, without starting anything
#
# Measured on this Mac on 2026-09-07: one section took 18.6 seconds on the run that built the
# image and 3.7 on every run after it.
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

packages="$(printf '%s\n' $TOOL_PACKAGES | awk -F: '{print $2}' | sort -u | tr '\n' ' ')"
target="${1:-}"

# The image is BUILT ONCE and reused (claude-config#338). Installing the packages inside a fresh
# container on every invocation was most of the minute a run cost and needed a network, and the
# cost is what decides whether this gets used: a run somebody has to decide to wait for is one they
# skip when they are in a hurry, which is exactly when the defect it catches gets pushed.
#
# The tag is keyed on the two things that decide what the image CONTAINS, so a tool added to the
# workflow invalidates it rather than being silently missing from a stale image (L40, L431). The
# Dockerfile is generated from the same derived list rather than kept beside it as a second copy
# that has to be remembered (L41).
key="$(printf '%s|%s' "$IMAGE" "$packages" | { shasum -a 256 2>/dev/null || sha256sum 2>/dev/null; } | awk 'NR==1{print $1}')"
case "$key" in
  '' )
    echo "run-on-linux: could not hash what the image should contain, so there is no safe name to cache it under. Refusing rather than reusing an image that may not match (L98)." >&2
    exit 2 ;;
esac
TAG="claude-sync-linux:$(printf '%s' "$key" | cut -c1-12)"

# What it WOULD do, without needing docker at all. It exists so the derivations above can be
# checked without building anything, and because "what would this run" is a fair question to be
# able to ask of a script that starts containers.
if [ -n "${SYNC_LINUX_PRINT_PLAN:-}" ]; then
  printf 'runner: %s\nimage: %s\ntag: %s\npackages: %s\n' "$runner" "$IMAGE" "$TAG" "$packages"
  exit 0
fi

# The container runner is a SEAM (claude-config#337). Without it the only way to test the refusal
# was to run this with docker off the PATH, which is a claim about the machine rather than a
# condition the test sets: a GitHub runner HAS docker, so that test both failed there and made the
# suite actually build and run a container inside CI, which took 184 seconds on the runner on
# 2026-09-07 and tripped the
# suite's own stall bound. A test that depends on machine state it cannot set has to set it (L504).
DOCKER="${SYNC_DOCKER:-docker}"

if ! command -v "$DOCKER" >/dev/null 2>&1; then
  echo "run-on-linux: docker is not installed, so the Linux run could not be made. This is UNMEASURED, not a pass. Install Docker Desktop, or run the suite on the real runner by pushing." >&2
  exit 3
fi
if ! "$DOCKER" info >/dev/null 2>&1; then
  echo "run-on-linux: docker is installed but its daemon is not running, so the Linux run could not be made. This is UNMEASURED, not a pass. Start Docker Desktop and try again." >&2
  exit 3
fi

if ! "$DOCKER" image inspect "$TAG" >/dev/null 2>&1; then
  # Said out loud. A first run that quietly takes two minutes reads as a hang, and the whole point
  # of this is that a run is cheap enough to reach for (L106).
  echo "run-on-linux: building $TAG from $IMAGE with [$packages]. This happens once per change to that list; every later run reuses it." >&2
  if ! printf 'FROM %s\nENV DEBIAN_FRONTEND=noninteractive\nRUN apt-get update -qq && apt-get install -y -qq %s && rm -rf /var/lib/apt/lists/*\n' "$IMAGE" "$packages" \
       | "$DOCKER" build -q -t "$TAG" - >/dev/null; then
    echo "run-on-linux: that build failed, so the Linux run could not be made. This is UNMEASURED, not a pass." >&2
    exit 3
  fi
fi

# The checkout is mounted READ ONLY and copied inside, so a run cannot touch the working tree this
# was launched from. The suite writes scratch, clones fixtures and kills process trees; none of that
# belongs anywhere near the tree somebody is editing (L2).
"$DOCKER" run --rm -i \
  -v "$ROOT:/src:ro" \
  -e SECTION_ONLY -e SECTION_UNTIL -e SECTION_LIST -e SUITE_JOBS -e SUITE_DEBUG \
  -e TARGET="$target" \
  "$TAG" bash -c '
    set -uo pipefail
    cp -a /src /work && cd /work || { echo "run-on-linux: could not copy the checkout into the container. UNMEASURED." >&2; exit 3; }
    # Deliberately no git identity: that is what a runner is, and it is the condition a whole class
    # of defect needs in order to appear at all.
    if [ -n "${TARGET:-}" ]; then bash "$TARGET"; else bash payload/hooks/run-all-tests.sh; fi
  '
