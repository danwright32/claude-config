#!/usr/bin/env python3
# merge-selector.py: WHICH pull request, and in WHICH repository, the merge a command runs names,
# read from that merge's own words. Run by lib/merge-target.sh (mt__merge_selector), with the
# command in MT_CMD, never as an argument, so nothing in it is ever read as a flag of this script.
#
# It prints ONE line of seven tab separated fields for the FIRST merge the command runs directly:
#
#   repo    the repository it names as owner/name (a host other than github.com kept in front), or
#             empty when it names none, so gh takes the directory's
#   number  the pull request number it names, or empty
#   route   pr (gh pr merge), rest (gh api on a pull request's merge endpoint), graphql (a GraphQL
#             mutation that merges a pull request), untold (a merge whose pull request or repository
#             cannot be read from the command), or empty when it runs none
#   node    for graphql, the pull request's node id the mutation names; GitHub resolves it
#   pin     the commit the merge is pinned to (--match-head-commit, sha=, expectedHeadOid), or empty
#   why     for untold, which part could not be read: doc, spread, noid, many, endpoint, or for a
#             repository flag gh cannot read, repo (a value that is not [HOST/]OWNER/REPO) and norepo
#             (no value at all), claude-config#1186
#   detail  for untold, the words concerned (the endpoint, the file), for the sentence a gate says
#
# One reader for both routes, because gh takes the repository and the number from the one command
# and a gate that reads either without the other asks one repository about another repository's
# pull request (claude-config#470). The gh api routes were added for claude-config#1181: before,
# `gh api -X PUT repos/<o>/<r>/pulls/<n>/merge` and a GraphQL mergePullRequest merged with no gate
# having read anything, while the overnight judge in the scope-modes mod already refused both.
# What counts as a merge through the API is pinned to that judge's own answer by a table both
# suites read (payload/mods/scope-modes/tests/api-merge-cases.ts), because two recognisers in two
# languages cannot share code and drift with nothing reporting it (L450).
#
# The gh pr merge reading is the one that lived inline in merge-target.sh until #1181. Since #1186 it
# finds the subcommand as gh does (gh_path), past flags written in front of it, takes the LAST
# repository flag as gh does, reads short flags clustered, and refuses a repository flag gh cannot read.
# Only the merge's own arguments count: a `gh pr view --repo x` earlier in the same command is about
# that view. A newline starts a new command the way a semicolon does, and the walk stops at the first
# token it cannot read.
import importlib.util
import os
import re
import shlex
import sys

cmd = os.environ.get("MT_CMD", "")
# A newline starts a new command the way a semicolon does, and a backslash before one does not.
# shlex reads both as ordinary whitespace, so they are rewritten before it sees them.
cmd = cmd.replace("\\\n", " ").replace("\n", " ; ")
lex = shlex.shlex(cmd, posix=True, punctuation_chars=True)
lex.whitespace_split = True
OPENERS = {";", "&&", "||", "|", "&", "(", "{", "|&", ";;"}
ENDERS = OPENERS | {")", "}"}

# ---- where gh finds its subcommand ------------------------------------------------------------
# gh takes a subcommand's flags written IN FRONT of it: `gh -R o/x pr merge 7`, `gh pr -R o/x merge
# 7`, `gh -X PUT api repos/o/x/pulls/7/merge` (claude-config#1186). Which subcommand a command runs is
# read by lib/shell-words.py (gh_command, gh_path), the one reading of gh every gate asks, the bash
# gates through lib/push-scope.sh's ps_runs_gh (claude-config#1188): it finds the subcommand and
# action as gh's command library does and hands back the flags in front as the subcommand's own. It
# lived here for #1186; a copy here and another in each bash gate is how a flag in front came to be
# read by the merge gates and not by the closing keyword check (L613).
#
# `gh --squash pr merge 7` is a command named merge to gh, which it has none of, and it runs nothing
# (measured: `gh --web pr view 1` answers `unknown command "view"`); the overnight judge refuses it
# anyway, and the shared table says why the two differ there.
# Loaded as a module by its path, never leaving a bytecode cache in the hooks' lib/.
sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location(
    "shell_words", os.path.join(os.path.dirname(os.path.abspath(__file__)), "shell-words.py"))
