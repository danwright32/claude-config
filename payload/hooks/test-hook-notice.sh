#!/usr/bin/env bash
# lib/hook-notice.sh, and the scans that keep every hook's notices on it (claude-config#1906, #1912).
#
# Claude Code discards a hook's stderr on exit 0 (hooks documentation: "Claude never sees stderr from
# a hook that exits 0"; it goes to the debug log), and sends a PreToolUse hook's plain stdout on exit
# 0 to the debug log too, so a gate that lets a call through and says why in either says it to
# nobody. The notice goes out as a JSON systemMessage instead, the field the documentation describes
# as a "warning message shown to the user". This suite checks:
#   * the library writes exactly one valid JSON object for any text, a newline or tab in a notice or
#     its context included, with python3 and with nothing on PATH, and handles its event and context
#     arguments as its header says, each rule seen to fail against a library that breaks it (#1924);
#   * the prompt hooks say their faults that way;
#   * no registered hook, on any event, writes a notice to stderr and then exits 0;
#   * no hook on an event whose plain stdout reaches no one (every event but UserPromptSubmit and
#     SessionStart: PreToolUse, PostToolUse, Stop and the rest) prints words plain to stdout and then
#     exits 0, outside a branch only a person running it by hand takes (#1924);
#   * no shell script under the hooks builds a systemMessage anywhere but the library;
#   * every registered hook using the library sources it with the fallback.
#
# What the two scans see, and what they do not, is written above scan.py below.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/lib/hook-notice.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $1"; }

if ! command -v python3 >/dev/null 2>&1; then
  echo "FAIL: python3 is not on PATH, so nothing this suite prints could be parsed as JSON. UNMEASURED."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

# message_of <stdout>: the systemMessage of the one JSON object stdout holds, or a line starting
# BROKEN saying why it is not exactly that.
message_of(){
  printf '%s' "$1" | python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception as e:
    print("BROKEN: not one JSON object (%s): %r" % (e, raw[:200])); sys.exit()
if not isinstance(d, dict) or not isinstance(d.get("systemMessage"), str):
    print("BROKEN: no systemMessage string in %r" % raw[:200]); sys.exit()
sys.stdout.write(d["systemMessage"])'
}

# --- the library -----------------------------------------------------------------------------------
if [ -r "$LIB" ]; then ok; else bad "#1906 lib/hook-notice.sh is missing beside this suite"; fi

# Text that breaks a hand built JSON string: quotes, a backslash, a newline, a tab, a curly
# apostrophe (a real path on the work MacBook holds one), and a dollar sign.
TRICKY="$(printf 'he said "no" \\ then\nline two\tafter a tab, Dan\xe2\x80\x99s MacBook, $HOME stays literal')"

# json_of <PATH> <text>: what hook_notice_json prints under that PATH.
json_of(){ env PATH="$1" HN_TEXT="$2" "$BASH" -c '. "$0" && hook_notice_json "$HN_TEXT"' "$LIB" 2>/dev/null; }

# A PATH with nothing on it, so the library's no python3 branch runs with no tool to lean on.
mkdir -p "$WORK/empty"
for arm in "$PATH" "$WORK/empty"; do
  name="with python3"; [ "$arm" = "$WORK/empty" ] && name="with nothing on PATH"
  out="$(json_of "$arm" "$TRICKY")"
  got="$(message_of "$out")"
  if [ "$got" = "$TRICKY" ]; then ok
  else bad "#1906 $name: hook_notice_json did not carry quotes, a backslash, a newline, a tab and UTF-8 through as one systemMessage. Got: ${got:0:300}"
  fi
  # A stray control character must not break the object.
  got="$(message_of "$(json_of "$arm" "$(printf 'bell\001 and escape\033 here')")")"
  case "$got" in BROKEN*|'') bad "#1906 $name: a control character in the text broke the JSON: $got" ;; *) ok ;; esac
  # Claude Code caps a systemMessage at 10,000 characters, so a long notice is cut short of that,
  # and saying it was cut, rather than truncated by the platform somewhere nobody chose.
  long="$(python3 -c 'print("x" * 20000, end="")')"
  got="$(message_of "$(json_of "$arm" "$long")")"
  case "$got" in BROKEN*) bad "#1906 $name: a 20,000 character notice broke the JSON: ${got:0:200}" ;; esac
  n="${#got}"
  if [ "$n" -gt 0 ] && [ "$n" -le 10000 ] && [[ "$got" == *"cut short"* ]]; then ok
  else bad "#1906 $name: a 20,000 character notice came out $n characters long, or without saying it was cut"
  fi
  # With an event, the session is handed the context too, as that event's additionalContext. A
  # newline in either text is where the hand built emitters this replaced broke (#1906).
  out="$(env PATH="$arm" HN_A="$TRICKY" HN_B="context: $TRICKY" "$BASH" -c '. "$0" && hook_notice_json "$HN_A" PostToolUse "$HN_B"' "$LIB" 2>/dev/null)"
  shape="$(printf '%s' "$out" | HN_WANT="$TRICKY" python3 -c '
import json, os, sys
want = os.environ["HN_WANT"]
try:
    d = json.loads(sys.stdin.read())
