package main

import rl "vendor:raylib"
import "base:intrinsics"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import win "core:sys/windows"

// ---------- vídeo / decode ----------
// base dos arquivos temporários (áudio/onda/frames). Preenchida no startup por init_paths()
// a partir do %TEMP% REAL da máquina — NÃO pode ser fixa: o editor roda em qualquer usuário.
AUDIO_BASE: string
EXE_DIR: string // pasta do .exe (heap, dono) — preenchida em init_paths; base do log de diagnóstico
DEC_W   :: 1280 // resolução do cache/preview (era 640×360 — borrava gravações de tela nítidas
DEC_H   :: 720  // 1080p reduzidas; 720p mata a cintilação do upscale. Custo: 4× RAM/frame).
DEC_FPS :: f32(30)
FRAME   :: DEC_W * DEC_H * 3 // bytes por frame (rgb24) — 720p = ~2.76 MB
// letterbox: preserva o aspecto da fonte e completa com barras pretas até DEC_W×DEC_H
// (mesmo tratamento que img_decode e a prévia do export já fazem). Sem isto, vídeo
// vertical/anamórfico era ESTICADO p/ 16:9 na textura e ficava distorcido.
DEC_VF  :: "scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2"
// --- qualidade da PRÉVIA de clipes STREAMING (longos): o decode ao vivo roda em
// 360p (Baixa, padrão — leve) ou 720p (Alta — mais nítido, ~4x os bytes/frame).
// SÓ afeta streaming; clipes curtos (cache em RAM) seguem sempre em DEC_W×DEC_H (720p).
// STREAM_LO é a res do Baixa — DESACOPLADA de DEC_W (que agora é 720p): sem isto, subir
// DEC_W jogava o Baixa do streaming pra 720p sem querer (dobrava o custo de decode).
// Toggle na barra do player. fbuf/scrub_buf/dup_buf são alocados no tamanho MÁX
// (720p) p/ a troca de qualidade nunca realocar buffer sob as threads de decode.
STREAM_LO_W :: i32(640)
STREAM_LO_H :: i32(360)
STREAM_HI_W :: i32(1280)
STREAM_HI_H :: i32(720)
STREAM_FBYTES_MAX :: int(STREAM_HI_W) * int(STREAM_HI_H) * 3
// false = Baixa (360p); true = Alta (720p). Global (estilo NLE). PADRÃO = Alta: o cache dos
// clipes curtos é 720p (DEC_W×DEC_H), então deixar o streaming em 360p fazia clipe curto sair
// NÍTIDO e clipe longo BORRADO no mesmo projeto, sem motivo aparente. E não há custo real:
// medido neste arquivo (1080p h264, 4h) o decode ao vivo dá 321fps em 720p vs 264fps em 360p
// no NVDEC (a escala roda na GPU, o decode domina) e 431fps vs 569fps por software — ambos
// MUITO acima dos 30fps necessários. O toggle fica p/ máquinas fracas.
stream_hi: bool = true
stream_dw :: proc() -> i32 { return stream_hi ? STREAM_HI_W : STREAM_LO_W }
stream_dh :: proc() -> i32 { return stream_hi ? STREAM_HI_H : STREAM_LO_H }
// scrub (streaming): distância MÁX (s, no tempo da fonte) que o último frame decodificado
// pode estar do cursor antes de cair pra miniatura 256×144 do filmstrip. Era 1.5 fixo — curto
// demais: num arrasto lento fundo num vídeo de horas cada seek custa MAIS que 1.5s de
// movimento do playhead, então o worker nunca chegava a <1.5s e o preview vivia preso na
// miniatura borrada. 4s mantém o frame REAL (360/720p, levemente atrás do cursor) na tela
// enquanto o worker persegue. Saltos grandes com o player PARADO (clique-seek) passam de 4s
// e ainda mostram a miniatura na POSIÇÃO certa. No ARRASTO do cursor a miniatura NÃO entra
// no player (qualidade): fica o último frame nítido. Cache (clipes curtos) decodifica ao
// vivo — nunca cai aqui.
SCRUB_SHARP_S :: f32(4.0)
// scrub: acima desta latência (ms) de um decode de scrub por SOFTWARE, o clipe migra p/
// NVDEC no scrub (c.scrub_hw). 700ms é conservador: mesmo o pior init de cuvid (~575ms) +
// decode (~23ms) fica abaixo, então trocar SEMPRE melhora onde dispara (codec pesado).
// Codec leve (SW rápido) nunca cruza o limiar e segue em SW — sem disputar sessão NVDEC à toa.
SCRUB_HW_MS :: f64(700)

MAX_CLIPS     :: 12
DBG_PLAY      :: false // LOG de diagnóstico do playback a cada frame (stderr); ligue p/ depurar
DBG_SPV       :: false // LOG do preview de VELOCIDADE (WAV esticado): pedido, render e adoção
DBG_SEEK      :: false // LOG do relógio nos ~3s após um seek na barra do player
STREAM_OVER   :: 45  // clipes acima disso decodificam ao vivo (streaming), não em RAM
CACHE_BUDGET  :: 45  // teto de segundos (ponderado por fps) no cache RAM. Cortado de 180→45 ao
                     // subir o cache p/ 720p (4× bytes/frame): ~45s×30fps×2.76MB ≈ 3.7GB de teto,
                     // seguro nos 15.8GB da máquina. Clipes que não cabem viram streaming.
// orçamento GLOBAL de leituras bloqueantes do pipe de vídeo POR FRAME de UI (main
// thread): os limites de catch-up eram POR CLIPE (3 no clip_frame, 2 no dup_frame),
// então 3+ trilhas streaming empilhadas em catch-up simultâneo somavam 9+ decodes
// bloqueantes num único frame (>100ms: UI trava e o buffer de áudio esvazia). O teto
// compartilhado reparte: quem não coube alcança nos frames seguintes. 6 = 2 clipes
// em catch-up pleno; regime normal (30fps de vídeo em 60fps de UI) usa ~0.5/clipe.
READ_BUDGET  :: 6
READ_MS_MAX  :: f64(10) // teto de reads bloqueantes por chamada de clip_frame/dup_frame
g_read_budget: int // restante neste frame; reset no topo do update (só main thread)
HEAD_SECS     :: f32(60) // áudio em 2 estágios: head de N segundos toca já, resto vem depois
CHUNK_SECS    :: f32(300) // áudio sob demanda: seek além do coberto extrai um trecho deste tamanho ali (~1-2s; ~58MB)
// o áudio "completo" é extraído em PARTES deste tamanho (~317MB de WAV cada):
// um WAV monolítico de um vídeo de ~5h passa de 2GB, e o seek do raylib/dr_wav
// estoura o fseek de 32 bits além desse byte — lia a posição ERRADA (som bugado).
// WAV também tem teto rígido de 4GB (um vídeo de 6h+ nem caberia).
FULL_PART     :: f32(1800)
WAVE_PPS      :: 100  // buckets de pico por segundo na forma de onda (10ms de resolução)
WAVE_RATE     :: 8000 // taxa (Hz, mono) do PCM extraído só p/ a onda — deve casar com o "-ar" do ffmpeg
// ganho de EXIBIÇÃO do corpo RMS: o RMS de material normal fica em ~0.15-0.35 (bem abaixo do
// pico), então sem ganho o corpo sólido ficaria um fiapo. 2.8 deixa música cheia perto de 3/4
// da faixa, preservando a dinâmica (o contorno do pico, translúcido, marca o teto real).
WAVE_RMS_GAIN :: f32(2.8)
// miniatura: alimenta o filmstrip da trilha (desenhado pequeno) E o fallback de scrub no
// player (streaming: esticado a ~900px). 96×54 era ok na trilha mas virava um borrão de
// upscale ~9x no player durante o arrasto rápido; 256×144 (16:9) dá ~4x mais nitidez lá e
// mantém o mesmo layout do filmstrip (proporção idêntica). Custo de RAM: ~110KB/miniatura
// (pior caso ~47MB com 12 clipes streaming longos) — aceitável.
THUMB_W       :: 256
THUMB_H       :: 144
THUMB_FR      :: THUMB_W * THUMB_H * 3
THUMB_SIZE    :: "256x144"
THUMB_VF      :: "scale=256:144:force_original_aspect_ratio=decrease,pad=256:144:(ow-iw)/2:(oh-ih)/2" // letterbox (ver DEC_VF)

// aspecto (largura/altura) do CONTEÚDO da fonte (vw/vh); fallback = quadro DEC 16:9 quando as
// dimensões são desconhecidas (probe falhou, projeto antigo). É o "quadro" sobre o qual crop,
// transform e fit operam — não mais o 16:9 fixo do buffer DEC.
clip_ar :: proc(c: ^Clip) -> f32 {
	if c.vw > 0 && c.vh > 0 do return f32(c.vw) / f32(c.vh)
	return f32(DEC_W) / f32(DEC_H)
}

// sub-retângulo do frame DEC (DEC_W×DEC_H) ocupado pelo conteúdo REAL da fonte: o DEC_VF encaixa
// o vídeo com letterbox/pillarbox, então este recorte descarta as barras. Amostrado como "quadro da
// fonte" no compositing/crop → sem tarjas. Sem dims conhecidas: frame inteiro (comportamento antigo).
// dims de DECODE/textura do clipe: streaming em alta = c.dw/dh (720p); senão o quadro
// DEC padrão (640×360) — cache e o fallback de streaming baixa. Todo o resto (buffer,
// textura, source rect, VF do ffmpeg) deriva daqui p/ ficar sempre consistente.
cdw :: proc(c: ^Clip) -> i32 { return (c.streaming && c.dw > 0) ? c.dw : i32(DEC_W) }
cdh :: proc(c: ^Clip) -> i32 { return (c.streaming && c.dh > 0) ? c.dh : i32(DEC_H) }
cframe :: proc(c: ^Clip) -> int { return int(cdw(c)) * int(cdh(c)) * 3 } // bytes rgb24 de 1 frame

// filtro scale+letterbox p/ o clipe. Baixa/cache usa a constante DEC_VF; streaming em
// alta gera o filtro p/ c.dw×c.dh. buf = stack do chamador (procs de decode rodam em
// threads de vida longa, sem temp allocator) — a string retornada vive só na chamada.
dec_vf_of :: proc(c: ^Clip, buf: []u8) -> string {
	w, h := cdw(c), cdh(c)
	if w == i32(DEC_W) && h == i32(DEC_H) do return DEC_VF
	return fmt.bprintf(buf, "scale=%d:%d:force_original_aspect_ratio=decrease,pad=%d:%d:(ow-iw)/2:(oh-ih)/2", w, h, w, h)
}

dec_content_rect :: proc(c: ^Clip) -> rl.Rectangle {
	dw, dh := f32(cdw(c)), f32(cdh(c))
	if c.vw <= 0 || c.vh <= 0 do return { 0, 0, dw, dh }
	ar := clip_ar(c)
	dec_ar := dw / dh
	cw, ch := dw, dh
	if ar <= dec_ar do cw = dh * ar; else do ch = dw / ar
	return { (dw-cw)/2, (dh-ch)/2, cw, ch }
}

// --- scrub assíncrono (clipes streaming): decodifica o frame numa thread de
// fundo, então arrastar o cursor não bloqueia a UI (que fica suave) ---
scrub_buf:    []u8          // 1 frame decodificado pelo worker
scrub_req_c:  int = -1      // atômico: clipe a decodificar (-1 = ocioso)
scrub_req_t:  f32           // tempo alvo (leitura possivelmente "torn"; inofensivo)
scrub_ready:  bool          // atômico: scrub_buf tem frame pronto p/ upload (main)
scrub_done_c: int           // clipe do frame pronto em scrub_buf
scrub_done_t: f32           // tempo (na fonte) pedido p/ esse frame — vira c.tex_t na adoção
scrub_done_sf:int           // bytes/frame com que o worker decodificou — a main só sobe o
                            // frame se bater com cframe() ATUAL (troca de qualidade Alta/Baixa
                            // no meio do decode deixava um frame de dims velhas: imagem embaralhada)
scrub_last_ms:f64           // duração do último decode de scrub (diagnóstico, HUD F3)
scrub_run:    bool          // atômico: worker ativo
scrub_thr:    ^thread.Thread

// --- vista DUPLICADA por segmento: quando a MESMA fonte aparece em 2+ trilhas de
// vídeo sob o playhead, um Clip só (1 textura, 1 decoder) não serve 2 tempos — as
// camadas mostravam o mesmo frame e, em streaming, os alvos alternados respawnavam
// o ffmpeg em loop (imagem congelada/piscando). O seg de trilha mais BAIXA fica com
// o caminho normal (c.tex); os de cima viram "dup" com textura própria: fonte em
// cache decodifica direto da RAM (30fps), streaming pede 1 frame ao worker de scrub
// (async, ~4-6fps — atrasa um pouco, mas estável). ---
SegDup :: struct {
	tex:   rl.Texture2D,
	ok:    bool, // textura criada
	tw, th: i32, // dims com que d.tex foi criada — dup_upload recria se a fonte/qualidade mudar
	src:   int,  // fonte do conteúdo na textura (slot é por índice de seg, que desloca)
	shown: int,  // frame do cache na textura (evita re-upload)
	has:   f32,  // tempo de fonte do frame na textura (streaming)
	// decoder ao vivo PRÓPRIO da vista (fonte streaming): espelho do live stream do
	// clipe — spawn assíncrono no worker de scrub, catch-up lido na main a 30fps
	lon:    bool,       // pipe ativo
	lps:    os.Process, // ffmpeg da vista
	lr:     ^os.File,   // ponta de leitura do pipe
	lbase:  f32,        // tempo de fonte do frame 0 do decoder
	lframe: int,        // frames já lidos deste decoder
	lfps:   f32,        // -r deste decoder (0 = DEC_FPS); casa com speed do seg
	leof:   f32,        // fim real detectado (0 = desconhecido); congela em vez de respawnar em loop
}
seg_dup:     [MAX_SEGS]SegDup
dup_buf:     []u8       // 1º frame lido pelo WORKER no spawn (só o worker escreve)
dup_rd_buf:  []u8       // frames do catch-up lidos pela MAIN (buffers separados: sem corrida)
dup_req_c:   int = -1   // atômico: clipe a spawnar (-1 = ocioso); main publica por último
dup_req_t:   f32        // tempo alvo na fonte
dup_req_fps: f32        // -r pedido (speed do seg)
dup_req_si:  int = -1   // segmento que pediu (só a main lê/escreve)
dup_req_start: f32      // identidade do seg no pedido: start/in_off (validados na adoção —
dup_req_inoff: f32      // remover um seg compacta o array e o MESMO índice vira OUTRO seg)
dup_ready:   bool       // atômico: spawn terminou (main adota processo+frame e libera)
// `dup_req_c` NÃO serve de flag de "spawn em voo": dois pontos o zeram à força para impedir
// o worker de COMEÇAR um decode novo (stream_quality_sync na troca de qualidade e
// remove_media), e com ele zerado um pedido novo passava pela guarda e sobrescrevia os
// metadados. O spawn antigo chegava depois e era validado contra o pedido NOVO — como o
// segmento costuma ser o mesmo, passava, e a main adotava um ffmpeg da resolução ANTIGA
// (dup_read passava a pedir frames do tamanho errado de um pipe que produz outro).
dup_inflight: bool      // atômico: há um spawn pedido e ainda não consumido pelo dup_poll
dup_req_seq:  int       // atômico: carimbo do pedido ATUAL — muda a cada pedido e a cada
dup_sp_seq:   int       // cancelamento; o worker guarda aqui o que estava servindo, e o
                        // dup_poll só adota se os dois baterem
dup_sp_ps:   os.Process // staging do spawn: processo entregue pelo worker
dup_sp_r:    ^os.File   // staging: ponta de leitura
dup_sp_on:   bool       // staging: spawn entregou decoder vivo com 1º frame em dup_buf

