#!/usr/bin/env python3
"""Refuse the changelog/announce label on wording Dan has not approved (claude-config#3666).

A pull request labelled changelog/announce carries the post for agents, and Dan approves that exact
wording first (lib/announce-approval.py says how he is asked and what counts). The merge gate holds
that an announcement merges only on wording he approved. This is the early refusal: a session's
ordinary command to put the label on a pull request is refused until he has, so the label is never
sitting on wording nobody asked him about.

Judged here, each only when the command names the label:
  gh pr create --label, gh pr edit --add-label, gh issue edit --add-label (gh's issue edit answers
    for a pull request's number too)
      The wording the command would leave must be wording he approved for that repository: the
      Announcement block of its --body, or of the file its --body-file names, or, for an edit that
      gives neither, of the description GitHub holds now. A form the wording cannot be read from
      (--fill, a template, a body on standard input, a body file the same command writes, more
      than one pull request) is refused with the form to use. One approval covers one pull request
      (Dan, 2026-11-25): the pull request that used an approval keeps it, and any other, or a
      command naming none by number, goes through only while an approval of that wording is
      unused. This hook asks and records nothing; the merge gate records which one uses it.
  gh api writing to repos/<owner>/<name>/issues/<number>/labels
      The same, from the description GitHub holds. Any other gh api write naming the label is
      refused with the form to use, since nothing here can place it.
  gh label edit --name changelog/announce, and its gh api form
      Renaming another label onto it puts it on every pull request carrying that one, with no
      wording read for any, so it is always refused, with the form to use.
Taking the label off, reading it and naming it in text put it on nothing and pass. So does making
the label (gh label create, gh label clone, gh api writing to repos/<owner>/<name>/labels): it puts
it on no pull request, so there is no wording to read and nothing to approve, and the merge gate
still holds what merges (Dan, 2026-11-25: "Always allow it").

And the record of what he approved, whatever the command names:
  Edit, Write, MultiEdit, NotebookEdit of a file under the record's folder
  a Bash command naming that folder that is not one only reading it (lib/db-apply-approval.py's
    reading of "only reads", the one the record of approved test project lines is held by)
  a Bash command that runs lib/announce-approval.py, the library that writes the record, in any
    form but the two that only read: `list`, and `check` without --claim and with every value
    written out (claude-config#3703). Refused: `check --claim` and `used`, which are the merge
    gate's and write; a command or flag the shell fills in at run time; the file run through
    `python -m` or named in a program handed to `python -c`; and the file named in a heredoc
    body. A command that names the file and runs none of it (git, grep, a suite, a compile) passes.
    A review found the library's check command writing an approval from a made up transcript, and
    that command names neither the label nor the record's folder.

Every refusal is a deny. Commands are read by the shared gh reader (gh_issue_scan.py). No override.

What it cannot see: a label named through a variable, a file or a script, a gh alias, a label id in
a GraphQL call that does not spell the name. Those reach the merge gate, which reads the pull
request itself. And the library run by a program that is not python by name and is handed the file
(uv run, ipython, coverage run), or reached without its file being named in the command: a script
file that runs it, a path built at run time, a copy under another name, a hook run by hand. No list
of the programs that can run a python file is kept, because such a list is only ever short of one;
the hook judges python where it is named, and the library
holds its own line there (a picker counts only from a transcript kept where Claude Code keeps them),
and a session that forges one in that folder is not stopped by anything on the same Mac.
"""

import importlib.util
import json
import os
import re
import subprocess
import sys

sys.dont_write_bytecode = True
_HERE = os.environ.get("GATE_DIR") or os.path.dirname(os.path.abspath(__file__))


def _load(name, *parts):
    path = os.path.join(_HERE, *parts)
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise ImportError("cannot load %s" % path)
    lib = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(lib)
    return lib


scan = _load("gh_issue_scan", "gh_issue_scan.py")
approval = _load("announce_approval", "lib", "announce-approval.py")