except Exception as e:
    print("not one JSON object: %s" % e); sys.exit()
h = d.get("hookSpecificOutput") or {}
if d.get("systemMessage") != want: print("systemMessage was %r" % d.get("systemMessage"))
elif h.get("hookEventName") != "PostToolUse": print("hookEventName was %r" % h.get("hookEventName"))
elif h.get("additionalContext") != "context: " + want: print("additionalContext was %r" % h.get("additionalContext"))')"
  [ -z "$shape" ] && ok || bad "#1906 $name: a notice and a context holding newlines did not come out as one valid object: $shape"
  out="$(env PATH="$arm" HN_A="one
two" "$BASH" -c '. "$0" && hook_notice_json "$HN_A" PreToolUse' "$LIB" 2>/dev/null)"
  ctx="$(printf '%s' "$out" | python3 -c 'import json, sys
try: print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"] == "one\ntwo")
except Exception as e: print("broken: %s" % e)')"
  [ "$ctx" = True ] && ok || bad "#1906 $name: with no context given, the notice itself was not handed to the session: $ctx"
done

# --- the event and context arguments, each seen to fail against a library that mishandles it -------
# (claude-config#1924). The checks above passed a mutant once, by hand, and nothing kept that proof;
# here every argument rule is checked against the real library, which must pass, and against a copy
# with that one rule broken, which must fail, in each arm it lives in (L1).
#
# arg_faults <library> <PATH>: one line per way the event and context arguments come out wrong.
arg_faults(){
  env PATH="$2" HN_LIB="$1" HN_T="$TRICKY" "$BASH" -c '
. "$HN_LIB" || exit 9
hook_notice_json "$HN_T"; echo "@@"
hook_notice_json "$HN_T" PostToolUse; echo "@@"
hook_notice_json "$HN_T" PostToolUse "ctx: $HN_T"; echo "@@"
hook_notice_json "$HN_T" PostToolUse ""; echo "@@"
hook_notice_json "$HN_T" "Pre\"Tool Use"' 2>/dev/null | HN_WANT="$TRICKY" python3 -c '
import json, os, sys
want = os.environ["HN_WANT"]
parts = sys.stdin.read().split("@@\n")
if len(parts) != 5:
    print("the library printed %d parts, not 5: %r" % (len(parts), parts[:2])); sys.exit()
def obj(n, what):
    try:
        d = json.loads(parts[n])
    except Exception as e:
        print("%s: not one JSON object (%s): %r" % (what, e, parts[n][:200])); return None
    if d.get("systemMessage") != want:
        print("%s: the systemMessage was %r" % (what, d.get("systemMessage"))); return None
    return d
d = obj(0, "no event")
if d is not None and set(d) != {"systemMessage"}:
    print("no event: it handed the session something anyway: %r" % d)
for n, what, ctx in ((1, "an event and no context", want), (2, "an event and a context", "ctx: " + want),
                     (3, "an event and an empty context", "")):
    d = obj(n, what)
    if d is None:
        continue
    h = d.get("hookSpecificOutput") or {}
    if h.get("hookEventName") != "PostToolUse":
        print("%s: hookEventName was %r" % (what, h.get("hookEventName")))
    elif h.get("additionalContext") != ctx:
        print("%s: additionalContext was %r, not %r" % (what, h.get("additionalContext"), ctx))
d = obj(4, "an event name that is not one word")
if d is not None and "hookSpecificOutput" in d:
    print("an event name that is not one word was passed on: %r" % d["hookSpecificOutput"])'
}
for arm in "$PATH" "$WORK/empty"; do
  name="with python3"; [ "$arm" = "$WORK/empty" ] && name="with nothing on PATH"
  got="$(arg_faults "$LIB" "$arm")"
  [ -z "$got" ] && ok || bad "#1924 $name: the library mishandles its event or context argument: $got"
done
# Each mutant: <name> TAB <text in the library> TAB <what it becomes> TAB <the arms it shows in>.
cat > "$WORK/mutants.tsv" <<'TSV'
the event is dropped	event="${2:-}"	event=""	both
an event is invented when none is given	event="${2:-}"	event="${2:-PostToolUse}"	both
the context is ignored for the text	context="${3-$1}"	context="$1"	both
an empty context is replaced by the text	context="${3-$1}"	context="${3:-$1}"	both
an event name is not checked	case "$event" in *[!A-Za-z]*) event="" ;; esac	:	both
python3 hands the text as the context	cut(os.environb[b"HN_CONTEXT"])	cut(os.environb[b"HN_TEXT"])	py
bash alone hands the text as the context	"$event" "$(_hn_string "$context")"	"$event" "$(_hn_string "$text")"	bash
TSV
mutants=0
while IFS=$'\t' read -r mname mold mnew marms; do
  [ -n "$mname" ] || continue
  mutants=$((mutants + 1))
  if ! HN_OLD="$mold" HN_NEW="$mnew" python3 -c '
