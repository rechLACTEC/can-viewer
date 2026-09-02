# CAN Viewer

Monitor CAN funcional com backend Python/SocketCAN e frontend Flutter Web. O backend descobre interfaces Linux, controla aquisição e transmissão, calcula métricas de timing e entrega frames em tempo real; o Flutter permanece remoto e nunca acessa diretamente o barramento.

## Tecnologias

- **Backend:** Python 3.12, FastAPI, `python-can`/SocketCAN e `uv`
- **Frontend:** Flutter/Dart, HTTP e WebSocket

## Estrutura

```text
.
├── backend/          # Domínio, serviço de sessão, adaptador SocketCAN e API
├── frontend/         # Aplicação Flutter Web/mobile
├── docs/             # Reunião técnica, contrato, QA e ADRs
└── scripts/          # Configuração reversível de vcan para desenvolvimento
```

## Requisitos

- Linux para SocketCAN ou `vcan`
- uv 0.9 ou mais recente e Python 3.12+
- Flutter estável com Dart compatível

## Backend

```bash
cd backend
uv sync --dev
PYTEST_DISABLE_PLUGIN_AUTOLOAD=1 uv run pytest -q
uv run uvicorn can_monitor.main:app --reload --host 127.0.0.1 --port 8000
```

Para criar `vcan0` sem instalar pacotes nem executar `sudo` automaticamente:

```bash
./scripts/setup-vcan.sh up vcan0
```

## Frontend Web

```bash
cd frontend
flutter pub get
flutter analyze
flutter test
flutter run -d chrome --dart-define=CAN_API_BASE_URL=http://localhost:8000
```

## Iniciar para acesso na rede local

O script abaixo detecta o IP local, inicia backend e frontend e mostra a URL que pode
ser aberta em outros dispositivos conectados à mesma rede:

```bash
./scripts/start.sh
```

Use `Ctrl+C` para encerrar os dois processos. Se a detecção automática escolher o IP
errado, informe explicitamente o endereço da máquina:

```bash
CAN_VIEWER_LAN_IP=192.168.1.10 ./scripts/start.sh
```

As portas padrão são `5173` para a interface e `8000` para a API. Elas podem ser
alteradas com `CAN_VIEWER_FRONTEND_PORT` e `CAN_VIEWER_BACKEND_PORT`. O firewall do
host precisa permitir conexões TCP nessas portas para que outros dispositivos acessem.
Se necessário, selecione uma instalação específica do Flutter com
`CAN_VIEWER_FLUTTER_BIN=/caminho/flutter/bin/flutter`.

Consulte [a documentação do backend](backend/README.md), o [contrato da API](docs/api-contract.md) e os [ADRs](docs/adr/) para detalhes de segurança, filtros, timestamps e limitações de medição de perda.
