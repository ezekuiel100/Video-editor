package main

import rl "vendor:raylib"
import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:thread"
import "core:time"
import win "core:sys/windows"

// Voz para texto: extrai o áudio do clipe, passa no whisper.cpp (processo separado,
// como o ffmpeg) e vira UMA faixa de legendas sincronizada na timeline.
//
// Motor + ggml-small (Máximo) vêm em EXE_DIR\stt (fetch-stt.ps1 / instalador).
// Se faltar (build sem a pasta) ou se o usuário ligar GPU CUDA, baixa sob
// demanda para %LOCALAPPDATA%\OdinVideoEditor\stt.

STT_CPU_ZIP    :: "https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.2/whisper-blas-bin-x64.zip"
STT_CUDA_ZIP   :: "https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.2/whisper-cublas-11.8.0-bin-x64.zip"
STT_HF         :: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/"
STT_MODEL_FILE :: "ggml-small.bin"
STT_MODEL_MB   :: 466

STTPhase :: enum i32 { Idle, Prep, FetchBin, FetchModel, Extract, Talk, Done, Fail }

stt_si:    int = -1
stt_lang:  int = 1 // 0=auto 1=pt 2=en 3=es
stt_gpu:   bool    // usar whisper CUDA se houver NVIDIA
stt_gpu_set: bool  // já escolheu (senão o default segue export_nvenc_ok)
stt_phase: STTPhase
stt_err:   string // heap, dono (só a main lê depois de Done/Fail)
stt_srt:   string // heap, dono: SRT cru do whisper (offset ainda NÃO aplicado)
stt_cues:  [dynamic]CapCue // parse na main p/ o preview do modal
stt_thr:   ^thread.Thread
stt_job:   win.HANDLE
stt_stop:  bool
stt_eat:   bool
stt_in:    f32 // in_off do segmento no Começar (offset das falas)
stt_src_dur: f32
stt_scroll: f32
tf_cue:     TField // texto da fala em edição (prévia STT ou modal Caps)
cue_edit:   int = -1
cue_focus:  bool
caps_edit_si: int = -1 // segmento da faixa no modal .Caps
caps_scroll:  f32
caps_eat:     bool
stt_note_buf: [200]u8
stt_note_n:   int
stt_want_gpu: bool // snapshot no Começar
stt_pct_x:    i32  // 0..1000, atômico (worker escreve, main lê)
stt_span_lo:  f32  // worker: fase atual mapeia 0..1 local → [lo, hi]
stt_span_hi:  f32
stt_watch_kind: STTWatch
stt_watch_dur:  f32 // segundos da extração (ffmpeg)

STTWatch :: enum { None, Curl, FFmpeg, Whisper }

STT_LANGS := []cstring{ "Auto", "Português", "Inglês", "Espanhol" }
STT_LANGC := []string{ "auto", "pt", "en", "es" }

stt_set_note :: proc(s: string) {
	n := min(len(s), len(stt_note_buf))
	for i in 0 ..< n do stt_note_buf[i] = s[i]
	intrinsics.atomic_store(&stt_note_n, n)
}
stt_note :: proc() -> string {
	n := clamp(intrinsics.atomic_load(&stt_note_n), 0, len(stt_note_buf))
	return string(stt_note_buf[:n])
}
stt_dir :: proc() -> string {
	base := os.get_env("LOCALAPPDATA", context.temp_allocator)
	if base == "" do base = EXE_DIR != "" ? EXE_DIR : "."
	return fmt.tprintf("%s\\OdinVideoEditor\\stt", base)
}

stt_exists :: proc(p: string) -> bool { return p != "" && os.exists(p) && !os.is_dir(p) }

stt_find_named :: proc(root, name: string, depth: int) -> string {
	if depth < 0 || root == "" do return ""
	direct := fmt.tprintf("%s\\%s", root, name)
	if stt_exists(direct) do return strings.clone(direct)
	if depth == 0 do return ""
	fd: win.WIN32_FIND_DATAW
	h := win.FindFirstFileW(win.utf8_to_wstring(fmt.tprintf("%s\\*", root)), &fd)
	if h == win.INVALID_HANDLE_VALUE do return ""
	defer win.FindClose(h)
	for {
		if fd.dwFileAttributes & win.FILE_ATTRIBUTE_DIRECTORY != 0 {
			sub := win.wstring_to_utf8(win.wstring(raw_data(fd.cFileName[:])), -1) or_else ""
			if sub != "" && sub != "." && sub != ".." {
				if found := stt_find_named(fmt.tprintf("%s\\%s", root, sub), name, depth - 1); found != "" {
					return found
				}
			}
		}
		if !win.FindNextFileW(h, &fd) do break
	}
	return ""
}

stt_find_cli :: proc(gpu: bool) -> string {
	if gpu {
		cuda := fmt.tprintf("%s\\cuda", stt_dir())
		if p := stt_find_named(cuda, "whisper-cli.exe", 3); p != "" do return p
	}
	roots := [3]string{ EXE_DIR, fmt.tprintf("%s\\stt", EXE_DIR), stt_dir() }
	for r in roots {
		if r == "" do continue
		if p := stt_find_named(r, "whisper-cli.exe", 2); p != "" {
			// a pasta cuda também está sob stt_dir: se pedimos CPU, ignora o binário CUDA
			if gpu || strings.index(p, "\\cuda\\") < 0 do return p
		}
	}
	return ""
}

