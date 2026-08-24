package main

// Testes unitários da lógica de SEGMENTOS da timeline (corte, ripple, paredes,
// cadeia contígua, ganho de áudio, mapa timeline→fonte). Rodar com:
//
//   odin test src -out:tests.exe -define:ODIN_TEST_THREADS=1 -define:INVARIANTS=true
//
// THREADS=1 é obrigatório: os testes compartilham os globais (segs/clips/st).
// INVARIANTS=true liga o check_invariants() (sem o define a chamada é no-op).
// As fontes são FALSAS (probed=true, sem cache/áudio/textura): clip_frame vira
// no-op (cached=0) e nenhum caminho de raylib-áudio/GL/ffmpeg é tocado — dá pra
// exercitar remove_seg/seek_global inteiros sem janela.

import "core:testing"
import rl "vendor:raylib"

t_feq :: proc(a, b: f32) -> bool { return abs(a - b) < 0.001 }

// zera o estado global da timeline e cria 2 fontes falsas prontas (100s cada)
t_reset :: proc() {
	nsegs = 0
	for i in 0 ..< MAX_SEGS { segs[i] = Seg{}; seg_marked[i] = false }
	nfx = 0; fx_sel = -1; fx_clear_marks()
	for i in 0 ..< MAX_CLIPS do clips[i] = Clip{}
	nclips = 2
	clips[0].probed = true; clips[0].dur = 100
	clips[1].probed = true; clips[1].dur = 100
	g_nv = 3; g_na = 2
	for i in 0 ..< MAXTRACKS { track_muted[i] = false; track_locked[i] = false; track_hidden[i] = false; track_h[i] = 0 }
	// geometria vertical determinística (o draw_timeline é quem seta isso em runtime)
	g_lanes_top = 0; g_track_h = 72; g_track_gap = 3
	st = State{}
	selected = -1; play_clip = -1; drag_clip = -1; sel_trans = -1; bin_sel = -1
	sel_gap_track = -1; sel_gap_t0 = 0; sel_gap_t1 = 0
	seek_rearm_si = -1; audio_hush_at = -1
	src_preview = -1
	player_seek_drag = false
	aud_prev = -1
	snap_line = -1
	seg_clipbrd_n = 0
	fx_clipbrd = {}
	clipbrd_kind = .None
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
undo_restaura_flags_de_trilha :: proc(t: ^testing.T) {
	t_reset()
	add_seg(0, 0, 0, 10)
	history_baseline()
	track_muted[0] = true
	track_locked[1] = true
	track_hidden[2] = true
	history_tick() // assenta o passo (sem arrasto)
	testing.expect(t, undo_top == 1, "silenciar/bloquear/ocultar vira um passo de undo")
	do_undo()
	testing.expect(t, !track_muted[0] && !track_locked[1] && !track_hidden[2], "desfazer devolve as trilhas")
	do_redo()
	testing.expect(t, track_muted[0] && track_locked[1] && track_hidden[2], "refazer reaplica")
	undo_top = 0; redo_top = 0; committed_ok = false // não vaza toast/histórico p/ o próximo teste
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
	testing.expect(t, t_feq(st.playhead, 22), "playhead é tempo global: ripple nesta trilha NÃO o recua")
	testing.expect(t, selected == 1, "índice selecionado corrigido após a compactação")
}

// Cortar no playhead e apagar a metade ESQUERDA: a direita rippla p/ o início e o
// cursor tem que ir junto (senão fica no fim da timeline, no mesmo tempo global).
@(test)
cut_delete_esquerda_segue_playhead :: proc(t: ^testing.T) {
	t_reset()
	a := add_seg(0, 0, 0, 10)
	st.playhead = 4
	testing.expect(t, split_seg_at(a, 4), "corta em 4s")
	// [0,4) e [4,10); playhead na borda
	testing.expect(t, t_feq(st.playhead, 4), "playhead no corte")
	remove_seg(0) // apaga a esquerda com ripple
	testing.expect(t, nsegs == 1, "sobra a metade direita")
	testing.expect(t, t_feq(segs[0].start, 0), "direita desliza p/ 0")
	testing.expect(t, t_feq(segs[0].dur, 6), "duração da direita intacta")
	testing.expect(t, t_feq(st.playhead, 0), "cursor acompanha a emenda (mesmo frame, tempo novo)")
}

// Apagar a metade DIREITA depois do corte: o cursor já está no fim da esquerda — fica.
@(test)
cut_delete_direita_mantem_borda :: proc(t: ^testing.T) {
	t_reset()
	a := add_seg(0, 0, 0, 10)
	st.playhead = 4
	testing.expect(t, split_seg_at(a, 4), "corta em 4s")
	remove_seg(1) // apaga a direita
	testing.expect(t, nsegs == 1, "sobra a esquerda")
	testing.expect(t, t_feq(st.playhead, 4), "cursor fica na borda (fim do que sobrou)")
}

// Playhead DENTRO do pedaço apagado: vai pro início do buraco/emenda.
@(test)
remove_playhead_dentro_vai_pro_inicio :: proc(t: ^testing.T) {
	t_reset()
	add_seg(0, 0, 0, 10)
	add_seg(0, 10, 0, 5) // [10,15) removido com playhead no meio
	add_seg(0, 15, 0, 5) // contíguo: desliza p/ 10
	st.playhead = 12
	remove_seg(1)
	testing.expect(t, t_feq(st.playhead, 10), "cursor no início da emenda após ripple")
	testing.expect(t, t_feq(segs[1].start, 10), "vizinho da direita fechou o buraco")
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

// o clipboard NÃO entra no Snapshot de undo, então ele sobrevive à remoção da trilha de
// onde veio. Sem clampar, o segmento colado nascia com track >= g_nv: track_row ficava
// negativo (desenhado por cima da trilha do topo), o preview e o laço de vídeo do export
// iteram 0..<g_nv e o ignoravam, mas o laço de ÁUDIO percorre todos os segmentos — o
// clipe saía do arquivo exportado só com o som, sem imagem.
@(test)
colar_em_trilha_removida_cai_na_ultima_visivel :: proc(t: ^testing.T) {
	t_reset()
	a := add_seg(0, 10, 0, 5, 2) // V3 (a trilha do topo com g_nv = 3)
	selected = a
	testing.expect(t, copy_segs() == 1, "copia o clipe da trilha do topo")
	remove_seg(a)
	g_nv = 2 // usuário removeu V3 (o × do cabeçalho só aparece com a trilha vazia)
	paste_segs(30)
	testing.expect(t, nsegs == 1, "colou")
	testing.expect(t, segs[0].track < g_nv, "a trilha do clipe colado EXISTE")
	testing.expect(t, segs[0].track == 1, "e é a última visível (V2), não a que sumiu")
}

// mesma proteção do lado do áudio: a trilha do clipboard é clampada dentro da faixa de
// áudio, nunca para uma trilha de vídeo
@(test)
colar_audio_em_trilha_removida_continua_no_audio :: proc(t: ^testing.T) {
	t_reset()
	a := add_seg(0, 10, 0, 5, MAXV + 1) // A2
	selected = a
	testing.expect(t, copy_segs() == 1, "copia o clipe de áudio")
	remove_seg(a)
	g_na = 1 // usuário removeu A2
	paste_segs(30)
	testing.expect(t, nsegs == 1, "colou")
	testing.expect(t, is_audio_track(segs[0].track), "continua numa trilha de ÁUDIO")
	testing.expect(t, segs[0].track == MAXV, "clampado para A1, a última visível")
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

// as janelas de dissolver são CENTRADAS no corte, então dois cortes seguidos disputam o
// espaço do clipe do meio. Sem descontar a transição do corte vizinho, o padrão de 1s em
// ambos ja sobrepunha as duas janelas num clipe curto — e o trans_overlap só devolve UMA
// janela por instante, então o clipe do meio sumia do preview.
@(test)
transicoes_vizinhas_nao_dividem_o_mesmo_espaco :: proc(t: ^testing.T) {
	t_reset()
	_ = add_seg(0, 0, 0, 2)      // A
	b := add_seg(0, 2, 0, 0.8)   // B, o clipe curto do meio
	c := add_seg(0, 2.8, 0, 2.2) // C
	segs[b].trans = 1; segs[c].trans = 1 // 1s em cada corte = 0.5s por lado
	hb := seg_trans(b) / 2
	hc := seg_trans(c) / 2
	testing.expect(t, hb > 0 && hc > 0, "os dois cortes continuam com dissolver")
	testing.expect(t, hb + hc <= segs[b].dur + 0.001, "as duas metades cabem no clipe do meio")
	// e o corte da esquerda também não pode invadir o clipe A alem do que sobra nele
	testing.expect(t, hb <= segs[0].dur + 0.001, "a metade que entra em A cabe em A")
}

// o cadeado da trilha era furado pelo "+" da miniatura do bin, pelo botão Texto e pela
// colocação automática do import — todos escolhiam a trilha sem consultar track_locked
@(test)
escolha_de_trilha_pula_as_bloqueadas :: proc(t: ^testing.T) {
	t_reset()
	track_locked[2] = true
	testing.expect(t, free_track_from(2) == 0, "V3 travada: cai na primeira de vídeo livre")
	track_locked[MAXV] = true
	testing.expect(t, free_track_from(MAXV) == MAXV + 1, "áudio travado procura em OUTRA de áudio")
	track_locked[0] = true; track_locked[1] = true
	testing.expect(t, free_track_from(2) == -1, "todas as de vídeo travadas: sem destino")
	nsegs = 0
	bin_add_to_timeline(0)
	testing.expect(t, nsegs == 0, "e o + do bin desiste em vez de furar o cadeado")
}

// o clamp fade_in+fade_out <= dur só existia no arrasto das alças: aparar, mudar a
// velocidade e cortar encolhiam dur deixando o fade maior que o clipe, e aí a prévia
// (seg_gain) e o export (afade) aplicavam curvas diferentes no mesmo trecho
@(test)
fades_reclampados_quando_o_clipe_encolhe :: proc(t: ^testing.T) {
	t_reset()
	a := add_seg(0, 0, 0, 10)
	segs[a].fade_in = 3; segs[a].fade_out = 4
	testing.expect(t, split_seg_at(a, 2), "corta em 2s")
	for k in 0 ..< nsegs {
		testing.expect(t, segs[k].fade_in <= segs[k].dur + 0.001, "fade_in cabe no pedaço")
		testing.expect(t, segs[k].fade_out <= segs[k].dur + 0.001, "fade_out cabe no pedaço")
		testing.expect(t, segs[k].fade_in + segs[k].fade_out <= segs[k].dur + 0.001, "e a soma dos dois também")
	}
}

// o campo .trans nunca é zerado quando o vizinho da ESQUERDA some, e o trans_max desconta a
// metade do corte vizinho para as janelas não se sobreporem. Sem exigir que o corte ainda
// exista, um dissolver inerte continuava cobrando espaço e encolhia (ou apagava) o do corte
// seguinte — sem o usuário ter tocado nele.
@(test)
transicao_de_corte_que_sumiu_nao_cobra_espaco :: proc(t: ^testing.T) {
	t_reset()
	_ = add_seg(0, 0, 0, 2)    // X
	a := add_seg(0, 2, 0, 0.6) // A, curto
	b := add_seg(0, 2.6, 0, 2) // B
	segs[a].trans = 1; segs[b].trans = 1 // dissolver nos dois cortes
	com_x := seg_trans(b)
	testing.expect(t, com_x > 0.001, "com X presente o dissolver de A|B existe (menor, dividindo A)")
	remove_seg(0, false) // apaga X sem ripple: A e B ficam onde estão; os índices caem 1
	testing.expect(t, trans_prev(0) < 0, "A ficou sem vizinho à esquerda")
	testing.expect(t, seg_trans(0) == 0, "o dissolver de A some junto com o corte, como sempre")
	testing.expect(t, seg_trans(1) > com_x + 0.1, "e o de A|B RECUPERA o espaço que o corte morto ocupava")
}

// o clamp dos fades é destrutivo: rodando a cada frame do arrasto, ir e voltar no slider de
// velocidade devolvia a duração mas não os fades cortados no meio do caminho
@(test)
fades_so_sao_cortados_com_a_interacao_assentada :: proc(t: ^testing.T) {
	t_reset()
	a := add_seg(0, 0, 0, 10)
	segs[a].fade_in = 3; segs[a].fade_out = 3
	segs[a].dur = 2   // como se o slider de velocidade tivesse encolhido o clipe
	st.drag = .Clip   // ...com o arrasto ainda EM CURSO
	fades_settle()
	testing.expect(t, t_feq(segs[a].fade_in, 3), "durante o arrasto o fade original é preservado")
	segs[a].dur = 10  // usuário voltou o slider antes de soltar
	st.drag = .None
	fades_settle()
	testing.expect(t, t_feq(segs[a].fade_in, 3) && t_feq(segs[a].fade_out, 3), "o vai-e-volta não perdeu nada")
	segs[a].dur = 2   // agora encolhe de verdade e solta
	fades_settle()
	testing.expect(t, segs[a].fade_in + segs[a].fade_out <= segs[a].dur + 0.001, "assentado, o corte acontece")
}

// as trilhas de vídeo e de áudio têm orientações OPOSTAS na tela (track_row devolve
// g_nv-1-t para vídeo e g_nv+(t-MAXV) para áudio), então o arrasto vertical de um grupo
// misto precisa deslocar em LINHAS. Somando o mesmo delta de ÍNDICE, como era feito, o
// vídeo descia e o áudio SUBIA no mesmo gesto.
@(test)
deslocamento_vertical_e_em_linhas_nao_em_indices :: proc(t: ^testing.T) {
	t_reset() // g_nv = 3, g_na = 2
	// descer uma linha: a linha na tela cresce em 1 para os DOIS tipos
	v := track_shift_rows(2, 1)          // V3 -> V2
	a := track_shift_rows(MAXV + 1, 1)   // A2 -> ...
	testing.expect(t, track_row(v) == track_row(2) + 1, "vídeo desce uma linha")
	testing.expect(t, track_row(a) == track_row(MAXV + 1) + 1, "áudio desce a MESMA linha")
	testing.expect(t, v == 1, "e no índice de vídeo isso é DESCER o número")
	testing.expect(t, a == MAXV + 2, "enquanto no de áudio é SUBIR o número (orientações opostas)")
	// subir uma linha: simétrico
	testing.expect(t, track_row(track_shift_rows(0, -1)) == track_row(0) - 1, "vídeo sobe uma linha")
	testing.expect(t, track_row(track_shift_rows(MAXV + 1, -1)) == track_row(MAXV + 1) - 1, "áudio sobe uma linha")
	// o tipo nunca muda
	testing.expect(t, !is_audio_track(track_shift_rows(0, -5)), "vídeo continua vídeo")
	testing.expect(t, is_audio_track(track_shift_rows(MAXV, 5)), "áudio continua áudio")
}

// O controle de velocidade do inspetor procurava a parede da direita com
// `fx_wall_r(track, -1, start+0.001)`. O `x - 0.001` de dentro do fx_wall_r cancela o épsilon
// do chamador, a condição do laço de SEGMENTOS vira `segs[i].start >= sg.start`, e o próprio
// segmento selecionado entrava como parede — o `mv` do fx_wall_r só filtra efeitos, não há
// como pedir "ignore este seg" por lá. Resultado: limite = start, duração = 0, e QUALQUER
// mexida no slider ou nos presets encolhia o clipe para o piso de 0,05 s.
@(test)
velocidade_nao_deixa_o_clipe_ser_parede_de_si_mesmo :: proc(t: ^testing.T) {
	for start in ([]f32{ 0, 1, 7.3, 123.456, 3599.5 }) {
		t_reset()
		si := add_seg(0, start, 0, 10) // sozinho na trilha: nada à direita para barrar
		d := speed_fit_dur(si, 5, 100) // 2x: 10s de timeline viram 5s
		testing.expectf(t, t_feq(d, 5), "start=%.3f: a duração pedida passa inteira (deu %.4f)", start, d)
	}
}

// ...e o que a chamada original queria de fato continua valendo.
@(test)
velocidade_para_no_efeito_no_vizinho_e_no_fim_da_fonte :: proc(t: ^testing.T) {
	t_reset()
	si := add_seg(0, 0, 0, 10)
	fxsegs[0] = FxSeg{ track = 0, start = 6, dur = 2 }; nfx = 1
	testing.expect(t, t_feq(speed_fit_dur(si, 20, 100), 6), "o clipe de efeito da trilha é parede")
	nfx = 0
	_ = add_seg(1, 8, 0, 5)
	testing.expect(t, t_feq(speed_fit_dur(si, 20, 100), 8), "o segmento vizinho é parede")
	testing.expect(t, t_feq(speed_fit_dur(si, 20, 3), 3), "e o que resta da fonte também")
	testing.expect(t, t_feq(speed_fit_dur(si, 20, 0), 0.05), "o piso de 0,05s continua sendo o piso")
}

// cortar + acelerar + voltar a 1x tem de devolver o trecho inteiro. Sem ripple o
// vizinho do corte ficava na posição antiga, virava parede, e a metade acelerada
// sumia (dur*speed encolhia em silêncio).
@(test)
velocidade_volta_a_1x_depois_do_corte :: proc(t: ^testing.T) {
	t_reset()
	a := add_seg(0, 0, 0, 10)
	testing.expect(t, split_seg_at(a, 5), "corta no meio")
	src0 := segs[a].dur * seg_speed(a)
	apply_seg_speed(a, 2)
	testing.expect(t, t_feq(segs[a].dur, 2.5), "2x encolhe a metade esquerda na timeline")
	testing.expect(t, t_feq(segs[a].dur * segs[a].speed, src0), "mas o trecho da fonte continua o mesmo")
	testing.expect(t, t_feq(segs[1].start, 2.5), "o vizinho do corte acompanha (sem vão)")
	apply_seg_speed(a, 1)
	testing.expect(t, t_feq(segs[a].speed, 1) && t_feq(segs[a].dur, 5),
		"voltar a 1x devolve a duração original da metade")
	testing.expect(t, t_feq(segs[a].dur * segs[a].speed, src0), "e o trecho da fonte inteiro")
	testing.expect(t, t_feq(segs[1].start, 5), "o vizinho volta pro ponto do corte")
}

@(test)
velocidade_nao_move_a_outra_trilha :: proc(t: ^testing.T) {
	t_reset()
	a := add_seg(0, 0, 0, 10)
	b := add_seg(1, 10, 0, 8, 1) // outra trilha, colado no fim de A
	apply_seg_speed(a, 2)
	testing.expect(t, t_feq(segs[b].start, 10), "trilha vizinha não rippla")
	apply_seg_speed(a, 1)
	testing.expect(t, t_feq(segs[a].dur, 10) && t_feq(segs[b].start, 10), "1x restaura A e B continua")
}

@(test)
velocidade_empurra_efeito_da_trilha :: proc(t: ^testing.T) {
	t_reset()
	si := add_seg(0, 0, 0, 10)
	fxsegs[0] = FxSeg{ track = 0, start = 10, dur = 2 }; nfx = 1
	apply_seg_speed(si, 2)
	testing.expect(t, t_feq(fxsegs[0].start, 5), "efeito colado no fim acompanha o encolhe")
	apply_seg_speed(si, 1)
	testing.expect(t, t_feq(fxsegs[0].start, 10), "e volta no 1x")
}

@(test)
velocidade_audio_separado_acompanha :: proc(t: ^testing.T) {
	t_reset()
	v := add_seg(0, 0, 0, 10)
	a := add_seg(0, 0, 0, 10, MAXV)
	segs[a].aonly = true
	apply_seg_speed(v, 2)
	testing.expect(t, t_feq(segs[v].dur, 5) && t_feq(segs[a].dur, 5), "os dois encolhem")
	testing.expect(t, t_feq(segs[a].speed, 2), "e o áudio separado ganha a mesma velocidade")
	apply_seg_speed(v, 1)
	testing.expect(t, t_feq(segs[v].dur, 10) && t_feq(segs[a].dur, 10) && t_feq(segs[a].speed, 1),
		"voltar a 1x restaura os dois")
}

// `dup_req_c` é zerado à força pela troca de qualidade da prévia e pela remoção de mídia.
// Se isso pegar um pedido ANTES de o worker olhar, ele nunca sinaliza `dup_ready` — o único
// ponto que baixava `dup_inflight`. A flag ficava presa e o dup_request retornava cedo pelo
// RESTO DA SESSÃO: nenhuma vista duplicada ganhava decoder de novo.
@(test)
canal_da_vista_dup_se_solta_quando_o_pedido_e_cancelado :: proc(t: ^testing.T) {
	t_reset()
	_ = add_seg(0, 0, 0, 10)
	dup_ready = false; dup_inflight = false; dup_req_c = -1; dup_req_si = -1
	dup_request(0, 1)
	testing.expect(t, dup_inflight && dup_req_c == 0, "o pedido subiu e ocupou o canal")
	testing.expect(t, !dup_cancel_settle(), "com o pedido de pé, nada é solto")
	dup_req_c = -1 // o cancelamento (stream_quality_sync / remove_media) chega aqui
	testing.expect(t, dup_cancel_settle(), "pedido cancelado: o canal se solta")
	testing.expect(t, !dup_inflight && dup_req_si == -1, "e volta a aceitar pedidos")
	dup_request(0, 1)
	testing.expect(t, dup_inflight && dup_req_c == 0, "o pedido seguinte passa (era isto que morria)")
	// spawn pronto por adotar: quem resolve é o dup_poll, não isto
	dup_req_c = -1; dup_ready = true
	testing.expect(t, !dup_cancel_settle(), "com dup_ready em pé, não rouba o trabalho do dup_poll")
	dup_ready = false; dup_inflight = false; dup_req_c = -1; dup_req_si = -1
}

// o .ovp é texto e pode vir truncado, editado à mão, ou de uma sessão com mais mídias do que
// MAX_CLIPS. `src` vira índice de `clips` dentro de seg_ready/seg_src sem checagem nenhuma
// adiante: fora da faixa, o processo caía no primeiro frame levando o projeto não salvo.
@(test)
linha_de_seg_do_projeto_recusa_o_que_derruba_o_programa :: proc(t: ^testing.T) {
	t_reset() // nclips = 2
	testing.expect(t, seg_line_ok(0, 0, 0, 5), "linha normal passa")
	testing.expect(t, seg_line_ok(1, 12.5, 3, 0.5), "outra linha normal passa")
	testing.expect(t, !seg_line_ok(-1, 0, 0, 5), "fonte negativa é recusada")
	testing.expect(t, !seg_line_ok(2, 0, 0, 5), "fonte >= nclips é recusada")
	testing.expect(t, !seg_line_ok(f32(MAX_CLIPS + 7), 0, 0, 5), "muito além do fim também")
	testing.expect(t, !seg_line_ok(0, 0, 0, 0), "duração zero é recusada (check_invariants cobra dur > 0.01)")
	testing.expect(t, !seg_line_ok(0, 0, 0, -3), "duração negativa também")
	testing.expect(t, !seg_line_ok(0, 0, -1, 5), "in_off negativo também")
	nan := f32(0); nan = nan / nan
	testing.expect(t, !seg_line_ok(nan, 0, 0, 5), "NaN na fonte")
	testing.expect(t, !seg_line_ok(0, nan, 0, 5), "NaN no start")
	testing.expect(t, !seg_line_ok(0, 0, nan, 5), "NaN no in_off")
	testing.expect(t, !seg_line_ok(0, 0, 0, nan), "NaN na duração")
	testing.expect(t, !seg_line_ok(0, 1e30, 0, 5), "infinito no start")
}

@(test)
ripple_nao_puxa_playhead_de_outra_trilha :: proc(t: ^testing.T) {
	t_reset()
	add_seg(0, 0, 0, 60, 0)  // V1 cobre o playhead
	add_seg(1, 10, 0, 10, 1) // V2 [10,20) — o que some
	st.playhead = 30
	remove_seg(1) // ripple só em V2
	testing.expect(t, nsegs == 1, "V2 sumiu")
	testing.expect(t, t_feq(st.playhead, 30), "V1 não foi editada: o cursor fica nos 30s")
}

@(test)
seek_to_seg_if_outside_pula_so_quando_fora :: proc(t: ^testing.T) {
	t_reset()
	a := add_seg(0, 0, 0, 10)   // [0,10)
	b := add_seg(1, 20, 0, 10)  // [20,30)
	st.playhead = 5
	seek_to_seg_if_outside(a)
	testing.expect(t, t_feq(st.playhead, 5), "já está sobre o clipe: cursor fica")
	seek_to_seg_if_outside(b)
	testing.expect(t, t_feq(st.playhead, 20), "fora do clipe: cursor vai ao início")
	st.playhead = 30 // fim EXATO de B — não está DENTRO
	seek_to_seg_if_outside(b)
	testing.expect(t, t_feq(st.playhead, 20), "no fim exato não está SOBRE: volta ao início")
	st.playhead = 25
	seek_to_seg_if_outside(-1)
	testing.expect(t, t_feq(st.playhead, 25), "índice inválido não mexe")
}

@(test)
view_seg_pula_trilha_oculta_e_usa_view_t :: proc(t: ^testing.T) {
	t_reset()
	add_seg(0, 0, 0, 10, 0) // V1
	add_seg(1, 0, 0, 10, 2) // V3 por cima
	track_hidden[2] = true
	st.playhead = 5
	testing.expect(t, view_seg() == 0, "olho fechado em V3: o preview/inspector veem V1")
	st.playhead = 10 // fim EXATO da timeline
	testing.expect(t, view_seg() == 0, "view_t recua 1ms: último quadro, não vazio")
}

@(test)
copy_um_marcado_nao_o_selecionado :: proc(t: ^testing.T) {
	t_reset()
	a := add_seg(0, 0, 0, 5)
	b := add_seg(1, 10, 0, 5, 1)
	selected = b
	seg_marked[a] = true
	testing.expect(t, copy_segs() == 1, "copia o único marcado")
	testing.expect(t, seg_clipbrd[0].src == 0, "é o marcado, não o selecionado")
}

@(test)
fades_video_nao_somam_mais_que_dur :: proc(t: ^testing.T) {
	t_reset()
	si := add_seg(0, 0, 0, 2)
	segs[si].vfin = 1.8
	segs[si].vfout = 1.8
	clamp_fades(&segs[si])
	testing.expect(t, segs[si].vfin + segs[si].vfout <= 2.001, "as duas rampas pretas cabem no clipe")
}

@(test)
snap_alinha_em_efeito :: proc(t: ^testing.T) {
	t_reset()
	st.zoom = 1 // pps() != 0
	add_seg(0, 0, 0, 4)
	nfx = 1
	fxsegs[0] = FxSeg{ start = 10, dur = 2, track = 0 }
	got := snap_start(0, -1, 10.02, 3)
	testing.expect(t, t_feq(got, 10), "borda do efeito é ponto de encaixe")
}

@(test)
audio_seg_at_olha_src_audio :: proc(t: ^testing.T) {
	t_reset()
	clips[0].src_audio = true
	clips[0].has_audio = false // stream ainda não abriu
	add_seg(0, 0, 0, 10)
	testing.expect(t, audio_seg_at(5) == 0, "fonte COM faixa é master mesmo sem rl.Music")
}

@(test)
scrub_thumb_so_se_mais_perto_que_o_frame :: proc(t: ^testing.T) {
	t_reset()
	c := &clips[0]
	c.nthumbs = 36
	c.thumb_dt = 100 // vídeo de ~1h: 1 thumb a cada 100s (centros em 50, 150, …)
	c.tex_t = 50
	testing.expect(t, !scrub_use_thumb(c, 53), "≤4s do frame nítido: não cai na thumb")
	testing.expect(t, !scrub_use_thumb(c, 55), "5s atrás, thumb no mesmo instante: empate fica o frame")
	testing.expect(t, scrub_use_thumb(c, 150), "cursor em outra cena: a thumb de 150s vence o frame em 50s")
}

@(test)
scrub_arrasto_usa_filmstrip_quando_frame_atrasado :: proc(t: ^testing.T) {
	// arrastando um vídeo LONGO o 720p não acompanha: a thumb mais perto do cursor
	// entra no player (cena certa). Perto do frame nítido (≤4s) o 720p continua.
	t_reset()
	c := &clips[0]
	c.nthumbs = 36
	c.thumb_dt = 100
	c.tex_t = 50
	st.drag = .Playhead
	testing.expect(t, scrub_player_uses_thumb(c, 150), "arrasto longe: thumb da cena certa")
	testing.expect(t, !scrub_player_uses_thumb(c, 53), "arrasto perto: fica o 720p")
	st.drag = .None
	player_seek_drag = true
	testing.expect(t, scrub_player_uses_thumb(c, 150), "barra longe: mesma regra")
	player_seek_drag = false
	testing.expect(t, scrub_player_uses_thumb(c, 150), "parado longe: thumb também")
}

@(test)
scrub_arrasto_atualiza_video_sob_texto :: proc(t: ^testing.T) {
	t_reset()
	clips[0].streaming = true
	clips[0].tex_t = 0
	clips[1].is_text = true
	add_seg(0, 0, 0, 10, 0) // V1 = vídeo
	add_seg(1, 0, 0, 10, 1) // V2 = título por cima (é o view_seg)
	st.playhead = 5
	scrub_req_c = -1
	scrub_req_t = 0
	testing.expect(t, view_seg() == 1, "topo é o texto")
	scrub_at_playhead()
	testing.expect(t, scrub_req_c == 0, "o worker pede o VÍDEO debaixo, não o título")
	testing.expect(t, t_feq(scrub_req_t, 5), "no tempo local do cursor")
	scrub_req_c = -1
}

@(test)
scrub_arrasto_pede_camada_mais_atrasada :: proc(t: ^testing.T) {
	t_reset()
	clips[0].streaming = true; clips[0].tex_t = 1 // base quase no cursor
	clips[1].streaming = true; clips[1].tex_t = 0 // overlay parado no 0
	add_seg(0, 0, 0, 10, 0)
	add_seg(1, 0, 0, 10, 1)
	st.playhead = 8
	scrub_req_c = -1
	scrub_at_playhead()
	testing.expect(t, scrub_req_c == 1, "overlay está 8s atrasado; a base só 7s")
	testing.expect(t, t_feq(scrub_req_t, 8), "tempo local do overlay")
	scrub_req_c = -1
}

@(test)
acha_vao_entre_clipes :: proc(t: ^testing.T) {
	t_reset()
	add_seg(0, 0, 0, 10)  // [0,10)
	add_seg(0, 20, 0, 5)  // [20,25)
	ok, t0, t1 := find_gap_at(0, 15)
	testing.expect(t, ok, "há vão em t=15")
	testing.expect(t, t_feq(t0, 10) && t_feq(t1, 20), "vão = [10,20)")
	ok, _, _ = find_gap_at(0, 5)
	testing.expect(t, !ok, "dentro do clipe não é vão")
	ok, _, _ = find_gap_at(0, 30)
	testing.expect(t, !ok, "depois do último não há o que puxar")
	ok, t0, t1 = find_gap_at(0, 2)
	testing.expect(t, !ok, "início colado em 0 não é vão")
}

@(test)
acha_vao_no_comeco_da_trilha :: proc(t: ^testing.T) {
	t_reset()
	add_seg(0, 8, 0, 4) // [8,12)
	ok, t0, t1 := find_gap_at(0, 3)
	testing.expect(t, ok && t_feq(t0, 0) && t_feq(t1, 8), "vão inicial = [0, 8)")
}

@(test)
fecha_vao_desliza_so_a_mesma_trilha :: proc(t: ^testing.T) {
	t_reset()
	add_seg(0, 0, 0, 10)     // [0,10)
	add_seg(0, 20, 0, 5)     // [20,25) → 10
	add_seg(1, 20, 0, 5, 1)  // outra trilha: fica
	nfx = 1
	fxsegs[0] = FxSeg{ start = 22, dur = 2, track = 0 } // efeito depois do vão → 12
	st.playhead = 30
	testing.expect(t, close_gap(0, 10, 20), "fecha")
	testing.expect(t, t_feq(segs[1].start, 10), "clipe da direita encostou")
	testing.expect(t, t_feq(segs[2].start, 20), "outra trilha não mexe")
	testing.expect(t, t_feq(fxsegs[0].start, 12), "efeito da trilha deslizou")
	testing.expect(t, t_feq(st.playhead, 30), "playhead fora do vão fica no tempo global")
}

@(test)
fecha_vao_playhead_dentro_vai_pro_inicio :: proc(t: ^testing.T) {
	t_reset()
	add_seg(0, 0, 0, 5)
	add_seg(0, 15, 0, 5)
	st.playhead = 10
	close_gap(0, 5, 15)
	testing.expect(t, t_feq(st.playhead, 5), "cursor no buraco vai p/ a emenda")
}

@(test)
fecha_todos_os_vaos_da_trilha :: proc(t: ^testing.T) {
	t_reset()
	add_seg(0, 4, 0, 4)   // [4,8)
	add_seg(0, 12, 0, 3)  // [12,15)
	add_seg(0, 20, 0, 2)  // [20,22)
	n := close_all_gaps(0)
	testing.expect(t, n == 3, "vão inicial + 2 intervalos")
	testing.expect(t, t_feq(segs[0].start, 0), "primeiro colou em 0")
	testing.expect(t, t_feq(segs[1].start, 4), "segundo encostou no primeiro")
	testing.expect(t, t_feq(segs[2].start, 7), "terceiro encostou no segundo")
}

@(test)
fecha_vao_trilha_travada :: proc(t: ^testing.T) {
	t_reset()
	add_seg(0, 0, 0, 5)
	add_seg(0, 12, 0, 5)
	track_locked[0] = true
	testing.expect(t, !close_gap(0, 5, 12), "cadeado recusa")
	testing.expect(t, t_feq(segs[1].start, 12), "nada moveu")
}

@(test)
copiar_colar_efeitos_de_cor :: proc(t: ^testing.T) {
	t_reset()
	a := add_seg(0, 0, 0, 10, 0)
	b := add_seg(1, 20, 0, 8, 0)
	segs[a].fx_bright = 0.4
	segs[a].fx_look = 2
	segs[a].fx_vignette = 0.6
	segs[a].bulge = 0.35
	testing.expect(t, copy_effects(a), "copia os efeitos do primeiro")
	testing.expect(t, fx_clipbrd_ok(), "clipboard de efeitos preenchido")
	testing.expect(t, paste_effects(b) >= 0, "cola no segundo")
	testing.expect(t, t_feq(segs[b].fx_bright, 0.4) && t_feq(segs[b].fx_look, 2), "cor colada")
	testing.expect(t, t_feq(segs[b].fx_vignette, 0.6) && t_feq(segs[b].bulge, 0.35), "vinheta/distorção coladas")
	testing.expect(t, segs[b].src == 1 && t_feq(segs[b].start, 20), "o clipe-destino não muda de mídia nem de tempo")
}

@(test)
copiar_colar_ajustes_do_inspector :: proc(t: ^testing.T) {
	t_reset()
	a := add_seg(0, 0, 0, 10, 0)
	b := add_seg(1, 20, 0, 8, 0)
	segs[a].scale = 1.4
	segs[a].px = 0.2
	segs[a].py = -0.15
	segs[a].rot = 12
	segs[a].opacity = 0.7
	segs[a].speed = 2
	segs[a].crop_x = 0.1; segs[a].crop_y = 0.1; segs[a].crop_w = 0.6; segs[a].crop_h = 0.6
	segs[a].vol = 0.5
	segs[a].vfin = 0.4
	testing.expect(t, copy_effects(a), "copia os ajustes do inspector")
	testing.expect(t, paste_effects(b) >= 0, "cola no segundo")
	testing.expect(t, t_feq(segs[b].scale, 1.4) && t_feq(segs[b].px, 0.2) && t_feq(segs[b].py, -0.15), "transform")
	testing.expect(t, t_feq(segs[b].rot, 12) && t_feq(segs[b].opacity, 0.7), "rotação/opacidade")
	testing.expect(t, t_feq(segs[b].speed, 2) && t_feq(segs[b].vol, 0.5), "velocidade/volume")
	testing.expect(t, t_feq(segs[b].crop_w, 0.6) && t_feq(segs[b].vfin, 0.4), "recorte e fade")
	testing.expect(t, segs[b].src == 1 && t_feq(segs[b].start, 20), "não troca o vídeo nem o tempo")
}

@(test)
copiar_efeitos_vazio_nao_suja_clipboard :: proc(t: ^testing.T) {
	t_reset()
	a := add_seg(0, 0, 0, 5)
	testing.expect(t, !copy_effects(a), "sem ajustes: recusa")
	testing.expect(t, !fx_clipbrd_ok(), "clipboard continua vazio")
}

@(test)
colar_efeitos_de_faixa_no_outro_video :: proc(t: ^testing.T) {
	t_reset()
	a := add_seg(0, 0, 0, 10, 0)   // V1 [0,10)
	b := add_seg(1, 20, 0, 10, 0)  // V1 [20,30)
	nfx = 1
	fxsegs[0] = FxSeg{ kind = FX_DISTORT, track = 1, start = 2, dur = 4, amount = 0.7, radius = 0.4 }
	testing.expect(t, copy_effects(a), "copia o efeito que cobre o 1º clipe")
	testing.expect(t, fx_clipbrd.nfx == 1, "1 efeito de faixa no clipboard")
	n0 := nfx
	testing.expect(t, paste_effects(b) == 1, "cria o efeito sobre o 2º")
	testing.expect(t, nfx == n0 + 1, "mais um clipe de efeito")
	e := fxsegs[nfx - 1]
	testing.expect(t, e.kind == FX_DISTORT && t_feq(e.amount, 0.7), "parâmetros iguais")
	testing.expect(t, t_feq(e.start, 22) && t_feq(e.dur, 4), "realinhado no destino (offset 2s)")
	testing.expect(t, e.track != segs[b].track, "não pousa em cima do vídeo-destino")
	testing.expect(t, e.track >= segs[b].track, "rege o destino (trilha >=)")
}

@(test)
copiar_efeito_ao_lado_do_clipe_na_mesma_trilha :: proc(t: ^testing.T) {
	t_reset()
	a := add_seg(0, 0, 0, 10, 0) // [0,10)
	b := add_seg(1, 20, 0, 8, 0)
	nfx = 1
	fxsegs[0] = FxSeg{ kind = FX_RGB, track = 0, start = 10, dur = 3, amount = 0.8, angle = 0.1 }
	testing.expect(t, copy_effects(a), "efeito no vão ao lado conta como efeito do clipe")
	testing.expect(t, fx_clipbrd.nfx == 1 && fx_clipbrd.cover, "vai cobrir o destino")
	testing.expect(t, paste_effects(b) == 1, "cola no outro vídeo")
	e := fxsegs[nfx - 1]
	testing.expect(t, e.kind == FX_RGB && t_feq(e.amount, 0.8), "parâmetros")
	testing.expect(t, t_feq(e.start, 20) && t_feq(e.dur, 8), "cobre o destino")
}

@(test)
colar_efeito_no_vao_vazio :: proc(t: ^testing.T) {
	t_reset()
	nfx = 1
	fxsegs[0] = FxSeg{ kind = FX_DISTORT, track = 1, start = 0, dur = 3, amount = 0.4 }
	testing.expect(t, copy_fx_clip(0), "copia o clipe de efeito")
	testing.expect(t, clipbrd_kind == .Fx, "área de transferência é de efeito")
	testing.expect(t, paste_fx_at(0, 12) == 1, "cola no vão")
	e := fxsegs[nfx - 1]
	testing.expect(t, t_feq(e.start, 12) && e.track == 0, "no tempo e trilha do clique")
}

@(test)
copiar_clipe_de_efeito_cobre_o_destino :: proc(t: ^testing.T) {
	t_reset()
	b := add_seg(0, 15, 0, 6, 0)
	nfx = 1
	fxsegs[0] = FxSeg{ kind = FX_RGB, track = 1, start = 0, dur = 3, amount = 0.55, angle = 0.25 }
	testing.expect(t, copy_fx_clip(0), "copia o clipe de efeito")
	testing.expect(t, fx_clipbrd.cover, "colar cobre o destino inteiro")
	testing.expect(t, paste_effects(b) == 1, "cola cobrindo o vídeo")
	e := fxsegs[nfx - 1]
	testing.expect(t, e.kind == FX_RGB && t_feq(e.amount, 0.55), "tipo e intensidade")
	testing.expect(t, t_feq(e.start, 15) && t_feq(e.dur, 6), "cobre [15,21) do destino")
}

@(test)
marquee_seleciona_efeitos :: proc(t: ^testing.T) {
	t_reset()
	st.zoom = 1
	nfx = 2
	fxsegs[0] = FxSeg{ kind = FX_DISTORT, track = 1, start = 0, dur = 3 }
	fxsegs[1] = FxSeg{ kind = FX_RGB, track = 1, start = 8, dur = 3 }
	view := rl.Rectangle{ 0, -2000, 20000, 20000 }
	mq := fx_rect(0)
	mq.width += 4; mq.height += 4
	tl_marquee_apply(mq, view, false)
	testing.expect(t, fx_marked[0], "efeito sob o retângulo entra na seleção")
	testing.expect(t, !fx_marked[1], "efeito fora do retângulo fica de fora")
	testing.expect(t, fx_sel == 0, "foco no primeiro marcado")

	tl_marquee_apply(fx_rect(1), view, true)
	testing.expect(t, fx_marked[0] && fx_marked[1], "Ctrl/soma acrescenta o segundo")
	testing.expect(t, fx_marks_count() == 2, "os dois ficam marcados")
}

@(test)
marquee_nao_marca_efeito_em_trilha_travada :: proc(t: ^testing.T) {
	t_reset()
	st.zoom = 1
	nfx = 1
	fxsegs[0] = FxSeg{ kind = FX_BLUR, track = 0, start = 0, dur = 4 }
	track_locked[0] = true
	view := rl.Rectangle{ 0, -2000, 20000, 20000 }
	tl_marquee_apply(fx_rect(0), view, false)
	testing.expect(t, !fx_marked[0], "trilha travada não entra na marquee")
	testing.expect(t, fx_sel < 0, "sem foco")
}

@(test)
remove_fxseg_desloca_marcas :: proc(t: ^testing.T) {
	t_reset()
	nfx = 3
	fxsegs[0] = FxSeg{ kind = FX_PIXEL, track = 1, start = 0, dur = 2 }
	fxsegs[1] = FxSeg{ kind = FX_BLUR, track = 1, start = 3, dur = 2 }
	fxsegs[2] = FxSeg{ kind = FX_GRAIN, track = 1, start = 6, dur = 2 }
	fx_marked[1] = true; fx_marked[2] = true; fx_sel = 2
	remove_fxseg(1)
	testing.expect(t, nfx == 2, "compactou")
	testing.expect(t, fx_marked[1] && fxsegs[1].kind == FX_GRAIN, "marca do 3º desceu com ele")
	testing.expect(t, fx_sel == 1, "foco acompanhou o índice")
}

@(test)
fx_biblioteca_tem_os_tipos_novos :: proc(t: ^testing.T) {
	testing.expect(t, string(fxlib_name(FX_PIXEL)) == "Pixelizar")
	testing.expect(t, string(fxlib_name(FX_BLUR)) == "Desfoque")
	testing.expect(t, string(fxlib_name(FX_GRAIN)) == "Granulação")
	testing.expect(t, string(fxlib_name(FX_MIRROR)) == "Espelhar")
	testing.expect(t, string(fxlib_name(FX_SHARP)) == "Nitidez")
	testing.expect(t, string(fxlib_name(FX_SPOT)) == "Holofote")
	testing.expect(t, string(fxlib_name(FX_SHAKE)) == "Tremor")
	testing.expect(t, string(fxlib_name(FX_POSTER)) == "Posterizar")
	testing.expect(t, len(fx_lib) >= 10, "biblioteca tem distorção, RGB e os 8 novos")
	f := FxSeg{ kind = FX_SPOT }
	fx_defaults(&f)
	testing.expect(t, f.amount > 0.5 && f.radius > 0.2, "holofote nasce visível")
}
