#!/usr/bin/env bash
# Tests that db-write-ask.sh judges a Bash command by the reading the shared reader gives a caller
# that asks which lines it is unsure of (claude-config#3472).
#
# The hook reads a command through lib/shell-words.py, which took a # for a comment by a rule the
# shell does not follow, so a command on the rest of that line was left out of what the hook judged
# (the shapes are test-shell-words-comment-start.sh's, measured against bash and zsh for
# claude-config#3464). Three things followed, each reproduced here against the unchanged hook: a
# database write on such a line was not asked about; a `supabase db push` Dan had applied was let
# through with that line riding along; and a commit of an unapproved line onto a test project list
# was not asked about. The reader now reads on where every shell does, and names the # it cannot
# tell from a comment, but only for a caller that asks. So: a write on such a line is asked about as
# any other, a # that cannot be told is asked about saying so, nothing is let through unless both
# readings find the same one run, and what the hook did with an ordinary command it still does.
#
# Every command here is only ever text in a payload handed to the hook: nothing a case names runs.
# The only programs started are the hook, python3 and, for the commit cases, git in a checkout this
# suite makes in its own temporary folder. Every project ref and path is invented.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/db-write-ask.sh"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

if [ ! -f "$HOOK" ]; then
  echo "FAIL: there is no db-write-ask.sh beside this suite at $DIR"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

WORK="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cases.py" <<'PY'
import datetime, hashlib, importlib.util, json, os, subprocess, sys, types

hook, work = sys.argv[1], sys.argv[2]
home = os.path.join(work, "home")
os.makedirs(home)
env = dict(os.environ, HOME=home)
env.pop("CLAUDE_HOME", None)

R = 'supabase db query --linked "select id from runs"'
PUSH = "supabase db push --linked --yes"
# What a line can hide: (its name, the command, words its question must hold).
WRITES = (
    ("a delete", 'supabase db query --linked "delete from runs"', "delete from runs"),
    ("an update", 'psql -c "update runs set note = 1"', "update runs set note = 1"),
    ("a drop", 'supabase db query --linked "drop table runs"', "drop table runs"),
    ("a push", PUSH, "applies the pending migrations"),
)
# Where every shell reads the # inside a word and runs the rest of the line.
READ_ON = (("an escaped space", "\\ "), ("an escaped tab", "\\\t"),
           ("three backslashes and a space", "\\\\\\ "), ("an escaped ;", "\\;"),
           ("an escaped &", "\\&"), ("an escaped |", "\\|"), ("an escaped (", "\\("),
           ("an escaped )", "\\)"), ("a line joined mid word", "\\\n"),
           ("a line joined after an escaped space", "\\ \\\n"),
           ("a line joined after an escaped ;", "\\;\\\n"))
UNSURE = "cannot tell from a comment"


def decided(command, cwd, transcript=None):
    d = {"session_id": "s1", "hook_event_name": "PreToolUse", "cwd": cwd, "tool_name": "Bash",
         "tool_input": {"command": command, "description": "d"}}
    if transcript is not None:
        d["transcript_path"] = transcript
    p = subprocess.run(["bash", hook], input=json.dumps(d).encode(), stdout=subprocess.PIPE,
                       stderr=subprocess.DEVNULL, env=env, cwd=work)
    out = p.stdout.decode("utf-8", "replace").strip()
    if not out:
        return "none rc=%d" % p.returncode, ""
    try:
        h = json.loads(out).get("hookSpecificOutput") or {}
    except ValueError:
        return "badjson rc=%d" % p.returncode, out[:300]
    return "%s rc=%d" % (h.get("permissionDecision", "none"), p.returncode), h.get("permissionDecisionReason", "")


def write(path, text):
    with open(path, "w") as f:
        f.write(text)
    return path


