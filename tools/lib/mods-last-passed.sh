# mods-last-passed.sh: which Claude Code build every mod last passed its checks on, on this Mac
# (claude-config#3297). Sourced by tools/check-mods.sh, which writes the record when a whole mods
# folder passes on a real claude, and by tests/test-mods.sh, which says at its start when the build
# installed now is another one.
#
# Why it exists: on 2026-11-18 Claude Code 2.1.328 arrived on the personal MacBook and two of the
# secret guard's tests failed from then on with no commit to blame. Three builders each spent time
# showing the failure was not theirs, because nothing said Claude Code had changed since the suite
# last passed. With this record the first line of the run says so.
#
# The record is one line, the build, a tab, and the date it passed, in this Mac's ~/.claude/state,
# which the sync never carries: each Mac's record is about the build that Mac runs. Written only by a
# test run, never by hand. CHECK_MODS_LAST_PASSED names another file (the suites point it at a
# scratch one), and set empty it turns the record off, both the note and the write.
MODS_LAST_PASSED_FILE="${CHECK_MODS_LAST_PASSED-$HOME/.claude/state/mods-last-passed.tsv}"

# mods_last_passed_note <build installed now>: prints one line when the mods last passed on another
# build, else nothing. Nothing either when there is no record yet or the build cannot be read, since
# neither is a change anybody can act on.
mods_last_passed_note(){
  local now="${1:-}" was="" when=""
  [ -n "$MODS_LAST_PASSED_FILE" ] && [ -n "$now" ] && [ -f "$MODS_LAST_PASSED_FILE" ] || return 0
  IFS=$'\t' read -r was when < "$MODS_LAST_PASSED_FILE" 2>/dev/null || true
  [ -n "$was" ] && [ "$was" != "$now" ] || return 0
  printf 'Claude Code changed since the mods last passed on this Mac: they passed on Claude Code %s%s, and %s is installed now. Read a failure below as that change first, before looking for a commit to blame.\n' \
    "$was" "${when:+ on $when}" "$now"
}

# mods_last_passed_write <build>: records that every mod passed on <build> today. Written to a file
# beside the record and moved over it, so a run killed halfway leaves the old record, never half a
# line. Says why when it cannot, and returns 1.
mods_last_passed_write(){
  local build="${1:-}" tmp
  [ -n "$MODS_LAST_PASSED_FILE" ] && [ -n "$build" ] || return 0
  mkdir -p "$(dirname "$MODS_LAST_PASSED_FILE")" 2>/dev/null \
    && tmp="$(mktemp "$MODS_LAST_PASSED_FILE.XXXXXX" 2>/dev/null)" \
    && printf '%s\t%s\n' "$build" "$(date +%Y-%m-%d)" > "$tmp" \
    && mv -f "$tmp" "$MODS_LAST_PASSED_FILE" && return 0
  [ -n "${tmp:-}" ] && rm -f "$tmp"
  echo "could not record in $MODS_LAST_PASSED_FILE that the mods passed on Claude Code $build" >&2
  return 1
}
