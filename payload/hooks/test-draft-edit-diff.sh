#!/usr/bin/env bash
# Tests for lib/draft-edit-diff.py (claude-config#3554): pairing each Slack draft a session saved
# with the post Dan made after it, and tallying the kinds of edit between the two.
#
# The records come from draft-edit-fixtures/build.py, whose message text, names and ids are all
# invented. Nothing here reads a real session record.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$DIR/lib/draft-edit-diff.py"
BUILD="$DIR/draft-edit-fixtures/build.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
check(){ if [[ "$3" == *"$2"* ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; echo "  expected to contain: $2"; echo "  actual: ${3:0:900}"; fi; }
check_not(){ if [[ "$3" != *"$2"* ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; echo "  expected NOT to contain: $2"; echo "  actual: ${3:0:900}"; fi; }
check_eq(){ if [[ "$3" == "$2" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 (expected '$2', got '${3:0:300}')"; fi; }

ME=U0FIXTUREA
fixture(){ mkdir -p "$WORK/$1/project" && python3 -B "$BUILD" "$WORK/$1/project" "$1"; }
run(){ local which="$1"; shift; python3 -B "$TOOL" --records "$WORK/$which" --author "$ME" "$@" 2>&1; }
for f in basics recurring lopsided few unknown; do fixture "$f" || { echo "FAIL: fixture $f could not be built"; fail=$((fail + 1)); }; done

# --- pairing -------------------------------------------------------------------------------------
out="$(run basics)"; rc=$?
check_eq "basics: the run succeeds" "0" "$rc"
check "basics: draft calls are counted once, though a resumed session and a request copy repeat them" "draft calls: 8 (saved: 6)" "$out"
check "basics: four pairs, one per thread" "pairs: 4 in 4 threads" "$out"
check "basics: a draft nothing read back after is left out and counted" "drafts with no post read back after them: 1" "$out"
check "basics: a draft replaced by a later one before any post is left out and counted" "drafts replaced by a later draft: 1" "$out"
check "basics: a post with no saved draft before it is left out and counted (a draft never saved is no draft)" "posts with no draft before them: 3" "$out"
check "basics: formatting, bullets, links, spacing and case are set aside" "sent as drafted: 2 of 4 pairs" "$out"
check "basics: heavily rewritten" "heavily rewritten: 2 of 4 pairs" "$out"
check "basics: figures cut rests on one pair and is too thin" "figures cut: 1 of 4 pairs, in 1 thread: too thin to offer a rule" "$out"
check "basics: the ask reworded" "the ask reworded: 1 of 4 pairs" "$out"
check "basics: the opening changed" "the opening changed: 2 of 4 pairs" "$out"
check "basics: the floor is stated beside a thin kind" "at least 10 pairs in at least 3 threads" "$out"
check_not "basics: no message text without the flag (draft)" "harbour" "$out"
check_not "basics: no message text without the flag (sent)" "fenders" "$out"
check_not "basics: no author name" "Ada" "$out"
check_not "basics: no channel id" "C0FIXTURE" "$out"

# The author by display name, whatever its case.
out="$(python3 -B "$TOOL" --records "$WORK/basics" --author "ada example" 2>&1)"
check "the author can be named as Slack shows them" "pairs: 4 in 4 threads" "$out"
# Somebody else's posts are never paired with a draft.
out="$(python3 -B "$TOOL" --records "$WORK/basics" --author "U0FIXTUREZ" 2>&1)"
check "an author with no posts pairs nothing" "pairs: 0" "$out"

# --- the floor -----------------------------------------------------------------------------------
out="$(run recurring)"
check "recurring: twelve pairs in three threads is recurring" "figures cut: 12 of 12 pairs, in 3 threads: recurring" "$out"
check "recurring: length cut too" "length cut: 12 of 12 pairs, in 3 threads: recurring" "$out"
check_not "recurring: still no message text without the flag" "Gauge" "$out"
out="$(run lopsided)"
check "lopsided: twelve pairs in two threads is too thin" "figures cut: 12 of 12 pairs, in 2 threads: too thin to offer a rule" "$out"
out="$(run few)"
check "few: nine pairs in three threads is too thin" "figures cut: 9 of 9 pairs, in 3 threads: too thin to offer a rule" "$out"

# --- one example pair per kind, only when asked ----------------------------------------------------
out="$(run recurring --examples)"
check "examples: the kind is named over its pair" "Example for figures cut" "$out"
check "examples: the draft is shown" "against 38, 52 and 60 last week" "$out"
check "examples: what was sent is shown" "read 57 at noon." "$out"
check_eq "examples: one pair per kind, never more" "1" "$(printf '%s\n' "$out" | grep -c '^Example for figures cut')"
out="$(run lopsided --examples)"
check_not "examples: a kind under the floor shows no message text" "Gauge" "$out"
out="$(run recurring --examples --skip "figures cut")"
check "skip: a kind decided before is said as that" "figures cut: 12 of 12 pairs, in 3 threads: decided before, not offered" "$out"
check_not "skip: and shows no example" "Example for figures cut" "$out"
check "skip: the others still show theirs" "Example for length cut" "$out"
out="$(run recurring --skip "no such kind")"; rc=$?
check_eq "skip: a kind that does not exist is refused" "2" "$rc"
check "skip: and the kinds are named" "figures cut" "$out"

# --- failure paths ---------------------------------------------------------------------------------
out="$(python3 -B "$TOOL" --records "$WORK/basics" 2>&1)"; rc=$?
check_eq "no author: refused" "2" "$rc"
check "no author: says what to pass" "--author" "$out"
out="$(python3 -B "$TOOL" --records "$WORK/nowhere" --author "$ME" 2>&1)"; rc=$?
check_eq "no records folder: refused, never a clean zero" "3" "$rc"
check "no records folder: said" "could not be read" "$out"
mkdir -p "$WORK/empty"
out="$(run empty)"; rc=$?
check_eq "records with no draft in them: measured, and zero" "0" "$rc"
check "records with no draft in them: the zero is said as nothing to compare, never as no edits" "No saved draft is in these records" "$out"
check_not "records with drafts in them never say so" "No saved draft" "$(run basics)"
out="$(run unknown)"; rc=$?
check_eq "a layout it cannot read is a failure, never zero pairs" "4" "$rc"
check "a layout it cannot read is counted" "read results in a layout this cannot read: 1" "$out"
check "and said as nothing measured" "Nothing was measured" "$out"
check_not "and none of its text is printed" "lock gates" "$out"
out="$(run unknown --shapes)"
check "shapes: says how many results it could not read" "in a layout this cannot read: 1" "$out"
check "shapes: names the result's own fields" "messages" "$out"
check_not "shapes: prints no message text" "lock gates" "$out"
out="$(run basics --shapes)"
check "shapes: counts each heading it knows" "thread parent headings: 5" "$out"
check_not "shapes: prints no message text for a layout it can read" "harbour" "$out"

# --- it writes nothing, and holds no way to -----------------------------------------------------------
before="$(cd "$WORK" && find . -type f -exec cksum {} + | sort)"
run basics --examples >/dev/null; run recurring --examples >/dev/null
check_eq "a run leaves every file as it was and makes none" "$before" "$(cd "$WORK" && find . -type f -exec cksum {} + | sort)"
static="$(python3 -B - "$TOOL" <<'PY'
import ast, sys
sys.stdout.reconfigure(errors="replace")
ALLOWED = {"argparse", "collections", "datetime", "difflib", "html", "json", "os.path", "re", "sys"}
WRITES = {"write", "writelines", "write_text", "write_bytes", "touch", "unlink", "rmdir", "rename", "replace_file",
          "symlink_to", "hardlink_to", "link_to", "chmod", "mkdir", "makedirs", "remove", "truncate", "fdopen"}
try:
    with open(sys.argv[1], "rb") as f:
        tree = ast.parse(f.read().decode("utf-8", "replace"))
except (OSError, SyntaxError) as e:
    print("unreadable: %s" % e)
    sys.exit(0)
bad = []
for node in ast.walk(tree):
    if isinstance(node, ast.Import):
        bad += ["imports " + a.name for a in node.names if a.name not in ALLOWED]
    elif isinstance(node, ast.ImportFrom):
        bad.append("imports from " + str(node.module))
    elif isinstance(node, ast.Attribute) and node.attr in WRITES:
        bad.append("names " + node.attr)
    elif isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "open":
        mode = node.args[1] if len(node.args) > 1 else None
        if not (isinstance(mode, ast.Constant) and mode.value == "rb") or node.keywords:
            bad.append("opens a file in a mode that is not rb")
    elif isinstance(node, ast.Name) and node.id in ("exec", "eval", "compile", "__import__", "getattr", "setattr"):
        bad.append("names " + node.id)
print("clean" if not bad else "; ".join(sorted(set(bad))))
PY
)"
check_eq "its source imports nothing that can send or write, opens files only to read, and names no writing call" "clean" "$static"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
