package main

import rl "vendor:raylib"
import "core:fmt"
import "core:math"
import "base:intrinsics"

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
			case 2:
				if track_locked[segs[selected].track] { set_toast("Trilha bloqueada") }
				else do remove_seg(selected, !alt_down())
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

	// botão "Cortar e Ampliar": só o ícone na barra (como desfazer/lâmina). O nome
	// aparece no hover, desenhado no fim de draw_timeline p/ ficar por cima da régua.
	cz_ok := selected >= 0 && selected < nsegs && seg_ready(selected) && !seg_audio_like(selected) && !seg_src(selected).is_text
	cz := rl.Rectangle{ ix - 4, tb.y + 4, 26, 26 }
	if cz_ok && clicked(cz) do open_crop_modal()
	rl.DrawRectangleRounded(cz, 0.3, 4, (hovered(cz) && cz_ok) ? HOVER : PANEL2)
	{ // ícone: cantos de recorte
		icx := cz.x + 13; icy := tb.y + tb.height/2; icol := cz_ok ? TEXT : rl.Color{ 92,96,104,255 }
		rl.DrawLineEx({icx-6, icy-6},{icx-6, icy+1}, 2, icol); rl.DrawLineEx({icx-6, icy-6},{icx+1, icy-6}, 2, icol)
		rl.DrawLineEx({icx+6, icy+6},{icx+6, icy-1}, 2, icol); rl.DrawLineEx({icx+6, icy+6},{icx-1, icy+6}, 2, icol)
	}
	ix += 30

	// Detectar silêncio: ao lado de Cortar e Ampliar (mesmo tamanho/estilo)
	sz_ok := selected >= 0 && selected < nsegs && seg_ready(selected) &&
		(seg_src(selected).src_audio || seg_src(selected).has_audio) && !seg_src(selected).is_text
	sz := rl.Rectangle{ ix - 4, tb.y + 4, 26, 26 }
	if sz_ok && clicked(sz) do open_silence_modal()
	rl.DrawRectangleRounded(sz, 0.3, 4, (hovered(sz) && sz_ok) ? HOVER : PANEL2)
	{ // ícone: onda com vão no meio (silêncio)
		icx := sz.x + 13; icy := tb.y + tb.height/2; icol := sz_ok ? TEXT : rl.Color{ 92,96,104,255 }
		rl.DrawLineEx({icx-8, icy}, {icx-5, icy-5}, 1.6, icol)
		rl.DrawLineEx({icx-5, icy-5}, {icx-2, icy+4}, 1.6, icol)
		rl.DrawLineEx({icx-2, icy+4}, {icx-0.5, icy}, 1.6, icol)
		rl.DrawLineEx({icx+0.5, icy}, {icx+2, icy+4}, 1.6, icol)
		rl.DrawLineEx({icx+2, icy+4}, {icx+5, icy-5}, 1.6, icol)
		rl.DrawLineEx({icx+5, icy-5}, {icx+8, icy}, 1.6, icol)
		rl.DrawLineEx({icx-1.5, icy}, {icx+1.5, icy}, 1.4, MUTED) // hiato = silêncio
	}
	ix += 30

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
	g_track_h = 72         // altura PADRÃO (não expande nem encolhe sozinha; quando não cabem, ROLA)
	nrows := g_nv + g_na
	content_h := tracks_content_h()                                                         // soma as alturas POR TRILHA
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

	WAVE_H :: f32(22) // faixa MÍNIMA da forma de onda no rodapé do bloco (cresce com a trilha)
	vlane := g_vlane // viewport de TODAS as trilhas (refs horizontais)
	// soltou o botão: encerra o redimensionamento de trilha (mesmo fora da zona)
	if track_resize >= 0 && !rl.IsMouseButtonDown(.LEFT) { track_resize = -1; dirty = true } // altura vai no .ovp
	// fundo + cabeçalho de cada trilha visível, RECORTADO ao viewport rolável (o scroll vertical
	// desliza as trilhas sob a faixa de efeitos/bandas sem vazar por cima delas)
	rl.BeginScissorMode(i32(r.x), i32(rows_top), i32(r.width), i32(rows_vh))
	for row in 0 ..< nrows {
		t := track_of_row(row)
		ly := track_y(t)
		lh := th(t)
		if ly + lh < rows_top || ly > rows_top + rows_vh do continue // fora da viewport: pula
		aud := is_audio_track(t)
		label := aud ? rl.TextFormat("A%d", i32(t - MAXV + 1)) : rl.TextFormat("V%d", i32(t + 1))
		// PEGADOR de altura na borda de baixo do cabeçalho (6px, abaixo dos botões M/cadeado/olho
		// que terminam em lh-6). Press tratado ANTES do header p/ ter prioridade sobre eles.
		hz := rl.Rectangle{ r.x, ly + lh - 3, LANE_X, 6 }
		if track_resize < 0 && rl.IsMouseButtonPressed(.LEFT) && hovered(hz) &&
		   st.drag == .None && !tl_split_drag && !md_split_drag && modal == .None {
			track_resize = t
		}
		if track_resize == t { // arrastando: a altura segue o mouse (o topo da trilha não muda)
			track_h[t] = clamp(rl.GetMousePosition().y - ly, TRACK_H_MIN, TRACK_H_MAX)
			lh = th(t)
		}
		draw_track_header({ r.x, ly, LANE_X, lh }, label, t)
		rl.DrawRectangleRec({ r.x + LANE_X, ly, r.width - LANE_X, lh }, aud ? rl.Color{ 28, 34, 32, 255 } : rl.Color{ 30, 33, 40, 255 })
		if track_locked[t] do rl.DrawRectangleRec({ r.x + LANE_X, ly, r.width - LANE_X, lh }, rl.Color{ 210, 160, 50, 20 }) // tint bloqueada
		if track_muted[t]  do rl.DrawRectangleRec({ r.x + LANE_X, ly, r.width - LANE_X, lh }, rl.Color{ 170, 60, 60, 24 })  // tint muda
		if track_hidden[t] do rl.DrawRectangleRec({ r.x + LANE_X, ly, r.width - LANE_X, lh }, rl.Color{ 80, 100, 130, 30 })  // tint oculta
		// feedback do pegador: pontilhado discreto, acende no hover/arrasto
		hot := track_resize == t || (track_resize < 0 && hovered(hz) && st.drag == .None && modal == .None)
		if hot {
			rl.SetMouseCursor(.RESIZE_NS)
			rl.DrawRectangleRec({ r.x, ly + lh - 1, LANE_X, 2 }, ACCENT)
		} else {
			for k in 0 ..< 3 do rl.DrawCircleV({ r.x + LANE_X/2 + f32(k - 1)*7, ly + lh - 2 }, 1.1, rl.Color{ 110, 118, 132, 255 })
		}
	}
	rl.EndScissorMode()
	// bandas "criar trilha" PINADAS (topo=vídeo, base=áudio): escuras, com "+"; arraste mídia aqui OU clique no "+"
	draw_new_track_zone(g_newv_zone, false)
	draw_new_track_zone(g_newa_zone, true)
	// barra de rolagem VERTICAL (aparece só quando as trilhas não cabem). A barra fica DENTRO
	// da faixa das trilhas, então o mesmo press também caía no hit-test dos clipes e virava
	// `st.drag = .Clip`: rolar arrastava junto o clipe que estava embaixo dela e, como a
	// origem das trilhas muda a cada frame durante a rolagem, ele ainda trocava de trilha.
	// `vbar_hit` entra em `consumed` (abaixo) p/ o clique ser só da barra.
	// O HIT tem de ficar AQUI (antes do laço de segmentos), mas o DESENHO vai lá embaixo,
	// junto da barra horizontal: desenhada neste ponto, os clipes vinham depois e tapavam a
	// barra em toda trilha com clipe chegando à borda direita.
	vbar_hit := false
	vsb_track: rl.Rectangle // calha; width 0 = sem barra (não desenha)
	vsb_thumb: rl.Rectangle
	if max_vscroll > 0 {
		vsb_w: f32 = 8
		vsb_x := r.x + r.width - vsb_w - 3
		vsb_track = rl.Rectangle{ vsb_x, rows_top, vsb_w, rows_vh }
		thumb_h := max(30, rows_vh * rows_vh / content_h)
		vsb_thumb = rl.Rectangle{ vsb_x, rows_top + (tl_vscroll / max_vscroll) * (rows_vh - thumb_h), vsb_w, thumb_h }
		if clicked(vsb_thumb) do tl_vbar_drag = true
		// a CALHA também é da barra: clicar ao lado do polegar não pode agarrar um clipe
		vbar_hit = tl_vbar_drag || clicked(vsb_track)
		if rl.IsMouseButtonReleased(.LEFT) do tl_vbar_drag = false
		if tl_vbar_drag {
			my := rl.GetMousePosition().y
			rel := clamp((my - vsb_track.y - thumb_h/2) / (rows_vh - thumb_h), 0, 1)
			tl_vscroll = rel * max_vscroll
		}
	}
	if segs_ready() == 0 do txt_c("arraste um clipe do bin para cá", vlane.x + vlane.width/2, track_y(0) + th(0)/2 - 8, 13, MUTED)

	// segmentos de vídeo (e blocos de áudio) colocados na timeline
	vc := view_seg()
	consumed := ctx_open || ctx_ate || vbar_hit // menu de contexto / barra de rolagem: timeline inerte
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

		vr := rl.Rectangle{ x, track_y(sg.track) + 4, w, th(sg.track) - 8 }
		alike := c.is_audio || sg.aonly // se comporta como áudio (mídia só-áudio OU áudio separado)
		rl.DrawRectangleRounded(vr, 0.06, 4, alike ? rl.Color{ 34, 52, 46, 255 } : (c.is_text ? rl.Color{ 58, 48, 78, 255 } : CLIP))
		// clipe só-áudio: a onda ocupa o bloco todo (sem filmstrip). Vídeo: REPARTIÇÃO em que a
		// IMAGEM cresce devagar (FILM_BASE + 25% do espaço extra, teto FILM_MAX) e TODO o resto
		// vai pra ONDA — aumentar a trilha engorda o áudio, que é o ponto (achar o corte). Na
		// altura padrão a conta dá exatamente o visual de sempre (tira 27px, onda WAVE_H).
		FILM_BASE :: f32(27)  // tira na trilha padrão (avail 49 = 27 de imagem + 22 de onda)
		FILM_MAX  :: f32(96)  // além disso a miniatura não ganha nada em legibilidade
		avail := vr.height - 15 // abaixo da barra de título
		film := clamp(FILM_BASE + max(0, avail - 49) * 0.25, 0, FILM_MAX)
		wave_h := alike ? avail : (c.has_audio ? clamp(avail - film, WAVE_H, max(WAVE_H, avail)) : 0)
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
		// VELOCIDADE ALTERADA: a marcação tem de pegar o clipe INTEIRO — uma pastilha na ponta
		// não diz QUE TRECHO da timeline está acelerado/lento. Hachura diagonal (45°) sobre a
		// tira de miniaturas, no comprimento todo, + a barra do título tingida na mesma cor.
		spd := seg_speed(i)
		spd_on := abs(spd - 1) > 0.001
		if spd_on && !alike {
			bx0 := max(vr.x, clip_rect.x)
			bx1 := min(vr.x + vr.width, clip_rect.x + clip_rect.width)
			by := vr.y + 15
			bh := vr.height - 15 - wave_h
			if bh > 6 && bx1 > bx0 {
				hcol := fa(speed_color(spd), 0.2)
				STRIPE :: f32(16) // grade ancorada em vr.x: a hachura anda junto com o clipe
				// só o trecho VISÍVEL, como a onda: um clipe de 1h em zoom alto tem centenas de
				// milhares de px e o scissor corta o desenho, não o custo das chamadas.
				n0 := math.floor((bx0 - vr.x) / STRIPE)
				for sx := vr.x + n0 * STRIPE; sx <= bx1 + bh; sx += STRIPE {
					// risco de (sx, by) a (sx-bh, by+bh), cortado nas bordas visíveis em x
					t0 := max(f32(0), sx - bx1)
					t1 := min(bh, sx - bx0)
					if t1 <= t0 do continue
					rl.DrawLineEx({ sx - t0, by + t0 }, { sx - t1, by + t1 }, 3, hcol)
				}
			}
		}
		rl.DrawRectangleRounded({vr.x, vr.y, vr.width, 15}, 0.15, 4, CLIP_HDR) // barra do título por cima
		if spd_on do rl.DrawRectangleRounded({vr.x, vr.y, vr.width, 15}, 0.15, 4, fa(speed_color(spd), 0.45))
		// PASTILHA com o VALOR: fica na ENTRADA do clipe (antes do nome), que é onde o olho cai
		// primeiro, e GRUDA na parte VISÍVEL: num clipe longo em zoom alto o começo fica muito
		// fora da tela, e ancorada nele o número sumiria. Clipe estreito demais p/ a pastilha
		// ganha um risco vertical da mesma cor — algum sinal sempre aparece.
		xbtn_room := (i == selected && w > 26) ? f32(18) : 0 // espaço reservado ao botão x
		name_x := vr.x + 6 // início do nome; a pastilha empurra pra direita
		if spd_on {
			scol := speed_color(spd)
			lbl := speed_label(spd)
			pw := txt_w(lbl, 10) + 8
			vis0 := max(vr.x, clip_rect.x)
			// à direita da área visível fica a barra de rolagem vertical, quando há uma
			vis1 := min(vr.x + vr.width - xbtn_room, clip_rect.x + clip_rect.width - (max_vscroll > 0 ? 13 : 0))
			px := vis0 + 5
			if px + pw <= vis1 - 3 {
				pr := rl.Rectangle{ px, vr.y + 1.5, pw, 12 }
				rl.DrawRectangleRounded(pr, 0.5, 6, scol)
				txt_c(lbl, px + pw/2, pr.y + 1, 10, rl.Color{ 24, 26, 32, 255 })
				name_x = max(name_x, px + pw + 5)
			} else if vis1 - vis0 > 5 { // estreito: só o risco na borda visível
				rl.DrawRectangleRec({ vis0 + 1, vr.y + 2, 3, 11 }, scol)
			}
		}
		if w > 40 { // nome cortado (…) p/ CABER no clipe, sem vazar pro vizinho
			name_r := vr.x + w - 6 - xbtn_room // limite direito do nome (reserva p/ o botão x)
			if name_r - name_x > 12 do txt(elide(c.name, 11, name_r - name_x), name_x, vr.y + 1, 11, rl.WHITE)
		}
		// marcas de silêncio detectado (modal aberto): faixa âmbar sobre o vão
		if modal == .Silence && i == sil_si {
			for k in 0 ..< sil_n {
				sx0 := tl_x(sil_hits[k].t0)
				sx1 := tl_x(sil_hits[k].t1)
				sr := rl.Rectangle{ sx0, vr.y, sx1 - sx0, vr.height }
				rl.DrawRectangleRec(sr, rl.Color{ 220, 170, 50, 70 })
			}
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
			if clicked(xr) {
				if track_locked[segs[i].track] { set_toast("Trilha bloqueada") }
				else do remove_seg(i, !alt_down())
				consumed = true
			}
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
			// SINGLE-SIDED (não espelhada): a onda preenche a partir da BASE da faixa, como
			// nos NLEs de mercado. Espelhar no centro gastava metade da altura desenhando a
			// imagem refletida — de um lado só o mesmo espaço mostra o DOBRO de detalhe, que
			// é o que importa pra achar o ponto do corte.
			base := ar.y + ar.height - 2
			amp := ar.height - 4
			cy := ar.y + ar.height / 2 // só p/ posicionar o ícone de mudo
			// corpo (RMS) sólido + contorno (pico) translúcido; cinza quando mudo
			wcol := sg.muted ? rl.Color{ 120, 126, 136, 190 } : rl.Color{ 95, 180, 150, 235 }
			pcol := sg.muted ? rl.Color{ 120, 126, 136,  70 } : rl.Color{ 95, 180, 150,  90 }
			for wx := wx0; wx < wx1; wx += STEP {
				tl := tl_t(wx)
				// tempo na FONTE nas duas bordas desta coluna (respeita o in_off do corte)
				ta := (tl             - sg.start) * seg_speed(i) + sg.in_off
				tb := (tl_t(wx + STEP) - sg.start) * seg_speed(i) + sg.in_off
				p := wave_peak(c, ta, tb)
				if p < 0 { // ainda calculando: fio esmaecido na base
					rl.DrawRectangleRec({wx, base - 3, STEP, 3}, rl.Color{70, 100, 92, 130})
				} else {
					// DUAS camadas (estilo NLE): contorno do PICO em tom claro/translúcido e o
					// corpo do RMS sólido por cima. Só o pico virava um bloco cheio em música
					// comprimida (pico ~1.0 em todo bucket); o RMS é que mostra a dinâmica.
					// A altura reflete o GANHO (volume × fade × mudo): baixar o volume encolhe
					// a onda, que também afina ao longo das rampas de fade.
					g := clamp(seg_gain(i, tl), 0, 1)
					hp := max(f32(1), clamp(p * g, 0, 1) * amp)
					rl.DrawRectangleRec({wx, base - hp, STEP, hp}, pcol)
					if rms := wave_rms_at(c, ta, tb); rms > 0 {
						hr := max(f32(1), min(clamp(rms * WAVE_RMS_GAIN * g, 0, 1) * amp, hp))
						rl.DrawRectangleRec({wx, base - hr, STEP, hr}, wcol)
					}
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
		if i > 0 do rl.DrawLineEx({x, track_y(sg.track)}, {x, track_y(sg.track) + th(sg.track)}, 1, rl.Color{20,22,27,255})
	}

	// SEGUNDO PASSO: indicadores de transição/fade POR CIMA de todos os blocos (senão um
	// clipe vizinho desenhado depois cobriria o indicador do corte). Cada um tem X p/ REMOVER.
	for i in 0 ..< nsegs {
		if !seg_ready(i) do continue
		sg := &segs[i]
		x := tl_x(sg.start); w := sg.dur * pps()
		vr := rl.Rectangle{ x, track_y(sg.track) + 4, w, th(sg.track) - 8 }
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
				if xbtn({ cut - 7, vr.y + 2, 14, 14 }) {
					if track_locked[segs[i].track] { set_toast("Trilha bloqueada") }
					else { segs[i].trans = 0; sel_trans = -1; set_toast("Transição removida") }
					consumed = true
				}
				if !consumed && !track_locked[segs[i].track] && st.drag == .None && rl.IsMouseButtonPressed(.LEFT) && (hovered(eL) || hovered(eR)) {
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
				if xbtn({ vr.x + 3, vr.y + 3, 14, 14 }) {
					if track_locked[segs[i].track] { set_toast("Trilha bloqueada") }
					else { segs[i].vfin = 0; sel_trans = -1; set_toast("Fade de entrada removido") }
					consumed = true
				}
			}
			if hg || is_sel do ew_cursor = true
			if !consumed && !track_locked[segs[i].track] && st.drag == .None && rl.IsMouseButtonPressed(.LEFT) && hovered(grip) {
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
				if xbtn({ reg.x + fw2 - 17, vr.y + 3, 14, 14 }) {
					if track_locked[segs[i].track] { set_toast("Trilha bloqueada") }
					else { segs[i].vfout = 0; sel_trans = -1; set_toast("Fade de saída removido") }
					consumed = true
				}
			}
			if hg || is_sel do ew_cursor = true
			if !consumed && !track_locked[segs[i].track] && st.drag == .None && rl.IsMouseButtonPressed(.LEFT) && hovered(grip) {
				sel_trans = i; sel_trans_kind = 2; selected = -1; bin_sel = -1
				st.drag = .TransDur; drag_clip = i; consumed = true
			}
		}
	}

	// TRILHA TRAVADA: hachura diagonal sobre os clipes (aparência de bloqueio, estilo NLE)
	for i in 0 ..< nsegs {
		if !seg_ready(i) || !track_locked[segs[i].track] do continue
		hvr := rl.Rectangle{ tl_x(segs[i].start), track_y(segs[i].track) + 4, segs[i].dur*pps(), th(segs[i].track) - 8 }
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
		// TESOURA no playhead (estilo NLE): corta tudo que estiver sob ele, sem precisar
		// da tecla S nem de ligar a lâmina. Só aparece quando HÁ o que cortar (algum segmento
		// destravado cruzando o playhead) — botão morto confunde mais do que ajuda.
		if !blade_mode && st.drag == .None && modal == .None {
			cutable := false
			for i in 0 ..< nsegs {
				if !seg_ready(i) || track_locked[segs[i].track] do continue
				if st.playhead > segs[i].start + 0.05 && st.playhead < segs[i].start + segs[i].dur - 0.05 { cutable = true; break }
			}
			if cutable {
				cut_r := rl.Rectangle{ px - 11, rows_top - 26, 22, 22 } // logo acima das trilhas, na linha
				bh := hovered(cut_r)
				rl.DrawCircleV({ px, cut_r.y + 11 }, 11, bh ? rl.Color{ 245, 120, 110, 255 } : PLAYHEAD)
				sc := rl.WHITE
				rl.DrawLineEx({ px - 4, cut_r.y + 5 }, { px + 5, cut_r.y + 14 }, 1.7, sc) // lâminas em X
				rl.DrawLineEx({ px + 4, cut_r.y + 5 }, { px - 5, cut_r.y + 14 }, 1.7, sc)
				rl.DrawCircleLinesV({ px - 4, cut_r.y + 16 }, 2.6, sc)                    // cabos
				rl.DrawCircleLinesV({ px + 4, cut_r.y + 16 }, 2.6, sc)
				if bh do rl.SetMouseCursor(.POINTING_HAND)
				if clicked(cut_r) do split_at_playhead()
			}
		}
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

	// barra de rolagem VERTICAL: só o DESENHO (o clique foi tratado lá em cima, antes do laço
	// de segmentos). Aqui já não há scissor ativo e nada mais é desenhado sobre as trilhas,
	// então a barra fica por cima dos clipes em vez de sumir debaixo deles.
	if vsb_track.width > 0 {
		rl.DrawRectangleRounded(vsb_track, 1, 4, rl.Color{20, 22, 27, 255})
		rl.DrawRectangleRounded(vsb_thumb, 1, 4, (tl_vbar_drag || hovered(vsb_thumb)) ? ACCENT : rl.Color{70, 76, 88, 255})
	}

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
	if modal == .None && !blade_mode && rl.IsMouseButtonPressed(.LEFT) && st.drag == .None && !consumed {
		mp := rl.GetMousePosition()
		// alças de áudio do segmento SELECIONADO têm prioridade sobre mover/aparar
		near :: proc(a, b: rl.Vector2) -> bool { return abs(a.x-b.x) < 8 && abs(a.y-b.y) < 8 }
		if selected >= 0 && seg_ready(selected) && !track_locked[segs[selected].track] {
			if g_sel_fi.x >= 0 && near(mp, g_sel_fi) {
				st.drag = .FadeIn; drag_clip = selected; consumed = true
			} else if g_sel_fo.x >= 0 && near(mp, g_sel_fo) {
				st.drag = .FadeOut; drag_clip = selected; consumed = true
			} else if g_sel_volbar.width > 0 && hovered(g_sel_volbar) {
				st.drag = .Vol; drag_clip = selected; consumed = true
			}
		}
	}
	if modal == .None && !blade_mode && rl.IsMouseButtonPressed(.LEFT) && st.drag == .None && !consumed {
		mp := rl.GetMousePosition()
		hit := -1
		edge := 0
		// SÓ o que está VISÍVEL pode ser agarrado. Com rolagem vertical ativa, `track_y` devolve
		// posições fora do viewport: sem o gate em `vlane` (e o mesmo culling do desenho), um
		// clipe rolado p/ fora cobria a régua e as bandas "+ trilha" e roubava o clique — clicar
		// na régua p/ mover o playhead começava a arrastar um bloco invisível.
		if rl.CheckCollisionPointRec(mp, vlane) do for i in 0 ..< nsegs {
			if !seg_ready(i) do continue
			x := tl_x(segs[i].start)
			w := segs[i].dur * pps()
			cr := rl.Rectangle{ x, track_y(segs[i].track) + 4, w, th(segs[i].track) - 8 }
			if cr.y + cr.height < rows_clip.y || cr.y > rows_clip.y + rows_clip.height do continue // fora da viewport
			if rl.CheckCollisionPointRec(mp, cr) {
				// se dois retângulos cobrirem o ponto (gap 0, overlap), ganha o de CIMA na tela
				if hit >= 0 && track_row(segs[i].track) >= track_row(segs[hit].track) do continue
				hit = i
				// perto de uma borda (e o segmento largo o bastante) -> aparar
				if w > 16 {
					if mp.x - x < 6 do edge = -1
					else if (x + w) - mp.x < 6 do edge = 1
				}
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
		if st.drag != .None && st.playing {
			// Stop de todo mundo (não só o master): Pause deixava ~0.7s de
			// secundário/spv por cima do seek. play_clip=-1 evita o Update
			// do rodapé reencher o buffer velho durante o arrasto.
			hush_all_music()
			seek_rearm_si = -1
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
				sr := rl.Rectangle{ tl_x(segs[i].start), track_y(segs[i].track) + 4, segs[i].dur*pps(), th(segs[i].track) - 8 }
				// mesmo culling do hit-test: um segmento rolado p/ fora da vista não pode ser
				// marcado por um retângulo que o usuário desenhou sobre a régua/bandas
				if sr.y + sr.height < rows_clip.y || sr.y > rows_clip.y + rows_clip.height do continue
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

	// tooltips dos ícones: por cima da régua/trilhas, só no hover
	if hovered(cz) {
		tip: cstring = "Cortar e Ampliar"
		tw := txt_w(tip, 12) + 16
		tr := rl.Rectangle{ cz.x, cz.y + cz.height + 6, tw, 22 }
		rl.DrawRectangleRounded(tr, 0.3, 6, rl.Color{ 28, 30, 38, 240 })
		rl.DrawRectangleRoundedLinesEx(tr, 0.3, 6, 1, LINE)
		txt(tip, tr.x + 8, tr.y + 4, 12, TEXT)
	}
	if hovered(sz) {
		tip: cstring = "Detectar silêncio"
		tw := txt_w(tip, 12) + 16
		tr := rl.Rectangle{ sz.x, sz.y + sz.height + 6, tw, 22 }
		rl.DrawRectangleRounded(tr, 0.3, 6, rl.Color{ 28, 30, 38, 240 })
		rl.DrawRectangleRoundedLinesEx(tr, 0.3, 6, 1, LINE)
		txt(tip, tr.x + 8, tr.y + 4, 12, TEXT)
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

// HH:MM:SS:FF — FF segue o fps do clipe sob o playhead (fonte), senão 30
timecode :: proc(total: f32) -> cstring {
	fps := DEC_FPS
	if v := view_seg(); v >= 0 {
		if c := cfps_of(seg_src(v)); c > 0 do fps = c
	}
	s := int(total)
	f := int((total - f32(s)) * fps)
	return fmt.ctprintf("%02d:%02d:%02d:%02d", s/3600, (s%3600)/60, s%60, f)
}
