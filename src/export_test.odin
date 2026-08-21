package main

// Testes da EXPORTAÇÃO. Rodar junto com o resto:
//
//   odin test src -out:tests.exe -define:ODIN_TEST_THREADS=1 -define:INVARIANTS=true
//
// Por que estes testes existem: erro no export falha em SILÊNCIO. O ffmpeg aceita
// um filtergraph com o trim deslocado sem reclamar — sai um arquivo perfeitamente
// válido, com o áudio fora do lugar. Não há exceção, código de saída != 0, nem
// nada na tela: só o usuário percebendo depois. Então o que dá p/ checar sem rodar
// o ffmpeg (a matemática dos trechos e o texto do grafo) é checado aqui.
//
// Usa o t_reset() do segs_test.odin (mesmo package): 2 fontes falsas de 100s.

import "core:testing"
import "core:strings"
import "core:strconv"
import "core:fmt"

// ---------- seg_src_span: trecho da FONTE consumido por um segmento ----------
// Alimenta o `-ss` do input E o `trim` do filtro. Se os dois divergissem, o vídeo
// sairia deslocado sem erro nenhum — daí ser fonte única da verdade.

@(test)
span_sem_transicao :: proc(t: ^testing.T) {
	t_reset()
	si := add_seg(0, 0, 10, 5) // fonte 0, timeline em 0, in_off 10, dur 5
	t0, t1, fh, tl := seg_src_span(si, 0, 0)
	testing.expect(t, t_feq(t0, 10), "sem transição o trecho começa no in_off")
	testing.expect(t, t_feq(t1, 15), "e termina em in_off+dur")
	testing.expect(t, fh == 0 && tl == 0, "sem handles não há nada p/ congelar")
}

@(test)
span_velocidade_consome_o_dobro :: proc(t: ^testing.T) {
	t_reset()
	si := add_seg(0, 0, 10, 5)
	segs[si].speed = 2 // 5s de timeline saem de 10s de fonte
	t0, t1, _, _ := seg_src_span(si, 0, 0)
	testing.expect(t, t_feq(t0, 10) && t_feq(t1, 20), "speed=2 consome dur*2 da fonte")
	segs[si].speed = 0.5 // câmera lenta: 5s de timeline saem de 2.5s de fonte
	_, t1s, _, _ := seg_src_span(si, 0, 0)
	testing.expect(t, t_feq(t1s, 12.5), "speed=0.5 consome dur/2 da fonte")
}

@(test)
span_handles_com_folga :: proc(t: ^testing.T) {
	t_reset()
	si := add_seg(0, 0, 10, 5) // sobra fonte dos 2 lados (clipe tem 100s)
	t0, t1, fh, tl := seg_src_span(si, 1, 1)
	testing.expect(t, t_feq(t0, 9), "há footage antes do in-point: o trecho recua o handle inteiro")
	testing.expect(t, t_feq(t1, 16), "e avança o handle inteiro depois do out-point")
	testing.expect(t, fh == 0 && tl == 0, "com folga dos 2 lados nada é congelado")
}

@(test)
span_handle_curto_congela_o_resto :: proc(t: ^testing.T) {
	t_reset()
	si := add_seg(0, 0, 0.5, 5) // in_off 0.5: só meio segundo de footage antes
	t0, _, fh, _ := seg_src_span(si, 2, 0)
	testing.expect(t, t_feq(t0, 0), "não dá p/ recuar além do começo da fonte")
	testing.expect(t, t_feq(fh, 1.5), "o que faltou do handle vira congelamento (tpad)")

	sj := add_seg(1, 20, 95, 5) // termina exatamente no fim da fonte de 100s
	_, t1, _, tl := seg_src_span(sj, 0, 2)
	testing.expect(t, t_feq(t1, 100), "não dá p/ avançar além do fim da fonte")
	testing.expect(t, t_feq(tl, 2), "a cauda inteira do handle vira congelamento")
}

@(test)
span_imagem_sempre_do_zero :: proc(t: ^testing.T) {
	t_reset()
	clips[0].is_img = true
	si := add_seg(0, 0, 10, 5) // in_off é ignorado: o input é um frame em loop
	t0, t1, fh, tl := seg_src_span(si, 1, 1)
	testing.expect(t, t_feq(t0, 0), "imagem entra em loop desde 0, ignorando o in_off")
	testing.expect(t, t_feq(t1, 7), "e dura dur+handles")
	testing.expect(t, fh == 0 && tl == 0, "imagem nunca congela: o loop cobre qualquer handle")
}

// A INVARIANTE que protege a sincronia: o material entregue ao filtro é sempre
// exatamente o que o segmento precisa. Trecho lido da fonte + o que for congelado
// nas pontas tem de bater com dur*speed + os dois handles — em QUALQUER combinação
// de folga. Se esta conta furar, o trim recorta um pedaço que não corresponde ao
// tempo pedido e a exportação sai dessincronizada, sem nenhum aviso.
@(test)
span_conserva_a_duracao :: proc(t: ^testing.T) {
	Caso :: struct { in_off, dur, speed, hd, tl: f32 }
	casos := []Caso{
		{10,   5, 1,   0,   0  }, // sem transição
		{10,   5, 1,   1,   1  }, // handles com folga dos 2 lados
		{0.5,  5, 1,   2,   0  }, // cabeça curta
		{95,   5, 1,   0,   2  }, // cauda no fim exato da fonte
		{0,    5, 1,   1.5, 1.5}, // in-point no 0: nenhuma folga na cabeça
		{10,   5, 2,   0,   0  }, // 2x
		{10,   5, 0.5, 1,   1  }, // câmera lenta com handles
		{0.25, 4, 1,   3,   3  }, // as duas pontas curtas ao mesmo tempo
	}
	for cs, k in casos {
		t_reset()
		si := add_seg(0, 0, cs.in_off, cs.dur)
		segs[si].speed = cs.speed
		t0, t1, fh, tl := seg_src_span(si, cs.hd, cs.tl)
		pedido := cs.dur*cs.speed + cs.hd + cs.tl
		entregue := (t1 - t0) + fh + tl
		testing.expectf(t, t_feq(entregue, pedido),
			"caso %d: fonte %.3f..%.3f + congelado %.3f/%.3f = %.3f, mas o segmento pede %.3f",
			k, t0, t1, fh, tl, entregue, pedido)
		// e nunca sai dos limites da fonte (ffmpeg não erra por isso — só entrega menos)
		testing.expectf(t, t0 >= -0.001, "caso %d: trecho começa antes do 0 da fonte (%.3f)", k, t0)
		testing.expectf(t, t1 <= clips[0].dur + 0.001, "caso %d: trecho passa do fim da fonte (%.3f)", k, t1)
	}
}

// ---------- montagem do comando (export_build_args em modo dry) ----------
// dry = sem disco e sem GL; o comando montado é o MESMO do export de verdade, então dá
// p/ conferir o texto do grafo aqui. As fontes são falsas (path/dur/src_audio), o que
// basta: nada nesta montagem abre os arquivos.
// Nestes cenários (sem texto nem distorção) o índice do input do ffmpeg coincide com o
// índice do segmento, então "[1:v]" é o segundo add_seg.

// 3 fontes de vídeo com áudio, 100s cada, saída 1920x1080
t_export_reset :: proc() {
	t_reset()
	nclips = 3
	for i in 0 ..< 3 {
		clips[i] = Clip{}
		clips[i].probed = true
		clips[i].dur = 100
		clips[i].src_audio = true // a FONTE tem faixa de áudio — é o que o export consulta
		clips[i].vw = 1920; clips[i].vh = 1080
	}
	clips[0].path = "A.mp4"; clips[1].path = "B.mp4"; clips[2].path = "C.mp4"
	for i in 0 ..< MAXTRACKS do track_hidden[i] = false
	proj_w = 1920; proj_h = 1080
	export_fmt = .MP4
	export_qual = .Medium // NÃO usar .Auto aqui: ela roda ffprobe nas fontes
}

