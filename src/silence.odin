package main

import rl "vendor:raylib"
import "base:intrinsics"
import "core:math"

// Detecção de silêncio a partir da forma de onda já calculada (wave_rms).
// Sem ffmpeg extra: 100 buckets/s (WAVE_PPS) = resolução de 10 ms.

SIL_MAX :: 63
Silence :: struct { t0, t1: f32 } // segundos (fonte ou timeline, conforme o uso)
SilKeep :: struct { src0, src1, dur: f32 } // pedaço que FICA (tempos na FONTE)

sil_pct:  f32 = 25   // limite de volume (0–80%): abaixo disso = silêncio (estilo Filmora)
sil_min:  f32 = 0.50 // duração mínima do vão (s)
sil_pad:  f32 = 0.10 // buffer de suavização nas bordas
sil_hits: [SIL_MAX]Silence
sil_n:    int
sil_si:   int = -1
sil_keep: [SIL_MAX + 1]SilKeep
sil_nk:   int
sil_keep_total: f32
sil_done:  bool // já rodou "Começar" — o resultado está na faixa de baixo
sil_dirty: bool // sliders mudaram depois do último Começar
sil_play:  bool
sil_play_t: f32 // tempo no RESULTADO (silêncios já pulados)
sil_run_pct, sil_run_min, sil_run_pad: f32 // parâmetros do último Começar (é o que o Aplicar usa)
sil_eat: bool // ignora o clique que ABRIU o cartão (ainda está down no mesmo frame)

sil_thresh :: proc(pct: f32) -> f32 { return clamp(pct, 1, 90) / 100 }

// preenche `out` com intervalos de silêncio em [src0, src1] na fonte. Devolve a contagem.
detect_silences :: proc(c: ^Clip, src0, src1, thresh, min_dur, pad: f32, out: []Silence) -> int {
	if c == nil || !intrinsics.atomic_load(&c.wave_ready) || len(c.wave_rms) == 0 do return 0
	if src1 - src0 < min_dur || thresh <= 0 || len(out) == 0 do return 0
	n := len(c.wave_rms)
	i0 := clamp(int(src0 * WAVE_PPS), 0, n - 1)
	i1 := clamp(int(src1 * WAVE_PPS), 0, n - 1)
	if i1 < i0 do return 0
	nfound := 0
	run := -1
	flush :: proc(c: ^Clip, run, i, i0, i1: int, src0, src1, min_dur, pad: f32, out: []Silence, nfound: ^int) {
		if run < 0 || nfound^ >= len(out) do return
		a := f32(run) / WAVE_PPS
		b := f32(i) / WAVE_PPS
		a = max(a, src0); b = min(b, src1)
		if b - a < min_dur do return
		a += pad; b -= pad
		if b - a < 0.05 do return
		out[nfound^] = Silence{ a, b }
		nfound^ += 1
	}
	for i := i0; i <= i1; i += 1 {
		if c.wave_rms[i] < thresh {
			if run < 0 do run = i
		} else {
			flush(c, run, i, i0, i1, src0, src1, min_dur, pad, out, &nfound)
			run = -1
		}
	}
	flush(c, run, i1 + 1, i0, i1, src0, src1, min_dur, pad, out, &nfound)
	return nfound
}

// silêncios do segmento em tempo de TIMELINE (já dividido pela velocidade)
detect_seg_silences :: proc(si: int, thresh, min_dur, pad: f32, out: []Silence) -> int {
	if si < 0 || si >= nsegs || !seg_ready(si) do return 0
	sg := segs[si]
	c := seg_src(si)
	if !c.src_audio && !c.has_audio do return 0
	spd := seg_speed(si)
	src0 := sg.in_off
	src1 := sg.in_off + sg.dur * spd
	n := detect_silences(c, src0, src1, thresh, min_dur, pad, out)
	for k in 0 ..< n {
		out[k].t0 = sg.start + (out[k].t0 - sg.in_off) / spd
		out[k].t1 = sg.start + (out[k].t1 - sg.in_off) / spd
	}
	return n
}

