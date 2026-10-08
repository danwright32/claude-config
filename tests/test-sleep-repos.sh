#!/bin/bash
# Tests for payload/mods/sleep-repos.json, sleep mode's per repository merge and deploy lists
# (claude-config#843). The mod reads it with readRepoLists (mods/scope-modes/hooks/mergedeploy.ts),
# which closes every repository for the night when the file does not read, so a shipped file that
# does not parse would silently stop every overnight merge. This holds the shipped file to the same
# shape that reader requires, and to Dan's overnight decision as he confirmed it on 2026-10-07,
# which replaced decision 6 and the list phase 7 first shipped:
#   wait (no merge, no deploy, the green PR stays open until morning): Try-Pennie/bidspoke,
#     Try-Pennie/slate, and every repository owned by Halo-lab-Trypennie, now and later ("Move
#     ANYTHING in halo-lab-trypennie to the wait list automatically. Nothing in that account should
#     merge overnight");
#   merge and deploy as in the daytime: the thirteen in MAY_DEPLOY below;
#   anything else is asked once at bedtime, as before.
# How the mod applies waitOwners (any case, ahead of both lists) is proved by its own tests in
# payload/mods/scope-modes/tests/mergedeploy.test.ts; the effect check here reads the shipped file
# with that same precedence, so the decision is held on CI, where the mod tests cannot run.
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
# owner/name, mergeDeploys true or false when given, waitOwners (when given) a list of owner names,
# no repository on both lists, and (stricter than the reader, which waits on it) no entry under an
# owner that waits, so the shipped file never carries a conflict.
shape="$(python3 - "$FILE" <<'PY' 2>&1
import json, re, sys
slug = re.compile(r"^[\w.-]+/[\w.-]+$")
owner = re.compile(r"^[\w.-]+$")
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
w = j.get("waitOwners", [])
if not isinstance(w, list): print("waitOwners is not a list"); sys.exit(0)
for e in w:
    if not isinstance(e, str) or not owner.match(e): print("bad waitOwners entry %r" % (e,)); sys.exit(0)
both = {e["repo"].lower() for e in j["mergeOnly"]} & {r.lower() for r in j["mayDeploy"]}
if both: print("on both lists: %s" % ", ".join(sorted(both))); sys.exit(0)
waiting = {o.lower() for o in w}
under = sorted(r for r in [e["repo"] for e in j["mergeOnly"]] + j["mayDeploy"] if r.split("/")[0].lower() in waiting)
if under: print("listed under an owner that waits: %s" % ", ".join(under)); sys.exit(0)
print("ok")
PY
)"
check "the shipped lists read as the mod reads them" "$shape"

# Dan's decision, exactly: each list holds these and nothing else.
decided="$(python3 - "$FILE" <<'PY' 2>&1
import json, sys
j = json.load(open(sys.argv[1]))
WAIT_OWNERS = ["Halo-lab-Trypennie"]
WAIT = ["Try-Pennie/bidspoke", "Try-Pennie/slate"]
MAY_DEPLOY = [
    "danwright32/claude-config", "Try-Pennie/project-enrollment-tracker", "Try-Pennie/paperboi",
    "Try-Pennie/sonar", "dwright-pennie/new-agent-onboarding", "dwright-pennie/repo-digest",
    "danwright32/overture", "danwright32/ovation", "danwright32/downbeat", "danwright32/PostRoll",
    "danwright32/backstage", "PlayedItApp/playedit", "nursedexapp/nursedex",
]
low = lambda xs: sorted(x.lower() for x in xs)
bad = []
if low(j.get("waitOwners", [])) != low(WAIT_OWNERS): bad.append("waitOwners is %s, not %s" % (j.get("waitOwners"), WAIT_OWNERS))
held = [e for e in j["mergeOnly"]]
if low(e["repo"] for e in held) != low(WAIT): bad.append("mergeOnly holds %s, not %s" % ([e["repo"] for e in held], WAIT))
loose = [e["repo"] for e in held if e.get("mergeDeploys") is not True]
if loose: bad.append("not held (mergeDeploys true): %s" % ", ".join(loose))
if low(j["mayDeploy"]) != low(MAY_DEPLOY):
    have, want = set(low(j["mayDeploy"])), set(low(MAY_DEPLOY))
    bad.append("mayDeploy differs: missing %s, extra %s" % (sorted(want - have), sorted(have - want)))