// monta e devolve (args, grafo); falha o teste se a montagem for recusada.
// O grafo vem pelo RETORNO, não de dentro de args: ele viaja num arquivo
// (-filter_complex_script) para não estourar o limite da linha de comando do Windows.
t_build :: proc(t: ^testing.T) -> (args: [dynamic]string, graph: string) {
	ok: bool
	args, graph, ok = export_build_args("saida.mp4", false, true)
	if !testing.expect(t, ok, "a montagem do comando foi recusada") do return
	testing.expect(t, t_has(args, "-filter_complex_script"), "comando sem -filter_complex_script")
	return
}

// o comando contém este argumento?
t_has :: proc(args: [dynamic]string, flag: string) -> bool {
	for a in args do if a == flag do return true
	return false
}

// valor do argumento seguinte a `flag` (primeira ocorrência)
t_arg_after :: proc(args: [dynamic]string, flag: string) -> (string, bool) {
	for a, i in args do if a == flag && i+1 < len(args) do return args[i+1], true
	return "", false
}

t_joined :: proc(args: [dynamic]string) -> string {
	return strings.join(args[:], " ", context.temp_allocator)
}

// lê um número no começo de `s`; devolve o valor e quantos bytes consumiu
t_num_head :: proc(s: string) -> (v: f32, n: int, ok: bool) {
	for n < len(s) && (s[n] == '.' || s[n] == '-' || (s[n] >= '0' && s[n] <= '9')) do n += 1
	v, ok = strconv.parse_f32(s[:n])
	return
}

// intervalo "A:B" logo depois de `prefix` — t_range(g, "[0:v]trim=") -> (60, 70)
t_range :: proc(s, prefix: string) -> (a, b: f32, ok: bool) {
	i := strings.index(s, prefix)
	if i < 0 do return
	p := i + len(prefix)
	na, n1, ok1 := t_num_head(s[p:])
	if !ok1 || p+n1 >= len(s) || s[p+n1] != ':' do return
	nb, _, ok2 := t_num_head(s[p+n1+1:])
	if !ok2 do return
	return na, nb, true
}

// O ACOPLAMENTO CENTRAL: o `-ss` do input e o `trim` do filtro saem os DOIS do
// seg_src_span. O -ss pula direto pro trecho (sem ele o ffmpeg decodifica desde o
// segundo zero — medido: >120s só p/ COMEÇAR num trecho aos 60min de um arquivo de 4h)
// e o trim recorta em tempo ABSOLUTO da fonte. Divergir = vídeo deslocado, sem erro.
@(test)
graph_ss_casa_com_o_trim :: proc(t: ^testing.T) {
	t_export_reset()
	add_seg(0, 0, 60, 10) // trecho 60..70 da fonte
	args, g := t_build(t)
	ss, has := t_arg_after(args, "-ss")
	testing.expect(t, has, "input sem -ss: o ffmpeg decodificaria desde o segundo zero")
	v, _ := strconv.parse_f32(ss)
	a, b, ok := t_range(g, "[0:v]trim=")
	testing.expect(t, ok, "grafo sem trim de vídeo")
	testing.expectf(t, t_feq(a, 60) && t_feq(b, 70), "trim deveria ser 60..70, veio %.3f..%.3f", a, b)
	testing.expectf(t, t_feq(v, a - 2), "-ss (%.3f) tem de ser o início do trim (%.3f) menos o recuo de keyframe", v, a)
}

// -copyts PRESERVA os timestamps da fonte. Sem ele o seek rebaseia tudo p/ zero e CADA
// trim/atrim do grafo (que fala em tempo absoluto) teria de ser deslocado à mão — foi
// por aí que uma versão anterior passou no vídeo e dessincronizou o áudio.
@(test)
graph_todo_ss_vem_com_copyts :: proc(t: ^testing.T) {
	t_export_reset()
	add_seg(0, 0, 60, 10)
	add_seg(1, 10, 30, 5)
	args, _ := t_build(t)
	n := 0
	for a, i in args {
		if a != "-ss" do continue
		n += 1
		testing.expectf(t, i+2 < len(args) && args[i+2] == "-copyts",
			"-ss no índice %d sem -copyts logo depois: o grafo inteiro sairia deslocado", i)
	}
	testing.expect(t, n == 2, "os dois segmentos deveriam ter seek na entrada")
}

// O erro que falha CALADO: vídeo e áudio recortados em trechos diferentes da fonte.
// Sai um arquivo válido, sem aviso nenhum, com o som fora do lugar.
@(test)
graph_audio_e_video_no_mesmo_trecho :: proc(t: ^testing.T) {
	t_export_reset()
	add_seg(0, 0, 60, 10)
	add_seg(1, 10, 12.5, 8)
	_, g := t_build(t)
	for k in 0 ..< 2 {
		va, vb, ok1 := t_range(g, fmt.tprintf("[%d:v]trim=", k))
		aa, ab, ok2 := t_range(g, fmt.tprintf("[%d:a]atrim=", k))
		testing.expectf(t, ok1 && ok2, "segmento %d: faltou trim de vídeo ou de áudio", k)
		testing.expectf(t, t_feq(va, aa) && t_feq(vb, ab),
			"segmento %d: vídeo em %.3f..%.3f mas áudio em %.3f..%.3f", k, va, vb, aa, ab)
	}
}

@(test)
graph_adelay_posiciona_na_timeline :: proc(t: ^testing.T) {
	t_export_reset()
	add_seg(0, 0, 0, 10)
	add_seg(1, 10, 0, 8) // entra aos 10s da timeline
	_, g := t_build(t)
	testing.expect(t, strings.contains(g, "adelay=0:all=1"), "o 1º segmento entra sem atraso")
	testing.expect(t, strings.contains(g, "adelay=10000:all=1"), "o 2º entra aos 10000ms")
	testing.expect(t, strings.contains(g, "amix=inputs=2"), "os dois entram no mix")
}

@(test)
graph_velocidade_consome_mais_fonte :: proc(t: ^testing.T) {
	t_export_reset()
	si := add_seg(0, 0, 10, 5)
	segs[si].speed = 4 // 5s de timeline saem de 20s de fonte
	_, g := t_build(t)
	a, b, _ := t_range(g, "[0:v]trim=")
	testing.expectf(t, t_feq(b-a, 20), "a 4x o trim consome 20s de fonte, veio %.3f", b-a)
	aa, ab, _ := t_range(g, "[0:a]atrim=")
	testing.expectf(t, t_feq(ab-aa, 20), "o áudio consome o mesmo trecho, veio %.3f", ab-aa)
	// atempo aceita 0.5..2 por estágio: 4x tem de sair encadeado
	testing.expect(t, strings.count(g, "atempo=") >= 2, "4x precisa de atempo encadeado (2.0 x 2.0)")
}

@(test)
graph_mudo_fica_fora_do_mix :: proc(t: ^testing.T) {
	t_export_reset()
	add_seg(0, 0, 0, 10)
	b := add_seg(1, 10, 0, 8)
	segs[b].muted = true
	_, g := t_build(t)
	testing.expect(t, !strings.contains(g, "[1:a]"), "segmento mudo sai do grafo de áudio")
	testing.expect(t, !strings.contains(g, "amix=inputs=2"), "sobra uma fonte de áudio só")
	testing.expect(t, strings.contains(g, "[1:v]trim="), "mas o VÍDEO dele continua")

	segs[b].muted = false
	track_muted[segs[b].track] = true
	_, g2 := t_build(t)
	testing.expect(t, !strings.contains(g2, "[1:a]"), "trilha muda também tira o segmento do mix")
	track_muted[segs[b].track] = false
}

