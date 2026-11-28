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
# Never ${x%%y*} (review of #3690, measured 2026-11-27): on bash 3.2 that longest match removal is
# quadratic too, 15 s of
# processor time for a 306 KB command in require-issue-fields.sh, past that hook's 15 s limit. Nor
# read with -d, which bash 3.2 reads one byte per system call: 0.4 s on 431 KB, more than the gate
# it saves. The shortest match from the end, ${x%y*}, stops at the last separator after a few bytes
# of folder, and the command holds no separator of its own (ps_parse_payload writes each as U+FFFD),
# so what it leaves is the command unless the folder holds the byte too. Only then, which no real
# folder does, is the cut made by read.

cs_cut() {
  local rest=""
  CS_COMMAND="${1%$'\x1f'*}"
  case "$CS_COMMAND" in
    *$'\x1f'*) ;;
    *) return 0 ;;
  esac
  # The here string ends in a line break of its own, which the last field takes, and IFS holds no
  # space, tab or line break, so the first field is every byte before the separator, kept as it is.
  IFS=$'\x1f' read -r -d '' CS_COMMAND rest <<< "$1"
  # read returns 1 at the end of its input, which is every time here, so it is judged by what it
  # left: the two fields put back must be the text it was given. A read that could not run (no file
  # for the here string) leaves the command empty, which the screen would answer no to.
  [ "$CS_COMMAND"$'\x1f'"$rest" = "$1"$'\n' ] && return 0
  CS_COMMAND=""
  return 1
}

cs_may_name() {
  local text pat
  # A word already whole in the text is a yes before anything is taken out, since taking characters
  # out only joins letters: a command that names what the gate reads, which every command it judges
  # does, pays for no scan for a $ and no tr (review of #3690).
  for pat in "${@:2}"; do
    case "$1" in $pat) return 0 ;; esac
  done
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
