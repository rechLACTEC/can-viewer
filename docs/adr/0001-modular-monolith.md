# ADR 0001: Monólito modular Python com cliente Flutter remoto

- Status: aceito
- Data: 2026-08-28

## Contexto

O barramento é acessível no Linux, enquanto Flutter Web/mobile pode executar em outra
máquina. O MVP precisa evoluir sem a operação de microsserviços.

## Decisão

Manter um processo backend Python modular, com Adapter CAN, Acquisition Service, Domain
Model, Analysis, Application Service e adapters HTTP/WS. Flutter é cliente remoto e
nunca acessa SocketCAN diretamente.

## Consequências

Há um único lifecycle e implantação simples. Fronteiras internas continuam testáveis.
Escala independente e tolerância distribuída ficam fora do MVP.
