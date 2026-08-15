package main

import rl "vendor:raylib"
import "base:intrinsics"
import "core:fmt"
import "core:math"

State :: struct {
	active_tab: int,
	playing:    bool,
	playhead:   f32, // segundos, tempo absoluto na timeline
	zoom:       f32, // pixels por segundo = 20 * zoom
	drag:       Drag,
}
Drag :: enum { None, Playhead, Clip, Bin, FadeIn, FadeOut, Vol, PreviewMove, Trans, TransDur, FxCenter, FxLib, FxClip, FxTrim, FxCtr }
trans_drag: int = -1 // tipo de transição sendo arrastado do painel (-1 = nenhum)
sel_trans: int = -1  // transição/fade SELECIONADO na timeline = índice do seg (-1 = nenhum)
sel_trans_kind: int = 0 // tipo do selecionado: 0=dissolver, 1=fade preto de entrada, 2=fade preto de saída
VOL_MAX :: f32(2) // teto do volume por segmento (200%) — usado na linha de volume e sliders
st: State

// Um segmento é uma COLOCAÇÃO na timeline: aponta para uma mídia-fonte (clips[])
// e recorta um trecho dela (in_off..in_off+dur). Vários segmentos podem apontar
// para a mesma fonte — é isso que permite cortar/dividir um clipe sem duplicar
// decode, áudio ou textura (tudo continua na fonte).
Seg :: struct {
	src:    int, // índice da mídia-fonte em clips[]
	track:  int, // trilha (0 = base/V1 embaixo; maior = por cima — vence no preview)
	start:  f32, // tempo na timeline onde o segmento começa (s)
	in_off: f32, // deslocamento dentro da fonte (s) — ponto de entrada
	dur:    f32, // duração do segmento (s)
	// controles de áudio por segmento (aplicados no stream ativo via SetMusicVolume)
	vol:      f32,  // multiplicador de volume (1 = 100%); 0 no zero-value tratado como 1
	muted:    bool, // silencia este segmento
	fade_in:  f32,  // duração do fade-in de áudio (s)
	fade_out: f32,  // duração do fade-out de áudio (s)
	// transform de vídeo (compositing das trilhas): PiP, split-screen, etc.
	scale:    f32,  // escala (1 = 100%); 0 no zero-value tratado como 1
	px, py:   f32,  // posição: fração do frame a partir do centro (0,0 = centro)
	rot:      f32,  // rotação (graus)
	opacity:  f32,  // opacidade (1 = opaco); 0 no zero-value tratado como 1
	// velocidade de reprodução: dur é SEMPRE tempo de timeline; a fonte consumida é
	// dur*speed (a partir de in_off). speed 2 = 2x (mais rápido); 0.5 = câmera lenta.
	speed:    f32,  // 1 = normal; 0 no zero-value tratado como 1
	// TRANSIÇÃO (dissolver): blend de `trans` segundos com o clipe anterior adjacente
	// na mesma trilha. Usa o "handle" da fonte (footage antes de in_off): durante
	// [start-trans, start] o clipe anterior some enquanto ESTE entra. 0 = sem transição.
	trans:    f32,
	// FADE PRETO: o clipe surge do preto nos primeiros `vfin` s e some no preto nos
	// últimos `vfout` s (rampa de opacidade; na trilha base = preto de verdade).
	vfin:     f32,
	vfout:    f32,
	// RECORTE ESPACIAL (crop): sub-região do quadro a MANTER, em frações [0,1] da fonte
	// (crop_w<=0 no zero-value = quadro inteiro, sem recorte). A região recortada é ajustada
	// ao canvas preservando o aspecto dela; escala/posição/rotação atuam por cima.
	crop_x, crop_y, crop_w, crop_h: f32,
	// ZOOM ANIMADO (Pan & Zoom estilo NLE): quando zoom_anim=true, a REGIÃO de recorte
	// vai de (crop_*) no INÍCIO do clipe a (crop2_*) no FIM, interpolada no tempo com easing
	// suave. Reaproveita TODO o render/escala do crop (a região menor = mais zoom). Preview
	// anima ao vivo; no export vira `zoompan` com a MESMA curva (ver start_export — crop não
	// serve lá: fixa w/h na init). zoom_anim=false = recorte estático.
	zoom_anim: bool,
	crop2_x, crop2_y, crop2_w, crop2_h: f32,
	// EFEITO de distorção radial (bulge/pinch): infla o rosto/centro (bulge>0) ou aperta
	// (bulge<0). bulge=0 no zero-value = efeito DESLIGADO. Centro do efeito = (0.5+bulge_x,
	// 0.5+bulge_y) em coords LOCAIS da região exibida (bulge_x/y = deslocamento do meio).
	// bulge_r = raio [0..1]; 0 no zero-value tratado como BULGE_R_DEF. Aplicado por um
	// fragment shader no preview (ao vivo); no export, por `remap` com mapas xmap/ymap
	// gerados em PGM 16 bits (write_bulge_maps) e passados como inputs — ver start_export.
	bulge:   f32,
	bulge_x: f32,
	bulge_y: f32,
	bulge_r: f32,
	// WOBBLE: anima a distorção — a força efetiva oscila `bulge ± wobble` por uma senoide
	// no tempo LOCAL do segmento (playhead-start). wobble=0 = estático. wobble_speed em Hz
	// (0 no zero-value tratado como WOBBLE_HZ_DEF). Preview passa a força já modulada ao
	// shader; export gera 1 período de mapas e faz o remap ciclar (ver start_export).
	wobble:       f32,
	wobble_speed: f32,
	// SÓ-ÁUDIO: segmento de trilha de áudio criado por "Separar áudio" — a fonte é um
	// VÍDEO, mas este segmento toca apenas o áudio dela (o preview/export ignoram o
	// vídeo dele). Falso no zero-value = comportamento normal pela mídia.
	aonly: bool,
	// EFEITOS DE COR: aplicados no MESMO fragment shader do bulge (preview ao vivo) e
	// mapeados p/ filtros do ffmpeg no export (eq/hue/negate/colorchannelmixer/vignette).
	// TODOS os campos têm 0 = NEUTRO (zero-value = sem efeito; projetos antigos abrem iguais).
	fx_bright:   f32, // brilho    -1..1 (0 neutro; somado)
	fx_contrast: f32, // contraste -1..1 (0 neutro; efetivo = 1+valor, em torno de 0.5)
	fx_satur:    f32, // saturação -1..1 (0 neutro; efetivo = 1+valor)
	fx_look:     f32, // visual: 0 nenhum | 1 P&B | 2 sépia | 3 inverter
	fx_vignette: f32, // vinheta 0..1 (escurece as bordas)
	fx_temp:     f32, // temperatura -1(frio)..1(quente): +R/-B quente, -R/+B frio
}
// Trilhas DINÂMICAS (estilo NLE). O índice da trilha carrega o tipo: vídeo ocupa a faixa
// FIXA [0, MAXV) e áudio a faixa FIXA [MAXV, MAXV+MAXA). Manter a base do áudio fixa em MAXV é o
// que permite adicionar/remover trilhas de vídeo SEM re-indexar os segmentos de áudio. `g_nv`/`g_na`
// contam quantas trilhas de cada tipo estão VISÍVEIS agora (o resto da faixa fica reservado/oculto).
MAXV :: 12 // capacidade máx de trilhas de VÍDEO  (índices 0..MAXV-1)
MAXA :: 12 // capacidade máx de trilhas de ÁUDIO  (índices MAXV..MAXV+MAXA-1)
MAXTRACKS :: MAXV + MAXA
g_nv: int = 3 // trilhas de vídeo visíveis (V1..Vg_nv)
g_na: int = 2 // trilhas de áudio visíveis (A1..Ag_na)
is_audio_track :: proc(t: int) -> bool { return t >= MAXV }
// cria uma trilha nova e devolve seu índice (-1 se atingiu a capacidade). Vídeo entra no TOPO
// (maior índice = vence o compositing); áudio entra embaixo. Nenhum re-index: a base é fixa.
add_video_track :: proc() -> int { if g_nv >= MAXV do return -1; g_nv += 1; return g_nv - 1 }
add_audio_track :: proc() -> int { if g_na >= MAXA do return -1; g_na += 1; return MAXV + g_na - 1 }
track_muted:  [MAXTRACKS]bool // trilha silenciada (não toca áudio nenhum dos seus segmentos)
track_locked: [MAXTRACKS]bool // trilha bloqueada: seus segmentos não movem, aparam nem cortam
track_hidden: [MAXTRACKS]bool // trilha de vídeo oculta: seus segmentos não aparecem no preview nem no export (áudio continua)
MAX_SEGS :: 64
segs:  [MAX_SEGS]Seg
nsegs: int

// EFEITO como CLIPE na timeline (estilo NLE): ocupa [start, start+dur] numa faixa própria
// acima das trilhas e aplica seu efeito VISUAL a todo o quadro durante esse intervalo. Cada
// clipe guarda seus PRÓPRIOS parâmetros (editáveis ao dar duplo-clique). kind: 0 = Distorção,
// 1 = Separação RGB.
FX_DISTORT :: 0
FX_RGB     :: 1
FxSeg :: struct {
	kind:   int,
	track:  int, // trilha de VÍDEO onde o efeito está (afeta essa trilha e as ABAIXO dela: índice <= track)
	start, dur: f32,
	amount: f32, // Distorção: intensidade | RGB: intensidade da separação
	radius: f32, // Distorção: raio
	cx, cy: f32, // Distorção: centro (offset do meio)
	wobble: f32, // Distorção: tremor
	speed:  f32, // Distorção: velocidade do tremor
	angle:  f32, // RGB: direção (0=horizontal, 0.25=vertical "cima-baixo")
}
MAX_FX :: 32
fxsegs:      [MAX_FX]FxSeg
nfx:         int
fx_sel:      int = -1 // clipe de efeito selecionado (-1 = nenhum)
fxlib_drag:  int = -1 // índice em fx_lib sendo arrastado do painel p/ a timeline

