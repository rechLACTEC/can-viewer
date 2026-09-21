#!/usr/bin/env bash
# DEV: ferramentas, resolução de dependências e servidor Flutter; pode usar Internet.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"
backend_port="${CAN_VIEWER_BACKEND_PORT:-8000}"
frontend_port="${CAN_VIEWER_FRONTEND_PORT:-5173}"
lan_ip="${CAN_VIEWER_LAN_IP:-127.0.0.1}"
recording_dir="${CAN_MONITOR_RECORDING_DIRECTORY:-$project_dir/recordings}"
flutter_bin="${CAN_VIEWER_FLUTTER_BIN:-$(command -v flutter 2>/dev/null || true)}"
snap_flutter_sdk="${HOME:-}/snap/flutter/common/flutter/bin/flutter"
if [[ "$flutter_bin" == /snap/bin/flutter && -x "$snap_flutter_sdk" ]]; then
  flutter_bin="$snap_flutter_sdk"
fi
for port in "$backend_port" "$frontend_port"; do
  if [[ ! "$port" =~ ^[0-9]{1,5}$ ]] || ((10#$port < 1 || 10#$port > 65535)); then
    printf 'Erro: porta inválida: %s\n' "$port" >&2
    exit 2
  fi
done
if ! command -v uv >/dev/null 2>&1 || [[ -z "$flutter_bin" || ! -x "$flutter_bin" ]]; then
  printf 'Erro: o modo DEV requer uv e Flutter. Defina CAN_VIEWER_FLUTTER_BIN se necessário.\n' >&2
  exit 3
fi

backend_pid=""
frontend_pid=""
cleanup() {
  trap - EXIT INT TERM
  for pid in "$frontend_pid" "$backend_pid"; do
    if [[ -n "$pid" ]]; then kill "$pid" 2>/dev/null || true; fi
  done
  [[ -z "$frontend_pid" ]] || wait "$frontend_pid" 2>/dev/null || true
  [[ -z "$backend_pid" ]] || wait "$backend_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

printf 'Modo DEV: preparando dependências; esta etapa pode acessar Internet.\n'
(cd -- "$project_dir/backend"; uv sync --locked --dev)
(cd -- "$project_dir/frontend"; "$flutter_bin" pub get --enforce-lockfile)
mkdir -p -- "$recording_dir"
api_url="http://$lan_ip:$backend_port"
app_url="http://$lan_ip:$frontend_port"
(
  exec env \
    CAN_MONITOR_CORS_ORIGINS="$app_url,http://localhost:$frontend_port,http://127.0.0.1:$frontend_port" \
    CAN_MONITOR_FRONTEND_DIRECTORY= \
    CAN_MONITOR_RECORDING_DIRECTORY="$recording_dir" \
    "$project_dir/backend/.venv/bin/python" -m uvicorn can_monitor.main:app \
    --app-dir "$project_dir/backend/src" --host 0.0.0.0 --port "$backend_port" --reload \
    --reload-dir "$project_dir/backend/src"
) &
backend_pid="$!"
(
  cd -- "$project_dir/frontend"
  exec "$flutter_bin" run --no-pub -d web-server \
    --web-hostname 0.0.0.0 --web-port "$frontend_port" \
    --dart-define="CAN_API_BASE_URL=$api_url"
) &
frontend_pid="$!"
printf 'DEV: %s (API %s). Ctrl+C encerra os dois processos.\nPara acesso LAN, defina CAN_VIEWER_LAN_IP com o IP deste computador.\n' "$app_url" "$api_url"
wait -n "$backend_pid" "$frontend_pid"
