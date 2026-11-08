#!/usr/bin/env bash
# Holds every hour figure written about a time constant to the constant itself (claude-config#2403).
#
# WHY. is-it-live's WAIT_MS, how long a merge made in the background is asked about (a setting, not
# measured), went from 12 to 24 hours in #1706, and the words describing it in merge-when-ready.sh, merges.ts and the README
# went on saying it was twice three hours plus three hours, which is 12, for weeks, through #2382
# rewriting the very paragraph. Nothing read the words against the number, so the next change of the
# value would have left them behind again.
#
# THE RULE, per constant in the table below:
#   - in its own doc comment (the block directly above its declaration), every hour figure equals
#     the constant, so the comment cannot quote some other budget in hours and read as this one;
#   - in each file describing it, every mention of its name carries its value right after it, as
#     "WAIT_MS, 24 hours" or "(`WAIT_MS`, twenty four hours)", and that value equals the constant.
#     A mention with no figure fails too: prose beside it saying "twice three hours" or "half a day"
#     cannot be read, so the figure has to sit where it can be.
# Figures are digits or words ("twenty four"), and lines are joined first, so a figure wrapped onto
# the next line of a comment is still read. Each rule is run against a fixture that breaks it before
# it is believed about the real files (L1).
#
# A second constant joins by a row in CONSTANTS; the reader of its value is the same.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

. "$ROOT/payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $1"; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.hourwords.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}"|"${TMPDIR:-/tmp}"|"${TMPDIR:-/tmp}"/)
    echo "test-hour-words: refusing to run: the throwaway directory came back as '$TMPROOT'." >&2
    exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

# name | the file declaring it | the files describing it, space separated, from the repository root
CONSTANTS='WAIT_MS|payload/mods/is-it-live/hooks/merges.ts|payload/hooks/lib/merge-when-ready.sh payload/hooks/lib/merge-in-line.sh README.md'

# hour_words <name> <declaring file> <describing file>...: prints one line per disagreement, nothing
# when every figure agrees, and exits 2 when the constant's value could not be read (never a pass).
hour_words(){
  python3 -I - "$@" <<'PY'
import re, sys
name, decl, *described = sys.argv[1:]
UNITS = {w: i for i, w in enumerate('zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen'.split())}
TENS = {w: 10 * (i + 2) for i, w in enumerate('twenty thirty forty fifty sixty seventy eighty ninety'.split())}
WORD = r'(?:%s)(?:[ -](?:%s))?|(?:%s)' % ('|'.join(TENS), '|'.join(k for k in UNITS if k != 'zero'), '|'.join(UNITS))
FIGURE = r'(\d+|%s)\s+hours?\b' % WORD
def number(text):
    text = text.lower()
    if text.isdigit():
        return int(text)
    parts = re.split(r'[ -]', text)
    return sum(TENS.get(p, UNITS.get(p, 0)) for p in parts)
try:
    src = open(decl, encoding='utf-8').read().splitlines()
except OSError as e:
    print(f'could not read {decl}: {e}'); sys.exit(2)
at = next((i for i, l in enumerate(src) if re.match(r'\s*export const %s\s*=' % re.escape(name), l)), None)
if at is None:
    print(f'{name} is not declared in {decl}'); sys.exit(2)
expr = re.sub(r'//.*$', '', src[at].split('=', 1)[1]).strip()
if not re.fullmatch(r'[\d_]+(\s*\*\s*[\d_]+)*', expr):
    print(f'{name} = {expr} is not a product of whole numbers, so its hours could not be read'); sys.exit(2)
ms = 1
for f in expr.split('*'):
    ms *= int(f.strip().replace('_', ''))
if ms % 3_600_000:
    print(f'{name} is {ms} ms, not a whole number of hours'); sys.exit(2)
hours = ms // 3_600_000
out = []
# Its doc comment: the comment lines directly above the declaration.
block = []
i = at - 1
while i >= 0 and re.match(r'\s*(/\*\*|\*|//)', src[i]):
    block.insert(0, re.sub(r'^\s*(/\*\*|\*/|\*|//)\s?', '', src[i]))
    i -= 1
for m in re.finditer(FIGURE, ' '.join(block), re.I):
    if number(m.group(1)) != hours:
        out.append(f'{decl}: the comment above {name} says "{m.group(0)}", but {name} is {hours} hours')
# Every file describing it, comment markers dropped and lines joined.
MENTION = r'%s`?\)?,\s+%s' % (re.escape(name), FIGURE)
for path in described:
    try:
        lines = open(path, encoding='utf-8').read().splitlines()
    except OSError as e:
        out.append(f'could not read {path}: {e}'); continue
    text = ' '.join(re.sub(r'^\s*(#|//|\*)\s?', '', l) for l in lines)
    text = re.sub(r'\s+', ' ', text)
    for m in re.finditer(re.escape(name), text):
        fig = re.match(MENTION, text[m.start():], re.I)
        around = text[max(0, m.start() - 40):m.end() + 40]
        if not fig:
            out.append(f'{path}: a mention of {name} carries no hour figure right after it ("...{around}..."), so nothing can hold it to the constant; write "{name}, {hours} hours"')
        elif number(fig.group(1)) != hours:
            out.append(f'{path}: "{fig.group(0)}", but {name} is {hours} hours')
print('\n'.join(out))
PY
}