// Uma mídia importada: fonte de vídeo + áudio. Fica no bin; pode ser colocada
// na timeline (placed). A importação roda numa thread de fundo (não congela).
Clip :: struct {
	path:   string, // caminho (heap, dono)
	name:   string, // basename (heap, dono)
	name_el: cstring, // nome truncado p/ o bin, cacheado (heap, dono) — elide re-mede a fonte glifo a glifo, caro p/ rodar todo frame
	vcodec: string, // codec do vídeo via ffprobe (heap, dono) — escolhe o decoder NVDEC
	no_hw:  bool,   // NVDEC recusou este clipe (perfil/sessões): decodifica por software.
	                // NÃO é permanente: recusa por PRESSÃO de sessões é transitória —
	                // use_cuvid re-tenta o hardware após 30s (no_hw_tk) e o sucesso cura
	no_hw_tk: time.Tick, // quando a recusa foi marcada (janela de 30s de software)
	scrub_hw: bool, // (worker de scrub) usar NVDEC no decode de scrub deste clipe. O scrub
	                // decodifica em SW por padrão (num codec leve o init do cuvid > o decode),
	                // mas migra p/ HW quando um decode SW passa de SCRUB_HW_MS: em codec pesado
	                // (AV1/HEVC/4K) o SW leva ~1-2s/keyframe e o HW, mesmo pagando o init, ~0.6s.
	scrub_hw_bad: bool, // o NVDEC falhou no scrub deste clipe: NUNCA mais tenta HW no scrub (evita
	                    // religar/oscilar). CRÍTICO: uma falha de scrub NÃO chama hw_reject (que
	                    // marcaria no_hw e derrubaria o DECODER AO VIVO p/ software = playback travado);
	                    // só desliga o HW do scrub. O decoder ao vivo tem seu próprio caminho hw/sw.
	aid:    int,    // id único p/ nomear o áudio temporário
	dur:    f32,    // duração total da fonte (s)
	vw, vh: i32,    // dimensões de EXIBIÇÃO da fonte (já corrigidas por rotação); 0 = desconhecido. Autodetecta proj_ar
	tex:    rl.Texture2D,
	tex_ok: bool,
	tw, th: i32,    // dims com que c.tex foi criada — upload_tex recria se cdw/cdh mudar (troca de qualidade)
	dw, dh: i32,    // dims de DECODE deste clipe STREAMING (0 = cache/baixa → DEC_W/DEC_H). Vide stream_hi/cdw
	// --- importação assíncrona ---
	job:      win.HANDLE, // Job Object PRÓPRIO: fechar mata TODOS os ffmpeg deste clipe
	                      // de uma vez (destrava reads bloqueados) ao remover/fechar
	imp_thr:  ^thread.Thread,
	probed:   bool,   // atômico: duração/modo/1º frame prontos
	failed:   bool,   // atômico: arquivo inválido (ou removido do bin — vira tombstone)
	closed:   bool,   // (main) clip_close já liberou os recursos deste slot (evita liberar 2x)
	notified: bool,   // (main) já avisou pronto/falhou
	autoplace: bool,  // (main) coloca na timeline assim que a duração for conhecida
	seg_made:  bool,  // (main) o segmento do autoplace já foi criado
	aud_path: string, // caminho do áudio WAV completo (heap, dono)
	ogg_done: bool,   // atômico: extração completa terminou
	ogg_ok:   bool,   // atômico: extração completa deu certo
	// áudio em 2 estágios (clipes streaming): head de HEAD_SECS fica pronto em
	// ~1s e já toca; é trocado pelo WAV completo quando a extração termina
	aud_head:  string, // caminho do WAV parcial (heap, dono)
	head_done: bool,   // atômico: extração do head terminou
	head_ok:   bool,   // atômico: extração do head deu certo
	head_dur:  f32,    // segundos cobertos pelo head
	// áudio completo em PARTES de FULL_PART s (arquivos `aud_path` + "_pNNN.wav"),
	// extraídas em sequência por parts_worker; prontas progressivamente
	parts_thr:  ^thread.Thread,
	nparts:     int, // total de partes (escrito no import antes do spawn)
	parts_done: int, // atômico: partes 0..parts_done-1 estão prontas no disco
	// --- áudio sob demanda (janela móvel): cobre seeks além do head enquanto o
	// WAV completo não fica pronto (vídeos de horas demoram ~30s+ p/ extrair) ---
	aud_ck:     [2]string, // 2 slots de WAV parcial (heap, dono) — alterna p/ nunca sobrescrever o que está tocando
	chunk_thr:  ^thread.Thread,
	chunk_slot: int,  // slot do pedido ATUAL (worker escreve aud_ck[chunk_slot])
	music_slot: int,  // slot do chunk aberto em c.music (-1 = head/parte) — o dr_wav
	                  // segura o arquivo mesmo pausado; regravar esse slot vira ruído
	chunk_req:  f32,  // base (s, na fonte) pedida ao worker
	chunk_base: f32,  // base coberta pelo chunk PRONTO (worker escreve antes do done)
	chunk_done: bool, // atômico: extração do chunk terminou
	chunk_ok:   bool, // atômico: extração do chunk deu certo
	chunk_busy: bool, // (main) worker no ar
	aud_end:    f32,  // ponto (s, na fonte) a partir do qual se PROVOU não haver áudio: um chunk
	                  // extraído ali voltou só com cabeçalho. 0 = nada provado. Faixa de áudio
	                  // mais curta que o vídeo é o caso comum (o mic para antes do fim).
	chunk_meas: bool, // a cobertura abaixo já foi MEDIDA? (false = usa o nominal CHUNK_SECS)
	chunk_cov:  f32,  // segundos REAIS cobertos pelo chunk no bolso, medidos ao abri-lo. O
	                  // ffmpeg entrega menos que -t quando o áudio acaba antes; sem isto o
	                  // intervalo nominal dizia "coberto" e o chunk era reaberto a cada
	                  // frame. Os dois campos separados porque 0 é cobertura VÁLIDA (arquivo
	                  // vazio = não cobre nada) e também o valor zero de um Clip novo.
	music_base: f32,  // offset (na fonte) do stream ATIVO em c.music (0 = head/completo)
	music_full: bool, // o stream ATIVO é o part_path(c,0) completo? Distingue do head sem
	                  // comparar durações — áudio mais curto que o vídeo faz o completo
	                  // PARECER head e o código o trocava por ele mesmo, todo frame
	// --- forma de onda (calculada do áudio em thread de fundo) ---
	// DOIS envelopes por bucket, como nos NLEs: o PICO vira o contorno claro e o RMS (energia
	// média) o corpo sólido. Só pico não serve: música moderna é comprimida e o pico fica ~1.0
	// em quase todo bucket de 10ms -> a onda virava um BLOCO CHEIO, sem dinâmica visível.
	wave:       []f32, // pico [0,1] por bucket, WAVE_PPS buckets/seg (heap, dono)
	wave_rms:   []f32, // RMS [0,1] por bucket (mesmo tamanho/índice de wave)
	wave_ready: bool,  // atômico: envelope pronto p/ desenhar
	// --- tira de miniaturas (filmstrip) na trilha de vídeo ---
	thumb_px:       []u8,           // pixels de nthumbs frames (heap; liberado após upload)
	nthumbs:        int,            // nº de miniaturas geradas
	thumb_dt:       f32,            // segundos de fonte por miniatura
	thumbs_decoded: bool,           // atômico: thumb_px pronto p/ upload (main)
	thumbs:         []rl.Texture2D, // texturas (main thread, dono)
	thumbs_up:      int,            // quantas já subiram (upload progressivo, evita hitch)
	thumbs_ready:   bool,           // (main) todas as texturas prontas
	// --- modo cache (clipes curtos): todos os frames em RAM ---
	streaming: bool,
	cfps:   f32, // fps do cache: segue a fonte (teto 60). 0 = streaming/imagem (usa DEC_FPS)
	// passo TRAVADO no vsync (anti-beat) do playback em cache — ver clip_frame. pframe = frame
	// exibido; pframe_tick = g_frame_no em que foi decidido (gate de 1 decisão/frame de render
	// E detector de continuidade: se o clipe não foi exibido no frame anterior, reancora).
	pframe:      int,
	pframe_tick: i64,
	total:  int,
	cached: int, // atômico
	shown:  int,
	cache:  []u8,
	dec_ps:  os.Process, // decoder do cache (thread de fundo)
	dec_r:   ^os.File,
	dec_run: bool, // atômico
	stop:    bool, // atômico
	thr:     ^thread.Thread,
	// --- modo streaming (clipes longos): decode de vídeo ao vivo ---
	fbuf:      []u8, // um frame
	live_ps:   os.Process,
	live_r:    ^os.File,
	live_on:   bool,
	live_hw:   bool, // o decoder ao vivo ATUAL é NVDEC (hardware)? p/ distinguir um EOF
	                 // REAL de uma recusa do NVDEC no meio do stream (fallback p/ software)
	live_base: f32, // -ss atual (segundos)
	live_frame:int, // frames lidos desde o respawn
	live_fps:  f32, // taxa de SAÍDA do decoder atual (-r). 0 = DEC_FPS. A speed!=1
	                // baixa isto (2x → 15fps) p/ a main ler a MESMA qtde de frames/s
	                // de parede que em 1x — senão o pipe a 30fps de fonte exigia o
	                // dobro de reads bloqueantes e o atraso >1.5s virava respawn em
	                // loop (UI travada / vídeo congelado só de assistir em 2x).
	tex_t:     f32, // tempo (s, na fonte) do frame ATUALMENTE em c.tex — o draw usa p/
	                // saber se o frame mostrado está longe do alvo (scrub/seek em voo)
	                // e cair pra miniatura do ponto certo em vez de congelar no velho
	eof_at:    f32, // fim REAL do stream (s), visto ao ler 0 frames; 0 = desconhecido.
	                // A duração do container (ffprobe) pode passar dos frames reais —
	                // sem isto, o fim do clipe respawnava o ffmpeg em loop p/ sempre.
	// respawn ASSÍNCRONO do decoder ao vivo: matar+spawnar o ffmpeg e ler o 1º
	// frame bloqueia ~250ms — na main thread isso esvaziava o buffer de áudio a
	// cada seek (picote). Um worker faz o respawn; o vídeo congela o frame atual.
	rsp_thr:  ^thread.Thread,
	rsp_t:    f32,  // alvo (s) do respawn pendente
	rsp_fps:  f32,  // -r pedido neste respawn (main escreve; worker lê)
	rsp_t0:   f64,  // quando foi pedido (p/ medir a latência no overlay)
	rsp_busy: bool, // atômico: worker é o DONO do live stream (main não toca)
	rsp_done: bool, // atômico: novo decoder pronto, 1º frame em fbuf
	// áudio (WAV em disco; funciona p/ qualquer duração)
	music:     rl.Music,
	has_audio: bool, // existe um rl.Music CARREGADO AGORA. É estado do player: oscila a cada
	                 // troca de janela (head -> chunk -> completo) e nasce false. NÃO use p/
	                 // decidir se a mídia tem som — use src_audio.
	src_audio: bool, // a FONTE tem faixa de áudio. Vem do probe, publicado antes de `probed`,
	                 // e não muda mais. É o que o export precisa: ele monta [N:a] a partir do
	                 // arquivo ORIGINAL e não depende de extração nenhuma.
	is_img:    bool, // imagem estática (1 frame, sem áudio, duração livre na timeline)
	is_audio:  bool, // mídia só-áudio (mp3/wav/...): sem vídeo, vai p/ trilha de áudio
	mix_on:    bool, // (main) o music deste clipe está tocando como SECUNDÁRIO (mix)
	// --- clipe de TEXTO (título/legenda): sem arquivo, sem decode; renderizado pela
	// própria fonte no preview e por um PNG no export. Ocupa trilha de vídeo (overlay).
	is_text:    bool,
	text:       string,   // conteúdo (heap, dono, UTF-8)
	text_size:  f32,      // altura da fonte como fração da altura do canvas (0.10 = 10%)
	text_color: rl.Color,
	text_font:  int,      // índice em text_fonts (0 = Segoe UI)
	// faixa de LEGENDAS: um clipe de texto com várias falas cronometradas (tempo de FONTE).
	// Evita estourar MAX_CLIPS/MAX_SEGS — voz-pra-texto vira UMA faixa, não 80 títulos.
	is_caps: bool,
	caps:    [dynamic]CapCue,
	// look das legendas (YouTube / CapCut / …). Zero = sombra suave (títulos e .ovp antigos).
	cap_preset:  CapPreset,
	cap_stroke:  f32,      // espessura do contorno, fração do tamanho da fonte
	cap_box:     f32,      // opacidade da caixa 0..1 (0 = sem caixa)
	cap_box_col: rl.Color, // cor da caixa / marcador
	cap_upper:   bool,     // desenha em MAIÚSCULAS
}

CapPreset :: enum u8 { Shadow, YouTube, CapCut, Marker }

// uma fala da faixa de legendas. t0/t1 são tempo na FONTE do vídeo transcrito.
CapCue :: struct {
	t0, t1: f32,
	text:   string, // heap, dono
}

clips:     [MAX_CLIPS]Clip
nclips:    int
play_clip: int = -1 // SEGMENTO cujo áudio (da fonte) é o relógio durante o playback
// seek feito FORA do bloco de playback neste frame (ex.: seek_global ao soltar o
// playhead): GetMusicTimePlayed só assenta após o próximo UpdateMusicStream —
// até lá o playback confia em seek_pending_loc (senão lia a posição ANTIGA:
// se ela caía além do fim do segmento, tratava como "acabou" -> mutava e
// jogava o playhead pro fim).
seek_pending:     bool
seek_pending_loc: f32
// após um seek: o Play da posição nova espera o PRÓXIMO frame. Stop+Play no
// mesmo instante deixava o sub-buffer velho (~0.7s, 2×16384) no mixer SOMANDO
// com o pré-enchimento do ponto novo = dois áudios por um instante.
seek_rearm_si:  int = -1
seek_rearm_loc: f32
audio_hush_at:  i64 = -1 // g_frame_no do último hush_all_music
clip_seq:  int      // contador p/ ids únicos

// ---------- probe ----------
// retorna duração, codec e dimensões de exibição do vídeo (codec aponta p/ memória temp;
// clonar p/ guardar). Saída chaveada (`chave=valor`) p/ separar w/h/duração sem ambiguidade.
// bitrate (bits/s) de um arquivo-fonte via ffprobe: pega o do stream de vídeo e o do
// container (format), retornando o MAIOR legível. 0 = desconhecido (muitos .mkv/.webm não
// expõem bit_rate do stream). Usado só no modo de export "Automático" p/ dimensionar o teto.
source_bitrate :: proc(path: string) -> int {
	_, out, _, e := os.process_exec(os.Process_Desc{
		command = []string{ "ffprobe", "-v", "error", "-select_streams", "v:0",
			"-show_entries", "stream=bit_rate:format=bit_rate", "-of", "default=nw=1:nokey=1", path },
	}, context.temp_allocator)
	if e != nil do return 0
	best := 0
	for ln in strings.split_lines(strings.trim_space(string(out)), context.temp_allocator) {
		v := strings.trim_space(ln)
		if v == "" || v == "N/A" do continue
		if n, ok := strconv.parse_int(v, 10); ok && n > best do best = n
	}
	return best
}

// maior bitrate entre as mídias de VÍDEO presentes na timeline (ignora texto/imagem/áudio).
// Base do teto de bitrate do export "Automático". Probe é síncrono, mas roda só no clique de
// exportar e sobre poucos arquivos — custo desprezível perto do render.
timeline_max_src_bitrate :: proc() -> int {
	best := 0
	for i in 0 ..< nsegs {
		if !seg_ready(i) do continue
		c := &clips[segs[i].src]
		if c.is_text || c.is_img || c.is_audio || segs[i].aonly do continue
		if b := source_bitrate(c.path); b > best do best = b
	}
	return best
}

video_probe :: proc(path: string) -> (dur: f32, codec: string, vw, vh: i32, fps: f32) {
	_, out, _, e := os.process_exec(os.Process_Desc{
		command = []string{
			"ffprobe", "-v", "error", "-select_streams", "v:0",
			"-show_entries", "stream=codec_name,width,height,avg_frame_rate,r_frame_rate:stream_side_data=rotation:stream_tags=rotate:format=duration",
			"-of", "default=nw=1", path,
		},
	}, context.temp_allocator)
	if e != nil do return
	return probe_parse(string(out))
}

// a fonte tem faixa de áudio? Uma pergunta sobre o ARQUIVO, respondida uma vez no import e
// guardada em c.src_audio. Saída vazia = sem stream de áudio (o -select_streams a:0 não casa
// nada). Erro do ffprobe também devolve false: o export apenas não emite a cadeia de áudio,
// que é o mesmo que acontecia antes deste campo existir.
probe_has_audio :: proc(path: string) -> bool {
	_, out, _, e := os.process_exec(os.Process_Desc{
		command = []string{
			"ffprobe", "-v", "error", "-select_streams", "a:0",
			"-show_entries", "stream=codec_name", "-of", "default=nw=1:nk=1", path,
		},
	}, context.temp_allocator)
	if e != nil do return false
	return len(strings.trim_space(string(out))) > 0
}

