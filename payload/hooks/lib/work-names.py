#!/usr/bin/env python3
"""Find the work GitHub organisations named in files this public repository publishes.

claude-config#1568. The work's private repositories live under two GitHub organisations, and this
repository is public. A name like that, written as an owner, a URL, a fixture or a lesson's
provenance, tells a stranger exactly where to look. This is the one scanner for it. Its fixtures are
held by hooks/test-work-names.sh. tests/test-work-names-tree.sh runs it over the whole tree (before
every push and in CI), and claude-sync's scan_work_names runs it over what a send is about to
publish, so a name written on a Mac is refused before it is published, not found afterwards (L280).

WHAT COUNTS AS A NAME. An organisation login, in any letter case, wherever it stands as a whole
hyphenated run inside a token: an owner (`<org>/repo`), a URL, a fixture file name before an
underscore, or the tail of a longer login that contains it. Two sources:

  built in   the two work organisations, held ONLY as sha256 hashes of their lower case logins, so
             this file does not itself publish what it guards (and a grep for them finds nothing
             here). This is all CI can check, because CI has no registry.
  registry   the owner of every repository in this Mac's dev update registry, read through its one
             reader (dev-update-registry.js repos), so an organisation added there is guarded on
             that Mac from the next scan. A Mac with no registry is said, never read as empty; an
             unreadable one is refused.

WHAT DOES NOT. A product or repository name on its own (a lesson's `name#123`, a checkout folder, a
product named in prose): without the organisation it locates nothing, it is the vocabulary hundreds
of lessons are written in, and `name#N` is what lesson-fanout.sh parses to skip the repository a
lesson came from. The same login without its hyphen is a different GitHub account, and the
company's public web domain, so it is not one either (in published text it is matched as a domain
only, see TWO MORE SOURCES below, claude-config#2184). These are decisions recorded on #1568's pull
request, not omissions, and they still hold for files, save the two published documents (THE TWO
PUBLISHED DOCUMENTS below, claude-config#2252). The other exceptions are text that is published
without being a file: the publish gate (work_names_publish_gate.py, claude-config#2105) checks public
pull request and issue text against the work repository names as well, and --work-repos does the
same for commit messages (claude-config#2111, below). Both read the list through work_repo_names
here, the one reader.

NOTHING PRINTED REPEATS A NAME FOUND. A hit is reported as path:line and which source matched. CI
logs of a public repository are public, and a refusal message is read in transcripts.

TEXT THAT IS NOT A FILE (claude-config#1995). This repository squash merges with the commit
messages as the body, so a commit message reaches main without ever being a file, and a pull
request's title and description are published beside it. --texts0-from reads them as a NUL
separated stream of label, text, label, text (a final NUL ends the stream and is optional; an empty
text is a text), which `git log -z --format='commit %h%x00%B'` writes as it stands. A hit is the
label and the line, by the same rule and in the same words as a file's. scanners-before-push.sh asks
it about the messages of the commits a push adds, and check-work-names-merge.sh about a pull
request's title, description and commit messages before it merges.

WORK REPOSITORIES IN MESSAGES (claude-config#2111). A squash merge publishes every commit message in
main, so a message naming a work repository is as public as one naming its organisation. With
--work-repos the text scan also matches every owner and repository in the work repository list
(read live through gh, never written to disk, refused when it cannot be read, is empty or is of the
wrong shape) and in this Mac's dev update registry, in plain prose as well as owner/name#N. Both
callers above pass it. The file scan never takes it (#1568).

TWO MORE SOURCES FOR PUBLISHED TEXT (claude-config#2184). The #2110 scrub found work names that
neither the list nor the registry holds, so --work-repos and the publish gate also take:
  projects   every project folder on the work MacBook's project list, the "On Dans-MacBook-Pro"
             block of the Projects section in the global CLAUDE.md (read by work_mac_projects, two
             directories above this file both in the repository and installed). Since #2112 that
             block lists none in the public file, so the names are matched through WORK_PROJECTS,
             their sha256 hashes, built and matched as BUILT_IN is, and taken whenever the block
             itself lists no project; where the block imports projects.local.txt and that file is
             beside the CLAUDE.md (the work MacBook only), its entries are matched too. A CLAUDE.md
             that cannot be read or has no such section or block is refused, and so is a list
             yielding neither a name nor a hash.
  domains    a built in organisation's login without its hyphens, which is its web and email domain,
             matched only as a domain: after an @, or before a dot and a top level domain. As a bare
             word it stays prose, as #1568 decided, since the same letters can be an ordinary word.
             A project folder that is such a login is a project all the same, and is refused as a
             plain word as every project is (claude-config#2190).

THE TWO PUBLISHED DOCUMENTS (claude-config#2252). README.md and DESIGN.md at the root are the manual
and the design record, read by strangers before anything else, and once named the work MacBook's
projects in dated anecdotes. The file scan holds those two, and only those, to WORK_PROJECTS and to
the domain rule as well, so a new mention there is refused by the tree suite (before every push and
in CI) rather than found by a sweep. It uses the committed hashes only, never the live list or this
Mac's projects.local.txt, so CI judges them exactly as a Mac does. Every other file keeps #1568's rule.

Usage:
  work-names.py [--root DIR] [--files0-from FILE|-] [PATH ...]
  work-names.py --texts0-from FILE|- [--work-repos]   labelled text, as above, in place of files
  work-names.py --uncovered-owners     registry owners the built in hashes do not cover
Exit: 0 clean; 1 at least one name found (each listed); 2 could not judge (a listed file could not
be read, a text stream held a label with no text, the registry could not be read, or node is missing
to read it; with --work-repos also the list unreadable or its time budget spent).

Seams (tests): WORK_NAMES_EXTRA_HASHES, comma separated sha256 hex of more lower case logins.
WORK_NAMES_REGISTRY_READER, the reader to ask (default: dev-update-registry.js beside this file).
Both are honoured only under HOOK_TESTS_RUNNING=1 (claude-config#2231), as below.
WORK_NAMES_REPOS_BUDGET_SECONDS, the whole --work-repos run's time for GitHub (default 30).
WORK_NAMES_PROJECT_LIST, the CLAUDE.md to read the work MacBook's project list from.
WORK_NAMES_PROJECT_HASHES, comma separated sha256 hex replacing WORK_PROJECTS (empty means none),
honoured only under HOOK_TESTS_RUNNING=1, so no real run can empty the committed set.
"""
import hashlib
import json
import os
import re
import subprocess
import sys
import time

