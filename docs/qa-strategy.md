# Estratégia de QA, integração e stress

## Modelo de risco

| Prioridade | Risco | Evidência mínima |
|---|---|---|
| Crítica | TX remoto/acidental ou frame inválido em equipamento real | TX off por padrão, validação server-side, opt-in, rate limit e teste negativo |
| Crítica | perda, duplicação, corrupção ou reordenação silenciosa | frames golden e contagens reconciliadas entre `candump`, backend e WebSocket |
| Alta | filtros SFF/EFF incorretos | matriz positiva/negativa com IDs limites, sobrepostos e troca sob tráfego |
| Alta | tasks/socket vazando em disconnect/reconnect | testes de lifecycle, cancelamento e repetição com recursos observados |
| Alta | cliente lento bloqueando aquisição ou memória sem limite | carga com consumidor lento, counters de overflow e memória limitada |
| Média | timestamp/jitter enganoso | clock injetável, fórmula documentada, fonte/precisão e tolerâncias registradas |
| Média | UI dispara TX por engano ou mascara estado | widget/integration tests de confirmação, estados, erros e acessibilidade textual |

## Camadas de teste

### Backend unitário

- CAN ID Standard: `0`, `0x7FF` e fora dos limites; Extended: `0`, `0x1FFFFFFF`
  e fora dos limites.
- Hex com espaços/case, vazio, número ímpar e caractere inválido; limites de 8/64 bytes
  e combinações incompatíveis de flags.
- `ALL` versus `FILTERED`, lista vazia, múltiplos IDs, duplicados e distinção SFF/EFF.
- Modelo e serialização, HEX e BIN por byte, direção, erro/RTR/CAN FD.
- Timing com clock determinístico: zero/uma/N amostras, média, extremos, desvio-padrão,
  frequência, gap esperado e ausência de falso `packet loss`.
- Falhas de open/send/recv/close, cancelamento e cleanup idempotente com doubles.

### API e WebSocket

- Schemas e códigos de erro; interface desconhecida; conflitos de estado.
- Criar/consultar/filtrar/transmitir/excluir sessão, nominal e inválido.
- WS frame/stat/state/error, disconnect abrupto, reconexão e cliente lento.
- Origem permitida/negada, TX desabilitado, limite de entrada/taxa/fila.

### Integração SocketCAN com `vcan`

Pré-condição: operador criou `vcan0` com `scripts/setup-vcan.sh up vcan0`.

1. Iniciar captura independente (`candump -L vcan0`) e backend.
2. Enviar frames golden com `cansend`: SFF, EFF, payloads 0/1/8 bytes.
3. Reconciliar ID, flags, DLC, bytes, ordem e contagem no raw capture, backend e WS.
4. Repetir em ALL, um filtro, múltiplos filtros e tráfego negativo.
5. Fazer TX backend → `vcan` → `candump` e confirmar evento TX/RX conforme semântica.
6. Trocar filtros sob tráfego e verificar falsos positivos/negativos e gaps sinalizados.
7. Exercitar burst conhecido, remoção da interface, erro, disconnect e reconnect.

Resultado `vcan` não cobre arbitragem, elétrica, transceiver, error counters, bus-off real,
timestamp de hardware nem capacidade CAN FD física.

### Flutter

- Unitários: modelos, parser do contrato, formatadores HEX/BIN e validadores de TX.
- Widgets: seletor/reload, estados de conexão, ALL/Filtered e chips, tabela, RX/TX,
  Standard/Extended, CAN/FD, pause UI, stale/error, formulário e confirmação de TX.
- Layouts estreito/largo, teclado/foco e indicação não dependente apenas de cor.
- Integração Web: fluxo selecionar→conectar→receber→filtrar→transmitir→desconectar
  contra backend controlado; não depender apenas de golden tests.

## Carga e stress

O MVP deve documentar, e executar quando automatizado:

- fases steady, burst, overload e recovery com seeds e N conhecidos;
- execução prolongada e reconexões repetidas;
- cliente Flutter/WS lento ou desconectado;
- interface removida, backend reiniciado e frontend reconectado;
- memória, CPU, filas, drops, contagens e latência nos pontos definidos.

Não há meta universal de frames/s neste estágio. Cada relatório informa ambiente, carga,
duração, limites e resultado observado. “Zero drop” vale somente para esse envelope.

## Evidência e gate

Cada caso registra:

```text
test_id | HEAD/diff | requisito/risco | ambiente/versões | precondição
entrada/seed/raw frame | oracle/tolerância | observado | artefatos | status | limitação
```

`SKIP` por falta de privilégio/interface não é `PASS`. Aceitação pode ser “passou com
limitações” em `vcan`, mas não estende conclusões a hardware/HIL. Bloqueiam a entrega:
TX inseguro, corrupção/drop silencioso, filtro incorreto, recurso sem limite ou ausência
de evidência ponta a ponta para os fluxos essenciais.

## Checklist da revisão de código

- [ ] Adapter, aquisição, domínio, análise e transporte têm fronteiras reais, sem camadas vazias.
- [ ] IDs/DLC/flags são validados no servidor e filtros distinguem SFF/EFF.
- [ ] Operações bloqueantes não bloqueiam o event loop; tasks têm ownership/cancelamento.
- [ ] Disconnect/reconnect não vaza bus, listener, socket ou subscription.
- [ ] Filas/ring buffers são limitados; overflow é observável.
- [ ] Cliente WS lento não bloqueia aquisição nem outros clientes.
- [ ] Timestamp mantém origem/precisão; intervalos usam clock apropriado.
- [ ] Jitter e perda não fazem alegações maiores que os oracles.
- [ ] TX usa defaults seguros, limites e erros auditáveis.
- [ ] Testes cobrem nominal, fronteira, erro, recovery e concorrência proporcionalmente.
- [ ] Documentação e contratos correspondem ao código e lockfiles.
- [ ] `git diff --check`, status e arquivos inesperados são revisados antes da entrega.