// fps a partir de "num/den" (avg_frame_rate/r_frame_rate do ffprobe) ou de um número solto.
// "0/0" (VFR sem info) e denominador zero devolvem 0.
parse_fps :: proc(s: string) -> f32 {
	if i := strings.index_byte(s, '/'); i >= 0 {
		n, nok := strconv.parse_f64(strings.trim_space(s[:i]))
		d, dok := strconv.parse_f64(strings.trim_space(s[i+1:]))
		if nok && dok && d > 0 do return f32(n / d)
		return 0
	}
	if v, ok := strconv.parse_f64(strings.trim_space(s)); ok do return f32(v)
	return 0
}

// parse da saída do ffprobe (formato `chave=valor`, uma por linha). Extrai duração, codec e
// dimensões de EXIBIÇÃO: com rotação de ±90/±270 (celular gravado deitado guarda os pixels
// 1920x1080 + rotation=-90) o ffmpeg auto-rotaciona no decode, então trocamos w/h p/ casar com
// o que o DEC_VF produz. "N/A" e linhas sem `=` são ignoradas.
probe_parse :: proc(out: string) -> (dur: f32, codec: string, vw, vh: i32, fps: f32) {
	rot := 0
	for ln in strings.split_lines(strings.trim_space(out), context.temp_allocator) {
		l := strings.trim_space(ln)
		eq := strings.index_byte(l, '=')
		if eq <= 0 do continue
		key := l[:eq]; val := strings.trim_space(l[eq+1:])
		if val == "" || val == "N/A" do continue
		switch {
		case key == "duration":   if v, ok := strconv.parse_f64(val);     ok do dur = f32(v)
		case key == "codec_name": codec = val
		case key == "width":      if v, ok := strconv.parse_int(val, 10); ok do vw = i32(v)
		case key == "height":     if v, ok := strconv.parse_int(val, 10); ok do vh = i32(v)
		// avg_frame_rate vem primeiro (média real, ideal p/ VFR); r_frame_rate só cobre
		// quando o avg falha ("0/0"). Ambos = fração "num/den".
		case key == "avg_frame_rate": if v := parse_fps(val); v > 0 do fps = v
		case key == "r_frame_rate":   if fps <= 0 { if v := parse_fps(val); v > 0 do fps = v }
		case key == "rotation" || strings.has_suffix(key, "rotate"):
			if v, ok := strconv.parse_int(val, 10); ok do rot = v
		}
	}
	if abs(rot) % 180 == 90 do vw, vh = vh, vw // ±90/±270: as dimensões de exibição se invertem
	return
}

// ---------- decode por GPU (NVDEC/cuvid) ----------
// Benchmark nesta máquina (RTX 4070, 1080p30 h264 -> rawvideo 640x360):
//   software:              wall 1.05s  cpu 5.41s
//   -hwaccel auto (d3d11): wall 2.02s  cpu 4.44s  <- PIOR: copia o frame 1080p GPU->CPU
//   h264_cuvid -resize:    wall 1.01s  cpu 1.69s  <- decode E escala na GPU, só o frame
//                                                    pequeno desce p/ a RAM (~3x menos CPU)
// Decoder explícito não tem fallback automático: se o NVDEC recusar (perfil não
// suportado, sessões esgotadas), o processo não entrega frame nenhum — cada ponto
// de spawn detecta isso, marca no_hw no clipe e refaz por software.
cuvid_of :: proc(codec: string) -> string {
	switch codec {
	case "h264":       return "h264_cuvid"
	case "hevc":       return "hevc_cuvid"
	case "vp9":        return "vp9_cuvid"
	case "vp8":        return "vp8_cuvid"
	case "av1":        return "av1_cuvid"
	case "mpeg2video": return "mpeg2_cuvid"
	case "mpeg4":      return "mpeg4_cuvid"
	}
	return ""
}

// decoder NVDEC a usar p/ o clipe ("" = software)
use_cuvid :: proc(c: ^Clip) -> string {
	if c.no_hw {
		// recusa por PRESSÃO de sessões (muitos streams NVDEC ao mesmo tempo) é
		// transitória: depois de 30s tenta o hardware de novo — o sticky antigo ia
		// desligando a GPU clipe a clipe conforme o uso e a sessão degradava p/
		// software sem volta. Codec realmente não-suportado só re-falha a cada 30s
		// (1 spawn perdido, barato). O sucesso limpa no_hw (stream_seek/dup_open).
		if time.duration_seconds(time.tick_diff(c.no_hw_tk, time.tick_now())) < 30 do return ""
	}
	return cuvid_of(c.vcodec)
}
// marca a recusa do NVDEC com carimbo de tempo (janela de 30s de software)
hw_reject :: proc(c: ^Clip) { c.no_hw = true; c.no_hw_tk = time.tick_now(); dbg("HWREJECT", "clip='%s' codec=%s -> no_hw por 30s (decoder AO VIVO passa a decodificar por SOFTWARE)", c.name, c.vcodec) }

// ---------- importação (assíncrona) ----------
// soma de segundos em cache (só clipes já-decididos e não-streaming)
// fps do cache do clipe (segue a fonte, teto 60); DEC_FPS quando não definido
cfps_of :: proc(c: ^Clip) -> f32 { return c.cfps > 0 ? c.cfps : DEC_FPS }

// taxa de SAÍDA do decoder ao vivo: DEC_FPS/speed. A 2x sai 15 fps (1 frame a cada
// 1/15 s da FONTE) → a main lê ~30 frames/s de parede, a mesma carga de 1x.
live_want_fps :: proc(spd: f32) -> f32 {
	s := spd <= 0.01 ? f32(1) : spd
	return clamp(DEC_FPS / s, 10, 60)
}
live_rate :: proc(c: ^Clip) -> f32 { return c.live_fps > 0 ? c.live_fps : DEC_FPS }
live_now  :: proc(c: ^Clip) -> f32 { return c.live_base + f32(c.live_frame) / live_rate(c) }
dup_rate  :: proc(d: ^SegDup) -> f32 { return d.lfps > 0 ? d.lfps : DEC_FPS }
dup_now   :: proc(d: ^SegDup) -> f32 { return d.lbase + f32(d.lframe) / dup_rate(d) }

// velocidade do segmento desta fonte que está sob o playhead (1 na prévia do bin).
clip_view_speed :: proc(c: ^Clip) -> f32 {
	if src_preview >= 0 && src_preview < nclips && &clips[src_preview] == c do return 1
	for t := g_nv - 1; t >= 0; t -= 1 {
		i := seg_on_track_at(t, st.playhead)
		if i >= 0 && seg_src(i) == c && !segs[i].aonly do return seg_speed(i)
	}
	for i in 0 ..< nsegs {
		if segs[i].src >= 0 && i < nsegs && seg_src(i) == c && !segs[i].aonly do return seg_speed(i)
	}
	return 1
}

cached_seconds :: proc() -> f32 {
	s: f32 = 0
	for i in 0 ..< nclips {
		c := &clips[i]
		// só o que realmente ocupa RAM de frames: áudio (sem vídeo), imagem (1 frame) e texto
		// (nenhum) publicam probed=true e streaming=false sem alocar cache, e antes entravam
		// no orçamento — um MP3 de 4 min sozinho estourava o teto de 45s e mandava todo vídeo
		// importado depois para streaming, com a RAM inteira livre.
		if c.is_audio || c.is_img || c.is_text do continue
		// pesa por fps: um clipe 60fps ocupa 2×/seg na RAM, então conta como 2× no orçamento
		if intrinsics.atomic_load(&c.probed) && !c.streaming do s += c.dur * cfps_of(c) / DEC_FPS
	}
	return s
}

// RESERVA do orçamento de cache. `cached_seconds()` só enxerga clipes que já publicaram
// `probed` — e `probed` é o ÚLTIMO passo do import, DEPOIS do make() do cache. Com N imports
// simultâneos (arrastar vários arquivos de uma vez dispara uma thread por arquivo) todas
// liam o mesmo total antigo e todas decidiam cachear: cada uma alocava até o teto que é
// GLOBAL, e 5 clipes de 45s pediam ~18GB numa máquina de 15.8GB. `cache_inflight` guarda os
// segundos já PROMETIDOS e ainda não publicados; decidir e prometer acontecem sob o mesmo
// mutex, então duas threads nunca gastam o mesmo espaço.
cache_mu:       sync.Mutex
cache_inflight: f32

// cabe `w` segundos (já ponderados por fps)? Se couber, RESERVA e devolve true.
cache_claim :: proc(w: f32) -> bool {
	sync.mutex_lock(&cache_mu); defer sync.mutex_unlock(&cache_mu)
	if cached_seconds() + cache_inflight + w > CACHE_BUDGET do return false
	cache_inflight += w
	return true
}
// devolve a reserva. publish=true entrega o custo para `cached_seconds()` no MESMO lock em
// que solta o inflight — sem isso existiria uma janela em que o clipe não conta em lugar
// nenhum e outra thread reservaria o espaço dele. publish=false = desistiu de cachear.
cache_unclaim :: proc(c: ^Clip, w: f32, publish: bool) {
	sync.mutex_lock(&cache_mu); defer sync.mutex_unlock(&cache_mu)
	if publish do intrinsics.atomic_store(&c.probed, true)
	cache_inflight = max(0, cache_inflight - w)
}

// slot de uma mídia JÁ importada com o mesmo caminho (viva: não fechada/falha), ou -1.
// Case-insensitive (caminhos do Windows). Ignora clipes de texto (sem arquivo).
find_media_by_path :: proc(path: string) -> int {
	if path == "" do return -1
	for i in 0 ..< nclips {
		c := &clips[i]
		if c.closed || c.is_text || intrinsics.atomic_load(&c.failed) do continue
		if strings.equal_fold(c.path, path) do return i
	}
	return -1
}

// importa `path`; se já estiver na bin, NÃO reimporta — só seleciona o existente. Devolve o
// slot (novo ou existente) e is_new=true quando importou de fato. Usado só nas importações
// interativas (diálogo/drag-drop); o load de projeto chama import_media direto (sem dedupe,
// senão os índices de mídia dos segmentos saem do lugar).
import_or_select :: proc(path: string, place: bool) -> (slot: int, is_new: bool) {
	if ex := find_media_by_path(path); ex >= 0 {
		bin_clear_marks(); bin_sel = ex; selected = -1 // realça o já-importado
		return ex, false
	}
	return import_media(path, place), true
}

// importa uma mídia: cria o slot na hora (aparece como "importando...") e faz
// todo o trabalho pesado (probe, decode, áudio) numa thread de fundo.
// place = true agenda a colocação na timeline assim que a duração for conhecida.
import_media :: proc(path: string, place: bool) -> int {
	// recicla um slot já removido (tombstone) — clip_close deixou-o sem threads vivas,
	// então reinicializá-lo é seguro; senão anexa um novo no fim.
	slot := -1
	for j in 0 ..< nclips do if clips[j].closed { slot = j; break }
	if slot < 0 {
		if nclips >= MAX_CLIPS { set_toast("Máximo de mídias atingido"); return -1 }
		slot = nclips; nclips += 1
	}
	c := &clips[slot]
	c^ = Clip{} // zera tudo (inclusive closed/failed) — slate limpo
	c.job = make_kill_job() // criado ANTES de qualquer worker: sem corrida na criação
	c.music_slot = -1 // nenhum chunk aberto (0 significaria "slot 0 preso")
	c.path = strings.clone(path)
	c.name = base_name(path)
	c.aid = clip_seq; clip_seq += 1
	// nome único por execução (PID + id): evita colidir com um .ogg de uma
	// sessão anterior que ficou travado no disco (ffmpeg daria "Permission denied").
	c.aud_path = fmt.aprintf("%s_%d_%d.wav", AUDIO_BASE, u32(win.GetCurrentProcessId()), c.aid)
	c.aud_head = fmt.aprintf("%s_%d_%d_head.wav", AUDIO_BASE, u32(win.GetCurrentProcessId()), c.aid)
	c.aud_ck[0] = fmt.aprintf("%s_%d_%d_ck0.wav", AUDIO_BASE, u32(win.GetCurrentProcessId()), c.aid)
	c.aud_ck[1] = fmt.aprintf("%s_%d_%d_ck1.wav", AUDIO_BASE, u32(win.GetCurrentProcessId()), c.aid)
	c.autoplace = place
	c.imp_thr = thread.create_and_start_with_poly_data(c, import_worker)
	return slot
}

// cria um clipe de TEXTO no bin (sem arquivo/thread; pronto na hora). `content`/estilo
// iniciais. Usado tanto pelo botão "Texto" quanto pelo load do projeto.
new_text_clip :: proc(content: string, size: f32, color: rl.Color) -> int {
	slot := -1
	for j in 0 ..< nclips do if clips[j].closed { slot = j; break }
	if slot < 0 {
		if nclips >= MAX_CLIPS { set_toast("Máximo de mídias atingido"); return -1 }
		slot = nclips; nclips += 1
	}
	c := &clips[slot]
	c^ = Clip{}
	c.music_slot = -1
	c.is_text = true
	c.text = strings.clone(content)
	c.text_size = size
	c.text_color = color
	c.name = strings.clone("Texto")
	c.aid = clip_seq; clip_seq += 1
	c.dur = IMG_DUR
	intrinsics.atomic_store(&c.probed, true) // sem decode: pronto imediatamente
	return slot
}

caps_free :: proc(c: ^Clip) {
	for q in c.caps do delete(q.text)
	delete(c.caps)
	c.caps = nil
	c.is_caps = false
}

// fala visível em `src_t` (tempo da fonte). Faixa vazia / fora de qualquer cue = "".
clip_text_at :: proc(c: ^Clip, src_t: f32) -> string {
	if c.is_caps && len(c.caps) > 0 {
		for q in c.caps {
			if src_t + 0.001 >= q.t0 && src_t < q.t1 do return q.text
		}
		return ""
	}
	return c.text
}

// cria a faixa de legendas no bin (is_text + is_caps). `cues` é copiado (textos clonados).
new_caps_clip :: proc(cues: []CapCue, size: f32, color: rl.Color, dur: f32) -> int {
	label := len(cues) > 0 ? cues[0].text : "Legendas"
	slot := new_text_clip(label, size, color)
	if slot < 0 do return -1
	c := &clips[slot]
	delete(c.name)
	c.name = strings.clone("Legendas")
	c.is_caps = true
	c.dur = max(dur, 0.1)
	c.caps = make([dynamic]CapCue)
	for q in cues {
		t := strings.trim_space(q.text)
		if t == "" do continue
		append(&c.caps, CapCue{ q.t0, q.t1, strings.clone(t) })
	}
	if len(c.caps) > 0 {
		delete(c.text)
		c.text = strings.clone(c.caps[0].text)
	}
	return slot
}

CAP_PRESET_NAME := [CapPreset]cstring{ .Shadow = "Sombra", .YouTube = "YouTube", .CapCut = "CapCut", .Marker = "Marca" }

cap_font_named :: proc(names: []string) -> int {
	for want in names {
		for f, i in text_fonts {
			if strings.equal_fold(string(f.name), want) do return i
		}
	}
	return -1
}

// aplica um look pronto (cor, caixa, contorno, maiúsculas). Tamanho e fonte
// acompanham o estilo; o usuário ainda pode ajustar depois no inspector.
cap_apply_preset :: proc(c: ^Clip, p: CapPreset) {
	c.cap_preset = p
	switch p {
	case .Shadow:
		c.text_color = rl.WHITE
		c.cap_stroke = 0
		c.cap_box = 0
		c.cap_box_col = {}
		c.cap_upper = false
		if c.text_size < 0.04 || c.text_size > 0.12 do c.text_size = 0.05
	case .YouTube:
		c.text_color = rl.WHITE
		c.cap_stroke = 0
		c.cap_box = 0.72
		c.cap_box_col = rl.Color{ 0, 0, 0, 255 }
		c.cap_upper = false
		c.text_size = 0.048
		c.text_font = 0
	case .CapCut:
		c.text_color = rl.WHITE
		c.cap_stroke = 0.11
		c.cap_box = 0
		c.cap_box_col = {}
		c.cap_upper = true
		c.text_size = 0.062
		if i := cap_font_named([]string{ "Arial Black", "Impact" }); i >= 0 do c.text_font = i
	case .Marker:
		c.text_color = rl.Color{ 16, 16, 20, 255 }
		c.cap_stroke = 0
		c.cap_box = 1
		c.cap_box_col = rl.Color{ 255, 224, 20, 255 }
		c.cap_upper = true
		c.text_size = 0.055
		if i := cap_font_named([]string{ "Arial Black", "Arial" }); i >= 0 do c.text_font = i
	}
	dirty = true
}

