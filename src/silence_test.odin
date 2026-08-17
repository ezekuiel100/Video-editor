package main

import "core:testing"

@(test)
silencio_acha_vao_no_meio :: proc(t: ^testing.T) {
	t_reset()
	c := &clips[0]
	c.src_audio = true
	c.wave_ready = true
	// 2.0 s × 100 buckets: 0.6s alto, 0.8s silêncio, 0.6s alto
	c.wave_rms = make([]f32, 200)
	defer { delete(c.wave_rms); c.wave_rms = nil; c.wave_ready = false }
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
	c.wave_ready = true
	c.wave_rms = make([]f32, 200)
	defer { delete(c.wave_rms); c.wave_rms = nil; c.wave_ready = false }
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
	c.wave_ready = true
	c.wave_rms = make([]f32, 100)
	defer { delete(c.wave_rms); c.wave_rms = nil; c.wave_ready = false }
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
	c.wave_ready = true
	c.wave_rms = make([]f32, 200)
	defer { delete(c.wave_rms); c.wave_rms = nil; c.wave_ready = false }
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
