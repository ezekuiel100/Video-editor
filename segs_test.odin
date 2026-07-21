package main

// Testes unitários da lógica de SEGMENTOS da timeline (corte, ripple, paredes,
// cadeia contígua, ganho de áudio, mapa timeline→fonte). Rodar com:
//
//   odin test . -out:tests.exe -define:ODIN_TEST_THREADS=1 -define:INVARIANTS=true
//
// THREADS=1 é obrigatório: os testes compartilham os globais (segs/clips/st).
// INVARIANTS=true liga o check_invariants() (sem o define a chamada é no-op).
// As fontes são FALSAS (probed=true, sem cache/áudio/textura): clip_frame vira
// no-op (cached=0) e nenhum caminho de raylib-áudio/GL/ffmpeg é tocado — dá pra
// exercitar remove_seg/seek_global inteiros sem janela.

import "core:testing"

t_feq :: proc(a, b: f32) -> bool { return abs(a - b) < 0.001 }

// zera o estado global da timeline e cria 2 fontes falsas prontas (100s cada)
t_reset :: proc() {
	nsegs = 0
	for i in 0 ..< MAX_SEGS { segs[i] = Seg{}; seg_marked[i] = false }
	nfx = 0
	for i in 0 ..< MAX_CLIPS do clips[i] = Clip{}
	nclips = 2
	clips[0].probed = true; clips[0].dur = 100
	clips[1].probed = true; clips[1].dur = 100
	g_nv = 3; g_na = 2
	for i in 0 ..< MAXTRACKS { track_muted[i] = false; track_locked[i] = false; track_h[i] = 0 }
	// geometria vertical determinística (o draw_timeline é quem seta isso em runtime)
	g_lanes_top = 0; g_track_h = 72; g_track_gap = 3
	st = State{}
	selected = -1; play_clip = -1; drag_clip = -1; sel_trans = -1; bin_sel = -1
	src_preview = -1
	aud_prev = -1
	snap_line = -1
	seg_clipbrd_n = 0
	toast_msg = nil // abandona o toast do teste ANTERIOR: liberar aqui seria "bad free"
	                // (o rastreador de memória é por-teste). O toast do próprio teste
	                // aparece como "leak" de ~30B no log — inofensivo; p/ silenciar,
	                // rode com -define:ODIN_TEST_TRACK_MEMORY=false
}

@(test)
add_seg_defaults :: proc(t: ^testing.T) {
	t_reset()
	si := add_seg(0, -5, 2, 10)
	testing.expect(t, si == 0, "primeiro segmento ocupa o índice 0")
	testing.expect(t, nsegs == 1, "nsegs vira 1")
	testing.expect(t, segs[si].start == 0, "start negativo é clampado a 0")
	testing.expect(t, segs[si].vol == 1 && segs[si].scale == 1 && segs[si].opacity == 1 && segs[si].speed == 1,
		"vol/scale/opacity/speed nascem 1 (zero-value seria mudo/invisível)")
}

@(test)
gain_vol_mudo_e_fades :: proc(t: ^testing.T) {
	t_reset()
	si := add_seg(0, 10, 0, 10) // timeline [10,20)
	segs[si].vol = 0.5
	testing.expect(t, t_feq(seg_gain(si, 15), 0.5), "sem fade: ganho = vol")
	segs[si].muted = true
	testing.expect(t, seg_gain(si, 15) == 0, "mudo zera o ganho")
	segs[si].muted = false
	track_muted[0] = true
	testing.expect(t, seg_gain(si, 15) == 0, "trilha muda zera o ganho")
	track_muted[0] = false
	segs[si].vol = 1
	segs[si].fade_in = 2
	testing.expect(t, t_feq(seg_gain(si, 10), 0), "início do fade-in = 0")
	testing.expect(t, t_feq(seg_gain(si, 11), 0.5), "meio do fade-in = 50%")
	testing.expect(t, t_feq(seg_gain(si, 13), 1), "depois do fade-in = 100%")
	segs[si].fade_out = 4 // últimos 4s: em t=18 restam 2s → 50%
	testing.expect(t, t_feq(seg_gain(si, 18), 0.5), "meio do fade-out = 50%")
}