// --- undo/redo: snapshot do documento (só os segmentos — Seg é struct puro, cópia
// barata). Detecção AUTOMÁTICA: qualquer mudança em segs vira uma entrada quando a
// interação assenta (fora de arrasto/slider), sem instrumentar cada operação. ---
// g_nv/g_na entram no snapshot: sem eles, desfazer podia devolver um segmento a uma
// trilha removida (track_row negativo = desenhado sobre a régua e inalcançável)
Snapshot :: struct { segs: [MAX_SEGS]Seg, nsegs: int, fxsegs: [MAX_FX]FxSeg, nfx: int, nv, na: int }
MAX_UNDO :: 100
undo_stack: [MAX_UNDO]Snapshot
undo_top:   int
redo_stack: [MAX_UNDO]Snapshot
redo_top:   int
committed:  Snapshot // último estado estável (baseline p/ detectar mudança)
committed_ok: bool

// ---------- timeline / navegação (opera sobre os segmentos colocados) ----------
seg_src :: proc(si: int) -> ^Clip { return &clips[segs[si].src] } // fonte do segmento
seg_ready :: proc(si: int) -> bool { return media_ready(segs[si].src) }

// o segmento conta como OBSTÁCULO nas checagens de colisão? Mídia ainda IMPORTANDO
// bloqueia (com seg_ready dava p/ soltar/mover/colar outro clipe em cima durante o
// import assíncrono — a sobreposição só aparecia quando o probe terminava, violando
// o invariante). Só mídia FALHA ou removida (tombstone) não bloqueia.
seg_blocks :: proc(si: int) -> bool {
	s := segs[si].src
	if s < 0 || s >= nclips do return false
	return !clips[s].closed && !intrinsics.atomic_load(&clips[s].failed)
}

// a mídia i tem pelo menos um segmento na timeline? (p/ o selo "na timeline" no bin)
src_placed :: proc(i: int) -> bool {
	for k in 0 ..< nsegs do if segs[k].src == i do return true
	return false
}

// (botão "+" da miniatura do bin) coloca a mídia na timeline a partir do PLAYHEAD, empurrando
// p/ o 1º vão livre da trilha — mesma regra do drop do bin, sem precisar arrastar.
// Áudio vai p/ trilha de áudio; vídeo/imagem/texto p/ V1.
bin_add_to_timeline :: proc(i: int) {
	if i < 0 || i >= nclips do return
	c := &clips[i]
	if !media_ready(i) do return
	tr := free_track_from(track_for_media(i, 0))
	if tr < 0 { set_toast("Trilha bloqueada"); return }
	start := free_start(tr, -1, st.playhead, c.dur)
	si := add_seg(i, start, 0, c.dur, tr)
	if si < 0 do return // add_seg já avisa (timeline cheia)
	selected = si; bin_sel = -1; insp_tab = 0
	seek_global(st.playhead)
	set_toast(rl.TextFormat("%s adicionado à timeline", cs(c.name)))
}

// cria um segmento (colocação na timeline) na trilha `track`. Retorna o índice, ou -1 se lotado.
add_seg :: proc(src: int, start, in_off, dur: f32, track := 0) -> int {
	if nsegs >= MAX_SEGS { set_toast("Máximo de segmentos na timeline"); return -1 }
	segs[nsegs] = Seg{ src = src, track = track, start = max(0, start), in_off = in_off, dur = dur, vol = 1, scale = 1, opacity = 1, speed = 1 }
	seg_marked[nsegs] = false // novo segmento nasce desmarcado
	nsegs += 1
	if src >= 0 && src < nclips do maybe_adopt_aspect(&clips[src]) // 1º vídeo na timeline define proj_ar
	return nsegs - 1
}

// reajusta os fades à duração ATUAL do segmento. Chame sempre que `dur` encolher: o clamp
// só existia no arrasto das alças, então aparar/mudar a velocidade/cortar deixavam para trás
// um fade maior que o clipe — a prévia (seg_gain, que divide por fade_in) e o export
// (afade com st negativo) passavam a aplicar curvas DIFERENTES no mesmo trecho.
clamp_fades :: proc(sg: ^Seg) {
	sg.fade_in  = clamp(sg.fade_in,  0, sg.dur)
	sg.fade_out = clamp(sg.fade_out, 0, sg.dur)
	if sg.fade_in + sg.fade_out > sg.dur do sg.fade_out = max(0, sg.dur - sg.fade_in)
	// fade PRETO: as duas rampas no mesmo clipe não podem somar mais que dur
	// (o arrasto de cada alça ia até 0.9*dur sozinho — as duas juntas estouravam)
	sg.vfin  = clamp(sg.vfin,  0, sg.dur)
	sg.vfout = clamp(sg.vfout, 0, sg.dur)
	if sg.vfin + sg.vfout > sg.dur do sg.vfout = max(0, sg.dur - sg.vfin)
}

// (main, todo frame) reajusta os fades de TODOS os segmentos — mas só com a interação
// ASSENTADA. O clamp é destrutivo: rodando a cada frame do arrasto do slider de velocidade
// (ou do aparo), ir até 4x cortava os fades e voltar a 1x devolvia a duração mas não eles.
// Aqui o corte só acontece quando o usuário solta, então o vai-e-volta dentro do mesmo
// arrasto não perde nada. Roda antes do history_tick p/ o ajuste entrar no mesmo passo de
// undo da edição que o causou.
fades_settle :: proc() {
	if edit_in_progress() do return
	for i in 0 ..< nsegs do clamp_fades(&segs[i])
}

// primeira trilha NÃO travada a partir de `tr`, dentro do MESMO tipo (vídeo/áudio); procura
// para cima e depois dá a volta. -1 = todas travadas. Sem isto, o "+" da miniatura do bin, o
// botão Texto e a colocação automática do import furavam o cadeado que a timeline promete.
free_track_from :: proc(tr: int) -> int {
	lo, hi := 0, g_nv
	if is_audio_track(tr) { lo, hi = MAXV, MAXV + g_na }
	t := clamp(tr, lo, hi - 1)
	for k := t; k < hi; k += 1 do if !track_locked[k] do return k
	for k := lo; k < t; k += 1 do if !track_locked[k] do return k
	return -1
}

// volume efetivo do segmento em `t` (tempo absoluto da timeline): vol × mudo × envelope
// de fade in/out. Aplicado a cada frame no stream ativo via SetMusicVolume.
seg_gain :: proc(si: int, t: f32) -> f32 {
	if si < 0 || si >= nsegs do return 1
	sg := segs[si]
	if sg.muted || track_muted[sg.track] do return 0
	g := sg.vol
	p := t - sg.start // posição dentro do segmento (0..dur)
	if sg.fade_in  > 0.001 && p < sg.fade_in            do g *= clamp(p / sg.fade_in, 0, 1)
	if sg.fade_out > 0.001 && p > sg.dur - sg.fade_out  do g *= clamp((sg.dur - p) / sg.fade_out, 0, 1)
	return max(0, g)
}

// EFEITOS ocupam a trilha como um clipe: um fxseg na trilha `tr` cobre [start,dur)? (≠ mv; encostar não conta)
fx_hit :: proc(tr, mv: int, start, dur: f32) -> bool {
	for k in 0 ..< nfx {
		if k == mv || fxsegs[k].track != tr do continue
		if start < fxsegs[k].start + fxsegs[k].dur - 0.001 && start + dur > fxsegs[k].start + 0.001 do return true
	}
	return false
}
// colisão/paredes/encaixe do PRÓPRIO efeito (≠ mv): contra segs de vídeo E outros efeitos da trilha.
fx_busy :: proc(tr, mv: int, start, dur: f32) -> bool {
	for i in 0 ..< nsegs do if seg_blocks(i) && segs[i].track == tr && start < segs[i].start + segs[i].dur - 0.001 && start + dur > segs[i].start + 0.001 do return true
	return fx_hit(tr, mv, start, dur)
}
fx_wall_r :: proc(tr, mv: int, x: f32) -> f32 { // menor início > x (seg ou fx) — parede à direita
	w: f32 = 1e30
	for i in 0 ..< nsegs do if seg_blocks(i) && segs[i].track == tr && segs[i].start >= x - 0.001 && segs[i].start < w do w = segs[i].start
	for k in 0 ..< nfx do if k != mv && fxsegs[k].track == tr && fxsegs[k].start >= x - 0.001 && fxsegs[k].start < w do w = fxsegs[k].start
	return w
}
// menor início de EFEITO ≥ x na trilha. Igual ao fx_wall_r, mas SEM o laço de segmentos —
// para quem já tem o próprio laço de segs e precisa excluir um deles: o `mv` do fx_wall_r
// só filtra efeitos, então não existe forma de pedir "ignore este segmento" por lá.
fx_wall_after :: proc(tr: int, x: f32) -> f32 {
	w: f32 = 1e30
	for k in 0 ..< nfx do if fxsegs[k].track == tr && fxsegs[k].start >= x && fxsegs[k].start < w do w = fxsegs[k].start
	return w
}

