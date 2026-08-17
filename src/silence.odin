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
sil_wave_t: f32 // tempo na FONTE p/ o preview de vídeo quando não está tocando o resultado
sil_run_pct, sil_run_min, sil_run_pad: f32 // parâmetros do último Começar (é o que o Aplicar usa)
sil_eat: bool // ignora o clique que ABRIU o cartão (ainda está down no mesmo frame)

SIL_HYST :: f32(1.4)  // sai do silêncio só acima de thresh×isto (evita tremer na borda)
SIL_GLUE :: f32(0.12) // funde vãos separados por um clique/respiração mais curta que isto

sil_thresh :: proc(pct: f32) -> f32 { return clamp(pct, 1, 90) / 100 }

// limiar ABSOLUTO a partir do % do slider: relativo ao volume da FALA do trecho
// (média dos buckets altos), não a 1.0. Sem isto, 25% = RMS 0.25 e ou apagava
// o clipe inteiro (fala quieta) ou não achava nada (fala alta).
sil_rel_thresh :: proc(c: ^Clip, src0, src1, pct: f32) -> f32 {
	if c == nil || len(c.wave_rms) == 0 do return sil_thresh(pct)
	n := len(c.wave_rms)
	i0 := clamp(int(src0 * WAVE_PPS), 0, n - 1)
	i1 := clamp(int(src1 * WAVE_PPS), 0, n - 1)
	if i1 < i0 do return sil_thresh(pct)
	mx: f32 = 0
	for i := i0; i <= i1; i += 1 do if c.wave_rms[i] > mx do mx = c.wave_rms[i]
	if mx < 0.008 do return 0.004
	floor := mx * 0.30
	sum: f32 = 0
	cnt := 0
	for i := i0; i <= i1; i += 1 {
		if c.wave_rms[i] >= floor { sum += c.wave_rms[i]; cnt += 1 }
	}
	ref := cnt > 0 ? sum / f32(cnt) : mx
	return max(f32(0.004), sil_thresh(pct) * ref)
}

sil_seg_thresh :: proc(si: int, pct: f32) -> f32 {
	if si < 0 || si >= nsegs do return sil_thresh(pct)
	sg := segs[si]
	spd := seg_speed(si)
	return sil_rel_thresh(seg_src(si), sg.in_off, sg.in_off + sg.dur * spd, pct)
}

// mediana de até 5 buckets (~50 ms) — um estalo não parte o vão
sil_smooth_at :: proc(rms: []f32, i, i0, i1: int) -> f32 {
	v: [5]f32
	n := 0
	a := max(i - 2, i0)
	b := min(i + 2, i1)
	for k := a; k <= b; k += 1 { v[n] = rms[k]; n += 1 }
	// insertion sort pequenininho
	for p in 1 ..< n {
		x, q := v[p], p
		for q > 0 && v[q - 1] > x { v[q] = v[q - 1]; q -= 1 }
		v[q] = x
	}
	return v[n / 2]
}

