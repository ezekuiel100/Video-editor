package main

// Mock de editor de vídeo não-linear, em Odin + raylib.
// UI immediate-mode + timeline com MÚLTIPLOS clipes: cada clipe pré-decodifica
// seus frames para a RAM (thread de fundo) e tem seu próprio áudio (rl.Music).
// Os clipes tocam em sequência; a sincronia A/V é mantida dentro de cada clipe
// (o áudio do clipe ativo é o relógio-mestre).

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
import "core:unicode/utf8"
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
stream_hi: bool // false = Baixa (360p); true = Alta (720p). Global (estilo NLE)
stream_dw :: proc() -> i32 { return stream_hi ? STREAM_HI_W : STREAM_LO_W }
stream_dh :: proc() -> i32 { return stream_hi ? STREAM_HI_H : STREAM_LO_H }
// scrub (streaming): distância MÁX (s, no tempo da fonte) que o último frame decodificado
// pode estar do cursor antes de cair pra miniatura 96×54 do filmstrip. Era 1.5 fixo — curto
// demais: num arrasto lento fundo num vídeo de horas cada seek custa MAIS que 1.5s de
// movimento do playhead, então o worker nunca chegava a <1.5s e o preview vivia preso na
// miniatura borrada. 4s mantém o frame REAL (360/720p, levemente atrás do cursor) na tela
// enquanto o worker persegue; saltos grandes (clique-seek, arrasto rápido) passam de 4s e
// ainda mostram a miniatura na POSIÇÃO certa. Cache (clipes curtos) decodifica ao vivo — nunca cai aqui.
SCRUB_SHARP_S :: f32(4.0)
// scrub: acima desta latência (ms) de um decode de scrub por SOFTWARE, o clipe migra p/
// NVDEC no scrub (c.scrub_hw). 700ms é conservador: mesmo o pior init de cuvid (~575ms) +
// decode (~23ms) fica abaixo, então trocar SEMPRE melhora onde dispara (codec pesado).
// Codec leve (SW rápido) nunca cruza o limiar e segue em SW — sem disputar sessão NVDEC à toa.
SCRUB_HW_MS :: f64(700)

MAX_CLIPS     :: 12
DBG_PLAY      :: false // LOG de diagnóstico do playback a cada frame (stderr); ligue p/ depurar
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

// ---------- paleta (tema escuro) ----------
BG       :: rl.Color{ 24, 26, 32, 255 }
PANEL    :: rl.Color{ 33, 36, 44, 255 }
PANEL2   :: rl.Color{ 28, 30, 37, 255 }
TOPBAR   :: rl.Color{ 20, 22, 27, 255 }
LINE     :: rl.Color{ 46, 49, 58, 255 }
TEXT     :: rl.Color{ 208, 212, 219, 255 }
MUTED    :: rl.Color{ 122, 128, 140, 255 }
ACCENT   :: rl.Color{ 40, 200, 182, 255 }
ACCENT_D :: rl.Color{ 24, 120, 110, 255 }
PLAYHEAD :: rl.Color{ 236, 72, 60, 255 }
CLIP     :: rl.Color{ 48, 78, 98, 255 }
CLIP_HDR :: rl.Color{ 62, 100, 122, 255 }
AUDIOCLIP:: rl.Color{ 44, 66, 60, 255 }
HOVER    :: rl.Color{ 48, 52, 62, 255 }

ui_font: rl.Font
g_us: f32 = 1.3 // escala da UI (fontes/barras) — janelas grandes ficam mais legíveis
sdf_shader: rl.Shader // shader do texto SDF (nítido em qualquer tamanho)
sdf_ok: bool          // SDF carregou? (senão desenha sem shader)
// fontes disponíveis p/ os clipes de TEXTO (índice 0 = Segoe UI = ui_font)
TextFont :: struct { font: rl.Font, name: cstring }
text_fonts: [dynamic]TextFont
// --- carga das fontes de texto em 2 ESTÁGIOS (CPU na thread, GL na main) ---
// gerar o SDF de 560 glifos a 64px custa ~300ms POR FONTE (~2.7s pelas 9) e dominava o
// startup (o app abria em ~3.3s). text_fonts_worker faz a parte de CPU (LoadFileData/
// LoadFontData/GenImageFontAtlas — sem GL, thread-safe); ensure_text_fonts() (main,
// 1x/frame) sobe a textura de cada slot pronto, em ordem. O seletor de fonte só aparece
// com len(text_fonts)>1, então a UI se ajusta sozinha enquanto carregam (~2.5s).
SDF_SZ    :: i32(64) // tamanho-base dos atlas SDF (UI e fontes de texto)
FONT_CP_N :: 560     // codepoints 32..591 (acentos PT-BR)
TFontCPU :: struct {
	glyphs: [^]rl.GlyphInfo,
	recs:   [^]rl.Rectangle,
	atlas:  rl.Image,
	name:   cstring,
	ready:  bool, // atômico: worker terminou este slot (main pode subir a textura)
}
tf_cpu:  [9]TFontCPU
tf_up:   int  // (main) próximo slot a subir p/ text_fonts
tf_done: bool // atômico: worker acabou (slots não-ready a partir daqui nunca ficarão prontos)
tf_thr:  ^thread.Thread
// fragment shader SDF: usa a distância (canal alpha) + derivada da tela p/ um alpha
// anti-serrilhado independente da escala → texto sempre nítido, sem borrar no downscale
SDF_FS : cstring : `#version 330
in vec2 fragTexCoord; in vec4 fragColor;
uniform sampler2D texture0; uniform vec4 colDiffuse;
out vec4 finalColor;
void main() {
    float d = texture(texture0, fragTexCoord).a - 0.5;
    float w = fwidth(d);
    float a = smoothstep(-w, w, d);
    finalColor = vec4(fragColor.rgb*colDiffuse.rgb, fragColor.a*colDiffuse.a*a);
}`

// --- EFEITO: distorção radial (bulge/pinch) para o vídeo ---
bulge_shader: rl.Shader
bulge_ok: bool
bulge_loc_uv0, bulge_loc_uv1, bulge_loc_center, bulge_loc_strength, bulge_loc_radius, bulge_loc_aspect: i32
fx_loc_bright, fx_loc_contrast, fx_loc_satur, fx_loc_look, fx_loc_vignette, fx_loc_temp: i32 // uniforms de COR
fx_loc_rgb: i32 // uniform da separação RGB
BULGE_R_DEF :: f32(0.5) // raio padrão do efeito (quando bulge_r==0)
WOBBLE_HZ_DEF :: f32(2) // frequência padrão do wobble (Hz, quando wobble_speed==0)
// desloca a coord de textura em direção ao (bulge>0) ou p/ longe do (bulge<0) centro,
// com queda suave até a borda do raio → amplia/aperta uma região circular (efeito "rosto
// inflado" dos memes). Trabalha em coords LOCAIS da sub-região amostrada (respeita crop),
// e clampa a amostragem à região p/ não vazar p/ vizinhos no atlas.
BULGE_FS : cstring : `#version 330
in vec2 fragTexCoord; in vec4 fragColor;
uniform sampler2D texture0; uniform vec4 colDiffuse;
uniform vec2 uv0;       // canto sup-esq da região amostrada (coords de textura)
uniform vec2 uv1;       // canto inf-dir
uniform vec2 center;    // centro do efeito em [0,1] LOCAL da região
uniform float strength; // >0 infla (bulge), <0 aperta (pinch)
uniform float radius;   // raio do efeito [0..1] local
uniform float aspect;   // largura/altura da região exibida (efeito circular)
uniform float bright;   // COR: brilho somado (-1..1)
uniform float contrast; // COR: contraste (1 = neutro)
uniform float satur;    // COR: saturação (1 = neutro)
uniform float look;     // COR: 0 nenhum | 1 P&B | 2 sépia | 3 inverter
uniform float vignette; // COR: vinheta 0..1
uniform float temp;     // COR: temperatura -1(frio)..1(quente)
uniform vec2  rgb;      // EFEITO: separação RGB (deslocamento em coords de textura; 0 = desligado)
out vec4 finalColor;
void main() {
    vec2 span = uv1 - uv0;
    vec2 local = (fragTexCoord - uv0) / span;   // [0,1] dentro da região
    vec2 d = local - center;
    vec2 da = vec2(d.x*aspect, d.y);            // distância corrigida p/ ser circular
    float dist = length(da);
    vec2 uv = local;
    if (dist < radius) {
        float pct = 1.0 - dist/radius;          // 1 no centro -> 0 na borda
        float amt = strength*pct*pct;           // suave (zera na borda)
        uv = local - d*amt;                     // amt>0: amostra p/ o centro => amplia
    }
    vec2 tex = uv0 + clamp(uv, 0.0, 1.0)*span;
    vec4 src = texture(texture0, tex);
    vec3 c = src.rgb;
    if (rgb.x != 0.0 || rgb.y != 0.0) {           // SEPARAÇÃO RGB: R e B amostrados deslocados
        c.r = texture(texture0, clamp(tex + rgb, uv0, uv1)).r;
        c.b = texture(texture0, clamp(tex - rgb, uv0, uv1)).b;
    }
    // ordem casa com o filtro eq do ffmpeg (export): contraste -> brilho -> temp -> saturação
    c = (c - 0.5) * contrast + 0.5;
    c += bright;
    c.r += temp*0.12; c.b -= temp*0.12;           // temperatura (quente>0: +vermelho, -azul)
    float g = dot(c, vec3(0.299, 0.587, 0.114));  // luma
    c = mix(vec3(g), c, satur);
    if (look > 0.5 && look < 1.5) {               // P&B
        c = vec3(dot(c, vec3(0.299, 0.587, 0.114)));
    } else if (look > 1.5 && look < 2.5) {        // sépia
        float y = dot(c, vec3(0.299, 0.587, 0.114));
        c = vec3(y*1.07, y*0.74, y*0.43);
    } else if (look > 2.5) {                       // inverter
        c = vec3(1.0) - c;
    }
    if (vignette > 0.001) {                        // escurece as bordas
        vec2 vd = local - vec2(0.5);
        float rr = length(vec2(vd.x*aspect, vd.y));
        float v = smoothstep(0.75, 0.30, rr);      // 1 no centro -> 0 nas quinas
        c *= mix(1.0, v, vignette);
    }
    c = clamp(c, 0.0, 1.0);
    finalColor = vec4(c, src.a)*colDiffuse*fragColor;
}`

// força efetiva do bulge no tempo local `t` (s): base + oscilação do wobble. Usado no
// preview (força passada ao shader) E na geração dos mapas do export — MESMA fórmula.
bulge_at :: proc(sg: Seg, t: f32) -> f32 {
	if abs(sg.wobble) < 0.0001 do return sg.bulge
	hz := sg.wobble_speed <= 0 ? WOBBLE_HZ_DEF : sg.wobble_speed
	return sg.bulge + sg.wobble * math.sin(t * 2*math.PI * hz)
}
// o efeito está ativo (estático OU animado)?
bulge_active :: proc(sg: Seg) -> bool { return abs(sg.bulge) > 0.001 || abs(sg.wobble) > 0.001 }
// algum efeito de COR ativo? (qualquer campo fx_* != neutro)
color_active :: proc(sg: Seg) -> bool {
	return abs(sg.fx_bright) > 0.001 || abs(sg.fx_contrast) > 0.001 || abs(sg.fx_satur) > 0.001 ||
	       sg.fx_look > 0.5 || sg.fx_vignette > 0.001 || abs(sg.fx_temp) > 0.001
}
// qualquer efeito (distorção OU cor) ativo? -> liga o shader no draw
fx_any :: proc(sg: Seg) -> bool { return bulge_active(sg) || color_active(sg) }

State :: struct {
	active_tab: int,
	playing:    bool,
	playhead:   f32, // segundos, tempo absoluto na timeline
	zoom:       f32, // pixels por segundo = 20 * zoom
	drag:       Drag,
}
Drag :: enum { None, Playhead, Clip, Bin, FadeIn, FadeOut, Vol, PreviewMove, Trans, TransDur, FxCenter, FxLib, FxClip, FxTrim, FxCtr }
trans_drag: int = -1 // tipo de transição sendo arrastado do painel (-1 = nenhum)
sel_trans: int = -1  // transição/fade SELECIONADO na timeline = índice do seg (-1 = nenhum)
sel_trans_kind: int = 0 // tipo do selecionado: 0=dissolver, 1=fade preto de entrada, 2=fade preto de saída
VOL_MAX :: f32(2) // teto do volume por segmento (200%) — usado na linha de volume e sliders
st: State

// Um segmento é uma COLOCAÇÃO na timeline: aponta para uma mídia-fonte (clips[])
// e recorta um trecho dela (in_off..in_off+dur). Vários segmentos podem apontar
// para a mesma fonte — é isso que permite cortar/dividir um clipe sem duplicar
// decode, áudio ou textura (tudo continua na fonte).
Seg :: struct {
	src:    int, // índice da mídia-fonte em clips[]
	track:  int, // trilha (0 = base/V1 embaixo; maior = por cima — vence no preview)
	start:  f32, // tempo na timeline onde o segmento começa (s)
	in_off: f32, // deslocamento dentro da fonte (s) — ponto de entrada
	dur:    f32, // duração do segmento (s)
	// controles de áudio por segmento (aplicados no stream ativo via SetMusicVolume)
	vol:      f32,  // multiplicador de volume (1 = 100%); 0 no zero-value tratado como 1
	muted:    bool, // silencia este segmento
	fade_in:  f32,  // duração do fade-in de áudio (s)
	fade_out: f32,  // duração do fade-out de áudio (s)
	// transform de vídeo (compositing das trilhas): PiP, split-screen, etc.
	scale:    f32,  // escala (1 = 100%); 0 no zero-value tratado como 1
	px, py:   f32,  // posição: fração do frame a partir do centro (0,0 = centro)
	rot:      f32,  // rotação (graus)
	opacity:  f32,  // opacidade (1 = opaco); 0 no zero-value tratado como 1
	// velocidade de reprodução: dur é SEMPRE tempo de timeline; a fonte consumida é
	// dur*speed (a partir de in_off). speed 2 = 2x (mais rápido); 0.5 = câmera lenta.
	speed:    f32,  // 1 = normal; 0 no zero-value tratado como 1
	// TRANSIÇÃO (dissolver): blend de `trans` segundos com o clipe anterior adjacente
	// na mesma trilha. Usa o "handle" da fonte (footage antes de in_off): durante
	// [start-trans, start] o clipe anterior some enquanto ESTE entra. 0 = sem transição.
	trans:    f32,
	// FADE PRETO: o clipe surge do preto nos primeiros `vfin` s e some no preto nos
	// últimos `vfout` s (rampa de opacidade; na trilha base = preto de verdade).
	vfin:     f32,
	vfout:    f32,
	// RECORTE ESPACIAL (crop): sub-região do quadro a MANTER, em frações [0,1] da fonte
	// (crop_w<=0 no zero-value = quadro inteiro, sem recorte). A região recortada é ajustada
	// ao canvas preservando o aspecto dela; escala/posição/rotação atuam por cima.
	crop_x, crop_y, crop_w, crop_h: f32,
	// ZOOM ANIMADO (Pan & Zoom estilo NLE): quando zoom_anim=true, a REGIÃO de recorte
	// vai de (crop_*) no INÍCIO do clipe a (crop2_*) no FIM, interpolada no tempo com easing
	// suave. Reaproveita TODO o render/escala do crop (a região menor = mais zoom). Preview
	// anima ao vivo; export = TODO (crop com expressão em t). zoom_anim=false = recorte estático.
	zoom_anim: bool,
	crop2_x, crop2_y, crop2_w, crop2_h: f32,
	// EFEITO de distorção radial (bulge/pinch): infla o rosto/centro (bulge>0) ou aperta
	// (bulge<0). bulge=0 no zero-value = efeito DESLIGADO. Centro do efeito = (0.5+bulge_x,
	// 0.5+bulge_y) em coords LOCAIS da região exibida (bulge_x/y = deslocamento do meio).
	// bulge_r = raio [0..1]; 0 no zero-value tratado como BULGE_R_DEF. Aplicado por um
	// fragment shader no preview (ao vivo); export ainda não mapeado (TODO).
	bulge:   f32,
	bulge_x: f32,
	bulge_y: f32,
	bulge_r: f32,
	// WOBBLE: anima a distorção — a força efetiva oscila `bulge ± wobble` por uma senoide
	// no tempo LOCAL do segmento (playhead-start). wobble=0 = estático. wobble_speed em Hz
	// (0 no zero-value tratado como WOBBLE_HZ_DEF). Preview passa a força já modulada ao
	// shader; export gera 1 período de mapas e faz o remap ciclar (ver start_export).
	wobble:       f32,
	wobble_speed: f32,
	// SÓ-ÁUDIO: segmento de trilha de áudio criado por "Separar áudio" — a fonte é um
	// VÍDEO, mas este segmento toca apenas o áudio dela (o preview/export ignoram o
	// vídeo dele). Falso no zero-value = comportamento normal pela mídia.
	aonly: bool,
	// EFEITOS DE COR: aplicados no MESMO fragment shader do bulge (preview ao vivo) e
	// mapeados p/ filtros do ffmpeg no export (eq/hue/negate/colorchannelmixer/vignette).
	// TODOS os campos têm 0 = NEUTRO (zero-value = sem efeito; projetos antigos abrem iguais).
	fx_bright:   f32, // brilho    -1..1 (0 neutro; somado)
	fx_contrast: f32, // contraste -1..1 (0 neutro; efetivo = 1+valor, em torno de 0.5)
	fx_satur:    f32, // saturação -1..1 (0 neutro; efetivo = 1+valor)
	fx_look:     f32, // visual: 0 nenhum | 1 P&B | 2 sépia | 3 inverter
	fx_vignette: f32, // vinheta 0..1 (escurece as bordas)
	fx_temp:     f32, // temperatura -1(frio)..1(quente): +R/-B quente, -R/+B frio
}
// Trilhas DINÂMICAS (estilo NLE). O índice da trilha carrega o tipo: vídeo ocupa a faixa
// FIXA [0, MAXV) e áudio a faixa FIXA [MAXV, MAXV+MAXA). Manter a base do áudio fixa em MAXV é o
// que permite adicionar/remover trilhas de vídeo SEM re-indexar os segmentos de áudio. `g_nv`/`g_na`
// contam quantas trilhas de cada tipo estão VISÍVEIS agora (o resto da faixa fica reservado/oculto).
MAXV :: 12 // capacidade máx de trilhas de VÍDEO  (índices 0..MAXV-1)
MAXA :: 12 // capacidade máx de trilhas de ÁUDIO  (índices MAXV..MAXV+MAXA-1)
MAXTRACKS :: MAXV + MAXA
g_nv: int = 3 // trilhas de vídeo visíveis (V1..Vg_nv)
g_na: int = 2 // trilhas de áudio visíveis (A1..Ag_na)
is_audio_track :: proc(t: int) -> bool { return t >= MAXV }
// cria uma trilha nova e devolve seu índice (-1 se atingiu a capacidade). Vídeo entra no TOPO
// (maior índice = vence o compositing); áudio entra embaixo. Nenhum re-index: a base é fixa.
add_video_track :: proc() -> int { if g_nv >= MAXV do return -1; g_nv += 1; return g_nv - 1 }
add_audio_track :: proc() -> int { if g_na >= MAXA do return -1; g_na += 1; return MAXV + g_na - 1 }
track_muted:  [MAXTRACKS]bool // trilha silenciada (não toca áudio nenhum dos seus segmentos)
track_locked: [MAXTRACKS]bool // trilha bloqueada: seus segmentos não movem, aparam nem cortam
track_hidden: [MAXTRACKS]bool // trilha de vídeo oculta: seus segmentos não aparecem no preview nem no export (áudio continua)
MAX_SEGS :: 64
segs:  [MAX_SEGS]Seg
nsegs: int

// EFEITO como CLIPE na timeline (estilo NLE): ocupa [start, start+dur] numa faixa própria
// acima das trilhas e aplica seu efeito VISUAL a todo o quadro durante esse intervalo. Cada
// clipe guarda seus PRÓPRIOS parâmetros (editáveis ao dar duplo-clique). kind: 0 = Distorção,
// 1 = Separação RGB.
FX_DISTORT :: 0
FX_RGB     :: 1
FxSeg :: struct {
	kind:   int,
	track:  int, // trilha de VÍDEO onde o efeito está (afeta essa trilha e as ABAIXO dela: índice <= track)
	start, dur: f32,
	amount: f32, // Distorção: intensidade | RGB: intensidade da separação
	radius: f32, // Distorção: raio
	cx, cy: f32, // Distorção: centro (offset do meio)
	wobble: f32, // Distorção: tremor
	speed:  f32, // Distorção: velocidade do tremor
	angle:  f32, // RGB: direção (0=horizontal, 0.25=vertical "cima-baixo")
}
MAX_FX :: 32
fxsegs:      [MAX_FX]FxSeg
nfx:         int
fx_sel:      int = -1 // clipe de efeito selecionado (-1 = nenhum)
fxlib_drag:  int = -1 // índice em fx_lib sendo arrastado do painel p/ a timeline

// --- undo/redo: snapshot do documento (só os segmentos — Seg é struct puro, cópia
// barata). Detecção AUTOMÁTICA: qualquer mudança em segs vira uma entrada quando a
// interação assenta (fora de arrasto/slider), sem instrumentar cada operação. ---
// g_nv/g_na entram no snapshot: sem eles, desfazer podia devolver um segmento a uma
// trilha removida (track_row negativo = desenhado sobre a régua e inalcançável)
Snapshot :: struct { segs: [MAX_SEGS]Seg, nsegs: int, fxsegs: [MAX_FX]FxSeg, nfx: int, nv, na: int }
MAX_UNDO :: 100
undo_stack: [MAX_UNDO]Snapshot
undo_top:   int
redo_stack: [MAX_UNDO]Snapshot
redo_top:   int
committed:  Snapshot // último estado estável (baseline p/ detectar mudança)
committed_ok: bool

drag_clip: int = -1 // SEGMENTO sendo arrastado na timeline
drag_trim: int = 0  // 0 = mover | -1 = aparar borda esquerda | +1 = aparar borda direita
fx_grab_dt: f32     // offset (s) do agarrão ao mover um clipe de efeito
grab_dt:   f32      // deslocamento (s) entre o mouse e o início do segmento
bin_drag:  int = -1 // item do bin (FONTE) sendo arrastado para a timeline (âncora do arrasto em lote)
bin_sel:   int = -1 // item do bin com FOCO (última seleção) — highlight/prévia
bin_marked: [MAX_CLIPS]bool // itens MARCADOS p/ seleção múltipla (Ctrl/Shift+clique); arrastar/Delete em lote
bin_marquee: bool           // seleção por RETÂNGULO em curso (arrastar sobre as miniaturas)
bin_marquee_start: rl.Vector2 // âncora do retângulo (onde o botão foi pressionado)
bin_marquee_moved: bool     // passou do limiar p/ contar como retângulo (senão é clique vazio = desmarca)
bin_marquee_add: bool       // Ctrl/Shift no início = soma à seleção; senão substitui
src_preview: int = -1 // mídia em PRÉVIA de origem no player (duplo-clique no bin); -1 = modo timeline
src_t:       f32      // posição (s) na fonte durante a prévia de origem
bin_click_t: f64 = -1 // tempo do último clique no bin (p/ detectar duplo-clique)
bin_click_i: int = -1 // item do último clique no bin
player_vol:  f32 = 1  // volume do PLAYER (monitor): escala o que se OUVE, NÃO altera o áudio dos segmentos
vol_popup:   bool     // popup do slider VERTICAL de volume (abre ao clicar no alto-falante)
shot_n:      int      // contador de screenshots (nome do arquivo)
fullscreen_preview: bool // preview de vídeo ocupando a janela toda
fs_ctl_alpha: f32        // opacidade atual dos controles em tela cheia (0..1, animada)
fs_ctl_hold:  f32        // segundos que os controles ainda ficam visíveis (auto-hide estilo NLE)
fs_vol_drag:  bool       // arrastando o slider de volume da barra em tela cheia
player_seek_drag: bool   // arrastando a barra de progresso do player
g_frame:     rl.Rectangle // retângulo do frame base no preview (p/ mapear transform<->tela)
g_insp_card: rl.Rectangle // retângulo do cartão do inspector (p/ não roubar cliques do preview)
prev_grab:   rl.Vector2   // offset do mouse ao centro do clipe ao começar a mover no preview
g_pv_x:      f32 = -1     // guia VERTICAL de alinhamento no preview (x na tela; -1 = nenhuma)
g_ph_y:      f32 = -1     // guia HORIZONTAL de alinhamento no preview (y na tela; -1 = nenhuma)
proj_ar:     f32 = 16.0/9.0 // proporção (largura/altura) do PROJETO — canvas de saída (preview)
proj_w:      int = 1920     // resolução de SAÍDA (export); proj_ar = proj_w/proj_h. Editável em Config. do Projeto
proj_h:      int = 1080
ar_auto:     bool = true    // proj_ar ainda segue o 1º vídeo da timeline (autodetecção); escolher preset e abrir projeto desligam
ar_menu_open: bool          // dropdown rápido de presets de proporção aberto
tf_pw, tf_ph: TField        // campos Largura/Altura do modal "Configurações do Projeto"
ps_wf, ps_hf: bool          // foco dos campos L/A do modal
file_menu_open: bool       // dropdown do menu Arquivo aberto

// --- menu de CONTEXTO da timeline (botão direito): copiar/colar/duplicar/etc.
// Aberto no update (botão direito sobre g_vlane); cliques tratados no UPDATE
// (antes da timeline reagir) e desenhado por último no draw (por cima de tudo).
ctx_open: bool
ctx_pos:  rl.Vector2 // canto do menu (posição do clique)
ctx_seg:  int = -1   // segmento alvo (-1 = área vazia: só "Colar aqui")
ctx_time: f32        // tempo da timeline no clique (colar/dividir usam)
ctx_ate:  bool       // este frame: o press fechou/executou o menu — não vaza p/ a UI de trás
CTX_W  :: f32(232)
CTX_IH :: f32(30)
g_file_menu_x: f32         // x do menu Arquivo (p/ posicionar o dropdown)
AspectPreset :: struct { label: cstring, ar: f32 }
AR_PRESETS := []AspectPreset{ {"16:9", 16.0/9}, {"9:16", 9.0/16}, {"1:1", 1}, {"4:3", 4.0/3}, {"3:4", 3.0/4}, {"2.35:1", 2.35}, {"21:9", 21.0/9} }

// rótulo do preset que casa com `ar` (ou "Custom"). Usado no botão de proporção e nos toasts.
ar_label :: proc(ar: f32) -> cstring {
	for p in AR_PRESETS do if abs(ar - p.ar) < 0.001 do return p.label
	return "Custom"
}

// define a resolução de SAÍDA (pares — ffmpeg exige) e a proporção derivada (usada no preview).
set_proj_res :: proc(w, h: int) {
	proj_w = max(2, w - (w & 1)); proj_h = max(2, h - (h & 1))
	proj_ar = f32(proj_w) / f32(proj_h)
}
// define a proporção e deriva uma resolução padrão (lado menor = 1080).
set_proj_ar :: proc(ar: f32) {
	if ar >= 1 do set_proj_res(int(f32(1080)*ar + 0.5), 1080)
	else       do set_proj_res(1080, int(f32(1080)/ar + 0.5))
}
// reduz W:H pelo maior divisor comum (ex.: 720,732 -> 60,61).
ratio_reduce :: proc(w, h: int) -> (int, int) {
	g := max(1, w); b := max(0, h)
	for b != 0 { g, b = b, g % b }
	if g <= 0 do g = 1
	return w/g, h/g
}
// razão irredutível "W:H" p/ exibir (ex.: 720x732 -> "60:61").
ratio_label :: proc(w, h: int) -> cstring {
	a, b := ratio_reduce(w, h)
	return fmt.ctprintf("%d:%d", a, b)
}

// AUTODETECÇÃO de formato: o 1º vídeo COLOCADO NA TIMELINE (não o 1º importado no bin) num projeto
// novo define a resolução do canvas, como qualquer NLE. Chamado por add_seg; áudio/texto
// (vw=0) não contam, então vale o 1º clipe com imagem. Adota o tamanho EXATO da fonte (sem encaixar
// em preset) — assim o canvas casa com o vídeo e NÃO sobra tarja nos cantos; vídeo de aspecto padrão
// (16:9 etc.) já vira o próprio preset. Escolher preset na mão, abrir projeto e "Novo projeto" desligam.
maybe_adopt_aspect :: proc(c: ^Clip) {
	if !ar_auto || c.vw <= 0 || c.vh <= 0 do return // travado, ou áudio/texto/probe sem dimensões
	ar_auto = false
	set_proj_res(int(c.vw), int(c.vh)) // tamanho exato do 1º vídeo: canvas casa, sem sobras
	dirty = true
	set_toast(rl.TextFormat("Formato do projeto: %dx%d (%s)", i32(proj_w), i32(proj_h), ratio_label(proj_w, proj_h)))
}

// proporção do CANVAS de preview: na prévia de origem (duplo-clique no bin) segue a PRÓPRIA
// fonte; caso contrário, o projeto. Assim um vídeo 9:16 aparece 9:16 mesmo num projeto 16:9.
preview_ar :: proc() -> f32 {
	if src_preview >= 0 && src_preview < nclips {
		c := &clips[src_preview]
		if c.vw > 0 && c.vh > 0 do return f32(c.vw) / f32(c.vh)
	}
	return proj_ar
}

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

// --- exportação (render via ffmpeg -filter_complex, thread de fundo) ---
export_run:   bool // atômico: exportando
export_pct:   f32  // progresso 0..1 (escrito pela thread, lido no draw)
export_ok:    bool // resultado (válido quando export_run cai p/ false)
export_total: f32  // duração total (p/ calcular o %)
export_out:   string // caminho do arquivo de saída (heap)
export_thr:   ^thread.Thread
export_job:   win.HANDLE // mata o ffmpeg do export ao fechar o app
export_r:     ^os.File   // ponta de leitura do -progress (stderr do ffmpeg)
export_ps:    os.Process
export_was_running: bool  // (main) p/ avisar quando terminar
export_gpu:   bool = true // codificar com NVENC (GPU)
// QUALIDADE da exportação: define o CQ (NVENC) / CRF (x264) — nº maior = arquivo menor.
// Auto = qualidade alta com TETO de bitrate ≈ o da fonte (mantém o arquivo ~ tamanho do
// original em vez de inchar). Padrão: Média (equilíbrio tamanho×qualidade).
ExportQual :: enum { High, Medium, Low, Auto }
export_qual: ExportQual = .Medium
// FORMATO/codec de saída (barra lateral do modal de exportar):
//   MP4 = H.264 (máx. compatibilidade), HEVC = H.265 (menor, menos compatível),
//   WEBM = VP9 (web; sempre CPU, mais lento), MP3 = só a trilha de áudio.
ExportFmt :: enum { MP4, HEVC, WEBM, MP3 }
export_fmt: ExportFmt = .MP4
export_fmt_ext :: proc(f: ExportFmt) -> string {
	switch f {
	case .WEBM: return ".webm"
	case .MP3:  return ".mp3"
	case .MP4, .HEVC: return ".mp4"
	}
	return ".mp4"
}
// prévia AO VIVO da exportação: um 2º ramo do filtro (split) manda frames rgb24
// reduzidos pelo stdout; a thread os lê e a main sobe na textura do overlay.
PREV_W :: i32(480)
PREV_H :: i32(270)
PREV_BYTES :: int(PREV_W) * int(PREV_H) * 3
export_prev_r:    ^os.File        // stdout do ffmpeg: frames rgb24 da prévia
export_prev_thr:  ^thread.Thread
export_prev_a:    []u8            // buffer duplo (evita rasgo entre worker e main)
export_prev_b:    []u8
export_prev_pub:  int = -1        // atômico: slot publicado (0=a, 1=b, -1=nenhum)
export_prev_wslot: int            // (worker) slot que está preenchendo
export_prev_seq:  int             // atômico: nº de frames publicados
export_prev_last: int             // (main) último seq já subido na textura
export_prev_tex:  rl.Texture2D
export_prev_tex_ok: bool
export_paused: bool // (main) ffmpeg suspenso
export_cancel: bool // (main) exportação cancelada pelo usuário (não é falha)
export_tmp_files: [dynamic]string // PNGs de texto gerados p/ o export (removidos no fim)
g_exp_pause_btn:  rl.Rectangle // rects dos botões do overlay (draw preenche, update lê)
g_exp_cancel_btn: rl.Rectangle

// --- modais (exportar / screenshot / conclusão) ---
Modal :: enum { None, Export, Shot, Done, Confirm, Crop, ProjSettings }
// ação adiada até o usuário responder o "salvar alterações?" (modal Confirm)
Pending :: enum { None, Close, New, Open }
pending_action: Pending
dirty: bool // há edições não salvas na timeline (some ao salvar/abrir/novo)
modal:     Modal
save_dir:  string  // pasta de destino (heap, dono)
shot_ext:  int     // 0=png 1=jpg
done_path: string  // caminho do último arquivo exportado (heap) — modal de conclusão
g_modal_draw: bool  // true enquanto draw_modal roda (libera cliques dentro do modal)
preview_pending: int = -1 // clip a dar prévia quando o import do export terminar
// campo de texto editável reutilizável (cursor + seleção com mouse/teclado, clipboard).
// Usado pelo inspector de texto E pelos campos "Nome" dos modais export/screenshot.
TField :: struct {
	buf:     [256]u8,
	len:     int,   // bytes usados
	caret:   int,   // cursor (índice em BYTES no UTF-8)
	sel:     int,   // âncora da seleção (caret==sel: sem seleção)
	drag:    bool,  // arrastando p/ selecionar
	click_t: f64,   // último clique (duplo-clique)
	scroll:  f32,   // rolagem horizontal p/ manter o cursor visível
}
tf_text: TField    // conteúdo do clipe de texto (inspector)
tf_name: TField    // nome do arquivo (modais)
tf_search: TField  // busca no bin de mídia (subbar)
txt_edit:   bool   // foco do campo do inspector (gate dos atalhos da timeline no update)
name_focus: bool   // foco do campo de nome nos modais
search_focus: bool // foco do campo de busca de mídia
g_vlane:   rl.Rectangle // retângulo de TODAS as trilhas (p/ hit-test do drop do bin)
g_newv_zone: rl.Rectangle // banda escura acima do vídeo: soltar aqui cria trilha de vídeo nova
g_newa_zone: rl.Rectangle // banda escura abaixo do áudio: soltar aqui cria trilha de áudio nova
g_lanes_top: f32        // y do topo da área das trilhas (p/ mapear Y<->trilha)
g_track_h:   f32 = 84   // altura de cada trilha (px)
g_track_gap: f32 = 3    // espaço vertical entre trilhas
g_view_w:  f32          // largura visível da timeline (px), guardada no draw p/ o atalho de ajuste
snap_line: f32 = -1 // tempo (s) da guia de encaixe ativa (-1 = nenhuma)
SNAP_PX :: 10.0     // distância (px) para o encaixe magnético
DROP_LEAD :: f32(64) // ao soltar do bin, a borda esq. do clipe fica ~64px ADIANTADA do mouse
                     // (mais fácil encaixar no início da timeline sem cravar o cursor no canto)
selected: int = -1  // SEGMENTO com FOCO na timeline (-1 = nenhum) — usado pelo inspector
seg_marked: [MAX_SEGS]bool // segmentos MARCADOS p/ seleção múltipla (Ctrl/Shift+clique, marquee); mover/Delete em grupo
// --- marquee de seleção na TIMELINE (arrastar em área vazia p/ selecionar vários) ---
tl_marquee:       bool
tl_marquee_start: rl.Vector2
tl_marquee_moved: bool
tl_marquee_add:   bool        // Ctrl/Shift no início = soma à seleção
// --- prévia do DROP do bin na timeline (mostra onde a mídia vai ficar) ---
bin_drop_show:  bool
bin_drop_tr:    int
bin_drop_start: f32
bin_drop_dur:   f32
bin_drop_newtrack: bool         // drop cria uma trilha NOVA: footprint desenhado sobre a banda "+ trilha"
bin_drop_zone: rl.Rectangle     // retângulo dessa banda (p/ posicionar o footprint da prévia)
bin_empty_click_t: f64 = -1   // último clique em área vazia do bin (importar por clique/duplo-clique)
blade_mode: bool    // ferramenta lâmina: clicar num segmento corta ali (estilo NLE)
tl_scroll: f32      // deslocamento horizontal da timeline (px); 0 = início
tl_hbar_drag: bool  // arrastando a barra de rolagem horizontal
tl_vscroll: f32     // deslocamento VERTICAL das trilhas (px); 0 = topo. >0 quando não cabem
tl_vbar_drag: bool  // arrastando a barra de rolagem vertical
zoom_bar_drag: bool // arrastando o knob do slider de zoom
ui_slider_active: int = -1 // id do slider sendo arrastado no inspector (-1 = nenhum)
// geometria das alças do segmento SELECIONADO, preenchida no draw da timeline e lida
// no hit-test do clique (imediato-mode): pontos de fade e faixa da linha de volume
g_sel_fi:   rl.Vector2 = {-1, -1} // centro da alça de fade-in (na timeline)
g_sel_fo:   rl.Vector2 = {-1, -1} // centro da alça de fade-out
g_sel_volbar: rl.Rectangle        // faixa fina de agarre da linha de volume
g_vby0, g_vby1: f32               // topo/base da região de mapeamento vertical do volume

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
	leof:   f32,        // fim real detectado (0 = desconhecido); congela em vez de respawnar em loop
}
seg_dup:     [MAX_SEGS]SegDup
dup_buf:     []u8       // 1º frame lido pelo WORKER no spawn (só o worker escreve)
dup_rd_buf:  []u8       // frames do catch-up lidos pela MAIN (buffers separados: sem corrida)
dup_req_c:   int = -1   // atômico: clipe a spawnar (-1 = ocioso); main publica por último
dup_req_t:   f32        // tempo alvo na fonte
dup_req_si:  int = -1   // segmento que pediu (só a main lê/escreve)
dup_req_start: f32      // identidade do seg no pedido: start/in_off (validados na adoção —
dup_req_inoff: f32      // remover um seg compacta o array e o MESMO índice vira OUTRO seg)
dup_ready:   bool       // atômico: spawn terminou (main adota processo+frame e libera)
dup_sp_ps:   os.Process // staging do spawn: processo entregue pelo worker
dup_sp_r:    ^os.File   // staging: ponta de leitura
dup_sp_on:   bool       // staging: spawn entregou decoder vivo com 1º frame em dup_buf

toast_msg:   cstring
toast_t:     f32
want_import: bool // pedido de abrir o diálogo de importar (tratado no update)

// relógio de áudio MONOTÔNICO: GetMusicTimePlayed oscila p/ trás em até ~1
// sub-buffer; o playback nunca deixa `local` recuar abaixo de aud_prev (o recuo
// espúrio disparava respawn de vídeo à toa). Zerado (=-1) a cada seek/aquisição.
aud_prev: f32 = -1

// frame de vídeo EXIBIDO no playback, avançado por PASSO travado no vsync (não amostrado do
// relógio). A 60fps num monitor de 60Hz o período do conteúdo == período do render: amostrar
// int(src_t*fps) por frame gera "beat" (repete+pula) a cada leve jitter de fase. Avançar +1 por
// frame de render dentro de uma zona-morta mata o beat (1:1 perfeito); fora dela persegue o
// relógio de áudio (corrige drift / faz pulldown quando render != conteúdo, ex. 75Hz). -1 =
// re-ancora no próximo frame (resetado junto de aud_prev em seek/aquisição).
play_frame: int = -1

// relógio de reprodução SUAVE (anti-judder). GetMusicTimePlayed avança em degraus de ~10-20ms
// (granularidade do callback de áudio); amostrá-lo 1×/frame de render (16.7ms) faz o índice de
// frame de vídeo `int(t*fps)` às vezes PULAR 2 e no frame seguinte REPETIR (step 0) — o par
// pula+repete é o judder, visível a 60fps (onde cada frame de render tem de avançar exatamente
// 1 frame de vídeo; a 30fps a folga de 2 frames de render absorve o jitter). Correção: avança
// pelo dt de render (uniforme) e só reata no relógio de áudio quando o drift passa de SMOOTH_RESYNC
// (seek, hitch, buffer esvaziado) — mantém A/V em sync com folga bem menor que os limiares de
// underrun/fim (0.25s). `aud_prev` passa a guardar o valor SUAVE; o chamador zera aud_prev=-1 em
// seek/aquisição p/ o 1º frame assentar no áudio. Monotônico: nunca recua (segura no underrun).
// snap SECO só p/ drift enorme (seek perdido, troca de janela de áudio, underrun longo). Abaixo
// disso a correção é PROPORCIONAL (PLL) — nunca congela nem pula, então o pulldown 4:5 (60fps em
// 75Hz) fica uniforme. O snap seco (threshold pequeno) congelava o índice por 2-3 frames = os
// "engasgos duplos" que sobravam de judder.
SMOOTH_HARD  :: f32(0.25)  // drift catastrófico: reata seco (bate com os limiares de underrun/fim)
SMOOTH_GAIN  :: f32(0.05)  // correção suave por frame: ~0.27s p/ absorver drift (A/V inaudível)
smooth_clock :: proc(raw, dt: f32) -> f32 {
	if aud_prev < 0 do return raw                  // 1º frame após seek/aquisição: assenta no áudio
	sm := aud_prev + dt                            // avança liso pelo tempo de render (vsync)
	drift := raw - sm
	if abs(drift) > SMOOTH_HARD do return raw       // catastrófico: reata seco no áudio
	sm += drift * SMOOTH_GAIN                        // PLL: puxa devagar p/ o áudio, sem congelar/pular
	if sm < aud_prev do sm = aud_prev               // monotônico (nunca recua)
	return sm
}

// taxa de atualização do monitor (Hz). O playback renderiza TRAVADO nela (não em 60 fixo):
// num monitor de 74Hz, render a 60fps espreme 60 frames em 74 refreshes → alguns aparecem por
// 1 refresh, outros por 2, IRREGULAR = judder (visível a 60fps; 30fps de câmera mascara). Render
// = refresh trava a apresentação no vsync e o vídeo (índice por relógio suave) fica o mais liso
// possível. Lido 1× no startup (fallback 60 se o driver devolver algo esquisito).
g_refresh: i32 = 60

// ---------- controle da janela (barra de título própria) ----------
should_close: bool        // botão fechar da barra custom
win_dragging: bool        // arrastando a janela pela barra
win_grab:     rl.Vector2  // ponto (na janela) onde o arrasto começou
win_click_t:  f64 = -1    // instante do último clique na barra (detecta duplo-clique)

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
	music_base: f32,  // offset (na fonte) do stream ATIVO em c.music (0 = head/completo)
	// --- forma de onda (envelope de picos, calculada do WAV em thread de fundo) ---
	wave:       []f32, // pico [0,1] por bucket, WAVE_PPS buckets/seg (heap, dono)
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
	rsp_t0:   f64,  // quando foi pedido (p/ medir a latência no overlay)
	rsp_busy: bool, // atômico: worker é o DONO do live stream (main não toca)
	rsp_done: bool, // atômico: novo decoder pronto, 1º frame em fbuf
	// áudio (WAV em disco; funciona p/ qualquer duração)
	music:     rl.Music,
	has_audio: bool,
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
clip_seq:  int      // contador p/ ids únicos

// ---------- helpers ----------
txt :: proc(s: cstring, x, y, size: f32, col: rl.Color) {
	if sdf_ok do rl.BeginShaderMode(sdf_shader)
	rl.DrawTextEx(ui_font, s, {x, y}, size * g_us, 0.5, col) // × escala da UI
	if sdf_ok do rl.EndShaderMode()
}
txt_w :: proc(s: cstring, size: f32) -> f32 { return rl.MeasureTextEx(ui_font, s, size * g_us, 0.5).x }
txt_c :: proc(s: cstring, cx, y, size: f32, col: rl.Color) {
	txt(s, cx - txt_w(s, size) / 2, y, size, col)
}
// com o menu de contexto aberto (ou no frame em que ele engoliu o clique), a UI de
// trás fica inerte — hover e cliques não atravessam o menu (padrão do modal)
hovered :: proc(r: rl.Rectangle) -> bool {
	if ctx_open || ctx_ate do return false
	return rl.CheckCollisionPointRec(rl.GetMousePosition(), r)
}
// clique válido; quando há modal aberto, só conta se for DENTRO do modal (g_modal_draw)
clicked :: proc(r: rl.Rectangle) -> bool { return hovered(r) && rl.IsMouseButtonPressed(.LEFT) && (modal == .None || g_modal_draw) }
// faixa do zoom do slider/roda (controle manual). ZOOM_MIN=0.005 -> ~0,1 px/s
// (1h ≈ 360 px). O "Fit" NÃO usa este piso: ele desce até FIT_MIN pra caber
// qualquer duração, por mais longa que seja (o que o slider não precisa alcançar).
ZOOM_MIN :: f32(0.005)
ZOOM_MAX :: f32(4.0)
FIT_MIN  :: f32(0.0002) // piso do ajuste-à-janela: ~0,004 px/s (cabe até ~10h numa tela grande)
pps :: proc() -> f32 { return 20 * st.zoom }
// conversões tempo<->x na timeline, já considerando o scroll horizontal
tl_x :: proc(t: f32) -> f32 { return f32(LANE_X) + t * pps() - tl_scroll }
tl_t :: proc(x: f32) -> f32 { return (x - f32(LANE_X) + tl_scroll) / pps() }
// muda o zoom mantendo fixo um ponto de referência na tela — o playhead se ele
// está visível, senão o centro da janela — pra não desorientar (os botões +/-
// antes só mexiam no zoom e o conteúdo "escorregava" sob o playhead).
tl_set_zoom :: proc(nz, view_w: f32) {
	vx0 := f32(LANE_X) // a timeline começa em x=0, então a lane começa em LANE_X
	ph_x := tl_x(st.playhead)
	anchor_x := (ph_x >= vx0 && ph_x <= vx0 + view_w) ? ph_x : vx0 + view_w * 0.5
	anchor_t := tl_t(anchor_x)
	st.zoom = clamp(nz, ZOOM_MIN, ZOOM_MAX)
	tl_scroll = vx0 + anchor_t * pps() - anchor_x // recoloca anchor_t em anchor_x
}

// "ajustar à janela": escolhe o zoom que faz TODO o conteúdo caber na área
// visível da timeline e volta ao início. Atalho F / botão na barra de zoom.
tl_fit :: proc(view_w: f32) {
	dur := timeline_dur()
	if dur <= 0 || view_w <= 0 do return
	lane_w := view_w - 40 // desconta a folga que o content_w adiciona no fim
	// clampa no piso do FIT (não no ZOOM_MIN do slider): assim SEMPRE cabe, mesmo
	// que o vídeo precise de um zoom menor que o alcance do controle manual.
	st.zoom = clamp(lane_w / (dur * 20), FIT_MIN, ZOOM_MAX) // pps=20*zoom => zoom = alvo_pps/20
	tl_scroll = 0
}
cs :: proc(s: string) -> cstring { return fmt.ctprintf("%s", s) } // string -> cstring (temp)

// trunca `s` com "..." para caber em `max_w` pixels (fonte não tem o glifo "…")
elide :: proc(s: string, size, max_w: f32) -> cstring {
	if txt_w(cs(s), size) <= max_w do return cs(s)
	for n := len(s) - 1; n > 0; n -= 1 {
		cand := fmt.ctprintf("%s...", s[:n])
		if txt_w(cand, size) <= max_w do return cand
	}
	return "..."
}

base_name :: proc(path: string) -> string {
	start := 0
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '/' || path[i] == '\\' { start = i + 1; break }
	}
	return strings.clone(path[start:])
}

// ---------- processos filhos: job object + prioridade ----------
// Job com KILL_ON_JOB_CLOSE: todo ffmpeg é atribuído a ele, e o kernel mata o
// job inteiro quando o último handle fecha — ou seja, quando o editor morre,
// MESMO em crash/kill. Sem isso, decoders ao vivo sobreviviam como órfãos
// presos no pipe. core:sys/windows não expõe Job Objects nem SetPriorityClass;
// bindings manuais abaixo (layouts x64 conferidos com o SDK do Windows).
JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE :: 0x00002000
JobObjectExtendedLimitInformation  :: i32(9)

IO_COUNTERS :: struct {
	ReadOperationCount, WriteOperationCount, OtherOperationCount: u64,
	ReadTransferCount, WriteTransferCount, OtherTransferCount:    u64,
}
JOBOBJECT_BASIC_LIMIT_INFORMATION :: struct {
	PerProcessUserTimeLimit: i64,
	PerJobUserTimeLimit:     i64,
	LimitFlags:              u32,
	MinimumWorkingSetSize:   uint,
	MaximumWorkingSetSize:   uint,
	ActiveProcessLimit:      u32,
	Affinity:                uint,
	PriorityClass:           u32,
	SchedulingClass:         u32,
}
JOBOBJECT_EXTENDED_LIMIT_INFORMATION :: struct {
	BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION,
	IoInfo:                IO_COUNTERS,
	ProcessMemoryLimit:    uint,
	JobMemoryLimit:        uint,
	PeakProcessMemoryUsed: uint,
	PeakJobMemoryUsed:     uint,
}

foreign import kernel32 "system:Kernel32.lib"
@(default_calling_convention="system")
foreign kernel32 {
	CreateJobObjectW         :: proc(attrs: rawptr, name: win.LPCWSTR) -> win.HANDLE ---
	SetInformationJobObject  :: proc(job: win.HANDLE, class: i32, info: rawptr, len: u32) -> win.BOOL ---
	AssignProcessToJobObject :: proc(job: win.HANDLE, ps: win.HANDLE) -> win.BOOL ---
	TerminateJobObject       :: proc(job: win.HANDLE, exit_code: u32) -> win.BOOL ---
	SetPriorityClass         :: proc(ps: win.HANDLE, class: u32) -> win.BOOL ---
}

// FECHANDO o app: sinaliza a TODOS os workers (globais e por-clipe) p/ não spawnar/retomar
// mais ffmpeg. Sem isto, workers como scrub/respawn re-spawnavam um decoder DEPOIS que o job
// foi morto (escapando dele) e o read bloqueante travava o join no shutdown — mesmo com os
// vídeos JÁ na timeline (scrub/playback ao vivo ativos).
app_closing: bool

// pausar/retomar a exportação = suspender/retomar TODAS as threads do processo ffmpeg.
// O Windows não tem SIGSTOP; NtSuspendProcess/NtResumeProcess (ntdll, não documentadas
// mas estáveis há décadas) fazem exatamente isso.
foreign import ntdll "system:ntdll.lib"
@(default_calling_convention="system")
foreign ntdll {
	NtSuspendProcess :: proc(ps: win.HANDLE) -> i32 ---
	NtResumeProcess  :: proc(ps: win.HANDLE) -> i32 ---
}

g_job: win.HANDLE

job_init :: proc() {
	g_job = CreateJobObjectW(nil, nil)
	if g_job == nil do return
	info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION
	info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
	if !SetInformationJobObject(g_job, JobObjectExtendedLimitInformation, &info, u32(size_of(info))) {
		win.CloseHandle(g_job)
		g_job = nil
	}
}

// ---------- log de diagnóstico (arquivo, ligado por F4) ----------
// Grava eventos do decoder com timestamp (ms desde o start da captura) num arquivo ao lado
// do .exe — p/ depurar problemas que só aparecem em USO REAL (travadinha no playback, scrub
// preso na miniatura) e que as medições isoladas do ffmpeg não revelam. F4 liga (zera o
// arquivo) / desliga. Thread-safe (workers de decode E a main gravam) via mutex.
dbg_on:   bool // atômico: capturando
dbg_f:    ^os.File
dbg_mtx:  sync.Mutex
dbg_t0:   time.Tick
dbg_hb_t: time.Tick // último heartbeat de estado (STATE) durante o playback
dbg_vframes: int // frames de vídeo streaming que subiram p/ a textura desde o último heartbeat (fps REAL do vídeo)
dbg_thumb_frames: int // frames em que o draw mostrou a MINIATURA durante o playback (flash borrado) desde o HB
dbg_path: string // caminho do log (heap, dono) — mostrado no toast

dbg_toggle :: proc() {
	if intrinsics.atomic_load(&dbg_on) {
		intrinsics.atomic_store(&dbg_on, false)
		sync.mutex_lock(&dbg_mtx)
		if dbg_f != nil { os.flush(dbg_f); os.close(dbg_f); dbg_f = nil }
		sync.mutex_unlock(&dbg_mtx)
		set_toast("Diagnóstico PARADO (log salvo)")
		return
	}
	dir := EXE_DIR != "" ? EXE_DIR : "."
	if dbg_path == "" do dbg_path = fmt.aprintf("%s\\decoder_log.txt", dir)
	f, e := os.open(dbg_path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC)
	if e != nil { set_toast("Falha ao abrir o log de diagnóstico"); return }
	sync.mutex_lock(&dbg_mtx); dbg_f = f; sync.mutex_unlock(&dbg_mtx)
	dbg_t0 = time.tick_now()
	intrinsics.atomic_store(&dbg_on, true)
	dbg("INICIO", "captura ligada — g_refresh=%dHz monitor=%dHz vsync=hint", g_refresh, rl.GetMonitorRefreshRate(rl.GetCurrentMonitor()))
	set_toast("Diagnóstico GRAVANDO — reproduza o problema e aperte F4")
}

// grava uma linha no log se a captura estiver ligada. `kind` é uma etiqueta curta (RESPAWN,
// SCRUB, HWREJECT, EOF, HITCH...). Formata em buffers de STACK (bprintf) — os workers de
// decode são threads de vida longa sem free do temp allocator, então tprintf vazaria ali.
dbg :: proc(kind: string, format: string, args: ..any) {
	if !intrinsics.atomic_load(&dbg_on) do return
	ms := time.duration_milliseconds(time.tick_diff(dbg_t0, time.tick_now()))
	hb: [64]u8;  hdr  := fmt.bprintf(hb[:], "[%10.1f] %-8s ", ms, kind)
	bb: [256]u8; body := fmt.bprintf(bb[:], format, ..args)
	sync.mutex_lock(&dbg_mtx); defer sync.mutex_unlock(&dbg_mtx)
	if dbg_f == nil do return
	os.write_string(dbg_f, hdr)
	os.write_string(dbg_f, body)
	os.write_string(dbg_f, "\n")
}

// cria um Job Object com KILL_ON_JOB_CLOSE (mata os processos quando o último handle
// fecha — no fim normal via clip_close, ou no crash pela morte do processo dono).
make_kill_job :: proc() -> win.HANDLE {
	j := CreateJobObjectW(nil, nil)
	if j == nil do return nil
	info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION
	info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
	if !SetInformationJobObject(j, JobObjectExtendedLimitInformation, &info, u32(size_of(info))) {
		win.CloseHandle(j); return nil
	}
	return j
}

// registra o processo no Job do PRÓPRIO clipe (fechar o job mata só os ffmpeg dele —
// essencial p/ remover um vídeo grande sem travar no join de um read bloqueado) e, se
// bg=true, baixa a prioridade p/ BELOW_NORMAL (trabalho de fundo não disputa CPU).
tame_process :: proc(c: ^Clip, p: os.Process, bg: bool) {
	if c.job != nil do AssignProcessToJobObject(c.job, win.HANDLE(p.handle))
	if bg do SetPriorityClass(win.HANDLE(p.handle), win.BELOW_NORMAL_PRIORITY_CLASS)
}

// FECHAMENTO INSTANTÂNEO. O teardown "educado" (juntar todas as threads) era lento por 3
// motivos: o worker de fontes SDF (`tf_thr`) é CPU puro e não checa `stop` -> o join podia
// esperar ~2.5s; cada ffmpeg de fundo só morria no polling de 50ms do `audio_extract_wait`,
// somando centenas de ms por vários clipes; e o `CloseAudioDevice`/`CloseWindow` do raylib
// desmontava WASAPI+GL (~100-200ms). Nada disso é necessário: o SO recupera RAM/GL/threads/
// áudio ao sair. Aqui só matamos todo ffmpeg de uma vez (libera os handles dos temporários),
// soltamos os handles de áudio do raylib, apagamos os temporários e saímos.
// NÃO liberamos (delete) nenhum buffer: um worker ainda pode estar escrevendo nele — como
// não liberamos nada, não há use-after-free; o os.exit encerra as threads em bloco.
close_now :: proc() {
	intrinsics.atomic_store(&app_closing, true) // barra qualquer novo spawn de ffmpeg
	intrinsics.atomic_store(&scrub_run, false)
	// 1) mata TODO ffmpeg em voo -> solta os handles dos temporários que ele escreve
	for i in 0 ..< nclips {
		intrinsics.atomic_store(&clips[i].stop, true)
		if clips[i].job != nil do TerminateJobObject(clips[i].job, 1)
	}
	if export_job != nil do TerminateJobObject(export_job, 1)
	// 2) solta os handles de áudio do raylib -> libera o temporário que cada stream toca
	for i in 0 ..< nclips do if clips[i].has_audio do rl.UnloadMusicStream(clips[i].music)
	for i in 0 ..< MAX_SEGS do if spv[i].ok do rl.UnloadMusicStream(spv[i].music)
	// 3) apaga os temporários deste processo (os mesmos que clip_close/spv_release removiam)
	for i in 0 ..< nclips {
		c := &clips[i]
		if c.aud_path == "" do continue // slot vazio/tombstone (já limpo) ou imagem sem áudio
		os.remove(c.aud_path)
		os.remove(c.aud_head)
		os.remove(c.aud_ck[0])
		os.remove(c.aud_ck[1])
		os.remove(part_path(c, 0)) // OGG completo
	}
	for i in 0 ..< MAX_SEGS do if spv[i].path != "" do os.remove(spv[i].path)
	// 4) sai — sem joins, sem desmontar o raylib; Jobs KILL_ON_JOB_CLOSE varrem o que escapou
	os.exit(0)
}

LANE_X :: 128 // largura do cabeçalho das trilhas

// dimensões de saída a partir da proporção do projeto (lado menor = 1080)
export_dims :: proc() -> (w, h: int) { return proj_w, proj_h } // resolução do projeto (Config. do Projeto)

// thread de fundo: lê o -progress do ffmpeg e atualiza export_pct; espera o fim
export_worker :: proc() {
	buf: [4096]u8
	line: [512]u8
	ll := 0
	for {
		n, e := os.read(export_r, buf[:])
		if n > 0 {
			for k in 0 ..< n {
				ch := buf[k]
				if ch == '\n' {
					s := string(line[0:ll])
					if strings.has_prefix(s, "out_time_us=") {
						if v, ok := strconv.parse_i64(s[len("out_time_us="):]); ok && export_total > 0 {
							export_pct = clamp(f32(f64(v)/1e6) / export_total, 0, 1)
						}
					}
					ll = 0
				} else if ll < len(line) { line[ll] = ch; ll += 1 }
			}
		}
		if n <= 0 || e != nil do break
	}
	os.close(export_r)
	state, _ := os.process_wait(export_ps)
	export_ok = state.exited && state.exit_code == 0
	export_pct = 1
	if export_job != nil { win.CloseHandle(export_job); export_job = nil }
	intrinsics.atomic_store(&export_run, false)
}

// thread de fundo: lê os frames rgb24 da prévia (stdout) e publica em buffer duplo;
// a main sobe o último na textura. Termina no EOF (o ffmpeg fecha ao acabar).
export_preview_worker :: proc() {
	frame := make([]u8, PREV_BYTES); defer delete(frame)
	got := 0
	buf: [65536]u8
	for {
		n, e := os.read(export_prev_r, buf[:])
		if n > 0 {
			off := 0
			for off < n {
				take := min(PREV_BYTES - got, n - off)
				copy(frame[got:], buf[off:off+take])
				got += take; off += take
				if got == PREV_BYTES { // frame completo: publica no slot livre
					s := export_prev_wslot
					copy(s == 0 ? export_prev_a : export_prev_b, frame)
					intrinsics.atomic_store(&export_prev_pub, s)
					intrinsics.atomic_add(&export_prev_seq, 1)
					export_prev_wslot = 1 - s
					got = 0
				}
			}
		}
		if n <= 0 || e != nil do break
	}
	os.close(export_prev_r)
}

// acrescenta os fades de alpha da transição (dissolver) ao fim da cadeia do clip no export
export_trans_fades :: proc(fb: ^strings.Builder, start2, tend, din, dout: f32) {
	if din > 0.01  do fmt.sbprintf(fb, ",fade=t=in:st=%.3f:d=%.3f:alpha=1", start2, din)
	if dout > 0.01 do fmt.sbprintf(fb, ",fade=t=out:st=%.3f:d=%.3f:alpha=1", tend-dout, dout)
}

// EFEITOS DE COR no export: espelha o BULGE_FS (brilho/contraste/saturação -> eq; visual
// P&B/sépia/inverter -> hue/colorchannelmixer/negate; vinheta -> vignette). Aproxima o
// preview (não é pixel-exato, mas visualmente consistente). Nada é adicionado se neutro.
export_color_filters :: proc(fb: ^strings.Builder, sg: Seg) {
	if abs(sg.fx_bright) > 0.001 || abs(sg.fx_contrast) > 0.001 || abs(sg.fx_satur) > 0.001 {
		fmt.sbprintf(fb, ",eq=brightness=%.4f:contrast=%.4f:saturation=%.4f", sg.fx_bright, 1+sg.fx_contrast, 1+sg.fx_satur)
	}
	if abs(sg.fx_temp) > 0.001 { // temperatura: desloca vermelho/azul (aproxima o shader)
		fmt.sbprintf(fb, ",colorbalance=rm=%.3f:bm=%.3f", sg.fx_temp*0.3, -sg.fx_temp*0.3)
	}
	switch int(sg.fx_look + 0.5) {
	case 1: fmt.sbprintf(fb, ",hue=s=0") // P&B
	case 2: fmt.sbprintf(fb, ",colorchannelmixer=0.393:0.769:0.189:0:0.349:0.686:0.168:0:0.272:0.534:0.131") // sépia
	case 3: fmt.sbprintf(fb, ",negate") // inverter
	}
	if sg.fx_vignette > 0.001 {
		// vinheta do ffmpeg: ângulo maior = escurece mais. Mapeia 0..1 -> ~PI/6..PI/2.5.
		fmt.sbprintf(fb, ",vignette=angle=%.4f", 0.52 + sg.fx_vignette*0.74)
	}
}

// dimensões (pares) do segmento após escala no export — MESMA fórmula usada ao montar o
// filtro; extraída p/ gerar os mapas do bulge com o tamanho exato do stream no remap.
seg_export_dims :: proc(i, W, H: int) -> (int, int) {
	sg := segs[i]
	sc := sg.scale <= 0 ? f32(1) : sg.scale
	_, _, crw, crh := seg_crop(i)
	crop_aspect := (crw * clip_ar(&clips[sg.src])) / crh // aspecto em pixels da região (frações × aspecto da fonte)
	fitW := min(f32(W), f32(H)*crop_aspect); fitH := fitW/crop_aspect
	segW := int(fitW*sc + 0.5); segH := int(fitH*sc + 0.5)
	segW -= segW%2; segH -= segH%2
	if segW < 2 do segW = 2
	if segH < 2 do segH = 2
	return segW, segH
}

// gera os mapas de deslocamento (xmap/ymap) do efeito Distorção p/ o filtro `remap` do
// ffmpeg no export. Reproduz a MESMA matemática do BULGE_FS (WYSIWYG: export == preview).
// PGM P5 16-bit big-endian, w×h; o VALOR de cada pixel = coordenada da FONTE a amostrar.
// remap depois é nativo/rápido (o geq equivalente seria ~20x mais lento que tempo real).
write_bulge_maps :: proc(str, cx, cy, rad: f32, w, h: int, xpath, ypath: string) -> bool {
	if w < 2 || h < 2 do return false
	asp := f32(w) / f32(h)
	hdr := fmt.tprintf("P5\n%d %d\n65535\n", w, h)
	xb := make([dynamic]u8, 0, len(hdr) + w*h*2, context.temp_allocator)
	yb := make([dynamic]u8, 0, len(hdr) + w*h*2, context.temp_allocator)
	for b in transmute([]u8)hdr { append(&xb, b); append(&yb, b) }
	for yy in 0 ..< h {
		ly := f32(yy) / f32(h)
		dy := ly - cy
		for xx in 0 ..< w {
			lx := f32(xx) / f32(w)
			dx := lx - cx
			dist := math.sqrt((dx*asp)*(dx*asp) + dy*dy)
			f := f32(0)
			if dist < rad { t := 1 - dist/rad; f = str*t*t }
			ix := clamp(int((lx - dx*f)*f32(w) + 0.5), 0, w-1)
			iy := clamp(int((ly - dy*f)*f32(h) + 0.5), 0, h-1)
			append(&xb, u8(ix >> 8), u8(ix & 0xff)) // 16-bit big-endian (PGM)
			append(&yb, u8(iy >> 8), u8(iy & 0xff))
		}
	}
	return os.write_entire_file(xpath, xb[:]) == nil && os.write_entire_file(ypath, yb[:]) == nil
}

// monta o -filter_complex e dispara o ffmpeg. Respeita trilhas/transform/proporção/
// cortes/volume/fades/mixagem. Renderiza a partir dos ARQUIVOS-fonte (resolução cheia).
start_export :: proc(out: string, gpu: bool) {
	if intrinsics.atomic_load(&export_run) { set_toast("Exportação já em andamento"); return }
	total := timeline_dur()
	if total <= 0 { set_toast("Nada na timeline para exportar"); return }
	W, H := export_dims()
	want_video := export_fmt != .MP3 // MP3 = só áudio: pula todo o ramo de vídeo do filtro

	if export_out != "" do delete(export_out)
	export_out = strings.clone(out)

	args := make([dynamic]string, context.temp_allocator)
	append(&args, "ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-progress", "pipe:2", "-nostats") // progresso no stderr; stdout = frames da prévia

	// clipes de TEXTO: renderiza cada um num PNG RGBA do tamanho do canvas (já
	// posicionado/estilizado) p/ virar overlay. Feito ANTES de montar os inputs.
	for f in export_tmp_files do delete(f)
	clear(&export_tmp_files)
	text_png: [MAX_SEGS]string
	for i in 0 ..< nsegs {
		if !want_video do break // MP3: sem overlay de texto
		if !seg_ready(i) do continue
		c := &clips[segs[i].src]
		if !c.is_text do continue
		p := fmt.tprintf("%s_%d_%d_txt%d.png", AUDIO_BASE, u32(win.GetCurrentProcessId()), c.aid, i)
		if render_text_png(c, segs[i], p) {
			text_png[i] = p
			append(&export_tmp_files, strings.clone(p))
		}
	}

	// transições CENTRADAS: cada B com d=trans estica a cabeça `d/2` (thead) e o clipe de
	// saída A estica a cauda `d/2` (ttail); os dois fazem crossfade sobre `d` s no corte.
	thead: [MAX_SEGS]f32; ttail: [MAX_SEGS]f32; tfin: [MAX_SEGS]f32; tfout: [MAX_SEGS]f32
	for i in 0 ..< nsegs {
		d := seg_trans(i)
		if d > 0 {
			thead[i] = max(thead[i], d/2); tfin[i] = max(tfin[i], d)
			if a := trans_prev(i); a >= 0 { ttail[a] = max(ttail[a], d/2); tfout[a] = max(tfout[a], d) }
		}
	}

	seg_inp: [MAX_SEGS]int
	bulge_xin: [MAX_SEGS]int // input do xmap do bulge (-1 = sem efeito); ymap = bulge_yin
	bulge_yin: [MAX_SEGS]int
	bulge_anim: [MAX_SEGS]bool // wobble: mapas são sequência em loop (não 1 frame estático)
	fx_xin: [MAX_FX]int; fx_yin: [MAX_FX]int // mapas de remap dos clipes de efeito de DISTORÇÃO
	for i in 0 ..< MAX_SEGS { seg_inp[i] = -1; bulge_xin[i] = -1; bulge_yin[i] = -1 }
	for k in 0 ..< MAX_FX { fx_xin[k] = -1; fx_yin[k] = -1 }
	inp := 0
	for i in 0 ..< nsegs {
		if !seg_ready(i) do continue
		c := &clips[segs[i].src]
		if !want_video && !c.has_audio do continue // MP3: só fontes com áudio viram input
		if c.is_text { // overlay de texto = PNG estático (como imagem); pula se o render falhou
			if text_png[i] == "" do continue
			append(&args, "-loop", "1", "-framerate", "30", "-t", fmt.tprintf("%.3f", segs[i].dur + thead[i] + ttail[i]))
			append(&args, "-i", text_png[i])
			seg_inp[i] = inp; inp += 1
			continue
		}
		if c.is_img { // imagem: repete o frame por dur (+ handles da transição) segundos
			append(&args, "-loop", "1", "-framerate", "30", "-t", fmt.tprintf("%.3f", segs[i].dur + thead[i] + ttail[i]))
		}
		append(&args, "-i", c.path)
		seg_inp[i] = inp; inp += 1
		// EFEITO Distorção: mapas xmap/ymap viram inputs p/ o remap (tamanho segW×segH).
		// Estático = 1 par (remap repete o frame). Wobble = 1 PERÍODO de mapas em sequência,
		// consumidos em loop (stream_loop) sincronizados ao vídeo em fps=30.
		if want_video && !c.is_audio && !segs[i].aonly && bulge_active(segs[i]) {
			sg := segs[i]
			segW, segH := seg_export_dims(i, W, H)
			cx := clamp(0.5 + sg.bulge_x, 0, 1); cy := clamp(0.5 + sg.bulge_y, 0, 1)
			rad := sg.bulge_r <= 0 ? BULGE_R_DEF : sg.bulge_r
			pid := u32(win.GetCurrentProcessId())
			if abs(sg.wobble) < 0.001 { // ESTÁTICO: 1 par de mapas
				xp := fmt.tprintf("%s_%d_%d_bx%d.pgm", AUDIO_BASE, pid, c.aid, i)
				yp := fmt.tprintf("%s_%d_%d_by%d.pgm", AUDIO_BASE, pid, c.aid, i)
				if write_bulge_maps(sg.bulge, cx, cy, rad, segW, segH, xp, yp) {
					append(&args, "-i", xp); bulge_xin[i] = inp; inp += 1
					append(&args, "-i", yp); bulge_yin[i] = inp; inp += 1
					append(&export_tmp_files, strings.clone(xp)); append(&export_tmp_files, strings.clone(yp))
				}
			} else { // WOBBLE: N pares (1 período) numerados _%03d.pgm
				hz := sg.wobble_speed <= 0 ? WOBBLE_HZ_DEF : sg.wobble_speed
				N := clamp(int(30/hz + 0.5), 2, 90) // frames por período (@30fps), limitado
				okall := true
				for k in 0 ..< N {
					s := bulge_at(sg, f32(k)/30)
					xk := fmt.tprintf("%s_%d_%d_bx%d_%03d.pgm", AUDIO_BASE, pid, c.aid, i, k)
					yk := fmt.tprintf("%s_%d_%d_by%d_%03d.pgm", AUDIO_BASE, pid, c.aid, i, k)
					if !write_bulge_maps(s, cx, cy, rad, segW, segH, xk, yk) { okall = false; break }
					append(&export_tmp_files, strings.clone(xk)); append(&export_tmp_files, strings.clone(yk))
				}
				if okall {
					segsec := sg.dur + thead[i] + ttail[i] + 0.3
					loops := int(segsec*30)/N + 2 // repetições p/ cobrir todo o segmento (+ folga)
					xpat := fmt.tprintf("%s_%d_%d_bx%d_%%03d.pgm", AUDIO_BASE, pid, c.aid, i)
					ypat := fmt.tprintf("%s_%d_%d_by%d_%%03d.pgm", AUDIO_BASE, pid, c.aid, i)
					ls := fmt.tprintf("%d", loops)
					append(&args, "-stream_loop", ls, "-framerate", "30", "-i", xpat); bulge_xin[i] = inp; inp += 1
					append(&args, "-stream_loop", ls, "-framerate", "30", "-i", ypat); bulge_yin[i] = inp; inp += 1
					bulge_anim[i] = true
				}
			}
		}
	}
	// mapas de remap dos clipes de efeito de DISTORÇÃO (tamanho do QUADRO W×H; write_bulge_maps
	// reproduz o BULGE_FS -> export == preview). Estático (wobble no export = intensidade base).
	for k in 0 ..< nfx {
		if !want_video do break // MP3: sem efeitos de vídeo
		e := fxsegs[k]
		if e.kind != FX_DISTORT do continue
		cx := clamp(0.5+e.cx, 0, 1); cy := clamp(0.5+e.cy, 0, 1)
		rad := e.radius <= 0 ? BULGE_R_DEF : e.radius
		pid := u32(win.GetCurrentProcessId())
		xp := fmt.tprintf("%s_%d_fxbx%d.pgm", AUDIO_BASE, pid, k)
		yp := fmt.tprintf("%s_%d_fxby%d.pgm", AUDIO_BASE, pid, k)
		if write_bulge_maps(e.amount, cx, cy, rad, W, H, xp, yp) {
			append(&args, "-i", xp); fx_xin[k] = inp; inp += 1
			append(&args, "-i", yp); fx_yin[k] = inp; inp += 1
			append(&export_tmp_files, strings.clone(xp)); append(&export_tmp_files, strings.clone(yp))
		}
	}
	if inp == 0 { set_toast("Nada para exportar"); return }

	fb := strings.builder_make(context.temp_allocator)
	if want_video {
	fmt.sbprintf(&fb, "color=c=black:s=%dx%d:r=30:d=%.3f[b0];", W, H, total)
	vlabel := "b0"
	vc := 0
	for t in 0 ..< g_nv {
		if track_hidden[t] do continue // trilha oculta (olho): fora do vídeo exportado (áudio segue mixado)
		for i in 0 ..< nsegs {
			if seg_inp[i] < 0 || segs[i].track != t || clips[segs[i].src].is_audio || segs[i].aonly do continue
			sg := segs[i]
			cc := &clips[sg.src]
			hd := thead[i]; tl := ttail[i]                        // esticões da transição (cabeça/cauda)
			fin := max(tfin[i], sg.vfin); fout := max(tfout[i], sg.vfout) // fades (dissolver OU fade preto)
			start2 := sg.start - hd              // começa `hd` s antes (metade do dissolver de entrada)
			tend := sg.start + sg.dur + tl       // termina `tl` s depois (metade do dissolver de saída)
			if cc.is_text { // PNG full-canvas já posicionado: overlay em 0:0
				fmt.sbprintf(&fb, "[%d:v]trim=0:%.3f,setpts=PTS-STARTPTS+%.3f/TB,scale=%d:%d,format=rgba",
					seg_inp[i], sg.dur+hd+tl, start2, W, H)
				export_trans_fades(&fb, start2, tend, fin, fout)
				fmt.sbprintf(&fb, "[v%d];", vc)
				nb := fmt.tprintf("c%d", vc)
				fmt.sbprintf(&fb, "[%s][v%d]overlay=0:0:enable='between(t\\,%.3f\\,%.3f)':eof_action=pass[%s];",
					vlabel, vc, start2, tend, nb)
				vlabel = nb; vc += 1
				continue
			}
			// RECORTE: a região recortada (aspecto crw:crh no modelo 16:9) é ajustada ao canvas
			// como no preview. Sem recorte (1,1) reduz ao box 16:9 de antes.
			crx, cry, crw, crh := seg_crop(i)
			segW, segH := seg_export_dims(i, W, H)
			op := sg.opacity <= 0 ? 1 : sg.opacity
			sp := sg.speed <= 0 ? 1 : sg.speed
			// vídeo consome (in_off-hd)..(in_off+dur*sp+tl) — hd=pré-roll, tl=pós-roll do
			// dissolver; imagem usa o input em loop. setpts posiciona em start2.
			// FOLGA insuficiente: se a fonte não tem footage p/ o pré/pós-roll, apara só o
			// que existe e CONGELA o resto com tpad (clone do 1º/último frame) — o dissolver
			// funciona entre quaisquer clipes sem o usuário aparar nada. (hd/tl só são >0 em
			// transições, onde sp==1, então a matemática de folga usa dur diretamente.)
			freeze_hd := f32(0); freeze_tl := f32(0)
			t0, t1: f32
			if cc.is_img {
				t0 = 0; t1 = sg.dur + hd + tl
			} else {
				head_avail := sg.in_off                            // footage antes do in_off
				tail_avail := max(0, cc.dur - (sg.in_off + sg.dur*sp)) // footage após o out-point
				real_hd := min(hd, head_avail); freeze_hd = hd - real_hd
				real_tl := min(tl, tail_avail); freeze_tl = tl - real_tl
				t0 = sg.in_off - real_hd
				t1 = sg.in_off + sg.dur*sp + real_tl
			}
			fmt.sbprintf(&fb, "[%d:v]trim=%.3f:%.3f", seg_inp[i], t0, t1)
			if freeze_hd > 0.001 do fmt.sbprintf(&fb, ",tpad=start_mode=clone:start_duration=%.3f", freeze_hd)
			if freeze_tl > 0.001 do fmt.sbprintf(&fb, ",tpad=stop_mode=clone:stop_duration=%.3f", freeze_tl)
			// SEM pillarbox: a fonte de entrada JÁ está no seu aspecto real (nativo, auto-rotacionada
			// pelo ffmpeg). crop/scale/zoompan/bulge operam em frações de iw/ih do conteúdo (não de um
			// quadro 16:9), igual ao preview (WYSIWYG). seg_export_dims dá o box no aspecto da fonte, então
			// o scale final não estica. Vale p/ vídeo E imagem; texto (full-canvas) sai antes por outro caminho.
			// EFEITO Distorção: o remap precisa que o vídeo comece em PTS 0 (casa com os
			// mapas, estáticos ou em loop). Então reseta o PTS (só velocidade) ANTES do
			// remap e REPOSICIONA em start2 DEPOIS. Sem bulge, o setpts já posiciona direto.
			anim := sg.zoom_anim
			// zoom animado e bulge rodam em PTS 0 (o filtro casa com o tempo LOCAL) e a
			// reposição em start2 vem DEPOIS. Sem eles, o setpts já posiciona direto.
			if bulge_xin[i] >= 0 || anim {
				fmt.sbprintf(&fb, ",setpts=(PTS-STARTPTS)/%.5f", sp)
			} else {
				fmt.sbprintf(&fb, ",setpts=(PTS-STARTPTS)/%.5f+%.3f/TB", sp, start2)
			}
			if anim {
				// ZOOM ANIMADO (Pan & Zoom): zoompan anima a região crop_*->crop2_* (frações da
				// fonte) e a escala p/ o box segW×segH (região travada no aspecto de saída = preenche).
				// Espelha seg_crop_at do preview: smoothstep S no tempo local (on = frame de saída).
				// crop não serve aqui (fixa w/h na init); zoompan avalia z/x/y por frame.
				ax, ay, aw, _  := crop_norm(sg.crop_x,  sg.crop_y,  sg.crop_w,  sg.crop_h)
				bx, by, bw, _  := crop_norm(sg.crop2_x, sg.crop2_y, sg.crop2_w, sg.crop2_h)
				N := max((t1 - t0)/sp * 30, 1) // frames de saída (30fps) deste segmento
				Ls := fmt.tprintf("(on/%.3f)", f64(N))
				Ss := fmt.tprintf("(%s*%s*(3-2*%s))", Ls, Ls, Ls) // smoothstep (sem vírgulas: seguro no filtergraph)
				zexpr := fmt.tprintf("1/(%.6f+(%.6f)*%s)", aw, bw-aw, Ss)   // zoom = 1/largura da região
				xexpr := fmt.tprintf("(%.6f+(%.6f)*%s)*iw", ax, bx-ax, Ss)  // canto sup-esq X (px da fonte)
				yexpr := fmt.tprintf("(%.6f+(%.6f)*%s)*ih", ay, by-ay, Ss)  // canto sup-esq Y
				// fps=30 ANTES do zoompan: com d=1 ele emite 1 frame de saída por frame de
				// ENTRADA; sem normalizar, fonte !=30fps (ex.: 60fps de stream) muda a duração
				// do vídeo e DESSINCRONIZA do áudio. Normaliza p/ 30fps -> dur*30 frames exatos.
				fmt.sbprintf(&fb, ",fps=30,zoompan=z='%s':x='%s':y='%s':d=1:s=%dx%d:fps=30,setpts=PTS+%.3f/TB,format=rgba",
					zexpr, xexpr, yexpr, segW, segH, start2)
			} else {
				// RECORTE estático: mantém só a sub-região (frações da fonte) antes de escalar
				if seg_cropped(i) do fmt.sbprintf(&fb, ",crop=iw*%.5f:ih*%.5f:iw*%.5f:ih*%.5f", crw, crh, crx, cry)
				fmt.sbprintf(&fb, ",scale=%d:%d", segW, segH)
				// distorce via remap ANTES da rotação; reposiciona em start2 após.
				if bulge_xin[i] >= 0 {
					fmt.sbprintf(&fb, ",fps=30,format=rgb24[bpre%d];[bpre%d][%d:v][%d:v]remap[brm%d];[brm%d]setpts=PTS+%.3f/TB,format=rgba",
						vc, vc, bulge_xin[i], bulge_yin[i], vc, vc, start2)
				} else {
					fmt.sbprintf(&fb, ",format=rgba")
				}
			}
			// EFEITOS de cor ANTES da rotação: eq/hue convertem p/ YUV (sem alpha); aplicar
			// depois do rotate=c=none perderia a transparência dos cantos rodados. Aqui o
			// vídeo ainda é opaco, então a conversão não custa nada; o rotate recria o alpha.
			export_color_filters(&fb, sg) // eq/hue/negate/vignette
			if abs(sg.rot) > 0.5 {
				rad := sg.rot * math.PI/180
				fmt.sbprintf(&fb, ",rotate=%.5f:c=none:ow=rotw(%.5f):oh=roth(%.5f)", rad, rad, rad)
			}
			if op < 0.999 do fmt.sbprintf(&fb, ",colorchannelmixer=aa=%.3f", op)
			export_trans_fades(&fb, start2, tend, fin, fout)
			fmt.sbprintf(&fb, "[v%d];", vc)
			nb := fmt.tprintf("c%d", vc)
			fmt.sbprintf(&fb, "[%s][v%d]overlay=x='(main_w-overlay_w)/2+(%.4f)*main_w':y='(main_h-overlay_h)/2+(%.4f)*main_h':enable='between(t\\,%.3f\\,%.3f)':eof_action=pass[%s];",
				vlabel, vc, sg.px, sg.py, start2, tend, nb)
			vlabel = nb; vc += 1
		}
		// EFEITOS DE FAIXA ancorados NESTA trilha t: aplicam ao COMPOSTO até aqui (trilhas 0..t =
		// "o que está embaixo" do efeito), ANTES de compor as trilhas acima. Via split+overlay+
		// enable (roda sempre, só aparece em [start,end]). Distorção = remap/lenscorrection; RGB = rgbashift.
		for k in 0 ..< nfx {
			e := fxsegs[k]
			if e.track != t do continue // só os efeitos desta trilha (as de cima aplicam depois)
			es := e.start; ee := e.start + e.dur
			ob := fmt.tprintf("fxb%d", k); op := fmt.tprintf("fxp%d", k); ox := fmt.tprintf("fxx%d", k); oo := fmt.tprintf("fxo%d", k)
			fmt.sbprintf(&fb, "[%s]split[%s][%s];", vlabel, ob, op)
			if e.kind == FX_DISTORT && fx_xin[k] >= 0 {
				// EXATO: remap pelos mapas (mesma matemática do shader). rgb24 antes, como no per-seg.
				fmt.sbprintf(&fb, "[%s]format=rgb24[%spf];[%spf][%d:v][%d:v]remap[%s];", op, op, op, fx_xin[k], fx_yin[k], ox)
			} else {
				fmt.sbprintf(&fb, "[%s]", op)
				switch e.kind {
				case FX_DISTORT: // fallback (mapa falhou): aproximação por lente
					cx := clamp(0.5+e.cx, 0, 1); cy := clamp(0.5+e.cy, 0, 1)
					fmt.sbprintf(&fb, "lenscorrection=cx=%.4f:cy=%.4f:k1=%.4f:k2=0:i=bilinear", cx, cy, -e.amount*0.4)
				case FX_RGB:
					off := fx_rgb_offset(e); rh := off[0]*f32(W); rv := off[1]*f32(H)
					fmt.sbprintf(&fb, "rgbashift=rh=%.1f:rv=%.1f:bh=%.1f:bv=%.1f", rh, rv, -rh, -rv)
				}
				fmt.sbprintf(&fb, "[%s];", ox)
			}
			fmt.sbprintf(&fb, "[%s][%s]overlay=0:0:enable='between(t\\,%.3f\\,%.3f)':eof_action=pass[%s];", ob, ox, es, ee, oo)
			vlabel = oo
		}
	}
	// duplica a saída: [vout] p/ codificar o arquivo; [vpout] reduzido rgb24 (8fps)
	// p/ a prévia ao vivo pelo stdout (a UI mostra enquanto exporta).
	fmt.sbprintf(&fb, "[%s]split=2[vmain][vprv];[vmain]format=yuv420p[vout];[vprv]fps=8,scale=%d:%d:force_original_aspect_ratio=decrease,pad=%d:%d:(ow-iw)/2:(oh-ih)/2,format=rgb24[vpout]",
		vlabel, PREV_W, PREV_H, PREV_W, PREV_H)
	}

	// áudio: cada segmento com áudio não-mudo → trim/volume/fade/adelay → amix
	ac := 0
	for i in 0 ..< nsegs {
		if seg_inp[i] < 0 do continue
		c := &clips[segs[i].src]
		if !c.has_audio || segs[i].muted || track_muted[segs[i].track] do continue
		sg := segs[i]
		vv := sg.vol <= 0 ? 1 : sg.vol
		sp := sg.speed <= 0 ? 1 : sg.speed
		sep := strings.builder_len(fb) > 0 ? ";" : "" // MP3: sem grafo de vídeo, a 1ª cadeia não leva ";"
		fmt.sbprintf(&fb, "%s[%d:a]atrim=%.3f:%.3f,asetpts=PTS-STARTPTS,aformat=sample_rates=48000:channel_layouts=stereo,volume=%.3f",
			sep, seg_inp[i], sg.in_off, sg.in_off+sg.dur*sp, vv)
		// velocidade: atempo aceita 0.5..2 por estágio; encadeia p/ cobrir 0.25..4.
		// Vem ANTES dos fades p/ que o stream já tenha duração `dur` (tempo de timeline).
		if abs(sp-1) > 0.001 {
			r := sp
			for r > 2.0 + 0.001 { fmt.sbprintf(&fb, ",atempo=2.0"); r /= 2 }
			for r < 0.5 - 0.001 { fmt.sbprintf(&fb, ",atempo=0.5"); r *= 2 }
			fmt.sbprintf(&fb, ",atempo=%.5f", r)
		}
		if sg.fade_in > 0.01  do fmt.sbprintf(&fb, ",afade=t=in:st=0:d=%.3f", sg.fade_in)
		if sg.fade_out > 0.01 do fmt.sbprintf(&fb, ",afade=t=out:st=%.3f:d=%.3f", max(0, sg.dur-sg.fade_out), sg.fade_out)
		fmt.sbprintf(&fb, ",adelay=%.0f:all=1[a%d]", sg.start*1000, ac)
		ac += 1
	}
	if ac > 0 {
		fmt.sbprintf(&fb, ";")
		for k in 0 ..< ac do fmt.sbprintf(&fb, "[a%d]", k)
		fmt.sbprintf(&fb, "amix=inputs=%d:normalize=0:dropout_transition=0[aout]", ac)
	}

	if !want_video && ac == 0 { set_toast("Nada de áudio para exportar"); return } // MP3 sem áudio

	append(&args, "-filter_complex", strings.to_string(fb))
	if want_video do append(&args, "-map", "[vout]")
	if ac > 0     do append(&args, "-map", "[aout]")

	// QUALIDADE: CQ (NVENC) / CRF (x264/x265/VP9) — nº maior = arquivo menor. Auto = alta
	// qualidade LIMITADA por teto de bitrate ≈ o da fonte (não incha além do original).
	cq, crf: string
	switch export_qual {
	case .High:   cq, crf = "23", "20"
	case .Medium: cq, crf = "28", "24"
	case .Low:    cq, crf = "32", "28"
	case .Auto:   cq, crf = "25", "22" // qualidade preservada; o -maxrate abaixo segura o tamanho
	}
	// codec por FORMATO. NVENC (GPU) vale p/ H.264 e HEVC; VP9 é sempre por software.
	switch export_fmt {
	case .MP4:
		if gpu do append(&args, "-c:v", "h264_nvenc", "-preset", "p5", "-cq", cq, "-pix_fmt", "yuv420p", "-r", "30")
		else    do append(&args, "-c:v", "libx264", "-preset", "veryfast", "-crf", crf, "-pix_fmt", "yuv420p", "-r", "30")
	case .HEVC: // -tag:v hvc1 = players (QuickTime/Apple) reconhecem o HEVC no .mp4
		if gpu do append(&args, "-c:v", "hevc_nvenc", "-preset", "p5", "-cq", cq, "-tag:v", "hvc1", "-pix_fmt", "yuv420p", "-r", "30")
		else    do append(&args, "-c:v", "libx265", "-preset", "veryfast", "-crf", crf, "-tag:v", "hvc1", "-pix_fmt", "yuv420p", "-r", "30")
	case .WEBM: // VP9 não tem NVENC utilizável aqui; -b:v 0 = modo CRF puro; row-mt acelera
		append(&args, "-c:v", "libvpx-vp9", "-crf", crf, "-b:v", "0", "-row-mt", "1", "-pix_fmt", "yuv420p", "-r", "30")
	case .MP3: // só áudio: descarta o vídeo por completo
		append(&args, "-vn")
	}
	if want_video && export_qual == .Auto {
		// teto = MAIOR bitrate entre as fontes de vídeo na timeline (heurística p/ várias
		// mídias: cada clipe tem o seu; usamos o maior p/ não degradar o mais pesado). Sem
		// bitrate legível (ex.: fonte sem essa info), fica sem teto = comportamento antigo.
		if src := timeline_max_src_bitrate(); src > 0 {
			append(&args, "-maxrate", fmt.tprintf("%d", src), "-bufsize", fmt.tprintf("%d", src*2))
		}
	}
	// áudio: AAC no MP4/HEVC, Opus no WEBM (AAC não entra em .webm), MP3 = codec principal
	if ac > 0 {
		switch export_fmt {
		case .WEBM: append(&args, "-c:a", "libopus", "-b:a", "192k")
		case .MP3:  append(&args, "-c:a", "libmp3lame", "-b:a", export_qual == .High ? "320k" : (export_qual == .Low ? "128k" : "192k"))
		case .MP4, .HEVC: append(&args, "-c:a", "aac", "-b:a", "192k")
		}
	}
	append(&args, export_out)
	// 2ª saída (só formatos de vídeo): frames rgb24 da prévia ao vivo pelo stdout (pipe:1)
	if want_video do append(&args, "-map", "[vpout]", "-an", "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1")

	pr, pw, e := os.pipe() // prévia (stdout)
	if e != nil { set_toast("Falha ao criar pipe"); return }
	gr, gw, e2 := os.pipe() // progresso (stderr)
	if e2 != nil { os.close(pr); os.close(pw); set_toast("Falha ao criar pipe"); return }
	p, pe := os.process_start(os.Process_Desc{ command = args[:], stdout = pw, stderr = gw })
	os.close(pw); os.close(gw)
	if pe != nil { os.close(pr); os.close(gr); set_toast("Falha ao iniciar ffmpeg"); return }
	export_job = make_kill_job()
	if export_job != nil do AssignProcessToJobObject(export_job, win.HANDLE(p.handle))
	export_ps = p; export_r = gr; export_prev_r = pr
	export_total = total; export_pct = 0; export_ok = false
	// prepara os buffers e a textura da prévia (uma vez; reusa nas próximas exportações)
	if export_prev_a == nil { export_prev_a = make([]u8, PREV_BYTES); export_prev_b = make([]u8, PREV_BYTES) }
	if !export_prev_tex_ok {
		img := rl.GenImageColor(PREV_W, PREV_H, rl.BLACK)
		rl.ImageFormat(&img, .UNCOMPRESSED_R8G8B8)
		export_prev_tex = rl.LoadTextureFromImage(img)
		rl.UnloadImage(img)
		export_prev_tex_ok = export_prev_tex.id != 0
	}
	intrinsics.atomic_store(&export_prev_pub, -1)
	intrinsics.atomic_store(&export_prev_seq, 0)
	export_prev_last = 0; export_prev_wslot = 0
	export_paused = false; export_cancel = false
	intrinsics.atomic_store(&export_run, true)
	export_was_running = true // garante que o bloco de conclusão rode mesmo se o clique de cancelar der early-return
	export_thr = thread.create_and_start(export_worker)
	export_prev_thr = thread.create_and_start(export_preview_worker)
	if want_video do set_toast(rl.TextFormat("Exportando %dx%d...", i32(W), i32(H)))
	else          do set_toast("Exportando áudio (MP3)...")
}

// pausa/retoma a exportação suspendendo o processo ffmpeg (as threads de leitura só
// ficam esperando os pipes — sem dado, sem deadlock; retoma e o ffmpeg continua).
export_toggle_pause :: proc() {
	if !intrinsics.atomic_load(&export_run) do return
	if export_paused { NtResumeProcess(win.HANDLE(export_ps.handle)); export_paused = false }
	else            { NtSuspendProcess(win.HANDLE(export_ps.handle)); export_paused = true }
}

// cancela: mata o ffmpeg (pipes -> EOF -> workers terminam). O bloco de conclusão
// no update apaga o arquivo parcial e avisa (não trata como falha).
export_do_cancel :: proc() {
	if !intrinsics.atomic_load(&export_run) do return
	export_cancel = true
	if export_paused { NtResumeProcess(win.HANDLE(export_ps.handle)); export_paused = false } // retoma p/ matar limpo
	_ = os.process_kill(export_ps)
}

// garante que o caminho termine com `ext` (ex.: ".ovp")
ensure_ext :: proc(path, ext: string) -> string {
	if strings.has_suffix(strings.to_lower(path, context.temp_allocator), ext) do return path
	return fmt.tprintf("%s%s", path, ext)
}

// limpa o projeto atual: fecha todas as mídias, zera timeline e histórico
clear_project :: proc() {
	st.playing = false; play_clip = -1; src_preview = -1
	nsegs = 0; selected = -1; bin_sel = -1; drag_clip = -1; sel_trans = -1; st.drag = .None
	nfx = 0; fx_sel = -1; fxlib_drag = -1
	g_nv = 3; g_na = 2; tl_vscroll = 0 // volta à contagem de trilhas padrão
	for i in 0 ..< MAXTRACKS { track_muted[i] = false; track_locked[i] = false; track_hidden[i] = false } // trilhas limpas
	bin_clear_marks(); seg_clear_marks()
	for i in 0 ..< nclips do clip_close(&clips[i])
	for i in 0 ..< MAX_SEGS do spv_release(i) // libera os WAVs de velocidade
	for i in 0 ..< MAX_SEGS do dup_release(i) // libera as texturas das vistas duplicadas
	nclips = 0
	undo_top = 0; redo_top = 0; committed_ok = false
	st.playhead = 0
	set_proj_ar(16.0/9.0); ar_auto = true // formato volta ao padrão (1920x1080) e reativa a autodetecção
	dirty = false
}

// executa a ação que estava esperando a resposta do "salvar alterações?"
do_pending :: proc() {
	pa := pending_action; pending_action = .None
	switch pa {
	case .None:
	case .Close: should_close = true
	case .New:   clear_project(); set_toast("Novo projeto")
	case .Open:  if p, ok := open_video_dialog(); ok do load_project(p)
	}
}

// se há edições não salvas na timeline, pede confirmação (modal); senão executa já
guard_unsaved :: proc(pa: Pending) {
	pending_action = pa
	if dirty && nsegs > 0 && modal == .None do modal = .Confirm
	else do do_pending()
}
request_new   :: proc() { guard_unsaved(.New) }
request_open  :: proc() { guard_unsaved(.Open) }
request_close :: proc() { if modal != .Confirm do guard_unsaved(.Close) }

// salva o projeto (.ovp): proporção + mídias (caminhos) + segmentos (com transform/áudio)
save_project :: proc(path: string) {
	idx: [MAX_CLIPS]int; for i in 0 ..< MAX_CLIPS do idx[i] = -1
	medias := make([dynamic]string, context.temp_allocator)
	for i in 0 ..< nclips {
		if intrinsics.atomic_load(&clips[i].failed) || clips[i].closed do continue
		idx[i] = len(medias)
		if clips[i].is_text { // clipe de texto: "#TXT<tab>size<tab>r<tab>g<tab>b<tab>fonte<tab>texto"
			tc := clips[i].text_color
			append(&medias, fmt.tprintf("#TXT\t%.4f\t%d\t%d\t%d\t%d\t%s", clips[i].text_size, tc.r, tc.g, tc.b, clips[i].text_font, clips[i].text))
		} else {
			append(&medias, clips[i].path)
		}
	}
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "OVP1\nar %.6f\nres %d %d\ntracks %d %d\nmedia %d\n", proj_ar, proj_w, proj_h, g_nv, g_na, len(medias))
	for p in medias do fmt.sbprintf(&b, "%s\n", p)
	nv := 0
	for i in 0 ..< nsegs do if seg_ready(i) && idx[segs[i].src] >= 0 do nv += 1
	fmt.sbprintf(&b, "seg %d\n", nv)
	for i in 0 ..< nsegs {
		if !seg_ready(i) || idx[segs[i].src] < 0 do continue
		s := segs[i]
		fmt.sbprintf(&b, "%d %d %.4f %.4f %.4f %.4f %d %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %d %.4f %.4f %.4f %.4f %d %.4f %.4f %.4f %.4f %.4f %.4f\n",
			idx[s.src], s.track, s.start, s.in_off, s.dur, s.vol, s.muted ? 1 : 0, s.fade_in, s.fade_out, s.scale, s.px, s.py, s.rot, s.opacity, s.speed <= 0 ? 1 : s.speed, s.trans, s.vfin, s.vfout, s.crop_x, s.crop_y, s.crop_w, s.crop_h, s.zoom_anim ? 1 : 0, s.crop2_x, s.crop2_y, s.crop2_w, s.crop2_h, s.aonly ? 1 : 0, s.fx_bright, s.fx_contrast, s.fx_satur, s.fx_look, s.fx_vignette, s.fx_temp)
	}
	// clipes de EFEITO (faixa): kind start dur amount radius cx cy wobble speed angle track
	fmt.sbprintf(&b, "fx %d\n", nfx)
	for i in 0 ..< nfx {
		e := fxsegs[i]
		fmt.sbprintf(&b, "%d %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %d\n", e.kind, e.start, e.dur, e.amount, e.radius, e.cx, e.cy, e.wobble, e.speed, e.angle, e.track)
	}
	if os.write_entire_file(path, b.buf[:]) == nil { dirty = false; set_toast(rl.TextFormat("Projeto salvo: %s", cs(path))) }
	else do set_toast("Falha ao salvar o projeto")
}

// carrega um projeto (.ovp): limpa o atual, reimporta as mídias e recria os segmentos
load_project :: proc(path: string) {
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil { set_toast("Falha ao abrir o projeto"); return }
	lines := strings.split_lines(string(data), context.temp_allocator)
	if len(lines) < 1 || strings.trim_space(lines[0]) != "OVP1" { set_toast("Arquivo de projeto inválido"); return }
	ar: f32 = 16.0/9
	res_w, res_h := 0, 0 // resolução salva (0 = ausente em projetos antigos; deriva de `ar`)
	lnv := -1; lna := -1 // contagem de trilhas do arquivo (-1 = não especificada; deriva do uso)
	mpaths := make([dynamic]string, context.temp_allocator)
	Seg2 :: struct { fields: [34]f32 }
	segd := make([dynamic]Seg2, context.temp_allocator)
	fxd  := make([dynamic]FxSeg, context.temp_allocator)
	li := 1
	for li < len(lines) {
		ln := strings.trim_space(lines[li]); li += 1
		if ln == "" do continue
		toks := strings.fields(ln, context.temp_allocator)
		if len(toks) == 0 do continue
		switch toks[0] {
		case "ar":
			if len(toks) >= 2 do if v, o := strconv.parse_f64(toks[1]); o do ar = f32(v)
		case "res":
			if len(toks) >= 3 { res_w = strconv.parse_int(toks[1]) or_else 0; res_h = strconv.parse_int(toks[2]) or_else 0 }
		case "tracks":
			if len(toks) >= 3 { lnv = strconv.parse_int(toks[1]) or_else -1; lna = strconv.parse_int(toks[2]) or_else -1 }
		case "media":
			n := len(toks) >= 2 ? (strconv.parse_int(toks[1]) or_else 0) : 0
			for _ in 0 ..< n { if li < len(lines) { append(&mpaths, strings.clone(strings.trim_space(lines[li]), context.temp_allocator)); li += 1 } }
		case "seg":
			n := len(toks) >= 2 ? (strconv.parse_int(toks[1]) or_else 0) : 0
			for _ in 0 ..< n {
				if li >= len(lines) do break
				ft := strings.fields(strings.trim_space(lines[li]), context.temp_allocator); li += 1
				s: Seg2
				s.fields[14] = 1 // velocidade padrão p/ projetos antigos (14 campos)
				for k in 0 ..< min(34, len(ft)) do s.fields[k] = f32(strconv.parse_f64(ft[k]) or_else 0)
				append(&segd, s)
			}
		case "fx": // clipes de efeito da faixa
			n := len(toks) >= 2 ? (strconv.parse_int(toks[1]) or_else 0) : 0
			for _ in 0 ..< n {
				if li >= len(lines) do break
				ft := strings.fields(strings.trim_space(lines[li]), context.temp_allocator); li += 1
				if len(ft) < 3 do continue
				g :: proc(ft: []string, k: int) -> f32 { return k < len(ft) ? f32(strconv.parse_f64(ft[k]) or_else 0) : 0 }
				e := FxSeg{ kind = int(g(ft,0)), start = g(ft,1), dur = g(ft,2) }
				if len(ft) >= 10 { e.amount=g(ft,3); e.radius=g(ft,4); e.cx=g(ft,5); e.cy=g(ft,6); e.wobble=g(ft,7); e.speed=g(ft,8); e.angle=g(ft,9) }
				else do fx_defaults(&e) // formato antigo (só kind/start/dur): usa padrões
				e.track = len(ft) >= 11 ? int(g(ft,10)) : -1 // sem track no arquivo: sentinela; vira o topo depois de restaurar g_nv
				append(&fxd, e)
			}
		}
	}
	// aplica: limpa, reimporta (slots 0..N-1 na ordem), recria segmentos
	clear_project()
	for p in mpaths {
		if strings.has_prefix(p, "#TXT\t") { // clipe de texto: recria do registro salvo
			f := strings.split(p, "\t", context.temp_allocator)
			size := len(f) >= 2 ? f32(strconv.parse_f64(f[1]) or_else 0.10) : 0.10
			col := rl.WHITE
			if len(f) >= 5 {
				col.r = u8(strconv.parse_int(f[2]) or_else 255)
				col.g = u8(strconv.parse_int(f[3]) or_else 255)
				col.b = u8(strconv.parse_int(f[4]) or_else 255)
			}
			font := 0; content := "Texto"
			if len(f) >= 7 { font = strconv.parse_int(f[5]) or_else 0; content = f[6] } // novo (com fonte)
			else if len(f) >= 6 { content = f[5] }                                      // antigo (sem fonte)
			slot := new_text_clip(content, size, col)
			if slot >= 0 do clips[slot].text_font = font
		} else {
			import_media(p, false)
		}
	}
	for s in segd {
		f := s.fields
		si := add_seg(int(f[0]), f[2], f[3], f[4], int(f[1]))
		if si < 0 do continue
		sg := &segs[si]
		sg.vol = f[5]; sg.muted = f[6] > 0.5; sg.fade_in = f[7]; sg.fade_out = f[8]
		sg.scale = f[9]; sg.px = f[10]; sg.py = f[11]; sg.rot = f[12]; sg.opacity = f[13]; sg.speed = f[14] <= 0 ? 1 : f[14]; sg.trans = f[15]; sg.vfin = f[16]; sg.vfout = f[17]
		sg.crop_x = f[18]; sg.crop_y = f[19]; sg.crop_w = f[20]; sg.crop_h = f[21]
		sg.zoom_anim = f[22] > 0.5; sg.crop2_x = f[23]; sg.crop2_y = f[24]; sg.crop2_w = f[25]; sg.crop2_h = f[26] // zoom animado
		sg.aonly = f[27] > 0.5 // áudio separado do vídeo (projetos antigos: 0 = normal)
		sg.fx_bright = f[28]; sg.fx_contrast = f[29]; sg.fx_satur = f[30]; sg.fx_look = f[31]; sg.fx_vignette = f[32]; sg.fx_temp = f[33] // efeitos de cor
	}
	for f in fxd { if nfx < MAX_FX { fxsegs[nfx] = f; nfx += 1 } } // clipes de efeito da faixa
	// restaura a contagem de trilhas: do arquivo se houver, senão o suficiente p/ mostrar tudo
	mv, ma := 0, 0
	for i in 0 ..< nsegs do if is_audio_track(segs[i].track) do ma = max(ma, segs[i].track - MAXV + 1); else do mv = max(mv, segs[i].track + 1)
	for i in 0 ..< nfx do if fxsegs[i].track >= 0 do mv = max(mv, fxsegs[i].track + 1)
	g_nv = clamp(max(lnv, mv, 1), 1, MAXV)
	g_na = clamp(max(lna, ma, 1), 1, MAXA)
	for i in 0 ..< nfx do if fxsegs[i].track < 0 do fxsegs[i].track = g_nv - 1 // efeitos antigos (sem track) = topo
	tl_vscroll = 0
	if res_w > 0 && res_h > 0 do set_proj_res(res_w, res_h) // resolução salva (novo formato)
	else do set_proj_ar(ar)                                  // projeto antigo: deriva do aspecto
	ar_auto = false // projeto salvo traz seu próprio formato — não sobrescreve na próxima importação
	dirty = false
	set_toast(rl.TextFormat("Projeto aberto: %s", cs(path)))
}

// diálogo nativo "Salvar como" — retorna o caminho escolhido (folder+nome)
save_dialog :: proc(default_name: string) -> (string, bool) {
	context.allocator = context.temp_allocator
	buf := make([]u16, win.MAX_PATH_WIDE)
	wn := win.utf8_to_utf16(default_name) // pré-preenche o nome
	for i in 0 ..< len(wn) do if i < win.MAX_PATH_WIDE - 1 do buf[i] = wn[i]
	ofn := win.OPENFILENAMEW{
		lStructSize = size_of(win.OPENFILENAMEW),
		hwndOwner   = win.HWND(rl.GetWindowHandle()),
		lpstrFile   = win.wstring(&buf[0]),
		nMaxFile    = u32(len(buf)),
		lpstrTitle  = win.utf8_to_wstring("Salvar como"),
	}
	if !bool(win.GetSaveFileNameW(&ofn)) do return "", false
	name, _ := win.utf16_to_utf8(buf[:])
	return strings.trim_right_null(name), true
}

// diretório de um caminho (sem a barra final)
dir_of :: proc(path: string) -> string {
	for i := len(path) - 1; i >= 0; i -= 1 do if path[i] == '/' || path[i] == '\\' do return path[:i]
	return ""
}
// pasta padrão de salvamento: a do 1º clipe colocado, senão o diretório atual
default_save_dir :: proc() -> string {
	for i in 0 ..< nsegs do if seg_ready(i) {
		if d := dir_of(clips[segs[i].src].path); d != "" do return strings.clone(d)
	}
	if cwd, err := os.get_working_directory(context.temp_allocator); err == nil do return strings.clone(cwd)
	return strings.clone(".")
}
set_name :: proc(s: string) { tf_set(&tf_name, s); name_focus = true }
name_str :: proc() -> string { return string(tf_name.buf[:tf_name.len]) }

open_export_modal :: proc() {
	if intrinsics.atomic_load(&export_run) { set_toast("Exportação já em andamento"); return }
	if timeline_dur() <= 0 { set_toast("Nada na timeline para exportar"); return }
	modal = .Export; set_name("Meu Video")
	if save_dir != "" do delete(save_dir)
	save_dir = default_save_dir()
}
open_shot_modal :: proc() {
	if pc, _ := player_source(); pc < 0 { set_toast("Nada no player para capturar"); return }
	modal = .Shot; set_name(fmt.tprintf("screenshot_%d", shot_n)); shot_ext = 0
	if save_dir != "" do delete(save_dir)
	save_dir = default_save_dir()
}

// carrega uma fonte TTF como atlas SDF (nítida em qualquer tamanho com o sdf_shader).
load_sdf_font :: proc(path: cstring, cp: []rune, sz: i32) -> (rl.Font, bool) {
	dsz: i32
	fd := rl.LoadFileData(path, &dsz)
	if fd == nil do return {}, false
	f: rl.Font
	f.baseSize = sz
	f.glyphCount = i32(len(cp))
	f.glyphs = rl.LoadFontData(fd, dsz, sz, raw_data(cp), i32(len(cp)), .SDF)
	recs: [^]rl.Rectangle
	atlas := rl.GenImageFontAtlas(f.glyphs, &recs, i32(len(cp)), sz, 0, 1)
	f.recs = recs
	f.texture = rl.LoadTextureFromImage(atlas)
	rl.UnloadImage(atlas)
	rl.UnloadFileData(fd)
	if f.texture.id == 0 do return {}, false
	rl.SetTextureFilter(f.texture, .BILINEAR)
	return f, true
}

// thread: estágio de CPU das fontes de texto (ver comentário em tf_cpu). Preenche os slots
// em ordem compacta (fonte que falha é pulada) e marca ready um a um — a main sobe conforme.
text_fonts_worker :: proc() {
	cp: [FONT_CP_N]rune
	for i in 0 ..< len(cp) do cp[i] = rune(32 + i)
	NAMES := []cstring{ "Arial", "Arial Black", "Impact", "Times New Roman", "Georgia", "Verdana", "Comic Sans", "Consolas", "Trebuchet" }
	PATHS := []cstring{
		"C:/Windows/Fonts/arial.ttf", "C:/Windows/Fonts/ariblk.ttf", "C:/Windows/Fonts/impact.ttf", "C:/Windows/Fonts/times.ttf",
		"C:/Windows/Fonts/georgia.ttf", "C:/Windows/Fonts/verdana.ttf", "C:/Windows/Fonts/comic.ttf", "C:/Windows/Fonts/consola.ttf", "C:/Windows/Fonts/trebuc.ttf",
	}
	n := 0
	for p, i in PATHS {
		dsz: i32
		fd := rl.LoadFileData(p, &dsz)
		if fd == nil do continue
		g := rl.LoadFontData(fd, dsz, SDF_SZ, raw_data(cp[:]), i32(len(cp)), .SDF)
		if g == nil { rl.UnloadFileData(fd); continue }
		recs: [^]rl.Rectangle
		atlas := rl.GenImageFontAtlas(g, &recs, i32(len(cp)), SDF_SZ, 0, 1)
		rl.UnloadFileData(fd)
		tf_cpu[n].glyphs = g; tf_cpu[n].recs = recs; tf_cpu[n].atlas = atlas; tf_cpu[n].name = NAMES[i]
		intrinsics.atomic_store(&tf_cpu[n].ready, true)
		n += 1
	}
	intrinsics.atomic_store(&tf_done, true)
}

// (main, 1x/frame) sobe a textura (GL) das fontes de texto cujo estágio de CPU terminou.
ensure_text_fonts :: proc() {
	for tf_up < len(tf_cpu) && intrinsics.atomic_load(&tf_cpu[tf_up].ready) {
		e := &tf_cpu[tf_up]
		f: rl.Font
		f.baseSize = SDF_SZ
		f.glyphCount = FONT_CP_N
		f.glyphs = e.glyphs
		f.recs = e.recs
		f.texture = rl.LoadTextureFromImage(e.atlas)
		rl.UnloadImage(e.atlas)
		if f.texture.id != 0 {
			rl.SetTextureFilter(f.texture, .BILINEAR)
			append(&text_fonts, TextFont{ f, e.name })
		}
		tf_up += 1
	}
}

// true quando não vem mais fonte nova (worker acabou e tudo pronto já subiu) — só então é
// seguro CLAMPAR índice de fonte salvo em projeto (antes disso a fonte pode só não ter chegado).
text_fonts_settled :: proc() -> bool {
	return intrinsics.atomic_load(&tf_done) && (tf_up >= len(tf_cpu) || !intrinsics.atomic_load(&tf_cpu[tf_up].ready))
}

// o editor é um app GUI (compilado com -subsystem:windows, sem console). Cada ffmpeg/ffprobe
// é um app de CONSOLE e, sem um console do PAI para herdar, o Windows abre uma JANELA PRETA
// nova por processo (enxurrada de terminais ao importar/tocar/exportar). Solução: alocar um
// console e ESCONDÊ-LO já — os filhos se anexam a ele (invisível) em vez de criar janelas.
// (Se o editor foi aberto DE um terminal — ex.: -bench —, AllocConsole falha e não escondemos
// nada: a saída segue visível no terminal, comportamento desejado no dev.)
// aviso sonoro de "exportação concluída". Um som curto de 2 notas gerado NO PRÓPRIO motor
// de áudio do raylib (que já toca o áudio dos vídeos) — assim independe do esquema de sons
// do Windows: o MessageBeep ficava MUDO se o usuário tivesse "Sem sons" atribuído ao evento.
// Construído 1x após InitAudioDevice; reproduzido com rl.PlaySound (não trava a UI).
g_done_snd:    rl.Sound
g_done_snd_ok: bool
build_done_sound :: proc() {
	if !rl.IsAudioDeviceReady() do return
	SR  :: 44100
	n   := int(f32(SR) * 0.26)              // ~0,26 s no total
	buf := make([]i16, n); defer delete(buf)
	f1  := f32(880.0)                       // 1ª nota (A5)
	f2  := f32(1318.51)                     // 2ª nota (E6) — sobe = "ta-dá"
	half := n / 2
	for i in 0 ..< n {
		t    := f32(i) / f32(SR)
		freq := i < half ? f1 : f2
		// envelope 0→1→0 DENTRO de cada nota (senoide): ataque+decaimento sem cliques
		loc  := i < half ? f32(i)/f32(half) : f32(i-half)/f32(n-half)
		env  := math.sin(loc * math.PI)
		s    := math.sin(2*math.PI*freq*t) * env * 0.35
		buf[i] = i16(clamp(s, -1, 1) * 32767)
	}
	w := rl.Wave{ frameCount = u32(n), sampleRate = u32(SR), sampleSize = 16, channels = 1, data = raw_data(buf) }
	g_done_snd = rl.LoadSoundFromWave(w)  // o raylib COPIA os dados; buf pode ser liberado
	g_done_snd_ok = rl.IsSoundValid(g_done_snd)
}

hide_child_consoles :: proc() {
	if !bool(win.AllocConsole()) do return // já tinha console (ex.: aberto de um terminal) — não mexe
	hwnd := win.GetConsoleWindow()
	if hwnd == nil do return
	// ShowWindow é chamado via GetProcAddress (runtime) DE PROPÓSITO: linkar User32.lib estático
	// colide com o CloseWindow/ShowCursor que o raylib.lib já define com os mesmos nomes (LNK2005).
	ShowWindow_t :: proc "system" (hWnd: win.HWND, nCmdShow: i32) -> win.BOOL
	if u := win.LoadLibraryW(win.utf8_to_wstring("user32.dll")); u != nil {
		if p := win.GetProcAddress(u, "ShowWindow"); p != nil {
			(cast(ShowWindow_t) p)(hwnd, i32(win.SW_HIDE))
		}
	}
}

// resolve caminhos que dependem da MÁQUINA (não podem ser fixos no fonte): a base de temp no
// %TEMP% real do usuário e a pasta do próprio .exe, que é inserida no INÍCIO do PATH para que
// os "ffmpeg"/"ffprobe" chamados pelo nome resolvam para os binários EMPACOTADOS ao lado do
// editor (assim o app funciona sem o usuário instalar/configurar ffmpeg).
init_paths :: proc() {
	tmp := os.get_env("TEMP", context.allocator)
	if tmp == "" do tmp = os.get_env("TMP", context.allocator)
	if tmp == "" do tmp = "."
	AUDIO_BASE = fmt.aprintf("%s\\odin_editor_audio", tmp)

	if exe, err := os.get_executable_path(context.temp_allocator); err == nil {
		if cut := strings.last_index_any(exe, "\\/"); cut > 0 {
			dir  := exe[:cut]
			EXE_DIR = strings.clone(dir) // dono; usado p/ achar o log de diagnóstico ao lado do .exe
			old  := os.get_env("PATH", context.temp_allocator)
			newp := fmt.tprintf("%s;%s", dir, old)
			win.SetEnvironmentVariableW(win.utf8_to_wstring("PATH"), win.utf8_to_wstring(newp))
		}
	}
}

// STARTUP: apaga temporários ÓRFÃOS — arquivos "odin_editor_audio_*" no %TEMP% cujo PID
// (embutido no nome) pertence a um processo que NÃO existe mais. São lixo de fechamentos
// por CRASH (o fechamento normal via close_now já limpa os do próprio PID). NÃO toca nos
// de um PID vivo: pode ser OUTRA instância do editor rodando agora. Roda depois do
// init_paths (precisa de AUDIO_BASE) e antes de qualquer spawn/temp. %TEMP% é por-usuário,
// então todo arquivo aqui é nosso (mesmo usuário) — sem risco de acesso negado no OpenProcess.
sweep_orphan_temps :: proc() {
	if AUDIO_BASE == "" do return
	slash := strings.last_index(AUDIO_BASE, "\\")
	if slash < 0 do return
	dir := AUDIO_BASE[:slash] // o %TEMP% (FindFirstFileW devolve só o NOME do arquivo, sem pasta)
	fd: win.WIN32_FIND_DATAW
	h := win.FindFirstFileW(win.utf8_to_wstring(fmt.tprintf("%s_*", AUDIO_BASE)), &fd)
	if h == win.INVALID_HANDLE_VALUE do return
	defer win.FindClose(h)
	PREFIX :: "odin_editor_audio_" // nome = PREFIX + <pid> + "_..." (ver os aprintf de aud_path/spv/box/fx)
	for {
		if fd.dwFileAttributes & win.FILE_ATTRIBUTE_DIRECTORY == 0 { // ignora subpastas
			name := win.wstring_to_utf8(win.wstring(raw_data(fd.cFileName[:])), -1) or_else ""
			if strings.has_prefix(name, PREFIX) {
				rest := name[len(PREFIX):]
				e := 0
				for e < len(rest) && rest[e] >= '0' && rest[e] <= '9' do e += 1 // dígitos do PID
				if pid, ok := strconv.parse_int(rest[:e], 10); ok && pid > 0 && !pid_alive(u32(pid)) {
					os.remove(fmt.tprintf("%s\\%s", dir, name))
				}
			}
		}
		if !win.FindNextFileW(h, &fd) do break
	}
}

// existe um processo com esse PID? OpenProcess devolve nil se o PID não corresponde a
// processo nenhum -> órfão seguro p/ apagar. Se corresponde (editor vivo, ou PID reciclado
// p/ outro programa), MANTÉM o arquivo — conservador: nunca apaga o de uma instância viva.
pid_alive :: proc(pid: u32) -> bool {
	h := win.OpenProcess(win.PROCESS_QUERY_LIMITED_INFORMATION, win.FALSE, win.DWORD(pid))
	if h == nil do return false
	win.CloseHandle(h)
	return true
}

main :: proc() {
	hide_child_consoles() // esconde as janelas de console dos ffmpeg — ANTES de qualquer spawn
	init_paths() // resolve %TEMP% e acha o ffmpeg empacotado — ANTES de qualquer spawn/temp
	sweep_orphan_temps() // varre o %TEMP%: apaga temporários de PIDs mortos (lixo de crashes antigos)
	job_init() // antes de qualquer spawn de ffmpeg
	rl.SetConfigFlags({ .WINDOW_RESIZABLE, .WINDOW_UNDECORATED, .MSAA_4X_HINT, .VSYNC_HINT })
	rl.InitWindow(1280, 760, "Editor de Vídeo")
	rl.SetExitKey(.KEY_NULL) // ESC não fecha; só o botão X da barra
	rl.MaximizeWindow()      // abre já maximizado
	// ícone da janela/barra de tarefas em runtime (o ícone do .exe vem do recurso icon.res
	// embutido no link). PNG embutido no binário via #load — sem depender de arquivo externo.
	{
		png := #load("icon.png")
		ico := rl.LoadImageFromMemory(".png", raw_data(png), i32(len(png)))
		rl.SetWindowIcon(ico)
		rl.UnloadImage(ico)
	}
	// buffer de música GRANDE (16384 frames ≈ 341ms): o decode de vídeo ao vivo é
	// lido do pipe do ffmpeg NA MAIN THREAD (pipe ~64KB << frame 675KB, sem decode
	// adiantado) — um frame ocasionalmente lento bloqueia a main por dezenas/centenas
	// de ms, e nesse tempo o UpdateMusicStream não roda. Um buffer de 85ms (4096)
	// estourava e estalava depois de 1-2min tocando (o vídeo seguia fluido porque o
	// decode acompanha na média). 341ms absorve esses picos. O custo de rearme no
	// seek é coberto pelo pré-enchimento em set_play_clip. Antes de LoadMusicStream.
	rl.SetAudioStreamBufferSizeDefault(16384)
	rl.InitAudioDevice()
	build_done_sound() // gera o "ding" de fim de exportação (precisa do audio device pronto)
	g_refresh = i32(rl.GetMonitorRefreshRate(rl.GetCurrentMonitor()))
	if g_refresh < 30 || g_refresh > 360 do g_refresh = 60 // driver devolveu 0/valor absurdo: 60
	rl.SetTargetFPS(g_refresh)

	cp: [FONT_CP_N]rune
	for i in 0 ..< len(cp) do cp[i] = rune(32 + i)
	// fonte SDF (signed distance field): a UI desenha 11..18px (downscale). Atlas bitmap
	// escalado borra; SDF + shader dá texto NÍTIDO em qualquer tamanho.
	sdf_shader = rl.LoadShaderFromMemory(nil, SDF_FS)
	if f, ok := load_sdf_font("C:/Windows/Fonts/segoeui.ttf", cp[:], SDF_SZ); ok {
		ui_font = f
		sdf_ok = sdf_shader.id != 0
	}
	if !sdf_ok { // fallback: atlas normal
		ui_font = rl.LoadFontEx("C:/Windows/Fonts/segoeui.ttf", 32, raw_data(cp[:]), i32(len(cp)))
		if ui_font.texture.id == 0 do ui_font = rl.GetFontDefault()
		rl.SetTextureFilter(ui_font.texture, .BILINEAR)
	}
	// shader do efeito de distorção (bulge/pinch) — usado no preview do vídeo
	bulge_shader = rl.LoadShaderFromMemory(nil, BULGE_FS)
	bulge_ok = bulge_shader.id != 0
	if bulge_ok {
		bulge_loc_uv0      = rl.GetShaderLocation(bulge_shader, "uv0")
		bulge_loc_uv1      = rl.GetShaderLocation(bulge_shader, "uv1")
		bulge_loc_center   = rl.GetShaderLocation(bulge_shader, "center")
		bulge_loc_strength = rl.GetShaderLocation(bulge_shader, "strength")
		bulge_loc_radius   = rl.GetShaderLocation(bulge_shader, "radius")
		bulge_loc_aspect   = rl.GetShaderLocation(bulge_shader, "aspect")
		fx_loc_bright      = rl.GetShaderLocation(bulge_shader, "bright")
		fx_loc_contrast    = rl.GetShaderLocation(bulge_shader, "contrast")
		fx_loc_satur       = rl.GetShaderLocation(bulge_shader, "satur")
		fx_loc_look        = rl.GetShaderLocation(bulge_shader, "look")
		fx_loc_vignette    = rl.GetShaderLocation(bulge_shader, "vignette")
		fx_loc_temp        = rl.GetShaderLocation(bulge_shader, "temp")
		fx_loc_rgb         = rl.GetShaderLocation(bulge_shader, "rgb")
	}
	// fontes dos clipes de texto: Segoe UI (=ui_font) + um conjunto do Windows carregado
	// em THREAD (2 estágios, ver tf_cpu) — síncrono custava ~2.7s e dominava o startup.
	// só carrega os extras no caminho SDF (sem o shader eles sairiam borrados).
	append(&text_fonts, TextFont{ ui_font, "Segoe UI" })
	if sdf_ok do tf_thr = thread.create_and_start(text_fonts_worker)
	else      do intrinsics.atomic_store(&tf_done, true)

	st = State{ active_tab = 0, zoom = 1 }

	// worker de scrub (decode de frame fora da main thread). Tamanho MÁX (720p): um
	// clipe streaming em Alta entrega frames maiores; alocar no máximo evita realocar
	// o buffer sob as threads ao trocar a qualidade (usa-se só cframe(c) bytes deles).
	scrub_buf = make([]u8, STREAM_FBYTES_MAX)
	dup_buf = make([]u8, STREAM_FBYTES_MAX)
	dup_rd_buf = make([]u8, STREAM_FBYTES_MAX)
	scrub_run = true
	scrub_thr = thread.create_and_start(scrub_worker)

	wsc_prev := false
	for !should_close {
		// Alt+F4 / fechar do SO: mesmo fluxo do botão X (pergunta se quer salvar).
		// Borda de subida p/ não reabrir o modal a cada frame se o flag ficar preso.
		wsc := rl.WindowShouldClose()
		if wsc && !wsc_prev do request_close()
		wsc_prev = wsc
		bench_wt := time.tick_now() // (bench) começo do TRABALHO do frame
		ensure_text_fonts() // sobe (GL) as fontes de texto que o worker aprontou
		pu := prof_beg(.Update)
		update() // continua rodando minimizado: imports, áudio e playback seguem vivos
		prof_end(.Update, pu)
		check_invariants() // debug: valida o estado da timeline pós-update (no-op no release)
		rl.BeginDrawing()
		if !rl.IsWindowMinimized() {
			rl.ClearBackground(BG)
			pd := prof_beg(.Draw); draw(); prof_end(.Draw, pd)
			prof_hud() // HUD do profiler por cima de tudo (no-op se F3 desligado)
		}
		prof_tick()
		// (bench) trabalho = update+draw, SEM o vsync do EndDrawing; no-op sem -bench
		work_ms := time.duration_milliseconds(time.tick_diff(bench_wt, time.tick_now()))
		bench_frame(work_ms)
		// TEMPO REAL entre frames apresentados (inclui vsync/GPU/swap — o que work_ms NÃO pega).
		// É ISTO que o olho vê como travadinha. 60fps liso = ~16ms; >33ms (abaixo de 30fps) = engasgo.
		// Ignora >300ms (stall de sistema: modal de arrasto de janela, minimizado — não é o vídeo).
		ft_ms := f64(rl.GetFrameTime()) * 1000
		if st.playing && ft_ms > 33 && ft_ms < 300 do dbg("HITCH", "frame APRESENTADO em %.0fms (%.0ffps) — work=%.0fms (o resto foi vsync/GPU) ph=%.1fs", ft_ms, 1000/ft_ms, work_ms, st.playhead)
		// heartbeat a cada 0.5s de playback: estado do decoder + FPS REAL do vídeo (quantos frames
		// NOVOS subiram/s) e o present delta. Se vfps cai bem abaixo de 30, o VÍDEO trava (decode
		// não acompanha), mesmo com a UI lisa. Captura o comportamento contínuo sem evento discreto.
		if intrinsics.atomic_load(&dbg_on) && st.playing && time.duration_milliseconds(time.tick_diff(dbg_hb_t, time.tick_now())) > 500 {
			dt := time.duration_seconds(time.tick_diff(dbg_hb_t, time.tick_now()))
			vfps := dt > 0 ? f64(dbg_vframes) / dt : 0
			thumbf := dbg_thumb_frames
			dbg_hb_t = time.tick_now(); dbg_vframes = 0; dbg_thumb_frames = 0
			if vs := view_seg(); vs >= 0 {
				c := seg_src(vs); lt := seg_local(vs, st.playhead)
				dbg("STATE", "ph=%.1fs clip='%s' live=%v hw=%v no_hw=%v vfps=%.0f(need~30) present=%.0fms atraso=%.2fs miniatura_flashes=%d work=%.0fms",
					st.playhead, c.name, c.live_on, c.live_hw, c.no_hw, vfps, ft_ms, lt - c.tex_t, thumbf, work_ms)
			}
		}
		rl.EndDrawing() // sempre: é aqui que o raylib faz o poll de eventos
		free_all(context.temp_allocator)
	}

	// Fechamento instantâneo: mata todo ffmpeg, solta os handles de áudio, apaga os
	// temporários e sai. Sem joins de thread nem teardown do raylib (o SO recupera tudo,
	// inclusive o buffer do som de fim de export — por isso nada de UnloadSound aqui).
	close_now()
}

// guarda uma CÓPIA própria da mensagem: rl.TextFormat cicla só 4 buffers
// estáticos (o overlay F1 sozinho os recicla em 2 frames) e o toast fica 3s na
// tela — sem a cópia ele passava a mostrar o texto de outra chamada qualquer.
set_toast :: proc(msg: cstring) {
	if toast_msg != nil do delete(toast_msg)
	toast_msg = fmt.caprintf("%s", msg)
	toast_t = 3
}

// diálogo nativo do Windows para escolher um vídeo
open_video_dialog :: proc() -> (string, bool) {
	context.allocator = context.temp_allocator
	buf := make([]u16, win.MAX_PATH_WIDE)
	ofn := win.OPENFILENAMEW{
		lStructSize = size_of(win.OPENFILENAMEW),
		hwndOwner   = win.HWND(rl.GetWindowHandle()),
		lpstrFile   = win.wstring(&buf[0]),
		nMaxFile    = u32(len(buf)),
		lpstrTitle  = win.utf8_to_wstring("Importar vídeo"),
		Flags       = win.OPEN_FLAGS,
	}
	if !bool(win.GetOpenFileNameW(&ofn)) do return "", false
	name, _ := win.utf16_to_utf8(buf[:])
	return strings.trim_right_null(name), true
}

// diálogo de importação com SELEÇÃO MÚLTIPLA. Retorna vários caminhos. Formato do buffer
// (OFN_EXPLORER + ALLOWMULTISELECT): 1 arquivo = "caminho completo\0\0"; N arquivos =
// "diretório\0nome1\0nome2\0...\0\0" (o dir vem 1x, junta com cada nome).
open_videos_dialog :: proc() -> ([]string, bool) {
	context.allocator = context.temp_allocator
	buf := make([]u16, 1 << 16) // buffer grande: multi-seleção concatena vários caminhos
	ofn := win.OPENFILENAMEW{
		lStructSize = size_of(win.OPENFILENAMEW),
		hwndOwner   = win.HWND(rl.GetWindowHandle()),
		lpstrFile   = win.wstring(&buf[0]),
		nMaxFile    = u32(len(buf)),
		lpstrTitle  = win.utf8_to_wstring("Importar mídia (segure Ctrl/Shift p/ várias)"),
		Flags       = win.OPEN_FLAGS_MULTI,
	}
	if !bool(win.GetOpenFileNameW(&ofn)) do return nil, false
	return multiselect_paths(buf)
}

// quebra o buffer do GetOpenFileNameW (ALLOWMULTISELECT) em caminhos completos:
// pedaços por NUL até o NUL duplo (fim). Retorna memória temp (como o resto do diálogo).
multiselect_paths :: proc(buf: []u16) -> ([]string, bool) {
	context.allocator = context.temp_allocator
	parts: [dynamic]string
	start := 0
	for i in 0 ..< len(buf) {
		if buf[i] == 0 {
			if i == start do break // NUL duplo = fim da lista
			s, _ := win.utf16_to_utf8(buf[start:i])
			append(&parts, s)
			start = i + 1
		}
	}
	if len(parts) == 0 do return nil, false
	if len(parts) == 1 do return parts[:], true // 1 arquivo = caminho completo
	// N arquivos: parts[0] é o diretório, os demais são nomes → junta
	dir := parts[0]
	out := make([]string, len(parts) - 1)
	for k in 1 ..< len(parts) do out[k-1] = fmt.tprintf("%s\\%s", dir, parts[k])
	return out, true
}

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

cached_seconds :: proc() -> f32 {
	s: f32 = 0
	for i in 0 ..< nclips {
		// pesa por fps: um clipe 60fps ocupa 2×/seg na RAM, então conta como 2× no orçamento
		if intrinsics.atomic_load(&clips[i].probed) && !clips[i].streaming do s += clips[i].dur * cfps_of(&clips[i]) / DEC_FPS
	}
	return s
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

// atualiza o conteúdo de um clipe de texto (marca o projeto como não salvo — o undo só
// vê `segs`, então texto/estilo não são desfazíveis, mas precisam sujar p/ o "salvar?").
set_text_clip :: proc(c: ^Clip, s: string) {
	if c.text == s do return
	delete(c.text); c.text = strings.clone(s); dirty = true
}

// botão "Texto": cria o clipe e coloca um segmento na trilha de vídeo do TOPO (overlay),
// no playhead. Já seleciona p/ o usuário editar o conteúdo no inspector.
add_text :: proc() {
	slot := new_text_clip("Texto", 0.10, rl.WHITE)
	if slot < 0 do return
	tr := g_nv - 1 // trilha de vídeo mais alta = vence no compositing (fica por cima)
	start := free_start(tr, -1, st.playhead, clips[slot].dur)
	si := add_seg(slot, start, 0, clips[slot].dur, tr)
	if si < 0 { set_toast("Timeline cheia"); return }
	selected = si; bin_sel = -1; insp_tab = 0
	seek_global(st.playhead)
	set_toast("Texto adicionado — edite no painel à direita")
}

// tipos de transição do painel: 0 = dissolver (com o clipe anterior) | 1 = fade de
// entrada (do preto) | 2 = fade de saída (p/ o preto). Aplica ao segmento selecionado.
apply_transition :: proc(kind: int) {
	if selected < 0 || selected >= nsegs { set_toast("Selecione um clipe na timeline primeiro"); return }
	sg := &segs[selected]
	if seg_audio_like(selected) { set_toast("Transições são p/ vídeo/imagem/texto"); return }
	switch kind {
	case 0: // dissolver com o clipe anterior adjacente
		if seg_speed(selected) != 1 { set_toast("Dissolver não combina com velocidade alterada"); return }
		tm := trans_max(selected)
		if tm <= 0.01 { trans_deny_toast(selected); return }
		sg.trans = min(1, tm); set_toast("Dissolver aplicado")
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
		segs[target].trans = min(1, tm); set_toast("Dissolver aplicado")
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

// roda em thread de fundo: NÃO toca em GL (textura/áudio ficam para a main thread)
import_worker :: proc(c: ^Clip) {
	// IMAGEM: 1 frame estático, sem áudio, duração padrão (extensível na timeline)
	if is_image_path(c.path) {
		c.is_img = true
		c.dur = IMG_DUR
		c.streaming = false
		c.total = 1
		c.cache = make([]u8, FRAME)
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
	// fps que o cache usaria: SEGUE a fonte, teto 60. Uma gravação 60fps tocava a 30
	// (o cache forçava -r 30) e o movimento fino "tremia"/judder; agora toca nativo.
	// 24/25/30 seguem como são (menos RAM). Probe falho -> DEC_FPS.
	cf := sfps > 0 ? min(sfps, f32(60)) : DEC_FPS
	// RAM ~ dur × fps: um clipe 60fps ocupa 2×/seg, então pesa 2× ao decidir streaming
	c.streaming = dur > STREAM_OVER || cached_seconds() + dur * cf / DEC_FPS > CACHE_BUDGET

	if c.streaming {
		c.dw = stream_dw(); c.dh = stream_dh() // qualidade atual (Alta/Baixa); dims de decode do clipe
		c.fbuf = make([]u8, STREAM_FBYTES_MAX) // max (720p): trocar de qualidade não realoca
		stream_seek(c, 0, false) // lê o 1º frame para fbuf (sem GL)
		intrinsics.atomic_store(&c.probed, true)
		// head de áudio: 30s de WAV ficam prontos em ~1s -> o clipe já toca com som
		c.head_dur = min(HEAD_SECS, c.dur)
		if audio_extract(c, c.aud_head, true) do intrinsics.atomic_store(&c.head_ok, true)
		intrinsics.atomic_store(&c.head_done, true)
	} else {
		c.cfps = cf
		c.total = int(dur * cf) + 2
		c.cache = make([]u8, c.total * FRAME)
		// cache_dec_start é software (ver lá): sem retry de fallback de NVDEC — o decode do cache
		// já é software puro, então uma falha aqui é falha real.
		if !cache_dec_start(c) { intrinsics.atomic_store(&c.failed, true); intrinsics.atomic_store(&c.probed, true); return }
		ok0 := clip_read_into(c, 0)
		if ok0 do intrinsics.atomic_store(&c.cached, 1)
		intrinsics.atomic_store(&c.probed, true) // já aparece no bin
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
	n := len(c.wave)
	buf := make([]u8, 1 << 16)
	defer delete(buf)
	frame_idx := 0
	fill := 0
	published := false
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

// extrai o áudio do vídeo para WAV PCM. WAV é ~12x mais rápido de gerar que
// OGG/MP3 (só decodifica, não codifica); o raylib toca WAV com streaming do
// disco (RAM baixa). Custo: ~10 MB/min de arquivo temporário.
// head=true limita aos primeiros HEAD_SECS (-t antes do -i: o ffmpeg nem lê o
// resto do arquivo, por isso fica pronto em ~1s mesmo em vídeos longos).
// Processo próprio + polling de `stop`: fechar o app aborta o ffmpeg em vez
// de congelar o join esperando a extração (vídeos longos demoram muito).
// dispara a extração (não bloqueia): retorna o processo p/ aguardar depois.
// Separar start/wait deixa o WAV completo ser extraído EM PARALELO à waveform e
// às miniaturas (antes ele só começava depois delas — atrasava muito o áudio
// completo em vídeos longos, prolongando a janela em que adiantar dava mudo).
// SEM -ac fixo: preserva o layout NATIVO do source. O áudio deste VOD é MONO;
// forçar "-ac 2" duplicava o mono em 2 canais e a reprodução saía picotando só
// num dos lados. Mono nativo -> WAV mono -> o raylib expande igual nos 2 ouvidos.
audio_extract_start :: proc(c: ^Clip, out: string, head: bool) -> (os.Process, bool) {
	head_cmd := []string{
		"ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
		"-t", fmt.tprintf("%.0f", HEAD_SECS), "-i", c.path,
		"-vn", "-c:a", "pcm_s16le", out,
	}
	full_cmd := []string{
		"ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-i", c.path,
		"-vn", "-c:a", "pcm_s16le", out,
	}
	ap, ape := os.process_start(os.Process_Desc{ command = head ? head_cmd : full_cmd })
	if ape != nil do return {}, false
	tame_process(c, ap, !head) // head é curto e sensível a latência; completo é fundo
	return ap, true
}

// aguarda a extração terminar; polling de `stop` p/ abortar se o app fechar.
audio_extract_wait :: proc(c: ^Clip, ap: os.Process) -> bool {
	for {
		if intrinsics.atomic_load(&c.stop) { // app fechando: mata e sai
			_ = os.process_kill(ap)
			_, _ = os.process_wait(ap)
			return false
		}
		state, werr := os.process_wait(ap, 50 * time.Millisecond)
		if state.exited do return state.exit_code == 0
		if werr != nil && werr != os.General_Error.Timeout do return false // erro real
	}
}

audio_extract :: proc(c: ^Clip, out: string, head: bool) -> bool {
	ap, ok := audio_extract_start(c, out, head)
	if !ok do return false
	return audio_extract_wait(c, ap)
}

// ----- áudio completo em partes -----
part_path :: proc(c: ^Clip, k: int) -> string { // OGG: pequeno (~90MB p/ 5h) e decodificado pelo stb_vorbis, não o drwav
	return fmt.tprintf("%s_full.ogg", c.aud_path)
}

// worker: extrai o áudio COMPLETO num ÚNICO WAV (o raylib NÃO tem FLAC embutido;
// suporta wav/ogg/mp3/qoa). Com o áudio MONO, 5h de WAV s16 = ~1.6GB — cabe no
// fseek de 32 bits do dr_wav (o estéreo passava de 2GB; foi por isso que fatiei
// em partes, e a troca de stream em CADA fronteira era o picote "sempre nas
// mesmas partes"). WAV gera em ~12s (só decodifica), então o head cobre a ponte.
// Um arquivo só = seek limpo em qualquer ponto, ZERO fronteiras.
// Salvaguarda: acima de ~6h a 48kHz o WAV passaria de 2GB -> baixa a taxa p/ caber.
parts_worker :: proc(c: ^Clip) {
	// OGG (libvorbis) em vez de WAV: o WAV único de 1.58GB fazia o rl.Music/drwav
	// CHIAR (som granulado, underrun=0, só neste vídeo/áudio grande; head e chunks
	// pequenos tocavam limpos). OGG comprime 5h em ~90MB, tamanho parecido com os
	// chunks que funcionam, e usa o stb_vorbis (decoder diferente). ~3-4min p/ gerar
	// (o head + chunks cobrem a ponte). Qualidade cheia de 48kHz.
	cmd := []string{
		"ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-i", c.path,
		"-vn", "-c:a", "libvorbis", "-q:a", "4", part_path(c, 0),
	}
	ok := false
	if ap, ape := os.process_start(os.Process_Desc{ command = cmd }); ape == nil {
		tame_process(c, ap, true) // fundo: o head cobre a interatividade até ficar pronto
		ok = audio_extract_wait(c, ap)
	}
	if ok do intrinsics.atomic_store(&c.parts_done, 1)
	intrinsics.atomic_store(&c.ogg_ok, ok)
	intrinsics.atomic_store(&c.ogg_done, true)
}

// (main) troca a janela de áudio ativa pelo FLAC completo (cobre o vídeo inteiro),
// assim que ele fica pronto. Uma única troca (head -> completo), sem fronteiras
// depois. true = c.music tem relógio válido em `local`.
try_part_open :: proc(c: ^Clip, local: f32) -> bool {
	if audio_clock_ok(c, local) do return true
	if intrinsics.atomic_load(&c.parts_done) < 1 do return false // FLAC ainda não pronto
	// já é o FLAC completo (base 0, cobre ~c.dur)? então não há o que trocar
	if c.has_audio && c.music_base == 0 {
		end := f32(c.music.frameCount) / f32(c.music.stream.sampleRate)
		if end >= c.dur - 0.5 do return false // é o completo; a margem de 0.25s no fim é normal
	}
	if c.has_audio { rl.UnloadMusicStream(c.music); c.has_audio = false }
	if !music_open(c, part_path(c, 0)) do return false
	c.music_base = 0
	return audio_clock_ok(c, local)
}

// ----- áudio sob demanda (janela móvel) -----
// worker: extrai CHUNK_SECS de áudio a partir de c.chunk_req (-ss antes do -i:
// seek de entrada, rápido mesmo fundo num vídeo de horas — fica pronto em ~1-2s)
chunk_worker :: proc(c: ^Clip) {
	base := c.chunk_req
	out := c.aud_ck[c.chunk_slot]
	cmd := []string{
		"ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
		"-ss", fmt.tprintf("%.2f", base), "-t", fmt.tprintf("%.0f", CHUNK_SECS), "-i", c.path,
		"-vn", "-c:a", "pcm_s16le", out,
	}
	ap, ape := os.process_start(os.Process_Desc{ command = cmd })
	if ape == nil {
		tame_process(c, ap, false) // sensível a latência: o usuário está esperando o som
		c.chunk_base = base     // antes do done: a main só lê depois do atomic
		if audio_extract_wait(c, ap) do intrinsics.atomic_store(&c.chunk_ok, true)
	}
	intrinsics.atomic_store(&c.chunk_done, true)
}

// (main) adota o chunk PRONTO se ele cobre `local` e a posição ainda não tem
// relógio. Separado da chegada (audio_load_ready): um chunk pré-buscado fica
// "no bolso" até o playback entrar na área — troca instantânea na borda, sem gap.
try_chunk_open :: proc(c: ^Clip, local: f32) -> bool {
	if audio_clock_ok(c, local) do return true
	if c.chunk_busy do return false // ainda extraindo
	if !intrinsics.atomic_load(&c.chunk_done) || !intrinsics.atomic_load(&c.chunk_ok) do return false
	if local < c.chunk_base || local >= c.chunk_base + CHUNK_SECS - 0.5 do return false
	if c.has_audio { rl.UnloadMusicStream(c.music); c.has_audio = false }
	if !music_open(c, c.aud_ck[c.chunk_slot]) do return false
	c.music_base = c.chunk_base
	c.music_slot = c.chunk_slot // este slot agora está preso pelo dr_wav
	return true
}

// (main) pede um chunk cobrindo `local`. Ignora se já há um worker no ar (quando
// ele terminar, se o playhead saiu da área, pede-se outro) ou se o chunk no bolso
// já cobre. Chame try_part_open/try_chunk_open antes.
chunk_request :: proc(c: ^Clip, local: f32) {
	if c.chunk_busy do return
	if intrinsics.atomic_load(&c.chunk_done) && intrinsics.atomic_load(&c.chunk_ok) &&
	   local >= c.chunk_base && local < c.chunk_base + CHUNK_SECS - 0.5 {
		return // já no bolso
	}
	if c.chunk_thr != nil { thread.join(c.chunk_thr); thread.destroy(c.chunk_thr); c.chunk_thr = nil }
	// NUNCA escreve no slot aberto em c.music: o ffmpeg (-y) trunca o arquivo na
	// hora, e tocar um WAV sendo regravado vira ruído/starvation (picote). A
	// alternância cega por paridade caía no slot ativo quando um chunk extraído
	// não era adotado (usuário adiantou de novo antes de ele ficar pronto).
	c.chunk_slot = c.music_slot >= 0 ? c.music_slot ~ 1 : c.chunk_slot ~ 1
	c.chunk_req = clamp(local - 1, 0, c.dur) // margem de 1s antes do pedido
	intrinsics.atomic_store(&c.chunk_done, false)
	intrinsics.atomic_store(&c.chunk_ok, false)
	c.chunk_busy = true
	c.chunk_thr = thread.create_and_start_with_poly_data(c, chunk_worker)
}

// abre um WAV como rl.Music do clipe, pausado no início; false se inválido
music_open :: proc(c: ^Clip, path: string) -> bool {
	c.music = rl.LoadMusicStream(strings.clone_to_cstring(path, context.temp_allocator))
	if c.music.frameCount == 0 do return false
	c.music_base = 0 // head/completo começam na origem; quem abre chunk sobrescreve
	c.music_slot = -1 // não é um slot de chunk; try_chunk_open sobrescreve ao abrir chunk
	c.music.looping = false
	rl.PlayMusicStream(c.music)
	rl.PauseMusicStream(c.music)
	c.has_audio = true
	return true
}

// carrega/atualiza o áudio dos clipes (main thread). Dois estágios: o head
// (30s) entra assim que fica pronto — som quase imediato em vídeos longos —
// e é trocado pelo WAV completo no fim, preservando posição e estado de play.
audio_load_ready :: proc() {
	for i in 0 ..< nclips {
		c := &clips[i]
		if c.closed do continue // slot removido (tombstone): recursos já liberados
		// chunk terminou de extrair: fica "no bolso" (adoção via try_chunk_open).
		// Se o playhead JÁ está na área e sem relógio (chegada no meio do mudo),
		// adota na hora — o playback re-adquire no frame seguinte.
		if c.chunk_busy && intrinsics.atomic_load(&c.chunk_done) {
			c.chunk_busy = false
			if a := seg_at(st.playhead); a >= 0 && segs[a].src == i {
				_ = try_chunk_open(c, seg_local(a, st.playhead))
			}
		}
		if !c.has_audio {
			// 1ª carga: WAV completo se já existe, senão o head
			if intrinsics.atomic_load(&c.parts_done) >= 1 {
				_ = music_open(c, part_path(c, 0)) // music_base = 0
			} else if intrinsics.atomic_load(&c.head_done) && intrinsics.atomic_load(&c.head_ok) {
				if !music_open(c, c.aud_head) do intrinsics.atomic_store(&c.head_ok, false)
			}
			continue
		}
		// troca PROATIVA head->completo assim que o WAV fica pronto (~12s após import):
		// feita cedo, quando o usuário nem começou a tocar, o gap da troca é inaudível
		// — e evita o gap acontecer no minuto 1 (fim do head) durante o playback.
		full_ready := intrinsics.atomic_load(&c.parts_done) >= 1
		is_head := c.music_base == 0 && f32(c.music.frameCount) / f32(c.music.stream.sampleRate) < c.dur - 0.5
		if full_ready && is_head && st.drag == .None {
			pos := play_clip >= 0 && segs[play_clip].src == i ? rl.GetMusicTimePlayed(c.music) : -1
			resume := st.playing && play_clip >= 0 && segs[play_clip].src == i
			rl.UnloadMusicStream(c.music); c.has_audio = false
			// fonte tocando como SECUNDÁRIO (mix): zera mix_on — o stream novo nasce pausado
			// em 0, e com mix_on=true o audio_secondary dava Resume ANTES de reposicionar
			// (blip do começo do arquivo). Com false, ele re-adquire na posição certa.
			c.mix_on = false
			if music_open(c, part_path(c, 0)) {
				if pos >= 0 { rl.SeekMusicStream(c.music, pos); if resume do rl.ResumeMusicStream(c.music) }
			}
		}
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
		if c.live_frame > 0 { upload_tex(c, rawptr(raw_data(c.fbuf))); c.tex_t = c.live_base + f32(c.live_frame) / DEC_FPS }
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
			if ci := intrinsics.atomic_load(&dup_req_c); ci >= 0 && ci < nclips {
				dup_open(&clips[ci], dup_req_t)
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
		// -threads 2 no decode por SOFTWARE: 2 cores bastam p/ 30fps a 360p; sem o teto,
		// vários clipes empilhados caindo p/ software (pressão NVDEC) disputavam TODOS
		// os cores entre si e com os workers — a sessão inteira ia degradando
		sw_cmd := []string{
			"ffmpeg", "-hide_banner", "-loglevel", "error", "-threads", "2",
			"-ss", ss, "-i", c.path,
			"-vf", vf, "-f", "rawvideo", "-pix_fmt", "rgb24", "-r", "30",
			"-an", "-sn", "pipe:1",
		}
		hw_cmd := []string{ // sem -resize (esticaria): letterbox pela CPU preserva o aspecto
			"ffmpeg", "-hide_banner", "-loglevel", "error",
			"-ss", ss, "-c:v", hw, "-i", c.path,
			"-vf", vf, "-f", "rawvideo", "-pix_fmt", "rgb24", "-r", "30",
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

// pede ao worker um decoder novo p/ a vista do seg si em `l` (1 spawn em voo por vez)
dup_request :: proc(si: int, l: f32) {
	if intrinsics.atomic_load(&dup_ready) do return      // spawn por adotar
	if intrinsics.atomic_load(&dup_req_c) >= 0 do return // spawn em voo
	dup_req_si = si
	dup_req_t = l
	dup_req_start = segs[si].start; dup_req_inoff = segs[si].in_off // identidade p/ validar na adoção
	intrinsics.atomic_store(&dup_req_c, segs[si].src) // publica por último (worker lê)
}

// lê 1 frame do decoder da vista p/ dup_rd_buf e sobe na textura (main)
dup_read :: proc(si: int) -> bool {
	d := &seg_dup[si]
	sf := cframe(seg_src(si)) // resolução da fonte (dup_rd_buf é max-sized)
	total := 0
	for total < sf {
		audio_pump() // leitura bloqueante do pipe: mantém o áudio alimentado
		n, e := os.read(d.lr, dup_rd_buf[total:sf])
		if n > 0 do total += n
		if n == 0 || e != nil do break
	}
	if total < sf { // fim do vídeo: registra e congela (não respawna em loop)
		end := d.lbase + f32(d.lframe) / DEC_FPS
		if d.leof <= 0 || end < d.leof do d.leof = max(end, 0.001)
		dup_live_stop(d)
		return false
	}
	d.lframe += 1
	dup_upload(si, rawptr(raw_data(dup_rd_buf)))
	d.has = d.lbase + f32(d.lframe - 1) / DEC_FPS
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
	cur := d.lbase + f32(d.lframe) / DEC_FPS
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
	for d.lbase + f32(d.lframe) / DEC_FPS < l && guard < 2 && g_read_budget > 0 {
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
		ok := si >= 0 && si < nsegs && seg_ready(si) && segs[si].src == intrinsics.atomic_load(&dup_req_c) &&
		      abs(segs[si].start - dup_req_start) < 0.001 && abs(segs[si].in_off - dup_req_inoff) < 0.001
		if dup_sp_on {
			if ok {
				d := &seg_dup[si]
				dup_live_stop(d) // por segurança (não deveria haver um vivo)
				d.lps = dup_sp_ps; d.lr = dup_sp_r; d.lon = true
				d.lbase = dup_req_t; d.lframe = 1
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
		intrinsics.atomic_store(&dup_ready, false) // por último: worker só reusa dup_buf depois daqui
	}
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
		// -threads 2 no decode por SOFTWARE: 2 cores bastam p/ 30fps a 360p; sem o teto,
		// vários clipes empilhados caindo p/ software (pressão NVDEC) disputavam TODOS
		// os cores entre si e com os workers — a sessão inteira ia degradando
		sw_cmd := []string{
			"ffmpeg", "-hide_banner", "-loglevel", "error", "-threads", "2",
			"-ss", ss, "-i", c.path,
			"-vf", vf, "-f", "rawvideo", "-pix_fmt", "rgb24", "-r", "30",
			"-an", "-sn", "pipe:1",
		}
		hw_cmd := []string{ // sem -resize (esticaria): letterbox pela CPU preserva o aspecto
			"ffmpeg", "-hide_banner", "-loglevel", "error",
			"-ss", ss, "-c:v", hw, "-i", c.path,
			"-vf", vf, "-f", "rawvideo", "-pix_fmt", "rgb24", "-r", "30",
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
			if upload { upload_tex(c, rawptr(raw_data(c.fbuf))); c.tex_t = c.live_base + f32(c.live_frame) / DEC_FPS }
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
		if c.live_on { upload_tex(c, rawptr(raw_data(c.fbuf))); c.tex_t = c.live_base + f32(c.live_frame) / DEC_FPS }
	}
}

// re-alimenta o buffer do áudio ativo no MEIO de operações bloqueantes da main
// thread (respawn do decoder ao vivo, leitura de frame): sem isso o stream
// esvazia durante um seek/salto e o som engasga. SÓ main thread (raylib audio).
audio_pump :: proc() {
	if play_clip >= 0 && seg_src(play_clip).has_audio do rl.UpdateMusicStream(seg_src(play_clip).music)
}

// lê um frame do decoder ao vivo para fbuf (sem GL). pump=true (só main thread)
// mantém o áudio alimentado entre as leituras bloqueantes do pipe.
stream_read_raw :: proc(c: ^Clip, pump := false) -> bool {
	if !c.live_on do return false
	sf := cframe(c) // bytes de 1 frame na resolução ATUAL do clipe (fbuf é max-sized)
	total := 0
	for total < sf {
		if pump do audio_pump()
		n, e := os.read(c.live_r, c.fbuf[total:sf])
		if n > 0 do total += n
		if n == 0 || e != nil do break
	}
	if total < sf { // o stream acabou: fim REAL do vídeo, OU o NVDEC desistiu no meio
		end := c.live_base + f32(c.live_frame) / DEC_FPS
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
	if c.eof_at > 0 && c.live_base + f32(c.live_frame) / DEC_FPS > c.eof_at do c.eof_at = 0
	return true
}

// lê um frame e sobe para a textura (main thread)
stream_read :: proc(c: ^Clip) -> bool {
	if !stream_read_raw(c, true) do return false
	upload_tex(c, rawptr(raw_data(c.fbuf)))
	c.tex_t = c.live_base + f32(c.live_frame) / DEC_FPS
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
	ndw, ndh := stream_dw(), stream_dh()
	intrinsics.atomic_store(&scrub_req_c, -1) // barra o worker de iniciar decode novo durante a troca
	intrinsics.atomic_store(&dup_req_c, -1)
	tmp: []u8
	for i in 0 ..< nclips {
		c := &clips[i]
		if c.closed || !c.streaming || !intrinsics.atomic_load(&c.probed) do continue
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
	for i in 0 ..< nsegs do if seg_dup[i].ok || seg_dup[i].lon do dup_release(i) // recriam na nova res
	set_toast(hi ? "Prévia streaming: Alta (720p)" : "Prévia streaming: Baixa (360p)")
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
		clip_show(c, int(l * cfps_of(c)))
		return
	}
	// respawn assíncrono no ar: o worker é o dono do live stream — congela o
	// frame atual até o novo decoder chegar (o áudio segue intocado)
	if intrinsics.atomic_load(&c.rsp_busy) {
		if !intrinsics.atomic_load(&c.rsp_done) do return
		intrinsics.atomic_store(&c.rsp_busy, false)
		if c.live_on { upload_tex(c, rawptr(raw_data(c.fbuf))); c.tex_t = c.live_base + f32(c.live_frame) / DEC_FPS } // 1º frame do novo decoder
		// se o alvo andou muito durante o respawn, o check de janela abaixo re-pede
	}
	if !c.live_on {
		// o stream já provou acabar antes de `l`: respawnar de novo só spawnaria
		// ffmpeg em loop (~3x/s) até o playhead passar — congela no último frame
		if c.eof_at > 0 && l >= c.eof_at - 0.05 do return
		stream_seek_async(c, l)
		return
	}
	cur := c.live_base + f32(c.live_frame) / DEC_FPS
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
	for c.live_base + f32(c.live_frame) / DEC_FPS < l && guard < 3 && g_read_budget > 0 {
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
	c.cache = nil; c.fbuf = nil; c.wave = nil; c.thumbs = nil; c.thumb_px = nil
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
	if intrinsics.atomic_load(&dup_req_c) == i do intrinsics.atomic_store(&dup_req_c, -1)
	if bin_drag == i { bin_drag = -1; if st.drag == .Bin do st.drag = .None }
	if bin_sel == i do bin_sel = -1
	bin_marked[i] = false // não deixa marca presa num tombstone
	if src_preview == i { src_preview = -1; st.playing = false } // saía da prévia dessa mídia
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

// ---------- timeline / navegação (opera sobre os segmentos colocados) ----------
seg_src :: proc(si: int) -> ^Clip { return &clips[segs[si].src] } // fonte do segmento
seg_ready :: proc(si: int) -> bool { return media_ready(segs[si].src) }

// o segmento conta como OBSTÁCULO nas checagens de colisão? Mídia ainda IMPORTANDO
// bloqueia (com seg_ready dava p/ soltar/mover/colar outro clipe em cima durante o
// import assíncrono — a sobreposição só aparecia quando o probe terminava, violando
// o invariante). Só mídia FALHA ou removida (tombstone) não bloqueia.
seg_blocks :: proc(si: int) -> bool {
	s := segs[si].src
	if s < 0 || s >= nclips do return false
	return !clips[s].closed && !intrinsics.atomic_load(&clips[s].failed)
}

// a mídia i tem pelo menos um segmento na timeline? (p/ o selo "na timeline" no bin)
src_placed :: proc(i: int) -> bool {
	for k in 0 ..< nsegs do if segs[k].src == i do return true
	return false
}

// cria um segmento (colocação na timeline) na trilha `track`. Retorna o índice, ou -1 se lotado.
add_seg :: proc(src: int, start, in_off, dur: f32, track := 0) -> int {
	if nsegs >= MAX_SEGS { set_toast("Máximo de segmentos na timeline"); return -1 }
	segs[nsegs] = Seg{ src = src, track = track, start = max(0, start), in_off = in_off, dur = dur, vol = 1, scale = 1, opacity = 1, speed = 1 }
	seg_marked[nsegs] = false // novo segmento nasce desmarcado
	nsegs += 1
	if src >= 0 && src < nclips do maybe_adopt_aspect(&clips[src]) // 1º vídeo na timeline define proj_ar
	return nsegs - 1
}

// volume efetivo do segmento em `t` (tempo absoluto da timeline): vol × mudo × envelope
// de fade in/out. Aplicado a cada frame no stream ativo via SetMusicVolume.
seg_gain :: proc(si: int, t: f32) -> f32 {
	if si < 0 || si >= nsegs do return 1
	sg := segs[si]
	if sg.muted || track_muted[sg.track] do return 0
	g := sg.vol
	p := t - sg.start // posição dentro do segmento (0..dur)
	if sg.fade_in  > 0.001 && p < sg.fade_in            do g *= clamp(p / sg.fade_in, 0, 1)
	if sg.fade_out > 0.001 && p > sg.dur - sg.fade_out  do g *= clamp((sg.dur - p) / sg.fade_out, 0, 1)
	return max(0, g)
}

// EFEITOS ocupam a trilha como um clipe: um fxseg na trilha `tr` cobre [start,dur)? (≠ mv; encostar não conta)
fx_hit :: proc(tr, mv: int, start, dur: f32) -> bool {
	for k in 0 ..< nfx {
		if k == mv || fxsegs[k].track != tr do continue
		if start < fxsegs[k].start + fxsegs[k].dur - 0.001 && start + dur > fxsegs[k].start + 0.001 do return true
	}
	return false
}
// colisão/paredes/encaixe do PRÓPRIO efeito (≠ mv): contra segs de vídeo E outros efeitos da trilha.
fx_busy :: proc(tr, mv: int, start, dur: f32) -> bool {
	for i in 0 ..< nsegs do if seg_blocks(i) && segs[i].track == tr && start < segs[i].start + segs[i].dur - 0.001 && start + dur > segs[i].start + 0.001 do return true
	return fx_hit(tr, mv, start, dur)
}
fx_wall_r :: proc(tr, mv: int, x: f32) -> f32 { // menor início > x (seg ou fx) — parede à direita
	w: f32 = 1e30
	for i in 0 ..< nsegs do if seg_blocks(i) && segs[i].track == tr && segs[i].start >= x - 0.001 && segs[i].start < w do w = segs[i].start
	for k in 0 ..< nfx do if k != mv && fxsegs[k].track == tr && fxsegs[k].start >= x - 0.001 && fxsegs[k].start < w do w = fxsegs[k].start
	return w
}
fx_free_start :: proc(tr, mv: int, proposed, dur: f32) -> f32 { // empurra p/ a direita até um vão livre
	s := max(0, proposed)
	for _ in 0 ..< nsegs + nfx + 1 {
		hit := f32(-1)
		for i in 0 ..< nsegs do if seg_blocks(i) && segs[i].track == tr && s < segs[i].start+segs[i].dur-0.001 && s+dur > segs[i].start+0.001 { hit = segs[i].start+segs[i].dur; break }
		if hit < 0 do for k in 0 ..< nfx do if k != mv && fxsegs[k].track == tr && s < fxsegs[k].start+fxsegs[k].dur-0.001 && s+dur > fxsegs[k].start+0.001 { hit = fxsegs[k].start+fxsegs[k].dur; break }
		if hit < 0 do break
		s = hit
	}
	return s
}

// invasão/paredes/encaixe são POR TRILHA: segmentos só conflitam com os da MESMA trilha.
// [start, start+dur) invade outro segmento da trilha `tr`? (encostar não conta) — efeitos incluídos
overlaps_any :: proc(tr, moving: int, start, dur: f32) -> bool {
	for i in 0 ..< nsegs {
		if i == moving || !seg_blocks(i) || segs[i].track != tr do continue
		if start < segs[i].start + segs[i].dur - 0.001 && start + dur > segs[i].start + 0.001 do return true
	}
	return fx_hit(tr, -1, start, dur) // vídeo não invade um efeito
}

// seleção múltipla de segmentos: contagem, limpeza, e invasão ignorando TODOS os marcados
seg_marks_count :: proc() -> int { n := 0; for k in 0 ..< nsegs do if seg_marked[k] do n += 1; return n }
seg_clear_marks :: proc() { for k in 0 ..< MAX_SEGS do seg_marked[k] = false }
// [start,start+dur) na trilha tr invade algum segmento NÃO-marcado? (p/ mover o grupo)
overlaps_nonmarked :: proc(tr: int, start, dur: f32) -> bool {
	for i in 0 ..< nsegs {
		// um marcado em trilha TRAVADA não vai se mover — conta como obstáculo (senão
		// o grupo aterrissava em cima dele: sobreposição real na mesma trilha)
		if (seg_marked[i] && !track_locked[segs[i].track]) || !seg_blocks(i) || segs[i].track != tr do continue
		if start < segs[i].start + segs[i].dur - 0.001 && start + dur > segs[i].start + 0.001 do return true
	}
	return fx_hit(tr, -1, start, dur)
}

// fim do vizinho imediatamente à esquerda de x na trilha `tr` (0 se nenhum) — inclui efeitos.
left_wall :: proc(tr, moving: int, x: f32) -> f32 {
	w: f32 = 0
	for i in 0 ..< nsegs {
		if i == moving || !seg_blocks(i) || segs[i].track != tr do continue
		e := segs[i].start + segs[i].dur
		if e <= x + 0.001 && e > w do w = e
	}
	for k in 0 ..< nfx do if fxsegs[k].track == tr { e := fxsegs[k].start + fxsegs[k].dur; if e <= x + 0.001 && e > w do w = e }
	return w
}

// início do vizinho imediatamente à direita de x na trilha `tr` (+inf se nenhum) — inclui efeitos.
right_wall :: proc(tr, moving: int, x: f32) -> f32 {
	w: f32 = 1e30
	for i in 0 ..< nsegs {
		if i == moving || !seg_blocks(i) || segs[i].track != tr do continue
		if segs[i].start >= x - 0.001 && segs[i].start < w do w = segs[i].start
	}
	for k in 0 ..< nfx do if fxsegs[k].track == tr && fxsegs[k].start >= x - 0.001 && fxsegs[k].start < w do w = fxsegs[k].start
	return w
}

// posição livre >= proposed p/ um clipe de `dur` na trilha `tr`: empurra p/ a direita enquanto invadir
// (segmentos E efeitos — o vídeo não pode cair em cima de um efeito)
free_start :: proc(tr, moving: int, proposed, dur: f32) -> f32 {
	s := max(0, proposed)
	for _ in 0 ..< nsegs + nfx + 1 {
		hit := f32(-1)
		for i in 0 ..< nsegs {
			if i == moving || !seg_blocks(i) || segs[i].track != tr do continue
			if s < segs[i].start + segs[i].dur - 0.001 && s + dur > segs[i].start + 0.001 { hit = segs[i].start + segs[i].dur; break }
		}
		if hit < 0 do for k in 0 ..< nfx do if fxsegs[k].track == tr && s < fxsegs[k].start+fxsegs[k].dur-0.001 && s+dur > fxsegs[k].start+0.001 { hit = fxsegs[k].start + fxsegs[k].dur; break }
		if hit < 0 do break
		s = hit // vai pro fim do que invadiu
	}
	return s
}

timeline_dur :: proc() -> f32 {
	d: f32 = 0
	for i in 0 ..< nsegs {
		if seg_ready(i) do d = max(d, segs[i].start + segs[i].dur)
	}
	return d
}

// ---------- modo ASSERT de invariantes (debug) ----------
// Valida 1x por frame as regras estruturais que o resto do código ASSUME (mantidas
// por mover/aparar/cortar/colar/remover): corrupção silenciosa vira crash com dump
// da timeline e mensagem NA HORA em que acontece, não 20 features depois. Liga com
// -define:INVARIANTS=true (o build -debug já vem ligado); no release a chamada
// desaparece via @(disabled). Custo: O(nsegs²) com nsegs<=64 — desprezível.
INVARIANTS :: #config(INVARIANTS, ODIN_DEBUG)

inv_bad :: proc(v: f32) -> bool { return v != v || abs(v) > 1e18 } // NaN ou ±inf

inv_fail :: proc(msg: string, args: ..any) -> ! {
	fmt.eprintfln("---- INVARIANTE VIOLADA ----")
	fmt.eprintfln("nsegs=%d nclips=%d nfx=%d g_nv=%d g_na=%d playhead=%.3f playing=%v play_clip=%d selected=%d drag_clip=%d drag=%v",
		nsegs, nclips, nfx, g_nv, g_na, st.playhead, st.playing, play_clip, selected, drag_clip, st.drag)
	for i in 0 ..< nsegs {
		s := segs[i]
		fmt.eprintfln("  seg %d: src=%d track=%d start=%.3f dur=%.3f in_off=%.3f speed=%.2f vol=%.2f aonly=%v ready=%v",
			i, s.src, s.track, s.start, s.dur, s.in_off, s.speed, s.vol, s.aonly,
			s.src >= 0 && s.src < nclips && seg_ready(i))
	}
	for k in 0 ..< nfx {
		f := fxsegs[k]
		fmt.eprintfln("  fx %d: kind=%d track=%d start=%.3f dur=%.3f", k, f.kind, f.track, f.start, f.dur)
	}
	fmt.panicf(msg, ..args)
}

@(disabled=!INVARIANTS)
check_invariants :: proc() {
	// contadores e índices globais dentro das faixas
	if nsegs < 0 || nsegs > MAX_SEGS do inv_fail("nsegs fora da faixa: %d", nsegs)
	if nclips < 0 || nclips > MAX_CLIPS do inv_fail("nclips fora da faixa: %d", nclips)
	if nfx < 0 || nfx > MAX_FX do inv_fail("nfx fora da faixa: %d", nfx)
	if seg_clipbrd_n < 0 || seg_clipbrd_n > MAX_SEGS do inv_fail("clipboard fora da faixa: %d", seg_clipbrd_n)
	if g_nv < 1 || g_nv > MAXV do inv_fail("g_nv fora da faixa: %d", g_nv)
	if g_na < 1 || g_na > MAXA do inv_fail("g_na fora da faixa: %d", g_na)
	if inv_bad(st.playhead) || st.playhead < -0.001 do inv_fail("playhead inválido: %v", st.playhead)
	if selected < -1 || selected >= nsegs do inv_fail("selected fora da faixa: %d (nsegs=%d)", selected, nsegs)
	if drag_clip < -1 || drag_clip >= nsegs do inv_fail("drag_clip fora da faixa: %d (nsegs=%d)", drag_clip, nsegs)
	if sel_trans < -1 || sel_trans >= nsegs do inv_fail("sel_trans fora da faixa: %d (nsegs=%d)", sel_trans, nsegs)
	if play_clip < -1 || play_clip >= nsegs do inv_fail("play_clip fora da faixa: %d (nsegs=%d)", play_clip, nsegs)
	if bin_sel < -1 || bin_sel >= nclips do inv_fail("bin_sel fora da faixa: %d (nclips=%d)", bin_sel, nclips)
	if src_preview < -1 || src_preview >= nclips do inv_fail("src_preview fora da faixa: %d (nclips=%d)", src_preview, nclips)
	// o relógio-mestre precisa de fonte pronta e com áudio
	if play_clip >= 0 {
		if !seg_ready(play_clip) do inv_fail("play_clip %d com fonte não-pronta", play_clip)
		if !seg_src(play_clip).has_audio do inv_fail("play_clip %d é o relógio mas a fonte não tem áudio", play_clip)
	}
	for i in 0 ..< nsegs {
		s := segs[i]
		if s.src < 0 || s.src >= nclips do inv_fail("seg %d: src %d fora da faixa (nclips=%d)", i, s.src, nclips)
		if clips[s.src].closed do inv_fail("seg %d aponta p/ mídia removida (tombstone %d)", i, s.src)
		if inv_bad(s.start) || inv_bad(s.dur) || inv_bad(s.in_off) || inv_bad(s.speed) || inv_bad(s.vol) || inv_bad(s.fade_in) || inv_bad(s.fade_out) {
			inv_fail("seg %d com NaN/inf (start=%v dur=%v in_off=%v speed=%v)", i, s.start, s.dur, s.in_off, s.speed)
		}
		if s.start < -0.001 do inv_fail("seg %d: start negativo %.3f", i, s.start)
		if s.dur <= 0.01 do inv_fail("seg %d: dur %.4f (vazio/negativo)", i, s.dur)
		if s.in_off < -0.001 do inv_fail("seg %d: in_off negativo %.3f", i, s.in_off)
		if s.speed < 0 do inv_fail("seg %d: speed negativa %.3f", i, s.speed)
		if s.track < 0 || s.track >= MAXTRACKS do inv_fail("seg %d: trilha %d fora da faixa", i, s.track)
		// áudio (mídia só-áudio ou áudio separado) vive nas trilhas de áudio; vídeo nas de vídeo
		al := clips[s.src].is_audio || s.aonly
		if al && !is_audio_track(s.track) do inv_fail("seg %d é áudio mas está na trilha de vídeo %d", i, s.track)
		if !al && is_audio_track(s.track) do inv_fail("seg %d é vídeo mas está na trilha de áudio %d", i, s.track)
		// o trecho recortado cabe na fonte (imagem/texto esticam livre — sem fim real)
		if !clips[s.src].is_img && !clips[s.src].is_text && media_ready(s.src) && seg_src_out(i) > clips[s.src].dur + 0.05 {
			inv_fail("seg %d consome além do fim da fonte: out=%.3f > dur=%.3f", i, seg_src_out(i), clips[s.src].dur)
		}
	}
	// segmentos de uma mesma trilha NUNCA se sobrepõem (invariante do mover/aparar/colar/drop)
	for i in 0 ..< nsegs do for j in i + 1 ..< nsegs {
		if segs[i].track != segs[j].track do continue
		ov := min(segs[i].start + segs[i].dur, segs[j].start + segs[j].dur) - max(segs[i].start, segs[j].start)
		if ov > 0.005 do inv_fail("segs %d e %d sobrepõem %.3fs na trilha %d", i, j, ov, segs[i].track)
	}
	// efeitos: trilha de vídeo válida e exclusividade de espaço (fx×fx e fx×seg)
	for k in 0 ..< nfx {
		f := fxsegs[k]
		if inv_bad(f.start) || inv_bad(f.dur) do inv_fail("fx %d com NaN/inf", k)
		if f.dur <= 0.01 do inv_fail("fx %d: dur %.4f", k, f.dur)
		if f.track < 0 || f.track >= MAXV do inv_fail("fx %d: trilha %d fora da faixa de vídeo", k, f.track)
		for j in k + 1 ..< nfx {
			if fxsegs[j].track != f.track do continue
			ov := min(f.start + f.dur, fxsegs[j].start + fxsegs[j].dur) - max(f.start, fxsegs[j].start)
			if ov > 0.005 do inv_fail("efeitos %d e %d sobrepõem %.3fs na trilha %d", k, j, ov, f.track)
		}
		for i in 0 ..< nsegs {
			if segs[i].track != f.track do continue
			ov := min(f.start + f.dur, segs[i].start + segs[i].dur) - max(f.start, segs[i].start)
			if ov > 0.005 do inv_fail("efeito %d sobrepõe o seg %d em %.3fs na trilha %d", k, i, ov, f.track)
		}
	}
}

// ---- copiar/colar segmentos (Ctrl+C/X/V/D) ----
// a área de transferência guarda VALORES de Seg (struct puro, sem recursos):
// sobrevive a remoção/undo e traz junto transform/volume/fades/velocidade/efeitos.
// `start` fica absoluto; o colar desloca o CONJUNTO p/ o destino (posições
// relativas preservadas). A mídia-fonte é validada na hora de colar.
seg_clipbrd:   [MAX_SEGS]Seg
seg_clipbrd_n: int

// copia o grupo marcado (se houver) ou o segmento selecionado; retorna quantos
copy_segs :: proc() -> int {
	n := 0
	if seg_marks_count() > 1 {
		for i in 0 ..< nsegs do if seg_marked[i] && seg_ready(i) { seg_clipbrd[n] = segs[i]; n += 1 }
	} else if selected >= 0 && selected < nsegs && seg_ready(selected) {
		seg_clipbrd[0] = segs[selected]
		n = 1
	}
	if n > 0 {
		seg_clipbrd_n = n
		if n == 1 do set_toast("Clipe copiado — Ctrl+V cola no playhead")
		else do set_toast(rl.TextFormat("%d clipes copiados — Ctrl+V cola no playhead", n))
	} else {
		set_toast("Selecione um clipe na timeline p/ copiar")
	}
	return n
}

// cola a área de transferência com o início do conjunto em `at` (cada clipe na
// sua trilha de origem; empurrado p/ a direita se invadir — nunca sobrepõe)
paste_segs :: proc(at: f32) {
	if seg_clipbrd_n == 0 { set_toast("Nada copiado ainda — Ctrl+C copia o clipe selecionado"); return }
	base := f32(1e30)
	for k in 0 ..< seg_clipbrd_n do base = min(base, seg_clipbrd[k].start)
	delta := at - base
	first := -1; pasted := 0; dead := 0; locked := 0
	for k in 0 ..< seg_clipbrd_n {
		it := seg_clipbrd[k]
		// a mídia-fonte pode ter sido removida do bin depois do copiar
		if it.src < 0 || it.src >= nclips || clips[it.src].closed || intrinsics.atomic_load(&clips[it.src].failed) { dead += 1; continue }
		if track_locked[it.track] { locked += 1; continue }
		ni := add_seg(it.src, 0, it.in_off, it.dur, it.track)
		if ni < 0 do break // timeline lotada (add_seg já avisou)
		s := it
		s.start = free_start(it.track, ni, max(0, it.start + delta), it.dur)
		segs[ni] = s
		if first < 0 do first = ni
		pasted += 1
	}
	if pasted > 0 {
		seg_clear_marks()
		if pasted > 1 do for i in first ..< nsegs do seg_marked[i] = true // grupo colado já sai marcado (move junto)
		selected = first; sel_trans = -1; bin_sel = -1
		if pasted == 1 do set_toast("Clipe colado")
		else do set_toast(rl.TextFormat("%d clipes colados", pasted))
	} else if dead > 0 {
		set_toast("A mídia copiada foi removida do editor")
	} else if locked > 0 {
		set_toast("Trilha bloqueada")
	}
}

// recorta (copia + remove). Deixa o vão (sem ripple): recortar p/ colar em outro
// lugar não deve deslizar o resto da trilha.
cut_segs :: proc() {
	n := copy_segs()
	if n == 0 do return
	if seg_marks_count() > 1 {
		// só remove o que FOI copiado (seg_ready): um marcado com mídia ainda carregando
		// não entra no clipboard — removê-lo seria perdê-lo (não voltaria no Ctrl+V)
		for k := nsegs - 1; k >= 0; k -= 1 do if seg_marked[k] && seg_ready(k) do remove_seg(k, false)
		seg_clear_marks(); selected = -1
	} else if selected >= 0 && seg_ready(selected) {
		remove_seg(selected, false)
	}
	if n == 1 do set_toast("Clipe recortado — Ctrl+V cola no playhead")
	else do set_toast(rl.TextFormat("%d clipes recortados — Ctrl+V cola no playhead", n))
}

// duplica o selecionado (ou grupo) logo após o fim do conjunto, na mesma trilha
duplicate_segs :: proc() {
	if copy_segs() == 0 do return
	e := f32(0)
	for k in 0 ..< seg_clipbrd_n do e = max(e, seg_clipbrd[k].start + seg_clipbrd[k].dur)
	paste_segs(e)
}

// segmento que se comporta como ÁUDIO: mídia só-áudio (mp3/wav) OU áudio separado
// do vídeo (aonly). Preview/transform/efeitos/transições ignoram esses segmentos.
seg_audio_like :: proc(si: int) -> bool {
	return si >= 0 && si < nsegs && (seg_src(si).is_audio || segs[si].aonly)
}

// SEPARAR ÁUDIO (estilo NLE): cria um segmento só-áudio (aonly) numa trilha de
// áudio livre, em sincronia com o vídeo (mesmo start/in_off/dur/speed), move os
// fades/volume de áudio p/ ele e SILENCIA o vídeo original. Desfazível (só segs).
detach_audio :: proc(si: int) {
	if si < 0 || si >= nsegs || !seg_ready(si) do return
	sg := segs[si]
	c := seg_src(si)
	if sg.aonly || c.is_audio { set_toast("Este clipe já é só áudio"); return }
	if !c.has_audio { set_toast("Este clipe não tem áudio"); return }
	tr := -1
	for t in MAXV ..< MAXV + g_na { // 1ª trilha de áudio com espaço livre no trecho
		if track_locked[t] do continue
		if !overlaps_any(t, -1, sg.start, sg.dur) { tr = t; break }
	}
	if tr < 0 do tr = add_audio_track() // nenhuma livre: cria uma nova trilha de áudio embaixo
	if tr < 0 { set_toast("Sem espaço livre nas trilhas de áudio"); return }
	ni := add_seg(sg.src, sg.start, sg.in_off, sg.dur, tr)
	if ni < 0 do return
	na := &segs[ni]
	na.aonly = true
	na.vol = sg.vol; na.fade_in = sg.fade_in; na.fade_out = sg.fade_out
	na.speed = sg.speed <= 0 ? 1 : sg.speed
	segs[si].muted = true // o som agora vem do segmento separado
	segs[si].fade_in = 0; segs[si].fade_out = 0
	seg_clear_marks()
	selected = ni; sel_trans = -1; bin_sel = -1
	set_toast(rl.TextFormat("Áudio separado p/ a trilha A%d", tr - MAXV + 1))
}

segs_ready :: proc() -> int {
	n := 0
	for i in 0 ..< nsegs do if seg_ready(i) do n += 1
	return n
}

// tira UM segmento da timeline (a mídia continua no bin). Compacta o array, então
// conserta os índices globais que apontam para segmentos (deslocam ao remover).
// ripple=true (padrão) fecha o buraco; false deixa o vão (segurar Alt ao remover)
remove_seg :: proc(si: int, ripple := true) {
	if si < 0 || si >= nsegs do return
	src := seg_src(si)
	if src.has_audio do rl.PauseMusicStream(src.music)
	name := src.name
	rs := segs[si].start // início e duração do removido, p/ o ripple
	rd := segs[si].dur
	rt := segs[si].track // ripple só desloca a MESMA trilha
	for k := si; k < nsegs - 1; k += 1 { segs[k] = segs[k + 1]; seg_marked[k] = seg_marked[k + 1] }
	seg_marked[nsegs - 1] = false // limpa o slot que sobra após a compactação
	nsegs -= 1
	fix :: proc(idx: ^int, removed: int) {
		if idx^ == removed do idx^ = -1
		else if idx^ > removed do idx^ -= 1
	}
	fix(&play_clip, si); fix(&selected, si); fix(&drag_clip, si); fix(&sel_trans, si)
	if ripple {
		// fecha o buraco — tudo à direita do removido NA MESMA TRILHA desliza `rd` p/ a esquerda
		for k in 0 ..< nsegs do if segs[k].track == rt && segs[k].start > rs + 0.001 do segs[k].start -= rd
		// os clipes de EFEITO da trilha deslizam junto — senão um segmento escorregava
		// p/ cima de um efeito (sobreposição que nenhum arrasto permite criar)
		for k in 0 ..< nfx do if fxsegs[k].track == rt && fxsegs[k].start > rs + 0.001 do fxsegs[k].start -= rd
		// leva o playhead junto p/ ele ficar sobre o mesmo conteúdo de antes
		if st.playhead >= rs + rd do st.playhead -= rd
		else if st.playhead > rs do st.playhead = rs
	}
	st.playing = false
	seek_global(st.playhead)
	set_toast(rl.TextFormat(ripple ? "%s removido" : "%s removido (deixou vão)", cs(name)))
}

alt_down :: proc() -> bool { return rl.IsKeyDown(.LEFT_ALT) || rl.IsKeyDown(.RIGHT_ALT) }

// divide o segmento `a` no tempo `t` (absoluto da timeline). true = cortou.
// a esquerda encurta até o corte; a direita vira um novo segmento da mesma fonte.
split_seg_at :: proc(a: int, t: f32) -> bool {
	if a < 0 || a >= nsegs do return false
	off := t - segs[a].start // ponto do corte, relativo ao início do segmento
	if off <= 0.05 || off >= segs[a].dur - 0.05 { set_toast("Muito perto da borda para dividir"); return false }
	// a fonte consumida pela metade esquerda é off*speed (off é tempo de timeline)
	ri := add_seg(segs[a].src, t, segs[a].in_off + off * seg_speed(a), segs[a].dur - off, segs[a].track)
	if ri < 0 do return false
	// as duas metades herdam volume/mudo; o fade-in fica na esquerda, o fade-out na
	// direita — a borda do corte (interna) não ganha fade
	segs[ri].vol = segs[a].vol; segs[ri].muted = segs[a].muted
	segs[ri].fade_in = 0; segs[ri].fade_out = segs[a].fade_out
	segs[ri].scale = segs[a].scale; segs[ri].px = segs[a].px; segs[ri].py = segs[a].py // transform herdado
	segs[ri].rot = segs[a].rot; segs[ri].opacity = segs[a].opacity; segs[ri].speed = segs[a].speed
		segs[ri].crop_x = segs[a].crop_x; segs[ri].crop_y = segs[a].crop_y // RECORTE herdado pelas 2 metades
		segs[ri].crop_w = segs[a].crop_w; segs[ri].crop_h = segs[a].crop_h // (senão a direita perdia o recorte)
		segs[ri].crop2_x = segs[a].crop2_x; segs[ri].crop2_y = segs[a].crop2_y // ZOOM ANIMADO herdado
		segs[ri].crop2_w = segs[a].crop2_w; segs[ri].crop2_h = segs[a].crop2_h
		segs[ri].zoom_anim = segs[a].zoom_anim
		if segs[a].zoom_anim { // remapeia p/ o movimento continuar CONTÍNUO no corte
			cx, cy, cw, ch := seg_crop_at(a, t) // região exatamente no ponto do corte
			segs[a].crop2_x = cx; segs[a].crop2_y = cy; segs[a].crop2_w = cw; segs[a].crop2_h = ch // esq termina aqui
			segs[ri].crop_x = cx; segs[ri].crop_y = cy; segs[ri].crop_w = cw; segs[ri].crop_h = ch // dir começa aqui
		}
		segs[ri].vfin = 0; segs[ri].vfout = segs[a].vfout // fade preto: entrada esq, saída dir
		// SÓ-ÁUDIO herdado: sem isto, dividir um "áudio separado" criava um segmento de
		// VÍDEO numa trilha de áudio (violava o invariante e cobria o preview inteiro)
		segs[ri].aonly = segs[a].aonly
		// efeitos por segmento herdados pelas 2 metades (cor, vinheta, bulge/wobble) —
		// senão a metade direita perdia a correção de cor/distorção no corte
		segs[ri].bulge = segs[a].bulge; segs[ri].bulge_x = segs[a].bulge_x
		segs[ri].bulge_y = segs[a].bulge_y; segs[ri].bulge_r = segs[a].bulge_r
		segs[ri].wobble = segs[a].wobble; segs[ri].wobble_speed = segs[a].wobble_speed
		segs[ri].fx_bright = segs[a].fx_bright; segs[ri].fx_contrast = segs[a].fx_contrast
		segs[ri].fx_satur = segs[a].fx_satur; segs[ri].fx_look = segs[a].fx_look
		segs[ri].fx_vignette = segs[a].fx_vignette; segs[ri].fx_temp = segs[a].fx_temp
	segs[a].dur = off
	segs[a].fade_out = 0; segs[a].vfout = 0 // o fade preto de saída foi p/ a metade da direita
	return true
}

// divide TODOS os clipes que cruzam o playhead, em todas as trilhas (como qualquer NLE),
// pulando trilhas bloqueadas. (atalho: S). split_seg_at acrescenta a metade direita no fim do
// array, então iterar sobre o count ORIGINAL evita re-dividir os novos pedaços.
split_at_playhead :: proc() {
	n := 0
	orig := nsegs
	for i in 0 ..< orig {
		if !seg_ready(i) || track_locked[segs[i].track] do continue
		if st.playhead > segs[i].start + 0.05 && st.playhead < segs[i].start + segs[i].dur - 0.05 {
			if split_seg_at(i, st.playhead) do n += 1
		}
	}
	if n == 0 { set_toast("Nada sob o playhead para dividir"); return }
	bin_sel = -1
	set_toast(n == 1 ? "Clipe dividido" : rl.TextFormat("%d clipes divididos", n))
}

// encaixa o início do segmento nas bordas de outros segmentos DA MESMA TRILHA / início / playhead.
// moving = índice do segmento sendo movido (-1 quando é um item novo do bin).
snap_start :: proc(tr, moving: int, proposed: f32, dur: f32) -> f32 {
	thr := SNAP_PX / pps()
	result := proposed
	bestd := thr
	pts: [2 * MAX_SEGS + 2]f32
	n := 0
	pts[n] = 0; n += 1
	pts[n] = st.playhead; n += 1
	// bordas de TODOS os clipes (qualquer trilha) — guia de alinhamento entre trilhas ao arrastar
	for i in 0 ..< nsegs {
		if i == moving || !seg_blocks(i) do continue // importando também encaixa (é obstáculo)
		pts[n] = segs[i].start; n += 1
		pts[n] = segs[i].start + segs[i].dur; n += 1
	}
	for k in 0 ..< n {
		p := pts[k]
		if d := math.abs(proposed - p);         d < bestd { bestd = d; result = p;       snap_line = p }
		if d := math.abs(proposed + dur - p);   d < bestd { bestd = d; result = p - dur; snap_line = p }
	}
	return max(0, result)
}

// segmento de VÍDEO de topo que contém t (-1 se nenhum) — vence no preview e nos cliques.
// Ignora clipes só-áudio (não têm imagem); trilhas de áudio nunca aparecem no preview.
seg_at :: proc(t: f32) -> int {
	best := -1
	for i in 0 ..< nsegs {
		if !seg_ready(i) || seg_src(i).is_audio || segs[i].aonly || t < segs[i].start || t >= segs[i].start + segs[i].dur do continue
		if best < 0 || segs[i].track > segs[best].track do best = i
	}
	return best
}

// segmento que dá o RELÓGIO de áudio (master) em t: prefere áudio de trilha de VÍDEO
// (o "principal"); só cai numa trilha de áudio se não houver áudio de vídeo na região.
// Assim a música (trilha de áudio) toca como SECUNDÁRIO (mix) sem roubar o relógio.
audio_seg_at :: proc(t: f32) -> int {
	best := -1
	for i in 0 ..< nsegs {
		if !seg_ready(i) || t < segs[i].start || t >= segs[i].start + segs[i].dur do continue
		if !seg_src(i).has_audio || segs[i].muted || track_muted[segs[i].track] do continue
		if is_audio_track(segs[i].track) do continue // trilha de áudio = secundário, não master
		if best < 0 || segs[i].track > segs[best].track do best = i
	}
	if best >= 0 do return best
	// nenhum áudio de vídeo: aí sim uma trilha de áudio vira o relógio (timeline só-música)
	for i in 0 ..< nsegs {
		if !seg_ready(i) || t < segs[i].start || t >= segs[i].start + segs[i].dur do continue
		if !seg_src(i).has_audio || segs[i].muted || track_muted[segs[i].track] || !is_audio_track(segs[i].track) do continue
		if best < 0 || segs[i].track > segs[best].track do best = i
	}
	return best
}

// segmento na trilha `t` que contém o tempo `time` (-1 se nenhum)
seg_on_track_at :: proc(t: int, time: f32) -> int {
	for i in 0 ..< nsegs {
		if seg_ready(i) && segs[i].track == t && time >= segs[i].start && time < segs[i].start + segs[i].dur do return i
	}
	return -1
}

// clipe de SAÍDA de uma transição do segmento bi = o adjacente que termina onde bi começa
// (mesma trilha). -1 se bi começa "solto" (sem clipe encostado à esquerda) -> sem transição.
trans_prev :: proc(bi: int) -> int {
	if bi < 0 || bi >= nsegs do return -1
	for i in 0 ..< nsegs {
		if i == bi || !seg_ready(i) || segs[i].track != segs[bi].track do continue
		if math.abs((segs[i].start + segs[i].dur) - segs[bi].start) < 0.02 do return i // A termina onde B começa
	}
	return -1
}

// duração máxima de transição p/ o segmento bi (modelo CENTRADO no corte: metade `D/2`
// em cada clipe). NÃO exige mais handle (folga na fonte): quando um lado não tem footage
// além da borda, o preview/export CONGELAM o frame da borda durante a mistura (o efeito se
// vira sozinho). Limitado só pela duração dos 2 clipes e um teto de 1.5s por lado (D=3s).
trans_max :: proc(bi: int) -> f32 {
	a := trans_prev(bi)
	if a < 0 do return 0
	if seg_speed(a) != 1 || seg_speed(bi) != 1 do return 0 // v1: dissolver não combina com velocidade alterada
	half := min(segs[a].dur, segs[bi].dur, f32(1.5)) // teto de 1.5s por lado; cabe no clipe mais curto
	return max(0, half * 2)
}
// transição válida do segmento bi (clampada). 0 se speed!=1 (v1 não combina os dois).
seg_trans :: proc(bi: int) -> f32 {
	if segs[bi].trans <= 0.001 || seg_speed(bi) != 1 do return 0
	return clamp(segs[bi].trans, 0, trans_max(bi))
}

// explica POR QUE o dissolver foi recusado no corte de bi (só sobra motivo estrutural agora
// que a folga deixou de ser exigida: sem clipe adjacente, velocidade alterada, ou dur zero).
trans_deny_toast :: proc(bi: int) {
	a := trans_prev(bi)
	if a < 0 { set_toast("Encoste este clipe em outro na mesma trilha p/ dissolver"); return }
	if seg_speed(a) != 1 || seg_speed(bi) != 1 { set_toast("Dissolver não combina com velocidade alterada"); return }
	set_toast("Clipes muito curtos p/ dissolver")
}

// atualiza a textura de CADA trilha de vídeo sob o playhead (compositing multi-trilha):
// cada fonte decodifica seu frame; draw_preview desenha todas com seus transforms.
show_playhead_frame :: proc() {
	pt := prof_beg(.Video); defer prof_end(.Video, pt)
	for t in 0 ..< g_nv {
		if track_hidden[t] do continue // trilha oculta: não decodifica (não aparece)
		// transição centrada no corte: decodifica AMBOS os clipes no seu tempo de fonte
		// (o que SAI passa do out-point = pós-roll; o que ENTRA fica antes de in_off =
		// pré-roll). Quando não há footage sobrando, o clamp CONGELA o frame da borda —
		// o efeito funciona sem exigir aparo. Instantâneo p/ cache; streaming é aproximado.
		tb := trans_overlap(t, st.playhead)
		if tb >= 0 {
			a := trans_prev(tb)
			frz :: proc(c: ^Clip, sec: f32) { clip_frame(c, clamp(sec, 0, max(0, c.dur - 1.0/cfps_of(c)))) }
			// STREAMING também decodifica (clip_frame lida com respawn/EOF): o que ENTRA
			// respawna no início do overlap, quando a camada dele ainda é transparente —
			// o hitch fica invisível e ele chega pronto no fim (antes congelava um frame
			// velho durante o crossfade e ainda respawnava DEPOIS da transição).
			// Guardas de textura (1 textura não serve 2 tempos — era o pisca):
			//  - mesma fonte nos 2 lados (dissolve num corte interno): só o que ENTRA
			//    decodifica; num corte contíguo os tempos são idênticos, sem perda.
			//  - fonte de trilha mais BAIXA sob o playhead (seg_is_dup): o dono decide.
			if a >= 0 && segs[a].src != segs[tb].src && !seg_is_dup(a) {
				frz(seg_src(a), segs[a].in_off + (st.playhead - segs[a].start))
			}
			if !seg_is_dup(tb) do frz(seg_src(tb), segs[tb].in_off + (st.playhead - segs[tb].start))
		} else {
			i := seg_on_track_at(t, st.playhead)
			if i >= 0 {
				// mesma fonte já decodificando numa trilha mais baixa: este seg usa a
				// vista dup (textura própria) — 1 clipe não serve 2 tempos ao mesmo tempo
				if seg_is_dup(i) do dup_frame(i, seg_local(i, st.playhead))
				else do clip_frame(seg_src(i), seg_local(i, st.playhead))
			}
		}
	}
}

// linha (de cima p/ baixo) do lane da trilha `t`, contando só as VISÍVEIS: vídeo em cima
// (V-topo..V1, invertido), áudio embaixo (A1..A_n). Vídeo t ocupa a linha (g_nv-1-t); áudio
// (índice MAXV+a) ocupa a linha (g_nv+a).
track_row :: proc(t: int) -> int { return t < MAXV ? (g_nv - 1 - t) : (g_nv + (t - MAXV)) }
track_y :: proc(t: int) -> f32 { return g_lanes_top + f32(track_row(t)) * (g_track_h + g_track_gap) }
// trilha sob a coordenada y (usado no drop/arraste vertical)
track_at_y :: proc(y: f32) -> int {
	nrows := g_nv + g_na
	row := clamp(int((y - g_lanes_top) / (g_track_h + g_track_gap)), 0, nrows - 1) // 0 = topo
	return row < g_nv ? (g_nv - 1 - row) : (MAXV + (row - g_nv)) // vídeo: inverte; áudio: base MAXV
}
// ajusta a trilha alvo ao TIPO da mídia: áudio só em trilha de áudio; vídeo/imagem só em vídeo
track_for_media :: proc(src, t: int) -> int {
	if clips[src].is_audio do return is_audio_track(t) ? t : MAXV // A1 se largou no vídeo
	return is_audio_track(t) ? 0 : t                                 // V1 se largou no áudio
}
// idem, mas por SEGMENTO: um seg só-áudio (áudio separado de vídeo) fica preso às
// trilhas de áudio mesmo com fonte de vídeo
track_for_seg :: proc(si, t: int) -> int {
	if si >= 0 && si < nsegs && segs[si].aonly do return is_audio_track(t) ? t : MAXV
	return track_for_media(segs[si].src, t)
}

// segmento a exibir no preview (topo sob o playhead; -1 = vazio -> preto)
view_seg :: proc() -> int { return seg_at(st.playhead) }
// mídia-fonte sob o playhead (-1 = nenhuma) — usada p/ destacar no bin
view_src :: proc() -> int { a := seg_at(st.playhead); return a >= 0 ? segs[a].src : -1 }
// velocidade efetiva do segmento (0 no zero-value = 1). dur é timeline; a fonte
// consumida é dur*speed, então o mapa timeline->fonte multiplica o delta por speed.
seg_speed :: proc(si: int) -> f32 { s := segs[si].speed; return s <= 0 ? 1 : s }
// região de recorte do segmento (frações [0,1] da fonte a MANTER). Sem recorte = quadro
// inteiro (0,0,1,1). Clampa p/ ficar dentro do quadro e com tamanho mínimo.
// normaliza uma região crua (frações) p/ valores válidos; zero-value = quadro inteiro
crop_norm :: proc(cx, cy, cw, ch: f32) -> (x, y, w, h: f32) {
	if cw <= 0.001 || ch <= 0.001 do return 0, 0, 1, 1
	w = clamp(cw, 0.05, 1); h = clamp(ch, 0.05, 1)
	x = clamp(cx, 0, 1 - w); y = clamp(cy, 0, 1 - h)
	return
}
seg_crop :: proc(si: int) -> (x, y, w, h: f32) {
	s := segs[si]
	return crop_norm(s.crop_x, s.crop_y, s.crop_w, s.crop_h)
}
// região de recorte EFETIVA no tempo `t` (absoluto): estática = seg_crop; com zoom_anim,
// interpola crop_* -> crop2_* pelo tempo local do clipe (easing smoothstep = movimento suave).
seg_crop_at :: proc(si: int, t: f32) -> (x, y, w, h: f32) {
	s := segs[si]
	if !s.zoom_anim do return seg_crop(si)
	ax, ay, aw, ah := crop_norm(s.crop_x,  s.crop_y,  s.crop_w,  s.crop_h)
	bx, by, bw, bh := crop_norm(s.crop2_x, s.crop2_y, s.crop2_w, s.crop2_h)
	f := clamp((t - s.start) / max(s.dur, 0.0001), 0, 1)
	f = f*f*(3 - 2*f)
	return ax+(bx-ax)*f, ay+(by-ay)*f, aw+(bw-aw)*f, ah+(bh-ah)*f
}
seg_cropped :: proc(si: int) -> bool { return segs[si].crop_w > 0.001 && segs[si].crop_h > 0.001 && (segs[si].crop_w < 0.999 || segs[si].crop_h < 0.999) }
crop_mode: bool     // modo de recorte ativo (mostra a moldura no preview p/ ajustar)
crop_drag: int = -1 // alça de crop em arrasto: 0..7 cantos/bordas, 8 = mover a região (-1 = nenhum)
crop_grab: rl.Vector2 // offset (frações) entre o mouse e o canto da região ao começar a mover
// --- modal "Cortar e Ampliar" (estilo NLE): botão na toolbar da timeline abre um
// modal com o frame do clipe + retângulo arrastável. Reaproveita os campos crop_* do Seg
// (já renderizados no preview E no export). Aba "Cortar" = livre; "Aproximar e Ampliar" =
// proporção travada na saída (a região preenche o quadro = zoom de verdade). ---
crop_tab:      int        // aba do modal: 0=Cortar 1=Aproximar e Ampliar
crop_bk_seg:   int = -1   // segmento em edição no modal (-1 = modal fechado)
crop_bk:       [4]f32     // crop_x/y/w/h originais (restaurados no Cancelar)
crop_bk2:      [4]f32     // crop2_x/y/w/h originais (região do FIM)
crop_bk_anim:  bool       // zoom_anim original
crop_animate:  bool       // toggle "Animar zoom" dentro do modal (aba Aproximar e Ampliar)
crop_edit_end: bool       // no modo animado: false = editando o quadro Início, true = Fim
crop_play:     bool       // reproduzindo o clipe dentro do modal (mostra o resultado)
crop_play_t:   f32        // posição (s) da reprodução no modal, no tempo LOCAL do segmento
// ponto de SAÍDA na fonte (onde o segmento termina de consumir a mídia)
seg_src_out :: proc(si: int) -> f32 { return segs[si].in_off + segs[si].dur * seg_speed(si) }

// tempo dentro da FONTE correspondente ao tempo `t` da timeline no segmento `si`
seg_local :: proc(si: int, t: f32) -> f32 {
	return clamp((t - segs[si].start) * seg_speed(si) + segs[si].in_off, 0, seg_src(si).dur)
}

// segmento que continua `a` sem emenda: mesma fonte, colado na timeline E contíguo
// na fonte (é o caso de um corte simples L|R). Nesse caso o áudio da fonte já está
// tocando exatamente na posição certa, então dá pra passar o bastão sem parar/seek.
next_contiguous_seg :: proc(a: int) -> int {
	out_src := seg_src_out(a)               // posição na fonte onde `a` termina
	out_tl  := segs[a].start  + segs[a].dur // posição na timeline onde `a` termina
	for i in 0 ..< nsegs {
		if i == a || !seg_ready(i) || segs[i].src != segs[a].src || segs[i].track != segs[a].track do continue
		if math.abs(seg_speed(i) - seg_speed(a)) > 0.001 do continue // velocidades diferentes não emendam
		if math.abs(segs[i].in_off - out_src) < 0.02 && math.abs(segs[i].start - out_tl) < 0.02 do return i
	}
	return -1
}

// fim (na FONTE) da cadeia de segmentos contíguos a partir de `a`. Cortes internos
// de um mesmo clipe formam uma cadeia; para o playback são invisíveis — o áudio da
// fonte só "termina" no fim da cadeia inteira, nunca num corte interno.
seg_run_end :: proc(a: int) -> f32 {
	cur := a
	for _ in 0 ..< nsegs { // limite = nº de segmentos (nunca entra em laço)
		nx := next_contiguous_seg(cur)
		if nx < 0 do break
		cur = nx
	}
	return seg_src_out(cur)
}

// o music do clipe pode servir de relógio em `local`? O stream ativo é sempre
// uma JANELA [music_base, music_base + duração do arquivo): head (base 0),
// chunk sob demanda, ou uma parte do completo. Fora da cobertura o playback cai
// pro relógio de parede (mudo) e adota a parte pronta ou encomenda um chunk.
audio_clock_ok :: proc(c: ^Clip, local: f32) -> bool {
	if !c.has_audio do return false
	end := c.music_base + f32(c.music.frameCount) / f32(c.music.stream.sampleRate)
	return local >= c.music_base && local < end - 0.25
}

// define o segmento que fornece o áudio-relógio e o inicia em `local` (na FONTE)
set_play_clip :: proc(si: int, local: f32) {
	if play_clip >= 0 && play_clip != si && seg_src(play_clip).has_audio {
		rl.PauseMusicStream(seg_src(play_clip).music)
	}
	play_clip = si
	aud_prev = -1; play_frame = -1 // relógio monotônico e passo de frame recomeçam após seek/aquisição
	c := seg_src(si)
	// troca a janela p/ a parte da região ou o chunk no bolso, se prontos
	if c.has_audio && !try_part_open(c, local) do _ = try_chunk_open(c, local)
	if c.has_audio && audio_clock_ok(c, local) {
		msdur := f32(c.music.frameCount) / f32(c.music.stream.sampleRate)
		target := clamp(local - c.music_base, 0, msdur) // posição no ARQUIVO ativo
		// recarrega o áudio completo a cada seek (stream novo, decoder novo) em vez
		// de só reposicionar — foi o que estabilizou o playback do áudio longo.
		is_full := c.music_base == 0 && f32(c.music.frameCount) / f32(c.music.stream.sampleRate) >= c.dur - 1.0
		if is_full {
			rl.UnloadMusicStream(c.music); c.has_audio = false
			if music_open(c, part_path(c, 0)) {
				rl.SeekMusicStream(c.music, target)
				rl.ResumeMusicStream(c.music)
			}
		} else {
			// Stop antes do Seek: o Seek do raylib não descarta os sub-buffers já
			// enfileirados — sem o Stop tocava ~0.5s do áudio da posição ANTIGA (blip)
			// ao adquirir dentro do head/chunk. Play + pré-enchimento como nos demais.
			rl.StopMusicStream(c.music)
			rl.SeekMusicStream(c.music, target)
			rl.PlayMusicStream(c.music)
			for _ in 0 ..< 4 do rl.UpdateMusicStream(c.music)
		}
		seek_pending = true
		seek_pending_loc = clamp(local, 0, c.dur) // coords da FONTE (o playback compara nelas)
	} else if c.has_audio {
		chunk_request(c, local) // encomenda o áudio da região
	}
}

// MIXAGEM: toca em sincronia com o master TODOS os clipes com áudio sob o playhead que
// NÃO são o master — trilhas de áudio (música) E vídeos EMPILHADOS (o de baixo, quando o
// de cima é o relógio). O raylib soma os streams no device. Chamado todo frame — quando
// pausado/fora do clipe, silencia. NÃO mexe no relógio (master). Fontes LONGAS (streaming,
// áudio em janelas) podem não casar como secundário; o caso comum (clipes curtos) funciona.
// arrasto que NÃO deve silenciar o playback (volume/fade/transição): igual ao bloco
// do master — o usuário está ajustando áudio e precisa OUVIR a mudança ao vivo.
// Antes o secundário/spv exigiam drag==None e mutavam justamente o que era ajustado.
audio_edit_drag :: proc() -> bool {
	return st.drag == .Vol || st.drag == .FadeIn || st.drag == .FadeOut || st.drag == .TransDur || st.drag == .FxCenter
}

audio_secondary :: proc() {
	pt := prof_beg(.Audio); defer prof_end(.Audio, pt)
	// passada 1: elege, POR FONTE, o segmento que a toca neste frame (1 rl.Music não
	// toca 2 posições — mesma fonte 2x sob o playhead: o de trilha mais baixa vence,
	// o outro fica mudo). Sem eleição, um seg fora do playhead pausava o stream que
	// outro seg queria tocar, em loop (picote).
	win: [MAX_CLIPS]int
	for k in 0 ..< MAX_CLIPS do win[k] = -1
	for i in 0 ..< nsegs {
		if !seg_ready(i) || i == play_clip do continue
		// não gerencie a MESMA fonte do master aqui (o loop principal já cuida do c.music dela)
		if play_clip >= 0 && play_clip < nsegs && segs[i].src == segs[play_clip].src do continue
		if seg_speed(i) != 1 do continue // velocidade != 1: o áudio vem do spv (tom preservado)
		if !seg_src(i).has_audio do continue
		sg := &segs[i]
		inside := st.playhead >= sg.start && st.playhead < sg.start + sg.dur
		if !(st.playing && (st.drag == .None || audio_edit_drag()) && inside && !sg.muted && !track_muted[sg.track]) do continue
		if win[sg.src] < 0 || segs[i].track < segs[win[sg.src]].track do win[sg.src] = i
	}
	// passada 2: gerencia cada fonte secundária — toca o vencedor, pausa as demais
	for s in 0 ..< nclips {
		c := &clips[s]
		if c.closed || !c.has_audio do continue
		if play_clip >= 0 && play_clip < nsegs && segs[play_clip].src == s do continue // master cuida
		i := win[s]
		if i < 0 {
			if c.mix_on { rl.PauseMusicStream(c.music); c.mix_on = false }
			continue
		}
		sg := &segs[i]
		local := seg_local(i, st.playhead)
		// o stream ativo é uma JANELA da fonte (head/chunk/completo, offset music_base)
		// — igual ao master. Antes isto seekava `local` cru no arquivo ativo: em clipes
		// longos tocava a posição ERRADA (ou o fim do head) = áudio "bugado" ao sobrepor.
		if !audio_clock_ok(c, local) {
			if c.mix_on { rl.PauseMusicStream(c.music); c.mix_on = false }
			// adota a parte completa ou o chunk no bolso; senão encomenda um chunk —
			// o som desta trilha volta quando a janela cobrir (~1-2s)
			if !try_part_open(c, local) && !try_chunk_open(c, local) do chunk_request(c, local)
			continue
		}
		msdur := f32(c.music.frameCount) / f32(c.music.stream.sampleRate)
		target := clamp(local - c.music_base, 0, msdur) // posição no ARQUIVO ativo
		if !c.mix_on {
			rl.StopMusicStream(c.music); rl.SeekMusicStream(c.music, target); rl.PlayMusicStream(c.music)
			for _ in 0 ..< 4 do rl.UpdateMusicStream(c.music)
			c.mix_on = true
		} else {
			if !rl.IsMusicStreamPlaying(c.music) do rl.ResumeMusicStream(c.music)
			rl.UpdateMusicStream(c.music)
			if abs((rl.GetMusicTimePlayed(c.music) + c.music_base) - local) > 0.3 {
				// corrige drift re-ADQUIRINDO: o Seek do raylib não descarta os buffers
				// já enfileirados (tocaria ~0.7s do áudio antigo) — Stop zera e o
				// Update pré-enche com o áudio novo
				rl.StopMusicStream(c.music); rl.SeekMusicStream(c.music, target); rl.PlayMusicStream(c.music)
				for _ in 0 ..< 4 do rl.UpdateMusicStream(c.music)
			}
		}
		// pré-busca: perto do fim da janela ativa e ainda falta segmento -> encomenda
		// o próximo chunk JÁ (troca na borda sem ficar mudo esperando a extração)
		cend := c.music_base + msdur
		if cend < sg.in_off + sg.dur && local > cend - 15 {
			if int((cend + 1) / FULL_PART) >= intrinsics.atomic_load(&c.parts_done) {
				chunk_request(c, cend - 1)
			}
		}
		rl.SetMusicVolume(c.music, seg_gain(i, st.playhead) * player_vol)
	}
}

// segmento que fica com o stream ÚNICO (c.music) da fonte sob o playhead: o master (play_clip)
// se for dessa fonte; senão o de trilha mais BAIXA (mesma regra do audio_secondary). Só speed==1
// disputa o c.music (speed!=1 sempre vem do spv).
music_owner_of :: proc(src: int) -> int {
	if play_clip >= 0 && play_clip < nsegs && segs[play_clip].src == src do return play_clip
	owner := -1
	for i in 0 ..< nsegs {
		sg := segs[i]
		if sg.src != src || !seg_ready(i) || !seg_src(i).has_audio || seg_speed(i) != 1 do continue
		if sg.muted || track_muted[sg.track] do continue
		if !(st.playhead >= sg.start && st.playhead < sg.start + sg.dur) do continue
		if owner < 0 || sg.track < segs[owner].track do owner = i
	}
	return owner
}

// o segmento i precisa do PRÓPRIO áudio (via spv) por sobrepor outro da MESMA fonte que já ocupa
// o c.music (1 rl.Music não toca 2 posições — antes o duplicado ficava mudo). Só quando o conteúdo
// DIFERE do dono: cópias idênticas empilhadas seguem com um único áudio (sem eco/dobra).
seg_audio_dup :: proc(i: int) -> bool {
	if !seg_ready(i) || !seg_src(i).has_audio || seg_speed(i) != 1 do return false
	sg := segs[i]
	if sg.muted || track_muted[sg.track] do return false
	if !(st.playhead >= sg.start && st.playhead < sg.start + sg.dur) do return false
	owner := music_owner_of(sg.src)
	if owner < 0 || owner == i do return false
	return abs(seg_local(i, st.playhead) - seg_local(owner, st.playhead)) >= 0.05 // posição na fonte difere
}

// ---- preview de VELOCIDADE com tom preservado (time-stretch via ffmpeg atempo) ----
// O SetMusicPitch do raylib só reamostra (muda o TOM: voz fina/grossa). Para o
// preview soar natural, cada segmento com speed != 1 tem um WAV pré-renderizado com
// EXATAMENTE `dur` segundos e tom corrigido (o mesmo atempo do export), tocado a 1x
// e sincronizado ao playhead — como a mixagem secundária (aditivo, NÃO é relógio).
Spv :: struct {
	music: rl.Music,
	ok:    bool,   // main: WAV carregado e válido
	on:    bool,   // main: tocando agora
	key:   u64,    // conteúdo (src/in_off/dur/speed) que gerou o arquivo
	path:  string, // WAV temporário (heap, dono)
}
spv: [MAX_SEGS]Spv
spv_render_idx: int = -1      // segmento sendo renderizado (só a main escreve; -1 = ocioso)
spv_render_key: u64           // key alvo do render em voo
spv_args:       []string      // argv do ffmpeg (heap; liberado após o render)
spv_thr:        ^thread.Thread
spv_done:       bool          // atômico: worker terminou
spv_ok:         bool          // atômico: ffmpeg saiu com sucesso

// identidade do CONTEÚDO de áudio de um segmento (independe do índice, que desloca
// ao remover): fonte + trecho + velocidade. Muda => o WAV precisa ser regerado.
spv_key :: proc(i: int) -> u64 {
	sg := segs[i]
	h: u64 = 1469598103934665603
	h = (h ~ u64(u32(sg.src)))                 * 1099511628211
	h = (h ~ u64(transmute(u32)sg.in_off))     * 1099511628211
	h = (h ~ u64(transmute(u32)sg.dur))        * 1099511628211
	h = (h ~ u64(transmute(u32)seg_speed(i)))  * 1099511628211
	return h
}

spv_release :: proc(i: int) {
	e := &spv[i]
	if e.ok { rl.UnloadMusicStream(e.music); e.ok = false }
	if e.path != "" { os.remove(e.path); delete(e.path); e.path = "" }
	e.on = false; e.key = 0
}

// worker de fundo: renderiza o WAV esticado (1 por vez). Lê só globals (sem alocar).
spv_worker :: proc() {
	ok := false
	p, pe := os.process_start(os.Process_Desc{ command = spv_args })
	if pe == nil {
		job := make_kill_job() // morre junto com o editor se fechar no meio
		if job != nil do AssignProcessToJobObject(job, win.HANDLE(p.handle))
		for { // poll: se o app fechar, mata o render em voo em vez de esperar terminar
			if intrinsics.atomic_load(&app_closing) { _ = os.process_kill(p); _, _ = os.process_wait(p); break }
			state, we := os.process_wait(p, 50 * time.Millisecond)
			if state.exited { ok = we == nil && state.exit_code == 0; break }
			if we != nil && we != os.General_Error.Timeout do break
		}
		if job != nil do win.CloseHandle(job)
	}
	intrinsics.atomic_store(&spv_ok, ok)
	intrinsics.atomic_store(&spv_done, true)
}

// monta a cadeia atempo (0.5..2 por estágio) p/ cobrir 0.25..4 — igual ao export.
spv_atempo :: proc(sp: f32) -> string {
	b := strings.builder_make(context.temp_allocator)
	r := sp
	for r > 2.0 + 0.001 { fmt.sbprintf(&b, "atempo=2.0,"); r /= 2 }
	for r < 0.5 - 0.001 { fmt.sbprintf(&b, "atempo=0.5,"); r *= 2 }
	fmt.sbprintf(&b, "atempo=%.5f", r)
	return strings.to_string(b)
}

// dispara (se ocioso) o render do WAV do segmento i. Enquanto não fica pronto, o
// segmento toca MUDO no preview (nunca com tom cru) — some em ~1-2s.
SPV_MAX_DUR :: f32(300) // acima disso o WAV esticado seria enorme/lento: preview fica mudo

spv_request :: proc(i: int, k: u64) {
	if spv_render_idx >= 0 do return // um render por vez; os outros tentam no próximo frame
	// descarrega o WAV antigo (conteúdo obsoleto) ANTES de reescrever o arquivo —
	// senão o ffmpeg -y colide com o handle que o raylib mantém aberto (Windows).
	if spv[i].ok { rl.UnloadMusicStream(spv[i].music); spv[i].ok = false; spv[i].on = false }
	sg := segs[i]
	c  := seg_src(i)
	sp := seg_speed(i)
	span := sg.dur * sp // trecho da fonte a ler (rende `dur` após o atempo)
	if spv[i].path == "" {
		spv[i].path = fmt.aprintf("%s_%d_%d_spv%d.wav", AUDIO_BASE, u32(win.GetCurrentProcessId()), c.aid, i)
	}
	args := make([dynamic]string) // heap: precisa viver até o worker rodar o process_start
	append(&args, strings.clone("ffmpeg"), strings.clone("-y"), strings.clone("-hide_banner"),
		strings.clone("-loglevel"), strings.clone("error"),
		strings.clone("-ss"), fmt.aprintf("%.3f", sg.in_off),
		strings.clone("-t"),  fmt.aprintf("%.3f", span),
		strings.clone("-i"),  strings.clone(c.path),
		strings.clone("-vn"), strings.clone("-filter:a"), strings.clone(spv_atempo(sp)),
		strings.clone("-c:a"), strings.clone("pcm_s16le"), strings.clone(spv[i].path))
	spv_args = args[:]
	spv_render_idx = i
	spv_render_key = k
	intrinsics.atomic_store(&spv_done, false)
	spv_thr = thread.create_and_start(spv_worker)
}

// adota o render terminado (LoadMusicStream é GL/áudio -> só na main).
spv_poll :: proc() {
	if spv_render_idx < 0 || !intrinsics.atomic_load(&spv_done) do return
	i := spv_render_idx
	if spv_thr != nil { thread.join(spv_thr); thread.destroy(spv_thr); spv_thr = nil }
	ok := intrinsics.atomic_load(&spv_ok)
	for s in spv_args do delete(s) // libera o argv clonado
	delete(spv_args); spv_args = nil
	// só adota se o segmento ainda existe e nada mudou (senão o WAV está obsoleto)
	if ok && i < nsegs && seg_ready(i) && spv_key(i) == spv_render_key {
		e := &spv[i]
		if e.ok { rl.UnloadMusicStream(e.music); e.ok = false }
		e.music = rl.LoadMusicStream(strings.clone_to_cstring(e.path, context.temp_allocator))
		if e.music.frameCount > 0 { e.music.looping = false; e.ok = true; e.key = spv_render_key }
		e.on = false
	}
	spv_render_idx = -1
}

// toca, em sincronia com o playhead, o áudio pré-renderizado dos segmentos com
// speed != 1 sob o playhead. Chamado todo frame junto com audio_secondary.
audio_speed_preview :: proc() {
	pt := prof_beg(.Audio); defer prof_end(.Audio, pt)
	for i := nsegs; i < MAX_SEGS; i += 1 do if spv[i].ok || spv[i].path != "" do spv_release(i) // limpa slots mortos
	for i in 0 ..< nsegs {
		e := &spv[i]
		// usa o WAV por-segmento (spv) quando o áudio da fonte NÃO pode vir do c.music:
		// velocidade != 1 (tom preservado) OU duplicado (mesma fonte já ocupa o c.music).
		uses_spv := seg_ready(i) && seg_src(i).has_audio && (seg_speed(i) != 1 || seg_audio_dup(i))
		if !uses_spv {
			if e.on { rl.PauseMusicStream(e.music); e.on = false }
			continue
		}
		sg := &segs[i]
		inside := st.playhead >= sg.start && st.playhead < sg.start + sg.dur
		want := st.playing && (st.drag == .None || audio_edit_drag()) && inside && !sg.muted && !track_muted[sg.track]
		k := spv_key(i)
		// (re)gera o WAV quando necessário e a interação assentou (não arrastando o slider).
		// Segmentos muito longos não são pré-renderizados (WAV enorme) -> preview mudo.
		if want && (!e.ok || e.key != k) && sg.dur <= SPV_MAX_DUR && ui_slider_active != 9 && spv_render_idx < 0 {
			spv_request(i, k)
		}
		if want && e.ok && e.key == k {
			local := clamp(st.playhead - sg.start, 0, sg.dur) // spv tem `dur` s @ 1x
			if !e.on {
				rl.StopMusicStream(e.music); rl.SeekMusicStream(e.music, local); rl.PlayMusicStream(e.music)
				for _ in 0 ..< 4 do rl.UpdateMusicStream(e.music)
				e.on = true
			} else {
				if !rl.IsMusicStreamPlaying(e.music) do rl.ResumeMusicStream(e.music)
				rl.UpdateMusicStream(e.music)
				if abs(rl.GetMusicTimePlayed(e.music) - local) > 0.3 {
					// re-ADQUIRE (Stop zera a fila): Seek puro deixava os sub-buffers
					// antigos tocando — dessincronia permanente após um hitch, invisível
					// ao próprio check (GetMusicTimePlayed já reportava o alvo)
					rl.StopMusicStream(e.music); rl.SeekMusicStream(e.music, local); rl.PlayMusicStream(e.music)
					for _ in 0 ..< 4 do rl.UpdateMusicStream(e.music)
				}
			}
			rl.SetMusicVolume(e.music, seg_gain(i, st.playhead) * player_vol)
		} else if e.on {
			rl.PauseMusicStream(e.music); e.on = false
		}
	}
	spv_poll()
}

// ---------- undo/redo ----------
snap_now :: proc() -> Snapshot { s: Snapshot; s.segs = segs; s.nsegs = nsegs; s.fxsegs = fxsegs; s.nfx = nfx; s.nv = g_nv; s.na = g_na; return s }
snap_apply :: proc(s: Snapshot) { segs = s.segs; nsegs = s.nsegs; fxsegs = s.fxsegs; nfx = s.nfx; g_nv = s.nv; g_na = s.na }
snap_eq :: proc(s: Snapshot) -> bool {
	if s.nsegs != nsegs || s.nfx != nfx || s.nv != g_nv || s.na != g_na do return false
	for i in 0 ..< nsegs do if segs[i] != s.segs[i] do return false // Seg é comparável (sem ponteiros)
	for i in 0 ..< nfx   do if fxsegs[i] != s.fxsegs[i] do return false
	return true
}
push_stack :: proc(stack: ^[MAX_UNDO]Snapshot, top: ^int, s: Snapshot) {
	if top^ >= MAX_UNDO { for i in 0 ..< MAX_UNDO - 1 do stack[i] = stack[i + 1]; top^ = MAX_UNDO - 1 } // dropa o mais antigo
	stack[top^] = s; top^ += 1
}
// redefine o baseline SEM criar entrada de undo (ex.: remover mídia — não é desfazível)
history_baseline :: proc() { committed = snap_now(); committed_ok = true }
// chamado todo frame (fim do update): se segs mudou E não há interação em curso, grava
history_tick :: proc() {
	if !committed_ok { history_baseline(); return }
	if st.drag != .None || ui_slider_active != -1 || player_seek_drag || bin_drag >= 0 do return
	if !snap_eq(committed) {
		push_stack(&undo_stack, &undo_top, committed) // guarda o estado ANTERIOR
		redo_top = 0                                   // nova edição invalida o redo
		committed = snap_now()
		dirty = true                                   // edição não salva
	}
}
restore_after :: proc() { // conserta índices e o preview após aplicar um snapshot
	if selected >= nsegs do selected = -1
	if sel_trans >= nsegs do sel_trans = -1
	seg_clear_marks() // índices do snapshot não batem com as marcas antigas
	drag_clip = -1; play_clip = -1; st.playing = false; st.drag = .None
	committed = snap_now()
	dirty = true // desfazer/refazer também deixa o documento diferente do salvo
	seek_global(clamp(st.playhead, 0, timeline_dur()))
}
do_undo :: proc() {
	if undo_top == 0 { set_toast("Nada para desfazer"); return }
	push_stack(&redo_stack, &redo_top, snap_now()) // estado atual vai p/ o redo
	undo_top -= 1
	snap_apply(undo_stack[undo_top])
	restore_after()
	set_toast("Desfazer")
}
do_redo :: proc() {
	if redo_top == 0 { set_toast("Nada para refazer"); return }
	push_stack(&undo_stack, &undo_top, snap_now())
	redo_top -= 1
	snap_apply(redo_stack[redo_top])
	restore_after()
	set_toast("Refazer")
}

// reposiciona a timeline inteira para o tempo t (seek instantâneo)
seek_global :: proc(t: f32) {
	tt := clamp(t, 0, timeline_dur())
	st.playhead = tt
	for i in 0 ..< nclips do if !clips[i].closed && clips[i].has_audio { rl.PauseMusicStream(clips[i].music); clips[i].mix_on = false }
	for i in 0 ..< nsegs do if spv[i].on { rl.PauseMusicStream(spv[i].music); spv[i].on = false } // pausa spv (reposiciona no frame seguinte)
	play_clip = -1
	show_playhead_frame() // vídeo: frame da trilha de topo sob o playhead
	a := audio_seg_at(tt)  // áudio: relógio do topo COM áudio não-mudo
	if a < 0 do return // sem áudio na região (vazio ou só vídeo): nada a adquirir
	local := seg_local(a, tt)
	src := seg_src(a)
	// mesmo pausado, já garante o áudio da região: adota a parte pronta ou o chunk
	// no bolso, senão encomenda um chunk — quando der play, o som está lá
	if src.has_audio && !try_part_open(src, local) && !try_chunk_open(src, local) do chunk_request(src, local)
	if st.playing && src.has_audio do set_play_clip(a, local)
}

// ---------- prévia de origem (duplo-clique no bin: toca a mídia crua no player,
// sem colocá-la na timeline). Caminho próprio, isolado do playback da timeline. ----------
// (re)adquire o áudio da fonte na posição src_t, reusando os helpers de janela
src_acquire :: proc() {
	if src_preview < 0 do return
	c := &clips[src_preview]
	aud_prev = -1; play_frame = -1
	if !c.has_audio do return
	if !try_part_open(c, src_t) do _ = try_chunk_open(c, src_t)
	if audio_clock_ok(c, src_t) {
		msdur := f32(c.music.frameCount) / f32(c.music.stream.sampleRate)
		target := clamp(src_t - c.music_base, 0, msdur)
		rl.StopMusicStream(c.music); rl.SeekMusicStream(c.music, target) // Stop zera os buffers antigos
		if st.playing do rl.PlayMusicStream(c.music)
		for _ in 0 ..< 8 do rl.UpdateMusicStream(c.music) // pré-enche c/ o áudio novo
	} else {
		chunk_request(c, src_t) // fora da janela: encomenda o áudio da região
	}
}

start_src_preview :: proc(i: int) {
	if i < 0 || i >= nclips || !media_ready(i) do return
	// silencia o áudio da timeline e o da prévia anterior (se trocando)
	if play_clip >= 0 && seg_src(play_clip).has_audio do rl.PauseMusicStream(seg_src(play_clip).music)
	if src_preview >= 0 && src_preview != i && !clips[src_preview].closed && clips[src_preview].has_audio do rl.PauseMusicStream(clips[src_preview].music)
	for k in 0 ..< nclips do if clips[k].mix_on { rl.PauseMusicStream(clips[k].music); clips[k].mix_on = false } // silencia mix
	for k in 0 ..< nsegs do if spv[k].on { rl.PauseMusicStream(spv[k].music); spv[k].on = false } // silencia spv
	play_clip = -1
	src_preview = i
	src_t = 0
	bin_sel = i; selected = -1
	st.playing = true
	src_acquire()
	clip_frame(&clips[i], 0) // mostra o 1º frame já neste frame
}

exit_src_preview :: proc() {
	if src_preview < 0 do return
	c := &clips[src_preview]
	if !c.closed && c.has_audio do rl.PauseMusicStream(c.music)
	src_preview = -1
	st.playing = false
}

// fonte + tempo (na fonte) do que está no player agora (prévia de origem OU timeline)
player_source :: proc() -> (pc: int, t: f32) {
	if src_preview >= 0 && src_preview < nclips && !clips[src_preview].closed do return src_preview, src_t
	v := view_seg()
	if v >= 0 do return segs[v].src, seg_local(v, st.playhead)
	return -1, 0
}

// salva o frame atual do player em `out` (resolução cheia via ffmpeg -ss no ponto exato)
take_screenshot :: proc(out: string) {
	pc, t := player_source()
	if pc < 0 { set_toast("Nada no player para capturar"); return }
	cmd := []string{
		"ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
		"-ss", fmt.tprintf("%.3f", t), "-i", clips[pc].path,
		"-frames:v", "1", "-update", "1", out,
	}
	if p, e := os.process_start(os.Process_Desc{ command = cmd }); e == nil {
		_, _ = os.process_wait(p) // 1 frame: rápido
		set_toast(rl.TextFormat("Screenshot salvo: %s", cs(out)))
		shot_n += 1
	} else {
		set_toast("Falha ao salvar screenshot")
	}
}

toggle_fullscreen_preview :: proc() {
	fullscreen_preview = !fullscreen_preview
	// tela cheia SEM borda que cobre o monitor INTEIRO (inclusive a barra de tarefas do
	// Windows). O ToggleFullscreen deixava a barra de tarefas aparecer no rodapé.
	rl.ToggleBorderlessWindowed()
	if fullscreen_preview {
		fs_ctl_alpha = 1; fs_ctl_hold = 3 // ao entrar, mostra os controles por uns segundos
	} else {
		// ao voltar pro modo janela, o ToggleBorderlessWindowed devolve a borda/barra de
		// título NATIVAS do Windows E restaura um tamanho errado (menor que a tela, sobra
		// desktop embaixo). A janela foi criada SEM decoração e SEMPRE maximizada, então:
		// re-aplica "sem decoração" e re-maximiza limpo p/ voltar a preencher a tela.
		rl.SetWindowState({ .WINDOW_UNDECORATED })
		rl.RestoreWindow()  // limpa estado maximizado inconsistente deixado pelo toggle
		rl.MaximizeWindow() // re-maximiza (estado padrão do app), preenchendo a tela
		rl.ShowCursor(); fs_vol_drag = false; player_seek_drag = false // garante o cursor de volta
	}
}

// multiplica a opacidade de uma cor por `a` (p/ o fade dos controles em tela cheia)
fa :: proc(c: rl.Color, a: f32) -> rl.Color {
	return { c.r, c.g, c.b, u8(clamp(f32(c.a) * a, 0, 255)) }
}

// desenha só o vídeo ocupando a janela toda (modo tela cheia), com controles
// no rodapé estilo NLE: somem sozinhos e reaparecem ao mexer o mouse ali perto
draw_fullscreen_video :: proc(sw, sh: f32) {
	rl.DrawRectangleRec({ 0, 0, sw, sh }, rl.BLACK)
	// canvas na janela toda: proporção do projeto — ou, na prévia de origem, a da fonte
	par := preview_ar()
	scaleC := min(sw/par, sh)
	fw := par*scaleC; fh := scaleC
	fx := (sw-fw)/2; fy := (sh-fh)/2
	if src_preview >= 0 { // prévia de origem: fonte na PRÓPRIA proporção, preenchendo o canvas
		c := &clips[src_preview]
		ensure_tex(c)
		if c.tex_ok do rl.DrawTexturePro(c.tex, dec_content_rect(c), { fx, fy, fw, fh }, {0,0}, 0, rl.WHITE)
	} else {
		rl.BeginScissorMode(i32(fx), i32(fy), i32(fw), i32(fh)) // transform não vaza do frame
		composite_video(fx, fy, fw, fh, false) // MESMO compositing/transforms do editor
		rl.EndScissorMode()
	}

	// ---- auto-hide dos controles ----
	dt := rl.GetFrameTime()
	m  := rl.GetMousePosition()
	bh: f32 = 96 // altura da barra de controles
	d  := rl.GetMouseDelta()
	moved := abs(d.x) + abs(d.y) > 0.5
	hot   := m.y >= sh - bh - 48 // mouse na barra (ou logo acima): mantém aparecendo
	active := moved || hot || player_seek_drag || fs_vol_drag || rl.IsMouseButtonDown(.LEFT)
	if active do fs_ctl_hold = 2 // "vive" por +2s a cada atividade
	else do fs_ctl_hold = max(0, fs_ctl_hold - dt)
	target: f32 = fs_ctl_hold > 0 ? 1 : 0
	fs_ctl_alpha += (target - fs_ctl_alpha) * min(1, dt * 12) // fade rápido

	a := fs_ctl_alpha
	if a <= 0.02 do return // totalmente escondido: nada de barra (o cursor do mouse NÃO some)
	interactive := a > 0.5 // escondido não recebe clique (o 1º só revela, estilo player)

	// gradiente de escurecimento no rodapé p/ leitura dos controles sobre o vídeo
	bar_y := sh - bh
	rl.DrawRectangleGradientV(0, i32(bar_y - 54), i32(sw), i32(bh + 54), fa({0,0,0,0}, a), fa({0,0,0,205}, a))

	// --- barra de progresso (posição atual / duração total, arrastável) ---
	total := src_preview >= 0 ? (src_preview < nclips ? clips[src_preview].dur : 0) : timeline_dur()
	pos   := src_preview >= 0 ? src_t : st.playhead
	pbar := rl.Rectangle{ 28, bar_y + 26, sw - 56, 6 }
	pbar_hit := rl.Rectangle{ pbar.x - 6, pbar.y - 9, pbar.width + 12, 24 }
	frac := total > 0 ? clamp(pos / total, 0, 1) : 0
	rl.DrawRectangleRounded(pbar, 1, 4, fa({ 70, 74, 86, 255 }, a))
	rl.DrawRectangleRounded({ pbar.x, pbar.y, frac * pbar.width, pbar.height }, 1, 4, fa(ACCENT, a))
	pkx := pbar.x + frac * pbar.width
	rl.DrawCircleV({ pkx, pbar.y + pbar.height/2 }, (player_seek_drag || hovered(pbar_hit)) ? 8 : 6, fa(rl.WHITE, a))
	if interactive && rl.IsMouseButtonPressed(.LEFT) && hovered(pbar_hit) { player_seek_drag = true; st.playing = false }
	if rl.IsMouseButtonReleased(.LEFT) && player_seek_drag {
		player_seek_drag = false
		if src_preview >= 0 { src_acquire(); clip_frame(&clips[src_preview], src_t) } else do seek_global(st.playhead)
	}
	if player_seek_drag && total > 0 {
		np := clamp((m.x - pbar.x) / pbar.width, 0, 1) * total
		if src_preview >= 0 {
			src_t = np
			if !clips[src_preview].streaming do clip_show(&clips[src_preview], int(np * cfps_of(&clips[src_preview])))
		} else {
			st.playhead = np
			v := view_seg()
			if v >= 0 && !seg_src(v).streaming do clip_show(seg_src(v), int(seg_local(v, np) * cfps_of(seg_src(v))))
		}
	}

	cy := bar_y + 62 // linha de botões abaixo da barra de progresso

	// play / pause (canto inferior esquerdo)
	pr := rl.Rectangle{ 26, cy - 18, 36, 36 }
	rl.DrawCircleV({ pr.x + 18, cy }, 18, fa(hovered(pr) ? ACCENT : ACCENT_D, a))
	if st.playing {
		rl.DrawRectangleRec({ pr.x + 12, cy - 8, 4, 16 }, fa(rl.WHITE, a))
		rl.DrawRectangleRec({ pr.x + 20, cy - 8, 4, 16 }, fa(rl.WHITE, a))
	} else {
		rl.DrawTriangle({ pr.x + 13, cy - 9 }, { pr.x + 13, cy + 9 }, { pr.x + 27, cy }, fa(rl.WHITE, a))
	}
	if interactive && clicked(pr) do toggle_play()

	// timecode: posição ATUAL / duração TOTAL
	txt(rl.TextFormat("%s / %s", timecode(pos), timecode(total)), pr.x + 52, cy - 9, 16, fa(TEXT, a))

	// --- sair da tela cheia (canto inferior direito): 4 cantoneiras p/ DENTRO ---
	fsr := rl.Rectangle{ sw - 44, cy - 12, 24, 24 }
	fc := fa(hovered(fsr) ? ACCENT : TEXT, a)
	L :: f32(8)
	rl.DrawLineEx({fsr.x + L, fsr.y}, {fsr.x + L, fsr.y + L}, 2, fc);                         rl.DrawLineEx({fsr.x, fsr.y + L}, {fsr.x + L, fsr.y + L}, 2, fc)
	rl.DrawLineEx({fsr.x + fsr.width - L, fsr.y}, {fsr.x + fsr.width - L, fsr.y + L}, 2, fc);  rl.DrawLineEx({fsr.x + fsr.width, fsr.y + L}, {fsr.x + fsr.width - L, fsr.y + L}, 2, fc)
	rl.DrawLineEx({fsr.x + L, fsr.y + fsr.height}, {fsr.x + L, fsr.y + fsr.height - L}, 2, fc); rl.DrawLineEx({fsr.x, fsr.y + fsr.height - L}, {fsr.x + L, fsr.y + fsr.height - L}, 2, fc)
	rl.DrawLineEx({fsr.x + fsr.width - L, fsr.y + fsr.height}, {fsr.x + fsr.width - L, fsr.y + fsr.height - L}, 2, fc); rl.DrawLineEx({fsr.x + fsr.width, fsr.y + fsr.height - L}, {fsr.x + fsr.width - L, fsr.y + fsr.height - L}, 2, fc)
	if interactive && clicked(fsr) { toggle_fullscreen_preview(); return }

	// --- volume: alto-falante (clique = mudo/desmuta) + slider horizontal ---
	vtr := rl.Rectangle{ fsr.x - 108, cy - 3, 90, 6 } // trilho do slider
	spr := rl.Rectangle{ vtr.x - 30, cy - 10, 22, 20 } // ícone do alto-falante à esquerda
	sc := player_vol < 0.01 ? fa({ 210, 100, 100, 255 }, a) : fa(hovered(spr) ? ACCENT : TEXT, a)
	{
		bx := spr.x + 3; bcy := spr.y + spr.height/2
		rl.DrawRectangleRec({bx, bcy - 3, 3.5, 6}, sc)
		rl.DrawTriangle({bx + 3.5, bcy - 6}, {bx + 3.5, bcy + 6}, {bx + 9, bcy}, sc)
		if player_vol < 0.01 {
			rl.DrawLineEx({bx + 11, bcy - 4}, {bx + 17, bcy + 4}, 1.8, sc)
			rl.DrawLineEx({bx + 17, bcy - 4}, {bx + 11, bcy + 4}, 1.8, sc)
		} else {
			rl.DrawRing({bx + 6, bcy}, 5.2, 6.4, -55, 55, 12, sc)
			rl.DrawRing({bx + 6, bcy}, 3.0, 3.9, -55, 55, 12, sc)
		}
	}
	if interactive && clicked(spr) do player_vol = player_vol < 0.01 ? 1 : 0
	vhit := rl.Rectangle{ vtr.x - 4, vtr.y - 9, vtr.width + 8, 24 }
	rl.DrawRectangleRounded(vtr, 1, 4, fa({ 70, 74, 86, 255 }, a))
	rl.DrawRectangleRounded({ vtr.x, vtr.y, player_vol * vtr.width, vtr.height }, 1, 4, fa(ACCENT, a))
	rl.DrawCircleV({ vtr.x + player_vol * vtr.width, vtr.y + vtr.height/2 }, (fs_vol_drag || hovered(vhit)) ? 7 : 5, fa(rl.WHITE, a))
	if interactive && rl.IsMouseButtonPressed(.LEFT) && hovered(vhit) do fs_vol_drag = true
	if rl.IsMouseButtonReleased(.LEFT) do fs_vol_drag = false
	if fs_vol_drag do player_vol = clamp((m.x - vtr.x) / vtr.width, 0, 1)

	// dica curta (some junto com os controles)
	txt("Esc: sair  ·  Espaço: play/pause", 26, bar_y + 4, 13, fa({ 210, 210, 215, 190 }, a))
}

// playback da prévia de origem (chamado no update quando src_preview >= 0)
update_src_preview :: proc(dt: f32) {
	c := &clips[src_preview]
	if c.closed || intrinsics.atomic_load(&c.failed) { src_preview = -1; st.playing = false; return }
	if !st.playing do return
	if c.has_audio && audio_clock_ok(c, src_t) {
		rl.SetMusicVolume(c.music, player_vol) // volume do player (monitor)
		rl.UpdateMusicStream(c.music)
		nt := smooth_clock(rl.GetMusicTimePlayed(c.music) + c.music_base, dt) // relógio suave (anti-judder)
		aud_prev = nt
		src_t = nt
		if !rl.IsMusicStreamPlaying(c.music) && src_t < c.dur - 0.25 do rl.ResumeMusicStream(c.music) // underrun
	} else {
		// fora da janela (áudio longo ainda extraindo) ou clipe sem áudio: relógio de parede
		if c.has_audio && !try_part_open(c, src_t) && !try_chunk_open(c, src_t) do chunk_request(c, src_t)
		src_t += dt
	}
	if src_t >= c.dur - 0.02 { // fim da fonte: para no fim
		src_t = c.dur
		st.playing = false
		if c.has_audio do rl.PauseMusicStream(c.music)
	}
	// DISPLAY: frame por PASSO travado no vsync (ver play_frame). Cache indexa a RAM direto;
	// streaming decodifica por tempo (respawn/EOF) e mantém o caminho antigo.
	if c.streaming {
		clip_frame(c, src_t)
	} else {
		target := int(src_t * cfps_of(c))
		if play_frame < 0 do play_frame = target
		else {
			d := target - play_frame
			if d >= 2 do play_frame += 2         // atrasado 2+: acelera (raro; hitch/render mais lento)
			else if d > -2 do play_frame += 1    // zona-morta -1..+1: sempre +1 (1:1, sem beat)
			// d <= -2: segura (render mais rápido que o conteúdo, ex. 75Hz -> pulldown uniforme)
		}
		clip_show(c, play_frame)
	}
}

toggle_play :: proc() {
	if src_preview >= 0 { // prévia de origem: espaço toca/pausa a fonte
		c := &clips[src_preview]
		if st.playing {
			st.playing = false
			if c.has_audio do rl.PauseMusicStream(c.music)
		} else {
			if src_t >= c.dur - 0.03 do src_t = 0
			st.playing = true
			src_acquire()
		}
		return
	}
	if nsegs == 0 { return }
	if st.playing {
		st.playing = false
		if play_clip >= 0 && seg_src(play_clip).has_audio do rl.PauseMusicStream(seg_src(play_clip).music)
		play_clip = -1
		return
	}
	if st.playhead >= timeline_dur() - 0.03 do seek_global(0)
	st.playing = true // update() adquire o áudio do segmento sob o playhead
}

// ---------- update ----------
update :: proc() {
	// FPS dinâmico: parado (sem playback nem arrasto), 30fps bastam p/ a UI —
	// metade do custo de render; qualquer interação volta a 60 no frame seguinte.
	// O avanço por relógio de parede usa dt, então funciona em qualquer fps.
	idle := !st.playing && st.drag == .None && !win_dragging && !tl_hbar_drag && !zoom_bar_drag && !bin_marquee && !tl_marquee
	// PLAYBACK: sem cap de CPU — deixa o VSYNC ditar o ritmo (trava no vblank do monitor,
	// como o VLC). SetTargetFPS(60) por timer de CPU não sincroniza com o refresh e batia
	// contra o vsync = judder/tearing. 0 = ilimitado, mas o VSYNC_HINT segura no refresh atual
	// (casa com qualquer taxa, inclusive se o usuário trocar 75->60Hz com o app aberto).
	// Parado: mantém o cap de 30 (economia; sem playback a suavidade não importa).
	rl.SetTargetFPS(idle ? 30 : 0)

	dt := rl.GetFrameTime()
	// TETO no dt: uma travada longa (respawn do decoder de vídeo ~250ms, extração de
	// chunk, loop modal do Windows ao redimensionar, GC) faz o GetFrameTime devolver o
	// tempo INTEIRO da travada. Os ramos por relógio de parede (vão/mudo, velocidade!=1,
	// underrun do áudio, sem-chunk) somam isso de uma vez ao playhead — e o cursor SALTA
	// de lugar "do nada". Limita a ~2 frames: o relógio de áudio re-sincroniza no frame
	// seguinte, então o único custo é uma micro-perda de sync que ele mesmo corrige.
	if dt > 0.1 do dt = 0.1
	g_read_budget = READ_BUDGET // renova o orçamento de decode bloqueante deste frame
	m := rl.GetMousePosition()
	released := rl.IsMouseButtonReleased(.LEFT)
	was_ph := st.drag == .Playhead
	was_clip := st.drag == .Clip
	was_bin := st.drag == .Bin
	was_trans := st.drag == .Trans

	// drag-and-drop de arquivos: importam para o bin (já importado = só seleciona)
	if rl.IsFileDropped() {
		files := rl.LoadDroppedFiles()
		for i in 0 ..< int(files.count) {
			p := strings.clone_from_cstring(files.paths[i], context.temp_allocator)
			if slot, isnew := import_or_select(p, false); !isnew && slot >= 0 {
				set_toast(rl.TextFormat("Já na bin: %s", cs(clips[slot].name)))
			}
		}
		rl.UnloadDroppedFiles(files)
	}
	// botão Importar -> diálogo de arquivo do Windows (também vai para o bin)
	if want_import {
		want_import = false
		if paths, ok := open_videos_dialog(); ok {
			n, dup := 0, -1
			for p in paths {
				slot, isnew := import_or_select(p, false)
				if isnew && slot >= 0 do n += 1
				else if !isnew do dup = slot // já importado
			}
			if n > 1 do set_toast(rl.TextFormat("%d mídias importadas", n))
			else if n == 0 && dup >= 0 do set_toast(rl.TextFormat("Já na bin: %s", cs(clips[dup].name)))
		}
	}
	if toast_t > 0 do toast_t -= dt

	audio_load_ready() // carrega áudios cuja extração terminou
	adopt_respawns()   // sobe frames de respawns de vídeo concluídos (até pausado)
	notify_imports()   // avisa "pronto"/"falhou"

	// prévia da exportação: quando o import do arquivo exportado fica pronto, toca-o
	if preview_pending >= 0 && preview_pending < nclips && media_ready(preview_pending) {
		start_src_preview(preview_pending); preview_pending = -1
	}

	// modal aberto: congela as interações de fundo (o draw_modal cuida do modal)
	if modal != .None { st.drag = .None; ui_slider_active = -1; player_seek_drag = false; return }

	// exportando: intercepta os cliques nos botões do overlay (pausar/cancelar) ANTES
	// do resto — os rects vêm do draw. Não congela o resto da UI.
	if intrinsics.atomic_load(&export_run) && rl.IsMouseButtonPressed(.LEFT) {
		m := rl.GetMousePosition()
		if rl.CheckCollisionPointRec(m, g_exp_pause_btn)  { export_toggle_pause(); return }
		if rl.CheckCollisionPointRec(m, g_exp_cancel_btn) { export_do_cancel();   return }
	}

	// seleção de transição/fade que ficou inválida (removida / undo / segmentos mudaram) cai fora
	if sel_trans >= 0 {
		valid := sel_trans < nsegs
		if valid {
			switch sel_trans_kind {
			case 1: valid = segs[sel_trans].vfin  > 0.01
			case 2: valid = segs[sel_trans].vfout > 0.01
			case:   valid = seg_trans(sel_trans)  > 0.01
			}
		}
		if !valid do sel_trans = -1
	}

	// ---- menu de contexto da timeline (botão direito) ----
	ctx_ate = false
	if ctx_open && (ctx_seg >= nsegs || (ctx_seg >= 0 && !seg_ready(ctx_seg))) do ctx_open = false // alvo sumiu (undo etc.)
	if ctx_open {
		if rl.IsKeyPressed(.ESCAPE) do ctx_open = false
		if rl.IsMouseButtonPressed(.LEFT) {
			id, _ := ctx_hit(rl.GetMousePosition())
			if id >= 0 do ctx_run(id)
			ctx_open = false
			ctx_ate = true // o press que fechou/executou não vaza p/ a timeline (draw)
		} else if rl.IsMouseButtonPressed(.RIGHT) {
			_, inside := ctx_hit(rl.GetMousePosition())
			ctx_open = false
			if inside do ctx_ate = true // direito dentro só fecha; fora deixa reabrir abaixo
		}
	}
	// abrir: botão direito sobre as trilhas (num clipe = menu completo; vazio = colar)
	if !ctx_ate && rl.IsMouseButtonPressed(.RIGHT) && modal == .None && src_preview < 0 &&
	   st.drag == .None && !intrinsics.atomic_load(&export_run) && !fullscreen_preview {
		mp := rl.GetMousePosition()
		if rl.CheckCollisionPointRec(mp, g_vlane) {
			tr := track_at_y(mp.y)
			si := seg_on_track_at(tr, tl_t(mp.x))
			if si >= 0 && track_locked[tr] {
				set_toast("Trilha bloqueada")
			} else {
				ctx_seg = si
				ctx_time = max(0, tl_t(mp.x))
				if si >= 0 { // clique direito também seleciona (age no que se vê)
					selected = si; sel_trans = -1; bin_sel = -1
					if !seg_marked[si] do seg_clear_marks() // fora do grupo: menu age só nele
				}
				ctx_pos = mp
				ctx_open = true
			}
		}
	}

	// Ctrl+Z = desfazer | Ctrl+Y ou Ctrl+Shift+Z = refazer
	ctrl := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
	shift := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
	if ctrl && src_preview < 0 {
		if rl.IsKeyPressed(.Z) && !shift do do_undo()
		if rl.IsKeyPressed(.Y) || (rl.IsKeyPressed(.Z) && shift) do do_redo()
	}
	// Ctrl+S = salvar projeto | Ctrl+O = abrir projeto
	if ctrl && rl.IsKeyPressed(.S) {
		if p, ok := save_dialog("Meu Projeto"); ok do save_project(ensure_ext(p, ".ovp"))
	}
	if ctrl && rl.IsKeyPressed(.O) do request_open()
	// Ctrl+C/X = copiar/recortar o clipe selecionado (ou grupo marcado) da timeline
	// Ctrl+V = colar no playhead | Ctrl+D = duplicar logo após o original
	// (campos de texto têm o próprio Ctrl+C/V/X — gate por txt_edit/search_focus)
	if ctrl && src_preview < 0 && !txt_edit && !search_focus {
		if rl.IsKeyPressed(.C) do copy_segs()
		if rl.IsKeyPressed(.X) do cut_segs()
		if rl.IsKeyPressed(.V) do paste_segs(st.playhead)
		if rl.IsKeyPressed(.D) do duplicate_segs()
	}

	// Delete/Backspace: item do bin selecionado tem prioridade (remove a mídia do
	// editor); senão remove o segmento selecionado da timeline (Alt = deixa o vão)
	if (rl.IsKeyPressed(.DELETE) || rl.IsKeyPressed(.BACKSPACE)) && !txt_edit && !search_focus {
		if bin_marks_count() > 0 { // remove todas as mídias marcadas (tombstone; índices estáveis)
			rm := 0
			for k in 0 ..< nclips do if bin_marked[k] && !intrinsics.atomic_load(&clips[k].failed) { remove_media(k); rm += 1 }
			bin_clear_marks(); bin_sel = -1
			if rm > 1 do set_toast(rl.TextFormat("%d mídias removidas", rm))
		} else if bin_sel >= 0 && bin_sel < nclips && !intrinsics.atomic_load(&clips[bin_sel].failed) {
			remove_media(bin_sel)
		} else if fx_sel >= 0 && fx_sel < nfx { // clipe de efeito selecionado
			remove_fxseg(fx_sel); set_toast("Efeito removido")
		} else if sel_trans >= 0 && sel_trans < nsegs { // transição/fade selecionado tem prioridade
			switch sel_trans_kind {
			case 1: segs[sel_trans].vfin = 0;  set_toast("Fade de entrada removido")
			case 2: segs[sel_trans].vfout = 0; set_toast("Fade de saída removido")
			case:   segs[sel_trans].trans = 0; set_toast("Transição removida")
			}
			sel_trans = -1
		} else if seg_marks_count() > 1 {
			// deletar GRUPO: remove os marcados de índice MAIOR p/ MENOR (a compactação não
			// invalida os índices menores). Deixa os vãos (ripple=false) p/ não embaralhar o resto.
			n := seg_marks_count()
			for k := nsegs - 1; k >= 0; k -= 1 do if seg_marked[k] do remove_seg(k, false)
			seg_clear_marks(); selected = -1
			set_toast(rl.TextFormat("%d clipes removidos", n))
		} else if selected >= 0 {
			remove_seg(selected, !alt_down())
		}
	}

	// atalhos de transporte
	//  espaço = play/pause | ←/→ = 1 frame (Shift = 1s) | Home/End = início/fim
	//  S = dividir no playhead | B = ferramenta lâmina | F = ajustar à janela | Esc = sair da lâmina
	if rl.IsKeyPressed(.F3) do prof_show = !prof_show // HUD do profiler (global, mede o custo da main thread)
	if rl.IsKeyPressed(.F4) do dbg_toggle() // liga/desliga o log de diagnóstico do decoder (arquivo ao lado do .exe)
	if rl.IsKeyPressed(.SPACE) && !txt_edit && !search_focus do toggle_play() // espaço: ciente do modo prévia
	if rl.IsKeyPressed(.ESCAPE) {
		if search_focus do search_focus = false // sai da busca primeiro
		else if txt_edit do txt_edit = false // depois da edição de texto
		else if crop_mode do crop_mode = false // sai do modo recorte
		else if fullscreen_preview do toggle_fullscreen_preview()
		else if src_preview >= 0 do exit_src_preview()
		else if sel_trans >= 0 do sel_trans = -1 // Esc desseleciona a transição
		blade_mode = false
	}
	if src_preview < 0 && !ctrl && !txt_edit && !search_focus { // atalhos de edição da timeline (não digitando; Ctrl reservado)
		if rl.IsKeyPressed(.S) do split_at_playhead()
		if rl.IsKeyPressed(.B) do blade_mode = !blade_mode
		if rl.IsKeyPressed(.F) do tl_fit(g_view_w) // ajusta o zoom p/ o conteúdo caber na janela
		vs := view_seg() // passo de 1 frame segue o fps do clipe sob o playhead (60fps -> 1/60)
		step := (rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)) ? f32(1) : (vs >= 0 ? 1.0 / cfps_of(seg_src(vs)) : 1.0 / DEC_FPS)
		if rl.IsKeyPressed(.RIGHT) || rl.IsKeyPressedRepeat(.RIGHT) { st.playing = false; seek_global(st.playhead + step) }
		if rl.IsKeyPressed(.LEFT)  || rl.IsKeyPressedRepeat(.LEFT)  { st.playing = false; seek_global(st.playhead - step) }
		if rl.IsKeyPressed(.HOME) { st.playing = false; seek_global(0) }
		if rl.IsKeyPressed(.END)  { st.playing = false; seek_global(timeline_dur()) }
	}

	// colocação automática (import_media com place=true): cria o segmento assim
	// que a fonte é sondada (a duração só é conhecida depois do probe).
	for i in 0 ..< nclips {
		c := &clips[i]
		if c.autoplace && !c.seg_made && media_ready(i) {
			if add_seg(i, timeline_dur(), 0, c.dur) >= 0 do c.seg_made = true
			else do c.autoplace = false // timeline lotada: desiste (o add_seg já avisou)
		}
	}

	snap_line = -1 // recalculado a cada frame durante o arrasto
	bin_drop_show = false; bin_drop_newtrack = false // prévia do footprint do bin (recalculada no ramo .Bin abaixo)

	// arrasto: mover playhead (scrub), mover/aparar um segmento, ou soltar do bin
	if st.drag == .Playhead {
		st.playhead = clamp(tl_t(m.x), 0, timeline_dur())
		vc := view_seg()
		// se o seg de topo é uma vista DUPLICADA, NÃO escreve na textura da fonte com
		// o tempo dele (corrompia a camada do dono, que usa a mesma textura) — a vista
		// dup é atualizada pelo tick por-frame (dup_frame) com textura própria
		if vc >= 0 && !seg_is_dup(vc) {
			src := seg_src(vc)
			local := seg_local(vc, st.playhead)
			if !src.streaming {
				clip_show(src, int(local * cfps_of(src))) // cache: preview ao vivo, direto da RAM
			} else {
				// streaming: delega o frame ao worker async (não trava a UI); keyframes
				// chegam conforme o decode dá (num arquivo de HORAS cada spawn paga o
				// parse do índice, ~centenas de ms) e a MINIATURA cobre o meio-tempo.
				// NOTA: houve uma tentativa de "arrasto suave" (ler o pipe do decoder ao
				// vivo sequencialmente + respawns de convergência) — REVERTIDA: a
				// oscilação entre os modos degradava a sessão com o tempo (preview preso
				// na miniatura, worker descartado, loop de respawns). Se voltar ao tema,
				// o caminho certo é um decoder PERSISTENTE de scrub por clipe.
				intrinsics.atomic_store(&scrub_req_c, segs[vc].src)
				scrub_req_t = local
			}
		}
	} else if st.drag == .Clip && drag_clip >= 0 && drag_clip < nsegs {
		sg := &segs[drag_clip]
		src := seg_src(drag_clip)
		mt := tl_t(m.x)
		if drag_trim == 0 && seg_marks_count() > 1 && seg_marked[drag_clip] {
			// MOVER EM GRUPO: desloca todos os marcados pelo mesmo Δt (tempo) E Δtrilha (vertical),
			// RÍGIDO — o grupo move junto ou não move na vertical. Se ao aplicar o mesmo Δtrilha
			// QUALQUER marcado sair da sua faixa de tipo (vídeo/áudio), cancela o vertical (dtr=0);
			// nunca clampa um só (era o bug: um movia e o outro travava no limite). Bloqueadas fora.
			in_range :: proc(k, t: int) -> bool { // t cabe na faixa do TIPO do seg k? (e não é travada)
				if t >= 0 && t < MAXTRACKS && track_locked[t] do return false // não solta em trilha travada
				return is_audio_track(segs[k].track) ? (t >= MAXV && t < MAXV + g_na) : (t >= 0 && t < g_nv)
			}
			want := max(0, mt - grab_dt)
			delta := want - sg.start
			tgt := clamp(track_at_y(m.y), is_audio_track(segs[drag_clip].track) ? MAXV : 0, is_audio_track(segs[drag_clip].track) ? MAXV + g_na - 1 : g_nv - 1)
			dtr := tgt - segs[drag_clip].track // deslocamento vertical desejado (do clipe agarrado)
			minstart := f32(1e30)
			for k in 0 ..< nsegs do if seg_marked[k] && !track_locked[segs[k].track] && segs[k].start < minstart do minstart = segs[k].start
			if minstart + delta < 0 do delta = -minstart // não deixa ninguém ir p/ antes de 0
			// vertical só se TODOS couberem; senão trava (sem trilha disponível = não move)
			if dtr != 0 do for k in 0 ..< nsegs {
				if !seg_marked[k] || track_locked[segs[k].track] do continue
				if !in_range(k, segs[k].track + dtr) { dtr = 0; break }
			}
			check :: proc(d: int, dl: f32) -> bool { // nenhum marcado invade um não-marcado?
				for k in 0 ..< nsegs {
					if !seg_marked[k] || track_locked[segs[k].track] do continue
					if overlaps_nonmarked(segs[k].track + d, segs[k].start + dl, segs[k].dur) do return false
				}
				return true
			}
			ok := check(dtr, delta)
			if !ok && dtr != 0 { dtr = 0; ok = check(0, delta) } // vertical bloqueado: tenta só horizontal
			if ok && (abs(delta) > 0.0001 || dtr != 0) {
				for k in 0 ..< nsegs {
					if !seg_marked[k] || track_locked[segs[k].track] do continue
					segs[k].track += dtr
					segs[k].start = max(0, segs[k].start + delta)
				}
			}
		} else if drag_trim == 0 { // mover ÚNICO: pode trocar de trilha (Y do mouse) e de posição
			ntr := track_for_seg(drag_clip, track_at_y(m.y)) // respeita vídeo/áudio (e só-áudio)
			if track_locked[ntr] do ntr = sg.track // trilha travada não recebe: fica na atual
			cand := snap_start(ntr, drag_clip, max(0, mt - grab_dt), sg.dur)
			if !overlaps_any(ntr, drag_clip, cand, sg.dur) { sg.start = cand; sg.track = ntr }
			else do snap_line = -1 // rejeitado: não mostra guia num lugar onde não foi
		} else if drag_trim < 0 { // aparar a borda esquerda (mantém o fim fixo)
			old_end := sg.start + sg.dur
			spd := seg_speed(drag_clip)
			// limites: in_off >= 0 (nada antes da fonte), fim do vizinho à esquerda, dur > 0.
			// in_off zera quando o início recua sg.in_off/speed na timeline.
			lo := max(sg.start - sg.in_off / spd, left_wall(sg.track, drag_clip, sg.start + 0.001))
			new_start := clamp(mt, lo, old_end - 0.05)
			sg.in_off += (new_start - sg.start) * spd
			sg.start = new_start
			sg.dur = old_end - new_start
		} else { // aparar a borda direita (mantém o início fixo)
			// limites: fim da fonte e início do vizinho à direita. Imagem/TEXTO = still sem
			// fim real: pode esticar livremente (cap alto), só respeitando o vizinho.
			srcdur := (src.is_img || src.is_text) ? f32(3600) : src.dur
			// a fonte restante (srcdur - in_off) rende (srcdur - in_off)/speed na timeline
			max_end := min(sg.start + (srcdur - sg.in_off) / seg_speed(drag_clip), right_wall(sg.track, drag_clip, sg.start + 0.05))
			sg.dur = clamp(mt, sg.start + 0.05, max_end) - sg.start
		}
	} else if st.drag == .FadeIn && drag_clip >= 0 && drag_clip < nsegs {
		sg := &segs[drag_clip]
		sg.fade_in = clamp(tl_t(m.x) - sg.start, 0, sg.dur)
		if sg.fade_in + sg.fade_out > sg.dur do sg.fade_in = max(0, sg.dur - sg.fade_out)
	} else if st.drag == .FadeOut && drag_clip >= 0 && drag_clip < nsegs {
		sg := &segs[drag_clip]
		sg.fade_out = clamp((sg.start + sg.dur) - tl_t(m.x), 0, sg.dur)
		if sg.fade_in + sg.fade_out > sg.dur do sg.fade_out = max(0, sg.dur - sg.fade_in)
	} else if st.drag == .TransDur && drag_clip >= 0 && drag_clip < nsegs {
		// arrastar uma alça do dissolver/fade selecionado. Mínimo 0.2s (remover é pelo
		// Delete/X). O tipo vem de sel_trans_kind (consistente: só se arrasta o selecionado).
		sg := &segs[drag_clip]
		switch sel_trans_kind {
		case 1: // fade preto de entrada: largura = distância da borda esquerda
			sg.vfin  = clamp(tl_t(m.x) - sg.start, 0.1, max(f32(0.2), sg.dur*0.9))
		case 2: // fade preto de saída: largura = distância da borda direita
			sg.vfout = clamp((sg.start + sg.dur) - tl_t(m.x), 0.1, max(f32(0.2), sg.dur*0.9))
		case: // dissolver: D é SIMÉTRICO no corte, distância do mouse ao corte = D/2
			half := abs(tl_t(m.x) - sg.start)
			sg.trans = clamp(half * 2, 0.2, trans_max(drag_clip))
		}
	} else if st.drag == .Vol && drag_clip >= 0 && drag_clip < nsegs {
		frac := clamp((g_vby1 - m.y) / (g_vby1 - g_vby0), 0, 1) // base=0, topo=VOL_MAX
		v := frac * VOL_MAX
		if abs(v - 1) < 0.06 * VOL_MAX do v = 1 // gruda em 100%
		segs[drag_clip].vol = v
	} else if st.drag == .PreviewMove && drag_clip >= 0 && drag_clip < nsegs && g_frame.width > 0 {
		sg := &segs[drag_clip]
		ccx := m.x - prev_grab.x; ccy := m.y - prev_grab.y // move o centro do clipe no preview
		px := clamp((ccx - (g_frame.x + g_frame.width/2)) / g_frame.width, -1.5, 1.5)
		py := clamp((ccy - (g_frame.y + g_frame.height/2)) / g_frame.height, -1.5, 1.5)
		// tamanho EXIBIDO do clipe (frações) p/ alinhar as BORDAS ao canvas, além do centro
		s := sg.scale <= 0 ? f32(1) : sg.scale
		_, _, crw, crh := seg_crop_at(drag_clip, st.playhead)
		cr := dec_content_rect(seg_src(drag_clip)) // quadro da fonte = conteúdo (mesmo do draw)
		cwpx := crw*cr.width; chpx := crh*cr.height
		tf := min(g_frame.width/cwpx, g_frame.height/chpx)
		hwf := (cwpx*tf*s/2) / g_frame.width  // meia-largura (fração do frame)
		hhf := (chpx*tf*s/2) / g_frame.height // meia-altura
		T :: f32(0.02) // limiar de encaixe (~2% do frame)
		g_pv_x = -1; g_ph_y = -1
		// X: centro do canvas (0) ou bordas esquerda/direita
		if      abs(px)               < T { px = 0;          g_pv_x = g_frame.x + g_frame.width/2 }
		else if abs(px - (-0.5+hwf))  < T { px = -0.5+hwf;   g_pv_x = g_frame.x }
		else if abs(px - ( 0.5-hwf))  < T { px =  0.5-hwf;   g_pv_x = g_frame.x + g_frame.width }
		// Y: centro ou bordas topo/base
		if      abs(py)               < T { py = 0;          g_ph_y = g_frame.y + g_frame.height/2 }
		else if abs(py - (-0.5+hhf))  < T { py = -0.5+hhf;   g_ph_y = g_frame.y }
		else if abs(py - ( 0.5-hhf))  < T { py =  0.5-hhf;   g_ph_y = g_frame.y + g_frame.height }
		sg.px = px; sg.py = py
	} else if st.drag == .FxCenter && drag_clip >= 0 && drag_clip < nsegs && g_frame.width > 0 {
		sg := &segs[drag_clip] // arrastar o centro da distorção: mouse -> bulge_x/bulge_y (local)
		s := sg.scale <= 0 ? f32(1) : sg.scale
		ccx := g_frame.x + g_frame.width/2 + sg.px*g_frame.width
		ccy := g_frame.y + g_frame.height/2 + sg.py*g_frame.height
		rw := g_frame.width*s; rh := g_frame.height*s
		rad := sg.rot * math.PI/180; cs_ := math.cos(rad); sn := math.sin(rad)
		dx := m.x - ccx; dy := m.y - ccy // des-rotaciona p/ o plano do clipe
		ux := dx*cs_ + dy*sn; uy := -dx*sn + dy*cs_
		sg.bulge_x = clamp(ux/rw, -0.5, 0.5); sg.bulge_y = clamp(uy/rh, -0.5, 0.5)
		if abs(sg.bulge_x) < 0.02 do sg.bulge_x = 0
		if abs(sg.bulge_y) < 0.02 do sg.bulge_y = 0
	} else if st.drag == .FxCtr && fx_sel >= 0 && fx_sel < nfx && g_frame.width > 0 {
		f := &fxsegs[fx_sel] // centro da distorção do CLIPE DE EFEITO (relativo ao quadro)
		// SEM encaixe no meio: a "zona morta" fazia o centro pular pro meio (parecia um ímã)
		f.cx = clamp((m.x - (g_frame.x + g_frame.width/2)) / g_frame.width, -0.5, 0.5)
		f.cy = clamp((m.y - (g_frame.y + g_frame.height/2)) / g_frame.height, -0.5, 0.5)
	} else if st.drag == .Bin && bin_drag >= 0 && bin_drag < nclips {
		over_newv := !clips[bin_drag].is_audio && g_nv < MAXV && rl.CheckCollisionPointRec(m, g_newv_zone)
		over_newa :=  clips[bin_drag].is_audio && g_na < MAXA && rl.CheckCollisionPointRec(m, g_newa_zone)
		if over_newv || over_newa {
			// sobre a banda "+ trilha": já mostra o footprint onde o clipe cairá na trilha NOVA
			// (trilha vazia = sem empurrão; começa no cursor adiantado). O drop cria a trilha.
			bin_drop_start = max(0, tl_t(m.x - DROP_LEAD)); bin_drop_dur = clips[bin_drag].dur
			bin_drop_zone = over_newv ? g_newv_zone : g_newa_zone
			bin_drop_newtrack = true; bin_drop_show = true
		} else if rl.CheckCollisionPointRec(m, g_vlane) {
			tr := track_for_media(bin_drag, track_at_y(m.y))
			s := snap_start(tr, -1, max(0, tl_t(m.x - DROP_LEAD)), clips[bin_drag].dur) // guia (adiantado)
			// footprint real do drop (empurra p/ espaço livre, igual ao drop) — mostra onde vai ficar
			bin_drop_tr = tr; bin_drop_start = free_start(tr, -1, s, clips[bin_drag].dur)
			bin_drop_dur = clips[bin_drag].dur; bin_drop_show = true
		}
	} else if st.drag == .FxClip && fx_sel >= 0 && fx_sel < nfx {
		f := &fxsegs[fx_sel]
		ty := track_at_y(m.y)                                        // trilha de vídeo sob o cursor
		tr := is_audio_track(ty) ? f.track : clamp(ty, 0, g_nv - 1)  // efeito só em trilha de vídeo
		cand := max(0, tl_t(m.x) - fx_grab_dt)
		if !fx_busy(tr, fx_sel, cand, f.dur) { f.start = cand; f.track = tr } // EXCLUSIVO: rejeita se invadir seg/efeito
	} else if st.drag == .FxTrim && fx_sel >= 0 && fx_sel < nfx {
		f := &fxsegs[fx_sel]
		maxend := fx_wall_r(f.track, fx_sel, f.start + 0.05)          // não passa por cima do vizinho
		f.dur = clamp(tl_t(m.x), f.start + 0.3, maxend) - f.start
	}
	if released {
		if st.drag == .FxLib && fxlib_drag >= 0 { // soltar um efeito da biblioteca -> clipe de efeito NUMA TRILHA
			ty := track_at_y(m.y)
			tr := -1
			if g_nv < MAXV && rl.CheckCollisionPointRec(m, g_newv_zone) do tr = add_video_track() // banda "+ trilha": cria uma nova
			else if rl.CheckCollisionPointRec(m, g_vlane) && !is_audio_track(ty) do tr = clamp(ty, 0, g_nv - 1)
			if tr >= 0 {
				start := fx_free_start(tr, -1, max(0, tl_t(m.x - DROP_LEAD)), 3) // empurra p/ um vão livre (não cai sobre seg/efeito)
				add_fxseg(fxlib_drag, start, tr)
			} else do set_toast("Solte o efeito sobre uma trilha de vídeo")
			fxlib_drag = -1
		}
		if was_ph do seek_global(st.playhead)
		if was_clip {
			// soltar um clipe ÚNICO (não em grupo, não aparando) numa banda "criar trilha":
			// cria a trilha do tipo certo e move o clipe pra ela.
			if drag_clip >= 0 && drag_clip < nsegs && drag_trim == 0 && !(seg_marks_count() > 1 && seg_marked[drag_clip]) {
				aud := seg_audio_like(drag_clip)
				nt := -1
				if      !aud && g_nv < MAXV && rl.CheckCollisionPointRec(m, g_newv_zone) do nt = add_video_track()
				else if  aud && g_na < MAXA && rl.CheckCollisionPointRec(m, g_newa_zone) do nt = add_audio_track()
				if nt >= 0 {
					segs[drag_clip].track = nt
					segs[drag_clip].start = free_start(nt, drag_clip, segs[drag_clip].start, segs[drag_clip].dur)
				}
			}
			seek_global(st.playhead); drag_clip = -1; drag_trim = 0
		}
		if was_bin { // soltar item(ns) do bin numa trilha (definida pelo Y) -> cria segmentos
			// bandas "criar trilha": soltar mídia compatível na banda cria a trilha e larga nela
			over_newv := bin_drag >= 0 && bin_drag < nclips && !clips[bin_drag].is_audio && g_nv < MAXV && rl.CheckCollisionPointRec(m, g_newv_zone)
			over_newa := bin_drag >= 0 && bin_drag < nclips &&  clips[bin_drag].is_audio && g_na < MAXA && rl.CheckCollisionPointRec(m, g_newa_zone)
			if bin_drag >= 0 && bin_drag < nclips && (over_newv || over_newa || rl.CheckCollisionPointRec(m, g_vlane)) {
				tgt := over_newv ? add_video_track() : over_newa ? add_audio_track() : track_at_y(m.y)
				cursor := max(0, tl_t(m.x - DROP_LEAD)) // início adiantado (encaixa no começo)
				nm := bin_marks_count()
				placed := 0
				last_name: cstring = ""
				for k in 0 ..< nclips {
					use := nm > 0 ? bin_marked[k] : (k == bin_drag) // marcados; senão só o arrastado
					if !use || intrinsics.atomic_load(&clips[k].failed) || !media_ready(k) do continue
					c := &clips[k]
					tr := track_for_media(k, tgt) // áudio->trilha de áudio, vídeo/imagem->vídeo
					if track_locked[tr] { set_toast("Trilha bloqueada"); continue } // não solta em trilha travada
					start := snap_start(tr, -1, cursor, c.dur)
					start = free_start(tr, -1, start, c.dur) // espaço livre (sem invadir)
					if add_seg(k, start, 0, c.dur, tr) >= 0 {
						placed += 1; cursor = start + c.dur; last_name = cs(c.name) // enfileira o próximo
					}
				}
				seek_global(st.playhead)
				if placed == 1      do set_toast(rl.TextFormat("%s na timeline", last_name))
				else if placed > 1  do set_toast(rl.TextFormat("%d mídias na timeline", placed))
			}
			bin_drag = -1
		}
		if was_trans { // soltar uma transição: na timeline aplica no corte/clipe sob o cursor
			if rl.CheckCollisionPointRec(m, g_vlane) {
				si := seg_on_track_at(track_at_y(m.y), tl_t(m.x))
				if si >= 0 && track_locked[segs[si].track] do set_toast("Trilha bloqueada")
				else if si >= 0 do apply_transition_at(si, trans_drag, tl_t(m.x))
				else do set_toast("Solte sobre um clipe")
			} else {
				apply_transition(trans_drag) // fora da timeline = aplica ao selecionado (clique)
			}
			trans_drag = -1
		}
		st.drag = .None
		drag_clip = -1 // fade/volume também soltam aqui
		snap_line = -1
	}

	// scrub streaming: sobe o frame que o worker decodificou (só na main thread);
	// fora do scrub, deixa o worker ocioso.
	if st.drag != .Playhead do intrinsics.atomic_store(&scrub_req_c, -1)
	if intrinsics.atomic_load(&scrub_ready) {
		dc := scrub_done_c
		// NÃO sobe o frame de scrub durante o PLAYBACK: um scrub tardio (o worker ainda estava
		// decodificando o último ponto arrastado quando você soltou e deu play) plantaria um frame
		// de OUTRO tempo por 1 frame por cima do vídeo = "imagem rápida aparecendo" (flash). Só
		// adota quando NÃO está tocando (arrasto/pausa), onde o frame de scrub é o que deve aparecer.
		if !st.playing && dc >= 0 && dc < nclips && !clips[dc].closed && scrub_done_sf == cframe(&clips[dc]) {
			upload_tex(&clips[dc], rawptr(raw_data(scrub_buf)))
			clips[dc].tex_t = scrub_done_t // frame do scrub: vale pelo tempo PEDIDO (keyframe ≈ perto)
		} else if st.playing && dc >= 0 {
			dbg("SCRUBDROP", "descartado frame de scrub tardio t=%.1fs durante o playback (evita FLASH)", scrub_done_t)
		}
		intrinsics.atomic_store(&scrub_ready, false)
	}
	dup_poll() // adota spawns das vistas duplicadas (mesma fonte em 2 trilhas) e limpa slots mortos
	// mantém as vistas dup atualizadas TODO frame (pausado, drop, trim, scrub): fora
	// do playback o show_playhead_frame não roda, e sem isto a camada de cima ficava
	// congelada no fallback (mesmo frame do dono) até dar play. Barato: cache é no-op
	// quando o frame não mudou; streaming lê no máx 2 frames do pipe próprio.
	if src_preview < 0 && modal == .None {
		for t in 0 ..< g_nv {
			if i := seg_on_track_at(t, st.playhead); i >= 0 && seg_is_dup(i) {
				dup_frame(i, seg_local(i, st.playhead))
			}
		}
	}

	// pausado e sem arrasto: re-dirige o frame do clipe sob o playhead TODO frame. Um
	// seek pausado num clipe STREAMING (ex.: clicar p/ voltar ao início) dispara um
	// respawn ASSÍNCRONO do decoder; se ele foi descartado (outro respawn no ar) ou
	// falhou, o clip_frame precisa ser chamado de novo p/ re-pedir — mas fora do
	// playback nada o chamava, e a imagem congelava no frame velho até dar play/seekar.
	// Barato: quando já está na posição, cache é no-op e o streaming não lê nada.
	// (durante arrasto do playhead o frame vem do worker de scrub, não daqui)
	if src_preview < 0 && modal == .None && st.drag == .None && !st.playing {
		show_playhead_frame()
	}

	// prévia de origem (duplo-clique no bin): caminho próprio, ignora a timeline
	if src_preview >= 0 {
		update_src_preview(dt)
		return
	}

	// playback: o segmento sob o playhead toca; o áudio da sua fonte é o relógio.
	// o segmento pode recortar só um trecho da fonte, então o FIM é in_off+dur
	// (não a duração da fonte). Espaços vazios / sem áudio avançam pelo relógio de parede.
	// arrastos de volume/fade NÃO movem o playhead — deixa tocar p/ ouvir a mudança ao vivo
	audio_edit := audio_edit_drag()
	if st.playing && (st.drag == .None || audio_edit) {
		a := audio_seg_at(st.playhead) // RELÓGIO = topo com áudio não-mudo (pode não ser o vídeo)
		when DBG_PLAY { // LOG TEMPORÁRIO de diagnóstico do congelamento
			mp := a >= 0 && seg_src(a).has_audio ? rl.IsMusicStreamPlaying(seg_src(a).music) : false
			ck := a >= 0 && seg_src(a).has_audio ? audio_clock_ok(seg_src(a), (st.playhead-segs[a].start)*seg_speed(a)+segs[a].in_off) : false
			fmt.eprintfln("[play] ph=%.3f dur=%.3f a=%d pc=%d mp=%v ck=%v", f64(st.playhead), f64(timeline_dur()), a, play_clip, mp, ck)
		}
		if a < 0 {
			// sem áudio na região (vão OU só vídeo mudo/overlay): avança pelo relógio de
			// parede e mostra o frame da trilha de topo (se houver)
			if play_clip >= 0 {
				if seg_src(play_clip).has_audio do rl.PauseMusicStream(seg_src(play_clip).music)
				play_clip = -1
			}
			st.playhead += dt
			if st.playhead >= timeline_dur() do st.playing = false
			else do show_playhead_frame()
		} else if seg_speed(a) != 1 {
			// VELOCIDADE != 1: NÃO usa o áudio da fonte como relógio (a reamostragem
			// mudaria o tom). Avança pelo relógio de PAREDE (duração de timeline correta)
			// e o som sai do WAV pré-renderizado (audio_speed_preview, tom preservado).
			if play_clip >= 0 {
				if seg_src(play_clip).has_audio do rl.PauseMusicStream(seg_src(play_clip).music)
				play_clip = -1
			}
			sg := &segs[a]
			nl := (st.playhead - sg.start) + dt
			if nl >= sg.dur do st.playhead = sg.start + sg.dur
			else { st.playhead = sg.start + nl; show_playhead_frame() }
		} else {
			sg := &segs[a]
			c := seg_src(a)
			loc0 := (st.playhead - sg.start) * seg_speed(a) + sg.in_off // posição na fonte
			out0 := seg_run_end(a)                       // fim da CADEIA contígua, na fonte
			if c.has_audio && audio_clock_ok(c, loc0) {
				// adquire o áudio ao entrar num segmento. Mas se já estamos tocando
				// a MESMA fonte e o áudio já está na posição certa (atravessamos um
				// corte interno), só troca o dono — SEM seek/resume. Era o seek na
				// borda que engasgava; agora o corte fica invisível pro playback.
				acquired := false // seek feito NESTE frame
				if play_clip != a {
					// Atravessamos um corte limpo se `a` é a continuação contígua do
					// segmento que já está tocando. Aí o áudio da fonte JÁ está na
					// posição certa — passa o dono sem seek. Critério estrutural (não
					// depende de tolerância de tempo), então funciona mesmo com o vídeo
					// streaming lento, onde o áudio avança muito num único frame.
					if play_clip >= 0 && rl.IsMusicStreamPlaying(c.music) && next_contiguous_seg(play_clip) == a {
						play_clip = a
					} else {
						set_play_clip(a, loc0)
						acquired = true
					}
				}
				// no frame do seek, GetMusicTimePlayed ainda não assentou (o buffer só
				// atualiza no próximo UpdateMusicStream) e reportava uma posição ANTES
				// do ponto buscado. O playhead derivado recuava pra fora do segmento,
				// caía no vão, e o frame seguinte fazia OUTRO seek — oscilação infinita
				// na borda de cortes separados (SEEKS disparava). Confia no loc0 pedido.
				local := acquired ? loc0 : rl.GetMusicTimePlayed(c.music) + c.music_base // posição na FONTE (chunk tem offset)
				// seek do seek_global neste frame: a leitura acima é stale — usa a posição pedida
				if !acquired && seek_pending do local = seek_pending_loc
				seek_pending = false
				// relógio MONOTÔNICO: GetMusicTimePlayed oscila p/ trás em até ~1
				// sub-buffer (pior com buffers grandes). O recuo espúrio disparava o
				// respawn "pulo p/ trás" do vídeo a cada oscilação (~250ms de bloqueio
				// cada -> picote). Durante playback contínuo o relógio nunca recua;
				// seeks reais passam por set_play_clip, que zera aud_prev.
				if !acquired && aud_prev >= 0 && local < aud_prev do local = aud_prev
					// proteção contra salto p/ FRENTE (metade que faltava do relógio monotônico):
					// num playback contínuo o relógio avança ~dt/frame. Um pulo > 3s num único
					// frame que NÃO é seek = glitch da troca de janela de áudio (head->chunk->OGG
					// recalcula music_base / GetMusicTimePlayed dessincroniza) — seguir cegamente
					// jogava o playhead lá na frente e o vídeo enlouquecia atrás (imagem virava
					// miniatura — "piora com o tempo" durante a extração do áudio). Segue no ritmo
					// normal e re-sincroniza no frame seguinte. 3s separa o glitch (100s+) de
					// qualquer hitch legítimo (< 1s de áudio por frame). Seeks reais têm aud_prev=-1.
					if aud_prev >= 0 && local > aud_prev + 3.0 {
						dbg_jmp_n += 1; dbg_jmp_from = aud_prev; dbg_jmp_to = local
						dbg_jmp_gmtp = rl.GetMusicTimePlayed(c.music); dbg_jmp_base = c.music_base
						dbg_jmp_loc0 = loc0; dbg_jmp_len = f32(c.music.frameCount) / f32(c.music.stream.sampleRate)
						dbg_jmp_acq = acquired; dbg_jmp_pend = seek_pending
						local = aud_prev + dt // avança no ritmo normal em vez do salto
					}
				// e nunca deixa o jitter do relógio recuar o playhead pra antes do
				// início do segmento (sairia dele e re-entraria em loop)
				if local < sg.in_off do local = sg.in_off
				// o stream parou mas AINDA FALTA segmento -> não é fim, é buffer que
				// esvaziou (hitch do respawn do decoder, loop modal do Windows ao
				// redimensionar, frame longo): retoma de onde estava. Antes exigia
				// dt > 0.25, então travadas curtas caíam no caso "fim" — pausava o
				// áudio e jogava o playhead pro fim da cadeia (mutava do nada).
				if !rl.IsMusicStreamPlaying(c.music) && local < out0 - 0.25 {
					// stream parou mas AINDA falta segmento -> underrun (buffer esvaziou
					// num hitch), não fim: retoma de onde estava.
					rl.ResumeMusicStream(c.music)
					// pode ser underrun OU o áudio da fonte é MAIS CURTO que o vídeo e
					// chegou ao fim — aí o Resume não traz de volta e GetMusicTimePlayed
					// fica congelado, prendendo o playhead aqui pra sempre. Avança pelo
					// relógio de PAREDE: underrun real re-sincroniza no próximo frame;
					// áudio acabado segue em silêncio até o fim do segmento.
					nl := (st.playhead - sg.start) + dt
					if nl >= sg.dur do st.playhead = sg.start + sg.dur
					else { st.playhead = sg.start + nl; show_playhead_frame() }
				} else if !rl.IsMusicStreamPlaying(c.music) || local >= out0 - 0.001 {
					rl.PauseMusicStream(c.music) // fim da cadeia (a fonte pode continuar)
					play_clip = -1
					st.playhead = sg.start + (out0 - sg.in_off) / seg_speed(a) // fim da cadeia, na timeline
				} else {
					// GRAVA um SALTO do playhead: o relógio de áudio mandou o playhead
					// pular > 2s num único frame de playback contínuo (não é seek). É o
					// bug "o cursor pula sozinho / imagem vai ficando ruim". Guarda o
					// estado do relógio no instante p/ o HUD mostrar POR QUE saltou.
					new_ph := sg.start + (local - sg.in_off) / seg_speed(a)
					if new_ph - st.playhead > 2.0 {
						dbg_jmp_n += 1; dbg_jmp_kind = 1
						dbg_jmp_from = st.playhead; dbg_jmp_to = new_ph
						dbg_jmp_gmtp = rl.GetMusicTimePlayed(c.music); dbg_jmp_base = c.music_base
						dbg_jmp_loc0 = loc0; dbg_jmp_len = f32(c.music.frameCount) / f32(c.music.stream.sampleRate)
						dbg_jmp_acq = acquired; dbg_jmp_pend = seek_pending
					}
					aud_prev = local
					// pré-busca: perto do fim da janela ativa e a próxima área ainda sem
					// parte pronta -> encomenda o chunk seguinte JÁ (troca sem gap na borda)
					cend := c.music_base + f32(c.music.frameCount) / f32(c.music.stream.sampleRate)
					if cend < out0 && local > cend - 15 {
						if int((cend + 1) / FULL_PART) >= intrinsics.atomic_load(&c.parts_done) {
							chunk_request(c, cend - 1)
						}
					}
					st.playhead = new_ph
					show_playhead_frame()
				}
			} else {
				// sem relógio de áudio na região: adota a parte pronta ou o chunk no
				// bolso; senão encomenda um chunk. O frame seguinte adquire e o som volta.
				if c.has_audio && !try_part_open(c, loc0) && !try_chunk_open(c, loc0) do chunk_request(c, loc0)
				if play_clip >= 0 {
					if seg_src(play_clip).has_audio do rl.PauseMusicStream(seg_src(play_clip).music)
					play_clip = -1
				}
				local := (st.playhead - sg.start) + dt // avanço no tempo da timeline
				if local >= sg.dur { st.playhead = sg.start + sg.dur }
				else { st.playhead = sg.start + local; show_playhead_frame() }
			}
		}
	}
	// mantém os buffers do áudio ativo alimentados + aplica volume/mudo/fade do
	// segmento SOB O PLAYHEAD (não o dono da cadeia: num run contíguo cada pedaço
	// tem o seu próprio ganho). SetMusicVolume age no stream compartilhado da fonte,
	// mas só um segmento toca por vez, então não há conflito.
	if st.playing && play_clip >= 0 && seg_src(play_clip).has_audio {
		rl.SetMusicVolume(seg_src(play_clip).music, seg_gain(play_clip, st.playhead) * player_vol) // × volume do player (monitor)
		rl.UpdateMusicStream(seg_src(play_clip).music)
	}
	audio_secondary() // mixa as trilhas de áudio (música de fundo) em sincronia com o master
	audio_speed_preview() // som dos segmentos com velocidade != 1 (tom preservado)
	history_tick()    // grava um passo de undo quando uma edição assenta

	// exportação terminou: avisa e limpa a thread (só a main mexe em toast/thread)
	running := intrinsics.atomic_load(&export_run)
	if export_was_running && !running {
		export_was_running = false
		if export_thr != nil { thread.join(export_thr); thread.destroy(export_thr); export_thr = nil }
		if export_prev_thr != nil { thread.join(export_prev_thr); thread.destroy(export_prev_thr); export_prev_thr = nil }
		if export_cancel { // cancelado: remove o arquivo parcial, não é falha
			if export_out != "" do os.remove(export_out)
			set_toast("Exportação cancelada")
		} else if export_ok { // abre o modal de conclusão (com prévia) em vez de só um toast
			if done_path != "" do delete(done_path)
			done_path = strings.clone(export_out)
			modal = .Done
			if g_done_snd_ok do rl.PlaySound(g_done_snd) // aviso sonoro: exportação concluída
		} else {
			set_toast("Falha na exportação")
		}
		export_cancel = false; export_paused = false
		for f in export_tmp_files { os.remove(f); delete(f) } // remove os PNGs de texto
		clear(&export_tmp_files)
	}
	if running do export_was_running = true
}

// abre a pasta no Explorer
open_folder :: proc(dir: string) {
	if p, e := os.process_start(os.Process_Desc{ command = []string{ "explorer", dir } }); e == nil do _ = p
}

// modal de exportar / screenshot / conclusão (desenhado por cima de tudo)
// abre "Configurações do Projeto" e carrega os campos com a resolução atual.
open_projset_modal :: proc() {
	modal = .ProjSettings
	tf_set(&tf_pw, fmt.tprintf("%d", proj_w))
	tf_set(&tf_ph, fmt.tprintf("%d", proj_h))
	ps_wf = false; ps_hf = false
}

// modal estilo NLE: chips de proporção (preenchem L×A) + campos de resolução + razão
// irredutível ao lado. OK grava proj_w/proj_h (usados no export e derivam proj_ar do preview).
draw_projset_modal :: proc(sw, sh: f32) {
	rl.DrawRectangleRec({0,0,sw,sh}, rl.Color{0,0,0,150}) // backdrop
	cw: f32 = 560; ch: f32 = 316
	cx := sw/2 - cw/2; cy := sh/2 - ch/2
	card := rl.Rectangle{ cx, cy, cw, ch }
	rl.DrawRectangleRounded(card, 0.04, 8, rl.Color{ 32, 35, 42, 255 })
	rl.DrawRectangleRoundedLinesEx(card, 0.04, 8, 1, LINE)
	txt("Configurações do Projeto", cx + 24, cy + 18, 18, TEXT)
	xr := rl.Rectangle{ cx + cw - 38, cy + 16, 24, 24 }
	if clicked(xr) do modal = .None
	rl.DrawLineEx({xr.x+6,xr.y+6},{xr.x+16,xr.y+16}, 1.8, hovered(xr) ? TEXT : MUTED)
	rl.DrawLineEx({xr.x+16,xr.y+6},{xr.x+6,xr.y+16}, 1.8, hovered(xr) ? TEXT : MUTED)

	lx := cx + 24
	// valores atuais dos campos (p/ destacar o chip ativo e mostrar a razão)
	cwv := strconv.parse_int(string(tf_pw.buf[:tf_pw.len])) or_else 0
	chv := strconv.parse_int(string(tf_ph.buf[:tf_ph.len])) or_else 0
	cur_ar := (cwv > 0 && chv > 0) ? f32(cwv)/f32(chv) : proj_ar

	// --- Proporção da Tela: chips de preset (preenchem L×A, lado menor = 1080) ---
	txt("Proporção da Tela:", lx, cy + 66, 14, TEXT)
	chx := lx + 158; chy := cy + 62
	for p, i in AR_PRESETS {
		bw := f32(54)
		br := rl.Rectangle{ chx + f32(i%5)*(bw+6), chy + f32(i/5)*30, bw, 24 }
		if ui_btn(br, p.label, abs(cur_ar - p.ar) < 0.005) {
			if p.ar >= 1 { tf_set(&tf_pw, fmt.tprintf("%d", int(f32(1080)*p.ar+0.5))); tf_set(&tf_ph, "1080") }
			else         { tf_set(&tf_pw, "1080"); tf_set(&tf_ph, fmt.tprintf("%d", int(f32(1080)/p.ar+0.5))) }
		}
	}

	// --- Resolução: L × A + razão irredutível ---
	ry := cy + 156
	txt("Resolução:", lx, ry + 5, 14, TEXT)
	wr := rl.Rectangle{ lx + 158, ry, 84, 28 }
	hr := rl.Rectangle{ wr.x + wr.width + 24, ry, 84, 28 }
	rl.DrawRectangleRounded(wr, 0.2, 4, PANEL2); rl.DrawRectangleRoundedLinesEx(wr, 0.2, 4, 1, ps_wf ? ACCENT : LINE)
	rl.DrawRectangleRounded(hr, 0.2, 4, PANEL2); rl.DrawRectangleRoundedLinesEx(hr, 0.2, 4, 1, ps_hf ? ACCENT : LINE)
	tf_field(&tf_pw, wr, &ps_wf, true)
	tf_field(&tf_ph, hr, &ps_hf, true)
	txt("×", wr.x + wr.width + 8, ry + 5, 16, MUTED)
	if cwv > 0 && chv > 0 do txt(rl.TextFormat("Proporção %s", ratio_label(cwv, chv)), hr.x + hr.width + 16, ry + 6, 13, MUTED)

	// --- Taxa de Frames (fixa neste editor) ---
	txt("Taxa de Frames:", lx, ry + 50, 14, TEXT)
	txt("30 fps  (fixo)", lx + 158, ry + 50, 14, MUTED)

	// OK / Cancelar
	if ui_btn({ cx + cw - 234, cy + ch - 52, 100, 36 }, "Cancelar", false) do modal = .None
	if ui_btn({ cx + cw - 124, cy + ch - 52, 100, 36 }, "OK", true) {
		w := strconv.parse_int(string(tf_pw.buf[:tf_pw.len])) or_else 0
		h := strconv.parse_int(string(tf_ph.buf[:tf_ph.len])) or_else 0
		if w >= 2 && h >= 2 && w <= 8192 && h <= 8192 {
			set_proj_res(w, h); ar_auto = false; dirty = true; modal = .None
			set_toast(rl.TextFormat("Projeto: %dx%d (%s)", i32(proj_w), i32(proj_h), ratio_label(proj_w, proj_h)))
		} else do set_toast("Resolução inválida — use algo como 1080 x 1920")
	}
}

// linha "Rótulo: valor" do painel de infos do modal de exportar.
mrow :: proc(x, y: f32, k, v: cstring) { txt(k, x, y, 13, MUTED); txt(v, x + 150, y, 13, TEXT) }

// tamanho ESTIMADO do arquivo (MB) p/ o modal. Aproximação (CRF = bitrate variável, por isso
// exibido com "~"): bitrate nominal por qualidade, escalado pela resolução; HEVC/VP9 ~40%
// menores; MP3 usa só o bitrate de áudio. Não faz probe (roda todo frame do modal).
export_est_size_mb :: proc(W, H: int, total: f32) -> f64 {
	if total <= 0 do return 0
	abr := 192.0e3 // áudio (AAC/Opus)
	if export_fmt == .MP3 {
		abr = export_qual == .High ? 320.0e3 : (export_qual == .Low ? 128.0e3 : 192.0e3)
		return (abr * f64(total) / 8) / 1e6
	}
	vbr := 6.0e6
	switch export_qual {
	case .High:   vbr = 12.0e6
	case .Medium: vbr = 6.0e6
	case .Low:    vbr = 3.0e6
	case .Auto:   vbr = 6.0e6 // estimativa; o real segue a fonte
	}
	vbr *= f64(W*H) / f64(1920*1080)                              // escala pela resolução
	if export_fmt == .HEVC || export_fmt == .WEBM do vbr *= 0.6   // codecs mais eficientes
	return ((vbr + abr) * f64(total) / 8) / 1e6
}

draw_modal :: proc(sw, sh: f32) {
	if modal == .None do return
	g_modal_draw = true
	defer g_modal_draw = false
	if modal == .Crop { draw_crop_modal(sw, sh); return } // modal próprio (frame + retângulo)
	if modal == .ProjSettings { draw_projset_modal(sw, sh); return } // proporção + resolução do projeto
	rl.DrawRectangleRec({0,0,sw,sh}, rl.Color{0,0,0,150}) // backdrop escuro
	cw: f32 = modal == .Export ? 700 : 540
	ch: f32 = modal == .Done ? 210 : (modal == .Confirm ? 190 : (modal == .Shot ? 250 : 430))
	cx := sw/2 - cw/2; cy := sh/2 - ch/2
	card := rl.Rectangle{ cx, cy, cw, ch }
	rl.DrawRectangleRounded(card, 0.04, 8, rl.Color{ 32, 35, 42, 255 })
	rl.DrawRectangleRoundedLinesEx(card, 0.04, 8, 1, LINE)
	title: cstring = modal == .Export ? "Exportar" : (modal == .Shot ? "Salvar screenshot" : (modal == .Confirm ? "Salvar alterações?" : "Exportação concluída"))
	txt(title, cx + 24, cy + 18, 18, TEXT)
	xr := rl.Rectangle{ cx + cw - 38, cy + 16, 24, 24 }
	if clicked(xr) { modal = .None; pending_action = .None } // fechar no X = cancelar a ação pendente
	rl.DrawLineEx({xr.x+6,xr.y+6},{xr.x+16,xr.y+16}, 1.8, hovered(xr) ? TEXT : MUTED)
	rl.DrawLineEx({xr.x+16,xr.y+6},{xr.x+6,xr.y+16}, 1.8, hovered(xr) ? TEXT : MUTED)

	if modal == .Confirm {
		txt("Há alterações não salvas na timeline.", cx + 24, cy + 62, 14, TEXT)
		txt("O que deseja fazer?", cx + 24, cy + 86, 14, MUTED)
		if ui_btn({ cx + 24, cy + ch - 52, 150, 36 }, "Salvar", true) {
			modal = .None
			if p, ok := save_dialog("Meu Projeto"); ok {
				save_project(ensure_ext(p, ".ovp"))
				do_pending()
			} else do pending_action = .None // cancelou o diálogo: aborta a ação
		}
		if ui_btn({ cx + 184, cy + ch - 52, 150, 36 }, "Não salvar", false) { modal = .None; do_pending() }
		if ui_btn({ cx + cw - 130, cy + ch - 52, 106, 36 }, "Cancelar", false) { modal = .None; pending_action = .None }
		return
	}

	if modal == .Done {
		txt("Arquivo salvo em:", cx + 24, cy + 64, 14, MUTED)
		dd := done_path; if len(dd) > 60 do dd = fmt.tprintf("...%s", dd[len(dd)-57:])
		txt(cs(dd), cx + 24, cy + 88, 13, TEXT)
		if ui_btn({ cx + 24, cy + ch - 52, 170, 36 }, "Reproduzir prévia", true) {
			preview_pending = import_media(done_path, false); modal = .None
		}
		if ui_btn({ cx + 204, cy + ch - 52, 130, 36 }, "Abrir pasta", false) { if d := dir_of(done_path); d != "" do open_folder(d) }
		if ui_btn({ cx + cw - 110, cy + ch - 52, 86, 36 }, "Fechar", false) do modal = .None
		return
	}

	// ---- modal EXPORTAR (barra de formatos à esquerda + painel de infos à direita) ----
	if modal == .Export {
		// barra lateral de FORMATOS à esquerda
		sbx := cx + 24; sby := cy + 56; sbw := f32(150); rowh := f32(46)
		FMT_LABELS := [ExportFmt]cstring{ .MP4 = "MP4", .HEVC = "HEVC", .WEBM = "WEBM", .MP3 = "MP3" }
		FMT_DESC   := [ExportFmt]cstring{ .MP4 = "H.264 · compatível", .HEVC = "H.265 · menor", .WEBM = "VP9 · web", .MP3 = "só áudio" }
		fi := 0
		for f in ExportFmt {
			rr := rl.Rectangle{ sbx, sby + f32(fi)*rowh, sbw, rowh - 6 }
			sel := export_fmt == f
			if sel        do rl.DrawRectangleRounded(rr, 0.18, 4, rl.Color{ 44, 48, 58, 255 })
			else if hovered(rr) do rl.DrawRectangleRounded(rr, 0.18, 4, PANEL)
			if sel do rl.DrawRectangleRec({ rr.x, rr.y + 6, 3, rr.height - 12 }, ACCENT)
			txt(FMT_LABELS[f], rr.x + 14, rr.y + 6, 15, TEXT)
			txt(FMT_DESC[f],   rr.x + 14, rr.y + 26, 10, MUTED)
			if clicked(rr) do export_fmt = f
			fi += 1
		}
		rl.DrawLineEx({ sbx + sbw + 14, cy + 52 }, { sbx + sbw + 14, cy + ch - 66 }, 1, LINE) // divisória

		// painel à direita
		px := sbx + sbw + 32; pw := cx + cw - 24 - px; py := cy + 58
		txt("Exportar para arquivo e salvar no computador", px, py, 12, MUTED); py += 28
		// Nome
		txt("Nome:", px, py + 6, 14, TEXT)
		nf := rl.Rectangle{ px + 84, py, pw - 84, 28 }
		rl.DrawRectangleRounded(nf, 0.2, 4, PANEL2)
		tf_field(&tf_name, nf, &name_focus, false)
		rl.DrawRectangleRoundedLinesEx(nf, 0.2, 4, 1, ACCENT)
		py += 40
		// Salvar em
		txt("Salvar em:", px, py + 6, 14, TEXT)
		df := rl.Rectangle{ px + 84, py, pw - 84 - 36, 28 }
		rl.DrawRectangleRounded(df, 0.2, 4, PANEL2)
		dds := save_dir; if len(dds) > 40 do dds = fmt.tprintf("...%s", dds[len(dds)-37:])
		txt(cs(dds), df.x + 8, df.y + 6, 12, MUTED)
		if ui_btn({ df.x + df.width + 6, py, 30, 28 }, "...", false) {
			if p, ok := save_dialog(name_str()); ok {
				if d := dir_of(p); d != "" { if save_dir != "" do delete(save_dir); save_dir = strings.clone(d) }
				b := p[len(dir_of(p)) + 1:]
				if dot := strings.last_index_byte(b, '.'); dot > 0 do b = b[:dot]
				set_name(b)
			}
		}
		py += 42
		// Predefinição (qualidade)
		txt("Qualidade:", px, py + 3, 14, TEXT)
		QLABELS := [ExportQual]cstring{ .High = "Alta", .Medium = "Média", .Low = "Baixa", .Auto = "Auto" }
		qx := px + 84
		for q in ExportQual {
			if ui_btn({ qx, py - 2, 66, 26 }, QLABELS[q], export_qual == q) do export_qual = q
			qx += 72
		}
		py += 40
		// infos
		W, H := export_dims()
		total := timeline_dur()
		ts := int(total + 0.5)
		if export_fmt == .MP3 {
			mrow(px, py, "Tipo:", "Áudio (MP3)"); py += 26
		} else {
			mrow(px, py, "Resolução:", rl.TextFormat("%dx%d", i32(W), i32(H))); py += 26
			mrow(px, py, "Taxa de Frames:", "30 fps"); py += 26
		}
		mrow(px, py, "Duração:", rl.TextFormat("%02d:%02d:%02d", i32(ts/3600), i32((ts%3600)/60), i32(ts%60))); py += 26
		est := export_est_size_mb(int(W), int(H), total)
		szs: cstring = est >= 1024 ? rl.TextFormat("~ %.2f GB", est/1024) : rl.TextFormat("~ %.0f MB", est)
		mrow(px, py, "Tamanho estimado:", szs); py += 32
		// GPU só existe p/ H.264/HEVC (NVENC); VP9 é sempre CPU
		if export_fmt == .MP4 || export_fmt == .HEVC {
			chk := rl.Rectangle{ px, py, 18, 18 }
			if clicked(chk) do export_gpu = !export_gpu
			rl.DrawRectangleRoundedLinesEx(chk, 0.2, 4, 1.5, export_gpu ? ACCENT : MUTED)
			if export_gpu do rl.DrawRectangleRec({ chk.x + 4, chk.y + 4, 10, 10 }, ACCENT)
			txt("Ativar codificação com GPU (NVENC)", px + 26, py + 2, 13, TEXT)
		} else if export_fmt == .WEBM {
			txt("VP9 codifica por CPU — export mais lento.", px, py + 2, 12, MUTED)
		}
		// botões
		if ui_btn({ cx + cw - 244, cy + ch - 52, 100, 36 }, "Cancelar", false) do modal = .None
		if ui_btn({ cx + cw - 134, cy + ch - 52, 110, 36 }, "Exportar", true) {
			if tf_name.len == 0 do set_toast("Digite um nome")
			else { start_export(fmt.tprintf("%s/%s%s", save_dir, name_str(), export_fmt_ext(export_fmt)), export_gpu); modal = .None }
		}
		return
	}

	// campo de NOME (cursor + seleção; foco automático enquanto o modal está aberto)
	lx := cx + 24; fy := cy + 62
	txt("Nome:", lx, fy + 6, 14, TEXT)
	nf := rl.Rectangle{ lx + 90, fy, cw - 90 - 48, 28 }
	rl.DrawRectangleRounded(nf, 0.2, 4, PANEL2)
	tf_field(&tf_name, nf, &name_focus, false) // allow_unfocus=false: o nome segue focado no modal
	rl.DrawRectangleRoundedLinesEx(nf, 0.2, 4, 1, ACCENT)
	fy += 42
	txt("Salvar em:", lx, fy + 6, 14, TEXT)
	df := rl.Rectangle{ lx + 90, fy, cw - 90 - 48 - 36, 28 }
	rl.DrawRectangleRounded(df, 0.2, 4, PANEL2)
	dd := save_dir; if len(dd) > 44 do dd = fmt.tprintf("...%s", dd[len(dd)-41:])
	txt(cs(dd), df.x + 8, df.y + 6, 13, MUTED)
	if ui_btn({ df.x + df.width + 6, fy, 30, 28 }, "...", false) { // procurar pasta (diálogo salvar)
		if p, ok := save_dialog(name_str()); ok {
			if d := dir_of(p); d != "" { if save_dir != "" do delete(save_dir); save_dir = strings.clone(d) }
			b := p[len(dir_of(p)) + 1:] // basename
			if dot := strings.last_index_byte(b, '.'); dot > 0 do b = b[:dot]
			set_name(b)
		}
	}
	fy += 46
	// modal SCREENSHOT (o Export tem seu próprio bloco acima e retorna antes daqui)
	txt("Formato:", lx, fy + 2, 14, MUTED)
	if ui_btn({ lx + 90, fy - 3, 60, 26 }, "PNG", shot_ext == 0) do shot_ext = 0
	if ui_btn({ lx + 156, fy - 3, 60, 26 }, "JPG", shot_ext == 1) do shot_ext = 1
	if ui_btn({ cx + cw - 234, cy + ch - 52, 100, 36 }, "Cancelar", false) do modal = .None
	if ui_btn({ cx + cw - 124, cy + ch - 52, 100, 36 }, "Salvar", true) {
		if tf_name.len == 0 { set_toast("Digite um nome") }
		else { take_screenshot(fmt.tprintf("%s/%s%s", save_dir, name_str(), shot_ext == 0 ? ".png" : ".jpg")); modal = .None }
	}
}

// ---------- profiler de seções (HUD, tecla F3) ----------
// Mede, por frame de UI, quanto tempo da MAIN THREAD vai em cada parte pesada:
// decode de vídeo (show_playhead_frame/dup), áudio (mix/spv/master), compositing do
// preview e desenho da timeline — além do total update/draw. É o que responde "o que
// consome mais". Vídeo/Áudio são subconjuntos de Update; Preview/Timeline de Draw.
// Re-entrante (nesting no MESMO bucket conta só o span externo — sem dupla contagem).
// Custo desprezível (~QPC por zona); sempre coletando, só o HUD é ligado no F3.
Prof :: enum { Update, Draw, Video, Audio, Preview, Timeline, Tl_Wave, Tl_Thumb }
prof_acc:    [Prof]f64 // ms somados na janela atual
prof_avg:    [Prof]f64 // média/frame da janela fechada (exibida no HUD)
prof_depth:  [Prof]int // re-entrância por bucket
prof_frames: int
prof_show:   bool

// GRAVADOR DE SALTOS do playhead (diagnóstico, HUD F3): captura o estado do relógio
// de áudio no INSTANTE de um pulo > 2s num único frame de playback — o bug histórico
// "dou play e o cursor pula do nada". Fica com o ÚLTIMO salto até o próximo.
dbg_jmp_n:    int
dbg_jmp_kind: int // 1=relógio(normal) 2=fim-da-cadeia
dbg_jmp_from, dbg_jmp_to: f32
dbg_jmp_gmtp, dbg_jmp_base, dbg_jmp_loc0, dbg_jmp_len: f32
dbg_jmp_acq, dbg_jmp_pend: bool
dbg_rsp_n:  int // respawns pedidos (stream_seek_async)
dbg_rsp_t:  f32 // alvo do último respawn
dbg_rsp_ph: f32 // playhead no instante do último respawn

prof_beg :: proc(p: Prof) -> time.Tick { prof_depth[p] += 1; return time.tick_now() }
prof_end :: proc(p: Prof, t0: time.Tick) {
	prof_depth[p] -= 1
	if prof_depth[p] == 0 do prof_acc[p] += time.duration_milliseconds(time.tick_diff(t0, time.tick_now()))
}
prof_tick :: proc() { // fecha a janela a cada 20 frames: guarda a média e zera
	prof_frames += 1
	if prof_frames >= 20 {
		inv := 1.0 / f64(prof_frames)
		for p in Prof { prof_avg[p] = prof_acc[p] * inv; prof_acc[p] = 0 }
		prof_frames = 0
	}
}
prof_hud :: proc() {
	if !prof_show do return
	// conta o que está sob o playhead agora (correlaciona custo × nº de mídias)
	nvid, nstream := 0, 0
	for t in 0 ..< g_nv {
		if i := seg_on_track_at(t, st.playhead); i >= 0 && !seg_src(i).is_text {
			nvid += 1
			if seg_src(i).streaming do nstream += 1
		}
	}
	// clipes com o NVDEC desligado (no_hw) NESTE momento: se este número CRESCE com o
	// uso, a GPU está sendo recusada por pressão de sessões e o decode degrada p/ software
	nhwoff := 0
	for k in 0 ..< nclips do if !clips[k].closed && clips[k].streaming && clips[k].no_hw do nhwoff += 1
	total := prof_avg[.Update] + prof_avg[.Draw]
	x, y := f32(12), f32(44)
	rl.DrawRectangleRec({ x - 6, y - 6, 268, 330 }, rl.Color{ 12, 14, 20, 232 })
	rl.DrawRectangleLinesEx({ x - 6, y - 6, 268, 330 }, 1, rl.Color{ 70, 80, 100, 255 })
	line :: proc(x, y: f32, label: cstring, ms: f64, warn: bool, indent := false) {
		c := warn ? rl.Color{ 250, 170, 90, 255 } : rl.Color{ 210, 218, 230, 255 }
		txt(label, x + (indent ? 12 : 0), y, 13, indent ? rl.Color{ 150, 165, 185, 255 } : c)
		txt(rl.TextFormat("%.2f ms", ms), x + 150, y, 13, c)
	}
	txt(rl.TextFormat("PROFILER  F3   %d fps", rl.GetFPS()), x, y, 13, rl.Color{ 120, 200, 250, 255 }); y += 20
	line(x, y, "update",    prof_avg[.Update],   prof_avg[.Update] > 8);  y += 17
	line(x, y, "video",     prof_avg[.Video],    prof_avg[.Video]  > 6, true); y += 17
	line(x, y, "audio",     prof_avg[.Audio],    prof_avg[.Audio]  > 3, true); y += 17
	line(x, y, "draw",      prof_avg[.Draw],     prof_avg[.Draw]   > 8);  y += 17
	line(x, y, "preview",   prof_avg[.Preview],  prof_avg[.Preview]> 5, true); y += 17
	line(x, y, "timeline",  prof_avg[.Timeline], prof_avg[.Timeline] > 6, true); y += 17
	line(x, y, "wave",      prof_avg[.Tl_Wave],  prof_avg[.Tl_Wave] > 4, true); y += 17
	line(x, y, "thumbs",    prof_avg[.Tl_Thumb], prof_avg[.Tl_Thumb] > 4, true); y += 17
	line(x, y, "TOTAL",     total,               total > 16.6);          y += 20
	txt(rl.TextFormat("%d video sob playhead (%d streaming)  hw-off:%d", nvid, nstream, nhwoff), x, y, 12,
		nhwoff > 0 ? rl.Color{ 250, 170, 90, 255 } : rl.Color{ 150, 165, 185, 255 }); y += 16
	// latência do decode assíncrono de scrub (thread própria — NÃO entra no total da main)
	if scrub_last_ms > 0 {
		shw := false; if vs := view_seg(); vs >= 0 do shw = seg_src(vs).scrub_hw
		txt(rl.TextFormat("scrub: %.0f ms/frame (%s) (ult. decode)", scrub_last_ms, shw ? cstring("HW") : cstring("SW")), x, y, 12,
			shw ? rl.Color{ 130, 210, 140, 255 } : rl.Color{ 150, 165, 185, 255 })
	}
	y += 16
	// --- estado do decoder do seg de vídeo sob o playhead (print isto p/ depurar) ---
	if vs := view_seg(); vs >= 0 && seg_src(vs).streaming {
		c := seg_src(vs)
		lt := seg_local(vs, st.playhead)
		gray := rl.Color{ 150, 165, 185, 255 }
		rsp := intrinsics.atomic_load(&c.rsp_busy)
		rt := rsp ? rl.GetTime() - c.rsp_t0 : 0
		txt(rl.TextFormat("live:%s%s  rsp:%s  no_hw:%s  eof=%.0f",
			c.live_on ? cstring("S") : cstring("N"), c.live_on ? (c.live_hw ? cstring("(hw)") : cstring("(sw)")) : cstring(""),
			rsp ? rl.TextFormat("%.1fs", rt) : cstring("nao"),
			c.no_hw ? cstring("SIM") : cstring("nao"), c.eof_at), x, y, 12,
			(rsp && rt > 2) ? rl.Color{ 250, 170, 90, 255 } : gray); y += 16
		thumbing := abs(lt - c.tex_t) > SCRUB_SHARP_S
		txt(rl.TextFormat("gap=%.2fs  tex_dt=%.2fs  MINIATURA:%s",
			lt - (c.live_base + f32(c.live_frame) / DEC_FPS), lt - c.tex_t,
			thumbing ? cstring("SIM") : cstring("nao")), x, y, 12,
			thumbing ? rl.Color{ 250, 170, 90, 255 } : gray); y += 15
		// números CRUS: qual está insano — o playhead, o tempo-fonte, ou o decoder?
		txt(rl.TextFormat("ph=%.1f lt=%.1f  lbase=%.1f lframe=%d", st.playhead, lt, c.live_base, c.live_frame), x, y, 12, gray); y += 15
		txt(rl.TextFormat("tex_t=%.1f  gmtp=%.1f base=%.1f", c.tex_t, rl.GetMusicTimePlayed(c.music), c.music_base), x, y, 12, gray); y += 15
		// último respawn: alvo pedido vs playhead no instante — quem manda o decoder longe?
		bad := abs(dbg_rsp_t - dbg_rsp_ph) > 3.0
		txt(rl.TextFormat("respawn #%d -> t=%.1f (ph era %.1f)", dbg_rsp_n, dbg_rsp_t, dbg_rsp_ph), x, y, 12,
			bad ? rl.Color{ 250, 120, 120, 255 } : gray); y += 3
		// SALTO do playhead capturado (bug "cursor pula sozinho"): quem mandou o pulo
		if dbg_jmp_n > 0 {
			txt(rl.TextFormat("SALTO #%d: %.1f -> %.1fs (+%.1fs)", dbg_jmp_n, dbg_jmp_from, dbg_jmp_to, dbg_jmp_to - dbg_jmp_from), x, y, 12, rl.Color{ 250, 120, 120, 255 }); y += 15
			txt(rl.TextFormat("  gmtp=%.1f base=%.1f len=%.1f", dbg_jmp_gmtp, dbg_jmp_base, dbg_jmp_len), x, y, 12, rl.Color{ 250, 170, 90, 255 }); y += 15
			txt(rl.TextFormat("  loc0=%.1f acq=%s pend=%s", dbg_jmp_loc0, dbg_jmp_acq ? cstring("S") : cstring("N"), dbg_jmp_pend ? cstring("S") : cstring("N")), x, y, 12, rl.Color{ 250, 170, 90, 255 })
		}
	}
}

// ---------- draw raiz ----------
draw :: proc() {
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())

	if fullscreen_preview { // modo tela cheia: só o vídeo
		draw_fullscreen_video(sw, sh)
		return
	}

	topbar_h  : f32 = 34
	toolbar_h : f32 = 64
	subbar_h  : f32 = 38
	tl_h := max(f32(250), sh * 0.34)
	tl_top := sh - tl_h
	content_top := topbar_h + toolbar_h + subbar_h
	media_w := sw * 0.47

	draw_topbar(sw, topbar_h)
	draw_toolbar(sw, topbar_h, toolbar_h)
	draw_subbar(topbar_h + toolbar_h, media_w, subbar_h)
	draw_media_panel(rl.Rectangle{ 0, content_top, media_w, tl_top - content_top })
	draw_preview(rl.Rectangle{ media_w, topbar_h + toolbar_h, sw - media_w, tl_top - (topbar_h + toolbar_h) })
	draw_timeline(rl.Rectangle{ 0, tl_top, sw, tl_h })

	// fantasma do item do bin sendo arrastado para a timeline (com contagem se forem vários)
	if st.drag == .Bin && bin_drag >= 0 && bin_drag < nclips {
		c := &clips[bin_drag]
		m := rl.GetMousePosition()
		nm := bin_marks_count()
		// FOOTPRINT: retângulo verde onde a mídia vai cair (posição + duração na trilha alvo)
		if bin_drop_show {
			if bin_drop_newtrack { // trilha NOVA: fantasma (altura de clipe) centrado na área de drop
				gh := min(bin_drop_zone.height - 8, g_track_h - 8)
				fy := bin_drop_zone.y + (bin_drop_zone.height - gh)/2
				fr := rl.Rectangle{ tl_x(bin_drop_start), fy, bin_drop_dur*pps(), gh }
				rl.DrawRectangleRec(fr, rl.Color{ 90, 200, 120, 60 })
				rl.DrawRectangleLinesEx(fr, 1.6, rl.Color{ 90, 200, 120, 235 })
				txt(cs(c.name), fr.x + 6, fr.y + 4, 11, rl.WHITE)
			} else {
				ok := !track_locked[bin_drop_tr] // trilha travada = não pode receber (vermelho)
				fr := rl.Rectangle{ tl_x(bin_drop_start), track_y(bin_drop_tr) + 4, bin_drop_dur*pps(), g_track_h - 8 }
				rl.DrawRectangleRec(fr, ok ? rl.Color{ 90, 200, 120, 60 } : rl.Color{ 200, 70, 70, 55 })
				rl.DrawRectangleLinesEx(fr, 1.6, ok ? rl.Color{ 90, 200, 120, 235 } : rl.Color{ 200, 70, 70, 235 })
			}
		}
		gr := rl.Rectangle{ m.x - 60, m.y - 20, 120, 40 }
		if c.tex_ok do rl.DrawTexturePro(c.tex, {0,0,f32(cdw(c)),f32(cdh(c))}, gr, {0,0}, 0, rl.Color{255,255,255,180})
		rl.DrawRectangleLinesEx(gr, 1, ACCENT)
		if nm > 1 { // badge com a quantidade sobre a pilha
			br := rl.Rectangle{ gr.x + gr.width - 14, gr.y - 8, 26, 20 }
			rl.DrawRectangleRounded(br, 0.5, 6, ACCENT)
			txt_c(rl.TextFormat("%d", nm), br.x + br.width/2, br.y + 3, 12, rl.WHITE)
		}
		over := rl.CheckCollisionPointRec(m, g_vlane) // sobre uma trilha existente
		lbl := over ? (nm > 1 ? rl.TextFormat("soltar %d aqui", nm) : cstring("soltar aqui")) : (nm > 1 ? rl.TextFormat("%d mídias", nm) : cs(c.name))
		txt_c(lbl, gr.x + 60, gr.y + 44, 11, over ? ACCENT : MUTED)
	}

	// fantasma da TRANSIÇÃO sendo arrastada + guia no corte alvo
	if st.drag == .Trans && trans_drag >= 0 {
		m := rl.GetMousePosition()
		names := []cstring{ "Dissolver", "Fade de entrada", "Fade de saída" }
		over := rl.CheckCollisionPointRec(m, g_vlane)
		if over { // marca o corte/borda alvo com uma linha vertical âmbar
			si := seg_on_track_at(track_at_y(m.y), tl_t(m.x))
			if si >= 0 {
				sg := segs[si]
				edge := sg.start // dissolver esquerda / fade entrada
				if trans_drag == 0 && tl_t(m.x) > sg.start + sg.dur/2 do edge = sg.start + sg.dur // dissolver direita
				if trans_drag == 2 do edge = sg.start + sg.dur // fade saída
				ex := tl_x(edge)
				rl.DrawLineEx({ ex, g_vlane.y }, { ex, g_vlane.y + g_vlane.height }, 2.5, rl.Color{ 245, 200, 90, 235 })
			}
		}
		gr := rl.Rectangle{ m.x - 56, m.y - 16, 112, 30 }
		rl.DrawRectangleRounded(gr, 0.3, 6, rl.Color{ 40, 44, 54, 230 })
		rl.DrawRectangleRoundedLinesEx(gr, 0.3, 6, 1, over ? ACCENT : LINE)
		txt_c(trans_drag < len(names) ? names[trans_drag] : "Transição", gr.x + 56, gr.y + 7, 12, over ? ACCENT : TEXT)
	}

	if toast_t > 0 {
		w := txt_w(toast_msg, 14) + 28
		r := rl.Rectangle{ sw/2 - w/2, 46, w, 30 }
		a := u8(clamp(toast_t / 3 * 255, 0, 230))
		rl.DrawRectangleRounded(r, 0.4, 8, rl.Color{ 40, 44, 54, a })
		rl.DrawRectangleRoundedLinesEx(r, 0.4, 8, 1, rl.Color{ ACCENT.r, ACCENT.g, ACCENT.b, a })
		txt_c(toast_msg, sw/2, 53, 14, rl.Color{ 235, 238, 242, a })
	}

	// overlay de progresso da exportação (centralizado) — com prévia ao vivo
	if intrinsics.atomic_load(&export_run) {
		// sobe o último frame recebido na textura (só a main mexe em GL)
		if export_prev_tex_ok {
			seq := intrinsics.atomic_load(&export_prev_seq)
			if seq != export_prev_last {
				pub := intrinsics.atomic_load(&export_prev_pub)
				if pub == 0 do rl.UpdateTexture(export_prev_tex, rawptr(raw_data(export_prev_a)))
				else if pub == 1 do rl.UpdateTexture(export_prev_tex, rawptr(raw_data(export_prev_b)))
				export_prev_last = seq
			}
		}
		pw: f32 = 384; ph: f32 = 216 // prévia 16:9 (mesmo enquadramento com letterbox)
		bw: f32 = pw + 48; bh: f32 = ph + 158
		bx := sw/2 - bw/2; by := sh/2 - bh/2
		rl.DrawRectangleRec({ 0, 0, sw, sh }, rl.Color{ 0, 0, 0, 120 }) // escurece o fundo
		rl.DrawRectangleRounded({ bx, by, bw, bh }, 0.06, 8, rl.Color{ 30, 33, 40, 255 })
		rl.DrawRectangleRoundedLinesEx({ bx, by, bw, bh }, 0.06, 8, 1, LINE)
		txt(export_paused ? "Exportação pausada" : "Exportando vídeo...", bx + 24, by + 16, 15, export_paused ? rl.Color{ 235, 200, 90, 255 } : TEXT)
		txt(rl.TextFormat("%d%%", i32(export_pct*100)), bx + bw - 60, by + 16, 15, ACCENT)
		// prévia
		pr := rl.Rectangle{ bx + 24, by + 42, pw, ph }
		rl.DrawRectangleRec(pr, rl.BLACK)
		if export_prev_tex_ok && intrinsics.atomic_load(&export_prev_seq) > 0 {
			rl.DrawTexturePro(export_prev_tex, { 0, 0, f32(PREV_W), f32(PREV_H) }, pr, { 0, 0 }, 0, rl.WHITE)
		} else {
			txt_c("preparando…", pr.x + pr.width/2, pr.y + pr.height/2 - 8, 13, MUTED)
		}
		if export_paused { // véu + ícone de pause sobre a prévia congelada
			rl.DrawRectangleRec(pr, rl.Color{ 0, 0, 0, 90 })
			bxr := pr.x + pr.width/2; byr := pr.y + pr.height/2
			rl.DrawRectangleRec({ bxr - 13, byr - 15, 8, 30 }, rl.Color{ 235, 238, 242, 230 })
			rl.DrawRectangleRec({ bxr + 5,  byr - 15, 8, 30 }, rl.Color{ 235, 238, 242, 230 })
		}
		rl.DrawRectangleLinesEx(pr, 1, LINE)
		// barra de progresso
		track := rl.Rectangle{ bx + 24, pr.y + ph + 16, bw - 48, 10 }
		rl.DrawRectangleRounded(track, 1, 6, rl.Color{ 50, 54, 64, 255 })
		rl.DrawRectangleRounded({ track.x, track.y, track.width * clamp(export_pct, 0, 1), track.height }, 1, 6, ACCENT)
		// botões: Pausar/Retomar + Cancelar (clique tratado no update; aqui só desenha)
		bw2 := (bw - 48 - 12) / 2
		byb := track.y + 24
		g_exp_pause_btn  = { bx + 24, byb, bw2, 34 }
		g_exp_cancel_btn = { bx + 24 + bw2 + 12, byb, bw2, 34 }
		draw_overlay_btn(g_exp_pause_btn, export_paused ? "Retomar" : "Pausar", ACCENT)
		draw_overlay_btn(g_exp_cancel_btn, "Cancelar", rl.Color{ 210, 80, 72, 255 })
	}

	draw_file_menu()   // dropdown do menu Arquivo (por cima da toolbar)
	draw_ctx_menu()    // menu de contexto da timeline (botão direito)
	draw_modal(sw, sh) // modais de exportar/screenshot/conclusão por cima de tudo
	// FEEDBACK de arraste de efeito: etiqueta flutuante seguindo o cursor
	if st.drag == .FxLib && fxlib_drag >= 0 {
		m := rl.GetMousePosition()
		nm := fxlib_name(fxlib_drag)
		wpx := txt_w(nm, 13) + 24
		box := rl.Rectangle{ m.x - wpx/2, m.y - 13, wpx, 26 } // CENTRADO no cursor (fica "em cima")
		rl.DrawRectangleRounded(box, 0.4, 6, rl.Color{ 40, 44, 56, 240 })
		rl.DrawRectangleRoundedLinesEx(box, 0.4, 6, 1.5, ACCENT)
		rl.DrawCircleV({ box.x + 12, box.y + 13 }, 4, ACCENT) // "grão" do efeito
		txt(nm, box.x + 22, box.y + 6, 13, TEXT)
	}
}

// ---------- menu de contexto da timeline (botão direito) ----------
CtxItem :: struct {
	label: cstring,
	on:    bool, // habilitado (desabilitado = cinza, clique só fecha)
	id:    int,  // ação estável (o layout muda conforme o alvo)
}

// monta os itens p/ o alvo atual (ctx_seg/-1). Retorna a contagem.
ctx_items :: proc(it: ^[10]CtxItem) -> int {
	n := 0
	if ctx_seg >= 0 && ctx_seg < nsegs && seg_ready(ctx_seg) {
		grp := seg_marks_count() > 1 && seg_marked[ctx_seg] // agir no grupo marcado
		sg := segs[ctx_seg]
		if grp do it[n] = { "Copiar grupo  (Ctrl+C)", true, 0 }
		else do it[n] = { "Copiar  (Ctrl+C)", true, 0 }
		n += 1
		if grp do it[n] = { "Recortar grupo  (Ctrl+X)", true, 1 }
		else do it[n] = { "Recortar  (Ctrl+X)", true, 1 }
		n += 1
		if grp do it[n] = { "Duplicar grupo  (Ctrl+D)", true, 2 }
		else do it[n] = { "Duplicar  (Ctrl+D)", true, 2 }
		n += 1
		it[n] = { "Colar aqui  (Ctrl+V)", seg_clipbrd_n > 0, 3 }; n += 1
		it[n] = { "Dividir aqui", ctx_time > sg.start + 0.05 && ctx_time < sg.start + sg.dur - 0.05, 4 }; n += 1
		if sg.muted do it[n] = { "Ativar som", seg_src(ctx_seg).has_audio, 5 }
		else do it[n] = { "Silenciar", seg_src(ctx_seg).has_audio, 5 }
		n += 1
		it[n] = { "Separar áudio", seg_src(ctx_seg).has_audio && !seg_audio_like(ctx_seg), 7 }; n += 1
		if grp do it[n] = { "Excluir grupo  (Del)", true, 6 }
		else do it[n] = { "Excluir  (Del)", true, 6 }
		n += 1
	} else {
		it[n] = { "Colar aqui  (Ctrl+V)", seg_clipbrd_n > 0, 3 }; n += 1
	}
	return n
}

// retângulo do menu, clampado à janela (perto da borda de baixo abre p/ cima)
ctx_rect :: proc(n: int) -> rl.Rectangle {
	w := CTX_W; h := f32(n)*CTX_IH + 8
	x := ctx_pos.x; y := ctx_pos.y
	sw := f32(rl.GetScreenWidth()); sh := f32(rl.GetScreenHeight())
	if x + w > sw - 4 do x = max(4, sw - 4 - w)
	if y + h > sh - 4 do y = max(4, y - h)
	return { x, y, w, h }
}

// (update) id do item habilitado sob o mouse (-1 = nenhum) + se o mouse está no menu
ctx_hit :: proc(m: rl.Vector2) -> (id: int, inside: bool) {
	items: [10]CtxItem
	n := ctx_items(&items)
	r := ctx_rect(n)
	inside = rl.CheckCollisionPointRec(m, r)
	id = -1
	if !inside do return
	k := int((m.y - (r.y + 4)) / CTX_IH)
	if k >= 0 && k < n && items[k].on do id = items[k].id
	return
}

ctx_run :: proc(id: int) {
	sane := ctx_seg >= 0 && ctx_seg < nsegs && seg_ready(ctx_seg)
	switch id {
	case 0: if sane do copy_segs()
	case 1: if sane do cut_segs()
	case 2: if sane do duplicate_segs()
	case 3: paste_segs(max(0, ctx_time))
	case 4: if sane && split_seg_at(ctx_seg, ctx_time) { selected = ctx_seg; set_toast("Clipe dividido") }
	case 5: if sane do segs[ctx_seg].muted = !segs[ctx_seg].muted
	case 7: if sane do detach_audio(ctx_seg)
	case 6:
		if !sane do return
		if seg_marks_count() > 1 && seg_marked[ctx_seg] { // grupo: igual ao Delete (deixa os vãos)
			nrm := seg_marks_count()
			for k := nsegs - 1; k >= 0; k -= 1 do if seg_marked[k] do remove_seg(k, false)
			seg_clear_marks(); selected = -1
			set_toast(rl.TextFormat("%d clipes removidos", nrm))
		} else {
			remove_seg(ctx_seg, !alt_down()) // Alt = deixa o vão (igual ao Delete)
		}
	}
}

// desenhado por último (por cima da timeline). Hover com colisão CRUA — o
// hovered() global fica inerte enquanto o menu está aberto.
draw_ctx_menu :: proc() {
	if !ctx_open do return
	items: [10]CtxItem
	n := ctx_items(&items)
	r := ctx_rect(n)
	rl.DrawRectangleRounded(r, 0.08, 6, rl.Color{ 30, 33, 40, 250 })
	rl.DrawRectangleRoundedLinesEx(r, 0.08, 6, 1, LINE)
	m := rl.GetMousePosition()
	for k in 0 ..< n {
		ir := rl.Rectangle{ r.x + 3, r.y + 4 + f32(k)*CTX_IH, r.width - 6, CTX_IH }
		if items[k].on && rl.CheckCollisionPointRec(m, ir) do rl.DrawRectangleRounded(ir, 0.2, 4, HOVER)
		col := items[k].on ? TEXT : MUTED
		if items[k].id == 6 && items[k].on do col = rl.Color{ 225, 110, 100, 255 } // Excluir em vermelho
		txt(items[k].label, ir.x + 12, ir.y + 7, 14, col)
	}
}

// dropdown do menu Arquivo: Novo / Abrir / Salvar (desenhado por último p/ ficar por cima)
draw_file_menu :: proc() {
	if !file_menu_open do return
	items := []cstring{ "Novo projeto", "Abrir projeto  (Ctrl+O)", "Salvar projeto  (Ctrl+S)" }
	iw: f32 = 220; ih: f32 = 32
	mr := rl.Rectangle{ g_file_menu_x, 34, iw, f32(len(items))*ih + 6 }
	rl.DrawRectangleRounded(mr, 0.06, 6, rl.Color{ 30, 33, 40, 250 })
	rl.DrawRectangleRoundedLinesEx(mr, 0.06, 6, 1, LINE)
	for it, ii in items {
		ir := rl.Rectangle{ mr.x + 3, mr.y + 3 + f32(ii)*ih, iw - 6, ih }
		if hovered(ir) do rl.DrawRectangleRounded(ir, 0.2, 4, HOVER)
		txt(it, ir.x + 12, ir.y + 8, 14, TEXT)
		if clicked(ir) {
			file_menu_open = false
			switch ii {
			case 0: request_new()  // pergunta se quer salvar se houver algo não salvo
			case 1: request_open() // idem antes de abrir outro projeto
			case 2: if p, ok := save_dialog("Meu Projeto"); ok do save_project(ensure_ext(p, ".ovp"))
			}
		}
	}
	if rl.IsMouseButtonPressed(.LEFT) && !hovered(mr) { // clique fora fecha
		mx := rl.GetMousePosition().x
		if !(rl.GetMousePosition().y < 34 && mx >= g_file_menu_x - 4 && mx < g_file_menu_x + 80) do file_menu_open = false
	}
}

// ---------- barra de topo ----------
draw_topbar :: proc(sw, h: f32) {
	rl.DrawRectangleRec({0, 0, sw, h}, TOPBAR)
	rl.DrawRectangle(0, i32(h) - 1, i32(sw), 1, LINE)
	rl.DrawRectangleRounded({10, h/2 - 8, 16, 16}, 0.3, 6, ACCENT)
	txt("Editor de Vídeo", 34, h/2 - 9, 15, TEXT)

	menus := []cstring{ "Arquivo", "Editar", "Ferramentas", "Visualização", "Exportar", "Ajuda" }
	x: f32 = 150
	for mnu, mi in menus {
		w := txt_w(mnu, 14) + 22
		r := rl.Rectangle{ x, 0, w, h }
		if hovered(r) do rl.DrawRectangleRec(r, HOVER)
		txt(mnu, x + 11, h/2 - 8, 14, (mi == 0 && file_menu_open) ? TEXT : MUTED)
		if clicked(r) {
			if mi == 0 { file_menu_open = !file_menu_open; g_file_menu_x = x }      // Arquivo
			else if mi == 4 { open_export_modal(); file_menu_open = false }          // Exportar
			else do file_menu_open = false
		}
		x += w
	}
	txt_c("Sem Título : 00:00:00:00", sw/2, h/2 - 8, 14, MUTED)

	bw: f32 = 34

	// arrastar a janela pela barra: área central, entre o fim dos menus e os botões.
	// duplo-clique alterna maximizar/restaurar; maximizada, um clique simples NÃO
	// restaura — só o arrasto de fato (mouse moveu segurando), como no Windows.
	dz := rl.Rectangle{ x, 0, max(0, sw - bw*3 - x), h }
	if rl.IsMouseButtonPressed(.LEFT) && hovered(dz) {
		now := rl.GetTime()
		if now - win_click_t < 0.4 { // duplo-clique
			if rl.IsWindowMaximized() do rl.RestoreWindow()
			else do rl.MaximizeWindow()
			win_click_t = -1
			win_dragging = false
		} else {
			win_click_t = now
			win_dragging = true
			win_grab = rl.GetMousePosition()
		}
	}
	if !rl.IsMouseButtonDown(.LEFT) do win_dragging = false
	if win_dragging {
		m := rl.GetMousePosition()
		if rl.IsWindowMaximized() {
			// só restaura quando o mouse MOVE; re-ancora o grab proporcionalmente
			// à largura restaurada — antes o grab ficava nas coords da janela
			// maximizada e ela "pulava" p/ longe do cursor no 1º movimento
			if abs(m.x - win_grab.x) + abs(m.y - win_grab.y) > 4 {
				frac := m.x / sw
				rl.RestoreWindow() // no win32 o resize é síncrono: o tamanho novo já vale
				win_grab = { f32(rl.GetScreenWidth()) * frac, min(win_grab.y, h - 4) }
			}
		} else {
			wp := rl.GetWindowPosition()
			rl.SetWindowPosition(i32(wp.x + m.x - win_grab.x), i32(wp.y + m.y - win_grab.y))
		}
	}

	mn := rl.Rectangle{ sw - bw*3, 0, bw, h }
	mx := rl.Rectangle{ sw - bw*2, 0, bw, h }
	cl := rl.Rectangle{ sw - bw, 0, bw, h }
	if clicked(mn) do rl.MinimizeWindow()
	if clicked(mx) {
		if rl.IsWindowMaximized() do rl.RestoreWindow()
		else do rl.MaximizeWindow()
	}
	if clicked(cl) do request_close() // pergunta se quer salvar antes de sair
	if hovered(mn) do rl.DrawRectangleRec(mn, HOVER)
	if hovered(mx) do rl.DrawRectangleRec(mx, HOVER)
	if hovered(cl) do rl.DrawRectangleRec(cl, rl.Color{200, 60, 55, 255})
	rl.DrawLineEx({mn.x + 12, h/2 + 4}, {mn.x + 22, h/2 + 4}, 1.4, MUTED)
	if rl.IsWindowMaximized() { // ícone de "restaurar": dois quadros sobrepostos
		rl.DrawRectangleLinesEx({mx.x + 11, h/2 - 3, 9, 9}, 1.4, MUTED)
		rl.DrawRectangleLinesEx({mx.x + 14, h/2 - 6, 9, 9}, 1.4, MUTED)
	} else {
		rl.DrawRectangleLinesEx({mx.x + 12, h/2 - 5, 10, 10}, 1.4, MUTED)
	}
	rl.DrawLineEx({cl.x + 12, h/2 - 5}, {cl.x + 22, h/2 + 5}, 1.4, TEXT)
	rl.DrawLineEx({cl.x + 22, h/2 - 5}, {cl.x + 12, h/2 + 5}, 1.4, TEXT)
}

// ---------- abas ----------
draw_toolbar :: proc(sw, y, h: f32) {
	rl.DrawRectangleRec({0, y, sw, h}, PANEL2)
	rl.DrawRectangle(0, i32(y + h) - 1, i32(sw), 1, LINE)
	tabs := []cstring{
		"Mídia", "Transições", "Efeitos", "Cor", "Tela Dividida",
	}
	x: f32 = 6
	for tab, i in tabs {
		w := txt_w(tab, 13) + 26
		r := rl.Rectangle{ x, y, w, h }
		active := i == st.active_tab
		if hovered(r) && !active do rl.DrawRectangleRec(r, HOVER)
		if clicked(r) do st.active_tab = i
		icol := active ? ACCENT : MUTED
		rl.DrawRectangleRoundedLinesEx({ x + w/2 - 9, y + 12, 18, 15 }, 0.25, 4, 1.5, icol)
		txt_c(tab, x + w/2, y + 34, 13, active ? TEXT : MUTED)
		if active do rl.DrawRectangleRec({ x + 8, y + h - 3, w - 16, 3 }, ACCENT)
		x += w
	}
	ew: f32 = 96
	er := rl.Rectangle{ sw - ew - 14, y + h/2 - 15, ew, 30 }
	exporting := intrinsics.atomic_load(&export_run)
	rl.DrawRectangleRounded(er, 0.5, 8, exporting ? PANEL2 : (hovered(er) ? ACCENT : ACCENT_D))
	if exporting {
		txt_c(rl.TextFormat("%d%%", i32(export_pct*100)), er.x + er.width/2, er.y + 7, 14, ACCENT)
	} else {
		txt_c("Exportar", er.x + er.width/2, er.y + 7, 14, rl.WHITE)
		if clicked(er) do open_export_modal()
	}
}

// ---------- sub-barra ----------
draw_subbar :: proc(y, media_w, h: f32) {
	rl.DrawRectangleRec({0, y, media_w, h}, PANEL)
	rl.DrawRectangle(0, i32(y + h) - 1, i32(media_w), 1, LINE)
	pill :: proc(label: cstring, x, y, h: f32) -> f32 {
		w := txt_w(label, 13) + 40
		r := rl.Rectangle{ x, y + 5, w, h - 10 }
		rl.DrawRectangleRounded(r, 0.35, 6, hovered(r) ? HOVER : PANEL2)
		txt(label, x + 12, y + h/2 - 8, 13, TEXT)
		cx := x + w - 16
		rl.DrawTriangle({cx, y + h/2 - 2}, {cx + 8, y + h/2 - 2}, {cx + 4, y + h/2 + 3}, MUTED)
		return w
	}
	x: f32 = 10
	imp_w := pill("Importar", x, y, h)
	if clicked({ x, y + 5, imp_w, h - 10 }) do want_import = true
	x += imp_w + 8
	// botão "Texto" (＋): adiciona um título/legenda na timeline
	tb := rl.Rectangle{ x, y + 5, txt_w("+ Texto", 13) + 24, h - 10 }
	rl.DrawRectangleRounded(tb, 0.35, 6, hovered(tb) ? HOVER : PANEL2)
	txt("+ Texto", x + 12, y + h/2 - 8, 13, TEXT)
	if clicked(tb) do add_text()
	x += tb.width + 8
	// --- busca de mídia (filtra o bin pelo nome; campo editável com cursor/seleção) ---
	sr := rl.Rectangle{ x, y + 5, media_w - x - 20, h - 10 }
	rl.DrawRectangleRounded(sr, 0.35, 6, PANEL2)
	rl.DrawRectangleRoundedLinesEx(sr, 0.35, 6, 1, search_focus ? ACCENT : LINE)
	// lupa
	rl.DrawCircleLinesV({sr.x + 14, sr.y + sr.height/2 - 1}, 5, MUTED)
	rl.DrawLineEx({sr.x + 18, sr.y + sr.height/2 + 3}, {sr.x + 22, sr.y + sr.height/2 + 7}, 1.5, MUTED)
	// campo (depois da lupa; deixa espaço p/ o X de limpar à direita)
	fld := rl.Rectangle{ sr.x + 22, sr.y, sr.width - 22 - 24, sr.height }
	if tf_search.len == 0 && !search_focus do txt("Pesquisar mídia", fld.x + 4, sr.y + sr.height/2 - 8, 13, MUTED)
	tf_field(&tf_search, fld, &search_focus, true)
	// X p/ limpar (só quando há texto)
	if tf_search.len > 0 {
		xr := rl.Rectangle{ sr.x + sr.width - 22, sr.y + sr.height/2 - 8, 16, 16 }
		rl.DrawLineEx({xr.x + 3, xr.y + 3}, {xr.x + 13, xr.y + 13}, 1.6, hovered(xr) ? TEXT : MUTED)
		rl.DrawLineEx({xr.x + 13, xr.y + 3}, {xr.x + 3, xr.y + 13}, 1.6, hovered(xr) ? TEXT : MUTED)
		if clicked(xr) { tf_set(&tf_search, ""); search_focus = false }
	}
}

// ---------- painel de mídia (bin) ----------
// mostra todas as mídias importadas; arraste um item para a timeline (V1) para usá-lo.
// mini-ícone da transição dentro de um tile
draw_trans_icon :: proc(box: rl.Rectangle, kind: int) {
	ix := box.x + 20; iy := box.y + 12; iw := box.width - 40; ih := box.height - 30
	switch kind {
	case 0: // dissolver: dois blocos sobrepostos + laço âmbar
		rl.DrawRectangleRec({ ix, iy, iw*0.62, ih }, rl.Color{ 70, 110, 140, 255 })
		rl.DrawRectangleRec({ ix + iw*0.38, iy, iw*0.62, ih }, rl.Color{ 150, 90, 120, 210 })
		rl.DrawLineEx({ ix+iw*0.38, iy }, { ix+iw, iy+ih }, 1.5, rl.Color{ 245, 212, 120, 230 })
		rl.DrawLineEx({ ix+iw*0.38, iy+ih }, { ix+iw, iy }, 1.5, rl.Color{ 245, 212, 120, 230 })
	case 1: // fade de entrada: preto -> claro
		for k in 0 ..< 8 { a := u8(f32(k)/7*255); rl.DrawRectangleRec({ ix + f32(k)*(iw/8), iy, iw/8+1, ih }, rl.Color{ 205, 208, 216, a }) }
	case 2: // fade de saída: claro -> preto
		for k in 0 ..< 8 { a := u8((1-f32(k)/7)*255); rl.DrawRectangleRec({ ix + f32(k)*(iw/8), iy, iw/8+1, ih }, rl.Color{ 205, 208, 216, a }) }
	}
}

// painel de TRANSIÇÕES (aba do topo): tiles clicáveis aplicados ao clipe selecionado.
// ícone do efeito de distorção: círculos concêntricos (lente) sugerindo o bulge
draw_bulge_icon :: proc(box: rl.Rectangle, col: rl.Color) {
	cx := i32(box.x + box.width/2); cy := i32(box.y + box.height/2)
	rl.DrawCircleLines(cx, cy, 21, col)
	rl.DrawCircleLines(cx, cy, 13, col)
	rl.DrawCircleV({ f32(cx), f32(cy) }, 4, col)
}

// --- BIBLIOTECA DE EFEITOS (aba "Efeitos"): efeitos VISUAIS (NÃO cor — cor fica na aba "Cor").
// Arraste um tile p/ a faixa de efeitos da timeline -> cria um clipe com parâmetros PRÓPRIOS
// (editáveis no duplo-clique). ---
FxLibItem :: struct { name: cstring, kind: int }
fx_lib := [?]FxLibItem{ { "Distorção", FX_DISTORT }, { "Separação RGB", FX_RGB } }

fxlib_name :: proc(kind: int) -> cstring {
	switch kind { case FX_DISTORT: return "Distorção"; case FX_RGB: return "Separação RGB" }
	return "Efeito"
}
// valores padrão de um clipe de efeito recém-criado, por tipo
fx_defaults :: proc(f: ^FxSeg) {
	switch f.kind {
	case FX_DISTORT: f.amount = 0.5; f.radius = BULGE_R_DEF; f.cx = 0; f.cy = 0; f.wobble = 0; f.speed = WOBBLE_HZ_DEF
	case FX_RGB:     f.amount = 0.5; f.angle = 0.25 // "cima-baixo" (vertical) por padrão
	}
}
add_fxseg :: proc(kind: int, start: f32, track := 0) -> int {
	if nfx >= MAX_FX { set_toast("Máximo de efeitos na timeline"); return -1 }
	f := FxSeg{ kind = kind, track = clamp(track, 0, g_nv - 1), start = max(0, start), dur = 3 }
	fx_defaults(&f)
	fxsegs[nfx] = f; fx_sel = nfx; nfx += 1
	return nfx - 1
}
remove_fxseg :: proc(i: int) {
	if i < 0 || i >= nfx do return
	for k in i ..< nfx-1 do fxsegs[k] = fxsegs[k+1]
	nfx -= 1
	if fx_sel == i do fx_sel = -1; else if fx_sel > i do fx_sel -= 1
}
// efeito de faixa que rege a trilha de vídeo `s` no playhead. Um efeito na trilha T afeta
// as trilhas com índice <= T ("o que está embaixo"), então o seg da trilha s é regido pelo
// efeito ativo na trilha >= s mais PRÓXIMA (menor T >= s); empate -> o último. -1 = nenhum.
fx_for_track :: proc(s: int) -> int {
	best := -1; bt := 1 << 30
	for i in 0 ..< nfx {
		e := fxsegs[i]
		if e.track < s || st.playhead < e.start || st.playhead >= e.start + e.dur do continue
		if e.track <= bt { best = i; bt = e.track }
	}
	return best
}
// deslocamento da separação RGB em coords de textura (a partir de amount + ângulo)
fx_rgb_offset :: proc(f: FxSeg) -> [2]f32 {
	mag := f.amount * 0.03 // até ~3% da textura
	a := f.angle * 2*math.PI
	return { mag*math.cos(a), mag*math.sin(a) }
}
// intensidade da distorção modulada pelo tremor no tempo local `t`
fx_bulge_strength :: proc(f: FxSeg, t: f32) -> f32 {
	if abs(f.wobble) < 0.0001 do return f.amount
	hz := f.speed <= 0 ? WOBBLE_HZ_DEF : f.speed
	return f.amount + f.wobble*math.sin(t * 2*math.PI * hz)
}
// ícone/preview de um efeito na biblioteca
draw_fx_icon :: proc(box: rl.Rectangle, kind: int) {
	rl.DrawRectangleRec(box, rl.Color{ 40, 46, 60, 255 })
	switch kind {
	case FX_DISTORT:
		draw_bulge_icon(box, rl.Color{ 250, 220, 130, 255 })
	case FX_RGB: // três blocos R/G/B deslocados (sugere a separação)
		cx := box.x + box.width/2 - 10; cy := box.y + box.height/2 - 8
		rl.DrawRectangleRec({ cx-4, cy,   20, 16 }, rl.Color{ 235, 70, 70, 190 })
		rl.DrawRectangleRec({ cx,   cy-2, 20, 16 }, rl.Color{ 70, 220, 90, 190 })
		rl.DrawRectangleRec({ cx+4, cy+2, 20, 16 }, rl.Color{ 80, 120, 245, 190 })
	}
}

// aba "Efeitos": BIBLIOTECA de efeitos VISUAIS (arraste p/ a timeline). Se um clipe de efeito
// estiver selecionado (duplo-clique na faixa), mostra as CONFIGURAÇÕES dele no lugar.
draw_effects_panel :: proc(r: rl.Rectangle) {
	if fx_sel >= 0 && fx_sel < nfx { draw_fx_settings(r); return }
	txt("Efeitos", r.x + 14, r.y + 12, 15, TEXT)
	txt("Arraste um efeito para a faixa de efeitos (topo da timeline).", r.x + 14, r.y + 36, 11, MUTED)
	txt("Duplo-clique no clipe de efeito p/ ajustar.", r.x + 14, r.y + 52, 11, MUTED)

	tw: f32 = 104; th: f32 = 66; gap: f32 = 12; lblh: f32 = 22
	cols := max(1, int((r.width - gap) / (tw + gap)))
	x0 := r.x + gap; y0 := r.y + 76
	for it, idx in fx_lib {
		col := idx % cols; row := idx / cols
		box := rl.Rectangle{ x0 + f32(col)*(tw+gap), y0 + f32(row)*(th+gap+lblh), tw, th }
		hot := hovered(box)
		draw_fx_icon(box, it.kind)
		rl.DrawRectangleRoundedLinesEx(box, 0.1, 6, hot ? 2 : 1, hot ? ACCENT : LINE)
		txt_c(it.name, box.x + box.width/2, box.y + box.height + 4, 12, TEXT)
		if rl.IsMouseButtonPressed(.LEFT) && hovered(box) && modal == .None { st.drag = .FxLib; fxlib_drag = it.kind }
	}
}

// CONFIGURAÇÕES do clipe de efeito selecionado (aberto no duplo-clique). Sliders próprios por
// tipo + "‹ Efeitos" (voltar à biblioteca) e "Redefinir".
draw_fx_settings :: proc(r: rl.Rectangle) {
	f := &fxsegs[fx_sel]
	x := r.x + 14; cw := r.width - 28; vx := r.x + r.width - 14 - 50
	if ui_btn({ x, r.y + 8, 90, 22 }, "‹ Efeitos", false) { fx_sel = -1; return }
	txt(fxlib_name(f.kind), x, r.y + 40, 15, TEXT)
	txt(rl.TextFormat("Duração: %.1fs", f64(f.dur)), vx - 20, r.y + 44, 11, MUTED)
	y := r.y + 68
	switch f.kind {
	case FX_DISTORT:
		if f.radius <= 0 do f.radius = BULGE_R_DEF
		txt("Intensidade", x, y, 13, TEXT); txt(rl.TextFormat("%d%%", i32(f.amount*100)), vx, y, 13, ACCENT); y += 20
		ui_slider(40, { x, y, cw, 16 }, &f.amount, -1, 1); y += 28
		txt("Raio", x, y, 13, TEXT); txt(rl.TextFormat("%d%%", i32(f.radius*100)), vx, y, 13, ACCENT); y += 20
		ui_slider(41, { x, y, cw, 16 }, &f.radius, 0.1, 1); y += 28
		txt("Centro X", x, y, 13, TEXT); txt(rl.TextFormat("%d", i32(f.cx*100)), vx, y, 13, ACCENT); y += 20
		ui_slider(42, { x, y, cw, 16 }, &f.cx, -0.5, 0.5); y += 28
		txt("Centro Y", x, y, 13, TEXT); txt(rl.TextFormat("%d", i32(f.cy*100)), vx, y, 13, ACCENT); y += 20
		ui_slider(43, { x, y, cw, 16 }, &f.cy, -0.5, 0.5); y += 28
		txt("Tremor", x, y, 13, TEXT); txt(rl.TextFormat("%d%%", i32(f.wobble*100)), vx, y, 13, ACCENT); y += 20
		if ui_slider(44, { x, y, cw, 16 }, &f.wobble, 0, 1) { if f.wobble < 0.03 do f.wobble = 0 }
		y += 28
		if f.wobble > 0.001 {
			if f.speed <= 0 do f.speed = WOBBLE_HZ_DEF
			txt("Velocidade", x, y, 13, TEXT); txt(rl.TextFormat("%.1f Hz", f64(f.speed)), vx-8, y, 13, ACCENT); y += 20
			ui_slider(45, { x, y, cw, 16 }, &f.speed, 0.3, 8); y += 28
		}
	case FX_RGB:
		txt("Intensidade", x, y, 13, TEXT); txt(rl.TextFormat("%d%%", i32(f.amount*100)), vx, y, 13, ACCENT); y += 20
		ui_slider(40, { x, y, cw, 16 }, &f.amount, 0, 1); y += 28
		txt("Direção", x, y, 13, TEXT); txt(rl.TextFormat("%d°", i32(f.angle*360)), vx, y, 13, ACCENT); y += 20
		ui_slider(41, { x, y, cw, 16 }, &f.angle, 0, 1); y += 28
		txt("0° = horizontal · 90° = cima-baixo.", x, y, 11, MUTED); y += 22
	}
	y += 8
	// rodapé estilo NLE: REDEFINIR (contorno) à esquerda, OK (preenchido) à direita.
	pw: f32 = 116; ph: f32 = 30
	if ui_pill({ x, y, pw, ph }, "REDEFINIR", false) { k := f.kind; f^ = FxSeg{ kind = k, track = f.track, start = f.start, dur = f.dur }; fx_defaults(f) }
	if ui_pill({ x + cw - pw, y, pw, ph }, "OK", true) { fx_sel = -1 }
}

// aba "Cor": graduação de cor do clipe selecionado (preview ao vivo + export). Presets de
// visual (P&B/sépia/inverter) + ajustes (brilho/contraste/saturação/vinheta). Edita os
// campos fx_* do segmento; 0 = neutro em todos.
draw_color_panel :: proc(r: rl.Rectangle) {
	txt("Cor", r.x + 14, r.y + 12, 15, TEXT)
	valid := selected >= 0 && selected < nsegs && seg_ready(selected) && !seg_audio_like(selected) && !seg_src(selected).is_text
	if !valid {
		txt("Selecione um clipe de vídeo na timeline", r.x + 14, r.y + 40, 12, MUTED)
		txt("para ajustar a cor.", r.x + 14, r.y + 56, 12, MUTED)
		return
	}
	sg := &segs[selected]
	x := r.x + 14; cw := r.width - 28; vx := r.x + r.width - 14 - 50
	y := r.y + 44

	txt("Visual", x, y, 13, MUTED); y += 22
	lk := int(sg.fx_look + 0.5)
	presets := []struct{ name: cstring, v: int }{ {"Normal",0}, {"P&B",1}, {"Sépia",2}, {"Inverter",3} }
	bw := (cw - 3*6) / 4
	for p, k in presets {
		bx := x + f32(k)*(bw+6)
		if ui_btn({ bx, y, bw, 24 }, p.name, lk == p.v) do sg.fx_look = f32(p.v)
	}
	y += 34
	txt("Ajustes", x, y, 13, MUTED); y += 22
	txt("Brilho", x, y, 13, TEXT); txt(rl.TextFormat("%d", i32(sg.fx_bright*100)), vx, y, 13, ACCENT); y += 20
	if ui_slider(30, { x, y, cw, 16 }, &sg.fx_bright, -1, 1) { if abs(sg.fx_bright) < 0.04 do sg.fx_bright = 0 }
	y += 26
	txt("Contraste", x, y, 13, TEXT); txt(rl.TextFormat("%d%%", i32((1+sg.fx_contrast)*100)), vx, y, 13, ACCENT); y += 20
	if ui_slider(31, { x, y, cw, 16 }, &sg.fx_contrast, -1, 1) { if abs(sg.fx_contrast) < 0.04 do sg.fx_contrast = 0 }
	y += 26
	txt("Saturação", x, y, 13, TEXT); txt(rl.TextFormat("%d%%", i32((1+sg.fx_satur)*100)), vx, y, 13, ACCENT); y += 20
	if ui_slider(32, { x, y, cw, 16 }, &sg.fx_satur, -1, 1) { if abs(sg.fx_satur) < 0.04 do sg.fx_satur = 0 }
	y += 26
	txt("Temperatura", x, y, 13, TEXT); txt(rl.TextFormat("%d", i32(sg.fx_temp*100)), vx, y, 13, ACCENT); y += 20
	if ui_slider(34, { x, y, cw, 16 }, &sg.fx_temp, -1, 1) { if abs(sg.fx_temp) < 0.04 do sg.fx_temp = 0 }
	y += 26
	txt("Vinheta", x, y, 13, TEXT); txt(rl.TextFormat("%d%%", i32(sg.fx_vignette*100)), vx, y, 13, ACCENT); y += 20
	if ui_slider(33, { x, y, cw, 16 }, &sg.fx_vignette, 0, 1) { if sg.fx_vignette < 0.03 do sg.fx_vignette = 0 }
	y += 30
	// rodapé estilo NLE: REDEFINIR (contorno) à esquerda, OK (preenchido) à direita.
	pw: f32 = 116; ph: f32 = 30
	if ui_pill({ x, y, pw, ph }, "REDEFINIR", false) {
		sg.fx_bright = 0; sg.fx_contrast = 0; sg.fx_satur = 0; sg.fx_look = 0; sg.fx_vignette = 0; sg.fx_temp = 0
	}
	if ui_pill({ x + cw - pw, y, pw, ph }, "OK", true) { st.active_tab = 0 }
}

draw_transitions_panel :: proc(r: rl.Rectangle) {
	txt("Transições", r.x + 14, r.y + 12, 15, TEXT)
	txt("Arraste até a junção dos clipes (ou clique p/ o selecionado).",
		r.x + 14, r.y + 38, 12, MUTED)
	items := []struct{ name: cstring, kind: int }{ {"Dissolver", 0}, {"Fade de entrada", 1}, {"Fade de saída", 2} }
	tw: f32 = 132; th: f32 = 74; gap: f32 = 12
	cols := max(1, int((r.width - gap) / (tw + gap)))
	x0 := r.x + gap; y0 := r.y + 64
	for it, idx in items {
		col := idx % cols; row := idx / cols
		box := rl.Rectangle{ x0 + f32(col)*(tw+gap), y0 + f32(row)*(th+28), tw, th }
		hot := hovered(box)
		rl.DrawRectangleRounded(box, 0.08, 6, hot ? rl.Color{ 48, 52, 64, 255 } : PANEL2)
		rl.DrawRectangleRoundedLinesEx(box, 0.08, 6, 1, hot ? ACCENT : LINE)
		draw_trans_icon(box, it.kind)
		txt_c(it.name, box.x + box.width/2, box.y + box.height + 4, 11, TEXT)
		// arrastar até a timeline (soltar entre os clipes); clique = aplica ao selecionado
		if rl.IsMouseButtonPressed(.LEFT) && hovered(box) && modal == .None {
			st.drag = .Trans; trans_drag = it.kind
		}
	}
	txt("Ajuste a duração depois na aba \"Vídeo\" do inspector.", r.x + 14, r.y + r.height - 30, 11, MUTED)
}

// ícone de um layout de tela dividida: desenha as células (mesma tabela de split_cells)
// como blocos dentro do box, cada uma numa cor.
draw_split_icon :: proc(box: rl.Rectangle, kind: int) {
	pad: f32 = 16
	fr := rl.Rectangle{ box.x + pad, box.y + 10, box.width - 2*pad, box.height - 24 }
	cols := []rl.Color{ {70,110,140,255}, {150,90,120,255}, {90,140,110,255} }
	cells := split_cells(kind)
	// desenha do fim p/ o começo: célula[0] (o inset do PiP) por ÚLTIMO = por cima, igual ao composite
	#reverse for c, k in cells {
		cw := c.w*fr.width; ch := c.h*fr.height
		cx := fr.x + fr.width/2 + c.cx*fr.width - cw/2
		cy := fr.y + fr.height/2 + c.cy*fr.height - ch/2
		rl.DrawRectangleRec({ cx+1, cy+1, cw-2, ch-2 }, cols[k % len(cols)])
	}
}

// aba "Tela Dividida": tiles clicáveis que arrumam os clipes sobrepostos no playhead.
draw_split_panel :: proc(r: rl.Rectangle) {
	txt("Tela Dividida", r.x + 14, r.y + 12, 15, TEXT)
	txt("Ponha os clipes em trilhas separadas (V1/V2/V3),", r.x + 14, r.y + 38, 12, MUTED)
	txt("sobrepostos no playhead, e clique um layout.", r.x + 14, r.y + 54, 12, MUTED)
	items := []struct{ name: cstring, kind: int }{ {"2 lado a lado", 0}, {"2 empilhado", 1}, {"3 colunas", 2}, {"PiP (canto)", 3} }
	tw: f32 = 132; th: f32 = 74; gap: f32 = 12
	cols := max(1, int((r.width - gap) / (tw + gap)))
	x0 := r.x + gap; y0 := r.y + 80
	for it, idx in items {
		col := idx % cols; row := idx / cols
		box := rl.Rectangle{ x0 + f32(col)*(tw+gap), y0 + f32(row)*(th+28), tw, th }
		hot := hovered(box)
		rl.DrawRectangleRounded(box, 0.08, 6, hot ? rl.Color{ 48, 52, 64, 255 } : PANEL2)
		rl.DrawRectangleRoundedLinesEx(box, 0.08, 6, 1, hot ? ACCENT : LINE)
		draw_split_icon(box, it.kind)
		txt_c(it.name, box.x + box.width/2, box.y + box.height + 4, 11, TEXT)
		if clicked(box) do apply_split(it.kind)
	}
	txt("Ajuste posição/escala de cada clipe na aba \"Vídeo\".", r.x + 14, r.y + r.height - 30, 11, MUTED)
}

// seleção múltipla do bin: contagem e limpeza
bin_marks_count :: proc() -> int { n := 0; for k in 0 ..< nclips do if bin_marked[k] do n += 1; return n }
bin_clear_marks :: proc() { for k in 0 ..< MAX_CLIPS do bin_marked[k] = false }

draw_media_panel :: proc(r: rl.Rectangle) {
	rl.DrawRectangleRec(r, PANEL)
	if st.active_tab == 1 { draw_transitions_panel(r); return } // aba "Transições"
	if st.active_tab == 2 { draw_effects_panel(r); return }     // aba "Efeitos"
	if st.active_tab == 3 { draw_color_panel(r); return }       // aba "Cor"
	if st.active_tab == 4 { draw_split_panel(r); return }       // aba "Tela Dividida"

	// conta mídias válidas (não-falhas) e as que casam com a busca
	nshow := 0; nmatch := 0
	for i in 0 ..< nclips do if !intrinsics.atomic_load(&clips[i].failed) {
		nshow += 1
		if media_matches(i) do nmatch += 1
	}

	if nshow == 0 { // bin vazio: convite p/ importar
		cx := r.x + r.width/2
		cy := r.y + r.height*0.5
		hov := hovered(r)
		box := rl.Rectangle{ cx - 34, cy - 34, 68, 68 }
		rl.DrawRectangleRounded(box, 0.3, 8, rl.Color{ 38, 42, 54, 255 })
		// borda azul->ciano (aprox. do gradiente); brilha no hover
		rl.DrawRectangleRoundedLinesEx(box, 0.3, 8, 2, hov ? rl.Color{ 96, 214, 236, 255 } : rl.Color{ 68, 160, 214, 255 })
		blue := rl.Color{ 92, 152, 242, 255 } // topo (haste)
		cyan := rl.Color{ 48, 208, 216, 255 } // base (ponta + bandeja)
		// seta p/ baixo: haste + ponta em V (chevron)
		rl.DrawLineEx({ cx, cy - 15 }, { cx, cy + 3 }, 3.5, blue)
		rl.DrawLineEx({ cx - 8, cy - 5 }, { cx, cy + 5 }, 3.5, cyan)
		rl.DrawLineEx({ cx + 8, cy - 5 }, { cx, cy + 5 }, 3.5, cyan)
		// bandeja aberta embaixo (caixa sem topo): laterais + base
		rl.DrawLineEx({ cx - 14, cy + 9 }, { cx - 14, cy + 16 }, 3.5, cyan)
		rl.DrawLineEx({ cx + 14, cy + 9 }, { cx + 14, cy + 16 }, 3.5, cyan)
		rl.DrawLineEx({ cx - 15.5, cy + 16 }, { cx + 15.5, cy + 16 }, 3.5, cyan)
		txt_c("Clique aqui para importar (ou solte vídeos)", cx, cy + 52, 14, hov ? TEXT : MUTED)
		if clicked(r) && src_preview < 0 do want_import = true // bin vazio: 1 clique importa
		return
	}
	if nmatch == 0 { // há mídia, mas nada casa com a busca
		txt_c(rl.TextFormat("Nenhuma mídia com \"%s\"", cs(string(tf_search.buf[:tf_search.len]))), r.x + r.width/2, r.y + r.height*0.5, 14, MUTED)
		return
	}

	tw: f32 = 132
	th: f32 = 74
	gap: f32 = 12
	cols := max(1, int((r.width - gap) / (tw + gap)))
	x0 := r.x + gap
	slot := 0

	// seleção por retângulo: calcula a área e, no modo SUBSTITUIR, recomeça a cada frame
	// (encolher o retângulo desmarca de novo). No modo SOMAR (Ctrl/Shift) só acrescenta.
	mq: rl.Rectangle
	if bin_marquee {
		mm := rl.GetMousePosition()
		if abs(mm.x - bin_marquee_start.x) > 4 || abs(mm.y - bin_marquee_start.y) > 4 do bin_marquee_moved = true
		mq = { min(bin_marquee_start.x, mm.x), min(bin_marquee_start.y, mm.y),
		       abs(mm.x - bin_marquee_start.x), abs(mm.y - bin_marquee_start.y) }
		if bin_marquee_moved && !bin_marquee_add do bin_clear_marks()
	}
	handled := false // clique já consumido por uma miniatura / botão X (não vira marquee)

	for i in 0 ..< nclips {
		c := &clips[i]
		if intrinsics.atomic_load(&c.failed) do continue
		if !media_matches(i) do continue // filtro da busca
		col := slot % cols
		row := slot / cols
		slot += 1
		tx := x0 + f32(col) * (tw + gap)
		ty := r.y + gap + f32(row) * (th + 28)
		box := rl.Rectangle{ tx, ty, tw, th }
		rl.DrawRectangleRec({box.x-1, box.y-1, box.width+2, box.height+2}, PANEL2)

		if intrinsics.atomic_load(&c.probed) {
			if c.is_text { // clipe de texto: "T" grande + prévia do conteúdo
				rl.DrawRectangleRec(box, rl.Color{ 44, 38, 60, 255 })
				txt_c("T", tx + tw/2, ty + th/2 - 20, 30, rl.Color{ 200, 186, 232, 255 })
				txt_c(elide(c.text, 12, tw - 12), tx + tw/2, ty + th - 22, 11, rl.Color{ 170, 160, 190, 235 })
			} else if c.is_audio { // sem vídeo: ícone de nota musical
				mcx := tx + tw/2; mcy := ty + th/2 - 2
				mc := rl.Color{ 120, 200, 170, 255 }
				rl.DrawLineEx({mcx + 8, mcy - 12}, {mcx + 8, mcy + 6}, 2.5, mc)
				rl.DrawLineEx({mcx - 8, mcy - 8}, {mcx - 8, mcy + 10}, 2.5, mc)
				rl.DrawLineEx({mcx - 8, mcy - 8}, {mcx + 8, mcy - 12}, 2.5, mc)
				rl.DrawCircleV({mcx - 10, mcy + 10}, 3.5, mc); rl.DrawCircleV({mcx + 6, mcy + 6}, 3.5, mc)
			} else {
				ensure_tex(c)
				if c.tex_ok do rl.DrawTexturePro(c.tex, {0,0,f32(cdw(c)),f32(cdh(c))}, box, {0,0}, 0, rl.WHITE)
			}
			txt(timecode(c.dur), tx + tw - 62, ty + th - 15, 11, rl.WHITE)
			if c.streaming do txt("streaming", tx + 4, ty + 3, 10, rl.Color{120,190,230,220})
		} else {
			txt_c("importando...", tx + tw/2, ty + th/2 - 6, 12, rl.Color{200,200,90,230})
		}

		// seleção por retângulo: marca a miniatura que ele toca (probed = arrastável)
		if bin_marquee && bin_marquee_moved && intrinsics.atomic_load(&c.probed) && rl.CheckCollisionRecs(box, mq) {
			bin_marked[i] = true
		}

		placed := intrinsics.atomic_load(&c.probed) && src_placed(i)
		sel := bin_marked[i] || i == bin_sel // marcado (multi) ou com foco
		hot := i == view_src()
		border := sel ? rl.WHITE : (hot ? ACCENT : (placed ? ACCENT_D : LINE))
		rl.DrawRectangleLinesEx(box, (sel || hot) ? 2 : 1, border)
		if placed do txt("na timeline", tx + 4, ty + 3, 10, ACCENT)
		if c.name_el == nil do c.name_el = strings.clone_to_cstring(string(elide(c.name, 11, tw)))
		txt(c.name_el, tx, ty + th + 3, 11, MUTED)

		// botão remover (X) no canto — aparece ao passar o mouse sobre a miniatura
		if hovered(box) {
			xr := rl.Rectangle{ box.x + box.width - 20, box.y + 4, 16, 16 }
			rl.DrawRectangleRounded(xr, 0.4, 4, hovered(xr) ? PLAYHEAD : rl.Color{ 40, 44, 54, 225 })
			rl.DrawLineEx({ xr.x + 5, xr.y + 5 }, { xr.x + 11, xr.y + 11 }, 1.8, rl.WHITE)
			rl.DrawLineEx({ xr.x + 11, xr.y + 5 }, { xr.x + 5, xr.y + 11 }, 1.8, rl.WHITE)
			if clicked(xr) { remove_media(i); handled = true; break } // slot mudou: redesenha no próximo frame
		}

		// pressionar seleciona o item e inicia o arrasto p/ a timeline; Ctrl/Shift+clique
		// ALTERNA a marcação (seleção múltipla); DUPLO-clique toca a mídia crua no player.
		if rl.IsMouseButtonPressed(.LEFT) && hovered(box) && intrinsics.atomic_load(&c.probed) {
			handled = true
			now := rl.GetTime()
			ctrl := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
			shift := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
			if ctrl || shift { // alterna a marcação, sem arrastar/prévia
				bin_marked[i] = !bin_marked[i]
				bin_sel = bin_marked[i] ? i : -1
				selected = -1
			} else if bin_click_i == i && now - bin_click_t < 0.35 && !c.is_text {
				start_src_preview(i) // duplo-clique (texto não tem prévia de origem)
			} else {
				// clicar num item NÃO marcado redefine a seleção só p/ ele; se já estava
				// marcado (parte de um conjunto), mantém o conjunto e arrasta todos
				if !bin_marked[i] { bin_clear_marks(); bin_marked[i] = true }
				bin_sel = i
				selected = -1 // seleção do bin e da timeline são mutuamente exclusivas
				st.drag = .Bin
				bin_drag = i // âncora; o drop leva TODOS os marcados
			}
			bin_click_t = now; bin_click_i = i
		}
	}

	// iniciar seleção por retângulo: press em área VAZIA do painel (nenhuma miniatura pegou
	// o clique). Modo SOMAR se Ctrl/Shift; senão substitui a seleção atual.
	if !bin_marquee && !handled && rl.IsMouseButtonPressed(.LEFT) && hovered(r) && st.drag == .None && src_preview < 0 {
		bin_marquee = true
		bin_marquee_start = rl.GetMousePosition()
		bin_marquee_moved = false
		bin_marquee_add = rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL) || rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
		if !bin_marquee_add { bin_sel = -1; selected = -1 }
	}
	// desenhar o retângulo em curso
	if bin_marquee && bin_marquee_moved {
		rl.DrawRectangleRec(mq, rl.Color{ 120, 170, 240, 45 })
		rl.DrawRectangleLinesEx(mq, 1, rl.Color{ 150, 190, 245, 220 })
	}
	// soltar: encerra o marquee. Se não moveu (clique seco em área vazia) = desmarca tudo.
	if bin_marquee && rl.IsMouseButtonReleased(.LEFT) {
		was_click := !bin_marquee_moved
		if !bin_marquee_moved && !bin_marquee_add { bin_clear_marks(); bin_sel = -1 }
		bin_marquee = false; bin_marquee_moved = false
		// IMPORTAR clicando na área VAZIA do bin: sem mídia = 1 clique; com mídia = duplo-clique
		if was_click && !bin_marquee_add {
			have := 0
			for k in 0 ..< nclips do if !intrinsics.atomic_load(&clips[k].failed) && !clips[k].closed do have += 1
			now := rl.GetTime()
			if have == 0 { want_import = true }
			else if bin_empty_click_t > 0 && now - bin_empty_click_t < 0.35 { want_import = true; bin_empty_click_t = -1 }
			else { bin_empty_click_t = now }
		}
	}

	have_media := false
	for k in 0 ..< nclips do if !intrinsics.atomic_load(&clips[k].failed) && !clips[k].closed { have_media = true; break }
	hint: cstring = bin_marks_count() > 1 ? "arraste p/ a timeline (várias selecionadas)" :
	                (!have_media ? "clique aqui para importar mídia" : "duplo-clique para importar · arraste p/ selecionar")
	txt(hint, r.x + 12, r.y + r.height - 22, 12, MUTED)
}

// ---------- preview + transporte ----------
// slider horizontal simples p/ o inspector. `id` distingue qual está sendo arrastado
// (imediato-mode não tem foco). Retorna true no frame em que o valor muda.
ui_slider :: proc(id: int, r: rl.Rectangle, val: ^f32, lo, hi: f32) -> bool {
	cy := r.y + r.height/2
	rl.DrawRectangleRounded({r.x, cy - 2, r.width, 4}, 1, 4, rl.Color{50, 54, 64, 255})
	frac := clamp((val^ - lo) / (hi - lo), 0, 1)
	kx := r.x + frac * r.width
	rl.DrawRectangleRounded({r.x, cy - 2, kx - r.x, 4}, 1, 4, ACCENT)
	hot := ui_slider_active == id || hovered(r)
	rl.DrawCircleV({kx, cy}, hot ? 7 : 6, hot ? rl.WHITE : rl.Color{205, 210, 220, 255})
	if rl.IsMouseButtonPressed(.LEFT) && hovered(r) && modal == .None do ui_slider_active = id
	if ui_slider_active == id {
		if rl.IsMouseButtonReleased(.LEFT) { ui_slider_active = -1 }
		else {
			nf := clamp((rl.GetMousePosition().x - r.x) / r.width, 0, 1)
			val^ = lo + nf * (hi - lo)
			return true
		}
	}
	return false
}

// slider VERTICAL (topo = hi, base = lo). Mesmo id/estado do ui_slider (ui_slider_active).
ui_vslider :: proc(id: int, r: rl.Rectangle, val: ^f32, lo, hi: f32) -> bool {
	cx := r.x + r.width/2
	rl.DrawRectangleRounded({cx - 2, r.y, 4, r.height}, 1, 4, rl.Color{50, 54, 64, 255})
	frac := clamp((val^ - lo) / (hi - lo), 0, 1)
	ky := r.y + (1 - frac) * r.height // topo = cheio
	rl.DrawRectangleRounded({cx - 2, ky, 4, (r.y + r.height) - ky}, 1, 4, ACCENT) // preenche do knob p/ baixo
	hot := ui_slider_active == id || hovered(r)
	rl.DrawCircleV({cx, ky}, hot ? 7 : 6, hot ? rl.WHITE : rl.Color{205, 210, 220, 255})
	if rl.IsMouseButtonPressed(.LEFT) && hovered(r) && modal == .None do ui_slider_active = id
	if ui_slider_active == id {
		if rl.IsMouseButtonReleased(.LEFT) { ui_slider_active = -1 }
		else {
			nf := clamp(1 - (rl.GetMousePosition().y - r.y) / r.height, 0, 1)
			val^ = lo + nf * (hi - lo)
			return true
		}
	}
	return false
}

ui_btn :: proc(r: rl.Rectangle, label: cstring, active: bool) -> bool {
	col := active ? ACCENT_D : PANEL2
	if hovered(r) do col = active ? ACCENT : HOVER
	rl.DrawRectangleRounded(r, 0.3, 6, col)
	txt_c(label, r.x + r.width/2, r.y + r.height/2 - 8, 13, active ? rl.WHITE : TEXT)
	return clicked(r)
}

// botão em "pílula" (cantos totalmente arredondados) — estilo do rodapé do painel de efeito.
// filled=true → preenchido com ACCENT, texto branco (OK); filled=false → só contorno ACCENT,
// interior translúcido no hover, texto ACCENT (Redefinir). Igual à barra REDEFINIR/OK de um NLE.
ui_pill :: proc(r: rl.Rectangle, label: cstring, filled: bool) -> bool {
	hot := hovered(r)
	if filled {
		rl.DrawRectangleRounded(r, 1, 8, hot ? ACCENT : ACCENT_D)
		txt_c(label, r.x + r.width/2, r.y + r.height/2 - 8, 13, rl.WHITE)
	} else {
		if hot do rl.DrawRectangleRounded(r, 1, 8, fa(ACCENT, 0.15))
		rl.DrawRectangleRoundedLinesEx(r, 1, 8, 1.5, hot ? ACCENT : ACCENT_D)
		txt_c(label, r.x + r.width/2, r.y + r.height/2 - 8, 13, hot ? ACCENT : ACCENT_D)
	}
	return clicked(r)
}

// botão do overlay de exportação (o clique é tratado no update, não aqui — só desenha
// com destaque no hover). `col` = cor de destaque (ACCENT p/ pausar, vermelho p/ cancelar).
draw_overlay_btn :: proc(r: rl.Rectangle, label: cstring, col: rl.Color) {
	hot := hovered(r)
	rl.DrawRectangleRounded(r, 0.25, 6, hot ? col : rl.Color{ 44, 48, 58, 255 })
	rl.DrawRectangleRoundedLinesEx(r, 0.25, 6, 1, col)
	txt_c(label, r.x + r.width/2, r.y + r.height/2 - 8, 14, hot ? rl.Color{ 20, 22, 27, 255 } : col)
}

TEXT_COLORS := []rl.Color{ {255,255,255,255}, {20,20,24,255}, {245,205,90,255}, {230,80,72,255}, {90,200,120,255}, {80,150,235,255}, {40,200,182,255} }

// --- campo de texto reutilizável: cursor + seleção (índices em BYTES no UTF-8) ---
tf_prefix_w  :: proc(t: ^TField, n: int) -> f32 { return n <= 0 ? 0 : txt_w(cs(string(t.buf[:n])), 14) } // largura de buf[:n]
tf_rune_next :: proc(t: ^TField, i: int) -> int { j := i + 1; for j < t.len && (t.buf[j] & 0xC0) == 0x80 do j += 1; return min(j, t.len) }
tf_rune_prev :: proc(t: ^TField, i: int) -> int { j := i - 1; for j > 0 && (t.buf[j] & 0xC0) == 0x80 do j -= 1; return max(0, j) }
tf_lo :: proc(t: ^TField) -> int { return min(t.caret, t.sel) }
tf_hi :: proc(t: ^TField) -> int { return max(t.caret, t.sel) }
// índice de rune mais próximo da coordenada x (relativa ao início do texto)
tf_index_at_x :: proc(t: ^TField, rel: f32) -> int {
	best := 0; bestd := abs(rel)
	i := 0
	for {
		d := abs(tf_prefix_w(t, i) - rel)
		if d < bestd { bestd = d; best = i }
		if i >= t.len do break
		i = tf_rune_next(t, i)
	}
	return best
}
tf_delete_range :: proc(t: ^TField, lo, hi: int) {
	if hi <= lo do return
	d := hi - lo
	for k := hi; k < t.len; k += 1 do t.buf[k-d] = t.buf[k]
	t.len -= d; t.caret = lo; t.sel = lo
}
tf_delete_sel :: proc(t: ^TField) -> bool { if t.sel == t.caret do return false; tf_delete_range(t, tf_lo(t), tf_hi(t)); return true }
tf_insert :: proc(t: ^TField, bytes: []u8) -> bool { // insere no cursor, substituindo a seleção
	had := tf_delete_sel(t)
	n := len(bytes); if t.len + n > len(t.buf) do n = len(t.buf) - t.len
	if n <= 0 do return had
	for k := t.len - 1; k >= t.caret; k -= 1 do t.buf[k+n] = t.buf[k]
	for k in 0 ..< n do t.buf[t.caret+k] = bytes[k]
	t.len += n; t.caret += n; t.sel = t.caret
	return true
}
tf_insert_str :: proc(t: ^TField, s: string) -> bool { // cola: insere ignorando quebras/tabs
	ch := false
	for i in 0 ..< len(s) { b := s[i]; if b != '\n' && b != '\r' && b != '\t' { bb := [1]u8{b}; if tf_insert(t, bb[:]) do ch = true } }
	return ch
}
tf_set :: proc(t: ^TField, s: string) { // carrega uma string no buffer (cursor no fim)
	t.len = 0
	for i in 0 ..< len(s) do if t.len < len(t.buf) { t.buf[t.len] = s[i]; t.len += 1 }
	t.caret = t.len; t.sel = t.len; t.scroll = 0
}

// desenha e processa um campo de texto editável. `focused` (in/out) controla o foco:
// clique dentro foca; se `allow_unfocus`, clique fora desfoca. Retorna true se o
// conteúdo mudou neste frame. Suporta clique/arraste/duplo-clique (tudo), setas,
// Home/End, Shift+seta, Backspace/Delete e Ctrl+A/C/V/X.
tf_field :: proc(t: ^TField, r: rl.Rectangle, focused: ^bool, allow_unfocus: bool) -> bool {
	changed := false
	if !focused^ do t.drag = false
	tx0 := r.x + 8 - (focused^ ? t.scroll : 0)
	m := rl.GetMousePosition()
	ctrl := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
	shiftk := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
	if rl.IsMouseButtonPressed(.LEFT) {
		if hovered(r) {
			focused^ = true
			now := rl.GetTime()
			if now - t.click_t < 0.35 { t.sel = 0; t.caret = t.len } // duplo-clique = tudo
			else { t.caret = tf_index_at_x(t, m.x - tx0); t.sel = t.caret; t.drag = true }
			t.click_t = now
		} else if allow_unfocus && focused^ {
			focused^ = false; t.drag = false
		}
	}
	if t.drag {
		if rl.IsMouseButtonDown(.LEFT) do t.caret = tf_index_at_x(t, m.x - tx0)
		else do t.drag = false
	}
	if focused^ {
		if !ctrl { for { r2 := rl.GetCharPressed(); if r2 == 0 do break; b, n := utf8.encode_rune(r2); if tf_insert(t, b[:n]) do changed = true } }
		if rl.IsKeyPressed(.BACKSPACE) || rl.IsKeyPressedRepeat(.BACKSPACE) {
			if tf_delete_sel(t) { changed = true } else if t.caret > 0 { tf_delete_range(t, tf_rune_prev(t, t.caret), t.caret); changed = true }
		}
		if rl.IsKeyPressed(.DELETE) || rl.IsKeyPressedRepeat(.DELETE) {
			if tf_delete_sel(t) { changed = true } else if t.caret < t.len { tf_delete_range(t, t.caret, tf_rune_next(t, t.caret)); changed = true }
		}
		if rl.IsKeyPressed(.LEFT)  || rl.IsKeyPressedRepeat(.LEFT)  { t.caret = tf_rune_prev(t, t.caret); if !shiftk do t.sel = t.caret }
		if rl.IsKeyPressed(.RIGHT) || rl.IsKeyPressedRepeat(.RIGHT) { t.caret = tf_rune_next(t, t.caret); if !shiftk do t.sel = t.caret }
		if rl.IsKeyPressed(.HOME) { t.caret = 0;     if !shiftk do t.sel = 0 }
		if rl.IsKeyPressed(.END)  { t.caret = t.len; if !shiftk do t.sel = t.len }
		if ctrl && rl.IsKeyPressed(.A) { t.sel = 0; t.caret = t.len }
		if ctrl && rl.IsKeyPressed(.C) && t.sel != t.caret do rl.SetClipboardText(cs(string(t.buf[tf_lo(t):tf_hi(t)])))
		if ctrl && rl.IsKeyPressed(.X) && t.sel != t.caret { rl.SetClipboardText(cs(string(t.buf[tf_lo(t):tf_hi(t)]))); tf_delete_sel(t); changed = true }
		if ctrl && rl.IsKeyPressed(.V) { cb := rl.GetClipboardText(); if cb != nil { if tf_insert_str(t, string(cb)) do changed = true } }
		cw2 := tf_prefix_w(t, t.caret); avail := r.width - 16 // rola p/ manter o cursor visível
		if cw2 - t.scroll > avail do t.scroll = cw2 - avail
		if cw2 - t.scroll < 0     do t.scroll = cw2
		if t.scroll < 0 do t.scroll = 0
		tx0 = r.x + 8 - t.scroll
	}
	rl.BeginScissorMode(i32(r.x + 2), i32(r.y), i32(r.width - 4), i32(r.height))
	if focused^ && t.sel != t.caret {
		xa := tx0 + tf_prefix_w(t, tf_lo(t)); xb := tx0 + tf_prefix_w(t, tf_hi(t))
		rl.DrawRectangleRec({ xa, r.y + 5, xb - xa, r.height - 10 }, rl.Color{ 58, 108, 170, 150 })
	}
	txt(cs(string(t.buf[:t.len])), tx0, r.y + 7, 14, TEXT)
	if focused^ && t.sel == t.caret && (int(rl.GetTime()*2)) % 2 == 0 {
		rl.DrawRectangleRec({ tx0 + tf_prefix_w(t, t.caret), r.y + 6, 1.5, 18 }, TEXT)
	}
	rl.EndScissorMode()
	return changed
}

// painel do inspector para um clipe de TEXTO: campo editável, tamanho, cor, opacidade.
draw_text_inspector :: proc(c: ^Clip, sg: ^Seg, card: rl.Rectangle, x, pad, cw: f32) {
	y := card.y + 32
	if sg.opacity <= 0 do sg.opacity = 1
	if c.text_size <= 0 do c.text_size = 0.10
	vx := card.x + cw - pad - 46
	// --- campo de texto: clique posiciona o cursor, arrastar seleciona, duplo-clique
	//     seleciona tudo; digitar/Backspace/Delete substituem a seleção; Ctrl+A/C/V/X ---
	txt("Conteúdo", x, y, 13, TEXT); y += 20
	fr := rl.Rectangle{ x, y, cw - 2*pad, 30 }
	rl.DrawRectangleRounded(fr, 0.2, 4, PANEL2)
	if !txt_edit do tf_set(&tf_text, c.text) // fora de edição: espelha o conteúdo atual do clipe
	if tf_field(&tf_text, fr, &txt_edit, true) do set_text_clip(c, string(tf_text.buf[:tf_text.len]))
	rl.DrawRectangleRoundedLinesEx(fr, 0.2, 4, 1, txt_edit ? ACCENT : LINE)
	if txt_edit && rl.IsKeyPressed(.ENTER) do txt_edit = false
	y += 42
	// --- fonte (seletor ◀ nome ▶) ---
	if len(text_fonts) > 1 {
		txt("Fonte", x, y, 13, TEXT); y += 20
		fbx := rl.Rectangle{ x, y, cw - 2*pad, 28 }
		rl.DrawRectangleRounded(fbx, 0.2, 4, PANEL2)
		rl.DrawRectangleRoundedLinesEx(fbx, 0.2, 4, 1, LINE)
		// só CLAMPA o índice salvo quando a carga em thread terminou — antes disso a fonte
		// do projeto pode só não ter chegado ainda (clampar cedo resetaria a escolha).
		if text_fonts_settled() && (c.text_font < 0 || c.text_font >= len(text_fonts)) do c.text_font = 0
		di := c.text_font; if di < 0 || di >= len(text_fonts) do di = 0 // exibição segura durante a carga
		la := rl.Rectangle{ fbx.x, fbx.y, 28, 28 }; ra := rl.Rectangle{ fbx.x + fbx.width - 28, fbx.y, 28, 28 }
		txt_c("<", la.x + 14, la.y + 6, 15, hovered(la) ? TEXT : MUTED)
		txt_c(">", ra.x + 14, ra.y + 6, 15, hovered(ra) ? TEXT : MUTED)
		txt_c(text_fonts[di].name, fbx.x + fbx.width/2, fbx.y + 6, 13, TEXT)
		n := len(text_fonts)
		if clicked(la) { c.text_font = (di - 1 + n) % n; dirty = true }
		if clicked(ra) || clicked({ fbx.x + 28, fbx.y, fbx.width - 56, 28 }) { c.text_font = (di + 1) % n; dirty = true }
		y += 36
	}
	// --- tamanho ---
	txt("Tamanho", x, y, 13, TEXT); txt(rl.TextFormat("%d%%", i32(c.text_size*100 + 0.5)), vx, y, 13, ACCENT); y += 20
	if ui_slider(11, { x, y, cw - 2*pad, 16 }, &c.text_size, 0.03, 0.4) do dirty = true
	y += 30
	// --- cor (swatches) ---
	txt("Cor", x, y, 13, TEXT); y += 20
	n := len(TEXT_COLORS)
	sw := (cw - 2*pad - f32(n-1)*6) / f32(n)
	for col, ci in TEXT_COLORS {
		sr := rl.Rectangle{ x + f32(ci)*(sw+6), y, sw, 24 }
		rl.DrawRectangleRounded(sr, 0.25, 4, col)
		same := c.text_color.r == col.r && c.text_color.g == col.g && c.text_color.b == col.b
		rl.DrawRectangleRoundedLinesEx(sr, 0.25, 4, same ? 2 : 1, same ? ACCENT : LINE)
		if clicked(sr) { c.text_color = col; dirty = true }
	}
	y += 34
	// --- opacidade ---
	txt("Opacidade", x, y, 13, TEXT); txt(rl.TextFormat("%d%%", i32(sg.opacity*100 + 0.5)), vx, y, 13, ACCENT); y += 20
	ui_slider(12, { x, y, cw - 2*pad, 16 }, &sg.opacity, 0, 1)
	y += 26
	txt("Arraste no preview para mover.", x, y, 11, MUTED)
}

// inspector do segmento selecionado — controles de áudio (volume/mudo/fade), estilo
// NLE. Desenhado como cartão sobre o canto do preview.
insp_tab: int = 1 // aba do inspector: 0=Vídeo 1=Áudio 2=Velocidade (Áudio é a implementada)

draw_seg_inspector :: proc(area: rl.Rectangle) {
	if selected < 0 || selected >= nsegs || !seg_ready(selected) { txt_edit = false; return }
	sg := &segs[selected]
	c := seg_src(selected)
	if !c.is_text do txt_edit = false // edição de texto só vale p/ clipe de texto selecionado
	pad: f32 = 12
	cw: f32 = 250
	vextra := 0 // linhas extras na aba Vídeo (fades preto aplicados + botão Remover recorte)
	alike := c.is_audio || sg.aonly // se comporta como áudio (aba Vídeo mostra "(sem vídeo)")
	if insp_tab == 0 && !c.is_text && !alike {
		if segs[selected].vfin  > 0.01 do vextra += 1
		if segs[selected].vfout > 0.01 do vextra += 1
	}
	crop_extra := (insp_tab == 0 && !c.is_text && !alike && seg_cropped(selected)) ? f32(30) : f32(0)
	ch := c.is_text ? f32(388) : (insp_tab == 0 ? (f32(378) + f32(vextra)*46 + crop_extra) : (insp_tab == 2 ? f32(212) : f32(260)))
	card := rl.Rectangle{ area.x + area.width - cw - 14, area.y + 14, cw, ch }
	g_insp_card = card // p/ o preview não roubar cliques daqui
	rl.DrawRectangleRounded(card, 0.06, 8, rl.Color{ 28, 31, 38, 236 })
	rl.DrawRectangleRoundedLinesEx(card, 0.06, 8, 1, LINE)
	x := card.x + pad
	txt(cs(c.name), x, card.y + 8, 12, MUTED)

	if c.is_text { // ---- painel de TEXTO (título/legenda): conteúdo, tamanho, cor, opacidade ----
		draw_text_inspector(c, sg, card, x, pad, cw)
		return
	}
	// abas (estilo NLE): Vídeo | Áudio | Velocidade
	tabs := []cstring{ "Vídeo", "Áudio", "Velocidade" }
	ty := card.y + 28
	tw := cw / f32(len(tabs))
	for tab, i in tabs {
		tr := rl.Rectangle{ card.x + f32(i)*tw, ty, tw, 24 }
		act := i == insp_tab
		if clicked(tr) do insp_tab = i
		txt_c(tab, tr.x + tw/2, tr.y + 5, 13, act ? TEXT : MUTED)
		if act do rl.DrawRectangleRec({ tr.x + 10, tr.y + 22, tw - 20, 2 }, ACCENT)
	}
	rl.DrawLine(i32(card.x + pad), i32(ty + 26), i32(card.x + cw - pad), i32(ty + 26), LINE)
	y := ty + 38

	vx := card.x + cw - pad - 46

	if insp_tab == 0 { // ---- VÍDEO: transform (escala/posição/rotação/opacidade) ----
		if c.is_audio || sg.aonly { txt("(clipe sem vídeo)", x, y, 13, MUTED); return }
		if sg.scale <= 0 do sg.scale = 1
		if sg.opacity <= 0 do sg.opacity = 1
		txt("Escala", x, y, 13, TEXT); txt(rl.TextFormat("%d%%", i32(sg.scale*100+0.5)), vx, y, 13, ACCENT); y += 20
		if ui_slider(4, { x, y, cw - 2*pad, 16 }, &sg.scale, 0.1, 3) { if abs(sg.scale-1) < 0.04 do sg.scale = 1 }
		y += 28
		txt("Posição X", x, y, 13, TEXT); txt(rl.TextFormat("%d", i32(sg.px*100)), vx, y, 13, ACCENT); y += 20
		if ui_slider(5, { x, y, cw - 2*pad, 16 }, &sg.px, -1, 1) { if abs(sg.px) < 0.03 do sg.px = 0 }
		y += 28
		txt("Posição Y", x, y, 13, TEXT); txt(rl.TextFormat("%d", i32(sg.py*100)), vx, y, 13, ACCENT); y += 20
		if ui_slider(6, { x, y, cw - 2*pad, 16 }, &sg.py, -1, 1) { if abs(sg.py) < 0.03 do sg.py = 0 }
		y += 28
		txt("Rotação", x, y, 13, TEXT); txt(rl.TextFormat("%d°", i32(sg.rot)), vx, y, 13, ACCENT); y += 20
		if ui_slider(7, { x, y, cw - 2*pad, 16 }, &sg.rot, -180, 180) { if abs(sg.rot) < 5 do sg.rot = 0 }
		y += 28
		txt("Opacidade", x, y, 13, TEXT); txt(rl.TextFormat("%d%%", i32(sg.opacity*100+0.5)), vx, y, 13, ACCENT); y += 20
		ui_slider(8, { x, y, cw - 2*pad, 16 }, &sg.opacity, 0, 1)
		y += 26
		// (o dissolver é ajustado direto na timeline: clique na pastilha do corte e arraste
		// as alças — o slider daqui foi removido a pedido do usuário)
		// fades preto (aparecem quando aplicados pelo painel Transições; arraste a 0 p/ remover)
		fmx := max(f32(0.2), sg.dur * 0.9)
		if sg.vfin > 0.01 {
			txt("Fade entrada", x, y, 13, TEXT); txt(rl.TextFormat("%.1fs", f64(sg.vfin)), vx, y, 13, ACCENT); y += 20
			if ui_slider(14, { x, y, cw - 2*pad, 16 }, &sg.vfin, 0, fmx) { if sg.vfin < 0.1 do sg.vfin = 0 }
			y += 26
		}
		if sg.vfout > 0.01 {
			txt("Fade saída", x, y, 13, TEXT); txt(rl.TextFormat("%.1fs", f64(sg.vfout)), vx, y, 13, ACCENT); y += 20
			if ui_slider(15, { x, y, cw - 2*pad, 16 }, &sg.vfout, 0, fmx) { if sg.vfout < 0.1 do sg.vfout = 0 }
			y += 26
		}
		// RECORTE espacial (crop): entra no modo de moldura no preview
		if ui_btn({ x, y, cw - 2*pad, 26 }, seg_cropped(selected) ? "Recortar (ativo)" : "Recortar", seg_cropped(selected)) {
			crop_mode = true
			if !seg_cropped(selected) { sg.crop_x = 0; sg.crop_y = 0; sg.crop_w = 1; sg.crop_h = 1 } // começa do quadro inteiro
		}
		y += 32
		if seg_cropped(selected) {
			if ui_btn({ x, y, cw - 2*pad, 24 }, "Remover recorte", false) {
				sg.crop_x = 0; sg.crop_y = 0; sg.crop_w = 0; sg.crop_h = 0
			}
			y += 30
		}
		if ui_btn({ x, y, cw - 2*pad, 26 }, "Resetar transform", false) {
			sg.scale = 1; sg.px = 0; sg.py = 0; sg.rot = 0; sg.opacity = 1
		}
		return
	}
	if insp_tab == 2 { // ---- VELOCIDADE ----
		if c.is_img { txt("(imagem: sem velocidade)", x, y, 13, MUTED); return }
		if sg.speed <= 0 do sg.speed = 1
		old_speed := sg.speed
		changed := false
		txt("Velocidade", x, y, 13, TEXT)
		txt(rl.TextFormat("%.2fx", f64(sg.speed)), vx - 6, y, 13, ACCENT); y += 20
		if ui_slider(9, { x, y, cw - 2*pad, 16 }, &sg.speed, 0.25, 4) {
			if abs(sg.speed - 1) < 0.08 do sg.speed = 1 // gruda em 1x
			changed = true
		}
		y += 28
		// presets rápidos
		bw := (cw - 2*pad - 2*6) / 3
		presets := [3]f32{ 0.5, 1, 2 }
		labels  := [3]cstring{ "0.5x", "1x", "2x" }
		for k in 0 ..< 3 {
			br := rl.Rectangle{ x + f32(k)*(bw+6), y, bw, 26 }
			if ui_btn(br, labels[k], abs(sg.speed - presets[k]) < 0.001) { sg.speed = presets[k]; changed = true }
		}
		y += 36
		// aplica: preserva o trecho da fonte (dur*speed) e recalcula a duração na timeline,
		// limitada pelo próximo clipe da trilha e pelo fim da fonte.
		if changed {
			span := sg.dur * old_speed
			nd := span / sg.speed
			limit := f32(1e9)
			for j in 0 ..< nsegs {
				if j == selected || segs[j].track != sg.track do continue
				if segs[j].start >= sg.start + 0.001 do limit = min(limit, segs[j].start)
			}
			nd = min(nd, limit - sg.start, (c.dur - sg.in_off) / sg.speed)
			sg.dur = max(0.05, nd)
		}
		txt("Duração", x, y, 13, TEXT); txt(timecode(sg.dur), vx - 10, y, 13, MUTED); y += 24
		txt("Muda o tom do áudio.", x, y, 11, MUTED)
		return
	}
	if !c.has_audio { // aba Áudio
		txt("(clipe sem áudio)", x, y, 13, MUTED)
		return
	}
	// volume
	txt("Volume", x, y, 13, TEXT)
	txt(rl.TextFormat("%d%%", i32(sg.vol * 100 + 0.5)), vx, y, 13, ACCENT); y += 20
	if ui_slider(1, { x, y, cw - 2*pad, 16 }, &sg.vol, 0, VOL_MAX) {
		if abs(sg.vol - 1) < 0.06 * VOL_MAX do sg.vol = 1 // gruda em 100%
	}
	y += 30
	// mudo + resetar
	if ui_btn({ x, y, 112, 26 }, sg.muted ? "Reativar som" : "Mudo", sg.muted) do sg.muted = !sg.muted
	if ui_btn({ x + 120, y, cw - 2*pad - 120, 26 }, "Resetar", false) {
		sg.vol = 1; sg.muted = false; sg.fade_in = 0; sg.fade_out = 0
	}
	y += 40
	fmax := max(f32(0.1), min(f32(5), sg.dur * 0.5)) // fade até metade do clipe (máx 5s)
	// fade in
	txt("Fade in", x, y, 13, TEXT)
	txt(rl.TextFormat("%.1fs", f64(sg.fade_in)), vx, y, 13, ACCENT); y += 20
	ui_slider(2, { x, y, cw - 2*pad, 16 }, &sg.fade_in, 0, fmax); y += 30
	// fade out
	txt("Fade out", x, y, 13, TEXT)
	txt(rl.TextFormat("%.1fs", f64(sg.fade_out)), vx, y, 13, ACCENT); y += 20
	ui_slider(3, { x, y, cw - 2*pad, 16 }, &sg.fade_out, 0, fmax)
}

// compõe as trilhas de vídeo sob o playhead (base->topo) dentro do frame {fx,fy,fw,fh},
// cada uma com seu transform (escala/posição/rotação/opacidade). Retorna se desenhou algo.
// sel_box=true desenha a caixa do segmento selecionado (só no editor, não na tela cheia).
// desenha o texto de um clipe de TEXTO dentro do canvas {fx,fy,fw,fh}, com o transform
// do segmento (tamanho×escala, posição, rotação, opacidade). Usado no preview E no PNG
// do export (mesma renderização = WYSIWYG). Sombra sutil p/ legibilidade sobre qualquer fundo.
// fonte escolhida do clipe de texto (índice válido; 0 se fora da faixa)
text_font_of :: proc(c: ^Clip) -> rl.Font {
	i := c.text_font
	if i < 0 || i >= len(text_fonts) do i = 0
	return len(text_fonts) > 0 ? text_fonts[i].font : ui_font
}

draw_text_into :: proc(c: ^Clip, sg: Seg, fx, fy, fw, fh: f32) {
	if !c.is_text || c.text == "" do return
	fnt := text_font_of(c)
	scl := sg.scale <= 0 ? f32(1) : sg.scale
	fsz := max(f32(10), c.text_size * fh * scl)
	spacing := fsz * 0.06
	t := cs(c.text)
	dim := rl.MeasureTextEx(fnt, t, fsz, spacing)
	cx := fx + fw/2 + sg.px*fw
	cy := fy + fh/2 + sg.py*fh
	op := sg.opacity <= 0 ? f32(1) : sg.opacity
	col := c.text_color; col.a = u8(clamp(op, 0, 1) * 255)
	sh := rl.Color{ 0, 0, 0, u8(clamp(op, 0, 1) * 150) }
	origin := rl.Vector2{ dim.x/2, dim.y/2 } // centraliza o texto no ponto (cx,cy)
	off := max(f32(1), fsz*0.03)
	if sdf_ok do rl.BeginShaderMode(sdf_shader)
	rl.DrawTextPro(fnt, t, { cx + off, cy + off }, origin, sg.rot, fsz, spacing, sh)
	rl.DrawTextPro(fnt, t, { cx, cy },             origin, sg.rot, fsz, spacing, col)
	if sdf_ok do rl.EndShaderMode()
}

// renderiza o texto do segmento num PNG RGBA (transparente) do tamanho do canvas de
// export, via RenderTexture (mesma fonte/shader do preview). Roda na MAIN (GL).
render_text_png :: proc(c: ^Clip, sg: Seg, path: string) -> bool {
	W, H := export_dims()
	rt := rl.LoadRenderTexture(i32(W), i32(H))
	if rt.texture.id == 0 do return false
	rl.BeginTextureMode(rt)
	rl.ClearBackground(rl.BLANK) // fundo transparente
	draw_text_into(c, sg, 0, 0, f32(W), f32(H))
	rl.EndTextureMode()
	img := rl.LoadImageFromTexture(rt.texture)
	rl.ImageFlipVertical(&img) // RenderTexture vem espelhado no eixo Y
	ok := rl.ExportImage(img, strings.clone_to_cstring(path, context.temp_allocator))
	rl.UnloadImage(img)
	rl.UnloadRenderTexture(rt)
	return ok
}

// desenha UM segmento de vídeo/texto no canvas com um multiplicador de opacidade
// (usado pelo blend da transição: clipe que sai × (1-p), clipe que entra × p).
draw_seg_composited :: proc(i: int, opac_mul, fx, fy, fw, fh: f32, sel_box: bool) {
	c := seg_src(i)
	sg := segs[i]
	// fade preto (rampa de opacidade) — só na região NORMAL do clipe (não no lead-in de dissolver)
	bfade := f32(1)
	if st.playhead >= sg.start {
		p := st.playhead - sg.start
		if sg.vfin  > 0.01 && p < sg.vfin              do bfade = min(bfade, clamp(p / sg.vfin, 0, 1))
		if sg.vfout > 0.01 && p > sg.dur - sg.vfout    do bfade = min(bfade, clamp((sg.dur - p) / sg.vfout, 0, 1))
	}
	op := (sg.opacity <= 0 ? f32(1) : sg.opacity) * clamp(opac_mul, 0, 1) * bfade
	if c.is_text { // clipe de texto: desenha a própria fonte (sem textura)
		sg2 := sg; sg2.opacity = op
		draw_text_into(c, sg2, fx, fy, fw, fh)
		if sel_box && i == selected {
			scl := sg.scale <= 0 ? f32(1) : sg.scale
			fsz := max(f32(10), c.text_size*fh*scl); sp := fsz*0.06
			dim := rl.MeasureTextEx(text_font_of(c), cs(c.text), fsz, sp)
			bxc := fx + fw/2 + sg.px*fw; byc := fy + fh/2 + sg.py*fh
			rl.DrawRectangleLinesEx({ bxc - dim.x/2 - 6, byc - dim.y/2 - 4, dim.x + 12, dim.y + 8 }, 1.5, ACCENT)
		}
		return
	}
	ensure_tex(c)
	// vista duplicada (mesma fonte em trilha mais baixa): desenha a textura própria
	// do seg; enquanto ela não tem frame, cai na textura da fonte (frame do outro seg)
	tex := c.tex
	tw_ := f32(cdw(c)); th_ := f32(cdh(c)) // dims da textura EM USO (src e UVs derivam daqui)
	if seg_is_dup(i) && seg_dup[i].ok && seg_dup[i].src == sg.src do tex = seg_dup[i].tex
	else if !c.tex_ok do return
	else if c.streaming && c.thumbs_ready && c.nthumbs > 0 {
		// o frame em c.tex está LONGE do alvo (arrastando o playhead, ou o respawn de
		// um clique-seek ainda em voo): mostra a MINIATURA do filmstrip do ponto certo —
		// borrada, mas feedback INSTANTÂNEO na posição do cursor (estilo NLE); o frame
		// nítido substitui assim que o decode assíncrono chega (tex_t alcança o alvo).
		// Só fora do playback contínuo: um catch-up tocando NÃO deve piscar miniatura.
		lt := seg_local(i, st.playhead)
		waiting := st.drag == .Playhead || !st.playing || intrinsics.atomic_load(&c.rsp_busy)
		past_eof := c.eof_at > 0 && lt >= c.eof_at - 0.05 // além do fim real: congela (comportamento antigo)
		if waiting && !past_eof && abs(lt - c.tex_t) > SCRUB_SHARP_S {
			tex = c.thumbs[clamp(int(lt / c.thumb_dt), 0, c.nthumbs - 1)]
			tw_ = f32(THUMB_W); th_ = f32(THUMB_H)
			if st.playing do dbg_thumb_frames += 1 // diagnóstico: miniatura mostrada DURANTE o playback (flash borrado)
		}
	}
	s := sg.scale <= 0 ? f32(1) : sg.scale
	// RECORTE: fonte = sub-região; ajusta a REGIÃO recortada ao canvas preservando o aspecto dela.
	// seg_crop_at anima a região no tempo quando zoom_anim (Pan & Zoom); senão = recorte estático.
	crx, cry, crw, crh := seg_crop_at(i, st.playhead)
	// QUADRO da fonte = conteúdo real (sem o pillarbox do DEC): crop e fit passam a operar no
	// aspecto verdadeiro, então 9:16 numa timeline 9:16 PREENCHE (antes o quadro 16:9 encolhia o vertical).
	cr := dec_content_rect(c)
	if tw_ != f32(cdw(c)) { // textura de miniatura: mesma geometria pillarbox, escala menor
		k := tw_ / f32(cdw(c))
		cr = { cr.x*k, cr.y*k, cr.width*k, cr.height*k }
	}
	src := rl.Rectangle{ cr.x + crx*cr.width, cr.y + cry*cr.height, crw*cr.width, crh*cr.height }
	cwpx := crw*cr.width; chpx := crh*cr.height
	tf := min(fw/cwpx, fh/chpx) // ajusta a região recortada ao canvas preservando aspecto
	dw := cwpx*tf*s; dh := chpx*tf*s
	ccx := fx + fw/2 + sg.px*fw; ccy := fy + fh/2 + sg.py*fh
	tint := rl.Color{ 255, 255, 255, u8(clamp(op, 0, 1) * 255) }
	// COR: só o que o clipe tem (aba "Cor"); os clipes de EFEITO não são de cor.
	efb := sg.fx_bright; efc := sg.fx_contrast; efs := sg.fx_satur
	eft := sg.fx_temp; efv := sg.fx_vignette; efl := sg.fx_look
	// DISTORÇÃO efetiva: a do clipe; se ele não tiver e o efeito de FAIXA sob o playhead for
	// Distorção, aplica os parâmetros DELE (centro relativo ao quadro, tremor no tempo do efeito).
	b_str := bulge_at(sg, st.playhead - sg.start)
	b_cx := clamp(0.5+sg.bulge_x, 0, 1); b_cy := clamp(0.5+sg.bulge_y, 0, 1)
	b_r := sg.bulge_r <= 0 ? BULGE_R_DEF : sg.bulge_r
	rgb_off := [2]f32{ 0, 0 } // separação RGB do efeito de faixa (0 = desligado)
	// efeito de FAIXA que rege ESTA trilha (na trilha do seg ou numa acima — "afeta o que está embaixo")
	af := is_audio_track(sg.track) ? -1 : fx_for_track(sg.track)
	if af >= 0 {
		fs := fxsegs[af]
		if fs.kind == FX_DISTORT && !bulge_active(sg) {
			b_str = fx_bulge_strength(fs, st.playhead - fs.start)
			b_cx = clamp(0.5+fs.cx, 0, 1); b_cy = clamp(0.5+fs.cy, 0, 1); b_r = fs.radius <= 0 ? BULGE_R_DEF : fs.radius
		} else if fs.kind == FX_RGB {
			rgb_off = fx_rgb_offset(fs)
		}
	}
	use_fx := bulge_ok && (fx_any(sg) || af >= 0)
	if use_fx {
		br := b_r
		uv0 := [2]f32{ src.x/tw_, src.y/th_ } // src no espaço da textura EM USO (c.tex ou miniatura)
		uv1 := [2]f32{ (src.x+src.width)/tw_, (src.y+src.height)/th_ }
		ctr := [2]f32{ b_cx, b_cy }
		asp := dh > 0 ? dw/dh : 1
		st_ := b_str
		rl.SetShaderValue(bulge_shader, bulge_loc_uv0, &uv0, .VEC2)
		rl.SetShaderValue(bulge_shader, bulge_loc_uv1, &uv1, .VEC2)
		rl.SetShaderValue(bulge_shader, bulge_loc_center, &ctr, .VEC2)
		rl.SetShaderValue(bulge_shader, bulge_loc_strength, &st_, .FLOAT)
		rl.SetShaderValue(bulge_shader, bulge_loc_radius, &br, .FLOAT)
		rl.SetShaderValue(bulge_shader, bulge_loc_aspect, &asp, .FLOAT)
		// uniforms de COR (neutro quando 0): contraste/saturação efetivos = 1+valor
		cbr := efb; cco := 1 + efc; csa := 1 + efs
		clk := efl; cvg := efv; ctp := eft
		rl.SetShaderValue(bulge_shader, fx_loc_bright, &cbr, .FLOAT)
		rl.SetShaderValue(bulge_shader, fx_loc_contrast, &cco, .FLOAT)
		rl.SetShaderValue(bulge_shader, fx_loc_satur, &csa, .FLOAT)
		rl.SetShaderValue(bulge_shader, fx_loc_look, &clk, .FLOAT)
		rl.SetShaderValue(bulge_shader, fx_loc_vignette, &cvg, .FLOAT)
		rl.SetShaderValue(bulge_shader, fx_loc_temp, &ctp, .FLOAT)
		rl.SetShaderValue(bulge_shader, fx_loc_rgb, &rgb_off, .VEC2)
		rl.BeginShaderMode(bulge_shader)
	}
	rl.DrawTexturePro(tex, src, { ccx, ccy, dw, dh }, { dw/2, dh/2 }, sg.rot, tint)
	if use_fx do rl.EndShaderMode()
	if sel_box && i == selected {
		rad := sg.rot * math.PI/180; cs_ := math.cos(rad); sn := math.sin(rad)
		hw := dw/2; hh := dh/2
		cor :: proc(cx, cy, ox, oy, cs_, sn: f32) -> rl.Vector2 { return { cx + ox*cs_ - oy*sn, cy + ox*sn + oy*cs_ } }
		p0 := cor(ccx, ccy, -hw, -hh, cs_, sn); p1 := cor(ccx, ccy, hw, -hh, cs_, sn)
		p2 := cor(ccx, ccy, hw, hh, cs_, sn); p3 := cor(ccx, ccy, -hw, hh, cs_, sn)
		rl.DrawLineEx(p0, p1, 1.5, ACCENT); rl.DrawLineEx(p1, p2, 1.5, ACCENT)
		rl.DrawLineEx(p2, p3, 1.5, ACCENT); rl.DrawLineEx(p3, p0, 1.5, ACCENT)
	}
}

// segmento B cuja transição CENTRADA no corte cobre `time` na trilha t. A janela é
// [B.start - D/2, B.start + D/2] (metade em cada clipe). -1 se nenhum.
trans_overlap :: proc(t: int, time: f32) -> int {
	for i in 0 ..< nsegs {
		if !seg_ready(i) || segs[i].track != t do continue
		d := seg_trans(i)
		if d > 0 {
			half := d/2
			if time >= segs[i].start - half && time < segs[i].start + half do return i
		}
	}
	return -1
}

composite_video :: proc(fx, fy, fw, fh: f32, sel_box: bool) -> bool {
	any := false
	for t in 0 ..< g_nv {
		if track_hidden[t] do continue // trilha oculta (olho): não compõe no preview
		tb := trans_overlap(t, st.playhead) // transição centrada cobrindo o playhead?
		if tb >= 0 {
			a := trans_prev(tb)
			half := seg_trans(tb)/2; cut := segs[tb].start
			p := clamp((st.playhead - (cut - half)) / (2*half), 0, 1) // 0 no início do overlap, 1 no fim
			if a >= 0 { any = true; draw_seg_composited(a, 1-p, fx, fy, fw, fh, sel_box) } // SAI (cauda)
			any = true; draw_seg_composited(tb, p, fx, fy, fw, fh, sel_box)                // ENTRA (cabeça)
		} else {
			cur := seg_on_track_at(t, st.playhead)
			if cur >= 0 { any = true; draw_seg_composited(cur, 1, fx, fy, fw, fh, sel_box) }
		}
	}
	return any
}

// editor de RECORTE (crop): mostra o quadro COMPLETO do clipe selecionado ajustado ao canvas,
// escurece fora da região, e desenha 8 alças arrastáveis (cantos/bordas) + moldura de terços.
// Edita sg.crop_* diretamente (frações da fonte). Chamado no preview quando crop_mode.
draw_crop_editor :: proc(fx, fy, fw, fh: f32) {
	if selected < 0 || selected >= nsegs do return
	sg := &segs[selected]
	c := seg_src(selected)
	ensure_tex(c)
	cr := dec_content_rect(c)
	tff := min(fw/cr.width, fh/cr.height) // quadro de CONTEÚDO (aspecto da fonte) ajustado ao canvas
	fdw := cr.width*tff; fdh := cr.height*tff
	frx := fx + (fw-fdw)/2; fry := fy + (fh-fdh)/2
	if c.tex_ok do rl.DrawTexturePro(c.tex, cr, {frx,fry,fdw,fdh}, {0,0}, 0, rl.WHITE)
	crx, cry, crw, crh := seg_crop(selected)
	CR := rl.Rectangle{ frx+crx*fdw, fry+cry*fdh, crw*fdw, crh*fdh }
	// escurece fora do recorte (4 faixas em volta da região mantida)
	dim := rl.Color{ 0,0,0,150 }
	rl.DrawRectangleRec({frx, fry, fdw, CR.y-fry}, dim)
	rl.DrawRectangleRec({frx, CR.y+CR.height, fdw, (fry+fdh)-(CR.y+CR.height)}, dim)
	rl.DrawRectangleRec({frx, CR.y, CR.x-frx, CR.height}, dim)
	rl.DrawRectangleRec({CR.x+CR.width, CR.y, (frx+fdw)-(CR.x+CR.width), CR.height}, dim)
	rl.DrawRectangleLinesEx(CR, 1.5, rl.WHITE)
	for k in 1 ..< 3 { // guias de terços
		gx := CR.x + CR.width*f32(k)/3; gy := CR.y + CR.height*f32(k)/3
		rl.DrawLineEx({gx, CR.y},{gx, CR.y+CR.height}, 1, rl.Color{255,255,255,80})
		rl.DrawLineEx({CR.x, gy},{CR.x+CR.width, gy}, 1, rl.Color{255,255,255,80})
	}
	Hd := [8]rl.Vector2{
		{CR.x,CR.y},{CR.x+CR.width,CR.y},{CR.x+CR.width,CR.y+CR.height},{CR.x,CR.y+CR.height}, // cantos
		{CR.x+CR.width/2,CR.y},{CR.x+CR.width,CR.y+CR.height/2},{CR.x+CR.width/2,CR.y+CR.height},{CR.x,CR.y+CR.height/2}, // bordas
	}
	m := rl.GetMousePosition()
	for p, k in Hd {
		hov := crop_drag==k || (crop_drag<0 && abs(m.x-p.x)<9 && abs(m.y-p.y)<9)
		rl.DrawRectangleRec({p.x-5,p.y-5,10,10}, hov ? ACCENT : rl.WHITE)
		rl.DrawRectangleLinesEx({p.x-5,p.y-5,10,10}, 1, rl.Color{30,30,30,220})
	}
	// input: pegar alça / região; arrastar edita as frações
	if rl.IsMouseButtonPressed(.LEFT) && crop_drag<0 {
		hit := -1
		for p, k in Hd do if abs(m.x-p.x)<10 && abs(m.y-p.y)<10 { hit=k; break }
		if hit<0 && rl.CheckCollisionPointRec(m, CR) { hit=8; crop_grab = { (m.x-frx)/fdw - crx, (m.y-fry)/fdh - cry } }
		crop_drag = hit
	}
	if crop_drag>=0 && rl.IsMouseButtonDown(.LEFT) {
		mfx := clamp((m.x-frx)/fdw, 0, 1); mfy := clamp((m.y-fry)/fdh, 0, 1)
		x0:=crx; y0:=cry; x1:=crx+crw; y1:=cry+crh
		MIN :: f32(0.06)
		switch crop_drag {
		case 0: x0=min(mfx,x1-MIN); y0=min(mfy,y1-MIN)
		case 1: x1=max(mfx,x0+MIN); y0=min(mfy,y1-MIN)
		case 2: x1=max(mfx,x0+MIN); y1=max(mfy,y0+MIN)
		case 3: x0=min(mfx,x1-MIN); y1=max(mfy,y0+MIN)
		case 4: y0=min(mfy,y1-MIN)
		case 5: x1=max(mfx,x0+MIN)
		case 6: y1=max(mfy,y0+MIN)
		case 7: x0=min(mfx,x1-MIN)
		case 8: // mover mantendo o tamanho
			nx := clamp((m.x-frx)/fdw - crop_grab.x, 0, 1-crw); ny := clamp((m.y-fry)/fdh - crop_grab.y, 0, 1-crh)
			x0=nx; y0=ny; x1=nx+crw; y1=ny+crh
		}
		sg.crop_x=x0; sg.crop_y=y0; sg.crop_w=x1-x0; sg.crop_h=y1-y0
	}
	if rl.IsMouseButtonReleased(.LEFT) do crop_drag = -1
	rl.SetMouseCursor(.POINTING_HAND)
}

// ---------- modal "Cortar e Ampliar" ----------
// proporção da região (frações) que faz a área recortada preencher o quadro de saída sem tarjas:
// (w/h)*aspecto_fonte == proj_ar  =>  h = w * aspecto_fonte/proj_ar. Fonte e saída no mesmo aspecto
// => kh=1 (região cheia já preenche). Usa a fonte do seg selecionado (o modal opera sobre ele).
crop_lock_kh :: proc() -> f32 {
	car := selected >= 0 && selected < nsegs ? clip_ar(seg_src(selected)) : f32(DEC_W)/f32(DEC_H)
	return car / proj_ar
}

// conforma UMA região (por ponteiros p/ os 4 campos) à proporção travada, centrando na
// região existente (usado ao entrar na aba "Aproximar e Ampliar" e no Redefinir).
crop_conform_lock_q :: proc(qx, qy, qw, qh: ^f32) {
	kh := crop_lock_kh()
	w := qw^ <= 0 ? f32(1) : qw^
	cxr := (qw^ <= 0 ? f32(0) : qx^) + w/2
	cyr := (qh^ <= 0 ? f32(0) : qy^) + (qh^ <= 0 ? f32(1) : qh^)/2
	h := w*kh
	if h > 1 { h = 1; w = h/kh }
	qw^ = w; qh^ = h
	qx^ = clamp(cxr - w/2, 0, 1-w); qy^ = clamp(cyr - h/2, 0, 1-h)
}

// abre o modal p/ o segmento selecionado (só vídeo/imagem). Chamado pelo botão da toolbar.
open_crop_modal :: proc() {
	if selected < 0 || selected >= nsegs || !seg_ready(selected) do return
	c := seg_src(selected)
	if c.is_audio || c.is_text || segs[selected].aonly do return
	sg := &segs[selected]
	if !seg_cropped(selected) && !sg.zoom_anim { sg.crop_x = 0; sg.crop_y = 0; sg.crop_w = 1; sg.crop_h = 1 }
	crop_bk  = { sg.crop_x,  sg.crop_y,  sg.crop_w,  sg.crop_h }   // backup p/ Cancelar
	crop_bk2 = { sg.crop2_x, sg.crop2_y, sg.crop2_w, sg.crop2_h }
	crop_bk_anim = sg.zoom_anim
	crop_bk_seg = selected
	crop_tab = 1                 // abre direto na aba de zoom
	crop_animate = sg.zoom_anim
	crop_edit_end = false
	crop_play = false; crop_play_t = 0 // começa pausado no início do clipe
	crop_conform_lock_q(&sg.crop_x, &sg.crop_y, &sg.crop_w, &sg.crop_h) // trava início na proporção
	if sg.crop2_w <= 0 { sg.crop2_x=sg.crop_x; sg.crop2_y=sg.crop_y; sg.crop2_w=sg.crop_w; sg.crop2_h=sg.crop_h } // fim = início
	crop_conform_lock_q(&sg.crop2_x, &sg.crop2_y, &sg.crop2_w, &sg.crop2_h)
	crop_drag = -1
	modal = .Crop
	// leva o playhead pra dentro do clipe p/ a textura mostrar o frame certo
	if st.playhead < sg.start || st.playhead >= sg.start + sg.dur do seek_global(sg.start + sg.dur*0.5)
}
crop_modal_cancel :: proc() { // descarta: restaura recorte + animação originais
	if crop_bk_seg >= 0 && crop_bk_seg < nsegs {
		sg := &segs[crop_bk_seg]
		sg.crop_x =crop_bk[0];  sg.crop_y =crop_bk[1];  sg.crop_w =crop_bk[2];  sg.crop_h =crop_bk[3]
		sg.crop2_x=crop_bk2[0]; sg.crop2_y=crop_bk2[1]; sg.crop2_w=crop_bk2[2]; sg.crop2_h=crop_bk2[3]
		sg.zoom_anim = crop_bk_anim
	}
	modal = .None; crop_bk_seg = -1; crop_drag = -1; crop_play = false
	show_playhead_frame() // restaura o frame do preview no playhead (o play do modal mexeu na textura)
}
crop_modal_ok :: proc() { // aplica
	if crop_bk_seg >= 0 && crop_bk_seg < nsegs {
		sg := &segs[crop_bk_seg]
		sg.zoom_anim = crop_animate && crop_tab == 1 // animação só faz sentido na aba de zoom
		// estático + região ~cheia = "sem recorte" (zero-value, evita marcar como recortado à toa)
		if !sg.zoom_anim && sg.crop_w > 0.999 && sg.crop_h > 0.999 { sg.crop_x=0; sg.crop_y=0; sg.crop_w=0; sg.crop_h=0 }
	}
	modal = .None; crop_bk_seg = -1; crop_drag = -1; crop_play = false
	show_playhead_frame() // restaura o frame do preview no playhead (o play do modal mexeu na textura)
}

// desenha o CONTORNO de uma região (fantasma do quadro inativo no modo animado)
crop_rect_ghost :: proc(qx, qy, qw, qh, frx, fry, fdw, fdh: f32, col: rl.Color) {
	nx, ny, nw, nh := crop_norm(qx, qy, qw, qh)
	R := rl.Rectangle{ frx+nx*fdw, fry+ny*fdh, nw*fdw, nh*fdh }
	rl.DrawRectangleLinesEx(R, 1.4, col)
}

// desenha e edita UMA região (ponteiros p/ os 4 campos) sobre o frame. lock=true trava a
// proporção. col = cor do contorno/alças (branco no crop; verde=início, vermelho=fim).
crop_rect_editor :: proc(qx, qy, qw, qh: ^f32, frx, fry, fdw, fdh: f32, lock: bool, col: rl.Color) {
	crx := qw^ <= 0 ? f32(0) : clamp(qx^, 0, 1)
	cry := qh^ <= 0 ? f32(0) : clamp(qy^, 0, 1)
	crw := qw^ <= 0 ? f32(1) : qw^
	crh := qh^ <= 0 ? f32(1) : qh^
	CR := rl.Rectangle{ frx+crx*fdw, fry+cry*fdh, crw*fdw, crh*fdh }
	dim := rl.Color{ 0,0,0,150 }
	rl.DrawRectangleRec({frx, fry, fdw, CR.y-fry}, dim)
	rl.DrawRectangleRec({frx, CR.y+CR.height, fdw, (fry+fdh)-(CR.y+CR.height)}, dim)
	rl.DrawRectangleRec({frx, CR.y, CR.x-frx, CR.height}, dim)
	rl.DrawRectangleRec({CR.x+CR.width, CR.y, (frx+fdw)-(CR.x+CR.width), CR.height}, dim)
	rl.DrawRectangleLinesEx(CR, 1.5, col)
	for k in 1 ..< 3 { // guias de terços
		gx := CR.x + CR.width*f32(k)/3; gy := CR.y + CR.height*f32(k)/3
		rl.DrawLineEx({gx, CR.y},{gx, CR.y+CR.height}, 1, rl.Color{255,255,255,80})
		rl.DrawLineEx({CR.x, gy},{CR.x+CR.width, gy}, 1, rl.Color{255,255,255,80})
	}
	Hd := [8]rl.Vector2{
		{CR.x,CR.y},{CR.x+CR.width,CR.y},{CR.x+CR.width,CR.y+CR.height},{CR.x,CR.y+CR.height}, // cantos
		{CR.x+CR.width/2,CR.y},{CR.x+CR.width,CR.y+CR.height/2},{CR.x+CR.width/2,CR.y+CR.height},{CR.x,CR.y+CR.height/2}, // bordas
	}
	nH := lock ? 4 : 8 // travado: só os 4 cantos (bordas quebrariam a proporção)
	m := rl.GetMousePosition()
	for k in 0 ..< nH {
		p := Hd[k]
		hov := crop_drag==k || (crop_drag<0 && abs(m.x-p.x)<9 && abs(m.y-p.y)<9)
		rl.DrawRectangleRec({p.x-5,p.y-5,10,10}, hov ? ACCENT : col)
		rl.DrawRectangleLinesEx({p.x-5,p.y-5,10,10}, 1, rl.Color{30,30,30,220})
	}
	if rl.IsMouseButtonPressed(.LEFT) && crop_drag<0 {
		hit := -1
		for k in 0 ..< nH do if abs(m.x-Hd[k].x)<10 && abs(m.y-Hd[k].y)<10 { hit=k; break }
		if hit<0 && rl.CheckCollisionPointRec(m, CR) { hit=8; crop_grab = { (m.x-frx)/fdw - crx, (m.y-fry)/fdh - cry } }
		crop_drag = hit
	}
	if crop_drag>=0 && rl.IsMouseButtonDown(.LEFT) {
		mfx := clamp((m.x-frx)/fdw, 0, 1); mfy := clamp((m.y-fry)/fdh, 0, 1)
		x0:=crx; y0:=cry; x1:=crx+crw; y1:=cry+crh
		MIN :: f32(0.06)
		if crop_drag == 8 { // mover mantendo o tamanho
			nx := clamp((m.x-frx)/fdw - crop_grab.x, 0, 1-crw); ny := clamp((m.y-fry)/fdh - crop_grab.y, 0, 1-crh)
			x0=nx; y0=ny; x1=nx+crw; y1=ny+crh
		} else if lock { // canto k: âncora = canto oposto (fixo); altura = largura*kh
			kh := crop_lock_kh()
			ax, ay: f32
			switch crop_drag {
			case 0: ax=x1; ay=y1
			case 1: ax=x0; ay=y1
			case 2: ax=x0; ay=y0
			case 3: ax=x1; ay=y0
			}
			w := max(abs(mfx-ax), MIN); h := w*kh
			left  := crop_drag==0 || crop_drag==3
			top   := crop_drag==0 || crop_drag==1
			if left  && ax-w < 0 { w = ax;   h = w*kh } // não passar da borda esquerda
			if !left && ax+w > 1 { w = 1-ax; h = w*kh } // ...direita
			if top   && ay-h < 0 { h = ay;   w = h/kh } // ...topo
			if !top  && ay+h > 1 { h = 1-ay; w = h/kh } // ...base
			w = max(w, MIN); h = max(h, MIN)
			x0 = left ? ax-w : ax; x1 = left ? ax : ax+w
			y0 = top  ? ay-h : ay; y1 = top  ? ay : ay+h
		} else { // recorte livre
			switch crop_drag {
			case 0: x0=min(mfx,x1-MIN); y0=min(mfy,y1-MIN)
			case 1: x1=max(mfx,x0+MIN); y0=min(mfy,y1-MIN)
			case 2: x1=max(mfx,x0+MIN); y1=max(mfy,y0+MIN)
			case 3: x0=min(mfx,x1-MIN); y1=max(mfy,y0+MIN)
			case 4: y0=min(mfy,y1-MIN)
			case 5: x1=max(mfx,x0+MIN)
			case 6: y1=max(mfy,y0+MIN)
			case 7: x0=min(mfx,x1-MIN)
			}
		}
		qx^=clamp(x0,0,1); qy^=clamp(y0,0,1)
		qw^=clamp(x1-x0,MIN,1); qh^=clamp(y1-y0,MIN,1)
	}
	if crop_drag>=0 && rl.IsMouseButtonReleased(.LEFT) do crop_drag = -1
}

CROP_START_COL :: rl.Color{ 90, 200, 120, 255 } // quadro Início (verde)
CROP_END_COL   :: rl.Color{ 235, 95, 82, 255 }   // quadro Fim (vermelho)

// modal em si (chamado por draw_modal). Frame + retângulo(s) + abas + animação + rodapé.
draw_crop_modal :: proc(sw, sh: f32) {
	if crop_bk_seg < 0 || crop_bk_seg >= nsegs || !seg_ready(crop_bk_seg) ||
	   seg_audio_like(crop_bk_seg) || seg_src(crop_bk_seg).is_text {
		modal = .None; crop_bk_seg = -1; crop_drag = -1; return
	}
	selected = crop_bk_seg // mantém o resto da UI apontando p/ o mesmo segmento
	sg := &segs[crop_bk_seg]
	c := seg_src(crop_bk_seg)

	rl.DrawRectangleRec({0,0,sw,sh}, rl.Color{ 0,0,0,180 })
	cw: f32 = 640; chh: f32 = 552
	cx := sw/2 - cw/2; cy := sh/2 - chh/2
	card := rl.Rectangle{ cx, cy, cw, chh }
	rl.DrawRectangleRounded(card, 0.03, 8, rl.Color{ 30, 33, 40, 255 })
	rl.DrawRectangleRoundedLinesEx(card, 0.03, 8, 1, LINE)

	txt("Cortar e Ampliar", cx + 22, cy + 16, 18, TEXT)
	xr := rl.Rectangle{ cx + cw - 38, cy + 16, 24, 24 }
	if clicked(xr) { crop_modal_cancel(); return }
	rl.DrawLineEx({xr.x+6,xr.y+6},{xr.x+16,xr.y+16}, 1.8, hovered(xr) ? TEXT : MUTED)
	rl.DrawLineEx({xr.x+16,xr.y+6},{xr.x+6,xr.y+16}, 1.8, hovered(xr) ? TEXT : MUTED)

	// abas
	tabs := []cstring{ "Cortar", "Aproximar e Ampliar" }
	tws  := []f32{ 90, 180 }
	tx := cx + 22; ty := cy + 46
	for tab, i in tabs {
		tr := rl.Rectangle{ tx, ty, tws[i], 26 }
		if clicked(tr) {
			if i == 1 && crop_tab != 1 do crop_conform_lock_q(&sg.crop_x, &sg.crop_y, &sg.crop_w, &sg.crop_h)
			crop_tab = i
		}
		txt_c(tab, tr.x + tws[i]/2, tr.y + 6, 13, i == crop_tab ? TEXT : MUTED)
		if i == crop_tab do rl.DrawRectangleRec({ tr.x + 8, tr.y + 24, tws[i] - 16, 2 }, ACCENT)
		tx += tws[i] + 6
	}
	rl.DrawLine(i32(cx+22), i32(ty+28), i32(cx+cw-22), i32(ty+28), LINE)

	// linha de controles da animação (só na aba de zoom)
	ctrl_y := ty + 40
	if crop_tab == 1 {
		chk := rl.Rectangle{ cx + 22, ctrl_y, 18, 18 }
		if clicked(chk) do crop_animate = !crop_animate
		rl.DrawRectangleRoundedLinesEx(chk, 0.2, 4, 1.5, crop_animate ? ACCENT : MUTED)
		if crop_animate do rl.DrawRectangleRec({ chk.x+4, chk.y+4, 10, 10 }, ACCENT)
		txt("Animar zoom (Início → Fim)", chk.x + 26, ctrl_y + 2, 13, TEXT)
		if crop_animate { // seletor de qual quadro editar
			bi := rl.Rectangle{ cx + cw - 22 - 180, ctrl_y - 3, 86, 24 }
			bf := rl.Rectangle{ cx + cw - 22 - 88,  ctrl_y - 3, 86, 24 }
			if clicked(bi) do crop_edit_end = false
			if clicked(bf) do crop_edit_end = true
			rl.DrawRectangleRounded(bi, 0.3, 5, !crop_edit_end ? rl.Color{40,78,52,255} : PANEL2)
			rl.DrawRectangleRounded(bf, 0.3, 5,  crop_edit_end ? rl.Color{92,42,38,255} : PANEL2)
			txt_c("Início", bi.x + bi.width/2, bi.y + 5, 12, CROP_START_COL)
			txt_c("Fim",    bf.x + bf.width/2, bf.y + 5, 12, CROP_END_COL)
		}
	}

	// área do vídeo (painel único). Pausado = frame + retângulos (editar); tocando = resultado.
	va_top := ctrl_y + (crop_tab == 1 ? f32(32) : f32(0))
	va := rl.Rectangle{ cx + 22, va_top, cw - 44, chh - (va_top - cy) - 100 }
	rl.DrawRectangleRec(va, rl.BLACK)
	ensure_tex(c)
	dur := max(sg.dur, 0.0001)
	if crop_play { // avança a reprodução (vídeo-só; loopa no fim)
		crop_play_t += rl.GetFrameTime()
		if crop_play_t >= dur do crop_play_t = 0
	}
	clip_frame(c, clamp(sg.in_off + crop_play_t*seg_speed(crop_bk_seg), 0, c.dur)) // frame no tempo atual
	cr := dec_content_rect(c)
	tff := min(va.width/cr.width, va.height/cr.height)
	fdw := cr.width*tff; fdh := cr.height*tff
	frx := va.x + (va.width-fdw)/2; fry := va.y + (va.height-fdh)/2

	if crop_play { // TOCANDO: mostra o resultado (região recortada ampliada), sem alças
		rx, ry, rw, rh: f32
		if crop_tab == 1 && crop_animate {
			f := crop_play_t/dur; f = f*f*(3 - 2*f) // smoothstep (== render)
			ax, ay, aw, ah := crop_norm(sg.crop_x,  sg.crop_y,  sg.crop_w,  sg.crop_h)
			bx, by, bw, bh := crop_norm(sg.crop2_x, sg.crop2_y, sg.crop2_w, sg.crop2_h)
			rx=ax+(bx-ax)*f; ry=ay+(by-ay)*f; rw=aw+(bw-aw)*f; rh=ah+(bh-ah)*f
		} else {
			rx, ry, rw, rh = crop_norm(sg.crop_x, sg.crop_y, sg.crop_w, sg.crop_h)
		}
		cav_w := min(va.width, va.height*proj_ar); cav_h := cav_w/proj_ar
		cav_x := va.x + (va.width-cav_w)/2; cav_y := va.y + (va.height-cav_h)/2
		rasp := (rw / rh) * clip_ar(c)
		dw := min(cav_w, cav_h*rasp); dh := dw/rasp
		if c.tex_ok do rl.DrawTexturePro(c.tex, { cr.x + rx*cr.width, cr.y + ry*cr.height, rw*cr.width, rh*cr.height },
			{ cav_x+(cav_w-dw)/2, cav_y+(cav_h-dh)/2, dw, dh }, {0,0}, 0, rl.WHITE)
	} else { // PAUSADO: frame inteiro + retângulos de edição
		if c.tex_ok do rl.DrawTexturePro(c.tex, cr, {frx,fry,fdw,fdh}, {0,0}, 0, rl.WHITE)
		if crop_tab == 0 {
			crop_rect_editor(&sg.crop_x, &sg.crop_y, &sg.crop_w, &sg.crop_h, frx, fry, fdw, fdh, false, rl.WHITE)
		} else if !crop_animate {
			crop_rect_editor(&sg.crop_x, &sg.crop_y, &sg.crop_w, &sg.crop_h, frx, fry, fdw, fdh, true, rl.WHITE)
		} else if crop_edit_end {
			crop_rect_editor(&sg.crop2_x, &sg.crop2_y, &sg.crop2_w, &sg.crop2_h, frx, fry, fdw, fdh, true, CROP_END_COL)
			crop_rect_ghost(sg.crop_x, sg.crop_y, sg.crop_w, sg.crop_h, frx, fry, fdw, fdh, CROP_START_COL)
		} else {
			crop_rect_editor(&sg.crop_x, &sg.crop_y, &sg.crop_w, &sg.crop_h, frx, fry, fdw, fdh, true, CROP_START_COL)
			crop_rect_ghost(sg.crop2_x, sg.crop2_y, sg.crop2_w, sg.crop2_h, frx, fry, fdw, fdh, CROP_END_COL)
		}
	}

	// --- transporte: play/pause + barra de posição + timecode (reproduz dentro do modal) ---
	tp_y := va.y + va.height + 8
	pb := rl.Rectangle{ cx + 22, tp_y, 30, 24 }
	if clicked(pb) do crop_play = !crop_play
	rl.DrawRectangleRounded(pb, 0.3, 5, hovered(pb) ? HOVER : PANEL2)
	pcx := pb.x + pb.width/2; pcy := pb.y + pb.height/2
	if crop_play { // ícone pausa
		rl.DrawRectangleRec({ pcx-5, pcy-6, 3.5, 12 }, TEXT); rl.DrawRectangleRec({ pcx+1.5, pcy-6, 3.5, 12 }, TEXT)
	} else { // ícone play (triângulo)
		rl.DrawTriangle({ pcx-4, pcy-6 }, { pcx-4, pcy+6 }, { pcx+6, pcy }, TEXT)
	}
	tc :: proc(s: f32) -> cstring { v := int(s + 0.001); return rl.TextFormat("%d:%02d", v/60, v%60) }
	tcw := f32(96)
	sb := rl.Rectangle{ pb.x + 42, tp_y + 10, cw - 44 - 42 - tcw, 5 }
	if rl.IsMouseButtonPressed(.LEFT) && hovered({ sb.x-4, tp_y, sb.width+8, 24 }) do crop_play = false // scrub pausa
	if !crop_play && rl.IsMouseButtonDown(.LEFT) && hovered({ sb.x-4, tp_y, sb.width+8, 24 }) {
		crop_play_t = clamp((rl.GetMousePosition().x - sb.x)/sb.width, 0, 1) * dur
	}
	rl.DrawRectangleRounded(sb, 1, 4, LINE)
	kf := clamp(crop_play_t/dur, 0, 1)
	rl.DrawRectangleRounded({ sb.x, sb.y, kf*sb.width, sb.height }, 1, 4, ACCENT)
	rl.DrawCircleV({ sb.x + kf*sb.width, sb.y + 2 }, 6, ACCENT)
	txt(rl.TextFormat("%s / %s", tc(crop_play_t), tc(dur)), sb.x + sb.width + 12, tp_y + 4, 12, MUTED)

	// rodapé
	if ui_btn({ cx + 22, cy + chh - 46, 116, 32 }, "Redefinir", false) {
		if crop_tab == 1 {
			sg.crop_x=0; sg.crop_y=0; sg.crop_w=1; sg.crop_h=1
			crop_conform_lock_q(&sg.crop_x, &sg.crop_y, &sg.crop_w, &sg.crop_h)
			sg.crop2_x=sg.crop_x; sg.crop2_y=sg.crop_y; sg.crop2_w=sg.crop_w; sg.crop2_h=sg.crop_h
		} else {
			sg.crop_x=0; sg.crop_y=0; sg.crop_w=1; sg.crop_h=1
		}
	}
	if ui_btn({ cx + cw - 224, cy + chh - 46, 100, 32 }, "Cancelar", false) { crop_modal_cancel(); return }
	if ui_btn({ cx + cw - 114, cy + chh - 46, 92, 32 }, "OK", true) { crop_modal_ok(); return }
}

draw_preview :: proc(r: rl.Rectangle) {
	pt := prof_beg(.Preview); defer prof_end(.Preview, pt)
	transport_h: f32 = 66 // barra de progresso (topo) + linha de botões
	video := rl.Rectangle{ r.x, r.y, r.width, r.height - transport_h }
	rl.DrawRectangleRec(video, rl.BLACK)

	// CANVAS ajustado à área de preview: proporção do projeto — ou, na prévia de origem, a da fonte
	par := preview_ar()
	scaleC := min(video.width/par, video.height)
	fw := par*scaleC; fh := scaleC
	fx := video.x + (video.width-fw)/2; fy := video.y + (video.height-fh)/2
	g_frame = { fx, fy, fw, fh }

	// recorta ao CANVAS: o que passa da moldura de saída não aparece (vídeo ampliado/movido)
	rl.BeginScissorMode(i32(fx), i32(fy), i32(fw), i32(fh))
	if src_preview >= 0 { // PRÉVIA de origem: fonte na PRÓPRIA proporção, preenchendo o canvas
		c := &clips[src_preview]
		ensure_tex(c)
		if c.tex_ok do rl.DrawTexturePro(c.tex, dec_content_rect(c), g_frame, {0,0}, 0, rl.WHITE)
		txt(rl.TextFormat("Prévia: %s  (clique na timeline p/ sair)", cs(c.name)), video.x + 10, video.y + 8, 12, rl.Color{245,205,90,235})
		txt(rl.TextFormat("Prévia: %s  (clique na timeline p/ sair)", cs(c.name)), video.x + 10, video.y + 8, 12, rl.Color{245,205,90,235})
	} else if crop_mode && selected >= 0 && selected < nsegs && seg_ready(selected) && !seg_audio_like(selected) && !seg_src(selected).is_text {
		// MODO RECORTE: mostra o quadro completo do clipe + moldura de recorte com alças
		draw_crop_editor(fx, fy, fw, fh)
	} else {
		// COMPOSITING das trilhas de vídeo com transform (mesma função da tela cheia)
		if !composite_video(fx, fy, fw, fh, true) {
			txt_c("Preview", video.x + video.width/2, video.y + video.height/2 - 10, 16, rl.Color{60,64,72,255})
		}
	}
	// guias de alinhamento (centro/bordas do canvas) ao mover um clipe no preview
	if st.drag == .PreviewMove {
		gc := rl.Color{ 40, 220, 200, 235 }
		if g_pv_x >= 0 do rl.DrawLineEx({ g_pv_x, g_frame.y }, { g_pv_x, g_frame.y + g_frame.height }, 1.2, gc)
		if g_ph_y >= 0 do rl.DrawLineEx({ g_frame.x, g_ph_y }, { g_frame.x + g_frame.width, g_ph_y }, 1.2, gc)
	}
	rl.EndScissorMode()
	rl.DrawRectangleLinesEx(g_frame, 1, rl.Color{ 70, 76, 88, 160 }) // moldura do canvas de saída

	// barra do modo recorte: instrução + botão Concluir (sai do modo)
	if crop_mode {
		if selected < 0 || selected >= nsegs || !seg_ready(selected) || seg_audio_like(selected) || seg_src(selected).is_text {
			crop_mode = false // seleção inválida p/ recorte
		} else {
			// faixa escura no topo p/ leitura + instrução
			rl.DrawRectangleRec({ video.x, video.y, video.width, 44 }, rl.Color{ 0,0,0,140 })
			txt("Recorte: arraste as alças para escolher a área", video.x + 14, video.y + 15, 14, rl.Color{245,205,90,245})
			// botão CONCLUIR bem visível (preenchido, com um check desenhado)
			bw2: f32 = 176; bh2: f32 = 30
			cb := rl.Rectangle{ video.x + video.width - bw2 - 12, video.y + 7, bw2, bh2 }
			rl.DrawRectangleRounded(cb, 0.35, 6, hovered(cb) ? ACCENT : ACCENT_D)
			rl.DrawRectangleRoundedLinesEx(cb, 0.35, 6, 1.5, ACCENT)
			ck := rl.Vector2{ cb.x + 24, cb.y + bh2/2 } // marca de "check"
			rl.DrawLineEx({ck.x-7, ck.y+1}, {ck.x-2, ck.y+6}, 2.6, rl.WHITE)
			rl.DrawLineEx({ck.x-2, ck.y+6}, {ck.x+8, ck.y-6}, 2.6, rl.WHITE)
			txt("Concluir recorte", cb.x + 42, cb.y + bh2/2 - 8, 14, rl.WHITE)
			if clicked(cb) do crop_mode = false
		}
	}

	tb := rl.Rectangle{ r.x, r.y + r.height - transport_h, r.width, transport_h }
	rl.DrawRectangleRec(tb, PANEL)
	rl.DrawRectangle(i32(tb.x), i32(tb.y), i32(tb.width), 1, LINE)

	// --- barra de progresso do player (posição atual + duração total, arrastável) ---
	total := src_preview >= 0 ? (src_preview < nclips ? clips[src_preview].dur : 0) : timeline_dur()
	pos   := src_preview >= 0 ? src_t : st.playhead
	pbar := rl.Rectangle{ tb.x + 16, tb.y + 12, tb.width - 32, 5 }
	pbar_hit := rl.Rectangle{ pbar.x - 4, tb.y + 5, pbar.width + 8, 18 }
	frac := total > 0 ? clamp(pos / total, 0, 1) : 0
	rl.DrawRectangleRounded(pbar, 1, 4, rl.Color{ 50, 54, 64, 255 })
	rl.DrawRectangleRounded({ pbar.x, pbar.y, frac * pbar.width, pbar.height }, 1, 4, ACCENT)
	pkx := pbar.x + frac * pbar.width
	rl.DrawCircleV({ pkx, pbar.y + pbar.height/2 }, (player_seek_drag || hovered(pbar_hit)) ? 7 : 5, rl.WHITE)
	if rl.IsMouseButtonPressed(.LEFT) && hovered(pbar_hit) { player_seek_drag = true; st.playing = false }
	if rl.IsMouseButtonReleased(.LEFT) && player_seek_drag {
		player_seek_drag = false
		if src_preview >= 0 { src_acquire(); clip_frame(&clips[src_preview], src_t) } else do seek_global(st.playhead)
	}
	if player_seek_drag && total > 0 {
		np := clamp((rl.GetMousePosition().x - pbar.x) / pbar.width, 0, 1) * total
		if src_preview >= 0 {
			src_t = np
			if !clips[src_preview].streaming do clip_show(&clips[src_preview], int(np * cfps_of(&clips[src_preview]))) // cache: scrub instantâneo
		} else {
			st.playhead = np
			v := view_seg()
			if v >= 0 && !seg_src(v).streaming do clip_show(seg_src(v), int(seg_local(v, np) * cfps_of(seg_src(v))))
		}
	}

	cx := tb.x + tb.width/2
	cy := tb.y + 42 // linha de botões abaixo da barra de progresso

	rl.DrawTriangle({cx - 60, cy - 7}, {cx - 60, cy + 7}, {cx - 68, cy}, TEXT)
	rl.DrawRectangleRec({cx - 70, cy - 7, 2, 14}, TEXT)
	rl.DrawTriangle({cx - 34, cy - 7}, {cx - 34, cy + 7}, {cx - 42, cy}, TEXT)

	pr := rl.Rectangle{ cx - 16, cy - 16, 32, 32 }
	rl.DrawCircleV({cx, cy}, 16, hovered(pr) ? ACCENT : ACCENT_D)
	if clicked(pr) do toggle_play()
	if st.playing {
		rl.DrawRectangleRec({cx - 6, cy - 7, 4, 14}, rl.WHITE)
		rl.DrawRectangleRec({cx + 2, cy - 7, 4, 14}, rl.WHITE)
	} else {
		rl.DrawTriangle({cx - 5, cy - 8}, {cx - 5, cy + 8}, {cx + 8, cy}, rl.WHITE)
	}

	rl.DrawTriangle({cx + 34, cy - 7}, {cx + 42, cy}, {cx + 34, cy + 7}, TEXT)
	rl.DrawTriangle({cx + 60, cy - 7}, {cx + 68, cy}, {cx + 60, cy + 7}, TEXT)
	rl.DrawRectangleRec({cx + 68, cy - 7, 2, 14}, TEXT)

	sr := rl.Rectangle{ cx + 92, cy - 7, 14, 14 }
	if clicked(sr) {
		st.playing = false
		if src_preview >= 0 { src_t = 0; src_acquire(); clip_frame(&clips[src_preview], 0) }
		else do seek_global(0)
	}
	rl.DrawRectangleRec(sr, hovered(sr) ? TEXT : MUTED)

	// timecode à esquerda: posição ATUAL / duração TOTAL
	txt(rl.TextFormat("%s / %s", timecode(pos), timecode(total)), tb.x + 16, cy - 8, 15, TEXT)

	// --- cluster à direita: volume do player | screenshot | tela cheia ---
	// tela cheia (canto): 4 cantoneiras
	fsr := rl.Rectangle{ tb.x + tb.width - 30, cy - 10, 20, 20 }
	if clicked(fsr) do toggle_fullscreen_preview()
	{
		fc := hovered(fsr) ? ACCENT : TEXT
		L :: f32(6)
		rl.DrawLineEx({fsr.x, fsr.y}, {fsr.x + L, fsr.y}, 2, fc);              rl.DrawLineEx({fsr.x, fsr.y}, {fsr.x, fsr.y + L}, 2, fc)
		rl.DrawLineEx({fsr.x + fsr.width - L, fsr.y}, {fsr.x + fsr.width, fsr.y}, 2, fc); rl.DrawLineEx({fsr.x + fsr.width, fsr.y}, {fsr.x + fsr.width, fsr.y + L}, 2, fc)
		rl.DrawLineEx({fsr.x, fsr.y + fsr.height - L}, {fsr.x, fsr.y + fsr.height}, 2, fc); rl.DrawLineEx({fsr.x, fsr.y + fsr.height}, {fsr.x + L, fsr.y + fsr.height}, 2, fc)
		rl.DrawLineEx({fsr.x + fsr.width, fsr.y + fsr.height - L}, {fsr.x + fsr.width, fsr.y + fsr.height}, 2, fc); rl.DrawLineEx({fsr.x + fsr.width - L, fsr.y + fsr.height}, {fsr.x + fsr.width, fsr.y + fsr.height}, 2, fc)
	}
	// screenshot (câmera): corpo + lente
	shr := rl.Rectangle{ fsr.x - 32, cy - 9, 22, 18 }
	if clicked(shr) do open_shot_modal()
	{
		cc := hovered(shr) ? ACCENT : TEXT
		rl.DrawRectangleRoundedLinesEx(shr, 0.25, 4, 1.6, cc)
		rl.DrawRectangleRec({shr.x + 6, shr.y - 3, 6, 4}, cc) // saliência do topo
		rl.DrawCircleLinesV({shr.x + shr.width/2, shr.y + shr.height/2}, 4, cc)
	}
	// alto-falante: clique ABRE o slider VERTICAL de volume (popup). Antes era um slider
	// horizontal fixo que confundia com o zoom da timeline.
	spr := rl.Rectangle{ shr.x - 30, cy - 9, 20, 18 }
	if clicked(spr) do vol_popup = !vol_popup
	{
		sc := player_vol < 0.01 ? rl.Color{ 210, 100, 100, 255 } : ((hovered(spr) || vol_popup) ? ACCENT : TEXT)
		bx := spr.x + 3; bcy := spr.y + spr.height/2
		rl.DrawRectangleRec({bx, bcy - 3, 3.5, 6}, sc)                               // corpo (ímã)
		rl.DrawTriangle({bx + 3.5, bcy - 6}, {bx + 3.5, bcy + 6}, {bx + 9, bcy}, sc) // cone
		if player_vol < 0.01 {
			rl.DrawLineEx({bx + 11, bcy - 4}, {bx + 17, bcy + 4}, 1.8, sc)
			rl.DrawLineEx({bx + 17, bcy - 4}, {bx + 11, bcy + 4}, 1.8, sc)
		} else {
			rl.DrawRing({bx + 6, bcy}, 5.2, 6.4, -55, 55, 12, sc) // onda externa
			rl.DrawRing({bx + 6, bcy}, 3.0, 3.9, -55, 55, 12, sc) // onda interna
		}
	}
	// qualidade da prévia p/ clipes STREAMING (longos): Baixa=360p (leve) <-> Alta=720p
	// (nítido, ~4x os bytes/frame). Estilo dropdown "Total/1/2/..." de NLEs, aqui binário.
	{
		qlabel: cstring = stream_hi ? "Alta" : "Baixa"
		qw := txt_w(qlabel, 12) + 22
		qr := rl.Rectangle{ spr.x - 14 - qw, cy - 11, qw, 22 }
		rl.DrawRectangleRounded(qr, 0.35, 6, hovered(qr) ? HOVER : PANEL2)
		rl.DrawRectangleRoundedLinesEx(qr, 0.35, 6, 1, stream_hi ? ACCENT : LINE)
		txt_c(qlabel, qr.x + qr.width/2, qr.y + 4, 12, stream_hi ? ACCENT : TEXT)
		if clicked(qr) do set_stream_quality(!stream_hi)
	}
	if vol_popup { // painel com slider VERTICAL acima do alto-falante
		pw := f32(34); ph := f32(108)
		pr := rl.Rectangle{ spr.x + spr.width/2 - pw/2, cy - 14 - ph, pw, ph }
		rl.DrawRectangleRounded(pr, 0.2, 8, rl.Color{ 28, 31, 38, 250 })
		rl.DrawRectangleRoundedLinesEx(pr, 0.2, 8, 1, LINE)
		ui_vslider(10, { pr.x + pw/2 - 8, pr.y + 12, 16, ph - 42 }, &player_vol, 0, 1)
		txt_c(rl.TextFormat("%d", i32(player_vol*100 + 0.5)), pr.x + pw/2, pr.y + ph - 22, 12, TEXT)
		// clicar fora (sem ser no botão nem arrastando o slider) fecha
		if rl.IsMouseButtonPressed(.LEFT) && !hovered(pr) && !hovered(spr) && ui_slider_active != 10 do vol_popup = false
	}

	// --- formato do projeto: botão + dropdown rápido de presets ("Personalizar…" abre o modal) ---
	arb := rl.Rectangle{ spr.x - 150, cy - 11, 64, 22 }
	if clicked(arb) do ar_menu_open = !ar_menu_open
	rl.DrawRectangleRounded(arb, 0.3, 4, (ar_menu_open || hovered(arb)) ? HOVER : PANEL2)
	txt(ar_label(proj_ar), arb.x + 8, arb.y + 4, 12, TEXT)
	rl.DrawTriangle({ arb.x + arb.width - 14, arb.y + 9 }, { arb.x + arb.width - 6, arb.y + 9 }, { arb.x + arb.width - 10, arb.y + 14 }, MUTED)
	if ar_menu_open {
		ih := f32(26); mw := f32(130); mh := f32(len(AR_PRESETS) + 1) * ih + 8
		mr := rl.Rectangle{ arb.x, arb.y - mh - 4, mw, mh }
		rl.DrawRectangleRounded(mr, 0.08, 6, rl.Color{ 28, 31, 38, 248 })
		rl.DrawRectangleRoundedLinesEx(mr, 0.08, 6, 1, LINE)
		for p, idx in AR_PRESETS {
			ir := rl.Rectangle{ mr.x + 4, mr.y + 4 + f32(idx)*ih, mw - 8, ih }
			sel := abs(proj_ar - p.ar) < 0.001
			if hovered(ir) do rl.DrawRectangleRounded(ir, 0.3, 4, HOVER)
			if sel do rl.DrawCircleV({ ir.x + ir.width - 14, ir.y + ih/2 }, 3, ACCENT) // marca o ativo
			txt(p.label, ir.x + 12, ir.y + 5, 13, sel ? ACCENT : TEXT)
			if clicked(ir) { set_proj_ar(p.ar); ar_menu_open = false; ar_auto = false } // preset rápido (lado menor = 1080)
		}
		// "Personalizar…" -> abre o modal completo (resolução exata)
		cpr := rl.Rectangle{ mr.x + 4, mr.y + 4 + f32(len(AR_PRESETS))*ih, mw - 8, ih }
		rl.DrawLineEx({ mr.x + 8, cpr.y - 1 }, { mr.x + mw - 8, cpr.y - 1 }, 1, LINE)
		if hovered(cpr) do rl.DrawRectangleRounded(cpr, 0.3, 4, HOVER)
		txt("Personalizar…", cpr.x + 12, cpr.y + 5, 13, TEXT)
		if clicked(cpr) { ar_menu_open = false; open_projset_modal() }
		if rl.IsMouseButtonPressed(.LEFT) && !hovered(mr) && !hovered(arb) do ar_menu_open = false // clique fora fecha
	}

	g_insp_card = {} // repovoado por draw_seg_inspector se houver seleção
	if !crop_mode do draw_seg_inspector(video) // no modo recorte o cartão fica oculto (tapava o Concluir)

	// ALÇA do CENTRO da distorção: na aba Efeitos, com o efeito ativo, desenha um alvo
	// arrastável (+ anel do raio) sobre o preview p/ posicionar o centro sem os sliders.
	if !crop_mode && src_preview < 0 && st.active_tab == 2 && selected >= 0 && selected < nsegs &&
	   !seg_audio_like(selected) && !seg_src(selected).is_text && bulge_active(segs[selected]) &&
	   seg_on_track_at(segs[selected].track, st.playhead) == selected && g_frame.width > 0 {
		m := rl.GetMousePosition()
		sg := segs[selected]
		s := sg.scale <= 0 ? f32(1) : sg.scale
		ccx := g_frame.x + g_frame.width/2 + sg.px*g_frame.width
		ccy := g_frame.y + g_frame.height/2 + sg.py*g_frame.height
		rw := g_frame.width*s; rh := g_frame.height*s
		rad := sg.rot * math.PI/180; cs_ := math.cos(rad); sn := math.sin(rad)
		ox := sg.bulge_x*rw; oy := sg.bulge_y*rh
		hx := ccx + ox*cs_ - oy*sn; hy := ccy + ox*sn + oy*cs_
		// anel do raio: no shader dist usa aspect=rw/rh, então a fronteira é um círculo de
		// raio (bulge_r * altura) em pixels de tela (independe da largura).
		rr := (sg.bulge_r <= 0 ? BULGE_R_DEF : sg.bulge_r) * rh
		rl.DrawCircleLines(i32(hx), i32(hy), rr, rl.Color{ 245, 205, 90, 150 })
		// alvo (crosshair + círculo)
		near_h := abs(m.x-hx) < 14 && abs(m.y-hy) < 14
		hot := st.drag == .FxCenter || near_h
		col := hot ? ACCENT : rl.Color{ 245, 205, 90, 235 }
		rl.DrawCircleLines(i32(hx), i32(hy), 11, col)
		rl.DrawLineEx({hx-16, hy}, {hx-4, hy}, 2, col); rl.DrawLineEx({hx+4, hy}, {hx+16, hy}, 2, col)
		rl.DrawLineEx({hx, hy-16}, {hx, hy-4}, 2, col); rl.DrawLineEx({hx, hy+4}, {hx, hy+16}, 2, col)
		rl.DrawCircleV({hx, hy}, 3, col)
		if near_h && !hovered(g_insp_card) && st.drag == .None && ui_slider_active == -1 &&
		   rl.IsMouseButtonPressed(.LEFT) && !ctx_open && !ctx_ate {
			st.drag = .FxCenter; drag_clip = selected
		}
		if hot do rl.SetMouseCursor(.RESIZE_ALL)
	}

	// alvo do CENTRO da distorção do CLIPE DE EFEITO selecionado (arrasta no preview p/ mover
	// o centro sem os sliders). Só quando é Distorção e está sob o playhead (efeito visível).
	if !crop_mode && src_preview < 0 && fx_sel >= 0 && fx_sel < nfx && g_frame.width > 0 &&
	   fxsegs[fx_sel].kind == FX_DISTORT && st.playhead >= fxsegs[fx_sel].start && st.playhead < fxsegs[fx_sel].start + fxsegs[fx_sel].dur {
		f := fxsegs[fx_sel]
		m := rl.GetMousePosition()
		ccx := g_frame.x + g_frame.width/2 + f.cx*g_frame.width
		ccy := g_frame.y + g_frame.height/2 + f.cy*g_frame.height
		rr := (f.radius <= 0 ? BULGE_R_DEF : f.radius) * g_frame.height
		// recorta ao quadro do vídeo p/ o anel não vazar pra fora do preview
		rl.BeginScissorMode(i32(g_frame.x), i32(g_frame.y), i32(g_frame.width), i32(g_frame.height))
		// anel LISO desenhado à mão (DrawCircleLines/DrawRing deixavam um "bico"/emenda num ponto)
		{
			ringcol := rl.Color{ 245, 205, 90, 150 }; N :: 160
			prev := rl.Vector2{ ccx + rr, ccy }
			for k in 1 ..= N {
				a := f32(k)/f32(N) * 2*math.PI
				cur := rl.Vector2{ ccx + rr*math.cos(a), ccy + rr*math.sin(a) }
				rl.DrawLineEx(prev, cur, 1.2, ringcol)
				prev = cur
			}
		}
		near := abs(m.x-ccx) < 14 && abs(m.y-ccy) < 14
		hot := st.drag == .FxCtr || near
		col := hot ? ACCENT : rl.Color{ 245, 205, 90, 235 }
		rl.DrawCircleLines(i32(ccx), i32(ccy), 11, col)
		rl.DrawLineEx({ccx-16, ccy}, {ccx-4, ccy}, 2, col); rl.DrawLineEx({ccx+4, ccy}, {ccx+16, ccy}, 2, col)
		rl.DrawLineEx({ccx, ccy-16}, {ccx, ccy-4}, 2, col); rl.DrawLineEx({ccx, ccy+4}, {ccx, ccy+16}, 2, col)
		rl.DrawCircleV({ccx, ccy}, 3, col)
		rl.EndScissorMode()
		if near && !hovered(g_insp_card) && st.drag == .None && ui_slider_active == -1 &&
		   rl.IsMouseButtonPressed(.LEFT) && !ctx_open && !ctx_ate {
			st.drag = .FxCtr
		}
		if hot do rl.SetMouseCursor(.RESIZE_ALL)
	}

	// arrastar o clipe de vídeo SELECIONADO no preview p/ reposicionar (PiP). Só se ele
	// está visível sob o playhead e o clique não é no cartão do inspector. (A alça do efeito
	// tem prioridade: se agarrou o centro acima, st.drag != None e isto não dispara.)
	if !crop_mode && src_preview < 0 && selected >= 0 && selected < nsegs && !seg_audio_like(selected) &&
	   seg_on_track_at(segs[selected].track, st.playhead) == selected {
		m := rl.GetMousePosition()
		sg := segs[selected]
		s := sg.scale <= 0 ? 1 : sg.scale
		ccx := g_frame.x + g_frame.width/2 + sg.px*g_frame.width
		ccy := g_frame.y + g_frame.height/2 + sg.py*g_frame.height
		hw := g_frame.width*s/2; hh := g_frame.height*s/2
		inside := abs(m.x-ccx) <= hw && abs(m.y-ccy) <= hh
		if inside && !hovered(g_insp_card) && st.drag == .None && ui_slider_active == -1 &&
		   rl.IsMouseButtonPressed(.LEFT) && !ctx_open && !ctx_ate {
			st.drag = .PreviewMove; drag_clip = selected; prev_grab = { m.x-ccx, m.y-ccy }
		}
	}
}

// EFEITOS na timeline: cada um é um CLIPE de altura cheia na sua trilha (igual um vídeo) e
// ocupa o espaço com EXCLUSIVIDADE (nada se sobrepõe). Desenha + trata seleção/mover/apagar;
// o drop (criar) e a continuação do arraste ficam no update.
// retângulo do clipe de efeito i (altura cheia da trilha), igual ao de um segmento de vídeo.
fx_rect :: proc(i: int) -> rl.Rectangle {
	f := fxsegs[i]
	return { tl_x(f.start), track_y(f.track) + 4, max(f32(8), f.dur * pps()), g_track_h - 8 }
}
// clipe de efeito cujo retângulo contém o ponto m; -1 se nenhum. Do topo (último desenhado) p/ baixo.
fx_bar_at :: proc(m: rl.Vector2) -> int {
	for i := nfx - 1; i >= 0; i -= 1 do if rl.CheckCollisionPointRec(m, fx_rect(i)) do return i
	return -1
}
// desenha os clipes de EFEITO (altura cheia) na trilha de cada um. SEM scissor próprio: roda
// dentro do recorte das trilhas (rows_clip); `clip` só p/ culling vertical.
draw_fx_on_tracks :: proc(clip: rl.Rectangle) {
	m := rl.GetMousePosition()
	i := 0
	for i < nfx {
		f := &fxsegs[i]
		bar := fx_rect(i)
		if bar.y + bar.height < clip.y || bar.y > clip.y + clip.height { i += 1; continue } // fora da viewport
		sel := i == fx_sel
		rl.DrawRectangleRounded(bar, 0.12, 5, sel ? rl.Color{ 140, 118, 52, 245 } : rl.Color{ 108, 92, 44, 225 })
		rl.DrawRectangleRoundedLinesEx(bar, 0.12, 5, sel ? 2 : 1, sel ? rl.Color{ 240, 214, 120, 255 } : rl.Color{ 175, 155, 88, 210 })
		// faixa âmbar no topo p/ "cara de efeito" (distingue de um clipe de vídeo azul)
		rl.DrawRectangleRec({ bar.x + 2, bar.y + 2, bar.width - 4, 3 }, rl.Color{ 220, 190, 90, 220 })
		has_x := sel && bar.width > 46
		nx := has_x ? bar.x + 20 : bar.x + 8 // nome desloca p/ dar espaço ao × (à ESQUERDA)
		txt(fxlib_name(f.kind), nx, bar.y + 5, 11, rl.Color{ 248, 240, 210, 255 })
		xr := rl.Rectangle{ bar.x + 2, bar.y + 2, 16, 16 } // × à ESQUERDA (não colide com a alça de aparo)
		over_x := has_x && rl.CheckCollisionPointRec(m, xr)
		if has_x {
			txt_c("×", xr.x + xr.width/2, xr.y + 1, 15, rl.Color{ 245, 220, 205, 255 })
			if clicked(xr) { remove_fxseg(i); continue } // não incrementa i (o próximo desceu p/ cá)
		}
		// ALÇA DE APARO na borda direita (redimensionar a duração do efeito)
		grip := rl.Rectangle{ bar.x + bar.width - 8, bar.y, 8, bar.height }
		if sel do rl.DrawRectangleRec({ bar.x + bar.width - 3, bar.y + 3, 2, bar.height - 6 }, rl.Color{ 250, 230, 160, 255 })
		near_grip := rl.CheckCollisionPointRec(m, grip)
		if near_grip do rl.SetMouseCursor(.RESIZE_EW)
		if modal == .None && st.drag == .None && !over_x && rl.IsMouseButtonPressed(.LEFT) && rl.CheckCollisionPointRec(m, bar) {
			fx_sel = i; selected = -1; sel_trans = -1; bin_sel = -1
			st.active_tab = 2 // abre a aba Efeitos p/ mostrar as configurações do efeito
			if near_grip { st.drag = .FxTrim } // apara a borda direita (redimensiona)
			else { st.drag = .FxClip; fx_grab_dt = tl_t(m.x) - f.start } // move
		}
		i += 1
	}
	// fantasma do efeito arrastado da biblioteca: clipe na trilha de vídeo sob o cursor, no vão livre
	if st.drag == .FxLib && fxlib_drag >= 0 && rl.CheckCollisionPointRec(m, g_vlane) {
		ty := track_at_y(m.y)
		if !is_audio_track(ty) {
			tr := clamp(ty, 0, g_nv - 1)
			gx := tl_x(fx_free_start(tr, -1, max(0, tl_t(m.x - DROP_LEAD)), 3))
			rl.DrawRectangleRounded({ gx, track_y(tr) + 4, 3*pps(), g_track_h - 8 }, 0.12, 5, rl.Color{ 200, 175, 90, 150 })
		}
	}
}

// ---------- timeline ----------
draw_timeline :: proc(r: rl.Rectangle) {
	pt := prof_beg(.Timeline); defer prof_end(.Timeline, pt)
	toolbar_h: f32 = 34
	ruler_h: f32 = 22
	rl.DrawRectangleRec(r, PANEL2)
	rl.DrawRectangle(i32(r.x), i32(r.y), i32(r.width), 1, LINE)

	tb := rl.Rectangle{ r.x, r.y, r.width, toolbar_h }
	rl.DrawRectangleRec(tb, PANEL)
	rl.DrawRectangle(i32(tb.x), i32(tb.y + tb.height) - 1, i32(tb.width), 1, LINE)

	icon :: proc(x, cy: f32, kind: int) {
		switch kind {
		case 0:
			rl.DrawLineEx({x + 12, cy - 4}, {x + 4, cy}, 2, TEXT)
			rl.DrawLineEx({x + 4, cy}, {x + 12, cy + 4}, 2, TEXT)
			rl.DrawLineEx({x + 4, cy}, {x + 16, cy + 1}, 2, TEXT)
		case 1:
			rl.DrawLineEx({x + 4, cy - 4}, {x + 12, cy}, 2, TEXT)
			rl.DrawLineEx({x + 12, cy}, {x + 4, cy + 4}, 2, TEXT)
			rl.DrawLineEx({x + 12, cy}, {x, cy + 1}, 2, TEXT)
		case 2:
			rl.DrawRectangleRec({x + 3, cy - 3, 10, 9}, TEXT)
			rl.DrawRectangleRec({x + 1, cy - 6, 14, 2}, TEXT)
		}
	}
	ix := tb.x + 12
	for k in 0 ..< 3 {
		r2 := rl.Rectangle{ ix - 4, tb.y + 4, 26, 26 }
		// k==0 desfazer | k==1 refazer | k==2 lixeira (remove selecionado)
		can := (k == 0 && undo_top > 0) || (k == 1 && redo_top > 0) || (k == 2 && selected >= 0)
		if hovered(r2) do rl.DrawRectangleRounded(r2, 0.3, 4, can ? HOVER : PANEL2)
		if can && clicked(r2) {
			switch k {
			case 0: do_undo()
			case 1: do_redo()
			case 2: remove_seg(selected, !alt_down())
			}
		}
		icon(ix, tb.y + tb.height/2, k)
		ix += 30
	}

	// ferramenta lâmina: corta clicando direto no clipe (atalho B). Fica destacada quando ativa.
	br := rl.Rectangle{ ix - 4, tb.y + 4, 26, 26 }
	if clicked(br) do blade_mode = !blade_mode
	rl.DrawRectangleRounded(br, 0.3, 4, blade_mode ? ACCENT_D : (hovered(br) ? HOVER : PANEL2))
	{ // tesoura: duas lâminas cruzadas + dois eixos
		bcx := ix + 8; bcy := tb.y + tb.height/2
		bcol := blade_mode ? rl.WHITE : TEXT
		rl.DrawLineEx({bcx - 5, bcy + 5}, {bcx + 6, bcy - 6}, 1.6, bcol)
		rl.DrawLineEx({bcx + 5, bcy + 5}, {bcx - 6, bcy - 6}, 1.6, bcol)
		rl.DrawCircleLinesV({bcx - 5, bcy + 5}, 2.5, bcol)
		rl.DrawCircleLinesV({bcx + 5, bcy + 5}, 2.5, bcol)
	}
	ix += 34

	// botão "Cortar e Ampliar": abre o modal do retângulo de zoom (só p/ clipe de vídeo/imagem)
	cz_ok := selected >= 0 && selected < nsegs && seg_ready(selected) && !seg_audio_like(selected) && !seg_src(selected).is_text
	cz := rl.Rectangle{ ix - 4, tb.y + 4, 138, 26 }
	if cz_ok && clicked(cz) do open_crop_modal()
	rl.DrawRectangleRounded(cz, 0.3, 4, (hovered(cz) && cz_ok) ? HOVER : PANEL2)
	{ // ícone: cantos de recorte
		icx := cz.x + 15; icy := tb.y + tb.height/2; icol := cz_ok ? TEXT : rl.Color{ 92,96,104,255 }
		rl.DrawLineEx({icx-6, icy-6},{icx-6, icy+1}, 2, icol); rl.DrawLineEx({icx-6, icy-6},{icx+1, icy-6}, 2, icol)
		rl.DrawLineEx({icx+6, icy+6},{icx+6, icy-1}, 2, icol); rl.DrawLineEx({icx+6, icy+6},{icx-1, icy+6}, 2, icol)
	}
	txt("Cortar e Ampliar", cz.x + 30, tb.y + 10, 12, cz_ok ? TEXT : rl.Color{ 92,96,104,255 })
	ix += 144

	view_w := r.width - f32(LANE_X)
	g_view_w = view_w // guardado p/ o atalho F (ajustar à janela), tratado no update
	// botão "Ajustar": enquadra todo o conteúdo na janela (atalho F)
	fit_r := rl.Rectangle{ r.x + r.width - 190, tb.y + 6, 32, 22 }
	if clicked(fit_r) do tl_fit(view_w)
	rl.DrawRectangleRounded(fit_r, 0.3, 4, hovered(fit_r) ? HOVER : PANEL2)
	txt_c("Fit", fit_r.x + fit_r.width/2, fit_r.y + 5, 12, TEXT)
	zr_minus := rl.Rectangle{ r.x + r.width - 150, tb.y + 6, 22, 22 }
	zr_plus := rl.Rectangle{ r.x + r.width - 40, tb.y + 6, 22, 22 }
	// passos multiplicativos: casam com o slider log (aditivo daria saltos enormes perto do mínimo)
	if clicked(zr_minus) do tl_set_zoom(st.zoom / 1.3, view_w)
	if clicked(zr_plus)  do tl_set_zoom(st.zoom * 1.3, view_w)
	rl.DrawRectangleRounded(zr_minus, 0.3, 4, hovered(zr_minus) ? HOVER : PANEL2)
	rl.DrawRectangleRounded(zr_plus, 0.3, 4, hovered(zr_plus) ? HOVER : PANEL2)
	rl.DrawLineEx({zr_minus.x + 6, zr_minus.y + 11}, {zr_minus.x + 16, zr_minus.y + 11}, 2, TEXT)
	rl.DrawLineEx({zr_plus.x + 6, zr_plus.y + 11}, {zr_plus.x + 16, zr_plus.y + 11}, 2, TEXT)
	rl.DrawLineEx({zr_plus.x + 11, zr_plus.y + 6}, {zr_plus.x + 11, zr_plus.y + 16}, 2, TEXT)
	bar := rl.Rectangle{ zr_minus.x + 30, tb.y + 15, 76, 4 }
	// arrastar (ou clicar) o slider ajusta o zoom; área de toque mais alta que a barra
	bar_hit := rl.Rectangle{ bar.x - 6, tb.y + 6, bar.width + 12, 22 }
	if rl.IsMouseButtonPressed(.LEFT) && hovered(bar_hit) do zoom_bar_drag = true
	if rl.IsMouseButtonReleased(.LEFT) do zoom_bar_drag = false
	// mapeamento LOGARÍTMICO: cada passo do slider MULTIPLICA a escala, então o
	// controle fica suave de "vídeo inteiro na tela" (ZOOM_MIN) até frame a frame
	// (ZOOM_MAX). Linear deixaria quase todo o curso virar zoom-in.
	zratio := ZOOM_MAX / ZOOM_MIN
	if zoom_bar_drag {
		frac := clamp((rl.GetMousePosition().x - bar.x) / bar.width, 0, 1)
		tl_set_zoom(ZOOM_MIN * math.pow(zratio, frac), view_w)
	}
	rl.DrawRectangleRounded(bar, 1, 4, LINE)
	// frac clampado: após um "Fit", o zoom pode ficar abaixo de ZOOM_MIN — o knob
	// então encosta na ponta esquerda em vez de sair da barra.
	knob_frac := clamp(math.log(st.zoom / ZOOM_MIN, math.E) / math.log(zratio, math.E), 0, 1)
	knob := bar.x + knob_frac * bar.width
	rl.DrawCircle(i32(knob), i32(bar.y + 2), (zoom_bar_drag || hovered(bar_hit)) ? 7 : 6, ACCENT)

	// ----- geometria VERTICAL das trilhas (bandas pinadas + viewport rolável) -----
	// as bandas "criar trilha" ficam PINADAS (topo=vídeo, base=áudio); só as trilhas rolam entre elas.
	// São áreas de drop PERMANENTES (sempre visíveis, escuras, sem botão/rótulo): soltar mídia aqui
	// cria a trilha. Elas ABSORVEM o espaço vazio da timeline — com poucas trilhas ficam grandes;
	// com muitas encolhem até um mínimo e as trilhas rolam. NÃO mudam de tamanho ao arrastar.
	NEWZONE_MIN :: f32(28) // altura mínima da área de drop (quando as trilhas tomam o espaço)
	g_track_h = 72         // altura FIXA da trilha (não expande nem encolhe; quando não cabem, ROLA)
	nrows := g_nv + g_na
	content_h := f32(nrows) * (g_track_h + g_track_gap)                                     // altura total das trilhas
	lanes_top := r.y + toolbar_h + ruler_h
	region_bot := r.y + r.height - 10
	slack := max(0, (region_bot - lanes_top) - content_h - 2*NEWZONE_MIN - 2*g_track_gap)   // espaço vazio p/ dividir entre as 2 bandas
	newv_h := NEWZONE_MIN + slack*0.5
	newa_h := NEWZONE_MIN + slack*0.5
	newv_y := lanes_top
	g_newv_zone = rl.Rectangle{ r.x + LANE_X, newv_y, r.width - LANE_X, newv_h }            // banda de vídeo (topo)
	rows_top := newv_y + newv_h + g_track_gap                                               // topo da área rolável
	botband_y := region_bot - newa_h
	g_newa_zone = rl.Rectangle{ r.x + LANE_X, botband_y, r.width - LANE_X, newa_h }         // banda de áudio (base)
	rows_vh := max(f32(48), botband_y - g_track_gap - rows_top)                             // altura VISÍVEL das trilhas
	max_vscroll := max(0, content_h - rows_vh)

	// --- zoom (Ctrl+roda), scroll horizontal (Shift+roda) e VERTICAL (roda) ---
	over_tl := hovered(rl.Rectangle{ r.x + f32(LANE_X), r.y + toolbar_h, view_w, r.height - toolbar_h })
	if wheel := rl.GetMouseWheelMove(); wheel != 0 && over_tl {
		shift := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
		if rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL) {
			mx := rl.GetMousePosition().x
			t_cursor := tl_t(mx) // tempo sob o cursor (com o zoom atual)
			st.zoom = clamp(st.zoom * math.pow(1.2, wheel), ZOOM_MIN, ZOOM_MAX) // multiplicativo (casa com o slider log)
			tl_scroll = f32(LANE_X) + t_cursor * pps() - mx // mantém esse tempo sob o cursor
		} else if max_vscroll > 0 && !shift {
			tl_vscroll -= wheel * 40 // roda simples = rolar as trilhas (quando há trilhas fora da tela)
		} else {
			tl_scroll -= wheel * 60 // Shift+roda (ou sem overflow vertical) = rolar no tempo
		}
	}
	content_w := timeline_dur() * pps() + 40 // largura total + folga (já com o zoom novo)
	max_scroll := max(0, content_w - view_w)
	if st.playing { // segue o playhead pra ele não sair da tela
		phx := tl_x(st.playhead)
		if phx > r.x + r.width - 40 do tl_scroll += phx - (r.x + r.width - 40)
		else if phx < r.x + f32(LANE_X) + 40 do tl_scroll -= (r.x + f32(LANE_X) + 40) - phx
	}
	tl_scroll = clamp(tl_scroll, 0, max_scroll)
	tl_vscroll = clamp(tl_vscroll, 0, max_vscroll)
	// origem das trilhas p/ track_y/track_at_y já com o deslocamento vertical aplicado
	g_lanes_top = rows_top - tl_vscroll
	g_vlane = rl.Rectangle{ r.x + LANE_X, rows_top, r.width - LANE_X, rows_vh } // viewport (hit-test do drop)
	rows_clip := rl.Rectangle{ r.x + LANE_X, rows_top, view_w, rows_vh }        // recorte vertical das trilhas

	// retângulo de recorte: nada desenhado nas trilhas vaza sobre os cabeçalhos
	clip_rect := rl.Rectangle{ r.x + f32(LANE_X), r.y + toolbar_h, view_w, r.height - toolbar_h }

	// régua
	ruler := rl.Rectangle{ r.x + LANE_X, r.y + toolbar_h, r.width - LANE_X, ruler_h }
	rl.DrawRectangleRec(ruler, PANEL2)
	rl.BeginScissorMode(i32(clip_rect.x), i32(clip_rect.y), i32(clip_rect.width), i32(clip_rect.height))
	// passo adaptativo: escolhe um intervalo "redondo" (s) que garanta ~7px entre
	// marcas e ~55px entre rótulos. Sem isso, no zoom-out extremo a régua tentaria
	// desenhar milhares de marcas por segundo (1 por segundo do vídeo).
	nice := [?]int{ 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200 }
	tstep := nice[len(nice) - 1] // passo das marcas menores
	lstep := nice[len(nice) - 1] // passo dos rótulos
	for s in nice { if f32(s) * pps() >= 7  { tstep = s; break } }
	for s in nice { if f32(s) * pps() >= 55 { lstep = s; break } }
	if lstep < tstep do lstep = tstep
	sec := (max(0, int(tl_scroll / pps())) / tstep) * tstep // alinhado ao passo
	for {
		x := tl_x(f32(sec))
		if x > ruler.x + ruler.width do break
		if x >= ruler.x {
			rl.DrawLineEx({x, ruler.y + ruler.height - 8}, {x, ruler.y + ruler.height}, 1, MUTED)
			if sec % lstep == 0 {
				rl.DrawLineEx({x, ruler.y + 4}, {x, ruler.y + ruler.height}, 1, LINE)
				txt(timecode(f32(sec)), x + 3, ruler.y + 3, 11, MUTED)
			}
		}
		sec += tstep
	}
	rl.EndScissorMode()

	WAVE_H :: f32(22) // faixa da forma de onda no rodapé do bloco
	lane_h := g_track_h
	vlane := g_vlane // viewport de TODAS as trilhas (refs horizontais)
	// fundo + cabeçalho de cada trilha visível, RECORTADO ao viewport rolável (o scroll vertical
	// desliza as trilhas sob a faixa de efeitos/bandas sem vazar por cima delas)
	rl.BeginScissorMode(i32(r.x), i32(rows_top), i32(r.width), i32(rows_vh))
	for row in 0 ..< nrows {
		t := row < g_nv ? (g_nv - 1 - row) : (MAXV + (row - g_nv)) // linha -> índice de trilha
		ly := track_y(t)
		if ly + lane_h < rows_top || ly > rows_top + rows_vh do continue // fora da viewport: pula
		aud := is_audio_track(t)
		label := aud ? rl.TextFormat("A%d", i32(t - MAXV + 1)) : rl.TextFormat("V%d", i32(t + 1))
		draw_track_header({ r.x, ly, LANE_X, lane_h }, label, t)
		rl.DrawRectangleRec({ r.x + LANE_X, ly, r.width - LANE_X, lane_h }, aud ? rl.Color{ 28, 34, 32, 255 } : rl.Color{ 30, 33, 40, 255 })
		if track_locked[t] do rl.DrawRectangleRec({ r.x + LANE_X, ly, r.width - LANE_X, lane_h }, rl.Color{ 210, 160, 50, 20 }) // tint bloqueada
		if track_muted[t]  do rl.DrawRectangleRec({ r.x + LANE_X, ly, r.width - LANE_X, lane_h }, rl.Color{ 170, 60, 60, 24 })  // tint muda
		if track_hidden[t] do rl.DrawRectangleRec({ r.x + LANE_X, ly, r.width - LANE_X, lane_h }, rl.Color{ 80, 100, 130, 30 })  // tint oculta
	}
	rl.EndScissorMode()
	// bandas "criar trilha" PINADAS (topo=vídeo, base=áudio): escuras, com "+"; arraste mídia aqui OU clique no "+"
	draw_new_track_zone(g_newv_zone, false)
	draw_new_track_zone(g_newa_zone, true)
	// barra de rolagem VERTICAL (aparece só quando as trilhas não cabem)
	if max_vscroll > 0 {
		vsb_w: f32 = 8
		vsb_x := r.x + r.width - vsb_w - 3
		vtrack := rl.Rectangle{ vsb_x, rows_top, vsb_w, rows_vh }
		rl.DrawRectangleRounded(vtrack, 1, 4, rl.Color{20, 22, 27, 255})
		thumb_h := max(30, rows_vh * rows_vh / content_h)
		thumb := rl.Rectangle{ vsb_x, rows_top + (tl_vscroll / max_vscroll) * (rows_vh - thumb_h), vsb_w, thumb_h }
		if clicked(thumb) do tl_vbar_drag = true
		if rl.IsMouseButtonReleased(.LEFT) do tl_vbar_drag = false
		if tl_vbar_drag {
			my := rl.GetMousePosition().y
			rel := clamp((my - vtrack.y - thumb_h/2) / (rows_vh - thumb_h), 0, 1)
			tl_vscroll = rel * max_vscroll
		}
		rl.DrawRectangleRounded(thumb, 1, 4, (tl_vbar_drag || hovered(thumb)) ? ACCENT : rl.Color{70, 76, 88, 255})
	}
	if segs_ready() == 0 do txt_c("arraste um clipe do bin para cá", vlane.x + vlane.width/2, track_y(0) + lane_h/2 - 8, 13, MUTED)

	// segmentos de vídeo (e blocos de áudio) colocados na timeline
	vc := view_seg()
	consumed := ctx_open || ctx_ate // menu de contexto aberto/comendo o clique: timeline inerte
	// clique sobre uma barra de EFEITO tem prioridade sobre o clipe embaixo: marca consumed p/
	// o loop de segmentos ignorar; a seleção/arraste do efeito é tratada em draw_fx_on_tracks.
	if !consumed && st.drag == .None && modal == .None && rl.IsMouseButtonPressed(.LEFT) && fx_bar_at(rl.GetMousePosition()) >= 0 do consumed = true
	ew_cursor := false // mouse sobre uma borda de aparo -> cursor de redimensionar
	g_sel_fi = {-1, -1}; g_sel_fo = {-1, -1}; g_sel_volbar = {} // alças do selecionado (repovoadas abaixo)
	rl.BeginScissorMode(i32(rows_clip.x), i32(rows_clip.y), i32(rows_clip.width), i32(rows_clip.height))
	for i in 0 ..< nsegs {
		sg := &segs[i]
		if !seg_ready(i) do continue
		c := seg_src(i) // a mídia-fonte (textura, áudio, nome)
		x := tl_x(sg.start)
		w := sg.dur * pps()
		active := i == vc

		vr := rl.Rectangle{ x, track_y(sg.track) + 4, w, lane_h - 8 }
		alike := c.is_audio || sg.aonly // se comporta como áudio (mídia só-áudio OU áudio separado)
		rl.DrawRectangleRounded(vr, 0.06, 4, alike ? rl.Color{ 34, 52, 46, 255 } : (c.is_text ? rl.Color{ 58, 48, 78, 255 } : CLIP))
		// clipe só-áudio: a onda ocupa o bloco todo (sem filmstrip); vídeo: onda no rodapé
		wave_h := alike ? (vr.height - 15) : (c.has_audio ? WAVE_H : 0)
		// clipe de texto: mostra o conteúdo centralizado (sem miniaturas)
		if c.is_text && w > 30 {
			txt_c(elide(c.text, 12, w - 16), vr.x + vr.width/2, vr.y + vr.height/2 - 4, 12, rl.Color{ 214, 204, 236, 255 })
		}
		// tira de miniaturas (filmstrip) sob a barra do título, só o trecho visível
		if !c.is_text do ensure_thumbs(c)
		if w > 20 && !alike && !c.is_text {
			pth := prof_beg(.Tl_Thumb); defer prof_end(.Tl_Thumb, pth)
			sy := vr.y + 15
			sh := vr.height - 15 - wave_h
			if c.thumbs_ready && c.nthumbs > 0 {
				tw := (f32(THUMB_W) / f32(THUMB_H)) * sh // largura de cada miniatura (mantém 16:9)
				vis0 := max(vr.x, clip_rect.x)
				vis1 := min(vr.x + vr.width, clip_rect.x + clip_rect.width)
				s := max(0, int((vis0 - vr.x) / tw)) // 1ª miniatura visível (grade a partir de vr.x)
				for {
					sx := vr.x + f32(s) * tw
					if sx >= vis1 do break
					ct := (tl_t(sx + tw * 0.5) - sg.start) * seg_speed(i) + sg.in_off // tempo da fonte no meio do slot
					ti := clamp(int(ct / c.thumb_dt), 0, c.nthumbs - 1)
					dw := min(tw, (vr.x + vr.width) - sx) // recorta a última no fim do clipe
					if dw <= 0.5 do break
					rl.DrawTexturePro(c.thumbs[ti], {0, 0, THUMB_W, THUMB_H}, {sx, sy, dw, sh}, {0, 0}, 0, rl.WHITE)
					s += 1
				}
			} else if c.tex_ok && w > 84 { // ainda gerando: 1 miniatura de prévia
				rl.DrawTexturePro(c.tex, {0,0,f32(cdw(c)),f32(cdh(c))}, {vr.x + 4, sy + 4, 68, sh - 8}, {0,0}, 0, rl.WHITE)
			}
		}
		rl.DrawRectangleRounded({vr.x, vr.y, vr.width, 15}, 0.15, 4, CLIP_HDR) // barra do título por cima
		if w > 40 { // nome cortado (…) p/ CABER no clipe, sem vazar pro vizinho
			avail := w - 12 - (i == selected && w > 26 ? 18 : 0) // reserva p/ o botão x
			txt(elide(c.name, 11, avail), vr.x + 6, vr.y + 1, 11, rl.WHITE)
		}
		sel := i == selected
		mk := seg_marked[i] // parte de uma seleção múltipla
		if mk && !sel do rl.DrawRectangleRounded(vr, 0.06, 4, rl.Color{ 120, 170, 240, 40 }) // tom azul p/ marcado
		bcol := (sel || mk) ? rl.WHITE : (active ? ACCENT : ACCENT_D)
		rl.DrawRectangleRoundedLinesEx(vr, 0.06, 4, (sel || mk || active) ? 2 : 1, bcol)
		// alças de aparo nas bordas (só no segmento selecionado e largo o bastante)
		if sel && w > 24 {
			rl.DrawRectangleRec({vr.x + 1, vr.y + 3, 3, vr.height - 6}, ACCENT)
			rl.DrawRectangleRec({vr.x + vr.width - 4, vr.y + 3, 3, vr.height - 6}, ACCENT)
		}
		// detecta o mouse nas bordas p/ trocar o cursor (aparar) — só fora de arrasto
		if st.drag == .None && w > 16 && rl.CheckCollisionPointRec(rl.GetMousePosition(), vr) {
			mx := rl.GetMousePosition().x
			if mx - vr.x < 6 || (vr.x + vr.width) - mx < 6 do ew_cursor = true
		}
		// botãozinho de remover (x) no segmento selecionado
		if sel && w > 26 {
			xr := rl.Rectangle{ vr.x + vr.width - 18, vr.y + 2, 14, 14 }
			rl.DrawRectangleRounded(xr, 0.4, 4, hovered(xr) ? PLAYHEAD : rl.Color{60,64,74,220})
			rl.DrawLineEx({xr.x + 4, xr.y + 4}, {xr.x + 10, xr.y + 10}, 1.6, rl.WHITE)
			rl.DrawLineEx({xr.x + 10, xr.y + 4}, {xr.x + 4, xr.y + 10}, 1.6, rl.WHITE)
			if clicked(xr) { remove_seg(i, !alt_down()); consumed = true }
		}

		// forma de onda no RODAPÉ do mesmo bloco (estilo NLE), só se houver áudio
		if c.has_audio && w > 8 {
			pw := prof_beg(.Tl_Wave); defer prof_end(.Tl_Wave, pw)
			ar := rl.Rectangle{ vr.x, vr.y + vr.height - wave_h, vr.width, wave_h }
			rl.DrawRectangleRec(ar, rl.Color{ 24, 46, 40, 200 }) // faixa escura de fundo da onda
			// só o trecho visível: um clipe longo em zoom alto tem centenas de
			// milhares de px de largura, e o scissor corta o desenho na tela mas
			// não o custo das chamadas (eram ~72k DrawLineEx/frame p/ 1h no zoom 4)
			STEP :: f32(2)
			wx0 := ar.x + 3
			wx1 := min(ar.x + ar.width - 3, clip_rect.x + clip_rect.width)
			if wx0 < clip_rect.x do wx0 += math.ceil((clip_rect.x - wx0) / STEP) * STEP // preserva a fase da grade
			cy := ar.y + ar.height / 2
			amp := ar.height / 2 - 2
			wcol := sg.muted ? rl.Color{ 120, 126, 136, 170 } : rl.Color{ 95, 180, 150, 220 } // cinza se mudo
			for wx := wx0; wx < wx1; wx += STEP {
				tl := tl_t(wx)
				// tempo na FONTE nas duas bordas desta coluna (respeita o in_off do corte)
				ta := (tl             - sg.start) * seg_speed(i) + sg.in_off
				tb := (tl_t(wx + STEP) - sg.start) * seg_speed(i) + sg.in_off
				p := wave_peak(c, ta, tb)
				if p < 0 { // ainda calculando: barra fininha esmaecida
					rl.DrawRectangleRec({wx, cy - 2, STEP, 4}, rl.Color{70, 100, 92, 130})
				} else {
					// a altura reflete o GANHO (volume × fade × mudo): baixar o volume
					// encolhe a onda; a onda também afina ao longo das rampas de fade
					hh := max(f32(1), clamp(p * seg_gain(i, tl), 0, 1) * amp)
					rl.DrawRectangleRec({wx, cy - hh, STEP, hh * 2}, wcol)
				}
			}
			// ícone de mudo à esquerda da faixa
			if sg.muted && w > 30 {
				rl.DrawRectangleRec({ ar.x + 5, cy - 3, 4, 6 }, rl.Color{ 220, 90, 90, 255 })
				rl.DrawTriangle({ ar.x + 9, cy - 5 }, { ar.x + 9, cy + 5 }, { ar.x + 15, cy }, rl.Color{ 220, 90, 90, 255 })
				rl.DrawLineEx({ ar.x + 18, cy - 5 }, { ar.x + 24, cy + 5 }, 1.6, rl.Color{ 220, 90, 90, 255 })
				rl.DrawLineEx({ ar.x + 24, cy - 5 }, { ar.x + 18, cy + 5 }, 1.6, rl.Color{ 220, 90, 90, 255 })
			}
		}

		// --- fades nas quinas (sobre o filmstrip) + linha de volume, estilo NLE ---
		if c.has_audio && w > 8 {
			by0 := vr.y + 15                 // topo do filmstrip (sob o título)
			by1 := vr.y + vr.height - (alike ? 2 : wave_h) // base p/ fades/volume (áudio usa quase todo o bloco)
			fcol := rl.Color{ 250, 220, 120, 235 }
			// rampas de fade: diagonal da base (borda) até a alça no topo
			if sg.fade_in > 0.001  do rl.DrawLineEx({ vr.x, by1 },     { min(vr.x + sg.fade_in*pps(),  vr.x + w), by0 }, 1.6, fcol)
			if sg.fade_out > 0.001 do rl.DrawLineEx({ vr.x + w, by1 }, { max(vr.x + w - sg.fade_out*pps(), vr.x), by0 }, 1.6, fcol)
			if i == selected {
				// linha de volume (arraste vertical p/ ajustar; meio = 100%)
				vy := by1 - (clamp(sg.vol, 0, VOL_MAX) / VOL_MAX) * (by1 - by0)
				rl.DrawLineEx({ vr.x, vy }, { vr.x + w, vy }, 1.5, rl.Color{ 240, 240, 245, 230 })
				rl.DrawCircleV({ vr.x + w/2, vy }, 4, rl.WHITE)
				g_sel_volbar = { vr.x, vy - 5, w, 10 }; g_vby0 = by0; g_vby1 = by1
				if st.drag == .Vol do txt(rl.TextFormat("%d%%", i32(sg.vol*100 + 0.5)), vr.x + w/2 + 8, vy - 16, 12, rl.WHITE)
				// alças de fade arrastáveis (círculos no topo)
				fix := min(vr.x + sg.fade_in*pps(),  vr.x + w)
				fox := max(vr.x + w - sg.fade_out*pps(), vr.x)
				rl.DrawCircleV({ fix, by0 }, 5, fcol); rl.DrawCircleLinesV({ fix, by0 }, 5, rl.Color{ 40, 40, 40, 255 })
				rl.DrawCircleV({ fox, by0 }, 5, fcol); rl.DrawCircleLinesV({ fox, by0 }, 5, rl.Color{ 40, 40, 40, 255 })
				g_sel_fi = { fix, by0 }; g_sel_fo = { fox, by0 }
			}
		}

		// divisória no início do segmento (mostra o corte entre segmentos vizinhos, na trilha dele)
		if i > 0 do rl.DrawLineEx({x, track_y(sg.track)}, {x, track_y(sg.track) + lane_h}, 1, rl.Color{20,22,27,255})
	}

	// SEGUNDO PASSO: indicadores de transição/fade POR CIMA de todos os blocos (senão um
	// clipe vizinho desenhado depois cobriria o indicador do corte). Cada um tem X p/ REMOVER.
	for i in 0 ..< nsegs {
		if !seg_ready(i) do continue
		sg := &segs[i]
		x := tl_x(sg.start); w := sg.dur * pps()
		vr := rl.Rectangle{ x, track_y(sg.track) + 4, w, lane_h - 8 }
		xbtn :: proc(xr: rl.Rectangle) -> bool {
			rl.DrawRectangleRounded(xr, 0.4, 4, hovered(xr) ? PLAYHEAD : rl.Color{ 60, 64, 74, 235 })
			rl.DrawLineEx({xr.x+4,xr.y+4},{xr.x+10,xr.y+10},1.7,rl.WHITE)
			rl.DrawLineEx({xr.x+10,xr.y+4},{xr.x+4,xr.y+10},1.7,rl.WHITE)
			return clicked(xr)
		}
		// dissolver: PASTILHA compacta com ícone de crossfade centrada no corte (o bloco
		// âmbar largo antigo tapava os clipes). Hover/seleção mostram a EXTENSÃO real do
		// crossfade; clique na pastilha SELECIONA (Delete remove, alças ajustam a duração).
		if td := seg_trans(i); td > 0.01 {
			hw2 := clamp(td/2 * pps(), 8, 600)
			cut := vr.x // x do corte (início do clipe que entra)
			ext := rl.Rectangle{ cut - hw2, vr.y, hw2*2, vr.height }
			is_sel := sel_trans == i && sel_trans_kind == 0
			dragging := st.drag == .TransDur && drag_clip == i && sel_trans_kind == 0
			bw := f32(26); bh := min(vr.height - 8, 26)
			badge := rl.Rectangle{ cut - bw/2, vr.y + (vr.height - bh)/2, bw, bh }
			hb := hovered(badge) && st.drag == .None
			amber := rl.Color{ 248, 214, 122, 255 }
			// extensão real do crossfade: visível só no hover/seleção/arrasto (não polui)
			if hb || is_sel || dragging {
				on := is_sel || dragging
				rl.DrawRectangleRec(ext, rl.Color{ 240, 200, 90, on ? 55 : 32 })
				rl.DrawRectangleLinesEx(ext, on ? 1.6 : 1, rl.Color{ 248, 214, 122, on ? 235 : 140 })
			}
			// pastilha: fundo escuro arredondado + duas rampas cruzadas (símbolo de crossfade)
			rl.DrawRectangleRounded(badge, 0.35, 6, is_sel ? rl.Color{ 96, 78, 30, 250 } : rl.Color{ 33, 36, 43, 240 })
			rl.DrawRectangleRoundedLinesEx(badge, 0.35, 6, is_sel ? 1.8 : 1.2, rl.Color{ 248, 214, 122, (hb || is_sel) ? 255 : 185 })
			pd := f32(6)
			ix0 := badge.x + pd; ix1 := badge.x + bw - pd
			iy0 := badge.y + pd; iy1 := badge.y + bh - pd
			rc := rl.Color{ 252, 224, 138, 150 }
			rl.DrawTriangle({ ix0, iy0 }, { ix1, iy1 }, { ix0, iy1 }, rc) // rampa que desce (clipe que sai)
			rl.DrawTriangle({ ix1, iy0 }, { ix1, iy1 }, { ix0, iy1 }, rc) // rampa que sobe (clipe que entra)
			if is_sel || dragging {
				// alças nas bordas da extensão: arrastar ajusta a duração (simétrica no corte)
				eL := rl.Rectangle{ ext.x - 5, vr.y, 10, vr.height }
				eR := rl.Rectangle{ ext.x + ext.width - 5, vr.y, 10, vr.height }
				rl.DrawRectangleRounded({ ext.x - 2.5, vr.y + vr.height/2 - 9, 5, 18 }, 0.5, 4, amber)
				rl.DrawRectangleRounded({ ext.x + ext.width - 2.5, vr.y + vr.height/2 - 9, 5, 18 }, 0.5, 4, amber)
				if hovered(eL) || hovered(eR) || dragging do ew_cursor = true
				txt_c(rl.TextFormat("%.1fs", f64(td)), cut, badge.y + bh + 3, 11, amber)
				if xbtn({ cut - 7, vr.y + 2, 14, 14 }) { segs[i].trans = 0; sel_trans = -1; consumed = true; set_toast("Transição removida") }
				if !consumed && st.drag == .None && rl.IsMouseButtonPressed(.LEFT) && (hovered(eL) || hovered(eR)) {
					st.drag = .TransDur; drag_clip = i; consumed = true
				}
				// clique na região selecionada não vira arrasto/seleção de clipe
				if !consumed && st.drag == .None && clicked(ext) do consumed = true
			}
			// clique na pastilha = seleciona a transição (tira a seleção de clipe/bin)
			if !consumed && st.drag == .None && clicked(badge) {
				sel_trans = i; sel_trans_kind = 0; selected = -1; bin_sel = -1; consumed = true
			}
		}
		white := rl.Color{ 235, 238, 244, 235 }
		// fade preto de entrada (canto esquerdo): grip no fim da rampa seleciona/arrasta
		if sg.vfin > 0.01 {
			fw2 := clamp(sg.vfin * pps(), 10, 320)
			reg := rl.Rectangle{ vr.x, vr.y, fw2, vr.height }
			is_sel := sel_trans == i && sel_trans_kind == 1
			rl.DrawRectangleRec(reg, rl.Color{ 8, 8, 12, is_sel ? 165 : 120 })
			rl.DrawLineEx({ vr.x, vr.y + vr.height - 3 }, { vr.x + fw2, vr.y + 3 }, 1.8, white)
			grip := rl.Rectangle{ vr.x + fw2 - 3, vr.y + vr.height/2 - 9, 6, 18 }
			hg := hovered(grip) && st.drag == .None
			rl.DrawRectangleRounded(grip, 0.5, 4, (is_sel || hg) ? rl.WHITE : rl.Color{ 205, 210, 220, 205 })
			if is_sel {
				rl.DrawRectangleLinesEx(reg, 1.4, white)
				txt_c(rl.TextFormat("%.1fs", f64(sg.vfin)), vr.x + fw2/2, reg.y + reg.height + 2, 11, white)
				if xbtn({ vr.x + 3, vr.y + 3, 14, 14 }) { segs[i].vfin = 0; sel_trans = -1; consumed = true; set_toast("Fade de entrada removido") }
			}
			if hg || is_sel do ew_cursor = true
			if !consumed && st.drag == .None && rl.IsMouseButtonPressed(.LEFT) && hovered(grip) {
				sel_trans = i; sel_trans_kind = 1; selected = -1; bin_sel = -1
				st.drag = .TransDur; drag_clip = i; consumed = true
			}
		}
		// fade preto de saída (canto direito): grip no início da rampa seleciona/arrasta
		if sg.vfout > 0.01 {
			fw2 := clamp(sg.vfout * pps(), 10, 320)
			reg := rl.Rectangle{ vr.x + vr.width - fw2, vr.y, fw2, vr.height }
			is_sel := sel_trans == i && sel_trans_kind == 2
			rl.DrawRectangleRec(reg, rl.Color{ 8, 8, 12, is_sel ? 165 : 120 })
			rl.DrawLineEx({ reg.x, vr.y + 3 }, { reg.x + fw2, vr.y + vr.height - 3 }, 1.8, white)
			grip := rl.Rectangle{ reg.x - 3, vr.y + vr.height/2 - 9, 6, 18 }
			hg := hovered(grip) && st.drag == .None
			rl.DrawRectangleRounded(grip, 0.5, 4, (is_sel || hg) ? rl.WHITE : rl.Color{ 205, 210, 220, 205 })
			if is_sel {
				rl.DrawRectangleLinesEx(reg, 1.4, white)
				txt_c(rl.TextFormat("%.1fs", f64(sg.vfout)), reg.x + fw2/2, reg.y + reg.height + 2, 11, white)
				if xbtn({ reg.x + fw2 - 17, vr.y + 3, 14, 14 }) { segs[i].vfout = 0; sel_trans = -1; consumed = true; set_toast("Fade de saída removido") }
			}
			if hg || is_sel do ew_cursor = true
			if !consumed && st.drag == .None && rl.IsMouseButtonPressed(.LEFT) && hovered(grip) {
				sel_trans = i; sel_trans_kind = 2; selected = -1; bin_sel = -1
				st.drag = .TransDur; drag_clip = i; consumed = true
			}
		}
	}

	// TRILHA TRAVADA: hachura diagonal sobre os clipes (aparência de bloqueio, estilo NLE)
	for i in 0 ..< nsegs {
		if !seg_ready(i) || !track_locked[segs[i].track] do continue
		hvr := rl.Rectangle{ tl_x(segs[i].start), track_y(segs[i].track) + 4, segs[i].dur*pps(), lane_h - 8 }
		hx0 := max(hvr.x, clip_rect.x); hx1 := min(hvr.x + hvr.width, clip_rect.x + clip_rect.width)
		if hx1 <= hx0 do continue
		rl.BeginScissorMode(i32(hx0), i32(hvr.y), i32(hx1 - hx0), i32(hvr.height))
		for xx := hvr.x - hvr.height; xx < hvr.x + hvr.width; xx += 9 {
			rl.DrawLineEx({ xx, hvr.y + hvr.height }, { xx + hvr.height, hvr.y }, 3, rl.Color{ 12, 14, 18, 140 })
		}
	}
	// guias verticais (encaixe, playhead, lâmina) vão da RÉGUA à base: clipa ao clip_rect (topo =
	// ruler.y), NÃO ao viewport das trilhas (rows_clip). Sem isto, quando nenhuma trilha está
	// travada o scissor das trilhas continua ativo e corta o cursor antes dos números da régua.
	rl.BeginScissorMode(i32(clip_rect.x), i32(clip_rect.y), i32(clip_rect.width), i32(clip_rect.height))

	// cursor: lâmina = mira; sobre a linha de volume ou alças de fade = mãozinha;
	// borda de aparo = redimensionar; senão o padrão
	over_lanes := hovered(vlane) || hovered(ruler)
	mp2 := rl.GetMousePosition()
	on_handle :: proc(mp, pt: rl.Vector2) -> bool { return pt.x >= 0 && abs(mp.x-pt.x) < 8 && abs(mp.y-pt.y) < 8 }
	over_audio := (g_sel_volbar.width > 0 && hovered(g_sel_volbar)) || on_handle(mp2, g_sel_fi) || on_handle(mp2, g_sel_fo)
	dragging_audio := st.drag == .Vol || st.drag == .FadeIn || st.drag == .FadeOut
	if blade_mode && over_lanes do rl.SetMouseCursor(.CROSSHAIR)
	else if over_audio || dragging_audio do rl.SetMouseCursor(.POINTING_HAND)
	else do rl.SetMouseCursor(ew_cursor || drag_trim != 0 ? .RESIZE_EW : .DEFAULT)

	// guia de encaixe (durante o arrasto)
	if snap_line >= 0 {
		gx := tl_x(snap_line)
		if gx >= vlane.x && gx <= r.x + r.width {
			rl.DrawLineEx({gx, ruler.y}, {gx, r.y + r.height}, 1.5, ACCENT)
		}
	}

	// playhead
	px := tl_x(st.playhead)
	if px >= vlane.x && px <= r.x + r.width {
		rl.DrawTriangle({px - 6, ruler.y}, {px + 6, ruler.y}, {px, ruler.y + 10}, PLAYHEAD)
		rl.DrawLineEx({px, ruler.y}, {px, r.y + r.height}, 1.5, PLAYHEAD)
	}

	draw_fx_on_tracks(rows_clip) // barras de EFEITO por cima dos clipes, na trilha de cada um
	// guia da lâmina: linha âmbar + tesourinha no ponto onde o corte vai cair
	if blade_mode && over_lanes {
		bx := clamp(rl.GetMousePosition().x, vlane.x, r.x + r.width)
		blade_col := rl.Color{ 245, 200, 70, 235 }
		rl.DrawLineEx({bx, ruler.y}, {bx, r.y + r.height}, 1.5, blade_col)
		rl.DrawLineEx({bx - 4, ruler.y + 2}, {bx + 5, ruler.y + 11}, 1.6, blade_col)
		rl.DrawLineEx({bx + 4, ruler.y + 2}, {bx - 5, ruler.y + 11}, 1.6, blade_col)
		rl.DrawCircleLinesV({bx - 4, ruler.y + 12}, 2.5, blade_col)
		rl.DrawCircleLinesV({bx + 4, ruler.y + 12}, 2.5, blade_col)
	}
	rl.EndScissorMode()

	// barra de rolagem horizontal (aparece só quando há conteúdo além da tela)
	if max_scroll > 0 {
		sb_h: f32 = 8
		sb_y := r.y + r.height - sb_h - 3
		track := rl.Rectangle{ r.x + f32(LANE_X), sb_y, view_w, sb_h }
		rl.DrawRectangleRounded(track, 1, 4, rl.Color{20, 22, 27, 255})
		thumb_w := max(30, view_w * view_w / content_w)
		thumb := rl.Rectangle{ track.x + (tl_scroll / max_scroll) * (view_w - thumb_w), sb_y, thumb_w, sb_h }
		if clicked(thumb) do tl_hbar_drag = true
		if rl.IsMouseButtonReleased(.LEFT) do tl_hbar_drag = false
		if tl_hbar_drag {
			mx := rl.GetMousePosition().x
			rel := clamp((mx - track.x - thumb_w/2) / (view_w - thumb_w), 0, 1)
			tl_scroll = rel * max_scroll
		}
		rl.DrawRectangleRounded(thumb, 1, 4, (tl_hbar_drag || hovered(thumb)) ? ACCENT : rl.Color{70, 76, 88, 255})
	}

	// clicar na área das trilhas/régua sai da prévia de origem e volta ao modo timeline
	if src_preview >= 0 && rl.IsMouseButtonPressed(.LEFT) && (hovered(vlane) || hovered(ruler)) {
		exit_src_preview()
	}

	// clique com a lâmina ativa: corta o segmento sob o mouse exatamente no mouse
	if blade_mode && rl.IsMouseButtonPressed(.LEFT) && !consumed && hovered(vlane) && modal == .None {
		mp := rl.GetMousePosition()
		tr := track_at_y(mp.y) // corta só o segmento da trilha sob o cursor
		if track_locked[tr] { set_toast("Trilha bloqueada"); consumed = true }
		for i in 0 ..< nsegs {
			if track_locked[tr] do break
			if !seg_ready(i) || segs[i].track != tr do continue
			x := tl_x(segs[i].start); w := segs[i].dur * pps()
			if mp.x >= x && mp.x < x + w {
				if split_seg_at(i, tl_t(mp.x)) { selected = i; bin_sel = -1; set_toast("Clipe dividido") }
				break
			}
		}
		consumed = true // não deixa virar scrub/arrasto
	}

	// clique: pegar um segmento (mover/aparar) tem prioridade; senão, mover o playhead
	if !blade_mode && rl.IsMouseButtonPressed(.LEFT) && st.drag == .None && !consumed {
		mp := rl.GetMousePosition()
		// alças de áudio do segmento SELECIONADO têm prioridade sobre mover/aparar
		near :: proc(a, b: rl.Vector2) -> bool { return abs(a.x-b.x) < 8 && abs(a.y-b.y) < 8 }
		if selected >= 0 && seg_ready(selected) {
			if g_sel_fi.x >= 0 && near(mp, g_sel_fi) {
				st.drag = .FadeIn; drag_clip = selected; consumed = true
			} else if g_sel_fo.x >= 0 && near(mp, g_sel_fo) {
				st.drag = .FadeOut; drag_clip = selected; consumed = true
			} else if g_sel_volbar.width > 0 && hovered(g_sel_volbar) {
				st.drag = .Vol; drag_clip = selected; consumed = true
			}
		}
	}
	if !blade_mode && rl.IsMouseButtonPressed(.LEFT) && st.drag == .None && !consumed {
		mp := rl.GetMousePosition()
		hit := -1
		edge := 0
		for i in 0 ..< nsegs {
			if !seg_ready(i) do continue
			x := tl_x(segs[i].start)
			w := segs[i].dur * pps()
			cr := rl.Rectangle{ x, track_y(segs[i].track) + 4, w, lane_h - 8 }
			if rl.CheckCollisionPointRec(mp, cr) {
				hit = i
				// perto de uma borda (e o segmento largo o bastante) -> aparar
				if w > 16 {
					if mp.x - x < 6 do edge = -1
					else if (x + w) - mp.x < 6 do edge = 1
				}
				break
			}
		}
		if hit >= 0 && track_locked[segs[hit].track] {
			// TRILHA BLOQUEADA: clipe totalmente inerte — nem seleciona, marca ou arrasta
			set_toast("Trilha bloqueada")
		} else if hit >= 0 {
			ctrl := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
			shift := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
			bin_sel = -1; bin_clear_marks(); sel_trans = -1; fx_sel = -1 // selecionar seg volta a biblioteca de efeitos
			if (ctrl || shift) && edge == 0 {
				// Ctrl/Shift+clique: ALTERNA a marcação (seleção múltipla), sem iniciar arrasto
				seg_marked[hit] = !seg_marked[hit]
				if seg_marked[hit] do selected = hit
				else if selected == hit do selected = -1
			} else {
				// clicar num seg NÃO marcado (ou aparar borda) redefine a seleção só p/ ele;
				// clicar num JÁ marcado mantém o grupo e move todos juntos
				if edge != 0 || !seg_marked[hit] { seg_clear_marks(); seg_marked[hit] = true }
				st.drag = .Clip
				drag_clip = hit
				drag_trim = edge
				selected = hit // foco (para inspector/remover/dividir)
				grab_dt = tl_t(mp.x) - segs[hit].start
			}
		} else if hovered(ruler) {
			st.drag = .Playhead // arrastar na RÉGUA move o playhead (scrub)
			selected = -1; seg_clear_marks(); bin_sel = -1; bin_clear_marks(); sel_trans = -1
		} else if hovered(vlane) {
			// área VAZIA das trilhas: inicia MARQUEE de seleção (arrastar seleciona vários).
			// Clique seco (sem arrastar) = move o playhead e desseleciona (tratado no release).
			mctrl := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
			mshift := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
			tl_marquee = true; tl_marquee_start = mp; tl_marquee_moved = false
			tl_marquee_add = mctrl || mshift
			if !tl_marquee_add { selected = -1; seg_clear_marks() }
			bin_sel = -1; bin_clear_marks(); sel_trans = -1
		}
		// só silencia se um arrasto REALMENTE começou (st.drag deixou de ser None
		// acima). Antes isto rodava em qualquer clique da janela — zoom, aba,
		// maximizar — pausando o áudio; o update via o stream parado, achava que
		// o clipe tinha acabado e cravava o playhead no fim.
		if st.drag != .None && st.playing && play_clip >= 0 && seg_src(play_clip).has_audio {
			rl.PauseMusicStream(seg_src(play_clip).music) // silencia enquanto arrasta
		}
	}

	// --- MARQUEE de seleção da timeline: arrastar em área vazia marca os segmentos tocados ---
	if tl_marquee {
		mm := rl.GetMousePosition()
		if abs(mm.x - tl_marquee_start.x) > 4 || abs(mm.y - tl_marquee_start.y) > 4 do tl_marquee_moved = true
		if tl_marquee_moved {
			mq := rl.Rectangle{ min(tl_marquee_start.x, mm.x), min(tl_marquee_start.y, mm.y),
			                    abs(mm.x - tl_marquee_start.x), abs(mm.y - tl_marquee_start.y) }
			if !tl_marquee_add do seg_clear_marks()
			for i in 0 ..< nsegs {
				if !seg_ready(i) || track_locked[segs[i].track] do continue // trilha travada não entra na seleção
				sr := rl.Rectangle{ tl_x(segs[i].start), track_y(segs[i].track) + 4, segs[i].dur*pps(), lane_h - 8 }
				if rl.CheckCollisionRecs(sr, mq) do seg_marked[i] = true
			}
			if selected < 0 || !seg_marked[selected] { // mantém um foco válido p/ o inspector
				selected = -1
				for i in 0 ..< nsegs do if seg_marked[i] { selected = i; break }
			}
			rl.DrawRectangleRec(mq, rl.Color{ 120, 170, 240, 45 })
			rl.DrawRectangleLinesEx(mq, 1, rl.Color{ 150, 190, 245, 220 })
		}
		if rl.IsMouseButtonReleased(.LEFT) {
			if !tl_marquee_moved { // clique seco em área vazia: move o playhead + desseleciona
				st.playhead = clamp(tl_t(rl.GetMousePosition().x), 0, timeline_dur())
				seek_global(st.playhead)
			}
			tl_marquee = false; tl_marquee_moved = false
		}
	}
}

// área de drop "criar trilha" (estilo NLE). aud=false -> vídeo (topo); aud=true -> áudio (base).
// É um ESPAÇO ESCURO VAZIO, permanente (sempre visível, sem rótulo): soltar mídia compatível
// aqui cria a trilha (tratado no update). Um "+" discreto aparece só ao passar o mouse (fora de
// arraste) p/ criar uma trilha vazia por clique. Realça em verde quando um arraste compatível passa.
draw_new_track_zone :: proc(z: rl.Rectangle, aud: bool) {
	if aud ? g_na >= MAXA : g_nv >= MAXV do return // capacidade cheia: some com a banda
	m := rl.GetMousePosition()
	dragging := st.drag == .Bin || st.drag == .FxLib || (st.drag == .Clip && drag_clip >= 0 && drag_clip < nsegs && drag_trim == 0)
	type_ok := true
	if st.drag == .Bin  && bin_drag  >= 0 && bin_drag  < nclips do type_ok = clips[bin_drag].is_audio == aud
	if st.drag == .Clip && drag_clip >= 0 && drag_clip < nsegs  do type_ok = seg_audio_like(drag_clip) == aud
	if st.drag == .FxLib do type_ok = !aud // efeito só cria trilha de VÍDEO
	over := rl.CheckCollisionPointRec(m, z)
	hot := dragging && type_ok && over
	// fundo escuro vazio; leve tom verde + moldura quando um arraste compatível está por cima
	rl.DrawRectangleRec(z, hot ? rl.Color{ 34, 48, 42, 170 } : rl.Color{ 20, 22, 27, 150 })
	if hot do rl.DrawRectangleLinesEx(z, 1.4, rl.Color{ 90, 200, 120, 200 })
	// "+" discreto p/ criar trilha vazia — só ao passar o mouse e FORA de arraste
	if !dragging && over {
		pb := rl.Rectangle{ z.x + 8, z.y + z.height/2 - 9, 18, 18 }
		rl.DrawRectangleRounded(pb, 0.3, 4, hovered(pb) ? HOVER : rl.Color{ 40, 44, 52, 220 })
		pcx := pb.x + pb.width/2; pcy := pb.y + pb.height/2
		rl.DrawLineEx({pcx - 4, pcy}, {pcx + 4, pcy}, 2, TEXT)
		rl.DrawLineEx({pcx, pcy - 4}, {pcx, pcy + 4}, 2, TEXT)
		if clicked(pb) { if aud do add_audio_track(); else do add_video_track() }
	}
}

draw_track_header :: proc(r: rl.Rectangle, name: cstring, t: int) {
	rl.DrawRectangleRec(r, PANEL)
	rl.DrawRectangle(i32(r.x + r.width) - 1, i32(r.y), 1, i32(r.height), LINE)
	muted := track_muted[t]; locked := track_locked[t]; hidden := track_hidden[t]
	rl.DrawRectangleRec({r.x, r.y, 3, r.height}, locked ? rl.Color{ 210, 160, 50, 255 } : PLAYHEAD)
	txt(name, r.x + 12, r.y + 8, 13, TEXT)
	// "×" p/ remover a trilha — só na PONTA de cada tipo (topo do vídeo / base do áudio) e se
	// estiver VAZIA (sem segmentos). Só as pontas removem sem precisar re-indexar as outras.
	removable := is_audio_track(t) ? (t == MAXV + g_na - 1 && g_na > 1) : (t == g_nv - 1 && g_nv > 1)
	if removable {
		empty := true
		for i in 0 ..< nsegs do if segs[i].track == t { empty = false; break }
		if empty do for i in 0 ..< nfx do if fxsegs[i].track == t { empty = false; break } // efeito na trilha também conta
		if empty {
			xb := rl.Rectangle{ r.x + r.width - 22, r.y + 6, 15, 15 }
			if clicked(xb) {
				track_muted[t] = false; track_locked[t] = false; track_hidden[t] = false // devolve o slot limpo
				if is_audio_track(t) do g_na -= 1; else do g_nv -= 1
			} else {
				xcol := hovered(xb) ? rl.Color{ 220, 90, 90, 255 } : MUTED
				rl.DrawLineEx({xb.x + 3, xb.y + 3}, {xb.x + 12, xb.y + 12}, 1.6, xcol)
				rl.DrawLineEx({xb.x + 12, xb.y + 3}, {xb.x + 3, xb.y + 12}, 1.6, xcol)
			}
		}
	}
	iy := r.y + r.height - 22
	// botão MUTE (silencia todo o áudio da trilha)
	mb := rl.Rectangle{ r.x + 12, iy, 20, 16 }
	if clicked(mb) do track_muted[t] = !track_muted[t]
	rl.DrawRectangleRounded(mb, 0.25, 4, muted ? rl.Color{ 170, 60, 60, 255 } : (hovered(mb) ? HOVER : PANEL2))
	txt_c("M", mb.x + mb.width/2, mb.y + 1, 12, muted ? rl.WHITE : MUTED)
	// botão LOCK (bloqueia mover/aparar/cortar) — ícone de cadeado
	lb := rl.Rectangle{ r.x + 38, iy, 20, 16 }
	if clicked(lb) {
		track_locked[t] = !track_locked[t]
		if track_locked[t] do for i in 0 ..< nsegs do if segs[i].track == t { // solta seleção/marcação
			seg_marked[i] = false
			if selected == i do selected = -1
		}
	}
	rl.DrawRectangleRounded(lb, 0.25, 4, locked ? rl.Color{ 210, 160, 50, 255 } : (hovered(lb) ? HOVER : PANEL2))
	{
		lcol := locked ? rl.Color{ 20, 20, 24, 255 } : MUTED
		lcx := lb.x + lb.width/2; lcy := lb.y + lb.height/2
		rl.DrawRectangleRec({ lcx - 4, lcy - 1, 8, 6 }, lcol)                     // corpo do cadeado
		rl.DrawLineEx({ lcx - 2.5, lcy - 1 }, { lcx - 2.5, lcy - 4 }, 1.4, lcol) // arco (U invertido)
		rl.DrawLineEx({ lcx + 2.5, lcy - 1 }, { lcx + 2.5, lcy - 4 }, 1.4, lcol)
		rl.DrawLineEx({ lcx - 2.5, lcy - 4 }, { lcx + 2.5, lcy - 4 }, 1.4, lcol)
	}
	// botão OLHO (esconde o vídeo da trilha no preview/export) — só em trilha de vídeo
	if !is_audio_track(t) {
		eb := rl.Rectangle{ r.x + 64, iy, 20, 16 }
		if clicked(eb) do track_hidden[t] = !track_hidden[t]
		rl.DrawRectangleRounded(eb, 0.25, 4, hidden ? rl.Color{ 80, 100, 130, 255 } : (hovered(eb) ? HOVER : PANEL2))
		ecx := eb.x + eb.width/2; ecy := eb.y + eb.height/2
		ecol := hidden ? rl.Color{ 20, 20, 24, 255 } : MUTED
		rl.DrawEllipseLines(i32(ecx), i32(ecy), 6, 3.5, ecol) // contorno do olho
		rl.DrawCircleV({ ecx, ecy }, 1.8, ecol)               // pupila
		if hidden do rl.DrawLineEx({ ecx - 7, ecy + 4 }, { ecx + 7, ecy - 4 }, 1.6, ecol) // risco = oculto
	}
}

// HH:MM:SS:FF (30 fps)
timecode :: proc(total: f32) -> cstring {
	s := int(total)
	f := int((total - f32(s)) * 30)
	return fmt.ctprintf("%02d:%02d:%02d:%02d", s/3600, (s%3600)/60, s%60, f)
}
