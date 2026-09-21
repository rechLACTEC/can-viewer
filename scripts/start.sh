#!/usr/bin/env bash
# RUN: inicia somente artefatos e dependências já preparados, sem ferramentas de build.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"
backend_port="${CAN_VIEWER_BACKEND_PORT:-8000}"
bind_host="${CAN_VIEWER_HOST:-0.0.0.0}"
python_bin="${CAN_VIEWER_PYTHON:-$project_dir/backend/.venv/bin/python}"
frontend_dir="${CAN_MONITOR_FRONTEND_DIRECTORY:-$project_dir/frontend/build/web}"
recording_dir="${CAN_MONITOR_RECORDING_DIRECTORY:-$project_dir/recordings}"

if [[ ! "$backend_port" =~ ^[0-9]{1,5}$ ]] || ((10#$backend_port < 1 || 10#$backend_port > 65535)); then
  printf 'Erro: porta inválida: %s\n' "$backend_port" >&2
  exit 2
fi
if [[ ! -x "$python_bin" ]]; then
  printf 'Erro: Python preparado não encontrado em %s.\nExecute scripts/setup.sh --backend-only na Jetson antes do uso offline.\n' "$python_bin" >&2
  exit 3
fi
required_artifacts=(
  index.html
  flutter.js
  flutter_bootstrap.js
  main.dart.js
  manifest.json
  favicon.png
  canvaskit/canvaskit.js
  canvaskit/canvaskit.wasm
  assets/FontManifest.json
  assets/assets/fonts/Roboto-Regular.ttf
  assets/assets/fonts/Roboto-Medium.ttf
  assets/assets/fonts/Roboto-Bold.ttf
  assets/assets/fonts/NotoSansSymbols2-Regular.ttf
)
for artifact in "${required_artifacts[@]}"; do
  if [[ ! -f "$frontend_dir/$artifact" ]]; then
    printf 'Erro: build Web ausente/incompleto em %s.\nExecute scripts/setup.sh --frontend-only no PC e transfira frontend/build/web para a Jetson.\n' "$frontend_dir" >&2
    exit 3
  fi
done
if ! "$python_bin" -c 'import can, fastapi, uvicorn' >/dev/null 2>&1; then
  printf 'Erro: dependências Python ausentes. Prepare o backend antes do uso offline.\n' >&2
  exit 3
fi

mkdir -p -- "$recording_dir"
printf 'CAN Viewer: http://<IP_DA_JETSON>:%s (bind %s)\nPressione Ctrl+C para encerrar.\n' "$backend_port" "$bind_host"
exec env \
  CAN_MONITOR_FRONTEND_DIRECTORY="$frontend_dir" \
  CAN_MONITOR_RECORDING_DIRECTORY="$recording_dir" \
  "$python_bin" -m uvicorn can_monitor.main:app \
  --app-dir "$project_dir/backend/src" \
  --host "$bind_host" --port "$backend_port"