// atualiza o conteúdo de um clipe de texto (marca o projeto como não salvo — o undo só
// vê `segs`, então texto/estilo não são desfazíveis, mas precisam sujar p/ o "salvar?").
set_text_clip :: proc(c: ^Clip, s: string) {
	if c.text == s do return
	delete(c.text); c.text = strings.clone(s); dirty = true
}

// o rótulo do bin / timeline mostra a 1ª fala; mantém c.text alinhado.
caps_sync_label :: proc(c: ^Clip) {
	if !c.is_caps do return
	label := len(c.caps) > 0 ? c.caps[0].text : "Legendas"
	if c.text == label do return
	delete(c.text)
	c.text = strings.clone(label)
}

// troca o texto da fala `i`. `s` vazio não apaga — use cap_delete_at.
cap_set_text :: proc(cues: ^[dynamic]CapCue, i: int, s: string) -> bool {
	if i < 0 || i >= len(cues^) do return false
	t := strings.trim_space(s)
	if t == cues^[i].text do return false
	delete(cues^[i].text)
	cues^[i].text = strings.clone(t)
	return true
}

cap_delete_at :: proc(cues: ^[dynamic]CapCue, i: int) -> bool {
	if i < 0 || i >= len(cues^) do return false
	delete(cues^[i].text)
	ordered_remove(cues, i)
	return true
}

// insere em ordem de t0. Devolve o índice novo.
cap_insert :: proc(cues: ^[dynamic]CapCue, t0, t1: f32, s: string) -> int {
	a := min(t0, t1)
	b := max(t0, t1)
	if b - a < 0.05 do b = a + 2
	body := strings.trim_space(s)
	if body == "" do body = "Nova fala"
	i := 0
	for i < len(cues^) && cues^[i].t0 <= a do i += 1
	inject_at(cues, i, CapCue{ a, b, strings.clone(body) })
	return i
}

caps_set_text :: proc(c: ^Clip, i: int, s: string) -> bool {
	if !c.is_caps do return false
	if !cap_set_text(&c.caps, i, s) do return false
	caps_sync_label(c)
	dirty = true
	return true
}

caps_delete_at :: proc(c: ^Clip, i: int) -> bool {
	if !c.is_caps do return false
	if !cap_delete_at(&c.caps, i) do return false
	caps_sync_label(c)
	dirty = true
	return true
}

caps_insert :: proc(c: ^Clip, t0, t1: f32, s: string) -> int {
	if !c.is_caps do return -1
	i := cap_insert(&c.caps, t0, t1, s)
	caps_sync_label(c)
	dirty = true
	return i
}

// botão "Texto": cria o clipe e coloca um segmento na trilha de vídeo do TOPO (overlay),
// no playhead. Já seleciona p/ o usuário editar o conteúdo no inspector.
add_text :: proc() {
	slot := new_text_clip("Texto", 0.10, rl.WHITE)
	if slot < 0 do return
	tr := free_track_from(g_nv - 1) // trilha de vídeo mais alta = vence no compositing (fica por cima)
	if tr < 0 { set_toast("Trilha bloqueada"); return }
	start := free_start(tr, -1, st.playhead, clips[slot].dur)
	si := add_seg(slot, start, 0, clips[slot].dur, tr)
	if si < 0 { set_toast("Timeline cheia"); return }
	selected = si; bin_sel = -1; insp_tab = 0
	seek_global(st.playhead)
	set_toast("Texto adicionado — edite no painel à direita")
}

// Dissolve orgânico: se o clipe está encostado no anterior, dissolve custom no corte
// (opacidade + fumaça + borda irregular). Senão, overlay persistente com a mesma máscara.
apply_ghost :: proc(si: int) {
	if si < 0 || si >= nsegs do return
	if seg_speed(si) != 1 { set_toast("Dissolve orgânico não combina com velocidade alterada"); return }
	sg := &segs[si]
	tm := trans_max(si)
	if tm > 0.01 {
		sg.trans = min(1.2, tm)
		sg.trans_mode = 1
		set_toast("Dissolve orgânico aplicado")
	} else {
		sg.trans = 0
		sg.trans_mode = 1
		if sg.vfin < 0.15 do sg.vfin = min(1, sg.dur*0.4)
		set_toast("Dissolve orgânico: overlay com máscara de textura")
	}
}

// tipos de transição do painel: 0 = dissolver | 1 = fade de entrada | 2 = fade de saída
// | 3 = dissolve orgânico (opacidade + fumaça / overlay com máscara).
apply_transition :: proc(kind: int) {
	if selected < 0 || selected >= nsegs { set_toast("Selecione um clipe na timeline primeiro"); return }
	sg := &segs[selected]
	if seg_audio_like(selected) { set_toast("Transições são p/ vídeo/imagem/texto"); return }
	switch kind {
	case 0: // dissolver com o clipe anterior adjacente
		if seg_speed(selected) != 1 { set_toast("Dissolver não combina com velocidade alterada"); return }
		tm := trans_max(selected)
		if tm <= 0.01 { trans_deny_toast(selected); return }
		sg.trans = min(1, tm)
		sg.trans_mode = 0
		set_toast("Dissolver aplicado")
	case 3: // dissolve orgânico no corte, ou overlay com máscara se não houver vizinho
		apply_ghost(selected)
	case 1: // fade de entrada (do preto)
		sg.vfin = clamp(1, 0.1, sg.dur*0.8); set_toast("Fade de entrada aplicado")
	case 2: // fade de saída (p/ o preto)
		sg.vfout = clamp(1, 0.1, sg.dur*0.8); set_toast("Fade de saída aplicado")
	}
	insp_tab = 0 // mostra os controles no inspector p/ ajustar a duração
}

// aplica uma transição SOLTA sobre o segmento si na posição `time` (arrastar do painel).
// Dissolver escolhe o corte mais próximo (esquerda = com o anterior; direita = com o próximo).
apply_transition_at :: proc(si, kind: int, time: f32) {
	if si < 0 || si >= nsegs || seg_audio_like(si) { set_toast("Solte sobre um clipe de vídeo/imagem/texto"); return }
	sg := segs[si]
	target := si
	if kind == 0 { // dissolver: corte da esquerda (this) ou da direita (próximo)?
		if time > sg.start + sg.dur/2 {
			if nx := seg_on_track_at(sg.track, sg.start + sg.dur + 0.01); nx >= 0 do target = nx
		}
		if seg_speed(target) != 1 { set_toast("Dissolver não combina com velocidade alterada"); return }
		tm := trans_max(target)
		if tm <= 0.01 { trans_deny_toast(target); return }
		segs[target].trans = min(1, tm)
		segs[target].trans_mode = 0
		set_toast("Dissolver aplicado")
	} else if kind == 3 {
		if time > sg.start + sg.dur/2 {
			if nx := seg_on_track_at(sg.track, sg.start + sg.dur + 0.01); nx >= 0 do target = nx
		}
		apply_ghost(target)
	} else if kind == 1 {
		segs[target].vfin = clamp(1, 0.1, sg.dur*0.8); set_toast("Fade de entrada aplicado")
	} else {
		segs[target].vfout = clamp(1, 0.1, sg.dur*0.8); set_toast("Fade de saída aplicado")
	}
	selected = target; bin_sel = -1; insp_tab = 0
}

// TELA DIVIDIDA: uma célula do layout, em coords normalizadas do canvas — (cx,cy) = centro
// como fração do canvas a partir do MEIO (0,0 = centro); (w,h) = tamanho como fração do canvas.
SplitCell :: struct { cx, cy, w, h: f32 }

// layouts de tela dividida (kind). Limitados às g_nv fontes sobrepostas (trilhas de vídeo):
// 0 = 2 lado a lado | 1 = 2 empilhado | 2 = 3 colunas | 3 = PiP (fundo cheio + canto).
@(rodata) split_cells_sidebyside := [?]SplitCell{ {-0.25,0,0.5,1}, {0.25,0,0.5,1} }
@(rodata) split_cells_stacked    := [?]SplitCell{ {0,-0.25,1,0.5}, {0,0.25,1,0.5} }
@(rodata) split_cells_thirds     := [?]SplitCell{ {-1.0/3,0,1.0/3,1}, {0,0,1.0/3,1}, {1.0/3,0,1.0/3,1} }
// PiP: célula[0] = CANTO (inset) e célula[1] = fundo cheio. A ordem importa: picks[0] é o
// clipe da trilha MAIS ALTA (desenhada por cima no composite), então o inset tem de ser a
// célula[0] p/ ficar visível sobre o fundo — senão o fundo cheio o cobriria.
@(rodata) split_cells_pip        := [?]SplitCell{ {0.30,-0.28,0.32,0.32}, {0,0,1,1} }
split_cells :: proc(kind: int) -> []SplitCell {
	switch kind {
	case 0: return split_cells_sidebyside[:]
	case 1: return split_cells_stacked[:]
	case 2: return split_cells_thirds[:]
	case 3: return split_cells_pip[:]
	}
	return nil
}

// encaixa um segmento numa célula: corta (crop) a fonte até o aspecto da célula (sem barra
// preta) e ajusta escala/posição p/ preencher exatamente. Reaproveita o render de crop+transform
// que já existe (e, por isso, exporta nativamente via seg_export_dims).
place_in_cell :: proc(sg: ^Seg, c: SplitCell) {
	r := (c.w / c.h) * proj_ar          // aspecto da célula na tela
	sg.scale = r <= proj_ar ? c.h : c.w // preenche (altura- ou largura-limitado, casando com `tf` do draw)
	sg.px = c.cx; sg.py = c.cy; sg.rot = 0
	// crop centrado p/ a região amostrada ter o MESMO aspecto da célula
	ratio := r / clip_ar(&clips[sg.src]) // = crop_w/crop_h desejado (relativo ao aspecto da fonte)
	cw, ch: f32 = 1, 1
	if ratio <= 1 { cw = ratio } else { ch = 1.0/ratio }
	sg.crop_w = cw; sg.crop_h = ch
	sg.crop_x = (1-cw)/2; sg.crop_y = (1-ch)/2
	sg.zoom_anim = false // split é recorte estático; desliga o Pan & Zoom se estava ligado
}

// aplica um layout de tela dividida aos segmentos de vídeo sobrepostos no playhead, do topo
// (V3) p/ a base (V1). Precisa de tantos segmentos quantas células o layout tem.
apply_split :: proc(kind: int) {
	cells := split_cells(kind)
	if len(cells) == 0 do return
	picks: [MAXV]int; np := 0
	for tr := g_nv-1; tr >= 0; tr -= 1 {
		si := seg_on_track_at(tr, st.playhead)
		if si >= 0 && !seg_audio_like(si) { picks[np] = si; np += 1 }
		if np >= len(cells) do break
	}
	if np < len(cells) {
		set_toast("Ponha os clipes em trilhas separadas, sobrepostos no playhead")
		return
	}
	for k in 0 ..< len(cells) do place_in_cell(&segs[picks[k]], cells[k])
	// ÁUDIO: só a trilha BASE (o fundo, no PiP) toca — picks está do topo p/ a base, então
	// picks[np-1] é a mais baixa. Silencia os overlays: dois áudios longos sobrepostos
	// sobrecarregam o audio_secondary (re-seek por frame) e travam/picotam o playback.
	// Convenção de editor (overlay entra mudo); reversível pelo botão de mudo no inspector.
	for k in 0 ..< len(cells)-1 do segs[picks[k]].muted = true
	segs[picks[len(cells)-1]].muted = false
	selected = picks[0]; bin_sel = -1; insp_tab = 0
	set_toast("Tela dividida aplicada (áudio: trilha base)")
}

// dispara o decoder do cache em RAM. SOFTWARE de propósito (NÃO cuvid/NVDEC): o NVDEC lida mal
// com o timestamp de certos streams h264 e, com `-r`, produz CONTAGEM de frames ERRADA — ex.:
// gravação OBS 60fps de 1218 frames vira 1221 no cuvid+`-r 60` (3 frames duplicados fora de
// lugar), enquanto o software dá 1218 exatos. O cache indexa `int(t*fps)` assumindo dur*fps frames
// UNIFORMES; frames extras desalinham do relógio de áudio = JUDDER (só nesse arquivo — re-encode e
// VLC ficam lisos porque não passam por cuvid+`-r`). O cache decodifica 1× em background, então
// trocar a velocidade do NVDEC pela correção do software compensa. `-threads 2`: não toma todos os
// cores durante o playback. (streaming/scrub seguem usando NVDEC — lá o decode é por -ss, não índice.)
cache_dec_start :: proc(c: ^Clip) -> bool {
	r, w, e := os.pipe()
	if e != nil do return false
	rb: [16]u8
	fps_s := fmt.bprintf(rb[:], "%.5f", cfps_of(c)) // fps do cache = fps da fonte (cap 60)
	cmd := []string{
		"ffmpeg", "-hide_banner", "-loglevel", "error", "-threads", "2", "-i", c.path,
		"-vf", DEC_VF, "-f", "rawvideo", "-pix_fmt", "rgb24", "-r", fps_s,
		"-an", "-sn", "pipe:1",
	}
	p, pe := os.process_start(os.Process_Desc{ command = cmd, stdout = w })
	os.close(w)
	if pe != nil { os.close(r); return false }
	tame_process(c, p, false)
	c.dec_ps = p; c.dec_r = r; c.dec_run = true
	return true
}

IMG_DUR :: f32(5) // duração padrão de uma imagem na timeline (s) — extensível ao aparar

// o arquivo é uma imagem estática? (pela extensão)
is_image_path :: proc(path: string) -> bool {
	low := strings.to_lower(path, context.temp_allocator)
	for ext in ([]string{ ".png", ".jpg", ".jpeg", ".bmp", ".gif", ".webp", ".tif", ".tiff" }) {
		if strings.has_suffix(low, ext) do return true
	}
	return false
}

// o arquivo é só-áudio? (pela extensão)
is_audio_path :: proc(path: string) -> bool {
	low := strings.to_lower(path, context.temp_allocator)
	for ext in ([]string{ ".mp3", ".wav", ".ogg", ".m4a", ".aac", ".flac", ".opus", ".wma", ".aiff", ".aif" }) {
		if strings.has_suffix(low, ext) do return true
	}
	return false
}

// duração (s) de um arquivo de áudio via ffprobe (format=duration, sem stream de vídeo)
audio_probe_dur :: proc(path: string) -> f32 {
	_, out, _, e := os.process_exec(os.Process_Desc{
		command = []string{ "ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nokey=1", path },
	}, context.temp_allocator)
	if e != nil do return 0
	if v, ok := strconv.parse_f64(strings.trim_space(string(out))); ok do return f32(v)
	return 0
}

// decodifica UM frame da imagem (letterbox p/ DEC_W×DEC_H) direto p/ c.cache[0]
image_decode :: proc(c: ^Clip) -> bool {
	r, w, e := os.pipe()
	if e != nil do return false
	cmd := []string{
		"ffmpeg", "-hide_banner", "-loglevel", "error", "-i", c.path,
		"-vf", DEC_VF, // mesma escala/letterbox do vídeo (DEC_W×DEC_H) — casa com o tamanho de FRAME
		"-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1",
	}
	p, pe := os.process_start(os.Process_Desc{ command = cmd, stdout = w })
	os.close(w)
	if pe != nil { os.close(r); return false }
	tame_process(c, p, false)
	total := 0
	for total < FRAME {
		n, re := os.read(r, c.cache[total:])
		if n > 0 do total += n
		if n == 0 || re != nil do break
	}
	os.close(r)
	_, _ = os.process_wait(p)
	return total == FRAME
}

// prepara o clipe para decodificar AO VIVO: buffer de 1 frame, 1º frame e head de áudio.
// Extraído porque há DUAS entradas para o streaming — a decisão normal (clipe longo ou
// orçamento de RAM cheio) e o fallback de quando o make() do cache falha.
import_stream_setup :: proc(c: ^Clip) {
	c.dw = stream_dw(); c.dh = stream_dh() // qualidade atual (Alta/Baixa); dims de decode do clipe
	c.fbuf = make([]u8, STREAM_FBYTES_MAX) // max (720p): trocar de qualidade não realoca
	stream_seek(c, 0, false) // lê o 1º frame para fbuf (sem GL)
	intrinsics.atomic_store(&c.probed, true)
	// head de áudio: 30s de WAV ficam prontos em ~1s -> o clipe já toca com som
	c.head_dur = min(HEAD_SECS, c.dur)
	if audio_extract(c, c.aud_head, true) do intrinsics.atomic_store(&c.head_ok, true)
	intrinsics.atomic_store(&c.head_done, true)
}

