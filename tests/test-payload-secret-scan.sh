#!/usr/bin/env bash
# Everything this repository publishes passes claude-sync's own secret scan.
#
# A send runs scan_secrets over everything it is about to publish and refuses outright on a hit,
# so one token SHAPED placeholder blocks every sync from every Mac until somebody notices. That
# happened when claude-config#675 shipped a token placeholder in skills/tracker/config.example.json
# written as one unbroken run of letters and underscores: a key named token, then 24 or more
# identifier characters, which is exactly what the scan's assignment pattern looks for. Nothing ran
# the scan before merge; it first ran on the next send.
#
# A send publishes the payload, and a push publishes the WHOLE tree: tests/, tools/, claude-sync,
# the README. Until claude-config#1128 nothing scanned anything outside payload/ before it reached
# GitHub, so this reads every file git would carry anywhere in the repository (tracked, plus
# untracked files that are not ignored, so the file just written is judged too, L456). It is a
# whole tree scanner, so scanners-before-push.sh runs it before every push and CI runs it on every
# pull request.
#
# It runs the REAL function, cut out of claude-sync by name, never a copy of its patterns, which
# would drift from the scan it stands for (L41, L370). It reads the repository's real
# .secret-allowlist, as the send does.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
SCRIPT="$ROOT/claude-sync"

pass=0; fail=0
check(){ if [ "$2" = ok ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 ($2)"; fi; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-secretscan-test.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}"|"${TMPDIR:-/tmp}"|"${TMPDIR:-/tmp}"/)
    echo "test-payload-secret-scan: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

# The function and the helper it calls, cut from claude-sync by name. die is replaced so a refusal
# is reported here instead of ending this suite (and without the notification the real one posts).
SCAN_SRC="$(sed -n '/^scan_secrets(){/,/^}/p' "$SCRIPT")"
BLANK_SRC="$(sed -n '/^is_blank(){/p' "$SCRIPT")"
case "$SCAN_SRC" in
  *'apat='*'grep -rIoE'*'die '*) check "scan_secrets was cut from claude-sync whole" ok ;;
  *) check "scan_secrets was cut from claude-sync whole" "the extraction found no scan_secrets body, so nothing below would mean anything" ;;
esac
[ -n "$BLANK_SRC" ] && check "is_blank was cut from claude-sync" ok \
  || check "is_blank was cut from claude-sync" "not found"

# run_scan <payload dir> <repo dir holding .secret-allowlist>; prints what the scan said, and
# "SCAN-RC=<n>" last. Run in a subshell with the override switched off explicitly: a
# SYNC_SKIP_SECRET_SCAN inherited from whoever started this suite would pass everything (L439).
run_scan(){
  # Locals, which scan_secrets sees through bash's dynamic scope and which go when this returns.
  local PAYLOAD="$1" SYNC_REPO="$2"
  (
    unset SYNC_SKIP_SECRET_SCAN
    die(){ printf 'REFUSED: %s\n' "$*"; exit 1; }
    eval "$BLANK_SRC"
    eval "$SCAN_SRC"
    scan_secrets
  ) 2>&1
  printf 'SCAN-RC=%s\n' "$?"
}

# --- everything a push or a send publishes (claude-config#1128) -------------------
# copy_tree <git root> <dest>: copies exactly the files git would carry from anywhere in <root>
# into <dest>, so an ignored local file (a skill's config.local.json, which the sync also leaves
# out) neither fails nor passes this. Prints how many it copied. When it could not list or copy
# them it prints WHY instead and returns 1, so a run that read nothing cannot pass as clean (L98)
# and cannot read as a scan that failed either (claude-config#1146, L411).
#
# The list is a moment's picture of a tree other processes are writing in, so a file can be listed
# and gone before the archive reaches it, and tar then fails on that one file having copied the
# rest (measured 2026-10-13, below). A fresh listing no longer names it, so a failed copy is listed
# and made again, three attempts in all, with no wait between them: what changes between attempts
# is the listing, not the clock.
TREE_LISTER="$ROOT/payload/hooks/lib/repo-files.sh"   # a variable, set here, so a control can stand in for it
copy_tree(){
  local root="$1" dest="$2" list err attempt=1 why=""
  list="$(mktemp "$TMPROOT/tree-list.XXXXXX")" || { echo "no scratch file to hold the list of files in"; return 1; }
  err="$list.err"
  while [ "$attempt" -le 3 ]; do
    if ! bash "$TREE_LISTER" "$root" > "$list" 2> "$err"; then
      echo "the files under $root could not be listed: $(head -3 "$err" | tr '\n' ' ')"; return 1
    fi
    grep -q . "$list" || { echo "the listing of $root came back empty"; return 1; }
    rm -rf "$dest" && mkdir -p "$dest" || { echo "could not make $dest to copy into"; return 1; }
    # One archive in and one out, rather than a copy per file: the tree is several hundred files.
    if tar -C "$root" -cf - -T "$list" 2> "$err" | tar -C "$dest" -xf - 2>> "$err"; then
      grep -c . "$list"; return 0
    fi
    why="$(head -3 "$err" | tr '\n' ' ')"
    attempt=$(( attempt + 1 ))
  done
  echo "the files under $root could not be copied in 3 attempts, listing afresh each time: ${why:-tar gave no reason}"
  return 1
}
# unmeasured <what> <why>: says a part of the scan could not be made, in the one line
# scanners-before-push.sh reads as a fault in its own run rather than a scan that failed, and marks
# this run as one that measured less than it should have (claude-config#1146, L411).
unmeasured_n=0
unmeasured(){
  printf 'SCAN-UNMEASURED %s, so it was not scanned: %s\n' "$1" "$2"
  unmeasured_n=$(( unmeasured_n + 1 ))
}
# judge_tree <git root> <dest>: copies what <root> publishes into <dest> and judges it. Returns 3,
# having judged nothing, when the files could not be copied.
judge_tree(){
  local root="$1" TREE="$2" n outside out
  if ! n="$(copy_tree "$root" "$TREE")"; then
    unmeasured "everything $root publishes" "$n"
    return 3
  fi
  outside="$(cd "$TREE" 2>/dev/null && find . -type f ! -path './payload/*' | grep -c . || true)"
  [ "${n:-0}" -ge 300 ] && check "the scan reads every file the repository publishes ($n files)" ok \
    || check "the scan reads every file the repository publishes (${n:-0} files)" "too few to be this repository"
  [ "${outside:-0}" -ge 20 ] && [ -f "$TREE/claude-sync" ] && [ -f "$TREE/README.md" ] \
    && check "and they include the files outside payload/, claude-sync and the README among them ($outside)" ok \
    || check "and they include the files outside payload/, claude-sync and the README among them (${outside:-0})" "the scan would see the payload only, which is the gap #1128 closed"
  [ -f "$TREE/payload/skills/tracker/config.example.json" ] && check "and the tracker's example config is among them" ok \
    || check "and the tracker's example config is among them" "missing, so the case that blocked sync is not being judged"

  # The copy is its own repository root as well, holding the repository's .secret-allowlist among
  # the files it copied: an allowlist entry names the file it accepts by its path in the repository
  # (#1133), so the copy must sit where the repository does for that path to read the same.
  [ -f "$TREE/.secret-allowlist" ] && check "and the repository's .secret-allowlist is among them" ok \
    || check "and the repository's .secret-allowlist is among them" "missing, so the scan below would judge against no allowlist"
  out="$(run_scan "$TREE" "$TREE")"
  case "$out" in
    *'SCAN-RC=0') check "everything the repository publishes passes claude-sync's secret scan" ok ;;
    *) check "everything the repository publishes passes claude-sync's secret scan" "a push would publish, or a send would refuse: $(printf '%s' "$out" | tr '\n' ' ')" ;;
  esac
}
judge_tree "$ROOT" "$TMPROOT/tree"