LABEL = "changelog/announce"
HEAD = "ANNOUNCE LABEL"
# Where each command names the labels it puts on: the long flag and its one letter form.
PUTS = {("pr", "create"): ("--label", "-l"), ("pr", "edit"): ("--add-label", None), ("issue", "edit"): ("--add-label", None)}
RENAMES = {("label", "edit")}
KINDS = frozenset(PUTS) | RENAMES
# The flags of an edit, and of gh api, that take a value, so the value is not read as the pull
# request the command names or the endpoint it calls.
EDIT_VALUE_FLAGS = {"--add-assignee", "--add-label", "--add-project", "--add-reviewer", "--base", "-B", "--body", "-b",
                    "--body-file", "-F", "--milestone", "-m", "--remove-assignee", "--remove-label", "--remove-project",
                    "--remove-reviewer", "--repo", "-R", "--title", "-t"}
API_VALUE_FLAGS = {"-f", "-F", "--field", "--raw-field", "-H", "--header", "--input", "-X", "--method", "-q", "--jq",
                   "-t", "--template", "--hostname", "--cache", "-p", "--preview"}
# The forms of a create that take the description from somewhere this hook cannot read.
UNREAD_BODY_FLAGS = {"--fill", "-f", "--fill-first", "--fill-verbose", "--template", "-T", "--editor", "-e", "--recover"}
BODY_FLAGS = ("--body", "-b", "--body-file", "-F")
BODY_BYTES = 1024 * 1024
# Each bound is this hook's own. ONE command of a call is judged (_one_judgment refuses a second),
# so the most one run can wait is one read of the remote, one of GitHub, one hash (the library's 5)
# and the library's check (12): 37 seconds, inside the 45 the hook is registered with. So a slow
# GitHub is refused in words and never by the harness cutting the hook short. Without the limit of
# one, each further command in a call brought reads of its own and the sum had no ceiling.
GITHUB_SECONDS = 15
REMOTE_SECONDS = 5
# Seam, for the tests: a shorter bound on the read of GitHub, so no case waits on a clock (L524). It
# can only shorten the wait, and a read cut short is refused.
if (os.environ.get("ANNOUNCE_LABEL_GITHUB_SECONDS") or "").isdigit():
    GITHUB_SECONDS = max(1, min(GITHUB_SECONDS, int(os.environ["ANNOUNCE_LABEL_GITHUB_SECONDS"])))
EDIT_TOOLS = ("Edit", "Write", "MultiEdit", "NotebookEdit")
PULL_URL = re.compile(r"https://github\.com/([^/\s]+)/([^/\s]+)/(?:pull|issues)/(\d+)")
ISSUE_LABELS = re.compile(r"repos/([^/]+)/([^/]+)/issues/(\d+)/labels")
REPO_LABELS = re.compile(r"repos/([^/]+)/([^/]+)/labels")
# What a command that cannot be read is judged by. Making the label (gh label create, gh label
# clone) is not among them: it needs no approval, read or unread.
CRUDE_WRITE = re.compile(r"\bgh\b[^\n]*(?:--add-label|--label|\s-l\s|\bapi\b|\blabel\s+edit\b)")

USE_BODY_FILE = ("Give the description with --body-file <file>, a file written in a command of its own, so the "
                 "wording the label would sit on can be read: `gh pr create ... --body-file <file> --label " + LABEL
                 + "`, or for a pull request that exists `gh pr edit <number> --add-label " + LABEL + "`.")
USE_PR_EDIT = ("Put the label on one pull request with `gh pr edit <number> --add-label " + LABEL + "`, which reads "
               "the wording that pull request carries.")


class Refuse(Exception):
    """This command is refused; str() is why."""


def _labels(values):
    return {part.strip().lower() for v in values for part in v.split(",") if part.strip()}


