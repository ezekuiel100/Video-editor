package main

import rl "vendor:raylib"
import "base:intrinsics"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import win "core:sys/windows"

// --- exportação (render via ffmpeg -filter_complex, thread de fundo) ---
export_run:   bool // atômico: exportando
export_pct:   f32  // progresso 0..1 (escrito pela thread, lido no draw)
export_ok:    bool // resultado (válido quando export_run cai p/ false)
export_total: f32  // duração total (p/ calcular o %)
export_out:   string // caminho do arquivo de saída (heap)
export_thr:   ^thread.Thread
export_job:   win.HANDLE // mata o ffmpeg do export ao fechar o app
export_r:     ^os.File   // ponta de leitura do -progress (stderr do ffmpeg)
export_ps:    os.Process
// o HANDLE de export_ps deixa de ser válido no process_wait (o core:os o fecha lá), mas
// export_run só cai depois — pausar/cancelar nessa fresta operavam sobre um handle morto,
// que o Windows pode ter reciclado para outro processo. O mutex fecha a janela: o worker
// derruba `export_ps_ok` ANTES de esperar, e cancel/pause só tocam no handle segurando-o.
export_ps_mu: sync.Mutex
export_ps_ok: bool
// última linha de ERRO do ffmpeg (stderr). O `-progress pipe:2` mistura progresso e erro no
// mesmo fluxo e o worker descartava tudo que não era progresso: sem console, a causa real de
// uma falha se perdia por completo e o usuário só via "Falha na exportação".
export_err:   [240]u8
export_err_n: int
export_was_running: bool  // (main) p/ avisar quando terminar
export_gpu:   bool = false // codificar com NVENC (GPU); default false até probe_nvenc no startup
export_nvenc_ok: bool // GPU NVIDIA com h264_nvenc utilizável (medido 1× no startup)
export_used_gpu: bool // esta corrida pediu NVENC — se falhar, tenta de novo por CPU uma vez
export_gpu_fallback: bool // true = a corrida atual JÁ é o retry por CPU (não re-tenta)
// pedido de export adiado: o botão do modal vive no draw (GL), mas o start real roda no
// update — evita spawn/pipe/thread no meio do BeginDrawing e deixa o render_text_png
// (também GL) fora da passagem de desenho da UI.
export_pending: bool
export_pending_path: string // heap, dono; caminho de saída enfileirado
export_pending_gpu: bool
// QUALIDADE da exportação: define o CQ (NVENC) / CRF (x264) — nº maior = arquivo menor.
// Auto = qualidade alta com TETO de bitrate ≈ o da fonte (mantém o arquivo ~ tamanho do
// original em vez de inchar). Padrão: Média (equilíbrio tamanho×qualidade).
ExportQual :: enum { High, Medium, Low, Auto }
export_qual: ExportQual = .Medium
// FORMATO/codec de saída (barra lateral do modal de exportar):
//   MP4 = H.264 (máx. compatibilidade), HEVC = H.265 (menor, menos compatível),
//   WEBM = VP9 (web; sempre CPU, mais lento), MP3 = só a trilha de áudio.
ExportFmt :: enum { MP4, HEVC, WEBM, MP3 }
export_fmt: ExportFmt = .MP4
export_fmt_ext :: proc(f: ExportFmt) -> string {
	switch f {
	case .WEBM: return ".webm"
	case .MP3:  return ".mp3"
	case .MP4, .HEVC: return ".mp4"
	}
	return ".mp4"
}

// editor.exe -dump-export projeto.ovp [saida.mp4]
// monta o MESMO comando do botão Exportar (dry, sem GL) e roda o ffmpeg com loglevel info
// p/ ver a causa real — o toast da UI só guarda a última linha (quase sempre o -22 genérico).
dump_export_cli :: proc() -> bool {
	if len(os.args) < 3 || os.args[1] != "-dump-export" do return false
	ovp := os.args[2]
	out := len(os.args) >= 4 ? os.args[3] : "dump_out.mp4"
	data, rerr := os.read_entire_file(ovp, context.temp_allocator)
	if rerr != nil {
		fmt.eprintfln("nao abriu %s: %v", ovp, rerr)
		return true
	}
	lines := strings.split_lines(string(data), context.temp_allocator)
	if len(lines) < 1 || strings.trim_space(lines[0]) != "OVP1" {
		fmt.eprintfln("ovp invalido")
		return true
	}
	ar_auto = false
	mpaths := make([dynamic]string, context.temp_allocator)
	Seg2 :: struct { fields: [OVP_SEG_N]f32 }
	segd := make([dynamic]Seg2, context.temp_allocator)
	res_w, res_h := 1920, 1080
	lnv := 3
	li := 1
	for li < len(lines) {
		ln := strings.trim_space(lines[li]); li += 1
		if ln == "" do continue
		toks := strings.fields(ln, context.temp_allocator)
		if len(toks) == 0 do continue
		switch toks[0] {
		case "res":
			if len(toks) >= 3 {
				res_w = strconv.parse_int(toks[1]) or_else res_w
				res_h = strconv.parse_int(toks[2]) or_else res_h
			}
		case "tracks":
			if len(toks) >= 2 do lnv = strconv.parse_int(toks[1]) or_else lnv
		case "media":
			n := len(toks) >= 2 ? (strconv.parse_int(toks[1]) or_else 0) : 0
			for _ in 0 ..< n {
				if li < len(lines) {
					append(&mpaths, strings.trim_space(lines[li]))
					li += 1
				}
			}
		case "seg":
			n := len(toks) >= 2 ? (strconv.parse_int(toks[1]) or_else 0) : 0
			for _ in 0 ..< n {
				if li >= len(lines) do break
				ft := strings.fields(strings.trim_space(lines[li]), context.temp_allocator); li += 1
				s: Seg2
				s.fields[14] = 1
				for k in 0 ..< min(OVP_SEG_N, len(ft)) do s.fields[k] = f32(strconv.parse_f64(ft[k]) or_else 0)
				append(&segd, s)
			}
		}
	}
	nclips = 0
	nsegs = 0
	nfx = 0
	g_nv = clamp(lnv, 1, MAXV)
	set_proj_res(res_w, res_h)
	for p in mpaths {
		if strings.has_prefix(p, "#") do continue
		i := nclips
		if i >= MAX_CLIPS do break
		clips[i] = Clip{}
		clips[i].path = p
		dur, _, vw, vh, _ := video_probe(p)
		clips[i].dur = dur
		clips[i].vw = vw
		clips[i].vh = vh
		clips[i].src_audio = probe_has_audio(p)
		intrinsics.atomic_store(&clips[i].probed, true)
		nclips += 1
		fmt.printfln("media %d: %s dur=%.3f %dx%d audio=%v", i, p, dur, vw, vh, clips[i].src_audio)
	}
	for s in segd {
		f := s.fields
		si := add_seg(int(f[0]), f[2], f[3], f[4], int(f[1]))
		if si >= 0 do seg_apply_ovp_fields(&segs[si], f)
	}
	fmt.printfln("proj %dx%d nclips=%d nsegs=%d total=%.3f", proj_w, proj_h, nclips, nsegs, timeline_dur())
	args, graph, ok := export_build_args(out, false, true)
	if !ok {
		fmt.eprintfln("export_build_args recusou")
		return true
	}
	fmt.println("--- GRAPH ---")
	fmt.println(graph)
	fmt.println("--- ARGS ---")
	for a in args do fmt.println(a)
	fg_path := fmt.tprintf("%s_dump_fgraph.txt", AUDIO_BASE)
	if os.write_entire_file(fg_path, transmute([]u8)graph) != nil {
		fmt.eprintfln("falha ao gravar %s", fg_path)
		return true
	}
	run := make([dynamic]string, context.temp_allocator)
	for a in args {
		if a == "-filter_complex_script" {
			append(&run, a)
			continue
		}
		if strings.contains(a, "_fgraph.txt") {
			append(&run, fg_path)
			continue
		}
		if a == "pipe:1" {
			append(&run, fmt.tprintf("%s_dump_prev.raw", AUDIO_BASE))
			continue
		}
		if a == "-loglevel" {
			append(&run, a, "warning")
			continue
		}
		if a == "error" && len(run) > 0 && run[len(run)-1] == "warning" do continue
		append(&run, a)
	}
	fmt.printfln("--- RUN ffmpeg loglevel warning ---")
	state, stdout, stderr, e := os.process_exec(os.Process_Desc{ command = run[:] }, context.temp_allocator)
	fmt.printfln("exec_err=%v exited=%v code=%d stdout=%d", e, state.exited, state.exit_code, len(stdout))
	fmt.println("--- STDERR ---")
	fmt.println(string(stderr))
	return true
}
// prévia AO VIVO da exportação: um 2º ramo do filtro (split) manda frames rgb24
// reduzidos pelo stdout; a thread os lê e a main sobe na textura do overlay.
PREV_W :: i32(480)
PREV_H :: i32(270)
PREV_BYTES :: int(PREV_W) * int(PREV_H) * 3
export_prev_r:    ^os.File        // stdout do ffmpeg: frames rgb24 da prévia
export_prev_thr:  ^thread.Thread
export_prev_a:    []u8            // buffer duplo (evita rasgo entre worker e main)
export_prev_b:    []u8
export_prev_pub:  int = -1        // atômico: slot publicado (0=a, 1=b, -1=nenhum)
export_prev_wslot: int            // (worker) slot que está preenchendo
export_prev_seq:  int             // atômico: nº de frames publicados
export_prev_last: int             // (main) último seq já subido na textura
export_prev_tex:  rl.Texture2D
export_prev_tex_ok: bool
export_paused: bool // (main) ffmpeg suspenso
export_cancel: bool // (main) exportação cancelada pelo usuário (não é falha)
export_tmp_files: [dynamic]string // PNGs de texto gerados p/ o export (removidos no fim)
g_exp_pause_btn:  rl.Rectangle // rects dos botões do overlay (draw preenche, update lê)
g_exp_cancel_btn: rl.Rectangle

