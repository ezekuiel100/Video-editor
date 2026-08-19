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
srt_descarta_marcacao_de_nao_fala :: proc(t: ^testing.T) {
	src := "1\n00:00:00,000 --> 00:00:01,000\n[Música]\n\n2\n00:00:01,000 --> 00:00:02,000\n(applause)\n\n3\n00:00:02,000 --> 00:00:03,000\nFala de verdade\n"
	cues := parse_srt(src, 0)
	defer { for q in cues do delete(q.text); delete(cues) }
	testing.expect(t, len(cues) == 1, "só a fala real")
	if len(cues) == 1 do testing.expect(t, cues[0].text == "Fala de verdade")
}

@(test)
stt_parse_progresso_real :: proc(t: ^testing.T) {
	p, ok := stt_parse_pct_line("whisper_print_progress_callback: progress =  42%")
	testing.expect(t, ok && t_feq(p, 0.42), "Whisper progress = 42%")
	p, ok = stt_parse_pct_line("Progress: 5%")
	testing.expect(t, ok && t_feq(p, 0.05), "Progress: 5%")
	p, ok = stt_parse_pct_line("################ 40.1%")
	testing.expect(t, ok && abs(p - 0.401) < 0.002, "barra do curl")
	p, ok = stt_parse_pct_line("progress = 100%")
	testing.expect(t, ok && t_feq(p, 1), "100%")
	_, bad := stt_parse_pct_line("lixo sem número")
	testing.expect(t, !bad, "linha sem %")
	sec, ok2 := stt_parse_out_time("out_time_us=2500000")
	testing.expect(t, ok2 && t_feq(sec, 2.5), "ffmpeg out_time_us")
	sec, ok2 = stt_parse_out_time("out_time_ms=1000000")
	testing.expect(t, ok2 && t_feq(sec, 1), "ffmpeg out_time_ms (µs legado)")
	clk, ok3 := stt_parse_arrow_time("[00:00:10.000 --> 00:00:12.400] olá")
	testing.expect(t, ok3 && t_feq(clk, 12.4), "relógio da fala")
}

@(test)
stt_prompt_so_idioma :: proc(t: ^testing.T) {
	testing.expect(t, stt_build_prompt(1) == "Transcrição em português do Brasil.")
	testing.expect(t, stt_build_prompt(3) == "Transcripción en español.")
	testing.expect(t, stt_build_prompt(0) == "")
	testing.expect(t, stt_build_prompt(2) == "")
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
	cap_apply_preset(&clips[slot], .CapCut)
	txt2 := save_project_text()
	testing.expect(t, strings.contains(txt2, "\t2\t0.110\t"), "preset CapCut + contorno no #CAP")
	testing.expect(t, clips[slot].cap_stroke > 0.05, "CapCut tem contorno")
	testing.expect(t, clips[slot].cap_upper, "CapCut em maiúsculas")
	cap_apply_preset(&clips[slot], .YouTube)
	testing.expect(t, clips[slot].cap_box > 0.5, "YouTube tem caixa")
	testing.expect(t, !clips[slot].cap_upper, "YouTube não força maiúsculas")
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

@(test)
caps_edita_apaga_e_insere :: proc(t: ^testing.T) {
	raw := make([dynamic]CapCue)
	defer { for q in raw do delete(q.text); delete(raw) }
	cap_insert(&raw, 2, 3, "b")
	cap_insert(&raw, 0, 1, "a")
	testing.expect(t, len(raw) == 2 && raw[0].text == "a" && raw[1].text == "b")
	testing.expect(t, cap_set_text(&raw, 1, "B"))
	testing.expect(t, raw[1].text == "B")
	testing.expect(t, !cap_set_text(&raw, 1, "B"), "igual não muda")
	testing.expect(t, cap_delete_at(&raw, 0))
	testing.expect(t, len(raw) == 1 && raw[0].text == "B")

	t_reset()
	cues := []CapCue{ { 1, 3, "um" }, { 3, 5, "dois" } }
	slot := new_caps_clip(cues, 0.05, {255,255,255,255}, 10)
	testing.expect(t, slot >= 0)
	if slot < 0 do return
	c := &clips[slot]
	if !testing.expect(t, len(c.caps) == 2, "faixa nasceu com 2 falas") {
		caps_free(c)
		delete(c.text); c.text = ""
		delete(c.name); c.name = ""
		return
	}
	testing.expect(t, caps_set_text(c, 0, "olá"))
	testing.expect(t, c.caps[0].text == "olá", "texto da 1ª")
	testing.expect(t, c.text == "olá", "rótulo acompanha a 1ª fala")
	testing.expect(t, clip_text_at(c, 1.5) == "olá")
	testing.expect(t, caps_delete_at(c, 0))
	testing.expect(t, len(c.caps) == 1, "sobrou a 2ª")
	if len(c.caps) > 0 {
		testing.expect(t, c.caps[0].text == "dois")
		testing.expect(t, c.text == "dois", "rótulo após apagar a 1ª")
	}
	i := caps_insert(c, 0.2, 0.8, "início")
	testing.expect(t, i == 0, "inseriu no começo por t0")
	testing.expect(t, len(c.caps) == 2)
	if len(c.caps) >= 2 {
		testing.expect(t, c.caps[0].text == "início" && c.caps[1].text == "dois")
		testing.expect(t, c.text == "início")
	}
	caps_free(c)
	delete(c.text); c.text = ""
	delete(c.name); c.name = ""
}
