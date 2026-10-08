#!/usr/bin/env bash
#
# uses-supabase.sh <project dir>: does this project use Supabase (claude-config#685)?
#
# plan-council's preflight used to probe the Supabase MCP tools on every project, so on Overture,
# Ovation and every other project without Supabase the schema always read as unreachable and the
# plan opened with a grounding warning that was a false alarm. This answers the question the probe
# should have asked first, from the project's own files, so the skill can tell the workflow and the
# workflow can report the schema as not applicable rather than missing.
#
# The answer is an EXIT CODE (L184), three ways, because "could not look" is not "no" (L11):
#   0  yes, and the line printed names the evidence
#   1  no
#   2  could not tell (no folder given, or not a folder), and the probe should run as before
#
# Evidence, any one of:
#   - a `supabase` folder anywhere in the top three levels: the CLI's config and migrations, or an app's own
#     client folder such as src/lib/supabase, which is evidence too. A false yes only restores the
#     probe every project had before, so the walk errs that way rather than toward a false no (L93)
#   - a package.json in the top three levels depending on an @supabase/ package
#   - an env file (.env, .env.*, .dev.vars) at the root setting a variable whose name holds SUPABASE
# Source code that merely mentions the word is not evidence, and anything under node_modules or .git
# is skipped: a dependency's own copy says nothing about this project. The walk is bounded at three
# levels so a large tree costs a few directory reads, not a crawl (L493). Env files are only ever
# matched by variable NAME with grep -q, so no value is printed (L222).
set -uo pipefail

dir="${1:-}"
if [ -z "$dir" ] || [ ! -d "$dir" ]; then
  echo "could not tell: '${dir:-<no folder given>}' is not a folder"
  exit 2
fi

found=""
while IFS= read -r path; do
  [ -n "$path" ] || continue
  case "$path" in
    */supabase) found="${path#"$dir"/} folder"; break ;;
    */package.json)
      if grep -q '"@supabase/' "$path" 2>/dev/null; then found="${path#"$dir"/} depends on an @supabase package"; break; fi ;;
  esac
done <<EOF
$(find "$dir" -maxdepth 3 \( -name node_modules -o -name .git \) -prune -o \( \( -name supabase -type d \) -o \( -name package.json -type f \) \) -print 2>/dev/null)
EOF

if [ -z "$found" ]; then
  for env in "$dir"/.env "$dir"/.env.* "$dir"/.dev.vars; do
    [ -f "$env" ] || continue
    if grep -q -E '^[[:space:]]*(export[[:space:]]+)?[A-Za-z0-9_]*SUPABASE[A-Za-z0-9_]*[[:space:]]*=' "$env" 2>/dev/null; then
      found="${env#"$dir"/} sets a SUPABASE variable"; break
    fi
  done
fi

if [ -n "$found" ]; then
  echo "yes: $found"
  exit 0
fi
echo "no: no supabase folder, @supabase dependency or SUPABASE variable in $dir"
exit 1
