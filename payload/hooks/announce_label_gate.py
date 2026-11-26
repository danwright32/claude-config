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
      than one pull request) is refused with the form to use.
  gh api writing to repos/<owner>/<name>/issues/<number>/labels
      The same, from the description GitHub holds. Any other gh api write naming the label is
      refused with the form to use, since nothing here can place it.
  gh label create, gh label clone, gh api writing to repos/<owner>/<name>/labels
      Making the label puts it on no pull request, so there is no wording to read. It is refused
      until Dan has approved an announcement for that repository at all, which is when the label
      has a use there.
  gh label edit --name changelog/announce, and its gh api form
      Renaming another label onto it puts it on every pull request carrying that one, with no
      wording read for any, so it is always refused, with the form to use.
Taking the label off, reading it and naming it in text put it on nothing and pass.

And the record of what he approved, whatever the command names:
  Edit, Write, MultiEdit, NotebookEdit of a file under the record's folder
  a Bash command naming that folder that is not one only reading it (lib/db-apply-approval.py's
    reading of "only reads", the one the record of approved test project lines is held by)

Every refusal is a deny. Commands are read by the shared gh reader (gh_issue_scan.py). No override.

What it cannot see: a label named through a variable, a file or a script, a gh alias, a label id in
a GraphQL call that does not spell the name. Those reach the merge gate, which reads the pull
request itself.
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
MAKES = {("label", "create"), ("label", "clone")}
RENAMES = {("label", "edit")}
KINDS = frozenset(PUTS) | MAKES | RENAMES
# The flags of an edit, and of gh api, that take a value, so the value is not read as the pull
# request the command names or the endpoint it calls.
EDIT_VALUE_FLAGS = {"--add-assignee", "--add-label", "--add-project", "--add-reviewer", "--base", "-B", "--body", "-b",
                    "--body-file", "-F", "--milestone", "-m", "--remove-assignee", "--remove-label", "--remove-project",
                    "--remove-reviewer", "--repo", "-R", "--title", "-t"}
API_VALUE_FLAGS = {"-f", "-F", "--field", "--raw-field", "-H", "--header", "--input", "-X", "--method", "-q", "--jq",
                   "-t", "--template", "--hostname", "--cache", "-p", "--preview"}
# The forms of a create that take the description from somewhere this hook cannot read.
UNREAD_BODY_FLAGS = {"--fill", "-f", "--fill-first", "--fill-verbose", "--template", "-T", "--editor", "-e", "--recover"}
BODY_BYTES = 1024 * 1024
GITHUB_SECONDS = 20
EDIT_TOOLS = ("Edit", "Write", "MultiEdit", "NotebookEdit")
PULL_URL = re.compile(r"https://github\.com/([^/\s]+)/([^/\s]+)/(?:pull|issues)/(\d+)")
ISSUE_LABELS = re.compile(r"repos/([^/]+)/([^/]+)/issues/(\d+)/labels")
REPO_LABELS = re.compile(r"repos/([^/]+)/([^/]+)/labels")
CRUDE_WRITE = re.compile(r"\bgh\b[^\n]*(?:--add-label|--label|\s-l\s|\bapi\b|\blabel\s+(?:create|edit|clone)\b)")

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


def _github(selector, repo_flag, folder):
    """What GitHub holds for one pull request, through lib/merge-target.sh's reader (each logged in
    account, an answer about another repository refused): (owner/name, its description), or Refuse.
    selector is the number, link or branch the command names, empty for the current branch's."""
    script = ('. "$1/lib/merge-target.sh" 2>/dev/null && declare -F mt_pr_view >/dev/null || exit 3\n'
              'slug="${3:-$(mt_remote_slug)}"\n'
              'printf \'%s\\n\' "$slug"\n'
              'mt_pr_view "$2" "number,url,body" "$slug" "$3"\n')
    if not isinstance(folder, str) or not os.path.isdir(folder):
        raise Refuse("the directory this command runs in could not be told, so which pull request it names could not "
                     "be read from GitHub. " + USE_BODY_FILE)
    try:
        r = subprocess.run(["bash", "-c", script, "_", _HERE, selector or "", repo_flag or ""], cwd=folder,
                           capture_output=True, timeout=GITHUB_SECONDS)
    except subprocess.TimeoutExpired:
        raise Refuse("GitHub did not answer in %d seconds, so the wording this pull request carries could not be "
                     "read from GitHub. %s" % (GITHUB_SECONDS, USE_BODY_FILE))
    out = r.stdout.decode("utf-8", "replace")
    slug, _, rest = out.partition("\n")
    try:
        envelope = json.loads(rest)
    except ValueError:
        envelope = None
    if r.returncode == 3 or not isinstance(envelope, dict):
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
    return ("%s/%s" % (m.group(1), m.group(2)) if m else slug.strip()), view["body"]


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
            r = subprocess.run(["bash", "-c", '. "$1/lib/merge-target.sh" 2>/dev/null && mt_remote_slug', "_", _HERE],
                               cwd=folder, capture_output=True, timeout=10)
            slug = r.stdout.decode("utf-8", "replace").strip()
        except (subprocess.TimeoutExpired, OSError):
            slug = ""
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
    if kind == ("pr", "create"):
        if any(a in UNREAD_BODY_FLAGS or a.split("=", 1)[0] in UNREAD_BODY_FLAGS for a in args):
            raise Refuse("it takes the description from the commits, a template or an editor, which cannot be read "
                         "before the command runs. " + USE_BODY_FILE)
        raise Refuse("it gives no description, so there is no wording to read. " + USE_BODY_FILE)
    return None


