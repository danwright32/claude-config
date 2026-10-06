"""The account room's reader of Safari's cookie store (#808): how many live claude.ai session cookies
(sessionKey, unexpired) Safari's Cookies.binarycookies holds. Prints that count and nothing else;
names and values are never printed. Exit 0 with the count, 2 with why when the store cannot be read
or parsed.

Measured on Daniels-MacBook-Pro-2, 2026-10-05: the store at
~/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies is readable from a
Claude Code session there (532,410 bytes, 591 pages, 1,930 cookies, 20 for claude.ai, sessionKey
among them), so no Full Disk Access prompt stood in the way. A store that cannot be opened says
which error the system gave, and names Full Disk Access only for a permission refusal.

The format: "cook", a big endian page count and page sizes, then pages. Each page: 4 header bytes,
a little endian cookie count and offsets, and the cookies. Each cookie: little endian size, two
words, flags, then offsets (from the cookie's start) of its domain, name, path and value strings,
8 bytes, then its expiry and creation as little endian doubles in seconds since 2001-01-01 UTC.
"""
import os
import struct
import sys
import time

MAC_EPOCH = 978307200  # 2001-01-01T00:00:00Z as a Unix time


def fail(why):
    print(why)
    sys.exit(2)


path = os.environ.get("ACCOUNT_ROOM_SAFARI_COOKIES") or os.path.expanduser(
    "~/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies")
now = float(os.environ.get("ACCOUNT_ROOM_NOW") or time.time())
try:
    with open(path, "rb") as f:
        data = f.read()
except PermissionError:
    fail("could not read Safari's cookies: permission refused (Claude Code's terminal may need Full Disk Access)")
except OSError as e:
    fail("could not read Safari's cookies: %s" % (e.strerror or type(e).__name__))


def cstring(buf, at):
    end = buf.index(b"\0", at)
    return buf[at:end].decode("utf-8", "replace")


live = 0
try:
    if data[:4] != b"cook":
        raise ValueError("not a Safari cookie store")
    pages = struct.unpack(">i", data[4:8])[0]
    sizes = struct.unpack(">%di" % pages, data[8:8 + 4 * pages])
    at = 8 + 4 * pages
    for size in sizes:
        page = data[at:at + size]
        at += size
        if len(page) != size:
            raise ValueError("a page runs past the end of the file")
        count = struct.unpack("<i", page[4:8])[0]
        for off in struct.unpack("<%di" % count, page[8:8 + 4 * count]):
            c = page[off:]
            domain_at, name_at = struct.unpack("<ii", c[16:24])
            expiry = struct.unpack("<d", c[40:48])[0]
            if cstring(c, domain_at).lstrip(".") != "claude.ai" or cstring(c, name_at) != "sessionKey":
                continue
            # An expired cookie is no session: a logout may leave one behind dated in the past. One with
            # no expiry of its own (stored as 0) lasts as long as Safari runs, so it is live.
            if expiry <= 0 or expiry + MAC_EPOCH > now:
                live += 1
except (ValueError, struct.error, IndexError) as e:
    fail("could not parse Safari's cookies: %s" % e)
print(live)