// roda em thread de fundo: NÃO toca em GL (textura/áudio ficam para a main thread)
import_worker :: proc(c: ^Clip) {
	// IMAGEM: 1 frame estático, sem áudio, duração padrão (extensível na timeline)
	if is_image_path(c.path) {
		c.is_img = true
		c.dur = IMG_DUR
		c.streaming = false
		c.total = 1
		c.cache = make([]u8, FRAME)
		// sem RAM nem para 1 frame: falha limpa (image_decode escreveria num slice vazio)
		if c.cache == nil { intrinsics.atomic_store(&c.failed, true); intrinsics.atomic_store(&c.probed, true); return }
		if !image_decode(c) { intrinsics.atomic_store(&c.failed, true); intrinsics.atomic_store(&c.probed, true); return }
		if _, _, iw, ih, _ := video_probe(c.path); iw > 0 { c.vw = iw; c.vh = ih } // dims p/ autodetectar proj_ar
		intrinsics.atomic_store(&c.cached, 1)
		intrinsics.atomic_store(&c.probed, true)
		decode_thumbs(c) // tira a miniatura do próprio frame (caminho de cache)
		return
	}

	// ÁUDIO (mp3/wav/...): sem vídeo. Extrai o áudio completo (parts_worker) + waveform.
	if is_audio_path(c.path) {
		d := audio_probe_dur(c.path)
		if d <= 0 { intrinsics.atomic_store(&c.failed, true); intrinsics.atomic_store(&c.probed, true); return }
		c.is_audio = true
		c.dur = d
		c.streaming = false
		c.src_audio = true // mídia só-áudio: por definição (antes de `probed`, que a main lê)
		intrinsics.atomic_store(&c.probed, true) // já aparece no bin
		if intrinsics.atomic_load(&c.stop) do return // fechando: não dispara mais ffmpeg (escaparia do job)
		c.nparts = 1
		c.parts_thr = thread.create_and_start_with_poly_data(c, parts_worker) // gera o _full.ogg; audio_load_ready abre
		compute_waveform(c) // forma de onda (mostra na trilha de áudio)
		return
	}

	dur, codec, vw, vh, sfps := video_probe(c.path)
	if dur <= 0 {
		intrinsics.atomic_store(&c.failed, true)
		intrinsics.atomic_store(&c.probed, true)
		return
	}
	c.dur = dur
	c.vcodec = strings.clone(codec)
	c.vw = vw; c.vh = vh // publicado antes do store de `probed`: a main thread lê p/ autodetectar proj_ar
	// AQUI, antes dos dois caminhos (cache e streaming) publicarem `probed`: quando o clipe
	// aparece pronto para o resto do app, o export já sabe se ele tem som. Ligar isso ao
	// c.has_audio (que só vira true quando a extração termina, dezenas de segundos depois no
	// caminho de cache) deixava exportar um MP4 válido e MUDO nesse intervalo.
	c.src_audio = probe_has_audio(c.path)
	// fps que o cache usaria: SEGUE a fonte, teto 60. Uma gravação 60fps tocava a 30
	// (o cache forçava -r 30) e o movimento fino "tremia"/judder; agora toca nativo.
	// 24/25/30 seguem como são (menos RAM). Probe falho -> DEC_FPS.
	cf := sfps > 0 ? min(sfps, f32(60)) : DEC_FPS
	// RAM ~ dur × fps: um clipe 60fps ocupa 2×/seg, então pesa 2× ao decidir streaming.
	// `cache_claim` decide E reserva sob o mesmo lock: imports simultâneos não gastam o
	// mesmo espaço do orçamento (ver cache_inflight). cw = o que ESTE clipe tem reservado.
	cw := dur * cf / DEC_FPS
	c.streaming = dur > STREAM_OVER || !cache_claim(cw)
	if c.streaming do cw = 0 // não reservou nada: nada a devolver

	if !c.streaming {
		// aloca o cache ANTES de escolher o caminho: se o SO negar a RAM, cai para streaming
		// em vez de seguir e estourar o bounds check em clip_read_into (slice vazio),
		// derrubando o app com o projeto não salvo junto.
		c.cfps = cf
		c.total = int(dur * cf) + 2
		c.cache = make([]u8, c.total * FRAME)
		if c.cache == nil {
			dbg("CACHE", "clip='%s' make(%d bytes) falhou -> streaming", c.name, c.total * FRAME)
			cache_unclaim(c, cw, false); cw = 0
			c.streaming = true
			c.cfps = 0; c.total = 0
		}
	}

	if c.streaming {
		import_stream_setup(c)
	} else {
		// cache_dec_start é software (ver lá): sem retry de fallback de NVDEC — o decode do cache
		// já é software puro, então uma falha aqui é falha real.
		if !cache_dec_start(c) { intrinsics.atomic_store(&c.failed, true); cache_unclaim(c, cw, true); return }
		ok0 := clip_read_into(c, 0)
		if ok0 do intrinsics.atomic_store(&c.cached, 1)
		cache_unclaim(c, cw, true) // publica `probed` (já aparece no bin) e solta a reserva
		for {
			if intrinsics.atomic_load(&c.stop) do break
			n := c.cached
			if n >= c.total do break
			if !clip_read_into(c, n) do break
			intrinsics.atomic_store(&c.cached, n + 1)
		}
		_ = os.process_kill(c.dec_ps)
		_, _ = os.process_wait(c.dec_ps)
		os.close(c.dec_r)
		intrinsics.atomic_store(&c.dec_run, false)
	}

	// FECHANDO no meio da importação: NÃO dispara mais ffmpeg. Sem isto, o worker seguia
	// spawnando extração de áudio/waveform/miniaturas DEPOIS que o shutdown já fechou o
	// c.job — esses processos escapavam do Job (job==nil) e o thread.join travava esperando
	// o ffmpeg terminar sozinho. (Muito mais provável com vários imports = janela maior.)
	if intrinsics.atomic_load(&c.stop) do return

	// áudio completo num ÚNICO FLAC (thread própria, paralela à waveform/miniaturas):
	// fica pronto em ~15s p/ 5h; até lá o head + chunks cobrem a interatividade.
	c.nparts = 1
	c.parts_thr = thread.create_and_start_with_poly_data(c, parts_worker)

	compute_waveform(c) // forma de onda: PCM por pipe, preenche progressivo e rápido
	decode_thumbs(c)    // miniaturas (cache: instantâneo do RAM; streaming: -ss por frame)
}

// transmite o PCM do áudio (mono, WAVE_RATE Hz, s16le) por PIPE e preenche c.wave
// PROGRESSIVAMENTE conforme o ffmpeg decodifica — a onda se desenha da esquerda p/
// a direita, rápido, sem escrever/ler WAV grande. Sem cabeçalho (formato é o que
// pedi no comando). Indexa por tempo absoluto; `wave_ready` já no 1º bloco.
compute_waveform :: proc(c: ^Clip) {
	if c.dur <= 0 do return
	r, w, e := os.pipe()
	if e != nil do return
	cmd := []string{
		"ffmpeg", "-hide_banner", "-loglevel", "error", "-i", c.path,
		"-vn", "-ac", "1", "-ar", "8000", "-f", "s16le", "pipe:1", // "8000" deve casar com WAVE_RATE
	}
	p, pe := os.process_start(os.Process_Desc{ command = cmd, stdout = w })
	os.close(w)
	if pe != nil { os.close(r); return }
	tame_process(c, p, true) // fundo

	if c.wave == nil do c.wave = make([]f32, max(1, int(c.dur * WAVE_PPS)))
	if c.wave_rms == nil do c.wave_rms = make([]f32, len(c.wave))
	n := len(c.wave)
	buf := make([]u8, 1 << 16)
	defer delete(buf)
	frame_idx := 0
	fill := 0
	published := false
	// acumulador do bucket ATUAL p/ o RMS: as amostras chegam em ordem de tempo, então o bucket
	// fecha quando o índice muda — aí grava sqrt(média dos quadrados) e zera. Mantém a escrita
	// IN-PLACE de um f32 por bucket (a main lê sem trava, como o pico).
	acc_b := -1
	acc_sq: f64 = 0
	acc_n  := 0
	for {
		if intrinsics.atomic_load(&c.stop) do break // app fechando
		rn, rerr := os.read(r, buf[fill:])
		if rn > 0 do fill += rn
		usable := (fill / 2) * 2 // 2 bytes por amostra (mono s16)
		i := 0
		for i < usable {
			s := i16(u16(buf[i]) | u16(buf[i+1]) << 8)
			av := i32(s); if av < 0 do av = -av
			b := int(f64(frame_idx) / f64(WAVE_RATE) * f64(WAVE_PPS)) // bucket por tempo
			if b >= 0 && b < n {
				v := f32(av) / 32768.0
				if v > c.wave[b] do c.wave[b] = v
				if b != acc_b { // virou de bucket: fecha o anterior e começa o novo
					if acc_b >= 0 && acc_b < n && acc_n > 0 {
						c.wave_rms[acc_b] = f32(math.sqrt(acc_sq / f64(acc_n)))
					}
					acc_b = b; acc_sq = 0; acc_n = 0
				}
				fv := f64(v)
				acc_sq += fv * fv
				acc_n += 1
			}
			frame_idx += 1
			i += 2
		}
		rem := fill - usable
		if rem > 0 do copy(buf[0:rem], buf[usable:fill])
		fill = rem
		if !published { intrinsics.atomic_store(&c.wave_ready, true); published = true } // mostra já enquanto enche
		if rn <= 0 || rerr != nil do break
	}
	if acc_b >= 0 && acc_b < n && acc_n > 0 do c.wave_rms[acc_b] = f32(math.sqrt(acc_sq / f64(acc_n))) // último bucket
	os.close(r)
	if intrinsics.atomic_load(&c.stop) do _ = os.process_kill(p) // fechando: não espera o ffmpeg terminar sozinho
	_, _ = os.process_wait(p)
}

// pico [0,1] da fonte no intervalo de tempo [t0,t1] (segundos). -1 = ainda não pronto.
wave_peak :: proc(c: ^Clip, t0, t1: f32) -> f32 {
	if !intrinsics.atomic_load(&c.wave_ready) || len(c.wave) == 0 do return -1
	n := len(c.wave)
	i0 := clamp(int(t0 * WAVE_PPS), 0, n - 1)
	i1 := clamp(int(t1 * WAVE_PPS), 0, n - 1)
	if i1 < i0 do i1 = i0
	// amostra no MÁX ~8 buckets no intervalo: numa coluna de 2px o pico de 8 amostras
	// é visualmente idêntico ao de milhares. Sem o passo, zoom-out num clipe de HORAS
	// varria centenas de milhares de buckets POR COLUNA → timeline a 50ms/frame com
	// vários clipes longos (o desenho já era clampado ao visível, a VARREDURA não era).
	step := max(1, (i1 - i0) / 8)
	m: f32 = 0
	for i := i0; i <= i1; i += step do if c.wave[i] > m do m = c.wave[i]
	return m
}

// RMS [0,1] da fonte no intervalo (mesma amostragem do wave_peak). -1 = ainda não pronto.
// O RMS é ~3-5x menor que o pico, então o desenho aplica um ganho de exibição (WAVE_RMS_GAIN).
wave_rms_at :: proc(c: ^Clip, t0, t1: f32) -> f32 {
	if !intrinsics.atomic_load(&c.wave_ready) || len(c.wave_rms) == 0 do return -1
	n := len(c.wave_rms)
	i0 := clamp(int(t0 * WAVE_PPS), 0, n - 1)
	i1 := clamp(int(t1 * WAVE_PPS), 0, n - 1)
	if i1 < i0 do i1 = i0
	step := max(1, (i1 - i0) / 8)
	m: f32 = 0
	for i := i0; i <= i1; i += step do if c.wave_rms[i] > m do m = c.wave_rms[i]
	return m
}

// ----- filmstrip: miniaturas amostradas ao longo do clipe (thread de fundo) -----
// reduz (nearest) um frame 640x360 rgb24 do cache p/ THUMB_W x THUMB_H
thumb_from_cache :: proc(src, dst: []u8) {
	for y in 0 ..< THUMB_H {
		sy := y * DEC_H / THUMB_H
		for x in 0 ..< THUMB_W {
			sx := x * DEC_W / THUMB_W
			si := (sy * DEC_W + sx) * 3
			di := (y * THUMB_W + x) * 3
			dst[di] = src[si]; dst[di + 1] = src[si + 1]; dst[di + 2] = src[si + 2]
		}
	}
}

// decodifica 1 miniatura (THUMB_W x THUMB_H rgb24) do tempo `t` p/ `dst` via ffmpeg
// -ss (usado só em clipes streaming, que não têm cache). NVDEC quando dá.
thumb_decode :: proc(c: ^Clip, t: f32, dst: []u8) -> bool {
	for {
		if intrinsics.atomic_load(&c.stop) do return false // abortando: não re-spawna (fora do job já fechado)
		hw := use_cuvid(c)
		r, w, e := os.pipe()
		if e != nil do return false
		tb: [32]u8
		ss := fmt.bprintf(tb[:], "%.3f", t)
		sw_cmd := []string{
			"ffmpeg", "-hide_banner", "-loglevel", "error", "-threads", "1",
			"-ss", ss, "-i", c.path,
			"-frames:v", "1", "-vf", THUMB_VF, "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1",
		}
		hw_cmd := []string{ // sem -resize (esticaria): letterbox pela CPU preserva o aspecto
			"ffmpeg", "-hide_banner", "-loglevel", "error",
			"-ss", ss, "-c:v", hw, "-i", c.path,
			"-frames:v", "1", "-vf", THUMB_VF, "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1",
		}
		p, pe := os.process_start(os.Process_Desc{ command = hw != "" ? hw_cmd : sw_cmd, stdout = w })
		os.close(w)
		if pe != nil { os.close(r); return false }
		tame_process(c, p, true) // fundo: não disputa CPU com o playback
		total := 0
		for total < THUMB_FR {
			n, re := os.read(r, dst[total:])
			if n > 0 do total += n
			if n == 0 || re != nil do break
		}
		os.close(r)
		_, _ = os.process_wait(p)
		if total == THUMB_FR do return true
		if hw == "" do return false
		hw_reject(c) // NVDEC recusou: refaz por software
	}
}

// gera as miniaturas do clipe (thread de importação). Cache: reduz do RAM (grátis);
// streaming: um -ss por miniatura (poucas, keyframe, barato). Deixa em thumb_px
// p/ a main subir as texturas.
decode_thumbs :: proc(c: ^Clip) {
	if c.dur <= 0 do return
	if intrinsics.atomic_load(&c.stop) do return // fechando: não gera miniaturas (spawn de ffmpeg)
	// streaming: 1 miniatura/spawn de ffmpeg — teto 36 (era 24) adensa o fallback de scrub
	// (num vídeo de 1h: 1 a cada ~100s em vez de ~156s) sem estourar o tempo de geração.
	nt := c.streaming ? clamp(int(c.dur / 5) + 1, 1, 36) : clamp(int(c.dur / 1.5) + 1, 1, 80)
	px := make([]u8, nt * THUMB_FR)
	got := false
	if !c.streaming {
		cached := intrinsics.atomic_load(&c.cached)
		if cached > 0 {
			for i in 0 ..< nt {
				t := (f32(i) + 0.5) * c.dur / f32(nt)
				fi := clamp(int(t * cfps_of(c)), 0, cached - 1)
				thumb_from_cache(c.cache[fi * FRAME:], px[i * THUMB_FR:])
			}
			got = true
		}
	} else {
		for i in 0 ..< nt {
			if intrinsics.atomic_load(&c.stop) { delete(px); return }
			t := (f32(i) + 0.5) * c.dur / f32(nt)
			if thumb_decode(c, t, px[i * THUMB_FR : (i + 1) * THUMB_FR]) do got = true
		}
	}
	if !got { delete(px); return }
	c.thumb_px = px
	c.thumb_dt = c.dur / f32(nt)
	c.nthumbs = nt
	intrinsics.atomic_store(&c.thumbs_decoded, true)
}

