#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runtime_dir="$repo_root/.tmp/local-integration"
fault_dir="$runtime_dir/faults"
compose_env="$runtime_dir/compose.env"

fail() {
  printf 'local-up: %s\n' "$*" >&2
  exit 1
}

command -v docker >/dev/null 2>&1 || fail "docker is required"
command -v git >/dev/null 2>&1 || fail "git is required"
docker info >/dev/null 2>&1 || fail "Docker Desktop is not running"

allocate_loopback_port() {
  if command -v powershell.exe >/dev/null 2>&1; then
    powershell.exe -NoProfile -NonInteractive -Command '
      $listener = [System.Net.Sockets.TcpListener]::new(
        [System.Net.IPAddress]::Loopback, 0)
      $listener.Start()
      $port = $listener.LocalEndpoint.Port
      $listener.Stop()
      [Console]::Out.Write($port)
    ' | tr -d '\r\n'
    return
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
    return
  fi
  fail "PowerShell or Python 3 is required to allocate a loopback port"
}

head_version="$(git -C "$repo_root" rev-parse HEAD)"
[[ "$head_version" =~ ^[0-9a-f]{40}$ ]] || fail "could not resolve a full Git SHA"
if [[ -n "$(git -C "$repo_root" status --porcelain --untracked-files=normal)" ]]; then
  service_version="local-${head_version:0:12}-dirty"
else
  service_version="$head_version"
fi
local_app_a_port="$(allocate_loopback_port)"
[[ "$local_app_a_port" =~ ^[0-9]+$ ]] \
  && ((local_app_a_port >= 1024 && local_app_a_port <= 65535)) \
  || fail "could not allocate a valid loopback port"

mkdir -p "$fault_dir"
fault_tmp="$fault_dir/faults.json.tmp"
printf '%s\n' \
  '{' \
  '  "injected_latency_ms": 0,' \
  '  "injected_error_rate": 0.0' \
  '}' >"$fault_tmp"
mv -f "$fault_tmp" "$fault_dir/faults.json"

env_tmp="$compose_env.tmp"
printf 'SERVICE_VERSION=%s\nLOCAL_APP_A_PORT=%s\nLOCAL_FAULT_DIR=./.tmp/local-integration/faults\n' \
  "$service_version" "$local_app_a_port" >"$env_tmp"
mv -f "$env_tmp" "$compose_env"

export SERVICE_VERSION="$service_version"
export LOCAL_APP_A_PORT="$local_app_a_port"
export LOCAL_FAULT_DIR="./.tmp/local-integration/faults"
cd "$repo_root"

docker compose --env-file "$compose_env" config --quiet
docker compose --env-file "$compose_env" up \
  --detach \
  --build \
  --force-recreate \
  --remove-orphans \
  --wait \
  --wait-timeout 180

binding="$(docker compose --env-file "$compose_env" port app-a-gateway 8080 | tr -d '\r' | tail -n 1)"
[[ "$binding" == 127.0.0.1:* ]] || fail "App A did not receive a loopback-only host port"

printf 'Local stack is healthy.\n'
printf 'Service version: %s\n' "$service_version"
if [[ "$service_version" == local-*-dirty ]]; then
  printf 'Source state: uncommitted local review (not deployable)\n'
fi
printf 'App A endpoint: http://%s\n' "$binding"
