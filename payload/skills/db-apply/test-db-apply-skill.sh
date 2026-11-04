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

# An env file written with `export` must still be read.
W2="$TMP/project-export"; mkdir -p "$W2"
printf 'export DATABASE_URL=postgresql://user:%s@db.example.invalid:5432/postgres\n' "$SECRET" > "$W2/.env.local"
rm -f "$TMP/psql-args"
out="$(cd "$W2" && PATH="$TMP/bin-with" /bin/bash -c "$psql_line" 2>&1)"; rc=$?
check "an env file written as export DATABASE_URL=... is read too" \
  "$([ "$rc" -eq 0 ] && grep -qx "postgresql://user:$SECRET@db.example.invalid:5432/postgres" "$TMP/psql-args" 2>/dev/null && echo ok || echo "exit $rc, said: $out, psql got: $(cat "$TMP/psql-args" 2>/dev/null)")"

# No such variable: psql must NOT run, because an empty connection argument makes psql fall back to
# its default local database, which is a different database from the one meant (L75).
W3="$TMP/project-unset"; mkdir -p "$W3"
printf 'OTHER=1\n' > "$W3/.env.local"
rm -f "$TMP/psql-args"
out="$(cd "$W3" && PATH="$TMP/bin-with" /bin/bash -c "$psql_line" 2>&1)"; rc=$?
check "with no DATABASE_URL in the env file, psql is never started" \
  "$([ "$rc" -ne 0 ] && [ ! -f "$TMP/psql-args" ] && echo ok || echo "exit $rc, said: $out")"
check "and the refusal says the variable is not set" \
  "$(grep -qi 'DATABASE_URL is not set' <<< "$out" && echo ok || echo "said: $out")"

# No env file at all is its own cause, named as such rather than blamed on the variable (L11).
W4="$TMP/project-no-env"; mkdir -p "$W4"
rm -f "$TMP/psql-args"
out="$(cd "$W4" && PATH="$TMP/bin-with" /bin/bash -c "$psql_line" 2>&1)"; rc=$?
check "with no env file, psql is never started and the refusal names the missing file" \
  "$([ "$rc" -ne 0 ] && [ ! -f "$TMP/psql-args" ] && grep -qi 'no .env.local here' <<< "$out" && echo ok || echo "exit $rc, said: $out")"

# ---- 5. linked projects write through supabase db query, ahead of psql (claude-config#2144) ----
# On the work MacBook a hook refuses every command that reads .env.local, so the psql path can never
# run there and the session fell through to handing Dan SQL. The linked path needs no secret in the
# command at all, so it must come first, must not read an env file, and, because it reports no row
# count for a write, must be paired with a guard block that rolls back on a wrong count.
linked_line="$(grep -m 1 -F 'supabase db query --linked --yes -f' <<< "$CODE")"
check "there is a supabase db query --linked --yes -f command to test" \
  "$([ -n "$linked_line" ] && echo ok || echo "no linked db query command in a block")"
first_linked="$(grep -m 1 -n -F 'supabase db query --linked --yes -f' "$SKILL" | cut -d: -f1)"
psql_cmd_at="$(grep -m 1 -n -E 'psql "\$url"' "$SKILL" | cut -d: -f1)"
check "the linked path is offered before the psql command" \
  "$([ -n "$first_linked" ] && [ -n "$psql_cmd_at" ] && [ "$first_linked" -lt "$psql_cmd_at" ] && echo ok || echo "linked at line ${first_linked:-none}, psql at ${psql_cmd_at:-none}")"
check "the linked command reads no env file" \
  "$(grep -qE '\.env|\.dev\.vars' <<< "$linked_line" && echo "the line is: $linked_line" || echo ok)"

