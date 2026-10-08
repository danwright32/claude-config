#!/usr/bin/env bash
# A whole tree scan: a send touching these paths runs this suite (claude-config#809).
# send-gate: scans skills/ hooks/lib/skill-audit.py
# Every skill's links resolve, and every test a skill ships is run by something (claude-config#676).
#
# claude-sync's skill check asks only that SKILL.md exists with a name and a description. It never
# asks whether the files a skill points its reader at are there, so openchart, svg-design and
# opendata-api shipped fifty links into `references/` folders that were never committed, from
# 2026-06-22 until the audit found them. And a test file nothing runs looks exactly like one that
# passes: reel-plan's 28 render tests had no runner at all.
#
# So hooks/lib/skill-audit.py walks the skills folder ON DISK (never what git tracks, which cannot
# see the file being written, L456) and answers two questions about every skill in it:
#   links  every relative link in every markdown file reaches a file that exists
#   unrun  every file shaped like a test is run: a test-*.sh by run-all-tests.sh, a test_*.py by
#          hooks/lib/skill-python-tests.py, and anything else only if a suite names it
# Nothing is exempted by name. Each question is asked of fixtures built to fail it first (L1), then
# of the real skills.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIT="$DIR/lib/skill-audit.py"
ROOT="$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null || true)"
SKILLS="$ROOT/payload/skills"
# The repository's skills, never an installed ~/.claude/skills: that folder also holds skills no send
# carries (the Claude app's own downloads, plugin skills), which this suite has no say over (L36).
# And which suites exist is a question about the repository. An installed copy says so in the shape
# the runner reads as NOT RUN, and the runner re-runs it from the checkout (claude-config#155, #237).
if [ -z "$ROOT" ] || [ ! -d "$SKILLS" ]; then
  printf 'SUITE-NOT-RUN %s\n' "reads the repository's payload/skills and its suites, and there is no repository above $DIR"
  exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "FAIL: python3 is not on PATH, so no skill could be audited. Refusing to report them as sound."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/    /' | awk 'NR <= 40'; return 0; }