// sobe as texturas das miniaturas (main thread), algumas por frame p/ não travar
ensure_thumbs :: proc(c: ^Clip) {
	if c.thumbs_ready || !intrinsics.atomic_load(&c.thumbs_decoded) do return
	if c.thumbs == nil do c.thumbs = make([]rl.Texture2D, c.nthumbs)
	lim := min(c.nthumbs, c.thumbs_up + 8)
	for c.thumbs_up < lim {
		i := c.thumbs_up
		img := rl.Image{ data = raw_data(c.thumb_px[i * THUMB_FR:]), width = THUMB_W, height = THUMB_H, mipmaps = 1, format = .UNCOMPRESSED_R8G8B8 }
		c.thumbs[i] = rl.LoadTextureFromImage(img)
		rl.SetTextureFilter(c.thumbs[i], .BILINEAR)
		c.thumbs_up += 1
	}
	if c.thumbs_up >= c.nthumbs {
		c.thumbs_ready = true
		delete(c.thumb_px); c.thumb_px = nil
	}
}


// avisa (uma vez) quando cada importação fica pronta ou falha
notify_imports :: proc() {
	for i in 0 ..< nclips {
		c := &clips[i]
		if c.closed do continue // tombstone: nome já liberado, não notifica
		if c.notified || !intrinsics.atomic_load(&c.probed) do continue
		c.notified = true
		if intrinsics.atomic_load(&c.failed) do set_toast(rl.TextFormat("Falhou: %s", cs(c.name)))
		else do set_toast(rl.TextFormat("Importado: %s", cs(c.name)))
	}
}

// garante a textura do clipe a partir do 1º frame disponível (main thread)
ensure_tex :: proc(c: ^Clip) {
	if c.tex_ok || !intrinsics.atomic_load(&c.probed) do return
	if c.streaming {
		if intrinsics.atomic_load(&c.rsp_busy) do return // worker é o dono de fbuf
		if c.live_frame > 0 { upload_tex(c, rawptr(raw_data(c.fbuf))); c.tex_t = live_now(c) }
	} else {
		if intrinsics.atomic_load(&c.cached) > 0 do clip_show(c, 0)
	}
}

// ----- scrub assíncrono -----
// decodifica 1 frame (rgb24 640x360) do clipe no tempo `t` para `buf`.
// fast=true (arrasto do playhead): -noaccurate_seek — entrega o KEYFRAME mais próximo
// em vez de decodificar do keyframe até o tempo exato (até centenas de ms a menos por
// frame; num scrub o "quase lá" é invisível e ao soltar o seek preciso corrige).
scrub_decode_frame :: proc(c: ^Clip, t: f32, buf: []u8, fast := false) -> bool {
	for {
		// checa c.stop como o dup_open: remover a mídia no MEIO de um decode de scrub
		// liberava c.path/c.vcodec enquanto o loop retentava com eles (use-after-free)
		if intrinsics.atomic_load(&app_closing) || intrinsics.atomic_load(&c.stop) do return false
		// fast (arrasto): por software POR PADRÃO — p/ decodificar 1 keyframe de um codec
		// LEVE a 360p o init do cuvid custa mais que o próprio decode, e cada spawn disputa
		// uma sessão NVDEC com os decoders ao vivo. MAS num codec PESADO (AV1/HEVC/4K) o SW
		// leva ~1-2s/keyframe — aí c.scrub_hw (setado no worker quando um decode SW estoura
		// SCRUB_HW_MS) libera o NVDEC, que mesmo pagando o init entrega ~4x mais rápido.
		hw := (fast && !c.scrub_hw) ? "" : use_cuvid(c)
		r, w, e := os.pipe()
		if e != nil do return false
		tb: [32]u8
		ss := fmt.bprintf(tb[:], "%.3f", t)
		acc := fast ? "-noaccurate_seek" : "-accurate_seek" // opção de INPUT (antes do -i)
		vfb: [128]u8; vf := dec_vf_of(c, vfb[:]) // mesma resolução do caminho ao vivo (c.tex)
		sf := cframe(c)
		sw_cmd := []string{
			"ffmpeg", "-hide_banner", "-loglevel", "error", "-threads", "1",
			acc, "-ss", ss, "-i", c.path,
			"-frames:v", "1", "-vf", vf, "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1",
		}
		hw_cmd := []string{ // sem -resize (esticaria): letterbox pela CPU preserva o aspecto
			"ffmpeg", "-hide_banner", "-loglevel", "error",
			acc, "-ss", ss, "-c:v", hw, "-i", c.path,
			"-frames:v", "1", "-vf", vf, "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1",
		}
		p, pe := os.process_start(os.Process_Desc{ command = hw != "" ? hw_cmd : sw_cmd, stdout = w })
		os.close(w)
		if pe != nil { os.close(r); return false }
		tame_process(c, p, false)
		total := 0
		for total < sf {
			n, re := os.read(r, buf[total:sf])
			if n > 0 do total += n
			if n == 0 || re != nil do break
		}
		os.close(r)
		_, _ = os.process_wait(p)
		if intrinsics.atomic_load(&app_closing) do return false // fechando: não retenta por software
		if total == sf do return true
		if hw == "" do return false
		// NVDEC recusou. No scrub (fast) NÃO chama hw_reject: isso marcaria no_hw no clipe e
		// derrubaria o decoder AO VIVO p/ software (playback travado). Só desliga o HW do scrub
		// deste clipe (sticky, via scrub_hw_bad) e refaz por software no próximo giro do loop.
		if fast {
			c.scrub_hw = false; c.scrub_hw_bad = true
			dbg("SCRUBHW", "clip='%s' NVDEC FALHOU no scrub -> volta p/ SW (decoder ao vivo INTOCADO)", c.name)
		} else { hw_reject(c) }
	}
}

// roda em thread de fundo: pega o último tempo pedido e decodifica um frame.
// Protocolo ping-pong com a main via scrub_ready: o worker só escreve em
// scrub_buf quando ready=false; a main só lê quando ready=true. Sem corrida.
scrub_worker :: proc() {
	for intrinsics.atomic_load(&scrub_run) {
		// canal 1: scrub do playhead (prioridade — o usuário está arrastando)
		if !intrinsics.atomic_load(&scrub_ready) {
			if ci := intrinsics.atomic_load(&scrub_req_c); ci >= 0 && ci < nclips {
				sf0 := cframe(&clips[ci]) // dims no INÍCIO do decode (compara na adoção)
				st0 := scrub_req_t        // alvo capturado 1x (o global muda durante o arrasto)
				wt0 := time.tick_now()
				if scrub_decode_frame(&clips[ci], st0, scrub_buf, true) { // fast: keyframe basta no arrasto
					scrub_last_ms = time.duration_milliseconds(time.tick_diff(wt0, time.tick_now()))
					// codec pesado: um decode SW lento migra este clipe p/ NVDEC no scrub (só
					// sobe — nunca volta a SW sozinho, p/ não oscilar). scrub_hw_bad trava a
					// migração se o NVDEC já falhou aqui (senão religaria e oscilaria).
					if !clips[ci].scrub_hw && !clips[ci].scrub_hw_bad && scrub_last_ms > SCRUB_HW_MS {
						clips[ci].scrub_hw = true
						dbg("SCRUBHW", "clip='%s' migrado p/ NVDEC no scrub (decode SW levou %.0fms > %.0f)", clips[ci].name, scrub_last_ms, SCRUB_HW_MS)
					}
					dbg("SCRUB", "clip=%d t=%.1fs %s %.0fms", ci, st0, clips[ci].scrub_hw ? "HW" : "SW", scrub_last_ms)
					scrub_done_c = ci
					scrub_done_t = st0
					scrub_done_sf = sf0
					intrinsics.atomic_store(&scrub_ready, true)
				} else {
					dbg("SCRUB", "clip=%d t=%.1fs FALHOU (decode nao completou)", ci, st0)
					time.sleep(4 * time.Millisecond)
				}
				continue
			}
		}
		// canal 2: vista duplicada (mesma fonte em 2 trilhas, streaming): spawna o
		// decoder ao vivo da vista + lê o 1º frame. Protocolo: main publica dup_req_c
		// por último; o worker SEMPRE sinaliza dup_ready (sucesso = processo em
		// dup_sp_*; falha/EOF = dup_sp_on false, a main congela via leof).
		if !intrinsics.atomic_load(&dup_ready) {
			// o carimbo é lido ANTES do dup_req_c de propósito: se a main publicar um pedido
			// novo no meio, o worker fica com o carimbo VELHO e o dup_poll descarta — spawn
			// perdido, que o frame seguinte refaz. O erro na outra direção (carimbo novo com
			// pedido velho) adotaria lixo.
			seq := intrinsics.atomic_load(&dup_req_seq)
			if ci := intrinsics.atomic_load(&dup_req_c); ci >= 0 && ci < nclips {
				dup_open(&clips[ci], dup_req_t)
				dup_sp_seq = seq // publicado antes do dup_ready (a main só lê depois dele)
				intrinsics.atomic_store(&dup_ready, true)
				continue
			}
		}
		time.sleep(4 * time.Millisecond)
	}
}

// (worker) spawna um decoder ao vivo p/ a vista dup em `t` e lê o 1º frame p/
// dup_buf. Processo/pipe ficam em dup_sp_* p/ a main adotar. Mesmo fallback
// hw->sw do stream_seek. bprintf (não tprintf): o worker é uma thread de vida
// longa — temp allocator nunca é liberado nela.
dup_open :: proc(c: ^Clip, t: f32) {
	dup_sp_on = false
	force_sw := false
	for {
		if intrinsics.atomic_load(&app_closing) || intrinsics.atomic_load(&c.stop) do return
		hw := force_sw ? "" : use_cuvid(c)
		r, w, e := os.pipe()
		if e != nil do return
		tb: [32]u8
		ss := fmt.bprintf(tb[:], "%.3f", t)
		vfb: [128]u8; vf := dec_vf_of(c, vfb[:]) // mesma resolução do primário (dec_content_rect é compartilhado)
		sf := cframe(c)
		rfb: [16]u8
		rs := fmt.bprintf(rfb[:], "%.2f", dup_req_fps > 0 ? dup_req_fps : DEC_FPS)
		// -threads 2 no decode por SOFTWARE: 2 cores bastam p/ 30fps a 360p; sem o teto,
		// vários clipes empilhados caindo p/ software (pressão NVDEC) disputavam TODOS
		// os cores entre si e com os workers — a sessão inteira ia degradando
		sw_cmd := []string{
			"ffmpeg", "-hide_banner", "-loglevel", "error", "-threads", "2",
			"-ss", ss, "-i", c.path,
			"-vf", vf, "-f", "rawvideo", "-pix_fmt", "rgb24", "-r", rs,
			"-an", "-sn", "pipe:1",
		}
		hw_cmd := []string{ // sem -resize (esticaria): letterbox pela CPU preserva o aspecto
			"ffmpeg", "-hide_banner", "-loglevel", "error",
			"-ss", ss, "-c:v", hw, "-i", c.path,
			"-vf", vf, "-f", "rawvideo", "-pix_fmt", "rgb24", "-r", rs,
			"-an", "-sn", "pipe:1",
		}
		p, pe := os.process_start(os.Process_Desc{ command = hw != "" ? hw_cmd : sw_cmd, stdout = w })
		os.close(w)
		if pe != nil { os.close(r); return }
		tame_process(c, p, false)
		total := 0
		for total < sf {
			n, re := os.read(r, dup_buf[total:sf])
			if n > 0 do total += n
			if n == 0 || re != nil do break
		}
		if total == sf {
			if force_sw do hw_reject(c) // o software entregou onde o NVDEC não: recusa real
			else if hw != "" do c.no_hw = false // hardware entregando de novo: cura a marca
			dup_sp_ps = p; dup_sp_r = r; dup_sp_on = true
			return
		}
		_ = os.process_kill(p); _, _ = os.process_wait(p); os.close(r)
		if hw == "" do return // nem o software entregou: fim real (main congela via leof)
		force_sw = true
	}
}

// ----- vista duplicada (mesma fonte em 2+ trilhas de vídeo sob o playhead) -----
// o seg i é uma vista duplicada? = a mesma fonte já é usada por um seg de trilha
// mais BAIXA sob o playhead (que fica com o caminho normal c.tex + decoder).
// Determinística por frame — decode (show_playhead_frame) e draw (composite)
// recalculam e chegam à mesma resposta.
seg_is_dup :: proc(i: int) -> bool {
	if i < 0 || i >= nsegs do return false
	src := segs[i].src
	if clips[src].is_text do return false // texto não tem textura p/ disputar
	for t in 0 ..< segs[i].track {
		j := seg_on_track_at(t, st.playhead)
		if j >= 0 && segs[j].src == src do return true
	}
	return false
}

// sobe pixels rgb24 (cdw×cdh da fonte) p/ a textura da vista dup do segmento. Recria
// se as dims mudaram (fonte diferente no slot, ou troca de qualidade) — a vista dup e
// o primário c.tex compartilham dec_content_rect no draw, então têm de bater em tamanho.
dup_upload :: proc(si: int, pixels: rawptr) {
	d := &seg_dup[si]
	c := seg_src(si)
	w, h := cdw(c), cdh(c)
	if !d.ok || d.tw != w || d.th != h {
		if d.ok do rl.UnloadTexture(d.tex)
		img := rl.Image{ data = pixels, width = w, height = h, mipmaps = 1, format = .UNCOMPRESSED_R8G8B8 }
		d.tex = rl.LoadTextureFromImage(img)
		rl.SetTextureFilter(d.tex, .BILINEAR)
		d.ok = true; d.tw = w; d.th = h
	} else {
		rl.UpdateTexture(d.tex, pixels)
	}
}

// mata o decoder ao vivo da vista (main)
dup_live_stop :: proc(d: ^SegDup) {
	if d.lon {
		_ = os.process_kill(d.lps)
		_, _ = os.process_wait(d.lps)
		os.close(d.lr)
		d.lon = false
	}
}

dup_release :: proc(si: int) {
	d := &seg_dup[si]
	dup_live_stop(d)
	if d.ok do rl.UnloadTexture(d.tex)
	d^ = SegDup{}
}

// solta o canal da vista dup quando o pedido em voo foi CANCELADO antes de o worker olhar.
// Os dois cancelamentos (troca de qualidade da prévia, remoção da mídia) zeram `dup_req_c` à
// força; se isso pegar o pedido antes do worker, ele não entra no ramo e nunca sinaliza
// `dup_ready` — o único ponto que baixava `dup_inflight`. A flag ficava presa em true e o
// `dup_request` passava a retornar cedo PARA SEMPRE: nenhuma vista duplicada ganhava decoder
// pelo resto da sessão. Se o worker JÁ tinha pegado o pedido, o spawn ainda chega, mas com o
// carimbo velho — o `dup_sp_seq != dup_req_seq` do dup_poll o descarta e mata o órfão, então
// soltar a flag aqui não faz nada ser adotado errado.
dup_cancel_settle :: proc() -> bool {
	if !intrinsics.atomic_load(&dup_inflight) do return false
	if intrinsics.atomic_load(&dup_ready) do return false      // spawn pronto: quem resolve é o ramo de cima
	if intrinsics.atomic_load(&dup_req_c) >= 0 do return false // pedido ainda de pé
	dup_req_si = -1
	intrinsics.atomic_store(&dup_inflight, false)
	return true
}

// pede ao worker um decoder novo p/ a vista do seg si em `l` (1 spawn em voo por vez)
dup_request :: proc(si: int, l: f32) {
	if intrinsics.atomic_load(&dup_ready) do return       // spawn por adotar
	if intrinsics.atomic_load(&dup_inflight) do return    // spawn em voo (flag PRÓPRIA: dup_req_c
	                                                      // é zerado à força pelos cancelamentos)
	dup_req_si = si
	dup_req_t = l
	dup_req_fps = live_want_fps(seg_speed(si))
	dup_req_start = segs[si].start; dup_req_inoff = segs[si].in_off // identidade p/ validar na adoção
	intrinsics.atomic_add(&dup_req_seq, 1) // carimbo novo: invalida qualquer spawn anterior
	intrinsics.atomic_store(&dup_inflight, true)
	intrinsics.atomic_store(&dup_req_c, segs[si].src) // publica por último (worker lê)
}

// lê 1 frame do decoder da vista p/ dup_rd_buf e sobe na textura (main)
dup_read :: proc(si: int) -> bool {
	d := &seg_dup[si]
	sf := cframe(seg_src(si)) // resolução da fonte (dup_rd_buf é max-sized)
	ready, dead := pipe_ready(d.lr)
	if !dead && !ready do return false // main: pipe vazio, não bloqueia
	total := 0
	for total < sf {
		audio_pump() // leitura bloqueante do pipe: mantém o áudio alimentado
		n, e := os.read(d.lr, dup_rd_buf[total:sf])
		if n > 0 do total += n
		if n == 0 || e != nil do break
	}
	if total < sf { // fim do vídeo: registra e congela (não respawna em loop)
		end := dup_now(d)
		if d.leof <= 0 || end < d.leof do d.leof = max(end, 0.001)
		dup_live_stop(d)
		return false
	}
	d.lframe += 1
	dup_upload(si, rawptr(raw_data(dup_rd_buf)))
	d.has = d.lbase + f32(d.lframe - 1) / dup_rate(d)
	return true
}

