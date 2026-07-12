package main

// MODO BENCHMARK:  editor.exe -bench "caminho\video.mp4"
//
// Importa a mídia, espera ficar pronta e roda um ROTEIRO FIXO (tocar → seeks
// espalhados → rajada de seeks → cortes + tocar atravessando os cortes), medindo
// o TRABALHO da main thread por frame (update+draw, SEM a espera de vsync do
// EndDrawing) e a latência de cada seek. Imprime um relatório comparável no
// stdout e fecha sozinho. O valor não é o número absoluto: é rodar ANTES e
// DEPOIS de uma mudança e comparar. Use o build RELEASE (o -debug liga o
// check_invariants por frame e suja a medição).
//
// Orçamentos de referência: 16.6ms = fluidez 60fps; >341ms de main thread
// bloqueada = buffer de áudio (16384 amostras) esvazia = estalo garantido.

import "core:fmt"
import "core:os"
import "core:slice"
import "base:intrinsics"
import rl "vendor:raylib"
import win "core:sys/windows"

// pico de RAM (working set) via psapi — K32GetProcessMemoryInfo vive no kernel32
BENCH_PMC :: struct {
	cb, page_faults: u32,
	peak_ws, ws, qppp, qpp, qpnp, qnp, pf, peak_pf: uint, // SIZE_T (8 bytes em x64)
}
foreign import bench_k32 "system:Kernel32.lib"
@(default_calling_convention = "system")
foreign bench_k32 {
	K32GetProcessMemoryInfo :: proc(h: win.HANDLE, pmc: ^BENCH_PMC, cb: u32) -> win.BOOL ---
}
bench_peak_ram_mb :: proc() -> f64 {
	pmc := BENCH_PMC{ cb = size_of(BENCH_PMC) }
	if !K32GetProcessMemoryInfo(win.GetCurrentProcess(), &pmc, size_of(BENCH_PMC)) do return -1
	return f64(pmc.peak_ws) / (1024 * 1024)
}

Bench_Phase :: enum { Off, Ready, Play, Seek, Storm, Cuts, Done }

bench_phase:   Bench_Phase
bench_checked: bool // já procurou -bench nos args?
bench_slot:    int  // slot da mídia em clips[]
bench_t0:      f64  // GetTime() do início do import
bench_tp:      f64  // início da fase atual
// prontidão (s desde o início; -1 = não aconteceu/não terminou)
bench_probe, bench_first, bench_head, bench_full: f64 = -1, -1, -1, -1
// trabalho por frame (ms) nas fases ativas + contagem de picos
bench_ft:    [dynamic]f64
bench_sp50:  int // frames > 50ms  (risco: hitch visível)
bench_sp341: int // frames > 341ms (estouro certo do buffer de áudio)
// seeks medidos: alterna longe/perto p/ forçar respawn de decoder nos streaming
BENCH_SEEKS := [8]f32{ 0.5, 0.1, 0.9, 0.2, 0.8, 0.3, 0.7, 0.05 }
bench_seek_i:  int
bench_seek_t:  f64 // GetTime() em que o seek atual foi pedido
bench_seek_ms: [dynamic]f64
bench_storm_n: int
bench_storm_t: f64

