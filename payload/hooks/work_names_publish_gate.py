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
a script that rewrites PATH, curl or an API library, and gh extensions.

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


def _without_guard(path):
    """PATH without the guard on gh (bin/gh, claude-config#2183), so the gh this gate runs for its own
    reads is the real one: through the guard, every one of them would start this gate again."""
    guard = os.path.realpath(os.path.join(_HERE, "bin"))
    return ":".join(d for d in (path or "").split(":") if d and os.path.realpath(d) != guard)


os.environ["PATH"] = _without_guard(os.environ.get("PATH"))


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
          "repository\"), then run the command again. Public pull requests, issues and comments never "
          "name work organisations or repositories (claude-config#2105).")


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
        return "%s posts to %s, a public repository, and its text names %s." % (what, full, _shown(hit))
    for shown, text in bodies:
        if text is None:
            return ("%s posts to %s, a public repository, from %s, which this command writes from "
                    "something it does not show, so whether it names a work organisation or repository "
                    "cannot be told. Write the body with a heredoc in the command, or to a file first."
                    % (what, full, shown))
        hit = find(text, matcher, odd)
        if hit:
            return "%s posts to %s, a public repository, and %s names %s." % (what, full, shown, _shown(hit))
    return None


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


# gh's own top level commands. gh never lets an alias shadow one, so only a first word outside this set
# can be an alias (claude-config#2183). A word missing here is only asked about as an alias, never
# passed unjudged: an alias list that does not hold it means it is not one.
BUILTIN = frozenset("""accessibility agent-task alias api attestation auth browse cache codespace completion
config copilot extension gist gpg-key help issue label licenses org pr preview project release repo
ruleset run search secret ssh-key status variable version workflow""".split())
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
    """-> (alias name, the gh command text it runs) when args (gh's arguments, the program's own name
    left off) run an alias, else None.

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
        return args[0], expansion[1:] + (" " + shlex.join(rest) if rest else "")
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
    return args[0], shlex.join(["gh"] + words + extra)


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
        found = scan.scan_gh_in_context(command, cwd, dict(os.environ), KINDS)
        apis = api_writes(command, cwd) if re.search(r"\bapi\b", command) else []
    except scan.Unreadable as e:
        named = scan.gated_in_text(command, KINDS) or CRUDE_API.search(command or "")
        if named:
            return reasons + ["this command could not be read (%s), and it names a gh command that posts "
                              "text, so whether that text names a work organisation or repository cannot "
                              "be told." % e]
        return reasons
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
    for slug, files in apis:
        try:
            bodies = [("the file %s" % p, _read(p, cwd)) for p in files]
            why = judge("gh api", slug, cwd, None, command, bodies)
        except CannotTell as e:
            why = "gh api: %s." % e
        if why and why not in reasons:
            reasons.append(why)
    return reasons


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
        except CannotTell as e:
            return _refuse("gh %s could be a gh alias, and %s, so what it runs cannot be told."
                           % (judged[0], e))
        reasons = evaluate(got[1] if got else shlex.join(["gh"] + judged), os.getcwd())
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
    os.execv(real, [real] + list(args))


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
        if scan.gated_in_text(raw, KINDS) or CRUDE_API.search(raw):
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