def sha_of(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def stamp_after(folder):
    """An ISO time, to the millisecond as Claude Code stamps an entry, later than every file under
    folder was written: a dry run stamped in the millisecond its migrations were written in reads as
    one that came before them. Waits on the clock passing that millisecond, never a fixed time."""
    newest = max(os.stat(os.path.join(root, n)).st_ctime_ns for root, _, names in os.walk(folder) for n in names)
    epoch = datetime.datetime(1970, 1, 1, tzinfo=datetime.timezone.utc)
    while True:
        now = datetime.datetime.now(datetime.timezone.utc)
        if ((now - epoch) // datetime.timedelta(milliseconds=1)) * 1000000 > newest:
            return now.isoformat(timespec="milliseconds").replace("+00:00", "Z")


def transcript(path, applied, dry_cmd, dry_cwd, ref="exampleprojectref000"):
    """A session transcript holding the dry run the /db-apply skill runs first and then its picker
    with Dan's Apply for the file applied, in the shape test-db-write-ask.sh writes them."""
    q = "Apply migration " + os.path.basename(applied) + " to project " + ref + "?"
    ask = {"questions": [{"question": q, "header": "Migration", "multiSelect": False,
                          "options": [{"label": "Apply", "description": "Run it"}, {"label": "Cancel", "description": "Do not"}]}],
           "metadata": {"source": "db-apply", "migration": applied, "sha256": sha_of(applied), "project_ref": ref,
                        "pending": [os.path.basename(applied)]}}
    stamp = stamp_after(proj)
    lines = [
        {"type": "user", "sessionId": "s1", "message": {"role": "user", "content": "apply the migration"}},
        {"type": "assistant", "sessionId": "s1", "timestamp": stamp, "cwd": dry_cwd, "message": {
            "role": "assistant", "content": [
                {"type": "tool_use", "id": "toolu_dry1", "name": "Bash", "input": {"command": dry_cmd, "description": "d"}}]}},
        {"type": "user", "sessionId": "s1", "timestamp": stamp, "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": "toolu_dry1", "content": "Would push these migrations:\n 002_note.sql",
             "is_error": False}]}},
        {"type": "assistant", "sessionId": "s1", "message": {"role": "assistant", "content": [
            {"type": "tool_use", "id": "toolu_apply1", "name": "AskUserQuestion", "input": ask}]}},
        {"type": "user", "sessionId": "s1", "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": "toolu_apply1", "content": "answered"}]},
         "toolUseResult": {"questions": ask["questions"], "answers": {q: "Apply"}, "annotations": {}}},
    ]
    with open(path, "w") as f:
        for l in lines:
            f.write(json.dumps(l) + "\n")
    return path


# ---- the fixture: one project with a migration Dan applied, and a file he applied -----------------
proj = os.path.join(work, "proj")
elsewhere = os.path.join(work, "elsewhere")
os.makedirs(os.path.join(proj, "supabase", "migrations"))
os.makedirs(os.path.join(proj, "supabase", ".temp"))
os.makedirs(elsewhere)
write(os.path.join(proj, "supabase", "migrations", "001_first.sql"), "create table a (id int);\n")
mig = write(os.path.join(proj, "supabase", "migrations", "002_note.sql"), "alter table a add column note text;\n")
write(os.path.join(proj, "supabase", ".temp", "project-ref"), "exampleprojectref000")
change = write(os.path.join(proj, "change.sql"), "do $$ begin update a set note = 1 where id = 7; end $$;\n")
NONE_T = write(os.path.join(work, "no-apply.jsonl"),
               '{"type": "user", "sessionId": "s1", "message": {"role": "user", "content": "hi"}}\n')
GOOD_T = transcript(os.path.join(work, "apply.jsonl"), mig, "supabase db push --dry-run", proj)
CHANGE_T = transcript(os.path.join(work, "change.jsonl"), change, "supabase db push --dry-run", proj)
WRITE_Q = "supabase db query --linked --yes -f change.sql"

# rows: (the decision wanted, label, command, cwd, transcript, words the reason must hold or None,
# the whole reason or None)
rows = []

# ---- 1. a database write on a line the old reading left out is asked about -----------------------
for what, hidden, names in WRITES:
    front = R + " -o json"
    for shape, before in READ_ON:
        rows.append(("ask", "%s on the line of a # after %s is asked about" % (what, shape),
                     front + before + "# c; " + hidden + "\n", work, None, names, None))
    rows.append(("ask", "%s on the line of a # after two lines joined mid word is asked about" % what,
                 R + " -o js\\\non\\\n# c; " + hidden + "\n", work, None, names, None))
    # Where the reader cannot tell which the shell does, and names the line.
    rows += [
        ("ask", "%s on the line of a # after a word that ends in a parenthesis is asked about" % what,
         R + " -o a(b)# c; " + hidden + "\n", work, None, UNSURE, None),
        ("ask", "%s on the line of a # after a cd to a folder that ends in a parenthesis is asked about" % what,
         "cd /tmp/a(b)# c; " + hidden + "\n" + R + "\n", work, None, UNSURE, None),
        ("ask", "%s on the line of a # after a cd and a stray ) is asked about" % what,
         "cd /tmp/x)# c; " + hidden + "\n" + R + "\n", work, None, UNSURE, None),
        ("ask", "%s on a # line after an unsure comment that ends in a backslash is asked about" % what,
         R + " -o a(b)# c\\\n# d; " + hidden + "\n", work, None, UNSURE, None),
    ]
