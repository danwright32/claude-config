#!/usr/bin/env bash
#
# failure-handling.sh: does this added code HANDLE FAILURE? (claude-config#1477)
#
# The one predicate behind every gate that asks whether a change touches error handling or a retry:
#   lessons-advisory.sh          the "error path returning empty" and "retry or failure handling"
#                                triggers (fh_catch, fh_retry)
#   require-tests-before-push.sh the judge's failure path SPECIAL CASE is told which files these are
#                                (fh_files)
#   lib/ai-review-run.py         the lessons review is told the same list (`failure-handling.sh files`)
#   lessons-advisory.sh          its background work and fixed wait triggers read fh_code_only too
#                                (claude-config#1540), so every advisory trigger that matches words
#                                in code reads the same code
#
# WHY IT EXISTS. On 2026-10-21 Bidspoke PR #2630 was held because a test file was "new retry or
# failure-handling logic" needing a failure path test. The file held none: the advisory's word list
# matched `retries_assumed: 2`, a field of a mocked response, and the file's other candidate was a
# select option labelled 'Fail the run'. A word list cannot tell a word from a construct, and each
# gate kept its own idea of the question, so they disagreed without anyone seeing it (L261, L370).
#
# WHAT IT JUDGES. Code constructs, read from the added lines with string literal CONTENTS and
# comments removed (fh_code_only), by the file's language:
#   catch     catch (...) / catch { / .catch( / Swift catch let|var|is / Python except ...: / Ruby rescue
#   retry     an identifier naming a retry (withRetry, MAX_RETRIES, mt_retry_read), backoff,
#             exponential, maxAttempts, a loop over attempts or tries, exponent arithmetic on an attempt
#   errors    throw / raise, try { / try: / try? / try!, err != nil, if (err|error), .ok, a status or
#             return code compared, onError, and in shell `|| {` `|| exit|return`, `if !`, `$?`, trap
# fh_handles_failure is any of the three; the advisory asks the narrower two by name.
#
# ONE EXEMPTION, in test files only: a retry word that appears only as a KEY given a LITERAL value
# (`retries_assumed: 2,`) is fixture data. The same key in source still counts, because there it is
# configuration of real behaviour (a Playwright config's `retries: 2`), and a real retry call in a
# test file (`await retry(...)`) still counts, because it is code (L104).
#
# A non empty string keeps one placeholder character (`"x"` reads as `"S"`), so `return "x"` is never
# mistaken for the empty `return ""` the advisory's error path trigger looks for.
#
# WHAT IT CANNOT SEE. Added lines arrive without the lines around them, so the hunk can begin inside
# a docstring, block comment or template opened above it. The close of one is recognised (a lone or
# trailing triple quote, a */, a ` * ` comment line) so it does not swallow the code after it, which
# it did on two real commits before this was handled; a docstring's middle lines, a heredoc body, and
# code embedded in a string (a page or a browser script held as data) are read wrongly, the first two
# as code (erring toward firing) and the last as data. Prose files (.md, .txt, .rst, .adoc) carry
# no code. Measured against 150 merged pull requests in claude-config and 60 in Overture before it
# shipped: every flag it dropped was a word in a comment, string, label, doc or fixture.
#
# SHELL STRINGS (claude-config#1540). A quoted shell string is a PROGRAM when the command it belongs
# to runs one (awk, sed, jq, a shell, python, node, perl, ruby, eval, trap, ssh, watch): its text
# stays code. Handed to any other command (a test helper, printf, echo, grep) it is data, which is
# what the #1477 suite fixtures were. A single quote left open at the end of a line keeps its text as
# code, because it usually closes a program opened above the hunk and what follows is the code that
# runs it. What this reads as data although it runs: a script written out by printf or an escaped
# heredoc and run later, and a command string piped into a shell or run through a variable.
#
# Sourced by the shell callers; run as `bash failure-handling.sh files < diff` by the rest, which
# prints each file whose added code handles failure, one per line, in diff order.

# Its own folder by parameter expansion, never dirname, which a caller's PATH may lack (#1104).
FH_LIB_DIR="${BASH_SOURCE[0]%/*}"; [ "$FH_LIB_DIR" != "${BASH_SOURCE[0]}" ] || FH_LIB_DIR=.; FH_LIB_DIR="$(cd "${FH_LIB_DIR:-/}" && pwd)"
# shellcheck source=lib/source-class.sh
declare -F is_test >/dev/null 2>&1 || . "$FH_LIB_DIR/source-class.sh"