stt_find_model :: proc(name: string) -> string {
	roots := [4]string{
		EXE_DIR,
		fmt.tprintf("%s\\stt", EXE_DIR),
		fmt.tprintf("%s\\models", EXE_DIR),
		stt_dir(),
	}
	for r in roots {
		if r == "" do continue
		if p := stt_find_named(r, name, 2); p != "" do return p
	}
	return ""
}

stt_mkdirs :: proc(dir: string) -> bool {
	// cria pai e a pasta (os.make_directory não é recursivo)
	slash := strings.last_index_any(dir, "\\/")
	if slash > 0 do _ = os.make_directory(dir[:slash])
	_ = os.make_directory(dir)
	return os.is_dir(dir)
}

stt_set_pct :: proc(p: f32) {
	v := i32(clamp(p, 0, 1) * 1000 + 0.5)
	old := intrinsics.atomic_load(&stt_pct_x)
	if v < old do return // só avança (senão o 0% do Whisper no começo da fala puxava a barra pra trás)
	intrinsics.atomic_store(&stt_pct_x, v)
}
stt_reset_pct :: proc() { intrinsics.atomic_store(&stt_pct_x, 0) }
stt_pct :: proc() -> f32 { return f32(intrinsics.atomic_load(&stt_pct_x)) / 1000 }
stt_begin :: proc(lo, hi: f32) {
	stt_span_lo = clamp(lo, 0, 1)
	stt_span_hi = clamp(max(hi, stt_span_lo), 0, 1)
	stt_set_pct(stt_span_lo)
}
stt_local :: proc(p: f32) {
	stt_set_pct(stt_span_lo + clamp(p, 0, 1) * (stt_span_hi - stt_span_lo))
}

// "progress = 42%", "Progress:  5%", "######## 40.1%"
stt_parse_pct_line :: proc(s: string) -> (f32, bool) {
	t := strings.trim_space(s)
	if t == "" do return 0, false
	low := strings.to_lower(t, context.temp_allocator)
	if i := strings.index(low, "progress"); i >= 0 {
		rest := t[i + 8:]
		for j in 0 ..< len(rest) {
			c := rest[j]
			if c == '=' || c == ':' {
				rest = strings.trim_left_space(rest[j+1:])
				break
			}
		}
		if v, ok := stt_parse_leading_pct(rest); ok do return v, true
	}
	// último token com % (barra do curl, meter clássico)
	for k := len(t) - 1; k >= 0; k -= 1 {
		if t[k] != '%' do continue
		a := k
		for a > 0 {
			c := t[a-1]
			if (c >= '0' && c <= '9') || c == '.' || c == ' ' { a -= 1; continue }
			break
		}
		chunk := strings.trim_space(t[a:k])
		if v, ok := strconv.parse_f64(chunk); ok && v >= 0 && v <= 100.5 {
			return clamp(f32(v / 100), 0, 1), true
		}
		break
	}
	return 0, false
}

stt_parse_leading_pct :: proc(s: string) -> (f32, bool) {
	n := 0
	for n < len(s) {
		c := s[n]
		if (c >= '0' && c <= '9') || c == '.' || c == ' ' { n += 1; continue }
		break
	}
	chunk := strings.trim_space(s[:n])
	if chunk == "" do return 0, false
	v, ok := strconv.parse_f64(chunk)
	if !ok || v < 0 || v > 100.5 do return 0, false
	return clamp(f32(v / 100), 0, 1), true
}

stt_parse_out_time :: proc(s: string) -> (f32, bool) {
	us :: "out_time_us="
	ms :: "out_time_ms="
	if strings.has_prefix(s, us) {
		if v, ok := strconv.parse_i64(s[len(us):]); ok && v >= 0 do return f32(v) / 1e6, true
	} else if strings.has_prefix(s, ms) {
		if v, ok := strconv.parse_i64(s[len(ms):]); ok && v >= 0 do return f32(v) / 1e6, true
	}
	return 0, false
}

// "[00:00:10.000 --> 00:00:12.400]" — relógio da fala como fallback se o -pp não sair
stt_parse_arrow_time :: proc(s: string) -> (f32, bool) {
	i := strings.index(s, "-->")
	if i < 0 do return 0, false
	rest := strings.trim_left_space(s[i+3:])
	end := 0
	for end < len(rest) {
		c := rest[end]
		if c == ' ' || c == ']' || c == '\t' do break
		end += 1
	}
	return parse_srt_time(rest[:end])
}

stt_on_watch_line :: proc(s: string) {
	switch stt_watch_kind {
	case .None:
		return
	case .Curl:
		if p, ok := stt_parse_pct_line(s); ok do stt_local(p)
	case .FFmpeg:
		if t, ok := stt_parse_out_time(s); ok && stt_watch_dur > 0.05 {
			stt_local(t / stt_watch_dur)
		}
	case .Whisper:
		if p, ok := stt_parse_pct_line(s); ok {
			stt_local(p)
		} else if t, ok := stt_parse_arrow_time(s); ok && stt_src_dur > 0.2 {
			stt_local(t / stt_src_dur)
		}
	}
}

stt_spawn_wait :: proc(cmd: []string) -> bool {
	return stt_spawn_watch(cmd, .None, 0)
}

