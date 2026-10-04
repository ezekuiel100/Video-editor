package main

import "core:log"
import "core:os"
import "core:testing"
import "core:time"

// decodifica frames REAIS pela libav (pula se não houver DLLs ou o vídeo de amostra)
@(test)
lav_decodifica_alvos :: proc(t: ^testing.T) {
	path := "C:/Users/Adm/Downloads/11111111.mp4"
	if !os.exists(path) || !lav_init() do return
	c: Clip
	c.path = path; c.name = "amostra"; c.aid = 999; c.streaming = true; c.dw = 1280; c.dh = 720
	_, _, _, c.vw, c.vh, _ = video_probe(path)
	buf := make([]u8, STREAM_FBYTES_MAX); defer delete(buf)
	for ts in ([]f32{0, 0.1, 0.2, 0.2, 0.15, 30, 30.1, 5, 60, 30}) {
		t0 := time.tick_now()
		ok := false
		for attempt in 0 ..< 100 {
			retry := false
			ok = lav_decode_frame(&c, 0, ts, buf, &retry)
			if !retry do break
		}
		if ok {
			d := lav_open(&c, 0)
			testing.expect(t, d.has_frame && !d.pending, "quadro finalizado")
			testing.expect(t, d.frame_t + 0.000001 >= f64(ts) || d.draining, "PTS deve alcançar alvo ou EOF")
		}
		ms := time.duration_milliseconds(time.tick_since(t0))
		log.infof("t=%.0fs ok=%v %.1fms", ts, ok, ms)
		testing.expect(t, ok, "decode libav")
		nz := 0
		for b in buf[:cframe(&c)] do if b > 16 do nz += 1
		testing.expect(t, nz > 1000, "frame não pode sair preto")
	}
	_ = lav_decode_frame(&c, 0, 30, buf)
	for &d in lav_decs do lav_close(&d)
}
// Independentes de DLLs e arquivo de amostra.
@(test)
lav_politica_de_seek :: proc(t: ^testing.T) {
	d: LavDec
	testing.expect(t, lav_needs_seek(&d, 0), "primeiro pedido faz seek")
	d.has_frame = true; d.frame_t = 10.04; d.request_t = 10
	testing.expect(t, !lav_needs_seek(&d, 10.02), "alvo dentro do quadro retido não faz seek")
	testing.expect(t, !lav_needs_seek(&d, 10.1), "avanço curto reaproveita decoder")
	testing.expect(t, lav_needs_seek(&d, 9.99), "retorno faz seek")
	testing.expect(t, lav_needs_seek(&d, 11), "salto grande faz seek")
	d.pending = true; d.request_t = 20
	testing.expect(t, !lav_needs_seek(&d, 20), "orçamento interrompido retoma o mesmo alvo")
	testing.expect(t, lav_needs_seek(&d, 19), "alvo novo distante não retoma trabalho velho")
}

@(test)
lav_seek_gop_longo :: proc(t: ^testing.T) {
	d: LavDec
	d.has_frame = true; d.frame_t = 3; d.request_t = 3
	testing.expect(t, lav_needs_seek(&d, 8), "sem índice: salto grande faz seek")
	testing.expect(t, !lav_needs_seek(&d, 8, 0), "mesmo GOP: continuar vence voltar ao keyframe")
	testing.expect(t, lav_needs_seek(&d, 8, 6), "keyframe depois do quadro retido: seek")
	testing.expect(t, lav_needs_seek(&d, 2, 0), "voltar no mesmo GOP ainda faz seek")
}

// arrasto rápido: keyframe ≤ alvo com 1 decode; o refino exato continua dali sem novo seek
@(test)
lav_modo_keyframe :: proc(t: ^testing.T) {
	path := "C:/Users/Adm/Downloads/11111111.mp4"
	if !os.exists(path) || !lav_init() do return
	c: Clip
	c.path = path; c.name = "amostra"; c.aid = 998; c.streaming = true; c.dw = 1280; c.dh = 720
	c.aud_path = "C:/Users/Adm/AppData/Local/Temp/odin_editor_test_kf" // base do CSV temporário do índice
	_, _, _, c.vw, c.vh, _ = video_probe(path)
	build_kf_index(&c)
	defer delete(c.kf)
	buf := make([]u8, STREAM_FBYTES_MAX); defer delete(buf)
	for ts in ([]f32{30.5, 5.3, 60.7}) {
		k := kf_lookup(&c, ts)
		if k < 0 do continue
		t0 := time.tick_now()
		testing.expect(t, lav_decode_frame(&c, 0, ts, buf, kf_t = f64(c.kf[k]), keyframe = true), "keyframe decodifica")
		log.infof("KF t=%.1fs kf=%.2fs %.1fms", ts, c.kf[k], time.duration_milliseconds(time.tick_since(t0)))
		d := lav_open(&c, 0)
		testing.expect(t, abs(d.frame_t - f64(c.kf[k])) < 0.05, "quadro é o keyframe ≤ alvo")
		testing.expect(t, !lav_needs_seek(d, f64(ts), f64(c.kf[k])), "refino continua do keyframe")
	}
	for &d in lav_decs do lav_close(&d)
}

@(test)
scrub_chaves_intermediarias :: proc(t: ^testing.T) {
	a := scrub_key(1, 7, 2, 10.1, 300, true)
	b := scrub_key(1, 7, 2, 10.2, 300, true)
	testing.expect(t, a != b, "mesmo GOP não colapsa quadros intermediários")
	testing.expect(t, a == scrub_key(1, 7, 9, 10.1, 300, true), "índice de keyframes não muda chave precisa")
	testing.expect(t, a != scrub_key(1, 7, 2, 10.1, 300, false), "fallback não contamina cache preciso")
	testing.expect(t, scrub_key(1, 7, 2, 10.1, 300, false) == scrub_key(1, 7, 2, 10.2, 300, false), "fallback mantém cache por keyframe")
	testing.expect(t, a != scrub_key(1, 8, 2, 10.1, 300, true), "slot reaproveitado não casa")
	testing.expect(t, a != scrub_key(1, 7, 2, 10.1, 600, true), "resolução diferente não casa")
}
