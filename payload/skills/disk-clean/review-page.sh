#!/usr/bin/env bash
#
# review-page.sh: renders the last disk-clean scan into the one review page Dan ticks what goes on
# (claude-config#1807), drawn to the design he settled on 2026-10-28
# (docs/design/disk-clean-review-page.html, decisions D1 to D10).
#
#   bash ~/.claude/skills/disk-clean/review-page.sh --out <folder> [--clear-clipboard]
#
#   --out              the folder to write into, a scratchpad folder the skill gives. It gets the
#                      page (review-lib.sh's DCRV_PAGE) and, beside it, the nonce the page carries
#                      (DCRV_NONCE), which review-check.sh reads.
#   --clear-clipboard  empties the clipboard first, before the page exists, so a selection copied
#                      from an earlier page is not what gets pasted (#1808 runs it this way).
#
# The page is ONE self contained file: review-page.html beside this script with the scan put where
# its REVIEW marker is. Nothing on it is fetched from anywhere. What it shows, from the record
# (~/.claude/state/disk-clean/last-scan.json, read through hooks/lib/disk-clean-record.sh):
#   - each kind of thing as a heading row with what can go from it on the right (D1). A kind's total
#     says "At least" when anything in it that can go was only partly measured or not at all, since
#     then the figure is a lower bound (L11);
#   - kinds largest first by what can go, with Tools not used in 180 days and Large personal files
#     always last, in that order, because those are Dan's own and cannot come back (D3). A kind the
#     scan found nothing in is not drawn, as the design draws it;
#   - within a kind, what can be ticked largest first and unknown sizes last (D4), then what will not
#     be removed, greyed, each with its reason (D2), in the order the scan found them;
#   - each row on one line: path (the home folder as ~), then its reason or detail, then its marks
#     (D5, D7, D8), and its size;
#   - every tick box unticked, the foot bar reading Nothing selected (D9).
# The ordering is done by sort over keys, never inside awk, so thousands of items cost one sort.
#
# Exit: 0 the page and its nonce are written; 3 they are written but the clipboard could not be
# cleared (said on stderr, with pbcopy's own words); 2 refused, writing no page: an option it does not
# know, no --out, a folder it may not write (in test mode, one outside the throwaway directory), no
# scan record, or one cut short.
#
# Commands: awk cat date mkdir mktemp mv rm sort tr, the libraries it sources, and the builtins.
# bash 3.2 safe.
set -uo pipefail

HERE="${BASH_SOURCE[0]%/*}"; [ "$HERE" != "${BASH_SOURCE[0]}" ] || HERE=.
LIBS="$HERE/../../hooks/lib"
. "$HERE/review-lib.sh" || { echo "disk-clean review: review-lib.sh is missing beside it, so no page was written."; exit 2; }
. "$LIBS/disk-clean-record.sh" || { echo "disk-clean review: hooks/lib/disk-clean-record.sh is missing, so no page was written."; exit 2; }
. "$LIBS/disk-clean-units.sh" || { echo "disk-clean review: hooks/lib/disk-clean-units.sh is missing, so no page was written."; exit 2; }

TEMPLATE="$HERE/review-page.html"
S=$'\037'
TAB=$'\t'
refuse() { echo "disk-clean review: $1"; exit 2; }

OUT="" CLEAR=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --out) [ "$#" -ge 2 ] || refuse "--out needs a folder, so no page was written."; OUT="$2"; shift 2 ;;
    --clear-clipboard) CLEAR=1; shift ;;
    -h|--help) awk 'NR > 1 && /^set -uo/ { exit } NR > 1 { print }' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) refuse "it does not know '$1' (it takes --out and --clear-clipboard), so no page was written." ;;
  esac
done
[ -n "$OUT" ] || refuse "--out, the folder to write the page into, is missing, so no page was written."
[ -n "${HOME:-}" ] || refuse "HOME is not set, so there is no scan record to read, and no page was written."
if [ -n "${DISK_CLEAN_TEST_ROOT:-}" ]; then
  dc_home_isolated "$HOME" "$DISK_CLEAN_TEST_ROOT" || refuse "test mode, but HOME ('$HOME') is not inside the throwaway directory $DISK_CLEAN_TEST_ROOT, so no page was written."
fi
_dcrv_allowed "$OUT/$DCRV_PAGE" || refuse "test mode, and '$OUT' is outside the throwaway directory $DISK_CLEAN_TEST_ROOT, so no page was written."
[ -f "$TEMPLATE" ] || refuse "the page template $TEMPLATE is missing, so no page was written."

REC="$HOME/.claude/state/disk-clean/last-scan.json"
[ -f "$REC" ] || refuse "there is no scan record at $REC, so there is no scan to review, and no page was written. Scan first."
dcr_complete "$REC" || refuse "the scan record $REC stopped partway through being written, so no page was written. Scan again."
SID="$(dcr_header "$REC" scan_id)" || refuse "the scan record $REC names no scan, so no page was written. Scan again."
AT="$(dcr_header "$REC" scanned_at)" || AT=""
CATS="$(dcr_header "$REC" categories 2>/dev/null)" || CATS=""