# The line in front need not name a database at all.
rows += [
    ("ask", "a delete on the line of a # after an escaped space in a command that reads no database is asked about",
     "printf done\\ # c; " + WRITES[0][1] + "\n", work, None, WRITES[0][2], None),
    ("ask", "a delete on the line of a # after a word ending in a parenthesis in a command that reads no database is asked about",
     "printf a(b)# c; " + WRITES[0][1] + "\n", work, None, UNSURE, None),
    ("ask", "the question about a # that cannot be told names this issue",
     R + " -o a(b)# c; " + WRITES[0][1] + "\n", work, None, "claude-config#3472", None),
]

# ---- 2. a push Dan applied is not let through with a line riding along ---------------------------
RIDERS = (("a delete", WRITES[0][1]), ("a folder removal", "rm -rf supabase/migrations"))
for what, hidden in RIDERS:
    for shape, before in READ_ON:
        rows.append(("ask", "an applied push with %s on the line of a # after %s is asked about, not let through" % (what, shape),
                     PUSH + " x" + before + "# c; " + hidden + "\n", proj, GOOD_T, None, None))
    rows += [
        ("ask", "an applied push with %s on the line of a # after two lines joined mid word is asked about, not let through" % what,
         "supabase db push --linked --y\\\nes\\\n# c; " + hidden + "\n", proj, GOOD_T, None, None),
        ("ask", "an applied push with %s on the line of a # after a word that ends in a parenthesis is asked about, not let through" % what,
         PUSH + " a(b)# c; " + hidden + "\n", proj, GOOD_T, UNSURE, None),
        ("ask", "an applied push after a cd to a folder that ends in a parenthesis, a # and %s is asked about, not let through" % what,
         "cd /tmp/a(b)# c; " + hidden + "\n" + PUSH + " --workdir " + proj + "\n", elsewhere, GOOD_T, UNSURE, None),
        ("ask", "an applied push after a cd, a stray ), a # and %s is asked about, not let through" % what,
         "cd /tmp/x)# c; " + hidden + "\n" + PUSH + " --workdir " + proj + "\n", elsewhere, GOOD_T, UNSURE, None),
        ("ask", "an applied push with %s on a # line after an unsure comment that ends in a backslash is asked about, not let through" % what,
         PUSH + " a(b)# c\\\n# d; " + hidden + "\n", proj, GOOD_T, UNSURE, None),
        # The write from a file Dan applied, the skill's other run.
        ("ask", "an applied write from a file with %s on the line of a # after a line joined mid word is asked about, not let through" % what,
         WRITE_Q + "\\\n# c; " + hidden + "\n", proj, CHANGE_T, None, None),
        ("ask", "an applied write from a file after a cd to a folder that ends in a parenthesis, a # and %s is asked about, not let through" % what,
         "cd /tmp/a(b)# c; " + hidden + "\ncd " + proj + " && " + WRITE_Q + "\n", elsewhere, CHANGE_T, UNSURE, None),
    ]
rows.append(("ask", "the question about an applied push with a line riding along says the push is not the whole command",
             PUSH + " x\\ # c; rm -rf supabase/migrations\n", proj, GOOD_T, "inside a word", None))
rows.append(("ask", "the question about an applied push with a line riding along names this issue",
             PUSH + " x\\ # c; rm -rf supabase/migrations\n", proj, GOOD_T, "claude-config#3472", None))
# The dry run Dan saw before his Apply is read the same way: one with a line the old reading left
# out is not the dry run of this project that the Apply needs.
HID_DRY_T = transcript(os.path.join(work, "hidden-dry.jsonl"), mig,
                       "supabase db push --dry-run --workdir " + proj + "\\\n# c; printf done\n", elsewhere)
UNSURE_DRY_T = transcript(os.path.join(work, "unsure-dry.jsonl"), mig,
                          "cd /tmp/a(b)# c; printf done\nsupabase db push --dry-run --workdir " + proj + "\n", elsewhere)
rows += [
    ("ask", "a push whose only dry run held a line joined mid word and a # is asked about",
     PUSH, proj, HID_DRY_T, "dry run", None),
    ("ask", "a push whose only dry run held a # that cannot be told from a comment is asked about",
     PUSH, proj, UNSURE_DRY_T, "dry run", None),
]