import os, sys
s = open(sys.argv[1]).read(); old = os.environ["HN_OLD"]
if s.count(old) != 1: sys.exit(1)
open(sys.argv[2], "w").write(s.replace(old, os.environ["HN_NEW"]))' "$LIB" "$WORK/mutant.sh"; then
    bad "#1924 mutant \"$mname\": its text is not in lib/hook-notice.sh exactly once, so the check it proves is unproven. Update $WORK/mutants.tsv in this suite to the library's new wording."
    continue
  fi
  for arm in "$PATH" "$WORK/empty"; do
    a=py; name="with python3"; [ "$arm" = "$WORK/empty" ] && { a=bash; name="with nothing on PATH"; }
    case "$marms" in both|"$a") ;; *) continue ;; esac
    [ -n "$(arg_faults "$WORK/mutant.sh" "$arm")" ] && ok \
      || bad "#1924 canary, $name: a library in which $mname passed the argument checks"
  done
done < "$WORK/mutants.tsv"
[ "$mutants" -eq 7 ] && ok || bad "#1924 only $mutants argument mutants were read, not 7"

# hook_allow_notice lets the call through: exit 0, the JSON on stdout and nothing else there, and
# the same text on stderr for the debug log.
out="$(HN_TEXT="the check did not run" bash -c '. "$0" && hook_allow_notice "$HN_TEXT"; echo AFTER' "$LIB" 2>"$WORK/err")"; rc=$?
[ "$rc" -eq 0 ] && ok || bad "#1906 hook_allow_notice exited $rc, not 0, so with onFailure block it would refuse the call it allows"
[ "$(message_of "$out")" = "the check did not run" ] && ok || bad "#1906 hook_allow_notice printed [$out], not one systemMessage holding the notice (and it must exit, so nothing follows it)"
grep -q "the check did not run" "$WORK/err" && ok || bad "#1906 hook_allow_notice did not also write the notice to stderr, where the debug log keeps it"

# hook_notice_verdict, which the gates' own suites use, says nothing for a good notice and says why
# for every way stdout can fail to be one.
. "$LIB" 2>/dev/null
v="$(hook_notice_verdict '{"systemMessage": "ASSET CHECK DID NOT RUN (x)"}' 'ASSET CHECK DID NOT RUN')"
[ -z "$v" ] && ok || bad "#1906 hook_notice_verdict refused a good notice: $v"
for bad_out in '' 'plain words' '{"systemMessage": "a"}{"systemMessage": "b"}' '{"other": 1}' '{"systemMessage": "something else"}'; do
  v="$(hook_notice_verdict "$bad_out" 'DID NOT RUN')"
  [ -n "$v" ] && ok || bad "#1906 hook_notice_verdict passed [$bad_out] as a notice saying DID NOT RUN"
done

# --- the prompt hooks' notices reach the person ------------------------------------------------------
# A UserPromptSubmit or SessionStart hook's plain stdout becomes context for Claude ("Neither channel
# produces a visible transcript entry", hooks documentation) and its stderr on exit 0 is discarded,
# while its systemMessage is not among those the documentation says are discarded. So a prompt hook
# that could not do its job says so as a systemMessage, and still exits 0 so the prompt goes through.
# Each is run on the path that said it on stderr before (claude-config#1906).
prompt_hook(){   # prompt_hook <label> <ERE> <payload> <hook> [env assignment...]: runs it, judges stdout
  local label="$1" want="$2" payload="$3" hook="$4" out rc why; shift 4
  out="$(cd "$WORK" && printf '%s' "$payload" | env TMPDIR="$WORK" HOME="$WORK/home" "$@" "$BASH" "$DIR/$hook" 2>/dev/null)"; rc=$?
  why="$(hook_notice_verdict "$out" "$want")"
  [ "$rc" -eq 0 ] && [ -z "$why" ] && ok || bad "#1906 $hook, $label: wanted exit 0 and a systemMessage saying /$want/, got exit $rc. $why"
}
mkdir -p "$WORK/home"
NOSESSION='{"hook_event_name":"UserPromptSubmit","prompt":"hello"}'
WITHSESSION='{"hook_event_name":"UserPromptSubmit","session_id":"notice-probe","prompt":"hello"}'
prompt_hook "a payload with no session" "neither a session id" "$NOSESSION" payload-revert-warning.sh
mkdir -p "$WORK/rules"; printf 'rules\n' > "$WORK/rules/CLAUDE.md"
prompt_hook "a payload with no session" "neither a session id" "$NOSESSION" rule-files-changed.sh CLAUDE_RULES_DIR="$WORK/rules"
prompt_hook "a payload with no session" "neither a session id" "$NOSESSION" suite-pile-notice.sh
prompt_hook "a payload with no session" "neither a session id" "$NOSESSION" sync-stuck-notice.sh
prompt_hook "settings that are not whole numbers" "must all be whole numbers" "$WITHSESSION" suite-pile-notice.sh SYNC_SUITE_MAX_AGE=soon
# Run by its bare name from its own folder, as a person trying a hook by hand does, a hook that cuts
# its folder from its path in bash must still find the library rather than fall back.
for bare in sync-stuck-notice.sh suite-pile-notice.sh rtk-rewrite.sh; do
  out="$(cd "$DIR" && printf '%s' "$NOSESSION" | env PATH="$WORK/empty" TMPDIR="$WORK" HOME="$WORK/home" "$BASH" "$bare" 2>/dev/null)"
  case "$out" in
    *"lib/hook-notice.sh is missing"*) bad "#1906 $bare run by its bare name did not find lib/hook-notice.sh beside it: $out" ;;
    *systemMessage*) ok ;;
    *) bad "#1906 $bare run by its bare name with nothing on PATH said nothing: [$out]" ;;
  esac
