#!/usr/bin/env bash
#
# target-guard.sh: decide whether a bug bash may run against a URL (claude-config#719).
#
#   bash ~/.claude/skills/bug-bash/target-guard.sh <url>
#   bash ~/.claude/skills/bug-bash/target-guard.sh --read-only --proxy <proxy url> <url>
#
# Two rules from the skill, enforced here rather than left to a sentence:
#   1. Never a deployed site with real users. A host that is not this machine is refused, before
#      any request is made to it, unless read only is asked for, in which case the run is labelled
#      READ-ONLY and the explorers may only look. A read only run starts only behind the read only
#      proxy (read-only-proxy.js, #813), the guard that holds explorers to reading outside any
#      browser: --proxy (or BUG_BASH_PROXY) must name it, it must answer as itself, and it must be
#      seen to refuse a write, sent to a host that does not exist so a proxy that forwarded it
#      reaches nothing. Only then is any request made to the target.
#   2. A production build, never a dev server. A dev server compiles each route on its first visit
#      and injects reload scripts, so explorers report its pauses as dead links. A local URL whose
#      page carries a dev server's marks is refused. The marks recognised are Next.js's, Vite's
#      (and so Astro, Nuxt, SvelteKit and Remix, which serve through it) and webpack's dev
#      server's; a dev server with none of them is not caught, so the skill's own step still says
#      to serve a production build.
#
# Prints one line on success, `LOCAL <url>` or `READ-ONLY <url> via <proxy>`, and exits 0. Every refusal goes
# to stderr with its reason and a distinct exit code: 2 usage, 3 remote without read only, 4 dev
# server, 5 nothing answering, 6 a redirect chain longer than six hops, 7 a read only run with no
# working read only proxy.
# Text is matched through here strings, never `printf | grep -q`: under pipefail grep -q exiting on
# its first match kills printf, and the pipeline then reads as no match (L183).
set -uo pipefail

usage() { echo "Usage: target-guard.sh [--read-only [--proxy <proxy url>]] <http(s) url>" >&2; }

read_only=0
proxy="${BUG_BASH_PROXY:-}"
while [ "$#" -gt 1 ]; do
  case "$1" in
    --read-only) read_only=1; shift ;;
    --proxy) [ "$#" -ge 3 ] || { usage; exit 2; }; proxy="$2"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done
[ "$#" -eq 1 ] || { usage; exit 2; }
url="$1"

case "$url" in
  http://*|https://*) ;;
  *) echo "target-guard: give a full http:// or https:// URL, got: $url" >&2; exit 2 ;;
esac

# A URL's host, without scheme, credentials, port or path, lower cased. A bracketed IPv6 literal
# keeps its brackets.
host_of() {
  local rest="${1#*://}"
  rest="${rest%%/*}"
  rest="${rest%%\?*}"
  rest="${rest%%#*}"
  rest="${rest##*@}"
  case "$rest" in
    \[*\]*) rest="${rest%%]*}]" ;;
    *) rest="${rest%%:*}" ;;
  esac
  printf '%s' "$rest" | tr '[:upper:]' '[:lower:]'
}
# Local means the whole host names this machine. Matched on the whole name, so localhost.example.com
# and 127.0.0.1.nip.io, which resolve wherever their owners like, are remote.
is_local_host() {
  case "$1" in
    localhost|*.localhost|\[::1\]) return 0 ;;
    127.*) grep -Eq '^127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' <<< "$1" ;;
    *) return 1 ;;
  esac
}
# A read only run needs the read only proxy up and refusing writes, checked before anything else so
# that no request reaches the target without it (#813).
if [ "$read_only" -eq 1 ]; then
  no_proxy_fix="Start it with: node ~/.claude/skills/bug-bash/read-only-proxy.js --state <run dir>/proxy, then pass --proxy with the \"proxy\" value from its proxy.json."
  if [ -z "$proxy" ]; then
    echo "target-guard: refusing a read only run with no read only proxy: explorers are held to reading by that proxy, outside their browsers. $no_proxy_fix" >&2
    exit 7
  fi
  case "$proxy" in
    http://*) ;;
    *) echo "target-guard: refusing $proxy as the read only proxy: it listens on a local http:// address. $no_proxy_fix" >&2; exit 7 ;;
  esac
  proxy="${proxy%/}"
  if ! is_local_host "$(host_of "$proxy")"; then
    echo "target-guard: refusing $proxy as the read only proxy: it is not on this machine. $no_proxy_fix" >&2
    exit 7
  fi
  health="$(curl -s --noproxy '*' --max-time 5 "$proxy/__bug-bash-proxy__/health" 2>/dev/null)"
  if ! grep -q '"proxy":"bug-bash-read-only"' <<< "$health"; then
    echo "target-guard: refusing a read only run: nothing at $proxy answers as the bug bash read only proxy. $no_proxy_fix" >&2
    exit 7
  fi
  # A write sent through it, to a name that resolves nowhere (.invalid), must come back refused by
  # the proxy itself: a proxy that forwarded it would reach nothing.
  probe="$(curl -s --noproxy '' --max-time 5 -o /dev/null -D - -x "$proxy" -X POST --data probe "http://bug-bash-probe.invalid/write" 2>/dev/null)"
  if ! grep -Eq '^HTTP/[0-9.]+ 405' <<< "$probe" || ! grep -qi '^x-bug-bash-proxy: refused' <<< "$probe"; then
    echo "target-guard: refusing a read only run: the proxy at $proxy did not refuse a write sent through it. $no_proxy_fix" >&2
    exit 7
  fi
