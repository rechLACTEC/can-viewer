# ADR 0002: REST para controle e WebSocket para streaming

- Status: aceito
- Data: 2026-08-28

## Contexto

Descoberta e comandos são operações discretas; frames formam fluxo contínuo. Polling
rápido por HTTP adicionaria latência e overhead.

## Decisão

Usar REST para interfaces, status, sessão, filtros e TX manual; usar WebSocket para
frames, estatísticas, mudanças de estado e erros. Mensagens são versionadas e filas por
cliente são limitadas.

## Consequências

Aquisição e refresh da UI podem ter taxas diferentes. Reconnect, backpressure, origem e
compatibilidade do contrato precisam de testes explícitos.