SW = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(SW)


# ---- the repository flag -----------------------------------------------------------------------
# gh reads -R and --repo as [HOST/]OWNER/REPO, or as an address when it has a scheme or starts with
# git@ (gh's ghrepo.FromFullName), and refuses anything else outright: measured on gh 2.89.0,
# `-R nonsense`, `-R a//b`, `-R a/b/c/d` and `-R o/r/` each answer `expected the "[HOST/]OWNER/REPO"
# format`. An EMPTY value is no repository to gh, which then reads the folder's (`--repo= pr view`
# answered for the checkout), so it is read here as none. A flag given no value at all (the last
# word) gh refuses too. The two refusals are untold merges (claude-config#1186): read as naming no
# repository, the gates would judge the checkout's pull request in its place (L75).
ADDRESS = re.compile(r"^[^:]+://")
# No repository flag given at all, which is not the same as one given an empty value or none.
MISSING = object()


def repo_flag_problem(value):
    """Why gh cannot read this -R value: "norepo" when the flag has none, "repo" when it is not
    [HOST/]OWNER/REPO; None when gh can read it."""
    if value is None:
        return "norepo"
    if value == "" or ADDRESS.match(value) or value.startswith("git@"):
        return None
    parts = value.split("/", 3)
    if len(parts) not in (2, 3) or "" in parts:
        return "repo"
    return None


def untold_repo(problem, value):
    return {"route": "untold", "why": problem, "detail": value or ""}


# ---- gh pr merge -------------------------------------------------------------------------------
# The flags gh pr merge takes a VALUE for. A value is neither a flag nor the pull request, so
# without this list a commit sha or a message would be read as the thing being merged.
VALUED = {"--repo", "-R", "--body", "-b", "--body-file", "-F", "--subject", "-t",
          "--match-head-commit", "--author-email", "-A"}
# Its short flags that take a value, for a cluster such as `-sR owner/x` or `-sb 42`, which gh reads
# as pflag does: each letter a flag until one that takes a value, which takes the rest of the word or
# the next word (claude-config#1186; mod-kit's gh.ts reads `pr merge` with the same letters).
PR_MERGE_SHORT_VALUES = set("RbFtA")
LINK = re.compile(r"^(?:[a-z]+://)?([^/\s]+[.][^/\s]+)/([^/\s]+)/([^/\s]+)/pull/([0-9]+)(?:[/?#].*)?$")


def norm(v):
    v = re.sub(r"^[a-z]+://", "", v.strip())
    v = re.sub(r"[.]git$", "", v.rstrip("/"))
    if v.lower().startswith("github.com/"):
        v = v[len("github.com/"):]
    return v


def read_pr_merge(args):
    # The repository flag's value as written, or MISSING when no -R or --repo is given. gh takes the
    # LAST one (measured on gh 2.89.0: `-R a -R b` reads b), so each overwrites the one before.
    raw, link_repo, number, pin = MISSING, "", "", ""
    j, n = 0, len(args)
    while j < n:
        a = args[j]
        # The commit the merge is pinned to, read here as well as by block-red-merge.sh's own scan of
        # the typed text, which looks for gh at the head of a command and so cannot see the flag of a
        # merge behind env or sudo (claude-config#1181).
        if a == "--match-head-commit" and j + 1 < n:
            pin = pin or args[j + 1]
        elif a.startswith("--match-head-commit="):
            pin = pin or a[len("--match-head-commit="):]
        if a in ("--repo", "-R"):
            raw = args[j + 1] if j + 1 < n else None
            j += 2
            continue
        if a.startswith("--repo="):
            raw = a[len("--repo="):]
        elif a in VALUED:
            j += 2
            continue
        elif a.startswith("--"):
            pass
        elif a.startswith("-") and len(a) > 1:
            # A cluster of short flags, read as gh reads it.
            for k in range(1, len(a)):
                if a[k] in PR_MERGE_SHORT_VALUES:
                    value = a[k + 1:]
                    if not value:
                        value = args[j + 1] if j + 1 < n else None
                        j += 1
                    if a[k] == "R":
                        raw = value
                    break
        else:
            m = LINK.match(a)
            if m and not link_repo:
                host, owner, name = m.group(1), m.group(2), re.sub(r"[.]git$", "", m.group(3))
                link_repo = owner + "/" + name
                if host.lower() != "github.com":
                    link_repo = host + "/" + link_repo
                number = number or m.group(4)
            elif a.isdigit() and not number:
                number = a
        j += 1
    repo = ""
    if raw is not MISSING:
        problem = repo_flag_problem(raw)
        if problem:
            return untold_repo(problem, raw)
        repo = norm(raw)
    return {"repo": link_repo or repo, "number": number, "route": "pr", "pin": pin}