// duração que o seg `si` pode assumir sem invadir o vizinho da direita, o clipe de efeito da
// trilha, ou o fim da fonte (`src_left`). `want` é a duração pedida.
// Isto mora fora do draw porque a versão inline chamava `fx_wall_r(track, -1, start+0.001)`:
// o `x - 0.001` de dentro dele cancela o épsilon do chamador, a condição vira
// `segs[i].start >= sg.start` e o PRÓPRIO segmento selecionado entrava como parede. O limite
// dava `start`, a duração dava zero, e qualquer mexida no controle de velocidade encolhia o
// clipe para o piso de 0,05 s — perdendo o trecho editado.
speed_fit_dur :: proc(si: int, want, src_left: f32) -> f32 {
	sg := segs[si]
	limit := f32(1e9)
	for j in 0 ..< nsegs {
		if j == si || segs[j].track != sg.track do continue
		if segs[j].start >= sg.start + 0.001 do limit = min(limit, segs[j].start)
	}
	// os clipes de EFEITO da trilha também são parede: todo o resto do código os trata como
	// ocupantes exclusivos (overlaps_any, fx_free_start, o arrasto) e o check_invariants cobra
	// isso ("efeito sobrepõe o seg"). Sem eles no limite, desacelerar esticava o clipe por
	// cima de um efeito e o build de debug panicava.
	limit = min(limit, fx_wall_after(sg.track, sg.start + 0.001))
	return max(0.05, min(want, limit - sg.start, src_left))
}

fx_free_start :: proc(tr, mv: int, proposed, dur: f32) -> f32 { // empurra p/ a direita até um vão livre
	s := max(0, proposed)
	for _ in 0 ..< nsegs + nfx + 1 {
		hit := f32(-1)
		for i in 0 ..< nsegs do if seg_blocks(i) && segs[i].track == tr && s < segs[i].start+segs[i].dur-0.001 && s+dur > segs[i].start+0.001 { hit = segs[i].start+segs[i].dur; break }
		if hit < 0 do for k in 0 ..< nfx do if k != mv && fxsegs[k].track == tr && s < fxsegs[k].start+fxsegs[k].dur-0.001 && s+dur > fxsegs[k].start+0.001 { hit = fxsegs[k].start+fxsegs[k].dur; break }
		if hit < 0 do break
		s = hit
	}
	return s
}

// invasão/paredes/encaixe são POR TRILHA: segmentos só conflitam com os da MESMA trilha.
// [start, start+dur) invade outro segmento da trilha `tr`? (encostar não conta) — efeitos incluídos
overlaps_any :: proc(tr, moving: int, start, dur: f32) -> bool {
	for i in 0 ..< nsegs {
		if i == moving || !seg_blocks(i) || segs[i].track != tr do continue
		if start < segs[i].start + segs[i].dur - 0.001 && start + dur > segs[i].start + 0.001 do return true
	}
	return fx_hit(tr, -1, start, dur) // vídeo não invade um efeito
}

// seleção múltipla de segmentos: contagem, limpeza, e invasão ignorando TODOS os marcados
seg_marks_count :: proc() -> int { n := 0; for k in 0 ..< nsegs do if seg_marked[k] do n += 1; return n }
seg_clear_marks :: proc() { for k in 0 ..< MAX_SEGS do seg_marked[k] = false }
// [start,start+dur) na trilha tr invade algum segmento NÃO-marcado? (p/ mover o grupo)
overlaps_nonmarked :: proc(tr: int, start, dur: f32) -> bool {
	for i in 0 ..< nsegs {
		// um marcado em trilha TRAVADA não vai se mover — conta como obstáculo (senão
		// o grupo aterrissava em cima dele: sobreposição real na mesma trilha)
		if (seg_marked[i] && !track_locked[segs[i].track]) || !seg_blocks(i) || segs[i].track != tr do continue
		if start < segs[i].start + segs[i].dur - 0.001 && start + dur > segs[i].start + 0.001 do return true
	}
	return fx_hit(tr, -1, start, dur)
}

// fim do vizinho imediatamente à esquerda de x na trilha `tr` (0 se nenhum) — inclui efeitos.
left_wall :: proc(tr, moving: int, x: f32) -> f32 {
	w: f32 = 0
	for i in 0 ..< nsegs {
		if i == moving || !seg_blocks(i) || segs[i].track != tr do continue
		e := segs[i].start + segs[i].dur
		if e <= x + 0.001 && e > w do w = e
	}
	for k in 0 ..< nfx do if fxsegs[k].track == tr { e := fxsegs[k].start + fxsegs[k].dur; if e <= x + 0.001 && e > w do w = e }
	return w
}

// início do vizinho imediatamente à direita de x na trilha `tr` (+inf se nenhum) — inclui efeitos.
right_wall :: proc(tr, moving: int, x: f32) -> f32 {
	w: f32 = 1e30
	for i in 0 ..< nsegs {
		if i == moving || !seg_blocks(i) || segs[i].track != tr do continue
		if segs[i].start >= x - 0.001 && segs[i].start < w do w = segs[i].start
	}
	for k in 0 ..< nfx do if fxsegs[k].track == tr && fxsegs[k].start >= x - 0.001 && fxsegs[k].start < w do w = fxsegs[k].start
	return w
}

// posição livre >= proposed p/ um clipe de `dur` na trilha `tr`: empurra p/ a direita enquanto invadir
// (segmentos E efeitos — o vídeo não pode cair em cima de um efeito)
free_start :: proc(tr, moving: int, proposed, dur: f32) -> f32 {
	s := max(0, proposed)
	for _ in 0 ..< nsegs + nfx + 1 {
		hit := f32(-1)
		for i in 0 ..< nsegs {
			if i == moving || !seg_blocks(i) || segs[i].track != tr do continue
			if s < segs[i].start + segs[i].dur - 0.001 && s + dur > segs[i].start + 0.001 { hit = segs[i].start + segs[i].dur; break }
		}
		if hit < 0 do for k in 0 ..< nfx do if fxsegs[k].track == tr && s < fxsegs[k].start+fxsegs[k].dur-0.001 && s+dur > fxsegs[k].start+0.001 { hit = fxsegs[k].start + fxsegs[k].dur; break }
		if hit < 0 do break
		s = hit // vai pro fim do que invadiu
	}
	return s
}

timeline_dur :: proc() -> f32 {
	d: f32 = 0
	for i in 0 ..< nsegs {
		if seg_ready(i) do d = max(d, segs[i].start + segs[i].dur)
	}
	return d
}

// ---------- modo ASSERT de invariantes (debug) ----------
// Valida 1x por frame as regras estruturais que o resto do código ASSUME (mantidas
// por mover/aparar/cortar/colar/remover): corrupção silenciosa vira crash com dump
// da timeline e mensagem NA HORA em que acontece, não 20 features depois. Liga com
// -define:INVARIANTS=true (o build -debug já vem ligado); no release a chamada
// desaparece via @(disabled). Custo: O(nsegs²) com nsegs<=64 — desprezível.
INVARIANTS :: #config(INVARIANTS, ODIN_DEBUG)

inv_bad :: proc(v: f32) -> bool { return v != v || abs(v) > 1e18 } // NaN ou ±inf

// a linha de segmento do .ovp descreve um seg que o resto do programa aguenta?
// O `.ovp` é texto: pode vir truncado, editado à mão, ou de uma sessão com mais mídias do que
// MAX_CLIPS (import_media devolve -1 e nclips para de crescer, mas as linhas de seg continuam
// citando os índices antigos). E `src` vira índice de `clips` dentro de seg_ready/seg_src sem
// nenhuma checagem adiante — um valor fora da faixa derrubava o processo no primeiro frame,
// levando junto o projeto que ainda não tinha sido salvo. As condições são as mesmas que o
// check_invariants cobra de um seg vivo; recusar a linha inteira é melhor que inventar uma
// fonte e cair depois, longe daqui.
seg_line_ok :: proc(src, start, in_off, dur: f32) -> bool {
	if inv_bad(src) || int(src) < 0 || int(src) >= nclips do return false
	if inv_bad(start) || inv_bad(in_off) || inv_bad(dur) do return false
	return dur > 0.01 && in_off >= -0.001
}

inv_fail :: proc(msg: string, args: ..any) -> ! {
	fmt.eprintfln("---- INVARIANTE VIOLADA ----")
	fmt.eprintfln("nsegs=%d nclips=%d nfx=%d g_nv=%d g_na=%d playhead=%.3f playing=%v play_clip=%d selected=%d drag_clip=%d drag=%v",
		nsegs, nclips, nfx, g_nv, g_na, st.playhead, st.playing, play_clip, selected, drag_clip, st.drag)
	for i in 0 ..< nsegs {
		s := segs[i]
		fmt.eprintfln("  seg %d: src=%d track=%d start=%.3f dur=%.3f in_off=%.3f speed=%.2f vol=%.2f aonly=%v ready=%v",
			i, s.src, s.track, s.start, s.dur, s.in_off, s.speed, s.vol, s.aonly,
			s.src >= 0 && s.src < nclips && seg_ready(i))
	}
	for k in 0 ..< nfx {
		f := fxsegs[k]
		fmt.eprintfln("  fx %d: kind=%d track=%d start=%.3f dur=%.3f", k, f.kind, f.track, f.start, f.dur)
	}
	fmt.panicf(msg, ..args)
}

