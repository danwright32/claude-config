#!/usr/bin/env bash
# Global Stop hook: the sound that says a turn has ended, unless the Mac is asleep (claude-config#841).
#
# It was a bare `afplay` in the hooks block, which nothing could stop playing at 3 AM. While sleep
# mode holds it stays quiet; a sleep record that cannot be read counts as awake, so the sound plays
# (lib/sleep.sh: a mute that cannot say when it ends must never hold). The payload is not read.
set -uo pipefail
cat >/dev/null 2>&1 || true

if . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/sleep.sh" 2>/dev/null && sleep_active; then
  exit 0
fi
afplay /System/Library/Sounds/Blow.aiff >/dev/null 2>&1 || true
exit 0