stt_spawn_watch :: proc(cmd: []string, kind: STTWatch, dur: f32) -> bool {
	if len(cmd) == 0 do return false
	stt_watch_kind = kind
	stt_watch_dur = dur
	desc := os.Process_Desc{ command = cmd }
	er, ew, epe := os.pipe()
	if epe == nil {
		desc.stderr = ew
		desc.stdout = ew
	}
	p, e := os.process_start(desc)
	if epe == nil do os.close(ew)
	if e != nil {
		if epe == nil do os.close(er)
		return false
	}
	if stt_job != nil do AssignProcessToJobObject(stt_job, win.HANDLE(p.handle))
	SetPriorityClass(win.HANDLE(p.handle), win.BELOW_NORMAL_PRIORITY_CLASS)
	if epe == nil {
		buf: [4096]u8
		line: [512]u8
		ll := 0
		for {
			if intrinsics.atomic_load(&stt_stop) || app_closing {
				_ = os.process_kill(p)
				break
			}
			n, rerr := os.read(er, buf[:])
			if n > 0 {
				for k in 0 ..< n {
					ch := buf[k]
					if ch == '\n' || ch == '\r' {
						if ll > 0 {
							stt_on_watch_line(string(line[:ll]))
							ll = 0
						}
					} else if ll < len(line) {
						line[ll] = ch
						ll += 1
					}
				}
			}
			if n <= 0 || rerr != nil do break
		}
		if ll > 0 do stt_on_watch_line(string(line[:ll]))
		os.close(er)
	}
	for {
		if intrinsics.atomic_load(&stt_stop) || app_closing {
			_ = os.process_kill(p)
			_, _ = os.process_wait(p)
			stt_watch_kind = .None
			return false
		}
		state, werr := os.process_wait(p, 50 * time.Millisecond)
		if state.exited {
			stt_watch_kind = .None
			return state.exit_code == 0
		}
		if werr != nil && werr != os.General_Error.Timeout {
			stt_watch_kind = .None
			return false
		}
	}
}

stt_fail :: proc(msg: string) {
	if stt_err != "" do delete(stt_err)
	stt_err = strings.clone(msg)
	intrinsics.atomic_store(&stt_phase, STTPhase.Fail)
}

stt_download :: proc(url, dest: string) -> bool {
	os.remove(dest)
	return stt_spawn_watch([]string{
		"curl.exe", "-L", "--fail", "--retry", "2", "--progress-bar", "-o", dest, url,
	}, .Curl, 0) && stt_exists(dest)
}

stt_ensure_cli :: proc(gpu: bool) -> string {
	if p := stt_find_cli(gpu); p != "" do return p
	dir := stt_dir()
	if !stt_mkdirs(dir) do return ""
	if gpu {
		cuda := fmt.tprintf("%s\\cuda", dir)
		if !stt_mkdirs(cuda) do return ""
		intrinsics.atomic_store(&stt_phase, STTPhase.FetchBin)
		stt_begin(stt_pct(), 0.15)
		stt_set_note("Baixando motor Whisper GPU (~270 MB, só na 1ª vez)…")
		zip := fmt.tprintf("%s\\whisper-cuda.zip", cuda)
		if !stt_download(STT_CUDA_ZIP, zip) do return ""
		_ = stt_spawn_wait([]string{ "tar.exe", "-xf", zip, "-C", cuda })
		os.remove(zip)
		return stt_find_named(cuda, "whisper-cli.exe", 3)
	}
	intrinsics.atomic_store(&stt_phase, STTPhase.FetchBin)
	stt_begin(stt_pct(), 0.15)
	stt_set_note("Baixando motor Whisper (~21 MB, só na 1ª vez)…")
	zip := fmt.tprintf("%s\\whisper-cpu.zip", dir)
	if !stt_download(STT_CPU_ZIP, zip) do return ""
	_ = stt_spawn_wait([]string{ "tar.exe", "-xf", zip, "-C", dir })
	os.remove(zip)
	return stt_find_cli(false)
}

stt_ensure_tools :: proc(want_gpu: bool) -> (cli, model: string, gpu: bool, ok: bool) {
	model = stt_find_model(STT_MODEL_FILE)
	gpu = want_gpu
	cli = stt_ensure_cli(gpu)
	if gpu && cli == "" {
		// CUDA falhou (sem internet, driver velho, zip enorme): cai no CPU
		gpu = false
		cli = stt_ensure_cli(false)
	}
	if cli == "" {
		stt_fail("Falha ao baixar o whisper-cli. Coloque whisper-cli.exe em AppData\\OdinVideoEditor\\stt")
		return
	}
	if model == "" {
		dir := stt_dir()
		if !stt_mkdirs(dir) {
			stt_fail("Não deu para criar a pasta do Whisper em AppData")
			return
		}
		intrinsics.atomic_store(&stt_phase, STTPhase.FetchModel)
		stt_begin(max(stt_pct(), 0.12), 0.42)
		stt_set_note(fmt.tprintf("Baixando modelo Máximo (~%d MB)…", STT_MODEL_MB))
		dest := fmt.tprintf("%s\\%s", dir, STT_MODEL_FILE)
		if !stt_download(fmt.tprintf("%s%s", STT_HF, STT_MODEL_FILE), dest) {
			stt_fail(fmt.tprintf("Falha ao baixar %s. Coloque o arquivo na pasta stt", STT_MODEL_FILE))
			return
		}
		model = strings.clone(dest)
	}
	return cli, model, gpu, true
}

// prompt enviado ao Whisper: só o idioma (nomes/marcas se corrigem depois, nas falas).
stt_build_prompt :: proc(lang: int) -> string {
	switch lang {
	case 1: return "Transcrição em português do Brasil."
	case 3: return "Transcripción en español."
	}
	return ""
}

// [Música], (applause) e afins — o -sns já corta a maior parte; isto limpa o resto.
cap_is_junk :: proc(s: string) -> bool {
	t := strings.trim_space(s)
	if t == "" do return true
	if len(t) >= 2 {
		a, b := t[0], t[len(t) - 1]
		if (a == '[' && b == ']') || (a == '(' && b == ')') do return true
	}
	return false
}