@(disabled=!INVARIANTS)
check_invariants :: proc() {
	// contadores e índices globais dentro das faixas
	if nsegs < 0 || nsegs > MAX_SEGS do inv_fail("nsegs fora da faixa: %d", nsegs)
	if nclips < 0 || nclips > MAX_CLIPS do inv_fail("nclips fora da faixa: %d", nclips)
	if nfx < 0 || nfx > MAX_FX do inv_fail("nfx fora da faixa: %d", nfx)
	if seg_clipbrd_n < 0 || seg_clipbrd_n > MAX_SEGS do inv_fail("clipboard fora da faixa: %d", seg_clipbrd_n)
	if g_nv < 1 || g_nv > MAXV do inv_fail("g_nv fora da faixa: %d", g_nv)
	if g_na < 1 || g_na > MAXA do inv_fail("g_na fora da faixa: %d", g_na)
	if inv_bad(st.playhead) || st.playhead < -0.001 do inv_fail("playhead inválido: %v", st.playhead)
	if selected < -1 || selected >= nsegs do inv_fail("selected fora da faixa: %d (nsegs=%d)", selected, nsegs)
	if drag_clip < -1 || drag_clip >= nsegs do inv_fail("drag_clip fora da faixa: %d (nsegs=%d)", drag_clip, nsegs)
	if sel_trans < -1 || sel_trans >= nsegs do inv_fail("sel_trans fora da faixa: %d (nsegs=%d)", sel_trans, nsegs)
	if play_clip < -1 || play_clip >= nsegs do inv_fail("play_clip fora da faixa: %d (nsegs=%d)", play_clip, nsegs)
	if bin_sel < -1 || bin_sel >= nclips do inv_fail("bin_sel fora da faixa: %d (nclips=%d)", bin_sel, nclips)
	if src_preview < -1 || src_preview >= nclips do inv_fail("src_preview fora da faixa: %d (nclips=%d)", src_preview, nclips)
	// o relógio-mestre precisa de fonte pronta e com áudio
	if play_clip >= 0 {
		if !seg_ready(play_clip) do inv_fail("play_clip %d com fonte não-pronta", play_clip)
		if !seg_src(play_clip).src_audio do inv_fail("play_clip %d é o relógio mas a fonte não tem áudio", play_clip)
	}
	for i in 0 ..< nsegs {
		s := segs[i]
		if s.src < 0 || s.src >= nclips do inv_fail("seg %d: src %d fora da faixa (nclips=%d)", i, s.src, nclips)
		if clips[s.src].closed do inv_fail("seg %d aponta p/ mídia removida (tombstone %d)", i, s.src)
		if inv_bad(s.start) || inv_bad(s.dur) || inv_bad(s.in_off) || inv_bad(s.speed) || inv_bad(s.vol) || inv_bad(s.fade_in) || inv_bad(s.fade_out) {
			inv_fail("seg %d com NaN/inf (start=%v dur=%v in_off=%v speed=%v)", i, s.start, s.dur, s.in_off, s.speed)
		}
		if s.start < -0.001 do inv_fail("seg %d: start negativo %.3f", i, s.start)
		if s.dur <= 0.01 do inv_fail("seg %d: dur %.4f (vazio/negativo)", i, s.dur)
		if s.in_off < -0.001 do inv_fail("seg %d: in_off negativo %.3f", i, s.in_off)
		if s.speed < 0 do inv_fail("seg %d: speed negativa %.3f", i, s.speed)
		if s.track < 0 || s.track >= MAXTRACKS do inv_fail("seg %d: trilha %d fora da faixa", i, s.track)
		// áudio (mídia só-áudio ou áudio separado) vive nas trilhas de áudio; vídeo nas de vídeo
		al := clips[s.src].is_audio || s.aonly
		if al && !is_audio_track(s.track) do inv_fail("seg %d é áudio mas está na trilha de vídeo %d", i, s.track)
		if !al && is_audio_track(s.track) do inv_fail("seg %d é vídeo mas está na trilha de áudio %d", i, s.track)
		// o trecho recortado cabe na fonte (imagem/texto esticam livre — sem fim real)
		if !clips[s.src].is_img && !clips[s.src].is_text && media_ready(s.src) && seg_src_out(i) > clips[s.src].dur + 0.05 {
			inv_fail("seg %d consome além do fim da fonte: out=%.3f > dur=%.3f", i, seg_src_out(i), clips[s.src].dur)
		}
	}
	// segmentos de uma mesma trilha NUNCA se sobrepõem (invariante do mover/aparar/colar/drop)
	for i in 0 ..< nsegs do for j in i + 1 ..< nsegs {
		if segs[i].track != segs[j].track do continue
		ov := min(segs[i].start + segs[i].dur, segs[j].start + segs[j].dur) - max(segs[i].start, segs[j].start)
		if ov > 0.005 do inv_fail("segs %d e %d sobrepõem %.3fs na trilha %d", i, j, ov, segs[i].track)
	}
	// efeitos: trilha de vídeo válida e exclusividade de espaço (fx×fx e fx×seg)
	for k in 0 ..< nfx {
		f := fxsegs[k]
		if inv_bad(f.start) || inv_bad(f.dur) do inv_fail("fx %d com NaN/inf", k)
		if f.dur <= 0.01 do inv_fail("fx %d: dur %.4f", k, f.dur)
		if f.track < 0 || f.track >= MAXV do inv_fail("fx %d: trilha %d fora da faixa de vídeo", k, f.track)
		for j in k + 1 ..< nfx {
			if fxsegs[j].track != f.track do continue
			ov := min(f.start + f.dur, fxsegs[j].start + fxsegs[j].dur) - max(f.start, fxsegs[j].start)
			if ov > 0.005 do inv_fail("efeitos %d e %d sobrepõem %.3fs na trilha %d", k, j, ov, f.track)
		}
		for i in 0 ..< nsegs {
			if segs[i].track != f.track do continue
			ov := min(f.start + f.dur, segs[i].start + segs[i].dur) - max(f.start, segs[i].start)
			if ov > 0.005 do inv_fail("efeito %d sobrepõe o seg %d em %.3fs na trilha %d", k, i, ov, f.track)
		}
	}
}

// ---- copiar/colar segmentos (Ctrl+C/X/V/D) ----
// a área de transferência guarda VALORES de Seg (struct puro, sem recursos):
// sobrevive a remoção/undo e traz junto transform/volume/fades/velocidade/efeitos.
// `start` fica absoluto; o colar desloca o CONJUNTO p/ o destino (posições
// relativas preservadas). A mídia-fonte é validada na hora de colar.
seg_clipbrd:   [MAX_SEGS]Seg
seg_clipbrd_n: int

// copia o grupo marcado (se houver) ou o segmento selecionado; retorna quantos
copy_segs :: proc() -> int {
	n := 0
	if seg_marks_count() >= 1 {
		// 1 marcado também entra aqui: senão um clipe marcado + outro selecionado
		// copiava o selecionado (o grupo de 1 era ignorado)
		for i in 0 ..< nsegs do if seg_marked[i] && seg_ready(i) { seg_clipbrd[n] = segs[i]; n += 1 }
	} else if selected >= 0 && selected < nsegs && seg_ready(selected) {
		seg_clipbrd[0] = segs[selected]
		n = 1
	}
	if n > 0 {
		seg_clipbrd_n = n
		if n == 1 do set_toast("Clipe copiado — Ctrl+V cola no playhead")
		else do set_toast(rl.TextFormat("%d clipes copiados — Ctrl+V cola no playhead", n))
	} else {
		set_toast("Selecione um clipe na timeline p/ copiar")
	}
	return n
}

// cola a área de transferência com o início do conjunto em `at` (cada clipe na
// sua trilha de origem; empurrado p/ a direita se invadir — nunca sobrepõe)
paste_segs :: proc(at: f32) {
	if seg_clipbrd_n == 0 { set_toast("Nada copiado ainda — Ctrl+C copia o clipe selecionado"); return }
	base := f32(1e30)
	for k in 0 ..< seg_clipbrd_n do base = min(base, seg_clipbrd[k].start)
	delta := at - base
	first := -1; pasted := 0; dead := 0; locked := 0
	for k in 0 ..< seg_clipbrd_n {
		it := seg_clipbrd[k]
		// a mídia-fonte pode ter sido removida do bin depois do copiar
		if it.src < 0 || it.src >= nclips || clips[it.src].closed || intrinsics.atomic_load(&clips[it.src].failed) { dead += 1; continue }
		// a trilha guardada no clipboard pode ter sido REMOVIDA depois do copiar (o clipboard
		// não entra no Snapshot de undo). Sem clampar, o segmento nascia com track >= g_nv:
		// track_row virava negativo (desenhado por cima da trilha do topo), o preview e o
		// export de VÍDEO iteram 0..<g_nv e o ignoravam, mas o laço de áudio pega todos —
		// o clipe saía do arquivo final só com o som.
		tr := is_audio_track(it.track) ? clamp(it.track, MAXV, MAXV + g_na - 1) : clamp(it.track, 0, g_nv - 1)
		if track_locked[tr] { locked += 1; continue }
		ni := add_seg(it.src, 0, it.in_off, it.dur, tr)
		if ni < 0 do break // timeline lotada (add_seg já avisou)
		s := it
		s.track = tr
		s.start = free_start(tr, ni, max(0, it.start + delta), it.dur)
		segs[ni] = s
		if first < 0 do first = ni
		pasted += 1
	}
	if pasted > 0 {
		seg_clear_marks()
		if pasted > 1 do for i in first ..< nsegs do seg_marked[i] = true // grupo colado já sai marcado (move junto)
		selected = first; sel_trans = -1; bin_sel = -1
		if pasted == 1 do set_toast("Clipe colado")
		else do set_toast(rl.TextFormat("%d clipes colados", pasted))
	} else if dead > 0 {
		set_toast("A mídia copiada foi removida do editor")
	} else if locked > 0 {
		set_toast("Trilha bloqueada")
	}
}

