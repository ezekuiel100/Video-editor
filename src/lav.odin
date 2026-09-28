package main

// Decoder de scrub PERSISTENTE via libav (DLLs do FFmpeg carregadas em runtime).
// O caminho antigo subia um processo ffmpeg por frame do arrasto: abrir arquivo +
// probe + criar decoder custava mais que o decode do keyframe. Aqui o worker de
// scrub mantém arquivo, decoder e último quadro por clipe; avanços curtos não fazem seek.
//
// Tudo é opcional: sem as DLLs (ou se algo falhar num clipe) o scrub cai no
// ffmpeg por processo de sempre. As DLLs são carregadas por nome (LoadLibrary
// acha ao lado do .exe) e as structs lidas por OFFSET — só os poucos campos
// abaixo, conferidos nos headers de avformat 63 / avcodec 63 / avutil 61.
// Trocar a versão das DLLs = reconferir estes offsets.
//
// Só a thread do worker de scrub mexe aqui (sem lock).

import "base:intrinsics"
import "base:runtime"
import "core:dynlib"
import "core:strings"
import "core:time"

LAV_DLLS :: [4]string{ "avutil-61.dll", "swscale-10.dll", "avcodec-63.dll", "avformat-63.dll" }

// offsets (bytes) — ver comentário do topo
FMT_NB_STREAMS  :: 44  // AVFormatContext.nb_streams (u32)
FMT_STREAMS     :: 48  // AVFormatContext.streams (AVStream**)
FMT_START_TIME  :: 96  // AVFormatContext.start_time (i64, AV_TIME_BASE)
ST_CODECPAR     :: 16  // AVStream.codecpar
ST_TIME_BASE    :: 32  // AVStream.time_base (AVRational: dois i32)
FR_LINESIZE     :: 64  // AVFrame.linesize[8] (i32); data[8] fica em 0
FR_WIDTH        :: 104 // AVFrame.width, height (+4), format (+12)
FR_PTS         :: 136 // AVFrame.pts (i64), avutil 61 / Windows x64
FR_BEST_TS     :: 304 // AVFrame.best_effort_timestamp (i64), mesma ABI
PKT_STREAM_IDX  :: 36  // AVPacket.stream_index (i32)

AV_NOPTS        :: min(i64)
AV_PIX_RGB24    :: i32(2)
AVMEDIA_VIDEO   :: i32(0)
AVERROR_EAGAIN  :: i32(-11)
AVERROR_EOF     :: i32(-541478725)
AVSEEK_BACKWARD :: i32(1)

Lav :: struct {
	avformat_open_input:          proc "c" (ps: ^rawptr, url: cstring, fmt: rawptr, opts: ^rawptr) -> i32,
	avformat_find_stream_info:    proc "c" (s: rawptr, opts: rawptr) -> i32,
	av_find_best_stream:          proc "c" (s: rawptr, type: i32, wanted, related: i32, dec: ^rawptr, flags: i32) -> i32,
	av_seek_frame:                proc "c" (s: rawptr, idx: i32, ts: i64, flags: i32) -> i32,
	av_read_frame:                proc "c" (s: rawptr, pkt: rawptr) -> i32,
	avformat_close_input:         proc "c" (ps: ^rawptr),
	avcodec_alloc_context3:       proc "c" (codec: rawptr) -> rawptr,
	avcodec_parameters_to_context:proc "c" (ctx: rawptr, par: rawptr) -> i32,
	avcodec_open2:                proc "c" (ctx: rawptr, codec: rawptr, opts: ^rawptr) -> i32,
	avcodec_send_packet:          proc "c" (ctx: rawptr, pkt: rawptr) -> i32,
	avcodec_receive_frame:        proc "c" (ctx: rawptr, fr: rawptr) -> i32,
	avcodec_flush_buffers:        proc "c" (ctx: rawptr),
	avcodec_free_context:         proc "c" (ctx: ^rawptr),
	av_packet_alloc:              proc "c" () -> rawptr,
	av_packet_free:               proc "c" (pkt: ^rawptr),
	av_packet_unref:              proc "c" (pkt: rawptr),
	av_frame_alloc:               proc "c" () -> rawptr,
	av_frame_free:                proc "c" (fr: ^rawptr),
	av_frame_unref:               proc "c" (fr: rawptr),
	av_frame_move_ref:            proc "c" (dst, src: rawptr),
	av_opt_set:                   proc "c" (obj: rawptr, name, val: cstring, flags: i32) -> i32,
	av_log_set_level:             proc "c" (level: i32),
	sws_alloc_context:            proc "c" () -> rawptr,
	sws_free_context:             proc "c" (ctx: ^rawptr),
	sws_scale_frame:              proc "c" (ctx: rawptr, dst, src: rawptr) -> i32,
}

