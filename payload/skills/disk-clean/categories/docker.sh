#!/usr/bin/env bash
#
# docker.sh: disk-clean's Docker category (claude-config#1806). See scan-lib.sh for the module calls.
#
# Only when `docker info` answers; otherwise the category is unmeasured, saying whether Docker is not
# installed or not running. Offered, through disk-remove.sh's docker method: dangling images
# ("image <id>"), stopped containers ("container <id>") and the build cache ("builder cache"), each
# with Docker's own size (size "reported"). Volumes are listed by name and never offered: they hold
# data, and disk-remove.sh refuses them by name too.
set -uo pipefail
HERE="${BASH_SOURCE[0]%/*}"; [ "$HERE" != "${BASH_SOURCE[0]}" ] || HERE=.
. "$HERE/../scan-lib.sh" || { echo "unmeasured: scan-lib.sh is missing beside the categories folder"; exit 0; }

# Sets UP to yes, or V to why Docker cannot be read.
docker_up() {
  UP=""
  if ! command -v docker >/dev/null 2>&1; then V="unmeasured: docker is not installed"; return 1; fi
  if ! docker info >/dev/null 2>&1 </dev/null; then V="unmeasured: Docker is not running (docker info failed)"; return 1; fi
  UP=yes
}

do_scan() {
  docker_up || { dcs_status "$V"; return 0; }
  local out id size name kib
  out="$(docker images --filter dangling=true --format '{{.ID}}{{"\t"}}{{.Size}}' </dev/null 2>&1)" || { dcs_status "unmeasured: docker images failed (${out%%$'\n'*})"; return 0; }
  while IFS="$TAB" read -r id size; do
    [ -n "$id" ] || continue
    kib="$(dcu_docker_kib "$size")" || kib=""
    dcs_item "image $id" docker "$kib" "$([ -n "$kib" ] && echo reported || echo unread)" offerable "" "a dangling image, which no tag names" ""
  done <<< "$out"
  out="$(docker ps -a --filter status=exited --filter status=created --format '{{.ID}}{{"\t"}}{{.Names}}{{"\t"}}{{.Size}}' </dev/null 2>&1)" || { dcs_status "unmeasured: docker ps failed (${out%%$'\n'*})"; return 0; }
  while IFS="$TAB" read -r id name size; do
    [ -n "$id" ] || continue
    kib="$(dcu_docker_kib "${size%% *}")" || kib=""
    dcs_item "container $id" docker "$kib" "$([ -n "$kib" ] && echo reported || echo unread)" offerable "" "a stopped container ($name)" ""
  done <<< "$out"
  out="$(docker system df --format '{{.Type}}|{{.Size}}' </dev/null 2>&1)" || { dcs_status "unmeasured: docker system df failed (${out%%$'\n'*})"; return 0; }
  size="$(printf '%s\n' "$out" | awk -F '|' '$1 == "Build Cache" && !f { print $2; f = 1 }')"
  kib="$(dcu_docker_kib "$size")" || kib=""
  if [ -n "$kib" ] && [ "$kib" -gt 0 ]; then
    dcs_item "builder cache" docker "$kib" reported offerable "" "Docker's build cache, which the next build fills again" ""
  fi
  out="$(docker volume ls --format '{{.Name}}' </dev/null 2>&1)" || { dcs_status "unmeasured: docker volume ls failed (${out%%$'\n'*})"; return 0; }
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    dcs_item "volume $name" docker "" unread "not offerable: Docker volumes hold data, so they are listed and never offered" "" "" ""
  done <<< "$out"
}

do_judge() { # <target>
  local t="$1" kind ref out
  kind="${t%% *}"; ref="${t#* }"
  case "$kind" in
    volume) echo "not offerable: Docker volumes hold data, so they are never offered"; return 0 ;;
    image|container|builder) ;;
    *) echo "not offerable: it is not a Docker target this category offers"; return 0 ;;
  esac
  docker_up || { echo "$V"; return 0; }
  case "$kind" in
    image)
      out="$(docker image inspect --format '{{len .RepoTags}}' "$ref" </dev/null 2>/dev/null)" || { echo "not offerable: Docker has no such image now"; return 0; }
      [ "$out" = 0 ] && echo offerable || echo "not offerable: a tag names it now" ;;
    container)
      out="$(docker container inspect --format '{{.State.Running}}' "$ref" </dev/null 2>/dev/null)" || { echo "not offerable: Docker has no such container now"; return 0; }
      [ "$out" = false ] && echo offerable || echo "not offerable: it is running" ;;
    builder) [ "$ref" = cache ] && echo offerable || echo "not offerable: it is not a Docker target this category offers" ;;
  esac
}

case "${1:-}" in
  scan) do_scan ;;
  judge) do_judge "${2:-}" ;;
  *) echo "usage: docker.sh scan | docker.sh judge <target>" >&2; exit 2 ;;
esac
