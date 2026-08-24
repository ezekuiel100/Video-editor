package main

import rl "vendor:raylib"
import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import win "core:sys/windows"

// limpa o projeto atual: fecha todas as mídias, zera timeline e histórico
clear_project :: proc() {
	st.playing = false; play_clip = -1; src_preview = -1
	// zerar nclips faz o import_media voltar a distribuir os slots 0,1,2...: um pedido de
	// prévia pendente do export abriria a prévia de OUTRA mídia, a que caísse no slot
	preview_pending = -1
	nsegs = 0; selected = -1; bin_sel = -1; drag_clip = -1; sel_trans = -1; st.drag = .None
	nfx = 0; fx_sel = -1; fxlib_drag = -1; fx_clear_marks()
	g_nv = 3; g_na = 2; tl_vscroll = 0 // volta à contagem de trilhas padrão
	for i in 0 ..< MAXTRACKS { track_muted[i] = false; track_locked[i] = false; track_hidden[i] = false; track_h[i] = 0 } // trilhas limpas (h=0 => padrão)
	bin_clear_marks(); seg_clear_marks()
	for i in 0 ..< nclips do clip_close(&clips[i])
	for i in 0 ..< MAX_SEGS do spv_release(i) // libera os WAVs de velocidade
	for i in 0 ..< MAX_SEGS do dup_release(i) // libera as texturas das vistas duplicadas
	nclips = 0
	undo_top = 0; redo_top = 0; committed_ok = false
	st.playhead = 0
	st.active_tab = 0 // Novo/Abrir volta pra aba Mídia (o clique em Arquivo→Abrir não pode deixar Efeitos)
	set_proj_ar(16.0/9.0); ar_auto = true // formato volta ao padrão (1920x1080) e reativa a autodetecção
	dirty = false
	clear_proj_path() // Novo projeto não tem arquivo — o próximo Ctrl+S pergunta o nome de novo
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
// monta o TEXTO do .ovp (no temp_allocator), sem tocar disco. Separado de save_project
// pelo mesmo motivo do export: perder segmento ao salvar falha em SILÊNCIO — o arquivo sai
// bem-formado, só que menor — então o que precisa de teste é o texto, não a escrita.
save_project_text :: proc() -> string {
	idx: [MAX_CLIPS]int; for i in 0 ..< MAX_CLIPS do idx[i] = -1
	medias := make([dynamic]string, context.temp_allocator)
	for i in 0 ..< nclips {
		if intrinsics.atomic_load(&clips[i].failed) || clips[i].closed do continue
		idx[i] = len(medias)
		if clips[i].is_caps { // faixa de legendas: estilo + duração; as falas vão na seção `cues`
			tc := clips[i].text_color
			bc := clips[i].cap_box_col
			append(&medias, fmt.tprintf("#CAP\t%.4f\t%d\t%d\t%d\t%d\t%.4f\t%d\t%.3f\t%.3f\t%d\t%d\t%d\t%d",
				clips[i].text_size, tc.r, tc.g, tc.b, clips[i].text_font, clips[i].dur,
				int(clips[i].cap_preset), clips[i].cap_stroke, clips[i].cap_box,
				bc.r, bc.g, bc.b, clips[i].cap_upper ? 1 : 0))
		} else if clips[i].is_text { // clipe de texto: "#TXT<tab>size<tab>r<tab>g<tab>b<tab>fonte<tab>texto"
			tc := clips[i].text_color
			append(&medias, fmt.tprintf("#TXT\t%.4f\t%d\t%d\t%d\t%d\t%s", clips[i].text_size, tc.r, tc.g, tc.b, clips[i].text_font, clips[i].text))
		} else {
			append(&medias, clips[i].path)
		}
	}
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "OVP1\nar %.6f\nres %d %d\ntracks %d %d\nmedia %d\n", proj_ar, proj_w, proj_h, g_nv, g_na, len(medias))
	for p in medias do fmt.sbprintf(&b, "%s\n", p)
	// SÓ o índice decide: `idx` já exclui mídia falha e removida (tombstone) — que é tudo o
	// que não deve ser salvo. Filtrar também por `seg_ready` descartava, EM SILÊNCIO, todo
	// segmento cuja mídia ainda estava no probe: o .ovp saía internamente coerente (a contagem
	// usava o mesmo filtro), só que com menos clipes do que a timeline mostrava. Bastava abrir
	// um projeto com muitos vídeos e dar Ctrl+S por cima antes do bin terminar de importar.
	// Salvar um segmento com a mídia em probe é seguro: os campos do Seg já estão todos
	// definidos desde o add_seg, e o load reimporta a mídia pelo caminho de qualquer jeito.
	nv := 0
	for i in 0 ..< nsegs do if idx[segs[i].src] >= 0 do nv += 1
	fmt.sbprintf(&b, "seg %d\n", nv)
	for i in 0 ..< nsegs {
		if idx[segs[i].src] < 0 do continue
		s := segs[i]
		fmt.sbprintf(&b, "%d %d %.4f %.4f %.4f %.4f %d %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %d %.4f %.4f %.4f %.4f %d %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %d\n",
			idx[s.src], s.track, s.start, s.in_off, s.dur, s.vol, s.muted ? 1 : 0, s.fade_in, s.fade_out, s.scale, s.px, s.py, s.rot, s.opacity, s.speed <= 0 ? 1 : s.speed, s.trans, s.vfin, s.vfout, s.crop_x, s.crop_y, s.crop_w, s.crop_h, s.zoom_anim ? 1 : 0, s.crop2_x, s.crop2_y, s.crop2_w, s.crop2_h, s.aonly ? 1 : 0, s.fx_bright, s.fx_contrast, s.fx_satur, s.fx_look, s.fx_vignette, s.fx_temp, s.bulge, s.bulge_x, s.bulge_y, s.bulge_r, s.wobble, s.wobble_speed, s.trans_mode)
	}
	// LAYOUT do editor: divisórias (frações da janela) + altura de cada trilha. Não afeta o
	// vídeo exportado, mas o usuário monta o espaço de trabalho e espera reencontrá-lo.
	// Chaves novas: projetos antigos simplesmente não as têm e caem nos padrões (o switch do
	// load ignora chaves desconhecidas, então o formato segue compatível nos dois sentidos).
	fmt.sbprintf(&b, "layout %.4f %.4f\n", tl_frac, md_frac)
	fmt.sbprintf(&b, "prevq %d\n", stream_hi ? 1 : 0) // qualidade da prévia de clipes streaming
	fmt.sbprintf(&b, "trackh")
	for i in 0 ..< MAXTRACKS do fmt.sbprintf(&b, " %.1f", track_h[i]) // 0 = altura padrão
	fmt.sbprintf(&b, "\n")
	// mute / lock / hide da TRILHA (não do clipe). Sem estas linhas o clipe volta,
	// mas a faixa que o usuário silenciou/bloqueou/escondeu nasce ligada de novo.
	// Projetos antigos não têm as chaves → load deixa tudo false (zero-value).
	fmt.sbprintf(&b, "trackm")
	for i in 0 ..< MAXTRACKS do fmt.sbprintf(&b, " %d", track_muted[i] ? 1 : 0)
	fmt.sbprintf(&b, "\n")
	fmt.sbprintf(&b, "trackl")
	for i in 0 ..< MAXTRACKS do fmt.sbprintf(&b, " %d", track_locked[i] ? 1 : 0)
	fmt.sbprintf(&b, "\n")
	fmt.sbprintf(&b, "trackv") // v = hidden (trackh já é altura)
	for i in 0 ..< MAXTRACKS do fmt.sbprintf(&b, " %d", track_hidden[i] ? 1 : 0)
	fmt.sbprintf(&b, "\n")
	// clipes de EFEITO (faixa): kind start dur amount radius cx cy wobble speed angle track
	fmt.sbprintf(&b, "fx %d\n", nfx)
	for i in 0 ..< nfx {
		e := fxsegs[i]
		fmt.sbprintf(&b, "%d %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f %d\n", e.kind, e.start, e.dur, e.amount, e.radius, e.cx, e.cy, e.wobble, e.speed, e.angle, e.track)
	}
	// falas das faixas de legendas: `cues <idx-de-mídia> <n>` + n linhas `t0 t1 texto`
	for i in 0 ..< nclips {
		if idx[i] < 0 || !clips[i].is_caps || len(clips[i].caps) == 0 do continue
		fmt.sbprintf(&b, "cues %d %d\n", idx[i], len(clips[i].caps))
		for q in clips[i].caps {
			body, _ := strings.replace_all(q.text, "\n", " ", context.temp_allocator)
			fmt.sbprintf(&b, "%.3f %.3f %s\n", q.t0, q.t1, body)
		}
	}
	return strings.to_string(b)
}