# ---- gh api ------------------------------------------------------------------------------------
# Read as gh reads its flags (pflag), as the mods' one reader of gh does (mod-kit/hooks/gh.ts): a
# value attached (-XPUT, --method=PUT) or apart, short flags clustered until one taking a value.
API_SHORT_VALUES = set("XfFHpqt")
API_LONG_VALUES = {"--method", "--field", "--raw-field", "--header", "--input", "--jq", "--preview",
                   "--cache", "--hostname", "--template"}
FIELD_FLAGS = {"-f", "-F", "--field", "--raw-field"}
API = "https://api.github.com/"
PLACEHOLDER = re.compile(r"^(?:\{owner\}|:owner|\{repo\}|:repo)$")
# The mutations that merge a PULL REQUEST, now or once its checks pass. mergeBranch merges one branch
# into another with no pull request, so no gate has a pull request to read for it; the overnight
# judge refuses it as a merge all the same, and the shared table says why the two differ there.
PR_MERGE_MUTATION = re.compile(r"^(?:mergePullRequest|enablePullRequestAutoMerge|enqueuePullRequest)$")
IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def api_flags(args):
    flags, plain = [], []
    j, n = 0, len(args)
    while j < n:
        a = args[j]
        if a == "--":
            plain.extend(args[j + 1:])
            break
        if a.startswith("--"):
            if "=" in a:
                name, value = a.split("=", 1)
                flags.append((name, value))
            elif a in API_LONG_VALUES and j + 1 < n:
                flags.append((a, args[j + 1]))
                j += 1
            else:
                flags.append((a, True))
        elif a.startswith("-") and len(a) > 1:
            for k in range(1, len(a)):
                letter = a[k]
                if letter in API_SHORT_VALUES:
                    attached = a[k + 1:]
                    if attached:
                        flags.append(("-" + letter, attached))
                    elif j + 1 < n:
                        flags.append(("-" + letter, args[j + 1]))
                        j += 1
                    else:
                        flags.append(("-" + letter, True))
                    break
                flags.append(("-" + letter, True))
        else:
            plain.append(a)
        j += 1
    return flags, plain


def endpoint_repo(e):
    """("checkout", "") for gh's own placeholders, ("repo", owner/name), or ("untold", "")."""
    if e.startswith(API):
        path = e[len(API):]
    elif e.startswith("https://"):
        path = None
    else:
        path = e[1:] if e.startswith("/") else e
    if path is not None and path.startswith("repos/"):
        m = re.match(r"^repos/([^/?#]+)/([^/?#]+)", path)
        if not m:
            return ("untold", "")
        owner, name = m.group(1), m.group(2)
        # gh fills both placeholders from the directory's repository; one beside a real name is a
        # repository that cannot be told from here.
        if PLACEHOLDER.match(owner) and PLACEHOLDER.match(name):
            return ("checkout", "")
        if PLACEHOLDER.match(owner) or PLACEHOLDER.match(name):
            return ("untold", "")
        return ("repo", owner + "/" + name)
    return ("untold", "")


def args_after(doc, i):
    """The text of the argument list a field opens at i, or empty when it takes none."""
    n = len(doc)
    while i < n and doc[i] in " \t\r\n,":
        i += 1
    if i >= n or doc[i] != "(":
        return ""
    depth, start, i = 0, i + 1, i
    while i < n:
        c = doc[i]
        if c == '"':
            i += 1
            while i < n and doc[i] != '"':
                if doc[i] == "\\":
                    i += 1
                i += 1
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return doc[start:i]
        i += 1
    return doc[start:]