done
mkdir -p "$WORK/catonly"; ln -s "$(command -v cat)" "$WORK/catonly/cat"; ln -s "$(command -v dirname)" "$WORK/catonly/dirname"
prompt_hook "no python3" "python3 is not on PATH" "$WITHSESSION" stale-worktree-nudge.sh PATH="$WORK/catonly"

# --- the scan --------------------------------------------------------------------------------------
# scan.py <stderr|plain> <file>...: one line per place a hook writes a notice and then exits 0, as
# <file>:<line>: <text>; stderr mode reads notices written to stderr, plain mode words printed plain
# to stdout. One scanner for both, so a shape taught to one is taught to the other (#1924).
#
# A notice is: a line writing one (stderr: `>&2`; plain: an echo or printf of words, or `cat <<EOF`,
# with nothing redirecting it); the closing line of a bare `{ ... }` group (`} >&2`, or in plain mode
# one printing words with no redirect); or a CALL, in command position, of a function whose last
# statement (before a bare `return`) is a notice and which never exits itself, so a notice written
# in a function that returns before a later exit 0 is found at its call (#1924). It is reported when
# the same line goes on to `exit 0`, or the next code line is `exit 0` or a bare exit. A notice its
# own line closes with a refusal (`|| { ...>&2; exit 2; }`) is followed by that exit. Comment lines
# are skipped, and a here document is read to its end before the next line is looked at.
#
# A branch taken only when the script is run with a flag its registrations never pass
# (`if [ "${1:-}" = "--snooze-session" ]; then ... fi`) is a command a person runs in a terminal,
# where its output is read, so it is not scanned. HN_FLAGS holds each script's registered flags.
#
# What it does not see: a notice whose exit 0 is not the next code line, a call inside $( ), and a
# function that exits on some path. Those are found by reading.
cat > "$WORK/scan.py" <<'PY'
import json, os, re, sys
mode = sys.argv[1]
FLAGS = json.loads(os.environ.get("HN_FLAGS") or "{}")
STDERR = re.compile(r'(^|[^0-9&<])1?>&2(?![0-9])')
PLAIN = re.compile(r'''^\s*(echo\s+(-[a-zA-Z]+\s+)*["'][A-Za-z(]|printf\s+["'][A-Za-z(])''')
EXIT0 = re.compile(r'^\s*exit(\s+0)?\s*(;;|;|\)|\}|$)')
THEN_EXIT0 = re.compile(r'^[^#]*?(;|&&)\s*exit(\s+0)?\s*(;;|;|\}|\)|$)')
THEN_REFUSE = re.compile(r'^[^#]*?(;|&&)\s*exit\s+[1-9]')
HEREDOC = re.compile(r'(?<!<)<<(?!<)-?\s*[\'"]?([A-Za-z_][A-Za-z0-9_]*)[\'"]?')
FUNC = re.compile(r'^(\s*)(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{(.*)$')
ARGBRANCH = re.compile(r'''^(\s*)if\s+\[\[?\s+"?\$\{?1(?::-)?\}?"?\s+==?\s+["']?(--[A-Za-z0-9-]+)["']?\s+\]\]?\s*;\s*then\s*$''')
EXIT_ANY = re.compile(r'(^|[;&|{(\s])exit(\s|;|$)')
RETURN = re.compile(r'^\s*return(\s+0)?\s*;?\s*$')

def indent(line):
    return len(line) - len(line.lstrip())

def logical(lines):
    # (line number, text, starts a here document) per line, a here document's body folded away.
    out, i = [], 0
    while i < len(lines):
        line = lines[i]
        s = line.strip()
        m = HEREDOC.search(line) if s and not s.startswith("#") else None
        out.append((i + 1, line, bool(m)))
        i += 1
        if m:
            while i < len(lines) and lines[i].strip() != m.group(1):
                i += 1
            i += 1
    return out

def code(e):
    s = e[1].strip()
    return bool(s) and not s.startswith("#")

def direct(e):
    # Where on the line a notice it writes ends, or -1 for none.
    line = e[1]
    if not code(e):
        return -1
    if mode == "stderr":
        m = STDERR.search(line)
        return m.end() if m else -1
    if PLAIN.search(line):
        tail = line.rsplit('"', 1)[-1] if '"' in line else line
        if re.search(r'[>|]', tail):
            return -1
        return line.rfind('"') + 1 if '"' in line else len(line)
    if e[2] and re.match(r'^\s*cat\s+<<', line) and not re.search(r'[>|]', HEREDOC.sub('', line)):
        return len(line)
    return -1

def calls(line, names):
    # Where a call, in command position, of one of names ends, or -1.
    for n in sorted(names):
        m = re.search(r'(^\s*|(;|&&|\|\||\bthen|\bdo|\belse|\{)\s*)' + re.escape(n) + r'(?=\s|;|$)', line)
        if not m:
            continue
        cut = re.split(r'(;|&&|\|\|)', line[m.end():], maxsplit=1)[0]
        if re.search(r'2>|&>' if mode == "stderr" else r'[>|]', cut):
            continue
        return m.end()
    return -1