// campos numéricos de uma linha `seg` (projetos antigos têm 34; os 6 últimos são bulge/wobble)
OVP_SEG_N :: 41

OvpParsed :: struct {
	muted, locked, hidden: [MAXTRACKS]bool,
	nseg: int,
	fields: [MAX_SEGS][OVP_SEG_N]f32,
}

// lê o texto de um .ovp SEM importar mídia — serve p/ teste de round-trip e p/ inspecionar
// o que o save emitiu. Arquivo inválido → ok=false.
parse_project_text :: proc(data: string) -> (p: OvpParsed, ok: bool) {
	lines := strings.split_lines(data, context.temp_allocator)
	if len(lines) < 1 || strings.trim_space(lines[0]) != "OVP1" do return
	ok = true
	li := 1
	for li < len(lines) {
		ln := strings.trim_space(lines[li]); li += 1
		if ln == "" do continue
		toks := strings.fields(ln, context.temp_allocator)
		if len(toks) == 0 do continue
		switch toks[0] {
		case "trackm":
			for k in 1 ..< len(toks) do if k - 1 < MAXTRACKS do p.muted[k - 1] = (strconv.parse_int(toks[k]) or_else 0) != 0
		case "trackl":
			for k in 1 ..< len(toks) do if k - 1 < MAXTRACKS do p.locked[k - 1] = (strconv.parse_int(toks[k]) or_else 0) != 0
		case "trackv":
			for k in 1 ..< len(toks) do if k - 1 < MAXTRACKS do p.hidden[k - 1] = (strconv.parse_int(toks[k]) or_else 0) != 0
		case "seg":
			n := len(toks) >= 2 ? (strconv.parse_int(toks[1]) or_else 0) : 0
			for _ in 0 ..< n {
				if li >= len(lines) || p.nseg >= MAX_SEGS do break
				ft := strings.fields(strings.trim_space(lines[li]), context.temp_allocator); li += 1
				row: [OVP_SEG_N]f32
				row[14] = 1
				for k in 0 ..< min(OVP_SEG_N, len(ft)) do row[k] = f32(strconv.parse_f64(ft[k]) or_else 0)
				p.fields[p.nseg] = row
				p.nseg += 1
			}
		}
	}
	return
}