@(test)
graph_trilha_oculta_sai_do_video_mas_continua_no_audio :: proc(t: ^testing.T) {
	t_export_reset()
	add_seg(0, 0, 0, 10)
	add_seg(1, 0, 0, 10, 1) // trilha 1, por cima
	track_hidden[1] = true
	_, g := t_build(t)
	testing.expect(t, !strings.contains(g, "[1:v]trim="), "trilha oculta (olho) sai do vídeo exportado")
	testing.expect(t, strings.contains(g, "[1:a]atrim="), "mas o áudio dela continua no mix")
	track_hidden[1] = false
}

@(test)
graph_mp3_e_so_audio :: proc(t: ^testing.T) {
	t_export_reset()
	export_fmt = .MP3
	add_seg(0, 0, 60, 10)
	args, g := t_build(t)
	testing.expect(t, !strings.contains(g, "color=c=black"), "MP3 não monta o quadro de vídeo")
	testing.expect(t, !strings.contains(g, "[0:v]"), "MP3 não usa o vídeo da fonte")
	testing.expect(t, strings.contains(g, "[0:a]atrim="), "mas monta o áudio")
	j := t_joined(args)
	testing.expect(t, !strings.contains(j, "[vout]"), "MP3 não mapeia saída de vídeo")
	testing.expect(t, strings.contains(j, "-vn"), "MP3 descarta o vídeo no codec")
	export_fmt = .MP4
}

// Sem -t o muxer espera vídeo depois que o color=d=total acabou (áudio do atempo
// passa uns ms) e a exportação NÃO TERMINA. -nostdin evita o ffmpeg ficar à espera
// de 'q' no stdin herdado da janela.
@(test)
export_tem_teto_de_duracao_e_nostdin :: proc(t: ^testing.T) {
	t_export_reset()
	add_seg(0, 0, 0, 10)
	args, _ := t_build(t)
	testing.expect(t, t_has(args, "-nostdin"), "sem -nostdin o ffmpeg pode travar no stdin da GUI")
	testing.expect(t, t_has(args, "-t"), "sem -t a exportação pode nunca fechar o arquivo")
	testing.expect(t, t_has(args, "-max_muxing_queue_size"), "fila pequena trava com prévia+áudio")
	// opção de SAÍDA: antes do 1º -i o ffmpeg aborta ("cannot be applied to input url")
	ii, qi := -1, -1
	for a, i in args {
		if a == "-i" && ii < 0 do ii = i
		if a == "-max_muxing_queue_size" && qi < 0 do qi = i
	}
	testing.expect(t, qi > ii && ii >= 0, "max_muxing_queue_size tem de vir DEPOIS dos -i")
}

// Dissolver: a cabeça do clipe de entrada estica d/2 e o -ss tem de acompanhar, senão o
// trim pede material que o input não entregou — a transição sai curta, sem erro nenhum.
@(test)
graph_dissolver_estica_a_cabeca_e_o_ss_acompanha :: proc(t: ^testing.T) {
	t_export_reset()
	add_seg(0, 0, 10, 10)       // A: timeline 0..10
	b := add_seg(1, 10, 30, 10) // B: timeline 10..20, encostado em A
	segs[b].trans = 2           // dissolver de 2s centrado no corte: B começa 1s antes
	args, g := t_build(t)
	a, _, ok := t_range(g, "[1:v]trim=")
	testing.expect(t, ok, "grafo sem o trim de B")
	testing.expectf(t, t_feq(a, 29), "B tem handle de sobra: o trim recua 1s (30->29), veio %.3f", a)
	testing.expect(t, strings.contains(g, "fade=t=in"), "o clipe de entrada precisa do fade do dissolver")
	testing.expect(t, strings.contains(g, "fade=t=out"), "e o de saída, do fade complementar")
	// o input de B tem de ter recuado junto (senão o trim pede o que não veio)
	ssb := ""
	n := 0
	for s, i in args {
		if s == "-ss" { n += 1; if n == 2 do ssb = args[i+1] }
	}
	v, _ := strconv.parse_f32(ssb)
	testing.expectf(t, t_feq(v, a - 2), "o -ss de B (%.3f) tem de sair do mesmo trecho do trim (%.3f)", v, a)
}

@(test)
graph_timeline_vazia_nao_monta :: proc(t: ^testing.T) {
	t_export_reset()
	_, _, ok := export_build_args("saida.mp4", false, true)
	testing.expect(t, !ok, "sem segmentos não há o que exportar")
}

@(test)
export_recusa_com_midia_importando :: proc(t: ^testing.T) {
	t_export_reset()
	add_seg(0, 0, 0, 10)
	add_seg(1, 0, 0, 10) // encosta no primeiro (add_seg acha o vão)
	if _, _, ok := export_build_args("saida.mp4", false, true); !ok {
		testing.expect(t, false, "com as duas mídias prontas a montagem tinha de passar")
		return
	}
	// a fonte de B volta a "importando" (probe em curso): o export NÃO pode seguir e
	// entregar preto no lugar dela — tem de recusar e mandar esperar
	clips[1].probed = false
	testing.expect(t, segs_importing() == 1, "1 segmento com a mídia ainda em probe")
	_, _, ok := export_build_args("saida.mp4", false, true)
	testing.expect(t, !ok, "mídia importando tem de RECUSAR o export, não exportar um buraco preto")

	// mídia que FALHOU é diferente: nunca vai ficar pronta, então não pode travar o export
	clips[1].probed = true; clips[1].failed = true
	testing.expect(t, segs_importing() == 0, "mídia falha não conta como 'importando'")
	_, _, ok2 := export_build_args("saida.mp4", false, true)
	testing.expect(t, ok2, "com a mídia marcada como falha o export segue (sem ela)")
	clips[1].failed = false
}

@(test)
salvar_nao_descarta_segmento_em_probe :: proc(t: ^testing.T) {
	t_export_reset()
	clips[0].path = "A.mp4"; clips[1].path = "B.mp4"; clips[2].path = "C.mp4"
	add_seg(0, 0, 0, 10)
	add_seg(1, 0, 0, 10)
	add_seg(2, 0, 0, 10)
	// a mídia do meio ainda está importando — o .ovp NÃO pode perdê-la em silêncio
	clips[1].probed = false
	txt := save_project_text()
	testing.expect(t, strings.contains(txt, "\nseg 3\n"), "os 3 segmentos têm de ir para o arquivo")
	// e a contagem tem de bater com as linhas realmente emitidas (senão o load lê lixo)
	i := strings.index(txt, "\nseg 3\n")
	body := txt[i + len("\nseg 3\n"):]
	emitidos := 0
	for ln in strings.split_lines_iterator(&body) {
		if ln == "" || !(ln[0] >= '0' && ln[0] <= '9') do break
		emitidos += 1
	}
	testing.expectf(t, emitidos == 3, "cabeçalho diz 3 segmentos, saíram %d", emitidos)

	// mídia REMOVIDA (tombstone) continua fora: idx = -1
	clips[1].probed = true; clips[1].closed = true
	txt2 := save_project_text()
	testing.expect(t, strings.contains(txt2, "\nseg 2\n"), "segmento de mídia removida não é salvo")
	clips[1].closed = false
}