def _positionals(args, value_flags):
    """The words of args that are neither a flag nor the value of one that takes a value."""
    out, skip = [], False
    for a in args:
        if skip:
            skip = False
        elif a in value_flags:
            skip = True
        elif not a.startswith("-") or a == "-":
            out.append(a)
    return out


def _run_dir(place, cwd):
    return place.cwd if place is not None and isinstance(place.cwd, str) else cwd


def _bounded(args, folder, seconds):
    """(exit code, standard output) of a command run in folder, or None when it did not finish in
    seconds. It runs in a process group of its own, which is killed whole at the limit: a gh it
    started would otherwise hold the pipe open and this hook with it, past the harness's own limit."""
    import signal
    p = subprocess.Popen(args, cwd=folder, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                         stdin=subprocess.DEVNULL, start_new_session=True)
    try:
        out, _ = p.communicate(timeout=seconds)
        return p.returncode, out.decode("utf-8", "replace")
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except OSError:
            pass
        try:
            p.communicate(timeout=2)
        except subprocess.TimeoutExpired:
            pass
        return None


def _github(selector, repo_flag, folder):
    """What GitHub holds for one pull request, through lib/merge-target.sh's reader (each logged in
    account, an answer about another repository refused): (owner/name, its description, its number
    or None when GitHub's answer gave none), or Refuse. selector is the number, link or branch the
    command names, empty for the current branch's."""
    script = ('. "$1/lib/merge-target.sh" 2>/dev/null && declare -F mt_pr_view >/dev/null || exit 3\n'
              'slug="${3:-$(mt_remote_slug)}"\n'
              'printf \'%s\\n\' "$slug"\n'
              'mt_pr_view "$2" "number,url,body" "$slug" "$3"\n')
    if not isinstance(folder, str) or not os.path.isdir(folder):
        raise Refuse("the directory this command runs in could not be told, so which pull request it names could not "
                     "be read from GitHub. " + USE_BODY_FILE)
    ran = _bounded(["bash", "-c", script, "_", _HERE, selector or "", repo_flag or ""], folder, GITHUB_SECONDS)
    if ran is None:
        raise Refuse("GitHub did not answer in %d seconds, so the wording this pull request carries could not be "
                     "read from GitHub. %s" % (GITHUB_SECONDS, USE_BODY_FILE))
    code, out = ran
    slug, _, rest = out.partition("\n")
    try:
        envelope = json.loads(rest)
    except ValueError:
        envelope = None
    if code == 3 or not isinstance(envelope, dict):
        raise Refuse("lib/merge-target.sh, which reads a pull request from GitHub, could not be loaded or gave no "
                     "answer, so the wording this pull request carries could not be read from GitHub. Reinstall the "
                     "hooks with claude-sync pull.")
    view = envelope.get("view") if envelope.get("found") is True else None
    if not isinstance(view, dict) or not isinstance(view.get("body"), str):
        said = envelope.get("error") or ("no such pull request was found" if envelope.get("notFound") else "")
        raise Refuse("the wording this pull request carries could not be read from GitHub"
                     + (" (" + str(said)[:200] + ")" if said else "") + ", so whether Dan approved it could not be "
                     "told. " + USE_BODY_FILE)
    m = PULL_URL.match(view.get("url") or "")
    number = view.get("number")
    if not isinstance(number, int) or isinstance(number, bool):
        number = int(m.group(3)) if m else None
    return ("%s/%s" % (m.group(1), m.group(2)) if m else slug.strip()), view["body"], number


