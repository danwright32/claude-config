#!/usr/bin/env bash
#
# test-block-red-merge.sh — the merge gate, including the rule that a repo
# carrying the commit pinned merge tool must use it (PostRoll #711).
#
# Every case runs the real hook with a fake `gh` first on PATH, so what is
# tested is the hook's own reading of an answer rather than a rewrite of its
# logic living here (L52).

set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/block-red-merge.sh"
passed=0
failed=0

fail() { echo "  FAIL: $1"; failed=$((failed + 1)); }
pass() { passed=$((passed + 1)); }

# A throwaway repo, optionally carrying the merge tool, and a fake gh whose
# answer this test chooses.
make_repo() {  # $1 = with-tool | without-tool ; $2 = rollup json
  local dir; dir=$(mktemp -d)
  mkdir -p "$dir/repo/.git" "$dir/bin"
  if [ "$1" = "with-tool" ]; then
    mkdir -p "$dir/repo/tools"
    printf '#!/usr/bin/env python3\n' > "$dir/repo/tools/wait_for_checks.py"
  fi
  if [ "$1" = "with-npm-tool" ]; then
    mkdir -p "$dir/repo/.github/scripts"
    printf '#!/usr/bin/env bash\n' > "$dir/repo/.github/scripts/merge-pr.sh"
  fi
  cat > "$dir/bin/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"pr view"*) cat <<'JSON'
$2
JSON
  ;;
esac
EOF
  chmod +x "$dir/bin/gh"
  printf '%s' "$dir"
}

run_hook() {  # $1 = repo dir, $2 = command ; prints the hook's stdout
  printf '{"tool_input":{"command":%s},"cwd":%s}' \
    "$(printf '%s' "$2" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
    "$(printf '%s' "$1/repo" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
    | (cd "$1/repo" && PATH="$1/bin:$PATH" bash "$HOOK")
}

GREEN='{"number":7,"statusCheckRollup":[{"name":"tests","conclusion":"SUCCESS"}]}'
RED='{"number":7,"statusCheckRollup":[{"name":"tests","conclusion":"FAILURE"}]}'

denied() { printf '%s' "$1" | grep -q '"permissionDecision": *"deny"'; }

echo "block-red-merge: the commit pinned rule (#711)"

# 1. The rule itself: a repo carrying the tool must merge through it.
dir=$(make_repo with-tool "$GREEN")
out=$(run_hook "$dir" "gh pr merge 7 --squash --delete-branch")
if denied "$out"; then pass; else
  fail "a plain gh pr merge was allowed in a repo that carries the pinned merge tool"
fi
# And the refusal has to say what to run instead, or it is a dead end.
if printf '%s' "$out" | grep -q "wait_for_checks.py 7 --merge"; then pass; else
  fail "the refusal does not name the command to use instead: $out"
fi
rm -rf "$dir"

# 2. Green is not enough on its own. This is the whole point: the rollup can
#    read green for a commit that is no longer the head.
dir=$(make_repo with-tool "$GREEN")
if denied "$(run_hook "$dir" "gh pr merge 7 --squash")"; then pass; else
  fail "a green rollup let a plain merge through in a repo with the tool"
fi
rm -rf "$dir"

# 3. The visible override, for the one case where the tool cannot be used.
dir=$(make_repo with-tool "$GREEN")
if denied "$(run_hook "$dir" "ALLOW_UNPINNED_MERGE=1 gh pr merge 7 --squash")"; then
  fail "the visible override did not let the merge through"
else pass; fi
rm -rf "$dir"

# 4. The control: a repo WITHOUT the tool still merges the old way, or this
#    rule would have quietly blocked every other project (L159).
dir=$(make_repo without-tool "$GREEN")
if denied "$(run_hook "$dir" "gh pr merge 7 --squash")"; then
  fail "a green PR in a repo without the tool was blocked"
else pass; fi
rm -rf "$dir"

# 5. And a red one there is still refused, so the old gate is intact.
dir=$(make_repo without-tool "$RED")
if denied "$(run_hook "$dir" "gh pr merge 7 --squash")"; then pass; else
  fail "a red PR was allowed to merge"
fi
rm -rf "$dir"

# 6. Anything that is not a merge is none of this hook's business.
dir=$(make_repo with-tool "$GREEN")
if denied "$(run_hook "$dir" "gh pr view 7")"; then
  fail "the hook blocked a command that was not a merge"
else pass; fi
rm -rf "$dir"


# 6. The second pinned tool: a repo whose merge goes through its own shell
#    wrapper is held to the same rule, and the refusal names ITS command.
#    Without this, adding a tool to the table would be untested and the rule
#    would silently apply to one repo only.
dir=$(make_repo with-npm-tool "$GREEN")
out=$(run_hook "$dir" "gh pr merge 7 --squash --delete-branch")
if denied "$out"; then pass; else
  fail "a plain gh pr merge was allowed in a repo that carries a shell merge wrapper"
fi
if printf '%s' "$out" | grep -q "npm run merge -- 7"; then pass; else
  fail "the refusal does not name the wrapper's own command: $out"
fi
# It must name the tool it found, not the other repo's, or the message sends
# somebody to a file that is not there.
if printf '%s' "$out" | grep -q "wait_for_checks"; then
  fail "the refusal names the other repo's tool: $out"
else pass; fi
rm -rf "$dir"

# 7. The visible override works for the second tool too.
dir=$(make_repo with-npm-tool "$GREEN")
if denied "$(run_hook "$dir" "ALLOW_UNPINNED_MERGE=1 gh pr merge 7 --squash")"; then
  fail "the visible override did not let the merge through for the shell wrapper"
else pass; fi
rm -rf "$dir"

# 8. And a red PR there is still refused by the ORIGINAL gate, reached through
#    the override, so the two rules do not answer for each other (L178).
dir=$(make_repo with-npm-tool "$RED")
if denied "$(run_hook "$dir" "ALLOW_UNPINNED_MERGE=1 gh pr merge 7 --squash")"; then pass; else
  fail "a red PR was allowed through once the pinned-tool rule was overridden"
fi
rm -rf "$dir"

echo "  $passed passed, $failed failed"
[ "$failed" -eq 0 ]