def operations(doc):
    """The document's operations and their top level fields, as scope-modes nobuild.ts operations()
    reads them, each field with the text of its arguments."""
    out = []
    depth = parens = 0
    pending = None
    op = None
    i, n = 0, len(doc)
    while i < n:
        c = doc[i]
        if c == '"':
            i += 1
            while i < n and doc[i] != '"':
                if doc[i] == "\\":
                    i += 1
                i += 1
        elif c == "#":
            while i < n and doc[i] != "\n":
                i += 1
        elif c == "{":
            # A document's shorthand `{ ... }` is a query.
            if depth == 0:
                op = {"kind": pending or "query", "fields": [], "spreads": False}
                out.append(op)
            pending = None
            depth += 1
        elif c == "}":
            depth -= 1
        elif c == "(":
            parens += 1
        elif c == ")":
            parens -= 1
        elif c == "." and doc.startswith("...", i):
            if depth == 1 and op is not None:
                op["spreads"] = True
            i += 2
            after = re.match(r"\s*(?:on\s+)?[A-Za-z_][A-Za-z0-9_]*", doc[i + 1:])
            if after:
                i += len(after.group(0))
        elif c == "@" and i + 1 < n and re.match(r"[A-Za-z_]", doc[i + 1]):
            i += len(IDENT.match(doc, i + 1).group(0))
        elif re.match(r"[A-Za-z_]", c):
            word = IDENT.match(doc, i).group(0)
            i += len(word) - 1
            if depth == 0 and parens == 0 and word in ("query", "mutation", "subscription", "fragment"):
                pending = word
            # An alias (`a: mergePullRequest`) names the field after it.
            elif depth == 1 and parens == 0 and op is not None and not re.match(r"\s*:", doc[i + 1:]):
                op["fields"].append((word, args_after(doc, i + 1)))
        i += 1
    return out


def arg_value(args, name, variables):
    """A string argument of the mutation's input, written in it or passed as a variable; None when
    it cannot be read."""
    m = re.search(r"\b" + name + r"\s*:\s*(?:\"((?:[^\"\\]|\\.)*)\"|\$([A-Za-z_][A-Za-z0-9_]*))", args)
    if m:
        if m.group(1) is not None:
            return m.group(1)
        return variables.get(m.group(2))
    # The whole input passed as one variable, its keys sent as gh's nested fields (input[key]=value).
    m = re.search(r"\binput\s*:\s*\$([A-Za-z_][A-Za-z0-9_]*)", args)
    if m:
        return variables.get(m.group(1) + "[" + name + "]")
    return None


def read_api(front, after):
    """The merge a gh api call makes, as read_api_route reads it from the flags written in front of
    `api` and the words after it, held to a repository flag in front (claude-config#1186). gh api
    takes no -R and refuses a call carrying one, but the overnight judge reads one in front as
    naming the repository of an endpoint written with gh's placeholders, and the shared table holds
    the two to one answer: that repository when gh can read it, a refusal when it cannot. Only one in
    front counts, because after `api` both read -R as taking no value, its value as the endpoint,
    and the call as no merge."""
    named, rest = MISSING, []
    j, n = 0, len(front)
    while j < n:
        a = front[j]
        if a in ("-R", "--repo"):
            named = front[j + 1] if j + 1 < n else None
            j += 2
            continue
        if a.startswith("--repo="):
            named = a[len("--repo="):]
        elif a.startswith("-R") and len(a) > 2:
            named = a[2:]
        else:
            rest.append(a)
        j += 1
    found = read_api_route(rest + list(after), named)
    if found and named is not MISSING:
        problem = repo_flag_problem(named)
        if problem:
            return untold_repo(problem, named)
    return found


