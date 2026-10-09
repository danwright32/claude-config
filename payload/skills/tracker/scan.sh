#!/usr/bin/env bash
# scan.sh: find the local git repositories under some roots and describe each one as JSON, for
# /tracker --scan (claude-config#1030). Read only: it runs git read commands and writes nothing but
# its own temporary file, which it removes.
#
#   scan.sh [--root DIR]... [--ignore DIR]... [--author EMAIL_OR_NAME]... [--days N] [--now EPOCH]
#   scan.sh --normalize-url URL      # host/owner/repo for a hosted remote, or a refusal
#
# --root     a directory to search; repeatable. With none, HOME is searched.
# --ignore   a repository (or a directory of them) to leave out; repeatable. Listed under "ignored".
# --author   one of the user's identities: an email (contains @) or a name; repeatable. Matching is
#            exact after folding case (and spacing, for names). With none given, the user's counts
#            are null rather than zero, because nothing was measured (L622).
# --days     the window's length in days (default 30).
# --now      the window's end, in epoch seconds (default: the current time). A seam, so a test can
#            pin both ends of the window (L130).
#
# The window is git's own --since/--until, which judge the COMMITTER date. first_commit_date and
# last_commit_date are AUTHOR dates over every branch, remote branch and tag (stashes are not
# work). In a shallow clone first_commit_date is the shallow boundary, so is_shallow says so.
#
# Output: one JSON object on stdout. A run that finds no repositories says "no_repos" as its own
# outcome beside the roots it searched, so an empty answer is never mistaken for a broken one. A
# root that does not exist is refused, never quietly searched as nothing (L320).
#
# ONE ENTRY PER REPOSITORY, NOT PER WORKING TREE. This is the contract the reconcile relies on.
# A linked worktree shares its repository's commits and branches, so its commits are counted once,
# on one entry. Working trees are grouped by their common git dir (field git_common_dir). The
# entry's path is the main checkout when the scan found it, otherwise the first working tree it
# found, and every other working tree it found is listed in that entry's "worktrees". A submodule
# has its own git dir, so it is its own entry. Two entries can still share a normalized_url (two
# separate clones of one project), so the reconcile matches on normalized_url and treats more
# than one as a question, never as two projects.
#
# macOS bash 3.2 and set -e safe: lists are newline separated strings rather than arrays where
# they can be empty (L486), and every git call that can legitimately fail has its status captured
# (L612).
set -euo pipefail

prog="scan.sh"
die(){ echo "$prog: $*" >&2; exit 2; }

# A caller's GIT_DIR (a hook, a script run inside another repository) would make every git -C
# below read that one repository instead of the one named.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
# Read commands only, and no optional lock files either (a status refresh, for one, takes one).
export GIT_OPTIONAL_LOCKS=0

