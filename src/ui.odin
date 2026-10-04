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
import "core:unicode/utf8"
import win "core:sys/windows"

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
	// menu Arquivo cobre as abas (Mídia/Transições/Efeitos): o draw dele é por último,
	// mas o clique em "Abrir" passava ANTES na aba de baixo e deixava o projeto em Efeitos
	if ctx_open || ctx_ate do return false
	// menu Arquivo cobre as abas (y>=34). A barra de título (Arquivo/Editar/…) continua clicável.
	if file_menu_open && !g_file_menu_draw && rl.GetMousePosition().y >= 34 do return false
	// modal aberto: a UI de trás não recebe hover/clique (senão o silêncio fechava
	// porque o clique caía na timeline e desmarcava o clipe)
	if modal != .None && !g_modal_draw do return false
	if sil_eat || stt_eat do return false // 1º frame depois de abrir: o clique que abriu ainda está down
	// O painel flutuante bloqueia a prévia; controles rolados não recebem cliques fora da janela.
	if !g_modal_draw && !g_file_menu_draw {
		if insp_content && !rl.CheckCollisionPointRec(rl.GetMousePosition(), insp_view) do return false
		if !insp_drawing && rl.CheckCollisionPointRec(rl.GetMousePosition(), g_insp_card) do return false
	}
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

// trunca `s` com "…" para caber em `max_w` pixels. Recua por RUNA, não por byte: cortar
// no meio de um caractere multibyte ("ã", "ç") desenhava glifo-lixo antes das reticências.
elide :: proc(s: string, size, max_w: f32) -> cstring {
	if txt_w(cs(s), size) <= max_w do return cs(s)
	n := len(s)
	for n > 0 {
		_, w := utf8.decode_last_rune_in_string(s[:n])
		n -= w
		cand := fmt.ctprintf("%s…", strings.trim_right_space(s[:n]))
		if txt_w(cand, size) <= max_w do return cand
	}
	return "…"
}

// como elide, mas corta o INÍCIO — p/ caminhos, onde o que identifica é o fim (pasta/arquivo).
elide_left :: proc(s: string, size, max_w: f32) -> cstring {
	if txt_w(cs(s), size) <= max_w do return cs(s)
	i := 0
	for i < len(s) {
		_, w := utf8.decode_rune_in_string(s[i:])
		i += w
		cand := fmt.ctprintf("…%s", s[i:])
		if txt_w(cand, size) <= max_w do return cand
	}
	return "…"
}

base_name :: proc(path: string) -> string {
	start := 0
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '/' || path[i] == '\\' { start = i + 1; break }
	}
	return strings.clone(path[start:])
}


LANE_X :: 128 // cabeçalho compacto das trilhas


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
	cp := font_codepoints()
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

// abre a pasta no Explorer com o ARQUIVO já selecionado. Três pegadinhas do /select:
//  1. só aceita barra INVERTIDA — e o caminho da exportação vem misturado
//     (save_dir + "/" + nome), então tem de ser normalizado;
//  2. as aspas vão em volta do CAMINHO, não do argumento inteiro. Por isso NÃO dá p/
//     usar os.process_start: ele cita o argumento todo quando há espaço (medido:
//     `explorer "/select,C:\...\video editor\x.mp4"`) e o Explorer, sem entender,
//     abre uma pasta padrão. O ShellExecuteW passa lpParameters CRU — a citação fica
//     sob nosso controle;
//  3. arquivo movido/apagado depois do export: /select cairia na pasta padrão, então
//     abre só o diretório.
reveal_in_explorer :: proc(path: string) {
	if path == "" do return
	p, _ := strings.replace_all(path, "/", "\\", context.temp_allocator)
	exists := false
	if fh, oe := os.open(p); oe == nil { os.close(fh); exists = true }
	params: string
	if exists do params = fmt.tprintf("/select,\"%s\"", p)
	else {
		d := dir_of(p)
		if d == "" do return
		params = fmt.tprintf("\"%s\"", d)
	}
	win.ShellExecuteW(nil, win.utf8_to_wstring("open"), win.utf8_to_wstring("explorer.exe"),
		win.utf8_to_wstring(params), nil, win.SW_SHOWNORMAL)
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
	rl.DrawRectangleRec({0,0,sw,sh}, SCRIM) // backdrop
	cw: f32 = 560; ch: f32 = 316
	cx := sw/2 - cw/2; cy := sh/2 - ch/2
	card := rl.Rectangle{ cx, cy, cw, ch }
	rl.DrawRectangleRounded(card, 0.04, 8, SURFACE)
	rl.DrawRectangleRoundedLinesEx(card, 0.04, 8, 1, LINE)
	txt("Configurações do Projeto", cx + 24, cy + 18, FS_XL, TEXT)
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
	txt("Proporção da Tela:", lx, cy + 66, FS_MD, TEXT)
	chx := lx + 158; chy := cy + 62
	for p, i in AR_PRESETS {
		bw := f32(54)
		br := rl.Rectangle{ chx + f32(i%5)*(bw+6), chy + f32(i/5)*30, bw, 24 }
		if ui_btn(br, p.label, abs(cur_ar - p.ar) < 0.005) {
			if p.ar >= 1 { tf_set(&tf_pw, fmt.tprintf("%d", int(f32(1080)*p.ar+0.5))); tf_set(&tf_ph, "1080") }
			else         { tf_set(&tf_pw, "1080"); tf_set(&tf_ph, fmt.tprintf("%d", int(f32(1080)/p.ar+0.5))) }
		}
	}
	// "Do vídeo": tamanho EXATO da fonte — canvas casa com o vídeo, sem tarja nos cantos.
	// É o mesmo que a autodetecção faz ao soltar o 1º vídeo; aqui dá p/ voltar a ele depois
	// de experimentar um preset (antes não havia caminho de volta).
	svw, svh := proj_src_dims()
	nb := rl.Rectangle{ chx + 2*(54+6), chy + 30, 84, 24 }
	if ui_btn(nb, "Do vídeo", svw > 0 && cwv == svw && chv == svh) {
		if svw > 0 {
			tf_set(&tf_pw, fmt.tprintf("%d", svw)); tf_set(&tf_ph, fmt.tprintf("%d", svh))
		} else do set_toast("Nenhum vídeo na timeline para copiar o formato")
	}

	// --- Resolução: L × A + razão irredutível ---
	ry := cy + 156
	txt("Resolução:", lx, ry + 5, FS_MD, TEXT)
	wr := rl.Rectangle{ lx + 158, ry, 84, 28 }
	hr := rl.Rectangle{ wr.x + wr.width + 24, ry, 84, 28 }
	rl.DrawRectangleRounded(wr, 0.2, 4, PANEL2); rl.DrawRectangleRoundedLinesEx(wr, 0.2, 4, 1, ps_wf ? ACCENT : LINE)
	rl.DrawRectangleRounded(hr, 0.2, 4, PANEL2); rl.DrawRectangleRoundedLinesEx(hr, 0.2, 4, 1, ps_hf ? ACCENT : LINE)
	tf_field(&tf_pw, wr, &ps_wf, true)
	tf_field(&tf_ph, hr, &ps_hf, true)
	txt("×", wr.x + wr.width + 8, ry + 5, FS_LG, MUTED)
	if cwv > 0 && chv > 0 do txt(rl.TextFormat("Proporção %s", ratio_label(cwv, chv)), hr.x + hr.width + 16, ry + 6, FS_MD, MUTED)

	// --- Taxa de Frames (fixa neste editor) ---
	txt("Taxa de Frames:", lx, ry + 50, FS_MD, TEXT)
	txt("30 fps  (fixo)", lx + 158, ry + 50, FS_MD, MUTED)

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
	if modal == .Silence { draw_silence_modal(sw, sh); return }
	if modal == .STT { draw_stt_modal(sw, sh); return }
	if modal == .Caps { draw_caps_modal(sw, sh); return }
	rl.DrawRectangleRec({0,0,sw,sh}, SCRIM) // backdrop escuro
	cw: f32 = modal == .Export ? 760 : 540
	ch: f32 = modal == .Done ? 210 : (modal == .Confirm ? 190 : (modal == .Shot ? 250 : (modal == .Export ? 490 : 430)))
	cx := sw/2 - cw/2; cy := sh/2 - ch/2
	card := rl.Rectangle{ cx, cy, cw, ch }
	rl.DrawRectangleRounded(card, 0.04, 8, SURFACE)
	rl.DrawRectangleRoundedLinesEx(card, 0.04, 8, 1, LINE)
	title: cstring = modal == .Export ? "Exportar" : (modal == .Shot ? "Salvar screenshot" : (modal == .Confirm ? "Salvar alterações?" : "Exportação concluída"))
	txt(title, cx + 24, cy + 18, FS_XL, TEXT)
	xr := rl.Rectangle{ cx + cw - 38, cy + 16, 24, 24 }
	if clicked(xr) { modal = .None; pending_action = .None } // fechar no X = cancelar a ação pendente
	rl.DrawLineEx({xr.x+6,xr.y+6},{xr.x+16,xr.y+16}, 1.8, hovered(xr) ? TEXT : MUTED)
	rl.DrawLineEx({xr.x+16,xr.y+6},{xr.x+6,xr.y+16}, 1.8, hovered(xr) ? TEXT : MUTED)

	if modal == .Confirm {
		txt("Há alterações não salvas na timeline.", cx + 24, cy + 62, FS_MD, TEXT)
		txt("O que deseja fazer?", cx + 24, cy + 86, FS_MD, MUTED)
		if ui_btn({ cx + 24, cy + ch - 52, 150, 36 }, "Salvar", true) {
			modal = .None
			if save_now() do do_pending() // grava AGORA (já tem caminho, ou pede o nome)
			else do pending_action = .None // cancelou o diálogo: aborta a ação
		}
		if ui_btn({ cx + 184, cy + ch - 52, 150, 36 }, "Não salvar", false) { modal = .None; do_pending() }
		if ui_btn({ cx + cw - 130, cy + ch - 52, 106, 36 }, "Cancelar", false) { modal = .None; pending_action = .None }
		return
	}

	if modal == .Done {
		txt("Arquivo salvo em:", cx + 24, cy + 64, FS_MD, MUTED)
		dd := done_path; if len(dd) > 60 do dd = fmt.tprintf("...%s", dd[len(dd)-57:])
		txt(cs(dd), cx + 24, cy + 88, FS_MD, TEXT)
		if ui_btn({ cx + 24, cy + ch - 52, 170, 36 }, "Reproduzir prévia", true) {
			preview_pending = import_media(done_path, false); modal = .None
		}
		if ui_btn({ cx + 204, cy + ch - 52, 130, 36 }, "Abrir pasta", false) do reveal_in_explorer(done_path)
		if ui_btn({ cx + cw - 110, cy + ch - 52, 86, 36 }, "Fechar", false) do modal = .None
		return
	}

	// ---- modal EXPORTAR: formatos à esquerda, ajustes + resumo à direita, rodapé com destino ----
	if modal == .Export {
		HDR :: 56 // cabeçalho (título + X, desenhados acima)
		FTR :: 68 // rodapé (destino + botões)
		body_y := cy + HDR
		body_h := ch - HDR - FTR
		foot_y := cy + ch - FTR
		rl.DrawLineEx({ cx + 1, body_y }, { cx + cw - 1, body_y }, 1, LINE)
		rl.DrawLineEx({ cx + 1, foot_y }, { cx + cw - 1, foot_y }, 1, LINE)

		// barra lateral de FORMATOS, um degrau abaixo do cartão
		sbw := f32(200)
		rl.DrawRectangleRec({ cx + 1, body_y + 1, sbw, body_h - 1 }, PANEL2)
		rl.DrawLineEx({ cx + 1 + sbw, body_y }, { cx + 1 + sbw, foot_y }, 1, LINE)
		txt("FORMATO", cx + 22, body_y + 16, FS_XS, MUTED)
		FMT_LABELS := [ExportFmt]cstring{ .MP4 = "MP4", .HEVC = "HEVC", .WEBM = "WEBM", .MP3 = "MP3" }
		FMT_DESC   := [ExportFmt]cstring{ .MP4 = "H.264 · mais compatível", .HEVC = "H.265 · arquivo menor", .WEBM = "VP9 · para web", .MP3 = "Só o áudio" }
		fy := body_y + 40
		for f in ExportFmt {
			rr := rl.Rectangle{ cx + 10, fy, sbw - 19, 50 }
			sel := export_fmt == f
			hot := hovered(rr)
			if sel do rl.DrawRectangleRounded(rr, 0.2, 6, CONTROL)
			else if hot do rl.DrawRectangleRounded(rr, 0.2, 6, alpha(CONTROL, 120))
			ib := rl.Rectangle{ rr.x + 9, rr.y + 9, 32, 32 }
			rl.DrawRectangleRounded(ib, 0.3, 6, sel ? ACCENT_BG : (hot ? CONTROL : SURFACE))
			draw_icon(f == .MP3 ? .Music : .Film, ib.x + 16, ib.y + 16, 18, sel ? ACCENT : (hot ? TEXT : MUTED))
			txt(FMT_LABELS[f], rr.x + 52, rr.y + 8, FS_MD, sel || hot ? TEXT : MUTED)
			txt(elide(string(FMT_DESC[f]), FS_XS, rr.width - 60), rr.x + 52, rr.y + 27, FS_XS, MUTED)
			if clicked(rr) do export_fmt = f
			fy += 54
		}

		// painel à direita: coluna de rótulos medida (acompanha a escala da fonte)
		px := cx + sbw + 28
		pr := cx + cw - 28
		LBLS := [4]cstring{ "Nome", "Salvar em", "Qualidade", "Renderizar" }
		lw: f32 = 0
		for l in LBLS do lw = max(lw, txt_w(l, FS_MD))
		fx := px + lw + 20
		fw := pr - fx
		py := body_y + 22
		ext := cs(export_fmt_ext(export_fmt))

		// Nome — a extensão do formato aparece fixa no fim do campo
		txt("Nome", px, py + 9, FS_MD, MUTED)
		nf := rl.Rectangle{ fx, py, fw, 32 }
		rl.DrawRectangleRounded(nf, 0.25, 6, SUNK)
		ew := txt_w(ext, FS_MD)
		tf_field(&tf_name, { nf.x, nf.y + 2, nf.width - ew - 16, 28 }, &name_focus, false)
		txt(ext, nf.x + nf.width - ew - 10, nf.y + 9, FS_MD, MUTED)
		rl.DrawRectangleRoundedLinesEx(nf, 0.25, 6, 1, ACCENT)
		py += 44

		// Salvar em — o campo todo abre o diálogo
		txt("Salvar em", px, py + 9, FS_MD, MUTED)
		df := rl.Rectangle{ fx, py, fw, 32 }
		dhot := hovered(df)
		rl.DrawRectangleRounded(df, 0.25, 6, dhot ? PANEL2 : SUNK)
		rl.DrawRectangleRoundedLinesEx(df, 0.25, 6, 1, dhot ? GRIP : LINE)
		txt(elide_left(save_dir, FS_MD, df.width - 46), df.x + 10, df.y + 9, FS_MD, TEXT)
		draw_icon(.Folder, df.x + df.width - 18, df.y + 16, 16, dhot ? TEXT : MUTED)
		if clicked(df) {
			if p, ok := save_dialog(name_str()); ok {
				if d := dir_of(p); d != "" { if save_dir != "" do delete(save_dir); save_dir = strings.clone(d) }
				b := p[len(dir_of(p)) + 1:]
				if dot := strings.last_index_byte(b, '.'); dot > 0 do b = b[:dot]
				set_name(b)
			}
		}
		py += 44

		// Qualidade + o que cada opção significa
		txt("Qualidade", px, py + 9, FS_MD, MUTED)
		QLABELS := [ExportQual]cstring{ .High = "Alta", .Medium = "Média", .Low = "Baixa", .Auto = "Auto" }
		QHINTS  := [ExportQual]cstring{
			.High   = "Máxima fidelidade — arquivo maior, exportação mais lenta",
			.Medium = "Equilíbrio entre qualidade, tamanho e velocidade",
			.Low    = "Arquivo leve e exportação rápida — perde detalhe",
			.Auto   = "Alta qualidade, sem passar do bitrate dos clipes de origem",
		}
		qs: [len(ExportQual)]cstring
		for q in ExportQual do qs[int(q)] = QLABELS[q]
		if i := ui_segmented({ fx, py, fw, 32 }, qs[:], int(export_qual)); i >= 0 do export_qual = ExportQual(i)
		txt(QHINTS[export_qual], fx + 2, py + 39, FS_XS, MUTED)
		py += 64

		// modo de renderização
		txt("Renderizar", px, py + 9, FS_MD, MUTED)
		modes := [2]cstring{ "Vídeo único", "Um arquivo por clipe" }
		if i := ui_segmented({ fx, py, fw, 32 }, modes[:], export_individual ? 1 : 0); i >= 0 do export_individual = i == 1
		py += 50

		// resumo: quatro números lado a lado num cartão rebaixado
		W, H := export_dims()
		total := timeline_dur()
		ts := int(total + 0.5)
		est := export_est_size_mb(int(W), int(H), total)
		keys, vals: [4]cstring
		if export_fmt == .MP3 {
			keys[0], vals[0] = "TIPO", "Áudio"
			kbps := export_qual == .High ? 320 : (export_qual == .Low ? 128 : 192)
			keys[1], vals[1] = "BITRATE", rl.TextFormat("%d kbps", i32(kbps))
		} else {
			keys[0], vals[0] = "RESOLUÇÃO", rl.TextFormat("%d×%d", i32(W), i32(H))
			keys[1], vals[1] = "QUADROS", "30 fps"
		}
		if export_individual {
			keys[2], vals[2] = "ARQUIVOS", rl.TextFormat("%d", i32(individual_clip_count()))
		} else {
			keys[2], vals[2] = "DURAÇÃO", rl.TextFormat("%02d:%02d:%02d", i32(ts/3600), i32((ts%3600)/60), i32(ts%60))
		}
		keys[3] = "TAMANHO EST."
		vals[3] = est >= 1024 ? rl.TextFormat("~%.2f GB", est/1024) : rl.TextFormat("~%.0f MB", est)
		sc := rl.Rectangle{ px, py, pr - px, 64 }
		rl.DrawRectangleRounded(sc, 0.2, 6, PANEL2)
		colw := sc.width / 4
		for i in 0 ..< 4 {
			x := sc.x + f32(i)*colw
			if i > 0 do rl.DrawLineEx({ x, sc.y + 14 }, { x, sc.y + sc.height - 14 }, 1, SEP)
			txt(keys[i], x + 14, sc.y + 13, FS_XS, MUTED)
			txt(vals[i], x + 14, sc.y + 31, FS_LG, TEXT)
		}
		py += 80

		// GPU: só H.264/HEVC têm NVENC; VP9 aparece desligado com o porquê; MP3 não tem vídeo
		if export_fmt != .MP3 {
			ok := export_nvenc_ok && export_fmt != .WEBM
			gr := rl.Rectangle{ px, py, pr - px, 36 }
			ghot := ok && hovered(gr)
			ui_switch({ px, py + 9, 34, 18 }, export_gpu, ghot, ok)
			txt("Aceleração por GPU (NVENC)", px + 46, py, FS_MD, ok ? TEXT : MUTED)
			sub: cstring = "Codifica na placa de vídeo — bem mais rápido"
			if export_fmt == .WEBM do sub = "VP9 não usa GPU — exporta por CPU, mais devagar"
			else if !export_nvenc_ok do sub = "Indisponível neste computador — exporta por CPU"
			txt(sub, px + 46, py + 19, FS_XS, MUTED)
			if ok && clicked(gr) do export_gpu = !export_gpu
		}

		// rodapé: onde o arquivo vai parar + ações (Enter exporta, Esc cancela no update)
		bx := cx + cw - 24 - 128
		dest: string
		if export_individual {
			dest = fmt.tprintf("%s\\%s_001%s … _%03d%s", save_dir, name_str(), ext, i32(individual_clip_count()), ext)
		} else {
			dest = fmt.tprintf("%s\\%s%s", save_dir, name_str(), ext)
		}
		dmax := bx - 114 - 20 - (cx + 24)
		txt("Destino", cx + 24, foot_y + 15, FS_XS, MUTED)
		txt(elide_left(dest, FS_SM, dmax), cx + 24, foot_y + 32, FS_SM, TEXT)
		cr := rl.Rectangle{ bx - 114, foot_y + 16, 104, 36 }
		chot := hovered(cr)
		if chot do rl.DrawRectangleRounded(cr, 0.3, 6, CONTROL)
		rl.DrawRectangleRoundedLinesEx(cr, 0.3, 6, 1, chot ? GRIP : LINE)
		txt_c("Cancelar", cr.x + cr.width/2, cr.y + cr.height/2 - 8, FS_MD, TEXT)
		if clicked(cr) do modal = .None
		if ui_btn({ bx, foot_y + 16, 128, 36 }, "Exportar", true) || rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER) {
			if tf_name.len == 0 do set_toast("Digite um nome")
			else {
				// enfileira: o start real roda no update (fora do BeginDrawing)
				if export_individual do queue_individual_exports(save_dir, name_str(), export_gpu)
				else {
					export_range_on = false
					export_queue_active = false
					queue_export(fmt.tprintf("%s/%s%s", save_dir, name_str(), export_fmt_ext(export_fmt)), export_gpu)
				}
				modal = .None
			}
		}
		return
	}

	// campo de NOME (cursor + seleção; foco automático enquanto o modal está aberto)
	lx := cx + 24; fy := cy + 62
	txt("Nome:", lx, fy + 6, FS_MD, TEXT)
	nf := rl.Rectangle{ lx + 90, fy, cw - 90 - 48, 28 }
	rl.DrawRectangleRounded(nf, 0.2, 4, PANEL2)
	tf_field(&tf_name, nf, &name_focus, false) // allow_unfocus=false: o nome segue focado no modal
	rl.DrawRectangleRoundedLinesEx(nf, 0.2, 4, 1, ACCENT)
	fy += 42
	txt("Salvar em:", lx, fy + 6, FS_MD, TEXT)
	df := rl.Rectangle{ lx + 90, fy, cw - 90 - 48 - 36, 28 }
	rl.DrawRectangleRounded(df, 0.2, 4, PANEL2)
	dd := save_dir; if len(dd) > 44 do dd = fmt.tprintf("...%s", dd[len(dd)-41:])
	txt(cs(dd), df.x + 8, df.y + 6, FS_MD, MUTED)
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
	txt("Formato:", lx, fy + 2, FS_MD, MUTED)
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
		txt(label, x + (indent ? 12 : 0), y, FS_MD, indent ? rl.Color{ 150, 165, 185, 255 } : c)
		txt(rl.TextFormat("%.2f ms", ms), x + 150, y, FS_MD, c)
	}
	txt(rl.TextFormat("PROFILER  F3   %d fps", rl.GetFPS()), x, y, FS_MD, rl.Color{ 120, 200, 250, 255 }); y += 20
	line(x, y, "update",    prof_avg[.Update],   prof_avg[.Update] > 8);  y += 17
	line(x, y, "video",     prof_avg[.Video],    prof_avg[.Video]  > 6, true); y += 17
	line(x, y, "audio",     prof_avg[.Audio],    prof_avg[.Audio]  > 3, true); y += 17
	line(x, y, "draw",      prof_avg[.Draw],     prof_avg[.Draw]   > 8);  y += 17
	line(x, y, "preview",   prof_avg[.Preview],  prof_avg[.Preview]> 5, true); y += 17
	line(x, y, "timeline",  prof_avg[.Timeline], prof_avg[.Timeline] > 6, true); y += 17
	line(x, y, "wave",      prof_avg[.Tl_Wave],  prof_avg[.Tl_Wave] > 4, true); y += 17
	line(x, y, "thumbs",    prof_avg[.Tl_Thumb], prof_avg[.Tl_Thumb] > 4, true); y += 17
	line(x, y, "TOTAL",     total,               total > 16.6);          y += 20
	txt(rl.TextFormat("%d video sob playhead (%d streaming)  hw-off:%d", nvid, nstream, nhwoff), x, y, FS_SM,
		nhwoff > 0 ? rl.Color{ 250, 170, 90, 255 } : rl.Color{ 150, 165, 185, 255 }); y += 16
	// latência do decode assíncrono de scrub (thread própria — NÃO entra no total da main)
	if scrub_last_ms > 0 {
		shw := false; if vs := view_seg(); vs >= 0 do shw = seg_src(vs).scrub_hw
		txt(rl.TextFormat("scrub: %.0f ms/frame (%s) (ult. decode)", scrub_last_ms, shw ? cstring("HW") : cstring("SW")), x, y, FS_SM,
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
			c.no_hw ? cstring("SIM") : cstring("nao"), c.eof_at), x, y, FS_SM,
			(rsp && rt > 2) ? rl.Color{ 250, 170, 90, 255 } : gray); y += 16
		thumbing := abs(lt - c.tex_t) > SCRUB_SHARP_S
		txt(rl.TextFormat("gap=%.2fs  tex_dt=%.2fs  MINIATURA:%s",
			lt - live_now(c), lt - c.tex_t,
			thumbing ? cstring("SIM") : cstring("nao")), x, y, FS_SM,
			thumbing ? rl.Color{ 250, 170, 90, 255 } : gray); y += 15
		// números CRUS: qual está insano — o playhead, o tempo-fonte, ou o decoder?
		txt(rl.TextFormat("ph=%.1f lt=%.1f  lbase=%.1f lframe=%d", st.playhead, lt, c.live_base, c.live_frame), x, y, FS_SM, gray); y += 15
		txt(rl.TextFormat("tex_t=%.1f  gmtp=%.1f base=%.1f", c.tex_t, rl.GetMusicTimePlayed(c.music), c.music_base), x, y, FS_SM, gray); y += 15
		// último respawn: alvo pedido vs playhead no instante — quem manda o decoder longe?
		bad := abs(dbg_rsp_t - dbg_rsp_ph) > 3.0
		txt(rl.TextFormat("respawn #%d -> t=%.1f (ph era %.1f)", dbg_rsp_n, dbg_rsp_t, dbg_rsp_ph), x, y, FS_SM,
			bad ? rl.Color{ 250, 120, 120, 255 } : gray); y += 3
		// SALTO do playhead capturado (bug "cursor pula sozinho"): quem mandou o pulo
		if dbg_jmp_n > 0 {
			txt(rl.TextFormat("SALTO #%d: %.1f -> %.1fs (+%.1fs)", dbg_jmp_n, dbg_jmp_from, dbg_jmp_to, dbg_jmp_to - dbg_jmp_from), x, y, FS_SM, rl.Color{ 250, 120, 120, 255 }); y += 15
			txt(rl.TextFormat("  gmtp=%.1f base=%.1f len=%.1f", dbg_jmp_gmtp, dbg_jmp_base, dbg_jmp_len), x, y, FS_SM, rl.Color{ 250, 170, 90, 255 }); y += 15
			txt(rl.TextFormat("  loc0=%.1f acq=%s pend=%s", dbg_jmp_loc0, dbg_jmp_acq ? cstring("S") : cstring("N"), dbg_jmp_pend ? cstring("S") : cstring("N")), x, y, FS_SM, rl.Color{ 250, 170, 90, 255 })
		}
	}
}