# --- the controls (L1) -----------------------------------------------------------
# The whole tree run finds a credential planted OUTSIDE payload/, where nothing looked before #1128.
# A throwaway repository, so the file is listed by the same helper as the real tree's files are.
PT="$TMPROOT/planted-tree"
mkdir -p "$PT/payload" "$PT/tools"
git -C "$PT" init -q 2>/dev/null
printf 'nothing secret\n' > "$PT/payload/clean.txt"
printf '{ "token": "%s" }\n' "$(printf 'whole tree planted control' | shasum -a 256 | cut -c1-40)" > "$PT/tools/leak.json"
if pn="$(copy_tree "$PT" "$TMPROOT/planted-tree-copy")"; then
  out="$(run_scan "$TMPROOT/planted-tree-copy" "$TMPROOT/planted-tree")"
  case "$pn:$out" in
    2:*'possible secret found in: tools/leak.json'*'SCAN-RC=1') check "#1128 control: the whole tree scan refuses a token planted outside payload/ and names its file" ok ;;
    *) check "#1128 control: the whole tree scan refuses a token planted outside payload/ and names its file" "copied $pn, got: $(printf '%s' "$out" | tr '\n' ' ')" ;;
  esac
else
  unmeasured "the #1128 control's planted tree" "$pn"
fi

# --- a tree it could not read is UNMEASURED, never a scan failure (claude-config#1146) ------
# On 2026-10-13 the pre push gate ran this suite and it failed "the scan reads every file the
# repository publishes (0 files)" with every other check green, and run directly a minute later it
# passed 51 of 51. Reproduced since: a file listed and then gone before the archive reaches it
# (another process removing a file it had just written) makes tar fail on that one file, so the copy
# reports failure with every other file copied, and the count reads as zero. What tar said went
# to output the gate threw away, so which file it was is not known. Driven here with a lister
# standing in for repo-files.sh, so the race is SET rather than waited for (L290).
VT="$TMPROOT/vanish-tree"; mkdir -p "$VT/payload"; git -C "$VT" init -q 2>/dev/null
printf 'one\n' > "$VT/payload/a.txt"; printf 'two\n' > "$VT/payload/b.txt"
# vanish_lister <n>: writes a lister that gives the real list, plus a file that no longer exists in
# its first <n> listings, and prints its path. It counts its own calls in a file beside it.
vanish_lister(){
  local f="$TMPROOT/vanish-lister.$1"
  rm -f "$f.calls"
  cat > "$f" <<EOF
#!/usr/bin/env bash
n=\$(( \$(cat "$f.calls" 2>/dev/null || echo 0) + 1 )); printf '%s' "\$n" > "$f.calls"
bash "$ROOT/payload/hooks/lib/repo-files.sh" "\$1" || exit \$?
[ "\$n" -le $1 ] && printf 'payload/written-then-removed.txt\n'
exit 0
EOF
  printf '%s' "$f"
}
vl="$(vanish_lister 1)"
vn="$(TREE_LISTER="$vl" copy_tree "$VT" "$TMPROOT/vanish-copy")"; vrc=$?
[ "$vrc" -eq 0 ] && [ "$vn" = 2 ] && [ -f "$TMPROOT/vanish-copy/payload/a.txt" ] && [ -f "$TMPROOT/vanish-copy/payload/b.txt" ] \
  && check "#1146 a file gone before it was copied is listed again and the copy made whole" ok \
  || check "#1146 a file gone before it was copied is listed again and the copy made whole" "exit $vrc, said: $vn"
