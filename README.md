# Odin Video Editor

Editor de vídeo não-linear, escrito em **[Odin](https://odin-lang.org/)** com **raylib**. Interface *immediate-mode* desenhada à mão, decodificação de vídeo/áudio via **ffmpeg** (sem bindings C) e o áudio como relógio-mestre de sincronia.

> Projeto de arquivo único (`main.odin`). Roda no Windows.

---

## Recursos

- **Timeline multi-trilha** — até 12 trilhas de vídeo e 12 de áudio; um só bloco por clipe (vídeo + forma de onda juntos).
- **Corte não-destrutivo** — segmentos são *colocações* que recortam um trecho da fonte; vários segmentos podem apontar pra mesma mídia sem duplicar nada.
  - Dividir no playhead (`S`), ferramenta lâmina (`B`), aparar bordas (arrastar), *ripple* / anti-sobreposição.
- **Bin de mídia** — importação assíncrona (probe + decode + áudio numa thread por mídia), miniaturas, arrastar pra timeline.
- **Filmstrip de miniaturas** e **forma de onda real** ao longo de cada clipe.
- **Transições e fades** — dissolver entre clipes, fade de vídeo (preto) de entrada/saída, fades de áudio.
- **Transform no preview** — mover, escalar, recorte (crop), distorção; tudo WYSIWYG com o export.
- **Controles de áudio por segmento** — volume (0–200%), mudo, fade in/out.
- **Prévia em tela cheia** — só o vídeo ocupando o monitor inteiro, com controles no rodapé (progresso, play/pause, tempo, volume, sair) que somem sozinhos e reaparecem ao mexer o mouse perto.
- **Vídeos longos** — clipes de até ~5 h via *streaming* (decode ao vivo) + áudio sob demanda em janela móvel.
- **Decode por GPU** — usa `h264_cuvid` em placas NVIDIA quando disponível, com *fallback* automático por software.
- **Export** — `ffmpeg filter_complex` reproduzindo transforms/fades/velocidade do preview.
- **Screenshot** do quadro atual (PNG/JPG).
- **Salvar / abrir projeto** (`.ovp`), **desfazer/refazer**.

---

## Requisitos

- **[Odin](https://odin-lang.org/)** — build usado no desenvolvimento: `dev-2026-06-nightly`.
- **ffmpeg** e **ffprobe** no `PATH` — dependência dura (todo decode/probe/export passa por eles).
- **Windows** — usa `core:sys/windows` (diálogo de arquivo `GetOpenFileNameW`, *Job Objects* pra não deixar ffmpeg órfão).
- **GPU NVIDIA** *(opcional)* — acelera o decode; sem ela, roda por software.

O raylib já vem pré-compilado com o Odin no Windows (`vendor/raylib`), não precisa instalar nada além.

---

## Compilar e rodar

```sh
odin build . -out:editor.exe
./editor.exe
```

> ⚠️ **Sempre compile pra um nome SEM espaço** (`editor.exe`). Um build pra `"video editor.exe"` (com espaço) falha ao gravar o `.exe` silenciosamente (sai com código 0 mas não gera o arquivo).

### Build de debug (com verificação de invariantes)

```sh
odin build . -debug -out:editor_debug.exe
```

Liga `check_invariants()` (roda 1×/frame validando o estado da timeline). No release é no-op.

### Testes

```sh
odin test . -out:tests.exe -define:ODIN_TEST_THREADS=1 -define:INVARIANTS=true
```

- `ODIN_TEST_THREADS=1` é **obrigatório** — os testes compartilham os globais (`segs`/`clips`/`st`).
- `INVARIANTS=true` liga o verificador durante os testes.
- Cobre parsing do ffprobe, multi-seleção de arquivos, mapa NVDEC, forma de onda (inclusive `compute_waveform` de ponta a ponta com um tom gerado pelo ffmpeg), e a lógica de segmentos (corte, ripple, paredes, cadeia contígua, ganho de áudio).

### Benchmark

```sh
./editor.exe -bench "C:/caminho/video.mp4"
```

Roteiro fixo (importar → tocar → *seeks* → cortes) que mede o trabalho da main thread por frame, picos de *hitch* e RAM de pico, imprime o relatório e fecha. Use o build **release** (o `-debug` suja a medição).

---

## Atalhos de teclado

| Tecla | Ação |
|---|---|
| `Espaço` | Play / pause |
| `←` / `→` | 1 frame (com `Shift`: 1 s) |
| `Home` / `End` | Início / fim |
| `S` | Dividir no playhead |
| `B` | Ferramenta lâmina |
| `F` | Ajustar zoom à janela (*fit*) |
| `Esc` | Sair da lâmina / tela cheia / prévia; desselecionar |
| `Ctrl`+`Z` | Desfazer |
| `Ctrl`+`Y` / `Ctrl`+`Shift`+`Z` | Refazer |
| `Ctrl`+`S` / `Ctrl`+`O` | Salvar / abrir projeto |
| `Ctrl`+`C` / `X` / `V` | Copiar / recortar / colar |
| `Ctrl`+`D` | Duplicar |
| `Delete` / `Backspace` | Remover (com `Alt`: deixa o vão) |

Também dá pra arrastar arquivos de vídeo pra dentro da janela (vão pro bin).

---

## Como funciona (decisões de arquitetura)

- **UI *immediate-mode* à mão sobre raylib**, não ImGui (este build do Odin não traz `vendor:imgui`). A barra de título, botões e painéis são todos desenhados a cada frame.
- **Vídeo via ffmpeg por pipe, não bindings C.** ffmpeg/ffprobe resolvem pelo `PATH`.
  - **Clipes curtos** (≤ 45 s e dentro do orçamento de RAM) são pré-decodificados **inteiros para a RAM** numa thread de fundo (`ffmpeg -f rawvideo -pix_fmt rgb24 …`), a **640×360**. Play/seek = só indexar o frame e `UpdateTexture` → **seek instantâneo**.
  - **Clipes longos** viram **streaming** (decode ao vivo, `-ss` por seek); áudio extraído sob demanda em janela móvel.
- **Áudio = relógio-mestre.** A trilha é extraída para WAV e tocada via `rl.Music`; o vídeo indexa `GetMusicTimePlayed(music) * fps`. Isso mantém A/V em sincronia inclusive atravessando cortes.
- **Fonte com SDF** (Segoe UI, *signed distance field*) pra ficar nítida em qualquer tamanho — sempre via `txt()`/`txt_c()` (a fonte default do raylib não é usada).
- **Sem processos órfãos** — cada ffmpeg entra num *Job Object* do Windows com `KILL_ON_JOB_CLOSE`, então morre junto com o editor mesmo em caso de crash.
- **Tela cheia** usa `ToggleBorderlessWindowed` (cobre o monitor inteiro, inclusive a barra de tarefas) — o `ToggleFullscreen` deixava a barra de tarefas aparecer no rodapé.

### Limites atuais

| | |
|---|---|
| Mídias no bin | 12 (`MAX_CLIPS`) |
| Segmentos na timeline | 64 (`MAX_SEGS`) |
| Trilhas | 12 vídeo + 12 áudio |
| Resolução do preview | 640×360 (streaming: alterna 360p/720p) |
| Cache em RAM | ~180 s (`CACHE_BUDGET`), ~20 MB/s |

---

## Estrutura do projeto

```
main.odin          # o editor inteiro
parse_test.odin    # testes de parsing (ffprobe, multi-seleção, waveform…)
segs_test.odin     # testes da lógica de segmentos/timeline
bench.odin         # modo -bench (perfil da main thread)
editor.exe         # build release
editor_debug.exe   # build debug (invariantes ligados)
```

O formato de projeto `.ovp` guarda a proporção do canvas, os caminhos das mídias e os segmentos (com transform e áudio).
