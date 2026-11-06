#!/usr/bin/env bash
# The work names check for GitHub writes made inside a script (claude-config#2183).
#
# On 2026-11-03 a scrub made 239 GitHub edits as gh calls inside a Python script. The publish gate
# (check-work-names-publish.sh) judges the Bash command the hook sees, which was a python command,
# so it judged none of them. This suite holds the three parts that close that:
#   1. bin/gh, the guard put first on a session's PATH: every gh a script runs reaches it, and it
#      judges the real text with the publish gate's own rule before the real gh runs. A refusal stops
#      the write and fails the call; a clean or private write, and every read, runs the real gh with
#      its exit code and its standard input unchanged. It never names the name it matched, since a
#      script's error output can land in a log.
#   2. gh-guard-path.sh, the SessionStart hook that puts it there through CLAUDE_ENV_FILE, and says
#      so when it cannot.
#   3. The command hook, in a session whose PATH does not carry the guard (every session already
#      running when this ships): it judges exactly what it judged before, refusing nothing new, and
#      says once in that session that gh writes made inside scripts are not checked until a new
#      session starts. Refusing those scripts instead would stop every merge on both Macs, since
#      merge-when-ready.sh is one, until each session restarted. A guarded session hears nothing.
#
# Every name here is invented. This repository is public, and no work organisation or repository name
# belongs in this file.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/check-work-names-publish.sh"
GUARD="$HERE/bin/gh"
GUARD_BIN="$HERE/bin"
START="$HERE/gh-guard-path.sh"
. "$HERE/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

pass=0; fail=0
check(){   # $1 = name  $2.. = a command that succeeds when the check holds
  local name="$1"; shift
  if "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $name"; fi
}
has(){ [[ "$1" == *"$2"* ]]; }
lacks(){ [[ "$1" != *"$2"* ]]; }

for tool in python3 shasum jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "FAIL: $tool is not on PATH, so this suite cannot run."
    printf 'SUITE-RESULT passed=0 failed=1\n'
    exit 1
  fi
done

_tmp="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "${_tmp%/}/work-names-scripts.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"; mkdir -p "$BIN"
HOMEDIR="$WORK/home"; mkdir -p "$HOMEDIR"
CALLS="$WORK/gh-calls"
LIST="$WORK/list.json"
VIS="$WORK/visibility"
STDIN_SAVE="$WORK/stdin-seen"
CO="$WORK/checkout"; mkdir -p "$CO/sub"
ENVDIR="$WORK/session-env"; mkdir -p "$ENVDIR"
NOTICED="$WORK/noticed"

# A fake gh: two signed in accounts, a visibility table, the work repository list, and any other call
# recorded as a POST, with what it read on standard input saved, exiting FAKE_POST_RC.
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "${GH_TOKEN:-}" "$*" >> "$FAKE_CALLS"
case "$1 $2" in
  "auth status")
    printf '{"hosts":{"github.com":[{"login":"alice","active":true,"state":"success"}]}}\n'
    exit 0 ;;
  "auth token")
    printf 'tok-alice\n'; exit 0 ;;
  "alias list")
    [ -f "$FAKE_ALIASES" ] || { echo "failed to read the config file" >&2; exit 1; }
    cat "$FAKE_ALIASES"; exit 0 ;;
  "repo view")
    slug=""
    [ "$3" != "--json" ] && slug="$3"
    [ -n "$slug" ] || slug="${GH_REPO:-$(cat "$PWD/.fake-default" 2>/dev/null)}"
    want="$(tr '[:upper:]' '[:lower:]' <<<"$slug")"
    while read -r s v; do
      [ "$(tr '[:upper:]' '[:lower:]' <<<"$s")" = "$want" ] || continue
      printf '{"nameWithOwner":"%s","visibility":"%s"}\n' "$s" "$v"; exit 0
    done < "$FAKE_VIS"
    echo "GraphQL: Could not resolve to a Repository with the name '$slug'." >&2; exit 1 ;;
  "api -H")
    case "$*" in *contents/repos.json*)
      [ -f "$FAKE_LIST" ] || { echo "HTTP 404: Not Found" >&2; exit 1; }
      cat "$FAKE_LIST"; exit 0 ;;
    esac ;;
esac
for a in "$@"; do
  case "$a" in -|*=@-) cat > "$FAKE_STDIN_SAVE" ;; esac
