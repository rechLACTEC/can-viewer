#!/usr/bin/env bash
# BUILD/SETUP: pode acessar registries e baixar artefatos. Não é necessário no RUN.
set -euo pipefail

usage() {
  cat <<'HELP'
Uso: ./scripts/setup.sh [--backend-only | --frontend-only] [--production]

Sem opções: prepara backend com dependências de teste e compila Flutter Web.
--backend-only   Prepara Python na arquitetura da máquina atual (use na Jetson).
--frontend-only  Compila Web no PC; transfira frontend/build/web inteiro à Jetson.
--production     Omite dependências Python de desenvolvimento/teste.

Requer uv/Python para backend e Flutter para frontend. Pode usar Internet.
Respeita uv.lock; pubspec.lock pode ser atualizado pela resolução compatível do Pub.
A execução posterior com scripts/start.sh não usa uv ou Flutter.
HELP
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"
target="all"
production=false
for argument in "$@"; do
  case "$argument" in
    --backend-only|--frontend-only)
      if [[ "$target" != all ]]; then
        printf 'Erro: selecione somente um alvo de preparação.\n' >&2
        exit 2
      fi
      target="${argument#--}"
      ;;
    --production) production=true ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Erro: opção desconhecida: %s\n' "$argument" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ "$target" != frontend-only ]]; then
  if ! command -v uv >/dev/null 2>&1; then
    printf 'Erro: uv não encontrado; instale-o durante a preparação do ambiente.\n' >&2
    exit 3
  fi
  dependency_group="--dev"
  if "$production"; then dependency_group="--no-dev"; fi
  printf 'Preparando backend com uv.lock (pode acessar Internet)...\n'
  (cd -- "$project_dir/backend"; UV_PROJECT_ENVIRONMENT="$project_dir/backend/.venv" uv sync --locked "$dependency_group")
  if [[ ! -x "$project_dir/backend/.venv/bin/python" ]]; then
    printf 'Erro: uv concluiu sem preparar %s.\n' "$project_dir/backend/.venv/bin/python" >&2
    exit 4
  fi
fi

if [[ "$target" != backend-only ]]; then
  flutter_bin="${CAN_VIEWER_FLUTTER_BIN:-$(command -v flutter 2>/dev/null || true)}"
  snap_flutter_sdk="${HOME:-}/snap/flutter/common/flutter/bin/flutter"
  if [[ "$flutter_bin" == /snap/bin/flutter && -x "$snap_flutter_sdk" ]]; then
    flutter_bin="$snap_flutter_sdk"
  fi
  if [[ -z "$flutter_bin" || ! -x "$flutter_bin" ]]; then
    printf 'Erro: Flutter não encontrado. Defina CAN_VIEWER_FLUTTER_BIN para o SDK no PC.\n' >&2
    exit 3
  fi
  printf 'Preparando build Web autocontido (pode acessar Internet)...\n'
  (
    cd -- "$project_dir/frontend"
    lockfile_hash_before=""
    if [[ -f pubspec.lock ]]; then
      lockfile_hash_before="$(sha256sum pubspec.lock | awk '{print $1}')"
    fi
    if ! "$flutter_bin" pub get; then
      printf 'Erro: o Flutter/Dart ou as dependências não atendem às constraints de frontend em pubspec.yaml.\n' >&2
      exit 4
    fi
    lockfile_hash_after=""
    if [[ -f pubspec.lock ]]; then
      lockfile_hash_after="$(sha256sum pubspec.lock | awk '{print $1}')"
    fi
    if [[ "$lockfile_hash_before" != "$lockfile_hash_after" ]]; then
      printf 'pubspec.lock atualizado pela resolução compatível do Flutter/Dart.\n'
    else
      printf 'pubspec.lock preservado; nenhuma atualização foi necessária.\n'
    fi
    "$flutter_bin" build web --release --no-pub \
      --no-web-resources-cdn \
      --dart-define=CAN_API_BASE_URL=
  )
fi
printf 'Preparação concluída. Para executar: ./scripts/start.sh\n'