sil_build_keeps :: proc(si: int, hits: []Silence, n: int) {
	sil_nk = 0; sil_keep_total = 0
	if si < 0 || si >= nsegs do return
	sg := segs[si]
	spd := seg_speed(si)
	src_end := sg.in_off + sg.dur * spd
	cur := sg.in_off
	add :: proc(src0, src1, spd: f32) {
		d := (src1 - src0) / spd
		if d < 0.02 || sil_nk >= len(sil_keep) do return
		sil_keep[sil_nk] = SilKeep{ src0, src1, d }
		sil_nk += 1
		sil_keep_total += d
	}
	for k in 0 ..< n {
		s0 := sg.in_off + (hits[k].t0 - sg.start) * spd
		s1 := sg.in_off + (hits[k].t1 - sg.start) * spd
		if s0 > cur + 0.02 do add(cur, s0, spd)
		cur = s1
	}
	if src_end > cur + 0.02 do add(cur, src_end, spd)
}

sil_run :: proc() {
	if sil_si < 0 || sil_si >= nsegs do return
	sil_n = detect_seg_silences(sil_si, sil_thresh(sil_pct), sil_min, sil_pad, sil_hits[:])
	sil_build_keeps(sil_si, sil_hits[:], sil_n)
	sil_done = true
	sil_dirty = false
	sil_play = false
	sil_play_t = 0
	sil_run_pct = sil_pct; sil_run_min = sil_min; sil_run_pad = sil_pad
}

sil_close :: proc() {
	modal = .None
	sil_n = 0; sil_nk = 0; sil_si = -1
	sil_done = false; sil_dirty = false; sil_play = false; sil_eat = false
}

// tempo da FONTE correspondente a `t` no resultado empacotado (silêncios pulados)
sil_src_at :: proc(t: f32) -> f32 {
	acc: f32 = 0
	for k in 0 ..< sil_nk {
		if t < acc + sil_keep[k].dur {
			spd := (sil_si >= 0 && sil_si < nsegs) ? seg_speed(sil_si) : f32(1)
			return sil_keep[k].src0 + (t - acc) * spd
		}
		acc += sil_keep[k].dur
	}
	if sil_nk > 0 do return sil_keep[sil_nk - 1].src1
	return 0
}

open_silence_modal :: proc() {
	if selected < 0 || selected >= nsegs { set_toast("Selecione um clipe com áudio"); return }
	if track_locked[segs[selected].track] { set_toast("Trilha bloqueada"); return }
	c := seg_src(selected)
	if c.is_text || (!c.src_audio && !c.has_audio) { set_toast("Este clipe não tem áudio"); return }
	if !intrinsics.atomic_load(&c.wave_ready) { set_toast("Aguarde a forma de onda terminar"); return }
	st.playing = false
	sil_done = false; sil_dirty = false; sil_play = false; sil_play_t = 0
	sil_n = 0; sil_nk = 0; sil_si = selected
	sil_eat = true // o clique do ícone ainda está down — não pode cair no cartão
	modal = .Silence
}

