#!/usr/bin/env bash
# A whole tree scan: a send touching these paths runs this suite (claude-config#809).
# send-gate: scans hooks/ skills/
# Tests for lib/repo_slug.py, the one place a GitHub repository object becomes an owner/name slug,
# and for lib/hand-rolled-slug.py, the scan that fails on the next hook building it by hand
# (claude-config#2096, L613).
#
# Three hooks each joined owner.login and name themselves, and #2065 came from one of them reading a
# field gh does not send (nameWithOwner, absent from closingIssuesReferences), so every cross
# repository close was judged in the wrong repository. One helper, read by all three, and a scan over
# every Python file the repository ships, so the fourth copy is refused on the day it is written.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$DIR/lib/repo_slug.py"
SCAN="$DIR/lib/hand-rolled-slug.py"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/repo-slug.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "FAIL: could not make a scratch folder (got '$TMPROOT')"; printf 'SUITE-RESULT passed=0 failed=1\n'; exit 1 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

pass=0
fail=0
check_eq() { if [[ "$3" == "$2" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 (expected '$2', got '$3')"; fi; }

# ---- the helper ----
# Each case prints one line: the slug, or "refused: <message>" when it raised RepoSlugError. Anything
# else it raised is printed as "crashed", which no expectation below accepts.
cat > "$TMPROOT/cases.py" <<'PY'
import importlib.util, json, sys
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("repo_slug", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
for line in sys.stdin:
    if not line.strip():
        continue
    value = json.loads(line)
    try:
        print(mod.slug(value))
    except mod.RepoSlugError as exc:
        print("refused: %s" % exc)
    except Exception as exc:
        print("crashed: %s: %s" % (type(exc).__name__, exc))
print("is a ValueError" if issubclass(mod.RepoSlugError, ValueError) else "not a ValueError")
PY
run_cases() { printf '%s\n' "$@" | python3 "$TMPROOT/cases.py" "$HELPER" 2>&1; }
nth() { sed -n "${2}p" <<< "$1"; }

out="$(run_cases \
  '{"id":"R_kgDOTB20Bw","name":"slate","owner":{"id":"MDQ6","login":"acme"}}' \
  '{"nameWithOwner":"acme/site","name":"ignored","owner":{"login":"ignored"}}' \
  '{"nameWithOwner":"noslash","name":"slate","owner":{"login":"acme"}}' \
  '{"id":"R_kgDOTB20Bw","name":"slate"}' \
  '{"name":"slate","owner":{"id":"MDQ6"}}' \
  '{"owner":{"login":"acme"}}' \
  '{"name":"slate","owner":{"login":""}}' \
  'null' \
  '{"name":"a/b","owner":{"login":"acme"}}' \
  '{"name":"slate","owner":"acme"}' \
  '{"nameWithOwner":"acme/","name":"slate","owner":{"login":"acme"}}')"
check_eq "#2065 gh's real closingIssuesReferences shape, owner.login and name with no nameWithOwner, gives the slug" \
  "acme/slate" "$(nth "$out" 1)"
check_eq "nameWithOwner, where gh sends it, is the slug" "acme/site" "$(nth "$out" 2)"
case "$(nth "$out" 3)" in "refused: "*nameWithOwner*) r=refused ;; *) r="$(nth "$out" 3)" ;; esac
check_eq "a nameWithOwner that is not owner/name is refused, never passed on or guessed around" "refused" "$r"
case "$(nth "$out" 4)" in "refused: "*owner.login*) r=refused ;; *) r="$(nth "$out" 4)" ;; esac
check_eq "a repository with no owner is refused, naming owner.login, never a half slug" "refused" "$r"
case "$(nth "$out" 5)" in "refused: "*owner.login*) r=refused ;; *) r="$(nth "$out" 5)" ;; esac
check_eq "an owner with no login is refused, naming owner.login" "refused" "$r"
case "$(nth "$out" 6)" in "refused: "*name*) r=refused ;; *) r="$(nth "$out" 6)" ;; esac
check_eq "a repository with no name is refused, naming name" "refused" "$r"
case "$(nth "$out" 7)" in "refused: "*) r=refused ;; *) r="$(nth "$out" 7)" ;; esac
check_eq "an empty login is refused, never joined into '/slate'" "refused" "$r"
case "$(nth "$out" 8)" in "refused: "*) r=refused ;; *) r="$(nth "$out" 8)" ;; esac
check_eq "no repository object at all is refused" "refused" "$r"
case "$(nth "$out" 9)" in "refused: "*) r=refused ;; *) r="$(nth "$out" 9)" ;; esac
check_eq "a name holding a slash is refused, since the slug would name some other path" "refused" "$r"
case "$(nth "$out" 10)" in "refused: "*owner.login*) r=refused ;; *) r="$(nth "$out" 10)" ;; esac
check_eq "an owner given as bare text is not gh's repository shape and is refused" "refused" "$r"
case "$(nth "$out" 11)" in "refused: "*nameWithOwner*) r=refused ;; *) r="$(nth "$out" 11)" ;; esac
check_eq "a nameWithOwner with an empty half is refused" "refused" "$r"
check_eq "the refusal is a ValueError, so every caller's existing ValueError handling sees it" \
  "is a ValueError" "$(nth "$out" 12)"