// ---------- draw raiz ----------
draw :: proc() {
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())

	// rects dos botões do overlay de exportação: zera aqui e só o próprio overlay os
	// repõe. Em tela cheia o draw retorna antes dele, mas o update continuava testando a
	// colisão (só olha export_run) — os rects do último frame em janela viravam uma faixa
	// invisível no meio do vídeo que cancelava a exportação com um clique qualquer.
	g_exp_pause_btn = {}; g_exp_cancel_btn = {}
	g_insp_card = {}
	if fullscreen_preview do inspector_clear_focus()

	if fullscreen_preview { // modo tela cheia: só o vídeo
		draw_fullscreen_video(sw, sh)
		return
	}

	topbar_h  : f32 = 34
	toolbar_h : f32 = 64
	subbar_h  : f32 = 38
	content_top := topbar_h + toolbar_h + subbar_h
	// altura da timeline = fração da janela (arrastável pela divisória), com MÍN e MÁX:
	// TL_MIN mantém a timeline usável (toolbar+régua+2 trilhas); CONTENT_MIN garante que o
	// bin/preview nunca encolham a ponto de inutilizar o player (66px são só do transport).
	TL_MIN      :: f32(250) // toolbar(34)+régua(22)+~3 trilhas — 170 deixava 1 trilha só ("muito pequeno")
	CONTENT_MIN :: f32(280)
	tl_max := max(TL_MIN, sh - content_top - CONTENT_MIN)
	tl_h := clamp(sh * tl_frac, TL_MIN, tl_max)
	tl_top := sh - tl_h

	// divisória ARRASTÁVEL (estilo NLE): faixa fina no limite conteúdo/timeline. Zona de 6px
	// (tl_top-3..+3) escolhida p/ NÃO sobrepor os botões da toolbar da timeline (começam em
	// tl_top+4) nem os controles do player (terminam 8px acima). O press daqui roda ANTES dos
	// painéis, e a marquee do bin checa !tl_split_drag (os 3px de cima tocam o rodapé dela).
	m_div := rl.GetMousePosition()
	if tl_split_drag {
		// ao SOLTAR marca o projeto como não-salvo (o layout vai no .ovp): 1× por ajuste, não a
		// cada frame de arrasto — sem isso o usuário monta o layout, fecha e perde sem aviso
		if !rl.IsMouseButtonDown(.LEFT) { tl_split_drag = false; dirty = true }
		else {
			// clampa a PRÓPRIA fração nos limites (não só o tl_h): senão arrastar além do teto
			// acumulava fração "fantasma" e o knob demorava a reagir no arrasto de volta
			tl_frac = clamp((sh - m_div.y) / sh, TL_MIN / sh, tl_max / sh)
			tl_h = clamp(sh * tl_frac, TL_MIN, tl_max)
			tl_top = sh - tl_h
		}
	} else if rl.IsMouseButtonPressed(.LEFT) && hovered({ 0, tl_top - 6, sw, 9 }) &&
	          st.drag == .None && !player_seek_drag && !bin_marquee && !tl_marquee && !win_dragging && modal == .None {
		// zona de 9px esticada p/ CIMA (6px sobre o rodapé do bin/preview — a divisória tem
		// prioridade sobre eles; 3px p/ baixo, longe dos botões da toolbar em tl_top+4).
		// Com 6px o usuário errava o agarre e o clique caía no bin (2 erros <0.5s = importar).
		tl_split_drag = true
	}

	// largura do bin = fração da janela (divisória VERTICAL bin↔player, espelho da de cima):
	// arrastar p/ a esquerda ALARGA o player. Limites: bin com ~2 colunas de miniaturas;
	// player nunca menor que 420px.
	MD_MIN :: f32(280)
	PV_MIN :: f32(420)
	md_max := max(MD_MIN, sw - PV_MIN)
	media_w := clamp(sw * md_frac, MD_MIN, md_max)
	if md_split_drag {
		if !rl.IsMouseButtonDown(.LEFT) { md_split_drag = false; dirty = true } // idem: layout salvo no .ovp
		else {
			md_frac = clamp(m_div.x / sw, MD_MIN / sw, md_max / sw)
			media_w = clamp(sw * md_frac, MD_MIN, md_max)
		}
	} else if rl.IsMouseButtonPressed(.LEFT) && hovered({ media_w - 5, content_top, 8, tl_top - content_top }) &&
	          !tl_split_drag && st.drag == .None && !player_seek_drag && !bin_marquee && !tl_marquee && !win_dragging && modal == .None {
		// zona de 8px (5 sobre o bin, 3 sobre o player); a de cima tem prioridade (T-junção)
		md_split_drag = true
	}

	draw_topbar(sw, topbar_h)
	draw_toolbar(sw, topbar_h, toolbar_h)
	draw_subbar(topbar_h + toolbar_h, media_w, subbar_h)
	draw_media_panel(rl.Rectangle{ 0, content_top, media_w, tl_top - content_top })
	preview_area := inspector_layout({ media_w, topbar_h + toolbar_h, sw - media_w, tl_top - (topbar_h + toolbar_h) })
	draw_preview(preview_area)
	draw_timeline(rl.Rectangle{ 0, tl_top, sw, tl_h })

	// feedback das divisórias (depois do draw_timeline: o cursor setado aqui vence o de lá)
	split_hot := tl_split_drag || (hovered({ 0, tl_top - 6, sw, 9 }) && st.drag == .None && !player_seek_drag && !bin_marquee && !tl_marquee && !md_split_drag && modal == .None)
	if split_hot {
		rl.SetMouseCursor(.RESIZE_NS)
		rl.DrawRectangleRec({ 0, tl_top - 1, sw, 2 }, alpha(ACCENT, tl_split_drag ? 235 : 130))
	}
	// pegador SEMPRE visível no centro (pílula + 3 pontinhos): mostra ONDE agarrar mesmo sem hover
	gp := rl.Rectangle{ sw/2 - 26, tl_top - 4, 52, 8 }
	rl.DrawRectangleRounded(gp, 1, 4, split_hot ? ACCENT : GRIP)
	dc := split_hot ? INK : MUTED
	for i in 0 ..< 3 {
		rl.DrawCircleV({ gp.x + gp.width/2 + f32(i - 1) * 9, gp.y + gp.height/2 }, 1.6, dc)
	}
	// divisória VERTICAL bin↔player: mesma linguagem visual, cursor EW e pegador em pé
	md_hot := md_split_drag || (hovered({ media_w - 5, content_top, 8, tl_top - content_top }) && st.drag == .None && !player_seek_drag && !bin_marquee && !tl_marquee && !tl_split_drag && modal == .None)
	if md_hot {
		rl.SetMouseCursor(.RESIZE_EW)
		rl.DrawRectangleRec({ media_w - 1, content_top, 2, tl_top - content_top }, alpha(ACCENT, md_split_drag ? 235 : 130))
	}
	mgp := rl.Rectangle{ media_w - 4, (content_top + tl_top)/2 - 26, 8, 52 }
	rl.DrawRectangleRounded(mgp, 1, 4, md_hot ? ACCENT : GRIP)
	mdc := md_hot ? INK : MUTED
	for i in 0 ..< 3 {
		rl.DrawCircleV({ mgp.x + mgp.width/2, mgp.y + mgp.height/2 + f32(i - 1) * 9 }, 1.6, mdc)
	}

	// fantasma do item do bin sendo arrastado para a timeline (com contagem se forem vários)
	if st.drag == .Bin && bin_drag >= 0 && bin_drag < nclips {
		c := &clips[bin_drag]
		m := rl.GetMousePosition()
		nm := bin_marks_count()
		// FOOTPRINT: retângulo verde onde a mídia vai cair (posição + duração na trilha alvo)
		if bin_drop_show {
			if bin_drop_newtrack { // trilha NOVA: fantasma (altura de clipe) centrado na área de drop
				gh := min(bin_drop_zone.height - 8, th(bin_drop_tr) - 8)
				fy := bin_drop_zone.y + (bin_drop_zone.height - gh)/2
				fr := rl.Rectangle{ tl_x(bin_drop_start), fy, bin_drop_dur*pps(), gh }
				rl.DrawRectangleRec(fr, alpha(SUCCESS, 60))
				rl.DrawRectangleLinesEx(fr, 1.6, alpha(SUCCESS, 235))
				txt(cs(c.name), fr.x + 6, fr.y + 4, FS_XS, rl.WHITE)
			} else {
				ok := !track_locked[bin_drop_tr] // trilha travada = não pode receber (vermelho)
				fr := rl.Rectangle{ tl_x(bin_drop_start), track_y(bin_drop_tr) + 4, bin_drop_dur*pps(), th(bin_drop_tr) - 8 }
				rl.DrawRectangleRec(fr, ok ? alpha(SUCCESS, 60) : alpha(DANGER, 55))
				rl.DrawRectangleLinesEx(fr, 1.6, ok ? alpha(SUCCESS, 235) : alpha(DANGER, 235))
			}
		}
		gr := rl.Rectangle{ m.x - 60, m.y - 20, 120, 40 }
		if c.tex_ok do rl.DrawTexturePro(c.tex, {0,0,f32(cdw(c)),f32(cdh(c))}, gr, {0,0}, 0, rl.Color{255,255,255,180})
		rl.DrawRectangleLinesEx(gr, 1, ACCENT)
		if nm > 1 { // badge com a quantidade sobre a pilha
			br := rl.Rectangle{ gr.x + gr.width - 14, gr.y - 8, 26, 20 }
			rl.DrawRectangleRounded(br, 0.5, 6, ACCENT)
			txt_c(rl.TextFormat("%d", nm), br.x + br.width/2, br.y + 3, FS_SM, rl.WHITE)
		}
		over := rl.CheckCollisionPointRec(m, g_vlane) // sobre uma trilha existente
		lbl := over ? (nm > 1 ? rl.TextFormat("soltar %d aqui", nm) : cstring("soltar aqui")) : (nm > 1 ? rl.TextFormat("%d mídias", nm) : cs(c.name))
		txt_c(lbl, gr.x + 60, gr.y + 44, FS_XS, over ? ACCENT : MUTED)
	}

	// fantasma da TRANSIÇÃO sendo arrastada + guia no corte alvo
	if st.drag == .Trans && trans_drag >= 0 {
		m := rl.GetMousePosition()
		over := rl.CheckCollisionPointRec(m, g_vlane)
		if over { // marca o corte/borda alvo com uma linha vertical âmbar
			si := seg_on_track_at(track_at_y(m.y), tl_t(m.x))
			if si >= 0 {
				sg := segs[si]
				edge := sg.start // corte esquerdo / fade entrada
				if trans_panel_is_cut(trans_drag) && tl_t(m.x) > sg.start + sg.dur/2 do edge = sg.start + sg.dur
				if trans_drag == 2 do edge = sg.start + sg.dur // fade saída
				ex := tl_x(edge)
				rl.DrawLineEx({ ex, g_vlane.y }, { ex, g_vlane.y + g_vlane.height }, 2.5, alpha(WARN, 235))
			}
		}
		name := trans_panel_name(trans_drag)
		nw := max(f32(112), txt_w(name, FS_SM) + 24)
		gr := rl.Rectangle{ m.x - nw/2, m.y - 16, nw, 30 }
		rl.DrawRectangleRounded(gr, 0.3, 6, alpha(CONTROL, 230))
		rl.DrawRectangleRoundedLinesEx(gr, 0.3, 6, 1, over ? ACCENT : LINE)
		txt_c(name, gr.x + nw/2, gr.y + 7, FS_SM, over ? ACCENT : TEXT)
	}

	if save_flash_t > 0 {
		label: cstring = save_flash_ok ? "Salvo" : "Salvando..."
		w := txt_w(label, FS_LG) + 40
		r := rl.Rectangle{ sw/2 - w/2, sh/2 - 28, w, 48 }
		fade := save_flash_ok ? clamp(save_flash_t / 0.45, 0, 1) : 1 // Salvo some no fim; Salvando fica opaco
		a := u8(fade * 235)
		rl.DrawRectangleRounded(r, 0.25, 8, alpha(SURFACE, a))
		rl.DrawRectangleRoundedLinesEx(r, 0.25, 8, 2, alpha(ACCENT, a))
		txt_c(label, sw/2, r.y + 14, FS_LG, alpha(TEXT, a))
	}

	if toast_t > 0 && save_flash_t <= 0 {
		w := txt_w(toast_msg, FS_MD) + 28
		r := rl.Rectangle{ sw/2 - w/2, 46, w, 30 }
		a := u8(clamp(toast_t / 3 * 255, 0, 230))
		rl.DrawRectangleRounded(r, 0.4, 8, alpha(CONTROL, a))
		rl.DrawRectangleRoundedLinesEx(r, 0.4, 8, 1, alpha(ACCENT, a))
		txt_c(toast_msg, sw/2, 53, FS_MD, alpha(TEXT, a))
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
		rl.DrawRectangleRec({ 0, 0, sw, sh }, alpha(SCRIM, 120)) // escurece o fundo
		rl.DrawRectangleRounded({ bx, by, bw, bh }, 0.06, 8, SURFACE)
		rl.DrawRectangleRoundedLinesEx({ bx, by, bw, bh }, 0.06, 8, 1, LINE)
		txt(export_paused ? "Exportação pausada" : "Exportando vídeo...", bx + 24, by + 16, FS_LG, export_paused ? WARN : TEXT)
		txt(rl.TextFormat("%d%%", i32(export_pct*100)), bx + bw - 60, by + 16, FS_LG, ACCENT)
		// prévia
		pr := rl.Rectangle{ bx + 24, by + 42, pw, ph }
		rl.DrawRectangleRec(pr, rl.BLACK)
		if export_prev_tex_ok && intrinsics.atomic_load(&export_prev_seq) > 0 {
			rl.DrawTexturePro(export_prev_tex, { 0, 0, f32(PREV_W), f32(PREV_H) }, pr, { 0, 0 }, 0, rl.WHITE)
		} else {
			txt_c("preparando…", pr.x + pr.width/2, pr.y + pr.height/2 - 8, FS_MD, MUTED)
		}
		if export_paused { // véu + ícone de pause sobre a prévia congelada
			rl.DrawRectangleRec(pr, alpha(SCRIM, 90))
			bxr := pr.x + pr.width/2; byr := pr.y + pr.height/2
			rl.DrawRectangleRec({ bxr - 13, byr - 15, 8, 30 }, alpha(TEXT, 230))
			rl.DrawRectangleRec({ bxr + 5,  byr - 15, 8, 30 }, alpha(TEXT, 230))
		}
		rl.DrawRectangleLinesEx(pr, 1, LINE)
		// barra de progresso
		track := rl.Rectangle{ bx + 24, pr.y + ph + 16, bw - 48, 10 }
		rl.DrawRectangleRounded(track, 1, 6, TRACK_BG)
		rl.DrawRectangleRounded({ track.x, track.y, track.width * clamp(export_pct, 0, 1), track.height }, 1, 6, ACCENT)
		// botões: Pausar/Retomar + Cancelar (clique tratado no update; aqui só desenha)
		bw2 := (bw - 48 - 12) / 2
		byb := track.y + 24
		g_exp_pause_btn  = { bx + 24, byb, bw2, 34 }
		g_exp_cancel_btn = { bx + 24 + bw2 + 12, byb, bw2, 34 }
		draw_overlay_btn(g_exp_pause_btn, export_paused ? "Retomar" : "Pausar", ACCENT)
		draw_overlay_btn(g_exp_cancel_btn, "Cancelar", DANGER)
	}

	draw_file_menu()   // dropdown do menu Arquivo (por cima da toolbar)
	draw_ctx_menu()    // menu de contexto da timeline (botão direito)
	draw_modal(sw, sh) // modais de exportar/screenshot/conclusão por cima de tudo
	// FEEDBACK de arraste de efeito: etiqueta flutuante seguindo o cursor
	if st.drag == .FxLib && fxlib_drag >= 0 {
		m := rl.GetMousePosition()
		nm := fxlib_name(fxlib_drag)
		wpx := txt_w(nm, FS_MD) + 24
		box := rl.Rectangle{ m.x - wpx/2, m.y - 13, wpx, 26 } // CENTRADO no cursor (fica "em cima")
		rl.DrawRectangleRounded(box, 0.4, 6, alpha(CONTROL, 240))
		rl.DrawRectangleRoundedLinesEx(box, 0.4, 6, 1.5, ACCENT)
		rl.DrawCircleV({ box.x + 12, box.y + 13 }, 4, ACCENT) // "grão" do efeito
		txt(nm, box.x + 22, box.y + 6, FS_MD, TEXT)
	}
}