lav:       Lav
lav_state: int // 0 = não tentou, 1 = ok, -1 = sem DLLs (fica no ffmpeg por processo)

// decoder aberto de UM clipe (aid garante que um slot reaproveitado não casa)
LavDec :: struct {
	ci, aid:  int,
	fmt:      rawptr, // AVFormatContext
	dec:      rawptr, // AVCodecContext
	vidx:     i32,
	start:    i64,    // start_time do container (AV_TIME_BASE) — base do -ss
	used:     time.Tick,
	frame:    rawptr, // último quadro próprio: não compartilha lav_src entre clipes
	time_base: f64,
	frame_t, request_t: f64, // segundos relativos ao start_time do container
	has_frame, draining, pending: bool,
}

LAV_MAXDEC :: 4 // arquivos abertos ao mesmo tempo (arrasto cruzando clipes diferentes)
lav_decs:   [LAV_MAXDEC]LavDec
lav_pkt:    rawptr
lav_src:    rawptr // AVFrame decodificado
lav_dst:    rawptr // AVFrame "casca" apontando p/ o buffer do scrub
lav_sws:    rawptr

lav_init :: proc() -> bool {
	if lav_state != 0 do return lav_state > 0
	lav_state = -1
	libs: [4]dynlib.Library
	for name, i in LAV_DLLS {
		l, ok := dynlib.load_library(name)
		if !ok { dbg("LAV", "sem %s -> scrub segue por processo ffmpeg", name); return false }
		libs[i] = l
	}
	// cada campo de Lav é procurado em todas as DLLs pelo nome do campo
	ti := runtime.type_info_base(type_info_of(Lav)).variant.(runtime.Type_Info_Struct)
	for fi in 0 ..< ti.field_count {
		name := ti.names[fi]
		addr: rawptr
		for l in libs {
			if p, found := dynlib.symbol_address(l, name); found { addr = p; break }
		}
		if addr == nil { dbg("LAV", "símbolo %s ausente -> scrub por processo", name); return false }
		(^rawptr)(uintptr(&lav) + ti.offsets[fi])^ = addr
	}
	lav.av_log_set_level(-8) // AV_LOG_QUIET: nada de spam no console
	lav_pkt = lav.av_packet_alloc()
	lav_src = lav.av_frame_alloc()
	lav_dst = lav.av_frame_alloc()
	lav_sws = lav.sws_alloc_context()
	if lav_pkt == nil || lav_src == nil || lav_dst == nil || lav_sws == nil do return false
	lav.av_opt_set(lav_sws, "sws_flags", "fast_bilinear", 0) // arrasto: o "quase lá" basta
	lav_state = 1
	dbg("LAV", "libav carregada: scrub com decoder persistente")
	return true
}

@(private="file") rd :: proc(p: rawptr, off: int, $T: typeid) -> T { return (^T)(uintptr(p) + uintptr(off))^ }
@(private="file") wr :: proc(p: rawptr, off: int, v: $T) { (^T)(uintptr(p) + uintptr(off))^ = v }

lav_close :: proc(d: ^LavDec) {
	if d.frame != nil do lav.av_frame_free(&d.frame)
	if d.dec != nil do lav.avcodec_free_context(&d.dec)
	if d.fmt != nil do lav.avformat_close_input(&d.fmt)
	d^ = {}
}

// fecha decoders ociosos: solta o handle do arquivo (senão o Windows não deixa apagar/mover)
lav_idle :: proc() {
	if lav_state <= 0 do return
	for &d in lav_decs {
		if d.fmt != nil && time.duration_seconds(time.tick_since(d.used)) > 5 do lav_close(&d)
	}
}