def _repo(args, envs, place, cwd):
    """The repository a create posts to: its --repo or -R, GH_REPO, else the origin of the directory
    it runs in. Refuse when none can be told."""
    named = scan.flag_values(args, "--repo", "-R")
    if named:
        return named[-1]
    for e in envs:
        if e.startswith("GH_REPO=") and e[len("GH_REPO="):]:
            return e[len("GH_REPO="):]
    if os.environ.get("GH_REPO"):
        return os.environ["GH_REPO"]
    folder = _run_dir(place, cwd)
    if isinstance(folder, str) and os.path.isdir(folder):
        try:
            ran = _bounded(["bash", "-c", '. "$1/lib/merge-target.sh" 2>/dev/null && mt_remote_slug', "_", _HERE],
                           folder, REMOTE_SECONDS)
        except OSError:
            ran = None
        slug = ran[1].strip() if ran else ""
        if approval.repo_key(slug):
            return slug
    raise Refuse("the repository this command posts to could not be told (no --repo, and the directory it runs in "
                 "has no GitHub origin), so no approval of Dan's could be looked up for it. Name it with --repo "
                 "owner/name.")


def _given_body(kind, args, command, place, cwd, environ):
    """The description the command itself gives, as bytes, or None when it gives none. Refuse for a
    form it cannot be read from."""
    reads_stdin = any(a in ("-F", "--body-file") and nxt == "-" for a, nxt in zip(args, args[1:])) \
        or any(a in ("-F-", "--body-file=-") for a in args)
    if reads_stdin:
        raise Refuse("its description comes on standard input, which cannot be read before the command runs. "
                     + USE_BODY_FILE)
    bodies = scan.flag_values(args, "--body", "-b")
    if bodies:
        return bodies[-1].encode("utf-8", "replace")
    files = scan.flag_values(args, "--body-file", "-F")
    if files:
        path, why = scan.resolve_path(files[-1], place)
        if why or not path:
            raise Refuse("which file its --body-file names could not be told (" + (why or "no path") + "). "
                         + USE_BODY_FILE)
        for _, _, _, lands in scan.file_writes_in_context(command, cwd, environ):
            if lands is None or os.path.realpath(lands) == os.path.realpath(path):
                raise Refuse("the same command writes a file before it posts, so the body file may not hold yet what "
                             "the command would post. " + USE_BODY_FILE)
        try:
            with open(path, "rb") as f:
                data = f.read(BODY_BYTES + 1)
        except OSError as e:
            raise Refuse("its body file " + path + " could not be read (" + type(e).__name__ + "). " + USE_BODY_FILE)
        if len(data) > BODY_BYTES:
            raise Refuse("its body file " + path + " is larger than 1 MB, which is no pull request description.")
        return data
    if any(a in BODY_FLAGS for a in args):
        # The shared reader takes no value that stands apart from its flag and is empty or opens
        # with a dash, so the flag is there and its value is not. The description GitHub holds now
        # is the one this command replaces. (An empty value glued to its flag, `--body=`, IS read,
        # above: the command leaves an empty description, and is refused as having no block.)
        raise Refuse("it gives a description that could not be read from the command (one that is empty, or opens "
                     "with a dash, which reads as another flag). " + USE_BODY_FILE)
    if kind == ("pr", "create"):
        if any(a in UNREAD_BODY_FLAGS or a.split("=", 1)[0] in UNREAD_BODY_FLAGS for a in args):
            raise Refuse("it takes the description from the commits, a template or an editor, which cannot be read "
                         "before the command runs. " + USE_BODY_FILE)
        raise Refuse("it gives no description, so there is no wording to read. " + USE_BODY_FILE)
    return None


def _number(selector):
    """The pull request a command names by number or by link, or None (a branch, or nothing)."""
    m = PULL_URL.match(selector or "")
    if m:
        return int(m.group(3))
    return int(selector) if (selector or "").isdigit() else None