@(test)
overlaps_e_paredes :: proc(t: ^testing.T) {
	t_reset()
	add_seg(0, 10, 0, 10) // [10,20) trilha 0
	add_seg(0, 30, 0, 5)  // [30,35) trilha 0
	testing.expect(t, overlaps_any(0, -1, 15, 3), "dentro de [10,20) invade")
	testing.expect(t, !overlaps_any(0, -1, 20, 5), "encostar no fim não invade")
	testing.expect(t, !overlaps_any(0, -1, 5, 5), "encostar no início não invade")
	testing.expect(t, !overlaps_any(1, -1, 15, 3), "outra trilha não conflita")
	testing.expect(t, !overlaps_any(0, 0, 12, 5), "o próprio segmento (moving) é ignorado")
	testing.expect(t, t_feq(left_wall(0, -1, 25), 20), "parede esquerda = fim do vizinho")
	testing.expect(t, t_feq(right_wall(0, -1, 25), 30), "parede direita = início do vizinho")
	testing.expect(t, left_wall(0, -1, 5) == 0, "sem vizinho à esquerda = 0")
	testing.expect(t, right_wall(0, -1, 40) >= 1e29, "sem vizinho à direita = +inf")
}

@(test)
free_start_empurra :: proc(t: ^testing.T) {
	t_reset()
	add_seg(0, 10, 0, 10) // [10,20)
	add_seg(0, 30, 0, 5)  // [30,35)
	testing.expect(t, t_feq(free_start(0, -1, 12, 8), 20), "empurra p/ depois do ocupado")
	testing.expect(t, t_feq(free_start(0, -1, 12, 15), 35), "invade os dois: pula a cadeia inteira")
	testing.expect(t, t_feq(free_start(0, -1, 21, 5), 21), "vão livre fica onde propôs")
	testing.expect(t, free_start(0, -1, -3, 5) == 0, "proposta negativa clampada a 0")
}

@(test)
split_basico :: proc(t: ^testing.T) {
	t_reset()
	a := add_seg(0, 10, 5, 10) // timeline [10,20), fonte [5,15)
	segs[a].vol = 0.7
	segs[a].fade_in = 1; segs[a].fade_out = 2
	testing.expect(t, split_seg_at(a, 14), "corte válido retorna true")
	testing.expect(t, nsegs == 2, "corte cria um segundo segmento")
	r := 1
	testing.expect(t, t_feq(segs[a].dur, 4), "esquerda encurta até o corte")
	testing.expect(t, t_feq(segs[r].start, 14), "direita começa no corte")
	testing.expect(t, t_feq(segs[a].dur + segs[r].dur, 10), "as metades somam a duração original")
	testing.expect(t, t_feq(segs[r].in_off, 9), "in_off da direita = in_off + off")
	testing.expect(t, t_feq(segs[r].vol, 0.7), "volume herdado pela direita")
	testing.expect(t, t_feq(segs[a].fade_in, 1) && t_feq(segs[a].fade_out, 0),
		"fade-in fica na esquerda; a borda do corte não ganha fade")
	testing.expect(t, t_feq(segs[r].fade_in, 0) && t_feq(segs[r].fade_out, 2), "fade-out vai p/ a direita")
}

@(test)
split_com_speed :: proc(t: ^testing.T) {
	t_reset()
	a := add_seg(0, 0, 10, 10)
	segs[a].speed = 2 // 10s de timeline consomem 20s de fonte
	testing.expect(t, split_seg_at(a, 4), "corte válido")
	testing.expect(t, t_feq(segs[1].in_off, 18), "fonte consumida pela esquerda = off*speed (10+4*2)")
	testing.expect(t, t_feq(segs[1].speed, 2), "velocidade herdada")
}

@(test)
split_perto_da_borda :: proc(t: ^testing.T) {
	t_reset()
	a := add_seg(0, 0, 0, 10)
	testing.expect(t, !split_seg_at(a, 0.01), "corte colado no início é rejeitado")
	testing.expect(t, !split_seg_at(a, 9.99), "corte colado no fim é rejeitado")
	testing.expect(t, nsegs == 1, "nenhum segmento novo criado")
}

