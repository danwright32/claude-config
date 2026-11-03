#!/usr/bin/env python3
"""Refuse public pull request and issue text that names a work organisation or repository.

claude-config#2105. On 2026-11-02 a pull request description in this public repository named a work
repository three times, copied from the issue it closed, and both were scrubbed by hand. The file
scan (lib/work-names.py, #1568) never sees a description, a title or a comment: they reach GitHub
from the command line without ever being a file. This gate judges them before the command runs.

WHAT IS JUDGED. Every gh pr create, pr edit, pr comment, pr review, issue create, issue edit and
issue comment, and every gh api write to a repository's issues, pulls or comments endpoints (the
same text reaching the same place by another route, L247). Only where the target repository is
PUBLIC: a private repository passes without the list ever being read. A public repository owned by
a work owner passes too, a work repository naming its own work. The text judged is the whole
command (so a heredoc fed body is read) and every body file it names that can be read.

THE NAMES. Read live on every judged command and never written anywhere, so no file on disk lists
them: the work repository list (repos.json in the repo digest, the list lib/lesson-fanout.sh reads,
through each signed in account until one can read it), the owners and repositories in this Mac's dev
update registry (lib/dev-update-registry.js, a file each Mac keeps for itself), and the two built in
organisation hashes of lib/work-names.py. The match is that scanner's own rule (its Matcher): a
whole hyphenated run inside a token, in any letter case. Repository names are matched here although
#1568 left them out of the file scan on purpose; this departs from it for public text only (Dan,
2026-11-02, after a repository name leaked), and the file scan and the send scan are unchanged.

CANNOT TELL IS REFUSED (L98, L345): the visibility unreadable under every account, the list
unreadable, empty or of the wrong shape, the registry unreadable, a body file the command writes from
something it does not show, a body file a gh api call names that cannot be read, a command that
cannot be read but names a judged gh command, and the time budget spent. No registry at all is fine.

The refusal names the name it matched. It goes only to the session, which already holds the command
text the name is in; it is never written to a file or a log.

No override: the remedy is always open, rewrite the text.

Seams (tests): WORK_NAMES_EXTRA_HASHES and WORK_NAMES_REGISTRY_READER, read by lib/work-names.py;
WN_PUBLISH_BUDGET_SECONDS, the whole run's time for GitHub (35, against a hook timeout of 45).
"""
import importlib.util
import json
import os
import re
import subprocess
import sys
import time

sys.dont_write_bytecode = True
_HERE = os.environ.get("GATE_DIR") or os.path.dirname(os.path.abspath(__file__))


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

# The same list lib/lesson-fanout.sh reads (DIGEST_REPO there).
DIGEST_REPO = "dwright-pennie/repo-digest"
DIGEST_LIST = "repos.json"

KINDS = frozenset(scan.BODY_FILE_COMMANDS | {("pr", "review")})
API_ENDPOINT = re.compile(r"^/?repos/([^/\s]+)/([^/\s?#]+)/(?:issues|pulls|comments)(?:[/?#]|$)")
PLACEHOLDER = re.compile(r"^(?:\{owner\}|\{repo\}|:owner|:repo)$")
CRUDE_API = re.compile(r"\bgh\b[^\n]*\bapi\b[^\n]*repos/\S*/(?:issues|pulls|comments)")
BUDGET = float(os.environ.get("WN_PUBLISH_BUDGET_SECONDS") or 35)
STARTED = time.monotonic()

HEAD = "WORK NAME IN PUBLIC TEXT"
REMEDY = ("Scrub it: rewrite the text without the work organisation or repository (say \"a work "
          "repository\"), then run the command again. Public pull requests, issues and comments never "
          "name work organisations or repositories (claude-config#2105).")


class CannotTell(Exception):
    """Something the verdict needs could not be read; the message says what."""


def _left():
    return BUDGET - (time.monotonic() - STARTED)


