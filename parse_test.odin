package main

// Testes de PARSING: saída do ffprobe (probe_parse), buffer de multi-seleção do
// GetOpenFileNameW (multiselect_paths), mapa de decoder NVDEC (cuvid_of) e a
// forma de onda (wave_peak puro + compute_waveform de PONTA A PONTA com um tom
// gerado pelo ffmpeg — exige ffmpeg no PATH, que é dependência dura do editor).
// Rodar junto com os demais:
//
//   odin test . -out:tests.exe -define:ODIN_TEST_THREADS=1 -define:INVARIANTS=true
//
// (t_reset/t_feq vêm de segs_test.odin — mesmo pacote)

import "core:testing"
import "core:os"
import "base:intrinsics"

@(test)
probe_parse_campos :: proc(t: ^testing.T) {
	d, c, w, h := probe_parse("codec_name=h264\nwidth=1920\nheight=1080\nduration=123.5\n")
	testing.expect(t, t_feq(d, 123.5) && c == "h264", "duração e codec por chave")
	testing.expect(t, w == 1920 && h == 1080, "largura e altura por chave")
}

@(test)
probe_parse_ordem_indiferente :: proc(t: ^testing.T) {
	d, c, w, h := probe_parse("duration=42.0\nwidth=1080\ncodec_name=hevc\nheight=1920\n")
	testing.expect(t, t_feq(d, 42) && c == "hevc" && w == 1080 && h == 1920, "ordem das chaves não importa")
}

@(test)
probe_parse_crlf_e_espacos :: proc(t: ^testing.T) {
	d, c, _, _ := probe_parse("codec_name=hevc\r\nduration=17632.229000\r\n")
	testing.expect(t, c == "hevc", "linhas CRLF do Windows não sujam o codec")
	testing.expect(t, t_feq(d, 17632.229), "duração de vídeo de ~5h parseia")
	d, c, _, _ = probe_parse("  codec_name=vp9  \n\n  duration=42.0  \n")
	testing.expect(t, c == "vp9" && t_feq(d, 42), "espaços e linhas em branco ignorados")
}

@(test)
probe_parse_duracao_na :: proc(t: ^testing.T) {
	d, c, _, _ := probe_parse("duration=N/A\ncodec_name=h264\n")
	testing.expect(t, d == 0 && c == "h264", "duração N/A não quebra o parse")
	d, c, _, _ = probe_parse("")
	testing.expect(t, d == 0 && c == "", "saída vazia = zero-values")
}

@(test)
probe_parse_rotacao_troca_dims :: proc(t: ^testing.T) {
	// celular gravado deitado: pixels 1920x1080 + display matrix -90 → exibe 1080x1920
	_, _, w, h := probe_parse("width=1920\nheight=1080\nrotation=-90\n")
	testing.expect(t, w == 1080 && h == 1920, "rotação -90 (side_data) troca largura/altura")
	_, _, w, h = probe_parse("width=1920\nheight=1080\nTAG:rotate=90\n")
	testing.expect(t, w == 1080 && h == 1920, "tag rotate=90 (ffmpeg antigo) também troca")
	_, _, w, h = probe_parse("width=1080\nheight=1920\nrotation=180\n")
	testing.expect(t, w == 1080 && h == 1920, "rotação 180 não inverte dimensões")
	_, _, w, h = probe_parse("width=1080\nheight=1920\n")
	testing.expect(t, w == 1080 && h == 1920, "sem rotação: dimensões como vieram")
}

@(test)
find_media_dedup :: proc(t: ^testing.T) {
	t_reset()
	nclips = 3
	clips[0].path = "C:\\videos\\a.mp4"
	clips[1].path = "C:\\videos\\b.mp4"; clips[1].closed = true // removida (tombstone)
	clips[2].path = "C:\\videos\\c.mp4"
	testing.expect(t, find_media_by_path("C:\\videos\\a.mp4") == 0, "acha por caminho exato")
	testing.expect(t, find_media_by_path("c:\\VIDEOS\\A.MP4") == 0, "case-insensitive (Windows)")
	testing.expect(t, find_media_by_path("C:\\videos\\b.mp4") == -1, "tombstone (closed) não conta")
	testing.expect(t, find_media_by_path("C:\\videos\\z.mp4") == -1, "não importado = -1")
	testing.expect(t, find_media_by_path("") == -1, "caminho vazio = -1")
	clips[2].is_text = true
	testing.expect(t, find_media_by_path("C:\\videos\\c.mp4") == -1, "clipe de texto ignorado")
}