done
printf 'POST|%s\n' "$*" >> "$FAKE_CALLS"
echo "fake gh ran: $*"
exit "${FAKE_POST_RC:-0}"
SH
chmod +x "$BIN/gh"

printf '%s\n' '{"tokenByOwner":{"Acme-Corp":"X"},"repos":[{"owner":"Acme-Corp","name":"acme-widgets","label":"widgets"},{"owner":"Acme-Corp","name":"zephyr","label":"Zephyr"}]}' > "$LIST"
printf 'danwright-test/public-notes PUBLIC\ndanwright-test/private-notes PRIVATE\n' > "$VIS"
printf 'danwright-test/public-notes' > "$CO/.fake-default"
FAKE_HASH="$(printf '%s' "acme-hq" | shasum -a 256 | cut -d' ' -f1)"
PROJECTS="$WORK/CLAUDE.md"
printf '%s' '## Projects

On Dans-MacBook-Pro:
- `~/Apps/Quillfeather`: Next.js

## Writing Style
' > "$PROJECTS"

fixture_env(){   # the environment every run shares, then the command
  # The scanner reads the invented hashes and project list only under the test marker
  # (claude-config#2231), which the runner exports; it is set here too, so this suite run on its own
  # judges the same names.
  env HOOK_TESTS_RUNNING=1 HOME="$HOMEDIR" FAKE_CALLS="$CALLS" FAKE_LIST="$LIST" FAKE_VIS="$VIS" FAKE_STDIN_SAVE="$STDIN_SAVE" \
    WORK_NAMES_EXTRA_HASHES="$FAKE_HASH" WORK_NAMES_PROJECT_LIST="$PROJECTS" WN_SESSION_ENV_DIR="$ENVDIR" \
    WN_SCRIPTS_NOTICE_DIR="$NOTICED" FAKE_ALIASES="$ALIAS_SRC" "$@"
}

# The aliases, in the form gh alias list prints them (measured on gh 2.89.0 with invented aliases).
ALIASES="$WORK/aliases"
ALIAS_SRC="$ALIASES"
printf '%s\n' 'cm: issue comment $1 --repo danwright-test/public-notes --body "$2"' 'co: pr checkout' 'lv: pr view' \
  'ml: |-' '    issue comment 5 --repo danwright-test/public-notes --body "line one' '    the zephyr board"' > "$ALIASES"

# ================================================================ 1. the guard on PATH
guard(){   # $1 = a python script body run with the guard first on PATH; output in out, code in rc
  : > "$CALLS"; rm -f "$STDIN_SAVE"
  printf '%s\n' "$1" > "$CO/scrub.py"
  out="$(cd "$CO" && fixture_env PATH="$GUARD_BIN:$BIN:$PATH" python3 scrub.py 2>&1)"; rc=$?
}
posted(){ grep -q '^POST|' "$CALLS"; }
not_posted(){ ! grep -q '^POST|' "$CALLS"; }

check "the guard is an executable file" [ -x "$GUARD" ]

guard 'import subprocess, sys
r = subprocess.run(["gh", "issue", "comment", "5", "--repo", "danwright-test/public-notes", "--body", "seen in acme-widgets"])
sys.exit(r.returncode)'
check "a comment a script posts to a public repository naming a work repository is refused: rc=$rc $out" [ "$rc" -ne 0 ]
check "and the real gh never posts it" not_posted
check "and says why: $out" has "$out" "WORK NAME IN PUBLIC TEXT"
check "and withholds the name it matched, since a script's output can land in a log: $out" lacks "$out" "acme-widgets"
check "and the gate's own reads reached the real gh, not the guard again" has "$(cat "$CALLS")" "repo view"

guard 'import subprocess, sys
r = subprocess.run(["gh", "issue", "comment", "5", "--repo", "danwright-test/public-notes", "--body", "a work repository showed it"])
sys.exit(r.returncode)'
check "(control) a clean comment from a script posts through the real gh: rc=$rc $out" [ "$rc" -eq 0 ]
check "with its arguments unchanged" has "$(cat "$CALLS")" "POST|issue comment 5 --repo danwright-test/public-notes --body a work repository showed it"

