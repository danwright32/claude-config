"""score_github.py: the design match score's side on GitHub (claude-config#1364).

Shared by `design_score.py post`, which puts a score on a pull request and on its milestone's
"Match the settled design" issue, and by hooks/design-score-gate.py, which refuses to close that
issue or its milestone below 100% on both halves. Both read and write the same three marks here, so
the writer and the reader of a score comment cannot drift apart:

  <!-- design-score-issue {"design": "docs/design/x.html"} -->      in the Match issue's body
  <!-- design-score-milestone {"design": "docs/design/x.html"} -->  in the milestone's description
  <!-- design-score v1 -->                                           at the head of a score comment,
                                                                     the score file in a json block

A mark counts only as the HTML comment itself, outside code (outside_code, claude-config#1394): an
issue that documents a mark quotes it in backticks or a code block, and that marks nothing.

GitHub is read through `gh`, as whichever logged in account can see the repository: the active
one first, then each other, its token scoped to the one call and never switched (Dan runs sessions
under several accounts at once). That walk is lib/merge-target.sh's mt_pr_view, written again here
because this is python; its cases are the same and so are its reasons (claude-config#463, #1173).
"""
import json
import os
import re
import subprocess

ISSUE_MARK = "design-score-issue"
MILESTONE_MARK = "design-score-milestone"
SCORE_MARK = "<!-- design-score v1 -->"
MATCH_TITLE = "Match the settled design"
_MARK = re.compile(r"<!--\s*(design-score-issue|design-score-milestone)\s+(\{.*?\})\s*-->", re.S)
_SCORE_JSON = re.compile(r"<summary>Score file</summary>\s*```json\n(.*?)\n```", re.S)


class GitHubError(Exception):
    """GitHub could not be read or written, or answered with something that could not be used."""


def mark(kind, design):
    return "<!-- %s %s -->" % (kind, json.dumps({"design": design}))


_QUOTE = re.compile(r"^(?: {0,3}>)")
_FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})(.*)$")
_LIST_ITEM = re.compile(r"^ {0,3}(?:[-+*]|\d{1,9}[.)])(?:[ \t]|$)")


def _inline_outside_code(s):
    """A paragraph with its code spans blanked out, read left to right as GitHub's markdown does: a
    run of backticks opens a span closed by the next run of exactly as many, and one never closed is
    plain text; an HTML comment that starts first is kept whole, backticks inside it and all."""
    out, i, n = [], 0, len(s)
    while i < n:
        if s.startswith("<!--", i):
            j = s.find("-->", i + 4)
            if j < 0:
                out.append(s[i:])
                break
            out.append(s[i:j + 3])
            i = j + 3
        elif s[i] == "\\" and i + 1 < n:
            out.append(s[i:i + 2])
            i += 2
        elif s[i] == "`":
            j = i
            while j < n and s[j] == "`":
                j += 1
            run, k, close = s[i:j], j, -1
            while True:
                k = s.find(run, k)
                if k < 0:
                    break
                end = k + len(run)
                if s[k - 1] != "`" and (end >= n or s[end] != "`"):
                    close = k
                    break
                while k < n and s[k] == "`":
                    k += 1
            if close < 0:
                out.append(run)
                i = j
            else:
                out.append(" ")
                i = close + len(run)
        else:
            out.append(s[i])
            i += 1
    return "".join(out)


