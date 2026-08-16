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


LANE_X :: 128 // largura do cabeçalho das trilhas


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
			if save_now() do do_pending() // grava AGORA (já tem caminho, ou pede o nome)
			else do pending_action = .None // cancelou o diálogo: aborta a ação
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
		if ui_btn({ cx + 204, cy + ch - 52, 130, 36 }, "Abrir pasta", false) do reveal_in_explorer(done_path)
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
			if export_nvenc_ok {
				if clicked(chk) do export_gpu = !export_gpu
				rl.DrawRectangleRoundedLinesEx(chk, 0.2, 4, 1.5, export_gpu ? ACCENT : MUTED)
				if export_gpu do rl.DrawRectangleRec({ chk.x + 4, chk.y + 4, 10, 10 }, ACCENT)
				txt("Ativar codificação com GPU (NVENC)", px + 26, py + 2, 13, TEXT)
			} else {
				rl.DrawRectangleRoundedLinesEx(chk, 0.2, 4, 1.5, MUTED)
				txt("GPU (NVENC) indisponível — usa CPU", px + 26, py + 2, 13, MUTED)
			}
		} else if export_fmt == .WEBM {
			txt("VP9 codifica por CPU — export mais lento.", px, py + 2, 12, MUTED)
		}
		// botões
		if ui_btn({ cx + cw - 244, cy + ch - 52, 100, 36 }, "Cancelar", false) do modal = .None
		if ui_btn({ cx + cw - 134, cy + ch - 52, 110, 36 }, "Exportar", true) {
			if tf_name.len == 0 do set_toast("Digite um nome")
			else {
				// enfileira: o start real roda no update (fora do BeginDrawing)
				queue_export(fmt.tprintf("%s/%s%s", save_dir, name_str(), export_fmt_ext(export_fmt)), export_gpu)
				modal = .None
			}
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
			lt - live_now(c), lt - c.tex_t,
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

	// rects dos botões do overlay de exportação: zera aqui e só o próprio overlay os
	// repõe. Em tela cheia o draw retorna antes dele, mas o update continuava testando a
	// colisão (só olha export_run) — os rects do último frame em janela viravam uma faixa
	// invisível no meio do vídeo que cancelava a exportação com um clique qualquer.
	g_exp_pause_btn = {}; g_exp_cancel_btn = {}

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
	draw_preview(rl.Rectangle{ media_w, topbar_h + toolbar_h, sw - media_w, tl_top - (topbar_h + toolbar_h) })
	draw_timeline(rl.Rectangle{ 0, tl_top, sw, tl_h })

	// feedback das divisórias (depois do draw_timeline: o cursor setado aqui vence o de lá)
	split_hot := tl_split_drag || (hovered({ 0, tl_top - 6, sw, 9 }) && st.drag == .None && !player_seek_drag && !bin_marquee && !tl_marquee && !md_split_drag && modal == .None)
	if split_hot {
		rl.SetMouseCursor(.RESIZE_NS)
		rl.DrawRectangleRec({ 0, tl_top - 1, sw, 2 }, rl.Color{ ACCENT.r, ACCENT.g, ACCENT.b, tl_split_drag ? 235 : 130 })
	}
	// pegador SEMPRE visível no centro (pílula + 3 pontinhos): mostra ONDE agarrar mesmo sem hover
	gp := rl.Rectangle{ sw/2 - 26, tl_top - 4, 52, 8 }
	rl.DrawRectangleRounded(gp, 1, 4, split_hot ? ACCENT : rl.Color{ 74, 80, 92, 255 })
	dc := split_hot ? rl.Color{ 18, 22, 28, 255 } : rl.Color{ 165, 172, 184, 255 }
	for i in 0 ..< 3 {
		rl.DrawCircleV({ gp.x + gp.width/2 + f32(i - 1) * 9, gp.y + gp.height/2 }, 1.6, dc)
	}
	// divisória VERTICAL bin↔player: mesma linguagem visual, cursor EW e pegador em pé
	md_hot := md_split_drag || (hovered({ media_w - 5, content_top, 8, tl_top - content_top }) && st.drag == .None && !player_seek_drag && !bin_marquee && !tl_marquee && !tl_split_drag && modal == .None)
	if md_hot {
		rl.SetMouseCursor(.RESIZE_EW)
		rl.DrawRectangleRec({ media_w - 1, content_top, 2, tl_top - content_top }, rl.Color{ ACCENT.r, ACCENT.g, ACCENT.b, md_split_drag ? 235 : 130 })
	}
	mgp := rl.Rectangle{ media_w - 4, (content_top + tl_top)/2 - 26, 8, 52 }
	rl.DrawRectangleRounded(mgp, 1, 4, md_hot ? ACCENT : rl.Color{ 74, 80, 92, 255 })
	mdc := md_hot ? rl.Color{ 18, 22, 28, 255 } : rl.Color{ 165, 172, 184, 255 }
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
				rl.DrawRectangleRec(fr, rl.Color{ 90, 200, 120, 60 })
				rl.DrawRectangleLinesEx(fr, 1.6, rl.Color{ 90, 200, 120, 235 })
				txt(cs(c.name), fr.x + 6, fr.y + 4, 11, rl.WHITE)
			} else {
				ok := !track_locked[bin_drop_tr] // trilha travada = não pode receber (vermelho)
				fr := rl.Rectangle{ tl_x(bin_drop_start), track_y(bin_drop_tr) + 4, bin_drop_dur*pps(), th(bin_drop_tr) - 8 }
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

	if save_flash_t > 0 {
		label: cstring = save_flash_ok ? "Salvo" : "Salvando..."
		w := txt_w(label, 16) + 40
		r := rl.Rectangle{ sw/2 - w/2, sh/2 - 28, w, 48 }
		fade := save_flash_ok ? clamp(save_flash_t / 0.45, 0, 1) : 1 // Salvo some no fim; Salvando fica opaco
		a := u8(fade * 235)
		rl.DrawRectangleRounded(r, 0.25, 8, rl.Color{ 28, 32, 40, a })
		rl.DrawRectangleRoundedLinesEx(r, 0.25, 8, 2, rl.Color{ ACCENT.r, ACCENT.g, ACCENT.b, a })
		txt_c(label, sw/2, r.y + 14, 16, rl.Color{ 235, 238, 242, a })
	}

	if toast_t > 0 && save_flash_t <= 0 {
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
	items := []cstring{ "Novo projeto", "Abrir projeto  (Ctrl+O)", "Salvar  (Ctrl+S)", "Salvar como  (Ctrl+Shift+S)" }
	iw: f32 = 268; ih: f32 = 32
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
	// nome do arquivo no centro da barra (com * se houver edição não salva)
	pname := proj_path != "" ? file_name(proj_path) : "Sem título"
	txt_c(rl.TextFormat(dirty ? "%s  •" : "%s", cs(pname)), sw/2, h/2 - 8, 14, MUTED)

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
		if c.name_el == nil do c.name_el = strings.clone_to_cstring(string(elide(c.name, 11, tw)))
		txt(c.name_el, tx, ty + th + 3, 11, MUTED)

		// --- badge do canto inferior direito (estilo NLE) ---
		// JÁ na timeline: "✓" fixo (dispensa o rótulo "na timeline", que roubava o canto).
		// Senão, ao passar o mouse: "+" clicável que joga a mídia na timeline sem arrastar.
		badge_r := rl.Rectangle{ box.x + box.width - 22, box.y + box.height - 22, 18, 18 }
		// o "+" está clicável neste frame? (usado p/ o press da miniatura NÃO virar arrasto)
		badge_add := media_ready(i) && !placed && hovered(box)
		if media_ready(i) {
			br := badge_r
			if placed {
				rl.DrawRectangleRounded(br, 0.3, 4, rl.Color{ 40, 150, 130, 235 })
				// tique: perna curta descendo + perna longa subindo
				rl.DrawLineEx({ br.x + 4, br.y + 9 }, { br.x + 8, br.y + 13 }, 2, rl.WHITE)
				rl.DrawLineEx({ br.x + 8, br.y + 13 }, { br.x + 14, br.y + 5 }, 2, rl.WHITE)
			} else if hovered(box) {
				bhot := hovered(br)
				rl.DrawRectangleRounded(br, 0.3, 4, bhot ? ACCENT : rl.Color{ 40, 150, 130, 235 })
				rl.DrawRectangleRec({ br.x + 8, br.y + 4, 2, 10 }, rl.WHITE)
				rl.DrawRectangleRec({ br.x + 4, br.y + 8, 10, 2 }, rl.WHITE)
				if clicked(br) { bin_add_to_timeline(i); handled = true; break } // segs mudou: redesenha no próximo frame
			}
		}

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
		rl.DrawRectangleRec(mq, rl.Color{ 120, 170, 240, 45 })
		rl.DrawRectangleLinesEx(mq, 1, rl.Color{ 150, 190, 245, 220 })
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
			set_crop_mode(true)
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
			// o fade é reajustado quando o arrasto assentar (fades_settle)
			sg.dur = speed_fit_dur(selected, span / sg.speed, (c.dur - sg.in_off) / sg.speed)
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


draw_preview :: proc(r: rl.Rectangle) {
	pt := prof_beg(.Preview); defer prof_end(.Preview, pt)
	transport_h: f32 = 66 // barra de progresso (topo) + linha de botões
	video := rl.Rectangle{ r.x, r.y, r.width, r.height - transport_h }
	rl.DrawRectangleRec(video, PV_BACK) // sobra do painel: cinza, NÃO entra no export

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
		txt(rl.TextFormat("Prévia: %s  (clique na timeline p/ sair)", cs(c.name)), video.x + 10, video.y + 8, 12, rl.Color{245,205,90,235})
		txt(rl.TextFormat("Prévia: %s  (clique na timeline p/ sair)", cs(c.name)), video.x + 10, video.y + 8, 12, rl.Color{245,205,90,235})
	} else if crop_mode && modal == .None && selected >= 0 && selected < nsegs && seg_ready(selected) && !seg_audio_like(selected) && !seg_src(selected).is_text {
		// MODO RECORTE: mostra o quadro completo do clipe + moldura de recorte com alças.
		// `modal == .None` porque o editor lê rl.IsMouseButtonPressed CRU (não passa pelo
		// `clicked`, que respeita o modal): com um modal por cima, um clique nele arrastava
		// a moldura escondida atrás — e o draw_preview roda ANTES do draw_modal.
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
	rl.DrawRectangleLinesEx(g_frame, 1, PV_EDGE) // moldura do canvas de saída

	// barra do modo recorte: instrução + botão Concluir (sai do modo)
	if crop_mode {
		if selected < 0 || selected >= nsegs || !seg_ready(selected) || seg_audio_like(selected) || seg_src(selected).is_text {
			set_crop_mode(false) // seleção inválida p/ recorte
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
	pbar_hit := rl.Rectangle{ pbar.x - 4, tb.y + 5, pbar.width + 8, 18 }
	frac := total > 0 ? clamp(pos / total, 0, 1) : 0
	rl.DrawRectangleRounded(pbar, 1, 4, rl.Color{ 50, 54, 64, 255 })
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
	if player_seek_drag && total > 0 {
		np := clamp((rl.GetMousePosition().x - pbar.x) / pbar.width, 0, 1) * total
		if src_preview >= 0 {
			src_t = np
			if !clips[src_preview].streaming do clip_show(&clips[src_preview], int(np * cfps_of(&clips[src_preview]))) // cache: scrub instantâneo
			else { // streaming: mesmo worker da régua (o update também pede; aqui antecipa 1 frame)
				intrinsics.atomic_store(&scrub_req_c, src_preview)
				scrub_req_t = src_t
			}
		} else {
			st.playhead = np
			scrub_at_playhead() // todas as trilhas + worker (não só o cache do topo)
		}
	}

	// LAYOUT RESPONSIVO da barra: com o player estreito (divisória vertical), timecode + botões
	// centrais + cluster da direita se SOBREPUNHAM (precisam de ~710px). Estreito: timecode só
	// com a posição; apertado: esconde proporção/qualidade (raramente usados — reaparecem ao
	// alargar). O cluster central centra no ESPAÇO LIVRE entre o timecode e a direita, clampado.
	narrow := tb.width < 700
	tight  := tb.width < 560
	tc: cstring = narrow ? timecode(pos) : rl.TextFormat("%s / %s", timecode(pos), timecode(total))
	tcw := txt_w(tc, 15)
	// direita: fullscreen(‑30) + câmera(‑32) + alto-falante(‑30) => spr.x = fim‑92; proporção fica 150 antes
	rclust := tb.x + tb.width - 92 - (tight ? 0 : 150)
	cl := tb.x + 16 + tcw + 12
	cy := tb.y + 42 // linha de botões abaixo da barra de progresso
	cx := clamp((cl + rclust) / 2, cl + 76, max(cl + 76, rclust - 118))

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

	// timecode à esquerda: posição atual (e a duração total quando há espaço)
	txt(tc, tb.x + 16, cy - 8, 15, TEXT)

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
	if !tight {
		qlabel: cstring = stream_hi ? "Alta" : "Baixa"
		qw := txt_w(qlabel, 12) + 22
		qr := rl.Rectangle{ spr.x - 14 - qw, cy - 11, qw, 22 }
		rl.DrawRectangleRounded(qr, 0.35, 6, hovered(qr) ? HOVER : PANEL2)
		rl.DrawRectangleRoundedLinesEx(qr, 0.35, 6, 1, stream_hi ? ACCENT : LINE)
		txt_c(qlabel, qr.x + qr.width/2, qr.y + 4, 12, stream_hi ? ACCENT : TEXT)
		if clicked(qr) { set_stream_quality(!stream_hi); dirty = true } // escolha vai no .ovp
	}
	if vol_popup { // painel com slider VERTICAL acima do alto-falante
		pw := f32(34); ph := f32(108)
		vpr := rl.Rectangle{ spr.x + spr.width/2 - pw/2, cy - 14 - ph, pw, ph } // `vpr`: o `pr` de fora é o botão de play
		rl.DrawRectangleRounded(vpr, 0.2, 8, rl.Color{ 28, 31, 38, 250 })
		rl.DrawRectangleRoundedLinesEx(vpr, 0.2, 8, 1, LINE)
		ui_vslider(10, { vpr.x + pw/2 - 8, vpr.y + 12, 16, ph - 42 }, &player_vol, 0, 1)
		txt_c(rl.TextFormat("%d", i32(player_vol*100 + 0.5)), vpr.x + pw/2, vpr.y + ph - 22, 12, TEXT)
		// clicar fora (sem ser no botão nem arrastando o slider) fecha
		if rl.IsMouseButtonPressed(.LEFT) && !hovered(vpr) && !hovered(spr) && ui_slider_active != 10 do vol_popup = false
	}

	// --- formato do projeto: botão + dropdown rápido de presets ("Personalizar…" abre o modal) ---
	// (recolhido no modo apertado, junto com a qualidade — reaparece ao alargar o player)
	if tight do ar_menu_open = false
	if !tight {
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
	} // fim do !tight (proporção)

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
			rl.DrawRectangleRounded({ gx, track_y(tr) + 4, 3*pps(), th(tr) - 8 }, 0.12, 5, rl.Color{ 200, 175, 90, 150 })
		}
	}
}