stt_wav_path :: proc() -> string {
	return fmt.tprintf("%s_%d_stt.wav", AUDIO_BASE, u32(win.GetCurrentProcessId()))
}
stt_srt_prefix :: proc() -> string {
	return fmt.tprintf("%s_%d_stt", AUDIO_BASE, u32(win.GetCurrentProcessId()))
}

stt_worker :: proc() {
	defer if stt_job != nil { win.CloseHandle(stt_job); stt_job = nil }
	si := stt_si
	if si < 0 || si >= nsegs {
		stt_fail("Clipe inválido")
		return
	}
	c := seg_src(si)
	sg := segs[si]
	if c.path == "" || (!c.src_audio && !c.has_audio) {
		stt_fail("Este clipe não tem áudio")
		return
	}
	cli, model, use_gpu, ok := stt_ensure_tools(stt_want_gpu)
	if !ok do return
	if intrinsics.atomic_load(&stt_stop) { stt_fail("Cancelado"); return }

	intrinsics.atomic_store(&stt_phase, STTPhase.Extract)
	ex0 := max(stt_pct(), 0.04)
	stt_begin(ex0, min(ex0 + 0.08, 0.50))
	wav := stt_wav_path()
	os.remove(wav)
	src0 := sg.in_off
	src_d := max(f32(0.2), sg.dur * (sg.speed <= 0 ? 1 : sg.speed))
	if !stt_spawn_watch([]string{
		"ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
		"-progress", "pipe:2", "-nostats",
		"-ss", fmt.tprintf("%.3f", src0), "-t", fmt.tprintf("%.3f", src_d),
		"-i", c.path, "-vn", "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", wav,
	}, .FFmpeg, src_d) || !stt_exists(wav) {
		stt_fail("Falha ao extrair o áudio do clipe")
		return
	}
	if intrinsics.atomic_load(&stt_stop) { os.remove(wav); stt_fail("Cancelado"); return }

	intrinsics.atomic_store(&stt_phase, STTPhase.Talk)
	stt_begin(max(stt_pct(), 0.12), 1)
	stt_set_note(fmt.tprintf("Transcrevendo (Máximo%s)…",
		use_gpu ? " · GPU" : ""))
	pref := stt_srt_prefix()
	os.remove(fmt.tprintf("%s.srt", pref))
	lang := STT_LANGC[clamp(stt_lang, 0, len(STT_LANGC) - 1)]
	prompt := stt_build_prompt(stt_lang)
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, cli, "-m", model, "-f", wav, "-l", lang,
		"-osrt", "-of", pref, "-ml", "48", "-sow", "-np", "-pp", "-sns", "-t", "4")
	if !use_gpu do append(&cmd, "-ng")
	if prompt != "" do append(&cmd, "--prompt", prompt)
	if !stt_spawn_watch(cmd[:], .Whisper, 0) {
		if intrinsics.atomic_load(&stt_stop) { os.remove(wav); stt_fail("Cancelado"); return }
		// GPU recusou (CUDA ausente / DLL): uma tentativa por CPU
		if use_gpu {
			if cpu := stt_ensure_cli(false); cpu != "" {
				clear(&cmd)
				append(&cmd, cpu, "-m", model, "-f", wav, "-l", lang,
					"-osrt", "-of", pref, "-ml", "48", "-sow", "-np", "-pp", "-sns", "-ng", "-t", "4")
				if prompt != "" do append(&cmd, "--prompt", prompt)
				stt_set_note("GPU falhou — tentando de novo na CPU…")
				if stt_spawn_watch(cmd[:], .Whisper, 0) do use_gpu = false
			}
		}
		if use_gpu || !stt_exists(fmt.tprintf("%s.srt", pref)) {
			os.remove(wav)
			stt_fail("O Whisper falhou ao transcrever. Tente outro idioma ou um trecho menor")
			return
		}
	}
	os.remove(wav)
	data, rerr := os.read_entire_file(fmt.tprintf("%s.srt", pref), context.allocator)
	os.remove(fmt.tprintf("%s.srt", pref))
	if rerr != nil || len(data) == 0 {
		stt_fail("O Whisper não gerou legendas (sem fala?)")
		return
	}
	if stt_srt != "" do delete(stt_srt)
	stt_srt = string(data)
	stt_set_pct(1)
	intrinsics.atomic_store(&stt_phase, STTPhase.Done)
}

// SRT "00:00:01,234" / "00:00:01.234" → segundos.
parse_srt_time :: proc(s: string) -> (f32, bool) {
	t := strings.trim_space(s)
	if t == "" do return 0, false
	// aceita vírgula ou ponto nos milissegundos
	buf: [32]u8
	n := 0
	for i in 0 ..< len(t) {
		if n >= len(buf) do break
		buf[n] = t[i] == ',' ? '.' : t[i]
		n += 1
	}
	u := string(buf[:n])
	// H:MM:SS.mmm ou MM:SS.mmm
	parts := strings.split(u, ":", context.temp_allocator)
	if len(parts) < 2 || len(parts) > 3 do return 0, false
	sec, ok := strconv.parse_f64(parts[len(parts) - 1])
	if !ok do return 0, false
	min, okm := strconv.parse_int(parts[len(parts) - 2])
	if !okm do return 0, false
	hr := 0
	if len(parts) == 3 {
		hrok: bool
		hr, hrok = strconv.parse_int(parts[0])
		if !hrok do return 0, false
	}
	return f32(f64(hr) * 3600 + f64(min) * 60 + sec), true
}