BUILT_IN = {
    "91bb8dd6329de4f774a80b5431e2eaa984575662c24063fd0e6672a0c8d6fc2b",  # the work organisation
    "1c166f0036586d4969300ad3475ac491b1f7f09459cb89882da389836bd820af",  # the agency organisation that holds the website
}
# The work MacBook's project folders (claude-config#2112), held ONLY as sha256 hashes of their lower
# case names, as BUILT_IN holds the organisations, since the public CLAUDE.md no longer lists them.
# Built from the last CLAUDE.md block that did, by the same reading work_mac_projects does, every
# folder included: the one spelled as an organisation's login without its hyphens is a project too,
# refused as a plain word as well as a domain (claude-config#2190). tests/test-work-names-tree.sh
# checks this set against that block in history.
WORK_PROJECTS = {
    "305788032b694143d7dfcf4dd1225d397186663127ecd2f0b3246200344a42bc",  # a work MacBook project
    "5d093d8dbf4080f6854ad3c1f6249e765160cf6825defc6a63be240afa75adee",  # a work MacBook project
    "b62f3b3b1b40cb86438bf4d2affd121f9518814e713d3df7d4c193b2168f28fc",  # a work MacBook project
    "bbba57318f71911354fdaab5d67ea8c352bfe113231e968a9ac1f4cf5b38e546",  # a work MacBook project
    "d6386c59a6bcfcb1e4ced6beeb4594757afaa891ac805388076d0c83d2f5260a",  # a work MacBook project
    "eb54300f6828b72efe018d2575f8189ebcc6e0f152afa14d00c6a7382de14171",  # a work MacBook project
}
# The two documents at the root a stranger reads first, which the file scan holds to the hashed
# projects and the domains as well (claude-config#2252), as paths relative to the root.
PUBLISHED_DOCS = ("README.md", "DESIGN.md")
TOKEN = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*")
# The one remedy, said the same for a file and for a message (claude-config#1995).
REMEDY = ("Replace the organisation with an invented one in a fixture, or drop it from prose and "
          "provenance (write name#123, never owner/name#123).")
