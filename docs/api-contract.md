# Contrato HTTP e WebSocket do MVP

O Flutter usa JSON UTF-8 sob `/api/v1`. IDs são inteiros; timestamps em nanossegundos e contadores potencialmente grandes são strings decimais para permanecerem exatos no Flutter Web. Valores desconhecidos são `null`, nunca estimados.

## REST

### `GET /api/v1/health`

Retorna `{"status":"ok"}`.

### `GET /api/v1/can/interfaces`

```json
{
  "interfaces": [{
    "name": "vcan0",
    "channel": "vcan0",
    "kind": "vcan",
    "administratively_up": true,
    "operational_state": "unknown",
    "can_state": null,
    "bitrate": null,
    "data_bitrate": null,
    "fd_enabled": false,
    "fd_capable": null,
    "mtu": 16
  }]
}
```

### `POST /api/v1/can/sessions`

```json
{
  "interface": "vcan0",
  "fd": false,
  "filter": {
    "mode": "filtered",
    "ids": [{"can_id": 291, "is_extended_id": false}]
  }
}
```

`all` exige `ids: []`; `filtered` exige uma lista não vazia e sem duplicatas. A interface deve estar na descoberta atual. O MVP permite uma sessão ativa por processo.

A resposta `201` contém `id`, `interface`, `interface_kind`, `fd`, `state`, filtro e revisão, contagens de frames/drop e `filter_placement`. Este último permanece `unknown` porque o `python-can` pode cair para filtragem em software sem expor confirmação pública confiável.

### Estado, encerramento, filtro e timing

```text
GET    /api/v1/can/sessions/{session_id}
DELETE /api/v1/can/sessions/{session_id}
PUT    /api/v1/can/sessions/{session_id}/filters
GET    /api/v1/can/sessions/{session_id}/timing
```

O corpo de `PUT /filters` é o próprio objeto de filtro, sem wrapper:

```json
{"mode":"filtered","ids":[{"can_id":291,"is_extended_id":false}]}
```

O endpoint de timing retorna `{"statistics":[...]}`. Cada item identifica interface, ID, STD/EXT e CAN/CAN FD e inclui contagem, último/médio/mínimo/máximo intervalo, desvio padrão amostral, frequência, descontinuidades do relógio e:

```text
jitter = mean(abs(interarrival[i] - interarrival[i-1]))
```

### `POST /api/v1/can/sessions/{session_id}/frames`

```json
{
  "can_id": 291,
  "is_extended_id": false,
  "is_fd": false,
  "data_hex": "010AFF200035"
}
```

O destino é a interface da sessão. O backend valida ID, paridade hexadecimal e limite
de 8 bytes para CAN clássico. Em CAN FD os tamanhos aceitos são
`0..8, 12, 16, 20, 24, 32, 48, 64` bytes. A resposta `202` significa submissão ao
driver, não recepção por outro nó.

TX virtual é permitido por padrão. TX físico exige simultaneamente
`CAN_MONITOR_TX_ENABLED=true`, `CAN_MONITOR_PHYSICAL_TX_TOKEN` com pelo menos 16
caracteres e o mesmo valor no header `X-CAN-TX-Token`. O limite padrão é 10 envios por
segundo por sessão, configurável por `CAN_MONITOR_TX_RATE_LIMIT_PER_SECOND`; excedê-lo
retorna `429`. O token nunca integra payloads ou logs.

## Erros REST

Erros seguem `application/problem+json`:

```json
{
  "type": "urn:can-monitor:problem:validation_error",
  "title": "Request validation failed",
  "status": 422,
  "detail": "entrada inválida",
  "instance": "/api/v1/can/sessions/example/frames",
  "code": "validation_error"
}
```

## WebSocket

`WS /api/v1/can/sessions/{session_id}/stream` envia inicialmente:

```json
{"version":1,"type":"hello","session":{"id":"...","state":"connected","interface":"vcan0"}}
```

Em seguida envia lotes limitados:

```json
{
  "version": 1,
  "type": "frames",
  "frames": [{
    "sequence": 42,
    "timestamp_ns": "1770000000123456789",
    "timestamp_source": "kernel_software_realtime_float_converted",
    "ingress_monotonic_ns": "842300012345",
    "interface": "vcan0",
    "can_id": 291,
    "is_extended_id": false,
    "is_fd": false,
    "dlc": 6,
    "data_hex": "010AFF200035",
    "direction": "rx",
    "is_error_frame": false,
    "is_remote_frame": false,
    "bitrate_switch": null,
    "error_state_indicator": null,
    "filter_revision": 1
  }],
  "stream_dropped_frames": 0,
  "adapter_dropped_frames": 0
}
```

`sequence` e os contadores de drop descrevem o pipeline, não o protocolo CAN e não provam perda no barramento. O timestamp é o melhor valor recuperável depois que o `python-can` converte o `timespec` do kernel para `float`; a string não recupera precisão já perdida. O relógio monotônico é diagnóstico de ingresso e não substitui o horário de captura.

O cliente deve ignorar campos adicionais. Sessão inexistente fecha com código `4404`; encerrar a sessão fecha o stream. Filas por cliente são limitadas e cliente lento não bloqueia aquisição/análise.

## Segurança do transporte

- CORS/origin não são autenticação.
- O servidor faz bind em loopback nos comandos documentados.
- Exposição remota com TX físico exige TLS e autenticação/autorização adequadas ao
  ambiente; o token compartilhado do laboratório é somente um controle mínimo do MVP.
- A UI nunca repete automaticamente uma transmissão.