lav_open :: proc(c: ^Clip, ci: int) -> ^LavDec {
	for &d in lav_decs do if d.fmt != nil && d.ci == ci && d.aid == c.aid { d.used = time.tick_now(); return &d }
	v := &lav_decs[0] // vago primeiro, senão o menos usado recentemente
	for &d in lav_decs {
		if d.fmt == nil { v = &d; break }
		if time.tick_diff(d.used, v.used) > 0 do v = &d
	}
	if v.fmt != nil do lav_close(v)
	// heap, não temp: o worker é uma thread de vida longa (temp allocator nunca é liberado nela)
	path := strings.clone_to_cstring(c.path)
	defer delete(path)
	fmtc: rawptr
	if lav.avformat_open_input(&fmtc, path, nil, nil) < 0 do return nil
	v.fmt = fmtc
	if lav.avformat_find_stream_info(fmtc, nil) < 0 { lav_close(v); return nil }
	codec: rawptr
	idx := lav.av_find_best_stream(fmtc, AVMEDIA_VIDEO, -1, -1, &codec, 0)
	if idx < 0 || codec == nil || u32(idx) >= rd(fmtc, FMT_NB_STREAMS, u32) { lav_close(v); return nil }
	st := rd(fmtc, FMT_STREAMS, [^]rawptr)[idx]
	v.dec = lav.avcodec_alloc_context3(codec)
	if v.dec == nil || lav.avcodec_parameters_to_context(v.dec, rd(st, ST_CODECPAR, rawptr)) < 0 { lav_close(v); return nil }
	// Decodifica também P/B frames; slice threads evitam latência extra de frame-threading.
	lav.av_opt_set(v.dec, "threads", "auto", 0)
	lav.av_opt_set(v.dec, "thread_type", "slice", 0)
	if lav.avcodec_open2(v.dec, codec, nil) < 0 { lav_close(v); return nil }
	v.frame = lav.av_frame_alloc()
	num, den := rd(st, ST_TIME_BASE, i32), rd(st, ST_TIME_BASE + 4, i32)
	if v.frame == nil || num <= 0 || den <= 0 { lav_close(v); return nil }
	v.time_base = f64(num) / f64(den)
	v.ci = ci; v.aid = c.aid; v.vidx = idx
	v.start = rd(fmtc, FMT_START_TIME, i64)
	if v.start == AV_NOPTS do v.start = 0
	v.used = time.tick_now()
	dbg("LAV", "clip='%s' decoder aberto (stream %d)", c.name, idx)
	return v
}

// Avanço limitado em tempo de fonte; retorno/repetição fora do quadro retido e
// saltos grandes precisam de seek. Um decode que cedeu o orçamento pode continuar.
LAV_FORWARD_S :: f64(0.5)
LAV_BUDGET_MS :: f64(150)

// Tolerância entre o tempo do índice de keyframes (f32 do ffprobe) e o PTS decodificado.
LAV_KF_EPS :: f64(0.002)

// kf_t: keyframe ≤ alvo (índice do clipe; -1 = desconhecido). Se o quadro retido já está
// depois dele e antes do alvo, seguir decodificando nunca é pior que o seek, que voltaria
// para o mesmo keyframe — vale para GOP longo, onde o alvo fica a segundos do quadro.
lav_needs_seek :: proc(d: ^LavDec, target: f64, kf_t := f64(-1)) -> bool {
	if d.pending && target >= d.request_t && target - d.request_t <= LAV_FORWARD_S do return false
	if d.has_frame && kf_t >= 0 && target >= d.frame_t && d.frame_t + LAV_KF_EPS >= kf_t do return false
	return !d.has_frame || target < d.request_t || target - d.frame_t > LAV_FORWARD_S
}

// O pedido exato alcançaria o alvo sem seek? Não abre decoder (sem decoder = precisa seek).
lav_would_seek :: proc(c: ^Clip, ci: int, t: f32, kf_t := f64(-1)) -> bool {
	for &d in lav_decs do if d.fmt != nil && d.ci == ci && d.aid == c.aid do return lav_needs_seek(&d, f64(max(t, 0)), kf_t)
	return true
}

