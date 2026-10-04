package main

import rl "vendor:raylib"
import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"

// Estado de apresentação da sessão; não modifica o projeto.
insp_tab: int
insp_drawing: bool
insp_content: bool
insp_view: rl.Rectangle
insp_video_inset: f32 // largura tirada da área do vídeo pelo cartão flutuante
insp_scroll: f32
insp_total: f32
insp_last_seg: int = -1
insp_last_tab: int = -1
insp_num_id: int = -1
insp_num_field: TField
insp_transform_open: bool = true
insp_crop_open: bool = true
insp_appearance_open: bool = true
insp_volume_open: bool = true
insp_afade_open: bool = true
insp_speed_open: bool = true

// geometria das linhas "rótulo · slider · valor"
INSP_PAD     :: f32(16) // margem lateral do conteúdo (simétrica; a barra de rolagem cabe nela)
INSP_LABEL_W :: f32(80)
INSP_FIELD_W :: f32(72)
INSP_ROW_H   :: f32(26)
INSP_ROW_GAP :: f32(10)
INSP_HDR_H   :: f32(34)

inspector_clear_focus :: proc() {
	insp_num_id = -1
	txt_edit = false
	tf_text.drag = false
}

// Reserva espaço ANTES de calcular o canvas: os transforms continuam relativos
// ao quadro real. Em janela estreita o modo flutuante preserva o transporte.
inspector_layout :: proc(area: rl.Rectangle) -> rl.Rectangle {
	g_insp_card = {}
	insp_video_inset = 0
	floating := area.width < 860
	// Sem cabeçalho: vídeo e inspetor aproveitam toda a altura disponível.
	preview := area
	if fullscreen_preview || (floating && crop_mode) {
		inspector_clear_focus()
		return preview
	}
	if floating {
		g_insp_card = { preview.x + preview.width - 300, preview.y + 8, 288, max(f32(40), preview.height - 82) }
		// O transporte segue com a largura toda; só o canvas encolhe para não ficar atrás do cartão.
		insp_video_inset = 308
	} else {
		g_insp_card = { preview.x + preview.width - 300, preview.y, 300, preview.height - 6 }
		preview.width -= 300
	}
	return preview
}

// chevron desenhado (a fonte não garante ▾/▸): aberto aponta p/ baixo, fechado p/ a direita
inspector_chevron :: proc(cx, cy: f32, open: bool, col: rl.Color) {
	if open {
		rl.DrawLineEx({ cx - 4, cy - 2 }, { cx, cy + 2 }, 1.8, col)
		rl.DrawLineEx({ cx, cy + 2 }, { cx + 4, cy - 2 }, 1.8, col)
	} else {
		rl.DrawLineEx({ cx - 2, cy - 4 }, { cx + 2, cy }, 1.8, col)
		rl.DrawLineEx({ cx + 2, cy }, { cx - 2, cy + 4 }, 1.8, col)
	}
}

// ↺: arco aberto no alto-direito com a ponta seguindo no sentido anti-horário
inspector_reset_icon :: proc(cx, cy: f32, col: rl.Color) {
	R :: f32(5.5)
	rl.DrawRing({ cx, cy }, R - 0.9, R + 0.9, -50, 230, 24, col)
	a := f32(-50) * rl.DEG2RAD
	p := rl.Vector2{ cx + R*math.cos(a), cy + R*math.sin(a) }
	n := rl.Vector2{ math.cos(a), math.sin(a) }  // normal (radial)
	t := rl.Vector2{ math.sin(a), -math.cos(a) } // tangente no sentido anti-horário
	draw_tri2(p + t*4, p + n*3.2, p - n*3.2, col)
}

