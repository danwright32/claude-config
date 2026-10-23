#!/bin/bash
# Tests for sleep mode's per repository merge and deploy lists (claude-config#843), which are each
# Mac's own ~/.claude/mods/sleep-repos.local.json since claude-config#1568: they name work
# repositories, and this repository is public, so the lists Dan confirmed on 2026-10-07 live only
# on his Macs. The mod reads the file with readRepoLists (mods/scope-modes/hooks/mergedeploy.ts),
# which closes every repository for the night when it does not read, so a file that does not parse
# would silently stop every overnight merge.
#
# What is held here:
#   1. The shape the reader requires, and the precedence it applies (an owner that waits first, in
#      any case, then mayDeploy, then mergeOnly, else asked), on an invented fixture shaped like
#      Dan's decision: two repositories held with mergeDeploys true, every repository of one owner
#      waiting whether or not a list names it, and the rest allowed to deploy. The mod's own tests
#      prove the reader; this holds the same rules on CI, where the mod tests cannot run.
#   2. The checks can fail: a copy on both lists, one that does not parse, one listing a repository
#      under an owner that waits, and one without the owner rule.
#   3. This Mac's own file, when it has one, reads as the mod reads it. A Mac without one is said,
#      not failed: the mod then closes every repository for the night and says why itself.
# No work organisation or repository name belongs in this file.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
. "$ROOT/payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?
pass=0; fail=0
check(){   # $1 = name  $2 = "ok" or the evidence of failure
  if [ "$2" = ok ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1: $2"; fi
}

if ! command -v python3 >/dev/null 2>&1; then
  echo "FAIL: python3 is not installed, so the lists could not be read"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/sleep-repos.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# The reader's rules, as readRepoLists applies them: a record, v >= 1, both lists, every entry
# owner/name, mergeDeploys true or false when given, waitOwners (when given) a list of owner names,
# no repository on both lists, and (stricter than the reader, which waits on it) no entry under an
# owner that waits, so a file never carries a conflict.
shape_of(){   # $1 = a lists file -> "ok" or what is wrong
  python3 - "$1" <<'PY' 2>&1
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
}

# What each repository does overnight, read with the mod's precedence.
effect_of(){   # $1 = a lists file -> "ok" or each repository that does the wrong thing
  python3 - "$1" <<'PY' 2>&1
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
    "Studio-Partner/website": "wait",
    # a repository made under that owner after today, which no list names
    "Studio-Partner/a-repo-made-next-year": "wait",
    # the owner in another case
    "STUDIO-PARTNER/website": "wait",
    "studio-partner/Another": "wait",
    "Acme-Corp/bidboard": "wait",
    "acme-corp/Storefront": "wait",
    "danwright32/claude-config": "deploy",
    "nursedexapp/nursedex": "deploy",
    "Acme-Corp/listener-app": "asked",
}
wrong = ["%s is %s, not %s" % (r, night(r), w) for r, w in want.items() if night(r) != w]
print("ok" if not wrong else "; ".join(wrong))
PY
}

# ---------------------------------------------------------------- 1. the rules, on a fixture
FIX="$WORK/fixture.json"
cat > "$FIX" <<'JSON'
{
  "v": 1,
  "waitOwners": ["Studio-Partner"],
  "mergeOnly": [
    { "repo": "Acme-Corp/bidboard", "mergeDeploys": true },
    { "repo": "Acme-Corp/storefront", "mergeDeploys": true }
  ],
  "mayDeploy": ["danwright32/claude-config", "Acme-Corp/enrollment-board", "nursedexapp/nursedex"]
}
JSON
check "a file shaped like Dan's decision reads as the mod reads it" "$(shape_of "$FIX")"
check "every repository of an owner that waits waits, in any case, listed or not; others keep their list" "$(effect_of "$FIX")"

# ---------------------------------------------------------------- 2. the checks can fail
BAD="$WORK/bad.json"
printf '{"v":1,"mergeOnly":[{"repo":"o/x"}],"mayDeploy":["O/X"]}\n' > "$BAD"
out="$(shape_of "$BAD")"
case "$out" in *"on both lists: o/x"*) check "a repository on both lists is caught" ok ;; *) check "a repository on both lists is caught" "$out" ;; esac
printf '{"v":1,' > "$BAD"
out="$(shape_of "$BAD")"
case "$out" in *"does not parse"*) check "a file that does not parse is caught" ok ;; *) check "a file that does not parse is caught" "$out" ;; esac
python3 - "$FIX" "$BAD" <<'PY'
import json, sys
j = json.load(open(sys.argv[1])); j["mayDeploy"].append("studio-partner/website")
json.dump(j, open(sys.argv[2], "w"))
PY
out="$(shape_of "$BAD")"
case "$out" in *"listed under an owner that waits: studio-partner/website"*) check "a mayDeploy entry under an owner that waits is caught" ok ;; *) check "a mayDeploy entry under an owner that waits is caught" "$out" ;; esac
python3 - "$FIX" "$BAD" <<'PY'
import json, sys
j = json.load(open(sys.argv[1])); j.pop("waitOwners", None)
json.dump(j, open(sys.argv[2], "w"))
PY
out="$(effect_of "$BAD")"
case "$out" in *"a-repo-made-next-year is asked, not wait"*) check "a file without the owner rule is caught" ok ;; *) check "a file without the owner rule is caught" "$out" ;; esac

# ---------------------------------------------------------------- 3. this Mac's own file
MINE="${SLEEP_REPOS_FILE:-$HOME/.claude/mods/sleep-repos.local.json}"
if [ -f "$MINE" ]; then
  check "this Mac's own lists ($MINE) read as the mod reads them" "$(shape_of "$MINE")"
else
  echo "note: this machine has no $MINE, so its own lists were not checked here (CI has none). Sleep mode closes every repository for the night without it, and says so."
fi

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