# ---- 3. what the hook did with an ordinary command it still does ----------------------------------
COMMENT_DRY_T = transcript(os.path.join(work, "comment-dry.jsonl"), mig,
                           "supabase db push --dry-run # the list Dan is shown\n", proj)
RELEASED = ("db-write-ask.sh lets this through: Dan answered Apply for migration 002_note.sql on project "
            "exampleprojectref000 in this session, and the file is unchanged since (claude-config#2763)")
rows += [
    ("ask", "(control) a delete in plain sight is asked about, in the words it always was",
     WRITES[0][1], work, None, None, "@delete"),
    ("ask", "(control) an update in plain sight is asked about, in the words it always was",
     WRITES[1][1], work, None, None, "@update"),
    ("ask", "(control) a drop in plain sight is asked about, in the words it always was",
     WRITES[2][1], work, None, None, "@drop"),
    ("ask", "(control) a push with no Apply on record is asked about, in the words it always was",
     PUSH, proj, NONE_T, None, "@push"),
    ("ask", "(control) a delete with a comment after it is asked about, in the words it always was",
     WRITES[0][1] + " # c\n", work, None, None, "@delete"),
    ("ask", "(control) a delete after a read, in plain sight, is asked about, in the words it always was",
     R + "; " + WRITES[0][1] + "\n", work, None, None, "@delete"),
    ("none", "(control) a read is not asked about", R, work, None, None, None),
    ("none", "(control) a read with a comment after a space, which every shell leaves out, is not asked about",
     R + " # the runs of last night\n", work, None, None, None),
    ("none", "(control) a read under a line that is all comment is not asked about",
     "# the runs of last night\n" + R + "\n", work, None, None, None),
    ("none", "(control) a read with a comment after it whose text holds a ; and a write is not asked about",
     R + " # c; " + WRITES[0][1] + "\n", work, None, None, None),
    ("none", "(control) a read after a cd to a folder with a # inside its name is not asked about",
     "cd /tmp/a#b && " + R + "\n", work, None, None, None),
    ("none", "(control) a read whose statement holds a # in a string is not asked about",
     "supabase db query --linked \"select id from runs where note = 'a # b'\"\n", work, None, None, None),
    ("none", "(control) a dry run with a comment after it is not asked about",
     "supabase db push --linked --dry-run # what would go\n", proj, NONE_T, None, None),
    ("none", "(control) a command that names no database client is not asked about, whatever its #",
     "printf a(b)# c; ls\n", work, None, None, None),
    ("allow", "(control) a push Dan applied is let through, in the words it always was",
     PUSH, proj, GOOD_T, None, RELEASED),
    ("allow", "(control) a push Dan applied that ends in a line break is let through",
     PUSH + "\n", proj, GOOD_T, None, RELEASED),
    ("allow", "(control) a push Dan applied with a comment after it is let through",
     PUSH + " # the migration Dan applied\n", proj, GOOD_T, None, RELEASED),
    ("allow", "(control) a push Dan applied under a line that is all comment is let through",
     "# the migration Dan applied\n" + PUSH + "\n", proj, GOOD_T, None, RELEASED),
    ("allow", "(control) a push Dan applied after a cd to its project is let through",
     "cd " + proj + " && " + PUSH + "\n", elsewhere, GOOD_T, None, RELEASED),
    ("allow", "(control) a push whose dry run had a comment after it is let through",
     PUSH, proj, COMMENT_DRY_T, None, RELEASED),
    ("allow", "(control) a write from the file Dan applied is let through", WRITE_Q, proj, CHANGE_T, None, None),
    ("allow", "(control) a write from the file Dan applied with a comment after it is let through",
     WRITE_Q + " # the change Dan applied\n", proj, CHANGE_T, None, None),
]

# ---- 4. a commit of an unapproved line onto a test project list ----------------------------------


