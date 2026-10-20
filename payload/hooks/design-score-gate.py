#!/usr/bin/env python3
"""design-score-gate.py: refuse to close a "Match the settled design" issue, or its milestone, while
the build does not match its settled design on both halves (claude-config#1364).

Dan, 2026-10-19: the milestone's last issue becomes "Match the settled design", and a hook refuses
to close it, or the milestone, below 100% on both halves. Every route a closing can take from here is
read, because a gate that knows one spelling is dodged by the next (L247, L450):

  gh issue close / delete / transfer <issue>        the issue, judged at the default branch's head
  gh api ... repos/O/R/issues/N  with state=closed  the same
  gh api ... repos/O/R/milestones/N  state=closed, or DELETE    the milestone, the same
  gh api graphql  with closeIssue                  refused: which issue it closes is not read here,
                                                   and `gh issue close` does the same thing readably
  gh pr merge (and merge-when-ready.sh, which asks this gate) of a pull request whose closing
                    keywords name a Match issue    judged at the pull request's head

A shell redirection (`2>&1`, `>out`, `< in`) is the shell's and never read as an issue or an
endpoint, and a command asking gh for its help (`--help`, `-h`) closes nothing and passes.

Two closes never pass through here: one on GitHub's website, and a closing keyword in a commit pushed
straight to the default branch. design-score-reopen.py finds those afterwards and reopens them, with
this file's Gate as its judge (claude-config#1386), so the two cannot disagree about what 100% means.

A Match issue is one carrying the mark create-milestone.sh writes in its body, the HTML comment
itself outside code (a mark quoted in backticks or a code block documents it and marks nothing,
claude-config#1394; score_github.read_mark is the one reader), or one titled "Match the settled
design" by hand. A milestone is a design milestone when its description carries the milestone mark
or it holds a Match issue.

CLOSED AS NOT PLANNED, the design was abandoned (Dan, 2026-10-20, claude-config#1405), and the
close is let through below 100%: `gh issue close --reason "not planned"`, or a REST close sending
state_reason=not_planned. Any other reason, two reasons, --duplicate-of, or a reason that cannot be
read (an --input file) is judged as the completed close it may be; a GraphQL closeIssue is refused
whatever its reason. A milestone has no close reason: its design is abandoned when its Match issue
is closed as not planned, which is then not judged, so the milestone closes.

THE SCORE is the newest score comment on the Match issue (`design_score.py post` writes them) whose
commit has the same tree as the commit being closed on: the default branch's head, or the pull
request's head. A squash merge of an up to date branch makes a new commit with the same tree, so a
score posted on the pull request still counts once it has merged. That score must hold together
(design_score.verify_score), read matched, be for the design the issue names, be drawn from a
checkout with nothing uncommitted, and carry the hash of the design file GitHub holds at that
commit, so a design edited after the score is not scored by the old one.

Every reading that fails refuses, saying what could not be read: unmeasured is never 100%, and a
close that waits loses nothing (fail closed). There is no override. A deliberate difference is
settled by a new design round, or by an exception Dan approves, recorded in the design file in his
words, which the score then skips.

Run by design-score-gate.sh with the hook payload on stdin, and with `--merge <pr> <repo> <dir>`
(each possibly empty) when lib/merge-target.sh found a merge in the command. Prints the deny decision,
or nothing to allow. Exit 0 either way; anything else is the judge failing, which the wrapper refuses on.
"""
import hashlib
import importlib.util
import json
import os
import re
import subprocess
import sys

sys.dont_write_bytecode = True
HOOKS = os.path.dirname(os.path.abspath(__file__))
SCORE_DIR = os.path.normpath(os.path.join(HOOKS, "..", "skills", "design-rounds", "score"))
sys.path.insert(0, SCORE_DIR)
import design_score  # noqa: E402
import score_github as sg  # noqa: E402