// atualiza o frame da vista dup do segmento si no tempo de fonte `local` (main).
// Cache: direto da RAM (correto, 30fps). Streaming: decoder ao vivo PRÓPRIO —
// espelho do clip_frame (respawn assíncrono via worker, catch-up de até 2
// frames por chamada na main).
dup_frame :: proc(si: int, local: f32) {
	pt := prof_beg(.Video); defer prof_end(.Video, pt) // re-entrante: não soma 2x dentro do show_playhead_frame
	c := seg_src(si)
	if c.is_text do return
	d := &seg_dup[si]
	// o slot é por índice de seg (que desloca ao remover): conteúdo de outra fonte é inválido
	if d.src != segs[si].src { dup_live_stop(d); d.shown = -1; d.has = -1; d.leof = 0; d.src = segs[si].src }
	l := clamp(local, 0, c.dur)
	if !c.streaming {
		cached := intrinsics.atomic_load(&c.cached)
		if cached == 0 do return
		idx := clamp(int(l * cfps_of(c)), 0, cached - 1)
		if idx != d.shown || !d.ok {
			dup_upload(si, rawptr(raw_data(c.cache[idx * FRAME:])))
			d.shown = idx; d.has = l
		}
		return
	}
	if !d.lon {
		// o stream já provou acabar antes de l: congela o último frame
		if d.leof > 0 && l >= d.leof - 0.05 do return
		dup_request(si, l)
		return
	}
	want := live_want_fps(seg_speed(si))
	if abs(dup_rate(d) - want) > 0.6 {
		dup_live_stop(d)
		dup_request(si, l)
		return
	}
	cur := dup_now(d)
	// mesma correção do clip_frame: alvo atrás da posição ATUAL (não do início do
	// stream) é inalcançável — senão a zona já-passada virava zona morta sem respawn
	if l < cur - 0.2 || l > cur + 1.5 {
		dup_live_stop(d)
		dup_request(si, l)
		return
	}
	// alcança no máx 2 frames por chamada (a main já lê o pipe do clipe dono;
	// ler demais aqui esvaziaria o buffer de áudio). Também debita do orçamento
	// global — vista dup em catch-up soma ao custo das trilhas empilhadas.
	guard := 0
	t0 := time.tick_now()
	for dup_now(d) < l && guard < 2 && g_read_budget > 0 {
		if time.duration_milliseconds(time.tick_diff(t0, time.tick_now())) > READ_MS_MAX do break
		if !dup_read(si) do break
		guard += 1; g_read_budget -= 1
	}
}

// (main, todo frame) adota o spawn terminado pelo worker (processo + 1º frame) e
// libera slots de segs que deixaram de existir (remoção compacta o array).
dup_poll :: proc() {
	if intrinsics.atomic_load(&dup_ready) {
		si := dup_req_si
		// valida: o seg ainda existe, aponta p/ a fonte pedida E é o MESMO seg (start/in_off
		// batem) — src sozinho não basta: uma fonte dividida em vários segs tem todos com o
		// mesmo src, e a compactação após remover um seg faria adotar no seg errado
		// ...e o CARIMBO: um cancelamento (troca de qualidade da prévia, remoção de mídia) o
		// muda, então um spawn que estava em voo naquele momento cai no ramo de descarte em
		// vez de ser adotado com metadados de outro pedido — era assim que um ffmpeg da
		// resolução ANTIGA virava o decoder da vista, com o dup_read pedindo frames de um
		// tamanho que aquele pipe nunca produz.
		ok := si >= 0 && si < nsegs && seg_ready(si) && segs[si].src == intrinsics.atomic_load(&dup_req_c) &&
		      abs(segs[si].start - dup_req_start) < 0.001 && abs(segs[si].in_off - dup_req_inoff) < 0.001 &&
		      dup_sp_seq == intrinsics.atomic_load(&dup_req_seq)
		if dup_sp_on {
			if ok {
				d := &seg_dup[si]
				dup_live_stop(d) // por segurança (não deveria haver um vivo)
				d.lps = dup_sp_ps; d.lr = dup_sp_r; d.lon = true
				d.lbase = dup_req_t; d.lframe = 1
				d.lfps = dup_req_fps
				dup_upload(si, rawptr(raw_data(dup_buf)))
				d.src = segs[si].src
				d.has = dup_req_t
			} else { // o seg sumiu/mudou durante o spawn: mata o decoder órfão
				_ = os.process_kill(dup_sp_ps); _, _ = os.process_wait(dup_sp_ps); os.close(dup_sp_r)
			}
			dup_sp_on = false
		} else if ok {
			// spawn sem frame = EOF/falha nesse ponto: congela até um seek p/ trás
			seg_dup[si].leof = max(dup_req_t, 0.001)
		}
		dup_req_si = -1
		intrinsics.atomic_store(&dup_req_c, -1)
		intrinsics.atomic_store(&dup_inflight, false) // o canal volta a aceitar pedidos
		intrinsics.atomic_store(&dup_ready, false) // por último: worker só reusa dup_buf depois daqui
	}
	_ = dup_cancel_settle()
	for i in nsegs ..< MAX_SEGS do if seg_dup[i].ok || seg_dup[i].lon do dup_release(i)
	// mata o decoder de vistas FORA DE USO (playhead saiu do trecho, ou o dono foi
	// removido e a cópia virou dona) — senão ffmpeg ocioso acumula preso no pipe.
	// A textura fica (barata; reusada se voltar a ser dup).
	for i in 0 ..< nsegs {
		d := &seg_dup[i]
		if !d.lon do continue
		if seg_on_track_at(segs[i].track, st.playhead) == i && seg_is_dup(i) do continue // em uso
		dup_live_stop(d)
	}
}

// ----- streaming (clipes longos): decode de vídeo ao vivo, seek por respawn -----
stream_stop :: proc(c: ^Clip) {
	if c.live_on {
		_ = os.process_kill(c.live_ps)
		_, _ = os.process_wait(c.live_ps)
		os.close(c.live_r)
		c.live_on = false
	}
}

// (re)inicia o ffmpeg do clipe streaming a partir de `sec`.
// upload=false (thread de fundo, sem GL); upload=true (main thread, sobe a textura)
stream_seek :: proc(c: ^Clip, sec: f32, upload: bool) {
	stream_stop(c)
	dbg_t := time.tick_now()
	force_sw := false // retry por software SEM marcar no_hw ainda (pode ser só EOF)
	for {
		if intrinsics.atomic_load(&app_closing) || intrinsics.atomic_load(&c.stop) do return // fechando: não spawna decoder
		hw := force_sw ? "" : use_cuvid(c)
		r, w, e := os.pipe()
		if e != nil do return
		ss := fmt.tprintf("%.3f", sec)
		vfb: [128]u8; vf := dec_vf_of(c, vfb[:]) // 360p (const) ou 720p conforme a qualidade
		fps := c.rsp_fps > 0 ? c.rsp_fps : DEC_FPS
		c.live_fps = fps
		rs := fmt.tprintf("%.2f", fps)
		// -threads 2 no decode por SOFTWARE: 2 cores bastam p/ 30fps a 360p; sem o teto,
		// vários clipes empilhados caindo p/ software (pressão NVDEC) disputavam TODOS
		// os cores entre si e com os workers — a sessão inteira ia degradando
		sw_cmd := []string{
			"ffmpeg", "-hide_banner", "-loglevel", "error", "-threads", "2",
			"-ss", ss, "-i", c.path,
			"-vf", vf, "-f", "rawvideo", "-pix_fmt", "rgb24", "-r", rs,
			"-an", "-sn", "pipe:1",
		}
		hw_cmd := []string{ // sem -resize (esticaria): letterbox pela CPU preserva o aspecto
			"ffmpeg", "-hide_banner", "-loglevel", "error",
			"-ss", ss, "-c:v", hw, "-i", c.path,
			"-vf", vf, "-f", "rawvideo", "-pix_fmt", "rgb24", "-r", rs,
			"-an", "-sn", "pipe:1",
		}
		p, pe := os.process_start(os.Process_Desc{ command = hw != "" ? hw_cmd : sw_cmd, stdout = w })
		os.close(w)
		if pe != nil { os.close(r); return }
		tame_process(c, p, false) // alimenta o playback: prioridade normal, mas no job
		c.live_ps = p; c.live_r = r; c.live_on = true
		c.live_hw = hw != "" // rodando por hardware: um "EOF" no meio pode ser recusa do NVDEC
		c.live_base = sec; c.live_frame = 0
		if stream_read_raw(c, upload) { // upload=true <=> main thread: pode bombear o áudio
			// o software entregou frame onde o NVDEC não: recusa de verdade (não
			// era fim do vídeo) — só agora desliga a GPU p/ este clipe
			if force_sw do hw_reject(c)
			else if hw != "" do c.no_hw = false // hardware entregando de novo: cura a marca
			if upload { upload_tex(c, rawptr(raw_data(c.fbuf))); c.tex_t = live_now(c) }
			dbg("RESPAWN", "clip='%s' base=%.1fs %s dur=%.0fms OK (%s)", c.name, sec, hw != "" ? "HW" : "SW",
				time.duration_milliseconds(time.tick_diff(dbg_t, time.tick_now())), upload ? "main" : "worker")
			return
		}
		dbg("RESPAWN", "clip='%s' base=%.1fs %s -> 0 frames (EOF real, ou recusa NVDEC no 1o frame)", c.name, sec, hw != "" ? "HW" : "SW")
		// 0 frames: fim do vídeo (sw) OU o NVDEC recusou (hw) -> tenta por software
		if hw == "" do return // nem o software entregou: fim real (eof_at registrado)
		force_sw = true
	}
}

// ----- respawn assíncrono do decoder ao vivo -----
// worker: troca o decoder (mata + spawna + lê o 1º frame p/ fbuf, sem GL)
rsp_worker :: proc(c: ^Clip) {
	stream_seek(c, c.rsp_t, false)
	intrinsics.atomic_store(&c.rsp_done, true)
	// rsp_busy é limpo pela MAIN ao adotar — até lá ela não toca no live stream
}

// (main) pede o respawn em `t`. Se já há um no ar, ignora — quando ele terminar,
// o check de janela do clip_frame re-pede se o alvo ainda estiver fora.
stream_seek_async :: proc(c: ^Clip, t: f32) {
	if intrinsics.atomic_load(&c.rsp_busy) do return
	// diagnóstico: grava o alvo do respawn + o playhead no instante (HUD F3). Revela
	// QUEM manda o decoder pra longe do playhead (o bug do decoder travado à frente).
	dbg_rsp_n += 1; dbg_rsp_t = t; dbg_rsp_ph = st.playhead
	if c.rsp_thr != nil { thread.join(c.rsp_thr); thread.destroy(c.rsp_thr); c.rsp_thr = nil }
	c.rsp_t = t
	c.rsp_fps = live_want_fps(clip_view_speed(c))
	c.rsp_t0 = rl.GetTime()
	intrinsics.atomic_store(&c.rsp_done, false)
	intrinsics.atomic_store(&c.rsp_busy, true)
	c.rsp_thr = thread.create_and_start_with_poly_data(c, rsp_worker)
}

// (main) adota respawns concluídos: sobe o 1º frame do decoder novo. Necessário
// fora do playback também — num seek PAUSADO o clip_frame não é chamado de novo,
// e sem isto o preview ficaria no frame velho até a próxima interação.
adopt_respawns :: proc() {
	for i in 0 ..< nclips {
		c := &clips[i]
		if c.closed do continue
		if !c.streaming do continue
		if !intrinsics.atomic_load(&c.rsp_busy) do continue
		// WATCHDOG: respawn PRESO — o worker está bloqueado no read de um ffmpeg que
		// não produz (ex.: NVDEC pendurado esperando sessão livre, com vários clipes).
		// Matar o processo em voo desbloqueia o read; o worker segue (retry por
		// software / termina) e o rsp_done chega. Sem isto, rsp_busy ficava SIM p/
		// SEMPRE e o preview do clipe morria na miniatura borrada até reiniciar o app
		// (a "qualidade caindo com o tempo": clipes iam travando um a um).
		if !intrinsics.atomic_load(&c.rsp_done) {
			if c.live_on && rl.GetTime() - c.rsp_t0 > 4 {
				_ = os.process_kill(c.live_ps)
				c.rsp_t0 = rl.GetTime() // rearma: se travar de novo no retry, mata de novo em 4s
			}
			continue
		}
		intrinsics.atomic_store(&c.rsp_busy, false)
		if c.live_on { upload_tex(c, rawptr(raw_data(c.fbuf))); c.tex_t = live_now(c) }
	}
}

// re-alimenta o buffer do áudio ativo no MEIO de operações bloqueantes da main
// thread (respawn do decoder ao vivo, leitura de frame): sem isso o stream
// esvazia durante um seek/salto e o som engasga. SÓ main thread (raylib audio).
audio_pump :: proc() {
	if play_clip >= 0 && seg_src(play_clip).has_audio do rl.UpdateMusicStream(seg_src(play_clip).music)
}

// tem ALGUM byte no pipe, sem bloquear? O buffer padrão do pipe no Windows é
// ~64KB — um frame 720p rgb24 tem ~2.8MB. Exigir o quadro INTEIRO no Peek
// nunca passava (ffmpeg trava no write nos 64KB, a main nunca lia) = poucos
// frames / vídeo aos solavancos. Qualquer dado basta: o resto chega no read
// conforme drenamos. 0 = tenta no próximo frame; Peek falhou = pipe morto.
pipe_ready :: proc(f: ^os.File) -> (ok: bool, dead: bool) {
	if f == nil do return false, true
	avail: u32
	if !win.PeekNamedPipe(win.HANDLE(os.fd(f)), nil, 0, nil, &avail, nil) do return false, true
	return avail > 0, false
}

// lê um frame do decoder ao vivo para fbuf (sem GL). pump=true (só main thread)
// só entra no read se o pipe já tem dados — senão devolve false e o stream segue.
stream_read_raw :: proc(c: ^Clip, pump := false) -> bool {
	if !c.live_on do return false
	sf := cframe(c) // bytes de 1 frame na resolução ATUAL do clipe (fbuf é max-sized)
	if pump { // main: não espera um pipe vazio (ffmpeg/NVDEC parado)
		ready, dead := pipe_ready(c.live_r)
		if !dead && !ready do return false
	}
	total := 0
	for total < sf {
		if pump do audio_pump()
		n, e := os.read(c.live_r, c.fbuf[total:sf])
		if n > 0 do total += n
		if n == 0 || e != nil do break
	}
	if total < sf { // o stream acabou: fim REAL do vídeo, OU o NVDEC desistiu no meio
		end := live_now(c)
		// NVDEC pode abortar no MEIO de um vídeo pesado (perfil/sessões esgotadas)
		// fechando o pipe — NÃO é fim de verdade. Se ainda falta muito p/ o fim do clipe
		// e estávamos por hardware, desliga o NVDEC e NÃO grava eof: o clip_frame vê
		// !live_on sem eof e respawna por SOFTWARE (recupera sozinho, ~300ms). Sem isto,
		// gravava um eof falso e a imagem congelava de vez (áudio intacto) até um seek.
		if c.live_hw && !c.no_hw && end < c.dur - 1.0 {
			dbg("LIVEDROP", "clip='%s' NVDEC abortou no MEIO em %.1fs (frame %d, %d/%d bytes) -> vai respawnar por SW", c.name, end, c.live_frame, total, sf)
			hw_reject(c)
			stream_stop(c)
			return false
		}
		// fim REAL (ou já era software): registra onde o stream acaba
		if c.eof_at <= 0 || end < c.eof_at do c.eof_at = max(end, 0.001)
		dbg("EOF", "clip='%s' fim do stream em %.1fs (%s)", c.name, end, c.live_hw ? "HW" : "SW")
		stream_stop(c)
		return false
	}
	c.live_frame += 1
	// passou de um eof registrado: era falso (ex.: recusa do NVDEC) — invalida
	if c.eof_at > 0 && live_now(c) > c.eof_at do c.eof_at = 0
	return true
}

// lê um frame e sobe para a textura (main thread)
stream_read :: proc(c: ^Clip) -> bool {
	if !stream_read_raw(c, true) do return false
	upload_tex(c, rawptr(raw_data(c.fbuf)))
	c.tex_t = live_now(c)
	dbg_vframes += 1 // diagnóstico: 1 frame de vídeo NOVO na tela (o heartbeat vira isto em fps real)
	return true
}