def outside_code(text):
    """What of a markdown body GitHub does NOT show as code (claude-config#1394). An issue that
    documents a mark quotes it in inline code, a fenced block or an indented block, where GitHub
    shows it as text, so it marks nothing; the real mark is an HTML comment, hidden, outside code.

    Fenced blocks (``` or ~~~, inside a quote too, and one never closed runs to the end as it does
    on GitHub) and indented blocks (four spaces or a tab, never inside a list item, where that
    indent continues the item) are dropped; code spans are blanked; HTML blocks are kept as written.
    Where this reading is unsure it keeps the text, so a doubtful mark is still read as a mark."""
    chunks, para = [], []
    fence, fence_depth, html, in_list, prev_blank = None, 0, False, False, True

    def flush():
        if para:
            chunks.append(_inline_outside_code("\n".join(para)))
            del para[:]

    for raw in (text or "").replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        line, depth = raw, 0
        while _QUOTE.match(line):
            line = _QUOTE.sub("", line, count=1)
            line = line[1:] if line.startswith(" ") else line
            depth += 1
        if fence is not None:
            if depth < fence_depth:
                fence = None          # the quote holding the fence ended, and the fence with it
            else:
                if re.match(r"^ {0,3}%s{%d,}[ \t]*$" % (re.escape(fence[0]), len(fence)), line):
                    fence = None
                continue
        if html:
            chunks.append(line)
            html = "-->" not in line
            prev_blank = False
            continue
        expanded = line.expandtabs(4)
        indent = len(expanded) - len(expanded.lstrip(" "))
        if not expanded.strip():
            flush()
            prev_blank = True
            continue
        m = _FENCE.match(line)
        if m and not (m.group(1)[0] == "`" and "`" in m.group(2)):
            flush()
            fence, fence_depth, prev_blank = m.group(1), depth, False
            continue
        if indent >= 4 and not para and not in_list:
            prev_blank = False        # an indented code block: dropped
            continue
        if _LIST_ITEM.match(line):
            in_list = True
        elif indent == 0 and prev_blank:
            in_list = False
        if indent < 4 and expanded.lstrip(" ").startswith("<!--"):
            flush()
            chunks.append(line)
            html = "-->" not in line
            prev_blank = False
            continue
        para.append(line)
        prev_blank = False
    flush()
    return "\n".join(chunks)


def read_mark(text, kind):
    """The design path a body's mark of `kind` names, None when it has none. Only the mark itself,
    an HTML comment outside code, counts: one quoted in inline code or a code block is an example
    of it (outside_code, claude-config#1394). A real mark that is not readable JSON naming a design
    raises, since a broken mark must never read as no mark."""
    for m in _MARK.finditer(outside_code(text or "")):
        if m.group(1) != kind:
            continue
        try:
            design = json.loads(m.group(2)).get("design")
        except (ValueError, AttributeError):
            raise GitHubError("its %s mark is not readable JSON: %s" % (kind, m.group(0)[:200]))
        if not isinstance(design, str) or not design.strip():
            raise GitHubError("its %s mark names no design: %s" % (kind, m.group(0)[:200]))
        return design.strip()
    return None


def is_match_issue(issue):
    """(is it a Match issue, the design its mark names or None). A Match issue is one carrying the
    issue mark, or one titled as one: a hand filed "Match the settled design ..." with no mark is
    still one, and its score cannot be found, which the gate says rather than letting it close."""
    design = read_mark(issue.get("body") or "", ISSUE_MARK)
    titled = (issue.get("title") or "").strip().lower().startswith(MATCH_TITLE.lower())
    return (design is not None or titled), design


NOT_PLANNED = "not_planned"


def closed_not_planned(issue):
    """True only when GitHub reports `issue` closed as not planned: its design was abandoned, so
    neither the close gate nor the daily reopen check holds it to 100% (Dan, 2026-10-20,
    claude-config#1405). Any other reason, none, or one this cannot read is a completed close."""
    return issue.get("state") == "closed" and issue.get("state_reason") == NOT_PLANNED


def milestone_issues(gh, repo, number):
    """Every issue in milestone `number` of `repo`, open or closed, never a pull request (GitHub lists
    both from this endpoint). Read through `gh` (a GitHub below), every page of it."""
    issues = gh.api("repos/%s/issues?milestone=%d&state=all&per_page=100" % (repo, number), repo, paginate=True)
    return [i for i in issues if not i.get("pull_request")]


def match_issues(gh, repo, number, design):
    """The Match the settled design issues in milestone `number` whose mark names `design`. The one
    reading of a milestone's Match issues the post, the close gate and an app's CI share, so they
    cannot disagree about which issue a score belongs on."""
    return [i for i in milestone_issues(gh, repo, number) if is_match_issue(i)[1] == design]


def score_comment(score, lines, note=""):
    """The body of a score comment: the score as printed, then the score file itself."""
    verdict = {"matched": "matched, both halves 100%", "not-matched": "not matched yet",
               "unmeasured": "could not score"}.get(score.get("verdict"), "could not score")
    commit = score.get("commit") or "no commit"
    out = [SCORE_MARK,
           "**Design match score** for `%s` at `%s` (%s): **%s**" % (score.get("design"), commit[:7],
                                                                   score.get("platform"), verdict)]
    if note:
        out += ["", note]
    out += ["", "```text"] + lines + ["```", "", "<details><summary>Score file</summary>", "",
                                       "```json", json.dumps(score, separators=(",", ":")), "```", "", "</details>"]
    return "\n".join(out)


