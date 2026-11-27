# lib/command-screen.sh: whether a command MAY name a word as the shell reader reads it, asked
# before a gate starts python3 to read the command properly (claude-config#3690).
#
# Every PreToolUse Bash gate runs before every Bash call, all at once. On 2026-11-25 several of them
# started python3 on every call to learn that `uptime; date` was nothing they judge, and while the
# Mac was busy those starts were part of what took the gates on a read only call past their time
# limits. A gate that only judges commands running certain words (gh pr, gh issue, git commit) can
# leave before that start when the command cannot spell any of them.
#
# What "cannot spell" means is the reader's view, not the text's: lib/shell-words.py joins `p''r`,
# `"pr"` and `p\<line break>r` into the word pr, so a match on the raw text would miss them and pass a
# command the reader judges. So quotes, backslashes and line breaks are taken out first, which can only
# join letters, never part them. A $ or a backtick anywhere is a yes: an expansion can spell anything.
# The reader does no brace or glob expansion and reads no gh or git alias from a config file, so
# nothing else turns other letters into a word.
#
# A yes means "read it properly", never "it runs one": the gate goes on exactly as before. Only a no
# changes anything, and only by leaving with the answer the reader would have given.
#
# The removal is done by tr, never by bash's own ${text//x/}: on bash 3.2 (macOS /bin/bash) that is
# quadratic, measured at 4 seconds of processor time for 16 KB of text on 2026-11-26, and a commit
# message can be hundreds of KB. tr is one program start and linear.
#
#   cs_may_name <command> <case pattern> [<case pattern> ...]
#     returns 0 when the command may name a word matching any pattern (match case insensitively by
#     writing each letter as a bracket, *[pP][rR]*), 1 when it cannot
#
#   cs_cut <parsed payload>
#     sets CS_COMMAND to the command, everything before the first unit separator of what
#     ps_parse_payload printed, the same text ${parsed%%$'\x1f'*} gives; returns 1 when the cut
#     could not be made, and the caller then reads the command properly
#
# The cut is made by read, as ps__read splits its records (lib/push-scope.sh), never by ${x%%y*},
# for the same reason: on bash 3.2 that pattern removal is quadratic too, measured at 15 s of
# processor time for a 306 KB command in require-issue-fields.sh, past that hook's 15 s limit, and at
# 0.05 s by read on 431 KB (review of #3690).

cs_cut() {
  local rest=""
  CS_COMMAND=""
  case "$1" in
    *$'\x1f'*) ;;
    # Nothing to cut at: the whole text is the command, as the pattern removal gave it.
    *) CS_COMMAND="$1"; return 0 ;;
  esac
  # The here string ends in a line break of its own, which the last field takes, and IFS holds no
  # space, tab or line break, so the first field is every byte before the separator, kept as it is.
  IFS=$'\x1f' read -r -d '' CS_COMMAND rest <<< "$1"
  # read returns 1 at the end of its input, which is every time here, so it is judged by what it
  # left: the two fields put back must be the text it was given. A read that could not run (no file
  # for the here string) leaves both empty, and an empty command is one the screen would answer no to.
  [ "$CS_COMMAND"$'\x1f'"$rest" = "$1"$'\n' ] && return 0
  CS_COMMAND=""
  return 1
}

cs_may_name() {
  local text pat
  case "$1" in *'$'*|*'`'*) return 0 ;; esac
  case "$1" in
    *[\'\"\\]*|*$'\n'*|*$'\r'*)
      # A tr that cannot run leaves nothing to judge by, so the answer is yes.
      text="$(printf '%s' "$1" | LC_ALL=C tr -d "'\"\\\\\n\r" 2>/dev/null)" || return 0 ;;
    *) text="$1" ;;
  esac
  shift
  for pat in "$@"; do
    # The pattern unquoted, so its brackets and stars match.
    case "$text" in $pat) return 0 ;; esac
  done
  return 1
}