def _wording_approved(repo, body, payload, notes, pr=None):
    """Refuse unless the Announcement block of body, a description as bytes, is wording Dan approved
    for repo, under an approval that pull request pr may use: one approval covers one pull request
    (Dan, 2026-11-25), so the pull request that used one keeps it, and any other, or a command that
    names none by number (a create, an edit by branch that gives its own description), is covered
    only while an approval of that wording is unused. Nothing is recorded here: the merge gate
    records which pull request uses an approval."""
    answer, why = approval.hash_of(body, True)
    if why is not None:
        raise Refuse("the wording could not be hashed (" + why + "), so whether Dan approved it could not be told.")
    if not answer["found"]:
        raise Refuse("the description it would leave has no `## Announcement` block, and the label is for a pull "
                     "request carrying the post for agents that Dan approved. Write the post under that heading "
                     "first. " + approval.HOW_TO_ASK)
    if not answer["hash"]:
        raise Refuse("the `## Announcement` block of the description it would leave is empty, so there is no wording "
                     "Dan could have approved. " + approval.HOW_TO_ASK)
    verdict = approval.check(repo, answer["hash"], payload, pr)
    notes.extend(verdict["notes"])
    if verdict["approved"] is not True:
        raise Refuse(verdict["why"] + " " + verdict["how"])


_judged = 0


def _one_judgment():
    """Refuse the second command of one call that puts the label on. Each is judged by
    reads of its own (the remote, GitHub, the hash, the session), so one per call is what keeps this
    hook's time inside the bound it is registered with, and one per command is always open."""
    global _judged
    _judged += 1
    if _judged > 1:
        raise Refuse("this call puts the label on in more than one command, and each is judged by "
                     "reads of its own. Put the label on one pull request per command: `gh pr edit <number> "
                     "--add-label " + LABEL + "`.")


def _judge_put(kind, args, envs, place, command, cwd, payload, notes, writes):
    long_flag, short_flag = PUTS[kind]
    # The one letter form is read after other one letter flags too (`-dl`): a label found there that
    # gh would read otherwise can only refuse more.
    if LABEL not in _labels(scan.flag_values(args, long_flag, short_flag, clustered=bool(short_flag))):
        return
    _one_judgment()
    environ = dict(os.environ)
    body = _given_body(kind, args, command, place, cwd, environ)
    if kind == ("pr", "create"):
        return _wording_approved(_repo(args, envs, place, cwd), body, payload, notes)
    named = _positionals(args, EDIT_VALUE_FLAGS)
    if len(named) > 1:
        raise Refuse("it names more than one pull request, and each carries wording of its own. Put the label on "
                     "one pull request per command.")
    repo_flag = (scan.flag_values(args, "--repo", "-R") or [""])[-1]
    selector = named[0] if named else ""
    m = PULL_URL.match(selector)
    if m and not repo_flag:
        repo_flag = "%s/%s" % (m.group(1), m.group(2))
    if body is None:
        if writes > 1:
            raise Refuse("the same call makes another GitHub write (a create, an edit or a gh api write), so the "
                         "description GitHub holds now may not be the one the label would sit on. Put the label on "
                         "in a command of its own, once the other has run: `gh pr edit <number> --add-label " + LABEL
                         + "`.")
        repo, held, number = _github(selector, repo_flag, _run_dir(place, cwd))
        return _wording_approved(repo, held.encode("utf-8", "replace"), payload, notes, number)
    _wording_approved(repo_flag or _repo(args, envs, place, cwd), body, payload, notes, _number(selector))


def _judge_rename(args):
    """gh label edit: renaming another label onto this one is refused, whatever is approved."""
    if LABEL in _labels(scan.flag_values([a.lower() for a in args], "--name", "-n")):
        raise Refuse("it renames another label to " + LABEL + ", which puts the label on every pull request "
                     "carrying that one with no wording read for any of them. " + USE_PR_EDIT)


def _api_write(args):
    return "DELETE" not in {v.upper() for v in scan.flag_values(args, "--method", "-X")} and scan.api_writes(args)


def _api_calls(command):
    """The arguments of each gh api call the command makes, as the session link gate finds them."""
    out = []
    pipelines, _bodies = scan._stages(command)
    for stages in pipelines:
        if not isinstance(stages, list):
            continue
        for words, _redirects, _heredocs in stages:
            found = scan.gh_command(words)
            if found and found[0] == "api":
                out.append(list(found[2]) + list(found[3]))
    return out