// Cabeçalho de grupo: só texto + chevron (fundo apenas no hover) e um filete separando
// do grupo anterior — barras cheias em todo grupo pesavam mais que os próprios controles.
// Recolher não altera o clipe. `dirty` = algum valor do grupo saiu do padrão; só então o
// ↺ aparece (e responde ao clique). Retorna true no clique do ↺.
inspector_group :: proc(label: cstring, x, y, w: f32, open: ^bool, dirty: bool, first := false) -> bool {
	if !first do rl.DrawLineEx({ x, y }, { x + w, y }, 1, SEP)
	bar := rl.Rectangle{ x - 6, y + 3, w + 12, INSP_HDR_H - 6 }
	reset := rl.Rectangle{ x + w - 24, y + 5, 24, 24 }
	toggle := dirty ? rl.Rectangle{ bar.x, bar.y, bar.width - 30, bar.height } : bar
	hot := hovered(toggle)
	if hot do rl.DrawRectangleRounded(bar, 0.25, 4, alpha(HOVER, 110))
	if clicked(toggle) {
		open^ = !open^
		inspector_clear_focus()
	}
	inspector_chevron(x + 5, y + INSP_HDR_H/2, open^, hot ? TEXT : MUTED)
	txt(label, x + 18, y + 9, FS_MD, TEXT)
	if !dirty do return false
	rhot := hovered(reset)
	if rhot {
		rl.DrawRectangleRounded(reset, 0.3, 4, HOVER)
		lw := txt_w("Redefinir", FS_SM)
		txt("Redefinir", reset.x - lw - 6, y + 10, FS_SM, ACCENT)
	}
	inspector_reset_icon(reset.x + 12, reset.y + 12, rhot ? ACCENT : MUTED)
	return clicked(reset)
}

// número com `dec` casas, sem "-0" (arredondar -0.004 mostrava "-0.00")
inspector_fmt :: proc(v: f32, dec: int) -> string {
	q := v
	if abs(q) < 0.5 * math.pow(f32(10), f32(-dec)) do q = 0
	switch dec {
	case 0: return fmt.tprintf("%.0f", q)
	case 1: return fmt.tprintf("%.1f", q)
	}
	return fmt.tprintf("%.2f", q)
}

// Campo numérico. A digitação só altera o valor ao confirmar (Enter ou clique fora);
// Esc cancela. Não escreve valores intermediários no histórico. Em repouso mostra o
// número alinhado à direita (dígitos tabulares: não dança ao arrastar) com a unidade apagada.
inspector_value :: proc(id: int, box: rl.Rectangle, value: ^f32, lo, hi, factor: f32, dec: int, unit: cstring) -> bool {
	changed := false
	on := insp_num_id == id
	hot := hovered(box)
	if !on && clicked(box) {
		insp_num_id = id
		tf_set(&insp_num_field, inspector_fmt(value^ * factor, dec))
		insp_num_field.sel = 0
		on = true
	}
	rl.DrawRectangleRounded(box, 0.25, 4, SUNK)
	if on && modal == .None && !ctx_open && !file_menu_open {
		focus := true
		tf_field(&insp_num_field, box, &focus, true)
		if !focus || rl.IsKeyPressed(.ENTER) {
			input := strings.trim_space(string(insp_num_field.buf[:insp_num_field.len]))
			input = strings.trim_right(input, "%°xs ")
			if n, ok := strconv.parse_f32(input); ok && n == n && abs(n) < 1e9 {
				next := clamp(n / factor, lo, hi)
				changed = next != value^
				value^ = next
			} else {
				set_toast("Valor inválido. Use um número com ponto decimal.")
			}
			insp_num_id = -1
		}
	} else {
		num := inspector_fmt(value^ * factor, dec)
		uw := unit == "" ? 0 : txt_w(unit, FS_SM) + 2
		nw := txt_tab(num, 0, 0, FS_MD, TEXT, false)
		nx := box.x + box.width - 8 - uw - nw
		txt_tab(num, nx, box.y + 5, FS_MD, TEXT)
		if unit != "" do txt(unit, nx + nw + 2, box.y + 6, FS_SM, MUTED)
	}
	border := on ? ACCENT : (hot ? GRIP : LINE)
	rl.DrawRectangleRoundedLinesEx(box, 0.25, 4, 1, border)
	return changed
}

// coluna dos rótulos: mede o mais largo em vez de um fixo — a fonte escala com g_us,
// a geometria não, e num monitor com escala alta "Reprodução" encostava no slider.
// Igual em todas as linhas para os sliders ficarem alinhados.
inspector_label_w :: proc() -> f32 {
	return max(INSP_LABEL_W, txt_w("Fade entrada", FS_MD) + 12)
}