// Primeiro quadro com timestamp >= alvo (ou último quadro no EOF). Usa timestamps
// de apresentação, não contagem/fps: B-frames e VFR seguem a ordem do decoder.
// retry distingue orçamento/cancelamento de falha: não envenena lav_bad nem faz spawn.
//
// keyframe: arrasto rápido — entrega o keyframe ≤ alvo (seek + 1 decode) em vez de
// decodificar o GOP inteiro; um quadro retido entre o keyframe e o alvo é ainda melhor.
// partial: ao estourar o orçamento, entrega o quadro retido (entre kf_t e o alvo) em vez
// de nada; o estado segue pendente e o próximo pedido continua de onde parou.
lav_decode_frame :: proc(c: ^Clip, ci: int, t: f32, buf: []u8, retry: ^bool = nil,
	kf_t := f64(-1), keyframe := false, budget_ms := LAV_BUDGET_MS, partial: ^bool = nil) -> bool {
	if retry != nil do retry^ = false
	if partial != nil do partial^ = false
	if !lav_init() do return false
	d := lav_open(c, ci)
	if d == nil do return false
	target := f64(max(t, 0))
	if keyframe {
		held := d.has_frame && kf_t >= 0 && d.frame_t + LAV_KF_EPS >= kf_t && d.frame_t <= target + LAV_KF_EPS
		if !held && !lav_seek_first(c, d, target) {
			if intrinsics.atomic_load(&app_closing) || intrinsics.atomic_load(&c.stop) {
				if retry != nil do retry^ = true
			}
			return false
		}
		return lav_convert(c, d, buf)
	}
	if lav_needs_seek(d, target, kf_t) {
		ts := i64(target * 1e6) + d.start
		if lav.av_seek_frame(d.fmt, -1, ts, AVSEEK_BACKWARD) < 0 {
			if lav.av_seek_frame(d.fmt, -1, ts, 0) < 0 do return false
		}
		lav.avcodec_flush_buffers(d.dec)
		lav.av_frame_unref(d.frame)
		d.has_frame = false; d.draining = false
	}
	d.request_t = target; d.pending = true
	began := time.tick_now()
	defer lav.av_frame_unref(lav_src)
	for n := 0; !d.has_frame || d.frame_t + 0.000001 < target; n += 1 {
		if intrinsics.atomic_load(&app_closing) || intrinsics.atomic_load(&c.stop) {
			if retry != nil do retry^ = true
			return false
		}
		if n >= 2000 || time.duration_milliseconds(time.tick_since(began)) >= budget_ms {
			// estado preservado: próximo pedido continua sem flush
			if partial != nil && d.has_frame && kf_t >= 0 && d.frame_t + LAV_KF_EPS >= kf_t {
				partial^ = true
				return lav_convert(c, d, buf)
			}
			if retry != nil do retry^ = true
			return false
		}
		r := lav.avcodec_receive_frame(d.dec, lav_src)
		if r >= 0 {
			pts := rd(lav_src, FR_BEST_TS, i64)
			if pts == AV_NOPTS do pts = rd(lav_src, FR_PTS, i64)
			if pts == AV_NOPTS do return false // sem timestamp confiável: fallback
			ft := f64(pts) * d.time_base - f64(d.start) / 1e6
			if d.has_frame && ft < d.frame_t do return false
			lav.av_frame_unref(d.frame)
			lav.av_frame_move_ref(d.frame, lav_src)
			d.frame_t = ft; d.has_frame = true
			continue
		}
		if r == AVERROR_EOF {
			if !d.has_frame do return false
			break // alvo após o último PTS: mantém último quadro, inclusive B-frames drenados
		}
		if r != AVERROR_EAGAIN || d.draining do return false
		r = lav.av_read_frame(d.fmt, lav_pkt)
		if r < 0 {
			if r != AVERROR_EOF do return false
			if lav.avcodec_send_packet(d.dec, nil) < 0 do return false
			d.draining = true
			continue
		}
		sent: i32
		if rd(lav_pkt, PKT_STREAM_IDX, i32) == d.vidx do sent = lav.avcodec_send_packet(d.dec, lav_pkt)
		lav.av_packet_unref(lav_pkt)
		// Após receive=EAGAIN, send deve aceitar o pacote. Nunca ignora erro de envio.
		if sent < 0 do return false
	}
	d.pending = false
	return lav_convert(c, d, buf)
}