# normalize_remote <url>: prints host/path for a hosted remote, with the path's case kept, or
# fails. Every pattern is anchored: a suffix is removed only at the END (.git, slashes), never by
# deleting a substring wherever it happens to appear (a repo named my.github.repo keeps its name).
normalize_remote(){
  local u="$1" host="" path=""
  # The user information runs to the LAST @ before the first slash, since a password can hold one.
  local re_url='^(ssh|git|http|https|git\+ssh|ssh\+git)://([^/]*@)?([A-Za-z0-9][A-Za-z0-9.-]*)(:[0-9]*)?/(.*)$'
  local re_scp='^([^/@:]+@)?([A-Za-z0-9][A-Za-z0-9.-]*):(.*)$'
  if [[ "$u" =~ $re_url ]]; then
    host="${BASH_REMATCH[3]}"; path="${BASH_REMATCH[5]}"
  elif [[ "$u" != *://* && "$u" =~ $re_scp ]]; then
    host="${BASH_REMATCH[2]}"; path="${BASH_REMATCH[3]}"
  else
    return 1
  fi
  path="${path%%\?*}"; path="${path%%#*}"
  while [ "${path#/}" != "$path" ]; do path="${path#/}"; done
  while [ "${path%/}" != "$path" ]; do path="${path%/}"; done
  path="${path%.git}"
  while [ "${path%/}" != "$path" ]; do path="${path%/}"; done
  [[ "$path" =~ ^[^/]+(/[^/]+)+$ ]] || return 1
  printf '%s/%s\n' "$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')" "$path"
}
lower(){ printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# redact_url <url>: the remote as shown in the output. Credentials in an http(s) address (a token
# is often the user name alone) and any other user:password are dropped, and so are a query and a
# fragment (L741). A plain ssh user such as git@ is kept. The user information is matched to the
# LAST @ before the first slash, so a password holding an @ is removed whole, not cut at its own @.
redact_url(){
  local u="$1"
  # Credentials FIRST: a password may hold a raw # or ?, so cutting the query and fragment before
  # would truncate inside it, leave no @ to find, and print the password's first half.
  if [[ "$u" =~ ^(https?)://[^/]*@(.*)$ ]]; then
    u="${BASH_REMATCH[1]}://${BASH_REMATCH[2]}"
  elif [[ "$u" =~ ^([A-Za-z0-9+]+)://[^/@]*:[^/]*@(.*)$ ]]; then
    u="${BASH_REMATCH[1]}://${BASH_REMATCH[2]}"
  fi
  u="${u%%\?*}"; u="${u%%#*}"
  printf '%s' "$u"
}

roots_arg=""; ignores=""; authors=""; days=""; now=""
while [ $# -gt 0 ]; do
  case "$1" in
    --root|--ignore|--author|--days|--now)
      [ $# -ge 2 ] || die "$1 needs a value."
      # An empty value is refused, never dropped: an empty --root (a caller's unset variable)
      # would otherwise leave no root and widen the scan to all of HOME (L320).
      [ -n "$2" ] || die "$1 was given an empty value."
      case "$1" in
        --root) roots_arg="${roots_arg}$2"$'\n' ;;
        --ignore) ignores="${ignores}$2"$'\n' ;;
        --author) authors="${authors}$2"$'\n' ;;
        --days) days="$2" ;;
        --now) now="$2" ;;
      esac
      shift 2 ;;
    --normalize-url)
      [ $# -ge 2 ] || die "--normalize-url needs a value."
      if out="$(normalize_remote "$2")"; then lower "$out"; echo; exit 0; fi
      echo "$prog: '$2' is not the address of a hosted repository (host/owner/repo)." >&2
      exit 1 ;;
    -h|--help)
      # The whole leading comment, however long it grows: from line 2 to the first line that is
      # not a comment, never a fixed range that silently stops mid paragraph.
      awk 'NR == 1 { next } /^#/ { print; next } { exit }' "$0"; exit 0 ;;
    *) die "unknown argument '$1'. See --help." ;;
  esac
done

command -v git >/dev/null 2>&1 || die "git is not on PATH, so nothing can be scanned."
command -v python3 >/dev/null 2>&1 || die "python3 is not on PATH, so the JSON cannot be written."

# The defaults live here, in the shell, never as a literal path in a config file.
scan_roots="${roots_arg%$'\n'}"
scan_roots="${scan_roots:-${HOME:?HOME is not set, so there is no default root}}"
scan_window_days="${days:-30}"
case "$scan_window_days" in ''|*[!0-9]*) die "--days must be a whole number of days above zero, not '$scan_window_days'." ;; esac
# 10# reads the digits as decimal: shell arithmetic takes a leading zero as octal, so 08 would be an
# error and 0123 would quietly be 83.
scan_window_days=$((10#$scan_window_days))
[ "$scan_window_days" -gt 0 ] || die "--days must be a whole number of days above zero, not '${days}'."
case "$now" in
  '') now="$(date +%s)" ;;
  *[!0-9]*) die "--now must be epoch seconds, not '$now'." ;;