# ---- the callers ----
# closing-keyword.py pr: a closing reference whose repository cannot be read stops the check (exit
# 3) rather than reading as a pull request that closes nothing.
CK="$DIR/lib/closing-keyword.py"
printf '{"body":"Closes acme/slate#4","closingIssuesReferences":[{"number":4,"repository":{"id":"R_x","name":"slate"}}]}' \
  | python3 "$CK" pr acme/site >/dev/null 2>&1; rc=$?
check_eq "closing-keyword: a closing reference with no owner stops the check" "3" "$rc"
out="$(printf '{"body":"Closes acme/slate#4","closingIssuesReferences":[{"number":4,"repository":{"id":"R_x","name":"Slate","owner":{"id":"U","login":"Acme"}}}]}' \
  | python3 "$CK" pr acme/site 2>&1)"; rc=$?
check_eq "closing-keyword: a cross repository close in gh's real shape is matched, so nothing is reported" "0 " "$rc $out"

# sleep-report.py refs: a reference naming no repository is the report's own; one whose repository
# is present but unreadable is left out, never attributed to the report's repository by guess.
cat > "$TMPROOT/refs.py" <<'PY'
import importlib.util, json, sys
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("sleep_report", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
items = [
    {"number": 1, "repository": {"name": "Slate", "owner": {"login": "Acme"}}},
    {"number": 2},
    {"number": 3, "repository": {"id": "R_x", "name": "slate"}},
]
print(json.dumps(mod.refs(items, "acme/Site")))
PY
out="$(python3 "$TMPROOT/refs.py" "$DIR/lib/sleep-report.py" 2>&1)"
check_eq "sleep-report: own repository for none, the slug for a readable one, and an unreadable one left out" \
  '[["acme/slate", 1], ["acme/site", 2]]' "$out"

# ---- the scan, on a planted hand written join ----
mkdir -p "$TMPROOT/scan/payload/hooks/lib"
cat > "$TMPROOT/scan/payload/hooks/probe.py" <<'PY'
slug = "%s/%s" % (r["repository"]["owner"]["login"], r["repository"]["name"])

login, name = owner.get("login"), rp.get("name")
if login and name:
    return "%s/%s" % (login, name)





author = (i.get("author") or {}).get("login")





# slug = "%s/%s" % (owner["login"], name) is what this used to say
s = f"{o['login']}/{rp['name']}"
s = o["login"] + "/" + rp["name"]
s = "/".join((o.get("login"), rp.get("name")))
"""A docstring quoting the old way:
   "%s/%s" % (owner["login"], name)
"""




print("%s/%s" % (a, b))
PY
cp "$TMPROOT/scan/payload/hooks/probe.py" "$TMPROOT/scan/payload/hooks/probe.sh"
cp "$HELPER" "$TMPROOT/scan/payload/hooks/lib/repo_slug.py"
probe="$(printf 'payload/hooks/probe.py\npayload/hooks/probe.sh\npayload/hooks/lib/repo_slug.py\n' | python3 "$SCAN" --root "$TMPROOT/scan" 2>&1)"; probe_rc=$?
probe_lines="$(printf '%s\n' "$probe" | awk -F: 'NF { printf "%s:%s ", $1, $2 }')"
check_eq "the scan reports each hand written join (subscript, get, f-string, plus, join), and not a lone login read, a comment, a docstring, a shell file or the helper" \
  "1 payload/hooks/probe.py:1 payload/hooks/probe.py:3 payload/hooks/probe.py:18 payload/hooks/probe.py:19 payload/hooks/probe.py:20 " \
  "$probe_rc $probe_lines"
printf 'payload/hooks/gone.py\n' | python3 "$SCAN" --root "$TMPROOT/scan" >/dev/null 2>&1; rc=$?
check_eq "a listed Python file the scan cannot read stops it, rather than reading as clean" "2" "$rc"

# ---- the scan, on every Python file this repository ships ----
SELF_TOP="$(bash "$DIR/lib/checkout-root.sh" "$DIR/.." 2>/dev/null || true)"
FILES=""
[ -n "$SELF_TOP" ] && FILES="$(bash "$DIR/lib/repo-files.sh" "$SELF_TOP" 2>/dev/null || true)"
if [ -n "$SELF_TOP" ] && [ -n "$FILES" ]; then
  count="$(printf '%s\n' "$FILES" | grep -c '\.py$' || true)"
  if [ "${count:-0}" -gt 0 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: the repository listing held no Python file, so the scan below would read nothing"; fi
  found="$(printf '%s\n' "$FILES" | python3 "$SCAN" --root "$SELF_TOP" 2>&1)"; found_rc=$?
  check_eq "#2096 no Python file builds owner/name by hand; each asks lib/repo_slug.py" \
    "0" "$found_rc${found:+
$found}"
else
  echo "SUITE-PART-UNMEASURED this copy is not in a claude-config checkout, so its Python files were not scanned for a hand written slug"
fi

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