[ "$(cat "$vl.calls" 2>/dev/null)" = 2 ] && check "#1146 and it listed exactly twice, once more than the race needed" ok \
  || check "#1146 and it listed exactly twice, once more than the race needed" "listed $(cat "$vl.calls" 2>/dev/null || printf 'never')"
vn="$(TREE_LISTER="$(vanish_lister 99)" copy_tree "$VT" "$TMPROOT/vanish-copy-2")"; vrc=$?
case "$vrc:$vn" in
  0:*) check "#1146 a file that keeps vanishing fails the copy, naming the file tar could not read" "it succeeded: $vn" ;;
  *written-then-removed.txt*) check "#1146 a file that keeps vanishing fails the copy, naming the file tar could not read" ok ;;
  *) check "#1146 a file that keeps vanishing fails the copy, naming the file tar could not read" "exit $vrc, said: $vn" ;;
esac
# And a tree that cannot be read is said to be UNMEASURED, in the line scanners-before-push.sh
# reads as a fault in its own run, never as a scan that failed (L411).
FL="$TMPROOT/failing-lister"
printf '#!/usr/bin/env bash\necho "repo-files: git could not list the files under $1." >&2\nexit 1\n' > "$FL"
jt="$( pass=0; fail=0; TREE_LISTER="$FL"; judge_tree "$VT" "$TMPROOT/unlisted-copy"; printf 'JT-RC=%s failed=%s\n' "$?" "$fail" )"
case "$jt" in
  *FAIL:*) check "#1146 a tree that cannot be listed is UNMEASURED with the reason, not a failing scan" "got: $(printf '%s' "$jt" | tr '\n' ' ')" ;;
  *'SCAN-UNMEASURED '*'git could not list the files under'*'JT-RC=3 failed=0'*) check "#1146 a tree that cannot be listed is UNMEASURED with the reason, not a failing scan" ok ;;
  *) check "#1146 a tree that cannot be listed is UNMEASURED with the reason, not a failing scan" "got: $(printf '%s' "$jt" | tr '\n' ' ')" ;;
esac

# A key written in capitals is still a key (#1128): API_TOKEN, CLIENT_SECRET, DB_PASSWORD, X_API_KEY
# and a mixed case Api_Key each carry a value the scan must refuse. Each in its own file, so one
# match cannot answer for the others.
mkdir -p "$TMPROOT/upper/payload" "$TMPROOT/upper/repo"
uv="$(printf 'uppercase key control' | shasum -a 256 | cut -c1-40)"
for k in API_TOKEN CLIENT_SECRET DB_PASSWORD X_API_KEY Api_Key; do
  printf 'export %s=%s\n' "$k" "$uv" > "$TMPROOT/upper/payload/$k.sh"
done
out="$(run_scan "$TMPROOT/upper/payload" "$TMPROOT/upper/repo")"
for k in API_TOKEN CLIENT_SECRET DB_PASSWORD X_API_KEY Api_Key; do
  case "$out" in
    *'possible secret found in: '*"$k.sh"*'SCAN-RC=1') check "#1128 the scan refuses a key written as $k" ok ;;
    *) check "#1128 the scan refuses a key written as $k" "got: $(printf '%s' "$out" | tr '\n' ' ')" ;;
  esac
done
# A key whose name runs on past the credential word is still a key (#1133): SECRET_KEY, a YAML
# client_secret_key, PRIVATE_KEY and AWS_SECRET_ACCESS_KEY. PASSWD in capitals is one too, in a
# shell variable and as a YAML key. Each in its own file, so one match cannot answer for the others.
mkdir -p "$TMPROOT/compound/payload" "$TMPROOT/compound/repo"
cv="$(printf 'compound key control' | shasum -a 256 | cut -c1-40)"
for k in SECRET_KEY PRIVATE_KEY AWS_SECRET_ACCESS_KEY DB_PASSWD; do
  printf 'export %s=%s\n' "$k" "$cv" > "$TMPROOT/compound/payload/$k.sh"
done
for k in client_secret_key PASSWD; do
  printf '%s: %s\n' "$k" "$cv" > "$TMPROOT/compound/payload/$k.yml"
done
out="$(run_scan "$TMPROOT/compound/payload" "$TMPROOT/compound/repo")"
for f in SECRET_KEY.sh PRIVATE_KEY.sh AWS_SECRET_ACCESS_KEY.sh DB_PASSWD.sh client_secret_key.yml PASSWD.yml; do
  case "$out" in
    *'possible secret found in: '*"$f"*'SCAN-RC=1') check "#1133 the scan refuses a key written as ${f%.*}" ok ;;
    *) check "#1133 the scan refuses a key written as ${f%.*}" "got: $(printf '%s' "$out" | tr '\n' ' ')" ;;
  esac
done
# The one line a capital PASSWD must leave alone, with no exception written for it: the sudoers
# grant the bug-bash suite expects, NOPASSWD followed by a path that reads as a long value. NOPASSWD
# is a sudoers tag rather than a credential key, so the rule skips PASSWD right after NO. The whole
# tree run above reads the real line; this is the same shape on its own, so a pass there cannot
# come from that file being skipped.
mkdir -p "$TMPROOT/sudoers/payload" "$TMPROOT/sudoers/repo"
printf 'someone ALL = (root) NOPASSWD: /usr/local/libexec/bug-bash-egress load *\n' > "$TMPROOT/sudoers/payload/grant"
out="$(run_scan "$TMPROOT/sudoers/payload" "$TMPROOT/sudoers/repo")"
case "$out" in
  *'SCAN-RC=0') check "#1133 a sudoers NOPASSWD grant is not read as a password" ok ;;
  *) check "#1133 a sudoers NOPASSWD grant is not read as a password" "got: $(printf '%s' "$out" | tr '\n' ' ')" ;;
esac