def _judge_api(args, cwd, payload, notes):
    """One gh api write, in a command that names the label somewhere."""
    names = LABEL in " ".join(args).lower()
    # A body it reads from a file or standard input names its labels where the words here cannot.
    unseen = any(a == "--input" or a.startswith("--input=") for a in args)
    named = _positionals(args, API_VALUE_FLAGS)
    endpoint = (named[0] if named else "").split("?")[0]
    for prefix in ("https://api.github.com/", "/"):
        if endpoint.startswith(prefix):
            endpoint = endpoint[len(prefix):]

    def repo_of(m):
        if "{" in m.group(1) + m.group(2):
            return _repo([], [], None, cwd)
        return "%s/%s" % (m.group(1), m.group(2))

    m = ISSUE_LABELS.fullmatch(endpoint)
    if m and (names or unseen):
        _one_judgment()
        repo, held, number = _github(m.group(3), repo_of(m), cwd)
        return _wording_approved(repo, held.encode("utf-8", "replace"), payload, notes, number)
    if REPO_LABELS.fullmatch(endpoint):
        # Making the label in a repository: it goes on no pull request, so nothing is judged.
        return
    if not names:
        return
    raise Refuse("it writes the label through the GitHub API in a form whose pull request and wording cannot be "
                 "read here. " + USE_PR_EDIT)


def judge_label(command, cwd, payload, notes):
    """None, or why the command may not put the label on what it names."""
    if LABEL not in command.lower() or not re.search(r"\bgh\b", command):
        return None
    try:
        found = scan.scan_gh_in_context(command, cwd, dict(os.environ), KINDS)
        apis = [args for args in _api_calls(command) if _api_write(args)]
        # How many commands of this call write to GitHub: an edit that leaves the description to
        # GitHub is judged by what GitHub holds now, which holds only when it is the one write.
        writes = sum(1 for kind, _, _, _ in found if kind in PUTS) + len(apis)
        for kind, args, envs, place in found:
            if kind in PUTS:
                _judge_put(kind, args, envs, place, command, cwd, payload, notes, writes)
            else:
                _judge_rename(args)
        for args in apis:
            _judge_api(args, cwd, payload, notes)
    except Refuse as e:
        return str(e)
    except scan.ReaderMissing as e:
        if CRUDE_WRITE.search(command):
            return ("this hook could not read this command (" + str(e) + "), and its text names the label and a gh "
                    "command that may put it on a pull request. Put lib/shell-words.py back beside the hook "
                    "(claude-sync pull restores it), then run it again.")
    except scan.Unreadable as e:
        if CRUDE_WRITE.search(command):
            return ("this hook could not read this command (" + str(e) + "), and its text names the label and a gh "
                    "command that may put it on a pull request. " + USE_PR_EDIT)
    return None


def judge_record(command, cwd):
    """None, or why a Bash command naming the record of what Dan approved may write it."""
    name = approval.RECORD_NAME
    if name not in command.lower():
        return None
    ap = _load("db_apply_approval_shared", "lib", "db-apply-approval.py")
    sw = _load("shell_words_shared", "lib", "shell-words.py")
    calls = _load("db_write_calls_shared", "lib", "db-write-calls.py")
    here = cwd if isinstance(cwd, str) and cwd.startswith("/") else ""
    rest = command
    for _, text, _, why, _ in sw.every_command(command, here):
        if name in text.lower():
            if why or not ap._only_reads(text, sw, calls.strip_redirects, ap.GIT_LIST_READS, ("rg",)):
                return "the command `" + ap._shown(text) + "` names it and is not one that only reads it"
            rest = rest.replace(text, "", 1)
    if name in rest.lower():
        return "it is named where no command of this call could be read naming it (a heredoc body, a string)"
    return None