def read_score_comment(body):
    """The score file a comment carries, None for a comment that is not a score. A comment carrying
    the mark whose score cannot be read raises, so it is reported rather than skipped."""
    if SCORE_MARK not in (body or ""):
        return None
    m = _SCORE_JSON.search(body)
    if not m:
        raise GitHubError("a score comment holds no score file block")
    try:
        return json.loads(m.group(1))
    except ValueError as err:
        raise GitHubError("a score comment's score file is not JSON (%s)" % err)


class GitHub:
    """`gh` as whichever logged in account can see each repository."""

    def __init__(self, gh="gh", runner=subprocess.run):
        self.gh = gh
        self.run = runner
        self.accounts = {}   # repo -> the account that could see it ("" for the active one)
        self._others = None

    def _other_accounts(self):
        if self._others is None:
            proc = self.run([self.gh, "auth", "status"], capture_output=True, text=True)
            self._others = sorted(set(re.findall(r"account ([A-Za-z0-9_.-]+)", proc.stdout + proc.stderr)))
        return self._others

    def call(self, args, repo, cwd=None, binary=False):
        """Runs gh with `args` about `repo`, as the first account that can see it, and gives its output:
        text, or the bytes exactly as gh printed them when `binary`."""
        order = [self.accounts[repo]] if repo in self.accounts else [""]
        tried, last = set(), ""
        i = 0
        while i < len(order):
            account = order[i]
            i += 1
            if account in tried:
                continue
            tried.add(account)
            env = dict(os.environ)
            if account:
                tok = self.run([self.gh, "auth", "token", "-u", account], capture_output=True, text=True)
                if tok.returncode != 0 or not tok.stdout.strip():
                    continue
                env["GH_TOKEN"] = tok.stdout.strip()
            try:
                proc = self.run([self.gh] + args, capture_output=True, env=env, cwd=cwd)
            except OSError as err:
                raise GitHubError("gh could not be run (%s)" % err)
            if proc.returncode == 0:
                self.accounts[repo] = account
                return proc.stdout if binary else proc.stdout.decode("utf-8", errors="replace")
            said = (proc.stderr or proc.stdout or b"").decode("utf-8", errors="replace").strip()
            last = said.splitlines()[0] if said else "gh printed nothing (exit %d)" % proc.returncode
            # Only what a repository another account can see looks like sends the walk on; anything
            # else is GitHub's answer, believed the first time (mt_pr_view, claude-config#1173).
            if "Could not resolve to a Repository" in last or "HTTP 404" in last:
                if account == "" and i >= len(order):
                    order += [a for a in self._other_accounts() if a not in tried]
                continue
            break
        raise GitHubError("gh %s: %s" % (" ".join(args[:3]), last or "no logged in account could see %s" % repo))

    def api(self, endpoint, repo, paginate=False):
        args = ["api", endpoint] + (["--paginate", "--slurp"] if paginate else [])
        out = self.call(args, repo)
        try:
            data = json.loads(out)
        except ValueError as err:
            raise GitHubError("gh api %s answered with something that is not JSON (%s)" % (endpoint, err))
        if paginate:
            return [x for page in data for x in page]
        return data

    def raw(self, path, repo, ref=None):
        """A file's bytes as GitHub holds it at `ref`, or on the default branch when none is named."""
        where = "repos/%s/contents/%s" % (repo, path) + ("?ref=%s" % ref if ref else "")
        return self.call(["api", "-H", "Accept: application/vnd.github.raw", where], repo, binary=True)

    def write(self, method, endpoint, repo, **fields):
        """Sends `fields` to `endpoint` with `method` (POST a comment, PATCH a state), as the account
        that can see `repo`. Each field goes as raw text (-f), so a body is never read as a file."""
        args = ["api", "-X", method, endpoint]
        for name, value in fields.items():
            args += ["-f", "%s=%s" % (name, value)]
        return self.call(args, repo)