fi

host="$(host_of "$url")"
is_local=0
is_local_host "$host" && is_local=1

if [ "$is_local" -eq 0 ]; then
  if [ "$read_only" -eq 1 ]; then
    printf 'READ-ONLY %s via %s\n' "$url" "$proxy"
    exit 0
  fi
  echo "target-guard: refusing $host: it is not this machine, so it may have real users and real data. Run the bug bash against a local production build, or pass --read-only to only look." >&2
  exit 3
fi

# Redirects are followed by hand, one hop at a time, each target judged before it is requested,
# so a local page that redirects off this machine is refused without a request to where it points
# (curl -L would follow it and judge the remote page instead).
at="$url"
page=""
for _hop in 1 2 3 4 5 6; do
  body_file="$(mktemp)"
  meta="$(curl -s --max-time 10 -o "$body_file" -w '%{http_code} %{redirect_url}' "$at" 2>/dev/null)"
  page="$(cat "$body_file")"
  rm -f "$body_file"
  code="${meta%% *}"
  next="${meta#* }"
  [ "$next" = "$meta" ] && next=""
  if [ -z "$code" ] || [ "$code" = "000" ]; then
    echo "target-guard: nothing answered at $at. Start the production build first (for example a build then a start), then run this again." >&2
    exit 5
  fi
  [ -n "$next" ] || break
  if ! is_local_host "$(host_of "$next")"; then
    echo "target-guard: refusing $url: it redirects to $(host_of "$next"), which is not this machine." >&2
    exit 3
  fi
  at="$next"
done
# The last hop still pointing on means the guard never reached a page to judge.
if [ -n "$next" ]; then
  echo "target-guard: refusing $url: it redirects more than 6 times, so no page was reached to judge." >&2
  exit 6
fi

dev_reason=""
# Next.js in development: the React refresh runtime, the development build id, the HMR socket.
if grep -Eq 'react-refresh|"buildId":"development"|/_next/webpack-hmr|__webpack_hmr' <<< "$page"; then
  dev_reason="the page loads Next.js development scripts"
fi
# webpack's dev server (Create React App and its kin): its client script and its socket.
if [ -z "$dev_reason" ] && grep -Eq 'webpack-dev-server|sockjs-node|__webpack_dev_server__' <<< "$page"; then
  dev_reason="the page loads the webpack dev server client"
fi
# Vite in development: the client it injects, linked from the page or served at its fixed path.
if [ -z "$dev_reason" ]; then
  # Probed at the origin and under the URL's own path, since an app served with a base path has
  # its client there.
  origin="${url%%://*}://$(printf '%s' "${url#*://}" | cut -d/ -f1)"
  base="${url%%[?#]*}"
  base="${base%/}"
  # Judged by what comes back, never by the status alone: a production single page app answers
  # 200 with its own index page for any path, this one included.
  is_vite_client() { # the body is script, not a page, and names vite
    local body
    body="$(curl -s --max-time 10 "$1" 2>/dev/null)"
    body="${body:0:4096}"
    [ -n "$body" ] || return 1
    grep -qi '<html\|<!doctype' <<< "$body" && return 1
    grep -qi 'vite' <<< "$body"
  }
  if grep -q '/@vite/client' <<< "$page" || is_vite_client "$origin/@vite/client" || is_vite_client "$base/@vite/client"; then
    dev_reason="the server answers with the Vite development client"
  fi
fi
if [ -n "$dev_reason" ]; then
  echo "target-guard: refusing $url: it is a dev server ($dev_reason). A dev server compiles routes on first visit, which explorers report as dead links. Serve a production build and point the bug bash at that." >&2
  exit 4
fi

# Read only asked for is read only, wherever the build runs.
if [ "$read_only" -eq 1 ]; then printf 'READ-ONLY %s via %s\n' "$url" "$proxy"; else printf 'LOCAL %s\n' "$url"; fi
