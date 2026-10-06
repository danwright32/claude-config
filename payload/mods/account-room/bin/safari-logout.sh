#!/bin/sh
# The account room's browser logout for Safari (#808): loads claude.ai's logout page in Safari, the
# browser Dan signs in with on Daniels-MacBook-Pro-2. Not yet proven on a real Safari: the live proof
# with Dan present is on #808. Seam for the tests: ACCOUNT_ROOM_OPEN.
OPEN="${ACCOUNT_ROOM_OPEN:-/usr/bin/open}"
exec "$OPEN" -a Safari https://claude.ai/logout