// parseia um SRT e devolve falas com `offset` somado (in_off da fonte).
parse_srt :: proc(s: string, offset: f32, alloc := context.allocator) -> [dynamic]CapCue {
	out := make([dynamic]CapCue, alloc)
	if s == "" do return out
	norm, _ := strings.replace_all(s, "\r\n", "\n", context.temp_allocator)
	norm, _ = strings.replace_all(norm, "\r", "\n", context.temp_allocator)
	start := 0
	n := len(norm)
	for start <= n {
		end := n
		// bloco até linha em branco
		i := start
		for i < n {
			if norm[i] == '\n' && (i + 1 >= n || norm[i + 1] == '\n') {
				end = i
				break
			}
			i += 1
		}
		block := strings.trim_space(norm[start:end])
		start = end + 1
		for start < n && norm[start] == '\n' do start += 1
		if block == "" {
			if end >= n do break
			continue
		}
		lines := strings.split_lines(block, context.temp_allocator)
		// pula índice numérico se for a 1ª linha
		li := 0
		if len(lines) > 0 {
			only_num := true
			for ch in lines[0] {
				if ch < '0' || ch > '9' { only_num = false; break }
			}
			if only_num do li = 1
		}
		if li >= len(lines) do continue
		arrow := strings.index(lines[li], "-->")
		if arrow < 0 do continue
		t0, ok0 := parse_srt_time(lines[li][:arrow])
		t1, ok1 := parse_srt_time(lines[li][arrow + 3:])
		if !ok0 || !ok1 || t1 <= t0 do continue
		txt := strings.builder_make(context.temp_allocator)
		for k in li + 1 ..< len(lines) {
			ln := strings.trim_space(lines[k])
			if ln == "" do continue
			if strings.builder_len(txt) > 0 do strings.write_byte(&txt, ' ')
			strings.write_string(&txt, ln)
		}
		body := strings.trim_space(strings.to_string(txt))
		if body == "" || cap_is_junk(body) do continue
		append(&out, CapCue{ t0 + offset, t1 + offset, strings.clone(body, alloc) })
		if end >= n do break
	}
	return out
}

stt_cues_free :: proc() {
	for q in stt_cues do delete(q.text)
	delete(stt_cues)
	stt_cues = nil
}

stt_adopt_srt :: proc() {
	stt_cues_free()
	stt_cues = parse_srt(stt_srt, stt_in)
}

stt_join :: proc() {
	if stt_thr == nil do return
	thread.join(stt_thr)
	thread.destroy(stt_thr)
	stt_thr = nil
}

stt_cancel_run :: proc() {
	intrinsics.atomic_store(&stt_stop, true)
	if stt_job != nil do TerminateJobObject(stt_job, 1)
	stt_join()
	os.remove(stt_wav_path())
	os.remove(fmt.tprintf("%s.srt", stt_srt_prefix()))
}

stt_close :: proc() {
	ph := intrinsics.atomic_load(&stt_phase)
	if ph != .Idle && ph != .Done && ph != .Fail do stt_cancel_run()
	else do stt_join()
	modal = .None
	stt_si = -1
	stt_eat = false
	stt_scroll = 0
	cue_edit_reset()
	stt_cues_free()
	if stt_srt != "" { delete(stt_srt); stt_srt = "" }
	if stt_err != "" { delete(stt_err); stt_err = "" }
	intrinsics.atomic_store(&stt_phase, STTPhase.Idle)
}

open_stt_modal :: proc() {
	if selected < 0 || selected >= nsegs { set_toast("Selecione um clipe com áudio"); return }
	c := seg_src(selected)
	if c.is_text || (!c.src_audio && !c.has_audio) { set_toast("Este clipe não tem áudio"); return }
	if !seg_ready(selected) { set_toast("Aguarde o clipe terminar de importar"); return }
	st.playing = false
	stt_join()
	stt_cues_free()
	if stt_srt != "" { delete(stt_srt); stt_srt = "" }
	if stt_err != "" { delete(stt_err); stt_err = "" }
	stt_si = selected
	stt_in = segs[selected].in_off
	stt_src_dur = segs[selected].dur * seg_speed(selected)
	stt_scroll = 0
	stt_eat = true
	cue_edit_reset()
	if !stt_gpu_set { stt_gpu = export_nvenc_ok; stt_gpu_set = true }
	intrinsics.atomic_store(&stt_stop, false)
	intrinsics.atomic_store(&stt_phase, STTPhase.Idle)
	modal = .STT
}

stt_busy :: proc() -> bool {
	ph := intrinsics.atomic_load(&stt_phase)
	return ph == .Prep || ph == .FetchBin || ph == .FetchModel || ph == .Extract || ph == .Talk
}

stt_start :: proc() {
	if stt_busy() do return
	if stt_si < 0 || stt_si >= nsegs { set_toast("Selecione um clipe com áudio"); return }
	stt_join()
	cue_edit_reset()
	stt_cues_free()
	if stt_srt != "" { delete(stt_srt); stt_srt = "" }
	if stt_err != "" { delete(stt_err); stt_err = "" }
	stt_in = segs[stt_si].in_off
	stt_src_dur = segs[stt_si].dur * seg_speed(stt_si)
	stt_want_gpu = stt_gpu && export_nvenc_ok
	stt_reset_pct()
	stt_begin(0, 0.04)
	stt_set_note("Preparando…")
	intrinsics.atomic_store(&stt_stop, false)
	intrinsics.atomic_store(&stt_phase, STTPhase.Prep)
	stt_job = make_kill_job()
	stt_thr = thread.create_and_start(stt_worker)
}