def scan(path):
    try:
        lines = open(path, encoding="utf-8", errors="replace").read().split("\n")
    except OSError as e:
        print("%s:0: could not be read (%s)" % (path, e)); return
    L = logical(lines)
    flags = set(FLAGS.get(os.path.basename(path), []))
    skip = set()
    for i, e in enumerate(L):
        m = ARGBRANCH.match(e[1]) if code(e) else None
        if not m or m.group(2) in flags:
            continue
        j = i + 1
        while j < len(L) and not (L[j][1].strip() == "fi" and indent(L[j][1]) == len(m.group(1))):
            j += 1
        if j < len(L):
            skip.update(range(i, j + 1))
    bodies = {}
    for i, e in enumerate(L):
        m = FUNC.match(e[1]) if code(e) else None
        if not m:
            continue
        ind, name, rest = m.groups()
        r = rest.rstrip()
        if r.endswith("}"):
            bodies[name] = [(e[0], s.strip(), False) for s in r[:-1].split(";") if s.strip()]
            continue
        body, j = [], i + 1
        while j < len(L) and not (L[j][1].strip().startswith("}") and indent(L[j][1]) <= len(ind)):
            if code(L[j]):
                body.append(L[j])
            j += 1
        bodies[name] = body
    noticing, changed = set(), True
    while changed:
        changed = False
        for name, body in bodies.items():
            if name in noticing or not body or any(EXIT_ANY.search(b[1]) for b in body):
                continue
            k = len(body) - 1
            if RETURN.match(body[k][1]) and k > 0:
                k -= 1
            if direct(body[k]) >= 0 or calls(body[k][1], noticing) >= 0:
                noticing.add(name); changed = True
    groups, open_groups = set(), []
    for i, e in enumerate(L):
        if not code(e):
            continue
        s = e[1].strip()
        if s == "{":
            open_groups.append([indent(e[1]), False])
        elif open_groups and s.startswith("}") and indent(e[1]) == open_groups[-1][0]:
            printed = open_groups.pop()[1]
            if mode == "plain" and printed and not re.search(r'[>|]', s):
                groups.add(i)
        elif open_groups and mode == "plain" and direct(e) >= 0:
            open_groups[-1][1] = True
    for i, e in enumerate(L):
        if i in skip or not code(e):
            continue
        end = len(e[1]) if i in groups else direct(e)
        if end < 0:
            end = calls(e[1], noticing)
        if end < 0:
            continue
        after = e[1][end:]
        if THEN_REFUSE.search(after):
            continue
        hit = THEN_EXIT0.search(after)
        if not hit:
            j = i + 1
            while j < len(L) and not code(L[j]):
                j += 1
            hit = j < len(L) and EXIT0.match(L[j][1])
        if hit:
            print("%s:%d: %s" % (path, e[0], e[1].strip()[:160]))

for p in sys.argv[2:]:
    scan(p)
PY
scan(){ python3 "$WORK/scan.py" stderr "$@"; }

# The scan is seen to find each shape first, and to pass what is not one (L1).
cat > "$WORK/next-line.sh" <<'SH'
echo "CHECK DID NOT RUN" >&2
exit 0
SH
cat > "$WORK/same-line.sh" <<'SH'
[ -f x ] || { echo "skipping the check" >&2; exit 0; }
SH
cat > "$WORK/group.sh" <<'SH'
{
  echo "nothing was judged"
} >&2
exit 0
SH
cat > "$WORK/heredoc.sh" <<'SH'
cat >&2 <<EOF
the check did not run
EOF
exit
SH
cat > "$WORK/in-case.sh" <<'SH'
case "$v" in
  *) echo "GATE DID NOT RUN" >&2
     # a comment between
     exit 0 ;;
esac
SH
# A notice written by a function that returns, the exit 0 after the call (#1924): the function's
# last word is the notice, so each call of it is one.
cat > "$WORK/function-return.sh" <<'SH'
note(){
  echo "the check was skipped" >&2
  return 0
}
note
exit 0
SH
cat > "$WORK/function-one-line.sh" <<'SH'
warn(){ printf '%s\n' "$1" >&2; }
warn "nothing was judged"; exit 0
SH
cat > "$WORK/function-nested.sh" <<'SH'
say(){ echo "not run" >&2; }
skip(){
  say
}
if true; then skip
  exit 0
fi
SH
for f in next-line same-line group heredoc in-case function-return function-one-line function-nested; do
  [ -n "$(scan "$WORK/$f.sh")" ] && ok || bad "#1906 #1924 canary: the scan did not find the $f shape of a stderr notice followed by exit 0"