has() { grep -qF -- "$2" <<< "$1"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/skill-integrity.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# =============================================================================================
# links
# =============================================================================================
F="$TMP/links/skills"
mkdir -p "$F/alpha/references" "$F/beta"
printf 'present\n' > "$F/alpha/present.md"
printf 'spaced\n' > "$F/alpha/with space.md"
cat > "$F/alpha/SKILL.md" <<'MD'
---
name: alpha
description: a fixture
---
A [good link](present.md) and one [to a section](present.md#part) and [a titled one](present.md "Title").
An [angle bracketed one](<with space.md>) and an [escaped one](with%20space.md).
A [dead link](references/never-committed.md) the check must name.
![a dead image](images/missing.png)
[dead-ref]: references/also-missing.md
Not links: [the web](https://example.com/x.md), [a section here](#heading), [mail](mailto:a@b.c),
an [installed path](~/.claude/skills/alpha/x.md), an [absolute one](/etc/nowhere.md),
and `[inline code](inline-missing.md)` shown as syntax.

```markdown
[fenced example](fenced-missing.md)
```
~~~
[tilde fenced](tilde-missing.md)
~~~
MD
cat > "$F/alpha/references/deep.md" <<'MD'
Back [up](../SKILL.md), and [a dead one two folders down](nope.md).
MD
# beta is never committed: the check reads the disk, so it must still be judged (L456).
printf '[beta dead](gone.md)\n' > "$F/beta/SKILL.md"
git -C "$TMP/links" init -q 2>/dev/null && git -C "$TMP/links" add skills/alpha >/dev/null 2>&1

out="$(python3 "$AUDIT" links "$F" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && ok || bad "a skill with dead links fails the check (rc=$rc)" "$out"
for want in "alpha/SKILL.md:7: (references/never-committed.md)" "alpha/SKILL.md:8: (images/missing.png)" \
            "alpha/SKILL.md:9: (references/also-missing.md)" "alpha/references/deep.md:1: (nope.md)" \
            "beta/SKILL.md:1: (gone.md)"; do
  has "$out" "$want" && ok || bad "it names the dead link $want" "$out"
done
for never in present.md "with space" with%20space example.com '#heading' mailto '~/.claude' /etc/nowhere \
             inline-missing fenced-missing tilde-missing '../SKILL.md'; do
  has "$out" "$never" && bad "it does not call $never dead" "$out" || ok
done
has "$out" "LINKS skills=2 checked=" && has "$out" "broken=5" && ok \
  || bad "it reports how many skills and links it read and how many are broken" "$out"

# Every link fixed, the same skills pass.
rm -rf "$F/alpha/references/deep.md" "$F/beta"
python3 - "$F/alpha/SKILL.md" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace("references/never-committed.md", "present.md").replace("images/missing.png", "present.md")
s = s.replace("references/also-missing.md", "present.md")
open(p, "w").write(s)
PY
out="$(python3 "$AUDIT" links "$F" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && has "$out" "broken=0" && ok || bad "the same skill with its links fixed passes (rc=$rc)" "$out"

# A skills folder holding no skills is refused, not passed (L98).
mkdir -p "$TMP/noskills"
out="$(python3 "$AUDIT" links "$TMP/noskills" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && has "$out" "no skills" && ok || bad "a folder with no skills is refused (rc=$rc)" "$out"
out="$(python3 "$AUDIT" links "$TMP/not-there" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && has "$out" "not-there" && ok || bad "a missing folder is refused by name (rc=$rc)" "$out"

# The real skills.
out="$(python3 "$AUDIT" links "$SKILLS" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then ok; else bad "every relative link in payload/skills resolves (rc=$rc)" "$out"; fi
grep '^LINKS ' <<< "$out"

# =============================================================================================
# unrun
# =============================================================================================
U="$TMP/unrun"
mkdir -p "$U/skills/gamma/scripts" "$U/skills/gamma/web" "$U/hooks" "$U/skills/delta"
printf '#!/bin/bash\necho SUITE-RESULT passed=1 failed=0\n' > "$U/skills/gamma/test-gamma.sh"
printf 'def test_x():\n    pass\n' > "$U/skills/gamma/scripts/test_thing.py"
printf 'test("x", () => {})\n' > "$U/skills/gamma/web/widget.test.js"
printf '#!/bin/bash\nexit 0\n' > "$U/skills/gamma/healthcheck.sh"
printf 'it("y")\n' > "$U/skills/delta/check.spec.ts"
printf '#!/bin/bash\nexit 0\n' > "$U/skills/delta/test_legacy.sh"
printf 'not a test\n' > "$U/skills/delta/tests.md"

# No suite names anything yet, and no suite runs the Python runner.
out="$(python3 "$AUDIT" unrun "$U/skills" "$U" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && ok || bad "test files nothing runs fail the check (rc=$rc)" "$out"
for want in gamma/web/widget.test.js gamma/healthcheck.sh delta/check.spec.ts delta/test_legacy.sh gamma/scripts/test_thing.py; do
  has "$out" "$want" && ok || bad "it names $want as run by nothing" "$out"
done
for never in test-gamma.sh tests.md; do
  has "$out" "$never" && bad "it does not flag $never" "$out" || ok
done

# A suite that only TALKS about the Python runner, in a comment and in a message, runs nothing, so
# it covers nothing: this suite's own text is exactly that, and deleting the real runner suite must
# still leave the Python tests reported as unrun (L673).
printf '# skill-python-tests.py runs them\necho "see skill-python-tests.py"\n' > "$U/hooks/test-talker.sh"
out="$(python3 "$AUDIT" unrun "$U/skills" "$U" 2>&1)"; rc=$?
has "$out" "gamma/scripts/test_thing.py" && ok || bad "a suite that only mentions the runner does not cover the Python tests" "$out"
rm -f "$U/hooks/test-talker.sh"

# The suite that runs the runner declares it on a line of its own, and runs it from a code line. The
# declaration is assembled from pieces so this file never holds it whole and cannot answer for it.
DECL="# runs: hooks/lib/skill-python-tests.py"" over payload/skills"
# A suite naming a file covers that file, by its path under skills/ from anywhere, or by its own
# name from inside the skill.
printf '%s\nRUNNER="$DIR/lib/skill-python-tests.py"\npython3 "$RUNNER" "$SKILLS"\nbash "$SKILLS/gamma/healthcheck.sh"\n' "$DECL" > "$U/hooks/test-runner.sh"
printf 'node check.spec.ts\n' > "$U/skills/delta/test-delta.sh"
out="$(python3 "$AUDIT" unrun "$U/skills" "$U" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && ok || bad "with some files covered the rest still fail (rc=$rc)" "$out"
for gone in gamma/scripts/test_thing.py gamma/healthcheck.sh delta/check.spec.ts; do
  has "$out" "$gone" && bad "a suite that runs $gone covers it" "$out" || ok
done
for still in gamma/web/widget.test.js delta/test_legacy.sh; do
  has "$out" "$still" && ok || bad "$still is still run by nothing" "$out"
done

# A file named only in a suite's COMMENT is talked about, not run, so it stays unrun.
printf '#!/bin/bash\n# gamma/web/widget.test.js is covered elsewhere\n' > "$U/hooks/test-commenter.sh"
out="$(python3 "$AUDIT" unrun "$U/skills" "$U" 2>&1)"; rc=$?
has "$out" "gamma/web/widget.test.js" && ok || bad "a file named only in a comment is not covered by it" "$out"
rm -f "$U/hooks/test-commenter.sh"

# A suite in ANOTHER checkout nested inside this one (a worktree) covers nothing here (L234).
mkdir -p "$U/.claude/worktrees/other/hooks"
printf 'gitdir: elsewhere\n' > "$U/.claude/worktrees/other/.git"
printf 'web/widget.test.js gamma/web/widget.test.js delta/test_legacy.sh\n' > "$U/.claude/worktrees/other/hooks/test-other.sh"
out="$(python3 "$AUDIT" unrun "$U/skills" "$U" 2>&1)"; rc=$?
has "$out" "gamma/web/widget.test.js" && ok || bad "a nested checkout's suite does not cover this tree's files" "$out"

# The real skills, against every suite in this repository.
out="$(python3 "$AUDIT" unrun "$SKILLS" "$ROOT" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then ok; else bad "every test file under payload/skills is run by something (rc=$rc)" "$out"; fi
grep '^UNRUN ' <<< "$out"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