@(test)
audio_dup_ownership :: proc(t: ^testing.T) {
	t_reset()
	clips[0].has_audio = true; clips[0].dur = 100
	nsegs = 2
	segs[0] = Seg{ src = 0, start = 0, dur = 10, in_off = 0,  track = 0, speed = 1 } // V1
	segs[1] = Seg{ src = 0, start = 0, dur = 10, in_off = 20, track = 1, speed = 1 } // V2 (mesma fonte)
	st.playhead = 5; play_clip = -1
	// dono do c.music = trilha mais baixa; o outro (conteúdo diferente) é duplicado -> spv
	testing.expect(t, music_owner_of(0) == 0, "dono = trilha mais baixa")
	testing.expect(t, !seg_audio_dup(0), "o dono não é duplicado")
	testing.expect(t, seg_audio_dup(1), "sobreposto com in_off diferente = duplicado")
	// mesma posição na fonte (cópia idêntica empilhada) NÃO duplica (evita eco)
	segs[1].in_off = 0
	testing.expect(t, !seg_audio_dup(1), "cópia idêntica não vira duplicado")
	// o master (play_clip) é sempre o dono da sua fonte
	segs[1].in_off = 20; play_clip = 1
	testing.expect(t, music_owner_of(0) == 1, "master é o dono da fonte")
	testing.expect(t, seg_audio_dup(0), "o outro seg (conteúdo diferente) vira duplicado")
	// fora do playhead ninguém duplica
	st.playhead = 50
	testing.expect(t, !seg_audio_dup(0) && !seg_audio_dup(1), "fora do playhead: sem duplicado")
}

@(test)
proj_res_e_ratio :: proc(t: ^testing.T) {
	set_proj_res(720, 732)
	testing.expect(t, proj_w == 720 && proj_h == 732, "resolução exata (par)")
	rw, rh := ratio_reduce(720, 732)
	testing.expect(t, rw == 60 && rh == 61, "razão irredutível 720x732 = 60:61")
	set_proj_res(1921, 1080) // ímpar -> arredonda p/ par
	testing.expect(t, proj_w == 1920 && proj_h == 1080, "força dimensões pares")
	set_proj_ar(9.0/16)
	testing.expect(t, proj_w == 1080 && proj_h == 1920, "9:16 -> 1080x1920 (lado menor 1080)")
	set_proj_ar(16.0/9)
	testing.expect(t, proj_w == 1920 && proj_h == 1080, "16:9 -> 1920x1080")
}

// monta o buffer UTF-16 do GetOpenFileNameW: pedaços separados por NUL, NUL duplo
// no fim (o make já zera o resto, como o buffer real)
t_wbuf :: proc(parts: []string) -> []u16 {
	buf := make([]u16, 256, context.temp_allocator)
	i := 0
	for p in parts {
		for ch in p { buf[i] = u16(ch); i += 1 }
		i += 1 // NUL separador
	}
	return buf
}

@(test)
multiselect_um_arquivo :: proc(t: ^testing.T) {
	paths, ok := multiselect_paths(t_wbuf([]string{"C:\\videos\\a.mp4"}))
	testing.expect(t, ok && len(paths) == 1, "1 arquivo = 1 caminho")
	testing.expect(t, paths[0] == "C:\\videos\\a.mp4", "1 arquivo já vem completo (não junta com dir)")
}