LIBRARY_FILE = "announce-approval.py"
PYTHON = re.compile(r"(?:python|pypy)[0-9.]*")
# python's one letter options that take a value: the rest of their word, or else the next word.
PYTHON_VALUE_LETTERS = "cmXW"
# Modules that read a file handed to `python -m` and run none of it.
COMPILES = ("py_compile", "compileall")


def _library_verb(args):
    """None when the words after the library's file are one of its two forms that only read, else
    what stands in the way."""
    verb = args[0] if args else ""
    if verb == "list":
        return None
    if verb != "check":
        return "runs it with " + ("`" + verb + "`" if verb else "no command") + ", and only `list` and `check` read"
    if any(a.startswith("--claim") for a in args[1:]):
        return "runs its check with --claim, which is the merge gate's question and writes"
    if any("$" in a or "`" in a for a in args[1:]):
        return ("runs its check with a word the shell fills in at run time, so whether it carries --claim cannot be "
                "read here; write each value out")
    return None


def _python_runs(rest):
    """None when the python these words follow does not run the library, else how it does in a form
    that may write. python's options are read as python reads them: one letter options may share a
    word (-Bc), and -c, -m, -X and -W take the rest of their word as their value (-c"...") or else
    the next word, so a program or a module is found however it is spelled."""
    i = 0
    while i < len(rest):
        word = rest[i]
        if not word.startswith("-") or word == "-":
            # The script python runs, or its standard input. Another script handed the file's name
            # is not this library run.
            if os.path.basename(word).lower() == LIBRARY_FILE:
                return _library_verb(rest[i + 1:])
            return None
        # python's one long option that takes the next word as its value.
        step = 2 if word == "--check-hash-based-pycs" else 1
        if not word.startswith("--"):
            for k, letter in enumerate(word[1:], 1):
                if letter not in PYTHON_VALUE_LETTERS:
                    continue
                glued = word[k + 1:]
                value = glued or (rest[i + 1] if i + 1 < len(rest) else "")
                after = rest[i + 1:] if glued else rest[i + 2:]
                named = LIBRARY_FILE in value.lower() or any(LIBRARY_FILE in w.lower() for w in after)
                if letter == "c":
                    if named:
                        return "hands python a program that names it, and what that program does cannot be read here"
                    return None
                if letter == "m":
                    if value in COMPILES or not named:
                        return None
                    return "runs it through python -m " + value + ", and what that does with it cannot be read here"
                step = 1 if glued else 2
                break
        i += step
    return None


def _runs_library(text, unread, sw, only_reads):
    """None, or how one command naming the library's file runs it in a form that may write.

    Every python among the command's words is read, wherever it stands: what a program in front of
    it takes as its own options and their values (sudo -u root, env -u NAME, xargs -I {}) cannot be
    listed, so nothing is asked of the words before it. The one exception is a command known only to
    read (grep -n python3 <the file>), which names python and runs nothing."""
    if unread:
        return "names it inside a wrapper whose string could not be read (" + unread + ")"
    try:
        words = sw.command_words(sw.command_rest(text)[0])
    except Exception:  # noqa: BLE001  a command nobody can read is not one known only to read
        return "names it and could not be read as words"
    if not words:
        return None
    pythons = [i for i, w in enumerate(words) if PYTHON.fullmatch(os.path.basename(w).lower())]
    if pythons:
        if pythons[0] != 0 and only_reads(text):
            return None
        for at in pythons:
            held = _python_runs(words[at + 1:])
            if held:
                return held
        return None
    # No python named. The file carries no interpreter line, so run by its own path it is read by
    # the shell and never by python, in front of a command or behind a program that runs what
    # follows it (measured 2026-11-25, and test-announce-approval.sh holds that it carries none).
    # So no list of such programs is kept here, which could only ever be short of one. The file as
    # a command of its own is still refused, since nothing good comes of the shell reading it.
    if os.path.basename(words[0]).lower() == LIBRARY_FILE:
        return _library_verb(words[1:])
    return None