// reconstrói o segmento: tira os vãos de silêncio e fecha o buraco (ripple na trilha).
// Devolve quantos vãos foram removidos.
silence_apply_seg :: proc(si: int, thresh, min_dur, pad: f32) -> int {
	if si < 0 || si >= nsegs || track_locked[segs[si].track] do return 0
	found: [SIL_MAX]Silence
	n := detect_seg_silences(si, thresh, min_dur, pad, found[:])
	if n == 0 do return 0
	proto := segs[si]
	spd := seg_speed(si)
	// converte de volta p/ fonte p/ montar os pedaços que FICAM
	src_sils: [SIL_MAX]Silence
	for k in 0 ..< n {
		src_sils[k].t0 = proto.in_off + (found[k].t0 - proto.start) * spd
		src_sils[k].t1 = proto.in_off + (found[k].t1 - proto.start) * spd
	}
	src_end := proto.in_off + proto.dur * spd
	Keep :: struct { in_off, dur: f32 }
	keeps: [SIL_MAX + 1]Keep
	nk := 0
	cur := proto.in_off
	for k in 0 ..< n {
		if src_sils[k].t0 > cur + 0.02 {
			keeps[nk] = Keep{ cur, (src_sils[k].t0 - cur) / spd }
			nk += 1
		}
		cur = src_sils[k].t1
	}
	if src_end > cur + 0.02 {
		keeps[nk] = Keep{ cur, (src_end - cur) / spd }
		nk += 1
	}
	if nk == 0 {
		remove_seg(si, true, false)
		return n
	}
	if nsegs - 1 + nk > MAX_SEGS { set_toast("Timeline cheia para cortar o silêncio"); return 0 }
	old_end := proto.start + proto.dur
	old_dur := proto.dur
	tr := proto.track
	remove_seg(si, false, false)
	tl := proto.start
	keep_total: f32 = 0
	first := -1
	for k in 0 ..< nk {
		ni := add_seg(proto.src, tl, keeps[k].in_off, keeps[k].dur, tr)
		if ni < 0 do break
		segs[ni] = proto
		segs[ni].start = tl
		segs[ni].in_off = keeps[k].in_off
		segs[ni].dur = keeps[k].dur
		if k > 0 do segs[ni].fade_in = 0
		if k < nk - 1 do segs[ni].fade_out = 0
		if k > 0 do segs[ni].vfin = 0
		if k < nk - 1 do segs[ni].vfout = 0
		clamp_fades(&segs[ni])
		if first < 0 do first = ni
		tl += keeps[k].dur
		keep_total += keeps[k].dur
	}
	gap := old_dur - keep_total
	if gap > 0.001 {
		for k in 0 ..< nsegs do if segs[k].track == tr && segs[k].start >= old_end - 0.001 do segs[k].start -= gap
		for k in 0 ..< nfx do if fxsegs[k].track == tr && fxsegs[k].start >= old_end - 0.001 do fxsegs[k].start -= gap
	}
	if first >= 0 do selected = first
	return n
}

