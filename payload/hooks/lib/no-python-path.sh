#!/usr/bin/env bash
#
# no-python-path.sh: build the PATH a suite drives a hook under when it is measuring what that hook
# does on a machine with no python3 (claude-config#486).
#
# Sourced by test suites only. No hook uses it.
#
# The premise every one of those cases rests on is that the directory really does reach no python3.
# Unsetting a variable or renaming the binary proves nothing: a hook looks the interpreter up on
# PATH, so the PATH is what has to be emptied of it. The shape is the one test-check-add-scope.sh
# established for claude-config#480: a bare directory holding symlinks to the tools the hook does
# need, and nothing else, with the hook run under `PATH=<dir> <dir>/bash <hook>`.
#
# It lives here rather than in each suite because ten suites need the same directory, and ten
# copies of a tool list drift into ten different answers to "did this machine have python3"
# (L613). Each suite still ASSERTS the premise for itself with npp_reaches_python3 below: a shared
# builder that silently linked one in would otherwise make every case pass for the wrong reason
# (L70, L159).
#
#   . "$DIR/lib/no-python-path.sh"
#   NOPY="$ROOT/bin"
#   npp_build_bin "$NOPY"            # or with extra tools: npp_build_bin "$NOPY" jq gh
#   if npp_reaches_python3 "$NOPY"; then ...the premise failed... else ...ok... fi

# The tools a hook in this repo needs before it can get as far as its detector: a shell, the
# coreutils it shells out to, and git. Deliberately NOT python3, jq or gh, which are what the
# cases below and beside it are about; a caller that wants one passes it as an argument.
NPP_BASE_TOOLS="bash sh git grep egrep sed awk tr cat cut head tail sort uniq wc dirname basename env uname mkdir mv rm rmdir ln touch date find xargs mktemp stat shasum cksum md5 sleep expr id whoami hostname ls chmod cmp diff du tee nohup timeout"

# Build a bare bin directory holding ONLY the named tools.
npp_build_bin() {   # $1 = directory to build  $2.. = extra tools beyond the base set
  local dir="$1"; shift
  mkdir -p "$dir" || return 1
  local tool toolpath
  for tool in $NPP_BASE_TOOLS "$@"; do
    toolpath="$(command -v "$tool" 2>/dev/null)" || continue
    # Only a real file on disk. `command -v` answers with the bare word for a shell builtin or a
    # function, and a symlink made from that name points at itself inside the new directory, which
    # is a loop rather than a tool (L8).
    case "$toolpath" in
      /*) ln -s "$toolpath" "$dir/$tool" 2>/dev/null || true ;;
    esac
  done
  return 0
}

# True when a shell started with ONLY that directory on PATH can still find python3, which is the
# premise failing. Asked through that directory's own bash, because the question is about what the
# hook will see and the hook is run the same way.
npp_reaches_python3() {   # $1 = the directory
  PATH="$1" "$1/bash" -c 'command -v python3 >/dev/null 2>&1'
}
