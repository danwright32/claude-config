#!/usr/bin/env bash
#
# review-lib.sh: what disk-clean's review page and its checker share (claude-config#1807).
#
# The review page lists the last scan for Dan to tick; "Copy selection" copies
# {scan_id, nonce, count, ids} as JSON, he pastes it into the chat, and review-check.sh turns it into
# disk-remove.sh's plan or refuses it. The nonce is what ties a pasted selection to the page rendered
# LAST: a selection copied from an older copy of the page, or one still on the clipboard from an
# earlier run, carries another nonce and is refused.
#
#   DCRV_PAGE, DCRV_NONCE              the page's and the nonce file's names inside the folder the
#                                      page is rendered into (a scratchpad folder the skill gives)
#   DCRV_AWK_WORDS                     awk functions saying an item's facts in words, one copy for
#                                      the page and the checker's confirmation (L370):
#                                        dcrv_size(<bytes>, <size>)  "18.4 GB", "At least 1.6 GB",
#                                          "Size unknown", never 0 for a size nobody read; needs
#                                          DCU_AWK_LIB (hooks/lib/disk-clean-units.sh) beside it
#                                        dcrv_flags(<flags>)  the marks a flags list carries, in the
#                                          settled design's words ("Holds a credential", "Removes it
#                                          from iCloud on every device", "Partly kept only in
#                                          iCloud"), joined by "; ", or empty
#                                        dcrv_flag_quiet(<flag>)  true for a flag that informs
#                                          rather than warns (icloud-only-part: part of the folder
#                                          is kept only in iCloud, and its size is what this Mac
#                                          stores), which the page draws grey, never amber
#   dcrv_write_nonce <folder> <scan_id>
#                                      makes a fresh nonce (32 hex characters from /dev/urandom),
#                                      writes <folder>/$DCRV_NONCE as two lines, "scan_id <id>" and
#                                      "nonce <nonce>", through a temp file renamed into place, and
#                                      prints the nonce. Fails, writing nothing, on a folder that is
#                                      not there, a scan id holding a space or control character, or
#                                      no randomness. In test mode the folder must be inside the
#                                      throwaway directory.
#   dcrv_read_nonce <folder>           prints the nonce the last render wrote there; fails when none
#   dcrv_clear_clipboard               empties the clipboard, so a selection copied from an earlier
#                                      page is not what gets pasted (the skill runs it before the
#                                      page opens, #1808). pbcopy is reached by NAME, never by path:
#                                      the harness puts its stub first on PATH, which is the seam,
#                                      and no test can reach the real clipboard. Fails, saying so
#                                      with pbcopy's own words, when pbcopy does.
#
# Commands: awk cat cut head mkdir mv pbcopy rm shasum, and the builtins. bash 3.2 safe. Sourcing
# defines constants and functions and does nothing else.

DCRV_DIR="${BASH_SOURCE[0]%/*}"; [ "$DCRV_DIR" != "${BASH_SOURCE[0]}" ] || DCRV_DIR=.
. "$DCRV_DIR/../../hooks/lib/disk-clean-predicates.sh" || { echo "disk-clean review: hooks/lib/disk-clean-predicates.sh is missing"; return 2; }

DCRV_AWK_WORDS='
function dcrv_size(bytes, size,    h) {
  if (bytes !~ /^[0-9]+$/) return "Size unknown"
  h = dcu_h(int(bytes / 1024))
  return (size == "partial") ? "At least " h : h
}
# A flag that informs rather than warns about removing: drawn in the row grey, never amber.
function dcrv_flag_quiet(flag) { return flag == "icloud-only-part" }
function dcrv_flags(flags,    n, f, i, out, w) {
  n = split(flags, f, ",")
  out = ""
  for (i = 1; i <= n; i++) {
    w = ""
    if (f[i] == "credential") w = "Holds a credential"
    else if (f[i] == "icloud") w = "Removes it from iCloud on every device"
    else if (f[i] == "icloud-only-part") w = "Partly kept only in iCloud"
    else if (f[i] != "") w = f[i]
    if (w != "") out = out (out == "" ? "" : "; ") w
  }
  return out
}
'

DCRV_PAGE=disk-clean-review.html
DCRV_NONCE=disk-clean-review.nonce

# True outside test mode; in it, true only when <path> lies inside the throwaway directory, by the
# predicate disk-remove.sh and the harness use (L261).
_dcrv_allowed() { # <path>
  [ -n "${DISK_CLEAN_TEST_ROOT:-}" ] || return 0
  dc_inside "$1" "$DISK_CLEAN_TEST_ROOT"
}

dcrv_write_nonce() { # <folder> <scan_id>
  local dir="${1:-}" sid="${2:-}" n tmp
  [ -n "$dir" ] && [ -d "$dir" ] || { echo "disk-clean review: the folder '$dir' is not there, so no nonce was written." >&2; return 1; }
  _dcrv_allowed "$dir/$DCRV_NONCE" || { echo "disk-clean review: test mode, and '$dir' is outside the throwaway directory $DISK_CLEAN_TEST_ROOT, so no nonce was written." >&2; return 1; }
  case "$sid" in ''|*[[:space:][:cntrl:]]*) echo "disk-clean review: the scan id '$sid' is empty or holds a space or control character, so no nonce was written." >&2; return 1 ;; esac
  n="$(head -c 32 /dev/urandom | shasum -a 256 | cut -c 1-32)"
  case "$n" in *[!0-9a-f]*|'') echo "disk-clean review: could not read randomness from /dev/urandom, so no nonce was written." >&2; return 1 ;; esac
  [ "${#n}" -eq 32 ] || { echo "disk-clean review: could not read randomness from /dev/urandom, so no nonce was written." >&2; return 1; }
  tmp="$dir/$DCRV_NONCE.tmp.$$"
  printf 'scan_id %s\nnonce %s\n' "$sid" "$n" > "$tmp" || { rm -f "$tmp"; echo "disk-clean review: could not write $tmp, so no nonce was written." >&2; return 1; }
  mv -f "$tmp" "$dir/$DCRV_NONCE" || { rm -f "$tmp"; echo "disk-clean review: could not move the nonce into place in $dir." >&2; return 1; }
  printf '%s\n' "$n"
}

dcrv_read_nonce() { # <folder>
  local f="${1:-}/$DCRV_NONCE" n
  [ -f "$f" ] || return 1
  n="$(awk '$1 == "nonce" { print $2; exit }' "$f")"
  [ -n "$n" ] || return 1
  printf '%s\n' "$n"
}

dcrv_clear_clipboard() {
  local err rc
  err="$(printf '' | pbcopy 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "disk-clean review: could not clear the clipboard (pbcopy exit $rc${err:+: $err}), so a selection copied from an earlier review page may still be on it. The checker refuses one of those by its nonce." >&2
    return 1
  fi
  return 0
}
