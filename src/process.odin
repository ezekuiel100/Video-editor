package main

import rl "vendor:raylib"
import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import win "core:sys/windows"

// ---------- processos filhos: job object + prioridade ----------
// Job com KILL_ON_JOB_CLOSE: todo ffmpeg é atribuído a ele, e o kernel mata o
// job inteiro quando o último handle fecha — ou seja, quando o editor morre,
// MESMO em crash/kill. Sem isso, decoders ao vivo sobreviviam como órfãos
// presos no pipe. core:sys/windows não expõe Job Objects nem SetPriorityClass;
// bindings manuais abaixo (layouts x64 conferidos com o SDK do Windows).
JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE :: 0x00002000
JobObjectExtendedLimitInformation  :: i32(9)

IO_COUNTERS :: struct {
	ReadOperationCount, WriteOperationCount, OtherOperationCount: u64,
	ReadTransferCount, WriteTransferCount, OtherTransferCount:    u64,
}
JOBOBJECT_BASIC_LIMIT_INFORMATION :: struct {
	PerProcessUserTimeLimit: i64,
	PerJobUserTimeLimit:     i64,
	LimitFlags:              u32,
	MinimumWorkingSetSize:   uint,
	MaximumWorkingSetSize:   uint,
	ActiveProcessLimit:      u32,
	Affinity:                uint,
	PriorityClass:           u32,
	SchedulingClass:         u32,
}
JOBOBJECT_EXTENDED_LIMIT_INFORMATION :: struct {
	BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION,
	IoInfo:                IO_COUNTERS,
	ProcessMemoryLimit:    uint,
	JobMemoryLimit:        uint,
	PeakProcessMemoryUsed: uint,
	PeakJobMemoryUsed:     uint,
}

foreign import kernel32 "system:Kernel32.lib"
@(default_calling_convention="system")
foreign kernel32 {
	CreateJobObjectW         :: proc(attrs: rawptr, name: win.LPCWSTR) -> win.HANDLE ---
	SetInformationJobObject  :: proc(job: win.HANDLE, class: i32, info: rawptr, len: u32) -> win.BOOL ---
	AssignProcessToJobObject :: proc(job: win.HANDLE, ps: win.HANDLE) -> win.BOOL ---
	TerminateJobObject       :: proc(job: win.HANDLE, exit_code: u32) -> win.BOOL ---
	SetPriorityClass         :: proc(ps: win.HANDLE, class: u32) -> win.BOOL ---
}

// FECHANDO o app: sinaliza a TODOS os workers (globais e por-clipe) p/ não spawnar/retomar
// mais ffmpeg. Sem isto, workers como scrub/respawn re-spawnavam um decoder DEPOIS que o job
// foi morto (escapando dele) e o read bloqueante travava o join no shutdown — mesmo com os
// vídeos JÁ na timeline (scrub/playback ao vivo ativos).
app_closing: bool

// pausar/retomar a exportação = suspender/retomar TODAS as threads do processo ffmpeg.
// O Windows não tem SIGSTOP; NtSuspendProcess/NtResumeProcess (ntdll, não documentadas
// mas estáveis há décadas) fazem exatamente isso.
foreign import ntdll "system:ntdll.lib"
@(default_calling_convention="system")
foreign ntdll {
	NtSuspendProcess :: proc(ps: win.HANDLE) -> i32 ---
	NtResumeProcess  :: proc(ps: win.HANDLE) -> i32 ---
}

g_job: win.HANDLE

job_init :: proc() {
	g_job = CreateJobObjectW(nil, nil)
	if g_job == nil do return
	info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION
	info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
	if !SetInformationJobObject(g_job, JobObjectExtendedLimitInformation, &info, u32(size_of(info))) {
		win.CloseHandle(g_job)
		g_job = nil
	}
}

