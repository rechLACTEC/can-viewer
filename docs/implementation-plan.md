# Plano de implementação do MVP CAN

| Ordem | Entrega | Responsável | Consultados | Dependências | Aceitação principal |
|---:|---|---|---|---|---|
| 1 | Modelo de domínio, validação e análise de timing | Backend Python | CAN, Realtime, QA | decisões de timestamp/jitter | IDs, payloads, flags e estatísticas cobertos por testes de fronteira |
| 2 | Adaptador `python-can`/SocketCAN e descoberta | CAN Communications | Linux, Backend, CAN QA | modelo de domínio | lista somente CAN/vcan; open/close/filter/send são testáveis e liberam recursos |
| 3 | Serviço de aquisição e sessão | Backend Python | Realtime, CAN | 1–2 | lifecycle idempotente, buffer limitado, erros e overflow observáveis |
| 4 | REST e WebSocket | API Integration | Backend, Security | 1–3 | contrato versionado; controle REST; stream não bloqueia aquisição com cliente lento |
| 5 | Fluxo e componentes Flutter | Flutter Frontend | UX/UI, API | contrato 4 | selecionar/conectar/filtrar/monitorar/pausar/transmitir/desconectar |
| 6 | Controles de TX | Backend + Flutter | Security, UX/UI, CAN QA | 2, 4–5 | validação server-side, TX off por padrão, confirmação e sem envio periódico |
| 7 | Testes unitários e de componentes | Implementadores | QA | entregas correspondentes | nominal, fronteira, inválido, erro, recovery e lifecycle no nível mais baixo útil |
| 8 | Integração `vcan` e reconciliação ponta a ponta | CAN QA | Linux, Backend, API, Flutter | 2–7 | frames conhecidos reconciliados de captura independente até WS/UI |
| 9 | Revisão independente | Code Reviewer | especialistas de domínio | código e testes completos | blockers de concorrência, integridade, segurança e recursos corrigidos |
| 10 | Validação e estado final | QA + Git/Release | CAN QA, Code Reviewer | 8–9 | suites verdes, limitações explícitas, `git diff --check` e worktree revisado |

## Dependências de execução

- Backend gerenciado apenas com `uv` e Python 3.12 ou superior.
- Flutter estável e Dart compatível com o lockfile.
- Linux com suporte a SocketCAN para integração; `can-utils` é recomendado como oracle
  independente.
- Criação de `vcan0` é uma ação explícita do operador e pode exigir privilégios.

## Critérios transversais

- Nenhum crescimento ilimitado de filas ou histórico.
- Nenhuma métrica de perda sem informação protocolar suficiente.
- Nenhuma transmissão inválida ou habilitada implicitamente.
- Valores desconhecidos permanecem desconhecidos.
- Falhas são compreensíveis no cliente e detalhadas com segurança no log.
- Testes com mock não substituem a evidência `vcan`; `vcan` não substitui hardware/HIL.