esac
now=$((10#$now))
since=$((now - scan_window_days * 86400))

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REC="$WORK/records"; : > "$REC"
FOUND="$WORK/found"; : > "$FOUND"
TOPS="$WORK/tops"; : > "$TOPS"
ERRF="$WORK/err"
US=$'\037'
rec(){ local IFS="$US"; printf '%s\n' "$*" >> "$REC"; }

# --- the roots, each resolved, each required to exist -----------------------------
resolved_roots=""
while IFS= read -r root; do
  [ -n "$root" ] || continue
  real="$(cd "$root" 2>/dev/null && pwd -P)" || die "the root '$root' does not exist or cannot be entered. Nothing was scanned."
  resolved_roots="${resolved_roots}${real}"$'\n'
  rec ROOT "$real"
done <<EOF
$scan_roots
EOF
[ -n "$resolved_roots" ] || die "no root to search."

resolved_ignores=""
while IFS= read -r ig; do
  [ -n "$ig" ] || continue
  # Both sides are compared resolved (L266): an ignore given as /tmp/x matches /private/tmp/x.
  real="$(cd "$ig" 2>/dev/null && pwd -P)" || real="${ig%/}"
  resolved_ignores="${resolved_ignores}${real}"$'\n'
done <<EOF
$ignores
EOF

# --- discovery: a .git directory OR file, never inside noise ------------------------
while IFS= read -r real; do
  [ -n "$real" ] || continue
  find_rc=0
  find "$real" -mindepth 1 \
    \( -name node_modules -o -name Library -o -name .Trash -o -name .claude -o -name 'claude-backup-*' \) -prune \
    -o -name .git -print -prune > "$WORK/found.one" 2> "$ERRF" || find_rc=$?
  cat "$WORK/found.one" >> "$FOUND"
  if [ "$find_rc" -ne 0 ]; then
    # A partial search is reported as one, with what find could not read (TCC, permissions).
    rec WARN "searching $real was incomplete (find exited $find_rc)"
    while IFS= read -r line; do rec WARN "$line"; done < "$ERRF"
  fi
done <<EOF
$resolved_roots
EOF

exec 3< "$FOUND"
while IFS= read -r -u 3 gitpath; do
  [ -n "$gitpath" ] || continue
  dir="${gitpath%/.git}"
  rc=0
  top="$(git -C "$dir" rev-parse --show-toplevel 2> "$ERRF" < /dev/null)" || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$top" ]; then
    rec UNRESOLVED "$gitpath" "$(sed -n 1p "$ERRF")"
    continue
  fi
  top="$(cd "$top" && pwd -P)"
  printf '%s\n' "$top" >> "$TOPS"
done
exec 3<&-

sort -u "$TOPS" > "$WORK/tops.sorted"

# --- the ignore list, then one entry per repository, never one per working tree -----
# A linked worktree shares its repository's object store and every branch, so reading it as a
# repository of its own would report the same commits twice. Working trees are grouped by their
# common git dir: the entry's path is the main checkout when the scan found it (else the first
# working tree it found), and the other working trees it found are listed under "worktrees". A
# submodule has a common git dir of its own, so it stays an entry of its own.
PAIRS="$WORK/pairs"; : > "$PAIRS"
exec 3< "$WORK/tops.sorted"
while IFS= read -r -u 3 top; do
  [ -n "$top" ] || continue
  skip=""
  while IFS= read -r ig; do
    [ -n "$ig" ] || continue
    case "$top" in "$ig"|"$ig"/*) skip=1 ;; esac
  done <<EOF
$resolved_ignores
EOF
  if [ -n "$skip" ]; then rec IGNORED "$top"; continue; fi
  rc=0; common="$(git -C "$top" rev-parse --path-format=absolute --git-common-dir 2> "$ERRF" < /dev/null)" || rc=$?
  if [ "$rc" -eq 0 ] && [ -n "$common" ] && common="$(cd "$common" 2>/dev/null && pwd -P)"; then :; else
    # Unknown, so it is grouped with nothing: an entry of its own, and the run says so.
    rec WARN "$top: its common git dir could not be read, so it is listed alone: $(sed -n 1p "$ERRF")"
    common="$top"
  fi
  printf '%s\t%s\n' "$common" "$top" >> "$PAIRS"
done
exec 3<&-

# One line per repository: primary working tree, common git dir, then the other working trees
# found, joined by \035. The primary is listed first and the common dir is never empty, so the
# tab separated read below cannot lose a field to an empty one.
LC_ALL=C sort "$PAIRS" | awk -F '\t' '
  function flush(   i, primary, others, main) {
    if (n == 0) return
    main = common; sub(/\/\.git$/, "", main)
    primary = tops[1]
    if (common ~ /\/\.git$/) for (i = 1; i <= n; i++) if (tops[i] == main) primary = main
    others = ""
    for (i = 1; i <= n; i++) if (tops[i] != primary) others = others (others == "" ? "" : "\035") tops[i]
    printf "%s\t%s\t%s\n", primary, common, others
    n = 0
  }
  $1 != common { flush(); common = $1 }
  { tops[++n] = $2 }
  END { flush() }
' | LC_ALL=C sort > "$WORK/groups"

# --- each repository ----------------------------------------------------------------
gitr(){ git -C "$top" "$@" < /dev/null; }
exec 3< "$WORK/groups"
while IFS=$'\t' read -r -u 3 top common others; do
  [ -n "$top" ] || continue

  rec REPO "$top"
  rec F git_common_dir "$common"
  if [ -n "$others" ]; then
    printf '%s\n' "$others" | tr '\035' '\n' > "$WORK/others"
    while IFS= read -r wt; do if [ -n "$wt" ]; then rec W "$wt"; fi; done < "$WORK/others"
  fi

  rc=0; shallow="$(gitr rev-parse --is-shallow-repository 2> "$ERRF")" || rc=$?
  if [ "$rc" -ne 0 ]; then rec ERROR "is-shallow-repository failed: $(sed -n 1p "$ERRF")"; shallow=""; fi
  rec F is_shallow "$shallow"

  remote_name=""
  if gitr remote get-url origin > /dev/null 2>&1; then
    remote_name=origin
  else
    rc=0; remotes="$(gitr remote 2> "$ERRF")" || rc=$?
    if [ "$rc" -ne 0 ]; then rec ERROR "git remote failed: $(sed -n 1p "$ERRF")"; remotes=""; fi
    remote_name="$(printf '%s\n' "$remotes" | sed -n 1p)"
  fi
  if [ -n "$remote_name" ]; then
    rc=0; raw="$(gitr remote get-url "$remote_name" 2> "$ERRF")" || rc=$?
    if [ "$rc" -ne 0 ]; then
      rec ERROR "remote get-url $remote_name failed: $(sed -n 1p "$ERRF")"
    else
      rec F remote_name "$remote_name"
      rec F remote_url "$(redact_url "$raw")"
      if hosted="$(normalize_remote "$raw")"; then
        rec F normalized_url "$(lower "$hosted")"
        rec F repo_name "${hosted##*/}"
      fi
    fi
  fi

  # Every branch, remote branch and tag, plus the HEAD of EVERY working tree in this entry, the
  # main checkout and each worktree found: a detached worktree, or one whose branch was deleted,
  # holds commits no ref reaches. Each HEAD is added once, as a commit id, since "HEAD" alone
  # would name only the main checkout's. An empty repository has no HEAD commit, so each is asked
  # whether it has one first. A worktree whose branch was deleted underneath it has a HEAD naming
  # a branch that no longer exists; its last commit is read from its own HEAD reflog, and the run
  # says so in its warnings.
  revs="--branches --remotes --tags"
  printf '%s\n' "$top" > "$WORK/wts"
  if [ -n "$others" ]; then printf '%s\n' "$others" | tr '\035' '\n' >> "$WORK/wts"; fi
  while IFS= read -r wt; do
    [ -n "$wt" ] || continue
    sha=""
    if sha="$(git -C "$wt" rev-parse -q --verify 'HEAD^{commit}' 2> /dev/null < /dev/null)"; then :
    elif branch="$(git -C "$wt" symbolic-ref -q HEAD 2> /dev/null < /dev/null)"; then
      sha=""
      if logf="$(git -C "$wt" rev-parse --path-format=absolute --git-path logs/HEAD 2> /dev/null < /dev/null)" && [ -s "$logf" ]; then
        # Deleting the branch appends an entry whose new value is all zeros, so the commit is the
        # last NON-zero value HEAD held, not simply the last line.
        last="$(awk '$2 !~ /^0+$/ { v = $2 } END { print v }' "$logf")"
        if [ -n "$last" ] && git -C "$wt" rev-parse -q --verify "$last^{commit}" > /dev/null 2>&1 < /dev/null; then
          sha="$last"
          rec WARN "$wt: its branch $branch no longer exists, so its last commit was read from its HEAD reflog"
        fi
      fi
    fi
    if [ -n "$sha" ]; then
      case " $revs " in *" $sha "*) ;; *) revs="$revs $sha" ;; esac
    fi
  done < "$WORK/wts"
  # shellcheck disable=SC2086 # revs is a fixed list of git options, split on purpose
  {
    rc=0; total="$(gitr rev-list --count $revs 2> "$ERRF")" || rc=$?
    if [ "$rc" -ne 0 ]; then rec ERROR "rev-list failed: $(sed -n 1p "$ERRF")"; total=""; fi
    rec F commit_count "$total"

    # The newest AUTHOR date over every commit, not git log -1: the walk is in committer date
    # order, so a commit rebased or amended later, but authored earlier, would come first.
    rc=0; dates="$(gitr log --format='%at %aI' $revs 2> "$ERRF")" || rc=$?
    if [ "$rc" -ne 0 ]; then rec ERROR "log for the last commit failed: $(sed -n 1p "$ERRF")"; dates=""; fi
    last="$(printf '%s\n' "$dates" | sort -n | sed -n '$s/^[0-9-]* //p')"
    rec F last_commit_date "$last"

    rc=0; roots_out="$(gitr log --max-parents=0 --format='%at %aI' $revs 2> "$ERRF")" || rc=$?
    if [ "$rc" -ne 0 ]; then rec ERROR "log for the first commit failed: $(sed -n 1p "$ERRF")"; roots_out=""; fi
    first="$(printf '%s\n' "$roots_out" | sort -n | sed -n '1s/^[0-9-]* //p')"
    rec F first_commit_date "$first"

    rc=0; window="$(gitr log --since="@$since" --until="@$now" --format="%aN${US}%aE${US}%s" $revs 2> "$ERRF")" || rc=$?
    if [ "$rc" -ne 0 ]; then rec ERROR "log for the window failed: $(sed -n 1p "$ERRF")"; window=""; fi
    while IFS= read -r line; do [ -n "$line" ] && rec C "$line"; done <<EOF
$window
EOF

    rc=0; shortlog="$(gitr shortlog -sne --since="@$since" --until="@$now" $revs 2> "$ERRF")" || rc=$?
    if [ "$rc" -ne 0 ]; then rec ERROR "shortlog failed: $(sed -n 1p "$ERRF")"; shortlog=""; fi
    while IFS= read -r line; do [ -n "$line" ] && rec S "$line"; done <<EOF
$shortlog
EOF
  }