// dimensões de saída a partir da proporção do projeto (lado menor = 1080)
export_dims :: proc() -> (w, h: int) { return proj_w, proj_h } // resolução do projeto (Config. do Projeto)

// thread de fundo: lê o -progress do ffmpeg e atualiza export_pct; espera o fim
// a linha é do `-progress` (chave=valor em minúsculas, ex.: "frame=12", "speed=1.3x") e não
// uma mensagem de erro? As do ffmpeg vêm como "[libx264 @ ...] ..." ou texto corrido.
// (as chaves têm DÍGITO: o ffmpeg emite `stream_0_0_q=` em todo bloco de progresso, uma por
// stream de saída. Sem aceitar dígito, essa linha era classificada como erro e sobrescrevia
// o export_err a cada intervalo — o toast de falha mostrava "stream_0_0_q=29.0" no lugar da
// causa, e export_err_n > 0 ficava sempre verdadeiro.)
// atualiza export_pct a partir de uma linha `-progress`. Aceita out_time_us e
// out_time_ms (ffmpeg troca conforme a versão) e ignora N/A / parse falho.
export_apply_progress :: proc(s: string) -> bool {
	us_key :: "out_time_us="
	ms_key :: "out_time_ms="
	val: f64
	ok: bool
	if strings.has_prefix(s, us_key) {
		if v, p := strconv.parse_i64(s[len(us_key):]); p {
			val = f64(v) / 1e6
			ok = true
		}
	} else if strings.has_prefix(s, ms_key) {
		// ffmpeg: out_time_ms é o mesmo valor em microsegundos (nome legado)
		if v, p := strconv.parse_i64(s[len(ms_key):]); p {
			val = f64(v) / 1e6
			ok = true
		}
	} else {
		return false
	}
	if !ok || export_total <= 0 || val < 0 do return true
	export_pct = clamp(f32(val / f64(export_total)), 0, 1)
	return true
}

