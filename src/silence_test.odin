package main

import "core:testing"

@(test)
silencio_acha_vao_no_meio :: proc(t: ^testing.T) {
	t_reset()
	c := &clips[0]
	c.src_audio = true
	c.wave_ready = true; c.wave_complete = true
	// 2.0 s × 100 buckets: 0.6s alto, 0.8s silêncio, 0.6s alto
	c.wave_rms = make([]f32, 200)
	defer { delete(c.wave_rms); c.wave_rms = nil; c.wave_ready = false; c.wave_complete = false }
	for i in 0 ..< 200 {
		c.wave_rms[i] = (i >= 60 && i < 140) ? 0.005 : 0.2
	}
	out: [SIL_MAX]Silence
	n := detect_silences(c, 0, 2, 0.03, 0.3, 0, out[:])
	testing.expect(t, n == 1, "um vão contínuo")
	testing.expect(t, t_feq(out[0].t0, 0.60) && t_feq(out[0].t1, 1.40), "vão = [0.6, 1.4]")
}

@(test)
silencio_folga_encolhe_as_bordas :: proc(t: ^testing.T) {
	t_reset()
	c := &clips[0]
	c.wave_ready = true; c.wave_complete = true
	c.wave_rms = make([]f32, 200)
	defer { delete(c.wave_rms); c.wave_rms = nil; c.wave_ready = false; c.wave_complete = false }
	for i in 0 ..< 200 do c.wave_rms[i] = (i >= 60 && i < 140) ? 0 : 0.3
	out: [SIL_MAX]Silence
	n := detect_silences(c, 0, 2, 0.03, 0.3, 0.10, out[:])
	testing.expect(t, n == 1, "ainda um vão")
	testing.expect(t, t_feq(out[0].t0, 0.70) && t_feq(out[0].t1, 1.30), "pad de 0.1s de cada lado")
}

@(test)
silencio_minimo_ignora_blip :: proc(t: ^testing.T) {
	t_reset()
	c := &clips[0]
	c.wave_ready = true; c.wave_complete = true
	c.wave_rms = make([]f32, 100)
	defer { delete(c.wave_rms); c.wave_rms = nil; c.wave_ready = false; c.wave_complete = false }
	for i in 0 ..< 100 do c.wave_rms[i] = 0.2
	for i in 40 ..< 45 do c.wave_rms[i] = 0 // 50 ms
	out: [SIL_MAX]Silence
	n := detect_silences(c, 0, 1, 0.03, 0.30, 0, out[:])
	testing.expect(t, n == 0, "blip de 50ms fica abaixo da duração mínima")
}

@(test)
silencio_rebuild_fecha_o_vao :: proc(t: ^testing.T) {
	t_reset()
	c := &clips[0]
	c.src_audio = true
	c.wave_ready = true; c.wave_complete = true
	c.wave_rms = make([]f32, 200)
	defer { delete(c.wave_rms); c.wave_rms = nil; c.wave_ready = false; c.wave_complete = false }
	for i in 0 ..< 200 do c.wave_rms[i] = (i >= 60 && i < 140) ? 0 : 0.2
	a := add_seg(0, 10, 0, 2) // timeline [10,12) = fonte [0,2)
	b := add_seg(0, 12, 0, 1) // encostado à direita
	n := silence_apply_seg(a, 0.03, 0.3, 0)
	testing.expect(t, n == 1, "removeu 1 vão")
	testing.expect(t, nsegs == 3, "2 pedaços do original + o vizinho")
	// remove compacta o array: o vizinho pode ficar em qualquer índice
	lo, mid, hi := -1, -1, -1
	for i in 0 ..< nsegs {
		if t_feq(segs[i].start, 10) do lo = i
		else if t_feq(segs[i].start, 10.6) do mid = i
		else if t_feq(segs[i].start, 11.2) do hi = i
	}
	testing.expect(t, lo >= 0 && t_feq(segs[lo].dur, 0.6) && t_feq(segs[lo].in_off, 0), "fala 1")
	testing.expect(t, mid >= 0 && t_feq(segs[mid].dur, 0.6) && t_feq(segs[mid].in_off, 1.4), "fala 2 encostada")
	testing.expect(t, hi >= 0 && t_feq(segs[hi].dur, 1), "vizinho escorregou o vão (ripple)")
	_ = b
}

// um “hm” de 80ms no meio da pausa não pode virar 2 cortes — cola no vão único
@(test)
silencio_cola_vao_com_estalo :: proc(t: ^testing.T) {
	t_reset()
	c := &clips[0]
	c.wave_ready = true; c.wave_complete = true
	c.wave_rms = make([]f32, 200)
	defer { delete(c.wave_rms); c.wave_rms = nil; c.wave_ready = false; c.wave_complete = false }
	for i in 0 ..< 200 do c.wave_rms[i] = 0.2
	for i in 30 ..< 70 do c.wave_rms[i] = 0 // 0.40s
	for i in 70 ..< 78 do c.wave_rms[i] = 0.2 // 80ms de estalo
	for i in 78 ..< 118 do c.wave_rms[i] = 0 // 0.40s
	out: [SIL_MAX]Silence
	n := detect_silences(c, 0, 2, 0.03, 0.30, 0, out[:])
	testing.expect(t, n == 1, "estalo curto cola os dois vãos")
	testing.expect(t, t_feq(out[0].t0, 0.30) && t_feq(out[0].t1, 1.18), "vão único do 1º ao 2º silêncio")
}

