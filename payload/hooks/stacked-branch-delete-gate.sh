#!/bin/bash
# PreToolUse gate: refuse deleting a branch on GitHub while an open pull request is based on it
# (claude-config#1723).
#
# WHY. GitHub closes an open pull request the moment the branch it is based on is deleted through
# the API or a push (the web page's delete button moves it instead), and a closed pull request's base
# can never be changed again, so it has to be opened again as a new one, losing its review thread and
# a CI round. On 2026-10-25 in bidspoke, #2760 squash merged and its branch 2337-http-service was
# deleted with `gh api -X DELETE repos/<owner>/<repo>/git/refs/heads/<branch>`, the step the global
# CLAUDE.md names for a merge that could not delete its own branch. #2763 was stacked on that branch,
# and was closed at once with nothing said; it was found only because the next step read its state.
# lib/merge-when-ready.sh already moves every stacked pull request onto the merged one's base before
# it deletes a branch (claude-config#1337). This holds every other way a command here deletes one.
#
# WHAT IT DOES. Reads the command in COMMAND POSITION with lib/push-scope.sh's reader, so a delete
# quoted in an argument or written in a heredoc is not one, and one inside `bash -c` is. Four
# spellings delete a branch on GitHub:
#   gh api -X DELETE repos/<owner>/<repo>/git/refs/heads/<branch>   (any spelling of the method;
#                    {owner}/{repo} is whatever gh fills it with where the command runs, asked of
#                    gh itself: upstream before origin, so the parent in a fork's checkout;
#                    {branch} is the branch checked out there; a full https:// URL is read as the
#                    path it names on the host it names, #1758)
#   gh api graphql with a deleteRef mutation, whose ref id GitHub is asked to name, or an
#                    updateRefs whose afterOid of all zeros deletes a ref (#1758)
#   git push <remote> --delete <branch> (or -d), and git push <remote> :<branch>, to a GitHub remote
#   gh pr merge --delete-branch (or -d), which deletes the pull request's head branch as it merges
#                    (not a fork's: gh deletes no branch for a cross repository pull request)
# A pull request from a fork based on the branch counts as stacked like any other: GitHub closes it
# when its base goes, wherever its head lives, and gh pr list --base lists it (#1758).
# For each, the open pull requests based on the branch are listed with lib/stacked-prs.sh, the same
# reading merge-when-ready.sh moves them with, as the account the command itself runs as when it
# names one (`GH_TOKEN=$(gh auth token -u <account>)`). Any listed refuses (exit 2), naming them and
# the command that moves each onto the branch the merged pull request went into; for a merge, the
# helper that merges, moves them and only then deletes.
#
# FAILS CLOSED. A list GitHub will not give, an answer that is not a list, a pull request whose
# branch cannot be read, or a repository it cannot tell, refuses: the next step is a delete, and a
# delete that cannot see what it would close is the exact harm this exists to stop (L98).
#
# THE CLASS RULE: whenever this gate cannot establish WHO it is asking GitHub as, or WHICH GitHub
# repository a delete hits, it refuses, never passes. Both lessons reviews of the branch found the
# same fault in different clothes, a value the gate could not read taken for a harmless one: a
# lower case method read as no delete, an unreadable token or GH_TOKEN expression read as the active
# account (whose empty list allowed the delete), a remote it could not resolve or a GitHub URL it
# could not parse read as one off GitHub, a file named like a remote read as a path. So every
# reading below has three answers, never two: established, plainly not this gate's business (a
# command that deletes no branch, a remote on another host or a path on disk), or unknown, and
# unknown is a refusal through unknown(). A GitHub other than github.com (GH_HOST, or gh api
# --hostname) is not "another host": it is GitHub, and deleting a branch there closes the pull
# requests based on it just the same, but this gate lists pull requests on github.com only, so it
# cannot ask there, and refuses saying so rather than listing a same named github.com repository
# (#1758). Without its
# reader (python3, lib/push-scope.sh, lib/shell-words.py, lib/stacked-prs.sh) a command that looks
# like a delete is refused by name, and one that does not passes.
#
# Override: SKIP_STACKED_CHECK=1 in front of that one command, after saying why the refusal is wrong
# (for example, GitHub will not show this account the pull requests, and the branch is known to have
# none based on it).

# Does payload text $1 match regex $2? Under a UTF-8 locale bash's =~ stops at a byte that is not
# UTF-8, so a delete after one reads as absent and the call passes unread (claude-config#1885). The C
# locale reads every byte as a character, so it is tried as well; the session's locale is tried first,
# since only it counts a Unicode space as [[:space:]], so a match is only ever added, never lost.
payload_match() { [[ $1 =~ $2 ]] && return 0; local LC_ALL=C; [[ $1 =~ $2 ]]; }