# The remedy once messages are checked against the work repository list too (claude-config#2111),
# where name#123 is itself a hit.
REPO_REMEDY = ("Rewrite it without the work organisation or repository: say \"a work repository\", and "
               "never write owner/name#123 or name#123 for one.")
# The work repository list: the same one lib/lesson-fanout.sh reads (DIGEST_REPO there), read live
# through gh and never written to disk (claude-config#2105, #2111).
DIGEST_REPO = "dwright-pennie/repo-digest"
DIGEST_LIST = "repos.json"
HERE =os.path.dirname(os.path.abspath(__file__))
# The work MacBook's project list (claude-config#2184): its block in the Projects section of the
# global CLAUDE.md, named by the hostname the section uses for it.
WORK_MAC = "Dans-MacBook-Pro"
PROJECTS_SECTION = re.compile(r"^## Projects[ \t]*$(.*?)(?=^## |\Z)", re.M | re.S)
WORK_BLOCK = re.compile(r"^On %s(?: \([^)\n]*\))?:[ \t]*\n((?:[ \t]*\n)*(?:- .*(?:\n|\Z))*)"
                        % re.escape(WORK_MAC), re.M)
ENTRY = re.compile(r"^- `([^`]+)`", re.M)
# The work MacBook's own list (claude-config#2112): a block importing it inside a sentence means the
# file of that name beside the CLAUDE.md read, which exists on that Mac only.
LOCAL_IMPORT = re.compile(r"\S @projects\.local\.txt")
LOCAL_LIST = "projects.local.txt"
# A word written as a domain: after an @, or before a dot and a top level domain, never inside a
# longer hyphenated run (that run is the Matcher's). 39 is GitHub's longest login.
DOMAIN_AT = re.compile(r"@([a-z0-9]{2,39})(?![a-z0-9-])")
DOMAIN_DOT = re.compile(r"(?<![a-z0-9-])(?=([a-z0-9]{2,39})\.[a-z]{2,}(?![a-z0-9-]))")


def sha(s):
    return hashlib.sha256(s.encode("utf-8", "surrogatepass")).hexdigest()


def under_test():
    """True only under the hooks' own test runner, which exports HOOK_TESTS_RUNNING=1 to every suite
    (run-all-tests.sh). The gates that ask this scanner read Claude Code's own environment, so every
    test setting here is honoured only with it (claude-config#2217, #2231)."""
    return os.environ.get("HOOK_TESTS_RUNNING") == "1"


def extra_hashes():
    raw = os.environ.get("WORK_NAMES_EXTRA_HASHES", "") if under_test() else ""
    return {h.strip().lower() for h in raw.split(",") if h.strip()}


def project_hashes():
    """The hashed work MacBook projects: WORK_PROJECTS, or in a test run only (HOOK_TESTS_RUNNING=1)
    the comma separated WORK_NAMES_PROJECT_HASHES when it is set, where empty means none."""
    if under_test() and "WORK_NAMES_PROJECT_HASHES" in os.environ:
        raw = os.environ["WORK_NAMES_PROJECT_HASHES"]
        return {h.strip().lower() for h in raw.split(",") if h.strip()}
    return set(WORK_PROJECTS)


def hyphenless(word, hashes):
    """True when word is a hashed login with its one or two hyphens taken out (claude-config#2184)."""
    n = len(word)
    for i in range(1, n):
        if sha(word[:i] + "-" + word[i:]) in hashes:
            return True
        for j in range(i + 1, n):
            if sha(word[:i] + "-" + word[i:j] + "-" + word[j:]) in hashes:
                return True
    return False