@(test)
split_zoom_animado_continuo :: proc(t: ^testing.T) {
	t_reset()
	a := add_seg(0, 0, 0, 10)
	segs[a].zoom_anim = true
	segs[a].crop_w = 1; segs[a].crop_h = 1
	segs[a].crop2_x = 0.4; segs[a].crop2_y = 0.4; segs[a].crop2_w = 0.5; segs[a].crop2_h = 0.5
	cx, cy, cw, ch := seg_crop_at(a, 6) // região exatamente no ponto do corte
	testing.expect(t, split_seg_at(a, 6), "corte válido")
	testing.expect(t, t_feq(segs[0].crop2_x, cx) && t_feq(segs[0].crop2_y, cy) && t_feq(segs[0].crop2_w, cw),
		"a esquerda passa a TERMINAR na região do corte (movimento contínuo)")
	testing.expect(t, t_feq(segs[1].crop_x, cx) && t_feq(segs[1].crop_h, ch),
		"a direita passa a COMEÇAR na região do corte")
}

@(test)
remove_com_ripple :: proc(t: ^testing.T) {
	t_reset()
	add_seg(0, 0, 0, 10)    // [0,10)
	add_seg(0, 10, 0, 5)    // [10,15) ← removido
	add_seg(0, 20, 0, 5)    // [20,25) desliza p/ 15
	add_seg(1, 30, 0, 5, 1) // outra trilha: NÃO desliza
	st.playhead = 22
	selected = 2
	remove_seg(1)
	testing.expect(t, nsegs == 3, "sobram 3 segmentos")
	testing.expect(t, t_feq(segs[1].start, 15), "ripple fecha o buraco na mesma trilha")
	testing.expect(t, t_feq(segs[2].start, 30), "a outra trilha não desliza")
	testing.expect(t, t_feq(st.playhead, 17), "playhead acompanha o conteúdo (22−5)")
	testing.expect(t, selected == 1, "índice selecionado corrigido após a compactação")
}

@(test)
remove_sem_ripple_deixa_vao :: proc(t: ^testing.T) {
	t_reset()
	add_seg(0, 0, 0, 10)
	add_seg(0, 10, 0, 5)
	add_seg(0, 20, 0, 5)
	remove_seg(1, false)
	testing.expect(t, nsegs == 2, "sobram 2")
	testing.expect(t, t_feq(segs[1].start, 20), "sem ripple o vizinho fica onde estava (vão)")
}

@(test)
remove_o_selecionado :: proc(t: ^testing.T) {
	t_reset()
	add_seg(0, 0, 0, 10)
	selected = 0
	remove_seg(0)
	testing.expect(t, selected == -1, "remover o selecionado limpa a seleção")
	testing.expect(t, nsegs == 0, "timeline vazia")
	testing.expect(t, timeline_dur() == 0, "duração volta a 0")
}

@(test)
cadeia_contigua_de_corte :: proc(t: ^testing.T) {
	t_reset()
	a := add_seg(0, 10, 0, 20) // fonte [0,20)
	testing.expect(t, split_seg_at(a, 18), "corte válido") // [10,18) fonte[0,8) | [18,30) fonte[8,20)
	testing.expect(t, next_contiguous_seg(0) == 1, "corte simples L|R é contíguo (playback atravessa sem seek)")
	testing.expect(t, t_feq(seg_run_end(0), 20), "fim da cadeia = out na fonte do último pedaço")
	segs[1].start = 40 // afasta a metade direita: quebra a emenda
	testing.expect(t, next_contiguous_seg(0) == -1, "pedaço afastado na timeline não emenda")
	testing.expect(t, t_feq(seg_run_end(0), 8), "cadeia quebrada termina no out do próprio segmento")
}

@(test)
cadeia_nao_emenda_speed_diferente :: proc(t: ^testing.T) {
	t_reset()
	a := add_seg(0, 10, 0, 20)
	testing.expect(t, split_seg_at(a, 18), "corte válido")
	segs[1].speed = 2
	testing.expect(t, next_contiguous_seg(0) == -1, "velocidades diferentes não emendam")
}

@(test)
seg_at_trilha_de_topo :: proc(t: ^testing.T) {
	t_reset()
	testing.expect(t, seg_at(5) == -1, "timeline vazia = -1")
	add_seg(0, 0, 0, 10, 0)  // [0,10) V1
	add_seg(1, 5, 0, 10, 2)  // [5,15) V3 — vence no preview
	testing.expect(t, seg_at(7) == 1, "trilha de cima vence")
	testing.expect(t, seg_at(2) == 0, "fora do de cima, vale o de baixo")
	testing.expect(t, seg_at(10) == 1, "início inclusivo, fim exclusivo")
	testing.expect(t, seg_at(15) == -1, "fim exclusivo do último")
	segs[1].aonly = true
	testing.expect(t, seg_at(7) == 0, "segmento só-áudio não aparece no preview")
	segs[1].aonly = false
	clips[1].probed = false
	testing.expect(t, seg_at(7) == 0, "fonte não-pronta é ignorada")
}

