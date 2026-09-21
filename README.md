# CAN Viewer

Monitor CAN com backend Python/SocketCAN e frontend Flutter Web. No modo de execução da Jetson, o FastAPI serve a interface, REST e WebSocket na mesma origem; depois de preparado, o sistema não precisa de Internet, Flutter, uv ou registries para iniciar.

## Desenvolvimento local

Requer Python 3.12, uv e Flutter. Pode acessar a Internet para preparar dependências e mantém hot reload:

```bash
./scripts/dev.sh
```

Defaults: frontend `http://127.0.0.1:5173`, API `http://127.0.0.1:8000`. Para abrir a partir de outro computador na LAN:

```bash
CAN_VIEWER_LAN_IP=192.168.1.10 ./scripts/dev.sh
```

## Preparação/build

Esta é a única etapa que pode baixar dependências e artefatos:

```bash
./scripts/setup.sh
```

O comando sincroniza o backend estritamente com `uv.lock` e gera `frontend/build/web` com CanvasKit e fontes locais, sem service worker obrigatório. Opções:

```bash
./scripts/setup.sh --backend-only --production  # execute na Jetson conectada
./scripts/setup.sh --frontend-only              # pode executar no PC
```

O ambiente Python não é portátil entre o PC x86 e a Jetson ARM. Prepare `backend/.venv` na própria Jetson, ou produza um wheelhouse compatível com a mesma arquitetura, Python e sistema operacional. O diretório Web é portátil e pode ser copiado inteiro do PC para a Jetson.

## Execução offline na Jetson

Depois de transferir uma versão preparada:

```bash
./scripts/start.sh
```

Acesse `http://<IP_DA_JETSON>:8000` em qualquer PC da mesma LAN. O script apenas valida os artefatos e executa o Python de `backend/.venv`; não chama `uv`, Flutter, package registries ou servidores de desenvolvimento.

Antes de iniciar, o preflight confirma o bundle Web completo, incluindo `flutter.js`,
`manifest.json`, favicon, CanvasKit JS/WASM, `FontManifest.json` e as fontes locais.
Um bundle parcial é rejeitado antes de abrir a porta HTTP.

Variáveis úteis:

- `CAN_VIEWER_HOST` — bind do servidor, padrão `0.0.0.0`;
- `CAN_VIEWER_BACKEND_PORT` — porta única de UI/API/WS, padrão `8000`;
- `CAN_VIEWER_PYTHON` — Python preparado, padrão `backend/.venv/bin/python`;
- `CAN_MONITOR_FRONTEND_DIRECTORY` — build Web, padrão `frontend/build/web`;
- `CAN_MONITOR_RECORDING_DIRECTORY` — gravações, padrão `recordings/`.

## Atualização em local sem Internet

Prepare antes de ir a campo ou em uma máquina compatível:

1. gere o build Web no PC com `./scripts/setup.sh --frontend-only`;
2. prepare as dependências Python na Jetson enquanto houver acesso aos pacotes, com `./scripts/setup.sh --backend-only --production`;
3. transfira o repositório e `frontend/build/web` completo pela LAN ou mídia removível;
4. não substitua a `.venv` ARM da Jetson por uma criada no PC;
5. no local isolado, use somente `./scripts/start.sh`.

Um `git pull` não faz parte do runtime e não deve ser necessário para continuar executando a versão já instalada.

## Validação offline

Com o backend e build preparados, em um Linux com user namespaces, Chrome/Chromium e suporte a `vcan`:

```bash
./scripts/test-offline.sh
```

O teste cria um namespace de rede sem rota externa e um `vcan0` isolado. Em duas inicializações independentes, abre um perfil limpo do navegador, confirma que todos os requests são locais, verifica ausência de service worker, testa REST, WebSocket same-origin e TX→RX via SocketCAN. Ele não altera as interfaces de rede do host.

Testes normais:

```bash
cd backend
PYTHONDONTWRITEBYTECODE=1 PYTEST_DISABLE_PLUGIN_AUTOLOAD=1 .venv/bin/python -m pytest -q -p no:cacheprovider

cd ../frontend
flutter analyze --no-pub
flutter test --no-pub
```

Consulte [a implantação offline](docs/OFFLINE_DEPLOYMENT.md), [o backend](backend/README.md) e [o contrato da API](docs/api-contract.md) para detalhes.