# --- an exception admits one value in one file, never a shape (#1133, L1022) ------
# An allowlist entry was the fingerprint of the matched text alone. For a private key that text is
# the header line, the same for every key of its kind, so the entries written for one example in a
# document accepted every real RSA, EC and PGP private key anywhere. Real keys, made here and thrown
# away with this run, are planted and scanned against the repository's OWN allowlist.
mkdir -p "$TMPROOT/realkey/payload"
for kt in rsa ecdsa; do
  ssh-keygen -q -t "$kt" -m PEM -N '' -C '' -f "$TMPROOT/realkey/payload/$kt.pem" >/dev/null 2>&1
  rm -f "$TMPROOT/realkey/payload/$kt.pem.pub"
done
if [ -s "$TMPROOT/realkey/payload/rsa.pem" ] && [ -s "$TMPROOT/realkey/payload/ecdsa.pem" ]; then
  cp "$ROOT/.secret-allowlist" "$TMPROOT/realkey/.secret-allowlist"
  out="$(run_scan "$TMPROOT/realkey/payload" "$TMPROOT/realkey")"
  for kt in rsa ecdsa; do
    case "$out" in
      *'possible secret found in: '*"$kt.pem"*'SCAN-RC=1') check "#1133 a real $kt private key is refused against the repository's own allowlist" ok ;;
      *) check "#1133 a real $kt private key is refused against the repository's own allowlist" "got: $(printf '%s' "$out" | tr '\n' ' ')" ;;
    esac
  done
else
  check "#1133 a real private key is refused against the repository's own allowlist" "ssh-keygen made no key, so nothing was planted"
fi

# fp <where it lives, relative to the repository> <the matched text>: an allowlist fingerprint.
fp(){ printf '%s:%s' "$1" "$2" | shasum -a 256 | cut -d' ' -f1; }
# A value accepted in one file is refused in another: the entry names where it lives.
mkdir -p "$TMPROOT/where/payload"
wv="$(printf 'where it lives control' | shasum -a 256 | cut -c1-40)"
printf 'token=%s\n' "$wv" > "$TMPROOT/where/payload/accepted.txt"
printf 'token=%s\n' "$wv" > "$TMPROOT/where/payload/elsewhere.txt"
printf '%s  # one value in one file\n' "$(fp payload/accepted.txt "token=$wv")" > "$TMPROOT/where/.secret-allowlist"
out="$(run_scan "$TMPROOT/where/payload" "$TMPROOT/where")"
case "$out" in
  *'accepted.txt'*) check "#1133 an allowlisted value is accepted in the file it was allowlisted for" "got: $(printf '%s' "$out" | tr '\n' ' ')" ;;
  *'possible secret found in: '*'elsewhere.txt'*'SCAN-RC=1') check "#1133 an allowlisted value is accepted in the file it was allowlisted for" ok ;;
  *) check "#1133 an allowlisted value is accepted in the file it was allowlisted for" "got: $(printf '%s' "$out" | tr '\n' ' ')" ;;
esac
case "$out" in
  *'possible secret found in: '*'elsewhere.txt'*'SCAN-RC=1') check "#1133 and the same value in another file is still refused" ok ;;
  *) check "#1133 and the same value in another file is still refused" "got: $(printf '%s' "$out" | tr '\n' ' ')" ;;
esac
# A private key header is never accepted at all: it is not the key, so no entry can name the value.
# Both spellings of an entry for it are written, the old one (the text alone) and one naming its file.
mkdir -p "$TMPROOT/header/payload"
if [ -s "$TMPROOT/realkey/payload/rsa.pem" ]; then
  cp "$TMPROOT/realkey/payload/rsa.pem" "$TMPROOT/header/payload/doc.pem"
  hdr="$(grep -m 1 -oE 'BEGIN [A-Z ]*PRIVATE KEY' "$TMPROOT/header/payload/doc.pem")"
  { printf '%s  # the text alone\n' "$(printf '%s' "$hdr" | shasum -a 256 | cut -d' ' -f1)"
    printf '%s  # the text in its file\n' "$(fp payload/doc.pem "$hdr")"; } > "$TMPROOT/header/.secret-allowlist"
  out="$(run_scan "$TMPROOT/header/payload" "$TMPROOT/header")"
  case "$out" in
    *'possible secret found in: doc.pem'*'SCAN-RC=1') check "#1133 a private key header is refused whatever the allowlist holds for it" ok ;;
    *) check "#1133 a private key header is refused whatever the allowlist holds for it" "got: $(printf '%s' "$out" | tr '\n' ' ')" ;;
  esac
fi

# --- what a send commits outside the payload (#1133) ------------------------------
# A send publishes the payload and every commit the clone holds that the shared repo does not, and
# the sync makes commits of its own outside the payload: lesson-counts/<host>.tsv, the lesson tag
# files and lesson-bands/<host>. A clone with an upstream, one such commit unpushed, holding a token.
OB="$TMPROOT/outside/remote.git"; OC="$TMPROOT/outside/clone"
mkdir -p "$TMPROOT/outside"
git init -q --bare "$OB" 2>/dev/null
git clone -q "$OB" "$OC" 2>/dev/null
mkdir -p "$OC/payload" "$OC/lesson-counts"
printf 'nothing secret\n' > "$OC/payload/clean.txt"
printf 'HOST MacOut\nEND\n' > "$OC/lesson-counts/MacOut.tsv"
gq(){ git -C "$OC" -c user.name=t -c user.email=t@e "$@" >/dev/null 2>&1; }
gq add -A; gq commit -q -m seed; gq push -q -u origin HEAD
printf 'HOST MacOut\nL1\t3 api_key=%s\nEND\n' "$(printf 'outside the payload control' | shasum -a 256 | cut -c1-40)" > "$OC/lesson-counts/MacOut.tsv"
gq add -A; gq commit -q -m 'MacOut records its lesson citation counts'
out="$(run_scan "$OC/payload" "$OC")"
case "$out" in
  *'possible secret found in: lesson-counts/MacOut.tsv'*'SCAN-RC=1') check "#1133 a token in an unpushed lesson counts commit is refused and named" ok ;;
  *) check "#1133 a token in an unpushed lesson counts commit is refused and named" "got: $(printf '%s' "$out" | tr '\n' ' ')" ;;
