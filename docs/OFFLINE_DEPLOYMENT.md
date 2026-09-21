# Implantação e operação offline

## Arquitetura

O modo de execução usa um processo Uvicorn/FastAPI na Jetson:

```text
PC/browser -- LAN --> Jetson:8000
                         ├── / e assets Flutter estáticos
                         ├── /api/v1 (REST)
                         ├── /api/v1/.../stream (WebSocket)
                         └── python-can -> SocketCAN
```

Frontend, REST, download TRC e WebSocket usam a origem aberta no navegador. O IP não é compilado no build. `CAN_API_BASE_URL` continua disponível somente como override para desenvolvimento separado.

O build registra Roboto e Noto Sans Symbols 2 como assets, aponta CanvasKit e fallback de fontes para a própria origem e não registra service worker. Assim, um navegador novo não depende de cache prévio nem de CDN.

## DEV

```bash
./scripts/dev.sh
```

Esse modo usa `uv sync`, `flutter pub get`, Uvicorn com reload e Flutter web-server. Ele é destinado ao PC de desenvolvimento e pode acessar a Internet. `CAN_VIEWER_LAN_IP` permite expor o dev server na LAN.

## BUILD/SETUP

Para preparar tudo na mesma máquina:

```bash
./scripts/setup.sh
```

Para o fluxo PC → Jetson:

```bash
# PC com Flutter
./scripts/setup.sh --frontend-only

# Jetson, antes de ficar isolada
./scripts/setup.sh --backend-only --production
```

O frontend usa `pubspec.lock`, `--no-web-resources-cdn`, build sem nova resolução depois do `pub get` e sem estratégia PWA. O backend usa `uv sync --locked`; `uv.lock` continua como fonte da resolução reproduzível.

Transfira para a Jetson o código da versão e `frontend/build/web` completo. Não versione `build/`, `.dart_tool`, `.venv` ou caches. Para uma atualização totalmente offline das dependências Python, produza e transfira previamente um wheelhouse específico para Linux ARM64, para a versão de Python e glibc da Jetson; este repositório não gera esse wheelhouse automaticamente.

## RUN

```bash
./scripts/start.sh
```

Pré-condições:

- `backend/.venv/bin/python` existe e importa `can`, `fastapi` e `uvicorn`;
- `frontend/build/web` contém o bundle completo: `index.html`, `flutter.js`,
  `flutter_bootstrap.js`, `main.dart.js`, `manifest.json`, `favicon.png`,
  CanvasKit JS/WASM, `FontManifest.json` e as fontes Roboto/Noto;
- a interface SocketCAN foi configurada pelo sistema da Jetson;
- o diretório de gravações é gravável;
- a porta TCP 8000 é acessível apenas na LAN desejada.

O script não instala, sincroniza ou compila. A UI fica em `http://<IP_DA_JETSON>:8000`. Para alterar bind/porta:

```bash
CAN_VIEWER_HOST=192.168.1.20 CAN_VIEWER_BACKEND_PORT=9000 ./scripts/start.sh
```

## Teste sem Internet

```bash
./scripts/test-offline.sh
```

O teste reexecutável entra em namespace sem rota default, cria `vcan0` apenas nele e faz duas partidas completas. Cada partida usa perfil temporário novo do Chrome/Chromium e verifica:

- renderização Flutter e assets locais;
- zero requests HTTP/HTTPS/WS para outra origem;
- zero service workers registrados;
- health REST e descoberta do `vcan0`;
- criação de sessão e WebSocket same-origin;
- frame enviado pelo backend e observado no stream via SocketCAN.

O resultado só é aceito quando as duas partidas terminam com sucesso. Interromper
o comando não transforma uma única partida aprovada em evidência de reinício.

O teste exige user namespaces não privilegiados, módulo `vcan` disponível e Chrome/Chromium. Hardware CAN, CAN FD e comportamento elétrico continuam exigindo validação específica na Jetson/robô.

## Atualização e rollback

Mantenha a versão atualmente funcional até validar a nova versão preparada. Uma atualização de código que não muda dependências ainda precisa trazer um novo build Web. Mudanças em `uv.lock`, versão Python ou sistema da Jetson exigem nova preparação do backend. Se a nova versão falhar, restaure juntos código, build Web e ambiente Python correspondentes; misturar artefatos de versões diferentes não é suportado.