def _wording_approved(repo, body, payload, notes):
    """Refuse unless the Announcement block of body, a description as bytes, is wording Dan approved
    for repo."""
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
    verdict = approval.check(repo, answer["hash"], payload)
    notes.extend(verdict["notes"])
    if verdict["approved"] is not True:
        raise Refuse(verdict["why"] + " " + verdict["how"])


def _label_made(repo, payload, notes):
    """Refuse making the label in repo unless Dan has approved an announcement for it."""
    verdict = approval.repo_approved(repo, payload)
    notes.extend(verdict["notes"])
    if verdict["approved"] is not True:
        raise Refuse("it makes the label in a repository where it has no use yet: " + verdict["why"] + " The label is "
                     "made once he has approved the first announcement there. " + verdict["how"])


def _judge_put(kind, args, envs, place, command, cwd, payload, notes):
    long_flag, short_flag = PUTS[kind]
    if LABEL not in _labels(scan.flag_values(args, long_flag, short_flag)):
        return
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
        repo, held = _github(selector, repo_flag, _run_dir(place, cwd))
        return _wording_approved(repo, held.encode("utf-8", "replace"), payload, notes)
    _wording_approved(repo_flag or _repo(args, envs, place, cwd), body, payload, notes)


def _judge_label(kind, args, envs, place, cwd, payload, notes):
    lowered = [a.lower() for a in args]
    if kind in RENAMES:
        if LABEL in _labels(scan.flag_values(lowered, "--name", "-n")):
            raise Refuse("it renames another label to " + LABEL + ", which puts the label on every pull request "
                         "carrying that one with no wording read for any of them. " + USE_PR_EDIT)
        return
    if kind == ("label", "create") and LABEL not in lowered:
        return
    _label_made(_repo(args, envs, place, cwd), payload, notes)


def _judge_api(args, cwd, payload, notes):
    if LABEL not in " ".join(args).lower():
        return
    if "DELETE" in {v.upper() for v in scan.flag_values(args, "--method", "-X")} or not scan.api_writes(args):
        return
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
    if m:
        repo, held = _github(m.group(3), repo_of(m), cwd)
        return _wording_approved(repo, held.encode("utf-8", "replace"), payload, notes)
    m = REPO_LABELS.fullmatch(endpoint)
    if m:
        return _label_made(repo_of(m), payload, notes)
    raise Refuse("it writes the label through the GitHub API in a form whose pull request and wording cannot be "
                 "read here. " + USE_PR_EDIT)


def judge_label(command, cwd, payload, notes):
    """None, or why the command may not put the label on what it names."""
    if LABEL not in command.lower() or not re.search(r"\bgh\b", command):
        return None
    try:
        for kind, args, envs, place in scan.scan_gh_in_context(command, cwd, dict(os.environ), KINDS):
            if kind in PUTS:
                _judge_put(kind, args, envs, place, command, cwd, payload, notes)
            else:
                _judge_label(kind, args, envs, place, cwd, payload, notes)
        pipelines, _bodies = scan._stages(command)
        for stages in pipelines:
            if not isinstance(stages, list):
                continue
            for words, _redirects, _heredocs in stages:
                found = scan.gh_command(words)
                if found and found[0] == "api":
                    _judge_api(list(found[2]) + list(found[3]), cwd, payload, notes)
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


RECORD_WHY = ("the record of the announcement wording Dan approved (state/" + approval.RECORD_NAME + "), and only his "
              "own answer in the picker adds to it: a hook writes his approval there when it reads that answer. "
              "Read it with `python3 ~/.claude/hooks/lib/announce-approval.py list`. " + approval.HOW_TO_ASK)


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
            return deny("this " + tool + " writes " + RECORD_WHY)
        return 0
    if tool != "Bash":
        return 0
    command = tool_input["command"]
    if not isinstance(command, str):
        raise TypeError("the command is not text")
    held = judge_record(command, cwd)
    if held:
        return deny("this command may write " + RECORD_WHY.replace("), and only", "): " + held + ". Only", 1))
    notes = []
    why = judge_label(command, cwd, data, notes)
    if why:
        return deny("this command would put " + LABEL + " on wording Dan has not approved, or in a way that cannot be "
                    "checked: " + why)
    if notes:
        text = " ".join(notes)
        json.dump({"systemMessage": text,
                   "hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": text}}, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.stdout.reconfigure(errors="replace")
    sys.exit(main())