// ---------- menu de contexto da timeline (botão direito) ----------
CtxItem :: struct {
	label: cstring,
	on:    bool, // habilitado (desabilitado = cinza, clique só fecha)
	id:    int,  // ação estável (o layout muda conforme o alvo)
}

// monta os itens p/ o alvo atual (ctx_seg / ctx_fx / vazio). Retorna a contagem.
ctx_items :: proc(it: ^[14]CtxItem) -> int {
	n := 0
	if ctx_fx >= 0 && ctx_fx < nfx {
		grp := fx_marks_count() > 1 && fx_marked[ctx_fx]
		it[n] = { "Copiar efeito", true, 10 }; n += 1
		it[n] = { "Colar ajustes aqui", fx_clipbrd_ok(), 11 }; n += 1
		if grp do it[n] = { "Excluir grupo  (Del)", true, 12 }
		else do it[n] = { "Excluir  (Del)", true, 12 }
		n += 1
	} else if ctx_seg >= 0 && ctx_seg < nsegs && seg_ready(ctx_seg) {
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
		it[n] = { "Colar aqui  (Ctrl+V)", clipbrd_kind != .None, 3 }; n += 1
		vid := !seg_audio_like(ctx_seg)
		it[n] = { "Copiar ajustes", vid, 10 }; n += 1
		if grp do it[n] = { "Colar ajustes no grupo", vid, 11 }
		else do it[n] = { "Colar ajustes", vid, 11 }
		n += 1
		it[n] = { "Dividir aqui", ctx_time > sg.start + 0.05 && ctx_time < sg.start + sg.dur - 0.05, 4 }; n += 1
		if sg.muted do it[n] = { "Ativar som", seg_src(ctx_seg).has_audio, 5 }
		else do it[n] = { "Silenciar", seg_src(ctx_seg).has_audio, 5 }
		n += 1
		it[n] = { "Separar áudio", seg_src(ctx_seg).has_audio && !seg_audio_like(ctx_seg), 7 }; n += 1
		if grp do it[n] = { "Excluir grupo  (Del)", true, 6 }
		else do it[n] = { "Excluir  (Del)", true, 6 }
		n += 1
	} else {
		if clipbrd_kind == .Fx do it[n] = { "Colar ajustes aqui", fx_clipbrd_ok(), 3 }
		else do it[n] = { "Colar aqui  (Ctrl+V)", seg_clipbrd_n > 0, 3 }
		n += 1
		gok, _, _ := find_gap_at(ctx_track, ctx_time)
		it[n] = { "Fechar vão  (Del)", ctx_track >= 0 && !track_locked[ctx_track] && (sel_gap_ok() || gok), 8 }; n += 1
		it[n] = { "Fechar todos os vãos", ctx_track >= 0 && !track_locked[ctx_track] && track_has_gap(ctx_track), 9 }; n += 1
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
	items: [14]CtxItem
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
	case 3:
		if clipbrd_kind == .Fx {
			if sane do paste_effects_targets(ctx_seg)
			else do paste_fx_at(ctx_track, max(0, ctx_time))
		} else {
			paste_segs(max(0, ctx_time))
		}
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
	case 8:
		if sel_gap_ok() do close_sel_gap()
		else if ctx_track >= 0 {
			ok, t0, t1 := find_gap_at(ctx_track, ctx_time)
			if ok do close_gap(ctx_track, t0, t1)
		}
	case 9:
		if ctx_track >= 0 do close_all_gaps(ctx_track)
	case 10: // copiar efeitos (do clipe de vídeo ou do clipe de efeito)
		if ctx_fx >= 0 && ctx_fx < nfx do copy_fx_clip(ctx_fx)
		else if sane do copy_effects(ctx_seg)
	case 11: // colar efeitos no clipe (ou grupo) / no tempo do clique
		if sane do paste_effects_targets(ctx_seg)
		else do paste_fx_at(ctx_track, max(0, ctx_time))
	case 12: // excluir clipe de efeito (ou o grupo marcado)
		if ctx_fx < 0 || ctx_fx >= nfx do return
		if fx_marks_count() > 1 && fx_marked[ctx_fx] {
			nrm := 0
			for k := nfx - 1; k >= 0; k -= 1 {
				if !fx_marked[k] || track_locked[fxsegs[k].track] do continue
				remove_fxseg(k); nrm += 1
			}
			fx_clear_marks(); fx_sel = -1
			if nrm == 0 do set_toast("Trilha bloqueada")
			else do set_toast(rl.TextFormat("%d efeitos removidos", nrm))
		} else {
			if track_locked[fxsegs[ctx_fx].track] { set_toast("Trilha bloqueada"); return }
			remove_fxseg(ctx_fx); set_toast("Efeito removido")
		}
	}
}

// desenhado por último (por cima da timeline). Hover com colisão CRUA — o
// hovered() global fica inerte enquanto o menu está aberto.
draw_ctx_menu :: proc() {
	if !ctx_open do return
	items: [14]CtxItem
	n := ctx_items(&items)
	r := ctx_rect(n)
	rl.DrawRectangleRounded(r, 0.08, 6, POPUP)
	rl.DrawRectangleRoundedLinesEx(r, 0.08, 6, 1, LINE)
	m := rl.GetMousePosition()
	for k in 0 ..< n {
		ir := rl.Rectangle{ r.x + 3, r.y + 4 + f32(k)*CTX_IH, r.width - 6, CTX_IH }
		if items[k].on && rl.CheckCollisionPointRec(m, ir) do rl.DrawRectangleRounded(ir, 0.2, 4, HOVER)
		col := items[k].on ? TEXT : MUTED
		if items[k].id == 6 && items[k].on do col = DANGER // Excluir em vermelho
		txt(items[k].label, ir.x + 12, ir.y + 7, FS_MD, col)
	}
}

