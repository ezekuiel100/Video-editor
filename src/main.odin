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
PV_BACK  :: rl.Color{ 40, 43, 52, 255 } // fundo do painel de preview FORA do quadro de saída (não é preto:
                                        // separa à vista o que é vídeo do que é só sobra do painel)
PV_EDGE  :: rl.Color{ 96, 104, 120, 230 } // moldura do quadro de saída

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
tl_click_t:  f64 = -1 // tempo do último clique num clipe da timeline (duplo-clique = seek)
tl_click_i:  int = -1 // segmento do último clique na timeline
player_vol:  f32 = 1  // volume do PLAYER (monitor): escala o que se OUVE, NÃO altera o áudio dos segmentos
vol_popup:   bool     // popup do slider VERTICAL de volume (abre ao clicar no alto-falante)
shot_n:      int      // contador de screenshots (nome do arquivo)
fullscreen_preview: bool // preview de vídeo ocupando a janela toda
fs_ctl_alpha: f32        // opacidade atual dos controles em tela cheia (0..1, animada)
fs_ctl_hold:  f32        // segundos que os controles ainda ficam visíveis (auto-hide estilo NLE)
fs_vol_drag:  bool       // arrastando o slider de volume da barra em tela cheia
player_seek_drag: bool   // arrastando a barra de progresso do player
// tocava quando o usuário PEGOU a barra? O scrub pausa (senão brigaria com o relógio de
// áudio), mas soltar tem de VOLTAR a tocar — antes parava e exigia apertar play de novo.
// Escrito a cada clique na barra, então um arrasto cancelado (modal, sair da tela cheia)
// não deixa valor velho para o próximo.
seek_was_playing: bool
dbg_seek_n: int // frames de log restantes após um seek (DBG_SEEK)
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
g_file_menu_draw: bool     // true enquanto draw_file_menu roda (cliques no menu não são bloqueados)

// --- menu de CONTEXTO da timeline (botão direito): copiar/colar/duplicar/etc.
// Aberto no update (botão direito sobre g_vlane); cliques tratados no UPDATE
// (antes da timeline reagir) e desenhado por último no draw (por cima de tudo).
ctx_open: bool
ctx_pos:  rl.Vector2 // canto do menu (posição do clique)
ctx_seg:   int = -1  // segmento alvo (-1 = área vazia: colar / fechar vão)
ctx_fx:    int = -1  // clipe de efeito alvo (-1 = nenhum; exclusivo com ctx_seg)
ctx_track: int = -1  // trilha do clique (vão / "fechar todos" quando ctx_seg < 0)
ctx_time:  f32       // tempo da timeline no clique (colar/dividir/vão usam)
ctx_ate:  bool       // este frame: o press fechou/executou o menu — não vaza p/ a UI de trás
CTX_W  :: f32(248)
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

