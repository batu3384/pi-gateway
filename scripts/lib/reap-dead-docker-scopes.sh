# Dead docker cgroup leftovers (host-network nginx/gitea). Live container spared.
# docker inspect fail + daemon down → hiçbir şeye dokunma.
# shellcheck shell=bash
reap_dead_docker_scopes() {
  local scope cid pid alive docker_bin err
  docker_bin="/usr/bin/docker"
  [[ -x "$docker_bin" ]] || docker_bin="$(command -v docker 2>/dev/null || true)"
  [[ -n "$docker_bin" ]] || return 0
  "$docker_bin" info >/dev/null 2>&1 || return 0
  [[ -d /sys/fs/cgroup/system.slice ]] || return 0
  shopt -s nullglob
  for scope in /sys/fs/cgroup/system.slice/docker-*.scope; do
    cid="$(basename "$scope")"
    cid="${cid#docker-}"
    cid="${cid%.scope}"
    err="$(timeout 15 "$docker_bin" inspect "$cid" 2>&1 >/dev/null)" && continue
    printf '%s' "$err" | grep -qiE 'no such (object|container)' || continue
    "$docker_bin" info >/dev/null 2>&1 || { shopt -u nullglob; return 0; }
    [[ -f "$scope/cgroup.procs" ]] || continue
    alive=0
    while read -r pid; do
      [[ -n "$pid" ]] || continue
      if kill -0 "$pid" 2>/dev/null || sudo kill -0 "$pid" 2>/dev/null; then
        alive=1
        break
      fi
    done < "$scope/cgroup.procs"
    [[ "$alive" -eq 1 ]] || continue
    echo "[reap-docker] stale scope ${cid:0:12}" >&2
    while read -r pid; do
      [[ -n "$pid" ]] || continue
      kill -0 "$pid" 2>/dev/null || sudo kill -0 "$pid" 2>/dev/null || continue
      kill "$pid" 2>/dev/null || sudo kill "$pid" 2>/dev/null || true
    done < "$scope/cgroup.procs"
    sleep 0.2
    while read -r pid; do
      [[ -n "$pid" ]] || continue
      kill -0 "$pid" 2>/dev/null || sudo kill -0 "$pid" 2>/dev/null || continue
      kill -9 "$pid" 2>/dev/null || sudo kill -9 "$pid" 2>/dev/null || true
    done < "$scope/cgroup.procs"
  done
  shopt -u nullglob
  return 0
}