esac
# Its control: the same clone with nothing unpushed outside the payload passes, so the refusal above
# came from the commit and not from the scan reading the clone's whole history.
gq push -q
out="$(run_scan "$OC/payload" "$OC")"
case "$out" in
  *'SCAN-RC=0') check "#1133 control: once the shared repo holds that commit, the send has nothing outside the payload to judge" ok ;;
  *) check "#1133 control: once the shared repo holds that commit, the send has nothing outside the payload to judge" "got: $(printf '%s' "$out" | tr '\n' ' ')" ;;
esac
# What the shared repo gained that this clone has not taken in is not this send's to judge: a clone
# BEHIND its upstream reads only its own commits, never the other side's (a two dot diff of the
# upstream against HEAD lists both). The shared repo already holds a token shaped record (published
# past the scan, as SYNC_SKIP_SECRET_SCAN allows), this clone has it, and the other side then
# changes it. This clone fetches and stays behind, so the record is one it neither wrote nor sends.
OC2="$TMPROOT/outside/other"
git clone -q "$OB" "$OC2" 2>/dev/null
printf 'token=%s\n' "$(printf 'the other side published this' | shasum -a 256 | cut -c1-40)" > "$OC2/other-record.txt"
git -C "$OC2" add -A >/dev/null 2>&1
git -C "$OC2" -c user.name=t -c user.email=t@e commit -q -m other >/dev/null 2>&1
git -C "$OC2" push -q >/dev/null 2>&1
git -C "$OC" pull -q --rebase >/dev/null 2>&1
printf 'token=%s\n' "$(printf 'the other side changed this' | shasum -a 256 | cut -c1-40)" > "$OC2/other-record.txt"
git -C "$OC2" -c user.name=t -c user.email=t@e commit -q -am 'other again' >/dev/null 2>&1
git -C "$OC2" push -q >/dev/null 2>&1
git -C "$OC" fetch -q >/dev/null 2>&1
behind="$(git -C "$OC" rev-list --count HEAD..@{upstream} 2>/dev/null)"
out="$(run_scan "$OC/payload" "$OC")"
case "$behind:$out" in
  1:*'SCAN-RC=0') check "#1133 a clone behind its upstream judges only its own commits, not what the other side published" ok ;;
  *) check "#1133 a clone behind its upstream judges only its own commits, not what the other side published" "behind ${behind:-?}, got: $(printf '%s' "$out" | tr '\n' ' ')" ;;
esac

# When git cannot say what is new, the send is refused and says so, rather than scanning the
# payload alone and passing. A git that refuses the listing, in the same subshell as the scan.
scan_with_refusing_git(){
  local PAYLOAD="$1" SYNC_REPO="$2" SEND_REFUSED_FILE="$2/.send-refused"
  (
    unset SYNC_SKIP_SECRET_SCAN
    die(){ printf 'REFUSED: %s\n' "$*"; exit 1; }
    git(){
      case " $* " in
        *' diff '*) echo 'fatal: listing refused for this test' >&2; return 128 ;;
        *) command git "$@" ;;
      esac
    }
    eval "$BLANK_SRC"; eval "$SCAN_SRC"
    scan_secrets
  ) 2>&1
  printf 'SCAN-RC=%s\n' "$?"
}
out="$(scan_with_refusing_git "$OC/payload" "$OC")"
case "$out" in
  *'REFUSED: git could not list the files outside the payload'*'listing refused for this test'*) check "#1133 a listing git refuses is a refusal that names git's reason" ok ;;
  *) check "#1133 a listing git refuses is a refusal that names git's reason" "got: $(printf '%s' "$out" | tr '\n' ' ')" ;;
esac
# And it is recorded, since the staged edits stay behind as after any refusal, as what it is: no
# finding, and why. A later pull reads the record through pending_edits_cause, cut out here too.
rec="$(cat "$OC/.send-refused" 2>/dev/null)"
case "$rec" in
  [0-9]*"$(printf '\t\t')unlisted") check "#1133 that refusal is recorded with no finding and the reason" ok ;;
  *) check "#1133 that refusal is recorded with no finding and the reason" "got: '$rec'" ;;
esac
CAUSE_SRC="$(sed -n '/^pending_edits_cause(){/,/^}/p' "$SCRIPT")"
AGE_SRC="$(sed -n '/^age_in_words(){/,/^}/p' "$SCRIPT")"
cause="$(SEND_REFUSED_FILE="$OC/.send-refused" SYNC_REPO="$OC"; eval "$AGE_SRC"; eval "$CAUSE_SRC"; pending_edits_cause 2>&1)"
case "$cause" in
  *'git could not list the files outside the payload'*) check "#1133 and a later pull names it as that, never as a possible secret" ok ;;
  *) check "#1133 and a later pull names it as that, never as a possible secret" "got: $cause" ;;
esac
case "$cause" in
  *'possible secret'*) check "#1133 control: the cause names no secret it never found" "got: $cause" ;;
  *) check "#1133 control: the cause names no secret it never found" ok ;;
esac