def git(repo, *args):
    subprocess.run(["git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@example.invalid",
                    "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + list(args),
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env)


def new_repo(name, line=None):
    """A checkout of its own, one commit; with line, that project ref staged onto its test list."""
    repo = os.path.join(work, name)
    os.makedirs(os.path.join(repo, ".claude"))
    write(os.path.join(repo, "notes.txt"), "notes\n")
    git(repo, "init", "-q", "-b", "main")
    git(repo, "add", "notes.txt")
    git(repo, "commit", "-q", "-m", "base")
    if line is not None:
        write(os.path.join(repo, ".claude", "supabase-test-projects"), line + "\n")
        git(repo, "add", "-f", ".claude/supabase-test-projects")
    return repo


listed, clean = new_repo("listed", "unapprovedref00001"), new_repo("clean")
COMMIT = "git commit -q -m list"
for shape, before in READ_ON:
    rows.append(("ask", "a commit of an unapproved list line on the line of a # after %s is asked about" % shape,
                 "printf done" + before + "# c; " + COMMIT + "\n", listed, NONE_T, "unapprovedref00001", None))
rows += [
    ("ask", "a commit of an unapproved list line on the line of a # after two lines joined mid word is asked about",
     "printf do\\\nne\\\n# c; " + COMMIT + "\n", listed, NONE_T, "unapprovedref00001", None),
    ("ask", "a commit on the line of a # after a word that ends in a parenthesis is asked about",
     "printf a(b)# c; " + COMMIT + "\n", listed, NONE_T, UNSURE, None),
    ("ask", "a commit on the line of a # after a cd to a folder that ends in a parenthesis is asked about",
     "cd /tmp/a(b)# c; " + COMMIT + "\nprintf done\n", listed, NONE_T, UNSURE, None),
    ("ask", "a commit on a # line after an unsure comment that ends in a backslash is asked about",
     "printf a(b)# c\\\n# d; " + COMMIT + "\n", listed, NONE_T, UNSURE, None),
    ("ask", "(control) a commit of an unapproved list line in plain sight is asked about",
     COMMIT, listed, NONE_T, "would commit the line unapprovedref00001", None),
    ("ask", "(control) the same commit with a comment after it is asked about",
     COMMIT + " # c\n", listed, NONE_T, "would commit the line unapprovedref00001", None),
    ("none", "(control) a commit in a checkout with no list is not asked about", COMMIT, clean, NONE_T, None, None),
    ("none", "(control) a commit whose message holds a # is not asked about",
     'git commit -q -m "Count the runs (#12)"', clean, NONE_T, None, None),
    ("none", "(control) a commit with a comment after it is not asked about",
     COMMIT + " # c\n", clean, NONE_T, None, None),
    ("none", "(control) a commit on the line of a # after an escaped space, in a checkout with no list, is not asked about",
     "printf done\\ # c; " + COMMIT + "\n", clean, NONE_T, None, None),
]

# The whole reason of each ordinary question, as the unchanged hook gave it.
NOT_READ = " is not provably read only (it does not start with select, with, explain or show). Statement: "
EXACT = {
    "@delete": "db-write-ask.sh asks before this database call: supabase db query" + NOT_READ
               + "delete from runs (claude-config#2536)",
    "@update": "db-write-ask.sh asks before this database call: psql" + NOT_READ
               + "update runs set note = 1 (claude-config#2536)",
    "@drop": "db-write-ask.sh asks before this database call: supabase db query" + NOT_READ
             + "drop table runs (claude-config#2536)",
    "@push": "db-write-ask.sh asks before this database call: supabase db push applies the pending migrations "
             "to the database, and no /db-apply Apply covers it: Dan has answered no /db-apply Apply in this "
             "session (claude-config#2536, claude-config#2763)",
}
for want, label, command, cwd, t, holds, exact in rows:
    got, reason = decided(command, cwd, t)
    exact = EXACT.get(exact, exact)
    if got != want + " rc=0":
        verdict = "wanted %s rc=0, got %s: %s" % (want, got, reason[:400])
    elif holds is not None and holds not in reason:
        verdict = "the reason does not hold [%s]: %s" % (holds, reason[:400])
    elif exact is not None and reason != exact:
        verdict = "the reason is not the one it always was: %s" % reason[:600]
    else:
        verdict = "ok"
    print("%s\t%s" % (verdict, label))

# ---- 5. the library's own answers ----------------------------------------------------------------


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(os.path.dirname(hook), "lib", file))
    lib = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(lib)
    return lib


ro, calls, sw = load("ro", "sql-read-only.py"), load("calls", "db-write-calls.py"), load("sw", "shell-words.py")
reads_as = sw.commands
unsure_one = getattr(calls, "is_second_reading", lambda f: False)
facts = []


def fact(label, ok, got):
    facts.append((label, ok, got))


def findings(command, cwd=work, reader=sw):
    try:
        return calls.bash_findings(command, ro.judge, reader, cwd)
    except Exception as e:
        return "raised " + type(e).__name__


W = WRITES[0][1]
plain_delete = findings(W)
got = findings(R + " -o json\\ # c; " + W + "\n")
fact("a delete the shell runs on the line of a # is among the findings", isinstance(got, list) and any(
    f[1] == plain_delete[0][1] for f in got) and not any(unsure_one(f) for f in got), got)