def _gh(args, cwd=None, token=None, extra_env=None):
    """-> (ok, stdout, stderr). token None runs gh as the command would, with the inherited account."""
    left = _left()
    if left <= 1:
        raise CannotTell("GitHub did not answer within this gate's %d second budget" % BUDGET)
    env = dict(os.environ)
    env.update(extra_env or {})
    if token is not None:
        env["GH_TOKEN"] = token
    try:
        p = subprocess.run(["gh"] + args, cwd=cwd if cwd and os.path.isdir(cwd) else None, env=env,
                           capture_output=True, text=True, errors="replace", timeout=min(15, left))
    except FileNotFoundError:
        raise CannotTell("gh is not on PATH")
    except subprocess.TimeoutExpired:
        return False, "", "gh did not answer within %d seconds" % min(15, left)
    return p.returncode == 0, p.stdout, p.stderr.strip()


_TOKENS = []


def _tokens():
    """None (the inherited account) first, then each signed in account's token, active first; lazily."""
    yield None
    if not _TOKENS:
        ok, out, _ = _gh(["auth", "status", "--json", "hosts"])
        accounts = []
        try:
            hosts = json.loads(out).get("hosts", {}).get("github.com", []) if ok else []
            hosts = sorted(hosts, key=lambda h: 0 if h.get("active") else 1)
            accounts = [h.get("login") for h in hosts if h.get("state") == "success" and h.get("login")]
        except (ValueError, AttributeError):
            accounts = []
        for login in accounts:
            ok, tok, _ = _gh(["auth", "token", "--hostname", "github.com", "-u", login])
            if ok and tok.strip():
                _TOKENS.append(tok.strip())
        _TOKENS.append("")  # marks the list as built, even when empty
    for tok in _TOKENS:
        if tok:
            yield tok


_VIS = {}


def visibility(slug, cwd, gh_repo):
    """-> (nameWithOwner, visibility) of the repository a command posts to, or raises CannotTell."""
    key = (slug, cwd if not slug else None, gh_repo)
    if key in _VIS:
        return _VIS[key]
    args = ["repo", "view"] + ([slug] if slug else []) + ["--json", "nameWithOwner,visibility"]
    extra = {"GH_REPO": gh_repo} if gh_repo and not slug else None
    last = ""
    for tok in _tokens():
        ok, out, err = _gh(args, cwd, tok, extra)
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
    if _NAMES:
        return _NAMES[0]
    raw, last = None, ""
    for tok in _tokens():
        ok, out, err = _gh(["api", "-H", "Accept: application/vnd.github.raw",
                            "repos/%s/contents/%s" % (DIGEST_REPO, DIGEST_LIST)], None, tok)
        if ok:
            raw = out
            break
        last = err or last
    if raw is None:
        raise CannotTell("the work repository list (%s in %s) could not be read with any signed in "
                         "account (%s), so the text could not be checked" % (DIGEST_LIST, DIGEST_REPO, last[:200]))
    try:
        repos = json.loads(raw).get("repos")
    except (ValueError, AttributeError):
        repos = None
    if not isinstance(repos, list) or not all(
            isinstance(r, dict) and isinstance(r.get("owner"), str) and isinstance(r.get("name"), str)
            and r["owner"].strip() and r["name"].strip() for r in repos):
        raise CannotTell("the work repository list (%s in %s) is not a \"repos\" list of owner and name "
                         "entries, so the text could not be checked" % (DIGEST_LIST, DIGEST_REPO))
    if not repos:
        raise CannotTell("the work repository list (%s in %s) lists no repositories, and an empty list "
                         "is never read as clean" % (DIGEST_LIST, DIGEST_REPO))
    pairs = [(r["owner"].strip().lower(), r["name"].strip().lower()) for r in repos]
    state, where, why, reg = wn.registry_entries()
    if state == "unreadable":
        raise CannotTell("this Mac's dev update registry could not be read (%s), so its names could not "
                         "be checked" % why)
    for full in reg if state == "ok" else []:
        owner, _, name = full.strip().lower().partition("/")
        if owner:
            pairs.append((owner, name))
    owners = {o for o, _ in pairs}
    every = owners | {n for _, n in pairs if n}
    plain = {n for n in every if wn.TOKEN.fullmatch(n)}
    odd = sorted(every - plain)
    _NAMES.append((wn.Matcher(wn.BUILT_IN | wn.extra_hashes(), set(), plain), owners, odd))
    return _NAMES[0]