// aplica flags de trilha + campos extra do Seg a partir do parse (mídias já no bin).
apply_parsed_project :: proc(p: OvpParsed) {
	nsegs = 0
	for i in 0 ..< p.nseg {
		f := p.fields[i]
		if !seg_line_ok(f[0], f[2], f[3], f[4]) do continue
		ltr := int(f[1])
		ltr = is_audio_track(ltr) ? clamp(ltr, MAXV, MAXV+MAXA-1) : clamp(ltr, 0, MAXV-1)
		si := add_seg(int(f[0]), f[2], f[3], f[4], ltr)
		if si < 0 do continue
		seg_apply_ovp_fields(&segs[si], f)
	}
	for i in 0 ..< MAXTRACKS {
		track_muted[i] = p.muted[i]
		track_locked[i] = p.locked[i]
		track_hidden[i] = p.hidden[i]
	}
}

seg_apply_ovp_fields :: proc(sg: ^Seg, f: [OVP_SEG_N]f32) {
	sg.vol = f[5]; sg.muted = f[6] > 0.5; sg.fade_in = f[7]; sg.fade_out = f[8]
	sg.scale = f[9]; sg.px = f[10]; sg.py = f[11]; sg.rot = f[12]; sg.opacity = f[13]
	sg.speed = (inv_bad(f[14]) || f[14] <= 0) ? 1 : f[14]
	sg.trans = f[15]; sg.vfin = f[16]; sg.vfout = f[17]
	sg.crop_x = f[18]; sg.crop_y = f[19]; sg.crop_w = f[20]; sg.crop_h = f[21]
	sg.zoom_anim = f[22] > 0.5; sg.crop2_x = f[23]; sg.crop2_y = f[24]; sg.crop2_w = f[25]; sg.crop2_h = f[26]
	sg.aonly = f[27] > 0.5
	sg.fx_bright = f[28]; sg.fx_contrast = f[29]; sg.fx_satur = f[30]; sg.fx_look = f[31]; sg.fx_vignette = f[32]; sg.fx_temp = f[33]
	sg.bulge = f[34]; sg.bulge_x = f[35]; sg.bulge_y = f[36]; sg.bulge_r = f[37]; sg.wobble = f[38]; sg.wobble_speed = f[39]
	sg.trans_mode = int(f[40] + 0.5)
}