stt_apply :: proc() -> int {
	cue_commit(&stt_cues, nil)
	if len(stt_cues) == 0 do stt_adopt_srt()
	if len(stt_cues) == 0 { set_toast("Nenhuma fala para aplicar"); return 0 }
	if stt_si < 0 || stt_si >= nsegs { set_toast("Clipe de origem sumiu"); return 0 }
	sg := segs[stt_si]
	src := seg_src(stt_si)
	slot := new_caps_clip(stt_cues[:], 0.050, rl.WHITE, max(src.dur, sg.in_off + sg.dur * seg_speed(stt_si)))
	if slot < 0 do return 0
	cap_apply_preset(&clips[slot], .YouTube)
	tr := free_track_from(g_nv - 1)
	if tr < 0 { set_toast("Trilha bloqueada"); return 0 }
	ni := add_seg(slot, sg.start, sg.in_off, sg.dur, tr)
	if ni < 0 { set_toast("Timeline cheia"); return 0 }
	segs[ni].speed = sg.speed
	segs[ni].py = 0.38
	segs[ni].opacity = 1
	selected = ni
	bin_sel = -1
	insp_tab = 0
	return len(stt_cues)
}

stt_apply_and_close :: proc() {
	n := stt_apply()
	stt_close()
	if n > 0 do set_toast(rl.TextFormat("Legendas adicionadas (%d fala(s))", i32(n)))
}

cue_edit_reset :: proc() {
	cue_edit = -1
	cue_focus = false
	tf_cue.len = 0
	tf_cue.caret = 0
	tf_cue.sel = 0
	tf_cue.scroll = 0
	tf_cue.drag = false
}

cue_commit :: proc(cues: ^[dynamic]CapCue, owner: ^Clip) {
	if cue_edit < 0 { cue_focus = false; return }
	i := cue_edit
	s := strings.trim_space(string(tf_cue.buf[:tf_cue.len]))
	cue_edit = -1
	cue_focus = false
	if i >= len(cues^) do return
	if s == "" {
		if owner != nil do caps_delete_at(owner, i)
		else do cap_delete_at(cues, i)
		return
	}
	if owner != nil do caps_set_text(owner, i, s)
	else do cap_set_text(cues, i, s)
}

cue_begin :: proc(cues: ^[dynamic]CapCue, owner: ^Clip, i: int) {
	if i < 0 || i >= len(cues^) do return
	if cue_edit == i { cue_focus = true; return }
	if cue_edit >= 0 do cue_commit(cues, owner)
	if i >= len(cues^) do return
	cue_edit = i
	cue_focus = true
	tf_set(&tf_cue, cues^[i].text)
}

cue_commit_active :: proc() {
	if cue_edit < 0 { cue_focus = false; return }
	if modal == .Caps {
		if caps_edit_si < 0 || caps_edit_si >= nsegs { cue_edit_reset(); return }
		c := seg_src(caps_edit_si)
		if !c.is_caps { cue_edit_reset(); return }
		cue_commit(&c.caps, c)
		return
	}
	cue_commit(&stt_cues, nil)
}

// lista de falas editável (prévia do Whisper e modal da faixa).
draw_cue_list :: proc(lane: rl.Rectangle, cues: ^[dynamic]CapCue, owner: ^Clip, scroll: ^f32, eat: bool) {
	if len(cues^) == 0 {
		txt_c("Nenhuma fala. Adicione uma ou transcreva de novo.", lane.x + lane.width/2, lane.y + 40, 12, MUTED)
		return
	}
	row_h: f32 = 32
	max_scroll := max(f32(0), f32(len(cues^))*row_h - lane.height + 8)
	if hovered(lane) {
		scroll^ = clamp(scroll^ - rl.GetMouseWheelMove() * 36, 0, max_scroll)
	}
	rl.BeginScissorMode(i32(lane.x+1), i32(lane.y+1), i32(lane.width-2), i32(lane.height-2))
	i := 0
	for i < len(cues^) {
		yy := lane.y + 6 + f32(i)*row_h - scroll^
		if yy + row_h < lane.y || yy > lane.y + lane.height { i += 1; continue }
		row := rl.Rectangle{ lane.x + 2, yy, lane.width - 4, row_h - 4 }
		on := cue_edit == i
		if on do rl.DrawRectangleRounded(row, 0.15, 4, rl.Color{ 40, 48, 62, 255 })
		else if !eat && hovered(row) do rl.DrawRectangleRounded(row, 0.15, 4, HOVER)
		tc := rl.TextFormat("%s–%s", timecode(cues^[i].t0), timecode(cues^[i].t1))
		txt(tc, lane.x + 8, yy + 6, 11, MUTED)
		xr := rl.Rectangle{ lane.x + lane.width - 30, yy + 4, 20, 20 }
		xh := !eat && hovered(xr)
		txt_c("×", xr.x + 10, xr.y + 2, 14, xh ? rl.Color{ 220, 120, 110, 255 } : MUTED)
		if !eat && clicked(xr) {
			if cue_edit == i { cue_edit_reset() }
			else if cue_edit > i { cue_edit -= 1 }
			if owner != nil do caps_delete_at(owner, i)
			else do cap_delete_at(cues, i)
			continue
		}
		fr := rl.Rectangle{ lane.x + 118, yy + 2, lane.width - 154, row_h - 8 }
		if on {
			rl.DrawRectangleRounded(fr, 0.2, 4, PANEL2)
			if tf_field(&tf_cue, fr, &cue_focus, true) {
				s := strings.trim_space(string(tf_cue.buf[:tf_cue.len]))
				if s != "" {
					if owner != nil do caps_set_text(owner, i, s)
					else do cap_set_text(cues, i, s)
				}
			}
			rl.DrawRectangleRoundedLinesEx(fr, 0.2, 4, 1, cue_focus ? ACCENT : LINE)
			if !cue_focus {
				cue_commit(cues, owner)
				continue
			}
			if rl.IsKeyPressed(.ENTER) {
				cue_commit(cues, owner)
				continue
			}
		} else {
			txt(elide(cues^[i].text, 12, fr.width), fr.x + 4, yy + 6, 12, TEXT)
			if !eat && (clicked(fr) || (clicked(row) && !hovered(xr))) {
				cue_begin(cues, owner, i)
			}
		}
		i += 1
	}
	rl.EndScissorMode()
}