// Seek para o keyframe ≤ alvo e decodifica só o 1º quadro que sair. Deixa o decoder
// posicionado: request_t = frame_t, então o refino exato continua daqui sem novo seek.
@(private="file")
lav_seek_first :: proc(c: ^Clip, d: ^LavDec, target: f64) -> bool {
	ts := i64(target * 1e6) + d.start
	if lav.av_seek_frame(d.fmt, -1, ts, AVSEEK_BACKWARD) < 0 {
		if lav.av_seek_frame(d.fmt, -1, ts, 0) < 0 do return false
	}
	lav.avcodec_flush_buffers(d.dec)
	lav.av_frame_unref(d.frame)
	d.has_frame = false; d.draining = false; d.pending = false
	defer lav.av_frame_unref(lav_src)
	for n := 0; n < 2000; n += 1 {
		if intrinsics.atomic_load(&app_closing) || intrinsics.atomic_load(&c.stop) do return false
		r := lav.avcodec_receive_frame(d.dec, lav_src)
		if r >= 0 {
			pts := rd(lav_src, FR_BEST_TS, i64)
			if pts == AV_NOPTS do pts = rd(lav_src, FR_PTS, i64)
			if pts == AV_NOPTS do return false
			lav.av_frame_move_ref(d.frame, lav_src)
			d.frame_t = f64(pts) * d.time_base - f64(d.start) / 1e6
			d.request_t = d.frame_t; d.has_frame = true
			return true
		}
		if r == AVERROR_EOF || r != AVERROR_EAGAIN || d.draining do return false
		r = lav.av_read_frame(d.fmt, lav_pkt)
		if r < 0 {
			if r != AVERROR_EOF do return false
			if lav.avcodec_send_packet(d.dec, nil) < 0 do return false
			d.draining = true
			continue
		}
		sent: i32
		if rd(lav_pkt, PKT_STREAM_IDX, i32) == d.vidx do sent = lav.avcodec_send_packet(d.dec, lav_pkt)
		lav.av_packet_unref(lav_pkt)
		if sent < 0 do return false
	}
	return false
}

// quadro retido (d.frame) -> RGB24 no buffer do scrub, com barras pretas se preciso
@(private="file")
lav_convert :: proc(c: ^Clip, d: ^LavDec, buf: []u8) -> bool {
	src := d.frame
	fw, fh := rd(src, FR_WIDTH, i32), rd(src, FR_WIDTH + 4, i32)
	// rotação ±90: o ffmpeg CLI auto-rotaciona e aqui não — vídeo de celular em pé
	// sairia deitado. Sinal: dims de exibição (c.vw/vh, já corrigidas) invertidas.
	if c.vw > 0 && fw != fh && fw == c.vh && fh == c.vw do return false

	dw, dh := int(cdw(c)), int(cdh(c))
	sf := dw * dh * 3
	if len(buf) < sf do return false
	r := dec_content_rect(c)
	x0, y0 := int(r.x + 0.5), int(r.y + 0.5)
	cw, ch := max(int(r.width + 0.5), 2), max(int(r.height + 0.5), 2)
	x0 = clamp(x0, 0, dw - cw); y0 = clamp(y0, 0, dh - ch)
	if cw != dw || ch != dh do for &b in buf[:sf] do b = 0 // barras pretas
	lav.av_frame_unref(lav_dst)
	wr(lav_dst, 0, rawptr(&buf[(y0 * dw + x0) * 3])) // data[0] dentro do buffer, no canto do conteúdo
	wr(lav_dst, FR_LINESIZE, i32(dw * 3))
	wr(lav_dst, FR_WIDTH, i32(cw))
	wr(lav_dst, FR_WIDTH + 4, i32(ch))
	wr(lav_dst, FR_WIDTH + 12, AV_PIX_RGB24)
	ok := lav.sws_scale_frame(lav_sws, lav_dst, src) >= 0
	wr(lav_dst, 0, rawptr(nil)) // a casca não é dona do buffer
	return ok
}