def read_api_route(args, named):
    flags, plain = api_flags(args)
    endpoint = plain[0] if plain else ""
    fields = [(k, v) for k, v in flags if k in FIELD_FLAGS and isinstance(v, str)]
    has_input = any(k == "--input" for k, _ in flags)
    methods = [v for k, v in flags if k in ("-X", "--method") and isinstance(v, str)]
    method = methods[-1].upper() if methods else ("POST" if fields or has_input else "GET")
    host = [v for k, v in flags if k == "--hostname" and isinstance(v, str)]
    host = host[-1].lower() if host else ""
    # Each field as the variable or parameter it sends; a -F value read from a file is unknown.
    sent = {}
    for k, v in fields:
        if "=" not in v:
            continue
        key, value = v.split("=", 1)
        sent[key] = None if (k in ("-F", "--field") and value.startswith("@")) else value

    if endpoint == "graphql":
        # The document, from its query field, as mod-kit's queryOf reads it: none from --input, or
        # from a file through -F query=@file.
        query = None
        if not has_input:
            q = [(k, v) for k, v in fields if v.startswith("query=")]
            if q:
                k, v = q[-1]
                v = v[len("query="):]
                query = None if (k in ("-F", "--field") and v.startswith("@")) else v
        if query is None:
            detail = ""
            for k, v in fields:
                if v.startswith("query="):
                    detail = v[len("query="):]
            return {"route": "untold", "why": "doc", "detail": detail or ("--input" if has_input else "")}
        merges = []
        for op in operations(query):
            if op["kind"] != "mutation":
                continue
            if op["spreads"]:
                return {"route": "untold", "why": "spread"}
            merges.extend(f for f in op["fields"] if PR_MERGE_MUTATION.match(f[0]))
        if not merges:
            return None
        if len(merges) > 1:
            return {"route": "untold", "why": "many"}
        variables = {k: v for k, v in sent.items() if k != "query"}
        node = arg_value(merges[0][1], "pullRequestId", variables)
        if not node:
            return {"route": "untold", "why": "noid", "detail": merges[0][0]}
        pin = arg_value(merges[0][1], "expectedHeadOid", variables) or ""
        return {"route": "graphql", "node": node, "pin": pin}

    # REST: a pull request's merge endpoint, by any method but GET, as the overnight judge reads it.
    m = re.search(r"/pulls/([0-9]+)/merge/?$", endpoint)
    if method == "GET" or not m:
        return None
    kind, repo = endpoint_repo(endpoint)
    # gh's placeholders name the checkout's repository, and a repository flag in front names another.
    if kind == "checkout" and isinstance(named, str) and named:
        kind, repo = "repo", norm(named)
    if kind == "untold" or (kind == "checkout" and host and host != "github.com"):
        return {"route": "untold", "why": "endpoint", "detail": endpoint}
    # --hostname names the host of an owner/name; a repository flag that names its own host
    # (ghe.example.com/o/r) keeps that one, never with this one added in front again.
    if repo and host and host != "github.com" and repo.count("/") == 1:
        repo = host + "/" + repo
    return {"route": "rest", "repo": repo, "number": m.group(1), "pin": sent.get("sha") or ""}


# ---- the walk ----------------------------------------------------------------------------------
toks = []
while True:
    try:
        t = lex.get_token()
    except ValueError:
        break
    if t is None or t == lex.eof:
        break
    toks.append(t)

found = None
at_start, i, n = True, 0, len(toks)
while i < n:
    t = toks[i]
    if at_start and t not in ENDERS:
        k = i
        while k < n and toks[k] not in ENDERS:
            k += 1
        # The command from its first word to the next separator, read by the one reading of gh: past
        # its assignments, any rtk, env or sudo, and gh's flags written in front of the subcommand.
        g = SW.gh_command(toks[i:k])
        if g:
            sub, act, front, after = g
            if sub == "pr" and act == "merge":
                found = read_pr_merge(front + after)
            elif sub == "api":
                found = read_api(front, after)
            if found:
                break
        i = k
        at_start = False
        continue
    at_start = t in OPENERS
    i += 1


def field(name):
    return str((found or {}).get(name, "")).replace("\t", " ").replace("\n", " ")


print("\t".join(field(f) for f in ("repo", "number", "route", "node", "pin", "why", "detail")), end="")
