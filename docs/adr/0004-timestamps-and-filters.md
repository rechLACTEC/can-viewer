# ADR 0004: Estratégia de timestamps e filtros CAN

- Status: aceito
- Data: 2026-08-28

## Contexto

Horário absoluto serve a correlação; jitter não deve sofrer saltos do relógio civil.
Filtrar apenas em Python aumenta carga e pode confundir SFF/EFF.

## Decisão

Preservar timestamp de recepção da plataforma em nanossegundos de transporte junto da
origem declarada. Calcular intervalos com referência monotônica interna. Definir jitter
como `mean(abs(interarrival[i] - interarrival[i-1]))` por interface+ID+formato e
expor separadamente o desvio-padrão amostral dos intervalos.

Aplicar listas de filtros no SocketCAN via `python-can` quando possível. Os filtros
incluem ID e `is_extended_id`; `ALL` é explícito e não uma lista ambígua.

## Consequências

A resolução numérica do contrato não promete precisão física equivalente. Mudanças de
filtro sob tráfego e distinção SFF/EFF exigem reconciliação independente.