// ---------- log de diagnóstico (arquivo, ligado por F4) ----------
// Grava eventos do decoder com timestamp (ms desde o start da captura) num arquivo ao lado
// do .exe — p/ depurar problemas que só aparecem em USO REAL (travadinha no playback, scrub
// preso na miniatura) e que as medições isoladas do ffmpeg não revelam. F4 liga (zera o
// arquivo) / desliga. Thread-safe (workers de decode E a main gravam) via mutex.
dbg_on:   bool // atômico: capturando
dbg_f:    ^os.File
dbg_mtx:  sync.Mutex
dbg_t0:   time.Tick
dbg_hb_t: time.Tick // último heartbeat de estado (STATE) durante o playback
dbg_vframes: int // frames de vídeo streaming que subiram p/ a textura desde o último heartbeat (fps REAL do vídeo)
dbg_thumb_frames: int // frames em que o draw mostrou a MINIATURA durante o playback (flash borrado) desde o HB
dbg_path: string // caminho do log (heap, dono) — mostrado no toast

dbg_toggle :: proc() {
	if intrinsics.atomic_load(&dbg_on) {
		intrinsics.atomic_store(&dbg_on, false)
		sync.mutex_lock(&dbg_mtx)
		if dbg_f != nil { os.flush(dbg_f); os.close(dbg_f); dbg_f = nil }
		sync.mutex_unlock(&dbg_mtx)
		set_toast("Diagnóstico PARADO (log salvo)")
		return
	}
	dir := EXE_DIR != "" ? EXE_DIR : "."
	if dbg_path == "" do dbg_path = fmt.aprintf("%s\\decoder_log.txt", dir)
	f, e := os.open(dbg_path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC)
	if e != nil { set_toast("Falha ao abrir o log de diagnóstico"); return }
	sync.mutex_lock(&dbg_mtx); dbg_f = f; sync.mutex_unlock(&dbg_mtx)
	dbg_t0 = time.tick_now()
	intrinsics.atomic_store(&dbg_on, true)
	dbg("INICIO", "captura ligada — g_refresh=%dHz monitor=%dHz vsync=hint", g_refresh, rl.GetMonitorRefreshRate(rl.GetCurrentMonitor()))
	set_toast("Diagnóstico GRAVANDO — reproduza o problema e aperte F4")
}

// grava uma linha no log se a captura estiver ligada. `kind` é uma etiqueta curta (RESPAWN,
// SCRUB, HWREJECT, EOF, HITCH...). Formata em buffers de STACK (bprintf) — os workers de
// decode são threads de vida longa sem free do temp allocator, então tprintf vazaria ali.
dbg :: proc(kind: string, format: string, args: ..any) {
	if !intrinsics.atomic_load(&dbg_on) do return
	ms := time.duration_milliseconds(time.tick_diff(dbg_t0, time.tick_now()))
	hb: [64]u8;  hdr  := fmt.bprintf(hb[:], "[%10.1f] %-8s ", ms, kind)
	bb: [512]u8; body := fmt.bprintf(bb[:], format, ..args) // 512: a linha AUDIO tem muitos campos
	sync.mutex_lock(&dbg_mtx); defer sync.mutex_unlock(&dbg_mtx)
	if dbg_f == nil do return
	os.write_string(dbg_f, hdr)
	os.write_string(dbg_f, body)
	os.write_string(dbg_f, "\n")
}

// cria um Job Object com KILL_ON_JOB_CLOSE (mata os processos quando o último handle
// fecha — no fim normal via clip_close, ou no crash pela morte do processo dono).
make_kill_job :: proc() -> win.HANDLE {
	j := CreateJobObjectW(nil, nil)
	if j == nil do return nil
	info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION
	info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
	if !SetInformationJobObject(j, JobObjectExtendedLimitInformation, &info, u32(size_of(info))) {
		win.CloseHandle(j); return nil
	}
	return j
}

// registra o processo no Job do PRÓPRIO clipe (fechar o job mata só os ffmpeg dele —
// essencial p/ remover um vídeo grande sem travar no join de um read bloqueado) e, se
// bg=true, baixa a prioridade p/ BELOW_NORMAL (trabalho de fundo não disputa CPU).
tame_process :: proc(c: ^Clip, p: os.Process, bg: bool) {
	if c.job != nil do AssignProcessToJobObject(c.job, win.HANDLE(p.handle))
	if bg do SetPriorityClass(win.HANDLE(p.handle), win.BELOW_NORMAL_PRIORITY_CLASS)
}