draw_silence_modal :: proc(sw, sh: f32) {
	if sil_si < 0 || sil_si >= nsegs { sil_close(); return }
	sg := segs[sil_si]
	c := seg_src(sil_si)
	if sil_play {
		sil_play_t += rl.GetFrameTime()
		if sil_keep_total <= 0 || sil_play_t >= sil_keep_total { sil_play_t = 0; sil_play = false }
	}

	rl.DrawRectangleRec({0, 0, sw, sh}, rl.Color{0, 0, 0, 150})
	cw: f32 = 680; ch: f32 = 420
	cx := sw/2 - cw/2; cy := sh/2 - ch/2
	card := rl.Rectangle{ cx, cy, cw, ch }
	rl.DrawRectangleRounded(card, 0.03, 8, rl.Color{ 30, 33, 40, 255 })
	rl.DrawRectangleRoundedLinesEx(card, 0.03, 8, 1, LINE)
	txt("Detecção de silêncio", cx + 20, cy + 14, 16, TEXT)
	xr := rl.Rectangle{ cx + cw - 36, cy + 12, 22, 22 }
	if clicked(xr) do sil_close()
	rl.DrawLineEx({xr.x+5, xr.y+5}, {xr.x+15, xr.y+15}, 1.8, hovered(xr) ? TEXT : MUTED)
	rl.DrawLineEx({xr.x+15, xr.y+5}, {xr.x+5, xr.y+15}, 1.8, hovered(xr) ? TEXT : MUTED)

	// esquerda: sliders
	x := cx + 20; y := cy + 48; w := f32(230)
	old_pct, old_min, old_pad := sil_pct, sil_min, sil_pad
	txt("Limite de volume", x, y, 12, TEXT)
	txt(rl.TextFormat("%.0f %%", f64(sil_pct)), x + w - 4, y, 12, ACCENT); y += 18
	ui_slider(50, { x, y, w, 14 }, &sil_pct, 5, 80); y += 30
	txt("Duração mínima", x, y, 12, TEXT)
	txt(rl.TextFormat("%.2f s", f64(sil_min)), x + w - 4, y, 12, ACCENT); y += 18
	ui_slider(51, { x, y, w, 14 }, &sil_min, 0.10, 2.00); y += 30
	txt("Buffer de suavização", x, y, 12, TEXT)
	txt(rl.TextFormat("%.2f s", f64(sil_pad)), x + w - 4, y, 12, ACCENT); y += 18
	ui_slider(52, { x, y, w, 14 }, &sil_pad, 0, 0.40); y += 28
	if sil_pct != old_pct || sil_min != old_min || sil_pad != old_pad do sil_dirty = sil_done
	if ui_btn({ x, y, 120, 28 }, "Começar", true) do sil_run()
	y += 36
	if sil_dirty do txt("Começar de novo p/ atualizar.", x, y, 11, rl.Color{ 220, 180, 90, 255 })
	else if !sil_done do txt("Começar mostra o corte, sem aplicar.", x, y, 11, MUTED)
	else if sil_n == 0 do txt("Nenhum silêncio nesse limiar.", x, y, 11, MUTED)
	else do txt(rl.TextFormat("%d vão(s)  ·  −%.1f s", i32(sil_n), f64(sg.dur - sil_keep_total)), x, y, 12, ACCENT)

	// direita: preview pequeno
	pv := rl.Rectangle{ cx + 268, cy + 48, cw - 288, 168 }
	rl.DrawRectangleRec(pv, rl.BLACK)
	ensure_tex(c)
	src_t: f32
	if sil_done && sil_nk > 0 do src_t = sil_src_at(sil_play_t)
	else do src_t = clamp(sg.in_off, 0, c.dur)
	clip_frame(c, clamp(src_t, 0, c.dur))
	if c.tex_ok {
		cr := dec_content_rect(c)
		tff := min(pv.width / cr.width, pv.height / cr.height)
		fdw := cr.width * tff; fdh := cr.height * tff
		fr := rl.Rectangle{ pv.x + (pv.width - fdw)/2, pv.y + (pv.height - fdh)/2, fdw, fdh }
		rl.DrawTexturePro(c.tex, cr, fr, {0, 0}, 0, rl.WHITE)
	}
	play_r := rl.Rectangle{ pv.x + pv.width/2 - 14, pv.y + pv.height - 26, 28, 22 }
	if hovered(play_r) do rl.DrawRectangleRounded(play_r, 0.3, 4, HOVER)
	if clicked(play_r) && sil_done do sil_play = !sil_play
	if sil_play {
		rl.DrawRectangleRec({ play_r.x + 8, play_r.y + 5, 4, 12 }, TEXT)
		rl.DrawRectangleRec({ play_r.x + 16, play_r.y + 5, 4, 12 }, TEXT)
	} else {
		rl.DrawTriangle({ play_r.x + 9, play_r.y + 5 }, { play_r.x + 9, play_r.y + 17 }, { play_r.x + 20, play_r.y + 11 }, TEXT)
	}

	// resultado + aplicar
	lane := rl.Rectangle{ cx + 20, cy + 232, cw - 40, 112 }
	txt("Resultado (ainda não na timeline)", lane.x, lane.y - 16, 11, MUTED)
	rl.DrawRectangleRec(lane, rl.Color{ 36, 42, 78, 255 })
	if !sil_done {
		txt_c("Clique em Começar para ver os pedaços que ficam.", lane.x + lane.width/2, lane.y + 46, 12, MUTED)
	} else if sil_nk == 0 {
		txt_c("Tudo silêncio — nada restaria.", lane.x + lane.width/2, lane.y + 46, 12, MUTED)
	} else {
		gap: f32 = 3
		total_w := lane.width - gap * f32(sil_nk + 1)
		px := lane.x + gap
		acc: f32 = 0
		for k in 0 ..< sil_nk {
			kw := max(f32(6), sil_keep[k].dur / max(sil_keep_total, 0.001) * total_w)
			kr := rl.Rectangle{ px, lane.y + 5, kw, lane.height - 10 }
			hot := sil_play_t >= acc && sil_play_t < acc + sil_keep[k].dur
			rl.DrawRectangleRounded(kr, 0.08, 4, hot ? rl.Color{ 72, 88, 150, 255 } : rl.Color{ 56, 70, 128, 255 })
			if c.thumbs_ready && c.nthumbs > 0 && c.thumb_dt > 0 && kw > 20 {
				mid := (sil_keep[k].src0 + sil_keep[k].src1) * 0.5
				ti := clamp(int(mid / c.thumb_dt), 0, c.nthumbs - 1)
				if c.thumbs[ti].id > 0 {
					th := kr.height - 6
					tw := min(th * 16 / 9, kw - 4)
					rl.DrawTexturePro(c.thumbs[ti], {0, 0, f32(c.thumbs[ti].width), f32(c.thumbs[ti].height)},
						{ kr.x + 2, kr.y + 3, tw, th }, {0, 0}, 0, rl.WHITE)
				}
			}
			if clicked(kr) { sil_play_t = acc; sil_play = false }
			acc += sil_keep[k].dur
			px += kw + gap
		}
		if sil_keep_total > 0 {
			phx := lane.x + gap
			walk: f32 = 0
			for k in 0 ..< sil_nk {
				kw := max(f32(6), sil_keep[k].dur / sil_keep_total * total_w)
				if sil_play_t <= walk + sil_keep[k].dur {
					phx += (sil_play_t - walk) / max(sil_keep[k].dur, 0.001) * kw
					break
				}
				phx += kw + gap
				walk += sil_keep[k].dur
			}
			rl.DrawLineEx({ phx, lane.y }, { phx, lane.y + lane.height }, 2, PLAYHEAD)
		}
	}

	if ui_btn({ cx + 20, cy + ch - 48, 110, 32 }, "Cancelar", false) do sil_close()
	can_apply := sil_done && !sil_dirty && sil_n > 0
	ar := rl.Rectangle{ cx + cw - 230, cy + ch - 48, 210, 32 }
	if can_apply {
		rl.DrawRectangleRounded(ar, 0.4, 8, hovered(ar) ? ACCENT : ACCENT_D)
		txt_c("Aplicar na timeline", ar.x + ar.width/2, ar.y + 8, 13, rl.WHITE)
		if clicked(ar) do silence_apply_selection()
	} else {
		rl.DrawRectangleRounded(ar, 0.4, 8, rl.Color{ 50, 54, 62, 255 })
		txt_c("Aplicar na timeline", ar.x + ar.width/2, ar.y + 8, 13, MUTED)
	}
}

silence_apply_selection :: proc() {
	if !sil_done { set_toast("Clique em Começar para ver o resultado"); return }
	thresh := sil_thresh(sil_run_pct)
	// índices estáveis: processa da DIREITA p/ a esquerda (o rebuild mexe nos que estão depois)
	idx: [MAX_SEGS]int
	nn := 0
	for i in 0 ..< nsegs {
		if i == selected || seg_marked[i] {
			idx[nn] = i
			nn += 1
		}
	}
	if nn == 0 { set_toast("Selecione um clipe com áudio"); return }
	// insertion sort por start descendente
	for a in 1 ..< nn {
		v, p := idx[a], a
		for p > 0 && segs[idx[p - 1]].start < segs[v].start { idx[p] = idx[p - 1]; p -= 1 }
		idx[p] = v
	}
	cuts := 0
	for k in 0 ..< nn {
		si := idx[k]
		if si < 0 || si >= nsegs do continue
		cuts += silence_apply_seg(si, thresh, sil_run_min, sil_run_pad)
	}
	sil_close()
	if cuts == 0 do set_toast("Nenhum silêncio nesse limiar")
	else do set_toast(rl.TextFormat("Silêncio removido (%d vão(s))", i32(cuts)))
}
