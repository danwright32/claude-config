#!/usr/bin/env bash
#
# docker.sh: disk-clean's Docker category (claude-config#1806). See scan-lib.sh for the module calls.
#
# Only when `docker info` answers; otherwise the category is unmeasured, saying whether Docker is not
# installed or not running. Listed, through disk-remove.sh's docker method: dangling images
# ("image <id>"), stopped containers ("container <id>") and the build cache ("builder cache"), each
# with Docker's own size (size "reported"). Only a stopped container can be offered, under the 30
# day floor below: images and the build cache stay unmeasured (#2134). Volumes are listed by name and never offered: they hold
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

# The 30 day floor for Docker's targets, which are not files, so it reads Docker's own times
# (#2134). Docker records no time an image was last used, and disk-clean removes the build cache
# whole without reading when it was last used, so neither is ever offered. A stopped container is
# judged by when it was created, last started and last stopped: any of the three within 30 days, a
# time missing, or one that cannot be read, and it is not offered.
IMAGE_WHY="unmeasured: Docker records no time an image was last used, so whether it was used in $DCS_UNUSED_DAYS days is not known"
CACHE_WHY="unmeasured: disk-clean does not read when the build cache was last used, so whether it was used in $DCS_UNUSED_DAYS days is not known"
# Sets V for one container from `docker container inspect`, shared by the scan and the judge.
container_rule() { # <container id>
  local out running ts cutoff n=0 times=()
  out="$(docker container inspect --format '{{.State.Running}} {{.Created}} {{.State.StartedAt}} {{.State.FinishedAt}}' "$1" </dev/null 2>/dev/null)" || { V="not offerable: Docker has no such container now"; return; }
  read -r running ts <<< "$out"
  [ "$running" = false ] || { V="not offerable: it is running"; return; }
  read -r -a times <<< "$ts"
  n="${#times[@]}"
  [ "$n" -eq 3 ] || { V="unmeasured: Docker gave $n of the 3 times it records for a container, so whether it was used in $DCS_UNUSED_DAYS days is not known"; return; }
  cutoff="$(date -u -v-"$DCS_UNUSED_DAYS"d '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -u -d "$DCS_UNUSED_DAYS days ago" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null)"
  [ -n "$cutoff" ] || { V="unmeasured: the time $DCS_UNUSED_DAYS days ago could not be written, so whether it was used in $DCS_UNUSED_DAYS days is not known"; return; }
  for ts in "${times[@]}"; do
    if ! [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2} ]] || [ "${ts: -1}" != Z ]; then
      V="unmeasured: Docker gave a time that could not be read ($ts), so whether it was used in $DCS_UNUSED_DAYS days is not known"; return
    fi
    [[ "${ts:0:19}" > "$cutoff" ]] && { V="not offerable: used within $DCS_UNUSED_DAYS days"; return; }
  done
  V=offerable
}

do_scan() {
  docker_up || { dcs_status "$V"; return 0; }
  local out id size name kib
  out="$(docker images --filter dangling=true --format '{{.ID}}{{"\t"}}{{.Size}}' </dev/null 2>&1)" || { dcs_status "unmeasured: docker images failed (${out%%$'\n'*})"; return 0; }
  while IFS="$TAB" read -r id size; do
    [ -n "$id" ] || continue
    kib="$(dcu_docker_kib "$size")" || kib=""
    dcs_item "image $id" docker "$kib" "$([ -n "$kib" ] && echo reported || echo unread)" "$IMAGE_WHY" "" "a dangling image, which no tag names" ""
  done <<< "$out"
  out="$(docker ps -a --filter status=exited --filter status=created --format '{{.ID}}{{"\t"}}{{.Names}}{{"\t"}}{{.Size}}' </dev/null 2>&1)" || { dcs_status "unmeasured: docker ps failed (${out%%$'\n'*})"; return 0; }
  while IFS="$TAB" read -r id name size; do
    [ -n "$id" ] || continue
    kib="$(dcu_docker_kib "${size%% *}")" || kib=""
    container_rule "$id"
    dcs_item "container $id" docker "$kib" "$([ -n "$kib" ] && echo reported || echo unread)" "$V" "" "a stopped container ($name)" ""
  done <<< "$out"
  out="$(docker system df --format '{{.Type}}|{{.Size}}' </dev/null 2>&1)" || { dcs_status "unmeasured: docker system df failed (${out%%$'\n'*})"; return 0; }
  size="$(printf '%s\n' "$out" | awk -F '|' '$1 == "Build Cache" && !f { print $2; f = 1 }')"
  kib="$(dcu_docker_kib "$size")" || kib=""
  if [ -n "$kib" ] && [ "$kib" -gt 0 ]; then
    dcs_item "builder cache" docker "$kib" reported "$CACHE_WHY" "" "Docker's build cache, which the next build fills again" ""
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
      [ "$out" = 0 ] && echo "$IMAGE_WHY" || echo "not offerable: a tag names it now" ;;
    container) container_rule "$ref"; echo "$V" ;;
    builder) [ "$ref" = cache ] && echo "$CACHE_WHY" || echo "not offerable: it is not a Docker target this category offers" ;;
  esac
}

case "${1:-}" in
  scan) do_scan ;;
  judge) do_judge "${2:-}" ;;
  *) echo "usage: docker.sh scan | docker.sh judge <target>" >&2; exit 2 ;;
esac