@(test)
multiselect_varios_arquivos :: proc(t: ^testing.T) {
	paths, ok := multiselect_paths(t_wbuf([]string{"C:\\videos", "a.mp4", "b.mp4"}))
	testing.expect(t, ok && len(paths) == 2, "N arquivos: dir vem 1x, sobram N caminhos")
	testing.expect(t, paths[0] == "C:\\videos\\a.mp4", "dir juntado com o 1º nome")
	testing.expect(t, paths[1] == "C:\\videos\\b.mp4", "dir juntado com o 2º nome")
}

@(test)
multiselect_cancelado :: proc(t: ^testing.T) {
	vazio := make([]u16, 8, context.temp_allocator)
	_, ok := multiselect_paths(vazio)
	testing.expect(t, !ok, "buffer só com NULs (nada selecionado) = false")
}

@(test)
cuvid_mapa_de_codecs :: proc(t: ^testing.T) {
	testing.expect(t, cuvid_of("h264") == "h264_cuvid", "h264 tem decoder NVDEC")
	testing.expect(t, cuvid_of("hevc") == "hevc_cuvid", "hevc tem decoder NVDEC")
	testing.expect(t, cuvid_of("prores") == "", "codec sem NVDEC cai p/ software")
	testing.expect(t, cuvid_of("") == "", "codec vazio (probe falhou) = software")
	t_reset()
	clips[0].vcodec = "h264"
	clips[0].no_hw = true
	testing.expect(t, use_cuvid(&clips[0]) == "", "no_hw força software mesmo com codec suportado")
}

@(test)
wave_peak_intervalos :: proc(t: ^testing.T) {
	t_reset()
	c := &clips[0]
	c.dur = 3
	c.wave = make([]f32, 300) // 3s × WAVE_PPS buckets
	defer { delete(c.wave); c.wave = nil }
	c.wave[150] = 0.8 // pico em t=1.5s
	testing.expect(t, wave_peak(c, 1.4, 1.6) == -1, "antes de wave_ready = -1 (desenha linha fina)")
	intrinsics.atomic_store(&c.wave_ready, true)
	testing.expect(t, t_feq(wave_peak(c, 1.4, 1.6), 0.8), "pico do intervalo")
	testing.expect(t, wave_peak(c, 0, 1) == 0, "intervalo sem som = 0")
	testing.expect(t, t_feq(wave_peak(c, 1.5, 1.5), 0.8), "intervalo degenerado (t0=t1) não quebra")
	testing.expect(t, wave_peak(c, 250, 300) == 0, "além do fim clampa no array (não estoura)")
}

// PONTA A PONTA: gera 0.5s de senoide 440Hz com o ffmpeg e roda o compute_waveform
// real (pipe de PCM s16le). O clip é falso (dur=1): a 1ª metade dos buckets deve
// encher com pico alto e a 2ª (sem áudio no arquivo) ficar em 0.
@(test)
waveform_pcm_de_verdade :: proc(t: ^testing.T) {
	t_reset()
	tone := "C:/Users/Adm/AppData/Local/Temp/odin_editor_test_tone.wav"
	_, _, serr, e := os.process_exec(os.Process_Desc{ command = []string{
		"ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
		// a fonte `sine` gera a ~-18dB (~0.125): amplifica p/ perto do full-scale
		"-f", "lavfi", "-i", "sine=frequency=440:duration=0.5", "-af", "volume=17dB", tone,
	}}, context.temp_allocator)
	if !testing.expectf(t, e == nil, "ffmpeg (dependência do editor) não rodou: %v %s", e, string(serr)) do return
	c := &clips[0]
	c.path = tone
	c.dur = 1
	compute_waveform(c)
	defer { delete(c.wave); c.wave = nil }
	testing.expect(t, intrinsics.atomic_load(&c.wave_ready), "wave_ready publicada")
	testing.expect(t, len(c.wave) == 100, "1s × WAVE_PPS buckets")
	testing.expect(t, wave_peak(c, 0.1, 0.4) > 0.3, "trecho com tom tem pico alto")
	testing.expect(t, wave_peak(c, 0.7, 0.95) < 0.01, "trecho além do áudio fica em 0")
}