def registry_entries(timeout=60):
    """-> (state, file, why, ["owner/name", ...]) from this Mac's dev update registry, never exiting.

    state is ok, missing or unreadable, as dev-update-registry.js says it; unreadable also covers a
    reader that could not be run or did not answer in JSON, why saying which. The scan below and the
    publish gate (work_names_publish_gate.py, claude-config#2105) both read the registry through it;
    the gate passes what is left of its own time budget as timeout.
    """
    # A reader named in the environment, which could answer "nothing registered" on every real run,
    # is asked only under test (claude-config#2231).
    reader = (under_test() and os.environ.get("WORK_NAMES_REGISTRY_READER")) or os.path.join(HERE, "dev-update-registry.js")
    try:
        p = subprocess.run(["node", reader, "repos"], capture_output=True, text=True, timeout=timeout, errors="replace")
    except FileNotFoundError:
        return ("unreadable", None, "node is not on PATH, so this Mac's dev update registry could not be "
                "read", [])
    except subprocess.TimeoutExpired:
        return ("unreadable", None, "reading the dev update registry took over %d seconds" % timeout, [])
    try:
        got = json.loads(p.stdout)
        state = got.get("state")
    except (ValueError, AttributeError):
        return ("unreadable", None, "the dev update registry reader (%s) answered with something that is "
                "not JSON: %s" % (reader, (p.stdout + p.stderr).strip()[:300]), [])
    repos = [r for r in (got.get("repos") or []) if isinstance(r, str)]
    return (state if state in ("ok", "missing") else "unreadable", got.get("file"), got.get("why", ""), repos)


def read_registry():
    """-> (owners, sentence) or raises SystemExit(2) with the reason said."""
    state, where, why, repos = registry_entries()
    if state == "missing":
        return set(), ("there is no dev update registry on this Mac (%s), so only the two built in "
                       "work organisation names were checked" % where)
    if state != "ok":
        if where is None:
            die(why + ", and its owners could not be checked.")
        die("the dev update registry could not be read, so its owners could not be checked: %s" % why)
    owners = set()
    for full in repos:
        owner = full.split("/", 1)[0].strip().lower()
        if owner:
            owners.add(owner)
    return owners, ("the two built in work organisation names and %d owner%s from %s"
                    % (len(owners), "" if len(owners) == 1 else "s", where))


def die(msg):
    sys.stderr.write("work-names: " + msg + "\n")
    sys.exit(2)


# ------------------------------------------------------------------ the work repository list
# One reader, shared by the publish gate (work_names_publish_gate.py, #2105) and the message checks
# (--work-repos below, #2111), so the two can never read the list by different rules.

class CannotTell(Exception):
    """Something the verdict needs could not be read; the message says what."""


class GitHub:
    """gh, run under one time budget for a whole run, through each signed in account in turn."""

    def __init__(self, budget, who="this gate"):
        self.budget = float(budget)
        self.who = who
        self.started = time.monotonic()
        self._tokens = []

    def left(self):
        return self.budget - (time.monotonic() - self.started)

    def run(self, argv, cwd=None, token=None, extra_env=None):
        """argv is the whole gh command, gh first. -> (ok, stdout, stderr). token None runs gh as the command would, with the inherited account."""
        left = self.left()
        if left <= 1:
            raise CannotTell("GitHub did not answer within %s's %d second budget" % (self.who, self.budget))
        env = dict(os.environ)
        env.update(extra_env or {})
        if token is not None:
            env["GH_TOKEN"] = token
        try:
            p = subprocess.run(argv, cwd=cwd if cwd and os.path.isdir(cwd) else None, env=env,
                               capture_output=True, text=True, errors="replace", timeout=min(15, left))
        except FileNotFoundError:
            raise CannotTell("gh is not on PATH")
        except subprocess.TimeoutExpired:
            return False, "", "gh did not answer within %d seconds" % min(15, left)
        return p.returncode == 0, p.stdout, p.stderr.strip()

    def tokens(self):
        """None (the inherited account) first, then each signed in account's token, active first; lazily."""
        yield None
        if not self._tokens:
            ok, out, _ = self.run(["gh", "auth", "status", "--json", "hosts"])
            accounts = []
            try:
                hosts = json.loads(out).get("hosts", {}).get("github.com", []) if ok else []
                hosts = sorted(hosts, key=lambda h: 0 if h.get("active") else 1)
                accounts = [h.get("login") for h in hosts if h.get("state") == "success" and h.get("login")]
            except (ValueError, AttributeError):
                accounts = []
            for login in accounts:
                ok, tok, _ = self.run(["gh", "auth", "token", "--hostname", "github.com", "-u", login])
                if ok and tok.strip():
                    self._tokens.append(tok.strip())
            self._tokens.append("")  # marks the list as built, even when empty
        for tok in self._tokens:
            if tok:
                yield tok