// FECHAMENTO INSTANTÂNEO. O teardown "educado" (juntar todas as threads) era lento por 3
// motivos: o worker de fontes SDF (`tf_thr`) é CPU puro e não checa `stop` -> o join podia
// esperar ~2.5s; cada ffmpeg de fundo só morria no polling de 50ms do `audio_extract_wait`,
// somando centenas de ms por vários clipes; e o `CloseAudioDevice`/`CloseWindow` do raylib
// desmontava WASAPI+GL (~100-200ms). Nada disso é necessário: o SO recupera RAM/GL/threads/
// áudio ao sair. Aqui só matamos todo ffmpeg de uma vez (libera os handles dos temporários),
// soltamos os handles de áudio do raylib, apagamos os temporários e saímos.
// NÃO liberamos (delete) nenhum buffer: um worker ainda pode estar escrevendo nele — como
// não liberamos nada, não há use-after-free; o os.exit encerra as threads em bloco.
close_now :: proc() {
	intrinsics.atomic_store(&app_closing, true) // barra qualquer novo spawn de ffmpeg
	intrinsics.atomic_store(&scrub_run, false)
	// 1) mata TODO ffmpeg em voo -> solta os handles dos temporários que ele escreve
	for i in 0 ..< nclips {
		intrinsics.atomic_store(&clips[i].stop, true)
		if clips[i].job != nil do TerminateJobObject(clips[i].job, 1)
	}
	if export_job != nil do TerminateJobObject(export_job, 1)
	// 2) solta os handles de áudio do raylib -> libera o temporário que cada stream toca
	for i in 0 ..< nclips do if clips[i].has_audio do rl.UnloadMusicStream(clips[i].music)
	for i in 0 ..< MAX_SEGS do for s in 0 ..< 2 do if spv[i][s].ok do rl.UnloadMusicStream(spv[i][s].music)
	// 3) apaga os temporários deste processo (os mesmos que clip_close/spv_release removiam)
	for i in 0 ..< nclips {
		c := &clips[i]
		if c.aud_path == "" do continue // slot vazio/tombstone (já limpo) ou imagem sem áudio
		os.remove(c.aud_path)
		os.remove(c.aud_head)
		os.remove(c.aud_ck[0])
		os.remove(c.aud_ck[1])
		os.remove(part_path(c, 0)) // OGG completo
	}
	for i in 0 ..< MAX_SEGS do for s in 0 ..< 2 do if spv[i][s].path != "" do os.remove(spv[i][s].path)
	if spv_render_path != "" do os.remove(spv_render_path) // render em voo (o Job mata o ffmpeg)
	for t in spv_trash do os.remove(t)                     // lixeira ainda não varrida
	// 4) sai — sem joins, sem desmontar o raylib; Jobs KILL_ON_JOB_CLOSE varrem o que escapou
	os.exit(0)
}

hide_child_consoles :: proc() {
	if !bool(win.AllocConsole()) do return // já tinha console (ex.: aberto de um terminal) — não mexe
	hwnd := win.GetConsoleWindow()
	if hwnd == nil do return
	// ShowWindow é chamado via GetProcAddress (runtime) DE PROPÓSITO: linkar User32.lib estático
	// colide com o CloseWindow/ShowCursor que o raylib.lib já define com os mesmos nomes (LNK2005).
	ShowWindow_t :: proc "system" (hWnd: win.HWND, nCmdShow: i32) -> win.BOOL
	if u := win.LoadLibraryW(win.utf8_to_wstring("user32.dll")); u != nil {
		if p := win.GetProcAddress(u, "ShowWindow"); p != nil {
			(cast(ShowWindow_t) p)(hwnd, i32(win.SW_HIDE))
		}
	}
}