FAKE_POST_RC=4 guard 'import subprocess, sys
r = subprocess.run(["gh", "issue", "comment", "5", "--repo", "danwright-test/public-notes", "--body", "clean"])
sys.exit(r.returncode)'
check "the real gh's own failure comes back as its exit code, not the guard's: rc=$rc" [ "$rc" -eq 4 ]

guard 'import subprocess, sys
r = subprocess.run(["gh", "api", "-X", "PATCH", "repos/danwright-test/public-notes/issues/7", "-f", "body=the Zephyr board"])
sys.exit(r.returncode)'
check "a gh api edit of an issue body naming one is refused: rc=$rc $out" [ "$rc" -ne 0 ]
check "and never posted" not_posted

guard 'import subprocess, sys
r = subprocess.run(["gh", "issue", "edit", "7", "--repo", "danwright-test/public-notes", "--body-file", "-"], input=b"Notes from acme-hq\n")
sys.exit(r.returncode)'
check "a body a script sends on standard input is read and judged: rc=$rc $out" [ "$rc" -ne 0 ]
check "and never posted" not_posted

guard 'import subprocess, sys
r = subprocess.run(["gh", "issue", "edit", "7", "--repo", "danwright-test/public-notes", "--body-file", "-"], input=b"Clean notes\n")
sys.exit(r.returncode)'
check "(control) a clean body on standard input posts: rc=$rc $out" [ "$rc" -eq 0 ]
check "and the real gh reads the same bytes the script sent" [ "$(cat "$STDIN_SAVE" 2>/dev/null)" = "Clean notes" ]

guard 'import subprocess, sys
r = subprocess.run(["gh", "issue", "comment", "5", "--repo", "danwright-test/private-notes", "--body", "acme-widgets"])
sys.exit(r.returncode)'
check "a private repository passes: rc=$rc $out" [ "$rc" -eq 0 ]

guard 'import subprocess, sys
r = subprocess.run(["gh", "issue", "comment", "5", "--repo", "danwright-test/nowhere", "--body", "clean"])
sys.exit(r.returncode)'
check "a repository whose visibility cannot be read is refused, never passed: rc=$rc $out" [ "$rc" -ne 0 ]
check "and never posted" not_posted

guard 'import subprocess, sys
r = subprocess.run(["gh", "release", "list"])
sys.exit(r.returncode)'
check "a gh command that writes no public text runs the real gh at once: rc=$rc" [ "$rc" -eq 0 ]
check "and asks GitHub nothing first" [ "$(grep -c -v '^POST|' "$CALLS")" = "1" ]

# gh aliases: judged as the command they expand to.
guard 'import subprocess, sys
r = subprocess.run(["gh", "cm", "5", "seen in acme-widgets"])
sys.exit(r.returncode)'
check "an alias a script runs that expands to a comment naming a work repository is refused: rc=$rc $out" [ "$rc" -ne 0 ]
check "and never posted" not_posted
check "and says it went through the alias: $out" has "$out" "gh alias cm"
check "and withholds the name: $out" lacks "$out" "acme-widgets"
guard 'import subprocess, sys
r = subprocess.run(["gh", "ml"])
sys.exit(r.returncode)'
check "an alias written as a block over several lines is read and judged: rc=$rc $out" [ "$rc" -ne 0 ]
check "and never posted" not_posted
guard 'import subprocess, sys
r = subprocess.run(["gh", "lv", "5"])
sys.exit(r.returncode)'
check "(control) an alias to a read only command runs the real gh: rc=$rc $out" [ "$rc" -eq 0 ]
check "with the alias as the script wrote it, for gh to expand" has "$(cat "$CALLS")" "POST|lv 5"
ALIAS_SRC="$WORK/no-such-aliases"
guard 'import subprocess, sys
r = subprocess.run(["gh", "cm", "5", "clean"])
sys.exit(r.returncode)'
check "a word that could be an alias, when the aliases cannot be read, is refused as cannot tell: rc=$rc $out" [ "$rc" -ne 0 ]
check "and never posted" not_posted
check "and says the aliases could not be read: $out" has "$out" "aliases could not be read"
guard 'import subprocess, sys
r = subprocess.run(["gh", "pr", "view", "5"])
sys.exit(r.returncode)'
check "(control) gh's own commands still run when the aliases cannot be read: rc=$rc $out" [ "$rc" -eq 0 ]
ALIAS_SRC="$ALIASES"