mkdir -p "$OUT" 2>/dev/null && [ -d "$OUT" ] || refuse "could not make the folder $OUT, so no page was written."
WORK="$(mktemp -d "${TMPDIR:-/tmp}/disk-clean-review.XXXXXXXX")" || refuse "could not make a working folder under ${TMPDIR:-/tmp}, so no page was written."
trap 'rm -rf "$WORK"' EXIT

# ---------- the clipboard, before the page exists ----------
CLIP_FAILED=""
if [ -n "$CLEAR" ]; then dcrv_clear_clipboard || CLIP_FAILED=1; fi

# ---------- when the scan was taken, in words ----------
# date -r <seconds> is macOS's; date -d @<seconds> is the Linux CI runner's.
day_of() { date -r "$1" "+$2" 2>/dev/null || date -d "@$1" "+$2" 2>/dev/null; }
scanned_words() {
  local at="$1" now day today yday clock
  case "$at" in ''|*[!0-9]*) printf 'at a time the record does not say'; return ;; esac
  now="$(date +%s)" || now=""
  day="$(day_of "$at" %Y%m%d)"; today="$(day_of "${now:-0}" %Y%m%d)"; yday="$(day_of "$(( ${now:-86400} - 86400 ))" %Y%m%d)"
  clock="$(day_of "$at" '%I:%M %p' | awk '{ sub(/^0/, ""); print tolower($0) }')"
  if [ -n "$day" ] && [ "$day" = "$today" ]; then printf 'today at %s' "$clock"
  elif [ -n "$day" ] && [ "$day" = "$yday" ]; then printf 'yesterday at %s' "$clock"
  else printf 'on %s at %s' "$(day_of "$at" '%A %d %B' | awk '{ sub(/ 0/, " "); print }')" "$clock"; fi
}
SCANNED="$(scanned_words "$AT")"

# ---------- the nonce: written first, so a page still open from before is refused from now on ----------
NONCE="$(dcrv_write_nonce "$OUT" "$SID")" || refuse "could not write the nonce beside the page in $OUT, so no page was written."

# ---------- the rows, in the order the design settled ----------
dcr_review_items "$REC" > "$WORK/items"
# Pass 1: each kind's total and rank, and one sort key line per item:
#   rank, 0 for an item that can go or 1 for one that cannot, minus its KiB (unknown sizes after every
#   known one, kept items in scan order), the item's place in the scan, then the item itself.
awk -F "$S" -v cats="$CATS" -v table="$DCR_TITLES" -v catfile="$WORK/cats" -v tab="$TAB" "$DCU_AWK_LIB$DCR_AWK_TITLES"'
  {
    seq[NR] = $0; c = $2; cat_of[NR] = c
    if (!(c in known)) { known[c] = 1; firsts[++nfirst] = c }
    n[c]++
    if ($5 == "offerable") {
      if ($6 ~ /^[0-9]+$/) kib[c] += int($6 / 1024); else lower[c] = 1
      if ($8 == "partial") lower[c] = 1
    }
  }
  END {
    # The kinds, in the scan header order, then any the header does not name.
    m = split(cats, co, " "); nk = 0
    for (j = 1; j <= m; j++) if ((co[j] in n) && !(co[j] in placed)) { kinds[++nk] = co[j]; placed[co[j]] = 1 }
    for (j = 1; j <= nfirst; j++) if (!(firsts[j] in placed)) { kinds[++nk] = firsts[j]; placed[firsts[j]] = 1 }
    # D3: largest first by what can go (a stable insertion sort over a dozen kinds), your own last.
    nr = 0
    for (j = 1; j <= nk; j++) {
      c = kinds[j]; if (c == "forgotten-tools" || c == "large-files") continue
      r = ++nr; order[r] = c
      while (r > 1 && kib[order[r - 1]] + 0 < kib[c] + 0) { order[r] = order[r - 1]; r--; order[r] = c }
    }
    if ("forgotten-tools" in n) order[++nr] = "forgotten-tools"
    if ("large-files" in n) order[++nr] = "large-files"
    for (r = 1; r <= nr; r++) {
      c = order[r]; rank[c] = r
      printf "%d%s%s%s%s%s%s\n", r, tab, c, tab, dcr_t(c, table), tab, (lower[c] ? "At least " : "") dcu_h(kib[c] + 0) > catfile
    }
    for (i = 1; i <= NR; i++) {
      split(seq[i], f, FS)
      kept = (f[5] == "offerable") ? 0 : 1
      key = kept ? 0 : ((f[6] ~ /^[0-9]+$/) ? -int(f[6] / 1024) : 1)
      printf "%d%s%d%s%d%s%d%s%s\n", rank[cat_of[i]], tab, kept, tab, key, tab, i, tab, seq[i]
    }
  }' "$WORK/items" > "$WORK/keyed" || refuse "could not read the scan's items, so no page was written."