// caminho do .ovp aberto/salvo (heap). Vazio = ainda sem arquivo → Ctrl+S abre o diálogo.
proj_path: string
save_pending: bool  // gravar no PRÓXIMO frame: este ainda desenha "Salvando..."
save_flash_t: f32   // segundos restantes do cartão na tela
save_flash_ok: bool // false = Salvando… | true = Salvo

set_proj_path :: proc(p: string) {
	if proj_path == p do return
	if proj_path != "" do delete(proj_path)
	proj_path = p != "" ? strings.clone(p) : ""
}
clear_proj_path :: proc() { set_proj_path("") }

file_name :: proc(path: string) -> string {
	for i := len(path) - 1; i >= 0; i -= 1 do if path[i] == '/' || path[i] == '\\' do return path[i + 1:]
	return path
}

// 1º save: diálogo. Depois: grava no mesmo caminho, sem perguntar o nome.
request_save :: proc() {
	if proj_path != "" { begin_save(proj_path); return }
	if p, ok := save_dialog("Meu Projeto"); ok do begin_save(ensure_ext(p, ".ovp"))
}
request_save_as :: proc() {
	hint := proj_path != "" ? file_name(proj_path) : "Meu Projeto"
	if p, ok := save_dialog(hint); ok do begin_save(ensure_ext(p, ".ovp"))
}
// marca p/ gravar no próximo frame (o atual ainda pinta "Salvando...")
begin_save :: proc(path: string) {
	set_proj_path(path)
	save_pending = true
	save_flash_ok = false
	save_flash_t = 1.6
}
// grava AGORA (sem esperar o próximo frame). Usado no "Salvar alterações?" antes de Novo/Abrir/Sair.
save_now :: proc() -> bool {
	if proj_path == "" {
		if p, ok := save_dialog("Meu Projeto"); ok do set_proj_path(ensure_ext(p, ".ovp"))
		else do return false
	}
	return save_project(proj_path)
}