print("ok" if not bad else "; ".join(bad))
PY
)"
check "the lists hold exactly Dan's 2026-10-07 decision" "$decided"

# What each repository does overnight, read with the mod's precedence: an owner that waits first,
# then mayDeploy, then mergeOnly (a merge runs only where mergeDeploys is false), else asked.
effect="$(python3 - "$FILE" <<'PY' 2>&1
import json, sys
j = json.load(open(sys.argv[1]))
waiting = {o.lower() for o in j.get("waitOwners", [])}
def night(repo):
    if repo.split("/")[0].lower() in waiting: return "wait"
    if repo.lower() in {r.lower() for r in j["mayDeploy"]}: return "deploy"
    for e in j["mergeOnly"]:
        if e["repo"].lower() == repo.lower(): return "merge" if e.get("mergeDeploys") is False else "wait"
    return "asked"
want = {
    "Halo-lab-Trypennie/trypennie": "wait",
    # a repository made under that owner after today, which no list names
    "Halo-lab-Trypennie/a-repo-made-next-year": "wait",
    # the owner in another case
    "HALO-LAB-TRYPENNIE/trypennie": "wait",
    "halo-lab-trypennie/Another": "wait",
    "Try-Pennie/bidspoke": "wait",
    "try-pennie/Slate": "wait",
    "danwright32/claude-config": "deploy",
    "nursedexapp/nursedex": "deploy",
    "Try-Pennie/eavesly-web-app": "asked",
    "dwright-pennie/eavesly-web-app": "asked",
}
wrong = ["%s is %s, not %s" % (r, night(r), w) for r, w in want.items() if night(r) != w]
print("ok" if not wrong else "; ".join(wrong))
PY
)"
check "every Halo-lab-Trypennie repository waits, any case, listed or not; others keep the decision" "$effect"

# The suite is seen to fail: a copy on both lists, one that does not parse, one listing a
# repository under an owner that waits, and one where a Halo-lab-Trypennie repository could
# deploy. Only from the top level run, so the runs it starts do not start runs of their own.
if [ -z "${SLEEP_REPOS_FILE:-}" ]; then
BAD="$(mktemp "${TMPDIR:-/tmp}/sleep-repos.XXXXXX")"
trap 'rm -f "$BAD"' EXIT
printf '{"v":1,"mergeOnly":[{"repo":"o/x"}],"mayDeploy":["O/X"]}\n' > "$BAD"
out="$(SLEEP_REPOS_FILE="$BAD" bash "$0" 2>&1)"
case "$out" in *"on both lists: o/x"*) check "a repository on both lists fails the suite" ok ;; *) check "a repository on both lists fails the suite" "$out" ;; esac
printf '{"v":1,' > "$BAD"
out="$(SLEEP_REPOS_FILE="$BAD" bash "$0" 2>&1)"
case "$out" in *"does not parse"*) check "a file that does not parse fails the suite" ok ;; *) check "a file that does not parse fails the suite" "$out" ;; esac
python3 - "$ROOT/payload/mods/sleep-repos.json" "$BAD" <<'PY'
import json, sys
j = json.load(open(sys.argv[1])); j["mayDeploy"].append("halo-lab-trypennie/trypennie")
json.dump(j, open(sys.argv[2], "w"))
PY
out="$(SLEEP_REPOS_FILE="$BAD" bash "$0" 2>&1)"
case "$out" in *"listed under an owner that waits: halo-lab-trypennie/trypennie"*) check "a mayDeploy entry under an owner that waits fails the suite" ok ;; *) check "a mayDeploy entry under an owner that waits fails the suite" "$out" ;; esac
python3 - "$ROOT/payload/mods/sleep-repos.json" "$BAD" <<'PY'
import json, sys
j = json.load(open(sys.argv[1])); j.pop("waitOwners", None)
json.dump(j, open(sys.argv[2], "w"))
PY
out="$(SLEEP_REPOS_FILE="$BAD" bash "$0" 2>&1)"
case "$out" in *"a-repo-made-next-year is asked, not wait"*) check "a file without the owner rule fails the suite" ok ;; *) check "a file without the owner rule fails the suite" "$out" ;; esac
fi

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
