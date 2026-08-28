#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Uso:
  bash scripts/setup-vcan.sh check [interface]
  bash scripts/setup-vcan.sh up [interface]
  bash scripts/setup-vcan.sh down [interface]

O script não executa sudo. Se a operação exigir privilégio, execute-o explicitamente
com a conta/autorização adequada, por exemplo:
  sudo bash scripts/setup-vcan.sh up vcan0

`down` remove somente uma interface virtual cujo nome foi fornecido explicitamente.
EOF
}

action="${1:-check}"
interface_name="${2:-vcan0}"

if [[ ! "$interface_name" =~ ^vcan[0-9]+$ ]]; then
  printf 'Erro: interface deve seguir o formato vcanN (recebido: %s).\n' "$interface_name" >&2
  exit 2
fi

if ! command -v ip >/dev/null 2>&1; then
  printf 'Erro: comando ip não encontrado. Instale iproute2 pelo processo do sistema.\n' >&2
  exit 3
fi

show_status() {
  if ip link show dev "$interface_name" >/dev/null 2>&1; then
    ip -details link show dev "$interface_name"
  else
    printf '%s não existe.\n' "$interface_name"
    return 1
  fi
}

case "$action" in
  check)
    show_status
    ;;
  up)
    if ip link show dev "$interface_name" >/dev/null 2>&1; then
      link_type="$(ip -details link show dev "$interface_name")"
      if [[ "$link_type" != *"vcan"* ]]; then
        printf 'Erro: %s já existe e não foi confirmada como vcan.\n' "$interface_name" >&2
        exit 4
      fi
    else
      if command -v modprobe >/dev/null 2>&1; then
        modprobe vcan
      fi
      ip link add dev "$interface_name" type vcan
    fi
    ip link set dev "$interface_name" up
    show_status
    ;;
  down)
    if ! ip link show dev "$interface_name" >/dev/null 2>&1; then
      printf '%s já está ausente; nada a remover.\n' "$interface_name"
      exit 0
    fi
    link_type="$(ip -details link show dev "$interface_name")"
    if [[ "$link_type" != *"vcan"* ]]; then
      printf 'Erro: recusa em remover %s porque ela não foi confirmada como vcan.\n' "$interface_name" >&2
      exit 4
    fi
    ip link delete dev "$interface_name"
    printf '%s removida.\n' "$interface_name"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
