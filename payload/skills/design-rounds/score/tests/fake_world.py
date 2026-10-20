"""fake_world.py: a GitHub that remembers, for the reopen check's tests (claude-config#1386).

fake_gh.py answers each call from a fixed list of routes, which is right for a gate that only reads.
The reopen check WRITES (a comment, then a reopen) and has to be seen doing each once however many
times it runs, so its GitHub must change when written to. World.run stands in for subprocess.run
under score_github.GitHub, so the real code builds every gh command and parses every answer, and
only the network is replaced. Every call is kept in World.calls as (token, args).
"""
import json
import subprocess
from urllib.parse import parse_qs, urlsplit


class Repo:
    def __init__(self, slug):
        self.slug = slug
        self.default_branch = "main"
        self.commits = {}          # sha -> tree
        self.history = []          # [(iso time, sha)] of the default branch, oldest first
        self.issues = {}           # number -> issue
        self.comments = {}         # number -> [comment]
        self.events = {}           # number -> [event]
        self.milestones = {}       # number -> milestone
        self.files = {}            # (path, sha) -> bytes


class World:
    def __init__(self, accounts=("danwright32",)):
        self.accounts = list(accounts)
        self.repos = {}
        self.unreadable = set()    # repositories no account can see
        self.digest = {}           # list name -> {"repos": [...]}; a list absent here cannot be read
        self.failures = []         # [{"method", "path", "times", "err"}] injected refusals
        self.calls = []
        self.now = "2026-10-20T12:00:00Z"
        self._n = 100

    def repo(self, slug):
        return self.repos.setdefault(slug, Repo(slug))

    def writes(self):
        return [args for _, args in self.calls if args[:1] == ["api"] and ("POST" in args or "PATCH" in args)]

    # --- subprocess.run -----------------------------------------------------------------------
    def run(self, argv, capture_output=True, text=False, env=None, cwd=None):
        args = list(argv[1:])
        token = (env or {}).get("GH_TOKEN", "")
        self.calls.append((token, args))
        code, out, err = self._answer(args, token)
        if text:
            return subprocess.CompletedProcess(argv, code, out, err)
        return subprocess.CompletedProcess(argv, code, out.encode() if isinstance(out, str) else out, err.encode())

    def _answer(self, args, token):
        if args[:2] == ["auth", "status"]:
            return 0, "".join("  Logged in to github.com account %s (keyring)\n" % a for a in self.accounts), ""
        if args[:2] == ["auth", "token"]:
            return 0, "tok-" + args[-1] + "\n", ""
        if args[:1] != ["api"]:
            return 1, "", "fake world: no answer for gh %s\n" % " ".join(args)
        method, fields, endpoint, raw = "GET", {}, None, False
        i = 1
        while i < len(args):
            a = args[i]
            if a in ("-X", "--method"):
                method = args[i + 1].upper()
                i += 2
            elif a == "-H":
                raw = raw or "raw" in args[i + 1]
                i += 2
            elif a in ("-f", "-F", "--field", "--raw-field"):
                k, _, v = args[i + 1].partition("=")
                fields[k] = v
                i += 2
            elif a.startswith("-"):
                i += 1
            else:
                endpoint = endpoint or a
                i += 1
        if method == "GET" and fields:
            method = "POST"
        parts = urlsplit(endpoint or "")
        path, query = parts.path.strip("/"), {k: v[0] for k, v in parse_qs(parts.query).items()}
        for f in self.failures:
            if f["times"] > 0 and f["method"] == method and path == f["path"]:
                f["times"] -= 1
                return 1, "", f["err"] + "\n"
        bits = path.split("/")
        if len(bits) < 3 or bits[0] != "repos":
            return 1, "", "HTTP 404: Not Found\n"
        slug = bits[1] + "/" + bits[2]
        if slug == "dwright-pennie/repo-digest" and bits[3:4] == ["contents"]:
            name = "/".join(bits[4:])
            if name not in self.digest:
                return 1, "", "HTTP 404: Not Found\n"
            return 0, json.dumps(self.digest[name]), ""
        if slug in self.unreadable or slug not in self.repos:
            return 1, "", "HTTP 404: Not Found\n"
        r = self.repos[slug]
        rest = bits[3:]
        page = lambda xs: json.dumps([xs]) if "--paginate" in args else json.dumps(xs)  # noqa: E731
        if not rest:
            return 0, json.dumps({"default_branch": r.default_branch}), ""
        if rest[0] == "commits" and len(rest) == 2:
            ref = rest[1]
            sha = r.history[-1][1] if ref == r.default_branch else ref
            if sha not in r.commits:
                return 1, "", "HTTP 422: No commit found for SHA: %s\n" % ref
            return 0, json.dumps({"sha": sha, "commit": {"tree": {"sha": r.commits[sha]}}}), ""
        if rest[0] == "commits" and len(rest) == 1:
            until = query.get("until", "9999")
            older = [sha for t, sha in r.history if t <= until]
            return 0, json.dumps([{"sha": older[-1]}] if older else []), ""
        if rest[0] == "contents":
            sha = query.get("ref")
            data = r.files.get(("/".join(rest[1:]), sha))
            if data is None:
                return 1, "", "HTTP 404: Not Found\n"
            return 0, data, ""
        if rest[0] == "issues" and len(rest) == 1:
            xs = list(r.issues.values())
            if query.get("state") in ("open", "closed"):
                xs = [x for x in xs if x["state"] == query["state"]]
            if "since" in query:
                xs = [x for x in xs if x["updated_at"] >= query["since"]]
            if "milestone" in query:
                xs = [x for x in xs if (x.get("milestone") or {}).get("number") == int(query["milestone"])]
            return 0, page(xs), ""
        if rest[0] == "issues":
            n = int(rest[1])
            if n not in r.issues:
                return 1, "", "HTTP 404: Not Found\n"
            issue = r.issues[n]
            if len(rest) == 2 and method == "PATCH":
                self._set_state(issue, fields.get("state"))
                return 0, json.dumps(issue), ""
            if len(rest) == 2:
                return 0, json.dumps(issue), ""
            if rest[2] == "comments" and method == "POST":
                self._n += 1
                c = {"body": fields["body"], "created_at": self.now, "html_url": "https://github.com/%s/issues/%d#issuecomment-%d" % (slug, n, self._n)}
                r.comments.setdefault(n, []).append(c)
                issue["updated_at"] = self.now
                return 0, json.dumps(c), ""
            if rest[2] == "comments":
                return 0, page(r.comments.get(n, [])), ""
            if rest[2] == "events":
                return 0, page(r.events.get(n, [])), ""
        if rest[0] == "milestones" and len(rest) == 1:
            xs = list(r.milestones.values())
            if query.get("state") in ("open", "closed"):
                xs = [x for x in xs if x["state"] == query["state"]]
            return 0, page(xs), ""
        if rest[0] == "milestones":
            m = r.milestones.get(int(rest[1]))
            if m is None:
                return 1, "", "HTTP 404: Not Found\n"
            if method == "PATCH":
                self._set_state(m, fields.get("state"))
            return 0, json.dumps(m), ""
        return 1, "", "HTTP 404: Not Found (fake world has no answer for %s %s)\n" % (method, endpoint)

    def _set_state(self, thing, state):
        if state == "open":
            thing.update(state="open", closed_at=None)
        elif state == "closed":
            thing.update(state="closed", closed_at=self.now)
        thing["updated_at"] = self.now