@(test)
seg_local_mapa_fonte :: proc(t: ^testing.T) {
	t_reset()
	si := add_seg(0, 10, 3, 10)
	testing.expect(t, t_feq(seg_local(si, 14), 7), "timeline→fonte: (t−start)+in_off")
	segs[si].speed = 2
	testing.expect(t, t_feq(seg_local(si, 14), 11), "com speed 2 o delta dobra")
	testing.expect(t, t_feq(seg_local(si, 200), 100), "clampa na duração da fonte")
}

@(test)
split_playhead_multitrilha :: proc(t: ^testing.T) {
	t_reset()
	add_seg(0, 0, 0, 10, 0)
	add_seg(1, 0, 0, 10, 1)
	add_seg(0, 0, 0, 10, 2)
	track_locked[1] = true
	st.playhead = 5
	split_at_playhead()
	testing.expect(t, nsegs == 5, "corta as 2 trilhas livres; a bloqueada fica inteira")
	testing.expect(t, t_feq(segs[1].dur, 10), "trilha bloqueada intacta")
}

@(test)
copiar_e_colar_sem_sobrepor :: proc(t: ^testing.T) {
	t_reset()
	a := add_seg(0, 10, 0, 5)
	selected = a
	testing.expect(t, copy_segs() == 1, "copia o selecionado")
	paste_segs(30)
	testing.expect(t, nsegs == 2, "colou 1 segmento")
	testing.expect(t, t_feq(segs[1].start, 30), "cola no destino pedido")
	paste_segs(30) // mesmo lugar de novo: não pode sobrepor
	testing.expect(t, nsegs == 3, "colou de novo")
	testing.expect(t, t_feq(segs[2].start, 35), "empurrado p/ a direita do que já estava lá")
}

// estado "sujo" de edição pesada (2 cortes, ripple, colar, corte no playhead) tem
// que passar limpo pelo verificador de invariantes — se ele disparar aqui, ou uma
// operação corrompeu o estado ou a invariante está forte demais (falso positivo)
@(test)
invariantes_apos_edicao_pesada :: proc(t: ^testing.T) {
	t_reset()
	a := add_seg(0, 0, 0, 20)
	testing.expect(t, split_seg_at(a, 8), "1º corte")
	testing.expect(t, split_seg_at(1, 12), "2º corte")
	add_seg(1, 25, 0, 10, 1)
	selected = 0
	remove_seg(2) // remove o pedaço do meio, com ripple
	testing.expect(t, copy_segs() == 1, "copia o selecionado")
	paste_segs(50)
	st.playhead = 3
	split_at_playhead()
	check_invariants() // com -define:INVARIANTS=true, qualquer violação = panic (falha o teste)
	testing.expect(t, nsegs == 5, "2 pedaços + trilha 1 + colado + metade do corte no playhead")
}

@(test)
timeline_dur_por_trilha :: proc(t: ^testing.T) {
	t_reset()
	add_seg(0, 5, 0, 10)
	add_seg(1, 30, 0, 5, 1)
	testing.expect(t, t_feq(timeline_dur(), 35), "fim do último segmento em qualquer trilha")
	clips[1].probed = false
	testing.expect(t, t_feq(timeline_dur(), 15), "fonte não-pronta não conta")
}

// ---------- geometria vertical das trilhas (altura POR TRILHA) ----------
// A altura deixou de ser um global único: track_y soma as alturas das linhas ACIMA e
// track_at_y percorre acumulando. Se as duas saírem de sincronia, clipes são desenhados
// numa trilha e o arrasto/drop acerta OUTRA — daí os testes de ida-e-volta.
// Layout usado: g_nv=3, g_na=2 -> 5 linhas. Vídeo é invertido (V3 no topo), áudio embaixo:
//   linha 0 = V3(t=2) | 1 = V2(t=1) | 2 = V1(t=0) | 3 = A1(t=MAXV) | 4 = A2(t=MAXV+1)
t_mixed_heights :: proc() {
	track_h[2] = 100          // V3 (linha 0)
	track_h[1] = 0            // V2 (linha 1) -> padrão 72
	track_h[0] = 50           // V1 (linha 2)
	track_h[MAXV] = 120       // A1 (linha 3)
	track_h[MAXV + 1] = 0     // A2 (linha 4) -> padrão 72
}