def work_mac_projects():
    """-> ([lower case folder name], {sha256 of one}) for the work MacBook's projects, or raises
    CannotTell (claude-config#2184). The names are the block's entries and, when the block imports
    that Mac's projects.local.txt, that file's entries where it exists; the hashes are
    project_hashes(), taken when the block itself lists no project (claude-config#2112). Never both
    empty: a list with no project is refused, never clean."""
    path = os.environ.get("WORK_NAMES_PROJECT_LIST") or os.path.normpath(
        os.path.join(HERE, "..", "..", "CLAUDE.md"))
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError as e:
        raise CannotTell("the work MacBook's project list (the Projects section of %s) could not be "
                         "read (%s), so its projects could not be checked" % (path, e.strerror or e))
    section = PROJECTS_SECTION.search(text)
    if not section:
        raise CannotTell("%s has no '## Projects' section, so the work MacBook's project list could "
                         "not be read and its projects could not be checked" % path)
    block = WORK_BLOCK.search(section.group(1))
    if not block:
        raise CannotTell("the Projects section of %s has no 'On %s:' block, so the work MacBook's "
                         "project list could not be read and its projects could not be checked"
                         % (path, WORK_MAC))
    names = []

    def add(entries):
        for entry in entries:
            name = os.path.basename(entry.strip().rstrip("/")).strip().lower()
            if name and name not in names:
                names.append(name)

    add(ENTRY.findall(block.group(1)))
    hashes = set() if names else project_hashes()
    if LOCAL_IMPORT.search(block.group(1)):
        local = os.path.join(os.path.dirname(path), LOCAL_LIST)
        try:
            with open(local, encoding="utf-8", errors="replace") as fh:
                add(ENTRY.findall(fh.read()))
        except FileNotFoundError:
            pass
        except OSError as e:
            raise CannotTell("the work MacBook's own project list (%s) is there but could not be read "
                             "(%s), so its projects could not be checked" % (local, e.strerror or e))
    if not names and not hashes:
        raise CannotTell("the work MacBook's project list in %s lists no project, and an empty project "
                         "list is never read as clean" % path)
    return names, hashes