@(test)
ovp_guarda_flags_de_trilha_e_bulge :: proc(t: ^testing.T) {
	t_export_reset()
	si := add_seg(0, 0, 0, 10)
	segs[si].bulge = 0.45
	segs[si].bulge_x = 0.10
	segs[si].bulge_y = -0.20
	segs[si].bulge_r = 0.35
	segs[si].wobble = 0.15
	segs[si].wobble_speed = 2.5
	track_muted[0] = true
	track_locked[2] = true
	track_hidden[1] = true

	txt := save_project_text()
	testing.expect(t, strings.contains(txt, "\ntrackm "), "mute da trilha tem de ir no arquivo")
	testing.expect(t, strings.contains(txt, "\ntrackl "), "lock da trilha tem de ir no arquivo")
	testing.expect(t, strings.contains(txt, "\ntrackv "), "hide da trilha tem de ir no arquivo")

	// limpa o que o usuário veria ao reabrir (sem tocar disco / ffmpeg)
	nsegs = 0
	segs[0] = Seg{}
	for i in 0 ..< MAXTRACKS { track_muted[i] = false; track_locked[i] = false; track_hidden[i] = false }

	p, ok := parse_project_text(txt)
	testing.expect(t, ok, "texto emitido pelo save tem de parsear")
	testing.expect(t, p.muted[0] && !p.muted[1], "trilha 0 muda, as outras não")
	testing.expect(t, p.locked[2] && !p.locked[0], "trilha 2 bloqueada")
	testing.expect(t, p.hidden[1] && !p.hidden[0], "trilha 1 oculta")
	testing.expect(t, p.nseg == 1, "1 segmento no arquivo")
	testing.expect(t, t_feq(p.fields[0][34], 0.45), "bulge")
	testing.expect(t, t_feq(p.fields[0][35], 0.10), "bulge_x")
	testing.expect(t, t_feq(p.fields[0][36], -0.20), "bulge_y")
	testing.expect(t, t_feq(p.fields[0][37], 0.35), "bulge_r")
	testing.expect(t, t_feq(p.fields[0][38], 0.15), "wobble")
	testing.expect(t, t_feq(p.fields[0][39], 2.5), "wobble_speed")
	testing.expect(t, t_feq(p.fields[0][40], 0), "trans_mode padrão = dissolver")

	apply_parsed_project(p)
	testing.expect(t, nsegs == 1 && t_feq(segs[0].bulge, 0.45) && t_feq(segs[0].wobble, 0.15), "apply restaura bulge/wobble")
	testing.expect(t, track_muted[0] && track_locked[2] && track_hidden[1], "apply restaura mute/lock/hide")
}

@(test)
ovp_antigo_sem_flags_nem_bulge_abre_neutro :: proc(t: ^testing.T) {
	t_export_reset()
	// 34 campos (formato anterior): sem bulge e sem trackm/l/v
	old := "OVP1\nar 1.777778\nres 1920 1080\ntracks 3 2\nmedia 1\nA.mp4\nseg 1\n0 0 0.0000 0.0000 10.0000 1.0000 0 0.0000 0.0000 1.0000 0.0000 0.0000 0.0000 1.0000 1.0000 0.0000 0.0000 0.0000 0.0000 0.0000 0.0000 0.0000 0 0.0000 0.0000 0.0000 0.0000 0 0.0000 0.0000 0.0000 0.0000 0.0000 0.0000\n"
	p, ok := parse_project_text(old)
	testing.expect(t, ok && p.nseg == 1, "projeto antigo ainda parseia")
	testing.expect(t, !p.muted[0] && !p.locked[0] && !p.hidden[0], "sem as chaves novas = trilhas ligadas")
	testing.expect(t, p.fields[0][34] == 0 && p.fields[0][38] == 0, "campos ausentes nascem 0 (sem distorção)")
	apply_parsed_project(p)
	testing.expect(t, nsegs == 1 && segs[0].bulge == 0 && segs[0].wobble == 0, "bulge ausente = neutro")
	testing.expect(t, !track_muted[0] && !track_locked[0] && !track_hidden[0], "flags ausentes = desligadas")
}

// O FILTERGRAPH NÃO PODE VIAJAR NA LINHA DE COMANDO. Ele é a maior coisa do comando e o
// Windows corta em 32767 chars no CreateProcessW: com a timeline cheia o export morria com
// um "Falha ao iniciar ffmpeg" que não dizia nada. Vai por -filter_complex_script.
@(test)
grafo_grande_fica_fora_da_linha_de_comando :: proc(t: ^testing.T) {
	t_export_reset()
	// timeline cheia de segmentos curtos e enfeitados: é o que engorda o grafo de verdade
	// (crop + zoom animado + cor + rotação + fades somam centenas de chars por segmento)
	for k in 0 ..< MAX_SEGS {
		si := add_seg(k % 3, f32(k) * 2, 0, 2)
		if si < 0 do break
		s := &segs[si]
		s.fade_in = 0.2; s.fade_out = 0.2
		s.fx_bright = 0.1; s.fx_contrast = 0.1; s.fx_satur = 0.1; s.fx_temp = 0.1; s.fx_vignette = 0.3
		s.crop_x = 0.1; s.crop_y = 0.1; s.crop_w = 0.8; s.crop_h = 0.8
		s.zoom_anim = true
		s.crop2_x = 0.2; s.crop2_y = 0.2; s.crop2_w = 0.5; s.crop2_h = 0.5
		s.rot = 5; s.scale = 0.9; s.opacity = 0.9
	}
	testing.expectf(t, nsegs == MAX_SEGS, "cenário precisa da timeline cheia, tem %d", nsegs)
	args, g := t_build(t)

	// o grafo destes segmentos passa MUITO do que cabia numa linha de comando
	testing.expectf(t, len(g) > 20000, "grafo de %d segmentos deveria ser enorme, veio com %d chars", nsegs, len(g))
	// e mesmo assim nenhum argumento carrega o grafo: ele está no arquivo do script
	maior := 0
	for a in args do maior = max(maior, len(a))
	testing.expectf(t, maior < len(g), "algum argumento (%d chars) ainda carrega o grafo inteiro", maior)
	// o que sobra na linha de comando cabe folgado no teto do Windows
	n := cmdline_len(args)
	testing.expectf(t, n < CMDLINE_MAX, "linha de comando com %d chars passa do teto de %d", n, CMDLINE_MAX)
	// e o script é passado por caminho de arquivo, não pelo conteúdo
	p, ok := t_arg_after(args, "-filter_complex_script")
	testing.expect(t, ok, "faltou o -filter_complex_script")
	testing.expectf(t, len(p) < 260 && !strings.contains(p, ";"), "o argumento devia ser o caminho do script, veio %d chars", len(p))
}

// o ffmpeg roda com `-progress pipe:2`, então progresso e ERRO saem no mesmo stderr. O
// worker descartava tudo que não era progresso e a causa da falha se perdia — sem console,
// o usuário só via "Falha na exportação". Este é o filtro que separa os dois.
@(test)
progress_line_separa_progresso_de_erro :: proc(t: ^testing.T) {
	testing.expect(t, progress_line("frame=42"), "linha de -progress")
	testing.expect(t, progress_line("out_time_us=1000000"), "chave com underscore também")
	testing.expect(t, progress_line("progress=continue"), "valor não-numérico também")
	// o ffmpeg emite esta em TODO bloco de progresso, uma por stream de saída. Rejeitá-la
	// (a chave tem DÍGITO) fazia ela ser guardada como se fosse o erro, sobrescrevendo a
	// causa real e deixando export_err_n > 0 sempre ligado.
	testing.expect(t, progress_line("stream_0_0_q=29.0"), "chave com dígito ainda é progresso")
	testing.expect(t, !progress_line("[libx264 @ 000001] height not divisible by 2"), "erro do ffmpeg NÃO é progresso")
	testing.expect(t, !progress_line("Conversion failed!"), "erro em texto corrido também não")
	testing.expect(t, !progress_line("saida.mp4: Invalid argument"), "nem erro com caminho antes")
	testing.expect(t, !progress_line(""), "linha vazia não é progresso")
	testing.expect(t, !progress_line("=x"), "sem chave antes do = não é progresso")
}