def _load_shell_words():
    spec = importlib.util.spec_from_file_location("shell_words", os.path.join(HOOKS, "lib", "shell-words.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


sw = _load_shell_words()

ISSUE_URL = re.compile(r"^https?://github\.com/([^/\s]+/[^/\s]+)/issues/(\d+)")
ISSUE_EP = re.compile(r"^/?repos/([^/\s]+)/([^/\s]+)/issues/(\d+)/?$")
MILESTONE_EP = re.compile(r"^/?repos/([^/\s]+)/([^/\s]+)/milestones/(\d+)/?$")
SLUG = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
ISSUE_FLAGS_WITH_VALUE = {"-c", "--comment", "-r", "--reason", "-R", "--repo", "--duplicate-of"}
API_FLAGS_WITH_VALUE = {"-X", "--method", "-f", "--raw-field", "-F", "--field", "-H", "--header", "--input",
                        "-q", "--jq", "-t", "--template", "--hostname", "--cache", "-p", "--preview"}


class Refuse(Exception):
    pass


def remote_slug(directory):
    try:
        proc = subprocess.run(["git", "-C", directory, "config", "--get", "remote.origin.url"],
                              capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    url = proc.stdout.strip()
    m = re.search(r"github\.com[:/]([^/\s]+/[^/\s]+?)(?:\.git)?/?$", url)
    return m.group(1) if m else None


def _flag_value(words, names):
    for i, w in enumerate(words):
        for n in names:
            if w == n and i + 1 < len(words):
                return words[i + 1]
            if n.startswith("--") and w.startswith(n + "="):
                return w[len(n) + 1:]
    return None


def _flag_values(words, names, with_value):
    """Every value given to the flags `names`, in order, read past the other flags' values."""
    out, i = [], 0
    while i < len(words):
        w = words[i]
        if w == "--":
            break
        hit = False
        for n in names:
            if w == n and i + 1 < len(words):
                out.append(words[i + 1])
                hit = True
            elif n.startswith("--") and w.startswith(n + "="):
                out.append(w[len(n) + 1:])
        if hit:
            i += 2
        elif w.startswith("-") and len(w) > 1 and w in with_value and "=" not in w:
            i += 2
        else:
            i += 1
    return out


# The one reason a close of a Match issue below 100% is let through: not planned, the design
# abandoned (Dan, 2026-10-20, claude-config#1405). Spelled exactly as gh and the REST API take it;
# any other spelling, or a reason that cannot be read, is judged as the completed close it may be.
GH_NOT_PLANNED = "not planned"


REDIRECT = re.compile(r"^(\d*|&)(>>?|<<?<?|>&|<&|>\|)(.*)$")


def _drop_redirects(words):
    """The words with every shell redirection taken out: `2>&1`, `>out`, `&> log`, `< in`. The
    shell reads them, never gh, so none is an issue, an endpoint or a flag's value. An operator
    standing alone takes the next word, its target, with it. A quoted argument that starts with one
    is dropped too: that only ever leaves less to read, and reading less refuses."""
    out, i = [], 0
    while i < len(words):
        m = REDIRECT.match(words[i])
        if m:
            i += 1 if m.group(3) else 2
            continue
        out.append(words[i])
        i += 1
    return out


def _asks_help(words, with_value):
    """True when gh is asked for its help (--help or -h as a flag, never as another flag's value),
    which prints the usage and closes nothing."""
    i = 0
    while i < len(words):
        w = words[i]
        if w == "--":
            return False
        if w in ("--help", "-h"):
            return True
        i += 2 if (w in with_value and "=" not in w) else 1
    return False


def _positionals(words, with_value):
    out, i = [], 0
    while i < len(words):
        w = words[i]
        if w == "--":
            out += words[i + 1:]
            break
        if w.startswith("-") and len(w) > 1:
            i += 2 if (w in with_value and "=" not in w) else 1
            continue
        out.append(w)
        i += 1
    return out


def targets(command, cwd):
    """What the command would close: [(kind, repo, number, how)], kind issue, milestone or graphql."""
    try:
        records = sw.commands(command)
    except Exception:  # noqa: BLE001  the crude reading still finds the commands
        records = sw.crude_commands(command)
    found = []
    for d, text in records:
        # Which gh subcommand it runs is the shared reader's answer (shell-words.py gh_command), past
        # assignments, rtk, env and gh's own flags in front, never a word read by its position.
        found_gh = sw.gh_command(sw.command_words(text))
        if found_gh is None:
            continue
        sub, act, front, after = found_gh
        after = _drop_redirects(list(after))
        words = _drop_redirects(list(front)) + after
        if sub in ("issue", "api") and _asks_help(words, ISSUE_FLAGS_WITH_VALUE if sub == "issue"
                                                  else API_FLAGS_WITH_VALUE):
            continue          # gh prints its usage and closes nothing
        here = os.path.join(cwd, d) if d and not os.path.isabs(d) else (d or cwd)
        default_repo = _flag_value(words, ["-R", "--repo"]) or os.environ.get("GH_REPO") or remote_slug(here)
        if sub == "issue" and act in ("close", "delete", "transfer"):
            pos = _positionals(words, ISSUE_FLAGS_WITH_VALUE)
            if not pos:
                raise Refuse("`gh issue %s` names no issue, so which issue it %s cannot be told" % (act, act))
            spec = pos[0]
            if act == "close":
                reasons = _flag_values(words, ["-r", "--reason"], ISSUE_FLAGS_WITH_VALUE)
                duplicate = _flag_values(words, ["--duplicate-of"], ISSUE_FLAGS_WITH_VALUE)
                if reasons and all(r == GH_NOT_PLANNED for r in reasons) and not duplicate:
                    continue      # closed as not planned: the design abandoned, never judged
            m = ISSUE_URL.match(spec)
            if m:
                found.append(("issue", m.group(1), int(m.group(2)), "gh issue %s" % act))
            elif re.match(r"^#?\d+$", spec):
                found.append(("issue", default_repo, int(spec.lstrip("#")), "gh issue %s" % act))
            else:
                raise Refuse("`gh issue %s %s` names an issue this gate cannot read" % (act, spec))
        elif sub == "api":
            pos = _positionals(list(after), API_FLAGS_WITH_VALUE)
            endpoint = pos[0] if pos else ""
            method = (_flag_value(list(after), ["-X", "--method"]) or "").upper()
            fields = []
            for i, w in enumerate(after):
                if w in ("-f", "-F", "--field", "--raw-field") and i + 1 < len(after):
                    fields.append(after[i + 1])
                elif w.startswith(("--field=", "--raw-field=")):
                    fields.append(w.split("=", 1)[1])
            closes = any(re.match(r"^state=closed$", f) for f in fields)
            unread_input = _flag_value(list(after), ["--input"]) is not None
            reasons = [f.split("=", 1)[1] for f in fields if f.startswith("state_reason=")]
            not_planned = bool(reasons) and all(r == sg.NOT_PLANNED for r in reasons) and not unread_input
            if endpoint == "graphql":
                if "closeIssue" in " ".join(after):
                    found.append(("graphql", default_repo, None, "gh api graphql closeIssue"))
                continue
            ep = endpoint.replace("{owner}/{repo}", default_repo or "{owner}/{repo}").replace(":owner/:repo", default_repo or ":owner/:repo")
            mi = ISSUE_EP.match(ep)
            mm = MILESTONE_EP.match(ep)
            if mi and not_planned:
                continue          # closed as not planned: the design abandoned, never judged
            if mi and (closes or unread_input):
                found.append(("issue", "%s/%s" % (mi.group(1), mi.group(2)), int(mi.group(3)), "gh api %s" % endpoint))
            elif mm and (closes or unread_input or method == "DELETE"):
                found.append(("milestone", "%s/%s" % (mm.group(1), mm.group(2)), int(mm.group(3)), "gh api %s" % endpoint))
    return found


class Gate:
    def __init__(self, github):
        self.gh = github
        self.trees = {}

    def _repo(self, repo, how):
        if not repo or not SLUG.match(repo):
            raise Refuse("which repository `%s` acts on could not be told (no --repo, and no GitHub remote "
                         "here), so whether it closes a Match the settled design issue cannot be checked" % how)
        return repo

    def tree(self, repo, ref):
        key = (repo, ref)
        if key not in self.trees:
            data = self.gh.api("repos/%s/commits/%s" % (repo, ref), repo)
            try:
                self.trees[key] = (data["sha"], data["commit"]["tree"]["sha"])
            except (KeyError, TypeError):
                raise sg.GitHubError("repos/%s/commits/%s answered with no commit tree" % (repo, ref))
        return self.trees[key]

    def default_head(self, repo):
        data = self.gh.api("repos/%s" % repo, repo)
        branch = data.get("default_branch") if isinstance(data, dict) else None
        if not branch:
            raise sg.GitHubError("repos/%s answered with no default branch" % repo)
        return branch

    def judge_issue(self, repo, number, ref, why):
        """Refuses when issue `number` is a Match issue whose build does not match at `ref`."""
        issue = self.gh.api("repos/%s/issues/%d" % (repo, number), repo)
        if issue.get("pull_request"):
            return
        is_match, design = sg.is_match_issue(issue)
        if not is_match:
            return
        label = "%s#%d (%s)" % (repo, number, issue.get("title", ""))
        if design is None:
            raise Refuse("%s is a Match the settled design issue with no design mark in its body, so its score "
                         "cannot be found. Add this line to its body, with the settled design's path in the "
                         "repository: %s" % (label, sg.mark(sg.ISSUE_MARK, "docs/design/<name>.html")))
        sha, tree = self.tree(repo, ref)
        comments = self.gh.api("repos/%s/issues/%d/comments?per_page=100" % (repo, number), repo, paginate=True)
        scores = []
        for c in comments:
            try:
                s = sg.read_score_comment(c.get("body") or "")
            except sg.GitHubError as err:
                raise Refuse("%s: %s (%s)" % (label, err, c.get("html_url", "")))
            if s is not None:
                scores.append((c.get("created_at") or "", c.get("html_url", ""), s))
        scores.sort(key=lambda x: x[0], reverse=True)
        if not scores:
            raise Refuse("%s has no design match score posted on it, so the build is unmeasured, and "
                         "unmeasured is never 100%%. %s" % (label, HOW))
        chosen = None
        for _, url, s in scores:
            commit = s.get("commit")
            if not isinstance(commit, str) or not commit:
                continue
            try:
                _, t = self.tree(repo, commit)
            except sg.GitHubError:
                continue
            if t == tree:
                chosen = (url, s)
                break
        if chosen is None:
            newest = scores[0][2].get("commit") or "no commit"
            raise Refuse("%s: no score posted on it was measured on the code being closed on (%s %s); the newest "
                         "is for %s. Score that code and post it. %s" % (label, why, sha[:7], newest[:7], HOW))
        url, s = chosen
        verdict, problems = design_score.verify_score(s)
        if problems:
            raise Refuse("%s: the score at %s cannot be read: %s" % (label, url, "; ".join(problems)))
        lines = "\n".join(design_score.render(s))
        if s.get("design") != design:
            raise Refuse("%s names the design %s, and the score at %s is for %s" % (label, design, url, s.get("design")))
        if s.get("dirty") is not False:
            raise Refuse("%s: the score at %s was drawn from a checkout with uncommitted changes, so it belongs to "
                         "no commit. %s" % (label, url, HOW))
        if verdict != "matched":
            raise Refuse("%s is below 100%% on the code being closed on (%s %s):\n%s\n%s" % (
                label, why, sha[:7], lines, HOW))
        held = self.gh.raw(design, repo, sha)
        if hashlib.sha256(held).hexdigest() != s.get("designSha256"):
            raise Refuse("%s: the score at %s was measured against a different %s than the one at %s, so it does "
                         "not score this design. Score again. %s" % (label, url, design, sha[:7], HOW))

    def judge_milestone(self, repo, number, why, ref=None):
        """Refuses when milestone `number` is a design milestone whose Match issues do not match at
        `ref`: the head of the default branch unless a commit is named (design-score-reopen.py names
        the one the milestone was closed on)."""
        ms = self.gh.api("repos/%s/milestones/%d" % (repo, number), repo)
        ms_design = sg.read_mark(ms.get("description") or "", sg.MILESTONE_MARK)
        matches = [i for i in sg.milestone_issues(self.gh, repo, number) if sg.is_match_issue(i)[0]]
        if ms_design is not None and not matches:
            raise Refuse("milestone %s (%s) is built from the settled design %s but holds no Match the settled "
                         "design issue, so whether it matches cannot be checked" % (number, ms.get("title"), ms_design))
        if ref is None:
            ref = self.default_head(repo)
            why = "%s, the head of %s" % (why, ref)
        for i in matches:
            # A milestone has no close reason of its own. Its design is abandoned when its Match
            # issue was closed as not planned, and that issue is then not held to 100% (#1405).
            if sg.closed_not_planned(i):
                continue
            self.judge_issue(repo, i["number"], ref, why)

    def judge_merge(self, pr, repo, directory):
        # A command this gate WRITES, not one it reads, spelled so the word position scan does not
        # take it for a reading of gh (lib/word-position-scan.py).
        args = "pr view".split() + ([pr] if pr else []) + (["--repo", repo] if repo else []) + [
            "--json", "number,url,headRefOid,closingIssuesReferences"]
        slug = repo or remote_slug(directory) or ""
        out = self.gh.call(args, slug, cwd=directory or None)
        try:
            view = json.loads(out)
        except ValueError:
            raise sg.GitHubError("gh pr view answered with something that is not JSON")
        m = re.match(r"https://github\.com/([^/]+/[^/]+)/pull/", view.get("url", ""))
        prepo = m.group(1) if m else slug
        for ref in view.get("closingIssuesReferences") or []:
            irepo = (ref.get("repository") or {}).get("nameWithOwner") or prepo
            if irepo.lower() == prepo.lower():
                self.judge_issue(prepo, int(ref["number"]), view["headRefOid"],
                                 "merging #%s at its head" % view.get("number"))
            else:
                branch = self.default_head(irepo)
                self.judge_issue(irepo, int(ref["number"]), branch, "the head of %s in %s" % (branch, irepo))


HOW = ("Bring it to 100%: run the platform adapter, then `python3 ~/.claude/skills/design-rounds/score/design_score.py "
       "score <capture folder>`, and post it with `design_score.py post`. A difference Dan means to keep is "
       "settled by a new design round, or by an exception he approves, recorded in the design file in his words.")


def deny(reason):
    said = "Refusing to close. " + reason
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                             "permissionDecisionReason": said}}))