# A folder holding only bash, which the guard's own line asks for: /usr/bin holds a gh on a CI runner,
# so a PATH of the system folders had a real gh past the guard there and the case never ran.
NOGH="$WORK/nogh"; mkdir -p "$NOGH"; ln -s "$(command -v bash)" "$NOGH/bash"
: > "$CALLS"
out="$(cd "$CO" && fixture_env PATH="$GUARD_BIN:$NOGH" "$GUARD" pr view 5 2>&1)"; rc=$?
check "with no real gh past itself on PATH the guard fails as a missing command: rc=$rc $out" [ "$rc" -eq 127 ]
check "and says so: $out" has "$out" "no gh"

BROKEN="$WORK/broken"; mkdir -p "$BROKEN"
printf '#!/usr/bin/env bash\nexit 3\n' > "$BROKEN/python3"; chmod +x "$BROKEN/python3"
: > "$CALLS"
out="$(cd "$CO" && fixture_env PATH="$BROKEN:$BIN:/usr/bin:/bin" "$GUARD" issue comment 5 --repo danwright-test/public-notes --body clean 2>&1)"; rc=$?
check "a guard whose judge cannot run refuses the write rather than passing it: rc=$rc $out" [ "$rc" -ne 0 ]
check "and never posted" not_posted

# ================================================================ 2. the SessionStart hook
SID="11111111-2222-3333-4444-555555555555"
mkdir -p "$ENVDIR/$SID"
: > "$ENVDIR/$SID/sessionstart-hook-0.sh"
out="$(printf '{"session_id":"%s","hook_event_name":"SessionStart"}' "$SID" | CLAUDE_ENV_FILE="$ENVDIR/$SID/sessionstart-hook-0.sh" bash "$START" 2>&1)"; rc=$?
check "the SessionStart hook exits cleanly: rc=$rc $out" [ "$rc" -eq 0 ]
check "and puts the guard first on PATH in the session's env file" grep -q -F "export PATH=\"$GUARD_BIN:\$PATH\"" "$ENVDIR/$SID/sessionstart-hook-0.sh"
got_path="$(env -i HOME="$HOMEDIR" PATH="/usr/bin:/bin" bash -c ". '$ENVDIR/$SID/sessionstart-hook-0.sh'; command -v gh")"
check "and a shell that sources that file runs the guard as gh: $got_path" [ "$got_path" = "$GUARD" ]

out="$(printf '{"session_id":"%s"}' "$SID" | env -u CLAUDE_ENV_FILE bash "$START" 2>&1)"; rc=$?
check "with no env file the hook still exits cleanly: rc=$rc" [ "$rc" -eq 0 ]
check "and says the guard is not on PATH: $out" has "$out" "not on PATH"
check "and that gh writes inside scripts are not checked, never that they are refused: $out" has "$out" "not checked"

# ================================================================ 3. the command hook, for scripts
hook(){   # $1 = the command, $2 = the session id (may be empty); stdout in out, stderr in err, decision in decision
  local payload
  payload="$(jq -nc --arg c "$1" --arg d "$CO" --arg s "${2:-}" '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c},cwd:$d} + (if $s == "" then {} else {session_id:$s} end)')"
  : > "$CALLS"
  # Stdout alone is what Claude Code parses as the hook's JSON, so it is captured apart from stderr,
  # which carries a refusal's reason and the notice's terminal copy.
  out="$(cd "$CO" && printf '%s' "$payload" | fixture_env PATH="$BIN:$PATH" bash "$GATE" 2>"$WORK/hook-err")"; rc=$?
  err="$(cat "$WORK/hook-err")"
  decision="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)"
}
refused(){ [ "$rc" -eq 2 ] || [ "$decision" = deny ]; }
passed(){ [ "$rc" -eq 0 ] && [ -z "$decision" ]; }

printf 'import subprocess\nfor n in (1, 2):\n    subprocess.run(["gh", "issue", "edit", str(n), "--body", "x"])\n' > "$CO/scrub.py"
printf '#!/usr/bin/env bash\ngh pr comment 5 --body "$1"\n' > "$CO/sub/post.sh"; chmod +x "$CO/sub/post.sh"
UNGUARDED="99999999-2222-3333-4444-555555555555"