def work_repo_names(github):
    """-> (Matcher, work owners, odd names) from the work repository list, this Mac's dev update
    registry and the work MacBook's project list, or raises CannotTell. Odd names are those that are
    not one plain token (a dot in them), which the Matcher cannot hold and odd_hit finds instead. The
    Matcher also finds an organisation's domain (claude-config#2184)."""
    projects, hashed_projects = work_mac_projects()
    raw, last = None, ""
    for tok in github.tokens():
        ok, out, err = github.run(["gh", "api", "-H", "Accept: application/vnd.github.raw",
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
    state, where, why, reg = registry_entries(timeout=max(1, int(github.left())))
    if state == "unreadable":
        raise CannotTell("this Mac's dev update registry could not be read (%s), so its names could not "
                         "be checked" % why)
    for full in reg if state == "ok" else []:
        owner, _, name = full.strip().lower().partition("/")
        if owner:
            pairs.append((owner, name))
    owners = {o for o, _ in pairs}
    every = owners | {n for _, n in pairs if n}
    hashes = BUILT_IN | extra_hashes()
    # Every project folder is a name, the one spelled as an organisation's login without its hyphens
    # included: it is a work project, so it is refused as a plain word too, not only as a domain
    # (claude-config#2190, reversing #2184 for project folders only).
    every |= set(projects)
    plain = {n for n in every if TOKEN.fullmatch(n)}
    odd = sorted(every - plain)
    return Matcher(hashes, set(), plain, domains=True, project_hashes=hashed_projects), owners, odd


def odd_hit(text, odd):
    """The first odd name (see work_repo_names) the lower case text holds as a whole word, or None."""
    for n in odd:
        if re.search(r"(?<![a-z0-9])%s(?![a-z0-9])" % re.escape(n), text):
            return n
    return None


class Matcher:
    """names: further lower case names matched by the same rule, beside the owners. The tree scan and
    the send scan never pass any; work_repo_names passes the work repository names, for the publish gate
    (claude-config#2105) and --work-repos (#2111), which depart from #1568 for text that is published
    without being a file, see DESIGN.md. domains: also find a hashed login without its hyphens
    written as a domain (claude-config#2184), passed by work_repo_names and, among files, for
    README.md and DESIGN.md at the root only (claude-config#2252), never for any other file.
    project_hashes: sha256 of further names matched as names are (the hashed work MacBook projects,
    claude-config#2112), kept apart from hashes, which the publish gate reads as organisations."""

    def __init__(self, hashes, owners, names=frozenset(), domains=False, project_hashes=frozenset()):
        self.hashes = hashes
        self.owners = owners
        self.names = names
        self.domains = domains
        self.project_hashes = project_hashes
        self.cache = {}

    def domain(self, text):
        """None, or the first word the lower case text writes as a domain (after an @, or before a
        dot and a top level domain) that is a hashed login without its hyphens."""
        if not self.domains:
            return None
        for rx in (DOMAIN_AT, DOMAIN_DOT):
            for word in rx.findall(text):
                key = ("domain", word)
                if key not in self.cache:
                    self.cache[key] = hyphenless(word, self.hashes)
                if self.cache[key]:
                    return word
        return None

    def kind(self, token):
        """None, or which source a token's runs match: every contiguous run of its hyphen parts."""
        found = self.match(token)
        return found[0] if found else None

    def match(self, token):
        """None, or (source, run): the first contiguous run of the token's hyphen parts that matches."""
        if token in self.cache:
            return self.cache[token]
        found = None
        parts = token.split("-")
        n = len(parts)
        for i in range(n):
            for j in range(i + 1, n + 1):
                run = "-".join(parts[i:j])
                if sha(run) in self.hashes:
                    found = ("a work organisation name", run)
                    break
                if run in self.owners:
                    found = ("a name from this Mac's dev update registry", run)
                    break
                if run in self.names or (self.project_hashes and sha(run) in self.project_hashes):
                    found = ("a work repository or owner name", run)
                    break
            if found:
                break
        self.cache[token] = found
        return found


def scan_file(path, shown, matcher, hits):
    with open(path, "rb") as fh:
        data = fh.read()
    if b"\0" in data[:8192]:
        return
    scan_text(data.decode("utf-8", errors="replace"), shown, matcher, hits)


def scan_text(text, shown, matcher, hits, odd=()):
    """One file's or one message's text: a hit is `shown:line: source`, never the text itself. odd:
    listed names that are not one plain token (work_repo_names), found by odd_hit line by line."""
    text = text.lower()
    tokens = set(TOKEN.findall(text))
    if not any(matcher.kind(t) for t in tokens) and not odd_hit(text, odd) and not matcher.domain(text):
        return
    for no, line in enumerate(text.splitlines(), 1):
        k = next((matcher.kind(t) for t in TOKEN.findall(line) if matcher.kind(t)), None)
        if not k and odd_hit(line, odd):
            k = "a work repository or owner name"
        if not k and matcher.domain(line):
            k = "a work organisation's web or email domain"
        if k:
            hits.append("%s:%d: %s" % (shown, no, k))


def main(argv):
    root = None
    files = []
    i = 0
    uncovered = False
    repos = False
    texts = None
    while i < len(argv):
        a = argv[i]
        if a == "--root":
            root = argv[i + 1]; i += 2; continue
        if a == "--files0-from":
            src = argv[i + 1]
            raw = sys.stdin.buffer.read() if src == "-" else open(src, "rb").read()
            files.extend(p.decode("utf-8", errors="surrogateescape") for p in raw.split(b"\0") if p)
            i += 2; continue
        if a == "--texts0-from":
            src = argv[i + 1]
            raw = sys.stdin.buffer.read() if src == "-" else open(src, "rb").read()
            texts = read_texts(raw)
            i += 2; continue
        if a == "--uncovered-owners":
            uncovered = True; i += 1; continue
        if a == "--work-repos":
            repos = True; i += 1; continue
        files.append(a); i += 1

    if repos:
        if texts is None or uncovered:
            die("--work-repos is for messages only, so it is used only with --texts0-from: the file scan "
                "never reads the work repository list (claude-config#1568).")
        if isinstance(texts, str):
            die("the text stream could not be read: %s, so its messages could not be checked." % texts)
        budget = os.environ.get("WORK_NAMES_REPOS_BUDGET_SECONDS") or 30
        try:
            matcher, owners, odd = work_repo_names(GitHub(budget, "the work name check"))
        except (CannotTell, ValueError) as e:
            die("%s. A message that cannot be checked is not a clean one." % e)
        hits = []
        for label, text in texts:
            scan_text(text, label, matcher, hits, odd)
        sentence = ("the work organisation names and domains and %d work repository and owner names "
                    "from the work repository list, this Mac's dev update registry and the work "
                    "MacBook's project list" % (len(matcher.names) + len(odd) + len(matcher.project_hashes)))
        return report(hits, [], len(texts), "message", sentence, REPO_REMEDY)

    owners, sentence = read_registry()
    if uncovered:
        missing = sorted(o for o in owners if sha(o) not in BUILT_IN)
        if "no dev update registry" in sentence:
            print(sentence)
            return 0
        if missing:
            print("%d owner%s in this Mac's dev update registry %s not covered by the built in names, "
                  "so CI, which has no registry, cannot see %s. Add the sha256 of each lower case "
                  "login to BUILT_IN in %s." % (len(missing), "" if len(missing) == 1 else "s",
                                                 "is" if len(missing) == 1 else "are",
                                                 "it" if len(missing) == 1 else "them", __file__))
            return 1
        print("every owner in this Mac's dev update registry is covered by the built in names")
        return 0

    matcher = Matcher(BUILT_IN | extra_hashes(), owners)
    # README.md and DESIGN.md at the root also match the hashed projects and the domains (#2252).
    projects = frozenset(project_hashes())
    docs = Matcher(BUILT_IN | extra_hashes(), owners, domains=True, project_hashes=projects)
    hits = []
    unreadable = []
    if texts is not None:
        if isinstance(texts, str):
            die("the text stream could not be read: %s, so its messages could not be checked." % texts)
        for label, text in texts:
            scan_text(text, label, matcher, hits)
        return report(hits, [], len(texts), "message", sentence)
    saw_doc = False
    for f in files:
        path = os.path.join(root, f) if root and not os.path.isabs(f) else f
        if os.path.isdir(path):
            continue
        doc = published_doc(f, root)
        saw_doc = saw_doc or doc
        try:
            scan_file(path, f, docs if doc else matcher, hits)
        except OSError as e:
            unreadable.append("%s (%s)" % (f, e.strerror or e))
    if saw_doc:
        sentence += (", and %d hashed work MacBook project%s in %s, with the work organisations' web "
                     "and email domains" % (len(projects), "" if len(projects) == 1 else "s",
                                            " and ".join(PUBLISHED_DOCS)))
    return report(hits, unreadable, len(files), "file", sentence)


def published_doc(f, root):
    """True when the listed file is README.md or DESIGN.md at the root (claude-config#2252)."""
    rel = os.path.relpath(f, root) if root and os.path.isabs(f) else f
    return os.path.normpath(rel) in PUBLISHED_DOCS


def read_texts(raw):
    """-> [(label, text)], or a str saying why the stream cannot be read."""
    parts = raw.split(b"\0")
    if raw.endswith(b"\0"):
        parts.pop()
    if len(parts) % 2:
        return ("it ended on a label with no text (%d fields), which is a stream cut short or a NUL "
                "inside a text" % len(parts))
    dec = [p.decode("utf-8", errors="replace") for p in parts]
    return list(zip(dec[0::2], dec[1::2]))


def report(hits, unreadable, n, noun, sentence, remedy=REMEDY):
    for h in hits:
        print(h)
    summary = "work-names: checked %d %s%s for %s" % (n, noun, "" if n == 1 else "s", sentence)
    if unreadable:
        sys.stderr.write(summary + ". Could not read: " + "; ".join(unreadable)
                         + ". A listed file that cannot be read is not a clean one.\n")
        return 2
    if hits:
        sys.stderr.write(summary + ". %d line%s name%s one. %s\n" % (
            len(hits), "" if len(hits) == 1 else "s", "s" if len(hits) == 1 else "", remedy))
        return 1
    sys.stderr.write(summary + ": none found.\n")
    return 0


if __name__ == "__main__":
    sys.stdout.reconfigure(errors="replace")
    sys.exit(main(sys.argv[1:]))