def main(argv, stdin_text, github=None):
    try:
        payload = json.loads(stdin_text or "{}")
    except ValueError:
        return 0
    command = ((payload.get("tool_input") or {}).get("command")) or ""
    cwd = payload.get("cwd") or os.getcwd()
    merge = None
    if "--merge" in argv:
        i = argv.index("--merge")
        merge = (argv[i + 1], argv[i + 2], argv[i + 3])
    gate = Gate(github or sg.GitHub())
    try:
        for kind, repo, number, how in targets(command, cwd):
            if kind == "issue":
                repo = gate._repo(repo, how)
                gate.judge_issue(repo, number, gate.default_head(repo), "the head of the default branch")
            elif kind == "milestone":
                gate.judge_milestone(gate._repo(repo, how), number, "closing the milestone")
            else:
                raise Refuse("a GraphQL closeIssue cannot be checked against the design match score; close the "
                             "issue with `gh issue close`, which this gate can read")
        if merge is not None:
            gate.judge_merge(merge[0], merge[1], merge[2] or cwd)
    except Refuse as r:
        deny(str(r))
    except sg.GitHubError as err:
        deny("GitHub could not be read to check the design match score (%s), and an unread score is never "
             "100%%. Nothing was closed; try again." % err)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv, sys.stdin.read()))
