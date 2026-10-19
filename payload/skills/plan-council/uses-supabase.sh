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
#   0  yes, and the line printed names the evidence: which file, and which kind of signal
#   1  no
#   2  could not tell (no folder given, not a folder, the source search failed, or it was cut
#      short), and the probe should run as before
#
# Evidence, any one of, checked in this order:
#   - a `supabase` folder in the top three levels: the CLI's config and migrations, or an app's own
#     client folder such as src/lib/supabase, which is evidence too. A false yes only restores the
#     probe every project had before, so the detector errs that way rather than toward a false no
#     (L93)
#   - a package.json in the top three levels depending on an @supabase/ package
#   - an env file (.env, .env.*, .dev.vars) in the top three levels setting a variable whose name
#     holds SUPABASE, at the root or in a nested app
#   - source code that READS an env variable whose name holds SUPABASE, in any common form:
#     process.env.X, process.env["X"], import.meta.env.X, os.environ["X"], os.environ.get("X"),
#     os.getenv("X"), os.Getenv("X"), System.getenv("X"), Deno.env.get("X"), ENV["X"],
#     ENV.fetch("X"), std::env::var("X"), environment["X"], $env:X, $X and ${X} in a shell script,
#     ${{ secrets.X }} or ${{ env.X }} in a workflow
#   - source code naming a project host under supabase.co (supabase.com, the docs and the
#     dashboard, is not one)
# The last two exist for claude-config#1352: PET runs on Supabase but calls its REST API over plain
# https with the keys in CI secrets, so it has no folder, no dependency and no env file, and read as
# no. The word supabase alone, in a README, a comment or a constant's name, is still not evidence:
# only the shape of an env read or a supabase.co host is. Prose documents (Markdown, text,
# reStructuredText, AsciiDoc) are not searched at all: Overture, which has no Supabase, carries a
# plan written for another project whose code snippet reads env.SUPABASE_SERVICE_ROLE_KEY.
#
# Cost, on any size of tree (L493):
#   - the first three come from a walk bounded at three levels, a few directory reads
#   - in a git checkout with files tracked under the folder, the source search reads TRACKED files
#     only, with `git grep`, so ignored build output is never read. A file not yet added to git is
#     not seen
#   - otherwise (not a git checkout, or nothing tracked under it yet) it walks at most six levels
#     and reads the first PLAN_COUNCIL_SCAN_FILE_CAP files under 1MB (default 5000). A walk that hit the cap
#     and found nothing answers could not tell, because the files it never read could hold the
#     answer (L564)
#   - a git search that ERRORS answers could not tell, never no (L11)
#   - both skip node_modules, vendor, third_party, dist, build, out, .next, .nuxt, coverage, Pods,
#     target and virtualenv folders, lockfiles, minified files and source maps: a dependency's or a
#     bundler's copy says nothing about this project
#
# Every file is matched with grep -q or -l, so the line that matched, which may carry a key or a
# URL, is never printed; only the file's name is (L222). `find -H` follows the folder given when it
# is a symlink; without it find lists the link alone, walks nothing, and a Supabase project reads as
# no. `-mindepth 1` keeps the project folder itself out, so one merely NAMED supabase is not
# evidence.
set -uo pipefail

dir="${1:-}"
if [ -z "$dir" ] || [ ! -d "$dir" ]; then
  echo "could not tell: '${dir:-<no folder given>}' is not a folder"
  exit 2
fi
# One trailing slash off, so evidence is named relative to the folder rather than as a full path.
case "$dir" in /) ;; */) dir="${dir%/}" ;; esac

found=""
while IFS= read -r path; do
  [ -n "$path" ] || continue
  case "$path" in
    */supabase) found="${path#"$dir"/} folder"; break ;;
    */package.json)
      if grep -q '"@supabase/' "$path" 2>/dev/null; then found="${path#"$dir"/} depends on an @supabase package"; break; fi ;;
    *)
      # An env file, matched by variable NAME only.
      if grep -q -E '^[[:space:]]*(export[[:space:]]+)?[A-Za-z0-9_]*SUPABASE[A-Za-z0-9_]*[[:space:]]*=' "$path" 2>/dev/null; then
        found="${path#"$dir"/} sets a SUPABASE variable"; break
      fi ;;
  esac
done <<EOF
$(find -H "$dir" -mindepth 1 -maxdepth 3 \( -name node_modules -o -name .git \) -prune -o \( \( -name supabase -type d \) -o \( -type f \( -name package.json -o -name .env -o -name '.env.*' -o -name .dev.vars \) \) \) -print 2>/dev/null)
EOF

if [ -n "$found" ]; then
  echo "yes: $found"
  exit 0
fi

