package main

import rl "vendor:raylib"
import "core:strconv"
import "core:strings"

// Estado de apresentação da sessão; não modifica o projeto.
insp_tab: int
insp_drawing: bool
insp_content: bool
insp_view: rl.Rectangle
insp_scroll: f32
insp_total: f32
insp_last_seg: int = -1
insp_last_tab: int = -1
insp_num_id: int = -1
insp_num_field: TField
insp_transform_open: bool = true
insp_crop_open: bool = true
insp_appearance_open: bool = true

inspector_clear_focus :: proc() {
	insp_num_id = -1
	txt_edit = false
	tf_text.drag = false
}

// Reserva espaço ANTES de calcular o canvas: os transforms continuam relativos
// ao quadro real. Em janela estreita o modo flutuante preserva o transporte.
inspector_layout :: proc(area: rl.Rectangle) -> rl.Rectangle {
	g_insp_card = {}
	floating := area.width < 860
	// Sem cabeçalho: vídeo e inspetor aproveitam toda a altura disponível.
	preview := area
	if fullscreen_preview || (floating && crop_mode) {
		inspector_clear_focus()
		return preview
	}
	if floating {
		g_insp_card = { preview.x + preview.width - 300, preview.y + 8, 288, max(f32(40), preview.height - 82) }
	} else {
		g_insp_card = { preview.x + preview.width - 300, preview.y, 300, preview.height - 6 }
		preview.width -= 300
	}
	return preview
}

inspector_section :: proc(label: cstring, x, y, w: f32) {
	txt(label, x, y + 3, 13, TEXT)
	lw := txt_w(label, 13)
	rl.DrawLineEx({ x + lw + 12, y + 11 }, { x + w, y + 11 }, 1, LINE)
}

// Cabeçalho independente da área de redefinição: recolher não altera o clipe.
inspector_group :: proc(label: cstring, x, y, w: f32, open: ^bool) -> bool {
	bar := rl.Rectangle{ x, y, w, 32 }
	rl.DrawRectangleRounded(bar, 0.15, 4, PANEL2)
	if clicked({ x, y, w - 76, 32 }) {
		open^ = !open^
		inspector_clear_focus()
	}
	txt(open^ ? "-" : "+", x + 9, y + 8, 14, MUTED)
	txt(label, x + 26, y + 8, 14, TEXT)
	return ui_btn({ x + w - 72, y + 3, 68, 26 }, "Redefinir", false)
}

