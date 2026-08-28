# Resultado de QA do MVP CAN

Data: 2026-08-28  
Candidato: worktree de `main` baseado em `cd59c03`  
Decisão: **PASS WITH LIMITATIONS**

## Ambiente

- Linux 7.0.0-30-generic x86_64
- Python 3.12.3, uv 0.9.9
- Flutter 3.41.2, Dart 3.11.0
- `ip`, `cansend` e `candump` disponíveis
- nenhuma interface CAN/vcan disponível durante o teste

## Evidência

| Teste | Entrada/ação | Esperado | Observado | Status |
|---|---|---|---|---|
| Estado Git inicial | `git status --short --branch` | branch e mudanças visíveis, sem descarte | `main...origin/main`; mudanças do MVP rastreadas/untracked, sem conflito | PASS |
| Higiene do diff | `git diff --check` | sem whitespace errors | sem saída, exit 0 | PASS |
| Backend completo | `PYTEST_DISABLE_PLUGIN_AUTOLOAD=1 uv run pytest -q` | domínio, API, segurança e lifecycle verdes | 31 passed; 1 warning de depreciação TestClient/httpx | PASS |
| Compatibilidade unittest | `uv run python -m unittest discover -s tests -v` | pacote importável | 1 passed | PASS |
| REST/sessões/filtros | testes `test_api` | descoberta, create/get/delete, filtros e erros coerentes | contratos e problem JSON aprovados | PASS |
| WebSocket | testes `test_api` | hello/lotes v1, frames e fechamento válidos | contrato aprovado com `sequence` e counters | PASS |
| Segurança TX | testes de TX/CORS/config | físico off por padrão; token; rate 429; Origin/header restritos | casos negativos/positivos e preflight aprovados | PASS |
| Validação CAN/FD | testes de validação | limites SFF/EFF, hex e tamanhos DLC legais | limites e entradas inválidas aprovados | PASS |
| Timing | testes de timing | inter-arrival monotônico e fórmula documentada | wall-clock divergente não afetou intervalos; jitter aprovado | PASS |
| Lifecycle | testes de sessão | falha/close liberam adapter e acordam WS | cleanup, sentinel e boundary de filtro aprovados | PASS |
| Flutter analyze | `flutter analyze` | zero erros/lints | No issues found | PASS |
| Flutter unit/widget | `flutter test` | modelos, API, controller e fluxos UI verdes | 16 passed | PASS |
| Flutter Web release | `flutter build web --release` | artefato Web compilado | `build/web` gerado; Wasm dry-run aprovado | PASS |
| Configuração vcan | `bash scripts/setup-vcan.sh up vcan0`, sem sudo | criar e subir `vcan0` ou relatar limitação | `modprobe: Operation not permitted`; `vcan0` ausente | INCONCLUSIVE |
| TX→vcan→RX e filtros reais | `cansend`/`candump`/backend | reconciliar frames e filtros ponta a ponta | não executado porque `vcan0` não pôde ser criado | SKIP |
| CAN FD real | vcan/hardware FD | reconciliar frame FD real | não executado | SKIP |
| Stress/soak | burst, cliente lento, horas | medir drops/recursos no envelope definido | somente políticas/bounds e gaps foram testados com doubles | SKIP |

## Limitações e risco residual

- Os testes com adapters fake não provam SocketCAN real, filtros no kernel, ordering raw,
  eco TX, remoção de interface ou reconnect em `vcan`.
- Sem hardware/HIL não há evidência de arbitragem, bus-off, erros elétricos, bitrate,
  timestamp de hardware ou CAN FD físico.
- O build Web foi produzido, mas não houve execução end-to-end em navegador contra um
  backend ligado a SocketCAN.
- Não houve stress/soak representativo; “zero drop” não é afirmado.
- O warning TestClient/httpx é dívida de dependência, não falha funcional observada.
- Build Flutter Linux desktop não foi executado; o host informa ausência de clang/ninja.

## Condição para elevar a PASS sem limitações de integração

Em ambiente Linux autorizado, criar `vcan0`, capturar com `candump`, executar
TX externo→backend/WS/UI, TX backend→raw capture, ALL/um/múltiplos filtros, SFF/EFF,
burst conhecido, disconnect/reconnect e remoção da interface; reconciliar contagem,
ordem, ID, flags, DLC, payload, timestamps e counters. Remover `vcan0` ao final.
