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
# any other, nothing is let through unless both readings find the same one run, and what the hook
# did with an ordinary command it still does.
#
# A line the reader names is refused, as a command the hook could not check, in a sentence true of
# the mark it was named with (section 6). The reader names more than a #: a heredoc it cannot find
# the end of, which holds none. The hook asked the reader only about a command holding a #, so a
# write or a commit the shell runs out of such a heredoc was not asked about, each kind reproduced
# here against the unchanged hook, and where it did ask it said of every mark that the command
# held a # the reader could not tell from a comment.
#
# A refusal is printed whatever state the notice library is in beside the hook (section 7): beside
# one that loaded and had no builder for a refusal, the hook printed nothing and left with 0, which
# passes the command. The hook's other broken states still ask, on that same command.
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
import datetime, hashlib, importlib.util, json, os, shutil, subprocess, sys, types

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


def decided(command, cwd, transcript=None, by=None):
    d = {"session_id": "s1", "hook_event_name": "PreToolUse", "cwd": cwd, "tool_name": "Bash",
         "tool_input": {"command": command, "description": "d"}}
    if transcript is not None:
        d["transcript_path"] = transcript
    p = subprocess.run(["bash", by or hook], input=json.dumps(d).encode(), stdout=subprocess.PIPE,
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
    # Where the reader cannot tell which the shell does, and names the line: refused, as a command
    # the hook could not check (the choice made for the issue's second open question).
    rows += [
        ("deny", "%s on the line of a # after a word that ends in a parenthesis is refused" % what,
         R + " -o a(b)# c; " + hidden + "\n", work, None, UNSURE, None),
        ("deny", "%s on the line of a # after a cd to a folder that ends in a parenthesis is refused" % what,
         "cd /tmp/a(b)# c; " + hidden + "\n" + R + "\n", work, None, UNSURE, None),
        ("deny", "%s on the line of a # after a cd and a stray ) is refused" % what,
         "cd /tmp/x)# c; " + hidden + "\n" + R + "\n", work, None, UNSURE, None),
        ("deny", "%s on a # line after an unsure comment that ends in a backslash is refused" % what,
         R + " -o a(b)# c\\\n# d; " + hidden + "\n", work, None, UNSURE, None),
    ]
# The line in front need not name a database at all.
rows += [
    ("ask", "a delete on the line of a # after an escaped space in a command that reads no database is asked about",
     "printf done\\ # c; " + WRITES[0][1] + "\n", work, None, WRITES[0][2], None),
    ("deny", "a delete on the line of a # after a word ending in a parenthesis in a command that reads no database is refused",
     "printf a(b)# c; " + WRITES[0][1] + "\n", work, None, UNSURE, None),
    ("deny", "the refusal of a # that cannot be told names this issue",
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
        ("deny", "an applied push with %s on the line of a # after a word that ends in a parenthesis is refused, not let through" % what,
         PUSH + " a(b)# c; " + hidden + "\n", proj, GOOD_T, UNSURE, None),
        ("deny", "an applied push after a cd to a folder that ends in a parenthesis, a # and %s is refused, not let through" % what,
         "cd /tmp/a(b)# c; " + hidden + "\n" + PUSH + " --workdir " + proj + "\n", elsewhere, GOOD_T, UNSURE, None),
        ("deny", "an applied push after a cd, a stray ), a # and %s is refused, not let through" % what,
         "cd /tmp/x)# c; " + hidden + "\n" + PUSH + " --workdir " + proj + "\n", elsewhere, GOOD_T, UNSURE, None),
        ("deny", "an applied push with %s on a # line after an unsure comment that ends in a backslash is refused, not let through" % what,
         PUSH + " a(b)# c\\\n# d; " + hidden + "\n", proj, GOOD_T, UNSURE, None),
        # The write from a file Dan applied, the skill's other run.
        ("ask", "an applied write from a file with %s on the line of a # after a line joined mid word is asked about, not let through" % what,
         WRITE_Q + "\\\n# c; " + hidden + "\n", proj, CHANGE_T, None, None),
        ("deny", "an applied write from a file after a cd to a folder that ends in a parenthesis, a # and %s is refused, not let through" % what,
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
    ("deny", "a commit on the line of a # after a word that ends in a parenthesis is refused",
     "printf a(b)# c; " + COMMIT + "\n", listed, NONE_T, UNSURE, None),
    ("deny", "a commit on the line of a # after a cd to a folder that ends in a parenthesis is refused",
     "cd /tmp/a(b)# c; " + COMMIT + "\nprintf done\n", listed, NONE_T, UNSURE, None),
    ("deny", "a commit on a # line after an unsure comment that ends in a backslash is refused",
     "printf a(b)# c\\\n# d; " + COMMIT + "\n", listed, NONE_T, UNSURE, None),
    # A commit in plain sight beside such a line is refused too: his answer to the question about
    # the commit would have let whatever the line hides run with it.
    ("deny", "a commit of an unapproved list line in plain sight beside a # that cannot be told is refused",
     COMMIT + "\nprintf a(b)# c; printf done\n", listed, NONE_T, UNSURE, None),
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

# ---- 6. every mark the reader names is refused, in a sentence true of that mark -------------------
# The reader names more than a #: a heredoc it cannot find the end of, which needs no # at all
# (claude-config#3492, #3566). The hook asked the reader only about a command holding a #, so a
# write behind any of these heredocs was not asked about (each reproduced against the unchanged
# hook), and where it did ask it gave the # sentence for every mark, which is untrue of a heredoc.
# What each mark's refusal says that no other mark's does:
SAYS = {
    "comment": "holds a # the shared reader cannot tell from a comment",
    "unread": "past which the shared reader could not read the text to its end",
    "close": "opens a heredoc the shared reader cannot find the end of",
    "joined": "on a line that ends in a backslash before the heredoc's end marker is whole",
    "split": "whose end marker is quoted and holds a line break",
    "dollar": "whose end marker holds a dollar quote",
    "one line": "opens a heredoc in a text with no line break",
}
# How each says to write the command so that it can be read.
HOW = {
    "comment": "Write that # inside quotes, or put the comment on a line of its own",
    "unread": "Write that # inside quotes, or put the comment on a line of its own",
    "close": "End the heredoc with its marker alone on a line that follows no backslash",
    "joined": "Write the << and its whole end marker on one line",
    "split": "Write the end marker as one word on the line that opens the heredoc",
    "dollar": "Write the end marker as a plain word",
    "one line": "Put the heredoc's body and its end marker on lines of their own",
}


def behind(hidden):
    """(the mark, the shape, a command) for every mark the reader names: in each, some shell runs
    hidden, and the reader's own reading shows no such command."""
    quoted = "echo '$(" + hidden + ")'"
    return (
        ("comment", "a # after a word that ends in a parenthesis", "printf a(b)# c; " + hidden + "\n"),
        # Every shell joins `x\` to the marker's line, keeps the heredoc open and runs the $( ).
        ("close", "a heredoc whose marker stands right after a body line that ends in a backslash",
         "cat <<E\nx\\\nE\n" + quoted + "\nE\n"),
        ("close", "a heredoc that no line ends, with a $( ) after it", "cat <<E\nx\n" + quoted + "\n"),
        # The marker is EOF, so the E line ends nothing and the $( ) is in the body.
        ("joined", "a heredoc whose opener line ends in a backslash", "cat <<E\\\nOF\nx\nE\n" + quoted + "\nEOF\n"),
        # bash and zsh never end it, so sh is fed every line: the quote its first line opens is
        # closed by the one that, to the reader, opens a string around the hidden command.
        ("split", "a heredoc whose quoted marker holds a line break", "sh <<'E\nF'\n: '\nE\nF\n' ; " + hidden + "\n: '\n"),
        # dash ends it at the line $E, and runs the next.
        ("dollar", "a heredoc whose marker holds a dollar quote", "cat <<$'E'\nx\n$E\n" + hidden + "\nE\n"),
        ("one line", "a heredoc typed on one line", "cat <<E; " + hidden + "; E"),
    )


marked = []
for what, hidden, cwd, t in (("a delete", WRITES[0][1], work, None),
                             ("a commit of an unapproved list line", COMMIT, listed, NONE_T)):
    for kind, shape, command in behind(hidden):
        marked.append(("%s behind %s is refused, in the words for that mark" % (what, shape), kind, command, cwd, t))
marked += [
    ("an applied push with a folder removal behind a heredoc the reader cannot find the end of is refused, not let through",
     "close", PUSH + "\n" + behind("rm -rf supabase/migrations")[1][2], proj, GOOD_T),
    # The unchanged hook asked about this one, since it holds a #, and said the # was the trouble.
    ("a delete behind a heredoc the reader cannot find the end of, under a line that is all comment, is refused in the heredoc's words",
     "close", "# the runs of last night\n" + behind(WRITES[0][1])[1][2], work, None),
    # Every shell reads this # inside its word, so the reader reads on past it, and the quote that
    # opens after it never closes. The reader can tell this # from a comment, so the refusal does
    # not say it cannot.
    ("a read with a # the reader reads on past and then cannot read to the end is refused, in the words for that",
     "unread", R + " -o json\\ # it's a note\n", work, None),
]
# What the hook did with an ordinary heredoc it still does.
PLAIN_DOC = "cat <<'EOF' >/dev/null\nnote\nEOF\n"
rows += [
    ("none", "(control) a read after an ordinary heredoc is not asked about", PLAIN_DOC + R + "\n", work, None, None, None),
    ("none", "(control) a read after a heredoc whose body holds a backslash line and a substitution is not asked about",
     "cat <<EOF >/dev/null\na \\\nb $(date)\nEOF\n" + R + "\n", work, None, None, None),
    ("ask", "(control) a delete in plain sight after an ordinary heredoc is asked about",
     PLAIN_DOC + WRITES[0][1] + "\n", work, None, WRITES[0][2], None),
    ("none", "(control) a commit whose message is an ordinary heredoc, in a checkout with no list, is not asked about",
     "git commit -q -F - <<'EOF'\nlist\nEOF\n", clean, NONE_T, None, None),
    ("ask", "(control) a commit of an unapproved list line whose message is an ordinary heredoc is asked about",
     "git commit -q -F - <<'EOF'\nlist\nEOF\n", listed, NONE_T, "unapprovedref00001", None),
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


def of_another(kind, text):
    """What text says that is true of a mark other than kind."""
    return [SAYS[k] for k in SAYS if k != kind and SAYS[k] in text]


for label, kind, command, cwd, t in marked:
    got, reason = decided(command, cwd, t)
    if got != "deny rc=0":
        verdict = "wanted deny rc=0, got %s: %s" % (got, reason[:400])
    elif SAYS[kind] not in reason:
        verdict = "the refusal does not say [%s]: %s" % (SAYS[kind], reason[:500])
    elif of_another(kind, reason):
        verdict = "the refusal says what is true of another mark %s: %s" % (of_another(kind, reason), reason[:500])
    elif HOW[kind] not in reason:
        verdict = "the refusal does not say how to write it [%s]: %s" % (HOW[kind], reason[:700])
    elif "could not check" not in reason or "claude-config#3472" not in reason:
        verdict = "the refusal does not say it could not check, or names no issue: %s" % reason[:500]
    else:
        verdict = "ok"
    print("%s\t%s" % (verdict, label))

# A copy of the hook with no lib/hook-notice.sh beside it still refuses, in the characters that
# need no escaping, and says the library is missing.
bare = os.path.join(work, "bare")
os.makedirs(bare)
shutil.copy(hook, bare)
shutil.copytree(os.path.join(os.path.dirname(hook), "lib"), os.path.join(bare, "lib"),
                ignore=lambda folder, names: [n for n in names if n in ("hook-notice.sh", "__pycache__")])
got, reason = decided(behind(WRITES[0][1])[1][2], work, None, os.path.join(bare, os.path.basename(hook)))
print("%s\t%s" % ("ok" if got == "deny rc=0" and SAYS["close"] in reason and "lib/hook-notice.sh is missing" in reason
                  else "got %s: %s" % (got, reason[:400]),
                  "a hook with no lib/hook-notice.sh beside it still refuses a heredoc the reader cannot find the end of"))

# ---- 7. a refusal the notice library cannot build is still a refusal ------------------------------
# The hook builds a refusal with the notice library's private decision builder, _hn_decision_json.
# Beside a library that loads and has no such function (a copy from before 2026-11-16 that the sync
# held back, or one in which that private name changed), the hook printed nothing and left with 0,
# so the command ran with no decision at all, where the hook before #3472 asked about it. Each
# stand in here is a copy of the real library, changed in this suite's own folder and put beside a
# copy of the hook; the real library is never touched.
LIB = os.path.join(os.path.dirname(hook), "lib")
with open(os.path.join(LIB, "hook-notice.sh")) as f:
    NOTICE = f.read()
GONE = object()
# The library as it would be with the private builder under another name: it loads, and its ask
# and its allow are built as before.
RENAMED = NOTICE.replace("_hn_decision_json", "_hn_decision_built")
# The builder is there and prints nothing.
SILENT = NOTICE + "\n_hn_decision_json() { return 0; }\n"
# The builder is there and prints a refusal cut short, which no JSON reader takes.
CUT = (NOTICE + "\n_hn_decision_json() { printf '%s' '{\"hookSpecificOutput\": {\"hookEventName\": \"PreToolUse\", "
       "\"permissionDecision\": \"deny\", \"permissionDecisionReason\": \"cut sh'; }\n")
# The builder is there and prints a whole object that is no refusal.
ASKS = (NOTICE + "\n_hn_decision_json() { printf '%s\\n' '{\"hookSpecificOutput\": {\"hookEventName\": \"PreToolUse\", "
        "\"permissionDecision\": \"ask\", \"permissionDecisionReason\": \"r\"}}'; }\n")
# A copy of lib/db-write-calls.py whose advice on rewriting holds what JSON must escape: both
# quotes, a backslash, a tab and a line break.
ODD = 'Write "it" as \'a\\b\' \tso,\non two lines'
ODD_TAIL = "\n\ndef unsure_fix(told):\n    return %r if isinstance(told, (Unsure, UnsureFinding)) else None\n" % ODD
NO_BUILDER = "lib/hook-notice.sh beside this hook has no _hn_decision_json"
NO_REFUSAL = "_hn_decision_json in lib/hook-notice.sh beside this hook printed no refusal"


def beside(name, notice=None, calls_tail=None, broken=()):
    """A copy of the hook in a folder of its own, beside a copy of lib/ in which hook-notice.sh
    holds the text notice (GONE: the file is left out), lib/db-write-calls.py ends in calls_tail,
    and each file of broken is one python3 cannot load."""
    folder = os.path.join(work, name)
    os.makedirs(folder)
    shutil.copy(hook, folder)
    shutil.copytree(LIB, os.path.join(folder, "lib"), ignore=shutil.ignore_patterns("__pycache__"))
    if notice is GONE:
        os.remove(os.path.join(folder, "lib", "hook-notice.sh"))
    elif notice is not None:
        write(os.path.join(folder, "lib", "hook-notice.sh"), notice)
    if calls_tail is not None:
        with open(os.path.join(folder, "lib", "db-write-calls.py"), "a") as f:
            f.write(calls_tail)
    for file in broken:
        write(os.path.join(folder, "lib", file), "def (\n")
    return os.path.join(folder, os.path.basename(hook))


def loaded(by, name):
    """0 when the notice library beside the hook by loads and then has a function called name,
    1 when it loads and has none, 3 when it does not load."""
    return subprocess.run(["bash", "-c", '. "$1" 2>/dev/null || exit 3; declare -F "$2" >/dev/null', "-",
                           os.path.join(os.path.dirname(by), "lib", "hook-notice.sh"), name], env=env).returncode


def shown(by, command, cwd, t=None, home_dir=None, sent=None):
    """(what the hook by left with, the reason it gave, the notice beside it, all it printed), for
    command, or for the bytes sent when the payload is to be one that is no JSON."""
    d = {"session_id": "s1", "hook_event_name": "PreToolUse", "cwd": cwd, "tool_name": "Bash",
         "tool_input": {"command": command, "description": "d"}}
    if t is not None:
        d["transcript_path"] = t
    p = subprocess.run(["bash", by], input=json.dumps(d).encode() if sent is None else sent, stdout=subprocess.PIPE,
                       stderr=subprocess.DEVNULL, env=env if home_dir is None else dict(env, HOME=home_dir), cwd=work)
    out = p.stdout.decode("utf-8", "replace")
    if not out.strip():
        return "none rc=%d" % p.returncode, "", "", out
    try:
        whole = json.loads(out)
        h = whole.get("hookSpecificOutput") or {}
    except (ValueError, AttributeError):
        return "badjson rc=%d" % p.returncode, "", "", out
    return ("%s rc=%d" % (h.get("permissionDecision", "none"), p.returncode), h.get("permissionDecisionReason", ""),
            whole.get("systemMessage", ""), out)


stood = []


def refused(label, by, command, cwd, t, holds, lacks=(), home_dir=None, notice=(), bare=False):
    """One case: the hook by refuses command, in one JSON object that holds every text of holds in
    its reason and none of lacks, and every text of notice in the notice beside it. With bare, the
    object holds no notice beside the refusal at all."""
    got, reason, message, out = shown(by, command, cwd, t, home_dir)
    if got != "deny rc=0":
        verdict = "wanted deny rc=0, got %s: %s" % (got, (reason or out)[:400])
    elif [w for w in holds if w not in reason]:
        verdict = "the refusal does not say %s: %s" % ([w for w in holds if w not in reason], reason[:700])
    elif [w for w in lacks if w in reason]:
        verdict = "the refusal holds %s: %s" % ([w for w in lacks if w in reason], reason[:700])
    elif [w for w in notice if w not in message]:
        verdict = "the notice beside the refusal does not say %s: %s" % ([w for w in notice if w not in message], message[:500])
    elif bare and "systemMessage" in out:
        verdict = "the refusal written without the library builds a notice beside it by hand: %s" % out[-500:]
    else:
        verdict = "ok"
    stood.append((verdict, label))


def asked(label, by, command, cwd, t, holds, sent=None):
    """One case: the hook by asks, and its question holds every text of holds."""
    got, reason, _, out = shown(by, command, cwd, t, sent=sent)
    if got != "ask rc=0":
        verdict = "wanted ask rc=0, got %s: %s" % (got, (reason or out)[:400])
    elif [w for w in holds if w not in reason]:
        verdict = "the question does not say %s: %s" % ([w for w in holds if w not in reason], reason[:700])
    else:
        verdict = "ok"
    stood.append((verdict, label))


CLOSE = behind(WRITES[0][1])[1][2]
SAID = (SAYS["close"], HOW["close"], "could not check", "claude-config#3472")
renamed, silent = beside("renamed", RENAMED), beside("silent", SILENT)
got = (loaded(renamed, "hook_ask_json"), loaded(renamed, "_hn_decision_json"))
stood.append(("ok" if got == (0, 1) else "got %s" % (got,),
              "(control) the stand in library with its builder renamed loads, names an ask and has no _hn_decision_json"))
got = (loaded(silent, "hook_ask_json"), loaded(silent, "_hn_decision_json"))
stood.append(("ok" if got == (0, 0) else "got %s" % (got,),
              "(control) the stand in library whose builder prints nothing loads and has a _hn_decision_json"))
asked("(control) beside a notice library with no _hn_decision_json, a delete in plain sight is asked about as it always was",
      renamed, WRITES[0][1], work, None, (WRITES[0][2],))
refused("beside a notice library with no _hn_decision_json, a delete behind a heredoc the reader cannot find the end of is "
        "refused, never passed in silence", renamed, CLOSE, work, None, SAID + (NO_BUILDER,),
        ("lib/hook-notice.sh is missing", NO_REFUSAL))
refused("beside a notice library with no _hn_decision_json, a commit of an unapproved list line behind a # that cannot be "
        "told is refused, never passed in silence", renamed, "printf a(b)# c; " + COMMIT + "\n", listed, NONE_T,
        (UNSURE, "could not check", NO_BUILDER))
refused("beside a notice library whose _hn_decision_json prints nothing, the same delete is refused, never passed in silence",
        silent, CLOSE, work, None, SAID + (NO_REFUSAL,), ("lib/hook-notice.sh is missing", NO_BUILDER))
refused("beside a notice library whose _hn_decision_json prints a refusal cut short, the same delete is refused in an "
        "object that can be read", beside("cut", CUT), CLOSE, work, None, SAID + (NO_REFUSAL,))
refused("beside a notice library whose _hn_decision_json prints an ask where a refusal was meant, the same delete is "
        "refused", beside("asks", ASKS), CLOSE, work, None, SAID + (NO_REFUSAL,))
# A refusal whose words hold what JSON must escape. Beside the real library every character of
# them arrives (which is also what shows the stand in advice reaches the refusal); in the form
# built without it they are taken out, and the object is still one a JSON reader takes.
refused("(control) beside the real notice library, a refusal whose advice holds quotes, a backslash, a tab and a line "
        "break arrives whole", beside("odd", calls_tail=ODD_TAIL), CLOSE, work, None, (SAYS["close"], ODD))
for name, text, why in (("odd-renamed", RENAMED, NO_BUILDER), ("odd-gone", GONE, "lib/hook-notice.sh is missing")):
    refused("with the notice library %s, a refusal whose advice holds quotes, a backslash, a tab and a line break is "
            "still one JSON object, with those characters taken out"
            % ("left out" if text is GONE else "holding no _hn_decision_json"),
            beside(name, text, ODD_TAIL), CLOSE, work, None,
            (SAYS["close"], "Write it as ab so,on two lines", why), ('"', "'", "\\", "\t", "\n"))
# The notice a question carries beside it is carried by a refusal too. Beside the real library it
# is the library's own notice beside the refusal. A refusal written without the library says it
# inside its reason and builds no notice of its own: a notice is built only by the library
# (claude-config#1906, whose scan in test-hook-notice.sh failed on one built here).
sf_home = os.path.join(work, "sf-home")
os.makedirs(os.path.join(sf_home, ".claude"))
write(os.path.join(sf_home, ".claude", "settings.local.json"),
      json.dumps({"permissions": {"allow": ["mcp__claude_ai_SFDC_USE__createSobjectRecord"]}}))
SF_SAID = ("SALESFORCE WRITES SKIP AUTO MODE", "mcp__claude_ai_SFDC_USE__createSobjectRecord")
refused("(control) beside the real notice library, a refusal carries the notice about pre-allowed Salesforce writes "
        "beside it", hook, CLOSE, work, None, SAID, home_dir=sf_home, notice=SF_SAID)
for by, state, why in ((renamed, "with no _hn_decision_json", NO_BUILDER),
                       (beside("gone", GONE), "left out", "lib/hook-notice.sh is missing")):
    refused("beside a notice library %s, a refusal says the notice about pre-allowed Salesforce writes inside its "
            "reason, and builds no notice beside it by hand" % state, by, CLOSE, work, None,
            SAID + SF_SAID + (why,), home_dir=sf_home, bare=True)
# The hook's other broken states, on that same command: each asks, as it did before #3472 and
# after it, since no rewriting of the command mends any of them. None passes it in silence.
asked("with lib/db-write-calls.py one python3 cannot load, a delete behind a heredoc the reader cannot find the end of "
      "is asked about, naming the file", beside("no-calls", broken=("db-write-calls.py",)), CLOSE, work, None,
      ("lib/db-write-calls.py could not be loaded beside the hook",))
asked("with lib/shell-words.py one python3 cannot load, the same delete is asked about, naming the file",
      beside("no-reader", broken=("shell-words.py",)), CLOSE, work, None,
      ("lib/shell-words.py could not be loaded beside the hook", "could not be read"))
NAMED_PAYLOAD = json.dumps({"session_id": "s1", "hook_event_name": "PreToolUse", "cwd": work, "tool_name": "Bash",
                            "tool_input": {"command": CLOSE, "description": "d"}})
asked("with its payload cut short, the same delete is asked about, as a payload that could not be read",
      hook, CLOSE, work, None, ("the hook payload could not be read as a tool call",),
      sent=NAMED_PAYLOAD[:NAMED_PAYLOAD.index("delete from runs") + len("delete from runs")].encode())
# The same payload whole, for the case with no python3, which the shell below runs.
write(os.path.join(work, "named-line-payload.json"), NAMED_PAYLOAD)
for verdict, label in stood:
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
# A reader with no `unsure` to ask for: nothing it reads can be vouched for, whether or not the
# command holds a #.
older = types.SimpleNamespace(**{k: getattr(sw, k) for k in dir(sw) if not k.startswith("__")})
older.commands = lambda s, cwd="", heredocs=None, parts=None, spans=None, comments=None: reads_as(
    s, cwd, heredocs=heredocs, parts=parts, spans=spans, comments=comments)
got = findings(R + " # c\n", work, older)
fact("a reader that cannot be asked gives a read with a # a finding saying so",
     isinstance(got, list) and len(got) == 1 and unsure_one(got[0]) and "unsure" in got[0][0], got)
# A heredoc the reader cannot find the end of needs no #, so a command holding none cannot be
# vouched for by such a reader either. It is asked about, never refused: no rewriting of the
# command would let that reader be asked.
unsure_fix = getattr(calls, "unsure_fix", lambda f: None)
got = findings(R, work, older)
fact("a reader that cannot be asked gives a read with no # a finding saying so too",
     isinstance(got, list) and len(got) == 1 and unsure_one(got[0]) and "unsure" in got[0][0]
     and unsure_fix(got[0]) is None, got)
got = findings(W, work, older)
fact("a reader that cannot be asked still finds a delete with no #, after the finding saying so",
     isinstance(got, list) and len(got) == 2 and unsure_one(got[0]) and unsure_fix(got[0]) is None
     and got[1:] == plain_delete, got)

# Every mark the reader names, as the library answers for it.
asked_reading = getattr(calls, "asked_reading", lambda reader, read: (None, None))
for kind, shape, command in behind(W):
    got = findings(command)
    fact("the first finding for a delete behind %s is that mark's, and says how to write it" % shape,
         isinstance(got, list) and bool(got) and unsure_one(got[0]) and SAYS[kind] in got[0][0]
         and not of_another(kind, got[0][0]) and HOW[kind] in (unsure_fix(got[0]) or "")
         and not any(calls.is_applicable(f) for f in got), got)
    got = asked_reading(sw, lambda: sw.commands(command))
    fact("the reading that asks says of %s what is true of it and of no other mark" % shape,
         got[0] is None and isinstance(got[1], str) and SAYS[kind] in got[1] and not of_another(kind, got[1])
         and HOW[kind] in (unsure_fix(got[1]) or ""), got)
got = calls.second_reading(behind(COMMIT)[1][2], sw, listed, None, lambda: "read again")
fact("a costly read is told of a heredoc the reader cannot find the end of in a command holding no #",
     got[0] is None and isinstance(got[1], str) and SAYS["close"] in got[1], got)
fact("the reader reads as it did after the readings of every mark", sw.commands is reads_as, sw.commands)


# A reader that names a line by a mark this library has no words for (neither a # nor a <<), in a
# command holding no #: the command is not vouched for, and is told nothing untrue about it.
def naming(s, cwd="", heredocs=None, parts=None, spans=None, comments=None, unsure=None, joined=None):
    if unsure is not None:
        unsure.append((0, len(s)))
    return reads_as(s, cwd, heredocs=heredocs, parts=parts, spans=spans, comments=comments, joined=joined)


# The reader's own functions read through its commands(), so the stand in is put in its place for
# these two readings and taken out again.
sw.commands = naming
try:
    got = findings(R, work)
    try:
        dry = calls.dry_push_dir("supabase db push --dry-run", sw, proj)
    except Exception as e:
        dry = "raised " + type(e).__name__
finally:
    sw.commands = reads_as
fact("a line named by a mark with no words of its own is a finding that claims neither a # nor a heredoc",
     isinstance(got, list) and len(got) == 1 and unsure_one(got[0]) and "is unsure of" in got[0][0]
     and not of_another("", got[0][0]) and bool(unsure_fix(got[0])), got)
fact("a dry run holding no # that the reader names a line of is reported as unread, never as a dry run",
     dry == "raised UnsureLine", dry)


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
print("ran\t%d" % (len(rows) + len(marked) + 1 + len(stood) + len(facts)))
PY
rows="$(python3 -B "$WORK/cases.py" "$HOOK" "$WORK" 2>&1)"
ran=""
while IFS=$'\t' read -r verdict label; do
  if [ "$verdict" = "ran" ]; then ran="$label"; continue; fi
  if [ -n "$label" ]; then check "#3472 $label" "$verdict"; elif [ -n "$verdict" ]; then check "#3472 the cases program said something that is not a case" "${verdict:0:300}"; fi
done <<< "$rows"
# A program that stopped early checks nothing and would read as a pass (L288).
WANT_RAN=225
[ "$ran" = "$WANT_RAN" ] && check "#3472 all $WANT_RAN cases ran" ok || check "#3472 all $WANT_RAN cases ran" "ran: ${ran:-none}; ${rows: -300}"

# With no python3 on PATH nothing can be read at all, so the same command, a delete behind a
# heredoc the reader cannot find the end of, is asked about and never passed in silence.
. "$DIR/lib/no-python-path.sh"
NOPY="$WORK/nopy/bin"
npp_build_bin "$NOPY"
if npp_reaches_python3 "$NOPY"; then
  check "#3472 the bare directory reaches no python3" "it found one, so nothing here measures its absence"
elif [ ! -s "$WORK/named-line-payload.json" ]; then
  check "#3472 with no python3, a delete behind a heredoc the reader cannot find the end of is asked about, naming python3" "the cases program left no payload to send"
else
  r="$(cd "$WORK" && env -u CLAUDE_HOME HOME="$WORK/home" PATH="$NOPY" "$NOPY/bash" "$HOOK" < "$WORK/named-line-payload.json" 2>/dev/null; printf '\nrc=%s' "$?")"
  case "$r" in
    *'"permissionDecision": "ask"'*"python3 is not on PATH"*$'\nrc=0') check "#3472 with no python3, a delete behind a heredoc the reader cannot find the end of is asked about, naming python3" ok ;;
    *) check "#3472 with no python3, a delete behind a heredoc the reader cannot find the end of is asked about, naming python3" "${r:0:400}" ;;
  esac
fi

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