// limiar relativo: fala baixa (RMS 0.08) — 25% ABSOLUTO (0.25) apagaria o clipe todo
@(test)
silencio_limiar_relativo_a_fala :: proc(t: ^testing.T) {
	t_reset()
	c := &clips[0]
	c.wave_ready = true; c.wave_complete = true
	c.wave_rms = make([]f32, 200)
	defer { delete(c.wave_rms); c.wave_rms = nil; c.wave_ready = false; c.wave_complete = false }
	for i in 0 ..< 200 do c.wave_rms[i] = (i >= 60 && i < 140) ? 0.004 : 0.08
	thr := sil_rel_thresh(c, 0, 2, 25)
	testing.expect(t, thr > 0.01 && thr < 0.05, "25% da fala ~0.08, não 0.25 absoluto")
	out: [SIL_MAX]Silence
	n := detect_silences(c, 0, 2, thr, 0.30, 0, out[:])
	testing.expect(t, n == 1, "acha o vão no meio da fala baixa")
	testing.expect(t, sil_thresh(25) > 0.08, "o % absoluto antigo ficaria ACIMA da fala")
}

// ruído oscilando em torno do limiar = UM vão, não dezenas de cortes
@(test)
silencio_histerese_nao_treme :: proc(t: ^testing.T) {
	t_reset()
	c := &clips[0]
	c.wave_ready = true; c.wave_complete = true
	c.wave_rms = make([]f32, 200)
	defer { delete(c.wave_rms); c.wave_rms = nil; c.wave_ready = false; c.wave_complete = false }
	for i in 0 ..< 200 do c.wave_rms[i] = 0.2
	for i in 40 ..< 140 { // 1s de “quase silêncio” oscilando
		c.wave_rms[i] = (i % 2 == 0) ? 0.02 : 0.038
	}
	out: [SIL_MAX]Silence
	n := detect_silences(c, 0, 2, 0.03, 0.30, 0, out[:])
	testing.expect(t, n == 1, "histerese segura um único vão")
	testing.expect(t, out[0].t1 - out[0].t0 > 0.8, "cobre a pausa inteira")
}

@(test)
silencio_recusa_onda_ainda_carregando :: proc(t: ^testing.T) {
	t_reset()
	c := &clips[0]
	c.src_audio = true
	c.wave_ready = true
	c.wave_rms = make([]f32, 200)
	defer { delete(c.wave_rms); c.wave_rms = nil }
	// Apenas os primeiros 0.5s chegaram; o resto ainda esta zerado.
	for i in 0 ..< 50 do c.wave_rms[i] = 0.2
	si := add_seg(0, 0, 0, 2)
	out: [SIL_MAX]Silence
	testing.expect(t, detect_silences(c, 0, 2, 0.03, 0.3, 0, out[:]) == 0,
		"unprocessed audio must not be treated as silence")
	testing.expect(t, silence_apply_seg(si, 0.03, 0.3, 0) == 0 && nsegs == 1 && segs[0].dur == 2,
		"must not remove content while audio is loading")
}

@(test)
silencio_respeita_velocidade_nos_parametros :: proc(t: ^testing.T) {
	t_reset()
	c := &clips[0]
	c.src_audio = true
	c.wave_ready = true; c.wave_complete = true
	c.wave_rms = make([]f32, 200)
	defer { delete(c.wave_rms); c.wave_rms = nil }
	for i in 0 ..< 200 do c.wave_rms[i] = (i >= 60 && i < 140) ? 0 : 0.2
	si := add_seg(0, 10, 0, 1)
	segs[si].speed = 2
	out: [SIL_MAX]Silence
	testing.expect(t, detect_seg_silences(si, 0.03, 0.5, 0, out[:]) == 0,
		"a 0.4s timeline pause is shorter than the 0.5s minimum")
	n := detect_seg_silences(si, 0.03, 0.3, 0.1, out[:])
	testing.expect(t, n == 1 && t_feq(out[0].t0, 10.4) && t_feq(out[0].t1, 10.6),
		"0.1s padding is measured on the timeline at 2x speed")
}

@(test)
silencio_multiselecao_fora_da_ordem_da_timeline :: proc(t: ^testing.T) {
	t_reset()
	c := &clips[0]
	c.src_audio = true
	c.wave_ready = true; c.wave_complete = true
	c.wave_rms = make([]f32, 200)
	defer { delete(c.wave_rms); c.wave_rms = nil }
	for i in 0 ..< 200 do c.wave_rms[i] = (i >= 60 && i < 140) ? 0 : 0.2
	add_seg(0, 10, 0, 2)
	selected = add_seg(0, 0, 0, 2)
	seg_marked[0] = true
	sil_done = true
	sil_run_pct = 25; sil_run_min = 0.3; sil_run_pad = 0
	silence_apply_selection()
	total: f32 = 0
	for i in 0 ..< nsegs do total += segs[i].dur
	testing.expect(t, nsegs == 4 && t_feq(total, 2.4),
		"both original clips are cut once regardless of array order")
	check_invariants()
}
