# Fontes locais

Estes arquivos são assets redistribuíveis da aplicação, não um cache do SDK.
O build os empacota para que um navegador novo carregue a interface pela LAN.

- `Roboto-{Regular,Medium,Bold}.ttf`: arquivos originais de
  `bin/cache/artifacts/material_fonts` do Flutter 3.41.2; licença Apache 2.0
  em `Roboto_LICENSE.txt`.
- `NotoSansSymbols2-Regular.ttf`: arquivo original do pacote Debian
  `fonts-noto-core` versão `20201225-2`, `/usr/share/fonts/truetype/noto`; copyright Google,
  licença SIL OFL 1.1 em `NotoSansSymbols2_LICENSE.txt`. Cobre símbolos como
  o aviso de gravação degradada (`⚠`) que não constam nesta versão do Roboto.

O nome da família `Roboto` no pubspec também evita o download implícito da
fonte padrão pelo engine Web. O tema usa NotoSansSymbols2 como fallback.
`web/flutter_bootstrap.js` mantém qualquer consulta adicional de fallback na
origem local; estes assets não prometem cobertura de todo o Unicode.