@(test)
th_usa_padrao_quando_zero :: proc(t: ^testing.T) {
	t_reset()
	testing.expect(t, t_feq(th(0), g_track_h), "0 = altura padrão (trilha nova nasce assim)")
	track_h[0] = 150
	testing.expect(t, t_feq(th(0), 150), "valor próprio quando definido")
}

@(test)
track_of_row_inverte_track_row :: proc(t: ^testing.T) {
	t_reset()
	for tr in ([]int{ 0, 1, 2, MAXV, MAXV + 1 }) {
		testing.expectf(t, track_of_row(track_row(tr)) == tr, "ida-e-volta linha<->trilha (t=%d)", tr)
	}
	testing.expect(t, track_of_row(0) == 2, "linha 0 = trilha de vídeo do TOPO (V3)")
	testing.expect(t, track_of_row(g_nv) == MAXV, "1ª linha de áudio = A1")
}

@(test)
track_y_soma_alturas_individuais :: proc(t: ^testing.T) {
	t_reset()
	t_mixed_heights()
	// acumulado esperado: 0 | +100+3 | +72+3 | +50+3 | +120+3
	testing.expect(t, t_feq(track_y(2), 0),   "V3 (linha 0) começa no topo das trilhas")
	testing.expect(t, t_feq(track_y(1), 103), "V2 = depois de V3(100) + gap(3)")
	testing.expect(t, t_feq(track_y(0), 178), "V1 = 103 + V2 padrão(72) + gap")
	testing.expect(t, t_feq(track_y(MAXV), 231), "A1 = 178 + V1(50) + gap")
	testing.expect(t, t_feq(track_y(MAXV+1), 354), "A2 = 231 + A1(120) + gap")
}

@(test)
track_y_respeita_lanes_top :: proc(t: ^testing.T) {
	t_reset()
	t_mixed_heights()
	base := track_y(0)
	g_lanes_top = 500 // o scroll vertical desloca a origem
	testing.expect(t, t_feq(track_y(0), base + 500), "todas as trilhas deslocam com g_lanes_top")
}

@(test)
track_at_y_ida_e_volta :: proc(t: ^testing.T) {
	t_reset()
	t_mixed_heights()
	for tr in ([]int{ 2, 1, 0, MAXV, MAXV + 1 }) {
		y := track_y(tr)
		h := th(tr)
		testing.expectf(t, track_at_y(y + 1) == tr,       "topo da trilha %d mapeia de volta nela", tr)
		testing.expectf(t, track_at_y(y + h/2) == tr,     "meio da trilha %d idem", tr)
		testing.expectf(t, track_at_y(y + h - 1) == tr,   "base da trilha %d idem (antes do gap)", tr)
	}
}

@(test)
track_at_y_gap_e_bordas :: proc(t: ^testing.T) {
	t_reset()
	t_mixed_heights()
	// o gap pertence à trilha de CIMA (o loop testa y < acumulado + altura + gap)
	testing.expect(t, track_at_y(track_y(1) - 1) == 2, "gap entre linhas fica com a trilha de cima")
	// fora da faixa clampa nas pontas (mesmo contrato do clamp antigo) — arrastar acima/abaixo
	// de tudo não pode devolver trilha inválida
	testing.expect(t, track_at_y(-1000) == track_of_row(0), "acima de tudo = 1ª linha")
	testing.expect(t, track_at_y(99999) == track_of_row(g_nv + g_na - 1), "abaixo de tudo = última linha")
}

@(test)
tracks_content_h_soma_tudo :: proc(t: ^testing.T) {
	t_reset()
	testing.expect(t, t_feq(tracks_content_h(), 5*(72+3)), "padrão: 5 linhas × (72 + gap)")
	t_mixed_heights()
	// 103 + 75 + 53 + 123 + 75
	testing.expect(t, t_feq(tracks_content_h(), 429), "soma as alturas individuais + gaps")
	// coerência com track_y: a última trilha termina exatamente no fim do conteúdo
	last := track_of_row(g_nv + g_na - 1)
	testing.expect(t, t_feq(track_y(last) + th(last) + g_track_gap, tracks_content_h()),
		"fim da última trilha == altura total do conteúdo (scroll depende disso)")
}