# The comment over scan_secrets says what it does, and once said it used a tool it never called
# (#1128). unbacked_tool_claim <comment and body>: prints each external scanner the text names
# that no line of code invokes.
unbacked_tool_claim(){
  local text="$1" tool code
  code="$(grep -v '^[[:space:]]*#' <<< "$text" || true)"
  # Here strings, never a pipe into grep -q, which can leave early and read as a failure (L183).
  for tool in gitleaks trufflehog detect-secrets; do
    grep -qi -- "$tool" <<< "$text" || continue
    grep -qE -- "(^|[^A-Za-z_-])$tool([[:space:]]|\$)" <<< "$code" || printf '%s\n' "$tool"
  done
}
SCAN_DOC="$(awk '/^#/ { buf = buf $0 "\n"; next } /^scan_secrets\(\)\{/ { printf "%s", buf; exit } { buf = "" }' "$SCRIPT")"
[ -n "$SCAN_DOC" ] && check "#1128 the comment over scan_secrets was read" ok \
  || check "#1128 the comment over scan_secrets was read" "none found, so what it claims was not judged"
claimed="$(unbacked_tool_claim "$SCAN_DOC
$SCAN_SRC")"
[ -z "$claimed" ] && check "#1128 scan_secrets names no scanner it does not call" ok \
  || check "#1128 scan_secrets names no scanner it does not call" "it names $(printf '%s' "$claimed" | tr '\n' ' ') but never runs it"
# Its control: the comment as it read before #1128, over the body it sat on.
claimed="$(unbacked_tool_claim "# Block obvious credentials from being published. Uses gitleaks if installed,
scan_secrets(){
  grep -rIoE \"\$pat\" \"\$PAYLOAD\"
}")"
[ "$claimed" = gitleaks ] && check "#1128 control: a comment naming gitleaks over a body that never runs it is caught" ok \
  || check "#1128 control: a comment naming gitleaks over a body that never runs it is caught" "got: '$claimed'"

# The same run refuses a planted credential, so its silence above is a verdict.
mkdir -p "$TMPROOT/planted/payload/skills/x" "$TMPROOT/planted/repo"
# The planted token is a hash made here, never pieces of one written into this file (#1125).
printf '{ "token": "%s" }\n' "$(printf 'payload scan planted control' | shasum -a 256 | cut -c1-40)" > "$TMPROOT/planted/payload/skills/x/c.json"
out="$(run_scan "$TMPROOT/planted/payload" "$TMPROOT/planted/repo")"
case "$out" in
  *'possible secret found in: skills/x/c.json'*'SCAN-RC=1') check "control: the same scan refuses a planted token and names its file" ok ;;
  *) check "control: the same scan refuses a planted token and names its file" "got: $(printf '%s' "$out" | tr '\n' ' ')" ;;
esac

# And it refuses the placeholder that blocked sync, so this suite would have caught it. Read from
# the commit that shipped it rather than written here, because this file is scanned too (#1128),
# and a copy of it here would be the very placeholder the scan refuses.
if git -C "$ROOT" cat-file -e 96ec0d97:payload/skills/tracker/config.example.json 2>/dev/null; then
  mkdir -p "$TMPROOT/old/payload/skills/tracker" "$TMPROOT/old/repo"
  git -C "$ROOT" show 96ec0d97:payload/skills/tracker/config.example.json > "$TMPROOT/old/payload/skills/tracker/config.example.json"
  out="$(run_scan "$TMPROOT/old/payload" "$TMPROOT/old/repo")"
  case "$out" in
    *'possible secret found in: skills/tracker/config.example.json'*'SCAN-RC=1') check "control: the scan refuses the token shaped placeholder that blocked sync after #675" ok ;;
    *) check "control: the scan refuses the token shaped placeholder that blocked sync after #675" "got: $(printf '%s' "$out" | tr '\n' ' ')" ;;
  esac
else
  echo "UNMEASURED: the #675 placeholder control: commit 96ec0d97 is not in this clone's history"
fi

# Every path that ends a scan WITHOUT refusing clears the record of the last refusal
# (claude-config#947), or a later pull blames a refusal that no longer applies. The early returns
# are the paths a test of the whole tool cannot easily reach, so they are driven here.
run_scan_recorded(){   # $1 = payload dir  $2 = repo dir  $3 = SYNC_SKIP_SECRET_SCAN value
  local PAYLOAD="$1" SYNC_REPO="$2" SEND_REFUSED_FILE="$2/.send-refused" SYNC_SKIP_SECRET_SCAN="$3"
  printf '1\tskills/x/c.json\n' > "$SEND_REFUSED_FILE"
  (
    die(){ printf 'REFUSED: %s\n' "$*"; exit 1; }
    eval "$BLANK_SRC"
    eval "$SCAN_SRC"
    scan_secrets
  ) >/dev/null 2>&1
  [ -e "$SEND_REFUSED_FILE" ] && printf 'still there' || printf 'cleared'
}
mkdir -p "$TMPROOT/rec/repo" "$TMPROOT/rec/clean/payload"
printf 'nothing secret\n' > "$TMPROOT/rec/clean/payload/f.txt"
r="$(run_scan_recorded "$TMPROOT/rec/clean/payload" "$TMPROOT/rec/repo" 0)"
[ "$r" = cleared ] && check "#947 a scan that passes clears the record of the last refusal" ok \
  || check "#947 a scan that passes clears the record of the last refusal" "$r"
r="$(run_scan_recorded "$TMPROOT/rec/no-such-payload" "$TMPROOT/rec/repo" 0)"
[ "$r" = cleared ] && check "#947 so does a scan with no payload to read" ok \
  || check "#947 so does a scan with no payload to read" "$r"
r="$(run_scan_recorded "$TMPROOT/planted/payload" "$TMPROOT/rec/repo" 1)"
[ "$r" = cleared ] && check "#947 so does a send let past the scan with SYNC_SKIP_SECRET_SCAN=1" ok \
  || check "#947 so does a send let past the scan with SYNC_SKIP_SECRET_SCAN=1" "$r"