// recorta (copia + remove). Deixa o vão (sem ripple): recortar p/ colar em outro
// lugar não deve deslizar o resto da trilha.
cut_segs :: proc() {
	n := copy_segs()
	if n == 0 do return
	if seg_marks_count() > 1 {
		// só remove o que FOI copiado (seg_ready): um marcado com mídia ainda carregando
		// não entra no clipboard — removê-lo seria perdê-lo (não voltaria no Ctrl+V)
		for k := nsegs - 1; k >= 0; k -= 1 do if seg_marked[k] && seg_ready(k) do remove_seg(k, false)
		seg_clear_marks(); selected = -1
	} else if selected >= 0 && seg_ready(selected) {
		remove_seg(selected, false)
	}
	if n == 1 do set_toast("Clipe recortado — Ctrl+V cola no playhead")
	else do set_toast(rl.TextFormat("%d clipes recortados — Ctrl+V cola no playhead", n))
}

// duplica o selecionado (ou grupo) logo após o fim do conjunto, na mesma trilha
duplicate_segs :: proc() {
	if copy_segs() == 0 do return
	e := f32(0)
	for k in 0 ..< seg_clipbrd_n do e = max(e, seg_clipbrd[k].start + seg_clipbrd[k].dur)
	paste_segs(e)
}

// segmento que se comporta como ÁUDIO: mídia só-áudio (mp3/wav) OU áudio separado
// do vídeo (aonly). Preview/transform/efeitos/transições ignoram esses segmentos.
seg_audio_like :: proc(si: int) -> bool {
	return si >= 0 && si < nsegs && (seg_src(si).is_audio || segs[si].aonly)
}

// SEPARAR ÁUDIO (estilo NLE): cria um segmento só-áudio (aonly) numa trilha de
// áudio livre, em sincronia com o vídeo (mesmo start/in_off/dur/speed), move os
// fades/volume de áudio p/ ele e SILENCIA o vídeo original. Desfazível (só segs).
detach_audio :: proc(si: int) {
	if si < 0 || si >= nsegs || !seg_ready(si) do return
	sg := segs[si]
	c := seg_src(si)
	if sg.aonly || c.is_audio { set_toast("Este clipe já é só áudio"); return }
	if !c.has_audio { set_toast("Este clipe não tem áudio"); return }
	tr := -1
	for t in MAXV ..< MAXV + g_na { // 1ª trilha de áudio com espaço livre no trecho
		if track_locked[t] do continue
		if !overlaps_any(t, -1, sg.start, sg.dur) { tr = t; break }
	}
	if tr < 0 do tr = add_audio_track() // nenhuma livre: cria uma nova trilha de áudio embaixo
	if tr < 0 { set_toast("Sem espaço livre nas trilhas de áudio"); return }
	ni := add_seg(sg.src, sg.start, sg.in_off, sg.dur, tr)
	if ni < 0 do return
	na := &segs[ni]
	na.aonly = true
	na.vol = sg.vol; na.fade_in = sg.fade_in; na.fade_out = sg.fade_out
	na.speed = sg.speed <= 0 ? 1 : sg.speed
	segs[si].muted = true // o som agora vem do segmento separado
	segs[si].fade_in = 0; segs[si].fade_out = 0
	seg_clear_marks()
	selected = ni; sel_trans = -1; bin_sel = -1
	set_toast(rl.TextFormat("Áudio separado p/ a trilha A%d", tr - MAXV + 1))
}

segs_ready :: proc() -> int {
	n := 0
	for i in 0 ..< nsegs do if seg_ready(i) do n += 1
	return n
}

// segmentos cuja mídia ainda está IMPORTANDO (probe em curso). Mídia que FALHOU não conta:
// ela nunca vai ficar pronta e o usuário já viu o erro no bin, então esperar seria eterno.
// Usado para barrar o export: os laços de export_build_args pulam `!seg_ready(i)`, e o único
// aborto é "nenhum input" — com um segmento pronto no meio de dez importando, o export ia
// até 100% e entregava um arquivo com PRETO no lugar dos clipes que faltaram.
segs_importing :: proc() -> int {
	n := 0
	for i in 0 ..< nsegs do if !seg_ready(i) && !intrinsics.atomic_load(&clips[segs[i].src].failed) do n += 1
	return n
}

// tira UM segmento da timeline (a mídia continua no bin). Compacta o array, então
// conserta os índices globais que apontam para segmentos (deslocam ao remover).
// ripple=true (padrão) fecha o buraco; false deixa o vão (segurar Alt ao remover)
remove_seg :: proc(si: int, ripple := true) {
	if si < 0 || si >= nsegs do return
	src := seg_src(si)
	if src.has_audio do rl.PauseMusicStream(src.music)
	name := src.name
	rs := segs[si].start // início e duração do removido, p/ o ripple
	rd := segs[si].dur
	rt := segs[si].track // ripple só desloca a MESMA trilha
	for k := si; k < nsegs - 1; k += 1 { segs[k] = segs[k + 1]; seg_marked[k] = seg_marked[k + 1] }
	seg_marked[nsegs - 1] = false // limpa o slot que sobra após a compactação
	nsegs -= 1
	fix :: proc(idx: ^int, removed: int) {
		if idx^ == removed do idx^ = -1
		else if idx^ > removed do idx^ -= 1
	}
	fix(&play_clip, si); fix(&selected, si); fix(&drag_clip, si); fix(&sel_trans, si)
	if ripple {
		// fecha o buraco — tudo à direita do removido NA MESMA TRILHA desliza `rd` p/ a esquerda
		for k in 0 ..< nsegs do if segs[k].track == rt && segs[k].start > rs + 0.001 do segs[k].start -= rd
		// os clipes de EFEITO da trilha deslizam junto — senão um segmento escorregava
		// p/ cima de um efeito (sobreposição que nenhum arrasto permite criar)
		for k in 0 ..< nfx do if fxsegs[k].track == rt && fxsegs[k].start > rs + 0.001 do fxsegs[k].start -= rd
		// o playhead é TEMPO GLOBAL, não por trilha: recuá-lo aqui pulava o conteúdo
		// das outras trilhas (apagar 10s em V2 com o cursor em 30s em V1 jogava p/ 20s).
		// O seek_global abaixo reposiciona A/V no mesmo instante; o que escorregou
		// nesta trilha passa por baixo do cursor, o resto não se mexe.
	}
	st.playing = false
	seek_global(st.playhead)
	set_toast(rl.TextFormat(ripple ? "%s removido" : "%s removido (deixou vão)", cs(name)))
}

alt_down :: proc() -> bool { return rl.IsKeyDown(.LEFT_ALT) || rl.IsKeyDown(.RIGHT_ALT) }

// divide o segmento `a` no tempo `t` (absoluto da timeline). true = cortou.
// a esquerda encurta até o corte; a direita vira um novo segmento da mesma fonte.
split_seg_at :: proc(a: int, t: f32) -> bool {
	if a < 0 || a >= nsegs do return false
	off := t - segs[a].start // ponto do corte, relativo ao início do segmento
	if off <= 0.05 || off >= segs[a].dur - 0.05 { set_toast("Muito perto da borda para dividir"); return false }
	// a fonte consumida pela metade esquerda é off*speed (off é tempo de timeline)
	ri := add_seg(segs[a].src, t, segs[a].in_off + off * seg_speed(a), segs[a].dur - off, segs[a].track)
	if ri < 0 do return false
	// as duas metades herdam volume/mudo; o fade-in fica na esquerda, o fade-out na
	// direita — a borda do corte (interna) não ganha fade
	segs[ri].vol = segs[a].vol; segs[ri].muted = segs[a].muted
	segs[ri].fade_in = 0; segs[ri].fade_out = segs[a].fade_out
	segs[ri].scale = segs[a].scale; segs[ri].px = segs[a].px; segs[ri].py = segs[a].py // transform herdado
	segs[ri].rot = segs[a].rot; segs[ri].opacity = segs[a].opacity; segs[ri].speed = segs[a].speed
		segs[ri].crop_x = segs[a].crop_x; segs[ri].crop_y = segs[a].crop_y // RECORTE herdado pelas 2 metades
		segs[ri].crop_w = segs[a].crop_w; segs[ri].crop_h = segs[a].crop_h // (senão a direita perdia o recorte)
		segs[ri].crop2_x = segs[a].crop2_x; segs[ri].crop2_y = segs[a].crop2_y // ZOOM ANIMADO herdado
		segs[ri].crop2_w = segs[a].crop2_w; segs[ri].crop2_h = segs[a].crop2_h
		segs[ri].zoom_anim = segs[a].zoom_anim
		if segs[a].zoom_anim { // remapeia p/ o movimento continuar CONTÍNUO no corte
			cx, cy, cw, ch := seg_crop_at(a, t) // região exatamente no ponto do corte
			segs[a].crop2_x = cx; segs[a].crop2_y = cy; segs[a].crop2_w = cw; segs[a].crop2_h = ch // esq termina aqui
			segs[ri].crop_x = cx; segs[ri].crop_y = cy; segs[ri].crop_w = cw; segs[ri].crop_h = ch // dir começa aqui
		}
		segs[ri].vfin = 0; segs[ri].vfout = segs[a].vfout // fade preto: entrada esq, saída dir
		// SÓ-ÁUDIO herdado: sem isto, dividir um "áudio separado" criava um segmento de
		// VÍDEO numa trilha de áudio (violava o invariante e cobria o preview inteiro)
		segs[ri].aonly = segs[a].aonly
		// efeitos por segmento herdados pelas 2 metades (cor, vinheta, bulge/wobble) —
		// senão a metade direita perdia a correção de cor/distorção no corte
		segs[ri].bulge = segs[a].bulge; segs[ri].bulge_x = segs[a].bulge_x
		segs[ri].bulge_y = segs[a].bulge_y; segs[ri].bulge_r = segs[a].bulge_r
		segs[ri].wobble = segs[a].wobble; segs[ri].wobble_speed = segs[a].wobble_speed
		segs[ri].fx_bright = segs[a].fx_bright; segs[ri].fx_contrast = segs[a].fx_contrast
		segs[ri].fx_satur = segs[a].fx_satur; segs[ri].fx_look = segs[a].fx_look
		segs[ri].fx_vignette = segs[a].fx_vignette; segs[ri].fx_temp = segs[a].fx_temp
	segs[a].dur = off
	segs[a].fade_out = 0; segs[a].vfout = 0 // o fade preto de saída foi p/ a metade da direita
	// as duas metades ficaram menores que o original: o fade herdado pode não caber mais
	clamp_fades(&segs[a]); clamp_fades(&segs[ri])
	return true
}