def find(text, matcher, odd):
    """The first listed name the text holds, or None."""
    low = (text or "").lower()
    for token in wn.TOKEN.findall(low):
        hit = matcher.match(token)
        if hit:
            return hit[1]
    for n in odd:
        if re.search(r"(?<![a-z0-9])%s(?![a-z0-9])" % re.escape(n), low):
            return n
    return None


def _env_value(name, envs, place):
    for w in reversed(envs or []):
        if w.startswith(name + "="):
            return w.split("=", 1)[1]
    if place is not None:
        if place.vars.get(name):
            return place.vars[name]
        return (place.environ or {}).get(name) or None
    return os.environ.get(name) or None


def judge(what, slug, cwd, gh_repo, command, bodies):
    """None when it may post, else the reason. bodies: [(shown as, text or None when hidden)]."""
    full, vis = visibility(slug, cwd, gh_repo)
    if vis != "PUBLIC":
        return None
    matcher, owners, odd = names()
    owner = full.split("/", 1)[0].lower()
    if owner in owners or wn.sha(owner) in matcher.hashes:
        return None
    hit = find(command, matcher, odd)
    if hit:
        return "%s posts to %s, a public repository, and its text names `%s`." % (what, full, hit)
    for shown, text in bodies:
        if text is None:
            return ("%s posts to %s, a public repository, from %s, which this command writes from "
                    "something it does not show, so whether it names a work organisation or repository "
                    "cannot be told. Write the body with a heredoc in the command, or to a file first."
                    % (what, full, shown))
        hit = find(text, matcher, odd)
        if hit:
            return "%s posts to %s, a public repository, and %s names `%s`." % (what, full, shown, hit)
    return None


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
    """Each gh api write to an issues, pulls or comments endpoint, as (slug or None, bodies)."""
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
            bodies = [("the file %s" % p, _read(p, cwd)) for p in files if p != "-"]
            out.append((slug, bodies))
    return out


def evaluate(command, cwd):
    """-> [reasons]. Raises nothing: what cannot be told is a reason."""
    reasons = []
    try:
        found = scan.scan_gh_in_context(command, cwd, dict(os.environ), KINDS)
        apis = api_writes(command, cwd) if re.search(r"\bapi\b", command) else []
    except scan.Unreadable as e:
        named = scan.gated_in_text(command, KINDS) or CRUDE_API.search(command or "")
        if named:
            return ["this command could not be read (%s), and it names a gh command that posts text, so "
                    "whether that text names a work organisation or repository cannot be told." % e]
        return []
    for kind, args, envs, place in found:
        what = "gh %s %s" % kind
        try:
            slugs = scan.flag_values(args, "--repo", "-R")
            slug = slugs[-1] if slugs else None
            gh_repo = None if slug else _env_value("GH_REPO", envs, place)
            bodies = []
            for word, state, detail in field.body_files(args, command, place):
                if state == "hidden":
                    bodies.append(("--body-file %s" % word, None))
                elif state == "text":
                    bodies.append(("--body-file %s" % word, detail))
            why = judge(what, slug, place.cwd or place.start or cwd, gh_repo, command, bodies)
        except CannotTell as e:
            why = "%s: %s." % (what, e)
        if why and why not in reasons:
            reasons.append(why)
    for slug, bodies in apis:
        try:
            why = judge("gh api", slug, cwd, None, command, bodies)
        except CannotTell as e:
            why = "gh api: %s." % e
        if why and why not in reasons:
            reasons.append(why)
    return reasons


def main():
    raw = sys.stdin.buffer.read().decode("utf-8", "replace")
    try:
        data = json.loads(raw)
    except ValueError:
        # A payload nothing can parse: refused when its text plainly runs a judged command.
        if scan.gated_in_text(raw, KINDS) or CRUDE_API.search(raw):
            json.dump(scan.deny_payload("%s: this hook's input could not be read, and it names a gh "
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