@(test)
export_err_noise_ignora_rodape_do_muxer :: proc(t: ^testing.T) {
	testing.expect(t, export_err_noise("[out#0/mp4 @ 1] Terminating thread with return code -22 (Invalid argument)"),
		"é o rodapé que escondia a causa")
	testing.expect(t, export_err_noise("[out#0/mp4 @ 1] Task finished with error code: -22 (Invalid argument)"),
		"task finished também é rodapé")
	testing.expect(t, !export_err_noise("[mp4 @ 1] Application provided invalid, non monotonically increasing dts to muxer in stream 1"),
		"a linha do DTS é a causa — tem que ir pro toast")
}

@(test)
export_amix_corrige_timestamp :: proc(t: ^testing.T) {
	t_export_reset()
	add_seg(0, 0, 0, 10)
	add_seg(1, 10, 0, 8)
	args, g := t_build(t)
	testing.expect(t, strings.contains(g, "amix=inputs=2"), "os dois entram no mix")
	testing.expect(t, strings.contains(g, "aresample=async=1:first_pts=0[aout]"),
		"sem aresample o AAC estoura DTS no corte e o MP4 morre com -22")
	testing.expect(t, t_has(args, "-avoid_negative_ts"), "MP4 precisa de make_zero p/ DTS no limite")
}

// O export monta [N:a] a partir da FONTE ORIGINAL, então nunca dependeu da extração de áudio
// do player — mas consultava c.has_audio, que é "existe um rl.Music carregado agora". Esse
// campo é false durante toda a extração (que no caminho de cache só começa depois de o clipe
// já aparecer PRONTO no bin, e pode levar dezenas de segundos) e para sempre se ela falhar.
// Exportar nesse intervalo entregava um arquivo válido e MUDO, sem erro nem toast — e a
// guarda de recusa não pega, porque segs_importing() olha `probed`, que já é true.
@(test)
export_monta_audio_mesmo_com_a_extracao_pendente :: proc(t: ^testing.T) {
	t_export_reset()
	add_seg(0, 0, 0, 10)
	clips[0].has_audio = false // player ainda sem rl.Music: a extração não terminou
	_, g := t_build(t)
	testing.expect(t, strings.contains(g, "[0:a]"), "a cadeia de áudio da fonte entra no grafo")
	testing.expect(t, strings.contains(g, "[aout]"), "e o amix produz a saída de áudio")
}

// e o contrário continua valendo: fonte SEM faixa de áudio não vira cadeia nenhuma
@(test)
export_nao_inventa_audio_para_fonte_muda :: proc(t: ^testing.T) {
	t_export_reset()
	add_seg(0, 0, 0, 10)
	clips[0].src_audio = false // arquivo sem stream de áudio (o probe respondeu isso)
	clips[0].has_audio = true  // e o estado do player não pode mandar aqui
	_, g := t_build(t)
	testing.expect(t, !strings.contains(g, "[0:a]"), "sem faixa de áudio na fonte, sem cadeia")
	testing.expect(t, !strings.contains(g, "[aout]"), "e sem saída de áudio")
}

// O zoompan roda sobre o STREAM, que numa transição começa `hd` s ANTES do clipe (pré-roll
// do dissolver) e termina `tl` s depois — e ainda pode levar tpad quando a fonte não tem
// folga. Com a curva sendo `on/N` sobre esse stream, a animação saía adiantada em hd e
// esticada por (dur+hd+tl)/dur, e o smoothstep passava de 1 (deixando de ser monótono: o
// zoom VOLTAVA no fim). A curva tem que ser a mesma do seg_crop_at: clamp((t-start)/dur,0,1).
@(test)
zoompan_anima_sobre_o_clipe_nao_sobre_o_stream :: proc(t: ^testing.T) {
	t_export_reset()
	_ = add_seg(0, 0, 0, 4)   // A
	b := add_seg(1, 4, 0, 3)  // B, encostado em A
	segs[b].trans = 1         // dissolver de 1s no corte A|B -> hd = 0.5 em B
	segs[b].zoom_anim = true
	segs[b].crop_x = 0.1; segs[b].crop_y = 0.1; segs[b].crop_w = 0.5; segs[b].crop_h = 0.5
	segs[b].crop2_x = 0.3; segs[b].crop2_y = 0.3; segs[b].crop2_w = 0.3; segs[b].crop2_h = 0.3
	testing.expect(t, t_feq(seg_trans(b), 1), "o dissolver de 1s vale (senão o teste não exercita o pré-roll)")
	_, g := t_build(t)
	// o deslocamento tem que ser o hd REAL (metade do dissolver) e o divisor, dur
	testing.expect(t, strings.contains(g, "clip((on/30-0.5000)/3.0000"),
		"a curva desconta o pré-roll do dissolver e corre sobre dur")
	testing.expect(t, !strings.contains(g, "(on/"+"105"), "não usa a contagem de frames do stream")
	// sem transição o deslocamento é zero e o divisor continua sendo dur
	t_export_reset()
	c := add_seg(0, 0, 0, 4)
	segs[c].zoom_anim = true
	segs[c].crop_x = 0.1; segs[c].crop_y = 0.1; segs[c].crop_w = 0.5; segs[c].crop_h = 0.5
	segs[c].crop2_x = 0.3; segs[c].crop2_y = 0.3; segs[c].crop2_w = 0.3; segs[c].crop2_h = 0.3
	_, g2 := t_build(t)
	testing.expect(t, strings.contains(g2, "clip((on/30-0.0000)/4.0000"), "sem transição: sem deslocamento, divisor = dur")
	t_assert_zoompan_suave(t, g)
	t_assert_zoompan_suave(t, g2)
}

// ---------- Pan & Zoom: TREMO no arquivo (não só a curva da animação) ----------
// O que deixava o "ampliar" tremido: zoompan vira x/y em int e amostra nearest.
// A prévia é bilinear na GPU. Este ffmpeg não tem interp=linear. A guarda é:
//   1. SUPER >= 4 nas imagens; vídeo >= 2  (1× = 1 px de salto por frame)
//   2. OUT >= 2: zoompan num box maior + lanczos descendo (filtra o nearest)
//   3. gbrp + lanczos imediatamente antes do zoompan (não bilinear, não yuv420)
//   4. x/y com trunc( — round-to-nearest oscilava e virava ziguezague
//   5. nenhum zoompan:interp=  (este ffmpeg rejeita / ignora)

@(test)
zoompan_fatores_nao_descem :: proc(t: ^testing.T) {
	testing.expectf(t, ZOOM_PAN_SUPER >= 4,
		"ZOOM_PAN_SUPER=%d: imagem com ampliar precisa de 4× na fonte", ZOOM_PAN_SUPER)
	testing.expectf(t, ZOOM_PAN_OUT >= 2,
		"ZOOM_PAN_OUT=%d: sem downsample o zoompan entrega nearest no frame final", ZOOM_PAN_OUT)
	testing.expect(t, zoompan_in_mul(true, 784, 1168) >= 4, "JPEG retrato (capitalismo) em 4×")
	testing.expect(t, zoompan_in_mul(true, 1920, 1080) >= 4, "JPEG 1080p em 4×")
	testing.expect(t, zoompan_in_mul(false, 1920, 1080) >= 2, "vídeo 1080p em pelo menos 2×")
	testing.expect(t, zoompan_in_mul(true, 4000, 6000) == 2, "foto enorme: teto 8K, não 16K")
	ow, oh := zoompan_out_wh(1920, 1080)
	testing.expect(t, ow >= 3840 && oh >= 2160, "box do zoompan é 2× o segmento")
}