// preenche `out` com intervalos de silêncio em [src0, src1] na fonte. Devolve a contagem.
// thresh é RMS absoluto. Suaviza, usa histerese e cola vãos vizinhos antes do pad.
detect_silences :: proc(c: ^Clip, src0, src1, thresh, min_dur, pad: f32, out: []Silence) -> int {
	if c == nil || !intrinsics.atomic_load(&c.wave_ready) || len(c.wave_rms) == 0 do return 0
	if src1 - src0 < min_dur || thresh <= 0 || len(out) == 0 do return 0
	n := len(c.wave_rms)
	i0 := clamp(int(src0 * WAVE_PPS), 0, n - 1)
	i1 := clamp(int(src1 * WAVE_PPS), 0, n - 1)
	if i1 < i0 do return 0
	RAW :: 128
	raw: [RAW]Silence
	nraw := 0
	run := -1
	in_sil := false
	leave := thresh * SIL_HYST
	push :: proc(run, i: int, src0, src1: f32, raw: []Silence, nraw: ^int) {
		if run < 0 || nraw^ >= len(raw) do return
		a := max(f32(run) / WAVE_PPS, src0)
		b := min(f32(i) / WAVE_PPS, src1)
		if b - a < 0.02 do return
		raw[nraw^] = Silence{ a, b }
		nraw^ += 1
	}
	for i := i0; i <= i1; i += 1 {
		v := sil_smooth_at(c.wave_rms, i, i0, i1)
		if !in_sil {
			if v < thresh { in_sil = true; run = i }
		} else if v > leave {
			push(run, i, src0, src1, raw[:], &nraw)
			in_sil = false; run = -1
		}
	}
	if in_sil do push(run, i1 + 1, src0, src1, raw[:], &nraw)
	// cola vãos com um fiapo de “fala” no meio (clique, “hm”, respiração)
	glue := max(SIL_GLUE, pad)
	w := 0
	for k in 0 ..< nraw {
		if w > 0 && raw[k].t0 - raw[w - 1].t1 <= glue {
			raw[w - 1].t1 = raw[k].t1
		} else {
			if w != k do raw[w] = raw[k]
			w += 1
		}
	}
	nfound := 0
	for k in 0 ..< w {
		if nfound >= len(out) do break
		a, b := raw[k].t0, raw[k].t1
		if b - a < min_dur do continue
		a += pad; b -= pad
		if b - a < 0.05 do continue
		out[nfound] = Silence{ a, b }
		nfound += 1
	}
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
	sil_n = detect_seg_silences(sil_si, sil_seg_thresh(sil_si, sil_pct), sil_min, sil_pad, sil_hits[:])
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
	sil_wave_t = segs[selected].in_off
	sil_eat = true // o clique do ícone ainda está down — não pode cair no cartão
	modal = .Silence
}

// forma de onda do segmento: RMS+pico, linha do limiar e faixas âmbar.
// `hits` em tempo de TIMELINE. overlay=true: desenha POR CIMA do vídeo (fundo translúcido).
draw_sil_wave :: proc(r: rl.Rectangle, si: int, thresh: f32, hits: []Silence, nh: int, overlay := false) {
	if si < 0 || si >= nsegs do return
	sg := segs[si]
	c := seg_src(si)
	if overlay {
		rl.DrawRectangleRec(r, rl.Color{ 8, 14, 12, 140 })
	} else {
		rl.DrawRectangleRec(r, rl.Color{ 22, 40, 36, 255 })
		rl.DrawRectangleLinesEx(r, 1, rl.Color{ 48, 64, 58, 255 })
	}
	if sg.dur < 0.001 do return
	// vãos detectados (por baixo da onda) — o pad já está aplicado nos hits
	for k in 0 ..< nh {
		u0 := clamp((hits[k].t0 - sg.start) / sg.dur, 0, 1)
		u1 := clamp((hits[k].t1 - sg.start) / sg.dur, 0, 1)
		if u1 <= u0 do continue
		xr := rl.Rectangle{ r.x + u0 * r.width, r.y + 1, max(f32(1), (u1 - u0) * r.width), r.height - 2 }
		rl.DrawRectangleRec(xr, rl.Color{ 220, 170, 50, 60 })
	}
	STEP :: f32(2)
	base := r.y + r.height - 2
	amp := r.height - 4
	wcol := rl.Color{ 95, 180, 150, 235 }
	pcol := rl.Color{ 95, 180, 150, 90 }
	spd := seg_speed(si)
	for wx := r.x; wx < r.x + r.width; wx += STEP {
		u0 := (wx - r.x) / r.width
		u1 := (wx + STEP - r.x) / r.width
		ta := sg.in_off + u0 * sg.dur * spd
		tb := sg.in_off + u1 * sg.dur * spd
		p := wave_peak(c, ta, tb)
		if p < 0 {
			rl.DrawRectangleRec({ wx, base - 2, STEP, 2 }, rl.Color{ 70, 100, 92, 130 })
		} else {
			hp := max(f32(1), clamp(p, 0, 1) * amp)
			rl.DrawRectangleRec({ wx, base - hp, STEP, hp }, pcol)
			if rms := wave_rms_at(c, ta, tb); rms > 0 {
				hr := max(f32(1), min(clamp(rms * WAVE_RMS_GAIN, 0, 1) * amp, hp))
				rl.DrawRectangleRec({ wx, base - hr, STEP, hr }, wcol)
			}
		}
	}
	// limiar na MESMA escala visual do corpo RMS (ganho de exibição)
	thy := base - clamp(thresh * WAVE_RMS_GAIN, 0, 1) * amp
	rl.DrawLineEx({ r.x + 1, thy }, { r.x + r.width - 1, thy }, 1.6, rl.Color{ 236, 72, 60, 220 })
	// marca do tempo atual do preview (fonte → posição no segmento)
	if c.dur > 0 {
		src_t := sil_play && sil_done && sil_nk > 0 ? sil_src_at(sil_play_t) : sil_wave_t
		u := clamp((src_t - sg.in_off) / max(sg.dur * spd, 0.001), 0, 1)
		px := r.x + u * r.width
		rl.DrawLineEx({ px, r.y }, { px, r.y + r.height }, 1.5, PLAYHEAD)
	}
	// clique: scrub no original (pausa o play do resultado)
	if clicked(r) {
		u := clamp((rl.GetMousePosition().x - r.x) / r.width, 0, 1)
		sil_wave_t = sg.in_off + u * sg.dur * spd
		sil_play = false
	}
	if !overlay do txt("limiar", r.x + 6, r.y + 3, 10, rl.Color{ 236, 100, 90, 200 })
}

