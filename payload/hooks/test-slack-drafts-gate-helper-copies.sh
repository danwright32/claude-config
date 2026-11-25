#!/usr/bin/env bash
# The copies of the helper functions the suites of slack-drafts-only-gate.sh drive the gate through
# are held equal here (claude-config#3575).
#
# When test-slack-drafts-only-gate.sh was cut into six suites sharing lib/slack-drafts-gate-harness.sh,
# the helpers (check, payload, bash_input, run_raw, run_tool, run_bash, refused, allowed, says, and
# the few one section defines and a later suite uses) could not go in the harness: the gate knows a
# shell function only where the text calling it defines it (lib/unknown-program.py, #3304), and with
# them in a sourced file it refused a plain run of the suite as a post (measured 2026-11-24). So each
# suite carries a copy, and copies kept by hand drift apart until one suite's `allowed` means
# something another's does not (L613). This suite reads each helper's text out of every suite that
# carries it and fails, naming the suite and the helper, when two copies differ, and when a suite
# sharing the harness lacks one of the helpers every case is driven through.
#
# The suites held are every test-slack-drafts-only-gate*.sh that sources the harness, found by that
# line, never by a list (L96). HELPER_COPIES_DIR points it at another hooks folder (its red proof).
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="${HELPER_COPIES_DIR:-$DIR}"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

echo "slack drafts gate helper copies: every copy of a helper is the same text"

T="$(mktemp -d "${TMPDIR:-/tmp}/helper-copies.XXXXXXXX")" || exit 1
case "${T%/}" in ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$T'" >&2; exit 2 ;; esac
trap 'rm -rf "$T"' EXIT

# One line per finding: a helper a sharing suite lacks, a helper whose copies differ, and the count
# of suites read, so reading none is a finding and not a pass (L98). Written to a file first, since
# bash 3.2 misreads a quote inside a heredoc held in a command substitution.
cat > "$T/copies.py" <<'PY'
import glob, os, re, sys

hooks = sys.argv[1]
SOURCE = '. "$DIR/lib/slack-drafts-gate-harness.sh"'
EVERY = ["check", "payload", "bash_input", "run_raw", "run_tool", "run_bash", "refused", "allowed", "says"]
SOME = ["run_budget", "lacks", "read_refused", "sv_env", "sv_tool"]

def helpers(path):
    # name -> the definition's text: from `name() {` to the first line that is `}` or ends `; }`.
    lines = open(path, encoding="utf-8").read().split("\n")
    found = {}
    for i, l in enumerate(lines):
        m = re.match(r"([a-z_][a-z0-9_]*)\(\) \{", l)
        if not m or m.group(1) not in EVERY + SOME:
            continue
        j = i
        while not (lines[j].strip() == "}" or lines[j].rstrip().endswith("; }")):
            j += 1
            if j == len(lines):
                break
        found.setdefault(m.group(1), []).append("\n".join(lines[i:j + 1]))
    return found

suites = sorted(p for p in glob.glob(os.path.join(hooks, "test-slack-drafts-only-gate*.sh"))
                if SOURCE in open(p, encoding="utf-8").read())
print(f"suites {len(suites)}")
copies = {}
for p in suites:
    name = os.path.basename(p)
    got = helpers(p)
    for h in EVERY:
        if h not in got:
            print(f"{name} has no copy of {h}")
    for h, texts in got.items():
        if len(set(texts)) > 1:
            print(f"{name} defines {h} twice, differently")
        copies.setdefault(h, []).append((name, texts[0]))
for h in EVERY + SOME:
    held = copies.get(h, [])
    if not held:
        continue
    first_name, first = held[0]
    for name, text in held[1:]:
        if text != first:
            print(f"{name}: {h} differs from the copy in {first_name}")
PY
# The reader's exit and its stderr are read too (the lessons review of this pull request, 2026-11-25):
# one that stops after printing its `suites` line has printed no finding, and with its exit thrown
# away that read as every copy being the same.
report="$(python3 -B "$T/copies.py" "$HOOKS" 2> "$T/copies.err")"; reader_rc=$?
if [ "$reader_rc" -eq 0 ] && [ ! -s "$T/copies.err" ]; then
  check "the reader of the copies ran to its end" ok
else
  check "the reader of the copies ran to its end" "exit $reader_rc, so its findings are not all here: $(tr '\n' ' ' < "$T/copies.err" | cut -c1-300)"
fi
n="$(printf '%s\n' "$report" | sed -n 's/^suites //p')"
case "$n" in
  ''|0|1) check "the suites that share the harness are found (at least two)" "found ${n:-none} in $HOOKS" ;;
  *) check "the suites that share the harness are found (at least two)" ok ;;
esac
problems="$(printf '%s\n' "$report" | grep -v '^suites ' || true)"
if [ -z "$problems" ]; then
  check "every suite sharing the harness carries the helpers, and every copy of a helper is the same" ok
else
  check "every suite sharing the harness carries the helpers, and every copy of a helper is the same" "$(printf '%s' "$problems" | tr '\n' ';')"
fi

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
