# Registro da reunião técnica do MVP CAN

Data: 2026-08-28

## Participantes

Engineering Manager, Tech Lead, Backend Python, Flutter Frontend, CAN Communications,
Linux Systems, Realtime Data, API Integration, UX/UI, QA, CAN QA, Code Reviewer e
Git/Release. Security participou sob demanda porque o backend permite transmissão CAN
a partir de um cliente remoto.

## Decisões

- Usar um monólito modular Python entre SocketCAN e clientes Flutter Web/mobile. O
  frontend nunca acessa o barramento diretamente.
- Usar REST versionado sob `/api/v1` para descoberta, controle de sessão, filtros e transmissão manual; usar
  WebSocket para eventos de frames e estado em tempo real.
- Usar `python-can` com SocketCAN no Linux, isolado por um adaptador de barramento.
- Descobrir interfaces dinamicamente e representar dados indisponíveis como `null`,
  sem incluir interfaces Ethernet.
- Aplicar filtros de IDs no socket/kernel quando suportado. `ALL` e `FILTERED` são
  estados explícitos; Standard e Extended não podem colidir silenciosamente.
- Preservar o timestamp de recepção fornecido pela plataforma como horário absoluto e
  usar uma referência monotônica separada para intervalos e jitter. A origem e a
  precisão do timestamp devem ser declaradas no contrato.
- Definir jitter no MVP como a média da diferença absoluta entre intervalos
  consecutivos do mesmo ID. A análise também expõe último intervalo, média, mínimo,
  máximo, frequência e número de amostras.
- Não apresentar perda percentual sem contador de sequência ou periodicidade esperada.
  Gaps inferidos sem esse oracle são apenas `suspected_gap`.
- Limitar buffers no backend e no frontend. Pausar a UI não interrompe a aquisição;
  parar captura é uma ação diferente.
- Oferecer trace cronológico no MVP e uma visão agregada por CAN ID quando viável. HEX
  e BIN usam grupos de bytes; RX/TX e CAN/CAN FD são textualmente identificáveis.
- Transmissão é manual e separada visualmente da monitoração. Não há envio periódico
  nesta versão.

## Divergências e resolução

### Frontend remoto versus ausência de autenticação complexa

CORS e validação de `Origin` não autenticam um operador. A resolução é tratar este MVP
como ferramenta local/de laboratório: bind em loopback por padrão, transmissão
desabilitada por padrão no servidor, `vcan` como alvo seguro padrão e habilitação
explícita para TX e interfaces físicas. Exposição em rede ou uso físico exige uma etapa
posterior de autenticação, autorização e TLS; sem isso, TX remoto não é aceitável.

### Timestamp absoluto versus monotônico

O timestamp do frame é preservado para correlação externa e exibição. Estatísticas de
intervalo não dependem de ajustes do relógio civil: usam amostras monotônicas internas.
O sistema não promete precisão de hardware que o driver não forneça.

### Atualização da UI versus integridade da aquisição

Batching limita reconstruções visuais, não a aquisição. Se houver overflow, a política
de descarte e seus contadores precisam ser observáveis; descarte silencioso é defeito.

### Cobertura com `vcan`

`vcan` valida modelo, filtros, SocketCAN, fluxo TX/RX e integração, mas não prova
arbitragem, comportamento elétrico, bus-off real, timestamp de hardware ou CAN FD
físico. Esses itens permanecem testes futuros de hardware/HIL.

## Consequências

O MVP permanece pequeno e executável sem hardware, mas já preserva limites entre
domínio, aquisição, análise e transporte. Segurança de rede e alegações de tempo real
em hardware ficam explicitamente fora da aceitação inicial.

## Fontes primárias consultadas

- [Linux: SocketCAN](https://docs.kernel.org/networking/can.html) — sockets CAN RAW,
  filtros, timestamps, loopback, CAN FD e `vcan`.
- [`python-can` 4.6: SocketCAN](https://python-can.readthedocs.io/en/stable/interfaces/socketcan.html)
  — bus, descoberta e filtros suportados pelo adapter.
- [FastAPI: WebSockets](https://fastapi.tiangolo.com/advanced/websockets/) e
  [teste de WebSockets](https://fastapi.tiangolo.com/advanced/testing-websockets/) —
  lifecycle e verificação do transporte.
- [Flutter: visão geral de testes](https://docs.flutter.dev/testing/overview) — divisão
  entre testes unitários, de widget e de integração.
