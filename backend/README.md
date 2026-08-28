# Backend

Base Python do monitor CAN, organizada como pacote no layout `src/` e gerenciada com `uv`.

```bash
uv sync
uv run python -m unittest discover -s tests
```

Integração CAN, API e aquisição de dados ainda não fazem parte desta etapa.
