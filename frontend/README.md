# Frontend Flutter

Cliente Web do CAN Viewer. No modo da Jetson, é compilado previamente e servido pelo FastAPI na mesma origem da API e do WebSocket.

```bash
# desenvolvimento/hot reload, a partir da raiz
./scripts/dev.sh

# build autocontido, a partir da raiz
./scripts/setup.sh --frontend-only
```

O build de produção contém CanvasKit, ícones e fontes locais e não registra service worker. `CAN_API_BASE_URL` é um override de desenvolvimento; quando vazio, a aplicação usa automaticamente a origem da página, por exemplo `http://192.168.1.20:8000`.

Não publique `build/` no Git. Transfira `frontend/build/web` completo como artefato junto da versão preparada para a Jetson.