open_caps_editor :: proc() {
	if selected < 0 || selected >= nsegs { set_toast("Selecione a faixa de legendas"); return }
	c := seg_src(selected)
	if !c.is_caps { set_toast("Selecione a faixa de legendas"); return }
	st.playing = false
	caps_edit_si = selected
	caps_scroll = 0
	caps_eat = true
	cue_edit_reset()
	modal = .Caps
}

caps_close :: proc() {
	cue_commit_active()
	caps_edit_si = -1
	caps_eat = false
	caps_scroll = 0
	cue_edit_reset()
	if modal == .Caps do modal = .None
}

caps_add_at_playhead :: proc() {
	if caps_edit_si < 0 || caps_edit_si >= nsegs do return
	c := seg_src(caps_edit_si)
	if !c.is_caps do return
	sg := segs[caps_edit_si]
	spd := seg_speed(caps_edit_si)
	t := sg.in_off + (st.playhead - sg.start) * spd
	t = clamp(t, 0, max(c.dur, sg.in_off + sg.dur * spd))
	t1 := t + 2
	for q in c.caps {
		if q.t0 > t && q.t0 < t1 do t1 = q.t0
	}
	if t1 - t < 0.2 do t1 = t + 0.2
	i := caps_insert(c, t, t1, "Nova fala")
	if i >= 0 do cue_begin(&c.caps, c, i)
}

draw_caps_modal :: proc(sw, sh: f32) {
	if caps_eat && !rl.IsMouseButtonDown(.LEFT) do caps_eat = false
	if caps_edit_si < 0 || caps_edit_si >= nsegs { caps_close(); return }
	c := seg_src(caps_edit_si)
	if !c.is_caps { caps_close(); return }

	rl.DrawRectangleRec({0, 0, sw, sh}, rl.Color{0, 0, 0, 150})
	cw: f32 = 680; ch: f32 = 520
	cx := sw/2 - cw/2; cy := sh/2 - ch/2
	card := rl.Rectangle{ cx, cy, cw, ch }
	rl.DrawRectangleRounded(card, 0.03, 8, rl.Color{ 30, 33, 40, 255 })
	rl.DrawRectangleRoundedLinesEx(card, 0.03, 8, 1, LINE)
	txt("Editar falas", cx + 20, cy + 14, 16, TEXT)
	txt(rl.TextFormat("%d fala(s)  ·  clique o texto para corrigir  ·  × apaga", i32(len(c.caps))),
		cx + 20, cy + 38, 12, MUTED)
	xr := rl.Rectangle{ cx + cw - 36, cy + 12, 22, 22 }
	if clicked(xr) && !caps_eat do caps_close()
	rl.DrawLineEx({xr.x+5, xr.y+5}, {xr.x+15, xr.y+15}, 1.8, hovered(xr) ? TEXT : MUTED)
	rl.DrawLineEx({xr.x+15, xr.y+5}, {xr.x+5, xr.y+15}, 1.8, hovered(xr) ? TEXT : MUTED)

	lane := rl.Rectangle{ cx + 20, cy + 64, cw - 40, ch - 128 }
	rl.DrawRectangleRec(lane, rl.Color{ 24, 26, 32, 255 })
	rl.DrawRectangleLinesEx(lane, 1, LINE)
	draw_cue_list(lane, &c.caps, c, &caps_scroll, caps_eat)

	if ui_btn({ cx + 20, cy + ch - 48, 110, 32 }, "Fechar", false) && !caps_eat do caps_close()
	if ui_btn({ cx + cw - 170, cy + ch - 48, 150, 32 }, "Nova fala", true) && !caps_eat {
		caps_add_at_playhead()
	}
}

stt_phase_label :: proc(ph: STTPhase) -> cstring {
	if n := stt_note(); n != "" && (ph == .Prep || ph == .FetchBin || ph == .FetchModel || ph == .Talk) {
		return cs(n)
	}
	switch ph {
	case .Idle:       return "Pronto para transcrever o clipe selecionado."
	case .Prep:       return "Preparando…"
	case .FetchBin:   return "Baixando o motor Whisper…"
	case .FetchModel: return "Baixando o modelo de fala…"
	case .Extract:    return "Extraindo o áudio do clipe…"
	case .Talk:       return "Transcrevendo… pode levar alguns minutos."
	case .Done:       return ""
	case .Fail:       return ""
	}
	return ""
}

