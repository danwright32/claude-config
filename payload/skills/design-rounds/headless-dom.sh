#!/bin/bash
# headless-dom.sh <Chrome arguments...>: runs headless Chrome as given (its --dump-dom included) and
# prints the page it dumped, then ends Chrome, with a deadline that fails by name (#801, L110).
#
# Measured on Daniels-MacBook-Pro-2, 2026-10-05, Chrome 154: a --dump-dom run prints the whole page
# at once and then sits in its own teardown. Run plain, it printed the page and was ended by its own
# "Teardown watchdog expired" after 10 s (exit 2); given its own profile, it printed the page and was
# still running 40 s later. test-make-switcher.sh runs Chrome 18 times, so it paid 10 s or more on
# each and, run beside other suites, waited out its whole 1,200 s wall clock with nothing printed
# after the PICKER line. So the page is read as soon as it is complete (its closing </html>), and
# Chrome and every helper it started are ended then, never waited for.
#
# Each run gets a fresh profile folder of its own, so two suites running Chrome at once never meet
# on one profile's lock.
#
# THE COPY CHROME MAKES OF ITSELF (#988). On every launch Chrome copies its app bundle into a per
# user folder, <the parent of getconf DARWIN_USER_TEMP_DIR>/X/com.google.Chrome.code_sign_clone,
# and removes the copy only on a normal quit, so every run ended here left one behind (114 on
# 2026-10-08). Measured on Daniels-MacBook-Pro-2, 2026-10-08, Chrome 154.0.8037.98, own profile:
#   - no quit is clean in headless. Browser.close over --remote-debugging-pipe was answered, then
#     Chrome sat until its 10 s teardown watchdog (exit 2), left its copy and orphaned its network
#     helper; SIGTERM ended it in 0.2 s (exit 0) but left the copy and orphaned a renderer.
#   - --disable-features=MacAppCodeSignClone stops the copy being made at all, and the page is
#     dumped as before. So that is passed, merged into any --disable-features the caller gives,
#     because a second --disable-features replaces the first (measured: given ours and then
#     --disable-features=Translate, Chrome made its copy; given the two in one switch, it did not).
# Should a copy appear anyway (a later Chrome renaming the feature), the copy THIS run's Chrome
# holds open is removed after it is killed: new since the run began, held by this Chrome's pid
# while it is stopped, and held by no process once it is gone. Anything else in that folder,
# another Chrome's copy or one still in use, is never touched (L5). A Chrome that ends by itself
# is not inspected, since a dead process holds nothing to tell its copy by.
#
#   HEADLESS_DOM_CHROME    the Chrome binary to run (required)
#   HEADLESS_DOM_DEADLINE  seconds to wait for a complete page, default 60; past it this prints why
#                          on stderr and exits 124, with nothing on stdout
#   HEADLESS_DOM_CLONE_DIR the folder Chrome copies itself into, default as above (tests point it
#                          at a folder of their own)
#   HEADLESS_DOM_LSOF      the lsof to tell this run's copy by, default lsof
#
# Exit 0 with the page; 124 when no complete page came within the deadline; Chrome's own exit code
# when it ended without one, or 1 when that code was 0. Nothing is printed on stdout unless the page
# is complete.
set -u
REAL="${HEADLESS_DOM_CHROME:?headless-dom.sh: set HEADLESS_DOM_CHROME to the Chrome binary}"
LIMIT="${HEADLESS_DOM_DEADLINE:-60}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KILL_TREE="$HERE/../../hooks/lib/kill-tree.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/headless-dom.XXXXXX")" || { echo "headless-dom.sh: could not make a scratch folder" >&2; exit 1; }
trap 'rm -rf "$work"' EXIT

# The folder Chrome copies itself into, by its real path: lsof reports /private/var where TMPDIR
# says /var. Empty where there is none (no getconf DARWIN_USER_TEMP_DIR off a Mac).
clone_dir=""
if [ -n "${HEADLESS_DOM_CLONE_DIR:-}" ]; then
  clone_dir="$(cd "$HEADLESS_DOM_CLONE_DIR" 2>/dev/null && pwd -P)"