silent(){ [ "$rc" -eq 0 ] && [ -z "$out" ] && [ -z "$err" ]; }
notice_of(){ printf '%s' "$out" | jq -r '.systemMessage // empty' 2>/dev/null; }
told(){ [ "$rc" -eq 0 ] && [ -z "$decision" ] && [[ "$(notice_of)" == *"not checked"* ]]; }

hook 'python3 scrub.py' "$UNGUARDED"
check "a session without the guard: a python script making gh writes still runs, as it does today: $out" told
check "and the session is told, once, that gh writes inside scripts are not checked: $out" has "$(notice_of)" "inside scripts"
check "and how to get them checked: $out" has "$(notice_of)" "new session"
check "and the notice is the only thing on stdout, one JSON object: $out" [ "$(printf '%s' "$out" | jq -s 'length' 2>/dev/null)" = "1" ]
hook 'python3 scrub.py' "$UNGUARDED"
check "the second command in that session hears nothing more: $out" silent
hook 'cd sub && ./post.sh hello' "$UNGUARDED"
check "nor does a script run by its path: $out" silent
hook 'python3 missing.py' "$UNGUARDED"
check "nor a script that cannot be read, which today's gate never read either: $out" silent

UNGUARDED2="88888888-2222-3333-4444-555555555555"
hook 'gh pr create --repo danwright-test/public-notes --title Tidy --body "the acme-widgets checkout"' "$UNGUARDED2"
check "a command's own gh write naming a work repository is still refused in a session without the guard: $out" refused
hook 'ls -la /tmp && echo zephyr' "$UNGUARDED2"
check "and a refusal does not use up the notice, which the next command carries: $out" told
UNGUARDED3="77777777-2222-3333-4444-555555555555"
hook 'gh pr view 5' "$UNGUARDED3"
check "a gh command the gate clears carries the notice too: $out" told

hook 'python3 scrub.py' ""
check "a payload with no session id runs as today and is told nothing, since once per session cannot be kept: $out" silent
hook 'python3 scrub.py' "../$UNGUARDED"
check "a session id that is not one is never used as a path: $out" silent
check "and nothing is written beside the notice folder" [ ! -e "$WORK/$UNGUARDED" ]

GUARDED="22222222-2222-3333-4444-555555555555"
mkdir -p "$ENVDIR/$GUARDED"
printf '%s\n' "export PATH=\"$GUARD_BIN:\$PATH\"" > "$ENVDIR/$GUARDED/sessionstart-hook-0.sh"
hook 'python3 scrub.py' "$GUARDED"
check "a session whose PATH carries the guard runs the script and hears nothing, since the guard judges each write: $out" silent
hook 'gh pr create --repo danwright-test/public-notes --title Tidy --body "the acme-widgets checkout"' "$GUARDED"
check "the command's own gh writes are still judged in a guarded session: $out" refused
hook 'gh cm 5 "seen in acme-widgets"' "$GUARDED"
check "a command running an alias that expands to a comment naming a work repository is refused: $out" refused
check "and says it went through the alias: $out" has "$out" "gh alias cm"
# gh's arguments are the shared reader's words from the program's name on (claude-config#1188), so
# an alias behind an assignment or a runner is found as one written bare is.
hook 'GH_HOST=github.com gh cm 5 "seen in acme-widgets"' "$GUARDED"
check "an alias run behind an assignment is judged as what it expands to: $out" refused
check "through the alias: $out" has "$out" "gh alias cm"
hook 'env GH_HOST=github.com gh cm 5 "seen in acme-widgets"' "$GUARDED"
check "and one run behind env: $out" refused
check "through the alias too: $out" has "$out" "gh alias cm"
hook 'gh lv 5' "$GUARDED"
check "(control) a command running an alias to a read only command passes: $out" silent
ALIAS_SRC="$WORK/no-such-aliases"
hook 'gh cm 5 "seen in acme-widgets"' "$GUARDED"
check "an alias the hook cannot read passes as before, for the guard to refuse when it runs: $out" silent
ALIAS_SRC="$ALIASES"
OTHER="33333333-2222-3333-4444-555555555555"
mkdir -p "$ENVDIR/$OTHER"
printf '%s\n' "export PATH=\"/somewhere/else:\$PATH\"" > "$ENVDIR/$OTHER/sessionstart-hook-0.sh"
hook 'python3 scrub.py' "$OTHER"
check "an env file putting some other folder first is not the guard, so that session is told: $out" told

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