progress_line :: proc(s: string) -> bool {
	for c, i in s {
		if c == '=' do return i > 0
		if !((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_') do return false
	}
	return false
}

// linhas de rodapé do ffmpeg 7+ (thread do muxer). Não são a causa — a causa veio ANTES.
export_err_noise :: proc(s: string) -> bool {
	return strings.contains(s, "Terminating thread") ||
		strings.contains(s, "Task finished with error code") ||
		strings.contains(s, "Error muxing a packet") ||
		strings.contains(s, "Nothing was written into output file") ||
		strings.contains(s, "Error submitting a packet to the muxer")
}

export_worker :: proc() {
	buf: [4096]u8
	line: [512]u8
	ll := 0
	for {
		n, e := os.read(export_r, buf[:])
		if n > 0 {
			for k in 0 ..< n {
				ch := buf[k]
				if ch == '\n' {
					s := string(line[0:ll])
					if len(s) > 0 && s[len(s)-1] == '\r' do s = s[:len(s)-1] // Windows: -progress usa CRLF
					if export_apply_progress(s) {
						// out_time_* atualizou o %
					} else if !progress_line(s) && !export_err_noise(s) {
						// guarda a PRIMEIRA linha útil: o ffmpeg 7+ termina com
						// "Terminating thread ... -22", que sobrescrevia a causa
						// ("non monotonically increasing dts", "height not divisible"...).
						if export_err_n == 0 {
							n2 := min(len(s), len(export_err))
							copy(export_err[:], s[:n2]); export_err_n = n2
						}
					}
					ll = 0
				} else if ll < len(line) { line[ll] = ch; ll += 1 }
			}
		}
		if n <= 0 || e != nil do break
	}
	os.close(export_r)
	// o process_wait FECHA o handle: marca como inválido antes, para um cancelar/pausar
	// concorrente não operar sobre ele (ou sobre um PID já reciclado pelo Windows)
	sync.mutex_lock(&export_ps_mu); export_ps_ok = false; sync.mutex_unlock(&export_ps_mu)
	state, _ := os.process_wait(export_ps)
	export_ok = state.exited && state.exit_code == 0
	export_pct = 1
	if export_job != nil { win.CloseHandle(export_job); export_job = nil }
	intrinsics.atomic_store(&export_run, false)
}

// thread de fundo: lê os frames rgb24 da prévia (stdout) e publica em buffer duplo;
// a main sobe o último na textura. Termina no EOF (o ffmpeg fecha ao acabar).
export_preview_worker :: proc() {
	frame := make([]u8, PREV_BYTES); defer delete(frame)
	got := 0
	buf: [65536]u8
	for {
		n, e := os.read(export_prev_r, buf[:])
		if n > 0 {
			off := 0
			for off < n {
				take := min(PREV_BYTES - got, n - off)
				copy(frame[got:], buf[off:off+take])
				got += take; off += take
				if got == PREV_BYTES { // frame completo: publica no slot livre
					s := export_prev_wslot
					copy(s == 0 ? export_prev_a : export_prev_b, frame)
					intrinsics.atomic_store(&export_prev_pub, s)
					intrinsics.atomic_add(&export_prev_seq, 1)
					export_prev_wslot = 1 - s
					got = 0
				}
			}
		}
		if n <= 0 || e != nil do break
	}
	os.close(export_prev_r)
}

// acrescenta os fades de alpha da transição (dissolver) ao fim da cadeia do clip no export
// As DUAS rampas, encadeadas — não a maior das duas. O dissolver e o fade preto têm origens
// diferentes: o dissolver é CENTRADO no corte (começa em start2 = start - d/2) e o fade preto
// começa na borda do CLIPE. A prévia aplica os dois e MULTIPLICA (op = opacity × p × bfade);
// o export escolhia um `max` e emitia uma rampa só, então com dissolver + fade de entrada no
// mesmo clipe os dois caminhos divergiam muito (no instante do corte a prévia mostrava preto
// e o arquivo mostrava 50%). Dois `fade:alpha=1` em sequência multiplicam os fatores —
// conferido rodando o ffmpeg —, logo isto reproduz a composição do preview.
// O `enable` do fade preto de ENTRADA não é decoração: `fade=t=in:st=S` zera tudo que vem
// ANTES de S, e o lead-in do dissolver (o clipe aparece meio segundo antes do próprio start)
// cai justamente aí. Sem ele, um clipe com dissolver E fade de entrada sumia por completo na
// primeira metade do dissolver no arquivo, enquanto a prévia o mostrava surgindo — ela isenta
// o lead-in do fade preto (`if vt >= sg.start` no draw_seg_composited). Com `enable=gte(t,S)`
// o filtro fica em passagem antes de S, que é exatamente a isenção da prévia. Só faz sentido
// quando existe lead-in, daí o par com `din`.
export_trans_fades :: proc(fb: ^strings.Builder, start2, tend, din, dout: f32, sstart, send, vin, vout: f32) {
	if din  > 0.01 do fmt.sbprintf(fb, ",fade=t=in:st=%.3f:d=%.3f:alpha=1", start2, din)
	if dout > 0.01 do fmt.sbprintf(fb, ",fade=t=out:st=%.3f:d=%.3f:alpha=1", tend-dout, dout)
	if vin  > 0.01 {
		fmt.sbprintf(fb, ",fade=t=in:st=%.3f:d=%.3f:alpha=1", sstart, vin)
		if din > 0.01 do fmt.sbprintf(fb, ":enable='gte(t\\,%.3f)'", sstart)
	}
	if vout > 0.01 do fmt.sbprintf(fb, ",fade=t=out:st=%.3f:d=%.3f:alpha=1", send-vout, vout)
}

// Dissolve orgânico = os 9 frames: A segura; B entra como overlay fantasma no
// quadro inteiro; A some no fim. Sem janela/íris. invert=true = clipe que SAI.
export_ghost_mask :: proc(fb: ^strings.Builder, start2, d: f32, persist: bool, invert := false) {
	P: string
	if persist {
		P = "0.35"
	} else {
		du := max(d, 0.001)
		P = fmt.tprintf("min(1\\,max(0\\,(T-%.3f)/%.3f))", start2, du)
	}
	if invert {
		// hold até 38%, some até 98%
		U := fmt.tprintf("min(1\\,max(0\\,((%s)-0.38)/0.60))", P)
		M := fmt.tprintf("(1-((%s)*(%s)*(3-2*(%s))))", U, U, U)
		fmt.sbprintf(fb, ",format=rgba,geq=r='r(X\\,Y)':g='g(X\\,Y)':b='b(X\\,Y)':a='alpha(X\\,Y)*(%s)'", M)
		return
	}
	// B: fade-in nos primeiros 70%
	U := fmt.tprintf("min(1\\,max(0\\,(%s)/0.70))", P)
	M := fmt.tprintf("((%s)*(%s)*(3-2*(%s)))", U, U, U)
	fmt.sbprintf(fb, ",format=rgba,geq=r='r(X\\,Y)':g='g(X\\,Y)':b='b(X\\,Y)':a='alpha(X\\,Y)*(%s)'", M)
}

// EFEITOS DE COR no export: espelha o BULGE_FS (brilho/contraste/saturação -> eq; visual
// P&B/sépia/inverter -> hue/colorchannelmixer/negate; vinheta -> vignette). Aproxima o
// preview (não é pixel-exato, mas visualmente consistente). Nada é adicionado se neutro.
export_color_filters :: proc(fb: ^strings.Builder, sg: Seg) {
	if abs(sg.fx_bright) > 0.001 || abs(sg.fx_contrast) > 0.001 || abs(sg.fx_satur) > 0.001 {
		fmt.sbprintf(fb, ",eq=brightness=%.4f:contrast=%.4f:saturation=%.4f", sg.fx_bright, 1+sg.fx_contrast, 1+sg.fx_satur)
	}
	if abs(sg.fx_temp) > 0.001 { // temperatura: desloca vermelho/azul (aproxima o shader)
		fmt.sbprintf(fb, ",colorbalance=rm=%.3f:bm=%.3f", sg.fx_temp*0.3, -sg.fx_temp*0.3)
	}
	switch int(sg.fx_look + 0.5) {
	case 1: fmt.sbprintf(fb, ",hue=s=0") // P&B
	case 2: fmt.sbprintf(fb, ",colorchannelmixer=0.393:0.769:0.189:0:0.349:0.686:0.168:0:0.272:0.534:0.131") // sépia
	case 3: fmt.sbprintf(fb, ",negate") // inverter
	}
	if sg.fx_vignette > 0.001 {
		// vinheta do ffmpeg: ângulo maior = escurece mais. Mapeia 0..1 -> ~PI/6..PI/2.5.
		fmt.sbprintf(fb, ",vignette=angle=%.4f", 0.52 + sg.fx_vignette*0.74)
	}
}

// dimensões (pares) do segmento após escala no export — MESMA fórmula usada ao montar o
// filtro; extraída p/ gerar os mapas do bulge com o tamanho exato do stream no remap.
seg_export_dims :: proc(i, W, H: int) -> (int, int) {
	sg := segs[i]
	sc := sg.scale <= 0 ? f32(1) : sg.scale
	_, _, crw, crh := seg_crop(i)
	crop_aspect := (crw * clip_ar(&clips[sg.src])) / crh // aspecto em pixels da região (frações × aspecto da fonte)
	fitW := min(f32(W), f32(H)*crop_aspect); fitH := fitW/crop_aspect
	segW := int(fitW*sc + 0.5); segH := int(fitH*sc + 0.5)
	segW -= segW%2; segH -= segH%2
	if segW < 2 do segW = 2
	if segH < 2 do segH = 2
	return segW, segH
}

// gera os mapas de deslocamento (xmap/ymap) do efeito Distorção p/ o filtro `remap` do
// ffmpeg no export. Reproduz a MESMA matemática do BULGE_FS (WYSIWYG: export == preview).
// PGM P5 16-bit big-endian, w×h; o VALOR de cada pixel = coordenada da FONTE a amostrar.
// remap depois é nativo/rápido (o geq equivalente seria ~20x mais lento que tempo real).
write_bulge_maps :: proc(str, cx, cy, rad: f32, w, h: int, xpath, ypath: string) -> bool {
	if w < 2 || h < 2 do return false
	asp := f32(w) / f32(h)
	hdr := fmt.tprintf("P5\n%d %d\n65535\n", w, h)
	xb := make([dynamic]u8, 0, len(hdr) + w*h*2, context.temp_allocator)
	yb := make([dynamic]u8, 0, len(hdr) + w*h*2, context.temp_allocator)
	for b in transmute([]u8)hdr { append(&xb, b); append(&yb, b) }
	for yy in 0 ..< h {
		ly := f32(yy) / f32(h)
		dy := ly - cy
		for xx in 0 ..< w {
			lx := f32(xx) / f32(w)
			dx := lx - cx
			dist := math.sqrt((dx*asp)*(dx*asp) + dy*dy)
			f := f32(0)
			if dist < rad { t := 1 - dist/rad; f = str*t*t }
			ix := clamp(int((lx - dx*f)*f32(w) + 0.5), 0, w-1)
			iy := clamp(int((ly - dy*f)*f32(h) + 0.5), 0, h-1)
			append(&xb, u8(ix >> 8), u8(ix & 0xff)) // 16-bit big-endian (PGM)
			append(&yb, u8(iy >> 8), u8(iy & 0xff))
		}
	}
	return os.write_entire_file(xpath, xb[:]) == nil && os.write_entire_file(ypath, yb[:]) == nil
}

// trecho da FONTE que o segmento i consome: [t0,t1] mais o quanto falta congelar nas pontas
// quando não há footage p/ os handles do dissolver. FONTE ÚNICA DA VERDADE — o mesmo cálculo
// alimenta o `-ss` do input E o `trim` do filtro; se os dois divergissem, o vídeo exportado
// sairia deslocado/dessincronizado SEM erro nenhum. hd/tl = esticões da transição (0 fora dela).
seg_src_span :: proc(i: int, hd, tl: f32) -> (t0, t1, freeze_hd, freeze_tl: f32) {
	sg := segs[i]
	cc := &clips[sg.src]
	sp := sg.speed <= 0 ? f32(1) : sg.speed
	if cc.is_img do return 0, sg.dur + hd + tl, 0, 0 // imagem: input em loop, sempre do 0
	head_avail := sg.in_off                             // footage antes do in-point
	tail_avail := max(0, cc.dur - (sg.in_off + sg.dur*sp)) // footage depois do out-point
	real_hd := min(hd, head_avail); real_tl := min(tl, tail_avail)
	return sg.in_off - real_hd, sg.in_off + sg.dur*sp + real_tl, hd - real_hd, tl - real_tl
}

// CreateProcessW (que o os.process_start usa passando tudo em lpCommandLine) trunca a linha
// de comando em 32767 wchars. CMDLINE_MAX deixa margem para o quoting que o Odin aplica.
CMDLINE_MAX :: 30000
// comprimento aproximado da linha que o Windows vai montar: cada argumento entra entre
// aspas e separado por espaço, daí os 3 chars de sobrecarga por argumento.
cmdline_len :: proc(args: [dynamic]string) -> int {
	n := 0
	for a in args do n += len(a) + 3
	return n
}

// monta a LINHA DE COMANDO inteira do ffmpeg (inputs + filtergraph + codecs + saída)
// e devolve sem executar nada. Separada do start_export para poder ser TESTADA como texto:
// erro aqui não aborta coisa nenhuma — o ffmpeg aceita um grafo com o trim deslocado, sai
// com código 0 e entrega um arquivo válido com o áudio fora do lugar. Ver export_test.odin.
//
// dry=true: não toca disco nem GPU — pula o render dos PNGs de texto (que precisa de GL) e
// a escrita dos mapas do remap, seguindo como se os dois tivessem dado certo. O comando
// montado é o MESMO, então dá p/ conferir o grafo sem janela de raylib nem temporários.
//
// O grafo sai TAMBÉM como segundo retorno porque ele não viaja mais dentro de `args`: vai
// num arquivo, passado por -filter_complex_script (ver lá embaixo). Sem isso os testes não
// teriam como inspecionar o filtergraph.
export_build_args :: proc(out: string, gpu: bool, dry := false) -> (args: [dynamic]string, graph: string, ok: bool) {
	total := timeline_dur()
	if total <= 0 { set_toast("Nada na timeline para exportar"); return nil, "", false }
	// MÍDIA AINDA IMPORTANDO: recusa em vez de exportar um buraco preto. A guarda mora aqui
	// (e não só no botão) porque este é o ponto por onde TODA exportação passa — e é o que os
	// testes exercitam. Rota real: abrir um .ovp e apertar Exportar antes do bin terminar.
	if imp := segs_importing(); imp > 0 {
		set_toast(rl.TextFormat("%d clipe(s) ainda importando — espere terminar", i32(imp)))
		return nil, "", false
	}
	W, H := export_dims()
	want_video := export_fmt != .MP3 // MP3 = só áudio: pula todo o ramo de vídeo do filtro

	args = make([dynamic]string, context.temp_allocator)
	// -nostdin: app GUI não tem stdin útil; sem isto o ffmpeg às vezes fica à espera
	// de um 'q' no handle herdado e a exportação nunca acaba.
	// max_muxing_queue_size vai NAS SAÍDAS (não aqui): é opção de output; antes do
	// 1º -i o ffmpeg recusa com "cannot be applied to input url".
	append(&args, "ffmpeg", "-y", "-nostdin", "-hide_banner", "-loglevel", "error",
		"-progress", "pipe:2", "-nostats")

	// clipes de TEXTO: renderiza cada um num PNG RGBA do tamanho do canvas (já
	// posicionado/estilizado) p/ virar overlay. Feito ANTES de montar os inputs.
	if !dry {
		// os.remove junto: `delete` solta só a string. O bloco de conclusão do export apaga
		// os arquivos, mas quando a tentativa anterior morreu antes dele (ffmpeg fora do PATH,
		// comando recusado) os temporários ficavam no %TEMP% até o sweep do próximo lançamento.
		for f in export_tmp_files { os.remove(f); delete(f) }
		clear(&export_tmp_files)
	}
	text_png: [MAX_SEGS]string
	CapOv :: struct { inp: int, t0, t1: f32, png: string }
	cap_ovs: [MAX_SEGS][dynamic]CapOv
	for i in 0 ..< MAX_SEGS do cap_ovs[i] = make([dynamic]CapOv, context.temp_allocator)
	for i in 0 ..< nsegs {
		if !want_video do break // MP3: sem overlay de texto
		if !seg_ready(i) do continue
		c := &clips[segs[i].src]
		if !c.is_text do continue
		if c.is_caps do continue // legendas: um PNG por fala, montado com os inputs
		p := fmt.tprintf("%s_%d_%d_txt%d.png", AUDIO_BASE, u32(win.GetCurrentProcessId()), c.aid, i)
		if dry || render_text_png(c, segs[i], p) { // dry: sem GL, finge que o PNG saiu
			text_png[i] = p
			if !dry do append(&export_tmp_files, strings.clone(p))
		}
	}

	// transições CENTRADAS: cada B com d=trans estica a cabeça `d/2` (thead) e o clipe de
	// saída A estica a cauda `d/2` (ttail); os dois fazem crossfade sobre `d` s no corte.
	// Dissolve orgânico: A e B esticam a janela, mas o mix (opacidade + fumaça) vai no
	// geq — sem fade=t=in/out do dissolver limpo. ghost_out_* marca o clipe que SAI.
	thead: [MAX_SEGS]f32; ttail: [MAX_SEGS]f32; tfin: [MAX_SEGS]f32; tfout: [MAX_SEGS]f32
	ghost_out_d: [MAX_SEGS]f32; ghost_out_t0: [MAX_SEGS]f32
	for i in 0 ..< nsegs {
		d := seg_trans(i)
		if d > 0 {
			thead[i] = max(thead[i], d/2)
			if seg_ghost(i) {
				if a := trans_prev(i); a >= 0 {
					ttail[a] = max(ttail[a], d/2)
					ghost_out_d[a] = max(ghost_out_d[a], d)
					ghost_out_t0[a] = segs[i].start - d/2
				}
			} else {
				tfin[i] = max(tfin[i], d)
				if a := trans_prev(i); a >= 0 { ttail[a] = max(ttail[a], d/2); tfout[a] = max(tfout[a], d) }
			}
		}
	}

	seg_inp: [MAX_SEGS]int
	bulge_xin: [MAX_SEGS]int // input do xmap do bulge (-1 = sem efeito); ymap = bulge_yin
	bulge_yin: [MAX_SEGS]int
	bulge_anim: [MAX_SEGS]bool // wobble: mapas são sequência em loop (não 1 frame estático)
	fx_xin: [MAX_FX]int; fx_yin: [MAX_FX]int // mapas de remap dos clipes de efeito de DISTORÇÃO
	for i in 0 ..< MAX_SEGS { seg_inp[i] = -1; bulge_xin[i] = -1; bulge_yin[i] = -1 }
	for k in 0 ..< MAX_FX { fx_xin[k] = -1; fx_yin[k] = -1 }
	inp := 0
	for i in 0 ..< nsegs {
		if !seg_ready(i) do continue
		c := &clips[segs[i].src]
		if !want_video && !c.src_audio do continue // MP3: só fontes com áudio viram input
		if c.is_text && c.is_caps && len(c.caps) > 0 {
			// uma entrada por fala visível neste segmento (PNG WYSIWYG + enable)
			sgc := segs[i]
			spd := sgc.speed <= 0 ? f32(1) : sgc.speed
			src0 := sgc.in_off
			src1 := sgc.in_off + sgc.dur * spd
			for qi in 0 ..< len(c.caps) {
				q := c.caps[qi]
				if q.t1 <= src0 + 0.01 || q.t0 >= src1 - 0.01 do continue
				t0 := sgc.start + (max(q.t0, src0) - src0) / spd
				t1 := sgc.start + (min(q.t1, src1) - src0) / spd
				if t1 - t0 < 0.04 do continue
				p := fmt.tprintf("%s_%d_%d_cap%d_%d.png", AUDIO_BASE, u32(win.GetCurrentProcessId()), c.aid, i, qi)
				tmp := c^
				tmp.is_caps = false
				tmp.text = q.text
				if dry || render_text_png(&tmp, sgc, p) {
					append(&args, "-loop", "1", "-framerate", "30", "-t", fmt.tprintf("%.3f", t1 - t0))
					append(&args, "-i", p)
					append(&cap_ovs[i], CapOv{ inp, t0, t1, p })
					inp += 1
					if !dry do append(&export_tmp_files, strings.clone(p))
				}
			}
			continue
		}
		if c.is_text { // overlay de texto = PNG estático (como imagem); pula se o render falhou
			if text_png[i] == "" do continue
			append(&args, "-loop", "1", "-framerate", "30", "-t", fmt.tprintf("%.3f", segs[i].dur + thead[i] + ttail[i]))
			append(&args, "-i", text_png[i])
			seg_inp[i] = inp; inp += 1
			continue
		}
		if c.is_img { // imagem: repete o frame por dur (+ handles da transição) segundos
			append(&args, "-loop", "1", "-framerate", "30", "-t", fmt.tprintf("%.3f", segs[i].dur + thead[i] + ttail[i]))
		} else {
			// SEEK NA ENTRADA (-ss ANTES do -i): o ffmpeg pula pro keyframe e decodifica só até
			// o ponto pedido. Antes o corte era SÓ no filtro (trim), o que obriga a DECODIFICAR
			// O ARQUIVO DESDE O ZERO até o in-point — num trecho aos 60min de uma live de 4h a
			// exportação levava minutos só p/ COMEÇAR (medido: >120s, contra 0.7s com -ss).
			// `-copyts` PRESERVA os timestamps originais: sem ele o seek rebaseia p/ zero e todo
			// `trim`/`atrim` do grafo (que usa tempo ABSOLUTO da fonte) teria de ser deslocado à
			// mão — é onde um erro dessincronizaria áudio/vídeo em silêncio. Com -copyts o grafo
			// fica INTACTO. Verificado: vídeo bit-idêntico (inclusive com múltiplos inputs); o
			// áudio muda só ~-93 dBFS (arredondamento do decoder AAC ao iniciar noutro ponto).
			// Cada segmento tem seu PRÓPRIO input, então o -ss é por segmento, sem interferência.
			// Recua um keyframe (SEEK_PAD) do trecho pedido: garante que o trim tenha material
			// antes do in-point mesmo se o keyframe cair depois dele.
			SEEK_PAD :: f32(2)
			t0, _, _, _ := seg_src_span(i, thead[i], ttail[i])
			if ss := t0 - SEEK_PAD; ss > 0.001 do append(&args, "-ss", fmt.tprintf("%.3f", ss), "-copyts")
		}
		append(&args, "-i", c.path)
		seg_inp[i] = inp; inp += 1
		// EFEITO Distorção: mapas xmap/ymap viram inputs p/ o remap (tamanho segW×segH).
		// Estático = 1 par (remap repete o frame). Wobble = 1 PERÍODO de mapas em sequência,
		// consumidos em loop (stream_loop) sincronizados ao vídeo em fps=30.
		if want_video && !c.is_audio && !segs[i].aonly && bulge_active(segs[i]) {
			sg := segs[i]
			segW, segH := seg_export_dims(i, W, H)
			cx := clamp(0.5 + sg.bulge_x, 0, 1); cy := clamp(0.5 + sg.bulge_y, 0, 1)
			rad := sg.bulge_r <= 0 ? BULGE_R_DEF : sg.bulge_r
			pid := u32(win.GetCurrentProcessId())
			if abs(sg.wobble) < 0.001 { // ESTÁTICO: 1 par de mapas
				xp := fmt.tprintf("%s_%d_%d_bx%d.pgm", AUDIO_BASE, pid, c.aid, i)
				yp := fmt.tprintf("%s_%d_%d_by%d.pgm", AUDIO_BASE, pid, c.aid, i)
				if dry || write_bulge_maps(sg.bulge, cx, cy, rad, segW, segH, xp, yp) {
					append(&args, "-i", xp); bulge_xin[i] = inp; inp += 1
					append(&args, "-i", yp); bulge_yin[i] = inp; inp += 1
					if !dry { append(&export_tmp_files, strings.clone(xp)); append(&export_tmp_files, strings.clone(yp)) }
				}
			} else { // WOBBLE: N pares (1 período) numerados _%03d.pgm
				hz := sg.wobble_speed <= 0 ? WOBBLE_HZ_DEF : sg.wobble_speed
				N := clamp(int(30/hz + 0.5), 2, 90) // frames por período (@30fps), limitado
				okall := true
				for k in 0 ..< N {
					s := bulge_at(sg, f32(k)/30)
					xk := fmt.tprintf("%s_%d_%d_bx%d_%03d.pgm", AUDIO_BASE, pid, c.aid, i, k)
					yk := fmt.tprintf("%s_%d_%d_by%d_%03d.pgm", AUDIO_BASE, pid, c.aid, i, k)
					if !(dry || write_bulge_maps(s, cx, cy, rad, segW, segH, xk, yk)) { okall = false; break }
					if !dry { append(&export_tmp_files, strings.clone(xk)); append(&export_tmp_files, strings.clone(yk)) }
				}
				if okall {
					segsec := sg.dur + thead[i] + ttail[i] + 0.3
					loops := int(segsec*30)/N + 2 // repetições p/ cobrir todo o segmento (+ folga)
					xpat := fmt.tprintf("%s_%d_%d_bx%d_%%03d.pgm", AUDIO_BASE, pid, c.aid, i)
					ypat := fmt.tprintf("%s_%d_%d_by%d_%%03d.pgm", AUDIO_BASE, pid, c.aid, i)
					ls := fmt.tprintf("%d", loops)
					append(&args, "-stream_loop", ls, "-framerate", "30", "-i", xpat); bulge_xin[i] = inp; inp += 1
					append(&args, "-stream_loop", ls, "-framerate", "30", "-i", ypat); bulge_yin[i] = inp; inp += 1
					bulge_anim[i] = true
				}
			}
		}
	}
	// mapas de remap dos clipes de efeito de DISTORÇÃO (tamanho do QUADRO W×H; write_bulge_maps
	// reproduz o BULGE_FS -> export == preview). Estático (wobble no export = intensidade base).
	for k in 0 ..< nfx {
		if !want_video do break // MP3: sem efeitos de vídeo
		e := fxsegs[k]
		if e.kind != FX_DISTORT do continue
		cx := clamp(0.5+e.cx, 0, 1); cy := clamp(0.5+e.cy, 0, 1)
		rad := e.radius <= 0 ? BULGE_R_DEF : e.radius
		pid := u32(win.GetCurrentProcessId())
		xp := fmt.tprintf("%s_%d_fxbx%d.pgm", AUDIO_BASE, pid, k)
		yp := fmt.tprintf("%s_%d_fxby%d.pgm", AUDIO_BASE, pid, k)
		if dry || write_bulge_maps(e.amount, cx, cy, rad, W, H, xp, yp) {
			append(&args, "-i", xp); fx_xin[k] = inp; inp += 1
			append(&args, "-i", yp); fx_yin[k] = inp; inp += 1
			if !dry { append(&export_tmp_files, strings.clone(xp)); append(&export_tmp_files, strings.clone(yp)) }
		}
	}
	if inp == 0 { set_toast("Nada para exportar"); return nil, "", false }

	fb := strings.builder_make(context.temp_allocator)
	if want_video {
	fmt.sbprintf(&fb, "color=c=black:s=%dx%d:r=30:d=%.3f[b0];", W, H, total)
	vlabel := "b0"
	vc := 0
	for t in 0 ..< g_nv {
		if track_hidden[t] do continue // trilha oculta (olho): fora do vídeo exportado (áudio segue mixado)
		for i in 0 ..< nsegs {
			if segs[i].track != t || clips[segs[i].src].is_audio || segs[i].aonly do continue
			if seg_inp[i] < 0 && !(clips[segs[i].src].is_caps && len(cap_ovs[i]) > 0) do continue
			sg := segs[i]
			cc := &clips[sg.src]
			hd := thead[i]; tl := ttail[i]                        // esticões da transição (cabeça/cauda)
			fin := tfin[i]; fout := tfout[i] // dissolver; o fade PRETO (vfin/vfout) vai à parte —
			                                 // são rampas independentes, com origens diferentes
			start2 := sg.start - hd              // começa `hd` s antes (metade do dissolver de entrada)
			tend := sg.start + sg.dur + tl       // termina `tl` s depois (metade do dissolver de saída)
			if cc.is_caps && len(cap_ovs[i]) > 0 {
				for ov in cap_ovs[i] {
					fmt.sbprintf(&fb, "[%d:v]trim=0:%.3f,setpts=PTS-STARTPTS+%.3f/TB,scale=%d:%d,format=rgba",
						ov.inp, ov.t1 - ov.t0, ov.t0, W, H)
					export_trans_fades(&fb, ov.t0, ov.t1, 0, 0, sg.start, sg.start+sg.dur, sg.vfin, sg.vfout)
					fmt.sbprintf(&fb, "[v%d];", vc)
					nb := fmt.tprintf("c%d", vc)
					fmt.sbprintf(&fb, "[%s][v%d]overlay=0:0:enable='between(t\\,%.3f\\,%.3f)':eof_action=pass[%s];",
						vlabel, vc, ov.t0, ov.t1, nb)
					vlabel = nb; vc += 1
				}
				continue
			}
			if cc.is_text { // PNG full-canvas já posicionado: overlay em 0:0}
				fmt.sbprintf(&fb, "[%d:v]trim=0:%.3f,setpts=PTS-STARTPTS+%.3f/TB,scale=%d:%d,format=rgba",
					seg_inp[i], sg.dur+hd+tl, start2, W, H)
				export_trans_fades(&fb, start2, tend, fin, fout, sg.start, sg.start+sg.dur, sg.vfin, sg.vfout)
				if sg.trans_mode == 1 {
					if td := seg_trans(i); td > 0.01 do export_ghost_mask(&fb, start2, td, false)
					else do export_ghost_mask(&fb, start2, 1, true)
				}
				if ghost_out_d[i] > 0.01 do export_ghost_mask(&fb, ghost_out_t0[i], ghost_out_d[i], false, true)
				fmt.sbprintf(&fb, "[v%d];", vc)
				nb := fmt.tprintf("c%d", vc)
				fmt.sbprintf(&fb, "[%s][v%d]overlay=0:0:enable='between(t\\,%.3f\\,%.3f)':eof_action=pass[%s];",
					vlabel, vc, start2, tend, nb)
				vlabel = nb; vc += 1
				continue
			}
			// RECORTE: a região recortada (aspecto crw:crh no modelo 16:9) é ajustada ao canvas
			// como no preview. Sem recorte (1,1) reduz ao box 16:9 de antes.
			crx, cry, crw, crh := seg_crop(i)
			segW, segH := seg_export_dims(i, W, H)
			op := sg.opacity <= 0 ? 1 : sg.opacity
			sp := sg.speed <= 0 ? 1 : sg.speed
			// rgba só quando o overlay PRECISA de alpha (opacidade, giro, fade, dissolver).
			// No recorte simples o yuv420p evita 4 bytes/pixel + conversão no overlay — o
			// caminho mais comum (cortar e exportar) saía ~1.5–2× mais lento à toa.
			need_a := op < 0.999 || abs(sg.rot) > 0.5 || fin > 0.01 || fout > 0.01 || sg.vfin > 0.01 || sg.vfout > 0.01 || sg.trans_mode == 1 || ghost_out_d[i] > 0.01
			pix := need_a ? "rgba" : "yuv420p"
			// vídeo consome (in_off-hd)..(in_off+dur*sp+tl) — hd=pré-roll, tl=pós-roll do
			// dissolver; imagem usa o input em loop. setpts posiciona em start2.
			// FOLGA insuficiente: se a fonte não tem footage p/ o pré/pós-roll, apara só o
			// que existe e CONGELA o resto com tpad (clone do 1º/último frame) — o dissolver
			// funciona entre quaisquer clipes sem o usuário aparar nada. (hd/tl só são >0 em
			// transições, onde sp==1, então a matemática de folga usa dur diretamente.)
			t0, t1, freeze_hd, freeze_tl := seg_src_span(i, hd, tl)
			// trim em tempo ABSOLUTO da fonte: o input pode vir seekado (-ss), mas o -copyts
			// preserva os timestamps, então esta conta independe do seek (ver montagem dos inputs)
			fmt.sbprintf(&fb, "[%d:v]trim=%.3f:%.3f", seg_inp[i], t0, t1)
			if freeze_hd > 0.001 do fmt.sbprintf(&fb, ",tpad=start_mode=clone:start_duration=%.3f", freeze_hd)
			if freeze_tl > 0.001 do fmt.sbprintf(&fb, ",tpad=stop_mode=clone:stop_duration=%.3f", freeze_tl)
			// SEM pillarbox: a fonte de entrada JÁ está no seu aspecto real (nativo, auto-rotacionada
			// pelo ffmpeg). crop/scale/zoompan/bulge operam em frações de iw/ih do conteúdo (não de um
			// quadro 16:9), igual ao preview (WYSIWYG). seg_export_dims dá o box no aspecto da fonte, então
			// o scale final não estica. Vale p/ vídeo E imagem; texto (full-canvas) sai antes por outro caminho.
			// EFEITO Distorção: o remap precisa que o vídeo comece em PTS 0 (casa com os
			// mapas, estáticos ou em loop). Então reseta o PTS (só velocidade) ANTES do
			// remap e REPOSICIONA em start2 DEPOIS. Sem bulge, o setpts já posiciona direto.
			anim := sg.zoom_anim
			// zoom animado e bulge rodam em PTS 0 (o filtro casa com o tempo LOCAL) e a
			// reposição em start2 vem DEPOIS. Sem eles, o setpts já posiciona direto.
			if bulge_xin[i] >= 0 || anim {
				fmt.sbprintf(&fb, ",setpts=(PTS-STARTPTS)/%.5f", sp)
			} else {
				fmt.sbprintf(&fb, ",setpts=(PTS-STARTPTS)/%.5f+%.3f/TB", sp, start2)
			}
			if anim {
				// ZOOM ANIMADO (Pan & Zoom): zoompan anima a região crop_*->crop2_* (frações da
				// fonte) e a escala p/ o box segW×segH (região travada no aspecto de saída = preenche).
				// Espelha seg_crop_at do preview: smoothstep S no tempo local (on = frame de saída).
				// crop não serve aqui (fixa w/h na init); zoompan avalia z/x/y por frame.
				ax, ay, aw, ah := crop_norm(sg.crop_x,  sg.crop_y,  sg.crop_w,  sg.crop_h)
				bx, by, bw, bh := crop_norm(sg.crop2_x, sg.crop2_y, sg.crop2_w, sg.crop2_h)
				// O zoompan amostra iw/z × ih/z: a MESMA fração nos dois eixos. Mas a região do
				// Pan & Zoom está travada no aspecto de SAÍDA (crop_conform_lock_q: h = w*kh, com
				// kh = aspecto_fonte/proj_ar), então com fonte e projeto de aspectos DIFERENTES a
				// fração de altura não é a de largura — usar só `aw` amostrava uma região com a
				// forma da FONTE e o scale final a esticava (o preview mostrava certo, o arquivo
				// saía deformado). Correção: um `pad` estático antes do zoompan muda só o
				// DENOMINADOR das frações e iguala as duas; a área acrescentada nunca é amostrada
				// (a região cabe inteira no quadro original), serve só de espaço morto.
				//   kh >= 1: altura vira ih*kh  -> fração de altura = ah/kh = aw  (z = 1/aw)
				//   kh <  1: largura vira iw/kh -> fração de largura = aw*kh = ah (z = 1/ah)
				// O `pad` nunca encolhe (kh>=1 só cresce em altura, kh<1 só em largura), e o
				// aspecto real da região continua batendo com segW×segH — logo, sem distorção.
				kh := aw > 0.0001 ? ah/aw : f32(1)
				padf := ""
				za, zb := aw, bw // frações que viram o zoom (o eixo que ficou "comum")
				xa, xb := ax, bx
				ya, yb := ay, by
				if kh > 1.002 {
					padf = fmt.tprintf(",pad=w=iw:h=ih*%.6f:x=0:y=0", kh)
					ya = ay/kh; yb = by/kh // y agora é fração da altura JÁ esticada
				} else if kh < 0.998 {
					padf = fmt.tprintf(",pad=w=iw/%.6f:h=ih:x=0:y=0", kh)
					za = ah; zb = bh       // o eixo comum passou a ser a ALTURA
					xa = ax*kh; xb = bx*kh // x agora é fração da largura JÁ esticada
				}
				// posição do frame de saída DENTRO do clipe, em fração de dur — espelha
				// exatamente o `clamp((t - start)/dur, 0, 1)` do seg_crop_at (preview).
				// `on/30` conta a partir do PRIMEIRO frame do stream, que está em
				// start2 = start - hd (o pré-roll do dissolver), e o stream ainda leva o
				// pós-roll `tl` no fim; com folga insuficiente na fonte o tpad acrescenta
				// mais freeze_hd/freeze_tl. Por isso a curva não pode ser on/N sobre o stream:
				// ela saía adiantada em hd e esticada por (dur+hd+tl)/dur, e o smoothstep
				// passava de 1 (deixando de ser monótono — o zoom VOLTAVA no fim do clipe).
				// clip() em vez de dois min/max aninhados; vírgulas escapadas, como o
				// `between` do enable logo abaixo.
				Ls := fmt.tprintf("clip((on/30-%.4f)/%.4f\\,0\\,1)", f64(hd), f64(max(sg.dur, 0.0001)))
				Ss := fmt.tprintf("(%s*%s*(3-2*%s))", Ls, Ls, Ls) // smoothstep (sem vírgulas: seguro no filtergraph)
				zexpr := fmt.tprintf("1/(%.6f+(%.6f)*%s)", za, zb-za, Ss) // zoom = 1/fração da região
				xexpr := fmt.tprintf("(%.6f+(%.6f)*%s)*iw", xa, xb-xa, Ss)  // canto sup-esq X (px da entrada do zoompan)
				yexpr := fmt.tprintf("(%.6f+(%.6f)*%s)*ih", ya, yb-ya, Ss)  // canto sup-esq Y
				// fps=30 ANTES do zoompan: com d=1 ele emite 1 frame de saída por frame de
				// ENTRADA; sem normalizar, fonte !=30fps (ex.: 60fps de stream) muda a duração
				// do vídeo e DESSINCRONIZA do áudio. Normaliza p/ 30fps -> dur*30 frames exatos.
				fmt.sbprintf(&fb, ",fps=30%s,zoompan=z='%s':x='%s':y='%s':d=1:s=%dx%d:fps=30,setpts=PTS+%.3f/TB,format=%s",
					padf, zexpr, xexpr, yexpr, segW, segH, start2, pix)
			} else {
				// RECORTE estático: mantém só a sub-região (frações da fonte) antes de escalar
				if seg_cropped(i) do fmt.sbprintf(&fb, ",crop=iw*%.5f:ih*%.5f:iw*%.5f:ih*%.5f", crw, crh, crx, cry)
				fmt.sbprintf(&fb, ",scale=%d:%d", segW, segH)
				// distorce via remap ANTES da rotação; reposiciona em start2 após.
				if bulge_xin[i] >= 0 {
					fmt.sbprintf(&fb, ",fps=30,format=rgb24[bpre%d];[bpre%d][%d:v][%d:v]remap[brm%d];[brm%d]setpts=PTS+%.3f/TB,format=%s",
						vc, vc, bulge_xin[i], bulge_yin[i], vc, vc, start2, pix)
				} else {
					fmt.sbprintf(&fb, ",format=%s", pix)
				}
			}
			// EFEITOS de cor ANTES da rotação: eq/hue convertem p/ YUV (sem alpha); aplicar
			// depois do rotate=c=none perderia a transparência dos cantos rodados. Aqui o
			// vídeo ainda é opaco, então a conversão não custa nada; o rotate recria o alpha.
			export_color_filters(&fb, sg) // eq/hue/negate/vignette
			if abs(sg.rot) > 0.5 {
				rad := sg.rot * math.PI/180
				fmt.sbprintf(&fb, ",rotate=%.5f:c=none:ow=rotw(%.5f):oh=roth(%.5f)", rad, rad, rad)
			}
			if op < 0.999 do fmt.sbprintf(&fb, ",colorchannelmixer=aa=%.3f", op)
			export_trans_fades(&fb, start2, tend, fin, fout, sg.start, sg.start+sg.dur, sg.vfin, sg.vfout)
			if sg.trans_mode == 1 {
				if td := seg_trans(i); td > 0.01 do export_ghost_mask(&fb, start2, td, false)
				else do export_ghost_mask(&fb, start2, 1, true)
			}
			if ghost_out_d[i] > 0.01 do export_ghost_mask(&fb, ghost_out_t0[i], ghost_out_d[i], false, true)
			fmt.sbprintf(&fb, "[v%d];", vc)
			nb := fmt.tprintf("c%d", vc)
			fmt.sbprintf(&fb, "[%s][v%d]overlay=x='(main_w-overlay_w)/2+(%.4f)*main_w':y='(main_h-overlay_h)/2+(%.4f)*main_h':enable='between(t\\,%.3f\\,%.3f)':eof_action=pass[%s];",
				vlabel, vc, sg.px, sg.py, start2, tend, nb)
			vlabel = nb; vc += 1
		}
		// EFEITOS DE FAIXA ancorados NESTA trilha t: aplicam ao COMPOSTO até aqui (trilhas 0..t =
		// "o que está embaixo" do efeito), ANTES de compor as trilhas acima. Via split+overlay+
		// enable (roda sempre, só aparece em [start,end]). Distorção = remap/lenscorrection; RGB = rgbashift.
		for k in 0 ..< nfx {
			e := fxsegs[k]
			if e.track != t do continue // só os efeitos desta trilha (as de cima aplicam depois)
			es := e.start; ee := e.start + e.dur
			ob := fmt.tprintf("fxb%d", k); op := fmt.tprintf("fxp%d", k); ox := fmt.tprintf("fxx%d", k); oo := fmt.tprintf("fxo%d", k)
			fmt.sbprintf(&fb, "[%s]split[%s][%s];", vlabel, ob, op)
			if e.kind == FX_DISTORT && fx_xin[k] >= 0 {
				// EXATO: remap pelos mapas (mesma matemática do shader). rgb24 antes, como no per-seg.
				fmt.sbprintf(&fb, "[%s]format=rgb24[%spf];[%spf][%d:v][%d:v]remap[%s];", op, op, op, fx_xin[k], fx_yin[k], ox)
			} else {
				fmt.sbprintf(&fb, "[%s]", op)
				switch e.kind {
				case FX_DISTORT: // fallback (mapa falhou): aproximação por lente
					cx := clamp(0.5+e.cx, 0, 1); cy := clamp(0.5+e.cy, 0, 1)
					fmt.sbprintf(&fb, "lenscorrection=cx=%.4f:cy=%.4f:k1=%.4f:k2=0:i=bilinear", cx, cy, -e.amount*0.4)
				case FX_RGB:
					off := fx_rgb_offset(e); rh := off[0]*f32(W); rv := off[1]*f32(H)
					fmt.sbprintf(&fb, "rgbashift=rh=%.1f:rv=%.1f:bh=%.1f:bv=%.1f", rh, rv, -rh, -rv)
				}
				fmt.sbprintf(&fb, "[%s];", ox)
			}
			fmt.sbprintf(&fb, "[%s][%s]overlay=0:0:enable='between(t\\,%.3f\\,%.3f)':eof_action=pass[%s];", ob, ox, es, ee, oo)
			vlabel = oo
		}
	}
	// duplica a saída: [vout] p/ codificar o arquivo; [vpout] reduzido rgb24 (8fps)
	// p/ a prévia ao vivo pelo stdout (a UI mostra enquanto exporta).
	fmt.sbprintf(&fb, "[%s]split=2[vmain][vprv];[vmain]format=yuv420p[vout];[vprv]fps=8,scale=%d:%d:force_original_aspect_ratio=decrease,pad=%d:%d:(ow-iw)/2:(oh-ih)/2,format=rgb24[vpout]",
		vlabel, PREV_W, PREV_H, PREV_W, PREV_H)
	}

	// áudio: cada segmento com áudio não-mudo → trim/volume/fade/adelay → amix
	ac := 0
	for i in 0 ..< nsegs {
		if seg_inp[i] < 0 do continue
		c := &clips[segs[i].src]
		// src_audio (o arquivo tem faixa de áudio), NÃO has_audio (existe um rl.Music
		// carregado agora): este último é estado do PLAYER e é false durante toda a extração,
		// que só termina dezenas de segundos depois de o clipe aparecer pronto no bin — e
		// para sempre, se a extração falhar. Exportar nesse intervalo entregava um arquivo
		// válido e MUDO, sem erro nem aviso. O ffmpeg do export lê a fonte original, então
		// não depende da extração para nada.
		if !c.src_audio || segs[i].muted || track_muted[segs[i].track] do continue
		sg := segs[i]
		vv := sg.vol <= 0 ? 1 : sg.vol
		sp := sg.speed <= 0 ? 1 : sg.speed
		sep := strings.builder_len(fb) > 0 ? ";" : "" // MP3: sem grafo de vídeo, a 1ª cadeia não leva ";"
		// atrim em tempo ABSOLUTO da fonte (o -copyts do input preserva os timestamps, então o
		// seek de entrada não desloca nada aqui — nada a compensar)
		fmt.sbprintf(&fb, "%s[%d:a]atrim=%.3f:%.3f,asetpts=PTS-STARTPTS,aformat=sample_rates=48000:channel_layouts=stereo,volume=%.3f",
			sep, seg_inp[i], sg.in_off, sg.in_off+sg.dur*sp, vv)
		// velocidade: atempo aceita 0.5..2 por estágio; encadeia p/ cobrir 0.25..4.
		// Vem ANTES dos fades p/ que o stream já tenha duração `dur` (tempo de timeline).
		if abs(sp-1) > 0.001 {
			r := sp
			for r > 2.0 + 0.001 { fmt.sbprintf(&fb, ",atempo=2.0"); r /= 2 }
			for r < 0.5 - 0.001 { fmt.sbprintf(&fb, ",atempo=0.5"); r *= 2 }
			fmt.sbprintf(&fb, ",atempo=%.5f", r)
		}
		if sg.fade_in > 0.01  do fmt.sbprintf(&fb, ",afade=t=in:st=0:d=%.3f", sg.fade_in)
		if sg.fade_out > 0.01 do fmt.sbprintf(&fb, ",afade=t=out:st=%.3f:d=%.3f", max(0, sg.dur-sg.fade_out), sg.fade_out)
		fmt.sbprintf(&fb, ",adelay=%.0f:all=1[a%d]", sg.start*1000, ac)
		ac += 1
	}
	if ac > 0 {
		fmt.sbprintf(&fb, ";")
		for k in 0 ..< ac do fmt.sbprintf(&fb, "[a%d]", k)
		// aresample=async=1: o amix+adelay entrega pacotes com PTS/DTS furados no
		// INSTANTE em que um clipe acaba e o próximo começa (corte na timeline).
		// O AAC recusa com "non monotonically increasing dts" / "Queue input is
		// backward in time" e o muxer MP4 morre com -22 (Invalid argument) — o
		// toast só mostrava a última linha ("Terminating thread... -22").
		// first_pts=0 ancora o mix no zero da timeline.
		fmt.sbprintf(&fb, "amix=inputs=%d:normalize=0:dropout_transition=0,aresample=async=1:first_pts=0[aout]", ac)
	}

	if !want_video && ac == 0 { set_toast("Nada de áudio para exportar"); return nil, "", false } // MP3 sem áudio

	// FILTERGRAPH POR ARQUIVO, não por argumento. O grafo é de longe a maior coisa da linha
	// de comando (~254 chars por segmento de vídeo, ~134 por faixa de áudio) e o Windows
	// limita a linha inteira a 32767 chars no CreateProcessW: com ~50-64 segmentos e efeitos
	// o comando estourava e o export morria com um "Falha ao iniciar ffmpeg" sem causa.
	// -filter_complex_script lê o mesmo texto de um arquivo, então o tamanho do grafo deixa
	// de contar. O arquivo entra em export_tmp_files e some junto com os PNGs no fim.
	//
	// ffmpeg novo marca esta opção como "deprecated, use -/filter_complex" — e ela fica MESMO
	// assim: -/opt (ler o valor de um arquivo) só existe do ffmpeg 7 p/ cima, e o binário é
	// resolvido pelo PATH, então trocar quebraria em qualquer instalação mais antiga. O aviso
	// de deprecação sai em nível warning e o -loglevel error acima já o silencia.
	graph = strings.to_string(fb)
	fg_path := fmt.tprintf("%s_%d_fgraph.txt", AUDIO_BASE, u32(win.GetCurrentProcessId()))
	if !dry {
		if os.write_entire_file(fg_path, transmute([]u8)graph) != nil {
			set_toast("Falha ao gravar o filtro do export")
			return nil, "", false
		}
		append(&export_tmp_files, strings.clone(fg_path))
	}
	append(&args, "-filter_complex_script", fg_path)
	if want_video do append(&args, "-map", "[vout]")
	if ac > 0     do append(&args, "-map", "[aout]")
	// TETO DE DURAÇÃO no arquivo: se o áudio (amix/atempo) passar de `total` por
	// arredondamento, o muxer espera frames de vídeo que o `color=d=total` já não
	// emite — e a exportação não termina. -t fecha o arquivo na duração da timeline.
	tlim := fmt.tprintf("%.3f", total + 0.05)
	append(&args, "-t", tlim, "-max_muxing_queue_size", "4096")

	// QUALIDADE: CQ (NVENC) / CRF (x264/x265/VP9) — nº maior = arquivo menor. Auto = alta
	// qualidade LIMITADA por teto de bitrate ≈ o da fonte (não incha além do original).
	cq, crf: string
	switch export_qual {
	case .High:   cq, crf = "23", "20"
	case .Medium: cq, crf = "28", "24"
	case .Low:    cq, crf = "32", "28"
	case .Auto:   cq, crf = "25", "22" // qualidade preservada; o -maxrate abaixo segura o tamanho
	}
	// PRESET DE VELOCIDADE: o CQ/CRF manda no tamanho; o preset manda no TEMPO. Antes tudo
	// ia em NVENC p5 / x264 veryfast — a Média e a Baixa demoravam o mesmo que a Alta.
	// p1 é ~2–3× p5 no mesmo CQ; ultrafast é o atalho da Baixa em CPU. VP9 sem -cpu-used
	// (default 1) era o caminho mais lento do modal — 4/6 deixa o WEBM utilizável.
	nvenc_pr, x26x_pr, vp9_cpu: string
	switch export_qual {
	case .High:   nvenc_pr, x26x_pr, vp9_cpu = "p5", "veryfast", "2"
	case .Medium: nvenc_pr, x26x_pr, vp9_cpu = "p4", "veryfast", "4"
	case .Low:    nvenc_pr, x26x_pr, vp9_cpu = "p1", "ultrafast", "6"
	case .Auto:   nvenc_pr, x26x_pr, vp9_cpu = "p4", "veryfast", "4"
	}
	// codec por FORMATO. NVENC (GPU) vale p/ H.264 e HEVC; VP9 é sempre por software.
	switch export_fmt {
	case .MP4:
		if gpu do append(&args, "-c:v", "h264_nvenc", "-preset", nvenc_pr, "-cq", cq, "-pix_fmt", "yuv420p", "-r", "30")
		else    do append(&args, "-c:v", "libx264", "-preset", x26x_pr, "-crf", crf, "-pix_fmt", "yuv420p", "-r", "30")
	case .HEVC: // -tag:v hvc1 = players (QuickTime/Apple) reconhecem o HEVC no .mp4
		if gpu do append(&args, "-c:v", "hevc_nvenc", "-preset", nvenc_pr, "-cq", cq, "-tag:v", "hvc1", "-pix_fmt", "yuv420p", "-r", "30")
		else    do append(&args, "-c:v", "libx265", "-preset", x26x_pr, "-crf", crf, "-tag:v", "hvc1", "-pix_fmt", "yuv420p", "-r", "30")
	case .WEBM: // VP9 não tem NVENC utilizável aqui; -b:v 0 = modo CRF puro; row-mt + cpu-used aceleram
		append(&args, "-c:v", "libvpx-vp9", "-crf", crf, "-b:v", "0", "-row-mt", "1", "-cpu-used", vp9_cpu, "-pix_fmt", "yuv420p", "-r", "30")
	case .MP3: // só áudio: descarta o vídeo por completo
		append(&args, "-vn")
	}
	if want_video && export_qual == .Auto {
		// teto = MAIOR bitrate entre as fontes de vídeo na timeline (heurística p/ várias
		// mídias: cada clipe tem o seu; usamos o maior p/ não degradar o mais pesado). Sem
		// bitrate legível (ex.: fonte sem essa info), fica sem teto = comportamento antigo.
		if src := timeline_max_src_bitrate(); src > 0 {
			append(&args, "-maxrate", fmt.tprintf("%d", src), "-bufsize", fmt.tprintf("%d", src*2))
		}
	}
	// áudio: AAC no MP4/HEVC, Opus no WEBM (AAC não entra em .webm), MP3 = codec principal
	if ac > 0 {
		switch export_fmt {
		case .WEBM: append(&args, "-c:a", "libopus", "-b:a", "192k")
		case .MP3:  append(&args, "-c:a", "libmp3lame", "-b:a", export_qual == .High ? "320k" : (export_qual == .Low ? "128k" : "192k"))
		case .MP4, .HEVC: append(&args, "-c:a", "aac", "-b:a", "192k")
		}
	}
	// MP4/MOV recusam DTS negativo/NOPTS (EINVAL -22). make_zero desloca a linha do
	// tempo p/ não estourar o muxer se o amix ainda entregar um pacote no limite.
	if export_fmt == .MP4 || export_fmt == .HEVC do append(&args, "-avoid_negative_ts", "make_zero")
	append(&args, out)
	// 2ª saída (só formatos de vídeo): frames rgb24 da prévia ao vivo pelo stdout (pipe:1)
	if want_video do append(&args, "-map", "[vpout]", "-an", "-f", "rawvideo", "-pix_fmt", "rgb24", "-t", tlim, "-max_muxing_queue_size", "4096", "pipe:1")
	// REDE DE SEGURANÇA: com o grafo fora da linha, sobram os inputs (um -i por segmento, com
	// o caminho inteiro). Ainda dá p/ estourar com muitos clipes de caminho longo, e o erro do
	// os.process_start seria de novo um "Falha ao iniciar ffmpeg" mudo. Melhor dizer a causa.
	if n := cmdline_len(args); n > CMDLINE_MAX {
		set_toast(rl.TextFormat("Comando longo demais (%d chars, máx %d): use caminhos mais curtos ou menos clipes", i32(n), i32(CMDLINE_MAX)))
		return nil, "", false
	}
	return args, graph, true
}

// NVENC disponível? Roda 1× no startup (depois de init_paths). Codifica 1 frame preto
// — se o encoder abrir, a placa e o driver respondem. Sem isto o checkbox vinha
// ligado por padrão e em máquina sem NVIDIA o ffmpeg morria no primeiro frame com um
// toast críptico ("Cannot load nvcuda.dll" / "No NVENC capable devices found").
// NÃO usar 64×64 (nem 128×128): o NVENC da série 40 recusa com
// "Frame Dimension less than the minimum supported value" e o probe mentia
// "GPU indisponível" numa RTX 4070. Mínimo real do h264_nvenc é ~145×49; 256×144
// fica bem acima e ainda é 1 frame barato.
probe_nvenc :: proc() -> bool {
	state, _, _, e := os.process_exec(os.Process_Desc{
		command = []string{
			"ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi",
			"-i", "color=c=black:s=256x144:d=0.04", "-frames:v", "1",
			"-c:v", "h264_nvenc", "-f", "null", "-",
		},
	}, context.temp_allocator)
	return e == nil && state.exited && state.exit_code == 0
}

// enfileira o export p/ o próximo update (o botão do modal só marca o pedido).
queue_export :: proc(out: string, gpu: bool) {
	if intrinsics.atomic_load(&export_run) { set_toast("Exportação já em andamento"); return }
	if export_pending_path != "" do delete(export_pending_path)
	export_pending_path = strings.clone(out)
	export_pending_gpu = gpu
	export_pending = true
}

// monta o comando e dispara o ffmpeg. Respeita trilhas/transform/proporção/cortes/
// volume/fades/mixagem. Renderiza a partir dos ARQUIVOS-fonte (resolução cheia).
start_export :: proc(out: string, gpu: bool) {
	if intrinsics.atomic_load(&export_run) { set_toast("Exportação já em andamento"); return }
	// GPU pedida sem NVENC: cai p/ CPU na hora (sem tentar e falhar). O checkbox pode
	// ter ficado ligado de uma sessão anterior ou o driver caiu depois do probe.
	use_gpu := gpu && (export_fmt == .MP4 || export_fmt == .HEVC)
	if use_gpu && !export_nvenc_ok {
		use_gpu = false
		export_gpu = false
		set_toast("NVENC indisponível — exportando por CPU")
	}
	args, _, built := export_build_args(out, use_gpu)
	if !built do return // o motivo já foi ao toast lá dentro
	// só agora publica a saída: se a montagem falhasse, export_out (usado pelo "Abrir
	// pasta" da conclusão) ficaria apontando p/ um arquivo que nunca foi criado
	if export_out != "" do delete(export_out)
	export_out = strings.clone(out)
	total := timeline_dur()
	W, H := export_dims()
	want_video := export_fmt != .MP3

	pr, pw, e := os.pipe() // prévia (stdout)
	if e != nil { set_toast("Falha ao criar pipe"); return }
	gr, gw, e2 := os.pipe() // progresso (stderr)
	if e2 != nil { os.close(pr); os.close(pw); set_toast("Falha ao criar pipe"); return }
	p, pe := os.process_start(os.Process_Desc{ command = args[:], stdout = pw, stderr = gw })
	os.close(pw); os.close(gw)
	if pe != nil {
		os.close(pr); os.close(gr)
		// pe costuma ser "executable file not found" quando o ffmpeg sumiu do PATH —
		// antes virava um toast mudo e o usuário não sabia o que instalar/onde olhar.
		set_toast(rl.TextFormat("Falha ao iniciar ffmpeg: %v", pe))
		return
	}
	export_job = make_kill_job()
	if export_job != nil do AssignProcessToJobObject(export_job, win.HANDLE(p.handle))
	sync.mutex_lock(&export_ps_mu); export_ps = p; export_ps_ok = true; sync.mutex_unlock(&export_ps_mu)
	export_r = gr; export_prev_r = pr
	export_total = total; export_pct = 0; export_ok = false
	export_err_n = 0 // erro da exportação ANTERIOR não vale para esta
	export_used_gpu = use_gpu
	// prepara os buffers e a textura da prévia (uma vez; reusa nas próximas exportações)
	if export_prev_a == nil { export_prev_a = make([]u8, PREV_BYTES); export_prev_b = make([]u8, PREV_BYTES) }
	if !export_prev_tex_ok {
		img := rl.GenImageColor(PREV_W, PREV_H, rl.BLACK)
		rl.ImageFormat(&img, .UNCOMPRESSED_R8G8B8)
		export_prev_tex = rl.LoadTextureFromImage(img)
		rl.UnloadImage(img)
		export_prev_tex_ok = export_prev_tex.id != 0
	}
	intrinsics.atomic_store(&export_prev_pub, -1)
	intrinsics.atomic_store(&export_prev_seq, 0)
	export_prev_last = 0; export_prev_wslot = 0
	export_paused = false; export_cancel = false
	intrinsics.atomic_store(&export_run, true)
	export_was_running = true // garante que o bloco de conclusão rode mesmo se o clique de cancelar der early-return
	export_thr = thread.create_and_start(export_worker)
	export_prev_thr = thread.create_and_start(export_preview_worker)
	if want_video do set_toast(rl.TextFormat("Exportando %dx%d%s...", i32(W), i32(H), use_gpu ? cstring(" (GPU)") : cstring("")))
	else          do set_toast("Exportando áudio (MP3)...")
}

// pausa/retoma a exportação suspendendo o processo ffmpeg (as threads de leitura só
// ficam esperando os pipes — sem dado, sem deadlock; retoma e o ffmpeg continua).
export_toggle_pause :: proc() {
	if !intrinsics.atomic_load(&export_run) do return
	sync.mutex_lock(&export_ps_mu); defer sync.mutex_unlock(&export_ps_mu)
	if !export_ps_ok do return // o worker já entrou no process_wait: o handle morreu
	if export_paused { NtResumeProcess(win.HANDLE(export_ps.handle)); export_paused = false }
	else            { NtSuspendProcess(win.HANDLE(export_ps.handle)); export_paused = true }
}

// cancela: mata o ffmpeg (pipes -> EOF -> workers terminam). O bloco de conclusão
// no update apaga o arquivo parcial e avisa (não trata como falha).
export_do_cancel :: proc() {
	if !intrinsics.atomic_load(&export_run) do return
	export_cancel = true
	sync.mutex_lock(&export_ps_mu); defer sync.mutex_unlock(&export_ps_mu)
	if !export_ps_ok do return // já terminou sozinho: nada a matar (e o handle já foi fechado)
	if export_paused { NtResumeProcess(win.HANDLE(export_ps.handle)); export_paused = false } // retoma p/ matar limpo
	_ = os.process_kill(export_ps)
}

// garante que o caminho termine com `ext` (ex.: ".ovp")
ensure_ext :: proc(path, ext: string) -> string {
	if strings.has_suffix(strings.to_lower(path, context.temp_allocator), ext) do return path
	return fmt.tprintf("%s%s", path, ext)
}