done
# A function that refuses on its own, and one whose call is silenced, are not notices.
cat > "$WORK/function-clean.sh" <<'SH'
die(){ echo "PUSH BLOCKED: $1" >&2; exit 2; }
die "a reason"
exit 0
note(){
  echo "a detail" >&2
}
note 2>/dev/null
exit 0
SH
[ -z "$(scan "$WORK/function-clean.sh")" ] && ok || bad "#1924 control: the scan flagged a refusing function or a silenced call: $(scan "$WORK/function-clean.sh")"
cat > "$WORK/clean.sh" <<'SH'
echo "PUSH BLOCKED: reasons" >&2
exit 2
hook_allow_notice "the check did not run"
echo "fine" 2>&1
exit 0
cmd 2>/dev/null
exit 0
echo "refused" >&2; exit 2
encode || { printf '%s\n' "$1" >&2; exit 2; }
exit 0
SH
[ -z "$(scan "$WORK/clean.sh")" ] && ok || bad "#1906 control: the scan flagged a refusal, a notice through the library or a silenced command: $(scan "$WORK/clean.sh")"

# scan_plain <file>...: words printed plain to stdout and then exit 0. On every event but
# UserPromptSubmit and SessionStart the documentation sends that stdout to the debug log, not the
# transcript, so the words reach nobody. A printf whose format starts with % (passing on JSON a
# helper built) is not words. The same scanner as scan, reading stdout instead of stderr.
scan_plain(){ python3 "$WORK/scan.py" plain "$@"; }
printf 'echo "duplication check: skipped, nothing compared"\nexit 0\n' > "$WORK/plain.sh"
printf 'printf %s\\n "$out"\nexit 0\necho "to stderr" >&2\nexit 2\necho "piped" | cat\nexit 0\n' "'%s'" > "$WORK/plain-clean.sh"
[ -n "$(scan_plain "$WORK/plain.sh")" ] && ok || bad "#1906 canary: the plain stdout scan did not find words printed plain and then exit 0"
[ -z "$(scan_plain "$WORK/plain-clean.sh")" ] && ok || bad "#1906 control: the plain stdout scan flagged a JSON pass through, stderr or a pipe: $(scan_plain "$WORK/plain-clean.sh")"
# The shapes beyond one echo on the line before exit 0 (#1924): the two on one line, a group, a here
# document, and a function that prints and returns.
printf 'echo "skipped the check"; exit 0\n' > "$WORK/plain-same-line.sh"
printf '{\n  echo "nothing was judged"\n  echo "for this push"\n}\nexit 0\n' > "$WORK/plain-group.sh"
printf 'cat <<EOF\nthe check did not run\nEOF\nexit 0\n' > "$WORK/plain-heredoc.sh"
printf 'tell(){\n  echo "the review was skipped"\n}\ntell\nexit 0\n' > "$WORK/plain-function.sh"
for f in plain-same-line plain-group plain-heredoc plain-function; do
  [ -n "$(scan_plain "$WORK/$f.sh")" ] && ok || bad "#1924 canary: the plain stdout scan did not find the $f shape of words printed plain before exit 0"
done
printf '{\n  echo "PUSH BLOCKED"\n} >&2\nexit 2\n{\n  echo "kept"\n} > "$f"\nexit 0\ncat <<EOF >&2\nto stderr\nEOF\nexit 0\n' > "$WORK/plain-group-clean.sh"
[ -z "$(scan_plain "$WORK/plain-group-clean.sh")" ] && ok || bad "#1924 control: the plain stdout scan flagged a redirected group or here document: $(scan_plain "$WORK/plain-group-clean.sh")"
# A branch the script takes only when run with a flag no registration passes is a command a person
# runs (pr-merge-quiz.sh --snooze-session), whose stdout is read in a terminal, so its words are not
# a lost notice. The same branch on a flag a registration does pass is the hook speaking, and is.
printf 'if [ "${1:-}" = "--snooze" ]; then\n  echo "Snoozed for this session."\n  exit 0\nfi\nexit 0\n' > "$WORK/plain-terminal.sh"
[ -z "$(HN_FLAGS='{}' scan_plain "$WORK/plain-terminal.sh")" ] && ok || bad "#1924 control: the plain stdout scan flagged a branch for a flag no registration passes: $(HN_FLAGS='{}' scan_plain "$WORK/plain-terminal.sh")"
[ -n "$(HN_FLAGS='{"plain-terminal.sh": ["--snooze"]}' scan_plain "$WORK/plain-terminal.sh")" ] && ok \
  || bad "#1924 canary: the plain stdout scan passed a branch for a flag the registration passes, where the hook itself prints"