payload="$(cat)"
# Every Bash call passes through here, and nearly none can delete a branch: answer those at once,
# before anything is loaded. What can: a DELETE method, a --delete or --delete-branch, a short flag
# cluster holding d (git push -d, gh pr merge -sd), or a refspec that is a bare :branch, or any
# GraphQL call, whose deleteRef can sit in a query file the command only names (#1758).
fast_re='(^|[[:space:]"'"'"'])(-[A-Za-z]*d|\+?:[A-Za-z0-9_./-]+)([[:space:]"'"'"']|$)'
# The method is matched in any case (gh api -X delete deletes just the same), and so is --delete.
shopt -s nocasematch
case "$payload" in
  *delete*|*graphql*) ;;
  *) payload_match "$payload" "$fast_re" || exit 0 ;;
esac
shopt -u nocasematch

# The crude reading used only when the real one cannot run: does the payload LOOK like a delete?
# The system grep stops matching at a byte that is not UTF-8 under a UTF-8 locale, as =~ does, so it
# is asked in the C locale as well, after the session's (claude-config#1885).
looks_like_delete() {
  local re='DELETE.*refs/heads|deleteRef[[:space:]]*\(|updateRefs[[:space:]]*\(|push.*(--delete|[[:space:]]-[A-Za-z]*d[[:space:]]|[[:space:]]\+?:[A-Za-z0-9_./-])|merge.*(--delete-branch|[[:space:]]-[A-Za-z]*d([[:space:]]|$))'
  grep -Eiq "$re" <<< "$payload" || LC_ALL=C grep -Eiq "$re" <<< "$payload"
}
cannot_read() {   # $1 = what is missing or failed, as a clause
  looks_like_delete || exit 0
  echo "BLOCKED: this command looks like it deletes a branch on GitHub, and $1, so whether an open pull request is based on that branch (and would be closed by deleting it) cannot be told (claude-config#1723). Reinstall the hooks with claude-sync pull. If this refusal is wrong, say so and add SKIP_STACKED_CHECK=1 to that one command." >&2
  exit 2
}

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/push-scope.sh
. "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null || cannot_read "$HOOK_DIR/lib/push-scope.sh, the reader of the command, could not be loaded"
# shellcheck source=lib/stacked-prs.sh
. "$HOOK_DIR/lib/stacked-prs.sh" 2>/dev/null || cannot_read "$HOOK_DIR/lib/stacked-prs.sh, which lists them, could not be loaded"
command -v python3 >/dev/null 2>&1 || cannot_read "python3 is not on PATH, and the command's words are read with it"

parsed="$(ps_parse_payload "$payload" segmented)" || cannot_read "the hook payload could not be read (neither jq nor python3 could parse it as JSON)"
cmd="${parsed%%$'\x1f'*}"
cwd="${parsed#*$'\x1f'}"
[ -n "$cmd" ] || exit 0
ps_has_override "$cmd" SKIP_STACKED_CHECK && exit 0

ps__read "$cmd"
case $? in
  0|3) ;;
  *)
    [ -f "$PS_SHELL_WORDS" ] && cannot_read "$PS_SHELL_WORDS could not read the command"
    cannot_read "$PS_SHELL_WORDS, the reader of the command, is missing" ;;
esac

# ---- the account and directory one command runs as ----
rec_tok=""; rec_acct=""; rec_unread=""; rec_repo_env=""; rec_dir=""
run_gh() { if [ -n "$rec_tok" ]; then GH_TOKEN="$rec_tok" gh "$@"; else gh "$@"; fi; }
# The token of the account the command names, read once a delete needs it. One that cannot be read
# refuses: listing as whichever account is active instead may not see the pull requests at all, and
# its empty list would let the delete through (lessons review of claude-config#1723).
account_ready() {
  [ -z "$rec_unread" ] || unknown "this runs gh with $rec_unread, whose value cannot be read before the command runs, so which GitHub account (or which GitHub) the open pull requests would be listed as cannot be established"
  [ -n "$rec_acct" ] && [ -z "$rec_tok" ] || return 0
  rec_tok="$(gh auth token -u "$rec_acct" 2>/dev/null)" || rec_tok=""
  [ -n "$rec_tok" ] || unknown "this runs as the GitHub account $rec_acct, and no token for $rec_acct could be read on this Mac (gh auth token -u $rec_acct failed), so the open pull requests based on the branch cannot be listed as that account"
}
record_context() {   # $1 = record index
  local i="$1" line gh_token="" github_token="" tok_line
  rec_tok=""; rec_acct=""; rec_unread=""; rec_repo_env=""
  while IFS= read -r line; do
    case "$line" in
      GH_TOKEN=*) gh_token="$line" ;;
      GITHUB_TOKEN=*) github_token="$line" ;;
      # gh asks another host altogether; the pull requests on github.com say nothing about it.
      GH_HOST=*) [ "${line#GH_HOST=}" = github.com ] || rec_unread="$line" ;;
      GH_REPO=*) rec_repo_env="${line#GH_REPO=}" ;;
    esac
  done <<< "${PS__R_ASSIGNS[$i]}"
  # gh reads GH_TOKEN first, then GITHUB_TOKEN.
  tok_line="${gh_token:-$github_token}"
  if [ -n "$tok_line" ]; then
    # The one account form the shared reader accepts (lib/shell-words.py DATA_TOKEN_PREFIX), compared
    # as a literal rather than matched word by word (lib/word-position-scan.py); any other spelling
    # of it cannot be read, so it refuses below.
    local tok_val="${tok_line#*=}" acct_pre='$(gh auth token -u ' acct_try=""
    if [[ "$tok_val" == "$acct_pre"*")" ]]; then acct_try="${tok_val#"$acct_pre"}"; acct_try="${acct_try%)}"; fi
    if [ -n "$acct_try" ] && [ "${#acct_try}" -le 39 ] && [[ "$acct_try" =~ ^[A-Za-z0-9]+(-[A-Za-z0-9]+)*$ ]]; then
      rec_acct="$acct_try"
    else
      case "$tok_line" in
        *'$'*|*'`'*) [ -n "$rec_unread" ] || rec_unread="$tok_line" ;;
        *) rec_tok="${tok_line#*=}" ;;
      esac
    fi
  fi
  # The directory it runs in: its own git -C, then the cd in force for it, then the session's.
  rec_dir="$cwd"
  [ -n "${PS__R_DIR[$i]}" ] && rec_dir="$(ps__named_path "${PS__R_DIR[$i]}" "$cwd")"
  if [ -n "${PS__R_GITDIR[$i]}" ]; then rec_dir="$(ps__named_path "${PS__R_GITDIR[$i]}" "$rec_dir")"; fi
}
repo_env_readable() {
  case "$rec_repo_env" in
    *'$'*|*'`'*) unknown "this sets GH_REPO=$rec_repo_env, whose value cannot be read before the command runs, so which repository the delete hits cannot be established" ;;
  esac
}
origin_slug() {   # owner/name of the checkout's origin, or nothing
  [ -d "$rec_dir" ] || return 0
  sp_github_slug "$(git -C "$rec_dir" remote get-url origin 2>/dev/null)"
}