// dropdown do menu Arquivo: Novo / Abrir / Salvar (desenhado por último p/ ficar por cima)
draw_file_menu :: proc() {
	if !file_menu_open do return
	g_file_menu_draw = true
	defer { g_file_menu_draw = false }
	items := []cstring{ "Novo projeto", "Abrir projeto  (Ctrl+O)", "Salvar  (Ctrl+S)", "Salvar como  (Ctrl+Shift+S)" }
	iw: f32 = 268; ih: f32 = 32
	mr := rl.Rectangle{ g_file_menu_x, 34, iw, f32(len(items))*ih + 6 }
	rl.DrawRectangleRounded(mr, 0.06, 6, POPUP)
	rl.DrawRectangleRoundedLinesEx(mr, 0.06, 6, 1, LINE)
	for it, ii in items {
		ir := rl.Rectangle{ mr.x + 3, mr.y + 3 + f32(ii)*ih, iw - 6, ih }
		if hovered(ir) do rl.DrawRectangleRounded(ir, 0.2, 4, HOVER)
		txt(it, ir.x + 12, ir.y + 8, FS_MD, TEXT)
		if clicked(ir) {
			file_menu_open = false
			switch ii {
			case 0: request_new()  // pergunta se quer salvar se houver algo não salvo
			case 1: request_open() // idem antes de abrir outro projeto
			case 2: request_save()
			case 3: request_save_as()
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
	txt("Editor de Vídeo", 34, h/2 - 9, FS_LG, TEXT)

	menus := []cstring{ "Arquivo", "Editar", "Ferramentas", "Visualização", "Exportar", "Ajuda" }
	x: f32 = 150
	for mnu, mi in menus {
		w := txt_w(mnu, FS_MD) + 22
		r := rl.Rectangle{ x, 0, w, h }
		if hovered(r) do rl.DrawRectangleRec(r, HOVER)
		txt(mnu, x + 11, h/2 - 8, FS_MD, (mi == 0 && file_menu_open) ? TEXT : MUTED)
		if clicked(r) {
			if mi == 0 { file_menu_open = !file_menu_open; g_file_menu_x = x }      // Arquivo
			else if mi == 4 { open_export_modal(); file_menu_open = false }          // Exportar
			else do file_menu_open = false
		}
		x += w
	}
	// nome do arquivo no centro da barra (com * se houver edição não salva)
	pname := proj_path != "" ? file_name(proj_path) : "Sem título"
	txt_c(rl.TextFormat(dirty ? "%s  •" : "%s", cs(pname)), sw/2, h/2 - 8, FS_MD, MUTED)

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
	if hovered(cl) do rl.DrawRectangleRec(cl, DANGER)
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
// Ícones vetoriais em uma área de 20 × 20, com traço e cor comuns às abas.
draw_tab_icon :: proc(cx, cy: f32, kind: int, col: rl.Color) {
	stroke :: f32(1.5)
	switch kind {
	case 0: // Mídia: película com perfurações nas laterais.
		rl.DrawRectangleRoundedLinesEx({ cx - 9, cy - 8, 18, 16 }, 0.2, 4, stroke, col)
		rl.DrawLineEx({ cx - 5, cy - 8 }, { cx - 5, cy + 8 }, stroke, col)
		rl.DrawLineEx({ cx + 5, cy - 8 }, { cx + 5, cy + 8 }, stroke, col)
		for row in 0 ..< 3 {
			y := cy - 5 + f32(row) * 5
			rl.DrawLineEx({ cx - 9, y }, { cx - 5, y }, stroke, col)
			rl.DrawLineEx({ cx + 5, y }, { cx + 9, y }, stroke, col)
		}
	case 1: // Transições: dois quadros sobrepostos.
		rl.DrawRectangleRoundedLinesEx({ cx - 9, cy - 7, 12, 11 }, 0.2, 4, stroke, col)
		rl.DrawRectangleRoundedLinesEx({ cx - 3, cy - 3, 12, 11 }, 0.2, 4, stroke, col)
	case 2: // Efeitos: varinha diagonal e brilhos.
		rl.DrawLineEx({ cx - 8, cy + 8 }, { cx + 3, cy - 3 }, stroke, col)
		rl.DrawLineEx({ cx - 4, cy + 2 }, { cx - 2, cy + 4 }, stroke, col)
		rl.DrawLineEx({ cx + 3, cy - 9 }, { cx + 3, cy - 5 }, stroke, col)
		rl.DrawLineEx({ cx + 1, cy - 7 }, { cx + 5, cy - 7 }, stroke, col)
		rl.DrawLineEx({ cx + 7, cy - 2 }, { cx + 7, cy + 4 }, stroke, col)
		rl.DrawLineEx({ cx + 4, cy + 1 }, { cx + 10, cy + 1 }, stroke, col)
		rl.DrawLineEx({ cx - 6, cy - 7 }, { cx - 6, cy - 3 }, stroke, col)
		rl.DrawLineEx({ cx - 8, cy - 5 }, { cx - 4, cy - 5 }, stroke, col)
	case 3: // Cor: três círculos sobrepostos, no tom do estado da aba.
		rl.DrawRing({ cx, cy - 4 }, 4 - stroke/2, 4 + stroke/2, 0, 360, 32, col)
		rl.DrawRing({ cx - 4, cy + 3 }, 4 - stroke/2, 4 + stroke/2, 0, 360, 32, col)
		rl.DrawRing({ cx + 4, cy + 3 }, 4 - stroke/2, 4 + stroke/2, 0, 360, 32, col)
	case 4: // Tela dividida: grade com quatro quadrantes.
		rl.DrawRectangleRoundedLinesEx({ cx - 9, cy - 8, 18, 16 }, 0.2, 4, stroke, col)
		rl.DrawLineEx({ cx, cy - 8 }, { cx, cy + 8 }, stroke, col)
		rl.DrawLineEx({ cx - 9, cy }, { cx + 9, cy }, stroke, col)
	}
}
draw_toolbar :: proc(sw, y, h: f32) {
	rl.DrawRectangleRec({0, y, sw, h}, PANEL2)
	rl.DrawRectangle(0, i32(y + h) - 1, i32(sw), 1, LINE)
	tabs := []cstring{
		"Mídia", "Transições", "Efeitos", "Cor", "Tela Dividida",
	}
	x: f32 = 6
	for tab, i in tabs {
		w := txt_w(tab, FS_MD) + 26
		r := rl.Rectangle{ x, y, w, h }
		active := i == st.active_tab
		if active do rl.DrawRectangleRounded({ x + 4, y + 5, w - 8, h - 10 }, 0.18, 4, ACCENT_BG)
		else if hovered(r) do rl.DrawRectangleRec(r, HOVER)
		if clicked(r) do st.active_tab = i
		icol := active ? ACCENT : MUTED
		draw_tab_icon(x + w/2, y + 20, i, icol)
		txt_c(tab, x + w/2, y + 34, FS_MD, active ? TEXT : MUTED)
		if active do rl.DrawRectangleRec({ x + 8, y + h - 3, w - 16, 3 }, ACCENT)
		x += w
	}
	ew: f32 = 96
	er := rl.Rectangle{ sw - ew - 14, y + h/2 - 15, ew, 30 }
	exporting := intrinsics.atomic_load(&export_run)
	rl.DrawRectangleRounded(er, 0.5, 8, exporting ? PANEL2 : (hovered(er) ? ACCENT : ACCENT_D))
	if exporting {
		txt_c(rl.TextFormat("%d%%", i32(export_pct*100)), er.x + er.width/2, er.y + 7, FS_MD, ACCENT)
	} else {
		txt_c("Exportar", er.x + er.width/2, er.y + 7, FS_MD, rl.WHITE)
		if clicked(er) do open_export_modal()
	}
}

// ---------- sub-barra ----------
draw_subbar :: proc(y, media_w, h: f32) {
	rl.DrawRectangleRec({0, y, media_w, h}, PANEL)
	rl.DrawRectangle(0, i32(y + h) - 1, i32(media_w), 1, LINE)
	pill :: proc(label: cstring, x, y, h: f32) -> f32 {
		w := txt_w(label, FS_MD) + 40
		r := rl.Rectangle{ x, y + 5, w, h - 10 }
		rl.DrawRectangleRounded(r, 0.35, 6, hovered(r) ? HOVER : PANEL2)
		txt(label, x + 12, y + h/2 - 8, FS_MD, TEXT)
		cx := x + w - 16
		rl.DrawTriangle({cx, y + h/2 - 2}, {cx + 8, y + h/2 - 2}, {cx + 4, y + h/2 + 3}, MUTED)
		return w
	}
	x: f32 = 10
	imp_w := pill("Importar", x, y, h)
	if clicked({ x, y + 5, imp_w, h - 10 }) do want_import = true
	x += imp_w + 8
	// botão "Texto" (＋): adiciona um título/legenda na timeline
	tb := rl.Rectangle{ x, y + 5, txt_w("+ Texto", FS_MD) + 24, h - 10 }
	rl.DrawRectangleRounded(tb, 0.35, 6, hovered(tb) ? HOVER : PANEL2)
	txt("+ Texto", x + 12, y + h/2 - 8, FS_MD, TEXT)
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
	if tf_search.len == 0 && !search_focus do txt("Pesquisar mídia", fld.x + 4, sr.y + sr.height/2 - 8, FS_MD, MUTED)
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
// triângulo sem depender da ordem dos vértices (o raylib descarta a face de trás)
draw_tri2 :: proc(a, b, c: rl.Vector2, col: rl.Color) { rl.DrawTriangle(a, b, c, col); rl.DrawTriangle(a, c, b, col) }

draw_trans_icon :: proc(box: rl.Rectangle, kind: int) {
	ix := box.x + 20; iy := box.y + 12; iw := box.width - 40; ih := box.height - 30
	a_col := rl.Color{ 70, 110, 140, 255 }
	b_col := rl.Color{ 150, 90, 120, 255 }
	switch kind {
	case 0: // dissolver: dois blocos sobrepostos + laço âmbar
		rl.DrawRectangleRec({ ix, iy, iw*0.62, ih }, a_col)
		rl.DrawRectangleRec({ ix + iw*0.38, iy, iw*0.62, ih }, rl.Color{ 150, 90, 120, 210 })
		rl.DrawLineEx({ ix+iw*0.38, iy }, { ix+iw, iy+ih }, 1.5, rl.Color{ 245, 212, 120, 230 })
		rl.DrawLineEx({ ix+iw*0.38, iy+ih }, { ix+iw, iy }, 1.5, rl.Color{ 245, 212, 120, 230 })
	case 1: // fade de entrada: preto -> claro
		for k in 0 ..< 8 { a := u8(f32(k)/7*255); rl.DrawRectangleRec({ ix + f32(k)*(iw/8), iy, iw/8+1, ih }, rl.Color{ 205, 208, 216, a }) }
	case 2: // fade de saída: claro -> preto
		for k in 0 ..< 8 { a := u8((1-f32(k)/7)*255); rl.DrawRectangleRec({ ix + f32(k)*(iw/8), iy, iw/8+1, ih }, rl.Color{ 205, 208, 216, a }) }
	case 3: // tinta/fumaça (Filmora): manchas pretas orgânicas
		rl.DrawRectangleRec({ ix, iy, iw, ih }, rl.Color{ 228, 230, 235, 255 })
		ink := rl.Color{ 18, 18, 20, 255 }
		rl.DrawCircleV({ ix + iw*0.36, iy + ih*0.58 }, ih*0.36, ink)
		rl.DrawCircleV({ ix + iw*0.58, iy + ih*0.34 }, ih*0.30, ink)
		rl.DrawCircleV({ ix + iw*0.22, iy + ih*0.30 }, ih*0.16, ink)
		rl.DrawCircleV({ ix + iw*0.74, iy + ih*0.72 }, ih*0.20, ink)
		rl.DrawCircleV({ ix + iw*0.48, iy + ih*0.12 }, ih*0.10, ink)
	case 4: // wipe esquerda
		rl.DrawRectangleRec({ ix, iy, iw, ih }, a_col)
		rl.DrawRectangleRec({ ix, iy, iw*0.55, ih }, b_col)
		rl.DrawLineEx({ ix + iw*0.55, iy }, { ix + iw*0.55, iy + ih }, 2, rl.WHITE)
	case 5: // wipe direita
		rl.DrawRectangleRec({ ix, iy, iw, ih }, a_col)
		rl.DrawRectangleRec({ ix + iw*0.45, iy, iw*0.55, ih }, b_col)
		rl.DrawLineEx({ ix + iw*0.45, iy }, { ix + iw*0.45, iy + ih }, 2, rl.WHITE)
	case 6: // wipe cima
		rl.DrawRectangleRec({ ix, iy, iw, ih }, a_col)
		rl.DrawRectangleRec({ ix, iy, iw, ih*0.55 }, b_col)
		rl.DrawLineEx({ ix, iy + ih*0.55 }, { ix + iw, iy + ih*0.55 }, 2, rl.WHITE)
	case 7: // wipe baixo
		rl.DrawRectangleRec({ ix, iy, iw, ih }, a_col)
		rl.DrawRectangleRec({ ix, iy + ih*0.45, iw, ih*0.55 }, b_col)
		rl.DrawLineEx({ ix, iy + ih*0.45 }, { ix + iw, iy + ih*0.45 }, 2, rl.WHITE)
	case 8: // deslizar esquerda
		rl.DrawRectangleRec({ ix, iy, iw*0.48, ih }, a_col)
		rl.DrawRectangleRec({ ix + iw*0.52, iy, iw*0.48, ih }, b_col)
		rl.DrawLineEx({ ix + iw*0.28, iy + ih/2 }, { ix + iw*0.08, iy + ih/2 }, 2, rl.WHITE)
		rl.DrawTriangle({ ix + iw*0.08, iy + ih/2 }, { ix + iw*0.16, iy + ih*0.32 }, { ix + iw*0.16, iy + ih*0.68 }, rl.WHITE)
	case 9: // deslizar direita
		rl.DrawRectangleRec({ ix, iy, iw*0.48, ih }, a_col)
		rl.DrawRectangleRec({ ix + iw*0.52, iy, iw*0.48, ih }, b_col)
		rl.DrawLineEx({ ix + iw*0.72, iy + ih/2 }, { ix + iw*0.92, iy + ih/2 }, 2, rl.WHITE)
		rl.DrawTriangle({ ix + iw*0.92, iy + ih/2 }, { ix + iw*0.84, iy + ih*0.32 }, { ix + iw*0.84, iy + ih*0.68 }, rl.WHITE)
	case 10: // deslizar cima
		rl.DrawRectangleRec({ ix, iy, iw, ih*0.46 }, b_col)
		rl.DrawRectangleRec({ ix, iy + ih*0.54, iw, ih*0.46 }, a_col)
		rl.DrawTriangle({ ix + iw/2, iy + 4 }, { ix + iw*0.38, iy + ih*0.28 }, { ix + iw*0.62, iy + ih*0.28 }, rl.WHITE)
	case 11: // deslizar baixo
		rl.DrawRectangleRec({ ix, iy, iw, ih*0.46 }, a_col)
		rl.DrawRectangleRec({ ix, iy + ih*0.54, iw, ih*0.46 }, b_col)
		rl.DrawTriangle({ ix + iw/2, iy + ih - 4 }, { ix + iw*0.38, iy + ih*0.72 }, { ix + iw*0.62, iy + ih*0.72 }, rl.WHITE)
	case 12: // íris
		rl.DrawRectangleRec({ ix, iy, iw, ih }, a_col)
		rl.DrawCircleV({ ix + iw/2, iy + ih/2 }, min(iw, ih)*0.28, b_col)
		rl.DrawCircleLines(i32(ix + iw/2), i32(iy + ih/2), min(iw, ih)*0.38, rl.WHITE)
	case 13: // flash
		rl.DrawRectangleRec({ ix, iy, iw, ih }, rl.Color{ 245, 248, 255, 255 })
		cx := ix + iw/2; cy := iy + ih/2
		rl.DrawLineEx({ cx, iy + 4 }, { cx, iy + ih - 4 }, 2, rl.Color{ 250, 200, 60, 255 })
		rl.DrawLineEx({ ix + 6, cy }, { ix + iw - 6, cy }, 2, rl.Color{ 250, 200, 60, 255 })
		rl.DrawLineEx({ ix + 10, iy + 8 }, { ix + iw - 10, iy + ih - 8 }, 1.6, rl.Color{ 250, 180, 40, 255 })
		rl.DrawLineEx({ ix + iw - 10, iy + 8 }, { ix + 10, iy + ih - 8 }, 1.6, rl.Color{ 250, 180, 40, 255 })
	case 14: // zoom
		rl.DrawRectangleRec({ ix, iy, iw, ih }, a_col)
		rl.DrawRectangleLinesEx({ ix + iw*0.22, iy + ih*0.18, iw*0.56, ih*0.64 }, 1.5, rl.WHITE)
		rl.DrawRectangleRec({ ix + iw*0.32, iy + ih*0.30, iw*0.36, ih*0.40 }, b_col)
	case 15: // giro
		rl.DrawRectangleRec({ ix, iy, iw, ih }, a_col)
		rl.DrawCircleLines(i32(ix + iw/2), i32(iy + ih/2), min(iw, ih)*0.28, rl.WHITE)
		rl.DrawTriangle({ ix + iw*0.72, iy + ih*0.22 }, { ix + iw*0.86, iy + ih*0.18 }, { ix + iw*0.80, iy + ih*0.36 }, rl.WHITE)
	case 16: // whip
		rl.DrawRectangleRec({ ix, iy, iw, ih }, a_col)
		rl.DrawRectangleRec({ ix + iw*0.35, iy, iw*0.65, ih }, rl.Color{ 150, 90, 120, 180 })
		rl.DrawLineEx({ ix + 8, iy + ih/2 }, { ix + iw - 8, iy + ih/2 }, 2.2, rl.WHITE)
		rl.DrawTriangle({ ix + iw - 8, iy + ih/2 }, { ix + iw - 18, iy + ih*0.28 }, { ix + iw - 18, iy + ih*0.72 }, rl.WHITE)
	case 17: // glitch
		rl.DrawRectangleRec({ ix, iy, iw, ih }, a_col)
		rl.DrawRectangleRec({ ix + 4, iy + 6, iw*0.7, ih*0.35 }, rl.Color{ 255, 70, 90, 200 })
		rl.DrawRectangleRec({ ix + iw*0.28, iy + ih*0.42, iw*0.7, ih*0.4 }, rl.Color{ 70, 220, 255, 200 })
	case 18: // flip
		rl.DrawRectangleRec({ ix, iy, iw*0.42, ih }, a_col)
		rl.DrawRectangleRec({ ix + iw*0.58, iy, iw*0.42, ih }, b_col)
		rl.DrawLineEx({ ix + iw/2, iy + 4 }, { ix + iw/2, iy + ih - 4 }, 1.6, rl.WHITE)
	case 19: // zoom out
		rl.DrawRectangleRec({ ix, iy, iw, ih }, b_col)
		rl.DrawRectangleLinesEx({ ix + iw*0.08, iy + ih*0.08, iw*0.84, ih*0.84 }, 1.5, rl.WHITE)
		rl.DrawRectangleRec({ ix + iw*0.28, iy + ih*0.26, iw*0.44, ih*0.48 }, a_col)
	case 20: // relógio
		rl.DrawRectangleRec({ ix, iy, iw, ih }, a_col)
		cx := ix + iw/2; cy := iy + ih/2; r := min(iw, ih)*0.32
		rl.DrawCircleV({ cx, cy }, r, b_col)
		rl.DrawCircleLines(i32(cx), i32(cy), r, rl.WHITE)
		rl.DrawLineEx({ cx, cy }, { cx, cy - r + 2 }, 2, rl.WHITE)
		rl.DrawLineEx({ cx, cy }, { cx + r*0.55, cy + r*0.2 }, 2, rl.WHITE)
	case 21: // tremor
		rl.DrawRectangleRec({ ix - 2, iy + 4, iw, ih }, a_col)
		rl.DrawRectangleRec({ ix + 4, iy - 2, iw, ih }, b_col)
		rl.DrawRectangleLinesEx({ ix, iy, iw, ih }, 1.4, rl.WHITE)
	case 22: // zoom punch: quadros concêntricos + riscos de velocidade
		rl.DrawRectangleRec({ ix, iy, iw, ih }, a_col)
		cx := ix + iw/2; cy := iy + ih/2
		for k in 0 ..< 3 {
			f := 0.25 + f32(k)*0.25
			rl.DrawRectangleLinesEx({ cx - iw*f/2, cy - ih*f/2, iw*f, ih*f }, 1.2, rl.Color{ 255, 255, 255, u8(230 - k*60) })
		}
		rl.DrawLineEx({ ix + 3, iy + 3 }, { ix + iw*0.22, iy + ih*0.22 }, 1.4, rl.WHITE)
		rl.DrawLineEx({ ix + iw - 3, iy + ih - 3 }, { ix + iw*0.78, iy + ih*0.78 }, 1.4, rl.WHITE)
	case 23: // esticar: bloco largo com setas p/ os lados
		rl.DrawRectangleRec({ ix - 6, iy + ih*0.2, iw + 12, ih*0.6 }, b_col)
		cy := iy + ih/2
		draw_tri2({ ix - 4, cy }, { ix + 6, cy + 6 }, { ix + 6, cy - 6 }, rl.WHITE)
		draw_tri2({ ix + iw + 4, cy }, { ix + iw - 6, cy - 6 }, { ix + iw - 6, cy + 6 }, rl.WHITE)
		rl.DrawLineEx({ ix + 6, cy }, { ix + iw - 6, cy }, 1.6, rl.WHITE)
	case 24: // pixelizar: grade de blocos em dois tons
		n := 6; m := 4
		for yy in 0 ..< m do for xx in 0 ..< n {
			c := (xx + yy) % 2 == 0 ? a_col : b_col
			if (xx*7 + yy*3) % 5 == 0 do c = rl.Color{ 200, 205, 215, 255 }
			rl.DrawRectangleRec({ ix + f32(xx)*iw/f32(n), iy + f32(yy)*ih/f32(m), iw/f32(n) + 1, ih/f32(m) + 1 }, c)
		}
	case 25: // negativo: metade com as cores invertidas
		rl.DrawRectangleRec({ ix, iy, iw/2, ih }, a_col)
		rl.DrawRectangleRec({ ix + iw/2, iy, iw/2, ih }, rl.Color{ 255 - a_col.r, 255 - a_col.g, 255 - a_col.b, 255 })
		rl.DrawCircleV({ ix + iw/2, iy + ih/2 }, min(iw, ih)*0.26, rl.WHITE)
		rl.DrawCircleSector({ ix + iw/2, iy + ih/2 }, min(iw, ih)*0.26, 90, 270, 16, rl.Color{ 20, 20, 24, 255 })
	case 26: // estrobo: faixas alternando A/B/branco
		cols := [3]rl.Color{ a_col, rl.Color{ 245, 248, 255, 255 }, b_col }
		for k in 0 ..< 6 do rl.DrawRectangleRec({ ix + f32(k)*iw/6, iy, iw/6 + 1, ih }, cols[k % 3])
	case 27: // desfoque: dois blocos com bordas esfumadas
		for k in 0 ..< 5 {
			g := f32(k)*2
			al := u8(70 + k*35)
			rl.DrawRectangleRec({ ix + g, iy + g, iw*0.6 - 2*g, ih - 2*g }, rl.Color{ a_col.r, a_col.g, a_col.b, al })
			rl.DrawRectangleRec({ ix + iw*0.4 + g, iy + g, iw*0.6 - 2*g, ih - 2*g }, rl.Color{ b_col.r, b_col.g, b_col.b, al })
		}
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
fx_lib := [?]FxLibItem{
	{ "Distorção", FX_DISTORT },
	{ "Separação RGB", FX_RGB },
	{ "Pixelizar", FX_PIXEL },
	{ "Desfoque", FX_BLUR },
	{ "Desfoque local", FX_BLUR_PART },
	{ "Granulação", FX_GRAIN },
	{ "Espelhar", FX_MIRROR },
	{ "Nitidez", FX_SHARP },
	{ "Holofote", FX_SPOT },
	{ "Tremor", FX_SHAKE },
	{ "Posterizar", FX_POSTER },
	{ "Inverter", FX_INVERT },
	{ "Onda", FX_WAVE },
	{ "Matiz", FX_HUE },
	{ "Brilho", FX_GLOW },
	{ "Caleidoscópio", FX_KALEIDO },
	{ "Varredura", FX_SCAN },
	{ "Contorno", FX_EDGE },
	{ "Chroma key", FX_CHROMA },
}

fxlib_name :: proc(kind: int) -> cstring {
	switch kind {
	case FX_DISTORT: return "Distorção"
	case FX_RGB:     return "Separação RGB"
	case FX_PIXEL:   return "Pixelizar"
	case FX_BLUR:      return "Desfoque"
	case FX_BLUR_PART: return "Desfoque local"
	case FX_GRAIN:     return "Granulação"
	case FX_MIRROR:  return "Espelhar"
	case FX_SHARP:   return "Nitidez"
	case FX_SPOT:    return "Holofote"
	case FX_SHAKE:   return "Tremor"
	case FX_POSTER:  return "Posterizar"
	case FX_INVERT:  return "Inverter"
	case FX_WAVE:    return "Onda"
	case FX_HUE:     return "Matiz"
	case FX_GLOW:    return "Brilho"
	case FX_KALEIDO: return "Caleidoscópio"
	case FX_SCAN:    return "Varredura"
	case FX_EDGE:    return "Contorno"
	case FX_CHROMA:  return "Chroma key"
	}
	return "Efeito"
}
// valores padrão de um clipe de efeito recém-criado, por tipo
fx_defaults :: proc(f: ^FxSeg) {
	switch f.kind {
	case FX_DISTORT: f.amount = 0.5; f.radius = BULGE_R_DEF; f.cx = 0; f.cy = 0; f.wobble = 0; f.speed = WOBBLE_HZ_DEF
	case FX_RGB:     f.amount = 0.5; f.angle = 0.25 // "cima-baixo" (vertical) por padrão
	case FX_PIXEL:   f.amount = 0.45
	case FX_BLUR:      f.amount = 0.45
	case FX_BLUR_PART: f.amount = 0.55; f.radius = 0.22; f.cx = 0; f.cy = 0; f.angle = 0 // quadrado
	case FX_GRAIN:     f.amount = 0.40
	case FX_MIRROR:  f.amount = 1; f.angle = 0 // horizontal
	case FX_SHARP:   f.amount = 0.45
	case FX_SPOT:    f.amount = 0.70; f.radius = 0.45; f.cx = 0; f.cy = 0
	case FX_SHAKE:   f.amount = 0.40; f.speed = 8
	case FX_POSTER:  f.amount = 0.50
	case FX_INVERT:  f.amount = 1
	case FX_WAVE:    f.amount = 0.45; f.speed = 2
	case FX_HUE:     f.amount = 0.25
	case FX_GLOW:    f.amount = 0.50
	case FX_KALEIDO: f.amount = 0.40
	case FX_SCAN:    f.amount = 0.45
	case FX_EDGE:    f.amount = 0.55
	case FX_CHROMA:  f.amount = 0.55; f.radius = 0.25; f.angle = 0 // verde; amount=similaridade, radius=suavidade
	}
}
add_fxseg :: proc(kind: int, start: f32, track := 0) -> int {
	if nfx >= MAX_FX { set_toast("Máximo de efeitos na timeline"); return -1 }
	f := FxSeg{ kind = kind, track = clamp(track, 0, g_nv - 1), start = max(0, start), dur = 3 }
	fx_defaults(&f)
	fx_clear_marks()
	fxsegs[nfx] = f; fx_sel = nfx; fx_marked[nfx] = true; nfx += 1
	return nfx - 1
}
remove_fxseg :: proc(i: int) {
	if i < 0 || i >= nfx do return
	for k in i ..< nfx-1 { fxsegs[k] = fxsegs[k+1]; fx_marked[k] = fx_marked[k+1] }
	nfx -= 1
	fx_marked[nfx] = false
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
	case FX_PIXEL: // grade
		gx := box.x + 28; gy := box.y + 16
		for row in 0 ..< 3 do for col in 0 ..< 3 {
			rl.DrawRectangleRec({ gx + f32(col)*16, gy + f32(row)*12, 14, 10 }, rl.Color{ 180, 210, 255, u8(160 + (row+col)*20) })
		}
	case FX_BLUR:
		cx := box.x + box.width/2; cy := box.y + box.height/2
		rl.DrawCircleV({ cx, cy }, 18, rl.Color{ 160, 190, 230, 70 })
		rl.DrawCircleV({ cx, cy }, 11, rl.Color{ 180, 210, 245, 110 })
		rl.DrawCircleV({ cx, cy }, 5, rl.Color{ 230, 240, 255, 220 })
	case FX_BLUR_PART:
		cx := box.x + box.width/2; cy := box.y + box.height/2
		rl.DrawRectangleRec({ box.x + 16, box.y + 10, box.width - 32, box.height - 20 }, rl.Color{ 70, 90, 120, 255 })
		rl.DrawRectangleRec({ cx - 16, cy - 12, 32, 24 }, rl.Color{ 160, 190, 230, 90 })
		rl.DrawRectangleLinesEx({ cx - 16, cy - 12, 32, 24 }, 1.5, rl.Color{ 230, 240, 255, 220 })
	case FX_GRAIN:
		cx := box.x + 32; cy := box.y + 18
		for i in 0 ..< 18 {
			px := cx + f32((i * 17) % 40); py := cy + f32((i * 11) % 28)
			rl.DrawCircleV({ px, py }, 1.4, rl.Color{ 230, 230, 220, 220 })
		}
	case FX_MIRROR:
		mx := box.x + box.width/2; my := box.y + 16
		rl.DrawTriangle({ mx, my }, { mx - 22, my + 34 }, { mx, my + 34 }, rl.Color{ 140, 200, 255, 220 })
		rl.DrawTriangle({ mx, my }, { mx + 22, my + 34 }, { mx, my + 34 }, rl.Color{ 90, 150, 220, 180 })
		rl.DrawLineEx({ mx, my }, { mx, my + 34 }, 1.5, rl.WHITE)
	case FX_SHARP:
		cx := box.x + box.width/2; cy := box.y + box.height/2
		rl.DrawTriangle({ cx, cy - 16 }, { cx - 14, cy + 12 }, { cx + 14, cy + 12 }, rl.Color{ 250, 230, 140, 230 })
		rl.DrawTriangle({ cx, cy - 8 }, { cx - 7, cy + 6 }, { cx + 7, cy + 6 }, rl.Color{ 40, 46, 60, 255 })
	case FX_SPOT:
		rl.DrawRectangleRec({ box.x + 18, box.y + 12, box.width - 36, box.height - 24 }, rl.Color{ 18, 18, 24, 255 })
		rl.DrawCircleV({ box.x + box.width/2, box.y + box.height/2 }, 12, rl.Color{ 255, 240, 180, 230 })
		rl.DrawCircleV({ box.x + box.width/2, box.y + box.height/2 }, 5, rl.Color{ 255, 255, 245, 255 })
	case FX_SHAKE:
		cx := box.x + box.width/2 - 12; cy := box.y + box.height/2 - 10
		rl.DrawRectangleRec({ cx - 6, cy, 24, 18 }, rl.Color{ 120, 160, 220, 160 })
		rl.DrawRectangleRec({ cx + 4, cy - 3, 24, 18 }, rl.Color{ 230, 210, 120, 200 })
	case FX_POSTER:
		px := box.x + 26; py := box.y + 16
		cols := []rl.Color{ { 70, 90, 200, 255 }, { 80, 180, 120, 255 }, { 230, 190, 70, 255 }, { 220, 90, 80, 255 } }
		for c, i in cols do rl.DrawRectangleRec({ px, py + f32(i)*8, 52, 8 }, c)
	case FX_INVERT:
		rl.DrawRectangleRec({ box.x + 22, box.y + 14, 30, 38 }, rl.Color{ 230, 230, 240, 255 })
		rl.DrawRectangleRec({ box.x + 52, box.y + 14, 30, 38 }, rl.Color{ 28, 30, 40, 255 })
	case FX_WAVE:
		cx := box.x + 22; cy := box.y + box.height/2
		for i in 0 ..< 8 {
			x0 := cx + f32(i)*8; x1 := x0 + 8
			y0 := cy + math.sin(f32(i)*0.9)*12; y1 := cy + math.sin(f32(i+1)*0.9)*12
			rl.DrawLineEx({ x0, y0 }, { x1, y1 }, 2.2, rl.Color{ 120, 210, 255, 230 })
		}
	case FX_HUE:
		cx := box.x + box.width/2; cy := box.y + box.height/2
		cols := []rl.Color{ { 230, 70, 80, 255 }, { 230, 200, 60, 255 }, { 70, 200, 90, 255 }, { 70, 140, 230, 255 } }
		for i in 0 ..< 4 {
			a := f32(i) * math.PI/2
			rl.DrawCircleV({ cx + math.cos(a)*10, cy + math.sin(a)*10 }, 8, cols[i])
		}
	case FX_GLOW:
		cx := box.x + box.width/2; cy := box.y + box.height/2
		rl.DrawCircleV({ cx, cy }, 20, rl.Color{ 255, 220, 80, 50 })
		rl.DrawCircleV({ cx, cy }, 12, rl.Color{ 255, 240, 140, 120 })
		rl.DrawCircleV({ cx, cy }, 5, rl.Color{ 255, 255, 230, 255 })
	case FX_KALEIDO:
		cx := box.x + box.width/2; cy := box.y + box.height/2
		rl.DrawTriangle({ cx, cy }, { cx - 16, cy - 18 }, { cx + 16, cy - 18 }, rl.Color{ 180, 120, 230, 220 })
		rl.DrawTriangle({ cx, cy }, { cx - 16, cy + 18 }, { cx + 16, cy + 18 }, rl.Color{ 120, 90, 200, 180 })
		rl.DrawTriangle({ cx, cy }, { cx - 22, cy - 8 }, { cx - 22, cy + 8 }, rl.Color{ 210, 160, 255, 160 })
		rl.DrawTriangle({ cx, cy }, { cx + 22, cy - 8 }, { cx + 22, cy + 8 }, rl.Color{ 210, 160, 255, 160 })
	case FX_SCAN:
		px := box.x + 24; py := box.y + 16
		for i in 0 ..< 8 {
			rl.DrawRectangleRec({ px, py + f32(i)*4.5, 56, 2.2 }, rl.Color{ 80, 220, 120, u8(140 + (i%2)*80) })
		}
	case FX_EDGE:
		cx := box.x + box.width/2; cy := box.y + box.height/2
		rl.DrawRectangleLinesEx({ cx - 16, cy - 12, 32, 24 }, 2, rl.Color{ 240, 240, 250, 230 })
		rl.DrawCircleLines(i32(cx), i32(cy), 6, rl.Color{ 240, 240, 250, 230 })
	case FX_CHROMA: // silhueta sobre fundo verde (sugere o key)
		rl.DrawRectangleRec({ box.x + 14, box.y + 10, box.width - 28, box.height - 20 }, rl.Color{ 20, 180, 70, 255 })
		cx := box.x + box.width/2; cy := box.y + box.height/2 + 4
		rl.DrawCircleV({ cx, cy - 10 }, 7, rl.Color{ 40, 44, 56, 255 })
		rl.DrawRectangleRec({ cx - 9, cy - 2, 18, 16 }, rl.Color{ 40, 44, 56, 255 })
	}
}

// aba "Efeitos": BIBLIOTECA de efeitos VISUAIS (arraste p/ a timeline). Se um clipe de efeito
// estiver selecionado (duplo-clique na faixa), mostra as CONFIGURAÇÕES dele no lugar.
draw_effects_panel :: proc(r: rl.Rectangle) {
	if fx_sel >= 0 && fx_sel < nfx { draw_fx_settings(r); return }
	txt("Efeitos", r.x + 14, r.y + 12, FS_LG, TEXT)
	txt("Arraste um efeito para a faixa de efeitos (topo da timeline).", r.x + 14, r.y + 36, FS_XS, MUTED)
	txt("Duplo-clique no clipe de efeito p/ ajustar.", r.x + 14, r.y + 52, FS_XS, MUTED)

	tw: f32 = 104; th: f32 = 66; gap: f32 = 12; lblh: f32 = 22
	cols := max(1, int((r.width - gap) / (tw + gap)))
	rows := (len(fx_lib) + cols - 1) / cols
	content_h := f32(rows) * (th + gap + lblh)
	area := rl.Rectangle{ r.x, r.y + 76, r.width, max(40, r.height - 76) }
	maxs := max(f32(0), content_h - area.height + 8)
	if hovered(area) && st.drag == .None {
		fx_panel_scroll = clamp(fx_panel_scroll - rl.GetMouseWheelMove() * 40, 0, maxs)
	} else {
		fx_panel_scroll = clamp(fx_panel_scroll, 0, maxs)
	}
	x0 := r.x + gap; y0 := area.y - fx_panel_scroll
	rl.BeginScissorMode(i32(area.x), i32(area.y), i32(area.width), i32(area.height))
	for it, idx in fx_lib {
		col := idx % cols; row := idx / cols
		box := rl.Rectangle{ x0 + f32(col)*(tw+gap), y0 + f32(row)*(th+gap+lblh), tw, th }
		if box.y + box.height < area.y || box.y > area.y + area.height { continue }
		hot := hovered(box)
		draw_fx_icon(box, it.kind)
		rl.DrawRectangleRoundedLinesEx(box, 0.1, 6, hot ? 2 : 1, hot ? ACCENT : LINE)
		txt_c(it.name, box.x + box.width/2, box.y + box.height + 4, FS_SM, TEXT)
		if rl.IsMouseButtonPressed(.LEFT) && hovered(box) && modal == .None { st.drag = .FxLib; fxlib_drag = it.kind }
	}
	rl.EndScissorMode()
}

// CONFIGURAÇÕES do clipe de efeito selecionado (aberto no duplo-clique). Sliders próprios por
// tipo + "‹ Efeitos" (voltar à biblioteca) e "Redefinir".
draw_fx_settings :: proc(r: rl.Rectangle) {
	f := &fxsegs[fx_sel]
	x := r.x + 14; cw := r.width - 28; vx := r.x + r.width - 14 - 50
	if ui_btn({ x, r.y + 8, 90, 22 }, "‹ Efeitos", false) { fx_sel = -1; return }
	txt(fxlib_name(f.kind), x, r.y + 40, FS_LG, TEXT)
	txt(rl.TextFormat("Duração: %.1fs", f64(f.dur)), vx - 20, r.y + 44, FS_XS, MUTED)
	y := r.y + 68
	switch f.kind {
	case FX_DISTORT:
		if f.radius <= 0 do f.radius = BULGE_R_DEF
		txt("Intensidade", x, y, FS_MD, TEXT); txt(rl.TextFormat("%d%%", i32(f.amount*100)), vx, y, FS_MD, ACCENT); y += 20
		ui_slider(40, { x, y, cw, 16 }, &f.amount, -1, 1); y += 28
		txt("Raio", x, y, FS_MD, TEXT); txt(rl.TextFormat("%d%%", i32(f.radius*100)), vx, y, FS_MD, ACCENT); y += 20
		ui_slider(41, { x, y, cw, 16 }, &f.radius, 0.1, 1); y += 28
		txt("Centro X", x, y, FS_MD, TEXT); txt(rl.TextFormat("%d", i32(f.cx*100)), vx, y, FS_MD, ACCENT); y += 20
		ui_slider(42, { x, y, cw, 16 }, &f.cx, -0.5, 0.5); y += 28
		txt("Centro Y", x, y, FS_MD, TEXT); txt(rl.TextFormat("%d", i32(f.cy*100)), vx, y, FS_MD, ACCENT); y += 20
		ui_slider(43, { x, y, cw, 16 }, &f.cy, -0.5, 0.5); y += 28
		txt("Tremor", x, y, FS_MD, TEXT); txt(rl.TextFormat("%d%%", i32(f.wobble*100)), vx, y, FS_MD, ACCENT); y += 20
		if ui_slider(44, { x, y, cw, 16 }, &f.wobble, 0, 1) { if f.wobble < 0.03 do f.wobble = 0 }
		y += 28
		if f.wobble > 0.001 {
			if f.speed <= 0 do f.speed = WOBBLE_HZ_DEF
			txt("Velocidade", x, y, FS_MD, TEXT); txt(rl.TextFormat("%.1f Hz", f64(f.speed)), vx-8, y, FS_MD, ACCENT); y += 20
			ui_slider(45, { x, y, cw, 16 }, &f.speed, 0.3, 8); y += 28
		}
	case FX_RGB:
		txt("Intensidade", x, y, FS_MD, TEXT); txt(rl.TextFormat("%d%%", i32(f.amount*100)), vx, y, FS_MD, ACCENT); y += 20
		ui_slider(40, { x, y, cw, 16 }, &f.amount, 0, 1); y += 28
		txt("Direção", x, y, FS_MD, TEXT); txt(rl.TextFormat("%d°", i32(f.angle*360)), vx, y, FS_MD, ACCENT); y += 20
		ui_slider(41, { x, y, cw, 16 }, &f.angle, 0, 1); y += 28
		txt("0° = horizontal · 90° = cima-baixo.", x, y, FS_XS, MUTED); y += 22
	case FX_PIXEL, FX_BLUR, FX_GRAIN, FX_SHARP, FX_POSTER:
		txt("Intensidade", x, y, FS_MD, TEXT); txt(rl.TextFormat("%d%%", i32(f.amount*100)), vx, y, FS_MD, ACCENT); y += 20
		ui_slider(40, { x, y, cw, 16 }, &f.amount, 0, 1); y += 28
	case FX_MIRROR:
		txt("Direção", x, y, FS_MD, MUTED); y += 22
		horz := f.angle < 0.5
		if ui_btn({ x, y, (cw-8)/2, 26 }, "Horizontal", horz) do f.angle = 0
		if ui_btn({ x + (cw-8)/2 + 8, y, (cw-8)/2, 26 }, "Vertical", !horz) do f.angle = 0.5
		y += 36
		txt("Dobra a metade do quadro sobre a outra.", x, y, FS_XS, MUTED); y += 22
	case FX_BLUR_PART:
		if f.radius <= 0 do f.radius = 0.22
		txt("Intensidade", x, y, FS_MD, TEXT); txt(rl.TextFormat("%d%%", i32(f.amount*100)), vx, y, FS_MD, ACCENT); y += 20
		ui_slider(40, { x, y, cw, 16 }, &f.amount, 0, 1); y += 28
		txt("Tamanho", x, y, FS_MD, TEXT); txt(rl.TextFormat("%d%%", i32(f.radius*100)), vx, y, FS_MD, ACCENT); y += 20
		ui_slider(41, { x, y, cw, 16 }, &f.radius, 0.08, 0.7); y += 28
		txt("Centro X", x, y, FS_MD, TEXT); txt(rl.TextFormat("%d", i32(f.cx*100)), vx, y, FS_MD, ACCENT); y += 20
		ui_slider(42, { x, y, cw, 16 }, &f.cx, -0.5, 0.5); y += 28
		txt("Centro Y", x, y, FS_MD, TEXT); txt(rl.TextFormat("%d", i32(f.cy*100)), vx, y, FS_MD, ACCENT); y += 20
		ui_slider(43, { x, y, cw, 16 }, &f.cy, -0.5, 0.5); y += 28
		txt("Forma", x, y, FS_MD, MUTED); y += 22
		quad := f.angle < 0.5
		if ui_btn({ x, y, (cw-8)/2, 26 }, "Quadrado", quad) do f.angle = 0
		if ui_btn({ x + (cw-8)/2 + 8, y, (cw-8)/2, 26 }, "Círculo", !quad) do f.angle = 0.5
		y += 36
		txt("Arraste o alvo no preview para mover a região.", x, y, FS_XS, MUTED); y += 22
	case FX_SPOT:
		if f.radius <= 0 do f.radius = 0.45
		txt("Intensidade", x, y, FS_MD, TEXT); txt(rl.TextFormat("%d%%", i32(f.amount*100)), vx, y, FS_MD, ACCENT); y += 20
		ui_slider(40, { x, y, cw, 16 }, &f.amount, 0, 1); y += 28
		txt("Raio", x, y, FS_MD, TEXT); txt(rl.TextFormat("%d%%", i32(f.radius*100)), vx, y, FS_MD, ACCENT); y += 20
		ui_slider(41, { x, y, cw, 16 }, &f.radius, 0.1, 1); y += 28
		txt("Centro X", x, y, FS_MD, TEXT); txt(rl.TextFormat("%d", i32(f.cx*100)), vx, y, FS_MD, ACCENT); y += 20
		ui_slider(42, { x, y, cw, 16 }, &f.cx, -0.5, 0.5); y += 28
		txt("Centro Y", x, y, FS_MD, TEXT); txt(rl.TextFormat("%d", i32(f.cy*100)), vx, y, FS_MD, ACCENT); y += 20
		ui_slider(43, { x, y, cw, 16 }, &f.cy, -0.5, 0.5); y += 28
		txt("Arraste o alvo no preview para mover o centro.", x, y, FS_XS, MUTED); y += 22
	case FX_SHAKE:
		txt("Intensidade", x, y, FS_MD, TEXT); txt(rl.TextFormat("%d%%", i32(f.amount*100)), vx, y, FS_MD, ACCENT); y += 20
		ui_slider(40, { x, y, cw, 16 }, &f.amount, 0, 1); y += 28
		if f.speed <= 0 do f.speed = 8
		txt("Velocidade", x, y, FS_MD, TEXT); txt(rl.TextFormat("%.1f Hz", f64(f.speed)), vx-8, y, FS_MD, ACCENT); y += 20
		ui_slider(41, { x, y, cw, 16 }, &f.speed, 1, 16); y += 28
	case FX_WAVE:
		txt("Intensidade", x, y, FS_MD, TEXT); txt(rl.TextFormat("%d%%", i32(f.amount*100)), vx, y, FS_MD, ACCENT); y += 20
		ui_slider(40, { x, y, cw, 16 }, &f.amount, 0, 1); y += 28
		if f.speed <= 0 do f.speed = 2
		txt("Velocidade", x, y, FS_MD, TEXT); txt(rl.TextFormat("%.1f Hz", f64(f.speed)), vx-8, y, FS_MD, ACCENT); y += 20
		ui_slider(41, { x, y, cw, 16 }, &f.speed, 0.3, 8); y += 28
	case FX_HUE:
		txt("Matiz", x, y, FS_MD, TEXT); txt(rl.TextFormat("%d°", i32(f.amount*360)), vx, y, FS_MD, ACCENT); y += 20
		ui_slider(40, { x, y, cw, 16 }, &f.amount, 0, 1); y += 28
		txt("Gira as cores do quadro (0–360°).", x, y, FS_XS, MUTED); y += 22
	case FX_INVERT, FX_GLOW, FX_KALEIDO, FX_SCAN, FX_EDGE:
		txt("Intensidade", x, y, FS_MD, TEXT); txt(rl.TextFormat("%d%%", i32(f.amount*100)), vx, y, FS_MD, ACCENT); y += 20
		ui_slider(40, { x, y, cw, 16 }, &f.amount, 0, 1); y += 28
	case FX_CHROMA:
		if f.radius <= 0 do f.radius = 0.25
		txt("Cor-chave", x, y, FS_MD, MUTED); y += 22
		green := f.angle < 0.5
		if ui_btn({ x, y, (cw-8)/2, 26 }, "Verde", green) do f.angle = 0
		if ui_btn({ x + (cw-8)/2 + 8, y, (cw-8)/2, 26 }, "Azul", !green) do f.angle = 0.5
		y += 36
		txt("Similaridade", x, y, FS_MD, TEXT); txt(rl.TextFormat("%d%%", i32(f.amount*100)), vx, y, FS_MD, ACCENT); y += 20
		ui_slider(40, { x, y, cw, 16 }, &f.amount, 0.05, 1); y += 28
		txt("Suavidade", x, y, FS_MD, TEXT); txt(rl.TextFormat("%d%%", i32(f.radius*100)), vx, y, FS_MD, ACCENT); y += 20
		ui_slider(41, { x, y, cw, 16 }, &f.radius, 0, 1); y += 28
		txt("V1 = fundo · V2 = green screen · solte o Chroma key numa", x, y, FS_XS, MUTED); y += 16
		txt("trilha ACIMA do green screen (não pode cobrir o clipe).", x, y, FS_XS, MUTED); y += 22
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
	txt("Cor", r.x + 14, r.y + 12, FS_LG, TEXT)
	valid := selected >= 0 && selected < nsegs && seg_ready(selected) && !seg_audio_like(selected) && !seg_src(selected).is_text
	if !valid {
		txt("Selecione um clipe de vídeo na timeline", r.x + 14, r.y + 40, FS_SM, MUTED)
		txt("para ajustar a cor.", r.x + 14, r.y + 56, FS_SM, MUTED)
		return
	}
	sg := &segs[selected]
	x := r.x + 14; cw := r.width - 28; vx := r.x + r.width - 14 - 50
	y := r.y + 44

	txt("Visual", x, y, FS_MD, MUTED); y += 22
	lk := int(sg.fx_look + 0.5)
	presets := []struct{ name: cstring, v: int }{ {"Normal",0}, {"P&B",1}, {"Sépia",2}, {"Inverter",3} }
	bw := (cw - 3*6) / 4
	for p, k in presets {
		bx := x + f32(k)*(bw+6)
		if ui_btn({ bx, y, bw, 24 }, p.name, lk == p.v) do sg.fx_look = f32(p.v)
	}
	y += 34
	txt("Ajustes", x, y, FS_MD, MUTED); y += 22
	txt("Brilho", x, y, FS_MD, TEXT); txt(rl.TextFormat("%d", i32(sg.fx_bright*100)), vx, y, FS_MD, ACCENT); y += 20
	if ui_slider(30, { x, y, cw, 16 }, &sg.fx_bright, -1, 1) { if abs(sg.fx_bright) < 0.04 do sg.fx_bright = 0 }
	y += 26
	txt("Contraste", x, y, FS_MD, TEXT); txt(rl.TextFormat("%d%%", i32((1+sg.fx_contrast)*100)), vx, y, FS_MD, ACCENT); y += 20
	if ui_slider(31, { x, y, cw, 16 }, &sg.fx_contrast, -1, 1) { if abs(sg.fx_contrast) < 0.04 do sg.fx_contrast = 0 }
	y += 26
	txt("Saturação", x, y, FS_MD, TEXT); txt(rl.TextFormat("%d%%", i32((1+sg.fx_satur)*100)), vx, y, FS_MD, ACCENT); y += 20
	if ui_slider(32, { x, y, cw, 16 }, &sg.fx_satur, -1, 1) { if abs(sg.fx_satur) < 0.04 do sg.fx_satur = 0 }
	y += 26
	txt("Temperatura", x, y, FS_MD, TEXT); txt(rl.TextFormat("%d", i32(sg.fx_temp*100)), vx, y, FS_MD, ACCENT); y += 20
	if ui_slider(34, { x, y, cw, 16 }, &sg.fx_temp, -1, 1) { if abs(sg.fx_temp) < 0.04 do sg.fx_temp = 0 }
	y += 26
	txt("Vinheta", x, y, FS_MD, TEXT); txt(rl.TextFormat("%d%%", i32(sg.fx_vignette*100)), vx, y, FS_MD, ACCENT); y += 20
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
	txt("Transições", r.x + 14, r.y + 12, FS_LG, TEXT)
	txt("Arraste para o corte entre dois clipes na mesma trilha.",
		r.x + 14, r.y + 36, FS_SM, MUTED)
	items := []struct{ name: cstring, kind: int }{
		{"Dissolver", 0}, {"Fade de entrada", 1}, {"Fade de saída", 2}, {"Dissolve orgânico", 3},
		{"Wipe esquerda", 4}, {"Wipe direita", 5}, {"Wipe cima", 6}, {"Wipe baixo", 7},
		{"Deslizar esquerda", 8}, {"Deslizar direita", 9}, {"Deslizar cima", 10}, {"Deslizar baixo", 11},
		{"Íris", 12}, {"Flash", 13}, {"Zoom", 14},
		{"Giro", 15}, {"Whip", 16}, {"Glitch", 17}, {"Flip", 18},
		{"Zoom out", 19}, {"Relógio", 20}, {"Tremor", 21},
		{"Zoom punch", 22}, {"Esticar", 23}, {"Pixelizar", 24}, {"Negativo", 25},
		{"Estrobo", 26}, {"Desfoque", 27},
	}
	tw: f32 = 118; th: f32 = 64; gap: f32 = 10; lblh: f32 = 22
	cols := max(1, int((r.width - gap) / (tw + gap)))
	rows := (len(items) + cols - 1) / cols
	content_h := f32(rows) * (th + gap + lblh)
	area := rl.Rectangle{ r.x, r.y + 56, r.width, max(40, r.height - 56 - 32) }
	maxs := max(f32(0), content_h - area.height + 8)
	if hovered(area) && st.drag == .None {
		trans_panel_scroll = clamp(trans_panel_scroll - rl.GetMouseWheelMove() * 40, 0, maxs)
	} else {
		trans_panel_scroll = clamp(trans_panel_scroll, 0, maxs)
	}
	x0 := r.x + gap; y0 := area.y - trans_panel_scroll
	rl.BeginScissorMode(i32(area.x), i32(area.y), i32(area.width), i32(area.height))
	for it, idx in items {
		col := idx % cols; row := idx / cols
		box := rl.Rectangle{ x0 + f32(col)*(tw+gap), y0 + f32(row)*(th+gap+lblh), tw, th }
		if box.y + box.height < area.y || box.y > area.y + area.height { continue }
		hot := hovered(box)
		rl.DrawRectangleRounded(box, 0.08, 6, hot ? HOVER : PANEL2)
		rl.DrawRectangleRoundedLinesEx(box, 0.08, 6, 1, hot ? ACCENT : LINE)
		draw_trans_icon(box, it.kind)
		txt_c(it.name, box.x + box.width/2, box.y + box.height + 3, FS_XS, TEXT)
		// arrastar até a timeline (soltar entre os clipes); clique = aplica ao selecionado
		if rl.IsMouseButtonPressed(.LEFT) && hovered(box) && modal == .None {
			st.drag = .Trans; trans_drag = it.kind
		}
	}
	rl.EndScissorMode()
	txt("Ajuste a duração na pastilha do corte (alças).", r.x + 14, r.y + r.height - 26, FS_XS, MUTED)
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
	txt("Tela Dividida", r.x + 14, r.y + 12, FS_LG, TEXT)
	txt("Ponha os clipes em trilhas separadas (V1/V2/V3),", r.x + 14, r.y + 38, FS_SM, MUTED)
	txt("sobrepostos no playhead, e clique um layout.", r.x + 14, r.y + 54, FS_SM, MUTED)
	items := []struct{ name: cstring, kind: int }{ {"2 lado a lado", 0}, {"2 empilhado", 1}, {"3 colunas", 2}, {"PiP (canto)", 3} }
	tw: f32 = 132; th: f32 = 74; gap: f32 = 12
	cols := max(1, int((r.width - gap) / (tw + gap)))
	x0 := r.x + gap; y0 := r.y + 80
	for it, idx in items {
		col := idx % cols; row := idx / cols
		box := rl.Rectangle{ x0 + f32(col)*(tw+gap), y0 + f32(row)*(th+28), tw, th }
		hot := hovered(box)
		rl.DrawRectangleRounded(box, 0.08, 6, hot ? HOVER : PANEL2)
		rl.DrawRectangleRoundedLinesEx(box, 0.08, 6, 1, hot ? ACCENT : LINE)
		draw_split_icon(box, it.kind)
		txt_c(it.name, box.x + box.width/2, box.y + box.height + 4, FS_XS, TEXT)
		if clicked(box) do apply_split(it.kind)
	}
	txt("Ajuste posição/escala de cada clipe na aba \"Vídeo\".", r.x + 14, r.y + r.height - 30, FS_XS, MUTED)
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
		rl.DrawRectangleRounded(box, 0.3, 8, CONTROL)
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
		txt_c("Clique aqui para importar (ou solte vídeos)", cx, cy + 52, FS_MD, hov ? TEXT : MUTED)
			// bin vazio: 1 clique importa — MENOS nas faixas de 24px encostadas nas divisórias
		// (agarre perdido do redimensionar caía aqui e abria o diálogo) e nunca durante arrasto
		mi := rl.GetMousePosition()
		if clicked(r) && src_preview < 0 && !tl_split_drag && !md_split_drag &&
		   mi.y < r.y + r.height - 24 && mi.x < r.x + r.width - 24 {
			want_import = true
		}
		return
	}
	if nmatch == 0 { // há mídia, mas nada casa com a busca
		txt_c(rl.TextFormat("Nenhuma mídia com \"%s\"", cs(string(tf_search.buf[:tf_search.len]))), r.x + r.width/2, r.y + r.height*0.5, FS_MD, MUTED)
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
				rl.DrawRectangleRec(box, TEXTCLIP)
				txt_c(c.is_caps ? "Cc" : "T", tx + tw/2, ty + th/2 - 20, 30, TEXTCLIP_INK)
				prev := c.is_caps ? (len(c.caps) > 0 ? c.caps[0].text : "Legendas") : c.text
				txt_c(elide(prev, FS_SM, tw - 12), tx + tw/2, ty + th - 22, FS_XS, rl.Color{ 170, 160, 190, 235 })
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
			// imagem/texto não têm duração de fonte — o 00:00:05:00 (IMG_DUR) parecia um vídeo
			if !c.is_img && !c.is_text do txt(timecode(c.dur), tx + tw - 62, ty + th - 15, FS_XS, rl.WHITE)
			if c.streaming do txt("streaming", tx + 4, ty + 3, FS_XS, alpha(INFO, 220))
		} else {
			txt_c("importando...", tx + tw/2, ty + th/2 - 6, FS_SM, alpha(WARN, 230))
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
		if c.name_el == nil do c.name_el = strings.clone_to_cstring(string(elide(c.name, FS_XS, tw)))
		txt(c.name_el, tx, ty + th + 3, FS_XS, MUTED)

		// --- badge do canto inferior direito (estilo NLE) ---
		// JÁ na timeline: "✓" fixo (dispensa o rótulo "na timeline", que roubava o canto).
		// Senão, ao passar o mouse: "+" clicável que joga a mídia na timeline sem arrastar.
		badge_r := rl.Rectangle{ box.x + box.width - 22, box.y + box.height - 22, 18, 18 }
		// o "+" está clicável neste frame? (usado p/ o press da miniatura NÃO virar arrasto)
		badge_add := media_ready(i) && !placed && hovered(box)
		if media_ready(i) {
			br := badge_r
			if placed {
				rl.DrawRectangleRounded(br, 0.3, 4, alpha(ACCENT_D, 235))
				// tique: perna curta descendo + perna longa subindo
				rl.DrawLineEx({ br.x + 4, br.y + 9 }, { br.x + 8, br.y + 13 }, 2, rl.WHITE)
				rl.DrawLineEx({ br.x + 8, br.y + 13 }, { br.x + 14, br.y + 5 }, 2, rl.WHITE)
			} else if hovered(box) {
				bhot := hovered(br)
				rl.DrawRectangleRounded(br, 0.3, 4, bhot ? ACCENT : alpha(ACCENT_D, 235))
				rl.DrawRectangleRec({ br.x + 8, br.y + 4, 2, 10 }, rl.WHITE)
				rl.DrawRectangleRec({ br.x + 4, br.y + 8, 10, 2 }, rl.WHITE)
				if clicked(br) { bin_add_to_timeline(i); handled = true; break } // segs mudou: redesenha no próximo frame
			}
		}

		// botão remover (X) no canto — aparece ao passar o mouse sobre a miniatura
		if hovered(box) {
			xr := rl.Rectangle{ box.x + box.width - 20, box.y + 4, 16, 16 }
			rl.DrawRectangleRounded(xr, 0.4, 4, hovered(xr) ? PLAYHEAD : alpha(CONTROL, 225))
			rl.DrawLineEx({ xr.x + 5, xr.y + 5 }, { xr.x + 11, xr.y + 11 }, 1.8, rl.WHITE)
			rl.DrawLineEx({ xr.x + 11, xr.y + 5 }, { xr.x + 5, xr.y + 11 }, 1.8, rl.WHITE)
			if clicked(xr) { remove_media(i); handled = true; break } // slot mudou: redesenha no próximo frame
		}

		// pressionar seleciona o item e inicia o arrasto p/ a timeline; Ctrl/Shift+clique
		// ALTERNA a marcação (seleção múltipla); DUPLO-clique toca a mídia crua no player.
		// (o press no badge "+" não vira seleção/arrasto: o clique é dele)
		if rl.IsMouseButtonPressed(.LEFT) && hovered(box) && !(badge_add && hovered(badge_r)) && intrinsics.atomic_load(&c.probed) {
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
	// (roda também com a prévia de origem aberta: o duplo-clique de importar depende do fluxo
	// da marquee — com o guard `src_preview < 0` aqui, abrir uma prévia MATAVA o "duplo-clique
	// na área vazia importa" até o usuário sair da prévia com Esc/clique na timeline)
	if !bin_marquee && !handled && !tl_split_drag && !md_split_drag && rl.IsMouseButtonPressed(.LEFT) && hovered(r) && st.drag == .None {
		bin_marquee = true
		bin_marquee_start = rl.GetMousePosition()
		bin_marquee_moved = false
		bin_marquee_add = rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL) || rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
		if !bin_marquee_add { bin_sel = -1; selected = -1 }
	}
	// desenhar o retângulo em curso
	if bin_marquee && bin_marquee_moved {
		rl.DrawRectangleRec(mq, alpha(SELECT, 45))
		rl.DrawRectangleLinesEx(mq, 1, alpha(SELECT, 220))
	}
	// soltar: encerra o marquee. Se não moveu (clique seco em área vazia) = desmarca tudo.
	if bin_marquee && rl.IsMouseButtonReleased(.LEFT) {
		was_click := !bin_marquee_moved
		if !bin_marquee_moved && !bin_marquee_add { bin_clear_marks(); bin_sel = -1 }
		bin_marquee = false; bin_marquee_moved = false
		// IMPORTAR clicando na área VAZIA do bin: sem mídia = 1 clique; com mídia = duplo-clique.
		// Anti-acidente (o usuário mirava a DIVISÓRIA, errava, e 2 erros viravam "importar"):
		//  - clique a menos de 24px do rodapé não conta (é agarre perdido da divisória);
		//  - o 2º clique tem de cair no MESMO lugar do 1º (±8px) — duplo-clique real não anda,
		//    tentativas de agarre re-miram e mudam de posição.
		if was_click && !bin_marquee_add && bin_marquee_start.y < r.y + r.height - 24 && bin_marquee_start.x < r.x + r.width - 24 {
			have := 0
			for k in 0 ..< nclips do if !intrinsics.atomic_load(&clips[k].failed) && !clips[k].closed do have += 1
			now := rl.GetTime()
			same_spot := abs(bin_marquee_start.x - bin_empty_click_p.x) < 8 && abs(bin_marquee_start.y - bin_empty_click_p.y) < 8
			if have == 0 { want_import = true }
			else if bin_empty_click_t > 0 && now - bin_empty_click_t < 0.5 && same_spot { want_import = true; bin_empty_click_t = -1 } // 0.5s = duplo-clique padrão do Windows
			else { bin_empty_click_t = now; bin_empty_click_p = bin_marquee_start }
		}
	}

	have_media := false
	for k in 0 ..< nclips do if !intrinsics.atomic_load(&clips[k].failed) && !clips[k].closed { have_media = true; break }
	hint: cstring = bin_marks_count() > 1 ? "arraste p/ a timeline (várias selecionadas)" :
	                (!have_media ? "clique aqui para importar mídia" : "duplo-clique para importar · arraste p/ selecionar")
	txt(hint, r.x + 12, r.y + r.height - 22, FS_SM, MUTED)
}

// ---------- preview + transporte ----------
// slider horizontal simples p/ o inspector. `id` distingue qual está sendo arrastado
// (imediato-mode não tem foco). Retorna true no frame em que o valor muda.
ui_slider :: proc(id: int, r: rl.Rectangle, val: ^f32, lo, hi: f32) -> bool {
	cy := r.y + r.height/2
	// trilho com contraste visível sobre o PANEL; knob com anel escuro p/ destacar do preenchimento
	rl.DrawRectangleRounded({r.x, cy - 2, r.width, 4}, 1, 4, LINE)
	frac := clamp((val^ - lo) / (hi - lo), 0, 1)
	kx := r.x + frac * r.width
	if kx > r.x + 1 do rl.DrawRectangleRounded({r.x, cy - 2, kx - r.x, 4}, 1, 4, ACCENT)
	hot := ui_slider_active == id || hovered(r)
	rl.DrawCircleV({kx, cy}, hot ? 8 : 7, hot ? ACCENT : SUNK)
	rl.DrawCircleV({kx, cy}, hot ? 6 : 5.5, hot ? rl.WHITE : KNOB)
	if rl.IsMouseButtonPressed(.LEFT) && hovered(r) && (modal == .None || g_modal_draw) do ui_slider_active = id
	if ui_slider_active == id {
		// !Down (não só Released): se o slider sumir no frame do soltar (fade que
		// zera, troca de aba) o Released se perde e o id ficava preso pra sempre.
		if !rl.IsMouseButtonDown(.LEFT) { ui_slider_active = -1 }
		else {
			nf := clamp((rl.GetMousePosition().x - r.x) / r.width, 0, 1)
			val^ = lo + nf * (hi - lo)
			return true
		}
	}
	return false
}

// texto com dígitos de largura fixa (tabular): timecode não muda de largura a cada quadro.
// draw=false só mede. Retorna a largura.
txt_tab :: proc(s: string, x, y, size: f32, col: rl.Color, draw := true) -> f32 {
	dw := txt_w("0", size)
	cx := x
	buf: [2]u8
	for ch in transmute([]u8)s {
		buf[0] = ch
		c := cstring(&buf[0])
		cw := txt_w(c, size)
		w := (ch >= '0' && ch <= '9') ? dw : cw
		if draw do txt(c, cx + (w - cw)/2, y, size, col)
		cx += w + 0.5 * g_us // mesmo espaçamento do DrawTextEx
	}
	return cx - x
}

// botão de ícone do transporte (32x32 centrado em cx,cy): fundo no hover + dica acima.
// Retorna a cor do ícone e se foi clicado; o ícone é desenhado pelo chamador. São os
// controles principais do player: ficam CLAROS em repouso (não apagados como os da barra).
transport_btn :: proc(cx, cy: f32, tip: cstring) -> (rl.Color, bool) {
	r := rl.Rectangle{ cx - 16, cy - 16, 32, 32 }
	hot := hovered(r)
	if hot {
		rl.DrawRectangleRounded(r, 0.3, 6, HOVER)
		tw := txt_w(tip, FS_SM) + 14
		tr := rl.Rectangle{ cx - tw/2, cy - 48, tw, 22 }
		rl.DrawRectangleRounded(tr, 0.3, 6, TOOLTIP)
		txt_c(tip, cx, tr.y + 4, FS_SM, TEXT)
	}
	return hot ? rl.WHITE : TEXT, clicked(r)
}

// fundo dos ícones do cluster direito do transporte (mesmo padrão do transport_btn)
icon_hover_bg :: proc(r: rl.Rectangle, on := false) {
	if hovered(r) || on do rl.DrawRectangleRounded(r, 0.28, 6, HOVER)
}

// pausa e posiciona (timeline ou prévia de origem), como as setas/Home/End do teclado
transport_seek :: proc(t: f32) {
	st.playing = false
	if src_preview >= 0 {
		if src_preview >= nclips do return
		src_t = clamp(t, 0, clips[src_preview].dur)
		src_acquire()
		clip_frame(&clips[src_preview], src_t)
	} else do seek_global(t)
}

// slider VERTICAL (topo = hi, base = lo). Mesmo id/estado do ui_slider (ui_slider_active).
ui_vslider :: proc(id: int, r: rl.Rectangle, val: ^f32, lo, hi: f32) -> bool {
	cx := r.x + r.width/2
	rl.DrawRectangleRounded({cx - 2, r.y, 4, r.height}, 1, 4, TRACK_BG)
	frac := clamp((val^ - lo) / (hi - lo), 0, 1)
	ky := r.y + (1 - frac) * r.height // topo = cheio
	rl.DrawRectangleRounded({cx - 2, ky, 4, (r.y + r.height) - ky}, 1, 4, ACCENT) // preenche do knob p/ baixo
	hot := ui_slider_active == id || hovered(r)
	rl.DrawCircleV({cx, ky}, hot ? 7 : 6, hot ? rl.WHITE : KNOB)
	if rl.IsMouseButtonPressed(.LEFT) && hovered(r) && (modal == .None || g_modal_draw) do ui_slider_active = id
	if ui_slider_active == id {
		if !rl.IsMouseButtonDown(.LEFT) { ui_slider_active = -1 }
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
	txt_c(label, r.x + r.width/2, r.y + r.height/2 - 8, FS_MD, active ? rl.WHITE : TEXT)
	return clicked(r)
}

// controle segmentado: trilho rebaixado, opção ativa elevada (abas do inspetor, opções do
// modal de exportar). Devolve o índice clicado que NÃO era o ativo; -1 = nada mudou.
ui_segmented :: proc(r: rl.Rectangle, labels: []cstring, active: int) -> int {
	rl.DrawRectangleRounded(r, 0.3, 6, SUNK)
	w := (r.width - 6) / f32(len(labels))
	hit := -1
	for label, i in labels {
		b := rl.Rectangle{ r.x + 3 + f32(i)*w, r.y + 3, w, r.height - 6 }
		on := i == active
		hot := hovered(b)
		if on do rl.DrawRectangleRounded(b, 0.3, 6, CONTROL)
		else if hot do rl.DrawRectangleRounded(b, 0.3, 6, alpha(CONTROL, 120))
		txt_c(label, b.x + w/2, b.y + b.height/2 - 8, FS_MD, on || hot ? TEXT : MUTED)
		if clicked(b) && !on do hit = i
	}
	return hit
}

// interruptor liga/desliga (só desenha; o clique é do chamador, que costuma usar a linha
// inteira com o rótulo). ok=false → apagado, sem estado ligado.
ui_switch :: proc(r: rl.Rectangle, on, hot, ok: bool) {
	lit := on && ok
	track := lit ? (hot ? ACCENT : ACCENT_D) : (hot && ok ? HOVER : CONTROL)
	rl.DrawRectangleRounded(r, 1, 12, track)
	kx := lit ? r.x + r.width - r.height/2 : r.x + r.height/2
	rl.DrawCircleV({ kx, r.y + r.height/2 }, r.height/2 - 3, ok ? KNOB : DISABLED)
}

// botão em "pílula" (cantos totalmente arredondados) — estilo do rodapé do painel de efeito.
// filled=true → preenchido com ACCENT, texto branco (OK); filled=false → só contorno ACCENT,
// interior translúcido no hover, texto ACCENT (Redefinir). Igual à barra REDEFINIR/OK de um NLE.
ui_pill :: proc(r: rl.Rectangle, label: cstring, filled: bool) -> bool {
	hot := hovered(r)
	if filled {
		rl.DrawRectangleRounded(r, 1, 8, hot ? ACCENT : ACCENT_D)
		txt_c(label, r.x + r.width/2, r.y + r.height/2 - 8, FS_MD, rl.WHITE)
	} else {
		if hot do rl.DrawRectangleRounded(r, 1, 8, fa(ACCENT, 0.15))
		rl.DrawRectangleRoundedLinesEx(r, 1, 8, 1.5, hot ? ACCENT : ACCENT_D)
		txt_c(label, r.x + r.width/2, r.y + r.height/2 - 8, FS_MD, hot ? ACCENT : ACCENT_D)
	}
	return clicked(r)
}

// botão do overlay de exportação (o clique é tratado no update, não aqui — só desenha
// com destaque no hover). `col` = cor de destaque (ACCENT p/ pausar, vermelho p/ cancelar).
draw_overlay_btn :: proc(r: rl.Rectangle, label: cstring, col: rl.Color) {
	hot := hovered(r)
	rl.DrawRectangleRounded(r, 0.25, 6, hot ? col : CONTROL)
	rl.DrawRectangleRoundedLinesEx(r, 0.25, 6, 1, col)
	txt_c(label, r.x + r.width/2, r.y + r.height/2 - 8, FS_MD, hot ? INK : col)
}

TEXT_COLORS := []rl.Color{ {255,255,255,255}, {20,20,24,255}, {245,205,90,255}, {230,80,72,255}, {90,200,120,255}, {80,150,235,255}, {40,200,182,255} }

// --- campo de texto reutilizável: cursor + seleção (índices em BYTES no UTF-8) ---
tf_prefix_w  :: proc(t: ^TField, n: int) -> f32 { return n <= 0 ? 0 : txt_w(cs(string(t.buf[:n])), FS_MD) } // largura de buf[:n]
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
	clip := rl.Rectangle{ r.x + 2, r.y, r.width - 4, r.height }
	if insp_content do clip = rl.GetCollisionRec(clip, insp_view)
	rl.BeginScissorMode(i32(clip.x), i32(clip.y), i32(max(f32(0), clip.width)), i32(max(f32(0), clip.height)))
	if focused^ && t.sel != t.caret {
		xa := tx0 + tf_prefix_w(t, tf_lo(t)); xb := tx0 + tf_prefix_w(t, tf_hi(t))
		rl.DrawRectangleRec({ xa, r.y + 5, xb - xa, r.height - 10 }, rl.Color{ 58, 108, 170, 150 })
	}
	txt(cs(string(t.buf[:t.len])), tx0, r.y + 7, FS_MD, TEXT)
	if focused^ && t.sel == t.caret && (int(rl.GetTime()*2)) % 2 == 0 {
		rl.DrawRectangleRec({ tx0 + tf_prefix_w(t, t.caret), r.y + 6, 1.5, 18 }, TEXT)
	}
	rl.EndScissorMode()
	// raylib não empilha scissors: restaura o recorte externo do inspetor.
	if insp_content do rl.BeginScissorMode(i32(insp_view.x), i32(insp_view.y), i32(insp_view.width), i32(insp_view.height))
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
	txt("Conteúdo", x, y, FS_MD, TEXT); y += 20
	fr := rl.Rectangle{ x, y, cw - 2*pad, 30 }
	rl.DrawRectangleRounded(fr, 0.2, 4, PANEL2)
	if !txt_edit do tf_set(&tf_text, c.text) // fora de edição: espelha o conteúdo atual do clipe
	if tf_field(&tf_text, fr, &txt_edit, true) do set_text_clip(c, string(tf_text.buf[:tf_text.len]))
	rl.DrawRectangleRoundedLinesEx(fr, 0.2, 4, 1, txt_edit ? ACCENT : LINE)
	if txt_edit && rl.IsKeyPressed(.ENTER) do txt_edit = false
	y += 42
	// --- fonte (seletor ◀ nome ▶) ---
	if len(text_fonts) > 1 {
		txt("Fonte", x, y, FS_MD, TEXT); y += 20
		fbx := rl.Rectangle{ x, y, cw - 2*pad, 28 }
		rl.DrawRectangleRounded(fbx, 0.2, 4, PANEL2)
		rl.DrawRectangleRoundedLinesEx(fbx, 0.2, 4, 1, LINE)
		// só CLAMPA o índice salvo quando a carga em thread terminou — antes disso a fonte
		// do projeto pode só não ter chegado ainda (clampar cedo resetaria a escolha).
		if text_fonts_settled() && (c.text_font < 0 || c.text_font >= len(text_fonts)) do c.text_font = 0
		di := c.text_font; if di < 0 || di >= len(text_fonts) do di = 0 // exibição segura durante a carga
		la := rl.Rectangle{ fbx.x, fbx.y, 28, 28 }; ra := rl.Rectangle{ fbx.x + fbx.width - 28, fbx.y, 28, 28 }
		txt_c("<", la.x + 14, la.y + 6, FS_LG, hovered(la) ? TEXT : MUTED)
		txt_c(">", ra.x + 14, ra.y + 6, FS_LG, hovered(ra) ? TEXT : MUTED)
		txt_c(text_fonts[di].name, fbx.x + fbx.width/2, fbx.y + 6, FS_MD, TEXT)
		n := len(text_fonts)
		if clicked(la) { c.text_font = (di - 1 + n) % n; dirty = true }
		if clicked(ra) || clicked({ fbx.x + 28, fbx.y, fbx.width - 56, 28 }) { c.text_font = (di + 1) % n; dirty = true }
		y += 36
	}
	// --- tamanho ---
	txt("Tamanho", x, y, FS_MD, TEXT); txt(rl.TextFormat("%d%%", i32(c.text_size*100 + 0.5)), vx, y, FS_MD, ACCENT); y += 20
	if ui_slider(11, { x, y, cw - 2*pad, 16 }, &c.text_size, 0.03, 0.4) do dirty = true
	y += 30
	// --- cor (swatches) ---
	txt("Cor", x, y, FS_MD, TEXT); y += 20
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
	txt("Opacidade", x, y, FS_MD, TEXT); txt(rl.TextFormat("%d%%", i32(sg.opacity*100 + 0.5)), vx, y, FS_MD, ACCENT); y += 20
	ui_slider(12, { x, y, cw - 2*pad, 16 }, &sg.opacity, 0, 1)
	y += 26
	txt("Arraste no preview para mover.", x, y, FS_XS, MUTED)
}

// inspector da faixa de legendas: estilo + botão para editar fala a fala.
draw_caps_inspector :: proc(c: ^Clip, sg: ^Seg, card: rl.Rectangle, x, pad, cw: f32) {
	y := card.y + 32
	if sg.opacity <= 0 do sg.opacity = 1
	if c.text_size <= 0 do c.text_size = 0.05
	vx := card.x + cw - pad - 46
	txt(rl.TextFormat("%d fala(s) transcritas", i32(len(c.caps))), x, y, FS_MD, ACCENT); y += 22
	if ui_btn({ x, y, cw - 2*pad, 28 }, "Editar falas", true) do open_caps_editor()
	y += 36
	txt("Estilo", x, y, FS_MD, TEXT); y += 18
	presets := [4]CapPreset{ .YouTube, .CapCut, .Marker, .Shadow }
	pw := (cw - 2*pad - 18) / 4
	for p, pi in presets {
		r := rl.Rectangle{ x + f32(pi)*(pw + 6), y, pw, 26 }
		on := c.cap_preset == p
		rl.DrawRectangleRounded(r, 0.25, 4, on ? ACCENT_D : (hovered(r) ? HOVER : PANEL2))
		txt_c(CAP_PRESET_NAME[p], r.x + r.width/2, r.y + 6, FS_XS, on ? rl.WHITE : TEXT)
		if clicked(r) do cap_apply_preset(c, p)
	}
	y += 32
	chk := rl.Rectangle{ x, y, 16, 16 }
	if clicked({ x, y, cw - 2*pad, 18 }) { c.cap_upper = !c.cap_upper; dirty = true }
	rl.DrawRectangleRoundedLinesEx(chk, 0.2, 4, 1.5, c.cap_upper ? ACCENT : MUTED)
	if c.cap_upper do rl.DrawRectangleRec({ chk.x + 3, chk.y + 3, 10, 10 }, ACCENT)
	txt("MAIÚSCULAS", x + 22, y + 1, FS_SM, TEXT)
	y += 26
	txt("Tamanho, cor e posição valem para todas.", x, y, FS_XS, MUTED); y += 20
	if len(text_fonts) > 1 {
		txt("Fonte", x, y, FS_MD, TEXT); y += 20
		fbx := rl.Rectangle{ x, y, cw - 2*pad, 28 }
		rl.DrawRectangleRounded(fbx, 0.2, 4, PANEL2)
		rl.DrawRectangleRoundedLinesEx(fbx, 0.2, 4, 1, LINE)
		if text_fonts_settled() && (c.text_font < 0 || c.text_font >= len(text_fonts)) do c.text_font = 0
		di := c.text_font; if di < 0 || di >= len(text_fonts) do di = 0
		la := rl.Rectangle{ fbx.x, fbx.y, 28, 28 }; ra := rl.Rectangle{ fbx.x + fbx.width - 28, fbx.y, 28, 28 }
		txt_c("<", la.x + 14, la.y + 6, FS_LG, hovered(la) ? TEXT : MUTED)
		txt_c(">", ra.x + 14, ra.y + 6, FS_LG, hovered(ra) ? TEXT : MUTED)
		txt_c(text_fonts[di].name, fbx.x + fbx.width/2, fbx.y + 6, FS_MD, TEXT)
		n := len(text_fonts)
		if clicked(la) { c.text_font = (di - 1 + n) % n; dirty = true }
		if clicked(ra) || clicked({ fbx.x + 28, fbx.y, fbx.width - 56, 28 }) { c.text_font = (di + 1) % n; dirty = true }
		y += 36
	}
	txt("Tamanho", x, y, FS_MD, TEXT); txt(rl.TextFormat("%d%%", i32(c.text_size*100 + 0.5)), vx, y, FS_MD, ACCENT); y += 20
	if ui_slider(11, { x, y, cw - 2*pad, 16 }, &c.text_size, 0.03, 0.4) do dirty = true
	y += 30
	txt("Cor", x, y, FS_MD, TEXT); y += 20
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
	txt("Opacidade", x, y, FS_MD, TEXT); txt(rl.TextFormat("%d%%", i32(sg.opacity*100 + 0.5)), vx, y, FS_MD, ACCENT); y += 20
	ui_slider(12, { x, y, cw - 2*pad, 16 }, &sg.opacity, 0, 1)
	y += 26
	txt("Arraste no preview para mover.", x, y, FS_XS, MUTED)
}

draw_preview :: proc(r: rl.Rectangle) {
	pt := prof_beg(.Preview); defer prof_end(.Preview, pt)
	// Desenha por último para alças e overlays da prévia ficarem atrás do painel.
	defer draw_seg_inspector(g_insp_card)
	transport_h: f32 = 66 // barra de progresso (topo) + linha de botões
	rl.DrawRectangleRec({ r.x, r.y, r.width, r.height - transport_h }, PV_BACK) // sobra do painel: cinza, NÃO entra no export
	video := rl.Rectangle{ r.x, r.y, max(f32(1), r.width - insp_video_inset), r.height - transport_h }

	// CANVAS ajustado à área de preview: proporção do projeto — ou, na prévia de origem, a da fonte
	par := preview_ar()
	scaleC := min(video.width/par, video.height)
	fw := par*scaleC; fh := scaleC
	fx := video.x + (video.width-fw)/2; fy := video.y + (video.height-fh)/2
	g_frame = { fx, fy, fw, fh }
	rl.DrawRectangleRec(g_frame, rl.BLACK) // o quadro de saída é preto de VERDADE (é o que sai no arquivo)

	// recorta ao CANVAS: o que passa da moldura de saída não aparece (vídeo ampliado/movido)
	rl.BeginScissorMode(i32(fx), i32(fy), i32(fw), i32(fh))
	if src_preview >= 0 { // PRÉVIA de origem: fonte na PRÓPRIA proporção, preenchendo o canvas
		c := &clips[src_preview]
		ensure_tex(c)
		if c.tex_ok do rl.DrawTexturePro(c.tex, dec_content_rect(c), g_frame, {0,0}, 0, rl.WHITE)
		txt(rl.TextFormat("Prévia: %s  (clique na timeline p/ sair)", cs(c.name)), video.x + 10, video.y + 8, FS_SM, alpha(WARN, 235))
		txt(rl.TextFormat("Prévia: %s  (clique na timeline p/ sair)", cs(c.name)), video.x + 10, video.y + 8, FS_SM, alpha(WARN, 235))
	} else if crop_mode && modal == .None && selected >= 0 && selected < nsegs && seg_ready(selected) && !seg_audio_like(selected) && !seg_src(selected).is_text {
		// MODO RECORTE: mostra o quadro completo do clipe + moldura de recorte com alças.
		// `modal == .None` porque o editor lê rl.IsMouseButtonPressed CRU (não passa pelo
		// `clicked`, que respeita o modal): com um modal por cima, um clique nele arrastava
		// a moldura escondida atrás — e o draw_preview roda ANTES do draw_modal.
		draw_crop_editor(fx, fy, fw, fh)
	} else {
		// COMPOSITING das trilhas de vídeo com transform (mesma função da tela cheia)
		if !composite_video(fx, fy, fw, fh, true) {
			txt_c("Preview", video.x + video.width/2, video.y + video.height/2 - 10, FS_LG, LINE)
		}
	}
	// guias de alinhamento (centro/bordas do canvas) ao mover um clipe no preview
	if st.drag == .PreviewMove {
		gc := alpha(ACCENT, 235)
		if g_pv_x >= 0 do rl.DrawLineEx({ g_pv_x, g_frame.y }, { g_pv_x, g_frame.y + g_frame.height }, 1.2, gc)
		if g_ph_y >= 0 do rl.DrawLineEx({ g_frame.x, g_ph_y }, { g_frame.x + g_frame.width, g_ph_y }, 1.2, gc)
	}
	rl.EndScissorMode()
	rl.DrawRectangleLinesEx(g_frame, 1, PV_EDGE) // moldura do canvas de saída

	// barra do modo recorte: instrução + botão Concluir (sai do modo)
	if crop_mode {
		if selected < 0 || selected >= nsegs || !seg_ready(selected) || seg_audio_like(selected) || seg_src(selected).is_text {
			set_crop_mode(false) // seleção inválida p/ recorte
		} else {
			// faixa escura no topo p/ leitura + instrução
			rl.DrawRectangleRec({ video.x, video.y, video.width, 44 }, alpha(SCRIM, 140))
			txt("Recorte: arraste as alças para escolher a área", video.x + 14, video.y + 15, FS_MD, alpha(WARN, 245))
			// botão CONCLUIR bem visível (preenchido, com um check desenhado)
			bw2: f32 = 176; bh2: f32 = 30
			cb := rl.Rectangle{ video.x + video.width - bw2 - 12, video.y + 7, bw2, bh2 }
			rl.DrawRectangleRounded(cb, 0.35, 6, hovered(cb) ? ACCENT : ACCENT_D)
			rl.DrawRectangleRoundedLinesEx(cb, 0.35, 6, 1.5, ACCENT)
			ck := rl.Vector2{ cb.x + 24, cb.y + bh2/2 } // marca de "check"
			rl.DrawLineEx({ck.x-7, ck.y+1}, {ck.x-2, ck.y+6}, 2.6, rl.WHITE)
			rl.DrawLineEx({ck.x-2, ck.y+6}, {ck.x+8, ck.y-6}, 2.6, rl.WHITE)
			txt("Concluir recorte", cb.x + 42, cb.y + bh2/2 - 8, FS_MD, rl.WHITE)
			if clicked(cb) do set_crop_mode(false)
		}
	}

	tb := rl.Rectangle{ r.x, r.y + r.height - transport_h, r.width, transport_h }
	rl.DrawRectangleRec(tb, PANEL)
	rl.DrawRectangle(i32(tb.x), i32(tb.y), i32(tb.width), 1, LINE)

	// --- barra de progresso do player (posição atual + duração total, arrastável) ---
	total := src_preview >= 0 ? (src_preview < nclips ? clips[src_preview].dur : 0) : timeline_dur()
	pos   := src_preview >= 0 ? src_t : st.playhead
	pbar := rl.Rectangle{ tb.x + 16, tb.y + 12, tb.width - 32, 5 }
	player_seek_bar = pbar
	pbar_hit := rl.Rectangle{ pbar.x - 4, tb.y + 5, pbar.width + 8, 18 }
	frac := total > 0 ? clamp(pos / total, 0, 1) : 0
	rl.DrawRectangleRounded(pbar, 1, 4, TRACK_BG)
	rl.DrawRectangleRounded({ pbar.x, pbar.y, frac * pbar.width, pbar.height }, 1, 4, ACCENT)
	pkx := pbar.x + frac * pbar.width
	rl.DrawCircleV({ pkx, pbar.y + pbar.height/2 }, (player_seek_drag || hovered(pbar_hit)) ? 7 : 5, rl.WHITE)
	// `clicked` (e não IsMouseButtonPressed cru) porque ele respeita o modal: o draw_preview
	// roda ANTES do draw_modal, então um clique destinado ao modal chegava aqui primeiro. O
	// cartão do "Cortar e Ampliar" cruza esta faixa em qualquer janela abaixo de ~1480px:
	// arrastar a alça de baixo do recorte pausava a reprodução e jogava o playhead para a
	// fração X do mouse na timeline inteira. O overlay de exportação tem a mesma sobreposição.
	if clicked(pbar_hit) && !intrinsics.atomic_load(&export_run) { player_seek_drag = true; seek_was_playing = st.playing; st.playing = false; seek_drag_hush() }
	if rl.IsMouseButtonReleased(.LEFT) && player_seek_drag {
		player_seek_drag = false
		// retoma ANTES do seek: tanto src_acquire quanto seek_global só adquirem o áudio
		// na posição nova se st.playing já for true (senão voltaria mudo por um frame)
		if seek_was_playing { st.playing = true; seek_was_playing = false }
		when DBG_SEEK do dbg_seek_n = 200
		if src_preview >= 0 { src_acquire(); clip_frame(&clips[src_preview], src_t) } else do seek_global(st.playhead)
	}

	// LAYOUT RESPONSIVO da barra: com o player estreito (divisória vertical), timecode + botões
	// centrais + cluster da direita se SOBREPUNHAM (precisam de ~710px). Estreito: timecode só
	// com a posição; apertado: esconde proporção/qualidade (raramente usados — reaparecem ao
	// alargar). O cluster central centra no ESPAÇO LIVRE entre o timecode e a direita, clampado.
	narrow := tb.width < 700
	tight  := tb.width < 560
	// timecode com dígitos de largura fixa (não "dança" durante a reprodução): atual claro, total apagado
	tc_pos := string(timecode(pos))
	tc_tot := narrow ? "" : fmt.tprintf(" / %s", timecode(total))
	tcw := txt_tab(tc_pos, 0, 0, FS_LG, TEXT, false) + txt_tab(tc_tot, 0, 0, FS_LG, MUTED, false)
	// direita: tela cheia + câmera + alto-falante (28px a cada 31) => spr.x = fim‑96; proporção fica 144 antes
	rclust := tb.x + tb.width - 96 - (tight ? 0 : 144)
	cl := tb.x + 16 + tcw + 12
	cy := tb.y + 42 // linha de botões abaixo da barra de progresso
	cx := clamp((cl + rclust) / 2, cl + 102, max(cl + 102, rclust - 104))

	// passo de 1 quadro: mesmo fps das setas do teclado (clipe sob o playhead / clipe da prévia de origem)
	fstep := f32(1) / DEC_FPS
	if src_preview >= 0 && src_preview < nclips do fstep = 1 / cfps_of(&clips[src_preview])
	else if vs := view_seg(); vs >= 0 do fstep = 1 / cfps_of(seg_src(vs))
	{ c, hit := transport_btn(cx - 84, cy, "Início (Home)")
		draw_icon(.SkipBack, cx - 84, cy, 24, c)
		if hit do transport_seek(0)
	}
	{ c, hit := transport_btn(cx - 48, cy, "Voltar 1 quadro")
		draw_icon(.StepBack, cx - 48, cy, 24, c)
		if hit do transport_seek(pos - fstep)
	}
	{ c, hit := transport_btn(cx + 48, cy, "Avançar 1 quadro")
		draw_icon(.StepForward, cx + 48, cy, 24, c)
		if hit do transport_seek(pos + fstep)
	}
	{ c, hit := transport_btn(cx + 84, cy, "Fim (End)")
		draw_icon(.SkipForward, cx + 84, cy, 24, c)
		if hit do transport_seek(total)
	}

	pr := rl.Rectangle{ cx - 19, cy - 19, 38, 38 }
	rl.DrawCircleV({cx, cy}, 19, hovered(pr) ? ACCENT : ACCENT_D)
	if clicked(pr) do toggle_play()
	// play compensa 1px p/ a direita: o centro ótico do triângulo fica à esquerda do geométrico
	if st.playing do draw_icon(.Pause, cx, cy, 22, rl.WHITE)
	else do draw_icon(.Play, cx + 1, cy, 22, rl.WHITE)

	// timecode à esquerda: posição atual (e a duração total quando há espaço)
	tx := tb.x + 16 + txt_tab(tc_pos, tb.x + 16, cy - 8, FS_LG, TEXT)
	txt_tab(tc_tot, tx, cy - 8, FS_LG, MUTED)

	// --- cluster à direita: volume do player | screenshot | tela cheia ---
	// botões 28×28 (mesmo padrão do transporte), centrados a 31px um do outro a partir do canto
	fsr := rl.Rectangle{ tb.x + tb.width - 34, cy - 14, 28, 28 }
	if clicked(fsr) do toggle_fullscreen_preview()
	icon_hover_bg(fsr)
	draw_icon(fullscreen_preview ? .ExitFullscreen : .Fullscreen, fsr.x + 14, cy, 18, icon_col(true, hovered(fsr)))
	shr := rl.Rectangle{ fsr.x - 31, cy - 14, 28, 28 }
	if clicked(shr) do open_shot_modal()
	icon_hover_bg(shr)
	draw_icon(.Camera, shr.x + 14, cy, 18, icon_col(true, hovered(shr)))
	// alto-falante: clique ABRE o slider VERTICAL de volume (popup). Antes era um slider
	// horizontal fixo que confundia com o zoom da timeline.
	spr := rl.Rectangle{ shr.x - 31, cy - 14, 28, 28 }
	if clicked(spr) do vol_popup = !vol_popup
	icon_hover_bg(spr, vol_popup)
	{
		mute := player_vol < 0.01
		draw_icon(mute ? .VolumeMute : .Volume, spr.x + 14, cy, 18, mute ? DANGER : icon_col(true, hovered(spr), vol_popup))
	}
	// qualidade da prévia p/ clipes STREAMING (longos): Baixa=360p (leve) <-> Alta=720p
	// (nítido, ~4x os bytes/frame). Estilo dropdown "Total/1/2/..." de NLEs, aqui binário.
	if !tight {
		qlabel: cstring = stream_hi ? "Alta" : "Baixa"
		qw := txt_w(qlabel, FS_SM) + 22
		qr := rl.Rectangle{ spr.x - 8 - qw, cy - 11, qw, 22 }
		rl.DrawRectangleRounded(qr, 0.35, 6, hovered(qr) ? HOVER : PANEL2)
		rl.DrawRectangleRoundedLinesEx(qr, 0.35, 6, 1, stream_hi ? ACCENT : LINE)
		txt_c(qlabel, qr.x + qr.width/2, qr.y + 4, FS_SM, stream_hi ? ACCENT : TEXT)
		if clicked(qr) { set_stream_quality(!stream_hi); dirty = true } // escolha vai no .ovp
	}
	if vol_popup { // painel com slider VERTICAL acima do alto-falante
		pw := f32(34); ph := f32(108)
		vpr := rl.Rectangle{ spr.x + spr.width/2 - pw/2, cy - 14 - ph, pw, ph } // `vpr`: o `pr` de fora é o botão de play
		rl.DrawRectangleRounded(vpr, 0.2, 8, POPUP)
		rl.DrawRectangleRoundedLinesEx(vpr, 0.2, 8, 1, LINE)
		ui_vslider(10, { vpr.x + pw/2 - 8, vpr.y + 12, 16, ph - 42 }, &player_vol, 0, 1)
		txt_c(rl.TextFormat("%d", i32(player_vol*100 + 0.5)), vpr.x + pw/2, vpr.y + ph - 22, FS_SM, TEXT)
		// clicar fora (sem ser no botão nem arrastando o slider) fecha
		if rl.IsMouseButtonPressed(.LEFT) && !hovered(vpr) && !hovered(spr) && ui_slider_active != 10 do vol_popup = false
	}

	// --- formato do projeto: botão + dropdown rápido de presets ("Personalizar…" abre o modal) ---
	// (recolhido no modo apertado, junto com a qualidade — reaparece ao alargar o player)
	if tight do ar_menu_open = false
	if !tight {
	arb := rl.Rectangle{ spr.x - 144, cy - 11, 64, 22 }
	if clicked(arb) do ar_menu_open = !ar_menu_open
	rl.DrawRectangleRounded(arb, 0.3, 4, (ar_menu_open || hovered(arb)) ? HOVER : PANEL2)
	txt(ar_label(proj_ar), arb.x + 8, arb.y + 4, FS_SM, TEXT)
	draw_tri2({ arb.x + arb.width - 14, arb.y + 9 }, { arb.x + arb.width - 6, arb.y + 9 }, { arb.x + arb.width - 10, arb.y + 14 }, MUTED)
	if ar_menu_open {
		ih := f32(26); mw := f32(130); mh := f32(len(AR_PRESETS) + 1) * ih + 8
		mr := rl.Rectangle{ arb.x, arb.y - mh - 4, mw, mh }
		rl.DrawRectangleRounded(mr, 0.08, 6, POPUP)
		rl.DrawRectangleRoundedLinesEx(mr, 0.08, 6, 1, LINE)
		for p, idx in AR_PRESETS {
			ir := rl.Rectangle{ mr.x + 4, mr.y + 4 + f32(idx)*ih, mw - 8, ih }
			sel := abs(proj_ar - p.ar) < 0.001
			if hovered(ir) do rl.DrawRectangleRounded(ir, 0.3, 4, HOVER)
			if sel do rl.DrawCircleV({ ir.x + ir.width - 14, ir.y + ih/2 }, 3, ACCENT) // marca o ativo
			txt(p.label, ir.x + 12, ir.y + 5, FS_MD, sel ? ACCENT : TEXT)
			if clicked(ir) { set_proj_ar(p.ar); ar_menu_open = false; ar_auto = false } // preset rápido (lado menor = 1080)
		}
		// "Personalizar…" -> abre o modal completo (resolução exata)
		cpr := rl.Rectangle{ mr.x + 4, mr.y + 4 + f32(len(AR_PRESETS))*ih, mw - 8, ih }
		rl.DrawLineEx({ mr.x + 8, cpr.y - 1 }, { mr.x + mw - 8, cpr.y - 1 }, 1, LINE)
		if hovered(cpr) do rl.DrawRectangleRounded(cpr, 0.3, 4, HOVER)
		txt("Personalizar…", cpr.x + 12, cpr.y + 5, FS_MD, TEXT)
		if clicked(cpr) { ar_menu_open = false; open_projset_modal() }
		if rl.IsMouseButtonPressed(.LEFT) && !hovered(mr) && !hovered(arb) do ar_menu_open = false // clique fora fecha
	}
	} // fim do !tight (proporção)


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
		rl.DrawCircleLines(i32(hx), i32(hy), rr, alpha(WARN, 150))
		// alvo (crosshair + círculo)
		near_h := abs(m.x-hx) < 14 && abs(m.y-hy) < 14
		hot := st.drag == .FxCenter || near_h
		col := hot ? ACCENT : alpha(WARN, 235)
		rl.DrawCircleLines(i32(hx), i32(hy), 11, col)
		rl.DrawLineEx({hx-16, hy}, {hx-4, hy}, 2, col); rl.DrawLineEx({hx+4, hy}, {hx+16, hy}, 2, col)
		rl.DrawLineEx({hx, hy-16}, {hx, hy-4}, 2, col); rl.DrawLineEx({hx, hy+4}, {hx, hy+16}, 2, col)
		rl.DrawCircleV({hx, hy}, 3, col)
		if near_h && rl.CheckCollisionPointRec(m, video) && !rl.CheckCollisionPointRec(m, g_insp_card) && st.drag == .None && ui_slider_active == -1 &&
		   rl.IsMouseButtonPressed(.LEFT) && !ctx_open && !ctx_ate {
			st.drag = .FxCenter; drag_clip = selected
		}
		if hot do rl.SetMouseCursor(.RESIZE_ALL)
	}

	// alvo do CENTRO da distorção do CLIPE DE EFEITO selecionado (arrasta no preview p/ mover
	// o centro sem os sliders). Só quando é Distorção e está sob o playhead (efeito visível).
	if !crop_mode && src_preview < 0 && fx_sel >= 0 && fx_sel < nfx && g_frame.width > 0 &&
	   (fxsegs[fx_sel].kind == FX_DISTORT || fxsegs[fx_sel].kind == FX_SPOT || fxsegs[fx_sel].kind == FX_BLUR_PART) && st.playhead >= fxsegs[fx_sel].start && st.playhead < fxsegs[fx_sel].start + fxsegs[fx_sel].dur {
		f := fxsegs[fx_sel]
		m := rl.GetMousePosition()
		ccx := g_frame.x + g_frame.width/2 + f.cx*g_frame.width
		ccy := g_frame.y + g_frame.height/2 + f.cy*g_frame.height
		rr := (f.radius <= 0 ? (f.kind == FX_BLUR_PART ? f32(0.22) : BULGE_R_DEF) : f.radius) * g_frame.height
		// recorta ao quadro do vídeo p/ o anel não vazar pra fora do preview
		rl.BeginScissorMode(i32(g_frame.x), i32(g_frame.y), i32(g_frame.width), i32(g_frame.height))
		ringcol := alpha(WARN, 150)
		if f.kind == FX_BLUR_PART && f.angle < 0.5 {
			rl.DrawRectangleLinesEx({ ccx - rr, ccy - rr, rr*2, rr*2 }, 1.5, ringcol)
		} else {
			// anel LISO desenhado à mão (DrawCircleLines/DrawRing deixavam um "bico"/emenda num ponto)
			N :: 160
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
		col := hot ? ACCENT : alpha(WARN, 235)
		rl.DrawCircleLines(i32(ccx), i32(ccy), 11, col)
		rl.DrawLineEx({ccx-16, ccy}, {ccx-4, ccy}, 2, col); rl.DrawLineEx({ccx+4, ccy}, {ccx+16, ccy}, 2, col)
		rl.DrawLineEx({ccx, ccy-16}, {ccx, ccy-4}, 2, col); rl.DrawLineEx({ccx, ccy+4}, {ccx, ccy+16}, 2, col)
		rl.DrawCircleV({ccx, ccy}, 3, col)
		rl.EndScissorMode()
		if near && rl.CheckCollisionPointRec(m, video) && !rl.CheckCollisionPointRec(m, g_insp_card) && st.drag == .None && ui_slider_active == -1 &&
		   rl.IsMouseButtonPressed(.LEFT) && !ctx_open && !ctx_ate {
			st.drag = .FxCtr
		}
		if hot do rl.SetMouseCursor(.RESIZE_ALL)
	}

	// arrastar o clipe de vídeo SELECIONADO no preview p/ reposicionar (PiP). Só se ele
	// está visível sob o playhead e o clique não é no cartão do inspector. (A alça do efeito
	// tem prioridade: se agarrou o centro acima, st.drag != None e isto não dispara.)
	// O retângulo de hit SEGUE escala/posição — sem recortar ao `video`, um scale>1
	// ou py pra baixo cobre a timeline: o clique no playhead virava PreviewMove
	// (o draw do preview roda ANTES e st.drag != None trava a régua).
	if !crop_mode && src_preview < 0 && selected >= 0 && selected < nsegs && !seg_audio_like(selected) &&
	   seg_on_track_at(segs[selected].track, st.playhead) == selected {
		m := rl.GetMousePosition()
		sg := segs[selected]
		s := sg.scale <= 0 ? 1 : sg.scale
		ccx := g_frame.x + g_frame.width/2 + sg.px*g_frame.width
		ccy := g_frame.y + g_frame.height/2 + sg.py*g_frame.height
		hw := g_frame.width*s/2; hh := g_frame.height*s/2
		inside := abs(m.x-ccx) <= hw && abs(m.y-ccy) <= hh
		if inside && rl.CheckCollisionPointRec(m, video) && !rl.CheckCollisionPointRec(m, g_insp_card) && st.drag == .None && ui_slider_active == -1 &&
		   rl.IsMouseButtonPressed(.LEFT) && !ctx_open && !ctx_ate && !md_split_drag && !tl_split_drag {
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
	return { tl_x(f.start), track_y(f.track) + 4, max(f32(8), f.dur * pps()), th(f.track) - 8 }
}
// clipe de efeito cujo retângulo contém o ponto m; -1 se nenhum. Do topo (último desenhado) p/ baixo.
// O ponto precisa estar DENTRO do viewport rolável: `fx_rect` usa track_y, que com rolagem
// vertical devolve posições fora da vista — sem este recorte uma barra rolada p/ fora ficava
// por cima da régua e das bandas "+ trilha" e engolia o clique (o chamador marca `consumed`).
fx_bar_at :: proc(m: rl.Vector2) -> int {
	if !rl.CheckCollisionPointRec(m, g_vlane) do return -1
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
		mk := fx_marked[i]
		rl.DrawRectangleRounded(bar, 0.12, 5, sel ? rl.Color{ 140, 118, 52, 245 } : rl.Color{ 108, 92, 44, 225 })
		if mk && !sel do rl.DrawRectangleRounded(bar, 0.12, 5, rl.Color{ 240, 214, 120, 50 })
		rl.DrawRectangleRoundedLinesEx(bar, 0.12, 5, (sel || mk) ? 2 : 1, (sel || mk) ? rl.Color{ 240, 214, 120, 255 } : rl.Color{ 175, 155, 88, 210 })
		// faixa âmbar no topo p/ "cara de efeito" (distingue de um clipe de vídeo azul)
		rl.DrawRectangleRec({ bar.x + 2, bar.y + 2, bar.width - 4, 3 }, rl.Color{ 220, 190, 90, 220 })
		has_x := sel && bar.width > 46
		nx := has_x ? bar.x + 20 : bar.x + 8 // nome desloca p/ dar espaço ao × (à ESQUERDA)
		txt(fxlib_name(f.kind), nx, bar.y + 5, FS_XS, rl.Color{ 248, 240, 210, 255 })
		xr := rl.Rectangle{ bar.x + 2, bar.y + 2, 16, 16 } // × à ESQUERDA (não colide com a alça de aparo)
		over_x := has_x && rl.CheckCollisionPointRec(m, xr)
		if has_x {
			txt_c("×", xr.x + xr.width/2, xr.y + 1, FS_LG, rl.Color{ 245, 220, 205, 255 })
			if clicked(xr) { remove_fxseg(i); continue } // não incrementa i (o próximo desceu p/ cá)
		}
		// ALÇA DE APARO na borda direita (redimensionar a duração do efeito)
		grip := rl.Rectangle{ bar.x + bar.width - 8, bar.y, 8, bar.height }
		if sel do rl.DrawRectangleRec({ bar.x + bar.width - 3, bar.y + 3, 2, bar.height - 6 }, rl.Color{ 250, 230, 160, 255 })
		near_grip := rl.CheckCollisionPointRec(m, grip)
		if near_grip do rl.SetMouseCursor(.RESIZE_EW)
		if modal == .None && st.drag == .None && !tl_marquee && !over_x && rl.IsMouseButtonPressed(.LEFT) && rl.CheckCollisionPointRec(m, bar) {
			if track_locked[f.track] {
				set_toast("Trilha bloqueada")
			} else {
				ctrl := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
				shift := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
				selected = -1; sel_trans = -1; bin_sel = -1; seg_clear_marks(); clear_sel_gap()
				st.active_tab = 2 // abre a aba Efeitos p/ mostrar as configurações do efeito
				if (ctrl || shift) && !near_grip {
					fx_marked[i] = !fx_marked[i]
					if fx_marked[i] do fx_sel = i
					else if fx_sel == i {
						fx_sel = -1
						for k in 0 ..< nfx do if fx_marked[k] { fx_sel = k; break }
					}
				} else {
					if near_grip || !fx_marked[i] { fx_clear_marks(); fx_marked[i] = true }
					fx_sel = i
					if near_grip { st.drag = .FxTrim }
					else { st.drag = .FxClip; fx_grab_dt = tl_t(m.x) - f.start }
				}
			}
		}
		i += 1
	}
	// fantasma do efeito arrastado da biblioteca: clipe na trilha de vídeo sob o cursor, no vão livre
	if st.drag == .FxLib && fxlib_drag >= 0 && rl.CheckCollisionPointRec(m, g_vlane) {
		ty := track_at_y(m.y)
		if !is_audio_track(ty) {
			tr := clamp(ty, 0, g_nv - 1)
			gx := tl_x(fx_free_start(tr, -1, max(0, tl_t(m.x - DROP_LEAD)), 3))
			rl.DrawRectangleRounded({ gx, track_y(tr) + 4, 3*pps(), th(tr) - 8 }, 0.12, 5, rl.Color{ 200, 175, 90, 150 })
		}
	}
}