// divide TODOS os clipes que cruzam o playhead, em todas as trilhas (como qualquer NLE),
// pulando trilhas bloqueadas. (atalho: S). split_seg_at acrescenta a metade direita no fim do
// array, então iterar sobre o count ORIGINAL evita re-dividir os novos pedaços.
split_at_playhead :: proc() {
	n := 0
	orig := nsegs
	for i in 0 ..< orig {
		if !seg_ready(i) || track_locked[segs[i].track] do continue
		if st.playhead > segs[i].start + 0.05 && st.playhead < segs[i].start + segs[i].dur - 0.05 {
			if split_seg_at(i, st.playhead) do n += 1
		}
	}
	if n == 0 { set_toast("Nada sob o playhead para dividir"); return }
	bin_sel = -1
	set_toast(n == 1 ? "Clipe dividido" : rl.TextFormat("%d clipes divididos", n))
}

// encaixa o início do segmento nas bordas de outros segmentos DA MESMA TRILHA / início / playhead.
// moving = índice do segmento sendo movido (-1 quando é um item novo do bin).
snap_start :: proc(tr, moving: int, proposed: f32, dur: f32) -> f32 {
	thr := SNAP_PX / pps()
	result := proposed
	bestd := thr
	pts: [2 * MAX_SEGS + 2 * MAX_FX + 2]f32
	n := 0
	pts[n] = 0; n += 1
	pts[n] = st.playhead; n += 1
	// bordas de TODOS os clipes (qualquer trilha) — guia de alinhamento entre trilhas ao arrastar
	for i in 0 ..< nsegs {
		if i == moving || !seg_blocks(i) do continue // importando também encaixa (é obstáculo)
		pts[n] = segs[i].start; n += 1
		pts[n] = segs[i].start + segs[i].dur; n += 1
	}
	// efeitos também são parede: sem as bordas aqui o snap alinhava num ponto que
	// overlaps_any rejeitava em seguida (o clipe "recusava" a guia)
	for k in 0 ..< nfx {
		pts[n] = fxsegs[k].start; n += 1
		pts[n] = fxsegs[k].start + fxsegs[k].dur; n += 1
	}
	for k in 0 ..< n {
		p := pts[k]
		if d := math.abs(proposed - p);         d < bestd { bestd = d; result = p;       snap_line = p }
		if d := math.abs(proposed + dur - p);   d < bestd { bestd = d; result = p - dur; snap_line = p }
	}
	return max(0, result)
}

// encaixa UMA borda (aparo) nas bordas de todos os clipes / início / playhead — mesmos pontos
// do snap_start, mas para um ponto só (o snap_start move o bloco inteiro; aqui a outra borda
// fica parada). Acende a guia de alinhamento entre trilhas, igual ao mover.
snap_edge :: proc(moving: int, proposed: f32) -> f32 {
	thr := SNAP_PX / pps()
	result := proposed
	bestd := thr
	pts: [2 * MAX_SEGS + 2 * MAX_FX + 2]f32
	n := 0
	pts[n] = 0; n += 1
	pts[n] = st.playhead; n += 1
	for i in 0 ..< nsegs {
		if i == moving || !seg_blocks(i) do continue
		pts[n] = segs[i].start; n += 1
		pts[n] = segs[i].start + segs[i].dur; n += 1
	}
	for k in 0 ..< nfx {
		pts[n] = fxsegs[k].start; n += 1
		pts[n] = fxsegs[k].start + fxsegs[k].dur; n += 1
	}
	for k in 0 ..< n {
		p := pts[k]
		if d := math.abs(proposed - p); d < bestd { bestd = d; result = p; snap_line = p }
	}
	return result
}

// segmento de VÍDEO de topo que contém t (-1 se nenhum) — vence no preview e nos cliques.
// Ignora clipes só-áudio (não têm imagem); trilhas de áudio nunca aparecem no preview.
seg_at :: proc(t: f32) -> int {
	best := -1
	for i in 0 ..< nsegs {
		if !seg_ready(i) || seg_src(i).is_audio || segs[i].aonly do continue
		if segs[i].track < MAXV && track_hidden[segs[i].track] do continue // olho fechado: não vence o preview
		if t < segs[i].start || t >= segs[i].start + segs[i].dur do continue
		if best < 0 || segs[i].track > segs[best].track do best = i
	}
	return best
}

// segmento que dá o RELÓGIO de áudio (master) em t: prefere áudio de trilha de VÍDEO
// (o "principal"); só cai numa trilha de áudio se não houver áudio de vídeo na região.
// Assim a música (trilha de áudio) toca como SECUNDÁRIO (mix) sem roubar o relógio.
audio_seg_at :: proc(t: f32) -> int {
	best := -1
	for i in 0 ..< nsegs {
		if !seg_ready(i) || t < segs[i].start || t >= segs[i].start + segs[i].dur do continue
		if !seg_src(i).src_audio || segs[i].muted || track_muted[segs[i].track] do continue
		if is_audio_track(segs[i].track) do continue // trilha de áudio = secundário, não master
		if best < 0 || segs[i].track > segs[best].track do best = i
	}
	if best >= 0 do return best
	// nenhum áudio de vídeo: aí sim uma trilha de áudio vira o relógio (timeline só-música)
	for i in 0 ..< nsegs {
		if !seg_ready(i) || t < segs[i].start || t >= segs[i].start + segs[i].dur do continue
		if !seg_src(i).src_audio || segs[i].muted || track_muted[segs[i].track] || !is_audio_track(segs[i].track) do continue
		if best < 0 || segs[i].track > segs[best].track do best = i
	}
	return best
}

// segmento na trilha `t` que contém o tempo `time` (-1 se nenhum)
seg_on_track_at :: proc(t: int, time: f32) -> int {
	for i in 0 ..< nsegs {
		if seg_ready(i) && segs[i].track == t && time >= segs[i].start && time < segs[i].start + segs[i].dur do return i
	}
	return -1
}

// clipe de SAÍDA de uma transição do segmento bi = o adjacente que termina onde bi começa
// (mesma trilha). -1 se bi começa "solto" (sem clipe encostado à esquerda) -> sem transição.
trans_prev :: proc(bi: int) -> int {
	if bi < 0 || bi >= nsegs do return -1
	for i in 0 ..< nsegs {
		if i == bi || !seg_ready(i) || segs[i].track != segs[bi].track do continue
		if math.abs((segs[i].start + segs[i].dur) - segs[bi].start) < 0.02 do return i // A termina onde B começa
	}
	return -1
}

// duração máxima de transição p/ o segmento bi (modelo CENTRADO no corte: metade `D/2`
// em cada clipe). NÃO exige mais handle (folga na fonte): quando um lado não tem footage
// além da borda, o preview/export CONGELAM o frame da borda durante a mistura (o efeito se
// vira sozinho). Limitado só pela duração dos 2 clipes e um teto de 1.5s por lado (D=3s).
// segmento colado à DIREITA de ai na mesma trilha (o dono da transição do outro corte de ai)
trans_next :: proc(ai: int) -> int {
	if ai < 0 || ai >= nsegs do return -1
	for i in 0 ..< nsegs {
		if i == ai || !seg_ready(i) || segs[i].track != segs[ai].track do continue
		if math.abs(segs[i].start - (segs[ai].start + segs[ai].dur)) < 0.02 do return i
	}
	return -1
}
// metade da transição do corte de `i`, sem passar pelo seg_trans de propósito: ele chamaria
// trans_max de volta e um corte pediria o do outro em recursão infinita. Mas o campo cru
// SOZINHO não serve: `.trans` não é zerado quando o vizinho da esquerda some, então um corte
// que já não existe continuava cobrando espaço e encolhia (ou apagava) o dissolver do corte
// seguinte. Aqui exige o corte existir e aplica os tetos que dependem só de `i` — os do
// vizinho ficam de fora, que é justamente o que evita a recursão.
trans_half_raw :: proc(i: int) -> f32 {
	if i < 0 || i >= nsegs || segs[i].trans <= 0.001 || seg_speed(i) != 1 do return 0
	if trans_prev(i) < 0 do return 0 // sem clipe à esquerda não há corte: não gasta nada
	return min(segs[i].trans/2, segs[i].dur, f32(1.5))
}
trans_max :: proc(bi: int) -> f32 {
	a := trans_prev(bi)
	if a < 0 do return 0
	if seg_speed(a) != 1 || seg_speed(bi) != 1 do return 0 // v1: dissolver não combina com velocidade alterada
	half := min(segs[a].dur, segs[bi].dur, f32(1.5)) // teto de 1.5s por lado; cabe no clipe mais curto
	// a janela é CENTRADA no corte, então a metade que entra em cada clipe divide espaço com
	// a metade da transição do OUTRO corte dele. Sem descontar, dois cortes seguidos com
	// dissolver (clipe do meio com menos de 1s, o padrão D=1s já basta) sobrepunham as
	// janelas dentro dele — e o trans_overlap só devolve UMA janela por instante, então o
	// clipe do meio sumia do preview.
	half = min(half, segs[a].dur - trans_half_raw(a), segs[bi].dur - trans_half_raw(trans_next(bi)))
	return max(0, half * 2)
}
// transição válida do segmento bi (clampada). 0 se speed!=1 (v1 não combina os dois).
seg_trans :: proc(bi: int) -> f32 {
	if segs[bi].trans <= 0.001 || seg_speed(bi) != 1 do return 0
	return clamp(segs[bi].trans, 0, trans_max(bi))
}

