# Editor de Vídeo

Editor de vídeo não-linear, escrito em **[Odin](https://odin-lang.org/)** com **raylib**. Interface *immediate-mode* desenhada à mão, decodificação de vídeo/áudio via **ffmpeg** (sem bindings C) e o áudio como relógio-mestre de sincronia.

> Fonte em `src/` (mesmo `package main`, `odin build src`). Roda no Windows.

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
- **Decode por GPU** — usa `h264_cuvid` em placas NVIDIA no *streaming* e no *scrub*, com *fallback* automático por software. O cache em RAM é **sempre por software** de propósito: o NVDEC entrega alguns frames a mais em certos arquivos (1221 em vez de 1218 num teste), e o cache indexa por `int(t*fps)` assumindo frames uniformes — o desencontro virava *judder*.
- **Export** — `ffmpeg filter_complex` reproduzindo transforms/fades/velocidade do preview.
- **Screenshot** do quadro atual (PNG/JPG).
- **Salvar / abrir projeto** (`.ovp`), **desfazer/refazer**.

---

## Requisitos

- **[Odin](https://odin-lang.org/)** — build usado no desenvolvimento: `dev-2026-06-nightly`.
- **ffmpeg** e **ffprobe** — dependência dura (todo decode/probe/export passa por eles). Ao rodar **do código-fonte**, precisam estar no `PATH`. *(O **instalador** já empacota os dois ao lado do editor — o usuário final **não** precisa instalar ffmpeg; ver [Gerar o instalador](#gerar-o-instalador).)*
- **Windows** — usa `core:sys/windows` (diálogo de arquivo `GetOpenFileNameW`, *Job Objects* pra não deixar ffmpeg órfão).
- **GPU NVIDIA** *(opcional)* — acelera o decode; sem ela, roda por software.

O raylib já vem pré-compilado com o Odin no Windows (`vendor/raylib`), não precisa instalar nada além.

---

## Compilar e rodar

```sh
odin build src -out:editor.exe
./editor.exe
```

> ⚠️ **Sempre compile pra um nome SEM espaço** (`editor.exe`). Um build pra `"video editor.exe"` (com espaço) falha ao gravar o `.exe` silenciosamente (sai com código 0 mas não gera o arquivo).

### Build de debug (com verificação de invariantes)

```sh
odin build src -debug -out:editor_debug.exe
```

Liga `check_invariants()` (roda 1×/frame validando o estado da timeline). No release é no-op.

### Testes

```sh
odin test src -out:tests.exe -define:ODIN_TEST_THREADS=1 -define:INVARIANTS=true
```

- `ODIN_TEST_THREADS=1` é **obrigatório** — os testes compartilham os globais (`segs`/`clips`/`st`).
- `INVARIANTS=true` liga o verificador durante os testes.
- Cobre parsing do ffprobe, multi-seleção de arquivos, mapa NVDEC, forma de onda (inclusive `compute_waveform` de ponta a ponta com um tom gerado pelo ffmpeg), a lógica de segmentos (corte, ripple, paredes, cadeia contígua, ganho de áudio) e a **montagem do comando de exportação**.
- O export é testado como **texto**: `export_build_args(out, gpu, dry = true)` monta a linha de comando inteira sem tocar disco, GPU nem ffmpeg, e os testes conferem o filtergraph resultante (que vem pelo **segundo retorno**, não de dentro de `args` — ver abaixo). Isso existe porque erro no export falha em silêncio — o ffmpeg aceita um grafo com o `trim` deslocado, sai com código 0 e entrega um arquivo válido com o áudio fora do lugar.
- O **filtergraph vai num arquivo** (`-filter_complex_script`), não na linha de comando: ele é a maior parte do comando (~254 chars por segmento de vídeo) e o `CreateProcessW` do Windows corta em 32767 chars — com a timeline cheia o export morria com um "Falha ao iniciar ffmpeg" sem causa. Sobra o `cmdline_len`/`CMDLINE_MAX` como rede para os inputs, que dizem a causa real em vez de falhar mudo. A opção está marcada como *deprecated* no ffmpeg novo; a alternativa (`-/filter_complex`) só existe do ffmpeg 7 em diante e o binário vem do PATH, então trocar quebraria instalações antigas.
- O **salvar projeto** segue a mesma ideia: `save_project_text()` monta o `.ovp` inteiro sem escrever em disco, e o teste confere que a contagem do cabeçalho `seg N` bate com as linhas emitidas. Perder segmento ao salvar também falha em silêncio — o arquivo sai bem-formado, só que menor.
- **Mídia ainda importando** é barrada no export e preservada no save (`segs_importing()`), e isso tem teste: o import é assíncrono, então dava para exportar um projeto recém-aberto e receber preto no lugar dos clipes que não tinham terminado o probe.
- A **janela de áudio** (qual arquivo está aberto em `c.music` — head, chunk ou OGG completo — e se ele cobre a posição pedida) é testada pelo mesmo motivo: erro ali deixa o clipe mudo ou tocando da posição errada, sem erro nenhum. Os testes montam um `rl.Music` **falso** (só `frameCount`/`sampleRate`) e por isso só exercitam os caminhos que retornam **antes** da primeira chamada ao raylib — o cabeçalho do `audio_test.odin` diz exatamente quais são, leia antes de adicionar caso novo.

### Benchmark

```sh
./editor.exe -bench "C:/caminho/video.mp4"
```

Roteiro fixo (importar → tocar → *seeks* → cortes) que mede o trabalho da main thread por frame, picos de *hitch* e RAM de pico, imprime o relatório e fecha. Use o build **release** (o `-debug` suja a medição).

---

## Gerar o instalador

Produz um `Setup.exe` único que instala o editor com o **ffmpeg embutido** — o usuário final não precisa instalar nada.

**Pré-requisitos (uma vez):**

- **[Inno Setup](https://jrsoftware.org/isdl.php) 6.3+** — `winget install JRSoftware.InnoSetup`
- **`dist/ffmpeg.exe`** e **`dist/ffprobe.exe`** — um build **GPL win64** do ffmpeg (com `nvenc`/`nvdec`/`libx264`/`libvorbis`), copiados para a pasta `dist/`.
- **rc.exe** (Windows SDK) — compila o recurso do ícone.

**Gerar (um comando faz tudo):**

```powershell
powershell -ExecutionPolicy Bypass -File build-installer.ps1
```

O script compila o ícone (`icon.rc` → `icon.res`), recompila o `editor.exe` em release (sem console, com ícone), acha o `ISCC.exe` e gera o instalador em:

```
dist\Output\EditorDeVideo-Setup.exe
```

> A cada release, suba a versão em `setup.iss` (`#define MyAppVersion "1.0.1"`) para aparecer certo em "Adicionar ou remover programas".

**Licença:** o ffmpeg empacotado é **GPLv3** (por causa do `libx264`). O editor o invoca como processo separado (não linka → o editor não vira GPL), mas a redistribuição do binário exige incluir a licença (o instalador já mostra e instala `LICENSE-ffmpeg.txt`).

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
  - **Clipes curtos** (≤ 45 s e dentro do orçamento de RAM) são pré-decodificados **inteiros para a RAM** numa thread de fundo (`ffmpeg -f rawvideo -pix_fmt rgb24 …`), a **1280×720**. Play/seek = só indexar o frame e `UpdateTexture` → **seek instantâneo**.
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
| Resolução do preview | 1280×720 (`DEC_W`×`DEC_H`; streaming alterna 720p/360p) |
| Cache em RAM | ~45 s (`CACHE_BUDGET`), ~83 MB/s a 30 fps (o orçamento é ponderado por fps: clipe de 60 fps conta em dobro) |

---

## Estrutura do projeto

```
src/                # package main (odin build src)
  main.odin         # startup, loop, globais de UI
  process.odin      # Job Objects, PATH, temps, log F4
  export.odin       # filtergraph, workers, NVENC
  project.odin      # .ovp save/load, diálogos de projeto
  segs.odin         # Seg/FxSeg, corte, ripple, invariantes, undo
  audio.odin        # janela head/chunk, mix, preview de velocidade
  media.odin        # Clip, probe, import, cache, streaming
  preview.odin      # shaders, composite, crop, fullscreen
  ui.odin           # widgets, topbar, bin, painéis, modais
  timeline_ui.odin  # draw_timeline
  update.odin       # update() (input / drag / atalhos)
  *_test.odin       # testes (mesmo pacote)
  bench.odin        # modo -bench
  icon.png          # #load no main (ícone da janela)
editor.exe          # build release (sai na raiz)
editor_debug.exe    # build debug
build-installer.ps1 # recompila e gera o instalador (1 comando)
setup.iss           # script do Inno Setup (empacota editor + ffmpeg)
make_icon.py        # gera icon.ico / src/icon.png (Pillow)
icon.rc / icon.ico  # recurso do ícone embutido no .exe (instalador)
dist/               # payload do instalador (ffmpeg + Setup.exe) — não versionado
```

O formato de projeto `.ovp` guarda a proporção do canvas, os caminhos das mídias e os segmentos (com transform e áudio).