# ---- source code that reads a SUPABASE env variable, or names a supabase.co host (#1352) ----
N='[A-Za-z0-9_]*SUPABASE[A-Za-z0-9_]*'
Q='["'"'"'`]'
ENV_READ="(env\.$N|env\[$Q$N|env:$N|environ(\.get\(|\[)$Q$N|[Gg]et[Ee]nv\($Q$N|env\.get\($Q$N|env::var\($Q$N|ENV(\.fetch\(|\[)$Q$N|environment\[$Q$N|\\\$\{?$N|(secrets|vars)\.$N)"
HOST='[A-Za-z0-9-]\.supabase\.co([^A-Za-z0-9]|$)'
SKIP_DIRS="node_modules vendor third_party dist build out .next .nuxt coverage Pods target .venv venv"
SKIP_FILES="package-lock.json npm-shrinkwrap.json yarn.lock pnpm-lock.yaml bun.lock bun.lockb Cargo.lock Gemfile.lock poetry.lock uv.lock composer.lock go.sum Package.resolved"
SKIP_EXTS="md mdx markdown txt rst adoc min.js min.css map"

say_found() { # say_found <path relative to the folder> <env|host> <how it was searched>
  if [ "$2" = env ]; then
    echo "yes: $1 reads a SUPABASE env variable$3"
  else
    echo "yes: $1 names a supabase.co host$3"
  fi
  exit 0
}

why="not a git checkout"
tracked=""
if git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  why="nothing is tracked under it in git yet"
  # --error-unmatch fails when no tracked file sits under the folder, with no pipe into a reader
  # that could leave early under pipefail (claude-config#132).
  if git -C "$dir" ls-files --error-unmatch -- . >/dev/null 2>&1; then tracked=1; fi
fi

if [ -n "$tracked" ]; then
  # Tracked files only. Pathspecs are relative to the folder, so a folder inside a larger
  # repository is searched alone.
  specs=(.)
  for d in $SKIP_DIRS; do specs+=(":(exclude,glob)**/$d/**"); done
  for f in $SKIP_FILES; do specs+=(":(exclude,glob)**/$f"); done
  for e in $SKIP_EXTS; do specs+=(":(exclude,glob)**/*.$e"); done
  for kind in env host; do
    if [ "$kind" = env ]; then pat="$ENV_READ"; else pat="$HOST"; fi
    hits="$(git -C "$dir" grep -I -l -E --no-color -e "$pat" -- "${specs[@]}" 2>/dev/null)"
    rc=$?
    if [ "$rc" -eq 0 ] && [ -n "$hits" ]; then say_found "$(head -n 1 <<< "$hits")" "$kind" ""; fi
    if [ "$rc" -ne 1 ]; then
      echo "could not tell: no supabase folder, dependency or env file, and searching the tracked files of $dir with git grep failed (exit $rc), so its source was not read"
      exit 2
    fi
  done
  echo "no: no supabase folder, @supabase dependency, SUPABASE variable in an env file, SUPABASE env read or supabase.co host in the tracked files of $dir"
  exit 1
fi

# Not a git checkout, or nothing tracked under it yet: a bounded walk instead.
cap="${PLAN_COUNCIL_SCAN_FILE_CAP:-5000}"
case "$cap" in ''|*[!0-9]*|0) cap=5000 ;; esac
prune=()
for d in $SKIP_DIRS .git; do prune+=(-name "$d" -o); done
skipf=()
for f in $SKIP_FILES; do skipf+=(! -name "$f"); done
for e in $SKIP_EXTS; do skipf+=(! -name "*.$e"); done
listing="$(find -H "$dir" -mindepth 1 -maxdepth 6 \( "${prune[@]}" -false \) -prune -o -type f -size -1024k "${skipf[@]}" -print 2>/dev/null)"
count="$(grep -c . <<< "$listing")"
capped=""
if [ "$count" -gt "$cap" ]; then capped=1; count="$cap"; listing="$(head -n "$cap" <<< "$listing")"; fi
for kind in env host; do
  if [ "$kind" = env ]; then pat="$ENV_READ"; else pat="$HOST"; fi
  hits="$(tr '\n' '\0' <<< "$listing" | xargs -0 grep -I -l -E -e "$pat" -- 2>/dev/null)"
  hit="${hits%%$'\n'*}"
  if [ -n "$hit" ]; then say_found "${hit#"$dir"/}" "$kind" " ($why, so the files were walked)"; fi
done
if [ -n "$capped" ]; then
  echo "could not tell: no supabase folder, dependency or env file, and $dir ($why) holds more than $cap files, so only the first $cap were searched for a SUPABASE env read or supabase.co host"
  exit 2
fi
echo "no: no supabase folder, @supabase dependency, SUPABASE variable in an env file, SUPABASE env read or supabase.co host in $dir ($why, so all $count files within six levels were walked)"
exit 1