else
  user_tmp="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)"
  [ -n "$user_tmp" ] && clone_dir="$(cd "${user_tmp%/}/.." 2>/dev/null && pwd -P)/X/com.google.Chrome.code_sign_clone"
fi
LSOF="${HEADLESS_DOM_LSOF:-lsof}"
list_clones(){ ls -1 "$clone_dir" 2>/dev/null | grep '^code_sign_clone\.' | LC_ALL=C sort; }
[ -n "$clone_dir" ] && list_clones > "$work/clones.before"

# Told not to copy itself, inside the caller's own --disable-features when there is one.
args=()
merged=no
for a in "$@"; do
  case "$a" in
    --disable-features=*) args+=("$a,MacAppCodeSignClone"); merged=yes ;;
    *) args+=("$a") ;;
  esac
done
[ "$merged" = yes ] || args=(--disable-features=MacAppCodeSignClone ${args[@]+"${args[@]}"})

"$REAL" --user-data-dir="$work/profile" --no-first-run --no-default-browser-check "${args[@]}" > "$work/out" 2> "$work/err" &
pid=$!
start=$SECONDS
state=running
while :; do
  if grep -q '</html>' "$work/out" 2>/dev/null; then state=complete; break; fi
  if ! kill -0 "$pid" 2>/dev/null; then state=ended; break; fi
  if [ $((SECONDS - start)) -ge "$LIMIT" ]; then state=late; break; fi
  sleep 0.1
done

rc=0
if [ "$state" = ended ]; then
  wait "$pid"; rc=$?
  # It may have finished the page in the same instant it exited.
  grep -q '</html>' "$work/out" 2>/dev/null && rc=0
else
  # Stopped first, so it cannot start another helper while its tree is walked (kill-tree.sh).
  kill -STOP "$pid" 2>/dev/null
  # Its own copy is told by the pid holding it, read while it is stopped and still holds it.
  own=()
  if [ -n "$clone_dir" ]; then
    list_clones > "$work/clones.after"
    fresh="$(LC_ALL=C comm -13 "$work/clones.before" "$work/clones.after")"
    if [ -n "$fresh" ] && ! command -v "$LSOF" >/dev/null 2>&1; then
      echo "headless-dom.sh: copies of Chrome new since this run began in $clone_dir: $(printf '%s\n' "$fresh" | wc -l | tr -d ' '). $LSOF is not here to tell which is this run's, so none was removed." >&2
    elif [ -n "$fresh" ]; then
      for n in $fresh; do
        "$LSOF" -n -P -t +D "$clone_dir/$n" 2>/dev/null | grep -qx "$pid" && own+=("$n")
      done
    fi
  fi
  if [ -f "$KILL_TREE" ]; then bash "$KILL_TREE" "$pid"; else pkill -KILL -P "$pid" 2>/dev/null; fi
  kill -KILL "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  for n in ${own[@]+"${own[@]}"}; do
    case "$n" in code_sign_clone.?*) ;; *) continue ;; esac
    case "$n" in */*) continue ;; esac
    copy="$clone_dir/$n"
    [ -d "$copy" ] && [ ! -L "$copy" ] || continue
    users="$("$LSOF" -n -P -t +D "$copy" 2>/dev/null | sort -u | tr '\n' ' ')"
    if [ -n "$users" ]; then
      echo "headless-dom.sh: left Chrome's copy $copy, still in use by pid ${users% }." >&2
      continue
    fi
    rm -rf "$copy"
  done
fi

if [ "$state" = late ]; then
  echo "headless-dom.sh: Chrome gave no complete page within ${LIMIT}s (HEADLESS_DOM_DEADLINE) and was ended. Its last words: $(tail -n 3 "$work/err" | tr '\n' ' ')" >&2
  exit 124
fi
# Ended on its own without a whole page: a failure whatever its exit status, because handing back
# half a page with a clean status reads as success to every caller (claude-config#677).
if [ "$state" = ended ] && ! grep -q '</html>' "$work/out" 2>/dev/null; then
  echo "headless-dom.sh: Chrome ended without a complete page (exit $rc). Its last words: $(tail -n 3 "$work/err" | tr '\n' ' ')" >&2
  [ "$rc" -ne 0 ] && exit "$rc"
  exit 1
fi
cat "$work/out"
exit "$rc"