# ---------------------------------------------------------------------------
# Fixtures: each way of getting it wrong is refused, and the right form passes.
# ---------------------------------------------------------------------------
cat > "$TMPROOT/decl.ts" <<'TS'
/**
 * How long it waits, 24 hours: twice its line plus its deadline.
 */
export const WAIT_MS = 24 * 60 * 60_000
TS
cat > "$TMPROOT/good.md" <<'MD'
The window (`WAIT_MS`, twenty
four hours) is kept long, and WAIT_MS, 24 hours, says so again.
MD
r="$(hour_words WAIT_MS "$TMPROOT/decl.ts" "$TMPROOT/good.md")"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$r" ] && ok || bad "#2403 figures in digits and in words, one wrapped onto the next line, are read as agreeing (rc $rc: $r)"

printf 'A window (`WAIT_MS`, twelve hours) that says the old value.\n' > "$TMPROOT/stale.md"
r="$(hour_words WAIT_MS "$TMPROOT/decl.ts" "$TMPROOT/stale.md")"
[[ "$r" == *'twelve hours'*'is 24 hours'* ]] && ok || bad "#2403 a description saying twelve hours of a 24 hour constant is refused (got: $r)"

printf '# held at twice its line plus its deadline (WAIT_MS) by the test\n' > "$TMPROOT/bare.sh"
r="$(hour_words WAIT_MS "$TMPROOT/decl.ts" "$TMPROOT/bare.sh")"
[[ "$r" == *'carries no hour figure'* ]] && ok || bad "#2403 a mention with no figure beside it is refused (got: $r)"

cat > "$TMPROOT/doc-stale.ts" <<'TS'
/**
 * How long it waits: twice its three hours in line plus its three hour deadline.
 */
export const WAIT_MS = 24 * 60 * 60_000
TS
r="$(hour_words WAIT_MS "$TMPROOT/doc-stale.ts")"
[[ "$r" == *'says "three hours"'* ]] && ok || bad "#2403 a doc comment quoting another budget in hours is refused (got: $r)"

printf 'export const WAIT_MS = someHours()\n' > "$TMPROOT/unreadable.ts"
r="$(hour_words WAIT_MS "$TMPROOT/unreadable.ts")"; rc=$?
[ "$rc" -eq 2 ] && ok || bad "#2403 a value that cannot be read is a failure, never a pass (rc $rc: $r)"

# ---------------------------------------------------------------------------
# The real files.
# ---------------------------------------------------------------------------
printf '%s\n' "$CONSTANTS" | while IFS='|' read -r name decl described; do
  [ -n "$name" ] || continue
  # shellcheck disable=SC2086 # the describing files are a space separated list by design
  r="$(cd "$ROOT" && hour_words "$name" "$decl" $described)"; rc=$?
  if [ "$rc" -eq 0 ] && [ -z "$r" ]; then echo "ok"; else printf 'bad\t%s\n' "#2403 every hour figure written about $name agrees with it (rc $rc): ${r//$'\n'/ || }"; fi
done > "$TMPROOT/real"
while IFS=$'\t' read -r verdict why; do
  if [ "$verdict" = ok ]; then ok; else bad "$why"; fi
done < "$TMPROOT/real"
[ -s "$TMPROOT/real" ] && ok || bad "#2403 no constant in the table was checked"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