// chamada 1x por frame no loop principal com o tempo de TRABALHO do frame (ms).
// Dirige o roteiro e coleta as métricas; no-op sem -bench.
bench_frame :: proc(work_ms: f64) {
	if !bench_checked {
		bench_checked = true
		for a, i in os.args do if a == "-bench" && i + 1 < len(os.args) {
			bench_slot = import_media(os.args[i + 1], true) // autoplace na timeline
			if bench_slot < 0 { fmt.printfln("BENCH: import falhou de cara"); should_close = true; return }
			bench_phase = .Ready
			bench_t0 = rl.GetTime()
			bench_tp = bench_t0
			fmt.printfln("BENCH: importando %s", os.args[i + 1])
		}
	}
	if bench_phase == .Off || bench_phase == .Done do return
	now := rl.GetTime()
	el := now - bench_t0 // relógio do bench inteiro
	c := &clips[bench_slot]

	// marcos de prontidão: registra quando cada flag vira, em QUALQUER fase
	if intrinsics.atomic_load(&c.failed) {
		fmt.printfln("BENCH: a mídia FALHOU no import (arquivo inválido?)")
		should_close = true; bench_phase = .Done
		return
	}
	if bench_probe < 0 && media_ready(bench_slot) do bench_probe = el
	if bench_first < 0 && c.tex_ok do bench_first = el
	if bench_head  < 0 && c.has_audio && intrinsics.atomic_load(&c.head_done) do bench_head = el
	if bench_full  < 0 && c.has_audio && intrinsics.atomic_load(&c.ogg_done)  do bench_full = el

	// fases ativas medem o trabalho por frame
	if bench_phase != .Ready {
		append(&bench_ft, work_ms)
		if work_ms > 50  do bench_sp50  += 1
		if work_ms > 341 do bench_sp341 += 1
	}

	// segmento do bench na timeline (autoplace cria quando o probe termina)
	bseg := -1
	for i in 0 ..< nsegs do if segs[i].src == bench_slot { bseg = i; break }

	switch bench_phase {
	case .Off, .Done: // já tratados acima

	case .Ready:
		aud_ok := !c.has_audio || intrinsics.atomic_load(&c.head_done) || intrinsics.atomic_load(&c.ogg_done)
		if media_ready(bench_slot) && bseg >= 0 && aud_ok {
			fmt.printfln("BENCH: pronto em %.2fs — tocando %.0fs", el, min(12, f64(c.dur)))
			st.playhead = 0
			seek_global(0)
			st.playing = true
			bench_phase = .Play; bench_tp = now
		} else if el > 180 {
			fmt.printfln("BENCH: TIMEOUT esperando a mídia ficar pronta (180s)")
			bench_report()
		}

	case .Play:
		if now - bench_tp >= min(12, f64(c.dur)) {
			fmt.printfln("BENCH: fase de seeks (%d posições)", len(BENCH_SEEKS))
			bench_phase = .Seek; bench_tp = now
			bench_seek_i = -1 // o 1º seek é disparado abaixo
		}

	case .Seek:
		// seek atual assentou? (streaming: respawn assíncrono terminou; cache: instantâneo)
		settled := bench_seek_i >= 0 && !intrinsics.atomic_load(&c.rsp_busy)
		timeout := bench_seek_i >= 0 && now - bench_seek_t > 3
		if bench_seek_i < 0 || settled || timeout {
			if settled || timeout do append(&bench_seek_ms, (now - bench_seek_t) * 1000)
			bench_seek_i += 1
			if bench_seek_i >= len(BENCH_SEEKS) {
				fmt.printfln("BENCH: rajada de seeks (3s)")
				bench_phase = .Storm; bench_tp = now; bench_storm_t = 0; bench_storm_n = 0
			} else {
				seek_global(BENCH_SEEKS[bench_seek_i] * timeline_dur())
				bench_seek_t = now
			}
		}

	case .Storm:
		if now - bench_storm_t > 0.2 { // ~5 seeks/s, posições ciclando a timeline
			bench_storm_t = now
			bench_storm_n += 1
			seek_global(f32(bench_storm_n % 9 + 1) / 10 * timeline_dur())
		}
		if now - bench_tp >= 3 {
			// corta em 30/50/70% e toca atravessando os cortes (cadeia contígua + áudio)
			d := timeline_dur()
			if d > 2 {
				for f in ([3]f32{ 0.3, 0.5, 0.7 }) { st.playhead = f * d; split_at_playhead() }
				fmt.printfln("BENCH: 3 cortes; tocando 6s atravessando-os")
				seek_global(0.28 * d)
				st.playing = true
			} else do fmt.printfln("BENCH: vídeo curto demais p/ a fase de cortes (pulada)")
			bench_phase = .Cuts; bench_tp = now
		}

	case .Cuts:
		if now - bench_tp >= 6 do bench_report()
	}
}

bench_pct :: proc(sorted: []f64, p: f64) -> f64 {
	if len(sorted) == 0 do return 0
	return sorted[clamp(int(p * f64(len(sorted) - 1)), 0, len(sorted) - 1)]
}

bench_report :: proc() {
	c := &clips[bench_slot]
	slice.sort(bench_ft[:])
	sum := 0.0
	for v in bench_ft do sum += v
	avg := len(bench_ft) > 0 ? sum / f64(len(bench_ft)) : 0
	fmt.printfln("")
	fmt.printfln("==================== BENCH ====================")
	fmt.printfln("mídia: %s", c.path)
	fmt.printfln("dur=%.1fs codec=%s modo=%s no_hw=%v", c.dur, c.vcodec, c.streaming ? "streaming" : "cache-RAM", c.no_hw)
	fmt.printfln("prontidão (s): probe=%.2f 1º-frame=%.2f áudio-head=%.2f áudio-completo=%.2f (-1 = não houve/não terminou)",
		bench_probe, bench_first, bench_head, bench_full)
	fmt.printfln("trabalho/frame (ms, %d frames): avg=%.2f p50=%.2f p95=%.2f p99=%.2f max=%.2f",
		len(bench_ft), avg, bench_pct(bench_ft[:], 0.5), bench_pct(bench_ft[:], 0.95), bench_pct(bench_ft[:], 0.99), bench_pct(bench_ft[:], 1))
	fmt.printfln("picos: >50ms=%d (hitch visível)  >341ms=%d (estouro do buffer de áudio)", bench_sp50, bench_sp341)
	ssum := 0.0
	for v in bench_seek_ms do ssum += v
	fmt.printf("seeks (ms até assentar): ")
	for v, i in bench_seek_ms do fmt.printf(i > 0 ? ", %.0f" : "%.0f", v)
	fmt.printfln("  | avg=%.0f", len(bench_seek_ms) > 0 ? ssum / f64(len(bench_seek_ms)) : 0)
	fmt.printfln("rajada: %d seeks em 3s", bench_storm_n)
	fmt.printfln("RAM pico: %.0f MB", bench_peak_ram_mb())
	fmt.printfln("===============================================")
	delete(bench_ft); delete(bench_seek_ms)
	bench_phase = .Done
	should_close = true
}