// Linha única: rótulo à esquerda, slider no meio, campo à direita.
inspector_row :: proc(id: int, label: cstring, x, y, w: f32, value: ^f32, lo, hi: f32, factor: f32 = 1, dec := 2, unit: cstring = "") -> bool {
	txt(label, x, y + 5, FS_MD, MUTED)
	changed := inspector_value(id, { x + w - INSP_FIELD_W, y, INSP_FIELD_W, INSP_ROW_H }, value, lo, hi, factor, dec, unit)
	lw := inspector_label_w()
	if ui_slider(id, { x + lw, y + 5, max(f32(24), w - lw - INSP_FIELD_W - 14), 16 }, value, lo, hi) do changed = true
	return changed
}

// rótulo + valor só leitura (sem controle)
inspector_info :: proc(label, value: cstring, x, y, w: f32) {
	txt(label, x, y + 5, FS_MD, MUTED)
	txt(value, x + w - txt_w(value, FS_MD), y + 5, FS_MD, TEXT)
}

ROW_STEP :: INSP_ROW_H + INSP_ROW_GAP

inspector_controls :: proc(body: rl.Rectangle) -> f32 {
	sg := &segs[selected]
	c := seg_src(selected)
	x := body.x + INSP_PAD
	w := body.width - 2*INSP_PAD
	top := body.y - insp_scroll
	y := top + 6
	if c.is_text {
		// Reutiliza os controles de texto/legendas, agora recortados e roláveis.
		card := rl.Rectangle{ body.x, top - 20, body.width - 8, 440 }
		if c.is_caps do draw_caps_inspector(c, sg, card, x, 14, card.width)
		else do draw_text_inspector(c, sg, card, x, 14, card.width)
		return c.is_caps ? 410 : 380
	}
	if insp_tab == 0 {
		if c.is_audio || sg.aonly {
			txt("Este clipe não contém vídeo.", x, y + 8, FS_MD, MUTED)
			return 48
		}
		if inspector_group("Transformação", x, y, w, &insp_transform_open, sg.scale != 1 || sg.px != 0 || sg.py != 0 || sg.rot != 0, true) {
			inspector_clear_focus()
			sg.scale = 1
			sg.px = 0
			sg.py = 0
			sg.rot = 0
		}
		y += INSP_HDR_H + 4
		if insp_transform_open {
			inspector_row(4, "Escala", x, y, w, &sg.scale, 0.1, 3, 100, 0, "%")
			y += ROW_STEP
			inspector_row(5, "Posição X", x, y, w, &sg.px, -1, 1, 100, 1, "%")
			y += ROW_STEP
			inspector_row(6, "Posição Y", x, y, w, &sg.py, -1, 1, 100, 1, "%")
			y += ROW_STEP
			inspector_row(7, "Rotação", x, y, w, &sg.rot, -180, 180, 1, 1, "°")
			y += ROW_STEP + 4
		}
		if inspector_group("Recorte", x, y, w, &insp_crop_open, seg_cropped(selected)) {
			inspector_clear_focus()
			sg.crop_x = 0
			sg.crop_y = 0
			sg.crop_w = 0
			sg.crop_h = 0
		}
		y += INSP_HDR_H + 4
		if insp_crop_open {
			inspector_info("Área", seg_cropped(selected) ? "Personalizada" : "Quadro completo", x, y, w)
			y += ROW_STEP
			if ui_btn({ x, y, w, 30 }, seg_cropped(selected) ? "Editar recorte na prévia" : "Recortar na prévia", false) {
				set_crop_mode(true)
				if !seg_cropped(selected) {
					sg.crop_x = 0
					sg.crop_y = 0
					sg.crop_w = 1
					sg.crop_h = 1
				}
			}
			y += 30 + INSP_ROW_GAP + 4
		}
		if inspector_group("Aparência", x, y, w, &insp_appearance_open, sg.opacity != 1 || sg.vfin != 0 || sg.vfout != 0) {
			inspector_clear_focus()
			sg.opacity = 1
			sg.vfin = 0
			sg.vfout = 0
		}
		y += INSP_HDR_H + 4
		if insp_appearance_open {
			inspector_row(8, "Opacidade", x, y, w, &sg.opacity, 0, 1, 100, 0, "%")
			y += ROW_STEP
			fmax := max(f32(0.2), sg.dur * 0.9)
			if sg.vfin > 0.01 {
				inspector_row(14, "Fade entrada", x, y, w, &sg.vfin, 0, fmax, 1, 2, "s")
				y += ROW_STEP
			}
			if sg.vfout > 0.01 {
				inspector_row(15, "Fade saída", x, y, w, &sg.vfout, 0, fmax, 1, 2, "s")
				y += ROW_STEP
			}
		}
	} else if insp_tab == 2 {
		if c.is_img {
			txt("Imagem não possui velocidade.", x, y + 8, FS_MD, MUTED)
			return 48
		}
		speed := sg.speed <= 0 ? f32(1) : sg.speed
		changed := false
		if inspector_group("Velocidade", x, y, w, &insp_speed_open, abs(speed - 1) > 0.001, true) {
			inspector_clear_focus()
			speed = 1
			changed = true
		}
		y += INSP_HDR_H + 4
		if insp_speed_open {
			if inspector_row(9, "Reprodução", x, y, w, &speed, 0.25, 4, 1, 2, "x") do changed = true
			y += ROW_STEP
			presets := [4]f32{ 0.5, 1, 1.5, 2 }
			labels := [4]cstring{ "0.5x", "1x", "1.5x", "2x" }
			bw := (w - 3*6)/4
			for preset, i in presets {
				if ui_btn({ x + f32(i)*(bw + 6), y, bw, 28 }, labels[i], abs(speed - preset) < 0.001) {
					speed = preset
					changed = true
				}
			}
			y += 28 + INSP_ROW_GAP + 4
			inspector_info("Duração", timecode(sg.dur), x, y, w)
			y += ROW_STEP - 6
			txt("Alterar a velocidade muda o tom do áudio.", x, y, FS_SM, MUTED)
			y += 24
		}
		if changed do apply_seg_speed(selected, speed)
	} else {
		if !c.has_audio {
			txt("Este clipe não contém áudio.", x, y + 8, FS_MD, MUTED)
			return 48
		}
		if inspector_group("Volume", x, y, w, &insp_volume_open, sg.vol != 1 || sg.muted, true) {
			inspector_clear_focus()
			sg.vol = 1
			sg.muted = false
		}
		y += INSP_HDR_H + 4
		if insp_volume_open {
			inspector_row(1, "Volume", x, y, w, &sg.vol, 0, VOL_MAX, 100, 0, "%")
			y += ROW_STEP
			if ui_btn({ x, y, w, 30 }, sg.muted ? "Mudo — clique para reativar" : "Silenciar clipe", sg.muted) do sg.muted = !sg.muted
			y += 30 + INSP_ROW_GAP + 4
		}
		if inspector_group("Fades", x, y, w, &insp_afade_open, sg.fade_in != 0 || sg.fade_out != 0) {
			inspector_clear_focus()
			sg.fade_in = 0
			sg.fade_out = 0
		}
		y += INSP_HDR_H + 4
		if insp_afade_open {
			fmax := max(f32(0.1), min(f32(5), sg.dur * 0.5))
			inspector_row(2, "Entrada", x, y, w, &sg.fade_in, 0, fmax, 1, 2, "s")
			y += ROW_STEP
			inspector_row(3, "Saída", x, y, w, &sg.fade_out, 0, fmax, 1, 2, "s")
			y += ROW_STEP
		}
	}
	return y - top + 12
}