// onda de um intervalo da FONTE (pedaço do resultado empacotado)
draw_wave_src :: proc(r: rl.Rectangle, c: ^Clip, src0, src1: f32) {
	if c == nil || r.width < 2 || src1 - src0 < 0.001 do return
	STEP :: f32(2)
	base := r.y + r.height - 1
	amp := max(f32(2), r.height - 2)
	wcol := rl.Color{ 95, 180, 150, 235 }
	pcol := rl.Color{ 95, 180, 150, 80 }
	span := src1 - src0
	for wx := r.x; wx < r.x + r.width; wx += STEP {
		u0 := (wx - r.x) / r.width
		u1 := (wx + STEP - r.x) / r.width
		p := wave_peak(c, src0 + u0 * span, src0 + u1 * span)
		if p < 0 {
			rl.DrawRectangleRec({ wx, base - 2, STEP, 2 }, rl.Color{ 70, 100, 92, 120 })
		} else {
			hp := max(f32(1), clamp(p, 0, 1) * amp)
			rl.DrawRectangleRec({ wx, base - hp, STEP, hp }, pcol)
			if rms := wave_rms_at(c, src0 + u0 * span, src0 + u1 * span); rms > 0 {
				hr := max(f32(1), min(clamp(rms * WAVE_RMS_GAIN, 0, 1) * amp, hp))
				rl.DrawRectangleRec({ wx, base - hr, STEP, hr }, wcol)
			}
		}
	}
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
	cw: f32 = 680; ch: f32 = 460
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
	txt(rl.TextFormat("%.0f %% da fala", f64(sil_pct)), x + w - 48, y, 12, ACCENT); y += 18
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

	// direita: só o quadro (a onda vai na faixa de resultado, como na timeline)
	live: [SIL_MAX]Silence
	live_thr := sil_seg_thresh(sil_si, sil_pct)
	live_n := detect_seg_silences(sil_si, live_thr, sil_min, sil_pad, live[:])
	if live_n > 0 && !sil_done {
		rem: f32 = 0
		for k in 0 ..< live_n do rem += live[k].t1 - live[k].t0
		txt(rl.TextFormat("âmbar = silêncio  ·  %d vão(s)  ·  −%.1f s", i32(live_n), f64(rem)),
			x, y, 11, ACCENT)
	}

	pv := rl.Rectangle{ cx + 268, cy + 48, cw - 288, 168 }
	rl.DrawRectangleRec(pv, rl.BLACK)
	ensure_tex(c)
	src_t: f32
	if sil_play && sil_done && sil_nk > 0 do src_t = sil_src_at(sil_play_t)
	else do src_t = clamp(sil_wave_t, 0, c.dur)
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

	// resultado = clipe da timeline: filmstrip + onda no rodapé (limiar e âmbar na onda)
	lane := rl.Rectangle{ cx + 20, cy + 236, cw - 40, 148 }
	txt("Resultado (ainda não na timeline)", lane.x, lane.y - 16, 11, MUTED)
	rl.DrawRectangleRec(lane, rl.Color{ 36, 42, 78, 255 })
	if !sil_done {
		// antes de Começar: onda do original + limiar, para acertar o corte
		draw_sil_wave({ lane.x + 4, lane.y + 4, lane.width - 8, lane.height - 8 },
			sil_si, live_thr, live[:], live_n)
	} else if sil_nk == 0 {
		txt_c("Tudo silêncio — nada restaria.", lane.x + lane.width/2, lane.y + 64, 12, MUTED)
	} else {
		gap: f32 = 3
		total_w := lane.width - gap * f32(sil_nk + 1)
		px := lane.x + gap
		acc: f32 = 0
		film_h := f32(52)
		for k in 0 ..< sil_nk {
			kw := max(f32(6), sil_keep[k].dur / max(sil_keep_total, 0.001) * total_w)
			kr := rl.Rectangle{ px, lane.y + 5, kw, lane.height - 10 }
			hot := sil_play_t >= acc && sil_play_t < acc + sil_keep[k].dur
			rl.DrawRectangleRounded(kr, 0.08, 4, hot ? rl.Color{ 72, 88, 150, 255 } : rl.Color{ 56, 70, 128, 255 })
			// tira de vídeo em cima, onda do pedaço embaixo (igual ao clipe na timeline)
			if c.thumbs_ready && c.nthumbs > 0 && c.thumb_dt > 0 && kw > 20 && !c.is_audio {
				th := min(film_h, kr.height * 0.45)
				mid := (sil_keep[k].src0 + sil_keep[k].src1) * 0.5
				ti := clamp(int(mid / c.thumb_dt), 0, c.nthumbs - 1)
				if c.thumbs[ti].id > 0 {
					tw := min(th * 16 / 9, kw - 4)
					rl.DrawTexturePro(c.thumbs[ti], {0, 0, f32(c.thumbs[ti].width), f32(c.thumbs[ti].height)},
						{ kr.x + 2, kr.y + 3, tw, th }, {0, 0}, 0, rl.WHITE)
				}
				wr := rl.Rectangle{ kr.x + 2, kr.y + th + 4, kr.width - 4, kr.height - th - 6 }
				rl.DrawRectangleRec(wr, rl.Color{ 24, 46, 40, 220 })
				draw_wave_src(wr, c, sil_keep[k].src0, sil_keep[k].src1)
			} else {
				wr := rl.Rectangle{ kr.x + 2, kr.y + 4, kr.width - 4, kr.height - 8 }
				rl.DrawRectangleRec(wr, rl.Color{ 24, 46, 40, 220 })
				draw_wave_src(wr, c, sil_keep[k].src0, sil_keep[k].src1)
			}
			if clicked(kr) { sil_play_t = acc; sil_play = false; sil_wave_t = sil_keep[k].src0 }
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
		cuts += silence_apply_seg(si, sil_seg_thresh(si, sil_run_pct), sil_run_min, sil_run_pad)
	}
	sil_close()
	if cuts == 0 do set_toast("Nenhum silêncio nesse limiar")
	else do set_toast(rl.TextFormat("Silêncio removido (%d vão(s))", i32(cuts)))
}
