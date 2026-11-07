#!/usr/bin/env python3
"""Refuse public pull request and issue text that names a work organisation or repository.

claude-config#2105. On 2026-11-02 a pull request description in this public repository named a work
repository three times, copied from the issue it closed, and both were scrubbed by hand. The file
scan (lib/work-names.py, #1568) never sees a description, a title or a comment: they reach GitHub
from the command line without ever being a file. This gate judges them before the command runs.

WHAT IS JUDGED. Every gh pr create, pr edit, pr comment, pr review, issue create, issue edit and
issue comment, and every gh api write to a repository's issues, pulls or comments endpoints (the
same text reaching the same place by another route, L247). Also, since claude-config#2326 and #2398,
gh repo create (its own text, and the history --push sends), gh repo edit, gh repo sync, gh release
create and edit (title and notes), gh gist create --public (its files and description), and since
#2412 gh gist edit on a public gist and gh repo edit --visibility public. gh's
other names for these (gh pr new, gh issue new, gh release new and the rest) are read as the long
form by lib/shell-words.py. Only where the target is PUBLIC: a private repository passes without the
list ever being read, and so does a secret gist. A public repository owned by a work owner passes
too, a work repository naming its own work. The text judged is the whole command (so a heredoc fed
body is read) and every body, notes or gist file it names that can be read.

THE NAMES. Read live on every judged command and never written anywhere, so no file on disk lists
them: the work repository list (repos.json in the repo digest, the list lib/lesson-fanout.sh reads,
through each signed in account until one can read it), the owners and repositories in this Mac's dev
update registry (lib/dev-update-registry.js, a file each Mac keeps for itself), every project on the
work MacBook's project list in the global CLAUDE.md (claude-config#2184), and the two built in
organisation hashes of lib/work-names.py. The match is that scanner's own rule (its Matcher): a
whole hyphenated run inside a token, in any letter case, and an organisation's login without its
hyphens written as a web or email domain (after an @, or before a dot and a top level domain; as a
bare word it is prose, #2184). Repository names are matched here although
#1568 left them out of the file scan on purpose; this departs from it for public text only (Dan,
2026-11-02, after a repository name leaked), and the file scan and the send scan are unchanged. The
list is read by work_repo_names in lib/work-names.py, the one reader the commit message checks
(work-names.py --work-repos, claude-config#2111) use as well.

CANNOT TELL IS REFUSED (L98, L345): the visibility unreadable under every account, the list
unreadable, empty or of the wrong shape, the registry unreadable, the project list unreadable or
holding no work MacBook project, a body file the command writes from
something it does not show, a body file a gh api call names that cannot be read, a command that
cannot be read but names a judged gh command, and the time budget spent. No registry at all is fine.

The refusal names the name it matched. It goes only to the session, which already holds the command
text the name is in; it is never written to a file or a log.

No override: the remedy is always open, rewrite the text.

WRITES INSIDE A SCRIPT (claude-config#2183). The command hook sees only the Bash command, so a gh
write a Python or shell script makes is invisible to it (on 2026-11-03 a scrub made 239 of them).
So the same rule also runs as the guard on gh: bin/gh, put first on a session's PATH by the
SessionStart hook gh-guard-path.sh, calls this module with --gh <real gh> -- <its arguments>. That
mode judges the real argument list, refuses with exit 1 and withholds the matched name (a script's
error output can land in a log), and otherwise execs the real gh with its exit code unchanged. A
body read from standard input is copied to a temporary file, judged there, and handed to the real
gh unchanged. Any exception refuses. Both modes take the guard off PATH at import, so the gh this
module runs for its own reads is the real one.

GH ALIASES (Dan, on #2183). A command whose first word is not one of gh's own commands is read as
an alias from gh alias list and judged as what it expands to, with gh's $N substitution and the
leftover arguments appended; a shell alias is judged as its shell text. The refusal says which alias
it went through. The guard refuses a possible alias whose list cannot be read (cannot tell); the
command hook passes it, as it did before, since the guard refuses it when it runs.

A SESSION WITHOUT THE GUARD. Every session running when this ships, and any session whose env file
does not put the guard first on PATH, keeps exactly the checks it had: refusing scripts there would
stop merge-when-ready.sh, so every merge on both Macs, until each session restarted. The command
hook tells it once (a stamp per session id under WN_SCRIPTS_NOTICE_DIR) that gh writes inside
scripts are not checked until a new session starts. Not covered at all: gh run by its absolute path,
a script that rewrites PATH, and curl or an API library.

PROGRAMS GH STARTS (claude-config#2207). The real gh is handed the guard first on PATH, so a gh that
a shell alias's command, a pager, an editor or git runs meets the guard again. What the guard cannot
stand in front of is refused (program_refusal): a gh extension, gh copilot, and an alias naming
another alias.

TEXT NOT ON THE COMMAND LINE (claude-config#2326), for a public repository: --editor is refused (gh
runs the editor with no terminal and posts what it wrote), and so is gh pr create --fill unless both
a title and a body are given. gh pr create with no --head is judged with what it may push: the
branch's name and the messages of the commits no remote holds. gh repo create --push is judged with
the whole history it sends, unless the new repository is private or internal. gh repo sync into a
public destination from a --source that is not public is refused, since those commits are not here
to read.

Seams (tests): WORK_NAMES_EXTRA_HASHES, WORK_NAMES_REGISTRY_READER and WORK_NAMES_PROJECT_LIST,
read by lib/work-names.py;
WN_PUBLISH_BUDGET_SECONDS, the whole run's time for GitHub (35, against a hook timeout of 45);
WN_SCRIPTS_NOTICE_DIR and WN_SESSION_ENV_DIR, read by check-work-names-publish.sh for the notice.
"""
import importlib.util
import json
import os
import re
import shlex
import sys
import tempfile

