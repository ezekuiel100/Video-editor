package main

import rl "vendor:raylib"
import "base:intrinsics"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import win "core:sys/windows"

// ---------- update ----------
update :: proc() {
	// FPS dinâmico: parado (sem playback nem arrasto), 30fps bastam p/ a UI —
	// metade do custo de render; qualquer interação volta a 60 no frame seguinte.
	// O avanço por relógio de parede usa dt, então funciona em qualquer fps.
	idle := !st.playing && st.drag == .None && !win_dragging && !tl_hbar_drag && !zoom_bar_drag && !bin_marquee && !tl_marquee && !tl_split_drag && !md_split_drag && track_resize < 0
	// PLAYBACK: sem cap de CPU — deixa o VSYNC ditar o ritmo (trava no vblank do monitor,
	// como o VLC). SetTargetFPS(60) por timer de CPU não sincroniza com o refresh e batia
	// contra o vsync = judder/tearing. 0 = ilimitado, mas o VSYNC_HINT segura no refresh atual
	// (casa com qualquer taxa, inclusive se o usuário trocar 75->60Hz com o app aberto).
	// Parado: mantém o cap de 30 (economia; sem playback a suavidade não importa).
	rl.SetTargetFPS(idle ? 30 : 0)

	g_frame_no += 1 // frame de render novo (gate do passo travado — ver clip_frame)
	dt := rl.GetFrameTime()
	// TETO no dt: uma travada longa (respawn do decoder de vídeo ~250ms, extração de
	// chunk, loop modal do Windows ao redimensionar, GC) faz o GetFrameTime devolver o
	// tempo INTEIRO da travada. Os ramos por relógio de parede (vão/mudo, velocidade!=1,
	// underrun do áudio, sem-chunk) somam isso de uma vez ao playhead — e o cursor SALTA
	// de lugar "do nada". Limita a ~2 frames: o relógio de áudio re-sincroniza no frame
	// seguinte, então o único custo é uma micro-perda de sync que ele mesmo corrige.
	if dt > 0.1 do dt = 0.1
	g_read_budget = READ_BUDGET // renova o orçamento de decode bloqueante deste frame
	m := rl.GetMousePosition()
	released := rl.IsMouseButtonReleased(.LEFT)
	was_ph := st.drag == .Playhead
	was_clip := st.drag == .Clip
	was_bin := st.drag == .Bin
	was_trans := st.drag == .Trans

	// drag-and-drop de arquivos: importam para o bin (já importado = só seleciona)
	if rl.IsFileDropped() {
		files := rl.LoadDroppedFiles()
		for i in 0 ..< int(files.count) {
			p := strings.clone_from_cstring(files.paths[i], context.temp_allocator)
			if slot, isnew := import_or_select(p, false); !isnew && slot >= 0 {
				set_toast(rl.TextFormat("Já na bin: %s", cs(clips[slot].name)))
			}
		}
		rl.UnloadDroppedFiles(files)
	}
	// botão Importar -> diálogo de arquivo do Windows (também vai para o bin)
	if want_import {
		want_import = false
		if paths, ok := open_videos_dialog(); ok {
			n, dup := 0, -1
			for p in paths {
				slot, isnew := import_or_select(p, false)
				if isnew && slot >= 0 do n += 1
				else if !isnew do dup = slot // já importado
			}
			if n > 1 do set_toast(rl.TextFormat("%d mídias importadas", n))
			else if n == 0 && dup >= 0 do set_toast(rl.TextFormat("Já na bin: %s", cs(clips[dup].name)))
		}
	}
	if toast_t > 0 do toast_t -= dt

	audio_load_ready() // carrega áudios cuja extração terminou
	adopt_respawns()   // sobe frames de respawns de vídeo concluídos (até pausado)
	notify_imports()   // avisa "pronto"/"falhou"
	stream_quality_sync() // pega os clipes que terminaram de importar depois de uma troca de qualidade

	// prévia da exportação: quando o import do arquivo exportado fica pronto, toca-o
	if preview_pending >= 0 && preview_pending < nclips && media_ready(preview_pending) {
		start_src_preview(preview_pending); preview_pending = -1
	}

	// modal aberto: congela as interações de fundo (o draw_modal cuida do modal)
	if modal != .None {
		// em TELA CHEIA o modal ficava inalcançável: o draw retorna antes do draw_modal (nada
		// é desenhado e o `clicked` do botão de sair exige g_modal_draw) e este return corta o
		// ESC — sem saída a não ser matar o processo. Acontecia sozinho ao terminar uma
		// exportação (.Done) ou no Alt+F4 com projeto sujo (.Confirm). Volta pra janela.
		if fullscreen_preview do toggle_fullscreen_preview()
		// o editor de recorte inline não roda sob o modal (gate no draw_preview), e com ele
		// para o ÚNICO ponto que solta a alça — o IsMouseButtonReleased no fim dele. O modal
		// .Done da exportação abre sozinho, podendo cair no meio de um arrasto do recorte:
		// a alça ficava presa e o próximo clique-e-arraste em qualquer lugar reescrevia a
		// região do segmento. Só solta a alça; o modo em si continua ligado.
		// MENOS sob o modal de recorte: lá o crop_rect_editor roda DENTRO do draw_crop_modal e
		// é o dono legítimo do crop_drag. Como o update roda antes do draw, zerar aqui todo
		// frame matava o arrasto do próprio modal — a alça era armada no frame do clique
		// (IsMouseButtonPressed) e já chegava zerada no seguinte, então o retângulo não se
		// movia e o enquadramento só dava para desistir.
		if modal != .Crop { crop_drag = -1; crop_grab = {} }
		st.drag = .None; ui_slider_active = -1; player_seek_drag = false; return
	}

	// exportando: intercepta os cliques nos botões do overlay (pausar/cancelar) ANTES
	// do resto — os rects vêm do draw. Não congela o resto da UI.
	if intrinsics.atomic_load(&export_run) && rl.IsMouseButtonPressed(.LEFT) {
		// usa o `m` do topo do frame: re-buscar aqui dava o MESMO valor (nada move o mouse
		// no meio do update), só sombreava a variável de fora.
		if rl.CheckCollisionPointRec(m, g_exp_pause_btn)  { export_toggle_pause(); return }
		if rl.CheckCollisionPointRec(m, g_exp_cancel_btn) { export_do_cancel();   return }
	}

	// seleção de transição/fade que ficou inválida (removida / undo / segmentos mudaram) cai fora
	if sel_trans >= 0 {
		valid := sel_trans < nsegs
		if valid {
			switch sel_trans_kind {
			case 1: valid = segs[sel_trans].vfin  > 0.01
			case 2: valid = segs[sel_trans].vfout > 0.01
			case:   valid = seg_trans(sel_trans)  > 0.01
			}
		}
		if !valid do sel_trans = -1
	}

	// ---- menu de contexto da timeline (botão direito) ----
	ctx_ate = false
	if ctx_open && (ctx_seg >= nsegs || (ctx_seg >= 0 && !seg_ready(ctx_seg))) do ctx_open = false // alvo sumiu (undo etc.)
	if ctx_open {
		if rl.IsKeyPressed(.ESCAPE) do ctx_open = false
		if rl.IsMouseButtonPressed(.LEFT) {
			id, _ := ctx_hit(rl.GetMousePosition())
			if id >= 0 do ctx_run(id)
			ctx_open = false
			ctx_ate = true // o press que fechou/executou não vaza p/ a timeline (draw)
		} else if rl.IsMouseButtonPressed(.RIGHT) {
			_, inside := ctx_hit(rl.GetMousePosition())
			ctx_open = false
			if inside do ctx_ate = true // direito dentro só fecha; fora deixa reabrir abaixo
		}
	}
	// abrir: botão direito sobre as trilhas (num clipe = menu completo; vazio = colar)
	if !ctx_ate && rl.IsMouseButtonPressed(.RIGHT) && modal == .None && src_preview < 0 &&
	   st.drag == .None && !intrinsics.atomic_load(&export_run) && !fullscreen_preview {
		mp := rl.GetMousePosition()
		if rl.CheckCollisionPointRec(mp, g_vlane) {
			tr := track_at_y(mp.y)
			si := seg_on_track_at(tr, tl_t(mp.x))
			if si >= 0 && track_locked[tr] {
				set_toast("Trilha bloqueada")
			} else {
				ctx_seg = si
				ctx_time = max(0, tl_t(mp.x))
				if si >= 0 { // clique direito também seleciona (age no que se vê)
					selected = si; sel_trans = -1; bin_sel = -1
					if !seg_marked[si] do seg_clear_marks() // fora do grupo: menu age só nele
				}
				ctx_pos = mp
				ctx_open = true
			}
		}
	}

	// Ctrl+Z = desfazer | Ctrl+Y ou Ctrl+Shift+Z = refazer
	ctrl := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
	shift := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
	if ctrl && src_preview < 0 {
		if rl.IsKeyPressed(.Z) && !shift do do_undo()
		if rl.IsKeyPressed(.Y) || (rl.IsKeyPressed(.Z) && shift) do do_redo()
	}
	// Ctrl+S = salvar projeto | Ctrl+O = abrir projeto
	if ctrl && rl.IsKeyPressed(.S) {
		if p, ok := save_dialog("Meu Projeto"); ok do save_project(ensure_ext(p, ".ovp"))
	}
	if ctrl && rl.IsKeyPressed(.O) do request_open()
	// Ctrl+C/X = copiar/recortar o clipe selecionado (ou grupo marcado) da timeline
	// Ctrl+V = colar no playhead | Ctrl+D = duplicar logo após o original
	// (campos de texto têm o próprio Ctrl+C/V/X — gate por txt_edit/search_focus)
	if ctrl && src_preview < 0 && !txt_edit && !search_focus {
		if rl.IsKeyPressed(.C) do copy_segs()
		if rl.IsKeyPressed(.X) do cut_segs()
		if rl.IsKeyPressed(.V) do paste_segs(st.playhead)
		if rl.IsKeyPressed(.D) do duplicate_segs()
	}

	// Delete/Backspace: item do bin selecionado tem prioridade (remove a mídia do
	// editor); senão remove o segmento selecionado da timeline (Alt = deixa o vão)
	if (rl.IsKeyPressed(.DELETE) || rl.IsKeyPressed(.BACKSPACE)) && !txt_edit && !search_focus {
		if bin_marks_count() > 0 { // remove todas as mídias marcadas (tombstone; índices estáveis)
			rm := 0
			for k in 0 ..< nclips do if bin_marked[k] && !intrinsics.atomic_load(&clips[k].failed) { remove_media(k); rm += 1 }
			bin_clear_marks(); bin_sel = -1
			if rm > 1 do set_toast(rl.TextFormat("%d mídias removidas", rm))
		} else if bin_sel >= 0 && bin_sel < nclips && !intrinsics.atomic_load(&clips[bin_sel].failed) {
			remove_media(bin_sel)
		} else if fx_sel >= 0 && fx_sel < nfx { // clipe de efeito selecionado
			remove_fxseg(fx_sel); set_toast("Efeito removido")
		} else if sel_trans >= 0 && sel_trans < nsegs { // transição/fade selecionado tem prioridade
			switch sel_trans_kind {
			case 1: segs[sel_trans].vfin = 0;  set_toast("Fade de entrada removido")
			case 2: segs[sel_trans].vfout = 0; set_toast("Fade de saída removido")
			case:   segs[sel_trans].trans = 0; set_toast("Transição removida")
			}
			sel_trans = -1
		} else if seg_marks_count() > 1 {
			// deletar GRUPO: remove os marcados de índice MAIOR p/ MENOR (a compactação não
			// invalida os índices menores). Deixa os vãos (ripple=false) p/ não embaralhar o resto.
			n := seg_marks_count()
			for k := nsegs - 1; k >= 0; k -= 1 do if seg_marked[k] do remove_seg(k, false)
			seg_clear_marks(); selected = -1
			set_toast(rl.TextFormat("%d clipes removidos", n))
		} else if selected >= 0 {
			remove_seg(selected, !alt_down())
		}
	}

	// atalhos de transporte
	//  espaço = play/pause | ←/→ = 1 frame (Shift = 1s) | Home/End = início/fim
	//  S = dividir no playhead | B = ferramenta lâmina | F = ajustar à janela | Esc = sair da lâmina
	if rl.IsKeyPressed(.F3) do prof_show = !prof_show // HUD do profiler (global, mede o custo da main thread)
	if rl.IsKeyPressed(.F4) do dbg_toggle() // liga/desliga o log de diagnóstico do decoder (arquivo ao lado do .exe)
	if rl.IsKeyPressed(.SPACE) && !txt_edit && !search_focus do toggle_play() // espaço: ciente do modo prévia
	if rl.IsKeyPressed(.ESCAPE) {
		if search_focus do search_focus = false // sai da busca primeiro
		else if txt_edit do txt_edit = false // depois da edição de texto
		else if crop_mode do set_crop_mode(false) // sai do modo recorte
		else if fullscreen_preview do toggle_fullscreen_preview()
		else if src_preview >= 0 do exit_src_preview()
		else if sel_trans >= 0 do sel_trans = -1 // Esc desseleciona a transição
		blade_mode = false
	}
	if src_preview < 0 && !ctrl && !txt_edit && !search_focus { // atalhos de edição da timeline (não digitando; Ctrl reservado)
		if rl.IsKeyPressed(.S) do split_at_playhead()
		if rl.IsKeyPressed(.B) do blade_mode = !blade_mode
		if rl.IsKeyPressed(.F) do tl_fit(g_view_w) // ajusta o zoom p/ o conteúdo caber na janela
		vs := view_seg() // passo de 1 frame segue o fps do clipe sob o playhead (60fps -> 1/60)
		step := (rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)) ? f32(1) : (vs >= 0 ? 1.0 / cfps_of(seg_src(vs)) : 1.0 / DEC_FPS)
		if rl.IsKeyPressed(.RIGHT) || rl.IsKeyPressedRepeat(.RIGHT) { st.playing = false; seek_global(st.playhead + step) }
		if rl.IsKeyPressed(.LEFT)  || rl.IsKeyPressedRepeat(.LEFT)  { st.playing = false; seek_global(st.playhead - step) }
		if rl.IsKeyPressed(.HOME) { st.playing = false; seek_global(0) }
		if rl.IsKeyPressed(.END)  { st.playing = false; seek_global(timeline_dur()) }
	}

	// colocação automática (import_media com place=true): cria o segmento assim
	// que a fonte é sondada (a duração só é conhecida depois do probe).
	for i in 0 ..< nclips {
		c := &clips[i]
		if c.autoplace && !c.seg_made && media_ready(i) {
			tr := free_track_from(track_for_media(i, 0)) // respeita o cadeado da trilha
			if tr < 0 { c.autoplace = false; set_toast("Trilha bloqueada"); continue }
			if add_seg(i, timeline_dur(), 0, c.dur, tr) >= 0 do c.seg_made = true
			else do c.autoplace = false // timeline lotada: desiste (o add_seg já avisou)
		}
	}

	snap_line = -1 // recalculado a cada frame durante o arrasto
	bin_drop_show = false; bin_drop_newtrack = false // prévia do footprint do bin (recalculada no ramo .Bin abaixo)

	// arrasto: mover playhead (scrub), mover/aparar um segmento, ou soltar do bin
	if st.drag == .Playhead {
		st.playhead = clamp(tl_t(m.x), 0, timeline_dur())
		vc := view_seg()
		// se o seg de topo é uma vista DUPLICADA, NÃO escreve na textura da fonte com
		// o tempo dele (corrompia a camada do dono, que usa a mesma textura) — a vista
		// dup é atualizada pelo tick por-frame (dup_frame) com textura própria
		if vc >= 0 && !seg_is_dup(vc) {
			src := seg_src(vc)
			local := seg_local(vc, st.playhead)
			if !src.streaming {
				clip_show(src, int(local * cfps_of(src))) // cache: preview ao vivo, direto da RAM
			} else {
				// streaming: delega o frame ao worker async (não trava a UI); keyframes
				// chegam conforme o decode dá (num arquivo de HORAS cada spawn paga o
				// parse do índice, ~centenas de ms) e a MINIATURA cobre o meio-tempo.
				// NOTA: houve uma tentativa de "arrasto suave" (ler o pipe do decoder ao
				// vivo sequencialmente + respawns de convergência) — REVERTIDA: a
				// oscilação entre os modos degradava a sessão com o tempo (preview preso
				// na miniatura, worker descartado, loop de respawns). Se voltar ao tema,
				// o caminho certo é um decoder PERSISTENTE de scrub por clipe.
				intrinsics.atomic_store(&scrub_req_c, segs[vc].src)
				scrub_req_t = local
			}
		}
	} else if st.drag == .Clip && drag_clip >= 0 && drag_clip < nsegs {
		sg := &segs[drag_clip]
		src := seg_src(drag_clip)
		mt := tl_t(m.x)
		if drag_trim == 0 && seg_marks_count() > 1 && seg_marked[drag_clip] {
			// MOVER EM GRUPO: desloca todos os marcados pelo mesmo Δt (tempo) E Δtrilha (vertical),
			// RÍGIDO — o grupo move junto ou não move na vertical. Se ao aplicar o mesmo Δtrilha
			// QUALQUER marcado sair da sua faixa de tipo (vídeo/áudio), cancela o vertical (dtr=0);
			// nunca clampa um só (era o bug: um movia e o outro travava no limite). Bloqueadas fora.
			in_range :: proc(k, t: int) -> bool { // t cabe na faixa do TIPO do seg k? (e não é travada)
				if t >= 0 && t < MAXTRACKS && track_locked[t] do return false // não solta em trilha travada
				return is_audio_track(segs[k].track) ? (t >= MAXV && t < MAXV + g_na) : (t >= 0 && t < g_nv)
			}
			want := max(0, mt - grab_dt)
			delta := want - sg.start
			tgt := clamp(track_at_y(m.y), is_audio_track(segs[drag_clip].track) ? MAXV : 0, is_audio_track(segs[drag_clip].track) ? MAXV + g_na - 1 : g_nv - 1)
			drow := track_row(tgt) - track_row(segs[drag_clip].track) // deslocamento em LINHAS (do clipe agarrado)
			minstart := f32(1e30)
			for k in 0 ..< nsegs do if seg_marked[k] && !track_locked[segs[k].track] && segs[k].start < minstart do minstart = segs[k].start
			if minstart + delta < 0 do delta = -minstart // não deixa ninguém ir p/ antes de 0
			// vertical só se TODOS couberem; senão trava (sem trilha disponível = não move)
			if drow != 0 do for k in 0 ..< nsegs {
				if !seg_marked[k] || track_locked[segs[k].track] do continue
				if !in_range(k, track_shift_rows(segs[k].track, drow)) { drow = 0; break }
			}
			check :: proc(dr: int, dl: f32) -> bool { // nenhum marcado invade um não-marcado?
				for k in 0 ..< nsegs {
					if !seg_marked[k] || track_locked[segs[k].track] do continue
					d := track_shift_rows(segs[k].track, dr)
					if overlaps_nonmarked(d, segs[k].start + dl, segs[k].dur) do return false
				}
				return true
			}
			ok := check(drow, delta)
			if !ok && drow != 0 { drow = 0; ok = check(0, delta) } // vertical bloqueado: tenta só horizontal
			if ok && (abs(delta) > 0.0001 || drow != 0) {
				for k in 0 ..< nsegs {
					if !seg_marked[k] || track_locked[segs[k].track] do continue
					segs[k].track = track_shift_rows(segs[k].track, drow)
					segs[k].start = max(0, segs[k].start + delta)
				}
			}
		} else if drag_trim == 0 { // mover ÚNICO: pode trocar de trilha (Y do mouse) e de posição
			ntr := track_for_seg(drag_clip, track_at_y(m.y)) // respeita vídeo/áudio (e só-áudio)
			if track_locked[ntr] do ntr = sg.track // trilha travada não recebe: fica na atual
			cand := snap_start(ntr, drag_clip, max(0, mt - grab_dt), sg.dur)
			if !overlaps_any(ntr, drag_clip, cand, sg.dur) { sg.start = cand; sg.track = ntr }
			else do snap_line = -1 // rejeitado: não mostra guia num lugar onde não foi
		} else if drag_trim < 0 { // aparar a borda esquerda (mantém o fim fixo)
			old_end := sg.start + sg.dur
			spd := seg_speed(drag_clip)
			// limites: in_off >= 0 (nada antes da fonte), fim do vizinho à esquerda, dur > 0.
			// in_off zera quando o início recua sg.in_off/speed na timeline.
			// imagem/TEXTO não têm fonte com fim: in_off não representa nada neles (o
			// seg_src_span ignora), então a borda esquerda também estica livremente — só o
			// vizinho limita. Sem esta exceção, `lo` virava o próprio sg.start (in_off = 0 no
			// nascimento) e a borda esquerda só ENCURTAVA, nunca esticava — ao contrário da
			// direita, que já tinha o caso.
			wall := left_wall(sg.track, drag_clip, sg.start + 0.001)
			lo := (src.is_img || src.is_text) ? wall : max(sg.start - sg.in_off / spd, wall)
			// encaixa a borda nas bordas dos outros clipes (inclusive de OUTRAS trilhas) e
			// acende a guia; se o clamp (fonte/vizinho) tirar do ponto, apaga a guia — ela só
			// aparece onde a borda REALMENTE parou
			snapped := snap_edge(drag_clip, mt)
			new_start := clamp(snapped, lo, old_end - 0.05)
			if abs(new_start - snapped) > 0.0001 do snap_line = -1
			// imagem/texto: a borda pode ir p/ ANTES do início antigo (não há fonte que
			// limite), e aí o acúmulo deixaria in_off NEGATIVO — o check_invariants reprova
			// (`in_off negativo`) e o inv_fail é um panic, então o build de debug caía no
			// mesmo frame. in_off não significa nada nessas mídias (seg_src_span ignora).
			if src.is_img || src.is_text do sg.in_off = 0
			else                         do sg.in_off += (new_start - sg.start) * spd
			sg.start = new_start
			sg.dur = old_end - new_start
		} else { // aparar a borda direita (mantém o início fixo)
			// limites: fim da fonte e início do vizinho à direita. Imagem/TEXTO = still sem
			// fim real: pode esticar livremente (cap alto), só respeitando o vizinho.
			srcdur := (src.is_img || src.is_text) ? f32(3600) : src.dur
			// a fonte restante (srcdur - in_off) rende (srcdur - in_off)/speed na timeline
			max_end := min(sg.start + (srcdur - sg.in_off) / seg_speed(drag_clip), right_wall(sg.track, drag_clip, sg.start + 0.05))
			// mesma guia de encaixe do aparo da esquerda, agora p/ a borda do FIM
			snapped := snap_edge(drag_clip, mt)
			new_end := clamp(snapped, sg.start + 0.05, max_end)
			if abs(new_end - snapped) > 0.0001 do snap_line = -1
			sg.dur = new_end - sg.start
		}
	} else if st.drag == .FadeIn && drag_clip >= 0 && drag_clip < nsegs {
		sg := &segs[drag_clip]
		sg.fade_in = clamp(tl_t(m.x) - sg.start, 0, sg.dur)
		if sg.fade_in + sg.fade_out > sg.dur do sg.fade_in = max(0, sg.dur - sg.fade_out)
	} else if st.drag == .FadeOut && drag_clip >= 0 && drag_clip < nsegs {
		sg := &segs[drag_clip]
		sg.fade_out = clamp((sg.start + sg.dur) - tl_t(m.x), 0, sg.dur)
		if sg.fade_in + sg.fade_out > sg.dur do sg.fade_out = max(0, sg.dur - sg.fade_in)
	} else if st.drag == .TransDur && drag_clip >= 0 && drag_clip < nsegs {
		// arrastar uma alça do dissolver/fade selecionado. Mínimo 0.2s (remover é pelo
		// Delete/X). O tipo vem de sel_trans_kind (consistente: só se arrasta o selecionado).
		sg := &segs[drag_clip]
		switch sel_trans_kind {
		case 1: // fade preto de entrada: largura = distância da borda esquerda
			sg.vfin  = clamp(tl_t(m.x) - sg.start, 0.1, max(f32(0.2), sg.dur*0.9))
		case 2: // fade preto de saída: largura = distância da borda direita
			sg.vfout = clamp((sg.start + sg.dur) - tl_t(m.x), 0.1, max(f32(0.2), sg.dur*0.9))
		case: // dissolver: D é SIMÉTRICO no corte, distância do mouse ao corte = D/2
			half := abs(tl_t(m.x) - sg.start)
			sg.trans = clamp(half * 2, 0.2, trans_max(drag_clip))
		}
	} else if st.drag == .Vol && drag_clip >= 0 && drag_clip < nsegs {
		frac := clamp((g_vby1 - m.y) / (g_vby1 - g_vby0), 0, 1) // base=0, topo=VOL_MAX
		v := frac * VOL_MAX
		if abs(v - 1) < 0.06 * VOL_MAX do v = 1 // gruda em 100%
		segs[drag_clip].vol = v
	} else if st.drag == .PreviewMove && drag_clip >= 0 && drag_clip < nsegs && g_frame.width > 0 {
		sg := &segs[drag_clip]
		ccx := m.x - prev_grab.x; ccy := m.y - prev_grab.y // move o centro do clipe no preview
		px := clamp((ccx - (g_frame.x + g_frame.width/2)) / g_frame.width, -1.5, 1.5)
		py := clamp((ccy - (g_frame.y + g_frame.height/2)) / g_frame.height, -1.5, 1.5)
		// tamanho EXIBIDO do clipe (frações) p/ alinhar as BORDAS ao canvas, além do centro
		s := sg.scale <= 0 ? f32(1) : sg.scale
		_, _, crw, crh := seg_crop_at(drag_clip, st.playhead)
		cr := dec_content_rect(seg_src(drag_clip)) // quadro da fonte = conteúdo (mesmo do draw)
		cwpx := crw*cr.width; chpx := crh*cr.height
		tf := min(g_frame.width/cwpx, g_frame.height/chpx)
		hwf := (cwpx*tf*s/2) / g_frame.width  // meia-largura (fração do frame)
		hhf := (chpx*tf*s/2) / g_frame.height // meia-altura
		T :: f32(0.02) // limiar de encaixe (~2% do frame)
		g_pv_x = -1; g_ph_y = -1
		// X: centro do canvas (0) ou bordas esquerda/direita
		if      abs(px)               < T { px = 0;          g_pv_x = g_frame.x + g_frame.width/2 }
		else if abs(px - (-0.5+hwf))  < T { px = -0.5+hwf;   g_pv_x = g_frame.x }
		else if abs(px - ( 0.5-hwf))  < T { px =  0.5-hwf;   g_pv_x = g_frame.x + g_frame.width }
		// Y: centro ou bordas topo/base
		if      abs(py)               < T { py = 0;          g_ph_y = g_frame.y + g_frame.height/2 }
		else if abs(py - (-0.5+hhf))  < T { py = -0.5+hhf;   g_ph_y = g_frame.y }
		else if abs(py - ( 0.5-hhf))  < T { py =  0.5-hhf;   g_ph_y = g_frame.y + g_frame.height }
		sg.px = px; sg.py = py
	} else if st.drag == .FxCenter && drag_clip >= 0 && drag_clip < nsegs && g_frame.width > 0 {
		sg := &segs[drag_clip] // arrastar o centro da distorção: mouse -> bulge_x/bulge_y (local)
		s := sg.scale <= 0 ? f32(1) : sg.scale
		ccx := g_frame.x + g_frame.width/2 + sg.px*g_frame.width
		ccy := g_frame.y + g_frame.height/2 + sg.py*g_frame.height
		rw := g_frame.width*s; rh := g_frame.height*s
		rad := sg.rot * math.PI/180; cs_ := math.cos(rad); sn := math.sin(rad)
		dx := m.x - ccx; dy := m.y - ccy // des-rotaciona p/ o plano do clipe
		ux := dx*cs_ + dy*sn; uy := -dx*sn + dy*cs_
		sg.bulge_x = clamp(ux/rw, -0.5, 0.5); sg.bulge_y = clamp(uy/rh, -0.5, 0.5)
		if abs(sg.bulge_x) < 0.02 do sg.bulge_x = 0
		if abs(sg.bulge_y) < 0.02 do sg.bulge_y = 0
	} else if st.drag == .FxCtr && fx_sel >= 0 && fx_sel < nfx && g_frame.width > 0 {
		f := &fxsegs[fx_sel] // centro da distorção do CLIPE DE EFEITO (relativo ao quadro)
		// SEM encaixe no meio: a "zona morta" fazia o centro pular pro meio (parecia um ímã)
		f.cx = clamp((m.x - (g_frame.x + g_frame.width/2)) / g_frame.width, -0.5, 0.5)
		f.cy = clamp((m.y - (g_frame.y + g_frame.height/2)) / g_frame.height, -0.5, 0.5)
	} else if st.drag == .Bin && bin_drag >= 0 && bin_drag < nclips {
		over_newv := !clips[bin_drag].is_audio && g_nv < MAXV && rl.CheckCollisionPointRec(m, g_newv_zone)
		over_newa :=  clips[bin_drag].is_audio && g_na < MAXA && rl.CheckCollisionPointRec(m, g_newa_zone)
		if over_newv || over_newa {
			// sobre a banda "+ trilha": já mostra o footprint onde o clipe cairá na trilha NOVA
			// (trilha vazia = sem empurrão; começa no cursor adiantado). O drop cria a trilha.
			bin_drop_start = max(0, tl_t(m.x - DROP_LEAD)); bin_drop_dur = clips[bin_drag].dur
			bin_drop_zone = over_newv ? g_newv_zone : g_newa_zone
			bin_drop_newtrack = true; bin_drop_show = true
		} else if rl.CheckCollisionPointRec(m, g_vlane) {
			tr := track_for_media(bin_drag, track_at_y(m.y))
			s := snap_start(tr, -1, max(0, tl_t(m.x - DROP_LEAD)), clips[bin_drag].dur) // guia (adiantado)
			// footprint real do drop (empurra p/ espaço livre, igual ao drop) — mostra onde vai ficar
			bin_drop_tr = tr; bin_drop_start = free_start(tr, -1, s, clips[bin_drag].dur)
			bin_drop_dur = clips[bin_drag].dur; bin_drop_show = true
		}
	} else if st.drag == .FxClip && fx_sel >= 0 && fx_sel < nfx {
		f := &fxsegs[fx_sel]
		ty := track_at_y(m.y)                                        // trilha de vídeo sob o cursor
		tr := is_audio_track(ty) ? f.track : clamp(ty, 0, g_nv - 1)  // efeito só em trilha de vídeo
		cand := max(0, tl_t(m.x) - fx_grab_dt)
		if !fx_busy(tr, fx_sel, cand, f.dur) { f.start = cand; f.track = tr } // EXCLUSIVO: rejeita se invadir seg/efeito
	} else if st.drag == .FxTrim && fx_sel >= 0 && fx_sel < nfx {
		f := &fxsegs[fx_sel]
		maxend := fx_wall_r(f.track, fx_sel, f.start + 0.05)          // não passa por cima do vizinho
		f.dur = clamp(tl_t(m.x), f.start + 0.3, maxend) - f.start
	}
	if released {
		if st.drag == .FxLib && fxlib_drag >= 0 { // soltar um efeito da biblioteca -> clipe de efeito NUMA TRILHA
			ty := track_at_y(m.y)
			tr := -1
			if g_nv < MAXV && rl.CheckCollisionPointRec(m, g_newv_zone) do tr = add_video_track() // banda "+ trilha": cria uma nova
			else if rl.CheckCollisionPointRec(m, g_vlane) && !is_audio_track(ty) do tr = clamp(ty, 0, g_nv - 1)
			if tr >= 0 {
				start := fx_free_start(tr, -1, max(0, tl_t(m.x - DROP_LEAD)), 3) // empurra p/ um vão livre (não cai sobre seg/efeito)
				add_fxseg(fxlib_drag, start, tr)
			} else do set_toast("Solte o efeito sobre uma trilha de vídeo")
			fxlib_drag = -1
		}
		if was_ph do seek_global(st.playhead)
		if was_clip {
			// soltar um clipe ÚNICO (não em grupo, não aparando) numa banda "criar trilha":
			// cria a trilha do tipo certo e move o clipe pra ela.
			if drag_clip >= 0 && drag_clip < nsegs && drag_trim == 0 && !(seg_marks_count() > 1 && seg_marked[drag_clip]) {
				aud := seg_audio_like(drag_clip)
				nt := -1
				if      !aud && g_nv < MAXV && rl.CheckCollisionPointRec(m, g_newv_zone) do nt = add_video_track()
				else if  aud && g_na < MAXA && rl.CheckCollisionPointRec(m, g_newa_zone) do nt = add_audio_track()
				if nt >= 0 {
					segs[drag_clip].track = nt
					segs[drag_clip].start = free_start(nt, drag_clip, segs[drag_clip].start, segs[drag_clip].dur)
				}
			}
			seek_global(st.playhead); drag_clip = -1; drag_trim = 0
		}
		if was_bin { // soltar item(ns) do bin numa trilha (definida pelo Y) -> cria segmentos
			// bandas "criar trilha": soltar mídia compatível na banda cria a trilha e larga nela
			over_newv := bin_drag >= 0 && bin_drag < nclips && !clips[bin_drag].is_audio && g_nv < MAXV && rl.CheckCollisionPointRec(m, g_newv_zone)
			over_newa := bin_drag >= 0 && bin_drag < nclips &&  clips[bin_drag].is_audio && g_na < MAXA && rl.CheckCollisionPointRec(m, g_newa_zone)
			if bin_drag >= 0 && bin_drag < nclips && (over_newv || over_newa || rl.CheckCollisionPointRec(m, g_vlane)) {
				tgt := over_newv ? add_video_track() : over_newa ? add_audio_track() : track_at_y(m.y)
				cursor := max(0, tl_t(m.x - DROP_LEAD)) // início adiantado (encaixa no começo)
				nm := bin_marks_count()
				placed := 0
				last_name: cstring = ""
				for k in 0 ..< nclips {
					use := nm > 0 ? bin_marked[k] : (k == bin_drag) // marcados; senão só o arrastado
					if !use || intrinsics.atomic_load(&clips[k].failed) || !media_ready(k) do continue
					c := &clips[k]
					tr := track_for_media(k, tgt) // áudio->trilha de áudio, vídeo/imagem->vídeo
					if track_locked[tr] { set_toast("Trilha bloqueada"); continue } // não solta em trilha travada
					start := snap_start(tr, -1, cursor, c.dur)
					start = free_start(tr, -1, start, c.dur) // espaço livre (sem invadir)
					if add_seg(k, start, 0, c.dur, tr) >= 0 {
						placed += 1; cursor = start + c.dur; last_name = cs(c.name) // enfileira o próximo
					}
				}
				seek_global(st.playhead)
				if placed == 1      do set_toast(rl.TextFormat("%s na timeline", last_name))
				else if placed > 1  do set_toast(rl.TextFormat("%d mídias na timeline", placed))
			}
			bin_drag = -1
		}
		if was_trans { // soltar uma transição: na timeline aplica no corte/clipe sob o cursor
			if rl.CheckCollisionPointRec(m, g_vlane) {
				si := seg_on_track_at(track_at_y(m.y), tl_t(m.x))
				if si >= 0 && track_locked[segs[si].track] do set_toast("Trilha bloqueada")
				else if si >= 0 do apply_transition_at(si, trans_drag, tl_t(m.x))
				else do set_toast("Solte sobre um clipe")
			} else {
				apply_transition(trans_drag) // fora da timeline = aplica ao selecionado (clique)
			}
			trans_drag = -1
		}
		st.drag = .None
		drag_clip = -1 // fade/volume também soltam aqui
		snap_line = -1
	}

	// scrub streaming: sobe o frame que o worker decodificou (só na main thread);
	// fora do scrub, deixa o worker ocioso.
	if st.drag != .Playhead do intrinsics.atomic_store(&scrub_req_c, -1)
	if intrinsics.atomic_load(&scrub_ready) {
		dc := scrub_done_c
		// NÃO sobe o frame de scrub durante o PLAYBACK: um scrub tardio (o worker ainda estava
		// decodificando o último ponto arrastado quando você soltou e deu play) plantaria um frame
		// de OUTRO tempo por 1 frame por cima do vídeo = "imagem rápida aparecendo" (flash). Só
		// adota quando NÃO está tocando (arrasto/pausa), onde o frame de scrub é o que deve aparecer.
		if !st.playing && dc >= 0 && dc < nclips && !clips[dc].closed && scrub_done_sf == cframe(&clips[dc]) {
			upload_tex(&clips[dc], rawptr(raw_data(scrub_buf)))
			clips[dc].tex_t = scrub_done_t // frame do scrub: vale pelo tempo PEDIDO (keyframe ≈ perto)
		} else if st.playing && dc >= 0 {
			dbg("SCRUBDROP", "descartado frame de scrub tardio t=%.1fs durante o playback (evita FLASH)", scrub_done_t)
		}
		intrinsics.atomic_store(&scrub_ready, false)
	}
	dup_poll() // adota spawns das vistas duplicadas (mesma fonte em 2 trilhas) e limpa slots mortos
	// mantém as vistas dup atualizadas TODO frame (pausado, drop, trim, scrub): fora
	// do playback o show_playhead_frame não roda, e sem isto a camada de cima ficava
	// congelada no fallback (mesmo frame do dono) até dar play. Barato: cache é no-op
	// quando o frame não mudou; streaming lê no máx 2 frames do pipe próprio.
	if src_preview < 0 && modal == .None {
		for t in 0 ..< g_nv {
			if i := seg_on_track_at(t, st.playhead); i >= 0 && seg_is_dup(i) {
				dup_frame(i, seg_local(i, st.playhead))
			}
		}
	}

	// pausado e sem arrasto: re-dirige o frame do clipe sob o playhead TODO frame. Um
	// seek pausado num clipe STREAMING (ex.: clicar p/ voltar ao início) dispara um
	// respawn ASSÍNCRONO do decoder; se ele foi descartado (outro respawn no ar) ou
	// falhou, o clip_frame precisa ser chamado de novo p/ re-pedir — mas fora do
	// playback nada o chamava, e a imagem congelava no frame velho até dar play/seekar.
	// Barato: quando já está na posição, cache é no-op e o streaming não lê nada.
	// (durante arrasto do playhead o frame vem do worker de scrub, não daqui)
	if src_preview < 0 && modal == .None && st.drag == .None && !st.playing {
		show_playhead_frame()
	}

	// prévia de origem (duplo-clique no bin): caminho próprio, ignora a timeline
	if src_preview >= 0 {
		update_src_preview(dt)
		return
	}

	// playback: o segmento sob o playhead toca; o áudio da sua fonte é o relógio.
	// o segmento pode recortar só um trecho da fonte, então o FIM é in_off+dur
	// (não a duração da fonte). Espaços vazios / sem áudio avançam pelo relógio de parede.
	// arrastos de volume/fade NÃO movem o playhead — deixa tocar p/ ouvir a mudança ao vivo
	audio_edit := audio_edit_drag()
	if st.playing && (st.drag == .None || audio_edit) {
		a := audio_seg_at(st.playhead) // RELÓGIO = topo com áudio não-mudo (pode não ser o vídeo)
		when DBG_PLAY { // LOG TEMPORÁRIO de diagnóstico do congelamento
			mp := a >= 0 && seg_src(a).has_audio ? rl.IsMusicStreamPlaying(seg_src(a).music) : false
			ck := a >= 0 && seg_src(a).has_audio ? audio_clock_ok(seg_src(a), (st.playhead-segs[a].start)*seg_speed(a)+segs[a].in_off) : false
			fmt.eprintfln("[play] ph=%.3f dur=%.3f a=%d pc=%d mp=%v ck=%v", f64(st.playhead), f64(timeline_dur()), a, play_clip, mp, ck)
		}
		if a < 0 {
			// sem áudio na região (vão OU só vídeo mudo/overlay): avança pelo relógio de
			// parede e mostra o frame da trilha de topo (se houver)
			if play_clip >= 0 {
				if seg_src(play_clip).has_audio do rl.PauseMusicStream(seg_src(play_clip).music)
				play_clip = -1
			}
			st.playhead += dt
			when DBG_SEEK do if dbg_seek_n > 0 {
				dbg_seek_n -= 1
				fmt.eprintfln("[seek/SEM-AUDIO] ph=%.3f", f64(st.playhead))
			}
			if st.playhead >= timeline_dur() do st.playing = false
			else do show_playhead_frame()
		} else if seg_speed(a) != 1 {
			// VELOCIDADE != 1: NÃO usa o áudio da fonte como relógio (a reamostragem
			// mudaria o tom). Avança pelo relógio de PAREDE (duração de timeline correta)
			// e o som sai do WAV pré-renderizado (audio_speed_preview, tom preservado).
			if play_clip >= 0 {
				if seg_src(play_clip).has_audio do rl.PauseMusicStream(seg_src(play_clip).music)
				play_clip = -1
			}
			sg := &segs[a]
			nl := (st.playhead - sg.start) + dt
			if nl >= sg.dur do st.playhead = sg.start + sg.dur
			else { st.playhead = sg.start + nl; show_playhead_frame() }
			when DBG_SEEK do if dbg_seek_n > 0 {
				dbg_seek_n -= 1
				cc := seg_src(a)
				loc := clamp(st.playhead - sg.start, 0, sg.dur)
				ci := clamp(int(loc / SPV_CHUNK), 0, spv_nchunks(a) - 1)
				e := &spv[a][ci & 1]
				fmt.eprintfln("[seek/VELOCIDADE] ph=%.3f loc=%.3f sp=%.2f | spv ok=%v on=%v pos=%.3f alvo=%.3f d_aud=%+.3f | VIDEO tex_t=%.3f ATRASO=%+.3f",
					f64(st.playhead), f64(loc), f64(seg_speed(a)), e.ok, e.on,
					f64(e.ok ? rl.GetMusicTimePlayed(e.music) : 0), f64(loc - f32(ci)*SPV_CHUNK),
					f64((e.ok ? rl.GetMusicTimePlayed(e.music) : 0) - (loc - f32(ci)*SPV_CHUNK)),
					f64(cc.tex_t), f64(seg_local(a, st.playhead) - cc.tex_t))
			}
		} else {
			sg := &segs[a]
			c := seg_src(a)
			loc0 := (st.playhead - sg.start) * seg_speed(a) + sg.in_off // posição na fonte
			out0 := seg_run_end(a)                       // fim da CADEIA contígua, na fonte
			if c.has_audio && audio_clock_ok(c, loc0) {
				// adquire o áudio ao entrar num segmento. Mas se já estamos tocando
				// a MESMA fonte e o áudio já está na posição certa (atravessamos um
				// corte interno), só troca o dono — SEM seek/resume. Era o seek na
				// borda que engasgava; agora o corte fica invisível pro playback.
				acquired := false // seek feito NESTE frame
				if play_clip != a {
					// Atravessamos um corte limpo se `a` é a continuação contígua do
					// segmento que já está tocando. Aí o áudio da fonte JÁ está na
					// posição certa — passa o dono sem seek. Critério estrutural (não
					// depende de tolerância de tempo), então funciona mesmo com o vídeo
					// streaming lento, onde o áudio avança muito num único frame.
					if play_clip >= 0 && rl.IsMusicStreamPlaying(c.music) && next_contiguous_seg(play_clip) == a {
						play_clip = a
					} else {
						set_play_clip(a, loc0)
						acquired = true
					}
				}
				// no frame do seek, GetMusicTimePlayed ainda não assentou (o buffer só
				// atualiza no próximo UpdateMusicStream) e reportava uma posição ANTES
				// do ponto buscado. O playhead derivado recuava pra fora do segmento,
				// caía no vão, e o frame seguinte fazia OUTRO seek — oscilação infinita
				// na borda de cortes separados (SEEKS disparava). Confia no loc0 pedido.
				local := acquired ? loc0 : rl.GetMusicTimePlayed(c.music) + c.music_base // posição na FONTE (chunk tem offset)
				// seek do seek_global neste frame: a leitura acima é stale — usa a posição pedida
				was_seek := !acquired && seek_pending
				if was_seek do local = seek_pending_loc
				seek_pending = false
				// relógio SUAVE (PLL — o mesmo da prévia do bin): substitui o clamp monotônico e
				// a guarda de salto >3s, que eram versões rústicas da mesma ideia. Absorve os
				// degraus de 10-20ms do GetMusicTimePlayed (lição 9: oscila p/ trás; lição 8:
				// buffers velhos) E os glitches da troca de janela de áudio (o antigo salto >3s):
				// drift fora de ±SMOOTH_HARD avança pelo dt e reata sozinho se persistir
				// (~0.75s). Seeks/acquire ancoram por loc0/seek_pending_loc; aud_prev assume o
				// valor no fim do bloco (mesmo papel de antes).
				if !acquired && !was_seek do local = smooth_clock(local, dt)
				when DBG_SEEK do if dbg_seek_n > 0 {
					dbg_seek_n -= 1
					fmt.eprintfln("[seek] ph=%.3f raw=%.3f d_aud=%+.3f | VIDEO tex_t=%.3f ATRASO=%+.3f stream=%v rsp=%v | acq=%v pend=%v",
						f64(st.playhead), f64(rl.GetMusicTimePlayed(c.music) + c.music_base), f64(local-loc0),
						f64(c.tex_t), f64(local - c.tex_t), c.streaming, intrinsics.atomic_load(&c.rsp_busy),
						acquired, was_seek)
				}
				// e nunca deixa o jitter do relógio recuar o playhead pra antes do
				// início do segmento (sairia dele e re-entraria em loop)
				if local < sg.in_off do local = sg.in_off
				// o stream parou mas AINDA FALTA segmento -> não é fim, é buffer que
				// esvaziou (hitch do respawn do decoder, loop modal do Windows ao
				// redimensionar, frame longo): retoma de onde estava. Antes exigia
				// dt > 0.25, então travadas curtas caíam no caso "fim" — pausava o
				// áudio e jogava o playhead pro fim da cadeia (mutava do nada).
				if !rl.IsMusicStreamPlaying(c.music) && local < out0 - 0.25 {
					// stream parou mas AINDA falta segmento -> underrun (buffer esvaziou
					// num hitch), não fim: retoma de onde estava.
					rl.ResumeMusicStream(c.music)
					// pode ser underrun OU o áudio da fonte é MAIS CURTO que o vídeo e
					// chegou ao fim — aí o Resume não traz de volta e GetMusicTimePlayed
					// fica congelado, prendendo o playhead aqui pra sempre. Avança pelo
					// relógio de PAREDE: underrun real re-sincroniza no próximo frame;
					// áudio acabado segue em silêncio até o fim do segmento.
					nl := (st.playhead - sg.start) + dt
					if nl >= sg.dur do st.playhead = sg.start + sg.dur
					else { st.playhead = sg.start + nl; show_playhead_frame() }
				} else if !rl.IsMusicStreamPlaying(c.music) || local >= out0 - 0.001 {
					rl.PauseMusicStream(c.music) // fim da cadeia (a fonte pode continuar)
					play_clip = -1
					st.playhead = sg.start + (out0 - sg.in_off) / seg_speed(a) // fim da cadeia, na timeline
				} else {
					// GRAVA um SALTO do playhead: o relógio de áudio mandou o playhead
					// pular > 2s num único frame de playback contínuo (não é seek). É o
					// bug "o cursor pula sozinho / imagem vai ficando ruim". Guarda o
					// estado do relógio no instante p/ o HUD mostrar POR QUE saltou.
					new_ph := sg.start + (local - sg.in_off) / seg_speed(a)
					if new_ph - st.playhead > 2.0 {
						dbg_jmp_n += 1; dbg_jmp_kind = 1
						dbg_jmp_from = st.playhead; dbg_jmp_to = new_ph
						dbg_jmp_gmtp = rl.GetMusicTimePlayed(c.music); dbg_jmp_base = c.music_base
						dbg_jmp_loc0 = loc0; dbg_jmp_len = f32(c.music.frameCount) / f32(c.music.stream.sampleRate)
						dbg_jmp_acq = acquired; dbg_jmp_pend = seek_pending
					}
					aud_prev = local
					// pré-busca: perto do fim da janela ativa e a próxima área ainda sem
					// parte pronta -> encomenda o chunk seguinte JÁ (troca sem gap na borda)
					cend := c.music_base + f32(c.music.frameCount) / f32(c.music.stream.sampleRate)
					if cend < out0 && local > cend - 15 {
						if int((cend + 1) / FULL_PART) >= intrinsics.atomic_load(&c.parts_done) {
							chunk_request(c, cend - 1)
						}
					}
					st.playhead = new_ph
					show_playhead_frame()
				}
			} else {
				// sem relógio de áudio na região: adota a parte pronta ou o chunk no
				// bolso; senão encomenda um chunk. O frame seguinte adquire e o som volta.
				if c.has_audio && !try_part_open(c, loc0) && !try_chunk_open(c, loc0) do chunk_request(c, loc0)
				if play_clip >= 0 {
					if seg_src(play_clip).has_audio do rl.PauseMusicStream(seg_src(play_clip).music)
					play_clip = -1
				}
				local := (st.playhead - sg.start) + dt // avanço no tempo da timeline
				if local >= sg.dur { st.playhead = sg.start + sg.dur }
				else { st.playhead = sg.start + local; show_playhead_frame() }
			}
		}
	}
	// mantém os buffers do áudio ativo alimentados + aplica volume/mudo/fade do
	// segmento SOB O PLAYHEAD (não o dono da cadeia: num run contíguo cada pedaço
	// tem o seu próprio ganho). SetMusicVolume age no stream compartilhado da fonte,
	// mas só um segmento toca por vez, então não há conflito.
	if st.playing && play_clip >= 0 && seg_src(play_clip).has_audio {
		rl.SetMusicVolume(seg_src(play_clip).music, seg_gain(play_clip, st.playhead) * player_vol) // × volume do player (monitor)
		rl.UpdateMusicStream(seg_src(play_clip).music)
	}
	audio_secondary() // mixa as trilhas de áudio (música de fundo) em sincronia com o master
	audio_speed_preview() // som dos segmentos com velocidade != 1 (tom preservado)
	fades_settle()    // fades maiores que o clipe, depois que o arrasto assentou
	history_tick()    // grava um passo de undo quando uma edição assenta

	// pedido de export enfileirado pelo modal (draw) — dispara AQUI, fora do BeginDrawing
	if export_pending {
		export_pending = false
		path := export_pending_path
		gpu := export_pending_gpu
		export_pending_path = ""
		if path != "" {
			export_gpu_fallback = false // corrida nova: libera o retry por CPU
			start_export(path, gpu)
			delete(path)
		}
	}

	// exportação terminou: avisa e limpa a thread (só a main mexe em toast/thread)
	running := intrinsics.atomic_load(&export_run)
	if export_was_running && !running {
		export_was_running = false
		if export_thr != nil { thread.join(export_thr); thread.destroy(export_thr); export_thr = nil }
		if export_prev_thr != nil { thread.join(export_prev_thr); thread.destroy(export_prev_thr); export_prev_thr = nil }
		if export_cancel { // cancelado: remove o arquivo parcial, não é falha
			if export_out != "" do os.remove(export_out)
			set_toast("Exportação cancelada")
			export_gpu_fallback = false
		} else if export_ok { // abre o modal de conclusão (com prévia) em vez de só um toast
			if done_path != "" do delete(done_path)
			done_path = strings.clone(export_out)
			modal = .Done
			if g_done_snd_ok do rl.PlaySound(g_done_snd) // aviso sonoro: exportação concluída
			export_gpu_fallback = false
		} else {
			// NVENC falhou no meio (driver, encoder ocupado, resolução estranha…): tenta
			// UMA vez por CPU com o mesmo caminho, sem o usuário precisar desmarcar o
			// checkbox. export_gpu_fallback evita loop se a CPU também falhar.
			if export_used_gpu && !export_gpu_fallback && export_out != "" {
				export_gpu_fallback = true
				export_gpu = false // desmarca o checkbox: a GPU acabou de falhar nesta máquina
				export_nvenc_ok = false
				if export_out != "" do os.remove(export_out) // lixo parcial do NVENC
				for f in export_tmp_files { os.remove(f); delete(f) }
				clear(&export_tmp_files)
				set_toast("GPU falhou — tentando por CPU…")
				start_export(export_out, false)
				// se o retry armou, NÃO limpa flags de cancel/pause de novo abaixo
				// (start_export já zerou); só sai do bloco de conclusão desta corrida
			} else {
				// mostra a CAUSA (última linha de stderr do ffmpeg) em vez do genérico: sem
				// console, era a única informação e ela ia direto para o lixo
				if export_err_n > 0 do set_toast(rl.TextFormat("Falha na exportação: %s", cs(string(export_err[:export_err_n]))))
				else                do set_toast("Falha na exportação")
				export_gpu_fallback = false
			}
		}
		export_cancel = false; export_paused = false
		// temps só somem se NÃO rearmamos o export (o retry reusa/recria a lista)
		if !intrinsics.atomic_load(&export_run) {
			for f in export_tmp_files { os.remove(f); delete(f) } // remove os PNGs de texto
			clear(&export_tmp_files)
		}
	}
	if running do export_was_running = true
}