// Campo numérico + slider. A digitação só altera o valor ao confirmar (Enter
// ou clique fora); Esc cancela. Não escreve valores intermediários no histórico.
inspector_value :: proc(id: int, box: rl.Rectangle, value: ^f32, lo, hi, factor: f32, unit: cstring) -> bool {
	changed := false
	on := insp_num_id == id
	if !on && clicked(box) {
		insp_num_id = id
		tf_set(&insp_num_field, string(rl.TextFormat("%.2f", value^ * factor)))
		insp_num_field.sel = 0
		on = true
	}
	rl.DrawRectangleRounded(box, 0.2, 4, PANEL2)
	if on && modal == .None && !ctx_open && !file_menu_open {
		focus := true
		tf_field(&insp_num_field, box, &focus, true)
		if !focus || rl.IsKeyPressed(.ENTER) {
			input := strings.trim_space(string(insp_num_field.buf[:insp_num_field.len]))
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
		txt_c(rl.TextFormat("%.2f%s", value^ * factor, unit), box.x + box.width/2, box.y + 7, 12, ACCENT)
	}
	rl.DrawRectangleRoundedLinesEx(box, 0.2, 4, 1, on ? ACCENT : LINE)
	return changed
}

inspector_row :: proc(id: int, label: cstring, x, y, w: f32, value: ^f32, lo, hi: f32, factor: f32 = 1, unit: cstring = "") -> bool {
	txt(label, x, y + 7, 13, TEXT)
	changed := inspector_value(id, { x + w - 88, y, 88, 28 }, value, lo, hi, factor, unit)
	if ui_slider(id, { x, y + 32, w, 16 }, value, lo, hi) do changed = true
	return changed
}

inspector_controls :: proc(body: rl.Rectangle) -> f32 {
	sg := &segs[selected]
	c := seg_src(selected)
	x := body.x + 14
	w := body.width - 36
	top := body.y - insp_scroll
	y := top + 12
	if c.is_text {
		// Reutiliza os controles de texto/legendas, agora recortados e roláveis.
		card := rl.Rectangle{ body.x, top - 20, body.width - 8, 440 }
		if c.is_caps do draw_caps_inspector(c, sg, card, x, 14, card.width)
		else do draw_text_inspector(c, sg, card, x, 14, card.width)
		return c.is_caps ? 410 : 380
	}
	if insp_tab == 0 {
		if c.is_audio || sg.aonly {
			txt("Este clipe não contém vídeo.", x, y, 13, MUTED)
			return 48
		}
		if inspector_group("Transformação", x, y, w, &insp_transform_open) {
			inspector_clear_focus()
			sg.scale = 1
			sg.px = 0
			sg.py = 0
			sg.rot = 0
		}
		y += 42
		if insp_transform_open {
			inspector_row(4, "Escala", x, y, w, &sg.scale, 0.1, 3, 100, "%")
			y += 58
			txt("Posição", x, y, 13, TEXT)
			y += 24
			half := (w - 12)/2
			txt("X", x, y + 8, 13, MUTED)
			inspector_value(5, { x + 20, y, half - 20, 28 }, &sg.px, -1, 1, 100, "%")
			txt("Y", x + half + 12, y + 8, 13, MUTED)
			inspector_value(6, { x + half + 32, y, half - 20, 28 }, &sg.py, -1, 1, 100, "%")
			ui_slider(5, { x, y + 32, half, 16 }, &sg.px, -1, 1)
			ui_slider(6, { x + half + 12, y + 32, half, 16 }, &sg.py, -1, 1)
			y += 58
			inspector_row(7, "Rotação", x, y, w, &sg.rot, -180, 180, 1, "°")
			y += 64
		}
		if inspector_group("Recorte", x, y, w, &insp_crop_open) {
			inspector_clear_focus()
			sg.crop_x = 0
			sg.crop_y = 0
			sg.crop_w = 0
			sg.crop_h = 0
		}
		y += 42
		if insp_crop_open {
			txt(seg_cropped(selected) ? "Recorte personalizado" : "Quadro completo", x, y, 13, MUTED)
			y += 24
			if ui_btn({ x, y, w, 32 }, seg_cropped(selected) ? "Editar recorte na prévia" : "Recortar na prévia", seg_cropped(selected)) {
				set_crop_mode(true)
				if !seg_cropped(selected) {
					sg.crop_x = 0
					sg.crop_y = 0
					sg.crop_w = 1
					sg.crop_h = 1
				}
			}
			y += 44
		}
		if inspector_group("Aparência", x, y, w, &insp_appearance_open) {
			inspector_clear_focus()
			sg.opacity = 1
			sg.vfin = 0
			sg.vfout = 0
		}
		y += 42
		if insp_appearance_open {
			inspector_row(8, "Opacidade", x, y, w, &sg.opacity, 0, 1, 100, "%")
			y += 58
			fmax := max(f32(0.2), sg.dur * 0.9)
			if sg.vfin > 0.01 {
				inspector_row(14, "Fade entrada", x, y, w, &sg.vfin, 0, fmax, 1, "s")
				y += 58
			}
			if sg.vfout > 0.01 {
				inspector_row(15, "Fade saída", x, y, w, &sg.vfout, 0, fmax, 1, "s")
				y += 58
			}
		}
	} else if insp_tab == 2 {
		if c.is_img {
			txt("Imagem não possui velocidade.", x, y, 13, MUTED)
			return 48
		}
		inspector_section("Velocidade", x, y, w)
		y += 28
		speed := sg.speed <= 0 ? f32(1) : sg.speed
		changed := inspector_row(9, "Reprodução", x, y, w, &speed, 0.25, 4, 1, "x")
		y += 56
		presets := [3]f32{ 0.5, 1, 2 }
		labels := [3]cstring{ "0.5x", "1x", "2x" }
		bw := (w - 12)/3
		for preset, i in presets {
			if ui_btn({ x + f32(i)*(bw + 6), y, bw, 28 }, labels[i], abs(speed - preset) < 0.001) {
				speed = preset
				changed = true
			}
		}
		if changed do apply_seg_speed(selected, speed)
		y += 40
		txt("Duração", x, y, 13, TEXT)
		txt(timecode(sg.dur), x + w - 92, y, 13, MUTED)
		y += 28
		txt("Muda o tom do áudio.", x, y, 12, MUTED)
		y += 24
	} else {
		if !c.has_audio {
			txt("Este clipe não contém áudio.", x, y, 13, MUTED)
			return 48
		}
		inspector_section("Áudio", x, y, w)
		y += 28
		inspector_row(1, "Volume", x, y, w, &sg.vol, 0, VOL_MAX, 100, "%")
		y += 56
		bw := (w - 8)/2
		if ui_btn({ x, y, bw, 28 }, sg.muted ? "Reativar som" : "Mudo", sg.muted) do sg.muted = !sg.muted
		if ui_btn({ x + bw + 8, y, bw, 28 }, "Redefinir", false) {
			sg.vol = 1
			sg.muted = false
			sg.fade_in = 0
			sg.fade_out = 0
		}
		y += 40
		inspector_section("Fades de áudio", x, y, w)
		y += 28
		fmax := max(f32(0.1), min(f32(5), sg.dur * 0.5))
		inspector_row(2, "Entrada", x, y, w, &sg.fade_in, 0, fmax, 1, "s")
		y += 56
		inspector_row(3, "Saída", x, y, w, &sg.fade_out, 0, fmax, 1, "s")
		y += 56
	}
	return y - top + 12
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
		txt("Inspetor", area.x + 14, area.y + 14, 15, TEXT)
		msg: cstring = crop_mode ? "Conclua o recorte na prévia." : "Selecione um clipe na timeline."
		txt(msg, area.x + 14, area.y + 50, 13, MUTED)
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
	if !c.is_text || c.is_caps do txt_edit = false
	rl.DrawRectangleRec({ area.x + 1, area.y + 1, area.width - 2, 86 }, PANEL2)
	txt("Inspetor", area.x + 14, area.y + 12, 16, TEXT)
	kind: cstring = c.is_text ? (c.is_caps ? "LEGENDAS" : "TEXTO") : ((c.is_audio || segs[selected].aonly) ? "ÁUDIO" : (c.is_img ? "IMAGEM" : "VÍDEO"))
	txt(kind, area.x + area.width - 84, area.y + 15, 11, ACCENT)
	txt(elide(c.name, 14, area.width - 28), area.x + 14, area.y + 39, 14, TEXT)
	txt("Clipe selecionado", area.x + 14, area.y + 62, 12, MUTED)
	body := rl.Rectangle{ area.x + 1, area.y + 94, area.width - 2, max(f32(1), area.height - 102) }
	if !c.is_text {
		tabs := [3]cstring{ "Vídeo", "Áudio", "Velocidade" }
		tw := (area.width - 16)/3
		for tab, i in tabs {
			r := rl.Rectangle{ area.x + 8 + f32(i)*tw, area.y + 92, tw, 34 }
			active := insp_tab == i
			if active || hovered(r) do rl.DrawRectangleRounded(r, 0.15, 4, PANEL2)
			txt_c(tab, r.x + tw/2, r.y + 9, 14, active ? TEXT : MUTED)
			if active do rl.DrawRectangleRec({ r.x + 10, r.y + 32, tw - 20, 2 }, ACCENT)
			if clicked(r) && insp_tab != i {
				insp_tab = i
				insp_last_tab = i
				insp_scroll = 0
				insp_total = 0
				inspector_clear_focus()
			}
		}
		body.y += 42
		body.height = max(f32(1), body.height - 42)
	}
	rl.DrawLineEx({ body.x, body.y - 1 }, { body.x + body.width, body.y - 1 }, 1, LINE)
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
		rl.DrawRectangleRounded({ body.x + body.width - 7, body.y, 3, body.height }, 1, 4, PANEL2)
		rl.DrawRectangleRounded({ body.x + body.width - 7, sy, 3, h }, 1, 4, MUTED)
	}
}