sys.dont_write_bytecode = True
_HERE = os.environ.get("GATE_DIR") or os.path.dirname(os.path.abspath(__file__))


_GUARD_DIR = os.path.realpath(os.path.join(_HERE, "bin"))


def _without_guard(path):
    """PATH without the guard on gh (bin/gh, claude-config#2183), so the gh this gate runs for its own
    reads is the real one: through the guard, every one of them would start this gate again."""
    return ":".join(d for d in (path or "").split(":") if d and os.path.realpath(d) != _GUARD_DIR)


def _with_guard_first(path):
    """PATH with the guard first, for the real gh the guard hands a command to (claude-config#2207).
    gh runs a shell alias's command, an extension, a pager, an editor and git with its own PATH
    (measured on gh 2.89.0), so a gh any of them runs meets the guard again, not the real gh."""
    return ":".join([_GUARD_DIR] + [d for d in _without_guard(path).split(":") if d])


_CALLER_PATH = os.environ.get("PATH")
os.environ["PATH"] = _without_guard(_CALLER_PATH)


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise ImportError("cannot load %s" % path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


scan = _load("gh_issue_scan", os.path.join(_HERE, "gh_issue_scan.py"))
field = _load("issue_field_gate", os.path.join(_HERE, "issue_field_gate.py"))
wn = _load("work_names", os.path.join(_HERE, "lib", "work-names.py"))

KINDS = frozenset(scan.BODY_FILE_COMMANDS | {("pr", "review")})
API_ENDPOINT = re.compile(r"^/?repos/([^/\s]+)/([^/\s?#]+)/(?:issues|pulls|comments)(?:[/?#]|$)")
PLACEHOLDER = re.compile(r"^(?:\{owner\}|\{repo\}|:owner|:repo)$")
CRUDE_API = re.compile(r"\bgh\b[^\n]*\bapi\b[^\n]*repos/\S*/(?:issues|pulls|comments)")
BUDGET = float(os.environ.get("WN_PUBLISH_BUDGET_SECONDS") or 35)

HEAD = "WORK NAME IN PUBLIC TEXT"
REMEDY = ("Scrub it: rewrite the text without the work organisation or repository (say \"a work "
          "repository\"), then run the command again. Public pull requests, issues, comments, release "
          "notes, gists and repository descriptions never name work organisations or repositories "
          "(claude-config#2105, #2398).")


# gh, the budget, the accounts and the work repository list are read by lib/work-names.py, the one
# reader the commit message checks use too (claude-config#2111).
CannotTell = wn.CannotTell
GH = wn.GitHub(BUDGET)
_gh = GH.run
_tokens = GH.tokens


_VIS = {}


def visibility(slug, cwd, gh_repo):
    """-> (nameWithOwner, visibility) of the repository a command posts to, or raises CannotTell."""
    key = (slug, cwd if not slug else None, gh_repo)
    if key in _VIS:
        return _VIS[key]
    argv = ["gh", "repo", "view"] + ([slug] if slug else []) + ["--json", "nameWithOwner,visibility"]
    extra = {"GH_REPO": gh_repo} if gh_repo and not slug else None
    last = ""
    for tok in _tokens():
        ok, out, err = _gh(argv, cwd, tok, extra)
        if ok:
            try:
                got = json.loads(out)
                _VIS[key] = (str(got["nameWithOwner"]), str(got["visibility"]).upper())
                return _VIS[key]
            except (ValueError, KeyError, TypeError):
                last = "gh repo view answered with something that is not its JSON"
                continue
        last = err or last
    raise CannotTell("could not tell whether %s is public: no signed in account could read it (%s)"
                     % (slug or "this checkout's repository", last[:200]))


_NAMES = []


def names():
    """-> (Matcher, work owners, odd names), read once per run, or raises CannotTell."""
    if not _NAMES:
        _NAMES.append(wn.work_repo_names(GH))
    return _NAMES[0]


def find(text, matcher, odd):
    """The first listed name the text holds, or None."""
    low = (text or "").lower()
    for token in wn.TOKEN.findall(low):
        hit = matcher.match(token)
        if hit:
            return hit[1]
    return wn.odd_hit(low, odd) or matcher.domain(low)


def _env_value(name, envs, place):
    for w in reversed(envs or []):
        if w.startswith(name + "="):
            return w.split("=", 1)[1]
    if place is not None:
        if place.vars.get(name):
            return place.vars[name]
        return (place.environ or {}).get(name) or None
    return os.environ.get(name) or None


def _work_owner(owner):
    matcher, owners, _odd = names()
    owner = (owner or "").lower()
    return bool(owner) and (owner in owners or wn.sha(owner) in matcher.hashes)


def published(slug, cwd, gh_repo):
    """The repository's full name when text posted there is public and judged (a public repository
    no work owner owns), else None. Raises CannotTell as visibility does."""
    full, vis = visibility(slug, cwd, gh_repo)
    if vis != "PUBLIC" or _work_owner(full.split("/", 1)[0]):
        return None
    return full


def judge(what, slug, cwd, gh_repo, command, bodies, unseen=()):
    """None when it may post, else the reason. bodies: [(shown as, text, None when hidden, or a
    function returning the text, called only for a public repository)]. unseen: clauses saying what
    else the command posts that cannot be read (claude-config#2326), each refused for a public one."""
    full = published(slug, cwd, gh_repo)
    if full is None:
        return None
    return judge_public(what, "to %s, a public repository," % full, command, bodies, unseen)


def judge_public(what, to, command, bodies, unseen=()):
    """judge() once the text is known to be public: to says where it posts, "to o/x, a public
    repository," or "as a public gist," (claude-config#2398)."""
    matcher, _owners, odd = names()
    hit = find(command, matcher, odd)
    if hit:
        return "%s posts %s and its text names %s." % (what, to, _shown(hit))
    for shown, text in bodies:
        if callable(text):
            text = text()
        if text is None:
            return ("%s posts %s from %s, which this command writes from something it does not show, so "
                    "whether it names a work organisation or repository cannot be told. Write the text "
                    "with a heredoc in the command, or to a file first." % (what, to, shown))
        hit = find(text, matcher, odd)
        if hit:
            return "%s posts %s and %s names %s." % (what, to, shown, _shown(hit))
    for clause in unseen:
        return "%s posts %s %s" % (what, to, clause)
    return None


# Text gh posts that is not on its command line (claude-config#2326), each form measured on gh 2.89.0
# in a throwaway repository against a local stand in for GitHub. With no terminal, gh issue comment
# --editor and gh pr comment --editor run the editor and post what it wrote (gh issue create and gh pr
# create refuse --editor there), and gh pr create aborts rather than push an unpushed branch, which it
# does push when it can ask where to.
EDITOR_FLAGS = ("--editor", "-e")
FILL_FLAGS = ("--fill", "-f", "--fill-first", "--fill-verbose")
TITLE_FLAGS = ("--title", "-t")
BODY_FLAGS = ("--body", "-b", "--body-file", "-F")
EDITED = ("with text an editor program wrote (--editor), which this check cannot read, so whether it "
          "names a work organisation or repository cannot be told. Write the text with --body or "
          "--body-file instead.")
FILLED = ("with a title or body gh fills from commit messages (--fill), which this check does not read, "
          "so whether it names a work organisation or repository cannot be told. Give --title and "
          "--body (or --body-file) instead; given both, gh uses them over --fill.")
# gh repo new is read as gh repo create by the reader (lib/shell-words.py gh_long_form, #2398).
REPO_CREATE = frozenset({("repo", "create")})
REPO_SYNC = ("repo", "sync")
# Public text posted outside pull requests and issues (claude-config#2398): release notes and titles,
# a public gist's files and description, and a public repository's description, homepage and topics.
RELEASE = frozenset({("release", "create"), ("release", "edit")})
GIST_CREATE = ("gist", "create")
GIST_EDIT = ("gist", "edit")
REPO_EDIT = ("repo", "edit")
NOTES_FILE_FLAGS = ("--notes-file", "-F")
GENERATED = ("with notes GitHub writes from the pull requests and commits it includes (--generate-notes), "
             "which this check cannot read, so whether they name a work organisation or repository cannot "
             "be told. Write the notes with --notes or --notes-file instead.")
FROM_TAG = ("with notes taken from the tag's annotation or its commit's message (--notes-from-tag), which "
            "this check does not read, so whether they name a work organisation or repository cannot be "
            "told. Write the notes with --notes or --notes-file instead.")
GIST_STDIN = ("from standard input (it names no file, or names -), which this check cannot read here, so "
              "whether it names a work organisation or repository cannot be told. Name the file instead.")
GIST_EDIT_STDIN = ("with a file's new text from standard input (-), which this check cannot read here, so "
                   "whether it names a work organisation or repository cannot be told. Name the file instead.")
# gh gist edit opens an editor on the gist's file unless it is given a file to take the new text from,
# or adds or removes a file (its help, gh 2.89.0); --desc alone is not counted as saying no editor
# runs, the reading that refuses more (claude-config#2412).
GIST_EDITOR = ("with text an editor program can write (it names no file to take the new text from), which "
               "this check cannot read, so whether it names a work organisation or repository cannot be "
               "told. Name the file holding the new text after the gist, or add it with --add.")
UNREAD_FILE = ("from %s, which could not be read (%s), so whether it names a work organisation or "
               "repository cannot be told.")
# gh gist create's flags that take a value, so the word after one is never a file.
GIST_VALUES = frozenset(("--desc", "-d", "--filename", "-f"))
# gh gist edit's flags that take a value, so the word after one is never the gist or a file.
GIST_EDIT_VALUES = frozenset(("--add", "-a", "--desc", "-d", "--filename", "-f", "--remove", "-r"))
# gh repo edit's flags that take a value, so the word after one is never the repository's name.
REPO_EDIT_VALUES = frozenset(("--description", "-d", "--homepage", "-h", "--add-topic", "--remove-topic",
                              "--default-branch", "--squash-merge-commit-message", "--visibility"))
# Every gh command this gate judges, as (sub, act).
JUDGED = KINDS | REPO_CREATE | {REPO_SYNC} | RELEASE | {GIST_CREATE, GIST_EDIT, REPO_EDIT}
# gh repo create's flags that take a value, so the word after one is never the repository's name.
REPO_CREATE_VALUES = frozenset(("--description", "-d", "--homepage", "-h", "--team", "-t", "--template",
                                "-p", "--gitignore", "-g", "--license", "-l", "--source", "-s",
                                "--remote", "-r"))
REPO_SYNC_VALUES = frozenset(("--branch", "-b", "--source", "-s"))


def _given(args, flags):
    """Whether any of flags is written in args, alone or as --flag=value. A value that looks like one
    of them counts as one, the reading that refuses more, never less."""
    return any(a in flags or (a.startswith("--") and a.split("=", 1)[0] in flags) for a in args)


def _positionals(args, valued):
    """The words no flag takes. A lone - is one of them, as gh reads it (standard input)."""
    out, skip = [], False
    for a in args:
        if skip:
            skip = False
        elif a.startswith("-") and a != "-":
            skip = a in valued
        else:
            out.append(a)
    return out


def _git(where, *args):
    import subprocess
    try:
        return subprocess.run(["git", "-C", where or os.getcwd()] + list(args), capture_output=True,
                              text=True, errors="replace", timeout=20)
    except (OSError, subprocess.SubprocessError) as e:
        raise CannotTell("git could not be run to read what would be pushed (%s)" % type(e).__name__)


def pushed_text(where, history):
    """The text a push gh makes from where would publish: the names of the refs it pushes and the
    messages of the commits it sends. history False: the current branch and the commits no remote ref
    holds, what gh pr create pushes; True: every commit HEAD reaches, what gh repo create --push sends
    to a new repository, or every ref of a bare one, which it mirrors.

    "" when where is no git checkout or HEAD is on no branch, since gh pushes nothing from there.
    Raises CannotTell when git cannot list the commits."""
    r = _git(where, "rev-parse", "--is-bare-repository")
    if r.returncode != 0:
        return ""
    if r.stdout.strip() == "true":
        refs = _git(where, "for-each-ref", "--format=%(refname:short)")
        names_, revs = (refs.stdout if refs.returncode == 0 else None), ["--all"]
    else:
        b = _git(where, "symbolic-ref", "--quiet", "--short", "HEAD")
        if b.returncode != 0:
            return ""
        names_ = b.stdout
        if _git(where, "rev-parse", "--verify", "--quiet", "HEAD").returncode != 0:
            return "branch %s" % names_
        revs = ["HEAD"] if history else ["HEAD", "--not", "--remotes"]
    log = _git(where, "log", "--format=%B%x00", *revs)
    if names_ is None or log.returncode != 0:
        raise CannotTell("git could not list the commits a push from %s would send (%s)"
                         % (where, (log.stderr or "for-each-ref failed").strip()[:200]))
    return "branch %s\n%s" % (names_, log.stdout)


def judge_repo_create(what, args, where, command):
    """gh repo create's own text, its name, description and homepage, is public on the new repository
    (claude-config#2398), and --push sends the whole history to it (#2326). Judged unless the
    repository is made private or internal, or a work owner's."""
    if _given(args, ("--private", "--internal")):
        return None
    name = (_positionals(args, REPO_CREATE_VALUES) or [""])[0]
    if "/" in name and _work_owner(name.split("/", 1)[0]):
        return None
    matcher, _owners, odd = names()
    shown = name or "a new repository"
    hit = find(command, matcher, odd)
    if hit:
        return "%s makes %s, a public repository, and its text names %s." % (what, shown, _shown(hit))
    if not _given(args, ("--push",)):
        return None
    source = os.path.expanduser((scan.flag_values(args, "--source", "-s") or ["."])[-1])
    if not os.path.isabs(source):
        source = os.path.normpath(os.path.join(where or os.getcwd(), source))
    hit = find(pushed_text(source, True), matcher, odd)
    if hit:
        return ("%s --push publishes the history of %s to %s, a public repository, and its branch names "
                "or commit messages name %s." % (what, source, shown, _shown(hit)))
    return None


def judge_repo_sync(what, args, where):
    """gh repo sync with a destination copies the source's commits into it on GitHub (#2326). Their
    messages are not here to read, so a public destination takes them only from a public source, whose
    commits are public already. With no destination it updates this checkout and writes nothing to
    GitHub; with no source the source is the destination's parent, and GitHub keeps every fork of a
    private repository private, so a public destination's parent is public."""
    dest = _positionals(args, REPO_SYNC_VALUES)
    sources = scan.flag_values(args, "--source", "-s")
    if not dest or not sources:
        return None
    full = published(dest[0], where, None)
    if full is None:
        return None
    src, vis = visibility(sources[-1], where, None)
    if vis == "PUBLIC":
        return None
    return ("%s copies the commits of %s, which is not public, into %s, a public repository, and their "
            "messages cannot be read here, so whether they name a work organisation or repository cannot "
            "be told." % (what, src, full))


def _repo_of(args, envs, place):
    """(slug, GH_REPO) a gh pr, issue or release command posts to: its --repo (-R), else GH_REPO."""
    slugs = scan.flag_values(args, "--repo", "-R")
    slug = slugs[-1] if slugs else None
    return slug, (None if slug else _env_value("GH_REPO", envs, place))


def _file_bodies(args, command, place, flags, shown_as):
    """The files a command posts from, named by flags (field.body_files' rule), as judge's bodies: the
    text of one read from disk, None for one this command writes from something it does not show.
    One whose text is in the command (written from text it shows, or standard input) is judged with
    the command; one missing or unreadable is the issue field gate's to refuse, and gh's. One named
    inside clustered short flags (`-dF body.md`) is read too (claude-config#2412)."""
    out = []
    for word, state, detail in field.body_files(args, command, place, flags, clustered=True):
        if state == "hidden":
            out.append(("%s %s" % (shown_as, word), None))
        elif state == "text":
            out.append(("%s %s" % (shown_as, word), detail))
    return out


def judge_release(what, args, envs, place, where, command):
    """gh release create and edit post their title and notes on the release page (claude-config#2398):
    --notes on the command line, --notes-file read here, and the notes gh has GitHub generate or takes
    from the tag refused in a public repository, since this check cannot read them."""
    slug, gh_repo = _repo_of(args, envs, place)
    bodies = _file_bodies(args, command, place, NOTES_FILE_FLAGS, "--notes-file")
    unseen = ([GENERATED] if _given(args, ("--generate-notes",)) else []) + \
             ([FROM_TAG] if _given(args, ("--notes-from-tag",)) else [])
    return judge(what, slug, where, gh_repo, command, bodies, unseen)


def _gist_public(args):
    """Whether gh gist create makes the gist public: --public or -p, alone or among other one letter
    flags (`-wp`). A value that reads as one counts as one, the reading that judges more, never less."""
    return _given(args, ("--public", "-p")) or any(
        a.startswith("-") and not a.startswith("--") and "p" in a[1:] for a in args)


def judge_gist(what, args, place, command):
    """gh gist create --public publishes its files and description to anyone (claude-config#2398). A
    secret gist is unlisted and judged as private. The files are read here; one this command writes
    from something it does not show, one that cannot be read (a pattern gh expands itself included),
    and standard input when no file is named are refused, since their text cannot be read."""
    if not _gist_public(args):
        return None
    files = _positionals(args, GIST_VALUES)
    # A `-` is standard input, which only the guard reads (it hands the gate a file holding those
    # bytes); here it cannot be read, alone or beside named files.
    unseen = [GIST_STDIN] if not files or "-" in args else []
    bodies, unread = _gist_files(files, command, place)
    return judge_public(what, "as a public gist,", command, bodies, unseen + unread)


def _gist_files(files, command, place):
    """(bodies, unseen) for the local files a gist command posts: the text of each read from disk, None
    for one this command writes from something it does not show, and for one that is not there or
    cannot be read a clause saying so (L11: the command never wrote it). Standard input (-) is the
    caller's to judge, and a file written from text the command shows is judged with the command."""
    named = []
    for f in files:
        named += ["--file", f]
    bodies, unseen = [], []
    for word, state, detail in field.body_files(named, command, place, ("--file",)):
        if state == "text":
            bodies.append(("the file %s" % word, detail))
        elif state == "hidden":
            bodies.append(("the file %s" % word, None))
        elif state in ("missing", "unreadable"):
            unseen.append(UNREAD_FILE % ("the file %s" % word, detail or "it is not a file"))
    return bodies, unseen


_GISTS = {}


def gist_public(gist):
    """Whether the gist (its id) is public, read from GitHub with each signed in account in turn, or
    raises CannotTell."""
    if gist in _GISTS:
        return _GISTS[gist]
    last = ""
    for tok in _tokens():
        ok, out, err = _gh(["gh", "api", "gists/%s" % gist], None, tok, None)
        if ok:
            try:
                got = json.loads(out)["public"]
            except (ValueError, KeyError, TypeError):
                last = "gh api answered with something that is not the gist's JSON"
                continue
            if isinstance(got, bool):
                _GISTS[gist] = got
                return got
            last = "gh api gave the gist's public field as %r" % (got,)
            continue
        last = err or last
    raise CannotTell("could not tell whether the gist %s is public: no signed in account could read it (%s)"
                     % (gist, last[:200]))


def judge_gist_edit(what, args, place, command):
    """gh gist edit posts a gist's new description, a file it adds and a file's new text, all public
    on a public gist (claude-config#2412); a secret gist is unlisted and judged as private, as gh gist
    create's is. The gist is the first word that is no flag's (an id or its address), the file to take
    the new text from the second. Text an editor writes and standard input are refused on a public
    gist, since this check cannot read them."""
    named = _positionals(args, GIST_EDIT_VALUES)
    if not named:
        raise CannotTell("it names no gist, so whether the gist it edits is public could not be told")
    gist = named[0].split("#", 1)[0].rstrip("/").split("/")[-1]
    if not gist_public(gist):
        return None
    adds = scan.flag_values(args, "--add", "-a", clustered=True)
    files = adds + named[1:2]
    unseen = [GIST_EDIT_STDIN] if "-" in files else []
    if not files and not scan.flag_values(args, "--remove", "-r", clustered=True):
        unseen.append(GIST_EDITOR)
    bodies, unread = _gist_files([f for f in files if f != "-"], command, place)
    return judge_public(what, "as a public gist,", command, bodies, unseen + unread)


def judge_repo_edit(what, args, envs, place, where, command):
    """gh repo edit sets a repository's description, homepage and topics, which are public on a public
    repository (claude-config#2398). Its repository is the one named, else this checkout's.

    --visibility public makes a repository public, publishing every file, commit and issue it holds,
    none of which this check can read, so it is refused for one not yet public that no work owner owns
    (claude-config#2412), which is where its text would be judged once public."""
    named = _positionals(args, REPO_EDIT_VALUES)
    slug = named[0] if named else None
    gh_repo = None if slug else _env_value("GH_REPO", envs, place)
    if "public" in [v.lower() for v in scan.flag_values(args, "--visibility")]:
        full, vis = visibility(slug, where, gh_repo)
        if vis != "PUBLIC" and not _work_owner(full.split("/", 1)[0]):
            return ("%s makes %s public, publishing every file, commit and issue it holds, which this check "
                    "cannot read, so whether any of it names a work organisation or repository cannot be "
                    "told. Check the repository, then change its visibility yourself." % (what, full))
    return judge(what, slug, where, gh_repo, command, [])


# The command hook names the name it matched: only the session sees it, and the session already holds
# the text. The guard on gh (--gh) withholds it, since a script's error output can land in a log.
_WITHHOLD = []


def _shown(hit):
    return "a work organisation or repository" if _WITHHOLD else "`%s`" % hit


def _read(word, cwd):
    path = os.path.expanduser(word)
    if not os.path.isabs(path):
        path = os.path.join(cwd or os.getcwd(), path)
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError as e:
        raise CannotTell("%s, the file a gh api call sends, cannot be read (%s)" % (word, e.strerror or e))


def api_writes(command, cwd):
    """Each gh api write to an issues, pulls or comments endpoint, as (slug or None, files it sends).

    The files are read by evaluate, inside the try that turns CannotTell into a reason, so a file
    that cannot be read refuses with that reason rather than crashing the gate."""
    out = []
    pipelines, _ = scan._stages(command)
    for stages in pipelines:
        if not isinstance(stages, list):
            continue
        for words, _redirects, _heredocs in stages:
            found = scan.gh_command(words)
            if not found or found[0] != "api":
                continue
            args = list(found[2]) + list(found[3])
            if not scan.api_writes(args):
                continue
            target = None
            for a in args:
                m = API_ENDPOINT.match(a) if not a.startswith("-") else None
                if m:
                    target = m
                    break
            if not target:
                continue
            o, r = target.group(1), target.group(2)
            slug = None if PLACEHOLDER.match(o) or PLACEHOLDER.match(r) else "%s/%s" % (o, r)
            files = [v.split("=@", 1)[1] for v in scan.flag_values(args, "--field", "-F") if "=@" in v]
            files += scan.flag_values(args, "--input")
            out.append((slug, [p for p in files if p != "-"]))
    return out


# gh's own top level commands, with the other names gh answers to for them, its help topics, its hidden
# credits command and the completion commands of the library it is built on (each read from gh 2.89.0:
# gh help, the ALIASES of each command's help, and `gh <word> --help`). gh never lets an alias or an
# extension shadow one, so only a first word outside this set can be an alias (claude-config#2183) or
# an extension (#2207). A word missing here is asked about as an alias and, when it is not one, refused
# as an extension, never passed unjudged.
# The other names (a11y, cs, ext and the rest) come from the reader's one list of them, GH_GROUP_ALIASES
# in lib/shell-words.py (claude-config#2398).
BUILTIN = frozenset("""accessibility actions agent-task alias api attestation auth browse cache codespace
completion config copilot credits environment exit-codes extension formatting gist gpg-key help issue
label licenses mintty org pr preview project reference release repo ruleset run search secret ssh-key
status variable version workflow __complete __completeNoDesc""".split()) | frozenset(scan.GH_GROUP_ALIASES)
# The command whose exec subcommand runs an extension by name, under each of its names.
EXTENSION = frozenset({"extension"} | {a for a, long in scan.GH_GROUP_ALIASES.items() if long == "extension"})
# What gh copilot takes without starting the Copilot CLI.
COPILOT_OWN = frozenset(("--help", "-h", "--remove"))
CANNOT_SEE = ("a program that can write to GitHub with no gh in between for the guard to stand in front "
              "of, so whether it names a work organisation or repository cannot be told")


def program_refusal(args, in_alias=False):
    """The reason, when gh given args (its own name left off, any alias already expanded) would start a
    program the guard cannot see into, else None (claude-config#2207). in_alias: args are an alias's
    expansion, so an alias they name is one inside an alias; otherwise an alias found here stands
    behind a flag, since expand_alias expands one written first (the lessons review of #2398).

    An extension (a word that is neither gh's own command nor an alias, or gh extension exec) and the
    Copilot CLI that gh copilot starts can each write to GitHub through the API with no gh the guard
    could judge, so both are refused. Any gh a program gh starts runs meets the guard again, since the
    real gh is handed the guard first on PATH, so those need nothing here.

    The command is read past the flags written in front of it, as gh reads it (gh_command, #2398):
    `gh -R o/x notely` runs the extension notely, and read from its first word it was a flag, passed."""
    found = scan.gh_command(["gh"] + list(args)) if args else None
    if not found or not found[0]:
        return None
    # A group's other name reads as the group (ext is extension); a word that is no name of gh's own
    # is read as written, since gh lets no alias or extension shadow one of its commands.
    word, act, front, after = found[0], found[1], list(found[2]), list(found[3])
    if word in EXTENSION:
        if act == "exec":
            return "gh %s exec runs a gh extension, %s." % (word, CANNOT_SEE)
        return None
    if word == "copilot":
        own = front + ([act] if act else []) + after
        if own and all(a in COPILOT_OWN for a in own):
            return None
        return "gh copilot starts the GitHub Copilot CLI, %s." % CANNOT_SEE
    if word in BUILTIN:
        return None
    if word in aliases():
        if not in_alias:
            flags = [w for w in front if w.startswith("-")]
            return ("gh %s is a gh alias written behind the %s %s, where this check does not expand it, "
                    "so what it runs cannot be told. Write the alias first, before any flag."
                    % (word, "flags" if len(flags) > 1 else "flag", " ".join(flags)))
        return ("gh %s is another gh alias, which gh does not expand inside an alias (measured on gh "
                "2.89.0), so what it runs cannot be told." % word)
    return ("gh %s is neither one of gh's own commands nor a gh alias, so it runs a gh extension, %s."
            % (word, CANNOT_SEE))
ALIAS_LINE = re.compile(r"^([^\s:]+): (.*)$")
_ALIASES = []


def _alias_value(raw):
    if raw.startswith("'") and raw.endswith("'") and len(raw) >= 2:
        return raw[1:-1].replace("''", "'")
    if raw.startswith('"') and raw.endswith('"') and len(raw) >= 2:
        return json.loads(raw)
    if raw[:1] in ("'", '"', "|", ">", "&", "*", "!", "[", "{"):
        raise ValueError("a value written in a form this reader does not read: %s" % raw[:40])
    return raw


def aliases():
    """-> {name: expansion}, from `gh alias list`, read once per run, or raises CannotTell.

    gh prints each alias as YAML: `name: value`, the value quoted when it must be, or a block
    (`|-`) on the indented lines after it. Anything else is not read as a guess."""
    if _ALIASES:
        return _ALIASES[0]
    ok, out, err = _gh(["gh", "alias", "list"], None, None, None)
    if not ok:
        raise CannotTell("the gh aliases could not be read (%s)" % (err or "gh alias list failed")[:200])
    got, lines, i = {}, out.splitlines(), 0
    try:
        while i < len(lines):
            line = lines[i]
            i += 1
            if not line.strip():
                continue
            m = ALIAS_LINE.match(line)
            if not m:
                raise ValueError("a line that is not an alias: %s" % line[:40])
            name, raw = m.group(1), m.group(2).strip()
            if raw in ("|", "|-"):
                block = []
                while i < len(lines) and (lines[i].startswith(" ") or not lines[i].strip()):
                    block.append(lines[i])
                    i += 1
                pad = min((len(b) - len(b.lstrip(" ")) for b in block if b.strip()), default=0)
                got[name] = "\n".join(b[pad:] for b in block).rstrip("\n") + ("\n" if raw == "|" else "")
            else:
                got[name] = _alias_value(raw)
    except ValueError as e:
        raise CannotTell("the gh aliases could not be read: %s" % e)
    _ALIASES.append(got)
    return got


def expand_alias(args):
    """-> (alias name, the gh command text it runs, gh's arguments it runs or None for a shell alias)
    when args (gh's arguments, the program's own name left off) run an alias, else None.

    gh's own expansion: $1, $2 ... take the arguments after the alias name, and the arguments no
    placeholder took go on the end. A shell alias (`!...`) is the shell command with the arguments
    after it, so their text is judged with it. Raises CannotTell when the first word could be an
    alias and the aliases cannot be read."""
    if not args or args[0].startswith("-") or args[0] in BUILTIN:
        return None
    table = aliases()
    if args[0] not in table:
        return None
    expansion, rest = table[args[0]], list(args[1:])
    if expansion.startswith("!"):
        return args[0], expansion[1:] + (" " + shlex.join(rest) if rest else ""), None
    extra = []
    for n, a in enumerate(rest, 1):
        if "$%d" % n in expansion:
            expansion = expansion.replace("$%d" % n, a)
        else:
            extra.append(a)
    try:
        words = shlex.split(expansion)
    except ValueError as e:
        raise CannotTell("the gh alias %s expands to text that cannot be read (%s)" % (args[0], e))
    return args[0], shlex.join(["gh"] + words + extra), words + extra


def alias_runs(command):
    """Each gh alias the command runs: [(alias name, the command it runs, with any assignments in
    front of it)]. Raises CannotTell as expand_alias does."""
    out = []
    pipelines, _ = scan._stages(command)
    for stages in pipelines:
        if not isinstance(stages, list):
            continue
        for words, _redirects, _heredocs in stages:
            if not scan.gh_command(words):
                continue
            # gh's own arguments are the shared reader's words for the command from the program's
            # name on (claude-config#1188), never a search of the words for the name: the words in
            # front of those are the assignments and runners it passed over.
            rest, _ = scan._sw.command_rest(scan._sw.rejoin(words))
            own = scan._sw.command_words(rest)
            front = [w for w in words[:len(words) - len(own)] if scan.ASSIGNMENT.match(w)]
            got = expand_alias(own[1:])
            if got:
                out.append((got[0], " ".join([shlex.quote(w) for w in front] + [got[1]])))
    return out


def evaluate(command, cwd, depth=0):
    """-> [reasons]. Raises nothing: what cannot be told is a reason.

    A gh alias the command runs is judged as the command it expands to (claude-config#2183). One
    whose expansion cannot be read is the guard's to refuse (bin/gh, which judges every gh a running
    command makes); here it passes as it did before, so a session without the guard in front is told
    once that such writes are not checked, and is never refused more than before."""
    reasons = []
    if depth < 2 and re.search(r"\bgh\b", command or ""):
        try:
            runs = alias_runs(command)
        except (CannotTell, scan.Unreadable):
            runs = []
        for name, text in runs:
            for why in evaluate(text, cwd, depth + 1):
                why = "through the gh alias %s, %s" % (name, why)
                if why not in reasons:
                    reasons.append(why)
    try:
        found = scan.scan_gh_in_context(command, cwd, dict(os.environ), JUDGED)
        apis = api_writes(command, cwd) if re.search(r"\bapi\b", command) else []
    except scan.Unreadable as e:
        named = scan.gated_in_text(command, JUDGED) or CRUDE_API.search(command or "")
        if named:
            return reasons + ["this command could not be read (%s), and it names a gh command that posts "
                              "text, so whether that text names a work organisation or repository cannot "
                              "be told." % e]
        return reasons
    for kind, args, envs, place in found:
        what = "gh %s %s" % kind
        where = place.cwd or place.start or cwd
        try:
            if kind in REPO_CREATE:
                why = judge_repo_create(what, args, where, command)
            elif kind == REPO_SYNC:
                why = judge_repo_sync(what, args, where)
            elif kind in RELEASE:
                why = judge_release(what, args, envs, place, where, command)
            elif kind == GIST_CREATE:
                why = judge_gist(what, args, place, command)
            elif kind == GIST_EDIT:
                why = judge_gist_edit(what, args, place, command)
            elif kind == REPO_EDIT:
                why = judge_repo_edit(what, args, envs, place, where, command)
            else:
                why = _judge_text(kind, what, args, envs, place, where, command)
        except CannotTell as e:
            why = "%s: %s." % (what, e)
        if why and why not in reasons:
            reasons.append(why)
    for slug, files in apis:
        try:
            bodies = [("the file %s" % p, _read(p, cwd)) for p in files]
            why = judge("gh api", slug, cwd, None, command, bodies)
        except CannotTell as e:
            why = "gh api: %s." % e
        if why and why not in reasons:
            reasons.append(why)
    return reasons


def _judge_text(kind, what, args, envs, place, where, command):
    """judge() for one gh pr or issue command: its body files, and what it posts that is not on its
    command line (claude-config#2326). Raises CannotTell."""
    slug, gh_repo = _repo_of(args, envs, place)
    bodies = _file_bodies(args, command, place, ("--body-file", "-F"), "--body-file")
    unseen = [EDITED] if _given(args, EDITOR_FLAGS) else []
    if kind == ("pr", "create"):
        if _given(args, FILL_FLAGS) and not (_given(args, TITLE_FLAGS) and _given(args, BODY_FLAGS)):
            unseen.append(FILLED)
        if not _given(args, ("--head", "-H")):
            # With no --head, gh pushes the branch when it is not fully pushed and it can ask where.
            bodies.append(("what it may push (the branch's name and the commits no remote holds)",
                           lambda: pushed_text(where, False)))
    return judge(what, slug, where, gh_repo, command, bodies, unseen)


# The guard's refusal starts as gh's own errors do, with the program's name. Written as a format so
# the word position scan (claude-config#1188) does not read the literal as a comparison with it.
GUARD_HEAD = "%s: %s" % ("gh", HEAD)


def _refuse(why):
    sys.stderr.write("%s: this gh write was refused before it ran, and nothing was sent.\n  - %s\n%s\n"
                     % (GUARD_HEAD, why, REMEDY))
    return 1


def gh_main(real, args):
    """The guard on gh (bin/gh, claude-config#2183): judge the gh command a running script makes with
    the same rule the command hook applies, then run the real gh with the same arguments, standard
    input and exit code, or refuse it with exit 1 and nothing sent.

    Text a command sends on standard input (an argument of `-`, or a field of `=@-`) is read here, judged
    from a file holding exactly those bytes, and handed to the real gh on its standard input. The name
    matched is withheld from the refusal, since a script's error output can land in a log."""
    _WITHHOLD.append(True)
    judged = list(args)
    feed = seen = None
    try:
        if any(a == "-" or a.endswith("=@-") for a in judged):
            feed = tempfile.TemporaryFile()
            feed.write(sys.stdin.buffer.read())
            feed.flush()
            feed.seek(0)
            seen = tempfile.NamedTemporaryFile(prefix="gh-guard.", delete=False)
            seen.write(feed.read())
            seen.close()
            feed.seek(0)
            judged = [seen.name if a == "-" else (a[:-1] + seen.name if a.endswith("=@-") else a)
                      for a in judged]
        try:
            got = expand_alias(judged)
            starts = program_refusal(judged if got is None else (got[2] or []), in_alias=got is not None)
        except CannotTell as e:
            return _refuse("gh %s could be a gh alias, and %s, so what it runs cannot be told."
                           % (judged[0], e))
        reasons = ([starts] if starts else []) + evaluate(got[1] if got else shlex.join(["gh"] + judged),
                                                          os.getcwd())
    finally:
        if seen is not None:
            os.unlink(seen.name)
    if reasons:
        return _refuse("\n  - ".join(("through the gh alias %s, %s" % (got[0], r)) if got else r
                                     for r in reasons))
    if feed is not None:
        os.dup2(feed.fileno(), 0)
    sys.stdout.flush()
    sys.stderr.flush()
    # The guard goes back first on PATH for the real gh, so a gh that anything gh starts runs (a shell
    # alias's command, a pager, an editor, git and its hooks) is judged too (claude-config#2207).
    env = dict(os.environ, PATH=_with_guard_first(_CALLER_PATH))
    os.execve(real, [real] + list(args), env)


def main():
    if len(sys.argv) >= 4 and sys.argv[1] == "--gh" and sys.argv[3] == "--":
        try:
            return gh_main(sys.argv[2], sys.argv[4:])
        except Exception as e:  # noqa: BLE001  a guard that broke refuses: it is not one that found nothing
            return _refuse("the guard on gh failed (%s), so this write was not checked." % type(e).__name__)
    raw = sys.stdin.buffer.read().decode("utf-8", "replace")
    try:
        data = json.loads(raw)
    except ValueError:
        # A payload nothing can parse: refused when its text plainly runs a judged command.
        if scan.gated_in_text(raw, JUDGED) or CRUDE_API.search(raw):
            json.dump(scan.deny_payload("%s: this hook's payload could not be read, and it names a gh "
                                        "command that posts text, so it was not checked." % HEAD), sys.stdout)
        return 0
    if data.get("tool_name") != "Bash":
        return 0
    command = (data.get("tool_input") or {}).get("command") or ""
    cwd = data.get("cwd") if isinstance(data.get("cwd"), str) else None
    if not re.search(r"\bgh\b", command):
        return 0
    reasons = evaluate(command, cwd)
    if reasons:
        body = "\n".join("  - " + r for r in reasons)
        json.dump(scan.deny_payload("%s:\n%s\n%s" % (HEAD, body, REMEDY)), sys.stdout)
    return 0


if __name__ == "__main__":
    sys.stdout.reconfigure(errors="replace")
    sys.exit(main())
