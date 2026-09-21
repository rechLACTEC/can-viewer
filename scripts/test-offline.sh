#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"

if [[ "${CAN_VIEWER_OFFLINE_NAMESPACE:-}" != "1" ]]; then
  if ! command -v unshare >/dev/null 2>&1; then
    printf 'Erro: unshare é necessário para isolar a rede durante este teste.\n' >&2
    exit 3
  fi
  exec unshare --user --map-root-user --net env \
    CAN_VIEWER_OFFLINE_NAMESPACE=1 \
    CAN_VIEWER_PROJECT_DIR="$project_dir" \
    bash "$script_dir/test-offline.sh"
fi

project_dir="${CAN_VIEWER_PROJECT_DIR:?diretório do projeto ausente}"
chrome_bin="${CAN_VIEWER_CHROME_BIN:-}"
if [[ -z "$chrome_bin" ]]; then
  chrome_bin="$(command -v google-chrome 2>/dev/null || command -v chromium 2>/dev/null || true)"
fi
if [[ -z "$chrome_bin" || ! -x "$chrome_bin" ]]; then
  printf 'Erro: Chrome/Chromium não encontrado; use CAN_VIEWER_CHROME_BIN.\n' >&2
  exit 3
fi

if [[ ! -f "$project_dir/frontend/build/web/index.html" ]]; then
  printf 'Erro: build Web ausente. Execute ./scripts/setup.sh --frontend-only antes do teste.\n' >&2
  exit 4
fi
if [[ ! -x "$project_dir/backend/.venv/bin/python" ]]; then
  printf 'Erro: backend não preparado. Execute ./scripts/setup.sh --backend-only antes do teste.\n' >&2
  exit 4
fi

ip link set lo up
ip link add dev vcan0 type vcan
ip link set dev vcan0 up

test_root="$(mktemp -d -t can-viewer-offline-test.XXXXXXXX)"
backend_pid=""
cleanup() {
  if [[ -n "$backend_pid" ]] && kill -0 "$backend_pid" 2>/dev/null; then
    kill "$backend_pid" 2>/dev/null || true
    wait "$backend_pid" 2>/dev/null || true
  fi
  rm -rf -- "$test_root"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for run in 1 2; do
  log_path="$test_root/backend-$run.log"
  env \
    CAN_VIEWER_HOST=127.0.0.1 \
    CAN_VIEWER_BACKEND_PORT=8000 \
    CAN_MONITOR_RECORDING_DIRECTORY="$test_root/recordings-$run" \
    "$project_dir/scripts/start.sh" >"$log_path" 2>&1 &
  backend_pid="$!"

  if ! "$project_dir/backend/.venv/bin/python" \
    "$project_dir/scripts/check_offline.py" \
    --chrome "$chrome_bin" \
    --debugger-port "$((9221 + run))"; then
    cat "$log_path" >&2
    exit 1
  fi

  kill "$backend_pid"
  wait "$backend_pid" 2>/dev/null || true
  backend_pid=""
  printf 'reinício offline %d/2 aprovado\n' "$run"
done

if ip -json route show | grep -q '"dst":"default"'; then
  printf 'Erro: o namespace de teste possuía rota default.\n' >&2
  exit 1
fi

printf 'PASS: dois inícios, browser limpo, REST, WebSocket e vcan sem rota de Internet.\n'