# scan_handbuilt <file>...: a systemMessage written anywhere but lib/hook-notice.sh. A hand built
# object breaks on a newline, a tab or a quote in its text (check-wrapped-commands.sh,
# sync-main-to-dev.sh and pr-merge-quiz.sh each did), and invalid output is a hook failure. Reading
# the field (.systemMessage) is not writing it, and the fallback a hook declares for a missing
# library keeps only characters that need no escaping.
scan_handbuilt(){
  python3 - "$@" <<'PY'
import re, sys
for path in sys.argv[1:]:
    for n, line in enumerate(open(path, encoding="utf-8", errors="replace"), 1):
        s = line.strip()
        if s.startswith("#") or "systemMessage" not in s:
            continue
        if "(lib/hook-notice.sh is missing beside this hook)" in s:
            continue
        if not re.sub(r'\.systemMessage\b', "", s).count("systemMessage"):
            continue
        print("%s:%d: %s" % (path, n, s[:160]))
PY
}
printf 'printf %s "$m"\n' "'{\"systemMessage\": \"%s\"}\\n'" > "$WORK/handbuilt.sh"
printf 'jq -nc --arg m "$m" %s\n' "'{systemMessage: \$m}'" > "$WORK/handbuilt-jq.sh"
printf 'msg="$(jq -r %s <<< "$out")"\nhook_notice_json "$m"\n' "'.systemMessage // \"\"'" > "$WORK/handbuilt-clean.sh"
[ -n "$(scan_handbuilt "$WORK/handbuilt.sh")" ] && ok || bad "#1906 canary: the hand built scan did not find a printf of a systemMessage"
[ -n "$(scan_handbuilt "$WORK/handbuilt-jq.sh")" ] && ok || bad "#1906 canary: the hand built scan did not find a jq built systemMessage"
[ -z "$(scan_handbuilt "$WORK/handbuilt-clean.sh")" ] && ok || bad "#1906 control: the hand built scan flagged a read of the field or a call to the library: $(scan_handbuilt "$WORK/handbuilt-clean.sh")"

# The subjects: every hook in settings.hooks.json, on every event, read from the registration rather
# than a list, so a new hook is in scope the day it is registered (L96). Not only the gates: a hook
# that never refuses (rtk-rewrite.sh) loses its warnings to the same rule, and so does a hook on
# another event: the documentation's "Claude never sees stderr from a hook that exits 0" is not
# limited to PreToolUse. SessionEnd discards a systemMessage too, so its hook says a notice on stderr
# with exit 2, which the documentation says SessionEnd shows the user.
. "$DIR/lib/settings-file.sh" 2>/dev/null || { bad "lib/settings-file.sh is missing beside this suite"; }
REG="$(hook_settings_file "$DIR/.." 2>/dev/null)" || REG=""
if [ -z "$REG" ]; then
  bad "#1906 no settings.hooks.json or settings.json beside $DIR, so no hook was scanned"
else
  # One line per script: <name>\t<1 when its plain stdout reaches no one>. That is every event but
  # UserPromptSubmit and SessionStart, whose plain stdout is context for the session by design: a
  # PreToolUse hook's goes to the debug log, and so does a PostToolUse or Stop hook's (#1924).
  # HN_FLAGS is each script's flags as its registrations pass them, so the scan can tell a branch
  # the hook takes from one only a person running it by hand does.
  scripts="$(python3 - "$REG" "$WORK/flags.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
seen, flags = {}, {}
for event, groups in d.get("hooks", {}).items():
    for group in groups:
        for h in group.get("hooks", []):
            words = h.get("command", "").split()
            for k, word in enumerate(words):
                if word.endswith(".sh"):
                    name = word.rsplit("/", 1)[-1]
                    seen[name] = seen.get(name, False) or event not in ("UserPromptSubmit", "SessionStart")
                    flags.setdefault(name, set()).update(w for w in words[k + 1:] if w.startswith("--"))