// selo do tipo do clipe (pílula accent sobre fundo escuro), alinhado à direita em `right`
inspector_kind_pill :: proc(kind: cstring, right, y: f32) -> f32 {
	pw := txt_w(kind, FS_XS) + 14
	r := rl.Rectangle{ right - pw, y, pw, 18 }
	rl.DrawRectangleRounded(r, 1, 8, ACCENT_BG)
	txt_c(kind, r.x + pw/2, r.y + 2, FS_XS, ACCENT)
	return pw
}

draw_seg_inspector :: proc(area: rl.Rectangle) {
	if area.width <= 0 || area.height <= 0 do return
	insp_drawing = true
	defer insp_drawing = false
	rl.DrawRectangleRec(area, PANEL)
	rl.DrawRectangleLinesEx(area, 1, LINE)
	valid := selected >= 0 && selected < nsegs && seg_ready(selected)
	if !valid || src_preview >= 0 || crop_mode {
		inspector_clear_focus()
		insp_last_seg = -1
		txt("Inspetor", area.x + INSP_PAD, area.y + 14, FS_LG, TEXT)
		msg: cstring = crop_mode ? "Conclua o recorte na prévia." : "Selecione um clipe na timeline."
		txt(msg, area.x + INSP_PAD, area.y + 46, FS_MD, MUTED)
		return
	}
	if insp_last_seg != selected || insp_last_tab != insp_tab {
		insp_scroll = 0
		insp_total = 0
		inspector_clear_focus()
		insp_last_seg = selected
		insp_last_tab = insp_tab
	}
	c := seg_src(selected)
	sg := &segs[selected]
	if !c.is_text || c.is_caps do txt_edit = false

	// cabeçalho: nome do clipe + selo do tipo; abaixo, o que ajuda a reconhecê-lo
	// (resolução e duração) em vez de um "Clipe selecionado" que não dizia nada.
	has_tabs := !c.is_text
	hdr_h := f32(has_tabs ? 102 : 60)
	rl.DrawRectangleRec({ area.x + 1, area.y + 1, area.width - 2, hdr_h - 1 }, PANEL2)
	rl.DrawLineEx({ area.x + 1, area.y + hdr_h }, { area.x + area.width - 1, area.y + hdr_h }, 1, LINE)
	is_aud := c.is_audio || sg.aonly
	kind: cstring = c.is_text ? (c.is_caps ? "LEGENDAS" : "TEXTO") : (is_aud ? "ÁUDIO" : (c.is_img ? "IMAGEM" : "VÍDEO"))
	lx := area.x + INSP_PAD
	right := area.x + area.width - INSP_PAD
	pw := inspector_kind_pill(kind, right, area.y + 13)
	txt(elide(c.name, FS_MD, right - lx - pw - 10), lx, area.y + 13, FS_MD, TEXT)
	meta: cstring
	if !is_aud && !c.is_text && c.vw > 0 && c.vh > 0 {
		meta = fmt.ctprintf("%d×%d  ·  %s", c.vw, c.vh, timecode(sg.dur))
	} else {
		meta = timecode(sg.dur)
	}
	txt(meta, lx, area.y + 36, FS_SM, MUTED)

	body := rl.Rectangle{ area.x + 1, area.y + hdr_h + 1, area.width - 2, max(f32(1), area.height - hdr_h - 7) }
	if has_tabs {
		// controle segmentado: trilho rebaixado, aba ativa elevada
		tabs := [3]cstring{ "Vídeo", "Áudio", "Velocidade" }
		if i := ui_segmented({ area.x + 12, area.y + 62, area.width - 24, 30 }, tabs[:], insp_tab); i >= 0 {
			insp_tab = i
			insp_last_tab = i
			insp_scroll = 0
			insp_total = 0
			inspector_clear_focus()
		}
	}
	max_scroll := max(f32(0), insp_total - body.height)
	if hovered(body) && ui_slider_active < 0 && !rl.IsMouseButtonDown(.LEFT) {
		wheel := rl.GetMouseWheelMove()
		if wheel != 0 {
			insp_scroll -= wheel * 36
			inspector_clear_focus()
		}
	}
	insp_scroll = clamp(insp_scroll, 0, max_scroll)
	insp_view = body
	insp_content = true
	rl.BeginScissorMode(i32(body.x), i32(body.y), i32(body.width), i32(body.height))
	insp_total = inspector_controls(body)
	rl.EndScissorMode()
	insp_content = false
	if insp_total > body.height {
		h := max(f32(20), body.height * body.height / insp_total)
		sy := body.y + (body.height - h) * clamp(insp_scroll / (insp_total - body.height), 0, 1)
		rl.DrawRectangleRounded({ body.x + body.width - 7, body.y + 2, 3, body.height - 4 }, 1, 4, PANEL2)
		rl.DrawRectangleRounded({ body.x + body.width - 7, sy, 3, h }, 1, 4, GRIP)
	}
}