@(test)
zoompan_presample_e_gbrp_lanczos :: proc(t: ^testing.T) {
	s := zoompan_presample(4)
	testing.expect(t, strings.contains(s, "format=gbrp,"), "gbrp: yuv420 crawlava chroma no pan")
	testing.expect(t, strings.contains(s, "flags=lanczos,zoompan="), "lanczos no upsample; bilinear ainda saltava")
	testing.expect(t, strings.contains(s, "scale=iw*4:ih*4"), "scale usa o fator, não um 2 hardcoded solto")
	testing.expect(t, !strings.contains(s, "bilinear"), "bilinear no supersample não mata o tremor")
}

@(test)
zoompan_emite_supersample_e_trunc :: proc(t: ^testing.T) {
	t_export_reset()
	c := add_seg(0, 0, 0, 8)
	segs[c].zoom_anim = true
	segs[c].crop_x = 0.05; segs[c].crop_y = 0.05; segs[c].crop_w = 0.9; segs[c].crop_h = 0.9
	segs[c].crop2_x = 0.20; segs[c].crop2_y = 0.20; segs[c].crop2_w = 0.5; segs[c].crop2_h = 0.5
	_, g := t_build(t)
	t_assert_zoompan_suave(t, g)
}

// O capitalismo era retrato (784×1168) com Ken Burns em JPEG. O pad de aspecto
// entra no meio da cadeia; o supersample ainda tem de colar no zoompan.
@(test)
zoompan_em_retrato_ainda_supersample :: proc(t: ^testing.T) {
	t_export_reset()
	proj_w = 784; proj_h = 1168
	clips[0].is_img = true
	clips[0].vw = 784; clips[0].vh = 1168
	c := add_seg(0, 0, 0, 27)
	segs[c].zoom_anim = true
	segs[c].crop_x = 0.0; segs[c].crop_y = 0.0; segs[c].crop_w = 1; segs[c].crop_h = 1
	segs[c].crop2_x = 0.15; segs[c].crop2_y = 0.10; segs[c].crop2_w = 0.7; segs[c].crop2_h = 0.7
	_, g := t_build(t)
	testing.expect(t, strings.contains(g, "zoompan="), "imagem com ampliar usa zoompan")
	testing.expect(t, strings.contains(g, "scale=iw*4:ih*4:flags=lanczos,zoompan="),
		"JPEG retrato upsample 4× (2× ainda tremia no pan lento)")
	t_assert_zoompan_suave(t, g)
}

t_assert_zoompan_suave :: proc(t: ^testing.T, g: string) {
	nz := strings.count(g, "zoompan=")
	testing.expect(t, nz > 0, "grafo sem zoompan — o teste não exercita o ampliar")
	npre := strings.count(g, "format=gbrp,scale=iw*4:ih*4:flags=lanczos,zoompan=") +
		strings.count(g, "format=gbrp,scale=iw*2:ih*2:flags=lanczos,zoompan=")
	testing.expectf(t, npre == nz,
		"%d zoompan= mas só %d com upsample gbrp+lanczos — algum ficou sem supersample", nz, npre)
	testing.expect(t, strings.count(g, "x='trunc(") == nz, "x sem trunc: round-to-nearest = ziguezague")
	testing.expect(t, strings.count(g, "y='trunc(") == nz, "y sem trunc: idem")
	testing.expect(t, !strings.contains(g, "interp="),
		"zoompan:interp= não existe neste ffmpeg — export morre ou ignora")
	testing.expect(t, !strings.contains(g, "flags=bilinear,zoompan="),
		"bilinear antes do zoompan não mata o salto de 1 px")
	testing.expect(t, !strings.contains(g, "flags=fast_bilinear,zoompan="),
		"fast_bilinear antes do zoompan idem")
	testing.expect(t, !strings.contains(g, "x='(("), "x sem trunc (expressão crua)")
	testing.expect(t, !strings.contains(g, "y='(("), "y sem trunc (expressão crua)")
	// o downsample DEPOIS do zoompan é o que filtra o nearest: s=2×box, scale p/ o box
	testing.expectf(t, strings.count(g, ":fps=30,scale=") == nz,
		"%d zoompan sem scale= na cola — está entregando nearest no tamanho final", nz)
	t_assert_zoompan_desce_2x(t, g, nz)
}

// cada `d=1:s=SW x SH:fps=30,scale=DW:DH` tem SW,SH >= ~2× o destino
t_assert_zoompan_desce_2x :: proc(t: ^testing.T, g: string, nz: int) {
	n := 0
	from := 0
	for {
		i := strings.index(g[from:], ":d=1:s=")
		if i < 0 do break
		rest := g[from+i+7:]
		sw, n1, ok1 := t_num_head(rest)
		if !ok1 || n1 >= len(rest) || rest[n1] != 'x' {
			from += i + 7
			continue
		}
		sh, n2, ok2 := t_num_head(rest[n1+1:])
		if !ok2 {
			from += i + 7
			continue
		}
		after := rest[n1+1+n2:]
		if !strings.has_prefix(after, ":fps=30,scale=") {
			from += i + 7
			continue
		}
		rest2 := after[len(":fps=30,scale="):]
		dw, m1, ok3 := t_num_head(rest2)
		if !ok3 || m1 >= len(rest2) || rest2[m1] != ':' {
			testing.expect(t, false, "scale depois do zoompan sem W:H")
			return
		}
		dh, _, ok4 := t_num_head(rest2[m1+1:])
		testing.expect(t, ok4, "scale depois do zoompan sem H")
		testing.expectf(t, int(sw) >= int(dw)*2-2 && int(sh) >= int(dh)*2-2,
			"zoompan s=%dx%d não é 2× o destino %dx%d — downsample sumiu", int(sw), int(sh), int(dw), int(dh))
		testing.expect(t, strings.contains(after, "flags=lanczos"),
			"downsample do zoompan sem lanczos")
		n += 1
		from += i + 7
	}
	testing.expectf(t, n == nz, "achei %d downsamples p/ %d zoompan", n, nz)
}

// Dissolver e fade preto são rampas INDEPENDENTES e com origens diferentes: o dissolver é
// centrado no corte (começa em start - d/2) e o fade preto começa na borda do clipe. A prévia
// aplica os dois e multiplica; o export escolhia `max(tfin, vfin)` e emitia UMA rampa só, e
// aí os dois caminhos divergiam (no instante do corte a prévia mostrava preto e o arquivo,
// 50%). Dois fade:alpha=1 encadeados multiplicam os fatores, então emitir os dois casa.
@(test)
export_emite_dissolver_E_fade_preto_encadeados :: proc(t: ^testing.T) {
	t_export_reset()
	_ = add_seg(0, 0, 0, 4)  // A
	b := add_seg(1, 4, 0, 3) // B, encostado em A
	segs[b].trans = 1        // dissolver de 1s no corte -> rampa em start-0.5, dur 1
	segs[b].vfin  = 1        // fade preto de 1s        -> rampa em start,     dur 1
	testing.expect(t, t_feq(seg_trans(b), 1), "o dissolver de 1s vale (senão o teste não exercita nada)")
	_, g := t_build(t)
	testing.expect(t, strings.contains(g, "fade=t=in:st=3.500:d=1.000:alpha=1"), "rampa do DISSOLVER, centrada no corte")
	testing.expect(t, strings.contains(g, "fade=t=in:st=4.000:d=1.000:alpha=1"), "rampa do FADE PRETO, na borda do clipe")
}