// ------- troca de qualidade da prévia STREAMING (Alta 720p / Baixa 360p) -------
// Só mexe em clipes streaming (curtos em cache seguem em 360p). Para cada um: quiesce
// o worker de respawn (é dono do live stream enquanto rsp_busy), mata o decoder ao
// vivo, re-marca as dims de decode e re-decodifica 1 frame na posição atual p/ a
// textura já refletir a nova resolução. Buffers (fbuf/scrub/dup) são max-sized, então
// nada realoca sob as threads. Clipes ainda importando são pulados (o worker de
// importação é dono do decoder deles) — adotam a qualidade atual quando o probe termina.
set_stream_quality :: proc(hi: bool) {
	if hi == stream_hi do return
	stream_hi = hi
	stream_quality_sync()
	set_toast(hi ? "Prévia streaming: Alta (720p)" : "Prévia streaming: Baixa (360p)")
}

// (main, todo frame) põe os clipes de streaming na qualidade de prévia ATUAL. Roda sempre, e
// não só na troca, porque um clipe que ainda estava IMPORTANDO era pulado pelo `probed` e
// nada relia stream_hi depois: o import_stream_setup fixa c.dw/c.dh ANTES de publicar
// `probed` (o stream_seek do 1º frame leva centenas de ms num arquivo grande), então o clipe
// ficava presa na resolução antiga até o usuário trocar a qualidade de novo.
stream_quality_sync :: proc() {
	ndw, ndh := stream_dw(), stream_dh()
	tmp: []u8
	n := 0
	for i in 0 ..< nclips {
		c := &clips[i]
		if c.closed || !c.streaming || !intrinsics.atomic_load(&c.probed) do continue
		if c.dw == ndw && c.dh == ndh do continue // já está na qualidade certa
		if n == 0 { // só ao encontrar trabalho: zerar isto todo frame mataria o scrub
			intrinsics.atomic_store(&scrub_req_c, -1) // barra o worker de iniciar decode novo durante a troca
			intrinsics.atomic_store(&dup_req_c, -1)
			intrinsics.atomic_add(&dup_req_seq, 1) // invalida o spawn em voo: ele é da resolução ANTIGA
		}
		n += 1
		if c.rsp_thr != nil { thread.join(c.rsp_thr); thread.destroy(c.rsp_thr); c.rsp_thr = nil }
		intrinsics.atomic_store(&c.rsp_busy, false)
		intrinsics.atomic_store(&c.rsp_done, false)
		stream_stop(c)
		c.dw = ndw; c.dh = ndh
		c.live_frame = 0
		// re-decodifica o frame atual na nova resolução (upload_tex recria a textura no
		// novo tamanho) p/ prévia/bin atualizarem já; nunca-exibidos criam depois.
		if c.tex_ok {
			if tmp == nil do tmp = make([]u8, STREAM_FBYTES_MAX)
			if scrub_decode_frame(c, c.live_base, tmp) { upload_tex(c, rawptr(raw_data(tmp))); c.tex_t = c.live_base }
		}
	}
	if tmp != nil do delete(tmp)
	if n > 0 do for i in 0 ..< nsegs do if seg_dup[i].ok || seg_dup[i].lon do dup_release(i) // recriam na nova res
}

clip_read_into :: proc(c: ^Clip, idx: int) -> bool {
	off := idx * FRAME
	total := 0
	for total < FRAME {
		n, e := os.read(c.dec_r, c.cache[off + total : off + FRAME])
		if n > 0 do total += n
		if n == 0 || e != nil do break
	}
	return total == FRAME
}

// sobe pixels rgb24 (cdw×cdh) para a textura do clipe. Recria a textura se as dims
// mudaram (troca de qualidade Alta/Baixa em streaming) — UpdateTexture exige tamanho
// idêntico; passar um frame maior num texture menor leria fora do buffer (crash).
upload_tex :: proc(c: ^Clip, pixels: rawptr) {
	w, h := cdw(c), cdh(c)
	if !c.tex_ok || c.tw != w || c.th != h {
		if c.tex_ok do rl.UnloadTexture(c.tex)
		img := rl.Image{ data = pixels, width = w, height = h, mipmaps = 1, format = .UNCOMPRESSED_R8G8B8 }
		c.tex = rl.LoadTextureFromImage(img)
		rl.SetTextureFilter(c.tex, .BILINEAR)
		c.tex_ok = true; c.tw = w; c.th = h
	} else {
		rl.UpdateTexture(c.tex, pixels)
	}
}

// mostra o frame do clipe no tempo `local` (segundos dentro do clipe)
clip_frame :: proc(c: ^Clip, local: f32) {
	if c.is_text do return // texto não decodifica vídeo (desenhado no compositing)
	l := clamp(local, 0, c.dur)
	if !c.streaming {
		// PASSO TRAVADO NO VSYNC (anti-beat), só durante o playback: amostrar int(t*fps) por
		// frame de render "bate" quando o período do conteúdo ≈ período do render (60fps em
		// 60Hz) — o jitter residual do relógio repete um frame e pula o próximo. Aqui o frame
		// exibido avança +1 por frame de render dentro de uma zona-morta e só REancora em
		// descontinuidade real. Parado/scrub/seek: índice exato (pulos têm de ser imediatos).
		target := int(l * cfps_of(c))
		if !st.playing || st.drag != .None || player_seek_drag {
			c.pframe = target; c.pframe_tick = g_frame_no
			clip_show(c, target)
			return
		}
		if c.pframe_tick == g_frame_no { // 2º chamador no MESMO frame (update+draw, transição):
			clip_show(c, c.pframe)       // reusa a decisão — senão o vídeo andava 2x
			return
		}
		cont := g_frame_no - c.pframe_tick == 1 // exibido no frame anterior = cadência contínua
		c.pframe_tick = g_frame_no
		if !cont {
			c.pframe = target // acabou de entrar em cena (início/corte/transição): ancora
		} else {
			d := target - c.pframe
			if d > 5 || d < -5 do c.pframe = target // salto real (corte p/ outro trecho, hitch): pula direto
			else if d >= 2 do c.pframe += 2         // atrasado: alcança (+1 líquido por frame)
			else if d >= 0 do c.pframe += 1         // zona-morta: passo travado (absorve o jitter de ±1)
			// d < 0: segura (conteúdo mais lento que o render, ex. 30fps em 60Hz = pulldown limpo;
			// avançar aqui — como a 1ª versão fazia — deixava o vídeo até 2 frames À FRENTE do áudio)
		}
		clip_show(c, c.pframe)
		return
	}
	// respawn assíncrono no ar: o worker é o dono do live stream — congela o
	// frame atual até o novo decoder chegar (o áudio segue intocado)
	if intrinsics.atomic_load(&c.rsp_busy) {
		if !intrinsics.atomic_load(&c.rsp_done) do return
		intrinsics.atomic_store(&c.rsp_busy, false)
		if c.live_on { upload_tex(c, rawptr(raw_data(c.fbuf))); c.tex_t = live_now(c) } // 1º frame do novo decoder
		// se o alvo andou muito durante o respawn, o check de janela abaixo re-pede
	}
	if !c.live_on {
		// o stream já provou acabar antes de `l`: respawnar de novo só spawnaria
		// ffmpeg em loop (~3x/s) até o playhead passar — congela no último frame
		if c.eof_at > 0 && l >= c.eof_at - 0.05 do return
		stream_seek_async(c, l)
		return
	}
	// speed mudou (1x↔2x): o -r do pipe atual está errado — respawna na taxa nova
	want_fps := live_want_fps(clip_view_speed(c))
	if abs(live_rate(c) - want_fps) > 0.6 {
		stream_seek_async(c, l)
		return
	}
	cur := live_now(c)
	// pulo p/ TRÁS compara com a posição ATUAL (cur), não com o início do stream
	// (live_base): o pipe só anda pra frente, então QUALQUER alvo atrás de cur é
	// inalcançável sem respawn. Comparar com live_base criava uma ZONA MORTA
	// [live_base, cur] que CRESCIA com o tempo tocado — clique p/ trás dentro dela
	// não fazia NADA (nem respawn, nem read) e o preview morria congelado/na
	// miniatura ("a imagem vai ficando ruim com o tempo"). Margem de 0.2s: o decoder
	// passa do alvo por até 1 frame (33ms) no catch-up, o que não deve respawnar.
	if l < cur - 0.2 || l > cur + 1.5 {
		stream_seek_async(c, l)
		return
	}
	// alcança no máx 3 frames por chamada: cada stream_read bloqueia no pipe do
	// ffmpeg; ler muitos de uma vez (após um respawn o vídeo fica ~0.3s atrás)
	// segurava a main e esvaziava o áudio. Com 3, o vídeo alcança em poucos frames
	// de UI sem travar — a 60fps sobra folga sobre os 30fps do vídeo. O orçamento
	// GLOBAL (g_read_budget) reparte entre os clipes quando há vários empilhados.
	guard := 0
	t0 := time.tick_now()
	for live_now(c) < l && guard < 3 && g_read_budget > 0 {
		if time.duration_milliseconds(time.tick_diff(t0, time.tick_now())) > READ_MS_MAX do break
		if !stream_read(c) do break
		guard += 1; g_read_budget -= 1
	}
}

// mostra o frame idx do cache em RAM (main thread — usa GL)
clip_show :: proc(c: ^Clip, idx: int) {
	cached := intrinsics.atomic_load(&c.cached)
	if cached == 0 do return
	i := clamp(idx, 0, cached - 1)
	if i != c.shown || !c.tex_ok {
		upload_tex(c, rawptr(raw_data(c.cache[i * FRAME:])))
		c.shown = i
	}
}

clip_close :: proc(c: ^Clip) {
	if c.closed do return // idempotente: remover do bin já fechou; não libera de novo no shutdown
	c.closed = true
	intrinsics.atomic_store(&c.stop, true)
	// mata TODOS os ffmpeg deste clipe ANTES dos joins: um worker travado num os.read
	// bloqueante (ex.: -ss pro fim de um vídeo de horas p/ uma miniatura) só observa
	// `stop` ENTRE leituras — sem matar o processo, o join (e a UI) congelaria.
	if c.job != nil { win.CloseHandle(c.job); c.job = nil }
	if c.imp_thr != nil { thread.join(c.imp_thr); thread.destroy(c.imp_thr); c.imp_thr = nil }
	if c.chunk_thr != nil { thread.join(c.chunk_thr); thread.destroy(c.chunk_thr); c.chunk_thr = nil } // worker polla `stop`
	if c.parts_thr != nil { thread.join(c.parts_thr); thread.destroy(c.parts_thr); c.parts_thr = nil } // idem (polla via audio_extract_wait)
	if c.rsp_thr != nil { thread.join(c.rsp_thr); thread.destroy(c.rsp_thr); c.rsp_thr = nil }          // respawn é curto (~300ms)
	if c.streaming { stream_stop(c); delete(c.fbuf) }
	else do delete(c.cache)
	delete(c.wave)
	delete(c.wave_rms)
	for i in 0 ..< c.thumbs_up do rl.UnloadTexture(c.thumbs[i]) // só as que subiram
	delete(c.thumbs)
	delete(c.thumb_px)
	if c.tex_ok do rl.UnloadTexture(c.tex)
	if c.has_audio do rl.UnloadMusicStream(c.music) // solta o handle antes de apagar
	os.remove(c.aud_path)                           // não deixa WAV órfão no temp
	os.remove(c.aud_head)
	os.remove(c.aud_ck[0])
	os.remove(c.aud_ck[1])
	os.remove(part_path(c, 0)) // FLAC completo
	delete(c.path)
	delete(c.name)
	delete(c.name_el)
	delete(c.vcodec)
	caps_free(c)
	delete(c.text)
	delete(c.aud_path)
	delete(c.aud_head)
	delete(c.aud_ck[0])
	delete(c.aud_ck[1])
	// torna o slot INERTE: os loops por clipe checam esses flags/ponteiros. Sem isto,
	// um tombstone (removido do bin) ainda seria "streaming/has_audio" com slices já
	// liberados -> use-after-free. (No shutdown é inofensivo: o app está saindo.)
	c.has_audio = false; c.streaming = false; c.tex_ok = false; c.live_on = false; c.chunk_busy = false
	intrinsics.atomic_store(&c.probed, false)
	// wave_rms JUNTO com wave: as guardas de wave_peak/wave_rms_at são por LEN, então um
	// slice liberado mas não zerado passa direto e lê memória morta. Hoje só não estoura
	// porque o desenho consulta wave_peak antes (wave=nil -> -1) e nunca chega no RMS.
	c.cache = nil; c.fbuf = nil; c.wave = nil; c.wave_rms = nil; c.thumbs = nil; c.thumb_px = nil
	c.path = ""; c.name = ""; c.name_el = nil; c.vcodec = ""
	c.aud_path = ""; c.aud_head = ""; c.aud_ck[0] = ""; c.aud_ck[1] = ""
	c.is_text = false; c.text = ""
}

// remove uma mídia do bin: tira seus segmentos da timeline, libera os recursos e
// marca o slot como tombstone (o array clips[] é FIXO — endereços estáveis p/ as
// threads; não compacta). O slot fica p/ ser reciclado por import_media.
remove_media :: proc(i: int) {
	if i < 0 || i >= nclips || intrinsics.atomic_load(&clips[i].failed) do return
	nm := cs(clips[i].name) // cstring no temp (cópia) — válida após liberar clips[i].name
	// 1) tira todos os segmentos dessa mídia da timeline (compacta segs, conserta índices globais)
	fixi :: proc(idx: ^int, removed: int) { if idx^ == removed do idx^ = -1; else if idx^ > removed do idx^ -= 1 }
	k := 0
	for k < nsegs {
		if segs[k].src == i {
			if play_clip == k && clips[i].has_audio do rl.PauseMusicStream(clips[i].music) // solta o áudio tocando
			// desloca seg_marked JUNTO (como remove_seg faz) — senão as marcas ficam
			// nos índices antigos e o "grupo" vira outro conjunto de clipes
			for j := k; j < nsegs - 1; j += 1 { segs[j] = segs[j + 1]; seg_marked[j] = seg_marked[j + 1] }
			seg_marked[nsegs - 1] = false
			nsegs -= 1
			fixi(&play_clip, k); fixi(&selected, k); fixi(&drag_clip, k); fixi(&sel_trans, k)
		} else {
			k += 1
		}
	}
	// 2) impede os workers de scrub E de vista dup de tocar num recurso que vai ser liberado
	if intrinsics.atomic_load(&scrub_req_c) == i do intrinsics.atomic_store(&scrub_req_c, -1)
	if intrinsics.atomic_load(&dup_req_c) == i {
		intrinsics.atomic_store(&dup_req_c, -1)
		intrinsics.atomic_add(&dup_req_seq, 1) // invalida o spawn em voo: a mídia dele vai embora
	}
	if bin_drag == i { bin_drag = -1; if st.drag == .Bin do st.drag = .None }
	if bin_sel == i do bin_sel = -1
	bin_marked[i] = false // não deixa marca presa num tombstone
	if src_preview == i { src_preview = -1; st.playing = false } // saía da prévia dessa mídia
	if preview_pending == i do preview_pending = -1 // prévia do export encomendada p/ este slot
	// 3) libera tudo e vira tombstone (media_ready() passa a dar false p/ este slot)
	clip_close(&clips[i])
	intrinsics.atomic_store(&clips[i].failed, true)
	st.playing = false
	seek_global(st.playhead)
	// remover mídia não é desfazível: além do baseline, LIMPA as pilhas — um Ctrl+Z
	// depois daqui restauraria segmentos apontando pra mídia morta (tombstone)
	undo_top = 0; redo_top = 0
	history_baseline()
	set_toast(rl.TextFormat("%s removido do editor", nm))
}

// mídia válida e pronta o suficiente para uso (probe ok, não falhou)
media_ready :: proc(i: int) -> bool {
	return intrinsics.atomic_load(&clips[i].probed) && !intrinsics.atomic_load(&clips[i].failed)
}

// a mídia i casa com a busca do bin? (nome contém o termo, sem diferenciar maiúsculas)
media_matches :: proc(i: int) -> bool {
	if tf_search.len == 0 do return true
	q := strings.to_lower(string(tf_search.buf[:tf_search.len]), context.temp_allocator)
	nm := strings.to_lower(clips[i].name, context.temp_allocator)
	return strings.contains(nm, q)
}