save_project :: proc(path: string) -> bool {
	txt := save_project_text()
	if os.write_entire_file(path, transmute([]u8)txt) == nil {
		set_proj_path(path)
		dirty = false
		save_flash_ok = true
		save_flash_t = 1.6
		set_toast(rl.TextFormat("Salvo: %s", cs(file_name(path))))
		return true
	}
	save_pending = false
	save_flash_t = 0
	set_toast("Falha ao salvar o projeto")
	return false
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
	ltl := f32(-1); lmd := f32(-1) // divisórias salvas (-1 = ausente: mantém o padrão)
	lpq := stream_hi               // qualidade da prévia salva (ausente = mantém a atual)
	lth: [MAXTRACKS]f32            // alturas de trilha salvas (0 = padrão)
	lm, ll, lv: [MAXTRACKS]bool    // mute / lock / hide (ausente = tudo false)
	mpaths := make([dynamic]string, context.temp_allocator)
	Seg2 :: struct { fields: [OVP_SEG_N]f32 }
	segd := make([dynamic]Seg2, context.temp_allocator)
	fxd  := make([dynamic]FxSeg, context.temp_allocator)
	CueLoad :: struct { mi: int, t0, t1: f32, text: string }
	cueload := make([dynamic]CueLoad, context.temp_allocator)
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
		case "layout": // divisórias (frações da janela)
			if len(toks) >= 3 {
				if v, o := strconv.parse_f64(toks[1]); o do ltl = f32(v)
				if v, o := strconv.parse_f64(toks[2]); o do lmd = f32(v)
			}
		case "prevq": // qualidade da prévia de streaming (0 = Baixa/360p, 1 = Alta/720p)
			if len(toks) >= 2 do lpq = (strconv.parse_int(toks[1]) or_else 1) != 0
		case "trackh": // altura de cada trilha (0 = padrão)
			for k in 1 ..< len(toks) do if k - 1 < MAXTRACKS {
				if v, o := strconv.parse_f64(toks[k]); o do lth[k - 1] = f32(v)
			}
		case "trackm": // trilha silenciada
			for k in 1 ..< len(toks) do if k - 1 < MAXTRACKS do lm[k - 1] = (strconv.parse_int(toks[k]) or_else 0) != 0
		case "trackl": // trilha bloqueada
			for k in 1 ..< len(toks) do if k - 1 < MAXTRACKS do ll[k - 1] = (strconv.parse_int(toks[k]) or_else 0) != 0
		case "trackv": // trilha oculta (v de hidden — trackh já é altura)
			for k in 1 ..< len(toks) do if k - 1 < MAXTRACKS do lv[k - 1] = (strconv.parse_int(toks[k]) or_else 0) != 0
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
				for k in 0 ..< min(OVP_SEG_N, len(ft)) do s.fields[k] = f32(strconv.parse_f64(ft[k]) or_else 0)
				append(&segd, s)
			}
		case "cues": // falas de uma faixa de legendas (idx = ordem da seção media)
			mi := len(toks) >= 2 ? (strconv.parse_int(toks[1]) or_else -1) : -1
			n := len(toks) >= 3 ? (strconv.parse_int(toks[2]) or_else 0) : 0
			for _ in 0 ..< n {
				if li >= len(lines) do break
				lnc := strings.trim_space(lines[li]); li += 1
				sp1 := strings.index_byte(lnc, ' ')
				if sp1 < 0 do continue
				rest := lnc[sp1 + 1:]
				sp2 := strings.index_byte(rest, ' ')
				if sp2 < 0 do continue
				t0 := f32(strconv.parse_f64(lnc[:sp1]) or_else 0)
				t1 := f32(strconv.parse_f64(rest[:sp2]) or_else 0)
				body := strings.trim_space(rest[sp2 + 1:])
				if body != "" do append(&cueload, CueLoad{ mi, t0, t1, body })
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
				// sem track no arquivo: sentinela (-1), vira o topo depois de restaurar g_nv.
				// COM track, clampa: este é o único campo do .ovp que vira ÍNDICE DE ARRAY
				// (track_h/track_locked/track_muted/track_hidden, todos [MAXTRACKS]), e o
				// conserto lá embaixo só trata o caso < 0 — um valor fora da faixa, de arquivo
				// editado à mão ou corrompido, matava o editor no primeiro draw com bounds
				// check. O layout/trackh/res ao lado já são validados pelo mesmo motivo.
				e.track = len(ft) >= 11 ? clamp(int(g(ft,10)), 0, MAXV-1) : -1
				append(&fxd, e)
			}
		}
	}
	// aplica: limpa, reimporta (slots 0..N-1 na ordem), recria segmentos
	clear_project()
	for p in mpaths {
		if strings.has_prefix(p, "#CAP\t") { // faixa de legendas (falas vêm em `cues`)
			f := strings.split(p, "\t", context.temp_allocator)
			size := len(f) >= 2 ? f32(strconv.parse_f64(f[1]) or_else 0.05) : 0.05
			col := rl.WHITE
			if len(f) >= 5 {
				col.r = u8(strconv.parse_int(f[2]) or_else 255)
				col.g = u8(strconv.parse_int(f[3]) or_else 255)
				col.b = u8(strconv.parse_int(f[4]) or_else 255)
			}
			font := len(f) >= 6 ? (strconv.parse_int(f[5]) or_else 0) : 0
			dur := len(f) >= 7 ? f32(strconv.parse_f64(f[6]) or_else 5.0) : IMG_DUR
			slot := new_caps_clip({}, size, col, dur)
			if slot >= 0 {
				clips[slot].text_font = font
				if len(f) >= 14 {
					clips[slot].cap_preset = CapPreset(clamp(strconv.parse_int(f[7]) or_else 0, 0, int(max(CapPreset))))
					clips[slot].cap_stroke = f32(strconv.parse_f64(f[8]) or_else 0)
					clips[slot].cap_box = f32(strconv.parse_f64(f[9]) or_else 0)
					clips[slot].cap_box_col = rl.Color{
						u8(strconv.parse_int(f[10]) or_else 0),
						u8(strconv.parse_int(f[11]) or_else 0),
						u8(strconv.parse_int(f[12]) or_else 0),
						255,
					}
					clips[slot].cap_upper = (strconv.parse_int(f[13]) or_else 0) != 0
				}
			}
		} else if strings.has_prefix(p, "#TXT\t") { // clipe de texto: recria do registro salvo
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
	for q in cueload {
		if q.mi < 0 || q.mi >= nclips do continue
		c := &clips[q.mi]
		if !c.is_caps do continue
		append(&c.caps, CapCue{ q.t0, q.t1, strings.clone(q.text) })
		if c.text == "" || c.text == "Legendas" {
			delete(c.text)
			c.text = strings.clone(q.text)
		}
	}
	for s in segd {
		f := s.fields
		if !seg_line_ok(f[0], f[2], f[3], f[4]) do continue
		// trilha clampada DENTRO da faixa do seu tipo (o valor do arquivo decide qual): vira
		// índice de track_h/track_locked/... e nada adiante o valida — ver o fx acima
		ltr := int(f[1])
		ltr = is_audio_track(ltr) ? clamp(ltr, MAXV, MAXV+MAXA-1) : clamp(ltr, 0, MAXV-1)
		si := add_seg(int(f[0]), f[2], f[3], f[4], ltr)
		if si < 0 do continue
		seg_apply_ovp_fields(&segs[si], f)
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
	// LAYOUT salvo (aplicado DEPOIS do clear_project, que zera as alturas). Valores validados:
	// arquivo corrompido/editado à mão não pode deixar a UI inutilizável — fora da faixa, cai
	// no padrão. Ausente (projeto antigo) mantém o que já estava.
	if ltl > 0.05 && ltl < 0.95 do tl_frac = ltl
	if lmd > 0.05 && lmd < 0.95 do md_frac = lmd
	stream_hi = lpq // qualidade da prévia (set_stream_quality não serve aqui: nada foi importado ainda)
	for i in 0 ..< MAXTRACKS {
		track_h[i] = (lth[i] >= TRACK_H_MIN && lth[i] <= TRACK_H_MAX) ? lth[i] : 0 // 0 = padrão
		track_muted[i] = lm[i]; track_locked[i] = ll[i]; track_hidden[i] = lv[i]
	}
	if res_w > 0 && res_h > 0 do set_proj_res(res_w, res_h) // resolução salva (novo formato)
	else do set_proj_ar(ar)                                  // projeto antigo: deriva do aspecto
	ar_auto = false // projeto salvo traz seu próprio formato — não sobrescreve na próxima importação
	dirty = false
	set_proj_path(path) // Ctrl+S a partir daqui grava neste arquivo, sem pedir nome
	set_toast(rl.TextFormat("Projeto aberto: %s", cs(file_name(path))))
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
		// sem Flags o Windows sobrescrevia SEM perguntar — salvar por cima de um projeto
		// (ou de um vídeo já exportado) era irreversível e sem aviso nenhum
		Flags       = win.SAVE_FLAGS, // OFN_OVERWRITEPROMPT | OFN_EXPLORER
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
	// avisa ANTES de abrir o modal: melhor que deixar escolher nome/pasta e recusar no fim
	// (export_build_args barra de novo — esta checagem é só para o usuário não perder o passo)
	if imp := segs_importing(); imp > 0 {
		set_toast(rl.TextFormat("%d clipe(s) ainda importando — espere terminar", i32(imp)))
		return
	}
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