// `fade=t=in:st=S` zera TUDO que vem antes de S. Com dissolver + fade preto de entrada no
// mesmo clipe, a rampa do fade preto (st = start do clipe) apagava o lead-in do dissolver —
// o clipe que entra ficava 100% invisível na primeira metade do dissolver no arquivo, enquanto
// a prévia o mostrava surgindo até 50% (ela isenta o lead-in: `if vt >= sg.start`). O `enable`
// põe o filtro em passagem antes de S, que é exatamente a isenção da prévia.
@(test)
fade_preto_de_entrada_nao_apaga_o_lead_in_do_dissolver :: proc(t: ^testing.T) {
	t_export_reset()
	_ = add_seg(0, 0, 0, 4)  // A
	b := add_seg(1, 4, 0, 3) // B, encostado em A
	segs[b].trans = 1        // dissolver de 1s -> rampa em 3.5, o lead-in é [3.5, 4)
	segs[b].vfin  = 1        // fade preto de 1s -> rampa em 4.0
	_, g := t_build(t)
	testing.expect(t, strings.contains(g, "fade=t=in:st=4.000:d=1.000:alpha=1:enable='gte(t\\,4.000)'"),
		"a rampa do fade preto fica em passagem durante o lead-in")
	testing.expect(t, strings.contains(g, "fade=t=in:st=3.500:d=1.000:alpha=1,"),
		"e a do dissolver continua sem enable (não há nada antes dela)")
}

// sem dissolver não existe lead-in, e aí o enable seria ruído no grafo.
@(test)
fade_preto_sozinho_nao_ganha_enable :: proc(t: ^testing.T) {
	t_export_reset()
	b := add_seg(0, 0, 0, 5)
	segs[b].vfin = 1
	_, g := t_build(t)
	testing.expect(t, strings.contains(g, "fade=t=in:st=0.000:d=1.000:alpha=1"), "a rampa sai")
	// (o `enable` do overlay sai em todo seg — aqui só interessa o do fade)
	testing.expect(t, !strings.contains(g, "alpha=1:enable="), "mas sem enable")
}

// Dissolve orgânico: wipe de tinta (máscara luma). A e B em geq, sem fade limpo.
@(test)
export_aparicao_nao_some_o_clipe_de_saida :: proc(t: ^testing.T) {
	t_export_reset()
	_ = add_seg(0, 0, 0, 4)  // A
	b := add_seg(1, 4, 0, 3) // B
	segs[b].trans = 1
	segs[b].trans_mode = 1
	testing.expect(t, seg_ghost(b), "dissolve orgânico válido")
	_, g := t_build(t)
	testing.expect(t, strings.contains(g, "geq="), "máscara no grafo")
	testing.expect(t, strings.count(g, "geq=") >= 2, "A e B têm a máscara de tinta")
	testing.expect(t, strings.contains(g, "sin(X"), "luma orgânica no plano")
	testing.expect(t, strings.contains(g, "1.20"), "limiar da tinta com folga")
	testing.expect(t, strings.contains(g, "(1-("), "A some nas manchas (máscara invertida)")
	testing.expect(t, !strings.contains(g, "hypot"), "não é íris/raio")
	testing.expect(t, !strings.contains(g, "fade=t=out"), "opacidade vai no geq, não no fade")
	testing.expect(t, !strings.contains(g, "fade=t=in:st=3.500"), "sem fade-in cheio de dissolver")
	// geq a full-res no corte ainda travava (2ª transição do capitalismo). Máscara a 1/8
	// + trim só na janela: o RGB fica nítido, o geq vê ~64× menos pixels e só 1s de frames.
	testing.expect(t, strings.contains(g, "trim=3.500:4.500"), "o ramo da máscara só cobre o corte")
	testing.expect(t, strings.contains(g, "alphamerge"), "máscara baixa-res aplicada no RGB cheio")
	testing.expect(t, strings.contains(g, "format=gray,geq=lum="), "geq só no luma da miniatura")
	t_assert_geq_barato(t, g, 1920, 1080)
}

// ---------- dissolve orgânico: CUSTO do geq (não só o visual) ----------
// O que travou o capitalismo: geq interpreta a expressão POR PIXEL. Full-res 1080p
// ≈ 2M evals/frame; no clipe inteiro, dezenas de segundos de CPU por transição.
// `enable=between` NÃO basta neste ffmpeg — o filtro ainda avalia. A guarda é:
//   1. DIV >= 8  (1/8 da área = 64× menos pixels; DIV=2 ainda engasgava)
//   2. geq só em luma da miniatura, nunca r=/g=/b= no RGB cheio
//   3. trim no ramo da máscara = só a janela do corte, não o clipe
//   4. alphamerge aplica a miniatura no RGB nítido

@(test)
ghost_mask_div_nao_desce_de_8 :: proc(t: ^testing.T) {
	testing.expectf(t, GHOST_MASK_DIV >= 8,
		"GHOST_MASK_DIV=%d: abaixo de 8 o geq volta a travar o export (capitalismo, 2ª transição)",
		GHOST_MASK_DIV)
}

@(test)
ghost_mask_dims_reduz_cerca_de_64x :: proc(t: ^testing.T) {
	casos := [][2]int{{1920, 1080}, {784, 1168}, {1152, 1712}, {64, 64}, {2, 2}}
	for c in casos {
		mw, mh, ow, oh := ghost_mask_dims(c[0], c[1])
		full := max(c[0], 2) * max(c[1], 2)
		mini := mw * mh
		// piso: pelo menos 16× menos pixels (DIV=8 dá 64×; arredondamento em 2×2 sobra)
		if full >= 64*64 {
			testing.expectf(t, mini * 16 <= full,
				"%dx%d -> miniatura %dx%d (%d px) ainda é gorda demais vs %d",
				c[0], c[1], mw, mh, mini, full)
		}
		testing.expectf(t, ow >= 2 && oh >= 2 && mw >= 2 && mh >= 2,
			"%dx%d: dimensão ímpar/zero na máscara (%d×%d -> %d×%d)", c[0], c[1], mw, mh, ow, oh)
		testing.expectf(t, mw%2 == 0 && mh%2 == 0 && ow%2 == 0 && oh%2 == 0,
			"%dx%d: scale ímpar (%d×%d / %d×%d) — ffmpeg recusa em yuv420", c[0], c[1], mw, mh, ow, oh)
	}
}

// chamada direta: o texto emitido é o contrato. Se alguém "otimizar" de volta p/
// geq RGB + enable=between, este teste quebra sem precisar montar a timeline.
@(test)
ghost_mask_emite_miniatura_trim_e_luma :: proc(t: ^testing.T) {
	fb := strings.builder_make(context.temp_allocator)
	export_ghost_mask(&fb, 31.35, 1.2, false, true, 7, 784, 1168)
	s := strings.to_string(fb)
	mw, mh, ow, oh := ghost_mask_dims(784, 1168)
	want_down := fmt.tprintf("scale=%d:%d:flags=fast_bilinear,format=gray,geq=lum=", mw, mh)
	want_up   := fmt.tprintf("scale=%d:%d:flags=bilinear,format=gray", ow, oh)
	testing.expect(t, strings.contains(s, "trim=31.350:32.550"), "trim = só os 1.2s do corte, não o clipe")
	testing.expect(t, strings.contains(s, want_down), "geq vê a miniatura, não o frame cheio")
	testing.expect(t, strings.contains(s, want_up), "sobe de volta p/ casar com o RGB")
	testing.expect(t, strings.contains(s, "alphamerge"), "máscara aplicada no RGB nítido")
	testing.expect(t, !strings.contains(s, "geq=r="), "geq em RGB = 3 planos × full-res")
	testing.expect(t, !strings.contains(s, "enable="), "enable no geq NÃO pula trabalho neste ffmpeg")
	testing.expect(t, strings.contains(s, "(1-("), "invert=true: o clipe que SAI some nas manchas")
}

