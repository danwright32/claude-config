"""Record each hand rerun of a workflow run, `gh run rerun`, in the issue spool (claude-config#3613).

A session that reruns a failed check and sees it pass merges, and nothing recorded that the check
failed first, so a flaky job was never counted (L293). This records one line per rerun: the
repository and the run (or the job, for `--job`). It posts nothing and alerts nobody; the end of
turn review reads the run's final result later (issue-spool.sh resolve-reruns), because a hook that
fires when the rerun is requested cannot know how the rerun ended.

The command is read by the shared reader (gh_issue_scan.scan_gh_in_context, the walk the issue and
comment gates use), so a rerun joined to other commands, behind rtk or env, or inside a shell's -c
string is found, and a quoted mention (`echo "gh run rerun 1"`) is not. A command the reader cannot
read records nothing and says nothing: this is a recorder, not a gate. A failed command (a non zero
exit, an interrupted call) records nothing either, since no rerun may have started.

The repository is -R/--repo when given, else GH_REPO set in the command, else the one gh would pick
from the git remotes of the directory the command ran in (a remote marked by `gh repo set-default`,
then upstream, github, origin, then the first). A rerun whose repository cannot be told is not
recorded. Exit 3 with the reason on stderr when a record could not be WRITTEN: the wrapper says so.
"""

import importlib.util
import json
import os
import re
import subprocess
import sys

sys.dont_write_bytecode = True
_HERE = os.environ.get("GATE_DIR") or os.path.dirname(os.path.abspath(__file__))

KIND = ("run", "rerun")
VALUE_FLAGS = {"-R", "--repo", "--job", "-j"}
REMOTE_URL = re.compile(r"^(?:[a-z+]+://)?(?:[^@/]+@)?([^/:]+)[:/](?:\d+/)?([^/]+)/([^/]+?)(?:\.git)?/?$")


def _load_scan():
    path = os.path.join(_HERE, "gh_issue_scan.py")
    spec = importlib.util.spec_from_file_location("gh_issue_scan", path)
    if spec is None or spec.loader is None:
        raise ImportError("cannot load %s" % path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def read_args(args):
    """(repo, run id, job id) from one gh run rerun's own words; each None when not given."""
    repo = run = job = None
    i = 0
    while i < len(args):
        a = args[i]
        if a in VALUE_FLAGS:
            v = args[i + 1] if i + 1 < len(args) else None
            if a in ("-R", "--repo"):
                repo = v
            else:
                job = v
            i += 2
            continue
        if a.startswith("--repo="):
            repo = a.split("=", 1)[1]
        elif a.startswith("--job="):
            job = a.split("=", 1)[1]
        elif a.startswith("-R") and len(a) > 2:
            repo = a[2:]
        elif not a.startswith("-") and run is None:
            run = a
        i += 1
    return repo, run, job


def repo_of_remotes(cwd):
    """owner/name (host/owner/name off github.com) gh would pick from the remotes in cwd, or None."""
    if not cwd or not os.path.isdir(cwd):
        return None
    try:
        p = subprocess.run(["git", "-C", cwd, "config", "--get-regexp", r"^remote\..*\.(url|gh-resolved)$"],
                           capture_output=True, text=True, errors="replace", timeout=3)
    except (OSError, subprocess.TimeoutExpired):
        return None
    urls, resolved, order = {}, None, []
    for line in p.stdout.splitlines():
        key, _, value = line.partition(" ")
        m = re.match(r"^remote\.(.+)\.(url|gh-resolved)$", key)
        if not m:
            continue
        name, field = m.group(1), m.group(2)
        if field == "url" and name not in urls:
            urls[name] = value.strip()
            order.append(name)
        elif field == "gh-resolved" and value.strip() == "base":
            resolved = name
    pick = resolved if resolved in urls else next((n for n in ("upstream", "github", "origin") if n in urls),
                                                  order[0] if order else None)
    if not pick:
        return None
    m = REMOTE_URL.match(urls[pick])
    if not m:
        return None
    host, owner, name = m.groups()
    return "%s/%s" % (owner, name) if host == "github.com" else "%s/%s/%s" % (host, owner, name)


def reruns(command, cwd, scan):
    """(repo, run, job, cwd) for every gh run rerun the command runs; [] when it cannot be read."""
    try:
        found = scan.scan_gh_in_context(command, cwd=cwd, kinds=frozenset({KIND}))
    except (scan.Unreadable, scan.ReaderMissing):
        return []
    out = []
    for _kind, args, envs, place in found:
        repo, run, job = read_args(args)
        where = getattr(place, "cwd", None) or cwd
        if not repo:
            env = dict(e.split("=", 1) for e in envs if "=" in e)
            repo = env.get("GH_REPO") or (getattr(place, "vars", {}) or {}).get("GH_REPO")
        if not repo:
            repo = repo_of_remotes(where)
        if not repo:
            continue
        run = run if run and run.isdigit() else None
        job = job if job and job.isdigit() else None
        if run or job:
            out.append((repo, run, job, where or cwd or ""))
    return out


def main():
    try:
        data = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace"))
    except ValueError:
        return 0
    if not isinstance(data, dict):
        return 0
    command = (data.get("tool_input") or {}).get("command") or ""
    if "rerun" not in command:
        return 0
    resp = data.get("tool_response")
    resp = resp if isinstance(resp, dict) else {}
    if resp.get("exit_code") not in (None, 0, "0") or resp.get("interrupted") is True:
        return 0
    cwd = data.get("cwd") or ""
    found = reruns(command, cwd, _load_scan())
    if not found:
        return 0
    lib = os.path.join(_HERE, "lib", "issue-spool.sh")
    transcript = data.get("transcript_path") or ""
    failures = []
    for repo, run, job, where in found:
        p = subprocess.run(["bash", lib, "rerun", where or cwd or ".", repo, run or "", job or "", transcript],
                           capture_output=True, text=True, errors="replace")
        if p.returncode != 0:
            failures.append(p.stderr.strip() or "issue-spool.sh rerun exited %d" % p.returncode)
    if failures:
        print(" ".join(failures), file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