r="$(run_scan_recorded "$TMPROOT/planted/payload" "$TMPROOT/rec/repo" 0)"
[ "$r" = 'still there' ] && check "#947 control: a scan that refuses keeps it" ok \
  || check "#947 control: a scan that refuses keeps it" "$r"

# --- no test assembles a token this scan would refuse (claude-config#1125) --------
# A fixture that gets past the scan by HOW it is written, never by what it is, is an exception to
# the scan that nobody reviewed, and it shows the next real token a way through: a key in one place
# and its value in a variable, or a value printed from two halves. The scan reads text, so it sees
# neither. This reads every test file the way the shell would put it together, and runs the SAME
# scan over that: each variable given one literal value in its file replaced by it, escaped quotes
# unescaped, adjacent quoted pieces and Python's "a" + "b" joined, and printf's %s filled from its
# quoted arguments. A line is an assembly when the scan refuses the joined form and refuses none of
# its pieces (the raw line, and each value put into it). So a value written whole and visible to the
# scan, like the AWS example key the sync tests plant, is not one, because the scan already sees it.
#
# A fixture the scan accepts BY ITS OWN RULES is the way to stay clear of this: a placeholder with
# spaces or angle brackets (README "Secret scan"), or a value shorter than a pattern's minimum. A
# control that must be token shaped is derived at run time (a hash), so no token exists in the file
# to be split. Reading Python assignments and here documents is out of reach of this check.
#
# assembled_lines <root> <file holding the relative paths to read>: prints path:line per assembly,
# then "READ files=<n> joined=<m>" last, so a run that read nothing cannot pass as clean (L98).
assembled_lines(){
  local root="$1" list="$2" work raw joined listing
  work="$(mktemp -d "$TMPROOT/assembly.XXXXXX")" || { echo "READ failed: no scratch directory"; return 1; }
  raw="$work/raw"; joined="$work/joined"; mkdir -p "$raw" "$joined"
  if python3 - "$root" "$list" "$raw" "$joined" > "$work/listing" 2>&1 <<'PY'
import itertools, os, re, sys
root, listfile, out_raw, out_joined = sys.argv[1:5]
assign = re.compile(r"""^\s*(?:(?:local|export|readonly|declare(?:\s+-\w+)?)\s+)?([A-Za-z_]\w*)=(?:"([^"$`\\]*)"|'([^']*)'|([^\s"'$`;|&<>()\\]+))(?=\s|;|$)""")
ref = re.compile(r"\$\{([A-Za-z_]\w*)\}|\$([A-Za-z_]\w*)")
glue = re.compile(r"""(?<=[A-Za-z0-9_+/.-])(?:"\s*\+\s*"|'\s*\+\s*'|""|''|"'|'")(?=[A-Za-z0-9_+/.-])""")
printf = re.compile(r"""printf\s+(?:-v\s+\w+\s+)?(?:--\s+)?(['"])((?:(?!\1).)*)\1((?:\s+(?:"(?:[^"\\]|\\.)*"|'[^']*'|[^\s'"<>|;&]+))*)""")
arg = re.compile(r"""\s+(?:"((?:[^"\\]|\\.)*)"|'([^']*)'|([^\s'"<>|;&]+))""")

def fill(m):
    args = [next(g for g in a if g) if any(a) else "" for a in arg.findall(m.group(3))]
    it = iter(args)
    body = re.sub(r"%%|%[sb]", lambda c: "%" if c.group(0) == "%%" else next(it, ""), m.group(2))
    return "printf " + m.group(1) + body + m.group(1) + "".join(" '%s'" % a for a in it)

files = n = 0
for rel in open(listfile).read().splitlines():
    try:
        lines = open(os.path.join(root, rel), errors="ignore").read().splitlines()
    except OSError:
        continue
    files += 1
    values = {}
    for l in lines:
        m = assign.match(glue.sub("", l))
        if m:
            values.setdefault(m.group(1), set()).add(next((g for g in m.groups()[1:] if g is not None), ""))
    for i, l in enumerate(lines, 1):
        names = sorted({a or b for a, b in ref.findall(l)} & set(values))
        used, forms = [], []
        for combo in itertools.islice(itertools.product(*[sorted(values[k]) for k in names]), 16):
            sub = dict(zip(names, combo))
            used += combo
            e = ref.sub(lambda r: sub.get(r.group(1) or r.group(2), r.group(0)), l)
            forms.append(printf.sub(fill, glue.sub("", e.replace('\\"', '"'))))
        if not names:
            forms = [printf.sub(fill, glue.sub("", l.replace('\\"', '"')))]
        if forms == [l]:
            continue
        name = rel.replace("/", "%") + "__L%d" % i
        open(os.path.join(out_raw, name), "w").write("\n".join([l] + used) + "\n")
        open(os.path.join(out_joined, name), "w").write("\n".join(forms) + "\n")
        n += 1
print("READ files=%d joined=%d" % (files, n))
PY
  then listing="$(cat "$work/listing")"
  else echo "READ failed: the reader stopped: $(cat "$work/listing")"; return 1; fi
  refused_in(){ run_scan "$1" "$work/repo" | sed -n 's/^REFUSED: possible secret found in: \(.*\)\. Remove it.*/\1/p' | tr ' ' '\n' | sed '/^$/d' | sort -u; }
  mkdir -p "$work/repo"
  comm -13 <(refused_in "$raw") <(refused_in "$joined") | sed -e 's/%/\//g' -e 's/__L\([0-9]*\)$/:\1/'
  printf '%s\n' "$listing"
}

