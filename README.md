# Mimir

Ditado 100% local para macOS. Grava sua voz, transcreve on-device (WhisperKit),
aplica uma limpeza opcional por um LLM local (MLX) e cola o texto no app em
foco. Nada sai da sua máquina.

> ⚠️ **Projeto em estágio inicial.** Uso pessoal estável, mas espere rebaixa
> esporádica de performance e mensagens em pt-BR no UI. PRs bem-vindas.

## Highlights

- **Totalmente offline** — áudio e texto nunca saem do dispositivo.
- **Trigger global** configurável (default: Right ⌥, tap para alternar).
- **Streaming de preview** — o texto do LLM aparece token-a-token na ilha enquanto gera.
- **Telemetria visual** — popover com veredito rápida/normal/lenta, barra
  proporcional de onde o tempo foi, comparação com a mediana das últimas ditadas.
- **Histórico local** em `UserDefaults` (últimos 200 ditados com métricas).

## Requisitos

- macOS 15 (Sequoia) ou mais novo
- Apple Silicon (M1+) — o MLX e os modelos Whisper quantizados são otimizados para ANE/GPU
- Xcode 26+ com toolchain Swift 6.3+
- ~3 GB de disco livre para os modelos (Whisper Large V3 Turbo Quantizado + Qwen2.5-3B 4-bit)

## Instalação (a partir do código)

```bash
git clone https://github.com/<seu-usuário>/mimir.git
cd mimir
swift build -c release
bash scripts/build_app.sh
open dist/Mimir.app
```

O `build_app.sh` cria um keychain local (`mimir-codesign`) com um certificado
auto-assinado para dar code-signing estável ao binário — necessário para o
macOS conceder permissões (Input Monitoring, Accessibility) sem revogá-las a
cada rebuild. Variáveis de ambiente úteis:

- `MIMIR_BUNDLE_ID=dev.seunome.mimir` — sobrescreve o `CFBundleIdentifier`.
- `MIMIR_OUTPUT_DIR=/caminho/customizado` — diretório de saída do `.app`.
- `MIMIR_SKIP_CODESIGN=1` — pula assinatura (útil em CI).

## Primeira execução

1. Abra o `Mimir.app` recém-buildado.
2. macOS vai pedir três permissões:
   - **Microfone** — para capturar áudio.
   - **Monitoramento de Entrada** — para detectar o atalho global.
   - **Acessibilidade** — para fazer o `⌘V` final no app em foco.
3. Na primeira ditada os modelos são baixados do Hugging Face:
   - Whisper Large V3 Turbo Quantizado (~950 MB) via WhisperKit
   - Qwen2.5-3B Instruct 4-bit (~1.8 GB) via mlx-community
   - Isso leva alguns minutos e só acontece uma vez por modelo.
4. Segure o gatilho (default: **toque em Right ⌥**), fale, toque de novo, e o texto aparece.

## Configurações principais (UI → Ajustes)

| Categoria | Opções |
|-----------|--------|
| Trigger | Modifier puro (Right ⌥/⌘/⇧), modifier + tecla, hold-to-talk ou tap-to-toggle |
| Transcrição | WhisperKit (Core ML) — outros providers estão como placeholder |
| Estratégia Whisper | Chunked (streaming + warmup) ou Batch (arquivo inteiro) |
| Modelo Whisper | tiny / base / small / medium / large-v3 / large-v3-turbo / **large-v3-turbo quantizado (default)** |
| Pós-processamento | MLX (Qwen2.5-3B) ou desativado |
| Estilo de pós-processamento | Correção leve (ortografia/acentos) ou Estruturado (pontuação, parágrafos, listas quando óbvias) |
| Inserção | Clipboard + paste sintético |
| Idioma preferencial | Força Whisper a decodificar numa variante específica |

## Integração Hermes (opcional)

O Mimir tem um painel embutido para uma CLI chamada **Hermes** (separada). Se
você não usa Hermes, o painel fica inerte e mostra instruções — o resto do app
funciona normal.

Para ativar:
- Instale o binário `hermes` em qualquer lugar no seu `PATH` (o Mimir procura
  em `~/.local/bin/hermes` por default), ou
- Defina `HERMES_PATH=/caminho/para/hermes` antes de abrir o Mimir.

## Arquitetura resumida

```
┌─────────────┐   audio    ┌───────────────────┐  transcript   ┌─────────────┐
│ AVAudio     │──────────▶│ WhisperKitProvider │──────────────▶│ MLX Post    │
│ Engine tap  │  chunks +  │   (Chunked/Batch)  │    SpeechTR   │ Processor   │
└─────────────┘  full WAV  └───────────────────┘                └──────┬──────┘
                                                                       │ final text
                                                                       ▼
                                                              ┌─────────────┐
                                                              │ Clipboard + │
                                                              │ ⌘V sintético│
                                                              └─────────────┘
```

Fontes em `Sources/MimirCore` (lógica, pipeline, modelos) e
`Sources/MimirApp` (SwiftUI, controllers, UI). Testes em `Tests/`.

## Contribuindo

PRs são bem-vindas. Antes de mandar:

1. `swift test` passa.
2. `swift build -c release` sem warnings novos.
3. Strings em pt-BR (o UI é pt-BR por enquanto — se quiser localizar, abra
   uma issue pra decidirmos a estratégia).

Bug reports detalhados (versão do macOS, chip, log de `/tmp/mimir-swift-build.log`)
ajudam muito.

## Créditos

Veja `NOTICE.md` para a lista completa de dependências e licenças. Em
particular, agradecimento especial ao pessoal da **argmaxinc/WhisperKit** e do
**ml-explore/mlx-swift-lm**, sem os quais este projeto não existiria.

## Licença

MIT — veja `LICENSE`. Os modelos baixados em tempo de execução têm licenças
próprias, consulte `NOTICE.md`.