# ---- what a command deletes ----
# Each target is "<kind> 0x1f <owner/name> 0x1f <branch> 0x1f <merged pr> 0x1f <its base> 0x1f
# <method flags>", the last three for a merge only. A command whose target cannot be told is
# refused at once, by unknown.
targets=()
unknown() {   # $1 = what could not be told
  echo "BLOCKED: $1, so whether deleting that branch would close an open pull request based on it cannot be told (claude-config#1723). If this refusal is wrong, say so and add SKIP_STACKED_CHECK=1 to that one command." >&2
  exit 2
}
branch_of_ref() {   # $1 = a ref as written; prints the branch, or nothing for a tag or other ref
  local r="${1#+}"
  r="${r//%2F//}"; r="${r//%2f//}"
  case "$r" in
    refs/heads/*) printf '%s' "${r#refs/heads/}" ;;
    refs/*|"") ;;
    *) printf '%s' "$r" ;;
  esac
}

# gh api --hostname sends the call to another GitHub (an Enterprise server, or a ghe.com tenant).
# Deleting a branch there closes the pull requests based on it just as on github.com, so it is this
# gate's business, but the gate lists pull requests on github.com only and cannot ask that host. It
# refuses, as it does for GH_HOST (record_context), and never lists a same named github.com
# repository in its place, whose answer says nothing about the host the delete hits (#1758).
host_ready() {   # $1 = the --hostname value as written, or empty  $2 = what the command does, a clause
  local h
  h="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$h" in ""|github.com) return 0 ;; esac
  unknown "this $2 on $1 (its --hostname), not on github.com, and this gate lists pull requests on github.com only, so it cannot ask $1 whether one is based on that branch"
}

api_target() {   # PS_RUN_ARGS of a gh api
  local -a w=(${PS_RUN_ARGS[@]+"${PS_RUN_ARGS[@]}"})
  local i n=${#w[@]} t method="" endpoint="" host="" slug branch said
  for ((i = 0; i < n; i++)); do
    t="${w[$i]}"
    case "$t" in
      -X|--method) method="${w[$((i+1))]:-}"; i=$((i+1)) ;;
      --method=*) method="${t#--method=}" ;;
      -X*) method="${t#-X}" ;;
      --hostname) host="${w[$((i+1))]:-}"; i=$((i+1)) ;;
      --hostname=*) host="${t#--hostname=}" ;;
      -H|--header|-f|--raw-field|-F|--field|--input|-q|--jq|-t|--template|--cache|-p|--preview) i=$((i+1)) ;;
      -*) ;;
      *) [ -n "$endpoint" ] || endpoint="$t" ;;
    esac
  done
  # gh api takes a full URL as its endpoint too, and then asks the host in it, whatever --hostname
  # says: api.github.com is github.com, and any other host is another GitHub, whose REST paths sit
  # under /api/v3 and GraphQL at /api/graphql. Read as the path it names (#1758: a full URL used to
  # pass a branch delete unjudged).
  if [[ "$endpoint" =~ ^[Hh][Tt][Tt][Pp][Ss]?://([^/?#]+)([^?#]*) ]]; then
    host="$(printf '%s' "${BASH_REMATCH[1]##*@}" | tr '[:upper:]' '[:lower:]')"; host="${host%%:*}"
    endpoint="${BASH_REMATCH[2]#/}"
    case "$host" in
      api.github.com) host=github.com ;;
      *) endpoint="${endpoint#api/v3/}"; [ "$endpoint" = api/graphql ] && endpoint=graphql ;;
    esac
  fi
  if [ "$endpoint" = graphql ]; then graphql_target "$host"; return; fi
  method="$(printf '%s' "$method" | tr '[:lower:]' '[:upper:]')"
  [ "$method" = DELETE ] || return 0
  [[ "${endpoint#/}" =~ ^repos/([^/]+)/([^/]+)/git/refs/heads/(.+)$ ]] || return 0
  slug="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  branch="$(branch_of_ref "${BASH_REMATCH[3]}")"
  [ -n "$branch" ] || return 0
  host_ready "$host" "deletes branch $branch"
  # gh fills {branch} and :branch with the branch checked out where the command runs (git
  # symbolic-ref HEAD), and fails when none is: a detached HEAD, or no checkout. It refuses the
  # placeholder outright under GH_REPO, so nothing is deleted then. Reading it literally listed the
  # pull requests based on a branch named {branch}, found none, and passed (#1758).
  local cur="" br_re='[{]branch[}]|:branch([^A-Za-z0-9_]|$)' colon_re='^(.*):branch([^A-Za-z0-9_].*)?$'
  if [[ "$branch" =~ $br_re ]]; then
    [ -z "$rec_repo_env" ] || return 0
    [ -d "$rec_dir" ] && cur="$(git -C "$rec_dir" symbolic-ref --quiet --short HEAD 2>/dev/null)"
    [ -n "$cur" ] || unknown "this deletes the branch gh fills {branch} with, and no branch is checked out in $rec_dir (a detached HEAD, or not a git checkout), so which branch that is cannot be told"
    branch="${branch//\{branch\}/$cur}"
    while [[ "$branch" =~ $colon_re ]]; do branch="${BASH_REMATCH[1]}$cur${BASH_REMATCH[2]}"; done
  fi
  case "$slug" in
    "{owner}/{repo}"|":owner/:repo")
      repo_env_readable
      slug="$rec_repo_env"
      # gh fills the placeholders with the FIRST of the remotes upstream, github and origin (its
      # BaseRepoFunc), not with origin, so in a fork's checkout (origin the fork, upstream the
      # parent) the delete hits the parent, where the fork's pull requests are based. Reading
      # origin listed the fork's, found none, and let the delete through (#1758). So gh itself is
      # asked, where the command runs and as the account it runs as.
      if [ -z "$slug" ]; then
        account_ready
        [ -d "$rec_dir" ] || unknown "this deletes branch $branch with {owner}/{repo} from $rec_dir, which is not there, so which repository that stands for cannot be read"
        if ! said="$(cd "$rec_dir" && run_gh api 'repos/{owner}/{repo}' --jq .full_name 2>&1)" \
          || [[ ! "$said" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
          unknown "this deletes branch $branch with {owner}/{repo}, and gh could not say which repository that stands for in $rec_dir (gh said: ${said:0:300})"
        fi
        slug="$said"
      fi ;;
  esac
  targets+=("api"$'\x1f'"$slug"$'\x1f'"$branch")
}

# A GraphQL deleteRef names its ref by a node id, never by name, so the ids are read from the
# mutation (a refId literal, or the variable it names, from -f/-F fields or an --input body) and
# GitHub is asked which ref, in which repository, each one is. An updateRefs names its refs but its
# repository by a node id, which GitHub is asked to name. One the gate cannot read (a shell
# expansion, a body on standard input, a file not there yet) refuses: a delete it cannot place is
# the delete this exists to see. A GraphQL call naming neither is not asked about (#1758).
graphql_target() {   # $1 = the --hostname value, or empty; PS_RUN_ARGS of the gh api
  local found kind rid node info prefix slug name py
  # Read into a variable rather than a heredoc inside $( ): bash 3.2, /bin/bash on macOS, misparses
  # quotes in a heredoc nested in a command substitution.
  IFS= read -r -d '' py <<'PY' || true
import json, os, re, sys

rec_dir, cmd_text, words = sys.argv[1], sys.argv[2], sys.argv[3:]
DELETE_REF = re.compile(r'\bdeleteRef\s*\(')
UPDATE_REFS = re.compile(r'\bupdateRefs\s*\(')
TAKES_VALUE = {'-H', '--header', '-q', '--jq', '-t', '--template', '--cache', '-p', '--preview',
               '-X', '--method', '--hostname'}
fields, inputs = [], []   # fields: (name=value as written, typed)
i = 0
while i < len(words):
    t = words[i]
    nxt = words[i + 1] if i + 1 < len(words) else ''
    if t in ('-f', '--raw-field', '-F', '--field'):
        fields.append((nxt, t in ('-F', '--field'))); i += 2; continue
    if t.startswith('--raw-field=') or t.startswith('--field='):
        fields.append((t.split('=', 1)[1], t.startswith('--field='))); i += 1; continue
    if len(t) > 2 and t[:2] in ('-f', '-F'):
        fields.append((t[2:], t[1] == 'F')); i += 1; continue
    if t == '--input':
        inputs.append(nxt); i += 2; continue
    if t.startswith('--input='):
        inputs.append(t[len('--input='):]); i += 1; continue
    i += 2 if t in TAKES_VALUE else 1

unread, queries, variables = [], [], {}

def read(path):
    if path == '-':
        unread.append('standard input'); return None
    full = path if os.path.isabs(path) else os.path.join(rec_dir, path)
    try:
        with open(full, encoding='utf-8', errors='replace') as f:
            return f.read()
    except OSError:
        unread.append(path + ' (not there before the command runs)'); return None

for spec, typed in fields:
    name, eq, value = spec.partition('=')
    if not eq:
        continue
    if typed and value.startswith('@'):
        value = read(value[1:])
        if value is None:
            continue
    if name == 'query':
        queries.append(value)
    elif name != 'operationName':
        nested = re.fullmatch(r'(\w+)\[(\w+)\]', name)
        if nested:
            inner = variables.setdefault(nested.group(1), {})
            if isinstance(inner, dict):
                inner[nested.group(2)] = value
        else:
            variables[name] = value
for path in inputs:
    body = read(path)
    if body is None:
        continue
    try:
        doc = json.loads(body)
    except ValueError:
        queries.append(body); continue
    if isinstance(doc, dict):
        if isinstance(doc.get('query'), str):
            queries.append(doc['query'])
        if isinstance(doc.get('variables'), dict):
            variables.update(doc['variables'])

def deletes(text):
    return DELETE_REF.search(text) or UPDATE_REFS.search(text)

named = any(deletes(q) for q in queries)
if not named and not (unread and deletes(cmd_text)):
    sys.exit(0)
if unread:
    print('UNKNOWN\tits mutation or variables are read from ' + ', '.join(unread))
    sys.exit(0)

def arguments(q, start):   # the text between the ( at start and its matching )
    depth, k = 0, start
    while k < len(q):
        c = q[k]
        if c == '"':
            k += 1
            while k < len(q) and q[k] != '"':
                k += 2 if q[k] == '\\' else 1
        elif c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0:
                return q[start + 1:k]
        k += 1
    return None

ids = []
for q in queries:
    for m in DELETE_REF.finditer(q):
        args = arguments(q, m.end() - 1)
        rid = None
        if args is not None:
            lit = re.search(r'\brefId\s*:\s*(?:("(?:[^"\\]|\\.)*")|\$(\w+))', args)
            whole = re.search(r'\binput\s*:\s*\$(\w+)', args)
            if lit and lit.group(1):
                rid = json.loads(lit.group(1))
            elif lit:
                rid = variables.get(lit.group(2))
            elif whole and isinstance(variables.get(whole.group(1)), dict):
                rid = variables[whole.group(1)].get('refId')
        if not isinstance(rid, str) or not rid or re.search(r'[$`\s]', rid):
            print('UNKNOWN\tthe ref id it deletes is not written in the command as a value this gate can read')
            sys.exit(0)
        if rid not in ids:
            ids.append(rid)

# updateRefs deletes every ref in refUpdates whose afterOid is all zeros (GitHub's schema: "A value
# of 0000000000000000000000000000000000000000 can be used to delete a reference"), in the repository
# its repositoryId names. Its input is read as a GraphQL value, literals and $variables alike.
class Unreadable(Exception):
    pass

def skip(q, k):
    while k < len(q):
        if q[k] in ' \t\r\n,':
            k += 1
        elif q[k] == '#':
            while k < len(q) and q[k] != '\n':
                k += 1
        else:
            break
    return k

def value(q, k):   # a GraphQL value at k: (it, the index after it); a variable is resolved
    k = skip(q, k)
    if k >= len(q):
        raise Unreadable
    c = q[k]
    if c == '$':
        m = re.compile(r'\$(\w+)').match(q, k)
        if not m or m.group(1) not in variables:
            raise Unreadable
        return variables[m.group(1)], m.end()
    if c == '"':
        m = re.compile(r'"(?:[^"\\]|\\.)*"').match(q, k)
        if q.startswith('"""', k) or not m:
            raise Unreadable
        return json.loads(m.group(0)), m.end()
    if c in '[{':
        out, close, k = ([] if c == '[' else {}), (']' if c == '[' else '}'), k + 1
        while True:
            k = skip(q, k)
            if k >= len(q):
                raise Unreadable
            if q[k] == close:
                return out, k + 1
            if c == '[':
                v, k = value(q, k)
                out.append(v)
            else:
                m = re.compile(r'(\w+)\s*:').match(q, k)
                if not m:
                    raise Unreadable
                v, k = value(q, m.end())
                out[m.group(1)] = v
    m = re.compile(r'[-\w.+]+').match(q, k)
    if not m:
        raise Unreadable
    return m.group(0), m.end()

def shell_text(v):   # a value still holding a shell expansion was never read
    return not isinstance(v, str) or re.search(r'[$`]', v)

updates = []
for q in queries:
    for m in UPDATE_REFS.finditer(q):
        try:
            # Its argument list read as the fields of one object: (input: {...}) as {input: {...}}.
            args, _ = value('{' + (arguments(q, m.end() - 1) or '') + '}', 0)
            inp = args.get('input')
            if not isinstance(inp, dict) or not isinstance(inp.get('refUpdates'), list):
                raise Unreadable
            gone = []
            for u in inp['refUpdates']:
                if not isinstance(u, dict) or shell_text(u.get('name')) or shell_text(u.get('afterOid')):
                    raise Unreadable
                if re.fullmatch(r'0+', u['afterOid']) and u['name'].startswith('refs/heads/'):
                    gone.append(u['name'][len('refs/heads/'):])
            if gone and (shell_text(inp.get('repositoryId')) or not inp['repositoryId'] or re.search(r'\s', inp['repositoryId'])):
                raise Unreadable
        except (Unreadable, ValueError):
            print('UNKNOWN\tthe refs its updateRefs changes, or the repository they are in, are not written in the command as values this gate can read')
            sys.exit(0)
        for b in gone:
            if (inp['repositoryId'], b) not in updates:
                updates.append((inp['repositoryId'], b))

for rid in ids:
    print('ID\t' + rid)
for repo_id, b in updates:
    print('UPD\t' + repo_id + '\t' + b)
PY
  found="$(python3 -c "$py" "$rec_dir" "$cmd" ${PS_RUN_ARGS[@]+"${PS_RUN_ARGS[@]}"})" || unknown "this runs a GraphQL call, and its mutation could not be read to tell whether it deletes a ref"
  [ -n "$found" ] || return 0
  while IFS=$'\t' read -r kind rid name; do
    [ "$kind" = UNKNOWN ] && unknown "this runs a GraphQL deleteRef or updateRefs, and $rid, so which branch it deletes cannot be told"
  done <<< "$found"
  host_ready "$1" "runs a GraphQL deleteRef or updateRefs"
  account_ready
  # One lookup names either kind of node id: a deleteRef's ref (its name, prefix and repository) or
  # an updateRefs repository (its nameWithOwner). Each answer names its repository itself.
  while IFS=$'\t' read -r kind rid name; do
    case "$kind" in ID|UPD) ;; *) continue ;; esac
    node="$(run_gh api graphql -f query='query($id: ID!) { node(id: $id) { ... on Ref { name prefix repository { nameWithOwner } } ... on Repository { nameWithOwner } } }' -f id="$rid" 2>&1)"
    if [ "$kind" = UPD ]; then
      slug="$(jq -r '.data.node.nameWithOwner | if type == "string" and . != "" then . else error("no repository") end' <<< "$node" 2>/dev/null)" \
        || unknown "this runs a GraphQL updateRefs deleting branch $name in the repository $rid, and GitHub did not say which repository that is (GitHub said: ${node:0:300})"
      targets+=("api"$'\x1f'"$slug"$'\x1f'"$name")
      continue
    fi
    info="$(jq -r '.data.node | if type == "object" and (.prefix | type == "string") and (.name | type == "string") and (.repository.nameWithOwner | type == "string") then [.prefix, .repository.nameWithOwner, .name] | join("\u001f") else error("no ref") end' <<< "$node" 2>/dev/null)" \
      || unknown "this runs a GraphQL deleteRef of $rid, and GitHub did not say which ref that is (GitHub said: ${node:0:300})"
    IFS=$'\x1f' read -r prefix slug name <<< "$info"
    # A tag or any other ref has no pull request based on it.
    [ "$prefix" = refs/heads/ ] || continue
    targets+=("api"$'\x1f'"$slug"$'\x1f'"$name")
  done <<< "$found"
}

push_target() {   # PS_RUN_ARGS of a git push
  local -a w=(${PS_RUN_ARGS[@]+"${PS_RUN_ARGS[@]}"}) pos=()
  local i n=${#w[@]} t c deleting="" remote="" url slug ref branch
  for ((i = 0; i < n; i++)); do
    t="${w[$i]}"
    case "$t" in
      --) pos+=("${w[@]:$((i+1))}"); break ;;
      --delete) deleting=1 ;;
      --repo=*) remote="${t#--repo=}" ;;
      --repo) remote="${w[$((i+1))]:-}"; i=$((i+1)) ;;
      --push-option|--receive-pack|--exec) i=$((i+1)) ;;
      --*) ;;
      -?*)
        c="${t#-}"
        while [ -n "$c" ]; do
          case "${c:0:1}" in
            d) deleting=1 ;;
            # -o takes a value: the rest of the cluster, or the next word when it ends it.
            o) [ "${#c}" -eq 1 ] && i=$((i+1)); break ;;
          esac
          c="${c:1}"
        done ;;
      *) pos+=("$t") ;;
    esac
  done
  [ "${#pos[@]}" -gt 0 ] || return 0
  if [ -z "$remote" ]; then remote="${pos[0]}"; pos=("${pos[@]:1}"); fi
  # git reads the first word as the remote, always: with no word there is nothing to delete, and a
  # word it cannot resolve is never taken for a remote off GitHub, since a delete it cannot place
  # is the delete this exists to see (lessons review of claude-config#1723). Plainly off GitHub: a
  # URL to another host (sp_github_slug below), or a path on this disk.
  # A word holding a colon is a URL to git (a remote's name cannot hold one): host:path, or a
  # scheme. It is expanded through any url.<base>.insteadOf, as git does before it pushes.
  case "$remote" in
    *:*)
      if [ -d "$rec_dir" ]; then url="$(git -C "$rec_dir" ls-remote --get-url "$remote" 2>/dev/null)"; else url="$(git ls-remote --get-url "$remote" 2>/dev/null)"; fi
      [ -n "$url" ] || url="$remote" ;;
    /*|./*|../*|"~"*|.|..) return 0 ;;
    *)
      [ -d "$rec_dir" ] || unknown "this pushes a delete to $remote from $rec_dir, which is not there, so which repository $remote names cannot be read"
      # git resolves a configured remote BEFORE a path of the same name, so it is asked first: a
      # file named origin in the checkout must not hide the origin remote. A push goes to the
      # remote's push address (pushurl, pushInsteadOf) when it has one, so that is what is read.
      if ! url="$(git -C "$rec_dir" remote get-url --push "$remote" 2>/dev/null)"; then
        [ -e "$rec_dir/$remote" ] && return 0
        unknown "this pushes a delete to $remote, which git in $rec_dir does not resolve to a remote, so whether it is on GitHub cannot be told"
      fi ;;
  esac
  slug="$(sp_github_slug "$url")"
  case $? in
    0) ;;
    1) return 0 ;;
    *) unknown "this pushes a delete to $url, which is on github.com but names no owner/name this gate can read, so which repository the delete hits cannot be established" ;;
  esac
  for ref in ${pos[@]+"${pos[@]}"}; do
    if [ -z "$deleting" ]; then
      case "$ref" in :*|+:*) ref="${ref#*:}" ;; *) continue ;; esac
    fi
    branch="$(branch_of_ref "$ref")"
    [ -n "$branch" ] && targets+=("push"$'\x1f'"$slug"$'\x1f'"$branch")
  done
}

merge_target() {   # PS_RUN_ARGS of a gh pr merge
  local -a w=(${PS_RUN_ARGS[@]+"${PS_RUN_ARGS[@]}"}) view_args=()
  local i n=${#w[@]} t c deleting="" repo="" sel="" methods="" out slug
  for ((i = 0; i < n; i++)); do
    t="${w[$i]}"
    case "$t" in
      --) break ;;
      --delete-branch|--delete-branch=true) deleting=1 ;;
      --squash|--squash=true) methods="$methods --squash" ;;
      --merge|--merge=true) methods="$methods --merge" ;;
      --rebase|--rebase=true) methods="$methods --rebase" ;;
      --repo|-R) repo="${w[$((i+1))]:-}"; i=$((i+1)) ;;
      --repo=*) repo="${t#--repo=}" ;;
      --body|--body-file|--subject|--author-email|--match-head-commit) i=$((i+1)) ;;
      --*) ;;
      -?*)
        c="${t#-}"
        while [ -n "$c" ]; do
          case "${c:0:1}" in
            s) methods="$methods --squash" ;;
            m) methods="$methods --merge" ;;
            r) methods="$methods --rebase" ;;
            d) deleting=1 ;;
            # A flag taking a value takes the rest of the cluster, or the next word when it ends it.
            R) if [ "${#c}" -eq 1 ]; then repo="${w[$((i+1))]:-}"; i=$((i+1)); else repo="${c:1}"; fi; break ;;
            b|F|t|A) [ "${#c}" -eq 1 ] && i=$((i+1)); break ;;
            *) break ;;
          esac
          c="${c:1}"
        done ;;
      *) [ -n "$sel" ] || sel="$t" ;;
    esac
  done
  [ -n "$deleting" ] || return 0
  [ -n "$repo" ] || { repo_env_readable; repo="$rec_repo_env"; }
  [ -n "$sel" ] && view_args+=("$sel")
  [ -n "$repo" ] && view_args+=(--repo "$repo")
  account_ready
  if ! out="$(cd "${rec_dir:-.}" 2>/dev/null && run_gh pr view ${view_args[@]+"${view_args[@]}"} --json number,url,headRefName,baseRefName,isCrossRepository 2>&1)" \
    || ! jq -e 'type == "object" and (.headRefName | type == "string")' >/dev/null 2>&1 <<< "$out"; then
    unknown "this merges with --delete-branch, and this gate could not read the pull request it merges (GitHub said: ${out:0:300}), so which branch it would delete is not known"
  fi
  [ "$(jq -r '.isCrossRepository // false' <<< "$out")" = true ] && return 0
  slug="$(sp_github_slug "$(jq -r '.url // ""' <<< "$out" | sed -E 's#/pull/[0-9]+.*$##')")"
  [ -n "$slug" ] || slug="${repo:-$(origin_slug)}"
  [ -n "$slug" ] || unknown "this merges with --delete-branch, and the repository it merges in could not be told"
  targets+=("merge"$'\x1f'"$slug"$'\x1f'"$(jq -r '.headRefName' <<< "$out")"$'\x1f'"$(jq -r '.number // ""' <<< "$out")"$'\x1f'"$(jq -r '.baseRefName // ""' <<< "$out")"$'\x1f'"$methods")
}

# ---- judge every command in the line ----
refusals=""
judge_target() {   # $1 = a target
  local kind slug branch pr base methods nums n list="" moves="" merged_base out
  IFS=$'\x1f' read -r kind slug branch pr base methods <<< "$1"
  account_ready
  if ! sp_read_stacked run_gh "$slug" "$branch"; then
    refusals+="BLOCKED: this deletes branch $branch in $slug, and this gate could not list the open pull requests based on it (GitHub said: ${SP_OUT:0:300}, exit $SP_RC), so whether deleting it would close any cannot be told. GitHub closes a pull request the moment its base branch is deleted, and a closed pull request's base can never be changed again (claude-config#1723). List them yourself with gh pr list --repo $slug --base $branch --state open, move any onto the branch the merged pull request went into, and then delete. If this refusal is wrong, say so and add SKIP_STACKED_CHECK=1 to that one command."$'\n'
    return
  fi
  nums="$SP_STACKED"
  [ -n "$nums" ] || return 0
  for n in $nums; do
    case "$n" in ''|*[!0-9]*) unknown "GitHub listed '$n' among the pull requests based on $branch in $slug, which is not a number" ;; esac
    list="$list #$n"
  done
  if [ "$kind" = merge ]; then
    [ -n "$base" ] || base="the merged pull request's base"
    refusals+="BLOCKED: gh pr merge --delete-branch deletes branch $branch in $slug as it merges #$pr, and that would close the open pull request(s) based on it:$list. GitHub closes a pull request the moment its base branch is deleted, and a closed pull request's base can never be changed again, so it would have to be opened again as a new one (claude-config#1723). Merge with the helper instead, which merges, moves each onto $base and only then deletes the branch:"$'\n'"  bash ~/.claude/hooks/lib/merge-when-ready.sh $pr --repo $slug${methods} --delete-branch"$'\n'"If this refusal is wrong, say so and add SKIP_STACKED_CHECK=1 to that one command."$'\n'
    return
  fi
  # The base to move them onto is the one the merged pull request from this branch went into, read,
  # never guessed: a branch of a stack merges into its parent, not always the default branch.
  merged_base=""
  if out="$(run_gh pr list --repo "$slug" --head "$branch" --state merged --limit 1 --json number,baseRefName 2>/dev/null)"; then
    merged_base="$(jq -r 'if type == "array" then (.[0].baseRefName // "") else "" end' <<< "$out" 2>/dev/null)"
  fi
  if [ -n "$merged_base" ]; then
    for n in $nums; do moves="$moves"$'\n'"  gh pr edit $n --repo $slug --base $merged_base"; done
    moves="Move each onto $merged_base, the branch the merged pull request from $branch went into, and then delete:$moves"
  else
    moves="No merged pull request from $branch was found to say which branch they belong on; move each onto the branch its parent merged into (gh pr edit <number> --repo $slug --base <that branch>), and then delete."
  fi
  refusals+="BLOCKED: deleting branch $branch in $slug would close the open pull request(s) based on it:$list. GitHub closes a pull request the moment its base branch is deleted through the API or a push, and a closed pull request's base can never be changed again, so it would have to be opened again as a new one (claude-config#1723). $moves"$'\n'"If this refusal is wrong, say so and add SKIP_STACKED_CHECK=1 to that one command."$'\n'
}

# Each command's targets are judged before the next is read, so the list is asked as the account
# that command runs as, in the directory it runs in.
i="${PS__M_FIRST[$PS__HIT]}"; end=$((i + PS__M_COUNT[PS__HIT]))
while [ "$i" -lt "$end" ]; do
  targets=()
  if ps_runs_at gh "$i" api; then
    record_context "$i"; api_target
  elif ps_runs_at git "$i" push; then
    record_context "$i"; push_target
  elif ps_runs_at gh "$i" pr merge; then
    record_context "$i"; merge_target
  fi
  if [ "${#targets[@]}" -gt 0 ]; then for t in "${targets[@]}"; do judge_target "$t"; done; fi
  i=$((i + 1))
done
[ -n "$refusals" ] || exit 0
printf '%s' "$refusals" >&2
exit 2