draw_stt_modal :: proc(sw, sh: f32) {
	if stt_eat && !rl.IsMouseButtonDown(.LEFT) do stt_eat = false
	if stt_si < 0 || stt_si >= nsegs { stt_close(); return }
	ph := intrinsics.atomic_load(&stt_phase)
	if ph == .Done && len(stt_cues) == 0 && stt_srt != "" do stt_adopt_srt()

	rl.DrawRectangleRec({0, 0, sw, sh}, rl.Color{0, 0, 0, 150})
	cw: f32 = 640; ch: f32 = 500
	cx := sw/2 - cw/2; cy := sh/2 - ch/2
	card := rl.Rectangle{ cx, cy, cw, ch }
	rl.DrawRectangleRounded(card, 0.03, 8, rl.Color{ 30, 33, 40, 255 })
	rl.DrawRectangleRoundedLinesEx(card, 0.03, 8, 1, LINE)
	txt("Voz para texto", cx + 20, cy + 14, 16, TEXT)
	xr := rl.Rectangle{ cx + cw - 36, cy + 12, 22, 22 }
	if clicked(xr) && !stt_eat do stt_close()
	rl.DrawLineEx({xr.x+5, xr.y+5}, {xr.x+15, xr.y+15}, 1.8, hovered(xr) ? TEXT : MUTED)
	rl.DrawLineEx({xr.x+15, xr.y+5}, {xr.x+5, xr.y+15}, 1.8, hovered(xr) ? TEXT : MUTED)

	x := cx + 20; y := cy + 48
	txt("Idioma da fala", x, y, 12, TEXT); y += 22
	bw := (cw - 48) / f32(len(STT_LANGS))
	busy := stt_busy()
	for lab, i in STT_LANGS {
		r := rl.Rectangle{ x + f32(i)*bw, y, bw - 8, 26 }
		on := i == stt_lang
		rl.DrawRectangleRounded(r, 0.3, 6, on ? ACCENT_D : (hovered(r) && !busy ? HOVER : PANEL2))
		txt_c(lab, r.x + r.width/2, r.y + 6, 12, on ? rl.WHITE : TEXT)
		if !busy && !stt_eat && clicked(r) do stt_lang = i
	}
	y += 36
	if export_nvenc_ok {
		chk := rl.Rectangle{ x, y, 18, 18 }
		if !busy && !stt_eat && clicked({ x, y, 400, 18 }) {
			stt_gpu = !stt_gpu
			stt_gpu_set = true
		}
		rl.DrawRectangleRoundedLinesEx(chk, 0.2, 4, 1.5, stt_gpu ? ACCENT : MUTED)
		if stt_gpu do rl.DrawRectangleRec({ chk.x + 4, chk.y + 4, 10, 10 }, ACCENT)
		txt("GPU NVIDIA (bem mais rápido)", x + 26, y + 2, 12, TEXT)
		y += 26
	}
	txt("Modelo Máximo. Vem em stt\\ com o editor; GPU baixa na primeira vez.", x, y, 11, MUTED)
	y += 20
	if ui_btn({ x, y, 160, 30 }, busy ? "Cancelar" : "Transcrever", !busy) {
		if !stt_eat {
			if busy do stt_cancel_run()
			else do stt_start()
		}
	}
	y += 42

	switch ph {
	case .Fail:
		msg := stt_err != "" ? cs(stt_err) : "Falha na transcrição"
		txt(msg, x, y, 12, rl.Color{ 220, 120, 110, 255 })
	case .Done:
		txt(rl.TextFormat("%d fala(s)  ·  clique para editar  ·  × apaga  ·  Aplicar cria a faixa", i32(len(stt_cues))),
			x, y, 12, ACCENT)
	case .Idle:
		txt(stt_phase_label(ph), x, y, 12, MUTED)
	case .Prep, .FetchBin, .FetchModel, .Extract, .Talk:
		pct := stt_pct()
		txt(stt_phase_label(ph), x, y, 12, ACCENT)
		txt(rl.TextFormat("%d%%", i32(pct*100 + 0.5)), x + cw - 72, y, 12, ACCENT)
		bar := rl.Rectangle{ x, y + 22, cw - 40, 8 }
		rl.DrawRectangleRounded(bar, 1, 4, LINE)
		fill := max(f32(2), pct * bar.width)
		rl.DrawRectangleRounded({ bar.x, bar.y, fill, bar.height }, 1, 4, ACCENT)
	}
	y += 40

	lane := rl.Rectangle{ x, y, cw - 40, ch - (y - cy) - 64 }
	rl.DrawRectangleRec(lane, rl.Color{ 24, 26, 32, 255 })
	rl.DrawRectangleLinesEx(lane, 1, LINE)
	if ph == .Done && len(stt_cues) == 0 {
		txt_c("Nenhuma fala encontrada nesse trecho.", lane.x + lane.width/2, lane.y + 40, 12, MUTED)
	} else if len(stt_cues) > 0 {
		draw_cue_list(lane, &stt_cues, nil, &stt_scroll, stt_eat || stt_busy())
	} else if ph == .Idle {
		txt_c("As falas aparecem aqui depois de Transcrever.", lane.x + lane.width/2, lane.y + 40, 12, MUTED)
	}

	if ui_btn({ cx + 20, cy + ch - 48, 110, 32 }, "Fechar", false) && !stt_eat do stt_close()
	can := ph == .Done && len(stt_cues) > 0
	ar := rl.Rectangle{ cx + cw - 230, cy + ch - 48, 210, 32 }
	if can {
		rl.DrawRectangleRounded(ar, 0.4, 8, hovered(ar) ? ACCENT : ACCENT_D)
		txt_c("Aplicar na timeline", ar.x + ar.width/2, ar.y + 8, 13, rl.WHITE)
		if clicked(ar) && !stt_eat do stt_apply_and_close()
	} else {
		rl.DrawRectangleRounded(ar, 0.4, 8, rl.Color{ 50, 54, 62, 255 })
		txt_c("Aplicar na timeline", ar.x + ar.width/2, ar.y + 8, 13, MUTED)
	}
}
