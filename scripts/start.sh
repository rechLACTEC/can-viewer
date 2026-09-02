#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"
backend_dir="$project_dir/backend"
frontend_dir="$project_dir/frontend"

backend_port="${CAN_VIEWER_BACKEND_PORT:-8000}"
frontend_port="${CAN_VIEWER_FRONTEND_PORT:-5173}"
recording_dir="${CAN_MONITOR_RECORDING_DIRECTORY:-$project_dir/recordings}"

detect_lan_ip() {
  local detected=""

  if command -v ip >/dev/null 2>&1; then
    detected="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}')"
  fi
  if [[ -z "$detected" ]] && command -v hostname >/dev/null 2>&1; then
    detected="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi

  printf '%s' "$detected"
}

lan_ip="${CAN_VIEWER_LAN_IP:-$(detect_lan_ip)}"

if [[ -z "$lan_ip" ]]; then
  printf 'Erro: não foi possível detectar o IP da rede local.\n' >&2
  printf 'Informe-o manualmente: CAN_VIEWER_LAN_IP=192.168.1.10 ./scripts/start.sh\n' >&2
  exit 2
fi

if [[ ! "$backend_port" =~ ^[0-9]+$ ]] || ((backend_port < 1 || backend_port > 65535)); then
  printf 'Erro: porta inválida para o backend: %s\n' "$backend_port" >&2
  exit 2
fi
if [[ ! "$frontend_port" =~ ^[0-9]+$ ]] || ((frontend_port < 1 || frontend_port > 65535)); then
  printf 'Erro: porta inválida para o frontend: %s\n' "$frontend_port" >&2
  exit 2
fi

for command_name in uv flutter; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'Erro: comando obrigatório não encontrado: %s\n' "$command_name" >&2
    exit 3
  fi
done

backend_pid=""
frontend_pid=""

cleanup() {
  trap - EXIT INT TERM
  printf '\nEncerrando CAN Viewer...\n'
  if [[ -n "$frontend_pid" ]] && kill -0 "$frontend_pid" 2>/dev/null; then
    kill "$frontend_pid" 2>/dev/null || true
  fi
  if [[ -n "$backend_pid" ]] && kill -0 "$backend_pid" 2>/dev/null; then
    kill "$backend_pid" 2>/dev/null || true
  fi
  [[ -z "$frontend_pid" ]] || wait "$frontend_pid" 2>/dev/null || true
  [[ -z "$backend_pid" ]] || wait "$backend_pid" 2>/dev/null || true
}

trap cleanup EXIT INT TERM

mkdir -p -- "$recording_dir"

printf 'Preparando dependências do backend...\n'
(
  cd -- "$backend_dir"
  uv sync --dev
)

printf 'Preparando dependências do frontend...\n'
(
  cd -- "$frontend_dir"
  flutter pub get
)

api_url="http://$lan_ip:$backend_port"
app_url="http://$lan_ip:$frontend_port"
cors_origins="$app_url,http://localhost:$frontend_port,http://127.0.0.1:$frontend_port"

printf '\nIniciando backend em %s...\n' "$api_url"
(
  cd -- "$backend_dir"
  exec env \
    CAN_MONITOR_CORS_ORIGINS="$cors_origins" \
    CAN_MONITOR_RECORDING_DIRECTORY="$recording_dir" \
    uv run uvicorn can_monitor.main:app \
      --host 0.0.0.0 \
      --port "$backend_port"
) &
backend_pid="$!"

printf 'Iniciando frontend em %s...\n' "$app_url"
(
  cd -- "$frontend_dir"
  exec flutter run -d web-server \
    --web-hostname 0.0.0.0 \
    --web-port "$frontend_port" \
    --dart-define="CAN_API_BASE_URL=$api_url"
) &
frontend_pid="$!"

printf '\nCAN Viewer disponível na rede local:\n  %s\n' "$app_url"
printf 'Pressione Ctrl+C para encerrar backend e frontend.\n\n'

wait -n "$backend_pid" "$frontend_pid"