got = findings(R + " -o a(b)# c; " + W + "\n")
fact("a # that cannot be told from a comment is a finding of its own, the first", isinstance(got, list) and bool(got)
     and unsure_one(got[0]) and UNSURE in got[0][0], got)
got = findings(PUSH, proj)
fact("(control) a push that is the whole of its command is one an Apply can cover",
     isinstance(got, list) and len(got) == 1 and calls.is_applicable(got[0]), got)
got = findings(PUSH + " # the migration Dan applied\n", proj)
fact("(control) a push with a comment after it is one an Apply can cover",
     isinstance(got, list) and len(got) == 1 and calls.is_applicable(got[0]), got)
got = findings(PUSH + " x\\ # c; rm -rf supabase/migrations\n", proj)
fact("a push with a line riding along is not one an Apply can cover",
     isinstance(got, list) and bool(got) and not any(calls.is_applicable(f) for f in got), got)
got = findings(PUSH + " a(b)# c; rm -rf supabase/migrations\n", proj)
fact("a push beside a # that cannot be told is not one an Apply can cover",
     isinstance(got, list) and bool(got) and not any(calls.is_applicable(f) for f in got), got)
fact("(control) a read with a comment after it has no finding", findings(R + " # c\n") == [], findings(R + " # c\n"))
fact("the reader it was handed reads as it did afterwards", sw.commands is reads_as, sw.commands)
# A reader with no `unsure` to ask for: what holds a # cannot be vouched for, what holds none is read
# as it always was.
older = types.SimpleNamespace(**{k: getattr(sw, k) for k in dir(sw) if not k.startswith("__")})
older.commands = lambda s, cwd="", heredocs=None, parts=None, spans=None, comments=None: reads_as(
    s, cwd, heredocs=heredocs, parts=parts, spans=spans, comments=comments)
got = findings(R + " # c\n", work, older)
fact("a reader that cannot be asked gives a read with a # a finding saying so",
     isinstance(got, list) and len(got) == 1 and unsure_one(got[0]) and "unsure" in got[0][0], got)
fact("(control) a reader that cannot be asked still reads a read with no # as a read", findings(R, work, older) == [], findings(R, work, older))
got = findings(W, work, older)
fact("(control) a reader that cannot be asked still finds a delete with no #", got == plain_delete, got)


def dry_dir(command, cwd):
    try:
        return calls.dry_push_dir(command, sw, cwd)
    except Exception as e:
        return "raised " + type(e).__name__


fact("(control) a dry run names the folder it previews", dry_dir("supabase db push --dry-run", proj) == proj, dry_dir("supabase db push --dry-run", proj))
fact("(control) a dry run with a comment after it names the folder it previews",
     dry_dir("supabase db push --dry-run # c\n", proj) == proj, dry_dir("supabase db push --dry-run # c\n", proj))
got = dry_dir("supabase db push --dry-run --workdir " + proj + "\\\n# c; printf done\n", elsewhere)
fact("a dry run with a line joined mid word and a # previews no folder", got is None, got)
got = dry_dir("cd /tmp/a(b)# c; printf done\nsupabase db push --dry-run --workdir " + proj + "\n", elsewhere)
fact("a dry run beside a # that cannot be told is reported as unread, never as a dry run", got == "raised UnsureLine", got)
fact("the reader reads as it did after the dry run readings", sw.commands is reads_as, sw.commands)

for label, ok, got in facts:
    print("%s\t%s" % ("ok" if ok else "got %s" % (str(got)[:400],), label))
print("ran\t%d" % (len(rows) + len(facts)))
PY
rows="$(python3 -B "$WORK/cases.py" "$HOOK" "$WORK" 2>&1)"
ran=""
while IFS=$'\t' read -r verdict label; do
  if [ "$verdict" = "ran" ]; then ran="$label"; continue; fi
  if [ -n "$label" ]; then check "#3472 $label" "$verdict"; elif [ -n "$verdict" ]; then check "#3472 the cases program said something that is not a case" "${verdict:0:300}"; fi
done <<< "$rows"
# A program that stopped early checks nothing and would read as a pass (L288).
WANT_RAN=166
[ "$ran" = "$WANT_RAN" ] && check "#3472 all $WANT_RAN cases ran" ok || check "#3472 all $WANT_RAN cases ran" "ran: ${ran:-none}; ${rows: -300}"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
