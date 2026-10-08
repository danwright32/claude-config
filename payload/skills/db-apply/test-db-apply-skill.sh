#!/usr/bin/env bash
# Tests for the db-apply skill's instructions and its one shell command (claude-config#684).
#
# Three things were wrong on 2026-10-08. The schema step named `mcp__supabase__list_tables`, a
# server prefix current sessions do not use (they expose `mcp__claude_ai_Supabase__list_tables`),
# so a session looking for that exact name found nothing. The ad hoc path depended on psql, which
# is not installed on Daniels-MacBook-Pro-2, and invited copying the connection string from
# .env.local into a command, which puts a database password in the transcript. And "non
# interactive flags only" named no flags.
#
# Nothing here reaches a database. The psql command is run against a stub psql on PATH and a
# fixture env file holding an invented secret, and the check is that the stub received it while
# nothing the command printed contains it (L2, L222).
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$DIR/SKILL.md"

pass=0
fail=0
check() { # check <description> <result>   ("ok" passes, anything else is the failure text)
  if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/db-apply-skill.XXXXXXXX")" || TMP=""
case "${TMP%/}" in
  ''|/|"${HOME%/}") echo "test-db-apply-skill: refusing to run: throwaway directory came back as '$TMP'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMP"' EXIT

check "the skill is there to read" "$([ -f "$SKILL" ] && echo ok || echo "no $SKILL")"
# Fences inside a numbered list are indented, so the indent is allowed and then removed.
CODE="$(awk '/^[[:space:]]*```/ { inside = !inside; next } inside { sub(/^[[:space:]]+/, ""); print }' "$SKILL")"

# ---- 1. Supabase MCP tools are named without a server prefix ----
# The prefix depends on how the server is connected (claude.ai connector or a local server), so a
# full name is right in one session and absent in the next. The bare tool name is what both share.
check "no MCP tool is named with a server prefix" \
  "$(grep -m 1 -oE 'mcp__[A-Za-z0-9_-]+__[A-Za-z0-9_]+' "$SKILL" | sed 's/^/still names /' | grep . || echo ok)"
for tool in list_tables execute_sql list_migrations; do
  check "the Supabase MCP tool $tool is named, as \`$tool\`" \
    "$(grep -qF "\`$tool\`" "$SKILL" && echo ok || echo "not named in $SKILL")"
done

# ---- 2. the flags that keep the CLI non interactive are named ----
check "migrations are previewed with supabase db push --dry-run" \
  "$(grep -qF 'supabase db push --dry-run' <<< "$CODE" && echo ok || echo "no dry run command")"
check "and applied with supabase db push --yes, so no prompt is left hanging" \
  "$(grep -qF 'supabase db push --yes' <<< "$CODE" && echo ok || echo "no --yes command")"

# ---- 3. no command carries a secret ----
check "no command passes a connection string or password on the command line" \
  "$(grep -qE -- '--db-url|--password|(^| )-p |postgres(ql)?://' <<< "$CODE" && echo "found in a command block" || echo ok)"

# ---- 4. psql is optional, and the command keeps the connection string out of the transcript ----
psql_line="$(grep -m 1 -E '(^|[^a-z_])psql ' <<< "$CODE")"
check "there is a psql command to test" "$([ -n "$psql_line" ] && echo ok || echo "no psql command in a block")"
check "the psql command checks psql is installed before using it" \
  "$(grep -qF 'command -v psql' <<< "$psql_line" && echo ok || echo "the line is: $psql_line")"
# A path that needs no psql must come first, so a Mac without it is not a dead end.
first_exec="$(grep -m 1 -n -F '`execute_sql`' "$SKILL" | cut -d: -f1)"
first_psql="$(grep -m 1 -n 'psql' "$SKILL" | cut -d: -f1)"
check "execute_sql is offered before psql" \
  "$([ -n "$first_exec" ] && [ -n "$first_psql" ] && [ "$first_exec" -lt "$first_psql" ] && echo ok || echo "execute_sql at line ${first_exec:-none}, psql at ${first_psql:-none}")"

SECRET="pw-not-real-$$"
WORK="$TMP/project"; mkdir -p "$WORK"
printf 'NEXT_PUBLIC_X=1\nDATABASE_URL="postgresql://user:%s@db.example.invalid:5432/postgres"\n' "$SECRET" > "$WORK/.env.local"
printf 'select 1;\n' > "$WORK/change.sql"

# The tools the line needs, and nothing else, so psql present and absent are both decided here
# rather than by whatever this machine or the CI runner has installed (L411).
mkbin(){   # mkbin <dir> <tool...>
  local d="$1" t p; shift; mkdir -p "$d"
  for t in "$@"; do p="$(command -v "$t")" && ln -s "$p" "$d/$t"; done
}
mkbin "$TMP/bin-with" sed head tr cat
mkbin "$TMP/bin-without" sed head tr cat
cat > "$TMP/bin-with/psql" <<STUB
#!/bin/bash
printf '%s\n' "\$@" > "$TMP/psql-args"
echo "stub psql ran"
STUB
chmod +x "$TMP/bin-with/psql"

out="$(cd "$WORK" && PATH="$TMP/bin-with" /bin/bash -c "$psql_line" 2>&1)"; rc=$?
check "with psql installed the command runs it" \
  "$([ "$rc" -eq 0 ] && grep -q 'stub psql ran' <<< "$out" && echo ok || echo "exit $rc, said: $out")"
check "and hands it the connection string from the env file, with its quotes removed" \
  "$(grep -qx "postgresql://user:$SECRET@db.example.invalid:5432/postgres" "$TMP/psql-args" 2>/dev/null && echo ok || echo "psql got: $(cat "$TMP/psql-args" 2>/dev/null)")"
check "and stops on the first error, in one transaction" \
  "$(grep -qx 'ON_ERROR_STOP=1' "$TMP/psql-args" 2>/dev/null && grep -qx -- '-1' "$TMP/psql-args" 2>/dev/null && echo ok || echo "psql got: $(cat "$TMP/psql-args" 2>/dev/null)")"
check "and nothing it printed contains the secret" \
  "$(grep -qF "$SECRET" <<< "$out" && echo "printed the secret" || echo ok)"
check "and the command as written holds no secret of its own" \
  "$(grep -qF "$SECRET" <<< "$psql_line" && echo "secret in the command" || echo ok)"

out="$(cd "$WORK" && PATH="$TMP/bin-without" /bin/bash -c "$psql_line" 2>&1)"; rc=$?
check "without psql the command fails, rather than reading as a run that changed nothing" \
  "$([ "$rc" -ne 0 ] && echo ok || echo "exit $rc, said: $out")"
check "and says psql is not installed" \
  "$(grep -qi 'psql is not installed' <<< "$out" && echo ok || echo "said: $out")"

echo ""
echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
