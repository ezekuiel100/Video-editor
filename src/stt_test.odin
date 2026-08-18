package main

import "core:testing"
import "core:strings"

@(test)
srt_tempo_hhmmss :: proc(t: ^testing.T) {
	v, ok := parse_srt_time("00:00:02,500")
	testing.expect(t, ok, "00:00:02,500 tem de parsear")
	testing.expect(t, t_feq(v, 2.5), "2.5 s")
	v2, ok2 := parse_srt_time("00:01:00.000")
	testing.expect(t, ok2 && t_feq(v2, 60), "ponto nos ms também")
	v3, ok3 := parse_srt_time("01:02:03,250")
	testing.expect(t, ok3 && t_feq(v3, 3723.25), "1h2m3.25s")
	_, bad := parse_srt_time("lixo")
	testing.expect(t, !bad, "texto inválido")
}

@(test)
srt_bloco_com_offset :: proc(t: ^testing.T) {
	src := "1\n00:00:00,000 --> 00:00:02,400\nOlá mundo\n\n2\n00:00:02,400 --> 00:00:05,100\nSegunda\nlinha\n"
	cues := parse_srt(src, 10.0)
	defer { for q in cues do delete(q.text); delete(cues) }
	testing.expectf(t, len(cues) == 2, "2 falas, veio %d", len(cues))
	if len(cues) < 2 do return
	testing.expect(t, t_feq(cues[0].t0, 10.0) && t_feq(cues[0].t1, 12.4), "offset na 1ª")
	testing.expect(t, cues[0].text == "Olá mundo", "texto da 1ª")
	testing.expect(t, t_feq(cues[1].t0, 12.4) && t_feq(cues[1].t1, 15.1), "offset na 2ª")
	testing.expect(t, cues[1].text == "Segunda linha", "linhas do bloco viram espaço")
}

@(test)
srt_ignora_bloco_vazio_e_crlf :: proc(t: ^testing.T) {
	src := "1\r\n00:00:00,000 --> 00:00:01,000\r\n\r\n2\r\n00:00:01,000 --> 00:00:02,000\r\nOi\r\n"
	cues := parse_srt(src, 0)
	defer { for q in cues do delete(q.text); delete(cues) }
	testing.expect(t, len(cues) == 1, "bloco sem texto some")
	if len(cues) == 1 do testing.expect(t, cues[0].text == "Oi", "CRLF")
}

@(test)
clip_text_at_escolhe_fala :: proc(t: ^testing.T) {
	t_reset()
	cues := []CapCue{ { 1, 3, "um" }, { 3, 5, "dois" } }
	slot := new_caps_clip(cues, 0.05, {255,255,255,255}, 10)
	testing.expect(t, slot >= 0, "cria a faixa")
	if slot < 0 do return
	c := &clips[slot]
	testing.expect(t, c.is_caps && c.is_text, "é faixa de legendas")
	testing.expect(t, clip_text_at(c, 0.5) == "", "antes da 1ª fala: vazio")
	testing.expect(t, clip_text_at(c, 1.5) == "um", "1ª fala")
	testing.expect(t, clip_text_at(c, 3.0) == "dois", "borda t0 da 2ª")
	testing.expect(t, clip_text_at(c, 9) == "", "depois: vazio")
	caps_free(c)
	delete(c.text); c.text = ""
	delete(c.name); c.name = ""
}

@(test)
ovp_guarda_faixa_de_legendas :: proc(t: ^testing.T) {
	t_reset()
	nclips = 0
	cues := []CapCue{ { 0.5, 2.0, "olá" }, { 2.0, 4.0, "mundo" } }
	slot := new_caps_clip(cues, 0.05, {255,255,255,255}, 20)
	testing.expect(t, slot >= 0)
	if slot < 0 do return
	add_seg(slot, 1.0, 0.5, 3.5, 2)
	txt := save_project_text()
	testing.expect(t, strings.contains(txt, "#CAP\t"), "mídia #CAP")
	testing.expect(t, strings.contains(txt, "\ncues 0 2\n"), "seção cues")
	testing.expect(t, strings.contains(txt, "0.500 2.000 olá"), "1ª fala")
	testing.expect(t, strings.contains(txt, "2.000 4.000 mundo"), "2ª fala")
	caps_free(&clips[slot])
	delete(clips[slot].text); clips[slot].text = ""
	delete(clips[slot].name); clips[slot].name = ""
}

@(test)
export_dry_expande_falas :: proc(t: ^testing.T) {
	t_export_reset()
	nclips = 2
	clips[0].path = "A.mp4"; clips[0].probed = true; clips[0].dur = 20; clips[0].src_audio = true
	clips[0].vw = 1920; clips[0].vh = 1080
	clips[1] = Clip{}
	clips[1].is_text = true; clips[1].is_caps = true; clips[1].probed = true; clips[1].dur = 20
	clips[1].text = "olá"
	clips[1].caps = make([dynamic]CapCue)
	append(&clips[1].caps, CapCue{ 0, 2, strings.clone("olá") })
	append(&clips[1].caps, CapCue{ 2, 4, strings.clone("mundo") })
	add_seg(0, 0, 0, 10, 0)
	add_seg(1, 0, 0, 10, 1)
	_, graph, ok := export_build_args("saida.mp4", false, true)
	testing.expect(t, ok, "montagem aceita com faixa de legendas")
	testing.expect(t, strings.contains(graph, "between(t\\,0.000\\,2.000)"), "overlay da 1ª fala")
	testing.expect(t, strings.contains(graph, "between(t\\,2.000\\,4.000)"), "overlay da 2ª fala")
	caps_free(&clips[1])
}