done
exec 3<&-

python3 - "$REC" "$now" "$since" "$scan_window_days" "$authors" <<'PY'
import datetime, json, re, sys

rec_path, now, since, days, authors_raw = sys.argv[1:6]
now, since, days = int(now), int(since), int(days)

def iso(t):
    return datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def fold_name(s):
    return " ".join(s.split()).casefold()

given = [a.strip() for a in authors_raw.split("\n") if a.strip()]
emails = {a.casefold() for a in given if "@" in a}
names = {fold_name(a) for a in given if "@" not in a}

BOT_EMAILS = {"action@github.com", "actions@github.com"}
def is_bot(name, email):
    # A bot is never the user's work, even when it commits under the user's name.
    return "[bot]" in name.casefold() or "[bot]" in email.casefold() or email.casefold() in BOT_EMAILS

def matched(name, email):
    if not given or is_bot(name, email):
        return False
    return email.casefold() in emails or fold_name(name) in names

out = {
    "scan_version": 1,
    "now": iso(now), "since": iso(since), "until": iso(now), "window_days": days,
    "authors": given,
    "roots_searched": [], "repo_count": 0, "outcome": None,
    "ignored": [], "unresolved": [], "warnings": [], "repos": [],
}
repo = None
SHORTLOG = re.compile(r"^\s*(\d+)\t(.*) <([^<>]*)>$")
with open(rec_path, encoding="utf-8", errors="replace") as f:
    for line in f:
        line = line.rstrip("\n")
        kind, _, rest = line.partition("\x1f")
        if kind == "ROOT":
            out["roots_searched"].append(rest)
        elif kind == "WARN":
            out["warnings"].append(rest)
        elif kind == "IGNORED":
            out["ignored"].append(rest)
        elif kind == "UNRESOLVED":
            p, _, err = rest.partition("\x1f")
            out["unresolved"].append({"git_path": p, "error": err})
        elif kind == "REPO":
            repo = {
                "path": rest, "remote_name": None, "remote_url": None, "normalized_url": None,
                "repo_name": None, "is_shallow": None, "is_empty": None, "commit_count": None,
                "first_commit_date": None, "last_commit_date": None,
                "window_commit_count": 0 if given else None,
                "window_commit_count_all": 0,
                "window_subjects": [] if given else None,
                "authors_in_window": [], "bot_commits_in_window": 0,
                "git_common_dir": None, "worktrees": [], "errors": [],
            }
            out["repos"].append(repo)
        elif kind == "F":
            key, _, val = rest.partition("\x1f")
            if key == "is_shallow":
                repo[key] = {"true": True, "false": False}.get(val)
            elif key == "commit_count":
                repo[key] = int(val) if val.isdigit() else None
                repo["is_empty"] = None if repo[key] is None else repo[key] == 0
            else:
                repo[key] = val or None
        elif kind == "W":
            repo["worktrees"].append(rest)
        elif kind == "ERROR":
            repo["errors"].append(rest)
        elif kind == "C":
            name, email, subject = (rest.split("\x1f", 2) + ["", ""])[:3]
            repo["window_commit_count_all"] += 1
            if matched(name, email):
                repo["window_commit_count"] += 1
                repo["window_subjects"].append(subject)
        elif kind == "S":
            m = SHORTLOG.match(rest)
            if not m:
                repo["errors"].append("unreadable shortlog line: %r" % rest)
                continue
            n, name, email = int(m.group(1)), m.group(2), m.group(3)
            if is_bot(name, email):
                repo["bot_commits_in_window"] += n
            else:
                repo["authors_in_window"].append(
                    {"name": name, "email": email, "commits": n, "matched": matched(name, email)})

out["repo_count"] = len(out["repos"])
out["outcome"] = "repos_found" if out["repos"] else "no_repos"
json.dump(out, sys.stdout, indent=2, ensure_ascii=False)
sys.stdout.write("\n")
PY
