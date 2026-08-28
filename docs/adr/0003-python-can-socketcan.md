# ADR 0003: `python-can` sobre SocketCAN

- Status: aceito
- Data: 2026-08-28

## Contexto

Linux expõe controladores CAN como interfaces de rede e o projeto também precisa
funcionar com `vcan` sem hardware.

## Decisão

Usar `python-can` com interface SocketCAN. Chamadas específicas ficam em um adapter
pequeno; o restante usa modelos e contratos do projeto. Descoberta combina capacidades
da biblioteca com metadados Linux sem inventar valores.

## Consequências

Há suporte direto a filtros do socket e `vcan`. Comportamento elétrico, bus-off real e
timestamp de hardware ainda exigem hardware/HIL.