def judge_library(command, cwd):
    """None, or why a Bash command naming the library that writes the record may run it to write
    (claude-config#3703). Its two forms that only read pass, and so does a command that names the
    file without running it."""
    if LIBRARY_FILE not in command.lower():
        return None
    ap = _load("db_apply_approval_shared", "lib", "db-apply-approval.py")
    sw = _load("shell_words_shared", "lib", "shell-words.py")
    calls = _load("db_write_calls_shared", "lib", "db-write-calls.py")
    here = cwd if isinstance(cwd, str) and cwd.startswith("/") else ""

    def only_reads(text):
        return ap._only_reads(text, sw, calls.strip_redirects, ap.GIT_LIST_READS, ("rg",))

    rest = command
    for _, text, _, why, _ in sw.every_command(command, here):
        if LIBRARY_FILE in text.lower():
            held = _runs_library(text, why, sw, only_reads)
            if held:
                return "the command `" + ap._shown(text) + "` " + held
            rest = rest.replace(text, "", 1)
    if LIBRARY_FILE in rest.lower():
        return ("it is named where no command of this call could be read naming it (a heredoc body, a string), so "
                "whether a program there runs it could not be told; put that text in a file with Write")
    return None


RECORD_IS = "the record of the announcement wording Dan approved (state/" + approval.RECORD_NAME + ")"
LIBRARY_RULE = ("It is not a session's to run that way: only a hook writes his approval there, when it reads his "
                "answer in this session's own picker, as the label goes on or at the merge. A session may read the "
                "record with `python3 ~/.claude/hooks/lib/" + LIBRARY_FILE + " list`, or ask whether a wording is on "
                "it with `python3 ~/.claude/hooks/lib/" + LIBRARY_FILE + " check --repo <owner/name> --hash <sha256>`, "
                "without --claim and with each value written out. " + approval.HOW_TO_ASK)
RECORD_RULE = ("It is not a session's to write: only his own answer in the picker adds to it, when a hook reads that "
               "answer and writes his approval there. Read it with `python3 ~/.claude/hooks/lib/announce-approval.py "
               "list`. " + approval.HOW_TO_ASK)


def deny(reason):
    json.dump(scan.deny_payload(HEAD + ": " + reason), sys.stdout)
    return 0


def main():
    data = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace"))
    tool, tool_input = data.get("tool_name"), data.get("tool_input")
    cwd = data.get("cwd") if isinstance(data.get("cwd"), str) else None
    if tool in EDIT_TOOLS:
        path = tool_input.get("file_path") or tool_input.get("notebook_path")
        if isinstance(path, str) and path and not os.path.isabs(path) and cwd:
            path = os.path.join(cwd, path)
        if approval.is_record_path(path):
            return deny("this " + tool + " writes " + RECORD_IS + ". " + RECORD_RULE)
        return 0
    if tool != "Bash":
        return 0
    command = tool_input["command"]
    if not isinstance(command, str):
        raise TypeError("the command is not text")
    held = judge_record(command, cwd)
    if held:
        return deny("this command may write " + RECORD_IS + ": " + held + ". " + RECORD_RULE)
    held = judge_library(command, cwd)
    if held:
        return deny("this command runs lib/" + LIBRARY_FILE + ", or may, in a form that can write " + RECORD_IS + ": "
                    + held + ". " + LIBRARY_RULE)
    notes = []
    why = judge_label(command, cwd, data, notes)
    if why:
        # True of every refusal below it: wording he never approved, an approval another pull
        # request used, and a form that cannot be read (L11).
        return deny("this command would put " + LABEL + " on a pull request with no approval of Dan's covering it, or "
                    "in a way that cannot be checked: " + why)
    if notes:
        text = " ".join(notes)
        json.dump({"systemMessage": text,
                   "hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": text}}, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.stdout.reconfigure(errors="replace")
    sys.exit(main())