// resolve caminhos que dependem da MÁQUINA (não podem ser fixos no fonte): a base de temp no
// %TEMP% real do usuário e a pasta do próprio .exe, que é inserida no INÍCIO do PATH para que
// os "ffmpeg"/"ffprobe" chamados pelo nome resolvam para os binários EMPACOTADOS ao lado do
// editor (assim o app funciona sem o usuário instalar/configurar ffmpeg).
init_paths :: proc() {
	tmp := os.get_env("TEMP", context.allocator)
	if tmp == "" do tmp = os.get_env("TMP", context.allocator)
	if tmp == "" do tmp = "."
	AUDIO_BASE = fmt.aprintf("%s\\odin_editor_audio", tmp)

	if exe, err := os.get_executable_path(context.temp_allocator); err == nil {
		if cut := strings.last_index_any(exe, "\\/"); cut > 0 {
			dir  := exe[:cut]
			EXE_DIR = strings.clone(dir) // dono; usado p/ achar o log de diagnóstico ao lado do .exe
			old  := os.get_env("PATH", context.temp_allocator)
			newp := fmt.tprintf("%s;%s", dir, old)
			win.SetEnvironmentVariableW(win.utf8_to_wstring("PATH"), win.utf8_to_wstring(newp))
		}
	}
}

// STARTUP: apaga temporários ÓRFÃOS — arquivos "odin_editor_audio_*" no %TEMP% cujo PID
// (embutido no nome) pertence a um processo que NÃO existe mais. São lixo de fechamentos
// por CRASH (o fechamento normal via close_now já limpa os do próprio PID). NÃO toca nos
// de um PID vivo: pode ser OUTRA instância do editor rodando agora. Roda depois do
// init_paths (precisa de AUDIO_BASE) e antes de qualquer spawn/temp. %TEMP% é por-usuário,
// então todo arquivo aqui é nosso (mesmo usuário) — sem risco de acesso negado no OpenProcess.
sweep_orphan_temps :: proc() {
	if AUDIO_BASE == "" do return
	slash := strings.last_index(AUDIO_BASE, "\\")
	if slash < 0 do return
	dir := AUDIO_BASE[:slash] // o %TEMP% (FindFirstFileW devolve só o NOME do arquivo, sem pasta)
	fd: win.WIN32_FIND_DATAW
	h := win.FindFirstFileW(win.utf8_to_wstring(fmt.tprintf("%s_*", AUDIO_BASE)), &fd)
	if h == win.INVALID_HANDLE_VALUE do return
	defer win.FindClose(h)
	PREFIX :: "odin_editor_audio_" // nome = PREFIX + <pid> + "_..." (ver os aprintf de aud_path/spv/box/fx)
	for {
		if fd.dwFileAttributes & win.FILE_ATTRIBUTE_DIRECTORY == 0 { // ignora subpastas
			name := win.wstring_to_utf8(win.wstring(raw_data(fd.cFileName[:])), -1) or_else ""
			if strings.has_prefix(name, PREFIX) {
				rest := name[len(PREFIX):]
				e := 0
				for e < len(rest) && rest[e] >= '0' && rest[e] <= '9' do e += 1 // dígitos do PID
				if pid, ok := strconv.parse_int(rest[:e], 10); ok && pid > 0 && !pid_alive(u32(pid)) {
					os.remove(fmt.tprintf("%s\\%s", dir, name))
				}
			}
		}
		if !win.FindNextFileW(h, &fd) do break
	}
}

// existe um processo com esse PID? OpenProcess devolve nil se o PID não corresponde a
// processo nenhum -> órfão seguro p/ apagar. Se corresponde (editor vivo, ou PID reciclado
// p/ outro programa), MANTÉM o arquivo — conservador: nunca apaga o de uma instância viva.
pid_alive :: proc(pid: u32) -> bool {
	h := win.OpenProcess(win.PROCESS_QUERY_LIMITED_INFORMATION, win.FALSE, win.DWORD(pid))
	if h == nil do return false
	win.CloseHandle(h)
	return true
}