[ -f "$WORK/cats" ] || : > "$WORK/cats"
sort -t "$TAB" -k1,1n -k2,2n -k3,3n -k4,4n "$WORK/keyed" > "$WORK/sorted" || refuse "could not order the scan's items, so no page was written."

# Pass 2: the markup. Every string from the record is escaped; nothing from it is ever markup.
awk -v sep="$S" -v tab="$TAB" -v home="$HOME" -v sid="$SID" -v nonce="$NONCE" -v scanned="$SCANNED" \
  -v catfile="$WORK/cats" "$DCU_AWK_LIB$DCRV_AWK_WORDS"'
  function h(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); gsub(/"/, "\\&quot;", s); gsub(/\047/, "\\&#39;", s); return s }
  function short(t) {
    if (home != "" && t == home) return "~"
    if (home != "" && index(t, home "/") == 1) return "~" substr(t, length(home) + 1)
    return t
  }
  function reason(st) {
    if (st == "removed") return "removed already"
    if (st == "trashed") return "moved to the Trash already"
    if (st == "truncated") return "emptied already"
    if (st == "gone") return "already gone"
    if (st == "unreadable") return "this entry of the scan could not be read"
    sub(/^(not offerable|unmeasured): /, "", st)
    return st
  }
  BEGIN {
    while ((getline line < catfile) > 0) { split(line, c, tab); title[c[1]] = c[3]; total[c[1]] = c[4]; name[c[1]] = c[2] }
    printf "<header class=\"top\"><h1>Disk clean</h1><p class=\"scanline\">Scanned %s on this Mac. Nothing is removed until you copy your selection back.</p></header>\n", h(scanned)
    printf "<div class=\"grouped\" id=\"review\" data-scan-id=\"%s\" data-nonce=\"%s\">\n", h(sid), h(nonce)
    FS = tab
  }
  {
    r = $1; rest = $0
    for (k = 1; k <= 4; k++) rest = substr(rest, index(rest, tab) + 1)
    split(rest, f, sep)
    if (r != last) { last = r; printf "<div class=\"group-head\" data-category=\"%s\"><h2>%s</h2><span class=\"group-total\">%s</span></div>\n", h(name[r]), h(title[r]), h(total[r]) }
    id = f[1]; st = f[5]; b = f[6]; ok = (st == "offerable")
    p = h(short(f[4]))
    note = ok ? f[10] : reason(st)
    sub_ = ""
    if (note != "") sub_ = "<span class=\"note\">" h(note) "</span>"
    if (f[9] != "") {
      nf = split(f[9], fl, ","); marks = ""
      for (k = 1; k <= nf; k++) if (fl[k] != "") marks = marks "<span class=\"flag\">" h(dcrv_flags(fl[k])) "</span>"
      sub_ = sub_ "<span class=\"flags\">" marks "</span>"
    }
    if (sub_ != "") sub_ = "<span class=\"sub\">" sub_ "</span>"
    known = (b ~ /^[0-9]+$/)
    printf "<div class=\"item%s\" data-id=\"%s\"><input class=\"tick\" type=\"checkbox\" autocomplete=\"off\" aria-label=\"%s\" data-id=\"%s\" data-bytes=\"%s\" data-partial=\"%d\"%s><div class=\"what\"><span class=\"path\">%s</span>%s</div><span class=\"size%s\">%s</span></div>\n", \
      (ok ? "" : " kept"), h(id), p, h(id), (known ? b : ""), (f[8] == "partial"), (ok ? "" : " disabled"), p, sub_, (known ? "" : " unknown"), h(dcrv_size(b, f[8]))
    rows++
  }
  END {
    if (!rows) print "<p class=\"empty\">This scan found nothing to remove.</p>"
    print "</div>"
  }' "$WORK/sorted" > "$WORK/body" || refuse "could not write the page's rows, so no page was written."

# ---------- the page: the template with the rows where its marker is, renamed into place ----------
awk -v body="$WORK/body" '
  $0 == "<!-- REVIEW -->" { while ((getline line < body) > 0) print line; done = 1; next }
  { print }
  END { if (!done) exit 1 }' "$TEMPLATE" > "$WORK/page" || refuse "the page template $TEMPLATE has no REVIEW marker line, so no page was written."
mv -f "$WORK/page" "$OUT/$DCRV_PAGE" || refuse "could not move the page into place in $OUT."

echo "Review page for scan $SID: $OUT/$DCRV_PAGE"
if [ -n "$CLIP_FAILED" ]; then
  echo "The clipboard could not be cleared, so a selection copied earlier may still be on it; the checker refuses one by its nonce."
  exit 3
fi
exit 0
