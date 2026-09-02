# CAN Monitor Backend

Backend FastAPI para descoberta, aquisição, análise e transmissão manual/cíclica de frames via
`python-can`/SocketCAN. O navegador nunca acessa o barramento diretamente.

## Execução

```bash
uv sync --dev
uv run uvicorn can_monitor.main:app --reload --host 127.0.0.1 --port 8000
```

Para desenvolvimento Linux sem hardware, crie `vcan0` explicitamente:

```bash
../scripts/setup-vcan.sh up vcan0
```

O script requer `iproute2` e privilégios para carregar/criar a interface. Ele é
idempotente e não remove interfaces existentes.

## API v1

- `GET /api/v1/health`
- `GET /api/v1/can/interfaces`
- `GET /api/v1/can/tx-enabled`
- `PUT /api/v1/can/tx-enabled`
- `POST /api/v1/can/sessions`
- `GET /api/v1/can/sessions/{id}`
- `DELETE /api/v1/can/sessions/{id}`
- `PUT /api/v1/can/sessions/{id}/filters`
- `GET /api/v1/can/sessions/{id}/timing`
- `POST /api/v1/can/sessions/{id}/frames`
- `POST /api/v1/can/sessions/{id}/transmissions`
- `POST /api/v1/can/sessions/{id}/transmissions/send-once`
- `POST /api/v1/can/sessions/{id}/transmissions/{plan_id}/{start|pause|resume|stop}`
- `GET /api/v1/can/sessions/{id}/transmissions/{plan_id}`
- `POST /api/v1/can/sessions/{id}/recordings`
- `POST /api/v1/can/sessions/{id}/recordings/{recording_id}/pause`
- `POST /api/v1/can/sessions/{id}/recordings/{recording_id}/resume`
- `POST /api/v1/can/sessions/{id}/recordings/{recording_id}/stop`
- `GET /api/v1/can/sessions/{id}/recordings/{recording_id}`
- `GET /api/v1/can/recordings/{recording_id}/download`
- `WS /api/v1/can/sessions/{id}/stream`

Somente uma sessão CAN ativa é suportada no MVP. O WebSocket envia primeiro um
evento `hello` e depois lotes `{ "type": "frames", "frames": [...] }`. Ambos os
envelopes contêm `"version": 1`. Conexões WebSocket com `Origin` são aceitas
somente quando o valor pertence exatamente a `CAN_MONITOR_CORS_ORIGINS`.
`timestamp_ns` é serializado como string decimal para não perder precisão em
clientes JavaScript.

Exemplo de conexão:

```json
{
  "interface": "vcan0",
  "fd": false,
  "filter": {"mode": "filtered", "ids": [
    {"can_id": 291, "is_extended_id": false}
  ]}
}
```

Em `all`, `ids` deve ser vazio; em `filtered`, deve conter pelo menos um ID. IDs
standard e extended são distintos e os filtros são encaminhados ao SocketCAN.

## Segurança de transmissão

Transmissão em interfaces físicas é desabilitada por padrão. `vcan` permanece
habilitado para desenvolvimento. Para habilitar uma interface física em ambiente
expressamente autorizado:

```bash
CAN_MONITOR_TX_ENABLED=true uv run uvicorn can_monitor.main:app
```

Esse valor define apenas o estado inicial. Durante a execução, `GET` e `PUT`
`/api/v1/can/tx-enabled` consultam e alteram o controle de transmissão física.
Ao desabilitar, o backend bloqueia novos envios e encerra o plano cíclico físico
ativo sem afetar aquisição, WebSocket ou gravação. `vcan` é controlado
separadamente, mas todas as interfaces respeitam o rate limit. `bus.send()` confirma
submissão ao driver, não recepção por outro nó. O eco local é transmitido no stream
como direção `tx` quando suportado.

## Configuração