// dimensões NATIVAS do vídeo de referência, p/ o botão "Do vídeo" de Config. do Projeto:
// o que está sob o playhead (é o que o usuário está vendo); senão o 1º da timeline — o
// mesmo critério do maybe_adopt_aspect. 0,0 = nenhum (só áudio/texto, ou probe sem dims).
proj_src_dims :: proc() -> (int, int) {
	if v := view_seg(); v >= 0 {
		c := seg_src(v)
		if c.vw > 0 && c.vh > 0 do return int(c.vw), int(c.vh)
	}
	for i in 0 ..< nsegs {
		if !seg_ready(i) do continue
		c := seg_src(i)
		if c.vw > 0 && c.vh > 0 do return int(c.vw), int(c.vh)
	}
	return 0, 0
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



// --- modais (exportar / screenshot / conclusão) ---
Modal :: enum { None, Export, Shot, Done, Confirm, Crop, ProjSettings, Silence, STT, Caps }
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
g_track_h:   f32 = 84   // altura PADRÃO de trilha (px); por trilha vem de track_h/th()
g_track_gap: f32 = 3    // espaço vertical entre trilhas
// altura POR TRILHA (arrastar a borda de baixo do cabeçalho). 0 = usar o padrão g_track_h, então
// projeto novo/trilha nova já nasce certo sem inicializar nada. Trilha mais alta = miniaturas
// maiores E forma de onda proporcionalmente maior (facilita achar o ponto do corte no áudio).
track_h: [MAXTRACKS]f32
TRACK_H_MIN :: f32(44)   // ainda mostra a barra de título + um fio de conteúdo
TRACK_H_MAX :: f32(320)
track_resize: int = -1   // trilha sendo redimensionada (-1 = nenhuma)
// altura efetiva da trilha t
th :: proc(t: int) -> f32 { return track_h[t] > 0 ? track_h[t] : g_track_h }
// índice da trilha na linha `row` (inverso de track_row): vídeo em cima invertido, áudio embaixo
track_of_row :: proc(row: int) -> int { return row < g_nv ? (g_nv - 1 - row) : (MAXV + (row - g_nv)) }
// soma das alturas (+gaps) de todas as linhas visíveis
tracks_content_h :: proc() -> f32 {
	s: f32 = 0
	for r in 0 ..< g_nv + g_na do s += th(track_of_row(r)) + g_track_gap
	return s
}
g_view_w:  f32          // largura visível da timeline (px), guardada no draw p/ o atalho de ajuste
snap_line: f32 = -1 // tempo (s) da guia de encaixe ativa (-1 = nenhuma)
SNAP_PX :: 10.0     // distância (px) para o encaixe magnético
DROP_LEAD :: f32(64) // ao soltar do bin, a borda esq. do clipe fica ~64px ADIANTADA do mouse
                     // (mais fácil encaixar no início da timeline sem cravar o cursor no canto)
selected: int = -1  // SEGMENTO com FOCO na timeline (-1 = nenhum) — usado pelo inspector
// vão (espaço vazio) selecionado na timeline: clicar entre clipes destaca o buraco;
// Delete / X / menu "Fechar vão" desliza o que está à direita e cola os clipes.
sel_gap_track: int = -1
sel_gap_t0:    f32
sel_gap_t1:    f32
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
bin_empty_click_p: rl.Vector2 // posição desse clique — o 2º precisa cair no MESMO lugar (±8px)
// --- divisória entre o conteúdo (bin/preview) e a timeline: arrastável na vertical ---
TL_FRAC_DEF :: f32(0.34)      // fração padrão da altura da janela ocupada pela timeline
tl_frac: f32 = TL_FRAC_DEF    // fração ATUAL (persistida na sessão; arrastar a divisória muda)
tl_split_drag: bool           // arrastando a divisória
// --- divisória VERTICAL entre o bin e o player: arrastável na horizontal (alarga o player) ---
MD_FRAC_DEF :: f32(0.47)      // fração padrão da largura da janela ocupada pelo bin
md_frac: f32 = MD_FRAC_DEF
md_split_drag: bool
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


toast_msg:   cstring
toast_t:     f32
want_import: bool // pedido de abrir o diálogo de importar (tratado no update)

// relógio de áudio MONOTÔNICO: GetMusicTimePlayed oscila p/ trás em até ~1
// sub-buffer; o playback nunca deixa `local` recuar abaixo de aud_prev (o recuo
// espúrio disparava respawn de vídeo à toa). Zerado (=-1) a cada seek/aquisição.
aud_prev: f32 = -1


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
smooth_bad: int // frames consecutivos com drift fora do range (ver smooth_clock)
g_frame_no: i64 = 1 // nº do frame de render (update incrementa; 0 = "nunca" p/ os pframe_tick)
smooth_clock :: proc(raw, dt: f32) -> f32 {
	if aud_prev < 0 do return raw                  // sem âncora (segurança; a prévia sempre ancora)
	sm := aud_prev + dt                            // avança liso pelo tempo de render (vsync)
	drift := raw - sm
	// |drift| grande = relógio INVÁLIDO — jamais snap, avança pelo dt e re-sincroniza quando
	// o raw assentar. Casos reais medidos: (a) após Stop→Seek→Play com pré-encher, o
	// GetMusicTimePlayed "wrapa" p/ ~fim-do-arquivo−buffer (~19.6s num clipe de 20s!) até o
	// 1º sub-buffer tocar (~0.3s) — snap p/ FRENTE fazia o replay começar no fim ("play de
	// novo não volta pro início"); (b) fim de stream/troca de janela zera o relógio — snap p/
	// TRÁS rebobinava a prévia no fim. Seeks reais ancoram aud_prev na posição PEDIDA
	// (src_acquire), então o PLL captura assim que o raw fica são.
	if abs(drift) <= SMOOTH_HARD {
		smooth_bad = 0
		sm += drift * SMOOTH_GAIN
	} else {
		// glitch transitório some sozinho em <0.35s. Se persistir ~0.75s é deslocamento REAL
		// — ex.: travada longa (modal/chunk) em que o dt é capado a 0.1s mas o áudio correu
		// de verdade: sem isto o drift ficava > SMOOTH_HARD PRA SEMPRE (PLL desligado) e o
		// vídeo tocava permanentemente atrasado do áudio. Reata só P/ FRENTE.
		// TENTEI reatar p/ trás também (o áudio ficava 1s atrás ao adiantar na prévia) e MEDI
		// que é errado: logo após Stop→Seek→Play o GetMusicTimePlayed fica com um VIÉS estável
		// p/ menos (~0.69s medidos, o pré-enchimento de buffers) — o som está no lugar certo e
		// só o relógio mente. Reatar ali PUXAVA o src_t 0.69s p/ trás, criando o erro que não
		// existia. O atraso de verdade daquele bug tinha outra causa (janela de áudio adotada
		// sem seek) e foi corrigido na raiz, no update_src_preview.
		smooth_bad += 1
		if smooth_bad > 45 {
			smooth_bad = 0
			if raw > sm do return raw
		}
	}
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




main :: proc() {
	hide_child_consoles() // esconde as janelas de console dos ffmpeg — ANTES de qualquer spawn
	init_paths() // resolve %TEMP% e acha o ffmpeg empacotado — ANTES de qualquer spawn/temp
	if dump_export_cli() do return
	sweep_orphan_temps() // varre o %TEMP%: apaga temporários de PIDs mortos (lixo de crashes antigos)
	job_init() // antes de qualquer spawn de ffmpeg
	export_nvenc_ok = probe_nvenc() // 1 frame: decide se o checkbox de GPU pode ligar
	export_gpu = export_nvenc_ok    // default = GPU só quando ela de fato funciona
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
		fx_loc_wipe_edge   = rl.GetShaderLocation(bulge_shader, "wipeEdge")
		fx_loc_wipe_feather= rl.GetShaderLocation(bulge_shader, "wipeFeather")
		fx_loc_wipe_inv    = rl.GetShaderLocation(bulge_shader, "wipeInv")
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
			// ÁUDIO do master: por que sai (ou não sai) som. "fica mudo" é um ESTADO
			// contínuo, não um evento — e o bloco do master só roda DENTRO de
			// `has_audio && audio_clock_ok`, então JUSTAMENTE quando falha nada era
			// registrado. Este fica fora de qualquer guarda: mudo por falta de master
			// e mudo por janela de áudio errada são causas diferentes, e o log tem de
			// saber distinguir uma da outra sem precisar de outra reprodução.
			if play_clip >= 0 && play_clip < nsegs {
				ac := seg_src(play_clip); al := seg_local(play_clip, st.playhead)
				dbg("AUDIO", "seg=%d loc=%.1f has=%v clock=%v tocando=%v mbase=%.1f parts=%d head=%.0f mudo=%v | CK busy=%v done=%v ok=%v base=%.1f",
					play_clip, al, ac.has_audio,
					ac.has_audio ? audio_clock_ok(ac, al) : false,
					ac.has_audio ? rl.IsMusicStreamPlaying(ac.music) : false,
					ac.music_base, intrinsics.atomic_load(&ac.parts_done), ac.head_dur,
					segs[play_clip].muted || track_muted[segs[play_clip].track],
					ac.chunk_busy, intrinsics.atomic_load(&ac.chunk_done),
					intrinsics.atomic_load(&ac.chunk_ok), ac.chunk_base)
			} else {
				aa := audio_seg_at(st.playhead)
				why: cstring = aa < 0 ? "sem-seg-audio" : (seg_speed(aa) != 1 ? "speed!=1" : "janela-audio")
				dbg("AUDIO", "SEM MASTER (play_clip=%d) ph=%.1fs a=%d why=%s — relógio de parede",
					play_clip, st.playhead, aa, why)
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