// explica POR QUE o dissolver foi recusado no corte de bi (só sobra motivo estrutural agora
// que a folga deixou de ser exigida: sem clipe adjacente, velocidade alterada, ou dur zero).
trans_deny_toast :: proc(bi: int) {
	a := trans_prev(bi)
	if a < 0 { set_toast("Encoste este clipe em outro na mesma trilha p/ dissolver"); return }
	if seg_speed(a) != 1 || seg_speed(bi) != 1 { set_toast("Dissolver não combina com velocidade alterada"); return }
	set_toast("Clipes muito curtos p/ dissolver")
}

// atualiza a textura de CADA trilha de vídeo sob o playhead (compositing multi-trilha):
// cada fonte decodifica seu frame; draw_preview desenha todas com seus transforms.
show_playhead_frame :: proc() {
	pt := prof_beg(.Video); defer prof_end(.Video, pt)
	vt := view_t() // no fim da timeline, o último frame em vez de nada
	for t in 0 ..< g_nv {
		if track_hidden[t] do continue // trilha oculta: não decodifica (não aparece)
		// transição centrada no corte: decodifica AMBOS os clipes no seu tempo de fonte
		// (o que SAI passa do out-point = pós-roll; o que ENTRA fica antes de in_off =
		// pré-roll). Quando não há footage sobrando, o clamp CONGELA o frame da borda —
		// o efeito funciona sem exigir aparo. Instantâneo p/ cache; streaming é aproximado.
		tb := trans_overlap(t, vt)
		if tb >= 0 {
			a := trans_prev(tb)
			frz :: proc(c: ^Clip, sec: f32) { clip_frame(c, clamp(sec, 0, max(0, c.dur - 1.0/cfps_of(c)))) }
			// STREAMING também decodifica (clip_frame lida com respawn/EOF): o que ENTRA
			// respawna no início do overlap, quando a camada dele ainda é transparente —
			// o hitch fica invisível e ele chega pronto no fim (antes congelava um frame
			// velho durante o crossfade e ainda respawnava DEPOIS da transição).
			// Guardas de textura (1 textura não serve 2 tempos — era o pisca):
			//  - mesma fonte nos 2 lados (dissolve num corte interno): só o que ENTRA
			//    decodifica; num corte contíguo os tempos são idênticos, sem perda.
			//  - fonte de trilha mais BAIXA sob o playhead (seg_is_dup): o dono decide.
			if a >= 0 && segs[a].src != segs[tb].src && !seg_is_dup(a) {
				frz(seg_src(a), segs[a].in_off + (vt - segs[a].start))
			}
			if !seg_is_dup(tb) do frz(seg_src(tb), segs[tb].in_off + (vt - segs[tb].start))
		} else {
			i := seg_on_track_at(t, vt)
			if i >= 0 {
				// mesma fonte já decodificando numa trilha mais baixa: este seg usa a
				// vista dup (textura própria) — 1 clipe não serve 2 tempos ao mesmo tempo
				if seg_is_dup(i) do dup_frame(i, seg_local(i, vt))
				else do clip_frame(seg_src(i), seg_local(i, vt))
			}
		}
	}
}

// linha (de cima p/ baixo) do lane da trilha `t`, contando só as VISÍVEIS: vídeo em cima
// (V-topo..V1, invertido), áudio embaixo (A1..A_n). Vídeo t ocupa a linha (g_nv-1-t); áudio
// (índice MAXV+a) ocupa a linha (g_nv+a).
track_row :: proc(t: int) -> int { return t < MAXV ? (g_nv - 1 - t) : (g_nv + (t - MAXV)) }
// trilha destino ao mover `t` por `dr` LINHAS na tela (dr > 0 = para baixo). Os dois espaços
// de índice têm orientações OPOSTAS: no vídeo track_row é g_nv-1-t (índice maior = linha mais
// ALTA), no áudio é g_nv+(t-MAXV) (índice maior = linha mais BAIXA). Somar o mesmo delta de
// ÍNDICE nos dois — o que o arrasto em grupo fazia — descia o vídeo e SUBIA o áudio no mesmo
// gesto. Não clampa: quem chama decide se o destino cabe (in_range).
track_shift_rows :: proc(t, dr: int) -> int { return is_audio_track(t) ? t + dr : t - dr }
// y do topo da trilha: soma as alturas das linhas ACIMA (alturas são por trilha, não uniformes)
track_y :: proc(t: int) -> f32 {
	y := g_lanes_top
	row := track_row(t)
	for r in 0 ..< row do y += th(track_of_row(r)) + g_track_gap
	return y
}
// trilha sob a coordenada y (usado no drop/arraste vertical). Percorre acumulando as alturas;
// fora da faixa clampa na 1ª/última linha (mesmo comportamento do clamp antigo).
track_at_y :: proc(y: f32) -> int {
	nrows := g_nv + g_na
	yy := g_lanes_top
	for r in 0 ..< nrows {
		h := th(track_of_row(r)) + g_track_gap
		if y < yy + h do return track_of_row(r)
		yy += h
	}
	return track_of_row(nrows - 1)
}
// ajusta a trilha alvo ao TIPO da mídia: áudio só em trilha de áudio; vídeo/imagem só em vídeo
track_for_media :: proc(src, t: int) -> int {
	if clips[src].is_audio do return is_audio_track(t) ? t : MAXV // A1 se largou no vídeo
	return is_audio_track(t) ? 0 : t                                 // V1 se largou no áudio
}
// idem, mas por SEGMENTO: um seg só-áudio (áudio separado de vídeo) fica preso às
// trilhas de áudio mesmo com fonte de vídeo
track_for_seg :: proc(si, t: int) -> int {
	if si >= 0 && si < nsegs && segs[si].aonly do return is_audio_track(t) ? t : MAXV
	return track_for_media(segs[si].src, t)
}

// segmento a exibir no preview (topo sob o playhead; -1 = vazio -> preto)
// tempo usado para MOSTRAR o quadro. Um segmento cobre [start, start+dur), então no
// FIM exato da timeline o playhead não está DENTRO de nenhum: nem o decode nem a
// composição achavam o que exibir e o preview ficava PRETO em vez de segurar o último
// frame (como fazem os NLEs). Recua um fio só para exibição — o playhead e o timecode
// continuam no fim de verdade. Vãos no MEIO da timeline seguem pretos, como devem.
VIEW_EPS :: f32(0.001)
view_t :: proc() -> f32 {
	td := timeline_dur()
	return (td > 0 && st.playhead >= td) ? max(0, td - VIEW_EPS) : st.playhead
}
view_seg :: proc() -> int { return seg_at(view_t()) } // view_t: no fim da timeline, o último quadro (não -1)
// mídia-fonte sob o playhead (-1 = nenhuma) — usada p/ destacar no bin
view_src :: proc() -> int { a := view_seg(); return a >= 0 ? segs[a].src : -1 }
// velocidade efetiva do segmento (0 no zero-value = 1). dur é timeline; a fonte
// consumida é dur*speed, então o mapa timeline->fonte multiplica o delta por speed.
seg_speed :: proc(si: int) -> f32 { s := segs[si].speed; return s <= 0 ? 1 : s }
// rótulo curto da velocidade p/ a timeline: 2x, 1.5x, 0.25x (sem zeros à toa)
speed_label :: proc(sp: f32) -> cstring {
	if abs(sp - math.round(sp))         < 0.005 do return fmt.ctprintf("%.0fx", f64(sp))
	if abs(sp*10 - math.round(sp*10))   < 0.05  do return fmt.ctprintf("%.1fx", f64(sp))
	return fmt.ctprintf("%.2fx", f64(sp))
}
// cor do indicador de velocidade: âmbar = acelerado, azul = câmera lenta
speed_color :: proc(sp: f32) -> rl.Color {
	return sp > 1 ? rl.Color{ 248, 176, 84, 255 } : rl.Color{ 122, 186, 248, 255 }
}
// região de recorte do segmento (frações [0,1] da fonte a MANTER). Sem recorte = quadro
// inteiro (0,0,1,1). Clampa p/ ficar dentro do quadro e com tamanho mínimo.
// normaliza uma região crua (frações) p/ valores válidos; zero-value = quadro inteiro
crop_norm :: proc(cx, cy, cw, ch: f32) -> (x, y, w, h: f32) {
	if cw <= 0.001 || ch <= 0.001 do return 0, 0, 1, 1
	w = clamp(cw, 0.05, 1); h = clamp(ch, 0.05, 1)
	x = clamp(cx, 0, 1 - w); y = clamp(cy, 0, 1 - h)
	return
}
seg_crop :: proc(si: int) -> (x, y, w, h: f32) {
	s := segs[si]
	return crop_norm(s.crop_x, s.crop_y, s.crop_w, s.crop_h)
}
// região de recorte EFETIVA no tempo `t` (absoluto): estática = seg_crop; com zoom_anim,
// interpola crop_* -> crop2_* pelo tempo local do clipe (easing smoothstep = movimento suave).
seg_crop_at :: proc(si: int, t: f32) -> (x, y, w, h: f32) {
	s := segs[si]
	if !s.zoom_anim do return seg_crop(si)
	ax, ay, aw, ah := crop_norm(s.crop_x,  s.crop_y,  s.crop_w,  s.crop_h)
	bx, by, bw, bh := crop_norm(s.crop2_x, s.crop2_y, s.crop2_w, s.crop2_h)
	f := clamp((t - s.start) / max(s.dur, 0.0001), 0, 1)
	f = f*f*(3 - 2*f)
	return ax+(bx-ax)*f, ay+(by-ay)*f, aw+(bw-aw)*f, ah+(bh-ah)*f
}
seg_cropped :: proc(si: int) -> bool { return segs[si].crop_w > 0.001 && segs[si].crop_h > 0.001 && (segs[si].crop_w < 0.999 || segs[si].crop_h < 0.999) }
crop_mode: bool     // modo de recorte ativo (mostra a moldura no preview p/ ajustar)
crop_drag: int = -1 // alça de crop em arrasto: 0..7 cantos/bordas, 8 = mover a região (-1 = nenhum)
crop_grab: rl.Vector2 // offset (frações) entre o mouse e o canto da região ao começar a mover
// liga/desliga o modo recorte SEMPRE por aqui: o único ponto que soltava o crop_drag era o
// IsMouseButtonReleased no fim do draw_crop_editor, que deixa de rodar assim que o modo cai.
// Sair com o botão pressionado (ESC, "Concluir", seleção inválida) deixava a alça pendurada,
// e na próxima entrada o editor continuava o arrasto de onde o cursor estivesse.
set_crop_mode :: proc(on: bool) { crop_mode = on; crop_drag = -1; crop_grab = {} }