json.dump({n: sorted(f) for n, f in flags.items()}, open(sys.argv[2], "w"))
print("\n".join("%s\t%d" % (n, p) for n, p in seen.items()))
PY
)"
  HN_FLAGS="$(cat "$WORK/flags.json" 2>/dev/null)"; export HN_FLAGS
  hooks=(); plain_hooks=()
  while IFS=$'\t' read -r s plain; do
    [ -n "$s" ] || continue
    if [ -f "$DIR/$s" ]; then
      hooks+=("$DIR/$s")
      [ "$plain" = 1 ] && plain_hooks+=("$DIR/$s")
    else bad "#1906 $s is registered but is not in $DIR"; fi
  done <<< "$scripts"
  # Judged by the count it scanned (L288): on 2026-10-30 49 hook scripts were registered on an event
  # whose plain stdout reaches no one (37 PreToolUse hooks among them) and 65 in all.
  if [ "${#plain_hooks[@]}" -ge 45 ] && [ "${#hooks[@]}" -ge 50 ]; then ok
  else bad "#1906 #1924 only ${#hooks[@]} hooks (${#plain_hooks[@]} whose plain stdout reaches no one) were found to scan, so the registration was not read as expected"
  fi
  for want in require-issue-fields.sh no-session-link-in-comments.sh handback-claims-gate.sh check-deferrals.sh \
              require-tests-before-push.sh simplify-before-push.sh check-public-assets.sh check-gh-watch-interval.sh \
              check-filed-issue-session.sh issue-spool-session-end.sh suite-pile-notice.sh rule-files-changed.sh; do
    case " ${hooks[*]} " in *"/$want "*) ok ;; *) bad "#1906 $want was not among the hooks scanned" ;; esac
  done
  # The plain stdout scan reads PostToolUse and Stop hooks too (#1924), and pr-merge-quiz.sh, on
  # both, is read with the flag its Stop registration passes it.
  for want in pr-merge-quiz.sh sync-main-to-dev.sh check-filed-issue-session.sh session-reflection.sh require-tests-before-push.sh; do
    case " ${plain_hooks[*]} " in *"/$want "*) ok ;; *) bad "#1924 $want was not among the hooks the plain stdout scan reads" ;; esac
  done
  case "$HN_FLAGS" in *'"pr-merge-quiz.sh": ["--release-held"]'*) ok ;; *) bad "#1924 the flags pr-merge-quiz.sh is registered with were not read: ${HN_FLAGS:0:300}" ;; esac
  case " ${plain_hooks[*]} " in *"/rule-files-changed.sh "*) bad "#1924 rule-files-changed.sh, on UserPromptSubmit and SessionStart only, was read by the plain stdout scan, where its stdout is context by design" ;; *) ok ;; esac
  found="$(scan "${hooks[@]}")"
  if [ -z "$found" ]; then ok
  else
    bad "#1906 these hooks write a notice to stderr and then exit 0, where Claude Code shows it to nobody. Send it with hook_allow_notice from lib/hook-notice.sh instead:"
    printf '%s\n' "$found" | sed "s|$DIR/|  |"
  fi
  found="$(scan_plain "${plain_hooks[@]}")"
  if [ -z "$found" ]; then ok
  else
    bad "#1906 #1924 these hooks print words plain on stdout and then exit 0, on an event where that stdout goes to the debug log. Send them with hook_allow_notice from lib/hook-notice.sh instead:"
    printf '%s\n' "$found" | sed "s|$DIR/|  |"
  fi
  echo "  scanned ${#hooks[@]} hooks, ${#plain_hooks[@]} of them on an event whose plain stdout reaches no one"

  # Every hook that sends a notice through the library sources it with the fallback the library's
  # header gives, so a missing library lets the call through saying so rather than leaving
  # hook_allow_notice undefined and carrying on into the gate's logic.
  sources_with_fallback(){   # <file>: true when its code sources the library with the fallback
    local code; code="$(grep -v -E '^[[:space:]]*#' "$1")"
    grep -q -E '^[[:space:]]*\. "\$[A-Z_]+/lib/hook-notice\.sh" 2>/dev/null \|\| hook_allow_notice\(\) \{' <<< "$code" \
      && grep -q -F '(lib/hook-notice.sh is missing beside this hook)"}\n'"'"' "${1//[^A-Za-z0-9 .,:;()\/_=+#-]/}"; exit 0; }' <<< "$code"
  }
  # Seen to tell the two apart first (L1). The good one is the library header's own example, so the
  # header and this check cannot drift apart.
  header_example="$(sed -n 's/^#   //p' "$LIB")"
  { echo 'HOOK_DIR=.'; awk 'index($0, "lib/hook-notice.sh\" 2>/dev/null ||") { on = 1 } on && !done { print } on && index($0, "exit 0; }") { done = 1 }' <<< "$header_example"; echo 'hook_allow_notice "x"'; } > "$WORK/fallback-good.sh"
  printf '. "$HOOK_DIR/lib/hook-notice.sh" 2>/dev/null || exit 0\nhook_allow_notice "x"\n' > "$WORK/fallback-bad.sh"
  sources_with_fallback "$WORK/fallback-good.sh" && ok || bad "#1906 canary: the library header's own fallback example did not pass the fallback check"
  sources_with_fallback "$WORK/fallback-bad.sh" && bad "#1906 canary: a hook that sources the library with no fallback passed the fallback check" || ok
  # The good fixture really works: with no library beside it, the call is let through and said.
  out="$(cd "$WORK" && bash fallback-good.sh 2>/dev/null)"; rc=$?
  why="$(hook_notice_verdict "$out" 'x \(lib/hook-notice.sh is missing beside this hook\)')"
  [ "$rc" -eq 0 ] && [ -z "$why" ] && ok || bad "#1906 the header's fallback, run with no library beside it, did not exit 0 with its notice (exit $rc): $why"
  users=0
  for h in "${hooks[@]}"; do
    code="$(grep -v -E '^[[:space:]]*#' "$h")"
    case "$code" in *'hook_allow_notice "'*) ;; *) continue ;; esac
    users=$((users + 1))
    if sources_with_fallback "$h"; then ok
    else bad "#1906 $(basename "$h") calls hook_allow_notice but does not source lib/hook-notice.sh with the fallback its header gives"
    fi
  done
  if [ "$users" -ge 24 ]; then ok
  else bad "#1906 only $users registered hooks send a notice through lib/hook-notice.sh, fewer than the 24 moved onto it"
  fi
fi

# Every shell script under the hooks, registered or a library, builds a systemMessage only through
# lib/hook-notice.sh. Suites are left out: they read the field and write fixtures of it.
shell_files=()
while IFS= read -r f; do shell_files+=("$f"); done < <(find "$DIR" -name '*.sh' ! -name 'test-*.sh' ! -path "$LIB" -type f | sort)
if [ "${#shell_files[@]}" -ge 100 ]; then ok
else bad "#1906 only ${#shell_files[@]} shell scripts were found under $DIR to scan for a hand built systemMessage"
fi
found="$(scan_handbuilt "${shell_files[@]}")"
if [ -z "$found" ]; then ok
else
  bad "#1906 these scripts build a systemMessage by hand, which breaks on a newline, tab or quote in its text. Build it with hook_notice_json or hook_allow_notice from lib/hook-notice.sh:"
  printf '%s\n' "$found" | sed "s|$DIR/|  |"
fi

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
