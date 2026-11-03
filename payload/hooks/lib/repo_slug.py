"""The owner/name slug of a GitHub repository object, built in one place (claude-config#2096).

gh describes a repository as an object, and which fields it carries depends on where it appears.
A pull request's closingIssuesReferences and an issue's closedByPullRequestsReferences give each
repository as {id, name, owner: {id, login}} and carry NO nameWithOwner (measured 2026-11-02), so
code that read nameWithOwner there got nothing and fell back to the wrong repository, judging every
cross repository close against the pull request's own (claude-config#2065). Three hooks had each
written this join for themselves; this is the one they all read now, and
hand-rolled-slug.py fails the suite on the next hook that writes its own (L613).

slug(repository) returns "owner/name" in the case GitHub gave it (a caller that compares slugs
lowercases them itself). nameWithOwner is used when it is present; otherwise owner.login and name.
Anything that cannot give a whole slug raises RepoSlugError, which names the field it could not
read: never a half slug such as "/widgets", and never a guess. What an ABSENT repository means (often
"the pull request's own") is the caller's decision, so the caller checks for that before asking.
"""


class RepoSlugError(ValueError):
    """The repository object cannot give a whole owner/name slug."""


def _text(value, *path):
    """The non-empty, slash-free text at path inside value, or RepoSlugError naming the path."""
    for key in path:
        value = value.get(key) if isinstance(value, dict) else None
    if not isinstance(value, str) or not value or "/" in value:
        raise RepoSlugError("the repository's %s is %s, not a name"
                            % (".".join(path), "missing" if value is None else repr(value)))
    return value


def slug(repository):
    """owner/name for a gh repository object, or RepoSlugError."""
    if not isinstance(repository, dict):
        raise RepoSlugError("there is no repository object to read (got %r)" % (repository,))
    whole = repository.get("nameWithOwner")
    if whole is not None:
        owner, sep, name = whole.partition("/") if isinstance(whole, str) else ("", "", "")
        if not sep or not owner or not name or "/" in name:
            raise RepoSlugError("the repository's nameWithOwner is %r, not owner/name" % (whole,))
        return whole
    return "%s/%s" % (_text(repository, "owner", "login"), _text(repository, "name"))