# Every test in this repository: tracked or not yet, under tests/ or named test-* anywhere. A listing
# that fails is said to be one, rather than read as a repository with too few tests (#1146).
if all_files="$(bash "$TREE_LISTER" "$ROOT" 2> "$TMPROOT/test-files.err")"; then
  printf '%s\n' "$all_files" | grep -E '(^|/)test-[^/]*$|^tests/' > "$TMPROOT/test-files" || true
  out="$(assembled_lines "$ROOT" "$TMPROOT/test-files")"
  read_files="$(printf '%s\n' "$out" | sed -n 's/^READ files=\([0-9]*\).*/\1/p')"
  [ "${read_files:-0}" -ge 100 ] && check "#1125 the assembly check reads every test file ($read_files)" ok \
    || check "#1125 the assembly check reads every test file (${read_files:-none})" "too few to be this repository's tests: $out"
  found="$(printf '%s\n' "$out" | grep -v '^READ ' || true)"
  [ -z "$found" ] && check "#1125 no test assembles a token the secret scan would refuse" ok \
    || check "#1125 no test assembles a token the secret scan would refuse" "write the fixture so the scan accepts it as written (see the comment above this check): $(printf '%s' "$found" | tr '\n' ' ')"
else
  unmeasured "the #1125 assembly check over every test file" "the files under $ROOT could not be listed: $(head -3 "$TMPROOT/test-files.err" | tr '\n' ' ')"
fi

# The controls, both ways (L1, L497). The token shaped values are a hash, made here, so this file
# holds none of them; each fixture is a file of its own, read the same way as the tests above.
FX="$TMPROOT/assembly-fixtures"; mkdir -p "$FX/tests"
fxv="$(printf 'claude-config#1125 control' | shasum -a 256 | cut -c1-40)"
printf 'FXV="%s"\nprintf '"'"'{"token":"%%s"}'"'"' "$FXV"\n' "$fxv" > "$FX/tests/test-key-apart.sh"
printf 'write "{\\"token\\":\\"$FXV\\"}"\nFXV="%s"\n' "$fxv" > "$FX/tests/test-escaped.sh"
printf "printf '{ \"token\": \"%%s%%s\" }' \"%s\" \"%s\"\n" "${fxv:0:16}" "${fxv:16}" > "$FX/tests/test-halves.sh"
printf 'FXV="%s"\nprintf "AKI""A%%s" "$FXV"\n' "$(printf '%s' "$fxv" | tr 'a-f' 'A-F' | cut -c1-16)" > "$FX/tests/test-glued.sh"
printf 'FXG="%s""%s"\necho "api_key=$FXG"\n' "${fxv:0:8}" "${fxv:8}" > "$FX/tests/test-glued-value.sh"
cat > "$FX/tests/test-placeholder.sh" <<'EOF'
FXP="kept token, invented for this test"
write "{\"token\":\"$FXP\"}"
EOF
# The fixture holds a whole AWS shaped key; this file holds none, since it is scanned too (#1128).
fxa="AKIA$(printf '%s' "$fxv" | tr 'a-f' 'A-F' | cut -c1-16)"
{ printf "FXS='%s'\n" "$fxa"; printf '%s\n' "printf 'export AWS_KEY=%s\\n' \"\$FXS\""; } > "$FX/tests/test-visible.sh"
(cd "$FX" && ls tests) | sed 's|^|tests/|' > "$FX/list"
out="$(assembled_lines "$FX" "$FX/list")"
for want in tests/test-key-apart.sh:2 tests/test-escaped.sh:1 tests/test-halves.sh:1 tests/test-glued.sh:2 tests/test-glued-value.sh:2; do
  case "$out" in
    *"$want"*) check "#1125 control: the check finds the assembly at $want" ok ;;
    *) check "#1125 control: the check finds the assembly at $want" "got: $(printf '%s' "$out" | tr '\n' ' ')" ;;
  esac
done
case "$out" in
  *test-placeholder*) check "#1125 control: a placeholder the scan accepts by its own rules is not an assembly" "got: $(printf '%s' "$out" | tr '\n' ' ')" ;;
  *) check "#1125 control: a placeholder the scan accepts by its own rules is not an assembly" ok ;;
esac
case "$out" in
  *test-visible*) check "#1125 control: a value the scan already sees whole is not an assembly" "got: $(printf '%s' "$out" | tr '\n' ' ')" ;;
  *) check "#1125 control: a value the scan already sees whole is not an assembly" ok ;;
esac
# And the real fixture this issue was filed against, when the history holding it is here.
if git -C "$ROOT" cat-file -e a323443b:payload/skills/tracker/test-scan-flow.sh 2>/dev/null; then
  mkdir -p "$FX/old/payload/skills/tracker"
  git -C "$ROOT" show a323443b:payload/skills/tracker/test-scan-flow.sh > "$FX/old/payload/skills/tracker/test-scan-flow.sh"
  printf 'payload/skills/tracker/test-scan-flow.sh\n' > "$FX/old/list"
  case "$(assembled_lines "$FX/old" "$FX/old/list")" in
    *'test-scan-flow.sh:161'*) check "#1125 control: the check finds the tracker scan test's token as #1112 shipped it" ok ;;
    *) check "#1125 control: the check finds the tracker scan test's token as #1112 shipped it" "not found" ;;
  esac
else
  echo "UNMEASURED: #1125 control on the fixture #1112 shipped: commit a323443b is not in this clone's history"
fi

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
# A run that could not scan part of what it scans is not a pass: exit 3, apart from a failure, so
# the pre push gate holds the push as a fault in its own run and CI stays red (#1146).
if [ "$unmeasured_n" -gt 0 ]; then
  echo "UNMEASURED: $unmeasured_n part(s) of this scan could not be made; the SCAN-UNMEASURED lines above say why."
  exit 3
fi
exit 0
