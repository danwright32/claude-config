#!/bin/bash
# Tests for payload/mods/sleep-repos.json, sleep mode's per repository merge and deploy lists
# (claude-config#843). The mod reads it with readRepoLists (mods/scope-modes/hooks/overnight.ts),
# which closes every repository for the night when the file does not read, so a shipped file that
# does not parse would silently stop every overnight merge. This holds the shipped file to the same
# shape that reader requires, and to Dan's decision 6 (2026-10-06): trypennie, Bidspoke and Slate
# merge but never deploy, and each of them deploys on merge, so their green PRs stay open overnight;
# claude-config's merge reaches the live harness, so it is held the same way.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
. "$ROOT/payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?
FILE="${SLEEP_REPOS_FILE:-$ROOT/payload/mods/sleep-repos.json}"
pass=0; fail=0
check(){   # $1 = name  $2 = "ok" or the evidence of failure
  if [ "$2" = ok ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1: $2"; fi
}

if ! command -v python3 >/dev/null 2>&1; then
  echo "FAIL: python3 is not installed, so the lists could not be read"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

# The reader's rules, as readRepoLists applies them: a record, v >= 1, both lists, every entry
# owner/name, mergeDeploys true or false when given, and no repository on both lists.
shape="$(python3 - "$FILE" <<'PY' 2>&1
import json, re, sys
slug = re.compile(r"^[\w.-]+/[\w.-]+$")
try:
    j = json.load(open(sys.argv[1]))
except Exception as e:
    print("does not parse: %s" % e); sys.exit(0)
if not isinstance(j, dict): print("not a record"); sys.exit(0)
v = j.get("v")
if not isinstance(v, (int, float)) or isinstance(v, bool) or v < 1: print("no version"); sys.exit(0)
if not isinstance(j.get("mergeOnly"), list) or not isinstance(j.get("mayDeploy"), list): print("both lists are not there"); sys.exit(0)
for e in j["mayDeploy"]:
    if not isinstance(e, str) or not slug.match(e): print("bad mayDeploy entry %r" % (e,)); sys.exit(0)
for e in j["mergeOnly"]:
    if not isinstance(e, dict) or not isinstance(e.get("repo"), str) or not slug.match(e["repo"]): print("bad mergeOnly entry %r" % (e,)); sys.exit(0)
    if "mergeDeploys" in e and not isinstance(e["mergeDeploys"], bool): print("bad mergeDeploys on %s" % e["repo"]); sys.exit(0)
both = {e["repo"].lower() for e in j["mergeOnly"]} & {r.lower() for r in j["mayDeploy"]}
if both: print("on both lists: %s" % ", ".join(sorted(both))); sys.exit(0)
print("ok")
PY
)"
check "the shipped lists read as the mod reads them" "$shape"

decided="$(python3 - "$FILE" <<'PY' 2>&1
import json, sys
j = json.load(open(sys.argv[1]))
held = {e["repo"].lower(): e.get("mergeDeploys", True) for e in j["mergeOnly"]}
want = ["Halo-lab-Trypennie/trypennie", "Try-Pennie/bidspoke", "Try-Pennie/slate", "danwright32/claude-config"]
missing = [r for r in want if held.get(r.lower()) is not True]
print("ok" if not missing else "not merge only with mergeDeploys true: %s" % ", ".join(missing))
PY
)"
check "trypennie, Bidspoke, Slate and claude-config never merge or deploy overnight" "$decided"

# The suite is seen to fail: a copy on both lists, and one that does not parse. Only from the
# top level run, so the runs it starts do not start runs of their own.
if [ -z "${SLEEP_REPOS_FILE:-}" ]; then
BAD="$(mktemp "${TMPDIR:-/tmp}/sleep-repos.XXXXXX")"
trap 'rm -f "$BAD"' EXIT
printf '{"v":1,"mergeOnly":[{"repo":"o/x"}],"mayDeploy":["O/X"]}\n' > "$BAD"
out="$(SLEEP_REPOS_FILE="$BAD" bash "$0" 2>&1)"
case "$out" in *"on both lists: o/x"*) check "a repository on both lists fails the suite" ok ;; *) check "a repository on both lists fails the suite" "$out" ;; esac
printf '{"v":1,' > "$BAD"
out="$(SLEEP_REPOS_FILE="$BAD" bash "$0" 2>&1)"
case "$out" in *"does not parse"*) check "a file that does not parse fails the suite" ok ;; *) check "a file that does not parse fails the suite" "$out" ;; esac
fi

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
