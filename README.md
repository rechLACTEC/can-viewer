# CAN Viewer

Monorepo para a fundação de um sistema de monitoramento de barramento CAN. Nesta etapa, o projeto contém somente as bases independentes do backend e do frontend; aquisição CAN e comunicação entre os componentes serão definidas posteriormente.

## Tecnologias

- **Backend:** Python 3.12, gerenciado exclusivamente com [uv](https://docs.astral.sh/uv/)
- **Frontend:** Flutter e Dart

## Estrutura

```text
.
├── backend/          # Pacote Python com layout src
│   ├── src/can_monitor/
│   └── tests/
└── frontend/         # Aplicação Flutter padrão
```

## Requisitos

- Git
- uv 0.9 ou mais recente
- Python 3.12 ou compatível
- Flutter estável com Dart compatível

## Backend

Na raiz do repositório:

```bash
cd backend
uv sync
uv run python -c "import can_monitor"
uv run python -m unittest discover -s tests
```

O `uv sync` cria o ambiente local em `backend/.venv` e instala o pacote a partir do `uv.lock`.

## Frontend

```bash
cd frontend
flutter pub get
flutter analyze
flutter test
flutter run
```

Selecione um dispositivo compatível quando solicitado por `flutter run`.