@(test)
ghost_mask_persist_ainda_e_miniatura :: proc(t: ^testing.T) {
	fb := strings.builder_make(context.temp_allocator)
	export_ghost_mask(&fb, 0, 1, true, false, 0, 1920, 1080)
	s := strings.to_string(fb)
	mw, mh, _, _ := ghost_mask_dims(1920, 1080)
	want := fmt.tprintf("scale=%d:%d:flags=fast_bilinear,format=gray,geq=lum=", mw, mh)
	testing.expect(t, strings.contains(s, want), "overlay persistente também geq a 1/8 — senão um overlay de 10s trava igual")
	testing.expect(t, !strings.contains(s, "trim="), "persist = máscara o clipe todo (sem janela)")
	testing.expect(t, strings.contains(s, "alphamerge"), "mesmo caminho barato")
}

// O cenário que travou de verdade: clipes longos (16s+7s) e dissolve de 1.2s.
// Sem o trim, o geq rodava nos ~16s do A e nos ~7s do B. Sem a miniatura, 1.2s
// a full-res ainda engasgava. Os dois têm de continuar no grafo montado.
@(test)
dissolve_organico_em_clipe_longo_nao_geq_full :: proc(t: ^testing.T) {
	t_export_reset()
	_ = add_seg(0, 0, 0, 16)
	b := add_seg(1, 16, 0, 7)
	segs[b].trans = 1.2
	segs[b].trans_mode = 1
	testing.expect(t, t_feq(seg_trans(b), 1.2), "dissolve de 1.2s (senão o teste não pega o corte)")
	_, g := t_build(t)
	testing.expect(t, strings.contains(g, "trim=15.400:16.600"),
		"máscara recortada na janela do corte (15.4..16.6), não nos 16s do clipe")
	t_assert_geq_barato(t, g, 1920, 1080)
	// nenhum ramo de máscara pode durar o clipe: trim A:B,scale=mini tem B-A ≈ 1.2
	n, ok_all := t_mask_trims_curtos(g, 1.2)
	testing.expect(t, n >= 2, "A (sai) e B (entra) precisam do ramo de máscara")
	testing.expect(t, ok_all, "algum trim da máscara cobriu o clipe inteiro em vez do corte")
}

// cada `geq=` do grafo: luma de miniatura, nunca RGB, nunca full-res, nunca sem alphamerge.
t_assert_geq_barato :: proc(t: ^testing.T, g: string, fw, fh: int) {
	testing.expect(t, !strings.contains(g, "geq=r="), "geq=r= avalia RGB cheio — o que travou o export")
	testing.expect(t, !strings.contains(g, "geq=g="), "geq=g= idem")
	testing.expect(t, !strings.contains(g, "geq=b="), "geq=b= idem")
	nge := strings.count(g, "geq=")
	nlum := strings.count(g, "format=gray,geq=lum=")
	testing.expectf(t, nge == nlum && nge > 0,
		"%d geq= mas só %d em luma cinza — o resto é o caminho lento", nge, nlum)
	testing.expect(t, strings.count(g, "alphamerge") == nge,
		"cada geq precisa de alphamerge no RGB cheio")
	// scale=W:H imediatamente antes do geq de luma
	needle := "scale="
	from := 0
	for {
		i := strings.index(g[from:], "format=gray,geq=lum=")
		if i < 0 do break
		at := from + i
		// recua até o scale= mais próximo à esquerda
		chunk := g[:at]
		ls := strings.last_index(chunk, needle)
		testing.expect(t, ls >= 0, "geq=lum sem scale= antes")
		if ls < 0 do break
		rest := g[ls+len(needle):]
		w, n1, ok1 := t_num_head(rest)
		if !ok1 || n1 >= len(rest) || rest[n1] != ':' {
			testing.expect(t, false, "não li W do scale antes do geq")
			break
		}
		h, _, ok2 := t_num_head(rest[n1+1:])
		testing.expect(t, ok2, "não li H do scale antes do geq")
		area := int(w) * int(h)
		full := fw * fh
		testing.expectf(t, area * 16 <= full,
			"geq a %dx%d (%d px) ainda é gordo vs canvas %dx%d — DIV caiu?",
			int(w), int(h), area, fw, fh)
		from = at + 1
	}
}

// trims do ramo da máscara: `trim=A:B,scale=` (o trim de vídeo é `]trim=` sem scale na cola).
t_mask_trims_curtos :: proc(g: string, want_d: f32) -> (n: int, all_short: bool) {
	all_short = true
	from := 0
	for {
		i := strings.index(g[from:], "trim=")
		if i < 0 do break
		at := from + i
		rest := g[at+5:]
		a, n1, ok1 := t_num_head(rest)
		if !ok1 || n1 >= len(rest) || rest[n1] != ':' {
			from = at + 5
			continue
		}
		b, n2, ok2 := t_num_head(rest[n1+1:])
		if !ok2 {
			from = at + 5
			continue
		}
		after := rest[n1+1+n2:]
		if !strings.has_prefix(after, ",scale=") {
			from = at + 5
			continue
		}
		n += 1
		d := b - a
		if d < want_d-0.05 || d > want_d+0.05 do all_short = false
		from = at + 5
	}
	return
}

// Clipe opaco, sem giro/fade/dissolver: yuv420p no overlay (rgba 4 bytes/pixel era o
// default e deixava o recorte simples ~1.5–2× mais lento). Transparência continua rgba.
@(test)
export_clipe_simples_nao_usa_rgba :: proc(t: ^testing.T) {
	t_export_reset()
	add_seg(0, 0, 0, 10)
	_, g := t_build(t)
	testing.expect(t, strings.contains(g, "format=yuv420p[v0]"), "recorte simples: overlay em yuv420p")
	testing.expect(t, !strings.contains(g, "format=rgba[v0]"), "rgba no clipe opaco é custo à toa")
}

@(test)
export_opacidade_continua_em_rgba :: proc(t: ^testing.T) {
	t_export_reset()
	si := add_seg(0, 0, 0, 10)
	segs[si].opacity = 0.5
	_, g := t_build(t)
	testing.expect(t, strings.contains(g, "format=rgba"), "opacidade < 1 precisa de alpha no overlay")
}

// Presets de VELOCIDADE (não confundir com CRF): Baixa tem de sair mais rápida que Média,
// senão o botão só muda o tamanho do arquivo e o usuário acha que "não tem como acelerar".
@(test)
export_baixa_usa_preset_rapido_na_cpu :: proc(t: ^testing.T) {
	t_export_reset()
	add_seg(0, 0, 0, 10)
	export_qual = .Low
	args, _ := t_build(t)
	p, ok := t_arg_after(args, "-preset")
	testing.expect(t, ok && p == "ultrafast", "Baixa em CPU: ultrafast")
	export_qual = .Medium
	args, _ = t_build(t)
	p, ok = t_arg_after(args, "-preset")
	testing.expect(t, ok && p == "veryfast", "Média em CPU: veryfast")
}

@(test)
export_gpu_media_nao_fica_em_p5 :: proc(t: ^testing.T) {
	t_export_reset()
	add_seg(0, 0, 0, 10)
	args, _, ok := export_build_args("saida.mp4", true, true)
	testing.expect(t, ok, "montagem GPU recusada")
	p, has := t_arg_after(args, "-preset")
	testing.expect(t, has && p == "p4", "Média em NVENC: p4 (p5 era o lento de antes)")
	export_qual = .Low
	args, _, ok = export_build_args("saida.mp4", true, true)
	testing.expect(t, ok, "montagem GPU Baixa recusada")
	p, has = t_arg_after(args, "-preset")
	testing.expect(t, has && p == "p1", "Baixa em NVENC: p1")
}

@(test)
export_webm_usa_cpu_used :: proc(t: ^testing.T) {
	t_export_reset()
	export_fmt = .WEBM
	add_seg(0, 0, 0, 10)
	args, _ := t_build(t)
	v, ok := t_arg_after(args, "-cpu-used")
	testing.expect(t, ok && v == "4", "WEBM Média sem -cpu-used (default 1) é o export mais lento")
	export_fmt = .MP4
}