- `CAN_MONITOR_TX_ENABLED=false`
- `CAN_MONITOR_VIRTUAL_TX_ENABLED=true`
- `CAN_MONITOR_TX_RATE_LIMIT_PER_SECOND=10`
- `CAN_MONITOR_ACQUISITION_QUEUE_SIZE=8192`
- `CAN_MONITOR_TRACE_BUFFER_SIZE=10000`
- `CAN_MONITOR_CLIENT_QUEUE_SIZE=2048`
- `CAN_MONITOR_WS_BATCH_SIZE=200`
- `CAN_MONITOR_WS_BATCH_INTERVAL_MS=20`
- `CAN_MONITOR_RECORDING_DIRECTORY=/data/recordings`
- `CAN_MONITOR_RECORDING_QUEUE_SIZE=8192`
- `CAN_MONITOR_RECORDING_MAX_BYTES=268435456`
- `CAN_MONITOR_CORS_ORIGINS=http://localhost:3000,http://localhost:5173,http://localhost:8080`
- `CAN_MONITOR_LOG_LEVEL=INFO`

Filas e buffers são limitados. Em sobrecarga, frames antigos são descartados para
preservar frescor e os contadores `adapter_dropped_frames` e
`stream_dropped_frames` tornam a perda do pipeline observável.

## Gravação TRC

A gravação usa uma fila limitada e um worker dedicado, portanto escrita em disco não
bloqueia o caminho de aquisição. O arquivo permanece com extensão `.trc.part` até a
fila ser drenada, `TRCWriter.stop()` ser executado e a leitura por `TRCReader` ser
validada. Somente então ele é renomeado para `.trc` e liberado para download.

Este MVP grava CAN clássico STD/EXT e RX/TX. Sessões CAN FD são recusadas no início.
Frames FD, RTR ou Error eventualmente observados em uma sessão clássica incrementam
contadores explícitos e degradam a gravação, pois o `TRCWriter` do python-can 4.6.1
não os serializa. Pausar afeta apenas a gravação; aquisição, estatísticas, ring buffer
e WebSocket continuam ativos.

Em Docker, monte um volume persistente em `/data/recordings`, por exemplo
`./recordings:/data/recordings`. O repositório não possui atualmente um Compose
executável; por isso nenhuma configuração de rede ou capability foi criada ou alterada.

A fonte é o fluxo normalizado da sessão antes do ring buffer e do WebSocket. Os filtros
configurados são encaminhados ao SocketCAN/python-can e podem impedir que frames cheguem
ao processo; a gravação não abre um segundo socket para contornar essa limitação.

## Timestamps e perda

SocketCAN fornece `SO_TIMESTAMPNS`, mas a API pública do `python-can` converte o
`timespec` para segundos epoch em `float`. O backend devolve o melhor wall-clock
recuperável em nanossegundos, identificado como
`kernel_software_realtime_float_converted`, apenas para apresentação/correlação.
Intervalos, frequência e jitter são calculados exclusivamente com
`ingress_monotonic_ns`, que não sofre saltos do wall-clock, mas inclui latência de
scheduling entre a captura no kernel e o ingresso na aplicação.

A revisão de filtros possui boundary consistente na aplicação: frames processados
antes da conclusão de `set_filters` mantêm a revisão anterior; frames processados
depois recebem a nova revisão. Frames que já estavam nas filas do kernel/adapter
podem cruzar essa janela, portanto a revisão não representa uma fronteira física no
barramento.

As estatísticas não inventam percentual de perda CAN. Sem contador de payload ou
periodicidade conhecida, apenas frames, intervalos, frequência, desvio padrão,
jitter e descontinuidades do relógio são observáveis. Jitter é definido como:

```text
mean(abs(interarrival[i] - interarrival[i-1]))
```

## Testes

```bash
PYTEST_DISABLE_PLUGIN_AUTOLOAD=1 uv run pytest -q
```

A variável evita que plugins globais do host contaminem o ambiente de teste. Os
testes cobrem domínio, filtros, descoberta, timing, validação, REST, segurança TX e
WebSocket. Testes HIL continuam necessários para bus-off, erros físicos, arbitragem
e timestamp de hardware.