# The guard: one fenced block that wraps the write in do $$ ... end $$ and refuses a wrong count.
guard_block="$(awk '
  /^[[:space:]]*```/ {
    if (inside && buf ~ /get diagnostics/ && buf ~ /raise exception/) { printf "%s", buf; exit }
    inside = !inside; buf = ""; next
  }
  inside { sub(/^[[:space:]]+/, ""); buf = buf $0 "\n" }' "$SKILL")"
check "a documented block holds both get diagnostics and raise exception" \
  "$([ -n "$guard_block" ] && echo ok || echo "no fenced block holds both")"
check "and that block wraps the write in do \$\$ ... end \$\$ and reads row_count" \
  "$(grep -qF 'do $$' <<< "$guard_block" && grep -qF 'end $$;' <<< "$guard_block" && grep -qF 'row_count' <<< "$guard_block" && echo ok || echo "block is: $guard_block")"
check "and it refuses any count other than the expected one, not only zero" \
  "$(grep -qE 'if n <> [0-9]+ then' <<< "$guard_block" && echo ok || echo "block is: $guard_block")"
guard_at="$(grep -m 1 -n -F 'get diagnostics' "$SKILL" | cut -d: -f1)"
check "the guard block sits with the linked path, ahead of psql" \
  "$([ -n "$guard_at" ] && [ -n "$psql_cmd_at" ] && [ "$guard_at" -lt "$psql_cmd_at" ] && echo ok || echo "guard at line ${guard_at:-none}, psql at ${psql_cmd_at:-none}")"
check "the skill says which supabase CLI version the command was checked against" \
  "$(grep -qE 'checked against [^.]*[0-9]+\.[0-9]+\.[0-9]+' "$SKILL" && echo ok || echo "no version named")"
check "the skill says the write is read back after it runs" \
  "$(linked_section="$(awk '/supabase db query --linked/,/psql "\$url"/' "$SKILL")"; grep -qi 'read it back\|read back' <<< "$linked_section" && echo ok || echo "no read back step on the linked path")"

# The command line itself, against stub supabase CLIs that behave as each real version was measured
# or documented to (claude-config#2189). Every stub writes each call it gets to supabase-calls, and
# the change counts as sent only when a call carries change.sql.
#   sb-with     3.0.0: db query takes --linked and --file, so its help exits 0.
#   sb-old      2.75.0, measured on the personal MacBook on 2026-11-04: no db query, so a bare
#               `db query --help` prints the parent db help and exits 0, while the same help asked
#               with --linked exits 1 with "unknown flag: --linked".
#   sb-lookalike  no db query either, but its parent help carries an unrelated --file flag, which a
#               search of that help for --file mistook for the command (the old detection).
#   sb-four     4.0.0: db query exists but --linked is removed, so asking for it exits 1.
mkbin "$TMP/sb-none" grep cat
stub_cli(){   # stub_cli <dir> <version> <has db query --linked: yes|no> <parent help line>
  mkbin "$1" grep cat head
  cat > "$1/supabase" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$TMP/supabase-calls"
if [ "\$1" = "--version" ]; then echo "$2"; echo "A new version of Supabase CLI is available" >&2; exit 0; fi
help=no; linked=no
for a in "\$@"; do [ "\$a" = "--help" ] && help=yes; [ "\$a" = "--linked" ] && linked=yes; done
if [ "\$1 \$2" = "db query" ] && [ "$3" = "yes" ]; then
  if [ "\$help" = yes ]; then echo "Usage:"; echo "  supabase db query [sql] [flags]"; echo "  -f, --file string   Path to a SQL file to execute."; exit 0; fi
  echo "stub supabase ran"; exit 0
fi
if [ "\$1 \$2" = "db query" ] && [ "\$linked" = yes ]; then
  echo "Usage:"; echo "  supabase db [command]"; echo "unknown flag: --linked" >&2; exit 1
fi
if [ "\$1" = "db" ]; then echo "Usage:"; echo "  supabase db [command]"; echo "$4"; exit 0; fi
exit 1
STUB
  chmod +x "$1/supabase"
}
stub_cli "$TMP/sb-with" "3.0.0" yes "  -f, --file string   Path to a SQL file to execute."
stub_cli "$TMP/sb-old" "2.75.0" no "  push   Push new migrations to the remote database"
stub_cli "$TMP/sb-lookalike" "2.70.0" no "  -f, --file string   Path to an unrelated file."
stub_cli "$TMP/sb-four" "4.0.0" no "  query   Execute a SQL query against a database."

sent(){ grep -q 'change\.sql' "$TMP/supabase-calls" 2>/dev/null; }

rm -f "$TMP/supabase-calls"
out="$(cd "$WORK" && PATH="$TMP/sb-with" /bin/bash -c "$linked_line" 2>&1)"; rc=$?
check "with db query available the command runs it against the linked project" \
  "$([ "$rc" -eq 0 ] && grep -q 'stub supabase ran' <<< "$out" && echo ok || echo "exit $rc, said: $out")"
check "and sends exactly one call carrying the change: db query --linked --yes -f change.sql" \
  "$(got="$(grep 'change\.sql' "$TMP/supabase-calls" 2>/dev/null)"; [ "$got" = "db query --linked --yes -f change.sql" ] && echo ok || echo "calls carrying the change: $got")"
check "and nothing it printed holds the env file's secret" \
  "$(grep -qF "$SECRET" <<< "$out" && echo "printed the secret" || echo ok)"
# The detection asks for db query with the flags the last step uses, as a help request, and never
# with --yes or the change file: a CLI that ignored --help would then be sent nothing it could apply.
probe="$(grep -m 1 -- '--help' "$TMP/supabase-calls" 2>/dev/null)"
check "the detection asks for db query --linked --file itself, as a help request" \
  "$(grep -q '^db query ' <<< "$probe" && grep -q -- '--linked' <<< "$probe" && grep -q -- '--file' <<< "$probe" && echo ok || echo "the help call was: ${probe:-none}")"
check "and the detection carries neither --yes nor the change file" \
  "$(grep -qE -- '--yes|change\.sql' <<< "$probe" && echo "the help call was: $probe" || echo ok)"

for cli in sb-old:2.75.0 sb-lookalike:2.70.0 sb-four:4.0.0; do
  d="${cli%%:*}"; v="${cli#*:}"
  rm -f "$TMP/supabase-calls"
  out="$(cd "$WORK" && PATH="$TMP/$d" /bin/bash -c "$linked_line" 2>&1)"; rc=$?
  check "with CLI $v ($d), which cannot take db query --linked, nothing is sent and the command fails" \
    "$([ "$rc" -ne 0 ] && ! sent && echo ok || echo "exit $rc, calls: $(tr '\n' ';' < "$TMP/supabase-calls" 2>/dev/null), said: $out")"
  check "and the refusal names the version found, $v, and the version needed, 2.79.0" \
    "$(grep -qF "version $v" <<< "$out" && grep -qF '2.79.0' <<< "$out" && echo ok || echo "said: $out")"
done

out="$(cd "$WORK" && PATH="$TMP/sb-none" /bin/bash -c "$linked_line" 2>&1)"; rc=$?
check "with no supabase CLI at all the command fails and says so" \
  "$([ "$rc" -ne 0 ] && grep -qi 'supabase CLI is not installed' <<< "$out" && echo ok || echo "exit $rc, said: $out")"

# The versions the skill relies on, and the --linked or --remote decision, with their sources.
linked_prose="$(awk '/supabase db query --linked/,/psql "\$url"/' "$SKILL")"
check "the skill names 2.79.0 as the release that added db query, from its release notes" \
  "$(grep -qF '2.79.0' <<< "$linked_prose" && grep -qi 'release notes' <<< "$linked_prose" && echo ok || echo "no 2.79.0 with its source on the linked path")"
check "the skill says --remote exists only from 3.0.0 and --linked is removed in v4" \
  "$(grep -qE -- '--remote. exists only from 3\.0\.0' <<< "$linked_prose" && grep -qF 'removed in v4' <<< "$linked_prose" && echo ok || echo "the --linked or --remote decision is not stated")"

echo ""
echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
