package main

import "core:log"
import "core:os"
import "core:testing"
import "core:time"

// decodifica frames REAIS pela libav (pula se não houver DLLs ou o vídeo de amostra)
@(test)
lav_decodifica_keyframes :: proc(t: ^testing.T) {
	path := "C:/Users/Adm/Downloads/11111111.mp4"
	if !os.exists(path) || !lav_init() do return
	c: Clip
	c.path = path; c.name = "amostra"; c.aid = 999; c.streaming = true; c.dw = 1280; c.dh = 720
	_, _, _, c.vw, c.vh, _ = video_probe(path)
	buf := make([]u8, STREAM_FBYTES_MAX); defer delete(buf)
	for ts in ([]f32{0, 30, 5, 60, 30}) {
		t0 := time.tick_now()
		ok := lav_decode_frame(&c, 0, ts, buf)
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