// ponto de SAÍDA na fonte (onde o segmento termina de consumir a mídia)
seg_src_out :: proc(si: int) -> f32 { return segs[si].in_off + segs[si].dur * seg_speed(si) }

// tempo dentro da FONTE correspondente ao tempo `t` da timeline no segmento `si`
seg_local :: proc(si: int, t: f32) -> f32 {
	return clamp((t - segs[si].start) * seg_speed(si) + segs[si].in_off, 0, seg_src(si).dur)
}

// segmento que continua `a` sem emenda: mesma fonte, colado na timeline E contíguo
// na fonte (é o caso de um corte simples L|R). Nesse caso o áudio da fonte já está
// tocando exatamente na posição certa, então dá pra passar o bastão sem parar/seek.
next_contiguous_seg :: proc(a: int) -> int {
	out_src := seg_src_out(a)               // posição na fonte onde `a` termina
	out_tl  := segs[a].start  + segs[a].dur // posição na timeline onde `a` termina
	for i in 0 ..< nsegs {
		if i == a || !seg_ready(i) || segs[i].src != segs[a].src || segs[i].track != segs[a].track do continue
		if math.abs(seg_speed(i) - seg_speed(a)) > 0.001 do continue // velocidades diferentes não emendam
		if math.abs(segs[i].in_off - out_src) < 0.02 && math.abs(segs[i].start - out_tl) < 0.02 do return i
	}
	return -1
}

// fim (na FONTE) da cadeia de segmentos contíguos a partir de `a`. Cortes internos
// de um mesmo clipe formam uma cadeia; para o playback são invisíveis — o áudio da
// fonte só "termina" no fim da cadeia inteira, nunca num corte interno.
seg_run_end :: proc(a: int) -> f32 {
	cur := a
	for _ in 0 ..< nsegs { // limite = nº de segmentos (nunca entra em laço)
		nx := next_contiguous_seg(cur)
		if nx < 0 do break
		cur = nx
	}
	return seg_src_out(cur)
}

// ---------- undo/redo ----------
snap_now :: proc() -> Snapshot { s: Snapshot; s.segs = segs; s.nsegs = nsegs; s.fxsegs = fxsegs; s.nfx = nfx; s.nv = g_nv; s.na = g_na; return s }
snap_apply :: proc(s: Snapshot) { segs = s.segs; nsegs = s.nsegs; fxsegs = s.fxsegs; nfx = s.nfx; g_nv = s.nv; g_na = s.na }
snap_eq :: proc(s: Snapshot) -> bool {
	if s.nsegs != nsegs || s.nfx != nfx || s.nv != g_nv || s.na != g_na do return false
	for i in 0 ..< nsegs do if segs[i] != s.segs[i] do return false // Seg é comparável (sem ponteiros)
	for i in 0 ..< nfx   do if fxsegs[i] != s.fxsegs[i] do return false
	return true
}
push_stack :: proc(stack: ^[MAX_UNDO]Snapshot, top: ^int, s: Snapshot) {
	if top^ >= MAX_UNDO { for i in 0 ..< MAX_UNDO - 1 do stack[i] = stack[i + 1]; top^ = MAX_UNDO - 1 } // dropa o mais antigo
	stack[top^] = s; top^ += 1
}
// redefine o baseline SEM criar entrada de undo (ex.: remover mídia — não é desfazível)
history_baseline :: proc() { committed = snap_now(); committed_ok = true }

// há uma interação em curso cujo resultado ainda NÃO virou passo de undo? Enquanto for true
// o histórico fica congelado: nem grava (senão um arrasto empilha um snapshot por frame e o
// MAX_UNDO joga fora o histórico real) nem desfaz (o do_undo mandaria o estado do MEIO do
// arrasto p/ o redo e o `committed` sumiria dos dois lados).
// O recorte do preview entra aqui porque NÃO passa por st.drag: escreve sg.crop_* direto. A
// condição espelha a de escrita do draw_crop_editor, então um crop_drag pendurado se resolve
// no primeiro frame com o botão solto — nunca trava o histórico para sempre.
edit_in_progress :: proc() -> bool {
	if st.drag != .None || ui_slider_active != -1 || player_seek_drag || bin_drag >= 0 do return true
	return crop_drag >= 0 && rl.IsMouseButtonDown(.LEFT)
}
// chamado todo frame (fim do update): se segs mudou E não há interação em curso, grava
history_tick :: proc() {
	if !committed_ok { history_baseline(); return }
	if edit_in_progress() do return
	if !snap_eq(committed) {
		push_stack(&undo_stack, &undo_top, committed) // guarda o estado ANTERIOR
		redo_top = 0                                   // nova edição invalida o redo
		committed = snap_now()
		dirty = true                                   // edição não salva
	}
}
restore_after :: proc() { // conserta índices e o preview após aplicar um snapshot
	if selected >= nsegs do selected = -1
	if sel_trans >= nsegs do sel_trans = -1
	seg_clear_marks() // índices do snapshot não batem com as marcas antigas
	drag_clip = -1; play_clip = -1; st.playing = false; st.drag = .None
	committed = snap_now()
	dirty = true // desfazer/refazer também deixa o documento diferente do salvo
	seek_global(clamp(st.playhead, 0, timeline_dur()))
}
do_undo :: proc() {
	// no meio de um arrasto o `committed` (a última edição CONCLUÍDA) ainda não foi
	// empilhado — o history_tick está congelado. Desfazer aqui mandava o estado do meio do
	// arrasto p/ o redo e aplicava o passo ANTERIOR ao committed: a edição concluída sumia
	// do undo e do redo. Ignora até a interação assentar.
	if edit_in_progress() do return
	if undo_top == 0 { set_toast("Nada para desfazer"); return }
	push_stack(&redo_stack, &redo_top, snap_now()) // estado atual vai p/ o redo
	undo_top -= 1
	snap_apply(undo_stack[undo_top])
	restore_after()
	set_toast("Desfazer")
}
do_redo :: proc() {
	if edit_in_progress() do return // idem do_undo
	if redo_top == 0 { set_toast("Nada para refazer"); return }
	push_stack(&undo_stack, &undo_top, snap_now())
	redo_top -= 1
	snap_apply(redo_stack[redo_top])
	restore_after()
	set_toast("Refazer")
}

// reposiciona a timeline inteira para o tempo t (seek instantâneo)
seek_global :: proc(t: f32) {
	tt := clamp(t, 0, timeline_dur())
	st.playhead = tt
	for i in 0 ..< nclips do if !clips[i].closed && clips[i].has_audio { rl.PauseMusicStream(clips[i].music); clips[i].mix_on = false }
	for i in 0 ..< nsegs do for s in 0 ..< 2 do if spv[i][s].on { rl.PauseMusicStream(spv[i][s].music); spv[i][s].on = false } // pausa spv (reposiciona no frame seguinte)
	play_clip = -1
	show_playhead_frame() // vídeo: frame da trilha de topo sob o playhead
	a := audio_seg_at(tt)  // áudio: relógio do topo COM áudio não-mudo
	if a < 0 do return // sem áudio na região (vazio ou só vídeo): nada a adquirir
	local := seg_local(a, tt)
	src := seg_src(a)
	// mesmo pausado, já garante o áudio da região: adota a parte pronta ou o chunk
	// no bolso, senão encomenda um chunk — quando der play, o som está lá
	if src.has_audio && !try_part_open(src, local) && !try_chunk_open(src, local) do chunk_request(src, local)
	// velocidade != 1 NÃO pode ser relógio: o som vem do WAV pré-renderizado (spv, tom
	// preservado) e o laço de playback já força play_clip = -1 nesse caso. Adquirir aqui
	// recarregava o OGG e dava Resume no tom ORIGINAL — um estalo a cada seek, pausado só
	// no frame seguinte.
	if st.playing && src.has_audio && seg_speed(a) == 1 do set_play_clip(a, local)
}