# The language family a path is read as. prose has no code; shell keeps $expansions inside double
# quotes, and a string handed to a program runner, as code (SHELL STRINGS above); hash languages comment with #;
# slash languages with // and /* */; sql with --.
fh_lang() {   # $1 = path
  local base="${1##*/}"
  case "$base" in
    *.md|*.markdown|*.txt|*.rst|*.adoc) echo prose ;;
    *.sh|*.bash|*.zsh) echo shell ;;
    *.py|*.pyi) echo python ;;
    *.rb|*.rake) echo ruby ;;
    *.yml|*.yaml|*.toml|*.pl|*.r|*.R|*.mk|*.cfg|*.conf|*.ini|Makefile|Dockerfile) echo hash ;;
    *.sql) echo sql ;;
    *.*) echo slash ;;
    *) echo shell ;;   # no extension: a script here is a shell script (claude-sync, the bin/ tools)
  esac
}

# The awk that does the work. `want` is code (print the normalized lines), catch, retry or any (exit
# 0 when the construct is present, 1 when not). One pass, so a large pushed file costs one read.
FH_AWK='
function keep_expansion(s, i,   c, d, j) {
  # A shell $expansion inside double quotes is code: $name, ${...}, $(...), $((...)).
  c = substr(s, i + 1, 1)
  if (c == "(") {
    d = 0
    for (j = i + 1; j <= length(s); j++) {
      c = substr(s, j, 1)
      if (c == "(") d++
      else if (c == ")") { d--; if (d == 0) break }
    }
    return j
  }
  if (c == "{") { j = index(substr(s, i + 1), "}"); return (j ? i + j : length(s)) }
  for (j = i + 1; j <= length(s) && substr(s, j, 1) ~ /[A-Za-z0-9_]/; j++) ;
  return j - 1
}
function template_expr_end(s, i,   d, j, c) {
  # The ${...} of a template literal is code, and may hold another template with its own ${...}, so
  # it ends at the brace that balances its opening one, never at the first } (9ed36c578 lost five
  # real catches to that misread).
  d = 0
  for (j = i + 1; j <= length(s); j++) {
    c = substr(s, j, 1)
    if (c == "{") d++
    else if (c == "}") { d--; if (d == 0) return j }
  }
  return length(s)
}
function closes_unseen(s, i,   before, after) {
  # A triple quote met outside any string, on lines that may begin INSIDE a string opened above the
  # hunk: is it the CLOSE of that string? Yes when it stands alone on its line, or follows text that
  # cannot open a string (an opener follows = ( [ { , : + % or return, yield, or, and, else, in, is,
  # not, lambda, or a prefix such as r f b). Read as an opening instead, it swallowed the code after
  # it (ef1291176 lost a real except that way).
  before = substr(s, 1, i - 1); after = substr(s, i + 3)
  sub(/[ \t]+$/, "", before); sub(/^[ \t]+/, "", before); sub(/[ \t]+$/, "", after)
  if (before == "") return (after == "")
  if (before ~ /[=(\[{,:+%]$/) return 0
  if (before ~ /(^|[^A-Za-z0-9_])(return|yield|or|and|else|in|is|not|lambda|print)$/) return 0
  if (before ~ /(^|[^A-Za-z0-9_])[rRbBfFuU]{1,2}$/) return 0
  return 1
}
function normalize(s,   out, i, c, n, nx, k) {
  out = ""; n = length(s); i = 1
  # A slash language line that is the middle of a block comment opened above the hunk.
  if (lang == "slash" && !block && triple == "" && !tmpl && s ~ /^[ \t]*\*([ \t\/]|$)/) {
    k = index(s, "*/")
    if (!k) return ""
    i = k + 2
  }
  while (i <= n) {
    c = substr(s, i, 1); nx = substr(s, i, 2)
    if (block) { if (nx == "*/") { block = 0; i += 2 } else i++; continue }
    if (triple != "") {
      if (substr(s, i, 3) == triple) { out = out (qn ? "S" : "") triple; triple = ""; i += 3 } else { qn++; i++ }
      continue
    }
    if (tmpl) {
      if (c == "\\") { qn++; i += 2; continue }
      if (c == "`") { out = out (qn ? "S" : "") "`"; tmpl = 0; i++; continue }
      if (nx == "${") { k = template_expr_end(s, i); out = out substr(s, i, k - i + 1); i = k + 1; continue }
      qn++; i++; continue
    }
    if (q != "") {
      if (qcode) {
        # A program handed to a command that runs it: its text is code, copied as it stands.
        if (q == "\"" && c == "\\") { out = out substr(s, i, 2); i += 2; continue }
        if (c == q) { out = out q; q = ""; qcode = 0; i++; continue }
        out = out c; i++; continue
      }
      # Inside shell single quotes a backslash is an ordinary character, never an escape.
      if (c == "\\" && !(lang == "shell" && q == "\x27")) { qn++; i += 2; continue }
      if (c == q) { out = out (qn ? "S" : "") q; q = ""; i++; continue }
      if (lang == "shell" && q == "\"" && (c == "$") && substr(s, i + 1, 1) ~ /[A-Za-z_({]/) {
        k = keep_expansion(s, i); out = out substr(s, i, k - i + 1); i = k + 1; continue
      }
      qn++; i++; continue
    }
    # Outside any string or comment.
    if (lang == "slash" && nx == "//") break
    if (lang == "slash" && nx == "/*") { block = 1; i += 2; continue }
    # The close of a block comment opened above the hunk: what came before it was comment.
    if ((lang == "slash" || lang == "sql") && nx == "*/") { out = ""; i += 2; continue }
    if (lang == "sql" && nx == "--") break
    if (lang == "sql" && nx == "/*") { block = 1; i += 2; continue }
    if ((lang == "shell" || lang == "python" || lang == "ruby" || lang == "hash") && c == "#") {
      if (lang != "shell") break
      # In shell a # opens a comment only at the start of a word, never in $# or ${#x}.
      if (i == 1 || substr(s, i - 1, 1) ~ /[ \t;&|(]/) break
    }
    if ((lang == "python" || lang == "slash") && (substr(s, i, 3) == "\"\"\"" || substr(s, i, 3) == "\x27\x27\x27")) {
      if (closes_unseen(s, i)) { out = ""; i += 3; continue }
      triple = substr(s, i, 3); out = out triple; qn = 0; i += 3; continue
    }
    if (lang == "slash" && c == "`") { tmpl = 1; qn = 0; out = out c; i++; continue }
    if (c == "\"" || c == "\x27") {
      # In shell, a quoted string handed to a command that runs it (awk, a shell, python -c, trap,
      # eval) is a program, so its text stays code; handed to any other command it is data.
      q = c; qn = 0; qcode = (lang == "shell" && runs_program(out)); out = out c; qi = i; qo = length(out); i++; continue
    }
    out = out c; i++
  }
  # A shell single quote still open at the end of the line most often CLOSES a program opened above
  # the hunk (an awk program whose last line reads: quote, "$f" || exit 1), so what follows it is the code that runs it, kept as
  # it stands; when it opens one instead, the text after it is the first line of that program.
  if (lang == "shell" && q == "\x27" && !qcode) out = substr(out, 1, qo) substr(s, qi + 1)
  else if (q != "" && qn) out = out "S"
  q = ""; qcode = 0   # an ordinary string never runs past its line
  return out
}
function runs_program(p,   k, n, t, j, w) {
  # The simple command a quote belongs to is the text after the last | ; & ( or backtick; it runs a
  # program when any of its words, read without a leading path, names something that runs one.
  for (k = length(p); k > 0; k--) if (index("|;&(`", substr(p, k, 1))) break
  n = split(substr(p, k + 1), t, /[ \t]+/)
  for (j = 1; j <= n; j++) {
    w = t[j]; sub(/^.*\//, "", w)
    if (w ~ /^(awk|gawk|mawk|nawk|sed|jq|perl|ruby|node|deno|bun|python[0-9.]*|bash|sh|zsh|dash|ksh|fish|pwsh|osascript|eval|trap|ssh|watch)$/) return 1
  }
  return 0
}
function is_retry_token(t) { return tolower(t) ~ /retr(y|ies|ied|ying)/ }
function is_attempt_token(t) {
  return t ~ /^([Aa]ttempts?|[Tt]ries)$/ || tolower(t) ~ /_(attempts?|tries)$/ || t ~ /[a-z0-9](Attempts?|Tries)$/
}
function has_retry(code, low,   rest, t, after, loop, attempts) {
  if (low ~ /backoff|exponential|maxattempts/) return 1
  if (low ~ /(^|[^a-z0-9_])2[ \t]*\*\*[ \t]*[a-z_$(]/ || low ~ /pow\([ \t]*2[ \t]*,/ || low ~ /(^|[^a-z0-9_])1[ \t]*<<[ \t]*[a-z_$(]/) return 1
  loop = (low ~ /(^|[^a-z0-9_])(for|while|until|repeat)([^a-z0-9_]|$)/)
  attempts = 0
  rest = code
  while (match(rest, /[A-Za-z_][A-Za-z0-9_]*/)) {
    t = substr(rest, RSTART, RLENGTH)
    after = substr(rest, RSTART + RLENGTH)
    rest = after
    if (is_attempt_token(t)) attempts = 1
    if (!is_retry_token(t)) continue
    # Fixture data in a test: a retry word used only as a key given a literal value.
    if (testfile && after ~ /^[ \t]*:[ \t]*(-?[0-9][0-9.]*|true|false|null|nil|none|None|undefined|"S?"|\x27S?\x27)[ \t]*([,}\]]|$)/) continue
    return 1
  }
  return (loop && attempts)
}
function has_catch(low) {
  if (low ~ /(^|[^a-z0-9_])catch[ \t]*[({]/) return 1
  if (low ~ /(^|[^a-z0-9_])catch[ \t]+(let|var|is)([^a-z0-9_]|$)/) return 1
  if (low ~ /^[ \t]*except([ \t]+[^:]*)?[ \t]*:/) return 1
  if (lang == "ruby" && low ~ /(^|[^a-z0-9_])rescue([^a-z0-9_]|$)/) return 1
  return 0
}
function has_error_branch(low) {
  if (low ~ /(^|[^a-z0-9_.])(throw|raise)([^a-z0-9_]|$)/) return 1
  if (low ~ /(^|[^a-z0-9_.])try[ \t]*[:{?!]/) return 1
  if (low ~ /err[ \t]*!=[ \t]*nil/) return 1
  if (low ~ /(^|[^a-z0-9_])if[ \t]*\([ \t]*!?[ \t]*(err|error)[ \t]*\)/) return 1
  if (low ~ /\.ok([^a-z0-9_(]|$)/) return 1
  if (low ~ /(status|statuscode|status_code|returncode|exitcode|exit_code|exitstatus)[ \t]*(===?|!==?|>=?|<=?)/) return 1
  if (low ~ /(^|[^a-z0-9_])on_?error([^a-z0-9_]|$)/) return 1
  if (lang == "shell") {
    if (low ~ /\|\|[ \t]*(\{|exit|return|die|fail|bail)/) return 1
    if (low ~ /(^|[^a-z0-9_])(if|elif|while|until)[ \t]+![ \t]/) return 1
    if (low ~ /\$\?/) return 1
    if (low ~ /(^|[^a-z0-9_])trap[ \t]/) return 1
  }
  return 0
}
BEGIN { block = 0; triple = ""; tmpl = 0; q = ""; qcode = 0; found = 0 }
{
  if (lang == "prose") next
  code = normalize($0)
  if (want == "code") { print code; next }
  low = tolower(code)
  if ((want == "catch" || want == "any") && has_catch(low)) { found = 1; exit }
  if ((want == "retry" || want == "any") && has_retry(code, low)) { found = 1; exit }
  if (want == "any" && has_error_branch(low)) { found = 1; exit }
}
END { if (want != "code") exit !found }
'

fh__run() {   # $1 = want  $2 = path  [$3 = a file of lines; stdin when absent]
  local lang testfile=0
  lang="$(fh_lang "$2")"
  is_test "$2" && testfile=1
  if [ -n "${3:-}" ]; then
    awk -v want="$1" -v lang="$lang" -v testfile="$testfile" "$FH_AWK" "$3"
  else
    awk -v want="$1" -v lang="$lang" -v testfile="$testfile" "$FH_AWK"
  fi
}

# The added lines on stdin, read as code: string literal contents and comments removed.
fh_code_only() {   # $1 = path
  fh__run code "$1"
}

# Each answers by its exit status: 0 when the construct is in the lines, 1 when it is not.
fh_catch() {   # $1 = path  $2 = a file holding the added lines
  fh__run catch "$1" "$2"
}

fh_retry() {   # $1 = path  $2 = a file holding the added lines
  fh__run retry "$1" "$2"
}

fh_handles_failure() {   # $1 = path  $2 = a file holding the added lines
  fh__run any "$1" "$2"
}

# A unified diff on stdin; prints each file whose ADDED lines handle failure, in diff order.
fh_files() {
  local tmp rows f
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/claude-failure-handling.XXXXXXXX")" || return 1
  rows="$tmp/rows"
  awk '
    /^\+\+\+ / { f = substr($0, 5); sub(/^b\//, "", f); if (f == "/dev/null") f = ""; next }
    /^diff --git / { f = ""; next }
    # The lessons review appends whole files AFTER its diff (lib/ai-review-common.sh), so the first
    # such header ends the diff. Their text is not added lines, even a line beginning with + or a
    # diff header quoted inside a test file, so nothing past it is read.
    /^===== FULL FILE / { exit }
    /^\+/ { if (f != "") print f "\t" substr($0, 2) }
  ' > "$rows"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    awk -F'\t' -v want="$f" '$1 == want { print substr($0, length(want) + 2) }' "$rows" > "$tmp/lines"
    fh_handles_failure "$f" "$tmp/lines" && printf '%s\n' "$f"
  done < <(cut -f1 "$rows" | awk '!seen[$0]++')
  rm -rf "$tmp"
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    files) fh_files ;;
    *) echo "usage: bash failure-handling.sh files < unified-diff" >&2; exit 2 ;;
  esac
fi
