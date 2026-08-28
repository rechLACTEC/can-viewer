# ADR 0005: Defaults seguros para transmissão CAN

- Status: aceito
- Data: 2026-08-28

## Contexto

Um cliente remoto pode alterar equipamento real ao transmitir frames. O MVP não inclui
autenticação complexa, e CORS não é controle de autorização.

## Decisão

TX é manual e desabilitado por padrão no backend. O default de rede é loopback e o alvo
seguro é `vcan`. Habilitar TX ou interface física exige configuração explícita. O
servidor valida interface descoberta, ID, formato, payload, DLC/length e flags, aplica
limites de taxa/recurso e registra tentativa/resultado. A UI separa Receive de Transmit,
exige confirmação e não oferece envio periódico.

## Consequências

O laboratório local continua funcional. Exposição em rede ou TX físico requer TLS,
autenticação, autorização e política operacional antes de produção; sem isso, a revisão
de segurança bloqueia essa modalidade.
